# Engine-pass worklist from the 2026-08-02 source-fidelity sweep

The prose wave fixed 190 recipes' steps. Everything below needs the ENGINE chain (ingredient list, mapping,
costing, macros - never a prose edit), or a human call. Compiled from the 8 fix-wave reports plus the
audit's MISSING-KEY rows (`engine-pass-worklist.json` holds the raw audit rows).

## Blocked recipes - the steps cannot be honest until the LIST changes

1. **slow-cooker-dr-pepper-pulled-pork-bowls** - the namesake soda is the braising liquid and is not
   costed. The salt/pepper/garlic-powder "for rub" annotations also only resolve once the soda exists.
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

## Related standing items

- ZERO-QTY (16) and ABSURD-UNIT (79) remain baselined in `out\spec-contradictions-baseline.json` - the
  display-unit picker work. The biryani "Milk: 0 tbsp (1 g)" phantom is the worst of them.
- UNUSED dropped 418 -> 162 after the prose wave; the remainder is mostly the audit matcher's
  conservatism (compound nouns, "season" phrasing), worth re-measuring after the next matcher tightening.
