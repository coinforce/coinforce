-- 102: Profil açılışında "canceling statement due to statement timeout" hatası
-- trader_best_coin(p_user) kullanıcının tüm al/sat işlemlerini toplar; çok işlemli (bot) hesaplarda
-- (300 binden fazla satır) tablo taranıyor ve 8 sn'lik sınıra takılıyordu (ölçüm: 14,7 sn).
-- Yalnızca yeni indeks eklenir: toplama için "yalnızca indeks taraması", son 300 işlem için
-- (kullanıcı, sembol, zaman) sırası. Mevcut veri, fonksiyon ve izinler değişmez.
-- Canlıda tabloyu kilitlememek için CREATE INDEX CONCURRENTLY ile uygulanır.
-- Geri almak için: drop index if exists public.transactions_user_sym_cover;
create index if not exists transactions_user_sym_cover
  on public.transactions (user_id, symbol, created_at desc)
  include (kind, qty, amount_usd, price)
  where kind in ('buy', 'sell') and symbol is not null;
