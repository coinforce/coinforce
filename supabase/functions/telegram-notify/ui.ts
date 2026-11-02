// Menüler, klavyeler ve sonuç mesajları (veriyi alır, metin + klavye döndürür; yan etkisi yoktur).
// deno-lint-ignore-file no-explicit-any
import { esc, pct, price, priceKey, qty, roundPrice, signedMoney, usdt } from "./fmt.ts";
import type { Button, Keyboard } from "./tg.ts";

export type Me = { linked: boolean; username?: string; trading?: boolean; session_version?: number; state?: any; alerts?: boolean; daily?: boolean; news?: boolean; linked_at?: string };
export type Screen = { text: string; kb?: Keyboard };

export const APP_URL = Deno.env.get("COINFORCE_APP_URL") ?? "https://coinforce.github.io/coinforce/";
const b = (text: string, data: string): Button => ({ text, callback_data: data });
const rows = (list: Button[], per: number) => { const out: Button[][] = []; for (let i = 0; i < list.length; i += per) out.push(list.slice(i, i + per)); return out; };
const kb = (...r: Button[][]): Keyboard => ({ inline_keyboard: r.filter((x) => x.length) });
const NAV = (back?: [string, string]) => [...(back ? [b(back[0], back[1])] : []), b("🏠 Menü", "m")];

const TRADING_OFF = "🔒 <b>Telegram'dan işlem izni kapalı.</b> Açmak için COINFORCE uygulamasında <b>Ayarlar › Telegram bildirimleri › Telegram ile işlem</b> seçeneğini kullan. Okuma (bakiye, emirler, pozisyonlar, fiyatlar) açık.";

export function notLinked(): Screen {
  return {
    text: [
      "🔗 <b>Bu Telegram hesabı bir COINFORCE hesabına bağlı değil.</b>",
      "",
      "Bağlamak için COINFORCE uygulamasında <b>Ayarlar › Telegram bildirimleri › Telegram'a bağla</b> butonuna dokun. Kod 5 dakika geçerlidir ve yalnızca bir kez kullanılır.",
      "",
      "Bağlamadan da fiyatlara bakabilirsin: /price BTC · /grafik",
    ].join("\n"),
    kb: kb([b("💲 Fiyatlar", "px"), b("❓ Yardım", "h")], [{ text: "📱 COINFORCE'u aç", url: APP_URL }]),
  };
}

export function mainMenu(me: Me, bal?: any): Screen {
  const lines = [`🏦 <b>COINFORCE Trading Terminal</b>`, `Hesap: <b>@${esc(me.username)}</b> · İşlem izni: ${me.trading ? "🔓 açık" : "🔒 kapalı"}`];
  if (bal?.linked) lines.push(`Nakit: <b>${usdt(bal.usdt)}</b> · Toplam varlık: ${usdt(bal.equity)}`);
  if (!me.trading) lines.push("", TRADING_OFF);
  lines.push("", "Bir bölüm seç ya da komut yaz: /buy BTC 100 · /sell BTC %50 · /long ETH 50 10x");
  return {
    text: lines.join("\n"),
    kb: kb(
      [b("📈 Spot", "s"), b("⚡ Vadeli", "f")],
      [b("💰 Bakiye", "b"), b("📋 Emirler", "o")],
      [b("📊 Pozisyonlar", "p"), b("💲 Fiyatlar", "px")],
      [b("⚙️ Ayarlar", "st"), b("❓ Yardım", "h")],
    ),
  };
}

