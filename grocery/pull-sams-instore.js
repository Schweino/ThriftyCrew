/*
  pull-sams-instore.js  --  Sam's Club search sweep, PACED so it does not trip the bot wall.

  WHY THIS EXISTS
  ---------------
  The 2026-08-15 sweep ran as an ad-hoc console snippet with no delay between searches. It got
  207 of 595 (id,term) pairs before samsclub.com started serving the interstitial, and the run
  kept going -- so 389 pairs were never really checked. Two separate failures, and the second is
  the dangerous one:

    1. PACING. An unthrottled burst of ~200 searches trips the wall. Sam's is the most aggressive
       of the seven and the only one that CAPTCHAs. It has to be paced like Aldi is paced.

    2. A BLOCKED SEARCH WAS RECORDED THE SAME WAY AS AN EMPTY ONE. The snippet only knew "rows"
       or "no rows", so a walled search looked exactly like "Sam's doesn't carry this". After the
       run, `milk gallon`, `sour cream`, `white bread` and `beef chuck roast boneless` were all
       missing from the capture and NOTHING in the artifact said whether that was because Sam's
       lacks them or because we were blocked. Sam's obviously sells milk. That ambiguity is worse
       than the missing data, because a missing row is visibly missing while a false EMPTY is a
       silent claim that the store does not carry the item.

  So this script reports the three-state verdict the estate already standardised on in
  search-verdict-lib.ps1 -- MATCHES / EMPTY / UNUSABLE -- and a wall is ALWAYS `UNUSABLE`, never
  `EMPTY`. See [[board-data-integrity]]: unchecked is never not-carried.

  HOW TO RUN
  ----------
  1. Owner Chrome, signed in, on an Omaha club. Open any samsclub.com page (same-origin fetch).
  2. Paste this file into the console, then:
         await pullSamsInStore(WORKLIST)     // WORKLIST = ["milk gallon", "sour cream", ...]
  3. Results accumulate in localStorage key TC_SAMS_SWEEP and are returned. Re-running with the
     same worklist RESUMES -- terms already resolved MATCHES/EMPTY are skipped, terms left
     UNUSABLE are retried, which is exactly the "finish the walled tail" case.
  4. Export with samsSweepToCsv() -> q|n|lp|up|id  (that column order is what build-sams-deals
     expects; changing it silently mis-parses the capture).

  HARD RULES (do not relax)
  -------------------------
  * A bot wall is UNUSABLE. Never write EMPTY for a search we were blocked on.
  * CONSECUTIVE_WALL_LIMIT stops the run. Pushing on after the wall is up does not collect data,
    it just deepens the block and burns the rest of the worklist into UNUSABLE.
  * Pacing is jittered. A metronome-exact delay is itself a bot signature; real shoppers are ragged.
  * Never lower delayMs to "just finish faster". The 2026-08-15 run is what that costs.
*/

const SAMS_SEARCH_BASE = 'https://www.samsclub.com/s/';
const SAMS_STORE_KEY   = 'TC_SAMS_SWEEP';

/* Phrases Sam's serves when it is challenging us rather than answering. */
const SAMS_WALL_PHRASES = [
  "let us know you're not a robot",
  'are you a robot',
  'verify you are a human',
  'px-captcha',
  'access to this page has been denied',
  'unusual traffic',
];

const sleep = ms => new Promise(r => setTimeout(r, ms));

/** Base delay plus jitter. A constant interval is a bot tell in its own right. */
function pacedDelay(base, jitter) {
  return base + Math.floor(Math.random() * jitter);
}

/**
 * Abort unless the live session is really on an OMAHA club.
 * Prices are per-club, so a sweep run against the wrong club is real data in the wrong basis --
 * the failure class that is hardest to spot later because every number looks plausible.
 */
