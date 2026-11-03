-- coinforce_95_social_links
-- Profil rozetleri için bağlı hesaplar: X ve Telegram. Yalnızca ekleme: yeni tablolar ve fonksiyonlar; mevcut veriye dokunulmaz.
-- X: hesabın sahipliği X'in kendi girişiyle (OAuth 2.0 + PKCE) x-link Edge Function'ında doğrulanır. X erişim belirteci
--    saklanmaz; yalnızca X kullanıcı kimliği, kullanıcı adı ve görünen adı tutulur. Bir X hesabı tek bir COINFORCE hesabına bağlanır.
-- Telegram: mevcut bot bağlantısı (tg_notify; tek kullanımlık kodla doğrulanmış Telegram kullanıcısı) kullanılır. Burada yalnızca
--    "profilde göster" onayı ve onayın verildiği Telegram kullanıcı kimliği tutulur; başka bir Telegram hesabı bağlanırsa rozet,
--    kullanıcı yeniden onaylayana kadar görünmez.
-- Rozetler yalnızca kullanıcı göstermeyi seçtiyse görünür. Kullanıcılar tablolara doğrudan erişemez; yalnızca fonksiyonlar üzerinden.
-- Hiçbir fonksiyon satır silmez: kullanılan giriş durumu işaretlenir, X bağlantısı kaldırılınca alanlar boşaltılır.

create table if not exists public.social_links (
  user_id uuid not null references auth.users (id) on delete cascade,
  provider text not null check (provider in ('x', 'tg')),
  ext_id text check (ext_id is null or ext_id ~ '^[0-9]{1,20}$'),
  username text check (username is null or username ~ '^[A-Za-z0-9_]{1,15}$'),
  display_name text check (display_name is null or char_length(display_name) <= 60),
  show boolean not null default true,
  linked_at timestamptz not null default now(),
  primary key (user_id, provider),
  check (provider <> 'x' or (ext_id is null) = (username is null))
);
create unique index if not exists social_links_x_ext_uniq on public.social_links (ext_id) where provider = 'x';
alter table public.social_links enable row level security;
revoke all on public.social_links from anon, authenticated;

-- X girişinin kısa ömürlü PKCE durumu (10 dakika, tek kullanımlık: kullanılınca used_at dolar). Yalnızca x-link (service role) kullanır.
create table if not exists public.x_oauth_states (
  state text primary key check (state ~ '^[A-Za-z0-9_-]{32,128}$'),
  user_id uuid not null references auth.users (id) on delete cascade,
  verifier text not null check (verifier ~ '^[A-Za-z0-9._~-]{43,128}$'),
  created_at timestamptz not null default now(),
  used_at timestamptz
);
create index if not exists x_oauth_states_user_idx on public.x_oauth_states (user_id, created_at);
alter table public.x_oauth_states enable row level security;
revoke all on public.x_oauth_states from anon, authenticated;

-- Kullanıcının kendi bağlantıları (ayarlar ekranı)
create or replace function public.my_socials()
returns json language plpgsql stable security definer set search_path = '' as $$
declare u uuid := auth.uid(); x public.social_links; tl public.social_links; tid bigint; tun text;
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  select * into x from public.social_links where user_id = u and provider = 'x';
  select * into tl from public.social_links where user_id = u and provider = 'tg';
  select t.tg_user_id, t.tg_username into tid, tun from public.tg_notify t where t.user_id = u;
  return json_build_object(
    'x', case when x.ext_id is null then null
         else json_build_object('username', x.username, 'name', x.display_name, 'show', x.show, 'linked_at', x.linked_at) end,
    'tg', json_build_object('linked', tid is not null, 'username', case when tid is not null then tun end,
          'show', coalesce(tid is not null and tl.show and tl.ext_id = tid::text, false)));
end $$;

-- Rozeti profilde göster / gizle
create or replace function public.social_set_show(p_provider text, p_show boolean)
returns json language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); n int; tid bigint;
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  if p_show is null then raise exception 'Geçersiz değer'; end if;
  if p_provider = 'x' then
    update public.social_links set show = p_show where user_id = u and provider = 'x' and ext_id is not null;
    get diagnostics n = row_count;
    if n = 0 then raise exception 'X hesabı bağlı değil'; end if;
  elsif p_provider = 'tg' then
    select t.tg_user_id into tid from public.tg_notify t where t.user_id = u;
    if tid is null then raise exception 'Telegram hesabı bağlı değil'; end if;
    insert into public.social_links (user_id, provider, ext_id, show, linked_at) values (u, 'tg', tid::text, p_show, now())
    on conflict (user_id, provider) do update set ext_id = excluded.ext_id, show = excluded.show, linked_at = now();
  else
    raise exception 'Geçersiz hesap türü';
  end if;
  return public.my_socials();
