GO
scope: pioneer-woman-chili

# Wave 3 re-audit - hunt-2026-08-27-highprotein (butter-chicken-pasta, pioneer-woman-chili)
Scoped re-audit 2026-08-27 after the recipe-local repair to pioneer-woman-chili
(prose.cost_closing_html). Audited against wave-3.preaudit.json generated
2026-08-27T15:09:46, which POSTDATES the repair (chili spec mtime 15:09:28); current
on-disk mtimes verified identical to the report's (chili 15:09:28, butter-chicken
14:56:00, costed.json 14:56:05), so the report certifies the bytes that will publish.

## VERDICT: GO

## THE BLOCKER FROM THE PRIOR NO-GO, VERIFIED REPAIRED
- Spec field cost_closing_html now reads `${{cost_ps}}` (double braces), the builder's
  recognized token form.
- Rebuilt card (wave-3.preaudit-cards\pioneer-woman-chili\pioneer-woman-chili.body.html
  line 615) renders it as `<span data-tc-live-price>current release price loading</span>` -
  the same live-price mechanism butter-chicken-pasta uses; the card carries the JS that
  fills every [data-tc-live-price] span (line 267). No `cost_ps` string anywhere in the
  card. The broken template text is gone.
- Prose numbers in the patched field ("680 calories and 42 grams of protein") match the
  battery's post-repair macro recompute (679.9 cal, 41.8 g protein) and the stat block
  (680/42). Voice-sweep: 0 dash hits on the new bytes.
- Nothing else moved: every non-prose number on post-repair bytes is identical to the
  pre-repair audit's record - macros 679.9/41.8/42.2/38 at 14 servings, costs
  37.45/42.05/2.68/50.81 with 16 lines 0 unpriced, protein derived beef 2117 g,
  card structurally identical to the live reference. (The spec is untracked in git, so
  the delta could not be diffed; but since the whole battery re-ran on current bytes,
  the certification does not depend on the repair's claim.)
- butter-chicken-pasta untouched (mtime 14:56:00 unchanged); prior whole-wave audit's
  clean ruling stands.

## THE BATTERY'S ONE FAIL, RE-CLOSED BY HAND ON CURRENT BYTES
recipes-db-dryrun again failed as a BLOCKED look (rc=1, could-not-read) - the known probe
invocation defect (pre-daemon layout assumptions), not a data finding. Re-ran myself on
post-repair bytes with -SpecsDir meal-prep\db\recipes -SpecList <both slugs> -DryRun:

    built + parse-validated new recipes: 2 (skipped already-present: 0)
    item_id source: ingredient-map 32 rows | scaler-bid fallback 4 rows | no id (null) 0 rows
    fallbacks: Masa Harina->masa-harina, Canned Pinto Beans->canned-pinto-beans,
               Lime->limes, Almond Butter->almond-butter
    exit=0

Zero null item_ids; the 4 fallbacks are the same documented registrar-minted /
recipe-only class as the prior audit found. CLEAN.

## BAND (authority: cal 450-800, carbs any, protein >= 40)
- pioneer-woman-chili: 679.9 cal, 41.8 g protein - inside. Real carb source (pinto
  beans + masa), beef protein, 14 servings, no seafood.
- butter-chicken-pasta: 630.4 cal, 40.2 g protein - inside, 0.2 g protein margin over
  the floor; the prior audit's watch-flag on any future recost stands.

## RESIDUE RULED ON THIS PASS
- Nested `<p><p>...</p></p>` around the closing paragraph in BOTH wave-3 rebuilt cards
  (butter-chicken 584/619, chili 615) but not in the live reference card. Predates the
  repair (butter-chicken has it and was ruled clean pre-repair), browsers auto-close it
  (renders as an empty paragraph plus the real one; no reader-visible breakage). NOT a
  blocker; builder double-wraps *_html fields that already carry their own <p>. Owner:
  pipeline, hygiene queue.
- Chili cost-reconcile shows spec newer than costed.json (15:09:28 > 14:56:05):
  explained by the prose-only repair; every spec cost field still matches its engine
  row to the cent, and wave-publish E2 re-anchors stat.cost_ps at publish regardless.

## STANDING NON-BLOCKING ITEMS (unchanged from the prior audit, still open)
- Chili "optional" copy vs macros (~3 g/serving of protein rides on cheddar the copy
  calls optional). Owner: writer, next repair pass.
- Food-DB duplicate pair Lime/Limes and the Ziti Pasta row disagreement - queue with
  the ~15-pair duplicate backfill. Owner: shared-data.
- Title question for Brad, on the record: "The Pioneer Woman Chili" is the first
  live-trademark title in a paid recipe (credits thecozycook.com, not Ree Drummond).
  Catalog precedent tolerates named-dish titles; not blocking, but Brad should see it.
- wave-preaudit.ps1's recipes-db-dryrun probe needs the daemon-era SpecsDir/SpecList
  invocation - it has now cost two audit passes a hand re-run. Owner: pipeline.
