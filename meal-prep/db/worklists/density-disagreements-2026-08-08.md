# Density vs food-DB disagreements (audit-schema-constraints, 2026-08-08)

Twelve items where `db\densities.json` and `food-macros-db.json` state different grams for the SAME
household unit, after normalising the food DB by `serving_qty`. densities.json drives LABEL derivation;
food-macros-db drives MACRO computation - so a gap means the shopping line says one amount and the macros
were computed from another.

These are NOT sweepable. The estate's rule (repair-measure-vs-grams) is that deciding a gram figure needs
the SOURCE, not arithmetic. Each row below needs one adjudication, cheapest-blast-radius last.

| item | densities | food DB | gap | live recipes |
|---|---|---|---|---|
| Garlic | 5 g/clove | 3 g/clove | 67% | **377** |
| Seasoned Black Beans | 172 g/cup | 260 g/cup | 34% | 34 |
| Sweet Whole Kernel Corn | 165 g/cup | 250 g/cup | 34% | 32 |
| Ranch Seasoning Mix | 7 g/tbsp | 9 g/tbsp | 22% | 8 |
| Canned Black Beans | 172 g/cup | 260 g/cup | 34% | 5 |
| Canned Pinto Beans | 172 g/cup | 260 g/cup | 34% | 1 |
| 1/3 Fat Cream Cheese, Fresh Mint, Sugar, BBQ Sauce (Sugar Free), Italian Seasoning, Taco Seasoning | small | small | 7-30% | few |

Notes toward adjudication:
- **Garlic** is the open `garlic gpu` item already tracked from the burrito batch. A USDA clove is ~3 g;
  the board's own Kroger netWeight work put the priced clove at 42.6 g per head. Whichever wins must be
  applied to BOTH files at once.
- The **canned bean / corn** cluster is almost certainly the drained-vs-undrained split (172 g drained vs
  260 g including liquid) - the r300 run hit this as "drained-can pricing". If so, the fix is to state
  which basis each file means, not to average them.

Ratcheted in `db\schema-constraint-baseline.json`, so these stay visible daily without paging, and any
THIRTEENTH disagreement fires immediately.
