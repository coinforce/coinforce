-- coinforce_76_telegram_finalize
-- 75'in üzerine son ayarlar. Yalnızca ADD COLUMN ve CREATE OR REPLACE; hiçbir şey silinmez.
-- 1) Webhook güncelleme kaydı iki aşamalı: biten güncelleme tekrar işlenmez; 30 sn'den uzun süre yarıda
--    kalan (zaman aşımı/çökme) güncelleme yeniden işlenebilir. Emir tarafı idempotent olduğu için yeniden
--    işleme ikinci bir emir oluşturmaz, saklanan sonucu döndürür.
-- 2) tgx_begin: tekrar kontrolü + hesap bilgisi tek çağrıda (bot ile veritabanı arasındaki gidiş-dönüş azalır).
-- 3) tgx_order: idempotency anahtarı Telegram kullanıcısına bağlı (başkasının kaydı asla dönmez);
--    pozisyon kapama dakikalık 20 yeni emir sınırına sayılmaz; sonuçta işlem sonrası USDT bakiyesi döner.
-- 4) tgx_audit_event: edge function'ın kendi olaylarını (özel olmayan sohbet, hata) audit log'a yazması.
-- 5) tgx_cleanup + günlük cron: telegram_updates 3 gün, login_attempts 2 gün saklanır.
-- 6) tgx_config: bot yapılandırması. Production'da app_settings'te tg_api_base / tg_test_token yoktur, değerler boş döner.

-- 1) İki aşamalı güncelleme kaydı ---------------------------------------------------------------
alter table public.telegram_updates add column if not exists done_at timestamptz;

create or replace function public.tgx_seen_update(p_update_id bigint, p_tg_user bigint)
returns text language plpgsql security definer
set search_path = ''
as $$
declare r public.telegram_updates; k int;
begin
  insert into public.telegram_updates (update_id, tg_user_id) values (p_update_id, p_tg_user)
  on conflict do nothing returning * into r;
  if r.update_id is null then
    update public.telegram_updates set received_at = now()
     where update_id = p_update_id and done_at is null and received_at < now() - interval '30 seconds'
    returning * into r;
    return case when r.update_id is null then 'dup' else 'retry' end;
  end if;
  if p_tg_user is not null then
    select count(*) into k from public.telegram_updates
     where tg_user_id = p_tg_user and received_at > now() - interval '60 seconds';
    if k > 60 then return 'limited'; end if;
  end if;
  return 'ok';
end $$;

create or replace function public.tgx_update_done(p_update_id bigint)
returns void language sql security definer
set search_path = ''
as $$
  update public.telegram_updates set done_at = now() where update_id = p_update_id and done_at is null;
$$;

-- 2) Tek çağrıda tekrar kontrolü + hesap bilgisi ---------------------------------------------------
create or replace function public.tgx_begin(p_update_id bigint, p_tg_user bigint)
returns json language plpgsql security definer
set search_path = ''
as $$
declare s text := public.tgx_seen_update(p_update_id, p_tg_user);
begin
  if s not in ('ok', 'retry') then return json_build_object('seen', s); end if;
  return json_build_object('seen', s, 'me', public.tgx_me(p_tg_user));
end $$;

-- 3) Emir giriş noktası (imza 75 ile aynı) --------------------------------------------------------
create or replace function public.tgx_order(
  p_tg_user bigint, p_idem text, p_update bigint, p_kind text,
  p_symbol text default null, p_side text default null, p_amount numeric default null, p_qty numeric default null,
  p_price numeric default null, p_leverage integer default null, p_ref uuid default null, p_pct numeric default null)
returns json language plpgsql security definer
set search_path = ''
as $$
declare
  n public.tg_notify; u uuid; lg public.telegram_order_logs; pr public.prices; ps public.positions; od public.orders;
  sym text := upper(btrim(coalesce(p_symbol, '')));
  -- Yeni emirler sayılır; iptal ve pozisyon kapama (riski azaltan işlemler) sayılmaz.
  is_new boolean := p_kind in ('spot_market','spot_limit','spot_stop','futures_open');
  cnt int; bal numeric; have numeric; a numeric; q numeric; px numeric; lev int; sd int; fee numeric;
  is_custom boolean := false; res json; rid uuid; st text; v_err text; v_code text; v_pnl numeric;
