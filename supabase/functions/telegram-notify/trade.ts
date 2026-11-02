// Telegram işlem terminali: komutlar, butonlar, sohbet içi girdi ve emir yürütme.
// Yetki her zaman sunucuda: kullanıcı hesabı doğrulanmış Telegram bağlantısından (from.id) bulunur;
// emirler tgx_order üzerinden mevcut motor fonksiyonlarıyla, onay beklemeden yürütülür.
// deno-lint-ignore-file no-explicit-any
import { commandName, esc, parseAmount, parseFutArgs, parseNum, parseSpotArgs, parseSymbol, type Amount } from "./fmt.ts";
import { answerCb, editOrSend, type Keyboard, sendText } from "./tg.ts";
import * as ui from "./ui.ts";
import { chartCallback, coinInfo, coinList, send as sendWithLinks, showChart } from "./charts.ts";

let sb: any;
export function initTrade(client: any) { sb = client; }

export type Ctx = {
  chat: number; tg: number; update: number; me: ui.Me; tgName?: string;
  msgId?: number; sentAt?: number;                       // metin mesajı
  cb?: { id: string; msgId?: number; data: string };      // buton
};
type OrderReq = { kind: string; symbol?: string; side?: string; amount?: number; qty?: number; price?: number; leverage?: number; ref?: string; pct?: number };

const ORDER_TTL_MS = 120_000; // gecikmeli ulaşan emir komutu işlenmez
const trunc = (v: number, d: number) => Math.floor(v * 10 ** d + 1e-9) / 10 ** d;

async function rpc(fn: string, args: Record<string, unknown>) {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
}
export async function audit(ctx: { tg?: number; update?: number }, event: string, detail?: Record<string, unknown>) {
  try { await sb.rpc("tgx_audit_event", { p_tg_user: ctx.tg ?? null, p_update: ctx.update ?? null, p_event: event, p_detail: detail ?? null }); } catch { /* audit asla akışı bozmaz */ }
}
const balanceOf = (ctx: Ctx) => rpc("tgx_balance", { p_tg_user: ctx.tg });
const priceOf = (sym: string) => rpc("tgx_price", { p_symbol: sym });
const setState = (ctx: Ctx, st: Record<string, unknown> | null) => rpc("tgx_state_set", { p_tg_user: ctx.tg, p_state: st });

// İşlem butonları (x:…) bağlantının oturum sürümüyle damgalanır. Bağlama, bağlantı kaldırma ve işlem izni
// değişikliği session_version'ı artırır; eski mesajlarda kalan işlem butonları böylece emir oluşturamaz.
export function stamp(kb: Keyboard | undefined, version: number | undefined): Keyboard | undefined {
  if (!kb) return kb;
  return {
    inline_keyboard: kb.inline_keyboard.map((row) => row.flatMap((btn) => {
      if (!btn.callback_data?.startsWith("x:")) return [btn];
      if (!version) return [];                                   // sürüm yoksa işlem butonu gösterilmez
      const data = `${btn.callback_data}:v${version}`;
      return data.length <= 64 ? [{ ...btn, callback_data: data }] : []; // Telegram sınırı 64 bayt
    })).filter((row) => row.length),
  };
}
/** x:…:v<sürüm> → { data: "x:…", version } ; sürüm damgası yoksa null */
export function unstamp(d: string): { data: string; version: number } | null {
  const m = d.match(/^(x:.+):v(\d{1,9})$/);
  return m ? { data: m[1], version: Number(m[2]) } : null;
}

function show(ctx: Ctx, s: ui.Screen) {
  const kb = stamp(s.kb, ctx.me?.linked ? ctx.me.session_version : undefined);
  return ctx.cb ? editOrSend(ctx.chat, ctx.cb.msgId, s.text, kb) : sendText(ctx.chat, s.text, kb);
}
const warn = (ctx: Ctx, text: string) => sendText(ctx.chat, `⚠️ ${text}`);

