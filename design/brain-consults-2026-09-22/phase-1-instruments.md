# Phase 1 - instruments (no behaviour change)

Part of `design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md`. Read its sections 4, 6 and 8, and your item's row in section 5, first. An evidence
id "x/y" resolves to `design/brain-review-2026-09-22/digest-x.md`, finding y.

## W1.0 One helper that redirects every live path in a fixture

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** S.

**Why.** Several self-tests write live state today. `recall-reflex-outcome-hook.py` and `recall-correction-hook.py` write
fake sessions (`sess1.json`, `nosession.json`) into the live `recall-sessions`. `recall_semantic.py --selftest` writes
the live sidecar breaker: its dead-URL count rose from 260 to 264 during the review. The persisted recall index
(`recall_index.DB_PATH`, line 91) cannot be redirected at all. Every later item's fixtures depend on this helper.
(tool-tier/selftest-writes-live-state; prompt-tier/semantic-selftest-writes-live-breaker)

**Steps.**
1. Add `recall_core.redirected_env(tmpdir, base=None) -> dict`. It returns a copy of `os.environ` in which EVERY
   `RECALL_*` variable that names a file or directory points under `tmpdir`.
   - Derive the list by scanning `~/.claude/skills/recall*.py` and `knowledge-search/*.py` for
     `os.environ.get("RECALL_...")` and `environ["RECALL_..."]`. Do not hand-copy a list.
   - A derived name is a PATH name when its default (the right side of `os.environ.get("RECALL_X") or <default>`) is an
     `os.path.join(...)` or a path constant. Every other derived name (for example RECALL_SIDECAR_URL,
     RECALL_MIN_COSINE, RECALL_DEBUG, RECALL_EXPLORE_RATE) goes in an explicit `NON_PATH` set with a one-line reason, and
     is copied unchanged. The scan found 55 distinct names on 2026-09-22.
   - It also removes `TC_HEADLESS` and `CLAUDE_CODE_ENTRYPOINT`. A caller that needs either sets it explicitly.
2. Add env `RECALL_INDEX_DB`, which `recall_index.connect` honours: `path = db_path or os.environ.get("RECALL_INDEX_DB")
   or DB_PATH`. Make `recall_reflex.TABLE_PATH` honour the EXISTING `RECALL_REFLEXES`
   (`os.environ.get("RECALL_REFLEXES") or os.path.join(HERE, "recall-reflexes.json")`), as recall-auto-accept.py:57 and
   recall-reflex-author.py:54 already do. Add no new name for it.
3. Move these self-tests onto the helper:
   - `recall-reflex-outcome-hook.py`;
   - `recall-correction-hook.py`;
   - `recall_semantic.py`: set the breaker path at the TOP of `selftest()`, before its first call, and restore it in
     `finally`.
4. The helper's own self-test:
   - MUST FIRE: a planted `os.environ.get("RECALL_ZZ_LOG") or os.path.join(...)` in a temp source file is covered by
     the derived list.
   - MUST FIRE: a planted derived name that is in neither the PATH class nor `NON_PATH` fails the self-test.
   - CLEAN TWIN: every derived PATH name in the returned env points under `tmpdir`.
   - CLEAN TWIN: every `NON_PATH` name keeps its ambient value.
   - MUST FIRE: `TC_HEADLESS` is absent from the returned env.
5. For the selftest-isolation fixes, prove the mechanism rather than comparing a file's md5, since live prompts rewrite
   that file. Run the subject as a child with the redirected env, and assert that the live directory gained no new file
   name. For the breaker, record the paths `breaker_note` writes during the self-test.

**Done when.** Every moved self-test exits 0, and after one run each, `recall-sessions` has no `sess1.json` or
`nosession.json` newer than the run.

## W1.1 One sandboxed probe of the harness events this plan depends on

**Repo:** brain. **Lands via:** `~/.claude` commit (the probe script and its dated results).
**Effort:** M. **Needs:** W1.0, W1.9. **Brad:** D18, for step 2's temporary box-wide entry.

**Why.** Several items rest on facts nobody has probed. The store also records "PostToolUse on failures cannot exist
[REFUTED 2026-09-07]", yet PostToolUseFailure is present in every installed build (2.1.173 through 2.1.280). Treat that
claim as unqualified until this probe answers it.

