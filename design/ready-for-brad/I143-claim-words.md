# I143: FDA nutrient content claim words on the live catalogue

Measured 2026-09-19 by `meal-prep\pipeline\audit-nutrient-claims.ps1 -ReportFile`, which calls `Get-TcNutrientClaimUse` in `meal-prep\pipeline\nutrient-claim-lib.ps1` (lib blob 73a790fb84cd599d7efdc2cb293a8e11e7d03f2a) over the list in the `nutrient_claims` block of `meal-prep\pipeline\forbidden-prose-global.json`, at base commit 42056585e. Re-run the same command to refresh it.

**Brad's ruling (2026-09-19): "rule for new, measure old".** A NEW recipe may use one of these words only where its own per-serving macros clear the FDA bar; that is enforced at the import door and in the wave pre-audit. **This page is the "measure old" half. No live page was changed and nothing was published.** The question it puts to Brad is whether, and in what order, to sweep the uses below.

## The count

- **336 of 584 live recipes** carry at least one claim word as our own claim; **746 uses** in all.
- **670 pass** their bar, **21 fail** it, and **55 cannot be computed** because the bar needs a number no spec carries (sodium, sugars, fibre, saturated fat, cholesterol, or a reference food).
- **53 of 584 recipes** carry at least one use that does not pass (fail or not computable).
- 583 of 584 recipes weigh 6 oz or more a serving (raw ingredient weight over servings) and are judged as a main dish under 21 CFR 101.13(m); the rest by the per-serving conditions.

**Why this is not the item's 767.** The item counted 12 spellings of 7 claims over 10 named prose fields. This counts 19 claims (the closed list, cited below) over every reader-facing field except the five rendered from the ingredient list, and it does NOT count a word that sits beside a product whose own name carries it (Fat Free Cheddar, BBQ Sauce (Sugar Free)) or a store-variant word (fat free, low sodium, sugar free, less fat...) directly before a product word (the low-fat kind, 1/3 less fat cream cheese, a high fiber tortilla), or a claim's listed non-claim contexts (lean on, 93/7 lean, lean ground turkey, light and fluffy). Attribution, writer notes and the slug are not read. Different test, stated; neither number is wrong about its own test.

## Per claim word

| Claim | Rule | Uses | Recipes | Pass | Fail | Not computable | of the non-passing, beside a product word |
|---|---|---:|---:|---:|---:|---:|---:|
| high protein | 21 CFR 101.54(b); DRV 50 g at 101.9(c)(7)(iii) | 653 | 329 | 653 | 0 | 0 | 0 |
| good source of protein | 21 CFR 101.54(c); DRV 50 g at 101.9(c)(7)(iii) | 0 | 0 | 0 | 0 | 0 | 0 |
| high fiber / good source of fiber | 21 CFR 101.54(b)-(d); DV 28 g at 101.9(c)(9) | 0 | 0 | 0 | 0 | 0 | 0 |
| high in / good source of a micronutrient | 21 CFR 101.54(b)-(c) | 0 | 0 | 0 | 0 | 0 | 0 |
| fat free | 21 CFR 101.62(b)(1) | 3 | 2 | 0 | 3 | 0 | 0 |
| low fat | 21 CFR 101.62(b)(2), (b)(3) | 9 | 7 | 3 | 6 | 0 | 0 |
| reduced fat / less fat | 21 CFR 101.62(b) (relative claims) | 2 | 2 | 0 | 0 | 2 | 0 |
| low saturated fat | 21 CFR 101.62(c) | 0 | 0 | 0 | 0 | 0 | 0 |
| cholesterol free / low cholesterol | 21 CFR 101.62(d) | 0 | 0 | 0 | 0 | 0 | 0 |
| lean / extra lean | 21 CFR 101.62(e)(3), (e)(5) | 44 | 35 | 0 | 0 | 44 | 3 |
| calorie free | 21 CFR 101.60(b)(1) | 0 | 0 | 0 | 0 | 0 | 0 |
| low calorie | 21 CFR 101.60(b) | 18 | 18 | 10 | 8 | 0 | 1 |
| reduced calorie / fewer calories | 21 CFR 101.60(b) (relative claims) | 2 | 2 | 0 | 0 | 2 | 0 |
| sugar free | 21 CFR 101.60(c)(1) | 5 | 4 | 0 | 0 | 5 | 0 |
| no added sugar | 21 CFR 101.60(c)(2) | 2 | 2 | 0 | 0 | 2 | 0 |
| reduced sugar / less sugar | 21 CFR 101.60(c) (relative claims) | 0 | 0 | 0 | 0 | 0 | 0 |
| low sodium / sodium free | 21 CFR 101.61(b) | 0 | 0 | 0 | 0 | 0 | 0 |
| reduced sodium / less sodium | 21 CFR 101.61(b) (relative claims) | 0 | 0 | 0 | 0 | 0 | 0 |
| light / lite (as a calorie or fat claim) | 21 CFR 101.56(d)(1); 101.56(e)(1), (f) | 8 | 8 | 4 | 4 | 0 | 0 |

