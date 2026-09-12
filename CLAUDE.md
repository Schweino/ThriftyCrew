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

**Exit 0 = passed. 1 = at least one gate failed. 3 = could not evaluate**, which means discovery is
broken, not that the tree is clean. Never read 3 as a pass. (The recipe battery uses exit 2 for its
own could-not-run - check which tool you actually ran.)

**The 10 machine-wide gate worker slots are a QUEUE, served in arrival order** (`lib/gate-slots.ps1`, since
2026-09-11): a refusal with 3 means the queue itself stopped moving for 20 minutes, never that your run lost a
race. A run that exits 0 records its verdict for the exact content it judged, so **a manual `run-gates` followed
by a push no longer pays twice** - the hook prints the recorded pass and dispatches nothing (`-NoReuse` runs them
anyway, and a red run over that same content withdraws the pass). And a push the remote will reject anyway,
because main moved while it waited, is refused in seconds instead of after the whole run: rebase and push again.

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
- **A ~07:00 bot commits the whole tree daily** with an autoStash rebase that rewrites uncommitted
  files. Only rebase when `origin/main` actually moved; autostash restores content, not the index.
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
  it did not control. The tool takes its cores from the same machine-wide pool of 10 that `run-gates` uses
  (`lib/gate-slots.ps1`), refuses more than that or longer than 15 minutes, and its burners die with it.
  `ops/audit-cpu-load.ps1` fails a committed script that starts burners any other way. A scratch script is
  out of any gate's reach, so there the rule is the whole prevention.
