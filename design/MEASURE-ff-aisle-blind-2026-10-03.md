# MEASURE: Family Fare rows admitted with no shelf department (2026-10-03)

Plan: `design/PLAN-ff-aisle-blind-2026-10-03.md`. Measurement only. Nothing here changes the engine, a capture file
or the board, and nothing ran in a landing checkout.

Harness: `design/aisle-blind-2026-10/harness/` (committed with this doc; `.txt` so no gate walks it as live code).
The probe instruments a SCRATCH copy of `grocery/compare-deals.ps1` at blob e5de5cf8db08a1997d4c1e0156c2498c00261540,
judging through `grocery/aisle-lib.ps1` at blob ac1634c62bd50e1ea233c262d0c75d58634e87b1 (both read at main
12a3943f7, the tip when the 2026-10-02 08:10 board was built). `pull-grocery-ads.ps1` read at blob
e9a9b6ccfaab679a26df32b3da1c1ba0affcb135. Run 2026-10-03 between 01:40 and 02:20 CDT.

Cases: `design/aisle-blind-2026-10/cells.jsonl` (one row per Family Fare board cell, 463) and
`design/aisle-blind-2026-10/blind-pairs.jsonl` (one row per admitted Family Fare row with no department, 1,414).
Every total below is derived from those files by `harness/cases.py.txt`.

## Knowledge consulted

- `searched "aisle admission blind family fare department"` (estate) and `"carried row lost canonical_url identity"`.
- memory `aisle-test-built` (C--Codex): the aisle test gates on the store's own shelf department. Why the
  measurement judges every row with `Test-AisleAllowed` and never with a similarity score.
- memory `freshop-probes-share-the-production-budget`: "run Freshop measurement or resolver work after the 10:30
  window ... never probe before 07:00". Why the circular's `canonical_url` is left unmeasured here.
- memory `compare-deals-is-not-standalone`: the replica ran compare-deals alone, so both arms stop before the
  chain's relink steps (stated under Results).
- `.claude/rules/measurement.md` ms-04 and ms-07: one row per case (`cells.jsonl`, `blind-pairs.jsonl`) and the
  harness named by blob.

## Question

`Get-AisleAdmissionRefusal` admits any Family Fare row whose department it cannot find
(`if (-not $Dept) { return $null }`). How many rows that compare-deals admitted on the newest board had no
department, how many of them hold a cell and a crown, and why did the lookup find nothing?

## Method

1. **Replica.** A scratch git worktree at 12a3943f7 and a scratch copy of `grocery/out`. compare-deals ran with the
   bot's own arguments (`-MinStores 1 -IdentityNamespace staple`, as `check-ad-cycles.ps1` passes them) plus
   `-OutDir <scratch>` and `-JudgeDate 2026-10-02`. Exit 0, 440 s.
2. **Inputs pinned by the engine's own ledger.** `out/input-usage.json` (updated 2026-10-02 08:10:45) lists the 113
   files that build read. Of those, exactly one was rewritten afterwards: `regular/family-fare-regular-2026-10-02.json`,
   rewritten in place by the 10:30 window at 10:34. No other input-like file is newer than the build. The replica
   therefore read the 10:34 version of that one file.
3. **Agreement check before any count.** The replica's board and the real `comparison-2026-09-30.json`
   (built_at 2026-10-02T08:10:02, md5 91c1f4157379e7417bb1ef02175ae364) agree on all **463 of 463** Family Fare
   cells: same item, same per-unit (4 dp), same type. The 10:34 rewrite moved no Family Fare cell.
4. **Probe.** The scratch compare-deals logs every (commodity, Family Fare row) pair that REACHES the aisle check
   (rows refused earlier by band, floor, pack or known-wrong rules never reach it), with the department found, how
   it was found (`id`, `name`, `none`), and `Test-AisleAllowed`'s verdict. 4,234 pairs reached the check; the engine
   refused 27 (its own log says 27). The rebuilt shelf index matches the engine's: 3,846 ids, 3,861 names.
5. **Cells** are joined to pairs by (commodity id, item name): 463 of 463 joined. A cell is "no department" when
   every admitted pair behind it had none. A crown is `cheapest_store` = Family Fare or a tie with it.

## Results

### Task 1: admitted with no department

| | admitted pairs | no department | cells | no-dept cells | crowns | no-dept crowns |
|---|---|---|---|---|---|---|
| everyday | 3,673 | 1,051 (28.6%) | 404 | 112 (27.7%) | 14 | 5 |
| sale (Weekly Ad) | 534 | 363 (68.0%) | 59 | 29 (49.2%) | 12 | 7 |
| **all** | **4,207** | **1,414 (33.6%)** | **463** | **141 (30.5%)** | **26** | **12 (46%)** |

Twelve of Family Fare's 26 crowns stood on a row no department judged. All three founding rows are in the
no-department set: Twisted Tea (iced-tea, everyday), Cinnamon Twirls (ground-cinnamon, sale, **a crown**) and the
Magic Eraser shower cleaner (sponges, sale).

**The proxy overstated.** 171 cells carry no product link; 141 had no department. The difference is 30 sale cells
that borrowed a department from an everyday twin by name, and every one of them shows no link. No cell with a link
lacked a department.

### Task 2: the everyday rows

- All 1,051 no-department everyday pairs trace to the **1,740 rows of the everyday file with no `canonical_url`**
  (1,049 by name, 2 through a row link that is not a shelf path). All 1,740 are `carried_forward`, and none has a
  `product_id`, `found_by_term`, `store_id`, `current_price` or `base_price`. Their `as_of` runs 2026-07-14 to
  2026-09-05 (median 2026-08-29). Every row WITH a URL has `as_of` on or after 2026-09-05.