// ── Emir yürütme ─────────────────────────────────────────────────────────────────────────────
async function execOrder(ctx: Ctx, req: OrderReq, idem: string) {
  const args = {
    p_tg_user: ctx.tg, p_idem: idem, p_update: ctx.update, p_kind: req.kind, p_symbol: req.symbol ?? null, p_side: req.side ?? null,
    p_amount: req.amount ?? null, p_qty: req.qty ?? null, p_price: req.price ?? null, p_leverage: req.leverage ?? null,
    p_ref: req.ref ?? null, p_pct: req.pct ?? null,
  };
  let r: any = null;
  const { data, error } = await sb.rpc("tgx_order", args);
  if (!error) r = data;
  else {
    // Bağlantı kopması / zaman aşımı: emir işlenmiş olabilir. Yeniden göndermeden önce kaydı oku.
    const st = await sb.rpc("tgx_order_status", { p_tg_user: ctx.tg, p_idem: idem });
    if (st.data?.found) r = st.data;
    else {
      await audit(ctx, "order_error", { kind: req.kind, error: error.message });
      if (ctx.cb) await answerCb(ctx.cb.id, "Sonuç doğrulanamadı", true);
      return show(ctx, { text: "⚠️ Emrin sonucu doğrulanamadı. Tekrar göndermeden önce /orders ve /balance ile kontrol et.", kb: { inline_keyboard: [[{ text: "💰 Bakiye", callback_data: "b" }, { text: "📋 Emirler", callback_data: "o" }]] } });
    }
  }
  if (ctx.cb) await answerCb(ctx.cb.id, r?.ok ? (r?.duplicate ? "Bu buton zaten kullanıldı" : "✅ Gerçekleşti") : "❌ Reddedildi");
  return show(ctx, ui.orderResult(r));
}

/** Metin komutundan gelen emir: geç ulaşan komut işlenmez (önce eski sonucu arar). */
async function runCommandOrder(ctx: Ctx, req: OrderReq) {
  const idem = `m:${ctx.chat}:${ctx.msgId}`;
  if (ctx.sentAt && Date.now() - ctx.sentAt * 1000 > ORDER_TTL_MS) {
    const st = await sb.rpc("tgx_order_status", { p_tg_user: ctx.tg, p_idem: idem });
    if (st.data?.found) return show(ctx, ui.orderResult(st.data));
    await audit(ctx, "order_expired", { kind: req.kind, ms: Date.now() - ctx.sentAt * 1000 });
    return warn(ctx, `Komut ${Math.round((Date.now() - ctx.sentAt * 1000) / 1000)} sn gecikmeyle ulaştı; güvenlik için işlenmedi. Tekrar gönder.`);
  }
  return execOrder(ctx, req, idem);
}

// ── Emir isteği hazırlama ──────────────────────────────────────────────────────────────────────
type Built = OrderReq | { error: string };

async function buildSpot(ctx: Ctx, side: "buy" | "sell", sym: string, amt: Amount, type: "market" | "limit" | "stop", trig: number | null): Promise<Built> {
  if (type === "market") {
    if (side === "buy") {
      if (amt.kind === "usdt") return { kind: "spot_market", symbol: sym, side, amount: trunc(amt.value, 2) };
      if (amt.kind === "pct") { const bal = await balanceOf(ctx); return { kind: "spot_market", symbol: sym, side, amount: trunc(Number(bal.usdt) * amt.value / 100, 2) }; }
      return { error: "Alış tutarını USDT olarak yaz (ör. 100) ya da yüzde olarak (%25)." };
    }
    if (amt.kind === "qty") return { kind: "spot_market", symbol: sym, side, qty: trunc(amt.value, 8) };
    if (amt.kind === "pct") return { kind: "spot_market", symbol: sym, side, pct: amt.value };
    if (amt.kind === "all") return { kind: "spot_market", symbol: sym, side, pct: 100 };
    const p = await priceOf(sym);
    if (!p?.price) return { error: `${esc(sym)}/USDT işlem çifti bulunamadı.` };
    return { kind: "spot_market", symbol: sym, side, qty: trunc(amt.value / Number(p.price), 8) };
  }
  if (!trig || !(trig > 0)) return { error: "Emir fiyatını yaz (ör. limit 60000)." };
  const kind = type === "limit" ? "spot_limit" : "spot_stop";
  const factor = (type === "stop" ? 1.02 : 1) * 1.0008; // motorun alışta ayırdığı pay
  if (side === "buy") {
    if (amt.kind === "usdt") return { kind, symbol: sym, side, price: trig, qty: trunc(amt.value / trig, 8) };
    if (amt.kind === "pct") { const bal = await balanceOf(ctx); return { kind, symbol: sym, side, price: trig, qty: trunc(Number(bal.usdt) * amt.value / 100 / (trig * factor), 8) }; }
    return { error: "Alış tutarını USDT olarak yaz (ör. 100) ya da yüzde olarak (%25)." };
  }
  if (amt.kind === "qty") return { kind, symbol: sym, side, price: trig, qty: trunc(amt.value, 8) };
  if (amt.kind === "usdt") return { kind, symbol: sym, side, price: trig, qty: trunc(amt.value / trig, 8) };
  const bal = await balanceOf(ctx);
  const have = Number((bal.spot ?? []).find((h: any) => h.symbol === sym)?.qty ?? 0);
  const pctV = amt.kind === "all" ? 100 : amt.value;
  return { kind, symbol: sym, side, price: trig, qty: pctV >= 100 ? have : trunc(have * pctV / 100, 8) };
}

