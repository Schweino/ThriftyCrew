# V3 real-Chrome capture runbook

## Authority and scope

Cloudflare does not drive retail websites. A local Codex automation uses the connected real Chrome session for
the four sources that still require it: Aldi, Fareway, Sam's Club, and Walmart. Baker's, Family Fare, and Hy-Vee
are server captures owned by the scheduled GitHub job.

The browser automation is a capture producer only. It must not run the legacy compare/publish/Ghost tail. Each
accepted browser pull ends in the immutable local V3 queue. The queue client uploads the artifact and screenshots;
the engine-owned daily job performs matching, promotion, guards, release construction, and the atomic pointer swap.

The canonical historical browser instructions are retained at
`ops/prompt-backup/scheduled-tasks/grocery-browser-stores-refresh/SKILL.md` and
`ops/prompt-backup/scheduled-tasks/grocery-fareway-daily-check/SKILL.md`. Use their current store extraction
methods, but follow this runbook when they disagree about authority or publication.

## Schedule and idempotency

Run the automation every day at 06:15 America/Chicago.

1. On Wednesday through Saturday, run `platform/scripts/browser-capture-due.ps1 -Json`.
   - `FRESH` (exit 0): the weekly four-store capture is complete. Do not recapture.
   - `INFLIGHT` (exit 2): artifacts are already waiting/retrying in the local queue. Do not recapture; run the
     queue watchdog and report only if it is unhealthy.
   - `DUE` (exit 1): capture only the source IDs listed in `due`. Thursday-Saturday are retry days.
2. On Sunday, Monday, Tuesday, Thursday, Friday, and Saturday, when no weekly four-store capture is running,
   run `grocery/fareway-daily-due.ps1`. Capture Fareway only when it returns `DUE`; honor `FRESH` and `IDLE`.
3. Never run two store sweeps concurrently in the shared Chrome profile.

## Rules shared by every store

- Use the connected real Chrome browser. Do not substitute server HTTP, a search engine, a different retailer,
  or marketplace pricing.
- Codex browser page evaluation is read-only. Do not copy Claude's page-mutating router, iframe, local-storage,
  or Blob-download tricks. Use ordinary top-level Chrome navigation for each search term, read the resulting DOM
  or `__NEXT_DATA__`, and append projected capture rows outside the page. Work in bounded 10-20 term chunks and
  commit each through `tc capture session`; prose progress or a partially written CSV is not a checkpoint.
- Verify Omaha and the price mode before reading any price. Save a screenshot that visibly proves both. If either
  cannot be proved, do not create an artifact.
- Use the store's own first-party surface. Never invent, interpolate, or carry a price from an unrelated product.
- Work `grocery/out/rescue-terms-<store>.txt` first when present, then the complete generated pull order. Capture
  broadly and let the deterministic builders filter. A narrow capture can displace a better prior product.
- Store the product identity shown by the same result that supplied the price: Walmart `usItemId`, Sam's product
  ID, and Aldi/Fareway product URL.
- Retry an ordinary empty/error once. If a human-verification wall survives one retry, do not evade it or solve
  a challenge. Run `grocery/notify-desktop.ps1 -Store <store> -Detail <progress> -AlsoEmail`, continue with another
  store, and leave the affected source due for the next retry day.
- A current Omaha location/price-mode canary is required in every chunk. Bind at least one canary to the SHA-256
  of a proof screenshot so a retailer silently resetting fulfillment during a long sweep is detectable.
- Record exact term outcomes, row counts, attempts, and time intervals. A challenge is `blocked`, never `empty`.
  A capture is `full` only when every worklist term is `success` or verified `empty`.
- Every term records its bounded result-depth target, loaded/available counts, page count, continuation state, and
  termination. Success requires either the real end of results or reaching the declared target; a truncated page
  is never complete.
- Every accepted discovery row retains an internal truth record with page URL and position, capture instant,
  location/mode, raw visible price/name/size, parsed integer cents, and exact parser rule. Walmart and Sam's also
  require the independently read structured product key/name/size/price, and both channels must agree.
- Never guess a decimal, glue split visual nodes, repair a product identity, or silently discard an ambiguous
  loaded result. The chunk validator fails accepted rows it cannot reproduce exactly.
