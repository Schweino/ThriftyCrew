// box-heartbeat.selftest.mjs - the off-box boot page (worker/box-heartbeat.js) driven with a stub KV and a stub mailer.
// Hermetic: no request leaves the process. Run through worker/test_member_token.py so run-gates discovers it.
//
// The founding defect (2026-09-14 to 09-17, queue 2026-09-18-8491bf): a Windows Update restart left the box with
// nobody signed in, every TC task (health-heartbeat included) refused to launch for two days, and nothing paged.
// The MUST FIRE cases are that silence as the watcher sees it; the bar is SILENT_AFTER_MS = 60 minutes, and a case
// sits exactly AT it and one a minute PAST it (.claude/rules/ops-and-gates.md, backlog I196).
import worker from "./index.js";
import { decideBoxWatch, runBoxWatch, handleBoxHeartbeat, boxWatchEmail, SILENT_AFTER_MS, BEAT_KEY, WATCH_KEY } from "./box-heartbeat.js";

let n = 0;
const fails = [];
function check(name, got, want) {
  n++;
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? "  ok    " : "  X     ") + name + (ok ? "" : "   got: " + JSON.stringify(got) + " want: " + JSON.stringify(want)));
  if (!ok) fails.push(name);
}

function stubKv() {
  const m = new Map();
  const puts = [];
  return { m, puts, async get(k) { return m.has(k) ? m.get(k) : null; }, async put(k, v) { puts.push(k); m.set(k, v); } };
}
const T0 = Date.parse("2026-09-25T03:00:00Z");
const MIN = 60 * 1000;
const at = (msv) => new Date(msv).toISOString();
const beatAt = (msv) => ({ last_beat_at: at(msv), boot_at: "2026-09-22T17:25:22Z", host: "DESKTOP-L652I1V" });

check("CLEAN TWIN the bar is 60 minutes", SILENT_AFTER_MS, 60 * MIN);

// ---- the pure decision ----
check("MUST NOT FIRE a fresh heartbeat (5 minutes old) is quiet",
  decideBoxWatch(beatAt(T0 - 5 * MIN), null, T0).action, "none");
check("MUST NOT FIRE AT THE BAR: a heartbeat exactly 60 minutes old is quiet (silent means MORE than 60)",
  decideBoxWatch(beatAt(T0 - 60 * MIN), null, T0).action, "none");
const past = decideBoxWatch(beatAt(T0 - 61 * MIN), null, T0);
check("MUST FIRE ONE STEP PAST THE BAR: 61 minutes of silence pages", past.action, "page-silent");
check("MUST FIRE the page is recorded so it is sent once", past.watch.paged_silent_at, at(T0));
check("MUST NOT FIRE a silence already paged is not paged again 45 minutes later",
  decideBoxWatch(beatAt(T0 - 61 * MIN), past.watch, T0 + 45 * MIN).action, "none");
const back = decideBoxWatch(beatAt(T0 + 50 * MIN), past.watch, T0 + 55 * MIN);
check("MUST FIRE beats that come back after a silence page say so once", back.action, "page-resumed");
check("CLEAN TWIN and re-arm the silence page", back.watch.paged_silent_at, null);
check("MUST NOT FIRE the resumed page is not repeated on the next check",
  decideBoxWatch(beatAt(T0 + 65 * MIN), back.watch, T0 + 70 * MIN).action, "none");
check("MUST FIRE a second silence after a resume pages again",
  decideBoxWatch(beatAt(T0 + 65 * MIN), back.watch, T0 + 65 * MIN + 61 * MIN).action, "page-silent");

const first = decideBoxWatch(null, null, T0);
check("MUST NOT FIRE the watcher's first check with no beat yet is quiet, and starts the clock",
  [first.action, first.watch.first_check_at], ["none", at(T0)]);
check("MUST NOT FIRE AT THE BAR: no beat 60 minutes after the first check is quiet",
  decideBoxWatch(null, first.watch, T0 + 60 * MIN).action, "none");
const never = decideBoxWatch(null, first.watch, T0 + 61 * MIN);
check("MUST FIRE ONE STEP PAST THE BAR: a box that has never beaten is paged", never.action, "page-never");
check("MUST NOT FIRE and only once", decideBoxWatch(null, never.watch, T0 + 200 * MIN).action, "none");

let digits = 0;
for (const a of ["page-silent", "page-resumed", "page-never"]) if (/\d/.test(boxWatchEmail(a, beatAt(T0), { ageMs: 61 * MIN }).subject)) digits++;
check("CLEAN TWIN every subject carries no digits, so a filter can key on it", digits, 0);
let threw = false;
try { boxWatchEmail("page-bogus", null, {}); } catch { threw = true; }
check("MUST FIRE an unknown action refuses loudly instead of mailing nothing", threw, true);

// ---- the cron body, against a stub KV and mailer ----
const sent = [];
const mail = async (s, b) => { sent.push(s); };
check("MUST NOT FIRE with no BOX_KV binding nothing runs and nothing is mailed",
  [(await runBoxWatch({}, T0, mail)).configured, sent.length], [false, 0]);
