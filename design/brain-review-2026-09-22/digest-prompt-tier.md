# prompt-tier

recall-hook.py runs on UserPromptSubmit only, so only in MAIN sessions: 835 of 835 invocations in the last 7 days had no agent_id. Each call writes a turn id and a heartbeat first. It then strips named harness blocks (system-reminder, task-notification, command-*, local-command-stdout) and every absolute Windows path, and returns early when fewer than 3 tokens are left. That was 558 of 835 calls, p50 29 ms, mostly task-notifications.
Next it routes exact hyphenated names: subject dirs, side files, and memory slugs for the project key of os.getcwd(). After that it retrieves from the SKILLS corpus only. The semantic leg calls the sidecar's /recall-search over recall-embed-index.npz (2,162 skills vectors, cosine floor 0.548). When that is down it falls back to recall_index BM25 over ["skills"] at 8.5, with a breaker that opens after 2 failures for 60 s. Memory is reached only by exact slug. Rules and estate code are never retrieved.
It emits up to 4 `path :: heading` pointers inside a fixed <recall> block plus a `Consulted:` footer instruction. Nothing is procedural, and it has no notion of task kind (recall_core.query_for always returns kind "prompt").
It logs offer, nearmiss and timing rows to recall-log.jsonl, plus a leg row only for turns that offered. It never calls recall_core.record, so the Stop consulted gate (which counts state["offered"]) cannot see its offers.
A memory semantic index (recall-embed-memory-C--Codex-ThriftyCrew.npz) is built but read by nothing (ruled NOT SHIPPED 2026-09-12).
recall-correction-hook scans the RAW prompt for correction cues and does not strip harness text. recall-stop-hook re-primes after compaction with only the last prompt (600 chars), and its --health counts beats all-time with no split by origin.
Last 7 days: 277 retrievals, 261 of them offered (94.2%), 977 offers. Of those offers, 27 were opened in the same session within 15 min (2.8%), 548 came from scheduled-task envelopes (0 opened), and 0 were memory. The tier cannot reach subagent or workflow contexts, which is where 533 of 647 (82.4%) Edit/Write calls happened.

