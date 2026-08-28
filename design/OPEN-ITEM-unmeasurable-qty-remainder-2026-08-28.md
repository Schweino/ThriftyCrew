# OPEN ITEM - the four rows UNMEASURABLE-QTY cannot fix without a ruling

UNMEASURABLE-QTY went **21 -> 2** on 2026-08-28 and the baseline was ratcheted down to match. What is left
is not a label problem, and this file is the evidence for each one so the ruling can be made without
re-deriving it. Two rows still fail the gate; two more are the same family and no gate can see them at all.

Every figure below was checked against the recipe's own source page, not inferred.

---

## 1. `chicken-biryani-rice-bowls` - Milk at 1 g. THE GRAMS ARE WRONG BY ~100x.

The card says `Milk (Fairlife): 0 tbsp (1 g)`. Step 6 says *"a drizzle of the milk"*.

**Source** ([indianhealthyrecipes.com/chicken-biryani-recipe](https://www.indianhealthyrecipes.com/chicken-biryani-recipe/)):

> "1 pinch saffron (optional)(soaked in 2 tbsps hot milk)"

2 tbsp for a **4-serving** recipe. Our batch carries 1295 g of rice - roughly 3.5x the source - so the
milk should be about **7 tbsp (~105 g)**, not 1 g.

**Note the recipe buys no saffron at all**, so what is left is the carrier without the thing it carries.
That is the real question: either the row wants ~105 g of milk (and probably a saffron line), or the
drizzle should come out of the method entirely.

**Ruling needed.** Changing 1 g to ~105 g moves cost and macros, so it needs a recost and a restat, not a
relabel.

---

## 2. `turkey-cordon-bleu-casserole` - Dijon Mustard is NOT IN THE SOURCE RECIPE.

The card says `Dijon Mustard (generic): 0.07 tbsp (1 g)`. Step 4 says *"season with the Dijon mustard"*.

**Source** ([fivehearthome.com](https://www.fivehearthome.com/chicken-turkey-cordon-bleu-casserole/)):
there is **no Dijon mustard in the ingredient list**. There is

> "⅛ teaspoon ground mustard powder"

So this is a substitution, not a quantity error - a wet condiment standing in for a dry spice. ⅛ tsp of
mustard powder scaled to our batch is roughly 0.4 g, which is where the 1 g came from; the grams are
about right for the food the source names and wrong for the food the card names.

**Ruling needed, and it is a commodity question.** The estate has `Dijon Mustard`, `Honey Dijon Mustard`
and `Yellow Mustard` - there is **no Mustard Powder / Ground Mustard commodity**. Correcting to source
means minting one, which is the commodity-registrar's gate, not a repair sweep's. The alternatives are to
keep Dijon and give it a real amount (which is inventing a quantity no source states), or to drop the row.

---

## 3 + 4. `musakhan-sumac-chicken` and `turkey-pozole-rojo` - `scaler.buy` disagrees with every other surface

These two do not fail any gate, and that is the finding.

| slug | item | grams | `scaler.buy` | display + head + cost line | `gpu` |
|---|---|---|---|---|---|
| musakhan-sumac-chicken | Tortilla | 1260 | **99.75 oz** | 44.4 oz | 36.850 |
| turkey-pozole-rojo | Corn Tortillas | 575 | **67.5 oz** | 20.3 oz | 23.500 |

1260 g really is 44.4 oz, so the display, the head line and the cost line all agree and **only `buy` is
wrong**. They are the ONLY two rows in the catalog where `scaler.buy` disagrees with the display amount.

**Do not hand-fix them.** `gpu` is grams per *displayed* unit and it agrees with neither number: 1260 /
36.85 = 34, i.e. the serving widget is scaling this row **by the tortilla**. So the row carries three
readings - 99.75 oz, 44.4 oz, and 34 tortillas - and rewriting the printed string without settling `gpu`
makes the card lie the moment a reader changes the serving count. That is the exact hazard
repair-absurd-units was written about.

---

## Why no gate reported 3 and 4 - **HEAD-QTY IS INERT ON THIS CATALOG**

`Get-HeadQtyMismatch` requires a head line to BEGIN with a quantity:

```
$q = [regex]::Match($s, '^\s*([\d.]+)\s*(cups?|tbsp|tsp|lbs?|oz)\b')
```

Every `head.recipeIngredient` line in `db\recipes` is written as `"<Item>[ (brand)], <amount> (<g> g)"` -
it begins with the ingredient name. **Measured 2026-08-28: 0 of 7,893 head lines start with a quantity.**
The class has never fired on live data, and its self-test passes on a fixture (`"5.5 cups dry rice"`) in a
shape the catalog does not use.

This is the third instance of the same failure found in one day, after the PHANTOM self-test staying green
while the catalogue read was red, and the eight-false-positive-shapes fixture passing on a word its
vocabulary did not know. **A green fixture is not evidence a class can see production.**

Fixing the regex looks cheap and the blast radius is small - the buy-vs-display sweep above found exactly
2 disagreements catalogue-wide - but it would turn a currently-green gate red on rows that need ruling 3+4
first, so it is deliberately NOT done here. Sequence: rule 3+4, then widen HEAD-QTY, then re-baseline.

Related: `Assert-BuyLabelSurfacesAgree` exists in `buy-label-lib.ps1` and is only ever called on specs a
repair is already touching. Nothing runs it across the catalog, which is why these two sat unseen.

---

## What WAS fixed on 2026-08-28 (for context)

* **The cups gap in `friendly-amt-lib`** - the teaspoon rung's gate read `tbsp` and `oz` but not `cups`,
  and `Get-FriendlyAmtCore`'s Broth arm returns cups unconditionally, so 15 g of chicken broth printed
  "0.06 cups" and no rung below could see it. 5 broth rows.
* **The count rung** now reads `each` as well as `leaf` and is gated on "no tsp and no tbsp" rather than
  also excluding a cup, so Dried Arbol Chiles - which the recipes say to use WHOLE - counts instead of
  printing a fraction of a cup. 3 rows. Ordered ahead of the cup step-down, which otherwise answered first
  with "1.25 tbsp".
* **Two missing densities** - Caraway Seeds and Poultry Seasoning had no entry of any kind. 3 rows.
* **Three "to taste" rows** whose sources state no quantity at all. `repair-to-taste-labels.ps1`.

Measured blast radius of the generator change: **8 of 7,893** derived labels move, and all 8 are findings
this work set out to fix.
