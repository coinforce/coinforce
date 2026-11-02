-- coinforce_77_telegram_group
-- Toplu işlem: hesap sahibi, başka COINFORCE hesaplarının API Key + Secret Key'ini UYGULAMADAN ekler.
-- Toplu işlem açıkken bottan verdiği her emir, kendi hesabıyla birlikte eklenen hesaplarda da aynı anda yürütülür.
-- Secret Key Telegram'dan geçmez ve saklanmaz, yalnızca doğrulanır. Bağlantı eklenen hesabın API Key parmak izine
-- bağlıdır: hesap sahibi anahtarını yenilerse ya da bağlantıyı kaldırırsa erişim hemen biter.
-- Kurallar her hesapta ayrı uygulanır: en az 1 USDT, hesap başına dakikada 20 yeni emir, 120 sn fiyat yaşı, bakiye,
-- idempotency (emir anahtarı + hesap). Kapama ve iptal yalnızca aynı toplu işlemle açılmış pozisyon/emirde yapılır.
-- Yalnızca ekleme: yeni tablo, sütun ve fonksiyonlar; tgx_order için CREATE OR REPLACE (imza aynı). Hiçbir şey silinmez.

-- 1) Tablolar ----------------------------------------------------------------------------------------
alter table public.tg_notify add column if not exists group_trading boolean not null default false;

create table if not exists public.tg_group_links (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) on delete cascade,
  member_id uuid not null references auth.users (id) on delete cascade,
  key_fp text not null,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid,
  constraint tg_group_links_not_self check (owner_id <> member_id)
);
create unique index if not exists tg_group_links_active on public.tg_group_links (owner_id, member_id) where revoked_at is null;
create index if not exists tg_group_links_member on public.tg_group_links (member_id) where revoked_at is null;
alter table public.tg_group_links enable row level security;
revoke all on public.tg_group_links from anon, authenticated;

create table if not exists cf_private.group_key_attempts (
  owner_id uuid not null,
  created_at timestamptz not null default now()
);
create index if not exists group_key_attempts_owner on cf_private.group_key_attempts (owner_id, created_at);

-- 2) Yardımcılar (API'den erişilemez) -------------------------------------------------------------------
create or replace function cf_private.group_fp(p_key text) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest(coalesce(p_key, ''), 'sha256'), 'hex')
$$;

create or replace function cf_private.html_esc(p text) returns text
language sql immutable set search_path = '' as $$
  select replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
$$;

create or replace function cf_private.num_tr(v numeric, d int) returns text
language sql immutable set search_path = '' as $$
  select case when v is null then '—'
    else replace(rtrim(rtrim(to_char(round(v, d), 'FM999999999999990.' || repeat('0', greatest(d, 1))), '0'), '.'), '.', ',') end
$$;

-- Fiyat: büyük fiyatlarda 2, 1'in üstünde 4, küçüklerde 8 ondalık
create or replace function cf_private.px_tr(v numeric) returns text
language sql immutable set search_path = '' as $$
  select cf_private.num_tr(v, case when v >= 1000 then 2 when v >= 1 then 4 else 8 end)
$$;

-- Gruptaki, anahtarı hâlâ geçerli ve işleme açık hesaplar
create or replace function cf_private.group_members(p_owner uuid)
returns table (link_id uuid, member_id uuid, username text)
language sql stable security definer set search_path = '' as $$
  select l.id, l.member_id, coalesce(p.username, left(l.member_id::text, 8))
    from public.tg_group_links l
    join cf_private.account_api_keys k on k.user_id = l.member_id and cf_private.group_fp(k.api_key) = l.key_fp
    left join public.profiles p on p.id = l.member_id
   where l.owner_id = p_owner and l.revoked_at is null
     and not exists (select 1 from auth.users au where au.id = l.member_id and (au.banned_until > now() or au.deleted_at is not null))
   order by l.member_id
$$;

