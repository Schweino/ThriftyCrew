# Spec bid/gpu reconciliation worklist (2026-07-26 Fable re-review)

**THE FINDING:** the 513 specs disagree INTERNALLY on 50 ingredient items - the same display item
carries different board bids (and sometimes different gpu bases) depending on which recipe era wrote it
(r100 writers used specific bids; the originals/db era used generic ones). Both variants resolve on the
feed at DIFFERENT prices, so two live cards can price the same ingredient differently today.
`pipeline\regenerate-ingredient-map.ps1` papers over this for the TOOLS (majority-feed rule, conflicts
listed in the map's own `conflicts` block); this worklist is the SPEC-side fix - converge each item to
ONE bid across all specs, then recost + rebuild + republish the affected cards.

**Every change here moves live "current cheapest" numbers.** Work it as its own audited pass (Fable),
per class below. After the specs converge, regenerate-ingredient-map picks the result up automatically.

## Class 1 - BOARD DUPLICATES (fix the BOARD, not the specs, first)
Synonym commodity rows on the feed with independently drifting prices. These are r300 "proxy item_ids"
leftovers. Merging each pair on the board (one canonical id, aliases retired) collapses many spec
conflicts automatically and fixes the price gap at the source:
- worcestershire ($0.10/floz) vs worcestershire-sauce ($0.0686/floz)  <- 46% gap between synonym rows!
- jalapenos ($1.2246/lb) vs jalapeno ($1.90/lb)                       <- 55% gap
- fresh-ginger ($3.97/lb) vs ginger ($3.41/lb)
- frozen-peas ($0.0612/oz) vs frozen-green-peas ($0.078/oz)
- flour vs all-purpose-flour (same price, per-lb vs per-oz bases)
- cucumbers vs cucumber (identical price)   - feta vs feta-cheese (identical)
- cabbage vs green-cabbage (identical)      - bacon vs hickory-smoked-bacon (identical)
- canned-corn (per-oz) vs canned-sweet-corn (per-each; ~same real price)
- cilantro vs fresh-cilantro; green-olives vs olives; parmesan vs parmesan-cheese;
  chipotle-adobo vs chipotle-in-adobo; canned-green-chilies vs diced-green-chiles;
  canned-pineapple vs pineapple-chunks; raisins vs golden-raisins (distinct products? verify);
  italian-sausage vs hot-italian-sausage; sour-cream vs light-sour-cream; mushrooms vs white-mushrooms;
  cream-cheese vs 1-3-fat-cream-cheese; russet-potatoes vs potato; bell-peppers vs green-bell-pepper

## Class 2 - PRODUCT-ACCURACY CALLS (the majority side prices a cheaper DIFFERENT product)
Converging to the SPECIFIC product is the honest fix, and it RAISES displayed cheapest numbers on the
affected recipes (Brad decision - see the session report):
| item | majority (recipes) | specific (recipes) | price gap |
|---|---|---|---|
| 93/7 Ground Turkey | ground-turkey x73 $2.66/lb | 93-7-ground-turkey x16 $4.33/lb | +63% |
| Boneless Skinless Chicken Thigh | chicken-thighs (bone-in) x60 $1.28/lb | boneless... x1 $1.99/lb | +55% |
| 93/7 Ground Beef | ground-beef-8020 x46 $5.56/lb | 93-7-ground-beef x27 $6.17/lb | +11% |
| Cherry Tomatoes | tomatoes x7 $1.15/lb | cherry-tomatoes x2 ~$3.42/lb-eq | ~3x |
| Red Bell Pepper | bell-peppers x39 $0.83 | red-bell-pepper x6 $0.98 | +18% |
| Red Onion | onions x13 $0.74/lb | red-onion x17 $1.33/lb | +80% (majority ALREADY specific) |
| Smoked Paprika | paprika x18 | smoked-paprika x4 | +46% |
| Sriracha | hot-sauce x4 | sriracha x1 | +97% |
| Greek Yogurt | yogurt x14 | greek-yogurt x9 | +6% |
| Penne Pasta | pasta x3 | penne-pasta x13 (majority specific) | +37% |
| Seasoned Black Beans | canned-black-beans x12 | seasoned-black-beans x18 (majority specific) | +91% |
| Buffalo Wing Sauce | hot-sauce x1 | buffalo-wing-sauce x2 | +20% |
| Salsa Verde | salsa x1 | salsa-verde x4 | +68% |
| Smoked Turkey Sausage | kielbasa x2 | smoked-turkey-sausage x20 | +10% |
| Sugar-Free Maple Syrup | maple-syrup x2 (floz) | sugar-free... x1 (oz) | units differ too |
| Marinara Sauce | pasta-sauce x9 | marinara-sauce x7 | +15% |
| Coconut Milk | coconut-milk-canned x20 | coconut-milk x8 (beverage row? verify product) | -24% |
| Reduced Fat Mozzarella | shredded-cheese x20 | reduced-fat-mozzarella x7 | +13% |
| Ricotta Cheese | cottage-cheese x5 (BUDGET-SWAP? check prose) | ricotta x4 | +61% |
| Rice | rice x211 (item says just 'Rice') | jasmine-rice x79 | +74% - check per-recipe prose (many r100 recipes SAY jasmine) |
| Frozen Chopped Spinach | spinach x18 (FRESH row - overstates) | frozen-chopped-spinach x1 | -47% (fix LOWERS) |
| Broccoli Florets | frozen-broccoli-florets x28 | broccoli (fresh) x8 | per-recipe (fresh vs frozen intent) |
| Carrots | carrots x72 | shredded-carrots x6 | per-recipe (shredded intent) |
| Frozen Green Peas | frozen-peas x25 | frozen-green-peas x1 | board-dup class |
| Golden Raisins | raisins x9 | golden-raisins x1 | verify distinct product |
| Corn Chips | potato-chips x1 (WRONG product) | corn-chips x1 | fix the 1 |

## Class 3 - OUTRIGHT BUG
- 'Korean glass noodles (dangmyeon)': one spec maps it to **cornstarch** ($0.1181/oz). Glass noodles are
  sweet-potato-starch noodles; rice-noodles (x2) is the reasonable proxy. Fix the 1 spec.

## Recommended order
1. Class 1 board dedup (collapses many conflicts at the source, no per-recipe judgment).
2. Class 3 the cornstarch bug (one spec).
3. Class 2 with Brad's direction on the accuracy-vs-cheaper-looking tradeoff, batched by item,
   recost -Slugs + rebuild + republish + re-anchor prose per batch, guards between batches.
