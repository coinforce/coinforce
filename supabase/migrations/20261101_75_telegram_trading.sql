-- coinforce_75_telegram_trading
-- Telegram link v2 (verified Telegram user, one Telegram account per COINFORCE account,
-- trading permission off by default), order/audit/update logs and the tgx_* RPC layer.
-- The tgx_* functions are callable only by the service role (the telegram-notify edge function).
-- They resolve the account from the verified Telegram link and call the EXISTING engine
-- functions (market_trade, place_order, cancel_order, open_position, close_position) unchanged.
-- Additive only: no table, column or row is removed.

-- 1) tg_notify: Telegram identity, trading permission, session version, conversation state ----
alter table public.tg_notify add column if not exists tg_user_id bigint;
alter table public.tg_notify add column if not exists tg_username text;
alter table public.tg_notify add column if not exists trading_enabled boolean not null default false;
alter table public.tg_notify add column if not exists trading_changed_at timestamptz;
alter table public.tg_notify add column if not exists session_version integer not null default 1;
alter table public.tg_notify add column if not exists state jsonb;
alter table public.tg_notify add column if not exists state_version integer;
alter table public.tg_notify add column if not exists state_at timestamptz;

-- Existing links made from a private chat: there the chat id is the Telegram user id.
update public.tg_notify set tg_user_id = chat_id where chat_id > 0 and tg_user_id is null;

create unique index if not exists tg_notify_tg_user_uniq on public.tg_notify (tg_user_id) where tg_user_id is not null;
create unique index if not exists tg_notify_chat_uniq on public.tg_notify (chat_id) where chat_id is not null;

-- 2) Logs ---------------------------------------------------------------------------------------
create table if not exists public.telegram_order_logs (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  user_id uuid not null references auth.users(id) on delete cascade,
  tg_user_id bigint not null,
  idem_key text not null unique,
  update_id bigint,
  kind text not null check (kind in ('spot_market','spot_limit','spot_stop','futures_open','futures_close','order_cancel')),
  symbol text,
  side text,
  amount_usd numeric,
  qty numeric,
  price numeric,
  leverage integer,
  ref_id uuid,
  status text not null default 'executing' check (status in ('executing','filled','open','opened','closed','cancelled','rejected')),
  counted boolean not null default false,
  error text,
  result jsonb
);
create index if not exists telegram_order_logs_rate on public.telegram_order_logs (user_id, created_at desc) where counted;
create index if not exists telegram_order_logs_user on public.telegram_order_logs (user_id, created_at desc);
alter table public.telegram_order_logs enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'telegram_order_logs' and policyname = 'kendi telegram emirleri') then
    create policy "kendi telegram emirleri" on public.telegram_order_logs for select to authenticated using (user_id = auth.uid());
  end if;
end $$;

create table if not exists public.telegram_audit_logs (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  tg_user_id bigint,
  user_id uuid references auth.users(id) on delete set null,
  update_id bigint,
  event text not null,
  detail jsonb
);
create index if not exists telegram_audit_logs_user on public.telegram_audit_logs (user_id, at desc);
create index if not exists telegram_audit_logs_tg on public.telegram_audit_logs (tg_user_id, at desc);
alter table public.telegram_audit_logs enable row level security;

create table if not exists public.telegram_updates (
  update_id bigint primary key,
  tg_user_id bigint,
  received_at timestamptz not null default now()
);
create index if not exists telegram_updates_user on public.telegram_updates (tg_user_id, received_at desc);
alter table public.telegram_updates enable row level security;

-- 3) Internal helpers (not reachable through the API) ------------------------------------------
create or replace function cf_private.tg_audit(p_tg bigint, p_user uuid, p_update bigint, p_event text, p_detail jsonb default null)
returns void language sql security definer
set search_path = ''
as $$
  insert into public.telegram_audit_logs (tg_user_id, user_id, update_id, event, detail)
  values (p_tg, p_user, p_update, p_event, p_detail);
$$;

