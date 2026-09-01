NO-GO
scope: chicken-and-potato-curry,high-protein-chicken-alfredo-lasagna,no-boil-chicken-pasta-casserole-with-artichokes-and-peas
run: hunt-2026-08-27-highprotein  wave: 15  audited: 2026-08-31
battery: wave-15.preaudit.json (generated 2026-08-31T15:50:57, 30 checks, 0 failed) - chains
verified against disk, not rebuilt; spec mtimes on disk match the report's recorded stamps
exactly (13:21:48 / 13:44:38 / 13:24:43) and costed.json matches its 14:57:17, so the report
certifies the bytes that exist now.

## Verdict

NO-GO. The wave-9 story has a good ending this time: all five R1-R5 repairs are REAL ON DISK,
verified independently (details below). The premise of this dispatch is true. What blocks is
new, and two of the three findings live exactly where the dispatch said to look: in the
residue the battery does not check. The lasagna's ruled rebuild pushed it out of the run's
own calorie band, and two cost lines price packages that cannot produce the batch as written.

## Blockers

### R1. high-protein-chicken-alfredo-lasagna - rebuilt stat 440 cal is below the run's 450 band floor (recipe-local, orchestrator/Brad)
The R2 repair itself is faithful: I re-derived all four macros by hand from food-macros-db
(Member's Mark raw breast 130cal/25p per 112 g, plus the other eight rows) and got
440.34 / 43.17 / 26.33 / 17.98 per serving - stat 440/43/26/18 is exact, the chain is honest.
But run.json's band is calMin 450 ("450-800 calories per serving" in Brad's conditions), and
rebasing the 1058 g line from breaded bites (496 cal) to plain breast landed at 440 - 10 under
the floor. Nothing downstream catches this: band enforcement lives at selection (the recipe
was selected at ~500 cal on the breaded basis), wave-publish has no band check, and
spec-guards full mode (the 550 house floor) deliberately does not run on this path. The
lasagna writer_notes record Brad's protein-form ruling but no band waiver, and unlike the
casserole spec there is no "band verified" note post-rebase. Three doors: Brad rules the 2%
shortfall acceptable and the waiver is recorded in writer_notes; or the recipe is reworked
into band (more noodles/sauce/cheese and a recost); or it leaves the wave. A question, not a
shrug - but until ruled, it blocks.
File: meal-prep\db\recipes\high-protein-chicken-alfredo-lasagna.json (stat.cal) +
meal-prep\runs\hunt-2026-08-27-highprotein\run.json (band.calMin).

### R2. no-boil-chicken-pasta-casserole-with-artichokes-and-peas - artichoke buy and cost computed on gross can weight against drained grams (recipe-local, pipeline)
The dispatch's recorded note-level residue, ruled here: it BLOCKS, because it is not prose -
it is the engine row. The extraction reads "14 oz canned artichoke hearts, (drained and
roughly chopped)"; scaled 7/3 that is 2 1/3 cans, whose DRAINED content is the build's 560 g
(the display line "1 lb 4 oz drained (about 2 1/3 cans)" is correct). But costed.json prices
the line with pkg_g 391 - the 13.8 oz LABEL weight - so buy_n = ceil(560/391) = 2, and the
bolded "Buy 2 13.8oz cans: $4.45" ships an instruction that cannot produce the batch: two
cans drain to roughly 480 g, 80 g (14%) short. The same card contradicts itself two clauses
apart (2 vs 2 1/3 cans), and every tier under-prices the line: util $3.19 is drained grams at
the gross per-gram rate (a drained basis puts utilization near $5.19), and the true tier is a
third can short (+$2.23; 49.44 -> ~51.67, per-serving true 3.53 -> ~3.69). Same family as
wave-9's R3 citrus unit-basis blocker, and the same standard Brad's own R2 ruling stated: the
card must describe what it costs. Fix owner pipeline: give artichoke-hearts a drained-basis
package weight (~240 g/can) or restate the spec grams on label basis, then recost, run
sync-recipesdb-cost, rebuild the card, scoped re-audit (-Slugs).
Related non-blocking residue to fix in the same pass: the food-DB "Artichoke Hearts" row is
WITH-LIQUID basis (130 g serving, 40 cal) applied to drained grams - understates the dish by
only a few cal/serving at 560 g, harmless at 603 cal mid-band, but the basis mismatch should
not survive into a third wave.
File: meal-prep\db\costed.json (artichoke line) + meal-prep\db\recipes\no-boil-chicken-pasta-casserole-with-artichokes-and-peas.json (cost_lines) + meal-prep\food-macros-db.json (row basis).

