# EVIDENCE: weekly items re-homed to the ruled step that owns them (2026-10-02)

Phase 1 step 2 of `design/PLAN-weekly-root-families-2026-10-02.md` (Brad's ruling D3 A). Each item below was open in the weekly triage queue and was
closed with disposition `owned-by-step`, its notes naming the step. Its full queue body is kept here, verbatim, so
the evidence the step must answer is not lost with the queue item. This file has no Status line on purpose: the
bodies name about thirty repo paths, and in a plan they would make every commit to those files cite it.
The Phase 0 row for each item is in `design/MEASURE-weekly-root-families-2026-10-02.md`.

## Step 8, the row contract (family 1, row basis)

Owner: `step:design/PLAN-zero-alert-days-remainder-2026-09-24.md#8`

### 2026-09-28-9ee1f9: Triage residual: two latent Hy-Vee ad-line basis bugs, pack count x size and each over multibuy (10d164)

```text
Residual of triage queue 2026-09-27-10d164 (plan grocery/triage-plans/plan-2026-09-28-10.json), part (4). Two latent Hy-Vee ad-line basis bugs, NOT fixed; they left the board with their ad on 2026-09-27.

1. 'Keurig coffee or cocoa, 8 or 10 ct., 12 oz., $6.99' (ads-2026-09-27.json, 2026-09-21..09-27) was read as pack count x 12 oz: Hy-Vee coffee 0.0582/oz on 2026-09-27.
2. 'Bakery-fresh large croissants, sold in a 6 ct. 5.94, $0.99 each' (09-25..09-27) had the $0.99 each divided by the 6 ct multibuy: Hy-Vee croissants 0.165/each on 2026-09-27.

Occurrences: 1 each on 2026-09-27. Absent from ads-2026-09-28.json; git log since 09-27 shows no change to pricing-math-lib.ps1, compare-deals.ps1 or pu-lib.ps1, so both recur the next time Hy-Vee prints either shape. Each wants a frozen must-fire fixture from the ad line above plus a clean twin.


graded: 3806f1535 at C:\Codex\ThriftyCrew, 0 commit(s) behind origin/main, worktree: main
```

### 2026-09-28-7c3a24: Triage residual: N-for-M deals on each-unit commodities with no stated count (30 rows, from 633d2b)

```text
Residual of queue 2026-09-25-633d2b (plan-2026-09-28-9): non-plain prices on each-unit commodities that state NO pack count.

Measured on candidates-2026-09-28 (8,141 each-unit candidate rows): 48 carry a non-plain price ("N for $M", "2/ $5", Buy-N-Get-K). After the 633d2b fix the 18 that state a count divide by it. The other 30 state no count anywhere (price text, size field or name) and still price per-each.

That is right when the deal unit is one piece (2 avocados for $3) and wrong when it is a package of unstated count (a multi-piece package priced as one unit). They were not classified one by one. Nothing pages on the wrong half: Get-MultibuyRefusalHalf labels such a row 'unresolved' only when the band refuses it.

Ask: classify the 30 rows (single piece vs package of unstated count), and for the package half decide whether the capture can recover the count or the row should be withheld.


graded: 1925b9690 at C:\Codex\ThriftyCrew, 0 commit(s) behind origin/main, worktree: main
```

### 2026-09-28-6adf51: Triage residual: multibuy refusal half calls a missed pack count a complete basis (9 rows); Muscle Milk powder routes to milk (ef1612)

```text
Residual of 2026-09-27-ef1612 (44 NEW price flags). The prior class (9459a1: a real multibuy and a parse error paged identically) is fixed and live (614010d45). No refused row reaches the board. Measured over grocery/out/flagged-2026-09-28.json multibuy_unpriced, 55 rows:
- 44 Family Fare "Buy 2 get 1 free" soda 12-packs ("Coca Cola Soda Cans 12 Pk", reg 10.99, size "12 pack") have no can volume. They are refused correctly, since a size is never filled in. These are the 44 NEW flags of 09-27.
- 9 rows are labelled half=complete-basis, "the band refuses a real price; see band review", when the basis is missing a pack count:
  3 x "Pepsi ... Soda Cola 16.9 Fl Oz, 6 Count 6 Ea" (reg 7.29): priced on 16.9 floz, so $0.2876/floz. On 6 x 16.9 = 101.4 floz it is $0.0479, which sits inside the 0.00296-0.074 band. This is a real sale refused.
  6 x "... Soda Cans 12 Fl Oz" (Mr. Pibb, Coca Cola Cherry Float; reg 10.99, the 12-pack price): priced on one 12 floz can, so $0.6106/floz. The name carries no count, so refusing it is right, but it is not a real price the band refused.
  Cause: Get-MultibuyRefusalHalf (grocery/pricing-math-lib.ps1) judges the half from the basis string and unit only. It never checks whether the name or size_text carries a count ("6 Count", "6 ea") that the basis ignored. Band review is therefore handed parse errors as real prices, and widening the soda band to fit them would publish a per-can price. pricing-math-lib.ps1 was held by a sibling session on 2026-09-2 ...[truncated - full context in ad-cycle-log.txt / the source audit json]

graded: 910bb8b47 at C:\Codex\ThriftyCrew, 0 commit(s) behind origin/main, worktree: main
```

### 2026-09-29-1eac5a: Triage residual: Sam's per-piece guard refuses count-per-pound shrimp and cod rows (0cefa4)

```text
Triage residual of 2026-09-25-0cefa4 (plan-2026-09-29.json). A pre-existing false refusal in build-sams-deals.ps1's per-piece guard (Test-SamsPerPieceUnit, 2026-09-21), NOT introduced by 0cefa4: every row below is lb measure against a per-lb price, which the guard matched before today's change too.

The guard reads Get-NamePack's count as a PIECE count, but on these names the count is pieces PER POUND or a count range beside a pack weight, so the pack weight is the total and Sam's unit price is right. The rows are correct and are refused.

Measured in grocery/out/sams/sams-rejects-2026-09-27.json, reason "NAME CONFLICT: per-piece unit price":
- Member's Mark Farm Raised Jumbo Raw Shrimp, Frozen, 21-25 ct. per pound, 2 lbs. | $16.97 | $8.49/lb (16.97/2 = 8.485, the whole bag)
- Member's Mark Farm Raised Large Raw Shrimp, Frozen, 31-40 ct. per pound, 3 lbs. | $20.97 | $6.99/lb
- Member's Mark Farm Raised Medium Cooked Shrimp, Frozen, 50-70 ct. per pound, 2 lbs. | $16.47 | $8.24/lb
- Member's Mark Wild Caught Skinless and Boneless Beer Battered Cod Fillets, Frozen, 11-15 ct., 2 lbs. | $18.96 | $9.48/lb
- Royal Asia Farm Raised Shrimp Tempura ..., 24 ct. per box, 2.07 lbs. | $16.98 | $8.20/lb
Occurrences: 5 distinct names on 2026-09-27; 0 on 09-23..09-26 (not captured those days). The same shape (Tidy Cat "42 lbs. (2 Pack, 21 lb. Jugs)") fires in the scan of sams-deals files too.

Effect: Sam's shrimp and cod rows cannot reach a board cell (understated coverage, never a wrong pri ...[truncated - full context in ad-cycle-log.txt / the source audit json]

graded: 1e211b0eb at C:\Codex\ThriftyCrew, 0 commit(s) behind origin/main, worktree: main
```

### 2026-09-29-35fdeb: Triage residual: guard 4 still exempts Fareway ttl and Walmart rollback sale cells (garlic-bread / Fareway 0.13x)

```text
WHAT. Residual of queue 2026-09-28-a5268a (plan-2026-09-29-2). Guard 4 now grades Sam's rollbacks (Brad's ruling 2026-09-29), but two other markdown-shaped sale classes stay exempt from the pack-factor guard, and one of them carries what looks like a real per-unit error today.

MEASURED on comparison-2026-09-28.json with guard 4's own arithmetic (pu-lib Get-LinkPerUnit, bar >= 1.5x or <= 0.67x):
- Fareway sale cells with ad_basis ttl (source_ad shop.fareway.com): 62 cells, 62 compared, 2 over the bar.
  - garlic-bread / Fareway: board 8 ct $3.99, link "Fareway Garlic Texas Toast" 8 ct $3.99, link per-unit 0.4988/each, ratio 0.13x. Same size, same price, so the board's per_unit is about 7.7x the link's: looks like a per-pack vs per-each basis error on a published cell.
  - dish-soap / Fareway: board 58 fl oz $5.94, link 58 fl oz $8.94, 1.51x. Same size, a markdown just past the bar: a real sale, not a pack error.
- Walmart sale cells with ad_basis store (source_ad "everyday shelf price", rollbacks): 18 cells, 16 compared, 0 over the bar.

ASK (money lane). (1) Check garlic-bread / Fareway's per_unit basis and fix it at its builder if wrong. (2) Decide whether guard 4 should also grade Walmart rollbacks and Fareway ttl site sales (factor-grade-lib.ps1 Test-TcFactorGuardGrades is the one place to widen), noting a genuine markdown deeper than 33% off would trip the bar if the link carries the pre-markdown price.


graded: c26b14840 at C:\Codex\ThriftyCrew, 0 commit(s) behind origin/main, worktree: main
```

### 2026-10-02-44c416: Triage residual: fl oz read as weight oz on oz-unit commodities (2026-10-02-25cb66)

```text
Residual of triage item 2026-10-02-25cb66 (plan grocery/triage-plans/plan-2026-10-02.json), born weekly.

CLASS: the engine reads a "fl oz" size as WEIGHT ounces on an oz-unit commodity (grocery/pricing-math-lib.ps1 Convert-ToUnit, 'oz' arm: '^(oz|ounce|ounces|fl\s*oz)$' returns the number unchanged), while audit-unit-basis-outlier reads the same token as VOLUME through pu-lib Get-SizeMeasureKind. Two readers, one token.

MEASUREMENT (candidates-2026-09-30.json, 08:09:45): 410 of 19,860 candidates on oz-unit commodities are priced today from a size_text naming fl oz with a 'size N oz' basis, across 35 commodities: mayonnaise 78, pickles 76, coconut-oil 30, shaving-cream 27, evaporated-milk 26, relish 20, cooking-spray 18, tomato-soup 15, banana-peppers 12, yogurt 11, pickled-jalapenos 11, baby-food 11, air-freshener 9, pepperoncini 9, miracle-whip 8, insect-spray 6, taco-sauce 5, bbq-sauce 5, deodorant 4, cocktail-sauce 4, pizza-sauce 4, horseradish-sauce 3, whipped-cream 2, parmesan 2, feta 2, disinfectant-spray 2 (declared near-water), canned-beets 2, and 1 each for pasta-sauce, sour-cream, mustard, salsa, furniture-polish, condensed-milk, clam-chowder, vegetable-soup.

WHY THE PLANNED FIX DID NOT SHIP: the plan's exact_change (refuse fl oz on an oz row unless the commodity declares an equivalence) expected exactly one move (condensed-milk/Aldi) and named any other move as a stop. Its measured blast radius is up to 410 candidates on 35 commodities. Defaulting to refuse woul ...[truncated - full context in ad-cycle-log.txt / the source audit json]

graded: 6774f0f77 at C:\Codex\ThriftyCrew, 0 commit(s) behind origin/main, worktree: main
```

### 2026-10-01-ab2257: Grocery: a price band refused rows it cannot explain - 2026-10-01

```text
A price band's only job is to refuse a basis error (a pack price read per piece, ounces as pounds, a dropped decimal). These rows were refused by a band and carry no such evidence, so each is either a wrong product the band is hiding (it joins the matching worklist as kind band, resolver lane:grocery/resolve-match-worklist.ps1; a wrong product becomes an exclude through apply-coverage-batch -FromWorklist, per Brad's shape ruling) or a real price the band is censoring (fix the band derivation, never its number):

  UNEXPLAINED  shampoo | Aldi | 0.5576 against reference 0.0941 | Head & Shoulders Tea Tree Oil 2 IN 1 Shampoo & Conditioner   resolver: lane:grocery/resolve-match-worklist.ps1 (a wrong product -> an exclude via apply-coverage-batch -FromWorklist) or the band derivation (a real price)
  UNEXPLAINED  shampoo | Aldi | 0.5576 against reference 0.0941 | Head & Shoulders 2 IN 1 Dry Scalp Care   resolver: lane:grocery/resolve-match-worklist.ps1 (a wrong product -> an exclude via apply-coverage-batch -FromWorklist) or the band derivation (a real price)
  UNEXPLAINED  shampoo | Aldi | 0.5576 against reference 0.0941 | Head & Shoulders Classic Clean Shampoo   resolver: lane:grocery/resolve-match-worklist.ps1 (a wrong product -> an exclude via apply-coverage-batch -FromWorklist) or the band derivation (a real price)
  UNEXPLAINED  shampoo | Aldi | 0.4775 against reference 0.0941 | Pantene Pro-V 2 IN 1 Classic Clean   resolver: lane:grocery/resolve-match-worklist.ps1 (a wrong pr ...[truncated - full context in ad-cycle-log.txt / the source audit json]

graded: 3c7a00808 at C:\Codex\ThriftyCrew, 0 commit(s) behind origin/main, worktree: main
```

## Step 9, two-signal identity (family 2)

Owner: `step:design/PLAN-zero-alert-days-remainder-2026-09-24.md#9`

### 2026-09-28-6fc290: Triage residual: Family Fare ad lines route household products to food, store department unread (10d164)

```text
Residual of triage queue 2026-09-27-10d164 (plan grocery/triage-plans/plan-2026-09-28-10.json), part (1).

A Family Fare Weekly Ad line can name a household product without its class noun and still route to a food commodity. Every defence on the road is a noun or brand vocabulary (lemons exclude has 'trash\s+bags?', 'detergent', '\bcascade\b'; audit-household-in-food.ps1 is unsound by its own header, it sees only $HOUSEHOLD_SIGNAL words). The store's own department, which the flyer-link lane records, is read by no gate.

Occurrences: 2 in 17 days, both FF Weekly Ad lines on lemons:
- 'Cascade Ap Comp Lemon', comparison-2026-09-11 (known-wrong lemons|FamilyFare|cascade-ap-comp-lemon)
- 'Glad Drawstring Odor Shield Lemon Tall Kitchen 40 Ct', comparison-2026-09-27 and -28, published 3451de927 (known-wrong lemons|FamilyFare|glad-drawstring-odor-shield-lemon, added 2026-09-28)

Evidence: grocery/familyfare/flyer-link-evidence-2026-09-27.jsonl:179 resolves the Glad line to Freshop 14841, canonical_url https://www.shopfamilyfare.com/shop/household/trash_bag... Of 171 resolved lines in that file (20 more search-failed), 5 carry department 'household': charcoal, sponges x2, dishwasher-detergent (correct) and lemons (the bug).

Fix shape from the plan: audit-household-in-food (hard, cell-scoped) gains a second input, the flyer-link evidence department (/shop/household/, personal-care, pet, baby), for any FF ad claim on a food commodity. Covers FF ad lines the flyer linker resolves (171 ...[truncated - full context in ad-cycle-log.txt / the source audit json]

graded: 3806f1535 at C:\Codex\ThriftyCrew, 0 commit(s) behind origin/main, worktree: main
```

### 2026-09-28-184b1d: triage residual: 4 matching-worklist keys need a two-rule fix or a reading (plan-2026-09-28-13)

```text
Residual of plan-2026-09-28-13 round 2 (items 2026-09-27-c744ba and 2026-09-26-564dc6). 4 matching-worklist keys stay undecided because a plain release would move each product from one wrong commodity to another. None of the 4 holds a board cell on comparison-2026-09-28 (checked by name).

Measured 2026-09-28 by routing each name through New-CommodityMatcher over grocery/commodities.json, with the release simulated:
1. contested|carrots: 'Del Monte Peas And Carrots 8.5 Oz' is claimed by carrots; released it lands on frozen-vegetables, but Del Monte 8.5 oz is a can. The right home is probably canned-mixed-vegetables, which needs an include there plus an exclude on carrots, and a check that frozen peas and carrots bags stay on frozen-vegetables.
2. contested|milk: 'Muscle Milk Cookies N Creme High Protein Shake ... 4 Ea' is claimed by milk; released it lands on cookies. No protein-shake commodity exists, so the right result is unmatched: an exclude on milk AND on cookies.
3. contested|garlic: 'New York Bakery Cheesy Focaccia Pesto & Garlic' is claimed by garlic; released it lands on pesto. It is frozen garlic bread; garlic-bread exists but does not admit it.
4. coverage|canned-pears|Fareway: 'Fareway Diced No Sugar Added Pears' matches nothing. The row carries no size, so canned pears and a fruit-cups 4-pack cannot be told apart; it needs a reading of the Fareway listing before any rule.

Each fix is a grocery/commodities.json change for the money lane, through apply-coverage-b ...[truncated - full context in ad-cycle-log.txt / the source audit json]

graded: 03c761d06 at C:\Codex\ThriftyCrew, 0 commit(s) behind origin/main, worktree: main
```

### 2026-09-29-356c4e: Triage residual: facial-tissues / Walmart 0.0137 vs 0.0103 after the lotion release, mechanism not isolated (b96f21)

```text
Residual of plan-2026-09-29-3, item 2026-09-21-b96f21 (carried from plan-2026-09-22-9, whose owner 2026-09-22-0c812e has since closed).

facial-tissues / Walmart moved 0.0103 -> 0.0137 each at the 2026-09-23 landing, under the lotion release (lotion.exclude += \bfacial\w*\s+tissue). Origin rules on the same inputs kept 0.0103 (the 08-31 'Great Value Everyday Soft' rollback row). The mechanism was never isolated.

Measured 2026-09-29 on comparison-2026-09-29 (10:52 build): the Walmart cell holds 'Great Value Ultra Soft Facial Tissues, 4 Flat Cartons, 120 Tissues per Carton' $6.58 / 480 ct = 0.0137 each. The arithmetic is right and the cell is not the crown (Sam's Club 0.008). Not checked: whether an 'Everyday Soft' row is in today's Walmart capture at all (if it is not, this closes as no longer reproducing; if it is, find which rule stops it reaching facial-tissues).

Occurrences: 1 cell, first seen 2026-09-23, still present 2026-09-29. Nothing else watches it.


graded: def8085a8 at C:\Codex\ThriftyCrew, 5 commit(s) behind origin/main, worktree: main
```

### 2026-09-29-465acc: triage residual: 3 identity cells need a store product-detail read (olive oil mayo, 2 sun-dried jars)

```text
Residual of 2026-09-26-177835 (plan-2026-09-29-3), folding in 2026-09-29-59b8fc.

WHAT IS OPEN: 3 cell findings from audit-ingredient-identity against comparison-2026-09-29 (exit 2, RISE 3 over the 2026-09-26 mark of 86). They page daily until the FORM of each listing is proven by a store's own product detail, not by its name:

1. Mayonnaise (10 lines, 10 recipes, basis board:mayonnaise:walmart): Baker's cell winner is "Kroger Olive Oil Mayo", 30 fl oz $3.99 ($0.133/oz), product_id 0001111001968 (bakers-regular-2026-09-29). The Mayonnaise identity_same_as record (2026-09-27-c989c6) deliberately leaves olive oil mayo a finding until a capture proves it is not a reduced-fat mayonnaise dressing. A WebFetch of the bakersplus page timed out on 2026-09-29: could not verify.
2. Sun-Dried Tomatoes (Oil-Packed) (1 line, 1 recipe, basis board:sun-dried-tomatoes:walmart): Family Fare "California Sun Dry Sun Dried Tomatoes Julienne Ct", 8 oz $5.99 ($0.7488/oz).
3. Same row: Hy-Vee "Hy-Vee Sun-Dried Tomatoes Halves", 8.5 oz $6.99 ($0.8224/oz).
Size and price say jars in oil (the dry halves bag Baker's sells is 3 oz $3.99, $1.33/oz, candidates-2026-09-29), but neither name says oil, and the c989c6 fixture keeps the Family Fare listing a finding on purpose. Aldi "Tuscan Garden Sundried Tomatoes 8 OZ" ($0.4988/oz) is the same shape and already sits in the mark.

NO PRICE MOVES TODAY: no recipe line is costed at these cells (both rows price from Walmart).

REPAIR: read each listing's product  ...[truncated - full context in ad-cycle-log.txt / the source audit json]

graded: a2b784907 at C:\Codex\ThriftyCrew, 2 commit(s) behind origin/main, worktree: main
```

### 2026-09-30-88bd45: Triage residual: soundness cell quarantine false-positive rate, 2 of 3 crown findings were good cells (ef21d4)

```text
Residual of triage 2026-09-30-ef21d4 (plan-2026-09-30.json), which implemented Brad's ruling Q-2026-09-29-4-A: a match-soundness finding on a winning cell now quarantines that cell (held at its last verified published price, or withheld) instead of holding the post.

What is left open: the cell-by-contest trigger quarantines GOOD cells as well as bad ones. Brad ruled that cost acceptable (a false positive costs one cell until resolve-match-worklist.ps1 -Decide, not the whole post), so this is a rate to watch, not a defect to fix.

Measurement (2026-09-30, over all 283 committed versions of grocery/out/audit/soundness-report.json, 2026-09-13 to 2026-09-30):
- 10 versions carried a non-empty cell_by_contest; 6 distinct findings.
- 3 of the 6 were crowns (winning cells), the class ruling A quarantines:
  - horseradish @ Aldi 0.2989/oz, Inglehoffer Horseradish Cream Style 9.5 OZ (2026-09-24, 09-25): GOOD cell, confirmed by 2026-09-24-f44c88.
  - carrots @ Aldi 0.29/lb, Specially Selected Carrots Sweet Potatoes 16 OZ (2026-09-29): BAD cell, released by 2026-09-29-754693.
  - rotisserie-chicken @ Walmart 3.97/each, (Chilled) Freshness Guaranteed Lemon Pepper Rotisserie Chicken, 36 oz (2026-09-30): GOOD cell, confirmed by 2026-09-30-abf660.
- False-positive rate on crowns: 2 of 3 (the other 3 findings were non-crown cells, all bad matches: Dawn in strawberries, Mochiko flour in rice, walnut oatmeal).
- Under ruling A: carrots would have been held at its last verified 0.995 (2026-09- ...[truncated - full context in ad-cycle-log.txt / the source audit json]

graded: a3d8b01f2 at C:\Codex\ThriftyCrew, 0 commit(s) behind origin/main, worktree: main
```

## Step 11, the review packet (family 3)

Owner: `step:design/PLAN-zero-alert-days-remainder-2026-09-24.md#11`

### 2026-09-30-a57d2e: Grocery matching soundness: NEW CONTESTED

```text
 - NEW-CONTESTED Barissimo Halloween Ground Coffees Chai Cookie 12 OZ | chain: coffee (oz) > cookies (oz) | engine: size 12 oz = 0.4908/oz
 - NEW-CONTESTED [FORM] Giovanni Rana Chicken Alfredo & Mushroom Lasagna, 40 oz. | chain: mushrooms (oz) > frozen-lasagna (oz) | engine: size 40 oz = 0.3455/oz
 - NEW-CONTESTED Specially Selected Pepperoni Marinara 8 OZ | chain: pasta-sauce (oz) > pepperoni (oz) | engine: OUT-OF-BAND
 - CROWN-BY-CONTEST (Chilled) Freshness Guaranteed Lemon Pepper Rotisserie Chicken, 36 oz | cell rotisserie-chicken @ Walmart 3.97/each | claimed by: rotisserie-chicken > lemon-pepper-seasoning

Full report: grocery\out\audit\soundness-report.json. After review: audit-match-soundness.ps1 -Accept, then commit grocery\out\audit\match-baseline.json WITH the rule change; ops\verify-commodities-gate.ps1 refuses a rule commit whose staged baseline does not cover it. A NEW CONTESTED arrival is not cleared by -Accept: decide it with resolve-match-worklist.ps1 -Decide.

graded: 6c1016a21 at C:\Codex\ThriftyCrew, 0 commit(s) behind origin/main, worktree: main
```

### 2026-09-30-0210a6: Grocery: 3 store(s) dropped from a commodity they carry - 2026-09-30

```text
NEW today and still open on the matching worklist (grocery/out/match-worklist.json; resolver lane:grocery/resolve-match-worklist.ps1, the weekly lane applies releases and widenings through apply-coverage-batch -FromWorklist):
- Member's Mark Garlic Parmesan Brussels Sprouts with Balsamic Glaze, priced per pound | brussels-sprouts @ Sam's Club | lane: release - the head noun 'sprouts' names brussels-sprouts, and garlic's own words do not
- Fresh Beef Bone-In Short Ribs | beef-short-ribs @ Aldi | lane: widen - the head noun 'ribs' names beef-short-ribs and no rule admits the name

audit-coverage-gaps found 3 store(s) missing from a commodity whose product they appear to carry, each tagged with WHY: [RULE-INVISIBLE] no include matches the name, so widen that commodity's include; [CLAIMED-BY] first-match-wins gave the name to another commodity, so add a release exclude or confirm the claim; [PRICED] the engine priced a row the board does not show, so look downstream of matching, not at a rule; [UNKNOWN-VERDICT] the engine refused the row with a verdict the audit does not know, so teach Get-EngineVerdictReason in audit-coverage-gaps.ps1 (not a rule gap). brussels-sprouts @ Sam's Club [CLAIMED-BY]; beef-short-ribs @ Aldi [RULE-INVISIBLE]; canned-pears @ Fareway [RULE-INVISIBLE]. A reviewed exception goes in coverage-gap-allowlist.json. 295 further gap(s) are engine-explained (withheld by the provenance contract, refused by an engine gate, BASIS-NULL, BAND-DROPPED, RULED-WRONG, AD-L ...[truncated - full context in ad-cycle-log.txt / the source audit json]

graded: 6c1016a21 at C:\Codex\ThriftyCrew, 0 commit(s) behind origin/main, worktree: main
```

### 2026-09-30-8415b9: Grocery: semantic sweep found 4 product(s) no rule can see - 2026-09-30

```text
The embedding sweep found real store products that look like a tracked commodity but match NO include pattern. NEW today and still open on the matching worklist (resolver lane:grocery/resolve-match-worklist.ps1; the weekly lane applies decided widenings through apply-coverage-batch -FromWorklist):
- Prairie Fresh Natural Fresh Pork Spareribs, Bone-in, 4.0-5.5 lb, 19g Protein per 4oz Serving | baby-back-ribs @ Walmart | lane: undecided - head noun 'spareribs' does not name baby-back-ribs
- Prairie Fresh Natural Fresh Pork St. Louis Style Spareribs, Bone-in, 3.0- 4.4 lb, 19g of protein per 4oz serving | baby-back-ribs @ Walmart | lane: undecided - head noun 'spareribs' does not name baby-back-ribs
Details: grocery/out/semantic-findings.json.


graded: 6c1016a21 at C:\Codex\ThriftyCrew, 0 commit(s) behind origin/main, worktree: main
```

## Phase 6, traps into gates (family 6): the part Phase 6 did not close

Owner: `step:design/PLAN-weekly-root-families-2026-10-02.md#phase-6`

### 2026-09-27-ae8b7a: Triage residual: test-match-lib load reds and unexplained non-blind divergences (06cd9b)

```text
Residual of triage 2026-09-27-06cd9b (plan grocery/triage-plans/plan-2026-09-27-2.json).

WHAT HAPPENED. test-match-lib failed at 09:11 on 2026-09-27 inside test-auditors' early pool while the 08:49 check-ad-cycles chain ran: 3,915 divergences over 45,759 names, 2,274 could-not-look (blind) and 1,641 NON-blind fast-path divergences. At rest the same day: 0 and 0 (twice, 45,762 names).

WHAT SHIPPED. test-match-lib now re-looks EVERY divergence after the shard pool drains (the 50-look cap is gone) and classes the red on its own FAILED line: DRIFT (disagrees again), UNRECORDED (agreed on re-look, no timeout recorded), still-blind. The full lists go to %TEMP%\matchlib-relook-<stamp>-<id>.json, named on the FAILED line.

STILL OPEN.
(a) The mechanism of the 1,641 non-blind divergences is unproven. Reproduction under ops/cpu-load.ps1 -Cores 20 (20 of 24 slots, 36 busy processes on 32 cores) gave 0 blind and 0 divergences, exit 0, so controlled CPU load alone does not reproduce it. Occurrences: 1 day (2026-09-27, 1,641 rows); 2026-09-24 not recorded. If the next loaded red prints UNRECORDED rows, match-lib answered differently with no recorded timeout: that is a MONEY-LANE item (the engine uses match-lib), with the rows from the list file.
(b) test-auditors still runs the census beside the daily chain at peak, so a load storm still pages, now labelled still-blind. Occurrences: 2 in 30 days (2026-09-24-3ca22f, 2026-09-27-06cd9b). Options: move early:match-lib out of the chain-peak w ...[truncated - full context in ad-cycle-log.txt / the source audit json]

graded: 41d8d0d31 at C:\Codex\ThriftyCrew, 1 commit(s) behind origin/main, worktree: main
```

## Bot-dedicated checkout, Stage 2 W2.1 (family 5, foreign writers)

Owner: `step:design/PLAN-bot-dedicated-checkout-2026-09-25.md#stage-2`

### 2026-09-28-2bcd10: Triage residual: foreign writers in the production checkout await bot-dedicated-checkout Stage 2 W2.1

```text
Residual of 2026-09-27-f50b7a, carried through 2026-09-28-90a544 (resolved, shipped), re-owned in grocery/triage-plans/plan-2026-09-28-7.json.

What is left: a session or hand command that changes a chain verdict INPUT's content (commodities.json, known-wrong.json, board-price-overrides.json, product-urls.json) in the production checkout while the daily chain runs still withholds that day's board. That is the correct fail-closed answer, and since 1cb27d9e8 it pages as itself ('Daily chain withheld its board: <paths> changed after guards ran', lane verdict-stale) naming the moved paths. The fix is to stop the write, not the withhold.

Measurement (plan-2026-09-28-6.json, item 90a544): 1 proven content move by a session (2026-09-20, commit 5d42fb944, commodities.json at 11:40:06) over 26 daily runs 2026-09-01..2026-09-28, plus 1 unattributed pull inside a window (2026-09-20 08:23:19). The line-ending half (09-27) is fixed: a CRLF round-trip no longer moves the fingerprint.

Owner of the real fix: design/PLAN-bot-dedicated-checkout-2026-09-25.md Stage 2 W2.1 (the barrier refuses a session write to the production checkout). That plan says Stage 2 waits on Stage 0, and no queue item tracked W2.1 until this one.

Cheapest next step: when W2.1 ships, close this against it. Until then, each verdict-stale page is a lookup: its moved-path line names what changed, and the main reflog names who.


graded: c349cbd77 at C:\Codex\ThriftyCrew, 0 commit(s) behind origin/main, worktree: main
```