async function buildFut(ctx: Ctx, sym: string, side: "L" | "S", lev: number, amt: Amount): Promise<Built> {
  let margin: number;
  if (amt.kind === "usdt") margin = trunc(amt.value, 2);
  else if (amt.kind === "pct") {
    const bal = await balanceOf(ctx);
    // Komisyon da bakiyeden düşüldüğü için: teminat × (1 + kaldıraç × 0,0005) ≤ bakiye × oran
    margin = trunc(Number(bal.usdt) * amt.value / 100 / (1 + lev * 0.0005), 2);
  } else return { error: "Teminatı USDT olarak yaz (ör. 100) ya da yüzde olarak (%25)." };
  return { kind: "futures_open", symbol: sym, side: side === "L" ? "long" : "short", amount: margin, leverage: lev };
}

// ── Komutlar ────────────────────────────────────────────────────────────────────────────────
async function needLinked(ctx: Ctx) {
  if (ctx.me?.linked) return true;
  await show(ctx, ui.notLinked());
  return false;
}

async function mainMenu(ctx: Ctx) {
  if (!ctx.me.linked) return show(ctx, ui.notLinked());
  const bal = await balanceOf(ctx).catch(() => null);
  return show(ctx, ui.mainMenu(ctx.me, bal));
}

async function spotCommand(ctx: Ctx, side: "buy" | "sell", args: string[]) {
  if (!(await needLinked(ctx))) return;
  const a = parseSpotArgs(args, side);
  if (a.error) return warn(ctx, `${a.error}\nÖrnek: ${side === "buy" ? "/buy BTC 100 · /buy BTC 100 limit 60000" : "/sell BTC %50 · /sell BTC 0,01"}`);
  if (!a.symbol) {
    const pairs = await rpc("tgx_pairs", { p_tg_user: ctx.tg, p_limit: 12 });
    return show(ctx, ui.coinPicker("s", pairs, side === "buy" ? "🟢 <b>Hangi coini almak istiyorsun?</b>" : "🔴 <b>Hangi coini satmak istiyorsun?</b>", "Listede yoksa yaz: /buy PEPE 50"));
  }
  if (!a.amount) {
    const [p, bal] = await Promise.all([priceOf(a.symbol), balanceOf(ctx)]);
    if (!p) return warn(ctx, `${esc(a.symbol)}/USDT işlem çifti bulunamadı.`);
    if (!ctx.me.trading) return show(ctx, ui.spotCard(p, ctx.me, bal));
    const t = a.type === "limit" ? "l" : "t", sd = side === "buy" ? "b" : "s";
    if (a.type !== "market") return show(ctx, a.price ? ui.triggerAmounts(a.symbol, t, sd, a.price, bal) : ui.triggerPrices(a.symbol, t, sd, p));
    return show(ctx, side === "buy" ? ui.buyAmounts(a.symbol, bal) : ui.sellAmounts(a.symbol, bal));
  }
  const req = await buildSpot(ctx, side, a.symbol, a.amount, a.type, a.price);
  if ("error" in req) return warn(ctx, req.error);
  return runCommandOrder(ctx, req);
}

