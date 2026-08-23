# Identity matcher: the harder eval (2026-08-23, tag `ft-v2`, defs `phase3-baseline`)

Phase 1 reported **AUC 0.985** on 25 negatives that are all dramatically wrong (bath soap,
dog food). This re-measures the SAME model against negatives that are subtle.

- accepted board pairs (positives): **2816**
- OLD negatives (Phase 1's set): **25**
- GOLD negatives (adjudicated wrong-product rulings): **45**
- MINED near-miss negatives (rule-rejected, semantically close): **5132**

## AUC

| negative set | n | AUC |
|---|---:|---:|
| Phase 1 (dramatic) | 25 | 0.9966 |
| GOLD (adjudicated) | 45 | 0.9963 |
| MINED (near miss)  | 5132 | 0.9965 |

## The number that decides shipping

AUC is not it. The lane is advisory, so what matters is how many CORRECT pairs a human has
to read in order to be shown the wrong ones.

```
  catch 13/25 OLD (thr 0.0008)  ->  5 of 2816 accepted pairs also flagged (0.2%)
  catch 6/25 OLD (thr 0.0002)  ->  2 of 2816 accepted pairs also flagged (0.1%)
  catch 3/25 OLD (thr 0.0001)  ->  1 of 2816 accepted pairs also flagged (0.0%)
  catch 1/25 OLD (thr 0.0000)  ->  1 of 2816 accepted pairs also flagged (0.0%)
  catch 23/45 GOLD (thr 0.0007)  ->  5 of 2816 accepted pairs also flagged (0.2%)
  catch 10/45 GOLD (thr 0.0001)  ->  2 of 2816 accepted pairs also flagged (0.1%)
  catch 5/45 GOLD (thr 0.0001)  ->  1 of 2816 accepted pairs also flagged (0.0%)
  catch 1/45 GOLD (thr 0.0000)  ->  1 of 2816 accepted pairs also flagged (0.0%)
  catch 2567/5132 MINED (thr 0.0001)  ->  1 of 2816 accepted pairs also flagged (0.0%)
  catch 1027/5132 MINED (thr 0.0000)  ->  0 of 2816 accepted pairs also flagged (0.0%)
  catch 514/5132 MINED (thr 0.0000)  ->  0 of 2816 accepted pairs also flagged (0.0%)
  catch 1/5132 MINED (thr 0.0000)  ->  0 of 2816 accepted pairs also flagged (0.0%)
```

## Calibrated per commodity (the fair test)

Each pair scored against its OWN commodity's accepted distribution, which is what
lib_match's `calibrate` exists to do. If the answer does not improve here, the problem is
not the threshold.

- scorable positives 2754 / gold 43 (a commodity needs 3+ accepted
  products before it has a distribution to calibrate against)
- AUC on the calibrated score: **0.9858**

```
  catch 22/43 GOLD (calibrated) (thr -220742.7067)  ->  31 of 2754 accepted pairs also flagged (1.1%)
  catch 9/43 GOLD (calibrated) (thr -418910.4246)  ->  17 of 2754 accepted pairs also flagged (0.6%)
  catch 5/43 GOLD (calibrated) (thr -837362.6986)  ->  8 of 2754 accepted pairs also flagged (0.3%)
  catch 1/43 GOLD (calibrated) (thr -8311669.1562)  ->  0 of 2754 accepted pairs also flagged (0.0%)
```

## The adjudicated-wrong pairs the model likes MOST

These are the ones it would never flag. Each is a product a reasoner ruled is not the
commodity, scored as if it belongs. **Read the list before deciding what to fine-tune**:
they are not one failure, they are two, and only one of them is learnable from a name.

- CARRIER errors (the commodity is an INGREDIENT inside a different product): Parmesan
  Garlic Pita Chips as parmesan, a chicken sausage with sun-dried tomatoes as sun-dried
  tomatoes. A model can learn these, and more labelled examples would help.
- SPECIFICATION errors (right product family, wrong grade or cut): Roast Beef Hash against
  corned-beef-hash, 96% lean against ground-beef-93-7, Pork Half Loin against
  pork-tenderloin, a beef-and-pork blend against ground-pork. Nothing in the NAME says
  which grade a commodity wants - that fact lives in the commodity's own definition, not
  in the product string - so no amount of fine-tuning on names will separate them. These
  need a grade/cut check, which is a different mechanism.

One caveat on the gold set itself: `ground-cloves <- Spice Supreme Spice Ground Cloves` is
in the blocklist as a PRICE defect, not an identity one. The product IS ground cloves. The
model scoring it 0.531 is correct behaviour counted as a miss, so treat 45 as the
pessimistic denominator.

- `0.164`  **frozen-vegetables**  <- Birds Eye Steamfresh Cut Green Beans, Frozen Vegetables
- `0.063`  **jalapenos**  <- San Marcos Traditional Recipe Crunchy Whole Jalapenos Peppers 26 Oz
- `0.033`  **ground-cloves**  <- Spice Supreme Spice Ground Cloves
- `0.027`  **dried-thyme**  <- Local Roots Organic Thyme
- `0.010`  **baking-soda**  <- Arm & Hammer Baking Soda Clumping Litter, Fresh Scent
- `0.009`  **corned-beef-hash**  <- MARY KITCHEN Roast Beef Hash, Canned Roast Beef Hash, 14 oz Can
- `0.008`  **olive-oil**  <- Violi Mediterranean Blend, Italian Sunflower & Extra Virgin Olive Oil 33.8 Oz
- `0.007`  **butter**  <- Nature's Own Butter Buns Hot Dog Buns, Non-GMO Hot Dog Buns, 8 Count
- `0.005`  **stain-remover**  <- Lysol Toilet Bowl Cleaner Clinging Gel, Power, Disinfecting Bathroom Cleaner and Toilet Bo
- `0.004`  **tortillas**  <- Quest Tortilla Style 10-20g Protein Chip Variety Pack, Salsa Verde and Chili Lime, 14 ct.

## The accepted pairs the model likes LEAST

The false alarms a low threshold buys. If these read as obviously fine, the lane is
flagging correctness, not error.

- `0.000`  **blackberries**  <- Siggi's Fruit & Fiber Blueberry Blackberry 5.3oz
- `0.000`  **blueberries**  <- Salad Pizazz! Dried Blueberries and Honey Pecans Fruit & Nut Topping, 3.5 oz Bag
- `0.000`  **relish**  <- Dill Relish
- `0.000`  **pineapple**  <- Pineapple Teriyaki Brats 4 Ct.
- `0.001`  **hot-dogs**  <- Wimmer's Wieners, Skinless 24 Oz
- `0.001`  **black-pepper**  <- McCormick Seasoning, Himalayan Pink Salt with Black Pepper and Garlic, 6.5 oz Bottle
- `0.001`  **clementines**  <- Fareway Mandarin Oranges
- `0.001`  **egg-whites**  <- No Yolks Extra Broad Egg White Noodles, 12 ounce bag
- `0.001`  **sun-dried-tomatoes**  <- Gilbert's Sausage, Chicken, Caprese, With Basil, Mozzarella & Sun Dried Tomatoes 10 Oz
- `0.002`  **frozen-meatballs**  <- Marie Callender's Swedish Meatballs Bowl Frozen Meal 11.5 Oz
