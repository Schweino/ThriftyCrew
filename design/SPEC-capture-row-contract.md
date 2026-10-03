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
`pack_is_package`, `pint_oz`, `kind_equivalent`, `density_g_ml` from `grocery/commodities.json`. The density is read by
`Get-TcCommodityDensity` / `Get-TcDensityGml` in `commodity-density-lib.ps1`, the same functions `Get-UnitPrice` reads
(section 6), so the size the contract states is the divisor the engine uses.

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
- **RULED 2026-10-03 (Brad, R7.4, "Give each a density"), built as section 6:** the 26 cells in section 5 were almost
  all `KIND-VOLUME-ON-WEIGHT` / `KIND-LABELS-DISAGREE` on 11 oz-unit commodities. A numeric `density_g_ml` now converts a
  volume size to weight in the contract AND in the engine through one reader; five of the 11 declare one, two are
  reviewed size strings, and four (the brined jars) have no defensible source and are back with Brad. Section 6.
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

## 6. Densities (R7.4, built 2026-10-03)

**The ruling**, Brad, 2026-10-03, "Give each a density (Recommended)": each of the 11 oz-unit commodities whose fl oz rows
the contract would refuse declares a SOURCED density, so the sizes convert and no cell empties. No density is typed from
memory; each carries its source.

**One place, one reader.** The declaration is `density_g_ml` on the commodity in `grocery/commodities.json`, beside a
`density_source` naming the USDA FoodData Central record and portion it came from. The contract already read that field
(and nothing declared it); the engine did not read any density at all. `Get-TcCommodityDensity` moved from this lib into
`grocery/commodity-density-lib.ps1` (dot-sourced by `pricing-math-lib.ps1`), and `Get-TcDensityGml` returns the number the arithmetic uses: a numeric `density_g_ml` on an oz
or lb commodity, else 0. `meal-prep/db/densities.json` was considered and not used: it is keyed by recipe food name and
household unit, not by commodity id, and the engine does not load it. `kind_equivalent: near-water` stays a declaration
that silences the kind question without converting (its own text says the units are interchangeable at the board's
precision), so no near-water price moves.

