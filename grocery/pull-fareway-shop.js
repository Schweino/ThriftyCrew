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

  EVERY ROW CARRIES THE STORE IT WAS READ AT (2026-09-18, backlog I124). Fareway is an Instacart
  storefront whose store is SESSION state, and a fresh session sits plausibly on Des Moines
  (retailerLocation 513473). farewayIdentity() in pull-fareway-instore.js asserts 531573 ONCE, before a
  driver sweep - and nothing kept what any later page said, so a session that moved mid-sweep, or a
  rescue run in Brad's Chrome that never called farewayIdentity() at all, produced rows no file could
  attribute. This reads retailerLocation out of the SAME cache extract the rows come from, with the same
  regex farewayIdentity() uses, and stamps it on every row as `loc` ('UNRECORDED' when the cache names
  none). It records and never refuses: select-fareway-shop.ps1 is where a capture is ruled on (no stamp,
  UNRECORDED, two stores, or any store but the sanctioned one in stores.json), so the hunter's lookup lane,
  which also calls this, behaves exactly as before.

  EVERY ROW IS SCOPED TO ITS OWN SEARCH, IN CODE (2026-09-26). This used to walk the WHOLE cache. Navigating per
  term reloaded the page, so the cache held one search; driving terms with the router keeps the cache alive, and
  on 2026-09-24 a 45-term sweep read 81 -> 1910 candidates, every term carrying every earlier term's rows, all
  stamped the right store (memory fareway-router-sweep-needs-apollo-reset). Resetting the store too early still
  leaked the previous term ("yogurt" led by Yellow Onions). The cache is keyed by operation, then by the query's
  variables, measured 2026-09-26 on the live page:
        cache.SearchResultsPlacements['{"query":"pork ribs",...}']  ->  the result list, naming every item id
                                                                        ("items_<loc>-<pid>") that search returned
        cache.Items['{"ids":["items_<loc>-<pid>"],...}']            ->  the priced ItemsItem nodes, id the same
  After a router push from "pork ribs" to "yogurt" the cache held both searches and 104 priced items; the 68 whose
  id is in the yogurt result list covered all 63 tiles on screen, and none of the 36 rib rows. So a row is kept
  only when its node id is in the result list of the search whose query IS the term (lowercased, whitespace
  collapsed: the site lowercases "Campbell's" and keeps a doubled space), and every row carries that query as
  `scope_query`. No search for the term in the cache THROWS: the router has not mounted it yet, and extracting
  anyway is how another term's rows get recorded under this one. select-fareway-shop.ps1 refuses a capture whose
  rows are scoped to any query but their own term, and one whose candidate counts climb term after term.

  USAGE (in Brad's Chrome, on a shop.fareway.com search results page):
      farewayShopExtract('pork ribs')        -> [{ id, term, name, price, per, orig, unit, size, url,
                                                   sale_ends_days, sale_note, loc, scope_query }, ...]
  Window functions do NOT survive navigation - re-inline this after every navigate.

  THE SWEEP DRIVER (router, no navigation, so it survives the whole sweep). Start it as a background promise and
  poll; the agent's only jobs are to inject, start, poll and post:
      farewaySweep(terms, commodities, { loc: '531573' });     // parallel arrays, as the worklist carries them
      window.__fwSweep                     -> { done, i, n, lines, errors, aborted }
      farewaySweepJsonl()                  -> the capture, one {id, term, candidates, settle} line per term
  Per term it pushes the route, waits for it to mount, resets the store, scrolls until the SCOPED candidate count
  holds for four reads (the page paints ~9 and fills the rest seconds later: memory fareway-capture-defects), then
  extracts. A term that never settles, or whose search never mounts, is an ERROR for that term, never a line. A row
  read at any store but opts.loc stops the sweep.
*/

/** The query text as the storefront keys it: lowercased, whitespace collapsed. */
function farewayNormQuery(s) {
  return String(s == null ? '' : s).toLowerCase().replace(/\s+/g, ' ').trim();
}

/**
 * The item ids the search for `term` returned, read from the cache's own SearchResultsPlacements entry for it.
 * Returns { query: <the query as the cache keys it, or ''>, ids: Set, queries: [every query the cache holds] }.
 */
function farewayQueryItemIds(cache, term) {
  const want = farewayNormQuery(term);
  const out = { query: '', ids: new Set(), queries: [] };
  const srp = cache && cache.SearchResultsPlacements;
  if (!srp || typeof srp !== 'object') return out;
  for (const k of Object.keys(srp)) {
    let v = null;
    try { v = JSON.parse(k); } catch (e) { continue; }
    const q = v && typeof v.query === 'string' ? v.query : '';
    if (!q) continue;
    out.queries.push(q);
    if (farewayNormQuery(q) !== want) continue;
    out.query = q;
    for (const m of (JSON.stringify(srp[k]).match(/items_\d+-\d+/g) || [])) out.ids.add(m);
  }
  return out;
}

/** The retailerLocation a cache blob names, by farewayIdentity()'s own regex: the first match, or ''. */
function farewayReadLocation(blob) {
  const m = String(blob || '').match(/"retailerLocation(?:Id)?":"?(\d+)"?/);
  return m ? m[1] : '';
}

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
  if (!farewayNormQuery(term)) {
    throw new Error('REFUSING TO EXTRACT: no term. Rows are scoped to the search for their term, and there is ' +
                    'no search to scope to.');
  }
  const cache = c.cache.extract();
  const all = farewayItemNodes(cache);
  if (!all.length) {
    throw new Error('REFUSING TO EXTRACT: the Apollo cache holds no priced item nodes. Either the results ' +
                    'have not hydrated yet (scroll/wait and retry) or the cache shape moved.');
  }
  // THE SCOPE (see the header): only items the search for THIS term returned.
  const scope = farewayQueryItemIds(cache, term);
  if (!scope.query) {
    throw new Error('REFUSING TO EXTRACT: the Apollo cache holds no search for "' + farewayNormQuery(term) +
                    '" (it holds: ' + (scope.queries.map(q => '"' + q + '"').join(', ') || 'none') + '). The route ' +
                    'has not mounted this search yet - wait and retry; never record another search\'s rows.');
  }
  const nodes = all.filter(x => scope.ids.has(String(x.node.id || '')));
  if (!nodes.length) {
    throw new Error('REFUSING TO EXTRACT: the search for "' + scope.query + '" names ' + scope.ids.size +
                    ' item(s) and none is priced in the cache yet (' + all.length + ' priced item(s) belong to ' +
                    'other searches). Scroll/wait and retry.');
  }
  // The store, read from the very object the rows are read from - never from an earlier page.
  const loc = farewayReadLocation(JSON.stringify(cache)) || 'UNRECORDED';

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
      sale_note: disc || '',
      // The retailerLocation this page's cache named when the row was read. See the header.
      loc: loc,
      // The search this row was scoped to, as the cache keys it. select-fareway-shop refuses a row whose
      // scope is not its own term.
      scope_query: scope.query
    });
  }
  return rows;
}

