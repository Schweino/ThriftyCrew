# Declared deviation from PLAN-recipe-hunter-v2 section 2.4 - hunt-2026-08-27-ten

Recorded 2026-08-27T04:40 local, BEFORE the daemon was started, per the skill's rule that a
deliberate deviation is recorded in the run dir up front rather than explained in the report.

## The deviation

The HUNT and SELECT lanes are not run. All twelve recipes enter at `extracted`, carrying forward
the transcriptions `hunt-2026-08-26-ten` already paid for. Every lane from MAP onward runs normally.

## Why

`hunt-2026-08-26-ten` ended 0 published with twelve recipes STUCK in the write lane, all on
`build-intake-skeleton: no food-macros-db row for '<food>'` (17 distinct names across 11 recipes).
That stall is dated, not mysterious: those twelve were mapped by the morning of 2026-08-26, and
three fixes landed AFTER their map ran -

  b1fe62b4 06:18  the write lane refused twelve correct recipes: alcohol, composites, bases
  9d7e9769 11:15  silence about a missing food row is now refused at the map dispatch
  4721309f 20:09  rung 3: one basis in the finding, and a ledger that outlives the run

The composite splitter added in b1fe62b4 is why `Salt and Pepper` reached the macro table as one
purchasable item in two of them; `Get-CompositeSplits` now splits it to Salt + Pepper. The map
dispatch gate added in 9d7e9769 is why silence about `Chicken Thighs` or `Mexican Crema` can no
longer pass. Re-mapping under current code is the test of exactly those fixes.

Sourcing and select were 75.5% of a measured run's tokens. Re-buying them to re-prove lanes that
were never in question is the expensive way to learn nothing. Brad chose this scope explicitly.

## What is NOT deviated

MAP, PRICE (singleton, term-keyed queue), WRITE, QA, WAVE, audit, publish, post-publish review all
run as specified. Wave size 10, band 450-700 cal / <=40 carb / >=40 protein, publish LIVE.

---

## Intervention 2026-08-27 ~05:10: one rejection VOIDED and re-entered

`enchiladas-suizas` was retired `rejected-macros` at 09:2xZ by the first map dispatch of this run,
with `reject_reason` exactly "mapper rejected" and no rulings file. It is being re-entered at
`extracted` and re-mapped. This is not the mapper being overruled - the mapper was asked the wrong
question and its answer cannot be read:

1. THE QUESTION WAS WRONG. That dispatch carried `DEFAULT_COND` into its prompt - "between 400 and
   650 calories per serving AND 35 g carbohydrate or less" - because `--conditions` defaulted to a
   hardcoded string while the BAND beside it was read from run.json. This run is 450-700 cal and
   <= 40 g carbs. A macro rejection decided against a 35 g ceiling, in a run whose ceiling is 40, is
   a verdict on a question nobody asked. The decider had already verified this dish at 519/29/41,
   which passes this run's real band on all three edges.
2. THE ANSWER CANNOT BE READ. The rejection cites nothing - not which macro, not the computed
   figure, not the number it was compared against. Nothing in the run dir can tell you whether it
   was right. Both defects are now fixed and fixtured (hunt_daemon_selftest.py sections H:
   `_a_rejection_needs_a_basis`, `_conditions_come_from_the_run_dir`), so a rejection with no basis
   is STUCK and re-askable rather than terminal, and the run dir's own conditions reach every prompt.

The re-entry is recorded here rather than in the report because it changes what the run may publish.
If the re-map rejects it again ON A STATED BASIS against the correct band, that rejection stands and
no further intervention will be made.
