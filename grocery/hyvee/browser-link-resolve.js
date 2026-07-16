/*
  browser-link-resolve.js - BOARD-MATCH link resolver for the BROWSER stores (Baker's, Walmart, Sam's), run
  from a warm tab on that store's own origin. This is the "never again" tool for browser-store no-link chips:
  the daily cloud job self-heals Family Fare + Hy-Vee headlessly (resolve-ff-boardmatch / resolve-hyvee-links),
  but the bot-walled stores can only be resolved from a real browser, so the weekly Wednesday agent runs THIS.

  WHY BOARD-MATCH, NOT CHEAPEST-PICK: the "See item" link must point at the SAME product the board prices, or
  the per-unit won't match and guard 4 hard-fails the publish. We search for the board's OWN product name and
  accept a candidate only when the name matches AND (for a sized commodity) the size agrees. Sponsored slots are
  skipped - they surfaced a "Tru Fru" snack for fresh blueberries. Anything uncertain is LEFT unlinked; a wrong
  link is the thing we are avoiding. prune-bad-links (Tol 0.32) + guards.ps1 are the final backstop server-side:
  any link whose per-unit drifts from the board by a factor is dropped before publish.

  HOW TO RUN (weekly agent):
    1. Get the no-link chips for the store:
         powershell -File list-browser-nolinks.ps1     (prints board product name + size per store)
    2. Open a warm tab on the store (store set to the Omaha location; clear any bot wall first).
    3. Paste this file, then:
         await BLR.run('bakers',  CHIPS)   // CHIPS = [{id, q:'<GENERIC term>', match:'<board product name>', size}]
         await BLR.run('walmart', CHIPS)
       It returns rows [{id,url,name,upc,perunit,size}] for the confident matches; MISS entries are reported.
       IMPORTANT (root-cause fix 2026-07-15): q is the GENERIC commodity term (build-nolink-chips.ps1 fills it from
       commodity-search.json), NOT the board product name. Kroger/Baker's search mis-ranks a brand-specific query
       (searching "Filippo Berio Balsamic..." returns Bertolli first and can OMIT Filippo Berio entirely), which
       silently produced wrong-brand matches. Searching the generic term returns the full brand set - exactly how
       the price capture found the product - and we word-match c.match (the board name) to pick the right one.
       Falls back to c.q for older chip files that lack a match field.
    4. Save the rows into out\url-inputs\store-<store>-urls.json (merge format: {id,url,price,size,name}),
       anchoring price to the board cell (see build-browser-links.ps1), then:
         merge-product-urls.ps1 -> stamp-board-pu.ps1 -> prune-bad-links.ps1 -Tol 0.32 -> guards.ps1 -> publish
       and MOVE the store-*-urls.json into out\url-inputs-archive\ (a stale file left in url-inputs re-merges
       every run and can resurrect a dead link - this bit us before).

  Instacart storefronts (Aldi = www.aldi.us/store/aldi, Fareway = shop.fareway.com) are client-rendered and have
  NO same-origin search JSON, so they are DOM-read instead: navigate to /s?k=<term>, poll for
  a[href*="/products/"], and read the product id+slug from the href (the card text truncates the name, the slug
  does not). Same board-match + size rules apply.
*/
const BLR = (() => {
  const norm = s => (s || '').toLowerCase().replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();
  // qty of a size string in its own unit, for the size-agreement check ("16 oz" -> 16, "lb"/"each" -> 1)
  const qtyOf = sz => { const m = String(sz || '').match(/(\d+(?:\.\d+)?)/); return m ? parseFloat(m[1]) : 1; };

  // per-store: fetch the search HTML/JSON same-origin and return [{url,name,upc,perunit,sizeText,sponsored}]
  async function candidates(store, q) {
    if (store === 'bakers') {
      const r = await fetch('/search?query=' + encodeURIComponent(q) + '&searchType=default_search', { credentials: 'include' });
      const doc = new DOMParser().parseFromString(await r.text(), 'text/html');
      return [...doc.querySelectorAll('.ProductCard')].map(card => {
        const t = card.innerText, a = card.querySelector('a[href*="/p/"]');
        let path = null; try { path = new URL(a.href, location.origin).pathname; } catch (e) {}
        const m = path && path.match(/\/p\/[^/]+\/(\d+)/);
        const pum = t.match(/\$(\d+(?:\.\d+)?)\s*\/\s*(fl\s*oz|oz|lb|ea|ct)/i);
        const szm = t.match(/(\d+(?:\.\d+)?)\s*(fl\s*oz|oz|lb|ct|ea)\b/i);
        return m ? { url: 'https://www.bakersplus.com' + path, upc: m[1], name: t.split('\n').filter(x => /[a-z]{4}/i.test(x)).pop() || '', perunit: pum ? parseFloat(pum[1]) : null, sizeText: szm ? szm[0] : '', sponsored: /^\s*sponsored/i.test(t) } : null;
      }).filter(Boolean);
    }
    if (store === 'walmart' || store === 'sams') {
      const base = store === 'sams' ? '' : '';
      const r = await fetch('/search?q=' + encodeURIComponent(q), { credentials: 'include' });
      const txt = await r.text();
      const nm = txt.match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
      if (!nm) return [];                                   // challenge page -> no data
      let items = [];
      try { const j = JSON.parse(nm[1]); for (const s of (j?.props?.pageProps?.initialData?.searchResult?.itemStacks || [])) if (s.items) items = items.concat(s.items); } catch (e) {}
      const host = store === 'sams' ? 'https://www.samsclub.com' : 'https://www.walmart.com';
      return items.filter(it => it.canonicalUrl && it.name).map(it => ({
        url: host + it.canonicalUrl.split('?')[0], name: it.name, upc: String(it.usItemId || it.productId || ''),
        perunit: it.priceInfo?.unitPrice?.price ?? null, sizeText: '', sponsored: !!it.isSponsoredFlag
      }));
    }
    return [];
  }

  return {
    async run(store, chips) {
      const out = [];
      for (const c of chips) {
        try {
          const cands = await candidates(store, c.q);                       // SEARCH the generic term (c.q)
          const qwords = norm(c.match || c.q).split(' ').filter(w => w.length > 2 && !/^\d/.test(w));  // MATCH the board product name
          const wantQty = c.size ? qtyOf(c.size) : null;
          let best = null, bestScore = -1;
          for (const p of cands) {
            if (p.sponsored) continue;
            const nm = norm(p.name);
            let hits = 0; for (const w of qwords) if (nm.includes(w)) hits++;
            if (hits < 2) continue;
            if (wantQty && p.sizeText) { const sq = qtyOf(p.sizeText); if (sq && Math.abs(sq - wantQty) > wantQty * 0.1) continue; } // size must agree within 10%
            if (hits > bestScore) { bestScore = hits; best = p; }
          }
          // Keep the WHOLE product name. This used to .slice(0, 60), which is display trimming applied to
          // STORED DATA - and the per-unit weight lives at the END of a grocery name ("... , 20 oz Can"), so a
          // 60-char cap deletes exactly the token every downstream check needs. guards.ps1 #5 verifies a
          // multipack by multiplying the name's per-unit weight by its pack count; without the weight it cannot
          // decide and must fail closed, which is why 7 Walmart rows now need hand-written allowlist entries.
          // (Those 7 are truncated in out\regular\, not here - a historical capture did that, and its code is
          // not in this repo. This slice was a second, smaller instance of the same mistake, not their cause.)
          // Truncate for DISPLAY at the point of display, never on the way into a file.
          out.push(best ? { id: c.id, url: best.url, name: (best.name || ''), upc: best.upc, perunit: best.perunit, score: bestScore + '/' + qwords.length } : { id: c.id, miss: true });
        } catch (e) { out.push({ id: c.id, error: String(e).slice(0, 80) }); }
        await new Promise(x => setTimeout(x, 1600));         // gentle: Baker's Akamai / Walmart PerimeterX
      }
      return out;
    }
  };
})();
