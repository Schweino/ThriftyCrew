# PLAN: the "See item" link rides with the price, so a priced tile always knows its product

Status: D1 to D4 RULED by Brad 2026-09-27 (see Decisions). Work items revised to match; L1 built
2026-09-27.

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

## Work items (revised 2026-09-27 to match D1 to D4)
Staged so each stage ships alone and is additive until the stage that removes. Brad's rulings reshape the end state:
every published price carries its own product link, fetched by the system; there is no hand-made link file (D2); a
flyer price the system cannot resolve to a product is not published (D1); one per-unit engine (D4).

**L1. The tile carries its link (additive, nothing reads it yet). BUILT 2026-09-27.** `grocery/link-identity-lib.ps1`
holds `Get-TcRowUrl`, `Test-SamsAlnumShapeProven` and `Get-TcLinkSource`, dot-sourced by `compare-deals.ps1` and
`derive-links-from-prices.ps1` (one copy of the per-store URL rules). `Add-Norm` computes the link from the capture row
it is handed, and every store tile gets `link_source` (`row`, `none` = storefront row with no identity, `ad` = flyer
line) and `link` when the source is `row`. Fixtures: `grocery/test-link-identity-lib.ps1` (11 cases).
Measured on the 2026-09-27 board (base = origin/main compare-deals, same inputs, same day): 2,825 tiles, 0 differ
beyond the two new fields, no top-level key differs. Priced tiles: row 2,493, none 199, ad 133. Storefront linked
2,493 of 2,692 (92.6%), BELOW the 97% bar: Family Fare 266 of 400 (the 134 are `carried_forward` everyday rows, 1,907
such rows in today's capture with no `canonical_url`), Aldi 319 of 383 (64; 940 Aldi rows with no `link_url`), Fareway
296 of 297. Baker's, Hy-Vee, Sam's and Walmart 100%. The miss is capture defects, which L5 owns; L2 does not wait on
it, because L2 only prefers a link when one exists.
Still owed in L1: stamp `link` / `link_source` on `recipe-board-everyday.json` cells (they do not pass the tile
builder). Found in passing: the `has_identity` tie-break reads `link_url` off a record that never carries it, so only
`product_id` rows count as linkable; switching it to `link` changes winners and ships as its own measured change.

**L1b. Flyer lines are resolved to a product before they publish (new, D1).** A flyer line (`link_source=ad`, 133
tiles: Hy-Vee 70, Family Fare 61, Aldi 2) is matched to the store's own product at capture time: Hy-Vee by its
storefront search API, Family Fare by the Freshop search `resolve-ff-boardmatch` already runs (commodity include and
exclude, cheapest), Aldi by its product search. The resolved row's id is stamped on the flyer row, so the tile is
`row`. Additive first: the resolved link is recorded and counted for 7 builds. Then the switch: a flyer price with no
resolved product is withheld (cell falls back to that store's everyday price or shows no price), never published
without a link. Bar before the switch: at least 90% of flyer tiles resolved, and a sampled 20 checked by eye for
same product, same size.
PROBED 2026-09-27 (Hy-Vee only; one-off scratch probe `probe-hv-flyer.ps1`, one row per tile, 70 rows): for each
Hy-Vee flyer tile on the L1 board, Hy-Vee's own headless search (the endpoint `resolve-hyvee-links` already uses,
store 1466) was asked for the flyer line, and a result counted as a price match when its current `tagPriceValue`
equals the flyer price to the cent. 70 of 70 searches answered; 51 had at least one price match, 12 exactly one, 39
two or more; 19 none, an overstatement, because the probe read a multi-buy line ("5/ $5.00") as $5. **A flyer line
is usually a FAMILY, not a product** ("Hormel Black Label bacon, 9.3 to 16 oz., $4.99" matched 11 products at $4.99).
So the resolver's rule is: the link is the one product that is (a) at the flyer price today, (b) at the SIZE the
tile's per-unit was divided by, which the tile already records in `basis` (bacon: `size 0.581 lb`, the 9.3 oz end
of the flyer's range), and (c) inside the commodity's own include/exclude; more than one survivor, or none,
leaves the tile unresolved (`ad`), never a guess. Multi-buy lines resolve on the unit price the deal implies
(`deal_qty`). Family Fare (61) goes through the Freshop search `resolve-ff-boardmatch` already runs, and is not yet
probed. Bar for the withhold switch unchanged: at least 90% of flyer tiles resolved, and 20 sampled by eye.

**L2. The page and the feed read the tile's link first.** `build-deals-page.ps1` `SeeLink` uses `tile.link` when
`link_source=row`; otherwise store search, never `product-urls.json` (D2). `export-feed.ps1` ships the tile link
beside the price. A row link needs no per-unit re-check: it is the product that set the price.
PAGE HALF BUILT 2026-09-27 (`SeeLink` takes the tile link first; the `product-urls.json` fallback stays until L6, so
no chip loses a link before its replacement exists). Measured on the 2026-09-27 board built by L1, origin/main
`build-deals-page` vs this one, same board: 4,232 chips, 4,148 unchanged, 75 store-search to exact product, 4
weekly-ad pill to exact product (Fareway and Hy-Vee storefront sale rows), 5 change product. Of the 5, 1 was a WRONG
live link: Sam's eggs priced a 2-dozen pack at $4.82 while the link file opened a 15-dozen case at $29.56; the other 4
are the same product under a newer id. Search-fallback chips 197 to 122. **The L2 bar (a fall of at least 200) is
MISSED and was unreachable**: the page carried only 197 search-fallback chips in all; it was written before that count
was taken. Recorded as a miss, not rewritten. The feed half (`export-feed.ps1`, recipe widgets) is still owed: it
reads `product-urls.json` through its own store-ownership checks and moves in its own change.

**L3. The link checks judge identity, not arithmetic.** `audit-tile-integrity.ps1` and the link checks in `guards.ps1`
assert the tile's link equals the URL built from the row the tile names. With no exception file (D2) nothing is left
for `pu-lib`'s link re-pricing, which is what makes removing `derive-links`' write-time refusal safe (memory
`link-derivation-order`). Extends the existing guards; no new gate.

**L4. The backlog lists only what the system must fix.** `resolve-worklist.ps1` reads `link_source`: `row` is never
listed; `none` is listed with store and capture file (capture defect); `ad` is listed as an unresolved flyer line
(L1b's work, not a resting state, per D1).
BUILT 2026-09-27 (`Get-WorklistLinkClass`, 5 self-test cases; each entry carries `link_class`). Measured on the L1
board of 2026-09-27, main board only (recipe board not rebuilt in the scratch run), origin/main resolve-worklist vs
this one, same inputs: 238 entries to 144. The 94 dropped are tiles carrying their own row link (Walmart 39, Baker's
15, Sam's 11, Family Fare 13, Aldi 9, Hy-Vee 6, Fareway 1). The 144 left: `ad` 92 (83 missing, 9 stale), `none` 52
(48 missing, 4 stale). Half the L4 bar holds (every entry is `none` or `ad`); naming the capture file per entry is
still owed.

**L5. Fix the captures that drop identity.** `build-walmart-deals` writes `link_url` from `item_id`; Hy-Vee's
`everyday shelf price` rows keep `product_id`; Family Fare's carried-forward rows (1,907 with no `canonical_url`) get
re-read or carry the URL forward from the capture that had it; Aldi's 940 unlinked rows, including the 19 on the
backlog, are re-read in the next 06:15 browser run (D3).
BUILT 2026-09-27, measured first: Walmart and Hy-Vee need nothing (100% of their tiles are `row` after L1, because the
lib builds their URL from the id). Family Fare's 1,907 unlinked rows all carry `as_of` 2026-09-05 or earlier and every
row since 2026-09-06 has `canonical_url`, so the capture is already fixed and only the OLD rows need a re-read; Aldi's
940 date 2026-08-15 to 09-09. Rather than wait up to 90 days for the rotation, `Get-TcLinkOwed` (link-identity-lib)
lists the commodities whose tile is `none` on the newest board and `Get-CaptureWorklist` leads with their terms right
after the price-flag verifications, capped at HALF the room left so ended sales keep theirs. It empties itself as each
re-read lands. On the 2026-09-27 board: Family Fare 134 owed, 14 terms per run; Aldi 64 owed, 17 per run (this also
covers D3's 19); sale expiries displaced 0. Uncapped it took 28 of 37 and 35 of 37 lead slots, so the cap is the
first plausible value of 1 tried.

**L6. Retire the link file and the bridge (D2).** After L1 to L5 hold for 7 daily builds: `product-urls.json` is
retired outright, not shrunk. Retire, one commit each with `audit-script-census` evidence of no remaining caller:
`derive-links-from-prices.ps1`, `merge-product-urls.ps1`, `relink-drifted-cells.ps1`, `withdraw-stale-link.ps1`,
`sync-browser-links.ps1`, the per-store resolvers (`resolve-hyvee-links`, `refresh-hyvee-links`,
`refresh-bakers-links`, `resolve-ff-boardmatch` once L1b owns its search, `fix-links-ff`, `resolve-chips-hyvee`) and
the product-link item in the 06:15 browser task. Each of the 58 readers of `product-urls.json` moves to the tile field.

**L7. One per-unit engine (D4).** Once L3 has removed `pu-lib` from the link checks, list its remaining callers and
move each to `pricing-math-lib`, with a paired run showing identical per-unit on every board tile, then retire
`pu-lib`.

## Bars (written before the build)
Measured on the daily board, main comparison plus recipe board, counted per store tile:
- **L1:** storefront tiles with `link_source=row` at least 97%, as `N of M` per board. First reading 2,493 of 2,692
  (92.6%) on 2026-09-27; met only after L5.
- **L1:** zero tiles where `link` and the priced row name different products.
- **L1b:** at least 90% of flyer tiles resolved before the withhold switch; after it, zero published flyer prices
  with no link.
- **L2:** priced tiles rendering the store-SEARCH fallback fall by at least 200, read off the built page.
- **L4:** every remaining backlog entry is `none` or `ad` with a named capture file or flyer.
- **L7:** per-unit identical on every tile between the two engines before `pu-lib` retires.
- **No regression:** `audit-tile-integrity` and `guards` link failures do not rise over 7 daily builds after L3.
A miss stops the stage that depends on it; L6 never starts until L1 to L5 hold for 7 builds.

## Decisions (ruled)
- **D1. Flyer-only sale tiles** (83 today): link to the store's weekly ad page (the pill that exists today), or show
  no link. Recommendation: the weekly-ad link, labelled as the ad, never presented as the product.
  **RULED by Brad 2026-09-27: neither.** Verbatim: *"We should NOT be storing products without links. Full stop. The
  ad flyer may show the product and price, but its the systems job to find the link."* So `link_source=ad` is not a
  resting state: a flyer-sourced price must be matched to the store's real product page before it is stored, and a
  flyer price the system cannot link is not published. L1, L4 and the L1 bar need rework to match (a new item: resolve
  each flyer line to a product page at capture time).
- **D2. Hand-made exceptions:** keep `product-urls.json` as a small exceptions file for tiles with no row link, or drop
  it entirely and accept store search for those. Recommendation: keep it, capped by a ratchet whose mark only falls.
  **RULED by Brad 2026-09-27: drop it entirely.** Every link comes from the system's own fetch; a tile with no fetched
  link is a defect, never covered by hand. L6 retires `product-urls.json` outright, and L3 has no exception set left
  for `pu-lib` to check.
- **D3. Old Aldi rows with no link** (19 on the backlog): let them age out by mid-October, or re-read them now in the
  06:15 browser run. Recommendation: let them age out; the capture already keeps links.
  **RULED by Brad 2026-09-27: re-read them now** in the next 06:15 browser run, so they carry links instead of
  waiting to age out. L5 gains this re-read.
- **D4. The two unit-price engines** (`pricing-math-lib` for the board, `pu-lib` for links): out of scope here, and L3
  makes `pu-lib` matter far less. Recommendation: a separate plan after L6, if exceptions still show disagreements.
  **RULED by Brad 2026-09-27: fold it into this plan.** Merging the two per-unit engines into one becomes a work item
  here (to be written as L7), not a follow-up plan.

## Open measurement
25 of the 134 entries pass every check reproduced here and are still unlinked. The L4 classifier will name them per
entry; if they are a separate cause, it gets its own item before L6.

Harness: one-off scratch probes (`link_gap_join.py`, `link_gap_pu.ps1`), described above and superseded by L4's
per-entry classes. Inputs: `grocery/out/url-worklist.json` (generated 2026-09-27 08:46), `comparison-2026-09-27.json`,
`out/regular/*-regular-2026-0[7-9]-*.json` and `out/sams/sams-deals-*.json` within 90 days of 2026-09-27.
