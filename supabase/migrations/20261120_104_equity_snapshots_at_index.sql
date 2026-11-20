-- 104: Portföy anlık görüntülerinin süresi dolanları zamana göre indeksle silinsin
-- snapshot_equity() 10 dakikada bir "delete from equity_snapshots where at < now() - interval '35 days'" çalıştırıyor.
-- Tabloda yalnızca (user_id, at) birincil anahtarı vardı; bu silme her seferinde ≈1 milyon satırlık (423 MB)
-- tablonun tamamını tarıyordu. Küçük sunucuda bu tarama disk bütçesini tüketti ve 19-20 Kasım kesintisine katkı verdi.
-- Yalnızca ekleme: zamana göre bir indeks. Veri, fonksiyon ve izinler değişmez.
-- Geri almak için: drop index if exists public.equity_snapshots_at;
create index if not exists equity_snapshots_at on public.equity_snapshots (at);
