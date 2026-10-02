# SPEC: the capture row contract (build step 8, ruling 2)

**Status: SHADOW since 2026-10-02.** Ruling 2, verbatim: "**A row contract at capture, all 7 stores**, shadow first,
enforced store by store". Brad's D1 ruling of 2026-10-02 (`design/PLAN-weekly-root-families-2026-10-02.md`): "write the
contract and run it in SHADOW now, beside R18 and R11. Shadow refuses nothing and moves no price". Enforcement for a
store waits until that store's capture work has landed (R18 for Walmart and Sam's, R11 for Aldi and Fareway) and it has
7 shadow days. The bar is Brad's and lives in `design/PLAN-zero-alert-days-remainder-2026-09-24.md` step 8; this spec
does not restate or reinterpret it.

| Piece | File |
|---|---|
| The validator (pure) | `grocery/row-contract-lib.ps1`, `Get-TcRowContract` |
| Its self-test (42 cases) | `grocery/test-row-contract.ps1` |
| The daily shadow | `grocery/audit-row-contract-shadow.ps1`, one fan-out lane of `grocery/check-ad-cycles.ps1` |
| The shadow report | `grocery/out/row-contract-shadow-<board date>.json` (gitignored) |
| Ruling 6 | `grocery/validate-triage-plan.ps1` (the weekly lane's `new_source_check`) |

## 1. Why one contract

Every captured row's size, unit kind, pack count, price basis and deal terms are decided today by its store builder,
then decided again by the engine (`Get-UnitPrice` in `grocery/pricing-math-lib.ps1`), then again by each guard (pu-lib
`Get-LinkPerUnit`, `Get-SizeMeasureKind`, `Get-MultibuyRefusalHalf`, `Test-SamsPerPieceUnit`). Two readers of one token
disagree, and every disagreement so far has been a real number in the wrong basis. Seven open weekly items are this one
class (family 1 of the root-families plan): 9ee1f9, 7c3a24, 6adf51, 1eac5a, 35fdeb, 44c416, ab2257.

The contract is a statement about the row, made once, with the FIELD each value came from and a REFUSAL CODE for each
value it cannot prove. It reads every quantity with the readers that already exist (`Get-ItemPrice`, `Get-SizeAmount`,
`Get-PackCount`, `Get-EachPackCount`, `Resolve-MultibuyPackCount`, `Get-EachCountConflict`, `Test-NameOffersTwoSizes`,
`Get-TcDealCondition`, pu-lib `Get-SizeMeasureKind`), so it is not a third reader. What it adds is the decision those
readings support. When enforcement lands, the engine's unit conversion and every basis guard read the contract's
fields instead of parsing the size again.

## 2. What the seven builders and two importers emit today

Read from each builder's newest output on 2026-10-02 (`out/regular/*-regular-2026-10-02.json`,
`out/sams/sams-deals-2026-10-02.json`). Every row of every builder carries the three source texts the contract reads:
`item` (the name), `size`, `ad_price` (the price text). The one gap: **7 of 915 Fareway rows carry no `size`** (the rows
`build-fareway-regular.ps1` marks `size_raw` / `size_repaired`); the contract reads the name for those, as the engine
does. No builder change was needed for the shadow.

| Store | Writer | Price text | Size | Evidence the contract also reads |
|---|---|---|---|---|
| Walmart | `build-walmart-deals.ps1`; `import-walmart-batch.ps1` rows carry `written_by` | `ad_price`, `current_price`, `regular` | `size` | `wm_unit_price`, `qty_basis` ("reproduces Walmart's unit price"), `engine_check` |
| Aldi | `build-aldi-regular.ps1`; `import-instacart-batch.ps1` rows carry `written_by` | `ad_price`, `current_price` | `size` (the card size; gr-08) | `store_location` |
| Fareway | `build-fareway-regular.ps1`; `import-instacart-batch.ps1` | `ad_price`, `current_price`, `base_price` | `size`, `size_raw` | `marked_down`, `sale_note`, `sale_ends_days` |
| Sam's Club | `build-sams-deals.ps1` | `ad_price`, `current_price` | `size` (often derived as price / unit price) | `sams_unit_price`, `qty_basis`, `sams_unit_price_proven`, `ad_from` / `ad_to`, `marked_down` |
| Hy-Vee | `pull-regular-hyvee.ps1` (the weekly ad lines reach the engine as whole lines, name = price text) | `ad_price`, `current_price`, `base_price` | `size` | `marked_down`, `price_multiple` |
| Family Fare | `pull-regular-familyfare.ps1` | `ad_price`, `current_price`, `base_price`, `regular` | `size` | `carried_forward` |
| Baker's | `pull-regular-bakers-api.ps1` | `ad_price`, `current_price`, `base_price` | `size`, `size_raw` | `size_basis` (label, netweight, soldby-weight, netweight-namecount), `net_weight`, `ad_from` / `ad_to`, `marked_down` |