export function help(): Screen {
  return {
    text: [
      "❓ <b>Komutlar</b> (Türkçe karşılıkları da çalışır)",
      "",
      "<b>Spot</b>",
      "/buy BTC 100 — 100 USDT'lik piyasa alımı (/al)",
      "/buy BTC %25 — USDT bakiyenin %25'iyle alım",
      "/buy BTC 100 limit 60000 — limit alış (@60000 de olur)",
      "/buy BTC 100 stop 70000 — stop alış",
      "/sell BTC 0,01 · /sell BTC %50 · /sell BTC hepsi — piyasa satış (/sat)",
      "/sell BTC %50 limit 72000 — limit satış",
      "",
      "<b>Vadeli (izole teminat)</b>",
      "/long BTC 100 10x — 100 USDT teminatla 10x long",
      "/short ETH 50 5x — 50 USDT teminatla 5x short",
      "/close BTC — BTC pozisyonunu tamamen kapat (/kapat)",
      "",
      "<b>Hesap</b>",
      "/balance (/bakiye) · /orders (/emirler) · /positions (/pozisyonlar)",
      "/cancel (/iptal) — açık emri iptal et",
      "/price BTC (/fiyat) · /grafik BTC · /settings (/ayarlar) · /unlink (/dur)",
      "",
      "Emirler <b>onay beklemeden anında</b> işlenir. En düşük tutar 1 USDT, hesap başına dakikada en fazla 20 yeni emir. Fiyat verisi 120 saniyeden eskiyse emir reddedilir.",
      "Desteklenmeyenler: vadeli limit emir, TP/SL, kısmi kapama, çapraz teminat.",
    ].join("\n"),
    kb: kb(NAV()),
  };
}

/** Coin seçimi. prefix: "s" spot, "f" vadeli, "px" fiyat */
export function coinPicker(prefix: string, pairs: { mine?: string[]; top?: string[] }, title: string, hint: string): Screen {
  const mine = pairs.mine ?? [], top = (pairs.top ?? []).filter((s) => !mine.includes(s));
  const btns = [...mine.map((s) => b(`👜 ${s}`, `${prefix}:${s}`)), ...top.map((s) => b(s, `${prefix}:${s}`))];
  return { text: `${title}\n${mine.length ? "👜 = elindeki coinler\n" : ""}\n${hint}`, kb: kb(...rows(btns, 4), NAV()) };
}

function priceLine(p: any): string {
  const parts = [`Fiyat: <b>${price(p.price)}</b>`];
  if (p.change_pct != null) parts.push(`${pct(p.change_pct)} (24s)`);
  return parts.join(" · ");
}
function staleNote(p: any): string {
  return !p.custom && Number(p.age_s) > 120 ? `\n⚠️ Fiyat verisi ${Math.floor(Number(p.age_s))} sn önce güncellendi; şu an emir verilemez (120 sn sınırı).` : "";
}

export function spotCard(p: any, me: Me, bal: any): Screen {
  const h = (bal?.spot ?? []).find((x: any) => x.symbol === p.symbol);
  const lines = [`📈 <b>${esc(p.symbol)}/USDT</b> · Spot`, priceLine(p) + staleNote(p),
    `Elindeki: ${h ? `${qty(h.qty)} ${esc(p.symbol)} (≈ ${usdt(h.value)})` : `0 ${esc(p.symbol)}`}`,
    `Kullanılabilir: ${usdt(bal?.usdt ?? 0)}`];
  if (p.custom) lines.push("ℹ️ COINFORCE coini: yalnızca piyasa emri; fiyat işlem anında arz eğrisinden hesaplanır.");
  if (!me.trading) return { text: lines.join("\n") + "\n\n" + TRADING_OFF, kb: kb([b("💲 Grafik", `g|${p.symbol}|24h`)], NAV(["⬅️ Coinler", "s"])) };
  const r: Button[][] = [[b("🟢 Piyasa al", `sb:${p.symbol}`), b("🔴 Piyasa sat", `ss:${p.symbol}`)]];
  if (!p.custom) {
    r.push([b("📥 Limit al", `lb:${p.symbol}`), b("📤 Limit sat", `ls:${p.symbol}`)]);
    r.push([b("⛔ Stop al", `tb:${p.symbol}`), b("⛔ Stop sat", `ts:${p.symbol}`)]);
  }
  r.push([b("📈 Grafik", `g|${p.symbol}|24h`), b("📋 Emirler", "o")], NAV(["⬅️ Coinler", "s"]));
  return { text: lines.join("\n"), kb: { inline_keyboard: r } };
}

