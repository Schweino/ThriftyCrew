# Rice basis change, 2026-08-07 — what it left open

The Rice cup basis moved 185 -> 180 g/cup and `food-macros-db.json`'s Rice row was re-pointed from a
Member's Mark **Thai Jasmine** label (1/4 cup = 50 g, 180 cal, 4 g protein) to the **Long Grain** label
the board actually prices (1/4 cup = 45 g, 160 cal, 3 g protein). 171 labels were re-derived and 168
live cards republished. Two things came out of it that are decisions, not repairs.

## 1. turkey-maqluba-upside-down-rice-bake now sits UNDER the 25 g protein floor

It is the only recipe in the catalog the corrected rice data pushes out of the spec-guards macro
tolerance, and the reason matters: the jasmine label claimed **8.0 g protein per 100 g** of dry rice and
the long-grain label claims **6.67 g**. This recipe carries 1676 g of rice across 14 servings — 120 g a
serving, the most in the catalog — so the change costs it ~1.6 g of protein per serving.

| | stat on the card | recompute, old (jasmine) row | recompute, new (long grain) row |
|---|---|---|---|
| calories | 605 | 605 | 599 |
| protein | 26 g | 26 g | **24 g** |

`spec-guards.ps1` fails anything under `stat.protein < 25`. **The stat block was deliberately left at
605 / 26** rather than restated, because both available actions are decisions:

* restate it to 599 / 24 and the recipe fails the protein floor — it needs more turkey or it comes down
* leave it and the card overstates protein by 2 g

Worth knowing before deciding: the label's integer rounding is coarse at a 45 g serving. "3 g per 45 g"
covers anything from 2.5 to 3.5 g, i.e. 5.6–7.8 g per 100 g, and USDA's figure for raw long-grain white
rice is **7.13 g/100 g**. At the USDA figure this recipe lands near 24.6 g, which rounds to 25 and clears
the floor. So the honest range is "24 to 25", and which end you publish depends on whether the site
wants to state label figures or USDA figures for rice protein. Every other rice recipe stays inside
tolerance either way.

**No other recipe was restated.** The rice change moves per-serving calories by at most 5.3 across the
305 rice recipes, inside the tolerance that exists for exactly this kind of label rounding, and a blanket
restat would have been actively wrong: 11 specs are ALREADY outside the macro tolerance for an unrelated
reason (below), and overwriting their stats from the DB would have laundered that bug into a clean-looking
number.

## 2. The seven "cups dry jasmine" recipes were left alone

`bbq-chicken-rice-bowls`, `beef-burrito-bowls`, `beef-chili-rice-bowls`, `cheesy-beef-broccoli-bowls`,
`chicken-enchilada-rice-bowls`, `fajita-chicken-rice-bowl`, `hot-honey-chicken-bowls` carry hand-written
labels naming jasmine rice, derived at exactly 200 g/cup. They failed the relabel gate (their stored
label was never generator output) and were not swept. A writer naming a specific rice is a claim about
that recipe, and it now disagrees with both the commodity's price basis and its macro row. Either the
labels drop the word "jasmine", or those recipes want a separate `Jasmine Rice` canonical item with its
own board mapping.

## Not from this change, but standing in the same reports

11 specs are outside the macro tolerance by 46–337 cal/serving, all of them Tortilla recipes
(`musakhan-sumac-chicken` is worst at +337). The same recipes drive the `GOLDEN: 1 failed` structural
result (`Tortilla :: pkg_g 300 is not a package db\ingredients.json defines for it`) and 13 of the
remaining GPU-DRIFT lines. That is the tortilla-basis work, not the label lane — see
`out\tortilla-basis-2026-08-06.md`.
