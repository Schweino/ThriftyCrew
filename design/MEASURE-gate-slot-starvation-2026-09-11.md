# MEASURE: why the machine-wide gate worker pool starved (2026-09-11)

**Harness and commit.** Measured through scratch probes that are not committed, whose bodies are described with each
number below, plus `Win32_Process` snapshots, the pre-push logs the hook keeps under `%TEMP%`, the per-checkout
`gate-readings.jsonl` rows, and session scratch files. Run 2026-09-11 between 16:35 and 17:05 local against the tree
at commit c6533c7ea.

**The fairness probe of item 5 is now committed as `ops\probe-gate-slot-fairness.ps1`**, because a described probe
costs a re-write to repeat and this one had to be re-written the next day to answer whether the fix held. The
re-measurement at 20 arrivals is the last section of this file.

**The raw rows behind items 1 and 6 are committed as `design\DATA-gate-slot-starvation-2026-09-11.csv`** - 138 rows,
one per `run-gates` process, carrying its origin, start and end, outcome, worker count and the verdict line its hook
log ended on. This file did not name it, so the numbers here could not be traced to their own data; that is the E24
discipline kept and then not pointed at. The remaining numbers - the occupancy snapshot's zero-wait probe and the
service-order probe of item 5 - came from scratch probes described with each and were not kept.

## The question

A push is gated by `run-gates` through a machine-wide budget of 10 gate worker slots. That afternoon, two consecutive
pushes from one session were blocked with exit 3 after waiting the full 1,200 s each: *"every one of the 10
machine-wide gate worker slots stayed held by other gate runs. Nothing was run"*. Exit 3 is correctly never a pass,
but when every push times out, no push can be gated at all, which is the red that teaches `--no-verify`. Why did the
pool starve?

## What was measured

**1. Occupancy, 16:39:59.** A zero-wait probe of `Global\tc-gate-worker-slot-0..9` found **10 of 10 held**.
`Win32_Process` showed **27 `run-gates` processes** started with `-File` (32 counting the `-Command` wrappers above
them). Of the 27, **8 had gate children** (1 or 2 each, so they were running at width 1 or 2) and **19 had none at
all**. All 27 were in different checkouts: 21 were pre-push hooks under a `git push`, 6 were a session's own run with
no push above it, and 1 had lost the shell that started it while its `git push` lived on. Orphaned gate children: 0.

**2. What a run costs while the box is contended.** From the kept hook logs after 15:00, every run that got a slot got
**one**: waits of 425, 460, 597, 867 and 1,010 s, then walls of 1,046 to 1,864 s. One log records it exactly: width 1,
31 s of waiting, **1,122 s of wall holding 1,085 s of gate work**, slowest single gates `learn_apply.py` 81 s and
`pull-browser-stores.py` 74 s. The same set took 48 to 101 s at width 16 on the quieter morning. So under contention a
run holds its one slot for about 20 minutes, and 10 concurrent runs turn the budget over roughly 33 times an hour.

**3. Is a slot held while a run waits on something else?** The lease is taken after discovery and released before
judging, so no. Inside the pool a gate holds its slot for its own wall, including fixtures that wait on other
processes. No gate takes a real slot of its own: `cpu-load`'s self-test uses a private `Local\` budget.

**4. Are leases released on exit 3 and on a kill?** Yes, and both were already fixtured. A timed-out `Enter` returns
holding nothing; the release is in a `finally`; a killed run's slots come back as abandoned mutexes.

