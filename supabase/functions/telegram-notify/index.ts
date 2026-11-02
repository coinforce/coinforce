// COINFORCE Telegram botu: bildirimler, grafikler ve işlem terminali (spot + vadeli).
// Gizli değer: TELEGRAM_BOT_TOKEN (Supabase > Edge Functions > Secrets).
// Webhook güvenliği: Telegram'ın gizli başlığı (token'dan türetilir), update_id tekrar kontrolü,
// yalnızca özel sohbet (chat.id = from.id), Telegram kullanıcı başına dakikada 60 güncelleme sınırı, audit log.
// Bakım uçları (?setup, ?run, ?preview) yalnızca x-cf-internal başlığıyla çalışır; değer Vault'taki
// tg_internal_secret'tır (veritabanındaki tgn_tick bu başlığı kendisi ekler).
import { createClient } from "jsr:@supabase/supabase-js@2";
import { initCharts, preview, send as sendWithLinks } from "./charts.ts";
import { answerCb, sendText, setApi, tg } from "./tg.ts";
import { audit, type Ctx, initTrade, onCallback, onMessage } from "./trade.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const sb = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
initCharts(sb);
initTrade(sb);

const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json" } });

// Yapılandırma: production'da token ortam değişkeninden, API api.telegram.org. Staging'de veritabanındaki
// tgx_config test token'ı ve sahte Telegram API adresini verebilir.
let TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
let ready: Promise<void> | null = null;
function init(): Promise<void> {
  if (!ready) {
    ready = (async () => {
      const { data } = await sb.rpc("tgx_config");
      if (!TOKEN && data?.test_token) TOKEN = String(data.test_token);
      setApi(data?.api_base ? String(data.api_base) : "https://api.telegram.org", TOKEN);
    })().catch(() => { setApi("https://api.telegram.org", TOKEN); });
  }
  return ready;
}

