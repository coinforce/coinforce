-- coinforce_79_kyc
-- Kimlik doğrulama (KYC): kullanıcı belge türü, ad soyad, kimlik no, doğum tarihi ve üç fotoğrafı (belge ön yüz,
-- T.C. kimlikte arka yüz, belgeyle selfie) gönderir. Fotoğraflar herkese kapalı 'kyc' deposunda, kullanıcının kendi
-- klasöründe durur; yalnızca yönetici okuyabilir. Kimlik numarası şifreli saklanır, tekrar kontrolü için gizli
-- anahtarlı özeti (HMAC) tutulur: bir kimlik yalnızca bir hesapta doğrulanabilir.
-- Yönetici onaylayınca hesaba bir kez 5000 USDT İŞLEM HACMİ eklenir (bakiye değişmez). Bu hacim kademelere
-- (çerçeve, banner) sayılır; kampanya ödüllerine sayılmaz (_campaign_volume değişmedi).
-- Para çekme talebi için onaylı KYC zorunlu (withdrawals tablosuna tetikleyici).
-- Yalnızca ekleme: yeni tablolar, depo, politikalar, fonksiyonlar; _user_volume ve my_volume CREATE OR REPLACE.

-- 1) Tablolar ----------------------------------------------------------------------------------------
create table if not exists public.kyc_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  doc_type text not null check (doc_type in ('tc', 'passport')),
  full_name text not null,
  birth_date date not null,
  id_hash text not null,
  id_enc bytea not null,
  id_last4 text not null,
  front_path text not null,
  back_path text,
  selfie_path text not null,
  reject_reason text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid
);
-- Hesap başına aynı anda en fazla bir bekleyen ya da onaylı talep; bir kimlik yalnızca bir hesapta onaylı olabilir.
create unique index if not exists kyc_one_open on public.kyc_requests (user_id) where status in ('pending', 'approved');
create unique index if not exists kyc_id_once on public.kyc_requests (id_hash) where status = 'approved';
create index if not exists kyc_status_idx on public.kyc_requests (status, created_at);
alter table public.kyc_requests enable row level security;
revoke all on public.kyc_requests from anon, authenticated;

create table if not exists public.volume_bonuses (
  user_id uuid not null references auth.users (id) on delete cascade,
  reason text not null,
  amount numeric not null check (amount > 0),
  created_at timestamptz not null default now(),
  primary key (user_id, reason)
);
alter table public.volume_bonuses enable row level security;
revoke all on public.volume_bonuses from anon, authenticated;

-- 2) Belge deposu: herkese kapalı, 10 MB, yalnızca fotoğraf ---------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('kyc', 'kyc', false, 10485760, array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif'])
on conflict (id) do nothing;

do $$
begin
  -- Kullanıcı yalnızca kendi klasörüne yeni dosya yükleyebilir (üzerine yazma, okuma, silme yok).
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'kyc_insert_own') then
    create policy kyc_insert_own on storage.objects for insert to authenticated
      with check (bucket_id = 'kyc' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
  -- Belgeleri yalnızca yönetici görebilir.
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'kyc_admin_read') then
    create policy kyc_admin_read on storage.objects for select to authenticated
      using (bucket_id = 'kyc' and public.is_admin());
  end if;
end $$;

-- 3) Yardımcılar (API'den erişilemez) -------------------------------------------------------------------
-- T.C. kimlik numarası algoritma kontrolü
create or replace function cf_private.tckn_ok(p text) returns boolean
language plpgsql immutable set search_path = '' as $$
declare d int[]; i int; o int; e int; s int := 0;
begin
  if p is null or p !~ '^[1-9][0-9]{10}$' then return false; end if;
  for i in 1..11 loop d[i] := substr(p, i, 1)::int; end loop;
  o := d[1] + d[3] + d[5] + d[7] + d[9];
  e := d[2] + d[4] + d[6] + d[8];
  if (((o * 7 - e) % 10) + 10) % 10 <> d[10] then return false; end if;
  for i in 1..10 loop s := s + d[i]; end loop;
  return s % 10 = d[11];
end $$;

-- Dosya gerçekten yüklenmiş ve kullanıcının kendi klasöründe mi?
create or replace function cf_private.kyc_file_ok(u uuid, p text) returns boolean
language sql stable security definer set search_path = '' as $$
  select p is not null and split_part(p, '/', 1) = u::text
     and exists (select 1 from storage.objects o where o.bucket_id = 'kyc' and o.name = p)
$$;

-- 4) Hacim: kademeler (çerçeve, banner) ve "Hacmin" göstergesi bonus hacmi de sayar ------------------------
create or replace function public._user_volume(p_user uuid)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((select sum(case when kind = 'perp_open' then qty * price else amount_usd end)
                     from public.transactions where user_id = p_user and kind in ('buy', 'sell', 'swap', 'perp_open')), 0)
       + coalesce((select sum(amount) from public.volume_bonuses where user_id = p_user), 0);
