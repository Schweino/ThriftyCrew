/*
  pull-sams-instore.js  --  Sam's Club search sweep agent.

  Runs on pull-agent-lib.js -- paste that file into the console FIRST, then this one.
  The pacing, jitter, backoff, three-state verdict, resumability and timing ledger all live in the
  lib; everything here is the part that is genuinely specific to Sam's.

  THE RUN THIS WAS WRITTEN FOR
  ----------------------------
  2026-08-15: the sweep ran as an ad-hoc console snippet with no delay between searches. It got 207
  of 595 (id,term) pairs before samsclub.com started serving the interstitial, and it kept going --
  so 389 pairs were never really checked. Two separate failures:

    1. PACING. An unthrottled burst trips the wall. Sam's is the most aggressive of the seven and the
       only one that CAPTCHAs.
    2. A BLOCKED SEARCH WAS RECORDED THE SAME WAY AS AN EMPTY ONE. Afterwards, `milk gallon`,
       `sour cream`, `white bread` and `beef chuck roast boneless` were all missing from the capture
       and nothing said whether that was because Sam's lacks them or because we were blocked. Sam's
       obviously sells milk. That ambiguity is worse than the missing data.

  And a third thing, which is why the lib emits a timing ledger: THE RUN RECORDED NO TIMING AT ALL,
  so after it walled there was no measured rate to compare against or tune away from.

  HOW TO RUN
  ----------
  1. Owner Chrome, signed in, on an Omaha club. Open any samsclub.com page (same-origin fetch).
  2. Paste pull-agent-lib.js, then this file, then:
         await pullSamsInStore(WORKLIST)     // WORKLIST = ["milk gallon", "sour cream", ...]
  3. Re-running the SAME worklist resumes: settled terms are skipped, UNUSABLE ones retried. That is
     how the walled tail from 2026-08-15 gets finished.
  4. Export: samsSweepToCsv() -> q|n|lp|up|id. That column order is what build-sams-deals expects;
     changing it silently mis-parses the capture.
*/

const SAMS_STORAGE_KEY = 'TC_SAMS_SWEEP';

/*
  Mirrors stores.json -> Sam's Club -> pull_profile, which is the source of truth. The console has no
  filesystem, so the numbers are duplicated here and audit-pull-profiles.ps1 fails if they disagree.
  Still `proposed`, not `measured`: 2600+/-1400ms was derived from the ceiling we hit, not from a
  clean run. Never lower it to "just finish faster" - 2026-08-15 is what that costs.
*/
const SAMS_PROFILE = { delayMs: 2600, jitterMs: 1400, retries: 3, backoffMs: 20000, wallLimit: 3 };

const SAMS_WALL_PHRASES = [
  "let us know you're not a robot", 'are you a robot', 'verify you are a human',
  'px-captcha', 'access to this page has been denied', 'unusual traffic',
];

/**
 * Abort unless the live session is really on an OMAHA club. Sam's prices are per-club, so a sweep
 * against the wrong club is real data in the wrong basis -- the hardest failure to spot later,
 * because every number looks plausible.
 */
function samsIdentity() {
  const body = document.body.innerText || '';
  const club = (body.match(/\d{3,5}\s+[A-Za-z][^\n,]{0,40},?\s*(?:Omaha|OMAHA)[^\n]{0,20}/) || [])[0]
            || (body.match(/Omaha[^\n]{0,40}/) || [])[0];
  if (!club) {
    throw new Error(
      "REFUSING TO SWEEP: could not read an Omaha club from the page. Sam's prices are per-club; " +
      'set the club in the UI and confirm it is Omaha before pulling.'
    );
  }
  return { club: club.trim() };
}

/**
 * One search. Returns the three-state verdict.
 * A wall or a missing payload is UNUSABLE -- never EMPTY. EMPTY is reserved for a page we genuinely
 * read that listed nothing, which is the only case that licenses "Sam's returned no products".
 */
async function samsProbe(term) {
  const r = await fetch('https://www.samsclub.com/s/' + encodeURIComponent(term), { credentials: 'include' });
  if (r.status === 403 || r.status === 429) return { state: 'UNUSABLE', rows: [], why: 'http ' + r.status };
  const html = await r.text();
  const low = html.slice(0, 200000).toLowerCase();
  if (SAMS_WALL_PHRASES.some(p => low.includes(p))) return { state: 'UNUSABLE', rows: [], why: 'bot-wall' };

  const m = html.match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
  if (!m) return { state: 'UNUSABLE', rows: [], why: 'no-nextdata' };
  let data;
  try { data = JSON.parse(m[1]); } catch (e) { return { state: 'UNUSABLE', rows: [], why: 'nextdata-unparseable' }; }

  /*
    Walk the payload rather than pinning a path. Sam's reshapes the search response, and a pinned
    path degrades to "no products" -- which, without the three-state verdict, is indistinguishable
    from the store not carrying the item.
    linePrice = what one package costs. unitPrice = Sam's own per-unit rate, the independent
    cross-check audit-basis-reconcile uses. Capture BOTH or that guard has nothing to compare.
  */
  const rows = [];
  const seen = new Set();
  (function walk(node, depth) {
    if (!node || typeof node !== 'object' || depth > 12) return;
    if (Array.isArray(node)) { for (const v of node) walk(v, depth + 1); return; }
    const name = node.name || node.productName || node.title;
    const id   = node.productId || node.itemNumber || node.id;
    const lp   = node.linePrice ?? node.finalPrice?.unitPrice ?? node.price;
    const up   = node.unitPrice ?? node.pricePerUnit ?? node.unitOfMeasure?.price;
    if (name && id && lp != null && !seen.has(String(id))) {
      seen.add(String(id));
      rows.push({
        n:  String(name).replace(/[|\r\n]+/g, ' ').trim(),
        lp: typeof lp === 'object' ? (lp.amount ?? null) : lp,
        up: typeof up === 'object' ? (up.amount ?? null) : (up ?? null),
        id: String(id),
      });
    }
    for (const k of Object.keys(node)) walk(node[k], depth + 1);
  })(data, 0);

  return rows.length ? { state: 'MATCHES', rows } : { state: 'EMPTY', rows: [], why: 'store returned no products' };
}

const samsAgent = {
  storeName: "Sam's Club",
  storageKey: SAMS_STORAGE_KEY,
  profile: SAMS_PROFILE,
  assertIdentity: samsIdentity,
  probe: samsProbe,
};

const pullSamsInStore    = (worklist, opts) => runPacedSweep(samsAgent, worklist, opts);
const samsSweepToCsv     = () => sweepToCsv(SAMS_STORAGE_KEY, p => [p.n, p.lp ?? '', p.up ?? '', p.id ?? '']);
const samsSweepVerdicts  = () => sweepVerdicts(SAMS_STORAGE_KEY);
const samsSweepRemaining = wl => sweepRemaining(SAMS_STORAGE_KEY, wl);
