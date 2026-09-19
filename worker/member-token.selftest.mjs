// member-token.selftest.mjs - frozen fixtures for worker/member-token.js. Hermetic: keys are generated here,
// nothing is fetched. Run through worker/test_member_token.py so run-gates discovers it.
import { verifyMemberToken, bearer, _resetKeyCacheForTest } from "./member-token.js";

const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const NOW = Date.UTC(2026, 8, 18, 12, 0, 0);
const nowS = Math.floor(NOW / 1000);

async function keypair() {
  return crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-512" },
    true, ["sign", "verify"]);
}
async function jwkOf(pub, kid) { const j = await crypto.subtle.exportKey("jwk", pub); return { kty: "RSA", n: j.n, e: j.e, kid }; }
async function sign(priv, header, claims) {
  const h = enc(header), c = enc(claims);
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", priv, new TextEncoder().encode(h + "." + c));
  return h + "." + c + "." + Buffer.from(sig).toString("base64url");
}

const good = { sub: "Member@Example.com", iss: "https://www.thriftycrew.com/members/api", exp: nowS + 600, iat: nowS };
const fails = [];
let n = 0;
async function check(label, got, want) {
  n++;
  if (got !== want) fails.push(label + " got=" + JSON.stringify(got) + " want=" + JSON.stringify(want));
}

const site = await keypair();
const other = await keypair();
let fetches = 0;
let jwks = { keys: [await jwkOf(site.publicKey, "k1")] };
const opts = { now: NOW, fetchJwks: async () => { fetches++; return jwks; } };
const H = { alg: "RS512", kid: "k1", typ: "JWT" };

_resetKeyCacheForTest();
await check("CLEAN TWIN a genuine current token yields the member's email, lower-cased",
  await verifyMemberToken(await sign(site.privateKey, H, good), opts), "member@example.com");
await check("MUST FIRE a token signed by some other key is refused",
  await verifyMemberToken(await sign(other.privateKey, H, good), opts), null);
const t = await sign(site.privateKey, H, good);
const [h0, , s0] = t.split(".");
await check("MUST FIRE a payload swapped to another email under the original signature is refused",
  await verifyMemberToken(h0 + "." + enc({ ...good, sub: "victim@example.com" }) + "." + s0, opts), null);
await check("MUST FIRE alg none with no signature is refused",
  await verifyMemberToken(enc({ alg: "none", kid: "k1" }) + "." + enc(good) + ".", opts), null);
await check("MUST FIRE an HS512 header is refused whatever it carries",
  await verifyMemberToken(enc({ alg: "HS512", kid: "k1" }) + "." + enc(good) + "." + s0, opts), null);
await check("MUST FIRE a genuine signature under a header naming another algorithm is refused",
  await verifyMemberToken(await sign(site.privateKey, { ...H, alg: "RS256" }, good), opts), null);
await check("MUST FIRE an expired token is refused",
  await verifyMemberToken(await sign(site.privateKey, H, { ...good, exp: nowS - 120 }), opts), null);
await check("MUST NOT FIRE a token 30 s past exp is inside the skew allowance",
  await verifyMemberToken(await sign(site.privateKey, H, { ...good, exp: nowS - 30 }), opts), "member@example.com");
await check("MUST FIRE a token from another site's members API is refused",
  await verifyMemberToken(await sign(site.privateKey, H, { ...good, iss: "https://evil.example/members/api" }), opts), null);
await check("MUST FIRE a look-alike issuer host is refused",
  await verifyMemberToken(await sign(site.privateKey, H, { ...good, iss: "https://www.thriftycrew.com.evil.io/members/api" }), opts), null);
await check("MUST NOT FIRE the apex-host issuer is accepted",
  await verifyMemberToken(await sign(site.privateKey, H, { ...good, iss: "https://thriftycrew.com/members/api" }), opts), "member@example.com");
await check("MUST FIRE a subject that is not an email is refused",
  await verifyMemberToken(await sign(site.privateKey, H, { ...good, sub: "abc123" }), opts), null);
await check("MUST FIRE garbage is refused, never thrown",
  await verifyMemberToken("not.a.jwt", opts), null);
await check("MUST FIRE no token at all is refused", await verifyMemberToken(null, opts), null);

// Key rotation: an unknown kid forces ONE refetch, so a rotated key works without waiting out the cache.
jwks = { keys: [...jwks.keys, await jwkOf(other.publicKey, "k2")] };
const before = fetches;
await check("CLEAN TWIN an unknown kid refetches the keys once and then verifies",
  await verifyMemberToken(await sign(other.privateKey, { ...H, kid: "k2" }, good), opts), "member@example.com");
await check("CLEAN TWIN the rotation cost exactly one extra key fetch", fetches - before, 1);
await check("MUST FIRE a kid that exists nowhere is refused after the refetch",
  await verifyMemberToken(await sign(other.privateKey, { ...H, kid: "k9" }, good), opts), null);

const req = (h) => ({ headers: { get: (k) => (k === "Authorization" ? h : null) } });
await check("CLEAN TWIN bearer reads the token", bearer(req("Bearer abc.def.ghi")), "abc.def.ghi");
await check("MUST NOT FIRE a non-bearer header yields no token", bearer(req("Basic xyz")), null);

for (const f of fails) console.log("  FAIL  " + f);
const EXPECTED = 19;
if (n !== EXPECTED) { fails.push("ran " + n + ", expected " + EXPECTED); console.log("  FAIL  ran " + n + ", expected " + EXPECTED); }
console.log("member-token self-test: " + (fails.length ? "FAIL" : "pass") + " (cases=" + n + " failures=" + fails.length + ")");
process.exit(fails.length ? 1 : 0);
