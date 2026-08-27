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

---

## Measured 2026-08-27, after a peer session asked whether "Black Olives" duplicated "Olives"

It does not, and checking answered a bigger question. The three ids are distinct on the board:

    black-olives   -> "Black Olives (canned, ripe)"     Aldi $0.265/oz
    green-olives   -> "Green Olives (stuffed)"
    olives         -> present in recipe-commodities.json and out\recipe-board-everyday.json,
                      ABSENT from commodities.json

So `Black Olives -> black-olives` (added this morning) points at its own priced commodity and is a
genuine third food, not a near-name of either existing row. That one is fine.

**THE CROSSED PAIR HAS 24 LIVE CONSUMERS, WHICH IS THE PART THAT MATTERS.** 24 live specs carry the
vocabulary name `Olives`, and that row points at bid `green-olives`, whose board commodity is
literally "Green Olives (**stuffed**)". Any of those 24 that meant ripe black olives - a Mediterranean
or Tex-Mex dish calling for "olives" usually does - is being priced as stuffed green olives, and the
reader's buy line names the wrong jar. Meanwhile `Green Olives` points at `olives`, an id that is not
in commodities.json at all.

Sharpened, the question is no longer "are the two rows swapped" but:
1. Which food do those 24 live recipes actually call for? That is a read of their prose and sources,
   not a lookup.
2. Is `olives` a live commodity or a stale id kept alive only by these rows? It resolves in two files
   and is missing from the third.
3. What do the 24 cost per serving if each is repointed at the food it actually means?

Nothing here was changed. The blast radius is 24 published recipes' prices.
