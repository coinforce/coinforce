-- STAGING ONLY. Production'a asla uygulanmaz.
-- COINFORCE Telegram işlem sistemi · staging uçtan uca testi.
-- Gerçek akış: Telegram güncellemesi → telegram-notify Edge Function (webhook) → tgx_* RPC → mevcut motor fonksiyonları.
-- Telegram API'si yerine tg-mock Edge Function kullanılır; botun gönderdiği her çağrı cf_test.tg_mock_calls'a yazılır.
-- Uygulama tarafı (bağlama kodu, işlem izni, bağlantı kaldırma) gerçek Auth girişi + kullanıcı JWT'si ile PostgREST'ten çağrılır.
-- Yalnızca staging test hesapları (tg_alice, tg_bob, tg_carol) kullanılır. Veriye doğrudan DELETE/UPDATE yapılmaz:
-- bağlantılar uygulamanın kendi RPC'siyle (tg_notify_unlink) sıfırlanır, kontroller önce/sonra farkına bakar. Gerekli: staging_hooks.sql.
--
-- Çalıştırma: her bölüm ayrı bir CALL ile (bölümlerin içinde COMMIT var; tek başına çalıştırılmalı), sırayla:
--   call cf_test.e2e_link(2);         call cf_test.e2e_spot(1);        call cf_test.e2e_spot2(1);
--   call cf_test.e2e_futures(1);      call cf_test.e2e_concurrency(1); call cf_test.e2e_latency(1);
--   call cf_test.e2e_permissions(1);  call cf_test.e2e_security(1);
--   select * from cf_test.e2e_report(1);

create table if not exists cf_test.e2e_results (
  run_id bigint not null, n int not null, name text not null, ok boolean not null, detail text,
  at timestamptz not null default clock_timestamp(), primary key (run_id, n));
create table if not exists cf_test.e2e_latency (
  run_id bigint not null, i int not null, ms numeric, pre_ms numeric, status text, primary key (run_id, i));
create table if not exists cf_test.tokens (email text primary key, token text not null, exp timestamptz not null);

-- Sonuç kaydı
create or replace function cf_test.t(p_run bigint, p_n int, p_name text, p_ok boolean, p_detail text default null)
returns void language sql as $$
  insert into cf_test.e2e_results (run_id, n, name, ok, detail)
  values (p_run, p_n, p_name, coalesce(p_ok, false), left(coalesce(p_detail, ''), 500))
  on conflict (run_id, n) do update set name = excluded.name, ok = excluded.ok, detail = excluded.detail, at = clock_timestamp();
$$;

create or replace function cf_test.e2e_report(p_run bigint)
returns table(n int, sonuc text, test text, ayrinti text) language sql stable as $$
  select r.n, case when r.ok then 'GEÇTİ' else 'KALDI' end, r.name, r.detail
    from cf_test.e2e_results r where r.run_id = p_run order by r.n;
$$;

-- Test kullanıcısı oturumu (Auth giriş sınırına takılmamak için erişim belirteci önbelleklenir)
create or replace function cf_test.token(p_email text) returns text language plpgsql as $$
declare t text; b text; s int;
begin
  select k.token into t from cf_test.tokens k where k.email = p_email and k.exp > clock_timestamp() + interval '5 minutes';
  if t is not null then return t; end if;
  select x.status, x.body into s, b from cf_test.rest('POST', '/auth/v1/token?grant_type=password', null,
    json_build_object('email', p_email, 'password', 'Test-1234!')::text) x;
  t := (b::json)->>'access_token';
  if t is null then raise exception 'giriş başarısız: % (HTTP %)', p_email, s; end if;
  insert into cf_test.tokens (email, token, exp)
  values (p_email, t, clock_timestamp() + make_interval(secs => coalesce(((b::json)->>'expires_in')::int, 3600)))
  on conflict (email) do update set token = excluded.token, exp = excluded.exp;
  return t;
end $$;

-- Uygulamanın yaptığı gibi: kullanıcının JWT'siyle PostgREST RPC çağrısı
create or replace function cf_test.user_rpc(p_email text, p_fn text, p_args jsonb default '{}')
returns table(status int, body text) language plpgsql as $$
begin
  return query select x.status, x.body from cf_test.rest('POST', '/rest/v1/rpc/' || p_fn, cf_test.token(p_email), p_args::text) x;
end $$;

-- Telegram güncellemesi kurucuları (tarih: gerçek saat)
create or replace function cf_test.msg(p_update bigint, p_tg bigint, p_text text, p_chat bigint default null,
  p_chat_type text default 'private', p_date bigint default null, p_mid bigint default null)
returns jsonb language sql volatile as $$
  select jsonb_build_object('update_id', p_update, 'message', jsonb_build_object(
    'message_id', coalesce(p_mid, p_update), 'date', coalesce(p_date, extract(epoch from clock_timestamp())::bigint), 'text', p_text,
    'from', jsonb_build_object('id', p_tg, 'is_bot', false, 'first_name', 'T', 'username', 'user' || p_tg),
    'chat', jsonb_build_object('id', coalesce(p_chat, p_tg), 'type', p_chat_type)));
$$;
create or replace function cf_test.cbq(p_update bigint, p_tg bigint, p_data text, p_mid bigint default 777)
returns jsonb language sql volatile as $$
  select jsonb_build_object('update_id', p_update, 'callback_query', jsonb_build_object(
    'id', 'cq' || p_update, 'data', p_data,
    'from', jsonb_build_object('id', p_tg, 'is_bot', false, 'first_name', 'T', 'username', 'user' || p_tg),
    'message', jsonb_build_object('message_id', p_mid, 'date', extract(epoch from clock_timestamp())::bigint, 'text', 'menu',
      'chat', jsonb_build_object('id', p_tg, 'type', 'private'))));
$$;

-- Sahte Telegram kaydından okuma
create or replace function cf_test.last_alert(p_since timestamptz) returns text language sql stable as $$
  select coalesce((select body->>'text' from cf_test.tg_mock_calls
                    where at >= p_since and method = 'answerCallbackQuery' and body ? 'text' order by id desc limit 1), '');
$$;
create or replace function cf_test.buttons_since(p_since timestamptz)
returns table(call_id bigint, data text, label text) language sql stable as $$
  select c.id, b->>'callback_data', b->>'text'
    from cf_test.tg_mock_calls c
    cross join lateral jsonb_array_elements(case when jsonb_typeof(c.body->'reply_markup'->'inline_keyboard') = 'array'
                                                 then c.body->'reply_markup'->'inline_keyboard' else '[]'::jsonb end) r
    cross join lateral jsonb_array_elements(r) b
   where c.at >= p_since and c.method in ('sendMessage', 'editMessageText');
$$;
create or replace function cf_test.find_button(p_since timestamptz, p_prefix text) returns text language sql stable as $$
  select data from cf_test.buttons_since(p_since) where data like p_prefix || '%' order by call_id desc limit 1;
$$;
create or replace function cf_test.has_button(p_since timestamptz, p_data text) returns boolean language sql stable as $$
  select exists (select 1 from cf_test.buttons_since(p_since) where data = p_data);
$$;
create or replace function cf_test.sent_since(p_since timestamptz, p_chat bigint) returns int language sql stable as $$
  select count(*)::int from cf_test.tg_mock_calls
   where at >= p_since and chat_id = p_chat and method in ('sendMessage', 'editMessageText', 'sendPhoto');
$$;

-- Zamanlı gönderim ve eşzamanlı isteklerin bitmesini bekleme
create or replace function cf_test.post_timed(p_update jsonb, out status int, out ms numeric) language plpgsql as $$
declare t0 timestamptz := clock_timestamp();
begin
  status := cf_test.post_update(p_update);
  ms := round((extract(epoch from clock_timestamp() - t0) * 1000)::numeric, 1);
end $$;
create or replace function cf_test.wait_done(p_ids bigint[], p_timeout_s numeric default 45) returns int language plpgsql as $$
declare k int; t0 timestamptz := clock_timestamp();
begin
  loop
    select count(*) into k from public.telegram_updates where update_id = any(p_ids) and done_at is not null;
    exit when k >= coalesce(array_length(p_ids, 1), 0) or clock_timestamp() - t0 > make_interval(secs => p_timeout_s::float8);
    perform pg_sleep(0.4);
  end loop;
  return k;
end $$;
create or replace function cf_test.wait_http(p_req bigint[], p_timeout_s numeric default 30) returns int language plpgsql as $$
declare k int; t0 timestamptz := clock_timestamp();
begin
  loop
    select count(*) into k from net._http_response where id = any(p_req);
    exit when k >= coalesce(array_length(p_req, 1), 0) or clock_timestamp() - t0 > make_interval(secs => p_timeout_s::float8);
    perform pg_sleep(0.4);
  end loop;
  return k;
