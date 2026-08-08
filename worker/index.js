// smp-feed Worker
// - GET /smp-feed.json and all other paths: served from static ./public assets (ASSETS binding)
// - POST /submit: item-request form handler -> emails admin@thriftycrew.com via Gmail API
//   Reuses the Work Google OAuth (same refresh-token flow as send-alert.ps1).
//   Secrets (set in Cloudflare dashboard, NOT in this repo):
//     GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN
//   Optional var: NOTIFY_TO (defaults to admin@thriftycrew.com)
//   Optional field: email (requester wants to be notified when the item is added; included in
//   the notification body + set as Reply-To so Brad can just hit Reply when it goes live)
// - POST /alert: price-alert signup {email, item, weekly} -> EXISTING PAID/comped Ghost member gets
//   label alert-<item> + the "Price Alerts" newsletter (plus the default newsletter when weekly=true).
//   NEVER creates a member and refuses free/non-members server-side - hitting the endpoint directly
//   must not grant the paid feature. The daily pipeline emails label segments on record lows.
//   Extra secret required: GHOST_ADMIN_KEY (same id:hexsecret Admin API key the pipeline uses)

const ALLOWED_ORIGINS = [
  "https://www.thriftycrew.com",
  "https://thriftycrew.com",
  "https://map-to-success.ghost.io",
];
const STORES = ["Walmart", "Baker's", "Family Fare", "Hy-Vee", "Aldi", "Sam's Club", "Fareway"];

function corsHeaders(origin) {
  const allow = ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

function json(body, status, origin) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...corsHeaders(origin) },
  });
}

// base64url of a UTF-8 string
function b64url(str) {
  const bytes = new TextEncoder().encode(str);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function getAccessToken(env) {
  const body = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID,
    client_secret: env.GOOGLE_CLIENT_SECRET,
    refresh_token: env.GOOGLE_REFRESH_TOKEN,
    grant_type: "refresh_token",
  });
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!r.ok) throw new Error("token exchange failed: " + r.status + " " + (await r.text()).slice(0, 200));
  const j = await r.json();
  if (!j.access_token) throw new Error("no access_token in token response");
  return j.access_token;
}

async function sendEmail(env, { store, item, url, notifyEmail, queued }) {
  const to = env.NOTIFY_TO || "admin@thriftycrew.com";
  const token = await getAccessToken(env);
  const text =
    "A visitor submitted an item for the grocery list:\r\n\r\n" +
    "Store: " + store + "\r\n" +
    "Item:  " + item + "\r\n" +
    "URL:   " + url + "\r\n" +
    (notifyEmail ? "Notify when added: " + notifyEmail + (queued ? " (auto-notify QUEUED - the pipeline emails them when a matching item goes live on the board)" : " (auto-notify queue FAILED - reply manually when added)") + "\r\n" : "") +
    "\r\n(Submitted via the website item-request form." +
    (notifyEmail ? " Reply to this email to reach the requester." : "") + ")";
  const raw =
    "To: " + to + "\r\n" +
    (notifyEmail ? "Reply-To: " + notifyEmail + "\r\n" : "") +
    "Subject: New Item Request" + (notifyEmail ? " (wants notification)" : "") + "\r\n" +
    "Content-Type: text/plain; charset=UTF-8\r\n\r\n" +
    text;
  const r = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", {
    method: "POST",
    headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
    body: JSON.stringify({ raw: b64url(raw) }),
  });
  if (!r.ok) throw new Error("gmail send failed: " + r.status + " " + (await r.text()).slice(0, 200));
  return (await r.json()).id;
}

// ---- Ghost Admin API helpers (for /alert) ----
const GHOST_API = "https://map-to-success.ghost.io";

async function ghostJwt(env) {
  const [id, secretHex] = (env.GHOST_ADMIN_KEY || "").split(":");
  if (!id || !secretHex) throw new Error("GHOST_ADMIN_KEY secret missing/malformed");
  const keyBytes = new Uint8Array(secretHex.length / 2);
  for (let i = 0; i < keyBytes.length; i++) keyBytes[i] = parseInt(secretHex.substr(i * 2, 2), 16);
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "HS256", typ: "JWT", kid: id }));
  const payload = b64url(JSON.stringify({ iat: now, exp: now + 300, aud: "/admin/" }));
  const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(header + "." + payload));
  const sigBytes = new Uint8Array(sig);
  let bin = "";
  for (let i = 0; i < sigBytes.length; i++) bin += String.fromCharCode(sigBytes[i]);
  const sigB64 = btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return header + "." + payload + "." + sigB64;
}

