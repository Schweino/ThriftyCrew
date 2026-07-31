// walmart-capture-reducer.js - the browser reducer for Walmart __NEXT_DATA__ price captures.
// Paste this into the claude-in-chrome javascript_tool on a Walmart search results page, calling
// f(patterns, cap) with an array of name-match regex strings and a per-commodity cap.
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
function f(patterns, cap) {
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
  return out.join('|') || ('EMPTY:' + items.length);
}
