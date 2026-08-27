GO
scope: mediterranean-chicken-w-marinade

# Wave 1 RE-audit - hunt-2026-08-27-ten (mediterranean-chicken-w-marinade)

Scoped re-audit after the 06:10 NO-GO (two blockers, both this slug). Battery report:
waves\wave-1.preaudit.json, generated 2026-08-27T06:18:24, 16 checks, 0 failed, scope whole-wave
(the full battery re-ran, not just the slug). Freshness verified: ingredients.json 06:17:10 ->
costed.json 06:17:19 -> spec 06:17:24 -> report 06:18:24, and nothing in that chain has moved since
the report was generated. The repair was done in the right ORDER (label at the source, then recost,
then spec rebuild), not by hand-patching the spec.

## The two blockers, verified repaired

BLOCKER 1 (STAT-PROSE x4) - FIXED. Grep of the spec finds zero "51.8" and zero "16.1"; prose now
reads "52 grams of protein" / "52g protein" and "16 grams of carb" / "16g carb" in intro_html,
portion_html, cost_closing_html and head.description. The carbs advisory (16.1 -> 16) was applied
too. audit-spec-contradictions is back to baseline: clean, exit 0.

BLOCKER 2 ("6oz can, draineds") - FIXED AT THE SOURCE. ingredients.json black-olives
buy_pkg_label is now "6oz drained-weight can" (pluralizable noun last), and the spec's cost line
renders "Buy 5 6oz drained-weight cans: $9.84." Repo-wide grep of meal-prep\db finds zero
"draineds". The scratch-rebuilt card is clean of both defects.

## Verdict per category

1. MACROS - clean. Battery recompute 560.9/51.8/16.1/34.2 vs stat 561/52/16/34, no missing food-DB
   rows; the macro inputs did not change in the repair (prose + cost label only). Independent
   sanity re-add of the heavy lines (chicken 2540 g, feta 635 g at 70/28 g, oil 151 g, olives 728 g
   drained at 25/15 g, artichokes 1230 g gross at 40/130 g) lands at ~7850 batch cal vs 561x14=7854
   and ~51 g protein/serving. BAND (run-dir authority): 561 in [450,700], 16 <= 40 carbs,
   52 >= 40 protein - all clear with margin. No seafood in the 13 lines; 14 servings; $4.04/serving.
2. COSTS - clean. Engine row coherent (56.49 batch, 63.34 true, 73.94 first-run, 13 lines, 0
   unpriced); shelf plausibility was checked line by line in the 06:10 audit and only the olive
   line's LABEL changed since (price unchanged, $1.97/6oz drained can - shelf-plausible). Basis
   coherence (artichokes gross/gross, olives drained/drained) re-confirmed unchanged.
   stat.cost_ps basis is wave-publish E2's hard-verify at publish time, as designed.
3. MAPPING - clean, unchanged since the full 06:10 review (13/13 bids resolve; black-olives and
   lemons rulings written; grape->cherry tomato and fresh spinach precedents checked then).
4. PROTEIN - clean. chicken claimed = derived, 2540 g, sole protein. recipes-db -DryRun green.
5. CARDS - clean. Scratch rebuild structurally identical to the live reference, JSON-LD parses,
   scaler + 3-part cost + source credit present. db\built card absent as expected pre-publish
   (wave-publish builds it). Card is the existing template verbatim, so no new 375px surface.
6. VOICE - clean on the gate (0 dash bytes). QA verdict pass with live-page anchor; substitutions
   (grape->cherry canon stand-in, garlic cloves, salt form) ruled deliberate and defensible.
7. GATES - all green legitimately. The spec-contradictions gate was returned to baseline by fixing
   the spec, not by touching the gate. Dish identity: decider ruling on record distinguishes this
   bake from the slow-cooker Mediterranean bowls and the creamy spinach-artichoke bakes; checked
   against provencal / marbella / souvlaki neighbors - distinct dishes by method and flavor base.
   State file tells one story sourced->waved, no open condition questions (selection-time band
   figure 673/18/49 was a pre-scaling estimate; final 561/16/52 also passes - not a contradiction).

## Advisories carried forward (NOT blocking, ruled so at 06:10, nothing changed)

- Two shopping stories on one card: prose still says "about three 15 oz cans" (artichokes) and
  "three 14.5 oz cans" (olives) vs engine "Buy 4 13.8oz cans" / "Buy 5 6oz drained-weight cans".
  Both plans cover the batch (45oz >= 43.4oz gross; ~27oz >= 25.7oz drained), so neither is false;
  align prose to board packages in a future writer touch.
- Artichoke display line says "drained" beside the gross-basis 1230 g figure; tidy when touched.
- Title uses "w/" ("Mediterranean Chicken w/ Marinade"), locked at selection; flagged for Brad's
  awareness, not blocking.
- For the battery owner (from QA): coverage_check.py cannot parse compound weights ("1 lb 6 oz")
  or decimal prose figures; produced three false fails at QA and will recur.

## Verdict

GO. Both blockers repaired at the correct owner, gates returned to baseline without weakening,
band re-verified against the run dir's numbers, nothing outside the repaired chain moved.
