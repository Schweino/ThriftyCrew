# A 90-minute sampled window of the gate queue, 2026-09-11

A second, independent measurement of the starvation that `design/MEASURE-gate-slot-starvation-2026-09-11.md`
diagnoses. That document answers **why** the pool starved and what was changed for it (arrival-order tickets, a
reused green verdict, and refusing a push that can no longer land). This one answers **how much**, from a window
sampled while that work was being built, and it ships the per-run rows so the totals can be re-derived.

**Harness:** `ops/observe-gate-queue.ps1` - `-Watch` sampled the window, `-Report` derived every total below, and
`-Retro` read the day's own kept records. It holds no gate slot, opens no slot mutex and starts no gate.
**Commit it ran at:** the commit that adds this file, 2026-09-11. What it measured: `lib/gate-slots.ps1` at
`d72b4f5cd` and `ops/run-gates.ps1` at `8b21be2fa` - that is, the estate BEFORE b1aab0424 changed either.
**Re-read at commit `46a78c564`:** the commit adding the harness; every total here was produced by running that
copy of it over the sampled rows.

## What was sampled

Every 15 s from **16:48:33 to 18:18:23** (360 ticks). The totals count runs that STARTED in the first 60 minutes,
so each had the remaining half hour to finish.

**70 run-gates started in that hour: 41 from a pre-push hook, 29 by hand from a session.**

| outcome | count | of 70 |
|---|---|---|
| evaluated (gate workers ran) | 38 | 54% |
| exited 3 on the slot wait | 13 | 19% |
| ended within seconds, no workers (killed, or refused before the queue) | 19 | 27% |

**The classifier was checked, not trusted.** A run counts as evaluated when it had gate worker children, because a
run waiting for a slot spawns nothing. For hook runs the hook's own log is ground truth - it deletes the log on a
pass and keeps it on a refusal - and the two **agree 64 of 64** readable verdicts (18 hook runs left none).

## The numbers that decide what a fix can do

- **Capacity, measured: 62 evaluated runs ENDED inside the 90 minutes, 41.4 an hour.** The slot-second arithmetic
  predicts 36 to 40 from the same day's per-run cost, so the two agree.
- **Unique work: 55 of the 70 starts were distinct (checkout, content) pairs - 55 an hour.** Demand exceeded the
  ceiling on unique content alone, which is why removing duplicates could never have been the whole answer.
- **Duplicates, keyed as the reuse keys them: 2 of 41 hook runs** followed a hand run in the same checkout on the
  same content (one had finished 41 s earlier; the other was still running), plus **2 of 41** that followed an
  earlier hook run on the same content - a re-push.
- **Clean trees:** a hook run's tree was clean in **69 of 92 (75%)**, a hand run's in only **14 of 46 (30%)**. Any
  reuse that demanded a clean tree when RECORDING would have recorded nothing for 32 of those 46 hand runs, which is
  why keying on working-tree CONTENT rather than on HEAD is what makes gate-then-commit-then-push pay once.
- Live runs averaged **19.1 a tick and peaked at 39**; those actually holding workers averaged **7.2, peak 9**,
  which is the budget of 10 doing its job.

**One row per run, and every total above derives from it:** `design/DATA-gate-slot-starvation-2026-09-11.csv`,
138 rows carrying origin, checkout, both content keys, the outcome and the hook's own verdict where there was one.
A pair of totals cannot be un-aggregated later; that file can.

## What this says about the fix that shipped

The reuse in `lib/gate-verdict.ps1` removes a real class outright, and the arrival-order queue stops a waiter
losing races indefinitely. Neither creates slot-seconds: with unique demand at 55 an hour against a 41.4 ceiling,
**the remaining gap is capacity, not order and not duplication.** The levers left, in the order they should be
considered, are fewer runs (hand runs were 29 of 70 starts), cheaper runs (about 870 s of gate work each, and the
discovered set grew from 245 self-tests at 09:50 to 267 by 18:00), and the slot total itself - which is Brad's
ruling, recorded in `docs/CONTROL-CONSTANTS.md` and untouched here.

The queue drained on its own by 18:00 as the afternoon's sessions finished: per-run cost fell to 825 s in the 17h
hour and 698 s at 18h, and live runs fell from 39 to 12. This was transient overload against a fixed ceiling, and
it will recur the next time several sessions push at once - which is what the harness is kept for.