async function futCommand(ctx: Ctx, side: "L" | "S", args: string[]) {
  if (!(await needLinked(ctx))) return;
  const a = parseFutArgs(args);
  if (a.error) return warn(ctx, `${a.error}\nÖrnek: /${side === "L" ? "long" : "short"} BTC 100 10x`);
  if (!a.symbol) {
    const pairs = await rpc("tgx_pairs", { p_tg_user: ctx.tg, p_limit: 12 });
    return show(ctx, ui.coinPicker("f", pairs, "⚡ <b>Vadeli işlem için coin seç</b>", "Listede yoksa yaz: /long PEPE 50 5x"));
  }
  const p = await priceOf(a.symbol);
  if (!p) return warn(ctx, `${esc(a.symbol)}/USDT işlem çifti bulunamadı.`);
  if (!ctx.me.trading) { const [bal, ps] = await Promise.all([balanceOf(ctx), rpc("tgx_positions", { p_tg_user: ctx.tg })]); return show(ctx, ui.futCard(p, ctx.me, bal, ps.positions ?? [])); }
  if (!a.margin) {
    if (a.leverage) return show(ctx, ui.margins(a.symbol, side, a.leverage, await balanceOf(ctx)));
    return show(ctx, ui.leverages(a.symbol, side, Number(p.max_leverage) || 1));
  }
  if (!a.leverage) {
    if (a.margin.kind !== "usdt") return warn(ctx, "Yüzdeyle teminat verirken kaldıracı da yaz (ör. /long BTC %25 10x).");
    return show(ctx, ui.leverages(a.symbol, side, Number(p.max_leverage) || 1, trunc(a.margin.value, 2)));
  }
  const req = await buildFut(ctx, a.symbol, side, a.leverage, a.margin);
  if ("error" in req) return warn(ctx, req.error);
  return runCommandOrder(ctx, req);
}

async function closeCommand(ctx: Ctx, args: string[]) {
  if (!(await needLinked(ctx))) return;
  // Kısmi kapama yok: "/close BTC %50" tamamını kapatmasın diye ek değer reddedilir.
  if (args.length > 1) return warn(ctx, `Kısmi kapama desteklenmiyor; pozisyon yalnızca tamamen kapatılabilir. Tamamını kapatmak için: /close ${esc(args[0])}`);
  const list = ((await rpc("tgx_positions", { p_tg_user: ctx.tg })).positions ?? []) as any[];
  if (args[0]) {
    const sym = parseSymbol(args[0]);
    if (!sym) return warn(ctx, `“${esc(args[0])}” geçerli bir sembol değil.`);
    const mine = list.filter((p) => p.symbol === sym);
    if (!mine.length) return warn(ctx, `Açık ${esc(sym)} pozisyonun yok.`);
    if (mine.length === 1) return runCommandOrder(ctx, { kind: "futures_close", ref: mine[0].id });
    return show(ctx, ui.positionsList(mine, !!ctx.me.trading));
  }
  return show(ctx, ui.positionsList(list, !!ctx.me.trading));
}

async function cancelCommand(ctx: Ctx, args: string[]) {
  if (!(await needLinked(ctx))) return;
  const list = ((await rpc("tgx_orders", { p_tg_user: ctx.tg })).orders ?? []) as any[];
  if (args[0]) {
    const sym = parseSymbol(args[0]);
    if (!sym) return warn(ctx, `“${esc(args[0])}” geçerli bir sembol değil.`);
    const mine = list.filter((o) => o.symbol === sym);
    if (!mine.length) return warn(ctx, `Açık ${esc(sym)} emrin yok.`);
    if (mine.length === 1) return runCommandOrder(ctx, { kind: "order_cancel", ref: mine[0].id });
    return show(ctx, ui.ordersList(mine, !!ctx.me.trading));
  }
  return show(ctx, ui.ordersList(list, !!ctx.me.trading));
}

