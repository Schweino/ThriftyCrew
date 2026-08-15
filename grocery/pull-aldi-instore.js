/*
  pull-aldi-instore.js  --  Aldi IN-STORE (shelf) price puller.

  WHY THIS EXISTS
  ---------------
  aldi.us is an Instacart-powered storefront with THREE fulfillment modes:
      Delivery / Pickup / In-Store
  and it serves a DIFFERENT PRICE per mode. Their own modal says so:
      "Item pricing and availability may vary."
  A fresh/cold session defaults to DELIVERY, whose catalog is marked up
  (observed ~10%: canned tuna 5 oz = $1.05 delivery vs $0.95 in-store).

  The 2026-07-12 aldi-regular file was pulled through a default (Delivery)
  session for the bulk staples100/staples300 batches, so ~249 of 278 Aldi
  everyday prices were the DELIVERY price while the file's `source` string
  claimed in-store. The board therefore showed Aldi ~10% more expensive than
  the shelf on every row it appeared in. That is what this script fixes.

  HOW TO RUN
  ----------
  1. In the owner Chrome profile, open aldi.us and set the fulfillment mode to
     IN-STORE for the Omaha store (ALDI - OLA 42, 68137). This is a real UI
     click; the mode lives in an httpOnly server session, NOT in a cookie or
     localStorage we can set, so it cannot be scripted from PowerShell.
  2. Open any aldi.us product page (same-origin is required for fetch()).
  3. Paste this file into the console, then:
         await pullAldiInStore(WORKLIST)   // WORKLIST = [{i:<commodityId>, s:<productSlug>}, ...]
  4. Results land in localStorage key TC_ALDI_INSTORE and are returned.

  HARD RULES (do not relax)
  -------------------------
  * assertInStore() MUST pass before any price is trusted. If the session is in
    Delivery/Pickup mode the prices are marked up and the run must abort.
  * A page that does not yield a JSON-LD price is recorded as {ok:false}. We NEVER
    fall back to a guessed/derived price. A missing price stays missing.
  * Aldi rate-limits: it starts returning 403 Forbidden after a few hundred rapid
    requests. Keep concurrency at 1 and the delay >= 900ms. A 403 is retried with
    backoff, never silently treated as "no price".
*/

const ALDI_PRODUCT_BASE = 'https://www.aldi.us/store/aldi/products/';

/** Abort unless the live session is really pinned to In-Store. */
function assertInStore() {
  const body = document.body.innerText;
  const mode = (body.match(/(In-Store|Delivery|Pickup)\s*·/) || [])[1];
  if (mode !== 'In-Store') {
    throw new Error(
      `REFUSING TO PULL: fulfillment mode is "${mode || 'unknown'}", not In-Store. ` +
      `Delivery/Pickup prices are marked up. Set the mode in the Aldi UI first.`
    );
  }
  const store = (body.match(/ALDI - [^\n]{0,30}/) || ['unknown'])[0];
  return { mode, store };
}

/*
  Pacing MIRRORS stores.json -> Aldi -> pull_profile, which is the source of truth. The console has
  no filesystem, so the numbers are duplicated here and audit-pull-profiles.ps1 fails if the two
  ever disagree. Tune the registry first, then copy the value down.
  jitterMs is 0: Aldi has held at a flat 900ms. If 403s reappear, add jitter (Sam's needed it).
*/
const ALDI_PROFILE = { delayMs: 900, jitterMs: 0, retries: 2, backoffMs: 4000 };

async function pullAldiInStore(worklist, opts = {}) {
  const delayMs = opts.delayMs ?? ALDI_PROFILE.delayMs;   // Aldi 403s if we go faster
  const retries = opts.retries ?? ALDI_PROFILE.retries;

  const ctx = assertInStore();           // throws if not In-Store
  const res = JSON.parse(localStorage.getItem('TC_ALDI_INSTORE') || '{}');

  /*
    TIMING LEDGER (2026-08-15). Aldi's loop is a product-slug lookup, not a term sweep, so it does
    not run through runPacedSweep -- but it shares the MEASUREMENT via finishLedger from
    pull-agent-lib.js. Paste that file first. The Sam's sweep walled with no record of its own
    cadence; no agent should be able to do that again. `firstWall` here counts 403s, Aldi's
    rate-limit signal.
  */
  const t0 = Date.now();
  let requests = 0, settledCount = 0, firstWall = null;
  let consecutive403 = 0, pausedMs = 0;

  for (const item of worklist) {
    if (res[item.i]?.ok) continue;       // resumable: skip what we already have

    let got = false;
    let wasBlocked = false;              // distinguishes "Aldi blocked us" from "no price on the page"
    for (let attempt = 0; attempt < retries && !got; attempt++) {
      try {
        requests++;
        const r = await fetch(ALDI_PRODUCT_BASE + item.s, { credentials: 'include' });
        if (r.status === 403) {          // rate limited - back off, do not record a price
          if (firstWall === null) firstWall = settledCount;
          wasBlocked = true;
          await sleep(ALDI_PROFILE.backoffMs * (attempt + 1));
          continue;
        }
        const html = await r.text();
        const price = (html.match(/"price":"([\d.]+)"/) || [])[1];
        const size  = (html.match(/"size":"([^"]+)"/)  || [])[1];
        const name  = (html.match(/"name":"([^"]+)"/)  || [])[1];
        if (price) {
          res[item.i] = { p: parseFloat(price), z: size || null, n: name || null, ok: true };
          got = true;
        }
      } catch (e) {
        await sleep(2000 * (attempt + 1));
      }
    }
    if (!got) res[item.i] = { p: null, z: null, n: null, ok: false };  // honest miss
    else { settledCount++; consecutive403 = 0; }

    localStorage.setItem('TC_ALDI_INSTORE', JSON.stringify(res));      // persist every item

    /*
      THE HANDOFF (same contract as runPacedSweep - see pull-agent-lib.js). Aldi's block is a 403
      rather than a CAPTCHA page, but the rule is identical: once retries with backoff have failed,
      stop guessing and hand control to Brad. Without this the run just ends and a {ok:false} miss
      is indistinguishable from a product Aldi genuinely does not stock.
    */
    if (!got && wasBlocked) {
      consecutive403++;
      if (consecutive403 >= (ALDI_PROFILE.wallLimit ?? 3)) {
        const pauseAt = Date.now();
        const answer = await awaitWallCleared('Aldi', item.s, 'http 403 (rate limited)');
        pausedMs += Date.now() - pauseAt;
        if (answer === 'stop') {
          console.warn('Aldi: stopped by operator. Re-run the same worklist later to finish the tail.');
          break;
        }
        consecutive403 = 0;
        delete res[item.i];          // he cleared it - this item deserves a real look
        worklist.push(item);
        continue;
      }
    }

    await sleep(delayMs);
  }

  const ok = Object.values(res).filter(v => v.ok).length;
  const timing = finishLedger({
    t0, requests, delayMs, jitterMs: ALDI_PROFILE.jitterMs, firstWallAfter: firstWall, pausedMs,
  });
  console.log('Aldi pull:', timing);
  return { context: ctx, ok, missing: Object.values(res).length - ok, timing, results: res };
}

const sleep = ms => new Promise(r => setTimeout(r, ms));