**Questions, one output row each:**
- (q1) SubagentStart fires for an Agent-tool agent and for a Workflow agent, and its additionalContext reaches the
  child (a quote test).
- (q2) PreToolUse fires for `tool_name` `Workflow` (with `script` or `scriptPath`), and for
  `mcp__ccd_session__spawn_task`.
- (q3) PostToolUseFailure fires, and what it carries, for `exit 42` in a subagent and for a hook-denied call.
- (q4) A PreToolUse DENY on Edit is honoured inside a Workflow agent (a Bash deny is).
- (q5) The SubagentStop fields `agent_transcript_path` and `last_assistant_message`.
- (q6) InstructionsLoaded `load_reason` after a Read, after a Bash `cat` and for a subagent Read, and the exact payload
  field names W1.2 will log.
- (q7) The rules two-file test: `paths:` against `globs:` against no front matter, with a comma-string `paths:` and a
  YAML list.
- (q8) Whether a nested CLAUDE.md outside the cwd tree (a temp dir standing in for `~/.claude/skills/CLAUDE.md`) loads
  on a Read.
- (q9) Whether a PostToolUse additionalContext is delivered for Edit/Write. W4.2 step 8 reads it: if it is, the
  analysis-record pointer moves to PostToolUse.
- (q10) Whether a workflow agent's PreToolUse payload carries a distinct `agent_id` per agent.

**Files.** New `~/.claude/skills/probes/harness-probe-2026-09.py`. It is committed, because a probe anyone may want to
re-run is a harness. It writes:
- a sandbox `settings.json` whose hooks are ONLY a logger, in the pattern of `skills/recall-probe.py`: one JSON line per
  invocation, every top-level payload key, no content bodies;
- a temp project dir holding `.claude/rules/a.md` (`paths: ["zz-nobody/**"]`), `b.md` (`globs: "zz-nobody/**"`), `c.md`
  (no front matter) and `d.md` (`paths: "zz-nobody/**, zz-other/**"`);
- files `zz-nobody/x.txt` and `zz-nobody/y.txt`.

**Steps.**
1. **Headless half.**
   - From the temp dir, run
     `claude -p --setting-sources project,local --settings <sandbox.json> --permission-mode bypassPermissions "<script>"`.
     `--settings` ADDS settings, so the user source must be excluded, or every live recall hook fires on the probe.
   - Set every `RECALL_*` path through `redirected_env`.
   - The script: Read `zz-nobody/x.txt`; Bash `cat zz-nobody/y.txt`; Bash `exit 42`; spawn one Agent-tool subagent that
     runs `exit 42`, Reads a file, and quotes any sentinel text it was given.
   - The sandbox logger is registered on SubagentStart, SubagentStop, PreToolUse, PostToolUse, PostToolUseFailure and
     InstructionsLoaded.
   - **First assertion, before any other:** only the sandbox logger fired. The redirected RECALL_LOG is empty, and no
     brief-gate text is in the transcript. If not, stop and record why.
   - If excluding the user source changes what a question measures (q1, q6, q8), say so in that question's output row.
2. **Desktop half** (Workflow and spawn_task exist only there).
   - After D18, add a TEMPORARY entry through procedure P1: PreToolUse matcher `Workflow|mcp__ccd_session__spawn_task`,
     plus SubagentStart, InstructionsLoaded and PostToolUseFailure, all running the logger.
   - The logger emits its SubagentStart sentinel ONLY when the payload's session_id equals the probing session's id,
     which it reads from a file the probe writes, so no other session's subagent receives it.
   - It carries a hard-coded expiry two hours after installation, after which it exits 0 at once.
   - For the probing session only, the logger also denies a PreToolUse Edit of `zz-nobody/deny-me.txt` (q3, q4), and
     emits a PostToolUse additionalContext sentinel after an Edit or Write under `zz-nobody/` (q9).
   - Run a 2-agent workflow: q10 needs two agent_ids to compare. Tell each agent to Edit `zz-nobody/deny-me.txt`, Write
     `zz-nobody/w.txt`, and quote any sentinel it was given. Then run one spawn_task.
   - Remove the entry in the same session: `git -C ~/.claude diff --exit-code -- settings.json` must exit 0.
   - Record in the dated results block the ids to exclude: the headless `claude -p` session ids, the workflow agent ids
     and the spawn_task child's session id. Never the Desktop session that ran the probe. W1.9 then adds them.
