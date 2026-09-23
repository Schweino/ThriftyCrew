# PLAN: the bot's checkout heals itself, and one refused day stops refusing the next (2026-09-23)

On 2026-09-23 the daily grocery run executed on a checkout about 14 hours behind origin. A defect fixed upstream the
night before held the board, and the commit was refused because two days of captures had piled up uncommitted. Shipping
the board took a hand repair and a forced commit. This plan is written before anything is built, so Brad can read and
edit it first. It is built on the design the judges scored highest (section 4.1 has the sums), with the named best ideas
of the other design grafted in. The bars in section 8 are written now, before any run.

**RULED 2026-09-23 (Brad): build it with every recommendation, live from its first commit with the kill switch. Section 12 records each ruling.**

**Status: PLAN, ruled by Brad 2026-09-23, not ruled.** Section 12 lists what only Brad can decide. Each decision has a recommendation.

**Numbers.** Every measured number in this plan is **SCRATCH** unless it names a committed harness. None of the
harnesses behind these numbers is committed yet; W1.2 commits the one that re-derives the bars. Scratch harnesses are
named with their blob in section 14. Constants quoted from code cite `grocery/capture-run.ps1` blob `8e37b0830f07`,
which is unchanged from origin/main `50d6d7089` to `cec9779a3`. Where a number was re-derived by the planner with a
one-off git command, it says so. That still makes it SCRATCH.

**Implementer: read sections 0, 4, 5 and 9, then your item in section 6, then the section 12 row of any D-id it names.**
Every item is in the ThriftyCrew repo and lands through `ops\push-main.ps1` from a linked worktree. The one exception is
W5.1's store edit, which is in `~/.claude/skills`.

## 0. Read this first: today's forced commit landed a deletion on main

This is live state, read-only, at 10:43 CDT on 2026-09-23.

- The hand run `capture-run -Kind daily -Force -ForceBigCommit` (pid 36512, started 09:32:18) committed `c6a89ab9c` at
  10:27:10, rebased it to `209eb6edb`, and pushed on attempt 2. **origin/main is now `cec9779a3`**, the bot's
  "Daily pipeline: refresh prices + feed (2026-09-23) [daily]" commit, with commit time 10:39:13.
- In that commit, `graph/provenance/2026-09-22.jsonl` is recorded as a rename (R100) into
  `grocery/out/untracked-quarantine/2026-09-23/graph/provenance/2026-09-22.jsonl`, blob `246c77c39`. **origin/main no
  longer tracks the provenance file at its own path.** `lib/bot-paths.ps1:92` lists `graph/provenance` as a bot input
  path, and `Get-DirtyOwnedSnapshot` keeps only a worktree `M` (`lib/pipeline-commit.ps1:151`). So nothing held the
  worktree deletion back, which is exactly what the judges predicted before the commit stage ran.
- origin/main now tracks 3 files under `grocery/out/untracked-quarantine/2026-09-23/`. The copy of
  `design/RCA-holistic-2026-09-22.md` has blob `037cfbd12`, the same as the tracked design doc, so no private content
  leaked; it is clutter. The directory is still not ignored: origin/main's `.gitignore` has 534 lines and no line
  matching `quarantine` (grep rc 1), and `git check-ignore --no-index grocery/out/untracked-quarantine/x.json` exits 1.
- The main checkout's shared index holds 4 staged adds for paths `cec9779a3` does not track. Each is on disk and in the
  index at its blob from before the commit (`d7b8c7a59`):

  | Path | Index blob = pre-commit blob = disk |
  |---|---|
  | `graph/provenance/2026-09-22.jsonl` | `246c77c39` |
  | `grocery/out/browser-capture-due-2026-09-18.flag` | `26e8d294f` |
  | `grocery/out/browser-capture-due-2026-09-20.flag` | `e03e12acd` |
  | `grocery/out/throttled/family-fare-2026-08-31.throttled.json` | `e96e46b78` |

  How the last three came back is **not verified**. One plausible reading is that the pipeline deleted them during the
  run and the tail's autostash `Applied autostash` restored them from the index it stashed. That is the autostash
  hazard this plan removes, but this plan does not rest on that reading.

W0.1 repairs this. It is the only item that should land today, and D1 is its decision.

## Knowledge consulted

Searched on 2026-09-23 with `knowledge-search/search.py --files --multi "autostash" "fast-forward shared checkout"
"conflict markers" "commit size gate" "absence floor" "read-tree" "self-perpetuating backlog" "kill switch"` (2292
sections indexed, blind=0). "autostash" hit `reliability-craft/applies-here.md`. "read-tree" and "self-perpetuating
backlog" returned nothing: those two are new to the store. The rest hit only scattered words. A second query, "stuck
state grows each cycle absence floor upper bound", ranked `reliability-craft/applies-here.md` section 3 first.

- `reliability-craft/applies-here.md`, "The 07:00 bot, the shared index, and the fix that never reached a commit":
  *"autoStash restores CONTENT and not the index and REWRITES the mtimes of every dirty file it puts back"*, and
  *"wave-publish's P1b gate refuses to publish when the wave audit is older than any spec it certifies"*. Used for G3
  and bar B4. **The same section says capture-run's autostash "engages only when origin/main has actually moved". That
  is refuted.** The tail at `grocery/capture-run.ps1:1164-1216` has no `is-ancestor` check, and E4/X5 show an up-to-date
  autostash rebase still stashes, rewrites mtimes and drops staging, with exit 0. W5.1 corrects the store.
- `reliability-craft/applies-here.md` section 3, "Every threshold here is an upper bound, so none can fire on nothing
  happening": *"write down what the number does when the producer stops, and if the answer is 'goes quiet, and the
  alert cannot fire', add the floor in the same change."* W1.1's two floors are that rule.
- `CLAUDE.md` (ThriftyCrew): *"A ~07:00 bot commits the whole tree daily with an autoStash rebase that rewrites
  uncommitted files. Only rebase when origin/main actually moved; autostash restores content, not the index."* This
  sentence becomes false when Row 4 lands (D7).
- `.claude/rules/ops-and-gates.md`, "EVERY LOCK PATH DEGRADES TO THE DAY BEFORE": every sync failure in this plan falls
  back to running on the current HEAD with a page. Only two outcomes refuse, and both protect the chain from a tree it
  must not run on (section 4.3).
- `.claude/rules/ops-and-gates.md`, "A mutex serialises WRITERS, never READERS": *"`Move-Item -Force x.tmp x` fails
  ... whenever another handle holds `x` shared ReadWrite but not Delete - which is exactly how `Get-Content` and
  `Read-TextFile` open it."* git's unlink obeys the same Windows rule. That is why git's two-way move is atomic in its
  up-to-date check but NOT in its write phase (j2, re-run by the planner, section 2.6), and why W3.1 verifies the
  worktree after the move.
- `.claude/rules/ops-and-gates.md`: "A catch around a native redirect is not a guard" (every git call goes through
  `Invoke-GitCaptured`); "A `switch` on DATA carries a `default` that REFUSES loudly" (the classifier's default is
  FOREIGN); "A threshold or count detector's self-test carries a case exactly AT its bar and one a step PAST it ... built
  from BINARY-EXACT NUMBERS"; "A timed lock wait is a BRANCH"; "A hermetic self-test never asserts an UPPER wall-clock
  bar"; "A self-test names every temp path PER RUN"; "A new hook that spawns tests, or a fixture that builds a temp repo,
  clears `GIT_DIR` first"; "State whether a retried operation is IDEMPOTENT"; "Write the POINTED-TO object before the
  object that points to it"; "THE LOCK ORDER IS DECLARED, OUTERMOST FIRST" (D6); "A lock around the SAVE is not a lock
  around the read-modify-write" (the carry ledger).
- `.claude/rules/grocery.md`: *"A BAD CELL QUARANTINES ITSELF ... ONLY A BOARD-SCOPED FAILURE OR THE CIRCUIT BREAKER
  HOLDS THE BOARD"* (Brad, 2026-09-21). The 08:00 hold was the quarantine step's own defect, which `03d587117` fixed. This
  plan does not touch guards.
- `.claude/rules/measurement.md`: "Write the ACCEPTANCE BAR before the run"; "a number that moved is not a number that
  improved"; "NAME THE HARNESS AND THE COMMIT IT RAN AT" and "Never cite your own unlanded commit hash, anywhere: cite a
  blob"; "NAMING A SCRATCH HARNESS IS NOT NAMING A HARNESS" (W1.2 commits one).
- Memory `an-intention-has-no-exit-code` (index line): *"a follow-up step needs a detector, not a reminder."* The
  read-outs in section 8 have an exit code (W1.2 `-Due`).
- Memory index lines, files not opened: `autostash-restores-content-not-the-index`, `daily-bot-commits-the-whole-tree`,
  `landing-a-push-needs-a-clean-worktree`, `check-for-a-sibling-session-before-fixing`, `name-the-owner-from-process-shape`
  (the abandoned-mutex check in W4.1 reads process shape, never timing), `ps-json-array-collapse`.
- `CLAUDE.md`, "A SIBLING MAY ALREADY HOLD THE FIX": `git log --all --not origin/main --since=2026-09-20` over
  `grocery/capture-run.ps1`, `lib/pipeline-commit.ps1`, `grocery/capture-watchdog.ps1`, `grocery/test-commit-size-gate.ps1`
  and `.gitignore` returns nothing. `git log --all -- lib/checkout-sync.ps1 grocery/commit-size-lib.ps1` returns
  nothing. No branch holds any part of this.
- Exemplars read at origin/main: `grocery/push-data.ps1:124-137`, the only rebase-when-moved check in the estate;
  `lib/push-lock.ps1`, the `<pid>|<guid>|<prefix>` holder token; `lib/pipeline-commit.ps1:214-216`, a journal kept in the
  git common dir that "can never ride a commit" (its own CLEAN TWIN at :679); `grocery/test-commit-size-gate.ps1:43-48`,
  which lifts the shipped gate block out of capture-run.ps1 between the anchors `  $newDirs = @()` and
  `  & git -C $repo diff --cached --quiet`.

## 1. The incident, in plain words

The bot that captures prices and ships the board runs twice each morning from the shared main checkout. It only brings
that checkout up to date with origin **after it has committed**. On 09-22 its commit was refused, so it never updated.
Fixes landed upstream that evening, and the bot ran on 09-23 without them. One of them was the fix for the defect that
then held the board. Meanwhile each refused day left its capture files uncommitted. The next run tried to commit two days
at once, and the size gate, which judges every commit as if it were one run's output, refused that too. Each refusal made
the next one more likely. A hand repair was needed to get out, and the repair itself used the same damaging tool as the
bot (an autostash rebase), which is how a provenance file reached main as a deletion (section 0).

### 1.1 Timeline, with evidence

