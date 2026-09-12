# PLAN - the pre-push gate loses the ref race, and losing it is what keeps the gate slow (2026-09-11)

Status: DIAGNOSED AND MEASURED. Nothing built. Three options were put to me; one of them I recommend
against building, and the reason is worth more than the option. Brad rules.

**Harness and commit.** Every number below was derived by this session from two already-committed
records plus `git log origin/main`, at `1975ea45d` with `origin/main` at `4ac43c532`. The per-run rows
are `design/DATA-gate-slot-starvation-2026-09-11.csv` (138 rows, written by `ops/observe-gate-queue.ps1`
at `46a78c564`); the cost curve is `design/MEASURE-gate-cost-2026-09-09.md`. **`ops/run-gates.ps1` was
NOT run.** The box was at 100% CPU with 7 live gate runs and 138 Claude sessions while this was written,
and the standing instruction is not to add load to a jammed queue. So nothing here claims a gate pass.

## The finding that changes the question

The ref race is not a separate problem sitting downstream of the slot starvation. **It is the largest
single producer of the load that causes the starvation**, and the two sustain each other.

- **Landing rate on `origin/main` today: 61 distinct landings over 14.3 h = 4.3/h, median gap 11.3 min**
  (53 on 09-10, 62 on 09-09, so this is the estate's normal rate, not a spike). Counted as distinct
  committer timestamps, because a rebase stamps every commit it moves with one time, so 84 commits
  today were 61 landings.
- A push must survive its whole gate without any of those landing. At the arrival rate above,
  `P(win) = exp(-4.3 x T/60)`:

  | gate duration T | P(win) | expected gate runs per landing |
  |---|---|---|
  | 1 min | 93% | 1.1 |
  | 5 min | 70% | 1.4 |
  | 15 min | 34% | 2.9 |
  | 25 min | 17% | 5.9 |
  | 31 min | 11% | 9.1 |

  The reported sequence - 5 pushes, 3 full gate runs, 0 landings - sits exactly on this curve.
- **The re-gating is half the machine.** Of the 62 runs in the sampled window that actually consumed
  slots, **35 (56%) were a repeat run from a checkout that had already run the gate**, and those repeats
  are **34,263 of 68,119 seconds (50%) of all evaluated gate wall-time**. There were **41 hook-run
  followed-by-hook-run pairs in one checkout; in 35 of them the first run had already done gate work**,
  median gap from one ending to the next starting **152 s** - a session rebasing and pushing straight
  back in.
- 51 of the 80 repeat pairs carried a **different** content fingerprint, which is what a rebase onto a
  moved `main` looks like. So the existing verdict reuse in `lib/gate-verdict.ps1` cannot absorb them,
  correctly: the content really did change.

**The loop, stated plainly:** a slow gate loses the race; losing the race forces a re-gate; the re-gates
are half the demand; the demand keeps every run at width 1-2; width 1-2 is what makes the gate slow. It
is self-sustaining and it will restart on its own after any quiet period.

**The arithmetic says it is bistable, which is why it has to be broken rather than waited out.** Measured
capacity 41.4 evaluated runs/h. Unique demand 55/h. Uncontended the gate is 516 slot-seconds (78 s wall at
width 16); under load runs cost 870-1543 slot-seconds. So: at 516 s/run, 10 slots serve ~70/h and the
demand fits. At 870 s/run they serve ~41/h and it does not. The system has a fast stable state and a slow
stable state, today's load sits between them, and the race is the thing that pushes it into the slow one.

## The three options, judged

### Option 1 - gate the rebased result, then retry rebase+push without re-gating when only the ref moved

**Recommend against building the half that makes it attractive, and it does not help anyway.**

Two independent reasons.

**It cannot shrink the race window.** The window a push must win *is* the gate duration, wherever the
gate runs. Moving `run-gates` ahead of `git push` and reusing the verdict changes nothing about how long
`main` has to move: 28 minutes of gating is 28 minutes of exposure whether it happens inside the hook or
in a wrapper before it. This is worth stating because it is the intuitive fix and it is a no-op.

**"Only the ref moved and my paths did not change" is not true of this gate.** `run-gates` is not a
per-path test suite. A large part of it is whole-tree ratchets and censuses, and other people's commits
move them: today alone `audit-cross-module-reach` went 133 -> 118, `audit-mustfire-census` 2727 -> 2806,
`audit-write-only-reports` 41 -> 40. A rebase produces a tree that is *their content plus mine*, which no
run has judged, and the class of defect that survives "each half passed separately" is exactly what a
change-time gate exists for. Skipping the re-gate there ships an ungated combination and would be the
`a-could-not-look-must-not-settle-the-question` shape wearing a performance argument.

What is worth keeping from Option 1: the **lease** half. `--force-with-lease` is not it -
`force-with-lease-after-a-fetch-protects-nothing` is already a memory here. The useful lease is Option 3's.

### Option 2 - a bigger slot budget, or a different wait budget

**Recommend against both, and they are already measured.** `design/MEASURE-gate-cost-2026-09-09.md` has
the width curve: 16 -> 24 -> 32 workers moves wall from 78 s to 75 s while gate *work* rises 516 -> 580 ->
657 slot-seconds. More width buys 3 seconds and costs 27%. And `PLAN-gate-queue-2026-09-11.md` Q4 showed
the slots are not what loads the box. Raising `WaitSec` grows the queue rather than draining it, and the
fixed deadline has already been replaced by the "the queue stopped moving" rule.

**But there is one real lever inside this option, and it is cheap.** The pool is being time-sliced into
its worst possible configuration: **18 of 19 grants that day were width 1**, and width 1 is the 372 s
serial number against 78 s at width 16. Ten runs each granted one slot all finish late; two runs granted
five each finish at a fraction of the cost, for identical throughput in slot-seconds. A **minimum grant
width** - `Enter-TcGateSlots` keeps its ticket until it can take K slots, rather than proceeding with 1 -
converts processor-sharing into batch service. It changes no safety property, needs no new mechanism, and
helps every run whether or not anything else here is built. **K is unmeasured**; the curve has points at
1, 16, 24 and 32 only, so K would be picked by a sweep, not asserted.

### Option 3 - serialise landing through one queue

**Recommend, in the smallest form that removes the race by construction: a landing lease.**

Not a merge-queue daemon. A machine-wide mutex that anything about to update `refs/heads/main` holds
across **fetch -> rebase -> gate -> push**. While it is held, `main` cannot move, so the push cannot lose
the race - not "is unlikely to", cannot. That is a correctness property and it does not rest on any
width curve or throughput estimate.

The machinery already exists. `lib/gate-slots.ps1` has arrival-order tickets, mutex-based liveness (a
killed holder's mutex comes back abandoned and the next waiter takes it), and a "the queue stopped moving"
deadline. A landing lease is that pattern with a budget of one.

**It has to be a block, not a habit.** The hook runs after git has already fixed the push's refs, so the
lease must be taken by a wrapper *before* `git push`. A wrapper nobody is forced to use is the
`always-on-delivery-is-not-sufficient` shape - a rule delivered every turn and broken six times. So the
wrapper takes the lease and writes a token naming (pid, ref, sha), and **`ops/hooks/pre-push` refuses a
push that updates `refs/heads/main` without a live lease token covering it**. `ops/test-prepush-hook.ps1`
already drives the hook from a sandbox linked worktree, which is where those cases go.

**What it costs, stated before anyone builds it.**

- **The safety margin is thin at today's demand, and this is the number that decides the design.**
  Serialised, capacity is `1440/T` landings a day. Demand is 53-62. So **T must stay under ~23 minutes or
  the lease is worse than the race it replaces**, and the gate under load today measured 25-31 minutes.
  The lease only pays if the gate inside it is fast - which it should be, because removing the re-gate
  loop removes ~50% of demand and a lease holder is usually the only main-bound gate running. But that is
  the loop running in the good direction, not a measurement. **The lease and Option 2's minimum width are
  therefore not independent; my recommendation is to land the width change first and measure T under it,
  because the lease built alone could make things worse.**
- Everything that pushes to `main` must take it or the race returns: the ~07:00 bot
  (`.github/workflows/daily.yml`, `grocery/run-daily-local.ps1`) and `meal-prep/pipeline/wave-publish.ps1`.
  wave-publish is the money lane - committing `public/board.json` *is* the feed deploy - so it needs a
  place in the queue that a twenty-deep session backlog cannot starve.
- `git push --no-verify` still bypasses everything, deliberately, and a bypassing push can still move
  `main` under a lease holder. That is the existing loud bypass and it stays.
- A frozen-but-alive lease holder wedges every landing on the box. The ticket rule's answer is a loud
  refusal after the queue stops moving, never a pass - plus a hard cap on hold time, which the slot code
  does not currently have because nothing there held anything this consequential.

## What I recommend, in order

1. **Minimum grant width in `lib/gate-slots.ps1`** (Option 2's one real lever). Cheapest, no new
   mechanism, no safety property touched, helps every run today. K chosen by a sweep at widths 1, 2, 5, 10
   on a quiet box, not asserted.
2. **Re-measure T** - the gate's wall time under the post-(1) load - before building anything else. If T
   falls under ~5 minutes, `P(win)` is 70% and the race may not need a mechanism at all.
3. **The landing lease** (Option 3) if T stays high, built as a block in `ops/hooks/pre-push` rather than
   a habit, with the bot and wave-publish enrolled and a hold cap.
4. **Not built: Option 1's re-gate skip**, for the reason in its section.

## Brad's ruling, 2026-09-12

**Sweep width first, re-measure T under whatever that gives, and decide the landing lease after** -
recommendations 1 and 2, in that order, with 3 held until there is a number. And **wait for a quiet box**
rather than measuring under load: a width curve taken at 100% CPU measures the contention.

Option 1's re-gate skip is not built, as recommended.

### The harness, built 2026-09-12

`ops/measure-gate-width.ps1` - `-Probe` (is the box quiet, adds no load), `-Sweep` (the real runs),
`-Report` (totals). The bar is in its source above the run, as `measurement.md` E21 requires, and
`-Report` judges against the same constants the header states rather than a number chosen after seeing
the result.

Three choices in it worth naming, because a first cut would have got each one wrong:

- **Arms are interleaved (1,2,5,10, 1,2,5,10, ...), never blocked.** Load here drifts over tens of
  minutes, so a blocked sweep would confound width with the hour it ran in - the defect
  `grocery/check-ad-cycles.ps1` carries a block headed *"THE MEASUREMENT WAS CONFOUNDED"* about.
- **The width recorded is the width REACHED, not the width asked**, and `-Report` drops a row where they
  differ instead of averaging it in. A lease grants what is free; a run that asked 10 and got 3 ran at 3.
- **It refuses to start unless the box is quiet, and aborts mid-sweep if that stops being true.** Unlike
  `ops/observe-gate-queue.ps1`, this harness DOES add gate load, and its header says so at the top.

**Verified:** parse clean, LF, no BOM; `-Probe` read 11 live runs at 87% and refused; `-Report` driven
over four synthetic sets - bar met (0.30), bar not met (0.81), the drop rule naming both a short-width
row and a non-zero exit, and a set with no width-1 rows exiting **3 with `verdict=unjudged`** rather than
inventing a verdict. **`-Sweep` itself is NOT yet exercised**: it needs the quiet box it insists on, and
the box has been at 100% with 6 to 11 gate runs live all night.

### The box is almost never quiet, and that corrects an earlier conclusion (2026-09-12)

Waiting for the quiet box the ruling asked for produced a measurement nobody had asked for. A probe
every 90 s from **05:58 to 09:24 (134 samples)** found the box quiet - no other `run-gates` and CPU at or
under 60% - in **1 of 134 samples (0.7%)**. Median concurrent gate runs **5**, max **14**. Median CPU
**73%**, and 100% at the peak. The single quiet window arrived at 09:24 and held for at least four
consecutive probes.

`design/MEASURE-gate-queue-window-2026-09-11.md` closes by reading the afternoon's saturation as
**"transient overload against a fixed ceiling"** that "drained on its own by 18:00". The overnight sample
says that reading was too kind: the queue did not drain, it thinned. Five concurrent gate runs at 3 a.m.
on a Saturday is not a transient, and the afternoon's 19-39 is that same state under a working day. **The
harness that found this is `ops/measure-gate-width.ps1 -Probe`, which adds no load**, and the per-sample
rows are kept with the sweep.

This does not change the recommended order, but it does change what the lease is up against: a landing
lane's throughput has to be found under the load the box actually carries, because the quiet condition
this estate has been measuring against is available about seven hours in a thousand.

## What would make me wrong

- If the 4.3/h landing rate is transient rather than this estate's normal rate, the race is not worth a
  mechanism. Three days at 53, 61, 62 says it is normal, but three days is three days.
- The 56%-repeat figure counts *any* second run from a checkout that had already run gates. Some of those
  are legitimate (a real edit between the two, a `gates-baseline`/`gates-after` pair). The 41 hook-to-hook
  pairs with a 152 s median gap are the cleaner signal and they point the same way, but the 50% of
  wall-time is an upper bound on what a race fix could recover, not a prediction.
- Width K is unmeasured, and `MEASURE-gate-cost` has no point below 16. If the curve is flat from 1 to 10
  on a loaded box - which contention makes plausible - recommendation 1 buys nothing and the whole weight
  falls on the lease, whose margin is thin. **That sweep is the first thing to run, and it is cheap.**
