# PROBE: can the browser-captured stores be read from a JSON endpoint directly? (2026-09-10)

Read-only research for Brad's ruling of 2026-09-10. Nothing in the estate was edited, run, committed or pushed.
Written at ThriftyCrew `main` HEAD `263006cea`, probes run 2026-09-10 between about 20:30 and 20:46 UTC, through
the Claude Code in-app Browser pane (a cold, unseeded profile), plus a handful of direct GETs noted per store.

## Summary

| Store | Captured today by | Verdict | One-line recommendation |
|---|---|---|---|
| Family Fare | Server-side Freshop per-term search (`pull-regular-familyfare.ps1`) | **DIRECT DATA FOUND** (catalog browse, no search term) | Measure whether browse pages spend the search window, then trial a paced whole-catalog walk as a second lane beside the rotation. |
| Aldi | Browser, SPA-router DOM sweep (`pull-aldi-instore.js`) | **PARTIAL** | Worth an in-page JSON capture trial; do not attempt a server-side client. |
| Fareway | Browser, DOM sweep (`pull-fareway-instore.js`) | **PARTIAL** | Same platform as Aldi, same trial; it retires four known silent DOM defects if it works. |
| Sam's Club | Browser, in-page fetch of SSR HTML (`pull-sams-instore.js`) | **NONE FOUND** (bot-challenge script served on first load; stopped) | Keep the current method. The HTML document already is the data. |
| Walmart | Browser, in-page fetch / iframe navigation of SSR HTML (`pull-walmart-instore.js`) | **NOT PROBED** (deliberate, see below) | Do not probe from this house without Brad's go-ahead; keep the current method. |
| Hy-Vee | Headless GraphQL + REST (`pull-regular-hyvee.ps1`) | NOT PROBED (already server-side) | No action. |
| Baker's | Headless Kroger developer API (`bakers-daily-scan.ps1`) | NOT PROBED (already server-side) | No action. |

**Rubric for the verdicts.**
- DIRECT DATA FOUND: a JSON endpoint was observed live today returning price, size, availability and a store
  scope for a store we price, callable without the rendered page.
- PARTIAL: a JSON endpoint carrying those fields was observed live, but at least one of these is unproven or
  against us: it works outside the browser session, the Omaha In-Store price comes back through it, or
  robots.txt allows it.
- NONE FOUND: the page's product data arrived in the HTML document itself and no separate product JSON call was
  seen.
- WALLED: a CAPTCHA, challenge page or login wall stopped the probe.
- NOT PROBED: not looked at, for the stated reason.

**Context.** The ask was triggered by capture-aging alerts firing on 23 of 60 store-days over 20 days (Family
Fare catalog, Family Fare carried-item, Walmart). Each store below got at most one ordinary search-page load;
no pagination, filter or repeat load was made against any retailer's storefront.

**One correction to the framing of the ask.** The "7 of 602 terms per window" is not Freshop's limit. It is Brad's
ruling of 2026-09-03 that everyday prices refresh once a quarter (602 / 7 = an 86-day rotation), recorded in
`ff-term-budget-is-quarterly-by-design.md`. The measured Freshop ceiling is higher; see the Family Fare section.

---

## Family Fare

**Current method.** Server-side, token-less `GET https://api.freshop.ncrcloud.com/1/products?app_key=family_fare&store_id=6401&q=<term>&limit=25&fields=...`,
one request per search term, rotated by a shared cursor, every 3 hours plus the daily run
(`grocery-method-familyfare.md`, `pull-regular-familyfare.ps1`, `familyfare-sweep.ps1`).

**Verdict: DIRECT DATA FOUND.** A search-free catalog browse exists, is token-less, and returns the fields we use.

**Evidence.**
- The Family Fare site's own shop page browses with `api.freshop.ncrcloud.com/1/products` and the parameters
  `app_key, department_id_cascade, include_departments, limit, render_id, store_id, token` - no `q=`. Read from
  the page's resource-timing buffer (parameter names only; values not recorded).
- `GET /1/departments?app_key=family_fare&store_id=6401` returned **876** departments, token-less. Fields:
  `store_id, id, identifier, name, sequence, path, type_id, store_rollup_mode_id, store_depth, type_identifier,
  is_default, canonical_url`. The root department is `22585550 = Shop`.
- `GET /1/products?app_key=family_fare&store_id=6401&department_id=22585550&department_id_cascade=true&limit=2&fields=id,name,size,price,base_price,unit_price,status,department_id,canonical_url`
  returned `total=18557` with two full rows (Yellow Bananas, size `lb`, price `$0.65`, status `available`,
  canonical_url present). The same call on Dairy (`22585789`) returned `total=557` (Our Family Reduced Fat Milk
  1 Gal, `$3.49`, status `available`).