-- Özet mesajındaki tek hesap satırı
create or replace function cf_private.group_line(p_name text, r json) returns text
language plpgsql immutable set search_path = '' as $$
declare res json := r->'result'; t text;
begin
  if not coalesce((r->>'ok')::boolean, false) then
    return format('❌ @%s: %s', cf_private.html_esc(p_name), cf_private.html_esc(coalesce(r->>'error', 'Reddedildi')));
  end if;
  t := case r->>'kind'
    when 'spot_market' then format('%s %s @ %s', cf_private.num_tr((res->>'qty')::numeric, 8), r->>'symbol', cf_private.px_tr((res->>'price')::numeric))
    when 'spot_limit' then format('emir açıldı · %s %s @ %s', cf_private.num_tr((res->>'qty')::numeric, 8), r->>'symbol', cf_private.px_tr((res->>'trigger_price')::numeric))
    when 'spot_stop' then format('emir açıldı · %s %s @ %s', cf_private.num_tr((res->>'qty')::numeric, 8), r->>'symbol', cf_private.px_tr((res->>'trigger_price')::numeric))
    when 'futures_open' then format('%s %sx · teminat %s USDT · giriş %s', case when (res->>'side')::numeric > 0 then 'Long' else 'Short' end,
                                    res->>'leverage', cf_private.num_tr((res->>'margin')::numeric, 2), cf_private.px_tr((res->>'entry_price')::numeric))
    when 'futures_close' then format('kapatıldı · K/Z %s USDT', cf_private.num_tr((res->>'pnl')::numeric, 2))
    when 'order_cancel' then 'emir iptal edildi'
    else 'gerçekleşti' end;
  return format('✅ @%s: %s%s', cf_private.html_esc(p_name), t,
                case when coalesce((r->>'duplicate')::boolean, false) then ' (zaten işlenmişti)' else '' end);
end $$;

-- 3) Tek hesapta emir yürütme: 076'daki tgx_order'ın doğrulama ve yürütme kısmı, değişmeden ----------------
create or replace function cf_private.tg_order_exec(
  u uuid, p_tg_user bigint, p_idem text, p_update bigint, p_kind text,
  p_symbol text, p_side text, p_amount numeric, p_qty numeric,
  p_price numeric, p_leverage integer, p_ref uuid, p_pct numeric)
returns json language plpgsql security definer
set search_path = ''
as $$
declare
  lg public.telegram_order_logs; pr public.prices; ps public.positions; od public.orders;
  sym text := upper(btrim(coalesce(p_symbol, '')));
  -- Yeni emirler sayılır; iptal ve pozisyon kapama (riski azaltan işlemler) sayılmaz.
  is_new boolean := p_kind in ('spot_market','spot_limit','spot_stop','futures_open');
  cnt int; bal numeric; have numeric; a numeric; q numeric; px numeric; lev int; sd int; fee numeric;
  is_custom boolean := false; res json; rid uuid; st text; v_err text; v_code text; v_pnl numeric;
begin
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

-- 4) Emir giriş noktası (imza 076 ile aynı; toplu işlem kapalıyken davranış birebir aynı) ------------------
create or replace function public.tgx_order(
  p_tg_user bigint, p_idem text, p_update bigint, p_kind text,
  p_symbol text default null, p_side text default null, p_amount numeric default null, p_qty numeric default null,
  p_price numeric default null, p_leverage integer default null, p_ref uuid default null, p_pct numeric default null)
