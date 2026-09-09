# What the gate costs, and whether the slowest fifteen earn it

**Harness:** `ops/run-gates.ps1`, run as `powershell -NoProfile -File ops\run-gates.ps1 -Jobs <N>`.
**Commit it ran at:** `679a1535661ad682dcdadb163c39c4057a1a7508` (main, 2026-09-09).
**Machine:** 32 logical cores, Windows 11, PowerShell 5.1.
**Verdict read:** exit code first. Every run below exited **0** at `RUN-GATES-COMPLETE pass=304 fail=0`.

`measurement.md` asks that the next recorded measurement name its harness and the commit it ran at.
This is that next one.

## The headline

304 gates. **78 seconds of wall clock** at width 16, containing **516 seconds of gate work**, of which
about 57s is process startup - every gate is still its own process.

The fifteen slowest are **245 of those 516 seconds, 47%**. The other 289 gates are the remaining 53%.

## The slowest fifteen, as measured inside the pool

| ms in pool | ms alone | gate | what it resolved |
|---:|---:|---|---|
| 24,532 | - | `meal-prep/pipeline/map-preresolve.ps1` | |
| 24,170 | - | `grocery/pull-browser-stores.py --selftest` | |
| 18,673 | 14,034 | `grocery/audit-guard-contract.ps1` | covered=56 |
| 17,388 | 15,089 | `ops/test-precommit-hook.ps1` | cases=13 |
| 17,248 | 10,897 | `grocery/test-push-data.ps1` | cases=18 |
| 16,863 | 13,772 | `grocery/audit-script-census.ps1` | |
| 15,803 | 13,526 | `ops/audit-write-only-reports.ps1` | scanned 635 files, 41 families |
| 13,194 | - | `meal-prep/pipeline/learn_apply.py --selftest` | |
| 12,325 | 8,847 | `ops/audit-fixture-vocabulary.ps1` | files=654 |
| 12,151 | 9,737 | `ops/audit-source-control-bytes.ps1` | scanned 8,100 tracked files |
| 12,020 | 10,514 | `grocery/fanout-lib.ps1` | cases=17 |
| 11,671 | - | `meal-prep/pipeline/hunt-run.ps1` | |
| 11,079 | - | `meal-prep/pipeline/wave-preaudit.ps1` | |
| 9,006 | **1,069** | `ops/audit-memory-backup.ps1` | files=190 |
| 8,561 | 6,794 | `grocery/ingredient-queue.ps1` | |

**Pool contention inflates a gate by roughly 1.15x to 1.4x**, so part of every figure in the first
column is the pool rather than the gate. `audit-memory-backup` is the outlier at **8.4x** - 9.0s in
the pool against 1.07s alone - and the standalone read was warm-cache, so its true cold cost sits
between the two. It is on this list because of contention, not because it is expensive.

## Three explanations, all three tested, all three dead

Each of these would have given a fix that keeps every assertion. None survived.

1. **Parse cost.** `map-preresolve.ps1` is 3,662 lines, so its self-test might be paying to be read
   before it does anything. Measured with `[Parser]::ParseInput` over all thirteen PowerShell files
   in the list: **22ms at worst**, most of them 0-2ms. Dead.

2. **Redundant tree reads.** Five detectors here each walk the source tree independently - 635, 654
   and 8,100 files - so one shared source-text pass looked like the long-term fix. Measured: a cold
   read of 726 source files costs 2,593ms, but a **second** pass that re-reads all of them AND runs a
   regex over each costs **74ms**, because the OS file cache already holds them. A shared cache would
   save approximately nothing. Dead. The corollary is the useful half: `audit-fixture-vocabulary`
   spends 8.8s where read-plus-one-regex is 74ms, so its cost is **per-file regex work in PowerShell**,
   about 120 times one pass. Same for its neighbours.

3. **More parallelism.** Width 16 -> 24 -> 32 on a 32-core machine:

   | width | wall | gate work inside it |
   |---|---|---|
   | 16 | 78s | 516s |
   | 24 | 76s | 580s |
   | 32 | 75s | 657s |

   **Wall clock is flat while the work inflates 27%.** The pool is already saturated at 16; adding
   workers only makes each gate slower and buys 1-3 seconds. Dead. Note this also means the 516s
   figure is not a constant - it is a function of the width it was measured at, and quoting it
   without the width is meaningless.

   (`ps5-static-regex-lock` already says runspaces make `-match` slower and only separate processes
   parallelise, so the intra-detector lever was closed before this.)

**So 78 seconds is the floor for this gate on this machine.** The only remaining way to make it
faster is to remove assertions.

## Do the fifteen earn their share

Every one of the fifteen carries a founding bug. Counted in source:

- `map-preresolve` 120 must-fire / 56 clean twin; `hunt-run` 86 / 41; `learn_apply` 53 / 21;
  `wave-preaudit` 38 / 7 must-not-fire / 12; `ingredient-queue` 19; `pull-browser-stores` 15;
  `fanout-lib` 10; `test-precommit-hook` 8 / 11; `test-push-data` 8 / 12;
  `audit-fixture-vocabulary` 7 / 11 / 26; `audit-guard-contract` 5 / 5 / 2 plus a ratchet;
  `audit-source-control-bytes` 5 / 5 / 5; `audit-write-only-reports` 3 / 4 / 2 plus a ratchet;
  `audit-memory-backup` 1 / 10; `audit-script-census` is a pure ratchet with a baseline.

**Not one of them is a speculative check.** There is no free retirement on this list.

The three integration self-tests are the clearest case *for* the cost: `test-precommit-hook` spends
15.1s over 13 cases, about 1.2s each, because each case drives a real `git commit` through the real
hook in a child process. `test-push-data` is 605ms per case over 18 and `fanout-lib` 618ms over 17,
for the same reason. That subprocess cost **is the assertion** - a hook and a push lane exist only as
subprocess behaviour, and a version of those tests that did not spawn would not be testing the thing.

## What this does not claim

This measures cost and it counts fixtures. **It does not measure what each gate has caught in
production**, which would need the incident history per detector and is not in this document. A
founding bug proves a gate caught something real once, by construction; it does not prove the gate
is still the only thing standing between the estate and that bug.

It also measured one machine on one day at one commit, and the CI runner is a different machine
where the boards are absent.

## Recommendation

**Retire nothing, and stop trying to make the gate faster.** Three structural fixes were tested and
all three are dead, so the remaining levers all cost assertions, and this estate's rule is that a
gate is never weakened to buy something else.

78 seconds is the honest price of 304 gates. The cost that was actually felt on 2026-09-09 was not
the 78 seconds - it was **running the full gate eight times in one day**, ten minutes of waiting, when
most of those runs were re-checking a tree whose changed file did not touch 300 of the 304 gates.
If anything here is worth building later, it is running the gates a change can actually affect
during iteration and the full 304 once before the push - and that is a change to how the gate is
*invoked*, not to what it asserts.
