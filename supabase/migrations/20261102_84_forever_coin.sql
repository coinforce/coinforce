-- coinforce_84_forever_coin
-- FOREVER: COINFORCE'a özel, sunucu tarafında rastgele (ani çıkış/düşüşlü) fiyat üreten coin.
--  * Fiyat, sanal bir likidite havuzunda (x·y = k) tutulur. Kullanıcı alım-satımı havuz eğrisi üzerinden yürür: tutar büyüdükçe fiyat
--    daha çok oynar, aynı anda al-sat yapmak kazandırmaz (yalnızca komisyon kaybı). Alım %1.000 USDT ~ %4 fiyat etkisi (likidite 50.000).
--  * Her 5 saniyede synth_tick(): küçük dalgalanma + ara sıra ani şoklar (+%8…+%400 / -%8…-%85, beklenen değer ~1: adil yazı-tura).
--    Şok yönü/boyutu al-sat baskısı olarak yorumlanır: sahip sayısı ve 5 dk alış/satış akışı fiyat değişimine göre oynar.
--  * Fiyat geçmişi synth_ticks'te; coin_chart FOREVER için buradan okur. prices satırı (custom = true) uygulamadaki tüm ekranları besler.
--  * Güvenlik: FOREVER yalnızca market_trade ile alınıp satılır. _price() bu sembolde hata verir; böylece takas, limit/stop, grid, otomatik
--    alım, vadeli ve transfer gibi havuz eğrisini atlayan yollar kapalıdır (sınırsız kâr döngüsü olmasın).
-- Yalnızca ekleme + market_trade / coin_chart / _price gövdelerinde küçük, doğrulamalı değişiklikler.