const BUY_USDT = [10, 25, 50, 100, 250, 500];
export function buyAmounts(sym: string, bal: any): Screen {
  return {
    text: `🟢 <b>${esc(sym)} piyasa alımı</b>\nKullanılabilir: ${usdt(bal?.usdt ?? 0)}\nTutarı seç; dokunduğun anda emir gerçekleşir.`,
    kb: kb(
      ...rows(BUY_USDT.map((v) => b(`${v} USDT`, `x:mb:${sym}:${v}`)), 3),
      [25, 50, 100].map((v) => b(`%${v}`, `x:mbp:${sym}:${v}`)),
      [b("✏️ Başka tutar yaz", `ci:mb:${sym}`)],
      NAV(["⬅️ Geri", `s:${sym}`]),
    ),
  };
}
export function sellAmounts(sym: string, bal: any): Screen {
  const h = (bal?.spot ?? []).find((x: any) => x.symbol === sym);
  return {
    text: `🔴 <b>${esc(sym)} piyasa satışı</b>\nElindeki: ${h ? `${qty(h.qty)} ${esc(sym)} (≈ ${usdt(h.value)})` : `0 ${esc(sym)}`}\nOranı seç; dokunduğun anda emir gerçekleşir.`,
    kb: kb([25, 50, 75, 100].map((v) => b(v === 100 ? "Tamamı" : `%${v}`, `x:msp:${sym}:${v}`)), [b("✏️ Adet ya da USDT yaz", `ci:ms:${sym}`)], NAV(["⬅️ Geri", `s:${sym}`])),
  };
}

/** Limit/stop için fiyat seçimi. t: "l" limit | "t" stop, side: "b" | "s" */
export function triggerPrices(sym: string, t: "l" | "t", side: "b" | "s", p: any): Screen {
  const offs = t === "l" ? (side === "b" ? [-1, -2, -3, -5, -10] : [1, 2, 3, 5, 10]) : (side === "b" ? [1, 2, 3, 5] : [-1, -2, -3, -5]);
  const name = `${t === "l" ? "Limit" : "Stop"} ${side === "b" ? "alış" : "satış"}`;
  const btns = offs.map((o) => {
    const v = roundPrice(Number(p.price) * (1 + o / 100));
    return b(`${o > 0 ? "+" : "−"}${Math.abs(o)}% · ${price(v)}`, `${t}p:${sym}:${side}:${priceKey(v)}`);
  });
  const rule = t === "l"
    ? (side === "b" ? "Limit alış fiyatı güncel fiyatın altında olmalı." : "Limit satış fiyatı güncel fiyatın üstünde olmalı.")
    : (side === "b" ? "Stop alış fiyatı güncel fiyatın üstünde olmalı." : "Stop satış fiyatı güncel fiyatın altında olmalı.");
  return {
    text: `${t === "l" ? "📥" : "⛔"} <b>${esc(sym)} ${name}</b>\n${priceLine(p)}\n${rule}\nEmir fiyatını seç:`,
    kb: kb(...rows(btns, 2), [b("✏️ Fiyat yaz", `ci:${t}p${side}:${sym}`)], NAV(["⬅️ Geri", `s:${sym}`])),
  };
}

/** Limit/stop için tutar seçimi (fiyat seçildikten sonra). */
export function triggerAmounts(sym: string, t: "l" | "t", side: "b" | "s", trig: number, bal: any): Screen {
  const name = `${t === "l" ? "Limit" : "Stop"} ${side === "b" ? "alış" : "satış"}`;
  const pk = priceKey(trig);
  if (side === "b") {
    return {
      text: `${t === "l" ? "📥" : "⛔"} <b>${esc(sym)} ${name}</b> · Emir fiyatı ${price(trig)}\nKullanılabilir: ${usdt(bal?.usdt ?? 0)}\nTutarı seç; dokunduğun anda emir açılır.`,
      kb: kb(...rows([25, 50, 100, 250, 500, 1000].map((v) => b(`${v} USDT`, `x:${t}b:${sym}:${pk}:${v}`)), 3),
        [b("✏️ Başka tutar yaz", `ci:${t}b:${sym}:${pk}`)], NAV(["⬅️ Geri", `${t}b:${sym}`])),
    };
  }
  const h = (bal?.spot ?? []).find((x: any) => x.symbol === sym);
  return {
    text: `${t === "l" ? "📤" : "⛔"} <b>${esc(sym)} ${name}</b> · Emir fiyatı ${price(trig)}\nElindeki: ${h ? `${qty(h.qty)} ${esc(sym)}` : `0 ${esc(sym)}`}\nOranı seç; dokunduğun anda emir açılır.`,
    kb: kb([25, 50, 75, 100].map((v) => b(v === 100 ? "Tamamı" : `%${v}`, `x:${t}sp:${sym}:${pk}:${v}`)),
      [b("✏️ Adet yaz", `ci:${t}s:${sym}:${pk}`)], NAV(["⬅️ Geri", `${t}s:${sym}`])),
  };
}

