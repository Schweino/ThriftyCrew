# Phase 6 - the loop's own evidence, efficiency and honesty

Part of `design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md`. Read its sections 4, 6 and 8, and your item's row in section 5, first. An evidence
id "x/y" resolves to `design/brain-review-2026-09-22/digest-x.md`, finding y.

## W6.1 Subagent failures are recorded

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** M. **Needs:** W1.1 (q3), W1.7, W1.8.

**Why.** 0 of 1,237 resolved subagent outcomes are burned or blocked, against 81 and 39 of 1,020 main-session rows.
PostToolUse does not fire on failures, and the harvesters read top-level transcripts only. 0 of 122 drafts are READY,
and 0 of the 85 with shadow evidence clear the ladder's bar. Whether subagent blindness is the cause is unmeasured:
tool-tier reads it as lost statistical power, offline-loop as a bias toward "fine". (tool-tier/subagent-evidence-invisible;
offline-loop/reflex-promotion-dead-end)

**Steps.**
1. If q3 confirms PostToolUseFailure, register `recall-reflex-outcome-hook.py` on it for Bash|PowerShell|Edit|Write
   (procedure P1, with the table row).
   - Add a branch that reads `payload['error']`. `recall_failure.is_failure` reads `tool_response`, which this payload
     lacks, so without the branch every failure logs `unknown`.
   - The existing reflex deny-marker test decides `blocked`.
   - A failure whose tool_use_id is in the W4.2 first-write log with `decision: deny` logs verdict `first-write-deny`.
     It is never burned or blocked, and never attributed to a reflex row.
   - Join on tool_use_id (W1.7).
2. The harvesters `recall-tool-probes`, `recall-failure-harvest` and `recall-reflex-outcome-join` read through W1.8's
   iterator. Dedup live rows against backfill rows by tool_use_id.
3. **In the same commit, re-run `recall_reflex.py --rate` for EVERY row** against the new probe corpus. Record before
   and after, with the corpus fingerprint and the probe count by origin (main, subagent, workflow). A row that crosses
   its max_fire_rate goes to Brad as a finding. Never raise a cap to make the night green.
4. **Floor:** the sleep hook-health prints WARN when resolved subagent outcomes number at least 200 and burned plus
   blocked is 0.
5. After landing, re-run the ladder unchanged, and report how many drafts clear it, with the denominator.

**Fixtures.**
- MUST FIRE: a PostToolUseFailure payload with error text and an agent_id logs burned for that agent.
- MUST FIRE: the reflex deny text logs blocked.
- MUST FIRE: W4.2's deny text, with its tool_use_id in a temp first-write log, logs first-write-deny.
- MUST NOT FIRE: a success row with the same tool_use_id is not overwritten.
- CLEAN TWIN: the main-session fixtures pass unchanged.

## W6.2 Did an edit-time reminder change the next edit? A control arm

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** M. **Needs:** W4.1 with 7 days of fires, W4.2, W6.1. **Brad:** D12b.

**The signal.** Read transcripts through W1.8. A later Edit or Write by the same (sid, agent) to the same path either
removed the shape (fixed) or kept it (persisted). This is cheaper and less confounded than a git join, which the 07:00
bot, push-main's rebase and pruned branches all distort.

**The control.** For the machinery rows ONLY, split fires deterministically by `sha1(tool_use_id)` parity into shown and
shadow (never shown), for a stated 14-day window.
- During the window, W4.2's deny reason omits the machinery lines for shadow-arm tool_use_ids, using the same parity.
- Both arms exclude any call whose tool_use_id is in the first-write log with `decision: deny`, and the redo that follows
  it.

**Bar (written now).** Shown-arm fixed rate minus shadow-arm fixed rate: at least 20 points, over at least 40 fires per
arm. Reported with both denominators, whatever it comes out as. The report script is committed and blob-cited.

## W6.3 The nightly signal means what it says

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** M.

**Why.**
- The nightly pass was red on 11 of its last 12 runs, and went RED was mailed on 9 of 9 nights, mostly for index drift
  and a reflex cap breach.
