# Weekly root families: five calls for Brad

From `design/PLAN-weekly-root-families-2026-10-02.md`. Everything that needed no ruling was built and landed on
2026-10-02. These five are yours. None of them shows a reader a wrong price today; each one decides how fast a class of
weekly alerts stops for good.

## 1. Let a sale item jump the Family Fare rotation? (Phase 7)

Today 8 items are on sale with no everyday price behind them, so the store drops off that item when the sale ends.
3 are Family Fare (frozen fries, trash bags, Yukon Gold potatoes), whose everyday prices are re-read 7 a day over 86
days by your ruling of 2026-09-03; a sale item just waits its turn.
**Recommendation: yes.** Same 7-a-day budget, only the order changes: an item on sale with no everyday price goes first.

## 2. Run the slower Family Fare catalog-walk trial (step 3b)? (Phase 7)

The September trial found 2,339 of 5,395 everyday prices in about a third of the catalog, but could not show whether it
covers the rotation or whether a follow-up search works.
**Recommendation: yes, run the trial**, then decide whether to build it. It needs a browser session, so it is a
scheduled run.

## 3. Hy-Vee's missing everyday items: measure first? (Phase 7)

The other 5 of the 8 are Hy-Vee (chicken drumsticks, frozen cauliflower rice, gruyere, quinoa, white wine). Hy-Vee's
everyday pull searched and found nothing, and no planned step covers it.
**Recommendation: measure first:** check whether Hy-Vee carries those five at an everyday price at all. That decides
whether it is a capture problem to fix or a "not carried" fact to record.

## 4. Liquid-ounce sizes on items priced by weight (step 8, the row contract)

The new row check, running in shadow, would empty 24 board cells where a store sells in fluid ounces but the item is
priced per weight ounce: mayonnaise, pickles, relish, evaporated milk, coconut oil and six others. Today those prices
treat a fluid ounce as a weight ounce, which is close for watery foods and wrong for oils and dense sauces.
**Recommendation: give each of the 11 a density** (one number per item) so the sizes convert properly and no cell
empties. The alternatives are changing those items to be priced per fluid ounce, or letting those rows leave the board.
Nothing is enforced until the shadow has run 7 days per store (from 2026-10-09).

## 5. Should an unexplained "cheapest price moved" flag still page? (step 11, the review packet)

Review alerts now go into a packet that explains most of them automatically. The build treated a "cheapest price moved"
flag that nothing explains as a change to a live winning price, so it still reaches triage. New price flags alone did so
on 6 of the last 14 days, and the ruled bar is at most 4 of 14.
**Recommendation: keep it as built for the 14-day window** (2026-10-03 to 2026-10-16) and read the real count; narrow it
only if the bar is missed because of these flags.

Delete this file once all five are ruled.
