NO-GO
scope: street-corn-chicken-rice-bowls
run: hunt-2026-08-27-highprotein  wave: 16  batch: hunt-2026-08-27-highprotein-w16  audited: 2026-09-02
battery: wave-16.preaudit.json (generated 2026-09-02T12:05:35, 16 checks, 0 failed; spec mtime 09:10:18, costed 11:54:54) - chains verified, not rebuilt
source-qa: qa\street-corn-chicken-rice-bowls.json PASS 2026-09-02 (battery 09:05:02, verdict 09:21:16) - what it certified is what is in the spec now

## Verdict

NO-GO on ONE blocker, and it is not recipe-local. The recipe itself is clean: macros reconcile by
hand, the engine row reconciles to the cent, both wave-9 blockers are genuinely fixed on disk, the
corn line is on the drained basis with the arithmetic agreeing, no ingredient is billed twice or
dropped, the prose carries no literal numbers, and the card rebuilds byte-identical to the built
copy. What blocks is the card's live cost widget, the only cost surface a member actually sees,
which prices this recipe's corn on the NET basis and will tell the reader to buy 3 cans of a
4-can recipe. That is the exact "a can short" defect commit 59831927 declared fixed this morning,
still standing in the reader-facing copy of the rule. Details and the fix in B1.

If Brad rules that a shared-template defect already carried by every live drained-can card is
not a per-wave blocker, nothing else in this audit stands in the way and the wave may go on
that ruling alone. I am not making that ruling for him.

## Blocker

### B1. Card widget + compute-v2 price drained lines on the net basis: this card says 3 cans, the recipe needs 4 (pipeline)

The engine (meal-prep\engine\cost-recipes.ps1) now runs corn through its drained branch: pkg_g
298, 1148 g / 298 = 3.85, ceil(3.85 - 0.02) = 4 cans, $2.44. The spec, costed.json and the widget
data block all carry pkg_g 298 (card line 607: {"item":"Sweet Whole Kernel Corn", "grams":1148,
"gpu":28.350, "pkg_g":298, "pkg_l":"can"}). But the widget never divides by pkg_g when the feed
carries a store package size:

- tpl2-scaler-prefix.html (rendered in the card at body lines 118-135): `required = grams / gpu`
  = 1148 / 28.35 = 40.5 oz, then `k = ceil(required / packageBasisUnits)` with the feed's own
  15.25 oz basis -> 3 cans. `pkgs()`, the one function that reads pkg_g, has NO caller.
- I replicated the widget's own costAt()/cheapestAcross() in the browser against the live feed
  (generated 2026-09-02T08:05:34, schema 2). Custom tab: Fareway 3 x 15.25 oz, $2.04. Everyday
  tab: Hy-Vee 3 x 15.25 oz, $2.28. Walmart: 2 x 29 oz, $2.32. Every answer is a can short: three
  15.25 oz cans drain to 894 g against the 1148 g (7 cups) the ingredient list on the same page
  states, 22% short of the salad.
