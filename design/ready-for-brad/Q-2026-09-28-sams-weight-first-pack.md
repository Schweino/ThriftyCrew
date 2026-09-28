# Q: how should a Sam's "weight, N pk/ct" row be read - N pieces of that weight, or the pack total?

**Where this came from:** queue item `2026-09-25-0cefa4`, measured against today's board.

## The situation

Sam's Club writes a lot of its multipack cards the same way: `"<weight>, N pk"` - for example
"1 lb., 6 pk." or "40 oz., 4 ct." That phrase is genuinely ambiguous. Sometimes it means "N
pieces, each of that weight" (a 6-pack of 1 lb boxes). Sometimes it means "the pack as a whole
weighs that much, split into N pieces" (a 40 oz box split into 4 servings).

We measured 639 rows across 24 days of Sam's data where we can check Sam's own printed unit
price against both readings:

- **616 of 639 (96%)** match the "N pieces of that weight" reading (what the engine already uses).
- **23** match the "pack total" reading instead.
- The remaining rows have no printed unit price to check against, or are priced per-each already.

**The catch: Sam's own unit price is not a reliable tiebreaker.** Some of the 23 "pack total"
matches are actually Sam's making the SAME mistake we'd be worried about - dividing by one piece
when the pack is really several pieces:

- Barilla Pasta Rotini & Farfalle Variety Pack, "1 lb., 6 pk." - $8.52 at Sam's own 53.3¢/oz,
  which is one 1 lb box, not six ($8.52 / 6 = 8.9¢/oz for the real per-box price)
- Sunlee Coconut Milk, "13.5 oz., 6 pk." - same shape
- Nate's Honey, "16 oz., 2 pk." - same shape

But others in that same 23 are genuinely pack totals, correctly:

- Cafe Bustelo Ground Coffee, "40 oz., 4 ct." - $21.18, a real 40 oz total split 4 ways
- Hormel Black Label Fully Cooked Bacon, "10.5 oz., 72 ct."
- Ball Park Tailgaters Brat Buns, "32 oz., 12 ct."

So there is no mechanical rule - not the phrase, not Sam's own unit price - that tells these
two groups apart today.

## What's actually on the board right now

**Nothing is wrong.** Every genuine pack-total row on a weight-priced commodity is already
withheld (Cafe Bustelo shows WITHHELD-SHIP-ONLY / WITHHELD-UNPROVEN-CHANNEL). The one row that
was live and wrong (Red Baron pizza, misread as 69.60 oz for a single 5.8 oz piece) is already
blocked by a known-wrong ruling from 2026-09-19. Zero cells are exposed to this ambiguity today.

## The recommendation

**Option D - a targeted withhold, not a guess.** Where the weight actually matters (a
weight-priced commodity, or the frozen-pizza piece-size floor), a weight-first pack row whose
Sam's-printed unit price disagrees with BOTH what we'd compute AND what we'd get from the other
reading gets withheld as a basis conflict rather than guessed either way. Count-priced each-item
rows are untouched - this only applies where a wrong reading could silently misprice a cell.

This keeps today's zero-exposure state and stops the class in front of it, without needing a
mechanical rule that doesn't actually exist for this pattern. It's a smaller ask than picking A
(always read as N pieces) or C (always read as pack total) - both of which would misprice a real
share of rows the measurement above found.

## If you'd rather pick something else

- **Option A** (always N pieces): would misread the 23 pack-total rows if any of them ever
  becomes the cheapest cell for their commodity.
- **Option C** (always pack total): would misread the 616 piece rows the same way, at far
  larger scale.
- Either requires accepting some wrong prices will occasionally reach the board with no code
  changed beyond picking the direction.
