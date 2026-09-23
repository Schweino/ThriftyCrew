# Completeness critique: does knowledge reach coding and analysis work? (2026-09-22)

This was a read-only job. I made 9 tool calls, listed under Newly measured. Each call fired the live hooks under parent session 134f2f6e-7fb9-4057-a890-b2c27ba9dfc0: reflex and open rows were appended, and the intent hook injected twice. I drove no hook synthetically, ran no writer, and wrote no files.

## Scenarios

**What every context shares.** Some hooks reach every kind of context: main sessions, Agent-tool subagents, Workflow agents, scheduled runs, Fantasy and brain edits. They are:
- PreToolUse reflex and intent on Bash|PowerShell|Edit|Write
- memory-lint on Write|Edit
- PostToolUse open-log and outcome

Everything else depends on how the context was started.

**(i) A main-checkout session is asked to "fix a bug in grocery\X.ps1".**
- What fires:
  - The UserPromptSubmit recall hook. It searches the skills corpus only. It strips any absolute path from the prompt, so the file name never reaches the query. It finds memory only by exact slug: 0 of 977 offers in 7 days were memory.
  - The correction hook.
  - On each Edit/Write, the reflex hook. It sees the path plus the first 2,000 chars. 5 of 30 rows are scoped to grocery/meal-prep, and it injected on 115 of 1,052 grocery edits.
  - The intent hook, which is inert on edits: 1 of 1,938 Edit/Write calls carry a description.
  - On Stop, the consulted gate. It is blind to prompt offers: it counted an offer on 25 of 224 offered turns. The absence rung also runs.
  - The commit-msg store_citation check, and run-gates at push.
- What reaches it:
  - 3 CLAUDE.md files.
  - All six rules files (118,538 B). They load unconditionally because their `globs:` key is inert.
  - The TC MEMORY.md index: 149 of 186 memos are linked, and 37 more are cited from rules.
  - The helper names (Write-TcAtomicFile, Get-TcTreeFiles, Invoke-Native and so on) arrive only as prose in ops-and-gates.md (74 KB). The recall index stores that file as a single 10,978-token chunk.
- What enforces:
  - The Store: line: warn now, refuse from 2026-09-25. It will refuse citations of `.claude/rules`, `design/` or `lib/`.
  - Push gates exist for 4 of the 12 named helpers.
- What is missing:
  - Nothing at edit time names the helper that replaces the construct being typed (0 of 30 rows).
  - Edit reminders land after the write.
  - Nothing checks that this context searched. "Backed" means any search by the parent session id in the prior 24 h, so 171 of 175 rows read as backed.
  - search.py cannot see memory, rules or code, so every "Store: searched X, nothing applicable" line is uninformed by construction.

**(ii) An ultracode session runs a Workflow whose agents edit ops\*.ps1 in worktrees.**
- What fires:
  - The parent's UserPromptSubmit hook only.
  - The Workflow tool call itself fires nothing: the brief gate and the agent hook match `Agent|Task` only.
  - Inside the agents, the tool-tier hooks fire with agent_id (97 reflex rows across 9 agents today).
  - Agent failures are invisible. PostToolUse does not fire on a failed call, and the nightly join reads top-level transcripts only: 0 of 1,237 subagent outcomes are recorded as burned.
  - SubagentStop runs only the roll-up. No consulted or absence rung runs, and 0 of 699 gate rows carry an agent id.
- What reaches it:
  - CLAUDE.md ×3, all six rules and the main MEMORY.md index. I observed all of these in this agent's own context.
  - No UserPromptSubmit recall, no agent-hook pointers, and no Knowledge consulted section unless the orchestrator writes one. 1 of 34 saved scripts carry a section, and brief-gate's HEAD_RE denies even that one.
  - For a worktree cwd, the recall corpora are skills plus that worktree's rules, with no memory.