The two batch importers write into the same regular files (input I165); the shadow attributes a row to its importer by
`written_by`. **Today's files hold 0 importer rows**, so both importers are covered by the shadow but not yet exercised by
it; the first file an importer writes is attributed on the next run.

## 3. The contract: fields, sources, refusals

Input: one row (the engine's candidate shape `name` / `price_text` / `size_text`, or a builder row `item` / `ad_price` /
`size`, mapped by `ConvertTo-TcContractRow`) and its commodity: `unit` and the declarations `weight_is_one_unit`,
`pack_is_package`, `pint_oz`, `kind_equivalent`, `density_g_ml` from `grocery/commodities.json`.

| Field | Value | Source recorded |
|---|---|---|
| price | `Get-ItemPrice`'s per-item price | `price_text`, and the deal note when there is one |
| size | value in the commodity's unit, the text it was read from | `size_text` first; the name only when the size field states no usable amount (the engine's order); `size_text per-lb rate`; `via commodity.pint_oz` |
| unit kind | weight, volume, count (or `disputed`) | the same text, read by `Get-SizeMeasureKind` with the commodity unit; a density or a reviewed allowlist string is named when it settles a mismatch |
| pack count | count and form: `single`, `pack`, `package`, `count-per-container`, `either-or`, `range`, `unstated`, `unproven` | which party stated it (price text, size field, name), and the proof: arithmetic, a store unit price, or a declaration |
| price basis | `item`, `per-unit`, `pack-total`, `per-package`, `per-piece`, `deal` | the marker, count or declaration that decided it |
| deal terms | kind (`n-for`, `must-buy`, `bogo`, `buy-get`, `markdown`, `none`), quantity, TTL | `price_text`; `marked_down`; `regular > price`; TTL from `sale_ends_days` (Fareway) or `ad_to` (Baker's, Sam's) |

The verdict is `refuse` (any refusal code), `reprice` (the contract proves a basis the engine does not use) or `accept`.

### Refusal codes

| Code | When | Instance it settles |
|---|---|---|
| `NO-PRICE` | no money token in the price text or the name | |
| `DEAL-NO-REGULAR` | a buy-N-get-K price with no regular price to apply it to | |
| `NO-SIZE` | a weight or volume commodity and no amount anywhere, and no per-unit rate | |
| `SIZE-EITHER-OR` | the name offers two sizes and the size field states none | |
| `KIND-VOLUME-ON-WEIGHT` | a volume size on a weight-unit commodity that declares no density | **44c416** at the source: `Convert-ToUnit` reads "fl oz" as weight oz on an oz commodity, pu-lib reads it as volume; the contract has one answer |
| `KIND-WEIGHT-ON-VOLUME` | the reverse | |
| `KIND-LABELS-DISAGREE` | the size field says one kind and the name states the commodity's kind at the SAME amount ("14 fl oz" beside "7 oz., 2 pk.") | 44c416's population: a store name that drops "fl" and a builder that adds it look identical, so neither is believed |
| `KIND-COUNT-ON-MEASURE` | the size states only a count on a weight or volume commodity | 6adf51's 44 Family Fare "Coca Cola Soda Cans 12 Pk" rows |
| `PACK-COUNT-AMBIGUOUS` | a count offered as an alternative ("8 or 10 ct.") or a piece-count range multiplied into the size | **9ee1f9 (1)**: "Keurig coffee or cocoa, 8 or 10 ct., 12 oz., $6.99" read as 120 oz |
| `PACK-BASIS-UNPROVEN` | a pack count is stated and the size equals ONE item's size, with no store unit price to say which | gr-08 (a name size equal to the card proves nothing), **6adf51**'s missed-count half |
| `PACK-COUNT-UNSTATED` | a volume row whose name sells plural cans or bottles with no count anywhere | **6adf51**: "Mr. Pibb Cherry Cola Soda Cans 12 Fl Oz" at the 12-pack price |
| `PACK-CONFLICT` | two parties state counts that do not divide each other | 8d2ad5's "Benner Black Tea Bags 100 CT" with size "24 ct" |
| `COUNT-UNSTATED` | an each-unit package price with no count, no whole-purchase size and no per-each marker | the engine's existing "bare package, unknown count" drop |
| `DEAL-COUNT-UNSTATED` | an N-for-M, BOGO or buy-get deal on an each-unit commodity where nothing states how many pieces one unit holds | **7c3a24**: "Annie's ... Macaroni & Cheese 6 Oz", 2 for $7.00, priced per each while the plain path refuses the same shape |