**The arithmetic.** `Convert-ToUnit` and `Get-SizeAmount` take an optional density (default 0: every existing caller is
unchanged). With one, a volume token (fl oz, gal, qt, pt, l, ml) is read by the floz arm, multiplied by 29.5735 ml per fl
oz and the density, and divided by 28.3495 g per oz (or 453.592 g per lb). `Get-UnitPrice` passes the commodity's density
and, when it moved the divisor, writes `size_override` with the weight it divided by and a basis naming the density, so
pu-lib and the kind audit read the quantity the price used (the gallon-jug branch's precedent). The contract passes the
same density to the same `Get-SizeAmount`, so its accepted size equals the engine's divisor (fixture-asserted).

**A density never converts a row whose NAME states the size's number as a weight** (`Test-TcKindLabelsDisagree`, 1% bar,
kinds from pu-lib's `Get-SizeMeasureKind`): Sam's "Magnolia Sweetened Condensed Milk, 14 oz., 6 pk." sized "84 fl oz" is
84 weight oz, and a density would understate it by 26%. The contract refuses such a row as `KIND-LABELS-DISAGREE` even
on a density commodity; the engine leaves its number as read.

### The 11, and what each got

| Commodity | Declared | Source | Why a volume size really is a volume |
|---|---|---|---|
| mayonnaise | 0.9299 g/ml | FDC 171009 SR Legacy, 1 cup = 220 g (1 tbsp 13.8 g = 0.9333) | 175 FDC Branded mayonnaise records state the jar in fl oz or mL |
| miracle-whip | 0.9933 g/ml | FDC 171403 SR Legacy (mayonnaise type, regular), 1 cup = 235 g (1 tbsp 0.9941; Kraft label 1 Tbsp = 15 g, 1.0144) | Kraft Heinz's own records state 12, 19, 30, 48 fl oz |
| coconut-oil | 0.9214 g/ml | FDC 171412 SR Legacy, 1 cup = 218 g (1 tbsp 0.9197); NOT Foundation 330458 (0.7845, below any edible oil) | 148 records in fl oz or mL, 35 by weight (weight jars are not converted) |
| evaporated-milk | 1.0651 g/ml | FDC 172194 SR Legacy, 0.5 cup = 126 g and 1 fl oz = 31.5 g (agree) | 129 records in fl oz or mL (12 fl oz/354 mL), 1 by weight |
| relish | 1.0356 g/ml | FDC 168561 SR Legacy (sweet), 1 cup = 245 g (1 tbsp 1.0144) | 162 records in fl oz or mL, 17 by weight |
| condensed-milk | NONE: reviewed size string instead | FDC 171275 would give 1.2934, but the category is sold by WEIGHT: 135 of 139 labelled records state the can by weight (14 oz/396 g) | the Aldi "14 FL OZ" row is a 14 oz can mislabelled; converted it would be an 18.9 oz can (26% understated, crown direction). `basis-kind-allowlist.json` entry condensed-milk / Aldi / 14 fl oz |
| cooking-spray | NONE: reviewed size strings | an aerosol is labelled by net weight | Sam's names state 7 oz x 2 = 14 and 12 oz x 2 = 24 by weight; the builder wrote fl oz. Allowlist entries for 14 fl oz and 24 fl oz |
| pickles, banana-peppers, pepperoncini, pickled-jalapenos | NONE: back to Brad | no defensible source (below) | |

**Why the four brined jars have no density.** What is needed is the weight of a jar's CONTENTS (pieces and brine) per
labelled fluid ounce. FDC's portions for these foods are drained pieces with air gaps: dill pickles 1 cup = 155 g (0.655
g/ml), jalapenos solids and liquids 1 cup sliced = 104 g (0.44), hot pickled peppers 1/4 cup drained = 34 g (0.57).
Branded label servings for one product family range 0.38 to 1.05 g/ml ("1/4 cup (30g)" against "2 Tbsp (30g)": a 30 g
reference amount with a rounded household measure, not a measurement). Branded package strings that state both a volume
and a weight either give a drained weight ("16 fl oz/347 g", 0.73; "46 fl oz/1.36 lbs", 0.45) or are the fl oz = oz
conflation itself ("25.5 FL OZ/723 g" is exactly 25.5 weight oz, 0.9586). Declaring any of these would move those cells by
up to 2.3x on a number that measures something else, so they are not declared and the choice goes back to Brad: a
contents density from a source not yet found, a change of unit to floz, or letting their fl oz rows leave the board.

### Blast radius, measured before landing

Harness: a scratch clone of this branch outside the worktree, seeded from the main checkout, `compare-deals.ps1 -MinStores
1 -IdentityNamespace staple -JudgeDate 2026-10-03` run twice over the same inputs (ads-2026-09-30 and the seeded captures):
once at HEAD 252c523da (board A, candidates sha256 130F15CF...), once with the change (board B, candidates sha256
79D7B94A...). Blobs of the change: `grocery/pricing-math-lib.ps1` 6ef65636beb1ad71533853b69679e47c727e4887, `grocery/commodity-density-lib.ps1` 1cb1f9b04455955bddadbe6da7a75f2bd43cb4c9,
`grocery/row-contract-lib.ps1` 95d96837612171687c4166cb137fb4c3d6f7c825, `grocery/commodities.json`
b78f90a84d65865f5a5cf21e030b6c6b8f1a1b09, `grocery/basis-kind-allowlist.json` 04d216788de94c761646935187e347cf83a79a49,
`grocery/pu-lib.ps1` ff69dea376da77cb168f532b4d509cb8fe6061e4, `grocery/audit-row-contract-shadow.ps1`
b4c5ffaaf14eac6b73cdb649156664303ea5652a. Both builds exit 0. (Board B was first built from an earlier arrangement of the same code, before the density functions moved into their own lib for the file-size budget; a rebuild at the blobs above over the same inputs reproduced it cell for cell, 0 of 2,910 changed, and the shadow again read 9.)