- It has no reindex step, although drift means the live semantic leg is behind the corpus.
- 20 of its 30 steps' output never reaches the report.
- Forgetting and clusters are computed 3 times a night.
- The recall-inbox self-test runs 2,253 searches against the live index.
- The sleep pass commits WITHOUT a pathspec (`recall-sleep.py:400`).
(offline-loop/ratchet-falls-fail-the-night, unread-step-outputs, duplicated-nightly-work; critic.md guardrails)

**Steps.**
1. Add a sleep step "reindex" (`recall-reindex.py`, then the embed index) before "gate", run when any corpus file is
   newer than the index stamp.
2. `classify_failures` classes a ratchet FALL as `can-tighten`, never `broken`.
3. Compute forgetting and clusters once, and hand the output file to the digest and the inbox.
4. Make the recall-inbox self-test hermetic, on a temp store with RECALL_INDEX_DB redirected.
5. The report shows the ladder's per-row PROMOTE and REVIEW lines and the habit drafts, or deletes the steps nobody
   reads. The commit lists which.
6. **`commit_outputs` commits with a pathspec:** `["git", "-C", home, "commit", "-q", "-F", msg, "--"] + changed`.
   Fixture: a file staged by another writer in a temp repo is still staged, and absent from the commit, afterwards.
7. Leave "derive floors" exactly as it is. Brad ruled on it on 2026-09-22 (ALREADY-RULED).

**Bar.** Over the 7 nights after landing, every red night names a cause that is neither index drift nor a ratchet fall.
Report the red count out of 7.

## W6.4 Brad's unapplied rulings are applied, and the approvals page reads the live store

**Repo:** both. **Lands via:** the graph exports through push-main from a worktree holding graph.db; a `~/.claude` commit for steps 2-5. **Effort:** M. **Brad:** D13.

**Why.**
- On 2026-09-12 Brad answered 88 approvals in one sitting.
- One apply batch of 70 answers (69 graph-alias rulings needing work, plus 1 cluster ruling) hit HTTP 429 and was never
  retried.
- His other 4 graph-alias answers were Holds, skipped by design.
- So all 73 graph-alias rulings (51 Reject, 18 Accept, 4 Hold) still read "proposed", 10 days later.
- The approvals page runs from a separate 09-12 checkout, so it reads 164 of 187 memories and 45 of 70 cluster rulings.
(offline-loop/approvals-applies-dead, approvals-server-stale-checkout)

**Steps.**
1. **Re-apply the rulings once, by hand, from the place D13 names.**
   - **Never the main checkout.** An ingest in `C:\Codex\ThriftyCrew` writes the tracked
     `graph/learning/proposals.json` and `approved-patches.json` into the shared tree, and the 07:00 bot commits them
     ungated.
   - **Never a worktree without graph.db.** `graph/sqlite/graph.db` is gitignored (`graph/.gitignore:4`) and no seed
     carries it. Rebuild it in the worktree with `C:/Codex/Python312/python.exe graph/lib/rebuild.py`, and read its
     exit code and verify line before ingesting.
   - Graph rulings need no LLM. The verdicts file carries `reviewer: 'Brad via approvals page 2026-09-12'`: an
     attribution, not a model name. `graph/learning/stage2_review.py:195` otherwise writes `claude-fable-medium`.
   - Before ingesting, re-validate each of the 69 against today's `proposals.json`: same id, status still proposed,
     payload hash unchanged. Skip and name any that moved.
   - The argv never contains `--apply`.
   - Land the exports with a pathspec commit through push-main.
2. **`approvals_runner.py`.** Retry a JOB only if it died before doing any work: a short run, no worktree created, no
   commit on its branch. A "429" match alone is not enough. Retry at most 3 times, then set a named `retry-later` state
   the page shows.
3. `recall-inbox --list` and the digest's graph row subtract answered-but-unapplied ids, as the approvals page already
   does.
4. The approvals server reads the live `CLAUDE_HOME`.
5. The digest rows compute AgeDays instead of hard-coding 0. 6 of 9 rows do that today.