export function futCard(p: any, me: Me, bal: any, positions: any[]): Screen {
  const mine = positions.filter((x) => x.symbol === p.symbol);
  const lines = [`⚡ <b>${esc(p.symbol)}/USDT</b> · Vadeli`, priceLine(p) + staleNote(p),
    `Teminat modu: İzole (çapraz teminat desteklenmiyor) · En yüksek kaldıraç: ${p.max_leverage}x`,
    `Kullanılabilir: ${usdt(bal?.usdt ?? 0)}`];
  if (mine.length) lines.push(`Açık pozisyonların: ${mine.map((x) => `${x.side > 0 ? "Long" : "Short"} ${x.leverage}x (${signedMoney(x.unrealized)} USDT)`).join(", ")}`);
  if (p.custom) return { text: lines.join("\n") + "\n\nℹ️ COINFORCE coinlerinde vadeli işlem yok.", kb: kb(NAV(["⬅️ Coinler", "f"])) };
  if (!me.trading) return { text: lines.join("\n") + "\n\n" + TRADING_OFF, kb: kb(NAV(["⬅️ Coinler", "f"])) };
  return {
    text: lines.join("\n") + "\n\nPiyasa fiyatından açılır. Vadeli limit emir, TP/SL ve kısmi kapama desteklenmiyor.",
    kb: kb([b("🟢 Long", `fl:${p.symbol}`), b("🔴 Short", `fs:${p.symbol}`)], [b("📊 Pozisyonlar", "p")], NAV(["⬅️ Coinler", "f"])),
  };
}

const LEVS = [2, 3, 5, 10, 20, 25, 50];
export function leverages(sym: string, side: "L" | "S", maxLev: number, margin?: number): Screen {
  const list = LEVS.filter((l) => l <= maxLev);
  if (!list.includes(maxLev) && maxLev > 1) list.push(maxLev);
  const data = (l: number) => margin ? `x:fo:${sym}:${side}:${l}:${margin}` : `fm:${sym}:${side}:${l}`;
  return {
    text: `${side === "L" ? "🟢 Long" : "🔴 Short"} <b>${esc(sym)}</b>${margin ? ` · Teminat ${usdt(margin)}` : ""}\nKaldıracı seç (en fazla ${maxLev}x)${margin ? "; dokunduğun anda pozisyon açılır." : ":"}`,
    kb: kb(...rows([1, ...list].map((l) => b(`${l}x`, data(l))), 4), NAV(["⬅️ Geri", `f:${sym}`])),
  };
}
export function margins(sym: string, side: "L" | "S", lev: number, bal: any): Screen {
  return {
    text: `${side === "L" ? "🟢 Long" : "🔴 Short"} <b>${esc(sym)} ${lev}x</b>\nKullanılabilir: ${usdt(bal?.usdt ?? 0)}\nTeminatı seç; dokunduğun anda pozisyon açılır. Komisyon: büyüklüğün %0,05'i.`,
    kb: kb(...rows([10, 25, 50, 100, 250, 500].map((v) => b(`${v} USDT`, `x:fo:${sym}:${side}:${lev}:${v}`)), 3),
      [10, 25, 50].map((v) => b(`%${v}`, `x:fop:${sym}:${side}:${lev}:${v}`)),
      [b("✏️ Başka tutar yaz", `ci:fo:${sym}:${side}:${lev}`)], NAV(["⬅️ Geri", `f${side === "L" ? "l" : "s"}:${sym}`])),
  };
}

