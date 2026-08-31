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
    return { state: 'UNUSABLE', rows: [], why: wallWhy(html, WALMART_WALL_PHRASES) };
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
    /*
      TWO PRICE SHAPES, AND WE READ BOTH (2026-08-22).
      This read only the OBJECT shape - priceInfo.currentPrice.price / priceDetails.priceLines[0].price.
      Measured against a live /search?q=milk that returned 1.3 MB with 119 usItemId nodes and 69
      priceInfo nodes, this extractor kept ZERO rows: the payload now carries

          priceInfo = { linePrice: "$1.74", linePriceDisplay: "$1.74", unitPrice: "2.7 c/fl oz",
                        wasPrice: "", savingsAmt: 0, ... }

      - flat STRINGS, not nested objects with numeric .price. Neither old path exists on it, so every
      term came back as a store that carries no milk.

      Both shapes are kept because both have been real: this file's own header documents
      priceDetails.priceLines as "Walmart's own structure", and it may well be what a different
      response variant still returns. Reading both is cheap; guessing which era we are in is not.
    */
    const money = v => {
      if (v == null || v === '') return undefined;
      if (typeof v === 'number') return v;
      const m2 = String(v).match(/([\d,]+\.?\d*)/);
      return m2 ? parseFloat(m2[1].replace(/,/g, '')) : undefined;
    };
    /*
      lp MUST REACH THE CSV AS A "$x.xx" STRING, NOT A NUMBER.
      build-walmart-deals' Build-Row parses it with [regex]::Match($raw.lp, '\$\s*([\d,]+...)') and
      rejects anything without the dollar sign. A first version of this fix ran every candidate
      through money() and emitted bare floats: the capture looked perfect (333 rows, 7/7 MATCHES)
      and the builder rejected all 333 with "no linePrice". The price was right and the SHAPE was
      wrong, which is the harder failure to see because nothing in the capture looks broken.
      So: keep the display string when the payload gives one, and only synthesise "$n" from a
      numeric shape. money() stays, but as the VALIDATOR - it decides whether we have a price at
      all, while the string is what travels.
    */
    const lines = node.priceInfo?.priceDetails?.priceLines || node.priceInfo?.currentPrice;
    const lpRaw = node.priceInfo?.currentPrice?.price
      ?? (Array.isArray(lines) ? lines[0]?.price : undefined)
      ?? node.priceInfo?.linePrice
      ?? node.priceInfo?.linePriceDisplay;
    const lpNum = money(lpRaw);
    const lp = lpNum == null ? undefined
      : (typeof lpRaw === 'string' && lpRaw.includes('$') ? lpRaw.trim() : '$' + lpNum.toFixed(2));
    // unitPrice is a DISPLAY STRING in the flat shape ("2.7 c/fl oz"). Kept verbatim rather than
    // parsed to a number: the basis ("/fl oz") is half the fact, and a bare 2.7 beside a $/lb rival
    // is the unit-mismatch error this estate has already paid for at three stores.
    const up = node.priceInfo?.unitPrice?.price
      ?? (typeof node.priceInfo?.unitPrice === 'string' ? node.priceInfo.unitPrice : undefined)
      ?? node.priceInfo?.unitPriceDisplayCondition;
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
    /*
      THE SHELF SIGNAL (2026-08-31). sellerName and fulfillmentType sit on the SAME item node we
      already read for name and price - walmart-capture-reducer.js has read them since July for
      import-walmart-batch's 3P filter, so this is not new extraction; it is the DAILY path finally
      carrying what the manual path already had.

      WHY IT IS WORTH TWO COLUMNS. Three generations of per-product known-wrong rulings failed to
      converge on the marketplace-bulk class (Frontier Co-op 16 oz -> 27 Peaks 12-19 oz -> Badia /
      24 Mantra), because a ruling names a PRODUCT and the defect is a LISTING KIND: curry-powder was
      blocked at Frontier's $0.7669/oz and came straight back at 27 Peaks' $0.7775/oz. Every proxy
      tried - brand absence, exact-item absence, size shape - stood in for one fact that was on the
      page and not in our data: is this listing purchasable at the L St store, or does it only ship?
      Spec: design\BRIEF-marketplace-shelf-signal-2026-08-29.md.

      EMIT EMPTY RATHER THAN GUESSING. A node with no sellerName or no fulfillmentType writes the
      field EMPTY. Empty means UNKNOWN and every consumer admits the row; it must never be filled
      with a default, because "" and "SHIP" are about to mean opposite things. build-walmart-deals
      already reads a 7-column capture's sel/ff as empty for exactly this reason.
    */
    const sel = node.sellerName ?? '';
    const ff  = (node.fulfillmentType ?? '');
    if (name && id && lp != null && !seen.has(String(id))) {
      seen.add(String(id));
      rows.push({
        n: String(name).replace(/[|\r\n]+/g, ' ').trim(),
        lp: typeof lp === 'object' ? (lp.amount ?? null) : lp,
        up: typeof up === 'object' ? (up.amount ?? null) : (up ?? null),
        id: String(id),
        was: was,
        rb: rb ? 1 : 0,
        sel: String(sel).replace(/[|\r\n]+/g, ' ').trim(),
        ff: String(ff).replace(/[|\r\n]+/g, ' ').trim().toUpperCase(),
      });
    }
    for (const k of Object.keys(node)) walk(node[k], depth + 1);
  })(data, 0);

  if (rows.length) return { state: 'MATCHES', rows };

  /*
    BLINDNESS IS NOT EMPTINESS (2026-08-22) - the same rule pull-fareway-instore.js learned the hard
    way, arriving here for the same reason. EMPTY is a claim about the STORE: "we read the page and
    it listed nothing", which downstream treats as a NOT-CARRIED ruling and will retire the cell.
    We may only say that when we actually READ a product listing and it was bare.

    The tell that we did not: the payload is full of products but none survived extraction. On
    2026-08-22 a price-shape change did exactly this - 119 usItemId nodes, 69 priceInfo nodes, and
    zero rows kept, reported as seven consecutive stores-carry-nothing. So count what we SAW: if the
    page held item nodes and we still kept none, the parser is the thing that failed, not Walmart's
    shelf, and UNUSABLE is the honest verdict - it halts loudly instead of poisoning the catalog.
  */
  let itemNodes = 0;
  (function count(node, depth) {
    if (!node || typeof node !== 'object' || depth > 12) return;
    if (Array.isArray(node)) { for (const v of node) count(v, depth + 1); return; }
    if (node.usItemId || node.priceInfo) itemNodes++;
    for (const k of Object.keys(node)) count(node[k], depth + 1);
  })(data, 0);

  if (itemNodes > 0) {
    return {
      state: 'UNUSABLE', rows: [],
      why: `parser kept 0 rows from a page holding ${itemNodes} item node(s) - the price shape moved, ` +
           `this is our blindness and NOT evidence that Walmart carries nothing`,
    };
  }
  return { state: 'EMPTY', rows: [], why: 'store returned no products' };
}

const walmartAgent = {
  storeName: 'Walmart',
  storageKey: WALMART_STORAGE_KEY,
  profile: WALMART_PROFILE,
  assertIdentity: walmartIdentity,
  probe: walmartProbe,
};

const pullWalmartInStore    = (worklist, opts) => runPacedSweep(walmartAgent, worklist, opts);
// q|n|lp|up|id|was|rb|sel|ff - the first five are the contract build-walmart-deals has always read
// positionally; was/rb/sel/ff are appended so an older builder ignores them rather than mis-parsing.
// sel/ff use `?? ''` and NOT a default: empty is the honest encoding of "the node did not say".
const walmartSweepToCsv     = () => sweepToCsv(WALMART_STORAGE_KEY, p => [p.n, p.lp ?? '', p.up ?? '', p.id ?? '', p.was ?? '', p.rb ?? 0, p.sel ?? '', p.ff ?? '']);
const walmartSweepVerdicts  = () => sweepVerdicts(WALMART_STORAGE_KEY);
const walmartSweepRemaining = wl => sweepRemaining(WALMART_STORAGE_KEY, wl);
