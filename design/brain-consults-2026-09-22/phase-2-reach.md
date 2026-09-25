# Phase 2 - reach and hygiene

Part of `design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md`. Read its sections 4, 6 and 8, and your item's row in section 5, first. An evidence
id "x/y" resolves to `design/brain-review-2026-09-22/digest-x.md`, finding y.

## W2.1 One project-root function: worktree and subdirectory sessions get their memory corpus

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** M.

**Why.** `recall_index.resolve_roots(cwd)` keys memory on the raw cwd. A worktree or repo subdirectory therefore
resolves NO memory, even though the harness loads the main MEMORY.md. From a subdirectory it resolves no rules either.
19 of 40 TC transcripts since 09-16 ran from a worktree.

The live cost today is small: exact-slug memory routing (4 offers ever) and memory-lint's near-duplicate check, which
cannot fire. But every memory leg and the `--estate` search depend on it.

`project_key` keeps `.` while the harness turns every non-alphanumeric character into `-`. That affects worktree dir
names and corpus tags only, since it already matches all 30 non-worktree dirs. (prompt-tier/worktree-memory-key-mismatch,
OVERSTATED; memory-and-budget/project-key-from-raw-cwd, near-duplicate-lookup-dead)

**Files.** `knowledge-search/recall_index.py`, plus these callers:
- `recall_tiers._memory_dir` (delete this copy);
- `memory_lint.near_duplicates`;
- `recall-log-open.py`'s classifier;
- `recall-agent-hook.py`;
- `recall-hook.py`;
- `recall-embed-memory.py`.

**Steps.**
1. Add `canonical_root(cwd)`.
   - Run `git -C <cwd> rev-parse --path-format=absolute --git-common-dir` with a 2 s timeout and the eight git variables
     removed from the CHILD env. If the result ends in `.git`, the root is its parent.
   - Cache real answers in-process and in `~/.claude/recall-root-cache.json` (env RECALL_ROOT_CACHE). Write the cache
     through `<file>.<pid>.tmp` and `os.replace`; an unparseable cache is a miss and is rewritten.
   - **Never cache a fallback.** A timeout, a non-zero exit or an exception returns the raw cwd for THIS call only and
     writes no cache entry.
   - Respect `autoMemoryDirectory` if settings.json sets it.
2. Add `checkout_root(cwd)`: `git rev-parse --show-toplevel`, with the same env and cache rules.
3. `project_key(path)` becomes `re.sub(r'[^A-Za-z0-9]', '-', str(path))`, with NO rstrip. Past 200 chars the harness
   appends a hash Python cannot reproduce, so fall back to the existing `projects/*` dir whose name starts with the
   200-char prefix.
4. `resolve_roots`:
   - take memory from `projects/<project_key(canonical_root)>/memory`;
   - take rules from `<checkout_root>/.claude/rules`, which is the worktree's own checkout, tagged PER CHECKOUT. Never
     tag a worktree's rules with the main checkout's tag, or the index flips one corpus between two directories.
5. `refresh_if_due`: keep one last_refresh timestamp PER ROOT SET, not a single global one.
6. `memory_lint.near_duplicates`: open each hit through `{corpus_tag: root}` from `resolve_roots`, not the process cwd.
   Skip unreadable hits and count them. Return None only when no hit could be judged.
7. Add `recall_index --check-live`. It prints, for every transcript dir on disk, whether `project_key` of its first
   recorded cwd equals the dir name, and names the over-200 cases resolved by prefix. It exits 3 when it read 0 dirs.

**Fixtures** (`recall_index --selftest`: temp HOME, temp repo plus `git worktree add`, eight git variables cleared, never
the live DB):
- MUST FIRE: a worktree cwd resolves `memory:<main key>`.
- MUST FIRE: a subdirectory cwd resolves the repo's memory AND its rules.
- MUST NOT FIRE: a non-git dir (the `C:\Codex` container shape) keys on itself.
- MUST NOT FIRE: a submodule `.git` file whose gitdir has no `/worktrees/` keys on the submodule.
- MUST FIRE: a fake git that sleeps past the timeout yields the raw cwd AND leaves no cache entry.
- CLEAN TWIN: the next call, with a working git, caches the real root.
- CLEAN TWIN: the main-checkout roots are byte-identical to today's.
- CLEAN TWIN: `project_key('C:\\a.b\\c_d e') == 'C--a-b-c-d-e'`.
- memory_lint, real-path case (a real index in a temp HOME):
  - an identical description returns `('a', >= 0.8)`;
  - an unrelated one returns [];
  - an unreadable single hit returns None.

