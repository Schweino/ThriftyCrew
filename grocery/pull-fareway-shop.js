/*
  pull-fareway-shop.js  --  Fareway storefront extractor, read from the APOLLO CACHE.

  WHY THIS FILE EXISTS AT ALL. Every other store's extractor lives in a file; Fareway's did not. It was
  pasted into the browser by hand each session, so it could not be reviewed, could not be diffed, and
  could not be fixed once - which is how it went a whole quarter emitting a was-price with no end date
  beside it while the page it was reading said "Sale ends in 1 day" three inches away.

  WHY THE CACHE AND NOT THE TILES. shop.fareway.com is fully client-rendered (see pull-fareway-instore.js
  for the day the fetch-and-regex probe went blind). The rendered tiles carry the name and the price, but
  measured 2026-08-21 on the "pork ribs" results page:
        document.body.innerText   contains "Sale ends"   ->  NO
        __APOLLO_CLIENT__ cache   contains "Sale ends"   ->  YES, as saleDisclaimerString
  The end date is never painted into the DOM. A DOM extractor cannot see it no matter how it is written,
  so this reads window.__APOLLO_CLIENT__.cache.extract() and takes name, price, was-price, unit, size,
  product id and the disclaimer from ONE node - which also means they cannot be mis-joined to each other.

  WHAT saleDisclaimerString ACTUALLY COVERS, measured, not assumed. On that same page:
        79 items,  47 carrying a was-price (a real markdown),  6 carrying "Sale ends in N day(s)"
  All six were MEAT. The packaged markdowns (barbecue sauce, canned beans) carry a was-price and no end
  date at all. So this closes the dating gap for Fareway's weekly meat ad and NOT for the rest, and the
  30-day TTL still has to cover what is left. Do not read a low sale_ends_days count as a broken sweep.

  A DISCLAIMER IS NOT ALWAYS A DATE. The same field also carries multibuy conditions - "Add 2 to qualify
  for deal" appeared 3 times on that page. Only the "Sale ends in N day(s)" / "Sale ends today" shapes are
  parsed; everything else is recorded verbatim in sale_note and dates nothing. Parsing a multibuy string
  as a window is how a deal that has no end date acquires a confident one.

  THE ARITHMETIC IS RELATIVE, SO THE CAPTURE DATE IS PART OF THE READING. "Sale ends in 1 day" means
  today + 1, and it means something different tomorrow. This emits sale_ends_days (the integer we read)
  rather than a date, and the builder turns it into a date using the extract's OWN as_of. Storing a date
  computed here would launder a stale capture into a fresh-looking window - the `dates written, not
  measured` failure, which surfaces as a wrong PRICE.
  Verified against an independent source before shipping: on 2026-08-21 the ribs read "Sale ends in 1
  day" -> 2026-08-22, and out\fareway\fareway-deals-2026-08-20.json independently states the weekly ad
  runs 2026-08-17 to 2026-08-22.

  USAGE (in Brad's Chrome, on a shop.fareway.com search results page):
      farewayShopExtract('pork ribs')        -> [{ id, term, name, price, per, orig, unit, size, url,
                                                   sale_ends_days, sale_note }, ...]
  Window functions do NOT survive navigation - re-inline this after every navigate.
*/

/** Parse "Sale ends in 3 days" / "Sale ends in 1 day" / "Sale ends today" -> integer days, else null. */
function farewaySaleEndsDays(s) {
  if (!s || typeof s !== 'string') return null;
  const t = s.trim();
  if (/^sale ends today\b/i.test(t)) return 0;
  const m = t.match(/^sale ends in\s+(\d{1,2})\s+days?\b/i);
  if (!m) return null;                     // "Add 2 to qualify for deal" and friends land here, correctly
  const n = parseInt(m[1], 10);
  // A sanity bound, not a guess: Fareway runs a weekly flyer and a ~4-week monthly one. Anything claiming
  // more than 60 days is not a sale window and must not become one.
  if (!isFinite(n) || n < 0 || n > 60) return null;
  return n;
}

