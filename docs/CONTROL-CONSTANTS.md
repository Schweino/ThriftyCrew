# Control constants: the register

**Why this exists (2026-09-09, backlog I93, ruled by Brad).** The estate tunes several correcting
loops, and every constant that tunes one was declared locally with a good comment and listed nowhere
together. `sidecar/THRESHOLDS.md` is the precedent and the model, but it covers **score spaces** -
bi-encoder cosine, cross-encoder sigmoid, BM25 - and says nothing about control loops.

A register is not a gate. Nothing here is enforced by a threshold, and it must not become one: a bar
over these numbers would be red on day one against most of them. What it buys is that the next person
tuning one can see the others, and that a constant with no stated direction stands out.

## How to read the columns

- **Direction** is the one that matters. A constant that can only move ONE WAY is an actuator, and an
  actuator needs a rate limit and a plausibility bar or it latches. That is the rule below.
- **When the producer stops** is the standing question from the `ops-and-gates.md` rule: every
  threshold here is an upper bound, so write down what the number does when the thing it watches goes
  quiet. If the answer is "nothing fires", the loop needs a floor as well.
- **Tuned how** is the `I94` convention: was this the first plausible value, or the survivor of a
  sweep? Those are different claims and only one of them is evidence.

## The register

| Constant | Where | What it controls | Direction | When the producer stops | Tuned how |
|---|---|---|---|---|---|
| `$script:BoardStaleHours = 26` | `grocery/capture-watchdog.ps1` | how old a board may be before the watchdog complains | two-way, an upper bound | **fires** - staleness is exactly the absence case | not recorded |
| `$script:NeverRanGraceHours = 30` | `grocery/capture-watchdog.ps1` | how long a task may have never run before it is a finding | two-way, an upper bound | **fires** | not recorded |
| `$REARM_DAYS = 14` | `grocery/check-ad-cycles.ps1` | how long before an alert may fire again for the same thing; since WS 10b the DEFAULT, overridden per alert type by `grocery/alert-tuning.json` when a row is in 7..56 | two-way | goes quiet, and cannot fire | not recorded |
| `LOW_PRECISION = 40.0` at `LOW_MIN_CASES = 5`, `HIGH_PRECISION = 80.0` at `HIGH_MIN_CASES = 10` | `grocery/tune-alert-rearm.ps1` | when an alert's re-arm window doubles (mostly wrong) or halves (right); precision is the PERCENT `Get-TcPrecision` returns | two-way actuator | **printed, not tuned**: a type with no judged close in `STALE_CLOSE_DAYS = 30` moves nothing | **first plausible values**, the plan's; NOT a sweep. No type had 5 judged closes on 2026-09-10 |
| `REARM_MIN = 7`, `REARM_MAX = 56`, `MOVE_EVERY_DAYS = 14` | `grocery/tune-alert-rearm.ps1` | the plausibility clamp and the rate limit on that actuator; a refused move is KEPT and spoken | bounds on a two-way actuator | goes quiet | **first plausible values**, the plan's; NOT a sweep |
| `$script:FLOOR` (BusSilentDays 3, ObservationsDays 3, ProposalNewestDays 7, PacketDays 2, ApplyDays 30, ScoreStaleDays 2, NightlyDays 2, ClosesDays 7, RecheckDays 2) | `ops/brain-report.ps1` | when each estate learning stage's floor goes RED | **floors**, watching for absence - each is its producer's own cadence plus slack | **fires** - that is the whole job; a source that could not run reads NO EVIDENCE instead | **first plausible values**, one per producer cadence; NOT a sweep. First live run 2026-09-10 |
| `$StoppedRuns = 30` | `ops/report-ratchet-trends.ps1` | how many identical non-zero daily readings make a detector a STOPPED LOOKING line | a **floor**, watching for a detector that stopped finding | **fires** - flatness is the absence it watches for; a detector with no readings reads NO EVIDENCE | **first plausible value**, the plan's; NOT a sweep |
| `$StaleDays = 90` | `ops/audit-rule-currency.ps1` | how old a dated claim in `.claude/rules` may be before it is listed for re-verification | a report, never a gate: the count rises with the calendar, so it cannot be hermetic | goes quiet | **first plausible value**, the board's quarter; NOT a sweep |
| `-MaxDropPct 60.0` | `lib/ratchet.ps1` | the largest single-run fall in a high-water mark that reads as real | **one-way actuator** (the mark may only go DOWN) | goes quiet | not recorded |
| `$SENT_LOG_KEEP_DAYS = 180` | `grocery/notify-item-added.ps1` | how long a sent-notification row is kept | two-way | goes quiet | not recorded |
| `$DELETE_GIVE_UP = 5` | `grocery/notify-item-added.ps1` | attempts before a delete is abandoned | two-way | goes quiet | not recorded |
| `MAX_NEW_HOLDS_PER_RUN = 10` | `graph/learning/promote_aliases.py` | the largest plausible batch of new promotion holds in one run | **one-way actuator** (holds only accumulate and never expire) | goes quiet | **first plausible value**, grounded on the live set of 16 holds across 10 commodities; NOT a sweep |
| `HISTORY_MAX_AGE_DAYS = 40` | `ops/member-cohorts.ps1` | how stale the monthly member snapshot series may get | a **floor**, watching for absence | **fires** - that is its whole job | **first plausible value**, 31 days plus a week of slack; NOT a sweep |
| `MIN_SCORE = 8.5` | `~/.claude/skills/recall-hook.py` | the recall floor | two-way | goes quiet | derived; see the file's own note on the 9.0 -> 8.5 move |
| `MAX_REASKS_PER_NIGHT = 200` | `graph/learning/verdict_expiry.py` | how many expired model verdicts one night may re-ask, oldest first | two-way, an upper bound: the rate limit on an expiry actuator that would otherwise re-ask every lapsed verdict at once | **spoken** - `--emit` counts how many of last night's list now carry a newer date, and prints DID NOT FULLY LAND into the nightly status when the resolve stage re-asked fewer than it was given | **first plausible value**, well under one night's model budget; NOT a sweep. No verdict can expire before 2026-11-19, so the first real reading is that night |
| `FRESH_HOURS = 18` | `graph/learning/verdict_expiry.py` | how old a re-ask list may be and still be tonight's | two-way | goes quiet by design: a stale list re-asks NOTHING, never yesterday's questions again | **first plausible value**, the 21:30 to 06:30 window plus slack; NOT a sweep |
| `FANOUT_WARN = 1000` | `graph/lib/fanout.py` | the traversal width that refuses an entry point | two-way, an upper bound | goes quiet | **first plausible value**, grounded on the live shape: max out-degree 4, max in-degree 20,146, so nothing sits near the bar; NOT a sweep |
| `$MaxSeconds = 900` | `ops/cpu-load.ps1` | the longest a deliberate CPU load may hold its core slots in one run; longer is refused with exit 3 | two-way, an upper bound | goes quiet - no load runs, nothing holds slots; a killed tool's burners stop on a 5 s stale heartbeat and its slots come back as abandoned mutexes | **first plausible value**, the longest harness arm seen on 2026-09-11 was about 15 minutes; NOT a sweep |
| `$script:TcGateSlotTotal = 10` | `lib/gate-slots.ps1` | the most gate workers ALL `run-gates` on the machine may run at once, **together with** deliberate load from `ops/cpu-load.ps1` (one slot per burner, all or nothing); each run's width is the free share of it | two-way, an upper bound on a shared budget | goes quiet - an idle machine holds no slots, and a run killed mid-pool frees its slots as abandoned mutexes; a queued run refuses with exit 3 only when the queue itself stops moving (the row below), and says so | **Brad's ruling, 2026-09-11** ("fixed at 10 total"), after seven concurrent runs at width 16 each took ~390s against 372s serial; NOT a sweep, and a lone run's wall at width 10 is unmeasured (the width curve has 16, 24 and 32 only) |
| `$WaitSec = 1200` in `Enter-TcGateSlots` | `lib/gate-slots.ps1` | how long the gate queue may go WITHOUT MOVING before a queued run refuses with exit 3; it does NOT bound the whole wait, which lasts as long as the queue keeps moving | two-way, an upper bound on no progress | **fires** - a queue that stopped moving is exactly the absence it watches, and the refusal names how many runs are still ahead | kept from the fixed 20-minute total deadline it replaced, which refused runs whose queue WAS moving (24 such refusals on 2026-09-11); NOT a sweep |
| `$script:TcGateVerdictMaxAgeMin = 180` | `lib/gate-verdict.ps1` | how old a recorded green `run-gates` verdict may be and still stand in for byte-identical content in the same checkout | two-way, an upper bound | goes quiet - no green run, no verdict, and every run runs the gates | **first plausible value**, NOT a sweep: long enough to span a session's own run and its push through the queue as measured 2026-09-11 (up to 1,010 s waiting plus 1,864 s running), short enough that an input outside the fingerprint rarely moves under it |
| `-AbandonEverySec 60` and `-SweepEverySec 5` in `Enter-TcGateSlots` | `lib/gate-slots.ps1` | how often a queued push asks the remote whether it can still land, and how often a waiter probes the tickets ahead of it for a dead owner | two-way | goes quiet - nothing queued, nothing asked | **first plausible values**, NOT a sweep: one network round trip a minute per queued push, and a dead ticket can block the queue for at most 5 s |
| `$script:HangGuardSec = 2700` | `ops/run-daemon-battery.ps1` | how long the nightly daemon battery may run before its whole process tree is killed and the run exits 3 | two-way, an upper bound | goes quiet - a battery that never starts trips nothing here; `TC Daemon Battery 0230`'s row in `grocery/expected-automations.json` pages it STALE or NEVER RAN | **first plausible value**, four times the slowest full battery measured (677 s under load, 2026-09-11; 248 s for the run that wrote the runner); NOT a sweep |
| `$script:SlotWaitSec = 3600` | `ops/run-daemon-battery.ps1` | how long the battery waits for its one slot of the machine-wide gate budget before exit 3 | two-way, an upper bound | goes quiet - no run, no wait; the task row pages as above | **first plausible value**, NOT a sweep. 1800 was drafted and dropped the same day: the exploratory run waited 1,629 s behind about fifteen concurrent `run-gates` |
| `$PAIR_MAX_BYTES = 2MB` | `ops/seed-worktree.ps1` | the largest tracked record the seeding pair check will read when looking for a stale pointer to a seeded dated file | two-way, an upper bound | goes quiet, and it has nothing to lose: this is a REPORT with no verdict, and a record that stops being written keeps its last pointer and is still reported as stale | **first plausible value**, NOT a sweep: a board pointer lives in a small report and the boards themselves carry a dated NAME, so they are excluded before the size matters. 9 of the 304 records examined on 2026-09-11 were over it or unreadable, and the run prints that count |
| `$script:TcPushLockTotal = 1` | `lib/push-lock.ps1` | how many pushes on this box may hold the machine-wide push lock, and so gate-then-land, at once | **fixed by the mechanism, not tuned**: `refs/heads/main` accepts one push at a time whatever this says, so the only question was whether the losers find that out before or after gating | goes quiet - nothing pushing, nothing held; a holder that is killed frees the lock at once as an abandoned mutex | **not a tuning constant and NOT a sweep.** It is a property of git. A value above 1 would not add landings, only restore the race |
| `$WaitSec = 1200` in `Enter-TcPushLock` (`-WaitSec` on `ops/hold-push-lock.ps1`) | `lib/push-lock.ps1` | how long the PUSH queue may go WITHOUT MOVING before a hook gives up on the lock; as with the gate queue it does not bound the whole wait | two-way, an upper bound on no progress | **spoken, and it degrades rather than firing**: the hook prints `push lock - unlocked <why>` and pushes on, gated exactly as before. That is deliberate - this is a fairness device, and a refusal here would be worse than the livelock it fixes | **kept from `Enter-TcGateSlots`**, which is the same queue with a budget of one; NOT a sweep |
| `$MaxHoldSec = 5400` | `ops/hold-push-lock.ps1` | the hang guard on one hold, after which the lock is released whatever the hook is doing | two-way, an upper bound | goes quiet; and it is the THIRD of three ways a hold ends, behind the hook writing its release file and behind the watched hook process disappearing, so it only ever fires if both of those fail | **first plausible value**, NOT a sweep: about three times the longest hook measured on 2026-09-11 (1,840 s) |

**Most rows say "not recorded" and that is the honest state.** `I94` established the convention that a
constant records what ELSE was tried; retro-filling the existing ones was explicitly not asked for, so
only the ones added since carry it. A row here saying "not recorded" is a fact about the estate, not a
gap in this document.

## The rule this register exists to make visible

**A control constant that may only move ONE WAY needs a rate limit and a plausibility bar.**

`lib/ratchet.ps1` had it and `promote_aliases.py` did not, which is what backlog I93 found. The
audits' high-water mark may only fall, so the ratchet refuses a fall to zero and a fall larger than
`-MaxDropPct`, **keeps the old baseline**, and reports. `promotion-holds.json` may only accumulate -
holds never expire and nothing re-tested them until `--recheck-holds` - so a single degraded guard run
naming many commodities would have written a permanent hold for each of them in one pass, with nothing
calling that extraordinary. It now refuses a batch over `MAX_NEW_HOLDS_PER_RUN`, keeps the file it
has, and reports, with `--accept-holds` as the deliberate override.

**Both halves matter, and the second is the one that gets forgotten:** refusing is not enough. The old
state has to be KEPT and the refusal has to be SPOKEN, or a run that silently declined to act looks
exactly like a run with nothing to do.
