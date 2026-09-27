# PLAN: the "See item" link rides with the price, so a priced tile always knows its product

Status: DRAFT for Brad, 2026-09-27. Nothing is built. Decisions D1 to D4 at the bottom need a ruling first.

## In one paragraph, for Brad
Every price on the board is read from a real product page, and in most cases that page's product id or link is
sitting on the same row as the price. The board build throws it away when it makes the tile, and the tile's link is
then looked up in a separate file (`grocery/product-urls.json`) that about 20 scripts fill and repair after the fact.
That second record is why 347 tiles are on the "missing or wrong link" backlog today, and why this problem has been
"fixed for good" at least five times since July. The fix: put the link ON the tile, from the same row that set the
price, so price and link are one record and cannot disagree. The separate link file shrinks to a short list of
hand-made exceptions, and most of the repair scripts retire.

## Why (measured 2026-09-27)
Brad, 2026-09-27: *"You cant have a price but no link to the item - that doesnt make any sense, because then where did
the price come from?"* The same ruling already opens `grocery/derive-links-from-prices.ps1` from an earlier round:
*"We cannot have our system fetch a price but not have a link."* That script is a bridge between the two records,
not a removal of the second one, and everything it cannot bridge lands on the backlog.

**The line where the link is dropped.** `grocery/compare-deals.ps1` builds each tile at the `$row = [ordered]@{ store=...`
line (about 3438) with name, price, size, basis and dates, and no product id or link. The comment about 180 lines above it
says so outright: *"the projection above deliberately drops the id fields"*. The build even ranks linkable rows ahead
(`has_identity`, used as a tie-break), then discards the thing it ranked on.

**Where the 347 backlog entries come from.** `out/url-worklist.json` generated 2026-09-27 08:46, board
`comparison-2026-09-27.json`, each entry joined to the 90-day `out/regular` (and `out/sams`) rows that priced it.
One row per entry in the scratch file `link-gap-rows.jsonl`; totals derived from it.

| Cause | Entries | What happens |
|---|---|---|
| Price row HAS the product id, link never written | 134 | 79 refused by `derive-links`' write-time check, because `pu-lib`'s `Get-LinkPerUnit` cannot compute a per-unit the board's engine already computed (per-each "weight is one unit" 25, per-N-pack from a name count 34, square feet). 4 refused by smaller checks. 25 linked after the list was built. 25 pass every check I reproduced and are still unlinked: NOT yet explained. |
| Recipe-board tile | 109 | `resolve-worklist.ps1` lists recipe-board tiles; `derive-links-from-prices.ps1` reads only the main comparison (0 references to `recipe-board.json`). Recipe-board links are never derived at all. |
| Sale price from a store flyer | 83 | Hy-Vee 55, Family Fare 26, Aldi 2. The flyer names an ad line, not a product, so no product link can exist. Counted as "missing" anyway (the 2026-07-31 finding in memory `grocery-links-consistency`, never fixed in the worklist). |
| Price row genuinely has no id | 21 | Aldi 19 (rows carried forward from captures made before Aldi kept `href`), Family Fare 2. |

Per-store identity on today's `out/regular` files, for scale: Walmart 459 of 459 rows carry `item_id` but 0 carry
`link_url`; Aldi 2,936 of 3,876 carry `link_url`; Fareway 805 of 882; Baker's 7,363 of 7,363; Family Fare 3,699 of 5,583
`canonical_url`; Hy-Vee 1,235 of 1,546 `product_id` (the 311 without are mostly `everyday shelf price` rows).

**Why every previous fix leaked back.** Each one patched the bridge, never removed it: the 30% SeeLink band (07-12),
the ad-cell finding (07-31), link-derivation ordering (08-05, memory `link-derivation-order`), the reader/repairer
fileset split (08-30, memory `reporter-outruns-repairer`), the price-versus-URL snapshot (09-20), the two size readers
(09-22, 09-25), the outgrown-link sibling rule (09-26). Two records for one fact, checked by two per-unit engines
(`pricing-math-lib` prices the board, `pu-lib` checks the link), will keep disagreeing at the edges.

