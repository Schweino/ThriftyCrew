NO-GO
scope: whole-wave
run: hunt-2026-08-27-highprotein  wave: 10  audited: 2026-08-28
battery: wave-10.preaudit.json (generated 2026-08-28T07:53:41, 23 checks, 3 failed) - chains verified, two of the three fails re-derived and cleared, one stands

## Verdict

NO-GO on ONE blocker, and it is shared, not recipe-local: the audit-spec-contradictions
gate is red (exit 1, PHANTOM 3 vs baseline 0) and wave-publish must not run against a red
gate. Both recipes themselves are clean: every macro and cost chain verifies to the cent,
both sit inside the enforced band (cal 450-800, protein >= 40), mappings are sound on
precedent, cards rebuild faithfully. The other two battery fails are a rounding artifact
and a battery harness bug, both re-derived clean by hand.

## Blocker

### B1. Shared gate red: audit-spec-contradictions PHANTOM 3 vs baseline 0 (shared, pipeline + shared-data)
Re-ran it myself: exit 1, same three phantoms wave 9's audit blocked on (R5 there):
- blackened-chicken-with-mango-salsa "salsa": CHECKER FALSE POSITIVE. The spec's step 1
  composes the mango salsa entirely from ingredient-line items (mango, avocado, cilantro,
  red onion, salt, pepper, olive oil, lime juice); later steps reference that composed
  component by name. The dish CAN be made as shopped. Fix the CHECKER to understand
  composite components named in a step (owner: pipeline). Do NOT rephrase the steps to
  dodge the word - that degrades correct copy to appease a false positive - and never
  touch the baseline.
- beef-rendang-rice-bowls "coconut oil" and mediterranean-chicken-w-marinade "cooking
  spray": catalog specs OUTSIDE this run (neither is in this run's state dir). Owner:
  shared-data.
Until this gate exits 0, no wave in the estate publishes. Nothing either wave-10 slug's
spec can change fixes it.

## Battery fails re-derived clean (not blockers)

- cost-engine-consistency, blackened, "Salt costs nothing (0)": 1 g of salt on basis
  board:salt:walmart, starter 26oz/737g at $0.94 -> $0.94/737 = $0.001275/g; 1 g
  cent-floors to $0.00. The line IS priced (basis + starter present), and the batch sum
  including it re-adds by hand to $41.33 exactly. Rounding artifact, matches the wave-9
  ruling. Battery should tolerate priced sub-cent lines. Owner: pipeline, non-blocking.
- recipes-db-dryrun "never printed its item_id source line": the tail names its own cause
  this time, as the battery's comment hoped - the harness passed relative forward-slash
  '-RunDir meal-prep/runs/hunt-2026-08-27-highprotein' into Start-Job and the child threw
  'RunDir not found' before doing anything. Same path bug as waves 8 and 9. Re-ran with
  absolute -RunDir, -SpecsDir meal-prep\db\recipes, -SpecList waves\wave-10.preaudit-slugs.txt:
  RC=0, both recipes build and parse-validate, item_id source: ingredient-map 23 rows,
  scaler-bid fallback 5 rows (Bone Broth, Blackened Seasoning->cajun-seasoning, Frozen
  Cilantro Lime Rice, Mexican Blend Shredded Cheese, Canned Black Beans - all same-concept),
  null 0 rows. Clean. Wave-preaudit should Resolve-Path RunDir before the job. Owner:
  pipeline, non-blocking.

## Verified clean this pass (chains checked, spot work re-derived)

- MACROS vs the enforced band (cal 450-800, protein >= 40, carbs any):
  - blackened: hand-recomputed the ENTIRE chain from food-macros-db rows x stated grams
    (11 lines, e.g. chicken 2381g / 112g-serving x 25g protein = 531.5g): per-serving
    620.2 cal / 43.6 p / 61.9 c / 22.2 f. Matches battery to the decimal and stat 620/44/62/22
    within honest rounding. Protein 43.6 >= 40 - tightest number in the wave, verified by hand.
  - chili: battery chain 541.6 / 47.4 / 29.8 / 24.3 vs stat 542/47/30/24, coherent. Both in band.
- COSTS: both batch sums re-added line by line to the cent (chili 17 lines -> 28.49;
  blackened 11 lines -> 41.33). Three tiers derive: blackened true 46.82 = buys 44.89 +
  bulk utils 1.93; pantry add 11.89 = starters 13.82 - utils 1.93; first run 58.71 = 46.82
  + 11.89. Chili 28.49 / 37.68 / 42.89 same construction. Price classes spot-checked
  against shelf reality: chicken $2.23/lb, bacon $3.96/lb, GV spice jars $0.70-1.61,
  beans ~$0.89/can, mango $0.75/ea, avocado $0.58/ea - all plausible, no 3x survivors.