**24 of 2,910 priced cells move, on 5 commodities; 0 crowns change; no cell appears or disappears.** Every move is the
density factor (density x 1.0432) and nothing else:

| Commodity (factor on the divisor) | Cells, old -> new per oz |
|---|---|
| coconut-oil (+4.05%) | Aldi 0.3707 -> 0.3857; Baker's 0.3263 -> 0.3395; Fareway 0.5993 -> 0.6235; Walmart 0.2443 -> 0.2542 |
| evaporated-milk (-10.0%) | Baker's 0.1075 -> 0.0968; Family Fare 0.1492 -> 0.1343; Fareway 0.2580 -> 0.2322; Hy-Vee 0.1483 -> 0.1335; Sam's Club 0.1092 -> 0.0983; Walmart 0.1483 -> 0.1335 |
| mayonnaise (+3.1%) | Aldi 0.0963 -> 0.0993; Baker's 0.1330 -> 0.1371; Family Fare 0.1330 -> 0.1371; Fareway 0.2900 -> 0.2990; Hy-Vee 0.1327 -> 0.1368; Walmart 0.0990 -> 0.1021 |
| miracle-whip (-3.5%) | Aldi 0.0963 -> 0.0930; Family Fare 0.2330 -> 0.2249; Fareway 0.3253 -> 0.3140 |
| relish (-7.4%) | Aldi 0.1056 -> 0.0978; Baker's 0.1454 -> 0.1346; Family Fare 0.1990 -> 0.1842; Fareway 0.2250 -> 0.2083; Walmart 0.1550 -> 0.1435 |

**Row-contract shadow on board B:** the contract would empty **9 of 2,915** priced cells, against 26 on board A: the 8
brined-jar cells (banana-peppers Aldi, Baker's, Walmart; pepperoncini Baker's, Walmart; pickled-jalapenos Aldi; pickles
Baker's, Hy-Vee) and donuts / Hy-Vee (DEAL-COUNT-UNSTATED, outside this ruling). Of the original 24 fl oz cells, 16 no
longer empty (15 by density, condensed-milk / Aldi by its reviewed size string) and cooking-spray / Sam's Club no longer
empties either. Engine-priced rows refused: 290 of 22,271 (1.3%), from 431 (1.9%).

**guards.ps1 on board B: `GUARDS OK`, hard=0, warn=20, exit 0.** On board A, the same clone and inputs: hard=1, exit 2,
`QUARANTINE-REQUIRED` on condensed-milk / Aldi (the kind guard: a volume cell crowning a weight row), which the reviewed
size string clears. Guard 4's drift warning (a cell within 50% of its link but more than 2% off) reads 83 cells on B
against 62 on A: the link's per-unit is pu-lib's `Get-LinkPerUnit`, which takes no commodity and so reads a linked
"30 fl oz" as 30 oz. That is the remaining second reader (open item below); it fails nothing (guard 4 fails at 1.5x and
0.67x, generate-board-overrides pins at 30%).

**Measurement notes.** One build pair over one input set; the shadow numbers are one day, not the 7 the ruling's bar
reads. The density list was changed once after the first measurement (condensed-milk was declared, measured to move the
Aldi cell -25.9%, and withdrawn on the label evidence above), so this is the second variant measured.

**Open:** (1) the four brined jars, Brad's call; (2) pu-lib's `Get-LinkPerUnit` does not know a density, so a link and its
cell disagree by the density factor on linked cells of the five commodities (drift warnings only); (3) a store that writes
a jar's fl oz as a bare "oz" (Hy-Vee "Sweet Relish 10 oz", Family Fare and Hy-Vee coconut oil "14 oz") is read as weight
and not converted, so those cells sit up to the density factor dearer than converted peers (the safe direction, no crown
affected on board B).