## Measurements
- prompt-hook invocations (timing rows) by session origin: 835 total, rc 0 on 835 of 835; main-TC 553, cowork scratch 126, C--Codex 123, worktree 29, scratchpad-cwd 4; carrying an agent_id 0 of 835  [2026-09-15 18:45 to 2026-09-22 18:45 local]
- what each invocation did: early return (nothing to search) 558 of 835 (66.8%, p50 29 ms); retrieval ran 277 of 835 (33.2%); of those 261 offered (94.2%), 16 quiet  [same 7 days]
- leg share (question b): of 277 retrieving turns: semantic 191 (69.0%), lexical 86 (31.0%); of 261 offering turns: semantic 177 (67.8%), lexical 84; lexical present every day 09-17..09-22  [same 7 days]
- prompt-hook latency by path: offered/semantic p50 213 ms p90 316 ms (n=177); offered/lexical p50 660 ms p90 1,884 ms (n=84); quiet semantic p50 163 ms (n=14)  [same 7 days]
- offer-to-open (question c), four join rules, 15-minute window: 977 prompt-hook offers: opened by any session 35 (3.6%), same session 27 (2.8%), same session main agent only 14 (1.4%), same turn 11 (1.1%); offering turns with at least one open 19 of 261 (7.3%)  [same 7 days]
- offer-to-open all time, and deliberate search follow rate: offers opened within 15 min: 274 of 8,809 (3%); knowledge-search searches followed by an open of a returned path, same session: 52 of 154 (34%)  [all time to 2026-09-22 18:45]
- offers driven by a scheduled-task envelope: 548 of 977 offers (56.1%) over 137 turns, opened 0 of 548; the other 429 offers opened same-session 27 (6.3%). Top paths course/orchestration.md 128, claude-code-automation/MAP.md 91, mcp-craft/intelligence-budget.md 90, agent-workflow-craft/agent-architecture.md 87  [same 7 days]
- strict harness tokens left in offer cues after the 2026-09-12 strip: 0 of 977 (was 73.7% of 7,421 before the strip; the prediction written then was under 5%)  [same 7 days]
- memory offers from the prompt hook (question a): 0 of 977 in 7 days (worktree 0 of 65, main-TC 0 of 279); 4 of 8,809 all time, the last on 2026-09-12  [7 days, and all time]
- resolve_roots per cwd (question a): worktree affectionate-bun-6716c6 -> skills + rules:C--Codex-ThriftyCrew-.claude-worktrees-affectionate-bun-6716c6 only (no memory); C:\Codex -> skills + memory:C--Codex (209 md); C:\Codex\Fantasy -> skills + memory:C--Codex-Fantasy (0 md); C:\Codex\ThriftyCrew -> skills + memory (187 md) + rules (6 md); C:\Codex\ThriftyCrew\grocery -> skills only. Worktree keys that have a memory dir: 0 of 97; worktrees with .claude/rules: 90 of 97  [state at 2026-09-22 18:45]
- which MEMORY.md the HARNESS loads in a worktree session: 146 of 188 worktree top-level transcripts record loading C:\Users\Owner\.claude\projects\C--Codex-ThriftyCrew\memory\MEMORY.md; 0 name a worktree-keyed memory dir; 42 name none. Main-TC subagent transcripts: 181 of the 300 sampled name the same main MEMORY.md  [all worktree transcripts on disk]
- project_key against Claude Code's own project-dir encoding: project_key matches 32 of 204 project dirs; replacing every non-alphanumeric character with '-' matches 203 of 204 (the 204th is a session whose first recorded cwd was a different worktree)  [all project dirs on disk]
- main-TC activity with cwd off the repo root: 10,351 of 24,604 transcript rows (42.1%): 7,076 in a worktree, 3,275 in a subdir; user-prompt rows off-root 260 of 545. Open rows in recall-log carry per-worktree tags such as rules:C--Codex-ThriftyCrew-.claude-worktrees-<name>, so hooks see the worktree cwd  [same 7 days]
- Stop consulted gate's view of prompt-hook offers: 233 of 261 offering turns joined to a consulted-log row: the gate logged 'nothing was offered this turn' on 194, saw offered>0 on 25 (from the agent hook); a footer was present on 170, and 30 named something. Consulted-log rows from subagents: 0 of 699  [same 7 days]
- main sessions that never beat UserPromptSubmit (question e): 43 of 450: Desktop worktree sessions whose first message is the worktree system-reminder 23 of 146; headless sdk-cli approvals runs 10 of 12 (all 2026-09-12; these beat PreToolUse up to 58 and Stop); Cowork scratch 7 of 198; C--Codex scheduled task 1 of 11; main-TC desktop 1 of 20; worktree plain 1 of 12  [all rows in recall-session-log.jsonl (the health step's own window)]
- code-writing calls in subagent contexts, where UserPromptSubmit never fires: Edit+Write 533 of 647 (82.4%); PowerShell 1,874 of 2,270; Bash 728 of 1,001; UserPromptSubmit 0 of 330; 670 subagent contexts against 82 Agent-tool calls from main. Lower bounds: the roll-up state resets  [same 7 days]
- UserPromptSubmit payload classes: 1,205 user-prompt entries in top-level transcripts: retrievable 623, task-notification 502 (402 of them in main-TC), under 3 tokens 41, scheduled-task-first 15, slash command 12, empty after strip 12  [transcripts touched in the same 7 days]
- human prompts quoting an absolute repo path, which the strip deletes whole: 200 of 664 human-shaped prompts; e.g. 'fix C:\Codex\ThriftyCrew\grocery\compare-deals.ps1 so the Walmart rows stop doubling' becomes 'fix so the Walmart rows stop doubling'  [same 7 days]
- correction records produced by harness envelopes: 3 of 4 correction rows (2 task-notification, 1 scheduled-task)  [same 7 days]
- scheduled task files that carry a Knowledge consulted section: 1 of 14 under C:\Users\Owner\.claude\scheduled-tasks\*\SKILL.md  [state at 2026-09-22]
- exploration rows and their scores: 27 all time (15 in 7 days); 27 of 27 scored below 0.548  [all time (first row 2026-09-12)]
- synced vendor skill sections in the retrieval corpus: 172 of 2,162 embedded vectors; 39 offers in 7 days, 0 opened, 24 of them from scheduled envelopes  [same 7 days]
- SubagentStart hook support in the installed CLIs: present in C:\Users\Owner\AppData\Roaming\Claude\claude-code\2.1.280\claude.exe and C:\Users\Owner\.local\bin\claude.exe: input {agent_id, agent_type} plus common fields, matched on agent_type; output hookSpecificOutput.additionalContext is read. Nothing in settings.json registers it. The store has 0 mentions (grep -rn SubagentStart ~/.claude/skills --include=*.md)  [binaries dated 2026-09-08 and 2026-09-22]
- nightly derive-floors step for a file that gates nothing: 56,691 ms of the 2026-09-22 sleep pass; recall-floors.json _meta.applied_by is []; snapshot index 91,381,760 bytes  [2026-09-22 04:35 pass]

## Findings

### prompt-tier-cannot-reach-subagents [gap/both/high] VERDICT=OVERSTATED
The prompt tier never fires in subagent or workflow contexts, where 82% of code edits happen. SubagentStart exists and is unused

CORRECTED: UserPromptSubmit never fires in a subagent (0 of 834 prompt-hook calls carried an agent id). SubagentStart exists in both installed CLIs and nothing registers it. But subagents are not unserved, and they are not mostly Workflow agents. 3,567 of 4,516 Edit/Write calls (79.0%) ran in Agent-tool subagents. Those already get recall-agent-hook's pointer block and, since 09-20, a brief gate that held on 52 of 52 briefs. Workflow-tool agents made 6 of 4,516, all inside this review. The measured goal-1 gap for subagents is behaviour, not reach: only 11 of 38 Agent-tool contexts with an edit searched before their first edit, even after the gate.

FIX: STEP 0, a probe with its bar written first. Write the scratch hook <scratch>/probe-subagent-start.py, which appends the raw stdin payload to a temp jsonl. Register it only in a sandbox settings file and run `claude -p --settings <sandbox.json>` from a scratch dir: one Agent-tool subagent and one Workflow-tool agent, 5 each. Record per spawn: did SubagentStart fire, the payload keys, and whether the payload's transcript_path (or <proj>/<sid>/subagents/agent-<agent_id>.jsonl) already holds the agent's task prompt when the hook runs. Bar: retrieval-on-prompt only if the prompt is readable in at least 9 of 10 spawns; otherwise ship the fixed block alone.
STEP 1. New file ~/.claude/skills/recall-subagent-start-hook.py. In settings.json add "SubagentStart": [{"matcher": "", "hooks": [{"type":"command","command":"\"C:\\Codex\\Python312\\python.exe\\\" \"...\\recall-subagent-start-hook.py\""}]}].
- Input: the payload. Exempt agent_type in {Explore, claude-code-guide, statusline-setup}, the same set as recall-brief-gate-hook.py; print nothing for those.
- Output: print JSON {"hookSpecificOutput":{"hookEventName":"SubagentStart","additionalContext": BLOCK}}, with BLOCK at most 900 bytes (recall_core.MAX_INJECT_BYTES). BLOCK is a fixed 3-line procedure: (1) the exact knowledge-search command with a <terms> slot; (2) grep the repo for an existing helper, gate or lib before writing one; (3) end the report with 'Knowledge consulted: <paths>' or 'searched "<terms>", nothing applicable'. If STEP 0 found the prompt readable, append up to 4 semantic pointers from recall_semantic.search(prompt, k=4) at MIN_COSINE.
- Resolve the project through the fixed memory key (finding worktree-memory-key-mismatch).
- Fail OPEN: any exception gives exit 0 and empty stdout, because a start hook must never stop a subagent.
- Telemetry: recall_append a row {ev:'subagent-start', sid, agent, agent_type, mode:'fixed'|'retrieved', bytes, n}, and call recall_core.heartbeat(state,'SubagentStart') so --health can count it (event_population 'subagent').
- Fixtures in --selftest (RECALL_LOG and RECALL_STATE_DIR redirected via a proof_env copy). MUST FIRE: agent_type general-purpose gives parseable JSON with hookEventName SubagentStart and a non-empty additionalContext of at most 900 bytes. MUST NOT FIRE: agent_type Explore gives empty stdout. MUST NOT FIRE: malformed stdin gives exit 0 and empty stdout. CLEAN TWIN: recall-hook.py's UserPromptSubmit output is byte-identical before and after (run its selftest).
STEP 2, measure with the bar written first: the share of subagent contexts that log a knowledge-search `search` row (the agent field) before their first Edit/Write. Baseline over the 7 days before install, then compare 7 days after. If it does not at least double, retire the block, per always-on-delivery-is-not-sufficient.

CRITIQUE: 1. Scope it. For Agent-tool subagents a SubagentStart block would be a third injection, after the agent-hook pointers and the pasted Knowledge consulted section. Either target agent_type 'workflow-subagent' only, or measure the gain first.
2. Workflow agents must answer through StructuredOutput. 'End the report with Knowledge consulted:' conflicts with that; route it into the output schema instead.
3. The exempt list in recall-brief-gate-hook.py is lower-case, and the payload says 'Explore'. Compare case-insensitively.
4. STEP 0 must prove the block reached the child, because the CLI skips the hook for delegated-observation agents and drops attachments for isolatedContext. Ask the probe agent to quote the block back; a hook firing is not proof.
5. The STEP 2 metric cannot be measured as written. Search rows carry only CLAUDE_CODE_SESSION_ID, which is the parent sid, and no agent field (search.py:1026-1055): 96 of 96 search rows in the window read as main-agent, while transcripts show 84 Agent-tool contexts ran search.py. Measure from subagent transcripts instead: a Bash or PowerShell tool_use invoking knowledge-search\search.py before the first Edit/Write. The baselines are above.
6. A 'doubles' bar over about 5 workflow contexts a week is noise.
7. The settings command in the sketch has broken escaping. Copy an existing entry's quoting byte for byte.
The fixture must prove four things: the child context contains the block (quote test); exempt types get empty stdout; malformed stdin exits 0 silently; and a brief that already carries Knowledge consulted gets no duplicate block.

### scheduled-task-envelope-floods-offers [issue/both/high] VERDICT=CONFIRMED
Scheduled-task envelopes are not stripped: 56% of prompt offers come from them, and none was opened

CORRECTED: 548 of 977 prompt-hook offers (56.1%) in 7 days answered a scheduled-task envelope. None was opened in-session, against 27 of 429 for the rest. The failure scenario picks the wrong example: grocery-alert-triage is the one scheduled task (of 14) whose file carries a search step, and scheduled sessions produced half of all searches (48 of 96). The static in-file step works where the pushed pointers did not.

FIX: 1. recall-hook.py _main_body: before the strip, test the raw prompt with re.match(r'\s*(<\system-reminder>.*?<\/system-reminder>\s*)*<scheduled-task\b([^>]*)>', prompt, re.S). On a match: pull name="..."; write one row {t, ev:'skip', why:'scheduled-task', name, sid, agent, turn} via _append_rows(LOG,...); keep the heartbeat; do not set last_prompt; return 0. No retrieval, no stdout.
2. recall-stats.py: rows with ev 'skip' are ignored by construction (it counts offer and open only), so there is no change beyond printing a 'skipped scheduled turns: N' line.
3. New read-only audit ~/.claude/skills/scheduled-task-knowledge-lint.py, called from check-skills.py as a WARNING, not a failure (a bar that is red on day one is forbidden). It lists each ~/.claude/scheduled-tasks/*/SKILL.md without a '## Knowledge consulted' section. It is the scheduled-run analogue of the brief gate, and Brad rules whether it becomes a refusal.
Fixtures in recall-hook --selftest, with outputs redirected by proof_env. MUST FIRE: the envelope above gives empty stdout and exactly one skip row naming grocery-alert-triage. MUST FIRE: the Cowork shape ('<\system-reminder>...<\/system-reminder>\n<scheduled-task name="aa-fare-watch-tys-oma" ...>') is also skipped. MUST NOT FIRE: 'why did the scheduled-task grocery-alert-triage fail twice today' still retrieves normally. CLEAN TWIN: a <\task-notification> prompt still strips to empty and writes no skip row.
Measure after 7 days: the scheduled-envelope offer share must be 0 of N and the non-scheduled open rate is reported beside it (baseline 27 of 429). This must land BEFORE consulted-gate-blind-to-prompt-offers, or scheduled Desktop runs start being refused.

CRITIQUE: 1. The sketch's regex has escaping artefacts. A literal copy of '<\system-reminder>' puts \s (whitespace) into the pattern. Write it as r'\s*(?:<\system-reminder>.*?<\/system-reminder>\s*)*<scheduled-task\b'.
2. Adding 'scheduled-task' to _HARNESS_BLOCKS alone does nothing, because the block regex needs an attribute-free tag.
3. Put the skip after the turn-id and heartbeat writes, so --health still counts the beat.
4. Make one shared predicate in recall_core. recall-dream.py:201 already has its own scheduled test, `first_prompt.lstrip().startswith('<scheduled-task')`, which misses the Cowork shape: 371 of 373 Cowork transcripts are aa-fare-watch runs that open with <\system-reminder>.
5. The lint should look for a search.py instruction, not the literal heading 'Knowledge consulted'.
The fixture must prove four things: both envelope shapes are skipped with one skip row; a prompt that merely mentions a scheduled task still retrieves; a task-notification still strips to empty; and the timing row is still written on the skip path.

### consulted-gate-blind-to-prompt-offers [issue/both/high] VERDICT=CONFIRMED
The Stop consulted gate cannot see prompt-hook offers, because the prompt hook never records them

CORRECTED: The Stop gate has never seen a prompt-hook offer: on 194 of 224 joinable offering turns it logged nothing offered. Once scheduled envelopes are skipped, turning it on would refuse about 15 turns a week (17 with no footer, of 105 non-scheduled offering turns, less 2 with stop_hook_active). It would not produce 63. Without enforcement, footers already appear on 88 of 105 and name something on 28 of 105, so the gate mostly buys 'Consulted: nothing relevant' lines. The real gain is a correct 'offered' field for recall-brain and recall-answer-outcome.

FIX: 1. recall-hook.py write_turn(key, turn, qtoks, state_dir=None, offered=0, src='prompt'): add 'offered': offered and 'offered_t': int(time.time()) to the turn sidecar JSON. At the offer site (line ~790) pass offered=len(picked). The sidecar is a separate file, not the allow-listed state, so there is no load_state allow-list change and no race with the reflex hook's state writes.
2. recall_core: add turn_offered(payload, state_dir=None) that returns (n, t) from _read_turn(turn_path(session_key(payload))). Never raises; returns (0, 0) on error.
3. recall-consulted-hook.decide(): n = offered_this_turn(state, since) + (tn if tt >= since else 0), where (tn, tt) = turn_offered(payload). Log a new field 'offered_prompt': tn.
4. Keep the headless skip and the once-per-turn brakes unchanged.
Fail OPEN on any read error (count 0), same as today. Waiver: 'Consulted: nothing relevant' is already accepted.
Fixtures in recall-consulted-hook --selftest. MUST FIRE: sidecar offered=3 with offered_t >= since and a reply without a footer gives refuse. MUST NOT FIRE: sidecar offered=3 with offered_t < since (last turn's offer) gives no refusal. MUST NOT FIRE: stop_hook_active set gives no refusal. CLEAN TWIN: state['offered'] from the agent hook still refuses exactly as before.
Blast radius, stated for Brad's ruling before shipping: at the 7-day rate, 63 of 233 offering turns had no footer, so up to about 63 refusals a week, each a second turn. Depends on scheduled-task-envelope-floods-offers landing first.

CRITIQUE: 1. The sidecar is rewritten whole at line 432 (turn start) and again at about 790. Both writes must carry 'offered' (0, then len(picked)), or a stale value survives.
2. Keep the count out of state['offered']. recall-agent-hook's filter_new dedups against that dict, so writing prompt offers there would silence agent-hook pointers.
3. It depends on the scheduled skip landing first: 42 of the 59 would-be refusals are envelopes.
4. Brad should rule on it with the corrected figures: about 15 a week, most of them yielding 'nothing relevant'.
The fixture needs four cases: MUST FIRE with the sidecar offered=3 at or after since and no footer; MUST NOT FIRE on the previous turn's offer; MUST NOT FIRE with stop_hook_active; and a CLEAN TWIN in which agent-hook state['offered'] refuses exactly as before.

### worktree-memory-key-mismatch [gap/both/high] VERDICT=OVERSTATED
In a worktree or subdir the hooks resolve no memory corpus, while the harness loads the main repo's memory. project_key also mis-encodes 172 of 204 project dirs

CORRECTED: From any cwd other than the repo root, the hooks resolve no memory corpus, while the harness loads the main MEMORY.md (146 of 188 worktree transcripts). The concrete losses are two: exact-slug memory routing, which yields about 0 offers a week even at the root (4 ever), and memory-lint's near-duplicate check, which is blind for memories written from a worktree. The encoding difference (172 of 204) affects only worktree dir names and corpus tags, never where memory lives: project_key already matches all 30 non-worktree dirs. This is a prerequisite for any memory retrieval leg, not a large live loss today.

FIX: 1. In knowledge-search/recall_index.py add two functions.
   cc_encode(path): re.sub(r'[^A-Za-z0-9]', '-', str(path)).rstrip('-').
   project_root(cwd): walk up from cwd at most 12 levels. At each level L: if L/.git is a directory, return L. If L/.git is a file, read its first line 'gitdir: X' and normalise the slashes. If X contains '/.git/worktrees/', return the part before '/.git/worktrees/'; otherwise (submodule) return L. If no .git is found, return cwd. On any exception, return cwd.
   Add memory_key(cwd) = cc_encode(project_root(cwd)).
2. resolve_roots: memory root = projects/<memory_key(cwd)>/memory, tagged 'memory:'+memory_key. Leave the rules corpus rooted at the worktree's own top-level .claude/rules with its current tag, because the rules differ per branch; retagging would make worktrees thrash one corpus and orphan index rows.
3. recall_tiers._memory_dir: delete the local copy and call recall_index.memory_key.
4. recall-hook.py and recall-agent-hook.py: pass payload.get('cwd') or os.getcwd().
Cost: at most 12 stats and one small read, under 1 ms. Fail open to today's behaviour.
Fixtures in recall_index --selftest, on a temp tree. MUST FIRE: main/.git (dir) plus main/.claude/worktrees/x/.git (file 'gitdir: <main>/.git/worktrees/x'); cwd main/.claude/worktrees/x resolves memory to projects/<cc_encode(main)>/memory. MUST FIRE: cwd main/grocery gives the main key. CLEAN TWIN: cwd main gives the same key as today for a dot-free path. MUST NOT FIRE: a dir with no .git anywhere above (the C:\Codex container shape) keys on itself. MUST NOT FIRE: a submodule .git file whose gitdir has no /worktrees/ keys on the submodule. CLEAN TWIN: cc_encode('C:\\a.b\\c_d e') == 'C--a-b-c-d-e'.
Live check: rerun <scratch>/review/roots.py. The worktree cwd must list memory:C--Codex-ThriftyCrew with 187 files. The memory_key encoding must reproduce 203 of 204 non-worktree dirs in encoding.py.

CRITIQUE: 1. cc_encode must copy Claude Code exactly: no rstrip('-'), and a 200-character cut plus '-'+base36(abs(Java string hash)). The sketch's rstrip is wrong. For memory, what matters is resolving the canonical root; the encoding does not.
2. Two roots are involved and a quick fix will conflate them. The canonical project root is for memory. The checkout top-level is for rules; today rules are rooted at cwd, so a subdir gets none.
3. 7 of 97 worktree dirs have no .git file. Resolve a relative gitdir against the .git file's own directory.
4. recall-log-open.py's classifier is a third copy and must call the shared function.
5. refresh_if_due's last_refresh timestamp is global. A corpus first seen from a new cwd is skipped if any refresh ran in the last 5 s: the index holds rules for 3 cwds while 90 worktrees have rules.
6. Respect autoMemoryDirectory if it is set.
Fixtures: MUST FIRE near_duplicates returns a list, not None, from a worktree cwd; MUST FIRE a subdir cwd keys to the main root; CLEAN TWIN the main key is unchanged; MUST NOT FIRE on the non-repo C:\Codex container.

### path-strip-deletes-estate-file-names [issue/code/medium] VERDICT=OVERSTATED
The harness-text strip deletes every absolute path, including the repo file a coding prompt is about

CORRECTED: The strip does delete repo file names, but the loss is rare in real traffic: 4 of 99 main-TC prompts in 7 days lost a repo file name (7 lost any file name), and 0 of 61 in C--Codex. The 200-of-664 figure is mostly scheduled envelopes and experiment prompts. Most main-TC path-bearing prompts are spawn briefs ('In C:\Codex\ThriftyCrew (...)') where only the repo root is removed. This is low severity.

FIX: In recall-hook.py _strip_harness_text, replace the single _PATH_RE.sub with a function sub. For each absolute path match p: if p (case-insensitive) is under %TEMP%, AppData, \.claude\projects, or a scratchpad dir, return ' '. Else, if recall_index.project_root(p) (from worktree-memory-key-mismatch) returns a root R != p, return ' ' + relpath(p, R).replace('\\','/') + ' '. Else return the basename only.
Fixtures. MUST FIRE: a scratchpad path is removed entirely. CLEAN TWIN: 'C:\\Codex\\ThriftyCrew\\grocery\\compare-deals.ps1' becomes 'grocery/compare-deals.ps1'. MUST NOT FIRE: prose with no path is byte-identical. MUST FIRE: '<output-file>C:\\Users\\...\\x.output</output-file>' is still removed.
Re-measure after 7 days with the same strict-token list used on 2026-09-12: the share must stay under 5% (today 0 of 977).

CRITIQUE: 1. It depends on project_root from the worktree fix and adds filesystem stats for every path. Cap the paths per prompt.
2. Assert on the TOKENS tokenise() produces, not the rewritten string, because '/' handling decides whether 'compare-deals.ps1' survives.
3. Re-measure with 'scheduled-task' added to the strict list, or the '<5%' check proves nothing (see strength-harness-strip-held).
4. Rank it below the scheduled skip, which removes 124 of these 186 at once.

### memory-corpus-not-retrieved-at-prompt [gap/both/medium] VERDICT=CONFIRMED
The prompt tier retrieves skills only: memory is reached by exact slug alone and the built memory index is unread

CORRECTED: Correct as stated. It is the PLAN's own pending next step (a held-out memory floor), not a new idea, and the 3a wording needs correcting now. One qualifier: every memory is already reachable in context, 149 of 186 through the MEMORY.md index and the other 37 through rules citations. So a memory leg buys salience at the right moment, not reach.

FIX: Do the ruled next step, in order.
(1) Extend course/memory-questions.jsonl from 20 to at least 40 questions. Add 20 new situation-phrased questions from recent sessions, each keyed to a memory file, with a source field. Add 20 off-topic prompts.
(2) Split by sha1(question) parity. Run course/derive-semantic-floor.py against recall-embed-memory-C--Codex-ThriftyCrew.npz on the derive half only, with the selection rule written in the script header first.
(3) Report held-out hit@3 through /recall-search (index_path set to the memory npz, k=4, floor = the derived value). Bar written before the run: held-out hit@3 of at least 12 of 20 AND off-topic fire of at most 5 of 20. One row per case per arm in a jsonl.
(4) Register the floor as a new row in sidecar/THRESHOLDS.md (space: bi-encoder cosine, corpus: memory:<key>).
(5) Only if it clears: recall_semantic.search gains an index_path passthrough in the /recall-search body. recall-hook.py makes a second call with the npz for memory_key(cwd) and the memory floor. Up to 2 memory hits are rendered as '  memory/<file> :: <description line>' (at most 160 B each, per the core rule that a memory hit is the rule itself), taking slots before the 4th skills pointer. Leg logged as 'semantic-memory'.
(6) Add a sleep step that runs recall-embed-memory.py when any memory mtime is newer than the npz.
(7) Correct automatic-recall.md 3a now: the memory index is built and is consulted by no hook, verdict NOT SHIPPED.
Fixtures. MUST FIRE: a memory question with the index present gives a memory pointer. MUST NOT FIRE: a cwd of another project never loads C--Codex-ThriftyCrew's npz. CLEAN TWIN: with the memory npz missing, the skills pointers are byte-identical.

CRITIQUE: 1. Rendering 'memory/<file> :: <description line>' re-serves the MEMORY.md index line word for word. recall-agent-hook ruled against exactly that duplication. Render something the index lacks (the rule sentence from the body), or restrict hits to memories whose index line is not loaded.
2. A sha1 parity split will not give exactly 20 held-out questions, so write the bar as a rate with its denominator. Declare which half holds the 20 questions that already failed.
3. recall-embed-memory.py resolves its corpus from os.getcwd(), so run from a worktree it builds nothing. Land the key fix first.
4. Measure through /recall-search at k=4, as the plan says, never offline.

### prompt-tier-has-no-task-kind [gap/both/medium] VERDICT=CONFIRMED
The prompt hook cannot tell a coding or analysis prompt from chat, and injects only generic pointers

CORRECTED: Correct that the tier has no task kind and emits generic pointers. The comparison rate is wrong: deliberate searches were followed 18 of 96 times (18.8%) before this review ran, not 52 of 154. The 52 of 154 counted this review's own searches. Offers convert 274 of 8,809 (3.1%).

FIX: 1. recall_intent.py: add prompt_kind(text) returning 'code', 'analysis' or 'other'. Reuse SUBJECT_RE and JUDGEMENT_RE and add CODE_RE (fix|implement|add|write|refactor|build|wire|patch|change the (script|hook|gate|schema)) and ANALYSIS_RE (why|measure|diagnose|review|audit|compare|verdict|root cause|how (many|often)|rate). The rule: code wins when both hit and a file or identifier is present, otherwise analysis.
2. Bar written first: hand-label 100 prompts sampled by sha1 order from the 623 retrievable prompts of 2026-09-15..22 into cases jsonl rows (one row per prompt, with source). Ship only if code precision is at least 0.85, analysis precision at least 0.80, and neither fires on more than 60% of prompts.
3. recall-hook.py: compute the kind after the strip and add 'kind' to the timing, offer and nearmiss rows (telemetry first, no behaviour change, for 7 days).
4. Then, for code or analysis only, add ONE line before the footer, at most 200 B, keeping the block under 900 B. For code: '  Code task: search the store and grep the repo for an existing helper or gate before writing; the commit owes a Store: line.' For analysis: '  Analysis: search the store for the method, and state denominator, rubric and window.' When the top hit's domain has an applies-here.md not already picked, it takes the 4th slot (2a found the misses pointed at those files).
5. Measure with the bar written before: the share of code-kind turns with a knowledge-search 'search' row in the same sid before the turn's first Edit/Write, 7 days before against 7 days after. Retire the line if the rise is under 2x.
Fixtures. MUST FIRE: 'fix the Walmart row builder so pack sizes stop doubling' gives code. MUST FIRE: 'why did run-gates exit 3 on the worktree push' gives analysis. MUST NOT FIRE: 'what should I make for dinner tonight' gives other. CLEAN TWIN: the kind-other block is byte-identical to today's.

CRITIQUE: 1. Adding a line breaks the existing fixture (at most MAX_SECTIONS+3 lines, under 700 B, on a code prompt). A quick implementer will loosen the fixture, which weakens a gate. Replace the footer wording, or take a pointer slot, instead of adding a line.
2. 'The commit owes a Store: line' is true only in ThriftyCrew (ops/store_citation.py). Gate the line on the project.
3. Exclude tc-exp and other harness-driven sessions from the labelling sample and the metric: all 46 read as 'code'.
4. After exclusions there are only about 160 human-ish prompts in 7 days, so the sample of 100 needs a longer window.
5. The same-sid search metric credits a subagent's search to the main turn. Use transcripts instead.
The fixture must pin the byte and line budget on a code-kind prompt.

### offer-open-join-crosses-sessions [issue/analysis/medium] VERDICT=CONFIRMED
recall-stats counts an open from any session as a hit and has no time window

CORRECTED: In 7 days, 8 of 35 counted hits (23%) were opens by a different session. That inflates the hit rate and the per-file weights. It does not change forgetting candidacy, which counts any open by design, so the failure scenario's 'rescues sections from the forgetting list' is wrong.

FIX: recall-stats.py:
(a) add --since DAYS (default: all). It filters offer rows by t and leaves the open index unfiltered.
(b) tally(): hit only when an open with the same sid lands in [t, t+WINDOW]. Rows without a sid on either side use the old rule, so legacy numbers reproduce.
(c) print four lines with denominators: same turn, same session, same session main-agent, any session.
(d) print a separate line for offers whose first 3 cue tokens include 'scheduled-task'.
Fixtures in --selftest. MUST NOT FIRE: an open in session B 100 s after an offer in session A is not a hit. CLEAN TWIN: the same-session open still hits. MUST FIRE: legacy rows with no sid are counted by the old rule. The candidates() output is unchanged on the frozen fixture.

CRITIQUE: 1. Pick the legacy rule by date, not by whether the sid field is present. Otherwise a new row that happens to lack a sid silently reverts to the permissive join.
2. Add is_real_session filtering: this review alone added 96 searches and 52 follows under one sid within an hour.
3. Fixture a boundary case exactly at t+900 and one a second past it.

### hook-health-hides-structural-gaps [issue/both/medium] VERDICT=OVERSTATED
Hook health pools all origins all-time, so whole classes of sessions that never fire the prompt hook read as healthy

CORRECTED: --health does pool every origin with no time window, which is true and worth fixing. But the headless class that 'never fires' is one day's batch: 10 of 12 approvals sessions on 2026-09-12, with no approvals run since and 2 of 2 later sdk-cli sessions beating. The Desktop worktree miss is 24 of 158. The -p doc claim is contradicted, since those sessions beat PreToolUse and Stop.

FIX: 1. recall-stop-hook.py health(rows, registered, origin_of=None, days=14). origin_of(key) opens projects/*/<key>.jsonl and reads the first row's entrypoint, plus the dir class (worktree if '--claude-worktrees-' is in the dir, cowork if 'scratch-workspaces', main otherwise); cache it per key. Print 'UserPromptSubmit beat in X of N <origin>' per origin, over rows with t >= now-days. Add a NOTE line (not an OUTAGE, and exit code semantics unchanged) 'STRUCTURAL GAP <origin>: X of N' when N >= 5 and X/N < 0.5.
2. approvals_runner.real_launch: before p.stdin.write, prepend a block computed in-process. import recall_semantic; hits, leg = recall_semantic.search(prompt, k=4). On leg None fall back to recall_index.search(conn, prompt, ['skills'], 8) at 8.5. Render '## Knowledge consulted (retrieved by approvals_runner for this job)\n- <path> :: <heading>', or '- searched "<first 8 cue tokens>", nothing applicable'. Also set TC_HEADLESS=1 in the child env. Fail open: on any exception send the original prompt.
3. Correct permissions-and-headless.md section 4 with these counts.
Fixtures. The --health selftest gains an origin fixture: 6 sdk-cli keys with 1 beat gives a STRUCTURAL GAP note and exit 0. CLEAN TWIN: the existing 'beat in 5 of 5 main sessions' case is unchanged. approvals_runner selftest: the fake_launch prompt starts with '## Knowledge consulted'. MUST NOT FIRE: a retrieval exception leaves the prompt byte-identical.

CRITIQUE: 1. Prepending a retrieved '## Knowledge consulted (retrieved by approvals_runner)' labels unread pointers as consulted. The in-process call also writes no search row, so store_citation cannot credit it. Instead, have the job run search.py itself (the grocery-alert-triage pattern, 48 of 96 searches).
2. Session keys carry no project, so origin_of needs one glob and a map.
3. Fixture the STRUCTURAL GAP note at the bar: N=5 and exactly half beating.

### correction-hook-reads-harness-envelopes [issue/general/low] VERDICT=CONFIRMED
The correction hook takes task-notifications and scheduled-task envelopes for Brad correcting me

CORRECTED: Correct. The organ has recorded 6 rows ever, and 4 of them are harness envelopes. That leaves 2 real corrections in its whole life, so its downstream rates rest on almost nothing.

FIX: Move _strip_harness_text and _HARNESS_BLOCKS from recall-hook.py into recall_core (strip_harness_text). recall-hook.py calls it (no behaviour change). recall-correction-hook calls it before classify(), and returns 0 on a scheduled-task envelope (the same regex as scheduled-task-envelope-floods-offers).
Fixtures. MUST NOT FIRE: '<\task-notification><result>this happens constantly</result><\/task-notification>' records nothing. MUST NOT FIRE: the scheduled-task envelope records nothing. CLEAN TWIN: 'You always have full permission to open tabs in my chrome so IDK why you didnt do it' is still recorded.

CRITIQUE: 1. Strip system-reminder blocks too. Human prompts carry CLAUDE.md text full of cue words (always, never, stop).
2. Share the scheduled predicate with recall-hook and recall-dream.
3. The data is too thin to verify any rate, so the fixtures are the whole proof: MUST NOT FIRE on a task-notification, MUST NOT FIRE on a scheduled envelope with or without a leading reminder, CLEAN TWIN keeps the real 09-22 18:40 correction.

### explore-guard-uses-bm25-floor [issue/general/low] VERDICT=CONFIRMED
The exploration guard passes the BM25 floor (8.5) where it needs the cosine floor (0.548)

CORRECTED: Correct. Today the guard holds only by accident of slot-filling. CATALOGUE.md scoring at or above 0.548 is a live path through it.

FIX: recall-hook.py:657: pass min_cosine=recall_semantic.MIN_COSINE. In recall_explore.explore_candidates also skip path == 'CATALOGUE.md'.
Fixtures in recall_explore --selftest. MUST NOT FIRE: a raw hit at 0.60 with room=2 is not returned when min_cosine=0.548. MUST NOT FIRE: CATALOGUE.md at 0.50 is not returned. CLEAN TWIN: a 0.50 hit not yet picked is still returned. Plus a hook-level static fixture that 'min_cosine=MIN_SCORE' does not appear in recall-hook.py (needle built by concatenation, per ops rules).

CRITIQUE: 1. Add an at-the-bar case using binary-exact numbers: pass min_cosine=0.5 and check that 0.5 is refused and 0.4375 is accepted, rather than using 0.548 and 0.547.
2. Build the static needle by concatenation.

### semantic-selftest-writes-live-breaker [issue/general/low] VERDICT=CONFIRMED
recall_semantic --selftest writes the live breaker file before redirecting it

CORRECTED: Correct, and still happening today: the live breaker's dead-URL count rose from 260 to 264 during this review.

FIX: Move 'global BREAKER; BREAKER = os.path.join(tmp, "breaker.json")' (with try/finally restore) to the top of selftest(), before line 465.
Fixture, CLEAN TWIN: the md5 of the live BREAKER file (or its absence) is identical before and after the selftest, read from os.environ-free defaults. After the fix, remove the stale 127.0.0.1:9 key once by hand (a person's action, not a script's).

CRITIQUE: The proposed fixture (md5 of the live file before and after) is racy. Every live prompt rewrites the 8077 entry's last_ok, so it will flake. Prove the mechanism instead: record every path breaker_note writes during the selftest, or run it as a subprocess with RECALL_SIDECAR_BREAKER set and assert the default file never gains the DEAD key.

### leg-unknown-on-quiet-turns [inefficiency/analysis/low] VERDICT=CONFIRMED
The leg log records only offering turns, so the leg share over all prompt calls cannot be computed

CORRECTED: Correct.

FIX: Move the LEG_LOG append to just after retrieval, before 'if not picked'. Write n=len(picked), which may be 0. Add a 'why' field on the timing row: 'empty-after-strip' | 'short' | 'scheduled' | 'retrieved', set in _CTX at each return.
Fixtures. MUST FIRE: a quiet semantic turn (stubbed search returning scores below the floor) writes a leg row with n=0. CLEAN TWIN: an offering turn's leg row is unchanged apart from key order. MUST FIRE: a 2-token prompt writes timing why='short'.

CRITIQUE: recall-brain.retrieve_stage counts leg rows as offers ('79 real semantic offers'). Rows with n=0 would change its meaning unless it filters n>0 for offers and reports quiet turns separately. Add a CLEAN TWIN: recall-brain's output is unchanged on a log that has extra n=0 rows.

### lexical-fallback-slow-and-frequent [inefficiency/general/low] VERDICT=CONFIRMED
The lexical fallback answers 31% of retrieving turns at a p50 of 660 ms, against a 200 ms budget

CORRECTED: Correct.

FIX: Add sub-timings to the existing timing row: sem_ms (the recall_semantic.search call), idx_ms (recall_index.ready plus search), breaker ('closed'|'open'|'half-open' read from breaker_state before the call). Bump 'arm' to 'breaker-subtimed' so check-skills' gate separates the arms. After 7 days, pick the fix from the data. No constant changes before that. Fixture: a timing row from a stubbed lexical turn carries sem_ms, idx_ms and breaker.

CRITIQUE: check-skills does not separate arms; it keeps any non-empty arm. Renaming the arm pools the new rows with the old ones. Sub-timings do not move the cost, so leave the arm as it is.

### floors-derivation-gates-nothing [inefficiency/general/low] VERDICT=CONFIRMED
The nightly floor derivation costs 57 s and a 91 MB snapshot, for a file that gates nothing

CORRECTED: The numbers are correct. The file gates retrieval nothing, but its snapshot is what the calibrate gate judges drift on, under a ruling made today.

FIX: In recall-sleep.py, run 'derive floors' only when its last run is 7 or more days old: read its own row in recall-sleep-log.jsonl, and print 'derive floors: skipped, weekly (last <date>)' otherwise. recall-hook-calibrate reads the existing file unchanged. Fixture in recall-sleep --selftest: with a 2-day-old last run the step is skipped and says so; with an 8-day-old one it runs.

CRITIQUE: 1. Running it weekly makes the gate judge a snapshot up to 7 days old, so Brad should re-rule before it changes.
2. A skipped step must still print exit 0 and 'skipped' in the sleep report, or the report reads as a failure.
3. Fixture the bar at exactly 7 days (runs) and 6 days 23 hours (skipped).

### analysis-turn-after-task-notification-unserved [gap/analysis/low] VERDICT=PLAUSIBLE
The synthesis turn after a workflow finishes gets no recall: task-notifications strip to empty

CORRECTED: True that the synthesis turns get nothing: these prompts strip to empty. But the proposed query is weak. The <summary> is mostly the spawn's 3-6 word operational description. And the parent's brief already carried a gated Knowledge consulted section (52 of 52 since 09-20).

FIX: Shadow mode only, 7 days. When the raw prompt is a task-notification, extract the <summary> text (not <result>, which can be kilobytes) and run the semantic leg on it. Log rows {ev:'shadow-offer', turn, path, heading, score, q} and print NOTHING. Then hand-label 50 shadow turns (sampled by sha1) for 'would this pointer have helped the synthesis'. Bar written before labelling: at least 25 of 50 useful and at most 10 of 50 misleading, or the idea is recorded as refuted in automatic-recall.md. Fixture: a task-notification prompt produces empty stdout and exactly one shadow-offer row per candidate in the redirected LOG.

CRITIQUE: 1. Set the shadow bar knowing the summary text is 'Agent "Push the branch through the gate" finished'. Or test the first 600 characters of <result> as a second arm.
2. Log exactly one row per turn for each arm.

### strength-harness-strip-held [strength/general/low] VERDICT=OVERSTATED
STRENGTH: the 2026-09-12 harness-text strip did what its prediction said

CORRECTED: The prediction held on the list it chose (0 of 977). Harness envelopes still drive 548 of 977 offers (56.1%) through a token that was not on that list.

FIX: Keep it. Move it to recall_core so the correction hook shares one copy (see correction-hook-reads-harness-envelopes), and add the scheduled-task and repo-path cases as fixtures beside the existing ones.

CRITIQUE: Add 'scheduled-task' to the strict list before claiming the strip holds.

### strength-pull-beats-push [strength/both/medium] VERDICT=OVERSTATED
STRENGTH: deliberate knowledge-search is followed 10x more often than pushed pointers

CORRECTED: Before the review, searches were followed 18 of 96 times (18.8%) against 3.1% for offers, about 6x rather than 10x. Searches are also self-selected: whoever runs one already wants the knowledge. So the ratio does not predict how a prompted search would convert.

FIX: Design the goal-1 and goal-2 mechanisms (the SubagentStart block, the code/analysis prompt line, launcher-injected sections) to trigger a deliberate search.py call and cite it, not to add pointers. Measure them on the 'search followed' and 'search before first Edit' rates, with denominators.

CRITIQUE: Exclude review and probe sessions from every rate. Report the before-review figure.

### strength-cheap-fail-open-and-timed [strength/general/low] VERDICT=CONFIRMED
STRENGTH: the hook fails open cheaply and times every path

CORRECTED: Correct.

FIX: Keep them as they are. New telemetry fields (kind, why, sub-timings, offered in the turn sidecar) go onto these same rows rather than into new logs.

CRITIQUE: None.

## Missed by mapper
- [medium] The search log cannot attribute a search to a subagent, so every 'searched before editing' metric and the Store: session check credit any agent's search to the whole session: search.py:1026-1055 logs only sid, taken from CLAUDE_CODE_SESSION_ID (the parent sid), and no agent field. 96 of 96 search rows in the window carry no agent. <vp>/v13_search_before_edit.py shows 84 Agent-tool subagent contexts ran search.py: 41 before their first edit and 43 only after.
- [medium] Review and probe runs contaminate the live logs that the rates are computed from: This review session added 96 searches and 52 follows in under an hour, doubling the all-time search count to 193. The mapper's 52-of-154 strength figure included them; the figure before the review was 18 of 96. recall-stats has no real-session filter.
- [high] The goal-1 gap in subagents is behaviour, not reach: the brief gate works, and editors still rarely search first: <vp>/v15_kc_by_date.py: briefs carried Knowledge consulted in 4 of 220 before the gate and 52 of 52 from 09-20. Contexts with an edit searched before the first edit in 30 of 207 before and 11 of 38 after. Workflow-tool agents made 6 of 4,516 Edit/Write calls in the window.
- [medium] The fixed search step in a scheduled task file produced half of all searches: 48 of 96 search rows in 7 days came from 5 scheduled sessions, and grocery-alert-triage's file is the one that carries a search.py step. That evidence favours putting the step into the file that launches the work over pushing pointers.
- [low] recall-dream's scheduled-session filter misses the Cowork shape: recall-dream.py:201 tests first_prompt.startswith('<scheduled-task'). recall-session-digest stores the raw first 200 characters, and 371 of 373 Cowork transcripts are aa-fare-watch runs that open with '<\system-reminder>'.
- [low] refresh_if_due uses one global timestamp, so a corpus first seen from a new cwd can go unindexed: recall_index.py:492-513 keeps a single last_refresh for all root sets. The index holds rules corpora for 3 cwds (18 files), while 90 of 97 worktrees have .claude/rules.

## Open questions
- Does SubagentStart fire for Workflow-tool agents as well as Agent-tool subagents? Can a SubagentStart hook read the agent's task prompt at that moment, from transcript_path or the subagent's own transcript? Not measured. STEP 0 of prompt-tier-cannot-reach-subagents is the probe.
- Does UserPromptSubmit fire for a `claude -p` prompt given on stdin in the current CLI (2.1.280)? Observed only on 2026-09-12: 10 of 12 approvals_runner sessions never beat it while beating PreToolUse and Stop.
- Why did 23 of 146 Desktop-spawned worktree sessions (first message is the 'You are operating in a git worktree' reminder) never beat UserPromptSubmit? Most were single-turn. Is the spawn prompt delivered without the event?
- Brad's ruling is needed before consulted-gate-blind-to-prompt-offers ships: restoring the gate adds up to about 63 refusals a week at the 7-day rate (63 of 233 offering turns had no footer).
- Should scheduled-task runs get any prompt-time recall, or should each ~/.claude/scheduled-tasks/*/SKILL.md carry its own '## Knowledge consulted' (1 of 14 does today), and should that become a refusal?
- Why do 3 large Fantasy sessions (e2d042b7, 5512eb08, ff9d8f1b, touched 2026-09-17) have zero rows in every recall log and the session log, while the C--Codex-Fantasy memory dir is empty? Not measured further. They began 2026-08-29 and may predate the logs.
- Are the synced vendor skill copies (172 of 2,162 embedded vectors; 39 offers in 7 days, 0 opened) meant to be in the retrieval corpus at all?
- Other reviewers need to confirm: whether recall-agent-hook.py and memory_lint.py also resolve memory through project_key (both call resolve_roots), so the worktree key fix changes their behaviour too.
