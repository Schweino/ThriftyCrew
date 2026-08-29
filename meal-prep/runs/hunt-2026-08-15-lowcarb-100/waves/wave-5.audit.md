GO
Scope: scoped re-audit of 2 slugs only (low-carb-turkey-cauliflower-mushroom-casserole, southwest-ground-turkey-cauliflower-rice-skillet) after the 300-char custom_excerpt repair. This supersedes the morning wave-5 GO for these two slugs only; the seven already-published slugs were not re-audited and their GO stands.

# Wave 5 re-audit: excerpt-length repair on 2 slugs (2026-08-29)

## Mechanical battery
Scoped run at 11:12:57, after the spec edits (both spec mtimes 11:10:57), so the report certifies the current bytes. WAVE-PREAUDIT-COMPLETE, 23 checks, 0 failed. Chains verified, not just the verdicts:

- Macro recompute vs stat (food-macros-db, no missing rows):
  - casserole: 429.3 / 35.3 / 11.8 carbs / 27.4 fat vs stat 429 / 35 / 12 / 27
  - southwest: 360.0 / 31.6 / 9.2 carbs / 20.5 fat vs stat 360 / 32 / 9 / 20
- Cost: engine rows internally coherent, 0 unpriced lines, spec fields match costed.json to the cent. stat.cost_ps basis re-derived by hand: first-run per serving (56.59/14 = 4.04; 60.18/14 = 4.30) - same basis both, wave-publish E2 re-verifies at publish time.
- Protein derivation by grams: turkey on both (1361 g; 2155 g), matches spec field.
- Voice sweep: 0 dash bytes in either spec, none in the new descriptions.

## The repair itself (the judgment items)

1. TRUTH OF THE SHORTENED CLAIMS - clean. "about 429 calories and 35 grams of protein each, under 15 grams of carbs" holds against the recompute (11.8 g carbs, 3.2 g of headroom). "about 360 calories and 32 grams of protein each, under 10 grams of carbs" holds (9.2 g recomputed, 0.8 g of headroom - tighter, but the DB is label-accurate by contract and the claim is true as computed).

2. "RED BELL PEPPER" -> "RED PEPPER" - ruled fine. The recipe buys 4 1/2 fresh red bell peppers (540 g, Red Bell Pepper (generic)). In the shipped sentence the compression cannot read as a hot pepper: cayenne is already named separately in the same sentence ("browned with cumin, coriander, paprika and cayenne"), and "red pepper" sits in the fresh-vegetable list ("folded with red pepper, shallot, spinach and riced cauliflower"). The sentence disambiguates itself.

3. SHIPPED COPY (meta_description / og / twitter) - clean. Both are complete sentences in Brad's register, plain punctuation, no dashes, no swearing. Every factual claim in the casserole copy verified against the ingredient list: roasted turkey (yes, "roasted and diced"), sour cream and mozzarella sauce (yes), "no canned soup and no flour" (no soup, no flour, no breadcrumbs anywhere in the spec). "Riced cauliflower" is true to the dish - the make_it steps cook riced cauliflower and the intro says the same.

4. LENGTH - verified exactly, not taken from the dispatch: both raw descriptions are 307 chars and both expand ({{cal}}, {{protein}} -> 3+2 digits) to 294, under Ghost's 300 cap with the same 6 chars of margin as the nearest published sibling. Catalogue sweep re-run independently: 587 specs, expanded lengths, zero over 300; these two are now the joint-longest at 294. The defect class is closed, not just these two instances.

5. CARDS - rebuilt for real. meal-prep\db\built\*.head.html and *.body.html for both slugs carry mtime 2026-08-29 11:11:28; the new phrasing ("Built for 14 servings at about ...") appears exactly once in each head card, the old phrasing ("per serving, with under") appears zero times. The head JSON-LD description carries the fully expanded text and its NutritionInformation block matches stat (360/32/9 and 429/35/12). The battery's independent scratch rebuild (11:12:57) is structurally identical to the live reference card.

6. audit-spec-contradictions - clean after the edit (SPEC-CONTRADICTIONS-COMPLETE in the 11:12:57 battery run).

## Non-blocking note (pre-existing, outside this diff)
The casserole's ingredient display line says "10 1/2 cups chopped" cauliflower while the steps and intro say riced. Same text that went GO this morning; not introduced or touched by this repair, and audit-spec-contradictions does not flag it. Worth a one-word tidy ("riced" on the ingredient line) some day, not a blocker.

## Verdict
GO. Publish these two.