3. **Output.** A dated block in `claude-code-automation/hooks-measured-payloads.md`, one row per question. Record the CLI
   version of BOTH installs (memory `two-claude-code-installs-desktop-and-path`: `claude --version` reports the PATH
   binary, so record the Desktop build path too). Mark the automatic-recall.md s2 claim `[REFUTED 2026-09-xx]` or
   `[CONFIRMED]` accordingly.

**Done when.** Every question has an observed answer, or an explicit "could not be probed, because". W1.2, W2.3 option B,
W4.2 step 9, W4.4, W4.5 step 7, W5.6 and W6.1 read their go/no-go from this block.

## W1.2 Log which instruction files actually loaded

**Repo:** brain. **Lands via:** `~/.claude` commit (settings.json via P1). **Effort:** S. **Needs:** W1.1 (q6 field names).

**Why.** Every rules-load count in the review was reverse-engineered from transcripts. InstructionsLoaded exists;
`claude-code-automation/hooks.md:26` names it as the way to audit what reached context; nothing registers it.

**Steps.**
1. New `~/.claude/skills/recall-instructions-log-hook.py`, registered on event `InstructionsLoaded` (no matcher) through
   P1.
2. Append one row per call through `recall_append.append_rows` to `~/.claude/recall-instructions-log.jsonl` (env
   RECALL_INSTRUCTIONS_LOG). Fields: t, sid, agent, file_path, memory_type, load_reason, trigger_file_path, bytes
   (`os.path.getsize`, or -1). Use the names W1.1 observed.
3. Print nothing, and always exit 0.
4. Add the hook's row to the automatic-recall.md s2 table in the SAME commit.

**Fixtures.** MUST FIRE: a synthetic payload writes one row with load_reason. MUST NOT FIRE: malformed stdin writes
nothing and exits 0. CLEAN TWIN: check-skills table parity passes.

**Done when.** After one day the log has rows from main, worktree and subagent contexts. A one-off count prints bytes
loaded per session by load_reason, with denominators, and names its script.

## W1.3 The brief gate writes a row for every call

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** S.

**Why.** `recall-brief-gate-hook.py` writes nothing. Its refusal rate (2 refusals in 50 top-level calls, both resent
compliant within 94 s) had to be rebuilt from transcripts. (agent-tier/brief-gate-logs-nothing)

**Steps.**
1. After `verdict()`, append one row to `~/.claude/recall-brief-gate-log.jsonl` (env RECALL_BRIEF_GATE_LOG). Fields: t,
   sid, agent, tool, subagent_type, verdict (pass|deny|skip), why, kc_kind (paths|memory|searched-only|none), kc_paths,
   prompt_len.
2. Never log prompt text.
3. Log skip rows too. Without them, "the gate stopped being called" and "no Agent calls happened" look the same.
4. Wrap the append in try/except, so a log failure never changes the verdict.
5. `store-usage-report.py` gains a "briefs" section, every rate with its denominator: calls, denied, denied-then-passed
   within 10 minutes (joined on sid AND subagent_type), and searched-only share. It reads W1.9's exclusions and prints
   `excluded N rows`.

**Fixtures.** MUST FIRE: a deny writes exactly one row with verdict=deny. CLEAN TWIN: a pass writes a row and still
prints nothing. MUST NOT FIRE: a Bash payload writes no row. CLEAN TWIN: an unwritable log path leaves stdout
byte-identical.

## W1.4 The intent hook logs every judgement it makes

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** S.

**Why.** 682 shell calls were classified as judgements in 7 days, and 269 got an injection. Why the other 413 did not
cannot be answered: the hook keeps no log. (tool-tier/intent-blind-to-code-and-analysis)

**Steps.**
1. For EVERY call where `is_judgement` is True, append one row to `~/.claude/recall-intent-log.jsonl` (env
   RECALL_INTENT_LOG). Fields: t, sid, agent, tool, ikey, verdict, shown.
   - verdict is injected, sidecar-down, asked-before, all-seen, no-hits or byte-cap-empty. Every return path after
     `is_judgement` writes its own.
   - shown is a list of `path::heading`.
