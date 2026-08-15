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
  // A page we genuinely read that lists nothing really is EMPTY. We only reach here past the wall checks.
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
