// Biçimlendirme ve kullanıcı girdisi ayrıştırma (saf fonksiyonlar, birim testli).
// Tutarlar Türkçe biçimde gösterilir (1.234,56). Girdi hem 1234,56 hem 1234.56 biçimini kabul eder;
// 2.500 gibi belirsiz yazımlar reddedilir (anında işlemde 1000 kat hata olmasın diye).

export const esc = (x: unknown) =>
  String(x ?? "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" } as Record<string, string>)[c]);

const nf = (min: number, max: number) => new Intl.NumberFormat("tr-TR", { minimumFractionDigits: min, maximumFractionDigits: max });
const NF2 = nf(2, 2);

/** 1.234,56 (para, 2 hane) */
export function money(v: number): string {
  const n = Number(v);
  return Number.isFinite(n) ? NF2.format(Math.abs(n) < 0.005 ? 0 : n) : "—";
}
/** 1.234,56 USDT */
export const usdt = (v: number) => `${money(v)} USDT`;
/** İşaretli para: +12,34 / −5,00 */
export function signedMoney(v: number): string {
  const n = Number(v);
  if (!Number.isFinite(n)) return "—";
  const r = Math.round(n * 100) / 100;
  return (r > 0 ? "+" : r < 0 ? "−" : "") + NF2.format(Math.abs(r));
}
/** Fiyat: büyük fiyatlarda 2 hane, küçüklerde 6 anlamlı haneye kadar. $ işaretli. */
export function price(v: number): string {
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) return "—";
  if (n >= 1000) return "$" + nf(2, 2).format(n);
  if (n >= 1) return "$" + nf(2, 4).format(n);
  const digits = Math.min(12, Math.max(4, 5 - Math.floor(Math.log10(n))));
  return "$" + nf(2, digits).format(n);
}
/** Coin miktarı: en fazla 8 ondalık, sondaki sıfırlar atılır. */
export function qty(v: number): string {
  const n = Number(v);
  if (!Number.isFinite(n)) return "—";
  return nf(0, 8).format(n);
}
/** Yüzde: +2,35% */
export function pct(v: number | null | undefined): string {
  const n = Number(v);
  if (v == null || !Number.isFinite(n)) return "—";
  return (n > 0 ? "+" : n < 0 ? "−" : "") + nf(2, 2).format(Math.abs(n)) + "%";
}
/** Bir fiyatı callback verisine sığacak kısa ondalık metne çevirir (8 anlamlı hane). */
export function priceKey(v: number): string {
  return Number(Number(v).toPrecision(8)).toString();
}
/** Fiyatı makul bir adıma yuvarlar (gösterilen ve gönderilen fiyat aynı olsun). */
export function roundPrice(v: number): number {
  const n = Number(v);
  if (!(n > 0)) return 0;
  const step = n >= 1000 ? 0.01 : n >= 1 ? 0.0001 : Math.pow(10, Math.floor(Math.log10(n)) - 5);
  return Number((Math.round(n / step) * step).toPrecision(10));
}

export type Num = { ok: true; value: number } | { ok: false; error: string };

/** Sayı ayrıştırma: 1234,56 / 1234.56 / 1.234,56 / 1,234.56 / 0,001 kabul; 2.500 gibi belirsizler reddedilir. */
export function parseNum(raw: string): Num {
  let s = String(raw ?? "").trim().replace(/\s+/g, "").replace(/^\+/, "");
  if (!s) return { ok: false, error: "Bir sayı yaz." };
  if (!/^[0-9.,]+$/.test(s)) return { ok: false, error: `“${esc(raw)}” geçerli bir sayı değil.` };
  const dots = (s.match(/\./g) ?? []).length, commas = (s.match(/,/g) ?? []).length;
  if (dots && commas) {
    const dec = s.lastIndexOf(",") > s.lastIndexOf(".") ? "," : ".";
    const thou = dec === "," ? "." : ",";
    const [intPart, frac = ""] = s.split(dec);
    if ((s.match(new RegExp("\\" + dec, "g")) ?? []).length > 1) return { ok: false, error: `“${esc(raw)}” geçerli bir sayı değil.` };
    if (!/^\d{1,3}(\d{3})*$/.test(intPart.split(thou).join("")) || !intPart.split(thou).slice(1).every((g) => g.length === 3)) {
      return { ok: false, error: `“${esc(raw)}” geçerli bir sayı değil.` };
    }
    s = intPart.split(thou).join("") + "." + frac;
  } else if (dots + commas > 1) {
    const sep = dots ? "." : ",";
    const parts = s.split(sep);
    if (!parts.slice(1).every((g) => g.length === 3) || !/^\d{1,3}$/.test(parts[0])) return { ok: false, error: `“${esc(raw)}” geçerli bir sayı değil.` };
    s = parts.join("");
  } else if (dots + commas === 1) {
    const sep = dots ? "." : ",";
    const [a, b] = s.split(sep);
    if (!a && !b) return { ok: false, error: "Bir sayı yaz." };
    // 2.500 → 2,5 mi 2500 mü? Sıfırla başlamayan 1-3 haneli tam kısım + tam 3 ondalık hane belirsizdir.
    if (b.length === 3 && /^[1-9]\d{0,2}$/.test(a)) {
      return { ok: false, error: `“${esc(raw)}” belirsiz: ${a}${b} mü, ${a},${b} mi? Binlik ayırıcı kullanmadan yaz (ör. ${a}${b} ya da ${a},${b.replace(/0+$/, "") || "0"}).` };
    }
    s = (a || "0") + "." + b;
  }
  const v = Number(s);
  if (!Number.isFinite(v)) return { ok: false, error: `“${esc(raw)}” geçerli bir sayı değil.` };
  if (v > 1e15) return { ok: false, error: "Sayı çok büyük." };
  return { ok: true, value: v };
}