2. Never log the description text.
3. Use a distinct file, not `ev=offer` rows in recall-log. Those feed recall-stats, the forgetting candidates and
   recall-brain.

**Fixtures.** MUST FIRE: a judgement intent with the sidecar down writes verdict sidecar-down. MUST NOT FIRE: a mechanical
intent writes no row.

## W1.5 A coverage row for every call the reflex hook sees

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** S.

**Why.** Answering "what share of estate code edits got any knowledge" took a 582-transcript scan.
(tool-tier/no-coverage-telemetry)

**Steps.**
1. In `recall-reflex-hook.py main()`, at step 5 of procedure P2 (after `fire()` has produced the hits, before the early
   return), append one row to `~/.claude/recall-coverage-log.jsonl` (env RECALL_COVERAGE_LOG). Fields:
   - t, sid, agent, tool, kind, tool_use_id;
   - `repo`: thriftycrew | thriftycrew-worktree | skills | fantasy | scratch | other. For an edit, take it from the file
     PATH. For a command, take it from cwd plus any absolute path in the command, and record `repo_from`;
   - `top`: the first directory below the repo root;
   - `ext`;
   - `fired`: the live row ids;
   - `shadow_n`: the number of draft rows `_log_shadow` wrote. Change `_log_shadow` to return that count (0 on every
     error path), and amend its docstring's "no return value the caller could act on" to "returns a count that is only
     ever LOGGED, never acted on". Procedure P2 step 3 depends on this.
2. Never log command or body text.
3. At about 25,000 rows a week it needs W6.7's archive.
4. `recall-stats.py` prints "estate code edits with any tool-tier pointer: N of M", by top directory and by origin (main
   or agent), reading W1.9's exclusions.

**Fixtures.** MUST FIRE: a silent Write of `ops\x.ps1` still writes a row with `fired: []`. MUST NOT FIRE: no row
contains body text (assert the literal `Move-Item` is absent). CLEAN TWIN: the fire log still gets its rows.

## W1.6 Searches are attributed, survive a pipe, and end with a verdict line

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** S.

**Why.**
- Search rows carry only CLAUDE_CODE_SESSION_ID, which is the parent's: 0 of 158 carry an agent id. So "backed by a
  search" is true for 175 of 179 commits, whether or not the committing agent searched.
- `search.py` logs in a `finally` AFTER printing, so `| Select-Object -First N` kills the row: 19 of 75 PowerShell
  searches were lost.
- W4.2 needs an unambiguous signal that a query really ran.
(record-tier/backing-is-per-session; tool-tier missed finding)

**Steps.**
1. `knowledge-search/search.py`: on each of its four result paths, compute the result lines, THEN write the log row with
   `paths` taken from those lines, THEN print. The row gains `corpus` (the legs), `cwd`, `child`
   (CLAUDE_CODE_CHILD_SESSION) and `flags`. Remove the `log_search(...)` call from `main()`'s `finally`
   (search.py:1085-1096) in the same change, so a run writes exactly one row.
2. Whenever a query actually ran, print `KNOWLEDGE-SEARCH-COMPLETE legs=<n> hits=<n> blind=<n>` as the LAST line of
   output. legs=1 until W3.3. An empty query, a usage error, `--help` and `--selftest` print no such line.
3. `recall-log-open.py` (PostToolUse on Bash|PowerShell; its payload carries agent_id): when the command matches
   `knowledge-search[\\/]+search\.py`, is not `--selftest`, and its segment's leading verb is not a reader (cat, type,
   Get-Content, sed), append `{ev:'search-call', sid, agent, cwd, t, tool_use_id, complete: <bool>, q: command[:200]}`
   through `recall_append.append_rows` to recall-log.jsonl (RECALL_LOG, the file search rows already use).
   - `complete` is whether the last non-empty line of the tool_response stdout is a KNOWLEDGE-SEARCH-COMPLETE line.
   - recall-stats, recall-forget and recall-brain ignore `ev: search-call` (add the filter in the same commit).
4. Write these rows BEFORE the existing `if not found: return 0` (about line 242), because `paths_from_command` returns []
   for such commands.
5. The W4.2 marker is NOT created here. W4.2 adds it in its own commit.

