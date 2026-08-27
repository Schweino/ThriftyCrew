# OPEN ITEM: the food-DB `Milk` row is Fairlife, and 49 live recipes price generic milk against it

Found 2026-08-27 during run hunt-2026-08-27-ten, and independently confirmed by that run's wave-2
auditor. Logged on Brad's ruling; NOTHING was changed on any live recipe.

## The split

  macro basis   food-macros-db "Milk" = **Fairlife**, 80 cal / 13 P / 6 C / **0 F** per 240 g cup
                (ultra-filtered, fat free - a specialty product)
  price basis   board id `milk` = **"Milk (gallon)"**, cheapest $2.816 at Walmart
                (Fairlife sells ~$4.50/52 oz and is never $2.82/gal)

Same ingredient, two different packages. 49 LIVE specs compute their macros from that row.

## What it is worth

On the largest consumer (1929 g = 8 cups): protein 104 g vs ~64 g for 1% low-fat - **overstated by
40 g per batch**; fat 0 g vs ~19 g - understated; calories 643 vs ~820. Per serving at 14 that is
~+2.9 g protein and ~-1.4 g fat. Protein is the headline number this catalog sells on.

Biggest consumers: jamie-oliver-s-chicken-in-milk (1929 g), pastitsio (1750), buffalo-chicken-pasta-
bake (1715), creamy-roasted-garlic-chicken (1715), turkey-mac-and-cheese-bake (1501),
moussaka-greek-beef-eggplant-bake (1429), turkey-florentine-rice-bake (1286).

## Why nothing was changed

Correcting the row moves published macros on 49 live recipes. That is a recost-and-republish
operation with a measured blast radius, not an edit to make inside a recipe run.

## The case that made it concrete

`jamie-oliver-s-chicken-in-milk-seriously-delish` is `rejected-audit` in this run because of it. Its
own ingredient line says "8 cups LOW FAT milk", its cost line prices a $2.82 generic gallon, and its
shop_smart says "grab the store brand". On the Fairlife basis it computes 693 cal and clears the 700
ceiling; on the basis its own card instructs (store-brand 1%) the wave-2 auditor recomputed **~705
cal - ABOVE the ceiling**. It cleared the band only on a macro basis its own cost and shopping copy
contradict.

So the honest finding is not "add a milk row and publish it". Adding the label-accurate row REVEALS
that this recipe does not meet the run's conditions. That is the rejection standing on its stated
basis, which is where it now sits.

## What answering it needs

- Decide whether the estate's milk basis is generic (then the row is wrong and 49 recipes recost) or
  Fairlife (then the PRICE basis and the shopping copy are wrong instead, on the same 49).
- Either way it wants a distinct label-accurate row for ordinary 1%/2%/whole milk, since recipes do
  specify which, and the vocabulary currently cannot say.
- Same family as the crossed Olives/Green Olives pair (OPEN-ITEM-olives-crossed-bids-2026-08-27.md)
  and the broth/sausage/pasta brand splits the food-DB provenance pass turned up on 2026-08-26.

---

## RESOLVED 2026-08-27 on Brad's ruling

"If a recipe calls for just milk, we should use the 'generic' milk like the store brand milks, not
Fairlife. But if a recipe specifically calls for Fairlife, we use that." Then: "Fix and republish them
all and IDC if they move across the band. Let them stay and don't unpublish."

DONE:
  * food-macros-db "Milk" is now store-brand 2% reduced-fat - 120 cal / 7.9 P / 11.5 C / 4.8 F per
    240 g cup, source fdc:171267, brand "store brand".
  * "Ultra-Filtered Fat Free Milk" (brand Fairlife) exists as its own food, for recipes that name it.
  * 48 of the 49 live specs restatted and republished. audit-db-agreement CLEAN, 575 recipes, 0
    issues; propagate carried 60 dirty specs, 47 stamps advanced, 0 errors.

TWO REMAINDERS, both known and neither worth forcing:
  * chicken-biryani-rice-bowls REFUSED its restat: its stored carbs do not reproduce from the food DB
    even under the PRIOR snapshot (80.3 vs 78, past the 2 g ruler), so the tool declined to rewrite
    macros it cannot vouch for. Its milk line is "0 tbsp (1 g)" - one gram - so the macro consequence
    is under a calorie, and the discrepancy is in some other ingredient. Its live card still prints
    "Milk (Fairlife)" for that 1 g line. Worth its own look, but it is not a milk problem.
  * creamy-roasted-garlic-chicken carries a stale WRITER NOTE describing the old Fairlife basis. It is
    authoring metadata, never rendered, and its ingredient line updated correctly.

WHAT THIS COST THE ESTATE TO LEARN: there was no way to carry a corrected food-DB row into the specs
built from it. rebase-spec-ingredient only recomputed macros for an item MOVE. That gap is now closed
by its -Restat mode, which keeps the safety argument by proving against -PriorFoodDb. See
[[OPEN-ITEM-gruyere-duplicate-id-2026-08-27]] and [[OPEN-ITEM-olives-crossed-bids-2026-08-27]] for the
two remaining members of this family.
