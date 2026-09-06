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

`ops/run-gates.ps1` is the change-time gate and runs on every push.

**Exit 0 = passed. 1 = at least one gate failed. 3 = could not evaluate**, which means discovery is
broken, not that the tree is clean. Never read 3 as a pass. (The recipe battery uses exit 2 for its
own could-not-run - check which tool you actually ran.)

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
- Comparison boards are rebuilt daily, so a fresh correction in `known-wrong.json` is red on purpose
  until the next build.

## Standing rules for anything that ships

- No em dashes. Brad's voice. No fabricated numbers - ever.
- Any page whose layout changed gets the 375px mobile check: no horizontal scroll, nothing crushed.
- Never bypass or weaken a gate to get something through. Fix the cause.
- A measurement is not a look: when you change something visual, screenshot it and read the words.
- When a defect recurs, the durable fix is a memory, a gate or a command - not just the repair.
