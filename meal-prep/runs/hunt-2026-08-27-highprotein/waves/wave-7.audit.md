NO-GO
scope: whole-wave

# Wave 7 audit - hunt-2026-08-27-highprotein - 2026-08-27

Auditor: recipe-batch gate (final pre-publish). Battery report wave-7.preaudit.json
(generated 2026-08-27T17:53:10, 30 checks, 1 fail) read and its chains verified; the one
failed stage re-derived by hand and found clean; residue checks done. One blocker, and it
is not in the wave's own three recipes.

## VERDICT: NO-GO

### Blocker (shared-data, NOT recipe-local): recipes-db.json still carries THREE
### audit-rejected recipes marked published
Wave-6's Blocker 2 ordered pipeline to remove two rejected-audit rows from
meal-prep\recipes-db.json "before or with this wave's publish". Verified right now, 568 rows:

* pioneer-woman-chili                              state=rejected-audit, in recipes-db, published=2026-08-27
* healthy-hamburger-helper                         state=rejected-audit, in recipes-db, published=2026-08-27
* teriyaki-grilled-chicken-and-veggie-rice-bowls   state=rejected-audit (wave 6), in recipes-db, published=2026-08-27

Nothing was repaired, and the set GREW: teriyaki was written to recipes-db by wave-4's
partial publish (E3 ran, E4 refused), then rejected by the wave-6 audit and trimmed out of
wave 7, so its row is now a third published row that no wave carries and no page backs.
The arithmetic tells one story: 568 db rows minus 562 live feed recipes = 6; three are this
wave's slugs (their pages publish with this wave) and three are these orphans, which point
nowhere. The free-dinner rotation and the hub Top 5 read this file and can crown a recipe
whose page does not exist. Wave-publish P2/P3 reconcile only the wave's own slugs and will
not catch it.

Repair owner: PIPELINE. Remove the three rows via the documented Remove-RecipeRow /
-Replace flow (file: meal-prep\recipes-db.json) before or with this wave's publish.
Teriyaki's row removal is safe regardless of its pending dedup re-ruling: if the
dedup-selector later rules it distinct, its own wave's publish re-adds a fresh row.
Then a scoped re-audit (-Slugs) - the wave's recipes carry no defect and re-check in seconds.

## Blocked-stage re-derivation (battery fail: recipes-db-dryrun) - CLEAN
Same instrument defect wave-6 filed: the battery invokes update-recipes-db.ps1 -DryRun bare
and it dies on the absent <run>\specs-ready.txt before printing the item_id source line
(rc=1, null_item_ids=-1 in the report - a blocked stage, not a finding against the data).
Re-ran the publish way myself:
  update-recipes-db.ps1 -RunDir <run> -DryRun -SpecList waves\wave-7.preaudit-slugs.txt
  -> exit 0, "item_id source: ingredient-map 0 rows | scaler-bid fallback 0 rows |
     no id (null) 0 rows", "skipped already-present: 3", "nothing to add".
