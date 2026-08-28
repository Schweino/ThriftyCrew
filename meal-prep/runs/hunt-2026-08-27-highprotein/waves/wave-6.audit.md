NO-GO
scope: whole-wave

# Wave 6 audit - hunt-2026-08-27-highprotein - 2026-08-27

Auditor: recipe-batch gate (final pre-publish). Battery report wave-6.preaudit.json
(generated 2026-08-27T17:35:29, 37 checks, 1 fail) read and verified; blocked stage
re-derived by hand; residue checks done. Two blockers.

## VERDICT: NO-GO

### Blocker 1 (recipe-local): teriyaki-grilled-chicken-and-veggie-rice-bowls - dish identity
The live catalog already carries `teriyaki-chicken-bowl` ("Teriyaki Chicken and Rice Bowl"):
boneless skinless chicken breast + teriyaki sauce + rice + broccoli florets + shredded carrots.
The new recipe is boneless skinless chicken breast + homemade teriyaki (soy/brown sugar/honey/
ginger/garlic/rice vinegar/cornstarch) + rice + broccoli + carrots + zucchini. Same dinner on
the plate: same protein cut, same sauce identity, same starch, two of three vegetables shared.

The dish ledger (db\considered-dishes.json) condemns this by its own precedent, set the same day:
* 11:40:27 crock-pot-teriyaki-chicken REJECTED: "duplicates the live teriyaki-chicken-bowl on
  protein, teriyaki/soy sauce and rice starch; added stir-fry veg does not make it a distinct
  dinner."
* 11:44:57 grilled-teriyaki-chicken-kebabs REJECTED: "identical dinner to live Teriyaki Chicken
  and Rice Bowl and to the accepted teriyaki grilled chicken rice bowls" - the decider's own
  words treat the accepted slug and the live bowl as the same dinner.
* 11:40:25 the ACCEPTANCE reason compares only against "live orange/sweet-sour/adobo chicken
  bowls" and never names teriyaki-chicken-bowl, the closest live neighbor. The nearest neighbor
  was not weighed.

Repair owner: recipe-dedup-selector (the sole author of acceptances and the dish ledger) must
re-rule this slug with the live teriyaki-chicken-bowl explicitly confronted. If it rules distinct
with written evidence, the slug returns; if dupe, drop it from the wave and re-audit scoped.
This is not a rejected mapping and no ingredient is at fault.

### Blocker 2 (shared-data): recipes-db.json carries two audit-rejected recipes marked published
Wave 4 (which contained all six of these slugs) got a GO and its publish ran E3 - WRITING
recipes-db.json (568 rows) - before REFUSING at E4 (propagate -AllowCreateFile error,
wave-4.publish-refusal.txt). The four wave-6 rows left behind are harmless: they match the
current specs field-for-field (verified: per_serving macros + all five cost tiers exact on all
four) and wave-6's publish completes them today. But the other two wave-4 slugs:

* pioneer-woman-chili       state=rejected-audit (wave 5) yet in recipes-db, published=2026-08-27
* healthy-hamburger-helper  state=rejected-audit (wave 5) yet in recipes-db, published=2026-08-27

Two recipes the audit rejected sit in the live recipes-db marked published, with no wave carrying
them to a page. The free-dinner rotation and the hub Top 5 read this file; either can crown a
recipe whose page does not exist (live feed has 562 recipes; these rows point nowhere). Repair
owner: pipeline - remove both rows (the documented Remove-RecipeRow / -Replace flow) before or
with this wave's publish. Wave-publish P2/P3 only reconcile the wave's own slugs and will not
catch this.

## Blocked-stage re-derivation (battery fail: recipes-db-dryrun) - CLEAN
The battery invoked update-recipes-db.ps1 -DryRun bare; the script throws on the absent
<run>\specs-ready.txt before printing its item_id source line (reproduced, exit 1). The real
publish path (wave-publish P7/E3) passes -SpecList waves\wave-N.slugs.txt, which bypasses that
file. Re-ran exactly the publish way with the four wave-6 slugs: exit 0,
"item_id source: ingredient-map 0 rows | scaler-bid fallback 0 rows | no id (null) 0 rows",
"skipped already-present: 4". The four existing rows carry 0 null item_ids each and match their
specs exactly, so the null-id bill is clean by construction. normalize-recipe-ids.ps1 was NOT run
(new-era rows). Non-blocking battery defect filed: wave-preaudit should invoke with -SpecList.

