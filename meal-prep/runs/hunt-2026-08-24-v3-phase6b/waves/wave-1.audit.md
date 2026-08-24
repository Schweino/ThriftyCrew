GO
scope: whole-wave

# Wave 1 pre-publish RE-AUDIT (shared-data staleness) - hunt-2026-08-24-v3-phase6b
Auditor: recipe-batch-auditor (final gate), 2026-08-24 evening, superseding the 13:11:46 GO that went
stale when meal-prep\db\costed.json was rewritten at 18:16:41 and both specs were restamped at 18:16:41.
Battery report: waves\wave-1.preaudit.json, generated 2026-08-24T18:23:56 - AFTER every byte it certifies
(costed 18:16:41, both spec mtimes 18:16:41 recorded in-report and confirmed on disk). 22 checks, 0 failed,
whole-wave. Its numbers were verified below, not taken on faith.

## What actually moved at 18:16, measured
- git diff of costed.json vs HEAD: 436 insertions, 0 deletions - a PURE ADDITION of exactly the two wave
  rows (570 -> 572, each slug present exactly once). No pre-existing row was touched, so the blast radius
  of the shared-data event is precisely this wave.
- Every cost and macro number now on disk equals the number the 13:11 audit recorded (27.54/31.46/45.36,
  $1.97; 23.79/27.27/46.16, $1.70; 524/63.8/9.6/25.6; 602/54.9/28/29.5). The rewrite reproduced the prior
  basis rather than shifting it. I did not rely on that equality: everything below is re-derived from the
  CURRENT bytes.
- The pork Blocker-2 repair survived the restamp: head.cookTime PT4H30M / totalTime PT4H40M still on disk,
  make_it step 5 and head.steps still lead with the loin 4-to-5-hour time, the alternate still phrased as
  "a heavier, fattier roast" (no unbought commodity named). The Blocker-1 phantom-gate fix is upstream lib
  code and unaffected; audit-spec-contradictions re-ran clean over all 572 specs in the fresh battery.

## Owed item 1: cost blocks vs the NEW costed.json rows, and shelf plausibility
- Spec-to-engine: all six cost fields in each spec match its costed row to the cent (chicken 27.54 / 31.46 /
  1.97 / 2.25 / 13.90 / 45.36; pork 23.79 / 27.27 / 1.70 / 1.95 / 18.89 / 46.16). stat.cost_ps "1.97" and
  "1.70" equal cost_per_serving. scaler.cost equals cost_batch_true in both, matching catalog convention.
- Engine rows re-summed by hand from their 13 and 12 lines: utils sum to cost_batch exactly; non-bulk buys
  plus bulk utils sum to cost_batch_true exactly; starter packs minus the bulk utils already counted equal
  cost_pantry_add exactly; first_run = true + pantry in both. Per-serving tiers derive at /14.
- Prose money literals re-traced: chicken pantry-seasonings "~$0.20" = .03+.06+.07+.02+.02; the nine chicken
  cost_lines re-sum to $27.54; pork pantry-seasonings "~$0.36" = .12+.04+.05+.06+.03+.06; the seven pork
  lines re-sum to $23.79; both True lines ($31.46/$2.25, $27.27/$1.95) and both pantry-add closers
  ($13.90 -> $45.36, $18.89 -> $46.16) re-derive.
- Shelf reality: breast $2.23/lb and loin $2.14/lb (both util = grams x per-lb rate, checked), butter
  $2.98/lb, honey $2.70 per 12oz, spinach $2.00 per 10oz bag, cream cheese $1.84 per 8oz brick, ACV $1.67
  per 32oz, cornstarch $1.92 per 16oz, parmesan $2.74 per 8oz tub, sun-dried tomatoes $4.26 per 7oz jar.
  Nothing 3x under shelf; no price-class survivor. Zero unpriced lines, zero uncarried, so no 2b repair
  owners to name.

## Owed item 2: macros vs food-DB labels at the run band (500-650 cal, <=40 g carb, >=50 g protein)
Recomputed end to end by hand from meal-prep\food-macros-db.json rows and the specs' own grams, independent
of the battery (whose per-item rows I pulled and multiplied myself):
- stuffed-chicken-breast: batch 7342 cal / 893.1 P / 134.9 C / 359.0 F -> per serving 524.4 / 63.8 / 9.64 /
  25.64 vs stat 524/64/10/26. IN BAND on all three gates with margin.
