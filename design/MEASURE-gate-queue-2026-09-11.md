# MEASURE - the gate slot queue (2026-09-11)

**Question.** Pushes from about 20 worktrees were being refused by `ops/hooks/pre-push` with run-gates exit 3,
"waited 1,200s and every one of the 10 machine-wide gate worker slots stayed held". Was that the budget of 10
running out, or the ORDER in which `lib/gate-slots.ps1` handed slots out? And what is the smallest change that
keeps every push fully gated?

**Code under test.** "Old" is `lib/gate-slots.ps1` as it stood at `e5ccc768e` (unchanged at `5b4cc0982`, md5
recorded in the simulation fingerprint). "New" is this branch.

**Harness.** Session scratch scripts, not committed, each described closely enough below to rebuild:
`sample-gate-queue.ps1` (the live sampler, v1 and v2), `parse-kept-logs.ps1`, `analyze-sample.ps1`, `sim-queue.ps1`,
`mutate-gate-slots.ps1`. Every one is READ-ONLY toward the real slots: none opens a `Global\tc-gate-worker-slot-*`
mutex, and the simulation and mutants run on private `Local\` prefixes with sleep-based work, so none adds CPU load.

## 1. The live queue

**Method.** Every 2 s, one `Win32_Process` listing. A run is a `powershell.exe` whose script is `run-gates.ps1`; a
worker is a powershell or python child of one. For a run started by the hook, the sampler opens the hook's log
with read, write and delete sharing, so the log a PASS deletes can still be read after the hook's `rm`, and it
reads the run's exit code from its process handle. v1 counted a tool wrapper whose `-Command` merely names
run-gates.ps1 as a run, and its child run-gates as that wrapper's worker; a snapshot at 17:1x showed 30 matches of
which 7 were wrappers and 23 real runs, with exactly **10 real gate workers**. v2 fixes the filter.

**The window: 17:11:18 to 17:36:07 on 2026-09-11, 733 ticks.**

- **88** run-gates processes observed, **63** of them started by the pre-push hook, 63 seen from process start, 14
  still running when sampling ended.
- Of the **74** that exited inside the window: 50 exit 0, 5 exit 1, **13 exit 3**, 1 exit 8, and 5 whose code could
  not be read.
- **27 of the 63** hook runs had their log captured; the rest belong to sessions that push from bash, which writes
  the log into its own TEMP. Of those 27: 11 PASSED, 1 FAILED, **5 refused for want of a slot**, 10 in flight.
- Slot wait over the **22** logged runs that reached Enter's verdict: min **2 s**, median **486 s**, max **1,200 s**;
  9 of 22 waited 600 s or more.
- **The order, over the 16 runs whose grant or refusal this sampler saw happen (11 granted, 5 refused): 9 of the 11
  grants went to a run while another that had begun waiting more than 5 s earlier was still waiting. 24 such passes
  in all.** One run was granted **2 s** after it began waiting while another had been waiting **767 s** longer and
  was later refused; another was granted at 213 s over a run that had waited **844 s** longer and was also refused.
- Gate worker processes alive per tick: median **10**, max 11, at or above 10 in **718 of 733** ticks. Machine CPU
  median 70%. run-gates processes alive with no worker child, so waiting, discovering or judging: median 12, max 19.

So the budget was fully subscribed for the whole window and every slot was running a gate. The refusals were not the
budget running out; they were the order it was handed out in.

**A longer, overlapping window, 16:48:35 to 17:38:01, 1,451 ticks.** Its process counts carry the v1 filter defect,
so only its hook-log figures are quoted, which the defect does not touch: **43** logged runs reached Enter's verdict,
median wait **1,132 s**, **20 of 43 refused at 1,200 s**, 27 of 43 waited 600 s or more. Of the **38** runs whose
grant or refusal it saw (18 granted, 20 refused), **16 of the 18 grants** passed a run that had begun waiting more
than 5 s earlier, **83 passes** in all. One run granted at 290 s stood in front of six such runs at once, four of
which had waited between 549 s and 856 s longer and three of which were later refused.


**Kept hook logs** (`%TEMP%\tc-prepush-*.log`, 2026-09-10 and 09-11). A pass deletes its log, so passes are
ABSENT from this set by construction and it says nothing about a pass rate. Of 80 kept logs: **26 refused at
1,200 or 1,201 s**, 25 FAILED, 29 in flight or granted without a verdict yet. Every granted run in the set started
at width 1 except two, and nine carry timings.

## 2. What a held slot was doing

A run at width 1 from start to finish is the cleanest reading, because its pool wall IS one slot's hold. Five
such runs across the kept logs and v1 did **776 to 929 s of gate work in 779 to 933 s of pool wall, 99 to 100%**:
a held slot is busy running a gate essentially all of the time it is held. The pile-up was not slots held idle.

So the box's capacity is the budget divided by one run's work: 10 slot-seconds a second over about 870
slot-seconds a run is about **41 runs an hour**. A queue longer than about 14 runs cannot clear inside a 20-minute
wait whatever the order, and no change to the order adds a run to that figure.

## 3. Candidates, rubric and ruling

**Rubric, in priority order.** (1) Every gate still runs on every push. (2) The machine-wide 10 is never exceeded:
Brad's ruling, 2026-09-11. (3) No new way for one broken process to block every push on the box. (4) The smallest
change. (5) Its property can be proved by ORDER or OVERLAP, never by an upper wall-clock bar.
**Context.** One 32-processor box, about 20 concurrent sessions, and checkouts on several versions of this file.

| Candidate | (1) | (2) | (3) | Measured | Ruling |
|---|---|---|---|---|---|
| FIFO ticket queue for the slot wait, and no top-up while a push is queued | yes | yes | yes, with mutex liveness and a heartbeat | order, below | **built** |
| A lower bar: a push that has waited long enough runs at width 1 over the budget | yes | **no** | yes | with about 20 waiters past the bar, up to 20 workers over the 10 | rejected: it is the 112-worker pile-up the budget was ruled to stop, and changing the 10 is Brad's call |
| Reuse a recent passing run-gates for the same tree hash | no, it skips the run | yes | yes | **0 runs saved**, below | rejected |

**Reuse, measured.** Over 2026-09-11 the shared repository's `refs/remotes/origin/*` reflogs record 42 push updates
(38 to main; `origin/HEAD` excluded, since it mirrors main and a first count that included it read 80). They carry
39 distinct trees. The three trees pushed twice were each pushed to a branch and to main in the **same second**,
which is one `git push` updating two refs and so ONE hook run. Beyond that, run-gates gates the working tree,
untracked and ignored scripts included, so a tree hash does not even name what was gated.

## 4. What changed

`lib/gate-slots.ps1`: a run that finds no slot it may take writes a ticket named by the moment its wait began, and
tries the slots only when no live ticket is ahead of it. A newcomer defers to every live ticket. `Add-TcGateSlots`
takes nothing while a gate run is queued. A ticket is alive while a named mutex its owner created exists, so a
killed waiter's ticket dies with its handles, and while its owner keeps touching it
(`$TcGateTicketStalePolls`, registered in `docs/CONTROL-CONSTANTS.md`), so a hung waiter cannot hold the line.
An `-Exact` load never holds back a gate run and defers to every queued one. The mutexes, the 10 and the 20-minute
refusal are unchanged. `ops/run-gates.ps1` prints how many runs were queued ahead, on the wait and on a refusal.

**Mixed checkouts.** A run from a checkout without this file polls and ignores the queue, so until the worktrees
rebase such a run can still take a slot out of turn. The budget holds either way.

## 5. Proof

**Self-test, `lib/gate-slots.ps1 -SelfTest`.** 28 cases, run under `Stop` with a counted catch and a literal case
count. The new ones stand a push in line in another process, free a slot, and ask who may take it; each waits on a
file, and no clock decides any of them. The first run printed PASS with one case never reached, because a fixture
variable `$pS` IS `$PS` and overwrote the powershell.exe path - hence the case count. One case covers the failure
path of the queue itself: with a file sitting where the queue directory would go, every ticket attempt fails, and
the run says why and waits out of turn rather than refusing a push, because refusing there would be a new way to
block every push on the box.

**Mutation probe, `mutate-gate-slots.ps1`.** Eight single mutants, each run from a temp mirror; the real file's md5
was `0C4CE9C08D6CA13CEC639FC67631813B` before and after. **8 of 8 killed**, each by the case written for it (the
probe was run twice, the second time against the file as it stands with all 28 cases; both runs killed all eight):

| Mutant | What it does | Killed by |
|---|---|---|
| m1 | Enter tries the slots whoever is queued - **the old polling** | MUST FIRE the order; MUST FIRE load yields to a queued push; CLEAN TWIN two pushes granted in turn |
| m2 | Add-TcGateSlots ignores the queue - the old top-up | MUST FIRE a running pool does not top itself up past a queued push |
| m3 | newest ticket first | MUST FIRE the order; CLEAN TWIN two pushes granted in turn |
| m4 | the heartbeat is ignored | MUST NOT FIRE a live run that stopped polling does not hold the queue |
| m5 | an -Exact ticket holds back gate runs | MUST NOT FIRE a queued -Exact load does not hold back a gate run |
| m6 | a dead ticket counts as live | CLEAN TWIN a push killed while queued does not hold the queue; CLEAN TWIN the top-up resumes |
| m7 | a waiter never touches its own ticket | CLEAN TWIN a queued push keeps its own ticket fresh |
| m8 | an -Exact request ignores queued gate runs | MUST FIRE load yields to a queued push |

m1 is the MUST FIRE the change owes: under the polling it replaces, the newcomer takes the freed slot on its first
try, every time, and the case goes red.

**Simulation, `sim-queue.ps1`.** Two slots, 8 runs each started 700 ms apart, each wanting 2, polling every 250 ms,
giving up at 25 s, and needing 6 slot-seconds of work at its current width with a top-up every 250 ms. Three
rounds per arm, arm order alternated per round, one row per run per arm. A PASS is a run granted while a run that
began waiting before it was still waiting. **The bar was written in the harness before the first run: 0 passes in
the new arm.**

| Arm | Runs | Timeouts | Passes | Granted runs that passed an older waiter | Median wait | Max wait |
|---|---|---|---|---|---|---|
| old | 24 | 0 | 23 | 11 of 24 | 6.2 s | 18.5 s |
| new | 24 | 0 | **0** | **0 of 24** | 8.3 s | 18.6 s |

Bar met, and the old arm's 23 show the harness can tell the two apart. The median wait moved 2.1 s the wrong way
over 24 runs per arm with one variant of each, which is inside what three rounds can resolve and is reported, not
explained: FIFO gives no run more capacity, and a pool that no longer tops up past a queued push runs narrower.

## 6. What this does not fix

Capacity (section 2). If pushes arrive faster than about 41 an hour, pushes still wait past 20 minutes and exit 3.
What the queue changes is WHICH: the most recent arrivals rather than whoever lost the poll, and the refusal now
says how long the line was. A session that retries at once rejoins at the back. The levers on capacity are the
gate work per run, the budget, and how often sessions push; none is in this change.