async function priceCommand(ctx: Ctx, args: string[]) {
  if (args[0]) {
    const sym = parseSymbol(args[0]);
    const p = sym ? await priceOf(sym) : null;
    if (!p) return warn(ctx, `“${esc(args[0])}” bulunamadı.`);
    return show(ctx, ui.priceCard(p));
  }
  return show(ctx, ui.pricesList(await rpc("tgx_prices", { p_limit: 12 })));
}

// Toplu işlem: emirlerin hangi hesaplarda gerçekleşeceğini gösterir (hesaplar yalnızca uygulamadan eklenir).
async function accountsCommand(ctx: Ctx) {
  if (!(await needLinked(ctx))) return;
  return show(ctx, ui.accounts(await rpc("tgx_accounts", { p_tg_user: ctx.tg })));
}

// Hesapların 1s / 12s / 24s kâr-zararı (yalnızca okuma).
async function pnlCommand(ctx: Ctx) {
  if (!(await needLinked(ctx))) return;
  return show(ctx, ui.pnl(await rpc("tgx_pnl", { p_tg_user: ctx.tg })));
}

async function link(ctx: Ctx, code: string) {
  const r = await rpc("tgx_link", { p_tg_user: ctx.tg, p_chat: ctx.chat, p_chat_type: "private", p_tg_username: ctx.tgName ?? null, p_code: code, p_update: ctx.update });
  if (!r?.ok) return warn(ctx, esc(r?.error ?? "Bağlantı kurulamadı."));
  await sendText(ctx.chat, `✅ <b>Bağlandı:</b> @${esc(r.username)}\nBildirimlerin artık buraya gelecek.\n\n🔒 Telegram'dan işlem izni varsayılan olarak <b>kapalı</b>. Açmak için uygulamada Ayarlar › Telegram bildirimleri › Telegram ile işlem.`);
  ctx.me = await rpc("tgx_me", { p_tg_user: ctx.tg });
  return mainMenu(ctx);
}

async function unlink(ctx: Ctx) {
  const r = await rpc("tgx_unlink", { p_tg_user: ctx.tg, p_update: ctx.update });
  return show(ctx, { text: r?.ok ? "🔕 Bağlantı kaldırıldı. Bildirimler durdu ve işlem izni kapandı. Tekrar bağlamak için uygulamadan yeni kod al." : "Bu Telegram hesabı zaten bir COINFORCE hesabına bağlı değil." });
}

// ── Sohbet içi girdi (özel tutar / fiyat) ─────────────────────────────────────────────────────
const PROMPTS: Record<string, string> = {
  mb: "Kaç USDT'lik alım? (ör. 150 ya da %20)",
  ms: "Ne kadar satılsın? (ör. 0,01 · %50 · hepsi · 100usdt)",
  lpb: "Limit alış fiyatını yaz (güncel fiyatın altında):", lps: "Limit satış fiyatını yaz (güncel fiyatın üstünde):",
  tpb: "Stop alış fiyatını yaz (güncel fiyatın üstünde):", tps: "Stop satış fiyatını yaz (güncel fiyatın altında):",
  lb: "Kaç USDT'lik limit alış? (ör. 150 ya da %20)", tb: "Kaç USDT'lik stop alış? (ör. 150 ya da %20)",
  ls: "Ne kadar limit satış? (ör. 0,01 · %50 · hepsi)", ts: "Ne kadar stop satış? (ör. 0,01 · %50 · hepsi)",
  fo: "Teminat kaç USDT? (ör. 75 ya da %10)",
};

async function askInput(ctx: Ctx, parts: string[]) {
  const [act, sym, a, c] = parts;
  if (!PROMPTS[act] || !parseSymbol(sym ?? "")) return;
  const st: Record<string, unknown> = { await: "input", act, sym };
  if (["lb", "tb", "ls", "ts"].includes(act)) st.price = Number(a);
  if (act === "fo") { st.side = a; st.lev = Number(c); }
  await setState(ctx, st);
  return show(ctx, { text: `✏️ <b>${esc(sym)}</b> · ${PROMPTS[act]}\nVazgeçmek için “iptal” yaz.`, kb: { inline_keyboard: [[{ text: "Vazgeç", callback_data: "cx" }]] } });
}

