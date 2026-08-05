# Engine-pass worklist from the 2026-08-02 source-fidelity sweep

The prose wave fixed 190 recipes' steps. Everything below needs the ENGINE chain (ingredient list, mapping,
costing, macros - never a prose edit), or a human call. Compiled from the 8 fix-wave reports plus the
audit's MISSING-KEY rows (`engine-pass-worklist.json` holds the raw audit rows).

## Blocked recipes - the steps cannot be honest until the LIST changes

1. ~~**slow-cooker-dr-pepper-pulled-pork-bowls**~~ - DONE 2026-08-04. Zero-Sugar Soda restored to the
   spec: 710 g / "3 cups", bid `zero-sugar-soda-2l`, gpu 29.570 - the same row its root beer twin already
   carried, and the canonical values in `db/ingredients.json`. It prices at 1 x 2L bottle ($1.01, $0.36
   used), so the step that pours it can now be followed from the list a shopper buys.
   FIVE PLACES, because an ingredient is not one field: `ingredients_display` and `scaler.ing` spliced
   key-scoped (parallel arrays, same index the index row already used); `head.recipeIngredient` NOT typed
   by hand but re-derived with `repair-head-ingredients.ps1 -Apply -Slugs` since it became a derived
   field, which yields "Zero-Sugar Soda, 3 cups (710 g)"; `db/costed.json` via a targeted
   `cost-recipes.ps1 -Slugs`; and the `recipes-db.json` row, whose own copy of the line said 0 g /
   "1 bottle" - a braising liquid weighing nothing, labelled with a package. `sync-recipesdb-buy.ps1`
   correctly REFUSED to carry that one ("grams disagree too - not a label repair") and reported it
   instead, so it was authored deliberately. The salt/pepper/garlic-powder "for rub" annotations are
   still purchase labels rather than cook measures - the separate repair-cook-measures class, not this one.
2. **coq-au-vin** - the sauce thickener is a flour beurre manie; flour is not costed. Source confirms no
   reduction path. Needs flour added (butter is already there).
3. **filipino-pork-menudo-rice-bowls** - a "Rice Bowls" card with no rice in the cost list; every sibling
   costs rice. Add rice, re-cost, then restore the rice steps.

## Ingredient-list corrections (bought item is wrong or missing for what the dish is)

4. **turkey-chili-verde-white-beans** - source explicitly requires salsa VERDE ("not regular salsa");
   we cost 7 cups of Pace regular. Swap the mapped product. Steps currently say "jarred salsa".
5. **thai-turkey-larb-bowls** - the "Jalapeno" display line is actually dried chiles/chile powder per the
   source. Mapping label mismatch.
6. **chicken-jalfrezi** - ground coriander is core to the source's spice blend and is not costed. Writer
   removed the step reference; better fix is adding coriander.
7. **brazilian-galinhada** - salt/pepper seasoned in steps but neither is costed (every sibling costs
   them). Add to list.
8. **beef-honey-black-pepper-sauce-bowls** - source velvets with cornstarch; not costed. Decide velvet or
   not.
9. **cheesy-taco-spaghetti** - buys BOTH Ro-Tel AND plain diced tomatoes, 7 cans total for 3.5 lb beef.
   Probable double-count.
10. **greek-turkey-moussaka** - source says a true moussaka has no potato, yet 3,268 g of potato is the
    second-largest line. Writer used it as a base layer (defensible), or drop the line and re-cost.
11. **slow-cooker-pork-carnitas-bowl / slow-cooker-pulled-pork-bowl / slow-cooker-salsa-verde-chicken-bowl /
    slow-cooker-buffalo-chicken-bowl / slow-cooker-italian-chicken-penne / cheesy-zucchini-beef-rice-skillet** -
    costed lines absent from the source (padding). Writers folded them in so no purchase is orphaned;
    de-padding is a list+recost call.
