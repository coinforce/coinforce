-- 103 GERİ ALMA (yalnızca gerekirse elle uygulanır; otomatik migration değildir)
-- Eski CoinGecko tabanlı fetch_prices / fetch_sparks / fetch_fx gövdelerini geri yükler ve borsa
-- eşleşmelerini kapatır. Eklenen sütunlar, ex_fetch tablosu ve yardımcı fonksiyonlar zararsızdır, kalabilir.
update public.prices set ex_src = null, ex_sym = null where ex_src is not null;

create or replace function public.fetch_prices()
returns void language plpgsql security definer set search_path = public, extensions as $function$
declare r record; j jsonb; e jsonb; ids text; k text; h jsonb;
begin
  -- 1) Önceki isteklerin cevaplarını işle
  for r in
    select f.id, x.status_code, x.content
    from public.price_fetch f join net._http_response x on x.id = f.id
    where not f.done order by f.id
  loop
    update public.price_fetch set done = true where id = r.id;
    if r.status_code = 200 and r.content is not null then
      j := r.content::jsonb;
      if jsonb_typeof(j) = 'array' then
        -- /coins/markets biçimi: [{id, current_price, market_cap, price_change_percentage_24h, image}, ...]
        for e in select * from jsonb_array_elements(j) loop
          if (e ->> 'current_price') is not null and (e ->> 'current_price')::numeric > 0 then
            update public.prices p set
              price = (e ->> 'current_price')::numeric,
              open_24h = case when (e ->> 'price_change_percentage_24h') is not null
                then (e ->> 'current_price')::numeric / (1 + (e ->> 'price_change_percentage_24h')::numeric / 100)
                else p.open_24h end,
              market_cap = coalesce((e ->> 'market_cap')::numeric, p.market_cap),
              image_url = coalesce(e ->> 'image', p.image_url),
              circulating_supply = coalesce((e ->> 'circulating_supply')::numeric, p.circulating_supply),
              ath = coalesce((e ->> 'ath')::numeric, p.ath),
              volume_24h = coalesce((e ->> 'total_volume')::numeric, p.volume_24h),
              high_24h = coalesce((e ->> 'high_24h')::numeric, p.high_24h),
              low_24h = coalesce((e ->> 'low_24h')::numeric, p.low_24h),
              spark = coalesce(e -> 'sparkline_in_7d' -> 'price', p.spark),
              listed = true,
              listed_at = coalesce(p.listed_at, now()),
              updated_at = now()
            where p.coingecko_id = e ->> 'id';
          end if;
        end loop;
      else
        -- eski /simple/price biçimi (geçiş sırasında bekleyen cevaplar için)
        update public.prices p set
          price = (j -> p.coingecko_id ->> 'usd')::numeric,
          open_24h = case when (j -> p.coingecko_id ->> 'usd_24h_change') is not null
            then (j -> p.coingecko_id ->> 'usd')::numeric / (1 + (j -> p.coingecko_id ->> 'usd_24h_change')::numeric / 100)
            else p.open_24h end,
          market_cap = coalesce((j -> p.coingecko_id ->> 'usd_market_cap')::numeric, p.market_cap),
          updated_at = now()
        where p.coingecko_id is not null
          and (j -> p.coingecko_id ->> 'usd') is not null
          and (j -> p.coingecko_id ->> 'usd')::numeric > 0;
      end if;
    end if;
  end loop;
  delete from public.price_fetch where created_at < now() - interval '1 hour';

  -- 2) Emirler, likidasyonlar, alarmlar
  perform public.run_engine();

  -- 3) Yeni istek
  select string_agg(coingecko_id, ',') into ids from public.prices where coingecko_id is not null;
  select value into k from public.app_settings where key = 'coingecko_key';
  h := jsonb_build_object('accept', 'application/json', 'user-agent', 'Mozilla/5.0 (compatible; COINFORCE/1.0)');
  if k is not null then h := h || jsonb_build_object('x-cg-demo-api-key', k); end if;
  insert into public.price_fetch (id) values (
    net.http_get(
      url := 'https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=' || ids ||
             '&per_page=250&price_change_percentage=24h',
      headers := h, timeout_milliseconds := 10000));
end $function$;

create or replace function public.fetch_sparks()
returns void language plpgsql security definer set search_path = public, extensions as $function$
declare ids text; k text; h jsonb;
begin
  select string_agg(coingecko_id, ',') into ids from public.prices where coingecko_id is not null;
  select value into k from public.app_settings where key = 'coingecko_key';
  h := jsonb_build_object('accept', 'application/json', 'user-agent', 'Mozilla/5.0 (compatible; COINFORCE/1.0)');
  if k is not null then h := h || jsonb_build_object('x-cg-demo-api-key', k); end if;
  insert into public.price_fetch (id) values (
    net.http_get(url := 'https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=' || ids || '&per_page=250&sparkline=true&price_change_percentage=24h',
      headers := h, timeout_milliseconds := 15000));
end $function$;

create or replace function public.fetch_fx()
returns void language plpgsql security definer set search_path = public, extensions as $function$
declare r record; j jsonb; c text; v numeric; prev numeric; prev_at timestamptz; k text; h jsonb;
begin
  for r in select f.id, x.status_code, x.content from public.fx_fetch f join net._http_response x on x.id = f.id loop
    begin
      if r.status_code = 200 then
        j := r.content::jsonb -> 'tether';
        foreach c in array array['try', 'eur', 'aed'] loop
          v := (j ->> c)::numeric;
          select value::numeric into prev from public.app_settings where key = 'usdt_' || c;
          select value::timestamptz into prev_at from public.app_settings where key = 'usdt_' || c || '_at';
          -- Hatalı veri koruması: önceki kurdan %5'ten fazla sapan değer kabul edilmez
          if v > 0 and v < 10000 and (prev is null or prev_at is null or prev_at < now() - interval '1 day' or abs(v / prev - 1) <= 0.05) then
            insert into public.app_settings (key, value) values ('usdt_' || c, v::text), ('usdt_' || c || '_at', now()::text)
            on conflict (key) do update set value = excluded.value;
          end if;
        end loop;
      end if;
    exception when others then null;
    end;
    delete from public.fx_fetch where id = r.id;
  end loop;
  delete from public.fx_fetch where created_at < now() - interval '1 hour';
  select value into k from public.app_settings where key = 'coingecko_key';
  h := jsonb_build_object('accept', 'application/json', 'user-agent', 'Mozilla/5.0 (compatible; COINFORCE/1.0)');
  if k is not null then h := h || jsonb_build_object('x-cg-demo-api-key', k); end if;
  insert into public.fx_fetch (id) values (
    net.http_get(url := 'https://api.coingecko.com/api/v3/simple/price?ids=tether&vs_currencies=try,eur,aed',
                 headers := h, timeout_milliseconds := 10000));
end $function$;
