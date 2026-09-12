# PLAN - fold the three unmerged gate-slot branches into the landed one (2026-09-12)

**Status when this was written.** Four sessions fixed the gate-slot starvation on 2026-09-11. One landed:
`b1aab0424`, now on `origin/main`. A sibling session has since landed a fourth branch's measurement too -
`claude/gate-slot-line` was rewritten to `30065916c` and is an ancestor of `origin/main`, with its old tip kept
as `keep/gate-slot-line-superseded`. So main ALREADY carries the observability scripts and two of the four
measurements. This plan covers only what is still outside it.

## What main already has, verified rather than assumed

| Thing | On main | From |
|---|---|---|
| `lib/gate-slots.ps1` ticket queue, arrival order, mutex liveness, stall deadline | yes | b1aab0424 |
| `lib/gate-verdict.ps1` (verdict reuse) | yes | b1aab0424 |
| `lib/push-landable.ps1`, `lib/push-lock.ps1`, `ops/hold-push-lock.ps1` | yes | b1aab0424 |
| `ops/probe-gate-slot-admission.ps1`, `ops/report-gate-slot-admission.ps1` | yes | gate-slot-line, landed by a sibling |
| `ops/observe-gate-queue.ps1` | yes | gate-slot-starvation, landed by a sibling |
| `design/MEASURE-gate-slot-admission-2026-09-11.md` | yes | gate-slot-line |
| `design/MEASURE-gate-slot-starvation-2026-09-11.md` | yes | b1aab0424 (the name collides with the starvation branch's own doc) |
| `lib/gate-pass-reuse.ps1` (the SECOND reuse library) | **no** | gate-slot-starvation - must stay off |
| The `[CmdletBinding()]` hook-compatibility problem | solved | `ops/hooks/pre-push:217-221` greps the gate for `PushRefsFile` before passing it |

## What is still missing, and the evidence for each

### 1. A real defect: an unwritable queue root REFUSES instead of degrading

`New-TcGateTicket` calls `[IO.Directory]::CreateDirectory` and `[IO.File]::WriteAllText` with no guard, and
`Enter-TcGateSlots` does not catch. Driven directly on this branch with a FILE sitting where the queue root
would go:

```
B unwritable-queue-root: throw='MethodInvocationException: Exception calling "CreateDirectory" with "1"
argument(s): "Cannot create "...\qdirfile-58abaef0" because a file or directory with the same name already
exists."'
```

It throws OUT of `Enter-TcGateSlots`, into `ops/run-gates.ps1`, which is `$ErrorActionPreference = 'Stop'`.
That is a could-not-evaluate for every push on the box from one stray file, and it breaks the estate's
standing rule that **every lock path degrades to the behaviour of the day before, never to a refusal** - the
rule `ops/hooks/pre-push` already follows for the push lock. `claude/gate-slot-fifo` found this and fixed it;
main did not. **Fix: a ticket that cannot be written leaves the run waiting out of turn, gated exactly as
before, and says why.**

### 2. Fixture cases main lacks, each asserting a property main's code already claims

Folded from the rivals, restricted to properties MAIN's mechanism actually has:

- **MUST NOT FIRE** a run that never waits takes no ticket and creates no queue directory (verified: the
  fast path `break`s before `New-TcGateTicket`; probe read `queueDirExists=False`).
- **MUST NOT FIRE** a queue directory that cannot be created does not refuse the push - #1's twin.
- **MUST NOT FIRE** a waiting `-Exact` load takes no ticket, so it can never hold back a gate run. Main
  asserts only the other direction (load does not jump the queue).
- **CLEAN TWIN** a killed waiter whose ticket mutex is held OPEN by another process comes back ABANDONED
  rather than vanishing, and still does not hold the queue. Main's header names this exact effect as the one
  that hides bugs from a one-process fixture, and then asserts only the vanish path.
- **CLEAN TWIN** a waiter does not sweep its OWN ticket. The header claims "a probe never touches the ticket
  of the thread probing"; nothing asserts it, and a self-probe would delete its own ticket and lose its turn.
- **CLEAN TWIN** no ticket is left behind - not by a run that timed out in the queue, nor by one admitted
  after waiting. Main asserts this only for the abandon path.
- An **expected case count**, asserted not just printed. The fifo run printed PASS with one case never
  reached, because a fixture variable `$pS` IS `$PS` and overwrote the powershell.exe path. Main's suite uses
  `$PS` for exactly that, so the trap is live here.

NOT folded, on purpose: the fifo/line **ticket-heartbeat** cases (a live-but-frozen waiter aged out of the
line) and the line branch's **head-takes-one** rule. Both are different queue DESIGNS, not missing cases -
main's header states the frozen-waiter behaviour as a deliberate choice ("everyone behind it stops moving and
refuses after WaitSec, loudly, which is the wedge reading and never a pass"). Re-landing them would be a
second queue implementation, which this consolidation is explicitly not for.

### 3. Measurement main does not carry

`design/MEASURE-gate-queue-2026-09-11.md` (fifo) is the strongest live sampling of the four and carries two
things main's two documents do not:

- **The capacity bound.** A slot at width 1 is running a gate 99 to 100% of the time it is held, so the box
  does about 41 run-gates an hour and **a queue longer than about 14 cannot clear inside a 20-minute wait
  whatever the order**. This QUALIFIES the queue fix: order decides which pushes are refused, not how many.
- **The reuse measurement, and what it does and does not measure.** Over 2026-09-11 the shared repo's
  `origin/*` reflogs record 42 push updates carrying 39 distinct trees; the 3 trees pushed twice were each
  one `git push` updating two refs, so one hook run. On that key, reuse saves **0 runs**, and fifo rejected it.
  **That is not a verdict on `lib/gate-verdict.ps1`**, which main landed: it is keyed on a hand `run-gates`
  followed by a push in the SAME checkout, not on the same tree pushed twice. Recording the 0 without that
  sentence would be the `identity-graph-commodity-is-namespaced` shape - an agreeing number about something
  else. fifo's own caveat ("a tree hash does not even name what was gated", because run-gates reads untracked
  and ignored scripts) is the reason main's fingerprint hashes raw script bytes rather than a tree hash.

