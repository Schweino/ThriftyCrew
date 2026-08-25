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

/* ==================================================================================================
   THE PRIMARY LANE: A SEARCH SWEEP (added 2026-08-25)
   ==================================================================================================
   Everything above is the SECONDARY tool - a re-pricer for products whose slug we already know
   (product-urls.json has 410 of 625). The lane that actually feeds the board is a SEARCH sweep:
   build-aldi-regular.ps1 reads `id|term|name|prices|unit|size|href` and stamps found_by_term, which
   only a search can produce.

   IT EXISTED ONLY AS PROSE UNTIL NOW. The method was proven on 2026-08-22 through the extension
   (7 terms, 392 rows, 310 priced, mode verified In-Store) and written up in a COMMENT in
   pull-browser-stores.py, while Walmart, Fareway and Sam's each got a committed agent module. So
   Aldi's primary lane was re-improvised from prose every time it ran - and improvising this lane is
   exactly how the 2026-07-12 file shipped ~249 DELIVERY prices labelled in-store. It lives here, in
   the file stores.json -> Aldi -> pull_profile.agent already names, so audit-pull-profiles keeps its
   pacing honest; a second module would carry a second copy of ALDI_PROFILE that nothing checks.

   Runs on pull-agent-lib.js (paste that FIRST, then this file): runPacedSweep supplies the pacing,
   the three-state verdict, the wall handoff and the timing ledger, so this file supplies only what
   is genuinely Aldi-shaped - how to reach a result page, and how to read a tile.

   THE FOUR THINGS THAT ARE NOT OBVIOUS, each of which cost a false start:
     * CLIENT-SIDE ROUTER, NOT NAVIGATION. window.__do_not_use_me_history.push('/aldi/s?k=<term>').
       The path is '/aldi/s' and NOT '/store/aldi/s' - the router is already scoped under /store/,
       and doubling it produces /store/store/aldi/s, a page with no mode label at all. A real
       navigation would also drop us into a cold session.
     * SCROLL, OR YOU GET A TENTH OF THE SHELF. Results lazy-load. Measured 2026-08-25 on
       'alfredo sauce': the first paint carried 4 tiles and scrolling to the bottom gave 67. A sweep
       that stops at the first paint is not a shallow sweep, it is one that will miss the cheapest
       item and publish the second-cheapest as Aldi's price.
     * NAME FROM THE SLUG, NEVER THE CARD TEXT. The longest card line is often a descriptor
       ("Sold individually", "Prepared"). The slug cannot hold a decimal, so "15.5 oz" arrives as
       "15 5 oz"; build-aldi-regular's Repair-SlugDecimals fixes that FROM THE SIZE COLUMN, so size
       must be read off the card rather than derived from the slug.
     * PRICE ONLY FROM "Current price: $X.XX". Every tile also renders a glued form right beside it
       - a $1.75 item carries a bare "$175" - and a naive $-scan takes it. That is the same 100x trap
       Fareway's extractor has, and here it is 100x too EXPENSIVE, which no plausibility check
       catches because a $175 jar of sauce simply never crowns.
*/

const ALDI_SEARCH_STORAGE_KEY = 'TC_ALDI_SEARCH';

/* A product tile, and ONLY a product tile: the cookie-consent link is also an href*="/products/".
   Aldi slugs always begin with the numeric product id, so requiring it is both the filter and the
   proof that we are looking at a real product URL. */
