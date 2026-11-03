-- coinforce_94_w3_wallets
-- Web3 saklamasız (non-custodial) cüzdan: kullanıcının kendi cihazında oluşturduğu ya da içe aktardığı cüzdanın
-- yalnızca HERKESE AÇIK adresleri. Kurtarma ifadesi, özel anahtar ya da cüzdan şifresi burada (ve sunucunun hiçbir
-- yerinde) saklanmaz; bunlar yalnızca kullanıcının cihazında, şifreli durur.
-- Amaç: kullanıcı başka bir cihazda giriş yaptığında "hesabına kayıtlı bir cüzdan var, kurtarma ifadenle içe aktar"
-- uyarısını gösterebilmek. Yalnızca kullanıcının kendisi okuyup yazabilir (fonksiyonlar auth.uid() ile sınırlı;
-- tabloya doğrudan erişim yok). Yalnızca ekleme: yeni tablo ve fonksiyonlar; mevcut veriye dokunulmaz.

create table if not exists public.w3_wallets (
  user_id uuid not null references auth.users (id) on delete cascade,
  chain text not null check (chain in ('sol', 'evm')),
  address text not null check (
    (chain = 'sol' and address ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$') or
    (chain = 'evm' and address ~ '^0x[0-9a-fA-F]{40}$')),
  updated_at timestamptz not null default now(),
  primary key (user_id, chain)
);
alter table public.w3_wallets enable row level security;
revoke all on public.w3_wallets from anon, authenticated;

create or replace function public.my_w3_wallets()
returns json language plpgsql stable security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  return coalesce((select json_object_agg(w.chain, w.address) from public.w3_wallets w where w.user_id = u), '{}'::json);
end $$;

create or replace function public.save_w3_wallet(p_sol text, p_evm text)
returns json language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'Giriş gerekli'; end if;
  if p_sol is null or p_sol !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$' then raise exception 'Geçersiz Solana adresi'; end if;
  if p_evm is null or p_evm !~ '^0x[0-9a-fA-F]{40}$' then raise exception 'Geçersiz EVM adresi'; end if;
  insert into public.w3_wallets (user_id, chain, address) values (u, 'sol', p_sol), (u, 'evm', p_evm)
  on conflict (user_id, chain) do update set address = excluded.address, updated_at = now();
  return json_build_object('ok', true);
end $$;

revoke all on function public.my_w3_wallets(), public.save_w3_wallet(text, text) from public, anon;
grant execute on function public.my_w3_wallets(), public.save_w3_wallet(text, text) to authenticated;
