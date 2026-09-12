# A push should cost under a minute, checks included

Brad, 2026-09-12: *"When a session is trying to push code, it should take less than a minute to do checks and push.
The end. It seems we made the system incredibly complicated."*

He is right, and the complexity is the symptom rather than the disease. This plan names the one design decision
everything else was built to work around, and proposes removing it rather than optimising around it again.

**Harness:** `ops/run-gates.ps1` timing lines from real pushes, `lib/gate-input-key.ps1` driven read-only over the
tree by a scratch census, and `git log/show --name-only` over `origin/main`. **Commit it ran at:** the commit that
adds this file. Nothing here was measured by running a gate deliberately; the run figures are from pushes that were
happening anyway.

## The decision that costs the hour

**Every push runs every check.** 391 gates, 778 s of gate work warm and 1,474 s cold, whatever changed.

Everything added in the last two days exists to make that affordable: a 10-slot machine-wide worker budget, an
arrival-order queue for it, a machine-wide push lock, whole-run verdict reuse, per-gate input keys, a
seed-on-first-push step, and a wrapper that orders the lock against the rebase. Each is individually correct. Together
they are a large, subtle, concurrent system whose purpose is to make an unnecessary 778 s tolerable.

**MEASURED, and this is the whole argument.** Over the last 12 commits on `origin/main`, against the 240 gates whose
inputs `lib/gate-input-key.ps1` can already resolve:

| commit | files changed | keyable gates whose inputs actually changed |
|---|---|---|
| 4ae8376f4 | 2 | 1 |
| 6c4a057f4 | 7 | 1 |
| 95738617b | 4 | 6 |
| 4cdc7a9c1 | 18 | 0 |
| b33988f80 | 1 | 0 |
| a9289c164 | 2 | 0 |
| b2460165e | 3 | 240 |
| a6e724f36 | 2 | 0 |
| 81ba9dbf0 | 4 | 240 |
| c3d8ab4c2 | 2 | 1 |
| 71275d638 | 2 | 0 |
| d993225ce | 1 | 1 |

**Ten of twelve commits affect 0 to 6 of 240.** The two reading 240 are correct and are both mine: they edited
`ops/run-gates.ps1` and `lib/gate-input-key.ps1`, the runner, which is part of what every pass means. Mean files per
commit is **4.0**, median 2. So the normal case is that **234 to 240 of 240 gates are provably unaffected and run
anyway.**

## What to build

**Run what the change touches. Sweep everything on a schedule.** This is ordinary affected-target selection, and this
estate already has the two halves it needs: the dependency map (the input key already computes each gate's input set -
inverting it is the whole feature) and a nightly chain to carry the full sweep.

1. **Invert the input map.** `Get-TcGateInputKey` already returns `Files`. Build file -> gates once per run and select
   the gates whose inputs the push actually changed. The per-gate cache then becomes a fallback for the rare wide
   change rather than the main mechanism.
2. **The 53 gates the key cannot resolve are the floor, and the floor is the problem.** 28 build a repo path from a
   variable, 17 read a data directory, 8 are refused only because a file they LOAD is unkeyable -
   `lib/gate-slots.ps1` alone poisons 4. Unresolved means "always run", and those 53 include the most expensive gates
   on the box: `test-prepush-hook` 67 s, `map-preresolve` 40 s, `test-precommit-hook` 39 s, `gate-slots` 34 s,
   `cpu-load` 22 s, `audit-source-control-bytes` 20 s, `push-main` 18 s, `audit-full-path-excludes` 16 s - **256 s in
   eight files.** Selection alone therefore does NOT reach a minute. Each of the 53 gets one of two dispositions,
   written down per file: **declare its inputs** in its own source, or **move to the nightly sweep**.
3. **A TREE-SCANNING AUDIT IS NOT A FILE LIST, and this is the soundness hole to close first.** An audit that walks
   the whole tree is affected by any change to what it walks, and a map keyed on literal filenames under-selects it -
   which would skip a gate whose input really did change. Those audits declare a GLOB, not a list, and a gate that
   declares nothing runs. **The default is to run, never to skip.**
4. **Keep the nightly full sweep as the safety net**, and let it be the thing that catches an under-declared input.
   Selection is an optimisation over a net that still exists, which is what makes it safe to be wrong occasionally.

## Are the 53 even the right checks for a push? (Brad, 2026-09-12)

