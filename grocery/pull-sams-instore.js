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
  if (SAMS_WALL_PHRASES.some(p => low.includes(p))) return { state: 'UNUSABLE', rows: [], why: wallWhy(html, SAMS_WALL_PHRASES) };

  const m = html.match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
  if (!m) return { state: 'UNUSABLE', rows: [], why: 'no-nextdata' };
  let data;
  try { data = JSON.parse(m[1]); } catch (e) { return { state: 'UNUSABLE', rows: [], why: 'nextdata-unparseable' }; }

  /*
    THE PRICE PAIR LIVES ON item.priceInfo, NOT ON THE ITEM (2026-08-15).
    A first version walked for any node carrying a name + id and read `node.linePrice ?? node.price`.
    `linePrice` is one level down under `priceInfo`, so that always fell through to `node.price` -- a
    bare number -- and never captured `unitPrice` at all. The PRICES were right (item.price is exactly
    priceInfo.linePrice, verified across a search page), but a capture with no unitPrice is WORTHLESS:
    build-sams-deals derives size as lp/up and rejects every row with `err='no unitPrice'`. A whole
    388-term sweep would have produced 7,298 rows and published nothing.

    So: walk to the item nodes and read the pair off priceInfo, keeping Sam's OWN STRING FORMS
    ("$6.22", "$1.55/lb"). The builder parses the "$n/unit" shape directly; converting to numbers here
    would throw away the unit of measure, which is the whole point of capturing it.
    unitPrice is also the independent cross-check audit-basis-reconcile uses. Capture BOTH or that
    guard has nothing to compare.
  */
  const rows = [];
  const seen = new Set();
  (function walk(node, depth) {
    if (!node || typeof node !== 'object' || depth > 14) return;
    if (Array.isArray(node)) { for (const v of node) walk(v, depth + 1); return; }

    const pi = node.priceInfo;
    if (pi && (pi.linePrice != null)) {
      const name = node.name || node.productName || node.title;
      const id   = node.productId || node.itemNumber || node.id;
      if (name && id && !seen.has(String(id))) {
        seen.add(String(id));
        /*
          THE ROLLBACK / INSTANT-SAVINGS PRICE (2026-08-21). Same reason as Walmart: Brad's 30-day TTL
          runs "from when we first detect", and nothing could detect one because this capture recorded
          only what you pay today. A cut price and an everyday price arrived identical, so a discount
          entered the board as EVERYDAY and never expired.
          Sam's publishes no end date either - measured on a live butter search, the payload contains
          ZERO date-shaped values and every key matching /Expir/ is session, cache or consent related.
          It does expose a strikethrough / was-price, which is enough to say "this is a discount"
          honestly and hand rollback-ttl-lib something to anchor.
          Recorded honestly: "Instant Savings" did not appear for that term, so that specific mechanism
          is UNTESTED rather than absent; whatever field carries it will surface here as a was-price.
        */
        const wasRaw = pi.wasPrice ?? pi.strikethroughPrice ?? pi.listPrice ?? null;
        rows.push({
          n:  String(name).replace(/[|\r\n]+/g, ' ').trim(),
          lp: pi.linePrice,          // "$14.98" - keep the string, the builder parses it
          up: pi.unitPrice ?? null,  // "$0.09/ea" - unit of measure must survive
          id: String(id),
          was: (typeof wasRaw === 'object' && wasRaw) ? (wasRaw.amount ?? null) : wasRaw,
        });
      }
      return;                        // do not descend into a priced item and re-match its children
    }
    for (const k of Object.keys(node)) walk(node[k], depth + 1);
  })(data, 0);

  if (rows.length) assertSamsRowContract(rows[0]);
  return rows.length ? { state: 'MATCHES', rows } : { state: 'EMPTY', rows: [], why: 'store returned no products' };
}

/*
  FAIL FAST ON A SHAPE THE BUILDER CANNOT EAT (2026-08-15).
  The first version of this agent swept all 388 terms, produced 7,298 rows, and every one of them
  would have been rejected by build-sams-deals with err='no unitPrice' - a 35-minute run worth
  nothing, discovered only at build time. The capture contract is narrow and knowable, so check it on
  the FIRST priced row and throw immediately rather than at the end of a sweep.
  Contract (build-sams-deals.ps1 header): q|n|lp|up|id, lp = "$14.98", up = "$0.09/ea".
*/
function assertSamsRowContract(row) {
  /*
    Check the SHAPE, never the completeness. A blank unitPrice is real Sam's data - plenty of single
    items carry `"unitPrice":""` - and build-sams-deals already handles that correctly by rejecting
    just that ROW with err='no unitPrice'. A first version treated "" as a violation and threw, which
    marked whole terms UNUSABLE ("ant roach killer spray", "arm and hammer detergent") purely because
    their first row happened to lack a unit price. That is the guard inventing a blockage, and worse,
    UNUSABLE is the state that means "we never got to look" - so an over-strict gate manufactures the
    exact false signal the three-state contract exists to prevent.

    The systematic failure this gate is FOR is `lp` arriving as a bare number instead of "$14.98",
    which is what happens when the extractor reads node.price instead of node.priceInfo.linePrice.
    So: lp must be a "$n" string. up may be absent, blank, or a well-formed "$n/unit".
  */
  const lpOk = typeof row.lp === 'string' && /^\$\s*[\d,]+(\.\d{1,3})?$/.test(row.lp);
  const upOk = row.up == null || row.up === '' ||
               (typeof row.up === 'string' && /^\$\s*[\d,]+(\.\d{1,3})?\s*\/\s*.+$/.test(row.up));
  if (!lpOk || !upOk) {
    throw new Error(
      'ROW CONTRACT VIOLATED - build-sams-deals would reject this capture wholesale. ' +
      `lp=${JSON.stringify(row.lp)} (want "$14.98"), up=${JSON.stringify(row.up)} (want "$0.09/ea", "" or null). ` +
      'Fix the extractor before sweeping; a whole run of this shape publishes nothing.'
    );
  }
}

const samsAgent = {
  storeName: "Sam's Club",
  storageKey: SAMS_STORAGE_KEY,
  profile: SAMS_PROFILE,
  assertIdentity: samsIdentity,
  probe: samsProbe,
};

const pullSamsInStore    = (worklist, opts) => runPacedSweep(samsAgent, worklist, opts);
// q|n|lp|up|id|was - the first five are build-sams-deals' long-standing positional contract.
const samsSweepToCsv     = () => sweepToCsv(SAMS_STORAGE_KEY, p => [p.n, p.lp ?? '', p.up ?? '', p.id ?? '', p.was ?? '']);
const samsSweepVerdicts  = () => sweepVerdicts(SAMS_STORAGE_KEY);
const samsSweepRemaining = wl => sweepRemaining(SAMS_STORAGE_KEY, wl);
