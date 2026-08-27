# Food-DB source backfill: what FDC would and would not confirm

Rung 2 of `design\PLAN-food-db-provenance-2026-08-26.md`, run 2026-08-26. 98 row(s) put to USDA's curated tiers: **68 corroborated** (2 of them as a stated proxy), **0 disagreed**, **30 ruled to have no curated entry**, **0 not yet ruled on**.

**Nothing on this page was overwritten, and nothing was written on a machine's guess.** Two independent tests must both hold before a `source` is written: a frontier ruling that this FDC entry IS this food (`db\food-source-approvals.json`), and the stored numbers still agreeing with it. The first pass without the ruling proposed Croutons for Bread Crumbs, rice cakes for Rice and chicken BREAST for chicken thigh - all four macros inside tolerance.

Tolerance: calories 10% or 15 kcal per 100 g, whichever is larger; each macro 15% or 2 g.

## Disagreed - an approved entry whose numbers do not match. A person decides.

None.

## No curated entry is this food - these need a label (rung 4) or a stated proxy

- **Rice** (256,589 g live) - FDC's curated shelf for this term returns rice CAKES and rice CRACKERS, not dry long-grain rice. No curated entry for the food was offered.
- **Boneless Skinless Chicken Thigh** (158,584 g live) - the entire shelf returned is chicken BREAST. Asking for a thigh returned no thigh.
- **Beef Chuck Roast** (92,641 g live) - every chuck-eye candidate reads 24-27 g protein against the stored 19.6, and the stored row's own note says it is a raw basis reflecting a slow-cooked yield. Two different claims; a person decides.
- **Pork Chops** (37,750 g live) - no candidate agrees - the bone-in center loin entries read 167-170 cal against the stored 152.
- **Green Bell Peppers** (28,136 g live) - FDC's curated tiers returned nothing for this term.
- **Red Bell Pepper** (22,934 g live) - FDC's curated tiers returned nothing for this term.
- **Heavy Cream** (21,718 g live) - the stored row reads 0.0 g protein and 6.7 g carbs per 100 g against USDA's 2.8/2.8. That is a real question about the row, not a citation.
- **Sweet Whole Kernel Corn** (19,339 g live) - every canned sweet corn entry reads 14.3 g carbs against the stored 11.2.
- **Cannellini Beans** (17,676 g live) - the only agreeing candidate is canned PINTO beans.
- **Garlic** (17,523 g live) - USDA raw garlic is 149 cal per 100 g against the stored 133.
- **Sweet Potatoes** (12,979 g live) - the shelf offers only leaves, canned mash and babyfood - no raw sweet potato entry was returned.
- **Reduced Fat Mozzarella** (10,719 g live) - the only agreeing candidate is reduced-fat PROVOLONE.
- **Cherry Tomatoes** (8,360 g live) - the only agreeing candidate is CANNED tomatoes packed in juice; the row is fresh.
- **Parmesan Cheese** (6,893 g live) - the hard entry disagrees on carbs (3.2 vs 7.1) and the grated entries disagree on protein. No clean answer.
- **1/3 Fat Cream Cheese** (5,777 g live) - low-fat cream cheese reads 208 cal / 16.7 g fat against the stored 250 / 21.4.
- **Olives** (4,747 g live) - the only candidates returned are OLIVE LOAF (a pork lunch meat) and olive oil.
- **Apple** (4,495 g live) - the shelf returns rose-apples, apple strudel, apple croissants and babyfood juice. No raw apple entry.
- **Pineapple Chunks** (4,139 g live) - every agreeing candidate is a JUICE or juice blend, not fruit.
- **Orange Juice** (3,441 g live) - every agreeing candidate is BABYFOOD juice.
- **Fat Free Cottage Cheese** (2,898 g live) - the shelf returns fat-free CREAM, AMERICAN and CHEDDAR cheese - no cottage cheese.
- **Fat Free Cheddar** (2,536 g live) - USDA fat-free cheddar reads 7.1 g carbs against the stored 10.7.
- **Korean glass noodles (dangmyeon)** (1,891 g live) - the shelf returns RICE noodles; dangmyeon is sweet-potato starch, a different food.
- **Feta Cheese** (1,841 g live) - USDA feta reads 14.2 g protein against the stored 17.9.
- **Peanuts** (1,175 g live) - the only candidate returned is a peanut CANDY BAR.
- **Ground Turmeric** (329 g live) - the stored row reads 0.0 g protein and 0.0 g fat against USDA's 9.7 and 3.2. A real question about the row.
- **Red Pepper Flakes** (207 g live) - the agreeing-by-name candidates are sweet red PEPPERS, raw; the cayenne spice entry disagrees on protein and fat against a stored 0.0/0.0.
- **Ground Allspice** (178 g live) - stored 0.0 protein / 0.0 fat / 52.6 carbs against USDA's 6.1 / 8.7 / 72.1.
- **Ground Ginger** (90 g live) - stored 0.0 protein / 0.0 fat against USDA's 9.0 / 4.2.
- **Poppy Seeds** (39 g live) - stored 35.7 / 35.7 / 35.7 is three identical numbers, which is what a household serving rounded to one decimal does; USDA reads 18.0 P / 28.1 C / 41.6 F.
- **Fat Free Mozzarella** (0 g live) - the shelf returns fat-free cream cheese, sour cream and American - no mozzarella.

## Corroborated as a PROXY - visibly not the real thing, which is the point

- **Green Onions** - FDC 170006 Onions, young green, tops only. FDC's curated set carries scallion TOPS ONLY, not the whole trimmed onion the recipes use. Stands in, and says so.
- **Mayonnaise** - FDC 167736 Mayonnaise dressing, no cholesterol. the only corroborating curated entry is a no-cholesterol dressing; Great Value mayonnaise is egg-based. Stands in, and says so.

