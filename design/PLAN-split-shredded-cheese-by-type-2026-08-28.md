# Splitting `shredded-cheese` by type — plan and evidence

Brad ruled 2026-08-28: split the basket by cheese TYPE, for the four common types (cheddar,
mozzarella, colby-jack, mexican-blend). This is the plan and the measurement behind it.
**Nothing has been executed yet.**

## First, a correction to the earlier finding

`design/FINDING-cheddar-priced-by-mozzarella-2026-08-28.md` says the 55 live cheddar recipes are
**20.6% under**. That number is wrong; the real gap is about **0.9%**.

It was measured with `cheddar-cheese-shredded`'s own include patterns (`shred\w*\s+cheddar`,
`cheddar,?\s*shred`), which miss the word order in *"Shredded Mild Yellow Cheddar"*. Sweeping product
names directly finds real shredded cheddar at **7 of 7 stores**, crowning at **$0.1535/oz** against
the basket's $0.1521. The recipes are near-correct by luck, not by design. The case for splitting is
correctness and robustness, not recovering a large mispricing.

## What is actually in the basket — 195 products

| type | products | cheapest real shredded, /oz | stores |
|---|---|---|---|
| cheddar | 68 | $0.1535 | 7/7 |
| mozzarella | 48 | $0.1521 | 6/7 |
| mexican blend | 28 | $0.1540 | 5/7 |
| colby jack | 22 | $0.1527 | 6/7 |
| pepper jack | 6 | $0.2325 | 3/7 |
| monterey jack | 5 | $0.2462 | 3/7 |
| italian blend | 2 | $0.2325 | 2/7 |
| parmesan | 1 | $0.3333 | 6/7 |
| other blends | 15 | — | — |

The four chosen types crown within **1% of each other**; the specialty types run 50–120% higher.
Live recipes book only two names against it: `Cheddar Cheese, Shredded` (55) and
`Mexican Cheese Blend` (30).

## Two things the inventory settled

**Block vs shredded is already done.** `block-cheese` exists as its own id, priced $0.1762/oz over 5
stores, with proper block includes (`block\s+cheese`, `cheese\s+block`, `chunk\s+cheese`, …).
`shredded-cheese`'s label — *"Shredded / Block Cheese"* — is simply **stale**: its 7 includes are all
shredded, and the basket contains 162 shredded products and 0 blocks. The fix there is a relabel, not
a split.

**Three products in the basket are not shredded cheese at all**, and `string-cheese` already exists
for them:
- Member's Mark Colby and Monterey Jack Cheese **Sticks**, 36 ct.
- Sargento Colby-Jack Cheese **Sticks**, 12-Count
- Frigo Cheese Heads Mozzarella Cheese & **Salami Sticks**

## The real defect: three ids sharing one fictional row

`cheddar-cheese`, `cheddar-cheese-shredded` and `mozzarella-cheese` all already have rows in
`recipe-board-everyday.json` — and all three rows are **byte-identical**:

```
Sam's Club  0.1519  Member's Mark Part-Skim Shredded MOZZARELLA Cheese 5 lbs.
Aldi        0.2056  Happy Farms Shredded MOZZARELLA Cheese
Walmart     0.2155  Great Value FIESTA BLEND Finely Shredded Cheese
Baker's     0.2188  Kroger Sharp CHEDDAR Shredded Cheese
Hy-Vee      0.2462  Hy-Vee Finely Shredded Mild CHEDDAR Natural Cheese
Family Fare 0.2466  Our Family Part Skim MOZZARELLA Shredded Cheese
```

`derive-recipe-floors.ps1 -Apply` refreshes recipe rows from the weekly candidates, so all three
inherited the generic basket's cells. **Dropping the floor-map lines alone would not fix anything** —
each id would price off its own row, and the cheddar id would still crown on Sam's mozzarella.

Each id needs its row **rebuilt from type-correct capture evidence**, the same shape as the
`reduced-fat-cheddar` mint.

## The work, per type

| type | id | state today | what it needs |
|---|---|---|---|
| cheddar | `cheddar-cheese-shredded` (+ `cheddar-cheese`) | rule exists; row is the generic copy; floor-mapped away | widen includes (they miss "Shredded Mild Yellow Cheddar"), rebuild row from cheddar-only evidence, drop floor-map line |
| mozzarella | `mozzarella-cheese` | **no commodity rule**; row is the generic copy; floor-mapped away | write a rule, rebuild row, drop floor-map line |
| colby-jack | — | does not exist | new id, rule + row (6/7 stores) |
| mexican blend | — | does not exist; `Mexican Cheese Blend` bids `shredded-cheese` | new id, rule + row (5/7 stores), then rebid the vocabulary row |

Plus, estate-wide:
- evict the 3 stick products from `shredded-cheese` (they belong to `string-cheese`)
- relabel `shredded-cheese` to drop "/ Block Cheese"
- fence `shredded-cheese` against the four types, or order the type ids ahead of it
- allowlist the new pairs against `audit-commodity-dupes`

## Order of execution

1. Widen `cheddar-cheese-shredded`'s includes and evict the sticks — safe, needed either way, and
   without it a split makes cheddar **19% worse** ($0.1834 instead of $0.1535).
2. Build the four board rows from capture evidence, dry-run first.
3. Drop the two floor-map lines.
4. Fence the generic basket and relabel it.
5. Recost → `sync-recipesdb-cost` → propagate. Expect 55 + 30 live recipes to move by ~1%.

## Open, not settled by the ruling

What `shredded-cheese` is FOR afterwards. It keeps a vocabulary row (`Shredded Cheese`) that no live
recipe books, and after the split its remaining members are the specialty types and 15 blends. It can
stay as the catch-all for a recipe that genuinely says "shredded cheese", or be retired.

Also still open and unrelated: `gruyere` ($0.3362) and `gruyere-cheese` ($0.3713) are the same food
priced under two ids — `audit-commodity-dupes` flags it, and it predates all of this.
