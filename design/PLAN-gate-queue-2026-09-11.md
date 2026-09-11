# PLAN - the gate queue that refills faster than it drains (2026-09-11)

Status: DIAGNOSIS DONE, NOTHING CHANGED. Every fix below changes gate behaviour and waits for Brad.

## The short version

1. **It is not a queue, it is a lottery.** Waiters poll the ten slot mutexes every 500 ms and whoever polls first
   wins. A run created at 16:11:14 was served while seven runs created 16:04:15 to 16:08:20 kept waiting, and all
   seven timed out. Pools already holding a slot also top up ahead of the waiters.
2. **Demand is about twice what ten slots can serve.** In 29 minutes, 43 runs arrived (89 an hour) and 21 ran
   (43 an hour); 18 timed out at the 1,200 s bound. Ten slots at the measured 909 slot-seconds a run serve about 40
   an hour.
3. **About half the demand is re-work.** 80 of 94 failed or timed-out attempts were retried by the same session,
   and 41 of 66 sessions that ran the gates by hand then pushed and ran them again.
4. **The largest single reason to retry is not the queue:** two meal-prep gates FAIL on any worktree that was
   never seeded, and learn it only after their turn. 18 of 53 failed captures failed on nothing else.
5. **Nothing rogue holds the CPU.** No llama-server, no burners. About 24 of 32 cores were busy on average; 104 to
   119 Claude Code sessions and their short-lived tool processes are most of it. The ten slots run ten gates, as
   designed.

## What was observed

A session trying to push at 16:23 counted 40 powershell.exe processes carrying `run-gates.ps1`, CPU at 100%, and
a pre-push that refused with *"waited 1,200s and every one of the 10 machine-wide gate worker slots stayed held"*.
From 16:01 to 16:58 origin/main gained one commit (e5ccc768e, committer time 16:22). Local `main` holds four
commits nobody has pushed, one of them "Batch 2 board and feed live" - committing `public/board.json` IS the feed
deploy, so the money lane is queued behind this too.

## How it was measured

| Source | What it is | Blind to |
|---|---|---|
| Process sampler | one `Win32_Process` read every 60 s, 30 samples, 16:28:44 to 16:57:48 (1,744 s) | processes born and dead inside one interval; a run's end is known only to within 60 s |
| Burst sampler | filtered WQL every 2 s for 60 s, about 16:36 | processes shorter than 2 s, so its CPU figures are LOWER bounds |
| Kept pre-push logs | `%TEMP%\tc-prepush-<pid>.log`, 79 created today | **the hook deletes a passing run's log**, so no PASS appears |
| Session captures | scratchpad files named `*gate*` or `*push*` that contain run-gates output, 09:00 to 16:31 | attempts not saved to a file, so attempt counts are lower bounds |

The scripts were scratch, in the session scratchpad, and are not committed. The gate code they observed:
`lib/gate-slots.ps1` and `lib/parallel-run.ps1` at d72b4f5cd, `ops/run-gates.ps1` at dbd92279f,
`ops/hooks/pre-push` at 8549a395a; origin/main cda34d71b, then e5ccc768e. Each worktree runs ITS OWN copy of
run-gates, so an older worktree runs older code. **No load was added:** no `run-gates`, no burners. The sampler's
own WMI reads are inside the `wmi` figure below and were not separated.

## Finding 0 - the 40 was about 25, and "half had children" was the wrappers

A Claude Code PowerShell tool call is TWO processes: a `powershell -Command "... -File ops\run-gates.ps1 > $out"`
wrapper, whose command line contains the run-gates path, and the real run under it. Every wrapper has exactly one
child, which is most of "20 had child processes". At 16:26:32 the 36 matching processes were 11 wrappers, 10
session-tool runs, 14 pre-push runs and 1 probe checkout: **25 runs**. With wrappers excluded the sampler read
**21 to 33 live runs**, of which **7 to 10 held slots** at any sample.

## Q1 - Are blocked pushes re-queuing? YES

**Across the day** (session captures, 232 in 74 sessions):

- **94 captures ended TIMEOUT or FAILED; 80 of 94 were followed by another attempt in the same session.**
  TIMEOUT 20 of 27, FAILED 60 of 67. Gap to the next attempt: median 12.9 min, p75 21.8, min 1.4, max 78.0 (n=80).
- One session pushed 12 times from 12:29 to 16:01, another 8 times from 10:44 to 12:08. One saved its attempts as
  `loop-push-2-err.txt` and `loop-push-3-err.txt`. One ran run-gates directly five times from 15:00 to 16:26 and
  timed out on three.
- Captures per hour from 09:00: 28, 30, 14, 30, 10, 23, then **48 at 15:00 and 47 at 16:00**. TIMEOUT captures: 0
  before 12:00, 2 at 12:00, **17 at 15:00, 8 at 16:00**.

