// COINFORCE Telegram bildirim botu — yalnızca bildirim gönderir, emir almaz.
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
const send = (chat: number, text: string) =>
  tg("sendMessage", { chat_id: chat, text, parse_mode: "HTML", disable_web_page_preview: true });

const HELP = [
  "<b>COINFORCE bildirim botu</b>",
  "",
  "Bu bot hesabındaki gelişmeleri sana haber verir:",
  "• Fiyat alarmları ve uygulama bildirimleri",
  "• Günlük kar/zarar özeti",
  "• Kripto haberleri (isteğe bağlı)",
  "",
  "Bağlamak için uygulamada <b>Ayarlar › Telegram bildirimleri</b> bölümündeki butona dokun.",
  "",
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
    const { data } = await sb.rpc("tgn_summary", { p_chat: chat });
    await send(chat, data ? String(data) : "Bu sohbet bir hesaba bağlı değil. Uygulamadan bağlayabilirsin.");
    return;
  }
  if (cmd === "/dur" || cmd === "/stop") {
    const { data } = await sb.rpc("tgn_unlink", { p_chat: chat });
    await send(chat, data ? "🔕 Bildirimler kapatıldı. İstediğin zaman uygulamadan tekrar bağlayabilirsin." : "Bu sohbet zaten bir hesaba bağlı değil.");
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
    for (const m of data as { id: number; chat_id: number; body: string }[]) {
      const r = await send(m.chat_id, m.body);
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
    const set = await tg("setWebhook", {
      url: hook,
      secret_token: await hookSecret(),
      allowed_updates: ["message"],
      drop_pending_updates: true,
    });
    const me = await tg("getMe", {});
    if (me?.ok && me.result?.username) await sb.rpc("tgn_set_bot", { p_username: me.result.username });
    await tg("setMyCommands", {
      commands: [
        { command: "ozet", description: "Hesap özeti" },
        { command: "dur", description: "Bildirimleri kapat" },
      ],
    });
    return json({ webhook: set?.ok === true, bot: me?.result?.username ?? null });
  }

  if (url.searchParams.has("run")) return json({ sent: await flush() });

  if (req.method === "POST") {
    if (req.headers.get("x-telegram-bot-api-secret-token") !== (await hookSecret())) return json({ ok: false }, 401);
    const upd = await req.json().catch(() => null);
    if (upd?.message) await onMessage(upd.message).catch(() => {});
    return json({ ok: true });
  }
  return json({ ok: true });
});
