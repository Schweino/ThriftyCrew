# Q-2026-09-26-form-style: is a different form or style of a food the same food?

**The question.** Under your 2026-09-22 ruling (no ingredient priced as a different food), may a recipe line be
priced by a different FORM (pasta shape, crushed vs chunk pineapple, tortelloni vs tortellini) or a different STYLE
(marinara vs plain pasta sauce, cajun vs creole, salsa verde vs green chile sauce, chili oil vs chili crisp)?

Raised by queue item 2026-09-22-5a9676 (residual), owned by 2026-09-25-f9c8ce; supersedes Q-2026-09-25-pasta-shape.
Source: `grocery/triage-plans/plan-2026-09-26-2.json`, open_questions_for_brad.

## What I checked

Read from `ops/out/ingredient-identity-cell-baseline.json` (the day-one mark of identity check (d), recorded
2026-09-26 from comparison-2026-09-23 plus the recipe board). It holds 86 cell keys. The form and style lines
among them add up to **51 of 86**, which matches the triage number:

| Ingredient line | Cell keys | Kind |
|---|---|---|
| Pasta Shells | 7 | form |
| Fettuccine | 7 | form |
| Ziti, Spaghetti, Rotini, Orzo | 5 each (20) | form |
| Pineapple Chunks (priced by crushed) | 3 | form |
| Cheese Tortellini (priced by Priano tortelloni) | 1 | form |
| Marinara Sauce | 5 | style |
| Traditional Pasta Sauce | 1 | style |
| Green Chile Sauce (priced by salsa verde, 4 stores) | 4 | style |
| Enchilada Sauce (Las Palmas red chile sauce) | 1 | style |
| Chili Crisp (Lao Gan Ma fried chili oil) | 1 | style |
| Cajun Seasoning (Tony Chachere's Creole, Fareway) | 1 | style |

So 38 keys are form and 13 are style. The other 35 keys belong to other items (several already fixed, 7 board
wrong-product candidates, 3 regex looks).

**Not re-measured:** the triage's recipe count (88 of 570 not-held recipes carry at least one such line; 42 pasta
shape, 21 marinara, 13 cajun, 9 enchilada, 4 pineapple, 3 tortellini, 2 chili crisp, 1 green chile). That needs the
costing chain; I quote it from the plan.

## Options

- **A. Forms are the same food, styles are too (keep today's pricing).** Nothing moves, nothing is held. A marinara
  recipe keeps pricing from plain pasta sauce, which contradicts the 09-22 ruling for anything that tastes different.
- **B. Forms are the same food, styles are different foods.** Extend your 2026-09-06 form rule T2 to recipes: when
  the unit is weight or volume, a different shape or cut of the same food prices the line, recorded as a reviewed
  same-food pair (38 keys stay, no price moves). Each style gets its own commodity, the way zucchini and pepperoncini
  were split on 09-26; a recipe whose style no Omaha store carries is held until a capture lands. Up to 46 recipes
  reprice or hold (triage count).
- **C. Both are different foods.** Up to 88 recipes move or hold, and pasta alone needs five or six new commodities
  with captures before 42 recipes can go back live.

## Recommended (best long-term): B

A shape of dry pasta or a cut of canned pineapple is the same food by weight; a sauce style or a seasoning blend is
a different recipe ingredient with a different taste and a different price. B matches both rulings you already gave
(form rule T2 and the 09-22 no-substitute rule), keeps the 38 form keys honest with a recorded review instead of a
silent stand-in, and only holds recipes where the stand-in really is a different food.

## What executes once ruled

- **A:** the 51 keys are marked reviewed in the identity check mark; queue f9c8ce closes.
- **B:** 38 reviewed same-food records for the form pairs (identity_same_as, as 5a9676 did for its twenty); new
  style commodities (marinara, enchilada sauce, cajun seasoning, chili crisp, green chile sauce) through the
  commodity-registrar, then a board rebuild and the recost chain; recipes with no Omaha style capture held through
  `hold-recipe.ps1`; the mark is tightened after the rebuild.
- **C:** B's style work plus five or six pasta-shape commodities and their captures before 42 recipes return.

## Ruling (2026-09-26, Brad in chat)

Q-2026-09-26-form-style: **"B: shape same, style own"** - a different pasta SHAPE is the same commodity; a different
STYLE (cajun vs creole, salsa verde vs green chile, sauce styles, chili oil etc.) is its own.

## Ruling on whole-grain pasta (2026-09-26, Brad in chat)

Asked whether whole-grain pasta (the 6 keys priced by Kroger 100% Whole Grain Penne Rigate at Baker's) is the same
food as regular pasta under "shape same, style own". Brad: **"Separate food"** - whole grain is a different grain, so
whole-grain pasta is excluded from the regular pasta cells, the same way a style is.

Executed the same day through the mechanism the form/style ruling used: `grocery/commodities.json` pasta excludes
`\bwhole[\s-]*(?:grain|wheat)\b`, with MUST FIRE / MUST NOT FIRE / CLEAN TWIN cases in
`grocery/test-commodity-rules.ps1`. Paired scratch rebuild (compare-deals, same inputs, old rules vs new): 1 of 2,807
priced cells moved - pasta at Baker's, Kroger 100% Whole Grain Penne Rigate to Kroger Penne Rigate Pasta, both
$0.0831/oz; the pasta crown (Aldi $0.0591/oz) did not move. No whole-grain pasta commodity was minted, because no
recipe line names one.

The green chile sauce style from the ruling above now has its own commodity, `green-chile-sauce`, with the capture
term "green chile sauce". The recipe line stays on salsa verde until a store fetch prices it.