/** How many candidates the search for `term` has hydrated so far; 0 while it cannot be read at all. */
function farewayScopedCount(term) {
  try { return farewayShopExtract(term).length; } catch (e) { return 0; }
}

/**
 * The router sweep (see the header). terms and commodities are PARALLEL arrays. Resolves to window.__fwSweep,
 * which it also keeps current while it runs, so a caller can start it without awaiting and poll.
 * opts: loc (the retailerLocation every row must carry, else the sweep stops), mountMs (1500), pollMs (2500),
 * stableReads (4), maxPolls (16), sleep (a promise-returning ms timer; tests pass an instant one).
 */
async function farewaySweep(terms, commodities, opts) {
  const o = opts || {};
  const sleep = o.sleep || (ms => new Promise(r => setTimeout(r, ms)));
  const mountMs = o.mountMs != null ? o.mountMs : 1500;
  const pollMs = o.pollMs != null ? o.pollMs : 2500;
  const stableReads = o.stableReads || 4;
  const maxPolls = o.maxPolls || 16;
  const T = Array.isArray(terms) ? terms : [];
  const C = Array.isArray(commodities) ? commodities : [];
  const st = { done: false, i: 0, n: T.length, lines: [], errors: [], aborted: '' };
  window.__fwSweep = st;
  if (T.length !== C.length) {
    st.aborted = 'terms (' + T.length + ') and commodities (' + C.length + ') are not parallel arrays';
    st.done = true;
    return st;
  }
  for (let k = 0; k < T.length; k++) {
    const term = String(T[k]), id = String(C[k]);
    st.i = k + 1;
    try {
      window.__do_not_use_me_history.push('/fareway-meat-grocery/s?k=' + encodeURIComponent(term));
      // Mount first, THEN reset: a reset fired before the route mounts refetches the PREVIOUS search.
      await sleep(mountMs);
      if (window.__APOLLO_CLIENT__ && typeof window.__APOLLO_CLIENT__.resetStore === 'function') {
        await window.__APOLLO_CLIENT__.resetStore();
      }
      // SETTLE on the count this term will actually emit, never on a sleep: the page paints ~9 and fills later.
      let last = -1, same = 0, polls = 0, n = 0;
      while (polls < maxPolls && same < stableReads) {
        try { window.scrollTo(0, window.document.body.scrollHeight); } catch (e) { /* no layout in a test */ }
        await sleep(pollMs);
        n = farewayScopedCount(term);
        same = (n > 0 && n === last) ? same + 1 : (n > 0 ? 1 : 0);
        last = n;
        polls++;
      }
      if (same < stableReads) {
        throw new Error('UNSETTLED: the scoped count for "' + term + '" did not hold for ' + stableReads +
                        ' reads in ' + polls + ' polls (last ' + n + ')');
      }
      const rows = farewayShopExtract(term);
      if (o.loc) {
        const off = rows.filter(r => r.loc !== String(o.loc));
        if (off.length) {
          st.aborted = 'term "' + term + '": ' + off.length + ' row(s) read at retailerLocation ' + off[0].loc +
                       ', not ' + o.loc + ' - the session is on the wrong store; nothing after this was read';
          break;
        }
      }
      st.lines.push({ id: id, term: term, candidates: rows, settle: { count: n, polls: polls } });
    } catch (e) {
      st.errors.push({ id: id, term: term, error: String((e && e.message) || e) });
    }
  }
  st.done = true;
  return st;
}

/** The finished sweep as the capture file: one {id, term, candidates, settle} JSON line per term that read. */
function farewaySweepJsonl() {
  const st = window.__fwSweep;
  if (!st || !st.done) throw new Error('the sweep has not finished (window.__fwSweep.done is not true)');
  return st.lines.map(l => JSON.stringify(l)).join('\n') + (st.lines.length ? '\n' : '');
}

/* Node/test surface. In the browser these are just globals; the PowerShell self-test requires the file. */
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { farewaySaleEndsDays, farewayShopExtract, farewayItemNodes, farewayReadLocation,
                     farewayNormQuery, farewayQueryItemIds, farewayScopedCount, farewaySweep, farewaySweepJsonl };
}