**Inside the 29-minute window** (process sampler):

- **20 sessions started more than one run-gates; 10 worktrees started a new pre-push after their previous run
  ended**, the new one beginning between 44 s and about 9 min after the old one was last seen alive. Two of the
  ten had timed out without ever running a gate and re-pushed within 1 to 4 minutes.

**The biggest re-queue driver is not the queue.** Two gates fail on a WORKTREE THAT WAS NEVER SEEDED, not on code:

- `meal-prep\pipeline\feed-covers-published.ps1` - `a real built card is available to parse`, *"missing
  ...\worktrees\<name>\meal-prep\db\built\american-goulash-pasta.body.html"*. The case dates from 77e8fff52, 08-15.
- `meal-prep\pipeline\wave-preaudit.ps1` - `END-TO-END the drill inputs exist`, which needs a card under
  `db\built`. The case dates from d0d8af5c0, 08-23.
- `meal-prep/db/built/` is gitignored (`.gitignore:336`) with 0 files tracked. `ops\seed-worktree.ps1` carries it
  (47 MB, 1,168 files, since 4e8102c21), but only when a session runs it, and no hook does
  (`~/.claude/settings.json` has no worktree or seeding hook).
- Of **53** session FAILED captures with a readable failed-gate list, **37 include one of the two and 18 fail on
  nothing else**. Of the 7 FAILED pre-push logs created from 15:07 on, 6 include both.
- Of 106 worktrees, **31 lack the card** (24 of the 99 touched in the last 8 h).
- Why today: until e1afb523b (09-11 09:24) run-gates discovery was blind inside a worktree, so these cases never
  ran there. Two old cases started running where their inputs do not exist.

Both are a could-not-look reported as a FAIL. run-gates already has the honest answer: a self-test that exits 0
with `blind=<n>` on its COMPLETE marker is listed BLIND (`ops\run-gates.ps1:536-546`; `sidecar\start-sidecar.ps1`
is the precedent).

Other gates in failed session captures, not diagnosed here: `ops\audit-cross-module-reach.ps1` 15,
`sidecar\start-sidecar.ps1` 9, `lib\parallel-run.ps1` 7, `meal-prep\pipeline\make-saturation.ps1` 7,
`meal-prep\pipeline\find-similar.ps1` 7. `lib\parallel-run.ps1` and `lib\guard-contract.ps1` are concurrency
fixtures and read as load-sensitive.

## Q2 - Direct session-tool runs, and do they duplicate the hook? YES

- **Across the day: 123 direct run-gates captures and 109 via a push. 66 sessions ran run-gates directly; 41 of
  them also pushed**, and the push re-ran the gates.
- **Inside the window: 67 distinct runs, 49 from pre-push and 18 direct.** **10 sessions ran it directly and then
  pushed within the 29 minutes; in 7 of those the direct run had got slots and run gates**, so the same session
  paid for two turns.
- Some direct runs are legitimate and a push cannot replace them: `gates-baseline` then `gates-after` pairs measure
  a change, and `gates-bare` against `gates-port-seeded` measure seeding. The duplicates are the
  `run-gates-final`, `run-gates-rebased` and `gates-final2` shapes followed minutes later by a push of that tree.

## Q3 - Does a waiter hold or leak a slot, and is 1,200 s the wrong bound?