async function hookSecret(): Promise<string> {
  const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("cf-notify:" + TOKEN));
  return Array.from(new Uint8Array(h)).map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 48);
}
function safeEqual(a: string, b: string) {
  if (!a || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
let internalKey: string | null = null;
async function isInternal(req: Request): Promise<boolean> {
  const got = req.headers.get("x-cf-internal") ?? "";
  if (!got) return false;
  if (!internalKey) {
    const { data } = await sb.rpc("tgx_internal_secret");
    internalKey = typeof data === "string" && data.length >= 32 ? data : null;
  }
  return !!internalKey && safeEqual(got, internalKey);
}

// Arka planda bitirilebilecek işler (yanıt beklemesin). supabase-js sorgu nesneleri yalnızca "thenable"dır
// (.catch yoktur); Promise.resolve ile gerçek Promise'e çevrilir. Buradaki bir hata webhook yanıtını asla bozmaz.
function later(p: PromiseLike<unknown>) {
  const pr = Promise.resolve(p).catch(() => {});
  // deno-lint-ignore no-explicit-any
  const er = (globalThis as any).EdgeRuntime;
  if (er?.waitUntil) er.waitUntil(pr);
  return pr;
}

// Bildirim kuyruğunu gönderir (tgn_tick → ?run)
async function flush() {
  let sent = 0;
  for (let round = 0; round < 4; round++) {
    const { data, error } = await sb.rpc("tgn_outbox_take", { p_limit: 25 });
    if (error || !Array.isArray(data) || !data.length) break;
    const done: number[] = [];
    for (const m of data as { id: number; chat_id: number; body: string; syms: string[] | null }[]) {
      const r = await sendWithLinks(m.chat_id, m.body, m.syms);
      if (r?.ok || r?.error_code === 403 || r?.error_code === 400) done.push(m.id); // 403: kullanıcı botu engelledi
      if (r?.ok) sent++;
    }
    if (done.length) await sb.rpc("tgn_outbox_done", { p_ids: done });
    if (data.length < 25) break;
  }
  return sent;
}

const COMMANDS = [
  { command: "menu", description: "Ana menü" },
  { command: "balance", description: "Bakiye (/bakiye)" },
  { command: "buy", description: "Al: /buy BTC 100" },
  { command: "sell", description: "Sat: /sell BTC %50" },
  { command: "long", description: "Long: /long BTC 100 10x" },
  { command: "short", description: "Short: /short BTC 100 5x" },
  { command: "positions", description: "Açık pozisyonlar" },
  { command: "orders", description: "Açık emirler" },
  { command: "close", description: "Pozisyon kapat: /close BTC" },
  { command: "cancel", description: "Emir iptal et" },
  { command: "price", description: "Fiyat: /price BTC" },
  { command: "grafik", description: "Coin grafiği" },
  { command: "settings", description: "Ayarlar" },
  { command: "unlink", description: "Bağlantıyı kaldır" },
  { command: "help", description: "Yardım" },
];

async function setup() {
  const hook = `${SUPABASE_URL}/functions/v1/telegram-notify`;
  const params = { url: hook, secret_token: await hookSecret(), allowed_updates: ["message", "callback_query"], drop_pending_updates: true };
  let set = await tg("setWebhook", params);
  if (!set?.ok && set?.parameters?.retry_after) {
    await new Promise((r) => setTimeout(r, Math.min(5, set.parameters.retry_after) * 1000 + 300));
    set = await tg("setWebhook", params);
  }
  const info = await tg("getWebhookInfo", {});
  const me = await tg("getMe", {});
  if (me?.ok && me.result?.username) await sb.rpc("tgn_set_bot", { p_username: me.result.username });
  await tg("setMyCommands", { commands: COMMANDS });
  const w = info?.result ?? {};
  const ok = set?.ok === true || (w.url === hook && (w.allowed_updates ?? []).includes("callback_query"));
  return { webhook: ok, bot: me?.result?.username ?? null, ...(ok ? {} : { error: set?.description ?? null }), updates: w.allowed_updates ?? null };
}

// deno-lint-ignore no-explicit-any
async function handleUpdate(upd: any) {
  const msg = upd.message, cq = upd.callback_query;
  const from = msg?.from ?? cq?.from, chat = msg?.chat ?? cq?.message?.chat;
  if (!from || !chat || from.is_bot) return;
  const meta = { tg: from.id, update: upd.update_id };
  // Yalnızca botla özel sohbet: orada chat.id = from.id olur. Grup/kanal güncellemeleri işlem yapamaz.
  if (chat.type !== "private" || chat.id !== from.id) {
    later(audit(meta, "not_private", { chat_type: chat.type }));
    if (cq) await answerCb(cq.id, "Bu bot yalnızca özel sohbette çalışır.", true);
    else if (String(msg?.text ?? "").startsWith("/")) await sendText(chat.id, "🔒 COINFORCE botu yalnızca botla özel sohbette çalışır.");
    return;
  }
  const { data: begin, error } = await sb.rpc("tgx_begin", { p_update_id: upd.update_id, p_tg_user: from.id });
  if (error) throw new Error(`tgx_begin: ${error.message}`); // 500 → Telegram daha sonra tekrar dener
  if (begin?.seen === "dup") { if (cq) await answerCb(cq.id); return; }
  if (begin?.seen === "limited") {
    later(audit(meta, "rate_limited", { kind: cq ? "callback" : "message" }));
    if (cq) await answerCb(cq.id, "Çok hızlı istek gönderiyorsun; biraz bekle.", true);
    await sb.rpc("tgx_update_done", { p_update_id: upd.update_id });
    return;
  }
  const ctx: Ctx = { chat: chat.id, tg: from.id, update: upd.update_id, me: begin?.me ?? { linked: false }, tgName: from.username };
  try {
    if (msg) { ctx.msgId = msg.message_id; ctx.sentAt = msg.date; await onMessage(ctx, msg); }
    else { ctx.cb = { id: cq.id, msgId: cq.message?.message_id, data: String(cq.data ?? "") }; await onCallback(ctx, cq); }
  } catch (e) {
    await audit(meta, "error", { error: String((e as Error)?.message ?? e).slice(0, 300), kind: cq ? "callback" : "message" });
    if (cq) await answerCb(cq.id, "Bir hata oluştu", false);
    await sendText(chat.id, "⚠️ Bir hata oluştu. Lütfen tekrar dene; sorun sürerse /balance ile hesabını kontrol et.");
  } finally {
    later(sb.rpc("tgx_update_done", { p_update_id: upd.update_id }));
  }
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const maintenance = url.searchParams.has("setup") || url.searchParams.has("run") || url.searchParams.has("preview");
  if (maintenance && !(await isInternal(req))) return json({ ok: false }, 401);
  await init();
  if (!TOKEN) return json({ error: "TELEGRAM_BOT_TOKEN tanımlı değil" }, 500);

  if (url.searchParams.has("setup")) return json(await setup());
  if (url.searchParams.has("run")) return json({ sent: await flush() });
  if (url.searchParams.has("preview")) return await preview(url.searchParams.get("preview") ?? "BTC", url.searchParams.get("r") ?? "24h", url.searchParams.has("img"));

  if (req.method === "POST") {
    if (!safeEqual(req.headers.get("x-telegram-bot-api-secret-token") ?? "", await hookSecret())) return json({ ok: false }, 401);
    const upd = await req.json().catch(() => null);
    if (!upd || typeof upd.update_id !== "number") return json({ ok: true });
    try {
      await handleUpdate(upd);
    } catch {
      return json({ ok: false }, 500);
    }
    return json({ ok: true });
  }
  return json({ ok: true });
});
