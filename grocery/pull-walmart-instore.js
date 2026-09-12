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

  *** THE STORE IS READ, AND IT COST TWO HAND QUARANTINES TO GET HERE (2026-09-12) ***
  This header used to say "Walmart has NO store toggle to assert -- prices are already the local
  store's -- so the identity check here is narrower than Fareway's or Aldi's", and called that
  asymmetry deliberate. The first half was true and the conclusion was wrong: "prices are already
  the local store's" is exactly why the store matters. Brad's session drifted to storeId 3153
  ("Omaha S 167th St Neighborhood Market") and this agent captured real, clean, plausible prices at
  it TWICE -- 414 rows on 2026-08-27 and 380 rows on 2026-09-12 -- and both times the only thing
  that noticed was a human reading the page header against a memory. Both had to be quarantined by
  hand. The board's sanctioned basis is storeId 5361, the L St Supercenter 68137 (Brad's ruling,
  grocery/out/walmart-store-ruling-2026-08-28.json), and 3153 is a smaller-assortment Neighborhood
  Market, so a NOT-CARRIED ruled there is false and a price read there is the right number in the
  wrong basis -- the hardest error to find later, because every figure still looks fine.

  So the store is READ from __NEXT_DATA__, at identity-assert time AND from every /search response,
  and it travels on every row (st/si/sz/sr) into a #tc-store line at the head of the capture. The
  per-response read is not belt-and-braces: pull-aldi-instore.js asserts per TERM because a session
  really does get flipped mid-sweep, and a sweep that asserts once cannot tell a flip from a clean
  run. A term whose response reads a different store records UNUSABLE rather than MATCHES, so the
  wrong-basis rows are never written at all, and build-walmart-deals.ps1 refuses a capture that
  cannot name its store. Switching the store back IS this agent's to do (Brad, 2026-08-28, in
  memory walmart-session-store-3153-drift) -- through his own Chrome, before capturing.

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

/*
  THE SANCTIONED STORE, MIRRORED. grocery/stores.json -> Walmart -> store_identity is canonical (it
  carries Brad's ruling and the drifted store it exists to refuse); a browser console cannot read a
  file, so this is a mirror, and build-walmart-deals.ps1's self-test FAILS when the two disagree -
  the same discipline audit-pull-profiles.ps1 applies to the pacing constants above, and for the same
  reason: a duplicated constant is the class where a shared-source fix ships nothing.
  The id is what discriminates. "Omaha" does not: 3153 is an Omaha address too.
*/
const WALMART_SANCTIONED_STORE = { id: '5361', zip: '68137', label: 'Omaha L St Supercenter' };

/*
  WHICH STORE THIS PAYLOAD IS PRICED FOR.
  The documented path is __NEXT_DATA__ pageMetadata.location.storeId (the 2026-08-28 ruling file
  names it, and the operator read 5361/68137/"Omaha L St Supercenter" there on 2026-09-12). It is
  read by WALKING for it rather than by that one path, for the reason this file's price extractor
  already gives three times over: Walmart has moved the shape of its payload under us repeatedly,
  and a single hard path that stops resolving returns undefined, which reads as "no store" and not
  as "we have gone blind".

  Candidates are SCORED, because more than one node can carry a storeId (an item's availability
  block does) and the one we want is the page's own location. Highest score wins; if two different
  storeIds tie at the top the answer is AMBIGUOUS, which is never the sanctioned id and so is
  refused downstream rather than resolved by a guess.
*/
function walmartStoreFromData(data) {
  const found = [];                                   // { id, zip, label, score }
  (function walk(node, key, depth) {
    if (!node || typeof node !== 'object' || depth > 14) return;
    if (Array.isArray(node)) { for (const v of node) walk(v, key, depth + 1); return; }
    const id = node.storeId ?? node.store_id;
    if (id != null && id !== '' && (typeof id === 'number' || typeof id === 'string')) {
      const zip = node.postalCode ?? node.postal_code ?? node.zipcode ?? node.zip ?? '';
      const label = node.displayName ?? node.name ?? node.storeName ?? node.label ?? '';
      let score = 1;
      if (zip) score = 2;
      if (zip && label) score = 3;
      if (String(key).toLowerCase() === 'location' || String(key).toLowerCase() === 'store') score += 2;
      found.push({ id: String(id).trim(), zip: String(zip).trim(), label: String(label).trim(), score: score });
    }
    for (const k of Object.keys(node)) walk(node[k], k, depth + 1);
  })(data, '', 0);

  if (!found.length) return null;
  const top = found.reduce((a, b) => (b.score > a.score ? b : a), found[0]);
  const rivals = new Set(found.filter(f => f.score === top.score).map(f => f.id));
  if (rivals.size > 1) {
    return { id: 'AMBIGUOUS', zip: '', label: 'payload names ' + rivals.size + ' stores at equal confidence (' + [...rivals].join(', ') + ')' };
  }
  return { id: top.id, zip: top.zip, label: top.label };
}

