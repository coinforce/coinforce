-- 101: Destek sohbetinde temsilcinin profil fotoğrafı
-- Gizli profilli temsilcinin fotoğrafı müşteri tarafından profiller tablosundan okunamaz. support_thread
-- yanıtına yalnızca aktif temsilcilerin {görünen ad: fotoğraf adresi} eşlemesi eklenir (kullanıcı adı ve
-- hesap kimliği döndürülmez). Yalnızca bir alan eklenir; veriye dokunmaz.
do $do$
declare
  d text;
  a text := '''online'', cf_private.support_online(),';
begin
  d := pg_get_functiondef('public.support_thread(bigint)'::regprocedure);
  if position('avatars' in d) > 0 then return; end if;                 -- zaten uygulanmış
  if position(a in d) = 0 then raise exception 'support_thread beklenen yapıda değil'; end if;
  d := replace(d, a, a || ' ''avatars'', (select coalesce(json_object_agg(s.display_name, p.avatar_url), ''{}''::json) from public.support_agents s join public.profiles p on p.id = s.user_id where s.active and p.avatar_url like ''https://%''),');
  execute d;
end $do$;
