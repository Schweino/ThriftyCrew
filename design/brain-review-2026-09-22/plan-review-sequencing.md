# sequencing, dependencies and conflicts

The phase order is right in outline: the record fix comes first, then instruments, reach, search, shadow, and refusal last. But section 6's claim that "Items in one row are independent unless the Needs column says otherwise" is false in rows 5 and 6. Several items also write to a file, a gate or a log that an earlier or later item depends on, and nothing tells the implementer.

Six problems would produce a harmful or wrong build, and a lower-effort implementer would miss each one:
- W3.4's command sweep breaks the push gate that W5.2 adds (audit-agent-tools RULE 3).
- Editing a scheduled-task SKILL.md the way W3.4 and W5.2 describe makes audit-prompt-backup red for every checkout on the box.
- Once W4.5 installs the brain commit-msg hook (after REFUSE_FROM), it refuses the very citations section 4 tells every commit to carry.
- W4.1's deny text lacks the reflex deny marker. After W6.1 wires PostToolUseFailure, its denies are logged as `burned` against the reflex rows that fired on the same call.
- W4.1 and W4.3 mode files have no environment redirect. The hook self-tests run a child process, so a deny-mode fixture has to flip the live, box-wide mode file.
- W6.4 step 1 runs graph ingest in the main tree, which the critic's guardrail forbids.

Several bars also cannot be computed when the plan schedules them, or can pass trivially:
- M1 is ambiguous about the denied first attempt, and the subagent transcript reader it needs is scheduled after the measurement window.
- W3.2's bar has no scorer until W3.3 exists.
- W0.1's replay bar passes trivially through `repo_blind`.
- W6.6's exclusion list lands last, although every earlier bar needs it.

Checked and found consistent, so not flagged:
- BM25 statistics are computed per corpus (recall_index.py:516-525), so W3.1 re-chunking cannot move skills offers.
- recall_append.append_rows already exists, so W1.3-W1.7's stated need for W2.4 is harmless.
- search rows already carry `flags` (search.py:1056), so W3.3's bar can be computed.
- Every D-number cited by an item exists in section 9.

## [high] W3.4 (with W5.2)
W5.2 (order row 6) adds audit-agent-tools RULE 3: every agent's store-step must be byte-identical to ops/agent-blocks/store-step.md. W3.4 (row 7) then rewrites the six agents' store-steps to `--estate`, but its Where list omits ops/agent-blocks/store-step.md. An implementer who follows the list edits the six agents and their mirrors, and RULE 3 goes red on every push. W5.2's own step 1 says CODE becomes '--estate once W3.4 lands', so the plan expects the change but never assigns it.

EVIDENCE: Plan lines 644-653 (W3.4 Where: brief-gate HOW, store_citation refusal, six agent store-steps and mirrors, grocery-alert-triage SKILL.md, knowledge-search SKILL.md, CLAUDE.md, W4.1 deny text; no ops/agent-blocks). Plan line 953-955 (canonical file, 'with --estate once W3.4 lands') and 964-966 (RULE 3 byte-identical). ops/run-gates.ps1:269 runs ops\audit-agent-tools.ps1 on every push.

FIX: Add to W3.4's Where list, as the first bullet: "- `ops/agent-blocks/store-step.md`, BOTH variants (CODE and ANALYSIS), in the SAME ThriftyCrew commit as the six agent store-steps, their `ops/prompt-backup/agents/` mirrors and every other agent that carries a variant. Before committing, run `powershell -NoProfile -File ops\audit-agent-tools.ps1` and read exit 0 and its AUDIT-AGENT-TOOLS-COMPLETE line." In W5.2 step 1, replace "with `--estate` once W3.4 lands" with "today's text; W3.4 later changes this file and every copy in one commit".

## [high] W3.4 and W5.2 step 5 (scheduled-task SKILL.md edits)
The live copy of a scheduled-task SKILL.md is C:\Users\Owner\.claude\scheduled-tasks\<task>\SKILL.md, and every checkout shares it. audit-prompt-backup is a push gate that compares that live file with THIS checkout's ops\prompt-backup\scheduled-tasks\<task>\SKILL.md. So editing the live file makes every checkout that has not rebased onto the new mirror read STALE BACKUP (exit 2), and their pushes are refused. W5.2 step 5 has the direction backwards. It says to land on main and let -SyncScopes carry the user-scope copy, but -SyncScopes touches agents only; for tasks, -SyncMirror copies live to mirror, so a mirror-only edit stays STALE. It also says to 'extend audit-prompt-backup coverage to scheduled-task SKILL.md', which already exists. The digest meant: extend RULE 3's canonical-text check to them.