end $$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) Webhook güvenliği, bağlama ve işlem izni (testler 1–14)
create or replace procedure cf_test.e2e_link(p_run bigint) language plpgsql as $$
declare
  alice uuid := (select id from public.profiles where username = 'tg_alice');
  bob   uuid := (select id from public.profiles where username = 'tg_bob');
  carol uuid := (select id from public.profiles where username = 'tg_carol');
  ta bigint := 700000001; tb bigint := 700000002; tc bigint := 700000003; tx bigint := 700000099;
  u bigint := p_run * 10000;
  t0 timestamptz; s int; s2 int; s3 int; code text; code_b text; code_c text; ttl numeric; v text; rep text; u0 numeric; n0 int;
begin
  -- Başlangıç: test hesaplarının Telegram bağlantısı uygulamanın kendi RPC'siyle kaldırılır (veriye doğrudan yazılmaz)
  perform cf_test.user_rpc('alice@coinforce.test', 'tg_notify_unlink');
  perform cf_test.user_rpc('bob@coinforce.test', 'tg_notify_unlink');
  perform cf_test.user_rpc('carol@coinforce.test', 'tg_notify_unlink');
  u0 := (select usdt from public.accounts where user_id = alice);
  n0 := (select count(*) from public.telegram_order_logs where user_id = alice);

  -- 1
  s := cf_test.post_update(cf_test.msg(u + 1, ta, '/menu'), 'yanlis-gizli-deger');
  s2 := cf_test.post_update(cf_test.msg(u + 2, ta, '/menu'), '');
  perform cf_test.t(p_run, 1, 'Webhook: yanlış ya da boş gizli başlık reddedilir', s = 401 and s2 = 401,
    format('yanlış=%s · boş=%s', s, s2));

  -- 2
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 3, tx, '/buy BTC 100'));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 2, 'Bağlı olmayan Telegram hesabı emir veremez', s = 200 and rep like '%bağlı değil%'
    and not exists (select 1 from public.telegram_order_logs where tg_user_id = tx), left(rep, 110));

  -- 3
  select (x.body::json)->>'code' into code from cf_test.user_rpc('alice@coinforce.test', 'tg_notify_code') x;
  select round(extract(epoch from code_exp - clock_timestamp())) into ttl from public.tg_notify where user_id = alice;
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 4, ta, '/start ' || code));
  rep := cf_test.last_reply(t0);
  select n.tg_user_id || ':' || n.chat_id || ':' || n.trading_enabled into v from public.tg_notify n where n.user_id = alice;
  perform cf_test.t(p_run, 3, 'Uygulamadan alınan tek kullanımlık kodla bağlama (kod 5 dk geçerli)',
    code ~ '^[0-9A-F]{10}$' and ttl between 290 and 300 and v = ta || ':' || ta || ':false' and rep like '%COINFORCE Trading Terminal%',
    format('kod=%s · kalan süre=%s sn · tg_user:chat:izin=%s', code, ttl, v));

  -- 4
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 5, tb, '/start ' || code));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 4, 'Kullanılmış kod ikinci kez çalışmaz', rep like '%geçersiz%'
    and not exists (select 1 from public.tg_notify where tg_user_id = tb), left(rep, 110));

  -- 5
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 6, tb, '/start ' || upper(substr(md5(clock_timestamp()::text), 1, 10))));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 5, 'Uydurma (üretilmemiş) kod çalışmaz', rep like '%geçersiz ya da süresi dolmuş%'
    and not exists (select 1 from public.tg_notify where tg_user_id = tb), left(rep, 110));

  -- 6
  select (x.body::json)->>'code' into code_c from cf_test.user_rpc('carol@coinforce.test', 'tg_notify_code') x;
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 7, ta, '/start ' || code_c));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 6, 'Bir Telegram hesabı ikinci bir COINFORCE hesabına bağlanamaz',
    rep like '%başka bir COINFORCE hesabına bağlı%' and (select tg_user_id from public.tg_notify where user_id = carol) is null
    and (select tg_user_id from public.tg_notify where user_id = alice) = ta, left(rep, 130));

  -- 7
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 8, ta, '/buy BTC 100', -1001234567, 'supergroup'));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 7, 'Grup sohbetinden gelen emir komutu işlenmez', rep like '%özel sohbette%'
    and (select count(*) from public.telegram_order_logs where user_id = alice) = n0, left(rep, 100));

  -- 8
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 9, ta, '/balance', tb, 'private'));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 8, 'Gönderen ile sohbet kimliği farklıysa (sahte chat.id) işlenmez, veri sızmaz',
    rep like '%özel sohbette%' and rep not like '%Bakiye%', left(rep, 100));

  -- 9
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 10, ta, '/buy BTC 100'));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 9, 'İşlem izni varsayılan kapalı: emir reddedilir, bakiye değişmez', rep like '%izni kapalı%'
    and (select count(*) from public.telegram_order_logs where user_id = alice and status <> 'rejected' and created_at > t0) = 0
    and (select usdt from public.accounts where user_id = alice) = u0, left(rep, 120));

  -- 10
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 11, ta, '/settings'));
  rep := cf_test.last_reply(t0);
  s := cf_test.post_update(cf_test.cbq(u + 12, ta, 'trade:on', u + 12));
  s := cf_test.post_update(cf_test.msg(u + 13, ta, '/trading on'));
  perform cf_test.t(p_run, 10, 'İşlem izni Telegram''dan açılamaz (yalnızca uygulamadan)',
    rep like '%yalnızca COINFORCE uygulamasından%' and not (select trading_enabled from public.tg_notify where user_id = alice),
    left(rep, 120));

  -- 11
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 14, ta, '/bakiye'));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 11, 'İzin kapalıyken okuma çalışır (/bakiye)', rep like '%Kullanılabilir USDT%', left(rep, 110));

  -- 12
  select x.status into s from cf_test.user_rpc('alice@coinforce.test', 'tg_trading_set', '{"p_on": true}') x;
  perform cf_test.t(p_run, 12, 'İşlem izni uygulamadan açılır; Telegram''a güvenlik uyarısı kuyruğa girer', s = 200
    and (select trading_enabled from public.tg_notify where user_id = alice)
    and exists (select 1 from public.tg_outbox where chat_id = ta and body like '%AÇILDI%'), 'HTTP ' || s);

  -- 13
  select x.status into s from cf_test.rest('POST', '/rest/v1/rpc/tg_trading_set', null, '{"p_on": true}') x;
  select x.status into s2 from cf_test.rest('POST', '/rest/v1/rpc/tgx_order', cf_test.token('alice@coinforce.test'),
    json_build_object('p_tg_user', ta, 'p_idem', 'hack-1', 'p_update', 1, 'p_kind', 'spot_market', 'p_symbol', 'BTC',
                      'p_side', 'buy', 'p_amount', 10)::text) x;
  select x.status into s3 from cf_test.rest('POST', '/rest/v1/rpc/tgx_link', cf_test.token('bob@coinforce.test'),
    json_build_object('p_tg_user', 1, 'p_chat', 1, 'p_chat_type', 'private', 'p_tg_username', 'x', 'p_code', 'ABCDEF0123')::text) x;
  perform cf_test.t(p_run, 13, 'Bot RPC''leri (tgx_*) kullanıcı JWT''siyle çağrılamaz; izin anonim açılamaz',
    s in (401, 403) and s2 in (401, 403, 404) and s3 in (401, 403, 404)
    and not exists (select 1 from public.telegram_order_logs where idem_key = 'hack-1'),
    format('tg_trading_set(anon)=%s · tgx_order(alice)=%s · tgx_link(bob)=%s', s, s2, s3));

  -- 14
  select (x.body::json)->>'code' into code_b from cf_test.user_rpc('bob@coinforce.test', 'tg_notify_code') x;
  s := cf_test.post_update(cf_test.msg(u + 15, tb, '/start ' || code_b));
  perform cf_test.user_rpc('bob@coinforce.test', 'tg_trading_set', '{"p_on": true}');
  s := cf_test.post_update(cf_test.msg(u + 16, tc, '/start ' || code_c));   -- 6. testte reddedilen kod Carol'ın kendi Telegram'ıyla
  perform cf_test.user_rpc('carol@coinforce.test', 'tg_trading_set', '{"p_on": true}');
  perform cf_test.t(p_run, 14, 'Bob ve Carol kendi Telegram hesaplarıyla bağlandı, izinleri uygulamadan açıldı',
    (select count(*) from public.tg_notify
      where (user_id = bob and tg_user_id = tb and trading_enabled) or (user_id = carol and tg_user_id = tc and trading_enabled)) = 2,
    (select string_agg(p.username || '=' || coalesce(n.tg_user_id::text, '-') || '/' || n.trading_enabled, ' ')
       from public.tg_notify n join public.profiles p on p.id = n.user_id where n.user_id in (bob, carol)));
  commit;
