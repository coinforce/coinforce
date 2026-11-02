"""Yerel staging uçtan uca testi: gerçek PostgreSQL + PostgREST + Deno bot + sahte Telegram API.

Telegram'ın göndereceği güncellemeleri webhook'a yollar, botun cevaplarını sahte API kaydından,
veritabanı etkisini psql ile kontrol eder. Canlı borsa/para yoktur; yalnızca yerel kopya kullanılır.
Kullanım: python3 e2e_local.py
"""
import concurrent.futures as cf
import hashlib
import json
import os
import subprocess
import time
import urllib.request

GW = os.environ.get("GW", "http://127.0.0.1:54321")
TOKEN = os.environ.get("TG_TOKEN", "123:TEST")
DB = ["psql", "-h", "127.0.0.1", "-p", "54322", "-U", "postgres", "-d", "staging", "-At", "-v", "ON_ERROR_STOP=1", "-c"]
JWT_PY = os.environ.get("JWT_PY", "/home/claude/staging/env/jwt.py")
SECRET = hashlib.sha256(("cf-notify:" + TOKEN).encode()).hexdigest()[:48]
ALICE, BOB = "b63eee78-673e-4183-89c9-20738ceabc5a", "482227f8-acf7-40bc-bfb6-8a1025c62314"
T_ALICE, T_BOB, T_X = 700000001, 700000002, 700000099
results = []
_uid = [int(time.time()) * 1000]
_mid = [5000]


def db(sql):
    return subprocess.run(DB + [sql], capture_output=True, text=True, check=True).stdout.strip()


def user_rpc(uid, fn, args=None):
    """Uygulamanın yaptığı gibi: kullanıcının JWT'siyle PostgREST RPC çağrısı."""
    tok = subprocess.run(["python3", "-I", JWT_PY, "authenticated", uid], capture_output=True, text=True, check=True).stdout.strip()
    s, body = http(f"/rest/v1/rpc/{fn}", args or {}, {"authorization": f"Bearer {tok}", "apikey": tok})
    return s, (json.loads(body) if body else None)