**5. Are waiters fair? No - the order is effectively random.** Probe: one private `Local\` slot held by the probe, 8
waiter processes calling `Enter-TcGateSlots -PollMs 500`, started 400 ms apart, then the slot released and passed
along, 3 rounds. Service order by arrival index:

```
round 1   7 6 1 4 2 0 5 3    inversions 19 of 28 pairs    first arrival served 6th of 8
round 2   2 5 1 4 6 3 7 0    inversions 13 of 28 pairs    first arrival served 8th of 8
round 3   2 7 1 6 0 4 5 3    inversions 15 of 28 pairs    first arrival served 5th of 8
```

A uniformly random order averages 14 inversions of 28. So a run that had waited 19 minutes was no likelier to be
served than one that arrived that second, and with a fixed 1,200 s deadline the unlucky ones refused.

**6. Demand against service.** Completed runs, counted as a set of `gate-readings.jsonl` rows, across 69 checkouts:
10h 37, 11h 27, 12h 33, 13h 12, 14h 28, 15h 37, 16h 24 (to about 16:45). Refusals are only countable from the hook
logs the hook KEEPS, and it deletes a passing run's log, so this is a floor: 12 in the 15h hour and 12 more from
16:22 to 16:35. Session scratch files carrying a `RUN-GATES-COMPLETE` with no pre-push text, which is a session's own
run: completed 14h 18, 15h 19, 16h 8; refused for want of a slot 15h 11, 16h 5. So in the 15:00 hour about **37 runs
completed and at least 23 were refused, and about half of the completions were not a push at all**. Meanwhile commits
reaching `origin/main` fell through the afternoon: 09h 10, 10h 5, 11h 6, 12h 8, 13h 3, 14h 5, 15h 4, 16h 2.

**7. Duplicates.** Of 205 completed runs in the live worktrees, **32 ran over the same HEAD as that checkout's
previous completed run**. That is not a clean duplicate count in either direction: an uncommitted edit between two
such runs makes the second one needed, and a commit of exactly the tree just gated is a duplicate a HEAD comparison
cannot see. Concurrent duplicates at 16:39: 0 of 27, every live run a different checkout.

**8. Retries and the push race.** 34 session scratch files that day carry a push to main rejected because main had
moved (`cannot lock ref`, `remote rejected`, `fetch first`, `stale info`), by hour: 11h 3, 12h 9, 13h 7, 14h 3, 15h 4,
16h 8. Again not a count of wasted gates - a stdout and stderr pair can be one push, and a `fetch first` rejection
happens before the hook runs - but git fixes a push's refs when it connects, so any push whose gate takes 20 minutes
of waiting plus 20 of running is likely to be rejected after the whole run. Two retry shapes were visible in the
process table: a loop of up to 6 attempts that rebases and pushes again on a race, and a script that runs `run-gates`
and then pushes, so the hook gates the identical tree a second time.

**9. Reds, not investigated here.** 9 kept hook logs from 13:00 on ended FAILED; `wave-preaudit.ps1` and
`feed-covers-published.ps1` failed in 6 of them each. A red main multiplies demand, because every session then runs
the gate again after a fix. Out of scope for this change.

## What the numbers say

- The pool was overloaded, roughly 60 attempts an hour against about 35 completions, and the width collapse made each
  run hold a slot for about 20 minutes. Randomised service then decided who was refused, not arrival order.
- About half the completions were a session's own run over a tree the hook would gate again minutes later.
- A push that waits 20 minutes and gates for 20 more is likely to find main moved and be rejected after all of it.

## What changed, in the commit that adds this file

1. **Arrival order (`lib/gate-slots.ps1`).** A waiter takes a ticket, only the oldest live ticket may take slots, and
   the deadline becomes "the queue has not moved for `WaitSec`" instead of "1,200 s have passed". A holder no longer
   tops up past a run holding nothing, and deliberate load never jumps the queue.
2. **A verdict is not earned twice (`lib/gate-verdict.ps1`).** A run that exits 0 records its verdict against a
   fingerprint of the HEAD tree, every `git status` entry and the bytes of every script discovery walked. The next run
   in that checkout over identical content prints the pass and dispatches nothing. `-NoReuse` runs them anyway, and a
   red run over that content withdraws the pass. **The fingerprint is content, not history**: it starts as
   `git ls-tree -r HEAD`, and every path `git status` reports takes its working-tree value hashed by git itself the way
   a commit would store it, so the fingerprint of a dirty tree and of the commit recording exactly those bytes is the
   same. That is what makes the estate's actual habit - gate, then commit, then push - pay once; keying on the HEAD
   tree id instead would have missed it, which the fixtures now pin in both directions. Measured on this tree the same
   evening: **737 ms cold, 744 ms warm, 9,091 fingerprint entries** (8,382 tracked paths plus 705 scripts hashed raw for
   byte sensitivity), and two passes over an unchanged checkout agree. Hashing all 8,382 tracked files raw instead
   would be sound too and was measured at **9.0 s for 1.2 GB**, which is why git's own hashes carry the tracked set.
3. **A doomed push stops waiting (`lib/push-landable.ps1`).** The hook hands the gate its refs and the remote's URL;
   when the remote no longer holds the sha any of them was built on, the run refuses in seconds with exit 3 rather
   than queueing and then gating for a push the remote will reject.

## Not done, on purpose

- **The budget of 10 is unchanged**, and so is the cost of a gate. This change is about who waits and what is not
  re-run, not about running more workers.
- **The pool is not stopped mid-flight when a push becomes doomed.** `Invoke-TcParallel` has no stop seam today, so a
  push that is invalidated after dispatch still finishes its gates. That is the largest remaining waste.
- **The two red gates above were not diagnosed**, and nothing here makes a red push cheaper.
- **A fingerprint covers tracked content, untracked non-ignored files and every script discovery walked.** An ignored
  input that is not a script - a gitignored corpus, root debris, a venv - is outside it, which is why a verdict is
  reused only inside the checkout that earned it and only for 180 minutes.

## The rubric this was chosen against

| Property | Arrival order | Verdict reuse | Doomed push refused |
|---|---|---|---|
| A push is still gated or refused loudly, never silently passed | yes, exit 3 names the stall | yes, the reuse is a pass over identical bytes | yes, exit 3 and a rebase instruction |
| Removes the measured starvation | yes, the refusal can no longer be bad luck | no | partly, it shortens the queue |
| Removes wasted slot time | no | yes, for the run-then-push shape | yes, for a push already rejected |
| Hermetic fixtures, no day-one red | yes | yes | yes |

## Re-measured at 20 arrivals, 2026-09-12

**Re-read at commit 78b720b3b: every conclusion above still holds, and item 5 is now re-measured below.** The
arrival-order finding, the occupancy snapshot and the cost-per-run numbers were unaffected by that commit, which
adds the probe and records in `lib\gate-slots.ps1`'s header what the wait does when the producers never stop.

`ops\audit-conclusion-currency.ps1` is why this line exists and why the change is two commits. The section below
names a harness that did not exist when this document cited `c6533c7ea`, so on the first attempt the audit read a
document whose newest cited commit predated its own harness and refused the push - correctly, and it is the same
rule that catches a verdict left standing over a harness that moved underneath it. A document cannot cite a harness
from the future. So the probe landed first, as 78b720b3b, and this section cites the commit it landed as.

**Harness and commit.** `ops\probe-gate-slot-fairness.ps1` at commit 78b720b3b, run against the tree at 8b7d7ff4d.
It is the probe of item 5 above, kept this time. 20 arrivals, each wanting 3 slots of a private budget of 4 for 1,500 ms of
work, staggered 250 ms apart on one absolute release clock published after every child reports ready, because
powershell.exe takes about a second to start and launch order is therefore not arrival order. One row per arrival,
and every total below derived from the rows. Arms alternate ROUND BY ROUND, not arm by arm, so a busy stretch on
this shared box cannot land on one arm only; each arm records the machine's live `run-gates` count at its start (4
to 10 across the six arms).

**The two arms.** AFTER is this tree. BEFORE is a temp mirror whose `Get-TcGateQueueAhead` returns 0 always, which
is the documented pre-queue behaviour: tickets still written, never honoured, nothing swept. The original was
verified byte-identical by md5 after the mutant runs.

**Bars, written before the run** (scratchpad, and restated here): B1 at most 19 of 190 pairs inverted; B2 no arrival
passed by more than 2 later ones; B3 no refusals; B4 peak held at most the budget; B5 the first arrival waits least.
And the standing MUST NOT FIRE: a lone run still gets the whole budget.

| Round | Arm | Inverted pairs of 190 | Worst arrival passed by, of 19 | Refused of 20 | Peak of 4 |
|---|---|---|---|---|---|
| 1 | after | **0** | **0** | 0 | 4 |
| 1 | before | 47 | 9 | 0 | 4 |
| 2 | after | **0** | **0** | 0 | 4 |
| 2 | before | 49 | 9 | 0 | 4 |
| 3 | after | **0** | **0** | 0 | 4 |
| 3 | before | 53 | 15 | 0 | 4 |

Every bar held on all three AFTER rounds. BEFORE breached B1 and B2 in all three. A lone run asking for 10 of a
budget of 10 got 10 of 10 in 34 ms.

**Three things the table does not say, and each of them matters more than the totals do.**

1. **47 of 190 is well under the 95 a uniformly random order averages, and that is not the fix flattering itself.**
   A waiter that arrives earlier also starts polling earlier, so under the old code it usually did win. The damage
   was never spread evenly; it fell hard on a FEW arrivals, and the max passed-by column is where it shows. That is
   exactly the production signature of 2026-09-11: most pushes were fine and a handful waited out the full deadline
   and refused. A mean would have hidden it.
2. **The fix does not make the average wait better, and cannot.** Median wait to first slot rose from 2.3 to 4.3 s
   (before) to 5.1 to 5.2 s (after), with the max at about 10.5 s in both arms. The budget and the work are
   unchanged, so the same queue drains in the same time and the only thing that moves is WHO waits. What arrival
   order buys is a wait bounded by the drain rate instead of by luck.
3. **This probe does not reproduce the refusal itself**, only the mechanism behind it. Its queue drains in about
   11 s, so no arm ever reached its deadline. The production refusal needed a queue that took 20 minutes to turn
   over, which is item 2 of this file and is unchanged by any of this.

**What was considered and not changed.** A cap on how many slots one run may hold while others wait. The head of
the queue may still take the whole budget, and with `run-gates` sizing its pool to what it got, that is the run
that finishes soonest and frees them soonest; capping the head would lengthen the queue it is at the front of.
Arrival order already makes head-of-line a turn rather than a prize.

**What the 1,200 s does when the producers never stop** is now recorded in `lib\gate-slots.ps1`'s own header, per
the ops rule that a threshold states what it does when its producer stops: it never fires, the wait is unbounded
but the SERVICE is guaranteed, and the failure it cannot see is a queue that moves while filling faster than it
drains. That needs a floor on the drain rate, which this upper bound structurally cannot be.