$$;

create or replace function public.my_volume()
returns json language sql stable security definer set search_path to 'public' as $$
  select json_build_object(
    'total', coalesce(sum(v), 0) + coalesce((select sum(amount) from public.volume_bonuses where user_id = auth.uid()), 0),
    'd30',   coalesce(sum(v) filter (where created_at > now() - interval '30 days'), 0),
    'd1',    coalesce(sum(v) filter (where created_at > now() - interval '24 hours'), 0),
    'bonus', coalesce((select sum(amount) from public.volume_bonuses where user_id = auth.uid()), 0))
  from (select created_at, case when kind = 'perp_open' then qty * price else amount_usd end as v
          from public.transactions
         where user_id = auth.uid() and kind in ('buy', 'sell', 'swap', 'perp_open')) t;
$$;

-- 5) Para çekme için onaylı KYC zorunlu ------------------------------------------------------------------
create or replace function cf_private.withdraw_kyc_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.kyc_requests k where k.user_id = new.user_id and k.status = 'approved') then
    raise exception 'Para çekmek için önce kimliğini doğrula (Ayarlar › Kimlik doğrulama).';
  end if;
  return new;
end $$;
create or replace trigger withdrawals_kyc_guard before insert on public.withdrawals
  for each row execute function cf_private.withdraw_kyc_guard();

-- 6) Kullanıcı fonksiyonları -----------------------------------------------------------------------------
create or replace function public.kyc_status()
returns json language plpgsql stable security definer set search_path = '' as $$
declare u uuid := auth.uid(); k public.kyc_requests; p public.profiles;
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  select * into k from public.kyc_requests where user_id = u order by created_at desc limit 1;
  select * into p from public.profiles where id = u;
  return json_build_object(
    'status', coalesce(k.status, 'none'), 'reason', k.reject_reason, 'submitted_at', k.created_at, 'reviewed_at', k.reviewed_at,
    'doc_type', k.doc_type, 'bonus', 5000,
    'bonus_given', exists (select 1 from public.volume_bonuses b where b.user_id = u and b.reason = 'kyc'),
    'full_name', coalesce(k.full_name, p.full_name), 'birth_date', coalesce(k.birth_date::text, p.birth_date::text));
end $$;

create or replace function public.kyc_submit(p_doc_type text, p_full_name text, p_id_number text, p_birth_date date,
                                             p_front text, p_back text, p_selfie text, p_consent boolean)
returns json language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); num text; nm text; h text; rid uuid; uname text; a record;
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  if not coalesce(p_consent, false) then raise exception 'Devam etmek için kimlik bilgilerinin işlenmesine onay vermelisin.'; end if;
  if exists (select 1 from public.kyc_requests where user_id = u and status = 'approved') then raise exception 'Kimliğin zaten doğrulandı.'; end if;
  if exists (select 1 from public.kyc_requests where user_id = u and status = 'pending') then raise exception 'İncelenmekte olan bir talebin var.'; end if;
  if (select count(*) from public.kyc_requests where user_id = u and created_at > now() - interval '24 hours') >= 3 then
    raise exception 'Son 24 saatte çok fazla talep gönderdin. Daha sonra tekrar dene.';
  end if;
  if p_doc_type is null or p_doc_type not in ('tc', 'passport') then raise exception 'Belge türünü seç.'; end if;
  nm := btrim(regexp_replace(coalesce(p_full_name, ''), '\s+', ' ', 'g'));
  if length(nm) < 5 or length(nm) > 80 or position(' ' in nm) = 0 then raise exception 'Adını ve soyadını belgede yazdığı gibi gir.'; end if;
  num := upper(regexp_replace(coalesce(p_id_number, ''), '\s', '', 'g'));
  if p_doc_type = 'tc' and not cf_private.tckn_ok(num) then raise exception 'Geçerli bir T.C. kimlik numarası gir.'; end if;
  if p_doc_type = 'passport' and num !~ '^[A-Z0-9]{6,12}$' then raise exception 'Geçerli bir pasaport numarası gir.'; end if;
  if p_birth_date is null or p_birth_date < date '1900-01-01' or p_birth_date > (current_date - interval '18 years')::date then
    raise exception 'Kimlik doğrulaması için 18 yaşını doldurmuş olmalısın.';
  end if;
  if not cf_private.kyc_file_ok(u, p_front) or not cf_private.kyc_file_ok(u, p_selfie)
     or (p_doc_type = 'tc' and not cf_private.kyc_file_ok(u, p_back)) then
    raise exception 'Belge fotoğrafları bulunamadı. Fotoğrafları yeniden seçip tekrar gönder.';
  end if;
  h := encode(extensions.hmac(p_doc_type || ':' || num, cf_private.master_key(), 'sha256'), 'hex');
  if exists (select 1 from public.kyc_requests where id_hash = h and status = 'approved' and user_id <> u) then
    raise exception 'Bu kimlik başka bir hesapta doğrulanmış.';
  end if;
  insert into public.kyc_requests (user_id, doc_type, full_name, birth_date, id_hash, id_enc, id_last4, front_path, back_path, selfie_path)
  values (u, p_doc_type, nm, p_birth_date, h, extensions.pgp_sym_encrypt(num, cf_private.master_key()), right(num, 4),
          p_front, case when p_doc_type = 'tc' then p_back end, p_selfie)
  returning id into rid;
  select username into uname from public.profiles where id = u;
  for a in select id from public.profiles where is_admin loop
    perform public._notify(a.id, 'Yeni kimlik doğrulama talebi: @' || coalesce(uname, '?') || '. Ayarlar › Kimlik doğrulama bölümünden inceleyebilirsin.', null);
  end loop;
  return json_build_object('ok', true, 'id', rid);