export function balance(bal: any): Screen {
  const spot = (bal.spot ?? []) as any[];
  const lines = [
    `💰 <b>Bakiye</b> · @${esc(bal.username)}`,
    `Toplam varlık: <b>${usdt(bal.equity)}</b>`,
    `Kullanılabilir USDT: <b>${usdt(bal.usdt)}</b>`,
    `Spot varlıklar: ${usdt(bal.spot_value)}`,
    `Emirlerde ayrılan: ${usdt(bal.orders_reserved)}`,
    `Vadeli kullanılan teminat: ${usdt(bal.margin_used)}`,
    `Gerçekleşmemiş K/Z: ${signedMoney(bal.unrealized)} USDT`,
    `Açık emir: ${bal.open_orders} · Açık pozisyon: ${bal.open_positions}`,
    "<i>Spot ve vadeli aynı USDT bakiyesini kullanır; ayrı vadeli cüzdan yok.</i>",
  ];
  if (spot.length) {
    lines.push("", "<b>Spot varlıklar</b>");
    for (const h of spot.slice(0, 10)) lines.push(`• ${esc(h.symbol)}: ${qty(h.qty)} · ${usdt(h.value)} (${signedMoney(h.pnl)})`);
    if (spot.length > 10) lines.push(`… ve ${spot.length - 10} coin daha`);
  }
  return { text: lines.join("\n"), kb: kb([b("📋 Emirler", "o"), b("📊 Pozisyonlar", "p")], [b("🔄 Yenile", "b"), b("🏠 Menü", "m")]) };
}

const TYPE_TR: Record<string, string> = { limit: "Limit", stop: "Stop" };
export function ordersList(list: any[], trading: boolean): Screen {
  if (!list.length) return { text: "📋 <b>Açık emir yok.</b>\nLimit/stop emri vermek için: /buy BTC 100 limit 60000", kb: kb([b("📈 Spot", "s")], NAV()) };
  const lines = ["📋 <b>Açık emirler</b>"];
  const btns: Button[] = [];
  list.slice(0, 15).forEach((o, i) => {
    lines.push(`${i + 1}. ${TYPE_TR[o.type] ?? esc(o.type)} ${o.side === "buy" ? "alış" : "satış"} · ${esc(o.symbol)} · ${qty(o.qty)} @ ${price(o.trigger_price)} (şu an ${price(o.price)})`);
    if (trading) btns.push(b(`❌ ${i + 1}. iptal`, `x:oc:${o.id}`));
  });
  if (list.length > 15) lines.push(`… ve ${list.length - 15} emir daha`);
  if (!trading) lines.push("", TRADING_OFF);
  return { text: lines.join("\n"), kb: kb(...rows(btns, 3), [b("🔄 Yenile", "o"), b("🏠 Menü", "m")]) };
}

export function positionsList(list: any[], trading: boolean): Screen {
  if (!list.length) return { text: "📊 <b>Açık pozisyon yok.</b>\nPozisyon açmak için: /long BTC 100 10x", kb: kb([b("⚡ Vadeli", "f")], NAV()) };
  const lines = ["📊 <b>Açık pozisyonlar</b> (izole teminat)"];
  const btns: Button[] = [];
  list.slice(0, 15).forEach((p, i) => {
    lines.push(`${i + 1}. ${esc(p.symbol)} ${p.side > 0 ? "Long" : "Short"} ${p.leverage}x · Teminat ${usdt(p.margin)}`,
      `   Giriş ${price(p.entry_price)} → Şu an ${price(p.mark)} · Tasfiye ${price(p.liq_price)}`,
      `   Gerçekleşmemiş K/Z: <b>${signedMoney(p.unrealized)} USDT</b> (${pct(p.roe_pct)})`);
    if (trading) btns.push(b(`✖️ ${i + 1}. kapat`, `x:fc:${p.id}`));
  });
  if (!trading) lines.push("", TRADING_OFF);
  return { text: lines.join("\n"), kb: kb(...rows(btns, 3), [b("🔄 Yenile", "p"), b("🏠 Menü", "m")]) };
}

