# Data smells flagged by the 2026-07-26 shop_smart money-strip wave (5 writer agents, 97 recipes)

Real content-bug candidates surfaced while rewriting prose. NOT fixed in that wave (out of scope).
Each needs a verify-then-fix pass through the engine (spec edit -> cost-recipes -> build-cards -> publish).

## Build/quantity bugs (verify against source recipe, then fix spec)
- **vietnamese-lemongrass-pork-noodle-bowls** - dish is Bun Thit Nuong but NO lemongrass in
  ingredients_display / scaler.ing / ingredients_grams; marinade is only fish sauce + sugar.
  Lemongrass is the defining ingredient.
- **chicken-pad-thai-noodle-bowls** - garlic 2.25 cups (308 g) / "Buy 8 heads" for 14 servings. ~60+
  cloves is implausible for pad thai.
- **turkey-keema-curry-with-peas** - Fresh Cilantro "105 tbsp (105 g)": grams value pasted into the
  tbsp field.
- **turkey-kofta-rice-bowl-with-tahini-sauce** - 3.5 cups tahini (~28 oz, near a whole large jar) for
  one 14-serving batch; verify build quantity.
- **middle-eastern-beef-kofta-bowls-with-tzatziki** - cucumber 2828 g ("9.4 cucumbers") for 14
  servings; heavy, verify.
- **vietnamese-caramelized-ground-beef-rice-bowls** - cucumber 4200 g ("14 cucumbers", ~300 g/serving)
  + 5.25 cups green onions; very veg-heavy, verify.
- **thai-basil-beef-bowls-with-coconut-rice** - Fresh Basil 56 tbsp (84 g) bucketed under "Pantry
  seasonings" driving an absurd ~$14 pantry line; mis-bucketed and quantity suspect.

## Internal contradictions (fix spec fields to agree)
- **fajita-chicken-rice-bowl** - portion_html says 499 cal / 49 g protein; stat.cal, intro_html and
  head block all say 541.
- **greek-beef-and-chickpea-bowls** - head.recipeIngredient says 5.5 cups dry rice; display/scaler/
  grams all say 3.75 cups / 700 g.
- **slow-cooker-mississippi-pork-bowls** - Au Jus Gravy Mix (65 g) + Cornstarch (2 tbsp) in ingredient
  list + scaler but never used in make_it steps; head.recipeIngredient omits both. Steps are likely
  the incomplete side (classic recipe uses ranch AND au jus).
- **hong-kongstyle-baked-pork-chop-rice** - Chicken Broth buy label reads "0 lb".
- **filipino-pork-giniling** - cost_closing still says "for 28 cents" (money in a non-shop_smart field).

## Mapping/proxy confirmations (mapper judgment, may be fine)
- **south-indian-chettinad-pepper-chicken-bowls** - Dijon Mustard 7.5 oz + Italian Seasoning as
  proxies in a Tamil dish; confirm mapping intent (mustard seeds / curry leaves proxy?).
- **baked-ziti-with-ground-beef** - ricotta mapped to bid cottage-cheese; reduced-fat mozzarella to
  shredded-cheese. Likely intentional proxies; confirm.
- **chicken-souvlaki-rice-bowls** - olives mapped to green-olives; souvlaki convention is Kalamata.

## Non-bugs the writers flagged (documented so nobody re-investigates)
- stat.cost_ps ("at everyday cost") sitting ABOVE cost_per_serving_true: intended two-basis design
  (everyday stable vs cheapest/true), uniform across all cards.
- Whole-jar spice lines (e.g. berbere ~$7 on ethiopian-doro-wat): whole-package costing is the v2
  policy - you buy the jar once.
- Ground-beef per-pound spread across recipes in removed prose: prose was frozen at different capture
  dates; exactly why the dollars were stripped.
