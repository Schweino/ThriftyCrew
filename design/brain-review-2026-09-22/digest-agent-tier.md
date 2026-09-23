# agent-tier

Two hooks make up the agent tier. Both are registered only on PreToolUse with matcher "Agent|Task" (settings.json line 46). recall-agent-hook.py searches the skills corpus using the brief as the query (BM25, floor taken from recall-hook.MIN_SCORE, at most 5 sections, 1,200 bytes). It appends the pointers to the prompt through updatedInput and records them in the PARENT's session state (recall_core.record, line 208). It writes no durable log of what it sent. recall-brief-gate-hook.py denies a brief with no "Knowledge consulted" section that names a path, a memory or a search. It is presence-only, writes no log at all, and exempts Explore, claude-code-guide and statusline-setup.

On the Agent-tool path both hooks work every time. 54 of 54 helpers spawned since the gate landed (2026-09-19T18:55Z) carry the block and a passing section. There were 2 refusals in 57 calls, and both were resent as passing briefs within 94 s. That includes helpers spawned by scheduled tasks.

Three other ways of starting a helper never pass through either hook:
- Workflow-tool agents. agent() inside a script is not an Agent tool call. 0 of 1,306 workflow-agent transcripts ever carried the block. Today's 9 agents passed only because the orchestrator wrote the section by hand, and 33 of 34 saved workflow scripts contain no section.
- spawn_task children. 1 of 24 prompts since 2026-09-12 carried a section.
- Headless claude -p runs (approvals_runner, hunt_dispatch). Their brief is built in Python.

What does reach a workflow agent (observed from inside one):
- CLAUDE.md at all three levels, all six .claude/rules files and the MEMORY.md index.
- A Skill tool.
- Every PreToolUse and PostToolUse tool-tier hook. That is 97 reflex rows across 9 of 9 agents, with intent-hook additionalContext arriving in this agent's own context.

What does not reach a workflow agent: UserPromptSubmit recall, the agent-hook pointers, the brief gate, and the Stop consulted gate. SubagentStop runs only the roll-up.

Scheduled sessions, headless runs and spawn_task children are top-level sessions, so they do get UserPromptSubmit recall. spawn_task children run in worktree project dirs whose memory corpus resolves to nothing.

The store-first step exists as one copy-pasted block in 6 of 13 agent definitions and in 1 scheduled task (grocery-alert-triage). Its trigger is worded for code only ("a finding that proposes code"). It is missing from 4 of the 7 verdict and analysis agents and from the analysis task verify-board-sample. The user-scope and project-scope copies agree 9 of 9, synced daily by audit-prompt-backup -SyncScopes.

Measured use of the hook's pointers: helpers read 148 of 1,274 injected pointers (since 2026-09-08). Since the gate the figure is 14 of 193, and 21 of those 193 repeat a path the brief's own section already named.

