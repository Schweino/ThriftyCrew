# Board cells that price live recipes with no product behind them

The wave-11 audit listed "milk empty item/size rows" as a pricer data-quality item. Measured, milk
is the harmless case and something else is not. **Nothing has been changed.**

`add-recipe-board-rows.ps1` refuses a cell with no item — *"identity travels with the price or not at
all"* — so every row below predates that tool.

## Two rows where NO cell has an item or a size

| id | unit | cells blank | on the live board? | what the feed serves |
|---|---|---|---|---|
| `milk` | each | 6/6 | **dropped** | the weekly row, gallon $2.81 |
| `red-bell-pepper` | each | 6/6 | **survives** | each $0.98 Walmart |

`milk` is dead weight: the weekly board owns the commodity, recipe-overlay drops the recipe row, and
nothing prices off it. Worth deleting, but it is not hurting anyone. Its unit (`each`) is also wrong
for milk, which is a hint about how it was made.

`red-bell-pepper` is the real one. **54 live recipes price off it, $169.52 of util cost**, and not
one of its six cells names a product or a size:

```
Sam's Club 0.83   Walmart 0.98   Aldi 1.00   Baker's 1.66   Hy-Vee 1.69   Family Fare 2.50
```

### Nothing corroborates it

Sweeping every capture on disk against `red-bell-pepper`'s own include list finds **no red bell
pepper at any store**. Fresh single peppers evidently do not appear in the ad/regular feeds. The
numbers are *plausible* for a bell pepper — this is not a proven mispricing — but nobody can check
them, and `aisle-test` and `audit-match-soundness` both need a product name to reason about a cell.

The feed does carry a Walmart product URL for the winning cell, so the crown is traceable to an item
id even though the board cell is not. The other five are traceable to nothing.

### And the rule finds a can of corn

`red-bell-pepper`'s include is:

```
\bred\b[^.]*bell\s+pepper
bell\s+pepper[^.]*\bred\b
```

The first matches **`Green Giant SteamCrisp Mexicorn Whole Kernel Corn with Red & Green Bell
Peppers`** — `\bred\b[^.]*bell\s+pepper` spans "Red & Green Bell Pepper". That canned corn is the
**only product `red-bell-pepper` claims anywhere in the identity graph.** Not one actual red pepper.

No live price is wrong from it: the corn came from a quarantined Baker's capture and never reached a
board cell, and `bell-peppers`' five live cells are all real peppers. But the rule is what it is, and
the day that product appears in a clean capture it will claim it.

## The tail

29 further rows have *some* blank cells — `1-3-fat-cream-cheese` (3/6), `apple` (3/6),
`frozen-chopped-spinach` (3/5), and 26 more. Mixed: some survive on the live board, some are dropped.

## What this needs

1. **A capture pass for `red-bell-pepper`** across the seven stores — item, size, price per cell — so
   the row can be rebuilt through `add-recipe-board-rows` with identity, the way the four ids minted
   today were. This is pricer work; it cannot be done from data on disk.
2. **A tighter include**, so `red` and `bell pepper` must belong to the same product rather than
   merely appear in the same name. `[^.]*` is doing no fencing at all here.
3. **Delete the dead `milk` recipe row** (or rebuild it with identity), and decide whether the
   29-row tail is worth a sweep or is simply what a pre-tool board looks like.
