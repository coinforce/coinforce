// COINFORCE Telegram bildirim botu — bildirim ve grafik gösterir, emir almaz.
// Gizli değer (Supabase > Edge Functions > Secrets): TELEGRAM_BOT_TOKEN
// Kurulum: tarayıcıda bir kez  .../functions/v1/telegram-notify?setup=1  adresini aç.
import { createClient } from "jsr:@supabase/supabase-js@2";

const TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const API = `https://api.telegram.org/bot${TOKEN}`;

async function hookSecret(): Promise<string> {
  const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("cf-notify:" + TOKEN));
  return Array.from(new Uint8Array(h)).map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 48);
}
async function tg(method: string, body: Record<string, unknown>) {
  const r = await fetch(`${API}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return await r.json().catch(() => ({ ok: false }));
}
const APP_URL = Deno.env.get("COINFORCE_APP_URL") ?? "https://coinforce.github.io/coinforce/";
// Al/Sat butonları uygulamayı o coinin işlem ekranında açar; emir uygulamanın içinde verilir.
function keyboard(syms?: string[] | null) {
  const list = (syms ?? []).filter((x) => /^[A-Z0-9]{1,20}$/.test(x)).slice(0, 5);
  if (!list.length) return undefined;
  const link = (sym: string, side: string) => `${APP_URL}?coin=${encodeURIComponent(sym)}&side=${side}`;
  return {
    inline_keyboard: list.map((sym) => [
      { text: `🟢 Al ${sym}`, url: link(sym, "buy") },
      { text: `🔴 Sat ${sym}`, url: link(sym, "sell") },
    ]),
  };
}
const send = (chat: number, text: string, syms?: string[] | null) => {
  const kb = keyboard(syms);
  return tg("sendMessage", {
    chat_id: chat, text, parse_mode: "HTML", disable_web_page_preview: true, ...(kb ? { reply_markup: kb } : {}),
  });
};

// ───────────── Grafik ─────────────
type Range = "1h" | "24h" | "7d";
const RANGES: Range[] = ["1h", "24h", "7d"];
const RLABEL: Record<Range, string> = { "1h": "1S", "24h": "24S", "7d": "7G" };
const RHOURS: Record<Range, number> = { "1h": 1, "24h": 24, "7d": 168 };
const GT_NET: Record<string, string> = { ethereum: "eth", polygon: "polygon_pos", avalanche: "avax", arbitrum: "arbitrum", base: "base", bsc: "bsc", solana: "solana", optimism: "optimism" };
const fmtUsd = (v: number) => "$" + Number(v).toLocaleString("en-US", v >= 1 ? { minimumFractionDigits: 2, maximumFractionDigits: 2 } : { maximumSignificantDigits: 4 });
const fmtBig = (v: number) => v >= 1e9 ? "$" + (v / 1e9).toFixed(2) + "B" : v >= 1e6 ? "$" + (v / 1e6).toFixed(2) + "M" : v >= 1e3 ? "$" + (v / 1e3).toFixed(1) + "K" : fmtUsd(v);
const escH = (x: unknown) => String(x ?? "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" } as Record<string, string>)[c]);

async function getJson(url: string, headers: Record<string, string> = {}) {
  try {
    const r = await fetch(url, { headers: { accept: "application/json", ...headers }, signal: AbortSignal.timeout(8000) });
    return r.ok ? await r.json() : null;
  } catch { return null; }
}

async function series(c: any, range: Range): Promise<[number, number][]> {
  const now = Date.now(), from = now - RHOURS[range] * 3600e3;
  let pts: [number, number][] = [];
  if (c.custom) {
    pts = (c.ticks ?? []).map((t: any) => [Number(t[0]), Number(t[1])]);
  } else if (c.dex_chain && c.dex_pair) {
    const net = GT_NET[c.dex_chain] ?? c.dex_chain;
    const [tf, agg, lim] = range === "1h" ? ["minute", 1, 60] : range === "24h" ? ["minute", 15, 96] : ["hour", 1, 168];
    const j = await getJson(`https://api.geckoterminal.com/api/v2/networks/${net}/pools/${c.dex_pair}/ohlcv/${tf}?aggregate=${agg}&limit=${lim}&currency=usd`);
    pts = (j?.data?.attributes?.ohlcv_list ?? []).map((o: number[]) => [o[0] * 1000, Number(o[4])]).reverse();
  } else if (c.cg) {
    const h: Record<string, string> = c.cg_key ? { "x-cg-demo-api-key": c.cg_key } : {};
    const j = await getJson(`https://api.coingecko.com/api/v3/coins/${encodeURIComponent(c.cg)}/market_chart?vs_currency=usd&days=${range === "7d" ? 7 : 1}`, h);
    pts = (j?.prices ?? []).map((p: number[]) => [p[0], Number(p[1])]);
    if (pts.length < 3 && Array.isArray(c.spark) && range !== "1h") {
      const sp = range === "7d" ? c.spark : c.spark.slice(-24), step = (RHOURS[range] * 3600e3) / sp.length;
      pts = sp.map((v: number, i: number) => [from + i * step, Number(v)]);
    }
  }
  pts = pts.filter((p) => p[0] >= from - 60e3 && p[1] > 0);
  if (c.price > 0) pts.push([now, Number(c.price)]);
  if (pts.length === 1) pts.unshift([from, pts[0][1]]);
  return pts;
}