end $$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) Spot: piyasa, tekrar koruması, limit/stop, butonlar, sohbet içi tutar (testler 15–25)
create or replace procedure cf_test.e2e_spot(p_run bigint) language plpgsql as $$
declare
  alice uuid := (select id from public.profiles where username = 'tg_alice');
  ta bigint := 700000001;
  u bigint := p_run * 10000 + 100;
  t0 timestamptz; s int; ms numeric; rep text; rep2 text; upd jsonb; n0 int; u0 numeric; u1 numeric; q numeric; px numeric;
  oid uuid; btn text; v text;
begin
  -- 15
  u0 := (select usdt from public.accounts where user_id = alice);
  upd := cf_test.msg(u + 1, ta, '/buy BTC 100');
  t0 := clock_timestamp();
  select x.status, x.ms into s, ms from cf_test.post_timed(upd) x;
  rep := cf_test.last_reply(t0);
  u1 := (select usdt from public.accounts where user_id = alice);
  q := (select coalesce(sum(qty), 0) from public.holdings where user_id = alice and symbol = 'BTC');
  perform cf_test.t(p_run, 15, '/buy BTC 100: onay beklemeden, aynı istekte piyasa alımı',
    rep like '%Alındı%BTC/USDT%' and abs((u0 - u1) - 100) < 0.01 and q > 0
    and (select status from public.telegram_order_logs where idem_key = 'm:' || ta || ':' || (u + 1)) = 'filled'
    and not exists (select 1 from cf_test.buttons_since(t0) b where b.label ilike '%onay%' or b.data like 'x:%'),
    format('%s ms · USDT %s → %s · BTC %s', ms, u0, u1, q));

  -- 16
  n0 := (select count(*) from public.telegram_order_logs where user_id = alice);
  s := cf_test.post_update(upd);
  s := cf_test.post_update(upd);
  perform cf_test.t(p_run, 16, 'Aynı update_id iki kez daha gelir: ikinci emir yok, bakiye değişmez',
    (select count(*) from public.telegram_order_logs where user_id = alice) = n0
    and (select usdt from public.accounts where user_id = alice) = u1,
    format('emir kaydı %s → %s', n0, (select count(*) from public.telegram_order_logs where user_id = alice)));

  -- 17
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 2, ta, '/buy BTC 100', null, 'private', null, u + 1));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 17, 'Aynı mesaj yeni update_id ile gelse de tek emir (idempotency anahtarı)',
    (select count(*) from public.telegram_order_logs where user_id = alice) = n0
    and (select usdt from public.accounts where user_id = alice) = u1 and rep like '%zaten işlenmişti%', left(rep, 110));

  -- 18
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 3, ta, '/sell BTC %50'));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 18, '/sell BTC %50: elindekinin yarısı satılır', rep like '%Satıldı%'
    and abs((select sum(qty) from public.holdings where user_id = alice and symbol = 'BTC') - q / 2) < 0.0000001,
    format('BTC %s → %s', q, (select sum(qty) from public.holdings where user_id = alice and symbol = 'BTC')));

  -- 19
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 4, ta, '/al ETH 20'));
  rep := cf_test.last_reply(t0);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 5, ta, '/sat BTC 0,0001'));
  rep2 := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 19, 'Türkçe komutlar: /al ETH 20 ve /sat BTC 0,0001', rep like '%Alındı%ETH/USDT%'
    and rep2 like '%Satıldı%0,0001 BTC%', left(rep2, 110));

  -- 20
  px := (select price from public.prices where symbol = 'ETH');
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 6, ta, '/buy ETH 50 limit ' || replace(to_char(trunc(px * 0.9, 2), 'FM999999990.00'), '.', ',')));
  rep := cf_test.last_reply(t0);
  oid := (select id from public.orders where user_id = alice and status = 'open' and symbol = 'ETH' and side = 'buy'
           order by created_at desc limit 1);
  btn := cf_test.find_button(t0, 'x:oc:');
  perform cf_test.t(p_run, 20, 'Limit alış emri açılır (fiyat Türkçe ondalıkla)', rep like '%Limit alış emri açıldı%'
    and oid is not null and btn like 'x:oc:' || oid || ':v%', format('emir=%s · buton=%s', oid, btn));

  -- 21
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 7, ta, btn, u + 7));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 21, 'Sonuç mesajındaki butonla emir iptali', (select status from public.orders where id = oid) = 'cancelled'
    and rep like '%Emir iptal edildi%', left(rep, 100));

  -- 22
  s := cf_test.post_update(cf_test.msg(u + 8, ta, '/buy SOL 30'));
  px := (select price from public.prices where symbol = 'SOL');
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 9, ta, '/sell SOL hepsi stop ' || replace(to_char(trunc(px * 0.95, 2), 'FM999999990.00'), '.', ',')));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 22, 'Stop satış emri açılır (/sell SOL hepsi stop …)', rep like '%Stop satış emri açıldı%'
    and exists (select 1 from public.orders where user_id = alice and symbol = 'SOL' and type = 'stop' and side = 'sell' and status = 'open'),
    left(rep, 120));

  -- 23
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 10, ta, '/orders'));
  rep := cf_test.last_reply(t0);
  btn := cf_test.find_button(t0, 'x:oc:');
  perform cf_test.t(p_run, 23, '/orders açık emri ve iptal butonunu gösterir', rep like '%Stop satış · SOL%' and btn ~ ':v[0-9]+$',
    left(rep, 120));

  -- 24
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 11, ta, 's:BTC', u + 11));
  rep := cf_test.last_reply(t0);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 12, ta, 'sb:BTC', u + 11));
  btn := cf_test.find_button(t0, 'x:mb:BTC:10:');
  n0 := (select count(*) from public.telegram_order_logs where user_id = alice and status = 'filled');
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 13, ta, btn, u + 11));
  rep2 := cf_test.last_reply(t0);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 14, ta, btn, u + 11));
  v := cf_test.last_alert(t0);
  perform cf_test.t(p_run, 24, 'Butonla alım (Spot › BTC › Piyasa al › 10 USDT); aynı butona ikinci basış emir oluşturmaz',
    rep like '%BTC/USDT</b> · Spot%' and rep2 like '%Alındı%' and v like '%zaten kullanıldı%'
    and (select count(*) from public.telegram_order_logs where user_id = alice and status = 'filled') = n0 + 1,
    format('buton=%s · ikinci basış: %s', btn, v));

  -- 25
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 15, ta, 'ci:mb:ETH', u + 15));
  rep := cf_test.last_reply(t0);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 16, ta, '15,5'));
  rep2 := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 25, 'Sohbet içi özel tutar (15,5 USDT) anında alınır', rep like '%Kaç USDT%' and rep2 like '%Alındı%ETH/USDT%'
    and exists (select 1 from public.telegram_order_logs where idem_key = 'm:' || ta || ':' || (u + 16) and status = 'filled' and amount_usd = 15.5),
    left(rep2, 110));
  commit;
end $$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) Spot doğrulamaları: belirsiz tutar, bakiye, en düşük tutar, çift, eski fiyat, gecikme, iletilen mesaj (testler 26–34)
create or replace procedure cf_test.e2e_spot2(p_run bigint) language plpgsql as $$
declare
  alice uuid := (select id from public.profiles where username = 'tg_alice');
  ta bigint := 700000001;
  u bigint := p_run * 10000 + 200;
  t0 timestamptz; s int; rep text; rep2 text; rep3 text; n0 int; u0 numeric; age numeric; cc text;
