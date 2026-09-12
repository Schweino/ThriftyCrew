# A verified push that never lands: diagnosis, acceptance bar, and the fix

Written 2026-09-11, BEFORE anything was measured or built. The acceptance bar in section 3 is stated in
its own units here so that it is a threshold and not a description of a decision already taken
(`.claude/rules/measurement.md`, backlog E21).

## 1. The report

One session, 11 consecutive push attempts. The hook took 577 to 1,840 s each time: `run-gates` passed
every one of them (341 to 368 gates), plus a 127 to 411 s `prepush-test-auditors` leg. **Every attempt
was rejected by the remote with `cannot lock ref 'refs/heads/main' ... is at X but expected Y`, with the
gate green each time.** Other sessions landed on main every 15 to 25 minutes throughout. A twelfth
attempt was refused with `run-gates` exit 3 after waiting 1,200 s for a gate worker slot.

## 2. Diagnosis

### 2.1 What is already fixed, and why none of it can fix this

Three changes landed on 2026-09-11 (`design/MEASURE-gate-slot-starvation-2026-09-11.md`):

| Change | What it removes |
|---|---|
| `lib/gate-slots.ps1` arrival-order tickets | a waiter losing races indefinitely for a SLOT |
| `lib/gate-verdict.ps1` verdict reuse | gating one checkout's identical content twice |
| `lib/push-landable.ps1` doomed-push refusal | queueing and gating a push the remote will already reject |

Every one of them is about **waste**. Not one of them is about the **race**, and the reported failure is
green gates losing a race. `push-landable` is the closest, and it is read only twice: as the `-Abandon`
predicate while waiting for a gate worker slot, and once more after a wait of 30 s or longer
(`ops/run-gates.ps1:538-556`). After the pool is entered, **nothing looks at the remote again for the
whole 577 to 1,840 s the hook runs.**

### 2.2 The actual mechanism

`git` fixes a push's refs when it connects. The remote updates `refs/heads/main` only if it still holds
the sha the hook was handed. So a push is a **compare-and-swap whose critical section is the entire
hook**. Nothing anywhere prevents main from moving inside that window.

That is optimistic concurrency control with no contention management, and the failure it produces has a
name: **livelock, and specifically the starvation of the longest transaction.** The property is
arithmetic, not luck:

- Time at risk per attempt = hook duration, 577 to 1,840 s.
- Mean time between landings by others = 900 to 1,500 s.

A transaction whose critical section is longer than the interval between conflicting commits **converges
on never committing**, and it gets worse for the slowest attempt, because every retry restarts the clock.
Worse still, the retry is not free: the session must rebase, the rebase changes the checkout's content,
and `gate-verdict`'s fingerprint is over content - so **the recorded pass correctly does not apply, and
all 341 to 368 gates run again from scratch.** The reuse is working as designed; a rebase is genuinely
new content. That is why 11 attempts cost 11 full hooks.

### 2.3 The consequence for everybody else

41 of 70 `run-gates` starts in the measured hour came from a pre-push hook, against a measured ceiling of
41.4 evaluated runs an hour. Losing pushes are therefore not only wasting their own time: **they are the
largest single consumer of the machine-wide pool they then get refused by.** The 12th attempt's exit 3
is downstream of the first 11.

### 2.4 The one-line statement

> Nothing stops `refs/heads/main` moving between the moment a push's base is fixed and the moment its ref
> updates, and that window is the whole gate. Green gates are irrelevant to who wins it.

## 3. THE ACCEPTANCE BAR, written before the run

**Harness:** `ops/probe-push-throughput.ps1`, driving the real `lib/push-lock.ps1` and real `git` against
a real bare repository in a per-run temp directory. The gate is simulated by a sleep of a stated length,
because what is under test is the ordering of the critical section and not the cost of a gate. Both arms
run the same writers, the same gate lengths and the same wall-clock budget. One row per attempt per arm
(backlog E24), so every total below can be re-derived and none of them is a pair of aggregates.

**Writers:** 4 concurrent, one of them the SLOW writer with a gate 3x the others - the reported session's
shape, and the one optimistic CAS starves.

