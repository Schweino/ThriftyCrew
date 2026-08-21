# PLAN - Live price state: everyday and ad prices as separate, dated facts on the board the site actually serves

**Status: DRAFT for Brad's review, 2026-08-21. No code written. Every number below was measured on the live tree today; every "must verify" is a question this plan refuses to answer by assumption.**

---

## 0. What Brad asked for, restated

> I'm a bag of potatoes. I carry an everyday price people can buy at any time, $1.99/lb. That is stored as the everyday price and shown on the grocery page and recipe pages. Sometimes I go on sale for 7 days at $0.99/lb. That is stored IN THE SAME ROW, in new columns: ad price, ad start, ad end. The pages fetch the cheaper of the two. When the sale ends the ad price nulls out and the pages go back to $1.99/lb.
>
> Ad pricing never enters the everyday value. Everyday pricing never replaces ad pricing. Ad price is null when not on ad.

And the shape question, settled:

> One row per item, columns per store? Store long, render wide. The wide per-item view (`comparison-<date>.json`, `board.json`, the deals page) already exists and is generated; the stored row is `(commodity, store)`. This is amendment 3a of `PLAN-price-state-2026-08-20.md`, which Brad accepted on 2026-08-20.

The model, as a table:

| everyday_price | everyday_asof | ad_price | ad_from | ad_to | **shown** |
|---|---|---|---|---|---|
| 1.99/lb | 2026-08-11 | 0.99/lb | 2026-08-19 | 2026-08-25 | 0.99 (through 08-25) |
| 1.99/lb | 2026-08-11 | null | null | null | 1.99 (from 08-26, by arithmetic, no re-capture needed) |

The load-bearing consequence: **once `ad_to` is on the row, a sale expires by date arithmetic.** No re-capture is needed to stop publishing it. That removes the single worst failure the 90-day carry introduced (section 2.3).

---

## 1. What already exists, and what does not

### 1.1 The design is already ratified. The live board never received it.

`design/PLAN-price-state-2026-08-20.md` is Brad's spec, word for word, with the `cell_state` schema:

```
commodity_id, store_id,
everyday_price, everyday_unit_price, everyday_size, everyday_product, everyday_asof, everyday_evidence,
ad_price, ad_unit_price, ad_product, ad_from, ad_to, ad_evidence,
reverted_checked_at
```

It was built 2026-08-20, phases A-D, and lives at `graph/state/cell-state.json` (3,092 rows). **But `graph/` is a shadow estate.** `docs/RUNTIME-MAP.md` is explicit: nothing in any serving path reads it, and it stays that way until its numeric exit gates pass. The site is served by the PowerShell pipeline, and that pipeline has none of this.

Measured on the shadow today, so nobody mistakes it for done:

| store | cells | cells with `ad_price` set |
|---|---|---|
| Baker's | 518 | 35 |
| Fareway | 452 | 33 |
| Hy-Vee | 432 | **0** |
| Aldi | 367 | **0** |
| Family Fare | 475 | **0** |
| Walmart | 504 | 0 (no ad cycle, correct) |
| Sam's | 344 | 0 (no ad cycle, correct) |

`graph/import/importers.py::import_ad_deals` reads only `out/bakers` and `out/fareway`. The server-ad file `out/ads-<date>.json`, which carried 1,794 live deals this morning (Hy-Vee 686, Aldi 108, Family Fare 1,000), is never imported. And the shadow's `everyday_*` columns are filled from the same capture files as the live board, so they inherit the contamination in section 2 unchanged.

**Conclusion for this plan:** the schema is settled and should be reused byte-for-byte so the graph's `board_parity` becomes a free cross-check. The work is to make the LIVE pipeline produce and consume it, correctly, for all seven stores.

### 1.2 How the live engine actually selects a price today (read, not inferred)

`compare-deals.ps1`:

