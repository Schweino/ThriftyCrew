# Measured: cheapest-store selection, old rule vs min-cost rule

Generated 2026-08-15 15:34 by `grocery\measure-cheapest-selection.ps1`. Read-only.
Feed: `C:\Codex\ThriftyCrew\public\smp-feed.json`, week of 2026-08-15, schema 2. Cards: 544.

## Cheapest lane, at each recipe base servings

| measure | value |
|---|---|
| recipes with both totals | 536 of 544 |
| ingredient lines that switch store | 3864 |
| recipes with at least one switch | 543 |
| recipe totals that fall | 535 |
| recipe totals that rise | 0 (must be 0) |
| median delta | $-42.24 |
| largest single-recipe drop | $-114.58 |
| lines switching at 7 / 28 servings | 3999 / 3491 |
| switches won by a per-unit-only cell | 220 |

Named example `bangers-and-mash-onion-gravy`: $58.37 -> $37.25, 6 line(s) switched.

## Biggest movers

| recipe | ingredient | old | new | delta |
|---|---|---|---|---|
| slow-cooker-french-onion-chicken-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-salsa-chicken-bowl | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-brown-sugar-sesame-pork-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| turkey-picadillo-rice-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| ground-turkey-stir-fry-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-chicken-tacos-rice-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-pork-tinga-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-filipino-pork-adobo-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-barbacoa-bowl | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| mediterranean-ground-turkey-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| beef-burrito-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-salsa-verde-chicken-bowl | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-chicken-tagine-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-chicken-tikka-masala-rice-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-chicken-gyro-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-chicken-chile-verde-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| bbq-chicken-rice-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-chicken-shawarma-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-kalua-pork-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-king-ranch-chicken-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-korean-gochujang-pork-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-pork-carnitas-bowl | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-pork-green-chili-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-char-siu-pork-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |
| slow-cooker-general-tso-chicken-bowls | Rice | Sam's Club $40 | Walmart $2.5 | $-37.5 |

## Phase 2 probe: the free-dinner rotation

Variant A (keep compute-v2 recipe package basis, pick the min-cost store) is algebraically a no-op:
with k and pkg_g/gpu fixed across stores, minimising cost is minimising per-unit. Only variant B
(move to the store package basis, matching the card) changes anything.

Variant B CHANGES which recipes are free:

| protein | loses free | gains free |
|---|---|---|
| chicken | chicken-pot-pie-biscuit-casserole, claypot-chicken-mushroom-rice | buffalo-chicken-pasta-bake, slow-cooker-crack-chicken-bowls |
| turkey | haluski-and-kielbasa-cabbage-noodles, red-beans-turkey-sausage-and-rice | turkey-alfredo-rotini-bake, turkey-maqluba-upside-down-rice-bake |
| beef | slow-cooker-beef-and-noodles, bistek-tagalog-filipino-beef-onion-rice | john-wayne-casserole, cheesy-beef-and-shells-casserole |
| pork | slow-cooker-filipino-pork-adobo-bowls | no-peek-pork-chop-rice-casserole |

