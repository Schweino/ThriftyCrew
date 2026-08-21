/*
  pull-walmart-instore.js  --  Walmart price agent.

  Runs on pull-agent-lib.js -- paste that file into the console FIRST, then this one.

  WHY THIS EXISTS
  ---------------
  Walmart hit a "Robot or human?" wall during the 2026-08-15 refresh and the rate that triggered it
  was never recorded, because the sweep was an ad-hoc snippet with no instrumentation. That is the
  same failure that cost the Sam's sweep 389 of 595 term-pairs: without a timing ledger there is
  nothing to tune, and without the three-state verdict a blocked search is indistinguishable from a
  store that does not carry the item.

  Walmart has NO store toggle to assert -- prices are already the local store's -- so the identity
  check here is narrower than Fareway's or Aldi's: it only confirms we are on walmart.com and NOT
  already sitting on the interstitial. That asymmetry is deliberate; do not add a fake store assert
  to make the four agents look uniform.

  PRICE SHAPE: priceInfo.priceDetails.priceLines is Walmart's own structure (see stores.json capture
  note). Read the current price, and keep the unit price where Walmart states one -- it is the
  independent cross-check audit-basis-reconcile uses. Walmart's own unit price is provably wrong
  sometimes, so it is evidence, never an oracle: the product NAME wins on conflict.

  PACING: unmeasured, and deliberately the most conservative of the four. Walmart walled us once
  already at an unknown rate, so this starts slower than Sam's rather than faster.
*/

const WALMART_STORAGE_KEY = 'TC_WALMART_SWEEP';

/* Mirrors stores.json -> Walmart -> pull_profile. audit-pull-profiles.ps1 fails if they disagree. */
const WALMART_PROFILE = { delayMs: 3500, jitterMs: 2000, retries: 3, backoffMs: 30000, wallLimit: 3 };

const WALMART_WALL_PHRASES = [
  'robot or human', 'are you a robot', 'verify your identity',
  'access denied', 'unusual traffic', 'px-captcha',
];

/** Walmart has no store selector to assert - only confirm the origin and that we are not already walled. */
function walmartIdentity() {
  if (!/(^|\.)walmart\.com$/.test(location.hostname)) {
    throw new Error(`REFUSING TO PULL: not on walmart.com (host is ${location.hostname}); fetch must be same-origin.`);
  }
  const body = (document.body.innerText || '').toLowerCase();
  if (WALMART_WALL_PHRASES.some(p => body.includes(p))) {
    throw new Error('REFUSING TO PULL: this page is already the bot interstitial. Clear it in the UI first.');
  }
  return { store: 'Walmart (local store pricing; no store toggle to assert)', host: location.hostname };
}

async function walmartProbe(term) {
  const r = await fetch('/search?q=' + encodeURIComponent(term), { credentials: 'include' });
  if (r.status === 403 || r.status === 429) return { state: 'UNUSABLE', rows: [], why: 'http ' + r.status };
  const html = await r.text();
  const low = html.slice(0, 200000).toLowerCase();
  if (WALMART_WALL_PHRASES.some(p => low.includes(p))) {
    return { state: 'UNUSABLE', rows: [], why: 'bot-wall' };
  }

  const m = html.match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
  if (!m) {
    // No payload and no wall phrase: a soft block or a page-shape change. Either way we did NOT
    // observe the catalog, so this is UNUSABLE. Recording EMPTY here would assert Walmart carries
    // nothing matching the term, which we have no evidence for.
    return { state: 'UNUSABLE', rows: [], why: 'no-nextdata' };
  }

  let data;
  try { data = JSON.parse(m[1]); } catch (e) { return { state: 'UNUSABLE', rows: [], why: 'nextdata-unparseable' }; }

  const rows = [];
  const seen = new Set();
  (function walk(node, depth) {
    if (!node || typeof node !== 'object' || depth > 12) return;
    if (Array.isArray(node)) { for (const v of node) walk(v, depth + 1); return; }
    const name = node.name || node.title;
    const id = node.usItemId || node.productId || node.id;
    const lines = node.priceInfo?.priceDetails?.priceLines || node.priceInfo?.currentPrice;
    const lp = node.priceInfo?.currentPrice?.price ?? (Array.isArray(lines) ? lines[0]?.price : undefined);
    const up = node.priceInfo?.unitPrice?.price ?? node.priceInfo?.unitPriceDisplayCondition;
    /*
      THE ROLLBACK, CAPTURED (2026-08-21). Brad: "for walmart and sams, a rollback price we just stick
      with a 30 day TTL from when we first detect". Nothing could anchor that TTL because this capture
      recorded only the current price - a rollback and an ordinary everyday price arrived identical, so
      a cut price entered the board as EVERYDAY and never expired.

      Walmart publishes no end date for one. Measured on a live butter search: the ROLLBACK badge
      carries __typename/key/text/type/id/styleId and nothing temporal, promoData holds only an AFFIRM
      financing entry, promoDiscount is null, eventAttributes is {priceFlip:false, specialBuy:false}.
      What it DOES publish is priceInfo.wasPrice ($5.96 against a $4.87 line price) plus a ROLLBACK
      badge flag, and those two together are enough to say "this is a discount" honestly.

      So capture the was-price and the badge; rollback-ttl-lib anchors the window to the first day we
      saw it and refuses to re-anchor on re-sighting, which is what stops a 30-day TTL becoming
      infinite. Emitted as extra CSV columns - build-walmart-deals reads q|n|lp|up|id positionally, so
      appending is safe and an older builder simply ignores them.
    */
    const wasRaw = node.priceInfo?.wasPrice?.price ?? node.priceInfo?.wasPrice;
    const was = typeof wasRaw === 'object' ? (wasRaw?.amount ?? null) : (wasRaw ?? null);
    const rb = !!(node.badges?.flags || []).find(f => f && f.key === 'ROLLBACK');
    if (name && id && lp != null && !seen.has(String(id))) {
      seen.add(String(id));
      rows.push({
        n: String(name).replace(/[|\r\n]+/g, ' ').trim(),
        lp: typeof lp === 'object' ? (lp.amount ?? null) : lp,
        up: typeof up === 'object' ? (up.amount ?? null) : (up ?? null),
        id: String(id),
        was: was,
        rb: rb ? 1 : 0,
      });
    }
    for (const k of Object.keys(node)) walk(node[k], depth + 1);
  })(data, 0);

  return rows.length ? { state: 'MATCHES', rows } : { state: 'EMPTY', rows: [], why: 'store returned no products' };
}

const walmartAgent = {
  storeName: 'Walmart',
  storageKey: WALMART_STORAGE_KEY,
  profile: WALMART_PROFILE,
  assertIdentity: walmartIdentity,
  probe: walmartProbe,
};

const pullWalmartInStore    = (worklist, opts) => runPacedSweep(walmartAgent, worklist, opts);
// q|n|lp|up|id|was|rb - the first five are the contract build-walmart-deals has always read
// positionally; was/rb are appended so an older builder ignores them rather than mis-parsing.
const walmartSweepToCsv     = () => sweepToCsv(WALMART_STORAGE_KEY, p => [p.n, p.lp ?? '', p.up ?? '', p.id ?? '', p.was ?? '', p.rb ?? 0]);
const walmartSweepVerdicts  = () => sweepVerdicts(WALMART_STORAGE_KEY);
const walmartSweepRemaining = wl => sweepRemaining(WALMART_STORAGE_KEY, wl);
