# Identity matcher: the harder eval (2026-08-02)

Phase 1 reported **AUC 0.985** on 25 negatives that are all dramatically wrong (bath soap,
dog food). This re-measures the SAME model against negatives that are subtle.

- accepted board pairs (positives): **2816**
- OLD negatives (Phase 1's set): **25**
- GOLD negatives (adjudicated wrong-product rulings): **45**
- MINED near-miss negatives (rule-rejected, semantically close): **0**

## AUC

| negative set | n | AUC |
|---|---:|---:|
| Phase 1 (dramatic) | 25 | 0.9160 |
| GOLD (adjudicated) | 45 | 0.8641 |

## The number that decides shipping

AUC is not it. The lane is advisory, so what matters is how many CORRECT pairs a human has
to read in order to be shown the wrong ones.

```
  catch 14/25 OLD (thr 0.1833)  ->  198 of 2816 accepted pairs also flagged (7.0%)
  catch 6/25 OLD (thr 0.0641)  ->  58 of 2816 accepted pairs also flagged (2.1%)
  catch 3/25 OLD (thr 0.0275)  ->  27 of 2816 accepted pairs also flagged (1.0%)
  catch 1/25 OLD (thr 0.0096)  ->  6 of 2816 accepted pairs also flagged (0.2%)
  catch 23/45 GOLD (thr 0.1899)  ->  207 of 2816 accepted pairs also flagged (7.4%)
  catch 10/45 GOLD (thr 0.0779)  ->  75 of 2816 accepted pairs also flagged (2.7%)
  catch 5/45 GOLD (thr 0.0454)  ->  42 of 2816 accepted pairs also flagged (1.5%)
  catch 1/45 GOLD (thr 0.0096)  ->  6 of 2816 accepted pairs also flagged (0.2%)
```

## Calibrated per commodity (the fair test)

Each pair scored against its OWN commodity's accepted distribution, which is what
lib_match's `calibrate` exists to do. If the answer does not improve here, the problem is
not the threshold.

- scorable positives 2754 / gold 43 (a commodity needs 3+ accepted
  products before it has a distribution to calibrate against)
- AUC on the calibrated score: **0.9093**

```
  catch 22/43 GOLD (calibrated) (thr -5.6090)  ->  133 of 2754 accepted pairs also flagged (4.8%)
  catch 9/43 GOLD (calibrated) (thr -14.5101)  ->  49 of 2754 accepted pairs also flagged (1.8%)
  catch 5/43 GOLD (calibrated) (thr -24.3018)  ->  30 of 2754 accepted pairs also flagged (1.1%)
  catch 1/43 GOLD (calibrated) (thr -128.7985)  ->  2 of 2754 accepted pairs also flagged (0.1%)
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

- `0.869`  **corned-beef-hash**  <- MARY KITCHEN Roast Beef Hash, Canned Roast Beef Hash, 14 oz Can
- `0.791`  **ground-beef-93-7**  <- All Natural Extra Lean Ground Beef 96% Lean/4% Fat, 1 lb
- `0.691`  **frozen-vegetables**  <- Birds Eye Steamfresh Cut Green Beans, Frozen Vegetables
- `0.549`  **sun-dried-tomatoes**  <- Gilbert's Sausage, Chicken, Caprese, With Basil, Mozzarella & Sun Dried Tomatoes 10 Oz
- `0.531`  **ground-cloves**  <- Spice Supreme Spice Ground Cloves
- `0.512`  **pork-tenderloin**  <- Prairie Fresh Natural Fresh Pork Half Loin, Boneless, 3.5- 5.5 lb, 22g of Protein per 4oz 
- `0.470`  **ground-pork**  <- Ground Beef and Pork Blend, 80% Lean/20% Fat
- `0.462`  **parmesan**  <- Clancy S Parmesan Garlic Pita Chips 7.33 OZ
- `0.460`  **pork-tenderloin**  <- Smithfield All-Natural Boneless Pork Loin Filet, 1.0 - 2.8 lb, 24 G of Protein per 4 oz Se
- `0.459`  **parmesan**  <- Clancy's Parmesan Garlic Pita Chips

## The accepted pairs the model likes LEAST

The false alarms a low threshold buys. If these read as obviously fine, the lane is
flagging correctness, not error.

- `0.005`  **red-pepper-flakes**  <- Great Value Crushed Red Pepper, 12 oz
- `0.006`  **red-pepper-flakes**  <- Badia Spices Crushed Red Pepper
- `0.006`  **red-pepper-flakes**  <- Smart Way Crushed Red Pepper
- `0.007`  **red-pepper-flakes**  <- That's Smart! Crushed Red Pepper
- `0.008`  **dried-guajillo-chiles**  <- Orale! Guajillo Peppers, 12 oz.
- `0.009`  **red-pepper-flakes**  <- Stonemill Crushed Red Pepper 1.5 OZ
- `0.010`  **refrigerated-biscuits**  <- Pillsbury Southern Homestyle Buttermilk Biscuits 8 Ea
- `0.010`  **cauliflower**  <- Fresh Whole White Cauliflower
- `0.011`  **plantains**  <- Fresh Plantain - Single
- `0.012`  **hot-dogs**  <- Wimmer's Wieners, Skinless 24 Oz
