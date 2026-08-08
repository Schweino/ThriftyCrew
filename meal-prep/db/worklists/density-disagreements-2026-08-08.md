# Density vs food-DB disagreements (audit-schema-constraints, 2026-08-08)

Eight items where `db\densities.json` and `food-macros-db.json` state different grams for the SAME
household unit, after normalising the food DB by `serving_qty`. densities.json drives LABEL derivation;
food-macros-db drives MACRO computation - so a gap means the shopping line says one amount and the macros
were computed from another.

## Corrected 2026-08-08 - four "findings" were the correct answer

The first version of this list had 12 rows. `db\densities.json` already settles four of them in its own
`basis_reconciliation_2026_08_07` note, with sources: the canned-bean and corn cups (172/165 here vs
260/250 implied by the labels) are **DRAINED yields against AS-PACKED label servings** - two different
measurements of two different things, "and merging them would be the error, not the fix". Fresh Basil and
Green Onions are the same story in produce. Rice was checked and is settled at 180 g/cup on BOTH sides.

Those are now an explicit exception list in the auditor, derived from that note rather than typed
independently. A guard that reports a settled adjudication is not finding a defect, it is re-litigating a
decision someone already made with sources - and it would page daily forever.

## The eight that remain

| item | densities | food DB | gap | live recipes | note |
|---|---|---|---|---|---|
| **Garlic** | 5 g/clove | 3 g/clove | 67% | **377** | the open `garlic gpu` item; USDA clove ~3 g, board's Kroger netWeight put the priced head at 42.6 g |
| Ranch Seasoning Mix | 7 g/tbsp | 9 g/tbsp | 22% | 8 | |
| Taco Seasoning | 2.7 g/tsp | 2.5 g/tsp | 8% | few | near tolerance |
| 1/3 Fat Cream Cheese | 15 g/tbsp | 14 g/tbsp | 7% | few | near tolerance |
| Italian Seasoning | 1.4 g/tsp | 1 g/tsp | 40% | few | both near-zero macro |
| BBQ Sauce (Sugar Free) | 17 g/tbsp | 16 g/tbsp | 6% | few | near tolerance |
| Sugar | 4.2 g/tsp | 4 g/tsp | 5% | few | near tolerance |
| Fresh Mint | 1.6 g/tbsp | 1.5 g/tbsp | 7% | few | near tolerance |

**Only Garlic is worth a decision.** Six of the eight are within a gram on near-zero-macro items, which
densities.json's own readme already calls macro- and cost-irrelevant; the honest fix for those is probably
to widen the tolerance for spice-class items rather than to edit numbers. Ranch Seasoning Mix is the only
other one above rounding.

Ratcheted in `db\schema-constraint-baseline.json`: these stay visible daily without paging, and a NINTH
disagreement fires immediately.