async function handleInput(ctx: Ctx, text: string) {
  const st = ctx.me.state as any;
  await setState(ctx, null);
  if (/^(iptal|vazgeç|vazgec|cancel|dur)$/i.test(text.trim())) return sendText(ctx.chat, "Vazgeçildi.");
  const sym = String(st.sym);
  switch (st.act) {
    case "lpb": case "lps": case "tpb": case "tps": {
      const n = parseNum(text);
      if (!n.ok) return warn(ctx, n.error);
      return show(ctx, ui.triggerAmounts(sym, st.act[0] as "l" | "t", st.act[2] as "b" | "s", n.value, await balanceOf(ctx)));
    }
    case "fo": {
      const a = parseAmount(text, false);
      if (!a.ok) return warn(ctx, a.error);
      const req = await buildFut(ctx, sym, st.side === "S" ? "S" : "L", Number(st.lev), a.amount);
      if ("error" in req) return warn(ctx, req.error);
      return runCommandOrder(ctx, req);
    }
    default: {
      const sell = ["ms", "ls", "ts"].includes(st.act);
      const a = parseAmount(text, sell);
      if (!a.ok) return warn(ctx, a.error);
      let amt = a.amount;
      if (!sell && amt.kind === "qty") amt = { kind: "usdt", value: amt.value };
      if (!sell && amt.kind === "all") amt = { kind: "pct", value: 100 };
      const type = st.act[0] === "l" ? "limit" : st.act[0] === "t" ? "stop" : "market";
      const req = await buildSpot(ctx, sell ? "sell" : "buy", sym, amt, type, type === "market" ? null : Number(st.price));
      if ("error" in req) return warn(ctx, req.error);
      return runCommandOrder(ctx, req);
    }
  }
}

// ── Mesaj yönlendirme ─────────────────────────────────────────────────────────────────────────
export async function onMessage(ctx: Ctx, msg: any) {
  const text: string = String(msg?.text ?? "").trim();
  if (!text) return;
  if (msg.forward_origin || msg.forward_date || msg.via_bot) return; // iletilen mesajlardaki komutlar yürütülmez
  if (!text.startsWith("/")) {
    if (ctx.me?.linked && ctx.me.state?.act) return handleInput(ctx, text);
    if (/^[0-9.,%\s]+$/.test(text)) return sendText(ctx.chat, "Bekleyen bir işlem yok. Menüden ya da komutla devam et: /menu");
    if (/^\$?[A-Za-z0-9]{2,20}$/.test(text)) return showChart(ctx.chat, text.replace(/^\$/, ""), "24h");
    return ctx.me?.linked ? mainMenu(ctx) : show(ctx, ui.notLinked());
  }
  const { cmd, args } = commandName(text);
  if (ctx.me?.linked && ctx.me.state?.act) await setState(ctx, null); // yeni komut bekleyen girdiyi iptal eder
  switch (cmd) {
    case "start":
      if (args[0]) return link(ctx, args[0]);
      return mainMenu(ctx);
    case "menu": case "menü": case "m": return mainMenu(ctx);
    case "help": case "yardim": case "yardım": case "komutlar": return show(ctx, ui.help());
    case "balance": case "bakiye": case "wallet": case "cuzdan": case "cüzdan":
      if (!(await needLinked(ctx))) return;
      return show(ctx, ui.balance(await balanceOf(ctx)));
    case "accounts": case "hesaplar": return accountsCommand(ctx);
    case "pnl": case "kar": case "kâr": case "karzarar": return pnlCommand(ctx);
    case "buy": case "al": return spotCommand(ctx, "buy", args);
    case "sell": case "sat": return spotCommand(ctx, "sell", args);
    case "long": return futCommand(ctx, "L", args);
    case "short": return futCommand(ctx, "S", args);
    case "spot": return spotCommand(ctx, "buy", []);
    case "futures": case "vadeli": return futCommand(ctx, "L", []);
    case "positions": case "pozisyonlar": case "pozisyon": return closeCommand(ctx, []);
    case "close": case "kapat": return closeCommand(ctx, args);
    case "orders": case "emirler": return cancelCommand(ctx, []);
    case "cancel": case "iptal": return cancelCommand(ctx, args);
    case "price": case "fiyat": case "fiyatlar": return priceCommand(ctx, args);
    case "settings": case "ayarlar":
      if (!(await needLinked(ctx))) return;
      return show(ctx, ui.settings(ctx.me, ctx.tgName));
    case "unlink": case "dur": case "stop": return unlink(ctx);
    case "ozet": case "özet": case "durum": {
      const { data } = await sb.rpc("tgn_summary2", { p_chat: ctx.chat });
      if (data?.text) return sendWithLinks(ctx.chat, String(data.text), data.syms);
      return show(ctx, ui.notLinked());
    }
    case "grafik": case "coin": case "coinler": case "chart": {
      if (!args[0]) return coinList(ctx.chat);
      const rr = ({ "1s": "1h", "1h": "1h", "24s": "24h", "24h": "24h", "7g": "7d", "7d": "7d" } as Record<string, "1h" | "24h" | "7d">)[(args[1] ?? "").toLowerCase()] ?? "24h";
      return showChart(ctx.chat, args[0], rr);
    }
    case "bilgi": case "info": return args[0] ? coinInfo(ctx.chat, args[0]) : coinList(ctx.chat);
  }
  return sendText(ctx.chat, `Bilinmeyen komut: /${esc(cmd)}\n/help ile komutları gör.`);
}