Kept by copying the document in under a name that does not collide, with a header saying which parts were
superseded by what landed.

`design/PLAN-gate-slot-fair-admission-2026-09-11.md` (line) is a plan for the head-takes-one design that was
NOT taken. Kept as the rejected alternative, not as live work.

### 4. Housekeeping

- `ops/observe-gate-queue.ps1` is on main and NOT in `grocery/audit-script-census.ps1`. A script with no
  census entry is what `audit-script-census` exists to name. Give it one.
- One story in `.claude/rules/ops-and-gates.md`, extending the existing arrival-order bullet rather than
  adding a second: the capacity bound, the degrade-never-refuse rule for the queue directory, and the two
  fixture lessons (a case count for a literal list; one case asserting two checks at once tests neither).
- Delete the three superseded branches after the fold, local and remote.

## Out of scope, deliberately

`claude/gate-slot-starvation` also carries four commits of unrelated triage work - Family Fare fencing, a
batch 2 board and feed, `grocery/commodities.json`, `public/board.json`. That is money-lane work with its own
gates and its own review; it is not gate-slot consolidation and this plan does not touch it. Flagged to Brad
as still unlanded.

## What it actually found, once built

Three things turned up that were not in the plan above, and two of them are defects the fold would have missed
if it had only copied cases across:

1. **`ops/observe-gate-queue.ps1` was on main WITHOUT ITS DEPENDENCY.** It dot-sources
   `lib/gate-pass-reuse.ps1`, the second reuse library, which is not in the tree and must not be. The file runs
   under `Continue`, so the missing dot-source prints "is not recognized" and carries on, and the script then
   dies at its first content key. So "keep the observability scripts" turned out to mean "one of them does not
   run at all". **The fix is written and verified and is NOT in this change** - see the section below.
2. **The admission guard's first fixture could not reach it.** With the queue ROOT a file the directory never
   exists, `Get-TcGateQueueAhead` answers 0, and the run would have been admitted with or without the guard. The
   case that exercises it needs a queue directory this run can READ, holding a live ticket, that it cannot WRITE
   into - a deny-write ACL, whose deny bit the case PROVES before asserting anything, since an ACL that did not
   take would make the case pass down the ordinary path.
3. **The fixture had the bug the branches warned about.** Two fixture names were claimed twice, so the second
   claimant read the first's stale `.ready` and found a `.release` that already said go: its holder freed the
   slots at once. The broken-queue case read `got=1` where it should have read 0. Names are now claimed once and
   a reuse THROWS.

And one belief was wrong and was corrected rather than forced: a linked worktree does **not** fingerprint
differently from its parent when both hold identical content, and it must not - the key is content and the HEAD
tree id is deliberately out of it. What keeps one checkout off another's pass is the repo check, not the
fingerprint. The first version of that case asserted the opposite and went red.

## The observer fix, which a SIBLING SESSION landed while this was queued - and the trap that is still there

**Resolved by somebody else, better, at `c3d8ab4c2` (2026-09-12).** This section was written saying the fix
could not land; a sibling landed it while this change sat in the push queue, and the honest thing is to record
both that and how their version differs, rather than quietly deleting the section. They put
`Get-TcWorkingTreeState` in `lib/gate-verdict.ps1` itself, beside the fingerprint the push reuse keys on, so
the observer changed by eight lines and "the same tree twice" means the same thing in the observer as at push
time. The version drafted here was a shim inside the observer, which would have left the function's meaning in
a different file from the fingerprint it mirrors. Theirs is the better shape and this one was dropped.

