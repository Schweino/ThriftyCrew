# MEASURE: triage token spend, baseline and bars (2026-09-24)

Harness: `grocery/triage-cost.py`, blob `522531f8dd82b1d93c42c0c151af4f6f2aa6704b` (`git hash-object`, taken before the
commit; a rebase cannot move a blob). It reads Claude Code session transcripts under `~/.claude/projects/*/`, which is an
internal format; a transcript with calls and no usage block reads BLIND, never zero. Plan:
`design/PLAN-triage-token-efficiency-2026-09-24.md`.

## The unit

`cost_units` = input + 1.25 x cache write + 0.1 x cache read + 5 x output, summed over every API call of the
orchestrator and every spawn. Relative Opus list-price weights with the 5-minute cache-write rate; a 1-hour write costs
more, so this understates a run that uses it. It compares runs with each other; it is not an invoice. The ledger's old
`tokens` column is the final context size of each spawn (exact on 4 of 4 spawns of 09-19) and is not comparable.

## Baseline (one row per session; plans and done counts read from the plan files)

| session | run | cost_units | plans | items done / items |
|---|---|---|---|---|
| 74c896e6 | 09-06 | 18.2M | not counted | not counted |
| 0d5b6bf1 | 09-18 | 44.9M | plan-2026-09-18, -2, -3, -4 | 9 / 19 |
| 5f9934ec | 09-19 | 26.2M | plan-2026-09-19 | 3 / 8 |
| ffbacbef | 09-20 to 09-23 (carried over 3 days) | 402.3M | 09-20 x6, 09-21 x8, 09-22 x11 | not counted |

Cost per done item where both halves are counted: 09-18 about 5.0M (44.9M / 9), 09-19 about 8.7M (26.2M / 3). Two runs;
a baseline, not a distribution. Plan outcomes 09-10 to 09-22: 95 of 201 items `done` (47%).

## Bars, written before the next run (2026-09-25), judged over the next 5 scheduled runs

1. **Spend per run**: median cost_units per scheduled run at or below **20M**, and no run above the **30M** budget
   unless its report says the budget stopped a spawn.
2. **Cost per done item**: median at or below **4M** over the runs that close at least one item.
3. **Finish rate**: at least **65%** of the planned (non-deferred) items end `done`, counted over all 5 runs' plans.
4. **Coverage**: every plan dated 2026-09-25 or later is named by a schema-2 ledger row (the `-Closing` gate enforces
   it; the check here is that no plan escaped by skipping the gate), and none carries a round above 2 without
   `round_override`.

Each bar is a first plausible number from the baseline above, not the survivor of a sweep. A run that meets bar 1 by
deferring everything fails bar 3; the two are read together. If the next 5 runs miss bar 1 or 2, the next lever measured
first is the developer's context size per call (median about 312k tokens over 30 spawns), because cost grows with calls
times context.
