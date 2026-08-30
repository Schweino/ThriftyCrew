# Omaha Grocery Weekly-Ad Puller

Pulls the **current week's** weekly-ad deals for four Omaha grocery stores, straight from **each store's own published weekly ad** (no Instacart, no third-party markups, no online-catalog everyday prices). Every store passes two hard gates before a single deal is accepted.

## The two hard gates (both must pass, or the store returns ZERO deals)

1. **OMAHA** â€” the ad's store must resolve to the Omaha store: city Omaha + a `68xxx` zip (Hy-Vee / Aldi / Family Fare), or the "Saddlecreek" store label (Baker's, 888 S Saddle Creek Rd, Omaha 68106).
2. **CURRENT** â€” today's date must fall inside the ad's `valid_from â€¦ valid_to`. A stale or next-week-only ad is rejected.

Fail either gate â†’ that store is flagged `BLOCKED` and contributes nothing. Nothing wrong-city or out-of-date can leak into the results.

## Store coverage

| Store | Source (its own weekly ad) | Method | Browser needed? |
|---|---|---|---|
| Hy-Vee | Flipp SFML (`digital-flyers/1465`) | `pull-grocery-ads.ps1` | No |
| Aldi | Flipp flyerkit JSON (store `446-048`) | `pull-grocery-ads.ps1` | No |
| Family Fare | Freshop circular API (store `6401`) | `pull-grocery-ads.ps1` | No |
| Baker's (Kroger) | flyer-page JPGs on przone CDN | `pull-bakers.ps1` + Chrome | Yes (Akamai-gated) |

## Running it

### 1) The three server-side stores (one command, no browser)

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Codex\ThriftyCrew\grocery\pull-grocery-ads.ps1"
```

Prints a verification table (store, zip, ad dates, OMAHA, CURRENT, deals, status) and writes `out\ads-YYYY-MM-DD.json`. Only `PASS` stores contribute deals.

### 2) Baker's (browser-assisted, image-based)

Kroger is Akamai bot-protected, so the discovery step runs in Chrome (the agent does this):

1. Open `https://www.bakersplus.com/weeklyad`. Confirm the store selector reads **"Pickup at Saddlecreek"** (the Omaha store). Read the date range shown ("July 1 - 7").
2. Capture the flyer page image URLs: `read_network_requests` with `urlPattern=przone` â†’ the `/anonymous/{uuid}.jpg` list. Write them (one per line, `imwidth=2400`) to `out\bakers\urls.txt`.
3. Verify + download:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Codex\ThriftyCrew\grocery\pull-bakers.ps1" `
  -StoreLabel "Pickup at Saddlecreek" -AdFrom 2026-07-01 -AdTo 2026-07-07 `
  -UrlsFile "C:\Codex\ThriftyCrew\grocery\out\bakers\urls.txt"
```

It re-checks both gates, stages the pages, then installs them to `out\bakers\page-NN.jpg`, clearing the folder's old page files first. The agent vision-reads **the pages `meta.json` lists**, not a bare `page-*.jpg` glob, to extract deals (the front page prints the sale dates, which independently confirm the week).

> **Why not the glob** (2026-08-09): neither image puller used to clear its target folder, so an ad with FEWER pages than the previous one left the expired ad's extra pages on disk, indistinguishable from current ones. Fareway's 24-page 2026-08-02..08 ad left `weekly-23.jpg`/`weekly-24.jpg` sitting under the 22-page 2026-08-09..15 ad; `weekly-23.jpg` was vision-confirmed as the OLD ad's Personal Care page. That is the expired-ad-supplement class ruled on 2026-08-07, except it **bypasses** that guard: the stale data arrives as an IMAGE, before any `ad_to` exists to check. Both pullers now stage and swap through `adpages-lib.ps1`: nothing installs unless every page arrived, the folder is cleared first, the page count is re-asserted after the swap, and `ad-window.json` in the folder stamps which window the images actually belong to. An incomplete download refuses the swap and leaves the previous ad intact (`installed:false`, exit 2) rather than half-publishing. Fixture: `regression-inputs\guard-fixtures\adpages-shrink.json`, run by `pull-fareway-ads.ps1 -SelfTest` and asserted daily by `test-auditors.ps1`.

## Notes / gotchas

- **WALMART PULLS MUST RUN THE FULL WORKLIST** (all ~447 commodity-search.json terms, not a
  core-staples subset). A partial pull no longer breaks anything - compare-deals UNIONS Walmart's
  recent captures, so a 50-term throttled day just backfills from the last comprehensive capture -
  but the union needs a comprehensive capture inside its 14-day window. build-walmart-deals stamps
  `pull_terms` on every output, and audit-walmart-fullpull.ps1 warns (guards) + emails
  (check-ad-cycles, deduped) from day 10 if no >=200-term capture is fresh. See
  INCIDENT-2026-07-23-walmart-flood.md for why a 50-term pull once collapsed the board 410 -> 80.