- slow-cooker-pork...: batch 8433.8 cal / 769.2 P / 391.6 C / 412.7 F -> per serving 602.4 / 54.9 / 27.97 /
  29.48 vs stat 602/55/28/30. IN BAND: 602 inside 500-650, 28.0 <= 40, 54.9 >= 50. (Fat 29.48 displays as
  30 via the pipeline's 29.5-then-round; 0.5 g, immaterial, no published claim rests on fat.)
- All DB rows present; the pork loin row is the LEAN trimmed loin (155 cal/112 g) matching "trimmed" in the
  buy string, and Spinach is the fresh-priced/fresh-booked row per the 2026-08-16 form ruling.
- Prose bounds still true on current numbers: chicken "under 10 grams of carbs" (9.64), pork "under 30 grams
  of carbs" (27.97). Both intros/portions carry only {{cal}}/{{protein}}/{{cost_ps}} tokens otherwise.

## Owed item 3: what the restamp could have disturbed
- Stale-literal sweep of both specs (intro, portion, cost_note, cost_lines, cost_closing, shop_smart,
  make_it, head, upsell, credit): every literal number re-traced to the current stats or engine row; no
  frozen pre-restamp number found. Buy lines match costed buy_n/buy_cost verbatim (7 lb / $15.62, 2 bags /
  $3.99, 2 bricks / $3.68, 9 lb / $19.26, 1 lb box / $2.98, 1 head / $0.58, etc).
- Pantry folds intact: chicken folds 5 seasonings into one line, pork folds 6; composite riders (dried
  basil on the oregano line; dried thyme on paprika; onion powder on garlic-powder; black pepper on salt)
  are each named in the buy string AND used in a step, per the QA certs. Rider grams are uncosted and
  unmacroed by design; worst case ~1 cal/serving, immaterial.
- Card rebuild (battery, 18:23): both structurally identical to the live al-pastor reference - scaler,
  print, 3-part cost section, credit line, JSON-LD Recipe parses, 8 and 7 step anchors, zero dash bytes.
  head.steps shorter than make_it (5 vs 8 on chicken) matches live-catalog convention (al-pastor 6 vs 8).

## Standard battery, remainder
- Protein field: chicken 3178 g / pork 3719 g, exclusive tallies, claimed == derived; update-recipes-db
  -DryRun green, zero null item_ids; both specs visibility "paid", so free-dinner rotation and hub Top 5
  sets are untouched.
- Mapping: no new rulings since 13:11; loin-vs-shoulder band ruling stands (shoulder ~738 cal breaches 650),
  scaler bids all resolve (vocab-integrity clean n=2, unbid clean n=2).
- Voice: zero em/en dashes (counted the codepoints myself, both files), no swearing (the only "ass" hits
  are "PASS" in writer_notes), plain punctuation.
- Gates: contradictions / store-integrity / vocab / unbid / cost-plausibility / dryrun all rc 0 at 18:23;
  none weakened. Manifest (2 slugs), states ("waved", wave 1) and QA certs (both "pass") tell one story.

## Advisories (carried or new; none falsifies a published claim, none blocks)
- Sun-dried tomato form (carried): spec books the DRY food-DB row at 63 g while prose sells the oil-packed
  jar and its drained oil; adjudicated immaterial (+9 cal, +1.3 g fat at drained-jar weight; band holds).
  A future touch should book the oil-packed row.
- Chicken intro "under 10 grams of carbs" beside a displayed stat of 10 (actual 9.64): true as computed,
  mildly tense next to the rounding (carried).
- Mozzarella priced at the Sam's 5-lb per-oz rate on an "8oz bag" buy string: the standing everyday-cost
  board model, uniform across the catalog (carried).
- Pork honey line "this batch alone uses about 2 12oz bottles": usage is 445 g (~1.3 bottles); the BUY of 2
  bottles is what is true (starter_n 2). Phrasing is loose but the money and the shopping list are honest.
- Writer_notes in both specs cite a "400-650 cal AND <=35 g carb" band; the run's actual band is 500-650 /
  <=40 / >=50 (run.json). Internal notes only, never published, and both recipes sit inside the REAL band
  (524 and 602 cal), so nothing published is wrong - but a future skeleton should carry the right band text.

## Left to wave-publish by contract (unchanged)
stat.cost_ps re-anchor and hard-verify (E2); manifest/ledger/states one-story (P2/P3). Both specs carry
cost_ps == cost_per_serving against the 18:16 costed.json, so E2 should find nothing.

## Verdict: GO. The 18:16 cost-basis rewrite added exactly the two wave rows and every number re-derives
from the current bytes. No blockers. Publish wave 1.