function assertOmahaClub() {
  const body = document.body.innerText || '';
  const club = (body.match(/\d{3,5}\s+[A-Za-z][^\n,]{0,40},?\s*(?:Omaha|OMAHA)[^\n]{0,20}/) || [])[0]
            || (body.match(/Omaha[^\n]{0,40}/) || [])[0];
  if (!club) {
    throw new Error(
      'REFUSING TO SWEEP: could not read an Omaha club from the page. Sam\'s prices are per-club; ' +
      'set the club in the UI and confirm it is Omaha before pulling.'
    );
  }
  return { club: club.trim() };
}

/** True when the response is the bot interstitial rather than a search result. */
function isWalled(html, status) {
  if (status === 403 || status === 429) return true;
  const low = html.slice(0, 200000).toLowerCase();
  return SAMS_WALL_PHRASES.some(p => low.includes(p));
}

/**
 * Pull product nodes out of __NEXT_DATA__.
 * Walks the payload rather than pinning a path, because Sam's reshapes the search response and a
 * pinned path degrades to "no products" -- which, before the three-state verdict existed, was
 * indistinguishable from the store not carrying the item.
 */
function extractProducts(html) {
  const m = html.match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
  if (!m) return null;                       // no payload at all -> caller decides (wall vs shape change)
  let data;
  try { data = JSON.parse(m[1]); } catch (e) { return null; }

  const out = [];
  const seen = new Set();
  (function walk(node, depth) {
    if (!node || typeof node !== 'object' || depth > 12) return;
    if (Array.isArray(node)) { for (const v of node) walk(v, depth + 1); return; }

    const name = node.name || node.productName || node.title;
    const id   = node.productId || node.itemNumber || node.id;
    // linePrice = what one package costs. unitPrice = Sam's own per-unit rate, the independent
    // cross-check audit-basis-reconcile uses. Capture BOTH or that guard has nothing to compare.
    const lp = node.linePrice ?? node.finalPrice?.unitPrice ?? node.price;
    const up = node.unitPrice ?? node.pricePerUnit ?? node.unitOfMeasure?.price;

    if (name && id && lp != null && !seen.has(String(id))) {
      seen.add(String(id));
      out.push({
        n:  String(name).replace(/[|\r\n]+/g, ' ').trim(),
        lp: typeof lp === 'object' ? (lp.amount ?? null) : lp,
        up: typeof up === 'object' ? (up.amount ?? null) : (up ?? null),
        id: String(id),
      });
    }
    for (const k of Object.keys(node)) walk(node[k], depth + 1);
  })(data, 0);

  return out;
}

/*
  Pacing defaults MIRROR stores.json -> Sam's Club -> pull_profile. That file is the source of
  truth; these are here only because the console has no filesystem. If you tune the rate, tune it
  THERE and copy it here, or the next puller reads a number nobody measured. Currently marked
  `proposed`, not `measured` -- see the profile's evidence field.
*/
const SAMS_PROFILE = { delayMs: 2600, jitterMs: 1400, retries: 3, backoffMs: 20000, wallLimit: 3 };