## W6.5 Bridge currency, and the frozen refusal cases

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** S.

- **`check-bridge-currency.py`,** a separate read-only report, never inside check-skills' L2 gate. For every
  `path:LINE` citation in an applies-here.md it reports:
  - FILE-MISSING;
  - DRIFT: a backticked identifier from the same sentence occurs in the file, but not within 15 lines. Exactly 15 is not
    DRIFT; 16 is;
  - IDENT-GONE;
  - UNANCHORED.
  Restrict identifiers to tokens found in the cited file's history, so craft terms do not flag. 11 of 20 sampled line
  anchors had drifted.
- **Authoring rule,** added to `course/CONSOLIDATE.md`: cite a path plus an identifier, never a bare line number without
  its blob.
- **The frozen 2a case sets.** The sets are `~/.claude/skills/course/path-signal-cases.jsonl` (candidate 1) and
  `course/craft-signal-cases.jsonl` (candidate 3).
  - Commit a scoring harness FIRST. It reads `want_current` when present, prints how many rows used it, and reproduces
    the recorded 4 of 20 and 10 of 20 on the unremapped rows, blob-cited.
  - Then add `want_current` to the 11 candidate-3 labels and the 2 candidate-1 paths that no longer resolve. Never edit
    `want`.
  - Remap by the same basename under `concurrency-craft/`. Never remap from software-craft's MOVED table, which maps
    entry numbers.
  (bridge-and-routing/bridge-claims-rot, refusal-instrument-rotted)

## W6.6 The always-loaded budget is measured, then ratcheted

**Repo:** both. **Lands via:** `~/.claude` commit (check-skills, the MEMORY.md warn); push-main (the run-gates ratchet). **Effort:** S. **Needs:** D2.

A ThriftyCrew session starts with 155,320 B of instructions, 76% of it rules. Nothing budgets CLAUDE.md, rules or
MEMORY.md. After the rules decision, and never before (marks set today would bless the accidental load):
- check-skills reports the machine-wide sum per project, from W1.2's log;
- a ThriftyCrew run-gates ratchet holds the TC-side bytes (TC CLAUDE.md plus unconditional rules), so a TC edit is caught
  at a TC push;
- MEMORY.md warns at 180 lines or 22,500 B, recording the CLI version its harness limits were read from.
Every ratchet here FAILS only on a rise. A fall prints "can tighten" and keeps the mark.

## W6.7 Logs are archived, never deleted

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** M. **Needs:** W2.4 step 3, because every writer must be on recall_append first.

About 28 MB of recall logs has accumulated since 2026-09-06, with no rotation.
- New `recall-log-archive.py`, a nightly step. It moves rows older than 60 days into
  `<RECALL_ARCHIVE_DIR>/<name>-<YYYY-MM>.jsonl.gz` (env RECALL_ARCHIVE_DIR, default `~/.claude/recall-archive/`, added
  to `redirected_env`) and never deletes them.
- It holds a per-log lock, `<log>.archive-lock`, that `recall_append` also takes. The append side is bounded at about
  200 ms and fails open by appending unlocked, which it logs.
- Immediately before `os.replace`, re-stat the live log. If its size is no longer the size that was read, an append
  landed (locked or not): discard the temp and retry, at most 3 times. Then print `ARCHIVE SKIPPED <log>: grew during
  the archive` and leave the log whole. A PermissionError on replace retries 5 times (10 to 160 ms), then skips the same
  way.
- **Lock order, stated in the commit:** W2.4's state lock is now held across append_rows' log-lock wait, so the order
  is state lock (outer), then log lock (inner). The archiver takes only log locks, never a state lock, so no cycle
  exists. Amend W2.4's "leaf" sentence in `locked_state`'s docstring in the same commit.
- A log with no row past 60 days is left byte-identical.
- It prints rows kept and archived per log.
- The outcome join, recall-recurrence and the ladder read through one `iter_rows(name, since)` that spans the archive
  and the live file. They change in the same commit.