export function pricesList(list: any[]): Screen {
  const lines = ["💲 <b>Fiyatlar</b>"];
  for (const p of list) lines.push(`• <b>${esc(p.symbol)}</b> ${price(p.price)} ${pct(p.change_pct)}`);
  lines.push("", "Bir coine dokun ya da yaz: /price PEPE");
  return { text: lines.join("\n"), kb: kb(...rows(list.slice(0, 12).map((p) => b(p.symbol, `px:${p.symbol}`)), 4), NAV()) };
}

export function priceCard(p: any): Screen {
  const lines = [`💲 <b>${esc(p.name ?? p.symbol)} (${esc(p.symbol)}/USDT)</b>`, priceLine(p)];
  if (Number(p.high_24h) > 0 && Number(p.low_24h) > 0) lines.push(`24s aralık: ${price(p.low_24h)} – ${price(p.high_24h)}`);
  lines.push(p.custom ? "COINFORCE coini · fiyat arz eğrisinden" : `Veri yaşı: ${Math.max(0, Math.floor(Number(p.age_s)))} sn${Number(p.age_s) > 120 ? " ⚠️ (emir verilemez)" : ""}`);
  if (!p.listed) lines.push("⚠️ Bu coin şu an işleme kapalı.");
  return {
    text: lines.join("\n"),
    kb: kb([b("📈 Grafik", `g|${p.symbol}|24h`), b("ℹ️ Bilgi", `i|${p.symbol}`)], [b("Spot", `s:${p.symbol}`), b("Vadeli", `f:${p.symbol}`)], NAV(["⬅️ Fiyatlar", "px"])),
  };
}

export function settings(me: Me, tgName?: string): Screen {
  const on = (v?: boolean) => (v ? "açık" : "kapalı");
  return {
    text: [
      "⚙️ <b>Ayarlar</b>",
      `COINFORCE hesabı: <b>@${esc(me.username)}</b>${tgName ? ` · Telegram: @${esc(tgName)}` : ""}`,
      `Telegram ile işlem: <b>${me.trading ? "🔓 açık" : "🔒 kapalı"}</b>`,
      `Bildirimler: alarmlar ${on(me.alerts)} · günlük özet ${on(me.daily)} · haberler ${on(me.news)}`,
      "",
      "İşlem izni ve bildirimler yalnızca COINFORCE uygulamasından değiştirilir (Ayarlar › Telegram bildirimleri).",
    ].join("\n"),
    kb: kb([{ text: "📱 Uygulamayı aç", url: APP_URL }], [b("🔌 Bağlantıyı kaldır", "ul")], NAV()),
  };
}
export const unlinkConfirm = (): Screen => ({
  text: "🔌 Telegram bağlantısı kaldırılsın mı? Bildirimler durur ve işlem izni kapanır. Tekrar bağlamak için uygulamadan yeni kod alman gerekir.",
  kb: kb([b("Evet, kaldır", "ul!"), b("Vazgeç", "st")]),
});

