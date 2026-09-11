# PLAN: the machine-wide gate queue - 2026-09-11

**Status: PLAN. Nothing is built.** `ops/run-gates.ps1` is the push gate for every session on this box, so
this is written first for Brad to read and edit. The measurement it rests on is in section 2 and is complete;
the fix in section 6 is a proposal with three open decisions in section 9.

## 1. What was reported

2026-09-11, about 15:30 to 16:40. `run-gates`, standalone and through `ops/hooks/pre-push`, printed *"all 10
machine-wide gate worker slots are held by other gate runs - waiting for one (up to 20 min)"* and then exited 3
with *"COULD NOT EVALUATE - waited 1,200s ... Nothing was run"*, twice in a row, refusing the push both times.
`Win32_Process` listed 40 PowerShell processes naming `run-gates.ps1` or `cpu-load.ps1` over about 20
worktrees. The budget is `lib/gate-slots.ps1` (`Enter-TcGateSlots`, total 10).

A queue where a push waits 20 minutes and then exits 3 teaches `--no-verify` exactly as a red that blocks
unrelated pushes does (`.claude/rules/ops-and-gates.md`).

## 2. How it was measured

**No gate load was added.** No `run-gates` and no `cpu-load` was started. Every figure comes from reading state
other sessions were already producing:

| Source | What it gives | Its bias |
|---|---|---|
| A read-only sampler, every 15 s for 30 min from 16:51 | which of the 10 `Global\tc-gate-worker-slot-N` mutexes are HELD, every `run-gates` process with its ancestry and children, every recent hook log's state, total CPU, run queue, and every 4th sample the CPU split by process tree | a process counts toward CPU only if alive at the sample, so short-lived gate children are undercounted |
| `%TEMP%\tc-prepush-<n>.log`, read with shared access | per push: whether it waited, how long, width, refusal, gate work | **a PASS deletes its log**, so logs already on disk are biased to failures and refusals; a refusal always keeps its log, so refusals per hour are complete |
| `ops/out/gate-readings.jsonl` in 72 checkouts | one timestamp per run that reached judging, so completed runs per hour | misses checkouts already deleted, so an undercount |
| `git rev-parse HEAD^{tree}` in each live checkout | whether live runs gate identical trees | none |

**The slot probe never acquires a slot.** It opens each mutex with `MUTANT_QUERY_STATE` and reads
`NtQueryMutant`, and was calibrated at start against a mutex it held: held read 1 from the holding thread and
from another thread, released read 0, disposed read -1.

**Harness and commit.** The sampler and analysis are kept as text beside this plan in
`design/gate-queue-2026-09-11-data/` (`.txt`, so no discovery walk enrols them), with `runs.jsonl`, one row per
hook run, from which every per-run figure below is derived. They ran from the session scratchpad on 2026-09-11.
The gate code under measurement is **not one commit**: every push runs its own checkout's copy. Of 117
checkouts on the box, 92 carry the current generation (`d72b4f5cd`, grow and shrink), 4 carry slots without
grow and 21 predate the budget; **all 17 named checkouts with a live run were the current generation**. The
standalone runs' checkout cannot be read from their command line, so their generation is unknown. origin/main
was `e5ccc768e` throughout.

Two traps hit while measuring, recorded so the next measurement does not repeat them:
- **NTFS does not update LastWriteTime for a file another process holds open.** A live hook log reads as last
  written at its creation for the whole run. Dispatch time is therefore arrival plus the wait run-gates prints.
- **A hook log that a pass deletes cannot be sampled after the fact.** The only unbiased cohort is runs that
  arrived while the sampler watched.

## 3. What the numbers say

### 3.1 How many waiters

Over 120 samples in 29.8 minutes, 16:51 to 17:21: **a median of 10 hook runs sat in the slot wait, between 4
and 16**. `run-gates` processes numbered a median of 20 (13 to 27), of which a median of 7 (6 to 9) had gate
children. **All 10 slots were held in 120 of 120 samples**, so the budget was saturated for the whole window.

