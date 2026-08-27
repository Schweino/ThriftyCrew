NO-GO
scope: whole-wave

# Wave 2 audit, run hunt-2026-08-27-ten
Auditor: recipe-batch-auditor (final gate), 2026-08-27
Battery: wave-2.preaudit.json, generated 2026-08-27T06:39:43, 30 checks, 1 failed.
Band of record (from the run dir, not the prose): cal 450-700, carbs <= 40, protein >= 40.

## Battery disposition
The one battery FAIL (audit-cost-line-coverage, rc=1) was the battery's own invocation
bug, not a wave defect: wave-preaudit.ps1 passed the three slugs as ONE comma-joined
string and the gate REFUSED ("1 slug(s) named but NONE matched a spec"). A refusal is a
blocked stage, so I re-ran the gate myself with the array form:
    audit-cost-line-coverage.ps1 -Slugs a,b,c  ->  AUDIT-COST-LINE-COVERAGE-COMPLETE clean n=3, exit 0
The underlying gate is clean. The battery defect still needs fixing (owner:
meal-prep\pipeline\wave-preaudit.ps1, the known -Slugs comma-join trap) or every future
wave ships with this gate silently blocked.

All other battery chains were verified, not re-derived, except where noted below; the
jamie-oliver calorie chain was re-derived by hand end to end because it sits 7 cal under
the 700 ceiling (batch: chicken 5250 g x 1.505 = 7875 + milk 643 + oil 831 + lemons 118 +
garlic ~156 + minors ~30 = 9653 vs battery 9706; agrees).

## Verdict per category
- MACROS: ISSUES FOUND (milk form-flip, yogurt wrong row - below)
- COSTS: ISSUES FOUND (milk price/macro basis split; bacon grams-basis question; bread price note)
- MAPPING: ISSUES FOUND (the two wrong-form rows are mapping defects)
- PROTEIN/ROTATION: clean (all three derivations verified; note the broth quirk below)
- CARDS: clean (battery rebuild structurally identical to the live reference on all three)
- VOICE/COPY: ISSUES FOUND (title cruft, milk prose contradictions - fold into repairs)
- GATES: clean (no gate weakened; coverage gate re-run through its owning script unmodified)

## BLOCKER 1 - jamie-oliver-s-chicken-in-milk-seriously-delish (recipe-local)
Milk is a form-flip that decides a band pass.
- The macro basis row is food-macros-db "Milk (Fairlife)": Fat Free ultra-filtered,
  80 cal / 13 P / 6 C / 0 F per 240 g cup.
- The recipe's own ingredient line says "8 cups LOW FAT milk". The cost line prices a
  $2.82 generic gallon (bid: milk, gpu 3785; Fairlife sells ~$4.50/52 oz, never $2.82/gal).
  shop_smart says "Grab the store brand; there is no premium milk on earth that will make
  this sauce better."
- Cooked with the milk the card instructs (store-brand 1%: ~42 cal / 3.4 P / 5 C / 1 F
  per 100 g), the batch is 9706 - 643 + 810 = 9873 cal -> ~705 cal/serving, ABOVE the
  700 ceiling; protein ~54 not 57; carbs ~13.5 not 10; fat ~47.6 not 46.2.
  The recipe clears this run's calorie ceiling only on a macro basis its own cost and
  shopping copy contradict. That is the spinach-form-flip class of defect.
- Repair owner: recipe-ingredient-mapper - map "low fat milk" to a low-fat (1%) milk row
  (add one if absent), then re-lock macros and re-cost through the owning stages.
  NOTE for the run: on the correct basis this recipe recomputes to ~705 cal and FAILS the
  450-700 band. It likely needs tuning (e.g. trim oil, or skim the poured-off fat into the
  basis) or rejection under this run's conditions. That ruling belongs to the run, but it
  cannot publish as-is.
- Same repair pass, copy fixes: (a) shop_smart says "exactly one half gallon carton...
  buying a single container" while the cost line says "Buy 1 gallon: $2.82" - pick one;
  (b) the title "Jamie Oliver's Chicken in Milk {Seriously Delish}" carries the source
  blog's brace cruft; on our card it reads as scraper residue. Recommend "Jamie Oliver's
  Chicken in Milk" (credit line already attributes recipetineats.com properly).
- Non-blocking note: the Whole Chicken row (150 cal / 13 P per 100 g as-purchased) is a
  modeled 0.70 meat-and-skin yield on USDA SR 05006 and carries needs_verify=true; the
  derivation is internally consistent (215 x .70 = 150.5, 18.6 x .70 = 13.0) and is the
  only workable basis for a bone-in whole bird. Leave to the provenance rungs.