end $$;

-- X bağlantısını kaldır (alanlar boşaltılır; X hesabı başka bir COINFORCE hesabına bağlanabilir hâle gelir)
create or replace function public.social_unlink_x()
returns json language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  update public.social_links set ext_id = null, username = null, display_name = null, show = false, linked_at = now()
   where user_id = u and provider = 'x';
  return public.my_socials();
end $$;

-- Bir profilin görünen rozetleri: yalnızca doğrulanmış ve sahibinin göstermeyi seçtiği hesaplar
create or replace function public.profile_socials(p_user uuid)
returns json language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(q.b order by q.o), '[]'::json) from (
    select 1 as o, json_build_object('p', 'x', 'u', s.username) as b
      from public.social_links s
     where s.user_id = p_user and s.provider = 'x' and s.show and s.ext_id is not null
    union all
    select 2, json_build_object('p', 'tg', 'u', case when t.tg_username ~ '^[A-Za-z0-9_]{5,32}$' then t.tg_username end)
      from public.social_links s
      join public.tg_notify t on t.user_id = s.user_id and t.tg_user_id is not null and s.ext_id = t.tg_user_id::text
     where s.user_id = p_user and s.provider = 'tg' and s.show
  ) q where auth.uid() is not null;
$$;

-- x-link (service role): PKCE durumu oluştur; kullanıcı başına 15 dakikada en fazla 5 bekleyen giriş
create or replace function public.x_oauth_begin(p_user uuid, p_state text, p_verifier text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.x_oauth_states s where s.user_id = p_user and s.used_at is null and s.created_at > now() - interval '15 minutes') >= 5 then
    raise exception 'too_many'; end if;
  insert into public.x_oauth_states (state, user_id, verifier) values (p_state, p_user, p_verifier);
end $$;

-- x-link (service role): durumu tek kullanımlık olarak al; yoksa ya da 10 dakikadan eskiyse null
create or replace function public.x_oauth_take(p_state text)
returns json language plpgsql security definer set search_path = '' as $$
declare r public.x_oauth_states;
begin
  update public.x_oauth_states set used_at = now() where state = p_state and used_at is null returning * into r;
  if r.state is null or r.created_at < now() - interval '10 minutes' then return null; end if;
  return json_build_object('user_id', r.user_id, 'verifier', r.verifier);
end $$;

-- x-link (service role): X'in doğruladığı hesabı kaydet. 'ok' | 'taken' (başka hesaba bağlı) | 'bad'
create or replace function public.x_link_finish(p_user uuid, p_id text, p_username text, p_name text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if p_id is null or p_id !~ '^[0-9]{1,20}$' or p_username is null or p_username !~ '^[A-Za-z0-9_]{1,15}$' then return 'bad'; end if;
  if not exists (select 1 from auth.users a where a.id = p_user) then return 'bad'; end if;
  if exists (select 1 from public.social_links s where s.provider = 'x' and s.ext_id = p_id and s.user_id <> p_user) then return 'taken'; end if;
  insert into public.social_links (user_id, provider, ext_id, username, display_name, show, linked_at)
  values (p_user, 'x', p_id, p_username, left(p_name, 60), true, now())
  on conflict (user_id, provider) do update set ext_id = excluded.ext_id, username = excluded.username,
    display_name = excluded.display_name, show = true, linked_at = now();
  return 'ok';
exception when unique_violation then return 'taken';
end $$;

revoke all on function public.my_socials(), public.social_set_show(text, boolean), public.social_unlink_x(), public.profile_socials(uuid) from public, anon;
grant execute on function public.my_socials(), public.social_set_show(text, boolean), public.social_unlink_x(), public.profile_socials(uuid) to authenticated;
revoke all on function public.x_oauth_begin(uuid, text, text), public.x_oauth_take(text), public.x_link_finish(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.x_oauth_begin(uuid, text, text), public.x_oauth_take(text), public.x_link_finish(uuid, text, text, text) to service_role;
