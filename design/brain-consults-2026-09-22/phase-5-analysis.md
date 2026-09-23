# Phase 5 - goal 2, analysis

Part of `design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md`. Read its sections 4, 6 and 8, and your item's row in section 5, first. An evidence
id "x/y" resolves to `design/brain-review-2026-09-22/digest-x.md`, finding y. W4.2 already covers analysis RECORDS at
their first write, including ones written through PowerShell. This phase covers the method, the agents, the records'
content, and chat answers.

## W5.1 The analysis method is delivered everywhere, as a pointer

**Repo:** both. **Lands via:** `~/.claude` commit (steps 1, 2 and 4); push-main (step 3, the measurement.md line).
**Effort:** S. **Brad:** D6, for step 2.

**Why.**
- Retrieval follows topic words, not method. experiment-craft was offered 4 of 973 times, and on 0 of 14 regex-selected
  human analysis prompts. A method section from another domain was offered on 5 of those 14.
- measurement.md reaches C:\Codex-cwd sessions only after a Read of a ThriftyCrew file.
- The global CLAUDE.md is the one file verified to reach every context.
(analysis-path/analysis-method-not-delivered, codex-cwd-sessions-lack-analysis-rules)

**Steps.**
1. New `~/.claude/skills/experiment-craft/analysis-preflight.md`, headed `# The analysis preflight`, at most 40 lines.
   It is a THIN index: it cites experiment-craft MAP.md's pre-registration lines and "the five things that travel with a
   delta", and adds only what MAP.md lacks. Each item links to its depth (measurement.md, the memory, or the MAP
   section):
   - exit code first, tally second;
   - a rate with its denominator AND its coverage, declines and skips counted;
   - the bar in the metric's units, written before the run;
   - one row per case per arm, with totals derived from them;
   - name the harness and its blob, never an unlanded hash;
   - an agreeing number gets the same check as a surprising one;
   - count distinct inputs, and say how many variants were tried;
   - an offer, an open, a search or a pass is not a use; a delegated finding is an input;
   - an estate identifier may be namespaced (`commodity:staple:<id>`), and a bare id returns an agreeing zero.
2. A block of at most 10 lines in `~/.claude/CLAUDE.md`, directly under "Every quality verdict carries its rubric and
   its context".
   - Head it `ANALYSIS PREFLIGHT`, with one line per top item.
   - End it with the absolute forward-slash paths to analysis-preflight.md and to
     `C:/Codex/ThriftyCrew/.claude/rules/measurement.md`.
   - No em dashes.
   - It is Brad's file, so he approves the exact lines (D6).
3. In ThriftyCrew, measurement.md gains a first body line linking to the preflight. It stays unconditional.
4. **Lands in the same commit as step 2, after D6:** a static check in check-skills. The block exists, has at most 10
   lines, contains no em dash, and every absolute path in it resolves. Do not "check that it loaded": it loads whole or
   not at all. Until D6, land steps 1 and 3 only.

## W5.2 Verdict and analysis agents carry the analysis store-step

**Repo:** both. **Lands via:** ThriftyCrew push-main; scheduled tasks by procedure P3. **Effort:** S.