begin
  -- 26
  n0 := (select count(*) from public.telegram_order_logs where user_id = alice);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 1, ta, '/buy BTC 2.500'));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 26, 'Belirsiz tutar (2.500) emir oluşturmaz, açıklama ister', rep like '%belirsiz%'
    and (select count(*) from public.telegram_order_logs where user_id = alice) = n0, left(rep, 120));

  -- 27
  u0 := (select usdt from public.accounts where user_id = alice);
  t0 := clock_timestamp(); s := cf_test.post_update(cf_test.msg(u + 2, ta, '/buy BTC 999999')); rep := cf_test.last_reply(t0);
  t0 := clock_timestamp(); s := cf_test.post_update(cf_test.msg(u + 3, ta, '/buy BTC 0,5')); rep2 := cf_test.last_reply(t0);
  t0 := clock_timestamp(); s := cf_test.post_update(cf_test.msg(u + 4, ta, '/buy NOPE 10')); rep3 := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 27, 'Yetersiz bakiye, 1 USDT altı ve bilinmeyen çift reddedilir; bakiye değişmez',
    rep like '%bakiye yetersiz%' and rep2 like '%En düşük emir tutarı 1 USDT%' and rep3 like '%bulunamadı%'
    and (select usdt from public.accounts where user_id = alice) = u0,
    left(rep, 70) || ' | ' || left(rep2, 60) || ' | ' || left(rep3, 50));

  -- 28
  n0 := (select count(*) from public.telegram_order_logs where user_id = alice);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 5, ta, '/buy BTC 100 tp 90000'));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 28, 'Spot TP/SL istenirse desteklenmiyor denir, emir oluşmaz', rep like '%TP/SL desteklenmiyor%'
    and (select count(*) from public.telegram_order_logs where user_id = alice) = n0, left(rep, 120));

  -- 29
  age := (select floor(extract(epoch from clock_timestamp() - updated_at)) from public.prices where symbol = 'HIGGS');
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 6, ta, '/buy HIGGS 10'));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 29, 'Fiyat verisi eski (staging''de güncellenmeyen DEX coini) → emir reddedilir',
    age > 120 and rep like '%Fiyat verisi güncel değil%', format('veri yaşı %s sn · %s', age, left(rep, 90)));

  -- 30
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 7, ta, 's:HIGGS', u + 7));
  rep := cf_test.last_reply(t0);
  age := (select floor(extract(epoch from clock_timestamp() - updated_at)) from public.prices where symbol = 'XRP');
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 8, ta, '/buy XRP 10'));
  rep2 := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 30, 'Eski fiyatlı coin kartı "emir verilemez" uyarısı gösterir; 120 sn içinde güncellenen coinde emir gerçekleşir',
    rep like '%şu an emir verilemez (120 sn sınırı)%' and age <= 120 and rep2 like '%Alındı%XRP/USDT%',
    format('XRP veri yaşı %s sn · %s', age, left(rep2, 40)));

  -- 31
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 9, ta, '/buy BTC 10', null, 'private', extract(epoch from clock_timestamp())::bigint - 300));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 31, '300 sn gecikmeyle ulaşan emir komutu işlenmez', rep like '%gecikmeyle ulaştı%'
    and not exists (select 1 from public.telegram_order_logs where idem_key = 'm:' || ta || ':' || (u + 9)), left(rep, 110));

  -- 32
  t0 := clock_timestamp();
  s := cf_test.post_update(jsonb_set(cf_test.msg(u + 10, ta, '/buy BTC 10'), '{message,forward_origin}', '{"type":"user","date":1}'));
  perform cf_test.t(p_run, 32, 'İletilen (forward) mesajdaki komut yürütülmez', cf_test.sent_since(t0, ta) = 0
    and not exists (select 1 from public.telegram_order_logs where idem_key = 'm:' || ta || ':' || (u + 10)),
    'gönderilen mesaj: ' || cf_test.sent_since(t0, ta));

  -- 33
  cc := (select c.symbol from public.custom_coins c join public.prices p on p.symbol = c.symbol where p.listed order by c.symbol limit 1);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 11, ta, '/buy ' || cc || ' 5'));
  rep := cf_test.last_reply(t0);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 12, ta, '/buy ' || cc || ' 5 limit 0,001'));
  rep2 := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 33, 'COINFORCE coini: piyasa alımı çalışır (arz eğrisi), limit emri motor tarafından reddedilir',
    rep like '%Alındı%' and rep2 like '%Emir reddedildi%'
    and not exists (select 1 from public.orders where user_id = alice and symbol = cc and status = 'open'),
    cc || ': ' || left(rep, 50) || ' | ' || left(rep2, 90));

  -- 34
  t0 := clock_timestamp(); s := cf_test.post_update(cf_test.msg(u + 13, ta, '/price BTC')); rep := cf_test.last_reply(t0);
  t0 := clock_timestamp(); s := cf_test.post_update(cf_test.msg(u + 14, ta, '/balance')); rep2 := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 34, '/price ve /balance: fiyat, veri yaşı, spot bakiye ve varlıklar', rep like '%BTC/USDT%Veri yaşı%'
    and rep2 like '%Kullanılabilir USDT%' and rep2 like '%BTC:%' and rep2 like '%aynı USDT bakiyesini%', left(rep2, 120));
  commit;
end $$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 4) Vadeli: market long/short, kaldıraç, izole, tam kapama, desteklenmeyenler, callback manipülasyonu (testler 35–45)
create or replace procedure cf_test.e2e_futures(p_run bigint) language plpgsql as $$
declare
  alice uuid := (select id from public.profiles where username = 'tg_alice');
  bob   uuid := (select id from public.profiles where username = 'tg_bob');
  ta bigint := 700000001; tx bigint := 700000099;
  u bigint := p_run * 10000 + 300;
  t0 timestamptz; s int; rep text; rep2 text; rep3 text; btn text; btn2 text; n0 int; u0 numeric; u1 numeric;
  pos public.positions; bpos uuid; bord uuid; px numeric; ver int;
begin
  -- 35
  u0 := (select usdt from public.accounts where user_id = alice);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 1, ta, '/long ETH 25 10x'));
  rep := cf_test.last_reply(t0);
  select * into pos from public.positions where user_id = alice and status = 'open' and symbol = 'ETH' order by created_at desc limit 1;
  u1 := (select usdt from public.accounts where user_id = alice);
  perform cf_test.t(p_run, 35, '/long ETH 25 10x: izole long anında açılır, teminat + komisyon düşülür',
    rep like '%Long açıldı%ETH/USDT 10x (izole)%' and pos.leverage = 10 and pos.margin = 25 and pos.side = 1
    and (u0 - u1) between 25 and 25.2,
    format('teminat=%s · kaldıraç=%s · giriş=%s · tasfiye=%s · düşülen=%s USDT', pos.margin, pos.leverage, round(pos.entry_price, 2),
           round(pos.liq_price, 2), u0 - u1));

  -- 36
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 2, ta, '/close ETH %50'));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 36, 'Kısmi kapama istenirse (/close ETH %50) pozisyon kapanmaz, desteklenmiyor denir',
    rep like '%Kısmi kapama desteklenmiyor%' and (select status from public.positions where id = pos.id) = 'open', left(rep, 120));

  -- 37
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 3, ta, '/positions'));
  rep := cf_test.last_reply(t0);
  btn := cf_test.find_button(t0, 'x:fc:' || pos.id || ':v');
  u0 := (select usdt from public.accounts where user_id = alice);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 4, ta, '/close ETH'));
  rep2 := cf_test.last_reply(t0);
  u1 := (select usdt from public.accounts where user_id = alice);
  perform cf_test.t(p_run, 37, '/positions pozisyonu ve kapat butonunu gösterir; /close ETH tamamen kapatır, teminat + K/Z geri döner',
    rep like '%ETH Long 10x%' and btn is not null and (select status from public.positions where id = pos.id) = 'closed'
    and rep2 like '%Pozisyon kapatıldı%' and u1 > u0,
    format('K/Z=%s · USDT %s → %s', (select round(pnl, 4) from public.positions where id = pos.id), u0, u1));

  -- 38
  n0 := (select count(*) from public.telegram_order_logs where user_id = alice);
  t0 := clock_timestamp(); s := cf_test.post_update(cf_test.msg(u + 5, ta, '/long BTC 10 5x limit 60000')); rep := cf_test.last_reply(t0);
  t0 := clock_timestamp(); s := cf_test.post_update(cf_test.msg(u + 6, ta, '/short BTC 10 5x tp 50000')); rep2 := cf_test.last_reply(t0);
  t0 := clock_timestamp(); s := cf_test.post_update(cf_test.msg(u + 7, ta, '/long BTC 10 5x cross')); rep3 := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 38, 'Vadeli limit emir, TP/SL ve çapraz teminat istekleri reddedilir; pozisyon açılmaz',
    rep like '%desteklenmiyor%' and rep2 like '%desteklenmiyor%' and rep3 like '%desteklenmiyor%'
    and (select count(*) from public.telegram_order_logs where user_id = alice) = n0
    and not exists (select 1 from public.positions where user_id = alice and status = 'open'), left(rep, 140));

  -- 39
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 8, ta, '/short BTC 20 100x'));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 39, 'Kaldıraç sınırı (BTC en fazla 50x) aşılırsa reddedilir', rep like '%kaldıraç 1x ile 50x arasında%'
    and not exists (select 1 from public.positions where user_id = alice and status = 'open'), left(rep, 120));

  -- 40
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 9, ta, 'f:BTC', u + 9));
  rep := cf_test.last_reply(t0);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 10, ta, 'fs:BTC', u + 9));
  btn := case when cf_test.has_button(t0, 'fm:BTC:S:5') then 'fm:BTC:S:5' end;
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 11, ta, coalesce(btn, 'fm:BTC:S:5'), u + 9));
  btn2 := cf_test.find_button(t0, 'x:fo:BTC:S:5:10:v');
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 12, ta, btn2, u + 9));
  rep2 := cf_test.last_reply(t0);
  select * into pos from public.positions where user_id = alice and status = 'open' and symbol = 'BTC' order by created_at desc limit 1;
  perform cf_test.t(p_run, 40, 'Butonla vadeli: Vadeli › BTC › Short › 5x › 10 USDT; kart izole teminatı ve desteklenmeyenleri yazar',
    rep like '%İzole (çapraz teminat desteklenmiyor)%' and rep like '%TP/SL ve kısmi kapama desteklenmiyor%' and btn is not null
    and btn2 is not null and rep2 like '%Short açıldı%' and pos.side = -1 and pos.leverage = 5 and pos.margin = 10,
    format('buton=%s · pozisyon yön=%s kaldıraç=%s teminat=%s', btn2, pos.side, pos.leverage, pos.margin));

  -- 41
  btn := cf_test.find_button(t0, 'x:fc:' || pos.id || ':v');
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 13, ta, btn, u + 12));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 41, 'Sonuç mesajındaki “Pozisyonu kapat” butonu pozisyonu tamamen kapatır',
    btn is not null and (select status from public.positions where id = pos.id) = 'closed' and rep like '%Pozisyon kapatıldı%',
    left(rep, 120));

  -- 42
  perform cf_test.user_rpc('bob@coinforce.test', 'open_position', '{"p_symbol":"BTC","p_side":1,"p_leverage":5,"p_margin":20}');
  bpos := (select id from public.positions where user_id = bob and status = 'open' order by created_at desc limit 1);
  ver := (select session_version from public.tg_notify where user_id = alice);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 14, ta, 'x:fc:' || bpos || ':v' || ver, u + 14));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 42, 'Callback manipülasyonu: başka hesabın pozisyon kimliğiyle (geçerli damgayla) kapatma denenir, pozisyon açık kalır',
    bpos is not null and (select status from public.positions where id = bpos) = 'open' and rep like '%Açık pozisyon bulunamadı%',
    left(rep, 120));

  -- 43
  px := (select price from public.prices where symbol = 'BTC');
  perform cf_test.user_rpc('bob@coinforce.test', 'place_order',
    json_build_object('p_symbol', 'BTC', 'p_side', 'buy', 'p_type', 'limit', 'p_trigger', round(px * 0.5, 2), 'p_qty', 0.0005)::jsonb);
  bord := (select id from public.orders where user_id = bob and status = 'open' order by created_at desc limit 1);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 15, ta, 'x:oc:' || bord || ':v' || ver, u + 15));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 43, 'Callback manipülasyonu: başka hesabın emir kimliğiyle iptal denenir, emir açık kalır',
    bord is not null and (select status from public.orders where id = bord) = 'open' and rep like '%Açık emir bulunamadı%',
    left(rep, 120));

  -- 44
  n0 := (select count(*) from public.telegram_order_logs);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 16, tx, 'x:mb:BTC:10:v' || ver, u + 16));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 44, 'Bağlı olmayan Telegram hesabı geçerli görünen işlem butonuyla emir veremez',
    (select count(*) from public.telegram_order_logs) = n0 and rep like '%bağlı değil%', left(rep, 100));

  -- 45
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 17, ta, '/kapat SOL'));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 45, 'Açık pozisyon yokken /kapat SOL emir oluşturmaz', rep like '%Açık SOL pozisyonun yok%', left(rep, 100));
  commit;
