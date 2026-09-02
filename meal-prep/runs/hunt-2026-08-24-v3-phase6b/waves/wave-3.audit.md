NO-GO
scope: whole-wave (one slug)

# Wave 3 audit - hunt-2026-08-24-v3-phase6b
Auditor: recipe-batch-auditor, 2026-09-02 (file clock 05:31; the dispatch's clock reads about 43 minutes ahead of the file system, ordering is identical on both)
Battery: wave-3.preaudit.json, generated 2026-09-02T05:23:13, 16 checks, 0 failed, WAVE-PREAUDIT-COMPLETE, exit 0.
Battery freshness verified against current bytes: spec mtime 2026-09-02T05:20:40 (unchanged since the battery ran; git diff vs HEAD shows writer_notes[4] and [5] as the ONLY changed lines, as the dispatch claimed), costed.json 2026-09-01T19:15:07, v2-perserving.json 2026-09-01T19:21, all older than the battery's stamp. The rebuilt card in wave-3.preaudit-cards is byte-identical (body and head) to db\built\creamy-roasted-garlic-chicken.*.html of 2026-09-01 20:32.

Slugs: creamy-roasted-garlic-chicken (1 of 1). Batch hunt-2026-08-24-v3-phase6b-w3.

## Verdict per category

1. MACROS: ISSUES FOUND (blocker B1 below). The DB recompute itself is CLEAN and I re-derived it end to end by hand from the ten food-macros-db rows (chicken 3174 g at 130/25/0/3 per 112 g; butter 245 g at 717/0.85/0.06/81 per 100 g; olive oil 47 g at 119/0/0/13.5 per 13.5 g; salt 20 g zero; black pepper 4 g at 6/0/1/0 per 2.3 g; flour 109 g at 110/3/23/0 per 30 g; garlic 158 g at 4/0.2/1/0 per 3 g; milk 1715 g at 120/7.9/11.5/4.8 per 240 g; parmesan 196 g at 110/10/2/7 per 28 g; hot sauce 18 g zero): batch 8103.4 cal / 858.5 P / 234.3 C / 413.8 F over 14 = 578.8 / 61.3 / 16.7 / 29.6, matching the battery and the dispatch to the decimal. Band check against run.json (500 to 650 cal, carb 40 or less, protein 50 or more): 578.8 PASS, 16.7 PASS, 61.3 PASS. Source cross-check: keviniscooking publishes 580 / 57 / 13 / 31 at 4 servings and every line scales at exactly 3.5x, so our per-serving basis agrees with the source within 3 percent on every macro. Protein 61, carbs 17 and fat 30 are the recompute rounded. The calorie stat 583 is NOT the recompute and NOT the intake number: see B1.

2. COSTS: CLEAN. All three tiers re-summed by hand to the cent from db\costed.json: batch 15.61 + 1.61 + 0.47 + 0.03 + 0.14 + 0.10 + 2.15 + 1.25 + 2.37 + 0.08 = 23.81 (1.70 per serving); true shopping = whole packages for chicken 15.61, butter 2.98, garlic 2.32, milk 2.76, parmesan 2.74 plus use-basis pantry 0.82 = 27.23 (1.94); pantry starters 6.86 + 0.94 + 2.96 + 2.15 + 1.56 = 14.47 minus use 0.82 = 13.65; first run 27.23 + 13.65 = 40.88. Every util_cost re-derives from grams / pkg_g x buy price. Every engine basis is board:<id>:walmart and I checked each against the Walmart cell in the live feed (smp-feed.json generated 2026-09-01T08:05:53, week_of 2026-08-31): chicken breast 2.2301/lb, butter 2.976/lb, salt 0.0362/oz x 26, pepper 0.9878/oz x 3, flour 0.4308/lb x 5, garlic 0.58 each, milk 2.76/gallon, parmesan 0.3425/oz x 8, hot sauce 0.13/floz x 12, olive oil 0.2784/floz. All shelf-plausible for Omaha; no cheap-class survivor; nothing 3x under reality. stat.cost_ps 2.92 = v2-perserving everyday_ps 2.92 = cost_first_run 40.88 / 14 (whole-package basis per the cost-basis map); head.costPerServing 2.92 agrees. 0 unpriced lines, so no repair-owner classification is owed.

3. MAPPING: CLEAN. Ten lines, ten bids, all resolve and all carried; battery vocab-integrity and unbid-ingredients clean, 0 null item_ids in the recipes-db dry run. Tabasco to generic hot sauce is brand-to-generic same-concept at exact ratio (ruled in wave 2, QA concurs). Garlic head to clove basis is the same fresh food. Parmesan grams use the estate's grated 1/4 cup = 28 g label row (tub, not wedge, consistent with the shop_smart bullet). Flour is the wheat AP row. Milk resolves to the store-brand 2 percent row per Brad's 2026-08-27 ruling, and the display now reads "Milk (store brand)", so the wave-2 C2 basis mismatch is closed.

4. PROTEIN + rotation: CLEAN. chicken by construction (3174 g chicken, 0 turkey / beef / pork); update-recipes-db -DryRun rc 0 with item_ids on every row; normalize-recipe-ids correctly not run. The slug is not yet in meal-prep\recipes-db.json, so no set moves until publish; v2-perserving protein_g 61 and protein_rank 17 are consistent with the stat.

5. CARDS: CLEAN. Structural compare against the live al-pastor reference passed in the battery and the rebuilt bytes equal db\built. Credit link to keviniscooking.com present with rel=noopener; cost section fetches https://feed.thriftycrew.com/smp-feed.json (the producible feed the guard validates); print references and scaler present; JSON-LD parses as Recipe with the two to-taste lines now carrying no grams. No unrendered {{token}} in the card. head.image is empty, which matches the live wave-1 sibling stuffed-chicken-breast (build fills it). 375px: the card is the unchanged template that is live on 580 recipes and adds no new visual element; the live-page DOM check at 375px is owed by the post-publish review exactly as wave 1's ledger records it.

6. VOICE + copy: CLEAN. Zero em or en dash bytes in the spec and in the card. No swearing. Warm, no-BS register throughout. Both wave-2 blockers verified repaired on disk: shop_smart[1] now argues the gallon the engine priced ("the gallon is still the play even though a half gallon would just about cover it"), and the four to-taste strings carry no grams. No fabricated arithmetic in the prose: every number in the card is a rendered token or a cost_lines literal that matches the engine.

7. GATES: CLEAN. Source-QA re-passed 2026-08-31T16:13:42 on both anchors; I re-fetched the live source page and every ingredient scales at exactly 3.5x (7 lb chicken, 17.5 tbsp butter, 3.5 tbsp oil, 14 tbsp flour, 3.5 heads garlic, 7 cups milk, 1.75 cups parmesan, 3.5 tsp hot sauce) and the steps are the source's steps in the source's order; the dropped Italian seasoning and parsley garnish are in forbidden_prose_terms and absent from the prose. Battery 16/16. wave-publish P2 (audit stamp on w3) and P3 (state waved, wave 3) will hold once a GO exists. No gate weakened.

8. IDENTITY + one story: ISSUES FOUND (non-blocking C1). No live near-duplicate (chicken-40-cloves-garlic is a braise, parmesan-garlic-sheet-pan has potatoes). Manifest wave-3.json, state file (waved, wave 3, updated 2026-09-02T05:22:14) and ledger row w3 (opened 05:22:14, slug listed) agree. The ledger row w2 does not: see C1.

## BLOCKING issues

### B1 (recipe-local): stat.cal 583 is a restat over the pre-repair 140 g salt / 28 g black pepper, and writer_notes[5] misstates where it came from
File: meal-prep\db\recipes\creamy-roasted-garlic-chicken.json, stat.cal and writer_notes[5].
Recipe-local. Owner: orchestrator (machine restat) plus the writer of today's note.

What the number is. The dispatch and today's writer_notes[5] both say the 583 "is the intake number". It is not: intake\creamy-roasted-garlic-chicken.json macros_per_serving reads 563 / 63.9 / 14.7 / 27.1. The 583 first appears in commit 8db19121 (2026-08-27, the Milk restat), when ingredients_grams still carried 140 g salt and 28 g pepper. Reproduce it: the current batch minus today's pepper (10.4 cal) plus 28 g pepper (12.17 x 6 = 73.0 cal) is 8166.0 cal / 14 = 583.3, and carbs 234.3 - 1.74 + 12.17 = 244.7 / 14 = 17.5. That is the published 583 / 61 / 17 / 30 exactly. Commit d9881dcc (2026-08-31) then cut the grams to 20 g and 4 g and did not restat. So the card's calorie figure is the recompute over grams the estate itself ruled indefensible and removed, left standing only because 4.2 cal sits inside the build gate's 5-cal proof tolerance.

Why it blocks rather than passes on tolerance. The 5-cal ruler (build-v2-spec.ps1:335, spec-guards.ps1:209, and -Restat's proof) is the tolerance for PROVING a tool understands a spec before it writes; the estate's own precedent on 2026-08-27 was to accept the proof and then WRITE the fresh number on 48 of 49 specs, not to leave a known drift on a card. Here the drift has a known cause, a known fix and a one-command tool, and the wave is pre-publish. A card that says 583 while the DB says 579 for a reason we can name is a number we would have to defend, and we cannot.

Verified fix (dry run already passes, rc 0, nothing written):
  meal-prep\pipeline\rebase-spec-ingredient.ps1 -Slug creamy-roasted-garlic-chicken -From 'Milk' -Restat -PriorFoodDb meal-prep\food-macros-db.json -Apply
  (the food DB did not change, so the prior snapshot IS the current file; the dry run reports "583/61/17/30 -> 579/61/17/30 (cal -4)", protein / carbs / fat unchanged)
Then rewrite writer_notes[5] so it states the truth: the stat was restatted on 2026-09-02 to 579 over the repaired 20 g / 4 g grams; the intake number was 563 on the Fairlife basis; the earlier 583 was the 2026-08-27 restat over the pre-repair seasoning grams. Do not leave "the calorie figure is the intake number" or "the locked stat stands" in the file.
Then rebuild the card (intro, portion and head.description are all {{cal}} tokens, so nothing else in the prose moves; there is no literal 583 anywhere in the spec outside stat and that note), run the battery with -Slugs creamy-roasted-garlic-chicken, and re-dispatch a scoped audit. Cost fields do not move, so no recost or reanchor is needed.

## Non-blocking findings (recorded, owners named)

C1 (orchestration). Ledger row hunt-2026-08-24-v3-phase6b-w2 is still OPEN and still lists creamy-roasted-garlic-chicken, while waves\wave-2.json was reconciled to no slugs on 2026-09-02T05:22:10 and the state file says wave 3. batch-ledger.ps1 -Verify flags it (OPEN+STALE, 202h). wave-publish does not gate on -Verify (P2 reads only the w3 row), so this does not block, but the slug currently sits in two open batches and the ledger will report it forever. Fix: batch-ledger.ps1 -Abandon -Batch hunt-2026-08-24-v3-phase6b-w2 -Detail 'wave-2 NO-GO 2026-08-24; slug revived and re-waved as w3 on 2026-09-02'. No spec touched, so it needs no re-audit. (Same -Verify run also reports hunt-2026-08-27-highprotein-w9 as LIVE-UNREVIEWED; pre-existing, not this run.)

C2 (shared, pre-existing estate convention). The display parenthetical is the food-DB label brand, not the priced product: "Boneless Skinless Chicken Breast (Member's Mark)" is priced at Walmart $2.23/lb, and "Hot Sauce (Frank's RedHot)" is priced off the generic hot-sauce cell at $1.56 a bottle (Frank's does not sell for that). Macros are label-accurate and the reader is told to buy the cheapest, so the numbers are right; the brand tag can still read as a product claim. This is the same class the Milk C2 in wave 2 belonged to and it was fixed for milk only. Not this wave's defect; recorded for the estate.

C3 (shared, pre-existing). The pantry-starter tier prices olive oil at $6.86 for a 25.5 floz bottle (0.269/floz) while the board's Walmart cell is 0.2784/floz ($7.10 at that size). Util cost uses the board and is right; only the empty-pantry add is 24 cents light. Registry pack price vs board price, an estate mechanism.

C4 (shared, bookkeeping). grocery\out\recipe-board-everyday.json carries week_of 2026-07-06 with built_at 2026-08-29; the feed built from it says week_of 2026-08-31 and the prices agree. A written date, not a measured one. Owner: board pipeline.

C5 (observation). shop_smart[0] says seven pounds of breast is "where nearly all the money" sits; it is 66 percent of the batch cost (83 percent of the protein). Qualitative and defensible, left alone.

## GO / NO-GO

NO-GO. Blocks: creamy-roasted-garlic-chicken on B1 only (stat.cal must be restatted to 579 over the repaired grams, and writer_notes[5] must stop claiming the 583 is the intake number). Recipe-local, one command plus one note edit plus a card rebuild; scoped re-audit after repair. Nothing shared blocks.