/** The same read against the page we are SITTING on, for the identity assert. */
function walmartStoreFromDocument() {
  const el = document.getElementById('__NEXT_DATA__');
  if (!el) return null;
  let data;
  try { data = JSON.parse(el.textContent || ''); } catch (e) { return null; }
  return walmartStoreFromData(data);
}

/* The store read when the sweep started. Every row falls back to it when its own /search response
   carried no store block, and the capture says so (read="page") rather than implying otherwise. */
let walmartAssertedStore = null;

/**
 * Confirm the origin, that we are not already walled, AND which store we are priced at.
 * Throws on a store we cannot read or a store that is not the sanctioned one - a wrong-basis sweep
 * is worse than no sweep, because its rows look right (see the header's two quarantines).
 */
function walmartIdentity() {
  if (!/(^|\.)walmart\.com$/.test(location.hostname)) {
    throw new Error(`REFUSING TO PULL: not on walmart.com (host is ${location.hostname}); fetch must be same-origin.`);
  }
  const body = (document.body.innerText || '').toLowerCase();
  if (WALMART_WALL_PHRASES.some(p => body.includes(p))) {
    throw new Error('REFUSING TO PULL: this page is already the bot interstitial. Clear it in the UI first.');
  }
  const where = walmartStoreFromDocument();
  if (!where) {
    throw new Error('REFUSING TO PULL: no storeId in this page\'s __NEXT_DATA__, so nothing here can say which store these prices are. Load a /search page in this tab and re-run; if a search page still carries no store block the payload shape has moved and walmartStoreFromData needs a look - do NOT capture blind.');
  }
  if (where.id !== WALMART_SANCTIONED_STORE.id) {
    throw new Error('REFUSING TO PULL: this session is on storeId ' + where.id + ' (' + (where.label || 'unnamed') + (where.zip ? ' ' + where.zip : '') + '), not the sanctioned ' +
      WALMART_SANCTIONED_STORE.id + ' ' + WALMART_SANCTIONED_STORE.label + ' ' + WALMART_SANCTIONED_STORE.zip +
      '. Prices here are real and in the WRONG BASIS - the 2026-08-27 and 2026-09-12 quarantines are both this. Switch the store in this browser first (that is this agent\'s to do, Brad 2026-08-28), then re-run.');
  }
  walmartAssertedStore = { id: where.id, zip: where.zip || WALMART_SANCTIONED_STORE.zip, label: where.label || WALMART_SANCTIONED_STORE.label };
  return {
    store: 'Walmart storeId ' + walmartAssertedStore.id + ' - ' + walmartAssertedStore.label + ' ' + walmartAssertedStore.zip,
    storeId: walmartAssertedStore.id,
    postalCode: walmartAssertedStore.zip,
    host: location.hostname,
  };
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

  /*
    THE STORE, PER RESPONSE (2026-09-12). Read from THIS payload, not from the assert at the top of
    the run: a session can be flipped mid-sweep, and the two quarantines in this file's header are
    what a once-per-run assert cannot see. pull-aldi-instore.js asserts per term for the same reason.

    A response that names a DIFFERENT store settles as UNUSABLE, never MATCHES. That is the whole
    point: rows read in the wrong basis are not written at all, so build-walmart-deals never has to
    decide about them. UNUSABLE also means runPacedSweep retries the term and sweepRemaining hands it
    back, so nothing is silently dropped - the verdict ledger names the store it refused.

    A response with NO store block falls back to the store read at assert time and is MARKED as such
    (sr='page'). That fallback is deliberate and it is a known blind spot, not a claim: a flip would
    be invisible for those rows. It is not silent - the rows carry read="page", the #tc-store line
    groups them separately, and the builder says out loud how many were attributed that way. The
    alternative, refusing every row whose response has no store block, would retire the whole lane
    on a payload shape nobody has measured yet.
  */
  const respStore = walmartStoreFromData(data);
  const asserted = walmartAssertedStore;
  let where, readFrom;
  if (respStore && respStore.id !== 'AMBIGUOUS') {
    where = respStore; readFrom = 'response';
    if (asserted && respStore.id !== asserted.id) {
      return { state: 'UNUSABLE', rows: [],
        why: 'store flipped mid-sweep: this response is priced for storeId ' + respStore.id + ' (' + (respStore.label || 'unnamed') + ') and the sweep asserted ' + asserted.id + ' (' + asserted.label + '). Refusing to record prices in the wrong basis - switch the store back and re-run this term.' };
    }
    /*
      THE NAME IS NOT IN THE PAYLOAD, MEASURED (2026-09-12, live /search?q=anaheim peppers through
      Brad's Chrome: HTTP 200, 876,030 bytes, 61 item nodes). The store block carries storeId and
      postalCode and NO display name, while 130 item nodes carry storeId 0 - so the scoring above
      picks the page location (score 4) over those (score 1), tie count 1, and the label comes back
      empty. The capture line still has to be readable, so the NAME falls back to the store we
      asserted - which is truthful exactly because a response naming a different ID was already
      refused above. The ID and the ZIP are always the read ones; only the display name is borrowed.
    */
    const named = where.label ||
      (asserted && asserted.id === where.id ? asserted.label : '') ||
      (where.id === WALMART_SANCTIONED_STORE.id ? WALMART_SANCTIONED_STORE.label : 'name not in payload');
    where = { id: where.id, zip: where.zip || (asserted && asserted.id === where.id ? asserted.zip : ''), label: named };
  } else if (respStore && respStore.id === 'AMBIGUOUS') {
    return { state: 'UNUSABLE', rows: [],
      why: 'cannot say which store this response is priced for - ' + respStore.label + '. Refusing to record prices we cannot attribute.' };
  } else if (asserted) {
    where = asserted; readFrom = 'page';
  } else {
    // No store in the response and no assert to fall back on: walmartIdentity() was bypassed, which
    // is how both quarantined captures happened. A row with no store is not a row worth keeping.
    return { state: 'UNUSABLE', rows: [],
      why: 'no store in this response and no asserted store to fall back on - walmartIdentity() never ran. Run the sweep through pullWalmartInStore, which asserts the store first.' };
  }

  const rows = [];
  const seen = new Set();
  (function walk(node, depth) {
    if (!node || typeof node !== 'object' || depth > 12) return;
    if (Array.isArray(node)) { for (const v of node) walk(v, depth + 1); return; }
    const name = node.name || node.title;
    const id = node.usItemId || node.productId || node.id;
    /*
      THREE PRICE SHAPES, AND WE READ ALL OF THEM (2026-08-22, third added 2026-09-02).
      This read only the OBJECT shape - priceInfo.currentPrice.price / priceDetails.priceLines[0].price.
      Measured against a live /search?q=milk that returned 1.3 MB with 119 usItemId nodes and 69
      priceInfo nodes, this extractor kept ZERO rows: the payload now carries

          priceInfo = { linePrice: "$1.74", linePriceDisplay: "$1.74", unitPrice: "2.7 c/fl oz",
                        wasPrice: "", savingsAmt: 0, ... }

      - flat STRINGS, not nested objects with numeric .price. Neither old path exists on it, so every
      term came back as a store that carries no milk.

      Both of those shapes are kept because both have been real: this file's own header documents
      priceDetails.priceLines as "Walmart's own structure", and it may well be what a different
      response variant still returns. Reading both is cheap; guessing which era we are in is not.
      A third shape arrived on 2026-09-02 and the same rule applied - see the note below money().
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
    /*
      THE THIRD SHAPE, AND WHY `??` HAD TO GO (2026-09-02).
      Measured on a live /search?q=miracle whip from Chrome: every flat field this file learned to
      read in August is now the EMPTY STRING - linePrice, linePriceDisplay, itemPrice, unitPrice and
      wasPrice are all "" - and priceInfo.currentPrice is undefined. The price moved one level down,
      into priceDetails.priceLines as {lineType, values:[{key, value}]}:

          { lineType: 'CURRENT_PRICE', values: [{ key: 'PRICE',       value: '8.97'         }] }
          { lineType: 'UNIT_PRICE',    values: [{ key: 'UNIT_PRICE',  value: '18.7 c/fl oz' }] }

      The value carries NO dollar sign, so the "$n" synthesis below is what makes it survive
      build-walmart-deals' Build-Row - which is the same trap already documented above it.

      Adding the new path is the small half of the fix. The structural half is the candidate LIST.
      The old `??` chain could not have reached priceDetails even with a path added: the new
      priceLine has no `.price` (the number is under values[]), so the chain fell through to
      linePrice - and `??` only falls through on null/undefined, so the EMPTY STRING won, money("")
      returned undefined, and all 127 item nodes were dropped. Against a payload whose absent fields
      are "" rather than absent, `??` is the wrong operator entirely. So candidates are now ordered
      and the first one money() can PARSE wins, which no "" can ever do.

      All three shapes stay, newest first, for the reason the 2026-08-22 note gives: each has been
      real, reading them all is cheap, and guessing which era a given response is from is not.
    */
    const detail = (lineType, key) => {
      const line = (node.priceInfo?.priceDetails?.priceLines || []).find(l => l && l.lineType === lineType);
      const v = (line?.values || []).find(x => x && x.key === key)?.value;
      return v === '' || v == null ? undefined : v;
    };
    const lines = node.priceInfo?.priceDetails?.priceLines || node.priceInfo?.currentPrice;
    const lpRaw = [
      detail('CURRENT_PRICE', 'PRICE'),
      node.priceInfo?.currentPrice?.price,
      Array.isArray(lines) ? lines[0]?.price : undefined,
      node.priceInfo?.linePrice,
      node.priceInfo?.linePriceDisplay,
    ].find(v => money(v) != null);
    const lpNum = money(lpRaw);
    const lp = lpNum == null ? undefined
      : (typeof lpRaw === 'string' && lpRaw.includes('$') ? lpRaw.trim() : '$' + lpNum.toFixed(2));
    // unitPrice is a DISPLAY STRING in the flat shape ("2.7 c/fl oz"). Kept verbatim rather than
    // parsed to a number: the basis ("/fl oz") is half the fact, and a bare 2.7 beside a $/lb rival
    // is the unit-mismatch error this estate has already paid for at three stores.
    // Same ordered-candidate rule, and for the same reason: priceInfo.unitPrice is "" in the third
    // shape, so a `??` chain would return the empty string and we would report no unit price at all.
    const up = [
      detail('UNIT_PRICE', 'UNIT_PRICE'),
      node.priceInfo?.unitPrice?.price,
      typeof node.priceInfo?.unitPrice === 'string' ? node.priceInfo.unitPrice : undefined,
      node.priceInfo?.unitPriceDisplayCondition,
    ].find(v => v != null && v !== '');
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
    // Third shape again: wasPrice is "" and the was-price, when there is one, is a WAS_PRICE line.
    // An unparseable candidate must not win here either - "" travelling into the was column would
    // read as a marked-down row with no base price, and rollback-ttl-lib would anchor a TTL on it.
    const wasRaw = [
      detail('WAS_PRICE', 'WAS_PRICE'),
      node.priceInfo?.wasPrice?.price,
      node.priceInfo?.wasPrice,
      // the object shape the emit below unwraps with .amount - kept a candidate so that branch stays live
    ].find(v => money(v) != null || (v && typeof v === 'object' && v.amount != null));
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
        // THE STORE TRAVELS WITH THE ROW, the way aldiSearchProbe puts st/md on each row. These do
        // NOT become CSV columns - walmartSweepToCsv counts them off into the #tc-store header, so
        // the 9-column positional contract build-walmart-deals has always read is untouched.
        st: where.label,
        si: where.id,
        sz: where.zip,
        sr: readFrom,
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
/* q|n|lp|up|id|was|rb|sel|ff - the first five are the contract build-walmart-deals has always read
   positionally; was/rb/sel/ff are appended so an older builder ignores them rather than mis-parsing.
   sel/ff use `?? ''` and NOT a default: empty is the honest encoding of "the node did not say".

   THE STORE TRAVELS WITH THE CAPTURE (2026-09-12), exactly as aldiSearchToCsv does it - that file's
   header documents each decision and this is the same shape for the same reason. The output OPENS
   with one line per distinct store the sweep actually read, counted off the st/si/sz/sr the probe put
   on each row, then the column header:

       #tc-store store="Omaha L St Supercenter" id="5361" zip="68137" read="response" rows=774
       q|n|lp|up|id|was|rb|sel|ff

   A row with no store (persisted by an agent older than this) is counted as id="UNRECORDED" and is
   never folded into a store it was not read at. read="page" marks rows attributed from the
   identity-assert read because their own response carried no store block - see walmartProbe.
   build-walmart-deals.ps1 refuses a capture with no store line, an UNRECORDED one, one that is not
   the sanctioned store, or one that straddles two stores, and writes its `source` stamp from the
   line instead of the literal it used to carry. The line holds no '|', so the pipe-splitting readers
   of these files skip it as a short line. POST THIS OUTPUT UNCHANGED: it already has its column
   header, so do not prepend a second one. */
const WALMART_CAPTURE_COLUMNS = 'q|n|lp|up|id|was|rb|sel|ff';
// The NUL strip is not decoration: it is the group key's separator below, and a store name carrying
// one would split into the wrong number of fields.
const walmartStoreField = s => String(s == null ? '' : s).replace(/["|\r\n\u0000]/g, ' ').replace(/\s+/g, ' ').trim();

const walmartSweepToCsv = () => {
  const res = JSON.parse(localStorage.getItem(WALMART_STORAGE_KEY) || '{}');
  const out = [];
  const stores = new Map();          // id + NUL + zip + NUL + label + NUL + read -> row count, first-read order
  for (const [term, r] of Object.entries(res)) {
    if (r.v !== 'MATCHES') continue;
    for (const p of r.rows) {
      const k = [walmartStoreField(p.si) || 'UNRECORDED', walmartStoreField(p.sz),
                 walmartStoreField(p.st) || 'UNRECORDED', walmartStoreField(p.sr) || 'UNRECORDED'].join('\u0000');
      stores.set(k, (stores.get(k) || 0) + 1);
      out.push([term, p.n, p.lp ?? '', p.up ?? '', p.id ?? '', p.was ?? '', p.rb ?? 0, p.sel ?? '', p.ff ?? ''].join('|'));
    }
  }
  const head = [];
  for (const [k, n] of stores.entries()) {
    const [id, zip, label, read] = k.split('\u0000');
    head.push('#tc-store store="' + label + '" id="' + id + '" zip="' + zip + '" read="' + read + '" rows=' + n);
  }
  return head.concat([WALMART_CAPTURE_COLUMNS], out).join('\n');
};
const walmartSweepVerdicts  = () => sweepVerdicts(WALMART_STORAGE_KEY);
const walmartSweepRemaining = wl => sweepRemaining(WALMART_STORAGE_KEY, wl);