async function ghostFetch(env, path, opts) {
  const token = await ghostJwt(env);
  const r = await fetch(GHOST_API + path, {
    ...opts,
    headers: { Authorization: "Ghost " + token, "Accept-Version": "v5.0", "Content-Type": "application/json", ...(opts && opts.headers) },
  });
  return r;
}

// find the member by email; returns the member (with labels,newsletters) or null. NEVER creates.
async function findMemberByEmail(env, email) {
  const filter = encodeURIComponent("email:'" + email.replace(/'/g, "") + "'");
  const findR = await ghostFetch(env, "/ghost/api/admin/members/?filter=" + filter + "&limit=1&include=labels,newsletters");
  if (!findR.ok) throw new Error("member lookup failed " + findR.status);
  return ((await findR.json()).members || [])[0] || null;
}

// attach the alert label + Price Alerts newsletter to an ALREADY-VERIFIED paid member.
// The /alert handler does the paid check and passes the member in; this NEVER creates a member, because a
// free signup must not be able to buy into a paid feature just by reaching this endpoint.
// Labels/newsletters are REPLACED on PUT in Ghost, so we always merge with what exists.
async function subscribeAlert(env, member, item, weekly) {
  const nlR = await ghostFetch(env, "/ghost/api/admin/newsletters/?limit=all");
  if (!nlR.ok) throw new Error("newsletters fetch failed " + nlR.status);
  const newsletters = (await nlR.json()).newsletters || [];
  const alertsNl = newsletters.find((n) => n.name === "Price Alerts" && n.status === "active");
  if (!alertsNl) throw new Error("Price Alerts newsletter not found");
  const defaultNl = newsletters.find((n) => n.status === "active" && n.id !== alertsNl.id);

  const label = "alert-" + item;
  const m = member;
  const labels = (m.labels || []).map((l) => ({ name: l.name }));
  if (!labels.some((l) => l.name === label)) labels.push({ name: label });
  const nlIds = (m.newsletters || []).map((n) => ({ id: n.id }));
  if (!nlIds.some((n) => n.id === alertsNl.id)) nlIds.push({ id: alertsNl.id });
  if (weekly && defaultNl && !nlIds.some((n) => n.id === defaultNl.id)) nlIds.push({ id: defaultNl.id });
  const putR = await ghostFetch(env, "/ghost/api/admin/members/" + m.id + "/", {
    method: "PUT",
    body: JSON.stringify({ members: [{ labels: labels, newsletters: nlIds }] }),
  });
  if (!putR.ok) throw new Error("member update failed " + putR.status + " " + (await putR.text()).slice(0, 200));
  return "updated";
}

// ---- "notify me when it's added" queue (NO Ghost member is created - requesters are often not members) ----
// A pending request is stored as a Ghost DRAFT post tagged #item-request-queue (invisible to visitors; only
// clutter is the admin Drafts list). The daily pipeline (notify-item-added.ps1) matches new board commodities
// against the queue and calls POST /notify here to send the requester a ONE-OFF Gmail - no membership, no
// newsletter, nothing persistent for the requester.
const QUEUE_TAG = "#item-request-queue";

async function queueRequest(env, email, store, item) {
  const meta = JSON.stringify({ email: email, store: store, item: item, date: new Date().toISOString().slice(0, 10) });
  const lex = JSON.stringify({ root: { children: [{ type: "html", version: 1, html: "<pre>" + meta.replace(/</g, "&lt;") + "</pre>" }], direction: null, format: "", indent: 0, type: "root", version: 1 } });
  const r = await ghostFetch(env, "/ghost/api/admin/posts/", {
    method: "POST",
    body: JSON.stringify({ posts: [{ title: "[QUEUE] item request: " + item.slice(0, 120), lexical: lex, status: "draft", custom_excerpt: meta.slice(0, 300), tags: [{ name: QUEUE_TAG }] }] }),
  });
  if (!r.ok) throw new Error("queue draft create failed " + r.status + " " + (await r.text()).slice(0, 200));
  return (await r.json()).posts[0].id;
}

// constant-ish auth: caller sends SHA-256 hex of GHOST_ADMIN_KEY (shared with the pipeline; key never travels)
async function notifyAuthOk(env, request) {
  const given = request.headers.get("X-Notify-Auth") || "";
  if (!env.GHOST_ADMIN_KEY || !given) return false;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(env.GHOST_ADMIN_KEY));
  const want = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return given.toLowerCase() === want;
}

async function sendRecipeEmail(env, { recipe, url, memberEmail, notifyEmail }) {
  const to = env.NOTIFY_TO || "admin@thriftycrew.com";
  const token = await getAccessToken(env);
  const replyTo = notifyEmail || memberEmail;
  const text =
    "A paid member suggested a recipe for the meal-prep library:\r\n\r\n" +
    "Recipe: " + recipe + "\r\n" +
    "URL:    " + url + "\r\n" +
    "Member: " + memberEmail + "\r\n" +
    (notifyEmail ? "Notify when added: " + notifyEmail + " (reply to this email when it goes live)\r\n" : "") +
    "\r\n(Submitted via the members' recipe-idea form on the Meal Prep page." +
    (replyTo ? " Reply to this email to reach them." : "") + ")";
  const raw =
    "To: " + to + "\r\n" +
    (replyTo ? "Reply-To: " + replyTo + "\r\n" : "") +
    "Subject: New Recipe Idea" + (notifyEmail ? " (wants notification)" : "") + "\r\n" +
    "Content-Type: text/plain; charset=UTF-8\r\n\r\n" +
    text;
  const r = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", {
    method: "POST",
    headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
    body: JSON.stringify({ raw: b64url(raw) }),
  });
  if (!r.ok) throw new Error("gmail send failed: " + r.status + " " + (await r.text()).slice(0, 200));
  return (await r.json()).id;
}

