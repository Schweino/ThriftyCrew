---
name: grocery-accuracy-sample
description: DISABLED 2026-08-22 by Brad: the three TC Windows tasks are the ONLY routines that should fire. NOTE this was the only out-of-band accuracy measurement of the board (blind n=100 weekly sample, Wilson interval) - nothing else measures accuracy independently. Run it on demand, or fold it into a Windows task if the measurement is wanted back on a clock. Prompt kept for reference.
---

You are running the weekly out-of-band accuracy measurement for the Thrifty Crew grocery board.

Working directory: C:\Codex\ThriftyCrew\grocery

## Why this exists (read this, it changes how you behave)

Every number this estate prints about its own accuracy is written by the same code that wrote the board. On 2026-07-30 every internal report read clean while a bag of cat food held the SALMON crown. 99 wrong numbers reached shoppers in 22 days and the guards caught 5% of them. **This task is the only statement about the board that the board did not write about itself.** Its value comes entirely from being independent, so the blindness rules below are not ceremony.

The task has been failing quietly in one specific way: the sampler draws 100 cells and only 20 to 24 verdicts ever come back. At n=22 the 95% interval is about +/-14 points, which cannot tell a 2% board from a 15% one. **Answering all 100 is the entire point of this run.** A run that returns 30 verdicts has produced nothing usable.

## Step 1: draw the sample

```
cd C:\Codex\ThriftyCrew\grocery
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-verification-sample.ps1 -N 100
```

This writes two files dated for the current board:
- `out\verification-worklist-<DATE>.csv` - the BLIND worklist you fill in
- `out\verification-sample-<DATE>.json` - the SEALED KEY holding the board's own answers

**DO NOT OPEN THE SEALED KEY JSON, and do not read comparison-*.json, board.json, recipe-board.json or any page of the live site for the commodities you are verifying.** Shown our answer, a verifier confirms the price and never asks whether the row is the right product at all. That is precisely how the cat food survived. If you open it, this run is worthless and you should say so rather than report a number.

The worklist columns are: `ticket, seq, commodity, unit, store, verdict, found_product, found_price, note`. You fill in `verdict`, `found_product`, `found_price` and optionally `note`. You are given only the commodity LABEL, its UNIT and the STORE.

## Step 2: verify all 100

Fan this out with the Agent tool, **one agent per store** (there are 7: Walmart, Aldi, Hy-Vee, Baker's, Family Fare, Fareway, Sam's Club). Each agent gets only its own store's rows, roughly 10 to 20 each, which is tractable. Launch them in a single message so they run concurrently. Give each agent the blindness rules above and the verdict vocabulary below verbatim.

For each row the agent opens the store's own site and answers one question: **what is the cheapest product at this store that genuinely IS this commodity, and what does it cost in the stated unit?** Then records `found_product` and `found_price` and picks a verdict:

- `ok` - the board names the cheapest qualifying product at this store and its price is right
- `wrong-product` - the product on the board is not this commodity at all (the cat-food-as-salmon class)
- `wrong-price` - right product, wrong number
- `wrong-size` - right product, but the size or pack basis makes the per-unit wrong
- `missing` - the store does not sell this commodity at all
- `unverifiable` - bot wall, sign-in wall, or the site would not answer. NOT a defect and NOT a pass; these leave the denominator and are reported separately

Note that `ok` requires the CHEAPEST qualifying product, not merely a real product at a real price. That strictness is deliberate: cheapest is what the board claims.

**PRICE MODE MATTERS AND IS A KNOWN TRAP.** The board publishes IN-STORE shelf prices. Aldi and Fareway serve a marked-up DELIVERY price through Instacart, so an agent reading an Instacart page will flag a correct board cell as wrong-price. Use the store's own storefront in in-store/pickup mode, Omaha NE. If you can only reach a delivery price, that row is `unverifiable`, not `wrong-price`.

You have Brad's Chrome available, so a login wall is usually not a real blocker. The one genuine hard stop is a CAPTCHA. Do not guess a price you could not see; `unverifiable` is an honest answer and a fabricated `ok` is the worst possible outcome here.

## Step 3: record and report

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\record-sample-verdict.ps1 -VerdictFile out\verification-worklist-<DATE>.csv
```

Exit 0 = recorded and a rate was quotable. Exit 3 = recorded but too few verified rows to quote a rate. Exit 1 = bad input. It never exits 2.

**Report the 95% Wilson interval, never the point estimate.** "3 defects in 30 = 10%" is the sentence that makes this exercise worse than useless, because 3-in-30 is also consistent with 2% and with 27%. The script reports three different numbers and labels them: the crown rate, the non-crown rate, and the population-weighted whole-board rate. **The whole-board rate is the one to quote**, because the draw deliberately over-samples crowns (a wrong product is about 4x more likely to hold a crown). Quoting the raw sample fraction would be a number that estimates nothing at all.

## Step 4: act on what you found, then commit

For every `wrong-product` verdict, file it so it can never silently return:
```
powershell -NoProfile -ExecutionPolicy Bypass -File .\add-known-wrong.ps1 -Commodity <id> -Store <store> -RuledBy "weekly accuracy sample <DATE>" -Evidence "<what you saw>"
```

Then commit and push. The standing rule in this repo is that a commit which is not pushed is not done, so push immediately rather than batching:
```
cd C:\Codex\ThriftyCrew
git add -A
git commit -m "weekly accuracy sample <DATE>: <n> verified, whole-board rate <lo>% to <hi>%"
git push
```

## Report back to Brad

Keep it short and lead with the interval:
- how many of the 100 were verified, and how many were unverifiable and why
- the whole-board defect rate AS AN INTERVAL, plus the crown rate separately
- whether that interval overlaps last week's (if it does, you cannot claim the board improved, and you should say so plainly)
- every wrong-product found, named, with the store

Do not write "accuracy is X%". Any accuracy claim the pipeline makes about itself is worth nothing; the only number worth publishing is the one that came back from the store, with its width attached.

Never use em dashes in anything Brad reads.