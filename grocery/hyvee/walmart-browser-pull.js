/*
  walmart-browser-pull.js - capture Walmart's CURRENT Omaha prices, gently, with the FULL price basis.

  Walmart is not headless-scriptable from PowerShell (bot-gated), but a same-origin fetch of /ip/<itemId> from
  a warm walmart.com tab returns the product's __NEXT_DATA__, and priceInfo carries everything we need:
      priceInfo.currentPrice.price   the PACK price ($10.35 for a ~4 lb chicken tray)  <- NOT per lb
      priceInfo.unitPrice.price      the per-unit price (5.31)                          <- the per-lb number
      priceInfo.unitPrice.priceString  names the basis ("$5.31/lb", "12.4 c/oz")       <- REQUIRED
      priceInfo.wasPrice.price       the regular price, when reduced
      priceInfo.isPriceReduced       explicit discount flag
  import-walmart-prices.ps1 needs BOTH cur AND (uv,us) - the per-unit value and its basis string - to publish
  in the SAME basis our board row uses. A first run exported only cur/was and the import was useless: it could
  not tell a per-lb row from a packaged one, so it refused all 80 (correctly - it left the board alone).

  *** PACING - READ BEFORE CHANGING ***
  Walmart soft-blocks: it serves a "Robot or human?" PerimeterX page with HTTP 200 and no __NEXT_DATA__. It
  does NOT 403. So a fast run looks like it is working while collecting garbage: `fetched` climbs, `parsed`
  stays flat. 1.4s SERIAL gave a 100% parse rate across the run; 3-parallel/350ms tripped the block within a
  few dozen requests and then hard-redirected the tab to /blocked for the rest of the session. Watch PARSED,
  not fetched. Do not speed this up.

  RUN, in a warm walmart.com tab with the store set to the Omaha L St Supercenter:
      1. paste this file
      2. WM.start(ITEM_IDS)      // comma-separated usItemIds, from out\walmart-worklist.json
      3. poll WM.status()        // if parseRate falls below ~80%, it self-stops (soft block) - wait it out
      4. WM.dumpJson()           // paste the result into out\walmart-prices-raw.json, then run the importer
*/
const WM = (() => {
  const parse = (html) => {
    const m = html.match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
    if (!m) return null;                       // challenge page -> no NEXT_DATA -> null (this is the block signal)
    let j; try { j = JSON.parse(m[1]); } catch (e) { return null; }
    const p = j?.props?.pageProps?.initialData?.data?.product;
    if (!p || !p.priceInfo) return null;
    const pi = p.priceInfo;
    if (pi.currentPrice?.price == null) return null;
    return {
      cur: pi.currentPrice.price,              // PACK price
      was: pi.wasPrice?.price ?? null,         // regular price (only when reduced)
      reduced: !!pi.isPriceReduced,
      uv: pi.unitPrice?.price ?? null,         // per-unit value
      us: pi.unitPrice?.priceString ?? null    // per-unit BASIS - the importer cannot work without this
    };
  };

  const S = { ids: [], out: {}, run: false, stop: false, fetched: 0, parsed: 0, miss: 0, reason: null };

  return {
    start(idsCsv) {
      S.ids = idsCsv.split(',').map(x => x.trim()).filter(Boolean);
      Object.assign(S, { out: {}, run: true, stop: false, fetched: 0, parsed: 0, miss: 0, reason: null });
      (async () => {
        for (const id of S.ids) {
          if (S.stop) break;
          try {
            const r = await fetch('/ip/' + id, { credentials: 'include' });
            if (r.status === 403 || r.status === 429) { S.stop = true; S.reason = 'HTTP ' + r.status; break; }
            const v = parse(await r.text());
            S.fetched++;
            if (v) { S.out[id] = v; S.parsed++; S.miss = 0; }
            else { S.miss++; if (S.miss >= 8) { S.stop = true; S.reason = 'parse rate collapsed (soft block)'; break; } }
          } catch (e) { S.miss++; }
          await new Promise(x => setTimeout(x, 1400));   // the pace that parsed 100%. Do not raise it.
        }
        S.run = false;
      })();
      return { started: true, total: S.ids.length, etaMin: Math.round(S.ids.length * 1.45 / 60) };
    },
    status() {
      return { fetched: S.fetched, parsed: S.parsed,
               parseRate: S.fetched ? Math.round(100 * S.parsed / S.fetched) + '%' : '-',
               running: S.run, stopped: S.reason };
    },
    dumpJson() { return JSON.stringify(S.out); }   // { itemId: {cur, was, reduced, uv, us} }
  };
})();
