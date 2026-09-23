# Produce refuses condiments: the rule is on main, the live board is not rebuilt yet

## What Brad does

The condiment class (aioli, mayo, squeeze, dip, dressing, spread) is already on main for 114 of 116 produce
commodities; the live board was built ten minutes before it landed. The file has the paired diff (1 cell is this
rule), the full rebuild diff (80 cells), and the one command that rebuilds the live board.
Brad's second ruling the same day is recorded there too: both green-chilli products are known-wrong, stews and
cans are fenced off produce, no hand rebuild. The one action left is the check after the 08:00 run on 2026-09-20.

Brad's ruling, 2026-09-19: "Fix all produce". No aioli, mayo, squeeze condiment, dip, dressing or spread may win a
fresh produce cell, not only green chiles.

## State in one paragraph

The rule already landed on origin/main at 08:22 on 2026-09-19 in ee218cf06 ("Board accuracy 4f"). The live board,
`comparison-2026-09-17.json` in the main checkout, was built at 08:12 from a main checkout whose HEAD was f4bd8b66c
(2026-09-18 20:32), so it predates that rule and about 30 other commits landed since. That is why
`audit-food-category` exits 2 on it and the aioli is still on the public board. **Nothing in the rule files needs to
change.** This branch adds only the ruling's own fixtures (garlic, jalapenos, basil, fresh green chiles) to
`grocery/test-match-lib.ps1`. What is left is one action: land this branch and rebuild the live board, which moves
80 cells, of which exactly 1 is this rule.

**Update, 2026-09-19 afternoon:** Brad ruled a second time (section "Brad's ruling, 2026-09-19 (second)"): both
green-chilli products are now known-wrong, stews and cans are fenced off produce, and nobody rebuilds by hand. The
08:00 daily run on 2026-09-20 rebuilds the board, and the check to run after it is in that section.

## The mechanism, and why this one

`grocery/category-excludes.json` is the estate's single library of wrong-CLASS product tokens. It has three consumers
that read the same file, so they cannot disagree:

1. `grocery/apply-category-excludes.ps1` bakes each class's patterns into the `exclude` list of every commodity in the
   class's scoped categories (the `apply` block `^(Fruit|Vegetables)$` for produce), so a new produce commodity is born
   fenced;
2. `grocery/audit-food-category.ps1` (the blocking guard) flags a published cell whose product matches a class;
3. `grocery/build-vet-sheet.ps1` flags them for batch review.

`condiment_carrier` is that library's class for this shape: `\baioli\b`, `\bsqueeze\b`, `\bmayo(?:nnaise)?\b`,
`\bdips?\b`, `\bdressings?\b`, `\bspreads?\b`, scoped to Fruit and Vegetables beside `dairy_carrier`, `soup_carrier`
and the others, exempting `caesar-salad-kit` (its product carries a dressing) and `lemongrass-paste` (its product is a
squeeze paste). `lib/global-exclude-lib.ps1` is the wrong tool: it applies to every commodity, and mayonnaise, ranch
dressing and the dips must keep these words. A per-commodity hand fence (what canned-green-chilies and mayonnaise did
before) is the one-cell-at-a-time road the ruling rejects. The memory `wrong-product-class-is-a-seller-shape` says the
same about brands: fence the shape, not the seller.

Measured on this branch (base fe2ad786e): the class's 6 patterns are baked into 114 of the 116 Fruit and Vegetables
commodities (681 patterns), the 2 not baked are the 2 exempt ids, and the self-test's mechanism case asserts all 114.

## Over-exclusion check

No include pattern of any of the 116 produce commodities mentions aioli, squeeze, mayo, mayonnaise, dip, dressing or
spread (0 of 116). The paired board run below moved no fresh product out of any cell. The landing commit ee218cf06 also
measured 43,309 distinct item names the 2026-09-17 board read: 13 produce names left a produce cell, every one a
dressing, spread, squeeze pouch or aioli (jalapeno cheese spreads, strawberry and ginger dressings, lemon and raspberry
squeeze pouches, an avocado squeeze, a lime mayonesa, a cucumber bowl with ranch, the green chili aioli).
Nothing legitimate is killed that I could find. The words that could in principle hurt are `spread` and `dip` on a
produce name that is really fresh (a "Veggie Tray with Dip" is not a single fresh commodity either), and none exists
in the captures.

## Fixtures (grocery/test-match-lib.ps1, section 2b)

Added, each routed through match-lib over the live commodities.json and global excludes:

| Label | Name | Routes to |
|---|---|---|
| MUST FIRE | Kraft Roasted Garlic Mayo Mayonnaise, 12 fl oz | mayonnaise (not garlic) |
| MUST FIRE | Primal Kitchen Garlic Aioli Mayo, 12 oz | nothing (not garlic) |
| CLEAN TWIN | Kroger Whole Garlic Bulbs | garlic |
| CLEAN TWIN | Fresh Jalapeno Peppers | jalapenos |
| CLEAN TWIN | Gotham Greens Fresh Basil | fresh-basil |
| CLEAN TWIN | Fresh Green Chiles, per lb | green-chilli |

The founding Burman aioli MUST FIRE and a fresh green chili MUST NOT FIRE were already there from ee218cf06. No garlic
mayo or aioli is in any capture, so the two garlic names are written for the case; the three clean twins except the
green chiles are real shelf names from the 2026-09-17 board. The list's count guard moves from 20 to 26.

- Green: `test-match-lib.ps1` exit 0, "match-lib routing fixtures: 26 of 26 pass (condiment_carrier reaches 114 of
  114 non-exempt produce commodities)", then the full corpus: 42,775 names, 0 divergences, `MATCH-LIB PASSED`.
