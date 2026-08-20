/*
  pull-fareway-instore.js  --  Fareway IN-STORE (shelf) price agent.

  Runs on pull-agent-lib.js -- paste that file into the console FIRST, then this one.

  WHY THE IDENTITY ASSERT IS THE WHOLE GAME HERE
  ----------------------------------------------
  Fareway is an Instacart storefront, and a fresh session reads completely PLAUSIBLY while sitting on
  a store in Des Moines (retailerLocation 513473). Every price is real, every parse is confident, and
  the board silently fills with another market's shelf. The on-screen label is NOT proof -- the only
  reliable identity is the Apollo cache. Omaha is:

      lineOneString    "17070 Audrey Street"
      retailerLocation 531573
      zoneId           917
      postal           68136
      header           In-Store

  Instacart storefronts serve a DIFFERENT PRICE per fulfillment mode, and In-Store is the only mode
  the board may publish (Delivery/Pickup are marked up). So the assert checks BOTH the location and
  the mode, and refuses on either.

  PACING: unmeasured. The 2026-08-15 sweep of 144 terms completed with no wall, so no rate limit has
  ever been observed -- but "never observed" is not "measured safe", and 144 terms is a fifth of the
  full list. Starts at the Aldi rate (900ms, the one measured Instacart figure we have) plus jitter.
  The timing ledger will say whether that holds over a full sweep.
*/

const FAREWAY_STORAGE_KEY = 'TC_FAREWAY_SWEEP';

/* Mirrors stores.json -> Fareway -> pull_profile. audit-pull-profiles.ps1 fails if they disagree. */
const FAREWAY_PROFILE = { delayMs: 900, jitterMs: 600, retries: 3, backoffMs: 20000, wallLimit: 3 };

/** Read the Apollo cache, which is the only trustworthy statement of which store we are on. */
function farewayIdentity() {
  const client = window.__APOLLO_CLIENT__;
  if (!client) {
    throw new Error(
      'REFUSING TO PULL: no __APOLLO_CLIENT__ on this page. The on-screen store label is not proof of ' +
      'location -- a fresh session reads plausibly while sitting on Des Moines. Open a Fareway storefront page.'
    );
  }
  const cache = client.cache.extract();
  const blob = JSON.stringify(cache);

  const loc = (blob.match(/"retailerLocation(?:Id)?":"?(\d+)"?/) || [])[1];
  const line1 = (blob.match(/"lineOneString":"([^"]+)"/) || [])[1];

  if (loc !== '531573') {
    throw new Error(
      `REFUSING TO PULL: retailerLocation is ${loc || 'unknown'} (address "${line1 || '?'}"), not Omaha's 531573. ` +
      `513473 is Des Moines - Euclid, which reads plausibly and would fill the board with another market's shelf.`
    );
  }
  const mode = (document.body.innerText.match(/\b(In-Store|Delivery|Pickup)\b/) || [])[1];
  if (mode !== 'In-Store') {
    throw new Error(
      `REFUSING TO PULL: fulfillment mode is "${mode || 'unknown'}", not In-Store. Instacart serves a ` +
      `different (marked-up) price per mode; only the in-store shelf price may be published.`
    );
  }
  return { store: line1 || 'Fareway Omaha', retailerLocation: loc, mode };
}

/** Fareway/Instacart returns 429 when it throttles; anything non-OK is UNUSABLE, never EMPTY. */
async function farewayProbe(term) {
  const url = '/store/fareway/s?k=' + encodeURIComponent(term);
  const r = await fetch(url, { credentials: 'include' });
  if (r.status === 429 || r.status === 403) return { state: 'UNUSABLE', rows: [], why: 'http ' + r.status };
  const html = await r.text();
  if (/unusual traffic|are you a robot|px-captcha/i.test(html.slice(0, 200000))) {
    return { state: 'UNUSABLE', rows: [], why: 'bot-wall' };
  }

  const rows = [];
  const seen = new Set();
  const re = /"name":"([^"]{3,120})"[^}]{0,400}?"price":\{[^}]*?"viewSection":\{[^}]*?"priceString":"\$?([\d.]+)"/g;
  let m;
  while ((m = re.exec(html))) {
    const key = m[1] + '|' + m[2];
    if (seen.has(key)) continue;
    seen.add(key);
    rows.push({ n: m[1].replace(/[|\r\n]+/g, ' ').trim(), lp: parseFloat(m[2]), up: null, id: '' });
  }
  // BLINDNESS IS NOT EMPTINESS (2026-08-20). EMPTY is a claim about the STORE - "we looked, it carries
  // nothing" - and downstream treats it exactly that way: a NOT-CARRIED ruling, a dropped cell, a term
  // retired. Reaching that conclusion because WE cannot see is the confident-ok-over-an-empty-examination
  // shape this estate keeps paying for.
  //
  // What happened: shop.fareway.com became fully client-rendered. This response is now a 584KB shell with
  // ZERO product JSON in it - measured the same day, `"priceString"` appears 0 times, `__NEXT_DATA__` 0
  // times, the search term itself twice (title and meta). The regex above therefore matched nothing on
  // EVERY term, and a sweep of the whole worklist would have completed, exited 0, reported no wall, and
  // recorded that Fareway carries none of the ~700 things it sells.
  //
  // So: if the response carries no product markup AT ALL, this parser did not read the page - it failed to.
  // That is UNUSABLE, which halts the sweep loudly, rather than EMPTY, which poisons the catalog quietly.
  // The working path is driver-side: navigate per term, scroll to the bottom TWICE (results lazy-load nine
  // at a time; a repeated exact 9 is the tell), then read the rendered tiles - which cannot run from inside
  // this page, because navigating unloads the script doing the sweeping. Do not "fix" this by widening the
  // regex; there is nothing in the response to widen onto.
  if (!rows.length && !/"priceString"|"viewSection"/.test(html)) {
    return {
      state: 'UNUSABLE', rows: [],
      why: 'no product JSON in the response - the storefront is client-rendered and this fetch-and-regex probe cannot see it. Use the driver-side DOM sweep (navigate, scroll twice, extract), not this probe.'
    };
  }
  // A page we genuinely read that lists nothing really is EMPTY. We only reach here past the wall checks
  // AND past the blindness check above, so this is now a statement we can actually stand behind.
  return rows.length ? { state: 'MATCHES', rows } : { state: 'EMPTY', rows: [], why: 'store returned no products' };
}

const farewayAgent = {
  storeName: 'Fareway',
  storageKey: FAREWAY_STORAGE_KEY,
  profile: FAREWAY_PROFILE,
  assertIdentity: farewayIdentity,
  probe: farewayProbe,
};

const pullFarewayInStore     = (worklist, opts) => runPacedSweep(farewayAgent, worklist, opts);
const farewaySweepToCsv      = () => sweepToCsv(FAREWAY_STORAGE_KEY, p => [p.n, p.lp ?? '', p.up ?? '', p.id ?? '']);
const farewaySweepVerdicts   = () => sweepVerdicts(FAREWAY_STORAGE_KEY);
const farewaySweepRemaining  = wl => sweepRemaining(FAREWAY_STORAGE_KEY, wl);
