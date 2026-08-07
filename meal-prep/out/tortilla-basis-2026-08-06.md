# Tortilla basis repair - 2026-08-06

Started as "three files disagree on what a tortilla weighs." The three-way contradiction is fixed. What
the investigation turned up underneath it is bigger than the contradiction, and is NOT fixed: 7 of the
11 specs that carry `Tortilla` are pricing an ingredient their source recipe never called for, so
recosting them is polishing a wrong number.

---

## 1. What the `tortillas` commodity actually prices  (SETTLED)

`commodities.json` defines `tortillas` as "Tortillas (flour)", unit `each`, include regex `tortillas?`.
There is no size control, and per-EACH pricing systematically selects the SMALLEST tortilla. The seven
store winners on the 2026-08-06 board:

| store | $/each | product | g each |
|---|---|---|---|
| Walmart | 0.1060 | Great Value Small Fajita, 26 oz / 20 ct | **36.85** |
| Sam's Club | 0.1230 | Mission 6" Fajita, 54.667 oz / 40 ct | 38.75 |
| Hy-Vee | 0.1245 | Guerrero fajita 20 ct | ~36 |
| Baker's | 0.1681 | La Banderita Street Taco Thin, 16 ct @ 0.63 oz | 17.86 |
| Family Fare | 0.1825 | Frescados Taqueria Mini, 12 ea | ~22 |
| Fareway | 0.1990 | Mission Super Soft Fajita, 10 ct | 38.75 |
| Aldi | 0.2612 | Pueblo Lindo BURRITO, 20 oz / 8 ct | 70.87 |

Five of seven are fajita/street-taco/mini. The cheapest is 36.85 g. **gpu 45 matched none of them** - 45 g
is an 8-inch soft-taco tortilla, which is what several SOURCE recipes call for. Someone calibrated gpu to
the recipe's tortilla instead of the priced one. Same class as the 2026-07-19 brown-sugar 16x.

**Chosen basis: 36.85 g** (26 oz / 20 ct = 737 g / 20). It is the cheapest, it is the middle of the fajita
cluster, and it closes the card's arithmetic exactly: 737 / 36.85 = 20 tortillas x $0.106 = **$2.12**,
which is the literal Walmart shelf price on the board.

## 2. What was fixed  (SHIPPED, verified)

| file | was | now |
|---|---|---|
| `db/ingredients.json` `tortillas` | gpu 45, buy_pkg 300 g / "10ct pack" | gpu 36.85, buy_pkg 737 g / "20ct pack" |
| `db/densities.json` `Tortilla.each` | 30 | 36.85 |
| `food-macros-db.json` `Tortilla` | La Banderita, 65 g / 90 cal | Great Value, 36 g / 110 cal / 3P / 18C / 2fib / 2F |

The old row asserted a 300 g pack of 10 (= 30 g each) while its own gpu said 45. It contradicted itself.

**The macro row was the bigger bug.** La Banderita Carb Counter is 1.385 cal/g; an ordinary flour tortilla
is 3.06 cal/g. Every recipe using `Tortilla` has understated its tortilla calories by 2.2x per gram. The
proof needs no judgement: musakhan carries 202 g of bread per serving, which at true density is 618 cal
from bread alone against a **stated total of 576**. The published number is arithmetically impossible.

The La Banderita identity is not lost - the burrito batch already cloned it to a `High Fiber Tortilla`
row (65 g / 90 cal, buy_pkg 388 g / 6 ct, internally consistent). The burrito format's 400-cal cap still
has its product. That clone is what made the generic row safe to correct.

## 3. Guards added  (SHIPPED, fixtures pass)

**`pipeline/audit-count-gpu.ps1`** - new. For count-unit rows, `buy_pkg_g / <count in label>` is an
independent measure of one unit; gpu and `densities.each` must match it. `-SelfTest` ships the founding
bug and a clean twin as frozen literals. Live run: 2 findings, both real (below), zero false positives.

Note on scope: an early draft also compared densities/macro servings against gpu on SINGLE-unit rows and
produced 17 findings, 15 of them false - densities `each` is the COOK's unit (a garlic clove is 5 g) while
gpu is the PURCHASE unit (a head is 40 g). Narrowed to the class where the arithmetic is actually closed.

**`engine/audit-db-agreement.ps1`** - closed a hole. gpu was exempt from value comparison because
build-v2-spec unit-reconciles it. That is true only when a conversion applies; `Resolve-ScalerGpu` returns
gpu untouched when map unit == feed unit, and "each" is not even in its `$UNIT_G` table. So for every
count-priced commodity the gpu magnitude was unchecked on both sides. Now compared whenever no conversion
can apply. This is what keeps the current half-repaired state honest instead of silently green.

## 4. Open - needs Brad

### 4a. The 11 specs are stale on purpose

They still carry gpu 45 and La Banderita branding. `audit-db-agreement` now reports GPU-DRIFT and
HEAD-INGREDIENT drift on them. **This red is correct and deliberate** - do not clear it by reverting the
map. It is not in daily CI (`daily.yml` runs the grocery chain only), so nothing is blocked overnight.

They were NOT recost, because 7 of 11 are pricing the wrong ingredient and a recost would have to be done
twice. Every claim below was checked against the recipe's own `source_url`:

