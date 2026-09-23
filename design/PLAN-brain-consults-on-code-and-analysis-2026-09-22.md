# PLAN: the brain is consulted on every code task and every analysis task, 2026-09-22

Brad, 2026-09-22: *"Whenever we code anything, there should be a hook (or whatever) to reference all our internal
machinery knowledge if its applicable for that code task. Whenever we analyze anything, same concept."* Plan only. It
will be built at lower effort, so every work item is written to be executed without re-deriving it.

**Status: PLAN, nothing built.** This file is the index: the goals, the evidence summary, the design, the working rules,
the order, the metrics, the guardrails and Brad's decisions. The work items live in seven phase files, each small enough
to read in one pass:

| Phase | File | Items |
|---|---|---|
| 0 | `design/brain-consults-2026-09-22/phase-0-store-resolver.md` | W0.1-W0.2 (before 2026-09-25) |
| 1 | `design/brain-consults-2026-09-22/phase-1-instruments.md` | W1.0-W1.9 |
| 2 | `design/brain-consults-2026-09-22/phase-2-reach.md` | W2.1-W2.4 |
| 3 | `design/brain-consults-2026-09-22/phase-3-search.md` | W3.1-W3.4 |
| 4 | `design/brain-consults-2026-09-22/phase-4-coding.md` | W4.1-W4.6 |
| 5 | `design/brain-consults-2026-09-22/phase-5-analysis.md` | W5.1-W5.7 |
| 6 | `design/brain-consults-2026-09-22/phase-6-evidence.md` | W6.1-W6.13 |

**Evidence.** A read-only review ran on 2026-09-22 in two passes, both committed in `design/brain-review-2026-09-22/`:
- nine mappers, each checked by an adversarial verifier, then a completeness critic (`critic.md`, `digest-*.md`);
- five skeptics who reviewed the first draft of this plan (`plan-review-*.md`). The draft was revised against all five.

A citation such as "tool-tier/machinery-rows-absent" means the finding with that id in `digest-tool-tier.md`. Where this
plan and a digest's CORRECTED line disagree, the CORRECTED line is the measured fact and this plan is wrong.

**Implementer: before any item, read sections 4, 6 and 8 of this file, your item's row in section 5 (its Needs), and
the section 9 row of any D-id it names. Then read only your item's phase file.** This plan and its evidence landed on
main together, so a worktree implementer rebases past that commit first.

## Knowledge consulted

- `knowledge-search/automatic-recall.md` 2a (RULED 2026-09-12): edit-time recall by SIMILARITY was measured and refused
  twice. The file path as the query gave hit@3 of 10 of 20, and the code written gave 4 of 20, against a bar of 12. The
  cause is vocabulary: estate code uses estate words, craft sections use craft words. This plan proposes no similarity
  signal at edit time. Its signals are exact recognition, exact citation and the context's own search action.
- `knowledge-search/automatic-recall.md` 7: "any index over the ESTATE" is a recorded open gap (answered by W3.2), and so
  is "whether an injected pointer changes what the model DOES" (section 7 here is honest about it).
- memory `always-on-delivery-is-not-sufficient`: "a lesson prevents nothing until it REFUSES something". Reminds were
  ignored and blocks held, so each goal ends in a refusal with an honest-negative escape.
- memory `apply-the-store-is-checked-at-the-record`, and `ops/store_citation.py`: the Store: line, the plan section, and
  the refuse date 2026-09-25. W0.1 is time-critical because of that date.
- memory `store-in-every-helper-brief`: the brief gate took Agent-tool briefs from 2 of 1,204 carrying a section to 54 of
  54 since 2026-09-19T18:55Z (agent-tier; prompt-tier counted 4 of 220 to 52 of 52 from 09-20). A refusal that names how
  to comply is obeyed. W4.2 copies that shape.
- memory `what-actually-reaches-a-spawned-agent`: CLAUDE.md, rules and the MEMORY.md index reach subagents; skill CONTENT
  does not. The review adds that workflow agents get the same channels.
- `design/MEASURE-store-ab-2026-09-19.md`: two runs of the same arm differed as much as store against no store (2 of 2
  same-arm pairs had a consistent winner). So this plan measures reach and use, never "a commit got better".
- `design/PLAN-brain-efficiency-2026-09-12.md` defect 2: the memory semantic leg is NOT SHIPPED pending a held-out
  floor. This plan does not ship it (W6.8).
- `.claude/rules/measurement.md`: bars before runs, denominators, one row per case per arm, a repeatable measurement
  commits its harness. Every bar here is written now.
- `.claude/rules/ops-and-gates.md`: no gate red on day one; a ratchet's plain run never writes its mark; fixture labels;
  per-run temp paths; a self-test's last line is its verdict; timed waits are branches; the declared lock order.
- `claude-code-automation/hooks-measured-payloads.md` 1 and 5: `additionalContext` reaches context from PreToolUse, but
  for a tool call it ARRIVES AFTER THE CALL HAS RUN, which was observed in this session. Only `deny` and `updatedInput` act
  first. settings.json is re-read live.
- memory `landing-a-push-needs-a-clean-worktree`: ThriftyCrew pushes go through `ops\push-main.ps1` from a clean, seeded
  linked worktree when the main checkout is dirty.
- memory `prompt-backup-audit-red-for-agent-edits-from-a-worktree`: editing a live scheduled-task SKILL before its mirror
  lands reds every other session's push (section 4, procedure P3).

## 1. What "done" means, as properties that can be checked