end $$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 5) Eşzamanlılık: dakikada 20 emir sınırı ve eşzamanlı tekrarlar (testler 46–47)
create or replace procedure cf_test.e2e_concurrency(p_run bigint) language plpgsql as $$
declare
  bob   uuid := (select id from public.profiles where username = 'tg_bob');
  carol uuid := (select id from public.profiles where username = 'tg_carol');
  tb bigint := 700000002; tc bigint := 700000003;
  u bigint := p_run * 10000 + 500;
  ids bigint[] := '{}'; req bigint[] := '{}'; i int; k int; h int; ok int; rl int; dup int;
  u0 numeric; u1 numeric; t0 timestamptz; t1 timestamptz; same jsonb;
begin
  -- 46
  u0 := (select usdt from public.accounts where user_id = bob);
  for i in 1..21 loop
    ids := ids || (u + i);
    req := req || cf_test.post_update_async(cf_test.msg(u + i, tb, '/buy DOGE 1'));
  end loop;
  t0 := clock_timestamp();
  commit;   -- pg_net 21 isteği işlem bitince birlikte, eşzamanlı gönderir
  k := cf_test.wait_done(ids, 60);
  t1 := clock_timestamp();
  h := cf_test.wait_http(req, 30);
  ok := (select count(*) from public.telegram_order_logs where user_id = bob and update_id = any(ids) and status = 'filled');
  rl := (select count(*) from public.telegram_order_logs where user_id = bob and update_id = any(ids) and result->>'code' = 'RATE_LIMIT');
  u1 := (select usdt from public.accounts where user_id = bob);
  perform cf_test.t(p_run, 46, 'Aynı anda 21 emir: 20 gerçekleşir, 21. emir dakikalık sınırla reddedilir (veritabanında atomik)',
    k = 21 and ok = 20 and rl = 1 and abs((u0 - u1) - 20) < 0.0001
    and (select count(*) from net._http_response r where r.id = any(req) and r.status_code = 200) = 21,
    format('işlenen=%s · gerçekleşen=%s · RATE_LIMIT=%s · USDT %s → %s · HTTP 200=%s/%s · hepsi %s ms içinde', k, ok, rl, u0, u1,
      (select count(*) from net._http_response r where r.id = any(req) and r.status_code = 200), h,
      round((extract(epoch from t1 - t0) * 1000)::numeric)));

  -- 47
  u0 := (select usdt from public.accounts where user_id = carol);
  ids := '{}'; req := '{}';
  same := cf_test.msg(u + 30, tc, '/buy DOGE 1');
  for i in 1..6 loop req := req || cf_test.post_update_async(same); end loop;
  ids := ids || (u + 30);
  for i in 1..6 loop
    ids := ids || (u + 40 + i);
    req := req || cf_test.post_update_async(cf_test.msg(u + 40 + i, tc, '/buy DOGE 1', null, 'private', null, u + 99));
  end loop;
  t0 := clock_timestamp();
  commit;
  k := cf_test.wait_done(ids, 60);
  h := cf_test.wait_http(req, 30);
  ok := (select count(*) from public.telegram_order_logs where user_id = carol and status = 'filled'
           and idem_key in ('m:' || tc || ':' || (u + 30), 'm:' || tc || ':' || (u + 99)));
  dup := (select count(*) from cf_test.tg_mock_calls where at >= t0 and chat_id = tc and body->>'text' like '%zaten işlenmişti%');
  u1 := (select usdt from public.accounts where user_id = carol);
  perform cf_test.t(p_run, 47, 'Eşzamanlı tekrarlar: aynı update_id 6 kez + aynı mesaj 6 farklı update_id ile → yalnızca 2 emir',
    k = 7 and ok = 2 and abs((u0 - u1) - 2) < 0.0001
    and (select count(*) from public.telegram_order_logs where user_id = carol and created_at >= t0) = 2,
    format('kayıt=%s · "zaten işlenmişti" yanıtı=%s · USDT %s → %s · HTTP yanıtı %s/12', ok, dup, u0, u1, h));
  commit;
end $$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 6) Anında işlem süresi (test 48)
create or replace procedure cf_test.e2e_latency(p_run bigint) language plpgsql as $$
declare
  tc bigint := 700000003;
  u bigint := p_run * 10000 + 600;
  k int; s int; ms numeric; filled int := 0; lg public.telegram_order_logs; up public.telegram_updates;
begin
  for k in 1..10 loop
    select x.status, x.ms into s, ms from cf_test.post_timed(cf_test.msg(u + k, tc, '/buy DOGE 1')) x;
    -- webhook yanıtı döndüğü anda emir kaydı okunur: gerçekleşmişse emir bekletilmeden, aynı istekte yürütülmüştür
    select * into lg from public.telegram_order_logs where idem_key = 'm:' || tc || ':' || (u + k);
    select * into up from public.telegram_updates where update_id = u + k;
    insert into cf_test.e2e_latency (run_id, i, ms, pre_ms, status)
    values (p_run, k, ms, round((extract(epoch from lg.created_at - up.received_at) * 1000)::numeric, 1), lg.status)
    on conflict (run_id, i) do update set ms = excluded.ms, pre_ms = excluded.pre_ms, status = excluded.status;
    if lg.status = 'filled' then filled := filled + 1; end if;
  end loop;
  perform cf_test.t(p_run, 48, 'Anında işlem: 10 ardışık /buy DOGE 1 — webhook yanıtı döndüğünde emir gerçekleşmiş, bekleme/onay yok',
    filled = 10,
    (select format('gerçekleşen %s/10 · uçtan uca (webhook → bot → DB → Telegram yanıtı) medyan %s ms, en az %s ms, en çok %s ms · bot ön işlemi medyan %s ms',
       filled, round(percentile_cont(0.5) within group (order by l.ms)::numeric), min(l.ms), max(l.ms),
       round(percentile_cont(0.5) within group (order by l.pre_ms)::numeric))
       from cf_test.e2e_latency l where l.run_id = p_run));
  commit;
