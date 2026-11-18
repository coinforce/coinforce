-- 103: Canlı fiyatlar borsalardan
-- Sorun: CoinGecko demo anahtarının aylık 10.000 istek kotası, 30 sn'de bir fiyat + 15 dk'da bir
-- kıvılcım + 5 dk'da bir kur çağrısıyla ayın ilk ~4 gününde bitiyordu (HTTP 429, error_code 10006).
-- 5 Kasım 03:45 UTC'den beri 56 coinin fiyatı, 7 günlük serisi ve USDT/TRY-EUR kuru donmuştu.
-- Çözüm: canlı fiyat, 24 saatlik açılış/en yüksek/en düşük/hacim borsaların herkese açık piyasa
-- verisinden (anahtarsız, aylık kotasız): Binance (46 coin), Gate (8), KuCoin (XMR), Kraken (TON).
-- Eşleşmeler 16 Kasım'da OKX ve CoinGecko fiyatlarıyla karşılaştırılarak doğrulandı (hepsi %2 içinde).
-- 7 günlük seri borsa mumlarından (15 dk'da bir), USDT/TRY ve EUR kuru Binance'ten (5 dk'da bir).
-- CoinGecko yalnızca piyasa değeri/arz/ATH/logo/toplam hacim için 30 dk'da bir çağrılır (~1.500 istek/ay).
-- Anahtarın aylık kotası dolarsa bu seyrek çağrı bir gün boyunca anahtarsız (herkese açık) uca gider.
-- Bir coinin borsa fiyatı 5 dk'dan uzun güncellenmezse yöneticiye saatte en fazla bir bildirim gider.
-- Yalnızca ekleme: yeni sütunlar (varsayılan null), yeni tablo ve fonksiyonlar; fetch_prices, fetch_fx,
-- fetch_sparks gövdeleri değişir (imzalar ve zamanlanmış işler aynı). Kullanıcı verisine, bakiyelere,
-- emirlere dokunmaz. Geri almak için: supabase/rollback/20261116_103_rollback.sql

alter table public.prices add column if not exists ex_src text;          -- binance | gate | kucoin | kraken
alter table public.prices add column if not exists ex_sym text;          -- borsadaki parite adı
alter table public.prices add column if not exists ex_at timestamptz;    -- borsadan son başarılı güncelleme
alter table public.prices add column if not exists cg_at timestamptz;    -- CoinGecko'dan son başarılı güncelleme
do $do$ begin
  if not exists (select 1 from pg_constraint where conname = 'prices_ex_src_ok') then
    alter table public.prices add constraint prices_ex_src_ok
      check (ex_src is null or ex_src in ('binance', 'gate', 'kucoin', 'kraken'));
  end if;
end $do$;

create table if not exists public.ex_fetch (
  id bigint primary key,                 -- net.http_get istek kimliği
  src text not null,
  kind text not null,                    -- tick | spark
  symbol text,                           -- coin başına isteklerde prices.symbol
  created_at timestamptz not null default now()
);
alter table public.ex_fetch enable row level security;
revoke all on public.ex_fetch from anon, authenticated;

-- Eşleşmeler (sembol + CoinGecko kimliği birlikte kontrol edilir)
update public.prices p set ex_src = 'binance', ex_sym = p.symbol || 'USDT'
  from (values ('AAVE','aave'),('ADA','cardano'),('APT','aptos'),('ARB','arbitrum'),('ATOM','cosmos'),('AVAX','avalanche-2'),
    ('BCH','bitcoin-cash'),('BNB','binancecoin'),('BOME','book-of-meme'),('BONK','bonk'),('BTC','bitcoin'),('DOGE','dogecoin'),
    ('DOT','polkadot'),('ENA','ethena'),('ETC','ethereum-classic'),('ETH','ethereum'),('FIL','filecoin'),('FLOKI','floki'),
    ('HBAR','hedera-hashgraph'),('HYPE','hyperliquid'),('ICP','internet-computer'),('INJ','injective-protocol'),
    ('JUP','jupiter-exchange-solana'),('LINK','chainlink'),('LTC','litecoin'),('NEAR','near'),('ONDO','ondo-finance'),
    ('OP','optimism'),('PENGU','pudgy-penguins'),('PEPE','pepe'),('POL','polygon-ecosystem-token'),('RENDER','render-token'),
    ('SEI','sei-network'),('SHIB','shiba-inu'),('SOL','solana'),('SUI','sui'),('TAO','bittensor'),('TRUMP','official-trump'),
    ('TRX','tron'),('TURBO','turbo'),('UNI','uniswap'),('VIRTUAL','virtual-protocol'),('WIF','dogwifcoin'),('XLM','stellar'),
    ('XRP','ripple'),('ZEC','zcash')) m(sym, cg)
 where p.symbol = m.sym and p.coingecko_id = m.cg and p.ex_src is null;
update public.prices p set ex_src = 'gate', ex_sym = p.symbol || '_USDT'
  from (values ('BRETT','based-brett'),('FARTCOIN','fartcoin'),('KAS','kaspa'),('MEW','cat-in-a-dogs-world'),('MNT','mantle'),
    ('MOG','mog-coin'),('POPCAT','popcat'),('SPX','spx6900')) m(sym, cg)
 where p.symbol = m.sym and p.coingecko_id = m.cg and p.ex_src is null;
update public.prices set ex_src = 'kucoin', ex_sym = 'XMR-USDT' where symbol = 'XMR' and coingecko_id = 'monero' and ex_src is null;
update public.prices set ex_src = 'kraken', ex_sym = 'TONUSD' where symbol = 'TON' and coingecko_id = 'the-open-network' and ex_src is null;

-- İlk uyarı en erken bir saat sonra (geçiş anında yanlış alarm olmasın)
insert into public.app_settings (key, value) values ('price_alert_at', now()::text)
  on conflict (key) do update set value = excluded.value;

-- Tek coine borsa verisini uygular
create or replace function public._ex_apply(p_sym text, p_px numeric, p_open numeric, p_hi numeric, p_lo numeric, p_vol numeric)
returns boolean language plpgsql security definer set search_path = public as $$
declare cur record;
begin
  if p_px is null or p_px <= 0 then return false; end if;
  select price, ex_at into cur from public.prices where symbol = p_sym;
  if not found then return false; end if;
  -- hatalı veri koruması: borsa verisi tazeyken tek adımda %50'den büyük sıçrama kabul edilmez
  if cur.ex_at > now() - interval '10 minutes' and cur.price > 0 and abs(p_px / cur.price - 1) > 0.5 then return false; end if;
  update public.prices p set
    price = p_px,
    open_24h = case when p_open > 0 then p_open else p.open_24h end,
    high_24h = case when p_hi > 0 then greatest(p_hi, p_px) else p.high_24h end,
    low_24h = case when p_lo > 0 then least(p_lo, p_px) else p.low_24h end,
    -- toplam (tüm borsalar) hacmi CoinGecko'dan geliyorsa onu koru; yoksa borsa hacmi
    volume_24h = case when p.cg_at > now() - interval '2 hours' then p.volume_24h when p_vol >= 0 then p_vol else p.volume_24h end,
    market_cap = case when p.circulating_supply > 0 then p_px * p.circulating_supply else p.market_cap end,
    ath = case when p.ath is null or p_px > p.ath then p_px else p.ath end,
    updated_at = now(), ex_at = now()
  where p.symbol = p_sym;
  return true;
end $$;
revoke all on function public._ex_apply(text, numeric, numeric, numeric, numeric, numeric) from public, anon, authenticated;

-- Borsa cevaplarını işler, yeni istekleri gönderir, bayatlığı izler (fetch_prices içinden 30 sn'de bir)
create or replace function public.fetch_ex_prices()
returns void language plpgsql security definer set search_path = public, extensions as $$
declare r record; j jsonb; e jsonb; px numeric; op numeric; sp jsonb; syms text; t0 bigint; n int; s text; gone boolean;
begin
  -- 1) gelen cevaplar
  for r in select f.id, f.src, f.kind, f.symbol, x.status_code, x.content
             from public.ex_fetch f join net._http_response x on x.id = f.id order by f.id loop
    begin
      -- borsadan çıkarılmış parite: eşleşmeyi kaldır (fiyat CoinGecko'dan alınır), yöneticiye bildir
      gone := r.kind = 'tick' and r.symbol is not null and (
           (r.src = 'binance' and r.status_code = 400 and r.content like '%-1121%')
        or (r.src = 'gate' and r.status_code = 400 and r.content like '%INVALID_CURRENCY%')
        or (r.src = 'kucoin' and r.status_code = 200 and r.content like '%"data":{%'
            and r.content::jsonb -> 'data' ->> 'last' is null and r.content::jsonb -> 'data' ->> 'symbol' is not null)
        or (r.src = 'kraken' and r.content like '%Unknown asset pair%'));
      if gone then
        update public.prices set ex_src = null, ex_sym = null where symbol = r.symbol and ex_src = r.src;
        perform public._notify(a.id, 'Fiyat kaynağı: ' || r.symbol || ' artık ' || initcap(r.src) ||
          ' borsasında işlem görmüyor; fiyatı CoinGecko üzerinden alınacak.', r.symbol) from public.profiles a where a.is_admin;
      elsif r.kind = 'tick' and r.src = 'binance' and r.symbol is null and r.status_code = 400 then
        -- toplu istekte geçersiz parite var: 10 dk tek tek iste, geçersiz olan bulunup çıkarılsın
        insert into public.app_settings (key, value) values ('binance_split_at', now()::text)
          on conflict (key) do update set value = excluded.value;
      elsif r.status_code = 200 and r.content is not null then
        j := r.content::jsonb;
        if r.kind = 'tick' then
          if r.src = 'binance' then
            -- işlem görmeyen (durdurulmuş) parite eski fiyat döndürür: son 1 saatte işlem şartı
            t0 := (extract(epoch from now()) * 1000)::bigint - 3600000;
            if jsonb_typeof(j) = 'object' then j := jsonb_build_array(j); end if;
            perform public._ex_apply(p.symbol, (t.x ->> 'lastPrice')::numeric, (t.x ->> 'openPrice')::numeric,
                (t.x ->> 'highPrice')::numeric, (t.x ->> 'lowPrice')::numeric, (t.x ->> 'quoteVolume')::numeric)
              from jsonb_array_elements(j) t(x) join public.prices p on p.ex_src = 'binance' and p.ex_sym = t.x ->> 'symbol'
             where coalesce((t.x ->> 'closeTime')::bigint, 0) > t0 and coalesce((t.x ->> 'count')::bigint, 1) > 0;
          elsif r.src = 'gate' then
            e := j -> 0;
            px := (e ->> 'last')::numeric;
            if px > 0 then
              op := case when nullif(e ->> 'change_percentage', '') is not null then px / (1 + (e ->> 'change_percentage')::numeric / 100) end;
              perform public._ex_apply(r.symbol, px, op, (e ->> 'high_24h')::numeric, (e ->> 'low_24h')::numeric, (e ->> 'quote_volume')::numeric);
            end if;
          elsif r.src = 'kucoin' then
            e := j -> 'data';
            px := (e ->> 'last')::numeric;
            if px > 0 then
              op := case when (e ->> 'changeRate') is not null then px / (1 + (e ->> 'changeRate')::numeric) end;
              perform public._ex_apply(r.symbol, px, op, (e ->> 'high')::numeric, (e ->> 'low')::numeric, (e ->> 'volValue')::numeric);
            end if;
          elsif r.src = 'kraken' then
            -- sonuç anahtarı istenen paritenin adından farklı olabilir (XMRUSD → XXMRZUSD); tek parite istenir
            select kv.value into e from jsonb_each(j -> 'result') kv limit 1;
            px := (e -> 'c' ->> 0)::numeric;
            if px > 0 then
              -- Kraken kayan 24 saatlik açılış vermez: 7 günlük seriden 24 saat önceki kapanış, yoksa günün açılışı
              select case when jsonb_array_length(p.spark) >= 25 then (p.spark ->> (jsonb_array_length(p.spark) - 25))::numeric end
                into op from public.prices p where p.symbol = r.symbol;
              op := coalesce(op, (e ->> 'o')::numeric);
              perform public._ex_apply(r.symbol, px, op, (e -> 'h' ->> 1)::numeric, (e -> 'l' ->> 1)::numeric,
                (e -> 'v' ->> 1)::numeric * (e -> 'p' ->> 1)::numeric);
            end if;
          end if;
        elsif r.kind = 'spark' then
          sp := null;
          if r.src = 'binance' then        -- [[açılışZamanı, a, y, d, k, ...], ...]
            select jsonb_agg((k ->> 4)::numeric order by (k ->> 0)::bigint) into sp from jsonb_array_elements(j) k;
          elsif r.src = 'gate' then        -- [[zaman, kotaHacmi, k, y, d, a, hacim, kapandı], ...]
            select jsonb_agg((k ->> 2)::numeric order by (k ->> 0)::bigint) into sp from jsonb_array_elements(j) k;
          elsif r.src = 'kucoin' then      -- {data: [[zaman, a, k, y, d, hacim, tutar], ...]} yeniden eskiye
            select jsonb_agg((k ->> 2)::numeric order by (k ->> 0)::bigint) into sp from jsonb_array_elements(j -> 'data') k;
          elsif r.src = 'kraken' then      -- {result: {PARİTE: [[zaman, a, y, d, k, ...], ...], last: n}}
            select jsonb_agg(z.c order by z.t) into sp from (
              select (k ->> 0)::bigint t, (k ->> 4)::numeric c
                from jsonb_each(j -> 'result') kv, jsonb_array_elements(kv.value) k
               where jsonb_typeof(kv.value) = 'array' order by 1 desc limit 168) z;
          end if;
          if sp is not null and jsonb_array_length(sp) >= 24 then
            -- son 168 saat (CoinGecko'nun 7 günlük serisiyle aynı biçim)
            if jsonb_array_length(sp) > 168 then
              select jsonb_agg(v order by i) into sp from jsonb_array_elements(sp) with ordinality a(v, i) where i > jsonb_array_length(sp) - 168;
            end if;
            update public.prices set spark = sp where symbol = r.symbol;
          end if;
        end if;
      end if;
    exception when others then null;   -- hatalı tek cevap diğerlerini durdurmasın
    end;
    delete from public.ex_fetch where id = r.id;
  end loop;
  delete from public.ex_fetch where created_at < now() - interval '10 minutes';

  -- 2) yeni fiyat istekleri
  if coalesce((select value::timestamptz from public.app_settings where key = 'binance_split_at'), '-infinity') > now() - interval '10 minutes' then
    insert into public.ex_fetch (id, src, kind, symbol)
      select net.http_get(url := 'https://data-api.binance.vision/api/v3/ticker/24hr?symbol=' || ex_sym,
        timeout_milliseconds := 10000), 'binance', 'tick', symbol
        from public.prices where ex_src = 'binance';
  else
    select string_agg('%22' || ex_sym || '%22', ',' order by symbol) into syms from public.prices where ex_src = 'binance';
    if syms is not null then
      insert into public.ex_fetch (id, src, kind) values (net.http_get(
        url := 'https://data-api.binance.vision/api/v3/ticker/24hr?symbols=%5B' || syms || '%5D',
        timeout_milliseconds := 10000), 'binance', 'tick');
    end if;
  end if;
  insert into public.ex_fetch (id, src, kind, symbol)
    select net.http_get(url := case ex_src
        when 'gate' then 'https://api.gateio.ws/api/v4/spot/tickers?currency_pair=' || ex_sym
        when 'kucoin' then 'https://api.kucoin.com/api/v1/market/stats?symbol=' || ex_sym
        else 'https://api.kraken.com/0/public/Ticker?pair=' || ex_sym end,
      timeout_milliseconds := 10000), ex_src, 'tick', symbol
      from public.prices where ex_src in ('gate', 'kucoin', 'kraken');

  -- 3) izleme: 5 dk'dan uzun güncellenmeyen coin varsa yöneticilere saatte en fazla bir bildirim
  select count(*), string_agg(symbol, ', ' order by symbol) into n, s from public.prices
   where ex_src is not null and listed is not false and coalesce(ex_at, '-infinity') < now() - interval '5 minutes';
  if n > 0 and coalesce((select value::timestamptz from public.app_settings where key = 'price_alert_at'), '-infinity') < now() - interval '1 hour' then
    insert into public.app_settings (key, value) values ('price_alert_at', now()::text)
      on conflict (key) do update set value = excluded.value;
    perform public._notify(a.id, 'Fiyat uyarısı: ' || n || ' coinin borsa fiyatı 5 dakikadır güncellenmiyor (' || left(s, 160) || ').', null)
      from public.profiles a where a.is_admin;
  end if;
end $$;
revoke all on function public.fetch_ex_prices() from public, anon, authenticated;

-- 7 günlük seri (saatlik kapanışlar) borsa mumlarından
create or replace function public.fetch_ex_sparks()
returns void language plpgsql security definer set search_path = public, extensions as $$
declare st bigint := extract(epoch from now() - interval '7 days 2 hours')::bigint;
begin
  insert into public.ex_fetch (id, src, kind, symbol)
    select net.http_get(url := case ex_src
        when 'binance' then 'https://data-api.binance.vision/api/v3/uiKlines?interval=1h&limit=168&symbol=' || ex_sym
        when 'gate' then 'https://api.gateio.ws/api/v4/spot/candlesticks?interval=1h&limit=168&currency_pair=' || ex_sym
        when 'kucoin' then 'https://api.kucoin.com/api/v1/market/candles?type=1hour&symbol=' || ex_sym || '&startAt=' || st
        else 'https://api.kraken.com/0/public/OHLC?interval=60&pair=' || ex_sym || '&since=' || st end,
      timeout_milliseconds := 15000), ex_src, 'spark', symbol
      from public.prices where ex_src is not null;
end $$;
revoke all on function public.fetch_ex_sparks() from public, anon, authenticated;

-- fetch_prices: borsa fiyatları + emir motoru; CoinGecko yalnızca 30 dk'da bir (borsası olmayan coin varsa 10 dk)
create or replace function public.fetch_prices()
returns void language plpgsql security definer set search_path = public, extensions as $$
declare r record; j jsonb; e jsonb; ids text; k text; h jsonb; last_cg timestamptz; gap interval;
begin
  -- 0) Borsa fiyatları (canlı)
  perform public.fetch_ex_prices();

  -- 1) CoinGecko cevapları: borsa verisi tazeyse fiyat alanlarına dokunulmaz
  for r in
    select f.id, x.status_code, x.content
    from public.price_fetch f join net._http_response x on x.id = f.id
    where not f.done order by f.id
  loop
    update public.price_fetch set done = true where id = r.id;
    if r.status_code = 429 and r.content like '%10006%' then
      -- anahtarın aylık kotası doldu: bir gün boyunca anahtarsız (herkese açık) uç kullanılır
      insert into public.app_settings (key, value) values ('cg_key_out_at', now()::text)
        on conflict (key) do update set value = excluded.value;
    end if;
    if r.status_code = 200 and r.content is not null then
      j := r.content::jsonb;
      if jsonb_typeof(j) = 'array' then
        for e in select * from jsonb_array_elements(j) loop
          if (e ->> 'current_price') is not null and (e ->> 'current_price')::numeric > 0 then
            update public.prices p set
              price = case when p.ex_at > now() - interval '5 minutes' then p.price else (e ->> 'current_price')::numeric end,
              open_24h = case when p.ex_at > now() - interval '5 minutes' then p.open_24h
                when (e ->> 'price_change_percentage_24h') is not null
                then (e ->> 'current_price')::numeric / (1 + (e ->> 'price_change_percentage_24h')::numeric / 100)
                else p.open_24h end,
              market_cap = case when p.ex_at > now() - interval '5 minutes' and (e ->> 'circulating_supply')::numeric > 0
                then p.price * (e ->> 'circulating_supply')::numeric
                else coalesce((e ->> 'market_cap')::numeric, p.market_cap) end,
              image_url = coalesce(e ->> 'image', p.image_url),
              circulating_supply = coalesce((e ->> 'circulating_supply')::numeric, p.circulating_supply),
              ath = greatest(coalesce((e ->> 'ath')::numeric, p.ath), p.ath),
              volume_24h = coalesce((e ->> 'total_volume')::numeric, p.volume_24h),
              high_24h = case when p.ex_at > now() - interval '5 minutes' then p.high_24h else coalesce((e ->> 'high_24h')::numeric, p.high_24h) end,
              low_24h = case when p.ex_at > now() - interval '5 minutes' then p.low_24h else coalesce((e ->> 'low_24h')::numeric, p.low_24h) end,
              spark = coalesce(e -> 'sparkline_in_7d' -> 'price', p.spark),
              listed = true,
              listed_at = coalesce(p.listed_at, now()),
              updated_at = now(),
              cg_at = now()
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
        where p.coingecko_id is not null and p.ex_src is null
          and (j -> p.coingecko_id ->> 'usd') is not null
          and (j -> p.coingecko_id ->> 'usd')::numeric > 0;
      end if;
    end if;
  end loop;
  delete from public.price_fetch where created_at < now() - interval '1 hour';

  -- 2) Emirler, likidasyonlar, alarmlar
  perform public.run_engine();

  -- 3) CoinGecko isteği (aylık kotayı aşmamak için seyrek)
  gap := case when exists (select 1 from public.prices where coingecko_id is not null and ex_src is null)
                then interval '10 minutes' else interval '30 minutes' end;
  select max(created_at) into last_cg from public.price_fetch;
  if last_cg is not null and last_cg > now() - gap then return; end if;
  select string_agg(coingecko_id, ',') into ids from public.prices where coingecko_id is not null;
  if ids is null then return; end if;
  select value into k from public.app_settings where key = 'coingecko_key';
  h := jsonb_build_object('accept', 'application/json', 'user-agent', 'Mozilla/5.0 (compatible; COINFORCE/1.0)');
  if k is not null and coalesce((select value::timestamptz from public.app_settings where key = 'cg_key_out_at'), '-infinity') < now() - interval '1 day' then
    h := h || jsonb_build_object('x-cg-demo-api-key', k);
  end if;
  insert into public.price_fetch (id) values (
    net.http_get(
      url := 'https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=' || ids ||
             '&per_page=250&price_change_percentage=24h',
      headers := h, timeout_milliseconds := 10000));