The question was asked before the disposition work started, which is the right order: making a check faster is wasted
if it should not be in the push path at all.

**THE RUBRIC, written before the list was read.** A check belongs in a PUSH if **(a)** it can fail *because of this
change*, and **(b)** the cost of learning that later exceeds the cost of running it now. A check that can only pass,
given what the change touched, is not cheap - it is pure cost, and it is the thing that teaches `--no-verify`.

**SIX of the 53 test the gate and push machinery itself**, and against (a) they fail the rubric outright for any
change that does not touch that machinery:

| gate | warm time | what it tests |
|---|---|---|
| `ops\test-prepush-hook.ps1` | 67 s | the pre-push hook |
| `ops\test-precommit-hook.ps1` | 39 s | the pre-commit hook |
| `lib\gate-slots.ps1` | 34 s | the gate worker queue |
| `ops\cpu-load.ps1` | 22 s | the load tool sharing those slots |
| `ops\seed-worktree.ps1` | not in the slowest 15 | worktree seeding |
| `lib\gate-input-key.ps1` | not in the slowest 15 | the key itself |

**162 s of measured warm gate work - 21% of the 778 s - goes on testing the machinery that runs the push.** A commit
that edits a recipe cannot break the pre-push hook, so that 67 s can only ever pass. These are NOT low-value gates:
they exist because this machinery once set `core.bare=true` on the shared `.git` and let an ungated push out, and
`.claude/rules/ops-and-gates.md` records that day. The claim is about WHEN they run, not whether. Selection already
answers it: they run when the machinery changes, which is the case where they have ever caught anything, plus nightly.

**A CORRECTION TO THIS PLAN'S OWN FIRST DRAFT, recorded rather than quietly fixed.** The 17 gates labelled
`DATA reader` are labelled that way because **the key cannot PROVE they are hermetic** - their source names a data
directory - and NOT because they were observed reading live data. Their self-tests may be entirely hermetic against
temp fixtures. Reading the refusal reason as a finding about the gate would be the estate's own
`an-agreeing-number-escapes-scrutiny` shape. All 17 were confirmed to RUN on a push (checked against one push's own
output); nothing here establishes that any of them is waste. Each needs reading, which is what the disposition list is.

## What this predicts, stated before building

A typical push (2 to 4 files) selects **single digits** of gates. With the 53 dispositioned, the gate half of a push
lands in **seconds**, and the push itself already takes **2 s** (measured today: `d993225ce..a9289c164`). Under a
minute is then a consequence, not a target to tune toward.

**The acceptance bar, in the metric's own units, written now:** median wall clock for the check-plus-push half of a
push, over 10 consecutive real pushes from this box, **under 60 s**, with the count of gates selected printed beside
it. If selection lands under 60 s but the full sweep then goes red on something a push skipped, the bar is FAILED
however good the number is.

## What can then be deleted, which is the real prize

None of this is proposed as removal today; it is what the change makes removable, and it is the reason to prefer it
over another layer:

- the 10-slot machine-wide budget and its arrival-order queue, once a push needs a handful of gates rather than 391;
- whole-run verdict reuse, subsumed by per-gate selection;
- most of the push lock's reason to exist, since its cost was only ever the gate inside it.

## What is already done, and stands either way

- **The gate runs OUTSIDE the push lock** (today). It ran inside, so the box landed about six pushes an hour whatever
  the session count: measured at 9 pushes queued, oldest 47 minutes, **zero** run-gates processes on a 32-core box.
- **A red gate never enters the push queue**, so a failing push stops blocking every other session.
- **Per-gate input keys** cut warm gate work from 1,474 s to 778 s.
- **The slot budget is Brad's ruling** and is unchanged in this plan. He approved raising it from 10 to 24 today;
  that is worth doing and is orthogonal - it divides wall clock by width, while this plan divides the work itself.

## Risks, stated rather than discovered later

- **Under-selection skips a real check.** Mitigated by declare-or-run defaults, globs for tree scanners, and the
  nightly sweep. This is the risk to design against; everything else here is throughput.
- **A declaration can go stale** when a suite starts reading something new. The nightly sweep is what finds it, and
  the disposition list says which suites carry that exposure.
- **The daily bot and the capture lanes share this box**, so any wall-clock figure taken here is contended. Report
  gate WORK and the width achieved beside every wall figure, per `.claude/rules/measurement.md`.
