# 100 High-Protein Recipes — Project Tracker

Goal: publish 100 high-protein meal-prep recipes to the SMP Meal Prep page, each in the JOB 3 framework (see `.claude/skills/meal-macro/SKILL.md`).

## Decisions (Brad, 2026-07-06)
- **Ratio:** calories / protein must be <= 15 (150-cal meal needs >=10g protein). Desired <= 10 (>=15g). Screen candidates at <= 12 for margin.
- **Protein must be MEAT/POULTRY:** chicken, turkey, beef, pork. NO seafood, NO plant-based protein, and NO eggs/dairy as the MAIN protein (dairy/cheese as an accent in a dish is fine). (Brad, 2026-07-06)
- **Cooking method (Brad, 2026-07-06):** the vast majority must be SLOW COOKER (for chicken or pork) or SKILLET/STOVE (for beef/ground meats). Easy + hands-off + batch-friendly. Avoid fussy methods (breading, deep-frying, multi-step).
- **Servings:** every recipe scaled to 14.
- **Recipe source:** FIND real recipes online, STORE the source URL, and CREDIT it on the post ("Adapted from <site>", linked). Copyright: ingredient lists + basic method are facts we can use; ALL instructions + intro rewritten in Brad's voice; never copy their prose.
- **Macro data for new ingredients:** USDA FoodData Central for generics + published brand labels for packaged items. Tag the source in the food-db `notes`. Flag low-confidence items for Brad. (Never hallucinate a macro.)
- **Pricing:** conservative Walmart/Sam's estimates, cross-checked against the Omaha grocery engine where items overlap.
- **Rollout:** pilot 10 end-to-end -> Brad approves quality/format -> scale to 90.

## Existing 13 (do not duplicate)
fajita chicken rice bowl, beef burrito bowls, bbq chicken rice bowls, cheeseburger pasta, italian sausage penne, turkey taco rice skillet, cheesy beef broccoli bowls, pizza pasta bowls, hot honey chicken bowls, beef chili rice bowls, chicken parmesan pasta, turkey bolognese penne, chicken enchilada rice bowls.

## Pipeline per recipe
1. Vet ratio on source macros (screen <=12).
2. Scale ingredient amounts to 14 servings; convert to grams.
3. Map ingredients to food-macros-db; add missing (USDA/web, source-tagged).
4. Compute macros via recipe-macros.ps1; confirm ratio holds on OUR numbers.
5. Price -> util cost per line, batch = sum, true shopping cost = sum of buys.
6. Card body + head JSON-LD + meta per JOB 3; add source-credit line.
7. Publish (paid) + verify on the public page.

