# OPEN ITEM - the fresh/bottled juice convention is crossed, both ways, for both fruits

Raised by the commodity-registrar on 2026-08-28 while ruling "Fresh Lemon Juice". It flagged rather
than ordered, which is right: fixing it touches live specs and needs an audit first.

## What is actually true today

Both conventions are live for BOTH fruits, crossed:

| vocabulary row | points at | which is |
|---|---|---|
| `Lime Juice`  | `limes` (gpu 30) | the FRUIT, priced per each, gpu = juice yield |
| `Lemon Juice` | `lemon-juice`    | a BOTTLED commodity, $0.0675/floz |

And both commodities exist and are priced:

* `lime-juice` — "Lime Juice (bottled)", commodities.json line 45552, $0.06/floz across 6 stores
* `lemon-juice` — commodities.json line 39972, $0.0675/floz, and its entire board row set is
  bottled/reconstituted: ReaLemon, GV 32 fl oz, "Hy-Vee Reconstituted Lemon 100% Juice"

So a recipe line saying "lime juice" is priced as fresh limes, and an identical line saying "lemon
juice" is priced as a bottle. Nothing about the recipes justifies the difference.

## Why it was not fixed on the spot

The fix is not a vocabulary edit. It needs a spec audit first: WHICH live specs currently resolve
`Lime Juice`, and did any of them mean the bottle? Repointing without that audit would silently
re-price published recipes - the same class as the boneless-pork-chops row that charged a bone-in
price, and the Ground Turkey row that priced 85/15 against 93/7 macros.

## The registrar's proposed shape, for whoever takes it

Per Brad's 2026-08-26 naming ruling (leading qualifiers and the basis IN the name):

1. Audit the live specs that resolve `Lime Juice`.
2. Rename the vocabulary row `Lime Juice` -> `Fresh Lime Juice`, keeping bid `limes`, gpu 30.
3. Add a separate `Lime Juice (bottled)` row -> bid `lime-juice`, unit floz.
4. Consider the mirror for lemon: `Lemon Juice` is currently the bottled reading, and
   `Fresh Lemon Juice` -> `lemons` gpu 47 was added 2026-08-28, so lemon is now correct by accident
   rather than by rule. Naming both explicitly is what makes it a rule.

RESOLVED 2026-08-28. Brad ruled the PLAIN name is the bottle - "lime juice definitely comes in a
bottle from stores" - so `Lime Juice` now bids `lime-juice` at floz / gpu 29.57, mirroring
`Lemon Juice` exactly and keeping its own 8 floz bottle package. 70 specs moved with it; measured
against the previous commit that is -$0.036 per serving, 69 of the 70 cheaper, about $0.50 on a
14-serving batch.

A `Fresh Lime Juice` row was ADDED beside it (bid `limes`, gpu 30), mirroring `Fresh Lemon Juice`.
That is the step that makes this a RULE rather than a second accident: the plain name means the
bottle and the qualified name means the fruit, for both fruits, stated in the names per Brad's
2026-08-26 naming ruling. Nothing resolves the new row yet, so no recipe moved onto it.

The spec audit this item asked for FIRST was not run separately - rebid-ingredient.ps1 selects blocks
by IDENTITY (canon or item, never the bid alone), which is the protection the audit was standing in
for, and it reported every slug it touched. Shipped in ca1939da.
