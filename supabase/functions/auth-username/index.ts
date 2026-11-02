// COINFORCE kullanıcı adıyla giriş.
// Uygulama, kullanıcı adı + şifreyi buraya gönderir; şifre veritabanında doğrulanır ve yalnızca doğruysa
// e-posta adresi döner (sonra uygulama normal Supabase Auth girişini yapar).
// Hız sınırı veritabanında: kullanıcı adı başına 15 dakikada 5, IP başına 20 hatalı deneme.
// Eski email_for_login RPC'si anonim kullanıcılara kapatıldı; bu fonksiyon onun yerini alır.
import { createClient } from "jsr:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};
const json = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "content-type": "application/json" } });

// Cloudflare'in yazdığı başlık istemci tarafından değiştirilemez; yoksa ilk yönlendirme adresi kullanılır.
function clientIp(req: Request): string {
  const v = req.headers.get("cf-connecting-ip") ?? req.headers.get("x-real-ip") ??
    (req.headers.get("x-forwarded-for") ?? "").split(",")[0];
  return (v ?? "").trim().slice(0, 64) || "unknown";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  let body: Record<string, unknown> | null = null;
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }
  const ident = typeof body?.ident === "string" ? body.ident.trim().slice(0, 64) : "";
  const pw = typeof body?.pw === "string" ? body.pw : "";
  if (!ident || !pw || pw.length > 200) return json({ email: null });

  const { data, error } = await sb.rpc("auth_username_login", { p_ident: ident, p_pw: pw, p_ip: clientIp(req) });
  if (error) return json({ error: "server_error" }, 500);
  if (data?.locked) return json({ email: null, locked: true, retry_after: data.retry_after ?? 900 }, 429);
  return json({ email: data?.email ?? null });
});
