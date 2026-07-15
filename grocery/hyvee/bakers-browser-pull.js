/*
  bakers-browser-pull.js - capture Baker's CURRENT shelf prices (Saddlecreek, Omaha).

  WHY THIS EXISTS
  Baker's publishes a regular price and a discounted price, and the board was carrying the REGULAR one:
      Heritage Farm chicken breast   store: "about $10.31  Discounted From $13.01  $2.29/lb"   board: $2.89/lb
      Kroger salted butter 16 oz     store: "$2.99  Discounted From $3.49  $0.19/oz"           board: $3.49
  Same bug Hy-Vee had. Unlike Hy-Vee, Baker's is Akamai-gated: there is no headless API, its product API
  rejects requests without LAF headers, and /p/<slug>/<upc> fetches come back 403. The ONE route in is the
  SEARCH page, which is server-rendered with prices and the "Discounted From" pair.

  *** RATE LIMIT - READ THIS BEFORE CHANGING THE PACING ***
  Akamai WILL block you. Fetching 5 at a time with a 150 ms gap got ~69 products through and then returned 403
  to everything, for a long time afterwards. This runs SERIALLY with a 2 s gap (~9 minutes for 262 products)
  and ABORTS on the first 403 rather than grinding against a wall. Do not "optimise" it back into a blocklist.

  HOW TO RUN
  In a Chrome tab already on www.bakersplus.com, with the store set to Saddlecreek / 888 S Saddle Creek Rd:
      1. paste this file
      2. BK.start(PAIRS)      // PAIRS = "<upc>~<name>" entries, from out\bakers-upc-worklist.json
      3. poll BK.status()
      4. BK.dump()            // returns CSV: upc,price,was,unitVal,unitOf,elp
  Match is by UPC taken from each card's own /p/<slug>/<upc> href, so the product NAME is only ever a search
  QUERY, never the thing we match on. Name matching is how you end up pricing Hidden Valley ranch as Hy-Vee's.
*/
const BK = (() => {
  const S = { queue: [], out: {}, running: false, blocked: false, done: 0, total: 0 };

  // Pull the price fields off one card. The traps, all of which produced garbage on the first pass:
  //   * the UNIT price ("$0.19/oz") is itself a $ token and must be removed before reading the main price;
  //   * a multi-buy line ("10 for $10") injects a $ token that looked like a "was" price;
  //   * "Discounted From" is the ONLY thing that licenses a was-price. Absent it, there is no discount, and
  //     any second $ token is something else entirely (a coupon, a multi-buy, a per-unit).
  const parseCard = (card, upc) => {
    const t = card.innerText.replace(/\s*\n\s*/g, '|');
    const unitM = t.match(/\$(\d+(?:\.\d+)?)\s*\/\s*(fl\s*oz|oz|lb|ea|ct|sq\s*ft)/i);
    const unitVal = unitM ? parseFloat(unitM[1]) : null;
    const unitOf = unitM ? unitM[2].toLowerCase().replace(/\s+/g, ' ') : null;

    // strip the unit-price token and any multi-buy phrasing before reading money off the card
    let clean = t;
    if (unitM) clean = clean.split(unitM[0]).join('|');
    clean = clean.replace(/\d+\s*for\s*\$\d+(?:\.\d+)?/gi, '|');       // "10 for $10"
    clean = clean.replace(/(?:save|coupon|get)\b[^|]*/gi, '|');        // coupon / promo lines

    const disc = /Discounted From/i.test(t);
    const money = (clean.match(/\$\d+(?:\.\d+)?/g) || []).map(x => parseFloat(x.slice(1)));
    const price = money.length ? money[0] : null;
    let was = null;
    if (disc && money.length > 1 && money[1] > price) was = money[1];

    return { price, was, unitVal, unitOf, elp: /Everyday Low Price/i.test(t) };
  };

  const findCard = (doc, upc) => {
    for (const c of doc.querySelectorAll('.ProductCard')) {
      const a = c.querySelector('a[href*="/p/"]');
      if (!a) continue;
      const m = (a.getAttribute('href') || '').match(/\/p\/[^/]+\/(\d+)/);
      if (m && m[1] === upc) return c;      // exact identity, by UPC. Never by name.
    }
    return null;
  };

  const one = async (upc, name) => {
    // search by NAME (UPC-only search does not index every product), then match the card by UPC
    const q = encodeURIComponent(name || upc);
    const r = await fetch('/search?query=' + q + '&searchType=default_search', { credentials: 'include' });
    if (r.status === 403) { S.blocked = true; throw new Error('403 - Akamai has blocked us; stop.'); }
    const doc = new DOMParser().parseFromString(await r.text(), 'text/html');
    const card = findCard(doc, upc);
    if (card) {
      const pc = parseCard(card, upc);
      // capture the product URL too, so import-bakers can store the link on the row (sync-browser-links then
      // heals a pruned Baker's link from it - Baker's has no numeric item_id like Walmart to rebuild a URL from).
      const a = card.querySelector('a[href*="/p/"]');
      try { pc.url = a ? 'https://www.bakersplus.com' + new URL(a.href, location.origin).pathname : ''; } catch (e) { pc.url = ''; }
      S.out[upc] = pc;
    } else { S.out[upc] = null; }
  };

  return {
    start(pairsStr) {
      S.queue = pairsStr.split('§').map(p => {
        const i = p.indexOf('~');
        return { upc: p.slice(0, i), name: p.slice(i + 1) };
      });
      S.total = S.queue.length; S.done = 0; S.out = {}; S.blocked = false; S.running = true;
      (async () => {
        for (const it of S.queue) {
          if (S.blocked) break;
          try { await one(it.upc, it.name); } catch (e) { break; }
          S.done++;
          await new Promise(r => setTimeout(r, 2000));   // GENTLE. See the rate-limit note above.
        }
        S.running = false;
      })();
      return { started: true, total: S.total };
    },
    status() {
      const got = Object.values(S.out).filter(Boolean).length;
      return { done: S.done, total: S.total, parsed: got, running: S.running, blocked: S.blocked };
    },
    dump() {   // CSV: upc,price,was,unitVal,unitOf,elp,url  (url is last - it never contains a comma)
      return Object.entries(S.out).filter(([, v]) => v).map(([u, v]) =>
        [u, v.price ?? '', v.was ?? '', v.unitVal ?? '', v.unitOf ?? '', v.elp ? 1 : 0, v.url ?? ''].join(',')
      ).join('\n');
    }
  };
})();
