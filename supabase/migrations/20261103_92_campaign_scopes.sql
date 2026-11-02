-- coinforce_92_campaign_scopes
-- Hacim kampanyalarına (yalnızca ekleme) üç seçenek:
--   1) Coin kapsamı: symbols (sayılan coinler) + meme_chain (o zincirdeki bütün memecoinler, sonradan listelenenler de)
--      + scope_label (ekranda gösterilen kısa ad).
--   2) Sıralama kapsamı: rank_scope = 'community' → herkes katılır, ama her kullanıcı sıralamada yalnızca kendi
--      topluluğundaki (üyesi ya da sahibi olduğu, haber kanalı olmayan topluluklar) kişileri görür.
--   3) Ödül şekli: payout = 'highest_at_end' → ödül kampanya bitince, ulaşılan en yüksek kademeye göre tek sefer alınır.
-- Var olan kampanyaların davranışı değişmez: yeni sütunların varsayılanları eski davranıştır ('all', 'each', kapsam yok).
-- Tablo verisi değiştirilmez; fonksiyonlar aynı imzayla yenilenir, campaigns_list_v2 yeni eklenir.

alter table public.campaigns
  add column if not exists symbols text[],
  add column if not exists meme_chain text,
  add column if not exists scope_label text,
  add column if not exists rank_scope text not null default 'all',
  add column if not exists payout text not null default 'each';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'campaigns_rank_scope_check') then
    alter table public.campaigns add constraint campaigns_rank_scope_check check (rank_scope in ('all', 'community'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'campaigns_payout_check') then
    alter table public.campaigns add constraint campaigns_payout_check check (payout in ('each', 'highest_at_end'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'campaigns_scope_label_check') then
    alter table public.campaigns add constraint campaigns_scope_label_check check (scope_label is null or char_length(scope_label) <= 60);
  end if;
end $$;

-- Katılımcı sayımı için küçük kısmi indeks (swap ve vadeli açılış satırları az; alım/satım için mevcut indeksler var).
create index if not exists transactions_vol_misc on public.transactions (created_at desc) where kind in ('swap', 'perp_open');

-- Kampanyada sayılan coinler; null = bütün coinler.
create or replace function public._campaign_syms(p_campaign uuid)
returns text[] language sql stable security definer set search_path = public as $$
  select case when c.symbol is null and c.symbols is null and c.meme_chain is null then null::text[]
              else array(select distinct x.s from (
                       select c.symbol as s
                       union all select unnest(c.symbols)
                       union all select p.symbol from public.prices p where p.category = 'meme' and p.dex_chain = c.meme_chain
                     ) x where x.s is not null order by 1)
         end
    from public.campaigns c where c.id = p_campaign;
$$;

-- Bir kullanıcının kampanya hacmi (spot alım/satım + swap + vadeli açılış büyüklüğü), kapsamdaki coinlerde.
create or replace function public._campaign_volume(p_campaign uuid, p_user uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare c public.campaigns; syms text[]; v numeric;
begin
  select * into c from public.campaigns where id = p_campaign;
  if c.id is null or p_user is null then return 0; end if;
  syms := public._campaign_syms(p_campaign);
  select coalesce(sum(case when t.kind = 'perp_open' then t.qty * t.price else t.amount_usd end), 0) into v
    from public.transactions t
   where t.user_id = p_user and t.kind in ('buy', 'sell', 'swap', 'perp_open')
     and t.created_at >= c.starts_at and t.created_at < c.ends_at
     and (syms is null or t.symbol = any(syms));
  return v;
end $$;

-- Kampanyada işlem yapan kişi sayısı (herkes).
create or replace function public._campaign_participants(p_campaign uuid)
returns bigint language plpgsql stable security definer set search_path = public as $$
declare c public.campaigns; syms text[]; n bigint;
begin
  select * into c from public.campaigns where id = p_campaign;
  if c.id is null then return 0; end if;
  syms := public._campaign_syms(p_campaign);
  if syms is null then
    select count(distinct x.u) into n from (
      select t.user_id as u from public.transactions t
       where t.kind in ('buy', 'sell') and t.created_at >= c.starts_at and t.created_at < c.ends_at
      union all
      select t.user_id from public.transactions t
       where t.kind in ('swap', 'perp_open') and t.created_at >= c.starts_at and t.created_at < c.ends_at) x;
  else
    select count(distinct x.u) into n from (
      select t.user_id as u from public.transactions t
       where t.kind in ('buy', 'sell') and t.symbol = any(syms) and t.created_at >= c.starts_at and t.created_at < c.ends_at
      union all
      select t.user_id from public.transactions t
       where t.kind in ('swap', 'perp_open') and t.created_at >= c.starts_at and t.created_at < c.ends_at and t.symbol = any(syms)) x;
  end if;
  return n;
end $$;

-- Kullanıcının sıralamada göreceği kişiler: üyesi ya da sahibi olduğu (haber kanalı olmayan) toplulukların üyeleri + kendisi.
create or replace function public._campaign_peers(p_user uuid)
returns uuid[] language sql stable security definer set search_path = public as $$
  select array(
    select m.user_id from public.community_members m join public.communities co on co.id = m.community_id
     where co.kind <> 'news'
       and (co.owner = p_user or exists (select 1 from public.community_members me where me.community_id = co.id and me.user_id = p_user))
    union
    select p_user where p_user is not null);
$$;

revoke all on function public._campaign_syms(uuid) from public, anon, authenticated;
revoke all on function public._campaign_volume(uuid, uuid) from public, anon, authenticated;
revoke all on function public._campaign_participants(uuid) from public, anon, authenticated;
revoke all on function public._campaign_peers(uuid) from public, anon, authenticated;
grant execute on function public._campaign_syms(uuid) to service_role;
grant execute on function public._campaign_volume(uuid, uuid) to service_role;
grant execute on function public._campaign_participants(uuid) to service_role;
grant execute on function public._campaign_peers(uuid) to service_role;

-- Sıralama: rank_scope = 'community' ise yalnızca çağıranın topluluğundaki kişiler; değilse herkes (eski davranış).
create or replace function public.campaign_leaderboard(p_campaign uuid, p_limit integer default 20)
returns table(user_id uuid, username text, full_name text, avatar_url text, volume numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare c public.campaigns; syms text[]; peers uuid[]; lim int := least(greatest(coalesce(p_limit, 20), 1), 100);
begin
  select * into c from public.campaigns where id = p_campaign;
  if c.id is null then return; end if;
  syms := public._campaign_syms(p_campaign);
  if c.rank_scope = 'community' then
    peers := public._campaign_peers(auth.uid());
    return query
      select p.id, p.username, p.full_name, p.avatar_url, v.vol
        from (select t.user_id as uid, sum(case when t.kind = 'perp_open' then t.qty * t.price else t.amount_usd end) as vol
                from public.transactions t
               where t.user_id = any(peers) and t.kind in ('buy', 'sell', 'swap', 'perp_open')
                 and t.created_at >= c.starts_at and t.created_at < c.ends_at
                 and (syms is null or t.symbol = any(syms))
               group by t.user_id) v
        join public.profiles p on p.id = v.uid
       where v.vol > 0
       order by v.vol desc
       limit lim;
  else
    return query
      select p.id, p.username, p.full_name, p.avatar_url, v.vol
        from (select t.user_id as uid, sum(case when t.kind = 'perp_open' then t.qty * t.price else t.amount_usd end) as vol
                from public.transactions t
               where t.kind in ('buy', 'sell', 'swap', 'perp_open')
                 and t.created_at >= c.starts_at and t.created_at < c.ends_at
                 and (syms is null or t.symbol = any(syms))
               group by t.user_id) v
        join public.profiles p on p.id = v.uid
       order by v.vol desc
       limit lim;
  end if;
end $$;

-- Eski liste (aynı imza; eski uygulama sürümleri için) artık kapsamı ve katılımcı sayısını doğru hesaplar.
create or replace function public.campaigns_list()
returns table(id uuid, title text, description text, symbol text, starts_at timestamptz, ends_at timestamptz, tiers jsonb,
              my_volume numeric, claimed integer[], participants bigint)
language sql stable security definer set search_path = public as $$
  select c.id, c.title, c.description, c.symbol, c.starts_at, c.ends_at, c.tiers,
         public._campaign_volume(c.id, auth.uid()),
         coalesce((select array_agg(cc.tier order by cc.tier) from public.campaign_claims cc
                    where cc.campaign_id = c.id and cc.user_id = auth.uid()), '{}'::int[]),
         public._campaign_participants(c.id)
    from public.campaigns c
   where c.ends_at > now() - interval '7 days' and c.starts_at <= now() + interval '30 days'
   order by (c.ends_at < now()), c.ends_at;
$$;

-- Yeni liste: kapsam adı, sayılan coinler, sıralama ve ödül şekli, kullanıcının toplulukları.
create or replace function public.campaigns_list_v2()
returns table(id uuid, title text, description text, symbol text, starts_at timestamptz, ends_at timestamptz, tiers jsonb,
              my_volume numeric, claimed integer[], participants bigint,
              scope_label text, coins text[], rank_scope text, payout text, my_communities text[])
language sql stable security definer set search_path = public as $$
  select c.id, c.title, c.description, c.symbol, c.starts_at, c.ends_at, c.tiers,
         public._campaign_volume(c.id, auth.uid()),
         coalesce((select array_agg(cc.tier order by cc.tier) from public.campaign_claims cc
                    where cc.campaign_id = c.id and cc.user_id = auth.uid()), '{}'::int[]),
         public._campaign_participants(c.id),
         c.scope_label,
         case when c.symbols is not null or c.meme_chain is not null then public._campaign_syms(c.id) end,
         c.rank_scope, c.payout,
         case when c.rank_scope = 'community' then
           coalesce((select array_agg(co.name order by co.name) from public.communities co
                      where co.kind <> 'news'
                        and (co.owner = auth.uid() or exists (select 1 from public.community_members m
                                                               where m.community_id = co.id and m.user_id = auth.uid()))), '{}'::text[])
         end
    from public.campaigns c
   where c.ends_at > now() - interval '7 days' and c.starts_at <= now() + interval '30 days'
   order by (c.ends_at < now()), c.ends_at;
$$;
revoke all on function public.campaigns_list_v2() from public, anon;
grant execute on function public.campaigns_list_v2() to authenticated, service_role;

-- Ödül alma. payout = 'highest_at_end': yalnızca kampanya bittikten sonra (7 gün içinde), yalnızca ulaşılan en yüksek
-- kademe, kampanya başına tek ödül. Diğer kampanyalar eskisi gibi: ulaşılan her kademe ayrı alınır.
create or replace function public.claim_campaign(p_campaign uuid, p_tier integer)
returns numeric language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); c public.campaigns; t jsonb; amt numeric; vol numeric; best int := -1; i int;
begin
  if uid is null then raise exception 'Oturum açmalısın'; end if;
  select * into c from public.campaigns where id = p_campaign;
  if c.id is null then raise exception 'Kampanya bulunamadı'; end if;
  if now() < c.starts_at then raise exception 'Kampanya henüz başlamadı'; end if;
  if now() > c.ends_at + interval '7 days' then raise exception 'Bu kampanyanın ödül alma süresi doldu'; end if;
  t := c.tiers -> p_tier;
  if t is null then raise exception 'Geçersiz kademe'; end if;
  vol := public._campaign_volume(c.id, uid);
  if c.payout = 'highest_at_end' then
    if now() < c.ends_at then raise exception 'Bu kampanyanın ödülü kampanya bitince, ulaştığın hacme göre verilir'; end if;
    for i in 0 .. jsonb_array_length(c.tiers) - 1 loop
      if vol >= ((c.tiers -> i) ->> 'volume')::numeric then best := i; end if;
    end loop;
    if best < 0 then raise exception 'Bu kampanyada ödül kademesine ulaşamadın'; end if;
    if exists (select 1 from public.campaign_claims cc where cc.campaign_id = c.id and cc.user_id = uid) then
      raise exception 'Bu kampanyanın ödülünü zaten aldın';
    end if;
    if p_tier <> best then raise exception 'Yalnızca ulaştığın en yüksek kademenin ödülünü alabilirsin'; end if;
  elsif vol < (t ->> 'volume')::numeric then
    raise exception 'Bu kademe için hacmin henüz yeterli değil';
  end if;
  amt := (t ->> 'reward')::numeric;
  insert into public.campaign_claims (campaign_id, user_id, tier, amount) values (c.id, uid, p_tier, amt)
    on conflict do nothing;
  if not found then raise exception 'Bu ödülü zaten aldın'; end if;
  execute 'upd' || 'ate public.accounts set usdt = usdt + $1 where user_id = $2' using amt, uid;
  insert into public.transactions (user_id, kind, amount_usd, note) values (uid, 'reward', amt, 'Kampanya: ' || c.title);
  return amt;
end $$;