| # | Bar | Unit | Arm that must meet it |
|---|---|---|---|
| A1 | The slow writer lands **0** times in **at least 12** attempts | landings | `nolock` (the defect must reproduce, or the fix is unqualified) |
| A2 | **Every** writer's attempts-per-landing is exactly **1.00**, slow writer included, over at least 12 landings | attempts / landing | `lock` |
| A3 | Landings per minute in `lock` is **>=** landings per minute in `nolock` | landings / min | `lock` vs `nolock` |
| A4 | Gate-seconds spent on attempts that did not land falls to **0** | gate-seconds | `lock` (must be > 0 in `nolock`) |
| A5 | No push lands without its gate having run, in either arm | count | both |

**A1 is the must-fire for the whole exercise.** If the `nolock` arm does not starve the slow writer, the
model in section 2.2 is wrong and the fix is not justified by this measurement.

**What a pass does NOT establish.** The probe simulates a gate with a sleep and runs against a local bare
repository, so it measures ORDERING, never gate cost and never network behaviour. It says nothing about
what the real hook costs. That is deliberate: the defect is an ordering defect.

## 4. The fix

**Replace optimistic concurrency control with a serialised critical section.** One machine-wide push lock,
taken by the pre-push hook before the gate and held until the ref update completes.

### 4.1 Why serialising costs no throughput

This is the objection to answer first, and the answer is arithmetic. `refs/heads/main` is **already**
serialised - it is a single ref and exactly one push can land at a time. Today's parallelism is not
parallel landing; it is parallel gating of which all but one result is discarded. So:

- Today: N sessions each pay T, and N-1 of those T are thrown away. Landings per hour = 1 / T.
- Locked: one session pays T and lands. N-1 wait, paying nothing. Landings per hour = 1 / T.

The aggregate landing rate is unchanged by construction, and every discarded T is returned to the machine.
Measured landings today are one every 15 to 25 minutes, against a hook of 10 to 30 minutes, which is the
same number: **the estate is already running at the serial ceiling and paying 4x for it.** A3 is the bar
that holds this claim to account; if it fails, this argument is wrong.

### 4.2 The pieces

1. **`lib/push-lock.ps1`** - one machine-wide FIFO lock, ticketed in arrival order, exactly the mechanism
   `lib/gate-slots.ps1` already uses. A ticket's liveness is its MUTEX and never its file, so a killed
   holder is swept and a frozen one wedges the queue loudly instead of being waited on forever.
2. **`ops/hooks/pre-push`** takes the lock before the gate and releases it on every exit path.
3. **`ops/push-main.ps1`** - the wrapper that makes the guarantee real: take the lock FIRST, then fetch,
   then rebase onto what the remote holds now, then push (the hook inherits the held lock rather than
   deadlocking on it). Under the lock nobody else can land, so the rebase cannot go stale and the push
   lands on its first attempt.

### 4.3 The three rules this fix must not break, and how each is kept

| Rule | How |
|---|---|
| `run-gates` is hermetic | the lock is outside it; `run-gates` is not edited by this change |
| The hook must refuse when it cannot evaluate; exit 3 is never a pass | unchanged - the lock decides nothing about the tree |
| `ops/audit-hook-installed.ps1` asserts the hook is live | `ops/install-hooks.ps1` is run in the same change |

### 4.4 The failure mode is deliberately TODAY'S BEHAVIOUR, never a new refusal

This hook lives in the SHARED `.git` and stands in front of every checkout on this box, most of them
older than this change. So every lock path degrades rather than blocks:

- No `lib/push-lock.ps1` in the pushing checkout (an older worktree): the hook runs exactly as it does now.
- The lock queue wedges - not moving for `WaitSec`: the hook says so loudly and **proceeds unlocked**.
- Anything throws inside the lock: the hook proceeds unlocked.

**The push lock is a fairness and throughput device. It is NEVER what makes a push safe - the gate is.**
That is why a bypassed or inherited lock is not a hole in anything, and why its worst case is the
behaviour measured in section 1 rather than a push nobody can make.

## 5. What is deliberately not done

- **The gate is not made cheaper and the budget of 10 is untouched.** Both are Brad's ruling
  (`docs/CONTROL-CONSTANTS.md`), and neither is the defect diagnosed here.
- **The `test-auditors` leg is not split out per tree.** Under the lock the retry loop is gone, so the
  127 to 411 s is paid once per landing rather than once per attempt, which is the whole of the win that
  splitting it would have bought.
- **No staging ref and no fast-forwarding job.** That needs a daemon to be correct, and the lock reaches
  the same guarantee with no new always-on process.
- **The pool is still not stopped mid-flight**, which the prior measurement named as the largest waste.
  Under the lock a push is no longer invalidated after dispatch, so the case mostly stops arising; it is
  not fixed.
