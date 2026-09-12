# MEASURE: who gets a freed gate slot (2026-09-11, evening)

**This is a REPLICATION.** The starvation it measures was fixed the same afternoon by `b1aab0424`, whose own
numbers are in `design\MEASURE-gate-slot-starvation-2026-09-11.md` (taken 16:35 to 17:05). This probe ran
21:56 to 22:41 against the estate as it then stood, with a different instrument and without knowledge of that
work, and it agrees. Two independent measurements of the same defect, hours apart, are worth more than one,
and the disagreement to look for is in the qualifications at the end, not in the verdicts.

Status: BAR WRITTEN BEFORE THE RUN. Results are appended below the bar and never edit it.

## The question

Four consecutive `run-gates` runs from one session each waited about 1,205 s for a machine-wide gate
worker slot (`lib\gate-slots.ps1`, 10 slots) and exited 3, "no-gate-worker-slot". A CIM snapshot at the
fourth timeout showed 37 `run-gates.ps1` processes: about 9 active and 28 waiting, most of the waiters
pre-push hooks. So pushes across sessions were refused with no gate failing.

HYPOTHESIS (not proven). `Enter-TcGateSlots` polls with `WaitOne(0)` every 500 ms and keeps no queue.
`ops\run-gates.ps1` hands `Invoke-TcParallel` a `-Grow` that calls `Add-TcGateSlots` every 500 ms while
its lanes are full and gates remain. So a run that already holds slots competes for every freed slot on
the same cadence as a run holding none, and a waiter's age buys it nothing.

Two alternatives must be ruled in or out with the same data:

- **A. Overload.** Runs arrive faster than 10 slots can serve them. Then no admission order can stop the
  timeouts; it only chooses who times out.
- **B. Leaked or stuck holders.** A slot owned by something that is not a live gate run, or by a run
  whose process tree has stopped doing work.

## The harness

**Re-read at commit `30f237b35`:** what this file measures still holds. Its own harness - the probe and the
reporter - is unchanged; what moved is `ops\run-gates.ps1`, which this file names only in the caveat that each
session runs its own checkout's copy. The 2026-09-12 change there keys each self-test on its inputs and does
not run one whose inputs are untouched, so a run DISPATCHES less and holds its slots for less time. That
shortens how long a starved waiter waits; it does not change who wins a freed slot, which is what was measured
here and lives in `lib\gate-slots.ps1`.

**Re-read at commit `683363de8`:** `ops\run-gates.ps1` moved again, twice on 2026-09-12 - six tree-wide ratchets are
now marked `daily` and deferred out of a push, and the loop that judges them skips them too. Neither touches
`lib\gate-slots.ps1`, which is what this document measures: who wins a freed slot. What it DOES change is the
denominator around it - a push dispatches less - and that was already true of the per-gate keys, so the caveat below
about each session running its own checkout's `run-gates` now covers three versions rather than two.

**Re-read at commit `b2460165e`:** `ops\run-gates.ps1` is unchanged since the re-read above; only the hash that
one cites is gone. The branch carrying that change was rebased onto a main other sessions were pushing to, so
`30f237b35` was rewritten as `81ba9dbf0` with identical content. The verdicts below are untouched.

**Harness and commit.** `ops\probe-gate-slot-admission.ps1` (the probe) and `ops\report-gate-slot-admission.ps1`
(the analysis), both introduced by commit fd55e361d and unmoved since, run 2026-09-11 against whatever
`run-gates.ps1` each session's own checkout happened to be running; this session's checkout stood at c6533c7ea.
They are in their own commit for exactly this reason: a document cannot carry the hash of the commit that adds
it, and a measurement whose harness is newer than the commit it cites is UNQUALIFIED by
`ops\audit-conclusion-currency.ps1`, correctly.

**Re-read at commit 740c82af6: every verdict below stands as measured.** That commit changed
`ops\audit-conclusion-currency.ps1` in one respect only - a plain run now states a fall and keeps the committed
mark, `-Tighten` records it, and `-Root` / `-BaselineFile` exist so its self-test can drive the live path against
a temp tree. It altered no probe, no analysis, no slot library and no number in this document. Note why the
re-read was owed at all: the sentence above mentions that script as prose, on a line beside the word this audit
keys on, so the audit counts it among this document's own instruments. That is its stated approximation, not a
finding about this measurement.