const ALDI_PRODUCT_HREF_RX = /\/products\/(\d+)-([^?#]+)/;
const ALDI_SIZE_RX = /^[\d.]+\s*(?:x\s*[\d.]+\s*)?(?:fl\.?\s*oz|oz|lb|lbs|ct|count|gal|qt|pt|ml|l|g|kg|pk|pack)\b/i;

function aldiSearchExtract(a) {
  const href = a.getAttribute('href') || '';
  const m = href.match(ALDI_PRODUCT_HREF_RX);
  if (!m) return null;
  const lines = (a.innerText || '').split('\n').map(s => s.trim()).filter(Boolean);
  // THE LABELLED PRICE ONLY. See the header: the unlabelled neighbour is the glued 100x form.
  const price = lines.map(l => (l.match(/^Current price:\s*(\$[\d,]+\.\d{2})/) || [])[1]).filter(Boolean)[0] || '';
  // Aldi states a per-unit rate on weighted goods only; kept verbatim, basis and all, never parsed
  // to a bare number - a 2.7 beside a $/lb rival is the unit-mismatch error this estate has paid for.
  const unit = lines.map(l => (l.match(/(\$[\d.]+\s*\/\s*[A-Za-z]+)/) || [])[1]).filter(Boolean)[0] || '';
  const size = lines.find(l => ALDI_SIZE_RX.test(l)) || '';
  return {
    name: m[2].replace(/-/g, ' ').trim(),   // the slug is Aldi's own name and carries the pack size
    prices: price,
    unit: unit,
    size: size,
    href: href,
  };
}

async function aldiSearchProbe(term) {
  // ASSERTED PER TERM, not once per run. A session can be flipped back to Delivery mid-sweep - by a
  // background tab, or by Aldi itself - and every row captured after that is ~10% marked up while
  // looking perfectly normal. Cheap to re-ask; the 2026-07-12 file is what not re-asking costs.
  try { assertInStore(); }
  catch (e) { return { state: 'UNUSABLE', rows: [], why: e.message }; }

  const tiles = () => [...document.querySelectorAll('a[href*="/products/"]')]
    .filter(a => ALDI_PRODUCT_HREF_RX.test(a.getAttribute('href') || ''));

  /*
    THE TURNOVER WINDOW, AND WHY IT HAD TO BE MEASURED (2026-08-25).
    A client-side router changes the URL BEFORE it swaps the result list, so for a moment after the
    push the PREVIOUS term's tiles are still mounted. The first version of this loop seeded its
    stability counter from tiles() at that moment and required only 3 quiet rounds, so it declared
    the shelf "fully loaded" while it was still looking at the old term - or at the first paint of
    the new one. Measured against a patient re-probe on the same session:

        term                       this loop   patient
        aluminum foil                      2         6
        all purpose cleaner                5        23
        unsweetened almond milk            3        70

    A 3-of-70 read is not a shallow sweep. Every one of those rows is a candidate for CHEAPEST, so an
    early exit does not just lose coverage, it silently publishes the wrong Aldi price - and it looks
    exactly like a store that simply does not stock much. Aldi IS limited-assortment (6 really is the
    whole aluminum-foil shelf), which is precisely why a low count cannot be used as the signal that
    the read finished.

    So: remember the tile set BEFORE the push, wait for it to actually turn over, and put a FLOOR on
    the number of scroll rounds so a list that has not mounted yet can never read as stable.
  */
  const beforeCount = tiles().length;
  const beforeFirst = tiles()[0] ? tiles()[0].getAttribute('href') : null;

  try { window.__do_not_use_me_history.push('/aldi/s?k=' + encodeURIComponent(term)); }
  catch (e) { return { state: 'UNUSABLE', rows: [], why: 'router push threw: ' + (e && e.message) }; }

  let landed = false;
  for (let i = 0; i < 25 && !landed; i++) {
    await sleep(300);
    try { landed = decodeURIComponent(location.search || '').includes(term); } catch (e) { }
  }
  if (!landed) return { state: 'UNUSABLE', rows: [], why: 'router never landed on this term' };

  // The URL is this term's; the LIST may still be the last one's. Wait for it to change.
  for (let i = 0; i < 20; i++) {
    await sleep(300);
    const t = tiles();
    const firstHref = t[0] ? t[0].getAttribute('href') : null;
    if (t.length !== beforeCount || firstHref !== beforeFirst) break;
  }

  let last = -1, stable = 0;
  for (let i = 0; i < 40 && (i < 5 || stable < 3); i++) {
    window.scrollTo(0, document.documentElement.scrollHeight);
    await sleep(1100);
    const n = tiles().length;
    if (n === last) stable++; else { stable = 0; last = n; }
  }

  const all = tiles();
  const seen = new Set();
  const rows = [];
  for (const a of all) {
    const r = aldiSearchExtract(a);
    if (!r || !r.prices) continue;              // a tile with no LABELLED price is not a price
    const id = (a.getAttribute('href').match(ALDI_PRODUCT_HREF_RX) || [])[1];
    if (seen.has(id)) continue;
    seen.add(id);
    rows.push(r);
  }
  if (rows.length) return { state: 'MATCHES', rows: rows };

  // BLINDNESS IS NOT EMPTINESS - the rule pull-walmart-instore.js and pull-fareway-instore.js both
  // learned the hard way. EMPTY is a claim about the STORE ("we read the shelf and it was bare"),
  // which downstream treats as NOT-CARRIED and will retire the cell. We may only say it when we
  // actually read a listing. Tiles present but none extractable means the TILE SHAPE moved and the
  // parser is what failed, so the honest answer is UNUSABLE: it halts loudly instead of publishing
  // a false absence.
  if (all.length > 0) {
    return { state: 'UNUSABLE', rows: [],
      why: 'parser kept 0 rows from ' + all.length + ' product tile(s) - the tile shape moved, this is our blindness and NOT evidence that Aldi carries nothing' };
  }
  const txt = (document.body.innerText || '').toLowerCase();
  if (/no results|0 results|could not find|no items/.test(txt)) {
    return { state: 'EMPTY', rows: [], why: 'store rendered a no-results page' };
  }
  return { state: 'UNUSABLE', rows: [], why: 'no product tiles and no no-results message - page shape unknown' };
}

const aldiSearchAgent = {
  storeName: 'Aldi',
  storageKey: ALDI_SEARCH_STORAGE_KEY,
  profile: ALDI_PROFILE,
  assertIdentity: assertInStore,
  probe: aldiSearchProbe,
};

const pullAldiSearch = (worklist, opts) => runPacedSweep(aldiSearchAgent, worklist, opts);

/* build-aldi-regular.ps1 reads `id|term|name|prices|unit|size|href` and the FIRST column is the
   COMMODITY id the term came from, not the product id - so this cannot use the lib's sweepToCsv,
   which puts the term first. Pass the worklist's own term -> commodity id map. */
const aldiSearchToCsv = (idByTerm) => {
  const raw = (typeof tcGet === 'function') ? tcGet(ALDI_SEARCH_STORAGE_KEY) : localStorage.getItem(ALDI_SEARCH_STORAGE_KEY);
  const res = JSON.parse(raw || '{}');
  const out = [];
  for (const entry of Object.entries(res)) {
    const term = entry[0], r = entry[1];
    if (r.v !== 'MATCHES') continue;
    for (const p of r.rows) {
      out.push([(idByTerm && idByTerm[term]) || '', term, p.name, p.prices, p.unit, p.size, p.href].join('|'));
    }
  }
  return out.join('\n');
};
const aldiSearchVerdicts = () => sweepVerdicts(ALDI_SEARCH_STORAGE_KEY);