- meal-prep\pipeline\compute-v2-perserving.ps1 line 203 derives `$req = grams / gpu` the same
  way (by design, "the card's required"), so cheapest_ps 3.39 in v2-perserving.json is on the
  can-short basis too. everyday_ps 3.67 is not (it reads the engine's k), which is why the two
  numbers now disagree about the corn.
- Neither browser is signed in as a member, so I could not watch the paid widget render; the
  reproduction above IS the widget's code path with the widget's inputs, not an estimate.

Why this is new today and not a carried condition: until 09:16 corn's pkg_g was 432, the net
weight, so the engine and the widget agreed (both wrong, both said 3). Moving the engine to 298
without moving the widget's basis split the card against itself. The same split has existed
silently on every drained-bean line (pkg_g 255 against a 425 g net can) since the feed repoint;
this is simply the first audit after a basis move exposed it. That is the [[two-copies-of-a-rule]]
class: package-cost-lib.ps1 says outright that the JS is the authority and the lib is its copy,
and both copies carry the same net-basis `required`.

Fix (owner: pipeline; no spec edit needed):
1. meal-prep\pipeline\build-card2.ps1: for a line the engine costed on the drained basis (costed
   basis ends "+drained", pkg_g < the ingredients.json buy_pkg_g), emit the widget's `gpu` as
   drained grams per feed unit, gpu_eff = pkg_g / (buy_pkg_g / gpu). Corn: 298 / (432 / 28.35)
   = 19.56 g per oz. Then required = 1148 / 19.56 = 58.7 oz -> ceil(58.7 / 15.25) = 4 cans, the
   authored fallback pkg_g / gpu_eff = 15.24 oz still names the real can, and no JS changes.
   (Or emit a separate drained factor and read it in the template; either way ONE rule.)
2. compute-v2-perserving.ps1 line 203 and package-cost-lib.ps1 consumers take the same gpu_eff,
   so cheapest_ps and the blast-radius measurement move with the card.
3. Rebuild and republish every drained card (34 corn specs from this morning plus the ~63
   drained-bean lines), since all of them under-buy in the widget today; then a scoped re-audit
   of this slug. Suggest the same guard-fixture discipline as the engine: a frozen corn line
   whose widget count must equal the engine's buy_n.

## Verified clean this pass (re-derived, not taken from the battery)

MACROS (hand recompute from meal-prep\food-macros-db.json, all 20 rows present): batch 8391 cal,
642 g P, 789 g C, 306 g F; over 14 = 599.4 / 45.9 / 56.4 / 21.9 against stat 599 / 46 / 56 / 22.
Corn row is FDC 169214 drained solids (67 cal/100 g) and 1148 g / 7 cups = 164 g/cup matches the
FDC cup. Chicken 2183 g at 130 cal/112 g carries 2534 of the calories; rice 648 g at 160/45 g
carries 2304. Band 450-800 cal and >= 40 g protein satisfied with margin. No 550 gate applies
(cal_floor null, run band 450-800).

COSTS (engine row in db\costed.json, 20 lines, 0 unpriced): the 20 utils sum to 25.43 exactly;
non-bulk buys 29.96 + bulk utils 2.18 + zest util 0.69 = 32.83; pantry add re-derives to 19.29
(sum of starter minus util over the 10 bulk lines); first run 32.83 + 19.29 = 52.12; pantry
seasonings line 0.55 = the seven spice utils. Every buy line reproduces from the live feed cell
it names: chicken Walmart 2.2301/lb x 5 = 11.15, corn 0.04/oz x 15.25 = 0.61/can x 4 = 2.44,
yogurt 0.115 x 32 = 3.68, cotija Baker's 0.4738 x 8 = 3.79 (only Baker's and Family Fare carry
it), limes 0.25 x 7 = 1.75, jalapenos 1.76, cilantro 1.78, avocados 0.58 x 4 = 2.32, red onion
1.2867. No price-class survivors; nothing 3x under shelf reality. stat.cost_ps 3.67 equals the
manifest everyday_ps (wave-publish E2 re-anchors and hard-verifies it, tolerance 0.02).

WAVE-9 BLOCKERS, ACTUALLY FIXED (git show 59831927 on the spec): Lime Juice (bid lime-juice, 213 g,
"Buy 1 (covers this batch)") -> Fresh Lime Juice (bid limes, gpu 30, 210 g = 3.5 x 30 + 7 x 15,
"Buy 7 limes: $1.75"); Lime Zest 7 g "Buy 2 limes: $0.50" -> 11 g covered_by Fresh Lime Juice,
"From the limes you already bought"; no bottle anywhere on the card. Zest is no longer claimed on
both lines. The engine validated the covered_by (same bid, peer present) and suppressed the
purchase (buy_n null). The literal "under 600 calories" is gone from intro_html and
head.description; both carry {{cal}} and render 599. The card and head carry no {{ }} leftovers.

CORN BASIS: spec 1148 g drained, engine pkg_g 298 with basis "board:canned-corn:walmart+drained",
4 cans, util 1148/298 x 0.61 = 2.35. densities.can 298 with the FDC note; ingredients.json
buy_pkg_g stays 432 net, which is what admits the drained branch. Correct on the engine side.

PINEAPPLE (uncommitted): densities.json and food-macros-db.json diffs touch only Pineapple
Chunks; the uncommitted costed.json and recipes-db.json diffs do not mention this slug; the spec
is unmodified since the commit. This recipe is untouched by it, as expected.

MAPPING (runs\...\mapped\street-corn-chicken-rice-bowls.json + db\ingredient-resolutions.json):
26 source lines -> 20 spec lines, every one with a bid; the three mapped-null lines (cotija x2,
red onion) were priced by the pricer ("all 2 blocking ingredients carried") and now resolve to
cotija-cheese and red-onion. Substitutions are same-concept: avocado-oil mayonnaise -> Mayonnaise
(brand variant), "pickled or fresh red onions" -> fresh (source offers either), 2% Greek yogurt
-> the priced GV row (fat delta under 1 g/serving). Water is the cooking medium, not shopped,
carried in step 1 at the source's own 2:1 ratio. Sea Salt and Salt are two rows because the
source names two, and both sums close at 3.5x. recipes-db dry run: 0 null item_ids.

PROTEIN + ROTATION: chicken 2183 g is the only protein; recipes-db.protein "chicken" by
construction. Condition "boneless skinless chicken breast" is met literally (raw breast, not a
processed product).