- Capture first-party taxonomy/department/category fields when present. Leave taxonomy blank when unavailable;
  never infer a shelf path from the product name.

## Store methods

### Walmart

Verify the pickup store is Omaha L St Supercenter, 12850 L St, Omaha 68137. Build the full priority order with
`grocery/build-pull-order.ps1 -Store Walmart`; every commodity term is required. Navigate Chrome normally to each
search URL and read each result from
`__NEXT_DATA__.props.pageProps.initialData.searchResult.itemStacks[].items[]`. Price fields are under
`priceInfo.priceDetails.priceLines`: `CURRENT_PRICE` and `UNIT_PRICE`. Keep broad candidate sets and preserve
`usItemId`, exact package size, product URL/image, and `departmentName/category.categoryPathId` when present. Stop after three consecutive challenge/no-data pages. Write the UTF-8 pipe CSV to
`grocery/out/captures/walmart-capture-<date>.csv`, then run `grocery/build-walmart-deals.ps1`.

Do not enqueue a weekly Walmart artifact unless the capture attempted the complete worklist. Treat a wall-truncated
slice as retryable evidence, not a successful weekly capture.

### Sam's Club

Verify an Omaha club is selected. Build the priority order with
`grocery/build-pull-order.ps1 -Store "Sam's Club"`. Navigate to `/s/<term>` and parse the resulting page's
`__NEXT_DATA__`; project only query, name, line/item price, unit price, product ID, exact package size, product URL/image, and available
first-party taxonomy as `departmentName/category.categoryPathId`. Keep broad candidate sets, write a UTF-8 `q|n|lp|up|id|size|taxonomy_path|url|image_url` capture, and run `grocery/build-sams-deals.ps1`. Do not return or persist raw
tracking/cookie-bearing product objects.

Use `scripts/browser-capture-adapters/next-data-v2.mjs` with no more than ten Sam's terms per chunk and at least two
seconds between term navigations. A challenge/block ends the Sam's lane immediately; do not retry it in the same
cycle. Keep Sam's isolated from Walmart so either retailer can cool down without pausing the other.

### Aldi

Verify `ALDI - OLA 42 - Omaha` and independently verify `In-Store`; delivery/pickup prices are not acceptable.
Navigate normally to `/store/aldi/s?k=<term>` and wait for product anchors before extracting. Parse the card's
authoritative `Current price: $X.XX` text, not glued visual price nodes. Take the name
and identity from the product URL, retain card size and the explicit category/aisle label printed on the card, and write UTF-8
`id|term|name|prices|unit|size|href|taxonomy_path`. Run `grocery/build-aldi-regular.ps1`, followed by the existing carry-forward
and degraded-size repair commands only when the builder reports a complete, current pull.

ALDI is a deliberately low-rate lane: use `scripts/browser-capture-adapters/aldi-v2.mjs`, capture no more than three
terms per chunk, leave at least five seconds between term navigations, and leave at least two minutes between chunks.
Run other stores during that cooldown instead of increasing ALDI concurrency. A challenge/block ends the ALDI lane
immediately; do not retry it in the same cycle or attempt a bypass. Resume only in a later operator cycle after a
cooldown and a fresh Omaha/In-Store canary.

### Fareway

Verify the stable Omaha address `17070 Audrey Street, Omaha, NE 68136` from the page state and independently
verify `In-Store`; do not rely on the reissuable shop ID. Navigate normally to each storefront search URL, use the
product image `alt` for the product name, the product URL for identity, the explicit category/aisle label printed on the card, and the authoritative `Current price: $X.XX` / original-price
text. Retry empty terms once. Feed the repaired JSONL into `grocery/select-fareway-shop.ps1`, then run
`grocery/build-fareway-regular.ps1 -Today <date> -ModeVerified <date>`. Every selected row must retain `url`.

## Durable capture session

Create one rescue-first, query-only worklist from the generated files, then initialize before the first term. The
generated pull order is `commodityId<TAB>query` while the rescue file is `query<TAB>commodityId<TAB>...`; never
concatenate or pass either TSV directly to the session initializer.