// ── Buton yönlendirme ─────────────────────────────────────────────────────────────────────────
async function execCallback(ctx: Ctx, d: string) {
  const st = unstamp(d);
  if (!st || st.version !== Number(ctx.me.session_version)) {
    // Mesaj gönderildikten sonra bağlantı ya da işlem izni değişti: eski buton emir oluşturmaz.
    await audit(ctx, "button_stale", { reason: "session_changed", kind: d.split(":")[1] ?? "" });
    await answerCb(ctx.cb!.id, "Bu menü artık geçerli değil (bağlantı ya da işlem izni değişti). Güncel menü açıldı.", true);
    return mainMenu(ctx);
  }
  const p = st.data.split(":");
  const idem = `b:${ctx.chat}:${ctx.cb!.msgId ?? 0}:${d}`;
  const sym = parseSymbol(p[2] ?? "") ?? "";
  let req: Built | null = null;
  switch (p[1]) {
    case "mb": req = { kind: "spot_market", symbol: sym, side: "buy", amount: Number(p[3]) }; break;
    case "mbp": req = await buildSpot(ctx, "buy", sym, { kind: "pct", value: Number(p[3]) }, "market", null); break;
    case "msp": req = { kind: "spot_market", symbol: sym, side: "sell", pct: Number(p[3]) }; break;
    case "lb": case "tb": req = await buildSpot(ctx, "buy", sym, { kind: "usdt", value: Number(p[4]) }, p[1] === "lb" ? "limit" : "stop", Number(p[3])); break;
    case "lsp": case "tsp": req = await buildSpot(ctx, "sell", sym, { kind: "pct", value: Number(p[4]) }, p[1] === "lsp" ? "limit" : "stop", Number(p[3])); break;
    case "fo": req = { kind: "futures_open", symbol: sym, side: p[3] === "S" ? "short" : "long", leverage: Number(p[4]), amount: Number(p[5]) }; break;
    case "fop": req = await buildFut(ctx, sym, p[3] === "S" ? "S" : "L", Number(p[4]), { kind: "pct", value: Number(p[5]) }); break;
    case "fc": req = { kind: "futures_close", ref: p[2] }; break;
    case "oc": req = { kind: "order_cancel", ref: p[2] }; break;
  }
  if (!req) { await answerCb(ctx.cb!.id); return; }
  if ("error" in req) { await answerCb(ctx.cb!.id, req.error, true); return; }
  return execOrder(ctx, req, idem);
}

