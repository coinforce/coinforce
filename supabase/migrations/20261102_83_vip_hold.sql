-- coinforce_83_vip_hold
-- VIP kademesi için SOL tutma süresi: bir kademenin SOL miktarını o kademenin süresi boyunca kesintisiz tutan kullanıcı o kademeyi
-- kazanır; sonradan SOL'u satsa bile kademesi düşmez ("kazanılmış seviye"). Etkin seviye = max(şu anki SOL'a göre seviye, kazanılmış seviye).
-- Süreler (gün), VIP 1..12: 1, 2, 3, 5, 7, 10, 14, 18, 21, 25, 30, 45.
-- Yalnızca ekleme: yeni tablo + yardımcı fonksiyonlar + SOL satırlarına bağlı iki tetikleyici; _vip_level / vip_levels güncellenir.
-- Tetikleyici hata verirse işlemi bozmaz (hata yutulur), böylece alım-satım asla engellenmez.

create table if not exists public.vip_state (
  user_id uuid primary key references auth.users (id) on delete cascade,
  earned int not null default 0 check (earned between 0 and 12),
  since timestamptz[] not null default array_fill(null::timestamptz, array[12]),
  updated_at timestamptz not null default now()
);
alter table public.vip_state enable row level security;
revoke all on public.vip_state from anon, authenticated;

create or replace function public._vip_sync(p_uid uuid, p_qty numeric)
returns void language plpgsql security definer set search_path = '' as $$
declare
  thr constant numeric[] := array[1000,2500,5000,10000,20000,35000,50000,75000,100000,150000,250000,500000];
  dys constant int[] := array[1,2,3,5,7,10,14,18,21,25,30,45];
  s timestamptz[]; e int := 0; i int; r record;
begin
  select * into r from public.vip_state where user_id = p_uid;
  if found then s := r.since; e := r.earned; else s := array_fill(null::timestamptz, array[12]); end if;
  for i in 1 .. 12 loop
    if s[i] is not null and now() >= s[i] + make_interval(days => dys[i]) then e := greatest(e, i); end if;
    if p_qty >= thr[i] then
      if s[i] is null then s[i] := now(); end if;
    else
      s[i] := null;
    end if;
  end loop;
  insert into public.vip_state (user_id, earned, since) values (p_uid, e, s)
  on conflict (user_id) do update set earned = excluded.earned, since = excluded.since, updated_at = now();
end $$;
revoke all on function public._vip_sync(uuid, numeric) from public, anon, authenticated;

create or replace function public._vip_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    if tg_op = 'DELETE' then perform public._vip_sync(old.user_id, 0);
    else perform public._vip_sync(new.user_id, new.qty); end if;
  exception when others then null;
  end;
  return null;
end $$;
revoke all on function public._vip_trg() from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'vip_hold_upsert' and tgrelid = 'public.holdings'::regclass) then
    create trigger vip_hold_upsert after insert or update on public.holdings for each row when (new.symbol = 'SOL') execute function public._vip_trg();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'vip_hold_delete' and tgrelid = 'public.holdings'::regclass) then
    create trigger vip_hold_delete after delete on public.holdings for each row when (old.symbol = 'SOL') execute function public._vip_trg();
  end if;
end $$;

create or replace function public._vip_level(p_uid uuid)
returns int language sql stable security definer set search_path = '' as $$
  select greatest(
    coalesce((select count(*)::int from unnest(array[1000,2500,5000,10000,20000,35000,50000,75000,100000,150000,250000,500000]) t
              where t <= (select h.qty from public.holdings h where h.user_id = p_uid and h.symbol = 'SOL')), 0),
    coalesce((select s.earned from public.vip_state s where s.user_id = p_uid), 0));
$$;

create or replace function public.vip_levels()
returns table (user_id uuid, lvl int) language sql stable security definer set search_path = '' as $$
  select u.user_id, public._vip_level(u.user_id)
  from (select h.user_id from public.holdings h where h.symbol = 'SOL' and h.qty >= 1000
        union select s.user_id from public.vip_state s where s.earned > 0) u;
$$;
revoke all on function public.vip_levels() from public, anon;
grant execute on function public.vip_levels() to authenticated;

-- Kullanıcının kendi tutma ilerlemesi (kademe başına "şu tarihten beri tutuyor")
create or replace function public.my_vip()
returns json language plpgsql stable security definer set search_path = '' as $$
declare u uuid := auth.uid(); r record;
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  select * into r from public.vip_state where user_id = u;
  return json_build_object('earned', coalesce(r.earned, 0), 'since', to_json(coalesce(r.since, array_fill(null::timestamptz, array[12]))), 'now', now());
end $$;
revoke all on function public.my_vip() from public, anon;
grant execute on function public.my_vip() to authenticated;

-- Mevcut SOL sahipleri için tutma sayacı bugünden başlar
do $$
declare r record;
begin
  for r in select user_id, qty from public.holdings where symbol = 'SOL' and qty >= 1000 loop
    perform public._vip_sync(r.user_id, r.qty);
  end loop;
end $$;