**Their three cases and the four folded in here are complementary and both are kept**: theirs pin the shape the
observer reads (a checkout reports its root and the same key; a path BELOW the root resolves to the root, which
is what a process CWD hands it; a directory that is not a checkout comes back NOT ok with a reason and no key),
and these four pin the LINKED WORKTREE the observer actually runs in. The suite's asserted case count is 29.

**The trap below is still live, and it cost this change a feature.** It was never solved, only avoided. It bit
a second time after the sibling's fix landed: two documents - `MEASURE-gate-queue-window-2026-09-11.md` and
`MEASURE-gate-slot-admission-2026-09-11.md` - name `ops/run-gates.ps1` as their harness and both cite
`b2460165e`. This change wanted **seven lines** in that file, printing `$lease.QueueBroke` so a degraded queue
says so instead of going quiet. Those seven lines made both conclusions UNQUALIFIED and broke the ratchet.

**The print was dropped rather than the documents re-read**, and the reasoning is worth stating because it is a
trade and not an obvious call. Against the print: it fires only when the queue directory is unwritable, which
has never happened here; re-qualifying costs a re-read of two other sessions' measurements, and that re-read is
the citation trap again, which failed three times on this push already. For the print: a queue that silently
stopped queueing is exactly the could-not-look-reads-as-a-pass shape this estate keeps paying for. The reason is
therefore carried on the LEASE (`.QueueBroke`), where any caller can read it, and the omission is written into
`lib/gate-slots.ps1`'s header so the next person finds it as a decision rather than an oversight. **Whoever adds
the print should re-read those two documents in the same change.**

Note what this means in general: **`ops/run-gates.ps1` is named as a harness by two measurements, and nearly
every session edits it.** Every such edit owes two re-reads, and each re-read can only cite a commit a rebase
will rename. That is not sustainable, and it is the strongest argument for teaching the detector a symbolic
citation.

The mechanism, for whoever fixes it:

1. `design/MEASURE-gate-queue-window-2026-09-11.md` names that script as its **harness**.
2. `ops/audit-conclusion-currency.ps1` marks a conclusion UNQUALIFIED when a named harness has a commit after
   the newest commit the document cites, and it holds a **ratchet** on the unqualified count. So ANY edit to
   that path breaks the ratchet and `run-gates` refuses the push. That is the rule working: deciding the change
   altered nothing IS the re-read, as the detector's own header says.
3. To re-qualify, the document must cite a commit **at or after** the commit that moved the harness. When your
   own change is what moves it, the only citable commit is **your own**, which does not exist until you make it.
4. `ops/push-main.ps1` rebases onto `origin/main` whenever the remote moved during the lock wait, which renames
   that commit. **Measured on this push: three lock waits of 1,075 s, 1,985 s and 519 s, behind 18, 14 and 4
   other pushes; main moved during every one.** The citation went stale three times -
   `3d0c71498` to `19de2569e` to `d7794ff13` - and each time the gate correctly refused a push whose re-read
   named a commit no longer in the branch.

So on a box this busy, **a change that touches a script some MEASURE document names as its harness cannot be
landed by the normal route at all**: the re-read is correct when written and stale by the time the lock is
granted. Nothing here is a reason to weaken the gate, and `-Accept` (recording the current count as the new
high-water mark) is exactly the repair this estate forbids.

The honest options, none of which is mine to choose:

- **Land it in a quiet window**, when `push-main` does not rebase. Works today, fixes nothing, and fails again
  the next busy afternoon.
- **Let the detector resolve a citation that names the pushed commit symbolically** - `HEAD`, or a marker
  meaning "the commit this document ships in" - so a rebase carries it. That is a change to the detector, with
  its own must-fire, and it is the one that removes the trap rather than stepping around it.
- **Decide that a harness edit which cannot change a number need not re-qualify** - explicitly rejected by the
  detector's header, and correctly so; that reasoning is what a re-read is.

Recorded in `grocery/audit-script-census.ps1`'s entry for the script too, so the next person to open it learns
it cannot run before they try to run it.

## How this is verified before it is claimed

1. `powershell -File lib\gate-slots.ps1 -SelfTest` - read the exit code, then the verdict line.
2. A mutation probe for each NEW case: neuter the one guard that case covers, from a temp mirror, confirm the
   case goes red and that it names itself, restore, and verify the original by md5. A case that cannot fail
   is not a case.
3. `powershell -File ops\run-gates.ps1` - **exit code first, tally second**. 0 = passed, 3 = could not
   evaluate and is never a pass.
4. Push through `ops\push-main.ps1`, which takes the push lock before it rebases.
