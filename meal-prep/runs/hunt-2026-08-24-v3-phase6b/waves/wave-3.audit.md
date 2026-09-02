GO
scope: scoped re-audit of creamy-roasted-garlic-chicken after the B1 repair (whole wave is this one slug)

# Wave 3 audit - hunt-2026-08-24-v3-phase6b
Auditor: recipe-batch-auditor, 2026-09-02 (file clock; the dispatch clock reads about 43 minutes ahead, ordering identical on both)
Battery: wave-3.preaudit.json, generated 2026-09-02T05:38:12, scope "scoped: creamy-roasted-garlic-chicken", 16 checks, 0 failed, WAVE-PREAUDIT-COMPLETE, exit 0.
Freshness verified against current bytes: spec mtime 2026-09-02T05:35:42, db\built card 05:37:23, battery 05:38:12, this file newer than all three. costed.json 2026-09-01T19:15:07 and v2-perserving.json 2026-09-01T19:21 unchanged since the first pass. HEAD is d59c837b (05:34:24); the only dirty file under db\recipes is this spec, and its diff vs HEAD is exactly two lines: stat.cal 583 -> 579 and writer_notes[5].

Slugs: creamy-roasted-garlic-chicken (1 of 1). Batch hunt-2026-08-24-v3-phase6b-w3.

## First-pass NO-GO (05:32) and its repair
B1 (recipe-local) blocked on stat.cal 583, which was the 2026-08-27 Milk restat computed over the pre-repair 140 g salt / 28 g pepper fallback grams, and on a writer_notes[5] that called it the intake number. Repair verified:
- rebase-spec-ingredient.ps1 -Restat applied: stat is now 579 / 61 / 17 / 30, which is the DB recompute 578.8 / 61.3 / 16.7 / 29.6 rounded on all four. Protein, carbs, fat and cost_ps 2.92 did not move.
- writer_notes[5] rewritten. It now records the true history (intake 563 on the Fairlife row; 583 from the 08-27 restat over the 140/28 grams, reproducible at those weights; the 08-31 to-taste repair cut them to 20/4 without restatting; restatted 2026-09-02). "is the intake number" and "the locked stat stands" are gone; 0 em or en dashes in the spec. writer_notes[4] and [6] untouched.
- Card rebuilt after the spec under the renderer that changed in d59c837b (shop_smart shape guard). The rebuilt card in wave-3.preaudit-cards is byte-identical to db\built. It renders "about 579 calories" in the intro and "near 579 calories with 61 grams of protein" in the portion block, contains no 583, no unrendered {{token}}, 0 dash bytes, the credit link to keviniscooking.com, the producible feed URL https://feed.thriftycrew.com/smp-feed.json, print and scaler hooks, five Shop Smart bullets rendered as separate items, and 108 smp- references, the same count as the live al-pastor reference. JSON-LD parses as Recipe per the battery.
- audit-store-integrity is back to hard=0 (the interim CARD-STALE was the daemon's own stale build product and is gone).

## Verdict per category (first-pass findings stand unless noted)
1. MACROS: CLEAN. Hand recompute from the ten food-macros-db rows on the first pass: batch 8103.4 cal / 858.5 P / 234.3 C / 413.8 F over 14 = 578.8 / 61.3 / 16.7 / 29.6; stat now equals it rounded. Band (500 to 650 cal, carb 40 or less, protein 50 or more): PASS on all three. Source publishes 580 / 57 / 13 / 31 at exact 3.5x scale; agreement within 3 percent on every macro.
2. COSTS: CLEAN. Batch 23.81 (1.70), true 27.23 (1.94), pantry add 13.65, first run 40.88, all re-summed to the cent from the engine row; every Walmart basis checked against the live feed cell; stat.cost_ps 2.92 = everyday_ps = first run / 14; head.costPerServing 2.92. 0 unpriced lines.
3. MAPPING: CLEAN. Ten lines, ten bids, all carried, 0 null item_ids; Tabasco to generic hot sauce same-concept at exact ratio; parmesan on the grated label row; milk on the store-brand 2 percent row per Brad's 2026-08-27 ruling with the display reading "(store brand)".
4. PROTEIN + rotation: CLEAN. chicken by construction (3174 g chicken, 0 turkey / beef / pork); update-recipes-db -DryRun rc 0; normalize-recipe-ids correctly not run; slug not yet in recipes-db.json.
5. CARDS: CLEAN (see repair block above). head.image empty matches the live wave-1 sibling. 375px: unchanged template live on 580 recipes, no new visual element; the live-page DOM check at 375px is owed by the post-publish review as wave 1's ledger records it.
6. VOICE + copy: CLEAN. 0 dashes in spec and card, no swearing, warm no-BS register, both wave-2 repairs verified on disk, no literal number in the prose that is not a rendered token or an engine-matching cost line.
7. GATES: CLEAN. Source-QA re-passed 2026-08-31T16:13:42 on both anchors and I re-fetched the live source on the first pass (every line scales at exactly 3.5x, steps in source order, dropped Italian seasoning and parsley in forbidden_prose_terms). Battery 16/16. No gate weakened; a cost re-anchor is not needed since no cost field moved.
8. IDENTITY + one story: CLEAN for this wave. Manifest wave-3.json, state (waved, wave 3) and ledger row w3 agree. Ledger row w2 remains open (C1) and does not gate publish.

## BLOCKING issues
None.

## Non-blocking findings (recorded, owners named)
C1 (orchestration). Ledger row hunt-2026-08-24-v3-phase6b-w2 is still OPEN listing this slug while wave-2.json is reconciled to none; batch-ledger -Verify reports it OPEN+STALE. batch-ledger -Abandon refuses while the recipe is built and unpublished, so the order is publish first, then abandon w2. Not a publish gate (P2 reads only the w3 row). The daemon has undertaken to abandon w2 after the wave ships.
C2 (shared, pre-existing). Display brand parentheticals are the food-DB label brand, not the priced product ("Member's Mark" chicken priced at Walmart; "Frank's RedHot" priced off the generic hot-sauce cell at $1.56 a bottle). Same class as wave 2's milk finding, fixed for milk only. Estate convention, not this wave's defect.
C3 (shared, pre-existing). Olive-oil pantry starter $6.86 for 25.5 floz vs board 0.2784/floz ($7.10 at that size); util cost is right, empty-pantry add is 24 cents light. Registry pack price vs board price.
C4 (shared, bookkeeping). grocery\out\recipe-board-everyday.json week_of 2026-07-06 with built_at 2026-08-29; feed built from it says week_of 2026-08-31 and prices agree. A written date, not a measured one.
C5 (observation). shop_smart[0] "nearly all the money" is 66 percent of batch cost (83 percent of protein). Qualitative, left alone.

## GO / NO-GO
GO. creamy-roasted-garlic-chicken publishes as wave 3. Nothing blocks; C1 is post-publish bookkeeping and C2 through C5 are recorded for the estate.