- The same browse WITHOUT `department_id_cascade=true` returned `total=0`. The cascade flag is required.
- Paging: `pull-grocery-ads.ps1:175` already pages this same `/products` endpoint with `limit=200&page=N`
  (on `circular_id`). At 200 per page the whole catalog is about 93 requests, against 602 search terms today.
  Whether `limit=200` is accepted on a department browse: **could not verify** (not tested, to spare the window).
- Fields present: name, size, price, base_price, unit_price, status (in-stock at store 6401), canonical_url, id.
  Sale price is NOT in these fields; sales stay on the circular/offer path the estate already uses.
- **`unit_price` is not a normalized unit price.** For a 1 gal milk it read `3.49`, the package price. The builder
  must keep deriving per-unit from `size`, exactly as it does today.
- Auth: none beyond the public named `app_key`. The site itself also mints a session token
  (`/2/sessions/<id>` was requested); whether that endpoint now answers 200 or still 404s as the memo says:
  **could not verify** (status not visible in the timing buffer).
- robots.txt (shopfamilyfare.com): `User-agent: *` disallows only `/wp-admin/` and asks `Crawl-delay: 10`. The
  API host's own robots.txt: **could not verify** (not fetched).

**The documented rate limit.** No published limit was found. `docs.freshop.com` did not resolve (DNS ENOTFOUND)
and the NCR Voyix developer portal page returned an empty shell or login wall. The only numbers are the estate's
own measurements:
- About 60 to 70 search terms per window, after which `q=` answers HTTP 400 whose body is `{"error_code":429}`;
  45-second cooldowns do not reset it (`pull-regular-familyfare.ps1` comments dated 2026-07-28, 2026-07-30,
  2026-08-20).
- `capture-policy-lib.ps1:119` sets the Family Fare call cap at **40 search terms, basis `measured`**.
- **Browse (no `q=`) and `/stores` kept answering 200 throughout a throttle** (`pull-regular-familyfare.ps1`
  around line 583, 2026-07-30). That is the reason to think a catalog walk may not spend the search window, but
  it was observed during a throttle, not measured as a separate budget. **Could not verify.**
- Window length: not stated anywhere I found; the estate schedules one sweep every 3 hours.

**Other observation.** The shopfamilyfare.com origin answered a Cloudflare **504 Gateway time-out** on one load
at about 20:42 UTC (Cloudflare page: browser working, Cloudflare working, host error). That is an origin outage,
not a bot wall, and the next load worked. The API host was unaffected.

**Requests made against Freshop by this probe:** 4 token-less GETs (departments, one plain department browse,
two cascade browses) plus the site's own calls during 2 page loads. Zero `q=` searches.

**Risk if we switched.**
- Budget: unknown whether ~93 browse pages fit a window. A walk that does spend the search budget would starve
  the rotation for that window. Measure first, one window, paced.
- Fields: no sale price, no normalized unit price, and `status` is the only availability signal.
- Stability: `department_id_cascade` is an undocumented parameter we copied from the site's own call.
- Carried-item alerts: a full catalog is a positive "carries it" list, which could settle carried-or-not without
  a per-term search. That is the alert class this would most directly retire, but only once the catalog walk is
  proven complete (compare `total` to rows received).
- ToS: Freshop's terms were not readable; **could not verify**.

**Recommendation.** Trial a paced, cursor-kept catalog walk in a single window, record `total` against rows
received and whether the next `q=` search in that window still succeeds, then decide. Do not touch the quarterly
rotation ruling.

---

## Aldi

**Current method.** Browser only. Seeded Chrome at OLA 42 Omaha, In-Store; `window.__do_not_use_me_history.push('/aldi/s?k=<term>')`
per term, then a DOM extractor reading the tile's `Current price:` line and the slug for the name
(`grocery-method-aldi.md`, `pull-aldi-instore.js`). Excluded from the 08:00 driver (`browser-store-driver.md`).

**Verdict: PARTIAL.**

**Evidence.**
- One load of `https://www.aldi.us/store/aldi/s?k=milk`. No challenge or wall. A cookie notice (declined
  non-essential) and a fulfillment chooser appeared; the chooser was closed without confirming anything.
- The storefront is Instacart Storefront. Search runs as persisted-query GraphQL GETs on the same origin:
  - `GET /graphql?operationName=SearchResultsPlacements&variables={query, shopId, postalCode, zoneId, first, ...}&extensions={persistedQuery sha256}`
    returns placements, refinements and item references.
  - `GET /graphql?operationName=Items&variables={"ids":["items_24091-<productId>",...],"shopId","zoneId","postalCode"}&extensions={persistedQuery sha256 388f2002...}`
    hydrates items in batches of 5 to 10. All returned 200 with JSON.
