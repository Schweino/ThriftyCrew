# PLAN: why ~30 gate runs wait on 10 slots, and what to change (2026-09-11)

**Status: PROPOSED. Nothing here is built.** Brad reads and edits this before any code changes.
`$TcGateSlotTotal = 10` is Brad's ruling and nothing below changes it.

## In plain words

The gate queue keeps refilling because more gate runs arrive than 10 slots can finish, and three
parts of the design turn that overload into a loop instead of letting it drain:

1. **A refusal does not remove a run, it postpones one.** 15 of the 20 refused calls were followed by
   another attempt in the same session, 8 of them within two minutes.
2. **The queue has no order.** A freed slot goes to whichever waiting run happens to ask first, so the
   runs that have waited longest are the ones that hit the 20-minute limit. A third to a half of the
   grants we can see went to a later arrival while an earlier one was still waiting and was then refused.
3. **A slow gate makes pushes fail after passing.** While a push waits 20 to 30 minutes for its gate,
   another session lands on main, the remote rejects the push, and the session rebases and runs the
   whole gate again.

On top of that, most sessions run the gate by hand and then push, so the hook runs it a second time.
Nobody is running the gate in a loop from a scheduled task. Two sessions did wrap a push in a retry
loop. And nothing is squatting: a direct probe of the ten slot locks found **none free at any of 20
samples, with ten gates running under them**, so the queue is a shortage of capacity, not of
housekeeping.

The recommendation is an ordered queue with an honest, early refusal (A and B below), then a separate
plan for skipping the second gate run on a tree that has already passed (C).

## The brief

Observed 2026-09-11 about 15:40 to 16:45 local: two consecutive runs from one session exited 3 with
`COULD NOT EVALUATE - waited 1,200s and every one of the 10 machine-wide gate worker slots stayed held`;
33 processes naming `run-gates.ps1` at 16:29 and 35 at 16:42, about 30 distinct runs, none older than
about 25 minutes. The question: why, and is the design feeding it. Candidates to measure: (1) retries
after exit 3, (2) concurrent pre-push hooks, (3) runs holding slots too long, (4) something launching
run-gates in a loop.

## Harness and the commit it ran at

**Harness and commit.** Measured on 2026-09-11 through the five instruments below, against gate code at
commit `d72b4f5cd`. This plan was written on a branch cut from `origin/main` at commit `e5ccc768e` and
fast-forwarded to `564bdca47` before committing; that range does not touch `lib/gate-slots.ps1`,
`lib/parallel-run.ps1`, `ops/hooks/pre-push` or `ops/run-gates.ps1`.

**The code every measured run executed:** `lib/gate-slots.ps1` and `lib/parallel-run.ps1` as of
`d72b4f5cd` (12:26, the Grow/Shrink hand-back), `ops/hooks/pre-push` as of `8549a395a`. Checked, not
assumed: all 25 checkouts named on an observed run's command line contain `d72b4f5cd`, and their copies
of both libraries are byte-identical to `origin/main` `e5ccc768e` (`git hash-object --no-filters`
against the blob). Runs launched from a tool shell as a relative `ops\run-gates.ps1` do not name their
checkout, and were not checked. Runs under a `tc-prepush-selftest-*` path (31 in the observer window) are
`ops/test-prepush-hook.ps1` driving a STUB run-gates; they take no slots and are excluded everywhere
below.

