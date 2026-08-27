GO
scope: whole-wave

# Wave 4 audit - hunt-2026-08-27-highprotein
Auditor: recipe-batch-auditor (final gate), 2026-08-27
Battery: wave-4.preaudit.json, generated 2026-08-27T16:12:12, 51 checks / 6 slugs / 1 failed.
Slugs: chicken-rice-and-broccoli, butter-chicken-pasta, pioneer-woman-chili,
teriyaki-grilled-chicken-and-veggie-rice-bowls, ground-beef-cottage-cheese-bowl, healthy-hamburger-helper

## Verdict per category

1. MACROS - CLEAN. Battery recompute chains shown and verified against the run's enforced band
   (cal 450-800, protein >= 40, carbs any): 472/47.3, 630/40.2, 680/41.8, 764/48.9, 550/41.7,
   550/44.5. All six inside the band. Independent hand spot-check of ground-beef-cottage-cheese-bowl
   (14 ingredients, grams x generic per-100g values) lands ~551-565 cal / ~40.6 g protein, consistent
   with the battery's 550.4/41.7 given label-vs-generic variance. Thinnest margin: butter-chicken-pasta
   at 40.2 g protein - above the line as computed from the label-accurate DB, but any future food-DB
   row change for its chicken or pasta should trigger a recheck.

2. COSTS - CLEAN, with the basis verified end to end (the battery's own not_checked item).
   Engine rows internally coherent, 0 unpriced lines across all six. Shelf plausibility spot-checked
   on ground-beef-cottage-cheese-bowl: 93/7 beef $28.33 / 4.67 lb = $6.07/lb, sweet potatoes $1.44/lb,
   cottage cheese ~$2.73/24 oz tub, avocados $0.60 ea - all right for Omaha 2026, no 3x-cheap survivors.
   Three tiers sum sensibly on every slug (first_run = true + pantry verified by battery).
   COST BASIS: the four wave-4-native specs carry stat.cost_ps on the batch/14 fallback
   (1.66, 2.00, 3.08, 2.11); the estate convention (sampled 25 live specs: 24 exact, 1 within a cent)
   is EVERYDAY basis = cost_first_run/14. This is the documented NORMAL pre-publish state: I verified
   v2-perserving.json already carries everyday_ps for all six matching cost_first_run/14 to the cent
   (2.92, 3.62, 3.63, 3.53, 4.67, 3.00), and wave-publish E2 (compute-v2-perserving +
   reanchor-machine-fields, then Get-CostBasisProblems hard-verify) re-anchors before anything ships.
   The two wave-3 stragglers (butter-chicken-pasta 3.62, pioneer-woman-chili 3.63) already sit on the
   everyday basis - re-anchored by wave-3's own E2 at 15:13:18 - proving the mechanism on this exact data.
   No unpriced findings, so no 2b classification needed.

3. MAPPING - CLEAN (spot-checked; battery cannot check this). The suspicious-looking almond butter in
   butter-chicken-pasta is genuinely in the source ("2 tablespoons almond butter", skinnyspatula), not a
   substitution; the mapper REFUSED both near rows (dairy butter = wrong food, peanut-butter = different
   nut at a third of the price) and routed a new almond-butter bid through the registrar. Half and half
   is also source-stated. ground-beef-cottage-cheese-bowl bids are all same-concept (cottage-cheese,
   hot-honey, avocados, 93-7-ground-beef, sweet-potatoes). audit-vocab-integrity and
   audit-unbid-ingredients clean n=6. The dry run (below) shows 0 null item_ids.

4. PROTEIN + ROTATION - CLEAN. All six derivations match claimed protein by grams (battery chains
   shown; healthy-hamburger-helper's truncated dispatch line verified in the report file: beef 3268 g,
   sole protein). update-recipes-db -DryRun verified by construction with the P7 invocation (below):
   all 56 ingredient rows take ids from ingredient-map, 0 scaler-bid fallback, 0 null - so the new
   recipes-db rows match the live id convention the rotation and hub Top 5 read.
   normalize-recipe-ids.ps1 was not run and must not be.

5. CARDS - CLEAN. Battery rebuilt all six to scratch and structurally compared against the live
   al-pastor card (every smp-* class + anchor id, step anchors, JSON-LD parses as Recipe). Template
   is byte-for-byte the live convention; no new visual element beyond the standard card, so 375px is
   covered by the live template precedent.

6. VOICE - CLEAN. 0 dash hits on all six specs. Prose read on two specs (cottage-cheese bowl,
   butter-chicken-pasta intro): plain punctuation, warm/no-BS, no swearing, credit lines follow the
   "adapted from <source>" convention. Butter-chicken correctly avoids "authentic".

7. GATES - CLEAN. No gate weakened. Publish path is wave-publish's full P/E chain. Dedup residue
   checked: no competing chili dish live (only "Chili Lime Chicken Burrito", a different dish).
   P8 endpoint + feed probes pass (feed 562 recipes, producible, same URL both sides).

## The battery's one FAIL, resolved

recipes-db-dryrun (rc=1, "never printed its item_id source line") is a BATTERY INVOCATION BUG, not a
data defect. The v3 daemon run layout has no <run>\specs folder, and wave-preaudit calls
update-recipes-db without the -SpecsDir/-SpecList overrides that wave-publish P7 itself uses. I re-ran
with P7's exact invocation (-SpecsDir db\recipes -SpecList <wave slugs> -DryRun):

    live recipes-db slugs: 564
    built + parse-validated new recipes: 4 (skipped already-present: 2)
    item_id source: ingredient-map 56 rows | scaler-bid fallback 0 rows | no id (null) 0 rows
    DRY RUN - would write 568 recipes (564 + 4 new). Nothing written.  EXIT=0

The "skipped already-present: 2" line also settles the duplicate-row question: wave-3's E3 already
spliced butter-chicken-pasta and pioneer-woman-chili into recipes-db at 15:13:18 (backup receipt
recipes-db.backup-20260827-151318.json in the run dir), and E3 will skip, not duplicate, them.

## Non-blocking findings (with owners)

- F1 (tooling, owner: wave-preaudit.ps1): align its recipes-db-dryrun invocation with wave-publish
  P7's (-SpecsDir db\recipes -SpecList <wave slug list>). Until then this check fails on every v3 run.
- F2 (operational, owner: orchestrator/daemon): E2's reanchor will rewrite the FOUR native specs at
  publish time (batch -> everyday cost_ps), after P1b passes. If publish then fails downstream, every
  retry is poisoned at P1b - the exact wave-3 sequence of 15:13:18, now with four specs. On any publish
  failure, request a scoped re-audit (-Slugs) instead of retrying.
- F3 (editorial question for Brad, owner: Brad): "The Pioneer Woman Chili" would be the site's first
  PAID title using a person's brand name directly; nearest live precedent is the hedged
  "Chipotle-Style Steak Burrito". The wave-3 auditor GO'd this slug and the source site publishes under
  the same name, so it does not block, but a name-only retitle (slug unchanged) such as
  "Pioneer Woman-Style Chili" is cheap now and messier after it is live.
- F4 (context): this audit is written AFTER the 15:13:18 spec mtimes, so P1b passes for all six.
  Nothing may rewrite any of the six specs between this audit and publish.

## GO

All six slugs approved. No blocking slugs.
