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

## THE NET DOES NOT EXIST YET, so the order inverts (measured 2026-09-12, before any selection was built)

This plan's safety rests on a nightly full sweep catching what a selected push skips. **It was checked rather than
assumed, and it is not there.**

```
total scheduled tasks on this box:        193
tasks that run ops\run-gates.ps1:           0
"TC Daemon Battery 0230" registered:        no
```

**`ops\hooks\pre-push` is the ONLY thing on this box that ever runs the full gate set.** Nothing else, on any schedule,
ever has. So selection built today would not be an optimisation over a net - it would remove coverage outright, which
is the one thing `CLAUDE.md`'s standing rules forbid, and the whole-tree guarantee would simply end.

The claim that misled the first draft of this plan was this file's own reading of *"data-dependent audits stay in the
daily chain"*. They do. **The daily chain is not a gate sweep**, and the two were conflated here. This is exactly the
trap `.claude/rules/ops-and-gates.md` already records in its own words - *"A definition is not a registration: check
`Get-ScheduledTask` before saying it runs"* - written about this very battery, and it caught this plan.

**THE ORDER, therefore, and step 0 is not optional:**

0. **Build and REGISTER the nightly full sweep, and prove it runs.** A scheduled `run-gates` over a fresh checkout of
   `main`, its verdict reaching Brad the way the morning digest already does. Not "defined" - registered, with
   `Get-ScheduledTask` showing it and at least one green run on the clock.
1. Only then may a push stop running anything. Until step 0 is observed green, every gate stays where it is.

The acceptance bar for step 0, in its own units: `Get-ScheduledTask` names it, one completed run exists with a read
exit code, and a deliberately reddened tree is seen to produce a verdict that REACHES someone. A sweep nobody reads is
not a net, and a sweep that fails silently is worse than none, because this plan would then be trusting it.

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

## The disposition of all 53, read rather than guessed (2026-09-12)

Brad ruled the principle first: **a green push proves that everything the change could plausibly break is green**, and the
whole-tree guarantee moves to a nightly sweep. Each of the 53 was then read against the rubric above.

**THE HEURISTIC WAS WRONG ABOUT THE 17, AND THIS IS THE CORRECTION THAT MATTERS.** They were flagged `reads a data
directory` because their SOURCE TEXT names one. Read: **15 of 17 are hermetic**, every one of them because the live
data reads sit AFTER the `-SelfTest` exit. Exactly one is blind in a worktree and only for **1 of its 28 cases**
(`feed-covers-published`, which already reports it as `blind=` and does not fail the push). **Twelve of the 17 are pure
in-memory cases costing close to nothing and STAY at push.** A refusal reason is a fact about the key, never about the
gate, and reading it as the latter is this estate's `an-agreeing-number-escapes-scrutiny` shape.

**THE STRUCTURAL KEY, and what makes this safe.** `ops/run-gates.ps1` runs TWO things: a discovery pass over every
`-SelfTest` in the tree, and an explicit `$static` list that runs certain audits **live**. Seven files appear in both.
**Removing a self-test from the push does NOT remove the live audit.** So every tree-wide protection stays untouched
while its fixture suite stops running on every push.

**STAYS AT PUSH - the tree-wide live halves, which any commit can redden:**
`audit-source-control-bytes` (ReadAllBytes over every tracked source file; one heredoc-written path anywhere plants a
control byte and the affected script's own self-test stays green), `audit-full-path-excludes` (AST over every `.ps1`
and `.py`, ratcheted), `audit-task-registration` (every `.ps1` walked for `Register-ScheduledTask`),
`test-native-stderr-eap` (AST ratchet whose whole value is catching the new site in THIS diff), `audit-alert-registry`'s
argument-less run, `audit-phantom-paths`, `audit-memory-citations`, `audit-stray-root-artifacts`, and
`prepush-test-auditors`' self-test - that last one because it DERIVES which test-auditors units a push runs, so a silent
degradation there ships a green push over an unrun guard, which is the 2026-09-10 failure it was built for.
Plus the twelve cheap pure suites among the 17.

**MOVES TO ON-CHANGE - the measured money, with its trigger set:**

