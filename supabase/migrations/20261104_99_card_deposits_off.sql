-- 99: Kartla yatırma (iyzico) kapatıldı
-- begin_card_payment artık yeni kart ödemesi başlatmaz. Fonksiyonun geri kalanı aynen
-- korunur (yalnızca başına bir kontrol eklenir). Mevcut ödeme kayıtlarına, çekim ve iade
-- akışlarına, hesaplara ve bakiyelere dokunulmaz.
-- Yeniden açmak için: insert into public.app_settings (key, value) values ('card_enabled', '1')
--   on conflict (key) do update set value = excluded.value;
do $do$
declare
  d text;
  a text := 'if uid is null then raise exception ''Oturum açmalısın''; end if;';
begin
  d := pg_get_functiondef('public.begin_card_payment(numeric)'::regprocedure);
  if position('card_enabled' in d) > 0 then return; end if;            -- zaten uygulanmış
  if position(a in d) = 0 then raise exception 'begin_card_payment beklenen yapıda değil'; end if;
  d := replace(d, a, a || ' if public._setting_num(''card_enabled'', 0) <> 1 then raise exception ''Kartla yatırma şu an kapalı''; end if;');
  execute d;
end $do$;
