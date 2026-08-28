GO
scope: chicken-rice-and-broccoli

# Wave 8 audit - hunt-2026-08-27-highprotein (scoped re-audit after recipe-local repair)

Auditor: recipe-batch gate, 2026-08-27. Battery report wave-8.preaudit.json (generated 2026-08-27T19:25:16,
30 checks, 1 failed). Spec mtimes re-checked at audit time and identical to what the battery recorded
(16:22:57 / 16:22:57 / 19:24:53, costed.json 14:56:05) - the report certifies the bytes that exist now.
The prior NO-GO's blocker ("{{protein}} of protein" rendering "47 of protein" in 3 places) is verified
fixed: the rebuilt card now reads "47 grams of protein a serving" (intro, line 584) and "47 grams of
protein" (portion, line 627; cost_closing, line 613).

## Verdict per category

- MACROS: clean. Battery recompute chains verified for all three; scoped slug additionally re-derived by
  hand from the spec grams and label-typical densities (~470 cal, ~47.5 g protein per serving) - agrees
  with recompute 471.9/47.3 and stat display 472/47. Band (the authority: cal 450-800, protein >= 40):
  550/42 pass, 630/40 pass (recompute 40.2, thin margin, noted), 472/47 pass.
- COSTS: clean. Engine rows internally coherent (battery, verified). Price-class spot checks on the
  scoped slug: chicken breast $2.23/lb, rice $0.57/lb, frozen broccoli ~$1.16 per 12 oz bag, parmesan
  $2.74/8oz, broth ~$1.46/32oz-equivalent - all shelf-plausible, nothing 3x off. Three tiers sum
  sensibly (23.31 batch -> 27.95 true -> 40.87 first run = true + 12.92 pantry).
- MAPPING: clean. All 14 scoped-slug bids canonical and priced; stock->broth ruled defensible by QA from
  the source's own step 4 wording ("stir in rice, spices and broth"); frozen-broccoli-florets is the
  right form (shop_smart discusses fresh-vs-frozen honestly). No null item_ids anywhere in the wave.
- PROTEIN + rotation: clean, verified by construction. recipes-db rows: beef / chicken / chicken with
  0 null item_ids across all three; heaviest-protein-by-grams re-derived by hand (beef 2117 g;
  chicken 1575 g; chicken breast 2381 g). normalize-recipe-ids NOT run (new-era rows, per 2026-07-25).
- CARDS: clean. Battery structural compare against the live al-pastor card passed for all three; scoped
  card additionally grepped: zero unexpanded {{tokens}}, intro/portion render the stat display numbers.
- VOICE: clean. Dash sweep 0 hits per slug; prose read personally on the scoped slug - warm, plain
  punctuation, no swearing. One judgment note below on "cheapest".
- GATES: clean. No gate weakened. Repaired numbers are tokens fed by the stat, so prose cannot drift.

## The one failed battery check, resolved

`recipes-db-dryrun` failed rc=1 because meal-prep\pipeline\update-recipes-db.ps1 line 120 throws
"slug list not found": the run dir contains neither specs-ready.txt nor specs-full-ok.txt, so the
script dies before printing its item_id source line. That is a HARNESS gap (battery/pipeline), not a
recipe defect. I completed the check myself:
  powershell -NoProfile -File meal-prep\pipeline\update-recipes-db.ps1 -RunDir <run> -DryRun -SpecList <the 3 wave slugs>
  -> exit 0, "skipped already-present: 3", item_id source 0/0/0 (nothing to build)
All three slugs are ALREADY rows in meal-prep\recipes-db.json (565 live vs 562 in the 14:50 feed; the
delta is exactly these three, written by the 16:22:57 prior-wave attempt that left
recipes-db.backup-20260827-162257.json). Row inspection: protein fields correct, 0 null item_ids,
per_serving equals each stat exactly, cost fields equal the engine to the cent. The repair was
prose-only, and none of the patched fields feed the db row, so the pre-existing rows are current.
FIX (owner pipeline, non-blocking): make the battery pass -SpecList (or have the daemon write
specs-full-ok.txt) so this check can run pre-GO; and wave-publish P2/P3 should expect
skip-already-present for these three.

## Repair delta, verified (chicken-rice-and-broccoli)

prose.intro_html / prose.portion_html / prose.cost_closing_html now carry {{protein}}/{{cal}}/${{cost_ps}}
tokens. Rebuilt card renders "47 grams of protein a serving for 472 calories" (intro), "same 472 calories
and 47 grams of protein" (portion), and cost_closing's ${{cost_ps}} renders as a data-tc-live-price span
(live release price at page load) - so no literal that can contradict the cost_lines' $1.66/bowl.
head.description literal "47g protein and 472 calories" is the stat's own display value. "under 500
calories" true at 472. Zero unexpanded tokens anywhere in the card body. The repair landed as promised
and nothing outside the three fields moved (spec numbers byte-identical to the battery's record).

## Non-blocking findings (all recorded in `findings`)

1. stat.cost_ps basis (scoped slug): 2.92 = cost_first_run/14 exactly; matches neither batch (1.66) nor
   true (2.00). Reader-invisible (live-price span), and wave-publish E2 re-anchors + hard-verifies this
   per slug at publish; flagged so E2's check has the observed basis. Owner: pipeline (E2).
2. Battery instrument: protein-derivation tally counts Chicken Broth grams as chicken
   (4901 = 2381 breast + 2520 broth). Harmless this wave (verified by hand); could mislabel a future
   cross-protein dish (e.g. a pork dish simmered in chicken broth). Owner: pipeline.
3. Broccoli display contradiction (scoped slug): "10 1/2 cups florets (about 2 lb 3 oz) (892 g)" -
   2 lb 3 oz is 992 g, not 892 g. Grams (892, the macro/cost basis at 85 g/cup) vs the source-density
   oz label (10 oz per 3 cups -> 992). ~2 cal/serving effect, cost line's 3x12oz bags cover either.
   Owner: writer, at leisure. The mapping itself is right - do NOT throw the resolution.
4. Stale writer note: writer_notes still carry "BLOCKING 2" about spices at 3.0x vs 3.5x, but the
   current lines are exact 3.5x (2 tsp -> 2 tbsp + 1 tsp = 7 tsp; every line re-derived at 3.5x by
   hand, chicken 2381 g exact). Flag is resolved-by-fact; note text is stale but not reader-facing.
5. Sodium note (QA's, carried forward): source specified low/no-salt stock; a salted-broth mapping may
   read slightly high on sodium. Site publishes cal/protein/carbs/fat only; note severity.
6. Voice judgment: shop_smart says "cheapest sources of calories" while the spec's own
   forbidden_prose_terms bans "cheap"; the gate passed (whole-word match). Read in context it is a
   factual price statement in the site's budget register, not the banned tone. Left standing; writer
   may soften if Brad's ban is meant to cover inflections.
7. Butter-chicken-pasta protein margin: recompute 40.2 vs gate 40. Passes; any future recost that trims
   the chicken should re-check the band.
8. Real-carb condition (prose condition, not band-encoded) verified for all three: sweet potatoes /
   pasta / rice.

## GO

No blocker. The single failed battery check was a could-not-run harness gap, completed by hand and clean.
The repair landed exactly as scoped, the rest of the wave is byte-unmoved since its last clean audit,
and every judgment item above is note-severity.
