# Phase 4 - goal 1 at the moment of coding

Part of `design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md`. Read its sections 4, 6 and 8, and your item's row in section 5, first, especially
procedure P2, the one `recall-reflex-hook.py main()` order. An evidence id "x/y" resolves to
`design/brain-review-2026-09-22/digest-x.md`, finding y.

## W4.1 Machinery recognition rows in the one reflex engine: a few by hand, the rest generated

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** M. **Needs:** W3.2, W1.7. **Brad:** D9, for the
set-content rung only.

**Why.**
- 0 of 30 reflex rows name an estate helper.
- In ThriftyCrew .ps1 edits over 7 days, a construct a helper replaces was ADDED while the helper was absent: Move-Item
  -Force 73 of 90 candidates (60 outside tests), Set-Content/Out-File 23 of 32, List[object] 7 of 15, Add-Content 3 of 4.
- The readjson gate of 2026-09-21 reproduced tree-walk's founding bug at char 4,693, past the 2,000-char window.
(tool-tier/machinery-rows-absent; estate-machinery/no-edit-time-construct-recognition, prose-only-helpers)

**Engine changes** (`recall_reflex.py`, `recall-reflex-hook.py`):
1. **New optional row fields**, read in `in_scope()`:
   - `class: 'machinery'`;
   - `exts: [...]`, applied ONLY when kind == 'edit' and read from the path line alone. Never reuse `scope` for this:
     `scope` is a substring test over the whole action text;
   - `except_paths: [...]`: fnmatch below the repo root, naming the helper file, the gate file and `**/test-*.ps1`;
   - `helper`;
   - `gate`, which may be `none`;
   - `gate_fixture`: a literal copied from the gate's own MUST FIRE;
   - `file_context`: a regex that must also match the whole post-edit file;
   - `needle`: a lowercase literal checked with `in` before the regex runs.
2. **Match text.** Add `recall_core.action_text_for_match(tool, ti)`.
   - Write: the path plus the full content, capped at 262,144.
   - Edit: the path plus the REBUILT post-edit file: read the file on disk and apply old_string -> new_string once (the
     recall-memory-lint-hook precedent).
   - A command: its first 65,536 chars.
   - Leave `action_text_from_input` and its 2,000-char cap untouched: it is the chash join key.
3. **Site count rising.** A machinery row fires only when its match count in the rebuilt file is GREATER than in the
   file on disk (0 for a new file). Unchanged context lines never fire.
4. **Generated rows.** `machinery_index.py --reflex-rows <root>` writes
   `<RECALL_MACHINERY_CACHE>/<project_key(canonical_root(root))>/reflex-rows.json`. That is ONE file per repository,
   keyed on the canonical (main) root, so a worktree edit loads the main checkout's rows; the nightly sleep step writes
   it after `ensure_current`. It holds one row per `# REPLACES:` pattern. Each row has:
   - class `machinery`;
   - `helper`: the lib file plus the function its USE WHEN names;
   - `gate`: the ENFORCED BY path, or `none`;
   - `exts` from the lib's language;
   - `except_paths`: the lib and its gate;
   - rung remind;
   - must_fire and must_not_fire from the gate's MUST FIRE literal, or from the REPLACES-FIRE and REPLACES-SILENT lines.
   - `max_fire_rate: 0.02`.
   Emission rules:
   - `# REPLACES-FIRE:` and `# REPLACES-SILENT:` may each repeat. A pattern with fewer than two of either (the
     two-and-two rule the hand rows follow) is NOT emitted, and is listed BLIND.
   - A row is emitted only when `recall_reflex.py --rate` scores it `ok`. One scored TOO LOUD, NO CAP DECLARED or TOO
     FEW PROBES TO JUDGE is not emitted, and is listed with that verdict.
   `recall_reflex` loads the file for `canonical_root` of the edit's target path, after `recall-reflexes.json`: one
   engine. A missing or unparseable file logs one `reflex-rows BLIND <why>` row and never raises. A generated row whose
   id collides with a hand row is dropped and counted.
5. **Every fire row and remind prints the matched index entry:** the helper, its lib, and its gate, or "no gate enforces
   this; the helper is the only guard".

**Hand rows** (in `recall-reflexes.json`: rung remind, tools [Edit, Write], exts ['.ps1','.psm1'], scope
`codex/thriftycrew`, max_fire_rate 0.02, source the named ops-and-gates.md bullet):