returns json language plpgsql security definer
set search_path = ''
as $$
declare
  n public.tg_notify; u uuid; lg public.telegram_order_logs; r json; mr json; m record; src public.telegram_order_logs;
  mref uuid; got boolean; i int; okc int := 0; tot int := 0; lines text[]; ttl text; midem text;
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

  r := cf_private.tg_order_exec(u, p_tg_user, p_idem, p_update, p_kind, p_symbol, p_side, p_amount, p_qty, p_price, p_leverage, p_ref, p_pct);

  -- 5) Toplu işlem: aynı emir eklenen hesaplarda, her hesabın kendi kurallarıyla. Herkes için aynı olan ret
  -- sebeplerinde (eski fiyat, geçersiz sembol/tutar/kaldıraç) diğer hesaplar denenmez.
  if not coalesce(n.group_trading, false) then return r; end if;
  if not (coalesce((r->>'ok')::boolean, false) or (r->>'code') in ('BALANCE', 'RATE_LIMIT', 'ENGINE')) then return r; end if;
  if p_kind in ('futures_close', 'order_cancel') then
    select * into src from public.telegram_order_logs
     where user_id = u and ref_id = p_ref and kind in ('futures_open', 'spot_limit', 'spot_stop')
     order by created_at desc limit 1;
  end if;
  lines := array[cf_private.group_line(coalesce((select username from public.profiles where id = u), 'hesabın') || ' (sen)', r)];
  tot := 1; okc := case when coalesce((r->>'ok')::boolean, false) then 1 else 0 end;

  for m in select * from cf_private.group_members(u) loop
    mref := null;
    if p_kind in ('futures_close', 'order_cancel') then
      -- Yalnızca aynı toplu işlemle açılmış ve hâlâ açık olan pozisyon/emir
      if src.id is null then continue; end if;
      select l.ref_id into mref from public.telegram_order_logs l
       where l.idem_key = src.idem_key || ':' || m.member_id::text and l.user_id = m.member_id;
      if mref is null
         or (p_kind = 'futures_close' and not exists (select 1 from public.positions where id = mref and user_id = m.member_id and status = 'open'))
         or (p_kind = 'order_cancel' and not exists (select 1 from public.orders where id = mref and user_id = m.member_id and status = 'open'))
      then continue; end if;
    end if;
    tot := tot + 1;
    midem := p_idem || ':' || m.member_id::text;
    -- Kilitlenme olmasın: hesabın kilidi kısa süre denenir, alınamazsa emir bu hesapta atlanır.
    got := false;
    for i in 1..40 loop
      got := pg_try_advisory_xact_lock(hashtextextended('tgx-order:' || m.member_id::text, 0));
      exit when got;
      perform pg_sleep(0.05);
    end loop;
    if not got then
      mr := json_build_object('ok', false, 'code', 'BUSY', 'error', 'Hesap şu an başka bir emir işliyor; emir bu hesapta atlandı.');
    else
      begin
        select * into lg from public.telegram_order_logs where idem_key = midem;
        if lg.id is not null then
          mr := cf_private.tg_order_json(lg, true);
        else
          mr := cf_private.tg_order_exec(m.member_id, p_tg_user, midem, p_update, p_kind, p_symbol, p_side,
                                         p_amount, p_qty, p_price, p_leverage, coalesce(mref, p_ref), p_pct);
        end if;
      exception when others then
        mr := json_build_object('ok', false, 'code', 'ENGINE', 'error', sqlerrm);
      end;
    end if;
    if coalesce((mr->>'ok')::boolean, false) then okc := okc + 1; end if;
    lines := lines || cf_private.group_line(m.username, mr);
  end loop;

  if tot < 2 then return r; end if;
  ttl := coalesce(nullif(r->>'symbol', ''), upper(btrim(coalesce(p_symbol, '')))) || '/USDT · ' || case
    when p_kind = 'spot_market' and p_side = 'buy' then format('piyasa alış, hesap başına %s USDT', cf_private.num_tr(p_amount, 2))
    when p_kind = 'spot_market' then 'piyasa satış, ' || case when p_pct is not null then '%' || cf_private.num_tr(p_pct, 2) || ' (her hesabın kendi bakiyesinden)' else cf_private.num_tr(p_qty, 8) || ' adet' end
    when p_kind in ('spot_limit', 'spot_stop') then format('%s %s @ %s', case p_kind when 'spot_limit' then 'limit' else 'stop' end,
                                                            case when p_side = 'buy' then 'alış' else 'satış' end, cf_private.num_tr(p_price, 8))
    when p_kind = 'futures_open' then format('%s %sx, hesap başına %s USDT teminat', initcap(coalesce(p_side, '')), p_leverage, cf_private.num_tr(p_amount, 2))
    when p_kind = 'futures_close' then 'pozisyon kapatma'
    else 'emir iptali' end;
  insert into public.tg_outbox (chat_id, body)
  values (n.chat_id, format(E'👥 <b>Toplu işlem</b> · %s\n%s\n<b>%s/%s hesapta gerçekleşti.</b>',
                            cf_private.html_esc(ttl), array_to_string(lines, E'\n'), okc, tot));
  perform cf_private.tg_audit(p_tg_user, u, p_update, 'group_order', jsonb_build_object('kind', p_kind, 'ok', okc, 'total', tot));
  -- Özet hemen gönderilsin (pg_net isteği işlem bitince yollar; olmazsa zamanlanmış gönderim alır).
  begin
    perform net.http_post(
      url := (select value from public.app_settings where key = 'tg_function_url') || '?run=1',
      body := '{}'::jsonb,
      headers := jsonb_build_object('content-type', 'application/json', 'x-cf-internal', cf_private.tg_internal_secret()),
      timeout_milliseconds := 10000);
  exception when others then null;
  end;
  return (r::jsonb || jsonb_build_object('group', jsonb_build_object('ok', okc, 'total', tot)))::json;