end $$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 7) İzin ve bağlantı değişiklikleri, eski butonlar, bakım uçları (testler 49–59)
create or replace procedure cf_test.e2e_permissions(p_run bigint) language plpgsql as $$
declare
  alice uuid := (select id from public.profiles where username = 'tg_alice');
  bob   uuid := (select id from public.profiles where username = 'tg_bob');
  ta bigint := 700000001; tb bigint := 700000002;
  u bigint := p_run * 10000 + 700;
  url text := (select value from public.app_settings where key = 'tg_function_url');
  t0 timestamptz; s int; s2 int; s3 int; rep text; rep2 text; btn_old text; v_old int; v_new int; n0 int; code text;
  r extensions.http_response; codes text := '';
begin
  -- 49
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 1, ta, 'sb:BTC', u + 1));
  btn_old := cf_test.find_button(t0, 'x:mb:BTC:10:v');
  v_old := (select session_version from public.tg_notify where user_id = alice);
  perform cf_test.user_rpc('alice@coinforce.test', 'tg_trading_set', '{"p_on": false}');
  perform cf_test.user_rpc('alice@coinforce.test', 'tg_trading_set', '{"p_on": true}');
  v_new := (select session_version from public.tg_notify where user_id = alice);
  n0 := (select count(*) from public.telegram_order_logs where user_id = alice);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 2, ta, btn_old, u + 1));
  perform cf_test.t(p_run, 49, 'İzin kapatılıp yeniden açılınca eski mesajdaki işlem butonu emir oluşturmaz',
    btn_old = 'x:mb:BTC:10:v' || v_old and v_new = v_old + 2 and cf_test.last_alert(t0) like '%artık geçerli değil%'
    and (select count(*) from public.telegram_order_logs where user_id = alice) = n0,
    format('buton=%s · oturum sürümü %s → %s', btn_old, v_old, v_new));

  -- 50
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 3, ta, 'x:mb:BTC:10', u + 3));
  rep := cf_test.last_alert(t0);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 4, ta, 'x:mb:BTC:10:v' || (v_new + 5), u + 4));
  rep2 := cf_test.last_alert(t0);
  perform cf_test.t(p_run, 50, 'Elle üretilmiş işlem butonu (damgasız ya da yanlış sürüm) reddedilir',
    rep like '%artık geçerli değil%' and rep2 like '%artık geçerli değil%'
    and (select count(*) from public.telegram_order_logs where user_id = alice) = n0, left(rep, 90));

  -- 51
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 5, ta, 'ci:mb:BTC', u + 5));
  rep := cf_test.last_reply(t0);
  perform cf_test.user_rpc('alice@coinforce.test', 'tg_trading_set', '{"p_on": false}');
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 6, ta, '12'));
  rep2 := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 51, 'İzin kapatılınca bekleyen sohbet içi girdi geçersiz olur (sonra yazılan 12 emir oluşturmaz)',
    rep like '%Kaç USDT%' and rep2 like '%Bekleyen bir işlem yok%'
    and (select count(*) from public.telegram_order_logs where user_id = alice) = n0, left(rep2, 90));

  -- 52
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 7, ta, '/buy BTC 10'));
  rep := cf_test.last_reply(t0);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 8, ta, '/orders'));
  rep2 := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 52, 'İzin kapalıyken emir reddedilir; okuma çalışır ve işlem butonu gösterilmez',
    rep like '%izni kapalı%' and rep2 like '%Açık emirler%' and not exists (select 1 from cf_test.buttons_since(t0) b where b.data like 'x:%')
    and not exists (select 1 from public.telegram_order_logs where idem_key = 'm:' || ta || ':' || (u + 7) and status <> 'rejected'),
    left(rep, 80));

  -- 53
  r := extensions.http(('POST', url || '?run=1', array[extensions.http_header('x-cf-internal', cf_private.tg_internal_secret())],
                        'application/json', '{}')::extensions.http_request);
  perform cf_test.t(p_run, 53, 'İzin değişikliği bildirimleri iç anahtarla ?run üzerinden Telegram''a gönderilir', r.status = 200
    and exists (select 1 from cf_test.tg_mock_calls where chat_id = ta and method = 'sendMessage' and body->>'text' like '%AÇILDI%')
    and exists (select 1 from cf_test.tg_mock_calls where chat_id = ta and method = 'sendMessage' and body->>'text' like '%Bekleyen işlemler geçersiz%'),
    format('HTTP %s · %s', r.status, left(r.content, 40)));

  -- 54
  for s in select x.st from (values ('?run=1'), ('?setup=1'), ('?preview=BTC')) v(q),
                lateral (select (extensions.http(('GET', url || v.q, null, null, null)::extensions.http_request)).status st) x loop
    codes := codes || s || ' ';
  end loop;
  r := extensions.http(('GET', url || '?setup=1', array[extensions.http_header('x-cf-internal', repeat('0', 64))], null, null)::extensions.http_request);
  perform cf_test.t(p_run, 54, 'Bakım uçları (?run, ?setup, ?preview) iç anahtar olmadan ya da yanlış anahtarla 401',
    btrim(codes) = '401 401 401' and r.status = 401, 'anahtarsız: ' || btrim(codes) || ' · yanlış anahtar: ' || r.status);

  -- 55
  perform cf_test.user_rpc('alice@coinforce.test', 'tg_trading_set', '{"p_on": true}');
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 9, ta, 'sb:BTC', u + 9));
  btn_old := cf_test.find_button(t0, 'x:mb:BTC:10:v');
  select x.status into s2 from cf_test.user_rpc('alice@coinforce.test', 'tg_notify_unlink') x;
  n0 := (select count(*) from public.telegram_order_logs where user_id = alice);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 10, ta, '/buy BTC 10'));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 55, 'Uygulamadan bağlantı kaldırılınca Telegram''dan emir verilemez, izin kapanır',
    s2 in (200, 204) and rep like '%bağlı değil%'
    and (select tg_user_id is null and chat_id is null and not trading_enabled from public.tg_notify where user_id = alice)
    and (select count(*) from public.telegram_order_logs where user_id = alice) = n0, 'HTTP ' || s2 || ' · ' || left(rep, 70));

  -- 56
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 11, ta, btn_old, u + 9));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 56, 'Bağlantı kaldırıldıktan sonra eski işlem butonu emir oluşturmaz',
    rep like '%bağlı değil%' and (select count(*) from public.telegram_order_logs where user_id = alice) = n0, left(rep, 80));

  -- 57
  select (x.body::json)->>'code' into code from cf_test.user_rpc('alice@coinforce.test', 'tg_notify_code') x;
  s := cf_test.post_update(cf_test.msg(u + 12, ta, '/start ' || code));
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 13, ta, btn_old, u + 9));
  rep := cf_test.last_alert(t0);
  perform cf_test.t(p_run, 57, 'Yeniden bağlanınca izin yine kapalı başlar; bağlantı öncesi butonlar geçersiz kalır',
    (select tg_user_id = ta and not trading_enabled from public.tg_notify where user_id = alice) and rep like '%artık geçerli değil%'
    and (select count(*) from public.telegram_order_logs where user_id = alice) = n0, left(rep, 90));

  -- 58
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 14, tb, '/unlink'));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 58, 'Telegram''dan /unlink bağlantıyı ve işlem iznini kaldırır', rep like '%Bağlantı kaldırıldı%'
    and (select tg_user_id is null and not trading_enabled from public.tg_notify where user_id = bob), left(rep, 90));

  -- 59
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 15, tb, '/buy BTC 10'));
  rep := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 59, 'Bağlantısı kaldırılan hesap Telegram''dan işlem yapamaz', rep like '%bağlı değil%'
    and not exists (select 1 from public.telegram_order_logs where idem_key = 'm:' || tb || ':' || (u + 15)), left(rep, 80));
  commit;
end $$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 8) Audit log, API anahtarı izolasyonu, REST/yetki güvenlik testleri (testler 60–64)
create or replace procedure cf_test.e2e_security(p_run bigint) language plpgsql as $$
declare
  alice uuid := (select id from public.profiles where username = 'tg_alice');
  ta bigint := 700000001;
  evs text[]; need text[] := array['linked', 'link_rejected', 'not_private', 'order_denied', 'trading_on', 'trading_off',
                                   'order_executed', 'order_rejected', 'button_stale', 'unlinked_app'];
  n_pass int; n_all int; fails text;
