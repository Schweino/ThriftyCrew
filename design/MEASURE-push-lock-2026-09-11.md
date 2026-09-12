# Serialising pushes: the measurement, 2026-09-11

The diagnosis, and the acceptance bars this is read against, are `design/PLAN-push-livelock-2026-09-11.md`. Those
bars were written to that file **before** the harness existed and are not restated here in different words. This
document is what the runs said.

**Harness:** `ops/probe-push-throughput.ps1`, driving the real `lib/push-lock.ps1` and real `git` against a real
bare repository in a per-run temp directory. **Commit it ran at:** the commit that adds this file.
**One row per attempt per arm**, so every total below can be re-derived: `design/DATA-push-lock-2026-09-11.jsonl`.

**THE HARNESS MOVED BY ONE LINE AFTER THESE RUNS, and this says so rather than leaving the next reader to find it**
(the rule is `.claude/rules/measurement.md`: a moved harness does not make a verdict wrong, it makes it UNQUALIFIED
until somebody re-reads it, and this estate has paid twice for a harness difference nobody wrote down). The runs
below staged each writer's commit with a sweeping `add`; `ops/audit-git-sweepers.ps1` failed the push for it, so the
committed harness names the one file each writer owns instead. It stages the same single file either way and cannot
move a number: what is measured is which pushes LAND, and the staging line is upstream of every arm equally. Checked
rather than asserted - a 45 s single-arm run on the committed harness landed 12 of 12, w0 included, at 10.95
landings a minute, which is the same behaviour as run 3's locked arm.

**What it measures and what it does not.** ORDERING, and the capacity that ordering frees. The gate is modelled as
W seconds of work sharing a budget, not as a real gate, and the remote is local. It says nothing about what
`run-gates` costs. That is deliberate: the defect is an ordering defect.

## The reported failure, restated in one line

11 consecutive attempts, hook 577 to 1,840 s, `run-gates` green every time, every attempt rejected with
`cannot lock ref 'refs/heads/main'`, while other sessions landed every 15 to 25 minutes.

## Run 1: a harness that decided the answer

Not a result. It is here because a discarded arm that goes unrecorded is how a confounded measurement survives.

Run 1 modelled the gate by QUEUEING for slots from a private `lib/gate-slots.ps1` budget, each writer asking for the
whole budget. Arrival-order ticketing then served the writers one at a time, so **the gates never overlapped** - the
harness had serialised the very thing under test.

| unlocked arm, run 1 | attempts | landings |
|---|---|---|
| w0, the SLOW writer | 11 | **11** |
| w1 | 11 | 0 |
| w2 | 11 | 0 |
| w3 | 10 | 0 |

The livelock is plainly there - three writers landed nothing across 32 attempts - but **which** writer starved was
decided by ticket order, not by transaction length, and the slow writer won every time. So **A1 was NOT MET on a
harness that could not have met it**, and the run was discarded rather than reported. This is the same shape as
`grocery/check-ad-cycles.ps1`'s *"THE MEASUREMENT WAS CONFOUNDED"* block and `design/EVAL-hunter-wall-clock-2026-09-04.md`:
arithmetically true, causally wrong, and only visible by asking what else differed between the arms.

Run 2 computes each gate's width from a counter every writer keeps, so all gates overlap and nothing queues.

## Run 2: 180 s per arm

| | unlocked | locked |
|---|---|---|
| attempts | 51 | 37 |
| landings | 15 | **37** |
| landings per minute | 4.64 | **11.13** |
| gate-seconds thrown away on attempts that did not land | **550** | **0** |
| gate-seconds spent per landing | 48.3 | **4.6** |

Per writer, and this is the whole diagnosis in one table:

| writer | unlocked | locked |
|---|---|---|
| w0, the SLOW writer | landed 0 of 6 - **never landed** | landed 10 of 10, 1.00 attempts/landing |
| w1 | landed 15 of 15 | landed 9 of 9, 1.00 |
| w2 | landed 0 of 15 - **never landed** | landed 9 of 9, 1.00 |
| w3 | landed 0 of 15 - **never landed** | landed 9 of 9, 1.00 |

**A1 was NOT MET on this run either, and for an honest reason worth stating rather than editing away.** The bar as
written asks the slow writer to lose *at least 12 attempts*, and a writer whose gate is 36 s cannot make 12 attempts
inside a 180 s window: **the bar was arithmetically unmeetable at that budget.** That is a defect in the bar, not a
result about the estate - which is exactly why a bar is written down first, and why the fix is to lengthen the run
rather than to lower the bar. Run 3 gives the same writers a window they can make 12 attempts in.

## Run 3: 540 s per arm, the window A1 needs

Same harness, same writers, same work. The only change is the wall budget, which is what A1 needed.

| | unlocked | locked |
|---|---|---|
| attempts | 148 | 100 |
| landings | 44 | **100** |
| landings per minute | 4.72 | **10.65** |
| gate-seconds thrown away on attempts that did not land | **1,606** | **0** |
| gate-seconds spent per landing | 48.4 | **4.5** |
| wall | 559 s | 563 s |

| writer | unlocked | locked |
|---|---|---|
| w0, the SLOW writer | landed **0 of 16** | landed 25 of 25, **1.00** |
| w1 | landed 44 of 44 | landed 25 of 25, **1.00** |
| w2 | landed **0 of 44** | landed 25 of 25, **1.00** |
| w3 | landed **0 of 44** | landed 25 of 25, **1.00** |

**All five acceptance bars MET.**