| gate | measured warm | trigger |
|---|---|---|
| `ops\test-prepush-hook.ps1` | 67 s | `ops\hooks\pre-push`, `ops\prepush-test-auditors.ps1`, `ops\hold-push-lock.ps1`, **`lib\**`** |
| `meal-prep\pipeline\map-preresolve.ps1` | 40 s | `meal-prep\pipeline\*`, `lib\json-io.ps1`, `grocery\native-lib.ps1` |
| `ops\test-precommit-hook.ps1` | 39 s | the 9 files it already names in `$needed` |
| `lib\gate-slots.ps1` | 34 s | itself only |
| `ops\cpu-load.ps1` | 22 s | itself, `lib\gate-slots.ps1` |

with `hunt-run` (~1,100 fixture lines, many temp trees), `audit-event-bus`'s 800-event four-process drill,
`audit-ghost-drift` (a child process plus a `git status` per tool file), `audit-capture-encoding` (four child
processes), `test-pull-agent-lib` (node spawned six-plus times), `build-aldi-regular`, `import-walmart-batch`,
`import-instacart-batch`, `validate-triage-plan`, `rebid-ingredient`, `verify-commodities-gate`, `brain-digest`,
`pipeline-commit`, `consistency-oracle`, `test-guards`, `test-scaler-labels`, and the remaining machinery suites
joining them. **The measured five alone are 202 s of the 778 s.**

**`ops\test-prepush-hook.ps1` CAN NEVER BE CACHED, and that corrects a claim made earlier today.** It copies
`lib\*.ps1` by DIRECTORY ENUMERATION, and a source key cannot name a listing. Its trigger must be the whole of `lib\`.
Selection handles it; the per-gate cache never could.

**A CLAIM THIS PLAN MADE AND THEN DISPROVED, left standing here because the retraction is the useful part.** This file
asserted that `ops\audit-cpu-load.ps1` was "not doing its job" - that only its hermetic `-SelfTest` reached the push
path and its live tree scan did not. **That is FALSE.** It is registered in `ops\run-gates.ps1`'s `$static` list (line
209), so a push runs it BOTH ways, and one real push's own output carries both lines:

```
ok    ops\audit-cpu-load.ps1
ok    ops\audit-cpu-load.ps1  (every committed script that starts CPU burners takes its cores ...)
AUDIT-CPU-LOAD-COMPLETE findings=0 starters=1 scanned=725
```

**How it got written down: it came from a review that read the discovery path and missed the static registration, and
it was relayed into this plan and into a commit message WITHOUT being checked against a run.** Every other number in
this document was verified against a command before it was written; this one was not, because it arrived already
phrased as a finding. **A delegated finding is an input, not a result** - it earns the same check as a number this
plan computed itself, and the `$static` list is one grep away. The same shape as
`an-agreeing-number-escapes-scrutiny`, arriving from a colleague rather than from a tool.

The disposition table above is unaffected: `audit-cpu-load`'s `-SelfTest` still moves to ON-CHANGE, and its `$static`
live entry still stays at PUSH, which is exactly what the two-lists rule says.

**THE DISCIPLINE ALREADY EXISTS HERE.** `grocery\test-auditors.ps1` is not run whole: `ops\prepush-test-auditors.ps1`
derives its touched-input set and runs only the reachable units. What this plan proposes is extending a mechanism this
estate already trusts in production, not inventing one.

## The guarantee that makes this safe, VERIFIED rather than assumed (2026-09-12)

Everything above rests on one property, so it was read out of the source rather than believed:

**`ops/run-gates.ps1`'s cache loop iterates `$selfJobs` ONLY, never `$staticJobs`.** The per-gate key, the cache hit
and the skip all live inside `for ($i = 0; $i -lt $selfJobs.Count; $i++)`. The `$static` list - the LIVE tree-wide
audits - is dispatched unconditionally and is never consulted against a key.

So `audit-source-control-bytes` (ReadAllBytes over every tracked source file), `audit-full-path-excludes` (AST over
every `.ps1` and `.py`), `audit-task-registration` and `test-native-stderr-eap` **run on every push and no declaration
can skip them.** Declaring inputs on such a file skips only its FIXTURE suite, which the discovery pass runs under
`-SelfTest` as a separate entry with a separate key. The two halves of those files were never the same job.

That is what lets a push stop running things without the whole-tree ratchets going quiet: **the checks any commit can
redden were already on a list that selection cannot reach.**

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
