-- STAGING ONLY. Production'a asla uygulanmaz.
-- Staging projesinde botu sahte Telegram API'si (tg-mock edge function) ile çalıştırır ve testlere yardımcı fonksiyonlar ekler.
-- Gerçek bir test botu kullanılacaksa: tg_api_base ve tg_test_token satırlarını silip TELEGRAM_BOT_TOKEN secret'ını ayarla.

insert into public.app_settings (key, value) values
  ('tg_function_url', 'https://dyufemhucbphktjezasa.supabase.co/functions/v1/telegram-notify'),
  ('tg_api_base', 'https://dyufemhucbphktjezasa.supabase.co/functions/v1/tg-mock'),
  ('tg_test_token', 'TEST:staging-mock-token'),
  ('tg_bot', 'coinforce_staging_bot')
on conflict (key) do update set value = excluded.value;

create schema if not exists cf_test;
revoke all on schema cf_test from public, anon, authenticated;

-- Sahte Telegram API'sinin kaydettiği bot çağrıları
create table if not exists cf_test.tg_mock_calls (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  method text not null,
  chat_id bigint,
  body jsonb
);
create or replace function public.tgmock_record(p_method text, p_body jsonb)
returns bigint language plpgsql security definer
set search_path = ''
as $$
declare i bigint;
begin
  insert into cf_test.tg_mock_calls (method, chat_id, body)
  values (p_method, nullif(p_body->>'chat_id', '')::bigint, p_body) returning id into i;
  return i;
end $$;
revoke all on function public.tgmock_record(text, jsonb) from public, anon, authenticated;
grant execute on function public.tgmock_record(text, jsonb) to service_role;

-- Telegram güncellemesi kurucuları
create or replace function cf_test.msg(p_update bigint, p_tg bigint, p_text text, p_chat bigint default null,
  p_chat_type text default 'private', p_date bigint default null, p_mid bigint default null)
returns jsonb language sql stable as $$
  select jsonb_build_object('update_id', p_update, 'message', jsonb_build_object(
    'message_id', coalesce(p_mid, p_update), 'date', coalesce(p_date, extract(epoch from now())::bigint), 'text', p_text,
    'from', jsonb_build_object('id', p_tg, 'is_bot', false, 'first_name', 'T', 'username', 'user' || p_tg),
    'chat', jsonb_build_object('id', coalesce(p_chat, p_tg), 'type', p_chat_type)));
$$;
create or replace function cf_test.cbq(p_update bigint, p_tg bigint, p_data text, p_mid bigint default 777)
returns jsonb language sql stable as $$
  select jsonb_build_object('update_id', p_update, 'callback_query', jsonb_build_object(
    'id', 'cq' || p_update, 'data', p_data,
    'from', jsonb_build_object('id', p_tg, 'is_bot', false, 'first_name', 'T', 'username', 'user' || p_tg),
    'message', jsonb_build_object('message_id', p_mid, 'date', extract(epoch from now())::bigint, 'text', 'menu',
      'chat', jsonb_build_object('id', p_tg, 'type', 'private'))));
$$;

-- Webhook gizli başlığı: Telegram'ın göndereceği değerle aynı (token'dan türetilir)
create or replace function cf_test.hook_secret() returns text language sql stable as $$
  select left(encode(extensions.digest('cf-notify:' || (select value from public.app_settings where key = 'tg_test_token'), 'sha256'), 'hex'), 48);
$$;

-- Senkron gönderim (http eklentisi): cevabın HTTP durum kodunu döndürür
create or replace function cf_test.post_update(p_update jsonb, p_secret text default null)
returns int language plpgsql as $$
declare r extensions.http_response;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '45');
  r := extensions.http(('POST', (select value from public.app_settings where key = 'tg_function_url'),
         array[extensions.http_header('x-telegram-bot-api-secret-token', coalesce(p_secret, cf_test.hook_secret()))],
         'application/json', p_update::text)::extensions.http_request);
  return r.status;
end $$;

-- Asenkron gönderim (pg_net): aynı işlemde kuyruğa alınan istekler işlem bitince birlikte, eşzamanlı gönderilir
create or replace function cf_test.post_update_async(p_update jsonb)
returns bigint language sql as $$
  select net.http_post(url := (select value from public.app_settings where key = 'tg_function_url'), body := p_update,
    headers := jsonb_build_object('content-type', 'application/json', 'x-telegram-bot-api-secret-token', cf_test.hook_secret()),
    timeout_milliseconds := 45000);
$$;

-- Bir test kullanıcısı olarak (gerçek Auth girişi + kullanıcı JWT'si) PostgREST RPC çağrısı
create or replace function cf_test.user_rpc(p_email text, p_fn text, p_args jsonb default '{}')
returns table(status int, body text) language plpgsql as $$
declare tok text;
begin
  select (x.body::json)->>'access_token' into tok
    from cf_test.rest('POST', '/auth/v1/token?grant_type=password', null, json_build_object('email', p_email, 'password', 'Test-1234!')::text) x;
  return query select x.status, x.body from cf_test.rest('POST', '/rest/v1/rpc/' || p_fn, tok, p_args::text) x;
end $$;

-- Son bot cevabı (sendMessage / editMessageText metni)
create or replace function cf_test.last_reply(p_since timestamptz)
returns text language sql stable as $$
  select coalesce((select body->>'text' from cf_test.tg_mock_calls
                    where at >= p_since and method in ('sendMessage', 'editMessageText') order by id desc limit 1), '');
$$;