"Beside a product word" means the word sits directly next to a word of an ingredient the recipe buys, although that product's recorded name does not carry the claim ("the sugar-free BBQ sauce" where the recipe buys plain "BBQ Sauce"). Those are usually a description of a product rather than of the dish, and the cheapest sweep for them is to name the product the recipe actually buys. The rest are claims about the dish.

## How each bar is computed

Per serving is the spec's own `stat` block (cal, protein, fat), which is what the card prints. Per 100 g divides by the serving weight, taken as the sum of `ingredients_grams` over servings: RAW weight, because the spec carries no cooked weight, which is an approximation in both directions. Two stricter legal readings are recorded and NOT applied, because the ruling names per-serving macros: a protein claim wants PDCAAS-corrected protein (21 CFR 101.9(c)(7)(i)), and 101.54(b) lets a main dish say "high" only of an identified component food. The CFR text was read on law.cornell.edu; ecfr.gov refused the fetch.

## Every use that does not pass

### fat free (3)

- `bbq-chicken-rice-bowls` shop_smart[2] - FAIL (10 g fat per serving against under 0.5 g): "...Fat free cheese stretches the protein. A quarter cup adds 9 grams of protein for 45 calories and zero f..."
- `bbq-chicken-rice-bowls` shop_smart[2] - FAIL (10 g fat per serving against under 0.5 g): "...9 grams of protein for 45 calories and zero fat. It is one of the best macro deals in the dairy aisle...."
- `chicken-enchilada-rice-bowls` shop_smart[2] - FAIL (4 g fat per serving against under 0.5 g): "...ein per quarter cup for 45 calories and no fat, which is why it earns its spot in the lean bowls...."

### low fat (6)

- `bbq-chicken-rice-bowls` head.keywords - FAIL (3.82 g fat per 100 g (3 or less) and 20.6% of calories from fat (30 or less), main dish at 261.5 g a serving): "...rep, cheap meal prep, bbq chicken bowl, low fat meal prep, budget dinner..."
- `fajita-chicken-rice-bowl` head.description - FAIL (3.02 g fat per 100 g (3 or less) and 17.7% of calories from fat (30 or less), main dish at 397 g a serving): "...A high-protein, low-fat Tex-Mex chicken, rice, black bean, and pepper meal prep. Fourteen servings at about {{cal}} calo..."
- `fajita-chicken-rice-bowl` intro_html - FAIL (3.02 g fat per 100 g (3 or less) and 17.7% of calories from fat (30 or less), main dish at 397 g a serving): "...A high-protein, low-fat Tex-Mex chicken, rice, black bean, and pepper meal prep. Fourteen servings at about {{cal}} calo..."
- `high-protein-chicken-alfredo-lasagna` shop_smart[0] - FAIL (6.76 g fat per 100 g (3 or less) and 36.8% of calories from fat (30 or less), main dish at 266.3 g a serving): "...ups and you will use it up. Full fat or low fat both work; low fat trims the fat number without hurting the creaminess o..."
- `high-protein-chicken-alfredo-lasagna` shop_smart[0] - FAIL (6.76 g fat per 100 g (3 or less) and 36.8% of calories from fat (30 or less), main dish at 266.3 g a serving): "...e it up. Full fat or low fat both work; low fat trims the fat number without hurting the creaminess once it is blended s..."
- `hot-honey-chicken-bowls` head.keywords - FAIL (4.27 g fat per 100 g (3 or less) and 21.2% of calories from fat (30 or less), main dish at 234.1 g a serving): "...ep, cheap meal prep, hot honey chicken, low fat meal prep, budget dinner..."

### reduced fat / less fat (2)

- `ground-beef-stroganoff-pasta` shop_smart[1] - NOT-COMPUTABLE (needs a reference food - a relative claim is measured against one, and the spec names none): "...gives you the classic creamy tang with less fat, and one tub covers the whole batch...."
- `pizza-pasta-bowls` shop_smart[0] - NOT-COMPUTABLE (needs a reference food - a relative claim is measured against one, and the spec names none): "...g> It brings the same pizza flavor with less fat, which is why it earns its spot here...."

### lean / extra lean (44)

