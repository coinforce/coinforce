// STAGING ONLY — sahte Telegram Bot API. Production'a deploy edilmez.
// Botun Telegram'a yapacağı çağrıları (sendMessage, editMessageText, answerCallbackQuery ...) cf_test.tg_mock_calls'a
// kaydeder ve Telegram'ın vereceği türden başarılı cevap döner. Testler botun cevaplarını bu kayıttan okur.
// deno-lint-ignore-file no-explicit-any
import { createClient } from "jsr:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
let mid = Math.floor(Date.now() / 1000) % 1_000_000;

Deno.serve(async (req) => {
  const m = new URL(req.url).pathname.match(/\/bot[^/]+\/(\w+)$/);
  if (!m) return new Response(JSON.stringify({ ok: false, description: "Not Found" }), { status: 404, headers: { "content-type": "application/json" } });
  const body: Record<string, unknown> = {};
  const ct = req.headers.get("content-type") ?? "";
  if (ct.includes("application/json")) Object.assign(body, await req.json().catch(() => ({})));
  else if (ct.includes("multipart/form-data")) {
    const f = await req.formData();
    for (const [k, v] of f.entries()) body[k] = typeof v === "string" ? v : `<file ${(v as File).size}b>`;
  }
  await sb.rpc("tgmock_record", { p_method: m[1], p_body: body });
  const res: any = { ok: true, result: true };
  if (["sendMessage", "sendPhoto", "editMessageText", "editMessageMedia"].includes(m[1])) {
    res.result = { message_id: ++mid, chat: { id: Number(body.chat_id) || 0, type: "private" }, date: Math.floor(Date.now() / 1000), text: body.text ?? "" };
  }
  if (m[1] === "getMe") res.result = { id: 1, is_bot: true, first_name: "COINFORCE Staging", username: "coinforce_staging_bot" };
  if (m[1] === "getWebhookInfo") res.result = { url: "", allowed_updates: ["message", "callback_query"] };
  return new Response(JSON.stringify(res), { headers: { "content-type": "application/json" } });
});