| When (CDT) | What | Evidence |
|---|---|---|
| 09-22 08:45 | Daily commit refused by the pre-commit bulk-edit verifier (BOM CHANGED `meal-prep/db/cost-flags.txt`) | the brief, verified by the orchestrator from logs |
| 09-22 13:26 | `ba13faba0` lands (an empty file is not a BOM change, `ops/verify-bulk-edit.ps1`). **It DID reach the bot checkout**: a session fast-forwarded main in the main checkout at 16:49 and 17:02 (reflog `merge origin/main: Fast-forward`) | `git merge-base --is-ancestor ba13faba0 54bff6167` rc 0 (planner re-run). This corrects the brief |
| 09-22 18:33 | `4ba348d48`, the last origin commit the checkout received | `git merge-base 54bff6167 cc2d28e50` = `4ba348d48` (planner) |
| 09-22 21:34 | `03d587117` lands: a quarantined cell's link follows the held value (`grocery/apply-cell-quarantine.ps1`, `cell-quarantine-lib.ps1`, `test-cell-quarantine.ps1`, child scripts only) | `--is-ancestor 03d587117 54bff6167` rc 1 (planner) |
| 09-22 21:38 | Graph nightly commits `54bff6167` locally on main, 1 ahead | main reflog |
| 09-23 07:00 | Ad run: commit refused, 40 new files, 28.8 MB against 300 files / 25 MB | `capture-run-ad-2026-09-23.log:67` |
| 09-23 08:00 | Daily run (pid 31740): guards held the board on the held cell's link disagreeing with its tile by 1.94x (the `03d587117` defect); ship path 1001 s; commit refused, 51 new files, 43.3 MB; `FAILED LANES: guards-blocked, commit-size-gate` | `capture-run-daily-2026-09-23.log:98-99, 143, 162`; the 1.94x from the brief |
| 09-23 09:30:37 | Hand repair: autostash rebase onto `cc2d28e50` | main reflog |
| 09-23 09:32:18 | Hand run `-Force -ForceBigCommit` (pid 36512) | process table |
| 09-23 10:27 to 10:39 | Its commit lands as `cec9779a3`, carrying the provenance deletion and the quarantine directory | section 0 |

How far behind the checkout was depends on when it was read. Every count below is SCRATCH, and they differ only in the
moment of reading, since origin moves about 9 commits an hour (SCRATCH, sync-first; the window behind that rate was
not stated):

| Reading | Behind |
|---|---|
| sync-first | 108 at 07:00, 127 at 08:00 |
| sync-always | 127 at 07:51, 134 at 08:47 |
| the brief | 135 during 08:00-08:58 |
| planner, `rev-list --count 54bff6167..cc2d28e50` | 137 at the 09:30 repair base |

The checkout was **about 14 hours stale** (merge base 18:33 the day before), not two days. The backlog of uncommitted
captures was two days deep.

### 1.2 The size arithmetic

- One normal date's two bot commits add **31 files, 24.8 MiB** by blob bytes: `df1d6429e` (09-21 ad) added 21 files,
  11.1 MiB, and `5d842a7f8` (09-21 daily) added 10 files, 13.7 MiB. Re-derived by the planner with
  `git diff-tree --diff-filter=A` and `cat-file --batch-check` (SCRATCH).
- The gate counts WORKTREE bytes, `Length / 1MB`, rounded to 0.1, against 25 (`capture-run.ps1:1045-1055`). Checkout
  CRLF makes worktree bytes larger than blob bytes. So one carried run plus the next day's run is already at or over the
  cap.