### R3. high-protein-chicken-alfredo-lasagna - fresh mozzarella true tier prices a package no store sells (recipe-local, pipeline)
Basis is board:fresh-mozzarella:recipeboard-cheapest:Sam's Club at $0.2588/oz - but Sam's
only pack is "BelGioioso Pre-Sliced Fresh Mozzarella 32 oz" ($8.28). The engine stamped pkg
"8oz ball" and sold the reader "Buy 3 8oz balls: $6.22" - three balls at $2.07 each, a
purchase that exists at no store on the board: the stores that DO sell an 8 oz ball charge
$4.99 (Fareway $0.6238/oz), so following the instruction literally costs $14.97, 2.4x the
printed number, while buying at the priced store means one 32 oz pack at $8.28 (+$2.06 on the
line; true tier 32.50 -> ~34.56). The utilization tier is sound (529 g x Sam's per-gram =
$4.83, and the batch/per-serving headline stands); the whole-package tier's own stated
contract ("counted as the whole packages you have to buy") is what the line violates. Fix
owner pipeline: derive the package from the priced store's actual pack (1 x 32oz: $8.28),
recost, sync, rebuild. This is the price-class residue the battery names in not_checked; the
casserole's Boursin line (same recipeboard-cheapest mechanism, Fareway 5.3oz puck at $5.48)
shows the engine CAN get this right when the registry package matches the priced store.
File: meal-prep\db\costed.json (Fresh Mozzarella line) + grocery\out\recipe-board-everyday.json (fresh-mozzarella cell, for the pack size).

## Wave-9 R1-R5: all repairs verified real on disk

- R1 (lasagna recost): costed.json carries the 9-line row with a separate Black Pepper line
  (2 g, board:black-pepper:walmart, util $0.06), lines_unpriced 0; utils sum to 22.61 to the
  cent; the card rebuilds. Closed.
- R2 (protein form): ruled by Brad 2026-08-31, recorded in writer_notes. The card is honest
  everywhere I looked - display, buy string, steps, head.description all say roasted plain
  boneless skinless breast; my own grep of the rebuilt body+head HTML finds zero occurrences
  of breaded/bites/frozen. Macros genuinely rebuilt, not carried (hand recompute above).
  Closed as ruled - but see R1: the rebuild's arithmetic consequence was never re-checked
  against the band.
- R3 (citrus zest): the zest line is now pkg "lemon", pkg_g 6, "Buy 1 lemon: $0.50", ~$0.42
  for 5 g. The per-pound-as-each artifact is gone. Closed.
- R4 (curry chili): spec bid jalapenos, engine basis board:jalapenos:walmart, "Buy 1 lb:
  $1.43" - the registrar's $1.4277/lb. Zero serrano occurrences in spec and in all three
  rebuilt cards (my grep). Closed.
- R5 (shared gate): re-ran audit-spec-contradictions myself: exit 0, "0 finding(s) across
  585 spec(s)", SPEC-CONTRADICTIONS-COMPLETE. Closed.

## Checklist verdicts

- MACROS: issues found (R1 band, not arithmetic). Lasagna hand-recomputed end to end: exact.
  Casserole (602.8 vs 603) and curry (499.7 vs 500) verified from the battery's shown
  numbers; no wave recipe sits within 5% of a band edge except the lasagna, which sits UNDER
  one. missing_fooddb_rows empty on all three. Artichoke row basis note under R2.
