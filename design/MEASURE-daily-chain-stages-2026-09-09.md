# Where the daily chain's 27 minutes actually go

**Harness:** `grocery/check-ad-cycles.ps1`, read from its own `grocery/ad-cycle-log.txt`.
**Run measured:** the real 2026-09-09 08:09-08:34 local run. **Not a run I started** - the pipeline
executes captures, rebuilds boards and ships, so it is read from its log rather than re-run.
**Recorded at commit** `86f1c7114`.
**Verdict line:** `run complete; flips=1; ship=645s; total=1630s`.

## The map

Span in the log 1,522s. Each gap is attributed to the stage whose line preceded it.

| seconds | share | stage |
|---:|---:|---|
| **421** | **27.7%** | **`test-auditors`** |
| 190 | 12.5% | `surface-staleness` |
| 181 | 11.9% | *(unlabelled lines)* |
| 159 | 10.4% | `share` |
| 139 | 9.1% | `multipack-repair` |
| 117 | 7.7% | `free-rotation` |
| 98 | 6.4% | `sale-fallback` |
| 63 | 4.1% | `row-age` |
| 51 | 3.4% | `guards` |
| 29 | 1.9% | `derive-links-from-prices` |

**A LABEL CORRECTION, because the raw attribution is off by one and would mislead.** The 421s appears
against `prune-intermediates`, which is simply the stage that logged last before the gap. The next
line is `test-auditors: 421 s (rc=0)` and 08:27:45 to 08:34:46 is exactly 421 seconds, so the gap IS
test-auditors and it self-reports the same number. Attributing a gap to the preceding label is only
ever a first approximation; here the suite's own figure settles it.

## What this confirms, and it is worth saying because it could have gone the other way

**`test-auditors` is the largest single stage in the daily chain at 27.7%.** That is an INDEPENDENT
confirmation of `design/PLAN-test-auditors-concurrency-2026-09-09.md`, which was written from a
standalone profile before this log was read. The plan was targeting the right thing.

It also bounds the win honestly. That plan's floor is roughly 157s against 421s here, so a full build
would take the daily chain from about 1,522s to about 1,258s - **a 17% cut to the chain, not a 60%
one.** The 60% figure is the suite's own runtime, which is what you feel when running it by hand after
a site change. Both are true and they answer different questions. Quote the one that matches the
complaint.

## What is NOT profiled, and should be before anything after test-auditors is touched

`surface-staleness` (190s), `share` (159s) and `multipack-repair` (139s) are 488s together, 32% of the
chain, and **none of them has been looked at from the inside.** The 181s of unlabelled lines is a
fourth unknown of the same size. Nothing here says whether that time is real work, serial child
dispatch like test-auditors, or chosen waiting like the Walmart pull's documented pacing.

## The design finding behind all of it

Three separate efficiency defects were found on 2026-09-09 and every one is the same shape:
**independent work executed one item at a time.**

- `ops/run-gates.ps1` drained four pools in sequence. Fixed: 78s to 51s, verdicts identical by name.
- `grocery/test-auditors.ps1` spawns 271 children through 148 synchronous call sites. Planned.
- `grocery/guards.ps1` was checked and is ALREADY correct - launch early, harvest late.

**And the estate now carries FOUR different mechanisms for "run these together":**
`lib/parallel-run.ps1`'s `Invoke-TcParallel` (used only by run-gates), `grocery/fanout-lib.ps1`'s
`Invoke-Fanout` (used by check-ad-cycles), `guards.ps1`'s own `Register-Kid`/`Wait-Kid`, and
`test-auditors.ps1`'s own `RunPSMany`. Each was written because the one before it was not reachable or
not shaped right from where the author stood.

This is the shape of `[[price-formatter-had-five-copies]]`, one layer up: **a capability implemented
four times will be implemented a fifth time by the next person who needs it**, and none of the four
gets the hardening the others learned. `fanout-lib` alone carries a corrected confounded measurement
in its header that the other three know nothing about.

**No consolidation is proposed here.** The four have genuinely different semantics - bounded processes
with timeouts, runspaces, lazy harvest, index-sliced results - and merging them casually would be the
worst possible way to touch the machinery that gates everything. It is recorded so that the fifth one
gets written deliberately, or not at all.

## What this does not claim

One run, one machine, one day, read from a log rather than instrumented. Stage boundaries come from
log lines, so a stage that logs nothing while working is invisible and its time lands on its
predecessor - which is exactly the correction noted above, caught only because the suite printed its
own figure. Treat every row but `test-auditors` as approximate.
