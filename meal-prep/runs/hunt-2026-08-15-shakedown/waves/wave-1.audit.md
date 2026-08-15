NO-GO

# Wave 1 audit - hunt-2026-08-15-shakedown (chicken-florentine, country-captain-chicken)

Audited 2026-08-15 by recipe-batch-auditor. Four blockers. None is expensive to fix; all are named with
file and repair. Re-audit after repair will be fast because everything else below is verified clean.

## WHAT BLOCKS

### B1. COSTS - both specs still carry the garlic-hijack cost snapshot; db\costed.json disagrees
The spec cost blocks were rendered at 12:26 from a board whose Walmart garlic cell was the
"Marketside Tandoori Style Garlic Naan Bites" hijack at $0.268/each (the mapper flagged it in
runs\...\mapped\country-captain-chicken.json). Commit c6f347d8 fixed the board and recosted
db\costed.json at 12:30 (garlic $0.58/head), but nothing re-rendered the specs:

  file: db\recipes\chicken-florentine.json      spec: batch 23.23 / true 32.57 / first_run 45.71, garlic line "$0.19 ... Buy 1 head: $0.27"
                                                costed.json now: batch 23.45 / true 32.88 / first_run 46.02, garlic util 0.41 buy 0.58
  file: db\recipes\country-captain-chicken.json spec: batch 26.21 / true 35.49 / first_run 52.20, garlic line "$0.09 ... Buy 1 head: $0.27"
                                                costed.json now: batch 26.32 / true 35.80 / first_run 52.51, garlic util 0.20 buy 0.58

The deltas are small in dollars but the number is not "the board moved" snapshot drift - it is a
known-wrong hijack price frozen into a spec that has never published. Publish would copy the six stale
cost_* fields verbatim into recipes-db.json (pipeline\update-recipes-db.ps1 lines 157-159) and
engine\audit-db-agreement.ps1 cannot see it (it compares index vs spec, never spec vs costed).
stat.cost_ps is stale the same way: spec 3.26 / 3.73, but the correct everyday basis off current
costed.json is 46.02/14 = 3.29 and 52.51/14 = 3.75 (recomputed by hand with the ceil-package model).
wave-publish E2 would silently re-anchor stat.cost_ps to 3.29/3.75 and leave cost_lines quoting the old
totals - the documented reanchor-pair-or-corrupt "spec quoting two prices" state.

FIX: powershell -File pipeline\recost-spec-cost-block.ps1 -Slugs chicken-florentine,country-captain-chicken -Apply
(re-renders cost_lines + six cost_* + scaler.cost from current costed.json), then let E2 re-anchor
stat.cost_ps at publish, then rebuild cards via the normal propagate chain. Re-verify: spec cost_batch
must equal costed.json cost_batch per slug, and stat.cost_ps must equal round(cost_first_run/14,2).

NOTE on the coordinator's claim B: "every cost line resolves to Walmart, so none of the hijacks touched
either recipe" was wrong in exactly one place - the garlic hijack WAS the Walmart cell, the store every
line resolves to. It touched both recipes.

### B2. GATES/LEDGER - the batch ledger row records only one of the two recipes
db\batch-ledger.json row "hunt-2026-08-15-shakedown-w1" has slugs=["chicken-florentine"];
country-captain-chicken is missing. Root cause: pipeline\hunt-run.ps1 line 403 starts the ledger via
`powershell -File ...batch-ledger.ps1 -Start -Batch $batch -Slugs $slugs` - the external -File call
binds only the first element of the [string[]], the same marshalling trap wave-publish.ps1 already
documents and works around for reanchor-machine-fields. Every future multi-recipe wave will
under-record the same way.
FIX: repair the live row to carry both slugs, and change hunt-run.ps1's -WaveClose to invoke
batch-ledger.ps1 in-process (or pass a joined string it splits), with a two-slug must-fire case.

### B3. CARDS - country-captain-chicken renders nested paragraphs
The spec's prose fields (intro_html, cost_closing_html, portion_html, upsell_html, shop_smart) carry
their own <p>...</p> wrappers; the card builder wraps prose fields in <p> again. Built card
db\built\country-captain-chicken.body.html contains 2x "<p><p>" and 3x "</p></p>" (intro and cost
closing shown at char-level). Browsers auto-recover but render stray empty paragraphs. The live
convention is bare prose: 534 of 544 specs store intro_html without <p>; chicken-florentine follows it
and renders clean.
FIX: strip the outer <p> wrappers from the five prose fields in db\recipes\country-captain-chicken.json
(inner </p><p> breaks become plain breaks per house style), rebuild the card, and eyeball it at 375px
per the standing mobile rule before publish.