## BLOCKER 2 - spaghetti-squash-boats-with-chicken (recipe-local)
Yogurt is mapped to the wrong food-DB row.
- The recipe specifies "1 3/4 cups NONFAT plain GREEK yogurt" (427 g). The macro row used
  is "Plain Yogurt (generic (USDA))" = plain WHOLE-MILK yogurt (61 cal / 3.47 P / 4.66 C /
  3.25 F per 100 g), whose own note says it is deliberately NOT the Greek Yogurt row.
  The DB has a Greek Yogurt row (100 cal / 17 P per 170 g). The bid (greek-yogurt) is
  right; the macro row is not.
- Impact: protein understated ~2 g/serving (true ~42.5 vs published 40), fat overstated
  ~1 g/serving, carbs slightly overstated. Direction is band-safe (the 40-g floor is MET
  either way, and more comfortably on the correct row), but the published macros are not
  label-accurate for the ingredient the card sells, and label accuracy is the contract.
- Repair owner: recipe-ingredient-mapper - remap to the Greek Yogurt row, re-lock macros
  (this also moves stat.protein off its knife-edge 40).
- QUESTION, same slug, material to the headline cost: bacon grams basis. The line is
  "14 strips thick-sliced center-cut bacon (168 g)". 168 g is a COOKED-slice weight
  (GV label: 2 cooked slices = 15 g; 14 raw thick strips run ~400+ g raw). The batch cost
  tier charges 168 g against the RAW per-pound bid (~$1.47) while the dish consumes most
  of the 1-lb package the true tier buys, so the batch tier and the $2.68 headline
  understate bacon by roughly $2 batch / ~$0.15/serving. Either the grams basis or the
  batch-tier charge is wrong; the mapper/extractor must rule which. Macros are coherent
  IF 168 g is cooked weight; if 168 g was meant raw, the macros are overstated instead -
  the ambiguity itself is the finding.
- Unresolved writer FLAG, ruled here: black pepper under-scaled - source seasons twice
  (squash + chicken, 1/2 tsp total -> 1 3/4 tsp at 3.5x) but the locked line carries only
  "scant 1 tsp" / 4 g. The flag is REAL. Impact on macros/cost/band is nil (seasoning
  grams), and the step prose still seasons both stages, so this is cosmetic - fix the buy
  line to 1 3/4 tsp (~8 g) in the same repair pass. It does not block on its own.

## baked-stuffed-pork-chops - CLEAN (GO on its own)
- Macro chain hand-checked: batch cal ~7340 recomputed vs 7462 stated, protein ~710 vs
  714 - agrees within basis noise. 533 / 13.5 C / 50.6 P sits comfortably in band.
- Cost: $3.27/lb boneless loin chops is shelf-plausible Omaha; tiers sum sensibly
  (32.39 batch, 44.42 true, 55.41 first-run = true + 10.99 pantry).
- Cranberries-stay-FRESH ruling is documented in writer_notes with the source's own macro
  label as evidence - sound. Salt double-use QA repair verified present in the buy line.
- Dish identity: distinct from farmhouse-pork-chop-stuffing-casserole (casserole vs
  pocket-stuffed whole chops); no dupe.
- Notes, non-blocking: (a) the protein-derivation tally counted 560 g of chicken BROTH as
  chicken - harmless here (pork 3174 g dominates) but the deriver should exclude broths
  before a broth-heavy recipe mislabels; owner: update-recipes-db derivation. (b) Sandwich
  bread priced $6.97 per 20-oz loaf is high-side for generic white (~$1.50-2.50 shelf);
  overstates cost so it cannot sneak a cheap claim, but the bid class deserves a look.

## Shared data / estate
- Shared audits clean (contradictions, store-integrity hard=0, vocab n=3, unbid n=3,
  plausibility n=3, coverage clean n=3 on my re-run, dryrun 0 null item_ids, feed live and
  provenance-consistent).
- Battery defect (comma-joined -Slugs) recorded above; owner wave-preaudit.ps1. Tooling
  fix, does not block the wave once the gate was proven clean by direct run.

## GO / NO-GO
NO-GO. Blocked by:
1. jamie-oliver-s-chicken-in-milk-seriously-delish - milk form-flip with a band
   consequence (recipe-local; owner recipe-ingredient-mapper, then re-cost/re-lock and a
   run-level band ruling at ~705 cal).
2. spaghetti-squash-boats-with-chicken - Greek yogurt macro'd off the whole-milk plain
   row (recipe-local; owner recipe-ingredient-mapper), plus the bacon grams-basis
   question, which is material to the published $2.68 and must be ruled, not shrugged.
baked-stuffed-pork-chops is clean and may ride in the next wave file unchanged once the
wave is re-cut. After repairs, a scoped re-audit
(wave-preaudit.ps1 -Slugs jamie-oliver-s-chicken-in-milk-seriously-delish,spaghetti-squash-boats-with-chicken)
plus this desk's re-review of the two repaired chains is required before any GO.