## Measurements
- workflow-agent transcripts whose opening prompt carries the recall-agent-hook block: 0 of 1,306 (1,297 before the gate + 9 today); Agent-tool subagents since the gate: 54 of 54  [workflow transcripts 2026-06-20..2026-09-22; Agent-tool since 2026-09-19T18:55Z]
- workflow agents whose brief passes recall-brief-gate verdict(): 9 of 9 since the gate (one run, section written voluntarily by the orchestrator); 0 of 1,297 before  [2026-06-20..2026-09-22]
- saved workflow scripts carrying a Knowledge consulted mention with evidence: 1 of 34 (only today's brain-review script); recall-brief-gate verdict() applied to that compliant script returns deny ('no Knowledge consulted section') because HEAD_RE is line-anchored and the script has const KNOWLEDGE = `## Knowledge consulted  [all saved workflow scripts under ~/.claude/projects/*/*/workflows/scripts]
- tool-tier hook rows from workflow agents in this run: 97 recall-reflex-log rows across 9 of 9 workflow agents (12 block, 6 rewrite, 8 remind, 71 shadow); recall-log open rows from 8 of 9; intent-hook additionalContext observed 6+ times in this agent's own context  [2026-09-22, this workflow run]
- UserPromptSubmit recall reaching workflow agents: recall-leg-log has 1 row for this session (the parent prompt, t=1790120246) and none at the 9 agents' start (~t=1790120600); 4 offer rows for the parent, none for any agent  [2026-09-22]
- brief-gate refusals versus Agent/Task calls: 2 of 57 calls refused; both resent with the same subagent_type and a passing section, after 38.7 s (triage-ops-developer) and 93.9 s (triage-reviewer)  [2026-09-19T18:54Z..2026-09-22]
- Knowledge consulted quality on Agent-tool briefs: 46 of 54 cite at least 1 store path, 8 of 54 are searched-only; 102 of 102 named paths resolve (skills, repo, .claude/rules or memory)  [since 2026-09-19T18:55Z]
- Agent/Task calls preceded by a logged knowledge-search under the same sid: 39 of 50 at any earlier time, 31 of 50 in the 60 min before; upper bound, because parent and helpers share the sid  [since 2026-09-19T18:54Z, top-level transcripts]
- agent-hook pointers the child later read (Read file_path, or a read-shaped shell command): 148 of 1,274 pointers over 365 children (88 read at least 1). Since the gate: 14 of 193 (12 of 54 children). Before the gate: 134 of 1,081. An open is not a use.  [2026-09-08T10:00Z..2026-09-22]
- agent-hook pointers that repeat a path already named in the same brief's Knowledge consulted section: 21 of 193  [since the gate]
- helpers that ran knowledge-search themselves: 24 of 54 since the gate; 115 of 365 since 2026-09-08  [as stated]
- spawn_task prompts carrying a passing Knowledge consulted section: 1 of 24 (from 17 parent sessions); 24 of 24 matched at least one child session, 23 of 24 children got a UserPromptSubmit offer row, and every matched child is in a C--Codex-ThriftyCrew--claude-worktrees-* project dir  [2026-09-12..2026-09-22]
- sessions with at least 1 UserPromptSubmit offer row, by launch kind: scheduled-task 15 of 15; headless sdk-cli 15 of 17 (approvals runner on 09-12, plus 2 'say hi' probes); worktree 44 of 45; main 194 of 244  [2026-09-12..2026-09-22]
- recall corpora for an existing worktree cwd: skills + rules (the worktree's own copy), NO memory corpus; main checkout resolves skills + 187 memories + 6 rules  [2026-09-22]
- store-first block coverage: agent definitions 6 of 13; verdict or analysis-role agents 3 of 7 (missing: recipe-batch-auditor, recipe-dedup-selector, recipe-source-qa, recipe-hunter-pricer); Edit/Write-capable agents 4 of 5 (missing: recipe-batch-auditor); enabled or paused scheduled tasks 1 of 6 (grocery-alert-triage only)  [2026-09-22]
- user-scope versus project-scope agent drift: 9 of 9 shared files byte-identical; 4 are project-only by design (commodity-registrar, recipe-hunter-extractor, recipe-hunter-pricer, recipe-source-qa)  [2026-09-22]
- triage plans carrying knowledge_consulted: 19 of 23 non-routing plans; missing: plan-2026-09-20-4, -5, -6 and plan-2026-09-22-2  [2026-09-19..2026-09-22]
- agent-hook records the child's pointers in the parent's state: after 1 enrichment, the parent key held offered=5 and consulted-hook.offered_this_turn() returned 5  [2026-09-22 probe]
- parent turn roll-ups with PreToolUse:Agent beats that count child bytes as the parent's injections: 204 of 204  [2026-09-19T06:40Z..2026-09-22]
- brief-gate verdict() on weak sections: 'memory: none' passes, a nonexistent 'no-such-craft/made-up.md' passes, a repo doc path passes, 'searched "stuff"' passes, prose-only is denied, subagent_type 'claude' is gated  [2026-09-22]
- self-tests: recall-agent-hook 21 of 21 pass, exit 0 (one case is tautological: line 362 '... or True'); recall-brief-gate-hook 15 of 15 pass, exit 0  [2026-09-22]

## Findings

### workflow-agents-bypass-agent-tier [gap/both/high] VERDICT=OVERSTATED
Workflow agents skip the whole agent tier: no brief gate, no pointer enrichment, no UserPromptSubmit recall

CORRECTED: Workflow-tool agents do bypass the whole agent tier.
- 0 of 1,312 workflow transcripts ever received the agent-hook block.
- 0 of 1,297 before today carried a passing brief. The 15 of 15 today pass only because one orchestrator wrote the section by hand.
- No UserPromptSubmit recall reaches them.

But the route is rare right now: 1 Workflow call against 314 Agent calls since 2026-09-12, and none between 2026-08-24 and today. So the live exposure is one run of 15+ agents in four weeks, not 'the default route'. Severity medium, not high. It is a latent hole that grows only if Workflow use comes back.

FIX: STEP 0, a probe with a written bar: PreToolUse must fire for tool_name 'Workflow' and carry tool_input.script. Register skills/recall-probe.py (the payload logger behind hooks-measured-payloads.md) on a temporary PreToolUse matcher 'Workflow' for one desktop session. Run a 1-agent workflow, confirm a row, then remove the entry. Record the result in claude-code-automation/hooks-measured-payloads.md. If it does not fire, drop layer A and say so there.

LAYER A: new skills/recall-workflow-gate-hook.py.
- Registration: its own settings.json PreToolUse block, matcher 'Workflow'.
- Input: payload.tool_input.script.
- Check: do NOT reuse brief-gate verdict(). Measured: it DENIES today's compliant script because HEAD_RE (brief-gate line 43) is line-anchored, while a script writes const KNOWLEDGE = `## Knowledge consulted. Instead, find re.compile(r'(?i)knowledge consulted\\W{0,6}') anywhere, take the text up to the next backtick or 4,000 chars, and pass when brief-gate EVIDENCE_RE matches it. Also require that the constant is used at least once beyond its definition (count occurrences of its identifier).
- On failure: permissionDecision deny. The reason text says: define const KNOWLEDGE = `## Knowledge consulted ...`, interpolate ${KNOWLEDGE} into every agent() prompt, and 'searched "<terms>", nothing applicable' is accepted.
- Waiver: a '// knowledge-exempt: <reason>' line in the script, logged.
- Never returns updatedInput (never rewrite JS). Fails OPEN on any exception or an empty script.
- Telemetry: one row per call to the brief-gate log from finding brief-gate-logs-nothing, with tool='Workflow', verdict, agent() count and named paths.
- Fixtures, from frozen copies under skills/fixtures/workflow-gate/: MUST FIRE a copy of code-sweep-2026-07-30-wf_a955625f-3c7.js (no mention) is denied. MUST FIRE a heading with nothing under it. CLEAN TWIN a copy of brain-review-wf_2ae11799-ea0.js passes (the template-literal shape). CLEAN TWIN searched-nothing passes. MUST NOT FIRE on Bash, on empty stdin, on non-JSON.

LAYER B: new skills/recall-subagent-prime-hook.py.
- Registration: its own PreToolUse block, matcher 'Bash|PowerShell|Edit|Write|Read|Grep|Glob'.
- Exit at once when there is no agent_id, or when state[primed] is set for recall_core.session_key(payload).
- Look for the agent's transcript by glob: projects/*/<session_id>/subagents/workflows/*/agent-<agent_id>.jsonl, with the root redirectable by env RECALL_PROJECTS_ROOT. Not found means an Agent-tool subagent that was already enriched: set primed and exit.
- Found: take the user messages before the first assistant row as the brief. Import recall-agent-hook.build_block(brief, cwd) and brief-gate verdict(). Emit hookSpecificOutput.additionalContext = block, plus one line when the verdict is deny: 'this brief carries no Knowledge consulted section; before code or a verdict run search.py <terms>'. Then set primed.
- Never emits permissionDecision. Fails open.
- This channel is proven: PreToolUse additionalContext reaches a workflow agent (observed in this agent).
- Latency bar, written before the build: p50 <= 150 ms on the already-primed path over 200 calls.
- Fixtures, from a temp projects tree: MUST FIRE the first call of a workflow agent emits the header. MUST FIRE a brief without a section gets the note line. MUST NOT FIRE the second call. MUST NOT FIRE with no agent_id. MUST NOT FIRE a subagents/agent-*.jsonl (Agent-tool) child. CLEAN TWIN a brief with a section gets no note line. CLEAN TWIN a missing transcript is a silent exit 0.

CRITIQUE: STEP 0 is right and must come first: nothing shows that PreToolUse fires for tool_name 'Workflow'. The payload shape rests on n=1 observed call, so the probe must also try a resumed or re-run workflow, which may carry no script.

LAYER A:
- A lower-effort implementer will hard-code the identifier KNOWLEDGE. Instead, derive it from the const whose template literal holds the heading, then count its uses.
- They will also pass on a mention inside a comment or inside the HOW text. Strip // and /* */ comments first.
- Fixtures: a script whose only mention is a comment is MUST FIRE. A script that inlines the section in each agent() prompt with no const is CLEAN TWIN.

LAYER B, three traps:
(1) recall_core.load_state is an ALLOW-LIST. A new state['primed'] key is DROPPED by every other hook's load and save unless it is added to the fresh dict in load_state. Then every call re-primes.
(2) Even when allow-listed, the state file loses writes under concurrent hooks (see missed finding recall-state-lost-writes: 581 of 738 roll-up keys show impossible heartbeat counts). Keep the primed marker as its own file created with O_CREAT|O_EXCL in its own directory, and give that directory its own sweep. sweep_stale only deletes *.json, and other readers list recall-sessions/*.json. Do not make this a third concurrent load-modify-save writer of the same key on PreToolUse.
(3) The harness indents computed text by 2 spaces. HEAD_RE tolerates up to 3, so fixtures must use the real harness-indented shape, copied from a frozen transcript. They must also cover the two-user-message brief, not a single message.

OTHER LAYER B POINTS:
- Its value is mostly the note line and the log, not the pointers. Since the gate, children opened 14 of 193 agent-hook pointers and 31 of 102 paths from the chosen Knowledge consulted section. Consider emitting only the verdict note plus a row, and folding it into recall-intent-hook, which already runs on Bash|PowerShell|Edit|Write and already emits additionalContext. That avoids another process on every call in every session.
- Latency: the bar must be measured on the not-yet-primed path too. It globs projects/*/<sid>/subagents/workflows/*, and over 165+ project dirs that is the slow path.
- Probe whether the transcript's user rows are on disk before the agent's first PreToolUse fires.

FIXTURES MUST PROVE:
- A second hook's save between prime and next call does not clear the marker.
- An Agent-tool child (subagents/agent-*.jsonl) is never primed.
- The p50 bar is measured on both paths.

### spawn-task-briefs-ungated [gap/both/medium] VERDICT=CONFIRMED
spawn_task session briefs are never gated, and their worktree children lose the memory corpus

CORRECTED: 1 of 24 spawn_task prompts since 2026-09-12 carried a passing Knowledge consulted section, and no hook sees those prompts. All 24 were picked up: 50 child sessions, every one in a worktree project dir. The recall corpus for a worktree cwd resolves to skills plus rules and none of the 187 ThriftyCrew memories. Whether the worktree child's system context still loads the main MEMORY.md index was not measured.

FIX: 1. settings.json: add a separate PreToolUse entry, matcher 'mcp__ccd_session__spawn_task', running recall-brief-gate-hook.py ONLY. Keep it off the recall-agent-hook entry: the child is a full session with its own UserPromptSubmit recall.
2. recall-brief-gate-hook.py:108: accept tool in ('Agent','Task','mcp__ccd_session__spawn_task'). A missing subagent_type already defaults to general-purpose, so it is gated.
3. Add a HOW variant for spawn_task that names the prompt field.
4. Fail open as today. No waiver beyond the honest negative.
5. Telemetry: the row from finding brief-gate-logs-nothing, with tool set.
6. Fixtures in --selftest: MUST FIRE a spawn_task payload with no section is denied. CLEAN TWIN a spawn_task payload with a memory citation passes with no output. MUST NOT FIRE mcp__ccd_session__mark_chapter. MUST NOT FIRE an existing Agent case changes verdict (the regression twin).
7. The worktree memory mapping is fixed in recall_index.resolve_roots by the prompt-tier plan, not here.

CRITIQUE: A step 0 probe is missing. Nothing measured shows that PreToolUse fires for this desktop-internal MCP tool name. Probe it with recall-probe.py before relying on the matcher, as the Workflow finding does.

Other risks:
- A lower-effort implementer will put the new tool name into the existing 'Agent|Task' block, and recall-agent-hook would then updatedInput-rewrite a chip prompt. The sketch rightly says: a separate block, gate only. The fixture must assert the agent-hook stays silent on a spawn_task payload, because its tool check is hard-coded, and the matcher alone would not protect it.
- The HOW text says 'helper brief'. The spawn_task variant must name the 'prompt' field.
- Order matters. The gate adds a citation, but the child still cannot RECALL memories until resolve_roots maps a worktree to the main project, and that fix lives in the prompt-tier plan. Land that first, or say in the plan that the gate alone does not restore memory recall.
- Fixture: the MUST FIRE payload should be a frozen copy of a real spawn_task input (keys prompt, title, tldr), not a hand-built Agent-shaped dict.

### brief-gate-logs-nothing [issue/both/medium] VERDICT=CONFIRMED
The brief gate logs nothing, so its refusal rate, bypass rate and citation quality can only be rebuilt from transcripts

CORRECTED: The brief gate writes no row and no heartbeat. Its refusal rate (2 of 50 top-level Agent/Task calls since the gate), its pass kinds and its bypass rate can only be rebuilt from transcripts, and the weekly store-usage report carries none of it.

FIX: 1. In main(), after verdict(), append one row via skills/recall_append.append_line (atomic, attempted once, never retried) to ~/.claude/recall-brief-gate-log.jsonl. The path can be redirected with env RECALL_BRIEF_GATE_LOG so self-tests never touch the real file.
2. Row fields: t, sid, agent (the parent's agent_id or ''), tool, subagent_type, verdict (pass|deny|skip), why, kc_kind (paths|memory|searched-only|none), kc_paths (list), kc_resolved (int), prompt_len.
3. Do not scan recall-log from inside the hook; that costs latency on every spawn. The report computes prior_search by joining sid and t.
4. Logging errors are swallowed and never change the verdict.
5. Extend store-usage-report.py with a 'briefs' section, every rate with its denominator: calls, denied, the share of denials followed by a pass for the same sid within 10 min, searched-only share, resolved share, and briefs with no prior search under their sid.
6. Fixtures: MUST FIRE a deny writes exactly 1 row with verdict=deny. CLEAN TWIN a pass writes a row and still prints nothing. MUST NOT FIRE a Bash payload writes no row. CLEAN TWIN an unwritable log path leaves the verdict and output byte-identical.

CRITIQUE: Implementation traps:
- recall_append.append_line takes BYTES and RAISES on failure; its docstring says 'Raises on failure. Never retries'. A lower-effort implementer will pass a str or let the exception escape and turn a log failure into a lost verdict. Use recall_append.append_rows inside try/except.
- Log skip rows too, not only pass and deny. Otherwise 'the gate stopped being called' and 'no Agent calls happened' are still the same bytes, which is the scenario this finding exists for.
- Never log prompt text; prompt_len and kc_paths are enough.
- The self-test must set RECALL_BRIEF_GATE_LOG before any subprocess runs. Its run() helper spawns the real script with the inherited env, so an unredirected case writes the live log.

Fixture requirements:
- A redirected log gets exactly one row per call, across deny, pass and skip.
- An unwritable path leaves stdout byte-identical.

Report: the 'denied then passed within 10 min' join must key on sid AND subagent_type. Parallel spawns in one sid otherwise pair the wrong calls.

### brief-gate-accepts-unresolvable [issue/both/low] VERDICT=CONFIRMED
The brief gate passes citations that resolve to nothing ('memory: none', made-up paths)

CORRECTED: The gate's evidence test is lexical. A memory 'slug' of three or more letters ('none', 'zzz'), any path-shaped *.md string, and any quoted search term pass whether or not they resolve. The live cost is zero so far: 102 of 102 cited paths resolved since 2026-09-19T18:55Z. 'memory: n/a' is denied, not passed, as the finding implied.

FIX: 1. In verdict(), after EVIDENCE_RE passes, extract the named items: store paths, memory:<slug> and [ [slug] ].
2. Resolve them the way ops/store_citation.py home_store() does: skills root; memory dirs for C--Codex-ThriftyCrew and C--Codex; paths relative to the payload cwd and its repo root.
3. Pass if at least one resolves, or if the section matches the honest negative (a 'searched "..."' phrase plus nothing|none applicable, the NOTHING_RE shape in store_citation.py).
4. Deny otherwise, with reason 'none of the named sources exist: <list>'.
5. Fail open if resolution raises. The row from finding brief-gate-logs-nothing records kc_resolved.
6. Fixtures: MUST FIRE 'memory: none' is denied. MUST FIRE a nonexistent store path alone is denied. CLEAN TWIN data-quality-craft/applies-here.md passes. CLEAN TWIN 'searched "aioli", nothing applicable' passes. CLEAN TWIN a real path beside a fake one passes, because one resolves (the case at the bar).

CRITIQUE: THE MAIN RISK IS FALSE DENIALS.
- Resolve memory slugs against BOTH C--Codex-ThriftyCrew/memory and C--Codex/memory, whatever the payload cwd. A lower-effort implementer will reuse recall_index.resolve_roots(cwd), which returns NO memory dir for a worktree cwd (0 of 165 worktree project dirs hold memory), and will then deny every valid memory citation from a worktree session.
- Resolve repo paths against the repo root of cwd AND C:\Codex\ThriftyCrew. The .claude/rules/*.md, design/*.md and docs/*.md files are legitimate knowledge and must pass when they exist. The finding lists docs/RUNTIME-MAP.md as a weak case, but it is estate machinery, which is goal 1.
- Keep fail-open on any resolution exception.

FIXTURES:
- The case at the bar is one real path beside one fake path, and it passes.
- The step past it is two fake paths, and it denies.
- A worktree-cwd payload citing a real memory passes. This is the regression twin for the resolve_roots trap.

### store-step-code-only-and-sparse [gap/analysis/medium] VERDICT=CONFIRMED
The store-first step is worded for code only, and the analysis agents and the analysis scheduled task lack it

CORRECTED: The store-first block is one identical 1,432-char text in 6 of 13 agent definitions, worded for code and plans. It is absent from 7 agents, including the verdict agents recipe-batch-auditor, recipe-dedup-selector and recipe-source-qa. It is in 1 of the 6 enabled or paused scheduled tasks. Two of the uncovered agents (recipe-dedup-selector, recipe-writer) hold no Bash and cannot run search.py at all.

FIX: 1. Write one canonical file, ops/prompt-backup/store-step.md, with two variants. CODE: the current text. ANALYSIS: 'Before you diagnose, measure, compare, audit or return a verdict, search: <search.py line>. Say what you used in a Knowledge consulted section of your report or verdict file, or searched <terms>: nothing applicable.'
2. Paste the ANALYSIS variant into recipe-batch-auditor, recipe-dedup-selector, recipe-source-qa and recipe-hunter-pricer, and the CODE variant into recipe-batch-auditor as well, since it holds Write. Paste the ANALYSIS variant into the triage-reviewer, commodity-registrar and post-publish-reviewer blocks beside the existing one.
3. Decide extractor, sourcer and writer explicitly: they transcribe, source and write prose. Either mark them exempt with a reason in the audit's allowlist, or give them the analysis step.
4. Scheduled tasks: add the ANALYSIS variant to scheduled-tasks/verify-board-sample/SKILL.md and store-usage-weekly/SKILL.md. Leave the aa-fare-watch and resume tasks alone.
5. Run audit-prompt-backup -SyncScopes and -SyncMirror from main so the user-scope and mirror copies follow.
6. Add RULE 3 to ops/audit-agent-tools.ps1: every .claude/agents/*.md either carries a variant byte-identical to the canonical text (compare with [string]::Equals Ordinal after LF-normalising) or is on a named allowlist with a reason. Agents in its verdict-only list must carry the ANALYSIS variant.
7. Extend audit-prompt-backup coverage to scheduled-task SKILL.md files the same way.
8. Fixtures: MUST FIRE an agent with no block. MUST FIRE a block with one word changed (drift). MUST FIRE a verdict-only agent with only the CODE variant. CLEAN TWIN the canonical block passes. MUST NOT FIRE an allowlisted agent. Exit codes follow guard-contract (0/2/3) with an AUDIT-AGENT-TOOLS-COMPLETE marker.

CRITIQUE: Most likely lower-effort errors:
(1) Pasting 'run search.py' into recipe-dedup-selector and recipe-writer, whose tools are Read, Grep and Glob. They cannot execute it. For those two, either the dispatcher does the search and pastes excerpts (hunt_dispatch builds the brief in Python, so a per-stage curated Knowledge consulted block there reaches every headless decider), or the definition carries a static excerpt.
(2) Giving recipe-batch-auditor the CODE variant. Its Write is a verdict file, not code.
(3) Putting the canonical text in ops/prompt-backup/. That directory is the mirror of agents/ and scheduled-tasks/ that audit-prompt-backup.ps1 manages. Put it beside audit-agent-tools.ps1 instead, e.g. ops/agent-blocks/store-step.md.
(4) Ignoring cost. Hunt deciders run at throughput targets, and an extra search on every decider call is tokens and wall clock; pre-computed excerpts per stage are cheaper and deterministic.
(5) Running -SyncScopes by hand from a worktree. Land on main and let the daily sync carry it.

The new audit rule must be green on day one: land it in the SAME commit as the blocks.

Fixtures:
- MUST FIRE: one word changed.
- MUST FIRE: a verdict agent with only the CODE variant.
- MUST FIRE: an agent that lacks Bash but whose block says 'run search.py'.
- CLEAN TWIN: the canonical block passes.

The value of adding it to store-usage-weekly (a 12-line report runner) is low. verify-board-sample already carries the mechanism for its founding case.

### triage-plan-knowledge-unchecked [gap/analysis/medium] VERDICT=OVERSTATED
The triage handoff gate does not check the plan's knowledge_consulted field; 4 of 23 recent plans have none

CORRECTED: 3 of 23 non-routing triage plans dated 2026-09-19..22 record nothing about what was consulted (plan-2026-09-20-4, -5, -6). A fourth, plan-2026-09-22-2, carries no field but links an RCA document that has the section. validate-triage-plan.ps1 checks neither, and store_citation.py covers only design/PLAN-* and MEASURE-*.

FIX: 1. In grocery/validate-triage-plan.ps1, add a rule for plans whose file date is >= 2026-09-23. Using the cutoff means zero reds on the day it lands.
2. The rule: the plan carries a knowledge_consulted array with at least 1 entry. Each entry names a store path that resolves, a memory:<slug>, or a searched-nothing phrase.
3. Read presence with $o.PSObject.Properties['knowledge_consulted'] per the workspace rule. Assign before wrapping: $k = $o.knowledge_consulted; @($k).
4. Refuse with the validator's existing exit code and verdict-line vocabulary. Name the item and say how to comply.
5. Fixtures in its -SelfTest: MUST FIRE a plan dated 2026-09-23 with no field. MUST FIRE an empty array. MUST FIRE a field whose only entry is prose. CLEAN TWIN a frozen copy of plan-2026-09-22.json passes. MUST NOT FIRE a plan dated 2026-09-20 with no field (the cutoff). The case at the bar is dated exactly 2026-09-23, with a step past at 2026-09-22.
6. Also add the field to the plan template the triage-reviewer copies from, if one exists.

CRITIQUE: Lower-effort traps:
- Globbing plan-*.json catches plan-*.routing.json (3 of 26 files in the window) and fails them. Exclude routing artifacts explicitly.
- A holistic-rca plan whose rca_document carries the section must pass: resolve the linked doc and apply the same heading test.
- Take the cutoff date from the file name, including the -N suffix shapes, not from 'generated', which is free text in some plans.
- PowerShell 5.1: read presence with PSObject.Properties['knowledge_consulted'], and assign before wrapping.

Fixtures:
- The case at the bar is dated exactly 2026-09-23 with no field, and it is refused.
- The step past is 2026-09-22, and it passes.
- A routing.json is MUST NOT FIRE.
- The rca_document shape is CLEAN TWIN.

### agent-hook-pollutes-parent-state [issue/general/low] VERDICT=OVERSTATED
recall-agent-hook records a child's pointers as offers to the parent

CORRECTED: recall-agent-hook records a child's pointers into the parent's state['offered'], and it is the ONLY production writer of that field.

No harm to dedup: nothing in production reads state['offered'] for dedup.

The real consequences:
(a) The Stop consulted gate's rung 1 counts pointers the parent never saw. All 12 of its refusals since 2026-09-10 did so, and 6 of the 12 had nothing else behind them.
(b) The Session roll-up's bytes, injections and sections figures are 100% child-pointer data.

The gate's intended input, UserPromptSubmit offers, is never recorded. See missed finding consulted-gate-never-sees-prompt-offers.

FIX: 1. In recall-agent-hook.py, stop calling recall_core.record() for the child's hits.
2. Instead: state['child_offered'][hit_key] = t, and increment state['child_bytes'] and state['child_injections'].
3. In recall-stop-hook.roll_up, add the child_bytes, child_injections and child_sections fields, and leave bytes, injections and sections as the parent's own context.
4. Update the agent-hook self-test case 'an enrichment records its bytes, count and sections in the state' to assert on the child_* fields.
5. New fixtures: MUST NOT FIRE after an enrichment, recall-consulted-hook.offered_this_turn(parent_state, t0) == 0. MUST NOT FIRE recall_core.filter_new(hits, parent_state) still returns those hits. CLEAN TWIN child_bytes > 0.
6. Keep failing open.

CRITIQUE: THE MAIN TRAP: implemented as written ('stop calling record()'), this change leaves the consulted gate's rung 1 with ZERO production input. It would go from 12 refusals in 13 days to none, silently, and its self-test would stay green, because the fixtures write state['offered'] directly. It must land together with recall-hook.py recording its own offers, or explicitly say it retires rung 1.

The new keys child_offered, child_bytes and child_injections must be added to load_state's allow-list, or every other hook's save drops them. recall_core's self-test that scans sibling hooks for state writes should catch this. Run it.

The roll-up change renames what 'bytes' means. Say so in recall-brain and in any report reading recall-session-log, or the budget line will read a sudden drop to 0 as an improvement.

Fixtures:
- MUST NOT FIRE: after an enrichment, offered_this_turn(parent) == 0.
- CLEAN TWIN (end to end): after a recall-hook.py offer with RECALL_STATE_DIR redirected, offered_this_turn(parent) > 0 and decide() refuses a footerless reply.
- MUST FIRE: child_bytes > 0.

### pointer-use-unmeasured [gap/both/medium] VERDICT=CONFIRMED
Nothing measures whether helpers use the agent-hook pointers or the chosen section, and 21 of 193 pointers repeat the section

CORRECTED: No per-pointer record exists for agent-hook offers. Rebuilt from transcripts:
- Since 2026-09-08, children opened 148 of 1,274 pointers (11.6%).
- Since the gate, children opened 14 of 193 pointers (7.3%), against 31 of 102 (30%) of the paths the orchestrator chose for the section.
- 21 of 193 pointers repeat a chosen path.

An open is not a use, and the pre/post split is unqualified: different task mix, one split, no per-case rows.

FIX: 1. In recall-agent-hook.main(), after building the block, append one row per pointer to ~/.claude/recall-agent-offer-log.jsonl (env RECALL_AGENT_OFFER_LOG) via recall_append.append_line. Fields: t, sid, parent_agent, tool_use_id (payload key, if present), subagent_type, path, heading, score, in_kc (bool: the brief's Knowledge consulted section already names that path).
2. Before rendering, drop any hit whose path the section already names. Keep the fallback that sends nothing when every hit is a duplicate.
3. New read-only report, skills/recall-agent-offer-report.py --days N. It joins pointer rows to recall-log 'open' rows on sid, agent != parent_agent, same path, t between offer t and offer t + 6 h. Label it as an approximation when several children share one parent. Print 'read X of Y pointers (Z children)', the read rate for in_kc false versus true, and a list of the never-read paths. Write the acceptance bar before the first run: keep the hook if its non-duplicate pointers are read at a rate of at least 10%, with the denominator printed.
4. Fixtures: MUST FIRE an enrichment writes 1 row per pointer to the redirected log. CLEAN TWIN a hit already in the section is not rendered and is logged with in_kc true. MUST NOT FIRE a short prompt writes no row. The report's --selftest runs over a frozen 6-row fixture and asserts the join count.

CRITIQUE: PreToolUse:Agent cannot know the child's agent_id. The child does not exist yet, so a sid-plus-time join to the child's open rows is ambiguous whenever siblings run in parallel, which is the normal triage shape.

The precise join is the one the mapper already used: find the child transcript whose opening text contains the injected block, and read its Read and shell calls. Build the report on that, not on the recall-log join.

Do NOT ship 'drop hits already in the section' in the same change that starts logging. That changes the arm at the moment measurement begins and repeats the confound the finding complains about. Log for a stated window first, then change, with the bar written before either.

State the bar in the metric's own units with its denominator. Also consider the stronger comparison the data already offers: hook pointers against chosen paths.

### search-rows-lack-agent-id [issue/general/low] VERDICT=CONFIRMED
Search rows carry only the parent sid, so a helper's own search cannot be told from its parent's or a sibling's

CORRECTED: A search row carries only the parent's session id: 96 of 96 search rows in this workflow run have no agent. A helper's commit is therefore 'backed' by any search anywhere in its session tree within 24 h, and the weekly backed rate is an upper bound.

FIX: 1. In skills/recall-log-open.py (PostToolUse on Bash|PowerShell, where the payload does carry agent_id), when the command contains 'knowledge-search' and 'search.py', append a 'search-by' row to recall-log.jsonl: t, sid, agent, and the query argv parsed from the command.
2. Do not change search.py's own row.
3. In store-usage-report.py, when a commit row carries an agent id (store_citation's decision log may need an agent field, from CLAUDE_CODE_SESSION_ID alone it cannot), count as backed only if a search-by row has the same sid and agent. Otherwise report 'backed at session level only' as its own number.
4. Fixtures: MUST FIRE a Bash payload with agent_id and a search.py command writes 1 row carrying that agent. MUST NOT FIRE a non-search command writes nothing. CLEAN TWIN a Read open row is unchanged.

CRITIQUE: The commit side is the hard half, and the sketch leaves it open. store_citation runs inside git's commit-msg hook, whose environment has only CLAUDE_CODE_SESSION_ID. It can never learn the agent.

The workable route is a PostToolUse row on the Bash or PowerShell call whose command contains 'git commit'. That payload carries agent_id. The commit hash is in tool_response, as the '[branch abc1234]' line. Join the citation row to it by sid plus time plus subject.

Lower-effort traps:
- A naive shlex.split breaks on PowerShell quoting when parsing the search argv. Use a tolerant split and keep the raw command.
- A 'git commit' run through ops\push-main.ps1 or a script is not a direct Bash commit, so the join must allow no match and report it as a separate count.

A cheap interim signal: CLAUDE_CODE_CHILD_SESSION=1 is set in a workflow agent's environment, so search.py could log child:true. Whether Agent-tool subagents set it was not measured; probe that first.

### approvals-runner-no-store-step [gap/code/low] VERDICT=CONFIRMED
The headless approvals runner builds code with no store-first line in its brief

CORRECTED: The headless approvals runner starts coding runs whose brief never mentions the store or the Store: line. It relies on CLAUDE.md, which states the Store: rule, and on UserPromptSubmit recall. Whether those runs searched is not measured: its 15 runs on 2026-09-12 predate search logging.

FIX: 1. Add to build_prompt's head, after 'Verify before you claim': '- Before you design or change code, search the store: C:\\Codex\\Python312\\python.exe %USERPROFILE%\\.claude\\skills\\knowledge-search\\search.py "<terms>". Every code commit carries a Store: line (ops/store_citation.py): the store files you used, or Store: searched <terms>, nothing applicable.'
2. Add a fixture to approvals_runner --selftest: MUST FIRE build_prompt([...]) contains 'knowledge-search' and 'Store:'. CLEAN TWIN the existing result-line contract text is unchanged.

CRITIQUE: Traps:
- The self-test asserts that build_prompt contains 'knowledge-search'. The literal also sits in the same file, so build the needle by concatenation per the estate rule, and assert it on the function's RETURN value.
- The run works in a worktree, so its own recall has no memory corpus. Name the memory directory explicitly in the line, not just the skills path.
- Keep %USERPROFILE% in a prompt that a PowerShell or Bash child will expand. A hard-coded C:\Users\Owner path is fine on this box, but say which you chose.

Fixture: CLEAN TWIN, the result-line contract text is byte-identical before and after.

### agent-tier-never-points-at-estate [gap/code/medium] VERDICT=CONFIRMED
Neither agent-tier hook points a coding helper at existing estate machinery (libs, gates, helpers)

CORRECTED: Neither agent-tier hook can point a helper at existing estate libraries, gates or helpers. The recall corpus is skills-only, and no estate index exists. The proposed signal, a brief against estate script headers, is untested, not refused.

FIX: Defer the index itself to the estate-machinery plan. For this tier:
1. Once an estate header index exists (BM25 over the first comment block of lib/*.ps1, ops/*.ps1, grocery/*-lib.ps1, meal-prep/lib/*.ps1), recall-agent-hook appends a second capped block, at most 3 lines and 400 B, headed 'existing estate machinery that may already do this'.
2. Gate it on a bar written before the run: over 20 past briefs whose landed commit dot-sourced or called an existing lib function (mined from git log -S), hit@3 >= 12 of 20. Record one row per case per arm.
3. Add an optional 'Estate consulted:' line to the brief gate's HOW text, never required.
4. Fixtures: MUST FIRE a brief mentioning 'atomic replace' surfaces lib/atomic-write.ps1. MUST NOT FIRE a brief about recipe prose surfaces no lib line.

CRITIQUE: The right call is to defer to the estate-machinery plan and build it once.

Traps for whoever builds it:
- The 20-case bar must be mined BEFORE the index exists, with case sources recorded. It must include negative cases: briefs whose commit wrote genuinely new machinery. Otherwise it cannot measure over-firing.
- Keep the estate block's byte cap separate from the 1,200-byte skills cap, or the two will crowd each other out silently.

The fixture 'atomic replace surfaces lib/atomic-write.ps1' must come from a frozen index. Against the live one it goes red whenever a header changes.

### subagent-return-unchecked [gap/analysis/low] VERDICT=CONFIRMED
A helper's returned analysis is never checked for what it consulted (SubagentStop runs only the roll-up)

CORRECTED: Nothing reads a helper's final message for what it consulted. The SubagentStop payload's fields are unmeasured.

FIX: 1. STEP 0: confirm the SubagentStop payload fields with recall-probe.py, one run.
2. Then, in recall-stop-hook.py's SubagentStop path, add to the roll-up row: consulted_line (bool: the last assistant text matches (?im)^(##\\s*)?knowledge consulted|^consulted:) and agent_type.
3. Never return exit 2.
4. store-usage-report prints 'helpers whose final message names what they consulted: X of Y' with the denominator.
5. Fixtures: MUST FIRE a fixture transcript ending with a Knowledge consulted section gives consulted_line true. CLEAN TWIN one without gives false. MUST NOT FIRE the hook's exit code is 0 in both.

CRITIQUE: Traps:
- recall-stop-hook.py serves Stop, SubagentStop and SessionStart(compact) from one file. A lower-effort edit that raises inside the new branch costs the roll-up for all three. Fence it.
- If last_assistant_message is absent on SubagentStop, the fallback is the child's transcript. Find it by agent_id under subagents/, not through transcript_path, which may name the parent. That is an assumption to probe in step 0.
- It must never exit 2.

Fixtures:
- CLEAN TWIN: the roll-up row still carries the existing fields unchanged.
- MUST FIRE and CLEAN TWIN over frozen transcript tails.

### agent-hook-tautological-case [issue/general/low] VERDICT=CONFIRMED
One recall-agent-hook self-test case cannot fail

CORRECTED: One of the 21 agent-hook self-test cases cannot fail. It is also vacuous without the 'or True': a one-character query can never clear the score floor, so build_block returns '' through the normal no-hits path, not through a failure.

FIX: 1. Replace the case with a real failure: temporarily set recall_index.ready to a function that raises, and assert build_block('Write a PreToolUse hook that reads the exit code', r'C:\\Codex\\ThriftyCrew') == ('', []).
2. Restore it in finally.
3. Label it CLEAN TWIN (fail-open still works).
4. Mutation check: delete the try/except in build_block. The case must go red.

CRITIQUE: Removing 'or True' alone leaves an always-green case. Force a real failure, and pick the target so the case can go red:
- build_block imports recall_index inside the function, so first import recall_index into sys.modules, then patch its ready or search attribute to raise, and restore in finally.
- Patching recall_index.ready alone exercises the second try block. Patching the import is a different path.
- Use a real prompt that DOES produce hits when unpatched, and assert that in a sibling CLEAN TWIN, or the case still proves nothing.

The mutation check 'delete the try/except' makes the case raise, not go red. Wrap the call so an exception counts as a named failure, per the estate rule that a suite must not die mid-run.

### brief-gate-works-on-agent-path [strength/both/low] VERDICT=CONFIRMED
STRENGTH: the brief gate works on the Agent-tool path, including scheduled runs, and refused briefs come back compliant

CORRECTED: On the Agent-tool path the gate took briefs from 2 of 1,204 carrying a section to 54 of 54, with 2 refusals in 50 top-level calls. The mapper's 57 includes calls I did not re-count.

FIX: Keep it. Reuse EVIDENCE_RE and the honest-negative wording in the Workflow and spawn_task gates. Do not reuse HEAD_RE for JS scripts (see workflow-agents-bypass-agent-tier).

CRITIQUE: Agree: keep it, and reuse EVIDENCE_RE and the honest-negative wording. Do not reuse HEAD_RE on JS scripts; verified, it denies the one compliant script.

### tool-tier-reaches-workflow-agents [strength/both/low] VERDICT=CONFIRMED
STRENGTH: the tool-tier hooks and the standing context do reach workflow agents

CORRECTED: Workflow agents receive the tool-tier hooks (reflex, intent, open-logging) and carry agent_id on their PreToolUse payloads. UserPromptSubmit recall, the agent hook and the brief gate do not reach them.

FIX: Build layer B on this channel. Record the workflow-agent row (context, Skill tool, tool-tier hooks yes; agent hook, brief gate, UserPromptSubmit no) in what-actually-reaches-a-spawned-agent and in automatic-recall.md section 2.

CRITIQUE: Record the row in what-actually-reaches-a-spawned-agent, as proposed. One caution for layer B: the channel is proven, but the intent hook sharing it uses a state file that loses writes. See missed finding recall-state-lost-writes.

### agent-scope-sync-works [strength/general/low] VERDICT=CONFIRMED
STRENGTH: the user-scope and project-scope agent prompts do not drift

CORRECTED: The user-scope and project-scope copies of the 9 shared agent prompts are byte-identical. The 4 project-only agents are project-only by design.

FIX: Keep it. Land agent-prompt edits in the project scope on main and let -SyncScopes carry them.

CRITIQUE: None. Land agent edits on main in project scope and let the daily sync carry them. Do not run -SyncScopes from a worktree.

## Missed by mapper
- [high] consulted-gate-never-sees-prompt-offers: the Stop consulted gate (the only 'guarantee' tier, and goal 2's answer-time check) never sees the UserPromptSubmit offers it was built for; its only input is the agent-hook's child pointers: CODE:
- recall-consulted-hook.decide() counts offered_this_turn(state), which is the timestamps in state['offered'].
- recall_core.record is the only function that writes that field. grep over skills/*.py finds exactly one production caller, recall-agent-hook.py:208.
- git log -S shows recall-hook.py never wrote state['offered']. Commit 8d6f49a (2026-09-07) says record() had no caller before the agent-hook took it up; the consulted gate shipped on 2026-09-08.

LIVE DATA:
- This session's parent state shows UserPromptSubmit=1 and offered=0 after UPS offered 4 sections.
- v_consulted.py over recall-consulted-log joined to recall-log offer rows by (sid, turn), window 2026-09-10T11:58Z..2026-09-23T00:07Z: 1,980 top-level Stop rows. 1,322 of those turns had at least 1 UPS offer, and the gate logged offered>0 on 41 of the 1,322. 139 of the 180 offered>0 rows had no UPS offer that turn.
- v_consulted2.py: 12 of 12 consulted-rung refusals carry agent-block-sized counts (5, 6, 8, 10, 13). 6 of the 12 were in turns where UPS offered nothing, so the parent was refused for pointers only its child received.

WHY NOTHING NOTICED:
- recall-brain's 'prove' line prints 'X of Y turns carried a footer', which counts turns where nothing was offered.
- The gate's self-test injects state['offered'] directly, so it is green. This is the green-fixture-is-not-production-coverage shape.

Searched the store for 'consulted gate offered this turn / footer rate': no record of this.

FIX DIRECTION: recall-hook.py records its picked offers into the parent's state via record(), re-loading state immediately before. The agent-hook moves to child_* keys, added to the load_state allow-list. Before enforcing, run one week in shadow, logging would_refuse, and get a Brad ruling: going live makes the gate judge about 1,322 of 1,980 turns instead of 41.

END-TO-END FIXTURE: drive recall-hook.py with RECALL_STATE_DIR redirected, then run consulted decide() on a footerless reply. It must refuse. MUST NOT FIRE: a turn with only an agent-hook enrichment.
- [medium] recall-state-lost-writes: recall_core.save_state silently loses writes under concurrent hooks, and leaks a tmp file each time: FAILED REPLACES:
- ~/.claude/recall-sessions holds 7,330 leftover '<key>.json.<pid>.tmp' files (29 MB), dated 2026-09-08..2026-09-22, 573 of them on 09-22. There are 145 live state files. Command: v_state.py; ls -la --time-style=+%Y-%m-%d *.tmp | awk | uniq -c.
- save_state writes a tmp and calls os.replace. On an exception it returns False without removing the tmp, and sweep_stale deletes only *.json.
- The cause, probed in scratch (v_replace_probe.py): os.replace onto a file another process holds open for READ fails with PermissionError [WinError 5] and leaves the tmp behind. It succeeds once the reader closes. This is the same sharing-mode failure the estate already fixed for PowerShell in lib/atomic-write.ps1.

LOST UPDATES: reflex-hook and intent-hook both load-modify-save the same key on the same PreToolUse event, concurrently.
- v_lostbeats.py over the latest recall-session-log roll-up per key, 2026-09-07..2026-09-23: 581 of 738 keys have PreToolUse:<T> < PostToolUse:<T> for some tool. That is impossible if every heartbeat landed, because PostToolUse never fires on a failed call.
- 3,227 of 9,119 PostToolUse beats have no matching PreToolUse beat. That is a lower bound on lost Pre writes.

WHAT RIDES ON THE STATE FILE: heartbeat outage detection (build 8), the session-scoped reflex promotions ('promoted'), the intent-hook dedup, the consulted gate's brakes 2 and 3 and its per-turn marker, and the agent-hook records. Any new key the plan adds inherits the loss: layer B's 'primed', the agent-hook's child_* keys.

Searched the store for 'recall-sessions tmp', 'save_state PermissionError' and 'hooks run in parallel': none.

FIX DIRECTION:
- Retry os.replace on PermissionError with a short bounded backoff, and remove the tmp on final failure. Sweep *.tmp older than an hour.
- Serialise load-modify-save per key with an O_EXCL lock file or msvcrt.locking, or move counters to append-only rows.

FIXTURES: MUST FIRE, a naive replace fails under a held reader (this proves the harness). CLEAN TWIN, the retrying save lands. N=4 writers × 50 heartbeats released on a barrier INSIDE each writer: the final count is 200 with the lock, and red with the lock neutered.
- [low] recall-core-dead-budget-and-stale-docstring: the session injection budget and filter_new are dead code, and the intent hook's docstring describes a dedup it does not use: - grep over skills/*.py: budget_state, MAX_SESSION_BYTES (20 KB) and MAX_SESSION_SECTIONS (60) are referenced only inside recall_core.py and its self-test. filter_new is called only by that self-test.
- recall-intent-hook.py:29 says 'recall_core.filter_new already owns that rule and already backs the byte budget', but the code dedups on intent_seen and intent_asked (lines 111-151), and nothing enforces any byte budget.
- The plan's 'injected bytes per session against ~5 KB' is therefore unenforced, and the roll-up that reports bytes counts only agent-hook bytes (0 of 735 rows since t>=1789800000 show bytes without Agent beats).

This matters because a reviewer, like this subsystem's mapper, reads the docstring and infers a dedup interaction that does not exist.

FIX DIRECTION: either wire budget_state into recall-hook.py and recall-intent-hook.py with a stated bar, or delete it and correct the docstring. Do not leave a named budget that nothing enforces.

## Open questions
- Does PreToolUse fire for tool_name 'Workflow', and does its payload carry tool_input.script? Not measured. Layer A of workflow-agents-bypass-agent-tier depends on it, and step 0 settles it with recall-probe.py.
- What agent_type does a workflow agent's tool-call payload carry? Not measured. meta.json says workflow-subagent, but 147 workflow transcripts recorded general-purpose, and named recipe agents appear too. That is why layer B detects a workflow agent by transcript location rather than by agent_type.
- Do workflow agents fire SubagentStop, and does its payload carry last_assistant_message? Not measured: none of today's 9 had finished when this was read. An agent id a2bc6113267a09321 fired SubagentStop in this session with no transcript anywhere under ~/.claude/projects and no reflex or open rows. Its origin was not identified.
- All six .claude/rules files, which declare 'globs:' frontmatter with alwaysApply false, were present in this agent's context before it touched any file. Is 'globs' being ignored, so every rules file loads everywhere? That costs context on every helper and makes the path scoping decorative. This is worth a check by the prompt-tier or record-tier reviewer.
- Explore agents are exempt from the brief gate as lookup-only. Is an Explore agent that answers a 'why' question analysis work that should carry a brief section? 0 Explore spawns since the gate landed, so no live cost was measured.
- Should the agent-hook be kept once a chosen section is mandatory? The read rate fell from 134 of 1,081 (12.4%) before the gate to 14 of 193 (7.3%) after, over one pre/post split with a different task mix. That is unqualified until pointer-use-unmeasured records per-pointer rows.
- The 4 project-only agents (commodity-registrar, recipe-hunter-extractor, recipe-hunter-pricer, recipe-source-qa) cannot be spawned from a session whose cwd is C:\Codex, which is where the scheduled grocery-alert-triage runs. Is that intended? audit-prompt-backup line 298 makes it deliberate but gives no reason for the registrar.
- Side effects of this review on the live logs. This agent's own Bash calls fired the live hooks, and the harness appended rows under session 134f2f6e-7fb9-4057-a890-b2c27ba9dfc0 / agent a9f7dfe545941d314, including 2 reflex blocks. There was one knowledge-search run, which appended 1 search row. The state-contamination probe used session_id review-probe-2026-09-22 with RECALL_STATE_DIR, RECALL_LOG and RECALL_SESSION_LOG redirected to scratch. Nothing else was driven.