- Cajun-seasoning starter ($0.87 for two 2.5oz shakers) interrogated because it undercut
  its shelf-mates: the live price table (price-table-2026-08-26.csv) carries
  cajun-seasoning at $0.1733/oz Walmart -> 5 oz = $0.866 ~ $0.87, util 2.61 oz = $0.45.
  Board-real, cleared.
- MAPPING: lime juice -> limes (2026-08-27 precedent), blackened seasoning ->
  cajun-seasoning (same-concept, wave-9 ruling stands), Mexican blend -> shredded-cheese,
  bone broth, canned black beans: all same-concept. The one dropped line (Primal Kitchen
  Avocado Lime Dipping Sauce) is a confirmed optional garnish, dropped with a written
  reason and fenced by forbidden_prose_terms. Every null carries a reason.
- PROTEIN + rotation: chili tally chicken 1588g vs pork 175g (the bacon) -> chicken;
  blackened 2381g sole -> chicken. Both claimed=derived. Dry run confirms 0 null item_ids.
- CARDS: rebuilt bodies structurally identical to the live reference (battery), and I
  byte-checked the blackened rebuild: three "44g/44 grams" protein claims, zero stray
  "6g", 12 ingredient lines render, print button present, four "620" calorie mentions,
  3-part cost section, source credit to easyeatsdietitian.com. Chili card: pass per battery
  structural compare.
- VOICE: 0 dash hits both specs (battery + my read of the full blackened spec prose).
- CONDITIONS: BSCB is the main protein in both; real carb source in both (cilantro lime
  rice 1984g; beans + corn + tomatoes); 14 servings; no seafood; $2.03 and $2.95 per serving.
- Shared gates: store-integrity, vocab-integrity, unbid-ingredients, cost-plausibility,
  cost-line-coverage, P8 endpoint provenance + feed liveness (565 recipes, 07:13:42) all
  green with markers.

## Non-blocking findings (fix while the wave is blocked anyway)

- N1 STALE QA-FAIL ARTIFACT, blackened (pipeline/orchestrator): qa\blackened-...-salsa.json
  says verdict FAIL (mtime 07:21:59, 43s NEWER than the repaired spec at 07:21:16),
  claiming intro/portion/head say "6g protein". That claim is false against every current
  byte - spec, rebuilt body and head all say 44, zero "6g" anywhere - and the QA's own
  note records its dossier rendered 0 ingredient lines and a truncated step, i.e. it
  judged a corrupted dossier, not the spec. Content verified clean by me. BUT the freshest
  QA artifact on disk contradicts the state chain (qa-passed -> waved), and wave-publish
  P2/P3's one-story check plus a failed publish re-buying this audit make that a live
  risk. Re-run recipe-source-qa against the current built card so the artifact and the
  state tell one story BEFORE the publish attempt.
- N2 RICE PACKAGE PROSE SELF-CONTRADICTION, blackened (writer): ingredients_display,
  head.recipeIngredient and shop_smart say "seven 10 oz bags" of frozen cilantro lime
  rice; the cost line says "Buy 9 8.5oz pouches: $17.73". The 10-oz bag is an invented
  package size - the board pouch is 8.5oz/241g. Grams (1984) and costs are right; the
  same fact is stated twice and disagrees. Carried from wave-9's notes, spec unchanged.
  Reword the need to grams/cups and let the buy line own the package.
- N3 SALT LINE MICRO-WOBBLE, blackened (writer): display line says "to taste (1 1/2 g,
  about 1/4 tsp) (1 g)" - 1.5 g and 1 g in one line. Trivial, ride along with N2.
- N4 EXTRACTION FIDELITY NOTE, blackened: source's "1 Bunch Fresh Cilantro" (flagged by
  the extractor as reading high for 4 servings) scales faithfully to 3.5 bunches / $6.25 -
  second-costliest line in the recipe. Faithful to source, QA ruled scaling consistent;
  no action, recorded so the repair cycle knows it was seen.

## Repair routing summary

| finding | slugs | kind | owner | blocking |
|---|---|---|---|---|
| B1 spec-contradictions gate red (1 checker FP + 2 non-run specs) | shared | gate | pipeline + shared-data | yes |
| salt $0 cent-floor battery tolerance | blackened | battery-tolerance | pipeline | no |
| dryrun harness relative-path bug | shared | battery-bug | pipeline | no |
| N1 stale QA-fail artifact vs qa-passed state | blackened | one-story | pipeline/orchestrator | no |
| N2 rice 7x10oz vs 9x8.5oz prose | blackened | prose-drift | writer | no |
| N3 salt 1.5g vs 1g display | blackened | prose-drift | writer | no |
| N4 cilantro scale-faithful cost note | blackened | dish-quality note | none | no |
