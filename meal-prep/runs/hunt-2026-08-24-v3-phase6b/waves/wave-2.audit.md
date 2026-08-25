NO-GO
scope: whole-wave

# Wave 2 audit - hunt-2026-08-24-v3-phase6b
Auditor: recipe-batch-auditor, 2026-08-24
Battery: wave-2.preaudit.json, generated 2026-08-24T19:34:19, 15 checks, 0 failed, exit clean.
Battery verified against current bytes: spec mtime 2026-08-24T19:32:25 and costed.json mtime
2026-08-24T19:29:45 both PRECEDE the battery's generated stamp; spec on disk still reads 19:32:25
at audit time. No stale-certification issue (the wave-1 18:16 restamp trap does not recur here).

Slugs: creamy-roasted-garlic-chicken (1 of 1)

## Verdict per category

1. MACROS: CLEAN. Full hand recompute end to end from food-macros-db label rows (563 cal sits
   within 5% of the 550 gate, so 100% recompute): batch 7880.1 cal / 894.9 P / 205.4 C / 379.5 F
   over 14 servings = 562.9 / 63.9 / 14.7 / 27.1 vs stat 563 / 64 / 15 / 27. Exact. Every gram
   derivation re-walked against the source at exact 3.5x (7 lb chicken = 3174 g, 17.5 tbsp butter
   = 245 g, 3.5 tbsp oil = 47 g, 14 tbsp flour = 109 g, 52.5 cloves = 158 g, 7 cups milk = 1715 g,
   1.75 cups parmesan = 196 g, 3.5 tsp hot sauce = 18 g).
   CONDITIONS: run.json's band is 500-650 cal AND <=40 g carb AND >=50 g protein (NOT the
   400-650 / <=35 band this audit was dispatched with - see finding C1). Verified against the TRUE
   band: 563 in [500,650] PASS; 14.7 <= 40 PASS; 63.9 >= 50 PASS. Also passes the dispatched band.
   Budget dinner PASS ($1.76/serving), 14 servings PASS, no seafood PASS.

2. COSTS: CLEAN. All three tiers re-summed by hand to the cent: batch lines 15.61+1.61+0.51+0.10+
   2.15+1.28+2.37+0.06+1.01 = $24.70; true tier (whole packages for chicken/butter/garlic/milk/parm,
   use-basis for pantry) = $28.15; first run 28.15+12.67 = $40.82. Per-line prices shelf-plausible
   for Omaha: $2.23/lb Member's Mark breast, $2.98/lb butter, $0.58/head garlic, $2.82/gal milk,
   $2.74 8oz grated parmesan. No cheap-class survivors; nothing 3x under shelf reality. 0 unpriced
   lines, so no repair-owner classification needed.

3. MAPPING: CLEAN. All 14 source lines mapped, 0 null item_ids, 0 rejected. Tabasco -> generic
   hot-sauce is a brand-to-generic same-concept substitution at exact ratio (QA concurs). Garlic
   head -> clove-basis is the same fresh food, not a form flip. Parmesan grams use the estate's own
   grated 1/4-cup=28g label row, dodging the 2026-08-15 block-vs-tub trap by design. Flour is the
   wheat AP row, not almond. Milk resolves to the estate's standing Milk row (see finding C2).

4. PROTEIN + rotation: CLEAN. chicken by construction (3174 g chicken vs 0 turkey/beef/pork);
   battery's update-recipes-db -DryRun builds every row with item_ids, 0 nulls; normalize-recipe-ids
   correctly NOT run. Rotation/Top-5 sets unchanged in kind.

5. CARDS: CLEAN. Rebuilt card is structurally identical to the live known-good reference
   (al-pastor): 334 smp- classes in both, 2 smp-cost containers in both, scaler script byte-family
   identical (the 2 U+00D7 multiplication signs in the scaler JS match the reference exactly; they
   are NOT em dashes - verified with a proper UTF-8 read: 0 real em-dash bytes), 12 print
   references, credit link to keviniscooking.com present, cost section client-rendered from
   feed.thriftycrew.com/smp-feed.json exactly as the live card does. JSON-LD parses as Recipe.

6. VOICE + copy: ISSUES FOUND - one blocking (B1). Voice itself is clean: no em/en dashes, no
   swearing, warm no-BS register, plain punctuation.

7. GATES: CLEAN. Source-QA passed on both anchors (transcription + live fetch, 14/14 lines);
   battery 15/15; wave-publish path intact; no gate weakened or bypassed.