-- Makes auth.uid() return u for the rest of the current transaction, so the existing
-- engine functions run exactly as if the user had called them from the app.
create or replace function cf_private.tg_act_as(u uuid)
returns void language plpgsql security definer
set search_path = ''
as $$
begin
  perform set_config('request.jwt.claim.sub', u::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
end $$;

create or replace function cf_private.tg_order_json(lg public.telegram_order_logs, p_dup boolean)
returns json language sql stable security definer
set search_path = ''
as $$
  select json_build_object(
    'ok', lg.status <> 'rejected', 'duplicate', p_dup, 'log_id', lg.id, 'kind', lg.kind, 'status', lg.status,
    'symbol', lg.symbol, 'side', lg.side, 'code', case when lg.status = 'rejected' then coalesce(lg.result->>'code', 'ENGINE') end,
    'error', lg.error, 'result', lg.result, 'at', lg.created_at);
$$;

-- 4) Link, unlink, permission ------------------------------------------------------------------
create or replace function public.tg_notify_code()
returns json language plpgsql security definer
set search_path to 'public'
as $$
declare u uuid := auth.uid(); c text;
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  c := upper(substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 10));
  insert into public.tg_notify(user_id, link_code, code_exp) values (u, c, now() + interval '5 minutes')
  on conflict (user_id) do update set link_code = excluded.link_code, code_exp = excluded.code_exp;
  return json_build_object('code', c, 'bot', (select value from public.app_settings where key = 'tg_bot'), 'expires_in', 300);
end $$;

create or replace function public.tg_notify_get()
returns json language sql stable security definer
set search_path to 'public'
as $$
  select json_build_object(
    'linked', n.chat_id is not null, 'alerts', coalesce(n.alerts, true), 'daily', coalesce(n.daily, true),
    'daily_hour', coalesce(n.daily_hour, 21), 'news', coalesce(n.news, false),
    'bot', (select value from public.app_settings where key = 'tg_bot'),
    'tg_username', n.tg_username, 'linked_at', n.linked_at,
    'trading', coalesce(n.trading_enabled, false) and n.tg_user_id is not null,
    'can_trade', n.tg_user_id is not null)
  from (select auth.uid() u) x left join public.tg_notify n on n.user_id = x.u;
$$;

create or replace function public.tg_notify_unlink()
returns void language plpgsql security definer
set search_path to 'public'
as $$
declare u uuid := auth.uid(); n public.tg_notify;
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  select * into n from public.tg_notify where user_id = u for update;
  update public.tg_notify set chat_id = null, linked_at = null, link_code = null, code_exp = null,
    tg_user_id = null, tg_username = null, trading_enabled = false, trading_changed_at = now(),
    session_version = session_version + 1, state = null
  where user_id = u;
  if n.chat_id is not null then
    insert into public.tg_outbox(chat_id, body) values (n.chat_id, '🔌 Telegram bağlantın COINFORCE uygulamasından kaldırıldı.');
    perform cf_private.tg_audit(n.tg_user_id, u, null, 'unlinked_app');
  end if;
end $$;

-- Trading permission can only be changed from the app (authenticated RPC).
create or replace function public.tg_trading_set(p_on boolean)
returns json language plpgsql security definer
set search_path to 'public'
as $$
declare u uuid := auth.uid(); n public.tg_notify;
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  select * into n from public.tg_notify where user_id = u for update;
  if n.chat_id is null or n.tg_user_id is null then raise exception 'Önce Telegram hesabını bağla'; end if;
  update public.tg_notify set trading_enabled = coalesce(p_on, false), trading_changed_at = now(),
    session_version = session_version + 1, state = null
  where user_id = u;
  insert into public.tg_outbox(chat_id, body) values (n.chat_id,
    case when p_on then '🔓 Telegram''dan işlem izni COINFORCE uygulamasından AÇILDI. Bu işlemi sen yapmadıysan hemen uygulamadan kapat ve şifreni değiştir.'
         else '🔒 Telegram''dan işlem izni kapatıldı. Bekleyen işlemler geçersiz sayıldı.' end);
  perform cf_private.tg_audit(n.tg_user_id, u, null, case when p_on then 'trading_on' else 'trading_off' end);
  return json_build_object('trading', coalesce(p_on, false));
end $$;
revoke all on function public.tg_trading_set(boolean) from public, anon;
grant execute on function public.tg_trading_set(boolean) to authenticated, service_role;