| Row | Helper | Gate |
|---|---|---|
| `machinery-bare-replace`: Move-Item -Force, including `mi`/`-fo` as the gate counts them | Write-TcAtomicFile (lib/atomic-write.ps1) | ops/audit-bare-replace.ps1 (allow `# atomic-replace:allow`) |
| `machinery-list-array-wrap`: `@(` of a `New-Object ...List[object]` variable, keyed on the WRAP, not the creation | `::new()`, or assign then wrap | ops/audit-list-array-wrap.ps1 (allow `# list-array-wrap:allow`) |
| `machinery-filtered-walk`: `Get-ChildItem ... -Recurse ... \| Where-Object ... worktrees\|.claude` | Get-TcTreeFiles -PruneBelow (lib/tree-walk.ps1) | ops/audit-full-path-excludes.ps1 (no allow marker) |
| `machinery-fixed-temp`: Join-Path $env:TEMP '<literal>' with no NewGuid/$PID | a per-run dir (GcScratch in lib/guard-contract.ps1) | ops/audit-fixed-temp-names.ps1 (no allow marker) |
| `machinery-native-redirect-eap`: file_context `$ErrorActionPreference\s*=\s*'Stop'`, and a native exe with `2>&1`/`2>$null` | Invoke-Native (grocery/native-lib.ps1) | grocery/test-native-stderr-eap.ps1 (no allow marker) |

Message template: `<the trap in one clause>; the estate helper is <Fn> in <helper>; <gate> refuses a new site at push`.
Add `; a deliberate exception carries <marker>` ONLY where the gate honours one. The prose-only helpers (Add-TcLine,
Enter-TcLedgerLock, Write-TcLfFile) come through generated rows, not hand rows.

**`set-content-no-encoding`: amend the MESSAGE, and add `exts` (['.ps1','.psm1']).** The tie-break:
- a commit message goes through `[IO.File]::WriteAllText` with no BOM;
- a TRACKED ThriftyCrew file through Write-TcLfFile;
- a file others read through Write-TcAtomicFile;
- anything else `-Encoding utf8`.
Its rung stays rewrite until D9.

**Fixtures.** Each row carries two must_fire and two must_not_fire from real code, plus these self-test cases:
- CLEAN TWIN: every machinery row with a file helper names a helper file and a gate that exist. A row whose helper is
  an idiom (`::new()`) carries `helper_kind: idiom` and is skipped by name. `gate: none` prints SKIPPED gate=none. With
  the TC root absent, it prints SKIPPED with the reason.
- MUST FIRE: a temp gate file missing its row's `gate_fixture` literal is reported DRIFT.
- CLEAN TWIN: each live `gate_fixture` literal still appears in its gate file.
- MUST FIRE: an Edit adding `Move-Item $t $p -Force` to a grocery .ps1 with 0 sites on disk.
- MUST FIRE: `mi $t $p -fo`.
- MUST NOT FIRE: old_string already held that line.
- MUST NOT FIRE: a line carrying `# atomic-replace:allow`.
- MUST NOT FIRE: a Write of `ops/audit-bare-replace.ps1` itself.
- MUST NOT FIRE: an `exts` row on a `.md` or `.py` path.
- CLEAN TWIN: `memory-without-cost-band` (no exts) still fires on its `.md` path.
- MUST FIRE: a generated row from a temp lib's REPLACES / REPLACES-FIRE lines fires on the FIRE line and not the SILENT
  line.
- MUST FIRE: a REPLACES with no examples is listed BLIND and not loaded.
- Hang guard: all rows plus all drafts over a synthetic 256 KB .ps1 finish inside 60 s. This is generous, not a speed
  bar.

**Measure.** `recall-tool-probes.py` stores edit probes at path + 16,000 chars, not 1,200. Re-run `recall_reflex.py
--rate` for EVERY row in the same commit, recording before and after with the corpus fingerprint. Otherwise a row goes
TOO LOUD with nobody touching it.

**Bar before any row leaves remind.** 7 days of fires at most 2% of eligible calls each, then W6.2's per-row numbers.
The later `edit_block` rung is per row, and Brad's (D12). It waives only on the gate's own allow marker, never on
`# reflex-override`.

## W4.2 Search before the first in-scope write, per context: code files and analysis records

**Repo:** brain. **Lands via:** `~/.claude` commit; each mode flip is its own commit. **Effort:** M.
**Needs:** W4.1, W2.1, W2.2, W3.3, W1.6, W1.5, W5.1 step 1, W5.3. **Brad:** D3 (deny), D3b (headless).
**Mode sequence:** shadow for 7 days, then remind for 3 days, then deny on D3.