/** BTC, btc, BTC/USDT, BTCUSDT, $btc → BTC */
export function parseSymbol(raw: string): string | null {
  let s = String(raw ?? "").trim().toUpperCase().replace(/^\$/, "");
  s = s.replace(/[\/\-_]?USDT$/, (m) => (s.length - m.length >= 2 ? "" : m));
  return /^[A-Z0-9]{1,20}$/.test(s) && s !== "USDT" ? s : null;
}

export type Amount =
  | { kind: "usdt"; value: number }
  | { kind: "pct"; value: number }
  | { kind: "qty"; value: number }
  | { kind: "all" };

/** Tutar: 100, 100usdt, 100$, $100 → USDT; %50, 50% → yüzde; hepsi/tümü/all → tamamı; diğer sayı → adet (qtyDefault). */
export function parseAmount(raw: string, qtyDefault: boolean): { ok: true; amount: Amount } | { ok: false; error: string } {
  const s = String(raw ?? "").trim().toLowerCase();
  if (["all", "hepsi", "tümü", "tumu", "tamamı", "tamami", "max"].includes(s)) return { ok: true, amount: { kind: "all" } };
  let m = s.match(/^%\s*([0-9.,]+)$/) ?? s.match(/^([0-9.,]+)\s*%$/);
  if (m) {
    const n = parseNum(m[1]);
    if (!n.ok) return n;
    if (n.value <= 0 || n.value > 100) return { ok: false, error: "Yüzde 0 ile 100 arasında olmalı." };
    return { ok: true, amount: { kind: "pct", value: n.value } };
  }
  m = s.match(/^\$\s*([0-9.,]+)$/) ?? s.match(/^([0-9.,]+)\s*(usdt|usd|\$)$/);
  if (m) {
    const n = parseNum(m[1]);
    if (!n.ok) return n;
    return { ok: true, amount: { kind: "usdt", value: n.value } };
  }
  const n = parseNum(s);
  if (!n.ok) return n;
  return { ok: true, amount: qtyDefault ? { kind: "qty", value: n.value } : { kind: "usdt", value: n.value } };
}

/** 10x, x10, 10 → 10 */
export function parseLeverage(raw: string): number | null {
  const m = String(raw ?? "").trim().toLowerCase().match(/^x?(\d{1,3})x?$/);
  return m ? Number(m[1]) : null;
}

export type OrderType = "market" | "limit" | "stop";

export type ParsedSpot = {
  symbol: string | null;
  amount: Amount | null;
  type: OrderType;
  price: number | null;
  error?: string;
};

/**
 * /buy ve /sell argümanları: SEMBOL [TUTAR] [limit|stop FİYAT | @FİYAT]
 * Alışta tutar USDT'dir (%50 = USDT bakiyesinin yarısı). Satışta tutar adettir (%50 = elindekinin yarısı,
 * hepsi = tamamı, 100usdt = 100 USDT'lik).
 */
