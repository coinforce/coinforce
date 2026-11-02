-- coinforce_81_chart_drawings
-- View grafiğindeki çizimler (çizgi, kutu, kalem, fosforlu kalem, metin, emoji) kullanıcı silene kadar kalıcıdır ve
-- her cihazda aynı görünür. Kullanıcı ve coin başına tek satır; veri fiyat/zaman koordinatlarında bir JSON listesi.
-- Yalnızca kullanıcının kendisi okuyup yazabilir (fonksiyonlar auth.uid() ile sınırlı; tabloya doğrudan erişim yok).
-- Yalnızca ekleme: yeni tablo ve fonksiyonlar.

create table if not exists public.chart_drawings (
  user_id uuid not null references auth.users (id) on delete cascade,
  symbol text not null check (symbol ~ '^[A-Za-z0-9_.-]{1,30}$'),
  data jsonb not null default '[]'::jsonb check (jsonb_typeof(data) = 'array'),
  updated_at timestamptz not null default now(),
  primary key (user_id, symbol)
);
alter table public.chart_drawings enable row level security;
revoke all on public.chart_drawings from anon, authenticated;

create or replace function public.my_chart_drawings()
returns json language plpgsql stable security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  return coalesce((select json_object_agg(d.symbol, d.data) from public.chart_drawings d where d.user_id = u), '{}'::json);
end $$;

create or replace function public.save_chart_drawings(p_symbol text, p_data jsonb)
returns json language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  if p_symbol is null or p_symbol !~ '^[A-Za-z0-9_.-]{1,30}$' then raise exception 'Geçersiz coin'; end if;
  if p_data is null or jsonb_typeof(p_data) <> 'array' then raise exception 'Geçersiz çizim verisi'; end if;
  if jsonb_array_length(p_data) = 0 then
    delete from public.chart_drawings where user_id = u and symbol = p_symbol;
    return json_build_object('ok', true, 'n', 0);
  end if;
  if jsonb_array_length(p_data) > 400 then raise exception 'Bir coinde en fazla 400 çizim saklanır'; end if;
  if octet_length(p_data::text) > 400000 then raise exception 'Çizimler çok büyük'; end if;
  if not exists (select 1 from public.chart_drawings where user_id = u and symbol = p_symbol)
     and (select count(*) from public.chart_drawings where user_id = u) >= 150 then
    raise exception 'En fazla 150 coinde çizim saklanır';
  end if;
  insert into public.chart_drawings (user_id, symbol, data) values (u, p_symbol, p_data)
  on conflict (user_id, symbol) do update set data = excluded.data, updated_at = now();
  return json_build_object('ok', true, 'n', jsonb_array_length(p_data));
end $$;

revoke all on function public.my_chart_drawings(), public.save_chart_drawings(text, jsonb) from public, anon;
grant execute on function public.my_chart_drawings(), public.save_chart_drawings(text, jsonb) to authenticated;