/** Walk the normalized cache and return every node that carries a price viewSection. */
function farewayItemNodes(root) {
  const out = [];
  const seen = new Set();
  (function walk(o, depth) {
    if (!o || typeof o !== 'object' || depth > 16) return;
    if (seen.has(o)) return;
    seen.add(o);
    const det = o.price && o.price.viewSection && o.price.viewSection.itemDetails;
    if (det) out.push({ node: o, det: det });
    for (const k of Object.keys(o)) walk(o[k], depth + 1);
  })(root, 0);
  return out;
}

function farewayShopExtract(term) {
  const c = window.__APOLLO_CLIENT__;
  // BLINDNESS IS NOT EMPTINESS. No cache means this extractor did not read the page, it failed to - the
  // same distinction pull-fareway-instore.js draws for the dead fetch probe. Returning [] here would let
  // a sweep record "Fareway carries none of these things" on the strength of our own failure.
  if (!c || !c.cache || typeof c.cache.extract !== 'function') {
    throw new Error('REFUSING TO EXTRACT: no __APOLLO_CLIENT__ on this page. This is blindness, not an ' +
                    'empty result - do not record it as "no products found".');
  }
  const nodes = farewayItemNodes(c.cache.extract());
  if (!nodes.length) {
    throw new Error('REFUSING TO EXTRACT: the Apollo cache holds no priced item nodes. Either the results ' +
                    'have not hydrated yet (scroll/wait and retry) or the cache shape moved.');
  }

  const rows = [];
  const seenId = new Set();
  for (const { node, det } of nodes) {
    // evergreenUrl is the product slug, "84387836-hand-cut-extra-meaty-baby-back-pork-ribs-1-each".
    // Its numeric prefix is the product id the rest of the estate already keys Fareway on (it is what
    // build-fareway-regular reads out of link_url to anchor a TTL), so joining on it is joining on the
    // identity that already exists rather than minting a second one.
    const ever = String(node.evergreenUrl || '');
    const idm = ever.match(/^(\d+)-/);
    const pid = idm ? idm[1] : '';
    if (!pid || seenId.has(pid)) continue;
    seenId.add(pid);

    const priceStr = String(det.priceString || '');
    const wasStr = String(det.fullPriceString || '');
    const unitStr = String(det.pricingUnitString || '');
    const num = s => { const m = String(s).match(/([\d,]+\.?\d*)/); return m ? m[1].replace(/,/g, '') : ''; };

    // pricingUnitString is EITHER a rate ("$3.99 / lb") for a weighted good OR a pack size ("40 oz").
    // They are not the same fact and must not land in the same field: the builder prices a weighted good
    // per pound and a packaged one per pack, and feeding it "$3.99 / lb" as a size is how a per-lb number
    // gets compared against a per-pack one.
    const isRate = /\$/.test(unitStr) && /\//.test(unitStr);

    const disc = det.saleDisclaimerString || null;
    const days = farewaySaleEndsDays(disc);

    rows.push({
      id: pid,
      term: term || '',
      name: String((node.viewSection && node.viewSection.itemName) || node.name || '').trim(),
      price: num(priceStr),
      per: /each/i.test(priceStr) ? 'each' : '',
      orig: num(wasStr),
      unit: isRate ? unitStr : '',
      size: isRate ? '' : unitStr,
      url: ever ? 'https://shop.fareway.com/store/fareway-meat-grocery/products/' + ever : '',
      // The integer we READ, never a date computed here. See the header.
      sale_ends_days: days,
      // Kept verbatim even when it parses to nothing, so a disclaimer shape we do not handle yet is
      // visible in the capture instead of silently dropped.
      sale_note: disc || ''
    });
  }
  return rows;
}

/* Node/test surface. In the browser these are just globals; the PowerShell self-test requires the file. */
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { farewaySaleEndsDays, farewayShopExtract, farewayItemNodes };
}