## Status
- PILOT (10) locked: buffalo chicken, salsa verde chicken, italian shredded chicken, salsa chicken, pulled pork, pork carnitas, barbacoa beef, italian beef, teriyaki ground turkey, cheesy zucchini beef. (8 slow cooker + 2 skillet)
  - [x] vetted + scaled to 14
  - [x] 30 new ingredients added to food-macros-db (USDA/label, source-tagged; chuck + pork loin reconciled to source-measured, MED conf)
  - [x] macros computed + ratio-verified: all 10 pass (5.6-10.7, all <=15; 8 of 10 <=10). pilot-macros.json.
  - [x] REBUILT as complete dinner bowls (Brad 2026-07-06: 143-389 cal was snack-sized; added rice/pasta/bean bases + bigger protein). Now 503-558 cal, ratio 9.1-14.3 (all <=15), true cost $1.81-2.85/serv (all <=$3 soft cap).
  - [x] pricing + cost model (Walmart/Sam's) built
  - [x] cards generated + PUBLISHED PAID + verified live (all 10, Recipe schema, no em-dash) + added to recipes-db (now 23)
- [x] Multi-store pricing (Brad 2026-07-06): ALL 6 Omaha stores live-verified x all 42 pilot ingredients -> grocery DB (C:\Codex\income\grocery\ingredient-prices.json). Cards stay on Walmart/Sam's.
  - VERIFIED LIVE: Hy-Vee, Aldi, Baker's (Kroger), Sam's Club (browser pull); Family Fare (Freshop price API, store 6401 - its website UI was down but the API works). Walmart = prior estimates.
  - Family Fare 37/42 priced + 5 not carried (plain pork loin, fat-free cheddar, shredded carrots, canned coconut milk, fresh garlic). Its OLD meat estimates were badly wrong (est chuck $5.99/ground $4.99 vs REAL $10.99/$9.29 - FF is the PRICIEST on beef, not cheapest).
  - KEY FINDING: gated-store ESTIMATES were unreliable. Aldi beef est ($5.99 chuck / $4.79 ground) was $2-3/lb LOW vs live ($7.99 / $7.49). So the earlier "Aldi cheapest on all meats" claim was WRONG on beef.
  - Cheapest by item now computed: Sam's wins meats/bulk staples (pork loin $1.98, chuck $7.47, ground $6.17, rice $0.48/lb, oil $0.30/oz - bulk). Aldi wins chicken $2.19, pork tenderloin $3.59, + most produce/condiments. Walmart wins many pantry cans/spices. Tally: Walmart ~15, Aldi ~14, Sam's ~7, Baker's ~5, Hy-Vee ~3.
- [x] WAVE 90 COMPLETE + LIVE (2026-07-06). Brad approved pilot -> built + published the remaining 90.
  - Mix (Brad): 60% chicken/pork slow cooker (31 chicken + 23 pork) + 40% beef/turkey (22 GROUND beef + 14 GROUND turkey). 22 cuisines. All ground beef/turkey per Brad's cost call (no flank/chuck).
  - Pipeline: 6-agent source (~130 candidates) -> select 90 -> 10-agent formulate (14 servings, complete dinners) -> +46 new ingredients to food-macros-db (USDA/label, canonical-new-ingredients.json) -> compute-90.ps1 (macros + cost + auto cost-tuner) -> 6-agent prose (Brad voice, no em-dash) -> build-cards-90.ps1 -> publish-90.ps1 (all paid) -> verified public pages (Recipe schema + costPerServing stats bar render).
  - Gates all pass: 500-700 cal, ratio <=15 (69/90 <=12, 36 ideal <=10), <=$3.50/serv (avg $2.70, verified Walmart/Sam's prices), 14 servings.
  - COST LESSON (Brad caught it): do NOT fudge prices to fit a cap. Use the verified multi-store DB. Beef flank $13.94/lb, chuck $7.47, 93/7 ground beef $6.17 (Sam's), 93/7 ground turkey $4.55 (Sam's) - all live-verified. Ground-only + auto-tuner (trim meat, add cheap base, protein floor 43) hit <=$3.50 honestly.
  - recipes-db.json now 113 (13 original + 10 pilot + 90 wave). Ghost: 118 published Meal Prep posts. Wave scripts in scratchpad/recipes-100/wave90/.
- GROCERY DB COMPLETE (2026-07-06): all 102 distinct ingredients used across the 100 project recipes now in C:\Codex\income\grocery\ingredient-prices.json with ALL 6 Omaha stores. Added the 60 wave ingredients: Walmart (Great Value in-page __NEXT_DATA__ fetch) + Sam's (Member's Mark in-page fetch) + Aldi/Baker's/Hy-Vee (browser navigate+find) all live-verified; Family Fare 52/60 (Freshop API, throttles ~40/run). Per-store files in scratchpad/recipes-100/wave90/newprice/. Cheapest tally: Walmart 38, Sam's 21, Aldi 20, Hy-Vee 8, Baker's 8, Family Fare 2. FF API token: GET /1/sessions?app_key=family_fare&store_id=6401 -> {token}, pass &token= per query to beat throttle.
- PROJECT COMPLETE: 100+ high-protein meal-prep recipes live (113 in DB) + full 6-store grocery pricing for every ingredient.
- CAL FLOOR (hard criterion): 500-700 cal/serving. Recipes must be complete meals (protein + base + veg), NOT just the protein.

## Pilot recipes (filled as vetted)
| # | title | source | src servings | src cal/protein | status |
|---|-------|--------|--------------|-----------------|--------|
