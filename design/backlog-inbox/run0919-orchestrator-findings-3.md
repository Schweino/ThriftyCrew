# Backlog run 2026-09-18, third batch: findings from the second pass over the new items

Collected by the orchestrator from the item agents' reports while working I215 to I238. Nothing here was
verified a second time by the orchestrator unless it says so.

## Reader-facing: Walmart artichokes is a canned 12-pack divided by 8, and Hy-Vee harissa is a dry spice blend
`OPEN` `run-0919` `1-WAY` `RUNG1 RULING`

Found under I222 and I220. On `comparison-2026-09-17`, artichokes | Walmart is a 12-pack of canned artichoke
hearts sized "6-8 CT-14 OZ" and divided by 8, shown at $8.9988 (too high). Hy-Vee "Morton & Bassett Harissa,
1.9 oz", a dry spice blend, matches `harissa-paste`; it is hidden today only because Walmart's batch row is
cheaper, and I220's part 2 would put it on show. Both are catalogue or known-wrong corrections.

## The daily recipe republish died at the costing step on 11 of 58 runs
`OPEN` `run-0919` `2-WAY` `RUNG1 MEASURE`

Found under I234. Of 58 daily republish outcomes from 2026-08-08 to 2026-09-18, 11 ended in a compute-v2
failure, so recipe costs did not move those days. Nobody has read why.

## Walmart store proof has three more gaps
`OPEN` `run-0919` `2-WAY` `RUNG1 READ`

Found under I220. `grocery/walmart-capture-reducer.js` writes no `#tc-store` line, so after I220's part 1 the
batch import lane refuses every capture until it learns one. `walmart-regular-2026-09-12.json` was built
without a store line and is still priced. The July "staples300" rows claim only "Omaha", not a store id.

## Fareway's was-price is sometimes a per-pound price set against a per-pack sale
`OPEN` `run-0919` `2-WAY` `RUNG1 READ`

Found under I223. In 3 of the 41 rows that gained a sale end, the was-price is lower than the sale price
(Banana 0.49 vs 0.23, Chicken Drumsticks 1.39 vs 0.75, Chuck Roast 7.88 vs 26.97). None changes a board cell
today.

## Silent logs and a one-sided audit
`OPEN` `run-0919` `2-WAY` `RUNG1 BUILD`

- `grocery/check-ad-cycles.ps1:2498` logs only the last output line of `send-price-alerts`, so per-item
  failures are lost (I224).
- `ops/audit-write-only-reports.ps1:105` counts a read only through a fixed list of read commands, so a read
  through a helper reads as write-only (I224).
- `grocery/audit-coverage-gaps.ps1:319` still accepts single-search not-carried entries, so the 24 entries
  I221 found untrustworthy keep that audit quiet about those gaps until 2026-11-19 (I221).
- The 2026-09-17 graph nightly recorded `gold-score BLIND rc=1` (`graph\eval\score.py` exited 1), not read.
- `grocery/out/logs/ml-eval-last.txt` and `rejection-families-last.txt` are tracked but not in the graph lane's
  commit list in `lib/pipeline-commit.ps1`, so only the 07:00 bot commits them.

## Graph quality: wrong resolver picks, an each-branch pack gap, rows with no term, and file growth
`OPEN` `run-0919` `2-WAY` `RUNG1 MEASURE`

Found under I222 and I235. The graph's automatic resolver picked wrong products for newly added shadow cells
(dried-ancho-chiles = a Street Corn Kit, sponges = dishwand heads, pineapple = fresh-cut cubes, Walmart
eggplant = a roasted eggplant jar). `graph/lib/units.py` `per_unit`'s each branch prices a whole pack as one
when the size is only a volume and no count is written (Aldi Puraqua 16.9 FL OZ at 3.19). 361,906 capture rows
(118,557 Baker's) have no `found_by_term` and are dropped nightly; 12,720 more stay unresolved. One import grew
a copy of graph.db from 323.8 MB to 446.5 MB, which is I211's churn made larger by I235. No reader sees graph
prices.

## The paused harvest task will page daily after its window closes
`NEEDS A RULING` `run-0919` `2-WAY` `RUNG1 RULING`

Found by the graph-nightly fix. `TC Recipe Harvest Crawl` is paused by Brad's ruling until a five-evening retry,
2026-09-20 to 09-25. From about 09-26 the heartbeat's 30-hour limit will page TASK STALE every morning. Options:
(1) retire the task when the window closes, dropping its heartbeat row and committed definition in the same
change; (2) teach the heartbeat to read a task's start and end dates; (3) leave it and let the page be the
reminder. Recommendation: 1.

## No chain ran on 2026-09-15 or 09-16
`OPEN` `run-0919` `2-WAY` `RUNG1 READ`

Found by several agents. There is no capture-run-daily log and no Daily pipeline commit for either day; the box
slept from 2026-09-16 08:02 to 09-17 05:06 (System log event 42). Whether the heartbeat paged for the two lost
days, and whether a sleep that long should be prevented, is unread.
