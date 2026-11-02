-- coinforce_78_telegram_accounts
-- Botun /accounts (/hesaplar) komutu: emirlerin gerçekleşeceği hesaplar. Kendi hesabın + toplu işlemde aktif
-- hesaplar (kullanılabilir USDT ile) ve anahtarı yenilendiği için pasif kalanlar. Yalnızca okuma; yalnızca
-- service role (telegram-notify) çağırabilir. Yalnızca ekleme: yeni fonksiyon.

create or replace function public.tgx_accounts(p_tg_user bigint)
returns json language plpgsql stable security definer set search_path = '' as $$
declare n public.tg_notify;
begin
  select * into n from public.tg_notify where tg_user_id = p_tg_user and chat_id is not null;
  if n.user_id is null then return json_build_object('linked', false); end if;
  return json_build_object(
    'linked', true,
    'trading', coalesce(n.trading_enabled, false),
    'group', coalesce(n.group_trading, false),
    'me', (select json_build_object('username', p.username, 'usdt', a.usdt)
             from public.profiles p left join public.accounts a on a.user_id = p.id where p.id = n.user_id),
    'active', coalesce((select json_agg(json_build_object('username', m.username, 'usdt', a.usdt) order by m.username)
                          from cf_private.group_members(n.user_id) m left join public.accounts a on a.user_id = m.member_id), '[]'::json),
    'inactive', coalesce((select json_agg(coalesce(p.username, '?') order by p.username)
                            from public.tg_group_links l left join public.profiles p on p.id = l.member_id
                           where l.owner_id = n.user_id and l.revoked_at is null
                             and not exists (select 1 from cf_private.group_members(n.user_id) m where m.member_id = l.member_id)), '[]'::json));
end $$;

revoke all on function public.tgx_accounts(bigint) from public, anon, authenticated;
grant execute on function public.tgx_accounts(bigint) to service_role;
