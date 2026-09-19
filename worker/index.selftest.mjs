// index.selftest.mjs - the Worker's member routes driven end to end with fetch, the asset store and Ghost
// stubbed. Hermetic: keys are generated here and no request leaves the process. Run through
// worker/test_member_token.py so run-gates discovers it.
//
// The founding defects (2026-09-18): /alert answered 200 or 403 on a TYPED email, which told a stranger
// who pays and let them sign up someone else's inbox; /planner-data.json served every recipe's cost and
// ingredient amounts to anyone. The MUST FIRE cases below are those two, as a stranger would try them.
import worker from "./index.js";
import { _resetKeyCacheForTest } from "./member-token.js";

const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const nowS = Math.floor(Date.now() / 1000);
const kp = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-512" },
  true, ["sign", "verify"]);
const pub = await crypto.subtle.exportKey("jwk", kp.publicKey);
async function token(sub) {
  const h = enc({ alg: "RS512", kid: "k1", typ: "JWT" });
  const c = enc({ sub, iss: "https://www.thriftycrew.com/members/api", exp: nowS + 600 });
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", kp.privateKey, new TextEncoder().encode(h + "." + c));
  return h + "." + c + "." + Buffer.from(sig).toString("base64url");
}

const MEMBERS = {
  "paid@example.com": { id: "m1", email: "paid@example.com", status: "paid", labels: [], newsletters: [] },
  "free@example.com": { id: "m2", email: "free@example.com", status: "free", labels: [], newsletters: [] },
};
const puts = [];
globalThis.fetch = async (url, opts = {}) => {
  const u = String(url);
  if (u.endsWith("/members/.well-known/jwks.json"))
    return Response.json({ keys: [{ kty: "RSA", n: pub.n, e: pub.e, kid: "k1" }] });
  if (u.includes("/ghost/api/admin/members/?filter=")) {
    const m = /email:'([^']*)'/.exec(decodeURIComponent(u));
    const hit = m && MEMBERS[m[1]];
    return Response.json({ members: hit ? [hit] : [] });
  }
  if (u.includes("/ghost/api/admin/newsletters/"))
    return Response.json({ newsletters: [{ id: "n1", name: "Price Alerts", status: "active" }, { id: "n2", name: "Weekly", status: "active" }] });
  if (u.includes("/ghost/api/admin/members/") && opts.method === "PUT") { puts.push(u); return Response.json({ members: [{}] }); }
  throw new Error("unexpected fetch " + u);
};
const PLANNER = JSON.stringify([{ s: "fajita", cps: 2.66, ing: [{ i: "Chicken", g: 2495 }] }]);
const env = {
  GHOST_ADMIN_KEY: "abc123:" + "00".repeat(32),
  ASSETS: { fetch: async (req) => {
    const p = new URL(req.url).pathname;
    if (p === "/smp-feed.json") return new Response(JSON.stringify({ ingredients: { eggs: {} } }), { headers: { "Content-Type": "application/json" } });
    if (p === "/planner-data.json") return new Response(PLANNER, { headers: { "Cache-Control": "public, max-age=1800", "Access-Control-Allow-Origin": "*" } });
    return new Response("static:" + p, { status: 200 });
  } },
};
const ORIGIN = "https://www.thriftycrew.com";
const call = (path, { method = "GET", body, tok, origin = ORIGIN } = {}) => worker.fetch(new Request("https://feed.thriftycrew.com" + path, {
  method, body: body ? JSON.stringify(body) : undefined,
  headers: { "Content-Type": "application/json", Origin: origin, ...(tok ? { Authorization: "Bearer " + tok } : {}) },
}), env);
const snap = async (r) => r.status + " " + (await r.text());

const fails = [];
let n = 0;
const check = (label, got, want) => { n++; if (got !== want) fails.push(label + " got=" + JSON.stringify(got) + " want=" + JSON.stringify(want)); };
_resetKeyCacheForTest();

