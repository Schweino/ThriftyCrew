# Restructure: `C:\Codex\income` -> `C:\Codex\ThriftyCrew`

Plan of record, written 2026-08-15. Destination when the tree is clean: `design\MASTER-PLAN-RESTRUCTURE.md`.

**Why this exists.** The repo is still named `income` from the Simple Money Playbook era, 46 files sit loose at
its root, the Claude agent and skill estate lives in three separate roots with none of the skills versioned,
and real Thrifty Crew content (Ghost config backups, 1,072 rendered videos) lives outside the repo entirely.
This consolidates all of it under one project root without disturbing the git-bus described in `RUNTIME-MAP.md`.

**Governing constraint.** `RUNTIME-MAP.md` defines the git-bus: files one runtime writes and another reads
*through the committed repo*. The Cloudflare Worker deploys from git, and `wrangler.jsonc` resolves
`"main": "worker/index.js"` and `"assets": "./public"` relative to the repo root. **Moving `public\` or
`worker\` breaks the live feed.** The top of the tree therefore stays conservative; cleanup happens where the
mess actually is.

---

## Measured scope

| Item | Count |
|---|---|
| Tracked files total | 4,650 |
| `meal-prep\` + `grocery\` | 4,382 (94.2%) |
| Tracked files loose at repo root | 46 |
| Hardcoded `C:\Codex\income` paths | 238 occurrences across 149 files |
| Windows scheduled tasks with absolute paths | 6 |
| Git worktrees registered | 41 (38 prunable, 3 live) |
| Claude agents / skill files, unversioned | 12 agents, 52 skill files (42 `.ps1`) |
| Live credentials inside `skills\` | 6 |

---

## Stage 0: Pre-flight

Nothing below is safe while the pipeline can fire. `push-data.ps1` ends in `git add -A`, so a half-finished
move during the 8:30am run commits chaos.

### 0.1 Freeze

Disable, do not merely wait out, all six tasks:

```
SMP Bakers Daily Scan
SMP Daily Facebook Reel
SMP Family Fare Term Sweep
SMP Friday Email (draft)
SMP Grocery Daily Pipeline (local)
SMP Grocery Failure Watchdog
```

(`SMP Wake For Grocery Agents` only writes a wake log and carries no repo path. Leave it.)

Also pause the Claude scheduled agents, above all `grocery-alert-triage` (6:30am), which commits fixes.

### 0.2 Clear the worktrees — HARD BLOCKER

Worktree metadata stores **absolute** paths. Renaming the parent breaks the main tree's own registration and
`git status` can fail outright. Current state: 41 registered, 38 prunable leftovers from the ingredient-publish
batches, 3 live:

| Worktree | Branch | Ahead of main | Verdict |
|---|---|---|---|
| `income\.claude\worktrees\epic-ramanujan-c1e577` | `claude/epic-...` | 0 | remove |
| `income\.claude\worktrees\festive-cannon-1b16a8` | detached | n/a | remove |
| `C:\Codex\tmp\github-actions-autorecovery` | `codex/github-actions-autorecovery` | 0 | remove |
| `%TEMP%\tc-parallel-recipe-pipeline` | `codex/parallel-recipe-pipeline` | **1** | see below |

The single unmerged commit (`b2082b33`, "Run recipe fulfillment as parallel candidate lanes") touches
`platform/**` and nothing else. That estate was deleted 2026-08-14 in `f5e187a0`. It is dead work against a
removed target: discard, do not merge.

```bash
git worktree prune
```

Then remove the three live ones explicitly and re-run `git worktree list` until only the main tree remains.

### 0.3 Baseline

```bash
git tag pre-restructure
git status --short          # must be empty
```

Confirm a full clean run of the gates against the tag, so any later red is attributable to the move and not
to something already broken. **Diagnose only on a clean tree.**

---

## Stage 1: Discard

Confirmed by Brad 2026-08-15: not doing this work anymore.

| Path | Contents | Note |
|---|---|---|
| `C:\Codex\omaha_code\` | 9 files (`ch3_raw.json`, `content.ps1`) | discard |
| `C:\Codex\tweet_poster.py` | tweet automation | discard |
| `C:\Codex\tweet-queue.txt` | 3.6 KB queue | discard |
| `C:\Codex\twitter.env` | **live credentials** | discard, and revoke the API keys rather than only deleting the file |
| `C:\Codex\tmp\` | 27,783 files | discard *after* 0.2 releases its worktree |
| `C:\Codex\recipe-deploy-5d71adde\`, `-9d2739ee\` | empty husks | discard |
| `C:\Codex\dried-arbol-chiles\` | 2 stray capture JSONs | discard |
| `C:\Codex\*.log` (codex-app-server, remote-control) | stale May logs | discard |
| `C:\Codex\adap_dir.txt`, `dcd.xls` | June one-offs | discard |
| `C:\Codex\node-v24.15.0-win-x64.zip` | 36 MB, already extracted | discard |
| `C:\Codex\rustup-init.exe` | 12 MB installer | discard |

`twitter.env` is the one that matters. Deleting a credentials file does not invalidate the credentials.

**Not discarded, not moved** (toolchain, stays at `C:\Codex\`): `Python312\`, `node-v24.15.0-win-x64\`,
`npm-global\`. **Separate project, untouched**: `Book\`, and the `scalp-eod-google-doc` scheduled agent.

---

## Stage 2: The container move

The rename alone, with zero internal reorganization, so it stays independently revertable.

1. Rename `C:\Codex\income` -> `C:\Codex\ThriftyCrew`.
2. Rewrite the 238 path references across 149 files. Verify none survive:
   ```bash
   grep -rIl "Codex[\\/]income" . | grep -v "^./.git/"
   ```
   Expect zero. Note some hits are *historical prose* inside `ops\prompt-backup\**` and agent prompts;
   those update too, since they are operating instructions, not archive.
3. Repoint the 6 scheduled task actions.
4. Repoint the `.claude` permission globs (`PowerShell(... C:\Codex\income\**)`), which otherwise silently
   stop matching and turn every pipeline command into a prompt.
5. Repoint the Claude scheduled-task SKILLs in `C:\Users\Owner\.claude\scheduled-tasks\` (49 path references
   across the 8 SKILL files).
6. **Rename the GitHub remote to match** (decided 2026-08-15). GitHub redirects old clone URLs automatically,
   so nothing breaks at the moment of rename, but the redirect is a courtesy and not a permanent contract:
   update `git remote set-url` locally and sweep `.github\workflows\*.yml` and `wrangler.jsonc` for any
   reference to the old name in the same commit.

**Verification gate.** Re-enable one task, run one full daily cycle, confirm a green board and a normal commit
and push **to the renamed remote**. Do not proceed to Stage 3 until a real cycle has passed.

Doc drift to fix while here: `RUNTIME-MAP.md:22` says the 8:30am task runs `check-ad-cycles.ps1`; the task
actually invokes `run-daily-local.ps1`, which calls it.

---

## Stage 3: `.claude` consolidation

The full fix for the unversioned agent and skill estate. Today it spans three roots:

| Root | Holds | In git? |
|---|---|---|
| `C:\Codex\ThriftyCrew\.claude\` | 12 agents, 52 skill files, `settings.local.json` | no |
| `C:\Users\Owner\.claude\` | 8 duplicate agents, 8 scheduled-task SKILLs | SKILLs only |
| `income\.claude\` | `hooks\sync-main.sh`, `worktrees\` | no |

**Target: one home, inside the repo, loaded in place.** No mirror, no junction, no copy.

1. `agents\` and `skills\` move to `ThriftyCrew\.claude\`, tracked directly.
2. Sessions run from `C:\Codex\ThriftyCrew`, making that the project scope. This turns worktree isolation
   *on* for sessions that currently write the main tree directly.

   **Gate (decided 2026-08-15): one deliberate test run before trusting it.** Put a single small recipe batch
   through an isolated worktree and confirm four things specifically, because these are what isolation
   changes: the publish reaches Ghost, the gates read the right tree, the commit lands on `main` rather than
   stranding on a worktree branch, and `hooks\sync-main.sh` fast-forwards the main tree afterwards. Only then
   run a full batch.
3. **Delete the 8 duplicate user-scope agents** rather than syncing them (decided 2026-08-15). Project scope
   wins in-project, and this ends the two-copies problem the audit's SCOPE DRIFT check exists to police.
   Consequence to accept: `post-publish-reviewer`, `recipe-batch-auditor`, `recipe-dedup-selector`,
   `recipe-ingredient-mapper`, `recipe-sourcer`, `recipe-writer`, `triage-developer` and `triage-reviewer`
   stop being available in sessions outside `ThriftyCrew\`. Back them up outside the repo before deleting;
   `ops\prompt-backup\agents\` already holds all 8.
4. Extract the 6 credentials out of `skills\` to a machine-local secrets directory behind a resolver,
   matching the existing `.ghostkey` convention. Gitignore then becomes a backstop rather than the only control.
5. Rewrite the 14 hardcoded `C:\Codex\ThriftyCrew\.claude\skills\...` paths in `polish-*.ps1`, `snapshot-savings.ps1`,
   `verify-*.ps1`, the `meal-macro` scripts, and two `SKILL.md` docs.
6. Fix `grocery\send-alert.ps1:337`, which dot-sources `C:\Codex\ThriftyCrew\.claude\skills\lesson\google-token.ps1` from
   outside the repo. **A fresh clone currently cannot send alerts** — the same `lib\` hole from 2026-07-31, on
   the path that reports every other hole. Make it repo-relative.
7. Reduce `ops\audit-prompt-backup.ps1` to the 8 user-scope SKILLs it still legitimately mirrors, and add one
   check: has a stray agent or skill copy reappeared in another root.

**Known defect to fix in passing.** `skills\lesson\publish-resource.ps1` and `grocery\publish-resource.ps1`
are both 70 lines, same name, different hashes. The skills copy still carries an inline `New-GhostJWT`, the
exact thing `lib\ghost-lib.ps1` consolidated on 2026-07-26 as "one of 50+ inline copies", plus no retry
wrapper and a 30s versus 120s timeout. The sweep could not see into `.claude\skills\`. Fix the divergence
here, or it survives the restructure intact.

**Why not a mirror.** `audit-prompt-backup.ps1 -Sync` copies live -> repo. Mirror `skills\` into `ops\` and any
repo-side edit gets silently reverted by the next sync, which the audit will actively instruct you to run.
That converts an invisible file into one that resists being fixed.

**Why not a junction.** Tested: junctions need no admin, write-through works, `$PSScriptRoot` resolves through
them. But a `git checkout` to a branch without the target leaves the junction **dangling with no error** —
Claude Code would load zero agents and simply behave worse, silently. It also preserves the absolute
out-of-repo path shape that makes `send-alert.ps1` unclonable, which is the actual defect.

---

## Stage 4: Root cleanup

46 tracked files leave the root. `git mv` preserves history.

```
ThriftyCrew\
├─ .claude\                  agents\ skills\ hooks\        (Stage 3)
├─ .github\workflows\        daily.yml, heartbeat.yml
│
├─ grocery\                  UNCHANGED   1,310 files
├─ meal-prep\                UNCHANGED   3,072 files
├─ lib\                      UNCHANGED   ghost-lib, design-tokens
├─ public\                   UNCHANGED   Worker-served    \  must stay root-
├─ worker\                   UNCHANGED   Worker source     }  relative to
├─ wrangler.jsonc            UNCHANGED                    /   each other
│
├─ site\                     NEW - everything that publishes to Ghost
│   ├─ tools\                  13 *-tool.html + my-crew / meal-plan templates
│   ├─ build\                  build-*.ps1, publish-tool-post.ps1, deploy-*.ps1,
│   │                          get-*.ps1, verify-starthere.ps1
│   └─ interstitial\           join-interstitial.html + deployer
│
├─ content\                  NEW - the written estate
│   ├─ lessons\                55 lesson sources
│   ├─ substack\               71 archived posts
│   └─ workbooks\              4 .xlsx
│
├─ media\                    NEW - was outside the repo
│   ├─ reels\                  generator (from reels\)
│   └─ videos\                 1,072 files from C:\Codex\recipe_videos\  (ignored)
│
├─ brand\                    logos, covers (+ C:\Codex\output\social\)
├─ design\                   specs, MASTER-PLAN, this document
├─ ops\                      guards, audits, user-scope SKILL mirror
├─ sidecar\                  GPU semantic matcher
├─ docs\                     NEW - README, RUNTIME-MAP, CURRICULUM, STYLE-GUIDE
└─ archive\                  NEW - site-backups\ + C:\Codex\backups\ (138 Ghost config backups)
```

**`grocery\` and `meal-prep\` do not move.** They are 94% of tracked files and the entire git-bus runs through
them. Re-nesting under something tidier buys a nicer diagram and costs a second full round of path rewrites.
They are already coherent domains.

**The non-obvious cost.** Root scripts anchor on `$PSScriptRoot` and reach sideways into `lib\`, `grocery\`,
`meal-prep\`, `public\`. Moving `build-mycrew.ps1` into `site\build\` breaks every one of those `Join-Path`
calls. About 15 scripts need a re-derived `$root`, **in the same commit as the move**.

---

## Stage 5: Stray recovery

| From | To | Files |
|---|---|---|
| `C:\Codex\backups\` | `archive\ghost-config\` | 138 Ghost `codeinjection_head` + `routes.yaml` backups |
| `C:\Codex\recipe_videos\` | `media\videos\` | 1,072 (ignored) |
| `C:\Codex\output\social\` | `brand\social\` | 13 |
| `C:\Codex\deliverables\` | `archive\handoffs\` | 3 |
| `C:\Codex\ThriftyCrew\.claude\` | `ThriftyCrew\.claude\` | Stage 3 |

`backups\` is the priority. Given the injection-edit history and the 65,535-character ceiling, those files are
the rollback path for the live site and they are currently unversioned on one machine.

---

## The highest-risk artifact: `.gitignore`

`.gitignore` is deny-by-default from `/*` on line 3. **Every new top-level folder needs an explicit allow rule
or it vanishes silently.** This is exactly the trap that hid 146 source files for two months, and a restructure
is the most likely way to spring it again.

New rules required:

```gitignore
!/site/
!/content/
!/docs/
!/archive/
!/media/
/media/videos/                    # 1,072 rendered files; *.mp4 is already ignored but the .txt sidecars are not
!/.claude/
/.claude/worktrees/               # per-session, absolute paths inside
/.claude/settings.local.json      # machine-local, carries bypassPermissions
/.claude/scheduled_tasks.lock     # live pid + session id, same class as weekly-run.lock
```

Traps specific to this rewrite:

- **`site-backups\` has a three-rule dance** (`!/site-backups/`, then `site-backups/*`, then
  `!site-backups/ghost-export-*.zip`). Moving it under `archive\` requires rewriting all three or the exports
  are silently dropped.
- **`ops\` is already allow-listed**, so anything placed under it commits *by default*. Under `ops\`, the risk
  is silent committing, not silent ignoring. Verified: a hypothetical `ops/claude-backup/.../google-oauth-token.json`
  **would commit**, while `ghost-config.ps1` is already blocked by the global rule at line 187.
- **`.OLD-smp.json.bak` matches neither `*.backup-*.json` nor `*.bak-*`.** Two of the six credential files
  would commit under the current rules.

Every stage ends with, before any commit:

```bash
git status --ignored
```

plus `check-uncommitted-source.ps1 -Ignored`, and a hard check that no credential path is stageable.

---

## Rollback

- `git tag` before each stage. Stage 2 is revertable by renaming the folder back and reverting the
  path-rewrite commit.
- Stages 4 and 5 are pure `git mv`, revertable by revert.
- Stage 3 is the only one that deletes anything (the 8 duplicate user-scope agents). Back those up outside
  the repo first; they are already mirrored in `ops\prompt-backup\agents\`, but that mirror is currently
  missing `recipe-source-qa.md`.

---

## Do this first, regardless

`recipe-source-qa.md` exists on exactly one disk right now, and `ops\audit-prompt-backup.ps1` is currently
exiting 2 saying so. A `-Sync` and a commit takes two minutes and carries no architectural lock-in. It should
not wait for Stage 3.

---

## Decisions recorded

All settled 2026-08-15. Nothing in this plan is waiting on an answer.

| Question | Decision |
|---|---|
| Repo name on the remote | **Rename the remote to match.** Stage 2 step 6. |
| Worktree isolation turning on | **One deliberate test run first.** Stage 3 step 2 gate. |
| The 8 duplicate user-scope agents | **Delete them.** Project scope becomes the single home. |
| `README.md` location | **Stays at root** so GitHub renders it; only the other three docs move to `docs\`. |
| Execution and the freeze | **Wait for Brad's go, then Claude handles all of it**: disable tasks, prune worktrees, tag, execute, verify against a live cycle, re-enable. |
| `omaha_code\`, tweet scripts, `tmp\` | **Discard.** Stage 1. |
| Plan scope | **All five stages**, not a subset. |

## Execution protocol

Brad gives the go when the runs are finished. Claude then owns the whole sequence and does not start any
stage while work is in flight. Two standing rules for the duration:

- **Freeze means disabled, not idle.** Six Windows tasks plus the Claude scheduled agents, above all
  `grocery-alert-triage`, which commits fixes at 6:30am.
- **Re-enable is part of the job, not a follow-up.** The restructure is not done when the files have moved.
  It is done when a full daily cycle has run green on the new paths and every task is back on.

---

# EXECUTION RECORD - 2026-08-15

Stages 0, 1, 2, 4 and 5 executed. Stage 3 deferred.

| Stage | Outcome |
|---|---|
| 0 Freeze + worktrees | 6 Windows tasks + 5 Claude agents disabled; 44 registered worktrees reduced to the main tree; tagged `pre-restructure` |
| 1 Discard | Moved to `C:\_DISCARD-thriftycrew-2026-08-15\` rather than deleted, so it stays reversible. **twitter.env is in there and its 5 API keys still need revoking.** |
| 2 Container move | `income` -> `ThriftyCrew`; 605 path references rewritten in-repo, 127 more in live Claude config |
| 4 Root cleanup | 46 loose root files -> 5, across `site\ content\ docs\ media\ archive\` |
| 5 Stray recovery | 138 Ghost config backups, 1,072 videos, 15 social images, 3 handoffs brought in |
| 3 `.claude` consolidation | **NOT DONE** - see below |

## What the plan got wrong

**The blast radius was 5x the estimate.** The plan said 238 references across 149 files. The real number
was 1,127 across 382 files. The original grep used ripgrep, which respects `.gitignore`, and this repo is
deny-by-default from `/*` - so the measurement instrument was blind to most of the estate it was measuring.
Re-measured by reading all 22,607 files directly. Same root cause as the 2026-07 finding that hid 146
source files for two months, arriving this time as a wrong number rather than a missing file.

**Three variants a literal find-and-replace would have missed:** JSON-escaped (`C:\\Codex\\income`),
lowercase (`c:\codex\income`), and 446 `__pycache__` bytecode files carrying the compile-time path. The
rewrite captures the separator run instead of assuming one, and is byte-level over a latin1 round-trip so
no file is re-encoded.

**Ordering can invalidate a correct rewrite.** The scheduled tasks were repointed in Stage 2 and `reels\`
moved under `media\` in Stage 4, which silently re-broke the reel task. Found by verifying every task
action against the filesystem afterwards, not by grepping. Any restructure that repoints external
references before it finishes moving things needs that final check.

## Deliberately not rewritten

The historical logs (`ff-sweep-log`, `ad-cycle-log`, `logs-archive\`, `AUDIT-*-findings`,
`test-auditors-fail-*`) still say `income`. They are the record of runs that happened at a path that
existed at the time; rewriting them would make them describe something that never ran.

## Stage 3 is still open

Moving `agents\` and `skills\` into the repo changes **where Claude sessions must be launched from**. The
scheduled Claude agents currently run with `cwd: C:\Codex` and would lose their skills the moment the
directory moves. The plan already gated this behind one deliberate isolated-worktree test run; that gate
has not been satisfied, so the estate still spans three roots and the 6 credentials under `skills\` are
still outside the repo. `grocery\send-alert.ps1` still dot-sources
`C:\Codex\ThriftyCrew\.claude\skills\lesson\google-token.ps1`, so a fresh clone still cannot send alerts.

## Verification

`ops\run-gates.ps1`: 98 passed, 1 failed - **identical to the pre-restructure baseline**. The one failure
(`audit-guard-contract` reporting `audit-commodity-dupes` half-covered) is a pre-existing defect from
commits 3cdbb10d / 1f9479f6 earlier the same day, in files the restructure never touched. It is a real
bug - the guard uses two different definitions of "completion marker" - and is queued separately.

Smoke-tested at the new paths: `build-mycrew.ps1`, `build-meal-planner.ps1`, `audit-ghost-drift.ps1`
self-test. All 9 scheduled task targets verified to resolve on disk.