- `bbq-chicken-burrito` head.description - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...burrito under 400 calories, built on a lean blended crema. Fourteen servings at about {{cal}} calories and {{protein}}..."
- `bbq-chicken-burrito` intro_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them) - beside a product word: "...cup of mayo behind it. If you like our Lean BBQ Chicken and Rice Bowls, this is the same flavor you can eat with one ha..."
- `bbq-chicken-burrito` shop_smart[2] - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...it turns a normally fatty sauce into a lean one. Buy the big tub and you will find other uses for it fast...."
- `bbq-chicken-rice-bowls` name - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them) - beside a product word: "...Lean BBQ Chicken and Rice Bowls..."
- `buffalo-chicken-burrito` cost_closing_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...the trick that keeps it both creamy and lean...."
- `chicken-enchilada-rice-bowls` cost_closing_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...bowl (at everyday cost) for a lean, cheesy enchilada bowl that beats the frozen dinner on every count...."
- `chicken-enchilada-rice-bowls` shop_smart[2] - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "..., which is why it earns its spot in the lean bowls...."
- `chicken-enchilada-rice-bowls` upsell_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...Lean, cheesy dinners for about ${{cost_ps}} a bowl (at everyday cost). This is one of many. Members get every recipe in..."
- `chicken-florentine` intro_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...ting like it has no business being that lean...."
- `chicken-refried-bean-burrito` shop_smart[2] - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...am stand-in that keeps this whole batch lean...."
- `chicken-rice-and-broccoli` cost_closing_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...a handful of pantry spices is about as lean as a grocery list gets, and it still feeds you like a champion. This is wha..."
- `chicken-rice-and-broccoli` intro_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...serving for {{cal}} calories. That is a lean, honest number. A full dinner under 500 calories that still puts a serious..."
- `chicken-souvlaki-rice-bowls` intro_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...rotein}} grams of protein at a lean {{cal}} calories for about ${{cost_ps}} (at everyday cost)..."
- `creamy-tomato-ground-turkey-gnocchi` shop_smart[0] - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...turkey at 93/7 gives you 3.75 pounds of lean protein for the batch. It routinely undercuts lean ground beef by a good ma..."
- `filipino-chicken-inasal-bowls` intro_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...rotein}} grams of protein at a lean {{cal}} calories for about ${{cost_ps}} (at everyday cost)..."
- `green-chile-chicken-burrito` intro_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...with the skin removed keeps it fast and lean. If you know our Slow Cooker Chicken Chile Verde Bowls, this is the handhel..."
- `grilled-pork-tenderloin-burrito-bowl` cost_closing_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...ole. The tenderloin is the whole trick: lean, tender, and cheaper than people assume...."
- `ground-beef-stroganoff-pasta` portion_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...reamy classic still earns its spot on a lean plan...."
- `healthy-hamburger-helper` make_it[1] - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...oon a little off, but 93/7 stays pretty lean...."
- `hot-honey-chicken-bowls` cost_closing_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...bowl (at everyday cost) for a lean, crave-worthy dinner that would run $12 or more at a fast-casual spot...."
- `hot-honey-chicken-bowls` upsell_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...Lean, crave-worthy dinners for about ${{cost_ps}} a bowl (at everyday cost). This is one of many. Members get every reci..."
- `italian-ground-turkey-white-bean-skillet` shop_smart[0] - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...not packaging. The 93/7 blend keeps it lean without cooking up dry and chalky the way the 99 percent breast can...."
- `machaca-beef-burrito` intro_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...thread is seasoned. This build keeps it lean and honest at about {{cal}} calories and {{protein..."
- `pork-fried-rice-bowls` shop_smart[0] - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...y and freezes perfectly. It is lean, it slices thin without a fight, and buying two when the price drops sets u..."
- `salisbury-steak-potato-bowls` intro_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...This is old-fashioned comfort food done lean and cheap. Ground beef patties simmer in a mushroom and onion gravy, all sp..."
- `senfbraten-german-mustard-pork-roast` intro_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...d gravy you will want to drink. It is a lean, high protein plate at 53 grams for about ${{cost_ps}} (at everyday cost),..."
- `senfbraten-german-mustard-pork-roast` shop_smart[0] - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...drops the price per pound, and loin is lean enough that you are paying for meat, not trim...."
- `sheet-pan-pork-tenderloin-potatoes-green-beans` cost_closing_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...bowl (at everyday cost) for a lean protein, a starch and a vegetable that all came off the same pan. The tende..."
- `slow-cooker-chicken-gyro-bowls` portion_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...grams of protein and {{cal}} calories, lean and filling in equal measure...."
- `slow-cooker-filipino-pork-adobo-bowls` shop_smart[1] - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...Pork loin keeps this lean and affordable. Buy the loin over pre-cut pork and slice it yourself...."
- `slow-cooker-mongolian-chicken-bowls` portion_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...and just {{cal}} calories, a genuinely lean, high-protein plate...."
- `slow-cooker-pork-tinga-bowls` shop_smart[2] - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...Pork loin keeps this cheap and lean. Buy the loin over pre-shredded pork and do the shredding yourself..."
- `slow-cooker-root-beer-pulled-pork-bowls` intro_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them) - beside a product word: "...ee barbecue sauce keep this pulled pork lean while the slow cooker turns tenderloin into fork-tender shreds. It goes ove..."
- `slow-cooker-salsa-verde-chicken-bowl` intro_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...s, corn, and cheddar. It is loaded with lean protein and a squeeze of lime keeps it tasting fresh instead of heavy. A bu..."
- `slow-cooker-salsa-verde-pork-bowls` shop_smart[0] - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...Pork tenderloin runs lean and clean, but watch the tag. If the per-pound price is steep, check for pork loin ins..."
- `south-indian-chettinad-pepper-chicken-bowls` intro_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...only {{fat}} grams of fat. Big flavor, lean numbers...."
- `southwest-ground-turkey-cauliflower-rice-skillet` shop_smart[0] - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...ey, not packaging. The 93/7 blend stays lean without cooking up dry and chalky the way the 99 percent breast can...."
- `thai-red-curry-chicken-rice-bowls` intro_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...{cost_ps}} (at everyday cost). Lean has never tasted less like a punishment...."
- `turkey-bolognese-penne` intro_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...bolognese over high-protein penne, made lean with ground turkey. This is the weeknight pasta that tastes like Sunday, ho..."
- `turkey-chile-relleno-casserole-skillet` cost_closing_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...f cheese is most of that. This is not a lean dish and it was never trying to be. It is a chile relleno, and the cheese i..."
- `turkey-drunken-noodles` cost_closing_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...a bowl (at everyday cost) for lean drunken noodles. The Thai restaurant charges $14 for pad kee mao, and their..."
- `turkey-drunken-noodles` head.description - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...cost_ps}} a serving (at everyday cost). Lean pad kee mao with basil and jalapeno heat...."
- `turkey-drunken-noodles` head.keywords - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...les, pad kee mao, ground turkey recipe, lean noodle meal prep, thai turkey noodles, budget thai..."
- `turkey-fajita-rice-bowls` portion_html - NOT-COMPUTABLE (needs saturated fat and cholesterol - neither the spec nor food-macros-db.json carries them): "...{{cal}} calories, which keeps this one lean and filling...."

