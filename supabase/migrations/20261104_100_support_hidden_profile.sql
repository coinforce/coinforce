-- 100: Destek hesaplarının profilini gizleme
-- support_agents.hide_profile = true olan hesabın profili, kullanıcı adı ve profil sayfası diğer
-- kullanıcılara görünmez (kendisi ve yöneticiler görmeye devam eder). Sohbette yalnızca temsilcinin
-- görünen adı gösterildiği için müşteri kullanıcı adını zaten görmez.
-- Yalnızca ekleme ve genişletme: yeni sütun (varsayılan false), yeni yardımcı fonksiyon, profiller
-- okuma politikasına bir koşul ve public_profile'a bir kontrol. Mevcut veriye dokunmaz.
-- Geri almak için: alter policy "profiller herkese acik" on public.profiles using (true);

alter table public.support_agents add column if not exists hide_profile boolean not null default false;

create or replace function public.profile_hidden(p_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select p_id is distinct from auth.uid()
     and exists (select 1 from public.support_agents a where a.user_id = p_id and a.hide_profile)
     and not exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin);
$$;
revoke all on function public.profile_hidden(uuid) from public, anon;
grant execute on function public.profile_hidden(uuid) to authenticated;

alter policy "profiller herkese acik" on public.profiles using (not public.profile_hidden(id));

do $do$
declare
  d text;
  a text := 'if p.id is null then raise exception ''Kullanıcı bulunamadı''; end if;';
begin
  d := pg_get_functiondef('public.public_profile(uuid)'::regprocedure);
  if position('profile_hidden' in d) > 0 then return; end if;            -- zaten uygulanmış
  if position(a in d) = 0 then raise exception 'public_profile beklenen yapıda değil'; end if;
  d := replace(d, a, a || ' if public.profile_hidden(p_user) then raise exception ''Kullanıcı bulunamadı''; end if;');
  execute d;
end $do$;