**Gate.** Run `recall-hook-calibrate.py` before and after, and record the store-wide lowest clearing probe and its margin
(automatic-recall.md s6).

**Done when.**
- A live worktree cwd lists `memory:C--Codex-ThriftyCrew` with 187 files.
- `named_files` returns the memory from a worktree.
- `--check-live` prints its N.
- Every suite named above exits 0.

## W2.2 One harness-text strip; scheduled-task envelopes are skipped

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** S.

**Why.**
- 548 of 977 prompt offers (56.1%) in 7 days answered a `<scheduled-task ...>` envelope, and 0 were opened.
- The strip in `recall-hook.py` matches only BARE tags, so an attributed tag survives it.
- The correction hook strips nothing: 4 of its 6 lifetime rows are harness text.
- `recall-dream.py:201` has a third, weaker test that misses the Cowork shape. 371 of 373 Cowork transcripts open with a
  system-reminder.
(prompt-tier/scheduled-task-envelope-floods-offers, correction-hook-reads-harness-envelopes)

**Steps.**
1. Move `_strip_harness_text` and `_HARNESS_BLOCKS` from `recall-hook.py` into `recall_core.strip_harness_text()`.
   - Tags accept attributes (`<tag(\s[^>]*)?>`).
   - The tag list gains `scheduled-task` and `system-reminder`.
