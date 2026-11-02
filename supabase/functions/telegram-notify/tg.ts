// Telegram Bot API yardımcıları. API adresi ve token, ilk istekte index.ts tarafından ayarlanır.
export type Button = { text: string; callback_data?: string; url?: string };
export type Keyboard = { inline_keyboard: Button[][] };

let API = "";
export function setApi(base: string, token: string) {
  API = `${base.replace(/\/+$/, "")}/bot${token}`;
}

// deno-lint-ignore no-explicit-any
export async function tg(method: string, body: Record<string, unknown>): Promise<any> {
  try {
    const r = await fetch(`${API}/${method}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(10000),
    });
    return await r.json().catch(() => ({ ok: false }));
  } catch {
    return { ok: false };
  }
}

// deno-lint-ignore no-explicit-any
export async function tgForm(method: string, fields: Record<string, string>, file?: Blob): Promise<any> {
  const f = new FormData();
  for (const [k, v] of Object.entries(fields)) f.append(k, v);
  if (file) f.append("photo", file, "chart.png");
  try {
    const r = await fetch(`${API}/${method}`, { method: "POST", body: f, signal: AbortSignal.timeout(15000) });
    return await r.json().catch(() => ({ ok: false }));
  } catch {
    return { ok: false };
  }
}

export const sendText = (chat: number, text: string, kb?: Keyboard) =>
  tg("sendMessage", { chat_id: chat, text, parse_mode: "HTML", disable_web_page_preview: true, ...(kb ? { reply_markup: kb } : {}) });

/** Mesajı düzenler; düzenlenemezse (eski mesaj, fotoğraf vb.) yeni mesaj gönderir. */
export async function editOrSend(chat: number, messageId: number | undefined, text: string, kb?: Keyboard) {
  if (messageId) {
    const r = await tg("editMessageText", {
      chat_id: chat, message_id: messageId, text, parse_mode: "HTML", disable_web_page_preview: true,
      reply_markup: kb ?? { inline_keyboard: [] },
    });
    if (r?.ok || r?.description?.includes("message is not modified")) return r;
  }
  return sendText(chat, text, kb);
}

export const answerCb = (id: string, text?: string, alert = false) =>
  tg("answerCallbackQuery", { callback_query_id: id, ...(text ? { text: text.slice(0, 190), show_alert: alert } : {}) });