12. **ground-beef-teriyaki-bowls** - titled Teriyaki; the source and sauce are Mongolian beef. Title call.
13. **spicy-vodka-rigatoni-italian-sausage** - titled vodka rigatoni; no vodka costed and pasta is ziti.
    Title or list call. (Also in the audit's MISSING-KEY rows.)
14. **chicken-mole-rice-bowls** - sold as mole with no dried chiles or chocolate (audit, medium). Adaptation
    call for Brad.
15. **thai-green-curry (chunk 09 row)** - red curry paste bought for a green curry. Swap paste.
16. **al-pastor bowl** - "Cilantro Lime Rice" component has neither cilantro nor lime costed.
17. **sichuan-dan-dan-noodles** - no Sichuan pepper anywhere; chili crisp does not supply the numbing
    element (audit, medium).
18. **kafta / kerala-beef-fry / beef-rendang** - source-defining herb/coconut components absent (audit,
    medium): parsley, coconut+curry leaves, kerisik.

## Quantity integrity (label vs grams disagree, or implausible amounts)

The measure-vs-gram mismatch class - the printed measure and the gram figure cannot both be true:
- turkey-ragu-pasta: turkey bacon "4 oz" label vs 396 g (~3.5x); celery "2 stalks" vs 280 g; bid is
  'bacon' not turkey bacon.
- swedish-meatball-potato-bowls: egg "1 large (120 g)"; brown sugar "2 tsp (20 g)"; butter "1 tbsp (30 g)".
- slow-cooker-king-ranch-chicken-bowls: butter "8 tbsp (250 g)" (~2x).
- slow-cooker-salsa-verde-pork-bowls: brown sugar "1/3 cup (150 g)" (~2x).
- turkey-sloppy-joe-bowls: ACV "1 tbsp (45 g)", soy "1 tbsp (90 g)", honey "1 bottle (42 g)".
- turkey-picadillo-rice-bowls: salt "1 tsp (22 g)".
- ground-beef-fried-rice-bowls: eggs "3 large (500 g)".
- ground-beef-gyro-bowls: cucumber/feta/lemon juice lines all ~3x their stated measures.
- ground-beef-and-broccoli / fried-rice / teriyaki / gyro: rice "1 lb" labels carrying ~1 kg grams,
  inconsistent across the four.
- curry-ground-turkey-bowls: 8 lb turkey (siblings run 2.25-5.5), peas "1 cup (490 g)", coconut milk
  "1 can (200 g)".
- slow-cooker-honey-sesame-chicken-bowls: cornstarch "1 boxs (8 g)" - malformed unit AND implausibly low.
- spanish-turkey-albondigas: salt 52 g / pepper 23 g high; szegedin-goulash paprika 97 g (authentic but
  confirm); filipino-beef-pares black pepper 50 g; baked-turkey-kibbeh cumin 61 g; beef-mushroom-stir-fry
  cornstarch 93 g.
- oyakodon / turkey-keema: broth costed "2-3 lb" for a liquid - display-unit oddity.
- giouvetsi-greek-beef-orzo-bake: tomato paste 3.5 cans (595 g) vs the source's 2 tbsp (~5x at scale).
- Hard-coded poundage in prose vs list: unstuffed-pepper "4.9 pounds" vs 5 lb line; turkey-meatball-marinara
  6.9 vs 7; turkey-chili-mac 6.6 vs 7; turkey-fajita 6.1 vs 7 (three of these still carry the old figure).

## Source/credit corrections

- **cheeseburger-rice-bowls** - the recorded budgetbytes source 404s and the site has no such recipe; the
  credit published today points at a dead wrong source. Find the real source or pull the credit.
- Fetch-blocked (audit could not verify, nothing known wrong): 2 x thespruceeats 403s, 1 dead source in
  chunk 03.

## The REVERSE gate: measured, NOT armed (2026-08-02)

spec-guards now hard-fails a recipe that BUYS an ingredient no step uses. The symmetric invariant - a step
that USES something the recipe never bought - is not gated, and the last writer wave found exactly why it
matters: **slow-cooker-dr-pepper-pulled-pork-bowls** references "zero-sugar soda" in `intro_html`, a
`shop_smart` line AND a `make_it` step, while no soda appears anywhere in the costed list. The braise
cannot be made as shopped, and a used-ingredient gate alone will never see it.

I measured a reverse gate and did not ship it, because I could not get it clean in the time I had:
bounding the scan to the 275 food names this estate knows gives **295 raw hits**, almost all containment
artifacts (a step saying "brown sugar" trips the shorter known name "Sugar"). Substring containment cuts
it to 31; token-subset containment moves it to 44 by breaking on plurals ("Green Bell Pepper" against a
bought "Green Bell Peppers"). It needs stemming in the token comparison, and then the survivors want
reading one by one - "Fries" in beef-rendang and "Corn Tortillas" in the enchilada skillet look real, and
a handful of others are probably still noise.

A gate that cries wolf gets switched off, so this stays a worklist item rather than a half-tuned check.
The measurement above is the head start.

### ARMED 2026-08-04 as PHANTOM (`spec-contradiction-lib.ps1`), 555 raw -> 9

The head start was right about what it would take. Six rules, each one a false positive the matcher
actually produced against the live catalogue:

1. **Longest match wins**, with span masking. The single biggest cut. Read narrowest-first, "olive oil"
   trips Olives 183 times, "brown sugar" trips Sugar 50, "garlic powder" trips Garlic 58.
2. **Match the surface, never the stem.** Stemming both sides put the ingredient "Fries" on the cooking
   verb "fry" in 50 recipes. Plurals are tolerated on the last word of the name instead.
3. **Stem `oes` properly** in the coverage comparison. Without it "potatoes" stems to "potatoe" while
   "potato" stems to itself, and five recipes that BUY Sweet Potatoes reported a phantom Potato.
4. **Containment either way covers**, head noun not required - a step saying "diced tomatoes" in a recipe
   that buys "Diced Tomatoes & Green Chilies" is naming its own can. Also register the pre-comma reading
   of a name, or "Cheddar Cheese, Shredded" cannot account for a step that says "cheddar cheese".
5. **Compound tails, X-free, subject pronouns, comparisons.** "apple cider VINEGAR" is not apple cider;
   "sugar-free BBQ sauce" names sugar to say there is none; "so IT fries up" is a verb; "honey burns
   faster THAN sugar" is a comparison, not an instruction.
6. **A step that MAKES something is not shopping for it**, decided per NAME rather than per sentence -
   four recipes blend tomatillos "into a rough salsa" and then mention the salsa again a clause later.

Frozen fixture is the Dr Pepper spec's own list and steps, with the root beer twin - the same braise,
the same sentences, one extra line in the list - as the clean twin. Baselined at **9** and ratcheted, so
a new one fails the gate. Of the 9: coq-au-vin (no bay leaves), filipino-pork-menudo and
slow-cooker-country-style-pork-ribs-rice (no rice in a rice dish), hungarian-chicken-paprikash ("a ladle
of hot sauce" that means hot braising liquid), beef-tips-and-gravy-mashed-potatoes (titled for potatoes,
buys rice) and al-pastor (a squeeze of pineapple juice from bought chunks) are real and belong on the
list above. Three are known noise worth reading before anyone "fixes" them: two hash-brown casseroles
whose steps say "potatoes" (they buy Frozen Hash Browns) and turkish-iskender, whose tomato sauce is
built in the pan from bought paste and tomatoes.

## Related standing items

- ZERO-QTY (16) and ABSURD-UNIT (79) remain baselined in `out\spec-contradictions-baseline.json` - the
  display-unit picker work. The biryani "Milk: 0 tbsp (1 g)" phantom is the worst of them.
- UNUSED dropped 418 -> 162 after the prose wave; the remainder is mostly the audit matcher's
  conservatism (compound nouns, "season" phrasing), worth re-measuring after the next matcher tightening.