### low calorie (8)

- `bbq-chicken-burrito` head.keywords - FAIL (129.7 calories per 100 g (120 or less), main dish at 283 g a serving): "...hicken burrito, high protein meal prep, low calorie burrito, cheap meal prep, budget dinner..."
- `chicken-bacon-ranch-burrito` head.keywords - FAIL (135.7 calories per 100 g (120 or less), main dish at 290.3 g a serving): "...ranch burrito, high protein meal prep, low calorie burrito, cheap meal prep, budget dinner..."
- `chicken-refried-bean-burrito` head.keywords - FAIL (124.8 calories per 100 g (120 or less), main dish at 278 g a serving) - beside a product word: "...rema burrito, budget burrito meal prep, low calorie chicken burrito..."
- `green-chile-turkey-burrito` head.keywords - FAIL (130.6 calories per 100 g (120 or less), main dish at 288.6 g a serving): "...turkey meal prep, high protein burrito, low calorie meal prep, budget dinner..."
- `honey-chipotle-chicken-burrito` head.keywords - FAIL (133.7 calories per 100 g (120 or less), main dish at 281.9 g a serving): "...hicken burrito, high protein meal prep, low calorie burrito, cheap meal prep, budget dinner..."
- `ranch-chicken-burrito` head.keywords - FAIL (120.2 calories per 100 g (120 or less), main dish at 329.5 g a serving): "...hicken burrito, high protein meal prep, low calorie burrito, cheap meal prep, budget dinner..."
- `salsa-verde-chicken-burrito` head.keywords - FAIL (130.3 calories per 100 g (120 or less), main dish at 299.2 g a serving): "...eal prep burrito, cottage cheese crema, low calorie burrito, budget chicken burrito..."
- `thai-peanut-chicken-burrito` head.keywords - FAIL (151 calories per 100 g (120 or less), main dish at 249 g a serving): "...hai meal prep, avocado chicken burrito, low calorie burrito, budget meal prep..."