EVIDENCE: ops/audit-prompt-backup.ps1:13, 35-38 (-SyncScopes is project to user scope; -SyncMirror is live to prompt-backup), 57-58 ('Scheduled-task SKILLs ... their live copy is shared by every tree'), 205-212 (task coverage and STALE BACKUP already exist), 327-338 (task sync is live to mirror only). ops/run-gates.ps1:319 runs it on every push. digest-agent-tier.md:182 ('Extend audit-prompt-backup coverage ... the same way', meaning the RULE 3 byte-identity check).

FIX: Replace W5.2 step 5 with: "Scheduled tasks: the live file `C:\Users\Owner\.claude\scheduled-tasks\<task>\SKILL.md` is canonical and is shared by every checkout. Edit it and `ops\prompt-backup\scheduled-tasks\<task>\SKILL.md` to identical bytes in the same minute. Commit the mirror in a clean seeded worktree and land it at once through `ops\push-main.ps1`. Then name in the commit message that sibling checkouts will read STALE BACKUP until they rebase. -SyncScopes does not touch scheduled tasks. Extend audit-agent-tools RULE 3 (not audit-prompt-backup) to check each task SKILL.md that carries a store-step against ops/agent-blocks/store-step.md." Give W3.4's `scheduled-tasks/grocery-alert-triage/SKILL.md` bullet the same procedure by reference ("per W5.2 step 5").

## [high] W4.5 (with W0.1 and section 4)
Section 4 requires every code commit's Store: line to cite this plan and the store sections the item names, which include .claude/rules/*.md. W4.5 lands in order row 8, after REFUSE_FROM 2026-09-25, and makes brain commits run ThriftyCrew's store_citation. W0.1 resolves repo tokens only against the COMMITTING checkout's `git ls-files`, and for a brain commit that is ~/.claude. So `design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md` and `.claude/rules/measurement.md` both fail to resolve, and every later brain item that follows section 4 (W5.4-W6.14) is refused. A bare `measurement.md` falls back to ~/.claude/.claude/rules, which does not exist either.

EVIDENCE: Plan lines 189-190 (cite this plan; W0.1 makes rules and design resolve), 211-218 (W0.1: root from show-toplevel, tracked set from ONE ls-files), 881-883 (W4.5 calls C:\Codex\ThriftyCrew\ops\store_citation.py from the brain repo). store_citation.py:136-139 (store bases are skills, ~/.claude and the memory dirs only), 50 (REFUSE_FROM 2026-09-25).

FIX: Add a step to W4.5 before step 1: "0. In store_citation.py, when the committing toplevel is not a ThriftyCrew checkout, also resolve repo-relative tokens against the tracked set of the estate root. That root is the `default` entry of knowledge-search/estates.json (W3.3), or C:\Codex\ThriftyCrew when the file is absent, taken from one `git -C <root> ls-files` call with the inherited env removed only for that child. Record `resolved_in: estate` in the decision row. Fixtures, on a temp brain repo plus a temp estate repo: MUST NOT FIRE, a brain commit citing `design/PLAN-x.md` and `.claude/rules/r.md` that are tracked in the estate repo passes. MUST FIRE, a token tracked in neither repo is refused. CLEAN TWIN, `knowledge-search/automatic-recall.md` still resolves through the skills base." Change W4.5's Needs to "W0.1, W3.3's estates.json", and do not install the hook until this step lands.

## [high] W4.1 deny mode x W6.1 (and W4.2 rows)
W6.1 step 1 decides `blocked` with the existing deny-marker test: the first line of recall_reflex.deny_reason. W4.1's deny reason starts 'First code change in this context...', which does not match. So once W6.1 registers the outcome hook on PostToolUseFailure, every W4.1-denied Edit/Write (if W1.1 shows the event fires for hook denies) is logged as `burned` and joined by tool_use_id to every reflex row that fired on that call. W4.1 step 4 runs the W4.2 machinery rows on exactly those calls, so the machinery rows collect false burns. That corrupts the ladder, the W4.2 promotion bar and W6.2. This estate paid for the same shape before: 173 of pipe-then-exit-code's 222 'burns' were its own blocks.

