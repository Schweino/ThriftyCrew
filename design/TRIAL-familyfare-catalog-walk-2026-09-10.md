# TRIAL: Family Fare catalog walk (build step 3b, 2026-09-10)

Measurement only. Nothing in the pipeline changed. No file under `grocery\out\` was written, and the cursor, the
rotation and `grocery\sale-windows.json` were not touched. Raw pages went to a session scratch directory outside the
repo. Asked for by `design/PLAN-zero-alert-days-2026-09-10.md` section 7 ("Ruling 7 result"), after
`design/PROBE-store-direct-data-2026-09-10.md` found a search-free catalog browse. The quarterly rotation ruling is
untouched.

## Verdict first

Rubric (from the dispatch): a walk is only worth building if (1) it is complete, (2) the follow-up search still
succeeds, and (3) it covers what the rotation buys.

| Condition | Verdict | Numbers |
|---|---|---|
| (1) The walk is complete | **NOT MET** | `page=` is ignored: 186 pages returned the same 100 products (18,600 rows, 100 unique ids, total 18,557). `skip=` does page (6,600 rows, 6,600 unique ids, 0 duplicates), but that walk was refused at request 67 with HTTP 400 and body `{"error_code":429}`, after 6,600 of 18,557 products (35.6%). |
| (2) The follow-up search still succeeds | **COULD NOT VERIFY** | The one `q=` search answered 200 with 22 items right after the `page=` walk. That walk re-read one page, so it did not test a real walk. The real (`skip=`) walk hit the search throttle signature itself at request 67. Whether a search after it would also be refused was not tested, because the trial's one search was already spent. |
| (3) It covers what the rotation buys | **COULD NOT VERIFY** | Only 35.6% of the catalog was read. Lower bound: 2,339 of 5,395 rows in today's merged everyday file were found in that slice (889 by product id, 1,450 by the builder's name and size key). 112 of the 124 terms whose rows carry `found_by_term` have at least one row in it. |

**Recommendation: do not build the walk as a lane yet.** The reasons and the next measurement are at the end.

## When it ran, and why that moment was clear of the schedule

All times are CDT (UTC-5) on 2026-09-10.

- **Family Fare traffic earlier today.** Rotation windows landed at 07:01:16, 08:01:16 and 10:33:59
  (`grocery\out\capture-cursor-log.jsonl`). `capture-familyfare-2026-09-10.json` was written at 10:32:58 and the
  throttled diagnostic at 10:33:44. The probe's 4 browse GETs ran at about 15:30 to 15:46.
- **Scheduled tasks that reach Freshop** (`Get-ScheduledTask 'TC *'`):
  - `TC Grocery Ad Pulls 0700` runs `capture-run.ps1 -Kind ad` hourly from 07:00 to 12:00.
  - `TC Grocery Daily Capture 0800` runs `capture-run.ps1 -Kind daily` hourly from 08:00 to 14:00. Its 14:00 run
    logged no Family Fare window.
  - The next run of either is 2026-09-11 07:00.
  - No task outside `TC *` references grocery or Freshop, and `familyfare-sweep.ps1` has no task of its own.
- **Other Freshop callers, checked live.** No `hunt-daemon` or `probe-ingredient` process was running. The running
  `TC Recipe Harvest Crawl` (`harvest-crawl.ps1`) never calls Freshop.
- **The trial window.** Freshop requests ran from 20:09:00 to 20:28:23. That was 9 h 35 min after the last rotation
  window, 6 h 09 min after the last capture-run slot, and 10 h 31 min before the next scheduled pull.

## What was requested

**Rules for every request:**
- token-less, with `User-Agent: Mozilla/5.0`;
- one request at a time, at least 2.5 s from the end of one to the start of the next;
- stop on the first 4xx;
- one polite retry after 30 s on a 5xx or no response (none was needed).

**Fields:** the builder's `$FIELDS_RICH`, verbatim: `id,name,size,price,base_price,unit_price,canonical_url`
(`grocery/pull-regular-familyfare.ps1:556`).

**Browse base:** `GET https://api.freshop.ncrcloud.com/1/products?app_key=family_fare&store_id=6401&department_id=22585550&department_id_cascade=true`

| Phase | Time | Requests | Result |
|---|---|---|---|
| A. `limit=200&page=N` | 20:09:00 to 20:10:00 | 20 | Every page was 200 OK with 100 rows. I stopped it once the clamp showed, because a 93-page plan would have under-read. |
| B. `limit=100&page=N`, N = 1 to 186 | 20:10:57 to 20:20:17 | 186 | Every page was 200 OK with 100 rows, and `total` stayed 18,557 throughout. |
| C. One `q=milk gallon&limit=25`, in the builder's request shape | Right after B, before 20:20:27 | 1 | 200 OK |
| D. `limit=500&page=1` | Same | 1 | 200 OK, 100 rows (clamped) |
| E. `limit=100&page=1` with `,status` added to the fields | Same | 1 | 200 OK |
| F. Paging probe: `offset=100`, `skip=100`, `skip=18500` (sent twice by a script slip), `/1/offers?limit=200&page=1`, `page=2` | 20:21:48 to 20:22:06 | 6 | All 200 OK |
| G. `limit=100&skip=(N-1)*100`, N = 1 to 186 | 20:24:44 to 20:28:23 | 67 | 66 pages 200 OK. Request 67 (`skip=6600`): HTTP 400 in 108 ms, body `{"error_code":429}`. The walk stopped with no retry. |