### Reprice codes (not refusals: enforcement prices the row on the contract's basis)

| Code | When | Instance |
|---|---|---|
| `PACK-COUNT-IGNORED` | the size field states only a count N and the name the item size E, so the pack is N x E, but a reader divides by E | **6adf51**: "Pepsi Diet Soda Cola 16.9 Fl Oz, 6 Count 6 Ea", reg 7.29, priced on 16.9 fl oz; on 101.4 it sits inside the band |
| `PER-PIECE-PRICE-DIVIDED` | a per-each price beside a count, where the line also states the pack total (count x price, within 3%) | **9ee1f9 (2)**: "Bakery-fresh large croissants, sold in a 6 ct. 5.94, $0.99 each" divided to 0.165 |

### What the contract ACCEPTS that a guard refuses or questions today

- **1eac5a**: "Member's Mark Farm Raised Jumbo Raw Shrimp, Frozen, 21-25 ct. per pound, 2 lbs." is one 2 lb bag: pack form
  `count-per-container`, count 1. So is "24 ct. per box, 2.07 lbs." and the cod "11-15 ct., 2 lbs.". The Sam's per-piece
  guard (`Test-SamsPerPieceUnit`) reads these counts as pieces; when it reads the contract's pack form instead, the five
  correct rows stop being refused.
- **35fdeb**: Fareway "Fareway Garlic Texas Toast", 8 ct, $3.99 on garlic-bread (which declares `pack_is_package`) is
  priced per PACKAGE, with the 8 named as pieces inside, source `commodity.pack_is_package`. Guard 4's 0.13x reading is
  pu-lib dividing by 8 against that declaration, not a basis error on the cell. Reading the contract's price basis
  instead of re-parsing settles it.
- **ab2257**: Aldi "Head Shoulders Classic Clean Daily Shampoo 12.5 FL OZ", $6.97: the basis is proven (12.5 fl oz on a
  floz commodity, no count), so the band's refusal is a wrong product or a real price, never a basis error. The shadow
  reports, per store, how many out-of-band rows carry a basis code at all: that is the evidence ab2257 asks for.
- A size string reviewed in `grocery/basis-kind-allowlist.json` (the number is right, only the label disagrees) is
  accepted, as is a kind mismatch on a commodity declaring a density.

### Rules the contract keeps, and decisions it leaves open

- **gr-08**: the pack basis is proven by arithmetic or by the store's own unit price, never by a plausibility bar. The one
  tolerance is the 3% pack-total proof, the same 3% `Get-SizeAmount` and `Test-MpSizeIsPackTotal` already use; the
  self-test holds a case exactly at it and one step past it (og-06).
- **gr-10**: no band, no price bar.
- On a WEIGHT row a bare "ct" is pieces inside one package (nuggets, links); only an explicit pk or pack is a multipack.
  On a VOLUME row any count (ct, count, ea, pk, pack) counts containers. First plausible rule, not swept: the shadow
  measures its reach.
- **Open for a ruling before enforcement, not decided here:** the 26 cells in section 5 are almost all
  `KIND-VOLUME-ON-WEIGHT` / `KIND-LABELS-DISAGREE` on 11 oz-unit commodities (pickles, mayonnaise, relish,
  evaporated-milk, coconut-oil and others). Each needs a density declaration, a unit change, or acceptance that its fl-oz
  rows leave the board. That is 44c416's own ask ("measure density per commodity before choosing refuse-by-default or
  allow-by-default"), now with the cells named.
- The candidates file carries no `sale_ends_days` or `ad_to`, so the shadow's deal terms have no TTL; the builders do
  carry it, and enforcement inside each builder reads it.

## 4. Shadow, enforcement, and ruling 6