## Knowledge consulted
- memory `link-derivation-order`: *"Emit a link ONLY when the gate's per-unit lib can reconcile it... store what you
  audit."* This is why the write-time refusal exists; W3 has to replace the gate's check, not just delete the refusal,
  or the 2026-08-05 publish-gate loop comes back.
- memory `reporter-outruns-repairer`: *"a reporter and its repairer that read different inputs... When a repair is a
  no-op, check what the repairer can SEE."* The recipe-board gap (109) is this class again: worklist reads two boards,
  derive reads one.
- memory `grocery-links-consistency`: flyer-sourced sale cells *"can never have a link"*; key the exclusion on the
  row's SOURCE, not `type=sale`, because storefront sale rows (Fareway, Aldi) do have product pages.
- `grocery/derive-links-from-prices.ps1` header: the per-store identity rules (`Get-RowUrl`): Hy-Vee `product_id`,
  Family Fare `canonical_url` verbatim (never constructed), Walmart and Sam's `item_id` to `/ip/<id>` (Sam's shape
  proven by `sams-url-shape-*.json`), Baker's and browser stores `link_url` verbatim.
- memory `recipe-board-blind-spot`: *"There are TWO boards... Anything that reads only `comparison-*.json` is blind
  to"* the recipe board's live cells. Every item below names both boards, and each bar is counted over both.
- memory `compare-deals-is-not-standalone` and rules:grocery.md gr-04: a mid-day rebuild needs identity emission AND
  the link-repair chain, and `compare-deals.ps1`'s functions are lifted (run `ops\count-source-lifters.ps1` before
  changing the projection); any new helper is a function in a lib, not a `$script:` constant. L1 removes the
  link-repair half of that sequence only after L3 holds.
- CLAUDE.md, Brad 2026-09-27: new machinery must pay for itself. This plan adds one field and one small lib and
  retires machinery; every item states its cost.
- Searched knowledge-search `--estate "product link derived from price row"` and `--estate "tile link identity board
  projection"`; the five memories above were the applicable hits. The negative finding "derive-links never reads
  `recipe-board.json`" was proved against a positive control: the same search over the same file finds its
  `comparison-*` read at line 456.

## Work items
Staged so each stage ships alone, is additive until the stage that removes, and has its own bar.

**L1. The tile carries its link (additive, nothing reads it yet).** Move `Get-RowUrl` and the Sam's URL-shape proof
out of `derive-links-from-prices.ps1` into `grocery/link-identity-lib.ps1` (one function, dot-sourced by both, so
there is one copy of the per-store URL rules). In `compare-deals.ps1`, carry the winning row's URL through the
projection and write two fields on every store tile: `link` (the URL, or absent) and `link_source`:
`row` (from the priced row), `ad` (the row came from a flyer or ad feed: no product page exists), `none` (a storefront
row with no identity: a capture defect). The recipe board's SALE overlay gets it free, because `recipe-overlay.ps1`
runs the same `compare-deals.ps1`; its EVERYDAY baseline (`recipe-board-everyday.json`, refreshed monthly and
corrected by `set-board-cell.ps1`) does not pass through the tile builder, so L1 also stamps `link` and
`link_source` there from the row each baseline cell names, or `none` when it names no row. Cost: two short fields
per tile; no new step in the chain.
Fixtures: MUST FIRE a Walmart row with `item_id` and empty `link_url` gets `/ip/<id>`; MUST NOT FIRE a flyer row gets
`link_source=ad` and no link; CLEAN TWIN a Fareway storefront SALE row keeps its product link (source, not type).

**L2. The page and the feed read the tile's link first.** `build-deals-page.ps1` `SeeLink` uses `tile.link` when
`link_source=row`, and only then falls back to `product-urls.json`, the weekly-ad pill, and store search, in that
order, as today. `export-feed.ps1` ships the tile link beside the price, so recipe pages get it too. A row-derived
link needs no per-unit re-check: it is the product that set the price. Cost: none per push; one branch in SeeLink.

**L3. The link checks judge identity, not arithmetic, for row links.** `audit-tile-integrity.ps1` and the link
checks in `guards.ps1` stop re-pricing a `link_source=row` link through `pu-lib` and instead assert it is the SAME
product: the tile's link equals the URL built from the row the tile names. `pu-lib` keeps checking only the
exception links left in `product-urls.json`. This is what makes removing the write-time refusal safe (memory
`link-derivation-order`). Extends the existing guards; no new gate.

