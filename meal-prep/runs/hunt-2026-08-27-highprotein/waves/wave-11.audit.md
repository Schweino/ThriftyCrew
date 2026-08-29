NO-GO
scope: honey-bbq-chicken-mac-and-cheese

# Wave 11 RE-audit - hunt-2026-08-27-highprotein - 2026-08-28
Auditor: recipe-batch gate. Battery report: wave-11.preaudit.json (generated 2026-08-28T13:06:29,
16 checks, 2 failed). Spec mtime at audit: 2026-08-28T13:06:10. One slug: honey-bbq-chicken-mac-and-cheese.
Prior audit: NO-GO at 12:55 with three blockers (two shared-data, one recipe-local).

## VERDICT: NO-GO - the repair cycle closed 1 of the prior 3 blockers. Both SHARED-DATA blockers stand.

The dispatch premise ("the blocker was recipe-local, so nothing outside the repaired slugs moved") is
wrong: the prior audit named THREE blockers and only the recipe-local one was repaired. Verified
directly, not from the battery alone.

### BLOCKER 1 (shared-data, owner: writer) - STILL OPEN: audit-spec-contradictions exits 1
Re-ran the gate myself at audit time: RC=1, PHANTOM 3 vs baseline 0, the SAME three specs, all three
mtimes still 2026-08-28T10:57:26 - untouched since they were introduced:
  - meal-prep\db\recipes\beef-rendang-rice-bowls.json - step says 'coconut oil', no such ingredient line
  - meal-prep\db\recipes\mediterranean-chicken-w-marinade.json - step says 'cooking spray', no such line
  - meal-prep\db\recipes\blackened-chicken-with-mango-salsa.json - step says 'salsa'; ingredients are the
    salsa COMPONENTS - likely a detector literal-match; the repair cycle must RULE it (fix prose or teach
    the detector), never suppress or re-baseline it.
None are wave-11 slugs, but the gate is estate-wide and wave-publish runs it. Not weakened to pass a wave.

### BLOCKER 2 (shared-data, owner: pricer) - STILL OPEN: cheddar-cheese is priced by MOZZARELLA
Verified again on disk this audit: grocery\out\recipe-board-everyday.json id cheddar-cheese still crowned
by Sam's Club "Member's Mark Part-Skim Shredded Mozzarella Cheese 5 lbs." at $0.1519/oz; 4 of 6 store rows
are not cheddar (Sam's mozzarella, Aldi Happy Farms mozzarella, Walmart Fiesta Blend, Family Fare part-skim
mozzarella). grocery\out\smp-feed.json cheddar-cheese cheapest=$0.1521 Sam's, url /ip/13857173387 - same
pollution. The wave-11 spec still prices "Reduced Fat Cheddar Cheese" 525 g off that crown: 18.52 oz x
$0.1521 = $2.82 (spec line unchanged), "Buy 3 8oz blocks: $3.65" is not a shelf-real cheddar price.
costed.json mtime 12:38:20 - it predates even the PRIOR audit; no recost ever ran. At cheapest true
cheddar ($0.2188/oz Baker's): util ~$4.05, batch ~$24.40, per-serving ~$1.75, true ~$2.43 - every card
cost number moves. NOT a mapping rejection: Reduced Fat Cheddar Cheese -> cheddar-cheese is same-concept
and correct; the board row CONTENT is misfiled. Repair: purge/refile non-cheddar rows, re-crown, recost
this slug, sync-recipesdb-cost before propagate, sweep every other recipe pricing cheddar-cheese, then
scoped re-audit: wave-preaudit.ps1 -RunDir <run> -Wave 11 -Slugs honey-bbq-chicken-mac-and-cheese.

### Prior BLOCKER 3 (recipe-local, owner: writer) - VERIFIED FIXED
Spec repaired at 13:06:10: ingredients_display and head.recipeIngredient now read "Cooking Spray (PAM):
as needed for the pan (10 g)" - single gram token. Rebuilt card in wave-11.preaudit-cards grepped for
"(10 g) (10 g)": 0 hits. Battery card-rebuild structural compare vs the live al-pastor card passes.
Closed.

## Battery failure "recipes-db-dryrun": HARNESS defect again, re-derived clean by hand
Same Start-Job relative -RunDir defect as the prior audit diagnosed (owner: pipeline, still unfixed -
fix so waves 12+ read it). Hand re-run with absolute paths: RC=0, 1 recipe built + parse-validated,
item_id source: ingredient-map 15 | scaler-bid fallback 2 (Reduced Fat Cheddar Cheese -> cheddar-cheese,
Cooking Spray -> cooking-spray) | null 0. Protein-derivation-by-construction CLEAN. Non-blocking.

## Checks re-derived or judged clean this pass
- BAND (run-dir band is the authority): cal 751 in [450,800] PASS; protein 50 >= 40 PASS; carbs 85
  unrestricted; real carb source = pasta PASS; main protein boneless skinless chicken breast PASS;
  scales to 14 servings PASS; no seafood PASS.
- MACROS: battery recompute 751.1/50.5/84.7/24.4 vs stat 751/50/85/24, all in tolerance; numbers
  identical to the prior audit's hand-verified chain (chicken 1400 g dominates protein). Clean.
- PROTEIN FIELD: chicken by construction (tally 1400 g chicken, 0 others) + dry-run derivation clean.
  Rotation/Top-5 safe. normalize-recipe-ids NOT run (new-era rows), per standing correction.
- COST TIERS: 23.17 batch < 32.42 true < 43.51 first-run, coherent (43.51 = 32.42 + 11.09 pantry) -
  but the cheddar line inside them is Blocker 2, so the tiers are coherent, not correct.
- STATE STORY: state waved 12:54:33 = wave manifest created 12:54:33; one story. The spec file is
  untracked in git, normal pre-publish. Clean.
- Shared gates green at battery time: store-integrity (hard=0), vocab-integrity, unbid-ingredients,
  cost-plausibility, cost-line-coverage, p8 endpoint + feed liveness (565 recipes).

## Non-blocking notes (carried from prior audit, still true)
- MILK: engine basis vs on-disk board vintage difference; wave-publish E2 re-anchors at publish.
  Every store row under milk has empty item/size strings - pricer data-quality sweep item.
- PASTA PROSE: "Ziti Pasta ... (about 10 cups elbow macaroni)" states two noodle identities; drop at
  next writer touch, not blocking a mac-and-cheese.
- PROCESS: the re-dispatch reason claimed the blocker was recipe-local; the repair cycle must read the
  FULL blocker list of the audit it is repairing, or waves bounce twice for nothing.

## Repair routing summary
  writer   - 3 phantom specs (or an explicit detector ruling for blackened-chicken 'salsa')
  pricer   - cheddar-cheese board+feed refile + re-crown + recost + sync-recipesdb-cost + propagate +
             cross-recipe cheddar sweep; milk empty item/size rows
  pipeline - wave-preaudit Start-Job relative-path defect (absolute-ize RunDir before the job)
After BOTH shared repairs land: green audit-spec-contradictions + scoped re-audit
(-Slugs honey-bbq-chicken-mac-and-cheese), then this wave can come back for GO.