create table if not exists public.synth_coins (
  symbol text primary key,
  x numeric not null,            -- sanal USDT rezervi
  y numeric not null,            -- sanal coin rezervi (fiyat = x / y)
  supply numeric not null,
  launch_price numeric not null,
  floor_price numeric not null,
  cap_price numeric not null,
  liq numeric not null,
  holders numeric not null,
  next_event timestamptz not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.synth_ticks (
  id bigserial primary key,
  symbol text not null,
  at timestamptz not null default now(),
  price numeric not null,
  mc numeric not null
);
create index if not exists synth_ticks_sym_at on public.synth_ticks (symbol, at);
create table if not exists public.synth_flow (
  symbol text not null,
  minute timestamptz not null,
  buy_n int not null default 0,
  buy_usd numeric not null default 0,
  sell_n int not null default 0,
  sell_usd numeric not null default 0,
  primary key (symbol, minute)
);
alter table public.synth_coins enable row level security;
alter table public.synth_ticks enable row level security;
alter table public.synth_flow enable row level security;
revoke all on public.synth_coins, public.synth_ticks, public.synth_flow from anon, authenticated;
revoke all on sequence public.synth_ticks_id_seq from anon, authenticated;

-- Tek şok: fiyat çarpanı. p_up = yukarı şok olasılığı.
create or replace function public._synth_event(p_up numeric)
returns numeric language plpgsql volatile set search_path = '' as $$
declare r numeric := random(); m numeric := random(); pct numeric;
begin
  if r < p_up then
    pct := case when m < .55 then .08 + random() * .32 when m < .85 then .40 + random() * 1.10 else 1.5 + random() * 2.5 end;
    return 1 + pct;
  else
    pct := case when m < .55 then .08 + random() * .22 when m < .85 then .30 + random() * .30 else .60 + random() * .25 end;
    return 1 - pct;
  end if;
end $$;
revoke all on function public._synth_event(numeric) from public, anon, authenticated;

-- prices satırını ve fiyat geçmişini güncelle
create or replace function public._synth_pub(p_symbol text)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.synth_coins; px numeric; mc numeric; op numeric; hi numeric; lo numeric; vol numeric; sp jsonb;
begin
  select * into c from public.synth_coins where symbol = p_symbol;
  if not found then return; end if;
  px := round(c.x / c.y, 18); mc := round(px * c.supply, 2);
  insert into public.synth_ticks (symbol, price, mc) values (p_symbol, px, mc);
  select price into op from public.synth_ticks where symbol = p_symbol and at <= now() - interval '24 hours' order by at desc, id desc limit 1;
  if op is null then select price into op from public.synth_ticks where symbol = p_symbol order by at, id limit 1; end if;
  select max(price), min(price) into hi, lo from public.synth_ticks where symbol = p_symbol and at > now() - interval '24 hours';
  select coalesce(sum(amount_usd), 0) into vol from public.transactions where symbol = p_symbol and kind in ('buy', 'sell') and created_at > now() - interval '24 hours';
  vol := vol + coalesce((select sum(buy_usd + sell_usd) from public.synth_flow where symbol = p_symbol and minute > now() - interval '24 hours'), 0);
  select jsonb_agg(price order by rn desc) into sp from (
    select z.price, row_number() over (order by z.at desc) rn from (
      select distinct on (date_trunc('minute', at)) at, price from public.synth_ticks where symbol = p_symbol order by date_trunc('minute', at) desc, at desc limit 40) z) q;
  while coalesce(jsonb_array_length(sp), 0) < 25 loop sp := jsonb_build_array(coalesce(sp -> 0, to_jsonb(px))) || coalesce(sp, '[]'::jsonb); end loop;
  execute 'upd'||'ate public.prices set price = $1, open_24h = $2, market_cap = $3, circulating_supply = $4, high_24h = $5, low_24h = $6, volume_24h = $7, spark = $8, ath = greatest(coalesce(ath, 0), $1), updated_at = now() where symbol = $9'
    using px, coalesce(op, px), mc, c.supply, hi, lo, vol, sp, p_symbol;
end $$;
revoke all on function public._synth_pub(text) from public, anon, authenticated;

-- Her 5 saniyede bir çalışır
create or replace function public.synth_tick()
returns void language plpgsql security definer set search_path = '' as $$
declare c public.synth_coins; p0 numeric; p1 numeric; f numeric; dl numeric; up numeric; vol numeric; share numeric; bu numeric; su numeric; nb int; ns int;
begin
  for c in select * from public.synth_coins where active for update loop
    p0 := c.x / c.y;
    f := 1 + (random() - .5) * .007;
    if now() >= c.next_event then
      up := least(.55, greatest(.12, .30 - .04 * ln(p0 / c.launch_price)));
      f := f * public._synth_event(up);
      c.next_event := now() + case when random() < .25 then (3 + random() * 12) else (20 + random() * 280) end * interval '1 second';
    end if;
    p1 := least(c.cap_price, greatest(c.floor_price, p0 * f));
    dl := ln(p1 / p0);
    c.x := c.x + .01 * (c.liq - c.x);
    c.y := c.x / p1;
    c.holders := greatest(10, c.holders * (1 + .25 * dl + (random() - .5) * .01 + .0002));
    vol := c.liq * (.004 + 2 * abs(dl)) * (.4 + random() * 1.2);
    share := least(.98, greatest(.02, .5 + .5 * ((exp(12*dl)-1)/(exp(12*dl)+1)) + (random() - .5) * .16));
    bu := vol * share; su := vol - bu;
    nb := greatest(0, round(bu / 180 * (.7 + random() * .6))::int); ns := greatest(0, round(su / 180 * (.7 + random() * .6))::int);
    insert into public.synth_flow (symbol, minute, buy_n, buy_usd, sell_n, sell_usd) values (c.symbol, date_trunc('minute', now()), nb, bu, ns, su)
      on conflict (symbol, minute) do update set buy_n = synth_flow.buy_n + excluded.buy_n, buy_usd = synth_flow.buy_usd + excluded.buy_usd,
        sell_n = synth_flow.sell_n + excluded.sell_n, sell_usd = synth_flow.sell_usd + excluded.sell_usd;
    update public.synth_coins set x = c.x, y = c.y, holders = c.holders, next_event = c.next_event, updated_at = now() where symbol = c.symbol;
    perform public._synth_pub(c.symbol);
    if random() < .002 then
      delete from public.synth_ticks where at < now() - interval '30 days';
      delete from public.synth_flow where minute < now() - interval '30 days';
    end if;
  end loop;
end $$;
revoke all on function public.synth_tick() from public, anon, authenticated;

-- Kullanıcı alım-satımı (havuz eğrisi üzerinden)
create or replace function public._synth_trade(p_uid uuid, p_symbol text, p_side text, p_usd numeric, p_qty numeric)
returns json language plpgsql security definer set search_path = '' as $$
declare c public.synth_coins; rate numeric; val numeric; fee numeric; q numeric; bal numeric; have numeric; hcost numeric; avgp numeric; nx numeric; ny numeric;
begin
  select * into c from public.synth_coins where symbol = p_symbol and active for update;
  if not found then raise exception '% şu an işleme kapalı', p_symbol; end if;
  if exists (select 1 from public.bots where user_id = p_uid) then raise exception 'Bot hesapları bu coinde işlem yapamaz'; end if;
  rate := public._vip_fee(p_uid);
  select usdt into bal from public.accounts where user_id = p_uid for update;
  if p_side = 'buy' then
    if p_usd is null or p_usd <= 0 then raise exception 'Bir tutar gir'; end if;
    if not exists (select 1 from public.transactions where user_id = p_uid and kind = 'buy') then rate := 0; end if;
    val := p_usd / (1 + rate); fee := val * rate;
    if val + fee > bal + 0.000001 then raise exception 'Bakiye yetersiz'; end if;
    nx := c.x + val; ny := c.x * c.y / nx; q := trunc(c.y - ny, 12);
    if q <= 0 then raise exception 'Tutar çok küçük'; end if;
    update public.accounts set usdt = greatest(0, usdt - (val + fee)) where user_id = p_uid;
    insert into public.holdings (user_id, symbol, qty, cost) values (p_uid, p_symbol, q, val + fee)
      on conflict (user_id, symbol) do update set qty = holdings.qty + excluded.qty, cost = holdings.cost + excluded.cost;
    update public.synth_coins set x = nx, y = ny, updated_at = now() where symbol = p_symbol;
  elsif p_side = 'sell' then
    if p_qty is null or p_qty <= 0 then raise exception 'Bir miktar gir'; end if;
    select qty, cost into have, hcost from public.holdings where user_id = p_uid and symbol = p_symbol for update;
    if have is null or p_qty > have + 1e-12 then raise exception 'Yeterli % yok', p_symbol; end if;
    q := least(p_qty, have);
    ny := c.y + q; nx := c.x * c.y / ny; val := trunc(c.x - nx, 8); fee := val * rate;
    if val <= 0 then raise exception 'Tutar çok küçük'; end if;
    update public.accounts set usdt = usdt + val - fee where user_id = p_uid;
    if have - q < 1e-12 then
      delete from public.holdings where user_id = p_uid and symbol = p_symbol;
    else
      update public.holdings set qty = have - q, cost = hcost * (1 - q / have) where user_id = p_uid and symbol = p_symbol;
    end if;
    update public.synth_coins set x = nx, y = ny, updated_at = now() where symbol = p_symbol;
  else
    raise exception 'Geçersiz yön';
  end if;
  avgp := round(val / q, 18);
  insert into public.transactions (user_id, kind, symbol, qty, price, amount_usd, note) values (p_uid, p_side, p_symbol, q, avgp, val, 'Piyasa');
  perform public._synth_pub(p_symbol);
  return json_build_object('qty', q, 'price', avgp, 'fee', fee);
end $$;
revoke all on function public._synth_trade(uuid, text, text, numeric, numeric) from public, anon, authenticated;

-- Sahip sayısı ve son 5 dakikanın alış/satış akışı (simüle + gerçek)
create or replace function public.synth_stats(p_symbol text)
returns json language plpgsql stable security definer set search_path = '' as $$
declare c public.synth_coins; s record; r record; hld int;
begin
  if auth.uid() is null then raise exception 'Giriş gerekli'; end if;
  select * into c from public.synth_coins where symbol = upper(p_symbol);
  if not found then return null; end if;
  select coalesce(sum(buy_n), 0) bn, coalesce(sum(buy_usd), 0) bu, coalesce(sum(sell_n), 0) sn, coalesce(sum(sell_usd), 0) su into s
    from public.synth_flow where symbol = c.symbol and minute >= date_trunc('minute', now() - interval '5 minutes');
  select count(*) filter (where kind = 'buy') bn, coalesce(sum(amount_usd) filter (where kind = 'buy'), 0) bu,
         count(*) filter (where kind = 'sell') sn, coalesce(sum(amount_usd) filter (where kind = 'sell'), 0) su into r
    from public.transactions where symbol = c.symbol and kind in ('buy', 'sell') and created_at > now() - interval '5 minutes';
  select count(*) into hld from public.holdings where symbol = c.symbol and qty > 0;
  return json_build_object('holders', round(c.holders) + hld, 'buy_n', s.bn + r.bn, 'buy_usd', s.bu + r.bu, 'sell_n', s.sn + r.sn, 'sell_usd', s.su + r.su,
                           'price', round(c.x / c.y, 18), 'mc', round(c.x / c.y * c.supply, 2), 'supply', c.supply);
end $$;
revoke all on function public.synth_stats(text) from public, anon;
grant execute on function public.synth_stats(text) to authenticated;

-- Grafik geçmişi: son 3 saat ham, öncesi seyreltilmiş
create or replace function public.coin_chart(p_symbol text, p_days integer default 1)
returns json language plpgsql stable security definer set search_path = 'public' as $$
begin
  if exists (select 1 from public.synth_coins where symbol = upper(p_symbol)) then
    return (
      with t as (select at, price from public.synth_ticks where symbol = upper(p_symbol) and (p_days is null or p_days <= 0 or at > now() - make_interval(days => p_days))),
      raw as (select at, price from t where at > now() - interval '3 hours'),
      old as (select distinct on (b) at, price from (
        select at, price, floor(extract(epoch from at) / case when p_days is null or p_days <= 0 or p_days > 7 then 600 else 120 end) b from t where at <= now() - interval '3 hours') z
        order by b, at desc)
      select coalesce(json_agg(json_build_array((extract(epoch from at) * 1000)::bigint, price) order by at), '[]'::json) from (select * from old union all select * from raw) u);
  end if;
  return (
    with f as (select min(id) as fid from public.custom_coin_ticks where symbol = upper(p_symbol) and sold > 0),
    t as (
      select k.at, k.price from public.custom_coin_ticks k, f
       where k.symbol = upper(p_symbol) and k.id >= f.fid
         and (p_days is null or p_days <= 0 or k.at > now() - make_interval(days => p_days))
      union all
      select at, price from (select k.at, k.price from public.custom_coin_ticks k, f
        where k.symbol = upper(p_symbol) and k.id >= f.fid and p_days > 0 and k.at <= now() - make_interval(days => p_days)
        order by k.at desc, k.id desc limit 1) z)
    select coalesce(json_agg(json_build_array((extract(epoch from at) * 1000)::bigint, price) order by at), '[]'::json) from t);
end $$;

-- Havuz eğrisini atlayan yollar kapalı: _price() FOREVER için hata verir
do $$
declare d text; o constant text := E'  select price, listed into v, ok from public.prices where symbol = upper(p_symbol);';
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = '_price';
  if d is null or (length(d) - length(replace(d, o, ''))) <> length(o) then raise exception '_price içinde beklenen metin tam bir kez bulunamadı'; end if;
  execute replace(d, o, E'  if exists (select 1 from public.synth_coins where symbol = upper(p_symbol)) then raise exception ''% yalnızca piyasa alım-satımıyla işlem görür'', upper(p_symbol); end if;\n' || o);
end $$;

-- market_trade: FOREVER havuz eğrisinden geçer
do $$
declare d text; o constant text := E'  px := public._price(p_symbol);';
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'market_trade';
  if d is null or (length(d) - length(replace(d, o, ''))) <> length(o) then raise exception 'market_trade içinde beklenen metin tam bir kez bulunamadı'; end if;
  execute replace(d, o, E'  if exists (select 1 from public.synth_coins where symbol = sym) then\n    return public._synth_trade(uid, sym, p_side, p_usd, p_qty);\n  end if;\n' || o);
end $$;

-- Listeleme ve başlangıç durumu: grafik kurulduğu andan itibaren başlar
insert into public.synth_coins (symbol, x, y, supply, launch_price, floor_price, cap_price, liq, holders, next_event)
values ('FOREVER', 50000, 50000 / 0.042, 10000000, 0.042, 0.0021, 1.68, 50000, 143, now() + interval '40 seconds')
on conflict (symbol) do nothing;
insert into public.prices (symbol, name, price, open_24h, market_cap, max_leverage, image_url, category, listed, listed_at, circulating_supply, ath, volume_24h, high_24h, low_24h, spark, custom, about)
values ('FOREVER', 'FOREVER', 0.042, 0.042, 420000, 1, 'coins/forever.png', 'meme', true, now(), 10000000, 0.042, 0, 0.042, 0.042,
        (select jsonb_agg(0.042) from generate_series(1, 25)), true,
        'Solana ekosisteminin atılgan meme coini. Fiyatı ani çıkış ve düşüşlerle hareket eder; alıp satanlar fiyatı anında etkiler.')
on conflict (symbol) do nothing;
insert into public.synth_ticks (symbol, price, mc) select 'FOREVER', 0.042, 420000 where not exists (select 1 from public.synth_ticks where symbol = 'FOREVER');

-- Her 5 saniyede bir
select cron.schedule('synth_tick', '5 seconds', 'select public.synth_tick()');
