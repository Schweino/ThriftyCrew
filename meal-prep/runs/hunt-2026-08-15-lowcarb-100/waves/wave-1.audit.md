NO-GO
scope: whole-wave

# Wave 1 RE-audit - hunt-2026-08-15-lowcarb-100 (re-audited 2026-08-16, after the claimed repair)

Auditor: batch audit gate, second audit of this wave. Requested scope: whole-wave, on the premise that
"the fix moved shared data (map entry / DB row / cost basis), so every recipe in the wave has new
numbers." Every category was re-verified against current bytes.

## The finding that decides this audit

THE REPAIR NEVER LANDED. The premise of this re-audit is false: no repair artifact for wave 1 exists
anywhere in the repo. Evidence, all from current bytes:

- db\ingredients.json (the cost engine's wiring file, fix step 1 of the first audit) is untouched:
  mtime 2026-08-15 12:29, before the run even started. All 18 unwired item names are still absent.
- The 10 wave-1 specs in db\recipes are untouched since before the first audit (newest 05:44; the
  first audit was written 06:19). The short-ribs spec still claims stat.cost_ps "0.30" and its own
  writer_notes still carry the "BLOCKER FLAG for the repair pass".
- db\costed.json rows for the wave are numerically identical to the first audit: stroganoff $2.02
  (5 unpriced lines), tuscan $1.39 (1), keto-broccoli $1.79 (1), cauliflower-mac $0.31 (4 unpriced,
  3 of 7 priced), short-ribs $0.30 (main protein at zero), chimichurri $2.89 (3), fricassee $1.43 (5),
  hatch $2.08 (3). costed.json's newer mtime (06:28) comes from targeted recosts of WAVE-2 slugs;
  those runs also overwrote db\cost-flags.txt, which is why it looks quiet.
- A full sweep of every file modified after the 06:19 first audit shows only concurrent wave-2 lane
  traffic (other slugs' mapped/intake/state/spec/qa files) and grocery board machinery. Nothing
  touches wave-1 data. No board (comparison-2026-08-15, recipe-board) carries a cell for the blocking
  commodities; the registrar ruling on the boneless-beef-short-ribs proposal is still pending.
- The 8 blocking slugs' QA files all predate the first audit. Nothing was re-QA'd.
- batch-ledger: hunt-2026-08-15-lowcarb-100-w1 still owes audit onward; the short-ribs state history
  ends at "waved 06:07:43" with no repair event.

Mechanical proof, re-run in full: all 10 cards rebuilt from current bytes through
pipeline\build-card2.ps1. The SAME 8 of 10 hard-fail with the same refusal, first failing item named:

| Slug | Result |
|---|---|
| low-carb-ground-beef-stroganoff-skillet | FAIL: no costed line for 'Brandy' |
| creamy-tuscan-chicken-skillet | FAIL: no costed line for 'Sun-Dried Tomatoes (Oil-Packed)' |
| turkey-zucchini-noodle-casserole | BUILDS |
| keto-turkey-broccoli-cheddar-casserole | FAIL: no costed line for 'Broccoli' |
| baked-cauliflower-mac-smoked-sausage | FAIL: no costed line for 'Cauliflower' |
| slow-cooker-boneless-beef-short-ribs | FAIL: no costed line for 'Boneless Beef Short Ribs' |
| chimichurri-steak-sheet-pan | FAIL: no costed line for 'Broccolini' |
| french-chicken-fricassee | FAIL: no costed line for 'Portobello Mushrooms' |
| chicken-piccata-skillet | BUILDS |
| hatch-green-chile-chicken-casserole | FAIL: no costed line for 'Pepper Jack Cheese' |

## Verdict summary

| Category | Verdict |
|---|---|
| 1. Macros vs food DB | CLEAN - all 10 recomputed against the CURRENT food-macros-db (which did move at 06:20/06:27 for wave-2 rows); every recompute matches the spec stat within rounding (max drift 0.5 cal). The shared-DB movement did not touch any row wave 1 depends on. |
| 2. Costs | ISSUES FOUND - BLOCKING, unchanged from audit 1. Eight recipes still bake zero-priced non-optional lines into their published cost claims, short-ribs still 21x understated against the pricer's own $11.99/lb evidence. |
| 3. Mapping / item_ids | CLEAN (carried) - wave-1 mapped files untouched since audit 1; ingredient-map gained only wave-2 entries; the derivation still yields the same 23 nulls, i.e. no wiring arrived via the map either. |
| 4. Protein + rotation | CLEAN on labels (specs unchanged; update-recipes-db -DryRun re-run: 10 rows build, 80 map ids, 0 fallbacks, 23 nulls, matching audit 1). Rotation exposure stands: $0.30-0.31 false costs would top the Top 5 cheapest surface. |
| 5. Cards | ISSUES FOUND - BLOCKING - 8 of 10 cannot render (proof above). The 2 that build are the same 2 as audit 1. |
| 6. Voice + copy | CLEAN (carried) - all 10 spec bytes identical to what audit 1 swept. |
| 7. Gates | INTACT - wave-publish.ps1 unchanged, ledger stamps in order, no gate weakened. This NO-GO is the gate doing its job a second time. |

## What blocks, exactly (unchanged from audit 1 - none of its fix steps were executed)

1. Wire the 18 item names into db\ingredients.json. The evidence is already on file in
   grocery\ingredient-queue.json (brandy: E&J VS 750 ml $12.49 Baker's; boneless beef short ribs:
   $11.99/lb Baker's; dry white wine: $10.99/750 ml Baker's; fresh oregano: $2.49/0.5 oz Baker's, all
   CARRIED). Names: Brandy, Beef Base, Cream Cheese, Sour Cream, Fresh Parsley, Boneless Beef Short
   Ribs, Cauliflower, Smoked Sausage, Monterey Jack Cheese, Broccoli, Broccolini, Fresh Oregano,
   Sun-Dried Tomatoes (Oil-Packed), Portobello Mushrooms, Dry White Wine, Egg Yolk, Pepper Jack
   Cheese, Yellow Bell Pepper.
2. Registrar ruling on the boneless-beef-short-ribs commodity proposal
   (mapped\slow-cooker-boneless-beef-short-ribs.json, new_commodity_proposals). Still pending.
3. Re-run engine\cost-recipes.ps1 for the 8 slugs, re-render spec cost blocks
   (pipeline\recost-spec-cost-block.ps1), confirm the three tiers sum sensibly.
4. Re-QA the 8 (every prose cost literal changes), then request a fresh audit.
5. Budget re-review of slow-cooker-boneless-beef-short-ribs with its honest ~$6.30/serving number
   (run condition is "budget meal-prep dinner"). Retire or accept deliberately - never adjust it.
6. The defect class is still open and ALREADY BITING WAVE 2: db\cost-flags.txt (written 06:28 by a
   wave-2 recost) shows "Spinach Provolone Stuffed Flank Steak Rolls :: Cream Cheese :: NO PRICE
   BASIS" - the same unwired Cream Cheese silently zero-pricing a new recipe. The write-time refusal
   fixture (audit 1, fix step 6) is needed before more specs bake floors in.

## Freshness note for wave-publish P1b

This file is newer than every wave-1 spec (newest spec 05:44, this audit later on 2026-08-16), so a
GO here would satisfy the freshness gate mechanically. That is exactly why it must read NO-GO: the
bytes it certifies are the same broken bytes audit 1 refused.

NO-GO. Nothing in fix steps 1-6 of the first audit has happened. The wave returns when the wiring
lands in db\ingredients.json, the 8 are recosted and their specs re-rendered and re-QA'd, the
short-rib recipe survives an honest budget review, and a fresh audit reads genuinely new bytes.