const kv = stubKv();
kv.m.set(BEAT_KEY, JSON.stringify(beatAt(T0 - 90 * MIN)));
const r1 = await runBoxWatch({ BOX_KV: kv }, T0, mail);
check("MUST FIRE 90 minutes of silence mails the silent page", [r1.action, r1.sent, sent.slice()], ["page-silent", true, ["Thrifty Crew: the box has gone silent"]]);
await runBoxWatch({ BOX_KV: kv }, T0 + 15 * MIN, mail);
check("MUST NOT FIRE the next cron check sends nothing more", sent.length, 1);

const kv2 = stubKv();
kv2.m.set(BEAT_KEY, JSON.stringify(beatAt(T0 - 90 * MIN)));
const broken = async () => { throw new Error("gmail down"); };
const r2 = await runBoxWatch({ BOX_KV: kv2 }, T0, broken);
check("MUST FIRE a mail that fails is NOT recorded as sent", [r2.sent, JSON.parse(kv2.m.get(WATCH_KEY)).paged_silent_at || null], [false, null]);
const sent2 = [];
await runBoxWatch({ BOX_KV: kv2 }, T0 + 15 * MIN, async (s) => { sent2.push(s); });
check("CLEAN TWIN so the next check tries the page again", sent2, ["Thrifty Crew: the box has gone silent"]);
check("CLEAN TWIN the cron writes only the watch key, never the beat", [...new Set(kv.puts)], [WATCH_KEY]);

// ---- POST /box-heartbeat ----
const req = (method, body) => new Request("https://feed.thriftycrew.com/box-heartbeat", { method, body: body ? JSON.stringify(body) : undefined, headers: { "Content-Type": "application/json" } });
check("MUST FIRE an unauthenticated beat is refused, so a stranger cannot hold the page off",
  (await handleBoxHeartbeat(req("POST", {}), { BOX_KV: stubKv() }, false, T0)).status, 401);
check("MUST FIRE a GET is refused", (await handleBoxHeartbeat(req("GET"), { BOX_KV: stubKv() }, true, T0)).status, 405);
const nc = await handleBoxHeartbeat(req("POST", {}), {}, true, T0);
check("MUST FIRE with no BOX_KV binding the beat says not configured (503), never ok", [nc.status, (await nc.json()).configured], [503, false]);
const kv3 = stubKv();
kv3.m.set(WATCH_KEY, JSON.stringify({ last_check_at: at(T0 - 7 * MIN) }));
const okr = await handleBoxHeartbeat(req("POST", { boot_at: "2026-09-22T17:25:22Z", host: "DESKTOP-L652I1V" }), { BOX_KV: kv3 }, true, T0);
const okb = await okr.json();
check("CLEAN TWIN an authenticated beat is stored with the server's clock and hands back the watcher's last check",
  [okr.status, JSON.parse(kv3.m.get(BEAT_KEY)).last_beat_at, JSON.parse(kv3.m.get(BEAT_KEY)).boot_at, okb.last_check_at],
  [200, at(T0), "2026-09-22T17:25:22Z", at(T0 - 7 * MIN)]);
check("CLEAN TWIN the beat writes only the beat key, never the watch", [...new Set(kv3.puts)], [BEAT_KEY]);

// ---- wired into the Worker the repo deploys ----
const KEY = "selftest-id:00ff00ff";
const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(KEY)))].map((b) => b.toString(16).padStart(2, "0")).join("");
const kv4 = stubKv();
const envW = { GHOST_ADMIN_KEY: KEY, BOX_KV: kv4, ASSETS: { fetch: async () => new Response("static") } };
const wNo = await worker.fetch(new Request("https://feed.thriftycrew.com/box-heartbeat", { method: "POST", body: "{}" }), envW);
check("MUST FIRE through index.js, a beat with no X-Notify-Auth is refused", wNo.status, 401);
const wOk = await worker.fetch(new Request("https://feed.thriftycrew.com/box-heartbeat", { method: "POST", body: "{}", headers: { "X-Notify-Auth": hash } }), envW);
check("CLEAN TWIN through index.js, the pipeline's auth hash is accepted and the beat stored", [wOk.status, kv4.m.has(BEAT_KEY)], [200, true]);
let waited = null;
await worker.scheduled({ cron: "*/15 * * * *" }, {}, { waitUntil: (p) => { waited = p; } });
check("CLEAN TWIN index.js exports the cron handler, and with no binding it does nothing", (await waited).configured, false);

for (const f of fails) console.log("  FAIL  " + f);
const EXPECTED = 30;
if (n !== EXPECTED) { fails.push("ran " + n); console.log("  FAIL  ran " + n + ", expected " + EXPECTED); }
console.log("box-heartbeat self-test: " + (fails.length ? "FAIL" : "pass") + " (cases=" + n + " failures=" + fails.length + ")");
process.exit(fails.length ? 1 : 0);