- Broken once: `grocery/commodities.json` swapped for a copy with the 681 baked class patterns removed. Exit 1,
  "MATCH-LIB FAILED (routing fixtures: 4 of 26 failed)": the Burman aioli routed to green-chilli, the class reached
  0 of 114, the roasted garlic mayo and the garlic aioli both routed to garlic. The clean twins stayed green, as they
  should. Restored: md5 EB64D5CE6645E4CA812E73024E95571F before and after, identical.

## The board diff

Both runs are in a seeded worktree (`ops/seed-worktree.ps1 -Target`), never the main checkout, over identical inputs
(Sam's captures compared byte for byte against the main checkout's, ignoring carriage returns: all identical).

### This rule alone (paired run, one row per cell per arm)

`compare-deals.ps1 -MinStores 1 -NoIdentity` twice over the same captures, arm A with the 681 class patterns removed
from produce, arm B with origin/main's rules. Of 3,184 cells in arm A, **1 changes**:

| Commodity | Store | Arm A (no class) | Arm B (the rule) |
|---|---|---|---|
| green-chilli | Aldi | Burman S Green Chili Squeeze Aioli 10 OZ, $3.92/lb | no price |

No cheapest store or price changes (0 of 571 commodities). Aldi simply has no green-chilli price.

### What a rebuild of the live board changes (all of origin/main at fe2ad786e, not only this rule)

The documented mid-day road (memory `compare-deals-is-not-standalone`), in the worktree: `compare-deals.ps1 -MinStores 1
-IdentityNamespace staple` with Baker's and Fareway pinned as `check-ad-cycles.ps1` pins them, `recipe-overlay.ps1`,
`audit-name-drift.ps1`, `prune-bad-links.ps1 -Tol 0.32`, `sync-browser-links.ps1`, `relink-drifted-cells.ps1 -Apply`,
`audit-name-drift.ps1`, `audit-capture-eviction.ps1`. Every step exited 0.

