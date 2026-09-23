# memory-and-budget

A ThriftyCrew session starts with 155,320 B (about 38.8k tokens at the store's bytes/4 convention) of instructions: global CLAUDE.md 4,056 B, C:\Codex\CLAUDE.md 4,871 B, ThriftyCrew CLAUDE.md 12,463 B and MEMORY.md 16,394 B (37,784 B designed to be always-on), plus 117,536 B from all six .claude/rules files.

The rules files are not path-scoped, although everything says they are. Their front matter uses Cursor's `globs:`/`alwaysApply:` keys. Every Claude Code build checked (2.1.173, 2.1.236, 2.1.263, 2.1.280) reads only `paths:`, so every rules file loads unconditionally. The store's 2026-09-06 "correction" to `globs` was copied from Bun's embedded `.cursor/rules/...mdc` template inside claude.exe.

Memory is scoped by where a session starts. The harness loads the MEMORY.md of the git root's store, and worktree sessions correctly get C--Codex-ThriftyCrew's. The recall stack (recall_index.resolve_roots, recall_tiers.named_files, memory_lint.near_duplicates) keys on the raw cwd, so worktree and subdirectory sessions have no memory corpus.

No hook retrieves memory bodies at all. recall-hook and recall-agent-hook query only ["skills"]. The memory semantic index was built on 09-12, NOT SHIPPED on its floor, and is loaded by nothing. 0 of 977 offers in the last 7 days came from memory or rules. Memory bodies are reached only through the MEMORY.md index lines, rules-file [ [citations] ] or a prompt that names the file.

The two live stores do not overlap: C--Codex has 208 memories, C--Codex-ThriftyCrew 186, 0 shared names. C--Codex is where scheduled triage sessions (cwd C:\Codex) write. It holds Brad's rulings hub and 5 rulings dated 09-21/22 that ThriftyCrew-cwd sessions never see. C--Codex-income is an orphan: its project directory no longer exists.

What works: write-time front-matter lint, dangling-link and pointer ratchets, cross-store consolidation clustering, and the harness's own MEMORY.md line-count warning. check-skills budgets only skill descriptions (1,320 of 20,480 B). Nothing budgets CLAUDE.md, rules or MEMORY.md bytes, and check-skills itself exits 1 today.

## Measurements
- Bytes loaded at session start in a ThriftyCrew session: 155,320 B (~38,830 tok at bytes/4): designed always-on 37,784 B (global 4,056 + workspace 4,871 + TC CLAUDE.md 12,463 + MEMORY.md 16,394) + rules 117,536 B (ops-and-gates 74,252, grocery 19,041, meal-prep 9,250, measurement 9,076, site-and-publish 4,682, graph 1,235). Rules are 117,536 of 155,320 B (76%)  [files as of 2026-09-22]
- What a touch of ops/ or grocery/ adds: By design 74,252 B (~18.6k tok) and 19,041 B (~4.8k tok). Observed: 0 B, because both are already loaded at session_start. In a C:\Codex-cwd session, the first read of any ThriftyCrew file attaches TC CLAUDE.md and all six rules at once, about 130 KB (seen as nested_memory attachments in triage transcript ffbacbef...)  [2026-09-22 session]
- TC transcripts whose FIRST claudeMd block carried all six rules files: 33 of 33 (main-checkout and worktree transcripts with a claudeMd block, of 40 modified)  [last 7 days to 2026-09-22]
- Claude Code rules loader key: 4 of 4 CLI builds checked contain `let{frontmatter:X,content:Y}=F(e);if(!X.paths)return{content:Y}`. In 2.1.236 `alwaysApply` occurs once, inside Bun's embedded `.cursor/rules/use-bun-instead-of-node-vite-npm-pnpm.mdc` template. The InstructionsLoaded schema describes `globs` as 'the paths: frontmatter patterns that matched'  [builds 2.1.173, 2.1.236, 2.1.263, 2.1.280 (%APPDATA%\Claude\claude-code\2.1.280)]
- MEMORY.md harness limits vs current size: Harness constants Lte=200 lines, Dpe=25,000 B (2.1.236). TC 114 lines / 16,394 B (66% of bytes). C--Codex 138 lines / 16,006 B. Index lines over ~200 chars: 12 of 114 (TC), 8 of 138 (C--Codex)  [2026-09-22]
- check-skills level-1 budget and overall verdict: level-1 1,320 B of 20,480 B (6%). Exit 1 with 2 FAILs: recall-consolidate has 5 unruled clusters above a mark of 0, and the C--Codex NO_COST count fell to 186 below its mark of 187. Nothing measures CLAUDE.md, rules or MEMORY.md bytes  [2026-09-22]
- Overlap between the two live stores: 0 shared filenames (208 vs 186). 0 description pairs at Jaccard >=0.30 over description and name tokens. 181 of 208 C--Codex memories name ThriftyCrew machinery (loose keyword regex). recall-consolidate reports 12 cross-project clusters, 0 unruled  [2026-09-22]
- C:\Codex-cwd sessions that worked on ThriftyCrew: 17 of 19 C--Codex transcripts touched a ThriftyCrew path; most are grocery-alert-triage scheduled runs  [transcripts modified 2026-09-15 to 2026-09-22]
- Brad-ruling phrases from C--Codex ruling-* memos visible to TC sessions: 0 of 10 distinctive phrases (BOGO, stand-in, recurring shape, with purchase of, REVIEW not FAILED, carries but, OUT OF today, superlative, cheaper-than, exclude rules) found in TC rules + TC CLAUDE.md + TC memory. The 9-ruling hub brad-rulings.md exists only in C--Codex  [2026-09-22]
- TC memory reachability: 149 of 186 linked from MEMORY.md. 37 cited only by rules files, which confirms the index's '37 more' claim exactly. 13 of 186 are reachable ONLY through a rules-file citation (not from the index or an indexed memo). 0 of 186 unreachable  [2026-09-22]
- Dangling pointers: Consolidation pointers: 0 of 42 dangling, 37 of 42 unlinked (mark 37). [ [links] ] dangling: C--Codex 16 (mark 16), TC 3 (mark 3), income 1 (mark 1)  [2026-09-22]
- Recall offers by corpus: 0 of 977 offers pointed at a memory or rules file; all 977 were skills paths. Offer rows carry no corpus key. Opens: memory:C--Codex-ThriftyCrew 92 opens in 15 sessions, memory:C--Codex 57 opens in 4 sessions, skills 1,526 opens in 12 sessions  [last 7 days to 2026-09-22]
- Memory semantic index currency and use: recall-embed-memory-C--Codex-ThriftyCrew.npz holds 170 vectors (built 2026-09-12 06:55) against 186 memory files today. No C--Codex memory index exists. 0 hook scripts reference it: recall_semantic.py:46 loads only recall-embed-index.npz  [2026-09-22]
- Share of TC sessions run from a worktree cwd (recall memory corpus absent): 19 of 40 TC transcripts since 2026-09-16 (145 of 179 since 2026-09-15, which includes a 09-15 batch). resolve_roots on a worktree cwd returns [skills, rules] only. named_files('...propagate-has-no-slugs...') returns 1 hit from the main checkout and 0 from a worktree. 0 memory files across 165 worktree project dirs  [2026-09-15 to 2026-09-22]
- memory_lint.near_duplicates on an exact duplicate description: Returns [] from the main checkout, because the top raw hit (score 34.07, always-commit-and-push.md) comes back as a corpus-relative path and os.path.isfile is False. Returns None from a worktree cwd  [2026-09-22]
- Estate libraries named in always-loaded text: 22 of 41 lib/*.ps1 are named in rules + TC CLAUDE.md; 19 are not, among them json-io, strict-read, input-assert, git-blob-lib, production-text  [2026-09-22]
- Rule leads versus narrative in the rules files: 88 bold-lead bullets total 5,620 B of 117,542 B (4.8%). In ops-and-gates.md, 42 of 49 top-level bullets carry a date and only 8 distinct [ [citations] ] appear  [2026-09-22]
- Verbatim duplication across tiers: 3 (session-start file, memory body) pairs share >=15 8-word shingles: grocery.md with empty-result-has-four-causes (65), meal-prep.md with C--Codex/ruling-prices-fetched-by-pipeline (36), ops-and-gates with ps-ne-is-culture-sensitive (29). The largest pairwise overlap between session-start files is 25 shingles. 'exit code' appears in 5 of 10 session-start files  [2026-09-22]
- Fantasy record tier: 0 of 5 commits since 2026-09-01 carry a Store: line. .git/hooks holds no non-sample hook. Memory store has 0 files. Recall offers appear in 2 of 5 Fantasy transcripts  [2026-09-01 to 2026-09-22]

## Findings

### rules-scope-key-inert [issue/both/high] VERDICT=CONFIRMED
All six .claude/rules files load unconditionally: they use Cursor's globs:/alwaysApply:, Claude Code reads only paths:

CORRECTED: All six .claude/rules files (118,538 B raw, 117,536 B without front matter) load at session start in every ThriftyCrew session, subagent and Workflow agent. Their front matter uses Cursor's `globs:`/`alwaysApply:`, and 5 of 5 installed Claude Code builds (2.1.173 through 2.1.280) scope a rules file only by `paths:`. The harness's internal field is named `globs` but is derived from `paths:`, which is the likely source of the confusion. The 2026-09-06 'correction' was copied from Bun's embedded Cursor template. Observed: 33 of 33 TC transcripts with a readable first instruction block (last 7 days) carried all six. Records built on the false premise: claude-code-craft 11.1, claims-settled C3, BACKLOG E14 at line 1440 (whose goal of shrinking the always-on load was never achieved), the six rules headers, MEMORY.md:94, and ops/audit-rule-currency.ps1 check 1. That check validates a key the harness ignores.

FIX: Do not just rename the key.

STEP 0, measure first. Add C:\Users\Owner\.claude\skills\recall-instructions-log.py on hook event InstructionsLoaded (no matcher; the event exists in 2.1.173-2.1.263). It reads file_path, memory_type, load_reason (session_start|nested_traversal|path_glob_match|include|compact), globs, trigger_file_path, session_id, agent_id and cwd from stdin, and appends one row to ~/.claude/instructions-log.jsonl through recall_append. It prints nothing and always exits 0: telemetry fails OPEN. RECALL_INSTRUCTIONS_LOG redirects the log for --selftest. Add it to automatic-recall.md's hook table, because check-skills asserts table and settings parity. Add recall-instructions-report.py, which prints bytes loaded per session by load_reason, with denominators. Run 3 days.

STEP 1, offer N (global CLAUDE.md rule), with the rubric written first.
- Branch claude/rules-scope-A: convert each `globs: "a, b"` to a `paths:` YAML list and delete alwaysApply.
- Branch claude/rules-scope-B: keep one unconditional .claude/rules/<name>.md per file holding only the bold leads plus a one-line pointer (about 1.5 KB each; 88 leads are 5,620 B in total). Move the depth to .claude/rules/<name>-depth.md with paths:.
- Rubric: (i) session_start bytes in a main-checkout session, bar <= 50 KB against 155 KB today; (ii) a Workflow-agent probe asked to quote one lead from each of the 6 files, bar 6 of 6; (iii) from the instructions log, the share of sessions that Edit a file under grocery/ which loaded the grocery depth before their first Edit, bar >= 90%, N printed.

STEP 2, in the same change: correct claude-code-craft 11.1 (lines 139-183), annotate claims-settled C3 `[REVERSED 2026-09-xx]`, and fix MEMORY.md:94 and the six rules headers. Rewrite ops/audit-rule-currency.ps1 Get-FrontMatterGlobs (line 41) to read `paths:` as a string or a YAML list. Add a HARD exit 2 for any front matter that carries globs: or alwaysApply: and no paths: ('inert scope key: this file loads unconditionally'). Waiver: `rules-scope: unconditional <reason>` in the front matter.
Fixtures:
- MUST FIRE: globs-only front matter.
- MUST NOT FIRE: a paths: list that matches tracked files.
- CLEAN TWIN: a paths: entry matching nothing still exits 2 as today.
- MUST NOT FIRE: no front matter at all, reported as unconditional by design.

STEP 3, a harness-fact probe: skills/probe-harness-facts.py --report, read-only. It greps the newest CLI builds under ~/.local/share/claude/versions and %APPDATA%\Claude\claude-code for the regex `if\(![A-Za-z_$]+\.paths\)return\{content:` and exits 2 when the newest build lacks it. Run it from the weekly store-usage task.
Fixtures:
- MUST FIRE: a temp file without the signature.
- MUST NOT FIRE: a temp file with it.
- CLEAN TWIN (the founding bug): a temp file holding only the Bun template (globs + alwaysApply) still fires.

CRITIQUE: The fix sketch is sound in shape (measure, then offer N, then correct the records). Where a lower-effort implementer goes wrong:

(1) Just renaming `globs:` to `paths:`. That silently REMOVES delivery from Workflow agents and Bash/PowerShell-only sessions, which today get the rules precisely because the load is accidentally unconditional. In 2.1.280 every site that pushes a nested-memory trigger that I inspected is a read path: the FileReadTool operations and a read re-dedup path tagged tengu_file_read_reread. A Set-Content or sed edit never triggers one. Pending triggers are merged only `if(n&&r&&!e.agentId)`, so path-rule delivery to subagents is unproven. For Brad's Goal 1 this makes branch B (always-on lead file plus paths-scoped depth) the safe default. Branch A must not ship until a probe shows a Workflow agent and an Agent-tool subagent receive a path rule after their own Read.

(2) Landing the Step 2 hard `exit 2 on globs-only front matter` before, or separately from, the conversion. run-gates then goes red on day one for every push, including the 07:00 bot. It must land in the same commit as the converted files.

(3) Parsing `paths:` with the existing one-line regex `^\s*paths:\s*(.*)$`. A YAML list yields an empty value, the glob list is empty, and the check passes over nothing. The parser must handle the list form, and a fixture must drive it. The harness strips a trailing `/**`, and a list of only `**` is treated as unconditional; the gate should mirror both.

(4) The InstructionsLoaded logger must be added to automatic-recall.md's hook table in the same change. check-skills asserts 'installed 11, named 11' and fails otherwise.

(5) The harness probe greps 200 to 330 MB binaries. Keep it weekly, never in run-gates.

What the fixtures must prove:
- MUST FIRE: globs-only front matter.
- MUST NOT FIRE: a paths list matching tracked files.
- MUST FIRE: a paths YAML-list entry that matches nothing (proves the list parser).
- The Bun-template fixture still fires.
- A LIVE probe, not a fixture: one Workflow agent and one Agent subagent report which rules they received before and after a Read of grocery/x, recorded with the CLI version.

### memory-bodies-never-retrieved [gap/both/high] VERDICT=OVERSTATED
No hook ever retrieves a memory body: prompt and agent recall query the skills corpus only, and the memory semantic index is built but unwired and stale

CORRECTED: No hook retrieves memory by SIMILARITY. The prompt, agent and intent hooks search the skills corpus only. The one live memory route is name-routing (recall_tiers.named_files), which offers a memory pointer only when the prompt names the file. It served 4 of 8,813 offers all time and 0 of 981 in the last 7 days, and it is dead in worktree cwds (see project-key). The memory semantic index is built (170 vectors, 2026-09-12, now 16 memos stale) and wired to nothing, pending the held-out floor the 2026-09-12 plan required. The '0 of 20' for skills-only retrieval measures whether the memory FILE is returned, which is 0 by construction. It does not show that no skills section answers those questions.

FIX: (1) Extend the question set before fitting anything. Add >= 20 keyed memory-answered questions to the existing 20. Give every row a `source` and include negatives (skills-answered and off-topic prompts), per .claude/rules/measurement.md. Write the bar first, in the doc: held-out hit@3 >= 12 of 20 at the new floor, and <= 2 of 40 skills questions gain an off-topic memory hit.

(2) Run course/derive-semantic-floor.py on one random half, report the other half, and register MIN_COSINE_MEMORY in sidecar/THRESHOLDS.md with its corpus. Record the harness blob and the input fingerprint.

(3) Only if it clears: in recall-hook.py, after the skills semantic leg, load recall-embed-memory-<key>.npz for the RESOLVED project key (see the project-key finding). Inject at most 1 memory hit, shaped as the rule itself (the description line plus the path), under the existing <recall> header, which already names memory/. Fail open: a missing or torn npz adds nothing and logs leg=none.

(4) Add `corpus` to every offer row so the share can be measured by tag. Today it can only be inferred from paths.

(5) Have the nightly TC Recall Sleep 0435 pass rebuild each live store's memory npz when any memory mtime is newer than the npz. Print vectors against files; a mismatch is reported as STALE.

Fixtures:
- MUST FIRE: a prompt paraphrasing a memory's description returns that memory above the floor, over a temp npz.
- MUST NOT FIRE: a skills-only prompt returns no memory hit.
- CLEAN TWIN: the skills leg's offers over the 40 skills questions are unchanged, byte for byte.
- The at-the-bar case for the floor uses a cosine that is exact in float32.

CRITIQUE: Order matters: this fix is useless until the project-key fix lands, because the worktree sessions that write code resolve no memory corpus at all. Also no C--Codex npz exists, so the triage sessions get nothing.

What a lower-effort implementer gets wrong:
(a) Reusing MIN_COSINE 0.548. That is the exact setting that failed, at 11 of 20.
(b) Deriving the floor on all 40 questions, or re-tuning until the held-out half passes. That is selection on noise. Seed and record the split, and derive the floor once.
(c) Assuming the sidecar serves a second index. Check /recall-search accepts an index path, or add a leg that loads the npz in-process. That would be the first numpy import on this hook's path: measure p95 latency against the 1,000 ms bar check-skills already reports (today p50 79 ms, p95 336 ms).
(d) Offering a memory from the wrong store. Key the npz on the RESOLVED store, and keep recall-embed-memory's no-cross-project rule.
(e) Rebuilding the npz nightly without a fingerprint. Record the file count and newest mtime in the npz meta, and have the hook refuse a stale index loudly (leg=stale), not silently.

What the fixtures must prove:
- The negatives: skills questions gain at most 2 off-topic memory hits.
- The CLEAN TWIN: skills offers byte-identical over the 40 skills questions.
- A torn or missing npz yields leg=none and no exception.
- The at-the-bar case uses a float32-exact cosine.
Add the `corpus` key to offer rows first, as its own commit, so the before and after are measurable.

### project-key-from-raw-cwd [issue/both/high] VERDICT=CONFIRMED
The recall stack derives the memory corpus from the raw cwd, so worktree and subdirectory sessions have no memory corpus, while the harness itself loads the right store

CORRECTED: The recall stack derives its memory corpus from the raw cwd. A worktree or repo-subdirectory session therefore has no memory corpus for name-routing (named_files returns [] where the main checkout returns the memo) or for memory_lint.near_duplicates (which returns None). The harness itself loads the canonical C--Codex-ThriftyCrew MEMORY.md in the same sessions. 19 of 40 TC sessions in the last 7 days ran from a worktree dir. project_key also keeps '.' where the harness writes '-', so even the rules tag names a key that matches no transcript dir.

FIX: In recall_index.py, add canonical_root(cwd). It runs `git -C <cwd> rev-parse --path-format=absolute --git-common-dir` with a 2 s timeout and GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE removed from the child env (the ops rule on inherited GIT_DIR). If the result ends in .git, the root is its parent. Cache per cwd in ~/.claude/recall-root-cache.json keyed by cwd and mtime; a cache write failure is ignored. FAIL OPEN: if git fails or the dir is not a repo, fall back to walking up from cwd to the first ancestor that has projects/<key>/memory, then to the raw cwd, which is today's behaviour.

Change project_key to sanitise the way the harness does: re.sub(r'[^A-Za-z0-9]', '-', path). Verify it against every dir under ~/.claude/projects in the selftest: the property is that the key of each recorded transcript's cwd equals its directory name.

In resolve_roots, key the memory corpus on canonical_root, and take rules from the nearest ancestor of cwd holding .claude/rules (the worktree's own checkout). Make named_files and memory_lint.near_duplicates call resolve_roots instead of re-deriving the key.

Telemetry: log `root_via` (git|walk|raw) on the offer row. Fixtures use a temp HOME and a temp git repo plus `git worktree add`, with GIT_DIR cleared:
- MUST FIRE: a worktree cwd resolves memory:<main key>.
- MUST FIRE: a subdirectory cwd resolves the repo's store.
- MUST NOT FIRE: a non-git dir resolves only its own key.
- CLEAN TWIN: the main-checkout result is unchanged, and a dotted path maps to the harness's dashed name.

CRITIQUE: The mapper's `--git-common-dir` choice is right. A lower-effort implementer reaches for `git rev-parse --show-toplevel`, which returns the WORKTREE root and reproduces the bug under a new name.

Other traps:
(a) Porting the sanitiser without the >200-character hash truncation. The Bun hash cannot be reproduced in Python, so for long paths fall back to matching an existing projects/* dir. Test it against every recorded transcript cwd, not five hand-picked dirs.
(b) A git subprocess on every prompt. Cache it, and bound it at 2 s. Fail open to today's behaviour.
(c) Keying rules on the canonical root. Rules must come from the worktree's own checkout (its branch may have edited them), and memory from the canonical root.
(d) Assuming the harness uses the git root for a SUBDIRECTORY launch. It has not been measured (the only C--Codex-ThriftyCrew-grocery transcript is from Aug 22), so add a probe before claiming parity.
(e) Hooks use os.getcwd(), and a session can change directory mid-run (see missed item on ffbacbef). Decide whether the key follows the launch cwd, as the harness does, or the current cwd. Payload cwd versus os.getcwd() should be logged as root_via.

Fixtures (temp HOME, temp repo, `git worktree add`, GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE cleared):
- MUST FIRE: a worktree cwd resolves memory:<main key>.
- MUST FIRE: a subdirectory cwd resolves the repo's store.
- MUST NOT FIRE: a non-git dir resolves only its own key.
- CLEAN TWIN: the main checkout is unchanged.
- A property test: key(cwd) equals dirname for every transcript on the machine.

### stores-split-by-session-cwd [gap/both/high] VERDICT=CONFIRMED
ThriftyCrew knowledge is split across two stores by where the session started, and Brad's newest rulings are invisible to ThriftyCrew-cwd sessions

CORRECTED: ThriftyCrew knowledge is split across two stores by launch cwd, with 0 shared memo names (208 and 186). The ruling memos Brad made on 2026-09-21/22 live only in C--Codex. None of their distinctive phrases appears in any tier a ThriftyCrew-cwd session loads (TC CLAUDE.md, rules or TC memory). They are reachable there only through 3 committed triage-plan files that cite them, and one of those misattributes a C--Codex memo to the ThriftyCrew store. The split was diagnosed on 2026-09-08 and only surface-patched.

FIX: Recommended long-term: one business, one store.

(1) Make the ThriftyCrew scheduled tasks (grocery-alert-triage, grocery-browser-stores-refresh, verify-board-sample, store-usage-weekly) start at C:\Codex\ThriftyCrew, so the memories they write land in C--Codex-ThriftyCrew. This is a persistent config change and needs Brad's yes. Check how the Desktop scheduler records cwd first; the task JSON does not show it.

(2) Do a one-off migration: skills/migrate-memory-store.py --plan (read-only) lists every C--Codex memo whose body names ThriftyCrew paths, or that a TC artefact cites. --apply copies each into C--Codex-ThriftyCrew under the same name (refusing on a name clash), leaves a C--Codex stub whose body is 'Moved to C--Codex-ThriftyCrew/<name>', moves the index line, commits both memory git repos, and runs audit-memory-backup on both stores. Include brad-rulings.md and its 9 children.

(3) Make C:\Codex\CLAUDE.md citations store-qualified ('memory C--Codex/push-data-sweeps-your-edit'), and extend ops/audit-memory-citations.ps1 to resolve a store-qualified name.

Only if (1) is refused: add a `parent` memory corpus in resolve_roots (C--Codex for a cwd under C:\Codex\<project>), used for name-routing only, behind a measurement with its bar written first (hit@3 on 20 keyed questions whose answer is a C--Codex memo).

Fixtures for the migration script:
- MUST FIRE: a TC-topic memo is planned.
- MUST NOT FIRE: a Book or brand-voice memo stays.
- CLEAN TWIN: the moved memo is reachable in the new store and its stub resolves.

CRITIQUE: The migration is much harder than the sketch implies.

(1) The two stores live in DIFFERENT git repos. C--Codex/memory is its own repo with remote Schweino/codex-memory and is ignored by ~/.claude. The TC store has no .git of its own; it is tracked by the ~/.claude repo, remote Schweino/claude-store, 187 files. So 'commit both memory git repos' means two unrelated repos with different privacy rulings (audit-memory-backup check 2 allows only a reviewed private remote).

(2) Moving memos breaks [ [links] ] in BOTH directions unless the whole link closure moves together. check-skills ratchets dangling links at marks C--Codex 16 and TC 3, so an unplanned move turns check-skills red. Consolidation pointers (42) must be re-resolved with recall-pointer-check afterwards.

(3) Stubs left behind must pass memory_lint's front-matter checks, or the NO_COST/BAD_TYPE marks move.

(4) Changing the scheduled tasks' cwd must flip, in the same change, the triage agent definitions that now hard-code C--Codex. C:\Users\Owner\.claude\agents\triage-reviewer.md:288-312 and the triage-developer copies explain why they say C--Codex. Also flip audit-memory-backup's default store.

(5) Scheduler cwd is persistent configuration and needs Brad's yes.

(6) The C--Codex store also holds non-TC material (Book, brand voice). The --plan classifier must be conservative, and its MUST NOT FIRE cases must include those.

Fixtures:
- A moved memo resolves in the new store.
- Every [ [link] ] into or out of the moved set still resolves (dangling counts unchanged).
- A non-TC memo is not planned.

### no-instruction-budget-gate [gap/general/high] VERDICT=CONFIRMED
Nothing budgets the always-loaded instruction bytes (CLAUDE.md x3, MEMORY.md, unconditional rules); only skill descriptions are gated

CORRECTED: About 155,320 B (~38.8k tokens at bytes/4) of instruction text load in every ThriftyCrew session: 37,784 B designed always-on plus 117,536 B of accidentally unconditional rules. The only budgeted always-on cost is skill descriptions, at 1,320 B, which is 118 times smaller. Nothing budgets CLAUDE.md, rules or MEMORY.md bytes. MEMORY.md truncation past 200 lines or 25,000 B is not silent: the harness emits an 'Only part of it was loaded' notice, and nothing gates on it before it happens.

FIX: Add to check-skills.py instruction_budget_failure(total, mark) and a report block, 'always-loaded instructions (every session in <project>)'.

For each root in an explicit list [C:\Codex\ThriftyCrew, C:\Codex\Fantasy, C:\Codex], sum:
- ~/.claude/CLAUDE.md;
- every CLAUDE.md from the drive root down to the project root;
- the MEMORY.md of the store the harness uses (git-common-dir parent key, as in the project-key fix), counted only up to 200 lines or 25,000 B because the harness truncates there;
- every .claude/rules/*.md under the root whose front matter has no paths: key, with its front matter stripped.
Print bytes and ~tokens (bytes/4, the level-1 convention).

Ratchet INSTRUCTION_MARKS = {'C--Codex-ThriftyCrew': 155320, 'C--Codex-Fantasy': 13125, 'C--Codex': 24933}. The marks may only go down: FAIL above the mark, and 'tighten the mark' when below (the MEMORY_LINT_MARKS shape). A plain run never writes the mark.

MEMORY.md: WARN at >= 180 lines or >= 22,500 B; FAIL at 200 lines or 25,000 B, with the CLI version the constants were read from.

Fixtures:
- MUST FIRE: a rules file with no paths: is counted.
- MUST NOT FIRE: a file with paths: is not counted.
- At the bar exactly: silent. One byte past: fires.
- CLEAN TWIN: a 201-line MEMORY.md is counted only to line 200 and flagged.

CRITIQUE: (1) Putting the budget only in check-skills. That is the skills store's L2 gate and does not run on a ThriftyCrew push, so a TC CLAUDE.md or rules edit that blows the budget ships anyway. The TC-side bytes (TC CLAUDE.md plus .claude/rules) need a run-gates ratchet in the TC repo, with check-skills reporting the machine-wide sum.

(2) Hard-coding the harness limits. Read them from the newest build or record the CLI version beside them. 2.1.280 renamed the constants (HM=200).

(3) Summing only the files named in the sketch. Also count CLAUDE.local.md, .claude/CLAUDE.md, @imports (expanded inline at launch), user-level ~/.claude/rules, and the store MEMORY.md resolved through the canonical root.

(4) A plain run must never rewrite a mark (the ratchet rule).

(5) Marks set at today's 155,320 would bless the accidental load. Set them after the rules-scope decision, or the first conversion reads as a fall.

Fixtures:
- A rules file without paths: is counted; with paths: it is not.
- At the mark exactly: silent. One byte past: fires. Use integer byte counts.
- A 201-line MEMORY.md is counted to line 200 and flagged.

### near-duplicate-lookup-dead [issue/general/medium] VERDICT=CONFIRMED
memory_lint.near_duplicates can never find a neighbour: it opens a corpus-relative path, swallows the error and returns []

CORRECTED: memory_lint.near_duplicates can never report a neighbour. It opens the corpus-relative hit path from the process cwd, the open fails, and a bare `continue` swallows it, so it returns [] even for an exact duplicate description (top hit score 34.07). In a worktree cwd it returns None. The write-time 'near-duplicate of [ [x] ]' reminder has therefore never been able to fire from real data, and no fixture drives the real lookup.

FIX: In memory_lint.near_duplicates, build a {corpus_tag: root} map from recall_index.resolve_roots(cwd), which returns (tag, root, kind). Open os.path.join(root_for[h['corpus'] ], h['path']). Return None, not [], if any hit's file cannot be opened, so could-not-look stays distinct. Better: make recall_index.search attach an absolute `abspath` key, so every caller stops re-deriving it.

Add a real-path fixture that builds a temp HOME with projects/P/memory/{a.md, b.md} and a real index (recall_index.ready(temp_cwd, home=temp)):
- MUST FIRE: a description identical to a.md's returns ('a', >= 0.8).
- MUST NOT FIRE: an unrelated description returns [].
- CLEAN TWIN: with a.md made unreadable the result is None, never [].

Telemetry: have recall-memory-lint-hook append {ev:'memlint', action, dup_count|None} to recall-log.jsonl, so how often the reminder fires is measurable. Today it logs nothing.

CRITIQUE: The sketch is right to use the hit's `corpus` tag, which already exists on each hit, mapped through resolve_roots.

(a) Joining the relative path onto a memory dir derived from project_key(cwd). That re-breaks in worktrees; the join must go through the resolved roots, after the project-key fix.

(b) The proposed 'return None if ANY hit's file cannot be opened' would make the whole check read could-not-look whenever the index is stale over one deleted or retired memo. That is a common state (the index refreshes lazily). Skip unreadable hits, count them, and return None only when no hit could be judged.

(c) Leaving the selftest on injected lookups. The new real-path fixture must build a real index in a temp HOME and must not call ri.ready() on the live DB, because ready() refreshes and writes it.

Cases:
- MUST FIRE: an identical description returns (a, >= 0.8).
- MUST NOT FIRE: an unrelated description returns [].
- CLEAN TWIN: an unreadable single hit returns None.
- A case at exactly 0.8 with binary-exact scores.

Log {ev:'memlint', dup_count} so fire rate is measurable.

### tc-store-audit-gap [gap/general/medium] VERDICT=CONFIRMED
The daily memory audit covers only C--Codex; the ThriftyCrew store's index integrity, encoding and reachability regressions are unwatched, and 13 TC memos are reachable only through rules citations

CORRECTED: The daily memory audit (index integrity, mojibake, reachability regression) runs only against C--Codex. The ThriftyCrew store's index integrity, encoding and reachability regressions are unwatched: check-skills covers only its dangling links and git currency. 9 of 186 TC memos are reachable only through a rules-file citation under a transitive closure (13 under a one-hop test), a root the audit does not model. The audit also cannot simply be pointed at the TC store: that store is versioned by the enclosing ~/.claude repo, so check 1 exits 2 and returns before the checks that matter.

FIX: In grocery/check-ad-cycles.ps1, run ops/audit-memory-backup.ps1 once per store from an explicit list (C--Codex, C--Codex-ThriftyCrew), never a wildcard, with separate alert subjects naming the store. In audit-memory-backup check 5, accept `[ [slug] ]` citations from <repo>\.claude\rules\*.md as reachability roots when -MemoryDir is the TC store, via a new -RulesDir parameter defaulting to '' so C--Codex behaviour is unchanged. Check 7 then compares reachability including those roots.

Fixtures:
- MUST FIRE: a memo reachable only through a temp rules file becomes unreachable when that citation is removed, and check 7 names it.
- MUST NOT FIRE: a rules-cited memo counts as reachable.
- CLEAN TWIN: a C--Codex run with no -RulesDir gives byte-identical output to today's.

Exit vocabulary unchanged (0 / 2 / 3); a missing store is BLIND 3, never a pass.

CRITIQUE: The sketch ('run it once per store') would go red on day one. Pointing audit-memory-backup at C--Codex-ThriftyCrew returns rc=2 at check 1 ('NOT a git repository') and never reaches checks 5 to 7, so the chain would page daily and teach people to ignore it.

The implementer must teach checks 1, 2, 4 and 7 to accept a store tracked by an ENCLOSING repo: resolve the toplevel, use `git ls-files -- <store>`, and run `status --porcelain -- <store>` pathspec-limited. Check 2's remote rule must be evaluated for the claude-store remote, which needs Brad's ruling on whether it is a reviewed private remote. The -Sync arm must NEVER run `git add -A` in the enclosing ~/.claude repo: it would sweep the whole store. Stage the store path only, or skip sync for enclosed stores.

The -RulesDir roots are right. Model them as roots in Get reachability, not as index links, or check 5's index-integrity semantics change.

Fixtures:
- MUST FIRE: removing the only rules citation of a memo names it in check 7.
- MUST NOT FIRE: an enclosed-repo store is not reported as unversioned.
- CLEAN TWIN: C--Codex output byte-identical with no -RulesDir.
- A must-fire that an enclosed store with an uncommitted memo is reported by a pathspec-limited status, and that nothing outside the store is staged.

### contradicting-copies-live [issue/both/medium] VERDICT=CONFIRMED
Several always-loaded or indexed copies of a harness or estate fact contradict each other today, with no re-check date on any of them

CORRECTED: At least five always-loaded or indexed records contradict measured harness or estate facts today:
- the workspace table's Fantasy 'no git' and '2,284 commits' (actual 3,249);
- the three-tiers memo, cited by 4 other memos and MEMORY.md;
- procedure.md:7;
- audit-memory-citations' header;
- the rules-load claims in the six rules headers and MEMORY.md:94.
No harness fact carries a machine-checked re-check date.

FIX: (1) Create C:\Users\Owner\.claude\skills\claude-code-automation\harness-facts.json, one row per harness fact: id, claim, measured_on, cli_version, probe (a command or a probe-agent prompt), recheck_by (<= measured_on + 21 days), retired_phrases (strings that must not appear in live text once the fact is corrected, e.g. 'does NOT reach subagents', 'Loaded only when you touch', 'the only inherited context', 'THE FIELD IS `globs`').

(2) Add skills/harness-facts-check.py --report, read-only. It lists overdue rows with their age. It greps live text (skills/**/*.md excluding archives via search.is_archive, all memory stores, the three CLAUDE.md files, and <repo>/.claude/rules and ops/*.ps1 headers) for each retired phrase, and FAILS on a match outside a `[CORRECTED ...]` or `[REVERSED ...]` block. Wire it into check-skills as a ratchet whose mark starts at today's count. Its first run will find the five items above; fix those in the same change.

(3) Workspace table: check-skills reads C:\Codex\CLAUDE.md's table and compares each Git yes/no with Test-Path <project>\.git. It forbids a literal commit count and asks for 'run git rev-list --count origin/main' instead.

Fixtures:
- MUST FIRE: a live memo containing a retired phrase.
- MUST NOT FIRE: the same phrase inside course/archive or inside a [CORRECTED] quote block.
- CLEAN TWIN: a fact whose recheck_by is in the future is silent.
- MUST FIRE: the table says 'no' while a .git dir exists.

CRITIQUE: (1) Building harness-facts.json as a second register beside course/CLAIMS-REGISTER.md, which already owns claim status and the [CORRECTED]/[REFUTED] markers and whose own header records it bloating twice. Two registers drift. Add a probe and a recheck_by column to the existing six-field row, or keep harness facts there with a type tag.

(2) The retired-phrase grep will match the correction blocks themselves. claude-code-craft 11.1 quotes 'THE FIELD IS `globs`' inside a [RESOLVED] block. Settle the marker grammar and rewrite those blocks BEFORE the first ratchet run, or the mark starts inflated.

(3) C:\Codex\CLAUDE.md is not versioned (C:\Codex is not a repo), so any automated edit there has no undo. Make the table check report only, and do the edit by hand.

(4) A check-skills rule forbidding a literal commit count couples the skills gate to one workspace file. Keep it narrow: the table's Git column against Test-Path .git.

Fixtures:
- MUST FIRE: a retired phrase in a live memo.
- MUST NOT FIRE: the same phrase inside course/archive or a [CORRECTED]/[REVERSED] block.
- MUST FIRE: the table says no while .git exists.
- CLEAN TWIN: a future recheck_by is silent.

### fantasy-no-record-tier [gap/code/medium] VERDICT=CONFIRMED
Fantasy is now a git repo with no hooks, an empty memory store, no rules and no Store: check, so the store-use record measures ThriftyCrew only

CORRECTED: Fantasy is a git repo with 5 Claude-coauthored commits since 2026-09-01, 0 of which carry the Store: line. The global, all-projects CLAUDE.md already asks for that line. Nothing enforces or records it outside ThriftyCrew: no hook, no log row, and an empty memory store. The Store: RULE already covers Fantasy; only the ENFORCEMENT (Brad's 2026-09-18 commit-msg check) was scoped to ThriftyCrew. So the new decision is whether to enforce, not whether the rule applies.

FIX: If Brad rules yes:
(1) Move the generic core of ThriftyCrew's ops/store_citation.py into ~/.claude/skills/store_citation_core.py, which is repo-agnostic and takes the repo root as an argument. Leave a thin shim at ops/store_citation.py so ThriftyCrew's hook is unchanged.
(2) Install C:\Codex\Fantasy\.git\hooks\commit-msg calling the core in WARN-only mode. It fails OPEN on any exception, because a hook that blocks an unrelated commit costs more than it catches. It logs rows with a new `repo` field to the same ~/.claude/store-citation-log.jsonl.
(3) store-usage-report splits every rate by repo, with both denominators.

Fixtures:
- MUST FIRE: a Claude-coauthored Fantasy commit touching a .py with no Store: line logs verdict warn and repo=Fantasy.
- MUST NOT FIRE: a data-only commit (backups/, *.md notes) is not judged.
- CLEAN TWIN: TC verdicts over the existing fixture messages are byte-identical after the refactor.
The hook install is persistent configuration and needs explicit approval.

CRITIQUE: The risky step is (1), moving ThriftyCrew's store_citation core into ~/.claude/skills behind a shim. TC's commit-msg hook, its fixtures and run-gates' sandboxes would then depend on a file outside the TC repo. Worktrees and sandboxes that copy only lib\ lose it, and the gate either breaks or fails open silently. That is the 'sandbox copies the whole lib' failure these rules already record. Keep TC's store_citation.py self-contained, and give Fantasy its own vendored copy or a thin hook that calls a copy in the Fantasy repo.

Other traps: Fantasy's hooks path is .git/hooks, which is not versioned, so a hook install there has no audit that it stays installed (TC has audit-hook-installed.ps1). WARN-only and fail-open are right.

Fixtures:
- A Fantasy .py commit with no Store: line logs repo=Fantasy verdict=warn.
- A data or notes-only commit is not judged.
- TC verdicts over the existing fixture messages stay byte-identical.
- The hook exits 0 when the logger throws.

### rules-narrative-volume [inefficiency/both/medium] VERDICT=OVERSTATED
The always-on rules are 95% incident narrative: the 88 rule leads total 5.6 KB of 117.5 KB, and ops-and-gates.md holds full accounts inline

CORRECTED: The bold rule leads are about 5% of the 117,536 always-on rules bytes (88 leads, 5,972 B with markup). The other 95% mixes the operative instructions (which helper, flag or command to use) with dated incident narrative and measurements. The share that is pure narrative was not measured. ops-and-gates.md alone is 74,252 B in 48 bullets, 42 of them dated, the largest 7,073 B, with only 8 distinct memory citations. That contradicts the 'pointers, not copies' convention the files state.

FIX: Pair this with branch B of the rules-scope finding.
(1) Generate the lead index with ops/build-rules-index.ps1 (AST-free: regex `^- \*\*(.+?)\*\*`). It writes each rules file's always-on lead file, one line per rule plus a `-> <depth file> / [ [memory] ]` pointer.
(2) Move each bullet's narrative (measurements, dates, incident prose) into its memory or its design/MEASURE-* doc. Leave in the rules file only the rule, the library or command to use, and the pointer.
(3) Add ops/audit-rules-lead-size.ps1 to run-gates as a ratchet on bytes per bullet in the always-on files. The mark starts at today's maximum and may only fall. It follows the standard shape: a plain run never writes the mark, and -Tighten records a fall.
Fixtures:
- MUST FIRE: a new always-on bullet over the mark.
- MUST NOT FIRE: a depth file (paths: scoped) is not counted.
- At the bar exactly: silent. One byte past: fires.
- CLEAN TWIN: the index generator is idempotent (a second run is byte-identical).

CRITIQUE: (1) Generating the lead index from the regex `^- \*\*(.+?)\*\*`. That captures only the bold sentence and drops the operative half, the named library or flag, which is exactly what goal 1 needs at code time. Each lead-file line must carry the rule AND the 'use X' target, authored or reviewed by a person, not scraped.

(2) Moving the depth into MEMORIES makes it LESS reachable. Nothing retrieves memory by similarity (see memory-bodies finding), and the 9 rules-only memos already hang by one citation. Move depth into paths-scoped depth files or design/MEASURE docs cited by path.

(3) A bytes-per-bullet ratchet is gamed by splitting a bullet in two. Ratchet the TOTAL always-on bytes per file (which the budget finding already proposes), and do not add a second gate.

(4) Every rule's incident prose is load-bearing evidence for someone. Move it with its dates and hashes intact; never summarise it away.

Fixtures:
- The generator is idempotent.
- Every lead-file line resolves to an existing depth anchor.
- The always-on total at the mark is silent and one byte past it fires.

### estate-library-index-missing [gap/code/medium] VERDICT=CONFIRMED
19 of 41 shared libraries are named in no always-loaded text, and no generated index says what each lib is for

CORRECTED: 19 of 41 lib/*.ps1 files are named nowhere in the always-loaded text (stem match; 22 of 41 are unnamed if you require the full filename). Among them is json-io, which 183 grocery files reference. No index says what each library is for or which bare cmdlet shape it replaces. Goal 1's 'reference the estate's own machinery' has no carrier for about half of lib/.

FIX: (1) Add ops/build-lib-index.ps1. It reads each lib/*.ps1 header's first line and its exported function names (PowerShell AST: FunctionDefinitionAst at top level) and writes lib/INDEX.md, one line per lib: '<file> - <what it is for> - functions: A, B - use instead of: <the bare cmdlet shape it replaces>'. The 'use instead of' column comes from a `# replaces:` comment in each lib header; a missing one prints '(none declared)'. Write it LF, skip identical bytes, and make it deterministic.
(2) Add one always-on line to TC CLAUDE.md: 'Before writing a helper, read lib/INDEX.md.'
(3) Add ops/audit-lib-index.ps1 to run-gates: every lib/*.ps1 has a row and every row names a file that exists. It is a hard check, since it is decidable from source and would be green on day one once the index is generated.
Fixtures:
- MUST FIRE: a temp lib with no row.
- MUST FIRE: a row naming a deleted file.
- MUST NOT FIRE: the generated index over a temp lib dir.
- CLEAN TWIN: the generator is idempotent.

CRITIQUE: (1) An index is REMIND tier, and 'Before writing a helper, read lib/INDEX.md' in CLAUDE.md is one more always-on sentence of the kind always-on-delivery-is-not-sufficient measured being broken. The stronger carrier is to turn each lib's declared `# replaces:` shape into a reflex row, since the reflex hook already fires on Edit|Write content. For example, `ConvertFrom-Json` fed by `Get-Content` in a grocery .ps1 that does not dot-source json-io reminds json-io. That is a regex over a known anti-pattern, not the similarity signal 2a refused. It still needs a written fire-precision bar and a rate cap in recall-reflexes.json.

(2) 41 headers carry no `# replaces:` today, so a scraped index says '(none declared)' 41 times and carries nothing. The column must be authored.

(3) Header parsing: the first line is often `<#`. Take the first non-empty line inside the comment block.

(4) The audit must never regenerate INDEX.md inside run-gates (a gate child must not write a tracked path). It only compares.

Fixtures:
- MUST FIRE: a lib with no row.
- MUST FIRE: a row naming a deleted file.
- The generator is idempotent, with LF bytes.
- For each reflex row: one MUST FIRE snippet and one MUST NOT FIRE snippet that already dot-sources the lib.

### orphan-income-store [issue/general/low] VERDICT=CONFIRMED
C--Codex-income is an orphan store that no session can load; it holds the only copy of a browser-pane harness fact and a divergent twin of a C--Codex hub

CORRECTED: C--Codex-income is an orphan store keyed to a directory that no longer exists, so no session loads it. It holds the only record of the browser-pane requestAnimationFrame fact, and a same-named, different-content copy of a C--Codex hub. check-skills still ratchets it as if live.

FIX: Migrate raf-dead-in-browser-pane into the TC store as a harness fact and add it to harness-facts.json with a recheck_by. Compare no-prs-auto-deploy and shared-tree-concurrent-publish against TC CLAUDE.md, and fold or retire them. Merge the unique income content of board-match-collisions into the C--Codex hub's routed children. Then leave a README.md in the income store saying 'retired <date>, moved to ...'.

Add to check-skills a LIVE_STORES map {key: project path} and report any store with memory files whose key is not in the map, or whose path does not exist, as ORPHAN STORE (WARN, not fail). Fixtures:
- MUST FIRE: a temp store keyed to a missing dir.
- MUST NOT FIRE: the live stores.
- CLEAN TWIN: worktree and scratch-workspace keys stay excluded exactly as memory_lint.all_stores excludes them today.

CRITIQUE: The rAF fact is harness knowledge, not project knowledge. Move it into the skills store (claude-code-automation), which recall can retrieve, rather than into another memory store that no hook searches by similarity. Merge the board-match-collisions content by hand: same name, different content means a diff, not a copy. The ORPHAN STORE check must stay WARN and must exclude worktree and scratch keys exactly as memory_lint.all_stores does, or 174 worktree dirs light it up.

Fixtures:
- A store keyed to a missing dir warns.
- The live stores are silent.
- Worktree keys are excluded.

### strength-harness-memory-canonical [strength/both/low] VERDICT=CONFIRMED
Strength: the harness loads the git-root's MEMORY.md in worktree sessions, and path-triggered loading of CLAUDE.md works across projects

CORRECTED: The harness loads the canonical git-root store's MEMORY.md in worktree sessions, and memory writes land there (0 memory files across 174 worktree dirs). Workflow subagents also receive the CLAUDE.md files, the TC MEMORY.md index and the rules at start. That is observed today for this agent, and it contradicts the three-tiers memo.

FIX: Do not rebuild. Make the recall stack match it (project-key finding). Record it in harness-facts.json as a fact with a probe: grep a fresh worktree transcript for the MEMORY.md path, recheck_by +21 days.

CRITIQUE: Keep it. Record it as a probed fact with a recheck date in the existing claims register, not a new file. The probe must read a FRESH worktree transcript's first instruction block and one Workflow-agent transcript, because delivery to agents is what the rules-scope change would put at risk.

### strength-write-time-and-ratchets [strength/general/low] VERDICT=CONFIRMED
Strength: write-time memory lint, the dangling/pointer ratchets, cross-store consolidation and the reflex block rung all demonstrably work

CORRECTED: What works:
- write-time front-matter lint (the structural half);
- the dangling-link and pointer ratchets;
- cross-project consolidation clustering (12 cross-project clusters, 0 unruled);
- the reflex block rung.

Qualifications:
- The near-duplicate half of write-time lint cannot fire (see near-duplicate-lookup-dead).
- check-skills as a whole is red today (exit 1): 5 within-project clusters are unruled, and the C--Codex NO_COST mark of 187 wants lowering to 186.

FIX: Keep them. Two small repairs belong elsewhere in this report: near_duplicates is dead (its own finding), and check-skills is red today (exit 1) on two ratchets asking to be moved. Someone should rule on the 5 unruled clusters and lower C--Codex NO_COST to 186, or the gate teaches people to ignore red.

CRITIQUE: Keep these. Someone must clear the two check-skills FAILs promptly (rule the 5 clusters, lower NO_COST to 186 through the ratchet's own path), or a permanently red L2 gate teaches everyone to ignore it. Do not edit the marks by hand around the ratchet.

## Missed by mapper
- [medium] audit-memory-backup cannot audit the ThriftyCrew store as written: check 1 exits 2 and returns before checks 5-7: ops/audit-memory-backup.ps1:261-266 returns rc=2 'the memory store is NOT a git repository' when $Dir has no .git, before index integrity (5), encoding (6) and reachability regression (7) run. The TC store has no .git of its own: `git -C ~/.claude/projects/C--Codex-ThriftyCrew/memory rev-parse --show-toplevel` = C:/Users/Owner/.claude, which tracks 187 files there (remote Schweino/claude-store). The mapper's tc-store-audit-gap fix ('run once per store') would therefore page daily from day one and never reach the checks it wants. The -Sync arm must also never run `git add -A` in the enclosing ~/.claude repo.
- [medium] The two memory stores are versioned by two different repos with different remotes, so any migration crosses repos and link closures: C--Codex/memory is its own repo (remote Schweino/codex-memory) and is ignored by ~/.claude (`git -C ~/.claude check-ignore -q projects/C--Codex/memory/brad-rulings.md` rc=0). The TC store is tracked by ~/.claude (Schweino/claude-store). check-skills ratchets dangling [ [links] ] per store at marks C--Codex 16 and TC 3, so moving memos without their whole link closure turns check-skills red. The stores-split fix sketch treats this as one commit per store.
- [low] BACKLOG E14 also records the false 'globs' verification as DONE, and its stated goal (shrink the always-on load) was never achieved: design/BACKLOG-course-findings.md:1440: 'VERIFIED 2026-09-06, AND THE COURSE NAMED THE WRONG FIELD. The key is `globs:`, not `paths:`', E14 marked DONE 6f3b6fd5. Its rationale says splitting the rules out 'would shrink the always-on load without losing anything'. Today the rules are 117,536 B and load unconditionally in 33 of 33 observed sessions. This is not in the mapper's list of false records to correct.
- [low] The store already names the InstructionsLoaded hook as the way to audit what reached context, and it was never installed: ~/.claude/skills/claude-code-automation/hooks.md:26 lists `InstructionsLoaded` for 'auditing what actually reached context'. There is no InstructionsLoaded entry in ~/.claude/settings.json (grep shows only SessionStart and the others). The measurement that would have caught the rules-scope error in September was known and not built. That is the 'an intention has no exit code' shape.
- [medium] The split already produces wrong provenance in committed artefacts, and it was diagnosed on 2026-09-08 and only surface-patched: grocery/triage-plans/registrar-2026-09-22.json:217 cites 'memo ruling-recipe-live-only-if-every-ingredient-priced (ThriftyCrew store; read in full)', but the memo exists only in C--Codex. grocery/triage-plans/plan-2026-09-08.json item 'discovered-2026-09-08-agentstore' diagnosed store-by-launch-cwd and fixed only the two triage agent definitions. Those definitions (e.g. ~/.claude/agents/triage-reviewer.md:288-312) now hard-code C--Codex, so a cwd move must flip them in the same change.
- [low] A session's recall corpus can disagree with its own MEMORY.md index after a mid-session directory change: Transcript C--Codex/ffbacbef-5542-4451-b222-57770fc8518e.jsonl loaded C--Codex MEMORY.md, yet 1,625 of its records carry cwd C:\Codex\ThriftyCrew, against 480 at C:\Codex. The recall hooks derive their corpus from os.getcwd(). If a hook process inherits the current cwd, name-routing in that session resolves against the TC store while its index and memory writes are C--Codex. PLAUSIBLE, not measured: I did not observe a hook's cwd in that session.
- [low] The global Store: rule already covers every project; only its enforcement is ThriftyCrew-scoped: ~/.claude/CLAUDE.md 'Operating rules - all projects' says 'record what you used: a Store: line on the commit'. In C:\Codex\Fantasy, 5 of 5 commits since 2026-09-01 are Claude-coauthored and 0 of 5 carry a Store: line. The mapper framed extending Store: to Fantasy as a new decision for Brad. The rule already applies and is being broken; the decision is only whether to enforce it.
- [low] Memory name-routing is live, and it is the only memory recall there is: recall-hook.py:216 routes memory pointers through recall_tiers.named_files. recall-log.jsonl holds 4 of 8,813 offers all time on memory/ paths and 0 of 981 in the last 7 days, and the route returns [] in a worktree cwd. The mapper's 'no hook ever retrieves a memory body' missed it. Any memory-leg change must keep this route working and measure the two separately.
- [low] The harness project-key sanitiser truncates at 200 characters with a Bun hash suffix, which a Python port cannot reproduce: 2.1.280: `function RC(e){let n=k(e);if(n.length<=fQ)return n;return`${n.slice(0,fQ)}-${Le(e)}`}` with fQ=200 and k = replace(/[^a-zA-Z0-9]/g,'-'). The project-key fix must fall back to matching an existing projects/* directory for long paths, not compute the hash.
- [low] Hook side effects of this verification: My tool calls ran under parent session 134f2f6e-7fb9-4057-a890-b2c27ba9dfc0. The intent hook injected recall offers on several Bash descriptions, and the reflex hook blocked 1 command (pipe-then-exit-code); these append rows to ~/.claude logs. I drove no hook with a synthetic payload. near_duplicates was driven only against a sqlite backup copy of recall-index.sqlite3 in the review scratch dir, so the live index was not refreshed. check-skills.py and recall-pointer-check.py ran in their read-only default modes; memory_lint and recall-memory-lint-hook ran --selftest only.

## Open questions
- Rules scoping has a real tradeoff for Goal 1. Today's accidental always-on load gives every Workflow agent and every Bash-only session the rules. Converting to paths: would deliver them only after a Read/Edit/Write of a matching file, and the CLI code handles agents' pending nested-memory triggers differently (`if(t&&r&&!e.agentId)`). Which offer-N branch (A: paths:, B: always-on lead index plus path-scoped depth) does Brad want judged? And should a probe first confirm whether a subagent's own Read triggers path_glob_match?
- Subagent transcripts are ambiguous about whether they record their initial instruction context. Of 258 TC subagent transcripts since 09-15, 26 show all six rules files in their first 5 records, 74 some, and 158 none. It is unknown whether they serialise the claudeMd user context. Delivery to subagents has been measured only by the 2026-09-07 quote probe.
- Is 'one business, one store' the ruling? That means moving the ThriftyCrew scheduled tasks' working directory to C:\Codex\ThriftyCrew and migrating the ThriftyCrew-topic C--Codex memos, including brad-rulings.md and its 9 children. The Desktop scheduler's task list does not expose the cwd, so how it is set needs checking before any change.
- Should the Store: record tier (a commit-msg hook in warn mode) extend to Fantasy now that it is a git repo? Brad's 2026-09-18 ruling named ThriftyCrew only.
- The memory semantic leg's held-out floor derivation has been pending since 2026-09-12 (PLAN-brain-efficiency, NOT SHIPPED). Is it still wanted? If so, who owns building the 40-question keyed set with negatives?
- Not measured: tokens actually billed per session for the 155 KB (prompt caching makes the dollar cost much lower than the context-window cost), and whether compaction re-attaches the rules (load_reason 'compact' exists, but I did not observe a post-compaction transcript).
- Hooks fired on my own tool calls during this review. The intent hook offered pointers on several Bash descriptions, and the reflex hook blocked 2 commands; these were logged under parent session 134f2f6e-7fb9-4057-a890-b2c27ba9dfc0. knowledge-search/search.py ran 2 times, appending log rows. I drove no hook with a synthetic payload. check-skills.py and recall-pointer-check.py (default mode, no --accept) were run as read-only reports.