```powershell
pnpm tc capture session worklist <pull-order.txt> <rescue-terms.txt-or-> <worklist.json>
pnpm tc capture session init <aldi|fareway|sams|walmart> <worklist.txt> <session-directory> <started-at-iso>
```

For every 10-20-term discovery chunk (except ALDI's three-term rate-limited chunks), write JSON containing `version: 2`, `phase: discovery`, `store`, one current
location/mode `canary`, exact `terms` with `retrieval`, and projected `rows` with internal `_capture` truth.
Append with `pnpm tc capture session append <session-directory> <chunk.json>`.
Use `pnpm tc capture session status <session-directory>` to resume. A later successful retry replaces the earlier
blocked result for that term while both immutable chunks remain evidence.

After discovery is complete, create the deterministic independent second-pass worklist:

```powershell
pnpm tc capture session verification-plan <session-directory> <verification-plan.json>
```

The plan includes likely lowest-price winners, a stable audit sample, produce/count/multi-buy/outlier risks, and
duplicate-price conflicts. Revisit each target with a fresh top-level navigation. Append `version: 2`,
`phase: verification` chunks containing the plan row/hash and a newly read complete truth record. A changed row
must be recaptured as a new discovery result and replanned; missing, blocked, stale, copied, or disagreeing
verification cannot authorize publication.

Finalize after exhausting the worklist:

```powershell
pnpm tc capture session finalize <session-directory> <projected-capture> <capture-session-manifest.json> <finished-at-iso>
```

The finalizer deterministically merges the latest result for every term, strips internal `_capture` fields from
the builder input, hashes the projected capture, computes the accuracy/anomaly report, and emits the authoritative
term ledger. It cannot label a session `full` while a term, pagination envelope, raw-price contract, location/mode
check, or required second-pass verification is unresolved. Beginning 2026-08-12, Cloudflare independently
recomputes the report from the immutable R2 manifest before it validates or promotes the batch.

## V3 handoff

For each successful store pull, keep the Omaha/mode screenshot and run:

```powershell
powershell -ExecutionPolicy Bypass -File platform/scripts/enqueue-browser-capture.ps1 `
  -Store <aldi|fareway|sams|walmart> `
  -RegularFile <grocery/out/regular/...json> `
  -SessionManifest <capture-session-manifest.json> `
  -RawCapture <projected-capture> `
  -Screenshot <proof.png> `
  -EvidenceUrl <https store URL shown in proof> `
  -Statement <what Chrome visibly proved>
```

The wrapper verifies that the raw capture, manifest, and screenshot hashes bind to one session, builds and
validates the V3 artifact, and atomically enqueues all three evidence classes. Image magic bytes and minimum
dimensions are checked locally and again by the Worker. The installed five-minute client drains the queue with
hashes, retries, receipts, and a source-scoped credential. Run the queue watchdog at the end. Do not call
`capture promote-ready-browser` from the PC automation; the engine identity owns matching and promotion.

Success means every required source is remotely promoted (or later superseded), passed matching, and carries a
full term ledger, not merely that browser files or local upload receipts exist. The next
daily engine run promotes validated browser batches and publishes only if every hard guard passes. On failure,
leave the last good release live and report the exact store, attempted terms, captured rows, screenshots, queue
state, and whether operator action is required.

## Independent remote SLA

Cloudflare evaluates the remote weekly result every hour through the `browser-capture-sla` schedule. This
monitor does not depend on the capture PC, its queue, or Codex being online. Beginning with the 2026-08-12
cycle, it opens a digest alert after Saturday noon Central unless all four strict browser sources are full,
promoted or superseded, matched, and backed by screenshot, session-manifest, and projected-raw evidence. The
alert resolves automatically when those remote conditions recover.

## Performance telemetry

Sealing a browser batch records immutable performance telemetry from its verified capture-session manifest.
Use `pnpm tc capture metrics [limit]` for recent history. The public `/api/v2/status` response includes only the
latest aggregate per source under `browserCaptureTelemetry`. Review retries, total duration, p50/p95 term
duration, projected-versus-accepted rows, and taxonomy coverage after each weekly cycle. A successful capture
with rising latency, retries, or falling row/taxonomy yield is an early-warning signal even before the SLA fails.
