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
  or `__NEXT_DATA__`, and append projected capture rows to the local UTF-8 capture file outside the page. Work in
  bounded 10-20 term chunks so progress remains visible and a stopped run can resume without losing a store.
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
- A partial file may be queued only when its coverage is explicitly partial and it is deeper than the source it
  replaces. Never label a partial pull full.

## Store methods

### Walmart

Verify the pickup store is Omaha L St Supercenter, 12850 L St, Omaha 68137. Build the full priority order with
`grocery/build-pull-order.ps1 -Store Walmart`; every commodity term is required. Navigate Chrome normally to each
search URL and read each result from
`__NEXT_DATA__.props.pageProps.initialData.searchResult.itemStacks[].items[]`. Price fields are under
`priceInfo.priceDetails.priceLines`: `CURRENT_PRICE` and `UNIT_PRICE`. Keep broad candidate sets and preserve
`usItemId`. Stop after three consecutive challenge/no-data pages. Write the UTF-8 pipe CSV to
`grocery/out/captures/walmart-capture-<date>.csv`, then run `grocery/build-walmart-deals.ps1`.

Do not enqueue a weekly Walmart artifact unless the capture attempted the complete worklist. Treat a wall-truncated
slice as retryable evidence, not a successful weekly capture.

### Sam's Club

Verify an Omaha club is selected. Build the priority order with
`grocery/build-pull-order.ps1 -Store "Sam's Club"`. Navigate to `/s/<term>` and parse the resulting page's
`__NEXT_DATA__`; project only name, line/item price, unit price, and product ID. Keep broad candidate
sets, write a UTF-8 `q|n|lp|up|id` capture, and run `grocery/build-sams-deals.ps1`. Do not return or persist raw
tracking/cookie-bearing product objects.

### Aldi

Verify `ALDI - OLA 42 - Omaha` and independently verify `In-Store`; delivery/pickup prices are not acceptable.
Navigate normally to `/store/aldi/s?k=<term>` and wait for product anchors before extracting. Parse the card's
authoritative `Current price: $X.XX` text, not glued visual price nodes. Take the name
and identity from the product URL, retain card size, and write UTF-8
`id|term|name|prices|unit|size|href`. Run `grocery/build-aldi-regular.ps1`, followed by the existing carry-forward
and degraded-size repair commands only when the builder reports a complete, current pull.

### Fareway

Verify the stable Omaha address `17070 Audrey Street, Omaha, NE 68136` from the page state and independently
verify `In-Store`; do not rely on the reissuable shop ID. Navigate normally to each storefront search URL, use the
product image `alt` for the product name, the product URL for identity, and the authoritative `Current price: $X.XX` / original-price
text. Retry empty terms once. Feed the repaired JSONL into `grocery/select-fareway-shop.ps1`, then run
`grocery/build-fareway-regular.ps1 -Today <date> -ModeVerified <date>`. Every selected row must retain `url`.

## V3 handoff

For each successful store pull, keep the Omaha/mode screenshot and run:

```powershell
powershell -ExecutionPolicy Bypass -File platform/scripts/enqueue-browser-capture.ps1 `
  -Store <aldi|fareway|sams|walmart> `
  -RegularFile <grocery/out/regular/...json> `
  -Screenshot <proof.png> `
  -EvidenceUrl <https store URL shown in proof> `
  -Statement <what Chrome visibly proved>
```

The wrapper builds and validates a signed-shape V3 artifact and atomically enqueues it. It never reads or exposes
the capture credential. The installed five-minute client drains the queue with hashes, retries, receipts, and a
source-scoped credential. Run the queue watchdog at the end. Do not call `capture promote-ready-browser` from the
PC automation; the engine identity owns promotion.

Success means all required stores are completed in the local queue, not merely that browser files exist. The next
daily engine run promotes validated browser batches and publishes only if every hard guard passes. On failure,
leave the last good release live and report the exact store, attempted terms, captured rows, screenshots, queue
state, and whether operator action is required.