**Why.** This is the mechanism for both goals, at the one event proven to fire in every context: PreToolUse on
Bash|PowerShell|Edit|Write, in main sessions, subagents and workflow agents.
- Today 11 of 38 Agent-tool editing contexts search before their first edit.
- Refusals of this shape are obeyed (the brief gate).
- A reminder at this event lands AFTER the write, so only a deny acts first.
(critic ranked change 4; prompt-tier missed finding; plan-review-coverage)

**Files.**
- `recall-reflex-hook.py`: steps 6 and 8 of procedure P2.
- `recall-log-open.py`: the marker writer.
- New log `~/.claude/recall-first-write-log.jsonl` (env RECALL_FIRST_WRITE_LOG).
- Mode file `~/.claude/skills/recall-first-write-mode.json` (tracked): `{"mode": "shadow"}` by default, then `remind`,
  then `deny`. Env RECALL_FIRST_WRITE_MODE names the mode FILE's path, never the value.
- Marker dir `~/.claude/recall-searched/` (env RECALL_SEARCHED_DIR).
- New committed report `~/.claude/skills/first-write-report.py`.

**Steps.**
1. **Targets.** A call's targets are:
   - the `file_path` of an Edit or Write;
   - for a Bash or PowerShell call, each LITERAL path that is the direct target of a write in the command:
     `[IO.File]::WriteAllText(`, `Set-Content`, `Out-File`, `Add-Content`, `Write-TcLfFile`, `Write-TcAtomicFile`, the
     destination of `Copy-Item`, `Move-Item`, `cp` or `mv`, `cat >` / `cat >>`, `tee`, a `> <path>` redirect, and Python
     `open(<path>, 'w'...)`.
   A target built from a variable is not resolved: log `unresolved_target: true` and never deny on it. The
   triage-reviewer writes every plan through PowerShell (6 of 6), so without this step goal 2's triage lane is out of
   reach.
2. **Scope.** A target is in scope when it is either:
   - a CODE file: extension in store_citation's CODE_EXT (.ps1 .psm1 .py .js .ts .sql .sh), under a git toplevel
     (`checkout_root`); or
   - an ANALYSIS RECORD: `design/<PREFIX>-*.md` with `<PREFIX>` in ANALYSIS_RECORD_PREFIXES, or
     `grocery/triage-plans/plan-*.json` excluding `*.routing.json`.
   Always out of scope: `*/out/*`, `%TEMP%`, any `scratchpad` path, `AppData`, `~/.claude/projects/**` and `~/.claude/cache/**`.