function hhmm(ms: number, withDay: boolean) {
  const d = new Date(ms + 3 * 3600e3); // Europe/Istanbul (UTC+3)
  const t = `${String(d.getUTCHours()).padStart(2, "0")}:${String(d.getUTCMinutes()).padStart(2, "0")}`;
  return withDay ? `${String(d.getUTCDate()).padStart(2, "0")}.${String(d.getUTCMonth() + 1).padStart(2, "0")} ${t}` : t;
}

async function renderChart(c: any, range: Range, pts: [number, number][]): Promise<Blob | null> {
  if (pts.length < 2) return null;
  if (pts.length > 120) { const k = Math.ceil(pts.length / 120), last = pts[pts.length - 1]; pts = pts.filter((_, i) => i % k === 0); if (pts[pts.length - 1] !== last) pts.push(last); }
  const up = pts[pts.length - 1][1] >= pts[0][1], col = up ? "#2ebd85" : "#f6465d";
  const cfg = {
    type: "line",
    data: {
      labels: pts.map((p) => hhmm(p[0], range === "7d")),
      datasets: [{ data: pts.map((p) => p[1]), borderColor: col, borderWidth: 3, pointRadius: 0, tension: 0.25, fill: true, backgroundColor: up ? "rgba(46,189,133,0.12)" : "rgba(246,70,93,0.12)" }],
    },
    options: {
      plugins: { legend: { display: false }, title: { display: true, text: `${c.symbol}/USD · ${RLABEL[range]}`, color: "#e6e8ee", font: { size: 22, weight: "bold" }, align: "start" } },
      scales: {
        x: { ticks: { color: "#8a90a2", maxTicksLimit: 6, maxRotation: 0, font: { size: 15 } }, grid: { display: false } },
        y: { position: "right", ticks: { color: "#8a90a2", maxTicksLimit: 6, font: { size: 15 } }, grid: { color: "rgba(255,255,255,0.06)" } },
      },
    },
  };
  try {
    const r = await fetch("https://quickchart.io/chart", {
      method: "POST", headers: { "content-type": "application/json" }, signal: AbortSignal.timeout(10000),
      body: JSON.stringify({ chart: cfg, width: 900, height: 500, devicePixelRatio: 2, backgroundColor: "#0b0e14", format: "png", version: "4" }),
    });
    return r.ok ? await r.blob() : null;
  } catch { return null; }
}

