# tool-tier

PreToolUse on Bash|PowerShell|Edit|Write runs two hooks. recall-reflex-hook.py matches the ACTION (a command's first 4,000 chars, or an edit's path plus the first 2,000 chars of new_string/content, recall_core._text caps) against 30 regex rows in recall-reflexes.json (23 remind, 5 block, 2 rewrite). It injects up to 3 one-line reminders, denies (block rung, commands only, waivable with `# reflex-override:<id> <why>` except git-add-sweep), or rewrites (bare-python and set-content-no-encoding, through a code_only lexer that masks strings, here-strings and heredocs). It also shadow-fires 122 drafts, which log and inject nothing, and adds session-promoted drafts at remind.
recall-intent-hook.py reads ONLY tool_input.description, classifies it with a verb/subject table (recall_intent.is_judgement), and when the semantic sidecar is up injects up to 3 store section pointers, once per section and once per intent per session. It writes no log.
recall-reflex-outcome-hook.py (PostToolUse) writes fine or unknown for each call a row fired on. Burns and blocks are recovered nightly from TOP-LEVEL transcripts only, by recall-reflex-outcome-join.py. Edits are always unknown. recall-reflex-ladder.py recommends rung moves; drafts become READY only on burn lift. recall-auto-accept.py may add 2 per night at remind under Brad's 2026-09-12 ruling, and only with a person-approved must_not_fire.
There is no tier-2 BM25 recognition hook on tool events: recall-floors.json is derived nightly and no hook reads it. recall-agent-hook covers Agent prompts only.
PreToolUse additionalContext arrives AFTER the call has run. The hook header says so, and it happened in this session: the reflex note on my Write appeared after "File created successfully". So for Edit/Write every reminder lands after the file is written, and rung_for never lets a block apply to an edit.
Over 2026-09-15..22: the table injected on 189 of 2,066 real-repo code edits. No row names an estate helper. The intent hook fired on 0 of 4,510 Edit/Write and on 49 of 2,754 analysis-shaped commands. 79% of fires came from subagents, whose failures and blocks never reach the outcome record.
Self-tests on 2026-09-22 all exit 0: recall_reflex 47/47, reflex-hook 57/57, ladder 22/22, recall_intent 8/8.
Note: my own ordinary tool calls in this review fired the live hooks under session 134f2f6e-7fb9-4057-a890-b2c27ba9dfc0 and appended rows to recall-reflex-log.jsonl, recall-reflex-outcome.jsonl, session state and the knowledge-search log. I drove no hook synthetically. That session is excluded from every count below where stated.

## Measurements
- Reflex rows by rung: 30 rows: 23 remind, 5 block, 2 rewrite  [table as of 2026-09-22 14:19]
- Reflex rows by class: 13 of 30 shell/PowerShell/Python language traps; 5 of 30 harness or machine-environment traps; 10 of 30 git/estate process traps; 2 of 30 style/brain-meta; 0 of 30 'use the estate's existing helper'  [table as of 2026-09-22]
- Rows or drafts naming an estate helper: 0 of 30 rows (Grep 'Write-Tc|Add-TcLine|Get-TcTreeFiles|Invoke-Native|Enter-Tc|Clear-TcGitRepoEnv|lib[\\/]|atomic-write|lf-write|tree-walk|native-lib' over recall-reflexes.json: 0 matches); 1 of 122 drafts (fmt-lib.ps1)  [2026-09-22]
- Real-repo code Edit/Write (.ps1 .py .js .psm1) with ANY hook injection: 189 of 2,066 (9.1%), all reflex, 0 intent; tc-main 65 of 476, tc-worktree 124 of 1,349, claude-skills 0 of 68, C:\Codex\tc-exp-* arms 0 of 173; ThriftyCrew graph/ 0 of 188, grocery 115 of 1,052, ops 43 of 290, meal-prep 23 of 237, lib 7 of 42  [tool uses 2026-09-15T23:45Z..2026-09-22 ~23:45Z, 582 transcripts incl. subagents, excluding session 134f2f6e]
- Subagent share of real-repo code edits: 1,572 of 2,066 (76%)  [same 7 days]
- description field present per tool: Edit 0 of 3,047; Write 0 of 1,463; Bash 4,278 of 5,648; PowerShell 10,552 of 11,119; Agent 282 of 282  [same 7 days]
- Intent hook fires: 0 of 4,510 Edit/Write; 257 of 16,767 shell calls (1.5%); 49 of 2,754 analysis-shaped commands (1.8%); 49 of 257 intent fires were analysis-shaped; is_judgement true on 679 of 16,767 but injected on only 257 of 679  [same 7 days; the intent hook keeps no log, so transcripts are the only record (session state held 28 intent_asked keys in 13 files, not a usable record)]
- Exploratory ONE-variant analysis-verb extension (no bar written, sizing only): adds 783 of 14,830 described calls (4.6% -> 9.9%); catches 338 of 2,473 described analysis-shaped commands versus 119 today; includes mechanical ones such as 'Verify landing, delete remote branch'  [same 7 days]
- Edit bodies past the reflex match window: Writes of real-repo code over 2,000 chars: 102 of 110; Edit new_string over 2,000: 324 of 1,956; shell commands over 4,000: 116 of 16,838  [same 7 days]
- ThriftyCrew .ps1/.psm1 edits carrying a shape an estate helper replaces, helper absent from the same text: 180 of 1,550 (Move-Item -Force 90, Set-Content/Out-File/WriteAllText 131, native 2>&1|2>$null 16, New-Object List[object] 15, Add-Content 4, Start-Job/while($true) 4, recursive walk 2); injection naming the helper 0 in every class; first such shape past char 2,000 in 70 of 180. UNSOUND candidates, not confirmed defects  [same 7 days]
- Live fire origin and outcome resolution by origin: live fires 2,034 of 2,562 from subagents (79%); outcome rows: subagent burned 0 of 1,235 resolved, blocked 0; main burned 81 of 981 (8.3%), blocked 39; unwaived live BLOCK fires 245 in subagents versus 40 in main  [last 7 days by row t, excluding session 134f2f6e]
- Loudest row, live versus rate-gate corpus: select-first-in-writing-pipeline: 999 live fires over 21,277 eligible calls (4.70%) against a 3% cap, 1,000 distinct commands, 174 session/agent contexts, worst one 100; --rate corpus says 11 of 5,579 (0.20%) 'ok'; ladder burn 43 of 1,328 (3.2%) below the 8.3% main base  [live: last 7 days; corpus: recall-tool-probes.jsonl as harvested 2026-09-22 14:43]
- Commands longer than the probe corpus window: 3,552 of 16,838 shell commands exceed MAX_QUERY 600  [same 7 days]
- PowerShell-language rows firing on non-PowerShell edits: 15 of 295 PS-row edit injections (.py 9, .txt 2, .json 2, .md 2)  [same 7 days]
- set-content-no-encoding behaviour: 16 command rewrites and 18 edit fires logged acted=rewrite (the hook only reminded on those 18); 0 rewrites on a command that then ran git commit -F in 7 days (latent). Probe: 'Set-Content $p $body; git commit -F $p' is rewritten to 'Set-Content -Encoding utf8 ...' (a BOM under PS 5.1)  [same 7 days; probe run 2026-09-22]
- MISS classification (the 44 uncovered failure_misses): strong recurring traps 5 entries (4 traps); weak generic parse/runtime errors 6; gate/audit verdicts doing their job 12; degenerate signatures 15; harness refusals 3; knowledge-search permission denials 3. miss_kind labels on the same 44: cue 17, no-shape 14, outcome 11, harness 2  [recall-reflex-drafts.json as of 2026-09-22 14:44]
- Knowledge-search calls denied by the permission system: 18 all time (16 on 2026-09-19), 14 of 18 in C:\Codex\tc-exp-* experiment arms, 4 in ThriftyCrew  [all transcripts on disk]
- Draft pipeline state: 0 of 122 drafts READY (ladder); 0 of 122 carry a person-approved must_not_fire; 85 of 122 authored 2026-09-10 (12 days waiting); 0 rows ever auto-accepted (no auto-accept log, 0 live rows with accepted_by); no recall-inbox-log.jsonl exists  [2026-09-22]
- Same-session promotion (WS 2b) activity: 1 non-shadow draft-id fire in the whole fire log (18,711 lines since 2026-09-07); 0 of 113 current state files carry a promotion  [fire log lifetime; state files on disk 2026-09-22]
- Torn rows in tool-tier logs: recall-reflex-log.jsonl 1 unparseable of 18,711 (line 17832, a bare tail '18e", "agent": "ac8c65ad141adcd66"}'); outcome log 0 of 8,551  [log lifetime]
- .claude/rules delivery: all 6 rules files (118,538 bytes) loaded at session start in 45 of 45 ThriftyCrew-rooted transcripts (13 main, 12 worktree main, 20 subagent); loaded lazily (nested_memory) in 34 of 35 C:\Codex-rooted sessions that edited ThriftyCrew code; 555 of 1,825 ThriftyCrew code edits came from C--Codex-rooted sessions  [rules: last 3 days; edits: 7 days]
- MEASURE/EVAL/PLAN doc writes: 13 Writes (3 MEASURE, 10 PLAN), all 13 over 2,000 chars; MEASURE Writes with '## Knowledge consulted' 0 of 3; PLAN 8 of 10  [same 7 days]
- Function-name index opportunity (measured so the plan does NOT build it): 39 of 798 function definitions in 7-day ThriftyCrew .ps1 edits share a normalised name with a shared-library function elsewhere, mostly fixture helpers (T 19, Check 4, TT 1, Case 1)  [same 7 days]
- Hook latency (only runs that produced output are recorded): reflex p50 163 ms p95 596 ms (n=2,782); intent p50 259 ms p95 605 ms (n=390)  [same 7 days]
- Tool-tier self-tests: recall_reflex 47 of 47, recall-reflex-hook 57 of 57, recall-reflex-ladder 22 of 22, recall_intent 8 of 8, every exit 0  [run 2026-09-22 ~18:55]