begin
  -- 60
  select array_agg(distinct event order by event) into evs from public.telegram_audit_logs
   where user_id = alice or tg_user_id = ta or tg_user_id = 700000099;
  perform cf_test.t(p_run, 60, 'Audit log: bağlama, red, izin, emir, eski buton ve bağlantı olayları kayıtlı', evs @> need,
    format('%s olay türü: %s · eksik: %s', coalesce(array_length(evs, 1), 0), array_to_string(evs, ', '),
      coalesce((select string_agg(x, ', ') from unnest(need) x where not x = any(evs)), 'yok')));

  -- 61
  perform cf_test.t(p_run, 61, 'Audit log ve emir kayıtlarında gizli bilgi yok (token, şifre, API anahtarı)',
    not exists (select 1 from public.telegram_audit_logs a where a.detail::text ~* '(access_token|password|secret|bearer|api_key|apikey)')
    and not exists (select 1 from public.telegram_order_logs l where l.result::text ~* '(access_token|password|secret|bearer|api_key|apikey)'),
    (select count(*) || ' audit kaydı tarandı' from public.telegram_audit_logs));

  -- 62
  perform cf_test.t(p_run, 62, 'Telegram fonksiyonları API anahtarı tablolarına dokunmaz; anahtar şeması API''ye kapalı',
    not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname in ('public', 'cf_private') and (p.proname like 'tgx\_%' or p.proname like 'tgn\_%' or p.proname like 'tg\_%')
                   and p.prosrc ~* 'api_keys')
    and not has_schema_privilege('anon', 'cf_private', 'USAGE') and not has_schema_privilege('authenticated', 'cf_private', 'USAGE')
    and not exists (select 1 from pg_namespace where nspname = 'cf_private'
                      and nspname = any(string_to_array(coalesce(current_setting('pgrst.db_schemas', true), 'public,graphql_public'), ','))),
    'tg*/tgx*/tgn* fonksiyon gövdelerinde api_keys geçmiyor; cf_private şemasına anon/authenticated erişimi yok');

  -- 63 (8. test: başkasının profilini düzenleme; 403 ya da 200 [] ikisi de "değişmedi" demektir)
  with x as (
    select r.n, r.status, (
         (r.expect ~ '^[0-9]{3}$' and r.status::text = r.expect)
      or (r.expect = '200 []' and ((r.status = 200 and r.body = '[]') or r.status = 403))
      or (r.expect = '200 [1 row]' and r.status = 200 and r.body like '[{%}]')
      or (r.expect = '200 email' and r.status = 200 and r.body like '%"email":"%@%')
      or (r.expect = '200 email null' and r.status = 200 and r.body like '%"email":null%')) as pass
    from cf_test.rest_security_tests() r)
  select count(*) filter (where x.pass), count(*), string_agg(case when not x.pass then x.n || ':' || x.status end, ', ')
    into n_pass, n_all, fails from x;
  perform cf_test.t(p_run, 63, 'REST güvenlik testleri (anon ve kullanıcı JWT ile gerçek API çağrıları)', n_pass = n_all and n_all >= 17,
    format('%s/%s geçti%s', n_pass, n_all, coalesce(' · kalan: ' || fails, '')));

  -- 64
  with x as (
    select r.n, r.outcome, case r.expect
        when 'email' then r.outcome ~ '"email" : "[^"]+@'
        when 'locked' then r.outcome ~ '"locked" : true'
        when 'email null' then r.outcome ~ 'value=\{"email" : null\}$'
        else (r.outcome like r.expect || '%') or (r.expect like 'ok value=%' and r.outcome like 'ok rows=% ' || substr(r.expect, 4))
      end as pass
    from cf_test.security_tests() r)
  select count(*) filter (where x.pass), count(*), string_agg(case when not x.pass then x.n || ':' || left(x.outcome, 40) end, ', ')
    into n_pass, n_all, fails from x;
  perform cf_test.t(p_run, 64, 'Veritabanı yetki testleri (profiles RLS, is_admin, email_for_login, iç anahtar, kilitleme)',
    n_pass = n_all and n_all >= 21, format('%s/%s geçti%s', n_pass, n_all, coalesce(' · kalan: ' || fails, '')));
  commit;
end $$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 9) Toplu işlem: uygulamadan eklenen API anahtarlarıyla aynı anda emir (migration 77, testler 65–72)
create or replace procedure cf_test.e2e_group(p_run bigint) language plpgsql as $$
declare
  alice uuid := (select id from public.profiles where username = 'tg_alice');
  bob   uuid := (select id from public.profiles where username = 'tg_bob');
  carol uuid := (select id from public.profiles where username = 'tg_carol');
  ta bigint := 700000001; u bigint := p_run * 10000 + 950;
  ak text; asec text; bk text; bs text; ck text; cs text; r1 json; r2 json; r3 json; g json; s int; v text;
  t0 timestamptz; a0 numeric; b0 numeric; c0 numeric; a1 numeric; b1 numeric; c1 numeric;
  idem text; lid uuid; ok boolean; k int; pa uuid; pb uuid; pc uuid;