// Teknik gösterge özeti (TradingView tarzı sayım). Yatırım tavsiyesi değildir.
type Sig = "Al" | "Nötr" | "Sat";
function technicals(pts: [number, number][]) {
  const v = pts.map((p) => p[1]);
  if (v.length < 30) return null;
  const last = v[v.length - 1];
  const sma = (n: number) => { const a = v.slice(-Math.min(n, v.length)); return a.reduce((x, y) => x + y, 0) / a.length; };
  const emaArr = (src: number[], n: number) => { const k = 2 / (n + 1); const out: number[] = []; src.forEach((x, i) => out.push(i ? x * k + out[i - 1] * (1 - k) : x)); return out; };
  let g = 0, l = 0; for (let i = v.length - 14; i < v.length; i++) { const d = v[i] - v[i - 1]; if (d > 0) g += d; else l -= d; }
  const rsi = l === 0 ? 100 : 100 - 100 / (1 + g / l);
  const e12 = emaArr(v, 12), e26 = emaArr(v, 26), macd = e12.map((x, i) => x - e26[i]), sig = emaArr(macd, 9);
  const mom = last - v[v.length - 11];
  const w = v.slice(-14), hi = Math.max(...w), lo = Math.min(...w), k = hi > lo ? ((last - lo) / (hi - lo)) * 100 : 50;
  const m20 = sma(20), sd = Math.sqrt(v.slice(-20).reduce((a, x) => a + (x - m20) ** 2, 0) / 20);
  const pr = (x: number) => fmtUsd(x);
  const rows: { name: string; value: string; s: Sig }[] = [
    { name: "RSI (14)", value: rsi.toFixed(1), s: rsi < 30 ? "Al" : rsi > 70 ? "Sat" : "Nötr" },
    { name: "Stokastik %K (14)", value: k.toFixed(1), s: k < 20 ? "Al" : k > 80 ? "Sat" : "Nötr" },
    { name: "MACD (12,26,9)", value: (macd[macd.length - 1] - sig[sig.length - 1] >= 0 ? "+" : "") + ((macd[macd.length - 1] - sig[sig.length - 1]) / last * 100).toFixed(3) + "%", s: macd[macd.length - 1] > sig[sig.length - 1] ? "Al" : "Sat" },
    { name: "Momentum (10)", value: (mom >= 0 ? "+" : "") + (mom / last * 100).toFixed(2) + "%", s: mom > 0 ? "Al" : mom < 0 ? "Sat" : "Nötr" },
    { name: "Bollinger (20,2)", value: last > m20 + 2 * sd ? "üst bant üstü" : last < m20 - 2 * sd ? "alt bant altı" : "bant içi", s: last < m20 - 2 * sd ? "Al" : last > m20 + 2 * sd ? "Sat" : "Nötr" },
    { name: "SMA 10", value: pr(sma(10)), s: last > sma(10) ? "Al" : "Sat" },
    { name: "SMA 20", value: pr(m20), s: last > m20 ? "Al" : "Sat" },
    { name: "SMA 50", value: pr(sma(50)), s: last > sma(50) ? "Al" : "Sat" },
    { name: "EMA 12 / 26", value: e12[e12.length - 1] > e26[e26.length - 1] ? "12 > 26" : "12 < 26", s: e12[e12.length - 1] > e26[e26.length - 1] ? "Al" : "Sat" },
  ];
  const buy = rows.filter((r) => r.s === "Al").length, sell = rows.filter((r) => r.s === "Sat").length, neu = rows.length - buy - sell;
  const sc = (buy - sell) / rows.length;
  const label = sc <= -0.5 ? "Güçlü sat" : sc <= -0.1 ? "Sat" : sc < 0.1 ? "Nötr" : sc < 0.5 ? "Al" : "Güçlü al";
  const pct = (n: number) => Math.round((n / rows.length) * 100);
  return { rows, buy, sell, neu, label, pb: pct(buy), pn: pct(neu), ps: pct(sell) };
}
// 24S verisi yetersizse (az işlem gören DEX coinleri) 7G verisine düş
async function techFor(c: any, p24: [number, number][] | null) {
  const a = technicals(p24 ?? await series(c, "24h"));
  if (a) return { ...a, per: "24S" };
  const b = technicals(await series(c, "7d"));
  return b ? { ...b, per: "7G" } : null;
}
const techIcon = (l: string) => (l.includes("al") || l === "Al" ? (l.startsWith("Güçlü") ? "🟢🟢" : "🟢") : l.includes("sat") || l === "Sat" ? (l.startsWith("Güçlü") ? "🔴🔴" : "🔴") : "⚪");
function techBar(t: { pb: number; pn: number; ps: number }) {
  const n = 12, b = Math.round((t.pb / 100) * n), s = Math.round((t.ps / 100) * n), m = Math.max(0, n - b - s);
  return "🟩".repeat(b) + "⬜".repeat(m) + "🟥".repeat(s);
}