## Findings

### machinery-rows-absent [gap/code/high] VERDICT=OVERSTATED
No reflex row points at the estate's own machinery; the edit-time tier knows shell traps, not helpers

CORRECTED: 0 of 30 rows fire on a CODE shape and name the shared-library helper that replaces it (lib/atomic-write, append-line, lf-write, tree-walk, git-repo-env, grocery/native-lib). At least 7 rows do point at estate process machinery (propagate, the compare-deals chain, the daemon names gate, publish, the node path). The real 7-day opportunity is ThriftyCrew .ps1 edits that ADD a helper-replaceable site while the helper is absent: Move-Item -Force 73 of 90 candidates (60 outside tests), Set-Content/Out-File 23 of 32, List[object] 7 of 15, Add-Content 3 of 4. The mapper's 180 of 1,550 is an upper bound inflated by [IO.File]::WriteAllText, which CLAUDE.md prescribes. This is not ALREADY-RULED: 2a refused similarity retrieval, and a deterministic shape table is the mechanism tier 1 already accepts.

FIX: WS-A 'machinery rows'.
(1) recall_reflex.py, new optional row fields, all read in in_scope():
- class: 'machinery'
- exts: e.g. ['.ps1','.psm1']. For kind 'edit' the first line of the query is the file path, and the row applies only when os.path.splitext(path)[1].lower() is in exts. Ignored for commands.
- except_paths: path fragments where the shape IS the helper, e.g. 'lib/atomic-write.ps1'.
- helper: repo-relative file that holds the helper.
- gate: repo-relative file of the push-time gate.
- gate_fixture: a literal copied from the gate's own MUST FIRE case.
The hook also writes row.get('class','') into every fire-log row.
(2) recall-reflexes.json. Add these rows, each at rung remind, tools [Edit, Write], scope 'codex/thriftycrew', exts ['.ps1','.psm1'], harm loud, max_fire_rate 0.02, source '.claude/rules/ops-and-gates.md':
- machinery-bare-replace: pattern (?m)^(?![ \t]*#)[^\n]*\bMove-Item\b[^\n]*\s-Force\b(?![^\n]*atomic-replace:allow). except_paths lib/atomic-write.ps1. Helper Write-TcAtomicFile in lib/atomic-write.ps1. Gate ops/audit-bare-replace.ps1.
- machinery-shared-append: (?m)^(?![ \t]*#)[^\n]*\bAdd-Content\b -> Add-TcLine in lib/append-line.ps1.
- machinery-tracked-write: (?m)^(?![ \t]*#)[^\n]*(?:\bSet-Content\b|\bOut-File\b), scoped to ops/, lib/, grocery/ and meal-prep/ -> Write-TcLfFile in lib/lf-write.ps1 (census ops/count-tracked-writers.ps1).
- machinery-list-object: New-Object\s+(?:-TypeName\s+)?['\"]?(?:System\.)?Collections\.Generic\.List\[(?:System\.)?object\] -> [System.Collections.Generic.List[object] ]::new(). Gate ops/audit-list-array-wrap.ps1, held at ZERO.
- machinery-filtered-walk: Get-ChildItem\b[^\n|]*-Recurse[^\n]*\|\s*(?:Where-Object|\?)[^\n]*(?:worktrees|\.claude) -> Get-TcTreeFiles -PruneBelow in lib/tree-walk.ps1. Gate ops/audit-full-path-excludes.ps1.
- machinery-fixed-temp: Join-Path\s+\$env:TEMP\s+['\"][A-Za-z][\w.-]*['\"](?![^\n]*(?:NewGuid|\$PID)) -> a per-run directory (the GcScratch pattern in lib/guard-contract.ps1). Gate ops/audit-fixed-temp-names.ps1.
Message template: '<the trap in one clause>; the estate helper is <Fn> in <helper>; <gate> refuses a new site at push; a deliberate exception carries <allow marker>'.
The native-redirect-under-EAP-Stop row and the git-init-fixture row need file context and ship with WS-B.
Fixtures for each row:
- must_fire: the gate's own MUST FIRE literal, prefixed with a C:\Codex\ThriftyCrew\grocery\x.ps1 path line.
- must_not_fire: the gate's allow-marked case (e.g. audit-bare-replace.ps1:131-132); the helper call itself; the same text under a design\PLAN-x.md path; the helper's own file.
(3) New recall_reflex.py --selftest cases:
- MUST FIRE: every machinery row names a helper and a gate that exist under C:\Codex\ThriftyCrew. Print SKIPPED with the reason when that root is absent.
- MUST FIRE: each gate_fixture literal still appears in its gate file. This is the drift detector: a gate that changes its fixture flags the row.
- MUST NOT FIRE: an exts row is silent on a .md path.
- CLEAN TWIN: a row with no exts (memory-without-cost-band) still fires on its .md path.
Fails open under the existing hook contract. A row that fails to compile is dropped and reported by --selftest. Waiver: the gate's allow marker, which is inside the pattern, or '# reflex-override:<id> <why>'. Telemetry: the fire log, the WS-F coverage log, and the WS-E commit join after 7 days.

CRITIQUE: (a) A regex over new_string fires again on unchanged context lines. 17 of 90 bare-replace candidates and 8 of 15 List[object] candidates added no new site. Use the recall-memory-lint-hook precedent instead (automatic-recall.md s2: on an Edit it reads the file, applies the replacement and lints the result). Count sites in the old file and in the rebuilt new file, and fire only when the count rises. For a Write, compare against the file on disk. (b) Match the gate's own definition. The sketched pattern misses the aliases and abbreviations the gate counts, and it fires inside fixture strings (19 of the 90 candidates were in test/fixture files). Either call Get-TcBareReplaceLines through a PowerShell child with a generous hang guard, or port the gate's exclusions and mask strings with a PowerShell lexer (mask_non_code is currently disabled for edits). (c) machinery-tracked-write contradicts the existing set-content-no-encoding row on the same line: one says '-Encoding utf8', the other 'Write-TcLfFile'. A regex also cannot tell a tracked target from scratch output. Amend the existing row's message rather than add a rival row. (d) The List[object] row fires on creating the list, but audit-list-array-wrap refuses the @() WRAP. The row must key on the wrap. (e) in_scope's 'scope' matches a fragment anywhere in path plus BODY, so a scratch Write whose body mentions the repo satisfies 'codex/thriftycrew'. The new 'exts' check must read only the path line. (f) The helper names already reach the model at session start (see the globs missed finding), so this row is a trigger, and a remind lands after the write. Its value shows up only in the next edit, so pair it with WS-E. Fixtures must prove: MUST FIRE an Edit that adds 'Move-Item $t $p -Force' to a grocery .ps1 with 0 sites on disk; MUST FIRE 'mi $t $p -fo' (alias plus abbreviation, as the gate counts); MUST NOT FIRE when old_string already held that line; MUST NOT FIRE the literal inside a quoted string in a test-*.ps1; MUST NOT FIRE a line carrying '# atomic-replace:allow'; CLEAN TWIN memory-without-cost-band still fires on its .md path.

### subagent-evidence-invisible [issue/both/high] VERDICT=CONFIRMED
Every learning-loop harvester skips subagent and workflow transcripts, so 79% of fires can never record a burn or a block

CORRECTED: Confirmed as titled. In 7 days, 0 of 1,237 resolved subagent outcome rows are burned or blocked, against 81 burned and 39 blocked of 1,020 main-session rows. All three nightly harvesters read top-level transcripts only, and PostToolUse is silent on failures. The downstream claim that this is WHY 0 of 122 drafts are READY is not measured. The dilution lowers both the draft's burn rate and the tool base rate, so its demonstrated effect is lost statistical power, not a bias in a known direction.

FIX: WS-C.
(1) New module C:\Users\Owner\.claude\skills\recall_transcripts.py with iter_transcript_files(projects, since=None, include_subagents=True). It yields (mtime, proj, path, sid, agent_id):
- top level: sid = basename[:36], agent_id ''.
- subagent: sid = the directory name two levels above subagents; agent_id = filename minus the 'agent-' prefix and '.jsonl'.
Before relying on it, cross-check that this agent_id equals the fire log's 'agent' field and each row's 'agentId' field (both were seen, e.g. 'a095f140a4358a0a6').
(2) Use it in:
- recall-tool-probes.harvest: raise max_files or window by mtime (14 days) instead of 400 files.
- recall-failure-harvest: carry 'agent' on every row.
- recall-reflex-outcome-join.read_calls: key calls by (sid, agent, chash) and match fire rows on the same triple.
- recall-stop-hook._promote_session_drafts: filter failures by (sid, agent).
(3) Floor, per ops-and-gates 'write down what the number does when the producer STOPS': recall-sleep's hook-health section prints 'subagent outcomes: burned N, blocked K, of M resolved'. It prints WARN when M >= 200 and N + K == 0.
Fixtures in recall-reflex-outcome-join.py --selftest, built on a temp projects tree (a parent .jsonl plus parent\subagents\agent-ab12.jsonl):
- MUST FIRE: a subagent Bash `git add -A` whose tool_result is_error=true resolves 'burned' for (sid, 'ab12').
- MUST FIRE: the deny text resolves 'blocked'.
- MUST NOT FIRE: a parent-session fine call with the same chash is not overwritten by the subagent's burn.
- CLEAN TWIN: the existing main-session fixtures pass unchanged.
Fail mode: a transcript that cannot be read is skipped and counted in stats, never raised.

CRITIQUE: (a) The cheaper, live fix was missed: after a probe, register recall-reflex-outcome-hook.py on PostToolUseFailure for Bash|PowerShell|Edit|Write. The probe should cover a subagent 'exit 42' with a redirected log, and one hook-denied call, to see whether a deny arrives as PostToolUseFailure or as PermissionDenied. Keep the transcript join as a backfill only. A lower-effort implementer will add the matcher and stop there. That fails: recall_failure.is_failure reads tool_response, which this payload lacks, so every failure would log 'unknown' ('no tool_response'). The hook needs a branch that reads payload['error'] and applies the deny-marker test to it. (b) Join on tool_use_id. It is present on the PreToolUse, PostToolUse and PostToolUseFailure payloads and in transcripts. Store it in each fire row instead of relying on (sid, agent, chash), which is ambiguous when one agent repeats a command. Deduplicate live rows against backfill rows by tool_use_id, or burns count twice. (c) The sketch derives sid from 'the directory two levels above subagents'. That is wrong for workflow agents (subagents/workflows/wf_x/agent-*.jsonl). Read sessionId and agentId from the transcript rows instead. (d) A transcript that cannot be read is a counted skip. Fixtures: MUST FIRE a PostToolUseFailure payload carrying error text and agent_id logs burned for that agent; MUST FIRE deny text in payload['error'] logs blocked; MUST NOT FIRE a PostToolUse success row with the same tool_use_id is not overwritten; a temp tree holding parent.jsonl, subagents/agent-ab12.jsonl and subagents/workflows/wf_1/agent-cd34.jsonl resolves each to the right (sid, agent); CLEAN TWIN the existing main-session fixtures pass unchanged.

### edit-outcomes-unknowable [gap/code/high] VERDICT=CONFIRMED
Edit/Write outcomes are 'unknown' forever, so no edit-time row can ever be scored, promoted or retired

CORRECTED: As stated: 347 edit fires in 7 days and 305 of 305 edit outcome rows unknown. 24 of 122 drafts are Edit/Write-only, and 81 include Edit or Write.

FIX: WS-E 'edit outcome by the next commit'.
(1) recall-reflex-hook.py: for kind 'edit' fire rows, add 'path' as a repo-tagged relative path, e.g. 'ThriftyCrew:grocery/x.ps1', with any worktree prefix stripped. Store no body text.
(2) New nightly read-only step C:\Users\Owner\.claude\skills\recall-edit-outcome-join.py, writing ~/.claude/recall-edit-outcome.jsonl. For each edit fire older than 2 hours:
- Run `git -C C:\Codex\ThriftyCrew log --all --format='%H %ct' --since=<fire t> -- <path>` and take the first commit after the fire.
- Read that blob with `git show <c>:<path>` and the parent blob with `git show <c>^:<path>`.
- Run the SAME row through recall_reflex.row_search over path + '\n' + blob.
- Verdict 'persisted': the shape is present and was absent or less frequent in the parent. It counts as a burn.
- Verdict 'fixed': the shape is absent. It counts as fine.
- Verdict 'pre-existing': the parent had the same count. Unknown.
- Verdict 'uncommitted': no commit in 72 h. Unknown.
Clear GIT_DIR, GIT_INDEX_FILE and GIT_WORK_TREE in the subprocess env (ops-and-gates git-hook rule).
(3) recall-reflex-ladder.gather reads this second outcome map for edit fires.
Fixtures, in a temp git repo with a scrubbed env:
- MUST FIRE: a commit adding Move-Item -Force after a fake fire gives 'persisted'.
- MUST FIRE: a commit with the helper gives 'fixed'.
- MUST NOT FIRE: a file whose parent already had the site gives 'pre-existing', not 'persisted'.
- MUST NOT FIRE: a path outside any repo is skipped and counted.
- CLEAN TWIN: command outcomes from the existing join are unchanged.
Fails open: every git error is a counted skip. Output ends with EDIT-OUTCOME-COMPLETE and the counts by verdict, with denominators.

CRITIQUE: (a) There is no control arm. Among fired edits, 'persisted' versus 'fixed' cannot say whether the reminder did anything, which is the store's own open gap. Use shadow fires (never shown) of the same row as the control, or split fires into shown and not-shown by a deterministic hash of tool_use_id. Without a control the numbers are unqualified. (b) There is a cheaper first signal than git. From transcripts, check whether a LATER Edit/Write by the same (sid, agent) to the same path removed the shape. A git commit join is confounded by the ~07:00 bot that commits the whole tree, by push-main's rebase, and by worktree branches that never land or get pruned (a pruned branch would read as 'uncommitted'). (c) 'First commit after the fire' must be restricted to the fire's own worktree branch, because --all picks up siblings' commits of the same path. (d) Use WS-A's before/after site counter, or 'pre-existing' will disagree with the reflex. Extra fixtures: MUST NOT FIRE a bot commit whose parent already had the site resolves 'pre-existing'; CLEAN TWIN a shadow-arm fire resolves through the same code path.

### edit-window-2000-chars [issue/code/high] VERDICT=CONFIRMED
The reflex tier sees only the first 2,000 characters of an edit, and 102 of 110 code Writes are longer

CORRECTED: Confirmed: an edit is matched on path plus the first 2,000 characters of new_string or content, and a command on its first 4,000 characters.

FIX: WS-B.
(1) recall_core.py: add MATCH_LIMIT_COMMAND = 65536, MATCH_LIMIT_EDIT = 262144 and a function action_text_for_match(tool, ti) with the same (text, kind) shape but those caps. Leave action_text_from_input untouched: it is the chash key used by three callers.
(2) recall-reflex-hook.py main(): compute mq = action_text_for_match(...) and pass mq to shadow_fire, fire and decide. Keep recall_reflex.command_hash(query) on the capped query for every log row. apply_rewrites already uses the full ti['command'].
(3) File context. New optional row field file_context, a regex. For an Edit, the hook reads at most MATCH_LIMIT_EDIT bytes of the file on disk (read-only, errors swallowed) and requires file_context to match file + new_string. This enables machinery-native-redirect-under-stop (file_context \$ErrorActionPreference\s*=\s*['\"]Stop, pattern (?:\bgit\b|\.exe\b|\bpython\b|\bnode\b)[^\n]*\s(?:2>&1|2>\$null|\*>&1), helper Invoke-Native in grocery/native-lib.ps1, gate grocery/test-native-stderr-eap.ps1). It also enables machinery-git-init-fixture (pattern \bgit\b[^\n]*\binit\b, file_context absence of Clear-TcGitRepoEnv, helper lib/git-repo-env.ps1, gate ops/audit-git-fixture-env.ps1).
(4) Cost control. Optional row field needle, a lowercase literal checked with `in` before the regex runs. A selftest static check fails any row whose pattern uses [\s\S]*, (?s).* or a whole-text lookahead without a needle.
(5) recall-tool-probes.py: store command probes at 4,000 chars and edit probes at path + 16,000, so --rate scores the view the hook matches. State the remaining gap in its report.
Fixtures:
- MUST FIRE: machinery-bare-replace fires on a Write whose Move-Item -Force sits at char 30,000.
- MUST NOT FIRE: memory-without-cost-band is silent on a memory Write whose 'cost:' line sits at char 3,000.
- CLEAN TWIN: an edit's logged chash equals command_hash of the 2,000-capped text.
- Hang guard: all rows plus all drafts over a synthetic 256 KB .ps1 finish inside 60 s.
Fails open, unchanged.

CRITIQUE: (a) For an Edit, widening the window over new_string still cannot see the file, and it still fires on context lines. Rebuilding the post-edit file (as in the machinery-rows-absent critique) makes the cap irrelevant for Edit and leaves Write as whole-content. (b) Cost: 30 rows and 122 drafts would scan up to 256 KB per Edit/Write, on a hook whose p95 is already about 600 ms. The needle prefilter is the real control. Keep the hang guard generous; ops-and-gates bans tight upper wall-clock bars. (c) Keep chash on the capped text, and add tool_use_id beside it. Moving the hash input silently breaks a join shared by three callers. (d) Raising the probe-corpus caps changes every row's measured rate. Re-run --rate for all rows in the same change, record before and after with a corpus fingerprint, or a row goes TOO LOUD without anyone touching it. Add a CLEAN TWIN: the outcome hook's chash for a Write over 2,000 characters equals the fire hook's logged chash.

### intent-blind-to-code-and-analysis [gap/analysis/high] VERDICT=CONFIRMED
The intent gate cannot fire on code writing at all and fires on under 2% of analysis commands, with no log to say why

CORRECTED: Confirmed. 0 of 4,548 Edit/Write calls can reach the intent gate, and 269 of 16,896 shell calls got an injection. 269 of the 682 judgement-classified calls were injected (39%); the other 413 cannot be explained without a log.

FIX: WS-G.
(1) Intent log, needed before any tuning. recall-intent-hook.py appends one row per is_judgement==True call through recall_append.append_rows to LOG = env RECALL_INTENT_LOG or ~/.claude/recall-intent-log.jsonl. Fields: t, sid, agent, tool, ikey (the existing sha1[:12]), verdict (injected | sidecar-down | asked-before | all-seen | no-hits), and shown (a list of 'path::heading'). Never the description text.
Read it in recall-stats.py as 'intent: judged N, injected M, by reason', and join 'shown' to recall-log-open's later Reads for an open rate.
Selftest: redirect RECALL_INTENT_LOG to tmp. MUST FIRE: a judgement intent with the sidecar down writes verdict sidecar-down. MUST NOT FIRE: a mechanical intent writes no row.
(2) Analysis pack, shadow first. New reflex rows with class 'analysis', tools [Bash, PowerShell], a cue on the analysis command shape (e.g. python[^\n]*\s-c\b[\s\S]{0,4000}?(?:Counter|len\(|sum\(|%|/\s*len)|Measure-Object|Group-Object|sqlite3[^\n]*\bcount\(), and a new flag once_per_session: true. Implement the flag via state['reflex_once'][id] in recall-reflex-hook.py.
Message: 'measurement.md: print the denominator, write the bar before the run, name the harness and its blob; exemplar sidecar/matcher_eval.py'.
Ship them first as DRAFTS in recall-reflex-drafts.json, where they inject nothing. Write the acceptance bar BEFORE turning them live, in the metric's units: at most 1 injection per session, and present in at least 60% of sessions that later Write a design/MEASURE-* doc.
(3) Leave the verb table alone until (1) has run 7 days and a bar exists.

CRITIQUE: (a) The log comes first. A lower-effort implementer will log only on injection. Every return after is_judgement is true must write its reason (sidecar-down, asked-before, all-seen, no-hits, byte-cap-empty), through recall_append. (b) The dedup this log will explain lives in session state, and state loses writes (7,469 orphan .tmp files; see missed findings). 'asked-before' will therefore be undercounted and repeats will look like dedup failures. Fix save_state first. once_per_session in state inherits the same flaw. (c) A cue on '%' or 'len(' fires on most python -c one-liners. Measure its rate on shell probes before a bar is written. Only 3 MEASURE Writes happened in 7 days, so a '60% of sessions that later write a MEASURE doc' bar cannot be judged in a week; state the denominator the bar needs. (d) measurement.md already reaches every ThriftyCrew-rooted session at start (rules load unconditionally), so this is a trigger problem, not a delivery problem. The message should cite the rule bullet rather than re-teach it.

### edit-reminders-land-after-the-write [gap/code/medium] VERDICT=CONFIRMED
An edit-time reminder arrives after the file is written, and no edit can ever be blocked

CORRECTED: Confirmed. PreToolUse additionalContext cannot be read before the call runs; only deny and updatedInput act first. rung_for downgrades every block to remind when kind is 'edit'.

FIX: WS-J, after WS-A, WS-B and WS-E.
New rung 'edit_block' in recall_reflex.rung_for. It returns 'block' only when all of these hold:
- kind == 'edit';
- the path's extension is in row['exts'];
- the path matches none of row['except_paths'];
- the matched line carries neither the gate's allow marker nor '# reflex-override:<id>'.
Otherwise it returns 'remind'. For commands it is always 'remind'.
The hook's existing deny JSON works unchanged. deny_reason already names the alternative and the override. Add the gate name.
Eligible only for rows whose gate refuses ANY new site: audit-list-array-wrap (ZERO), audit-git-fixture-env, audit-keyword-arguments, audit-cmdlet-shadow, and audit-bare-replace (a new site above mark 20 hard-fails). Each row ships at remind for 7 days, then goes to Brad with its WS-E persisted/fixed numbers.
Fixtures:
- MUST FIRE: a Write of ops/x.ps1 with `Move-Item $t $p -Force` is denied and the reason names Write-TcAtomicFile.
- MUST NOT FIRE: the same text in design\PLAN-x.md is reminded, not denied.
- MUST NOT FIRE: a line ending '# atomic-replace:allow archive' is not denied.
- CLEAN TWIN: the existing hook case 'an edge quoting a blocked command is never denied' still passes.
Telemetry: acted=block rows in the fire log, plus WS-E.

CRITIQUE: (a) The founding reason edits cannot block comes back in the new scope. Gate files carry MUST FIRE literals: ops/audit-bare-replace.ps1:168 writes 'Move-Item $t $p -Force' into a fixture. 19 of 90 bare-replace candidate edits this week were in test/fixture files. except_paths must name every gate file and helper, and strings must be masked, or the tier will deny edits to the very gates that define the rule. (b) For edits, only the gate's allow marker should waive. A '# reflex-override:<id>' comment would let the Write through while the gate still counts the site and refuses the push, and the override text would stay in the source. (c) Deny only when the rebuilt file's site count RISES. Otherwise a whole-file Write of a script that already had the site gets blocked for an unrelated change. (d) Keep the per-row Brad ruling. Extra fixtures: MUST NOT FIRE a Write of ops/audit-bare-replace.ps1 itself; MUST NOT FIRE an Edit whose old_string already held the site.

### measure-doc-no-edit-time-check [gap/analysis/medium] VERDICT=OVERSTATED
Writing a MEASURE/EVAL/PLAN doc gets no reminder at write time; the Knowledge consulted and harness-blob rules are checked only at push

CORRECTED: There were 3 MEASURE Writes in 7 days. MEASURE-store-ab-2026-09-19 (a tc-exp arm) and MEASURE-aldi-pack-basis-2026-09-19 are dated before the cutoff and are not judged. The one in-scope doc, MEASURE-sams-cents-unit-price-2026-09-20, lacked the section at Write, gained it in a later 4,010-character Edit, and the committed file has it. All 4 PLAN Writes dated 2026-09-20 or later carried the section; the 2 without it are dated 2026-09-18. 3 of 3 MEASURE Writes already named a blob or rev-parse. So no in-scope doc is known to have reached a commit without the section, and the push-refusal scenario was not observed.

FIX: WS-H. Add these rows to recall-reflexes.json, rung remind, tools [Write], exts ['.md'], source CLAUDE.md 'Search before you read' plus .claude/rules/measurement.md:
- measure-doc-knowledge-consulted: pattern (?s)\A(?=[^\n]*[\\/]design[\\/](?:MEASURE|EVAL|PLAN)-[^\n]*\.md\n)(?!.*^##\s*Knowledge consulted), with needle 'design'.
- measure-doc-harness-blob: MEASURE and EVAL only, fires when the body lacks \bblob\b|rev-parse|hash-object.
Write only: an Edit fragment does not carry the whole doc.
Fixtures:
- MUST FIRE: a Write of design\MEASURE-x-2026-09-23.md with no section.
- MUST NOT FIRE: the same with the section at char 3,000, which proves WS-B.
- MUST NOT FIRE: an Edit of the same path.
- CLEAN TWIN: memory-without-cost-band still fires on a memory Write with no cost line.
Telemetry: fire log class 'analysis-doc'; the WS-E commit join resolves persisted/fixed on the committed doc.

CRITIQUE: Low value on this evidence. If it is built: take PLAN_RE and PLAN_CUTOFF from ops/store_citation.py (share the function) so the row judges only the docs the gate judges. Leave EVAL out unless the gate changes in the same commit. Require a NON-EMPTY section; the sketched regex accepts a bare heading, which store_citation refuses. Drop measure-doc-harness-blob, since 3 of 3 already comply. Fixtures: MUST NOT FIRE a PLAN dated 2026-09-18; MUST FIRE a Knowledge consulted heading with nothing under it.

### rate-gate-corpus-unlike-live [issue/general/medium] VERDICT=OVERSTATED
The per-row precision gate scores a corpus unlike live traffic; the loudest live row passes it

CORRECTED: The select-first comparison sets two different patterns side by side. Almost all of the 999 live fires (4.7%) ran under the OLD pattern. The corpus gate itself had flagged that pattern TOO LOUD (225 of 5,588, 4.03%, recorded in pattern_why), and Brad's ruling replaced it today. Under the new pattern the live rate is 12 of 2,033 calls (0.59%, about 5 hours of traffic, cap 3%). For rows whose pattern did not change, the live rate runs 2 to 3 times the corpus rate: count-on-maybe-absent 1.16% vs 0.39% (cap 4%), worktree-add-crlf 0.84% vs 0.38% (cap 1%). No row is currently over its cap. The structural causes stand: top-level transcripts only, 600-character probes, 400 files.

FIX: WS-D.
(1) recall-tool-probes.py: harvest through recall_transcripts.iter_transcript_files (WS-C), store commands at 4,000 chars (WS-B), and write a sidecar file recall-tool-probe-denominators.json with {tool: count, window}.
(2) recall_reflex.py --rate --live: read the last 7 days of non-shadow fire-log rows (load_fire_log) and divide by eligible calls, from the WS-F coverage log once it exists and from the denominators file until then. Print every row as 'fires N of M eligible (x%) cap y%'. Exit 1 when a row is TOO LOUD LIVE. It also ends with RECALL-REFLEX-RATE-COMPLETE.
(3) recall-reflex-ladder.py gains a 'LIVE LOUD' section that lists such rows for review (never an edit), plus rows with 0 live fires in 14 days as 'DEAD?'. That is the floor for a producer that stopped.
(4) Put select-first-in-writing-pipeline to Brad with the numbers: exclude read-only upstreams (knowledge-search\search.py, ops\audit-*.ps1 whose plain run never writes its mark) or move the row to shadow.
Fixtures:
- MUST FIRE: a synthetic fire log with 50 fires of a row over 1,000 eligible and a 3% cap is TOO LOUD LIVE.
- MUST NOT FIRE: 20 of 1,000 is ok.
- CLEAN TWIN: the corpus --rate still runs and prints its own denominator.

CRITIQUE: (a) Item (4) is wrong. search.py is not a read-only upstream: it writes its knowledge-search log row in a finally block after printing, and Select-Object -First kills it before that (probe above). 19 of 75 PowerShell store searches in 7 days were piped that way. Those fires were TRUE, and those searches are invisible to store_citation.py. Do not exclude search.py; steer users to --k N or '| Select-Object -Last N'. (b) --rate --live must segment fires by pattern version. Store a pattern hash in each fire row, or every pattern change produces this same confound. (c) select-first is labelled harm=loud, but its memory says the harm is silent ('reports success and changes nothing'). Its burn rate therefore justifies nothing; relabel it before anyone reads its ladder line. (d) 'DEAD?' is fine as a report and must never auto-retire a row.

### set-content-rewrite-steers-wrong [issue/code/medium] VERDICT=CONFIRMED
The Set-Content rewrite pushes toward the BOM-writing form the estate forbids for commit messages and tracked files

CORRECTED: Confirmed but latent. Every detected commit-message write in 7 days (91 of 91) used WriteAllText, so the rewrite has not yet put a BOM into a commit subject.

FIX: (1) recall_reflex.apply_rewrites: honour a new row field rewrite_unless, a regex over the whole command. Set it on set-content-no-encoding to git\s+commit\b[^\n]*\s-F\b. When it matches, apply no rewrite and keep the reminder.
(2) Change the row's message to: 'Set-Content/Add-Content/Out-File default to ANSI; under PS 5.1 -Encoding utf8 writes a BOM. A commit message: [IO.File]::WriteAllText($p,$b,(New-Object Text.UTF8Encoding($false))). A tracked file in ThriftyCrew: Write-TcLfFile (lib/lf-write.ps1). Anything else: -Encoding utf8.'
(3) Add exts ['.ps1','.psm1'] for edits, via WS-A's in_scope.
Fixtures in recall-reflex-hook.py --selftest:
- MUST NOT FIRE (rewrite): the commit -F command gets no updatedInput, and its reminder names WriteAllText.
- CLEAN TWIN: the existing 'the same rule still fires in PowerShell' case (Set-Content a.txt 'x' gets -Encoding utf8) passes.
- MUST NOT FIRE: a Write of notes.py whose text mentions Set-Content is silent.

CRITIQUE: (a) rewrite_unless on the SAME command misses the usual split, where the message file is written in one call and committed in the next. The rewrite would still fire on the Set-Content call. (b) The rung does not fit PS 5.1. A rewrite needs a total, correct transform. '-Encoding utf8' is wrong for commit messages (BOM) and for eol=lf tracked files (CRLF plus BOM), and ANSI is wrong for non-ASCII text. No single insertion is right, so demote the row to remind (Brad set the rung, so this needs his ruling) or limit the rewrite to paths outside every repo that are not message-named. (c) exts for edits is right and also removes the .py false fire. Fixtures: MUST NOT FIRE (rewrite) on 'Set-Content $env:TEMP\msg.txt $body' when message-named paths are excluded; CLEAN TWIN 'Set-Content a.txt x' is still rewritten if the rung stays.

### miss-pipeline-noise-and-person-bound [inefficiency/general/medium] VERDICT=CONFIRMED
33 of 44 MISSES are noise, and every step from a MISS to a live row waits on a person; nothing has moved in 12 days

CORRECTED: The pipeline state is confirmed. The 33-of-44 noise split is a reading judgement. I agree on the degenerate signatures ('<n>', '<path>', 'o', 'groce', 'False', '---', 'exit=<n>') and on the gate verdicts. MissingEndParenthesisInExpression (11 over 11 sessions) recurs as widely as EmptyPipeElement, so it belongs in the strong class, not the weak one.

FIX: WS-I.
(1) recall-reflex-propose.miss_kind gains three kinds:
- 'degenerate': the sig has fewer than 2 alphabetic words of 3+ letters after normalisation.
- 'verdict': extend MISS_OUTCOME_RX with REFUSED|not qualifiable|^ok\s|restored identical|SELF-TEST.
- 'error-class': the sig carries 'FullyQualifiedErrorId : \w+', a Python '\w+Error:', or 'Remove-Item on system path'.
(2) recall-failure-harvest.py labels rows from project dirs matching ^C--Codex-tc-exp- as 'experiment' and excludes them from misses with a counted reason.
(3) The recall-sleep report groups misses by kind with counts and lists only cue and error-class as MISSES.
(4) New catalog C:\Users\Owner\.claude\skills\recall-error-class-cues.json mapping an error class to a candidate pattern and message. Example: EmptyPipeElement -> (?m)^\s*(?:for|foreach|while)\s*\([^\n]*\)\s*\{[\s\S]{0,400}?\}\s*\| with the message 'a for/foreach/while statement cannot be piped; wrap it in $( ) or & { }'. The nightly pass sends each catalog hit through recall-reflex-author.py's checks as a DRAFT. Drafts inject nothing, so this is automatic up to shadow and no ruling is touched.
(5) Weekly: a session drafts 3 must_not_fire candidates per near-READY draft from real harvested commands that contain the draft's needle but miss its pattern. They are filed as ONE recall-inbox batch for Brad, which is the ruling's own procedure.
(6) Author three rows now, from the strong misses:
- git push in ThriftyCrew -> ops\push-main.ps1. Needs a scope that can read the payload cwd; add that to in_scope.
- An Edit/Write of \.claude[\\/]scheduled-tasks[\\/][^\\/]+[\\/]SKILL\.md -> 'mirror into ops\prompt-backup\scheduled-tasks\<name>\SKILL.md; ops/audit-prompt-backup.ps1 reds when they differ'.
- EmptyPipeElement.
The Remove-Item row waits on the open question about the harness's cue.
Fixtures in propose --selftest:
- MUST FIRE: 'False' -> degenerate.
- MUST FIRE: 'FullyQualifiedErrorId : EmptyPipeElement' -> error-class.
- MUST NOT FIRE: a real cue stays cue.
- CLEAN TWIN: the existing harness and outcome labels are unchanged.

CRITIQUE: (a) Approval is not the only blocker. 0 of 122 drafts are READY on evidence, and READY depends on burn evidence that subagent blindness hides. Wire PostToolUseFailure first, then re-read the ladder. (b) A catalog cue such as the EmptyPipeElement regex is a guess at the shape. It must pass recall-reflex-author's QUIET and fire-rate checks and stay in shadow; a lower-effort implementer will ship it live. (c) The ThriftyCrew git-push row needs cwd, which in_scope cannot see. Make that a separate in_scope change with its own fixture, and never put it at block: CLAUDE.md says a plain git push is still fully gated. (d) Excluding tc-exp directories by name must print how many rows it excluded.

### python-and-brain-code-uncovered [gap/code/medium] VERDICT=CONFIRMED
Python code, the identity graph and the brain's own code get nothing from the tool tier

CORRECTED: The counts are confirmed. The recorded commodity trap, however, was keying on a BARE id ('shredded-cheese') during an analysis for a fence proposal, not a 'commodity:<x>' literal in graph code.

FIX: Add these rows to recall-reflexes.json, rung remind, tools [Edit, Write], exts ['.py'], each with 2+ must_fire and 2+ must_not_fire from real code:
- py-text-mode-tracked-write: scope 'codex/thriftycrew', pattern \bopen\([^)\n]*['\"]w[t+]?['\"](?![^)\n]*newline). Message: 'Python text mode on Windows writes CRLF over an eol=lf blob; pass newline="\\n" (fdc_lookup.cache_write)'. Source .claude/rules/ops-and-gates.md.
- graph-bare-commodity-id: scope 'thriftycrew/graph', exts ['.py','.ps1'], pattern ['\"]commodity:(?!staple:|recipe:)[a-z0-9][a-z0-9-]*['\"]. Source memory identity-graph-commodity-is-namespaced.
- brain-log-not-redirectable: scope '.claude/skills', pattern os\.path\.join\([^\n]*['\"]recall-[\w-]+\.jsonl['\"](?![^\n]*environ). Message: 'a log constant nobody can redirect lets a selftest write the live record; read it from RECALL_*_LOG like recall-reflex-hook.py LOG'.
Run recall_reflex.py --selftest and --rate (post WS-D) before shipping.

CRITIQUE: (a) graph-bare-commodity-id as sketched cannot catch the founding incident: there was no 'commodity:' prefix at all, and it happened in analysis rather than graph code. It belongs on the analysis side, as a cue on reading graph/identity/*.jsonl and comparing the commodity field, and it must be measured. (b) py-text-mode-tracked-write matches 124 lines in 78 tracked files, many of them writing untracked out/ files, and a regex cannot tell a tracked target. Measure --rate on edit probes before shipping it. (c) brain-log-not-redirectable is sound and cheap; add a MUST NOT FIRE for recall-reflex-hook.py's own env-redirected LOG line.

### no-coverage-telemetry [gap/both/medium] VERDICT=CONFIRMED
The brain cannot say what share of code edits got any knowledge; answering took a 582-transcript scan

CORRECTED: Confirmed: per-path coverage cannot be computed without scanning transcripts. A coarse per-session ratio (reflex fires on edits over PreToolUse:Edit heartbeats) is available from recall-session-log.jsonl. Those heartbeats come from session state, which loses writes (7,469 failed os.replace calls leave .tmp files), so even that ratio undercounts.

FIX: WS-F. recall-reflex-hook.py main(): immediately after query_for returns an action, append one row through recall_append.append_rows to COVERAGE_LOG = env RECALL_COVERAGE_LOG or ~/.claude/recall-coverage-log.jsonl. Fields:
- t, sid, agent, tool, kind;
- repo: thriftycrew | thriftycrew-worktree | skills | fantasy | scratch | other, from the path for edits and from payload cwd for commands;
- top: the first directory below the repo root;
- ext;
- fired: the live ids;
- shadow_n.
Never command or body text. About 25k rows a week at roughly 150 B.
recall-stats.py prints:
- 'estate code edits with any tool-tier pointer: N of M', by top dir and by origin (main/agent);
- 'machinery pointers: N'.
The floor: recall-sleep hook-health prints WARN when PreToolUse heartbeats exist in the last 24 h and coverage rows are 0.
Fixtures in reflex-hook --selftest, with RECALL_COVERAGE_LOG redirected to tmp:
- MUST FIRE: a silent Write of ops\x.ps1 still writes a row with fired [].
- MUST NOT FIRE: no row contains the body text (assert the literal 'Move-Item' is absent).
- CLEAN TWIN: the fire log still gets its rows.

CRITIQUE: (a) Write the new log through recall_append. (b) Take 'repo' from the file path for edits. For commands, payload cwd alone is wrong for C:\Codex-rooted sessions that edit ThriftyCrew; use cwd plus any absolute path in the command, and record which source was used. (c) The WARN floor ('heartbeats exist and coverage rows are 0') needs heartbeats that do not lose writes. Otherwise compare the coverage log's daily count against transcripts. (d) About 25k rows a week needs a named pruner.

### tool-tier-logs-use-lossy-append [issue/general/medium] VERDICT=CONFIRMED
The reflex and outcome hooks still append with open(LOG,'a'), which recall_append.py replaced elsewhere because it loses rows under parallel subagents

CORRECTED: Confirmed, and the mapper's list is incomplete. At least 7 hook-path append sites still use open(...,'a'), including the SubagentStop roll-up that runs once for every parallel subagent.

FIX: Replace each of the four open(...,'a') sites with recall_append.append_rows(LOG, rows), building all rows of one call into one list, one call per hook invocation. Keep the surrounding try/except so it still fails open.
Add a selftest static case in recall_append.py --selftest, a MUST FIRE: grep every recall-*hook*.py for 'open(' followed by '"a"' and fail naming the file and line. Build the needle by concatenation so the test does not match its own source (ops-and-gates 'a self-test that greps its own source cannot fail').
CLEAN TWIN: the reflex-hook selftest's 'every fire writes a log row' still passes.

CRITIQUE: (a) The proposed static check greps only recall-*hook*.py, so it misses modules the hooks import (recall_correction.py, recall_selfcorrection.py). Scan every recall_*.py and recall-*.py, and allow-list the single-writer nightly scripts by name. (b) The reflex hook opens the log twice per call (shadow rows, then fire rows); combine them or accept two append calls. (c) Build the needle by concatenation, and keep the fail-open try.

### rung-mislabels [issue/general/low] VERDICT=CONFIRMED
The fire log and the ladder mislabel the rewrite rung

CORRECTED: Confirmed, with 13 edit fires (not 18) in 7 days once this session is excluded.

FIX: (1) recall-reflex-hook.py: after computing acted, add `if acted == 'rewrite' and kind != 'command': acted = 'remind'`.
(2) recall-reflex-ladder.recommend: when rung == 'rewrite', return ('rewrite-check', 'burned after the rewrite on N of M; inspect what the rewritten command did') and never promote.
Fixtures:
- Hook selftest MUST FIRE: a Write tripping set-content-no-encoding logs acted=remind.
- Ladder selftest MUST NOT FIRE: a rewrite row with a 35% burn is not 'promote'.
- CLEAN TWIN: a remind row at 35% burn still promotes.

CRITIQUE: The fix corrects only future rows. Readers (the ladder, stats) must also treat old rows with acted=rewrite and kind=edit as remind. The fixtures as sketched are right.

### selftest-writes-live-state [issue/general/low] VERDICT=CONFIRMED
The outcome hook's self-test writes session state into the live recall-sessions directory

CORRECTED: Confirmed, and the class is wider: the correction hook's self-test also writes fake keys into the live state directory.

FIX: In recall-reflex-outcome-hook.py selftest, set env['RECALL_STATE_DIR'] = a temp directory next to tmplog, and remove it in finally.
Add a MUST FIRE case: the temp STATE_DIR contains s1.json after the subprocess runs. That proves the redirect took effect and makes the case independent of the live directory.

CRITIQUE: Fix both suites. Add one shared helper that builds a fully redirected environment (RECALL_STATE_DIR, RECALL_REFLEX_LOG, RECALL_REFLEX_OUTCOME_LOG, RECALL_SESSION_LOG, RECALL_LOG), so the next suite cannot forget one of them. The MUST FIRE should check two things: the temp directory holds s1.json, and the live s1.json's mtime did not change.

### floors-derived-with-no-consumer [inefficiency/general/low] VERDICT=CONFIRMED
Tier-2 recognition floors for command/edit/path are derived and gated nightly, but no installed hook reads them

CORRECTED: Confirmed. No installed hook reads recall-floors.json.

FIX: Run a consumer census first (grep plus import graph) and record it.
Then, in recall-sleep.py, derive floors only for kinds with a live consumer (prompt, if the calibrate gate needs it). Otherwise label the step 'derived for calibration only; no hook reads these floors'.
recall-hook-calibrate should report the same label rather than 'ok'.
Fixture: sleep selftest MUST FIRE: the report line for an unconsumed kind carries the 'no hook reads' label.

CRITIQUE: If derivation stops but recall-floors.json stays, recall-hook-calibrate compares stale floors and lands in its COULD-NOT-COMPARE / blocked states. Change the calibrator and check-skills in the same commit, and label the file rather than deleting it. automatic-recall.md s4 describes the tool-event floors as if a live tier used them; correct that text too.

### rules-loaded-at-start-cost [inefficiency/general/low] VERDICT=CONFIRMED
All six ThriftyCrew rules files (118.5 KB) load at session start for every ThriftyCrew-rooted agent, contrary to the store's account

CORRECTED: All six rules files (118,538 bytes) load unconditionally in every ThriftyCrew-rooted session. The loader reads only frontmatter 'paths', and the files declare 'globs', which no installed CLI (2.1.173 through 2.1.280) reads. This is not a harness change. The 2026-09-06 'verification' mistook Bun's embedded .cursor/rules template for Claude Code's loader, so claude-code-craft 11.1, BACKLOG:1440 and every rules-file header saying 'Loaded only when you touch' are wrong.

FIX: (1) Re-run the store's two-file probe (a rule scoped to a path nobody touches) under the current CLI and record the result in claude-code-craft/claude-md-and-commands.md 11.1, with date and version.
(2) If rules load unconditionally now, correct the 'Loaded only when' header lines in the six files and record the per-session byte cost.
(3) Do not trim ops-and-gates.md on this finding alone. It is the channel that currently delivers the machinery names, and WS-A is what makes them fire at the moment of writing.

CRITIQUE: This is the riskiest item for a lower-effort implementer. 'Fixing' globs to paths would make ops-and-gates.md load only under ops/** and lib/**. grocery/ and meal-prep/ code sessions, which made 1,289 ThriftyCrew code edits this week, would lose the helper names. measurement.md would load only for eval/probe/audit files, so python -c analysis sessions would lose it too. Goals 1 and 2 would regress silently while the token cost fell. The plan must decide this explicitly. Option 1: keep the rules unconditional, set alwaysApply: true or drop the dead fields, correct the headers and 11.1, and record the cost of about 118.5 KB per session. Option 2: switch to paths, but first move the machinery index (helper names, gate names, lock order) and the measurement rules into a small always-loaded file. The probe is the two-file test the backlog originally required: one rule with paths: ["zz-nobody/**"] and one with globs: "zz-nobody/**"; start a fresh session and see which one loads.

### strength-block-and-rewrite-rungs [strength/code/low] VERDICT=CONFIRMED
STRENGTH: the block and rewrite rungs demonstrably stop mistakes, with a working waiver

CORRECTED: Confirmed for the block rung. The rewrite rung is weaker: bare-python reads PROMOTE at 13 of 37 burned, and set-content's transform is not correct under PS 5.1.

FIX: Keep as is. Reuse its pieces for WS-J (edit_block): rung_for, decide, deny_reason and the override comment.

CRITIQUE: Reuse rung_for, decide and deny_reason for edit_block, with only the gate's allow marker as the waiver for edits.

### strength-hooks-reach-every-agent [strength/both/low] VERDICT=CONFIRMED
STRENGTH: tool-tier hooks fire for subagents and workflow agents, keyed per agent, cheaply

CORRECTED: Confirmed: the hooks fire for subagents and workflow agents, and each call is keyed to its agent.

FIX: Keep. Build new edit-time rows (WS-A, WS-H) on this hook rather than on the Agent brief path, because workflow agents never pass through the brief gate.

CRITIQUE: Reach is not the same as a reliable record. Session-state writes lose updates for these agents (orphan .tmp files), and their burns are invisible until PostToolUseFailure is wired.

### strength-rules-deliver-machinery-names [strength/code/low] VERDICT=CONFIRMED
STRENGTH: the .claude/rules channel does put the estate's helper names in front of essentially every ThriftyCrew code session

CORRECTED: Confirmed. This delivery exists only because the globs field is inert, which is an accident, not a design.

FIX: Keep. Point every WS-A row's source at the ops-and-gates.md bullet, so the reminder names the account the model already has loaded.

CRITIQUE: Any plan item that touches the rules frontmatter must preserve this channel on purpose (see rules-loaded-at-start-cost).

### strength-row-discipline [strength/general/low] VERDICT=CONFIRMED
STRENGTH: every live row is fixture-tested, capped and counted, and the tier refuses to become a search

CORRECTED: Confirmed.

FIX: Keep. Every WS-A, WS-H and WS-I row must pass check_fixtures and --rate (and --rate --live once WS-D lands) before it is added to recall-reflexes.json.

CRITIQUE: The fixture gate cannot see what a pattern change does to live traffic; today's select-first tightening mixed two patterns in one fire log. Store a pattern hash in each fire row so rates can be segmented by pattern.

## Missed by mapper
- [high] The rules files' 'globs:' field is never read by any installed CLI, so the store's 2026-09-06 'correction' is wrong and the helper-name channel for goals 1 and 2 rests on an accident: The rules loader in 2.1.236, 2.1.263 and the running 2.1.280 returns no scope when frontmatter.paths is absent: 'if(!t.paths)return{content:r}'. In 2.1.263 the word 'globs' appears only in Bun's embedded .cursor/rules template and in ripgrep docs. The CLI text says rules 'can be scoped ... using `paths` frontmatter' in 2.1.173 through 2.1.280. claude-code-craft 11.1 and BACKLOG-course-findings.md:1440 cite the Bun template as proof. automatic-recall.md 2a also leans on it ('loaded when working in the area they describe, which the directory rules already do'). Consequence: ops-and-gates.md (74,418 bytes) and measurement.md reach every ThriftyCrew session only because scoping silently failed, and switching to paths: would remove them from grocery/meal-prep code sessions (1,289 code edits this week) and from analysis sessions.
- [high] PostToolUseFailure exists in every installed binary; the store records failure-side hooks as impossible, and the probe PLAN-brain-v2 0a ordered was never recorded: 2.1.280 builds a hookInput with hook_event_name 'PostToolUseFailure', tool_name, tool_input, tool_use_id, error, is_interrupt and duration_ms, and the settings schema enum lists it. It is present in 2.1.173 (25 hits), 2.1.236 and 2.1.263. automatic-recall.md s2: 'A PostToolUse hook on failures cannot exist [REFUTED 2026-09-07]'. PLAN-brain-v2-2026-09-09 line 202 asks for a probe of it; knowledge-search finds no match in 2,289 sections. Wiring the outcome hook to this event would record burns live for all 1,237 subagent outcomes that are currently fine-only, and would make the same-session promotion same-turn instead of a night late. Pitfall: recall_failure.is_failure reads tool_response, which this payload lacks, so a naive wiring logs every failure as 'unknown'.
- [medium] Session state loses writes: 7,469 orphan .tmp files, a lost update by construction, and a sweep that grows with the orphans: ~/.claude/recall-sessions holds 150 .json and 7,469 '<key>.json.<pid>.tmp' files (708 dated 2026-09-22; daily counts since 2026-09-08). recall_core.save_state (line 242) writes tmp, calls os.replace, and on any exception returns False and leaves the tmp. On Windows, os.replace is refused while another hook holds the target open for reading: the reader-costs-writer shape ops-and-gates records for Move-Item. sweep_stale removes only .json, so the orphans are never cleaned. The reflex and intent hooks both load, modify and save the same key on the same PreToolUse event, which is a lost update even when the replace succeeds. Affected data: heartbeats (the Stop build-8 assertion), reflex counts, intent_seen/intent_asked dedup, 'offered' (read by recall-consulted-hook), promotions. Each save lists 7.6k entries: about 18 ms per sweep, measured read-only, at several saves per tool call. knowledge-search for 'orphan tmp state' found nothing.
- [medium] A store search piped to Select-Object -First loses its own log row, so the Store: evidence misses it: Probe with RECALL_LOG redirected to scratch: 'search.py --full --k 20 reflex ladder rung | Select-Object -First 3' wrote 0 rows, and still 0 minutes later; the same command unpiped wrote 1; bash '| head -3' wrote 1. search.py logs in a finally block after printing (search.py:1091-1096). 19 of 75 PowerShell store searches in 7 days were piped into Select-Object -First (vt/ksfirst.py). store_citation.py and store-usage-report read that log to decide whether a session searched. The select-first row is labelled harm=loud, but its memory says the harm is silent.
- [low] The fire and outcome joins key on chash within a session although every hook payload carries tool_use_id: 2.1.280 payloads: PreToolUse {tool_name, tool_input, tool_use_id}; PostToolUse {..., tool_response, tool_use_id}; PostToolUseFailure {..., error, tool_use_id}. claude-code-automation/hooks-measured-payloads.md:112 records that tool_use_id 'pairs a PreToolUse with its PostToolUse'. The reflex fire row and outcome row store no tool_use_id, so a command repeated by one agent makes the join ambiguous, and any cap change on the chash input silently breaks it.
- [low] Workflow-agent transcripts sit two levels deeper than subagent transcripts: 19 of the 359 subagent transcripts modified in 7 days are at projects/<proj>/<sid>/subagents/workflows/wf_<id>/agent-<id>.jsonl, including this review's own agents. The WS-C sketch derives sid from the directory structure, which gives the wrong sid for these. Rows carry sessionId and agentId, which should be used instead.
- [low] The correction hook's self-test also writes fake sessions into the live state directory: ~/.claude/recall-sessions/sess1.json (runs 16) and nosession.json (runs 8), written 2026-09-22 19:16, hold only UserPromptSubmit:correction events. 'sess1' appears in recall-correction-hook.py and recall-stop-hook.py, and 'nosession' in recall_core.py. Same shape as selftest-writes-live-state, outside the tool tier.

## Open questions
- Why do 422 of 679 judgement-classified shell calls get no intent injection? The candidates are sidecar down, per-intent or per-section dedup, and no hit above MIN_COSINE. The intent hook keeps no log, so this is not measurable until WS-G's log exists.
- Did the C:\Codex\tc-exp-* experiment arms run with hooks deliberately disabled? They made 173 code edits with 0 injections, several 70-120-call transcripts have 0 hook attachments, and the directories are now deleted. The answer decides whether they belong in any coverage denominator.
- Which token does the harness key on when it refuses 'Remove-Item on system path /c is blocked'? There are 41 failure rows over 28 sessions, mostly `Remove-Item $tmp` or `-LiteralPath $out`. It must be known before the row for that MISS can be written.
- Is PostToolUse additionalContext delivered for Edit/Write? If so, a PostToolUse hook could run a gate's pure function (e.g. audit-bare-replace's Count-Hits) on the file just written, an exact mirror with no regex drift. Not verified here.
- Do globs + alwaysApply:false still path-scope rules under harness 2.1.275/2.1.280? All 6 rules loaded at start in 45 of 45 ThriftyCrew-rooted transcripts, which contradicts claude-code-craft 11.1.
- Did the 3 MEASURE doc Writes that lacked '## Knowledge consulted' at write time gain it by a later Edit before push? Not measured.
- Does an injected reminder change what the model does next? The store's own open gap. For edit rows no outcome exists at all until WS-E's commit join lands.
- Should select-first-in-writing-pipeline be sharpened or moved to shadow? It fires on 4.70% of eligible live calls against a 3% cap, including every `search.py ... | Select-Object -First N`. This is a ruling for Brad.
- Workflow-tool agents are not spawned through Agent|Task, so the brief gate and recall-agent-hook never see their prompts. Only one workflow run exists in the 7-day window (this review), so the impact on code work is unmeasured. It is another reviewer's subsystem but bears on goal 1.