- Flipp + SFML responses must be fetched with `Invoke-WebRequest -UseBasicParsing` then UTF-8-decoded + `ConvertFrom-Json` (or `[xml]`). `Invoke-RestMethod` returns empty objects for these.
- Aldi's store field is `merchant_store_code` (not `store_code`); the Omaha 72nd St store is `446-048` at zip `68132`. Its weekly publication id changes every week â€” the script always fetches the current one.
- Family Fare's Freshop API caps ~100 items/page; the script pages by the reported `total` (~1,200 items).
- `$PSScriptRoot` is empty inside a `param()` default under `-File` â€” output dirs are resolved in the script body.

## Direct product-URL layer (the "See item" links + price verification)

Every store price chip on the published page carries a **"See item"** link straight to that store's own
product page, with the price **verified at the source** (not just copied from the ad). Links live in the
durable **`product-urls.json`** (keyed `commodity id -> store -> {url, price, size, name, board_pu}`), which
survives weekly regeneration because commodity ids are stable. `build-deals-page.ps1` renders a link for any
chip that has one.

### Weekly incremental refresh ("refresh only what changed")

1. **Find the gaps.** `resolve-worklist.ps1` compares the current comparison + recipe board against
   `product-urls.json` and writes `out\url-worklist.json` listing chips that need work, with a `reason`:
   - **missing** - no link yet.
   - **stale** - the *board* per-unit moved off the `board_pu` snapshot taken when the link was resolved.
     Board-to-board (never shelf-vs-ad), so verified links don't churn. **This is also the ad-roll-off
     trigger**: when a sale ends the board price changes, so the store's link is re-resolved to whatever
     product is now cheapest for that commodity.
   - **mismatch** - the linked product's own price does NOT equal the board price shown next to it (the
     eggs bug: board is the budget-brand/sale price, link points at a pricier brand). Run `audit-links.ps1`
     anytime for the same check as a standalone report (`out\link-audit.json`).
   Each worklist chip's `term` is set to the board's exact source product name (`stores[].item`, e.g.
   "That's Smart! Large Eggs") so re-resolution links the RIGHT SKU, not just any product of the commodity.
2. **Resolve only those chips**, per store, in Chrome (methods below) - search the chip's `term` (the exact
   board item), verify the found product's price matches the board price, write
   `out\url-inputs\store-<store>-urls.json`. Append a number for correction/extra passes
   (`store-hyvee2-urls.json`, `store-hyvee3-urls.json`); **later numbers override earlier for the same
   id+store** (merge sorts base-first then numbered). Each row is `{id,url,price,size,name}`. Always eyeball
   names and drop wrong-category picks (roasted-pepper spice for a fresh bell pepper; a prepared meal for
   canned chickpeas). Fresh produce sold by weight often has no fixed-price page - leave it as a gap.
3. **Merge** `merge-product-urls.ps1` (auto-discovers `out\url-inputs\store-*-urls.json`, infers the store
   from the filename, accumulates into `product-urls.json`).
4. **Stamp** `stamp-board-pu.ps1` (records the current board per-unit onto every link so step 1 stays quiet).
5. **Build + publish** `build-deals-page.ps1` then `publish-deals-page.ps1`.

### PUBLISH ORDER vs THE FEED CACHE (why new chips can lag ~30 min)