### reduced calorie / fewer calories (2)

- `cheesy-ground-beef-tortellini` shop_smart[1] - NOT-COMPUTABLE (needs a reference food - a relative claim is measured against one, and the spec names none): "...kes the sauce creamy for less money and fewer calories than heavy cream, and the bricks are cheaper per ounce than the t..."
- `creamy-chicken-fajita-burrito` shop_smart[3] - NOT-COMPUTABLE (needs a reference food - a relative claim is measured against one, and the spec names none): "...Reduced fat mozzarella melts creamy for fewer calories than full fat, and the bag freezes well if you only use a handful..."

### sugar free (5)

- `bbq-chicken-burrito` shop_smart[0] - NOT-COMPUTABLE (needs sugars - neither the spec nor food-macros-db.json carries them (backlog I145)): "...batch. If you want to shave carbs, the no-sugar-added versions taste nearly identical once they hit the hot chicken...."
- `pulled-pork-stuffed-peppers` shop_smart[3] - NOT-COMPUTABLE (needs sugars - neither the spec nor food-macros-db.json carries them (backlog I145)): "...e. If you are watching carbs closely, a sugar-free barbecue sauce swaps in with no change to the method and drops the ca..."
- `slow-cooker-pulled-pork-bowl` shop_smart[1] - NOT-COMPUTABLE (needs sugars - neither the spec nor food-macros-db.json carries them (backlog I145)): "...ong>Check the BBQ sauce label. Sugar-free sauces vary a lot in price. The store brand is usually a dollar or tw..."
- `slow-cooker-root-beer-pulled-pork-bowls` intro_html - NOT-COMPUTABLE (needs sugars - neither the spec nor food-macros-db.json carries them (backlog I145)): "...and yes, it works. Zero-sugar soda and sugar-free barbecue sauce keep this pulled pork lean while the slow cooker turns..."
- `slow-cooker-root-beer-pulled-pork-bowls` shop_smart[0] - NOT-COMPUTABLE (needs sugars - neither the spec nor food-macros-db.json carries them (backlog I145)): "...Sugar-free barbecue sauce cuts the sugar without cutting flavor. Grab the sugar-free bottle and nobody..."

### no added sugar (2)

- `korean-bulgogi-beef-burrito` shop_smart[2] - NOT-COMPUTABLE (needs added sugars - the conditions are about ingredients and processing, and nothing here records them): "...nderizes and sweetens the marinade with no added sugar, and you eat the other half...."
- `thai-peanut-chicken-burrito` shop_smart[0] - NOT-COMPUTABLE (needs added sugars - the conditions are about ingredients and processing, and nothing here records them): "...ng per batch. Buy the natural kind with no added sugar so the honey does the sweetening on your terms...."

### light / lite (as a calorie or fat claim) (4)

- `chimichurri-steak-sheet-pan` shop_smart[1] - FAIL (meets neither: 6.49 g fat per 100 g (3 or less) and 44.2% of calories from fat (30 or less), main dish at 323.6 g a serving; 132.3 calories per 100 g (120 or less), main dish at 323.6 g a serving): "...rving and keeps this from eating like a light lunch. Roasted whole and then split, they turn sweet and creamy with no pe..."
- `greek-turkey-fasolakia-rice-bowls` intro_html - FAIL (meets neither: 5.39 g fat per 100 g (3 or less) and 35.6% of calories from fat (30 or less), main dish at 482.8 g a serving; 136.1 calories per 100 g (120 or less), main dish at 482.8 g a serving): "...t and serve it over rice, which turns a light lunch into a container that actually holds you until dinner. It runs <stro..."
- `ground-beef-teriyaki-bowls` portion_html - FAIL (meets neither: 4.2 g fat per 100 g (3 or less) and 23.3% of calories from fat (30 or less), main dish at 380.5 g a serving; 162.2 calories per 100 g (120 or less), main dish at 380.5 g a serving): "...ms of protein at just {{cal}} calories, keeping this one light, sweet, and filling...."
- `honey-bbq-chicken-mac-and-cheese` make_it[4] - FAIL (meets neither: 6.4 g fat per 100 g (3 or less) and 28.8% of calories from fat (30 or less), main dish at 374.9 g a serving; 200.3 calories per 100 g (120 or less), main dish at 374.9 g a serving): "...lender job, which is the whole trick to keeping this light. Combine the cottage cheese, cream cheese, shredded cheddar,..."

## Uses that pass

670 uses clear their bar and need nothing. By claim: 
high protein 653; low fat 3; low calorie 10; light / lite (as a calorie or fat claim) 4.
