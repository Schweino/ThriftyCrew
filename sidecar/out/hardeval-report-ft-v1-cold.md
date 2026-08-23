# Identity matcher: the harder eval (2026-08-23, tag `ft-v1-cold`, defs `phase3-baseline`)

Phase 1 reported **AUC 0.985** on 25 negatives that are all dramatically wrong (bath soap,
dog food). This re-measures the SAME model against negatives that are subtle.

- accepted board pairs (positives): **518**
- OLD negatives (Phase 1's set): **5**
- GOLD negatives (adjudicated wrong-product rulings): **6**
- MINED near-miss negatives (rule-rejected, semantically close): **964**

## AUC

| negative set | n | AUC |
|---|---:|---:|
| Phase 1 (dramatic) | 5 | 0.9938 |
| GOLD (adjudicated) | 6 | 0.9920 |
| MINED (near miss)  | 964 | 0.9925 |

## The number that decides shipping

AUC is not it. The lane is advisory, so what matters is how many CORRECT pairs a human has
to read in order to be shown the wrong ones.

```
  catch 3/5 OLD (thr 0.0010)  ->  1 of 518 accepted pairs also flagged (0.2%)
  catch 2/5 OLD (thr 0.0008)  ->  1 of 518 accepted pairs also flagged (0.2%)
  catch 1/5 OLD (thr 0.0003)  ->  0 of 518 accepted pairs also flagged (0.0%)
  catch 1/5 OLD (thr 0.0003)  ->  0 of 518 accepted pairs also flagged (0.0%)
  catch 3/6 GOLD (thr 0.0010)  ->  1 of 518 accepted pairs also flagged (0.2%)
  catch 2/6 GOLD (thr 0.0008)  ->  1 of 518 accepted pairs also flagged (0.2%)
  catch 1/6 GOLD (thr 0.0003)  ->  0 of 518 accepted pairs also flagged (0.0%)
  catch 1/6 GOLD (thr 0.0003)  ->  0 of 518 accepted pairs also flagged (0.0%)
  catch 483/964 MINED (thr 0.0001)  ->  0 of 518 accepted pairs also flagged (0.0%)
  catch 194/964 MINED (thr 0.0000)  ->  0 of 518 accepted pairs also flagged (0.0%)
  catch 97/964 MINED (thr 0.0000)  ->  0 of 518 accepted pairs also flagged (0.0%)
  catch 1/964 MINED (thr 0.0000)  ->  0 of 518 accepted pairs also flagged (0.0%)
```

## Calibrated per commodity (the fair test)

Each pair scored against its OWN commodity's accepted distribution, which is what
lib_match's `calibrate` exists to do. If the answer does not improve here, the problem is
not the threshold.

- scorable positives 518 / gold 6 (a commodity needs 3+ accepted
  products before it has a distribution to calibrate against)
- AUC on the calibrated score: **0.9833**

```
  catch 3/6 GOLD (calibrated) (thr -98604.2900)  ->  4 of 518 accepted pairs also flagged (0.8%)
  catch 2/6 GOLD (calibrated) (thr -98658.1345)  ->  4 of 518 accepted pairs also flagged (0.8%)
  catch 1/6 GOLD (calibrated) (thr -4131859.6016)  ->  0 of 518 accepted pairs also flagged (0.0%)
  catch 1/6 GOLD (calibrated) (thr -4131859.6016)  ->  0 of 518 accepted pairs also flagged (0.0%)
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

- `0.087`  **frozen-vegetables**  <- Birds Eye Steamfresh Cut Green Beans, Frozen Vegetables
- `0.044`  **butter**  <- Nature's Own Butter Buns Hot Dog Buns, Non-GMO Hot Dog Buns, 8 Count
- `0.015`  **stain-remover**  <- Lysol Toilet Bowl Cleaner Clinging Gel, Power, Disinfecting Bathroom Cleaner and Toilet Bo
- `0.001`  **parmesan**  <- Clancy S Parmesan Garlic Pita Chips 7.33 OZ
- `0.001`  **parmesan**  <- Clancy's Parmesan Garlic Pita Chips
- `0.000`  **parmesan**  <- Idahoan Baby Reds with Roasted Garlic & Parmesan Mashed Potatoes

## The accepted pairs the model likes LEAST

The false alarms a low threshold buys. If these read as obviously fine, the lane is
flagging correctness, not error.

- `0.000`  **egg-whites**  <- No Yolks Extra Broad Egg White Noodles, 12 ounce bag
- `0.001`  **hand-soap**  <- Safeguard Ultimate Care Hand Wash, Variety Pack, 15.5 fl. oz., 3 pk.
- `0.001`  **frozen-fries**  <- McCain fries or onion rings, 14 to 26 oz., 2/ $7.00
- `0.006`  **frozen-lasagna**  <- Healthy Choice Cafe Steamers Turkey Sausage Lasagna Bowl, Frozen Meal, 10 oz. Bowl
- `0.007`  **coffee-creamer**  <- Planet Oat Brown Sugar Cookie Oatmilk Creamer 32 Fl Oz
- `0.016`  **butter**  <- Fareway Solid Butter
- `0.017`  **frozen-meatballs**  <- Marie Callender's Swedish Meatballs Bowl Frozen Meal 11.5 Oz
- `0.024`  **frozen-meatballs**  <- Hy-Vee Beef Meatballs
- `0.032`  **frozen-corn**  <- Birds Eye Super Sweet Corn 10 Oz
- `0.124`  **frozen-waffles**  <- Fareway 10 Pack Blueberry Waffles
