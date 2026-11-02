-- coinforce_80_verified_badge
-- Kimliği doğrulanmış (KYC onaylı) hesapların listesi: uygulama isimlerin ve VIP++/CEO/BOT etiketlerinin sağında
-- yeşil yuvarlak tik gösterir. vip_users/ceo_users/bot_users ile aynı biçim: yalnızca kullanıcı kimlikleri döner,
-- kimlik bilgisi (ad, numara, belge) dönmez. Yalnızca giriş yapmış kullanıcılar çağırabilir.
-- Yalnızca ekleme: yeni fonksiyon.

create or replace function public.verified_users()
returns setof uuid language sql stable security definer set search_path = '' as $$
  select k.user_id from public.kyc_requests k where k.status = 'approved';
$$;

revoke all on function public.verified_users() from public, anon;
grant execute on function public.verified_users() to authenticated;