3. **The marker (this item's commit adds the writer to recall-log-open.py).** A PostToolUse Bash/PowerShell payload
   counts only when BOTH hold:
   - the command passes W1.6 step 3's test: it matches `knowledge-search[\\/]+search\.py`, is not `--selftest`, and its
     segment's leading verb is not a reader;
   - the last non-empty line of the tool_response stdout matches
     `^KNOWLEDGE-SEARCH-COMPLETE legs=\d+ hits=\d+ blind=\d+$`.
   Then create `$RECALL_SEARCHED_DIR/<session_key>.mark` with O_EXCL, or, if it already exists, `os.utime` it to now.
   - `marker_age_s` is now minus the marker's mtime. hits=0 still counts.
   - An empty query, a usage error, `--help` or `--selftest` prints no such line, so creates no marker. A piped search
     that cuts the last line is not counted, which is why the deny text says to run it unpiped.
   - `session_key` is session_id plus agent_id (`recall_core.session_key`).
   - It never touches shared state. Sweep markers older than 48 h.
4. **The check.** The marker is valid for `SEARCH_MARKER_TTL_S = 14400` (4 hours). The comment beside the constant says
   it is the first plausible value, not the survivor of a sweep, and that the log records `marker_age_s` so it can be
   re-derived.
5. **Shadow mode.** Append a row and emit nothing: `{t, sid, agent, tool, repo, target_rel, kind: code|record,
   would_deny, marker_age_s, machinery_ids, route_ids, headless, unresolved_target, tool_use_id, mode}`.
6. **Deny mode.** On the FIRST in-scope write with no valid marker, emit `permissionDecision: deny` with a reason of at
   most 900 B:
   ```
   First code change in this context, and no knowledge search has run here (search before code: ~/.claude/CLAUDE.md).
   Run this, then redo the change:
     C:/Codex/Python312/python.exe C:/Users/Owner/.claude/skills/knowledge-search/search.py --estate --estate-root "<checkout_root(target)>" "<3-6 words for what this change does>"
   Estate machinery this text already touches (exact match, not a search):
     - line 41: Move-Item -Force -> Write-TcAtomicFile (lib/atomic-write.ps1); push gate ops/audit-bare-replace.ps1
   Run it unpiped. "Nothing applicable" is an accepted outcome: say so in the Store: line. Redoing the change without a search proceeds, and is logged.
   ```
   - Once W4.3 is live, its route lines for the target follow the machinery lines, inside the 900 B cap (P2 step 7).
   - `--estate-root` is computed from the TARGET path, so a brain edit made from a ThriftyCrew cwd searches the brain.
   - The command always carries `--estate`, because its SKILLS leg is byte-identical to a plain search. If W3.3's bar did
     not hold, this item does not leave remind mode, and D3 goes to Brad with W3.3's result attached.
   - For an analysis record, the command example reads `"<the method> <the subject>"`, and the machinery line is
     replaced by a pointer to `C:/Users/Owner/.claude/skills/experiment-craft/analysis-preflight.md` (W5.1).
   - Log `decision: deny` with the tool_use_id. The fire rows for that call carry `acted: "first-write-deny"` and do not
     increment `state['reflexes']`: the redo after the search is the fire that counts. W6.1 relies on this.
7. **Brake.** At most ONE deny per context, recorded with an O_EXCL `<session_key>.denied` marker. A second in-scope
   write proceeds and logs `retried_without_search: true`, so an agent without Bash cannot loop.
8. **Analysis-record pointer.** On the FIRST analysis-record write in a context that already holds a valid marker, emit
   one additionalContext line, once per context (O_EXCL `<session_key>.record-pointed`): "Analysis record: the preflight
   is C:/Users/Owner/.claude/skills/experiment-craft/analysis-preflight.md; the rules are
   C:/Codex/ThriftyCrew/.claude/rules/measurement.md." It lands after the write, which is fine, because records are
   revised. If W1.1 (q9) shows PostToolUse additionalContext is delivered for Edit/Write, emit it from PostToolUse instead.
9. **Headless and probe-dependent fallbacks.**
   - When `recall_core.headless_reason(os.environ)` is non-empty, deny mode logs `would_deny` and emits nothing, until
     D3b.
   - If W1.1 (q4) shows an Edit deny is NOT honoured inside Workflow agents, those contexts are logged only.
   - If W1.1 (q10) shows workflow agents share one agent_id, every agent after the first would share one marker:
     workflow contexts stay log-only until that is solved.
10. **Remind mode** (an intermediate step): emit the deny text as additionalContext instead of denying. It lands after
    the write, and exists only to measure the text before deny.
11. **Fail open.** Any exception proceeds silently.

**Fixtures** (reflex-hook and recall-log-open self-tests, `redirected_env` plus RECALL_SEARCHED_DIR and
RECALL_FIRST_WRITE_MODE; the live mode file's sha256 is unchanged afterwards):
- MUST FIRE: deny mode, no marker, a Write of `C:\Codex\ThriftyCrew\grocery\x.ps1` is denied. The reason contains
  `search.py --estate` and contains no backslash in the command line and no `%`.
- MUST FIRE: the same with `Move-Item $t $p -Force` in the content, and the reason names Write-TcAtomicFile.
- MUST FIRE: a Write whose content fires NO reflex row is still denied (proves step 6 runs before P2's step 8).
- MUST FIRE: PowerShell `[IO.File]::WriteAllText('C:\Codex\ThriftyCrew\grocery\triage-plans\plan-2026-09-30.json', $j)`
  is denied, with the analysis wording.
- MUST FIRE: a payload with cwd `C:\Codex\ThriftyCrew` writing `C:\Users\Owner\.claude\skills\x.py` is denied with
  `--estate-root "C:/Users/Owner/.claude"`.
- MUST FIRE: a marker one second past the TTL is expired, and the write is denied.
- MUST NOT FIRE: a marker exactly AT the TTL is valid, and the write proceeds. Use an integer clock.
- MUST NOT FIRE: a second write after a deny proceeds and logs `retried_without_search`.
- MUST NOT FIRE: out-of-scope targets are silent: a `%TEMP%` `.ps1`, `grocery\out\x.json`, a scratchpad `.py`, a `.md`
  note, a `*.routing.json`.
- MUST NOT FIRE: `Get-Content <a triage plan>` has no write target.
- MUST NOT FIRE: `Set-Content $p $x` logs `unresolved_target` and does not deny.
- MUST NOT FIRE: a different agent_id under the same session_id is judged on its OWN marker.
- MUST NOT FIRE: deny mode with TC_HEADLESS=1 logs would_deny and emits nothing.
- Marker writer:
  - MUST FIRE: a PostToolUse search.py payload whose response ends with a KNOWLEDGE-SEARCH-COMPLETE line, with agent a1,
    creates `$RECALL_SEARCHED_DIR/<key>.mark`.
  - MUST NOT FIRE: a response with no COMPLETE line (an empty query) creates none.
  - MUST NOT FIRE: `cat .../search.py`, whose tool_response is the real search.py source (which contains the print
    statement for the COMPLETE line), creates none.
  - CLEAN TWIN: a second search 5 minutes later refreshes the existing marker's mtime.
- CLEAN TWIN: shadow mode writes a row and emits nothing.
- CLEAN TWIN: a first write whose content trips `get-content-no-encoding` is denied, and its fire row carries
  `acted: first-write-deny`.
- CLEAN TWIN: a context holding a code marker writes `design\MEASURE-x-2026-09-30.md`, proceeds, and gets the
  analysis-record pointer once. Its second record write gets nothing.
- CLEAN TWIN: a malformed mode file means shadow.

**Bars (written now).**
- **Promotion from shadow** (7 days; D3), all excluding W1.9's rows:
  - (a) contexts that would be denied, per day, printed with their median;
  - (b) 50 would-deny rows, drawn deterministically (sorted by t, first per context), hand-labelled in-scope or
    out-of-scope, with one row per label in a committed jsonl: out-of-scope at most 5 of 50;
  - (c) the producer floor: on any day with W1.5 coverage rows for in-scope targets, first-write rows are at least 1.
- **Keep-or-revise after 14 days in deny** (`first-write-report.py`, blob-cited; it joins the first-write log with W1.6
  search-call rows on (sid, agent), cross-checked from transcripts through W1.8):
  - M1a, searched before the first in-scope write ATTEMPT: reported;
  - M1b, searched before the first in-scope write that was NOT denied: at least 80%, N printed;
  - M2, `retried_without_search`: at most 20% of denies;
  - M3, a key the context's own search returned is cited: at least 25%, per origin (main, agent, workflow).
    `first-write-report.py` normalises both sides before the join. It strips the leg prefix and any `#<lead>`, maps
    `memory:<store>/<slug>` to `memory:<slug>` and `rules:<file>` to `.claude/rules/<file>`, and compares repo-relative
    paths with forward slashes, case-insensitively.
  Below either bar, the finding goes to Brad, never into a second deny.

**2026-09-25, Brad's D3 ruling:** "Remind now, decide refusals after 3 days (Recommended)". The mode moved from shadow
to remind the same day (brain commit db77e20). The shadow's numbers, from `first-write-report.py` on 2026-09-25: M1b 5
of 62 contexts (8%); M3 main 0 of 2 and workflow 1 of 6 against the 25% bar; would-deny contexts 37 on 09-23 and 21 on
09-24. Refusals are Brad's call on 3 days of remind data, which the one-time task d3-first-write-remind-review-0928
reports on 2026-09-28.

**Traps.**
- Keying the marker on session_id alone lets one parent's search back every subagent.
- Writing the marker into shared state loses it.
- Denying on the SECOND write traps an agent in a loop.
- Taking the estate root from cwd sends brain edits to ThriftyCrew's index.
- Judging only Edit/Write misses the triage lane.

## W4.3 Store sections that cite this exact file, delivered on Read, Edit and Run, in shadow first

**Repo:** brain. **Lands via:** `~/.claude` commit; the mode flip is its own commit. **Effort:** M. **Needs:** W4.2.

**Why.** 845 estate-path citations in the applies-here files, and more in memories, already say which knowledge governs
which file. Nothing delivers them by path, and automatic-recall.md 2a's "the directory rules already do" is false: the
rules cite 0 applies-here sections. (bridge-and-routing/path-route-shadow, bridge-not-path-routed;
offline-loop/no-estate-vocabulary-bridge)

**Files.**
- New `~/.claude/skills/build-path-routes.py`, run at the end of `build-catalogue.py` and as a nightly sleep step. It
  writes `~/.claude/path-routes.json` (env RECALL_PATH_ROUTES).
- New `~/.claude/skills/recall_path_route.py` with `consult(payload) -> (text, hits)`.
- Mode file `~/.claude/skills/recall-path-route-mode.json`, default shadow. Env RECALL_PATH_ROUTE_MODE names the mode
  FILE's path, never the value.
- Log `~/.claude/recall-path-route-log.jsonl` (env RECALL_PATH_ROUTE_LOG).
- Per-context seen files in `~/.claude/recall-route-seen/` (env RECALL_ROUTE_SEEN_DIR).

**Steps.**
1. **Build.**
   - Chunk with `recall_index.chunks_for(full, rel, kind)`: kind 'skills' for `*/applies-here.md`, kind 'memory' for
     memory files in the stores W2.1 resolves. Never call `chunk_file` directly: the index keeps a memory file as ONE
     chunk headed by its description, and only `chunks_for` reproduces the index's hit_keys.
   - Normalise the corpus part of each key, because the semantic and lexical legs shape it differently.
   - Extract directory-qualified estate paths and bare script names. Resolve a bare name against `git ls-files`, and drop
     a bare name that resolves to more than one file (12 basenames collide).
   - Keep at most 3 routes per file, ranked: a qualified citation beats a bare one; a section whose heading names the
     file comes first; then more citations, then fewer bytes.
   - Record the source file sha256s, and set `stale: true` when any source has changed since the build.
2. **Hosts, with no new settings entry.**
   - (a) `recall-log-open.py` on PostToolUse Read. A Read comes before an Edit, so this lands BEFORE the edit. It runs
     immediately after `found` is built and BEFORE the classify loop and its `if not rows: return 0` (about line 291),
     because classify() returns None for estate code.
   - (b) `recall-reflex-hook.py` at P2 step 7 for edits. When step 6 denied, live routes ride in the deny reason; in
     shadow they are only logged. This is the only host that sees a NEW file.
   - (c) the same hook for a Bash/PowerShell command that RUNS a cited script or harness (`powershell -File <path>`,
     `python(\.exe)? <path>` including a full interpreter path such as `C:/Codex/Python312/python.exe`, `& <path>`), as
     kind 'run'. This is the analysis action.
3. **Dedup and budget.** Use the per-context seen file of hit_keys (append through recall_append), with a cap of 12
   routes per context. Never use the shared `offered` dict: it would reach its 60-section cap in about 20 files and
   silence the prompt hook.
4. **Shadow.** Write `{t, sid, agent, host: read|edit|run, target_rel, routed:[hit_key], stale, eligible:true, mode}` and
   inject nothing.

**Bar (written now).**
- Draw 40 (file, section) pairs deterministically, taking the first routed pair per session sorted by t. Mix in 20
  control pairs, each a section citing a DIFFERENT file. Label them blind to the arm: "GOVERNS = the section states a
  rule or fact a change to this file must respect". Write one row per pair per label.
- Promote to live only if all three hold:
  - at least 28 of the 40 are GOVERNS;
  - the control arm is at most 6 of 20;
  - routes fire on at least 30% of route-eligible read/edit events, counted before dedup.
- The run host is scored separately, on the same bar.
- Otherwise, record the refusal in automatic-recall.md 2a beside the other two.

**Fixtures.**
- MUST FIRE: an Edit of `C:\Codex\ThriftyCrew\lib\json-io.ps1` routes the concurrency-craft entry citing it.
- MUST FIRE: the same file under `.claude\worktrees\x\`.
- MUST FIRE: a PostToolUse Read of that file writes one shadow row.
- MUST FIRE: `powershell -File ops\probe-gate-slot-fairness.ps1` routes as kind run, if a section cites it.
- MUST NOT FIRE: the same basename under %TEMP%, or a Fantasy file.
- MUST NOT FIRE: a second Edit of the same file in the same context.
- MUST NOT FIRE: an ambiguous bare name (`cost-engine.ps1`).
- CLEAN TWIN: the prompt hook still injects after 25 routed files in one session.
- CLEAN TWIN: a malformed routes file gives exit 0 and no output.
Fixture data lives in a per-run temp store, never `~/.claude`.

## W4.4 Gate the two unchecked spawn routes

**Repo:** brain. **Lands via:** `~/.claude` commit (settings.json by procedure P1). **Effort:** S each.
**Needs:** W1.1 (q2), W1.3. **Brad:** D5.

**spawn_task** (only if q2 shows PreToolUse fires for `mcp__ccd_session__spawn_task`).
- Add a SEPARATE settings.json PreToolUse entry for that matcher (procedure P1), running `recall-brief-gate-hook.py`
  only. Never add it to the `Agent|Task` block: `recall-agent-hook` would then rewrite the chip's prompt through
  updatedInput.
- The gate accepts that tool name, and its HOW text names the `prompt` field.
- Fixtures, from a frozen real spawn_task input (keys prompt, title, tldr):
  - MUST FIRE: no section is denied.
  - CLEAN TWIN: a memory citation passes silently.
  - MUST NOT FIRE: `mcp__ccd_session__mark_chapter`.
  - MUST NOT FIRE: recall-agent-hook stays silent on a spawn_task payload.
  - CLEAN TWIN: every existing Agent case keeps its verdict.
- Evidence: 1 of 24 spawn_task prompts carried a section.

**Workflow** (only if q2 shows PreToolUse fires for `Workflow` and carries `script` or `scriptPath`).
- New `recall-workflow-gate-hook.py` on its own matcher `Workflow` (P1). Its automatic-recall.md s2 table row goes in
  the same commit.
- Read `tool_input.script`, or the file named by `tool_input.scriptPath`. Unreadable means skip, and log it.
- Strip `//` and `/* */` comments first.
- Pass when a string or template literal contains `knowledge consulted` and the text after it (up to the closing
  backtick, or 4,000 chars) matches brief-gate's EVIDENCE_RE. The literal must also be USED: the identifier of the const
  holding it appears at least twice, or the section is inlined in every `agent(` prompt. Derive the identifier; never
  hard-code `KNOWLEDGE`.
- Waiver: a `// knowledge-exempt: <reason>` line, which is logged.
- Never return updatedInput, and fail open.
- Log to W1.3's log with tool=Workflow and the `agent(` count.
- Do NOT reuse brief-gate's HEAD_RE: it is line-anchored and DENIES the one compliant script on disk.
- Fixtures, from frozen copies under `skills/fixtures/workflow-gate/`:
  - MUST FIRE: the 2026-07-30 code-sweep script, which has no section.
  - MUST FIRE: a script whose only mention is inside a comment.
  - CLEAN TWIN: this review's `brain-review` and `brain-plan-review` scripts pass.
  - CLEAN TWIN: a script that inlines the section in each prompt passes.
  - CLEAN TWIN: searched-nothing passes.
  - MUST NOT FIRE: a Bash payload, empty stdin, or non-JSON.
- Evidence: 1 of 34 saved workflow scripts carry a section. Use is low now (1 run in September) but unbounded under
  ultracode.

## W4.5 The brain itself is covered

**Repo:** both. **Lands via:** step 0 through push-main FIRST; then one `~/.claude` commit for steps 1-7. **Effort:** S-M.
**Needs:** W0.1, W3.3, W4.1. **Brad:** D17.

**Why.** Nothing checks an edit to the brain's own code:
- `~/.claude` has 0 hooks;
- 0 of 30 reflex rows are scoped to the brain;
- 0 of 68 brain edits in 7 days got any injection;
- the hooks run from the working tree, so a saved edit is live before any test.
A heuristic replay reads 15 of 19 recent Claude code commits in the brain repo with no Store: line. (critic scenario
vii; record-tier/brain-repo-unjudged; plan-review-compliance)

**Steps.**
0. **ThriftyCrew `ops/store_citation.py`:**
   - When the committing toplevel is not a ThriftyCrew checkout, also resolve repo-relative tokens against the tracked
     set of `RECALL_ESTATE_ROOT`, default `C:\Codex\ThriftyCrew`. Use ONE `git -C <root> ls-files`, with the git
     variables removed only for that child. Record `resolved_in: estate`.
   - Add a per-repo refuse date: `BRAIN_REFUSE_FROM = None` beside REFUSE_FROM, commented "Brad sets this (D17); None
     means warn only". When the toplevel is `~/.claude`, mode is refuse only when it is set and today is on or after it.
   - Bump `expected`.
   - Fixtures:
     - MUST NOT FIRE: a temp brain commit citing `design/PLAN-x.md` and `.claude/rules/r.md`, both tracked in a temp
       estate repo, passes;
     - MUST FIRE: a token tracked in neither repo is refused once BRAIN_REFUSE_FROM is set and passed;
     - CLEAN TWIN: with BRAIN_REFUSE_FROM None, a brain commit with no Store: line WARNS and exits 0.
1. **The hook.** Add a tracked `~/.claude/skills/hooks/commit-msg` (bash, LF).
   - Copy ThriftyCrew's BOM-refusal half.
   - When CLAUDE_CODE_SESSION_ID is set, call `/c/Codex/ThriftyCrew/ops/store_citation.py --commit-msg "$1"`. That is the
     MAIN checkout path, never a worktree.
   - When the script or interpreter is missing, print `store-citation: BLIND` and exit 0.
   - The hook first runs `grep -q BRAIN_REFUSE_FROM /c/Codex/ThriftyCrew/ops/store_citation.py`. If the constant is
     absent, the main checkout has not rebased past step 0: print `store-citation: BLIND - the main checkout's resolver
     predates W4.5 step 0` and exit 0. Install the hook only after that grep succeeds; `install-brain-hooks.py --check`
     exits 3 in that state.
2. **The installer.** Add `~/.claude/skills/install-brain-hooks.py`. It copies the hook into
   `git -C ~/.claude rev-parse --git-path hooks` with LF bytes, reads it back and compares. `--check` exits 1 when the hook
   is missing or stale, and 3 when blind. The nightly sleep report runs `--check`.
3. **Before asking D17:** replay brain commits since 2026-09-15 through `judge_message`, and print "would refuse N of M"
   in the commit.
   **2026-09-25, Brad's D17 ruling:** "Oct 2, after a week of warnings (Recommended)". The brain commit-msg hook was
   installed 2026-09-25 (`install-brain-hooks.py --check` exit 0, CURRENT), so the warning week starts that day.
   Heuristic count: 44 of 140 brain commits since 09-15 carry no Store: line, 34 of them on 09-18, before the rule.
   The one-time task d17-brain-refuse-date-1002 replays the week through `judge_message` on 2026-10-02 and sets
   BRAIN_REFUSE_FROM only if at most 2, or 10%, of code commits would refuse.
4. **Brain-scoped reflex rows** (scope `.claude/skills`, exts ['.py']):
   - `brain-log-not-redirectable`: an assignment STATEMENT (continuation lines joined) whose right side has
     `os.path.join(...'recall-*.jsonl')` and no `environ` read. MUST NOT FIRE on recall-reflex-hook.py:62-63, whose
     `os.environ.get("RECALL_REFLEX_LOG")` is on the line before the join.
   - `brain-lossy-append`: `open(` with an `'a'` mode on a `recall-` path, pointing to recall_append.
5. **`approvals_runner.build_prompt`** adds the store-first line, using the section 4.7 command and naming the memory
   directory explicitly, since its runs work in worktrees. The self-test asserts it on the function's RETURN value, with
   the needle built by concatenation. It lands before BRAIN_REFUSE_FROM.
6. **The nightly sleep report** lists brain files modified and uncommitted for more than 12 hours.
7. **If W1.1 (q8)** shows a nested CLAUDE.md outside the cwd loads on a Read, add `~/.claude/skills/CLAUDE.md`, at most 40
   lines, holding the brain's invariants:
   - redirectable RECALL_* logs;
   - the load_state allow-list;
   - recall_append;
   - self-tests never touch live state;
   - fail open;
   - no hook change inside another task.
   Otherwise, put one pointer line in the global CLAUDE.md (D6).

## W4.6 Fantasy

**Repo:** Fantasy. **Lands via:** a local install in the Fantasy repo on D8 (no push gate there). **Effort:** S.
**Needs:** W0.1. **Brad:** D8, D15.

- The global CLAUDE.md's Store: rule already covers Fantasy, and 0 of 5 of its commits since 09-01 carry the line. Only
  the enforcement is ThriftyCrew-scoped. W4.2's first-write gate already reaches Fantasy code, because Fantasy has a git
  toplevel.
- If D8 is yes:
  - install a warn-only commit-msg hook in `C:\Codex\Fantasy\.git\hooks`, calling a VENDORED copy of store_citation kept
    in the Fantasy repo. Never make ThriftyCrew's gate depend on a file outside its repo;
  - log to the same decision log with `repo: Fantasy`;
  - store-usage-report splits every rate by repo.
- D15: `C:\Codex\CLAUDE.md` says Fantasy has no git (it has), and ThriftyCrew's row quotes 2,284 commits (3,249 on
  2026-09-22). That file is unversioned, so Brad corrects it by hand.
