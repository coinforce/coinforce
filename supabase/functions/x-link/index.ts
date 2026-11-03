// COINFORCE — X (Twitter) hesabını bağlama: OAuth 2.0 Authorization Code + PKCE (gizli istemci).
// Supabase > Edge Functions > "x-link" (Verify JWT: KAPALI — X'ten dönüş isteğinde JWT olmaz; başlatma isteği JWT'yi kendisi doğrular).
// Gerekli Secrets: X_CLIENT_ID, X_CLIENT_SECRET (X Developer Console > uygulama > User authentication: OAuth 2.0, tür: Web App).
// X uygulamasındaki Callback URL: https://<proje>.supabase.co/functions/v1/x-link
// İsteğe bağlı: APP_URL (varsayılan https://coinforce.github.io/coinforce/). Secrets yoksa başlatma "not_configured" döner.
// Akış: uygulama POST {action:"start"} (kullanıcı JWT'si) → X yetkilendirme adresi → kullanıcı X'te onaylar →
//       X bu fonksiyona ?code&state ile döner → kod X'te değiştirilir, /2/users/me ile hesap doğrulanır → uygulamaya ?xlink=sonuç.
// Güvenlik: durum tek kullanımlık ve 10 dk geçerli; PKCE (S256); yönlendirme yalnızca APP_URL'e; X erişim belirteci saklanmaz,
//           kullanımdan hemen sonra iptal edilir; bir X hesabı yalnızca bir COINFORCE hesabına bağlanır (x_link_finish).
import { createClient } from "jsr:@supabase/supabase-js@2";
import { cfg } from "./config.ts";

const SB_URL = Deno.env.get("SUPABASE_URL") ?? "", SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SELF = `${SB_URL}/functions/v1/x-link`;
const APP = cfg("APP_URL") || "https://coinforce.github.io/coinforce/";
const AUTH_URL = cfg("X_AUTH_URL") || "https://x.com/i/oauth2/authorize";
const API = (cfg("X_API_URL") || "https://api.x.com").replace(/\/$/, "");
const sb = createClient(SB_URL, SERVICE, { auth: { persistSession: false } });

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
  "access-control-allow-methods": "GET, POST, OPTIONS",
};
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "content-type": "application/json" } });
const back = (r: string) =>
  new Response(null, { status: 302, headers: { location: APP + (APP.includes("?") ? "&" : "?") + "xlink=" + r, "cache-control": "no-store", "referrer-policy": "no-referrer" } });
const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const rnd = (n: number) => b64u(crypto.getRandomValues(new Uint8Array(n)));
const sha = async (s: string) => b64u(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))));
const configured = () => !!(cfg("X_CLIENT_ID") && cfg("X_CLIENT_SECRET"));
const basic = () => "Basic " + btoa(`${encodeURIComponent(cfg("X_CLIENT_ID"))}:${encodeURIComponent(cfg("X_CLIENT_SECRET"))}`);
const form = (o: Record<string, string>) => ({ "content-type": "application/x-www-form-urlencoded", authorization: basic(), body: new URLSearchParams(o) });

async function start(req: Request) {
  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ ok: false, error: "auth" }, 401);
  const { data, error } = await sb.auth.getUser(jwt);
  if (error || !data?.user) return json({ ok: false, error: "auth" }, 401);
  if (!configured()) return json({ ok: false, error: "not_configured" });
  const state = rnd(32), verifier = rnd(48);
  const r = await sb.rpc("x_oauth_begin", { p_user: data.user.id, p_state: state, p_verifier: verifier });
  if (r.error) return json({ ok: false, error: /too_many/.test(r.error.message) ? "too_many" : "failed" });
  const q = new URLSearchParams({
    response_type: "code", client_id: cfg("X_CLIENT_ID"), redirect_uri: SELF, scope: "users.read tweet.read",
    state, code_challenge: await sha(verifier), code_challenge_method: "S256",
  });
  return json({ ok: true, url: `${AUTH_URL}?${q}` });
}

async function callback(u: URL) {
  const state = u.searchParams.get("state") ?? "", code = u.searchParams.get("code") ?? "", err = u.searchParams.get("error") ?? "";
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(state)) return back("err");
  const t = await sb.rpc("x_oauth_take", { p_state: state });
  const st = t.data as { user_id: string; verifier: string } | null;
  if (t.error || !st) return back("expired");
  if (err) return back(err === "access_denied" ? "denied" : "err");
  if (!code || code.length > 2048 || !configured()) return back("err");

  const tk = form({ grant_type: "authorization_code", code, redirect_uri: SELF, code_verifier: st.verifier });
  const tr = await fetch(`${API}/2/oauth2/token`, { method: "POST", signal: AbortSignal.timeout(10000), headers: { "content-type": tk["content-type"], authorization: tk.authorization }, body: tk.body }).catch(() => null);
  const tj = tr && tr.ok ? await tr.json().catch(() => null) : null;
  const at = typeof tj?.access_token === "string" ? tj.access_token : "";
  if (!at) return back("err");

  let me: { id?: unknown; username?: unknown; name?: unknown } | null = null;
  try {
    const mr = await fetch(`${API}/2/users/me?user.fields=name,username`, { signal: AbortSignal.timeout(10000), headers: { authorization: `Bearer ${at}` } });
    me = mr.ok ? ((await mr.json().catch(() => null))?.data ?? null) : null;
  } catch { me = null; }
  // Belirteç bir daha kullanılmayacak: hemen iptal et (saklanmaz)
  const rv = form({ token: at, token_type_hint: "access_token" });
  await fetch(`${API}/2/oauth2/revoke`, { method: "POST", signal: AbortSignal.timeout(5000), headers: { "content-type": rv["content-type"], authorization: rv.authorization }, body: rv.body }).catch(() => null);

  const id = String(me?.id ?? ""), un = String(me?.username ?? ""), nm = String(me?.name ?? "").slice(0, 60);
  if (!/^[0-9]{1,20}$/.test(id) || !/^[A-Za-z0-9_]{1,15}$/.test(un)) return back("err");
  const f = await sb.rpc("x_link_finish", { p_user: st.user_id, p_id: id, p_username: un, p_name: nm });
  if (f.error) return back("err");
  return back(f.data === "ok" ? "ok" : f.data === "taken" ? "taken" : "err");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const u = new URL(req.url);
  try {
    if (req.method === "POST") {
      const b = await req.json().catch(() => null);
      return b && b.action === "start" ? await start(req) : json({ ok: false, error: "bad_request" }, 400);
    }
    if (req.method === "GET" && (u.searchParams.has("state") || u.searchParams.has("code") || u.searchParams.has("error"))) return await callback(u);
    return json({ ok: true, configured: configured() });
  } catch {
    return req.method === "GET" ? back("err") : json({ ok: false, error: "failed" }, 500);
  }
});
