// member-token.js - who is asking, proved by Ghost's signature rather than claimed in a request body.
//
// WHY (2026-09-18, code review). /alert looked up the email the CALLER TYPED and answered 200 for a paying
// member and 403 for anyone else, so a stranger could test a list of emails and learn who pays, and could
// switch alerts on for someone else's inbox. /planner-data.json was a public file carrying every recipe's
// cost and ingredient amounts. Both now require the signed-in member's own identity token.
//
// THE TOKEN. On thriftycrew.com a signed-in member's browser can GET /members/api/session (same origin) and
// receive a short-lived JWT that Ghost signs with the site's members key. The public half of that key is
// published at /members/.well-known/jwks.json (checked live 2026-09-18: one RSA key, 200; the session route
// answers 204 to a visitor who is not signed in). The token's subject is the member's email.
//
// WHAT THIS PROVES AND WHAT IT DOES NOT. A valid token proves the caller holds that member's session right
// now. It does NOT say the member pays: the caller still checks status with the Admin API. Every failure
// returns null and never a reason, so no response can distinguish "no such member" from "bad token".

export const SITE = "https://www.thriftycrew.com";
const JWKS_URL = SITE + "/members/.well-known/jwks.json";
const JWKS_TTL_MS = 10 * 60 * 1000;   // first value; Ghost rotates members keys rarely, and an unknown kid refetches
const SKEW_S = 60;                      // clock skew allowed on exp and nbf. First value.

let jwksCache = { at: 0, keys: [] };

function b64urlToBytes(s) {
  const pad = s.length % 4 === 2 ? "==" : s.length % 4 === 3 ? "=" : "";
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function decodePart(s) {
  return JSON.parse(new TextDecoder().decode(b64urlToBytes(s)));
}

async function loadKeys(fetchJwks, force) {
  const now = Date.now();
  if (!force && jwksCache.keys.length && now - jwksCache.at < JWKS_TTL_MS) return jwksCache.keys;
  const doc = await fetchJwks();
  jwksCache = { at: now, keys: (doc && doc.keys) || [] };
  return jwksCache.keys;
}

async function defaultFetchJwks() {
  const r = await fetch(JWKS_URL, { cf: { cacheTtl: 600 } });
  if (!r.ok) throw new Error("jwks " + r.status);
  return r.json();
}

// Returns the member's email (lower-cased) when the token is genuine and current, else null.
// opts.fetchJwks and opts.now exist for the self-test; production passes neither.
export async function verifyMemberToken(token, opts = {}) {
  try {
    if (typeof token !== "string") return null;
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    const header = decodePart(parts[0]);
    const claims = decodePart(parts[1]);
    // RS512 only. Accepting the algorithm the token names is the classic hole: "none" or an HMAC keyed
    // with the public key would then verify anything.
    if (header.alg !== "RS512") return null;
    const fetchJwks = opts.fetchJwks || defaultFetchJwks;
    let keys = await loadKeys(fetchJwks, false);
    let jwk = keys.find((k) => k.kid === header.kid);
    if (!jwk) { keys = await loadKeys(fetchJwks, true); jwk = keys.find((k) => k.kid === header.kid); }
    if (!jwk || jwk.kty !== "RSA") return null;
    const key = await crypto.subtle.importKey(
      "jwk", { kty: "RSA", n: jwk.n, e: jwk.e, alg: "RS512", ext: true },
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-512" }, false, ["verify"]);
    const ok = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5", key, b64urlToBytes(parts[2]),
      new TextEncoder().encode(parts[0] + "." + parts[1]));
    if (!ok) return null;
    const now = Math.floor((opts.now || Date.now()) / 1000);
    if (typeof claims.exp !== "number" || claims.exp + SKEW_S < now) return null;
    if (typeof claims.nbf === "number" && claims.nbf - SKEW_S > now) return null;
    // Issuer is this site's members API. Accept the apex and www spellings of our own site only.
    const iss = String(claims.iss || "");
    if (!/^https:\/\/(www\.)?thriftycrew\.com\/members\/api\/?$/.test(iss)) return null;
    const email = String(claims.sub || "").trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email) || email.length > 200) return null;
    return email;
  } catch (e) {
    return null;
  }
}

export function bearer(request) {
  const h = request.headers.get("Authorization") || "";
  const m = /^Bearer\s+(\S+)$/.exec(h);
  return m ? m[1] : null;
}

export function _resetKeyCacheForTest() { jwksCache = { at: 0, keys: [] }; }