## Checklist results
1. MACROS - clean. Hand-recomputed end to end from food-macros-db:
   * ground-beef-cottage-cheese-bowl (550.4 cal sits within 5% of the 550 gate -> 100% recompute):
     batch 7705.1 cal / 584.0 P / 470.8 C / 404.4 F over 14 = 550.4 / 41.7 / 33.6 / 28.9.
     Matches battery and stat (550/42/34/29) exactly.
   * butter-chicken-pasta (protein clears the 40 g floor by only 0.2): batch 8826.25 cal /
     563.13 P over 14 = 630.4 / 40.22. Matches battery exactly. Floor margin is 2.2 g over the
     whole batch - real but thin; the chain holds on the label-accurate DB rows (chicken row
     USDA-corroborated 2026-08-26).
   * Other two verified against battery chains: 471.9/47.3 and 764/48.9.
   BAND (cal 450-800, protein >= 40, carbs any): 550.4 / 471.9 / 630.4 / 764 all in band;
   41.7 / 47.3 / 40.2 / 48.9 all >= 40. PASS on the run-dir band, and on the prose conditions:
   protein cut is boneless skinless chicken breast (3 recipes) / 93-7 ground beef (1); every
   recipe carries a real carb source (sweet potato 1213 g, rice 648 g, pasta 1050 g, rice 1134 g);
   no seafood; 14 servings each.
2. COSTS - clean. Engine rows internally coherent (battery, verified); per-pound spot sweep
   against shelf reality: chicken breast $2.23/lb, 93/7 beef $6.07/lb, cottage cheese $1.82/lb
   (~$2.73/24oz tub), avocado ~$0.60 each, almond butter ~$5.90/16oz (Sam's), pasta $0.97/lb,
   cilantro per-bunch basis. No 3x-cheap survivor, no price-class trap. Three tiers sum sensibly
   on all four (first_run = true + pantry_add verified). 2b: no unpriced lines anywhere, so no
   repair-owner classification needed. almond-butter was minted through the registrar with a full
   already-priced-under-another-name sweep (ruling in mapped-pre) - sound.
3. MAPPING - clean. All lines carry ids or a reasoned refusal (teriyaki "Water" line: bid-less
   optional-note, correct). Form calls checked: ground turmeric-by-teaspoon -> ground (rename not
   form-flip, correct), generic short pasta -> `pasta` (source names no shape, honest), frozen vs
   fresh broccoli split across the two recipes matches each source. One minor inconsistency
   filed non-blocking (butter-chicken dual-quantity, below).
4. PROTEIN + rotation - field correct on all four (beef/chicken/chicken/chicken, heaviest-by-
   grams verified). One instrument defect filed: the derivation tally counts chicken BROTH grams
   as protein-chicken (chicken-rice-and-broccoli tally 4901 = 2381 breast + 2520 broth). Verdict
   unaffected here; latent false-attribution risk for any beef/pork recipe heavy on chicken broth.
5. CARDS - battery rebuilt all four to scratch, structurally identical to the known-good live
   al-pastor card (every smp-* class + anchor, JSON-LD Recipe parses); spot-read of spec prose
   confirms 3-part cost section, source credit, scaler tokens. Clean.
6. VOICE - zero em/en dashes (battery + my spec reads), no swearing, plain warm prose, credit
   lines present, ${{cost_ps}}/{{cal}}/{{protein}} tokenized. Clean.
7. GATES - none weakened. cost_ps EVERYDAY basis verified myself: all four = cost_first_run/14
   to the cent (4.67 / 2.92 / 3.62 / 3.53), exactly what wave-publish E2 enforces against
   v2-perserving. States all say waved/wave-6; ledger stamping is the orchestrator's.

## Non-blocking findings (also in `findings`)
* wave-preaudit battery defect: bare update-recipes-db invocation dies on missing specs-ready.txt
  (owner: pipeline).
* protein-derivation counts chicken-broth grams as chicken (owner: pipeline).
* butter-chicken-pasta protein floor margin 0.2 g/serving; mapper's Ziti Pasta food-DB row
  conflict (existing row stood) is the pressure point - goes with the ~15-pair food-DB duplicate
  backfill review (owner: shared-data).
* butter-chicken-pasta dual-quantity inconsistency: half-and-half resolved by metric parenthetical
  (200 ml -> 202 g) while tomato sauce resolved by US cups (490 g vs source's 400 ml ~ 410 g);
  <= ~6 cal/serving, inside tolerance (owner: mapper).
* Wave-6 publish will re-carry ~13 outside-wave dirty specs via propagate (its design, wave-4
  refusal note) - the ledger should not read as having shipped only 4. Orchestrator must supply a
  correct wave-6.allow-create.txt: the wave-4 refusal came from exactly that mechanism (owner:
  pipeline).

## What publishing needs
1. Dedup-selector re-rules teriyaki-grilled-chicken-and-veggie-rice-bowls against
   teriyaki-chicken-bowl (drop from wave if dupe).
2. Pipeline removes the two rejected-audit rows from recipes-db.json.
3. Scoped re-audit (-Slugs) of whatever remains; the other three slugs carry no recipe-local
   defect and re-audit in seconds.
