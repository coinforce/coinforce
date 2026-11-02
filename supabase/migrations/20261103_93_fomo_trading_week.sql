-- coinforce_93_fomo_trading_week
-- "FOMO Trading Week" hacim kampanyası, 7 gün. Yalnızca ekleme: kampanya satırı + herkese bildirim.
-- Sayılan hacim: SOL ve Solana memecoinleri (CoinGecko'dan Solana memecoinleri, FOREVER ve Solana zincirindeki bütün
-- DEX memecoinleri; kampanya sürerken listelenen Solana memecoinleri de sayılır).
-- Ödül: kampanya bitince, ulaşılan en yüksek kademe tek sefer: 100.000 $ → 500 $, 500.000 $ → 5.000 $, 1.000.000 $ → 10.000 $.
-- Herkes katılabilir; sıralamada herkes yalnızca kendi topluluğundaki kişileri görür.
-- Tekrar çalıştırılırsa ikinci bir kampanya açmaz.
with ins as (
  insert into public.campaigns (title, description, symbol, starts_at, ends_at, tiers, created_by,
                                symbols, meme_chain, scope_label, rank_scope, payout)
  select 'FOMO Trading Week',
         '7 gün boyunca SOL ve Solana memecoinlerinde işlem yap, hacmini büyüt. Sıralamada kendi topluluğundaki kişilerle yarışırsın.',
         null, now(), now() + interval '7 days',
         '[{"volume": 100000, "reward": 500}, {"volume": 500000, "reward": 5000}, {"volume": 1000000, "reward": 10000}]'::jsonb,
         (select p.id from public.profiles p where p.username = 'goldenbob'),
         array['SOL', 'TRUMP', 'PENGU', 'BONK', 'WIF', 'FARTCOIN', 'BOME', 'POPCAT', 'MEW', 'FOREVER'],
         'solana', 'SOL ve Solana memecoin', 'community', 'highest_at_end'
   where not exists (select 1 from public.campaigns c where c.title = 'FOMO Trading Week' and c.ends_at > now())
  returning id)
insert into public.notifications (user_id, body)
select p.id, 'Yeni hacim kampanyası: FOMO Trading Week' from public.profiles p where exists (select 1 from ins);
