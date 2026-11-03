// STAGING ONLY — sahte X OAuth 2.0 / API. Production'a deploy edilmez.
// x-link uçtan uca testi için: /authorize (kodu ve durumu geri yönlendirir), /2/oauth2/token (istemci kimliği, redirect_uri ve
// PKCE doğrulaması), /2/users/me, /2/oauth2/revoke. Test kontrolü: authorize adresine mock_user=id:kullanıcıadı:isim ya da mock_deny=1.
// deno-lint-ignore-file no-explicit-any
const CID = "test-client", SECRET = "test-secret";
const j = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json" } });
const enc = (s: string) => btoa(unescape(encodeURIComponent(s))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const dec = (s: string) => decodeURIComponent(escape(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4))));
const sha = async (s: string) =>
  btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

Deno.serve(async (req) => {
  const u = new URL(req.url), p = u.pathname.replace(/^.*?\/x-mock/, "") || "/";
  if (p === "/authorize") {
    const q = u.searchParams, ru = q.get("redirect_uri") ?? "", st = q.get("state") ?? "";
    if (q.get("response_type") !== "code" || q.get("client_id") !== CID || q.get("code_challenge_method") !== "S256" || !q.get("code_challenge") ||
      !st || !/^https:\/\//.test(ru) || !(q.get("scope") ?? "").split(" ").includes("users.read")) return j({ error: "invalid_request" }, 400);
    if (q.get("mock_deny")) return Response.redirect(`${ru}?error=access_denied&state=${encodeURIComponent(st)}`, 302);
    const [id, un, nm] = (q.get("mock_user") ?? "1001:mock_x:Mock User").split(":");
    const code = enc(JSON.stringify({ ch: q.get("code_challenge"), ru, id, un, nm: nm ?? "" }));
    return Response.redirect(`${ru}?code=${code}&state=${encodeURIComponent(st)}`, 302);
  }
  if (p === "/2/oauth2/token" && req.method === "POST") {
    if (req.headers.get("authorization") !== "Basic " + btoa(`${CID}:${SECRET}`)) return j({ error: "unauthorized_client" }, 401);
    const f = new URLSearchParams(await req.text());
    let c: any;
    try { c = JSON.parse(dec(f.get("code") ?? "")); } catch { return j({ error: "invalid_grant" }, 400); }
    if (f.get("grant_type") !== "authorization_code" || f.get("redirect_uri") !== c.ru) return j({ error: "invalid_request" }, 400);
    if ((await sha(f.get("code_verifier") ?? "")) !== c.ch) return j({ error: "invalid_grant", error_description: "PKCE" }, 400);
    return j({ token_type: "bearer", expires_in: 7200, scope: "users.read tweet.read", access_token: enc(JSON.stringify({ id: c.id, un: c.un, nm: c.nm })) });
  }
  if (p === "/2/users/me") {
    let d: any;
    try { d = JSON.parse(dec((req.headers.get("authorization") ?? "").replace(/^Bearer /, ""))); } catch { return j({ title: "Unauthorized" }, 401); }
    return j({ data: { id: d.id, username: d.un, name: d.nm } });
  }
  if (p === "/2/oauth2/revoke" && req.method === "POST") {
    if (req.headers.get("authorization") !== "Basic " + btoa(`${CID}:${SECRET}`)) return j({ error: "unauthorized_client" }, 401);
    return j({ revoked: true });
  }
  return j({ error: "not_found" }, 404);
});