| bar | reading |
|---|---|
| A1 the defect reproduces: the slow writer lands 0 in >= 12 attempts, unlocked | **MET** - 0 landings in 16 attempts |
| A2 every locked writer lands on its first attempt, over >= 12 landings | **MET** - 100 landings, worst writer 1.00 |
| A3 locked landings/min >= unlocked | **MET** - 10.65 against 4.72 |
| A4 gate-seconds thrown away falls to 0 | **MET** - 0 against 1,606 |
| A5 nothing landed without its gate, in either arm | **MET** - 0 and 0 |

**One thing in the unlocked arm is the harness, not the estate, and is worth naming.** w1 landed 44 of 44 while w2
and w3, whose gates are exactly the same length, landed 0 of 44 each. That is lockstep: four writers released
together stay synchronised, one wins the race every round, and the losers restart together and lose again in the
same order. It sharpens the mechanism - under optimistic CAS the winner is decided by something that is not merit -
but **it should not be read as a claim about which real session wins.** The bar A1 rests on is the SLOW writer, and
that one starves for the reason the plan predicted: its critical section is longer than the interval between
conflicting commits.

## What the numbers say

- **The livelock is real and it is not about gates.** Unlocked, three of four writers landed nothing at all across
  36 attempts, having passed every gate. Locked, every writer landed on its first attempt, every time.
- **Serialising did not cost throughput; it more than doubled it.** 11.13 landings a minute against 4.64. The
  prediction in the plan was only that it would not be *worse*, on the grounds that `refs/heads/main` is already
  serialised. The gain on top of that is capacity: an unlocked arm has four gates sharing the machine and getting a
  quarter of it each, so every one of them is four times slower AND three of the four results are discarded.
- **The waste goes to zero, exactly.** 550 gate-seconds an arm burnt on attempts that could never land, against 0.
  On the real estate that is the 41-of-70 `run-gates` starts that came from a pre-push hook
  (`design/MEASURE-gate-queue-window-2026-09-11.md`), against a measured ceiling of 41.4 evaluated runs an hour.
- **Nothing landed ungated in either arm.** A5 is the bar that keeps the other four honest.

## What this does NOT establish

- Nothing here measures the real gate, the real network, or a real 1,840 s hook. The gate is a sleep against a
  modelled budget.
- The width is sampled when a gate starts and is not re-integrated as other gates come and go, so a gate that begins
  alone keeps its full width. That flatters the UNLOCKED arm, which is the direction that cannot flatter the change.
- Four writers on one box for nine minutes is not a day of this estate. It reproduces the mechanism, not the load.
- **A push that does not take the lock is untouched by any of this**: an older checkout with no
  `ops/hold-push-lock.ps1`, a `--no-verify` bypass, or a push from another machine.

## The limitation the first real deployment proved, stated rather than discovered later

**The lock binds only the checkouts that HAVE it, so its benefit phases in and is not complete on the day it lands.**
`ops/hooks/pre-push` is installed once in the shared `.git` and stands in front of every checkout, but it looks for
`$repo/ops/hold-push-lock.ps1` in the PUSHING checkout - deliberately, because a hook that hard-failed in a checkout
older than itself would refuse every push on the box. Until this change is on main and a checkout has pulled it,
that checkout pushes unlocked exactly as before.

**Measured on the attempt that shipped this file.** `push-main` held the lock, `run-gates` passed 379 of 379, and
the push was rejected anyway: `cannot lock ref 'refs/heads/main': is at 8bc6bf576 but expected 74e0a5ef8`. Nothing
had gone wrong - another checkout on this box, which does not yet carry `hold-push-lock.ps1`, landed while this gate
ran. That is the documented degrade working as designed, and it is also the honest cost of the design: **the change
that makes a push land reliably cannot use itself to land the first time.**

So the numbers in run 2 and run 3 describe a box where every writer takes the lock. On this estate that state is
reached when the last active checkout has pulled, which the ~07:00 bot and ordinary rebases do within a day. Until
then the fix is partial, and a push can still be overtaken by a checkout that has not caught up.

## What shipped, and what did not

Shipped: `lib/push-lock.ps1` (the queue at a budget of one), `ops/hold-push-lock.ps1` (a live process to hold it
across the gate), the `ops/hooks/pre-push` change, and `ops/push-main.ps1` (take the lock BEFORE the fetch, so the
rebase cannot go stale and the push lands first time). Five new cases in `ops/test-prepush-hook.ps1` drive all of it
through REAL pushes, including the two that matter most: a red gate under a held lock still refuses, and a refused
push hands the lock back.

Deliberately not done, carried over from the plan: the gate is not made cheaper, the budget of 10 is untouched, the
`test-auditors` leg is not split per tree (under the lock it is paid once per landing rather than once per attempt,
which was the whole win), and there is no staging ref and no fast-forwarding daemon.

**Still standing.** The pool is not stopped mid-flight when a push becomes doomed after dispatch - named as the
largest remaining waste in `design/MEASURE-gate-slot-starvation-2026-09-11.md`. Under the lock the case mostly stops
arising, because a push holding the lock cannot be overtaken; it is narrowed, not fixed.

## Two defects the fixtures found on the way, both now cased

- **`Get-TcPushPlan` read an empty merge-base as a stale base**, so a branch sharing NO ancestor with the remote
  would have been rebased onto main and pushed. `git merge-base` prints nothing and exits 1 for unrelated histories.
  It is now a refusal with its own case.
- **`git --no-optional-locks` was passed after the subcommand**, where git rejects it - and the rejection had been
  counted as a changed path by a `2>&1` that merged stderr into the porcelain output. Two bugs cancelling: separate
  the streams and a dirty checkout gets pushed. Both are fixed and both have cases.
