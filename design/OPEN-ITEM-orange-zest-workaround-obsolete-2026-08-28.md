# OPEN ITEM - Orange Zest points at orange-juice, and that workaround is now obsolete

Raised by the commodity-registrar on 2026-08-28 while ruling Lemon Zest and Lime Zest.

## The row

`meal-prep\db\ingredients.json`, line ~1681:

    { "item": "Orange Zest", "bid": "orange-juice", "gpu": 31, "unit": "floz",
      "buy_pkg_g": 131, "buy_pkg_label": "each" }

Zest exists only on the whole fruit. Pricing it per fluid ounce of JUICE is a category error - it
reads a purchase (a bottle or carton of juice) that cannot produce the ingredient at all. The row
also mixes bases: unit floz with a buy package labelled "each".

## Why it looked defensible when written

There was no whole-orange id, so the juice id was the only orange-shaped thing to point at. That is
no longer true: `oranges` exists in commodities.json at line 6659.

## The fix

Repoint `Orange Zest` -> `oranges`, unit each, with a zest-yield gpu (about 6 g per medium orange,
mirroring the Lemon Zest row added 2026-08-28 at gpu 6 and Lime Zest at gpu 4).

Note this is a bid MOVE on an existing row, not a new row - so it goes through
`rebid-ingredient.ps1`, and that tool hardcodes `board` to 'weekly' (line 308, "a moved bid is on the
weekly one by definition"). Check which namespace `oranges` lives in before running it; the same
assumption is what made the tool unusable for the Ground Turkey move on 2026-08-27 and is probably
the "tool gap" that blocked the pork mint on 2676e46e.

Then audit which live specs use Orange Zest and recost them.

RESOLVED 2026-08-28. Repointed `Orange Zest` -> `oranges`, one spec touched
(slow-cooker-orange-chicken-rice-bowls).

THE PRESCRIBED gpu 6 COULD NOT BE USED, and the tool refused it rather than letting it through: the
feed serves `oranges` per LB, not per each, and gpu is "grams in one unit of the PRICED basis". The
same principle was re-derived for that basis instead - 6 g of zest should consume one orange, one
orange is 131 g, 131 g is 0.2888 lb, so gpu = 6 / 0.2888 = 20.78, with buy_pkg_g 131 ("each") as the
purchase. The yield convention is unchanged; only the unit it is expressed in.

The rebid tool's hardcoded `board` = 'weekly' was left standing here (it is `oranges`, a weekly-board
produce id), unlike the Lime Juice row where an exact sibling - `Lemon Juice`, same commodity class,
live and working - said `recipe`. Nothing in live code reads that field; every reader is under
meal-preprchive. Shipped in ca1939da.