begin
  if p_idem is null or length(p_idem) < 3 or length(p_idem) > 128 then raise exception 'invalid idempotency key'; end if;
  if p_kind not in ('spot_market','spot_limit','spot_stop','futures_open','futures_close','order_cancel') then raise exception 'invalid kind'; end if;

  select * into lg from public.telegram_order_logs where idem_key = p_idem;
  if lg.id is not null then
    if lg.tg_user_id is distinct from p_tg_user then
      return json_build_object('ok', false, 'code', 'IDEM_CONFLICT', 'error', 'Geçersiz istek.');
    end if;
    return cf_private.tg_order_json(lg, true);
  end if;

  select * into n from public.tg_notify where tg_user_id = p_tg_user and chat_id is not null;
  if n.user_id is null then
    perform cf_private.tg_audit(p_tg_user, null, p_update, 'order_denied', jsonb_build_object('reason', 'not_linked', 'kind', p_kind));
    return json_build_object('ok', false, 'code', 'NOT_LINKED', 'error', 'Bu Telegram hesabı bir COINFORCE hesabına bağlı değil.');
  end if;
  u := n.user_id;

  -- Hesap başına aynı anda tek Telegram emri: dakikalık sınır ve idempotency eşzamanlı isteklerde de atomik.
  perform pg_advisory_xact_lock(hashtextextended('tgx-order:' || u::text, 0));
  select * into lg from public.telegram_order_logs where idem_key = p_idem;
  if lg.id is not null then
    if lg.tg_user_id is distinct from p_tg_user then
      return json_build_object('ok', false, 'code', 'IDEM_CONFLICT', 'error', 'Geçersiz istek.');
    end if;
    return cf_private.tg_order_json(lg, true);
  end if;

  -- İzin kapatma ile yarışmasın: satır kilidi, izin kapatan işlem bitene kadar bekletir.
  select * into n from public.tg_notify where user_id = u for share;
  if not coalesce(n.trading_enabled, false) or n.tg_user_id is distinct from p_tg_user or n.chat_id is null then
    perform cf_private.tg_audit(p_tg_user, u, p_update, 'order_denied', jsonb_build_object('reason', 'trading_off', 'kind', p_kind));
    return json_build_object('ok', false, 'code', 'TRADING_OFF',
      'error', 'Telegram''dan işlem izni kapalı. COINFORCE uygulamasında Ayarlar › Telegram bildirimleri bölümünden açabilirsin.');
  end if;
  if exists (select 1 from auth.users where id = u and (banned_until > now() or deleted_at is not null)) then
    perform cf_private.tg_audit(p_tg_user, u, p_update, 'order_denied', jsonb_build_object('reason', 'banned', 'kind', p_kind));
    return json_build_object('ok', false, 'code', 'BANNED', 'error', 'Hesabın işleme kapalı.');
  end if;

  -- Doğrulama (motor her şeyi tekrar kontrol eder; bunlar açık mesaj ve Telegram'a özel kurallar içindir)
  if is_new then
    select count(*) into cnt from public.telegram_order_logs
     where user_id = u and counted and created_at > now() - interval '60 seconds';
    if cnt >= 20 then v_code := 'RATE_LIMIT'; v_err := 'Dakikada en fazla 20 yeni emir verebilirsin. Biraz bekleyip tekrar dene.'; end if;
  end if;

  if v_code is null and p_kind in ('spot_market','spot_limit','spot_stop','futures_open') then
    if sym !~ '^[A-Z0-9]{1,20}$' then v_code := 'PAIR'; v_err := 'Geçersiz sembol.'; end if;
    if v_code is null then
      select * into pr from public.prices where symbol = sym;
      if pr.symbol is null or not coalesce(pr.listed, false) then
        v_code := 'PAIR'; v_err := format('%s/USDT işlem çifti bulunamadı ya da işleme kapalı.', sym);
      else
        is_custom := exists (select 1 from public.custom_coins c where c.symbol = sym);
        -- COINFORCE coinlerinin fiyatı dış veriden değil, işlem anında arz eğrisinden hesaplanır.
        if not is_custom and pr.updated_at < now() - interval '120 seconds' then
          v_code := 'PRICE_STALE';
          v_err := format('Fiyat verisi güncel değil (%s sn önce güncellendi). Emir reddedildi.', floor(extract(epoch from now() - pr.updated_at)));
        end if;
        px := pr.price;
      end if;
    end if;
  end if;

  if v_code is null and p_kind = 'futures_close' then
    select * into ps from public.positions where id = p_ref and user_id = u and status = 'open';
    if ps.id is null then v_code := 'NOT_FOUND'; v_err := 'Açık pozisyon bulunamadı.';
    else
      sym := ps.symbol;
      select * into pr from public.prices where symbol = ps.symbol;
      if pr.updated_at < now() - interval '120 seconds' then
        v_code := 'PRICE_STALE';
        v_err := format('Fiyat verisi güncel değil (%s sn önce güncellendi). Emir reddedildi.', floor(extract(epoch from now() - pr.updated_at)));
      end if;
    end if;
  end if;

  if v_code is null and p_kind = 'order_cancel' then
    select * into od from public.orders where id = p_ref and user_id = u and status = 'open';
    if od.id is null then v_code := 'NOT_FOUND'; v_err := 'Açık emir bulunamadı.'; else sym := od.symbol; end if;
  end if;

  if v_code is null then
    select usdt into bal from public.accounts where user_id = u;
    if p_kind = 'spot_market' and p_side = 'buy' then
      a := trunc(p_amount, 2);
      if a is null or a < 1 then v_code := 'MIN_AMOUNT'; v_err := 'En düşük emir tutarı 1 USDT.';
      elsif a > coalesce(bal, 0) then v_code := 'BALANCE'; v_err := format('Kullanılabilir bakiye yetersiz: %s USDT.', to_char(coalesce(bal, 0), 'FM999999990.00'));
      end if;
    elsif p_kind = 'spot_market' and p_side = 'sell' then
      select qty into have from public.holdings where user_id = u and symbol = sym;
      if p_pct is not null then
        if p_pct <= 0 or p_pct > 100 then v_code := 'AMOUNT'; v_err := 'Yüzde 0 ile 100 arasında olmalı.';
        else q := case when p_pct = 100 then have else trunc(coalesce(have, 0) * p_pct / 100, 8) end; end if;
      else q := trunc(p_qty, 8); end if;
      if v_code is null then
        if q is null or q <= 0 then
          if coalesce(have, 0) <= 0 then v_code := 'BALANCE'; v_err := format('Elinde %s yok.', sym);
          else v_code := 'AMOUNT'; v_err := 'Geçerli bir miktar gir.'; end if;
        elsif have is null or q > have + 1e-12 then v_code := 'BALANCE'; v_err := format('Yeterli %s yok. Elindeki: %s', sym, coalesce(trim(trailing '.' from trim(trailing '0' from to_char(have, 'FM999999999990.00000000'))), '0'));
        elsif q * px < 1 then v_code := 'MIN_AMOUNT'; v_err := 'En düşük emir tutarı 1 USDT.';
        end if;
      end if;
    elsif p_kind in ('spot_limit', 'spot_stop') then
      q := trunc(p_qty, 8); px := round(p_price, 8);
      if p_side not in ('buy', 'sell') then v_code := 'SIDE'; v_err := 'Yön al ya da sat olmalı.';
      elsif q is null or q <= 0 or px is null or px <= 0 then v_code := 'AMOUNT'; v_err := 'Geçerli miktar ve fiyat gir.';
      elsif q * px < 1 then v_code := 'MIN_AMOUNT'; v_err := 'En düşük emir tutarı 1 USDT.';
      elsif p_side = 'buy' and q * px * (case when p_kind = 'spot_stop' then 1.02 else 1 end) * 1.0008 > coalesce(bal, 0) + 0.000001 then
        v_code := 'BALANCE'; v_err := format('Kullanılabilir bakiye yetersiz: %s USDT.', to_char(coalesce(bal, 0), 'FM999999990.00'));
      elsif p_side = 'sell' then
        select qty into have from public.holdings where user_id = u and symbol = sym;
        if have is null or q > have + 1e-12 then v_code := 'BALANCE'; v_err := format('Yeterli %s yok.', sym); end if;
      end if;
    elsif p_kind = 'futures_open' then
      a := trunc(p_amount, 2); lev := p_leverage;
      sd := case lower(coalesce(p_side, '')) when 'long' then 1 when 'short' then -1 end;
      if sd is null then v_code := 'SIDE'; v_err := 'Yön long ya da short olmalı.';
      elsif a is null or a < 1 then v_code := 'MIN_AMOUNT'; v_err := 'En düşük teminat 1 USDT.';
      elsif lev is null or lev < 1 or lev > coalesce(pr.max_leverage, 1) then v_code := 'LEVERAGE'; v_err := format('%s için kaldıraç 1x ile %sx arasında olmalı.', sym, coalesce(pr.max_leverage, 1));
      else
        fee := a * lev * 0.0005;
        if a + fee > coalesce(bal, 0) + 0.000001 then v_code := 'BALANCE'; v_err := format('Kullanılabilir bakiye yetersiz: %s USDT (teminat + komisyon %s USDT).', to_char(coalesce(bal, 0), 'FM999999990.00'), to_char(a + fee, 'FM999999990.00')); end if;
      end if;
    end if;
  end if;

  if v_code is not null then
    insert into public.telegram_order_logs (user_id, tg_user_id, idem_key, update_id, kind, symbol, side, amount_usd, qty, price, leverage, ref_id, status, counted, error, result, finished_at)
    values (u, p_tg_user, p_idem, p_update, p_kind, nullif(sym, ''), p_side, coalesce(a, p_amount), coalesce(q, p_qty), coalesce(px, p_price), p_leverage, p_ref,
            'rejected', false, v_err, jsonb_build_object('code', v_code), now())
    returning * into lg;
    perform cf_private.tg_audit(p_tg_user, u, p_update, 'order_rejected', jsonb_build_object('code', v_code, 'kind', p_kind, 'symbol', nullif(sym, ''), 'log_id', lg.id));
    return cf_private.tg_order_json(lg, false);
  end if;

  insert into public.telegram_order_logs (user_id, tg_user_id, idem_key, update_id, kind, symbol, side, amount_usd, qty, price, leverage, ref_id, counted)
  values (u, p_tg_user, p_idem, p_update, p_kind, nullif(sym, ''), p_side, a, q, px, lev, p_ref, is_new)
  returning * into lg;

  -- Mevcut motor fonksiyonu, kullanıcı uygulamadan çağırmış gibi çalıştırılır.
  perform cf_private.tg_act_as(u);
  begin
    if p_kind = 'spot_market' and p_side = 'buy' then
      res := public.market_trade(sym, 'buy', a, null); st := 'filled';
    elsif p_kind = 'spot_market' then
      res := public.market_trade(sym, 'sell', null, q); st := 'filled';
    elsif p_kind in ('spot_limit', 'spot_stop') then
      rid := public.place_order(sym, p_side, case p_kind when 'spot_limit' then 'limit' else 'stop' end, px, q);
      select * into od from public.orders where id = rid;
      st := case od.status when 'open' then 'open' when 'filled' then 'filled' else 'cancelled' end;
      res := json_build_object('order_id', rid, 'status', od.status, 'type', od.type, 'side', od.side, 'qty', od.qty,
                               'trigger_price', od.trigger_price, 'reserved_usdt', od.reserved_usdt);
    elsif p_kind = 'futures_open' then
      rid := public.open_position(sym, sd, lev, a);
      select * into ps from public.positions where id = rid;
      st := 'opened';
      res := json_build_object('position_id', rid, 'side', ps.side, 'leverage', ps.leverage, 'margin', ps.margin,
                               'entry_price', ps.entry_price, 'qty', ps.qty, 'liq_price', ps.liq_price, 'fee', round(ps.margin * ps.leverage * 0.0005, 8));
    elsif p_kind = 'futures_close' then
      v_pnl := public.close_position(p_ref);
      rid := p_ref; st := 'closed';
      res := json_build_object('position_id', p_ref, 'pnl', v_pnl, 'symbol', ps.symbol, 'side', ps.side, 'leverage', ps.leverage, 'margin', ps.margin,
                               'entry_price', ps.entry_price,
                               'exit_price', (select t.price from public.transactions t where t.user_id = u and t.kind = 'perp_close' and t.symbol = ps.symbol order by t.created_at desc limit 1));
    elsif p_kind = 'order_cancel' then
      perform public.cancel_order(p_ref);
      rid := p_ref; st := 'cancelled';
      res := json_build_object('order_id', p_ref, 'symbol', od.symbol, 'side', od.side, 'type', od.type, 'qty', od.qty, 'trigger_price', od.trigger_price);
    end if;
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err is not null then
    update public.telegram_order_logs set status = 'rejected', counted = false, error = v_err,
      result = jsonb_build_object('code', 'ENGINE'), finished_at = now()
    where id = lg.id returning * into lg;
    perform cf_private.tg_audit(p_tg_user, u, p_update, 'order_rejected', jsonb_build_object('code', 'ENGINE', 'kind', p_kind, 'symbol', nullif(sym, ''), 'log_id', lg.id, 'error', v_err));
  else
    res := (res::jsonb || jsonb_build_object('balance_after', (select usdt from public.accounts where user_id = u)))::json;
    update public.telegram_order_logs set status = st, ref_id = rid, result = res::jsonb, finished_at = now()
    where id = lg.id returning * into lg;
    perform cf_private.tg_audit(p_tg_user, u, p_update, 'order_executed', jsonb_build_object('kind', p_kind, 'symbol', nullif(sym, ''), 'status', st, 'log_id', lg.id));
  end if;
  return cf_private.tg_order_json(lg, false);
end $$;

-- 4) Edge function olayları için audit (yalnızca izin verilen alanlar saklanır) ----------------------
create or replace function public.tgx_audit_event(p_tg_user bigint, p_update bigint, p_event text, p_detail jsonb default null)
returns void language plpgsql security definer
set search_path = ''
as $$
begin
  if p_event !~ '^[a-z_]{3,40}$' then return; end if;
  insert into public.telegram_audit_logs (tg_user_id, user_id, update_id, event, detail)
  values (p_tg_user, (select user_id from public.tg_notify where tg_user_id = p_tg_user), p_update, p_event,
          (select jsonb_object_agg(k, case when jsonb_typeof(v) = 'string' then to_jsonb(left(v #>> '{}', 300)) else v end)
             from jsonb_each(coalesce(p_detail, '{}'::jsonb)) e(k, v)
            where k in ('reason', 'chat_type', 'command', 'error', 'kind', 'status', 'ms')));
end $$;

-- 5) Eski kayıtların temizliği ----------------------------------------------------------------------
create or replace function public.tgx_cleanup()
returns json language plpgsql security definer
set search_path = ''
as $$
declare a int; b int;
begin
  with d as (delete from public.telegram_updates where received_at < now() - interval '3 days' returning 1) select count(*) into a from d;
  with d as (delete from cf_private.login_attempts where created_at < now() - interval '2 days' returning 1) select count(*) into b from d;
  return json_build_object('updates', a, 'login_attempts', b);
end $$;

select cron.schedule('coinforce-telegram-cleanup', '23 3 * * *', 'select public.tgx_cleanup()');

-- 6) Bot yapılandırması --------------------------------------------------------------------------
create or replace function public.tgx_config()
returns json language sql stable security definer
set search_path = ''
as $$
  select json_build_object(
    'api_base', (select nullif(value, '') from public.app_settings where key = 'tg_api_base'),
    'test_token', (select nullif(value, '') from public.app_settings where key = 'tg_test_token'),
    'bot', (select nullif(value, '') from public.app_settings where key = 'tg_bot'));
$$;

-- 6b) Fiyat listesi (bot menüsü): işleme açık en büyük coinler, tek çağrıda
create or replace function public.tgx_prices(p_limit integer default 12)
returns json language sql stable security definer
set search_path = ''
as $$
  select coalesce(json_agg(x order by x.mc desc nulls last), '[]'::json) from (
    select p.symbol, p.name, p.price, p.market_cap mc,
           case when coalesce(p.open_24h, 0) > 0 then round((p.price / p.open_24h - 1) * 100, 2) end change_pct,
           floor(extract(epoch from now() - p.updated_at)) age_s
      from public.prices p
     where coalesce(p.listed, false)
     order by p.market_cap desc nulls last
     limit least(greatest(coalesce(p_limit, 12), 1), 30)) x;
$$;

-- 7) Yetkiler: tüm tgx_* fonksiyonları yalnızca güvenilir sunucu (servis rolü) içindir ----------------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace s on s.oid = p.pronamespace
           where s.nspname = 'public' and p.proname like 'tgx\_%' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
