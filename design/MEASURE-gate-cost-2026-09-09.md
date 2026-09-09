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

**So 78 seconds looked like the floor for this gate on this machine, and the only remaining way to
make it faster looked like removing assertions. THAT CONCLUSION IS WRONG - see the CORRECTION below.**
All three explanations above are dead as measured; the fourth was the scheduler, which I had not read.

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

## CORRECTION, same day: the fourth explanation was the right one

Everything above stands as measured. **The recommendation that followed it was wrong**, and it was
wrong because I tested three fixes to the gates and never looked at the SCHEDULER that runs them.

Two structural facts, read in `ops/run-gates.ps1` rather than inferred:

1. **There are four sequential pools, not one.** `Invoke-TcParallel` is called at lines 124, 314, 410
   and 438 - PowerShell self-tests, PowerShell static detectors, Python static, Python suites. Each
   returns an array indexed by job, so each pool must **fully drain before the next begins**. Three
   hard barriers. At the end of every batch, the workers that finished sit idle waiting on that
   batch's longest straggler.

2. **Dispatch order is alphabetical** - `Sort-Object FullName`, line 53 - not longest-first. The
   single most expensive gate in the estate, `meal-prep/pipeline/map-preresolve.ps1` at 24.5s, sorts
   under "m" and is therefore dispatched near the END of its batch, which is the worst possible
   position for the longest job.

**The number that gives it away was already in this document, undivided:** 516s of work inside 78s of
wall is **6.6x effective parallelism against 16 dispatched workers, about 41% efficiency**. Perfect
packing of 516s at width 16 is 32s.

That also re-reads the width curve above. I recorded "the pool saturates at 16" and treated it as
physics. **Widening a barrier does not remove it** - each batch's tail is set by its longest single
gate no matter how many workers are idle behind it, so a flat curve is exactly what four barriers
produce. The machine was not full. It was waiting.

**The corrected finding: the architecture issue is not the 304 gates and not the slowest fifteen.
It is that the gate is scheduled as four alphabetical batches instead of one longest-first pool.**

The fix is contained and costs no assertion: build all four job lists, make ONE `Invoke-TcParallel`
call ordered longest-processing-time-first, then slice the result array by index range so each
judging loop stays byte-identical. Every gate still runs, still in its own process, still judged the
same way. `lib/parallel-run.ps1` already carries fixtures asserting that concurrency 1 and the pool
agree, which is the net under the change.

**Two things this correction does NOT claim.**

- **The size of the win is an estimate, not a measurement.** The floor is bounded below by the 24.5s
  longest gate, and the contention measured above is real, so the honest expectation is somewhere
  near 45-55s rather than the arithmetic 32s. That is a prediction. It gets measured before it gets
  quoted, per this estate's own rule that a number that moved is not a number that improved.
- **Cross-batch independence is unverified.** `run-gates.ps1` asserts the gates are independent by
  construction, but that comment sits over the self-test batch. Merging the pools assumes the four
  batches do not depend on each other's completion, and **verifying that is part of the work, not a
  footnote to it.** A Python suite that reads something a PowerShell gate writes would be invisible
  today, because the barrier is currently hiding it.

## Recommendation, corrected

**Retire nothing** - that half stands, and every one of the fifteen carries a founding bug.

**Do not conclude that 78 seconds is the floor.** It is the price of the current schedule, not of the
assertions. One pool, longest-first, is the durable fix: it is a change to how the gates are
DISPATCHED, touching neither what they assert nor which of them run, which is the property that makes
it safe in a way that selecting a subset by changed file would not be. Selecting a subset would
reproduce exactly the shape `ops-and-gates.md` warns about, where "no gate matched your change" and
"the gates found nothing" are the same bytes.

The eight-runs-in-a-day cost noted above is real but is downstream of this: at 45s the same eight
runs cost six minutes instead of ten, and the case for a change-scoped fast lane weakens accordingly.

## RESULT: one pool, measured

**Harness after the change:** same `ops/run-gates.ps1`, one `Invoke-TcParallel` call.
**Commit the change was measured at:** the `gate-single-pool` branch, merged as recorded below.

**The bar was registered before the run**, in the correction above: "45-55s rather than the arithmetic
32s". That was written before the change was applied, so it is a prediction and not a description of
a result already seen.

| | four pools | one pool | serial (`-Jobs 1`) |
|---|---:|---:|---:|
| wall clock | 78s | **51s** | 372s |
| gate work inside it | 516s | 580s | 370s |
| effective parallelism | 6.6x | **11.4x** | 1.0x |
| verdict | 304 pass, 0 fail | 304 pass, 0 fail | 304 pass, 0 fail |

**51s, and it landed inside the pre-registered band.** Three consecutive runs at width 16 measured
51s, 51s, 51s, so the figure is not a single sample. The saving is 27 seconds a run, 35%.

**Verdicts were diffed BY NAME, not by count** - a suite that silently runs a subset still prints a
large number. All three configurations produced 304 verdict lines and the sorted name-plus-verdict
sets are **identical**: four-pool against one-pool, and four-pool against serial. No gate changed its
answer, and none went missing.

**The `-Jobs 1` contract still holds.** The file promises that width 1 restores the old behaviour
exactly; it runs 304 gates serially in 372s and passes.

**A number worth keeping from the serial run:** uncontended, the gates are 370s of work. At width 16
that same work measures 580s, so **contention inflates gate work by about 55%**, and every "gate work"
figure in this document is a function of the width it was measured at. The 78s and 51s wall clocks are
the comparable numbers; the work totals are not.

**What was NOT done, deliberately.** Longest-processing-time-first ordering was designed and then not
built. One pool alone recovers the barriers, and at 51s against an arithmetic floor of 370/16 = 23s
the remaining gap is contention rather than tail, which reordering does not touch. Building the
refinement before measuring whether it was needed would have been the same mistake as the three dead
explanations above, one layer up. It stays available if the gate count grows enough to make the tail
matter again.
