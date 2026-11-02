-- coinforce_82_vip_levels
-- VIP seviyeleri (1-12): cüzdandaki SOL miktarına göre otomatik. Seviye, komisyonda indirim sağlar (VIP n → %round(n*75/12) indirim,
-- VIP 12 = %75). Yalnızca ekleme + üç mevcut fonksiyondaki sabit %0,08 oranının yardımcı fonksiyona bağlanması
-- (market_trade, run_engine, swap). Fonksiyon gövdeleri yerinde yamalanır; beklenen metin bulunamazsa migration hata verir.
-- Limit/stop emirlerinde ayrılan bakiye (%0,08 üzerinden) değişmez; indirimli komisyon daha az tuttuğu için fark iade edilir.
-- Açık bakiyelere dokunulmaz.

create or replace function public._vip_level(p_uid uuid)
returns int language sql stable security definer set search_path = '' as $$
  select coalesce((select count(*)::int from unnest(array[1000,2500,5000,10000,20000,35000,50000,75000,100000,150000,250000,500000]) t
                   where t <= (select h.qty from public.holdings h where h.user_id = p_uid and h.symbol = 'SOL')), 0);
$$;

create or replace function public._vip_fee(p_uid uuid)
returns numeric language sql stable security definer set search_path = '' as $$
  select 0.0008 * (1 - round(public._vip_level(p_uid) * 75 / 12.0) / 100.0);
$$;
revoke all on function public._vip_level(uuid), public._vip_fee(uuid) from public, anon, authenticated;

-- Herkesin etiketinde görünsün diye yalnızca seviye döner (SOL miktarı dönmez)
create or replace function public.vip_levels()
returns table (user_id uuid, lvl int) language sql stable security definer set search_path = '' as $$
  select h.user_id, (select count(*)::int from unnest(array[1000,2500,5000,10000,20000,35000,50000,75000,100000,150000,250000,500000]) t where t <= h.qty)
  from public.holdings h where h.symbol = 'SOL' and h.qty >= 1000;
$$;
revoke all on function public.vip_levels() from public, anon;
grant execute on function public.vip_levels() to authenticated;

do $$
declare d text; n text;
  pat constant text[][] := array[
    ['market_trade', 'rate numeric := 0.0008;', 'rate numeric := public._vip_fee(uid);'],
    ['run_engine',   'fee := val * 0.0008;',    'fee := val * public._vip_fee(o.user_id);'],
    ['swap',         '(1 - 0.0008)',            '(1 - public._vip_fee(uid))']];
begin
  for i in 1 .. array_length(pat, 1) loop
    select pg_get_functiondef(p.oid) into d from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = pat[i][1];
    if d is null or (length(d) - length(replace(d, pat[i][2], ''))) <> length(pat[i][2]) then
      raise exception '% içinde beklenen metin tam bir kez bulunamadı', pat[i][1];
    end if;
    execute replace(d, pat[i][2], pat[i][3]);
  end loop;
end $$;