### B4. VOICE/COPY - two chicken-florentine Shop Smart bullets contradict the recipe's own cost data
file: db\recipes\chicken-florentine.json (shop_smart), rendered verbatim in the built card.
  a) "Grate parmesan off a wedge. A block costs less per ounce than the pre-grated tub." False on our
     own board: the cost engine buys the Great Value 8oz grated tub at $2.74 ($0.34/oz, the cheapest
     Walmart form; board parmesan cheapest is Sam's grated $0.31/oz), and wedges cost more per ounce.
     The bullet tells the reader to spend more, and it contradicts the recipe's own buy line.
  b) "One carton of heavy cream covers the whole batch. This uses a full carton, so nothing is left."
     The buy is 2 pints (4 cups) against a 3.5-cup use; half a cup is left. The claim is false against
     the recipe's own numbers.
FIX: rewrite both bullets to match what the engine actually buys (tub is the budget play; two pints
with a half cup left for coffee), rebuild the card.

## RULINGS REQUESTED

### A. Calorie floor: 525 SHIPS (once the blockers above are fixed)
country-captain-chicken computes to 525 cal/serving, verified end to end from mapped grams against
food-macros-db.json (see MACROS below) - the number is honest, and the source dish itself is a
525-548 cal dish (source card: 548 at 6 servings). Precedent is established: 19 live non-burrito
recipes are under 550 (teriyaki-chicken-bowl 519, slow-cooker-italian-beef-bowl 504,
beef-chili-rice-bowls 484). Declaring cal_floor to silence it would itself violate the burrito-only
doctrine, and inflating the dish (+350 batch cal of rice) to clear a marketing floor would distort
source fidelity for no reader benefit. Not declaring the floor was the right call.
SEPARATE FINDING, not a blocker: on the v2 path the 550 floor is enforced NOWHERE - build-v2-spec.ps1
line 239 only warns, and spec-guards full mode (the enforcer) is banned from v2 specs. test-guards
tests the predicate but no production caller runs it on this path. If Brad wants the floor to be a
gate, it needs a home in wave-publish; today it is a convention, and this ruling relies on that being
understood, not hidden.

### B. Board hijacks vs these recipes' cost tiers
Everyday tier: every priced line on both recipes resolves to basis board:*:walmart (or
recipeboard-walmart; dried-guajillo-chiles is label:Fusion Select, allowlisted in
db\no-board-price-ok.json). The Aldi bacon-chips, Aldi parmesan-tenders, Fareway/Family Fare butter and
Aldi dairy-free cream hijacks therefore never touched the everyday tier - CONFIRMED. The garlic hijack
did (it was Walmart's cell) - that is blocker B1.
Cheapest tier: manifest cheapest_ps (2.63 / 2.92) was computed against scratch-smpfeed.json, dated
2026-07-27, which carries garlic 0.498/head, bacon 3.784/lb, parmesan 0.3049/oz, butter 2.74/lb - all
real products, no hijack in the numbers as shipped. But two real problems sit behind that "clean":
  1) compute-v2-perserving.ps1 line 46 downloads the feed only if the scratch file is MISSING, so every
     cheapest_ps recompute since July 27 (including the one E2 will run at publish) prices "cheapest"
     on a 19-day-old snapshot. Fix separately: delete/refresh scratch-smpfeed.json or staleness-gate it.
  2) The current live feed artifact (grocery\out\smp-feed.json, built 09:10 today) still carries the
     garlic hijack: cheapest 0.268/each. The board was fixed by 12:35 (comparison-2026-08-15.json:
     Walmart "Fresh Garlic Sleeve, 3 Count" $0.58/each, cheapest Baker's $0.498; butter/bacon/parmesan/
     heavy-cream cells all real products now). Live cards price garlic from the published feed, so the
     naan-bites price is reader-facing site-wide until the next feed publish. Republish the feed before
     or with this wave.

## PER-CATEGORY VERDICTS