// ---- /alert ----
const aMember = await snap(await call("/alert", { method: "POST", body: { email: "paid@example.com", item: "eggs" } }));
const aStranger = await snap(await call("/alert", { method: "POST", body: { email: "nobody@example.com", item: "eggs" } }));
const aFree = await snap(await call("/alert", { method: "POST", body: { email: "free@example.com", item: "eggs" } }));
check("MUST FIRE with no token a paying member's email and a stranger's get byte-identical answers", aMember, aStranger);
check("MUST FIRE with no token a free member's email gets that same answer too", aFree, aStranger);
check("MUST FIRE a typed email with no token signs nobody up", puts.length, 0);
check("CLEAN TWIN the no-token answer asks the caller to sign in", aStranger.startsWith("401 ") && aStranger.includes("needsSignin"), true);
// Corrupt a MIDDLE character of the signature. The last base64url character of a 256-byte signature carries
// two padding bits that decoding discards, so flipping it between some letters changes no byte at all and
// the "forged" token is the genuine one - which made this case pass or fail by chance of the key.
const good = await token("paid@example.com");
const mid = good.lastIndexOf(".") + 40;
const forged = good.slice(0, mid) + (good[mid] === "A" ? "B" : "A") + good.slice(mid + 1);
check("MUST FIRE a forged token for a paying member is refused like no token",
  await snap(await call("/alert", { method: "POST", body: { item: "eggs" }, tok: forged })), aStranger);
const aPaid = await call("/alert", { method: "POST", body: { item: "eggs", email: "free@example.com" }, tok: await token("paid@example.com") });
check("CLEAN TWIN a paying member's genuine token signs THAT member up", aPaid.status + ":" + puts.length + ":" + (puts[0] || "").includes("/members/m1/"), "200:1:true");
check("MUST FIRE the body's email is ignored when a token is present (m2 never written)", puts.some((u) => u.includes("/members/m2/")), false);
const aFreeTok = await snap(await call("/alert", { method: "POST", body: { item: "eggs" }, tok: await token("free@example.com") }));
check("CLEAN TWIN a signed-in free member is told it is a members perk", aFreeTok.startsWith("403 ") && aFreeTok.includes("needsUpgrade"), true);
check("MUST NOT FIRE an unknown item is refused before any member lookup",
  (await call("/alert", { method: "POST", body: { item: "not-an-item" }, tok: await token("paid@example.com") })).status, 400);

// ---- /planner-data.json ----
const pAnon = await call("/planner-data.json?v=2");
const pAnonBody = await pAnon.text();
check("MUST FIRE the planner data is refused to a visitor with no token", pAnon.status, 401);
check("MUST FIRE the refusal carries none of the data", pAnonBody.includes("cps") || pAnonBody.includes("Chicken"), false);
for (const variant of ["/planner-data.json/", "/Planner-Data.json", "/planner-data.JSON"])
  check("MUST FIRE path variant " + variant + " is gated too", (await call(variant)).status, 401);
check("MUST FIRE a free member's genuine token does not get the planner data",
  (await call("/planner-data.json", { tok: await token("free@example.com") })).status, 403);
const pPaid = await call("/planner-data.json", { tok: await token("paid@example.com") });
check("CLEAN TWIN a paying member gets the data byte for byte", pPaid.status + " " + (await pPaid.text()), "200 " + PLANNER);
check("CLEAN TWIN the member's copy is never cached publicly", pPaid.headers.get("Cache-Control"), "private, no-store");
check("CLEAN TWIN the member's copy is readable by the site origin only, not by *", pPaid.headers.get("Access-Control-Allow-Origin"), ORIGIN);
check("CLEAN TWIN a preflight allows the Authorization header",
  ((await call("/planner-data.json", { method: "OPTIONS" })).headers.get("Access-Control-Allow-Headers") || "").includes("Authorization"), true);
check("MUST NOT FIRE other static files are still public", await snap(await call("/board.json")), "200 static:/board.json");

for (const f of fails) console.log("  FAIL  " + f);
const EXPECTED = 20;
if (n !== EXPECTED) { fails.push("ran " + n); console.log("  FAIL  ran " + n + ", expected " + EXPECTED); }
console.log("worker-routes self-test: " + (fails.length ? "FAIL" : "pass") + " (cases=" + n + " failures=" + fails.length + ")");
process.exit(fails.length ? 1 : 0);