**L4. The backlog lists only what can be fixed.** `resolve-worklist.ps1` reads `link_source` from the tile:
`row` is never listed; `ad` goes to a separate `no_product_page` count, not the backlog; `none` is listed with the
store and capture file, because it is a capture defect, not a link search. It also writes the class per entry, which
retires the scratch join used to measure this plan (the measurement becomes existing machinery).

**L5. Fix the captures that drop identity.** `build-walmart-deals` writes `link_url` from `item_id` (today 0 of
459); Hy-Vee's `everyday shelf price` rows keep `product_id` (311 missing); Aldi rows older than its `href` capture
age out of the 90-day union on their own by about 2026-10-15, so no backfill unless D3 says otherwise.

**L6. Shrink the link file and retire the bridge.** After L1 to L4 hold for 7 daily builds: `product-urls.json`
keeps only hand-made exceptions (entries whose tile is `link_source` other than `row`). Retire, one commit each with
`audit-script-census` evidence of no remaining caller: `derive-links-from-prices.ps1`, `merge-product-urls.ps1`,
`relink-drifted-cells.ps1`, `withdraw-stale-link.ps1`, `sync-browser-links.ps1`, the per-store resolvers
(`resolve-hyvee-links`, `refresh-hyvee-links`, `refresh-bakers-links`, `resolve-ff-boardmatch`, `fix-links-ff`,
`resolve-chips-hyvee`) and the product-link item in the 06:15 browser task. 58 scripts read `product-urls.json` today;
each is either moved to the tile field or kept for exceptions, and the census lists which.

## Bars (written before the build)
Measured on the daily board, main comparison plus recipe board, counted per store tile:
- **L1:** of priced tiles whose winning row came from a storefront (not an ad), at least 97% carry `link_source=row`,
  stated as `N of M`, on each board separately. The pre-change figure is taken by L1's first build before any reader
  switches, with the same denominator; today's numbers (2,435 main-board links derive-links calls already correct;
  134 + 109 + 21 storefront entries on the backlog) do not share one denominator and are not the baseline.
- **L1:** zero tiles where `link` and the priced row name different products (identity check, per tile).
- **L2:** priced tiles rendering the store-SEARCH fallback on the deals page fall by at least 200 from today's count,
  read off the built page, not from the JSON.
- **L4:** the backlog's `missing` count, recomputed by the new classifier, falls from 277 to at most 40, and every
  remaining entry is `link_source=none` with a named capture file.
- **No regression:** `audit-tile-integrity` and `guards` link failures do not rise over 7 daily builds after L3.
A miss on any bar stops the next stage; L6 never starts until L1 to L4 hold for 7 builds.

## Decisions (need Brad)
- **D1. Flyer-only sale tiles** (83 today): link to the store's weekly ad page (the pill that exists today), or show
  no link. Recommendation: the weekly-ad link, labelled as the ad, never presented as the product.
- **D2. Hand-made exceptions:** keep `product-urls.json` as a small exceptions file for tiles with no row link, or drop
  it entirely and accept store search for those. Recommendation: keep it, capped by a ratchet whose mark only falls.
- **D3. Old Aldi rows with no link** (19 on the backlog): let them age out by mid-October, or re-read them now in the
  06:15 browser run. Recommendation: let them age out; the capture already keeps links.
- **D4. The two unit-price engines** (`pricing-math-lib` for the board, `pu-lib` for links): out of scope here, and L3
  makes `pu-lib` matter far less. Recommendation: a separate plan after L6, if exceptions still show disagreements.

## Open measurement
25 of the 134 entries pass every check reproduced here and are still unlinked. The L4 classifier will name them per
entry; if they are a separate cause, it gets its own item before L6.

Harness: one-off scratch probes (`link_gap_join.py`, `link_gap_pu.ps1`), described above and superseded by L4's
per-entry classes. Inputs: `grocery/out/url-worklist.json` (generated 2026-09-27 08:46), `comparison-2026-09-27.json`,
`out/regular/*-regular-2026-0[7-9]-*.json` and `out/sams/sams-deals-*.json` within 90 days of 2026-09-27.
