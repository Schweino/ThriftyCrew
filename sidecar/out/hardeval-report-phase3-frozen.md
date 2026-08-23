# Identity matcher: the harder eval (2026-08-23, tag `phase3-frozen`, defs `phase3-baseline`)

Phase 1 reported **AUC 0.985** on 25 negatives that are all dramatically wrong (bath soap,
dog food). This re-measures the SAME model against negatives that are subtle.

- accepted board pairs (positives): **2816**
- OLD negatives (Phase 1's set): **25**
- GOLD negatives (adjudicated wrong-product rulings): **45**
- MINED near-miss negatives (rule-rejected, semantically close): **4701**

## AUC

| negative set | n | AUC |
|---|---:|---:|
| Phase 1 (dramatic) | 25 | 0.8941 |
| GOLD (adjudicated) | 45 | 0.8312 |
| MINED (near miss)  | 4701 | 0.9183 |

## The number that decides shipping

AUC is not it. The lane is advisory, so what matters is how many CORRECT pairs a human has
to read in order to be shown the wrong ones.

```
  catch 13/25 OLD (thr 0.1710)  ->  240 of 2816 accepted pairs also flagged (8.5%)
  catch 6/25 OLD (thr 0.0629)  ->  72 of 2816 accepted pairs also flagged (2.6%)
  catch 3/25 OLD (thr 0.0293)  ->  28 of 2816 accepted pairs also flagged (1.0%)
  catch 1/25 OLD (thr 0.0166)  ->  15 of 2816 accepted pairs also flagged (0.5%)
  catch 23/45 GOLD (thr 0.1940)  ->  283 of 2816 accepted pairs also flagged (10.0%)
  catch 10/45 GOLD (thr 0.0896)  ->  107 of 2816 accepted pairs also flagged (3.8%)
  catch 5/45 GOLD (thr 0.0454)  ->  47 of 2816 accepted pairs also flagged (1.7%)
  catch 1/45 GOLD (thr 0.0166)  ->  15 of 2816 accepted pairs also flagged (0.5%)
  catch 2351/4701 MINED (thr 0.0785)  ->  88 of 2816 accepted pairs also flagged (3.1%)
  catch 941/4701 MINED (thr 0.0042)  ->  0 of 2816 accepted pairs also flagged (0.0%)
  catch 471/4701 MINED (thr 0.0004)  ->  0 of 2816 accepted pairs also flagged (0.0%)
  catch 1/4701 MINED (thr 0.0000)  ->  0 of 2816 accepted pairs also flagged (0.0%)
```

## Calibrated per commodity (the fair test)

Each pair scored against its OWN commodity's accepted distribution, which is what
lib_match's `calibrate` exists to do. If the answer does not improve here, the problem is
not the threshold.

- scorable positives 2754 / gold 43 (a commodity needs 3+ accepted
  products before it has a distribution to calibrate against)
- AUC on the calibrated score: **0.9122**

```
  catch 23/43 GOLD (calibrated) (thr -3.3042)  ->  213 of 2754 accepted pairs also flagged (7.7%)
  catch 9/43 GOLD (calibrated) (thr -7.5717)  ->  78 of 2754 accepted pairs also flagged (2.8%)
  catch 5/43 GOLD (calibrated) (thr -13.5238)  ->  37 of 2754 accepted pairs also flagged (1.3%)
  catch 1/43 GOLD (calibrated) (thr -40.2826)  ->  10 of 2754 accepted pairs also flagged (0.4%)
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

- `0.792`  **ground-beef-93-7**  <- All Natural Extra Lean Ground Beef 96% Lean/4% Fat, 1 lb
- `0.757`  **corned-beef-hash**  <- MARY KITCHEN Roast Beef Hash, Canned Roast Beef Hash, 14 oz Can
- `0.663`  **ground-pork**  <- Ground Beef and Pork Blend, 80% Lean/20% Fat
- `0.642`  **sun-dried-tomatoes**  <- Gilbert's Sausage, Chicken, Caprese, With Basil, Mozzarella & Sun Dried Tomatoes 10 Oz
- `0.559`  **frozen-vegetables**  <- Birds Eye Steamfresh Cut Green Beans, Frozen Vegetables
- `0.531`  **ground-cloves**  <- Spice Supreme Spice Ground Cloves
- `0.503`  **pork-tenderloin**  <- Prairie Fresh Natural Fresh Pork Half Loin, Boneless, 3.5- 5.5 lb, 22g of Protein per 4oz 
- `0.498`  **pork-tenderloin**  <- Smithfield All-Natural Boneless Pork Loin Filet, 1.0 - 2.8 lb, 24 G of Protein per 4 oz Se
- `0.379`  **parmesan**  <- Clancy S Parmesan Garlic Pita Chips 7.33 OZ
- `0.378`  **pie-pumpkins**  <- Bakery Fresh Pumpkin Pie

## The accepted pairs the model likes LEAST

The false alarms a low threshold buys. If these read as obviously fine, the lane is
flagging correctness, not error.

- `0.005`  **plums**  <- Plum Black Large
- `0.005`  **plums**  <- Black Plums
- `0.005`  **red-pepper-flakes**  <- Great Value Crushed Red Pepper, 12 oz
- `0.006`  **red-pepper-flakes**  <- Badia Spices Crushed Red Pepper
- `0.006`  **grapes**  <- Black Seedless Grapes, 3 lbs.
- `0.006`  **red-pepper-flakes**  <- Smart Way Crushed Red Pepper
- `0.007`  **red-pepper-flakes**  <- That's Smart! Crushed Red Pepper
- `0.009`  **red-pepper-flakes**  <- Stonemill Crushed Red Pepper 1.5 OZ
- `0.010`  **hot-dogs**  <- Wimmer's Wieners, Skinless 24 Oz
- `0.011`  **plantains**  <- Fresh Plantain - Single