export function parseSpotArgs(args: string[], side: "buy" | "sell"): ParsedSpot {
  const out: ParsedSpot = { symbol: null, amount: null, type: "market", price: null };
  const t = args.map((a) => a.trim()).filter(Boolean);
  if (!t.length) return out;
  out.symbol = parseSymbol(t[0]);
  if (!out.symbol) return { ...out, error: `“${esc(t[0])}” geçerli bir sembol değil.` };
  const rest = t.slice(1);
  for (let i = 0; i < rest.length; i++) {
    const w = rest[i].toLowerCase();
    if (w === "limit" || w === "lmt" || w === "stop" || w === "stp") {
      out.type = w.startsWith("l") ? "limit" : "stop";
      const p = parseNum((rest[i + 1] ?? "").replace(/^@/, ""));
      if (!p.ok) return { ...out, error: rest[i + 1] ? p.error : "Emir fiyatını yaz (ör. limit 60000)." };
      out.price = p.value; i++; continue;
    }
    if (w.startsWith("@")) {
      out.type = "limit";
      const p = parseNum(w.slice(1));
      if (!p.ok) return { ...out, error: p.error };
      out.price = p.value; continue;
    }
    if (w === "market" || w === "piyasa") { out.type = "market"; continue; }
    if (SPOT_UNSUPPORTED.has(w)) return { ...out, error: "TP/SL desteklenmiyor. Spotta piyasa, limit ve stop emri verebilirsin (ör. /sell BTC hepsi stop 60000)." };
    if (out.amount) return { ...out, error: `Fazla değer: “${esc(rest[i])}”.` };
    const a = parseAmount(rest[i], side === "sell");
    if (!a.ok) return { ...out, error: a.error };
    if (side === "buy" && (a.amount.kind === "qty" || a.amount.kind === "all")) {
      // Alışta düz sayı USDT'dir; "hepsi" = kullanılabilir USDT'nin tamamı.
      out.amount = a.amount.kind === "all" ? { kind: "pct", value: 100 } : { kind: "usdt", value: (a.amount as { value: number }).value };
    } else out.amount = a.amount;
  }
  if (out.price !== null && !(out.price > 0)) return { ...out, error: "Emir fiyatı sıfırdan büyük olmalı." };
  return out;
}

export type ParsedFut = { symbol: string | null; margin: Amount | null; leverage: number | null; error?: string };

// Motorun desteklemediği emir türleri: sessizce yok sayılıp piyasa emri açılmasın diye açıkça reddedilir.
const SPOT_UNSUPPORTED = new Set(["tp", "sl", "tp/sl", "takeprofit", "stoploss", "oco"]);
const FUT_UNSUPPORTED = new Set(["limit", "lmt", "stop", "stp", "tp", "sl", "tp/sl", "takeprofit", "stoploss", "oco", "cross", "çapraz", "capraz"]);
export const FUT_UNSUPPORTED_MSG = "Vadeli işlemde pozisyon yalnızca piyasa fiyatından ve izole teminatla açılır. Limit emir, TP/SL ve çapraz teminat desteklenmiyor.";

/** /long ve /short argümanları: SEMBOL [TEMİNAT] [KALDIRAÇx] — sıra serbest (10x her yerde olabilir). */
export function parseFutArgs(args: string[]): ParsedFut {
  const out: ParsedFut = { symbol: null, margin: null, leverage: null };
  const t = args.map((a) => a.trim()).filter(Boolean);
  if (!t.length) return out;
  out.symbol = parseSymbol(t[0]);
  if (!out.symbol) return { ...out, error: `“${esc(t[0])}” geçerli bir sembol değil.` };
  for (const w of t.slice(1)) {
    const lw = w.toLowerCase();
    if (FUT_UNSUPPORTED.has(lw) || lw.startsWith("@")) return { ...out, error: FUT_UNSUPPORTED_MSG };
    if (["izole", "isolated", "market", "piyasa"].includes(lw)) continue; // tek desteklenen mod zaten bu
    if (/^x?\d{1,3}x$|^x\d{1,3}$/i.test(w)) { out.leverage = parseLeverage(w); continue; }
    if (out.margin) {
      const lv = parseLeverage(w);
      if (lv && !out.leverage) { out.leverage = lv; continue; }
      return { ...out, error: `Fazla değer: “${esc(w)}”.` };
    }
    const a = parseAmount(w, false);
    if (!a.ok) return { ...out, error: a.error };
    if (a.amount.kind === "qty" || a.amount.kind === "all") return { ...out, error: "Teminatı USDT olarak yaz (ör. 100) ya da bakiyenin yüzdesi olarak (%25)." };
    out.margin = a.amount;
  }
  return out;
}

/** Komut adı: /Buy@BotAdı → buy */
export function commandName(text: string): { cmd: string; args: string[] } {
  const parts = String(text ?? "").trim().split(/\s+/);
  const cmd = (parts[0] ?? "").toLowerCase().replace(/@.*$/, "").replace(/^\//, "");
  return { cmd, args: parts.slice(1) };
}
