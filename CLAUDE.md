# Thrifty Crew

A live, paid membership site (thriftycrew.com, Ghost-hosted) run by one person. Three products
share one estate: **52 weekly money lessons** for parents teaching teens, a **weekly grocery deals
board** priced across seven Omaha stores, and **meal-prep recipes** costed off that board.

Because it is live and paid, a wrong number on a page is a real cost to a real reader. Accuracy
beats reassurance: understating is exactly as wrong as overstating.

## Orientation

- `docs/RUNTIME-MAP.md` is the architecture document. **Read it before reasoning about runtimes.**
  It documents the git-bus - which runtime writes a file that another reads through the repo - and
  it corrects several claims that were confidently wrong the first two times they were written.
- A TypeScript/D1/R2 platform ("V3"/"V4") was built and deleted in Aug 2026. **Deleting the code did
  not delete the Cloudflare estate**: D1, R2 buckets, Workflows and a live Ghost Admin key still
  exist and one frozen route still answers 200 with stale prices. Anything pointed back at it gets
  confidently wrong numbers. The estate is declared in `ops/cloudflare-estate.json`.
- Before writing a file write, walk, lock, native call or helper-shaped function, run
  `C:/Codex/Python312/python.exe C:/Users/Owner/.claude/skills/knowledge-search/search.py --estate "<3-6 words>"`.

| Where | What |
|---|---|
| `grocery/` | Deal capture, per-store pulls, the comparison board, price tables |
| `meal-prep/` | Recipes, the food DB, costing, the Recipe Hunter pipeline |
| `graph/` | Identity graph, provenance, learning state |
| `ops/` | Gates, audits, hooks - the machinery that keeps the rest honest |
| `content/`, `site/`, `public/`, `worker/` | Published copy and delivery |
| `design/` | Plans and specs. Several are ratified rulings, not drafts. |

## The gate

`ops/run-gates.ps1` is the change-time gate, and **a `pre-push` hook runs it on every push**
(installed by `ops/install-hooks.ps1`, asserted live by `ops/audit-hook-installed.ps1`). It runs ONCE
per push, not once per commit. **`git push --no-verify` is the deliberate, loud bypass.**

**This was NOT true between 2026-08-11 and 2026-09-09**, and this file asserted it anyway. `gates.yml`
went `workflow_dispatch`-only when Actions minutes were exhausted, no hook existed, and no task called
it - so for a month a push was gated exactly as much as the person pushing chose to gate it. The cloud
workflow is still dispatch-only; the hook is what restored the property, locally and for free.

**Exit 0 = passed. 1 = at least one gate failed. 3 = could not evaluate**, which is never the tree being
clean. **A 3 HAS SIX CAUSES and you read WHICH from the gate's own `blind=` token**, never from a habit:
discovery broken (`blind=no-selftests`, `blind=selftest-discovery-collapsed`); no gate worker slot inside
the wait, which is contention on this box and nothing wrong with your checkout (`blind=no-gate-worker-slot`);
a push the remote has already moved past (`blind=push-cannot-land`, rebase and push again); a pool that
returned a different count than it dispatched; a self-test that exited 0 without printing its OWN verdict
as its last words (2026-09-11: a verdict glued onto a case line let pull-grocery-ads fall through to a live
pull and score ok for hours); or a static gate that exited 0 while its own marker said it READ NOTHING
(`blind=static-scanned-zero`, since 2026-09-23: `audit-readjson-inline-wrap` walked zero files from every
worktree for two days and scored ok; the gates are named on run-gates' COULD NOT EVALUATE line, and an entry
whose empty set is a real answer declares `zero_ok = $true` with its reason). `pre-push` reads that token and
names the cause in its refusal - until 2026-09-12 it said "discovery is broken" for all five, which on a busy
box sent the pusher to debug a walk that was fine. Never read 3 as a pass, whichever cause it names and even
when it names none. (The recipe battery uses exit 2 for its own could-not-run - check which tool you actually ran.)

