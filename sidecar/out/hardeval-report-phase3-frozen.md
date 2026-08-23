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
| Phase 1 (dramatic) | 25 | 0.9705 |
| GOLD (adjudicated) | 45 | 0.8329 |
| MINED (near miss)  | 4701 | 0.9559 |

## The number that decides shipping

AUC is not it. The lane is advisory, so what matters is how many CORRECT pairs a human has
to read in order to be shown the wrong ones.

```
  catch 13/25 OLD (thr 0.0022)  ->  42 of 2816 accepted pairs also flagged (1.5%)
  catch 6/25 OLD (thr 0.0006)  ->  12 of 2816 accepted pairs also flagged (0.4%)
  catch 3/25 OLD (thr 0.0004)  ->  5 of 2816 accepted pairs also flagged (0.2%)
  catch 1/25 OLD (thr 0.0002)  ->  0 of 2816 accepted pairs also flagged (0.0%)
  catch 23/45 GOLD (thr 0.0161)  ->  140 of 2816 accepted pairs also flagged (5.0%)
  catch 10/45 GOLD (thr 0.0009)  ->  16 of 2816 accepted pairs also flagged (0.6%)
  catch 5/45 GOLD (thr 0.0005)  ->  9 of 2816 accepted pairs also flagged (0.3%)
  catch 1/45 GOLD (thr 0.0002)  ->  0 of 2816 accepted pairs also flagged (0.0%)
  catch 2351/4701 MINED (thr 0.0020)  ->  37 of 2816 accepted pairs also flagged (1.3%)
  catch 941/4701 MINED (thr 0.0002)  ->  0 of 2816 accepted pairs also flagged (0.0%)
  catch 471/4701 MINED (thr 0.0001)  ->  0 of 2816 accepted pairs also flagged (0.0%)
  catch 1/4701 MINED (thr 0.0000)  ->  0 of 2816 accepted pairs also flagged (0.0%)
```

## Calibrated per commodity (the fair test)

Each pair scored against its OWN commodity's accepted distribution, which is what
lib_match's `calibrate` exists to do. If the answer does not improve here, the problem is
not the threshold.

- scorable positives 2754 / gold 43 (a commodity needs 3+ accepted
  products before it has a distribution to calibrate against)
- AUC on the calibrated score: **0.8693**

```
  catch 22/43 GOLD (calibrated) (thr -8.1939)  ->  344 of 2754 accepted pairs also flagged (12.5%)
  catch 9/43 GOLD (calibrated) (thr -16.8521)  ->  150 of 2754 accepted pairs also flagged (5.4%)
  catch 5/43 GOLD (calibrated) (thr -27.3574)  ->  78 of 2754 accepted pairs also flagged (2.8%)
  catch 1/43 GOLD (calibrated) (thr -77.9646)  ->  17 of 2754 accepted pairs also flagged (0.6%)
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

- `0.973`  **ground-pork**  <- Ground Beef and Pork Blend, 80% Lean/20% Fat
- `0.959`  **pie-pumpkins**  <- Bakery Fresh Pumpkin Pie
- `0.954`  **pork-tenderloin**  <- Prairie Fresh Natural Fresh Pork Half Loin, Boneless, 3.5- 5.5 lb, 22g of Protein per 4oz 
- `0.949`  **ground-beef-93-7**  <- All Natural Extra Lean Ground Beef 96% Lean/4% Fat, 1 lb
- `0.936`  **pork-tenderloin**  <- Smithfield All-Natural Boneless Pork Loin Filet, 1.0 - 2.8 lb, 24 G of Protein per 4 oz Se
- `0.924`  **pie-pumpkins**  <- Marie Callender's Pumpkin Pie 36 Oz
- `0.867`  **ground-beef-93-7**  <- 96 Lean Ground Beef Per LB
- `0.852`  **corned-beef-hash**  <- MARY KITCHEN Roast Beef Hash, Canned Roast Beef Hash, 14 oz Can
- `0.630`  **pork-tenderloin**  <- Prairie Fresh Natural Fresh Pork Half Loin, Boneless, 3.5-6 lb
- `0.328`  **frozen-vegetables**  <- Birds Eye Steamfresh Cut Green Beans, Frozen Vegetables

## The accepted pairs the model likes LEAST

The false alarms a low threshold buys. If these read as obviously fine, the lane is
flagging correctness, not error.

- `0.000`  **apples**  <- Granny Smith Apple
- `0.000`  **bottled-water**  <- Hy-Vee Spring Water 24Pk
- `0.000`  **hot-dogs**  <- Wimmer's Wieners, Skinless 24 Oz
- `0.000`  **pears**  <- Fareway Sliced in Extra Light Syrup Pears
- `0.000`  **blackberries**  <- Siggi's Fruit & Fiber Blueberry Blackberry 5.3oz
- `0.000`  **asparagus**  <- Great Value Asparagus Cut Spears, 14.5 oz
- `0.000`  **frozen-waffles**  <- Fareway 10 Pack Blueberry Waffles
- `0.000`  **cereal**  <- Hy Vee Whole Grain Raisin Bran
- `0.001`  **pineapple**  <- Pineapple Teriyaki Brats 4 Ct.
- `0.001`  **coffee-creamer**  <- Planet Oat Brown Sugar Cookie Oatmilk Creamer 32 Fl Oz