- What enforces:
  - commit-msg DOES judge these commits. The workflow-agent environment carries `CLAUDE_CODE_SESSION_ID` (the parent's sid) and `CLAUDE_CODE_CHILD_SESSION=1` (measured below). This holds only when the worktree has `ops/store_citation.py`. One orchestrator search backs every agent.
  - run-gates at push. Its static audits score a zero-file scan as ok: readjson reported scanned=0 with rc 0 on 12 of 12 worktree runs.
- What is missing:
  - A check on the Workflow script.
  - Per-agent search attribution.
  - Memory in worktree recall.
  - Outcome evidence for agents.
- Volume, measured: Workflow transcripts were 324, 994, 24 and 20 for June through September, from 12, 30, 3 and 1 runs. The September run is this review. Agent-tool subagent transcripts in September were 563.

**(iii) A spawn_task child in a worktree builds a new audit.**
- What fires:
  - Nothing on the spawn_task call. 1 of 24 spawn_task prompts since 09-12 carried a section, and whether PreToolUse fires for `mcp__ccd_session__spawn_task` is unmeasured.
  - The child is a top-level Desktop session. UserPromptSubmit fired for 23 of 24 children, with skills only and no memory corpus. The Stop gates run as in (i).
- What reaches it:
  - CLAUDE.md ×3, the six rules and the main MEMORY.md (loaded in 146 of 188 worktree transcripts).
  - The audit contract lives only as ops-and-gates prose: the COMPLETE marker, the SCOPE OF A CLEAN REPORT line, `Get-TcTreeFiles -PruneBelow`, `New-TcWorktreeFixture`, and per-run temp directories.
- What enforces:
  - A fresh worktree carries the current store_citation, so the commit is judged.
  - Push gates.
- What is missing: this scenario is the exact history of `ops/audit-readjson-inline-wrap.ps1` (2026-09-21).
  - It was written with all the rules loaded and carried a compliant Store: line.
  - It reproduced tree-walk's founding bug at char 4,693, which is past the 2,000-char reflex window.
  - It passes in every worktree because run-gates scores scanned=0 as ok. full-path-excludes is a count ratchet with slack (3 sites against a mark of 4) and runs only daily.

**(iv) A scheduled triage-reviewer run diagnoses an alert.**
- What fires:
  - It runs as a Desktop scheduled task with entrypoint claude-desktop and cwd C:\Codex.
  - UserPromptSubmit fires on the attributed `<scheduled-task ...>` envelope, which the strip misses. 548 of 977 offers came from these envelopes, and 0 were opened.
  - The Stop consulted gate judges these runs, because the headless skip covers only TC_HEADLESS=1 and sdk-cli. Measured: 4 of the 5 newest scheduled sessions have gate rows, with 5 refusals among them.
  - Agent spawns pass the brief gate (52 of 52 since it landed) and receive agent-hook pointers.
- What reaches it:
  - The global and C:\Codex CLAUDE.md files.
  - The C--Codex MEMORY.md: 208 memos, none sharing a name with TC's 186. It holds Brad's rulings from 09-21 and 09-22.
  - The six TC rules, but only after the first Read-tool read of a TC file.
  - The task file's own search.py step, which is the one pull that works reliably: 48 of 96 searches in 7 days came from 5 scheduled sessions.
  - triage-reviewer.md carries the store-first block (6 of 13 agent definitions do).
- What enforces: validate-triage-plan checks nothing about knowledge. 19 of 23 plans carry `knowledge_consulted` voluntarily. The plan audit covers PLAN- and MEASURE- documents only.
- What is missing:
  - A check on the plan's knowledge field.
  - Any check on the helper's returned verdict.
  - Memories written here never reach TC-cwd sessions, and the reverse.

**(v) "Did X improve?" answered with python one-liners and no edits.**
- What fires:
  - UserPromptSubmit retrieves by topic. experiment-craft was offered 4 of 973 times, and on 0 of the 14 human analysis prompts.
  - Bash reflex, which has no analysis rows.
  - Bash intent, which fired on 215 of 997 measurement-worded descriptions. Its offers are not logged.
  - The Stop consulted gate (blind) and the absence rung, which fires only on "X does not exist" claims.
- What reaches it:
  - measurement.md, if cwd is under ThriftyCrew (23 of 23 sessions).
  - From C:\Codex it is absent at start (0 of 9). It arrives only after a Read-tool read of a TC file, and Bash-only work never does one.
- What enforces: nothing. There is no commit, no record, and no check on the chat answer's denominator, bar or harness.
- What is missing: every refusing mechanism. This is the largest hole in goal 2.

**(vi) A session in C:\Codex\Fantasy writes modelling code.**
- What fires: UserPromptSubmit (skills only; the C--Codex-Fantasy memory holds 0 files), the tool tier (23 unscoped reflex rows, none for Python modelling), and the Stop gates.
- What reaches it:
  - The global CLAUDE.md.
  - C:\Codex\CLAUDE.md, whose table still says Fantasy has no git. It has a .git.
  - The Fantasy CLAUDE.md (4,198 B).
  - No rules, no memory, and 1 mention of Fantasy across the 16 applies-here files.
- What enforces: nothing. Fantasy has no git hook, and 0 of 5 commits since 09-01 carry the Store: line the global CLAUDE.md requires.
- Volume: the three "zero-row" sessions predate the logs (measured below). Since 09-07 there have been 2 short sessions. It is a complete hole with near-zero traffic.

**(vii) A session edits the brain (~/.claude/skills/recall-*.py).**
- What fires:
  - UserPromptSubmit. For once the corpus fits the task: claude-code-craft and knowledge-search.
  - The tool tier, but 0 of 30 reflex rows are scoped to the brain, and 0 of 68 skills edits got any injection.
- What reaches it:
  - The global CLAUDE.md plus the cwd project's instruction files. There is no `~/.claude/skills/CLAUDE.md` and no rules directory for the brain.
  - The brain's invariants exist only in code comments and automatic-recall.md: redirectable RECALL_* logs, the load_state allow-list, recall_append, self-tests that never touch live state, and fail-open behaviour.
- What enforces: nothing.
  - The ~/.claude repo has 0 non-sample git hooks and no core.hooksPath.
  - check-skills runs only in the nightly pass, which was red on 11 of 12 nights.
  - The hooks execute from the working tree, so a saved edit is live in every session on the box before any test or commit.
- What is missing: any gate between edit and deploy.

**Cross-cutting holes that no mapper covered end to end.**
1. No context is ever made to search. Every scenario depends on the model choosing to. The only pulls that reliably happen are a fixed search step in a task file and the Agent-tool brief gate.
2. Three harness events that bear directly on the goals exist in the installed CLI builds and are neither probed nor registered: SubagentStart, PostToolUseFailure and InstructionsLoaded.

## Conflicts

- **C1. How much work runs through Workflow.** The orchestrator said most ultracode work does. The mappers found 6 of 4,516 Edit/Write calls in Workflow agents, and 1 Workflow call against 314 Agent calls. My measurement resolves it: Workflow was the dominant route in July (994 transcripts, 30 runs) and is near zero now (20 transcripts, 1 run in September). The Agent tool dominates today (563 in September).
  - Resolution: build tool-tier and Agent-path mechanisms first. Put Workflow-only mechanisms behind a probe, and assume neither route is absent.
- **C2. The consulted gate's mechanism and value.** Three designs were proposed: a turn-sidecar field, `record()` into shared state, or counting `ev=offer` rows in recall-log. Estimates of added refusals ranged from 15 to 63 a week.
  - Resolution: count recall-log rows for (sid, turn, no agent). The log is append-only and already carries the turn id. This avoids the shared state file, which loses writes (7,174 to 7,469 orphan .tmp files; 581 of 738 roll-up keys show impossible beat counts). It also avoids changing the bytes metric that `record()` feeds.
  - Stop counting agent-hook child pointers: 6 of 12 refusals were for pointers only the child ever saw.
  - Expect about 15 refusals a week once scheduled envelopes are skipped. The value is low because the footer is already habit: 384 of 453 turns with nothing offered carried one, and armed turns named anything in only 34 of 159. It goes below the line and is judged by named items, not footer rate.
- **C3. Scoping the rules files.** Two proposals (rules-frontmatter-inert step 4, and memory-and-budget branch B) want `paths:` scoping. Three critiques want the load kept unconditional. The evidence against scoping:
  - In 2.1.280, path triggers come from Read-tool paths and are merged only when `!agentId` (code reading, not probed).
  - 22,217 of 37,843 tool calls were Bash or PowerShell.
  - The agent hook suppresses rules hits on the premise that subagents already have the rules.

  Resolution: take option A now (drop the dead keys, correct the carriers, add telemetry). B becomes an offer-N only after InstructionsLoaded proves delivery to Bash-only, Agent and Workflow contexts. measurement.md stays unconditional under either option. `alwaysApply: true` does nothing.
- **C4. Exposure on 2026-09-25.** The record-tier review called the per-checkout copies high severity. My measurement shows only 8 of 92 checkouts have a HEAD commit in the last 3 days: 6 run the current resolver and 2 run the stale 59d00ae. That stale version has REFUSE_FROM 2026-09-25 and reads one memory dir. All 57 checkouts with no copy are inactive.
  - Resolution: the load-bearing defect is the resolver refusing estate citations (10 of 53 attempts on 09-22). The per-checkout copy is a small live exposure plus a missing BLIND message. The date is Brad's call.
- **C5. One matcher or two.** Tool-tier proposed reflex rows (WS-A); estate-machinery proposed a new recall-machinery-hook.
  - Resolution: one engine, `recall_reflex`. Header `REPLACES:` lines may generate rows but never run as a second matcher. No new process on each Edit/Write (a median of 376 a day).
- **C6. Machinery index tracked or cached.** A tracked `docs/MACHINERY.md` with a byte-compare push gate churns on every caller-line move and fights the rebase in push-main.
  - Resolution: a gitignored per-checkout cache, rebuilt on demand (about 2.1 s measured), with no push gate.
- **C7. `--estate` has three definitions** (memory, rules and grep; MACHINERY.md; or `--project`).
  - Resolution: one definition (ranked change 2), with roots from `--git-common-dir` and both memory stores.
- **C8. SubagentStart block vs a PreToolUse primer.** For Agent-tool subagents a block would be a third injection over a gate that already holds 52 of 52. The measured gap is behaviour: 11 of 38 editing subagent contexts searched before their first edit.
  - Resolution: a refusal keyed on the context's own search (ranked change 4), carried by PreToolUse, which already fires in Workflow agents. SubagentStart stays a probed option.
- **C9. Failure events.** automatic-recall s2 says "PostToolUse on failures cannot exist [REFUTED 2026-09-07]", yet PostToolUseFailure appears in builds 2.1.173 through 2.1.280. Treat the store's claim as unqualified until probed, and build on neither reading.
- **C10. What blocks reflex promotion.** One review says it is person-bound; the offline verifier says it is evidence-bound (0 of 85 evidenced drafts clear the bar, and subagent fires can never record a burn).
  - Resolution: fix the evidence first, then re-run the ladder, then add negatives.
- **C11. The select-first row.** One fix would exclude search.py from it. But piping search.py into `Select-Object -First` really does kill its log row (19 of 75 PowerShell searches), which hides those searches from store_citation.
  - Resolution: search.py logs before it prints. Do not exclude it.
- **C12. The set-content rewrite.** Proposals conflict: `rewrite_unless`, naming Write-TcLfFile in the message, and atomic-write deliberately keeping CRLF. No single rewrite is correct under PS 5.1.
  - Resolution: demote the row to remind, with the tie-break in the message. The rung change is Brad's call.
- **C13. derive floors.** Two reviews propose retiring the step or running it weekly, but Brad ruled on it today (ALREADY-RULED). Leave it.
- **C14. Does measurement.md reach C:\Codex sessions?** "0 of 9" at start and "lazy load in 34 of 35 C:\Codex sessions that edited TC code" are both true. The lazy load needs a Read-tool read of a TC file. That is why method delivery to C:\Codex goes through the User CLAUDE.md.
- **C15. Splitting the memory stores.** One review proposes migration. But the two stores live in different repos (codex-memory vs claude-store), dangling-link ratchets would fire, and the triage agents hard-code C--Codex.
  - Resolution: Brad rules. The interim fix is read-side only (change 2 and name-routing read both stores).
- **C16. Uncommitted brain files.** The offline verifier saw 13 earlier today; I saw 1 entry (`?? skills/synced/`). The count is fluid, and the structural point stands.
- **C17. The use holdout.** It withholds knowledge 10% of the time, which contradicts both goals. It is also underpowered: about 40 days to reach 150 withheld turns, with a CI of roughly ±5 points. It stays out unless Brad rules otherwise.

## Newly measured

All commands exited 0.

1. **Workflow-agent environment**, measured inside this agent:
   - Command: `env | grep -E '^(CLAUDE_CODE_SESSION_ID|CLAUDE_CODE_CHILD_SESSION|CLAUDE_CODE_ENTRYPOINT|TC_HEADLESS)='`, with values truncated.
   - Result: `CLAUDE_CODE_SESSION_ID` is the parent's sid (134f2f6e...), `CLAUDE_CODE_CHILD_SESSION=1`, `CLAUDE_CODE_ENTRYPOINT=claude-desktop`, and TC_HEADLESS is unset.
   - So commit-msg judges workflow-agent commits, and search.py logs the parent's sid. CHILD_SESSION marks "a child" but not which child; agent_id exists only in hook payloads. The Agent-tool subagent environment was not measured.
2. **Spawn route by month** (file mtime, all history):
   - Command: `find ~/.claude/projects -path '*/subagents/workflows/*' -name '*.jsonl' -printf '%TY-%Tm'`, plus wf_* directories and subagent `agent-*.jsonl` files.
   - Result: Workflow transcripts 324, 994, 24, 20 for June through September; Workflow runs 12, 30, 3, 1; Agent-tool subagent transcripts 40, 446, 209, 563.
3. **Store-citation versions across checkouts:**
   - `git cat-file -p 59d00ae`: REFUSE_FROM "2026-09-25", with only the C--Codex-ThriftyCrew memory dir. HEAD is d7ca8c58b, which reads both dirs.
   - Looping over `git worktree list` with `git hash-object ops/store_citation.py` and HEAD commit age:
     - HEAD commit within 3 days: 8 of 92 checkouts (6 on d7ca8c5, 2 on 59d00ae).
     - Older: 27 on 59d00ae and 57 with no copy.
   - Caveat: HEAD commit time stands in for activity; uncommitted work was not measured.
4. **Brain repo:** 0 non-sample hooks in `~/.claude/.git/hooks`; core.hooksPath unset; no `~/.claude/skills/CLAUDE.md`; no brain rules dir. `git status --porcelain -- skills` showed 1 entry at about 19:20.
5. **Reflex scopes** (in-process read of recall-reflexes.json): 30 rows. Scope blank 23, grocery 4, grocery+board.json 1, meal-prep 2. So 0 rows are scoped to ops/, lib/, graph/, the brain or Fantasy.
6. **Fantasy:**
   - CLAUDE.md is 4,198 B. `.claude/` holds only `scheduled_tasks.lock` and `worktrees/`. There is no rules dir, no git hook, and 0 memory files.
   - First and last transcript timestamps: e2d042b7 (17.4 MB) 08-29 20:10 to 08-30 22:27; 5512eb08 (5.3 MB) 09-01 08:53 to 23:38. Both predate the recall logs, so the "zero rows / touched 09-17" open question is an mtime artifact. ff9d8f1b was not timestamped.
   - 68a71d0d (09-07, 5 minutes) has 8 recall-log rows. All 5 transcripts have 0 session-log rows.
7. **Scheduled sessions and the Stop gate:**
   - The 5 newest C--Codex transcripts that open with `<scheduled-task`: all have entrypoint claude-desktop.
   - Gate rows 90, 1, 0, 7, 16; refusals 3, 0, 0, 1, 1.
   - recall-consulted-skipped.jsonl holds 2 rows in total.
   - So Desktop scheduled runs are judged, and the envelope skip must land before any widening of the gate.
8. **Intent-hook precision on my own calls (an anecdote, not a rate):** 2 injections over 9 described Bash calls, 4 pointers. By my single-rater reading, 1 of 4 answered the call. For "Check whether scheduled triage sessions are judged by the Stop gate" it offered concurrency-craft entry 15 and reliability-craft's "under other names" section.

**Unmeasured, and needed before the plan relies on it** (ranked change 3):
- whether SubagentStart, PostToolUseFailure and InstructionsLoaded fire for Workflow agents;
- whether PreToolUse fires for `tool_name` Workflow and for spawn_task;
- whether a PreToolUse deny on Edit/Write is honoured inside a Workflow agent (a Bash deny is honoured: a reflex block fired in a workflow agent today).

## Ranked changes

Ranking is (value toward the two goals) × (certainty it works) / (implementation risk). Tags: R refuses, V verifies or records, M reminds.

1. **[R] Make the store_citation resolver accept estate knowledge before 2026-09-25** (`C:\Codex\ThriftyCrew\ops\store_citation.py`).
   - Tracked repo paths resolve against the committing checkout's `--show-toplevel` using one `git ls-files`.
   - Normalise `\`, `~/` and absolute path forms.
   - A bare `grocery.md` falls back to `.claude/rules` only after the store bases miss.
   - A staged code file cannot cite itself.
   - Log `cited_kinds` and `rules_without_section`; report them, never refuse on them.
   - The hook prints BLIND when a checkout has no script.
   - Tell Brad about the 2 active stale checkouts.

   Why: in 3 days a refusal goes live that punishes exactly what goal 1 asks for (4 of 56 landed commits; 10 of 53 attempts on 09-22). It has a checkable bar (0 of 56 on a replay bounded at midnight) and touches one file.
2. **[V] One `search.py --estate`.**
   - It searches both memory stores, the main checkout's rules chunked per bold-lead bullet (11 of 99 leads wrap a line), the machinery-header cache, and an unranked `git grep --all-match` leg under its own header.
   - Roots come from `--git-common-dir`.
   - The log row is written before printing and carries the corpus list, cwd and `CLAUDE_CODE_CHILD_SESSION`.
   - The refusal text, the six agent store-steps and the triage task step switch to it.

   Why: pull is the only channel with conversion evidence (18 of 96 searches followed, against 274 of 8,809 offers), and today it cannot see memory, rules or code. It is additive, its legs fail open, and default output stays byte-identical.
3. **[measure] One sandbox harness-event probe.**
   - Run `claude -p --settings <sandbox.json>` from a temp directory with logger hooks only, every RECALL_* path redirected, and TC_HEADLESS unset.
   - Cover:
     - SubagentStart for an Agent-tool agent and a Workflow agent, with a quote test to prove the block reached the child;
     - PreToolUse for `Workflow` and `mcp__ccd_session__spawn_task`;
     - PostToolUseFailure for `exit 42` in a subagent and for a hook deny;
     - an Edit deny inside a Workflow agent;
     - the SubagentStop fields (`agent_transcript_path`, `last_assistant_message`);
     - InstructionsLoaded `load_reason` after a Read vs a Bash `cat` vs a subagent read.
   - Record the results with the CLI version in `claude-code-automation/hooks-measured-payloads.md`.

   Why: changes 4, 7 and 11 and three items below the line depend on these payloads, and the probe carries no production risk.
4. **[R] Search before the first write in each context.**
   - Where: in `recall-reflex-hook.py`, which is already on PreToolUse Edit|Write, so no new process.
   - What it denies: the first Edit/Write in a context (session_id + agent_id) to either
     - a tracked code file (store_citation's CODE_EXT, under a git toplevel, excluding `*/out/`, %TEMP% and scratch), or
     - an analysis record (`design/(PLAN|MEASURE|EVAL|RCA)-*.md`, or `grocery/triage-plans/plan-*.json` excluding routing files),

     when that context has no search marker.
   - The marker: an O_EXCL file `~/.claude/recall-searched/<session_key>`, created by `recall-log-open.py` on a successful search.py run (PostToolUse on Bash/PowerShell). Never shared state.
   - The deny text gives the exact `search.py --estate` line and says "nothing applicable" is an accepted answer.
   - Brakes: at most one deny per context; the second attempt proceeds and is logged, so an agent without Bash cannot loop. Fail open.
   - Rollout: 7 days in shadow, with bars written first (would-deny contexts per day; at most 5 of 50 hand-labelled would-denies out of scope). Then remind. Then deny, on Brad's ruling.

   Why: it enforces the standing CLAUDE.md rule at the one event proven to fire in all seven scenarios. Refusals are measured to be obeyed. Today only 11 of 38 editing subagent contexts search first. The residual risk is ceremonial searches, which named-item rates can measure.
5. **[M then V] Machinery recognition rows in the one reflex engine.** Six remind rows:

   | Construct | Helper |
   |---|---|
   | `Move-Item -Force` | Write-TcAtomicFile |
   | `Add-Content` on a shared log | Add-TcLine |
   | `@()` wrap of `List[object]` | `::new()`, or assign then wrap |
   | filtered recursive walk | `Get-TcTreeFiles -PruneBelow` |
   | fixed %TEMP% name | per-run directory |
   | native redirect under EAP Stop | Invoke-Native |

   - Each row gets `exts` and `except_paths`, and excludes the helper and the gate files.
   - Match against the rebuilt post-edit file and fire only when the site count rises.
   - Copy each `must_fire` from the gate's own MUST FIRE, with a self-test that the literal still exists in the gate.
   - Keep the full-body match text separate from the 2,000-char chash text.

   Why: this is the only edit-time channel that names the helper, and it reaches every context. It is recognition, not similarity, so 2a does not apply. Because it only reminds, and reminders land after the write, promotion rests on its 7-day fire and persisted counts.
6. **[V] Canonical-root fix** in `recall_index`.
   - The memory corpus comes from `git rev-parse --path-format=absolute --git-common-dir`, cached per cwd, bounded at 2 s, failing open.
   - Rules tags stay per worktree.
   - project_key matches the harness sanitiser; past 200 chars, fall back to an existing projects dir.
   - `named_files`, `memory_lint.near_duplicates` and recall-log-open's classifier all use it, and near_duplicates' corpus-relative open is fixed.

   Why: this is a prerequisite for memory routing, for the near-duplicate check (dead everywhere today) and for any memory leg. 42% of TC activity is off the repo root. It is mechanical and fixturable.
7. **[V] Tell the truth about the rules files (option A).**
   - Delete the inert `globs`/`alwaysApply` lines and rewrite each file's "Loaded only when" line.
   - Correct every place that repeats the false claim: claude-code-craft 11.1, claim C3, BACKLOG E14 line 1440, MEMORY.md:94, what-actually-reaches-a-spawned-agent, recall_core.py:546, recall-agent-hook.py:13, knowledge-search SKILL.md:17, and automatic-recall 2a/3a.
   - In the same commit, audit-rule-currency starts refusing globs/alwaysApply. It must accept a paths list or a comma string.
   - Add an InstructionsLoaded logger that writes through recall_append.

   Why: this protects the channel that actually delivers helper names and measurement rules today. It also blocks the likeliest lower-effort regression, a globs-to-paths rename that would silently strip them from Bash-only and agent contexts.
8. **[R] Record-level analysis checks.**
   - The plan audit adds RCA, EVAL, REVIEW and AUDIT prefixes; run it first to confirm zero missing on day one.
   - validate-triage-plan requires a non-empty `knowledge_consulted` for plans named 2026-09-23 or later, excluding `*.routing.json`, and accepting an `rca_document` that carries the section.

   Why: goal 2's refusals only exist at the record, and this extends them to the lane that writes diagnoses daily (3 of 23 recent plans would have failed). It is green on day one.
9. **[M] Deliver the analysis method.**
   - Write `experiment-craft/analysis-preflight.md` as a thin index over MAP.md, adding only the estate-specific items: exit code first, cite the harness blob and never an unlanded hash, the agreeing-number check, an offer, open or pass is not a use, a delegated finding is an input.
   - Add a block of at most 10 lines to `C:\Users\Owner\.claude\CLAUDE.md` pointing at it with absolute paths. It is the one file verified to reach every context.
   - Add an analysis route in recall-hook only after its cue clears a bar on all 137 human prompts, hand-labelled blind to the classifier.

   Why: nothing delivers method today (experiment-craft was offered 4 of 973 times). It is nearly free, but it only reminds.
10. **[R] Push-gate blindness, in this order.**
    1. Fix the readjson walk (prune, exit 3 on zero files, worktree fixture) and tighten full-path-excludes.
    2. Score a static detector that reports `scanned=0` with rc 0 as blind (`zero_ok` per gate). Check worktree logs first, and add the cause to pre-push's table and to CLAUDE.md's "five causes" in the same change.
    3. Lift the named-site ratchet into `lib/ratchet.ps1`, keyed on paths below the root.

    Why: the push tier is the one that reliably refuses (11 reds in 5,011 runs), but it reads green when blind, which is how the one observed goal-1 miss shipped.
11. **[R] Gate the two unchecked spawn routes, after the probe.**
    - A Workflow matcher checks the script: a Knowledge consulted constant must be interpolated into each `agent()` prompt, with comments stripped first. Never use brief-gate's HEAD_RE here, because it denies the one compliant script.
    - A separate spawn_task matcher runs brief-gate only.
    - All routes write a brief-gate log with pass, deny and skip rows.

    Why: the gate works where it runs (4 of 220 briefs before it, 52 of 52 after). Workflow is the ultracode route even though it is quiet now.
12. **[V] Cover the brain.**
    - A tracked commit-msg hook for `~/.claude` that calls ThriftyCrew's store_citation through its git-common-dir, fails open, and prints BLIND.
    - Brain-scoped reflex rows: a log path with no RECALL_* env read; a new state key not in the load_state allow-list; `open(...,'a')` on a recall-*.jsonl file; a self-test env missing RECALL_STATE_DIR.
    - A nightly line listing brain files modified and uncommitted for more than 12 h.

    Why: scenario vii has zero enforcement and its edits go live on save. These are cheap, but they are after-the-fact, hence last.

**Below the line** (plan them; they matter less for the two goals, or wait on a ruling or the probe):
- Skip scheduled-task envelopes, with one shared strip in recall_core for the prompt hook, the correction hook and dream.
- Have the consulted gate count logged prompt offers, and stop counting child pointers.
- Wire PostToolUseFailure into the outcome hook: read `payload['error']` and join on tool_use_id.
- Make save_state retry, sweep old .tmp files, take a lock spanning read-modify-write, and count saves and failures.
- Retry the one inbox batch killed by HTTP 429 (Brad's 73 graph rulings), with the ingest location and reviewer fixed, and point the approvals page at the live store.
- Add a nightly reindex step, and treat ratchet falls as warnings.
- Log every intent-hook judgement with its reason.
- Build the memory semantic leg on a held-out floor, after change 6.
- Exact-citation path routing, in shadow only.
- A SubagentStop absence rung, report-only.
- Brad's rulings: Fantasy commit hook, a hand fix of the C:\Codex table, and the store split.

## Anything the plan must not do

- **Rules scoping.** Do not convert `globs` to `paths` or scope measurement.md or ops-and-gates.md before InstructionsLoaded proves delivery to Bash-only, Agent and Workflow contexts. `alwaysApply: true` is a no-op.
- **Retrieval signals.** Do not re-propose similarity retrieval at edit time (file path or code as the query); the 2a refusals stand. The new signals here are exact recognition, exact citation, and the context's own search action.
- **The chash cap.** Do not raise recall_core's 2,000-char cap. It is the chash join key for three callers. Widen the match text separately.
- **Duplicate machinery.** Do not build a second pattern engine, a second claims register, a third BM25 index, a third copy of project_key or the harness strip, or a second definition of `--estate`.
- **Shared session state.** Do not put new keys there. It loses writes. Use append-only logs or O_EXCL markers. If a key must go there, add it to both load_state's fresh dict and its dict tuple.
- **`record()` for prompt offers.** Do not call it from the prompt hook. It changes the bytes metric and couples to the agent hook.
- **The consulted gate.** Do not widen it before the scheduled skip lands. Do not judge it by footer rate.
- **Brad's calls.** Do not withhold knowledge (the holdout), retire derive-floors, change the set-content rung, move REFUSE_FROM, migrate memories between the two repos, or edit the unversioned C:\Codex\CLAUDE.md by script. Each of these is Brad's.
- **select-first.** Do not exclude search.py from it; fix the log order instead.
- **Day-one reds.** Do not add gates that are red on day one: MEASURE-shape, bullet-size, lib index, Lands-in. Use a cutoff date or a ratchet whose plain run never writes its mark.
- **Order of the push fixes.** Do not land the zero-scan BLIND rule before the readjson walk fix, or without adding its cause to pre-push and CLAUDE.md in the same change.
- **commit-msg environment.** Do not scrub GIT_INDEX_FILE inside commit-msg; pathspec commits use a temp index.
- **The sleep pass commit.** Do not commit without a pathspec in it.
- **Graph ingest.** Do not run it in the main tree or in a worktree without graph.db, and do not let the reviewer default to claude-fable-medium.
- **Memory writes.** Do not write memories from a worktree agent.
- **Rules narrative.** Do not rewrite ops-and-gates narrative into memories; no hook retrieves memories by similarity. Keep the ruling sentences verbatim.
- **HEAD_RE.** Do not reuse it on JS scripts.
- **Store-step blocks.** Do not paste "run search.py" into agents that have no Bash.
- **The search gate's brake.** Do not let change 4 deny more than once per context.
- **Evidence standards.** Do not claim an effect from open rates; an open is not a use.
- **Baselines.** Do not include review or probe sessions in baselines. This review alone added 96 searches under one sid.
- **Fixture isolation.** Do not let fixtures touch live logs, state or the sidecar breaker. Redirect every RECALL_* path, including RECALL_SIDECAR_BREAKER and RECALL_CONSULTED_LOG, and clear TC_HEADLESS and CLAUDE_CODE_ENTRYPOINT where a MUST NOT FIRE case depends on them.
- **Workflow assumptions.** Do not assume Workflow stays rare. Do not build Workflow-only primers before the probe.