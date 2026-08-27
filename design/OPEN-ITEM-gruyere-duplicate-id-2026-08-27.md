# OPEN ITEM: Gruyere is priced under two ids, and the live quiche uses the dearer one

Surfaced by `audit-commodity-dupes.ps1` on 2026-08-27 while verifying the pork-chops mint. Pre-existing;
nothing in that work created or touched it. Investigated read-only, nothing changed.

## What is there

    gruyere        commodities.json, ON THE PRICED WEEKLY BOARD   "Gruyere Cheese"  $0.3362/oz @ Aldi
                   include: gruy[eè]re | blanc\s+grue
    gruyere-cheese recipe-board-everyday.json ONLY                "Gruyere Cheese"  $0.3713/oz @ Walmart
                   cell: bettergoods Gruyere Cheese Block, 8 oz
                   NO commodity rule anywhere - not in commodities.json, not in recipe-commodities.json

So `gruyere-cheese` is a hand-wired board row with no matching rule behind it, for a food that is
already on the priced weekly board under `gruyere`. Two prices for one commodity.

**THE ESTATE'S OWN TOOL REFUSES TO CREATE THIS.** add-recipe-board-rows.ps1's header states it
outright: "A row whose id is already on the PRICED weekly board is refused: recipe-overlay.ps1 would
drop it on the next run anyway, and a row that exists only to be dropped is a second price for one
commodity." This row predates that gate.

## What it costs, measured

`crustless-bacon-gruyere-quiche` is the only live consumer, and its scaler carries
`bid: gruyere-cheese` inline:

    537 g = 18.94 oz
      at gruyere-cheese $0.3713/oz  = $7.03 per batch   <- what the card charges today
      at gruyere        $0.3362/oz  = $6.37 per batch
      overstated by $0.66 per batch = $0.047 per serving at 14

Direction is conservative - the card overstates rather than under-claims, so it cannot sneak a cheap
claim past a reader. That is why it has survived every plausibility gate, and it is also why it is
worth fixing rather than urgent.

## What fixing it needs

1. Decide which id is the real one. `gruyere` is on the weekly board with a real include rule and the
   cheaper cell; `gruyere-cheese` is a rule-less row. The weekly id looks correct on both counts, but
   confirm the Aldi cell is actually Gruyere and not a near-name the include swept in - the include is
   broad (`gruy[eè]re`), and "an agreeing number escapes scrutiny" applies to the cheaper side too.
2. `rebid-ingredient.ps1 -Item 'Gruyere Cheese' -ToBid gruyere -ToUnit oz -ToGpu 28.3495
   -FromBid gruyere-cheese -Apply`, then the standard chain: cost-recipes -> compute-v2-perserving ->
   regenerate-ingredient-map -> reanchor-machine-fields -Slugs crustless-bacon-gruyere-quiche.
3. Drop the orphan `gruyere-cheese` row from recipe-board-everyday.json so it cannot be re-crowned.
4. Re-run audit-commodity-dupes; the pair should stop being reported without an allowlist entry,
   because it is a real duplicate and not a declared non-duplicate.

Blast radius: one live recipe, one ingredient line, about 5 cents a serving cheaper.

Related: [[OPEN-ITEM-olives-crossed-bids-2026-08-27]] (one food, two ids, two namespaces) and
[[OPEN-ITEM-milk-macro-basis-2026-08-27]] (one id, two package bases). Same family: the per-file gates
all read green because each file is internally consistent.