- At about 09:50 on 09-23 the untracked new files under `grocery/out` were 25 files / 19.0 MB dated 09-22, 34 files /
  26.3 MB dated 09-23, and 1 undated (SCRATCH, sync-always's read-only `ls-files`, not re-verified).

## 2. The defects

### 2.1 The sync lives only on the success path

`capture-run.ps1:1164` reads `if (-not $botCommitted) { $pushed = $false } else { foreach ($attempt in 1..4) { ... } }`.
Fetch, rebase and push all sit inside the else. A run whose commit is refused, whether by the size gate at :1055, by the
pre-commit hook, or by a throw before :1164, leaves the checkout exactly where it was. The next run executes the same
stale code, and that code may be the reason it failed.

### 2.2 The mover is an autostash rebase, and it damages a shared checkout

`capture-run.ps1:1184` runs `git -c rebase.autoStash=true rebase -X theirs origin/main`, up to 4 times, with no
`is-ancestor` check. Proved in temp repos on git 2.54.0.windows.1 (section 14 names each harness):

| Case | Result |
|---|---|
| E1: staged deletion with the file on disk, plus a local commit | rc 128 (`could not reset --hard`); leaves `rebase-merge` holding only `autostash` |
| E1b: `rebase --quit` on that state | rc 0; the dir is gone and the stash is kept |
| E1c: `rebase --abort` on that state | rc 1; the dir remains |
| E6: today's retry loop | attempts 2 and 3 exit 128 (`already a rebase-merge directory`); it can never recover |
| E2: autostash apply conflict | **exits 0** ("Successfully rebased") with UU entries and conflict markers left in the tree, and an unstaged file re-staged. Today's code reads only that rc |
| E3: a clean round trip | staged modifications become unstaged. j1: a staged NEW file stays staged, so "staging dropped" holds for staged modifications only |
| E4: origin already contained | still stashes, rewrites every dirty file's mtime (2020-01-01 became 2026-09-23 09:43) and drops staging, rc 0 |

E1, E1b, E1c, E2 and E4 were reproduced by two judges independently (X1-X5, j1).

### 2.3 The size gate judges a carried backlog as one run's output

`$NEW_FILE_CAP = 300` and `$NEW_MB_CAP = 25` (`capture-run.ps1:1045-1046`) cap the whole of `diff --cached
--diff-filter=A`. That sum includes files a previous refused run wrote. Section 1.2 shows that one carried run is enough
to push the next run over. The refusal then carries forward again, so the state is self-perpetuating.

### 2.4 Two holes let today's repair damage main

- The quarantine directory is not ignored (section 0), and the bot stages `grocery/out` whole.
- The dirty-at-start snapshot keeps only a worktree `M` (`lib/pipeline-commit.ps1:151`: "A staged-only change, a rename
  or a deletion is not a file the run could have been handed dirty"). A worktree deletion ` D` of an owned tracked file,
  present before the run started, therefore rides into the bot commit.

### 2.5 No floor sees a stale checkout or a growing backlog

`grocery/capture-watchdog.ps1` checks, in order: SCHEDULE, RAN, CAPTURED, PUBLISHED, AD HEALTH, AD FORECAST and
BROWSER. None asks whether the checkout the bot runs from contains origin, or whether captures from earlier days are
still uncommitted. Both quantities grow while nothing pages.

### 2.6 git's two-way move is not atomic in its write phase on Windows

Both designs assumed it was. Judge 2's probe j2 was re-run by the planner and reproduced exactly. One file was held
open with `FileShare.Read` and no Delete, the way `File.OpenRead` and PowerShell's readers open it:

| Mover | rc | What it wrote |
|---|---|---|
| `git merge --ff-only T` | 1 | 2 of 3 upstream paths already written; HEAD not moved |
| `git checkout -B main T` | **0** | HEAD moved; the held file left at its OLD bytes with the index at T |
| `git read-tree -m -u H T` | 128 | 2 of 3 paths written; stderr `unable to unlink old 'held.json'` |

So `checkout -B` can report success over a stale file. `read-tree` at least refuses loudly. The planner's probe p1 (18
cases, 0 failed, exit 0) then proved two recoveries after a partial read-tree:
- **Forward**: `git add` only the paths that were clean before and now equal NEW's blob, then retry the same read-tree
  (rc 0), then `update-ref` (rc 0).
- **Backward**: `git checkout H0 --` those paths. It works even with the reader still open, because git never wrote the
  held file.

In all three shapes a foreign dirty file outside the moved set kept its bytes and mtime.

### 2.7 The store is wrong about the 07:00 bot

See Knowledge consulted. W5.1 corrects it.

## 3. Goals, as properties that can be checked

- **G1.** Every armed capture-run starts its captures on a checkout that contains origin/main as fetched at run start.
  If it cannot, it pages that morning and names why, and runs on the HEAD it has. (W4.1; bar B1)
- **G2.** The bot never runs an autostash, a rebase, a `reset --hard` or a `stash` on the shared checkout. (W4.2; bar B3)
- **G3.** A sync never changes the bytes, the mtime or the index entry of any dirty path it was not told to own, and
  never writes a FOREIGN dirty file. (W3.1; bar B4)
- **G4.** The chain never runs on a tree holding unmerged entries or new conflict markers in any dirty tracked file, of
  any extension. (W3.1, W4.1; bar B5)
- **G5.** A size-gate refusal is never caused by files that an earlier run wrote within its own caps. This run's own
  writes are still judged at exactly 300 files / 25 MB. (W2.1, W2.2; bar B6)
- **G6.** A fix that lands on origin is executed by the next armed run whose start sync reports `current` or `synced`.
  When capture-run.ps1 or a startup library changed, the re-executed child runs the new file. (W4.1; bar B1a)
- **G7.** A checkout more than 26 hours behind origin, or captures from before today still uncommitted after the daily
  slot, page from state, even if capture-run never runs again. (W1.1; fixtures)
- **G8.** A partial write by git (a held file) ends in either the target tree or the original tree, both verified by
  bytes, never a silent mixture. (W3.1; bar B9)
- **G9.** A foreign worktree deletion of an owned tracked file is never committed by the bot. (W0.2; fixture)
- **G10.** Every sync writes one record row naming its outcome, and every outcome except `current`, `synced` and
  `skipped` pages. (W3.1, W1.2)

## 4. The design, and why it is this shape

### 4.1 The judges' scores

Three judges scored two designs over 7 criteria, 0 to 5 each: SAFETY, RECOVERY, NO COMPOUNDING, DETECTION, DEGRADES,
TESTABILITY and SIZE. Context for every score: a shared Windows main checkout on git 2.54.0.windows.1, with concurrent
readers and sessions, on 2026-09-23.

| Judge | sync-first | sync-always-two-way (the sync-on-refusal angle) |
|---|---|---|
| 1 | 22 | 27 |
| 2 | 21 | 25 |
| 3 | 20 | not received |
| **Sum** | **63 over 3 judges** | **52 over 2 judges** |
| Sum over the 2 judges that scored both | **43** | **52** |

Judge 3's text reached this planner truncated inside its first design's criterion 4, so its score for sync-always and
its winner are unknown. It scored sync-first 20 with SAFETY 3, RECOVERY 4 and NO COMPOUNDING 1, matching the other two on
those criteria. Judges 1 and 2 both named sync-always the winner.

Per criterion, summed over judges 1 and 2, out of 10:

| Criterion | sync-first | sync-always | Lesson for the graft |
|---|---|---|---|
| SAFETY | 6 | 8 | sync-always has one mover and blocks staged changes; it loses points for merging into a session's file and for a code-only marker scan |
| RECOVERY | **8** | 6 | sync-first syncs at start and re-execs; sync-always has a one-run lag |
| NO COMPOUNDING | 2 | **8** | the size gate is the load-bearing 09-23 cause, and only sync-always fixes it |
| DETECTION | 8 | 9 | both have floors; sync-always's floors read state rather than the producer's record |
| DEGRADES | **8** | 6 | sync-first waits on another owner's operation and recovers with `--quit`; sync-always refuses the run |
| TESTABILITY | 7 | 9 | sync-always ships a runnable 54-case prototype |
| SIZE | 4 | 6 | sync-always deletes the autostash path instead of keeping a second mover |
| **Total** | **43** | **52** | |

**The base is sync-always-two-way.** The grafts come from the two criteria where sync-first scored higher, RECOVERY and
DEGRADES, plus the safety findings the judges made against both designs.

The winner's prototype (`sync-proto.ps1` blob `3ddd9f98c415`, `fixtures.ps1` blob `0b261c3cb365`) was re-run by the
planner from a copy: 54 passed, 0 failed, exit 0, last line `SYNC-PROTO SELF-TEST PASS`. Judges 1 and 2 got the same
result. Nobody has re-run its "10 mutants each died in their own named case". A third scratch directory,
`%TEMP%\selfheal-detect\`, holds a read-only detection prototype (`checkout-sync-lib.ps1` blob `10673b07c7a2`). No design
text or score for it reached this planner, so it is not scored. W1.1 may read it before writing the floors.

### 4.2 What is taken from where

| Piece | Source | Criterion it fixes |
|---|---|---|
| One mover, `read-tree -m -u H0 NEW` plus an `update-ref` compare-and-swap; the autostash loop is deleted | winner | SAFETY, SIZE |
| Local commits replayed off to the side with `merge-tree --write-tree -X theirs` plus `commit-tree` | both (identical) | SAFETY |
| Untracked AND ignored files at paths upstream adds are moved to quarantine (git overwrites an ignored one silently, E5f/X2) | both | SAFETY |
| Staged change on a moved path is never rewritten | winner | SAFETY |
| Sync in every armed run whatever the commit did, with `finally` for a run that threw | winner | RECOVERY |
| **Sync at START too, before any capture; re-exec when capture-run.ps1 or a startup lib changed** | sync-first S12, judges 1 and 2 | RECOVERY (removes the winner's own measured one-run lag, fixture F1) |
| **Recover the autostash-only `rebase-merge` dir with `--quit`**; wait up to 120 s on another owner's operation, then degrade | sync-first S1b/S1c, judges 1 and 2 | DEGRADES |
| **A FOREIGN dirty file is never written**; the sync goes PARTIAL to the newest observed push tip before the first commit touching it | sync-first S8, judges 1 and 2 | SAFETY (replaces the winner's F8 merge into a session's file) |
| **Marker scan over every dirty tracked file**, not only `*.ps1 *.psm1 *.py *.js` | sync-first S2, judges 1 and 2 | SAFETY (X4: markers land in JSON) |
| **In-progress checks run BEFORE the branch check** | judge 3 (HEAD is detached during a stopped rebase, so a branch check first skips silently) | DETECTION |
| **Worktree verify after the move, and held-file recovery** (forward, else backward) | judge 2 j2/j3, planner p1 | SAFETY (section 2.6) |
| **Undo copies kept in the dated set-aside tree until verified**, never in a scratch dir `finally` deletes | judge 2 | SAFETY |
| **Fingerprint of every dirty path outside the write set, byte-identical after** | sync-first S10, judge 1 | TESTABILITY (asserts the mechanism) |
| **Parse the startup code from the object DB before moving to it** | sync-first S6, judges 1 and 2 | DEGRADES |
| **`-z` listings split on NUL** | judge 2 | SAFETY (a quoted or control-character path arrives C-quoted otherwise) |
| **Kill switch file in the git dir that pages daily** | sync-first, judges 1 and 2 | DETECTION, rollback |
| Two state-reading absence floors | winner | DETECTION |
| Journal `built` entries, so a guards-blocked day's served outputs are vouched pipeline bytes | winner | SAFETY |
| **Carry records for the size gate** (section 4.4) | judge 1's graft, adapted | NO COMPOUNDING without a loosening |
| `.gitignore` line, the snapshot holding ` D`, and the store correction | all judges, judge 1 | Row 0, W5.1 |

**Rejected, with the reason:**
- The winner's 600 files / 50 MB per capture date. Judge 2 ran it: a single-day flood of 350 files, or 40 MiB, dated
  today passes where today's gate refuses both. That is a gate loosening.
- Judge 2's graft "today's bucket at 300 / 25 per date". Bucketing by path date still refuses the 09-23 shape. The
  today-dated files of a refused 07:00 run plus the 08:00 run's own come to 34 files / 26.3 MB dated 09-23 (SCRATCH), and
  26.3 is over 25.
- Sync-first's retention of the autostash tail with repairs T1-T3. Both judges asked for one mover.
- Sync-first's `git checkout -B main T` mover. j2 shows it exits 0 over a stale held file; `read-tree` refuses with 128.
- The winner's preflight refusal of the whole run on any in-progress operation. It is replaced by the wait, the
  `--quit` recovery and the degrade.

### 4.3 The shape

```
capture-run start
  mutex (as today)
  START SYNC (W4.1) ----- Invoke-TcCheckoutSync -Phase start
     preflight: kill switch; index.lock (wait 60 s); autostash-only rebase dir -> rebase --quit;
                other operation in progress (wait 120 s); unmerged entries; new conflict markers;
                THEN the branch check
     fetch; H0, O; current? -> zero writes
     NEW = O, or local commits replayed onto O off to the side
     parse capture-run.ps1 and its startup libs at NEW
     classify every path the move changes; FOREIGN present -> PARTIAL to an observed push tip
     quarantine / set aside (copies kept); read-tree -m -u H0 NEW; held file -> forward, else backward
     update-ref main NEW H0 (compare-and-swap); verify index AND worktree AND the untouched fingerprint
     record + log row
  outcome conflict or mixed-tree -> page, exit 1 BEFORE any capture (the hourly retry is a first pull)
  startup code changed -> re-exec capture-run.ps1 once (D4), mutex handed over
  dirty-at-start snapshot (now holds ' D' too, W0.2) ... captures ... chain ... (unchanged)
  commit stage: size gate with carry records (W2.2); a run that does not commit records its own adds
  TAIL SYNC (W4.2) ------ committed: sync, push, re-sync on a rejected push (4 attempts)
                          not committed: one sync after every watcher, and in finally if the run threw
  CAPTURE-RUN-COMPLETE
capture-watchdog (W1.1): BOT CHECKOUT STALE (over 26 h), CAPTURE BACKLOG, KILL SWITCH ON
```

**Why each outcome degrades or refuses:**

| Outcome | Meaning | Pages | At start the run |
|---|---|---|---|
| `current` | HEAD already contains O, zero writes | no | continues |
| `synced` | moved to NEW and verified | no | continues (re-exec if startup code changed) |
| `partial` | moved to an older push tip because a FOREIGN file blocks the rest | yes, names the paths and the blocking commit | continues |
| `blocked` class `foreign` | no push tip is newer than H0 | yes | continues on H0 |
| `blocked` class `held-file` | a reader held a file; backward restore verified | yes | continues on H0 |
| `blocked` class `conflict` | unmerged entries or new markers on a non-owned path | yes | **exits 1 before any capture** |
| `degraded` | fetch failed, index.lock, another operation, merge commit, replay conflict, parse error | yes, except fetch failure (the floor catches that) | continues on H0 |
| `failed` class `mixed-tree` | a verify after a move or a restore found bytes that are neither H0 nor NEW | yes, loud | **exits 1 before any capture** |
| `failed` other | a post-move check other than bytes failed (a defect in this code) | yes, loud | continues |
| `disabled` | kill switch present | once a day | continues on H0 |
| `skipped` | -WhatIf, -NoDownstream, -NoSync, a linked worktree, a hook environment | no | continues |

Only the two early exits refuse, and both protect the chain from a tree it must never run on (G4, G8). Every other
failure is the day before, plus a page.

### 4.4 The size gate carries a refused run's verdict

A run that stages files but does not commit writes a **carry record** of its OWN additions: the files it added whose
LastWriteTime is at or after its `$script:RunStart`. The record holds each path's byte length, and its verdict against
exactly today's caps, `within-caps` or `over-caps`.

The next run's gate splits its additions into three groups:
- **own**: LastWriteTime at or after this run's start;
- **carried**: older, and named with the same byte length by a `within-caps` record under 72 h old;
- **unvouched**: everything else.

Own plus unvouched are judged at exactly today's caps (300 files, 25 MB after the existing rounding). Each carried
record's files are judged at one run's caps too, which they already met.

So:
- A flood refused yesterday (`over-caps`) is never laundered, because its files are unvouched today.
- A session dumping files into `grocery/out` is unvouched, exactly as today.
- On 09-23 the 07:00 run would have admitted its own ~11 MiB plus 09-22's vouched ~14 MiB.

A record older than 24 h still vouches, but pages "capture backlog N days deep". This is judge 1's graft ("count
carried files apart from this run's own writes; today's own run keeps 300/25") made exact.

## 5. How to work this plan (read before any item)

- **Repo and landing.** ThriftyCrew only, except the store edit in W5.1. Land every item through `ops\push-main.ps1`
  from a clean, seeded linked worktree (memory `landing-a-push-needs-a-clean-worktree`). Never use `--no-verify`.
  **Never test a sync against the main checkout.** Every fixture runs in temp repos. The first real run is the first
  scheduled run after W4.1 lands, with the kill switch ready (section 11).
- **Commits.** Stage explicit paths. Commit with a pathspec, `git commit -F <msgfile> -- <paths>`. Write the message
  file with `[IO.File]::WriteAllText($p, $body, (New-Object Text.UTF8Encoding($false)))`. Check `git show --stat HEAD`
  after every commit. Every message carries `Plan: design/PLAN-bot-checkout-self-heal-2026-09-23.md W<id>` and a
  `Store:` line naming the Knowledge consulted entries the item used.
- **Cite blobs, never your own unlanded hash** (`git rev-parse HEAD:<path>`). push-main rebases before it pushes.
- **Git calls.** Every git call in new code goes through `Invoke-GitCaptured` (`lib/git-blob-lib.ps1`), because
  capture-run runs under `$ErrorActionPreference = 'Stop'`. Every path listing uses `-c core.quotePath=false ... -z` and
  is split on `[char]0`. Assign a function's result before wrapping it in `@()`. Never name a loop variable after another
  in a different case (`$u` is `$U`). Sync-first's own dry run read 1 instead of 17 through both traps.
- **Self-tests.**
  - The last line is the verdict and names the self-test. A literal-case suite asserts how many cases ran.
  - Every temp path is per run and removed in `finally`.
  - Every temp repo calls `Clear-TcGitRepoEnv` (`lib/git-repo-env.ps1`) before `git init`.
  - At-the-bar cases use binary-exact numbers: integer seconds, integer bytes, and MiB values that are halves or quarters.
  - No case asserts an upper wall-clock bar. Every wait (60 s, 120 s, 300 s, 2 s) is a parameter, and fixtures pass 0,
    or a clock seam `-Now`.
  - A held-file case holds the file from ANOTHER PROCESS (`lib/mutex-hold.ps1` pattern), or from the test process with
    `[IO.File]::Open(..., 'Read', 'Read')` as p1 does, and never on a live path.
- **`# gate-inputs:`.** Every item that adds a library a self-test dot-sources updates that test's `# gate-inputs:` line
  and runs `powershell -File lib\gate-input-key.ps1 -VerifyDeclared <file>`, reading exit 0.
- **Re-reads owed.** Before committing, run `powershell -File ops\audit-conclusion-currency.ps1 -ReportOnly` on the
  post-change tree. For each doc that enrols a file you changed as a harness, re-read its conclusion and add the re-read
  in the same commit.
- **Docs say what the code does.** Update the header comment of every file you change, in the same commit.
- **No em dashes** in anything a reader sees, commit messages included.

## 6. Work items

### Row 0: today's repair, and the hole it came through

**W0.1 Put the provenance file back, untrack the quarantine, and ignore it.** (D1; land today, before 07:00 on 09-24)
Files: `.gitignore`, `graph/provenance/2026-09-22.jsonl`, `grocery/out/untracked-quarantine/`.
1. From a linked worktree at origin/main (`cec9779a3` or later), confirm the state first:
   - `git ls-tree origin/main -- graph/provenance/2026-09-22.jsonl` prints nothing.
   - `git ls-tree -r origin/main -- grocery/out/untracked-quarantine` prints 3 paths, among them
     `.../graph/provenance/2026-09-22.jsonl` at blob `246c77c39`.
   - If either differs, stop and re-read: someone else repaired it.
2. Restore the file from the blob: `git cat-file blob 246c77c39 > graph/provenance/2026-09-22.jsonl`, written as bytes.
   Check `git hash-object graph/provenance/2026-09-22.jsonl` equals `246c77c39`.
3. `git rm -r -q --cached -- grocery/out/untracked-quarantine`. The worktree copies in the main checkout stay on disk and
   are never deleted; they are the repair's own record.
4. Append to `.gitignore`, beside the other `/grocery/out/` lines (about :200), with a comment naming this plan:
   `/grocery/out/untracked-quarantine/`. It must be written LF with no BOM change: check
   `git diff --stat -- .gitignore` shows one file and a few insertions, and a CR count of 0 in the added lines.
5. Commit the three paths with a pathspec and land through push-main.
Fixtures: none, this is a data repair. Done when all four hold:
- `git ls-tree origin/main -- graph/provenance/2026-09-22.jsonl` shows `246c77c39`;
- `git ls-tree -r origin/main -- grocery/out/untracked-quarantine` prints nothing;
- `git check-ignore -q --no-index grocery/out/untracked-quarantine/2026-09-23/x.json` exits 0;
- the next bot commit's `git show --stat` names no path under `grocery/out/untracked-quarantine/`.

**W0.2 The dirty-at-start snapshot holds a foreign worktree deletion.**
Files: `lib/pipeline-commit.ps1` (`Get-DirtyOwnedSnapshot`, `Get-ForeignHeldPaths` and their self-test),
`grocery/capture-run.ps1` (the FOREIGN-HELD BLOCK at :919-948), `grocery/test-commit-size-gate.ps1` (its third lifted
block).
1. `Get-DirtyOwnedSnapshot` also keeps a line whose worktree column is `D` and whose path HEAD tracks, as
   `@{ path; mtime = $null; kind = 'deleted' }`. Keep ` M`/`MM` as `kind = 'modified'`. The header comment at :149-151
   changes to say why: a deletion present before the run started is a file the run was handed.
2. `Get-ForeignHeldPaths` holds a `deleted` entry when the path is STILL absent at commit time. The existing unstage,
   `git reset -q -- <path>` in the private index, restores HEAD's entry, so the deletion is not committed. A path that
   exists again at commit time is not held; the pipeline rewrote it.
3. The commit stage prints `foreign-held: kept a deletion present at start: <path>`, and the status record lists it.
Known residual, stated here and in section 10: a tracked file the pipeline itself deletes during a run whose commit is
then refused is ` D` at the next start, so it is held and prints every day until a person commits or restores it. That
is a visible leak, never a lost file (the pointed-to-first rule).
Fixtures (temp repo, `Clear-TcGitRepoEnv`):
- MUST FIRE: an owned tracked file deleted before the run, still absent at commit: the commit does not delete it
  (`git ls-tree HEAD -- <p>` still lists it), and the line is printed. This is today's `graph/provenance` shape.
- MUST NOT FIRE: an owned tracked file deleted DURING the run (after `RunStart`) is committed as a deletion, as today.
- CLEAN TWIN: an owned ` M` file present at start and unchanged is still held, exactly as before. The existing cases in
  `test-commit-size-gate.ps1`'s foreign-held block keep their verdicts, and their count is asserted.
Done when: `lib/pipeline-commit.ps1 -SelfTest` and `grocery/test-commit-size-gate.ps1` exit 0 with their verdict lines.

### Row 1: instruments first

**W1.1 Two absence floors and the kill-switch page in capture-watchdog.**
File: `grocery/capture-watchdog.ps1`. Add checks 7, 8 and 9 after BROWSER, each writing a finding into the existing one
email. The header gains one line per check saying what it does when capture-run STOPS: all three still fire, because
they read git and the filesystem, never capture-run's record.
7. **CHECKOUT.**
   - `git ls-remote origin refs/heads/main` through `Invoke-GitCaptured`. On rc not 0, print
     `CHECKOUT: BLIND - ls-remote exited <rc>`. That is a finding named BLIND, never a pass.
   - Then `git merge-base --is-ancestor refs/remotes/origin/main HEAD` in the MAIN checkout (the watchdog's own repo
     root). rc 0 means ok.
   - Otherwise take the oldest missing commit, the first line of
     `git rev-list --reverse refs/remotes/origin/main --not HEAD`, and its `%ct`. Older than 93,600 s (26 h) raises
     `BOT CHECKOUT STALE: <n> commits behind, oldest missing <sha8> committed <age> ago`, plus the last sync outcome and
     why, read from `<git common dir>\tc-checkout-sync.json` when it exists.
   - When the ls-remote tip is not the local `refs/remotes/origin/main`, say so on the line. A stale local ref can only
     understate the age, and nothing fetches here.
8. **BACKLOG.** Only after the daily slot (the existing `-SlotClose` path, or after 10:00 local): list untracked files
   under `grocery/out` with `git ls-files -z --others --exclude-standard -- grocery/out`. Take their path date with the
   same regex as W2.1's `Get-CaptureDateOf`. Any file dated before today raises
   `CAPTURE BACKLOG: <n> file(s), <MiB> MiB, oldest dated <date>`, grouped by date.
9. **KILL SWITCH.** If `<git common dir>\tc-checkout-sync.disabled` exists, raise
   `BOT CHECKOUT SYNC DISABLED since <mtime>` on every run, so it cannot be forgotten.
Fixtures (the watchdog's `-SelfTest`, temp bare remote plus clone):
- AT THE BAR, MUST NOT FIRE: oldest missing commit exactly 93,600 s old (via `GIT_COMMITTER_DATE`, integer seconds, and a
  `-Now` seam).
- ONE PAST, MUST FIRE: 93,601 s.
- MUST NOT FIRE: origin contained, at any age.
- MUST FIRE: ls-remote against a removed remote prints BLIND and counts as a finding.
- MUST FIRE: one untracked `grocery/out/regular/x-<yesterday>.json` after the slot.
- MUST NOT FIRE: the same file before the slot; an untracked file dated today; an ignored file dated yesterday.
- MUST FIRE: the kill-switch file present.
- CLEAN TWIN: checks 1 to 6 print unchanged over the existing fixture set, and the case count is asserted.
Done when: `capture-watchdog.ps1 -SelfTest` exits 0 with its verdict line, and one real run on the main checkout prints
the three new lines. **Today it should print BOT CHECKOUT STALE only if the checkout has fallen behind again.** Read the
lines and paste them into the commit message.

**W1.2 One committed harness for every bar, with read-out dates.**
File: `grocery/report-checkout-sync.ps1` (new). It is a report, not a gate. Header lines required: `SCOPE OF A CLEAN
REPORT:` (it counts only syncs that wrote a log row, so a sync that died before its row is invisible, and B1b's
denominator is armed runs from capture-run logs, not log rows), and a `REPORT-CHECKOUT-SYNC-COMPLETE` last line.
1. Inputs:
   - `<git common dir>\tc-checkout-sync-log.jsonl` (W3.1);
   - `<git common dir>\tc-commit-carry.json` (W2.1);
   - `grocery/out/logs/capture-run-{ad,daily}-<date>.log`, for `Created autostash`, the size-gate line and
     `FAILED LANES`;
   - git, for the bot commits on origin/main by author `smp-pipeline-bot` and subject stem
     `Daily pipeline: refresh prices + feed (`.
2. For each bar in section 8, print the metric, its N, its stratum and its bar, and a result word: `PASS`, `FAIL` or
   `NO-VERDICT (N below minimum)`. The bars table is a literal table in the script, holding each bar's landing commit
   and read-out date. Both are filled by the landing commit of the item the bar judges.
3. `-Due` exits 2 when a bar's read-out date has passed and section 13 of the committed copy of this plan has no
   `B<n>: result` line; otherwise exit 0. Until a scheduled task runs `-Due`, each item's landing commit also files one
   backlog-inbox finding naming its bars and read-out dates.
Fixtures (frozen literal JSONL rows and log snippets):
- MUST FIRE: a `Created autostash` line after the landing commit fails B3.
- MUST FIRE: a sync row with outcome `synced` whose `behind_after` is 1 fails B1a.
- MUST NOT FIRE: a `partial` row with a page is not a B1a defect.
- AT THE BAR for B1b: 18 of 20 PASS and 17 of 20 FAIL.
- MUST FIRE: `-Due` past date with no result line exits 2.
- CLEAN TWIN: the same with the result line exits 0.
Done when: `-SelfTest` exits 0 with its verdict line, and a plain run prints every bar as NO-VERDICT with N=0 today.

### Row 2: the size gate carries a refused run's verdict

**W2.1 `grocery/commit-size-lib.ps1`.** (D3)
1. `Get-CaptureDateOf($path)`, from the prototype: the last `yyyy-MM-dd` in the path, or `yyyyMMdd` before `-HHmmss`,
   or `''`.
2. `Read-TcCommitCarry` and `Add-TcCommitCarry -Run <id> -Kind <ad|daily> -Started <dt> -Files <path,bytes>[]`.
   - The ledger is `<git common dir>\tc-commit-carry.json`: `{ schema: 1, runs: [ { run_id, kind, started, recorded,
     verdict, files, bytes, paths: { <repo path>: <bytes> } } ] }`.
   - Every read-modify-write takes `Enter-TcLedgerLock` (`lib/ledger-lock.ps1`) with the READ inside the lock, and
     writes with `Write-TcAtomicFile -NoBom`.
   - `Add-TcCommitCarry` also prunes runs recorded more than 72 h ago, and runs all of whose paths HEAD now tracks.
   - `$env:TC_COMMIT_CARRY_PATH` overrides the path, for fixtures only.
3. `Test-CarriedCommitSize -Added <@{path; bytes; mtime}[]> -RunStart <dt> -Records <runs> -Now <dt>`, with parameters
   `-FileCap 300 -MbCap 25 -WindowHours 72 -DeepHours 24`. It returns
   `@{ ok; own = @{files; mb}; carried = @(@{run_id; files; mb; age_h}); unvouched = @{files; mb}; deep; why[] }`.
   - Own: `mtime -ge RunStart`.
   - Carried: older, and a `within-caps` record under `WindowHours` names the path with equal `bytes`. The newest such
     record wins.
   - Unvouched: the rest.
   - `own + unvouched` is judged EXACTLY as today: files `-gt 300`, or `[math]::Round(<sum of bytes>/1MB, 1) -gt 25`.
   - Each carried record's own files are judged by the same test, as a defence: they met it when recorded.
   - `deep` is any carried record older than `DeepHours`.
   - Every `switch` on a class carries a refusing `default`.
Fixtures (`-SelfTest`, pure, no git):
- MUST NOT FIRE (the incident): 09-22's refused run recorded 10 files / 13.5 MiB `within-caps`, and this run's own 21
  files / 11.25 MiB are admitted together; today's gate refused the sum.
- AT THE BAR: own plus unvouched exactly 300 files and exactly 26,214,400 bytes (25.0 MiB) is admitted.
- ONE PAST: 301 files refuses; 26,476,544 bytes (25.25 MiB) refuses.
- MUST FIRE (no laundering): a record with verdict `over-caps` vouches nothing, so its 350 files count as unvouched and
  refuse.
- MUST FIRE: a carried path whose byte length changed since its record counts as unvouched.
- AT THE BAR: a record exactly 72 h (259,200 s) old still vouches; 259,201 s does not.
- AT THE BAR: `deep` is false at exactly 24 h (86,400 s) and true at 86,401 s.
- MUST FIRE: the 2026-08-22 browser-profiles shape, 4,388 own files, refuses.
- CLEAN TWIN: no records at all gives exactly today's verdict for each of the existing `test-commit-size-gate.ps1` gate
  cases, fed through the lib.
Done when: `commit-size-lib.ps1 -SelfTest` exits 0 with its verdict line.

**W2.2 capture-run's gate calls the lib, and a run that does not commit records its own adds.**
Files: `grocery/capture-run.ps1` (the gate block between the anchors `  $newDirs = @()` and
`  & git -C $repo diff --cached --quiet`, which `test-commit-size-gate.ps1:43-48` lifts; keep both anchors byte-exact),
`grocery/test-commit-size-gate.ps1`.
1. Dot-source `grocery\commit-size-lib.ps1` with the other startup libs (:65-68), and add it to W3.1's startup-file list.
2. In the gate block, build `Added` from `git diff --cached -z --name-only --diff-filter=A`, each with the worktree
   `Length` and `LastWriteTime`. Call `Test-CarriedCommitSize`. Print one line per bucket (own, each carried run,
   unvouched). Keep the refusal text, `$sizeGateRefused`, `Add-FailedLane 'commit-size-gate'` and `-ForceBigCommit`
   exactly as today.
3. On refusal also `Send-Alert "Grocery commit refused by size - <today>"`, naming the buckets. When `deep` is true and
   the commit is admitted, `Send-Alert "Grocery capture backlog <n> days deep - <today>"`. Record `carried_runs` and
   `deep` in the status record.
4. After the commit stage, when `$botCommitted` is false, call `Add-TcCommitCarry` with this run's OWN adds and its
   verdict (`within-caps` when own plus unvouched met the caps, else `over-caps`). Wrap it in try/catch. A ledger that
   cannot be written is logged and pages once, and never fails the run.
5. `test-commit-size-gate.ps1` dot-sources the lib before running the lifted block, sets `$script:RunStart`, and points
   `TC_COMMIT_CARRY_PATH` at its temp dir. Update its `# gate-inputs:` line.
Fixtures (`test-commit-size-gate.ps1`, temp repo):
- MUST NOT FIRE: a run carrying a recorded `within-caps` day plus its own day is admitted.
- MUST FIRE: the same carried files with no record refuse, which is today's behaviour.
- MUST FIRE: a refused commit writes a carry record naming only files whose mtime is at or after `RunStart`.
- CLEAN TWIN: every existing gate case keeps its verdict, and the case count is asserted.
Done when: `test-commit-size-gate.ps1` exits 0 with `COMMIT-SIZE-GATE-COMPLETE cases=<n> failed=0`, where `n` is the old
count plus the new cases.

### Row 3: the mover

**W3.1 `lib/checkout-sync.ps1`: `Invoke-TcCheckoutSync`.** (D2, D5)
Port the prototype `sync-proto.ps1` (blob `3ddd9f98c415`) and its fixtures (blob `0b261c3cb365`). Apply the grafts
below; the numbered steps are the procedure. Parameters:
- `-Repo -Phase <start|tail> -OwnedPaths -OwnBlobs -QuarantineRoot -StartupFiles -Now`;
- the waits `-IndexLockWaitSec 60 -InProgressWaitSec 120 -AutostashAgeSec 300 -HeldRetrySec 2`;
- the seams `-BeforeMove -BeforeRef -AfterReadTree`.

It returns one record and appends one log row (step 11).

0. **Guards.**
   - `<git common dir>\tc-checkout-sync.disabled` present: outcome `disabled`. Page when the last `disabled` page date in
     `tc-checkout-sync.json` is not today.
   - `$env:GIT_INDEX_FILE` set: `failed`, no write (a private index was not released).
   - `GIT_DIR` or `GIT_WORK_TREE` set: `skipped`.
1. **In progress, BEFORE the branch check** (judge 3).
   - 1a. `index.lock`: poll every 5 s up to `IndexLockWaitSec`. Still present: `degraded`, naming its age. Never delete it.
   - 1b. `rebase-merge` whose ONLY entry is `autostash`, newest mtime older than `AutostashAgeSec`:
     - read the sha from `rebase-merge\autostash`;
     - run `git rebase --quit`, which must exit 0;
     - assert the dir is gone and `git stash list -n 1 --format=%H` equals that sha;
     - note `recovered half-started rebase, autostash kept as stash <sha>`.
     Any failure gives `degraded`. Younger than the bar falls through to 1c.
   - 1c. Any of `rebase-merge`, `rebase-apply`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `sequencer`, `BISECT_LOG`
     (each via `git rev-parse --git-path`): poll every 5 s up to `InProgressWaitSec`. If it clears, continue. Otherwise
     `degraded`, naming it. Never abort or quit an operation 1b did not recover.
   - 1d. Unmerged: `git ls-files -u -z`. Read the OUTPUT, because the rc is 0 either way (X6).
     - Owned path: copy its bytes to `set-aside\` with reason `unmerged`, then `git checkout HEAD -- <p>` (E9).
     - Non-owned: `blocked` class `conflict`.
   - 1e. New markers.
     - For every path in `git diff -z --name-only HEAD` that is a regular file of at most 52,428,800 bytes with no NUL
       in its first 8,000 bytes, count ordered triples: a line matching `^<{7}( |$)`, then `^={7}$`, then `^>{7}( |$)`.
     - Count the same in `git cat-file blob HEAD:<p>` when HEAD has the path.
     - The file has NEW markers when the worktree count is greater.
     - Owned: set aside, then `git checkout HEAD -- <p>`. Non-owned: `blocked` class `conflict`.
     - Larger files are listed as `unscanned` in the record, never blocked.
     This covers JSON (X4), and it ignores a doc that already quoted markers at HEAD, and a lone setext `=======`.
   - 1f. `git symbolic-ref -q HEAD` must be rc 0 and `refs/heads/main`. Otherwise:
     - in a linked worktree (`--git-dir` is not `--git-common-dir`): `skipped`;
     - in the main checkout: `degraded`.
2. **Fetch.** `git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main`, up to 3 attempts 5 s apart.
   Failing: `degraded` class `fetch`, logged, not paged (W1.1's floor catches persistence).
3. `H0 = rev-parse HEAD`, `O = rev-parse refs/remotes/origin/main`, `behind`, `ahead`. If `behind` is 0: `current`, with
   **zero writes** (F4 byte-identical).
4. `git rev-list --merges --count O..H0` greater than 0: `degraded` (never linearise a merge).
5. **NEW.** O, or the local commits replayed onto O (`Invoke-LocalCommitReplay`, prototype, which proves the same tree
   as `rebase -X theirs`, F6). A replay conflict gives `degraded`, naming the commit.
6. **Startup parse.** When `git diff -z --name-only H0 NEW -- <StartupFiles>` is not empty, parse each startup file at
   NEW from `git cat-file -p NEW:<f>` with `[System.Management.Automation.Language.Parser]::ParseInput`. Any error, or a
   missing file, gives `degraded` (`synced code does not parse: <file> line <n>`), and nothing moves. Record
   `startup_changed`. `StartupFiles` is a literal list in the lib. The self-test asserts it equals the set capture-run.ps1
   dot-sources (an AST scan of `. (Join-Path ...)` literals, :57-68 and :195 today), so it cannot drift.
7. **Classify every path in `D = git diff -z --no-renames --name-status H0 NEW`**, against
   `S = git --no-optional-locks status -z --porcelain=v1 --no-renames --untracked-files=all`. Classes, first match wins:

   | Class | Condition | Action |
   |---|---|---|
   | IN-THE-WAY | NEW adds P, P is on disk, and `ls-files --error-unmatch` rc 1 (untracked or ignored); or `??` on a path not being deleted | quarantine move |
   | ALREADY-UPSTREAM | ` M` and `git hash-object -- P` equals `rev-parse NEW:P` | index only: `git add -- P`; bytes and mtime never touched |
   | OWN-MERGE | ` M`, owned, vouched (`OwnBlobs[P]` Ordinal-equals `hash-object`), and the append-carry or an in-scratch `merge-file` exits 0 | merge |
   | OWN-SETASIDE | ` M`, owned, vouched, the merge fails or upstream deletes P | set aside; upstream wins |
   | OWN-DELETED | ` D` on an owned path | none; upstream's version comes back |
   | FOREIGN | a staged change (`X` not space), ` M` not vouched, ` D` not owned, or any other code (the refusing default, logged with the code) | **never written** |

   Merges use worktree-form bytes (`cat-file --filters`), because the checkout runs `core.autocrlf=true`.
8. **Partial**, when FOREIGN is not empty (sync-first S8; its proof is OWED, fixture below).
   - `E` = the first line of `git log --reverse --first-parent --format=%H MB..O --pathspec-from-file=<nul file>
     --pathspec-file-nul`, where `MB = merge-base H0 O`.
   - Candidates are the commits on the first-parent chain from `E^` back to `MB` that appear in
     `git reflog show --format=%H refs/remotes/origin/main`. Those are observed push tips.
   - `T'` is the newest candidate.
   - None newer than MB: `blocked` class `foreign`, nothing written, and the page names each path, its status and `E`.
   - Otherwise set O = `T'` and redo steps 5 to 7. FOREIGN must now be empty, or `blocked`. The outcome is `partial`.
9. **Apply.**
   - 9a. Write the intent record `<git common dir>\tc-checkout-sync.json` `{pid, phase, started, H0, O, NEW, plan}`
     (`Write-TcAtomicFile -NoBom`).
   - 9b. The dated tree is `<QuarantineRoot>\<yyyy-MM-dd>\<HHmmss>-sync\`, with `quarantine\`, `set-aside\`, `undo\` and
     `manifest.json` (path, class, reason, `hash-object` blob, index blob). IN-THE-WAY paths are moved into
     `quarantine\`. OWN-MERGE and OWN-SETASIDE paths are copied into `undo\`, and OWN-SETASIDE also into `set-aside\`.
     **The undo copies stay until step 10 passes** (judge 2).
   - 9c. `git add -- <ALREADY-UPSTREAM>`, then `git checkout -- <OWN-MERGE + OWN-SETASIDE>` (restore to the H0 index).
   - 9d. `rev-parse HEAD` must still be H0. Otherwise put everything back and `degraded`.
   - 9e. `git read-tree -m -u H0 NEW`. When the rc is not 0:
     - G = the paths in D that were clean before (or ALREADY-UPSTREAM) whose `hash-object` now equals NEW's blob.
     - **Forward**, when stderr names `unable to unlink old '<p>'`: wait `HeldRetrySec`, `git add -- <G>`, and retry
       read-tree once. rc 0 goes on to 9f (p1a).
     - **Backward**, otherwise or on a second refusal: `git reset -q -- <G>`, then `git checkout H0 -- <G minus
       ALREADY-UPSTREAM>` (p1b; it works with the reader still open, p1c). Put back the `undo\` copies and the quarantine
       moves.
     - Verify every restored path against its step 7 fingerprint. Pass: `blocked` class `held-file`, naming `<p>`.
       Fail: `failed` class `mixed-tree`.
   - 9f. `git update-ref -m "capture-run sync: onto <O>" refs/heads/main NEW H0`. If the swap loses: the prototype's ONE
     recovery (F11), else `failed`.
   - 9g. Write each OWN-MERGE path's merged bytes. The only file this code writes that it did not just restore is its
     own vouched output.
10. **Verify.**
    - HEAD is NEW and symbolic `refs/heads/main`; `ls-files -u` is empty; no in-progress dir exists.
    - The index holds NEW on every D path (prototype).
    - **The WORKTREE holds NEW**: `git diff -z --name-only -- <D>` lists exactly the OWN-MERGE paths, and each equals
      its merged bytes (j2/j3).
    - **The fingerprint** (porcelain v2 line, length and LastWriteTime) is identical for every dirty path outside D, for
      every FOREIGN path and for every ALREADY-UPSTREAM path.
    - For `partial`, `behind` equals `rev-list --count NEW..<full O>`.
    - A worktree-bytes mismatch is `failed` class `mixed-tree`. Any other mismatch is `failed`. Both keep `undo\`.
      On success delete `undo\` only.
11. **Record.** Update `tc-checkout-sync.json`. Append one row to `<git common dir>\tc-checkout-sync-log.jsonl` through
    `Add-TcLine`: `ts, pid, kind, phase, outcome, class, why, H0, O, NEW, behind, behind_after, ahead, replayed, dropped,
    changed, quarantined, set_aside, merged, already_upstream, foreign, partial_target, held, unscanned,
    startup_changed, sec`, plus `lib_blob`, the `hash-object` of this file. The header states idempotence:
    - a retried sync is idempotent, because `current` writes nothing and a completed move is detected at step 3;
    - the log append is NOT idempotent, so it is never retried.

Fixtures (`lib/checkout-sync.ps1 -SelfTest`, temp bare remote plus `up` and `bot` clones, per-run root,
`Clear-TcGitRepoEnv`). Keep all 54 prototype cases, with F8/F8b/F2 rewritten to the FOREIGN rule. Add these:
- MUST FIRE, the rewritten F8: a foreign non-overlapping edit on a path upstream changed is NOT merged. Outcome
  `partial` to the push tip before the touching commit, or `blocked` class `foreign` when there is none. The foreign
  file's md5 and mtime are identical.
- MUST FIRE, partial (OWED, sync-first never proved it): two upstream pushes, the second touching a session's dirty file.
  The sync lands on the first push tip. `behind_after` is 1 push worth of commits, and the page names the file and the
  commit.
- MUST FIRE, held file: `-BeforeMove` opens `held.json` with `[IO.File]::Open(p,'Open','Read','Read')`, and
  `-AfterReadTree` closes it, so the first read-tree fails and the forward retry finds the file free. The forward
  recovery ends `synced`, and the worktree equals NEW (p1a shape).
- MUST FIRE, held throughout: the reader stays open. The outcome is `blocked` class `held-file`, and every path equals
  its H0 bytes (p1c shape).
- MUST FIRE, M2 target: with the step 10 worktree check removed, the `checkout -B`-shaped stale file (index at NEW,
  worktree at H0) is caught. Build it by hand: `update-index --cacheinfo` to NEW's blob over H0 bytes.
- MUST FIRE, autostash-only dir: E1 shape. At `AutostashAgeSec` exactly 300 (via `-Now`) it waits and falls to 1c. At
  301 it recovers, and `stash@{0}` equals the recorded sha.
- MUST FIRE: another owner's `MERGE_HEAD`, `-InProgressWaitSec 0`, gives `degraded`, and `MERGE_HEAD` still exists.
- MUST FIRE, detached during a stopped rebase: `rebase-merge` present and HEAD detached gives 1c's `degraded`, never
  `skipped`.
- MUST FIRE, markers in JSON after a `git reset` (X4/E11, `ls-files -u` reads 0) on a non-owned path gives `blocked`
  class `conflict`. On an owned path it is set aside and restored.
- MUST NOT FIRE: a dirty markdown whose HEAD version already quotes one marker triple, edited elsewhere, is not
  flagged. A lone `=======` setext underline is not flagged.
- AT THE BAR: a 52,428,800-byte dirty file is scanned. At 52,428,801 bytes it is listed `unscanned`.
- MUST FIRE: a startup file that does not parse at NEW gives `degraded`, and HEAD, index and tree are byte-identical.
- MUST FIRE: a throw injected from `-AfterReadTree` (after a read-tree that succeeded, before step 9g) leaves the
  `undo\` copies on disk, and they equal the displaced bytes (M10 target).
- MUST NOT FIRE, ALREADY-UPSTREAM: a session file already holding upstream's bytes is carried through with its mtime
  unchanged, and ends clean.
- MUST NOT FIRE, `-z`: a path containing a double quote and a space round-trips through classification exactly.
- MUST FIRE: the kill-switch file gives `disabled` with zero writes. The page happens once per date over two calls.
- CLEAN TWIN: `StartupFiles` equals the AST-scanned dot-source set of the fixture's capture-run copy.
Done when:
- the self-test exits 0 with its verdict line, and the case count equals the file's literal count;
- the mutants in section 8 each turn their named case red from a temp mirror, with the originals md5-identical afterwards.

**W3.2 The pipeline journal vouches for a blocked day's outputs, and hands the mover its blobs.**
File: `lib/pipeline-commit.ps1`.
1. `Register-PipelineWrites` gains `-Built`, which writes entries with `commit = $false`. `Get-PipelineOwnHeld` skips
   `commit = $false` entries; an absent field means committable, as today.
2. Add `Get-PipelineOwnBlobs -Repo`, returning an Ordinal hashtable, repo path to blob, for THIS checkout's entries of
   either kind. A journal that cannot be read returns an empty table with `.note`. The mover then vouches nothing, and
   every owned edit becomes FOREIGN (never written): the day before.
3. In capture-run, when `$runDownstream -and -not $shipServed`, call `Register-PipelineWrites -Built -Lane
   ('capture-run-' + $Kind + '-built') -Since $script:RunStart -Paths $servedPaths` before the committable registration
   (the winner's step 2a).
Fixtures:
- MUST NOT FIRE: a `-Built` entry is never committed by `Get-PipelineOwnHeld`.
- MUST FIRE: `Get-PipelineOwnBlobs` returns it.
- MUST FIRE: an unreadable journal returns empty with a note.
- CLEAN TWIN: the existing journal cases keep their verdicts, and the count is asserted.
Done when: `lib/pipeline-commit.ps1 -SelfTest` exits 0 with its verdict line.

### Row 4: capture-run syncs at start and at the tail

**W4.1 The start sync, its two exits, and the re-exec.** (D4, D5, D6)
File: `grocery/capture-run.ps1`.
1. Dot-source `lib\checkout-sync.ps1` with the startup libs. Add a `-NoSync` switch.
2. Directly after the mutex block (:176-184) and BEFORE the dirty-at-start snapshot (:193), when the run is armed (not
   `-WhatIf`, not `-NoDownstream`, not `-NoSync`), call `Invoke-TcCheckoutSync -Phase start`. Pass `-OwnedPaths
   @((Get-BotInputPaths) + (Get-BotServedPaths))`, with each result assigned first, and `-OwnBlobs
   (Get-PipelineOwnBlobs)`. Write the record into the status file as `sync`, and `Write-RunStatus 'syncing'` first.
3. Class `conflict` or `mixed-tree`:
   - `Write-RunStatus 'blocked-checkout' 1`;
   - `Send-Alert "Grocery bot BLOCKED: the main checkout holds <conflict markers|a mixed tree> - <today>"`, naming the
     paths;
   - release the mutex and exit 1 before any capture. The next hourly occurrence retries, because the stage is not
     `complete`, and nothing has been pulled, so the retry is a first pull.
4. `partial`, `blocked`, `degraded` or `failed` of another class: `Send-Alert "Grocery bot checkout sync <outcome> -
   <today>"` with `why`, then continue on the HEAD it has.
5. **Re-exec** when the outcome is `synced` or `partial`, `startup_changed` is true, and `$env:TC_CAPTURE_RUN_SYNCED` is
   not set. The recommended D4 option:
   - Set `TC_CAPTURE_RUN_LOCK_HOLDER = '<PID>|<guid>|Global\tc-capture-run'` and `TC_CAPTURE_RUN_SYNCED = '<NEW>|<guid>'`.
   - `Write-RunStatus 'synced-handoff'` and log `handing off to <NEW>`.
   - Run `& powershell -NoProfile -ExecutionPolicy Bypass -File <root>\capture-run.ps1`, forwarding every bound
     parameter, streamed with no redirect. Keep holding the mutex.
   - Exit with the child's rc. If the child's status record still says `synced-handoff`, or carries the parent's pid,
     the child never started: page `capture-run could not start the synced code`, write stage `handoff-failed`, and
     exit 1.
6. **Child side**, before the mutex is taken:
   - If `TC_CAPTURE_RUN_LOCK_HOLDER` matches `^(\d+)\|[0-9a-f]{8,}\|(.+)$`, its prefix Ordinal-equals
     `Global\tc-capture-run`, and that pid is alive (`Test-TcProcessAlive`, the `lib/push-lock.ps1` pattern), the mutex
     is INHERITED: do not take it, and do not release it.
   - Remove both variables at once, so lanes never inherit them.
   - Skip the start sync, and record `sync = synced-by-parent`.
7. **The abandoned mutex.** Today `AbandonedMutexException` counts as held (:178). Change it: read the status record's
   `pid`. If that process is alive and its command line names `capture-run.ps1` (process shape, never timing), write
   stage `skipped-locked` and exit 0, as a normal lock refusal does. Otherwise proceed as today. This closes judge 2's
   orphan-child hole: a parent killed by Task Scheduler leaves an abandoned mutex while its child still runs.
Fixtures (capture-run's existing temp-repo harness, or a new `grocery/test-capture-run-sync.ps1`):
- MUST FIRE (F1, the founding bug over two runs): run 1's commit is refused; upstream then fixes the stale verifier.
  Run 2's START sync pulls it and run 2 lands BOTH days. With the start sync removed (M1), run 2 is refused again.
- MUST FIRE: a conflict marker in a non-owned dirty file exits 1 with stage `blocked-checkout`, and no capture lane
  started (a stub lane that writes a sentinel file is never run).
- MUST FIRE, handoff: with `startup_changed` true, the child runs the NEW capture-run.ps1 (it prints its own blob), the
  child's `WaitOne` is never called, and the parent's exit code equals the child's.
- MUST FIRE, orphan: the parent is killed while the child holds the inherited lock. A third run gets
  `AbandonedMutexException`, finds the child alive by process shape, and SKIPs.
- MUST NOT FIRE: `-WhatIf`, `-NoSync` and a linked-worktree run never fetch (no `FETCH_HEAD` mtime change).
- CLEAN TWIN: the child never re-execs, even when its own sync would report `startup_changed`.
Done when: the suite exits 0 with its verdict line, and a `-WhatIf` run on the main checkout prints the would-be sync
decision without writing.

**W4.2 The tail: the autostash loop is deleted; sync, then push.**
File: `grocery/capture-run.ps1` (:1164-1216).
1. Replace the loop with `foreach ($attempt in 1..4)`:
   - `$s = Invoke-TcCheckoutSync -Phase tail ...`;
   - if the outcome is not `current` or `synced`, add failed lane `sync`, page with `why`, and break;
   - if `$botCommitted`, run `git push origin HEAD:main` (no redirect, as today). rc 0 sets `$pushed` and breaks.
     Otherwise sleep 10 s and continue, which re-syncs;
   - if not committed, break after the one sync.
2. When not committed, run that one sync as the LAST git-mutating step before `CAPTURE-RUN-COMPLETE`, after every
   watcher, so the watchers read the tree they read today (the winner's placement). Set `$script:TailSyncOwed = $true`
   at the commit stage, and clear it once the sync ran. A top-level `finally` runs the owed sync when the run threw.
3. Delete the `Get-RebaseUntrackedBlockers` call site and the quarantine move at :1191-1206; the mover's IN-THE-WAY
   class replaces them. Leave the function in `capture-policy-lib.ps1` until `git grep` shows no other caller.
4. Update the header comment at :1165-1168 and the CLAUDE.md sentence (D7) in the same commit.
Fixtures:
- MUST FIRE (F6): a local bot commit plus a local graph commit are replayed, the push lands, and the tree equals what
  `rebase -X theirs` builds.
- MUST FIRE: a rejected push re-syncs and lands on attempt 2.
- MUST FIRE: a `partial` tail sync with a local commit does not push, and adds failed lane `sync`.
- MUST FIRE: a run that throws after the commit stage still syncs in `finally`.
- MUST NOT FIRE: `Created autostash` never appears in any fixture run's log (M-target for B3).
- CLEAN TWIN: `served-dirty` and `edge-decision` blocks print as before.
Done when: the suite exits 0, and `git grep -n "rebase.autoStash" -- grocery/capture-run.ps1` prints nothing.

### Row 5: the process text

**W5.1 Say what the code now does, everywhere it is said.** (D6, D7)
1. `CLAUDE.md` (ThriftyCrew), "What makes results here untrustworthy": replace the autoStash sentence with D7's text.
2. `.claude/rules/ops-and-gates.md`, "THE LOCK ORDER IS DECLARED": add the capture-run mutex as level 0, outermost (D6).
   It already nests over the push lock (the tail's `git push` runs the pre-push hook, which takes it) and over the ledger
   locks (journal, carry ledger). The sync takes no push lock and no gate slot.
3. `docs/CONTROL-CONSTANTS.md`: register the constants below. Each is marked "first plausible, not a sweep", with what
   it does when the producer stops.

   | Constant | Value |
   |---|---|
   | stale floor | 93,600 s |
   | autostash-only age | 300 s |
   | index.lock wait | 60 s |
   | in-progress wait | 120 s |
   | held-file retry | 2 s, once |
   | fetch attempts | 3 at 5 s |
   | marker-scan cap | 52,428,800 bytes |
   | NUL probe | 8,000 bytes |
   | carry window | 72 h |
   | deep | 24 h |
4. The store, as a separate commit in `~/.claude/skills`: `reliability-craft/applies-here.md:326-327` loses "It engages
   only when origin/main has actually moved". It gains the E4 finding and a pointer to this plan: the old tail never
   asked, and after Row 4 the bot never stashes. Add "read-tree two-way move is not atomic in its write phase on Windows
   (a held file)" beside the `Move-Item` rule's citation.
Done when: the gates that read the rules and constants (`audit-ruling-drift`, `audit-threshold-register` and any census
naming those files) exit 0 on the landing push.

## 7. Order

1. **W0.1 today**, after checking section 0 again. Then W0.2.
2. **Row 1** (W1.1, W1.2). The floors measure the problem before anything fixes it.
3. **Row 2** (W2.1, W2.2). Alone, it removes the self-perpetuating refusal, the load-bearing 09-23 cause.
4. **Row 3** (W3.2, then W3.1). The lib lands with no caller, so nothing changes at run time.
5. **Row 4** (W4.1, then W4.2), in one landing or in two landings on consecutive days. Between them the tail still
   autostashes.
6. **Row 5**, with W4.2's landing for items 1 and 2, and anytime for 3 and 4.

## 8. Bars, written now

Every bar is measured by `grocery/report-checkout-sync.ps1` (W1.2), cited by its blob, over armed capture-run runs after
the named item lands. Each value is the first plausible one, not the survivor of a sweep. The baselines are single
incidents, so **a number that moved is not a number that improved**. Most bars are deterministic, where any failing case
is a defect; the rest carry a minimum N and give no verdict under it. The read-out is 14 days after the item's landing
unless stated otherwise.

| # | Metric | Minimum N | Baseline (SCRATCH) | Bar | Item |
|---|---|---|---|---|---|
| B1a | start syncs with outcome `current` or `synced` whose `behind_after` is not 0 | 10 syncs | not measured before (no sync record); 09-23 07:00 ran 108 behind and 08:00 127 behind | 0 (deterministic: any such row is a defect) | W4.1 |
| B1b | armed runs whose start sync ended `current` or `synced`, of all armed runs | 20 armed runs | 0 of 2 on 09-23 (both ran on a stale tree) | at least 18 of 20 (90%). Every other run has an outcome, a `why` and a page: 0 silent | W4.1 |
| B2 | armed runs that started after a fix landed on origin and executed without it, over runs whose start sync was `current` or `synced` | 10 runs | 2 (the 07:00 and 08:00 runs of 09-23 without `03d587117`) | 0 (deterministic) | W4.1 |
| B3 | `Created autostash` lines in capture-run logs | 14 armed runs | every tail run used it (for example 10:28 today: `Created autostash: ee791d9e5`) | 0 | W4.2 |
| B4 | dirty paths outside the write set whose fingerprint (porcelain line, length, mtime) changed across a sync, summed over syncs that moved HEAD | 10 moving syncs | E4: 2 of 2 dirty files had their mtime rewritten by one up-to-date autostash (temp repo) | 0 paths (deterministic) | W3.1, W4 |
| B5 | armed runs whose captures started with unmerged entries or new marker triples in any dirty tracked file | 20 armed runs | not measured; E2 shows the old tail can leave both with rc 0 | 0 (deterministic). Reported beside it: `blocked-checkout` exits | W3.1, W4.1 |
| B6a | size-gate refusals where own plus unvouched were within 300 files / 25.0 MB and every carried record was `within-caps` | every refusal | 2 (07:00 and 08:00 on 09-23) | 0 (deterministic) | W2.2 |
| B6b | longest run of consecutive calendar days with no bot `[daily]` commit on origin/main | at least 1 refused day in 30 days | 2 days (09-22 and 09-23 before the hand repair) | at most 1; no verdict if no refusal occurs within 30 days of W2.2's landing | W2.2 |
| B7 | start-sync seconds (`sec`), a live report, never a fixture | 20 syncs | `git status` over 244 lines took 0.41 s (sync-always) | median at most 30 s, p90 at most 120 s | W4.1 |
| B8 | syncs whose read-tree hit `unable to unlink`, ending verified (`synced` or `blocked` class `held-file`), of all such syncs | reported at any N; judged at 3 | 0 known live; j2 and p1 in temp repos | all of them, and `mixed-tree` outcomes 0 (deterministic) | W3.1 |
| B9 | watchdog runs where check 7's condition held (26 h behind) and no BOT CHECKOUT STALE finding was raised | any | the checkout was 14 h stale on 09-23 and nothing paged | 0 (deterministic). Otherwise judged by the W1.1 fixtures at the bar | W1.1 |

**Fixture and mutation bars.** Every case in section 6 passes. Each suite prints its verdict line with exit 0, and every
literal-case suite's count equals the cases in its file. Each mutant runs from a temp mirror, one at a time, with the
originals md5-identical afterwards:

| Mutant | Must turn red |
|---|---|
| M1: remove the start-sync call | W4.1 F1 (run 2 is refused again) |
| M2: remove the step 10 worktree check | W3.1 stale-index case |
| M3: merge a foreign ` M` (the winner's F8) | W3.1 rewritten F8 |
| M4: bucket carried files by path date at 600 / 50 | W2.1 no-laundering MUST FIRE |
| M5: `rebase --abort` instead of `--quit` in 1b | W3.1 autostash-only case |
| M6: marker scan restricted to `*.ps1` | W3.1 JSON markers case |
| M7: branch check before the in-progress checks | W3.1 detached-during-rebase case |
| M8: the child takes the mutex instead of inheriting it | W4.1 handoff case |
| M9: `Get-DirtyOwnedSnapshot` back to `M` only | W0.2 MUST FIRE |
| M10: undo copies in a `finally`-deleted scratch dir | W3.1 throw-after-read-tree case |
| M11: `update-ref` without the old value | W3.1 F11 |
| M12: `-gt` to `-ge` on the 93,600 s floor | W1.1 at-the-bar case |

A mutant that survives means the fixture is insensitive, and the item is not done.

## 9. What this plan must not do

- Never run `stash`, `rebase`, `reset --hard`, `checkout -B`, `merge` or `clean` on the shared checkout from the bot.
- Never write a FOREIGN dirty file: not a merge, not a replace, not an mtime touch. Never rewrite an index entry the bot
  did not make, except ALREADY-UPSTREAM, whose bytes already equal upstream's.
- Never delete `index.lock`. Never abort or quit an operation this code did not recover under step 1b.
- Never delete a quarantined, set-aside or undo file on a failure path. Never let the quarantine tree be staged
  (W0.1's ignore line comes first).
- Never raise the caps for this run's own writes (300 files / 25 MB with today's rounding). Never let an `over-caps`
  record vouch.
- Never run a capture lane on a tree with unmerged entries, new markers or a `mixed-tree` outcome.
- Never push without the pre-push hook, never `--no-verify`, never force. The tail stays the only pusher.
- Never move HEAD off `refs/heads/main`, and never sync in a linked worktree.
- Never test against the main checkout, and never open a production lock name or the production carry or sync files
  from a fixture.
- Never re-exec twice in one run.

## 10. Deliberately not done

- **Other bots that commit in the main checkout.** Graph nightly commits locally at about 21:38 and harvest at about
  18:07, and `grocery/push-data.ps1` still autostashes when origin moved. They can go stale the same way. D8 proposes
  converting them to `Invoke-TcCheckoutSync` after this plan's bars hold for 14 days.
- **The cap values.** 300 files and 25 MB are unchanged. Whether one run's caps are right is a separate question.
- **Scheduled-task definitions.** Unchanged, which is why the re-exec exists.
- **The W0.2 residual.** A pipeline-deleted file on a refused day is held until a person acts. It is a visible leak and
  never a loss.
- **The three other staged adds in section 0.** Their owner decides (D1). This plan does not assume how they came back.
- **Partial sync to anything but an observed push tip.** An intermediate commit inside one push was never gated as a
  tree.
- **Deleting `Get-RebaseUntrackedBlockers`** until no caller remains.

## 11. Blast radius and rollback

**Where it runs.** In both scheduled capture tasks (TC Grocery Ad Pulls 0700 and TC Grocery Daily Capture 0800,
including their hourly catch-ups) and in any hand run of capture-run on main. It operates on the SHARED main checkout.

**What sessions working there will see:**
- HEAD moves forward up to three times a morning (start, tail and a re-sync after a rejected push), as the fast-forwards
  sessions already run there do. The reflog shows `merge origin/main: Fast-forward` at 16:49 and 17:02 on 09-22.
- A clean file that upstream changed changes under them.
- Every path upstream did not change keeps its bytes, mtime and index entry (E5a, E6a, F5), and step 10 asserts it on
  every run.
- There is no stash, no mtime rewrite and no marker.
- A session's dirty file on a moved path is never written. The sync goes partial or blocked instead, and pages.
- A pipeline-vouched output that upstream also changed is merged, or set aside with upstream winning. That is the one
  place a file changes under a session, and only for bytes the journal proves the pipeline wrote.
- Untracked or ignored files at paths upstream now tracks are moved to the dated quarantine, never deleted.
- Local unpushed commits are replayed with new ids, as the old tail did.

**Worst cases if this code is wrong:**
- HEAD moves to a wrong commit. This is bounded to O, O plus the replayed local commits, or an observed push tip. Step 10
  verifies it, and the reflog undoes it.
- An owned file is replaced. It is recoverable from `set-aside\` and the manifest.
- A foreign file is written. That cannot happen through git's own path: `read-tree` refuses a dirty path. The classifier
  is the only other writer, and the step 10 fingerprint catches it (bar B4).

**Rollback, cheapest first:**
1. Create `C:\Codex\ThriftyCrew\.git\tc-checkout-sync.disabled`. Every sync then records `disabled` and does nothing,
   and the watchdog pages daily while the file exists. capture-run then runs on the HEAD it has, which is the pre-plan
   behaviour for the start. For the tail, the push still needs a sync, so a committed run adds failed lane `sync` and
   keeps its commit locally until the switch is removed. **That is weaker than the old tail.** Use the switch for hours,
   not days, or revert W4.2.
2. `-NoSync` covers one hand run.
3. Revert W4.2, then W4.1. That restores the autostash tail exactly. Rows 0 to 3 stay, since each stands alone.
4. Undo a HEAD move from `git reflog main`: run `git read-tree -m -u <current> <old>` and then
   `git update-ref refs/heads/main <old> <current>`. That is the same two-way move, and it leaves local state untouched
   just as the forward move does.
5. Restore a file with `Copy-Item` from `grocery/out/untracked-quarantine/<date>/<HHmmss>-sync/`. The manifest names the
   original path.
6. Row 2 rolls back alone. Delete the carry ledger to disable it: with no records, every addition is unvouched, which is
   today's gate exactly.

## 12. Decisions only Brad can make

**RULED 2026-09-23 (Brad).** "Build with all recommendations (Recommended)" and "Live with a kill switch (Recommended)": D2 (a) partial sync, D3 (a) carry records, D4 (a) re-exec with the mutex handed over by token, D5 live from the first commit with the kill switch, D6 yes (the capture-run mutex is level 0), D7 yes (the CLAUDE.md sentence is replaced in W4.2's commit), D8 after this plan's bars have passed for 14 days. D1 was executed by the orchestrator the same day (see the addendum).

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | Today's repair (section 0, W0.1) | (a) repair forward now in one small commit: provenance file back, quarantine untracked and ignored; (b) leave it to the next bot run, which would re-add the provenance file (it is on disk and owned) but keep the quarantine copies tracked | **(a), today, before 07:00 on 09-24.** Never rewrite the pushed `cec9779a3`. Separately, the owner of this morning's repair decides the three other staged adds (`browser-capture-due-2026-09-18.flag`, `-09-20.flag`, `throttled/family-fare-2026-08-31.throttled.json`), since this plan could not verify whether the pipeline meant to delete them |
| D2 | A session's dirty file on a path upstream changed | (a) PARTIAL sync to the newest observed push tip before it, else blocked; (b) block the whole sync (the winner); (c) merge into the session's file (the winner's F8) | **(a).** (c) was marked down by both judges on safety. (b) freezes the checkout whenever any of the dirty non-owned files is touched upstream: 12 such files today, 10 of them with an upstream commit in the last 7 days (SCRATCH, sync-always). (a)'s selection logic is not yet proved, and W3.1 owes that proof |
| D3 | How the size gate treats a carried backlog | (a) carry records: each refused run's own adds are vouched at one run's caps; (b) 600 / 50 per capture date (the winner); (c) 300 / 25 per date (judge 2's graft); (d) defer (sync-first) | **(a).** (b) admits a 350-file same-day flood (judge 2). (c) still refuses 09-23 (26.3 MB dated 09-23). (d) leaves 09-23's actual cause standing |
| D4 | How the synced code runs when capture-run.ps1 or a startup lib changed | (a) re-exec; the parent holds the mutex and waits, the child inherits by token, and an abandoned mutex checks the child's liveness; (b) the parent releases and the child takes the mutex (a catch-up can win the race and run instead); (c) no re-exec, accepting a one-run lag | **(a).** capture-run.ps1 or a startup lib changed on 11 of the last 15 days (53 commits since 09-09; SCRATCH, planner `git log`), so (c) would lag most days. (a) keeps Task Scheduler's view of the run and its exit code honest. Whether the headless wrapper kills children when the parent exits is unknown, which rules (b) out until measured |
| D5 | Live from the first commit, or a report-only period | (a) live, with the kill switch, the fixtures and the mutants as the proof of ready; (b) a week in which the start sync only classifies and logs | **(a)**, matching your 2026-09-23 ruling on the push plan (*"I dont want to shadow"*). The first live run is a scheduled one; watch its sync row |
| D6 | Declare the capture-run mutex in the lock order | (a) level 0, outermost; (b) leave it undeclared | **(a).** It already nests over the push lock and the ledger locks today. Declaring it records what exists |
| D7 | The CLAUDE.md sentence about the 07:00 bot | replace it, when W4.2 lands, with: *"The ~07:00 and ~08:00 bots bring the main checkout to origin/main with a two-way move at the start and end of every run (lib/checkout-sync.ps1): no stash, no rebase. A dirty file of yours on a path upstream changed is never written: the sync goes partial and pages. Kill switch: .git\tc-checkout-sync.disabled."* | **Replace it** in W4.2's commit |
| D8 | Convert graph nightly, harvest and push-data to the same mover | (a) after this plan's bars pass for 14 days; (b) now; (c) never | **(a)** |

## 13. Results against the bars

Empty until read-outs. Each line is `B<n>: <result> (N=<n>, report blob <id>, window <from>..<to>)`.

## 14. Evidence register

Every entry is scratch. None is committed.

| Harness | Blob | Run by | Result |
|---|---|---|---|
| `%TEMP%\selfheal-syncalways\sync-proto.ps1` + `fixtures.ps1` | `3ddd9f98c415`, `0b261c3cb365` (reads `git-blob-lib.ps1` `269b920d5b08` = origin/main) | winner; judges 1 and 2; planner from `%TEMP%\selfheal-plan\proto-copy\` | 54 passed, 0 failed, exit 0, `SYNC-PROTO SELF-TEST PASS` (planner's run) |
| `%TEMP%\selfheal-syncfirst\exp1.sh` to `exp6.sh` | `42095a95ed5b`, `887b472dfd71`, `66ae865f66ca`, `8f02285ed725`, `39da140c44f3`, `0f504d02cfd0` | sync-first | E1-E11 as quoted; E1, E1b, E1c, E2, E4, E5f re-run by judges 1 and 2 |
| `%TEMP%\selfheal-syncfirst\probe-ps.ps1` | `b53e99edfd73` | sync-first | parse-from-object-DB 0 errors on 5 startup files, 2 on a broken snippet; a child's `WaitOne` on a parent-held mutex is False; exit 0 |
| `%TEMP%\selfheal-syncfirst\dryrun-classify.ps1` | `1a7d5fb92a76` | sync-first, read-only | 6 behind, 153 dirty, 1 SERVED collision (not re-run by anyone) |
| `%TEMP%\selfheal-judge\judge-exp.sh` | `a3ebaf92cacf` | judge 1 | X1-X6; exit 0 |
| `%TEMP%\selfheal-judge\j1.sh` | `772a10124f3d` | judge 2 | E-reruns; a staged new file stays staged |
| `%TEMP%\selfheal-judge\j2.ps1` | `4100b6c95a7d` | judge 2; **planner re-run, exit 0, `J2-PROBE-COMPLETE`** | the section 2.6 table |
| `%TEMP%\selfheal-judge\syncalways-copy\j3.ps1` | `ee981db31435` | judge 2 | winner's prototype under a held file: run 1 blocked with a mixed tree, run 2 synced |
| `%TEMP%\selfheal-plan\p1-heldfile-recovery.ps1` | `436f8f022e76` | planner | 18 passed, 0 failed, exit 0, `P1 HELD-FILE RECOVERY PROBE SELF-TEST PASS`; forward, backward and still-held recovery |
| `%TEMP%\selfheal-detect\checkout-sync-lib.ps1` | `10673b07c7a2` | a third angle | not read beyond its header; not scored |

**Git reads by the planner** (one-off commands, SCRATCH):
- ancestry of `ba13faba0` (rc 0) and `03d587117` (rc 1) against `54bff6167`;
- merge base `4ba348d48`, and 137 behind at `cc2d28e50`;
- the sizes of `df1d6429e` and `5d842a7f8`;
- the stat of `209eb6edb`, landed after its rebase as `cec9779a3` (186 files; 60 A, 5 D, 117 M, 4 renames);
- the section 0 blobs;
- the `.gitignore` grep (rc 1) and `check-ignore` (rc 1);
- 53 commits on 11 of 15 days to capture-run.ps1 and its startup libs since 09-09.

**Claims carried from the designs that nobody has proved** (each is owed by the item named):
- the partial sync's tip selection (W3.1);
- the re-exec handoff end to end, and the orphan case (W4.1);
- `merge-tree -X theirs` parity beyond one same-line conflict (W3.1, F6 extended to a modify/delete case, which must
  give `degraded`);
- a SESSION commit made with the real index between `read-tree` and `update-ref` (W3.1, an F11 twin through the real
  index);
- the winner's 10 mutants (section 8 re-runs its own set).

## Addendum, same day (orchestrator, after the panel)

**D1 is executed.** Commit `73eec5dd0` (landed through push-main, first attempt) moves `graph/provenance/2026-09-22.jsonl` back to its
path (blob `246c77c390ef7527e4540731be7e0c7939db8699`, unchanged), takes the other two quarantine copies out of the
tree (history keeps them at `cec9779a3`; a copy is kept outside the repo), and adds `/grocery/out/untracked-quarantine/`
to `.gitignore`. `cec9779a3` is not rewritten.

**A further defect the plan must cover: the private-index commit can RESURRECT files it deleted.** After the forced
run's commit (`cec9779a3`, which deleted `grocery/out/browser-capture-due-2026-09-18.flag`,
`...-2026-09-20.flag` and `grocery/out/throttled/family-fare-2026-08-31.throttled.json` as routine cleanup), all
three were back ON DISK, byte-identical to their last tracked blobs, and STAGED as adds in the shared index. Before
the orchestrator's sync they read ` D` (deleted on disk); the push-time `rebase.autoStash` restored them from the real
index, which still held entries the private-index commit had deleted from HEAD. A stale `browser-capture-due` flag on
disk can raise a false "capture due" condition, and any whole-index commit would re-add all three. The orchestrator
unstaged them and moved them outside the repo (backup kept). The mover that replaces the autostash tail must resync the
real index for DELETED paths of the bot commit too, and a fixture must assert that a path the bot commit deletes is
absent from both the index and the disk after the push.