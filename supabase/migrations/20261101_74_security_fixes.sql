-- coinforce_74_security_fixes
-- 1) profiles: RLS on, direct INSERT/DELETE closed, is_admin cannot be set from the API.
-- 2) Username login: email_for_login closed to anon/authenticated; replaced by a rate-limited
--    server-side check (auth_username_login) that only the auth-username edge function calls.
-- 3) Internal secret for the Telegram function's maintenance endpoints (?setup, ?run, ?preview).
-- 4) search_path pinned on helper functions; communities_list closed to anon.
-- Nothing is dropped and no user data is modified.

-- 1) profiles ------------------------------------------------------------
alter table public.profiles enable row level security;
revoke insert, delete, truncate, references, trigger, maintain on table public.profiles from anon, authenticated;

create or replace function public._profiles_guard()
returns trigger language plpgsql
set search_path = public
as $$
begin
  -- Security-definer functions run as their owner and are not affected; only API roles are checked.
  if current_user in ('anon', 'authenticated') then
    if tg_op = 'INSERT' then
      raise exception 'Profil doğrudan oluşturulamaz';
    end if;
    if new.is_admin is distinct from old.is_admin or new.id is distinct from old.id then
      raise exception 'Bu alan değiştirilemez';
    end if;
  end if;
  return new;
end $$;
revoke all on function public._profiles_guard() from public, anon, authenticated;

create or replace trigger profiles_guard before insert or update on public.profiles
for each row execute function public._profiles_guard();

-- 2) Username login -------------------------------------------------------
create table if not exists cf_private.login_attempts (
  id bigint generated always as identity primary key,
  ident text not null,
  ip text not null,
  ok boolean not null,
  created_at timestamptz not null default now()
);
create index if not exists login_attempts_ident on cf_private.login_attempts (ident, created_at desc);
create index if not exists login_attempts_ip on cf_private.login_attempts (ip, created_at desc);
alter table cf_private.login_attempts enable row level security;

-- Returns {email} when the password is correct, {email:null} otherwise,
-- {locked:true, retry_after} after 5 failures per username or 20 per IP within 15 minutes.
create or replace function public.auth_username_login(p_ident text, p_pw text, p_ip text)
returns json language plpgsql security definer
set search_path = ''
as $$
declare
  k text := lower(trim(leading '@' from btrim(coalesce(p_ident, ''))));
  v_ip text := left(coalesce(nullif(btrim(p_ip), ''), 'unknown'), 64);
  fu int; fi int; e text; h text; v_ok boolean := false;
begin
  if k = '' or p_pw is null or length(p_pw) > 200 then return json_build_object('email', null); end if;
  perform pg_advisory_xact_lock(hashtextextended('login-ip:' || v_ip, 0));
  perform pg_advisory_xact_lock(hashtextextended('login-user:' || k, 0));
  select count(*) into fu from cf_private.login_attempts where ident = k and not ok and created_at > now() - interval '15 minutes';
  select count(*) into fi from cf_private.login_attempts where ip = v_ip and not ok and created_at > now() - interval '15 minutes';
  if fu >= 5 or fi >= 20 then
    return json_build_object('email', null, 'locked', true, 'retry_after', 900);
  end if;
  select u.email, u.encrypted_password into e, h
    from auth.users u join public.profiles p on p.id = u.id
   where lower(p.username) = k limit 1;
  if e is not null and h is not null then
    v_ok := extensions.crypt(p_pw, h) = h;
  else
    perform extensions.crypt(p_pw, extensions.gen_salt('bf', 10)); -- same cost when the user does not exist
  end if;
  insert into cf_private.login_attempts (ident, ip, ok) values (k, v_ip, v_ok);
  return json_build_object('email', case when v_ok then e end);
end $$;
revoke all on function public.auth_username_login(text, text, text) from public, anon, authenticated;
grant execute on function public.auth_username_login(text, text, text) to service_role;

revoke all on function public.email_for_login(text, text) from public, anon, authenticated;
grant execute on function public.email_for_login(text, text) to service_role;

-- 3) Internal secret for Telegram maintenance endpoints --------------------
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'tg_internal_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'tg_internal_secret', 'telegram-notify ?setup/?run/?preview');
  end if;
end $$;

create or replace function cf_private.tg_internal_secret()
returns text language sql stable security definer
set search_path = ''
as $$ select decrypted_secret from vault.decrypted_secrets where name = 'tg_internal_secret' limit 1 $$;

-- Only the edge function (service role) can read it.
create or replace function public.tgx_internal_secret()
returns text language sql stable security definer
set search_path = ''
as $$ select cf_private.tg_internal_secret() $$;
revoke all on function public.tgx_internal_secret() from public, anon, authenticated;
grant execute on function public.tgx_internal_secret() to service_role;

-- The outbox flush call now carries the secret. The function URL is per environment:
--   insert into public.app_settings (key, value) values ('tg_function_url', 'https://<ref>.supabase.co/functions/v1/telegram-notify')
--   on conflict (key) do update set value = excluded.value;
create or replace function public.tgn_tick()
returns void language plpgsql security definer
set search_path to 'public'
as $$
declare u text := (select value from public.app_settings where key = 'tg_function_url');
begin
  perform public.tgn_enqueue();
  if u is not null and exists (select 1 from public.tg_outbox where sent_at is null and tries < 5 and created_at > now() - interval '1 day') then
    perform net.http_post(url := u || '?run=1',
                          body := '{}'::jsonb,
                          headers := jsonb_build_object('content-type', 'application/json',
                                                        'x-cf-internal', cf_private.tg_internal_secret()));
  end if;
end $$;

-- 4) Hardening ------------------------------------------------------------
alter function public._clean_text(text) set search_path = public, extensions;
alter function public._iban_ok(text) set search_path = public, extensions;
alter function public._hold_msg() set search_path = public, extensions;
alter function public._coin_logo_ok(text) set search_path = public, extensions;
alter function public._tier_volume(text) set search_path = public, extensions;
alter function public._auction_img_ok(text) set search_path = public, extensions;
alter function public._grid_idx(numeric, numeric, numeric, integer) set search_path = public, extensions;
alter function public.tg_link(bigint, text) set search_path = public;
alter function public.tg_trade(bigint, text, text, numeric, numeric) set search_path = public;
alter function public.tg_accounts(bigint) set search_path = public;
alter function public.tg_positions(bigint, text) set search_path = public;
revoke execute on function public.communities_list(uuid) from public, anon;
grant execute on function public.communities_list(uuid) to authenticated, service_role;
