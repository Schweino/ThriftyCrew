// smp-feed Worker
// - GET /smp-feed.json and all other paths: served from static ./public assets (ASSETS binding)
// - POST /submit: item-request form handler -> emails contact@simplemoneyplaybook.com via Gmail API
//   Reuses the Work Google OAuth (same refresh-token flow as send-alert.ps1).
//   Secrets (set in Cloudflare dashboard, NOT in this repo):
//     GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN
//   Optional var: NOTIFY_TO (defaults to contact@simplemoneyplaybook.com)

const ALLOWED_ORIGINS = [
  "https://www.thriftycrew.com",
  "https://thriftycrew.com",
  "https://www.simplemoneyplaybook.com",
  "https://simplemoneyplaybook.com",
  "https://map-to-success.ghost.io",
];
const STORES = ["Walmart", "Baker's", "Family Fare", "Hy-Vee", "Aldi", "Sam's Club"];

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

async function sendEmail(env, { store, item, url }) {
  const to = env.NOTIFY_TO || "contact@simplemoneyplaybook.com";
  const token = await getAccessToken(env);
  const text =
    "A visitor submitted an item for the grocery list:\r\n\r\n" +
    "Store: " + store + "\r\n" +
    "Item:  " + item + "\r\n" +
    "URL:   " + url + "\r\n\r\n" +
    "(Submitted via the website item-request form.)";
  const raw =
    "To: " + to + "\r\n" +
    "Subject: New Item Request\r\n" +
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

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const origin = request.headers.get("Origin") || "";

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

      if (store === "Other") store = storeOther;
      if (!store) return json({ ok: false, error: "Please choose a store." }, 400, origin);
      if (store !== "Other" && !STORES.includes(store) && !storeOther && !data.storeOther) {
        // allow any store text when 'Other' path used; otherwise store must be from the list or a provided name
      }
      if (!item) return json({ ok: false, error: "Item name is required." }, 400, origin);
      if (!itemUrl || !/^https?:\/\/.+/i.test(itemUrl)) {
        return json({ ok: false, error: "A valid item URL (starting with http) is required." }, 400, origin);
      }
      // length guards
      if (store.length > 120 || item.length > 300 || itemUrl.length > 2000) {
        return json({ ok: false, error: "One of the fields is too long." }, 400, origin);
      }

      try {
        await sendEmail(env, { store, item, url: itemUrl });
        return json({ ok: true }, 200, origin);
      } catch (e) {
        return json({ ok: false, error: "Could not send right now. Please try again later." }, 502, origin);
      }
    }

    // everything else: static assets (smp-feed.json, etc.)
    return env.ASSETS.fetch(request);
  },
};
