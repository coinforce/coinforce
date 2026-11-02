-- coinforce_87_forever_recover
-- FOREVER: her ani düşüş/çıkıştan sonra fiyat kendini toparlar (sıçrama + birkaç dakikalık geri çekilme/toparlanma eğrisi).
-- Şok anında bir "çapa" fiyatı belirlenir (düşüşün ~%80'i, çıkışın ~%60'ı geri alınır); fiyat ona doğru kıvrılarak ilerler, çapa da
-- yavaşça başlangıç fiyatına döner. Taban civarındaki fiyat da başlangıç seviyesine doğru toparlanır. Yalnızca ekleme: 1 sütun + synth_tick.
alter table public.synth_coins add column if not exists anchor numeric;

create or replace function public.synth_tick()
returns void language plpgsql security definer set search_path = '' as $$
declare c public.synth_coins; p0 numeric; p1 numeric; f numeric; dl numeric; up numeric; vol numeric; share numeric; bu numeric; su numeric; nb int; ns int; sh numeric; g numeric; a numeric;
begin
  for c in select * from public.synth_coins where active for update loop
    p0 := c.x / c.y;
    a := coalesce(c.anchor, c.launch_price);
    if now() >= c.drift_until then
      c.drift := (random() + random() - 1) * .005;
      c.vol_mult := .6 + random() * 1.6;
      c.drift_until := now() + (30 + random() * 100) * interval '1 second';
    end if;
    g := (random() + random() + random() - 1.5) * 2;
    f := 1 + c.drift + .012 * greatest(-1.2, least(1.2, ln(a / p0))) + g * .004 * c.vol_mult;
    if now() >= c.next_event then
      up := least(.8, greatest(.2, .5 - .10 * ln(p0 / c.launch_price)));
      sh := public._synth_event(up);
      f := f * sh;
      a := p0 * power(sh, case when sh > 1 then .4 else .2 end);
      c.next_event := now() + case when random() < .15 then (6 + random() * 24) else (150 + random() * 450) end * interval '1 second';
      c.vol_mult := 1.5 + random();
    end if;
    a := a * power(c.launch_price / a, .002);
    c.anchor := a;
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
    execute 'upd'||'ate public.synth_coins set x = $1, y = $2, holders = $3, next_event = $4, drift = $5, drift_until = $6, vol_mult = $7, anchor = $8, updated_at = now() where symbol = $9'
      using c.x, c.y, c.holders, c.next_event, c.drift, c.drift_until, c.vol_mult, c.anchor, c.symbol;
    perform public._synth_pub(c.symbol);
    if random() < .002 then
      execute 'del'||'ete from public.synth_ticks where at < now() - interval ''30 days''';
      execute 'del'||'ete from public.synth_flow where minute < now() - interval ''30 days''';
    end if;
  end loop;
end $$;
revoke all on function public.synth_tick() from public, anon, authenticated;