8. IDENTITY + one story: CLEAN. No live near-duplicate: chicken-40-cloves-garlic is a braise,
   parmesan-garlic-sheet-pan has potatoes, creamy-tuscan is a different sauce - the decider's
   ruling verified against the live slug list. State (waved, wave 2), wave-2.json manifest, and
   accepted-slugs.json tell one story.

## BLOCKING issues (both recipe-local, both in writer-authored spec strings)

B1. MILK BULLET CONTRADICTS THE CARD'S OWN COST LINE.
   File: meal-prep\db\recipes\creamy-roasted-garlic-chicken.json, shop_smart[1].
   The bullet says "a half gallon covers it with room to spare and leaves you milk for the rest of
   the week" while cost_lines[5] on the same card prices "Buy 1 gallon: $2.82" and the true-shopping
   tier ($28.15) charges that gallon. 7 cups against a half gallon (8 cups) leaves ONE cup - "milk
   for the rest of the week" is false on its face. Worse, the live sibling card
   buffalo-chicken-pasta-bake, with the SAME 7 cups, tells readers the opposite: "The gallon of milk
   is the play even though you only need 7 cups. Per ounce it crushes the half gallon." Publishing
   both is a catalog self-contradiction a reader can screenshot.
   FIX (writer): rewrite the one bullet to the gallon basis the engine actually priced (the sibling
   card's framing is the house line). Writer_notes even ordered "Re-walk the bullets against
   cost_lines once the recipe costs" - that re-walk missed this. No numbers move; prose only.

B2. 140 g SALT / 28 g PEPPER FALLBACK WEIGHTS ARE READER-FACING.
   File: same spec, ingredients_display[3]/[4] and head.recipeIngredient[3]/[4].
   "Salt (Morton): to taste (140 g)" is half a cup of salt printed on a public card and shipped to
   Google in JSON-LD; no live card shows a three-digit to-taste gram (grepped: this recipe is the
   only match in db\recipes). The 140/28 are the qty-engine's no-qty house-staple fallback doubled
   by line consolidation, not measured weights - the mapper's join_fallbacks and the writer's own
   notes both flag them, and the flagged repair never happened. Macros are untouched (0-cal rows,
   verified) and the $1.01 pantry line only OVERSTATES cost, so the numbers are safe; the display is
   the defect.
   FIX (writer): drop the parenthetical grams from the two reader-facing display strings (leave the
   scaler/cost grams alone - they are conservative and feed no macro). Recipe-local.
   ROOT CAUSE (recorded, not blocking): the house-staple fallback printing its grams into display
   strings is a generator/qty-engine behavior; proposal routed to the pipeline owner.

After both fixes: scoped re-audit is sufficient - both defects are recipe-local prose in one spec;
no shared data moved. Run the battery with -Slugs creamy-roasted-garlic-chicken and re-dispatch.

## Non-blocking findings (recorded)

C1. BAND MISMATCH IN STAGE DISPATCHES (owner: orchestrator/daemon, shared). run.json says 500-650 /
   <=40 carb / >=50 protein; this audit's dispatch and the writer's notes both cite the old default
   400-650 / <=35 with no protein floor. Harmless HERE (563/14.7/63.9 passes the true band, verified
   by hand) but a 400-499 cal or sub-50 g protein recipe would be framed as in-band by every stage
   reading the default. Related: harvest.py's hard-coded 400-650 pre-filter ADMITS 400-499 cal
   candidates the run band rejects - deviations.md item 5 records only the narrower-carb direction;
   the wider-cal direction is the dangerous one. Fix: stages must read run.json's band verbatim.

C2. FAIRLIFE MACRO BASIS vs GENERIC GALLON PRICE BASIS (owner: estate convention, shared,
   pre-existing). The Milk food row is Fairlife fat-free ultra-filtered (13 g protein/cup); the milk
   bid prices a $2.82 generic gallon; the display brands the line "(Fairlife)". Standing convention
   on 10+ live recipes, mapper named it, and the recipe holds >=50 g protein even on an
   ordinary-milk basis (61.3 g). Not this wave's defect; recorded for the estate.

C3. Mapper state-history detail string truncated mid-sentence in state\creamy-roasted-garlic-chicken.json
   ("...the published card will read"). Cosmetic; owner: orchestrator.

C4. Milk grams use 245 g/cup vs the label's 240 mL serving; ~2% conservative on macros. Immaterial.

## GO / NO-GO

NO-GO. Blocks: creamy-roasted-garlic-chicken, on B1 (milk bullet vs cost line) and B2 (fallback
grams in reader-facing strings). Both recipe-local, both writer-owned prose fixes in one spec file;
no shared data implicated; scoped re-audit after repair.