`board.json` is a Workers static asset deployed by the git-triggered Cloudflare build, cached per-colo for
max-age=1800 keyed by full URL (including `?v=`). The Ghost post ships the new `?v=` the moment
publish-deals-page runs, but the asset only updates when the PUSH finishes deploying (~1-3 min). Any visitor
who hits the new `?v=` in that gap pins the PREVIOUS build's bytes at their colo for up to 30 minutes. That
window only ever shows the last fully-gated board (never unverified data), but it delays new features/chips.
RULE for interactive sessions: **push first, probe with a throwaway cache-buster param until the content converges (compare NORMALIZED content or byte length, never raw sha - git's CRLF-to-LF normalization makes the served file one byte smaller than the working copy, so a raw-byte hash never matches),
THEN publish the post.** The daily cloud pipeline publishes before its end-of-run commit and accepts the lag.

### SINGLE-WRITER RULE for product-urls.json

Up to six things run concurrently against this repo (cloud daily, heartbeat, 3 daily local agents, interactive
sessions). `product-urls.json` has ONE direct writer: **the daily pipeline** (derive-links-from-prices ->
fix-links-ff -> prune-bad-links inside check-ad-cycles). Everything else - browser passes, resolver batches,
one-off sessions - writes candidate rows to **`out\url-inputs\store-*-urls.json`** and lets
`merge-product-urls.ps1` fold them in. Never hand-edit product-urls.json in a session while the daily could be
running; if you must run the merge yourself, check `git status`/mtimes first and re-verify after (a file that
changes under you means another writer is active - stand down and check its result instead of overwriting).
The archive of consumed inputs lives in `out\url-inputs-archive\`.

**ORDER RULE, and it is not cosmetic: every writer of `product-urls.json` must be followed by
`audit-name-drift.ps1` before `guards.ps1` runs.** `audit-tile-integrity.ps1` does not compute its
WRONG-PRODUCT half - it READS `out\name-drift.json` - so it refuses to grade at all (HELD, exit 2) whenever
that file is older than `product-urls.json`, on the sound ground that flags written before a link changed
cannot describe the link now. Run the audits in the other order and the whole board hard-fails on a hold,
with nothing actually wrong in the data. `prune-bad-links` is the writer that trips this most (it READS
name-drift and then WRITES product-urls, so it stales its own input by construction - measured 2026-08-22,
three blocked publishes with the two files 2 seconds apart). Every live chain now runs prune/merge/sync/
relink FIRST and `audit-name-drift` LAST: `check-ad-cycles` ship path and its consistency auto-repair,
`weekly-post-capture -Phase publish` and `-Phase links`, `relink-drifted-cells`. Keep it that way when
adding a writer.

### Per-store resolver methods (all proven)

| Store | Data source | eval? | Notes |
|---|---|---|---|
| Walmart | `__NEXT_DATA__` `...searchResult.itemStacks[].items[]` | no (CSP) | 2026-07: `priceInfo.currentPrice.price` is GONE - read `priceInfo.itemPrice`/`linePrice`/`unitPrice`; `unitPrice` may be an object (`.price`) or a display string ("$2.48/lb", "5.4 c/fl oz") - parse both. Fresh produce often has no price. A 200 with no `__NEXT_DATA__` = PerimeterX challenge, not data. |
| Sam's Club | same `__NEXT_DATA__` shape | yes | `priceInfo.linePrice`/`itemPrice` are `$`-strings; `canonicalUrl` -> `/ip/`; bare `/ip/<id>` 301s to the canonical slug (proven 2026-07-17; bogus id renders an "Uh-oh" h1, so verify the RENDERED page, not the status). Warehouse packs, judge by `unitPrice`. |
| Family Fare | Freshop API `api.freshop.ncrcloud.com/1/products?app_key=family_fare&store_id=6401&q=` | n/a | `base_price` + `canonical_url`; ~350ms pacing, 400s after ~40 calls (400 = throttle AND unknown-field - indistinguishable; fall back to minimal `fields=`). |
| Hy-Vee | headless REST `POST /aisles-online/api/search/products` (storeId 1465 in body) or client-rendered DOM `a[href*="/aisles-online/p/"]` | REST: no | bogus product page = 200 with `pageProps.notFound===true` - check it. Fresh produce priced by weight = no fixed price. |
| Aldi | client-rendered DOM `a[href*="/store/aldi/products/"]`; search is `/store/aldi/s?k=<term>` (NOT `?q=` - that redirects to an unrelated carousel) | yes | store-brand names; resolver body stored in `localStorage.AL_RESOLVE`; dead item renders h1 "Item Unavailable" on a 200. |
| Baker's | hidden same-origin IFRAME render of `/search?query=` + scroll + stable-count poll, then anchor-climb from `a[href*="/p/"]` | yes | plain `fetch()`+DOMParser is DEAD (client-rendered shell, zero cards) and so is the `.ProductCard`/`[data-testid^="product-card"]` class - climb from anchors to the nearest container with a `$`. Kroger banner, Akamai-gated; store = Saddlecreek; cards print their own "$X.XX/oz". `localStorage.BK_RESOLVE`. |

Common pattern for the three eval stores: store the resolver body once in `localStorage`, then per item
`navigate(search) -> poll until cards render -> set A={id,c,u,s} -> eval(resolver)`; it writes the best
per-unit match to `localStorage.<prefix>_<id>`; DOM-dump + `get_page_text` to harvest past the ~1.3KB
tool-output cap. Full method notes live in memory **grocery-product-urls.md**.

Genuine long-tail gaps that resist automated matching: fresh produce sold **by weight** (no clickable
fixed-price page) at Walmart/Hy-Vee, and **warehouse-only forms** at Sam's (no single apple / small can).
These are listed in `out\url-worklist.json` (reason `missing`) rather than silently dropped.

## Omaha store registry (EVERY price must come from one of these locations)

Brad's hard rule: every source, headless or browser, must be pinned to a verified OMAHA location.
A wrong-city session produces plausible-looking wrong prices (it happened: a fresh shop.fareway.com
session silently defaulted to Des Moines). Canonical identities + where each is enforced:

| Store | Omaha identity | Enforced by |
|---|---|---|
| Hy-Vee (ads) | Flipp collection 1465, zip 68106 | pull-grocery-ads.ps1 hard zip gate (`Test-OmahaZip`) |
| Hy-Vee (everyday) | Aisles Online store "Omaha #1, NE" | weekly SKILL step D verify |
| Aldi (ads) | Flipp merchant_store_code 446-048 (Omaha) | pull-grocery-ads.ps1 hard zip gate |
| Aldi (everyday) | aldi.us "ALDI - OLA 42 - Omaha", 68137 | weekly SKILL step F2 verify |
| Family Fare | Freshop store_id **6401** = 50th & Grover St, 5019 Grover St, Omaha 68106 | pull-regular-familyfare.ps1 runtime city assertion (exit 2 on non-Omaha) + ads gate |
| Baker's | "Pickup at Saddlecreek", 888 S Saddle Creek Rd, Omaha 68106 | weekly steps A + C verify, daily SKILL hard rule |
| Walmart | "Omaha L St Supercenter", 12850 L St, 68137 | weekly SKILL step E verify |
| Sam's Club | "Omaha Sam's Club", 13130 L St, 68137 | weekly SKILL step B verify |
| Fareway (storefront) | shopId **16668805** / postalCode **68136** = 17070 Audrey St, Omaha | daily + weekly SKILLs: graphql network-param check (label alone is NOT proof) |
| Fareway (ads) | OmahaGroup_*.jpg filenames | pull-fareway-ads.ps1 Omaha+current gates, then the complete+clean install gate (adpages-lib.ps1) |

If a store moves/renames, update this table AND the enforcing script/SKILL together.

## Adding a NEW commodity (the /suggest-an-item/ playbook)

Proven end-to-end 2026-07-12 with `laundry-detergent` (the first reader-suggested item: A&H Plus OxiClean).
Once registered, EVERY automation picks the item up with no further wiring (all pulls iterate
`commodity-search.json`; the board/guards/feed/history/alerts key off `commodities.json`).

1. **`commodities.json`** - id, label, unit, include/exclude. Write the include to tolerate every store's
   REAL naming (test it against actual product names first: Family Fare calls the A&H OxiClean line
   "Odor Blasters, Stain Fighters" without the word OxiClean). Never require `\s+` between words that a
   store might separate. NEVER leave a bare `lb` token in a deal's item NAME (per-lb marker trap).
2. **`categories.json`** - add the id to a category (create one if needed; `household` was added this way).
3. **`commodity-search.json`** - the search term every store pull uses. TEST it: an over-specific term
   ("arm hammer oxiclean") can return nothing while a broader one ("arm and hammer detergent") finds the
   product; prefer broad + let include/exclude filter.
4. **Same-day pricing at all 7 stores** (each price needs a matching product URL in `out\url-inputs\`):
   Walmart = product page in the browser (`__NEXT_DATA__`; raw fetch gets bot-walled); Sam's = browser
   search; Hy-Vee = Aisles Online (verify "Omaha #1, NE"); Family Fare = Freshop API (base_price everyday,
   sale_price -> `extra-deals-<date>.json`); Fareway = storefront browser (VERIFY shopId 16668805 /
   postalCode 68136 in the graphql network params - a fresh session can default to a NON-Omaha store);
   Baker's = browser (Akamai; if blocked, skip - the term is registered so the daily/weekly agents fill it).
5. **Confirmed not carried** (actually searched the store, product absent) -> `not-carried.json`
   ("Doesn't carry" card). **Couldn't verify today** -> do nothing (the board auto-renders a
   "No price yet" card; the agents fill it on their next run).
6. Run: compare-deals -> recipe-overlay -> publish-deals-page (the store-coverage + consistency gates run
   inside). `notify-item-added.ps1` then emails any /suggest-an-item/ requester who asked for the item and
   left an email.

## The comparison engine (built)

`compare-deals.ps1` normalizes every deal to a per-unit price, buckets by commodity (include/exclude rules),
and ranks the cheapest per store; `build-deals-page.ps1` renders the board (every staple shows ALL 7 stores:
a price, or a "Doesn't carry / No price yet" card); `publish-deals-page.ps1` gates (coverage, store-coverage,
consistency) and upserts to Ghost. `check-ad-cycles.ps1` orchestrates it daily.

