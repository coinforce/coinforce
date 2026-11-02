-- coinforce_91_telegram_pnl
-- Botun /pnl (/kar) komutu: kendi hesabın + toplu işlemde aktif hesapların 1 saat / 12 saat / 24 saatlik kâr-zararı.
-- Kâr/zarar = şimdiki özsermaye - ilgili sürenin başındaki özsermaye (equity_snapshots; hesap daha yeniyse ilk kayıt).
-- Yalnızca okuma; yalnızca service role (telegram-notify) çağırabilir. Yalnızca ekleme: yeni fonksiyon.

create or replace function public.tgx_pnl(p_tg_user bigint)
returns json language plpgsql stable security definer set search_path = '' as $$
declare n public.tg_notify; rows_ json;
begin
  select * into n from public.tg_notify where tg_user_id = p_tg_user and chat_id is not null;
  if n.user_id is null then return json_build_object('linked', false); end if;
  select coalesce(json_agg(x order by x.ord, x.username), '[]'::json) into rows_ from (
    select m.ord, m.username, m.me, e.eq,
           case when b1.eq  is null then null else round(e.eq - b1.eq, 2)  end as d1,
           case when b12.eq is null then null else round(e.eq - b12.eq, 2) end as d12,
           case when b24.eq is null then null else round(e.eq - b24.eq, 2) end as d24
      from (
        select 0 as ord, p.username, true as me, p.id as uid from public.profiles p where p.id = n.user_id
        union all
        select 1, g.username, false, g.member_id from cf_private.group_members(n.user_id) g
      ) m
      cross join lateral (select round(public._equity(m.uid), 2) as eq) e
      cross join lateral (select coalesce(
          (select s.equity from public.equity_snapshots s where s.user_id = m.uid and s.at <= now() - interval '1 hour' order by s.at desc limit 1),
          (select s.equity from public.equity_snapshots s where s.user_id = m.uid and s.at >  now() - interval '1 hour' order by s.at limit 1)) as eq) b1
      cross join lateral (select coalesce(
          (select s.equity from public.equity_snapshots s where s.user_id = m.uid and s.at <= now() - interval '12 hours' order by s.at desc limit 1),
          (select s.equity from public.equity_snapshots s where s.user_id = m.uid and s.at >  now() - interval '12 hours' order by s.at limit 1)) as eq) b12
      cross join lateral (select coalesce(
          (select s.equity from public.equity_snapshots s where s.user_id = m.uid and s.at <= now() - interval '24 hours' order by s.at desc limit 1),
          (select s.equity from public.equity_snapshots s where s.user_id = m.uid and s.at >  now() - interval '24 hours' order by s.at limit 1)) as eq) b24
  ) x;
  return json_build_object('linked', true, 'rows', rows_);
end $$;

revoke all on function public.tgx_pnl(bigint) from public, anon, authenticated;
grant execute on function public.tgx_pnl(bigint) to service_role;