end $$;

-- fetch_sparks: borsa mumları; borsası olmayan CoinGecko coinleri için eski CoinGecko yolu
create or replace function public.fetch_sparks()
returns void language plpgsql security definer set search_path = public, extensions as $$
declare ids text; k text; h jsonb;
begin
  perform public.fetch_ex_sparks();
  select string_agg(coingecko_id, ',') into ids from public.prices where coingecko_id is not null and ex_src is null;
  if ids is null then return; end if;
  select value into k from public.app_settings where key = 'coingecko_key';
  h := jsonb_build_object('accept', 'application/json', 'user-agent', 'Mozilla/5.0 (compatible; COINFORCE/1.0)');
  if k is not null and coalesce((select value::timestamptz from public.app_settings where key = 'cg_key_out_at'), '-infinity') < now() - interval '1 day' then
    h := h || jsonb_build_object('x-cg-demo-api-key', k);
  end if;
  insert into public.price_fetch (id) values (
    net.http_get(url := 'https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=' || ids || '&per_page=250&sparkline=true&price_change_percentage=24h',
      headers := h, timeout_milliseconds := 15000));
end $$;

-- fetch_fx: USDT/TRY ve EUR kuru Binance'ten (AED, USD'ye 3,6725 sabit kurla bağlı)
create or replace function public.fetch_fx()
returns void language plpgsql security definer set search_path = public, extensions as $$
declare r record; j jsonb; c text; v numeric; prev numeric; prev_at timestamptz; vals jsonb; tr numeric; eu numeric;
begin
  for r in select f.id, x.status_code, x.content from public.fx_fetch f join net._http_response x on x.id = f.id loop
    begin
      if r.status_code = 200 then
        j := r.content::jsonb;
        if jsonb_typeof(j) = 'array' then
          select (t.x ->> 'price')::numeric into tr from jsonb_array_elements(j) t(x) where t.x ->> 'symbol' = 'USDTTRY';
          select (t.x ->> 'price')::numeric into eu from jsonb_array_elements(j) t(x) where t.x ->> 'symbol' = 'EURUSDT';
          vals := jsonb_build_object('try', tr, 'eur', case when eu > 0 then round(1 / eu, 6) end, 'aed', 3.6725);
        else
          vals := j -> 'tether';   -- eski CoinGecko biçimi (geçişte bekleyen cevap)
        end if;
        foreach c in array array['try', 'eur', 'aed'] loop
          v := (vals ->> c)::numeric;
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
  insert into public.fx_fetch (id) values (
    net.http_get(url := 'https://data-api.binance.vision/api/v3/ticker/price?symbols=%5B%22USDTTRY%22,%22EURUSDT%22%5D',
                 timeout_milliseconds := 10000));
end $$;