-- Bot side: link with a single-use code, only from a private chat, verified Telegram user id.
create or replace function public.tgx_link(p_tg_user bigint, p_chat bigint, p_chat_type text, p_tg_username text, p_code text, p_update bigint default null)
returns json language plpgsql security definer
set search_path = ''
as $$
declare r public.tg_notify; c text := upper(btrim(coalesce(p_code, '')));
begin
  if p_tg_user is null or p_chat_type is distinct from 'private' or p_chat is distinct from p_tg_user then
    perform cf_private.tg_audit(p_tg_user, null, p_update, 'link_rejected', jsonb_build_object('reason', 'not_private'));
    return json_build_object('ok', false, 'error', 'Bağlantı yalnızca botla özel sohbetten yapılabilir.');
  end if;
  if c !~ '^[0-9A-F]{10}$' then
    perform cf_private.tg_audit(p_tg_user, null, p_update, 'link_rejected', jsonb_build_object('reason', 'bad_format'));
    return json_build_object('ok', false, 'error', 'Kod geçersiz ya da süresi dolmuş. Uygulamadan yeni bir kod oluştur.');
  end if;
  select * into r from public.tg_notify where link_code = c and code_exp > now() for update;
  if r.user_id is null then
    perform cf_private.tg_audit(p_tg_user, null, p_update, 'link_rejected', jsonb_build_object('reason', 'bad_code'));
    return json_build_object('ok', false, 'error', 'Kod geçersiz ya da süresi dolmuş. Uygulamadan yeni bir kod oluştur.');
  end if;
  if exists (select 1 from public.tg_notify where (tg_user_id = p_tg_user or chat_id = p_chat) and user_id <> r.user_id) then
    perform cf_private.tg_audit(p_tg_user, r.user_id, p_update, 'link_rejected', jsonb_build_object('reason', 'tg_linked_elsewhere'));
    return json_build_object('ok', false, 'error', 'Bu Telegram hesabı başka bir COINFORCE hesabına bağlı. Önce o hesaptan bağlantıyı kaldır.');
  end if;
  update public.tg_notify set chat_id = p_chat, tg_user_id = p_tg_user, tg_username = left(p_tg_username, 64),
    linked_at = now(), link_code = null, code_exp = null, trading_enabled = false, trading_changed_at = now(),
    session_version = session_version + 1, state = null, last_daily = (now() at time zone 'Europe/Istanbul')::date
  where user_id = r.user_id;
  perform cf_private.tg_audit(p_tg_user, r.user_id, p_update,
    case when r.tg_user_id is not null and r.tg_user_id <> p_tg_user then 'relinked' else 'linked' end,
    jsonb_build_object('tg_username', p_tg_username));
  return json_build_object('ok', true, 'username', (select username from public.profiles where id = r.user_id));
end $$;

create or replace function public.tgx_unlink(p_tg_user bigint, p_update bigint default null)
returns json language plpgsql security definer
set search_path = ''
as $$
declare n public.tg_notify;
begin
  select * into n from public.tg_notify where tg_user_id = p_tg_user for update;
  if n.user_id is null then return json_build_object('ok', false); end if;
  update public.tg_notify set chat_id = null, linked_at = null, link_code = null, code_exp = null,
    tg_user_id = null, tg_username = null, trading_enabled = false, trading_changed_at = now(),
    session_version = session_version + 1, state = null
  where user_id = n.user_id;
  perform cf_private.tg_audit(p_tg_user, n.user_id, p_update, 'unlinked_bot');
  return json_build_object('ok', true);
end $$;

-- Webhook replay guard + per-Telegram-user flood limit (60 updates per minute).
create or replace function public.tgx_seen_update(p_update_id bigint, p_tg_user bigint)
returns text language plpgsql security definer
set search_path = ''
as $$
declare k int;
begin
  insert into public.telegram_updates (update_id, tg_user_id) values (p_update_id, p_tg_user) on conflict do nothing;
  if not found then return 'dup'; end if;
  if p_tg_user is not null then
    select count(*) into k from public.telegram_updates where tg_user_id = p_tg_user and received_at > now() - interval '60 seconds';
    if k > 60 then return 'limited'; end if;
  end if;
  return 'ok';