- Every source is flattened into ONE pool of rows (`Add-Norm`, L1090) carrying `price_type` in {`sale`, `everyday`} and `src_date`.
- Sale rows come from `out/ads-<date>.json` (server ads, L1099), `bakers-deals-*.json` and `fareway-deals-*.json` (vision reads), `extra-deals-*.json` (agent-authored BOGOs). Each flyer file carries a document-level `ad_from`/`ad_to` and `Test-AdWindowClosed` (L562) refuses the file outside its window. **Ad expiry by arithmetic already exists for the flyer lanes.** The server-ad file has no per-deal dates; it is trusted only for the day it was pulled (`check-ad-cycles.ps1` L123).
- Everyday rows come from `out/regular/<store>-regular-<date>.json`, `price_type` from the document (default `everyday`).
- Ranking (L1563): per commodity, per store, after the freshest-capture filter, `Sort-Object unit_price | Select -First 1`. **The cheapest row of EITHER type wins the store's cell**, and the cell's `type` is whatever that row was. That IS "fetch the cheaper of ad and everyday", but it is computed over a pool in which the two kinds are not honestly labelled (section 2), and the losing kind is discarded, so the cell cannot say what the everyday price is behind a sale.

The cell contract every reader sees (L1579):
`store, per_unit, unit, type, bulk, membership, member_label, item, ad, size, basis, note, source_ad`

### 1.3 The side file that fakes the row-level dates

`sale-windows.json` (built by `build-sale-windows.ps1`) looks like Brad's row: `sale_price, sale_start, sale_end, refresh_on` per `(id, store)`. It is not a source of truth. Measured from its code:

- It is **derived from the finished board**, after ranking: only the winning cell per store per commodity, and only when that cell's `type` is `sale` (L107-109).
- Its dates come from the **store-level** ad cycle in `ad-schedule.json` plus flash-text parsing, not from the item (L111-144). A Fareway monthly-ad price had to be special-cased because the store-level window was wrong for it (L115-140).
- Everyday-typed cells are never logged (L109), so a markdown mislabelled `everyday` has no window and never expires.

It feeds `export-feed.ps1` (the "sale ends" badge) and `capture-policy` (`SaleExpiries`, the re-price trigger). Under the target design both read the cell state instead, and this file becomes a projection or is retired.

---

## 2. The defect, measured on today's live data

### 2.1 Everyday files carry sale prices labelled everyday

| store | everyday rows | rows whose "everyday" value is a live markdown | how proven |
|---|---|---|---|
| Fareway | 902 | **622 (69%)** | `regular` > `ad_price` on the row |
| Baker's | 7,281 | **1,404 (19%)** | `marked_down: true`, `base_price` on the row |
| Hy-Vee | 1,554 | 119 refreshed today | `marked_down=119` in the file header; **the rows cannot be counted** because the puller discards `basePrice` |
| Family Fare | 5,222 | unknown | `regular` is written as a copy of the current price; Freshop's `base_price` is discarded |
| Walmart, Sam's, Aldi | 11,256 / 60 / 2,217 | unknown | no regular price captured at all; EDLP stores, but Walmart rollbacks exist |

Real rows from the live Fareway everyday file:

```
Fareway Cream Cheese Spread     published everyday $1.88   true everyday $2.99
Daisy Sour Cream                published everyday $3.44   true everyday $4.49
Fareway Could It Be Butter      published everyday $1.88   true everyday $2.49
```

### 2.2 On the live board

Joining today's `comparison-2026-08-21.json` cells to the markdown evidence above (only the two stores where the evidence survives on the row):

| | cells typed `everyday` whose source row is a markdown | of which Cheapest crowns |
|---|---|---|
| Fareway | 292 | |
| Baker's | 68 | |
| **total** | **360** | **29** |

Sample crowns: air-freshener Fareway $1.48 (regular $2.99), balsamic-vinegar Fareway $2.88 ($3.98), bell-peppers Fareway $0.77 ($1.17), brandy Baker's $21.99 ($27.99), cereal Fareway $1.99 ($3.49).

Every one of these is a correct price TODAY. The defect is what happens next: nothing dates them, so nothing retires them.

### 2.3 The quarterly policy made this six times more dangerous

Until 2026-08-20 an everyday row lived at most 14 days, so a mislabelled markdown could survive at most two weeks past its sale. `capture-policy.ps1` now carries rows for **90 days** and re-captures each term once a quarter. A markdown captured today as "everyday" can publish until November. This is already the documented cause of the five wrong Fareway prices found 2026-08-20 (commit `8f2c29a8`): Zesty Italian $0.99 against a real $2.48, Organic Thyme $2.50 against $4.99, all expired markdowns.

