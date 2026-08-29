GO
scope: mediterranean-chicken-w-marinade (scoped re-audit of the 92a5ccff repair; supersedes the 2026-08-29 11:00 NO-GO)

# Wave 1 RE-audit - hunt-2026-08-27-ten (mediterranean-chicken-w-marinade), 2026-08-29 (afternoon)

Battery: waves\wave-1.preaudit.json generated 2026-08-29T11:27:31, scoped, 16 checks, 0 failed,
exit 0 with WAVE-PREAUDIT-COMPLETE (27.7s). The report postdates the fix commit (10:57:51) and the
spec/costed mtimes it certifies (10:55:31); nothing in the chain moved after it was written.

## The blocker's repair, verified in git - not in the working tree

1. THE COMMIT IS REAL. `git log --all -S "6oz drained-weight can" -- meal-prep/db/ingredients.json`
   now returns exactly one hit: 92a5ccff, which carries ingredients.json, costed.json AND the spec
   in one commit - the shape the predecessor's fix prescribed. 92a5ccff is an ancestor of HEAD;
   `git diff 92a5ccff..HEAD` on all three files is empty and `git status` shows them clean, so the
   committed bytes ARE today's bytes. The failure mode that ate the 08-27 repair (source fixed only
   in the working tree, stripped by the 07:00 bot's autoStash) cannot recur for this label.
2. THE ROW: ingredients.json Black Olives, bid black-olives, buy_pkg_label "6oz drained-weight can",
   buy_pkg_g 170. Pluralizable noun last.
3. EVERY SURFACE:
   - Spec cost line (line 68): "Black Olives, about 1 1/2 lb drained black olives (three 14.5 oz
     cans): ~$8.43. <strong>Buy 5 6oz drained-weight cans: $9.84.</strong>" - correct.
   - Rebuilt card (battery scratch dir wave-1.preaudit-cards\mediterranean-chicken-w-marinade):
     body embeds "pkg_l":"6oz drained-weight can" in its data payload; head clean. Zero "draineds"
     in body, head, spec, or anywhere under meal-prep\db (repo grep).
   - The card surface is additionally safe BY CONSTRUCTION: its client-side pkgLabel() renders
     count + ' x ' + pkg_l and never appends a plural s (only 'head' is special-cased), so the
     card never had this defect - it lived solely in the server-rendered spec cost_lines.
4. PRICE UNCHANGED, CHAIN RECONCILES. $9.84 for 5 cans; utilization $8.43 = (728g needed / 850g
   bought) x 9.84 exactly; 5 is the minimal count (4 x 170g = 680g < 728g). Tiers: 56.78/14 = 4.06,
   63.65/14 = 4.55, 63.65 + 10.79 = 74.44 = cost_first_run, scaler.cost 63.65 = cost_batch_true.
   13 lines, 0 unpriced. Battery cost-engine-consistency, cost-reconcile ("to the cent"),
   plausibility, line coverage all green.

## Everything the 08-27 GO certified, re-verified on today's bytes

- MACROS: battery recompute from food-macros-db: 560.9 / 51.8 / 16.1 / 34.2 vs stat 561/52/16/34,
  all four within tolerance, no missing food-DB rows. Matches the 08-27 figures exactly.
- STAT-PROSE: zero "51.8"/"16.1" literals in the spec; audit-spec-contradictions clean.
- PROTEIN: derived chicken by grams (2540 g, no competitor), matches claimed. recipes-db -DryRun
  builds every row with an item_id.
- VOICE: zero em/en dashes in spec and rebuilt card.
- CARDS: structural compare against the live al-pastor reference clean; JSON-LD parses as Recipe.
- The head description's "tomatoes" is real - Cherry Tomatoes, 834 g, is an ingredient (checked
  because the olive-line snippets happened not to show it).
- GHOST EXCERPT (new gate): head.description is 177 chars with no tokens to expand, safely under
  Ghost's 300-char custom_excerpt cap. audit-ghost-field-limits.ps1: 1 spec, 0 findings, exit 0.
  Confirmed by direct measurement, not just the gate.
- stat.cost_ps 5.30 vs today's first-run 5.32: expected pre-publish drift. Estate survey shows
  cost_ps = cost_first_run/servings at stat-write time and drifts pennies after recosts until
  wave-publish E2 re-anchors it per slug (several live specs show identical drift). Not a blocker;
  E2 owns it.

## The CLASS question: other labels the pluralizer will garble

Get-CostPlural (meal-prep\pipeline\cost-render-lib.ps1, ~line 59) appends "s" - or "es" after
ch/sh/ss/s/x/z - to the END of the whole label unless it ends in "each". So the defect class is
any label that reaches it with n >= 2 and does not END in a cleanly pluralizable noun. Swept all
344 labels in ingredients.json plus every pkg/starter_pkg in costed.json, then MEASURED the
rendered specs rather than predicting. NOT fixed, per instructions - named only:

FIRING TODAY in 7 live specs (none in this run or wave; all are older published recipes):
  - Swiss Cheese, buy_pkg_label "8oz" -> "Buy 2 8ozes" / "Buy 3 8ozes" (chicken-cordon-bleu-casserole,
    turkey-cordon-bleu-casserole, turkey-reuben-casserole, turkey-wild-rice-casserole)
  - Keto Bun, buy_pkg_label "8 buns" -> "Buy 4 8 bunses" (turkey-meatball-sub-bake)
  - Pasta Shells - jumbo, costed pkg "Great Value 12 oz" -> "Buy 2 Great Value 12 ozes"
    (ground-turkey-lasagna-casserole, turkey-manicotti-ricotta)
LATENT (0 firing lines in today's costed.json, will garble the day n >= 2):
  - Romaine Lettuce, buy_pkg_label "each (heart)" -> "each (heart)s" (the each$ guard misses it)
  - Egg Yolk, buy_pkg_label "12ct eggs" -> "12ct eggses"
  - pantry labels ending in parentheticals, exposed only when starter_n >= 2 renders the
    "Pantry staple; this batch alone uses about N <label>s" line: Dried Ancho Chiles
    "1lb bag (board capture)", Ground Fennel "8oz jar (board capture)", Sumac "8oz jar (label
    capture)", Sweet Soy Sauce "20.2floz bottle (600ml)", Jerk Seasoning "10 oz jar (Walkerswood,
    Walmart $4.52 captured 2026-07-25)" - the last three would leak capture provenance to readers
    even before pluralization.
Repair owner for all of the above: shared-data (the label rows), and the predecessor's process
advisory stands - the battery still has no check for a garbled pluralized render; the sweep above
is exactly the shape such a check should take.

Aside, same file, not this slug: the "Green Olives" row carries bid "olives" while the "Olives"
row carries bid "green-olives" - the display names and bids look crossed. Neither touches this
recipe (it uses black-olives); flagged for the mapper to rule on, not fixed.

## Advisories carried forward unchanged (predecessor + 08-27, still true, still not blocking)

Two shopping stories on one card (prose "three 14.5 oz cans" olives / "three 15 oz cans"
artichokes vs the engine's buy counts - both plans cover the batch); the artichoke display line's
"drained" beside a gross-basis figure; the "w/" in the title.

## Verdict

GO. The repair is committed, correct on every surface, the price did not move, the chain
reconciles to the cent, the macros and every 08-27 certification hold on today's bytes, and the
new Ghost gate passes by direct measurement. The class defect is real but lives entirely outside
this wave, in 7 already-published specs and a handful of latent labels, named above for a
separate repair.