A READ-ONLY probe. It never calls `WaitOne` on a slot and never takes one. Once a second it reads the
system handle table (`NtQuerySystemInformation`, extended handle information), duplicates only the
mutant handles held by `run-gates.ps1` and `cpu-load.ps1` processes, reads each one's name and
`NtQueryMutant` state, and so knows exactly which process owns each of the 10 `Global\tc-gate-worker-slot-N`
mutexes. A holder keeps its handle for the whole lease; a waiter's probe handle lives for microseconds,
so a persistent handle on an owned mutex is ownership. Every 30th sample scans every `powershell.exe`,
to catch an owner that is not a gate run (alternative B).

**This is a different instrument from the one `b1aab0424` used.** That measurement read the process table and
timed 8 waiter processes against a private slot, which shows the ORDER waiters are served in. This one reads
ownership out of the kernel, which shows WHO took each freed slot and what they already held. Neither can see
what the other sees: an order probe cannot tell a growing run from a newly admitted one, and this one cannot
manufacture a controlled arrival order.

It writes ONE ROW PER EVENT (JSONL): `run_seen`, `wait_start`, `acquire` (with `ADMIT` or `GROW`),
`release`, `run_exit` (with the process's real exit code), `stuck_holder`, `foreign_holder`, and a
`tick` every 10 s. Every total below is derived from that file.

Definitions, fixed now:

- **acquire** - a slot's owner changed to process P between two samples.
  **ADMIT** if P owned 0 slots in the previous sample, **GROW** if it owned 1 or more.
- **waiter** - a `run-gates.ps1` process owning 0 slots whose discovery has finished. Discovery is
  CPU-bound and waiting is not, so a run is waiting from the first 10 s window, after it has used at
  least 2 CPU-s, in which it gained under 0.3 CPU-s. Runs already alive when the probe starts are
  marked CENSORED, and their waits are reported as a lower bound.
- **service** - a run that released its last slot.
- **arrival** - a run that started waiting, or was admitted without ever registering as a waiter.

Caveat stated in advance: every session runs the `run-gates.ps1` of its own checkout, so the measured
population is a mix of versions. A checkout older than `d72b4f5cd` never grows. The probe reports the
number of distinct runs that were ever seen to GROW.

## The acceptance bar

Window: at least 30 minutes, stopped at 45, with the number of live runs printed per tick.

| Claim | Metric | CONFIRMED | REFUTED | Otherwise |
|---|---|---|---|---|
| H1 grows compete with waiters | share of acquires made while at least 1 waiter was registered that were GROW | at least 20%, over n of at least 20 | under 5%, over n of at least 20 | UNQUALIFIED |
| H2 age buys nothing | share of admissions with at least 3 waiters registered in which the admitted run was the OLDEST waiter (FIFO reads 100%) | at most 50%, over n of at least 10 | at least 90%, over n of at least 10 | UNQUALIFIED |
| A overload | arrivals against services over the window | arrivals at least 1.2 x services, with at least 10 services | arrivals under services | UNQUALIFIED |
| B leaked or stuck | a slot owned by a non-gate process, or a holder whose tree made no progress for 5 min (no new descendant and under 1 CPU-s gained) | 1 or more, named | 0 over the window | - |

Also reported, not barred: per-run wait (first slot minus wait start, and minus process creation),
the number of runs that exited without ever holding a slot and their exit codes, per-run slot-held
time, and the projected FIFO wait (mean queue length / service rate).

**Decision rule, fixed now.** A fair admission is built if H1 or H2 is CONFIRMED. If A is also
CONFIRMED, the plan must say plainly that fairness changes WHO times out and not HOW MANY, and the
capacity question goes to Brad, because the budget of 10 is his ruling.

## Results

Window **21:56:18Z to 22:41:19Z, 45.0 minutes**, 268 ticks. Live run-gates per tick: mean 16.1, min 11, max 23.
Registered waiters per tick: mean 8.4, max 14. **Slots owned: 10.0 of 10 on average - the budget was full for
the entire window**, so nothing below is about idle capacity. 54 slot acquisitions after the first sample.

| Claim | Metric | Verdict |
|---|---|---|
| H1 grows compete with waiters | **25 of 54 acquisitions (46%)** with a registered waiter present went to a GROW | **CONFIRMED** (bar: 20% or more over n of 20+) |
| H2 age buys nothing | the admitted run was the oldest waiter in **5 of 27 (19%)** by wait start, **3 of 27 (11%)** by process creation. FIFO reads 100% | **CONFIRMED** (bar: 50% or under over n of 10+) |
| A overload | 36 arrivals against 31 services over 45.0 min = **0.80/min in, 0.69/min out**; projected first-come wait 12.2 min against the 20 min limit | **UNQUALIFIED** - between the bars, neither 1.2x arrivals nor fewer than services |
| B leaked or stuck | 0 stuck holders; 0 non-run-gates holders in this window's full scans | **REFUTED** - every slot was held by a live gate run doing work |

What the H1 rows show beyond the share: the waiter that lost the slot had often been waiting a long time. The
oldest waiter at the moment a growing run took a freed slot was over 10 minutes in 13 of the 25 grows, and over
**19 minutes in 4 of them** - runs minutes from refusing their push, losing the slot to a run that already had one.

The cost, in the same window: **47 real run-gates processes exited; 16 of them (34%) exited 3 after about
1,205 s having never held a slot**, which is 16 pushes refused with no gate failing. 25 exited 0 and 6 exited 1.
Of the 28 runs admitted, the wait was **median 309 s, p90 813 s, longest 1,180 s** (3 censored, counted as lower
bounds). Runs held slots for a median of 558 s, at peak width 1 (11 runs), 2 (17) and 3 (3).

Qualifications, stated rather than assumed:

- **Mixed versions.** 21 runs were seen to GROW, so at least that many were running a checkout at or after
  `d72b4f5cd`. The population is whatever the other sessions happened to be running.
- **Sampling.** Ownership is read once a second; a slot released and retaken within one second is seen only as
  its end state. Production tenures here were minutes, not seconds.
- **"Waiting" is inferred** from a flat CPU window after discovery, and 3 admitted runs were already alive when
  the probe started, so their waits are lower bounds.
- **201 of 248 run-gates processes were excluded** as fixture stand-ins: they lived under 30 s, never reached
  discovery, and exited 0. Counting them would have buried the 16 starved runs in exit-0 noise.
- A is the one to re-read later. Arrivals and services were close, so the honest reading is that the machine sat
  NEAR its capacity for the whole window: a line makes the wait orderly and bounded by position, and cannot make
  it shorter.

## What this agrees with, and what it adds

`b1aab0424` shipped the fix at 17:41, hours before this window: tickets named by arrival time whose liveness is
a held mutex, slots to the oldest live ticket, a top-up that takes nothing while anyone is queued, and exact
load that never queues and never jumps. Its own probe measured the ORDER (the first of 8 arrivals served 6th,
8th and 5th); this one measured WHO (46% of freed slots to a run that already held one). The two are different
halves of the same defect and neither contradicts the other.

What this window adds to the record:

- **The grow share, with denominators**, which an order probe cannot see: 25 of 54, and the age of the waiter
  that lost each one.
- **A per-run exit census** over 45 minutes: 16 of 47 real runs refused a push after the full wait.
- **The two gates `b1aab0424` left undiagnosed.** Its commit names `wave-preaudit` and
  `feed-covers-published` as red in 6 of 9 kept failure logs and not diagnosed. They are **worktree
  blindness, not a defect in either gate**: `/meal-prep/db/built/` is gitignored (`.gitignore:336`), an
  unseeded worktree has 0 files there against 1,168 in the main checkout, and both gates need a real built
  card. `powershell -File ops\seed-worktree.ps1 -Target <worktree>` seeds them and both pass. The failure
  text names a missing file rather than a missing SEED, which is what makes it read as a code fault.

## Two properties the shipped design does not have, offered as candidates only

Both are deliberate choices there, not oversights, and neither is proposed here without its own measurement.

- **The head takes its whole want.** With a queue behind it, the oldest ticket may take every free slot. Taking
  ONE and leaving the rest would spread the budget across queued runs, and the estate's own gate-cost
  measurement argues that is cheaper in slot-seconds per run (370 s of work serially against 580 s at width 16,
  `design\MEASURE-gate-cost-2026-09-09.md`), so more runs complete per minute. It also makes each individual run
  slower, which is the trade-off, and nothing here measures it.
- **A frozen head wedges the queue into a refusal.** `b1aab0424` says so plainly and treats it as correct: a
  live-but-frozen ticket holder is not swept, and runs behind it exit 3 once the count ahead stops falling. The
  alternative is to pass over a ticket nobody has touched for some time and keep the line moving, which trades a
  loud refusal for continued throughput. Which is right depends on whether a frozen waiter is a bug worth
  stopping for; that is a ruling, not a measurement.