**The 24 machine-wide gate worker slots are a QUEUE, served in arrival order** (`lib/gate-slots.ps1`, since
2026-09-11; Brad set the budget at 10 that day and raised it to 24 on 2026-09-12 in 39be9900e): a refusal
with 3 means the queue itself stopped moving for 20 minutes, never that your run lost a race. A run that exits 0 records its verdict for the exact content it judged, so **a manual `run-gates` followed
by a push no longer pays twice** - the hook prints the recorded pass and dispatches nothing (`-NoReuse` runs them
anyway, and a red run over that same content withdraws the pass). And a push the remote will reject anyway,
because main moved while it waited, is refused in seconds instead of after the whole run: rebase and push again.

**ONE PUSH AT A TIME ON THIS BOX, and `ops\push-main.ps1` is how you land one** (2026-09-11). A push is a
compare-and-swap whose critical section is the whole hook, so on a busy day the slowest push never lands however
green its gates are: measured over 11 consecutive attempts from one session, `run-gates` passed every time and every
one was rejected with *"cannot lock ref"* while others landed every 15 to 25 minutes. That is why there is a
machine-wide push lock. **A plain `git push` still works and is still fully gated**, but it takes the lock only after
git has fixed its refs, so a long queue can still leave it stale and refused in seconds with "rebase and push again".
It weakens nothing - push-main runs a plain `git push` at the end, and a red gate refuses it like any other. **A lock
that cannot be taken is never a refusal**: the hook says so and pushes on, gated exactly as before.
`design\MEASURE-push-lock-2026-09-11.md`.
**From the MAIN checkout, `ops\push-main.ps1` lands through a throwaway worktree by itself** (W8.2 of
`design\PLAN-push-derived-conflicts-2026-09-23.md`): the main checkout is always dirty, so push-main there was refused
16 of 16 times since 09-16 and it landed only by plain push, which races the whole hook. It now runs the whole sequence in
a detached worktree of HEAD, never rebases the main checkout, and then moves local main to the landed tip with
`git reset --keep` when HEAD is still where the run found it (dirty and untracked files untouched), or prints the one
command to run. Like any push it lands the whole branch. A plain push is the fallback, and it is still fully gated.

**What push-main does now** (since 2026-09-23, `design\PLAN-push-derived-conflicts-2026-09-23.md`). It rebases before
it gates, and it re-checks what moved before it takes the lock:
1. **Pre-flight, in seconds, before any gate.** Fetch and rebase onto origin/main. A conflict is refused right there
   with the conflicted files named. So is a dirty tree (it lists the paths and says whether they were there at the
   start or appeared while the gates ran), a branch that is already on main, and a second push-main in the same
   checkout. Then it seeds the checkout, so the gates never run on stale boards or cards.
