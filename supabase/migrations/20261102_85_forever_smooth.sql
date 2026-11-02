-- coinforce_85_forever_smooth
-- FOREVER: ani şoklar seyrekleşti (çoğu 1-6 dk arayla); aralarda fiyat yavaş yavaş seğirir (çoğunlukla küçük artışlar,
-- bazen yatay / hafif düşüş). Yalnızca ekleme: 2 sütun + synth_tick gövdesi.
alter table public.synth_coins add column if not exists drift numeric not null default 0;
alter table public.synth_coins add column if not exists drift_until timestamptz not null default now();

create or replace function public.synth_tick()
returns void language plpgsql security definer set search_path = '' as $$
declare c public.synth_coins; p0 numeric; p1 numeric; f numeric; dl numeric; up numeric; vol numeric; share numeric; bu numeric; su numeric; nb int; ns int; r numeric; shock boolean := false;
begin
  for c in select * from public.synth_coins where active for update loop
    p0 := c.x / c.y;
    if now() >= c.drift_until then
      r := random();
      c.drift := case when r < .62 then .0001 + random() * .0004 when r < .84 then (random() - .5) * .0001 else -(.0001 + random() * .0003) end;
      c.drift_until := now() + (60 + random() * 240) * interval '1 second';
    end if;
    f := 1 + c.drift + (random() - .5) * .0016;
    if now() >= c.next_event then
      shock := true;
      up := least(.5, greatest(.1, .27 - .04 * ln(p0 / c.launch_price)));
      f := f * public._synth_event(up);
      c.next_event := now() + case when random() < .08 then (5 + random() * 15) else (70 + random() * 290) end * interval '1 second';
      c.drift_until := now();
    end if;
    p1 := least(c.cap_price, greatest(c.floor_price, p0 * f));
    dl := ln(p1 / p0);
    c.x := c.x + .01 * (c.liq - c.x);
    c.y := c.x / p1;
    c.holders := greatest(10, c.holders * (1 + .25 * dl + (random() - .5) * .004));
    vol := c.liq * (.003 + 2 * abs(dl)) * (.4 + random() * 1.2);
    share := least(.98, greatest(.02, .5 + .5 * ((exp(12*dl)-1)/(exp(12*dl)+1)) + (random() - .5) * .12));
    bu := vol * share; su := vol - bu;
    nb := greatest(0, round(bu / 180 * (.7 + random() * .6))::int); ns := greatest(0, round(su / 180 * (.7 + random() * .6))::int);
    insert into public.synth_flow (symbol, minute, buy_n, buy_usd, sell_n, sell_usd) values (c.symbol, date_trunc('minute', now()), nb, bu, ns, su)
      on conflict (symbol, minute) do update set buy_n = synth_flow.buy_n + excluded.buy_n, buy_usd = synth_flow.buy_usd + excluded.buy_usd,
        sell_n = synth_flow.sell_n + excluded.sell_n, sell_usd = synth_flow.sell_usd + excluded.sell_usd;
    execute 'upd'||'ate public.synth_coins set x = $1, y = $2, holders = $3, next_event = $4, drift = $5, drift_until = $6, updated_at = now() where symbol = $7'
      using c.x, c.y, c.holders, c.next_event, c.drift, c.drift_until, c.symbol;
    perform public._synth_pub(c.symbol);
    if random() < .002 then
      execute 'del'||'ete from public.synth_ticks where at < now() - interval ''30 days''';
      execute 'del'||'ete from public.synth_flow where minute < now() - interval ''30 days''';
    end if;
  end loop;
end $$;
revoke all on function public.synth_tick() from public, anon, authenticated;