function caption(c: any, range: Range, pts: [number, number][], t?: (ReturnType<typeof technicals> & { per?: string }) | null) {
  const first = pts[0]?.[1] ?? c.price, last = Number(c.price), ch = first > 0 ? (last / first - 1) * 100 : 0;
  const vals = pts.map((p) => p[1]), hi = Math.max(...vals), lo = Math.min(...vals);
  const L = [
    `<b>${escH(c.name)} (${escH(c.symbol)})</b>`,
    `💵 ${fmtUsd(last)}   ${ch >= 0 ? "🟢 +" : "🔴 "}${ch.toFixed(2)}% <i>(${RLABEL[range]})</i>`,
    `▲ ${fmtUsd(hi)}   ▼ ${fmtUsd(lo)}`,
  ];
  if (c.market_cap > 0) L.push(`Piyasa değeri: ${fmtBig(c.market_cap)}${c.volume_24h > 0 ? ` · Hacim: ${fmtBig(c.volume_24h)}` : ""}`);
  if (t) L.push(`\n📊 <b>Teknik görünüm: ${techIcon(t.label)} ${t.label}</b>\n${techBar(t)}\nAl %${t.pb} · Nötr %${t.pn} · Sat %${t.ps}  <i>(${t.rows.length} gösterge, ${t.per ?? "24S"})</i>`);
  if (c.holding) L.push(`\n👜 Pozisyonun: ${fmtUsd(c.holding.value)} (${c.holding.pnl >= 0 ? "+" : "-"}${fmtUsd(Math.abs(c.holding.pnl))})`);
  L.push(`\n🕒 ${hhmm(Date.now(), true)} · <i>Yatırım tavsiyesi değildir.</i>`);
  const out = L.join("\n");
  return out.length > 1000 ? out.slice(0, 997) + "…" : out;
}

function chartKb(sym: string, range: Range) {
  const link = (side: string) => `${APP_URL}?coin=${encodeURIComponent(sym)}&side=${side}`;
  return {
    inline_keyboard: [
      RANGES.map((r) => ({ text: (r === range ? "• " : "") + RLABEL[r], callback_data: `g|${sym}|${r}` })),
      [{ text: "🔄 Yenile", callback_data: `g|${sym}|${range}|${Date.now() % 100000}` }, { text: "ℹ️ Bilgi", callback_data: `i|${sym}` }, { text: "📋 Coinler", callback_data: "l" }],
      [{ text: `🟢 Al ${sym}`, url: link("buy") }, { text: `🔴 Sat ${sym}`, url: link("sell") }],
    ],
  };
}

async function tgForm(method: string, fields: Record<string, string>, file?: Blob) {
  const f = new FormData();
  for (const [k, v] of Object.entries(fields)) f.append(k, v);
  if (file) f.append("photo", file, "chart.png");
  const r = await fetch(`${API}/${method}`, { method: "POST", body: f });
  return await r.json().catch(() => ({ ok: false }));
}

async function showChart(chat: number, symRaw: string, range: Range, editMsg?: number) {
  const { data: c } = await sb.rpc("tgn_coin", { p_chat: chat, p_sym: symRaw, p_hours: RHOURS[range] });
  if (!c) { if (!editMsg) await send(chat, `"${escH(symRaw)}" bulunamadı. /grafik yazıp listeden seçebilirsin.`); return; }
  const pts = await series(c, range);
  const t = await techFor(c, range === "24h" ? pts : null);
  const png = await renderChart(c, range, pts);
  const cap = caption(c, range, pts, t), kb = JSON.stringify(chartKb(c.symbol, range));
  if (!png) { await tg("sendMessage", { chat_id: chat, text: cap + "\n\n<i>Grafik şu an oluşturulamadı.</i>", parse_mode: "HTML", reply_markup: JSON.parse(kb) }); return; }
  if (editMsg) {
    const r = await tgForm("editMessageMedia", {
      chat_id: String(chat), message_id: String(editMsg), reply_markup: kb,
      media: JSON.stringify({ type: "photo", media: "attach://photo", caption: cap, parse_mode: "HTML" }),
    }, png);
    if (r?.ok) return;
  }
  await tgForm("sendPhoto", { chat_id: String(chat), caption: cap, parse_mode: "HTML", reply_markup: kb }, png);
}

