// box-heartbeat.js - the OFF-BOX half of the boot page (Brad's ruling 2026-09-25 on Q4-tasks-dead-after-reboot,
// grocery/triage-plans/plan-2026-09-18.json).
//
// WHY IT LIVES HERE AND NOT ON THE BOX. Every TC task on Brad's PC is "run only when user is logged on", so after a
// reboot with nobody signed in NOTHING on the box runs - health-heartbeat included, because the watcher is one of
// the watched (09-15 and 09-16 were lost that way and nothing paged). A check that has to run on the box cannot
// report the box being down. This one runs on Cloudflare's clock.
//
// THE SHAPE (reliability-craft/applies-here.md 1: the heartbeat is written by the WATCHED, the verdict by the
// WATCHER). The box's TC Boot Watch task POSTs /box-heartbeat every 15 minutes; that handler writes ONLY the key
// BEAT_KEY. A cron trigger runs runBoxWatch every 15 minutes; it writes ONLY WATCH_KEY. One writer per key, so the
// two can never overwrite each other's fields (KV has no transactions). The heartbeat's response carries the
// watcher's last_check_at, so the box can page when the WATCHER stops - the centre of a centralised heartbeat is the
// one thing nothing else watches (reliability-craft/failure-detection-and-membership.md 4.1).
//
// THE THRESHOLD, AND WHAT IT DOES WHEN THE PRODUCER STOPS. SILENT_AFTER_MS = 60 minutes: the box is SILENT when its
// newest beat is MORE than 60 minutes old (strictly greater; exactly 60:00 is quiet). This is an absence detector,
// so it is the one threshold here that FIRES when the producer stops: no beats means the age only grows, and the
// page goes out on the first cron check past the bar - 60 to 75 minutes after the last beat. It pages ONCE per
// silence and once more when the beats come back. A box that never beat at all is paged too, once, 60 minutes after
// the watcher's first check. When the WATCHER stops (the cron is removed, or the Worker fails), nothing here fires;
// that half is the box's (ops/boot-watch.ps1 pages when last_check_at is over 2 hours old).
// 60 minutes is FIRST PLAUSIBLE, not the survivor of a sweep: four missed 15-minute beats, which rides out an
// ordinary Windows Update restart that signs itself back in (the 2026-09-22 boot signed in 37 s after kernel start)
// and a short network blip, and still pages hours before the 07:00 and 08:00 lanes on an overnight reboot.
//
// COST (Workers free plan): 96 beats a day are 96 KV writes, the cron's 96 checks are 96 more; 192 of the free
// 1,000 writes a day. Reads are 2 per check. Nothing here runs until Brad adds the KV binding and the cron trigger
// (design/ready-for-brad/Q4-autologon-and-box-heartbeat.md): without env.BOX_KV every path answers "not configured" and sends
// nothing, so deploying this file changes nothing live.

export const SILENT_AFTER_MS = 60 * 60 * 1000;
export const BEAT_KEY = "box:beat";
export const WATCH_KEY = "box:watch";

const iso = (ms) => new Date(ms).toISOString();
const ms = (s) => { const t = Date.parse(s || ""); return Number.isFinite(t) ? t : null; };

// Pure. What the watcher should do now, and the watch state to store. beat = { last_beat_at, boot_at, host } or null;
// watch = { first_check_at, last_check_at, paged_silent_at, paged_never_at } or null.
export function decideBoxWatch(beat, watch, nowMs, silentAfterMs = SILENT_AFTER_MS) {
  const w = Object.assign({ first_check_at: null, last_check_at: null, paged_silent_at: null, paged_never_at: null }, watch || {});
  if (!w.first_check_at) w.first_check_at = iso(nowMs);
  w.last_check_at = iso(nowMs);
  const lastBeat = beat ? ms(beat.last_beat_at) : null;

  if (lastBeat === null) {
    const since = nowMs - ms(w.first_check_at);
    if (since > silentAfterMs && !w.paged_never_at) {
      return { action: "page-never", ageMs: since, watch: Object.assign(w, { paged_never_at: iso(nowMs) }) };
    }
    return { action: "none", ageMs: null, watch: w };
  }

  const age = nowMs - lastBeat;
  const pagedAt = ms(w.paged_silent_at);
  // Beats came back after a silence page: say so once, and re-arm.
  if (pagedAt !== null && lastBeat > pagedAt) {
    return { action: "page-resumed", ageMs: age, silentSince: w.paged_silent_at, watch: Object.assign(w, { paged_silent_at: null }) };
  }
  if (age > silentAfterMs && pagedAt === null) {
    return { action: "page-silent", ageMs: age, watch: Object.assign(w, { paged_silent_at: iso(nowMs) }) };
  }
  return { action: "none", ageMs: age, watch: w };
}

