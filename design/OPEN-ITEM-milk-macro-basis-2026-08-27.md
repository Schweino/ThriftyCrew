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
