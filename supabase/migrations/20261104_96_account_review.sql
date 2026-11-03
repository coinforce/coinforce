-- coinforce_96_account_review
-- Hesap değerlendirme süreci: hesabı 14 günden yeni olan bir kullanıcı TEK işlemde 1.000 $ üzerinde al-sat yaparsa
-- hesap "değerlendirme"ye alınır. Yönetici onaylayana kadar uygulama kilitlenir (arayüz) ve sunucu yeni işlem /
-- para çekme talebi kabul etmez. Yönetici onaylayınca kayıt 'cleared' olur; aynı hesap bir daha işaretlenmez.
-- Yalnızca ekleme: yeni tablo, yeni tetikleyiciler ve fonksiyonlar. Mevcut işlem fonksiyonları DEĞİŞMEZ.
-- Geriye dönük işaretleme YOK: yalnızca bu migration'dan sonraki işlemler kontrol edilir.
-- Koruma tetikleyicisi, çağrı zinciri run_engine / arena_tick ise (kullanıcının önceden verdiği emirlerin
-- sunucuda gerçekleşmesi) hata vermez: bu iki fonksiyonda hata yakalama olmadığı için tüm motor durabilirdi.

-- 1) Tablo -------------------------------------------------------------------------------------------------
create table if not exists public.account_reviews (
  user_id uuid primary key references auth.users (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'cleared')),
  trigger_usd numeric not null,
  trigger_kind text,
  trigger_symbol text,
  created_at timestamptz not null default now(),
  cleared_at timestamptz,
  cleared_by uuid
);
create index if not exists account_reviews_status_idx on public.account_reviews (status, created_at);
alter table public.account_reviews enable row level security;
revoke all on public.account_reviews from anon, authenticated;

-- 2) Tespit: 1.000 $ üzerindeki al-sat, hesap 14 günden yeni, yönetici değil ---------------------------------
create or replace function cf_private.review_detect() returns trigger
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into public.account_reviews (user_id, trigger_usd, trigger_kind, trigger_symbol)
  select p.id, new.amount_usd, new.kind, new.symbol
    from public.profiles p
   where p.id = new.user_id and not coalesce(p.is_admin, false) and p.created_at > now() - interval '14 days'
  on conflict (user_id) do nothing;
  get diagnostics n = row_count;
  if n > 0 then
    perform public._notify(new.user_id, 'Hesabın değerlendirme sürecine alındı. Yönetici onayı gelene kadar işlem yapılamaz.', null);
  end if;
  return null;
exception when others then
  return null; -- tespit hatası işlemi asla bozmaz
end $$;
create or replace trigger zz_review_detect after insert on public.transactions
  for each row when (new.kind in ('buy', 'sell') and new.amount_usd > 1000)
  execute function cf_private.review_detect();

-- 3) Koruma: bekleyen hesap yeni işlem açamaz ---------------------------------------------------------------
create or replace function cf_private.review_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare ctx text;
begin
  if exists (select 1 from public.account_reviews r where r.user_id = new.user_id and r.status = 'pending') then
    get diagnostics ctx = pg_context;
    if ctx ~* 'function (public\.)?(run_engine|arena_tick)\(' then return new; end if;
    raise exception 'Hesabın değerlendirme sürecinde. Yönetici onayı gelene kadar işlem yapılamaz.';
  end if;
  return new;
end $$;
create or replace trigger zz_review_guard before insert on public.transactions
  for each row when (new.kind in ('buy', 'sell', 'perp_open', 'swap'))
  execute function cf_private.review_guard();

create or replace function cf_private.review_wd_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.account_reviews r where r.user_id = new.user_id and r.status = 'pending') then
    raise exception 'Hesabın değerlendirme sürecinde. Yönetici onayı gelene kadar para çekilemez.';
  end if;
  return new;
end $$;
create or replace trigger zz_review_wd_guard before insert on public.withdrawals
  for each row execute function cf_private.review_wd_guard();

-- 4) Kullanıcı: kendi durumu ---------------------------------------------------------------------------------
create or replace function public.my_review()
returns json language plpgsql stable security definer set search_path = '' as $$
declare u uuid := auth.uid(); r public.account_reviews; p public.profiles;
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  select * into r from public.account_reviews where user_id = u;
  if r.user_id is null or r.status <> 'pending' then return json_build_object('pending', false); end if;
  select * into p from public.profiles where id = u;
  return json_build_object('pending', true, 'since', r.created_at, 'account_created', p.created_at, 'now', now());
end $$;

-- 5) Yönetici: liste ve onay ---------------------------------------------------------------------------------
create or replace function public.admin_review_list(p_status text default 'pending')
returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Bu işlem sadece yönetici içindir'; end if;
  return coalesce((select json_agg(x order by x.created_at) from (
    select r.user_id, p.username, p.full_name, r.status, r.trigger_usd, r.trigger_kind, r.trigger_symbol, r.created_at, r.cleared_at,
           p.created_at as account_created, a.usdt as balance
      from public.account_reviews r
      left join public.profiles p on p.id = r.user_id
      left join public.accounts a on a.user_id = r.user_id
     where p_status is null or r.status = p_status
     order by r.created_at
     limit 100) x), '[]'::json);
end $$;

create or replace function public.admin_review_clear(p_user uuid)
returns json language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); n int;
begin
  if not public.is_admin() then raise exception 'Bu işlem sadece yönetici içindir'; end if;
  update public.account_reviews set status = 'cleared', cleared_at = now(), cleared_by = me
   where user_id = p_user and status = 'pending';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Bu hesap artık değerlendirmede değil.'; end if;
  perform public._notify(p_user, '✅ Hesap değerlendirmen tamamlandı. Artık işlem yapabilirsin.', null);
  return json_build_object('ok', true);
end $$;

-- 6) Yetkiler -----------------------------------------------------------------------------------------------
revoke all on function cf_private.review_detect(), cf_private.review_guard(), cf_private.review_wd_guard() from public, anon, authenticated;
revoke all on function public.my_review(), public.admin_review_list(text), public.admin_review_clear(uuid) from public, anon;
grant execute on function public.my_review(), public.admin_review_list(text), public.admin_review_clear(uuid) to authenticated;