- `Items` fields observed: `name`, `size` ("19.3 oz"), `productId`, `brandName`, `evergreenUrl` (the slug),
  `price.viewSection.priceString` ("$3.19"), `priceValueString` ("3.19"), `itemCard.priceScreenReaderString`
  ("Current price: $3.19"), `itemDetails.pricePerUnitString` ("$0.17/oz"), `availability.available` (true),
  `availability.stockLevel` ("highlyInStock"), `trackingProperties.retailer_location_id` ("24091"),
  `on_sale_ind`, `tags` (storeBrand).
- Store scope: `ShopCollectionScoped` lists three shops for retailerLocationId 24091: delivery `43147`, pickup
  `32006`, **instore `516952`**. This cold session was on Delivery (shopId 43147, postal 68144, zoneId 917), so
  every price observed today is the **Delivery** price. Whether `Items` with shopId 516952 returns the In-Store
  shelf price: **could not verify** (switching required confirming a form).
- Whether these GETs work without the browser's cookies: **could not verify** (not tested). The memo records a
  Forter bot wall on plain server scraping.
- Whether `Items.size` carries a multipack count ("24 x 16.9 fl oz", the gap in `grocery-method-aldi.md`):
  **could not verify**; the milk search did not return a multipack in the bodies read.
- robots.txt: `User-Agent: *` / `Disallow: /` (every unnamed agent barred from the whole site), plus a header
  line that any bot must abide by the Terms of Service. Named search engines are separately barred from `/api/`.
  `/graphql` is not mentioned.

**Risk if we switched.**
- ToS and robots: a blanket disallow for unnamed agents. A direct client is plainly against the stated stance;
  an in-page read of the JSON the page already fetched is closer to today's DOM read but still automation.
- Stability: persisted-query hashes change when Instacart redeploys; a hash change is a hard break.
- Price mode: the shopId decides Delivery versus In-Store pricing. A wrong shopId returns a marked-up price that
  looks entirely plausible (the 2026-08-05 memo shape). Any capture must assert shopId 516952 and In-Store.
- Gain: `priceValueString` and `pricePerUnitString` are unglued, and `name`/`size` are fields, which retires the
  glued-price, slug-decimal and descriptor-name repairs.

**Recommendation.** Trial capturing the `Items` JSON in-page (from the page's own responses) under the existing
paced sweep, asserting shopId 516952; do not build a server-side client.

---

## Fareway

**Current method.** Browser only. Seeded Chrome at retailerLocation 531573 (17070 Audrey Street, Omaha, 68136,
zoneId 917), In-Store; per-term router push and DOM extractor (`grocery-method-fareway.md`,
`pull-fareway-instore.js`, `fareway-capture-defects.md`).

**Verdict: PARTIAL.**

**Evidence.**
- One load of `https://shop.fareway.com/store/fareway-meat-grocery/s?k=milk`. No challenge or wall.
- **The cold session landed on Des Moines - Euclid**: retailerLocation `513473`, postal `50313`, zoneId `516`,
  pickup shop `16667216`, instore shop `16667217`. This is exactly the trap in `omaha-store-identities.md`. The
  store was not changed (that needs a form confirm), so **no Omaha price was read through the endpoint**.
- Same Instacart Storefront API as Aldi: `SearchResultsPlacements` then `Items`, and the `Items` persisted-query
  hash is identical (`388f2002...`). All 200.
- `Items` fields observed (Des Moines row): `name` ("Lactaid 2% Reduced Fat Milk Calcium Enriched"), `size`
  ("0.5 gal"), `priceString` ("$4.48"), `fullPriceString` ("reg. $4.99"), `plainFullPriceString` ("$4.99"),
  `pricePerUnitString` ("$0.07/fl oz"), `saleDisclaimerString` ("Sale ends in 2 days"), badge `offerLabelString`
  ("10% off"), `retailerReferenceCodeString` (a UPC-style code), `availability.available` and `stockLevel`,
  `retailer_location_id`.
- Sale price, regular price and sale end are all present as fields, which the DOM capture reconstructs today.
- Whether the GETs work without browser cookies: **could not verify**. The memo records bot protection on the
  persisted-query GraphQL.
- robots.txt: `User-Agent: *` / `Disallow: /`, with the same Terms of Service header as Aldi.

**Risk if we switched.** Same as Aldi (robots blanket disallow, hash rotation, shopId decides price mode and
location). Store identity is the sharper risk here: the endpoint silently answers for Des Moines if the session
is not seeded, and every field still looks right.

**Recommendation.** Same trial as Aldi, asserting retailerLocation 531573 and the Omaha In-Store shopId read from
`ShopCollectionScoped`. If it works it removes the four documented silent defects at once: the structurally blind
HTML probe, the 9-tile lazy load, the glued unit price and the descriptor name.

---

## Sam's Club

**Current method.** Browser only. In-page `fetch('https://www.samsclub.com/s/<term>')`, parse
`__NEXT_DATA__` -> `props.pageProps.initialData.searchResult.itemStacks[].items[]` (`grocery-method-sams.md`,
`pull-sams-instore.js`). Shares Walmart's bot defence (`walled-store-one-probe.md`).

**Verdict: NONE FOUND.** Stopped on bot-challenge signs after one load.

**Evidence.**
- One load of `https://www.samsclub.com/s/milk`, which went to `/search?q=milk`. The page rendered results.
- The rendered page's `__NEXT_DATA__` held **28 items** this time. (The 2026-08-05 memo said the rendered page
  no longer carried products; today it did. One observation, cold profile.)
