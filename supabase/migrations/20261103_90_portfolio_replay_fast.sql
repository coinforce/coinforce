-- portfolio_replay v3: yoğun (bot) hesaplarda 86 sn / 7 MB sorunu.
-- 1) Eğri: her aralık adımı için indeksle tek anlık görüntü okunur (255 bin satırı taramak yerine ~180 sorgu).
-- 2) Maliyet bazı: yalnızca son 5000 işlem taranır (normal kullanıcılar için tam geçmiş, birkaç bin işlemi aşan hesaplar için yaklaşık).
-- Sadece fonksiyonu yeniler; veri/tablo değişikliği yok.
create or replace function public.portfolio_replay(p_user uuid, p_range text default '24h')
returns json language plpgsql stable security definer set search_path to 'public' as $function$
declare since timestamptz; step interval; q jsonb := '{}'::jsonb; c jsonb := '{}'::jsonb; r record; wins jsonb := '[]'::jsonb; curve json;
        hq numeric; hc numeric; sold numeric; pnl numeric; n int := 0; tot numeric := 0; e0 numeric; enow numeric;
begin
  if auth.uid() is null then raise exception 'Oturum açmalısın'; end if;
  case p_range
    when '7d'  then since := now() - interval '7 days';  step := interval '1 hour';
    when '30d' then since := now() - interval '30 days'; step := interval '4 hours';
    when 'all' then since := now() - interval '35 days'; step := interval '6 hours';
    else            since := now() - interval '24 hours'; step := interval '10 minutes';
  end case;
  for r in select kind, symbol, qty, amount_usd, created_at from (
             select kind, symbol, qty, amount_usd, created_at, id from public.transactions
              where user_id = p_user and kind in ('buy', 'sell', 'perp_close') order by created_at desc, id desc limit 5000) t
            order by created_at, id loop
    pnl := null;
    if r.kind = 'buy' then
      q := jsonb_set(q, array[r.symbol], to_jsonb(coalesce((q ->> r.symbol)::numeric, 0) + r.qty));
      c := jsonb_set(c, array[r.symbol], to_jsonb(coalesce((c ->> r.symbol)::numeric, 0) + r.amount_usd));
    elsif r.kind = 'sell' then
      hq := coalesce((q ->> r.symbol)::numeric, 0); hc := coalesce((c ->> r.symbol)::numeric, 0);
      if hq > 0 and r.qty > 0 then
        sold := least(r.qty, hq);
        pnl := r.amount_usd * sold / r.qty - hc / hq * sold;
        q := jsonb_set(q, array[r.symbol], to_jsonb(hq - sold));
        c := jsonb_set(c, array[r.symbol], to_jsonb(hc - hc / hq * sold));
      end if;
    else
      pnl := r.amount_usd;
    end if;
    if pnl is not null and pnl >= 10000 then
      n := n + 1; tot := tot + pnl;
      wins := wins || jsonb_build_array(jsonb_build_object('t', (extract(epoch from r.created_at) * 1000)::bigint, 's', r.symbol, 'p', round(pnl, 2)));
    end if;
  end loop;
  if jsonb_array_length(wins) > 60 then wins := (select jsonb_agg(x) from (select x from jsonb_array_elements(wins) x order by (x ->> 't')::bigint desc limit 60) z); end if;
  select s.equity into e0 from public.equity_snapshots s where s.user_id = p_user and s.at < since order by s.at desc limit 1;
  enow := round(public._equity(p_user), 2);
  select coalesce(json_agg(json_build_array((extract(epoch from at) * 1000)::bigint, e) order by at), '[]'::json) into curve from (
    select since as at, round(e0, 2) as e where e0 is not null
    union all
    select s.at, round(s.equity, 2)
      from generate_series(date_bin(step, since, timestamptz '2000-01-01'), now(), step) b(t)
      cross join lateral (select x.at, x.equity from public.equity_snapshots x
                           where x.user_id = p_user and x.at >= greatest(b.t, since) and x.at < b.t + step
                           order by x.at limit 1) s
    union all
    select now(), enow where enow is not null and exists (select 1 from public.accounts a where a.user_id = p_user)) z;
  return json_build_object('curve', curve, 'wins', wins, 'n', n, 'total', round(tot, 2), 'since', (extract(epoch from since) * 1000)::bigint);
end $function$;