end $$;

create or replace function public.tgx_me(p_tg_user bigint)
returns json language sql stable security definer
set search_path = ''
as $$
  select case when n.user_id is null then json_build_object('linked', false)
    else json_build_object('linked', true, 'username', p.username, 'trading', n.trading_enabled,
      'session_version', n.session_version,
      'state', case when n.state_version = n.session_version and n.state_at > now() - interval '10 minutes' then n.state end,
      'alerts', n.alerts, 'daily', n.daily, 'news', n.news, 'linked_at', n.linked_at) end
  from (select 1) x
  left join public.tg_notify n on n.tg_user_id = p_tg_user and n.chat_id is not null
  left join public.profiles p on p.id = n.user_id;
$$;

create or replace function public.tgx_state_set(p_tg_user bigint, p_state jsonb)
returns void language sql security definer
set search_path = ''
as $$
  update public.tg_notify set state = p_state, state_version = session_version, state_at = now()
  where tg_user_id = p_tg_user and chat_id is not null;
$$;

-- 5) Read RPCs --------------------------------------------------------------------------------
create or replace function public.tgx_price(p_symbol text)
returns json language sql stable security definer
set search_path = ''
as $$
  select case when p.symbol is null then null else json_build_object(
    'symbol', p.symbol, 'name', p.name, 'price', p.price, 'open_24h', p.open_24h,
    'change_pct', case when coalesce(p.open_24h, 0) > 0 then round((p.price / p.open_24h - 1) * 100, 2) end,
    'high_24h', p.high_24h, 'low_24h', p.low_24h, 'listed', coalesce(p.listed, false),
    'custom', exists (select 1 from public.custom_coins c where c.symbol = p.symbol),
    'max_leverage', p.max_leverage, 'updated_at', p.updated_at,
    'age_s', floor(extract(epoch from now() - p.updated_at))) end
  from (select 1) x left join public.prices p on p.symbol = upper(btrim(coalesce(p_symbol, '')));
$$;

create or replace function public.tgx_pairs(p_tg_user bigint default null, p_limit integer default 12)
returns json language sql stable security definer
set search_path = ''
as $$
  with u as (select user_id from public.tg_notify where tg_user_id = p_tg_user and chat_id is not null),
  mine as (select h.symbol, h.qty * pr.price v from public.holdings h join public.prices pr using (symbol)
           where h.user_id = (select user_id from u) and h.qty * pr.price >= 1 order by v desc limit 6),
  top as (select symbol from public.prices where coalesce(listed, false) and symbol not in (select symbol from mine)
          order by market_cap desc nulls last limit greatest(0, least(p_limit, 24) - (select count(*) from mine)))
  select json_build_object('mine', coalesce((select json_agg(symbol order by v desc) from mine), '[]'::json),
                           'top', coalesce((select json_agg(symbol) from top), '[]'::json));
$$;

create or replace function public.tgx_balance(p_tg_user bigint)
returns json language plpgsql stable security definer
set search_path = ''
as $$
declare u uuid; a public.accounts; r json;
begin
  select user_id into u from public.tg_notify where tg_user_id = p_tg_user and chat_id is not null;
  if u is null then return json_build_object('linked', false); end if;
  select * into a from public.accounts where user_id = u;
  select json_build_object(
    'linked', true,
    'username', (select username from public.profiles where id = u),
    'usdt', coalesce(a.usdt, 0), 'cf', coalesce(a.cf, 0),
    'equity', round(public._equity(u), 2),
    'spot', coalesce((select json_agg(json_build_object('symbol', h.symbol, 'qty', h.qty, 'price', pr.price,
                       'value', round(h.qty * pr.price, 2), 'pnl', round(h.qty * pr.price - h.cost, 2)) order by h.qty * pr.price desc)
                      from public.holdings h join public.prices pr using (symbol) where h.user_id = u and h.qty > 0), '[]'::json),
    'spot_value', coalesce((select round(sum(h.qty * pr.price), 2) from public.holdings h join public.prices pr using (symbol) where h.user_id = u), 0),
    'orders_reserved', coalesce((select round(sum(o.reserved_usdt), 2) from public.orders o where o.user_id = u and o.status = 'open' and o.side = 'buy'), 0),
    'margin_used', coalesce((select round(sum(ps.margin), 2) from public.positions ps where ps.user_id = u and ps.status = 'open'), 0),
    'unrealized', coalesce((select round(sum(ps.side * (pr.price - ps.entry_price) * ps.qty), 2)
                            from public.positions ps join public.prices pr using (symbol) where ps.user_id = u and ps.status = 'open'), 0),
    'open_orders', (select count(*) from public.orders o where o.user_id = u and o.status = 'open'),
    'open_positions', (select count(*) from public.positions ps where ps.user_id = u and ps.status = 'open')
  ) into r;
  return r;
