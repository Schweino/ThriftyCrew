# PLAN: the bot gets a checkout nobody else writes (2026-09-25)

Brad, 2026-09-25, on the rule that nobody may push between 06:30 and 09:00: *"That smells like a
design/architecture/process problem. The fact it has to do another round is insane."* He then ruled: *"Measure, then
plan the lasting fix (Recommended)"*. This file is that measurement and that plan. Nothing is built by it.

**Status: RULED 2026-09-25, design D adopted with every recommendation; building in stage order.** Brad's rulings are
recorded verbatim in section 13.1. Stage 0 is under way (W0.2 by a sibling session, W0.1 and W0.3 here); Stage 2 waits
on W0.3's 7 clean days and a week of warnings.

**Numbers.** Every number in Part 1 comes from one scratch harness run over the main checkout's logs, the shared
reflogs, the checkout-sync record and the push ledger, read-only. The harness is named with its blobs in section 14,
and its rows are committed beside this file as `design/MEASURE-bot-checkout-2026-09-25.jsonl`. Totals are derived from
those rows, never counted by hand. The per-run CAUSE of each failed landing is a hand reading of that run's own log,
and each one names its evidence (section 2.3). SCRATCH means "not produced by a committed harness"; W0.1 commits it.

## 0. The answer, in plain words

- **The diagnosis holds for the checkout and mostly fails for the branch.** Of the 16 capture runs since 09-16 that
  made a commit, 10 did not push on their first round. **6 of those 10 were stopped by the shared checkout** (a
  session's untracked, staged or half-merged file, or a gate run over the session's dirty files), 3 by a code defect,
  and **only 1 because main moved** while the run was pushing. A code landing during a run is not what costs the bot a
  round. Other people's files in the bot's working tree are.
- **The self-heal code of 09-23 turned damage into a clean stop, and the stop is now every run.** Before it, 4 of 17
  armed runs were stopped by the shared checkout and one of them left a conflicted file in everybody's index. Since it,
  **0 of 5 armed runs landed their own data, and all 5 were stopped by the shared checkout or the shared branch**. The
  sync itself takes 0.4 to 5.2 seconds and writes nothing it does not own; it just cannot get past someone else's file.
- **Today's 07:00 run is the fourth kind of stall, found live.** A session landed the bot's unpushed commits from the
  main checkout at 17:35 yesterday and could not move local main afterwards, so local main now carries 6 commits that
  are patch-identical to commits already on origin. Replaying one of them conflicts with its own landed copy, the sync
  ends `degraded/replay`, and nothing was pushed. The 08:00 run did the same (commit made at 08:31, not pushed). As this is written at 09:06, **neither of today's two runs has reached origin**, and local main is 18 ahead and 39 behind.
- **A real content conflict is rare but not zero.** 28 session landings happened while a bot run was live; 7 touched
  a bot-owned path and 1 touched a file the bot's own commit also changed. So a catch-up is mechanical 27 times in 28.
- **The 06:30 to 09:00 rule costs about 4.5 landings a day.** 36 of 362 session landings over 8 full days fell in that
  window (9.9%, the window is 10.4% of the day). The rule defers them by up to two and a half hours and buys nothing
  that a checkout of its own would not buy for free.
- **Recommendation: design D.** The main checkout becomes the production checkout, written only by the scheduled
  writers, and every interactive session, Brad's included, works in a linked worktree. It is the only design that moves
  no data and re-points nothing: 13 scheduled tasks, 16 agent prompts, the alert road, the seeding source, the capture
  sink and 5 GB of gitignored state all stay where they are. It is enforced by a write barrier and backed by a
  registry of which writer owns which path. If the barrier cannot hold (section 5.4), the fallback is design B, a
  standalone production clone, which isolates everything and costs the most to move.

## Knowledge consulted

Searched on 2026-09-25 with `knowledge-search/search.py --estate "dedicated bot worktree production checkout"` (2,294
sections, 119 matched). Used from it, and from the brief:

- `claude-code-craft/applies-here.md`, "A worktree is not the main tree, and main moves while you work": *"Every Claude
  worktree ... shares one `.git` with the main checkout, gets a fresh checkout of TRACKED files only, and is written by
  tools that do not know which tree they are in"*, and item 1, *"A fresh checkout is CRLF; the main checkout is LF"*.
  Used in the rubric's "what breaks in the move" for designs A and B.
- `reliability-craft/applies-here.md`, "The 07:00 bot, the shared index, and the fix that never reached a commit":
  the bot stages an explicit path list, never `git add -A`. Kept as the ownership basis in section 6.
- `design/PLAN-bot-checkout-self-heal-2026-09-23.md`, section 4.1: scores in the context *"a shared Windows main
  checkout on git 2.54.0.windows.1"*; section 2.6: *"git's two-way move is not atomic in its write phase on Windows"*.
  Its sections 4.3, 10 (D8) and 12 are what section 12 below keeps or reverses.
- `design/PLAN-push-derived-conflicts-2026-09-23.md`, sections 15.5 (W8.2, W8.3) and 16 (design A, the chain queue).
- `CLAUDE.md`: *"The ~07:00 and ~08:00 bots bring the main checkout to origin/main with a two-way move at the start and
  end of every run (lib/checkout-sync.ps1): no stash, no rebase. A dirty file of yours on a path upstream changed is
  never written: the sync goes partial and pages, and the bot's push waits until that file is clean."* Part 1 measures
  exactly how often that wait happens.
- `.claude/rules/ops-and-gates.md`: *"A PUSH IS A COMPARE-AND-SWAP WHOSE CRITICAL SECTION IS THE WHOLE HOOK ...
  Serialising costs no throughput"*; the lock order (0 the capture-run mutex, 0b the chain queue ticket); *"EVERY LOCK
  PATH DEGRADES TO THE DAY BEFORE"*; *"Do not add a gate that is red on day one"*.
- `grocery/alert-lib.ps1` header, item 4: *"FROM A LINKED WORKTREE IT SENDS THROUGH THE MAIN CHECKOUT'S
  send-alert.ps1"*, and `grocery/send-alert.ps1:296`: an automated send from a linked worktree is refused. This rules
  out design A as written (section 5).
- `ops/rehearse-chain.ps1` header, "WHAT ONE REHEARSAL IS": the chain's ship path already runs in *"a STANDALONE clone
  ... never a linked worktree"*. This is the precedent that makes design B credible.
- Memory `refused-bot-commit-freezes-the-checkout` and `spawned-tasks-must-not-write-the-main-tree` (the second is the
  road three of the measured stalls came through).
- `~/.claude/CLAUDE.md`: *"Offer N when the design is open ... State the rubric used."*; *"Plan to a file when there is
  blast radius"*. `.claude/rules/measurement.md`: *"Write the ACCEPTANCE BAR before the run"*, *"Write ONE ROW PER CASE
  PER ARM"*, *"A rate is printed with its DENOMINATOR, always"*.
- Siblings: `git log --all --oneline -- lib/checkout-sync.ps1 grocery/capture-run.ps1` on 2026-09-25 shows the landed
  self-heal rows (W2.2, W3.1, W3.2, W4.1, W4.2, W0.2) twice each, one copy per rebase, and `b6be9c8c3` (a push-only
  retry). No branch works on a dedicated or production checkout. Branches `bot-paths-graph-tracked-writers` and
  `fix/bot-paths-restore-lane-state` touch the ownership list and are named in W0.3.