**No leak.** A waiter opens each slot mutex, calls `WaitOne(0)` and disposes it when taken
(`lib\gate-slots.ps1:91-97`); a non-exact waiter leaves the loop the moment it holds one; a killed holder's mutex
comes back abandoned and is re-acquired (the library's own CLEAN TWIN). Every slot holder in every sample had gate
children. That rules out a slot left held by a dead run; it cannot see a live run holding a slot with nothing
running, which the pool does not do.

**But there is no queue, and holders jump it.**

1. **No FIFO.** From the kept logs: a run created at **16:11:14** was served after 322 s (about 16:16:36) while
   **seven runs created 16:04:15 to 16:08:20 were still waiting, and all seven timed out** at 16:24 to 16:28. A run
   created at 16:24:16 was served after 295 s while the 16:08:20 run timed out at 16:28:25.
2. **Holders jump the queue.** A running pool tops up with `Add-TcGateSlots` every 500 ms while it has gates queued
   (`lib\parallel-run.ps1:97`), in the same race and blind to the waiters. **In 24 of 30 samples there were more
   gate workers than slot-holding runs** - at 16:37:45, 7 runs held 10 workers while 19 waited. Pools granted 1
   slot reached 10 (14:03:46) and 6 (15:58:52).
3. **Fragmentation.** **18 of 19 grants today were width 1**, and of the 9 slot-holding runs that finished, 6
   never exceeded 2.

**What one run costs.** Over the 9 runs that got a slot and finished today (all FAILED, because passes delete their
log): gate work **776 to 1,543 s, median 909 s**; wall 292 to 1,864 s. The quiet reference
is about 516 s of gate work at width 16 (`design\MEASURE-gate-cost-2026-09-09.md`), so a gate under this load does
1.5 to 3 times its quiet work.

**Arithmetic, FIFO assumed.** At 909 slot-seconds a run, 10 slots serve `10 x 3600 / 909 = 40` runs an hour, and a
waiter at position `d` needs about `91 x d` seconds, so 1,200 s covers position 13.

**Measured in the window, 1,744 s:**

| | count | per hour |
|---|---|---|
| runs that arrived | 43 | 89 |
| runs that ended having run gates | 21 | 43 |
| runs that ended at 1,146 to 1,198 s of age without running a gate (the 1,200 s bound) | 18 | 37 |
| runs seen once or ended early without running | 6 | - |
| waiting at a sample (live runs minus slot holders) | 13 to 25 | - |

The served rate (43 an hour, counted from processes) and the capacity estimate (40 an hour, derived from the logs'
gate work) come from different instruments and agree; the agreement is on a small sample and says the slots are
running at capacity, not that capacity is well measured.

**So 1,200 s is not the defect.** Waiting depth ran 13 to 25 against a FIFO reach of 13, so even a perfect queue
would time out the back half; and arrivals ran at about twice what the slots serve, so ANY fixed bound fills. A
longer bound only holds more sessions longer before they retry. The bound is spent by the wrong people (the
lottery), and the demand includes re-work that should not exist (Q1, Q2).

## Q4 - Is something else holding CPU? No single thing

- **No llama-server, no deliberate burners, no hot daemon** in any of the 30 samples. python averaged 0.15 cores.
- **Over the window, Idle averaged 7.59 of 32 cores, so about 24.4 were busy (76%).** `Win32_Processor`
  LoadPercentage, a different instrument, averaged 88% over its 30 reads.
- **Long-lived processes account for about 9.5 of those cores:** Claude Code **4.11** (claude.exe rose from 118 to
  132 during the window), other images 1.26, powershell outside any gate tree 1.19, WMI 1.03 (including this
  diagnosis's own reads), System 0.80, run-gates themselves 0.45, long-lived gate processes 0.42, python 0.15.
- **The remaining ~15 cores are processes born and dead inside a minute.** The 2 s burst puts LOWER bounds on it:
  gate trees 3.18 cores (482 processes seen in 60 s), pre-push hook processes outside run-gates 0.91 (154), session
  tool calls 0.88 (**732 processes in one minute**), run-gates 0.44 (32), other 0.26. The heaviest gate processes
  were the whole-tree scanners: `audit-script-census` (12.5 s and 10.2 s of CPU in one minute, from two
  worktrees), `audit-guard-contract` (7.4 to 7.7 s, from three), `audit-sale-fallback -SelfTest` (6.2 to 6.8 s,
  from three).
- conhost.exe rose from 474 to 544 with the sessions; 467 of 471 had a live parent when checked. Not a leak.

The budget of ten gate WORKERS holds - never more than ten - but ten workers is not ten cores, and the box is
loaded by around a hundred sessions' process churn, inside which each gate does 1.5 to 3 times its quiet work.

## Proposed fixes, best long-term first. Each changes gate behaviour: Brad decides.

**F1. A could-not-look in the two meal-prep gates is BLIND, not FAIL, and a worktree is seeded at birth.** The
missing-input branches of `feed-covers-published` and `wave-preaudit` report BLIND and put `blind=<n>` on their
COMPLETE marker, so run-gates names them instead of refusing the push; and worktree creation runs
`ops\seed-worktree.ps1`, so the cases actually look. Reach: 18 of 53 failed captures would have passed, 37 of 53
lose one reason to fail. The case still cannot pass without its input and run-gates still prints it, but a push
from an unseeded worktree would then prove less, and seeding costs 47 MB per worktree - both Brad's call.

**F2. A real FIFO queue in `lib\gate-slots.ps1`, with the position printed.** A waiter writes a ticket carrying its
pid and process creation time, so a dead waiter's ticket is skipped the way an abandoned mutex is, and takes slots
only at the head. `Add-TcGateSlots` does not grow a pool while any ticket waits. The wait line prints `position 7
of 14, about 10 min at the last hour's rate`. Removes the lottery and the holder queue-jump. Needs a MUST FIRE for
"a later arrival never overtakes an earlier live one" and one for "a dead ticket never blocks the queue".

**F3. Admission at arrival, and a bound derived from position.** A run whose position cannot be served inside the
bound at the measured rate refuses AT ONCE with the estimate (exit 3, `queue 16 deep, about 24 min: not queued`),
instead of after 20 minutes; an admitted run waits for its estimate with margin, not a fixed 1,200 s. The session
learns in seconds, and nobody sits out a bound they were never going to beat.

**F4. One gate run per tree, not two.** A run-gates that PASSES on a CLEAN tree records the pass keyed on the HEAD
tree hash, run-gates' own commit and the seed state; the pre-push hook skips a tree already passed under the same
key. Removes the direct-then-push duplicate without asking sessions to remember a rule -
`always-on-delivery-is-not-sufficient` records a rule delivered every turn and broken anyway. A cache on a gate is
where a stale pass would hide, which is why the key includes the gate's own commit and the tree must be clean.

**F5 (stopgap, not a fix).** A CLAUDE.md line: do not run `ops\run-gates.ps1` by hand when a push will run it, and
run `ops\seed-worktree.ps1` before a worktree's first push. It reaches every session and will be broken sometimes;
it buys time until F1 to F4 land.

**Not recommended: raising `WaitSec` alone** - demand is about twice the service rate, so it grows the queue.
**Not recommended: raising the slot total** - the slots are not what loads the box (Q4), and more gate width on a
box this loaded made each run slower on the morning this budget was built.

## Brad's rulings, 2026-09-11

All four approved, in this order: **F1 (BLIND plus seeding) first**, then F5's line, then F2 with F3, then F4.

## F1 as built, on branch `claude/gate-seed-blind-2026-09-11`

- **`meal-prep\pipeline\feed-covers-published.ps1`** - the missing-card branch reports BLIND and the self-test
  leaves through `Exit-Guard`, so the marker carries `blind=`. Unseeded here: exit 0,
  `FEEDCOV-SELFTEST-COMPLETE cases=27 blind=1`, zero FAIL lines. With both cards copied in: exit 0,
  `cases=28 blind=0`.
- **`meal-prep\pipeline\wave-preaudit.ps1`** - same, and its drill names each input it could not find. Seeded:
  exit 0, `blind=0`. With the reference card renamed away: exit 0, `blind=1`.
  **A defect this found on the way:** an undeclared `$script:blindCases` is `$null`, which formats as an EMPTY
  string, so the seeded arm printed `blind=` and run-gates' `blind=([1-9][0-9]*)` could read nothing. It only
  looked right in the blind arm, where `+= 1` on `$null` yields 1. Declared at 0 now. Running BOTH arms is what
  showed it; the blind arm alone passed.
- **`ops\hooks\pre-push`** - seeds a checkout with no built card once, before the gate, via
  `ops\seed-worktree.ps1`. Best effort and never a verdict: a seed that cannot run does not refuse the push,
  because the gates then report BLIND, which is the honest answer. That is deliberately NOT the "a missing gate
  is a refusal" rule the blocks around it apply - those decide, this one only supplies.
- **`ops\test-prepush-hook.ps1`** - four cases: the seeder runs BEFORE the gate (a seed afterwards would leave
  this push's gates as blind as they were), it is handed the pushing checkout, it does not run again once the
  card is there, and a checkout with no seeder still pushes and is still gated. **35 of 35 cases pass**, up from
  31. The count pin caught the addition with every case green, which is what it exists for.

**Where it deviates from the ruling, and why.** "At birth" would need a `SessionStart` hook in a project
`.claude\settings.json`, which this repo does not have (untracked, and `.claude\settings.local.json` is
gitignored), and whether project hooks run without a trust prompt here was NOT measured. The pre-push hook is
the estate's own installed mechanism, so seeding lands at a checkout's FIRST PUSH instead: certain to run, no
per-session cost, and still once per checkout. If you want it truly at birth, that is a separate change.

**What was verified, and what was not.** Verified: both self-tests in both arms, `grocery\audit-guard-contract.ps1`
(exit 0, `covered=58 backlog=0 regressed=0 half=0 dead=0`, so the self-test markers do not trip it), the hook
suite at 35 of 35, and the bytes of all four files (LF, CR=0, each keeping the BOM state of its own blob -
`wave-preaudit` has one, the others do not). **NOT verified: `ops\run-gates.ps1` was never run**, per the
instruction not to add load while the queue is jammed. So nothing here claims a full gate pass.

**Landing it needs one more step.** Every worktree shares `C:\Codex\ThriftyCrew\.git\hooks`, so the hook change
does nothing until `powershell -File ops\install-hooks.ps1` runs - and when it does, every checkout is re-armed
at once. `ops\audit-hook-installed.ps1` runs from the DAILY CHAIN on the main checkout, not from run-gates, so a
pushed-but-uninstalled hook shows up as a daily alert rather than a red gate on everybody's push.

## Still to build, in Brad's order

1. F5's CLAUDE.md line (stopgap).
2. F2 with F3: the FIFO queue with admission control in `lib\gate-slots.ps1`.
3. F4: the clean-tree pass cache for pre-push.
