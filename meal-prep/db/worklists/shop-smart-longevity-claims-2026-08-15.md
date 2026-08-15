# shop_smart longevity claims that outrun the package — 2026-08-15

Four hand-written `shop_smart` sentences tell a reader a package lasts several/many batches when the
package covers fewer than three. **These are the only READER-FACING instances of this defect**: the
`cost_lines` half of it (589 lines, 360 specs) never reaches a card — `build-card2.ps1` renders the cost
section from `db\costed.json`, not from `spec.cost_lines` — and was repaired mechanically by
`pipeline\repair-bulk-buy-line.ps1`. These four are prose in a writer's voice, so they are listed for a
person rather than rewritten by a script.

Coverage = `pantry_pkg_g / grams_used`, i.e. how many batches ONE package covers, measured against
`db\costed.json` on 2026-08-15.

| coverage | recipe | ingredient | the sentence as it ships |
|---|---|---|---|
| **1.01** | baked-sweet-and-sour-chicken-rice-bowls | Cornstarch | "Cornstarch, sugar, ketchup, and vinegar are all pantry cheapos that **last many batches**…" — the cornstarch box covers barely one |
| **1.35** | beef-chow-mein-noodles | Oyster Sauce | "Oyster sauce looks expensive per bottle, but it **lasts several batches** in the fridge." |
| **1.92** | korean-turkey-japchae | Sesame Oil | "Sesame oil is the signature flavor and one bottle **lasts many batches**." |
| **2.45** | mississippi-pot-roast-bowls | Pepperoncini | "A jar of pepperoncini **lasts several batches** and the brine is half the flavor…" |

The 2.45 case is the mildest and arguably survives as written; 1.01 and 1.35 do not.

`country-captain-chicken` is worth reading as the model for the fix — its shop_smart already does this
correctly ("covers this batch and most of a second… Not several batches, but the box is not a
one-and-done either") and it was that paragraph, sitting beside a cost line claiming the opposite, that
exposed the whole class.

## Not in this list, deliberately

A fifth candidate was rejected on inspection: `brazilianstyle-pork-ribs-bowls` says "Mustard,
Worcestershire, vinegar, and honey are all pantry bottles that last several batches, so the recurring cost
of this recipe is basically pork and rice." The matcher attached it to **Rice** (0.80 batches) because the
word appears in the sentence's tail. The claim is about the four bottles, not the rice, and it is true of
them. A sentence naming several ingredients cannot be scored against whichever one it happens to mention
last — the same refusal `Get-HeadQtyMismatch` makes for a head line carrying two quantities.

## Why no gate covers these

`BUY-COVERAGE` in `pipeline\spec-contradiction-lib.ps1` reads `cost_lines`, where the sentence has a fixed
machine-written shape it can parse and compare. Free prose has no such shape: deciding which ingredient
"one bottle" refers to is the ambiguity above, and a gate that guesses would fire on the Brazilian ribs
case every run. Four findings for a person beats a standing false positive nobody reads.
