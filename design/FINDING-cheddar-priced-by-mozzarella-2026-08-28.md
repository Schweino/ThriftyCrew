# 55 live recipes price their cheddar by mozzarella — measured, needs a ruling

Found while closing out the wave-11 audit, which named a "cross-recipe cheddar sweep" as pricer work
and left it unmeasured. This is that measurement. **Nothing has been changed.**

## What `shredded-cheese` actually is

It is not a cheese. It is a basket of five:

| store | per oz | product |
|---|---|---|
| Sam's Club | **$0.1521** ← crown | Member's Mark Part-Skim **Mozzarella** 5 lbs |
| Aldi | $0.2056 | Happy Farms Shredded **Mozzarella** 16 oz |
| Walmart | $0.2162 | Great Value Mild **Cheddar** Finely Shredded, 32 oz |
| Baker's | $0.2278 | Kroger **Colby Jack** Shredded, Family Size |
| Fareway | $0.2338 | Fareway **Colby Jack** Fancy Shredded |
| Hy-Vee | $0.2462 | Hy-Vee **Pepper Jack** Cheese |
| Family Fare | $0.2466 | Our Family **Mexican** Shredded 32 oz |

One of seven cells is cheddar. Both `cheddar-cheese` and `cheddar-cheese-shredded` alias into this
basket through `recipe-floor-id-map.json`, so every cheddar line in the catalog is quoted at the
price of part-skim mozzarella.

## Who is affected — live pages only

| vocabulary name | live recipes | grams booked | quoted now | at a real cheddar price |
|---|---|---|---|---|
| `Cheddar Cheese, Shredded` | **55** | 18,557 g | $99.56 | $120.05 (**+20.6%**) |
| `Mexican Cheese Blend` | 30 | 10,615 g | $56.95 | $68.67 |

Per card the error is small: **+$0.027 per serving**, worst case +$0.077 on a $2.86 card. This is a
truth problem, not a "the totals are badly wrong" problem — but it is systematic across 55 published
pages and it is the same defect Brad ruled on this morning for the reduced-fat variant.

## The price already exists — no capture pass needed for 6 of 7

Sweeping every capture on disk for products matching `cheddar-cheese-shredded`'s own include list
(and excluding the fat-tier fence added today):

| store | cheapest real shredded cheddar | per oz | capture |
|---|---|---|---|
| Sam's Club | Member's Mark Mild Cheddar 16 oz ×2 | **$0.1834** | sams-deals 2026-07-29 |
| Walmart | Great Value Medium Cheddar 16 oz | $0.2175 | walmart-regular 2026-07-23 |
| Baker's | Kroger Sharp Cheddar Shredded 16 oz | $0.2188 | bakers-regular 2026-08-19 |
| Family Fare | Our Family Mild Cheddar 16 oz | $0.2494 | family-fare-regular 2026-08-05 |
| Aldi | Happy Farms Thick Cut Triple Cheddar 11 oz | $0.2536 | aldi-regular 2026-08-15 |
| Fareway | Tillamook Farmstyle Medium Cheddar 8 oz | $0.4975 | fareway-regular 2026-07-15 |
| Hy-Vee | **none in any capture** | — | — |

Two caveats worth stating before anyone builds a row from this:

- **Fareway's only cheddar is Tillamook**, a premium 8 oz SKU at 2.7× the crown. A real pull would
  almost certainly find a store brand. Taking this cell as-is would put a wrong-looking number on the
  board even though it is honestly captured.
- **Hy-Vee has none**, so a row built today is 6 stores, not 7.

## The ruling this needs — and why it is not mine

The registrar's 2026-08-28 batch said, explicitly:

> DO NOT touch the cheddar-cheese -> shredded-cheese floor-map line; full-fat cheddar keeps its
> current basket.

It said that while knowing the crown was mozzarella — it cited that fact as the reason to split the
*reduced-fat* id. So splitting full-fat cheddar now would **reverse a standing instruction**, not
merely extend it. That is a Brad decision.

Two questions:

1. **Does `cheddar-cheese-shredded` get its own priced board row**, breaking its floor-map alias, the
   way `reduced-fat-cheddar` just did? If yes, the chain is the one already run today: capture
   Hy-Vee (and ideally refresh Fareway), `add-recipe-board-rows`, drop the floor-map line, recost,
   `sync-recipesdb-cost`, propagate. 55 live cards move by ~3 cents a serving.
2. **What about `Mexican Cheese Blend`** (30 live recipes)? It has a better claim to the generic
   basket than cheddar does — Family Fare's cell *is* a Mexican blend — but the basket's crown is
   still mozzarella, which is not a Mexican blend either. Same question, lower confidence.

## Also still open from the wave-11 audit

- `wave-preaudit` has a Start-Job relative-path defect (owner: pipeline) — absolute-ize `RunDir`
  before the job.
- "milk empty item/size rows" (owner: pricer), named but not measured here.