end $$;

create or replace function public.tgx_orders(p_tg_user bigint)
returns json language sql stable security definer
set search_path = ''
as $$
  select case when u.user_id is null then json_build_object('linked', false) else json_build_object('linked', true, 'orders',
    coalesce((select json_agg(json_build_object('id', o.id, 'symbol', o.symbol, 'side', o.side, 'type', o.type,
              'trigger_price', o.trigger_price, 'qty', o.qty, 'reserved_usdt', o.reserved_usdt, 'price', pr.price,
              'created_at', o.created_at) order by o.created_at desc)
              from public.orders o join public.prices pr using (symbol) where o.user_id = u.user_id and o.status = 'open'), '[]'::json)) end
  from (select 1) x left join public.tg_notify u on u.tg_user_id = p_tg_user and u.chat_id is not null;
$$;

create or replace function public.tgx_positions(p_tg_user bigint)
returns json language sql stable security definer
set search_path = ''
as $$
  select case when u.user_id is null then json_build_object('linked', false) else json_build_object('linked', true, 'positions',
    coalesce((select json_agg(json_build_object('id', ps.id, 'symbol', ps.symbol, 'side', ps.side, 'leverage', ps.leverage,
              'margin', ps.margin, 'entry_price', ps.entry_price, 'qty', ps.qty, 'liq_price', ps.liq_price, 'mark', pr.price,
              'unrealized', round(ps.side * (pr.price - ps.entry_price) * ps.qty, 2),
              'roe_pct', round(ps.side * (pr.price - ps.entry_price) * ps.qty / nullif(ps.margin, 0) * 100, 2),
              'created_at', ps.created_at) order by ps.created_at desc)
              from public.positions ps join public.prices pr using (symbol) where ps.user_id = u.user_id and ps.status = 'open'), '[]'::json)) end
  from (select 1) x left join public.tg_notify u on u.tg_user_id = p_tg_user and u.chat_id is not null;
$$;

create or replace function public.tgx_history(p_tg_user bigint, p_limit integer default 10)
returns json language sql stable security definer
set search_path = ''
as $$
  select case when u.user_id is null then json_build_object('linked', false) else json_build_object('linked', true, 'items',
    coalesce((select json_agg(t order by t.created_at desc) from (
      select x.kind, x.symbol, x.qty, x.price, x.amount_usd, x.note, x.created_at from public.transactions x
       where x.user_id = u.user_id order by x.created_at desc limit least(greatest(coalesce(p_limit, 10), 1), 25)) t), '[]'::json)) end
  from (select 1) x left join public.tg_notify u on u.tg_user_id = p_tg_user and u.chat_id is not null;
$$;

-- 6) Order entry point ------------------------------------------------------------------------
-- p_kind: spot_market (p_side buy: p_amount USDT | sell: p_qty or p_pct of holdings),
--         spot_limit / spot_stop (p_side, p_qty, p_price), futures_open (p_side long|short, p_amount margin, p_leverage),
--         futures_close (p_ref position id), order_cancel (p_ref order id).
-- Rules: linked + trading permission, 20 new orders per 60 s per account (atomic), idempotency on p_idem,
--        price younger than 120 s (COINFORCE bonding-curve coins price on the curve), minimum 1 USDT, balance.
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
  is_new boolean := p_kind in ('spot_market','spot_limit','spot_stop','futures_open','futures_close');
  cnt int; bal numeric; have numeric; a numeric; q numeric; px numeric; lev int; sd int; fee numeric;
  is_custom boolean := false; res json; rid uuid; st text; v_err text; v_code text; v_pnl numeric;