begin
  -- Hazırlık: alice'in işlem izni açık, toplu işlemi kapalı ve önceki koşulardan kalan bağlantısı yok
  perform cf_test.user_rpc('alice@coinforce.test', 'tg_trading_set', '{"p_on": true}');
  perform cf_test.user_rpc('alice@coinforce.test', 'tg_group_set', '{"p_on": false}');
  for lid in select id from public.tg_group_links where owner_id = alice and revoked_at is null loop
    perform cf_test.user_rpc('alice@coinforce.test', 'tg_group_remove', jsonb_build_object('p_id', lid));
  end loop;
  select (x.body::json)->>'api_key' into ak from cf_test.user_rpc('alice@coinforce.test', 'my_api_keys') x;
  select (x.body::json)->>'secret' into asec from cf_test.user_rpc('alice@coinforce.test', 'my_api_secret') x;
  select (x.body::json)->>'api_key' into bk from cf_test.user_rpc('bob@coinforce.test', 'my_api_keys') x;
  select (x.body::json)->>'secret' into bs from cf_test.user_rpc('bob@coinforce.test', 'my_api_secret') x;
  select (x.body::json)->>'api_key' into ck from cf_test.user_rpc('carol@coinforce.test', 'my_api_keys') x;
  select (x.body::json)->>'secret' into cs from cf_test.user_rpc('carol@coinforce.test', 'my_api_secret') x;

  -- 65
  select x.body::json into r1 from cf_test.user_rpc('alice@coinforce.test', 'tg_group_add', jsonb_build_object('p_api_key', bk, 'p_secret', 'yanlis-secret')) x;
  select x.body::json into r2 from cf_test.user_rpc('alice@coinforce.test', 'tg_group_add', jsonb_build_object('p_api_key', ak, 'p_secret', asec)) x;
  select x.status into s from cf_test.rest('POST', '/rest/v1/rpc/tg_group_add', null, jsonb_build_object('p_api_key', bk, 'p_secret', bs)::text) x;
  perform cf_test.t(p_run, 65, 'Toplu işlem: yanlış Secret, kendi anahtarı ve anonim çağrı reddedilir; bağlantı oluşmaz',
    not (r1->>'ok')::boolean and r1->>'error' like '%hatalı%' and not (r2->>'ok')::boolean and r2->>'error' like '%kendi%'
    and s in (401, 403) and not exists (select 1 from public.tg_group_links where owner_id = alice and revoked_at is null),
    format('yanlış secret: %s · kendi anahtarı: %s · anonim: HTTP %s', r1->>'error', r2->>'error', s));

  -- 66
  t0 := clock_timestamp();
  select x.body::json into r1 from cf_test.user_rpc('alice@coinforce.test', 'tg_group_add', jsonb_build_object('p_api_key', bk, 'p_secret', bs)) x;
  select x.body::json into r2 from cf_test.user_rpc('alice@coinforce.test', 'tg_group_add', jsonb_build_object('p_api_key', ck, 'p_secret', cs)) x;
  perform cf_test.t(p_run, 66, 'Doğru API Key + Secret ile hesap eklenir; Secret saklanmaz; eklenen hesabın sahibine Telegram uyarısı gider',
    coalesce((r1->>'ok')::boolean, false) and r1->>'username' = 'tg_bob' and coalesce((r2->>'ok')::boolean, false) and r2->>'username' = 'tg_carol'
    and (select count(*) from public.tg_group_links where owner_id = alice and revoked_at is null) = 2
    and not exists (select 1 from information_schema.columns where table_name = 'tg_group_links' and column_name ~* '(secret|api_key)')
    and exists (select 1 from public.tg_outbox o join public.tg_notify nn on nn.chat_id = o.chat_id and nn.user_id = carol
                 where o.created_at >= t0 and o.body like '%toplu işlemine eklendi%'),
    format('eklenen: @%s, @%s · aktif bağlantı: %s', r1->>'username', r2->>'username',
           (select count(*) from public.tg_group_links where owner_id = alice and revoked_at is null)));

  -- 67
  idem := 'm:' || ta || ':' || (u + 1);
  s := cf_test.post_update(cf_test.msg(u + 1, ta, '/buy BTC 2'));
  perform cf_test.t(p_run, 67, 'Toplu işlem kapalıyken emir yalnızca kendi hesabında gerçekleşir',
    (select status from public.telegram_order_logs where idem_key = idem) = 'filled'
    and not exists (select 1 from public.telegram_order_logs where idem_key like idem || ':%'),
    format('kendi hesabı: %s · diğer hesap kaydı: %s', (select status from public.telegram_order_logs where idem_key = idem),
           (select count(*) from public.telegram_order_logs where idem_key like idem || ':%')));

  -- 68
  select x.body::json into r1 from cf_test.user_rpc('alice@coinforce.test', 'tg_group_set', '{"p_on": true}') x;
  select usdt into a0 from public.accounts where user_id = alice;
  select usdt into b0 from public.accounts where user_id = bob;
  select usdt into c0 from public.accounts where user_id = carol;
  idem := 'm:' || ta || ':' || (u + 2);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 2, ta, '/buy BTC 5'));
  select usdt into a1 from public.accounts where user_id = alice;
  select usdt into b1 from public.accounts where user_id = bob;
  select usdt into c1 from public.accounts where user_id = carol;
  ok := false;
  for k in 1..40 loop
    select body->>'text' into v from cf_test.tg_mock_calls
     where chat_id = ta and method = 'sendMessage' and at >= t0 and body->>'text' like '%hesapta gerçekleşti%' order by id desc limit 1;
    ok := coalesce(v like '%3/3 hesapta%', false);
    exit when ok;
    perform pg_sleep(0.25);
  end loop;
  perform cf_test.t(p_run, 68, 'Toplu işlem açıkken /buy BTC 5 üç hesapta aynı anda gerçekleşir; özet Telegram''a gelir',
    (r1->>'members')::int = 2 and s = 200
    and (select count(*) from public.telegram_order_logs where (idem_key = idem or idem_key like idem || ':%') and status = 'filled') = 3
    and a0 - a1 = 5 and b0 - b1 = 5 and c0 - c1 = 5 and ok,
    format('USDT düşüşü: alice %s · bob %s · carol %s · özet: %s', a0 - a1, b0 - b1, c0 - c1, coalesce(left(replace(v, E'\n', ' | '), 200), 'yok')));

  -- 69
  idem := 'm:' || ta || ':' || (u + 3);
  s := cf_test.post_update(cf_test.msg(u + 3, ta, '/long ETH 5 2x'));
  select ref_id into pa from public.telegram_order_logs where idem_key = idem;
  select ref_id into pb from public.telegram_order_logs where idem_key = idem || ':' || bob::text;
  select ref_id into pc from public.telegram_order_logs where idem_key = idem || ':' || carol::text;
  s := cf_test.post_update(cf_test.msg(u + 4, ta, '/close ETH'));
  perform cf_test.t(p_run, 69, 'Vadeli: /long ETH 5 2x üç hesapta açılır; /close ETH aynı toplu işlemle açılan pozisyonları kapatır',
    pa is not null and pb is not null and pc is not null
    and (select count(*) from public.positions where id in (pa, pb, pc) and status <> 'open') = 3,
    format('açılan: %s · kapanan: %s', (select count(*) from public.positions where id in (pa, pb, pc)),
           (select count(*) from public.positions where id in (pa, pb, pc) and status <> 'open')));

  -- 70
  perform cf_test.user_rpc('bob@coinforce.test', 'my_api_regenerate');
  idem := 'm:' || ta || ':' || (u + 5);
  s := cf_test.post_update(cf_test.msg(u + 5, ta, '/buy BTC 2'));
  -- user_rpc uzun yanıtı kestiği için liste doğrudan, kullanıcının oturumuyla okunur
  perform set_config('request.jwt.claims', json_build_object('sub', alice, 'role', 'authenticated')::text, true);
  g := public.tg_group_list();
  perform cf_test.t(p_run, 70, 'Eklenen hesap API anahtarını yenileyince gruptan düşer; emir onun hesabında gerçekleşmez',
    (select status from public.telegram_order_logs where idem_key = idem) = 'filled'
    and not exists (select 1 from public.telegram_order_logs where idem_key = idem || ':' || bob::text)
    and (select status from public.telegram_order_logs where idem_key = idem || ':' || carol::text) = 'filled'
    and exists (select 1 from json_array_elements(g->'members') e where e->>'username' = 'tg_bob' and not (e->>'active')::boolean),
    format('alice: %s · bob: %s · carol: %s', (select status from public.telegram_order_logs where idem_key = idem),
           coalesce((select status from public.telegram_order_logs where idem_key = idem || ':' || bob::text), 'yok'),
           (select status from public.telegram_order_logs where idem_key = idem || ':' || carol::text)));

  -- 71
  perform set_config('request.jwt.claims', json_build_object('sub', carol, 'role', 'authenticated')::text, true);
  g := public.tg_group_list();
  perform set_config('request.jwt.claims', '', true);
  lid := (select (e->>'id')::uuid from json_array_elements(g->'controllers') e where e->>'username' = 'tg_alice' limit 1);
  select x.body::json into r3 from cf_test.user_rpc('bob@coinforce.test', 'tg_group_remove', jsonb_build_object('p_id', lid)) x;
  select x.body::json into r1 from cf_test.user_rpc('carol@coinforce.test', 'tg_group_remove', jsonb_build_object('p_id', lid)) x;
  idem := 'm:' || ta || ':' || (u + 6);
  s := cf_test.post_update(cf_test.msg(u + 6, ta, '/buy BTC 2'));
  perform cf_test.t(p_run, 71, 'Eklenen hesabın sahibi bağlantıyı kendisi kaldırabilir; sonraki emir onun hesabında gerçekleşmez',
    lid is not null and coalesce((r1->>'ok')::boolean, false)
    and (select status from public.telegram_order_logs where idem_key = idem) = 'filled'
    and not exists (select 1 from public.telegram_order_logs where idem_key like idem || ':%'),
    format('bağlantı bulundu: %s · kaldırma: %s · sonraki emirde diğer hesap kaydı: %s', lid is not null, r1->>'ok',
           (select count(*) from public.telegram_order_logs where idem_key like idem || ':%')));

  -- 72
  select x.status, x.body into s, v from cf_test.rest('GET', '/rest/v1/tg_group_links?select=id', cf_test.token('bob@coinforce.test')) x;
  perform cf_test.t(p_run, 72, 'Başkasının bağlantısı kaldırılamaz; tg_group_links tablosu API''den okunamaz',
    not coalesce((r3->>'ok')::boolean, false) and (s in (401, 403, 404) or v = '[]'),
    format('başkası kaldırmayı denedi: %s · tablo okuma: HTTP %s %s', coalesce(r3->>'error', '?'), s, left(coalesce(v, ''), 60)));

  perform cf_test.user_rpc('alice@coinforce.test', 'tg_group_set', '{"p_on": false}');
  commit;
end $$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 10) /accounts (/hesaplar) komutu (migration 78, testler 73–74)
create or replace procedure cf_test.e2e_accounts(p_run bigint) language plpgsql as $$
declare
  ta bigint := 700000001; u bigint := p_run * 10000 + 980;
  ck text; cs text; r1 json; s int; t0 timestamptz; rep text; rep2 text; hlp text; okb boolean;
begin
  perform cf_test.user_rpc('alice@coinforce.test', 'tg_trading_set', '{"p_on": true}');
  select (x.body::json)->>'api_key' into ck from cf_test.user_rpc('carol@coinforce.test', 'my_api_keys') x;
  select (x.body::json)->>'secret' into cs from cf_test.user_rpc('carol@coinforce.test', 'my_api_secret') x;
  select x.body::json into r1 from cf_test.user_rpc('alice@coinforce.test', 'tg_group_add', jsonb_build_object('p_api_key', ck, 'p_secret', cs)) x;
  perform cf_test.user_rpc('alice@coinforce.test', 'tg_group_set', '{"p_on": true}');

  -- 73
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 1, ta, '/accounts'));
  rep := cf_test.last_reply(t0);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 2, ta, '/hesaplar'));
  rep2 := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 73, '/accounts ve /hesaplar: kendi hesabın + toplu işlemde aktif hesaplar bakiyeleriyle, pasif hesaplar ayrı gösterilir',
    coalesce((r1->>'ok')::boolean, false) and rep like '%İşlem yapabildiğin hesaplar%' and rep like '%@tg_alice (sen)%'
    and rep like '%@tg_carol%kullanılabilir%' and rep like '%Pasif%@tg_bob%' and rep like '%2 hesapta aynı anda%'
    and rep2 like '%İşlem yapabildiğin hesaplar%',
    left(replace(rep, E'\n', ' | '), 260));

  -- 74
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.cbq(u + 3, ta, 'ac', u + 1));
  rep := cf_test.last_reply(t0);
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 4, ta, '/menu'));
  okb := cf_test.has_button(t0, 'ac');
  t0 := clock_timestamp();
  s := cf_test.post_update(cf_test.msg(u + 5, ta, '/help'));
  hlp := cf_test.last_reply(t0);
  perform cf_test.t(p_run, 74, 'Ana menüdeki Hesaplar butonu, Yenile butonu ve /help satırı çalışır',
    rep like '%İşlem yapabildiğin hesaplar%' and okb and hlp like '%/accounts%',
    format('yenile: %s · menü butonu: %s · yardım: %s', rep like '%İşlem yapabildiğin%', okb, hlp like '%/accounts%'));

  perform cf_test.user_rpc('alice@coinforce.test', 'tg_group_set', '{"p_on": false}');
  commit;
end $$;