2. **The gates run outside the lock**: run-gates, test-auditors and, for a chain change, the chain rehearsal.
3. **Catch-up, still outside the lock.** One fetch after the gates. If main moved, rebase there and re-run only what the
   move touched. At most 3 rounds. The rehearsal gets a budget of 3 rounds that actually rehearsed, and past it the push
   is refused `refused-rehearsal-churn` (Brad's D11a), because the hook never rehearses and would refuse it anyway.
4. **The lock is held for the swap only.** Inside it: fetch. If main has not moved, push, and the hook replays the
   verdicts already earned (about 25 seconds). If it moved, hand the lock back, rebase outside, re-run warm, and come
   back. After 3 hand-backs it rebases inside the lock as before. That cap is never a refusal.

A rebase refuses on a real conflict. It never guesses at one. **Two rules go with it** (W7.1a):
- **Run board steps, guards and reconcilers in a scratch clone, never in the checkout you land from.** A lane's own
  `reconcile-ghost-drift` rewrote `grocery/ghost-tool-published.json` while its gates ran, and the push was refused
  for a dirty tree it had made itself.
- **Land a chain change only through `ops\push-main.ps1`, never `git push origin HEAD:main`, and say so in every
  orchestrator brief.** 6 of 17 chain landings after the rehearsal gate went round push-main, all from one
  orchestrator whose briefs said `git push origin HEAD:main`, and one of them voided a rehearsal another push was
  counting on.

**The rest landed the same day (2026-09-24)**, each under its Plan id on `git log origin/main`:
- **Commit-time rehearsal** (W9.1, D19 ruled yes). `ops/hooks/post-commit` starts `push-main -Prepare` in the
  background on a session commit that changes the chain, and `-Prepare` starts the rehearsal of HEAD rebased onto
  origin as it stands at commit time, so the push usually finds its verdict already recorded. It never fails or holds
  a commit. The rebase is the design: over 23 chain landings on 2026-09-23, a rehearsal of the commit as made would
  have covered 6 (26%), and of the commit rebased 10 (43%), against a bar of 30% set before the run. The row's
  `early_hit` says whether the push's verdict came from such a rehearsal.
- **The rehearsal starts beside run-gates** (W9.3), and a red gate stops it instead of waiting up to about 14 minutes.
- **The chain queue** (W9.2). A chain push takes a ticket and is rehearsed stacked on the tickets ahead of it, so one
  chain landing no longer voids the next. It waits for its turn to SWAP, never to gate. It replaces the chain lease,
  which was never built. `-ChainQueue off` is the rollback.
- **The pre-push queue check** (W8.3). While a ticket is live, a chain push that is not the queue's head is refused in
  seconds with `cause=chain-queue` and told to use push-main.

**Superseded, kept so the numbers keep their context:** until 2026-09-23 push-main took the lock BEFORE its fetch and
rebased inside it, and before 2026-09-12 the hook held the lock across the whole gate. Neither is true now; the hook
takes it for the ref update only. And the lock once bound only checkouts that had their own `ops\hold-push-lock.ps1`:
measured on the very push that shipped it, 379 gates green, rejected anyway by a checkout that had not caught up.
Since 2026-09-12 the hook falls back to the main checkout's copy.

**THE GATE MUST NOT RUN INSIDE THE LOCK** (Brad, 2026-09-12). It did until that morning, and the arithmetic is the
whole story: the lock serialises pushes machine-wide, so with a ~10-minute gate inside it the box lands about SIX
pushes an hour however many sessions are working. Measured at 08:20 that day with seven sessions pushing: **9 git
pushes queued, the oldest waiting 47 minutes, ZERO run-gates processes running on a 32-core box**, and one session's
own log reading `RUN-GATES-COMPLETE pass=387 fail=0` then `push lock - held after waiting 1,002s` then *"cannot lock
ref"* - it came out of a 17-minute queue holding a base main had moved seven commits past. The ref update itself
takes **2 seconds**. Serialising the PUSH costs nothing because `refs/heads/main` is serialised already; serialising
the GATE costs everything, because gating is the part that parallelises and `lib\gate-slots.ps1` already bounds it (at
24 since 2026-09-12, 10 when this was written). So `push-main` gates first, unlocked, and the hook's run inside
the lock is WARM - the whole verdict replays when the rebase changed nothing, and the per-gate input keys re-run only what the rebase actually touched. **A red gate
now never enters the queue at all**, where before it took the lock, ran its full set and blocked every other session
before refusing. **Since 2026-09-23 the lock holds the swap and nothing else**: no rebase runs under it unless main
moved three times running, so the hook's warm run inside it is a replay. **No lock is held across a gate, and nothing
planned needs one.** The chain lease proposed on 2026-09-23 would have, and it needed a named exception to this ruling;
Brad chose design A instead the same evening, so the lease was never built and the exception is withdrawn. The chain
queue that replaces it waits for a turn to swap, which `refs/heads/main` serialises already, and
never holds up anyone's gate. The ordering is fixtured on the MECHANISM: the self-test's gate probes the lock FROM ANOTHER PROCESS,
because a Windows mutex is reentrant on its owning thread and the first version of that case, probing in-process,
SURVIVED the mutant that hoists the lock back above the gate. Paired 3 rounds after the fix: mutant killed 3 of 3 in
its own named case, original passed 3 of 3.

**A checkout with no built cards is SEEDED on its first push, and a gate that still cannot look says BLIND**
(2026-09-11). `meal-prep/db/built` is gitignored and `.worktreeinclude` structurally cannot carry it, so
`feed-covers-published` and `wave-preaudit` used to FAIL an unseeded worktree - after it had queued for a slot,
and for a reason that said nothing about the change being pushed. Measured that day: 31 of 106 worktrees had no
card, and 18 of 53 failed gate runs failed on nothing else. The hook now runs `ops/seed-worktree.ps1` once when
the cards are missing; if seeding cannot run, those cases report BLIND and run-gates names them, because a
could-not-look is never a failure and never a pass.

It deliberately runs only what is hermetic: every `-SelfTest` in the tree, plus the static-analysis
detectors that read source rather than data. Each self-test drives a frozen must-fire fixture of a
founding bug and its clean twin, so it fails loudly when a fix stops detecting the thing it exists
for. Data-dependent audits stay in the daily chain against a real board.

## What makes results here untrustworthy

- **The boards are gitignored.** `grocery/out/comparison-*.json` is not in git, so a clean checkout,
  a CI runner or a worktree has no board. `run-gates` and every data audit are BLIND there, and the
  pricing engines exit 0 having priced nothing. A green run off-main proves nothing.
- **A fresh checkout is CRLF; main is LF.** golden-test and ghost-drift go red over bytes, not drift.
- **The ~07:00 and ~08:00 bots bring the main checkout to origin/main with a two-way move at the start and
  end of every run** (`lib/checkout-sync.ps1`): no stash, no rebase. A dirty file of yours on a path upstream
  changed is never written: the sync goes partial and pages, and **the bot's push waits until that file is clean**
  (the old tail pushed anyway). Kill switch: `.git\tc-checkout-sync.disabled`; a hand run's `-NoSync` commits but
  never pushes, and pages.
  (Until 2026-09-23 the tail was an autostash rebase that rewrote uncommitted files and dropped staging;
  `design/PLAN-bot-checkout-self-heal-2026-09-23.md`, D7.)
- **Spawned agents run in worktrees** and must write through repo-relative paths only. Writing to an
  absolute `C:\Codex\ThriftyCrew` path corrupts the main tree under a concurrent session.
- **UNPUSHED IS NOT PRIVATE. A commit you are not ready to push does not go on `main`** - put it on a
  branch or leave it uncommitted. `git push` sends the WHOLE BRANCH, and this checkout is worked by
  several sessions and scheduled tasks at once, so the next one to push ships your commits with theirs,
  without reading why you kept them back and without re-running the gate on your behalf. **Measured
  2026-09-09**: two commits were held because `run-gates` was red, the hold was written down, and
  another session's push at 12:04 shipped both - and it would have shipped them identically if the
  change had been the wrong one. The state is one command, `git log origin/main..HEAD --oneline`, and
  it wants no script: I wrote one, and `audit-guard-contract` called it DEAD while `audit-script-census`
  called it uncensused, both correctly - a detector with no production caller is one nobody runs.
  **The habit is the whole prevention. There is nothing here to automate.**
- **A SIBLING MAY ALREADY HOLD THE FIX, on a branch nobody pushed**, and `main` matching `origin/main` says
  nothing about the hundred worktrees beside it. Before building, run `git log --all --oneline -- <file>`.
  **Measured 2026-09-11**: seven commits on seven branches carried the same two-line `pull-grocery-ads` fix and
  four sessions had each written a detector for that one line, none of it pushed, while the brief for a fifth
  session said the fix had shipped. That fifth session then built nothing and spent its afternoon comparing the
  four, which was the cheap outcome; the expensive one is four more copies. When the same hour produces two
  rival versions, the tie is broken by running both over one case list, not by whichever session pushes first.
- Comparison boards are rebuilt daily, so a fresh correction in `known-wrong.json` is red on purpose
  until the next build.

## Standing rules for anything that ships

- No em dashes. Brad's voice. No fabricated numbers - ever.
- Any page whose layout changed gets the 375px mobile check: no horizontal scroll, nothing crushed.
- Never bypass or weaken a gate to get something through. Fix the cause.
- A measurement is not a look: when you change something visual, screenshot it and read the words.
- When a defect recurs, the durable fix is a memory, a gate or a command - not just the repair.
- **Deliberate CPU load goes through `ops/cpu-load.ps1`** - never hand-rolled burners, never `run-gates` in
  a loop (Brad, 2026-09-11). This 32-processor box is shared by every session and every push's gate, and on
  that day four sessions' own load tests held it at 100% for over an hour while each recorded a load level
  it did not control. The tool takes its cores from the same machine-wide pool of 24 that `run-gates` uses
  (`lib/gate-slots.ps1`), refuses more than that or longer than 15 minutes, and its burners die with it.
  `ops/audit-cpu-load.ps1` fails a committed script that starts burners any other way. A scratch script is
  out of any gate's reach, so there the rule is the whole prevention.
