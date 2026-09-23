# record-tier

The record tier checks whether a decision's written record names knowledge. It does not try to push knowledge at a session.

1. Commit check. ThriftyCrew's commit-msg hook (ops/hooks/commit-msg:48-52) calls ops/store_citation.py --commit-msg, but only when CLAUDE_CODE_SESSION_ID is set. The hook runs once per commit. It judges a commit that stages a CODE_EXT file (.ps1 .psm1 .py .js .ts .sql .sh, or ops/hooks/). That commit needs either a `Store:` line whose tokens resolve, a `Store: searched <terms>, nothing applicable` line, or a `Store-Exempt: <reason>` line.
   - Tokens are matched by PATH_RE: `*.md`, `memory:x` or `[ [x] ]`.
   - A token resolves only against ~/.claude/skills, ~/.claude itself, or the two memory dirs (C--Codex-ThriftyCrew, C--Codex). It never resolves against the repo.
   - Each judged commit appends one row to ~/.claude/store-citation-log.jsonl. It WARNs until REFUSE_FROM=2026-09-25, then refuses (exit 1).
   - "Backed" means that SESSION id logged any knowledge-search search in the prior 24h. It is recorded, never refused.
2. Plan audit. run-gates (ops/run-gates.ps1:558, pyStatic) runs store_citation.py with no arguments. It fails any design/PLAN-* or MEASURE-* dated 2026-09-20 or later whose `## Knowledge consulted` section is empty. The section text is never resolved.
3. Weekly report. store-usage-report.py reads both logs and prints rates against the bars: 80% of judged commits backed, and half of those citing a file. A Claude scheduled task, store-usage-weekly, runs it next on 2026-09-24 08:06, the day before refusal starts.
4. Consulted hook. recall-consulted-hook.py runs on Stop only, meaning main-thread turns and never SubagentStop. It refuses once per turn (exit 2) when the recall hook offered sections this turn and the reply has no line starting `Consulted:`. Any text after the colon is accepted, including an empty one or `nothing relevant`. A second rung refuses an absence claim that has no `Checked:` line. Headless calls are skipped.

Nothing in this tier covers:
- the ~/.claude brain repo, which has no hooks at all
- Fantasy, which has git but no hooks
- behaviour-bearing .json, .xml or .md commits
- uncommitted work
- any analysis delivered by a subagent or Workflow agent.