export async function onCallback(ctx: Ctx, q: any) {
  const d = String(q?.data ?? "");
  if (/^(g\||i\||l$)/.test(d)) return chartCallback(q);
  if (d.startsWith("x:")) {
    if (!ctx.me?.linked) { await answerCb(ctx.cb!.id); return show(ctx, ui.notLinked()); }
    return execCallback(ctx, d);
  }
  await answerCb(ctx.cb!.id);
  const [k, s1, s2, s3] = d.split(":");
  if (k === "px") return s1 ? priceCommand(ctx, [s1]) : priceCommand(ctx, []);
  if (k === "h") return show(ctx, ui.help());
  if (!ctx.me?.linked) return show(ctx, ui.notLinked());
  const sym = parseSymbol(s1 ?? "") ?? "";
  switch (k) {
    case "m": return mainMenu(ctx);
    case "b": return show(ctx, ui.balance(await balanceOf(ctx)));
    case "o": return cancelCommand(ctx, []);
    case "p": return closeCommand(ctx, []);
    case "st": return show(ctx, ui.settings(ctx.me, ctx.tgName));
    case "ac": return accountsCommand(ctx);
    case "pl": return pnlCommand(ctx);
    case "ul": return show(ctx, ui.unlinkConfirm());
    case "ul!": return unlink(ctx);
    case "cx": await setState(ctx, null); return show(ctx, { text: "Vazgeçildi." });
    case "s": case "f": {
      if (!sym) {
        const pairs = await rpc("tgx_pairs", { p_tg_user: ctx.tg, p_limit: 12 });
        return show(ctx, k === "s" ? ui.coinPicker("s", pairs, "📈 <b>Spot · coin seç</b>", "Listede yoksa yaz: /buy PEPE 50") : ui.coinPicker("f", pairs, "⚡ <b>Vadeli · coin seç</b>", "Listede yoksa yaz: /long PEPE 50 5x"));
      }
      const [p, bal] = await Promise.all([priceOf(sym), balanceOf(ctx)]);
      if (!p) return show(ctx, { text: `⚠️ ${esc(sym)}/USDT bulunamadı.` });
      if (k === "s") return show(ctx, ui.spotCard(p, ctx.me, bal));
      const ps = await rpc("tgx_positions", { p_tg_user: ctx.tg });
      return show(ctx, ui.futCard(p, ctx.me, bal, ps.positions ?? []));
    }
  }
  if (!ctx.me.trading) return show(ctx, { text: "🔒 Telegram'dan işlem izni kapalı. Uygulamada Ayarlar › Telegram bildirimleri › Telegram ile işlem seçeneğinden açabilirsin.", kb: { inline_keyboard: [[{ text: "🏠 Menü", callback_data: "m" }]] } });
  switch (k) {
    case "sb": return show(ctx, ui.buyAmounts(sym, await balanceOf(ctx)));
    case "ss": return show(ctx, ui.sellAmounts(sym, await balanceOf(ctx)));
    case "lb": case "ls": case "tb": case "ts": {
      const p = await priceOf(sym);
      if (!p) return show(ctx, { text: `⚠️ ${esc(sym)}/USDT bulunamadı.` });
      return show(ctx, ui.triggerPrices(sym, k[0] as "l" | "t", k[1] as "b" | "s", p));
    }
    case "lp": case "tp": return show(ctx, ui.triggerAmounts(sym, k[0] as "l" | "t", s2 as "b" | "s", Number(s3), await balanceOf(ctx)));
    case "fl": case "fs": {
      const p = await priceOf(sym);
      return show(ctx, ui.leverages(sym, k === "fl" ? "L" : "S", Number(p?.max_leverage) || 1));
    }
    case "fm": return show(ctx, ui.margins(sym, s2 === "S" ? "S" : "L", Number(s3), await balanceOf(ctx)));
    case "ci": return askInput(ctx, d.split(":").slice(1));
  }
  return show(ctx, { text: "Bu menünün süresi doldu.", kb: { inline_keyboard: [[{ text: "🏠 Menü", callback_data: "m" }]] } });
}