def http(path, body=None, headers=None, method="POST"):
    req = urllib.request.Request(GW + path, data=json.dumps(body).encode() if body is not None else None, method=method,
                                 headers={"content-type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def mock_reset():
    http("/tgmock/_reset", {})


def mock_log():
    return json.loads(http("/tgmock/_log", method="GET")[1])


def next_uid():
    _uid[0] += 1
    return _uid[0]


def msg(tg_user, text, chat=None, chat_type="private", date=None, update_id=None, mid=None):
    _mid[0] += 1
    return {"update_id": update_id or next_uid(), "message": {
        "message_id": mid or _mid[0], "date": int(date or time.time()), "text": text,
        "from": {"id": tg_user, "is_bot": False, "first_name": "T", "username": f"user{tg_user}"},
        "chat": {"id": chat or tg_user, "type": chat_type}}}


def cb(tg_user, data, msg_id=777, update_id=None):
    return {"update_id": update_id or next_uid(), "callback_query": {
        "id": f"cq{next_uid()}", "data": data, "from": {"id": tg_user, "is_bot": False, "first_name": "T", "username": f"user{tg_user}"},
        "message": {"message_id": msg_id, "date": int(time.time()), "chat": {"id": tg_user, "type": "private"}, "text": "menu"}}}


def send(update, secret=SECRET):
    return http("/functions/v1/telegram-notify", update, {"x-telegram-bot-api-secret-token": secret})


def ver(uid):
    """Bağlantının güncel oturum sürümü (bot işlem butonlarını bununla damgalar)."""
    return db(f"select session_version from public.tg_notify where user_id = '{uid}'")


def last_alert():
    for c in reversed(mock_log()):
        if c["method"] == "answerCallbackQuery":
            return c["body"].get("text", "")
    return ""


def last_text():
    for c in reversed(mock_log()):
        if c["method"] in ("sendMessage", "editMessageText"):
            return c["body"].get("text", "")
    return ""


def check(n, name, ok, detail=""):
    results.append((n, name, "GEÇTİ" if ok else "KALDI", detail[:160].replace("\n", " ⏎ ")))


def orders_for(uid, where="true"):
    return int(db(f"select count(*) from public.telegram_order_logs where user_id = '{uid}' and {where}"))


def main():
    db("update public.prices set updated_at = now() where listed")
    db(f"update public.accounts set usdt = 10000 where user_id in ('{ALICE}','{BOB}')")
    db("delete from public.telegram_order_logs; delete from public.telegram_updates; delete from public.telegram_audit_logs;")
    db(f"update public.tg_notify set chat_id = null, tg_user_id = null, trading_enabled = false, link_code = null where user_id in ('{ALICE}','{BOB}')")
    db(f"delete from public.holdings where user_id in ('{ALICE}','{BOB}'); delete from public.orders where user_id in ('{ALICE}','{BOB}'); delete from public.positions where user_id in ('{ALICE}','{BOB}')")

    # 1) Webhook gizli başlığı
    s, _ = send(msg(T_ALICE, "/menu"), secret="wrong")
    check(1, "Yanlış webhook gizli başlığı reddedilir", s == 401, f"HTTP {s}")

    # 2) Bağlı olmayan Telegram kullanıcısı işlem yapamaz
    mock_reset(); send(msg(T_X, "/buy BTC 100"))
    check(2, "Bağlı olmayan kullanıcı: emir yok", "bağlı değil" in last_text() and orders_for(ALICE) == 0, last_text())

    # 3) Bağlama: 5 dakikalık tek kullanımlık kod
    code = user_rpc(ALICE, "tg_notify_code")[1]["code"]
    ttl = db(f"select round(extract(epoch from code_exp - now())) from public.tg_notify where user_id = '{ALICE}'")
    mock_reset(); send(msg(T_ALICE, f"/start {code}"))
    linked = db(f"select tg_user_id || ':' || trading_enabled from public.tg_notify where user_id = '{ALICE}'")
    check(3, "Kodla bağlama (kod ~300 sn geçerli)", linked == f"{T_ALICE}:false" and 280 <= float(ttl) <= 300, f"ttl={ttl} link={linked} | {last_text()}")
    mock_reset(); send(msg(T_BOB, f"/start {code}"))
    check(4, "Aynı kod ikinci kez kullanılamaz", "geçersiz" in last_text().lower(), last_text())

    # 5) Grup sohbeti
    mock_reset(); send(msg(T_ALICE, "/buy BTC 100", chat=-1001234, chat_type="supergroup"))
    check(5, "Grup sohbetinden emir verilemez", "özel sohbette" in last_text() and orders_for(ALICE) == 0, last_text())

    # 6) İşlem izni varsayılan kapalı
    mock_reset(); send(msg(T_ALICE, "/buy BTC 100"))
    check(6, "İşlem izni kapalıyken emir reddedilir", "izni kapalı" in last_text() and orders_for(ALICE, "status <> 'rejected'") == 0, last_text())

    user_rpc(ALICE, "tg_trading_set", {"p_on": True})

    # 7) Spot piyasa alımı (anında)
    usdt0 = float(db(f"select usdt from public.accounts where user_id = '{ALICE}'"))
    mock_reset(); t0 = time.time(); u = msg(T_ALICE, "/buy BTC 100"); s, _ = send(u); ms = (time.time() - t0) * 1000
    usdt1 = float(db(f"select usdt from public.accounts where user_id = '{ALICE}'"))
    btc = db(f"select coalesce(sum(qty),0) from public.holdings where user_id = '{ALICE}' and symbol = 'BTC'")
    check(7, "/buy BTC 100 anında gerçekleşir", "Alındı" in last_text() and abs((usdt0 - usdt1) - 100) < 0.01 and float(btc) > 0, f"{ms:.0f} ms, USDT {usdt0}->{usdt1}, BTC {btc}")

    # 8) Aynı update tekrar → ikinci emir yok
    n0 = orders_for(ALICE); send(u); send(u)
    check(8, "Aynı update_id tekrar gönderilince ikinci emir yok", orders_for(ALICE) == n0, f"emir sayısı {n0} -> {orders_for(ALICE)}")

    # 9) Satış yüzdesi
    mock_reset(); send(msg(T_ALICE, "/sell BTC %50"))
    check(9, "/sell BTC %50", "Satıldı" in last_text(), last_text())

    # 10) Limit alış, iptal
    px = float(db("select price from public.prices where symbol = 'ETH'"))
    mock_reset(); send(msg(T_ALICE, f"/buy ETH 50 limit {px * 0.9:.2f}".replace(".", ",")))
    oid = db(f"select id from public.orders where user_id = '{ALICE}' and status = 'open' order by created_at desc limit 1")
    check(10, "Limit alış emri açılır", "emri açıldı" in last_text() and bool(oid), last_text())
    mock_reset(); send(cb(T_ALICE, f"x:oc:{oid}:v{ver(ALICE)}", msg_id=900))
    st = db(f"select status from public.orders where id = '{oid}'")
    check(11, "Butonla emir iptali", st == "cancelled" and "iptal edildi" in last_text(), f"durum={st}")

    # 12) Stop satış
    mock_reset(); send(msg(T_ALICE, "/buy SOL 30"))
    spx = float(db("select price from public.prices where symbol = 'SOL'"))
    mock_reset(); send(msg(T_ALICE, f"/sell SOL hepsi stop {spx * 0.95:.4f}"))
    check(12, "Stop satış emri açılır", "Stop satış emri açıldı" in last_text(), last_text())

    # 13) Vadeli long + kapama
    mock_reset(); send(msg(T_ALICE, "/long ETH 25 10x"))
    pos = db(f"select id || '|' || leverage || '|' || margin::int from public.positions where user_id = '{ALICE}' and status = 'open' and symbol = 'ETH'")
    check(13, "/long ETH 25 10x açılır", "Long açıldı" in last_text() and pos.endswith("|10|25"), pos)
    mock_reset(); send(msg(T_ALICE, "/close ETH %50"))
    st = db(f"select status from public.positions where id = '{pos.split('|')[0]}'")
    check(29, "Kısmi kapama istenirse pozisyon kapanmaz, desteklenmiyor denir", st == "open" and "Kısmi kapama desteklenmiyor" in last_text(), f"durum={st}")
    n0 = orders_for(ALICE)
    mock_reset(); send(msg(T_ALICE, "/long BTC 10 5x limit 60000"))
    check(30, "Vadeli limit emir istenirse reddedilir, piyasa emri açılmaz", orders_for(ALICE) == n0 and "desteklenmiyor" in last_text(), last_text())
    mock_reset(); send(msg(T_ALICE, "/close ETH"))
    st = db(f"select status from public.positions where id = '{pos.split('|')[0]}'")
    check(14, "/close ETH pozisyonu tamamen kapatır", st == "closed" and "kapatıldı" in last_text(), f"durum={st}")
    mock_reset(); send(msg(T_ALICE, "/short BTC 20 100x"))
    check(15, "Kaldıraç sınırı aşılırsa reddedilir", "kaldıraç" in last_text().lower(), last_text())

    # 16) Başkasının pozisyonu/emri
    user_rpc(BOB, "open_position", {"p_symbol": "BTC", "p_side": 1, "p_leverage": 5, "p_margin": 20})
    bpos = db(f"select id from public.positions where user_id = '{BOB}' and status = 'open' limit 1")
    mock_reset(); send(cb(T_ALICE, f"x:fc:{bpos}:v{ver(ALICE)}", msg_id=901))
    st = db(f"select status from public.positions where id = '{bpos}'")
    check(16, "Callback manipülasyonu: başkasının pozisyonu kapanmaz", st == "open" and "bulunamadı" in last_text(), f"bob pozisyon={st}")

    # 17) Buton akışı + aynı butona ikinci basış
    mock_reset(); send(cb(T_ALICE, "s:BTC", msg_id=950)); card = last_text()
    send(cb(T_ALICE, "sb:BTC", msg_id=950))
    btn = next((b["callback_data"] for c in reversed(mock_log()) if c["method"] == "editMessageText"
                for row in c["body"].get("reply_markup", {}).get("inline_keyboard", []) for b in row
                if b.get("callback_data", "").startswith("x:mb:BTC:10:")), "")
    n0 = orders_for(ALICE, "status = 'filled'")
    send(cb(T_ALICE, btn, msg_id=950)); first = last_text()
    send(cb(T_ALICE, btn, msg_id=950))
    check(17, "Butonla alım; aynı butona ikinci basış emir oluşturmaz", btn == f"x:mb:BTC:10:v{ver(ALICE)}" and "BTC/USDT" in card and "Alındı" in first and orders_for(ALICE, "status = 'filled'") == n0 + 1, f"filled {n0}->{orders_for(ALICE, 'status = ' + chr(39) + 'filled' + chr(39))}")

    # 18) Özel tutar (sohbet içi girdi)
    mock_reset(); send(cb(T_ALICE, "ci:mb:ETH", msg_id=960)); ask = last_text()
    send(msg(T_ALICE, "15,5")); done = last_text()
    check(18, "Özel tutar girişi (15,5 USDT)", "Kaç USDT" in ask and "Alındı" in done, done)

    # 19) Belirsiz sayı
    mock_reset(); send(msg(T_ALICE, "/buy BTC 2.500"))
    check(19, "Belirsiz tutar (2.500) reddedilir, emir yok", "belirsiz" in last_text(), last_text())

    # 20) Yetersiz bakiye, en düşük tutar, bilinmeyen çift
    mock_reset(); send(msg(T_ALICE, "/buy BTC 999999")); a = last_text()
    send(msg(T_ALICE, "/buy BTC 0,5")); b = last_text()
    send(msg(T_ALICE, "/buy NOPE 10")); c = last_text()
    check(20, "Yetersiz bakiye / 1 USDT altı / bilinmeyen çift", "yetersiz" in a and "1 USDT" in b and "bulunamadı" in c, f"{a[:40]} | {b[:40]} | {c[:40]}")

    # 21) Eski fiyat
    db("update public.prices set updated_at = now() - interval '150 seconds' where symbol = 'XRP'")
    mock_reset(); send(msg(T_ALICE, "/buy XRP 10"))
    check(21, "Fiyat 120 sn'den eskiyse reddedilir", "güncel değil" in last_text(), last_text())
    db("update public.prices set updated_at = now() where symbol = 'XRP'")

    # 22) Gecikmeli komut
    mock_reset(); send(msg(T_ALICE, "/buy BTC 10", date=time.time() - 300))
    check(22, "300 sn gecikmeli emir komutu işlenmez", "gecikmeyle" in last_text(), last_text())

    # 23) Eşzamanlı 21 emir → 20 kabul, 1 red
    db("delete from public.telegram_order_logs where counted")  # sayaç temiz başlasın (yerel test)
    ups = [msg(T_ALICE, "/buy DOGE 1") for _ in range(21)]
    with cf.ThreadPoolExecutor(max_workers=21) as ex:
        list(ex.map(send, ups))
    ok = orders_for(ALICE, "counted and created_at > now() - interval '60 seconds'")
    rl = orders_for(ALICE, "result->>'code' = 'RATE_LIMIT'")
    check(23, "Eşzamanlı 21 emir: 20 kabul, 1 dakikalık sınır reddi", ok == 20 and rl == 1, f"kabul={ok} red={rl}")

    # 27-28) Eski mesajdaki işlem butonu: izin kapatılıp açıldıktan sonra emir oluşturmaz; damgasız buton da
    v_old = ver(ALICE)
    user_rpc(ALICE, "tg_trading_set", {"p_on": False}); user_rpc(ALICE, "tg_trading_set", {"p_on": True})
    n0 = orders_for(ALICE)
    mock_reset(); send(cb(T_ALICE, f"x:mb:BTC:10:v{v_old}", msg_id=980))
    a1 = last_alert()
    send(cb(T_ALICE, "x:mb:BTC:10", msg_id=981)); a2 = last_alert()
    check(27, "İzin kapatılıp açılınca eski işlem butonu emir oluşturmaz", orders_for(ALICE) == n0 and "geçerli değil" in a1, f"sürüm {v_old}->{ver(ALICE)} | {a1}")
    check(28, "Sürüm damgası olmayan işlem butonu reddedilir", orders_for(ALICE) == n0 and "geçerli değil" in a2, a2)

    # 24) İzin kapatılınca bekleyen girdi geçersiz, emir reddedilir
    send(cb(T_ALICE, "ci:mb:BTC", msg_id=970))
    user_rpc(ALICE, "tg_trading_set", {"p_on": False})
    mock_reset(); send(msg(T_ALICE, "12"))
    t = last_text()
    check(24, "İzin kapatılınca bekleyen işlem geçersiz", "Alındı" not in t, t)

    # 25) Bakım uçları
    s1, _ = http("/functions/v1/telegram-notify?run=1", {})
    s2, _ = http("/functions/v1/telegram-notify?setup=1", {})
    check(25, "?run ve ?setup iç anahtar olmadan 401", s1 == 401 and s2 == 401, f"{s1} {s2}")

    # 26) Audit log
    n = db(f"select count(*) from public.telegram_audit_logs where user_id = '{ALICE}'")
    check(26, "Audit log yazıldı", int(n) > 10, f"{n} kayıt")

    w = max(len(r[1]) for r in results)
    for r in results:
        print(f"{r[0]:>2}. {r[1]:<{w}}  {r[2]}  {r[3]}")
    print(f"\n{sum(r[2] == 'GEÇTİ' for r in results)}/{len(results)} geçti")


if __name__ == "__main__":
    main()