The three rows already in recipes-db (written by wave-4's E3) carry 0 null item_ids and
match their current specs on all per_serving macros and all five cost tiers (verified by
direct comparison). normalize-recipe-ids.ps1 NOT run (new-era rows). The battery -SpecList
fix remains owed to pipeline (non-blocking, filed again).

## Checklist results (the wave's three recipes: all clean)
1. MACROS + BAND - clean. Spec bytes unchanged since the wave-6 audit (mtime 2026-08-27T16:22:57
   recorded identically by both preaudits; battery generated 17:53:10, after the last edit),
   so wave-6's end-to-end hand recomputes still certify these bytes:
   ground-beef-cottage-cheese-bowl 550.4/41.7/33.6/28.9 (100% recompute done - within 5% of
   the 550 gate) and butter-chicken-pasta 630.4/40.22. chicken-rice-and-broccoli verified
   against the battery chain 471.9/47.3/47/9.7 and independently sanity-decomposed (chicken
   170 g/serving ~ 38 g protein + rice + parmesan lands at the recompute). stat rounding
   correct on all twelve numbers. BAND (cal 450-800, protein >= 40, from the run dir):
   550.4 / 630.4 / 471.9 in band; 41.7 / 40.2 / 47.3 all >= 40. Prose conditions also hold:
   proteins are 93/7 ground beef, boneless skinless chicken breast x2 (allowed cuts); real
   carb source in each (sweet potato 1213 g, pasta 1050 g, rice 648 g); no seafood;
   14 servings each. NOTE: butter-chicken-pasta clears the 40 g floor by 0.2 g/serving -
   thin but real; chicken DB row USDA-corroborated 2026-08-26 (wave-6 audit).
2. COSTS - clean. Tier sums verified: first_run = true + pantry_add on all three
   (49.98+15.34=65.32, 33.68+16.93=50.61, 27.95+12.92=40.87); per-serving derivations exact;
   lines_unpriced=0 everywhere so no 2b repair-owner classification is owed. Shelf spot
   checks: chicken breast $2.23/lb, 93/7 beef $6.07/lb, cottage cheese ~$2.73/24oz,
   avocados ~$0.58 each, pasta ~$0.97/lb, almond butter ~$5.86/16oz, chicken broth board
   bids $1.69-1.79/32oz (re-checked on the board myself). No 3x-cheap survivor, no wrong
   price class. cost_ps EVERYDAY basis verified: all three = cost_first_run/14 to the cent
   (4.67 / 3.62 / 2.92), same convention as live al-pastor and exactly what wave-publish E2
   re-anchors and hard-verifies per slug.
3. MAPPING - clean. 0 null item_ids (dry-run above). Form calls re-reviewed: fresh-or-frozen
   broccoli -> frozen-broccoli-florets with prose explicitly offering both and frozen the
   honest cheaper form for a 5-min in-pot simmer (not a spinach-style form-flip); chicken
   stock -> chicken-broth same-concept (mapper confirm noted in writer_notes, correct);
   generic "short pasta (penne, rigatoni or rotini)" -> pasta (source names no shape);
   almond-butter was registrar-minted with the already-priced-under-another-name sweep
   (wave-6 verified). The chicken-rice BLOCKING-2 spice under-scaling the writer flagged
   (3.0x vs 3.5x, out of writer reach) IS repaired: all 14 lines verify at exactly 3.5x of
   the 4-serving source, spices at 7 tsp = 3.5 x 2 tsp, grams consistent (7/4/22/17 g).
4. PROTEIN + rotation - clean. claimed=derived on all three (beef/chicken/chicken),
   heaviest-by-grams. Instrument defect (filed by wave-6, still present): the tally counts
   chicken BROTH as chicken (4901 = 2381 breast + 2520 broth). Verdict unaffected here;
   latent false-attribution risk for a beef/pork recipe heavy on chicken broth stands.
5. CARDS - clean. Battery rebuilt all three to scratch, structurally identical to the
   known-good live al-pastor card; JSON-LD parses as Recipe. My grep of the rebuilt
   head+body: zero surviving {{tokens}} (the {{cal}}/{{protein}} tokens in head.description
   substitute correctly). 3-part cost section, print/scaler machinery, source credit
   present. No new visual element beyond the proven template, so the 375px rule is
   satisfied by template identity with the live card.
6. VOICE - clean. 0 em/en dashes (battery + spec reads), no swearing, warm no-BS prose,
   credit lines correct, forbidden-term lists respected.
7. GATES - none weakened. The one battery fail was re-derived, not waved through.

## Non-blocking findings (all also in `findings`)
* wave-preaudit battery still invokes update-recipes-db bare and fails on missing
  specs-ready.txt; should pass -SpecList (owner: pipeline). Second consecutive wave.
* protein-derivation tally counts chicken-broth grams as chicken (owner: pipeline).
* butter-chicken-pasta protein floor margin 0.2 g/serving (informational; chain holds).
* butter-chicken-pasta dual-quantity basis inconsistency (half-and-half by metric ml,
  tomato sauce by US cups; <= ~6 cal/serving) - unchanged bytes, carried from wave-6
  (owner: mapper, with the ~15-pair food-DB backfill).
* teriyaki-grilled-chicken-and-veggie-rice-bowls still owes the dedup-selector re-ruling
  vs live teriyaki-chicken-bowl (wave-6 Blocker 1); does not block THIS wave since the
  slug was trimmed, but the ledger question is open (owner: recipe-dedup-selector).
* Wave-7's publish will re-carry outside-wave dirty specs via propagate; orchestrator must
  supply a correct wave-7 allow-create list - the wave-4 refusal came from exactly that
  mechanism (owner: pipeline).
* Display-brand note, informational only: chicken-broth line shows "(Swanson)" while the
  priced basis matches the store-brand-tier board bids ($1.69-1.79/32oz); within class,
  not a price defect.

## What publishing needs
1. Pipeline removes the three rejected-audit rows (pioneer-woman-chili,
   healthy-hamburger-helper, teriyaki-grilled-chicken-and-veggie-rice-bowls) from
   meal-prep\recipes-db.json via Remove-RecipeRow.
2. Scoped re-audit of wave 7 (-Slugs ground-beef-cottage-cheese-bowl,butter-chicken-pasta,
   chicken-rice-and-broccoli) - expected clean in seconds; the wave's recipes carry no
   recipe-local defect.