async function sendRequesterEmail(env, { email, item, commodity, cheapest }) {
  const token = await getAccessToken(env);
  const text =
    "Good news!\r\n\r\n" +
    "You asked us to track \"" + item + "\" on the Thrifty Crew price board, and it's live now" +
    (commodity ? " as \"" + commodity + "\"" : "") + "." +
    (cheapest ? "\r\n\r\nCheapest right now: " + cheapest : "") +
    "\r\n\r\nSee it here: https://www.thriftycrew.com/omaha-grocery-prices/\r\n\r\n" +
    "Thanks for the suggestion. Happy saving!\r\n" +
    "- The Thrifty Crew\r\n\r\n" +
    "(This is the one-time heads-up you asked for on our suggest-an-item form. No list, no follow-ups.)";
  const raw =
    "To: " + email + "\r\n" +
    "Subject: " + (commodity || item) + " is now on the Omaha price board\r\n" +
    "Content-Type: text/plain; charset=UTF-8\r\n\r\n" +
    text;
  const r = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", {
    method: "POST",
    headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
    body: JSON.stringify({ raw: b64url(raw) }),
  });
  if (!r.ok) throw new Error("gmail send failed: " + r.status + " " + (await r.text()).slice(0, 200));
  return (await r.json()).id;
}

// ops alert: lets the GitHub Actions backup run send a REAL Gmail alert to Brad (it holds no Google
// token of its own - only GHOST_ADMIN_KEY - so it proves itself with the same SHA-256-of-admin-key
// auth as /notify and this Worker does the sending). Recipient is fixed server-side; a stolen hash
// could only ever email Brad about the pipeline, never exfiltrate or spam third parties. The cloud
// runs at most once per day, which is the de-dup.
async function sendOpsEmail(env, { subject, body }) {
  const token = await getAccessToken(env);
  const raw =
    "To: schweino68@gmail.com\r\n" +
    "Subject: " + subject.replace(/[\r\n]+/g, " ").slice(0, 200) + "\r\n" +
    "Content-Type: text/plain; charset=UTF-8\r\n\r\n" +
    body.slice(0, 5000) + "\r\n\r\n(Automated ops alert relayed through the smp-feed Worker.)";
  const r = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", {
    method: "POST",
    headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
    body: JSON.stringify({ raw: b64url(raw) }),
  });
  if (!r.ok) throw new Error("gmail send failed: " + r.status + " " + (await r.text()).slice(0, 200));
  return (await r.json()).id;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const origin = request.headers.get("Origin") || "";

    // server-to-server only (no CORS path): the Actions backup posts here on failure.
    if (url.pathname === "/ops-alert") {
      if (request.method !== "POST") return json({ ok: false, error: "method not allowed" }, 405, origin);
      if (!(await notifyAuthOk(env, request))) return json({ ok: false, error: "unauthorized" }, 401, origin);
      let data;
      try { data = await request.json(); } catch { return json({ ok: false, error: "invalid JSON" }, 400, origin); }
      const subject = (data.subject || "").toString().trim();
      const body = (data.body || "").toString().trim();
      if (!subject || !body) return json({ ok: false, error: "bad payload" }, 400, origin);
      try { const id = await sendOpsEmail(env, { subject, body }); return json({ ok: true, id: id }, 200, origin); }
      catch (e) { return json({ ok: false, error: "send failed" }, 502, origin); }
    }

    if (url.pathname === "/alert") {
      if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(origin) });
      if (request.method !== "POST") return json({ ok: false, error: "method not allowed" }, 405, origin);
      let data;
      try { data = await request.json(); } catch { return json({ ok: false, error: "invalid JSON" }, 400, origin); }
      // honeypot: silently accept bots
      if (data && typeof data.website === "string" && data.website.trim() !== "") return json({ ok: true }, 200, origin);
      const email = (data.email || "").toString().trim().toLowerCase();
      const item = (data.item || "").toString().trim();
      const weekly = data.weekly === true;
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email) || email.length > 200) return json({ ok: false, error: "Please enter a valid email address." }, 400, origin);
      if (!/^[a-z0-9-]{2,60}$/.test(item)) return json({ ok: false, error: "Unknown item." }, 400, origin);
      // item must be something we actually track (guards junk labels)
      try {
        const feedRes = await env.ASSETS.fetch(new Request(new URL("/smp-feed.json", request.url)));
        const feedText = await feedRes.text();
        const feed = JSON.parse(feedText.charCodeAt(0) === 0xfeff ? feedText.slice(1) : feedText);
        if (!feed.ingredients || !feed.ingredients[item]) return json({ ok: false, error: "Unknown item." }, 400, origin);
      } catch (e) {
        return json({ ok: false, error: "Could not verify the item right now." }, 502, origin);
      }
      // PAID-ONLY GATE (server-side; the board's client-side check is UX, not security). Price alerts are a
      // paid perk, so the email must belong to an existing PAID or comped member. A free member, or an email
      // that is not a member at all, is refused - hitting this endpoint directly must not grant the feature.
      let member = null;
      try { member = await findMemberByEmail(env, email); } catch (e) {
        return json({ ok: false, error: "Could not verify your membership right now. Please try again later." }, 502, origin);
      }
      if (!member || (member.status !== "paid" && member.status !== "comped")) {
        return json({ ok: false, error: "Price alerts are a members-only perk. Join for $1/month to switch them on.", needsUpgrade: true }, 403, origin);
      }
      try {
        await subscribeAlert(env, member, item, weekly);
        return json({ ok: true }, 200, origin);
      } catch (e) {
        return json({ ok: false, error: "Could not sign you up right now. Please try again later." }, 502, origin);
      }
    }

    // pipeline-only: send the one-off "your item is live" email to a requester. Auth = SHA-256 of the
    // shared GHOST_ADMIN_KEY (pipeline computes the same hash; the key itself never travels). No CORS
    // needed (server-to-server), no browser path hits this.
    if (url.pathname === "/notify") {
      if (request.method !== "POST") return json({ ok: false, error: "method not allowed" }, 405, origin);
      if (!(await notifyAuthOk(env, request))) return json({ ok: false, error: "unauthorized" }, 401, origin);
      let data;
      try { data = await request.json(); } catch { return json({ ok: false, error: "invalid JSON" }, 400, origin); }
      const email = (data.email || "").toString().trim();
      const item = (data.item || "").toString().trim();
      const commodity = (data.commodity || "").toString().trim();
      const cheapest = (data.cheapest || "").toString().trim();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email) || !item) return json({ ok: false, error: "bad payload" }, 400, origin);
      try {
        const id = await sendRequesterEmail(env, { email, item, commodity, cheapest });
        return json({ ok: true, id: id }, 200, origin);
      } catch (e) {
        return json({ ok: false, error: "send failed" }, 502, origin);
      }
    }

    // members-only recipe-idea form on the Meal Prep page. Same email path as /submit, but the
    // requester must be a PAID (or comped) member: the form sends their account email as memberEmail
    // and we verify it server-side (the page's client gate is UX; this is the real check).
    if (url.pathname === "/submit-recipe") {
      if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(origin) });
      if (request.method !== "POST") return json({ ok: false, error: "method not allowed" }, 405, origin);

      let data;
      try { data = await request.json(); } catch { return json({ ok: false, error: "invalid JSON" }, 400, origin); }
      // honeypot: silently accept bots without emailing
      if (data && typeof data.website === "string" && data.website.trim() !== "") return json({ ok: true }, 200, origin);

      const recipe = (data.recipe || "").toString().trim();
      const recipeUrl = (data.url || "").toString().trim();
      const memberEmail = (data.memberEmail || "").toString().trim().toLowerCase();
      const notifyEmail = (data.email || "").toString().trim().toLowerCase();

      if (!recipe) return json({ ok: false, error: "Recipe name is required." }, 400, origin);
      if (!recipeUrl || !/^https?:\/\/.+/i.test(recipeUrl)) return json({ ok: false, error: "A valid recipe URL (starting with http) is required." }, 400, origin);
      if (recipe.length > 300 || recipeUrl.length > 2000) return json({ ok: false, error: "One of the fields is too long." }, 400, origin);
      if (notifyEmail && (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(notifyEmail) || notifyEmail.length > 200)) {
        return json({ ok: false, error: "That notification email doesn't look valid. Fix it or leave it blank." }, 400, origin);
      }
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(memberEmail) || memberEmail.length > 200) {
        return json({ ok: false, error: "We couldn't confirm your membership. Please refresh the page and try again." }, 400, origin);
      }
      // PAID-ONLY GATE (server-side): the account email must belong to a paid/comped member.
      let member = null;
      try { member = await findMemberByEmail(env, memberEmail); } catch (e) {
        return json({ ok: false, error: "Could not verify your membership right now. Please try again later." }, 502, origin);
      }
      if (!member || (member.status !== "paid" && member.status !== "comped")) {
        return json({ ok: false, error: "Recipe suggestions are a members-only perk. Join for $1/month to send one in.", needsUpgrade: true }, 403, origin);
      }
      try {
        await sendRecipeEmail(env, { recipe, url: recipeUrl, memberEmail, notifyEmail });
        return json({ ok: true }, 200, origin);
      } catch (e) {
        return json({ ok: false, error: "Could not send right now. Please try again later." }, 502, origin);
      }
    }

    if (url.pathname === "/submit") {
      if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(origin) });
      if (request.method !== "POST") return json({ ok: false, error: "method not allowed" }, 405, origin);

      let data;
      try { data = await request.json(); } catch { return json({ ok: false, error: "invalid JSON" }, 400, origin); }

      // honeypot: silently accept bots without emailing
      if (data && typeof data.website === "string" && data.website.trim() !== "") {
        return json({ ok: true }, 200, origin);
      }

      let store = (data.store || "").toString().trim();
      const storeOther = (data.storeOther || "").toString().trim();
      const item = (data.item || "").toString().trim();
      const itemUrl = (data.url || "").toString().trim();
      // optional: requester wants a heads-up when the item goes live
      const notifyEmail = (data.email || "").toString().trim().toLowerCase();
      if (notifyEmail && (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(notifyEmail) || notifyEmail.length > 200)) {
        return json({ ok: false, error: "That notification email doesn't look valid. Fix it or leave it blank." }, 400, origin);
      }

      if (store === "Other") store = storeOther;
      if (!store) return json({ ok: false, error: "Please choose a store." }, 400, origin);
      // any store text is accepted by design ("Other" is a free-text path); the 120-char cap below bounds it
      if (!item) return json({ ok: false, error: "Item name is required." }, 400, origin);
      if (!itemUrl || !/^https?:\/\/.+/i.test(itemUrl)) {
        return json({ ok: false, error: "A valid item URL (starting with http) is required." }, 400, origin);
      }
      // length guards
      if (store.length > 120 || item.length > 300 || itemUrl.length > 2000) {
        return json({ ok: false, error: "One of the fields is too long." }, 400, origin);
      }

      // queue the auto-notification BEFORE emailing Brad, so his email can say whether it queued.
      // Queue failure never fails the submit - Brad's email still carries the address as the manual fallback.
      let queued = false;
      if (notifyEmail) {
        try { await queueRequest(env, notifyEmail, store, item); queued = true; } catch (e) { queued = false; }
      }
      try {
        await sendEmail(env, { store, item, url: itemUrl, notifyEmail, queued });
        return json({ ok: true }, 200, origin);
      } catch (e) {
        return json({ ok: false, error: "Could not send right now. Please try again later." }, 502, origin);
      }
    }

    // everything else: static assets (smp-feed.json, etc.)
    return env.ASSETS.fetch(request);
  },
};