- One item: `name` "Silk Unsweetened Original Almond, 64 fl. oz., 3 pk.", `priceInfo.linePrice` "$8.83",
  `priceInfo.unitPrice` "$0.05/foz", `fulfillmentType` "STORE", `availabilityStatusV2` "IN_STOCK", and
  `storeId` keys present in the payload (values not recorded). The club name was not visible in page text, so
  which club: **could not verify**.
- No separate product JSON call was seen. The resource-timing buffer filtered for graphql, orchestra, api and
  search showed only the page chunk, `/api/vivaldi/auth/v1/guest-log`, and PerimeterX collector calls. 33 earlier
  network-log entries had been dropped from the pane's buffer, but the timing buffer covers them.
- **Bot-challenge signs on that single load:** PerimeterX `captcha.js` was fetched and an `/are-you-human` URL
  loaded for the embedded login-refresh frame. No challenge was visible on the main page. Treated as a hard stop:
  no further requests to samsclub.com.
- robots.txt (fetched server-side via WebFetch, not from Brad's IP): `User-agent: *` disallows `/search`, `/cart`,
  `/checkout/`, `/account`, `/login` and others. `/s/`, `/api/`, `/graphql` not mentioned.

**Risk if we switched.** There is nothing to switch to: the product JSON is embedded in the HTML document, which
is what the current lane already reads. `/search` is disallowed for all agents.

**Recommendation.** Keep the current method. The alerts it raises are bot-wall cost, not a missing endpoint.

---

## Walmart

**Current method.** Browser only. In-page `fetch('/search?q=<term>')` or, the affordable sweep, a same-origin
iframe navigation per term, then parse `__NEXT_DATA__`; prices in `priceInfo.priceDetails.priceLines`
(`grocery-method-walmart.md`, `grocery-browser-exfil.md`, `pull-walmart-instore.js`).

**Verdict: NOT PROBED, on purpose.**

**Why.** The rubric for "is it safe to probe" is the operator and its defence vendor, not the domain
(`walled-store-one-probe.md`). Walmart and Sam's share PerimeterX, and it scores the IP. On 2026-08-22 a cold
profile was enough to wall Walmart, and the wall reached Sam's. Minutes before this decision, Sam's served a
PerimeterX challenge script on its first cold load in this same browser. A Walmart load from the same cold
profile and IP was therefore likely to be walled, telling us nothing new, while risking tomorrow's 08:00 capture
for both stores. That is a week-scale cost against a probe that most likely returns "walled".

**What is already known (from memos, not re-verified today).**
- Product data is embedded in the SSR HTML document's `__NEXT_DATA__`, the same shape as Sam's.
- In-page `fetch` re-armed the wall after 6 searches (2026-08-06); iframe navigation swept 427 of 526 terms with
  zero walls. That rules out "just call the JSON": the defence keys on how the request is made, not only on its
  URL.
- Whether the site uses a separate product JSON endpoint for pagination or filters: **could not verify**.
- robots.txt (fetched server-side via WebFetch): `User-agent: *` disallows `/search` and `/api/`. `/orchestra/`
  and `/graphql` not mentioned.

**Risk if we switched.** Any direct call is the request shape the wall already punishes, and `/search` is
disallowed for all agents.

**Recommendation.** Keep the current method. If Brad wants the question closed anyway, make it one headed load in
the seeded driver profile right after a successful 08:00 run, network log only, no retries.

---

## Hy-Vee and Baker's

NOT PROBED: both are already server-side. Hy-Vee uses the persisted GraphQL doc and REST search with storeId
1466 (`grocery-method-hyvee.md`); Baker's uses the sanctioned Kroger developer API since 2026-07-24
(`grocery-method-bakers.md`, `kroger-api-bakers.md`).

---

## What this probe did not establish

- Whether any Instacart Storefront GraphQL call works outside the browser session.
- Whether Aldi's In-Store shopId returns the In-Store shelf price, and whether Fareway's Omaha shop does.
- Whether a Freshop catalog walk spends the same per-window budget as search, and the largest accepted `limit`.
- Any store's Terms of Service text on automated access.
- Anything about Walmart beyond what the memos already record.