1. MACROS: CLEAN. Both recipes recomputed end to end by hand from ingredients_grams against
   food-macros-db.json (both sit within 5% of 550, so both got the full recompute):
   florentine 573.2 cal / 45.1 P / 13.5 C / 37.1 F vs stat 573/45/14/37; country-captain 524.8 / 35.1 /
   65.5 / 12.1 vs stat 525/35/66/12. Bacon macros are correct despite the cost note: the DB row is a
   cooked-slice label (15 g/slice basis) so 108 g of cooked bacon is the right macro input for 9 cooked
   slices; only the COST line understates (raw-buy vs cooked-grams, ~$1.90 low - Brad ruled, disclosed
   in the mapped table). Spinach fresh-vs-frozen macro-identical per DB note; almonds row covers
   slivered; grams-vs-measure agree by construction per the mapped tables (spot-checked: cream 3.5 cups
   833 g, rice 4.25 cups dry 765 g, spinach 14 oz 397 g).
2. COSTS: ISSUES FOUND - B1 blocking; flags on feed staleness and live-feed garlic above. Tier
   arithmetic verified by hand line-by-line against costed.json (util, buy, starter, pantry_add =
   first_run - batch_true exactly on both). No absurd-unit survivors; all shelf prices plausible against
   the 12:35 board.
3. MAPPING: CLEAN. update-recipes-db -DryRun: 32 item_ids from ingredient-map, 1 scaler-bid fallback
   (dried-guajillo-chiles, allowlisted), 0 null. Same-concept verified per line; the ruled exceptions
   (shallots->onions per Brad, spinach->frozen-chopped precedent, boneless thigh NOT bone-in, red bell
   from the source's named options, petite-diced==diced same price class) are all documented in the
   mapped tables with evidence. Wine substitution follows the ropa-vieja precedent, registrar-ruled,
   disclosed in writer_notes and reader-facing prose, and source-QA confirmed no step reaches for wine.
4. PROTEIN + ROTATION: CLEAN. Both specs protein=chicken; heaviest protein ingredient is chicken by
   construction (florentine chicken-only; country-captain 1814 g chicken vs 108 g bacon). recipes-db
   copies spec.protein (update-recipes-db line 162) so index and spec cannot diverge at birth.
   normalize-recipe-ids.ps1 NOT run, per the 2026-07-25 correction. Both enter as paid, so the free
   rotation set is untouched by this wave.
5. CARDS: ISSUES FOUND - B3 blocking (country-captain nested <p>). Otherwise: both cards'
   class/id skeleton is byte-identical to the live known-good teriyaki-chicken-bowl card (florentine
   89/89 markers, country 94 = 89 + step8-step12 anchors); serving scaler (smp-sc-data + Make It Your
   Size), print/cook mode, tabbed whole-package cost section, Shop this recipe, and source credit all
   present; zero unresolved {{tokens}}; cost renders live via data-tc-live-price (the stale spec
   cost_lines are NOT reader-facing on the card - they surface via recipes-db, which is B1's path).
6. VOICE + COPY: ISSUES FOUND - B4 blocking. Zero em dashes in both specs and both built cards
   (UTF-8-decoded scan; the two apparent hits were the scaler JS multiplication sign misread under ANSI).
   No swearing (the one regex hit was "sCRAPe"). Tone is on-brand both recipes.
7. GATES: ISSUES FOUND - B2 blocking (ledger under-records the batch). audit-spec-contradictions -Quiet:
   COMPLETE rc=0. audit-store-integrity: COMPLETE hard=0 (19 pre-existing catalog warns, none on these
   slugs). test-guards: ALL GUARD PREDICATE TESTS PASS. audit-db-agreement: rc=1 with exactly the two
   expected SPEC-ONLY lines (index rows are created at E3; the E4 re-run gates for real). wave-publish
   self-test path inspected: P1-P7 and E2 verification reviewed, spec-guards full mode correctly NOT
   invoked. No gate was weakened by this audit.

## REPAIR SEQUENCE (then re-audit)
1. recost-spec-cost-block.ps1 -Slugs chicken-florentine,country-captain-chicken -Apply   (B1)
2. Strip outer <p> wrappers from country-captain-chicken prose fields                    (B3)
3. Rewrite the two florentine shop_smart bullets                                         (B4)
4. Repair ledger row slugs + fix hunt-run.ps1 -WaveClose marshalling                     (B2)
5. Republish the grocery feed (garlic hijack still live in the 09:10 artifact)           (B, site-wide)
6. Re-run this audit; the clean categories above only need the repaired surfaces re-checked.