- COSTS: issues found (R2, R3). Everything else reconciles and is shelf-plausible: chicken
  $2.23/lb, cottage cheese $2.73/24oz, GV parmesan $2.74/8oz, penne $0.92/lb, diced tomatoes
  $0.77/can, coconut milk $1.84/can, lemons $0.50, Boursin $5.48/puck (real price for the
  real product). All three engine rows sum to the cent; all tiers derive; nothing unpriced,
  so no 2b classification owed. stat.cost_ps basis verified as the catalog's firstrun/14
  convention on all three (2.56 / 3.82 / 3.06 exact).
- MAPPING: clean. fresh-red-chili->jalapenos is the registrar's ruling; boursin->
  garlic-herb-cheese-spread is same-concept at the real Boursin price; fresh-mozzarella and
  no-boil-lasagna-noodles have real multi-store board cells; null item_ids 0 (battery
  dry-run, and no normalize-recipe-ids anywhere near this path).
- PROTEIN + rotation: clean. All three chicken by heaviest ingredient. Note (non-blocking,
  pipeline): the battery's tally counts Chicken Broth grams as chicken (casserole 2988 =
  1588+1400; curry 3221 = 2381+840) - harmless here since breast dominates regardless, but
  the instrument would mislabel a recipe where broth outweighs a competing meat.
- CARDS: clean. Battery structural compare vs the al-pastor reference on all three, plus my
  own byte checks: zero unresolved {{tokens}}, paywall marker present, "What This Batch
  Costs" + hydration contract present, print present, credit lines correct. Cost prose ships
  via spec cost_lines/feed, which is where R2/R3 get fixed.
- VOICE: clean. Zero em/en dash BYTES in all three specs and all three rebuilt card bodies
  (my count, not the ban-list-scanning instrument). No swearing; plain punctuation.
- GATES: clean except as blocked. audit-spec-contradictions green (my run); store/vocab/
  unbid/cost-plausibility/cost-line-coverage green per battery rc 0 markers; P8 endpoint and
  feed probes green (577 recipes, 14:57:36). No gate weakened. States, manifest and QA tell
  one story: exactly the three slugs waved at 15, street-corn correctly back at written.

## Non-blocking notes

- Casserole true tier buys 3 lemons (2 juice + 1 zest) while the prose says the zest comes
  from the same lemons - $0.50 overstated, conservative direction. Writer, next pass.
- Boursin display says "5.2 oz packages", cost line says "5.3oz pucks" - cosmetic; likewise
  curry display "14 oz cans" vs engine 411 g (14.5 oz) on diced tomatoes.
- Display brands name the macro-row product while prices come from the board's cheapest
  store (Barilla display / Hy-Vee store-brand price on the noodles; Thai Kitchen display /
  GV-level price on coconut milk). Standing catalog convention, noted only.
- Curry writer-note broth scale drift (5.75 vs 5.833 cups) - recorded by the writer, minor.

## Repair routing summary

| finding | slug | kind | owner | blocking |
|---|---|---|---|---|
| R1 stat 440 under band floor 450 | lasagna | condition-question | orchestrator/Brad | yes |
| R2 artichoke gross-vs-drained buy/cost basis | casserole | cost-basis | pipeline | yes |
| R3 mozzarella package fiction in true tier | lasagna | price-class | pipeline | yes |
| broth counted as chicken in battery tally | shared | battery-tolerance | pipeline | no |
| artichoke food-DB row with-liquid basis | casserole | shared-data | mapper | no |
| lemon double-buy in true tier | casserole | prose-drift | writer | no |

Sequencing note for the orchestrator: R2 and R3 both end in a recost, so run them together -
fix both bases, recost the two slugs, sync-recipesdb-cost, rebuild the cards, then a scoped
re-audit (-Slugs casserole,lasagna) is seconds. R1 is a ruling; if Brad waives, record the
waiver in the spec's writer_notes so the next auditor is not re-litigating 440 vs 450 from
scratch. The curry is clean on every check I ran; it is only waiting on its wave-mates.