**Fixtures.**
- 8 concurrent appenders through the real hook write paths lose 0 rows during an archive rewrite.
- An appender that times out and appends unlocked between the archive's read and its replace leaves its row present.
- A day-59 row stays live, and a day-61 row is archived.

## W6.8 The memory semantic leg stays gated (no build)

**Repo:** none (no build).

PLAN-brain-efficiency's held-out memory floor is still the ruled next step, and it is useful only after W2.1. This plan
does not build it. If Brad wants it (D16), follow memory-and-budget/memory-bodies-never-retrieved's steps and critique.
Never reuse MIN_COSINE 0.548. Derive the floor once, on a seeded half.

**CLOSED 2026-09-25 by Brad's D16 ruling:** "Don't build it (Recommended)". The memory semantic leg is not built;
lessons reach the work through command-shape reflexes and the always-loaded index, and re-trying needs a new labelled
set and a bar written first (memory:similarity-recall-of-memories-fails).

## W6.9 The push tier stops reading green when blind

**Repo:** ThriftyCrew. **Lands via:** `ops\push-main.ps1`. **Effort:** M. Order matters.

**Why.** The one observed goal-1 miss shipped through here. `ops/audit-readjson-inline-wrap.ps1` (2026-09-21)
reproduced tree-walk's founding bug. It scans 0 files with exit 0 in every worktree (12 of 12), and run-gates scores a
zero-file scan as ok. (estate-machinery/readjson-gate-reproduced-founding-bug, static-zero-scan-passes, count-ratchet-slack)

**In this order.**
1. **Fix the readjson walk.**
   - Use `Get-TcTreeFiles -PruneBelow` AND keep the below-root filter.
   - Keep the `-ne $PSCommandPath` exclusion.
   - Exit 3 with `scanned=0 blind=1` on zero files.
   - Add a New-TcWorktreeFixture MUST FIRE.
   - Then run `audit-full-path-excludes -Tighten`, and commit its baseline.
2. **Survey, then score zero scans as blind.**
   - List every static gate's latest marker in WORKTREE logs as well as main: read `<checkout>\ops\out\gate-readings.jsonl`
     for each path in `git worktree list`.
   - Collect each static gate whose marker reports `scanned|files|examined|resolved` = 0 with rc 0 into `$staticBlind`,
     reading the marker already captured at run-gates.ps1 line 931. The exception is a gate whose `$static` entry says
     `zero_ok = $true`, with the reason in a comment.
   - When `$fail` is empty and `$staticBlind` is not, `$gateCode` is 3, and the final Exit-Guard summary BEGINS
     `blind=static-scanned-zero`, with no ':' and no path: pre-push's grep stops at them.
   - Name the gates on the line `run-gates: COULD NOT EVALUATE - static gate(s) scanned zero files: <list>`. A red gate
     still outranks blind.
   - In the SAME change:
     - add a `static-scanned-zero)` branch to `ops/hooks/pre-push`'s `case "$blind"`;
     - update run-gates' own header list of causes (lines 27-39);
     - update ThriftyCrew CLAUDE.md's "A 3 HAS FIVE CAUSES", which becomes six;
     - apply the same rule to the Python static loop.
   - Land this step only when the survey reads 0 static gates that scan zero without `zero_ok`, in the main checkout AND
     in a freshly seeded worktree, with both counts in the commit message. Any other zero-scan gate is fixed, or given
     `zero_ok = $true` with its reason, in the same change.
3. **One named-site comparison.** Lift it into `lib/ratchet.ps1` as `Compare-TcRatchetSites`: multisets, keyed on the
   path below root plus the normalised line text. Move `test-native-stderr-eap` and `audit-typed-param-shadow` onto it in
   the same change, so there is one copy, not three.

## W6.10 Harness facts carry a re-check date

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** S.

- Reuse `course/CLAIMS-REGISTER.md`'s existing "Recheck by" column. Add one `Probe` column, and tag harness rows
  `[harness]` in the Claim cell. No second register.