### 2.4 The field names are already lying

- The everyday price lives in a field named `ad_price` in every everyday file.
- `regular` means three different things: Fareway's true pre-sale price; Hy-Vee's deliberate duplicate of the current price (a guard-10 cross-check); Family Fare's copy of the current price; null for Walmart, Sam's, Aldi, Baker's.
- `regular` is ALSO the input to multibuy math (`compare-deals.ps1` L259-355: "Buy 1 Get 2 Free, regular $11.99"). Repurposing it would silently change BOGO pricing. **This plan does not touch `regular`.**

### 2.5 Downstream effects that already exist

- `export-feed.ps1` L190/L201: the recipe card's **everyday tab** is "the cheapest cell whose `type` is `everyday`". For a commodity where a store's markdown won as `everyday`, the everyday tab shows a sale price. For a commodity where the only cells are sale-typed, the tab has no everyday at all even though the stores have one.
- `recipe-overlay.ps1`: the recipe board is exactly Brad's model at coarse grain (an everyday baseline that sales overlay and never overwrite), but its baseline `recipe-board-everyday.json` is derived from the board's everyday cells, so it inherits the markdowns.
- `update-history.ps1`: banks the week's cheapest as a possible `record_low` without distinguishing a sale from an everyday price. A `record_low` drives the buy/wait badge forever.
- `guards.ps1` guard 8 ("no undated stale discount published as a sale") only inspects `extra-deals-*.json`. The 360 cells above are structurally invisible to it because they are typed `everyday`.

---

## 3. The target contract

### 3.1 Two levels of row, named plainly

Brad's "bag of potatoes" row is the **cell**: one per `(commodity, store)`, the answer. The capture files hold **product rows**: many per commodity per store (every Fareway cream cheese the search returned). Product rows are evidence; the cell is state. This is the graph's amendment 3a and it is kept.

### 3.2 Product rows (every `out/regular/*.json` and every ad file): additive fields

Every producer adds, never renames:

| field | meaning | rule |
|---|---|---|
| `everyday_price` | the non-sale shelf price, as a string like `ad_price` | **never** a discounted value. Taken from the store's own regular-price field when the store exposes one; equal to the observed price when the store exposes no discount signal at all |
| `sale_price` | the discounted price the store charges today | **null unless the store's own data says a discount is live** |
| `sale_from`, `sale_to` | the window | null when the source does not state one. Never borrowed from the store-level ad schedule at the row level (that borrowing is the guard-8 bug class) |
| `sale_kind` | `ad` (dated, from a flyer/feed) or `markdown` (undated storefront cut) | so the engine can apply the undated-discount TTL |

`ad_price` and `current_price` **stay exactly as they are** during transition: `current_price` is what the store charges today and guard 10 keeps asserting `ad_price == current_price`. Under the new fields the same invariant reads `current_price == (sale_price ?? everyday_price)`, which is guard 10 restated, not weakened.

Per store, what each source can honestly fill (read from each producer today; the last column is what must be verified before the producer is changed):

| store | everyday_price from | sale_price from | sale_from/to from | must verify |
|---|---|---|---|---|
| Baker's (Kroger API) | `price.regular` | `price.promo` when `promo < regular` | **unknown** | does the Kroger product response carry promo dates? If not, Baker's ad_to comes only from the flyer lane or is null |
| Hy-Vee (GraphQL) | `basePrice / basePriceMultiple` | `price` when `onSale` | **unknown** | does the persisted query select any promotion end field? (`hyvee/query-b64.txt`) |
| Family Fare (Freshop) | `base_price` | `price` when `price < base_price` | **unknown** | Freshop commonly exposes `sale_start_date`/`sale_finish_date`; confirm on a live response |
| Fareway storefront | `orig` ("Original Price") | `price` when `orig > price` | null (storefront shows no end date) | confirm no end-date text exists on the card |
| Aldi storefront | observed price | none observed | null | does the card ever render a strike-through "was" price? |
| Walmart (`__NEXT_DATA__`) | **unknown** | **unknown** | null | does `priceInfo` carry `wasPrice` / rollback? |
| Sam's (`__NEXT_DATA__`) | **unknown** | **unknown** | null | same question; also "Instant Savings" |
| server ads (`ads-*.json`) | n/a | `ad_price` | store window from `verification[]`/`ad-schedule.json` **at the file level**, which is what the board already trusts | nothing new |
| flyer files (`bakers-deals`, `fareway-deals`) | n/a | `ad_price` | document `ad_from`/`ad_to` (already enforced) | nothing new |

