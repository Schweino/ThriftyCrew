// walmart-capture-reducer.js - the browser reducer for Walmart __NEXT_DATA__ price captures.
// Paste this into the claude-in-chrome javascript_tool on a Walmart search results page, calling
// f(patterns, cap, term) with an array of name-match regex strings, a per-commodity cap, and the
// commodity term the rows are for.
//
// Emits SIX ~~-delimited fields per product so import-walmart-batch.ps1 can run its marketplace
// filter: name~~linePrice~~unitPrice~~usItemId~~sellerName~~fulfillmentType
// The last two are what let the importer DROP third-party MARKETPLACE listings (the in-store rule -
// a 3P pool-cue shop was once the "Walmart price" for Goya beans). DO NOT drop back to the old
// 4-field form or the marketplace filter silently never runs.
//
// fulfillmentType values seen: STORE / FC / SHIP (first-party, keep) vs MARKETPLACE (3P, dropped).
// sellerName "Walmart.com" or empty = first-party; anything else (even FC-fulfilled) = 3P seller.
//
// THE STORE THE PAGE WAS READ AT (2026-09-19, backlog I220). Walmart prices are per store, and
// import-walmart-batch.ps1 REFUSES a capture that does not open with a #tc-store line naming the store
// it was read at (it admits only the stores in stores.json -> Walmart -> batch_accepted_stores). Called
// WITH a term, f returns an importer-ready block:
//     #tc-store store="name not in payload" id="2847" zip="68123" read="page" rows=3
//     <term><TAB>name~~lp~~up~~id~~seller~~fulfill|...
// The id and zip are read from THIS page's own __NEXT_DATA__ by walmartStoreFromData, which is the SAME
// TEXT as the function of that name in pull-walmart-instore.js (test-pull-agent-lib.ps1 fails when the two
// copies differ). The payload carries no display name (measured 2026-09-12), so the name is written as
// the page gave it or "name not in payload" - never a store we assume. When the page names NO store, or
// two at equal confidence, NO store line is written and the rows still come back, so the importer refuses
// the capture loudly instead of this reducer guessing. Post the output UNALTERED; several terms' blocks
// may be concatenated, one per line group, and the importer rules on all their store lines together.
// Called WITHOUT a term, f returns the products string alone, as it did before, and that output can no
// longer be imported on its own - it carries no store.
//
// PRICE PATH: TRY BOTH SHAPES, ALWAYS. Walmart has now moved this twice.
//   2026-07-23: prices moved FROM priceInfo.linePrice TO priceInfo.priceDetails.priceLines[].values[]
//               (keys PRICE / UNIT_PRICE), and this file was rewritten to read only the new path.
//   2026-07-31: they moved BACK. priceDetails is an empty object on every product and the price is
//               on priceInfo.linePrice again. Measured that morning on the live site: the
//               priceDetails-only reducer returned EMPTY for all 58 items on the first term tried,
//               and would have returned EMPTY for every term of the at-risk pull.
// That is the whole danger of this class: a capture that reads the wrong path does not error, it
// returns nothing, and a zero-row capture looks like a clean run. Reading BOTH means the next move
// costs nothing. priceDetails is preferred when populated because it is the richer shape and
// carries UNIT_PRICE explicitly; linePrice/unitPrice are the fallback.
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

// One store line from what the page reported, or '' when it reported no usable store. A field carrying a
// quote, pipe, tab or newline cannot break the line (the importer's parser reads quoted fields).
function walmartReducerStoreLine(where, rows) {
  if (!where || !where.id || where.id === 'AMBIGUOUS' || !/^\d+$/.test(String(where.id))) return '';
  const clean = s => String(s == null ? '' : s).replace(/["|\t\r\n\u0000]/g, ' ').replace(/\s+/g, ' ').trim();
  return '#tc-store store="' + (clean(where.label) || 'name not in payload') + '" id="' + clean(where.id) +
    '" zip="' + clean(where.zip) + '" read="page" rows=' + rows;
}

function f(patterns, cap, term) {
  var el = document.getElementById('__NEXT_DATA__');
  if (!el) return 'NO-NEXTDATA';
  var jd = JSON.parse(el.textContent);
  var sr = (((jd.props || {}).pageProps || {}).initialData || {}).searchResult;
  if (!sr) return 'NO-SEARCHRESULT';
  var items = (sr.itemStacks || []).flatMap(function (s) { return s.items || []; });
  var out = [];
  for (var i = 0; i < items.length; i++) {
    var p = items[i];
    if (!p || !p.name) continue;
    if (!patterns.some(function (rx) { return new RegExp(rx, 'i').test(p.name); })) continue;
    var pi = p.priceInfo || {};
    var pls = ((pi.priceDetails || {}).priceLines) || [];
    var lp = '', up = '';
    for (var k = 0; k < pls.length; k++) {
      var vals = pls[k].values || [];
      for (var v = 0; v < vals.length; v++) {
        if (vals[v].key === 'PRICE' && !lp) lp = '$' + vals[v].value;
        if (vals[v].key === 'UNIT_PRICE') up = vals[v].value;
      }
    }
    // FALLBACK to the older/current flat shape - see the PRICE PATH note in the header.
    if (!lp && pi.linePrice) lp = ('' + pi.linePrice);
    if (!up && pi.unitPrice) up = ('' + pi.unitPrice);
    if (!lp) continue;
    var seller = (p.sellerName || '');
    var fulfill = ((p.fulfillmentType || '') + '').toUpperCase();
    out.push(p.name.replace(/[~|\t]/g, ' ') + '~~' + lp + '~~' + up + '~~' + (p.usItemId || '') + '~~' + seller + '~~' + fulfill);
    if (out.length >= cap) break;
  }
  if (!out.length) return 'EMPTY:' + items.length;
  var products = out.join('|');
  if (term == null || term === '') return products;
  var line = walmartReducerStoreLine(walmartStoreFromData(jd), out.length);
  var body = String(term).replace(/[\t\r\n|]/g, ' ').trim() + '\t' + products;
  return line ? (line + '\n' + body) : body;
}