**Instruments.** All five are passive: none started a gate or created CPU load, and only I5 touches a slot
mutex, for microseconds at a time, releasing each in the same pass. The
scripts are committed with this plan under `archive/one-off/gate-queue-2026-09-11/`, outside every gate
walk (`run-gates` and the census both skip `\archive\`). The base commit is stated in the Harness line
above.

| # | Instrument | What it records | Blind to |
|---|---|---|---|
| I1 | `observe-gate-runs.ps1` (v2), `Win32_Process` every 5 s from 16:51:39 | each run: creation time, checkout, full ancestry, direct children per poll (its pool's workers), whether its parent died, exit code through a handle opened while it lived | a run's wait or hold when its slot was granted before the observer started; it counts ALL direct children, so run-gates' own post-pool `git rev-parse` reads as a worker (one poll read 11); and a 5 s sample cannot see a slot whose worker is between gates, so its occupancy is a FLOOR |
| I2 | the pre-push hook's own logs, `%TEMP%\tc-prepush-<sh pid>.log` | arrival (file creation), `after Ns waiting`, `pool width reached`, `timing: ... Ns wall`, verdict | **every run that PASSED**: the hook deletes its log on exit 0, so these are refusals, failures and live runs only |
| I3 | `parse_push_attempts.py` + `analyze_attempts2.py` over every session transcript written on 2026-09-11 | each Bash or PowerShell tool call whose command executes `git push` or `-File ...run-gates.ps1`, and what its output or background output file says happened; the owner is the transcript the call is in, never a timing match | pushes launched as `Start-Process git -ArgumentList push` (found one by hand); **237 of 416 calls show no outcome** because their output went to a file |
| I4 | `git reflog refs/remotes/origin/main` in the shared `.git` | every successful push to main from any checkout on this box | pushes from off the box |
| I5 | `probe-free-slots.ps1`, 20 samples 4 s apart | how many of the 10 slot mutexes are FREE at an instant, beside the live runs and gate workers. It takes each free slot for microseconds and releases it in the same pass | one minute of one afternoon; it says nothing about who holds a slot, only how many are unheld |

Owners are named from process shape (I1) or from the transcript a call is in (I3). Nothing below
attributes a run to a session by timing.

**One correction, recorded because it is the shape this estate keeps paying for.** The first version of
I1's reader called a real run a WRAPPER whenever one of its children matched the root rule. A gate worker
running `ops/test-prepush-hook.ps1` has exactly that, the sandbox STUB, so those runs' workers were
dropped from the occupancy sum, which read 7.36 of 10 and looked like idle slots. I5 then found 0 free at
20 of 20. **A number that moved because the tool was wrong, not the tree**, the same lesson
`ops/count-tracked-writers.ps1` already carries. The reader is fixed, the corrected figure is in finding
(3), and the snapshot in finding (2) still carries the old rule's floor.

## Findings, one per candidate

### (1) Retries after exit 3 - YES, it feeds the queue

I3: 20 tool calls today show a slot refusal in their own output. **15 were followed by another push or
gate call in the same session; 5 were the session's last.** Of the 15, **8 started within two minutes of
the refusal ending** (gaps of 0, 0, 1, 1, 1, 1, 1 and 2 minutes), 1 had already been started in the
background while the refused call was still waiting, and 6 came 8 to 26 minutes later. In 4 sessions
the next call was refused too. A refused run leaves the queue for about a minute and comes back at a
random position.

The refusal is also mislabeled. `ops/hooks/pre-push` prints *"That means gate discovery is broken, NOT
that the tree is clean"* for every exit 3, including this one, where discovery was fine and the machine
was busy.

### (2) Concurrent pre-push hooks - YES, and it is most of the demand

Snapshot 16:54:03: **at least 27 real runs** (after dropping 6 Claude tool-shell wrappers whose child was
the real run): **20 pre-push hooks** (`sh.exe` parent, 20 different checkouts), **6 tool-shell runs**
(`powershell.exe` parent) and **1** launched straight from `claude.exe`. **10 workers in total.** This one
was counted with the reader's first wrapper rule, so a run whose worker was driving a sandbox stub was
dropped with the wrappers: 27 is a floor. A later snapshot at 17:37, with the rule corrected, read 11 real
runs sharing exactly 10 workers.

I3, sessions with at least one push or gate call, by local hour:

| hour | 08 | 09 | 10 | 11 | 12 | 13 | 14 | 15 | 16 |
|---|---|---|---|---|---|---|---|---|---|
| sessions | 5 | 11 | 9 | 9 | 11 | 3 | 26 | 37 | 43 |
| calls running run-gates by hand, no push in the same call | 4 | 19 | 15 | 7 | 14 | 1 | 23 | 29 | 25 |
| calls that push (6 of them also run the gate first) | 2 | 14 | 11 | 15 | 20 | 4 | 17 | 22 | 36 |

Sessions touching the gate went from about 10 an hour before 14:00 to 26, 37 and 43. And the load is
doubled by habit: **of 73 sessions that ran
`run-gates.ps1` by hand, 42 later pushed**, and the hook ran the whole gate again. Whether the tree was
unchanged between the two runs was not measured, so 42 is an upper bound on avoidable reruns from that
source.

### (3) Runs holding slots too long - NOT in the straggler form

**The slots are all held, and the held slots are working.** I5, a direct probe that opens each of the 10
slot mutexes, counts the free ones and releases them in the same pass, 20 samples 4 s apart at 17:39 to
17:40: **0 free at 20 of 20 samples, with 10 gate workers running and 12 runs live.** So nothing is
holding a slot it is not using, and no deliberate load (`ops/cpu-load.ps1`, which draws on the same
budget) was running at any snapshot.

I1 counts gate-worker PROCESSES every 5 s instead, and over 487 polls reads **min 6, max 11, mean 8.09,
with 10 or more at 86 of 487**. Read that as a LOWER BOUND, not a contradiction: a slot whose worker has
just exited and whose next gate has not started yet shows as empty to a process sample, and I1 cannot see
the mutex. The two were not fully reconciled. The question this section asks - is a slot being squatted
on - is answered by I5, and the answer is no. There is nothing here for the Shrink hand-back to fix.

What is long is the hold of a run that was granted ONE slot. I2's wall clock starts before the wait, so
hold = wall minus wait:

| sh pid | arrived | waited | width reached | wall | hold | verdict |
|---|---|---|---|---|---|---|
| 46594 | 16:01:43 | 31 s | 1 | 1,122 s | **1,091 s** | FAILED |
| 27418 | 15:13:47 | 1,011 s | 1 | 1,864 s | **854 s** | FAILED |
| 30933 | 15:23:02 | 425 s | 1 | 1,204 s | **779 s** | FAILED |
| 25082 | 15:07:14 | 597 s | 2 | 1,288 s | 691 s | FAILED |
| 30060 | 15:20:44 | 460 s | 2 | 1,046 s | 586 s | FAILED |
| 27617 | 15:14:15 | 867 s | 2 | 1,444 s | 577 s | FAILED |
| 45538 | 15:58:52 | 82 s | 6 | 316 s | 234 s | FAILED |

These are FAILED runs only (I2 cannot see a pass), 7 of them. Every run in the table except one reached
width 1 or 2. Grow tops a pool up only when a slot is free, and a freed slot is raced by about 20
waiters polling every 500 ms, so a run granted one slot keeps exactly one for its whole serial pass. The
quiet serial figure was 372 s for 304 gates on 2026-09-09 (`design/MEASURE-gate-cost-2026-09-09.md`);
today's runs dispatch 361 to 366 gates, and the box sampled 50 to 82% CPU with 132 `claude.exe`
processes. How much of a 779 to 1,091 s width-1 hold is load and how much is the 20% more gates was
NOT separated.

Fragmentation is not a throughput loss on its own. The same gate-seconds pass through 10 slots either
way. It is a LATENCY amplifier, and latency is what drives finding (5).

### (4) Something launching run-gates in a loop - no launcher; two push-retry loops inside sessions

I1: every observed run's ancestry is a Claude session, either through `git.exe`, `sh.exe` or a tool
shell. There was no scheduled-task or service shape. One hook run's `claude.exe` ancestor had already
exited when it was first seen, so its verdict had no reader.

I3: 21 calls in 11 sessions push inside a loop construct. That test is unsound: it strips strings and
comments and still counts a `foreach` over files. Read by hand, most are file loops, and four sessions
poll for other run-gates processes before pushing or running the gate once. **Two are explicit push-retry loops, and every
iteration is a full gate:**

- one allows up to 6 attempts. Attempt 1 started 16:15:55, its push took **1,598 s**, the gate
  **passed** (`pass=363 fail=0`), and the remote refused it: `cannot lock ref 'refs/heads/main': is at
  e5ccc768e... but expected cda34d71b...`. Attempt 2 started 16:42:48.
- one allows up to 3 attempts and `continue`s on `cannot lock ref|fetch first|non-fast-forward`.

`.claude/rules` forbids `run-gates` in a loop as CPU load. A push-retry loop has the same effect on the
queue and is not covered by that wording.

### (5) Found while measuring: the push herd - YES, a feedback loop

`origin/main` moved 9 times between 14:00 and 16:59 (I4). A push to main is checked against the remote's
head when it STARTS, but the ref is only updated when its gate FINISHES, 10 to 30 minutes later under
this load. I3 counts **20 calls today, 7 since 14:00, whose output shows the gate ran and the remote then
rejected the push**. All 7 were opened and read: each is `! [remote rejected] HEAD -> main (cannot lock
ref 'refs/heads/main': is at <new> but expected <old>)`, and 5 of the 7 print a PASSING gate
(`RUN-GATES-COMPLETE pass=357` to `361`, `fail=0`) immediately before it. The session then has to rebase,
and the next push runs the whole gate again. The longer the queue, the longer
a gate takes, the more often main moves under it, and the more runs join the queue.

### (6) Found while measuring: arrival order is not honoured - YES

`Enter-TcGateSlots` has every waiter poll `WaitOne(0)` over the 10 slots every 500 ms. Whoever polls
first after a release wins. I2, runs whose log shows the grant: **9 of 18 read at 16:57, and 6 of 17
read again at 17:38, were granted while an EARLIER arrival was still waiting and then exited 3.** The
clearest arrived at 16:50:12 and was granted after 19 s while 7 runs that arrived from 16:30:33 onwards
waited and were all refused.

**Read the two figures as one finding, not as a fall.** The population they are drawn from SHRINKS: the
hook deletes a log on a pass, so a grant leaves the visible set as soon as its run passes, and what stays
visible is refusals, failures and live runs. Neither is a rate. The spread of visible waits says the same
thing without needing a denominator: 18, 31, 36, 77, 82, 91, 108, 250, 394, 425, 453, 460, 593, 597, 867,
970 and 1,010 seconds, all of them overlapping in time.

### Why it refills

Rough capacity: I1's 24 completed holds over 50 minutes run **296 to 942 s, median 584 s**, at max widths
of 1 to 3, so a run costs roughly **600 to 1,900 slot-seconds**; through 10 slots that is **about 19 to 60
runs an hour**, and the wide spread is the honest state of it. Demand: I1 saw **38 real runs created in 50
minutes, 45.8 an hour** (28 pre-push hooks, 10 tool shells), and of the 49 runs that ended inside that
window **20 exited 3, 22 exited 0 and 6 exited 1**. I2 counts **46 refusals between 14:48 and 17:34**. So demand sits at or above the top of the capacity range, and the wait grows
to the 1,200 s deadline, which then sheds runs. But the shed runs are retried (1), the runs that do pass are re-run by the herd (5),
and hand runs are re-run by the hook (2). So shedding does not lower demand. That matches what the brief
saw: a queue that keeps refilling, with nothing older than about 25 minutes.

## Is the design feeding it?

Yes, in three places, and one habit multiplies all three:

- **No order.** The runs that waited longest take the refusals (6).
- **A refusal that costs 20 minutes, reads as a broken tree, and tells the caller nothing.** So callers
  retry at once (1).
- **Gate latency and main's movement are coupled.** A run that waited 20 minutes passes and is rejected
  anyway (5).
- The habit: run the gate by hand, then push (2), and wrap the push in a retry loop (4).

## Proposed changes (not built)

**Rubric.** Each option is judged on: (r1) refusals and reruns removed; (r2) any chance a push goes out
ungated, or a verdict is applied to bytes it did not run on, which must be zero; (r3) `$TcGateSlotTotal`
stays 10; (r4) reversible in one revert; (r5) a MUST FIRE exists that uses a rendezvous or a held mutex,
never a clock, per `ops-and-gates.md`.

### A. An ordered queue in `lib/gate-slots.ps1` - recommended

Each waiter writes a ticket (arrival ticks, pid, process start time) into one shared queue directory.
Only the OLDEST live ticket may try the slots. It takes what is free (at least one), removes its ticket,
and the next ticket becomes the head. Grow may top a running pool up only when no ticket is waiting, so a
waiting run always beats a wider one. A ticket whose pid is gone, or whose pid now has a different start
time, is dead and is skipped. That keeps the property the mutexes already have: a killed waiter cannot
block the head.

- r1: removes (6), the out-of-order grants. It does NOT add capacity.
- r2: none; the slots and the refusal are unchanged.
- r5: MUST FIRE, an earlier waiter in another process gets a released slot before a later waiter that
  polls harder. MUST FIRE, a head whose process is killed does not block the next ticket. CLEAN TWIN, a
  lone run on an empty queue still gets its whole want at once.
- The queue directory is deliberately shared across runs, like the restore journal the temp-path rule
  describes. It stays fixed on the production path and is redirected inside the self-test.
- **When the producer stops:** an empty queue makes the head rule vacuous and nothing waits.

### B. An early, honest refusal - recommended, with A

At arrival, with A's queue in place, a run knows how many tickets are ahead of it. It keeps a small
record of recent holds, written by runs as they release, and estimates its wait as tickets ahead times
the median recent slot-seconds per run, divided by the budget. If that estimate is already past the
deadline, it refuses AT ONCE with exit 3 and says: queue depth N, estimated M minutes, retrying now joins
the back of the queue. With no recent history it waits as today. The deadline becomes "the queue head
has not moved for 20 minutes" rather than 20 minutes absolute, so a run that is moving up is not refused
for being patient. `ops/hooks/pre-push` prints a slot refusal as a queue refusal, not as broken
discovery.

- r1: a refused run stops occupying a process for 20 minutes, and its caller is told not to hammer. It
  cannot stop a session that retries anyway.
- r2: none; a refusal is still exit 3 and still blocks the push.
- New constants: none. The deadline exists today. The estimate is derived from recorded holds, not a
  band.
- r5: MUST FIRE, with N fixture tickets ahead and a fixture hold record, the run refuses in under one
  poll (asserted as "no slot was ever tried", not as a time). CLEAN TWIN, with no hold record it still waits and is granted when a slot frees.
- **When the producer stops:** no releases, so no new hold records. The head-not-moving deadline still
  fires, which is the case the absolute deadline covers today.

### C. Do not run the gate twice on the same bytes - next plan, not this one

`run-gates` writes a PASS record keyed on everything the pass read: `HEAD^{tree}`, an empty `git status
--porcelain --untracked-files=all`, and the hash of the gate's own discovery list. `pre-push` skips the
gate only on an exact key match. It never skips after a rebase, because the tree differs.

- r1: the largest demand cut available, up to 42 sessions' second run (an upper bound, see (2)).
- r2: the only option with real risk. Discovery walks untracked and ignored files, so the key must cover
  every file the walk enrolled, and it needs MUST FIRE cases for a new untracked `.ps1`, a changed ignored
  file under discovery, and a changed `run-gates.ps1`. **That deserves its own plan and its own read**, so
  it is named here and not designed.

### D. A main-push turnstile against the herd - measure first

Serialize "gate, then push to main" behind one machine-wide mutex, so a gated push cannot be invalidated
while it runs. It removes (5) but makes every main push wait for the one before it. Today's actual rate,
9 updates in 3 hours, suggests that costs little, but that is not a measurement. **Re-measure the herd
rate after A and B**, because shorter gate latency shrinks it without any new lock.

### E. Guidance only - not enough on its own

A `CLAUDE.md` line: the push runs the gate, so do not run it by hand first unless you need the output;
never wrap a push in a retry loop. The memory store records a rule delivered every turn and broken six
times, so this goes in alongside B's message, not instead of it.

### Not recommended

Raising the total (ruled). Random back-off in the caller (it is the unordered poll we already have).
Skipping the gate when the queue is long (r2).

## Acceptance bars, written before anything is built

For A and B together, over the first window after deploy with at least 30 hook runs, read from the
queue's own log:

- **zero** grants to a ticket while an older live ticket was waiting;
- a run refused by B's estimate exits within one poll of arriving, and no run is refused by the deadline
  while the head is moving;
- re-run I3: refused calls followed by another push or gate call within two minutes, fewer than today's
  **8 of 20**, stated with its own denominator.

A number that moves will be reported with how far, over how many runs, and that this is the first
variant tried.

## Still unmeasured

- A lone run's wall at width 10 (the register already says so) and a width-1 hold on a quiet box at
  today's 366 gates.
- Whether the 42 hand-run-then-push sessions pushed the tree they had gated.
- The passing runs' waits and holds: I2 cannot see them, and I1 started too late for runs granted before
  16:51.