**Fixtures.**
- MUST FIRE: a Bash payload `C:/Codex/Python312/python.exe C:/Users/Owner/.claude/skills/knowledge-search/search.py "x"`
  with agent_id a1 logs a search-call row with agent a1.
- MUST FIRE: the backslash spelling of the same command does too.
- MUST NOT FIRE: `cat ...\search.py` logs no search-call.
- MUST NOT FIRE: `search.py --selftest` logs none.
- CLEAN TWIN: existing open rows are unchanged.
- search.py self-test, MUST FIRE: a run whose stdout is closed after its first line still leaves one log row.
- search.py self-test, CLEAN TWIN: the logged `paths` equal the paths printed, for a plain query and a `--files --multi`
  query.
- search.py self-test, MUST NOT FIRE: an empty query prints no COMPLETE line.
- search.py self-test, CLEAN TWIN: a plain query run to completion writes exactly one row.

## W1.7 Fire and outcome rows carry `tool_use_id` and a pattern hash

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** S.

**Why.** Every PreToolUse, PostToolUse and PostToolUseFailure payload carries `tool_use_id`, but the fire-to-outcome
join keys on a command hash, which is ambiguous when one agent repeats a command. The select-first tightening also mixed
two patterns in one fire log. (tool-tier missed finding; strength-row-discipline critique)

**Steps.**
1. Add `tool_use_id` to every row `recall-reflex-hook.py` and `recall-reflex-outcome-hook.py` write.
2. Add `pattern_sha` (`sha1(pattern)[:8]`) to each fire row.
3. Keep the chash on the 2,000-capped text exactly as it is: it is the join key for three callers.

**Fixture.** CLEAN TWIN: an edit's logged chash equals `command_hash` of the 2,000-capped text, before and after.

## W1.8 One transcript iterator that includes subagents and workflow agents

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** S.

**Why.** Every nightly harvester reads top-level transcripts only, while subagents hold 76% of code edits. Workflow
agents sit two levels deeper (`subagents/workflows/wf_*/agent-*.jsonl`). Several bars in this plan need the subagent
view. (tool-tier/subagent-evidence-invisible)

**Steps.**
1. New `~/.claude/skills/recall_transcripts.py` with
   `iter_transcript_files(projects=None, since=None, include_subagents=True)`. It yields `(mtime, proj, path, sid,
   agent_id)`.
2. Read `sessionId` and `agentId` from the transcript ROWS, never from the directory shape.
3. An unreadable file is a counted skip, never raised.
4. Add `iter_rows(path)` that tolerates a torn last line.

**Fixtures.** A temp tree holding `parent.jsonl`, `parent/subagents/agent-ab12.jsonl` and
`parent/subagents/workflows/wf_1/agent-cd34.jsonl` resolves each to the right (sid, agent). MUST NOT FIRE: an unreadable
file raises nothing and is counted.

## W1.9 One exclusion file for review and probe traffic

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** S.

**Why.** On 2026-09-22 review traffic was 200 of 295 open rows, and one audit open removes a section from the
forgetting list for the whole window. Every bar in this plan must exclude it the same way. (bridge-and-routing/audit-reads-inflate-open-counts)

**Steps.**
1. Add the tracked `~/.claude/skills/recall-audit-exclusions.json` (env RECALL_AUDIT_EXCLUSIONS):
   `{agents: {<agent_id>: reason}, sessions: {<sid>: reason}}`.
   - It is written AFTER a review run: agent ids exist only after spawn.
   - `sessions` is for sessions that are wholly probes, such as the `C--Codex-tc-exp-*` arms. Never the parent sid of a
     human session.
2. Seed it with the agent ids of session 134f2f6e's three workflow runs (wf_2ae11799-ea0, wf_d6439ad3-4d8 and
   wf_45396575-f25), read from their agent transcripts through W1.8, and with every `C--Codex-tc-exp-*` session. W1.1
   adds its probe ids after it runs.
3. Add `recall_core.is_excluded(row)`. recall-stats, recall-forget, the use-weight builder, store-usage-report and every
   report this plan adds call it, and print `excluded N rows`.

**Fixtures.** MUST FIRE: a listed agent's open is excluded from the forgetting-candidate computation. MUST NOT FIRE: an
unlisted agent in the same sid still protects its section.