### 3.2 How long a run holds a slot

**Every run starts at width 1, and widening is slow and partial.** **24 of 24** dispatched hook runs started at
width 1. Of the 8 whose pool finished with its log kept, 3 never rose above 1 and 5 reached 2, 2, 2, 2 and 6. So
a slot is held for most of the run's gate work:

- **Gate work per run, 7 failing runs that kept their timing: min 776 s, median 889 s, max 1,085 s**, all
  started at width 1. Across the kept logs by hour it was a median 889 s at 15:00 and 1,085 s at 16:00.
- The same gates uncontended on 2026-09-09 were **370 s of work** serially (304 gates then, 362 now, so about
  440 s at today's count; `design/MEASURE-gate-cost-2026-09-09.md`). Today's slot-seconds are **about 2x**.
- A run's `wall` figure includes its wait, so it is not the hold time. Dispatch to log-gone, for the 7 runs
  dispatched and finished inside the window: min 481 s, median 539 s, max 1,137 s.

### 3.3 Order of service: no FIFO, and early arrivals starve

`Enter-TcGateSlots` has no queue. Every waiter polls all 10 mutexes every 500 ms, and every running pool polls
too (`Add-TcGateSlots`, at most every 500 ms while it has gates queued). A freed slot goes to whichever process
polls first. Measured:

- **98 inversion pairs**, where a run arriving more than 120 s LATER was served while an earlier one still
  waited. **34 of the 70 queued hook runs were overtaken at least once, and 24 of the 41 refused runs were
  overtaken before they were refused.**
- Of the 16 hook runs that arrived while the sampler watched, the unbiased cohort: 9 dispatched after a median
  486 s (80 s to 1,180 s), 2 refused at 1,200 s, and 5 still waiting when the window closed, the oldest 1,037 s
  in. Waiting is the normal state, not the exception.
- One case read straight off the logs: a push that arrived at **16:37:55 was served after 92 s**, while pushes
  that arrived at 16:26:49, 16:26:59, 16:30:08, 16:30:33, 16:31:04, 16:31:13 and 16:32:06 were still waiting.
  Each of those seven was then refused at exactly 1,200 s.

So the 20-minute cap does not fall on the newest arrivals. It falls at random, and it can fall on the first
push in line.

### 3.4 Abandoned or orphaned waiters and holders: none holding slots

Counting holders as runs that have printed their dispatch line and not yet finished their pool, plus standalone
runs with gate children (a floor, since their state has no log): **holders ran 7 to 9 against 10 slots held,
in 120 of 120 samples. Never 0 holders, and never more holders than slots.** The gap of 1 to 3 is what widths
above 1 look like; one run at width 6 accounts for it alone.

**That the gap is not a leak is settled by the mutexes themselves, not by the gap.** A leaked slot is an
abandoned mutex, and an abandoned mutex is acquired by the very next `WaitOne`. With 10 to 16 waiters polling
all 10 names every 500 ms, a slot whose owner had died could not read as held for 120 consecutive samples. It
would have been taken inside a second.

- A killed holder frees its slots as abandoned mutexes; `lib/gate-slots.ps1`'s CLEAN TWIN already drives that.
  A waiter holds no slot at all.
- Parentless ThriftyCrew processes seen: 2, the sidecar server on port 8077 and one session's detached push
  wrapper. Neither is a slot holder.
- **1 run-gates whose launching session process had exited** while its `git push` lived on. It holds no slot
  while it waits, but **it will push if it passes, for a session that has stopped listening**. That is a
  separate hazard and is not fixed here.
- The `cpu-load.ps1` processes in the original report were **self-test children** of running gates, on a
  private `Local\` prefix. No deliberate load was waiting for slots.

### 3.5 Demand against capacity

| Local hour, 2026-09-11 | Runs completed (gate-readings) | Pushes refused for no slot (by the hour the push started) |
|---|---|---|
| 10:00 | 35 | 0 |
| 11:00 | 27 | 0 |
| 12:00 | 33 | 0 |
| 13:00 | 12 | 0 |
| 14:00 | 28 | 2 |
| 15:00 | 37 | 10 |
| 16:00 | 30 | 24 |

- **Capacity** at today's slot-seconds: 10 slots x 3,600 s / 889 s is **about 40 runs an hour**, and the
  completions above sit at 27 to 37. The budget is running at capacity.
- **Arrivals** while the sampler watched: **31 runs in 29.8 min, 63 an hour** (22 through the hook, 9
  standalone). **7 of 28 named checkouts started run-gates twice inside that half hour**, and several ran it 9
  or 10 times over the day, so part of the demand is the queue's own echo.
- **63 arriving against about 40 served is the whole story of the refusals.** 41 of 70 hook runs in the
  timeline were refused.
- **So demand was above capacity from about 14:00.** With demand above capacity a queue grows whatever order it
  serves in. Order decides who is refused; it cannot decide how many.

### 3.6 Why capacity is half what it should be: the CPU the budget cannot see

Total CPU ran at a median 76.5%, at or above 95% in 20 of 120 samples, with the processor queue reaching 248.
Attribution over 30 samples, mean cores of 32 logical:

| Where | Mean cores | Share of attributed |
|---|---|---|
| outside any Claude session or run-gates | 6.02 | 30% |
| gate trees, the processes the budget counts | 5.90 | 29% |
| session trees, below a Claude session but not below run-gates | 5.16 | 25% |
| claude.exe itself | 3.06 | 15% |
| the run-gates processes themselves | 0.22 | 1% |

**The gates are 29% of the CPU they compete for.** The budget bounds that 29% and nothing else, and inside the
other 71% a gate costs about 2x its quiet price. A slot count cannot defend gate latency against load it
cannot see. The attribution misses processes that start and end between samples, so gate trees, which are
short-lived by construction, are understated rather than overstated.

### 3.7 Identical trees

**22 live runs gated 22 distinct trees.** Deduplicating concurrent identical-tree runs would have saved nothing
in this episode.

## 4. The cause

In order of weight:

1. **Demand above capacity.** From about 14:00, pushes arrived faster than the 10 slots could gate them at
   today's slot-seconds. Nothing about ordering changes this.
2. **No ordering.** The wait is a lottery among every waiter and every growing pool, so the 20-minute cap lands
   on arbitrary pushes, including the earliest. That is a defect in its own right: a push can be refused while
   the queue is moving and it was first in line.
3. **The cap measures the wrong thing.** 1,200 s of TOTAL wait fires on a queue that is moving, so a 3 stops
   meaning "could not evaluate" and starts meaning "the machine was busy". Each refusal also sends the push to
   the back of the lottery on retry, which feeds item 1.
4. **Slot-seconds doubled under CPU load the budget does not count** (3.6), which halves capacity.

**Not the cause:** leaked or orphaned slots (3.4), deliberate `cpu-load` (3.4), pre-budget runs outside the
budget (all 17 named live checkouts were current), identical-tree duplicates (3.7).

## 5. What the fix must keep

- **Exit 3 means could not evaluate**, and is never a pass. After the fix a 3 must mean the queue is WEDGED: no
  progress anywhere on the machine for the stall bound. It must not fire while the queue moves.
- The total stays 10 (Brad's ruling). The fix orders the budget; it does not resize it.
- A killed waiter or holder never wedges anything.
- A lone run on an idle machine behaves exactly as today.

## 6. Phase 1, the proposed fix: a FIFO ticket queue and a progress-based stall

### 6.1 Tickets

In `Enter-TcGateSlots`, non-`-Exact` path only:

- The first time a pass finds no free slot, the waiter creates
  `<QueueDir>\<UtcTicks:D19>-<pid>.wait` with `FileMode.CreateNew` and `FileOptions.DeleteOnClose`, and keeps
  the handle open for the whole wait. The handle closes on grant, on refusal, and in `finally`.
- **Position** is the ticket's rank among `*.wait` names sorted ordinally. **Only position 1 tries the
  mutexes.** Everyone else only watches.
- **A killed waiter leaves the queue by itself.** Probed on this box: a ticket held by another process is listed
  and `File.Exists` sees it, a second `CreateNew` of the same name is refused, and 3 ms after that process is
  killed the file is gone. No sweeper deletes anything, so a live ticket cannot be removed by someone else's
  cleanup.
- `QueueDir` defaults to `%TEMP%\tc-gate-queue`. All 8 of 8 scheduled tasks that touch the repo run as `Owner`,
  interactive, so every session and task shares that `%TEMP%`. The self-test passes a per-run directory, per
  the fixed-temp-name rule in `ops-and-gates.md`.
- `-Exact` (`ops/cpu-load.ps1`) takes no ticket and is unchanged. Deliberate load already cannot get N slots
  together while gate runs churn, and still will not; its own 600 s exit 3 stays its own contract.

### 6.2 Holders report progress

When a lease is granted, `run-gates` opens `<QueueDir>\<UtcTicks>-<pid>.hold` (DeleteOnClose) and writes the
count of gates finished into it as each gate finishes. `lib/parallel-run.ps1` gains one optional callback,
`-OnJobDone`, called with the running total, because neither `-Grow` nor `-Shrink` is called when a gate
finishes mid-dispatch.

### 6.3 The stall bound replaces the total-wait cap

A waiter refuses with 3 only when, for `StallSec` (1,200 s, the existing number), **nothing moved**: the
position-1 ticket stayed the same ticket AND no `.hold` file's count changed. Then it prints what it saw:

> run-gates: COULD NOT EVALUATE - the gate queue made no progress for 1,200s: position 4 of 9, the same push
> at the head throughout, and no gate finished in any of 10 held slots. Nothing was run; that is not a pass.

Why this keeps a 3 honest: a holding pool finishes a gate at least every 900 s even when a gate hangs, because
`Invoke-TcParallel` kills a gate at `TimeoutSec` 900 and counts it. So 1,200 s with no gate finishing
anywhere means every holder is suspended, deadlocked outside its pool, or not a run-gates at all. That is could
not evaluate. **What it does when the producer stops:** no runs means no tickets and no wait; holders that stop
progressing make every waiter refuse loudly after 1,200 s.

**There is no total-wait ceiling in the recommendation.** A push at position 20 waits as long as the 19 ahead
take. It prints its position when it enters and whenever it moves, at most once a minute, with the rate it has
observed (*"position 9 of 14, moved 3 places in 6m12s"*), so the wait is spoken rather than silent. Decision 2
in section 9 is whether to add a ceiling anyway.

### 6.4 Growing pools keep growing

`Add-TcGateSlots` is unchanged: an admitted run still tops up toward its ask while it has gates queued, racing
only position 1 for freed slots. The alternative is decision 1.

Why keep it. Under saturation 10 slots are busy whichever runs hold them, so runs an hour is set by slot-seconds
per run, not by how the slots are split. What the split changes is how long each push sits in the pool. Ten
equal runs sharing 10 slots at width 1 all finish at about 890 s; the same runs finishing one after another at
full width finish at about 89, 178, ... 890 s, a mean near half. Today 3.2 shows the first shape.

**This is a prediction, not a measurement.** It assumes a gate costs the same wherever its slot came from, which
is plausible at a fixed number of busy slots and is untested. Phase 2's ledger is what tests it.

Starvation stays bounded: no run can be admitted ahead of position 1, so the only processes that can beat it to
a slot are pools already admitted. Each of those stops growing when its last gate is dispatched, so position 1
waits at most until every pool admitted before it has dispatched everything.

### 6.5 Text that changes

- `run-gates` OnWait line: position and queue length, not "(up to 20 min)".
- `run-gates` refusal line: 6.3's wording.
- `ops/hooks/pre-push:106` says "(about 51s)". Today a run holds a slot for about 890 s and may queue first.
  The line stops quoting a duration.
- `docs/CONTROL-CONSTANTS.md`: the `TcGateSlotTotal` row's "a run that waits 20 min for one slot exits 3"
  becomes the stall rule, and new rows for `StallSec = 1200` (the old cap re-read as a stall bound, first
  plausible, NOT a sweep), the 500 ms queue poll, and the once-a-minute position line.

### 6.6 Fixtures, in `lib/gate-slots.ps1 -SelfTest`

Every competing waiter and holder in its own process, `Local\` prefix and a per-run queue directory, no upper
wall-clock bar anywhere.

- **MUST FIRE, FIFO.** A holder process keeps all 3 slots. Waiter A enters (500 ms poll). Waiter B enters after
  A's ticket exists, polling every 20 ms: under the lottery the fast late poller wins almost every time. The
  holder releases ONE slot only after 2 tickets exist. A must be granted and B must not.
- **MUST FIRE, a killed position 1 leaves the queue.** Kill A while it waits. B becomes position 1 and takes the
  next freed slot, and A's ticket is gone.
- **MUST FIRE, stall.** Holder keeps every slot and its `.hold` count never changes. A waiter with a small
  `StallSec` refuses with TimedOut and names the stall. Asserts the refusal, never how quickly.
- **MUST NOT FIRE, a moving queue is not refused.** Waiter C at position 3 against a fake clock (a `-Clock`
  seam the fixture advances). The fixture closes ticket 1 at 0.9 x StallSec, ticket 2 at 1.8 x, then releases a
  slot at 2.7 x. C is granted, having waited 2.7 x the bound. The old total cap refuses it at 1.0 x.
- **CLEAN TWIN, the real timer.** With no seam, the stall wait still ends in TimedOut.
- **CLEAN TWIN, holder progress counts.** No ticket ahead moves, but the `.hold` count advances inside every
  window. Not refused.
- **CLEAN TWIN, nothing left behind.** A lone run on an idle machine creates no ticket; a granted waiter leaves no
  `.wait`; `Exit-TcGateSlots` leaves no `.hold`.
- **Every existing case keeps its NAME and passes.** Diff case names, not the count.

Then a mutation probe from a temp mirror, original verified byte-identical by md5 afterwards: position-1 check
removed, `DeleteOnClose` dropped, sort reversed, stall clock not reset on progress, `.hold` count ignored. Kill
rates are recorded as measured, never predicted.

### 6.7 Acceptance bar, written before the build

1. `lib/gate-slots.ps1 -SelfTest`, `lib/parallel-run.ps1 -SelfTest` and `ops/cpu-load.ps1 -SelfTest` exit 0 with
   every pre-existing case name present.
2. The FIFO must-fire is green 20 of 20. With the position-1 check removed, it goes red in **at least 15 of 20**
   runs, and the actual count is recorded.
3. The position-1-check mutant, the DeleteOnClose mutant and the stall-reset mutant each go red in their named
   case.
4. One full `ops/run-gates.ps1`, run once through the hook on the push itself, never in a loop, exits 0.
5. **Live, after the change is on main.** Among runs that carry it: zero inversions, since order is by
   construction and any inversion is a bug; and every refusal's line names a stall. Throughput and latency are
   REPORTED with denominators, not barred, because arrival load is uncontrolled and would confound any bar.

### 6.8 Rollout: mixed versions for weeks

Each push runs its own checkout's `lib/gate-slots.ps1`, and 25 of 117 checkouts still carry an older one.
Until a checkout rebases, its runs poll the mutexes without a ticket and **jump the queue**. Queued runs on the
new code are then served only when position 1 beats those pollers. That can be slower than today's lottery
for a queued run. A branch cut from main after the change gets it at once.

**The stall rule has a hole while old code holds slots, and it is stated rather than hidden.** An old-code
holder writes no `.hold` file, so its progress is invisible. If old-code runs hold all 10 slots and keep
winning every freed one for 1,200 s, the new-code position 1 sees no head change and no `.hold` change, and
refuses with 3 although the machine is moving. Only position 1 can be refused that way, and the next waiter
becomes position 1 with a fresh 1,200 s. So the worst case in that window is one refusal per 20 minutes, where
today every waiter can be refused from the moment it arrives. It closes as checkouts rebase. The live
observation for it: a stall refusal while `Win32_Process` shows run-gates with gate children. If it recurs
after most checkouts carry the change, the holder-progress signal needs a second source.

### 6.9 Blast radius and rollback

Every push on the box passes through this.
- A bug that WEDGES the queue shows as a loud 3 after 1,200 s with the stall line.
- A bug that lets runs skip the queue reverts to today's lottery, which is not worse than now.
- Rollback is a revert of one commit. The bypass stays `git push --no-verify`.

## 7. Phase 2, recommended in the same change: one ledger line per lease

`Exit-TcGateSlots` appends one JSON line to `<QueueDir>\gate-leases.jsonl` through `lib/append-line.ps1`
(`Add-TcLine`), which is concurrency-safe for many appenders. Each line records:

- pid, checkout and the `HEAD^{tree}` it gated;
- whether the hook launched it, which the hook marks with an environment variable;
- arrival, position at entry, wait, and first and peak width;
- gates finished, release time, and outcome (granted, stalled or killed is absent).

This is the history today's measurement had to reconstruct from temp logs that a pass deletes. It answers three
open questions with rows rather than guesses:
- whether growing pools lower per-push latency (6.4);
- how many pushes re-gate a HEAD tree that already passed, an upper bound on what a pass cache could save;
- what capacity actually is per hour.

## 8. Phase 3, capacity and demand: decisions, not code

Phase 1 stops refusals in a moving queue. It does not make pushes faster in an overloaded hour, because demand
was above capacity. The levers, each needing Phase 2's rows first:

- **CPU outside the budget** (3.6) is the biggest one, and it is not a gate change.
- **Re-gating an identical tree.** A standalone run followed by the push runs everything twice. A pass record
  keyed on a clean tree could skip the second, but discovery enrols untracked and some ignored files, so the key
  needs design and the saving is unmeasured.
- **The total of 10** is Brad's ruling and is not touched here. At a median 83% CPU, more slots would mostly
  slow every gate; that is a prediction, and testing it needs deliberate load through `ops/cpu-load.ps1`, not
  now.

## 9. Decisions for Brad

1. **Should a pool keep growing while others queue?** (a) Yes, unchanged: smaller change, predicted lower mean
   latency, bounded wait at position 1. **Recommended.** (b) No, `Add-TcGateSlots` yields whenever a ticket
   exists: a one-line change, strictly FIFO, but every push stays at width 1 for about 890 s in an overloaded hour.
2. **A total-wait ceiling on top of the stall rule?** (a) None, position lines only. **Recommended.** (b) Yes, for
   example 60 min, exit 3 "the queue did not reach this push".
3. **Ship the lease ledger with Phase 1?** (a) Yes. **Recommended.** (b) Later.

## 10. Considered and not proposed

- **Deduplicating concurrent identical-tree runs.** 22 of 22 live runs gated distinct trees.
- **A longer fixed timeout.** Still a lottery, and still refuses a moving queue.
- **A central queue daemon.** A new runtime to keep alive, and a dead daemon wedges every push on the box. The
  ticket files need no process.
- **A named semaphore.** Not released when its holder dies (the header of `lib/gate-slots.ps1` has the account).