begin
  if p_idem is null or length(p_idem) < 3 or length(p_idem) > 128 then raise exception 'invalid idempotency key'; end if;
  if p_kind not in ('spot_market','spot_limit','spot_stop','futures_open','futures_close','order_cancel') then raise exception 'invalid kind'; end if;

  select * into lg from public.telegram_order_logs where idem_key = p_idem;
  if lg.id is not null then return cf_private.tg_order_json(lg, true); end if;

  select * into n from public.tg_notify where tg_user_id = p_tg_user and chat_id is not null;
  if n.user_id is null then
    perform cf_private.tg_audit(p_tg_user, null, p_update, 'order_denied', jsonb_build_object('reason', 'not_linked', 'kind', p_kind));
    return json_build_object('ok', false, 'code', 'NOT_LINKED', 'error', 'Bu Telegram hesabı bir COINFORCE hesabına bağlı değil.');
  end if;
  u := n.user_id;

  -- One Telegram order at a time per account: makes the rate limit and idempotency atomic.
  perform pg_advisory_xact_lock(hashtextextended('tgx-order:' || u::text, 0));
  select * into lg from public.telegram_order_logs where idem_key = p_idem;
  if lg.id is not null then return cf_private.tg_order_json(lg, true); end if;

  select * into n from public.tg_notify where user_id = u for share;
  if not coalesce(n.trading_enabled, false) or n.tg_user_id is distinct from p_tg_user or n.chat_id is null then
    perform cf_private.tg_audit(p_tg_user, u, p_update, 'order_denied', jsonb_build_object('reason', 'trading_off', 'kind', p_kind));
    return json_build_object('ok', false, 'code', 'TRADING_OFF',
      'error', 'Telegram''dan işlem izni kapalı. COINFORCE uygulamasında Ayarlar › Telegram bildirimleri bölümünden açabilirsin.');
  end if;
  if exists (select 1 from auth.users where id = u and banned_until > now()) then
    perform cf_private.tg_audit(p_tg_user, u, p_update, 'order_denied', jsonb_build_object('reason', 'banned', 'kind', p_kind));
    return json_build_object('ok', false, 'code', 'BANNED', 'error', 'Hesabın işleme kapalı.');
  end if;

  -- Validation (the engine re-checks everything; these give clear messages and the extra Telegram rules)
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
        if q is null or q <= 0 then v_code := 'AMOUNT'; v_err := 'Geçerli bir miktar gir.';
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

  -- Run the existing engine function as the user.
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
      res := json_build_object('order_id', rid, 'status', od.status, 'qty', od.qty, 'trigger_price', od.trigger_price, 'reserved_usdt', od.reserved_usdt);
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
    update public.telegram_order_logs set status = st, ref_id = rid, result = res::jsonb, finished_at = now()
    where id = lg.id returning * into lg;
    perform cf_private.tg_audit(p_tg_user, u, p_update, 'order_executed', jsonb_build_object('kind', p_kind, 'symbol', nullif(sym, ''), 'status', st, 'log_id', lg.id));
  end if;
  return cf_private.tg_order_json(lg, false);
end $$;

-- Reconciliation after a timeout: read the stored outcome of an idempotency key, never re-execute.
create or replace function public.tgx_order_status(p_tg_user bigint, p_idem text)
returns json language sql stable security definer
set search_path = ''
as $$
  select case when lg.id is null then json_build_object('found', false)
              else (cf_private.tg_order_json(lg, true)::jsonb || jsonb_build_object('found', true))::json end
  from (select 1) x left join public.telegram_order_logs lg on lg.idem_key = p_idem and lg.tg_user_id = p_tg_user;
$$;

-- 7) Permissions: every tgx_* function is for the trusted server (service role) only ------------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace s on s.oid = p.pronamespace
           where s.nspname = 'public' and p.proname like 'tgx\_%' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace s on s.oid = p.pronamespace
           where s.nspname = 'cf_private' and p.proname like 'tg\_%' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
revoke all on table public.telegram_audit_logs, public.telegram_updates from anon, authenticated;
revoke insert, update, delete, truncate, references, trigger on table public.telegram_order_logs from anon, authenticated;