### 3.3 The cell (the state of record)

Same fields as `graph/state/cell-state.json`, plus two:

```
commodity_id, store_id,
everyday_price, everyday_unit_price, everyday_size, everyday_product, everyday_asof, everyday_evidence,
ad_price, ad_unit_price, ad_product, ad_from, ad_to, ad_evidence,
ad_kind,                -- 'ad' | 'markdown' | null   (NEW; which TTL applies)
reverted_checked_at,
published_unit_price,   -- NEW; = min(live ad_unit_price, everyday_unit_price), the number every page shows
published_kind          -- NEW; 'ad' | 'everyday'
```

Written by the engine to `grocery/out/cell-state-<date>.json` (per build) and mirrored to a tracked `grocery/cell-state.json` (the git-diff price historian, per 3b of the ratified plan).

### 3.4 The rules, mechanical

1. **Everyday answer** for a cell = cheapest qualifying product row whose `everyday_price` is set, never a row's `sale_price`. Everyday is never overwritten by a sale; it is only replaced by a newer everyday observation.
2. **Ad answer** = cheapest qualifying row with `sale_price` set AND a window that contains today. Precedence: a dated `ad` row beats an undated `markdown` row for the same cell.
3. **Undated markdown TTL.** A `markdown` row with no `sale_to` is honoured as `ad_price` for at most `MarkdownTtlDays` (a capture-policy constant, proposed 7, Brad's call) from its `as_of`, then dropped. It can never become `everyday_price`. This is the row-level form of guard 8.
4. **Published** = `min(ad, everyday)` while the ad is live; `everyday` otherwise. On `ad_to + 1` the ad columns null out by arithmetic at the next build; the page shows everyday again without any capture.
5. **Reversion verification** (ratified Phase D): `ad_to < today AND reverted_checked_at IS NULL` emits the cell's terms into the existing capture worklist; the next capture of that cell stamps `reverted_checked_at` and updates `everyday_*` if the shelf moved. This replaces `sale-windows.json`'s `refresh_on` as the trigger.
6. **Ad is null when not on ad**, at both levels, by construction of rules 2-4.

### 3.5 Invariants (new guards, each with a must-fire fixture and a clean twin)

- G-A: no product row has `everyday_price < sale_price` (a discount cannot exceed the regular).
- G-B: no cell has `ad_price` set with `ad_to < today` (expired ad published).
- G-C: no cell has `ad_kind = markdown` older than `MarkdownTtlDays` (undated discount outliving its leash).
- G-D: `published_unit_price == min(ad_unit_price ?? inf, everyday_unit_price)` on every cell (the display rule cannot drift from the data).
- G-E: every served artifact's price for a cell equals that cell's `published_unit_price` (section 4's parity check, run on every publish).
- G-10 restated: `current_price == (sale_price ?? everyday_price)` on every product row that carries `current_price`.

---

## 4. Every reader, and what happens to it

This is the "make sure everything is properly reading the table" half. Readers were found by grep (`comparison-*.json | verified-*.json | board.json | smp-feed.json` across `*.ps1,*.py,*.js`): **167 files, 438 references**. They fall into four classes. Nothing below is changed without its own before/after diff.

### 4.1 Unchanged by construction (the cell contract is additive)

Every reader that consumes `stores[].per_unit`, `type`, `ad`, `size`, `basis`, `item`, `cheapest_*` keeps working with identical semantics: `per_unit` stays the published number, `type` stays `sale|everyday` (derived from `published_kind`). This covers the bulk of the 167: audits, link resolvers, trend pages, store guide, accuracy sampler, rescue worklist, pull-order, the Worker (`worker/index.js` reads `board.json` as served), planner data, free dinners.

Verification: a byte-level diff of every served artifact built from the same inputs by the old and new engine, **before** any producer is changed (Phase 1 gate). The only permitted deltas are the additive fields.

### 4.2 Must change (reads the thing we are fixing)

| reader | today | after | gate |
|---|---|---|---|
| `compare-deals.ps1` | one pool, cheapest of either type | two answers per cell, published = min; emits cell state | Phase 1 parity; golden-test rebaseline with the delta enumerated |
| `export-feed.ps1` | `everyday` = cheapest cell typed everyday; `sale_end` from sale-windows | `everyday` from `everyday_unit_price` of the cheapest-everyday store; `sale_end` = cell `ad_to` | `feed-covers-published.ps1` stays green; diff of `pricing_inputs.*.everyday` enumerated |
| `build-deals-page.ps1` | "Sale thru" from sale-windows; everyday-vs-sale validation by `type` | same inputs from the cell; shows everyday behind a sale where the template allows | page diff; mobile check at 375px per standing rule |
| `build-sale-windows.ps1` | derives windows from the board + store schedule | projection of cell state (or retired once `capture-policy` and `export-feed` read cells directly) | `SaleExpiries` count before/after identical on a day with no real change |
| `capture-policy-lib.ps1` `Get-CapturePlan` | reads `sale-windows.json` `refresh_on` | reads cells where `ad_to < today AND reverted_checked_at IS NULL` | self-test fixture |
| `recipe-overlay.ps1` / `derive-recipe-floors.ps1` | baseline from everyday-typed cells | baseline from `everyday_unit_price` | recipe cost diff (`db\costed`), `audit-db-agreement` green |
| `update-history.ps1` | banks cheapest regardless of kind | banks `published_unit_price`, records `published_kind`; `record_low` from a sale is labelled as such | fixture: a sale week must not silently set an everyday record |
| `guards.ps1` | guard 8 inspects extra-deals only | G-A..G-E added; guard 8 generalised to all product rows | each guard's must-fire fixture |
| `verify-apply.ps1`, `sanity-check.ps1` | read cells | unchanged semantics, confirm they ignore the new fields | diff |
| 7 producers (section 3.2) | write `ad_price`/`regular`/`current_price` | add the four fields | per-producer `-SelfTest` with a markdown fixture and a plain fixture |

### 4.3 Must verify (reads `regular` or `type` for a purpose that could be affected)

- Multibuy math in `compare-deals.ps1` reads `regular` as the BOGO ceiling. Untouched, and the golden test's multibuy cases are the gate.
- `audit-everyday-mismatch.ps1`, `audit-sale-fallback.ps1`, `audit-coverage-gaps.ps1`, `build-staples-data.ps1`, `meal-prep/top5-weekly.ps1`, `build-freezer-data.ps1`, `build-sams-data.ps1`, `price-ingredient.ps1`: each read `type` or `sale_end`. Listed for a one-line review each; expected unchanged.
- `graph/import/importers.py`: should read `sale_price`/`sale_kind` from product rows instead of inferring `is_sale` from the lane, and should import `out/ads-*.json` (section 1.1). Shadow-only; `board_parity` is the gate and it is expected to IMPROVE.

### 4.4 Out of scope, named so it is not assumed in

- `archive/**` and `meal-prep/archive/**` (33 of the 167 files): dead code, not run.
- The 8 pre-existing `test-auditors` failures from commits earlier today (name-drift x5, script-census orphans x3, bake-currency, eviction date). Not this plan's, and they must be green or explicitly waived before Phase 1 starts, or the regression signal is noise.

---

## 5. Phases, each with a gate that can fail

Each phase ends green and pushed, or it does not end. The tree must be clean before each A/B (standing rule: a fix measured over a polluted tree re-measures the pollution).

**Phase 0 - answer the open questions (no code in the pipeline).**
Capture one raw response per source and record what it exposes: Kroger promo dates, Hy-Vee promotion fields, Freshop sale dates, Walmart/Sam's `wasPrice`, Aldi/Fareway strike-through text. Output: section 3.2's "must verify" column filled in with evidence files under `grocery/out/audit/price-fields/`. **Gate: every row of that table cites a file.** This phase exists because the plan would otherwise be guessing which store can date its sales.

**Phase 1 - engine emits the cell, reads nothing new.**
`compare-deals.ps1` computes everyday and ad answers from the EXISTING labels (`price_type`), emits the additive cell fields and `cell-state-<date>.json`. Nothing else changes.
**Gate:** every served artifact byte-identical except additive fields; `published_unit_price == per_unit` on 100% of cells; golden test green without rebaseline.

**Phase 2 - producers tell the truth.**
Each producer adds `everyday_price`, `sale_price`, `sale_from/to`, `sale_kind` per section 3.2, one store per commit, with its self-test fixture.
**Gate per store:** G-A passes; `current_price == (sale_price ?? everyday_price)` on every row; row count unchanged; the number of rows with `sale_price` set matches the store's own markdown count (Baker's 1,404, Fareway 622, Hy-Vee 119 today).

**Phase 3 - engine reads the new fields.**
Everyday answer from `everyday_price`, ad answer from `sale_price` + window, TTL on markdowns, published = min.
**Gate:** the set of cells whose `per_unit` changed is EXACTLY the set in section 2.2 plus the Hy-Vee/Family Fare cells Phase 2 revealed, enumerated in a report, each one explainable as "markdown now shown as ad with everyday behind it" (price shown today should NOT change for a live markdown; only its label and its expiry do). Golden test rebaselined with that enumeration attached. G-B, G-C, G-D green.

**Phase 4 - readers move.**
`export-feed`, `build-deals-page`, `recipe-overlay`/floors, `update-history`, `capture-policy` read the cell. `build-sale-windows` becomes a projection.
**Gate:** `feed-covers-published` green; `pricing_inputs.*.everyday` never carries a `sale` flag; `SaleExpiries` reproduces today's list from cells; page renders at 375px; G-E green on publish.

**Phase 5 - reversion verification and retirement.**
The `reverted_checked_at` worklist emitter; `sale-windows.json` retired or frozen as a projection; guard 8 generalised.
**Gate:** an ad that ended yesterday produces a worklist entry today (fixture); a cell re-captured after `ad_to` has `reverted_checked_at` stamped.

**Phase 6 - the shadow catches up.**
Graph importers read the new row fields and the server-ad file. **Gate:** `board_parity` improves or is explained, never silently worsens.

---

## 6. Open questions for Brad (decisions, not research)

1. **`MarkdownTtlDays`.** How long may an undated storefront markdown (Fareway's 622, Hy-Vee's 119) be shown as an ad price before it must be re-verified or dropped? Proposed 7 days. The alternative is 0 (never show an undated discount), which is option A from this morning and loses real savings.
2. **Show the everyday price behind a sale on the grocery page?** The data will be there. The template change is small; it is a design call. Recipe cards already have the two-tab shape.
3. **Walmart rollbacks and Sam's Instant Savings**, if Phase 0 finds them exposed: treat as `markdown` under the TTL, or as `everyday` because those stores have no ad cycle in `ad-schedule.json`? Proposed: `markdown`, because a rollback ends.
4. **Record lows from sales.** Should a sale week be eligible to set `record_low` (drives the buy/wait badge)? Today it does, unlabelled. Proposed: yes, but labelled `kind: ad`, so "cheapest since" can say it was a sale.

---

## 7. What this plan refuses to do

- Touch `regular`. It is multibuy input.
- Borrow a store-level ad window onto an item row. That is the guard-8 bug class, and it is why `sale-windows.json` needed a monthly-ad special case.
- Write `everyday_price` from any row the store itself marks as discounted, even when no regular price is exposed. Unknown regular means `everyday_price = null` for that row and the cell keeps its last honest everyday, not a guess.
- Change any served number in Phase 1 or Phase 2. The first phase that may move a published price is Phase 3, and it must enumerate every move.
- Read `graph/state/cell-state.json` from the live pipeline. The shadow stays a shadow until its own gates say otherwise.