CARDS: scratch rebuild is byte-identical to meal-prep\db\built\street-corn-chicken-rice-bowls.*
(both 73316 / 6567 bytes, 09:10). Structure matches the al-pastor reference: serving scaler data
block, print button, jump nav with What it costs / Make it / Portion it, 6 step anchors, JSON-LD
nutrition 599 cal / 46 g / 56 g / 22 g, source credit to eatingbirdfood.com. 375px: no new
visual element; this is the shared v2 template whose mobile pass stands. I could not view the
member-only widget rendered (see B1).

VOICE + COPY: 0 em/en dashes in spec, body and head; no swearing; none of the spec's
forbidden_prose_terms appear; the only literal number in any prose field is "14"; every
calorie/protein/cost mention is a token. Reads as Brad.

GATES: audit-spec-contradictions, store-integrity (hard 0, the one reviewed exception is the
tuscan sun-dried tomatoes, not this wave's), vocab-integrity, unbid-ingredients, cost-plausibility,
cost-line-coverage, P8 provenance and liveness (582 recipes, 08:05:34) all green per the battery
and re-read. Nothing here weakens a gate.

STATES / LEDGER / MANIFEST: wave-16.json, the state file (waved, wave 16, 12:04:48) and the w16
ledger row tell one story. See N4 for the w9 row.

## Non-blocking notes

N1. Zest utilisation is billed inside the totals the zest line says are free. Lime Zest util
$0.69 (11 g / gpu 4 = 2.75 limes at $0.25) is summed into cost_batch 25.43, cost_batch_true
32.83 and cost_first_run 52.12, while the same line prints "From the limes you already bought"
and 7 limes yield 28 g of zest. The engine comments this as deliberate ("the utilisation still
counts"); compute-v2 disagrees and skips covered lines, which is why everyday_ps is 51.43/14 =
3.67 and not 52.12/14 = 3.72. Not reader-facing on this card except the composition bar (Lime
Zest 3% beside Fresh Lime Juice 7%, so limes read as 10% of a bill on which they are 7%). The
spec's cost_lines are not rendered by the v2 card at all. One definition should win; owner
pipeline, next time the engine is opened. Same shape on the live no-boil casserole (Lemon Zest
$0.42).

N2. Chicken label vs grams: "4 3/4 lb" against 2183 g = 4.81 lb (the source's 1.25-1.5 lb
midpoint x 3.5). The label is the nearest quarter pound, the cost line buys 5 lb, and the macro
delta is 2 cal/serving. Fine to ship; noting so nobody reads it as a stale label later.

N3. writer_notes[4] still says "45g protein (44.6 pre-rounding) and 597 cal". Internal only,
never rendered, but it is now a false statement inside the spec file. Writer, next touch.

N4. Ledger row hunt-2026-08-27-highprotein-w9 is still open (closed false) and still lists this
slug, alongside the open w16 row. Its 2026-09-02 reconcile stamp explains why (the five others
shipped under w13/w15; this one is "still genuinely w9's"). Now that the slug has re-waved as
w16, the w9 row should be closed or abandoned at the same time the w16 row is stamped, or the
ledger will show one recipe live under two batches. Orchestrator bookkeeping, not a publish gate
(P2 reads only the w16 row).

N5. The QA battery file (09:05:02) predates the final spec bytes (09:10:18) by five minutes; the
QA verdict (09:21:16) describes the final state, including the {{cal}} token, and the battery's
ingredient rows already show Fresh Lime Juice and Lime Zest, so the gap is the restat and
tokenisation, not an ingredient change. Mentioned because wave-publish P1b will compare stamps
the same way.

N6. Working tree carries uncommitted shared-data edits (densities, food DB, costed, recipes-db,
the pineapple work) and an untracked store-integrity-exceptions.json that the store-integrity
gate now depends on. wave-publish's own commit step will sweep these in with the wave
([[push-data-sweeps-your-edit]]). Not this wave's defect, but whoever publishes should know the
pineapple basis change ships with it.

## Repair routing

| finding | kind | owner | blocking |
|---|---|---|---|
| B1 widget + compute-v2 price drained lines on the net basis (3 cans shown, 4 needed) | template / shared-lib basis defect | pipeline (build-card2 + tpl2-scaler + package-cost-lib consumers), then rebuild drained cards, scoped re-audit | yes, unless Brad rules a shared-template defect off the per-wave gate |
| N1 covered-line util inside the totals | engine vs compute-v2 definition | pipeline | no |
| N2 chicken quarter-pound label | rounding | none | no |
| N3 stale writer note | prose-internal | writer | no |
| N4 w9 ledger row open with this slug | bookkeeping | orchestrator | no |
| N5 QA battery predates final spec by 5 min | stamp hygiene | orchestrator | no |
| N6 uncommitted pineapple work rides the publish | tree hygiene | orchestrator | no |