| slug | source says | spec has | verdict |
|---|---|---|---|
| `turkey-huevos-rancheros-rice-bowls` | 6 srv, "6 soft taco-size (6-inch) flour tortillas" -> 14 | 420 g = 14 x 30 | **CLEAN** - and 6-inch matches the board exactly |
| `pulled-pork-enchilada-bake` | 4 srv, "8 (8-inch) flour tortillas" -> 28 | 840 g = 28 x 30 | **CLEAN** ingredient; source is 8-inch (~45 g) but the board prices 6-inch. This is where gpu 45 came from |
| `turkish-iskender-turkey-bowls` | 4 srv, "4 pita or Turkish bread, thick pita preferred" -> 14 | 830 g = 59 g/srv | **OK** - honest mass substitution, ~1 thick pita per serving |
| `slow-cooker-pork-birria-bowls` | 6 srv, "12 6-inch CORN tortillas" -> 28 | 840 g flour | WRONG COMMODITY - `corn-tortillas` is live at $0.0561, roughly half |
| `turkey-taco-casserole` | 6 srv, "12 CORN tortillas, cut into fourths" -> 28 | 840 g flour | WRONG COMMODITY (corn) |
| `turkey-migas-skillet` | 4 srv, "2 CORN tortillas cut into strips" -> 7 (210 g) | 508 g flour | WRONG COMMODITY + quantity 2.4x the source |
| `cochinita-pibil-pork-rice-bowls` | 12 srv, "corn tortillas ... to serve", NO quantity | 420 g flour | WRONG COMMODITY + invented quantity |
| `loaded-ground-turkey-nacho-bake` | 4-6 srv, "corn tortilla CHIPS", no quantity | 882 g Tortilla | WRONG COMMODITY - nachos are chips (`tortilla-chips`, $0.143/oz) |
| `chipotle-sweet-potato-pork-chili` | 10 srv, **no tortilla in the ingredient list** (chips named only as a serving suggestion) | 830 g Tortilla | **PHANTOM** - 830 g carrying $1.96 and 99 cal/serving for an ingredient the source never called for |
| `turkey-pozole-rojo` | 8 srv, "Tostadas, for serving", NO quantity | 1914 g = 137 g/srv | invented quantity for an optional garnish; 4.6 tortillas per bowl |
| `musakhan-sumac-chicken` | 6 srv, "6 flatbread such as Taboon bread, Greek pita bread, or naan" -> 14 | 2829 g = 202 g/srv | mass-honest (one taboon per person) but at true density the bread alone is 618 cal vs a stated 576 total |

### 4b. Measured movement if the 11 are recost as-is

Cost is a uniform +22.1% on the tortilla line (gpu 45 -> 36.85). Calories are the headline.

| slug | $ old | $ new | cal old | cal new | carbs old | carbs new |
|---|---|---|---|---|---|---|
| chipotle-sweet-potato-pork-chili | 1.96 | 2.39 | 571 | 670 | 46 | 55 |
| cochinita-pibil-pork-rice-bowls | 0.99 | 1.21 | 571 | 621 | 79 | 83 |
| loaded-ground-turkey-nacho-bake | 2.08 | 2.54 | 561 | 666 | 46 | 55 |
| musakhan-sumac-chicken | 6.66 | 8.14 | 576 | **914** | 88 | 118 |
| pulled-pork-enchilada-bake | 1.98 | 2.42 | 822 | 922 | 69 | 78 |
| slow-cooker-pork-birria-bowls | 1.98 | 2.42 | 692 | 792 | 33 | 42 |
| turkey-huevos-rancheros-rice-bowls | 0.99 | 1.21 | 574 | 624 | 88 | 92 |
| turkey-migas-skillet | 1.20 | 1.46 | 563 | 624 | 21 | 26 |
| turkey-pozole-rojo | 4.51 | 5.51 | 567 | **795** | 85 | 105 |
| turkey-taco-casserole | 1.98 | 2.42 | 650 | 750 | 49 | 58 |
| turkish-iskender-turkey-bowls | 1.96 | 2.39 | 583 | 682 | 37 | 46 |
| **batch total** | **26.29** | **32.11** | | | | |

Cost moves are small per serving (+$0.015 to +$0.105). The calorie moves are not, and they are published
numbers in the blue rectangle and in Recipe JSON-LD. Recommended order: settle 4a first (the corn swaps
make three of these CHEAPER, and the phantom removal makes one cheaper AND lower-calorie), then recost
once.

### 4c. Two independent defects the new guards found

- **`corn-tortillas`**: gpu 30, but buy_pkg 750 g / "30ct pack" = 25 g each. Same self-contradiction, and
  the only weighed board winner (Hy-Vee La Banderita, 24.9 oz / 30 ct) is 23.5 g. Affects
  `beef-enchilada-skillet-bowls` and `slow-cooker-king-ranch-chicken-bowls`, plus any spec moved to corn
  by 4a. Not changed - it moves other recipes' costs and deserves its own measured pass.
- **`Green Onions`**: `mongolian-ground-beef-bowls` and one other spec carry gpu 100 against the map's 90.
  Pre-existing spec/map divergence that the old blanket gpu exemption hid. Not changed.
- **`Garlic`**: single-unit row states buy_pkg 40 g ("head") against gpu 50. One of the two is wrong.

### 4d. Burrito batch loose end

`high-fiber-tortillas` exists in `db/ingredients.json` but is on no feed row and is not in
`db/no-board-price-ok.json`. The first burrito spec that ships pointing at it will trip the
CHEAPEST-FALLBACK guard, or silently price cheapest == everyday.