**Total:** 282 Freshop requests, one of them a `q=` search.

## Page size

- **Tested:** 200 (phase A), 100 (phases B and G) and 500 (phase D).
- **Clamping:** `limit=200` and `limit=500` both answer HTTP 200 and are **silently clamped to 100 rows**. There is no
  error, no field says so, and `total` stays 18,557. 1,000 and 2,000 were not sent, because 500 already clamped.
- **Largest effective page on a department browse: 100.** A builder that plans its pages from its own `limit` reads
  half the catalog at `limit=200` and gets no error.
- **Not universal:** `/1/offers` returned 200 rows at `limit=200`.

## Pages, rows, duplicates and missing ids

- **`page=` walk (phase B):**
  - 186 pages and 18,600 rows, but **100 unique ids**. Every id came back 186 times, and 18,457 of the 18,557
    products were never returned.
  - `page=` is ignored, and `offset=100` also returned page 1 unchanged.
  - Phase A's 20 pages at `limit=200` matched phase B's first 20 pages exactly, in the same order.
- **`skip=` walk (phase G):**
  - 66 pages and 6,600 rows, with 6,600 unique ids, 0 duplicates and 0 rows without an id.
  - `skip=100` shares no ids with page 1. `skip=18500` returned exactly 57 rows (18,557 minus 18,500), so the tail
    of the catalog can be reached.
  - The `skip=100` page read at 20:21 matched the walk's page 2 read at 20:24 exactly, in the same order, so the
    default ordering held for those three minutes.
  - 11,957 products were never fetched because of the throttle. Gaps past row 6,600: could not verify.

## The follow-up search

**Request:** `GET /1/products?app_key=family_fare&store_id=6401&q=milk%20gallon&limit=25&fields=<builder fields>`

**Result:** HTTP 200 in 1,511 ms. Body keys `total,items`, with `total=22` and 22 items. 20 of those 22 ids are in
the 6,600-product `skip=` slice.

**What it proves is narrow:**
- It came after 206 browse requests (phases A and B) that returned only 100 distinct products.
- Six probe requests later, the `skip=` walk was refused at its 67th request with the same `{"error_code":429}` the
  estate has recorded on search since 2026-08-20.

**Two readings fit, and this trial cannot tell them apart:**
1. **The limiter counts distinct result sets.** Requests the server resolves to a page it has already served cost
   little. Counting only distinct results, the refusal came after about 70, close to the "60 to 70 search terms per
   window" in `pull-regular-familyfare.ps1`'s comments.
2. **The limiter counts every request.** Then the budget was about 281 requests in 19 minutes.

**What it contradicts:** under either reading, the note that browse "kept answering 200 throughout a throttle" does
not hold for a walk of distinct pages. That note comes from `pull-regular-familyfare.ps1` around line 583
(2026-07-30) and is repeated in the probe. A browse of distinct pages is throttled with the search signature.

**Still open:** whether browse and search draw on one shared allowance. Could not verify.

## How long the walk took

- **`page=` walk (phase B):** 559.7 s for 186 requests. Server time summed to 94.9 s; the rest was pacing.
- **`skip=` walk (phase G):** 218.9 s for 67 requests. Server time summed to 53.1 s, and the slowest response took
  1,057 ms.
- **Projected, not measured:** a full 186-page `skip=` walk at the same pacing would take about 10 minutes, if
  nothing refused it.

## What the catalog rows carry, against what the builder needs

Measured on the 6,600 `skip=` rows unless a row says otherwise.

| The builder uses (`pull-regular-familyfare.ps1`) | Catalog row | Measured |
|---|---|---|
| `name` (with size, the row key at line 651) | Present | 0 missing |
| `size` | Present | 0 missing |
| `price`, read by `Get-FfPrice` (`ff-price-lib.ps1:50`) | Present | 0 missing. 76 rows carry multi-buy text ("N for $X"), which `Get-FfPrice` already drops. |
| `base_price` | Requested | How many rows carry it was not counted. The builder marks a sale from `/offers`, not from this field (comment from line 456). |
| `id` (becomes `product_id`) and `canonical_url` | Present | 0 missing for either |
| `unit_price` | Present | Equals `price` on 6,524 of 6,600 rows. The 76 that differ match the multi-buy count, but that was not checked row by row. It is the package price, not a per-unit price, as the probe said, so per-unit must still come from `size`. |
| `status` | **Not in the builder's field list** | Added once (phase E): `available` on 100 of 100 rows. That is a 100-row sample only. |
| Sale price and sale window | Absent | Stay on `/1/offers` (see the finding below) |
| Agreement with search | | 72 of today's 129 fresh rows (bought by search at 10:33) matched a catalog row. Price was equal on 72 of 72, and size on 72 of 72. |