end $$;

-- 7) Yönetici fonksiyonları ------------------------------------------------------------------------------
create or replace function public.admin_kyc_list(p_status text default 'pending')
returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Bu işlem sadece yönetici içindir'; end if;
  return coalesce((select json_agg(x order by x.created_at) from (
    select k.id, k.user_id, p.username, k.status, k.doc_type, k.full_name, p.full_name as profile_name, k.birth_date,
           extensions.pgp_sym_decrypt(k.id_enc, cf_private.master_key()) as id_number,
           k.front_path as front, k.back_path as back, k.selfie_path as selfie, k.created_at, k.reviewed_at, k.reject_reason as reason,
           exists (select 1 from public.kyc_requests d where d.id_hash = k.id_hash and d.user_id <> k.user_id and d.status in ('approved', 'pending')) as duplicate,
           (select count(*) from public.kyc_requests r where r.user_id = k.user_id and r.status = 'rejected') as prev_rejected
      from public.kyc_requests k left join public.profiles p on p.id = k.user_id
     where p_status is null or k.status = p_status
     order by k.created_at
     limit 100) x), '[]'::json);
end $$;

create or replace function public.admin_kyc_decide(p_id uuid, p_approve boolean, p_reason text default null)
returns json language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); k public.kyc_requests;
begin
  if not public.is_admin() then raise exception 'Bu işlem sadece yönetici içindir'; end if;
  select * into k from public.kyc_requests where id = p_id for update;
  if k.id is null or k.status <> 'pending' then raise exception 'Bu talep artık beklemede değil.'; end if;
  if coalesce(p_approve, false) then
    if exists (select 1 from public.kyc_requests d where d.id_hash = k.id_hash and d.status = 'approved' and d.user_id <> k.user_id) then
      raise exception 'Bu kimlik başka bir hesapta zaten doğrulanmış; onaylanamaz.';
    end if;
    update public.kyc_requests set status = 'approved', reviewed_at = now(), reviewed_by = me, reject_reason = null where id = k.id;
    insert into public.volume_bonuses (user_id, reason, amount) values (k.user_id, 'kyc', 5000) on conflict do nothing;
    perform public._notify(k.user_id, '✅ Kimliğin doğrulandı. Hesabına 5.000 USDT işlem hacmi eklendi; artık para çekme talebi de oluşturabilirsin.', null);
  else
    if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'Reddetme sebebini yaz.'; end if;
    update public.kyc_requests set status = 'rejected', reviewed_at = now(), reviewed_by = me, reject_reason = left(btrim(p_reason), 300)
     where id = k.id;
    perform public._notify(k.user_id, 'Kimlik doğrulama talebin reddedildi: ' || left(btrim(p_reason), 300)
                                      || ' Ayarlar › Kimlik doğrulama bölümünden yeniden gönderebilirsin.', null);
  end if;
  return json_build_object('ok', true);
end $$;

-- 8) Yetkiler -------------------------------------------------------------------------------------
revoke all on function cf_private.tckn_ok(text), cf_private.kyc_file_ok(uuid, text), cf_private.withdraw_kyc_guard()
  from public, anon, authenticated;
revoke all on function public.kyc_status(), public.kyc_submit(text, text, text, date, text, text, text, boolean),
  public.admin_kyc_list(text), public.admin_kyc_decide(uuid, boolean, text) from public, anon;
grant execute on function public.kyc_status(), public.kyc_submit(text, text, text, date, text, text, text, boolean),
  public.admin_kyc_list(text), public.admin_kyc_decide(uuid, boolean, text) to authenticated;