EVIDENCE: Plan line 1082-1084 (W6.1: 'The deny-marker test decides blocked'); plan line 688 (W4.1 deny text). recall-reflex-outcome-hook.py:94-97 (marker = deny_reason([]) first line; blocked = failed and marker in err). recall_reflex.py:733-734 (marker 'This estate has paid for this one before, so it is a block rather than a reminder:'). recall-reflex-outcome-join.py:312-319 (173 of 222 precedent).

FIX: Add to W4.1 step 6: "Every deny this item emits also appends its tool_use_id to the first-write log with `decision: deny`. The fire rows written for that call carry `acted: \"first-write-deny\"` and do not increment state['reflexes']; the redo after the search is the fire that counts." Add to W6.1 step 1: "A failure whose tool_use_id is in the first-write log with decision deny logs verdict `first-write-deny`, never burned or blocked, and is never attributed to a reflex row. Fixture MUST FIRE: a PostToolUseFailure carrying W4.1's deny text and a tool_use_id present in a temp first-write log logs first-write-deny. CLEAN TWIN: the reflex deny text still logs blocked."

## [high] W4.1, W4.3 (mode files) and section 4 / W2.4 step 4 (redirected_env)
The hook self-tests run the hook as a CHILD process, and redirect it only through environment variables. W4.1's fixtures need deny mode and remind mode, but its mode file ~/.claude/recall-first-write.json has no env var. The only way a fixture can set deny mode is to write the LIVE file, which denies the first code write of every session on the box while the suite runs, and for good if it crashes. W4.3 has the same gap for recall-path-route.json, path-routes.json, recall-route-seen/ and recall-path-route-log.jsonl. Section 4 also says redirected_env is 'created in W2.5', and no W2.5 exists (it is W2.4 step 4). redirected_env lands in row 2, before the env vars of rows 3-8 exist, and no later item is told to add its own.

EVIDENCE: recall-reflex-hook.py:299-317 (selftest builds env and runs the hook via subprocess). A grep of the plan for `RECALL_[A-Z_]+` found no env var for either mode file or any W4.3 path; the only W4.1 additions are RECALL_FIRST_WRITE_LOG (line 665) and RECALL_SEARCHED_DIR (line 703). A grep for `W2.5` hits only lines 172 and 175.

FIX: In section 4, replace "created in W2.5" and "Until W2.5 lands" with "created in W2.4 step 4" and "Until W2.4 lands". Append: "Every item that adds a log, marker directory, mode file or cache adds its env var to `redirected_env` in the SAME commit, and redirected_env's selftest asserts that every `os.environ.get(\"RECALL_...\")` name found by grepping recall_*.py and recall-*.py is set." In W4.1 Files, add "(env RECALL_FIRST_WRITE_MODE)" after the mode file. In W4.3 steps 1, 3 and 4, add the env vars RECALL_PATH_ROUTES, RECALL_ROUTE_SEEN_DIR, RECALL_PATH_ROUTE_MODE and RECALL_PATH_ROUTE_LOG. Add a fixture to each: "CLEAN TWIN: after the suite, the live mode file's sha256 is unchanged."

## [high] W6.4 step 1
The step says to re-run the killed batch 'by hand, in the main tree'. The critic's guardrail says the opposite: 'Do not run it in the main tree or in a worktree without graph.db'. The digest explains why: an ingest in C:\Codex\ThriftyCrew writes the tracked exports into the shared main tree, and the 07:00 bot then commits them ungated. The plan's section 8 copied only the worktree half of that guardrail. The plan's 'reviewer model' wording also invites passing a model name, where the digest wants Brad's attribution string.

EVIDENCE: Plan line 1135-1136 and line 1310. critic.md:337 ('Do not run it in the main tree or in a worktree without graph.db, and do not let the reviewer default to claude-fable-medium'). digest-offline-loop.md:65 CRITIQUE (2) main-tree exports and bot commit; (3) reviewer 'Brad via approvals page 2026-09-12'; (4) re-validate each proposal.