## Coverage against what the rotation buys

**Inputs:**
- `grocery\out\regular\family-fare-regular-2026-09-10.json`: 5,395 rows, 129 fresh and 5,266 carried.
- `grocery\commodity-search.json`: 602 term pairs, 599 distinct terms.
- `grocery\out\ff-term-ledger.json`: 599 terms.

**Join:** by product id first, then by the builder's own `name|size` key. That key does not prove identity: in the
6,600-row slice, 6,600 ids map to only 6,586 keys.

**Results:**
- **Rows found in the 35.6% slice:** 2,339 of 5,395 (889 by id, 1,450 by `name|size`). 3,056 were not found, and 663
  of those carry a product id.
- **Per term:**
  - Only 1,552 rows carry `found_by_term`, and all of them carry a product id, so per-term coverage can be measured
    for 124 of the 599 terms.
  - 112 of those 124 terms have at least one row in the slice, and 20 have every row in it.
  - 12 have no row in it, for example `15 bean soup mix`, `active dry yeast`, `all purpose cleaner` and
    `honeydew melon`.
  - The other 475 terms have no row carrying `found_by_term`.
- **Verdict:** with 64.4% of the catalog unread, whether the walk covers what the rotation buys could not be
  verified. The slice gives a lower bound only.

## A finding outside the question: `/offers` ignores `page=` too

**Measured:** `GET /1/offers?app_key=family_fare&store_id=6401&limit=200&page=1` returned `total=8600` and 200 rows.
`page=2` returned the same 200 ids in the same order.

**Why it matters:** `pull-regular-familyfare.ps1:477-509` pages that endpoint exactly this way. It asks for
`page=$offPage` while `(page-1)*200 < total` and `page <= 10`, and dedupes by product id. So at most the same 200 of
about 8,600 offer records reach `$script:FfOffers`, at a cost of up to 10 requests per run.

**Run logs:** each ad-run log read, 2026-09-02 to 09-05, says `Family Fare: 0 product(s) covered by an offer running
today`, from 8,037, 8,872, 8,903 and 9,009 offer records.

**Not verified:**
- Whether the unread records hold offers that run today and fall inside the 90-day bound.
- Whether `pull-grocery-ads.ps1:175`, which pages circular products with `limit=200&page=N` on the same `/products`
  endpoint, is hit by both the clamp and the ignored `page=`. It was not requested.

**Owner:** this touches sale prices, so it belongs to the max-effort money lane. This trial changed nothing.

## Recommendation, with its risks

Against the rubric: (1) **NOT MET**, (2) **COULD NOT VERIFY**, (3) **COULD NOT VERIFY**. **Do not build the walk as a
lane.** The quarterly rotation ruling stands.

**What the trial did establish:**
- **A walk has to page with `skip=` at 100 rows.** `page=` and `offset=` silently return page 1 forever, with HTTP
  200 and a correct `total`. A lane built on them would report a full catalog while holding 100 products.
- **One window holds about 66 distinct browse pages** before `{"error_code":429}`. So a full catalog needs at least 3
  windows, and if browse and search share one allowance, each of those windows starves the rotation.

**The next measurement, if Brad wants the lane considered:** two clear windows.
1. In the first, walk 30 `skip=` pages, then make one `q=` search.
2. In the second, walk only until the first 429, and make no search.

That separates "browse spends the search allowance" from "browse has its own allowance".

**Risks:**
- **Silent under-read.** The clamp and the ignored `page=` both answer 200 with a correct `total`. Any walk must
  check its unique ids against `total`, which is the check this trial used.
- **Budget.** A walk of distinct pages hits the search limiter within about 66 requests.
- **Stability.** `department_id_cascade` and `skip` are undocumented. The ordering held for 3 minutes; over a walk
  spread across several windows, could not verify.
- **Fields.** No sale price, `unit_price` is the package price, and `status` was sampled on 100 rows only.
- **This trial's own footprint.** 282 requests, ending in a 429 at 20:28.
  - Whether the allowance recovers before the 2026-09-11 07:00 window: could not verify. Today's windows at 07:01
    and 08:01, one hour apart, both bought their terms.
  - If tomorrow's 07:01 entry in `capture-cursor-log.jsonl` shows no Family Fare advance, suspect this trial first.

## Harness

- **Scripts:** scratch files outside the repo: `ffwalk\walk.ps1`, `walk-skip.ps1`, `analyze.ps1` and `coverage.ps1`
  in the session scratchpad.
- **Runtime:** Windows PowerShell 5.1 with `Invoke-WebRequest -UseBasicParsing`, run against ThriftyCrew `main`
  HEAD `b19b10a4a`.
- **Pipeline files:** read only, never written.
- **Slip:** `skip=18500` was sent twice (recorded in phase F).