async function pullSamsInStore(worklist, opts = {}) {
  const delayMs   = opts.delayMs   ?? SAMS_PROFILE.delayMs;   // 2026-08-15 used ~0 and walled at 207
  const jitterMs  = opts.jitterMs  ?? SAMS_PROFILE.jitterMs;  // ragged cadence, not a metronome
  const retries   = opts.retries   ?? SAMS_PROFILE.retries;   // per-term, on a wall
  const backoffMs = opts.backoffMs ?? SAMS_PROFILE.backoffMs; // doubled each retry
  const CONSECUTIVE_WALL_LIMIT = opts.wallLimit ?? SAMS_PROFILE.wallLimit;

  const ctx = assertOmahaClub();             // throws if the club is not Omaha
  const res = JSON.parse(localStorage.getItem(SAMS_STORE_KEY) || '{}');

  let consecutiveWalls = 0;
  let done = 0, walled = 0;

  for (const term of worklist) {
    // Resume: keep settled verdicts, retry anything we were blocked on.
    if (res[term] && res[term].v !== 'UNUSABLE') continue;

    let settled = false;
    for (let attempt = 0; attempt < retries && !settled; attempt++) {
      let html = '', status = 0;
      try {
        const r = await fetch(SAMS_SEARCH_BASE + encodeURIComponent(term), { credentials: 'include' });
        status = r.status;
        html = await r.text();
      } catch (e) {
        await sleep(backoffMs * Math.pow(2, attempt));
        continue;
      }

      if (isWalled(html, status)) {
        res[term] = { v: 'UNUSABLE', why: 'bot-wall', rows: [] };
        await sleep(backoffMs * Math.pow(2, attempt));   // 20s, 40s, 80s
        continue;
      }

      const rows = extractProducts(html);
      if (rows === null) {
        // No __NEXT_DATA__ and no wall phrase. Could be a soft block or a page-shape change.
        // Either way we did NOT observe the catalog, so it is UNUSABLE, not EMPTY.
        res[term] = { v: 'UNUSABLE', why: 'no-nextdata', rows: [] };
        await sleep(backoffMs * Math.pow(2, attempt));
        continue;
      }

      // Genuinely observed the catalog. Zero rows here really does mean Sam's returned nothing.
      res[term] = rows.length
        ? { v: 'MATCHES', why: null, rows }
        : { v: 'EMPTY',   why: 'store returned no products', rows: [] };
      settled = true;
    }

    if (settled) { consecutiveWalls = 0; done++; }
    else         { consecutiveWalls++;   walled++; }

    localStorage.setItem(SAMS_STORE_KEY, JSON.stringify(res));   // persist every term

    if (consecutiveWalls >= CONSECUTIVE_WALL_LIMIT) {
      console.warn(
        `STOPPING: ${consecutiveWalls} consecutive walled terms. The block is up; continuing would ` +
        `record the rest of the worklist as UNUSABLE and deepen the block. Wait, then re-run the ` +
        `SAME worklist - resolved terms are skipped and UNUSABLE ones are retried.`
      );
      break;
    }

    await sleep(pacedDelay(delayMs, jitterMs));
  }

  const v = Object.values(res);
  const summary = {
    context:  ctx,
    matches:  v.filter(x => x.v === 'MATCHES').length,
    empty:    v.filter(x => x.v === 'EMPTY').length,
    unusable: v.filter(x => x.v === 'UNUSABLE').length,
    thisRun:  { settled: done, walled },
    remaining: worklist.filter(t => !res[t] || res[t].v === 'UNUSABLE').length,
  };
  console.log('sams sweep:', summary);
  return summary;
}

/**
 * Export MATCHES rows as q|n|lp|up|id.
 * EMPTY and UNUSABLE deliberately emit NOTHING: the capture file is a record of observed prices,
 * and the verdict ledger below is where "we looked and found nothing" vs "we never got to look"
 * is kept. Writing a blank row for either would let a blocked term read as a checked one.
 */
function samsSweepToCsv() {
  const res = JSON.parse(localStorage.getItem(SAMS_STORE_KEY) || '{}');
  const out = [];
  for (const [term, r] of Object.entries(res)) {
    if (r.v !== 'MATCHES') continue;
    for (const p of r.rows) {
      out.push([term, p.n, p.lp ?? '', p.up ?? '', p.id].join('|'));
    }
  }
  return out.join('\n');
}

/** The verdict ledger: which terms were checked, and which we never actually got to see. */
function samsSweepVerdicts() {
  const res = JSON.parse(localStorage.getItem(SAMS_STORE_KEY) || '{}');
  return Object.entries(res)
    .map(([term, r]) => [term, r.v, r.why ?? ''].join('|'))
    .join('\n');
}

/** Terms still owed a real look -- feed straight back in as the next worklist. */
function samsSweepRemaining(worklist) {
  const res = JSON.parse(localStorage.getItem(SAMS_STORE_KEY) || '{}');
  return worklist.filter(t => !res[t] || res[t].v === 'UNUSABLE');
}
