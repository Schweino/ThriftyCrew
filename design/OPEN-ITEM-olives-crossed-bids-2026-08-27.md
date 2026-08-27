# OPEN ITEM: the Olives / Green Olives rows point at each other's commodity ids

Found 2026-08-27 while adding vocabulary rows for run hunt-2026-08-27-ten. Logged, not fixed, on
Brad's ruling. Nothing in that run depends on it.

## What is there

`meal-prep\db\ingredients.json`:

    {"item": "Olives",       "bid": "green-olives", "gpu": 28.3495, "unit": "oz", "board": "recipe",
     "buy_pkg_g": 170, "buy_pkg_label": "6oz can"}
    {"item": "Green Olives", "bid": "olives",       "gpu": 28.3495, "unit": "oz", "board": "recipe",
     "buy_pkg_g": 163, "buy_pkg_label": "5.75oz jar"}

The names and the ids are swapped relative to each other. Both ids are real and both are priced, so
nothing dangles and no gate complains - which is exactly why it has survived.

The package labels are the tell that this is a crossing rather than a naming choice: a 5.75 oz JAR is
the classic green-olive pack and a 6 oz CAN is the classic ripe/black-olive pack, and each row is
carrying the other's package.

## Why it was not fixed here

1. It is not this run's business. A recipe run that quietly re-points commodity ids is doing estate
   surgery under cover of shipping dinners.
2. Live specs already cost against these bids INLINE, so unswapping the rows moves published prices.
   That is a rebid-ingredient.ps1 + recost + propagate operation with a blast radius that has to be
   measured first, not a one-line edit.
3. Provenance is never a merge tiebreak (Brad, 2026-08-26), so "whichever row is older is right" is
   not an argument available here. Somebody has to look at what the two ids actually price.

## What answering it needs

- Which id prices which food on the live board - `green-olives` and `olives` both exist in
  `grocery\out\comparison-*.json`; read what each one's captured products actually are.
- Which live specs carry each bid inline, and what their per-serving cost does if the rows are
  unswapped. `Black Olives` was added 2026-08-27 pointing at the distinct `black-olives` id and is
  NOT part of this question.
- Then, if it is a genuine crossing: rebid-ingredient.ps1 for each affected item, the standard
  cost chain, and a note in the vocabulary rows saying what was corrected and when.
