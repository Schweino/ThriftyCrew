## a scented household product can hold a fruit cell: dish soap priced as strawberries, and the class fix waits on branch claude/board-wrong-cells-0919

`NEEDS A RULING` `run-0919` `2-WAY` `RUNG1 RULING`

**What was wrong.** "Dawn Ultra Strawberry Field Scent" (dish soap, $6.49 for 38 oz, Family Fare weekly ad 09-13 to 09-19) held Family Fare's STRAWBERRIES cell at $0.1708/oz on every board from comparison-2026-09-13 on. No rule changed: the product arrived in the ad, strawberries' include `strawberr` claims it, strawberries sits before dish-soap in commodities.json, and first-match-wins did the rest. It never held the crown (Aldi, $0.1431/oz). It is NOT on the page a reader sees today, only because guards has held every board since 09-13 and `public/board.json` on origin/main is still the 2026-09-12 09:46 commit (Family Fare strawberries there: $0.3119/oz).

**The same shape was already in the corpus, unpublished.** Over 50,954 distinct capture names, 8 route out of a food commodity once scent is treated as non-food: the Dawn soap, five hand sanitizers (apples, pears, cherries, raspberries, watermelon), a shave gel (raspberries) and a tanning oil (coconut-oil). The per-cell known-wrong entry a triage session staged in the main checkout on 2026-09-18 (`strawberries|FamilyFare|dawn-ultra-strawberry-field-scent`) corrects the one cell and none of the other seven.

**The prepared fix (branch `claude/board-wrong-cells-0919`, NOT landed).** A global exclude `\bscent(?:s|ed)?\b` in `grocery/global-exclude-lib.ps1`, declared in `relax_global` by all 59 non-food commodities (categories.json Household, Personal Care, Baby, Pet), the applesauce and baby-food shape one aisle over. `grocery/out/audit/match-baseline.json` re-points the two blessed names it moves (4bb2295e9 had accepted Dawn -> strawberries into the baseline that morning). Fixtures: compare-deals -SelfTest R20, 4 MUST FIRE and 3 CLEAN TWIN.

**Verified.** Engine run over one input set (the main checkout's 2026-09-17 inputs): origin/main code reproduced the live board exactly (0 of 3,189 cells differ), and the branch changes 1 of 3,189 cells and 0 of 572 crowns (strawberries @ Family Fare 0.1708 Dawn -> 0.3119 Fresh Strawberries). Routing diff over the corpus: exactly the 8 names above, nothing else. compare-deals -SelfTest, match-lib -SelfTest, test-match-lib, test-commodity-rules all exit 0; reverting either half turns R20 red (4 and 6 cases), restored md5-identical. audit-match-soundness: MOVED=0 DROPPED=0 after the baseline edit.

**The ruling.** It changes one live board cell, so it waits for Brad. Options: (a) land the branch as is (recommended: the class fix, and the known-wrong entry then becomes redundant but harmless); (b) keep only the triage known-wrong entry and close this; (c) land it but scope the token to produce commodities instead of global.

## band-censorship's ratchet flaps with an unrelated store's sale price

`OPEN` `run-0919` `2-WAY` `RUNG1 MEASURE`

guards held the 2026-09-18 08:13 board on a fourth hard fail: band-censorship 32 cells against a baseline of 29. The 3 new cells were frozen-pizza at Aldi, Sam's Club and Walmart, refusing the SAME rows (Totino's party pizzas at $1.4925, a Red Baron 5.4 oz personal pizza at $1.4422, a Mama Cozzi 2-count at $1.495) that were refused on the 09-14 board too. What moved was the median: Fareway's Jack's pizza went on sale 4.49 -> 3.33, the frozen-pizza median fell from 3.99 to 3.33, and 1.4925 crossed the 0.4 median floor (0.374 -> 0.448). Nothing about censorship changed. On the main checkout's 11:00 rebuild the same rows carry band `min_piece_oz>=12` and the audit reads 29 of 29 again. A ratchet that counts cells whose classification depends on OTHER stores' prices can break and heal on nobody's change. Worth measuring how often across the flagged history before deciding anything.

## audit-household-in-food could not have caught the Dawn soap

`OPEN` `run-0919` `2-WAY` `RUNG1 BUILD`

guard 2 exists for exactly this class (its own header names household products sold by fruit SCENT), and it was silent for six boards for two reasons: its `$HOUSEHOLD_SIGNAL` has no `scent` token and no `dawn`, and it sweeps only `out\regular\*-regular-*.json`, never the weekly ad files, where this row came from (grocery/audit-household-in-food.ps1:51 and :54). The script has no -SelfTest, so adding either needs a suite first.