end $$;

-- 6) Telegram bağlantısı değişince (bağlama, kaldırma) toplu işlem kendiliğinden kapanır -----------------
create or replace function cf_private.tg_group_reset() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.tg_user_id is distinct from old.tg_user_id or new.chat_id is distinct from old.chat_id then
    new.group_trading := false;
  end if;
  return new;
end $$;
create or replace trigger tg_notify_group_reset before update on public.tg_notify
  for each row execute function cf_private.tg_group_reset();

-- 7) Uygulama fonksiyonları (giriş yapmış kullanıcı) ---------------------------------------------------
create or replace function public.tg_group_add(p_api_key text, p_secret text)
returns json language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); k cf_private.account_api_keys; s text; c int; uname text; oname text; mchat bigint;
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  select count(*) into c from cf_private.group_key_attempts where owner_id = u and created_at > now() - interval '15 minutes';
  if c >= 5 then
    return json_build_object('ok', false, 'error', 'Çok fazla hatalı deneme. 15 dakika sonra tekrar dene.');
  end if;
  select * into k from cf_private.account_api_keys where api_key = btrim(coalesce(p_api_key, ''));
  if k.user_id is not null then s := extensions.pgp_sym_decrypt(k.secret_enc, cf_private.master_key()); end if;
  if k.user_id is null or s is null or s <> btrim(coalesce(p_secret, '')) then
    insert into cf_private.group_key_attempts (owner_id) values (u);
    perform cf_private.tg_audit(null, u, null, 'group_key_rejected');
    return json_build_object('ok', false, 'error', 'API Key ya da Secret Key hatalı.');
  end if;
  if k.user_id = u then
    return json_build_object('ok', false, 'error', 'Bu senin kendi anahtarın. Kendi hesabın toplu işleme zaten dahil.');
  end if;
  if exists (select 1 from auth.users au where au.id = k.user_id and (au.banned_until > now() or au.deleted_at is not null)) then
    return json_build_object('ok', false, 'error', 'Bu hesap işleme kapalı.');
  end if;
  if (select count(*) from public.tg_group_links where owner_id = u and revoked_at is null and member_id <> k.user_id) >= 25 then
    return json_build_object('ok', false, 'error', 'En fazla 25 hesap ekleyebilirsin.');
  end if;
  update public.tg_group_links set key_fp = cf_private.group_fp(k.api_key), created_at = now()
   where owner_id = u and member_id = k.user_id and revoked_at is null;
  if not found then
    insert into public.tg_group_links (owner_id, member_id, key_fp) values (u, k.user_id, cf_private.group_fp(k.api_key));
  end if;
  update cf_private.account_api_keys set last_used_at = now() where user_id = k.user_id;
  select username into uname from public.profiles where id = k.user_id;
  select username into oname from public.profiles where id = u;
  select chat_id into mchat from public.tg_notify where user_id = k.user_id and chat_id is not null;
  if mchat is not null then
    insert into public.tg_outbox (chat_id, body) values (mchat, format(
      '⚠️ COINFORCE hesabın, API anahtarınla @%s hesabının toplu işlemine eklendi. Bu hesabın bottan verdiği emirler artık senin hesabında da gerçekleşebilir. İstemiyorsan uygulamada Ayarlar › Telegram bildirimleri › Toplu işlem bölümünden kaldır ya da API anahtarını yenile.',
      cf_private.html_esc(oname)));
  end if;
  perform cf_private.tg_audit(null, u, null, 'group_added', jsonb_build_object('member', k.user_id));
  return json_build_object('ok', true, 'username', uname);