**Shadow (now).** `audit-row-contract-shadow.ps1` reads the engine's `candidates-<date>.json` (the only file that joins
each captured row to its commodity, so no builder or matcher is re-run) and the newest output of each of the seven
builders (attribution, store unit-price proof from the newest 14 Walmart and Sam's files, source-field check). It writes
only the gitignored `row-contract-shadow-<date>.json` and prints, per store, `examined N`, refusals `of` the engine-priced
rows, agreements on rows the engine already left unpriced, reprices, cells it would empty `of` the priced cells, and
out-of-band rows with a basis code `of` all out-of-band rows. Its last line is `ROW-CONTRACT-SHADOW-COMPLETE`. It runs in
the daily chain as the fan-out lane `row-contract-shadow`, after the builders and the board build; a run that does not
end on its marker is logged BLIND by `Test-FanoutComplete` and never holds the board.

A cell the contract "would empty" is a commodity x store pair with at least one engine-priced row, where the contract
refuses every one of them. A repriced row does not empty its cell.

**Enforcement (later, per store).** Each builder calls `Get-TcRowContract` on its own rows and writes the contract fields
beside them; the engine and the basis guards read those fields instead of re-parsing. Order: the census's order of
returns, and only after R18 (Walmart, Sam's) or R11 (Aldi, Fareway) has landed for that store and it has 7 shadow days.
Bar: the remainder plan's step 8, verbatim there.

**Ruling 6 (on).** "every new store, feed or large commodity batch is checked against the row contract before it goes
live". The weekly lane runs `audit-row-contract-shadow.ps1 -Store <store>` for each new source and quotes its
`ROW-CONTRACT-SHADOW <store>:` line in the plan's `new_source_check`, or writes "went live since the last lane run: none".
`validate-triage-plan.ps1` refuses the old "no row contract exists yet" wording and a named source with no quoted line.

## Knowledge consulted

- searched "capture row contract pack basis validator" (knowledge-search --estate). Used: data-quality-craft/applies-here.md,
  "The silent semantic change": "the worst pipeline failure is the one where everything runs, the schema holds, the values
  are plausible, and the *meaning* of a number changed", and its pointer to `grocery/audit-basis-reconcile.ps1`, whose
  store unit-price sources (Walmart `wm_unit_price`, Sam's `sams_unit_price`, Baker's `netWeight`) are the contract's
  unit-price proof.
- `.claude/rules/grocery.md` gr-08 (a name size equal to the card proves nothing: `PACK-BASIS-UNPROVEN`), gr-10 (no
  hard-coded bands), gr-04 (pricing math is `pricing-math-lib.ps1`, export a function).
- `.claude/rules/ops-and-gates.md` og-05, og-06, og-02, og-22, og-08, og-09, og-28; `.claude/rules/measurement.md` ms-01
  (denominators), ms-07 (blobs, never an unlanded commit hash).

## 5. First shadow run

**Date 2026-10-02.** Candidates `candidates-2026-09-30.json` (written 2026-10-02 08:09:45, sha256
`E79EC2681DA997E3942EE52875D38B5DD82F2922F71D38C77399B49FCE83834F`, read from the main checkout's `grocery/out` into a scratch copy), the seven builders' 2026-10-02
outputs from this worktree's seeded `grocery/out`, the catalog and allowlist at the same commit as the harness. Harness
blobs: `grocery/row-contract-lib.ps1` d30937e586f61fdee7c82659d766354afb75ad3f, `grocery/audit-row-contract-shadow.ps1`
b4c5ffaaf14eac6b73cdb649156664303ea5652a, with `grocery/pricing-math-lib.ps1` e2908ebb1db5308c374f6d36af27a5a4b500955e
and `grocery/pu-lib.ps1` ff69dea376da77cb168f532b4d509cb8fe6061e4. Exit 0, 95 s, 40,704 candidate rows over 593
commodities (0 missing from the catalog).

| Store | Rows examined | Engine-priced | Contract would refuse (of engine-priced) | By code | Agrees on engine-unpriced | Reprices | Cells it would empty | Out-of-band with a basis code |
|---|---|---|---|---|---|---|---|---|
| Walmart | 19,864 | 8,130 | 171 (2.1%) | KIND-VOLUME-ON-WEIGHT 131, KIND-LABELS-DISAGREE 37, PACK-BASIS-UNPROVEN 2, PACK-COUNT-UNSTATED 1 | 1,160 | 17 | 6 of 519 | 7 of 391 |
| Baker's | 6,520 | 5,734 | 158 (2.8%) | KIND-VOLUME-ON-WEIGHT 130, KIND-LABELS-DISAGREE 19, PACK-BASIS-UNPROVEN 7, NO-SIZE 2 | 347 | 0 | 4 of 534 | 5 of 389 |
| Family Fare | 5,166 | 4,206 | 39 (0.9%) | KIND-VOLUME-ON-WEIGHT 30, DEAL-COUNT-UNSTATED 5, PACK-BASIS-UNPROVEN 2, NO-SIZE 2 | 574 | 6 | 0 of 463 | 9 of 352 |
| Sam's Club | 4,007 | 1,165 | 12 (1.0%) | KIND-VOLUME-ON-WEIGHT 8, KIND-LABELS-DISAGREE 4 | 236 | 1 | 2 of 326 | 0 of 31 |
| Aldi | 2,219 | 1,902 | 34 (1.8%) | KIND-VOLUME-ON-WEIGHT 25, KIND-LABELS-DISAGREE 5, PACK-BASIS-UNPROVEN 2, NO-SIZE 2 | 190 | 1 | 6 of 386 | 0 of 105 |
| Hy-Vee | 1,733 | 586 | 7 (1.2%) | KIND-VOLUME-ON-WEIGHT 6, DEAL-COUNT-UNSTATED 1 | 193 | 0 | 4 of 340 | 2 of 36 |
| Fareway | 1,195 | 557 | 10 (1.8%) | KIND-VOLUME-ON-WEIGHT 8, NO-SIZE 1, PACK-COUNT-UNSTATED 1 | 45 | 0 | 4 of 348 | 0 of 13 |
| **All** | **40,704** | **22,280** | **431 (1.9%)** | | **2,745** | **25** | **26 of 2,916** | **23 of 1,317** |

Every reprice is `PACK-COUNT-IGNORED` (Walmart 17, Family Fare 6, Aldi 1, Sam's 1). A row's code count can exceed its
refusal count, because a row can carry more than one code. By writer (all rows, refused of examined): build-walmart-deals
710 of 10,204; pull-regular-bakers-api 505 of 6,514; pull-regular-familyfare 526 of 4,729; build-sams-deals 199 of 3,248;
build-aldi-regular 218 of 2,195; pull-regular-hyvee 81 of 1,439; build-fareway-regular 43 of 1,080; rows from the weekly
ads and other feeds (no builder output carries the name) 894 of 11,295; the two importers 0 of 0.

**The 26 cells the contract would empty** (commodity, store, engine-priced rows, codes): banana-peppers Aldi 1, Baker's 5,
Walmart 4; coconut-oil Aldi 1, Fareway 1, Walmart 19; condensed-milk Aldi 1; evaporated-milk Baker's 11, Fareway 2,
Hy-Vee 1, Sam's 2, Walmart 8; mayonnaise Aldi 8, Hy-Vee 1, Walmart 39; miracle-whip Fareway 2; pepperoncini Baker's 4,
Walmart 5; pickled-jalapenos Aldi 1; pickles Baker's 37, Hy-Vee 1; relish Aldi 1, Fareway 2, Walmart 10 (all
KIND-VOLUME-ON-WEIGHT, some with KIND-LABELS-DISAGREE); cooking-spray Sam's Club 3 (KIND-LABELS-DISAGREE); donuts Hy-Vee
1 (DEAL-COUNT-UNSTATED: "Hy-Vee mini donuts, 3 or 6 oz., 3/ $4.00").

**44c416 reconciled against its own population.** Its measurement counted 410 of 19,860 candidates on oz-unit
commodities priced from a fl-oz size with a "size N oz" basis; the same filter over this candidates file finds exactly
410. The contract refuses 337 as KIND-VOLUME-ON-WEIGHT and 65 as KIND-LABELS-DISAGREE, and accepts 8 whose size string is
reviewed in `basis-kind-allowlist.json` (337 + 65 + 8 = 410). That reconciliation was a one-off scratch script over the
same blob of the lib, not a committed harness.

**Measurement notes.** One run, one candidates file, so nothing here is a trend; 7 shadow days per store are the ruling's
evidence, and the daily lane writes them. The rules were adjusted twice against this same file before the run above
(a per-lb rate printed in the size, and the order of the reviewed-kind check), so this run is not an independent test of
those two rules: the next 7 days are. The engine-priced denominator counts a row with any unit price, including rows
the band later refuses.
