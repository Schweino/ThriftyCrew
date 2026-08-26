# Repair proposal: the 5 stranded parks in `hunt-2026-08-26-ten`

**Status: PROPOSED. Nothing in this file has been applied.** Brad's ruling 2026-08-26 was
"propose only, apply later". The code fix (Q1) is separate and is already committed; this
document is only about the five recipes already stranded in the live run.

## Preconditions, re-checked before anything runs

| check | measured 2026-08-26 | how to re-check |
|---|---|---|
| daemon writing the run dir | **exited** - `daemon.log` ends `HUNT-DAEMON-COMPLETE` at 10:17:59Z, PID 22380 gone | `tasklist /FI "PID eq <pid>"`, and tail `daemon.log` |
| wave cert in flight | **none** - `waves\` is empty, no manifest to void | `dir waves\wave-*.json` |
| another session writing | assumed none - **confirm before running** | ask; a concurrent writer voids any cert |

Re-run all three at the moment of repair, not on the strength of this table.

## What is actually wrong with each recipe

Every one of the eight stranded terms is a row in `mapped\<slug>.json` with **no bid**, which
`Get-CarriageBlockingTerms` turned into a blocking term that nobody ever enqueued. They fall
into three classes, and only one of them needs a pricer.

| recipe | term | class | repair |
|---|---|---|---|
| chicken-fried-steak | Pan Drippings | `optional-note` | none - the Q1 fix stops it blocking |
| grilled-garlic-parmesan-wings-with-cilantro | Water | `optional-note` | none |
| | Vegetable Oil | unmapped, **already on the board** | wire `bid: "vegetable-oil"` |
| slow-cooker-beef-stroganoff | Water | `optional-note` | none |
| | Garlic Salt | unmapped, **not on the board** | enqueue - the only real pricing work |
| sticky-bourbon-chicken | Water (x2) | `optional-note` | none |
| | Rice Vinegar | unmapped, **already on the board** | wire `bid: "rice-vinegar"` |
| quinoa-casserole-with-chicken | Optional Garnishes | `optional-note` | none |
| | Frozen Corn Kernels | unmapped, **already on the board** | wire `bid: "frozen-corn"` |
| | Garlic Powder, Cumin, and Chili Powder | composite, **all three on the board** | replace with three rows: `garlic-powder`, `ground-cumin`, `chili-powder` |

### This is a mapping repair, not a pricing job - and that matters

The brief proposed "enqueueing the genuinely purchasable terms (Vegetable Oil, Garlic Salt,
Rice Vinegar, Frozen Corn Kernels)". Three of those four are **already priced in
`grocery\out\smp-feed.json`** - `vegetable-oil`, `rice-vinegar` and `frozen-corn` all carry
live multi-store prices, as do `garlic-powder`, `chili-powder` and `ground-cumin`. Queueing
them would send a pricer to check seven stores for commodities the board already answers, and
`Get-Carriage` only consults the feed **by bid**, so a term with no bid can never be found
there however well priced it is.

So the repair is to wire the bid the board already has. Only `Garlic Salt` is genuinely
unpriced and genuinely needs the queue.

Note also that `Vegetable Oil` was mapped **both ways in the same run**: `bid: "vegetable-oil"`
on chicken-fried-steak and `bid: null` on the wings. That is a mapper inconsistency, not a
board gap, and it is worth a look independently of this repair.

### Every other blocking term on these five is already answered

`cube steak`, `seasoned salt`, `parmesan cheese`, `bourbon`, `beef stew meat`,
`wide egg noodles`, `rotisserie chicken` and `roasted corn kernels` are all `status=resolved`
`verdict=CARRIED` in the queue right now. So **four of the five recipes need no pricing work at
all** - they derive straight to `priced` the moment the phantom terms stop blocking. Only
slow-cooker-beef-stroganoff waits, on `Garlic Salt` alone.

## The sequence

Run from `C:\Codex\ThriftyCrew`, with the Q1 fix in place (it is what makes steps 3-4 correct).

1. **Back up.** Copy `meal-prep\runs\hunt-2026-08-26-ten\state\*.json` and `mapped\*.json` for
   the five slugs to a dated folder. Nothing below is reversible without it.

2. **Wire the six bids** in `mapped\<slug>.json`, and replace the one composite row with three:

   | slug | item | set |
   |---|---|---|
   | grilled-garlic-parmesan-wings-with-cilantro | Vegetable Oil | `bid: "vegetable-oil"`, `decision: "mapped"` |
   | sticky-bourbon-chicken | Rice Vinegar | `bid: "rice-vinegar"`, `decision: "mapped"` |
   | quinoa-casserole-with-chicken | Frozen Corn Kernels | `bid: "frozen-corn"`, `decision: "mapped"` |
   | quinoa-casserole-with-chicken | Garlic Powder, Cumin, and Chili Powder | delete; insert `Garlic Powder`/`garlic-powder`, `Cumin`/`ground-cumin`, `Chili Powder`/`chili-powder`, splitting its grams three ways |

   These are edits to a **run artifact**, not to the board or the food DB. Nothing here mints a
   commodity id, so the commodity-registrar is not in scope.

3. **Enqueue the one real term:**

   ```
   grocery\ingredient-queue.ps1 -Add -Term "Garlic Salt" -Recipe slow-cooker-beef-stroganoff -Why "slow-cooker-beef-stroganoff needs it"
   ```

4. **Re-advance each of the five** `parked -> pricing` (a legal transition). The repaired
   carriage union re-derives the blocking list from the artifacts: the wired bids come back
   CARRIED from the feed, the `optional-note` rows are recorded optional, and the composite is
   gone. Pass the recipe's already-resolved terms as `-Terms` so nothing is lost if a ledger
   read disagrees with the queue.

5. **Derive:** `meal-prep\pipeline\hunt-run.ps1 -Derive -RunDir <run>`.
   **Expected:** four recipes `parked -> priced`; slow-cooker-beef-stroganoff stays `parked`
   with `parked_on: ["Garlic Salt"]` and nothing else. Any other outcome means stop and re-read.

6. **Price `Garlic Salt`**, then `-Derive` again to move the fifth.

## What this does NOT do, and the open question

Steps 1-6 leave five recipes at `priced`. They still need spec-build, write, source-QA and a
wave to reach the site, and this run's daemon has already exited with its target met. So there
is a decision for Brad that this repair does not make:

- **restart the daemon on this run dir** so the five flow through the remaining lanes and
  publish in a new wave; or
- **leave them at `priced`** and let the next run pick them up on its resume seed; or
- **do nothing** - accept the five as lost work for this run, and keep the repair as proof the
  Q1 fix would have prevented it.

Recommend the first: the expensive stages (source, select, extract, map) are already paid for,
and four of the five need no further pricing.

## Verification after the repair

- No non-optional term on any of the five state files is missing from the queue - the same
  postcondition the Q1 fixture pins, checked against the live artifacts.
- No term row on any of the five contains a comma.
- `parked_on` is empty for the four, and exactly `["Garlic Salt"]` for the fifth.
- The daemon self-test still reports 251 ok, exit 0.