**Why.**
- The store-first block is one 1,432-char text in 6 of 13 agent definitions, and it is worded for code ("a finding that
  proposes code").
- It is missing from recipe-batch-auditor, recipe-dedup-selector, recipe-source-qa, recipe-hunter-pricer,
  recipe-hunter-extractor, recipe-sourcer and recipe-writer.
- It is also missing from 5 of the 6 enabled or paused scheduled tasks.
(agent-tier/store-step-code-only-and-sparse; plan-review-compliance)

**Steps.**
1. Put the canonical texts in a new `ops/agent-blocks/store-step.md`. It must NOT go in `ops/prompt-backup/`, which is a
   managed mirror. Two variants:
   - **CODE** is today's text with its command line replaced by the section 4.7 string WITHOUT `--estate`, and its
     Store: example replaced by W0.1's (`Store: .claude/rules/ops-and-gates.md ("..."); lib/atomic-write.ps1 (reused)`),
     which resolves once W0.1 lands. Today's
     `%USERPROFILE%` form fails in both shells when launched without cmd, and the backslash interpreter path fails in
     Bash (exit 127).
     - In the SAME ThriftyCrew commit, paste it into the six agents that carry the block today (commodity-registrar,
       post-publish-reviewer, recipe-ingredient-mapper, triage-developer, triage-ops-developer, triage-reviewer).
     - Change `scheduled-tasks/grocery-alert-triage/SKILL.md:17` the same way, through procedure P3.
     - W3.4 later adds only `--estate`, to this file and every copy together.
   - **ANALYSIS** reads: "Before you diagnose, measure, compare, audit or return a verdict, search:
     `<the section 4.7 command>`. Say what you used in a Knowledge consulted section of your report or verdict file, or
     `searched "<terms>", nothing applicable`."
2. Every one of the 13 agents is named in this step or in step 3:
   - **ANALYSIS:** recipe-batch-auditor (its Write is a verdict file, so ANALYSIS only), recipe-source-qa,
     recipe-hunter-pricer, and recipe-sourcer (all have Bash). Also triage-reviewer, commodity-registrar and
     post-publish-reviewer, beside their existing CODE block.
   - **Allow-listed, with a reason:** recipe-hunter-extractor (Bash, but transcription only: no code, no verdict).
   - **Keep CODE:** recipe-ingredient-mapper, triage-developer and triage-ops-developer.
3. recipe-dedup-selector and recipe-writer have no Bash. Allow-list them with the reason "no Bash: the dispatcher must
   paste excerpts". The dispatcher-side excerpt (hunt_dispatch builds the brief in Python) is a separate follow-on.
4. **`ops/audit-agent-tools.ps1` RULE 3, in the SAME commit.** Keep the existing `AGENT-TOOLS-COMPLETE` marker.
   - Every agent carries a variant byte-identical to the canonical text (LF-normalised, `[string]::Equals` Ordinal), or
     sits on the named allow-list with a reason.
   - The verdict-only agents carry ANALYSIS.
   - An agent without Bash whose block says "run search.py" is refused.
   - RULE 3 also reads every `ops/prompt-backup/scheduled-tasks/*/SKILL.md` that carries a store-step, and holds it
     byte-identical to a canonical variant under the same allow-list rules.
   - Run it over the real `.claude/agents` and task mirrors before landing, and put `agents=13 carried=N
     allow-listed=M failing=0 tasks=T carried=K failing=0` in the commit message.
   - **In the SAME commit, refresh the agent mirrors:** run `powershell -NoProfile -File ops\audit-prompt-backup.ps1
     -SyncMirror` in the worktree, stage `ops/prompt-backup/agents/*.md` beside the agent files, then run
     `ops\audit-prompt-backup.ps1` and read exit 0. The user-scope copies in `~/.claude/agents` follow main through the
     daily -SyncScopes. Never run -SyncScopes from the worktree.
5. **Scheduled tasks** (procedure P3). Edit the LIVE `C:\Users\Owner\.claude\scheduled-tasks\verify-board-sample\SKILL.md`
   and `...\store-usage-weekly\SKILL.md` to carry ANALYSIS, and land their mirrors at once. verify-board-sample was
   untracked in the brain repo on 2026-09-22 (P3 step 0 handles that). audit-prompt-backup already compares mirrors, so
   add no second mirror check.

**Fixtures.** MUST FIRE: one word changed (drift). MUST FIRE: a verdict agent with only CODE. MUST FIRE: a no-Bash agent
whose block says "run search.py". CLEAN TWIN: the canonical block passes. MUST NOT FIRE: an allow-listed agent.

## W5.3 Analysis records must say what they consulted

**Repo:** both. **Lands via:** push-main (store_citation, validator, README, and the recall_core mirror in a
`~/.claude` commit); the live SKILL.md by procedure P3. **Effort:** S.

**Why.**
- The triage lanes write diagnoses daily. 4 of 23 non-routing plans dated 2026-09-19..22 record nothing about what was
  consulted: plan-2026-09-20-4, -5, -6 and plan-2026-09-21-5.
- A fifth, plan-2026-09-22-2, has no field but links an RCA document that has the section.
- `validate-triage-plan.ps1` checks nothing about knowledge.
- No schema or instruction names the JSON field.
- The plan audit judges only PLAN- and MEASURE-.
(agent-tier/triage-plan-knowledge-unchecked; record-tier/plan-audit-scope; plan-review-evidence)

**Steps.**
1. **`ops/store_citation.py`.** Define `ANALYSIS_RECORD_PREFIXES = ('PLAN','MEASURE','EVAL','TRIAL','RCA','REVIEW',
   'AUDIT','FINDING','FINDINGS','PROBE')`, and build PLAN_RE's prefix from it, keeping the dated-name requirement.
   - Run the audit over the tree first, and put `judged=N missing=0` in the commit message.
   - Section tokens stay presence-only. Any resolution prints WARN lines only, and normalises backslashes first.
   - Mirror the tuple as `recall_core.ANALYSIS_RECORD_PREFIXES`, with a comment naming this source.
   - Bump `expected`.
2. **In the SAME landing, before the cutoff:**
   - add `knowledge_consulted` (a string or a list; entries as in step 3) to the schema in
     `grocery/triage-plans/README.md`;
   - change `~/.claude/scheduled-tasks/grocery-alert-triage/SKILL.md:20`, which asks for a markdown "Knowledge
     consulted section", so it also names the JSON field for plan files. Use procedure P3.
3. **`grocery/validate-triage-plan.ps1`.** The cutoff is a literal constant, `$KcCutoff = '<landing date + 1>'`, like
   store_citation's PLAN_CUTOFF, never computed from Get-Date. It judges only plans whose FILE-NAME date is on or after
   `$KcCutoff`, and excludes `*.routing.json`.
   - Read with the validator's existing `Read-TextFile` and ConvertFrom-Json.
   - The test, with the rca_document case checked BEFORE the refusal:
     `$p = $o.PSObject.Properties['knowledge_consulted']; if (-not $p -or $null -eq $p.Value) { if (<the plan's rca_document names a tracked doc carrying a Knowledge consulted section>) { <accept> } else { <refuse> } }; $k = $p.Value; $items = @(@($k) | Where-Object { $_ -is [string] -and $_.Trim() })`.
     Refuse when `$items.Count -eq 0`.
   - An entry passes when it contains any of:
     - a `<dir>/<file>.md` token;
     - a `.claude/rules/<file>.md` token;
     - `memory:<slug>`, a double-bracketed slug, or `memory <slug>` naming a file in either store;
     - a match for store_citation's NOTHING_RE.
     Current plans write "memory <slug>" and prose holding `reliability-craft/MAP.md`, and both pass.
   - Run the rule over every plan dated 2026-09-19..22 before landing, and put `judged=N refused=R` in the commit. R may
     count only the 4 known-empty plans.
   - Refuse through the validator's existing exit 2 problems list, naming the field and how to comply.
   - WARN, never refuse, when a memory entry resolves in neither store, or in the other store than the one it names.
     That is the `registrar-2026-09-22.json:217` provenance case.

**Fixtures.**
- The case AT the cutoff with no field is refused; the day before passes.
- MUST FIRE: `"knowledge_consulted": null`.
- MUST FIRE: `""`.
- MUST FIRE: `[""]`.
- MUST FIRE: `[]`.
- MUST FIRE: a prose-only entry.
- MUST NOT FIRE: a routing file.
- CLEAN TWIN: a frozen copy of a current plan passes.
- CLEAN TWIN: the rca_document shape passes.
- CLEAN TWIN: an existing PLAN doc still passes store_citation's audit.

## W5.4 Analysis prompts get the preflight routed, if a hand-labelled bar says the cue works

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** M. **Needs:** W2.2, W1.9. **Brad:** D19, for the dedup reversal in step 4.

**Why.** The prompt hook has no idea what kind of task it serves. A fixed route for analysis prompts is RECOGNITION on
prompt text routed to fixed files, modelled on the existing named-subject route ("A NAMED SUBJECT IS ROUTED, NOT
RETRIEVED"). It is not a new similarity signal. (analysis-path/analysis-method-not-delivered; prompt-tier/prompt-tier-has-no-task-kind)

**Steps.**
1. **Labels first, blind to any classifier.** Freeze the human-typed prompts of 2026-09-15..22, after excluding harness
   envelopes, task-notifications, slash commands, the tc-exp arms and W1.9's rows. Print the resulting N: the
   analysis-path mapper counted 137 before those exclusions, and prompt-tier estimates about 160 human prompts.
   - Write the labels to the tracked `~/.claude/skills/knowledge-search/analysis-cases.jsonl`, one row per prompt:
     `{text_sha1, label: analysis|code|other, subclass, labeller, source}`.
   - Keep the prompt TEXT only in the untracked `~/.claude/recall-analysis-cases-text.jsonl`, keyed by text_sha1. The
     brain repo deliberately keeps transcript text out of git.
2. **The classifier.** `recall_analysis.classify(prompt)` returns `'difference' | 'diagnosis' | 'decision' | None`. It
   works on the STRIPPED prompt (W2.2), uses word-bounded cue tables, and lets an operation verb at the head win (as
   `recall_intent.OPERATION_RE` does).
3. **Bar (written now).** Over that N: recall on the hand-labelled analysis prompts of at least 75%, and fires on at most
   20% of all N. Both are printed as N of M by `classify --rate`.
4. **Only if the bar holds.** In `recall-hook.py`, before `if not picked: return 0`, the route takes ONE slot: the
   `analysis-preflight.md` pointer, plus the subclass pointer if a slot is free. MAX_SECTIONS is 4.
   - Offer rows carry `route: 'analysis'`, and recall-stats, recall-forget and recall-brain separate them. Otherwise a
     routed file with no opens becomes a forgetting candidate within days.
   - Dedup once per subclass per session, through an O_EXCL marker `$RECALL_ANALYSIS_ROUTE_DIR/<session_key>.<subclass>`
     (env RECALL_ANALYSIS_ROUTE_DIR, default `~/.claude/recall-analysis-route/`, added to `redirected_env`). That
     reverses the hook's written "NO PER-SESSION DEDUP ON THIS EVENT" for this route only (D19). Say so in the code.
   - Never call `record()` from the prompt hook (section 8): the route writes offer rows only.

**Fixtures.**
- MUST FIRE: "Why did this take over 30 minutes?" gives diagnosis.
- MUST FIRE: "did the new matcher improve recall?" gives difference.
- MUST FIRE: "Is the juice worth the squeeze?" gives decision.
- MUST NOT FIRE: "Commit and push the change".
- MUST NOT FIRE: "Read QUEUE-4.md".
- MUST NOT FIRE: an attributed scheduled-task block containing "review" and "why".
- CLEAN TWIN: "read thresholds-and-filtering" keeps its named-subject slot.
- 5 route offers and 0 opens produce no forgetting candidate.

## W5.5 The intent hook gets an analysis card, after its log has run a week

**Repo:** brain. **Lands via:** `~/.claude` commit (settings.json by procedure P1). **Effort:** S. **Needs:** W1.4
plus 7 days of rows, W4.2.

**Steps.**
1. In `recall_intent.py`, add ANALYSIS_HEAD_RE `^(measure|compare|tally|quantify|estimate|benchmark)\b`, evaluated AFTER
   the operation check. Anywhere-words (rate, baseline, percent) stay behind the operation check, or "Read the ff-carry
   coverage baseline row" starts firing.
2. On kind 'analysis', emit ONE fixed pointer, to analysis-preflight.md, once per session through an O_EXCL marker
   `$RECALL_INTENT_CARD_DIR/<session_key>.analysis` (env RECALL_INTENT_CARD_DIR, added to `redirected_env`), never a
   session-state key. This works with the sidecar down. The intent log row logs kind 'analysis' and `searched` (whether
   a valid W4.2 marker exists).
3. Remove `recall` from SUBJECT_WORDS, and add `\b` to every entry. Without it, `score` matches `underscore`.
4. **Split settings.json PreToolUse[0] into two entries** (procedure P1): reflex on `Bash|PowerShell|Edit|Write`, intent
   on `Bash|PowerShell`. The intent hook cannot speak on edits (1 of 1,938 carry a description) and spawns a process per
   edit for nothing. Never drop `Edit|Write` from the SHARED entry: that removes the reflex hook from edits.

**Bar (written now).** Take 100 real descriptions drawn by sha1 order from the 7 days before the change, hand-labelled
analysis or mechanical.
- The card's precision must be at least 80%.
- The intent fire rate (calls where is_judgement is True, from W1.4's log) must be at most the pre-change rate plus 2
  points, over the same 7 days. Both are printed as N of M, with MAX_RATE unchanged.
- Write the pre-change rate down before the change. `recall_intent.py:219` records 10.6%.

## W5.6 Helpers' answers are measured before anything refuses them

**Repo:** brain. **Lands via:** `~/.claude` commit (settings.json by procedure P1). **Effort:** S. **Needs:** W1.1
(q5). **Brad:** D4b.

**Steps.**
1. Register `recall-consulted-hook.py` on SubagentStop (procedure P1; add the table row in the same commit).
2. A new branch logs to its OWN file, `~/.claude/recall-subagent-stop-log.jsonl` (env RECALL_SUBAGENT_STOP_LOG):
   `{agent, agent_type, would_refuse_absence, consulted_line, searched, rung}`.
   - The text comes from `agent_transcript_path`, or from `last_assistant_message` if q5 shows it. Never use
     `recall_core.transcript_path`, which returns the PARENT's transcript.
   - For a workflow agent whose last message is a StructuredOutput tool_use, read that tool input as the text.
3. It returns 0 unconditionally. Exit 2 on SubagentStop is not built here.
4. `store-usage-report` prints "helpers whose final message names what they consulted: X of Y".

**Bar before any refusal (D4b).** The absence rung's would-refuse rate over 7 days of subagent final answers is at most
10%, printed as N of M. Workflow agents stay report-only whatever the rate: exit 2 after a StructuredOutput call risks a
second output.

## W5.7 The Stop gates see what the prompt hook offered, and chat analysis is measured

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** S. **Needs:** W2.2, W4.2 (its marker), W5.4 (its
`recall_analysis` module). **Brad:** D4.

**Why.**
- The consulted rung counts `state['offered']`, which only the agent hook writes. It armed on 25 of 223 gate-rowed
  offered turns.
- 6 of its 12 refusals were for pointers only a CHILD saw.
- Footers already appear on 384 of 453 turns where nothing was offered, and named items are rare.
- A chat analysis ("did X improve?" answered with python one-liners) reaches no refusing mechanism at all. It is the
  largest hole in goal 2.
(analysis-path/consulted-gate-blind-to-prompt-offers; record-tier/analysis-record-thin)

**Steps.**
1. In `recall-consulted-hook.decide()`, count `ev=offer` rows in recall-log.jsonl (tail-read about 256 KB) with:
   - sid == payload session_id;
   - turn == `current_turn(payload)[0]`;
   - no agent field;
   - no `route` field.
   Count route offers separately as `offered_route`, and never arm on them alone: a fixed method pointer is not a
   retrieved claim the reply must account for. Stop counting agent-hook child pointers. Log `offered_prompt` on every
   row.
2. **A new rung value, `analysis`, log-only.** `recall_analysis.owes_line(text)` fires on a reply carrying a rate ("N of
   M"), "root cause", "the cause is" or "verdict".
   - Log it with rung `analysis`, never folded into `consulted`, or recall-answer-outcome's per-rung scoring breaks.
   - It also logs `searched` (a valid W4.2 marker exists for this session_key under the same TTL) and `marker_age_s`.
3. **Footer position**, log-only: record whether a footer is among the last 8 non-empty lines and outside ``` fences.
   Also record the contradiction count: "nothing relevant" after at least one open this turn. Change no verdict.
4. **Run a 7-day SHADOW** (`would_refuse` logged, no exit 2). Then D4 offers Brad two refusal shapes for chat analysis:
   - (a) a missing Consulted: or Checked: line;
   - (b) no search in the context, refused once with the same command and brake as W4.2.
   Precision is hand-labelled on 50 analysis-rung fires first.
5. **Report:** "analysis answers with no search in the context: N of M" (M10), and "named items per armed turn". Never
   the footer rate.

**Fixtures.**
- MUST NOT FIRE: a turn whose only offer row carries `route: analysis` does not arm.
- CLEAN TWIN: a turn with one retrieved offer still arms (in shadow, logged would_refuse).
- MUST FIRE: an analysis-shaped reply logs rung=analysis with `searched`.
- CLEAN TWIN: the 35 existing cases are unchanged.