**Goal 1 (code).** Before the first write of a code file in ANY context, the context has run a knowledge search, or it
has been stopped once and told three things: the exact command, which estate machinery its text already touches, and
which store sections cite that file (once W4.3's routes are live).
- A context is a main session, an Agent-tool subagent, a Workflow agent, a spawn_task child, a scheduled run or a
  headless run, in ThriftyCrew, the brain or Fantasy. Headless runs are subject to Brad's D3b.
- A write is an Edit/Write, or a shell command whose literal write target is the file.
- A code file is `.ps1 .psm1 .py .js .ts .sql .sh` under a git toplevel, never scratch, temp or `*/out/*`.
- The search covers the skills store, the memory stores, the rules (one chunk per bullet), a generated index of the
  estate's own libraries, gates and harnesses, and a grep of tracked code.
- Every later write that re-types a construct that some library's header declares it REPLACES is reminded of that helper
  and its gate by name. That is recognition over the whole generated catalogue, not a hand list.
- The commit's Store: line may cite estate knowledge and is never refused for it.

**Goal 2 (analysis).**
- Every context has the analysis method in its always-loaded instructions (W5.1).
- Before the first write of an analysis RECORD (a design doc whose prefix is in ANALYSIS_RECORD_PREFIXES, or a triage
  plan), the context has searched or has been stopped once, including when it writes through PowerShell.
- Verdict agents and analysis scheduled tasks carry the analysis store-step.
- Triage plans must carry `knowledge_consulted`.
- Chat answers are measured, log-only, for both a missing footer and a missing search in the context. Brad rules on
  whether either refuses (D4).

**Measured, not assumed.** Each goal has a metric with a baseline from the review (section 7). "Done" means the metric
clears its bar, not that code shipped.

## 2. What reaches which context today (verified 2026-09-22)

Code-edit shares are real-repo code Edit/Write, 2026-09-15..22, with the review session excluded (tool-tier, 2,066
edits).

| Context | CLAUDE.md x3 + rules + MEMORY.md index | prompt recall (skills only) | tool-tier reflex/intent | brief gate | Stop gates | commit record | code edits |
|---|---|---|---|---|---|---|---|
| top-level sessions of every kind | yes; rules only by accident (W2.3) | yes | yes | n/a | yes, blind to prompt offers | yes | 494 of 2,066 (24%) |
| worktree session | yes | yes, **no memory corpus** | yes | n/a | yes | per-checkout copy: 57 of 92 checkouts have none | within the row above |
| Agent-tool subagent | yes | **no** | yes | **yes, 54 of 54** | **no** | yes, but the parent's search backs it | 1,572 of 2,066 (76%) |
| Workflow agent | yes | **no** | yes | **no: 0 of 1,297 briefs passed before 09-22** | **no** | yes | 0 outside this review |
| spawn_task child | yes | yes, no memory | yes | **its brief is ungated: 1 of 24 carried a section** | yes | yes | within worktree rows |
| scheduled run (cwd C:\Codex) | global + workspace; C--Codex memory; TC rules only after a Read | 548 of 977 offers, 0 opened | yes | yes | yes | yes | C--Codex-rooted sessions made 555 of 1,825 TC code edits |
| brain edit (~/.claude/skills) | global + cwd project | yes | yes, **0 of 30 rows scoped to it** | n/a | yes | **no hook at all** | 68 in 7 days, 0 injections |
| Fantasy | global + workspace + Fantasy CLAUDE.md | yes | yes, no Python rows | n/a | yes | **no hook; 0 of 5 commits cite** | near zero |

The C--Codex-rooted row overlaps the subagent row: those sessions are mostly scheduled triage runs and their helpers.

The holes that matter most for the two goals:

1. **No context is ever made to search.** Only 11 of 38 Agent-tool editing contexts searched before their first edit,
   even after the brief gate. For comparison, deliberate searches were followed by an open 18 of 96 times before this
   review (18.8%), against 274 of 8,809 offers opened (3.1%). The joins and windows differ, and searches are
   self-selected, so that ratio says nothing about how a FORCED search converts (prompt-tier, OVERSTATED).
   Five scheduled sessions produced 48 of the 94 pre-review search rows in 7 days. 39 of those came from the two
   grocery-alert-triage sessions, whose task file is the only one carrying a search.py step. The rows carry only the
   parent sid, so they include searches by those runs' helpers.
2. **The search a session is told to run cannot see what governs estate code.** `search.py` indexes skills markdown
   only: no memory, no rules, no code. So every `Store: searched X, nothing applicable` is uninformed by construction.
   For the 12 helpers the rules name, search.py put the helper's function name in a top-8 section for 4 of 12
   task-phrased queries, and the owning lib file for 8 of 12 (the hook index: 6 and 9 of 12). A prototype index built
   from lib headers, searched alone, put the owning lib in the top 3 for 10 of 12, but only 5 of 7 on queries not written
   from the headers. Store hit@3 was not measured, so the two are not directly comparable (estate-machinery, OVERSTATED).
3. **Nothing at edit time names the estate helper that replaces the construct being typed.**
   - 0 of 30 reflex rows name one.
   - The reflex window is the first 2,000 chars, and 102 of 110 code Writes are longer.
   - Edit reminders land after the write.
   - Code is also written through shell commands: 614 shell writes of code files, against 10,190 Edit/Write (an unsound
     regex, so a lower bound).
   - 14 of 37 triage plans were first written by PowerShell or Bash, including 6 of 6 by the triage-reviewer, which has
     no Write tool. (tool-tier; plan-review-coverage)
4. **From 2026-09-25 the Store: check REFUSES citations of the estate's own rules, design docs and code.** Replaying
   2026-09-20..22 refuses 4 commits, all for estate citations: 574722dab, 748967ad4, affeb7254 and e5d0a00a1. On 09-22,
   10 of 53 attempts already warned. (record-tier/resolver-refuses-estate-knowledge)
5. **Worktree and subdirectory sessions have no memory corpus in the hooks.** 0 of 97 worktree keys have a memory dir,
   while the harness itself loads the main MEMORY.md (146 of 188 worktree transcripts). The live cost today is small:
   exact-slug routing (4 memory offers ever) and the near-duplicate check. It is a prerequisite, not a large live leak
   (prompt-tier, OVERSTATED).
6. **Analysis method is almost never delivered or checked.**
   - experiment-craft was offered 4 of 973 times, and on 0 of 14 regex-selected human analysis prompts. A method
     section from data-quality-craft or decision-craft was offered on 5 of those 14.
   - Chat answers have no refusing check except the absence rung.
   - measurement.md reaches C:\Codex sessions only after a Read of a ThriftyCrew file (0 of 9 at start).
   (analysis-path, OVERSTATED)
7. **The rules files' scope key is inert.** They use Cursor's `globs:`, and the Claude Code loader reads only `paths:`,
   in 4 of 4 builds checked. So all 118,538 B load in every ThriftyCrew context (33 of 33 transcripts), and at least 9
   records say otherwise. This accident is what delivers the helper names and measurement.md today, so a naive "fix"
   would silently remove them.
8. **Workflow and spawn_task briefs are ungated.** 1 of 24 spawn_task prompts and 1 of 34 saved workflow scripts carry a
   section.
9. **The Stop consulted gate never sees prompt-hook offers.** It counted an offer on 25 of 223 gate-rowed offered turns,
   all of them from the agent hook, and 37 of 260 offered turns had no gate row at all.

Also real, because they corrupt the loop's own evidence:
- Session state loses writes: 7,469 orphan `.tmp` files, and 581 of 738 roll-up keys show impossible beat counts.
- 79% of reflex fires come from subagents, whose failures are never recorded (0 of 1,237 burned).
- Scheduled envelopes drive 56% of prompt offers.
- One apply batch of Brad's 2026-09-12 rulings (70 answers: 69 graph-alias rulings needing work plus 1 cluster ruling)
  hit HTTP 429 and was never retried.
- The nightly pass was red on 11 of its last 12 runs, and went RED was mailed on 9 of 9 nights from 09-12.
- Review traffic pollutes the rates: this review alone added 96 searches under one session id.

## 3. The design, and why it is this shape

1. **Pull, enforced once, with a head start.** The one mechanism with a measured obedience record is a refusal that says
   exactly how to comply and accepts an honest negative: the brief gate went to 54 of 54, and both of its refusals came
   back compliant within 94 s. So Goal 1's core (W4.2) is a deny-once on the first in-scope write in a context that has
   not searched.
   - The deny text carries the command, plus whatever EXACT recognition finds in the text being written. It never
     carries a similarity guess.
   - It is judged by compliance (M1b) and by whether the context then cites something its own search returned (M3).
     Never by the self-selected pull/push ratio.
2. **Make the search able to answer.** A gate that forces a search over a corpus that cannot see memory, rules or code
   teaches ceremony. So W3.x gives `search.py` one `--estate` mode before the gate goes live. It covers skills, memory
   stores, rules one bullet per chunk, a generated machinery index, and an unranked `git grep` leg.
3. **Recognition over the whole catalogue, not a hand list.** Each helper the estate has built replaces a known
   construct.
   - Each library's header declares that construct in a `# REPLACES:` line (W3.2).
   - The one existing reflex engine loads rows GENERATED from those lines, beside a few hand rows (W4.1).
   - So the hook visibly references the estate's machinery as a whole, and the catalogue grows as each library declares
     what it replaces. This is tier 1's accepted mechanism (a pattern), not the refused tier-2 signal (similarity).
4. **Exact citation, in shadow first.** The 16 applies-here files cite estate paths 845 times (494 distinct), and
   memories cite more. A path-to-section map is a lookup, not a query, and it is new relative to 2a.
   - As a craft router it missed its pre-written bar: 5 of 20 against 12.
   - Over memories the same rule scored 13 of 20 against a bar of 12, on a case set biased toward memories named after
     their file (4 against 1 discordant, not significant).
   - As a bridge route only its reach was measured: 745 of 1,454 code file-touches.
   So it ships in shadow with a GOVERNS bar written first (W4.3).
5. **The record accepts what goal 1 asks for.** The Store: resolver must accept estate knowledge before 2026-09-25
   (W0.1), and analysis records gain the same check (W5.3).
6. **Instruments before enforcement.** Every change that can REFUSE a call, or route new text through a path that had
   none (W4.2, W4.3):
   - ships behind a mode that defaults to shadow;
   - has its log in place before the mode flips;
   - has its bar written in this plan.
   Reach fixes (W2.1, W2.2) and remind-rung rows (W4.1, W5.5) ship live, bounded by their fire-rate cap or bar, and roll
   back by revert.
   The harness facts it depends on are probed first (W1.1). Two of this estate's worst errors were unprobed harness
   beliefs: the rules scope, and "PostToolUse on failures cannot exist".
7. **One of everything.** One pattern engine (`recall_reflex`), one definition of `--estate`, one project-root function,
   one harness-text strip, one `headless_reason()`, one resolver per repo, and one list of analysis-record prefixes.

```
 prompt ──> recall-hook: skills pointers; + analysis route (W5.4)              [reminds]
 first in-scope write (Edit/Write, or a shell write to a literal path) ──> reflex hook
      marker for (session_id, agent_id)?  no ──> DENY once (W4.2):
         command + machinery entries recognised in the text (W4.1 rows, generated from REPLACES headers)
         + store sections citing the file (W4.3, once live)
      search.py --estate ──> skills + memory stores + rules/bullet + machinery index + git grep     [W3.3]
         last line KNOWLEDGE-SEARCH-COMPLETE ──> PostToolUse writes the O_EXCL marker               [W4.2]
 later writes ──> reflex hook: machinery rows (construct -> helper, gate)      [W4.1 remind]
 commit ──> store_citation accepts estate citations; logs kinds                [W0.1]
 push ──> run-gates; a zero-file static scan is BLIND, not ok                  [W6.9]
```

## 4. How to work this plan (read before any item)

### 4.1 The two repos
- **Brain items** (paths under `C:\Users\Owner\.claude`) commit to the `~/.claude` repo (remote Schweino/claude-store).
  It has no gates until W4.5, so its self-tests are the only guard.
- **ThriftyCrew items** land through `ops\push-main.ps1` from a clean, seeded linked worktree (memory
  `landing-a-push-needs-a-clean-worktree`).
- In BOTH repos: stage explicit paths and commit with a pathspec (`git commit -F <msgfile> -- <paths>`). Write the
  message file with `[IO.File]::WriteAllText($p, $body, (New-Object Text.UTF8Encoding($false)))`, and check
  `git show --stat HEAD` after every commit. The shared `~/.claude` index is used by other sessions too.
- Each item's first line says `Repo:` and `Lands via:`. An item marked "both" makes one commit per repo.

### 4.2 Every commit message
- **Name the plan on its own line:** `Plan: design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md W<id>`. Never
  put it on the Store: line: Store: is resolved against the committing repo, and in `~/.claude` a ThriftyCrew path does
  not resolve until W4.5 step 0.
- **A code commit carries a Store: line** naming the store sections the item lists. Once W0.1 lands,
  `.claude/rules/*.md`, `design/*.md` and directory-qualified `lib/*.ps1` resolve in ThriftyCrew.
- **Any item that adds a store_citation self-test case bumps `expected`** (line 335) in the same commit: W0.1, W0.2,
  W4.5, W5.3 and W6.11.

### 4.3 Brain hooks are live the moment a file is saved
The hooks run from the working tree, so:
1. put the new behaviour behind a mode whose default is today's behaviour or `shadow`;
2. immediately after saving, run `C:/Codex/Python312/python.exe -m py_compile <file>` and the file's `--selftest`, and
   read the exit code;
3. flip the mode in its own commit.
- Mode files live under `~/.claude/skills/` (tracked), never at the `~/.claude` root, which `.gitignore` ignores. So
  does any file a bar or report reads as its INPUT: exclusions, labelled cases, probe sets.
- A mode env var (RECALL_FIRST_WRITE_MODE, RECALL_PATH_ROUTE_MODE) names the mode FILE's path, never the value. A
  fixture writes `{"mode": "deny"}` into a file under its tmpdir and points the variable at it.
- Every row a moded hook writes carries `mode`.
- Never change a hook, a floor or a scorer inside a session doing something else (`knowledge-search/SKILL.md`).

### 4.4 Procedure P1: editing `~/.claude/settings.json`
Items W1.1, W1.2, W4.4, W5.5, W5.6 and W6.1 edit it. It is re-read live box-wide, and it carries
`permissions.defaultMode: bypassPermissions`, which every unattended run depends on.
1. Copy it to your scratch dir.
2. py_compile the hook script and run its `--selftest` first.
3. Change the file with Python `json.load` / `json.dump(obj, f, indent=2, ensure_ascii=False)` plus a trailing LF.
   Write `settings.json.<pid>.tmp` in `~/.claude` and `os.replace` it over the original. Never hand-edit the text, and
   never use PowerShell ConvertTo-Json or Set-Content.
4. Give every new command entry `"timeout": 10`.
5. Add a NEW entry rather than editing another entry's hook list, unless the item says otherwise. Never remove
   `Edit|Write` from the entry that runs `recall-reflex-hook.py`.
6. Verify:
   - `C:/Codex/Python312/python.exe -c "import json;json.load(open(r'C:\Users\Owner\.claude\settings.json',encoding='utf-8'))"`
     exits 0;
   - `git -C ~/.claude diff -- settings.json` shows only your lines;
   - the next matching tool call writes the new hook's row;
   - `check-skills.py`'s hook-table section is ok.
7. On any failure, `os.replace` the scratch copy back before anything else.
8. Except for a temporary entry (W1.1 step 2), which is never committed and is removed in the same session: commit
   settings.json and the automatic-recall.md section 2 table together. check-skills fails when an installed
   `recall-*.py` hook is missing from that table, so every item that registers a hook adds its table row in the same
   commit.

### 4.5 Procedure P2: the canonical `recall-reflex-hook.py main()` order
W1.5, W4.1, W4.2 and W4.3 all insert into `main()`. The one order is:
1. parse, heartbeat, `query_for` (unchanged; the chash stays on this 2,000-capped text);
2. `match_text = action_text_for_match(...)` (W4.1);
3. `_log_shadow`, which returns its row count once W1.5 changes it (the count is only ever LOGGED);
4. `hits = fire(match_text) + promoted`, with the machinery site-count filter (W4.1);
5. the W1.5 coverage row, with `fired` = the ids from step 4;
6. the W4.2 first-write decision;
7. the W4.3 route lookup. When step 6 denied and W4.3 is live, its route lines are appended to the deny reason after the
   machinery lines, inside the 900 B cap; in shadow they are only logged;
8. `if not hits and no W4.2 or W4.3 text: return 0`;
9. the existing decide, fire-log write and emit.
- On a W4.2 deny, emit only the deny: its reason carries the machinery lines and, once W4.3 is live, the route lines.
- Otherwise emit ONE additionalContext, in the order reflex text, W4.2 remind text, routes.
- An item that lands before a later step exists implements only its own step, in this position.

### 4.6 Procedure P3: editing a scheduled-task SKILL.md
Used by W3.4, W5.2 and W5.3. The LIVE file is `C:\Users\Owner\.claude\scheduled-tasks\<task>\SKILL.md` (brain repo),
shared by every checkout. Each ThriftyCrew checkout holds its mirror at `ops\prompt-backup\scheduled-tasks\<task>\SKILL.md`,
and `ops/audit-prompt-backup.ps1` compares the two on every push. `-SyncScopes` never touches scheduled tasks.
Do it in one sitting:
0. Run `git -C C:/Users/Owner/.claude status --short -- scheduled-tasks/<task>/SKILL.md`.
   - Empty output: proceed.
   - ` M`: another session has an uncommitted edit of this live file. Stop and ask: step 3 would copy it into the mirror,
     and step 4 would commit it under this item.
   - `??`: the file is untracked in the brain repo (verify-board-sample was, on 2026-09-22). Step 4 then runs
     `git -C C:/Users/Owner/.claude add -- scheduled-tasks/<task>/SKILL.md` before its pathspec commit.
1. Have a clean ThriftyCrew worktree at origin/main ready to push.
2. Edit the live SKILL.md.
3. At once, run `powershell -NoProfile -File ops\audit-prompt-backup.ps1 -SyncMirror` in that worktree, commit the
   refreshed mirror with a pathspec, and land it with push-main.
4. Commit the live file in the brain repo with a pathspec.
Until each sibling checkout rebases past step 3, its pushes read STALE BACKUP. Say so in the commit message, keep the
window to minutes, and never leave step 2 uncommitted overnight.

### 4.7 Constants every item uses
- **The search command**, one string, runnable unchanged in Bash and PowerShell: forward slashes, absolute, no `%VAR%`.
  - Until W3.3's bar has held AND W3.4 has landed, every carrier uses it WITHOUT `--estate`: W0.1, W5.2's blocks, W4.5
    step 5.
  - W3.4 is the one change that adds `--estate` to the carriers.
  - W4.2's deny text is the exception: it always carries `--estate` (W4.2 step 6).
  - Run it unpiped. A pipe that cuts the last line loses the COMPLETE line, and the search is not counted.
  ```
  C:/Codex/Python312/python.exe C:/Users/Owner/.claude/skills/knowledge-search/search.py --estate "<3-6 words>"
  ```
  A detector that recognises a search matches both separators: `knowledge-search[\\/]+search\.py`.
- **ANALYSIS_RECORD_PREFIXES** = PLAN, MEASURE, EVAL, TRIAL, RCA, REVIEW, AUDIT, FINDING, FINDINGS, PROBE, for dated
  `design/<PREFIX>-*.md`. It is defined once in `ops/store_citation.py` (W5.3) and mirrored as
  `recall_core.ANALYSIS_RECORD_PREFIXES`, with a comment naming the source.
- **Estate root when cwd is not in a repo:** env `RECALL_ESTATE_ROOT`, default `C:\Codex\ThriftyCrew`. recall-brain,
  recall-effort and recall-inbox already read it. No new config file.

### 4.8 Fixtures and tests
- **Every fixture redirects every live path through `recall_core.redirected_env(tmpdir)`** (W1.0). It sets every
  `RECALL_*` variable that names a file or directory, derived by scanning the sources, including the new
  `RECALL_INDEX_DB`. Its self-test fails when a referenced name is not covered.
  - Each item that adds a log, marker directory, mode file or cache adds its env var and appends it to `redirected_env`
    in the same commit.
  - A hook self-test that needs a mode sets it through the env var and never writes the live mode file. Its CLEAN TWIN
    asserts that the live mode file's sha256 is unchanged.
- **A fixture that builds a temp git repo removes all eight variables** that `Clear-TcGitRepoEnv` clears
  (`lib/git-repo-env.ps1:39-40`) from its CHILD env: GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, GIT_COMMON_DIR,
  GIT_OBJECT_DIRECTORY, GIT_ALTERNATE_OBJECT_DIRECTORIES, GIT_PREFIX and GIT_NAMESPACE. `ops/audit-git-fixture-env.ps1`
  does not read `.py`, so nothing else catches a miss. Never scrub them for a git call against the COMMITTING repo inside
  a real commit-msg path. A child that queries a DIFFERENT repo (W4.5 step 0) removes them for that child only.
- **An env var is named identically everywhere**, and an existing name is reused rather than duplicated (for example
  `RECALL_REFLEXES` for the reflex table).
- **Self-tests:**
  - the last line names the self-test and a result word (`lib/selftest-verdict.ps1`);
  - a literal-case suite asserts how many cases ran;
  - a needle that must not match its own source is built by concatenation;
  - at-the-bar cases use binary-exact numbers;
  - temp paths are per run.

### 4.9 Other standing rules
- **Append to a shared log only through `recall_append.append_rows`**, inside try/except (it raises). Never
  `open(path, 'a')`.
- **Put no new keys in shared session state** (`recall_core.load_state`). It loses writes until W2.4, and it is an
  allow-list. Use an append-only log or an O_EXCL marker. If a key must go there, add it to BOTH the `fresh` dict and the
  dict-type tuple.
- **Fail open, and say so.** A hook that raises exits 0 with empty stdout. A leg that cannot look prints `BLIND <why>`.
- **Never a gate that is red on day one.** Run any new check over the real tree before landing, and put the count in
  the commit message. Use a literal cutoff constant (never `Get-Date`) or a ratchet whose plain run never writes its
  mark.
- **Exclude review and probe traffic through ONE file**, `~/.claude/skills/recall-audit-exclusions.json` (W1.9).
  - Every report and bar here reads it and prints `excluded N rows`.
  - It lists this review's AGENT ids and the `C--Codex-tc-exp-*` sessions.
  - Never list the parent sid `134f2f6e-7fb9-4057-a890-b2c27ba9dfc0`: its human turns are real traffic.
- **A measurement anyone may repeat commits its harness** and cites the harness blob. The replay, report and scoring
  scripts named in the bars are committed before the run.
- **No em dashes** in anything a reader sees.

## 5. Work item index

| Id | Title | Repo | Needs | Brad |
|---|---|---|---|---|
| W0.1 | Store: resolver accepts estate knowledge | TC | - | D1 |
| W0.2 | A checkout with no copy of the rule says BLIND | TC | - | - |
| W1.0 | `redirected_env` and `RECALL_INDEX_DB` | brain | - | - |
| W1.1 | Sandboxed harness-event probe | brain | W1.0, W1.9 | D18 |
| W1.2 | InstructionsLoaded log | brain | W1.1 | - |
| W1.3 | Brief-gate log | brain | W1.0, W1.9 | - |
| W1.4 | Intent-hook log | brain | W1.0 | - |
| W1.5 | Coverage row per call | brain | W1.0, W1.9 | - |
| W1.6 | Search attribution, log before print, COMPLETE line | brain | W1.0 | - |
| W1.7 | `tool_use_id` and pattern hash on fire rows | brain | - | - |
| W1.8 | `recall_transcripts.py` (subagents and workflows) | brain | - | - |
| W1.9 | Review-traffic exclusion file | brain | W1.8 | - |
| W2.1 | One project-root function | brain | W1.0 | - |
| W2.2 | One harness strip; skip scheduled envelopes | brain | W1.0 | - |
| W2.3 | Rules truth, option A | both | W1.2 | D2 |
| W2.4 | State lock, atomic appends, saves counter | brain | W1.0 | - |
| W3.1 | Rules chunked per bullet | brain | W2.1 | - |
| W3.2 | Generated machinery index, plus header seeds | both | W2.1, W3.1, W5.3 step 1 | - |
| W3.3 | `search.py --estate` | brain | W3.1, W3.2, W1.6 | - |
| W3.4 | Command sweep to `--estate` | both | W3.3 bar, W5.2 | - |
| W4.1 | Machinery recognition rows (hand plus generated) | brain | W3.2, W1.7 | D9 |
| W4.2 | Search before the first in-scope write | brain | W4.1, W2.1, W2.2, W3.3, W1.6, W1.5, W5.1 step 1, W5.3 | D3, D3b |
| W4.3 | Store sections citing this file (shadow) | brain | W4.2 | - |
| W4.4 | spawn_task and Workflow brief gates | brain | W1.1, W1.3 | D5 |
| W4.5 | The brain is covered | both | W0.1, W3.3, W4.1 | D17 |
| W4.6 | Fantasy | Fantasy | W0.1 | D8, D15 |
| W5.1 | Analysis preflight, pointed at from ~/.claude/CLAUDE.md | both | - | D6 |
| W5.2 | Analysis store-step in verdict agents and tasks | both | - | - |
| W5.3 | Analysis records must say what they consulted | both | - | - |
| W5.4 | Prompt analysis route (bar first) | brain | W2.2, W1.9 | D19 |
| W5.5 | Intent analysis card | brain | W1.4 plus 7 days, W4.2 | - |
| W5.6 | SubagentStop telemetry | brain | W1.1 | D4b |
| W5.7 | Stop gates see prompt offers; analysis rung log-only | brain | W2.2, W4.2, W5.4 | D4 |
| W6.1 | Subagent failures recorded | brain | W1.1, W1.7, W1.8, W4.2 | - |
| W6.2 | Did a reminder change the next edit (control arm) | brain | W4.1, W4.2, W6.1 | D12b |
| W6.3 | The nightly signal means what it says | brain | - | - |
| W6.4 | Brad's unapplied rulings; approvals page | both | - | D13 |
| W6.5 | Bridge currency; frozen refusal cases | brain | - | - |
| W6.6 | Always-loaded budget ratchet | both | D2 | - |
| W6.7 | Log archive, never delete | brain | W2.4 | - |
| W6.8 | Memory semantic leg stays gated | - | W2.1 | D16 |
| W6.9 | The push tier stops reading green when blind | TC | - | - |
| W6.10 | Harness facts carry a re-check date | brain | - | - |
| W6.11 | Store: escape forms (warn-only first) | TC | W0.1 | D1b |
| W6.12 | Docs say what the code does (sweep) | both | as described | - |
| W6.13 | Hook health by origin | brain | W1.8 | - |

## 6. Order

Take one row at a time, and within a row follow the order given. Land and verify each item before starting the next.

| Row | Items, in order | Why here |
|---|---|---|
| 1 | W0.1, W0.2 | 2026-09-25 |
| 2 | W1.0, W1.8, W1.9, then W1.1, then W1.2; W2.4 | fixtures redirect first; exclusions exist before the probe records its ids and before any report reads them; the probe settles field names before any logger uses them; state must stop losing writes before any new key or rung |
| 3 | W1.3, W1.4, W1.5, W1.6, W1.7 | baselines accumulate while the rest is built |
| 4 | W2.1, W2.2, W2.3 (option A only), W5.3 | reach fixes; W2.3 scopes nothing; W5.3 defines ANALYSIS_RECORD_PREFIXES, which W3.2 and W4.2 read |
| 5 | W3.1, then W3.2 (its brain generator first, the ThriftyCrew header seeds second), then W3.3 | the search can answer before anything forces it; W3.2's bar is scored through W3.3 |
| 6 | W5.1 (steps 1 and 3), W5.2; W4.1 at remind; then W4.2 in SHADOW; then W4.3 in shadow | the shadow week measures real volume |
| 7 | W3.4 (only if W3.3's bar held) | add `--estate` to the carriers only if it answers |
| 8 | W4.2 remind for 3 days, then deny (D3; only if W3.3's bar held, otherwise W4.2 stays in remind and D3 goes to Brad with W3.3's result), W4.4 (D5), W4.5, W4.6 (D8), W5.1 step 2 (D6), W5.4, W5.5, W5.6 | refusals go live on evidence and a ruling |
| 9 | W5.7, W6.1, then W6.2, W6.3-W6.13 | evidence quality, efficiency, docs |

## 7. How we will know it worked (bars written now)

| # | Metric | Baseline (2026-09-22) | Bar | Instrument |
|---|---|---|---|---|
| M1a | editing contexts that searched before their first in-scope write ATTEMPT (a denied attempt counts) | 11 of 38 Agent-tool contexts, 2026-09-20..22 | reported, never a bar | committed `~/.claude/skills/first-write-report.py` (W4.2), transcripts through W1.8 |
| M1b | editing contexts that searched before their first in-scope write that was NOT denied | n/a | at least 80% after 14 days of deny, N printed | same |
| M2 | denies followed by a redo without a search | n/a | at most 20% of denies | W4.2 log |
| M3 | denied-then-searched contexts whose Store: line, Knowledge consulted section or `knowledge_consulted` names a key their own search returned | n/a | at least 25% after 14 days of deny, printed as N of M per origin (main, agent, workflow); the first plausible value, not a swept one; below it goes to Brad as ceremony, never into a second deny | W3.3 log `paths` joined to store_citation's `cited` and plan files |
| M4 | commits refused for citing estate knowledge | 4 in 2026-09-20..22 | 0 | W0.1 `cited_kinds` |
| M5 | "nothing applicable" lines backed by an `--estate` search | 0 possible today | reported | W1.6 `corpus` |
| M6 | triage plans after W5.3's cutoff with `knowledge_consulted` | 18 of 23 (19 with the rca_document link), 2026-09-19..22 | 100% (the validator refuses) | validate-triage-plan |
| M7 | memory corpus present for worktree-cwd hook calls | 0 of 97 worktree keys | all | W2.1 |
| M8 | prompt offers answering a scheduled envelope | 548 of 977 | 0 of N | W2.2 skip rows |
| M9 | machinery rows: fixed-rate difference, shown against shadow | n/a | at least 20 points over at least 40 fires per arm | W6.2 |
| M10 | analysis answers with no search in the context | unmeasured | reported (D4 decides any refusal) | W5.7 |
| M11 | instruction bytes per TC session | 155,320 B | set by D2, then ratcheted | W1.2, W6.6 |

**What none of these says.** They measure whether knowledge REACHED the moment of work and was USED in an action: a
search, a citation of something that search returned, a helper adopted. None says the code or the verdict got better. The
2026-09-19 pilot showed two runs of the same arm differ as much as store against no store. A decisive answer needs about 60
build and 60 judge sessions (MEASURE-store-ab's own sizing). That is D14, after M1b clears.

## 8. What this plan must not do

- Do not convert `globs:` to `paths:`, and do not scope measurement.md or ops-and-gates.md, before W1.1 and W1.2 prove
  delivery to Bash-only, Agent and Workflow contexts and Brad rules (D2). `alwaysApply: true` is a no-op.
- Do not propose similarity retrieval at edit time (file path or code as the query). The 2a refusals stand.
- Do not raise recall_core's 2,000-char chash cap. Widen the MATCH text separately.
- Do not build a second pattern engine, a second claims register, a third BM25 index, another copy of project_key, the
  harness strip or headless_reason, or a second definition of `--estate`.
- Do not put new keys in shared session state.
- Do not call `record()` from the prompt hook.
- Do not widen the consulted gate before W2.2 lands, and never judge it by footer rate.
- Do not exclude search.py from the select-first reflex row. Fix the log order (W1.6).
- Do not add a gate that is red on day one.
- Do not land the zero-scan BLIND rule before the readjson walk fix, or without its pre-push and CLAUDE.md changes.
- Do not scrub GIT_INDEX_FILE inside commit-msg.
- Do not run `ops/install-hooks.ps1` from a feature worktree: it installs that checkout's hooks box-wide.
- Do not commit without a pathspec in either repo, the sleep pass included (W6.3).
- Do not write memories from a worktree agent.
- Do not rewrite ops-and-gates narrative into memories; keep ruling sentences verbatim wherever they move.
- Do not paste "run search.py" into an agent that has no Bash.
- Do not let W4.2 deny more than once per context, or deny a headless run before D3b.
- Do not claim an effect from open rates, or from a search alone. An open is not a use, and neither is a search.
- Do not include review or probe sessions in any baseline.
- Do not run graph ingest in the main tree, or in a worktree without graph.db.
- Brad's alone: withholding knowledge beyond the ruled W6.2 split, retiring derive-floors, changing a reflex rung,
  moving any refuse date, migrating memories between the two repos, and editing the unversioned `C:\Codex\CLAUDE.md` by
  script.
- Do not run `-SyncScopes` or a memory migration from a worktree.

## 8b. Findings deliberately not built by this plan

Every high or medium finding in the digests is an item above (cited by id or by topic) or listed here with its
disposition.

| Finding (digest/id) | Disposition |
|---|---|
| estate-machinery/store-citation-blind-to-machinery: the commit-time MACHINERY ADVISORY | DEFER. A warn-only follow-on once W4.1's generated rows exist; it would reuse them, never a second pattern set |
| memory-and-budget/estate-library-index-missing: a tracked `lib/INDEX.md` plus a CLAUDE.md line | REJECT in favour of W3.2's untracked cache (critic C6: a tracked index churns every push) |
| tool-tier/python-and-brain-code-uncovered: `py-text-mode-tracked-write` | DEFER. Measure `--rate` on 16,000-char probes first (it matches 124 lines in 78 files) |
| tool-tier/python-and-brain-code-uncovered: graph bare commodity id | DEFER to the analysis side, as a cue on reading `graph/identity/*.jsonl`, measured first |
| agent-tier/agent-tier-never-points-at-estate | DEFER until W3.2 lands, with a 20-case bar mined first, negatives included |
| agent-tier/pointer-use-unmeasured | NOT IN SCOPE (a later plan) |
| prompt-tier/prompt-tier-cannot-reach-subagents: a SubagentStart primer | REJECT for now (critic C8: the measured gap is behaviour, which W4.2 addresses). W1.1 still records SubagentStart |
| bridge-and-routing/reader-facing-and-analysis-unbridged: `dir_routes` | DEFER until W4.3's citation routes clear their bar |
| memory-and-budget/tc-store-audit-gap | NOT IN SCOPE. It needs audit-memory-backup taught about enclosed-repo stores; a later plan |
| memory-and-budget/stores-split-by-session-cwd | D7, its own plan. Read-side only here (W3.3 reads the stores) |
| memory-and-budget/orphan-income-store | NOT IN SCOPE |
| offline-loop/course-routing-skips-rules: the Lands-in field | NOT IN SCOPE |
| prompt-tier/offer-open-join-crosses-sessions | NOT IN SCOPE (a recall-stats fix; later) |
| tool-tier/miss-pipeline-noise-and-person-bound | NOT IN SCOPE; W6.1 fixes the evidence it needs first |
| tool-tier/rate-gate-corpus-unlike-live: `--rate --live` | NOT IN SCOPE. W4.1 re-runs `--rate` whenever it changes the corpus |
| tool-tier/rung-mislabels, agent-tier/agent-hook-tautological-case, prompt-tier/explore-guard-uses-bm25-floor, prompt-tier/lexical-fallback-slow-and-frequent, prompt-tier/leg-unknown-on-quiet-turns | NOT IN SCOPE (low; each digest carries its own fix sketch) |
| record-tier/behaviour-files-unjudged | D11, a ruling only. A yes needs its own item |
| offline-loop/floors-derived-for-nothing | ALREADY-RULED by Brad on 2026-09-22. Leave it alone |
| offline-loop/no-use-measure: a prompt-tier and intent-tier holdout | NOT IN SCOPE. Withholding knowledge beyond W6.2's ruled split is Brad's alone (section 8); a later plan if he rules |
| prompt-tier/path-strip-deletes-estate-file-names | NOT IN SCOPE (OVERSTATED: 4 of 99 main-TC prompts). W2.2 moves the strip without changing its path handling |
| tool-tier select-first relabel | D10, a ruling only. W1.6 fixes the log order; a yes needs its own item |

## 9. Decisions only Brad can make

| # | Decision | Recommendation | Blocks |
|---|---|---|---|
| D1 | Land W0.1 by 2026-09-24, or move REFUSE_FROM | land it: one file, with a written bar | W0.1 |
| D1b | Refuse date for the escape forms (W6.11) | after one warn week, with its count | W6.11 |
| D2 | Rules: unconditional (A, now) or lead plus scoped depth (B, after the probe) | A now; judge B on W2.3's rubric once W1.1 and W1.2 report | W2.3 option B, W6.6 |
| D3 | First-write gate: shadow, then remind (3 days), then deny | yes, if the shadow bars and W3.3's bar hold | W4.2 deny |
| D3b | Deny headless runs too | decide on the shadow count; until then headless is log-only | W4.2 |
| D4 | Consulted gate reads prompt offers (about 15 refusals a week), and which refusal shape for chat analysis: a missing footer, or no search in the context | shadow first; prefer "no search in the context", judged on named items | W5.7 |
| D4b | Absence rung refuses on Agent-tool helpers | only if the rate bar holds; workflow agents report-only | W5.6 |
| D5 | spawn_task and Workflow brief gates go live | yes, after the probe | W4.4 |
| D6 | The exact ANALYSIS PREFLIGHT lines in `~/.claude/CLAUDE.md`, and a brain pointer line if needed | approve the 10 lines | W5.1 step 2, W4.5 step 7 |
| D7 | The two memory stores: one business, one store, or read-side only | read-side now; migration as its own plan (two git repos, link closures) | none |
| D8 | Fantasy gets a warn-only Store: hook | yes, warn-only, vendored | W4.6 |
| D9 | set-content-no-encoding: rewrite to remind | remind; no single rewrite is correct under PS 5.1 | W4.1 message only |
| D10 | select-first row: relabel harm silent, sharpen | relabel; no item here, a yes needs one | none |
| D11 | Behaviour files join the Store: rule, warn-only for 14 days | yes; no item here, a yes needs one | none |
| D12 | Per-row edit_block for machinery rows whose gate holds at zero | later, per row, on W6.2's numbers | later |
| D12b | A 14-day shown-against-shadow split on machinery rows | yes; it is the only way M9 means anything | W6.2 |
| D13 | Re-apply the 2026-09-12 rulings, and WHERE the ingest runs | yes, from a worktree with graph.db | W6.4 |
| D14 | Run the decisive store A/B (about 60 plus 60 sessions) | after M1b clears | none |
| D15 | Hand-fix `C:\Codex\CLAUDE.md`'s project table (Fantasy has git; ThriftyCrew is at 3,249 commits, not 2,284) | yes | none |
| D16 | Build the memory semantic leg's held-out floor | after W2.1, if still wanted | W6.8 |
| D17 | BRAIN_REFUSE_FROM for the brain repo's Store: check | after a warn period and a replay count | W4.5 |
| D18 | Approve W1.1's temporary box-wide logger hooks | yes: logger only, session-filtered, self-expiring | W1.1 step 2 |
| D19 | Per-session dedup for the analysis route, reversing recall-hook.py's "NO PER-SESSION DEDUP ON THIS EVENT" for that route only | yes | W5.4 step 4 |

Ruled 2026-09-23 by Brad: D5 yes, D6 yes (the 9-line block as drafted), D8 yes, D12b yes, D13 yes, then revised to 'lasting fix first' (a reconcile step so graph.db takes newer tracked verdicts, before the 69 rulings land), D18 yes (the desktop probe ran and was removed the same session), D19 yes.

## 10. Blast radius and rollback

- **Phase 0.** One ThriftyCrew file and one hook. W0.1 widens both what resolves AND what is extracted, so extraction
  could refuse a line that passes today. Its bar replays every Store-carrying commit since 2026-09-15 and prints verdict
  changes in either direction. Rollback is a revert.
- **Brain hooks.** Every change that can refuse a call, or route new text through a path that had none (W4.2, W4.3),
  sits behind a mode that defaults to shadow. Its rollback is the mode file (tracked, under skills/), then a revert.
  Reach fixes (W2.1, W2.2) and remind-rung rows (W4.1, W5.5) ship live, bounded by their fire-rate cap or bar, and roll
  back by revert. A crash fails open. W4.2's deny, the one change that can refuse a tool call,
  is capped at one per context, and a redo proceeds.
- **settings.json.** Procedure P1, with a scratch copy to restore.
- **Rules files (W2.3 option A).** Deleting inert keys changes no loading behaviour, and W1.2's log proves it. Option B
  is a separate, ruled change.
- **Gates** (W6.9, W5.3, W5.2, W2.3 step 2). Each is green on day one, verified over the real tree, with the count in its
  commit message.
- **Nothing here** publishes a page, changes a price, or writes a board or graph.db. The one exception is W6.4's
  re-application of Brad's already-made graph rulings, from a worktree, on his decision D13.