2. Add `recall_core.is_scheduled_envelope(raw)`: a regex match of
   `\s*(?:<system-reminder>.*?</system-reminder>\s*)*<scheduled-task\b` with `re.S`.
   - Type it from scratch. A copy from the digest carries `<\` escaping artefacts, and those add a `\s` class to the
     pattern.
3. `recall-hook.py`: AFTER the turn-id and heartbeat writes, if `is_scheduled_envelope` is true, write one row to
   recall-log.jsonl (RECALL_LOG), `{t, ev:'skip', why:'scheduled-task', name, sid, agent, turn}`, and return 0 with no
   stdout. recall-stats counts only offer and open rows, so the skip rows change none of its figures.
4. `recall-correction-hook.py` and `recall-dream.py` call the same two functions. The correction hook records nothing
   when no human text remains.
5. Move `headless_reason(env)` from `recall-consulted-hook.py` into `recall_core` in the same change, since W4.2 needs
   it. Its signature and behaviour are unchanged.
6. New read-only `~/.claude/skills/scheduled-task-knowledge-lint.py`, called from check-skills as a WARNING. It lists
   each `~/.claude/scheduled-tasks/*/SKILL.md` with no search.py instruction, matching the command rather than a
   heading.

**Fixtures** (recall-hook --selftest, redirected env):
- MUST FIRE: the grocery-alert-triage envelope gives empty stdout and exactly one skip row naming it.
- MUST FIRE: the Cowork shape (a leading system-reminder, then an attributed scheduled-task) is skipped.
- MUST NOT FIRE: "why did the scheduled-task grocery-alert-triage fail twice today" still retrieves.
- CLEAN TWIN: a task-notification still strips to empty and writes no skip row.
- CLEAN TWIN: the timing row is still written on the skip path.
- Correction hook:
  - MUST NOT FIRE: a task-notification whose result holds "constantly" and "not what I asked";
  - MUST NOT FIRE: an attributed scheduled-task holding "stop";
  - CLEAN TWIN: the 2026-09-22 Chrome-tabs sentence is still recorded.

**Bar.** After 7 days the scheduled-envelope share of offers reads 0 of N, with the non-scheduled open rate printed beside
it (baseline 27 of 429), excluding W1.9's rows.

## W2.3 Tell the truth about the rules files: option A now, option B only on a ruling

**Repo:** both. **Lands via:** one ThriftyCrew commit through push-main, plus one brain commit. **Effort:** S.
**Brad:** D2 for option B.

**Why.**
- Every rules file declares `globs:` and `alwaysApply:`. The Claude Code loader never reads those; it reads `paths:`, in
  4 of 4 builds checked.
- So all six files load in every ThriftyCrew context: 118,538 B, in 33 of 33 transcripts.
- At least 9 records claim path scoping, and `ops/audit-rule-currency.ps1` validates the ignored key.
- The 2026-09-06 "the field is globs" verification read Bun's bundled Cursor template inside claude.exe.
- **This accident is what delivers the helper names and measurement.md to grocery, meal-prep, Bash-only and agent
  contexts today.**

**Option A, now.**
1. **ThriftyCrew rules files.** Delete the `globs:` and `alwaysApply:` lines from all six, keeping `description:`.
   Rewrite each file's "Loaded only when..." sentence (measurement.md's reads "Loaded when you touch...") to:
   "Loaded in every ThriftyCrew session: this file has no `paths:` key, on purpose
   (design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md, W2.3)."
2. **ThriftyCrew `ops/audit-rule-currency.ps1`**, in the SAME commit as step 1, so it is green on day one.
   - Parse `paths:` as a YAML list OR a comma string, mirroring the loader: a trailing `/**` is stripped, and a bare
     `**` means unconditional.
   - Exit 2 on any front matter carrying `globs:` or `alwaysApply:`, with the message "inert scope key: this file loads
     unconditionally".
   - Fixtures:
     - MUST FIRE: globs-only front matter.
     - MUST FIRE: the Bun-template shape.
     - MUST FIRE: a `paths:` YAML-list entry matching nothing (proves the list parser).
     - MUST NOT FIRE: a `paths:` list matching tracked files.
     - MUST NOT FIRE: a comma-string `paths:`.
     - CLEAN TWIN: no front matter is reported as unconditional by design.
3. **Correct every other carrier in one sweep.** The ThriftyCrew carriers (`design/BACKLOG-course-findings.md` E14,
   at line 1427, and any repo straggler the grep finds) go in step 1's worktree commit. The brain carriers and the
   memories below are edited from the MAIN session, because memory files must not be written from a worktree:
   - `~/.claude/skills/claude-code-craft/claude-md-and-commands.md` 11.1, as a `[REFUTED 2026-09-22]` block quoting the
     loader string `if(!t.paths)return{content:...}` and naming the Bun-template misread;
   - claude-code-craft MAP.md;
   - claim C3 in `course/archive/claims-settled-2026-09-07.md`, annotated `[REVERSED 2026-09-xx]`. Do not add a new C3
     row to CLAIMS-REGISTER.md;
   - `MEMORY.md:94`;
   - the memory `what-actually-reaches-a-spawned-agent`, which also gains the workflow-agent row;
   - `recall_core.py:546-547`;
   - `recall-agent-hook.py:13`;
   - `agent-workflow-craft/applies-here.md`.
   Find stragglers with `grep -rniE 'loaded( only)? when you touch|loads only when|path-scoped'` over `~/.claude/skills`,
   both memory stores and the repo.

**Option B, only after W1.1 (q7) and W1.2, and only on D2.** Split each rules file into an unconditional lead file and a
`paths:`-scoped depth file.
- The lead file carries one line per rule: the rule plus its "use X" target, written by a person who read the whole
  bullet.
- The narrative moves verbatim, with its dates and hashes, into the depth file.
- measurement.md stays unconditional under either option.
- `recall-agent-hook.py`'s "a subagent already has the rules" exclusion changes in the same commit as any scoping.

Rubric for judging A against B, written now:
- (i) session-start bytes in a main-checkout session: at most 50 KB, against 155 KB today;
- (ii) a Workflow agent asked to quote one lead from each of the 6 files: 6 of 6;
- (iii) from W1.2's log, the share of sessions that edit a file under grocery/ and loaded the grocery depth before their
  first edit: at least 90%, N printed.

**2026-09-25, option B judged and not taken.** Built on branch `experiment/rules-split-option-b` (left in place, pushed,
for reference) and measured against the three bars above, one row per case in
`design/brain-consults-2026-09-22/rules-split-b/rows-2026-09-25.jsonl` (blob e0189a48f2df) and `rows-ii-2026-09-25.jsonl`
(blob 3eadc3cf5053) on that branch: (i) 78,362 B against the 50,000 B bar (arm A 181,413 B); (ii) 0 of 6 leads quoted,
because a helper's rules come from the root session's checkout and a branch cannot reach one; (iii) 71 of 89 grocery
editors, 79.8%, against 90%. All three missed, so Brad ruled D2 the same day: keep A, ratchet the size, "Keep A, ratchet the
size (Recommended)". The ratchet is W6.6.

**Trap.** Renaming `globs:` to `paths:` verbatim is the most damaging mistake available here. It strips ops-and-gates.md
from the grocery and meal-prep writers, who hold 20 of 27 Write-TcAtomicFile, 15 of 16 Invoke-Native and 3 of 3
Enter-TcLedgerLock call sites. It also strips measurement.md from analysis work.

## W2.4 Session-state writes stop being lost, and every hook log appends atomically

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** M.

**Why.**
- `~/.claude/recall-sessions` holds 7,469 orphan `<key>.json.<pid>.tmp` files.
- `save_state` writes a tmp and `os.replace`s it. On Windows the replace fails while another hook holds the target open
  for read, and on failure it leaves the tmp and returns False.
- The reflex and intent hooks load, modify and save the same key on the same event: 581 of 738 roll-up keys show
  impossible beat counts.
- About 30 `open(..., 'a')` sites remain, and the reflex log tore a row on 2026-09-22.
(agent-tier missed recall-state-lost-writes; tool-tier/tool-tier-logs-use-lossy-append; offline-loop/session-state-writes-lost)

**Steps.**
1. **`recall_core.save_state`.**
   - Retry `os.replace` on PermissionError 5 times, waiting 10, 20, 40, 80 and 160 ms. This is a bounded wait whose
     result is branched on.
   - On final failure, remove the tmp and append `{ev:'save-fail', key, t}` to `~/.claude/recall-state-fail.jsonl`
     (env RECALL_STATE_FAIL_LOG).
   - Count every save: append one `{ev:'save', key, t, ok}` row per `save_state` call to
     `~/.claude/recall-state-saves.jsonl` (env RECALL_STATE_SAVES_LOG, added to `redirected_env`), so the loss RATE has
     a denominator. Never keep the count in session state: a counter inside the store that loses writes cannot measure
     its own loss.
   - `sweep_stale` also removes `*.tmp` older than 1 hour.
2. **`recall_core.locked_state(key)`, a context manager.**
   - It takes `<STATE_DIR>/<key>.lock` with O_EXCL, writing the holder's pid, then calls `load_state` and yields the
     dict. On exit it calls `save_state` and releases the lock in `finally`, only if the lock file still holds its pid.
   - Wait at most `RECALL_STATE_LOCK_WAIT_MS` (default 1000), polling every 10 ms. The wait must exceed the holder's
     worst case: save_state's retries alone total 310 ms.
   - On timeout, PROCEED unlocked and log `{ev:'lock-timeout', key, t}` to the state-fail log. A hook must never be why
     a tool call failed.
   - A lock older than 10 s is stale. Take it over by `os.replace`-ing your own lock file onto it and re-reading the pid,
     never by delete-then-create.
   - Convert every load...save pair to it:
     - recall-agent-hook.py:185/207;
     - recall-consulted-hook.py:246;
     - recall-correction-hook.py:67;
     - recall-hook.py:438;
     - recall-intent-hook.py:83/103;
     - recall-log-open.py:213;
     - recall-reflex-hook.py:130/168/192;
     - recall-stop-hook.py:239.
   - Never hold it across `recall_semantic.search` or any network call.
   - The commit message states the lock's place in the declared order: "this lock is a leaf; while HELD, the holder
     waits only on save_state's os.replace retries against lock-free readers, which never take this lock, so no wait
     cycle exists". Put the same sentence in `locked_state`'s docstring. W6.7 later amends both, because its log lock
     is taken inside this one.
3. **Appends.**
   - Convert the hook-path set (every script settings.json runs, plus what they import) from `open(<log>, 'a')` to one
     `recall_append.append_rows` call per invocation.
   - Add a static case to `recall_append.py --selftest`. It scans `recall_*.py` and `recall-*.py` with `tokenize`, so
     comments are skipped, for `open(` with an `'a'` mode.
     - It excludes `recall_append.py` by name, because its naive writer at line 74 is the race harness.
     - It allow-lists each nightly single-writer script by name, with its reason.
     - It prints the files scanned, which must be above 0.
     - The needle is built by concatenation.

**Fixtures.**
- MUST FIRE: a naive `os.replace` fails under a held reader, which proves the harness.
- CLEAN TWIN: the retrying save lands.
- MUST FIRE (timeout branch): a lock file held fresh by ANOTHER process makes the save proceed, and writes exactly one
  lock-timeout row.
- MUST FIRE (stale branch): a lock with an mtime 11 s old is taken over, and the save runs locked.
- Concurrency case:
  - 4 writers x 50 heartbeats;
  - the barrier sits immediately before each writer ENTERS `locked_state`;
  - `RECALL_STATE_LOCK_WAIT_MS=30000` as a hang guard, so the production timeout cannot decide the result;
  - assert a final count of 200 AND zero lock-timeout rows;
  - with the lock neutered in a temp mirror it must go red. Record the red rate over 10 runs in the commit.
- MUST FIRE: the append scanner flags a planted `open(x, "a")`.

**Done when.** A day after landing, the save-fail count is printed against saves as N of M, and orphan `.tmp` files
created that day are 0. The orphan count alone only proves the cleanup runs.
