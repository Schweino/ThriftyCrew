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

Brad's call. Not started.