- Add a read-only `harness-facts-check.py --report`. It lists overdue rows, and greps live text for retired phrases (for
  example "Loaded only when you touch" and "THE FIELD IS `globs`") outside `[CORRECTED]`, `[REFUTED]` and `[REVERSED]`
  blocks. Settle that marker grammar BEFORE the first run.
- Wire it into check-skills as a ratchet that FAILS only on a rise. A fall prints `harness-facts: can tighten N -> M` as
  a warning and keeps the mark, a constant changed by hand. Do not copy check-skills.py:2554-2557, which fails on a fall.

## W6.11 The Store: rule's cheap escapes are measured, then closed

**Repo:** ThriftyCrew. **Lands via:** `ops\push-main.ps1`. **Effort:** S. **Needs:** W0.1. **Brad:** D1b.

**The forms to catch:**
- `NOTHING_RE` (store_citation.py:67) has no quote requirement today. It gains one: `searched` must be followed by at
  least one `"..."`, `'...'` or smart-quoted term. It keeps accepting the observed "nothing further applicable".
- A citation set drawn ONLY from index files counts as naming nothing. The index files are CLAUDE.md, MEMORY.md,
  memory:MEMORY, CATALOGUE.md, knowledge-search/SKILL.md and knowledge/SKILL.md, keyed on basename after resolution.
- `Store-Exempt:` needs at least 3 words.

**Implementation.**
- Add a constant `ESCAPES_REFUSE_FROM = None` beside REFUSE_FROM, commented "Brad sets this (D1b); None means warn only".
- The three checks set verdict `escape-warn`, or `refuse` only once ESCAPES_REFUSE_FROM is set and passed. They NEVER go
  through `d["mode"]`: this item lands after 2026-09-25, when mode is already refuse.
- `run_commit_check` prints its own head for `escape-warn`, `store-citation: NOTE (escape form, recorded, not refused)`,
  and exits 0. It must not fall through to "BLOCKED".
- Bump `expected`.

**Fixtures.**
- CLEAN TWIN: on 2026-09-30, `Store: CLAUDE.md` alone gives escape-warn and exit 0.
- MUST FIRE: with ESCAPES_REFUSE_FROM set to a past date, the same line refuses.
- CLEAN TWIN: the missing-Store:-line case on 2026-09-30 still refuses.

**Also:**
- a remind reflex on `git commit` with `-n` or `--no-verify`;
- store-usage-report's landed-commit replay (reuse W0.1's harness) lists landed Claude code commits that have no
  decision row. That is the only place a bypass shows, and the estate's pre-commit hook recommends `--no-verify` in 6 of
  its messages.

## W6.12 The docs say what the code does (the sweep for anything left over)

**Repo:** both. **Lands via:** each doc with its item; leftovers as one commit per repo. **Effort:** S. Fix each doc in the same commit as the item it describes. This item catches what is left.

- `automatic-recall.md`:
  - 2a: "the directory rules already do" is false (W4.3);
  - 3a: the memory index is built and consulted by no hook;
  - section 2's table gains rows as hooks land, plus a "workflow agent" reach row;
  - section 7 records what this plan measured.
- `knowledge-search/SKILL.md:17`: the hooks' corpus is skills, plus exact memory slugs.
- `recall-intent-hook.py:29` claims a `filter_new` dedup it does not use.
- `recall_core.budget_state` and `MAX_SESSION_BYTES` bound nothing live: wire them, or delete them and the claim.

## W6.13 Hook health by origin

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** S. **Needs:** W1.8.

`recall-stop-hook --health` splits by origin (main, worktree, cowork, sdk-cli, scheduled) over the last 14 days. It
prints a STRUCTURAL GAP note, not an outage, when N is at least 5 and fewer than half beat.

**Fixtures:**
- MUST NOT FIRE: the case at the bar, N=6 with exactly 3 beating (not fewer than half).
- MUST FIRE: the step past it, N=6 with 2 beating.
- MUST FIRE: the case at the N bar, N=5 with 2 beating.
- MUST NOT FIRE: N=4 with 0 beating (below the N of 5).