FIX: Replace W6.4 step 1 with: "1. Before asking D13, write where the ingest runs and how its exports land. Never run it in C:\Codex\ThriftyCrew: it writes the tracked graph/learning/proposals.json and approved-patches.json into the shared tree, and the 07:00 bot commits them ungated. Never run it in a worktree without graph/sqlite/graph.db, which is gitignored and not seeded. The verdicts file carries `reviewer: 'Brad via approvals page 2026-09-12'` (an attribution, not a model name). Each ruling is re-validated against today's proposal (same id, status still 'proposed', payload hash unchanged), and anything that moved is skipped and named. The argv never contains --apply." In section 8, replace the last bullet's graph clause with "Do not run graph ingest in the main tree, or in a worktree without graph.db."

## [medium] W1.5, W4.1, W4.2, W4.3 (all inside recall-reflex-hook.py main())
Four items insert into one main() with no stated order, and main() has an early `if not hits: return 0` and a single JSON emit.
- W1.5 says 'immediately after query_for'. At that point `fired` and `shadow_n` do not exist yet, because `_log_shadow` returns nothing and fire() runs later.
- A W4.1 check or W4.3 route placed after line 174 runs only on the roughly 4% of writes where a reflex row already fired. This is the bug the file's own shadow-mode comment records.
- W4.3's 'when the decision is not a deny' does not say whose deny.
- W4.1's CLEAN TWIN 'heredoc-writes-a-file still wins' cannot be built. That row is Bash-only and W4.1 acts only on Edit/Write, and no rung can block an Edit anyway.

EVIDENCE: recall-reflex-hook.py:136-141 (query_for), 143-154 (shadow runs before early returns, with the 4% note), 156-175 (fire, promoted, `if not hits: return 0`), 207-209 (decide), 241-281 (one JSON object per call). recall-reflexes.json: heredoc-writes-a-file rung=block tools=Bash. Plan lines 345-346, 681-682, 716, 816-818.

FIX: Add to W4.1 Steps, as step 0 (W1.5, W4.2 and W4.3 cite it): "main() runs in this order: (1) parse, heartbeat, query_for (unchanged); (2) match_text = action_text_for_match (W4.2), chash still from query; (3) _log_shadow, which now returns its row count; (4) hits = fire(match_text) + promoted, with the machinery site-count filter; (5) W1.5 coverage row, with fired = the ids from (4); (6) W4.1 first-write decision; (7) W4.3 route lookup, skipped when (6) denied; (8) `if not hits and no W4.1 or W4.3 text: return 0`; (9) the existing decide, fire-log write and emit. On a W4.1 deny, emit only the deny, whose reason carries the machinery lines. Otherwise emit ONE additionalContext: reflex text, then W4.1 remind text, then routes." Replace the W4.1 CLEAN TWIN about heredoc-writes-a-file with: "MUST FIRE: in deny mode, a Write whose content fires NO reflex row is still denied (this proves step 6 runs before step 8). CLEAN TWIN: a first write whose content trips `get-content-no-encoding` is denied, and its fire row carries acted=first-write-deny." In W1.5, replace "immediately after `query_for` returns an action" with "at step 5 of W4.1's main() order".

## [medium] W4.3 step 2 (Read host in recall-log-open.py)
`classify()` returns None for every estate code path, because it knows only skills, ~/.claude/projects memory and <cwd>/.claude/rules. A Read of lib\json-io.ps1 therefore reaches `if not rows: return 0` and exits. A route host appended after the open-row loop never runs for the files it exists to serve. W1.6 step 3 guards the same trap for its own row, but W4.3 says nothing, and W4.3's fixtures test only the Edit host. So a dead Read host passes every listed case.

EVIDENCE: recall-log-open.py:69-101 (classify), 265-268 (`if corpus is None: continue`), 291-292 (`if not rows: return 0`). Plan lines 816-818 and 831-838 (fixtures name only Edit cases).

FIX: Append to W4.3 step 2: "In recall-log-open.py, the Read host runs immediately after `found` is built and BEFORE the classify loop and its `if not rows: return 0` (line 291), because classify() returns None for estate code." Add a fixture: "MUST FIRE: a PostToolUse Read payload for `C:\Codex\ThriftyCrew\lib\json-io.ps1` writes one shadow route row (recall-log-open --selftest, redirected env)."