## Measurements
- Report: judged code commit attempts, with a resolving Store: line, backed, citing a file: 175 judged; 126 of 175 (72%) resolving and backed (bar 80%: missed); 106 of 126 (84%) cite a file (bar 50%: met); 47 warned (27 no Store: line, 14 unresolved, 6 name nothing); 2 exempt; 0 of 12 committing sessions searched nothing  [log rows 2026-09-18 19:11 to 2026-09-22 18:43 (the 7-day window covers the whole log)]
- Replay over LANDED commits: Claude-coauthored code commits on origin/main, judged by store_citation.judge_message as if today were 2026-09-25: 269 non-merge commits, 252 Claude-coauthored, 141 change code (2 more are the daily bot). 114 of 141 ok (98 cite a file, 16 'nothing applicable'), 2 exempt, 25 refused (21 no Store: line, 4 unresolved)  [author dates 2026-09-18..2026-09-22]
- Refuse-date readiness by day (landed commits, replayed): 09-18: 14 of 18 refused; 09-19: 7 of 67; 09-20: 3 of 13; 09-21: 0 of 15; 09-22: 1 of 28. Last three days: 4 of 56 (7%), and all 4 are refused only for citing .claude/rules/*.md or design/*.md  [2026-09-18..2026-09-22]
- Hook coverage: landed Claude code commits that have a decision-log row: 131 of 141. All 10 missing rows are dated 2026-09-18, before the first log row at 19:11 (hook install). 131 of 131 after install  [2026-09-18..2026-09-22]
- Unresolved citation tokens in the log, and whether they resolve with today's resolver: .claude/rules/ops-and-gates.md 9 (no), design/RCA-holistic-2026-09-22.md 5 (no), .claude/rules/meal-prep.md 2 (no), .claude/rules/measurement.md 1 (no), bare applies-here.md 1 (no); 3 memory tokens now resolve after today's C--Codex fix  [log 2026-09-18..2026-09-22]
- Synthetic Store: lines through judge_message on the refuse date (in-process probe): 14 cases: repo rule file, repo design doc, estate library (lib/atomic-write.ps1) and estate gate all REFUSE; 'Store: searched, nothing applicable' (no terms), 'Store: CLAUDE.md', 'Store: memory:MEMORY' and 'Store-Exempt: x' all PASS; an indented Store: line is 'no Store: line'  [2026-09-22]
- Backing granularity: 171 of 175 code rows backed=true. Session 97732561: 51 code commits across 36 distinct checkouts on 27 searches. Session ffbacbef: ~70 code commits across 6 checkouts (5 agent-* worktrees) on 32 searches. 0 of 134 search rows carry an agent id  [2026-09-18..2026-09-22]
- Cited skills file was among the SAME session's search results in the prior 24h: 58 of 60 commits that cite a skills file; logged open 48 of 60 (upper bound, see open-event finding); 46 of 106 cited commits cite memories only, which search.py cannot return  [2026-09-18..2026-09-22]
- Quoted 'searched "<terms>"' in Store: lines matched to a logged search within 48h before the commit (any session): 42 of 50 (lower bound: my substring test misses split or reordered probes); 15 of 16 'nothing applicable' lines quote their terms  [origin/main commits 2026-09-18..22]
- Verbatim reuse of Store: citations: 15 identical cited sets, each repeated within one day, cover 50 of 98 citing commits  [2026-09-18..22]
- Relevance sample of 15 most recent landed Store: lines (rubric below in findings): 8 real, 6 weak or ceremonial, 1 'nothing applicable' that was false  [commits dated 2026-09-22]
- Non-code Claude commits that change behaviour-bearing files (not judged): 34 of 111 (alert-registry.json, stores.json, product-urls.json, .claude/agents/*.md, .claude/rules/*.md, scheduled-task .xml, meal-prep/db)  [2026-09-18..22]
- Brain repo (~/.claude) record coverage: 14 commits since 09-18, 8 change code; 4 of 8 carry a voluntary Store: line; 0 judged (0 log rows repo='.claude'); 0 non-sample hooks in ~/.claude/.git/hooks; core.hooksPath unset  [2026-09-18..22]
- Consulted hook, last 7 days: 697 Stop rows, 0 with an agent id; 159 offered turns (507 had no offer, so no obligation); 20 refusals (8 consulted rung = 8 of 159 offered turns, 12 absence rung); 151 of 159 offered turns had a footer; 117 of 151 footers named nothing (and 11 of the 34 'named' read 'nothing new'); after the 8 consulted refusals the next turn said 'nothing relevant' 6 times, named something 2 times  [2026-09-15 18:47 to 2026-09-22]
- Consulted hook decide() edge cases (pure function, in-process): Empty 'Consulted:', a footer at the TOP of the reply, a footer inside a code fence, and a footer naming a nonexistent file all PASS; an analysis reply on a turn with no offer is never checked  [2026-09-22]
- Plan audit: judged=4 missing=0 (3 PLAN + 1 MEASURE); design/RCA-holistic-2026-09-22.md not judged by prefix (has the section voluntarily); triage plans: 16 of 22 non-routing plan-2026-09-2*.json carry knowledge_consulted, checked by no code  [plans dated 2026-09-20..22]
- Re-run of b453a01fb's own 'nothing applicable' query: search.py --files "control byte full path exclude": 'no section contains ALL of: byte, control, exclude, full, path' (exit 0); the rule it applied is in .claude/rules/ops-and-gates.md and memory filtering-a-walk-is-not-pruning-it, neither indexed by search.py  [2026-09-22]

## Findings

### commit-hook-coverage-complete [strength/code/medium] VERDICT=OVERSTATED
The commit record check is live, complete on landed commits since install, and adoption has converged

CORRECTED: On landed commits the hook is nearly complete: 130 of 132 Claude code commits after install have a decision row, and the 2 without one were made in the first 6 minutes. Adoption of the Store: line has converged; the landed replay refuses 1 of 28 on 09-22. Two parts of the claim do not hold.
- The rule is enforced per checkout. The shared hook runs `$top/ops/store_citation.py` from whichever checkout commits. On 2026-09-22, 57 of 92 checkouts have no copy and are silently unjudged, 29 run the older 09-18 resolver, and only 6 run the current one.
- Resolver warnings are rising, not converging. They went from 3 on 09-20 to 10 of 53 attempts on 09-22, mostly on branch commits that have not landed yet.
The mapper's replay window is also mislabelled. A date-only `--since=2026-09-18` starts at the current time of day on 09-18: 266 commits against 434 from midnight. So its '09-18: 14 of 18' row covers only the evening.

FIX: Keep it. Build on store_citation.py rather than beside it. Every change below extends judge_message/resolve and its self-test, and the expected-case constant (currently 24 at line 335) moves with each new case.

CRITIQUE: 'Keep it and build on store_citation.py' is right. A lower-effort implementer will assume a fix on main is live everywhere. It is live only in checkouts rebased past it, and a checkout with no copy is never judged at all. The plan must choose one of two designs and say which:
(a) The hook resolves the MAIN checkout's store_citation.py through `git rev-parse --git-common-dir`. One rule everywhere, but a branch cannot test its own edit to the rule.
(b) Keep the per-checkout copy, and have the hook print `store-citation: BLIND - this checkout has no ops/store_citation.py` instead of exiting 0 silently.
Every new case must also bump the expected-case constant (24, line 335).
The fixture must prove the hook's behaviour when the script is absent: it is loud, exits 0, and the report can count those commits. It needs a temp repo with the hook installed and no script.

### skills-citations-tied-to-searches [strength/both/low] VERDICT=CONFIRMED
A cited skills file almost always came out of that session's own search

CORRECTED: When a code commit cites a skills file, that file nearly always came out of the same parent session's own search in the prior 24h: 54 of 60 in my join, 58 of 60 in the mapper's. The gap is path normalisation, not substance. This proves provenance at session level, not that the change used the file. And because backing is keyed on the parent session (see backing-is-per-session), it does not prove that the committing agent searched.

FIX: No change to the skills half. Reuse this join (search.paths vs cited) as a report line in store-usage-report.py (see report-denominators finding) so the strength stays measured.

CRITIQUE: Adding this join to store-usage-report is cheap. A lower-effort implementer will compare raw strings. Search paths are skills-root-relative with forward slashes, while citations can carry a 'skills/' prefix or backslashes. Normalise both sides with one function and share it with the resolver.
Fixture: MUST FIRE, a citation of `skills/x/MAP.md` matches a search path `x/MAP.md`. MUST NOT FIRE, a search by a different sid backs nothing. The citation must count per session AND per agent once agent ids exist.

### plan-half-substantive [strength/analysis/low] VERDICT=CONFIRMED
New plans and MEASURE docs carry real Knowledge consulted sections that name rules, memories and estate exemplars

CORRECTED: All 4 of 4 judged plans (3 PLAN and 1 MEASURE, dated 2026-09-20 to 09-22) carry substantive sections that cite rules, memories and estate exemplars, and the unjudged RCA doc does too. Two of them spell rules paths with backslashes: `.claude\rules\ops-and-gates.md` in PLAN-live-recipe-prices and PLAN-per-cell-quarantine.

FIX: Keep the section check as it is. Use these four docs as the exemplars that agent prompts point to. Any resolution of plan citations stays warn-only (see plan-audit-scope).

CRITIQUE: Keeping the plan check as a presence check is right. The trap is in plan-audit-scope step 3: a resolver copied from the commit half cuts `.claude\rules\ops-and-gates.md` to `ops-and-gates.md` and reports it unresolved. It would also fail on a bare memory name with no `memory:` prefix, such as `prose-templating`.
Any resolution of plan tokens must normalise separators first, stay WARN-only, and have a MUST NOT FIRE fixture built from these four real sections.

### resolver-refuses-estate-knowledge [issue/code/high] VERDICT=CONFIRMED
From 2026-09-25 the commit check REFUSES citations of the estate's own rules, design docs and machinery, the knowledge goal 1 names

CORRECTED: From 2026-09-25 the commit check will refuse any commit whose Store: line cites the estate's own rules files, design docs or code. This is the knowledge goal 1 names. Landed commits 09-20..22 would give 4 of 56 refusals. On 09-22, 10 of 53 attempts in the log already warned for this reason, so the use of these citations is growing.

FIX: File: C:\Codex\ThriftyCrew\ops\store_citation.py only. Same hook event: git commit-msg.
1. home_store() gains repo_root. run_commit_check fills it from `git rev-parse --show-toplevel`, and fills a tracked-path set from ONE `git ls-files` call. Run both with the inherited env: under a pathspec commit, GIT_INDEX_FILE names the index being committed, which is the right one.
2. PATH_RE also admits repo paths with code or config extensions: `[\w.-]+(?:/[\w.-]+)+\.(?:md|ps1|psm1|py|js|json)`.
3. resolve() tries the store bases first. It then accepts a repo-relative token only when it is in the tracked set. A bare `grocery.md` also tries `.claude/rules/<name>`.
4. judge_message records cited_kinds {store, rules, design, machinery}. A machinery or rules citation satisfies the rule exactly as a store file does.
5. Failure mode: if git ls-files fails, repo tokens are accepted as `repo_blind: true` in the log row. It fails OPEN, because a could-not-look must not refuse (header line 33).
6. Telemetry: the log row gains cited_kinds and repo_blind; store-usage-report prints the kind mix.
7. Fixtures in selftest():
   - build a temp git repo, clearing GIT_DIR, GIT_INDEX_FILE and GIT_WORK_TREE from the subprocess env (the ops-and-gates fixture rule), holding a tracked .claude/rules/r.md and lib/x.ps1
   - MUST NOT FIRE: `.claude/rules/r.md` passes
   - MUST NOT FIRE: `lib/x.ps1` passes with kind machinery
   - MUST NOT FIRE: bare `r.md` resolves through .claude/rules
   - MUST FIRE: `.claude/rules/nope.md` is refused
   - MUST FIRE: a file present on disk but UNTRACKED is refused (proves the tracked test, not os.path.exists)
   - CLEAN TWIN: `memory:ps-null` still resolves
   - CLEAN TWIN: an unlistable repo gives repo_blind and ok
   - expected count 24 -> 31
8. Acceptance bar, written now: replaying origin/main 2026-09-20..22 through the new resolver gives 0 of 56 refused, down from 4. Re-run scratchpad\review\replay_citations.py logic to show it.
9. Also update the refusal text (lines 236-240) and the six .claude/agents prompts plus their ops\prompt-backup mirrors. The prompt-backup audit reds a mirror left behind. Add an example `Store: .claude/rules/ops-and-gates.md (<rule>); lib/atomic-write.ps1 (reused)`.
10. If this cannot land by 2026-09-25, say so to Brad: the date is his to move, not the implementer's.

CRITIQUE: The direction is right, but a lower-effort implementer will get six things wrong.
1. Self-citation. `git ls-files` membership is true of the very code files the commit changes, so `Store: ops/x.ps1` on a commit editing ops/x.ps1 would pass. Staged code paths must not satisfy the rule.
2. The rules files are loaded automatically for their directory, so a bare `.claude/rules/ops-and-gates.md` on every ops commit is the CLAUDE.md escape again. Log `rules_without_section` and report it. Do not refuse on it, since 574722dab cites the file with no section.
3. Normalise before matching: backslashes, `~/.claude/skills/...` and absolute `C:\...` forms. Today `reliability-craft\MAP.md` is cut to `MAP.md` and refused.
4. The bare-name fallback to `.claude/rules/<name>` must run only after the store bases miss, or a repo `CLAUDE.md` shadows the index-file check in cheap-escape-hatches.
5. It binds only rebased checkouts: 29 of 92 checkouts still run the 09-18 resolver. The plan must say how long-lived worktrees get the fix before 09-25, or ask Brad to move the date.
6. Update the six agent prompts and their prompt-backup mirrors in the same change.
Fixtures: the mapper's seven cases, plus MUST FIRE citing only a staged code file, plus MUST NOT FIRE on `.claude\rules\r.md` spelled with backslashes. The acceptance bar (0 of 56 on the 09-20..22 replay) must be run with an explicit `--since=2026-09-20T00:00:00`.

### null-search-blind-to-estate [gap/both/high] VERDICT=CONFIRMED
'Store: searched X, nothing applicable' is structurally likely to be false, because the only search it points to cannot see memory, rules or code

CORRECTED: The one search the Store: rule points to cannot see memories, rules or code. So a `nothing applicable` line reports on the skills store only, yet the record reads it as 'the brain had nothing'. In b453a01fb the walk rule WAS applied: the diff comment quotes it. So the loss is in the RECORD. The knowledge still reached the code, through the path-scoped rules file. The same 5-term query over the rules root finds the rule, so the corpus is the difference, not the query. There is a workaround today, `search.py --root <dir>`, but nothing tells anyone to use it.

FIX: File: ~/.claude/skills/knowledge-search/search.py.
1. Add flag `--estate`. It adds three things:
   - the memory dirs of BOTH launch roots (import store_citation's MEMORY_PROJECTS list, or duplicate it with a comment naming the source)
   - the MAIN checkout's .claude/rules, derived from `git rev-parse --git-common-dir`'s parent, NOT from cwd, because a worktree cwd maps to an empty memory dir
   - a literal grep leg: `git -C <main> grep -l -i -F -e <term>` over tracked *.ps1/*.py/*.js, capped at 10 files per term, printed under a separate 'MACHINERY (grep, unranked)' header. It is never fused into the BM25 scores, because three score spaces share no scale.
2. The search log row gains "corpus": [...] and "cwd".
3. Failure: the grep leg or a missing dir prints `ESTATE-LEG BLIND <why>` and still returns the skills results. It fails open and says so.
4. store_citation.py (report only, never refuse): record null_estate_backed = whether this session logged a search with corpus containing 'estate' in BACKING_HOURS. store-usage-report prints 'nothing-applicable lines backed by an estate search: X of Y'.
5. Change the recommended command in the refusal text and the six agent prompts plus mirrors to `search.py --estate`.
6. Fixtures in search.py --selftest (temp root):
   - MUST FIRE: `--estate "path below root"` returns a temp rules file holding that rule
   - MUST NOT FIRE: the same query without --estate does not return it (proves the flag is the difference)
   - MUST FIRE: the grep leg names a temp tracked .ps1 containing Get-TcPathBelowRoot
   - MUST NOT FIRE: an untracked file with the same text is not named
   - CLEAN TWIN: default output on the existing fixture set is byte-identical
7. Acceptance bar, written before the run: rerun the quoted terms of the 16 null-form commits with --estate. If a reader judges a relevant rules or memory section returned for at least 5 of 16, make --estate the recommended default. Otherwise record the result and keep it opt-in.

CRITIQUE: A lower-effort implementer will write a third BM25 index. recall_index.py already builds a persisted, corpus-tagged index over skills, memory and rules. `--estate` should call it with the right roots. The roots must come from the main checkout, found through `git rev-parse --git-common-dir`, because project_key(cwd) maps a worktree to an empty memory directory. Fix that in resolve_roots once, which also repairs the hook's corpus for worktree sessions.
The grep leg should require all terms in one file (`git grep --all-match -e a -e b`), leave out the files being changed, and stay unranked under its own header.
The acceptance bar must re-run each of the 16 null queries with the flags recorded in its own search-log row, so a --files query stays --files. It must also say that a single reader judged relevance.
Fixture: MUST FIRE with --estate finds a temp rules file. MUST NOT FIRE without the flag. CLEAN TWIN: default output is byte-identical. Plus a case with a worktree cwd, which must resolve to the main checkout's memory.

### backing-is-per-session [issue/both/medium] VERDICT=CONFIRMED
'Backed by a logged search' is judged per parent session over 24h, so it is nearly always true and cannot say which agent searched

CORRECTED: 'Backed' means the PARENT session logged any search in the prior 24h. So 175 of 179 code rows are backed, and the figure cannot say whether the agent that committed ever searched: 0 of 158 search rows carry an agent id.

FIX: 1. File ~/.claude/skills/recall-log-open.py (PostToolUse, matcher Read|Bash|PowerShell):
   - when tool_input.command matches `knowledge-search[\\/]+search\.py` and the leading verb is not a reader (cat, type, Get-Content, sed), append {ev:'search-call', sid, agent: payload agent_id, cwd, t, q: command[:200]}
   - when it matches `\bgit\b[^|;]*\bcommit\b`, append {ev:'commit-call', sid, agent, cwd, t}
   - PostToolUse never fires on a failed call, so a refused commit logs nothing, which is correct
2. File store-usage-report.py:
   - add 'per-agent backing': for each commit-call, was there a search-call by the same (sid, agent) earlier in that session
   - join commit-call to a store-citation row by sid, repo == basename(cwd) and |dt| <= 120 s
   - print it beside the session-level figure, with both denominators
3. Never refuse on it.
4. Fixtures in recall-log-open's existing selftest (it has one: 5 mentions):
   - MUST FIRE: a Bash payload `C:\Codex\Python312\python.exe ...\search.py "x"` with agent_id a1 logs search-call agent a1
   - MUST NOT FIRE: `cat ...\search.py` logs no search-call
   - CLEAN TWIN: existing open rows unchanged
5. store-usage-report selftest:
   - MUST FIRE: a commit by agent a2 in a session where only a1 searched counts unbacked per agent
   - CLEAN TWIN: the session-level number is unchanged
6. Verify first, and say so if it fails: that a Workflow agent's PostToolUse payload carries agent_id for Bash (observed for Read/Bash in this review) and for PowerShell.

CRITIQUE: PostToolUse is the right carrier, because its payload holds agent_id on 2266 open rows. A lower-effort implementer will get five things wrong.
1. Placement. The new search-call and commit-call rows must be written BEFORE `if not found: return 0` (line 242). paths_from_command also returns [] for any command containing 'git commit', so a branch added inside it never fires.
2. Regex. `\bgit\b[^|;]*\bcommit\b` also matches `git log --grep commit` and `commit-msg`. Anchor it on `git( -C \S+)? commit\b`.
3. Join window. PostToolUse fires after the commit's own hooks finish, and ThriftyCrew's pre-commit can be slow, so a 120 s join window is not safe. Join on sid, agent and message subject, reading the -F file when it exists.
4. From 09-25 a refused commit fires no PostToolUse, so per-agent figures after that date count only passing commits. Say so in the report.
5. The fix is report-only, and it must never refuse.
Fixture: MUST FIRE, agent a2's commit in a session where only a1 searched is unbacked per agent. MUST NOT FIRE, `git log --grep commit` logs no commit-call. CLEAN TWIN: existing open rows are unchanged.

### brain-repo-unjudged [gap/code/medium] VERDICT=CONFIRMED
The brain's own code (~/.claude repo) has no commit-msg hook, so the rule does not bind the machinery that enforces it

CORRECTED: The brain repo has no commit-msg hook. Since the rule landed (09-18 19:14), 3 of 5 brain code commits carried a voluntary Store: line and 2 did not. The mapper's '4 of 8' counts 3 commits made at or before the rule landed. Brain hooks run from the WORKING TREE: 13 files are modified and uncommitted right now. A commit-time record therefore arrives after the code is already live in every session on the box.

FIX: 1. Add tracked ~/.claude/skills/hooks/commit-msg (bash, LF), copying ThriftyCrew's BOM refusal half, then:
   `py=/c/Codex/Python312/python.exe; sc=/c/Codex/ThriftyCrew/ops/store_citation.py; if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -x "$py" ] && [ -f "$sc" ]; then "$py" "$sc" --commit-msg "$1" || exit 1; fi; exit 0`
   That keeps one copy of the rule, and a missing interpreter or script fails OPEN. store_citation's cwd-based staged-file listing and repo=basename(cwd) then log repo='.claude'.
2. Add ~/.claude/skills/install-brain-hooks.py: copy to `git -C ~/.claude rev-parse --git-path hooks`/commit-msg with LF, read it back, compare bytes; `--check` exits 1 when missing or stale, 3 when blind. This mirrors ops/install-hooks.ps1.
3. Put `install-brain-hooks.py --check` wherever the nightly brain report is assembled, so a disarmed hook shows in recall-sleep-latest.md. That location is not verified; find the writer of recall-sleep-latest.md first.
4. Fixtures in install-brain-hooks.py --selftest: a temp git repo (GIT_DIR, GIT_INDEX_FILE, GIT_WORK_TREE cleared); a date override env var read only by store_citation's selftest path (e.g. STORE_CITATION_TODAY, honoured only when --selftest-hook is passed); stage a .py with no Store: line.
   - MUST FIRE: CLAUDE_CODE_SESSION_ID set, refuse date: exit 1
   - MUST NOT FIRE: no session id: exit 0
   - CLEAN TWIN: a BOM-prefixed message is still refused
5. Fantasy: record the stale CLAUDE.md row for Brad; do not install hooks there without his ruling (no commits in two weeks).

CRITIQUE: The one-copy design is sound: call ThriftyCrew's store_citation.py, and fail open when it is missing. Four details are easy to get wrong.
1. It binds the brain to the main checkout's WORKING TREE, which the 07:00 bot rewrites and sessions edit. Resolve the script through ThriftyCrew's git-common-dir, never a worktree path.
2. NOT_CODE_PREFIX is ThriftyCrew-specific, and so is the refusal text's example.
3. The date override env var must be read only under the selftest flag.
4. It does not cover uncommitted brain edits, which is the larger gap. The plan should say that the brain's record point is the edit, and that the nightly report should list brain files left uncommitted for more than N hours, not only a disarmed hook.
Fixture: MUST FIRE, a session-id commit of a .py with no Store: line on the refuse date exits 1. MUST NOT FIRE with no session id. CLEAN TWIN: BOM refusal. Plus a case where the ThriftyCrew script is absent, which exits 0 and says BLIND.

### behaviour-files-unjudged [gap/code/medium] VERDICT=CONFIRMED
Commits that change behaviour through config, prompts or task definitions are not judged at all

CORRECTED: Commits that change behaviour through config, prompts, rules or task XML are never judged. On the fix's own explicit list that is 23 of 195 non-code Claude commits (09-18..22). The mapper's 34 of 111 used a narrower window and a broader filter that included product-urls.json and meal-prep/db, which its own fix then excludes.

FIX: File: ops/store_citation.py.
1. Add is_behaviour(path): true for .claude/agents/*.md, .claude/rules/*.md, .claude/skills/**/*.md, ops/scheduled-tasks/*.xml, grocery/alert-registry.json, grocery/stores.json, grocery/expected-automations.json and ops/chain-manifest.json. Keep an explicit list, not a glob of *.json. Data rulings (known-wrong.json, product-urls.json) stay unjudged.
2. judge_message: when code_files is empty and behaviour_files is not, apply the same Store: rules but verdict 'warn' ALWAYS, never 'refuse' (a new key mode_behaviour='warn-only'), and log behaviour_files.
3. store-usage-report prints 'behaviour commits with a Store: line: X of Y'. After 14 days Brad decides whether behaviour files join the refusal.
4. Fixtures:
   - MUST FIRE: an agents-prompt-only commit with no Store: line on the refuse date gives verdict warn, never refuse
   - MUST NOT FIRE: a grocery/out/*.json-only commit is not judged
   - CLEAN TWIN: a .ps1 commit with no Store: line is still refused on the refuse date

CRITIQUE: A lower-effort implementer will make four mistakes.
1. Reusing staged_code_files(). It filters to is_code, so behaviour files never reach judge_message. List the staged files once and split them.
2. Reusing verdict 'warn'. The message head then prints 'WARNING (refused from 2026-09-25)', which is false for a warn-only class. It needs its own head and verdict, and must never return 1.
3. Mirrors. ops/prompt-backup/ mirrors of agent prompts sit under NOT_CODE_PREFIX. The explicit list must not judge a mirror, or it will judge one prompt twice.
4. Report scope. store-usage-report's `code` filter is code_files>0. Behaviour rows need their own counter and must be kept out of the 80% bar.
Fixture: MUST FIRE, an agents-prompt-only commit on the refuse date gives the new warn verdict with exit 0. MUST NOT FIRE on a grocery/out json. CLEAN TWIN: a .ps1 with no line is still refused. Plus a mirror-only commit, which is not judged.

### analysis-record-thin [gap/analysis/high] VERDICT=CONFIRMED
Goal 2 has almost no record check. Only main-thread turns that were OFFERED something are checked, and any footer passes.

CORRECTED: The goal-2 record covers only main-thread turns that were OFFERED something, and any footer text passes. 541 of 700 Stop turns in 7 days had no offer and so owed nothing. No subagent or Workflow-agent turn is checked (0 of 700 rows carry an agent id). The mapper's '507 of 697 had no offer' is an arithmetic slip: 697 minus 159 is 538. The header says the footer must END the reply, but FOOTER_RE matches any line.

FIX: File ~/.claude/skills/recall-consulted-hook.py (+ settings.json).

(1) MEASURE FIRST: write a logging-only probe hook on SubagentStop, as was done for headless on 2026-09-19, and capture one payload each for an Agent-tool subagent and a Workflow agent. Record whether agent_id, agent_transcript_path and last_assistant_message are present. If the transcript path is the parent's, the reply must come from last_assistant_message.

(2) SUBAGENT TELEMETRY, never refuse:
- register recall-consulted-hook.py on SubagentStop
- add a branch in main(): event == 'SubagentStop' computes decide() and writes a row {event:'SubagentStop', agent, would_refuse, rung, named}, then returns 0 unconditionally
- MUST NOT FIRE fixture: a SubagentStop payload with an offer and no footer exits 0 and logs would_refuse=true
- CLEAN TWIN: a Stop payload with the same state still exits 2

(3) ANALYSIS RUNG on the main thread, log-only for 7 days:
- new ~/.claude/skills/recall_analysis.py owes_line(text) -> (bool, cue), with cues: a rate 'N of M', 'root cause', 'the cause is', 'verdict', 'because' within a sentence carrying a number
- decide(): after rung 2, when nothing was offered and owes_line fires, log rung 'analysis', would_refuse=true, and return False
- store-usage-report (or recall-brain) prints the would-refuse rate over main Stop rows
- Brad decides whether it refuses. When live it wants a Consulted: or a Checked: line, one refusal per turn, and every existing brake
- fixtures: MUST FIRE on 'the median moved 12% over 40 of 52 cells, so the ratchet is wrong'; MUST NOT FIRE on 'pushed, gates green'; MUST NOT FIRE once a Consulted: line exists

(4) TIGHTEN THE FOOTER (safe now, fixtures from this review's probe):
- a footer counts only if it is among the last 8 non-empty lines, is outside ``` fences, and has non-whitespace after the colon
- MUST FIRE: an empty 'Consulted:', a code-fence-only footer and a top-of-reply footer are each refused
- MUST NOT FIRE: 'Consulted: nothing relevant' and a named file pass

(5) REPORT, never refuse: log opened_this_turn (count of ev=open rows for this sid+agent since consulted_last_stop), and print 'nothing relevant after >=1 open' as a contradiction count.

All paths fail open as now.

CRITIQUE: Five traps.
1. SubagentStop telemetry rows must go to their OWN log. The header says recall-brain's footer rate uses every main-log row as its denominator, and that is why the skip log exists.
2. main() derives the logged rung from `why` ('absence' or else 'consulted'). A lower-effort analysis rung will be logged as 'consulted' and corrupt recall-answer-outcome.py's per-rung scoring. Add a third rung value explicitly.
3. Step 4's 'safe now' is unmeasured. The log does not record where a footer sits, so nobody knows how many of the 151 footers fall outside the last 8 lines. The position rule also has to allow a trailing `Checked:` line. Measure it over transcripts before shipping, and ship it log-only first.
4. The analysis cue regex will fire on most replies that carry a number. Its precision needs a hand-labelled sample of fires with a denominator before anything refuses, and the bar must be written first.
5. The SubagentStop payload shape is unmeasured, so a probe comes first.
Fixture: a SubagentStop with an offer and no footer exits 0 and writes only to the new log. The Stop twin still exits 2. An analysis would-refuse row carries rung='analysis'.

### plan-audit-scope [gap/analysis/low] VERDICT=CONFIRMED
The plan audit's prefix and schema miss analysis records: RCA/EVAL docs and triage-plan JSON

CORRECTED: The plan audit judges only PLAN-/MEASURE- markdown. The RCA doc and the triage-plan JSON records, which are the triage lanes' diagnosis, are outside it. 17 of 22 non-routing triage plans (dated 09-20 to 09-22) carry knowledge_consulted voluntarily, and no code checks it.

FIX: File ops/store_citation.py.
1. PLAN_RE prefix becomes (PLAN|MEASURE|RCA|EVAL|REVIEW|AUDIT). Today 1 RCA doc is in scope and it passes, so the change is zero on day one; verify by running the audit.
2. Add triage_plan_findings(dir, cutoff=<landing date + 1>): grocery/triage-plans/plan-YYYY-MM-DD*.json, excluding *.routing.json, dated on or after the cutoff, must have a non-empty knowledge_consulted value (string or list). Wire it into run_plan_audit's marker, e.g. STORE-CITATION-PLANS-COMPLETE judged=.. missing=.. triage_judged=.. triage_missing=..
3. Resolve tokens in plan sections through the new resolver (see resolver-refuses-estate-knowledge) and PRINT unresolved ones as WARN lines. Never fail on them.
4. Fixtures:
   - MUST FIRE: a triage plan dated at the cutoff with an empty knowledge_consulted list is missing
   - MUST NOT FIRE: a routing file is not judged
   - MUST NOT FIRE: a plan dated the day before the cutoff (the at-the-bar pair)
   - CLEAN TWIN: an RCA- doc with a filled section passes
   - update the expected case count

CRITIQUE: A lower-effort implementer will get four things wrong.
1. Type handling. knowledge_consulted appears as a string or a list. Treat an empty list, an empty string and whitespace as missing, and read the file with utf-8-sig.
2. The cutoff pair. Put one case at the cutoff date and one the day before, with the numbers chosen so the date comparison decides the result.
3. Token resolution must normalise backslashes and stay WARN-only (see plan-half-substantive).
4. Adding RCA, EVAL and similar prefixes must first be run over the tree so it lands at zero missing. The dated-name requirement in PLAN_RE also applies to those prefixes.
The fixtures the mapper listed are right. Add a CLEAN TWIN: an existing PLAN doc still passes.

### ceremonial-copy-paste [issue/code/low] VERDICT=PLAUSIBLE
Relevance sample: 6 of 15 recent Store: lines are weak or ceremonial, and batches paste one line across commits

CORRECTED: About half the citing commits (50 of 98, 09-18..22) share a cited set pasted within one day, which shows that batches reuse a single line. Whether a given line is ceremonial is one reader's judgement over 15 commits and has no second judge, so '6 of 15 weak' is unqualified.

FIX: File store-usage-report.py, report-only:
1. Print 'verbatim-repeated Store: lines: X of Y citing commits' by grouping on (date, sorted cited).
2. Replace 'last 10 cited' with 10 cited commits drawn by a [Random] seeded on the ISO week number and printed with the seed. The Get-Random ruling allows seeded, replayable test input.
3. For a parenthetical section name, check the heading exists in the cited file and print unmatched ones. This catches a wrong anchor name, not a wrong relevance, so say so in the header.
4. Optional and warn-only, Brad's call: a template `Store: <file> (<section>) -> <what it changed here>`, and report the share carrying '->'.
5. Fixtures:
   - MUST FIRE: two commits with identical cited sets on one day count 2 repeated
   - MUST NOT FIRE: the same set on different days counts 0
   - CLEAN TWIN: an existing summarise() total is unchanged

CRITIQUE: Report-only is right, because relevance cannot be gated.
1. Heading check. A lower-effort check will do exact string matching. Citations say '(section 7)', 'section 3' or '(The four techniques)', while headings read '## 7. A firing check...' and '### The four techniques, and what each is actually for'. Match numbers against the heading prefix and text as a case-insensitive prefix. State in the header that this checks the anchor, not relevance.
2. Seeded sample. Draw from one random.Random(seed) owned by the report, print the seed, and dedupe by subject first, or a pasted batch dominates the sample.
Fixture: MUST FIRE, two identical sets on one day count 2. MUST NOT FIRE, the same set on different days. Plus a heading-match case for the numbered form.

### cheap-escape-hatches [issue/code/low] VERDICT=CONFIRMED
Once refusal starts, three cheap forms still pass

CORRECTED: Several near-empty forms pass the check today, and use is currently low. The strongest escape is outside this list: `git commit --no-verify` skips the whole hook (see missed findings).

FIX: File ops/store_citation.py:
1. NOTHING_RE requires a quoted term: `searched\s+["“][^"”]{3,}["”].*\b(nothing|none)\b.*\bapplicable\b`.
2. INDEX_FILES = {CLAUDE.md, MEMORY.md, memory:MEMORY, CATALOGUE.md, knowledge-search/SKILL.md, knowledge/SKILL.md}. A citation set drawn only from these reads as 'names no store file'.
3. Store-Exempt needs at least 3 words. Log it with why and the staged code paths, and store-usage-report lists every exemption (it already prints them).
4. Land as WARN for one week (a separate why string) before these join the refusal, so the week's count is measured first.
5. Fixtures:
   - MUST FIRE: 'searched, nothing applicable' with no quoted terms
   - MUST FIRE: 'Store: CLAUDE.md' alone
   - MUST FIRE: 'Store-Exempt: x'
   - MUST NOT FIRE: 'Store: searched "regex timeout", nothing applicable'
   - CLEAN TWIN: 'Store: CLAUDE.md; memory:ps-null' passes

CRITIQUE: Three interactions a lower-effort implementer will miss.
1. Once the repo resolver lands, `CLAUDE.md` and `MEMORY.md` resolve against the repo too. The index-file test must apply after resolution, keyed on basename, covering skills/CATALOGUE.md, the repo CLAUDE.md and the ~/.claude one.
2. The quoted-term NOTHING_RE must accept smart quotes and the observed 'nothing further applicable' wording (a66ef0e94), or a real null line gets refused.
3. A line that cites a file AND says 'nothing applicable' passes today. Keep that.
The one-week WARN period must be measured with its own why string, and the refuse date for these forms is Brad's.
Fixture: all the mapper's cases, plus a CLEAN TWIN for the 'nothing further applicable' wording.

### report-denominators [inefficiency/both/low] VERDICT=CONFIRMED
The weekly bar mixes attempts, branch commits and retries, and its 'backed' figure adds nothing to 'recorded'

CORRECTED: The report's 'backed' figure repeats 'resolving' (129 of 129 ok rows are backed). Its denominator mixes landed commits, branch attempts and duplicate rows (14 extra). The 72% miss comes from the flagged rows: 27 with no line on 09-18/19, 13 to 15 from the resolver defect, and 6 that name nothing. It does not come from sessions failing to search.

FIX: File store-usage-report.py:
1. Dedupe by (sid, subject), keeping the last row.
2. Add `--repo <path> --ref origin/main`: import store_citation from <path>\ops, replay judge_message over Claude-coauthored non-merge commits since the window start (the logic in scratchpad\review\replay_citations.py), and print 'landed' figures beside 'attempted' figures.
3. Split flagged reasons into 'no line', 'unresolved: repo path', 'unresolved: other' and 'names nothing', so a resolver defect is visible as one line.
4. Print the per-agent backing from backing-is-per-session.
5. Fixtures:
   - MUST FIRE: two rows with the same sid+subject count once
   - MUST FIRE: an unresolved '.claude/rules/x.md' is classed repo-path
   - CLEAN TWIN: a single-row week gives the same totals as today
6. The store-usage-weekly SKILL step 2 names the landed figure as the one against the bar.

CRITIQUE: Three traps.
1. The landed replay must use `--since=<start>T00:00:00`. A date-only --since starts at the current time of day, which is how the mapper's own replay lost most of 09-18.
2. The replay must print landed Claude code commits that have NO decision row as their own line. That is the only place a `--no-verify` commit becomes visible.
3. Deduping by (sid, subject) and keeping the last row can pick a branch copy over the landed one. Prefer the row whose commit is on the ref.
Fixture: MUST FIRE, a landed commit with no log row is listed. MUST FIRE, a duplicate row counts once. CLEAN TWIN: single-row totals are unchanged.

### open-event-counts-mentions [issue/both/low] VERDICT=OVERSTATED
An 'open' is logged for any Bash command that names a store path, including ls and grep -c

CORRECTED: An 'open' is logged when a shell command contains any read verb (grep and wc count), and then every .md token in the whole command is credited. A bare `ls` of a store file logs nothing. `ls a.md; grep x b.md` logs both files. So open rates are upper bounds for opens made through the shell (2161 of 3465 open rows are via=bash).

FIX: File ~/.claude/skills/recall-log-open.py:
1. Classify the Bash verb. cat, type, Get-Content, sed -n, head, tail, less, more, or python -c with open( give via='bash-read'; anything else gives via='bash-mention'.
2. store-usage-report and recall-brain count only via in {read, bash-read} as opens.
3. Fixtures:
   - MUST FIRE: `cat skills/x/MAP.md` gives bash-read
   - MUST NOT FIRE: `ls skills/x/MAP.md` gives bash-mention
   - MUST NOT FIRE: `grep -c foo skills/x/MAP.md` gives bash-mention
   - CLEAN TWIN: a Read-tool open is unchanged

CRITIQUE: A lower-effort implementer will classify the whole command by its first verb. It must split on ; && | and attribute each token to the verb of its own segment.
It must not change the meaning of existing via values. The file's own header warns that a schema change that invalidates the history loses the baseline. Add a new field (read_kind) and leave via alone.
The decay and forget consumers must either keep counting what they count now or be changed deliberately in the same plan. Otherwise memories that are grepped start decaying faster.
Fixture: MUST NOT FIRE, `ls a.md; grep -c x b.md` credits b.md only. CLEAN TWIN: a Read-tool open is unchanged. Plus a case showing recall_memory_decay's input count is unchanged.

## Missed by mapper
- [medium] `git commit --no-verify` skips the Store: check entirely, leaves no decision row, and the estate's own pre-commit hook recommends it: Verified in a hermetic temp repo (GIT_DIR, GIT_INDEX_FILE and GIT_WORK_TREE unset), with a commit-msg hook that exits 1. A plain commit returned rc=1. `git commit --no-verify` returned rc=0, the hook never ran, and the commit landed.
The ThriftyCrew hook ops/hooks/pre-commit tells the author to use `--no-verify` in 6 refusal messages (lines 52, 78, 89, 98, 110, 124).
recall-reflexes.json has 30 rows, and `grep -c no-verify` returns 0.
store-usage-report reads only store-citation-log.jsonl, so a bypassed commit cannot appear in the weekly bar. Today 2 of 132 landed Claude code commits after install have no row, both within 6 minutes of install, so the bypass has not been exercised yet. From 2026-09-25 it is the obvious way out.
The fix needs two parts: a remind reflex on `git commit` with -n or --no-verify, and the landed-commit replay in store-usage-report listing commits with no decision row.
- [high] The rule is per checkout: 57 of 92 checkouts are silently unjudged and 29 run the 09-18 resolver, so a resolver fix on main does not reach them: ops/hooks/commit-msg lines 48-52 run `$top/ops/store_citation.py` from the committing checkout, and exit 0 silently when it is absent. I compared the blob in all 92 `git worktree list` checkouts on 2026-09-22:
- 6 hold the current d7ca8c5
- 29 hold 59d00ae, from 1d060a648 (09-18). It reads only the C--Codex-ThriftyCrew memory dir, so a C--Codex memory citation is refused there from 09-25 even though main accepts it.
- 57 have no copy. 7 of those have a HEAD dated 2026-09-18.
The log shows 93 distinct checkout basenames committing since 09-18. I did not measure which checkouts are still active.
This is the push-lock shape CLAUDE.md already records ('binds only the checkouts that HAVE' the script). The resolver fix and the date move must account for it.
- [low] Windows and home-relative path spellings in a Store: line are refused: probe_resolve.py, with today set to REFUSE_FROM:
- `Store: reliability-craft\MAP.md`: PATH_RE cuts it to `MAP.md`, which is refused.
- `Store: C:\Users\Owner\.claude\skills\reliability-craft\MAP.md`: refused.
- `Store: ~/.claude/skills/reliability-craft/MAP.md`: becomes `.claude/skills/...`, refused.
- `skills/reliability-craft/MAP.md` and `reliability-craft/MAP.md` pass.
0 of 219 landed Claude code commits (09-18..22) used a backslash, so this is latent. But the plan docs already spell rules paths with backslashes (PLAN-live-recipe-prices, PLAN-per-cell-quarantine), and the resolver fix adds exactly those paths.
- [low] The mapper's own date windows start at the time of day it ran, not at midnight: On origin/main, `git log --no-merges --since=2026-09-18` gives 266 commits and `--since=2026-09-18T00:00:00` gives 434. A date-only approxidate fills in the current time of day, which was 19:08 when I checked. So the '2026-09-18..22' replay (269 commits, and '09-18: 14 of 18 refused') and the brain-repo '14 commits since 09-18' both cover only the evening of 09-18. Over the full day, 09-18 is 89 of 93 refused and the brain repo has 46 commits. The 09-20..22 figures are unaffected. The report-denominators fix reimplements this replay and must use explicit midnight bounds.
- [low] The consulted hook's documented contract and its code disagree on where the footer must be: The recall-consulted-hook.py header says 'the reply must end with a line beginning `Consulted:`'. FOOTER_RE (line 97) is `^\s*consulted\s*:` with re.M, so it matches any line. probe_consulted2.py shows a footer at the top and a footer inside a code fence both pass (decide returns False, 'footer present'). Whichever side is changed, the fix must first measure how many of the 151 footered offered turns (last 7 days) would change verdict.

## Open questions
- Is Brad content that citing .claude/rules/*.md, design/*.md and estate code (lib/, ops/ gates) should satisfy the Store: rule? Goal 1 as worded says yes, and today's resolver refuses all three from 2026-09-25. If the resolver fix cannot land first, does he move REFUSE_FROM? The date is his call.
- Does a SubagentStop payload for an Agent-tool subagent and for a Workflow agent carry agent_id, its own transcript path, or last_assistant_message? Not measured. It decides whether a subagent consulted-footer telemetry row can read the right reply.
- Does a Workflow agent's Bash/PowerShell environment carry an agent-id variable? Not measured; its PostToolUse payload does carry agent_id, as observed. This decides where per-agent backing is logged.
- Should behaviour-bearing non-code files (agent prompts, rules, alert-registry.json, stores.json, scheduled-task XML) join the Store: rule, and if so warn-only or refusing after measurement?
- Should the brain repo (~/.claude) get the same commit-msg check, given it enforces the rule for everyone else and 4 of its 8 code commits since 09-18 carry no Store: line?
- C:\Codex\CLAUDE.md lists Fantasy as having no git, but C:\Codex\Fantasy has a .git with 5 commits (last 2026-09-07). C:\Codex\income is absent from disk while its memory directory holds 5 files. Which is current?
- store-usage-weekly is an enabled Claude scheduled task. Other task descriptions cite a 2026-08-22 rule that 'Windows tasks are the ONLY routines that fire'. Is this task a sanctioned exception?
- Does Brad want an optional rationale clause ('Store: <file> (<section>) -> <what it changed>')? It makes a pasted line visible to a reader, at the cost of one more convention.