end $$;

create or replace function public.tg_group_list()
returns json language plpgsql stable security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  return json_build_object(
    'enabled', coalesce((select group_trading from public.tg_notify where user_id = u), false),
    'members', coalesce((select json_agg(json_build_object('id', l.id, 'username', p.username, 'added_at', l.created_at,
                 'active', exists (select 1 from cf_private.account_api_keys k where k.user_id = l.member_id and cf_private.group_fp(k.api_key) = l.key_fp))
                 order by l.created_at)
               from public.tg_group_links l left join public.profiles p on p.id = l.member_id
              where l.owner_id = u and l.revoked_at is null), '[]'::json),
    'controllers', coalesce((select json_agg(json_build_object('id', l.id, 'username', p.username, 'added_at', l.created_at) order by l.created_at)
               from public.tg_group_links l left join public.profiles p on p.id = l.owner_id
              where l.member_id = u and l.revoked_at is null
                and exists (select 1 from cf_private.account_api_keys k where k.user_id = l.member_id and cf_private.group_fp(k.api_key) = l.key_fp)), '[]'::json));
end $$;

-- Bağlantıyı ekleyen de, eklenen hesabın sahibi de kaldırabilir.
create or replace function public.tg_group_remove(p_id uuid)
returns json language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); l public.tg_group_links;
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  update public.tg_group_links set revoked_at = now(), revoked_by = u
   where id = p_id and revoked_at is null and (owner_id = u or member_id = u)
  returning * into l;
  if l.id is null then return json_build_object('ok', false, 'error', 'Bağlantı bulunamadı.'); end if;
  perform cf_private.tg_audit(null, u, null, 'group_removed', jsonb_build_object('owner', l.owner_id, 'member', l.member_id));
  return json_build_object('ok', true);
end $$;

create or replace function public.tg_group_set(p_on boolean)
returns json language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); n public.tg_notify; c int;
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  select * into n from public.tg_notify where user_id = u for update;
  if n.chat_id is null or n.tg_user_id is null then raise exception 'Önce Telegram hesabını bağla'; end if;
  -- Oturum sürümü artar: önceki mesajlardaki işlem butonları geçersiz olur.
  update public.tg_notify set group_trading = coalesce(p_on, false), session_version = session_version + 1, state = null
   where user_id = u;
  select count(*) into c from cf_private.group_members(u);
  insert into public.tg_outbox (chat_id, body) values (n.chat_id, case when coalesce(p_on, false)
    then format('👥 Toplu işlem COINFORCE uygulamasından AÇILDI. Bottan verdiğin her emir, kendi hesabınla birlikte eklediğin %s hesapta da aynı anda gerçekleşir. Bunu sen yapmadıysan hemen uygulamadan kapat.', c)
    else '👤 Toplu işlem kapatıldı. Emirler artık yalnızca kendi hesabında gerçekleşir.' end);
  perform cf_private.tg_audit(n.tg_user_id, u, null, case when coalesce(p_on, false) then 'group_on' else 'group_off' end);
  return json_build_object('enabled', coalesce(p_on, false), 'members', c);
end $$;

-- 8) Yetkiler -------------------------------------------------------------------------------------
revoke all on function cf_private.group_fp(text), cf_private.html_esc(text), cf_private.num_tr(numeric, int), cf_private.px_tr(numeric),
  cf_private.group_members(uuid), cf_private.group_line(text, json), cf_private.tg_group_reset(),
  cf_private.tg_order_exec(uuid, bigint, text, bigint, text, text, text, numeric, numeric, numeric, integer, uuid, numeric)
  from public, anon, authenticated;
revoke all on function public.tg_group_add(text, text), public.tg_group_list(), public.tg_group_remove(uuid), public.tg_group_set(boolean) from public, anon;
grant execute on function public.tg_group_add(text, text), public.tg_group_list(), public.tg_group_remove(uuid), public.tg_group_set(boolean) to authenticated;