## [medium] Section 6 (order and dependencies) and W1.1's consumer list
The table says items in one row are independent unless Needs says otherwise, and that is false in several places:
- W3.3 needs W3.1 (its RULES leg is per-bullet) and W3.2 (its MACHINERY leg).
- W3.2's currency rule ('search.py --estate rebuilds the cache') and its bar (machinery leg hit@3) cannot run until W3.3 exists, so the two are circular.
- W4.1 needs W4.2: its fixture names Write-TcAtomicFile through a machinery row, and it uses action_text_for_match.
- W4.3's Edit host needs W4.1's decision.
- W6.2 needs W1.7 (tool_use_id parity) and W6.1 (subagent transcripts: 79% of code edits).
- W5.5 needs W1.4 plus 7 days, which is not in its Needs.
- W1.1 says 'W4.4, W5.7 and W6.1' read its block. W5.7 needs no probe, while W5.6, W4.1 step 9, W4.5 step 6, W2.3 option B and W1.2's field names do.
- W1.1 and W1.2 share row 2, but W1.2 logs payload fields W1.1 has not yet observed, and both touch the InstructionsLoaded registration.

EVIDENCE: Plan lines 1256-1263 (rows 5, 6, 8, 9; 'Items in one row are independent'). Plan 596-597 (W3.2 currency via --estate), 606-609 (W3.2 bar), 624-628 (W3.3 legs), 681-682 and 706 (W4.1 uses W4.2), 817 (W4.3 host after the decision), 1104-1105 (W6.2 parity on tool_use_id), 299-300 (W1.1 consumers), 1045 and 1054 (W5.6 'after W1.1').

FIX: Replace rows 2, 5 and 6 and the consumer sentence.
Row 2: "W1.1 probe, THEN W1.2 (its field names come from W1.1's observed payload), W2.4 | nothing".
Row 5: "W3.1, then W3.2, then W3.3 | W2.1; W3.3 needs W3.1 and W3.2 | W3.2 exposes `machinery_index.ensure_current(root)`, which W3.3 calls. W3.2's bar is scored after W3.3 lands, through `search.py --estate` with the MACHINERY (index) leg read alone."
Row 6: "W4.2 rows at remind, then W4.1 in SHADOW, then W4.3 in shadow; W5.1-W5.3 | W3.3, W1.6; W4.1 needs W4.2; W4.3 needs W4.1".
Move W6.6 into row 3.
Row 9: "W6.2 needs W1.7, W6.1 and D12b".
In W1.1 'Done when', replace the last sentence with "Items W1.2, W2.3 option B, W4.1 step 9, W4.4, W4.5 step 6, W5.6 and W6.1 read their go/no-go from this block."

## [medium] W4.1 step 6 and fixtures (the command it recommends) vs W3.4
W4.1 lands in row 6 with a deny text and a MUST FIRE fixture that hard-code `search.py --estate`. W3.4 (row 7) makes `--estate` the recommended command 'only if W3.3's bar holds', and it lists 'W4.1's deny text' as something to switch. If W3.3's bar fails, W4.1 still recommends a command the plan has just recorded as opt-in, and W3.4 has nothing to switch. The two items disagree about who decides the command.