async function coinList(chat: number, editMsg?: number) {
  const { data } = await sb.rpc("tgn_coin_list", { p_chat: chat });
  const mine: string[] = data?.mine ?? [], top: string[] = data?.top ?? [];
  const btn = (s: string) => ({ text: s, callback_data: `g|${s}|24h` });
  const rows: any[] = [];
  const chunk = (a: string[], pre?: string) => { for (let i = 0; i < a.length; i += 4) rows.push(a.slice(i, i + 4).map((s) => ({ ...btn(s), text: (pre ?? "") + s }))); };
  chunk(mine, "👜 "); chunk(top);
  const text = "📈 <b>Grafiğini görmek istediğin coini seç</b>" + (mine.length ? "\n👜 = pozisyonun olan coinler" : "") + "\n\nListede yoksa sembolünü yaz (ör. <code>PEPE</code>) ya da <code>/grafik PEPE</code>.";
  if (editMsg) await tg("deleteMessage", { chat_id: chat, message_id: editMsg });
  await tg("sendMessage", { chat_id: chat, text, parse_mode: "HTML", reply_markup: { inline_keyboard: rows } });
}

async function coinInfo(chat: number, sym: string) {
  const { data: c } = await sb.rpc("tgn_coin", { p_chat: chat, p_sym: sym, p_hours: 24 });
  if (!c) { await send(chat, "Coin bulunamadı."); return; }
  const t = await techFor(c, null);
  const ch24 = c.open_24h > 0 ? (c.price / c.open_24h - 1) * 100 : 0;
  const L: string[] = [`ℹ️ <b>${escH(c.name)} (${escH(c.symbol)})</b>`];
  const tags = [c.custom ? "COINFORCE coini" : c.dex_chain ? `DEX · ${escH(c.dex_chain)}` : "Spot", c.category ? escH(c.category) : ""].filter(Boolean).join(" · ");
  if (tags) L.push(`<i>${tags}</i>`);
  if (c.about) L.push("", escH(String(c.about).replace(/\s+/g, " ").trim()).slice(0, 600) + (String(c.about).length > 600 ? "…" : ""));
  L.push("", "<b>Piyasa verileri</b>", `Fiyat: ${fmtUsd(c.price)} (${ch24 >= 0 ? "+" : ""}${ch24.toFixed(2)}% 24S)`);
  if (c.high_24h > 0 && c.low_24h > 0) L.push(`24S aralık: ${fmtUsd(c.low_24h)} – ${fmtUsd(c.high_24h)}`);
  if (c.market_cap > 0) L.push(`Piyasa değeri: ${fmtBig(c.market_cap)}${c.rank ? ` (#${c.rank} COINFORCE'ta)` : ""}`);
  if (c.volume_24h > 0) L.push(`24S hacim: ${fmtBig(c.volume_24h)}${c.market_cap > 0 ? ` · hacim/piyasa değeri %${(c.volume_24h / c.market_cap * 100).toFixed(1)}` : ""}`);
  if (c.dex_liquidity > 0) L.push(`Likidite: ${fmtBig(c.dex_liquidity)}`);
  if (c.supply > 0) L.push(`Dolaşımdaki arz: ${Number(c.supply).toLocaleString("en-US", { maximumFractionDigits: 0 })} ${escH(c.symbol)}`);
  if (c.ath > 0) L.push(`Tüm zamanların zirvesi: ${fmtUsd(c.ath)} (zirveden ${((c.price / c.ath - 1) * 100).toFixed(1)}%)`);
  if (c.holding) L.push("", `👜 Pozisyonun: ${Number(c.holding.qty).toLocaleString("en-US", { maximumFractionDigits: 6 })} ${escH(c.symbol)} · ${fmtUsd(c.holding.value)} (${c.holding.pnl >= 0 ? "+" : "-"}${fmtUsd(Math.abs(c.holding.pnl))})`);
  if (t) {
    L.push("", `📊 <b>Teknik görünüm (${t.per}): ${techIcon(t.label)} ${t.label}</b>`, techBar(t), `Al ${t.buy} (%${t.pb}) · Nötr ${t.neu} (%${t.pn}) · Sat ${t.sell} (%${t.ps})`, "");
    for (const r of t.rows) L.push(`${r.s === "Al" ? "🟢" : r.s === "Sat" ? "🔴" : "⚪"} ${r.name}: ${r.value} → <b>${r.s}</b>`);
  } else L.push("", "📊 Teknik görünüm için yeterli fiyat geçmişi yok.");
  L.push("", "<i>Göstergeler geçmiş fiyat hareketinden otomatik hesaplanır; yatırım tavsiyesi değildir. Kripto paralar çok oynaktır, kararını kendin ver.</i>");
  await tg("sendMessage", { chat_id: chat, text: L.join("\n").slice(0, 4000), parse_mode: "HTML", disable_web_page_preview: true, reply_markup: keyboard([c.symbol]) });
}

async function onCallback(q: Record<string, any>) {
  const chat: number | undefined = q?.message?.chat?.id, mid: number | undefined = q?.message?.message_id;
  const d = String(q?.data ?? "");
  if (!chat) return;
  if (d === "l") { await tg("answerCallbackQuery", { callback_query_id: q.id }); await coinList(chat); return; }
  const im = d.match(/^i\|([A-Z0-9]{1,20})$/);
  if (im) { await tg("answerCallbackQuery", { callback_query_id: q.id }); await coinInfo(chat, im[1]); return; }
  const m = d.match(/^g\|([A-Z0-9]{1,20})\|(1h|24h|7d)(\|\d+)?$/);
  if (!m) { await tg("answerCallbackQuery", { callback_query_id: q.id }); return; }
  await tg("answerCallbackQuery", { callback_query_id: q.id, text: `${m[1]} · ${RLABEL[m[2] as Range]} yükleniyor…` });
  const isPhoto = Array.isArray(q?.message?.photo);
  await showChart(chat, m[1], m[2] as Range, isPhoto ? mid : undefined);
}

const HELP = [
  "<b>COINFORCE bildirim botu</b>",
  "",
  "Bu bot hesabındaki gelişmeleri sana haber verir:",
  "• Fiyat alarmları ve uygulama bildirimleri",
  "• Günlük kar/zarar özeti",
  "• Kripto haberleri (isteğe bağlı)",
  "• Coin grafikleri: /grafik ya da sadece sembol yaz (ör. BTC)",
  "",
  "Mesajlardaki 🟢 Al / 🔴 Sat butonları COINFORCE'u o coinin işlem ekranında açar.",
  "",
  "Bağlamak için uygulamada <b>Ayarlar › Telegram bildirimleri</b> bölümündeki butona dokun.",
  "",
  "/grafik — coin seç, grafik + bilgi + teknik görünüm",
  "/bilgi BTC — coin hakkında detaylı bilgi",
  "/ozet — anlık hesap özeti",
  "/dur — bildirimleri kapat (bağlantıyı kaldırır)",
].join("\n");

const json = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json" } });

async function onMessage(msg: Record<string, any>) {
  const chat: number | undefined = msg?.chat?.id;
  const text: string = (msg?.text ?? "").trim();
  if (!chat || !text) return;
  const [cmdRaw, ...rest] = text.split(/\s+/);
  const cmd = cmdRaw.toLowerCase().replace(/@.*$/, "");
  const arg = rest.join(" ");

  if (cmd === "/start" && arg) {
    const { data, error } = await sb.rpc("tgn_link", { p_chat: chat, p_code: arg });
    if (error || !data) {
      await send(chat, "Kod geçersiz ya da süresi dolmuş. Uygulamadan yeni bir bağlantı oluştur.");
      return;
    }
    await send(chat, `✅ Bağlandı: <b>@${String(data.username ?? "").replace(/[<>&]/g, "")}</b>\nArtık bildirimlerin buraya gelecek.\n\n/ozet — hesap özeti\n/dur — bildirimleri kapat`);
    return;
  }
  if (cmd === "/ozet" || cmd === "/özet" || cmd === "/durum") {
    const { data } = await sb.rpc("tgn_summary2", { p_chat: chat });
    if (data?.text) await send(chat, String(data.text), data.syms);
    else await send(chat, "Bu sohbet bir hesaba bağlı değil. Uygulamadan bağlayabilirsin.");
    return;
  }
  if (cmd === "/dur" || cmd === "/stop") {
    const { data } = await sb.rpc("tgn_unlink", { p_chat: chat });
    await send(chat, data ? "🔕 Bildirimler kapatıldı. İstediğin zaman uygulamadan tekrar bağlayabilirsin." : "Bu sohbet zaten bir hesaba bağlı değil.");
    return;
  }
  if (cmd === "/grafik" || cmd === "/coin" || cmd === "/coinler" || cmd === "/chart") {
    if (arg) {
      const [sym, r] = arg.split(/\s+/);
      const rr = ({ "1s": "1h", "1h": "1h", "24s": "24h", "24h": "24h", "7g": "7d", "7d": "7d" } as Record<string, Range>)[(r ?? "").toLowerCase()] ?? "24h";
      await showChart(chat, sym, rr);
    } else await coinList(chat);
    return;
  }
  if ((cmd === "/bilgi" || cmd === "/info") && arg) { await coinInfo(chat, arg.split(/\s+/)[0]); return; }
  if (!text.startsWith("/") && /^\$?[A-Za-z0-9]{2,20}$/.test(text)) {
    await showChart(chat, text.replace(/^\$/, ""), "24h");
    return;
  }
  await send(chat, HELP);
}

async function flush() {
  let sent = 0;
  for (let round = 0; round < 4; round++) {
    const { data, error } = await sb.rpc("tgn_outbox_take", { p_limit: 25 });
    if (error || !Array.isArray(data) || !data.length) break;
    const done: number[] = [];
    for (const m of data as { id: number; chat_id: number; body: string; syms: string[] | null }[]) {
      const r = await send(m.chat_id, m.body, m.syms);
      // 403: kullanıcı botu engelledi → tekrar deneme
      if (r?.ok || r?.error_code === 403 || r?.error_code === 400) done.push(m.id);
      if (r?.ok) sent++;
    }
    if (done.length) await sb.rpc("tgn_outbox_done", { p_ids: done });
    if (data.length < 25) break;
  }
  return sent;
}

Deno.serve(async (req) => {
  if (!TOKEN) return json({ error: "TELEGRAM_BOT_TOKEN tanımlı değil" }, 500);
  const url = new URL(req.url);

  if (url.searchParams.has("setup")) {
    const hook = `${Deno.env.get("SUPABASE_URL")}/functions/v1/telegram-notify`;
    const params = { url: hook, secret_token: await hookSecret(), allowed_updates: ["message", "callback_query"], drop_pending_updates: true };
    let set = await tg("setWebhook", params);
    if (!set?.ok && set?.parameters?.retry_after) {
      await new Promise((r) => setTimeout(r, Math.min(5, set.parameters.retry_after) * 1000 + 300));
      set = await tg("setWebhook", params);
    }
    const info = await tg("getWebhookInfo", {});
    const me = await tg("getMe", {});
    if (me?.ok && me.result?.username) await sb.rpc("tgn_set_bot", { p_username: me.result.username });
    await tg("setMyCommands", {
      commands: [
        { command: "grafik", description: "Coin grafiği" },
        { command: "bilgi", description: "Coin bilgisi (ör. /bilgi BTC)" },
        { command: "ozet", description: "Hesap özeti" },
        { command: "dur", description: "Bildirimleri kapat" },
      ],
    });
    const w = info?.result ?? {};
    const ok = set?.ok === true || (w.url === hook && (w.allowed_updates ?? []).includes("callback_query"));
    return json({ webhook: ok, bot: me?.result?.username ?? null, ...(ok ? {} : { error: set?.description ?? null }), updates: w.allowed_updates ?? null });
  }

  if (url.searchParams.has("run")) return json({ sent: await flush() });
  if (url.searchParams.has("preview")) {
    const r = (url.searchParams.get("r") ?? "24h") as Range;
    const { data: c } = await sb.rpc("tgn_coin", { p_chat: 0, p_sym: url.searchParams.get("preview") ?? "BTC", p_hours: RHOURS[r] ?? 24 });
    if (!c) return json({ found: false });
    const pts = await series(c, RANGES.includes(r) ? r : "24h");
    const t = await techFor(c, r === "24h" ? pts : null);
    const png = await renderChart(c, RANGES.includes(r) ? r : "24h", pts);
    if (url.searchParams.has("img") && png) {
      const b = new Uint8Array(await png.arrayBuffer()); let bin = ""; for (let i = 0; i < b.length; i++) bin += String.fromCharCode(b[i]);
      return new Response(btoa(bin), { headers: { "content-type": "text/plain" } });
    }
    return json({ found: true, points: pts.length, png: png ? png.size : 0, caption: caption(c, RANGES.includes(r) ? r : "24h", pts, t), tech: t });
  }

  if (req.method === "POST") {
    if (req.headers.get("x-telegram-bot-api-secret-token") !== (await hookSecret())) return json({ ok: false }, 401);
    const upd = await req.json().catch(() => null);
    if (upd?.message) await onMessage(upd.message).catch(() => {});
    else if (upd?.callback_query) await onCallback(upd.callback_query).catch(() => {});
    return json({ ok: true });
  }
  return json({ ok: true });
});