## 1. What this plan tests

The main session's diagnosis, to be tested and not assumed: the bot (capture-run, graph nightly, harvest, the ratchets)
shares (1) the MAIN CHECKOUT with every session, so a session's dirty file on a path upstream changed stalls the sync,
and (2) the MAIN BRANCH, landing its data commit by its own sync-and-retry instead of through push-main's queue while
main moves about 9 commits an hour. The bot's paths and code paths rarely overlap, so a mid-run landing should cost
seconds.

## 2. Part 1: the measurement

### 2.1 The bars, written before the harness ran

Written at about 07:05 CDT on 2026-09-25, before any per-run table existed. Seen before writing: the 5 rows of the sync
log, `capture-run-status.json`, the tail of the main reflog, and that local main stood 16 ahead and 39 behind origin.

| Q | Unit | Bar for "today's design is adequate" |
|---|---|---|
| Q1 | armed capture runs whose end-of-run sync or push needed more than one round; runs whose commit was not on origin from their own run | at most 1 run in 20 (5%) needs a second round, AND 0 runs end held or failed for any reason other than a real content conflict on a bot-owned path |
| Q2 | distinct stall events caused by a file, index entry, operation or branch state that a non-bot writer left in the main checkout | 0 in 10 days |
| Q3 | session landings per day in 06:30 to 09:00 CDT, and push-main runs started there | the rule is a real throughput cost if it removes at least 2 landings a day from the window |
| Q4 | session landings made while a bot run was live; of those, how many changed a bot-owned path (`lib/bot-paths.ps1`, 45 entries); how many changed a path the run's own commit changed | catch-up is mechanical if at most 5% touch a bot-owned path and at most 1% touch the bot commit's own paths |

### 2.2 The harness

`measure.py` (scratch, blob in section 14) reads, read-only: every `capture-run-{ad,daily}-<date>.log` from 09-16 on,
split into runs by their `--- run-log:` markers; the graph-nightly and harvest-crawl logs; the shared reflogs of
`refs/heads/main` and `refs/remotes/origin/main` (every origin entry since 09-16 is `update by push`); the checkout-sync
log `.git/tc-checkout-sync-log.jsonl`; and the push ledger under `%LOCALAPPDATA%\ThriftyCrew\push-ledger`. It writes one
row per run, per origin landing, per push-main row and per sync row. `derive.py` prints every total from those rows.
The owned-path set is exported from the declaration itself (`lib/bot-paths.ps1` blob `86587b43`, 45 entries), never
copied by hand. Run at origin/main `c42d0a679`, the base of this worktree.

**Coverage and what the harness cannot see.** Logs before 09-17 have gaps (no files for 09-15 and 09-16). The old tail
did not log git's push output, so a push refused by the hook is identified from the kept `%TEMP%\tc-prepush-*.log` files
where they survive (09-21) and is otherwise unattributed. The window rule's start date is not recorded anywhere, so
Q3's "before" days may already include days a session honoured it (09-22 and 09-24 carry 0 window landings each).

### 2.3 Q1: extra rounds, and why

**21 capture runs parsed, 20 armed** (reached a commit, a refusal, a throw or a start-sync stop). One row each.

| Run | Rounds | Landed from its own run? | Cause (from the run's own log) | Lag after the run ended |
|---|---|---|---|---|
| ad 09-17 06:00 | 1 | yes | clean | 0 |
| daily 09-17 07:00 | 1 | yes | clean | 0 |
| ad 09-18 07:00 | 1 | yes | clean | 0 |
| daily 09-18 08:00 | 1 | yes | clean | 0 |
| **ad 09-19 07:00** | 4 | no | **shared checkout**: a session's untracked `meal-prep/db/dedup-paired/report.json` blocked every rebase (fe2ad786e's message) | 8,381 s |
| **daily 09-19 08:00** | 4 | no | **shared checkout**: the same file; hand repair and a plain push at 09:22 | 177 s |
| ad 09-20 07:00 | 0 | no | code defect: `commit/push threw` on the `-C`/`-c` binding (cc053f374) | 1,077 s |
| daily 09-20 08:00 | 0 | no | code defect, same | 13,628 s |
| daily 09-20 12:00 | 0 | no | code defect, same | 2,727 s |
| **ad 09-21 07:00** | 4 | no | **shared checkout**: all 4 pushes refused by `run-gates` run over the main checkout's working tree, 3 to 5 gates red each time (`%TEMP%\tc-prepush-181009.log` to `-181993.log`); not attributed file by file | 5,204 s |
| daily 09-21 08:00 | 1 | yes | clean | 0 |
| ad 09-22 07:00 | 1 | yes | clean | 0 |
| daily 09-22 08:00 | - | no commit | commit refused by the pre-commit verifier (BOM CHANGED `meal-prep/db/cost-flags.txt`), the bot's own write | - |
| ad 09-23 07:00 | - | no commit | size gate, the carried backlog of the refused day | - |
| daily 09-23 08:00 | - | no commit | size gate and guards | - |
| daily 09-23 09:32 (hand, `-Force -ForceBigCommit`) | 2 | yes | **main moved during the push**; rebase, push rejected, rebase, pushed | -370 s |
| **ad 09-24 07:00** | 4 | no | **shared checkout**: round 1 an untracked `design/backlog-inbox/pd-land-W0.1R-2026-09-23.md`; round 2 an autostash conflict on a session's dirty `ops/test-prepush-hook.ps1`, left UNMERGED in the shared index; rounds 3 and 4 `Cannot autostash`. This run ran the OLD tail: the checkout had not yet received W4.2 | 37,733 s |
| **daily 09-24 08:00** | - | stopped | **shared checkout**: start sync `blocked/conflict` on that unmerged file; STOPPED before any capture | - |
| **daily 09-24 09:00** | 1 | no | **shared checkout**: tail sync `blocked/foreign` on `lib/chain-queue.ps1 (??)`, a session's untracked copy of a file upstream added | 27,086 s |
| **daily 09-24 16:38 (hand, `-Force`)** | 1 | no | **shared checkout**: start sync `partial` (17 short), tail `blocked/foreign`, on `meal-prep/pipeline/audit-lane-shape.ps1 (M )`, a session's STAGED edit. It is still staged at 07:00 on 09-25 | 340 s |
| **ad 09-25 07:00** | 1 | no | **shared branch**: start and tail sync `degraded/replay`: local commit `447b42efe` is patch-identical to `7e70f5fae` on origin, landed by a session's `push-main -ViaWorktree` from the main checkout at 17:35 on 09-24 (`main_sync=manual`), and replaying it conflicts with its own copy (rename/delete of a `browser-capture-due` flag) | not landed at 09:06 |
| **daily 09-25 08:00** | 1 | no | **shared branch**: the same `degraded/replay` at start and tail; commit `a7f0ea126` made and kept local | not landed at 09:06 |

Totals, derived from the rows. The 16 and the 20 below cover 09-17 to 09-24; with today's two runs they read 6 of 18
committed runs pushed on round 1, and 15 of 22 armed runs not landed from their own run.

- **Committed runs pushed on their first round: 6 of 16.** Not on the first round: 10 of 16 (62%). Bar: at most 5%.
  **Fails the bar.**