const KIND_TR: Record<string, string> = { spot_market: "Piyasa", spot_limit: "Limit", spot_stop: "Stop" };
/** tgx_order sonucunu mesaja çevirir. */
export function orderResult(r: any): Screen {
  const dup = r?.duplicate ? "ℹ️ <i>Bu istek zaten işlenmişti; ikinci emir oluşturulmadı.</i>\n" : "";
  const sym = esc(r?.symbol ?? "");
  const res = r?.result ?? {};
  if (!r?.ok) {
    const hints: Record<string, string> = {
      TRADING_OFF: "", NOT_LINKED: "", RATE_LIMIT: "", PRICE_STALE: "\nFiyat güncellenince tekrar dene.",
      BALANCE: "\n/balance ile bakiyeni gör.", MIN_AMOUNT: "", PAIR: "\nSembolü kontrol et: /price SEMBOL",
    };
    return {
      text: `${dup}❌ <b>Emir reddedildi</b>${sym ? ` · ${sym}/USDT` : ""}\n${esc(r?.error ?? "Bilinmeyen hata")}${hints[r?.code] ?? ""}`,
      kb: kb(r?.code === "TRADING_OFF" ? [{ text: "📱 Uygulamayı aç", url: APP_URL }] : [], [b("💰 Bakiye", "b"), b("🏠 Menü", "m")]),
    };
  }
  const after = res.balance_after != null ? `\nKullanılabilir USDT: ${usdt(res.balance_after)}` : "";
  switch (r.kind) {
    case "spot_market": {
      const q = Number(res.qty), p = Number(res.price), fee = Number(res.fee ?? 0), val = q * p;
      const buy = r.side === "buy";
      return {
        text: `${dup}✅ <b>${buy ? "Alındı" : "Satıldı"}</b> · ${sym}/USDT piyasa\nMiktar: ${qty(q)} ${sym}\nOrtalama fiyat: ${price(p)}\n${buy ? "Tutar" : "Satış tutarı"}: ${usdt(val)} · Komisyon: ${usdt(fee)}${buy ? "" : `\nHesaba geçen: ${usdt(val - fee)}`}${after}`,
        kb: kb([b(`📈 ${r.symbol}`, `s:${r.symbol}`), b("💰 Bakiye", "b")], [b("🏠 Menü", "m")]),
      };
    }
    case "spot_limit": case "spot_stop": {
      const buy = res.side === "buy" || r.side === "buy";
      return {
        text: `${dup}🕒 <b>${KIND_TR[r.kind]} ${buy ? "alış" : "satış"} emri açıldı</b> · ${sym}/USDT\nMiktar: ${qty(res.qty)} ${sym} · Emir fiyatı: ${price(res.trigger_price)}\n${buy ? `Ayrılan: ${usdt(res.reserved_usdt)}` : `Ayrılan: ${qty(res.qty)} ${sym}`}${after}\nFiyat seviyeye gelince gerçekleşir; Telegram'dan bildirim gelir.`,
        kb: kb([b("📋 Emirler", "o"), b("❌ İptal et", `x:oc:${res.order_id}`)], [b("🏠 Menü", "m")]),
      };
    }
    case "futures_open":
      return {
        text: `${dup}✅ <b>${Number(res.side) > 0 ? "Long" : "Short"} açıldı</b> · ${sym}/USDT ${res.leverage}x (izole)\nTeminat: ${usdt(res.margin)} · Büyüklük: ${usdt(Number(res.margin) * Number(res.leverage))}\nGiriş: ${price(res.entry_price)} · Tasfiye: ${price(res.liq_price)}\nKomisyon: ${usdt(res.fee)}${after}`,
        kb: kb([b("✖️ Pozisyonu kapat", `x:fc:${res.position_id}`), b("📊 Pozisyonlar", "p")], [b("🏠 Menü", "m")]),
      };
    case "futures_close":
      return {
        text: `${dup}✅ <b>Pozisyon kapatıldı</b> · ${sym}/USDT ${Number(res.side) > 0 ? "Long" : "Short"} ${res.leverage}x\nGiriş: ${price(res.entry_price)} → Çıkış: ${price(res.exit_price)}\nGerçekleşen K/Z (komisyon dahil): <b>${signedMoney(res.pnl)} USDT</b>${after}`,
        kb: kb([b("📊 Pozisyonlar", "p"), b("💰 Bakiye", "b")], [b("🏠 Menü", "m")]),
      };
    case "order_cancel":
      return {
        text: `${dup}🗑 <b>Emir iptal edildi</b> · ${sym}/USDT ${TYPE_TR[res.type] ?? ""} ${res.side === "buy" ? "alış" : "satış"}\n${qty(res.qty)} ${sym} @ ${price(res.trigger_price)}${after}`,
        kb: kb([b("📋 Emirler", "o"), b("🏠 Menü", "m")]),
      };
  }
  return { text: `${dup}✅ İşlem tamamlandı.`, kb: kb(NAV()) };
}