Against the live board (built 2026-09-19T08:12:32): **80 of 3,188 cells change** (75 change product, 5 lose their
price, 0 appear), and **38 of 572 commodities change their cheapest store or price**. By store: Sam's Club 64,
Fareway 7, Aldi 3, Walmart 3, Baker's 3. Only row 43 is this rule. Rows 12, 13 (La Choy, 117315d9c), 19, 22, 74
(ee218cf06's other fixes) are this morning's board-accuracy work; the rest come from the other commits landed since
f4bd8b66c (among them I191 Sam's and Fareway ad row ids, I193 peas, I222 per-each, I175 tie-break, which moves
same-price products such as Fareway's apples, bananas and croissants). I did not attribute each of those rows to its
commit; the paired run proves none of them is this rule. Two rows I could not explain from commit titles: Walmart
eggplant (row 34) and Aldi pudding cups (row 61) lose their price.

Cheapest changes (38): applesauce Aldi 0.0693 to Sam's 0.0642; bar-soap Walmart 0.6642 to Sam's 0.549; bbq-sauce
Walmart 0.0743 to Sam's 0.07; bean-sprouts Fareway 0.1421 to no price; canned-pasta Sam's 0.0688 to 0.0652;
coconut-aminos Walmart 0.624 to Baker's 0.599; coffee-creamer Aldi 0.0747 to 0.0841; collard-greens Hy-Vee to Baker's
(1.99 both); cream-cheese Fareway 0.1731 to Sam's 0.1381; cream-of-mushroom-soup Hy-Vee to Aldi (0.0695 both); diapers
Aldi 0.1499 to Sam's 0.1402; disinfecting-wipes Walmart 0.0359 to Sam's 0.0352; dog-treats Fareway 0.0936 to Sam's
0.0582; egg-noodles Walmart to Aldi (0.1088 both); energy-drinks Aldi 0.0931 to Sam's 0.0822; floor-cleaner Walmart
0.0778 to Sam's 0.0545; frozen-peas Fareway 0.0513 to Walmart 0.0612; glass-cleaner Walmart 0.0713 to Sam's 0.07; honey
Aldi 0.2079 to Sam's 0.1662; laundry-pods Walmart 0.1795 to Sam's 0.1498; mayonnaise Aldi 0.0963 to Sam's 0.0936;
oatmeal Aldi 0.095 to Sam's 0.0499; olive-oil Sam's 0.2275 to 0.1909; pancake-mix Sam's 0.0602 to 0.0484; pasta-sauce
Aldi 0.0704 to Sam's 0.0591; peanuts Aldi 0.1431 to Sam's 0.0873; pistachios Aldi 0.4056 to Sam's 0.3538; pork-shoulder
Sam's 1.98 to 1.94; powdered-sugar Hy-Vee to Aldi (0.925 both); ramen Aldi 0.3208 to Sam's 0.2908; refried-beans Hy-Vee
to Aldi (0.0619 both); rhubarb Fareway to Baker's (3.99 both); salsa Aldi 0.1079 to Sam's 0.0984; shredded-cheese
Fareway 0.1856 to Sam's 0.1521; shrimp Walmart 6.76 to Sam's 5.82; stuffing-mix Hy-Vee to Aldi (0.1583 both);
tomatillos Fareway to Family Fare (2.49 both); tomatoes-green-chilies Hy-Vee to Family Fare (0.0683 both).

Every changed cell (per-unit prices in the cell's own unit):

| # | Commodity | Store | Now on the live board | per unit | After a rebuild | per unit |
|---|---|---|---|---|---|---|
| 1 | all-purpose-cleaner | Sam's Club | Fabuloso 2X Concentrated Multi-Purpose Cleaner, Watermelon 210 fl. oz. | 0.0523 | Fabuloso 2X Concentrated Multi-Purpose Cleaner, Lavender 210 fl. oz. | 0.0523 |
| 2 | apples | Fareway | Washington Gala Apples | 1.48 | Gala Apple | 1.48 |
| 3 | applesauce | Sam's Club | GoGo SqueeZ Fruit & VeggieZ Applesauce Pouches, 3.2 oz., 28 pk. | 0.156 | Mott's No Sugar Added Applesauce, 46 oz., 3 pk. | 0.0642 |
| 4 | baby-formula | Sam's Club | Member's Mark Organic Whole Milk Infant Formula, 36 oz. | 0.9717 | Member's Mark, Advantage Premium, Infant Formula, 48 oz. | 0.7704 |
| 5 | baby-potatoes | Fareway | Summertime Farms Red or Gold Baby Potatoes | 0.9967 | Summertime Farms Baby Red Potatoes | 0.9967 |
| 6 | baby-wipes | Sam's Club | Pampers Sensitive Baby Wipes, Fragrance Free, 16 pks., 896 wipes | 0.03 | Huggies Natural Care Baby Wipes, Cucumber and Green Tea, 17 pk., 1088 Wipes | 0.02 |
| 7 | bacon | Sam's Club | Member's Mark Real Crumbled Bacon, 20 oz. | 7.184 | Member's Mark Restaurant Style Bacon, Hickory Smoked, 10lbs. | 3.986 |
| 8 | bagels | Sam's Club | Member's Mark Blueberry Sliced Bagels, 6 ct. | 0.6233 | Thomas' Plain Bagels, 12 pk. | 0.5817 |
| 9 | bananas | Fareway | Dole Bananas | 0.49 | Banana | 0.49 |
| 10 | bar-soap | Sam's Club | Dove Purely Pampering Shea Butter Beauty Bar (16 ct) | 0.9031 | Irish Spring Bar Soap, Original  Clean, 4 oz., 20 ct. | 0.549 |
| 11 | bbq-sauce | Sam's Club | Sweet Baby Ray's Barbecue Sauce, 40 oz., 2 pk. | 0.0873 | Sweet Baby Ray's Original Barbecue Sauce, 1 gal. | 0.07 |
| 12 | bean-sprouts | Baker's | La Choy Bean Sprouts | 0.1564 | (no price) | - |
| 13 | bean-sprouts | Fareway | La Choy Bean Sprouts | 0.1421 | (no price) | - |
| 14 | black-pepper | Sam's Club | Member's Mark Fine Ground Black Pepper, 18 oz. | 0.4433 | Member's Mark Coarse Black Pepper, 5 lbs. | 0.4185 |
| 15 | blueberries | Sam's Club | Organic Blueberries, 18 oz. | 0.5178 | Naturipe's Berry Peachy Blueberries, Dry Pint | 0.41 |
| 16 | canned-pasta | Sam's Club | Chef Boyardee Spaghetti and Meatballs, 14.5 oz., 8 pk. | 0.0688 | Chef Boyardee Beef Ravioli 15 oz., 12 pk. | 0.0652 |
| 17 | canned-peas | Walmart | (12 pack) Great Value Sweet Peas, 15 oz Can | 0.0547 | Great Value No Salt Added Green Peas, 15 oz | 0.0547 |
| 18 | chicken-wings | Sam's Club | Tyson Bone-In Buffalo Style Hot Chicken Wings, Frozen, 4 lbs. | 3.7425 | Tyson Garlic Parmesan Bone-In Oven Roasted Crispy Chicken Wings, Frozen, 4 lbs. | 2.4775 |
| 19 | coconut-aminos | Baker's | Bragg Organic Coconut Liquid Aminos Soy-Free Seasoning | 0.799 | Simple Truth Organic Coconut Aminos All-Purpose Seasoning Sauce | 0.599 |
| 20 | coconut-oil | Baker's | Eco Style Coconut Oil Styling Gel | 0.2806 | Kroger Pure Refined Coconut Oil | 0.3263 |
| 21 | coffee | Sam's Club | Airship Black Apple Espresso Whole Bean Coffee, 27 oz. | 0.8141 | Maxwell House Original Roast Medium Ground Coffee, 43.1 oz. | 0.394 |
| 22 | coffee-creamer | Aldi | Friendly Farms Half & Half Creamer | 0.0747 | Barissimo Assorted Seasonal Coffee Creamer | 0.0841 |
| 23 | coffee-creamer | Sam's Club | Chobani Dairy Coffee Creamer, Vanilla, 52 fl. oz. | 0.114 | Nestle Coffee mate Liquid Non-Dairy Refrigerated Coffee Creamer, French Vanilla, 66 fl. oz | 0.0861 |
| 24 | conditioner | Sam's Club | Shea Moisture 100% Virgin Coconut Oil Daily Hydration Conditioner, 34 fl. oz. | 0.5288 | Pantene Pro-V Ultimate Care 3-in-1 Conditioner, 38.2 fl. oz. | 0.2089 |
| 25 | crackers | Sam's Club | Member's Mark Cracker Cut Cheese Variety Tray, 2 lbs. | 0.2775 | Premium Original Saltine Crackers, 4 oz., 12 pk. | 0.155 |
| 26 | cream-cheese | Sam's Club | Philadelphia Original Cream Cheese Spread, 16 oz., 2 pk. | 0.2803 | Member's Mark Cream Cheese Brick, 48 oz. | 0.1381 |
| 27 | croissants | Fareway | Fareway All Butter Croissants | 1.6633 | Bakery Fresh Croissants | 1.6633 |
| 28 | croissants | Sam's Club | Member's Mark All Butter Sandwich Croissants, 12 ct. | 0.4967 | Member's Mark Chocolate Croissants, 12 ct. | 0.455 |
| 29 | deli-ham | Sam's Club | Member's Mark Uncured Boneless Quarter Sliced Ham, priced per pound | 0.2919 | Extra Lean Premium Ham, 1.25 lbs each., 2 pk. | 0.206 |
| 30 | deodorant | Sam's Club | Old Spice Fiji Antiperspirant Deodorant, Palm Tree + Coconut, 2.6 oz., 4 pk. | 1.6327 | Degree Antiperspirant Deodorant, Shower Clean, 2.6 oz., 5 pk. | 0.7677 |
| 31 | diapers | Sam's Club | Huggies Little Snugglers Baby Diapers, Sizes Newborn-2 | 0.18 | Luvs Pro Level Leak Protection Diapers, Sizes 1-8 | 0.1402 |
| 32 | disinfecting-wipes | Sam's Club | Clorox Disinfecting Cleaning Wipes Limited Edition Back to School Variety Pack, Bleach Free, Fresh Scent and Crisp Lemon, Pack of 5, 425 Wipes Total | 0.04 | Member's Mark Disinfecting Wipes, Variety Pack, 4 pk., 312 ct. | 0.0352 |
| 33 | dog-treats | Sam's Club | Irish Rover Beef Stick Dog Treats, 35 oz. | 0.5709 | Milk-Bone Original Dog Biscuits, Medium Crunchy Dog Treats, 15 lbs. | 0.0582 |
| 34 | eggplant | Walmart | Fresh Purple Eggplant, Each | 1.82 | (no price) | - |
| 35 | energy-drinks | Sam's Club | Red Bull Energy Drink, Coconut Berry, 12 fl. oz., 24 pk. | 0.2083 | Alani Nu Mini Variety Pack, 8.4 fl. oz., 24 pk. | 0.0822 |
| 36 | floor-cleaner | Sam's Club | Mr. Clean Professional Degreasing Floor Cleaner, 1 gal. | 0.1483 | Member's Mark No Rinse Floor Cleaner, 1 gal., Choose Pack Size | 0.0545 |
| 37 | frozen-meatballs | Sam's Club | Member's Mark Mozzarella Chicken Meatballs, 40 oz. | 0.2995 | Casa Di Bertacchi Homestyle Meatballs, Frozen, 5 lbs. | 0.1996 |
| 38 | frozen-peas | Fareway | Corner Store Green Peas, Sweet | 0.0513 | Fareway Steamables Green Peas | 0.0808 |
| 39 | frozen-peas | Walmart | Great Value No Salt Added Green Peas, 15 oz | 0.0547 | Great Value Frozen Sweet Peas, Steamable Bag, 16 oz | 0.0612 |
| 40 | frozen-pizza | Sam's Club | Member's Mark Cauliflower Crust White Pizza, 15.5 oz.,  2 pk. | 5.485 | Jack's Original Thin Pepperoni Frozen Pizza 4 pk. | 2.97 |
| 41 | garlic-powder | Sam's Club | Member's Mark Organic Granulated Garlic, 11 oz. | 0.7618 | Member's Mark Granulated Garlic, 26 oz. | 0.3569 |
| 42 | glass-cleaner | Sam's Club | Windex Fast Shine Foam Glass Cleaner, No-Drip Aerosol Cleaning Spray, 19 oz., 4 pk. | 0.1445 | Windex Original Glass Cleaner, 1 spray bottle + 128 fl. oz. Refill | 0.07 |
| 43 | green-chilli | Aldi | Burman S Green Chili Squeeze Aioli 10 OZ | 3.92 | (no price) | - |
| 44 | ground-cumin | Sam's Club | Member's Mark Organic Ground Cumin, 8 oz. | 0.7475 | Member's Mark Ground Cumin, 16 oz. | 0.5612 |
| 45 | hand-soap | Sam's Club | Softsoap Antibacterial Liquid Hand Soap, 11.25 fl. oz., 4 pk. | 0.2107 | Safeguard Ultimate Care Hand Wash, Variety Pack, 15.5 fl. oz., 3 pk. | 0.1497 |
| 46 | honey | Sam's Club | Nate's Honey 100% Organic Pure Raw and Unfiltered Honey, 40 oz. | 0.3495 | Member's Mark Wildflower Pure Premium Honey, 48 oz. | 0.1662 |
| 47 | laundry-pods | Sam's Club | Tide Power PODS + Ultra OXI Laundry Detergent Pacs, 72 ct. | 0.3469 | Member's Mark Laundry Detergent Power Pacs, Blooming Breeze, 130 ct. | 0.1498 |
| 48 | maple-syrup | Sam's Club | Member's Mark Organic 100% Pure Maple Syrup, 32 oz. | 0.3838 | Mrs. Butterworths Original Syrup, 36 oz., 2 pk. | 0.0942 |
| 49 | mayonnaise | Sam's Club | Duke's Real Mayonnaise, 64 fl. oz. | 0.1325 | Member's Mark Foodservice Extra Heavy Mayonnaise, 128 fl. oz. | 0.0936 |
| 50 | muffins | Sam's Club | Member's Mark Blueberry Muffins, 6 ct. | 1.1233 | Entenmann's Little Bites Chocolate Chip Muffins, 1.5 oz., 20 pk. | 0.539 |
| 51 | oatmeal | Sam's Club | Quaker Instant Oatmeal, Variety Pack, 1.51 oz., 52 pk. | 0.1398 | Quaker Old Fashioned Oats, 160 oz. | 0.0499 |
| 52 | olive-oil | Sam's Club | Member's Mark Extra Virgin Olive Oil, 101 fl. oz. | 0.2275 | Pompeian Extra Light Tasting Olive Oil, 68 fl. oz. | 0.1909 |
| 53 | pancake-mix | Sam's Club | Bisquick Original Pancake and Baking Mix, 96 oz. | 0.0602 | Member's Mark Buttermilk Pancake Mix, 10 lbs. | 0.0484 |
| 54 | pasta-sauce | Sam's Club | Rao's Homemade Marinara Sauce, 22 oz., 2 pk. | 0.1764 | Ragu Old World Style Traditional Pasta Sauce, 45 oz., 3 pk. | 0.0591 |
| 55 | peanut-butter | Sam's Club | Premier Protein 30g High Protein Shake, Chocolate Peanut Butter, 11 fl. oz., 15 pk. | 0.121 | Member's Mark Natural Creamy Peanut Butter, 40 oz., 2 pk. | 0.0972 |
| 56 | peanuts | Sam's Club | Planters Salted Dry Roasted Peanuts Canister, 52 oz. | 0.165 | Hampton Farms Salted In-Shell Peanuts, 5 lbs. | 0.0873 |
| 57 | pistachios | Sam's Club | Wonderful Lightly Salted Pistachios, No Shells, 24 oz. | 0.6658 | Member's Mark Roasted & Salted Pistachios, 48 oz. | 0.3538 |
| 58 | pork-shoulder | Sam's Club | Member's Mark Bone In Pork Boston Butt, Vacuum Pack, priced per pound | 1.98 | Bone-In Pork Boston Butt, Case, priced per pound | 1.94 |
| 59 | potato-chips | Sam's Club | Boulder Canyon Avocado Oil Potato Chips, 18 oz. | 0.36 | Member's Mark Wavy Potato Chips, 16 oz. | 0.1862 |
| 60 | protein-bars | Sam's Club | Larabar Protein Bars, Peanut Butter Chocolate, 16 pk. | 0.9362 | Nature Valley Peanut Butter Dark Chocolate Protein Chewy Bars, 30 ct. | 0.3993 |
| 61 | pudding-cups | Aldi | Baker S Corner Pudding Vanilla Each | 0.98 | (no price) | - |
| 62 | queso | Sam's Club | RITZ Handi-Snacks Crackers and Cheese Dip, 0.95 oz., 30 pk. | 0.44 | Bay Valley White Queso Cheese Sauce, 106 oz. | 0.1413 |
| 63 | ramen | Sam's Club | Samyang MEP Ramen Bowl, Red Pepper and Chicken & Cilantro, 6 pk. | 1.63 | Nissin Top Ramen, Chicken, 24 pk. | 0.2908 |
| 64 | ribeye-steak | Sam's Club | Member's Mark USDA Choice Angus Beef Boneless Ribeye Steak, priced per pound | 14.97 | USDA Choice Angus Beef Whole Cowboy Ribeye, Case, priced per pound | 12.97 |
| 65 | salsa | Sam's Club | Member's Mark Fresh Cilantro Pico De Gallo Style Salsa, 48 oz. | 0.1402 | Pace Chunky Salsa, Medium, 38 oz., 2 ct. | 0.0984 |
| 66 | salt | Sam's Club | Member's Mark Himalayan Pink Salt, 38 oz. | 0.1916 | Morton Iodized Salt, 64 oz. | 0.0372 |
| 67 | sandwich-cookies | Fareway | Fareway Sandwich Cookies | 0.1192 | Fareway Lemon Cremes Sandwich Cookies | 0.1192 |
| 68 | sandwich-cookies | Sam's Club | Nutter Butter Peanut Butter Sandwich Cookies, 24 pk. | 0.23 | OREO Chocolate Sandwich Cookies, 5.23 oz., 12 pk. | 0.175 |
| 69 | shampoo | Sam's Club | Shea Moisture 100% Virgin Coconut Oil Daily Hydration Shampoo, 34 fl. oz. | 0.5288 | TRESemme Ultimate Moisture Shampoo & Conditioner, 39 fl. oz., 2 pk. | 0.1536 |
| 70 | shredded-cheese | Sam's Club | Member's Mark Colby and Monterey Jack Shredded Cheese 16 oz., 2 pk. | 0.1866 | Member's Mark Part-Skim Mozzarella Cheese 5 lbs. | 0.1521 |
| 71 | shrimp | Sam's Club | Member's Mark Farm Raised Jumbo Raw Shrimp, Frozen, 21-25 ct. per pound, 2 lbs. | 8.485 | Member's Mark Farm Raised Jumbo Raw EZ Peel Shrimp, Frozen, 21-30 ct. per pound, 3 lbs. | 5.82 |
| 72 | sliced-cheese | Sam's Club | Member's Mark Sliced Colby Jack Cheese, 2 lbs. | 0.2069 | Member's Mark American Cheese 5 lbs., 160 slices | 0.1521 |
| 73 | soda | Sam's Club | Manzanita Sol Soda Apple 12 fl. oz., 24 pk. | 0.0468 | Shasta Cola 12 fl. oz., 24 pk. | 0.0312 |
| 74 | sponges | Sam's Club | Scrub Daddy Sponge Daddy Cleaning Sponges, Multi-Color, 12 ct. | 0.7483 | Scotch-Brite Heavy Duty Scrub Sponges, Individually Wrapped 24 ct. | 0.4988 |
| 75 | stain-remover | Sam's Club | Clorox 2 For Colors Stain Remover, Laundry + Fabric, Free and Clear, 90 Loads, 112.75 fl. oz. | 0.1506 | Clorox 2 for Colors Free & Clear Stain Remover, 90 loads, 112.75 fl. oz. | 0.1169 |
| 76 | stuffing-mix | Sam's Club | Kinder's Brown Butter & Herbs Homestyle Stuffing Mix, 24 oz. | 0.3325 | Kraft Stove Top Chicken Stuffing Mix, 6 oz., 6 pk. | 0.2706 |
| 77 | sun-dried-tomatoes | Sam's Club | Terra Verde Italian Sundried Tomatoes in Oil, 24 oz. | 0.4158 | Terra Verde Italian Sundried Tomatoes in Oil | 0.4158 |
| 78 | toaster-pastries | Sam's Club | Pop-Tarts Toaster Pastries, Brown Sugar Cinnamon, 48 ct. | 0.2079 | Pop-Tarts Chocolate Toaster Pastries, Variety Pack, 48 ct. | 0.2079 |
| 79 | tomato-soup | Sam's Club | Member's Mark Tomato Basil Soup 32 oz. tubs, 2 pk. | 0.1541 | Campbell's Condensed Tomato Soup 10.75 oz., 12 ct. | 0.1006 |
| 80 | yogurt | Sam's Club | GoGo Squeez Yogurtz Strawberry and Strawberry Banana, 3 oz., 20 ct. | 0.2163 | Yoplait Original Lowfat Yogurt Variety Pack, 6 oz., 18 ct. | 0.0739 |

(Three product names are printed here in plain ASCII where the store's own name carries a curly apostrophe or an
accented e: rows 4, 46 and 69.)

### The guard

`grocery/audit-food-category.ps1`, read by exit code:

- on the seeded live board: **exit 2**, `BUG green-chilli [Aldi] class=condiment_carrier 'Burman S Green Chili Squeeze
  Aioli 10 OZ'`, 1 cell;
- on the rebuilt board: **exit 0**, "ok - no food commodity matched a ... product (3076 priced cells scanned)".

## Landing and the live rebuild (for the orchestrator)

1. Land the fixtures (behaviour-neutral: a test file only). From the branch's worktree:

       powershell -NoProfile -File ops\seed-worktree.ps1 -Target <this worktree's full path>
       powershell -NoProfile -File ops\push-main.ps1

   Exit 0 is landed; 3 is never a pass (read `blind=`).

2. **Brad ruled on 2026-09-19: do not rebuild now; the 08:00 daily run on 2026-09-20 does it** (see his second ruling
   below). What follows is kept as the record of what a hand rebuild would have been.
   Rebuild the live board. This is the step that changes reader-visible numbers, and it moves all 80 cells above,
   not only the aioli. It is the same chain the 08:00 task runs (`grocery/ALERTS.md`: `TC Grocery Daily Capture 0800`
   runs `check-ad-cycles.ps1 -NoPull`), from the MAIN checkout after it has pulled origin/main:

       cd C:\Codex\ThriftyCrew
       git pull --rebase origin main
       powershell -NoProfile -File grocery\check-ad-cycles.ps1 -NoPull

   It recompares, repairs the links, runs the guards, publishes, and commits its own output (no `-NoCommit`).
   If nobody runs it, tomorrow's 08:00 chain does the same thing on its own, because the rule is already on main.

## How to verify after

- `powershell -NoProfile -File grocery\audit-food-category.ps1` in the main checkout: exit 0.
- `grocery\out\comparison-2026-09-17.json` (or the new date) has no Aldi row in green-chilli: its `built_at` is after
  the pull, and the Burman aioli is gone.
- `git show origin/main:public/board.json` no longer contains `burman-s-green-chili-squeeze-aioli` (the Aldi chip in
  the green-chilli cell today links to it).
- The live feed and the deals page: the green-chilli row shows Walmart only (see the risk below).

## Brad's ruling, 2026-09-19 (second): known-wrong both, fence stews and cans, no rebuild now

Brad ruled on the risk below, through the orchestrator:

1. **Known-wrong entries, so no rebuild can put either product back.** Both added with `grocery/add-known-wrong.ps1`,
   ruled by "Brad (via orchestrator, 2026-09-19)", `retire_when` = `ruling-reversed` (the closed vocabulary's
   default):
   - `green-chilli|Aldi|burman-s-green-chili-squeeze-aioli-10-oz`, name "Burman S Green Chili Squeeze Aioli 10 OZ".
   - `green-chilli|Walmart|stokes-green-chile-stew-with-pork-and-potatoes-m`, names "Stokes Green Chile Stew with
     Pork and Potatoes, Medium, 15 oz Can" (the board's spelling) and "Stokes Green Chile Stew with Pork and
     Potatoes, 15 oz Can" (the ruling's spelling).
   The Walmart entry also carries product id 35230539 (read off the item link on `public/board.json`), so it still
   fires if Walmart re-spells the name; Aldi publishes no id, so that ruling keys on the normalised name.
2. **Stews and cans are fenced off produce, through the same library class road as the condiments.**
   `grocery/category-excludes.json`: `soup_carrier` gains `\bstews?\b`, and a new class `canned_carrier`
   (`\bcans?\b`) sits in the Fruit and Vegetables apply block only. `apply-category-excludes.ps1` baked 273
   patterns into 163 commodities (116 produce and 47 Meat for the stew word, 110 produce for the can word; the
   other 6 produce commodities already carried it by hand). Two re-landing fences went in with it: `canned-peas`
   refuses `\bcarrots?\b` and `dried-oregano` refuses `\btomato\s+paste\b`.
   - **Why the can word is its own class and not in `soup_carrier`:** `soup_carrier` is also baked into Meat. With
     the can word there, 198 names moved, and most of them were real cans leaving their own cells: canned tuna,
     canned chicken, canned salmon, canned diced ham, and a fresh Hormel pork shoulder ad that reads "TASTE WHAT PORK
     CAN DO". Scoped to produce, the same two tokens move 70.
3. **No rebuild now.** The live board is untouched. Tomorrow's 08:00 daily run (`TC Grocery Daily Capture 0800`,
   `check-ad-cycles.ps1 -NoPull` from the main checkout) rebuilds it on these rules.

### Over-exclusion sweep

Harness: a scratch sweep (match-lib `Resolve-Commodity`, one row per name per arm) over every distinct `item`,
`product` and `name` string in the 1,275 JSON and JSONL files under `grocery/out` in a seeded worktree, plus the 35
board-corpus names that scan missed: **77,482 names**, of which **42,873** are the corpus `test-match-lib.ps1` builds
from the 2026-09-17 board's inputs. Arm A is origin/main at fe2ad786e; arm B is this change (grocery/commodities.json
blob 047c95eef8ab3f9f7d5b07e926ca84f977881919, grocery/match-lib.ps1 blob d69a4823d6e6fa906bd0243728f2a08260601736,
unchanged from fe2ad786e). Could-not-look 0 in both. The scratch sweep is a one-off and is not committed.

**70 of 77,482 names move; 27 of them are in the board corpus.** No fresh product moves. "Cantaloupe", "pecans",
"Mexican", "canola" and "Stewart" (a dog-treat brand) all sit inside a longer word, so the `\b` boundaries leave them
alone; "stewed tomatoes" and "stew meat" do not match `\bstews?\b` as a fresh-produce hit (stewed is a longer word,
and no stew-meat product routes to any Meat commodity today, before or after).

Board-corpus moves (27):

| From | To | Name |
|---|---|---|
| onions | none | French's Kosher Original Crispy Fried Onions, 6.0 oz Can |
| carrots | none | Kroger Sliced Carrots - 14.5oz can |
| carrots | none | Kroger Sweet Peas & Carrots - 8.5oz can |
| carrots | none | Kroger Sweet Peas & Carrots - 15oz can |
| limes | soda | Diet Coke Retro Lime Fridge Pack Cans 12 Fl Oz |
| carrots | none | Le Sueur Whole Tender Baby Carrots, Shelf-Stable, 15 oz Can |
| carrots | none | Great Value Sliced Carrots, 14.5 oz Can |
| carrots | none | Great Value Sliced Carrots, 8.25 oz Can |
| carrots | none | (12 pack) Great Value Sliced Carrots, 8.25 oz Can |
| garlic | tomato-paste | Hunts Tomato Paste with Basil, Garlic and Oregano, Perfect for Chili & Soups, 6 oz. Can |
| garlic | tomato-paste | Contadina Tomato Paste with Roasted Garlic, 6 oz Can |
| peaches | energy-drinks | Alani Nu, Juicy Peach, 12 fl oz, Single Can |
| raspberries | none | Augason Farms Freeze Dried Whole Raspberries Can, Emergency Food Supply, Everyday Meals, 23 Servings |
| oranges | none | Mingle Mocktails Non-Alcoholic Blood Orange Elderflower Mimosa, 4 Pack, 12 fl oz Aluminum Cans, 0.00% ABV |
| carrots | none | Great Value Peas & Diced Carrots, 8.5 oz Can |
| carrots | none | Libby's Peas & Diced Carrots, 15 oz can |
| tomatoes | none | Contadina San Marzano Style Whole Tomatoes, 28 oz Can |
| carrots | none | (12 pack) Libby's Peas & Diced Carrots, 15 oz can |
| strawberries | energy-drinks | Alani Nu, Strawberry Sunrise, 12 fl oz, Single Can |
| oranges | energy-drinks | Alani Nu, Orange Kiss, 12 fl oz, Single Can |
| peaches | none | Starbucks Iced Energy Tropical Peach 12 fl oz Can |
| pineapple | none | Dole Tropical Fruit, Pineapple and Papaya, No Sugar Added, 15.25 oz Can |
| green-chilli | none | Stokes Green Chile Stew with Pork and Potatoes, Medium, 15 oz Can |
| limes | canned-black-beans | Kuner's Southwest Black Beans with Mild Jalapenos and Lime 15 oz. Can |
| leeks | none | Mingle Mocktails Non-Alcoholic Party Variety Pack, 6 Pack, 12 fl oz Sleek Aluminum Cans, 0.00% ABV |
| shrimp | red-curry-paste | Mae Ploy Red Curry Paste, ... Shrimp Paste, Lemongrass ... Curries, Stews and Other Dishes, 2.2lbs Tub |
| cherry-tomatoes | none | Mutti Cherry Tomatoes (Ciliegini) 14 oz, Can |

Before the two re-landing fences, the Kroger peas-and-carrots cans landed on `canned-peas` and the Hunt's paste on
`dried-oregano`; with the fences they go nowhere and to `tomato-paste`. Every other landing above is the right
commodity or none.

The other 43 moves are outside the board corpus (long-tail listings, freeze-dried #10 cans, drinks, seeds, spice
blends "for soups and stews", and six recipe titles that name a stew). 39 go to no commodity or a right one. **Four
land on another wrong commodity** and were not fenced, because none is a board input today: "Middle Eastern Beef,
Spinach and Chickpea Stew" (a recipe title) spinach to chickpeas; "Gourmanity Dried Carrots ... Soups, Stews and
Ramen" carrots to ramen; "Emergency Essentials Freeze-Dried Super Sweet Corn #10 Can" sweet-corn to frozen-corn;
"Goya Sofrito Tomato Cooking Base ... For Rice Beans Soups Chili And Stews" tomatoes to rice (its jar sibling
already routes to rice on origin/main).

`audit-match-soundness.ps1` over its own baseline corpus read MOVED=1 DROPPED=3, all four inside the 27 above
(the three Kroger carrot cans and the Diet Coke). Those four entries, and only those, were changed by hand in
`grocery/out/audit/match-baseline.json`; no wholesale `-Accept`. It then read MOVED=0 DROPPED=0, exit 0.

On the live board (seeded, built 2026-09-19T08:12), `audit-food-category.ps1` exits 2 with exactly the two
green-chilli cells and nothing else: the Aldi aioli (`condiment_carrier`) and the Walmart stew (`soup_carrier` and
`canned_carrier`). The new tokens see no other cell on today's board.

### Fixtures (grocery/test-match-lib.ps1, section 2b)

Nine cases added beside the condiment ones; the count guard moves from 26 to 35.

| Label | Name | Routes to |
|---|---|---|
| MUST FIRE | Stokes Green Chile Stew with Pork and Potatoes, Medium, 15 oz Can | none (not green-chilli) |
| MUST FIRE | Great Value Sliced Carrots, 14.5 oz Can | none (not carrots) |
| MUST FIRE | Kroger Sweet Peas & Carrots - 15oz can | none (not canned-peas) |
| MUST FIRE | the mechanism: stew and can reach all 116 produce commodities | |
| MUST NOT FIRE | Large Cantaloupe, 1 ct. | cantaloupe |
| MUST NOT FIRE | Mexican Papayas | papaya |
| CLEAN TWIN | StarKist Chunk Light Tuna in Water Can | canned-tuna (the can word never reached Meat) |
| CLEAN TWIN | Planters ... Mixed Nuts with ... Pecans ... 15.25 oz Can | mixed-nuts (the can word never left produce) |
| CLEAN TWIN | Hunts Tomato Paste with Basil, Garlic and Oregano ... 6 oz. Can | tomato-paste |

The fresh green chile twin ("Fresh Green Chiles, per lb" to green-chilli) was already there.

- Green: `test-match-lib.ps1` exit 0, "match-lib routing fixtures: 35 of 35 pass", then 42,775 corpus names with 0
  divergences, `MATCH-LIB PASSED`.
- Broken once: `commodities.json` and `category-excludes.json` swapped for origin/main's. Exit 1, "MATCH-LIB FAILED
  (routing fixtures: 5 of 35 failed)": the stew routed to green-chilli, the carrot can to carrots, the peas-and-carrots
  can to carrots, the mechanism reached 0 of 116, the Hunt's paste routed to garlic. Restored: md5
  E4844CB45328B78D1318635779168A57 and AB3EFB08669E7551193A2AEBDC3D091D before and after, identical.
- `compare-deals.ps1 -SelfTest` exit 0; `test-commodity-rules.ps1` exit 0 (132 cases); `audit-json-encoding.ps1`
  exit 0.

### What happens at 08:00, and what can still go wrong

- **green-chilli will have no price at any store.** Across all 77,482 names, not one routes to green-chilli under
  these rules. The fresh commodity's include is `green chil(l)i`, `green chile(s)` and `green chili pepper(s)`; a
  real fresh chile sold as "Anaheim", "Hatch" or "New Mexico" goes to `anaheim-peppers` or nowhere, so a real product
  cannot fill the row until a store lists one under those words. That is the right answer for a row whose only
  candidates were a condiment and a stew, but the row will read empty.
- A new wrong product can still win green-chilli if its name says green chile and none of the fenced words: a green
  chile salsa verde is fenced (`\bsalsa\b`), a green chile queso (`queso`), a jarred or canned chile (`\bcanned\b`,
  `\bcans?\b`, `diced`, `roasted`), a sauce (`\bsauce\b`); a "Green Chile Seasoning" is fenced; a "Green Chile
  Burrito" or "Green Chile Chicken Enchilada" frozen meal is fenced only by `\bfrozen\b` if the name says frozen. The
  known-wrong entries catch only these two exact products.
- The known-wrong audit and `audit-food-category` both read RED on the current board until the rebuild, on purpose.

### Check to run after 08:00 tomorrow (2026-09-20)

From the main checkout, after the 08:00 run has committed:

    git pull --rebase origin main
    powershell -NoProfile -File grocery\audit-food-category.ps1
    powershell -NoProfile -File grocery\audit-known-wrong.ps1

Both exit 0. Then:

    $t = [IO.File]::ReadAllText((Resolve-Path public\board.json))
    $t.Contains('burman-s-green-chili-squeeze-aioli'); $t.Contains('Stokes-Green-Chile-Stew')

prints False twice (the board is one 3 MB line, so a Select-String would print all of it; and it carries each product as its store link, not its name: today both patterns match, the Aldi
link `.../burman-s-green-chili-squeeze-aioli-10-oz` and the Walmart link
`.../Stokes-Green-Chile-Stew-with-Pork-and-Potatoes-Medium-15-oz-Can/35230539`), and the newest `grocery\out\comparison-*.json` has a
`built_at` after 08:00 on 2026-09-20.

## Risks and what I did not do

- **green-chilli's only remaining cell is also a wrong product.** Walmart's "Stokes Green Chile Stew with Pork and
  Potatoes, Medium, 15 oz Can" is today's cheapest at $3.07/lb and stays after the rebuild. The fresh-green-chilli
  fence has `\bcanned\b` but not `can`, and `soup_carrier` names soup, chowder, bisque and gumbo but not stew, so
  neither the engine nor `audit-food-category` sees it. It is a canned prepared dish, not a condiment, so it is
  outside this ruling and I did not fence it; fencing it is a one-cell price-moving change (green-chilli would show no
  price at all) and needs its own call. Adding `\bstews?\b` to `soup_carrier` is the class road. **Ruled and done the
  same day: see "Brad's ruling, 2026-09-19 (second)" above.**
- The rebuild moves 79 cells that are not this rule, from roughly 30 commits that landed after f4bd8b66c, one of which
  (efc9c335f, I175 tie-break) says READY FOR BRAD in its own title and is on main anyway.
- Walmart eggplant and Aldi pudding cups lose their price in the rebuild and I have not traced why.

Store: data-quality-craft/applies-here.md (First-match-wins and freshness ranking let the wrong row take a board
cell); memory wrong-product-class-is-a-seller-shape; memory compare-deals-is-not-standalone.
Harness: grocery/compare-deals.ps1 blob a91efa1cba9384fbefc0f6286443ff7dae7d8288, grocery/commodities.json blob
d6fe562cf2cc8b2e4aeeed10b53fb2d73863829a, grocery/category-excludes.json blob 46cbc702f44f3de16b671b79881a51083b7d30d7,
grocery/audit-food-category.ps1 blob 777b562f7464d6ac427c32923a9642422006a297, base origin/main fe2ad786e.