EVIDENCE: Plan lines 687-690 and 704-705 (W4.1 text and fixture contain `--estate`); 638-642 (W3.3 bar: otherwise keep it opt-in); 644 and 653 (W3.4 is conditional and includes W4.1's deny text).

FIX: In W4.1 step 6, replace the command line with `<SEARCH_CMD>`, and add: "SEARCH_CMD is read from `knowledge-search/estates.json` key `recommended_command` (default: the plain `search.py \"<terms>\"` form). W3.4 sets it to the `--estate` form in its sweep, so this is the one switch for W4.1." Change the W4.1 MUST FIRE to "the reason contains the configured SEARCH_CMD", and add "CLEAN TWIN: with recommended_command set to the --estate form, the reason contains `--estate`."

## [medium] W4.1 keep-or-revise bar and M1
Under deny, a compliant context goes denied write, then search, then redo. Its first in-scope Edit/Write tool_use (the denied one) comes BEFORE its search, so the transcript definition scores it a failure. M1 then measures only pre-emptive searches and can judge a gate that works as failing. No harness is named or committed, which measurement.md requires for a repeatable measurement. Reading subagent and workflow transcripts (79% of edits) needs W6.1's recall_transcripts iterator, which is scheduled in row 9, after the 14-day deny window of row 8. The shadow producer floor (c) also leans on session-state heartbeats, which W2.4 says lose writes.

EVIDENCE: Plan lines 724-729 (bar text), 1269 (M1 instrument 'transcripts plus W1.6 search-call rows'), 1086-1087 (subagent iterator in W6.1), 1256-1260 (rows 8 and 9). Plan line 723 (heartbeat floor) and 514-518 (state loses writes).

FIX: Replace the first keep-or-revise bullet with: "- Two numbers, from a committed harness `~/.claude/skills/first-write-report.py` that joins the first-write log with W1.6 search-call rows on (sid, agent) and prints its blob. M1a (pre-emptive): search-call before the context's first in-scope write ATTEMPT, a denied attempt included; baseline 11 of 38; reported. M1b (compliant): search-call before the context's first in-scope write that was NOT denied; bar at least 80%, N printed. The transcript cross-check uses `recall_transcripts.iter_transcript_files(include_subagents=True)`, so W6.1 step 2 moves forward to row 3." Replace bar (c) with: "(c) the producer floor: on any day with W1.5 coverage rows for in-scope Edit/Write, first-write rows are at least 1."

## [medium] W6.6 (placement) and section 4 (the exclusion rule)
Section 4 requires every baseline and bar to exclude review traffic and print how many rows it excluded. But the exclusion list and its readers (W6.6) land in row 9, after every bar in rows 3-8 has been computed. That covers W1.3's briefs section, W1.5's recall-stats line, W2.2's open-rate bar, W4.1's shadow bars, W4.2's fire rates and W5.4/W5.5. Each of those will either hand-roll its own exclusion or forget it. The two texts also contradict each other:
- Section 4 excludes 'Session 134f2f6e ... by name'.
- W6.6 warns that excluding the parent sid drops the human's real opens, yet still seeds 'session 134f2f6e and its agent ids'.

EVIDENCE: Plan lines 191-193 (section 4), 1159-1169 (W6.6: 'excluding the parent sid would also drop the human's real opens'; 'Seed it with this review: session 134f2f6e and its agent ids'), 1260 (W6.6 in row 9). W6.6: review traffic was 200 of 295 open rows on 2026-09-22.

FIX: Move W6.6 into section 6 row 3. Replace section 4's bullet with: "Exclude review and probe traffic through ONE file, `~/.claude/recall-audit-exclusions.json` (W6.6, built in row 3). Every report and bar in this plan reads it and prints `excluded N rows`. It lists this review's AGENT ids and the `C--Codex-tc-exp-*` sessions, never the parent sid 134f2f6e, whose human turns are real traffic." In W6.6, replace "session 134f2f6e and its agent ids" with "the agent ids of session 134f2f6e's workflow runs, read from the workflow journal (not the parent sid)".

## [medium] W6.12 (lands after REFUSE_FROM)
judge_message has ONE mode: refuse whenever today >= REFUSE_FROM (2026-09-25). W6.12 comes after W0.1 in row 9, so after that date. An implementer who adds the new escape checks the way the existing branches do (`d.update(verdict=d["mode"], ...)`) refuses from the first commit, with no warn week and no D1b date. The banner would also print 'WARNING (refused from 2026-09-25)' for a date already past.

EVIDENCE: store_citation.py:50 (REFUSE_FROM), 146 (`"mode": "refuse" if today >= REFUSE_FROM else "warn"`), 156, 162 and 164 (every failing branch uses d["mode"]), 232 (banner). Plan lines 1225 and 1317.

FIX: Add to W6.12: "Add a constant `ESCAPES_REFUSE_FROM = None` beside REFUSE_FROM, with the comment 'Brad sets this (D1b); None means warn only'. The three new checks set `verdict = 'refuse' if ESCAPES_REFUSE_FROM and today >= ESCAPES_REFUSE_FROM else 'warn'`, never d['mode'], and their banner reads 'WARNING (escape form; refuse date not yet set)'. Fixture MUST NOT FIRE: on 2026-09-30, a Store: line citing only `CLAUDE.md` yields verdict warn, not refuse. CLEAN TWIN: the existing missing-Store:-line case on 2026-09-30 still refuses."

## [medium] W0.1 (bar, trap text and case count)
Three problems.
(1) Step 7 accepts every repo token with `repo_blind: true` when ls-files cannot be read. A replay harness that calls judge_message without a tracked set therefore reaches '0 of 56' vacuously, an agreeing number. The set also grows past 56 while it waits.
(2) The trap says a bare `CLAUDE.md` must not resolve to the repo file. But it already resolves today, through the ~/.claude store base (C:\Users\Owner\.claude\CLAUDE.md exists). An implementer who 'fixes' it lands W6.12's index-file refusal early, with no warn week and no D1b date.
(3) `expected = 24` is bumped only in W0.1. W0.2 (optional case), W4.5 step 3, W5.3 and W6.12 all add store_citation cases, and none mentions it.

EVIDENCE: Plan lines 221-222 (step 7), 239-242 (bar), 243-244 (trap), 227 (bump). store_citation.py:136-139 (bases include os.path.dirname(store['skills']), i.e. ~/.claude), 335-338 (exact-count assert fails the suite).

FIX: Replace the bar with: "Replay the Claude-coauthored non-merge code commits on origin/main with `--since=2026-09-20T00:00:00 --until=2026-09-22T23:59:59` through judge_message, with today set to 2026-09-25. Pass each commit's own tracked set (`git ls-tree -r --name-only <commit>`) and changed code files. Bar: 0 refused out of N, where N is printed (56 on 2026-09-22), AND `repo_blind` is false on all N rows. A blind row fails the bar." Replace the trap sentence with: "A bare `CLAUDE.md` already resolves through the ~/.claude store base; leave that alone, because closing it is W6.12's job, under its own warn date." Add to section 4: "Any item that adds a store_citation self-test case bumps `expected` in the same commit (W0.1, W0.2, W4.5, W5.3, W6.12)."

## [medium] W1.6 (search.py log order, and the W4.1 marker it creates)
(1) search.py has four print-and-return paths, and the search row's `paths` field is filled from the printed lines. recall-stats joins `paths` to open rows to compute 'searches followed', the 18-of-96 conversion figure the design rests on. A lower-effort 'log before print' writes the row at the top of _main with `paths: []`. That passes W1.6's only fixture (stdout closed after line 1) and silently zeroes the metric.
(2) W1.6 creates W4.1's marker three rows before its only reader exists. It names no directory env var, filename or fixture, so the writer and W4.1's reader (RECALL_SEARCHED_DIR, `<session_key>.mark`) are never tested together.

EVIDENCE: search.py:1085-1096 (log in finally, after printing), 1165-1166, 1202-1203 and 1226-1227 (returned is filled per path). recall-stats.py:139-167 (followed = an open of one of the search's `paths` within the window). Plan lines 367-379 (W1.6 steps and fixtures: no marker case) and 674-676, 703 (W4.1 marker contract).

FIX: Replace W1.6 step 1 with: "`knowledge-search/search.py`: on each of the four result paths, compute the result lines, then write the log row with `paths` taken from those lines, then print. The row gains `corpus`, `cwd` and `child`." Add a fixture: "CLEAN TWIN: the logged `paths` equal the paths printed, for a plain query and a `--files --multi` query." Move 'Also create the W4.1 marker file here' out of W1.6 step 2 into W4.1 step 2, landing in W4.1's commit, and add: "Fixture (recall-log-open --selftest): MUST FIRE, a Bash search.py payload with agent a1 creates `$RECALL_SEARCHED_DIR/<session_key>.mark`. MUST NOT FIRE, `cat ...search.py` creates none."

## [medium] W6.2 (control arm) with W4.1 deny
The shown/shadow split withholds the machinery reminder on half the fires. But W4.1 step 4 puts the same machinery lines into its deny reason on every context's first write, whichever arm the call falls in, so the shadow arm is shown the helper anyway. The denied write and its redo are also two tool_use_ids to the same path. Counted by 'a later Edit by the same (sid, agent) to the same path', the redo scores 'persisted' for the denied call. W6.2 reads 'transcripts' without naming the subagent-aware iterator, so it would see about 21% of code edits.

EVIDENCE: Plan lines 681-682 and 692 (W4.1 deny text lists the machinery hits), 1101-1108 (W6.2 first signal and parity split), section 2 table (Agent-tool subagents hold 3,567 of 4,516 code edits).

FIX: Add to W6.2: "Excluded from both arms: any call whose tool_use_id is in the first-write log with decision deny, and the redo that follows it. During the window, W4.1's deny reason omits the machinery lines for shadow-arm tool_use_ids (the same sha1 parity). Read transcripts only through `recall_transcripts.iter_transcript_files(include_subagents=True)` (W6.1 step 2). Needs: W1.7, W6.1 step 2, D12b."

## [medium] W6.1 step 3 (harvesters read subagent transcripts)
Switching recall-tool-probes to the subagent-inclusive iterator changes the probe corpus that `recall_reflex.py --rate` and every row's max_fire_rate cap are scored on. Subagents hold 79% of code edits, so each row's rate moves, including W4.2's six 2%-capped machinery rows. The nightly gate classes a cap breach as broken, which was a cause on 4 of 5 recent red nights, and that bears directly on W6.3's bar. W4.2 re-runs --rate for every row when it changes the probe size. W6.1 changes the population and says nothing.

EVIDENCE: Plan lines 789-791 (W4.2: re-run --rate for EVERY row, 'Otherwise a row goes TOO LOUD with nobody touching it'), 1088-1089 (W6.1 step 3), 1126-1127 (W6.3 bar). digest-offline-loop.md:70 (cap breach on 4 of 5 red nights).

FIX: Append to W6.1 step 3: "In the same commit, re-run `recall_reflex.py --rate` for EVERY row against the new probe corpus. Record before and after, with the corpus fingerprint and the probe count by origin (main, subagent, workflow). A row that crosses its max_fire_rate goes to Brad as a finding. Never raise its cap to make the night green."

## [medium] W5.4 route offers x W5.7 consulted-gate count
W5.4's analysis route writes ordinary `ev=offer` rows that carry `route: 'analysis'`. W5.7 step 1 arms the Stop gate by counting every `ev=offer` row for (sid, turn, no agent). So after W5.4, every analysis-routed turn arms the gate. W5.7's estimate of 'about 15 refusals a week' and its named-items metric were derived before this route existed. W5.4 carves the route out of recall-stats, recall-forget and recall-brain, but not out of the consulted gate.

EVIDENCE: Plan lines 1014-1016 (route offer rows; recall-stats, recall-forget and recall-brain separate them), 1063-1067 (W5.7 counts ev=offer rows; expects about 15 a week). Order: W5.4 in row 8, W5.7 in row 9.

FIX: Add to W5.7 step 1: "Count route offers (`route` present) separately as `offered_route` and do NOT arm on them alone: a fixed method pointer is not a retrieved claim the reply must account for. Fixture MUST NOT FIRE: a turn whose only offer row carries route 'analysis' does not arm. CLEAN TWIN: a turn with one retrieved offer still arms." If Brad wants route offers to arm, make that a sub-question of D4.

## [low] W5.1 step 4 before D6; W4.4 hook-table parity; D-register gaps
W5.1 sits in row 6, but its step 2 (the CLAUDE.md block) waits on D6. Its step 4 check-skills static check ('the block exists') fails every nightly run if it lands before Brad approves step 2. W4.4 adds a new `recall-workflow-gate-hook.py`, and check-skills fails when an installed recall-*.py is missing from automatic-recall.md section 2's table. W4.4 does not say to add the row in the same commit (W1.2 does). D10 and D11 have no work item that acts on a 'yes'. Two Brad touchpoints have no D-number: W1.1 step 2 (a temporary box-wide settings.json hook) and W5.4 step 4, which reverses the written 'NO PER-SESSION DEDUP ON THIS EVENT' decision at recall-hook.py:695.

EVIDENCE: Plan lines 940-946 (W5.1 steps 2 and 4), 1323 (D6). check-skills.py:2270-2296 (installed recall-*.py names must equal the table's). Plan line 854 (new hook name), 1327 and 1329 (D10, D11 'none'), 288-292 (W1.1 step 2), 1017-1018 (W5.4 dedup reversal).

FIX: W5.1 step 4: prefix with "Lands in the same commit as step 2, after D6; until then land steps 1 and 3 only." W4.4 Workflow bullet: add "Add `recall-workflow-gate-hook.py` to the automatic-recall.md section 2 table in the same commit (check-skills asserts parity)." Section 9: add "D17 | Approve the temporary box-wide probe hooks of W1.1 step 2 | yes, logger only, removed the same session | W1.1 step 2" and "D18 | Per-session dedup for the analysis route, reversing recall-hook.py:695's written decision for that route only | yes | W5.4 step 4". For D10 and D11, write "no item: a 'yes' needs its own work item" in the Blocks column.