- **Armed runs whose data did not land from their own run: 13 of 20.** Of the 13, a real content conflict on a
  bot-owned path: **0**. Bar: 0 other causes. **Fails the bar.** By cause: shared checkout 7 (09-19 twice, 09-21,
  09-24 four times), code defect 3, commit refused 3 (one the bot's own BOM write, two the carried backlog it caused).
- **Main moved during the push: 1 of 16 committed runs**, and that was a 20-minute tail of a forced hand run.
- **What the lag cost.** The 9 runs that committed and landed later landed 177 to 37,733 seconds after the run ended,
  median 5,204 s (87 minutes). While a run's commit is local, the live board and feed are the previous day's.
- **Wall time per round.** The old tail took 66 s median from commit to run end over 16 committed runs (88 s for the
  runs that pushed on round 1). The new sync's own step takes 0.44 to 5.24 s over 7 rows (median 2.46 s). Round cost is
  not the problem; rounds that can never succeed are.

**Before and after the 09-23 self-heal code** (the NEW tail is any run whose log carries `sync[start]` or `sync[tail]`):

| | Armed runs | Landed from their own run | Stopped by the shared checkout or branch |
|---|---|---|---|
| OLD autostash tail, 09-17 to 09-24 07:00 | 17 | 7 of 17 (6 on round 1, 1 on round 2) | 4 of 17 |
| NEW two-way sync, 09-24 08:00 to 09-25 08:00 | 5 | 0 of 5 | 5 of 5 (3 checkout, 2 branch) |

The new code did what it promised: 0 writes to a file it does not own (every blocked row says *"nothing was
written"*), no stash, no marker left in anyone's tree. What it cannot do is proceed past a foreign file on a moved path,
by design (self-heal D2(a)), and on this checkout there is always one. **The self-heal plan's own bar B1b (at least 18
of 20 armed runs start on `current` or `synced`) reads 1 of 5 so far** (the 09:00 run on 09-24 was `current`).

**The other committing writers, from their own logs since 09-16.** Graph nightly committed 16 times and pushed 3; 13
pushes failed and were *"left local for the next capture-run to carry"*. Harvest committed 7 times and pushed 5; 4
more commits were refused. On 09-25 the hook refused the graph push twice (05:18 and 05:25, `run-gates` red on
`ops/test-prepush-hook.ps1`, push ledger `hook-refused`). Their unpushed commits are what today's local main carries.

### 2.4 Q2: every stall the shared checkout caused

| Date | What was in the way | Whose | What it cost |
|---|---|---|---|
| 09-19 07:00 and 08:00 | untracked `meal-prep/db/dedup-paired/report.json` | a session (a sibling committed the same path from a worktree at 03:33) | two runs unpushed; board and feed not refreshed until a hand repair and a plain push at 09:22; a code change (fe2ad786e) |
| 09-21 07:00 | 3 to 5 gates red in `run-gates` over the main checkout's working tree | not attributed file by file | 4 refused pushes, 87 minutes late, paged "could not push" |
| 09-24 07:00 | untracked `design/backlog-inbox/pd-land-W0.1R-2026-09-23.md`, then a session's dirty `ops/test-prepush-hook.ps1` | sessions | the old autostash left the file UNMERGED in the shared index; push failed; 10.5 h late |
| 09-24 08:00 | that unmerged index entry | left by the bot's own autostash over a session's file | the daily capture never ran at 08:00 (stopped before any capture) |
| 09-24 09:00 | untracked `lib/chain-queue.ps1` | a session | commit local for 7.5 h |
| 09-24 16:38 | staged `meal-prep/pipeline/audit-lane-shape.ps1` | a session | a forced hand run went partial and did not push; still staged the next morning |
| 09-25 07:00 and 08:00 | 6 duplicate commits on local main | a session's `push-main -ViaWorktree` from the main checkout | neither of today's runs pushed; still local at 09:06 |

**7 stall events in 7 days** (09-19 to 09-25). Bar: 0 in 10 days. **Fails the bar.** 5 of 7 were a session's
file or index entry; 1 was a gate judging a session's tree; 1 was a session's landing of the bot's own commits.

**What the main checkout holds right now** (07:15 on 09-25, `git status --porcelain --untracked-files=all`, classified
by `Test-BotPathOwned`): 60 entries; 20 owned by the bot, **40 owned by no declared writer**: 23 untracked (16 recurring-red
`INCIDENT-*.md` reports, 3 triage plans, 2 plan drafts, 1 investigation, 1 reaper log) and 17 modified (6 weekly-audit
stamps, 2 staged code files, prompt-backup mirrors, graph eval files). Some of the 40 are written by OTHER scheduled
writers (the weekly stamps, the incident reports, the reaper log), not by sessions. **So "foreign" today means "not the
capture bot's", not "a session's"**, and any design that tells an intruder from a producer needs every producer to
declare its paths (W0.3).

**Sessions commit in the main checkout, and less since 09-23.** The main reflog since 09-16 holds 110 session commits
made on local main in the main checkout: 10 on 09-18, 22 on 09-19, 18 on 09-20, 22 on 09-21, 37 on 09-22, 0 on 09-23
and 1 on 09-24. The drop after 09-22 is when push-main learned to land from the main checkout through a throwaway
worktree (W8.2), which is also the road the 09-25 duplicate came through.

### 2.5 Q3: what the 06:30 to 09:00 window blocks

Session landings (origin reflog `update by push` entries carrying no bot commit), by day:

| Day | Session landings | In 06:30 to 09:00 | In 07:00 to 09:00 |
|---|---|---|---|
| 09-17 | 7 | 3 | 3 |
| 09-18 | 114 | 4 | 3 |
| 09-19 | 91 | 14 | 8 |
| 09-20 | 11 | 4 | 4 |
| 09-21 | 13 | 3 | 1 |
| 09-22 | 24 | 0 | 0 |
| 09-23 | 66 | 8 | 7 |
| 09-24 | 36 | 0 | 0 |
| 09-25 (to 09:06) | 4 | 0 | 0 |

- **36 of 362 session landings over 8 full days (09-17 to 09-24) fell in 06:30 to 09:00: 9.9%, mean 4.5 a day.** The
  window is 10.4% of the day, so it carries its proportional share; nothing about those hours is quiet. Bar: a real
  cost at 2 a day. **Above the bar.**
- **37 of 447 push-main runs since 09-16 started inside the window** (16 landed, 9 landed after a rebase, 5 refused on
  a red gate, 3 refused not-ready, 4 rejected).
- How long each deferred landing waited is not recorded anywhere; a landing deferred from a uniform time in the window
  waits 75 minutes on average and up to 150.

### 2.6 Q4: how often a landing during a run is a real conflict

Session landings made between a bot run's start and its end, per run (20 armed runs):

- **28 session landings happened inside a live bot run.** 7 touched a bot-owned path (25%). **1 touched a path the
  run's own commit also changed (3.6%)**: `public/smp-feed.json`, landed at 09:35 on 09-23 during the forced hand run.
  Bar: at most 5% and at most 1%. **Both fail**, on small N for the second.
- **Over every session landing since 09-16, 54 of 366 (14.8%) touched a bot-owned path.** The prefixes, by path count:
  `meal-prep/db` 113 (recipe specs and `costed.json`), `grocery/out` 54 (mostly `grocery/out/audit/match-baseline.json`),
  `graph/identity` 16, `public/smp-feed.json` 11, `grocery/product-urls.json` 9, `public/board.json` 9.
- **0 of 24 landings that carried a bot commit (31 bot commits) changed a file in the chain manifest**, the 185 files
  `ops/rehearse-chain.ps1 -ListSet` prints at `c42d0a679` (137 members, 48 dot-source closure). None changed a `.ps1`
  or `.py`; 4 changed the generated `meal-prep/cheapnow-data.js`, `dinner-data.js` or `stretcher-data.js`, which are
  served data and not in the set. So a bot push is not a chain-touching push and needs no chain-queue ticket. The set
  was read at today's HEAD, not at each landing's own commit.
  **Read again at each landing's own commit (W0.1, `ops/measure-bot-checkout.py manifest`, 2026-09-25): 3 of the 24
  landings can be judged, and 0 of those 3 touched the manifest (165 to 185 files); the other 21 are BLIND, because
  `-ListSet` lists nothing at a commit older than 09-22, before the manifest existed.** So "0 of 24" stands only as a
  reading at HEAD; at the landings' own commits it is 0 of 3 with 21 unjudgeable.

**What this means.** The ownership boundary is real but porous: sessions legitimately correct bot-owned data (money
lanes edit recipe specs and the feed). So a catch-up is mechanical 27 times in 28, and the design must keep a
conflict path for the 28th. That rules out any design that assumes the bot's paths are the bot's alone (section 5, C).

### 2.7 The diagnosis, scored

| Claim | Verdict | Evidence |
|---|---|---|
| (1) sharing the checkout stalls the sync | **Supported** | 7 of 20 armed runs stopped by it, 7 stall events in 7 days, 3 of 5 since the new sync (the other 2 by the branch) |
| (2a) sharing the branch: main moving costs rounds | **Not supported** | 1 of 16 committed runs, and that one landed on round 2 |
| (2b) sharing the branch: someone else lands or holds the bot's commits | **Supported, new** | 09-25 07:00 and 08:00: 6 patch-identical duplicates on local main; graph pushes left local 13 of 16 |
| mid-run landings rarely overlap the bot's paths | **Mostly** | 1 of 28 touched the bot commit's own paths; 7 of 28 touched some owned path |

## 3. Who reads and writes the main checkout's working files

Measured on 2026-09-25 by grepping for the absolute path and reading each consumer; nothing here is guessed. A move of
the bot out of the main checkout (designs A and B) must re-point every row. Design D re-points none.

| Reader or writer | What it touches | Evidence |
|---|---|---|
| 13 Windows tasks named `TC *` | 12 launch a script by absolute path in `C:\Codex\ThriftyCrew`: Ad Pulls 0700 and Daily Capture 0800 (`grocery\capture-run.ps1`), Graph Nightly 21:30 (`graph\pipeline\nightly.ps1`), Harvest 18:00 (`meal-prep\pipeline\harvest-crawl.ps1`), Process Reaper, Sidecar Watchdog, and 6 through `ops\run-once-a-day.ps1` (capture-watchdog, browser-slot-close, daily-ratchets, daemon-battery, brain-digest, recall-sleep `--cwd C:\Codex\ThriftyCrew --commit --push`) | `Get-ScheduledTask` actions |
| 16 Claude scheduled-agent prompts | name `C:\Codex\ThriftyCrew` (grocery-alert-triage 16 times; grocery-browser-stores-refresh 4, which starts the capture sink, writes `grocery\out\captures\*` and runs the builders that write `grocery\out\regular\*` into the main checkout for the bot to commit) | `C:\Users\Owner\.claude\scheduled-tasks\*\SKILL.md` |
| the capture sink | `grocery\capture-sink.ps1 -OutDir <absolute>`; default `<script root>\out\captures\_sink` | `Resolve-CaptureSinkOutDir` |
| seeding | `ops\seed-worktree.ps1`: source = the parent of the git common dir, which is always the main checkout; `.worktreeinclude` carries 7 patterns (the comparison boards, the eviction stamp, three feeds, the catalog digest, `published-hashes.json`); every session worktree and every `rehearse-chain` arm seeds from it | `Get-SeedSourceRoot` |
| the alert road | the Gmail credential and token, the triage queue, `alert-log.txt` and `alert-sent-<date>.txt` are main-checkout state; `lib\main-checkout.ps1` resolves the queue there; an automated send from a linked worktree is REFUSED | `grocery\alert-lib.ps1` item 4, `grocery\send-alert.ps1:296` |
| secrets | `meal-prep\.ghostkey`, `grocery\.krogerkey`, `meal-prep\db\fdc-api-key.txt`, `ops\.gsc-key.json`, all repo-relative with an env-var fallback | `git grep` |
| gitignored state that exists only here | `grocery/out` ignored set 3.7 GB (32 comparison boards, captures), `meal-prep/db` 799 MB (1,168 built cards, page cache, `published-hashes.json`, `thriftycrew.db`), `graph/sqlite` 432 MB (`graph.db`), `ops/ghost-journal.jsonl` 178 MB, `sidecar` models and venv 11 GB | `git ls-files -o -i --exclude-standard` in the main checkout, 963 entries |
| the sidecar | a service on port 8077 started from `sidecar\`; the chain reaches it over HTTP, never by path | RUNTIME-MAP |
| Cloudflare | deploys `public/**` from origin; the checkout's location does not matter | RUNTIME-MAP, the git-bus |
| Ghost publish | reads `.ghostkey` beside the script, or `GHOST_ADMIN_KEY` | `grocery\ghost-export.ps1:22` |
| tracked code naming the path | 302 tracked files, 174 outside JSON and archive. Almost all are `$PSScriptRoot` fallbacks that never fire under `-File`. Hard literals on a live road include `grocery\purge-bad-lows.ps1:22`, `grocery\publish-retry-until-live.ps1:15-16`, `grocery\build-{sams,freezer,staples}-data.ps1` (a hard root), `meal-prep\pipeline\hunt-orchestrator.js` (17), `ops\run-once-a-day.ps1` (10). A name grep of `capture-run.ps1`, `check-ad-cycles.ps1`, `nightly.ps1`, `harvest-crawl.ps1`, `capture-watchdog.ps1` and `run-daily-ratchets.ps1` finds none of the hard-root builders (`purge-bad-lows` only in a comment); scripts those six call were not walked | `git grep -i -E 'C:[\\/]+Codex[\\/]+ThriftyCrew'` |
| sessions | Brad's primary session and orchestrators work in the main checkout: 110 session commits on its local main since 09-16, and `push-main` lands from it through a throwaway worktree | main reflog, push ledger |

## 4. The rubric, written before any design was scored

Seven criteria, 0 to 5 each, the seven the brief names. Context for every score: this box on 2026-09-25, one shared
Windows main checkout on git 2.54.0.windows.1 with `core.autocrlf=true` system-wide, 163 linked worktrees, origin
moving about 9 commits an hour, and the Part 1 numbers above.

1. **Correctness under concurrent landings**: does the bot land its own data on its own run when sessions land
   mid-run, and does it resolve the 1-in-28 real overlap without silent loss?
2. **What breaks in the move, and how it is found**: how many readers and writers must be re-pointed (section 3), and
   whether a missed one fails loudly.
3. **Rollback**: how fast and how completely the old behaviour comes back.
4. **Windows file-locking behaviour**: how many processes open the bot's working files while it moves them.
5. **The gitignored data that lives only in the main checkout**: how much of it must move or be re-sourced.
6. **Cost to build**.
7. **What it does when the producer stops**: whether a stopped or stuck bot is still seen.

## 5. Four designs

### 5.1 A: a permanent linked worktree for the bot, landing through the chain queue

`git worktree add C:\Codex\tc-bot` (outside `.claude\worktrees`, so no cleanup tool prunes it), detached at origin,
with every scheduled writer re-pointed to it and landing through `push-main` (a chain-queue ticket only if a push ever
touches the chain manifest, which 0 of 24 bot landings did).

- It shares the `.git`: refs, the stash stack, the hooks, the `tc-*` records in the common dir. It gets its own index
  and its own HEAD, so the index and branch stalls go away.
- **It breaks the alert road outright.** `send-alert.ps1` refuses an automated send from a linked worktree, and
  `alert-lib.ps1` routes a linked worktree's alerts through the main checkout's sender. Every bot page would be refused
  or would read main-checkout state. Fixable, but it is a new road for the most safety-critical output.
- **Seeding reads the wrong source.** `Get-SeedSourceRoot` names the parent of the common dir, the main checkout, so
  every session would seed stale boards unless the seeder learns a second source.
- A fresh worktree is CRLF where main is LF (the store), so `golden-test` and `ghost-drift` go red on bytes until the
  worktree gets `core.autocrlf=false` through `extensions.worktreeConfig`.

### 5.2 B: a standalone production clone

`git clone` into `C:\Codex\tc-production` (its own `.git`, index, hooks, refs, `core.autocrlf=false`), with every
scheduled writer, every agent prompt, the sink, the alert credential and queue, the secrets and the gitignored state
moved to it, and `seed-worktree`, `main-checkout.ps1` and the triage agent pointed at it through one declared pointer.

- The strongest isolation: nothing outside the bot can hold its files, index, branch or stash.
- `rehearse-chain` already proves the ship path runs in a standalone clone (its arms are exactly that).
- The largest move: everything in section 3, including 5 GB of gitignored state, a second 622 MB object store (or
  alternates onto the main `.git`, which a `gc` there can break), and a day where the old and new homes can disagree.

### 5.3 C: the bot's data on its own branch or repository

The bot commits to `data` (or a data repo); readers follow it.

- The bot never contends for `main`. But **54 of 366 session landings touched a bot-owned path**, so either those
  sessions write to the data branch too or the two branches carry the same files and merge; neither is "the bot's
  paths are the bot's alone".
- Every git-bus reader moves: Cloudflare's deploy source for `public/**` (Brad-only settings), `daily.yml`,
  `compare-deals`' union over tracked captures, the seeding source, the watchdog's read of origin.
- It still needs a checkout for the bot, so it is one of A, B or D plus a branch model.

### 5.4 D: the production checkout keeps its place, and the sessions leave it

The main checkout becomes the production checkout. Only the scheduled writers write it; every interactive session,
Brad's primary session included, works in a linked worktree (today's spawned-agent rule, extended to everyone). Three
mechanisms make that true rather than hoped:

1. **A production ownership registry.** Every scheduled writer declares its paths (the capture bot already does in
   `lib/bot-paths.ps1`; graph nightly and harvest through `Get-PipelinePaths`; the weekly audits' stamps, the incident
   reports, the reaper log and the prompt-backup mirror do not yet). A dirty or untracked path in the production
   checkout that no registered writer owns is an INTRUDER.
2. **A write barrier.** A Claude Code `PreToolUse` hook (user settings, Brad's call, D3) refuses a Write, Edit or
   shell write whose target resolves inside `C:\Codex\ThriftyCrew` but outside `.claude\worktrees\`, from any session.
   Plus a `pre-commit` check refusing a non-bot commit in the production checkout. The first stops the file; the
   second stops the commit that would later be carried.
3. **An intruder policy for the sync** (D4). Registered producers' files keep today's rule: never written. An intruder
   on a path upstream changed is set aside into the dated quarantine (kept, byte-verified), the sync proceeds, and it
   pages naming the file. Today's rule, partial and wait, stays available as the kill switch position.

And two fixes that stand on their own:

4. **The sync drops a local commit that is already upstream by patch-id** (today's wedge; W0.2).
5. **Every committing scheduled writer lands the same way, under one production lock** (capture-run's mutex, level 0),
   through `push-main` from the production checkout (D5). Graph nightly and harvest stop leaving their commits for the
   next capture run to carry.

Nothing is re-pointed: the 13 tasks, 16 prompts, sink, seed source, alert road, secrets and gitignored state stay where
they are. **What breaks is a habit**: Brad's primary session and any agent that writes through an absolute path.
The barrier makes that break loud.

### 5.5 Scores

| Criterion | A: linked worktree | B: production clone | C: data branch | D: sessions leave |
|---|---|---|---|---|
| 1. correctness under concurrent landings | 4 (own index and HEAD; shares stash, hooks, refs) | **5** (nothing shared but the remote) | 3 (no contention on main, but the 14.8% overlap needs a merge between branches) | 4 (clean tree and bot-only local main once the barrier holds; the 1-in-28 overlap takes the replay path) |
| 2. what breaks in the move, how it is found | 1 (all of section 3, plus the alert refusal and CRLF; a missed reader fails quietly, reading stale files) | 2 (all of section 3; a missed reader reads a stale main checkout quietly) | 1 (every git-bus reader plus deploy settings) | **4** (nothing re-pointed; a session that writes production is refused loudly by the barrier) |
| 3. rollback | 3 (re-point back; data written in the worktree must be carried back) | 3 (same, across two object stores) | 2 (readers and deploy settings back) | **5** (remove the barrier flag; the checkout never moved) |
| 4. Windows file locking | **5** (no session opens its files) | **5** (same) | 3 (inherits A, B or D) | 3 (sessions may still READ production files, so a held file is possible; the sync's held-file recovery covers it) |
| 5. gitignored data only in main | 2 (5 GB to move, seed source to change) | 1 (5 GB to move, a second object store, seed source, alert credential) | 3 (inherits) | **5** (none moves) |
| 6. cost to build | 2 | 1 | 1 | **4** (a registry, a hook, a sync policy, a patch-id fix, one landing path) |
| 7. when the producer stops | 3 (the watchdog and floors must be re-pointed to the new home) | 3 (same) | 2 (a stalled data branch serves stale data unless readers watch it) | **4** (every floor stays where it is; one floor added: intruders per day) |
| **Total, of 35** | **20** | **20** | **15** | **29** |

**Recommendation: D.** It fixes every measured stall class (a session's file, a session's index entry, a gate over a
session's tree, a session landing the bot's commits) by removing the sessions, not by moving the bot, so it moves no
data and re-points nothing.

**What would change it:**
- **To B**: if, after two weeks of the barrier in enforce mode, intruders still reach the production checkout more
  than once a week (the barrier cannot see a process that is not a Claude session, such as Brad at a terminal or a
  tool with a hard-coded path), or if Brad does not want his primary session in a worktree. B is the design that does
  not depend on anybody's habits.
- **To C**: if the real-conflict rate (session landings touching the bot commit's own paths, during a live run) rises
  above 5% over at least 50 in-run landings, because then catch-ups stop being mechanical and a data branch with an
  explicit merge step becomes the honest shape.
- **Not to A** in any case while `send-alert.ps1` refuses linked-worktree sends; A is B with extra coupling.

## 6. Design D in detail

```
production checkout (C:\Codex\ThriftyCrew), local main belongs to the scheduled writers
  write barrier (Claude PreToolUse hook + pre-commit)   sessions: refused; scheduled writers: allowed
  ownership registry                                    every scheduled writer's paths, one declaration
  capture-run / graph nightly / harvest / push-data     all under Global\tc-capture-run (lock order 0)
    START SYNC (lib/checkout-sync.ps1, as landed)       + drop local commits already upstream by patch-id
                                                        + intruder on a moved path -> set aside, page, proceed (D4 b)
    ... captures, chain, commit (as landed) ...
    LAND (D5): push-main from the production checkout   lands through a throwaway worktree; clean gating;
                                                        catch-up outside the lock; the lock for the swap only;
                                                        local main moved by reset --keep (only the bot moves it)
    fallback: today's tail (sync, then git push)        when push-main cannot run
sessions: linked worktrees, seeded from the production checkout exactly as today
```

**Why the landing goes through push-main (D5 b).** The 09-21 refusals were `run-gates` judging the production tree's
dirty working files. `push-main -ViaWorktree` gates a clean detached copy of HEAD, catches up outside the lock, holds
the lock only for the swap, and replays recorded verdicts inside it (about 25 s, CLAUDE.md). The bot's commits are not
chain-touching (0 of 24 landings touched the chain manifest), so no ticket is taken; if one ever is, push-main takes one itself. The one hazard is the
09-24 17:35 shape (`main_sync=manual`, HEAD moved during the run, local main left behind with duplicates): under D only
the lock holder moves local main, so HEAD cannot move during its own landing, and W0.2 makes the duplicate harmless even
if it happens.

**The ownership registry, and why it comes first.** Section 2.4 found 40 dirty or untracked entries owned by no
declared writer, and some of them belong to OTHER scheduled writers. Setting aside an unregistered file is only safe
once every producer is registered, so W0.3 is a report-only census before any policy acts on it, and D4(b) switches on
only after the census reads 0 unregistered producer paths for 7 days.

## 7. What the 06:30 to 09:00 rule becomes

**Nothing, once Stage 2's bars hold.** Under D a session never touches the production checkout, so a session landing
during a bot run costs the bot one catch-up round outside the lock (a fetch and a two-way move of a clean tree: the sync
step measured 0.44 to 5.24 s) and a warm replay in the lock. The 1-in-28 real overlap takes the replay path, and if the
replay cannot merge it the sync degrades and pages, as today. **Until Stage 2's bars hold, the rule stays**, because
Stage 1 changes nothing for the bot. It is retired by a CLAUDE.md edit in W3.2, not by habit.

## 8. Work items

Every item lands through `ops\push-main.ps1` from a clean, seeded linked worktree. Each self-test follows
`.claude/rules/ops-and-gates.md`: private lock names, per-run temp paths, `Clear-TcGitRepoEnv` before any `git init`,
overlap never a wall clock, the suite's last line its verdict, a literal-case suite asserting its count.

### Stage 0: instruments and the independent fix (no behaviour change for sessions)

**W0.1 Commit the harness.** `ops/measure-bot-checkout.py` from the scratch `measure.py` and `derive.py`, with a
`--selftest` over a frozen fixture of three logs (a clean run, an untracked-blocker run, a new-sync blocked run), and
the chain-manifest check read at each landing's own commit rather than at today's HEAD. A report, never a gate. Done when
it re-derives section 2's totals from the committed rows.
**Done 2026-09-25.** `derive design/MEASURE-bot-checkout-2026-09-25.jsonl --until 2026-09-24` prints 6 of 16, 13 of
20 (7 shared checkout, 0 unattributed), 1 of 16 main moved, lag median 5,204 s over 9, 36 of 362 in the window over 8
days, 37 of 447 push-main starts, 28 in-run landings with 7 owned and 1 on the bot commit's own paths; without
`--until` it prints the 22-run and 54-of-366 figures, and the 5 of 5 new-sync row. A fresh `measure` over the live
logs agreed on every one of those (45 owned entries exported from `lib/bot-paths.ps1`). The manifest reading at each
landing's own commit is in section 2.6.

**W0.2 The sync drops a local commit that is already upstream.** File: `lib/checkout-sync.ps1`. Before replaying local
commits onto O, compute `git patch-id --stable` for each local commit and for each commit in `merge-base..O`; a local
commit whose patch-id is upstream is DROPPED (counted in the record's existing `dropped` field), never replayed.
Fixtures:
- MUST FIRE (today's founding case): local main carries a commit patch-identical to one on the fixture origin, whose
  replay would conflict on a rename/delete; the sync ends `synced`, `dropped` = 1, and HEAD equals O plus the
  non-duplicate commits.
- CLEAN TWIN: a local commit that differs from an upstream one by one byte is replayed, not dropped.
- MUST NOT FIRE: a local commit with no upstream twin is replayed exactly as today.
- Mutant: drop the patch-id step; the MUST FIRE goes red in its own named case.
This item is worth landing whatever Brad decides about D, because it is today's wedge.

**W0.3 The production ownership census (report only).** A new `ops/report-production-intruders.ps1`: classify every
`git status --porcelain --untracked-files=all` entry of the main checkout as owned by a declared writer (the capture
bot through `Test-BotPathOwned`, the lanes through `Get-PipelinePaths`, and new declarations for the weekly stamps,
the incident reports, the reaper log and the prompt-backup mirror) or UNREGISTERED. Writes one row a day; the capture
watchdog prints the count. Read branches `bot-paths-graph-tracked-writers` and `fix/bot-paths-restore-lane-state` first.
Done when a week of rows exists and every unregistered path names its writer or is a session's.

### Stage 1: sessions leave, in warn mode (the bot is unchanged)

**W1.1 The write barrier, WARN.** A `PreToolUse` hook script under `ops\hooks\claude\` (installed into user settings
only with Brad's yes, D3) that resolves each Write, Edit and NotebookEdit target, and each Bash or PowerShell command's
redirection targets it can read, and WARNS when the target is inside the production checkout and outside
`.claude\worktrees\`. It never refuses in Stage 1. A `pre-commit` addition WARNS on a non-bot commit made in the
production checkout. Both write one row per warning. Fixtures: MUST FIRE a Write to `C:\Codex\ThriftyCrew\lib\x.ps1`
from a session warns; MUST NOT FIRE a Write inside `.claude\worktrees\<name>\`; MUST NOT FIRE the capture bot's own
commit (author `smp-pipeline-bot` or `TC_BOT_COMMIT=1`, the test `ops/verify-bot-commit-scope.ps1` already makes with
`Test-IsBotCommit`); CLEAN TWIN a relative path
inside a worktree still resolves to the worktree.

**W1.2 Brad's primary session moves to a worktree** (D2). Not code: the desktop session starts in a named linked
worktree, and the CLAUDE.md "Spawned agents run in worktrees" rule becomes "every session runs in a worktree; the main
checkout is production".

### Stage 2: enforce, and one landing path

**W2.1 The barrier refuses.** The same hook in block mode, with the message naming the worktree to use. Kill switch:
`.git\tc-production-barrier.disabled` puts it back in warn mode, and the watchdog pages daily while the file exists.

**W2.2 The intruder policy (D4).** `lib/checkout-sync.ps1`: a dirty or untracked path on a moved path that the W0.3
registry says no scheduled writer owns is set aside into `grocery/out/untracked-quarantine/<date>/<HHmmss>-sync/`
(ignored since `73eec5dd0`, kept, verified by bytes before the move), and the sync proceeds. A registered producer's
dirty file keeps today's rule. Kill switch: the registry file's `intruder_policy` field, `wait` restores today exactly.
Fixtures:
- MUST FIRE (09-24 09:00's shape): an untracked `lib/chain-queue.ps1` at a path upstream adds; the sync moves it aside,
  the copy is byte-identical, the outcome is `synced`, and it pages naming the path.
- MUST FIRE (09-24 16:38's shape): a staged edit to a code file upstream changed; set aside with its index entry
  recorded, `synced`.
- CLEAN TWIN: a weekly stamp its registered audit wrote, on a moved path, is never moved; the sync goes partial as today.
- MUST NOT FIRE: with `intruder_policy = wait`, the first case goes `blocked/foreign` exactly as today.

**W2.3 One landing path under one lock (D5, D6).** `grocery/capture-run.ps1`'s tail, `graph/pipeline/nightly.ps1` and
`meal-prep/pipeline/harvest-crawl.ps1` land through `push-main` from the production checkout while holding
`Global\tc-capture-run` (lock order 0, which already nests over the push lock). The old tail stays as the fallback
when push-main cannot run. First nested acquisition of the capture-run mutex from graph nightly and harvest, said in
the commit. Fixtures, over a temp bare remote, a fixture production clone and a fixture session clone:
- MUST FIRE (a code landing mid-run): the bot commits; the session clone pushes a code change to a non-owned path; the
  bot lands on its own run in at most 2 rounds, and every foreign fingerprint is unchanged. Counted in rounds, never
  seconds.
- MUST FIRE (a bot-path conflict): the session pushes an edit to a file the bot commit also changed; the replay gives
  the documented winner (the bot's bytes under `-X theirs`), and a modify/delete ends `degraded` and pages, never
  silent.
- MUST FIRE: graph nightly's commit lands on its own run instead of `left local`.
- CLEAN TWIN: a run whose push-main refuses falls back to the tail and pushes as today.
- Mutants: replay under `-X ours`; land without the mutex; each red in its own case.

### Stage 3: retire the rule

**W3.1 Read Stage 2's bars** with W0.1's harness, 14 days after W2.3.
**W3.2 Retire the 06:30 to 09:00 rule** in CLAUDE.md and every orchestrator brief template, only if the bars hold.

## 9. Staged rollout and kill switches

| Stage | Changes | Kill switch | Degrades to |
|---|---|---|---|
| 0 | W0.2 fix, two reports | revert W0.2 | today exactly |
| 1 | barrier and pre-commit WARN; Brad's session in a worktree | uninstall the hook | today exactly |
| 2 | barrier REFUSES; intruder policy; one landing path | `.git\tc-production-barrier.disabled` (warn), `intruder_policy = wait`, capture-run `-NoPushMain` | Stage 1, then today |
| 3 | the window rule retired | re-add the CLAUDE.md line | Stage 2 with the rule |

Every switch degrades to the day before and none of them refuses anything, which is the estate's lock rule applied to
a process change.

## 10. Bars, written now

Measured by W0.1's harness, cited by its blob, over armed capture runs after the named item lands. First plausible
values, not the survivors of a sweep; the baselines are one week, so a number that moved is not yet a number that
improved.

| # | Metric | Minimum N | Baseline (section 2) | Bar | Item |
|---|---|---|---|---|---|
| B1 | armed capture runs whose data lands from their own run | 20 | 7 of 20; 0 of 5 on the new sync | at least 18 of 20 | W2.3 |
| B2 | stall events caused by a non-producer's file, index entry or branch state | 14 days | 7 in 7 days | 0 | W2.1, W2.2 |
| B3 | `degraded/replay` outcomes caused by a patch-identical local commit | any | 4 (09-25 07:00 and 08:00, start and tail) | 0 (deterministic) | W0.2 |
| B4 | graph nightly commits that land on their own run | 14 | 3 of 16 | at least 13 of 14 | W2.3 |
| B5 | median seconds from a bot commit to its landing, over runs with at least one session landing mid-run | 10 | not measurable today (0 such runs landed on their own) | at most 300 s | W2.3 |
| B6 | session writes into the production checkout the barrier admitted (W0.3's unregistered count, session-owned) | 14 days | 40 unregistered entries on 09-25, writer not yet split | 0 new per day in enforce mode | W2.1 |
| B7 | real conflicts: in-run session landings touching the bot commit's own paths | 50 in-run landings | 1 of 28 | reported, never judged; above 5% sends the design back to Brad (section 5.5) | - |

## 11. Blast radius and rollback

**Stage 0** changes one function in `lib/checkout-sync.ps1` (W0.2) and adds two reports. Worst case: a commit wrongly
judged a duplicate is dropped from the replay. Its content is already upstream by patch-id, and the dropped sha stays
in the reflog, so nothing is lost.

**Stage 1** changes nothing the bot does. Sessions see warnings.

**Stage 2** is the one with reach. Sessions: a write into the main checkout is refused with a message naming the
worktree to use; nothing already on disk is touched by the hook. The bot: an intruder file on a path upstream changed
is moved aside into the dated quarantine, kept and byte-verified, where today the bot would wait; a session that left
work there finds it in the quarantine directory named in the page. Graph nightly and harvest wait for the capture-run
mutex (at most one run; they are hours apart in practice). The landing path changes from a plain push to push-main.

**Rollback, cheapest first:** the barrier's disable file (warn mode); `intruder_policy = wait`; capture-run's
`-NoPushMain` (the old tail); uninstall the hook; revert W2.3, then W2.2, then W0.2. Nothing in design D moves data, so
no rollback copies anything back.

## 12. What the earlier plans decided, and what this plan keeps or reverses

**`PLAN-bot-checkout-self-heal-2026-09-23.md`:**
- KEEPS the one mover (`read-tree -m -u` plus the `update-ref` compare-and-swap), the start sync, the re-exec, the size
  gate's carry records, the kill switch, the floors, and G3 (*"never write a FOREIGN dirty file"*) for every
  REGISTERED producer.
- NARROWS D2(a) (partial sync for a foreign dirty file) to registered producers only, if Brad takes D4(b). An
  unregistered file in the production checkout is set aside instead of waited on. The self-heal plan wrote D2 for a
  checkout sessions share; D is a checkout they do not.
- ADVANCES D8 (convert graph nightly, harvest and push-data to the same mover) from "after this plan's bars pass for 14
  days" to Stage 2, because those bars cannot pass without it: B1b reads 1 of 5, and graph pushes are left local 13
  times in 16.
- REVERSES "the tail stays the only pusher" (section 9) if Brad takes D5(b); the tail stays as the fallback.
- Adds the patch-id drop its section 14 did not foresee (*"`merge-tree -X theirs` parity beyond one same-line
  conflict"* was owed; today's rename/delete on a patch-identical commit is the case).

**`PLAN-push-derived-conflicts-2026-09-23.md`:**
- KEEPS design A (lock only the swap, the chain queue, the in-lock verdict check) and W8.2 (landing from the main
  checkout through a throwaway worktree), used now by the bot.
- NARROWS W8.2 to the production checkout's own writers: under D no session runs push-main from there, which removes
  the 09-24 17:35 case (a session landing the bot's unpushed commits, `main_sync=manual`).
- W8.3's blast-radius note (*"A bot push carrying an unpushed session chain commit is refused while a lease is held"*)
  disappears: no session commits on the production branch.
- No chain-queue ticket for bot pushes: 0 of 24 bot landings changed a file in the 185-file chain manifest.

## 13. Decisions only Brad can make

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | Which design | A linked worktree, B production clone, C data branch, D sessions leave the main checkout | **D** (29 of 35 against 20, 20 and 15), with B as the named fallback (section 5.5) |
| D2 | Where your primary session works | (a) a named linked worktree, the desktop app's worktree mode; (b) stay in the main checkout | **(a).** Every measured stall came through a session's file in the main checkout, and 110 session commits were made there since 09-16 |
| D3 | The write barrier, a Claude Code hook in your user settings | (a) install it, warn for a week then block; (b) warn only; (c) no hook, rule text only | **(a).** A rule in a file is not a block; section 2.4 is what the rule text alone produced |
| D4 | What the sync does with an unregistered file on a moved path | (a) today: partial or blocked, and page; (b) set it aside into the dated quarantine, page, and proceed | **(b)**, switched on only after W0.3 reads 0 unregistered producer paths for 7 days; (a) stays as the switch position |
| D5 | How the bot lands | (a) its own tail, sync then `git push`; (b) `push-main` from the production checkout, the tail as fallback | **(b).** It gates a clean copy (09-21's four refusals were gates over the dirty tree) and holds the lock only for the swap |
| D6 | One lock for every committing scheduled writer | (a) graph nightly, harvest and push-data take `Global\tc-capture-run`; (b) leave them unlocked | **(a).** It is already lock level 0 and already nests over the push lock |
| D7 | The 06:30 to 09:00 rule | (a) retire it after Stage 2's bars hold; (b) keep it | **(a).** It defers about 4.5 landings a day and protects against a cost that 1 committed run in 16 paid |
| D8 | W0.2, the patch-id drop, ahead of any ruling on D1 | (a) now; (b) with D | **(a).** It is today's wedge and stands alone |

### 13.1 Rulings (Brad, 2026-09-25)

Brad's words, verbatim: on D1 to D7, *"Adopt D with all its recommendations (Recommended)"*; on D8, *"Yes, now
(Recommended)"*. Taken together, each decision above is ruled as its recommendation:

| # | Ruled | What it binds |
|---|---|---|
| D1 | **D**, with B (the standalone production clone) as the named fallback | the main checkout becomes the production checkout, written only by scheduled jobs; section 5.5's "what would change it" stays the trigger for B or C |
| D2 | **(a)** | Brad's primary session moves to a named linked worktree; every interactive session works in one (W1.2) |
| D3 | **(a)** | the write barrier is a Claude Code hook in user settings; it WARNS for a week, then BLOCKS (W1.1, then W2.1). It ships warn-only under procedure P1 of `design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md` section 4.4 |
| D4 | **(b)** | the stray-file quarantine switches on only after W0.3's ownership list reads 0 unregistered producer paths for 7 clean days; `intruder_policy = wait` (today's rule) stays as the switch position (W2.2) |
| D5 | **(b)** | the bot lands through `push-main` from the production checkout, with its own sync-then-push tail kept as the fallback (W2.3) |
| D6 | **(a)** | one lock, `Global\tc-capture-run` (lock order 0), for every committing scheduled job: graph nightly, harvest and push-data take it (W2.3) |
| D7 | **(a)** | the 06:30 to 09:00 rule stays until Stage 2's bars (section 10) hold, then retires by a CLAUDE.md edit (W3.2) |
| D8 | **(a)** | W0.2 now, ahead of the rest; it is being landed by a sibling session in `lib/checkout-sync.ps1`, not by this plan's builder |

## 14. Evidence register

| Harness or input | Blob or location | Result |
|---|---|---|
| `measure.py` (scratch, session scratchpad `botcheckout\`) | `533667d592b0` | `MEASURE-COMPLETE`, exit 0 |
| `derive.py` (scratch) | `8a232cb13938` | `DERIVE-COMPLETE`, exit 0 |
| `botcode.py` (scratch) | `878a93285b60` | `BOTCODE-COMPLETE landings-with-bot-commits=24 with-code-paths=4` (all four generated data `.js`) |
| `botmanifest.py` (scratch) over `ops/rehearse-chain.ps1 -ListSet -Commit HEAD` (rc 0) | `402c13123022` | `BOTMANIFEST-COMPLETE manifest_files=185 landings=24 bot_commits=31 landings_touching_manifest=0` |
| the rows | `design/MEASURE-bot-checkout-2026-09-25.jsonl`, blob `c46b20bcdb6e`, written by `commit_rows.py` `66e3012497a1` (every row kept; a landing keeps its full path list only when it fell inside a live run) | one row per run, landing, push-main row and sync row |
| the owned set | `lib/bot-paths.ps1` blob `86587b43`, `lib/pipeline-commit.ps1` blob `d279509b` | 45 entries |
| harness base | origin/main `c42d0a679` | |
| the committed harness (W0.1) | `ops/measure-bot-checkout.py` blob `c7232110e39e`, folding `measure.py`, `derive.py`, `commit_rows.py` and `botmanifest.py` | `--selftest` 20 of 20, exit 0; `derive --until 2026-09-24` over rows blob `c46b20bcdb6e` re-derives section 2; `manifest` exit 3, `landings=24 touching_manifest=0 blind=21` |
| patch-identity of today's duplicates | `git show <sha> \| git patch-id --stable` | `447b42efe` = `7e70f5fae`, `c574142d3` = `e839c8ad2`, `1e0cb20b9` = `8b98eb49e` |
| the 09-21 refusals | `%TEMP%\tc-prepush-181009.log`, `-181914`, `-181971`, `-181993` | `RUN-GATES-COMPLETE pass=451 fail=3` to `pass=450 fail=5` |
| the 09-24 17:35 landing | push ledger `pushes-2026-09-24.jsonl`, `2026-09-24T22:35:50Z`, `via_worktree=true`, `main_sync=manual`, 6 subjects, a Claude host session | |

## 15. Deliberately not done

- **Today's repair.** Local main carries 6 duplicates and the staged `audit-lane-shape.ps1` still blocks. This plan is
  read-only on the main checkout; the repair is the orchestrator's (W0.2 is the lasting half).
- **The three code defects of 09-20** are fixed (cc053f374) and are not a checkout question.
- **The commit refusals of 09-22 and 09-23** are the self-heal plan's (carry records, W2.2 there), not this one's.
- **Moving the sidecar, the models or the venv.** They are a service the chain reaches over HTTP.
- **Who wrote each of the 40 unregistered entries.** W0.3 answers it; guessing it here would be a number nobody measured.