- **They are not legacy rows. They lost their identity in carry.** The same row in `family-fare-regular-2026-08-19.json`
  (`Enriched Long Grain White Rice`) carries `canonical_url .../shop/pantry/dry_goods/rice/...`, `product_id 7081730`
  and `found_by_term`. The URL-less count per dated file was 17 on 08-22, **764 on 08-23**, 655 on 09-04 and
  **5,204 on 09-05**, then falls by about 30 to 120 a day as the rotation re-reads products (1,740 on 10-02). The
  09-05 file was written at 14:35, between the half-finished `Read-JsonFile` sweep swept into main at 14:40
  (`3c44d0c18`, working tree since 14:23) and its fix at 15:39 (`e1acec2a2`). That is a coincidence of timing,
  NOT a reproduced cause. The 08-23 event has no candidate cause.
- **Recoverable from history with zero store requests.** Keyed on exact item + size + regular price over the 76
  older dated files: 1,717 rows recover exactly one URL, 4 recover several (all agreeing on department), 8 match by
  name only and 11 match nothing. 1,718 recover a shelf department; 0 recover two conflicting departments.
- **What the engine would say with the identity restored** (judged by the engine's own `Test-AisleAllowed`,
  `harness/judge.ps1.txt`): of the 112 no-department everyday cells, **106 ALLOW, 1 BLOCK, 5 unrecoverable**. The one
  BLOCK is Twisted Tea in `beer_wine_spirits`, a wrong product. No crown is refused. Of the 1,035 recovered pairs
  that hold no cell, 1,017 ALLOW and 18 BLOCK; most of the 18 are wrong products (Iams puppy food under
  whole-chicken, croutons under butter, a coconut-oil butter spread under coconut-oil), and about 7 look like
  real product the allowlist does not yet place (Dan's Pantry onion powder and Italian seasoning and Willy's fresh
  salsa in produce, Calidad chips in bakery, gluten-free English muffins in freezer, Fresh & Finest soups in deli).
- **Arm B: the whole board rebuilt with the identity restored** (`harness/restore_arm.py.txt` writes the 1,717
  single-URL identities into the SCRATCH copy of the everyday file and asserts by md5 that item, prices, size, source,
  as_of and carried_forward are unchanged; the same scratch compare-deals then rebuilt; `harness/armdiff.py.txt`
  compares). Exit 0. Over all 2,911 cells of every store: **1 cell lost** (Family Fare iced-tea, the Twisted Tea
  row; no other Family Fare row qualifies), **0 prices moved, 0 crowns changed**, **106 Family Fare cells gain a
  product link** they did not have, and **12 Family Fare cells show a different product at the identical per-unit
  price**: equal-price ties that break differently once the rows carry product ids. Ten stay everyday; two flip
  sale to everyday at the same price (ground-turkey `Jennie O 93/7` sale $5.99 to `Jennie O 85/15` everyday $5.99;
  tomatoes `Campari` sale $2.99 to `Tomato On The Vine` everyday $2.99). The engine's refusal count went from 27
  to 45, the 18 recovered pairs above. Arm B ran compare-deals alone; the chain steps after it (recipe-overlay,
  prune-bad-links, sync-browser-links, relink-drifted-cells) were not run in either arm.
- A first pass that hand-copied the category allowlist reported 17 BLOCKs. It skipped `$AISLE_COMMODITY_DEPT`, the
  per-commodity table. **Withdrawn**; the harness no longer computes any verdict itself.

### Task 3: the ad rows

- **Ad rows carry no product id: 0 of 534.** The by-id join can never fire for them. By exact name: 171 of 534
  (32.0%) found an everyday twin; 363 (68.0%) did not.
- **A normalised name key rescues 0 of 363** (case, accents, punctuation and spacing folded). Searching all 76 days
  of everyday history by exact name rescues 36 of 363 (9.9%).
- **Why names miss.** The Weekly Ad and the catalog name the same product differently, and most ad products are not
  in our everyday file at all. Nearest everyday name by token overlap for the 363: 6 at Jaccard 0.8 or more, 64 at
  0.6 to 0.8, 152 at 0.4 to 0.6, 141 under 0.4. Even the close ones are often a different product
  (`Oikos Triple Zero Banana Creme` against `...Blueberry...`; `Del Monte Whole Green Beans` against `Cut`), and the
  far ones would place a product on a shelf it does not sit on: `Halo Clementines` lands nearest
  `Halo Top ... Ice Cream` in freezer, which would BLOCK a real clementine.
- **The source has the identity and we drop it.** `pull-grocery-ads.ps1` reads the circular from Freshop's
  `/1/products?...&circular_id=...&fields=id,name,size,base_price,sale_price`, the same endpoint the everyday pull
  reads with `canonical_url` in its field list (`$FIELDS_RICH`), and the pager dedupes on `id`. The ads file keeps
  only item, size, prices, source and window, and `compare-deals/identity.ps1:135` adds a Family Fare ad row with no
  `-ProductId` and no `-SrcRow`. Whether the circular call returns `canonical_url` is NOT measured: Freshop shares
  one request budget with the 07:00, 08:00 and 10:30 price windows, and this ran at 02:00.

## What this does not show

- The replica read the 10:34 rewrite of one input; agreement on 463 of 463 cells says it did not matter for
  Family Fare, and says nothing about other stores (not measured, not needed).
- "No department" counts pairs that REACHED the aisle check. A row refused earlier by another rule is outside it.
- The 24 sale cells that stay unrecoverable (5 of them crowns: coffee, cooked-shredded-chicken, ground-cinnamon,
  pasta-sauce, yukon-gold-potatoes) have no verdict here at all; they need the store's own answer (plan W1). The
  other 5 no-department sale cells (2 crowns) recover a department from everyday history by exact name, all ALLOW.