function mins(msv) { return msv === null || msv === undefined ? "unknown" : Math.round(msv / 60000) + " minutes"; }

// The email for an action. Subjects carry no numbers, so a mail filter can key on them.
export function boxWatchEmail(action, beat, d) {
  const host = (beat && beat.host) || "Brad's PC";
  const last = (beat && beat.last_beat_at) || "never";
  const boot = (beat && beat.boot_at) || "unknown";
  if (action === "page-silent") {
    return {
      subject: "Thrifty Crew: the box has gone silent",
      body: [
        host + " has not sent a heartbeat for " + mins(d.ageMs) + " (last one at " + last + ", UTC; bar is 60 minutes).",
        "Every TC scheduled task runs only while someone is signed in, so while this lasts nothing on the box runs:",
        "no ad pulls, no daily capture, no health heartbeat.",
        "",
        "Most likely it rebooted and nobody signed in, it is asleep or off, or it lost its network.",
        "Sign in (or wake it). The first sign-in after a reboot pages which jobs were missed.",
        "Last boot the box reported: " + boot + ".",
        "You will get one more email when the heartbeat comes back.",
      ].join("\n"),
    };
  }
  if (action === "page-resumed") {
    return {
      subject: "Thrifty Crew: the box is back",
      body: host + " is sending heartbeats again (newest at " + last + ", UTC). It went silent before " + (d.silentSince || "unknown") +
        ". Boot it reports: " + boot + ". If it rebooted, its own page lists the jobs that were missed.",
    };
  }
  if (action === "page-never") {
    return {
      subject: "Thrifty Crew: the box has never sent a heartbeat",
      body: "The off-box watcher has been checking for " + mins(d.ageMs) + " and has never received a heartbeat from the box. " +
        "Either TC Boot Watch is not registered, or its POST to /box-heartbeat is failing. " +
        "Run on the box: powershell -NoProfile -File C:\\Codex\\ThriftyCrew\\ops\\install-ops-tasks.ps1 -Verify",
    };
  }
  throw new Error("unknown box-watch action: " + action);
}

async function readJson(kv, key) {
  const t = await kv.get(key);
  if (!t) return null;
  try { return JSON.parse(t); } catch { return null; }
}

// The cron's body. sendEmail(subject, body) is injected so the self-test never reaches Gmail. An email that fails is
// NOT recorded as sent: the watch state is left as it was, so the next check tries again.
export async function runBoxWatch(env, nowMs, sendEmail) {
  const kv = env && env.BOX_KV;
  if (!kv) return { configured: false, action: "none" };
  const beat = await readJson(kv, BEAT_KEY);
  const watch = await readJson(kv, WATCH_KEY);
  const d = decideBoxWatch(beat, watch, nowMs);
  if (d.action !== "none") {
    const m = boxWatchEmail(d.action, beat, d);
    try { await sendEmail(m.subject, m.body); }
    catch (e) {
      const kept = Object.assign({}, watch || {}, { first_check_at: d.watch.first_check_at, last_check_at: d.watch.last_check_at });
      await kv.put(WATCH_KEY, JSON.stringify(kept));
      return { configured: true, action: d.action, sent: false, error: String(e && e.message || e) };
    }
  }
  await kv.put(WATCH_KEY, JSON.stringify(d.watch));
  return { configured: true, action: d.action, sent: d.action !== "none" };
}

function reply(o, status) {
  return new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
}

// POST /box-heartbeat. Server-to-server, no CORS. authOk is the X-Notify-Auth check the other pipeline routes use.
export async function handleBoxHeartbeat(request, env, authOk, nowMs) {
  if (request.method !== "POST") return reply({ ok: false, error: "method not allowed" }, 405);
  if (!authOk) return reply({ ok: false, error: "unauthorized" }, 401);
  const kv = env && env.BOX_KV;
  if (!kv) return reply({ ok: false, configured: false, error: "box heartbeat is not configured (no BOX_KV binding)" }, 503);
  let data = {};
  try { data = await request.json(); } catch { data = {}; }
  const clip = (v) => (v === undefined || v === null ? null : String(v).slice(0, 80));
  const beat = { last_beat_at: iso(nowMs), boot_at: clip(data.boot_at), host: clip(data.host), sent_at: clip(data.sent_at) };
  await kv.put(BEAT_KEY, JSON.stringify(beat));
  const watch = await readJson(kv, WATCH_KEY);
  return reply({ ok: true, configured: true, received_at: beat.last_beat_at, last_check_at: (watch && watch.last_check_at) || null }, 200);
}
