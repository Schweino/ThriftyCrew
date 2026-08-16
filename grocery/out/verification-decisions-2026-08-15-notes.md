# Adjudication standard applied, 2026-08-15 sample

Read this before comparing this run's rate to another run's. The grading standard is the single
biggest source of run-to-run movement, bigger than the board itself (see the 2026-07-30 vs
2026-08-08 gap: 16.5% -> 33.1% on a stricter reading of "cheapest", with the intervals overlapping).

## Coverage
100 of 100 sampled cells answered by the blind store agents. 0 unverifiable. This is the first run
where the denominator was the full draw; earlier runs returned 20-24 because the worklist asked a
blind verifier for a verdict only a sighted one can give. Fixed by adjudicate-blind-findings.ps1.

## Rules applied

**A live markdown is not a board defect.** Where the store showed a sale and the board held the
regular price, the board was scored `ok`. Fareway lemons: board 0.99/each, shelf 0.88 on an 11%
markdown against a 0.99 regular. Board is right.

**Flavor variants of the same brand/size/price are `ok`.** The blind agent picks one SKU off the
shelf; the board picked its sibling at the identical price. Not a defect, just a different pick from
a tied set. Scored ok: Aldi almond milk (Friendly Farms vanilla vs original unsweetened, both 64 fl
oz $2.29), Baker's body wash (Suave 18 fl oz $3.29 either way), Fareway shampoo (Suave 22.5 fl oz
$1.97 either way), Walmart toaster pastries (Great Value 12 ct $2.03, fudge vs cherry).

**A near-tie inside 1% is `ok`.** Baker's dried oregano: board's Kroger shaker 1.6959/oz vs the
blind pick's Tampico 1.6900/oz, a 0.4% gap. Calling that a defect measures noise.

**`ok` requires CHEAPEST, so not-cheapest IS a defect** - but it is reported as its own subclass
below, because it is a different fix from an identity failure and the raw count reads as far more
alarming than it is. Scored `wrong-price`, NOT filed to the known-wrong blocklist.

**Multipack bundles are `wrong-size`.** The board's stated basis is the in-store shelf price. Three
Walmart cells derive their per-unit from an online multipack listing, which is not a shelf price:
red wine vinegar "(2 pack) Star", rice vinegar "(6 pack) (1 pack) Mizkan", coconut milk "(6 pack)
Mae Ploy". The rice vinegar case is only 5% off and would have passed on price alone; the bundle in
the item name is what convicts it.

**Only identity failures go to add-known-wrong.ps1.** That blocklist bans a (commodity, store,
product) cell permanently and only a recorded reversal undoes it. Filing a not-cheapest row there
would record a false ruling against a product that really is the commodity.

**Do not count your own dispatch prompt as a board defect.** Checked: no exclusion in this run came
from wording I wrote rather than from the commodity. The Baker's body wash row was the near-miss -
the agent excluded a kids 3-in-1 combo product at 0.133/fl oz, which is a defensible commodity call
and not something my prompt forced.

## The four rows that were checked a second time
Product identity decides whether a permanent blocklist entry gets filed, so four rows where the
board's product might or might not be the commodity were re-checked against the store directly
AFTER the blind findings were committed (commit 65149ad9). The ordering property blindness protects
was already banked at that point.

See verification-decisions-2026-08-15.csv for the final verdict on each.
