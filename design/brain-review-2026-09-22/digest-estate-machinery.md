# estate-machinery

Four channels carry estate machinery to a coding session today. None of them was built for that job.

(1) Prose. The six .claude/rules files total 118,538 B (~29.6K tokens). Their front matter uses Cursor's `globs:`/`alwaysApply:`, but Claude Code 2.1.173 and 2.1.263 read only `frontmatter.paths`. So all six load unconditionally in every ThriftyCrew session and worktree (6 of 6 were in this agent's context at spawn). The helper rules sit inside ops-and-gates.md: 74 KB, 48 bullets, median 1,052 chars.

(2) Lib headers. 102 of 102 lib files open with a `<name> - purpose` line, and 525 of 737 top-level functions carry a doc comment. Nothing collects them. There is no catalogue anywhere: RUNTIME-MAP names 0 lib files, and 128 of 738 functions are named in any rules/CLAUDE.md/skills/memory/docs file.

(3) Retrieval. search.py sees only the skills store: task-phrased hit@8 was 4 of 12 for the 12 helpers the rules name. The hook's BM25 index adds memory and rules (6 of 12). But it stores ops-and-gates.md's body as one 10,978-token chunk, and from a worktree cwd it drops the 187 project memories.

(4) Recognition. There are 30 reflex rows; none names a helper, and the Write-content window is 2,000 chars. About 60 push-time static detectors exist, and 4 of the 12 helpers have a push gate. Those gates went red 11 times in 5,011 runs (2026-09-10..22), so the gate tier works where it exists. But count-only ratchets with slack, plus a pass on a zero-file scan, let ops/audit-readjson-inline-wrap.ps1 (2026-09-21) reproduce tree-walk's founding bug and run blind in every worktree. Its commit carried a compliant Store: line.

A prototype index generated only from existing headers reached 10 of 12 helpers at hit@3 by task phrase (bar 9, written before the run). The review appended 48 search.py log rows and caused 4 reflex reminders, 1 reflex block and 4 intent offers under the parent session id. I also overwrote a sibling reviewer's review\coverage.py; see finding shared-scratch-clobber.

## Measurements
- lib files and top-level functions: 102 files (lib 41, grocery 52, meal-prep 9); 738 top-level functions; 711 distinct names; 658 distinct Verb-Noun  [tree at HEAD 4ba348d48, 2026-09-22]
- lib headers that give a purpose / a machine-readable use-when field: purpose line 102 of 102; 'WHY THIS EXISTS' 34 of 102; 'THE RULE' 40 of 102; USE FOR/REPLACES/USE WHEN field 0 of 102  [2026-09-22]
- lib functions with their own doc comment: 525 of 737 top-level functions (377 inside body, 148 directly above); Verb-Noun 503 of 659  [2026-09-22]
- Python helper modules: 50 of 146 first-party .py imported by another first-party file; 569 public defs; 50 of 50 with a module docstring  [2026-09-22]
- lib machinery named anywhere a session could be told: functions 128 of 738 (rules 59, skills 63, memory 95, docs 36, CLAUDE.md 8); lib files 70 of 102; RUNTIME-MAP.md names 0 lib files; applies-here bridges name 28 of 658 Verb-Noun functions  [2026-09-22]
- task-phrased query reaches the helper (function name in a returned section), 12 helpers: search.py (skills only) hit@8 task 4 of 12, construct 5 of 12; hook BM25 index (skills+memory+rules, opened read-only) hit@8 task 6 of 12, construct 7 of 12; same 6 helpers miss both engines on the task arm (Get-TcTreeFiles, Invoke-Native, Clear-TcGitRepoEnv, New-TcWorktreeFixture, Test-RatchetMove, Enter-TcGateSlots)  [2026-09-22; semantic leg not measured]
- prototype machinery index generated from existing headers only: task arm hit@3 10 of 12 (bar written first: >= 9 of 12), hit@8 11 of 12; uncontaminated subset hit@3 5 of 7; construct arm hit@3 11 of 12. Misses: Get-TcGlobalExclude (absent), Format-TcLivePriceSpan (rank 8). One variant tried, 12 cases, machinery-only corpus  [2026-09-22]
- rules loader field in the shipped CLI: loader reads frontmatter.paths: 1 site in each of 2.1.173 and 2.1.263; loader reading globs: 0 of 2 binaries; the only 'alwaysApply' string in 2.1.263 (1 hit) is Bun's embedded .cursor/rules/use-bun-instead-of-node-vite-npm-pnpm.mdc template  [binaries dated 2026-06-11 and 2026-09-08]
- rules files present in this workflow agent's context at spawn, before any file was touched: 6 of 6 (graph, grocery, meal-prep, measurement, ops-and-gates, site-and-publish)  [2026-09-22]
- rules size and shape: 118,538 B total (~29.6K tokens), 76% of the 156,322 B always-on instruction set; ops-and-gates.md 74,418 B, 48 top-level bullets, 184 bold rule heads, median bullet 1,052 chars, max 7,007, 4 of 48 bullets <= 300 chars; all rules 66 of 99 bullets over 400 chars; 5 of 6 files say 'Loaded only when'  [2026-09-22]
- ops-and-gates.md growth: 1,966 B (a8b17d05a, 2026-09-06) to 74,418 B (968abcec8, 2026-09-19); 63 commits, 40 of them on 2026-09-11  [2026-09-06..2026-09-19]
- hook index chunking of the rules corpus: ops-and-gates.md body = 1 chunk of 10,978 tokens against a corpus average of 260; BM25 tf=1 weight factor 0.051 of an average chunk; 13 chunks for all 6 rules files  [index state 2026-09-22]
- ops-and-gates bullets about constructs any script types: 22 of 48 bullets (48,247 of 72,806 bytes); 23 of 48 name a lib helper; 15 of 48 both  [2026-09-22]
- callers of each helper outside ops/ and lib/ (the intended scope of ops-and-gates.md): Invoke-Native 15 of 16; Write-TcAtomicFile 20 of 27; Enter-TcLedgerLock 3 of 3; Write-TcLfFile 9 of 22; Test-RatchetMove 4 of 16; Clear-TcGitRepoEnv 6 of 29; Get-TcTreeFiles 3 of 22; Enter-TcGateSlots 0 of 9 (652 .ps1 scanned)  [2026-09-22]
- reflex rows that name an estate helper or lib file: 0 of 30  [2026-09-22]
- reflex text window vs new script sizes: Edit/Write text = file_path + first 2,000 chars (recall_core.py:549-550); the readjson defect starts at char 4,693; 40 of 41 .ps1 files added since 2026-09-12 exceed 2,000 chars  [2026-09-12..2026-09-22]
- helper-enforcing static gates going red: 11 red of 5,011 watched runs (15 gates, 77 gate-readings logs, 26,536 distinct rows); main checkout alone 6 of 2,263  [2026-09-10..2026-09-22]
- audit-readjson-inline-wrap scan count by checkout: worktree rows: scanned=0 rc=0 on 11 of 11; main rows: scanned 681..691  [2026-09-21..2026-09-22]
- audit-full-path-excludes live plain run: exit 0; 3 sites against a mark of 4 (can-tighten); site 1 is ops\audit-readjson-inline-wrap.ps1:68; tracked baseline hash unchanged by the run  [2026-09-22]
- count ratchets with slack / baseline shape: latest main markers: 1 of 14 baselined gates can-tighten (audit-write-seam 15 vs 17), plus full-path-excludes live 3 vs 4; of 10 sampled baselines at least 7 store only a count, 1 stores named sites (native-stderr-eap)  [2026-09-22]
- prose-only helpers reinvented after the helper existed: Enter-TcLedgerLock: 11 files carry a named Mutex outside lib, 1 introduced later and it is a legitimate self-test probe (push-main.ps1:503), so 0 real; Add-TcLine 0 of 2; Get-TcTreeFiles-style walks 1 of 3 (audit-readjson-inline-wrap, 2026-09-21)  [helper births 2026-09-11..12 to 2026-09-22]
- deliberate store searches that ask about estate machinery: 1 of 82 search.py queries (14 sessions)  [2026-09-09..2026-09-21 (today excluded to drop review probes)]
- hook recall roots from a worktree cwd: resolve_roots returns skills + rules only (memory dropped); 174 of 174 worktree project dirs spelled '--claude-worktrees', project_key yields '-.claude-worktrees'; 1 of 174 has a memory dir, holding 0 .md; 97 worktrees on disk  [2026-09-22]
- analysis harnesses and prior measurements: 32 committed harness-named scripts (probe/count/report/observe...), 25 of 32 with a purpose line, 7 of 32 named in measurement.md or ops-and-gates.md; 27 MEASURE/EVAL/TRIAL docs in design/, 6 of 27 named in the skills store  [2026-09-22]
- generator cost: PowerShell AST census of 102 lib files 1.1 s wall; Python ast census of 146 files 1.0 s  [2026-09-22]
- set-content-no-encoding reflex precision on this review's own Writes: 4 fires, 4 false positives (3 .py files, 1 regex literal in a .ps1)  [2026-09-22]
- InstructionsLoaded hook wiring: 0 of 9 hook groups in ~/.claude/settings.json; no project settings.json  [2026-09-22]

## Findings

### rules-frontmatter-inert [issue/both/high] VERDICT=CONFIRMED
The rules scope field is inert: `globs:` is Cursor syntax, so all six rules files load in every session, and the store, a gate and the files themselves all claim otherwise

CORRECTED: In all 3 installed CLI binaries (2.1.173, 2.1.236, 2.1.263) the rules loader reads only frontmatter `paths`. A file whose front matter carries only `globs:` has no scope, so it loads unconditionally. All 6 ThriftyCrew rules files (118,538 B, 75.8% of the always-on instruction bytes) therefore load in every session, which this verifier observed directly. The belief that they are path-scoped is written in at least 9 places: 11.1 of claude-md-and-commands.md; archived claim C3; 5 of 6 rules-file sentences; audit-rule-currency.ps1; the MEMORY.md index ('.claude/rules/*.md load when you touch that directory'); recall_core.py:546-547 ('The path is what selects the right .claude/rules/ file'); recall-agent-hook.py:13,127,303-304; memory what-actually-reaches-a-spawned-agent; design/PLAN-backlog-2026-09-06.md and BACKLOG. The loader code is a genuinely new signal that overturns C3, so this is not already ruled.

FIX: Order matters, and each step is its own commit.

(1) Telemetry first. Add ~/.claude/skills/recall-instructions-log-hook.py on hook event InstructionsLoaded (no matcher). It reads stdin JSON {file_path, memory_type, load_reason, globs, trigger_file_path, session_id, agent_id} and appends one LF line to ~/.claude/recall-instructions-log.jsonl. It fails OPEN (any exception: exit 0, no output). A --selftest drives a synthetic payload into a temp log: MUST FIRE a row is written with load_reason; MUST NOT FIRE a malformed payload writes nothing and exits 0.

(2) Two-file test in a scratch git repo, which is what 11.1 itself prescribes. Rule A with `paths: ["sub/**"]`, rule B with no front matter. Record which loads at session start, on Read of sub/x, and on Write of a NEW sub/y with no prior Read, and whether a comma string works as well as a YAML list. Write the result into claude-code-craft 11.1 as a `[CORRECTED 2026-09-xx]` block quoting the loader string and naming the Bun-template misread.

(3) Ask Brad: scoped or always-on (see open_questions).

(4) If scoped: split ops-and-gates.md. The 22 of 48 bullets naming a construct any script types go to .claude/rules/powershell.md with `paths: ["**/*.ps1", "**/*.psm1"]`; gate-authoring bullets stay with `paths: ["ops/**", "lib/**"]`; convert the other five files' globs to paths lists.

(5) ops/audit-rule-currency.ps1: parse `paths:` as a YAML list or string; exit 2 on any front matter carrying `globs:` or `alwaysApply:`; change line 186 to 'NO PATHS - loads in every session'. Fixtures: MUST FIRE a globs-only file gives exit 2; MUST NOT FIRE a paths list whose entries match tracked files; CLEAN TWIN the dated-claims listing is unchanged.

(6) Fix each file's 'Loaded only when' sentence to match what the log shows. No waiver needed. The log is the telemetry that says whether a rule reached the session that needed it.

CRITIQUE: Most likely lower-effort errors:
(a) Flipping every `globs:` to `paths:` verbatim. That strips ops-and-gates.md from the grocery/meal-prep writers who hold 20 of 27 Write-TcAtomicFile, 15 of 16 Invoke-Native and 3 of 3 Enter-TcLedgerLock call sites.
(b) Scoping measurement.md to its current code globs (sidecar/**, *eval*.py, *probe*.py, audit-*.ps1). The measurement rules would then vanish from ANALYSIS sessions that write design/MEASURE-*.md or run scratch scripts outside the repo, which is a direct regression of goal 2. It must stay unconditional, or add design/(MEASURE|EVAL|PLAN|TRIAL)-*.
(c) Forgetting recall-agent-hook.py. Its MUST NOT FIRE 'no memory or rules hit may be sent' rests on 'a subagent already has the rules files', which is true today only because the scope is inert. Once rules are scoped, a subagent that never touched a matching file lacks them, so the agent hook's exclusion must change in the same commit.
(d) Re-proving the loader by grepping the binary, which is how 11.1 went wrong. The two-file test must drive a real session (claude -p in a scratch repo, with the InstructionsLoaded logger from step 1) and read rows. Cases: start, Read of a match, Write of a NEW file with no prior Read, a comma string versus a YAML list (the binary strips a trailing '/**' and treats a bare '**' as unconditional), and a subagent/Workflow agent.
(e) The InstructionsLoaded log fires per file, per session start, per subagent and per compact. Append each row in one write, and give it a size cap.
(f) Fixing 11.1 only. All 9 carriers above need the correction in one sweep, plus claim C3 re-opened as overturned.
The fixture must prove: a `globs:`-only file loads at session_start (MUST FIRE for the inert field); a `paths:` file loads with load_reason path_glob_match on a matching touch and NOT at start; audit-rule-currency exits 2 on a globs-only file.

### no-estate-machinery-index [gap/both/high] VERDICT=OVERSTATED
There is no catalogue of estate machinery; a generated one reaches 10 of 12 helpers by task phrase where the store reaches 4

CORRECTED: No index of estate machinery exists (confirmed, and section 7 records it as open). A prototype generated from lib headers put the owning lib's section in the top 3 for 10 of 12 task-phrased queries, and in the top 8 for 11 of 12. The store reaches the owning lib FILE at hit@8 for 8 of 12 (search.py) and 9 of 12 (hook BM25 index); hit@3 for the store was not measured. The headline '10 of 12 where the store reaches 4' compares proto file-level hit@3 with store function-name hit@8. Further limits on the comparison:
- The prototype was searched alone over 102 sections, never mixed with the 2,162 skills chunks.
- The queries were written by someone who knew the answers, and several carry estate words ('excluding worktrees', 'json ledger', 'tracked ... LF').
- One variant, 12 cases.
The honest number is 5 of 7 uncontaminated at hit@3.

FIX: Generated, tracked, and gated for staleness.

Generator: NEW ops/build-machinery-index.ps1, PS 5.1. It dot-sources lib/tree-walk.ps1 (walk via Get-TcTreeFiles -PruneBelow), lib/lf-write.ps1, lib/selftest-lib.ps1 (Get-SelfTestBlock, to drop self-test functions) and lib/guard-contract.ps1 (Exit-Guard). Plus NEW ops/machinery_index_py.py (ast), which prints JSON to stdout; the generator calls it with stdout redirected to a per-run temp file, never 2>&1.

Population:
- kind=lib: lib/*.ps1, grocery/*-lib.ps1, meal-prep/lib/*.ps1.
- kind=py: .py modules imported by at least one other.
- kind=harness: ops|grocery|meal-prep/pipeline (probe|count|report|observe|measure|census)-*.ps1|py, 32 today.
- kind=gate: every run-gates $static entry; its `n=` text is the purpose, and `daily` gives the mode.
- kind=measurement: design/(MEASURE|EVAL|TRIAL)-*.md, 27 today (title, date, harness named, first Result or Verdict line).

Per entry: file, line, name, params, purpose (line 1, 102 of 102 present), first doc line (525 of 737 present), callers by top directory, rule_refs (rules file:line naming it). Exclude functions with names of 1-5 chars and functions inside self-test spans.

New OPTIONAL header lines, hand-authored, seeded for the 12 helpers here plus native-lib, json-io, parallel-run, push-lock and global-exclude-lib:
- `# USE WHEN: <plain task words>`
- `# REPLACES: <regex> ;; <regex>`
- `# ENFORCED BY: ops\audit-x.ps1`

Outputs, deterministic (sorted by path, no timestamps, written by Write-TcLfFile -NoBom):
- docs/MACHINERY.md: one `## <relpath> :: <purpose>` section per file, capped at ~1,500 tokens so BM25 does not bury it. Body: USE WHEN, REPLACES in words, enforced-by (gate, push|daily|build|none, count|named|zero), the first 1,200 header chars, then '- `Name` (params): doc'.
- docs/machinery-index.json: {schema:1, entries:[{kind, name, file, line, params, purpose, use_when, replaces:[{id, pattern, ext}], enforced_by, callers, rule_refs}]}.

Staleness: add to run-gates $static `@{ f='ops\build-machinery-index.ps1'; a=@('-Check'); n='the machinery index is what the generator makes from this tree' }`. -Check regenerates into a per-run temp dir and byte-compares. Exit 2 STALE names the first differing entry; exit 3 BLIND on any parse error or zero files resolved. Cost is about 2 s (measured 1.1 s + 1.0 s).

Search:
- Today, with no code change: `search.py --root C:\Codex\ThriftyCrew\docs "<task>"`.
- Add `--estate` to search.py: resolve the main checkout from cwd via `git rev-parse --git-common-dir` and search <repo>/docs/MACHINERY.md. Rewrite knowledge-search/SKILL.md step 3 to 'search.py --estate first, grep second'.
- Add one line to ThriftyCrew CLAUDE.md: before writing a file-write, walk, lock, native call or helper-shaped function, run search.py --estate.

Probe set: NEW ops/machinery-probes.jsonl rows {query, expect, source, contaminated}, seeded from <R>\helper-recall.jsonl. `-Probe` mode prints hit@3 with its denominator; it is a report, never a gate. A session appends each miss it hits (measurement.md E23).

Fixtures (-SelfTest, per-run temp tree):
- MUST FIRE: add Get-B to a temp lib after generating; -Check gives exit 2 naming Get-B.
- MUST FIRE: a lib with a parse error gives exit 3 naming it.
- MUST NOT FIRE: an unchanged tree gives exit 0, byte-identical.
- CLEAN TWIN: a function inside `if ($SelfTest)` is excluded while the real function beside it is indexed.
- Worktree: a root from New-TcWorktreeFixture still resolves every lib.

Bar, written now: uncontaminated probes hit@3 >= 6 of 7 once the USE WHEN seeds exist (5 of 7 without them).

CRITIQUE: The main risk is the tracked docs/MACHINERY.md plus a byte-compare -Check on every push. The entries carry `line`, `callers` and `rule_refs` (rules file:line), so any commit that touches a lib, a caller or a rules line makes the artifact stale. The result is either a red on most pushes (the red that teaches --no-verify) or a file every concurrent session regenerates and conflicts on during the rebase inside push-main. Either keep volatile fields out of the tracked artifact (track file, name, params, purpose, USE WHEN, REPLACES, ENFORCED BY only), or make it a gitignored per-checkout cache rebuilt on demand (measured ~2 s) and never gate it.
Other points:
- `--estate` resolving via git-common-dir reads the MAIN checkout's copy from a worktree, which contradicts 'a worktree reads its own commit's copy'. Pick one.
- Caller resolution: reuse grocery/audit-script-census.ps1's executable-reference walk and its .git-entry nested-checkout boundary, walking with Get-TcTreeFiles -PruneBelow. Do not write a third resolver.
- Do not call audit-conclusion-currency from the push-time check. It has -Json, but its status moves when harnesses move, which adds churn.
The fixture must prove:
- a New-TcWorktreeFixture root resolves all libs;
- zero resolved files exits 3;
- the tracked output is byte-identical across two runs on an unchanged tree AND unchanged after an edit that only moves a caller's line.
The bar belongs on a probe set written by someone who has not read the headers.

### no-edit-time-construct-recognition [gap/code/high] VERDICT=CONFIRMED
No edit-time channel maps the construct being typed to the estate helper that replaces it, and the reflex tier sees only the first 2,000 chars of a Write

CORRECTED: Confirmed as stated. No edit-time channel maps a construct to the estate helper that replaces it: 0 of 30 reflex rows name one. The reflex tier reads only the first 2,000 chars of an Edit/Write body, and 40 of 40 surviving .ps1 files added since 2026-09-12 are longer than that. The set-content row's advice (-Encoding utf8) is the tracked-file shape lf-write.ps1 exists to replace. PreToolUse is the one channel observed reaching Workflow agents. This is recognition, not the similarity retrieval refused in 2a, so it is not already ruled.

FIX: NEW ~/.claude/skills/recall-machinery-hook.py, registered in ~/.claude/settings.json in the existing PreToolUse `Write|Edit` group beside recall-memory-lint-hook.py.

Inputs: tool_input.file_path; tool_input.content (Write) or new_string (Edit) in FULL, with no 2,000 cap; cwd.

Resolution: walk up from file_path to the first directory holding docs/machinery-index.json, so a worktree reads its own commit's copy. None found: exit 0 silently.

Skips: the file IS the entry's own lib; the extension is not in entry.ext; the text already names the helper.

Matching: compile the REPLACES patterns once with re.M. The generator refuses a pattern slower than 50 ms on a 60 KB fixture (ReDoS bound).

Output: hookSpecificOutput.additionalContext of at most 450 B, for example: '<machinery> the estate already has this: Write-TcAtomicFile (lib\atomic-write.ps1) - replace a whole file without losing the write to a reader. Push gate: ops\audit-bare-replace.ps1. Section: docs/MACHINERY.md. Not an instruction.'

Behaviour: remind only, never deny. Dedup per (session_id, agent_id, helper) in a state file like the other hooks. Fails OPEN (any exception: exit 0 and one error row). No waiver needed, since it never blocks.

Telemetry: ~/.claude/recall-machinery-log.jsonl {t, sid, agent, file_rel, helper, pattern_id, ev}. A PostToolUse Write|Edit join (extend recall-reflex-outcome-hook.py) writes ev=adopted when a later edit in the same session and file names the helper, and ev=persisted when the construct is written again. This is the first measure of 'does a pointer change what the model DOES' (automatic-recall.md 7).

Seed REPLACES from each push gate's own MUST FIRE so edit time and push time agree:
- bare Move-Item -Force (audit-bare-replace)
- native 2>&1 under EAP Stop (test-native-stderr-eap)
- git init with no Clear-TcGitRepoEnv (audit-git-fixture-env)
- `$_.FullName -notmatch ...worktrees` (audit-full-path-excludes)
- Get-ChildItem -Recurse over a repo root with no -PruneBelow
- Add-Content onto .jsonl/.log (append-line)
- `New-Object System.Threading.Mutex` outside lib\ (ledger-lock)
- `ConvertTo-Json | Set-Content` onto a tracked path (lf-write)
- `@(Read-JsonFile` (audit-readjson-inline-wrap)

Also amend two rows in recall-reflexes.json:
- set-content-no-encoding gets 'In ThriftyCrew a TRACKED file goes through Write-TcLfFile (lib\lf-write.ps1), a file others read through Write-TcAtomicFile, a shared log through Add-TcLine'.
- native-exe-stderr-redirect gets 'Invoke-Native (grocery\native-lib.ps1) is the estate's form'.

Fixtures (--selftest):
- MUST FIRE: a Write to <tmprepo>\grocery\x.ps1 with Move-Item -Force at char 4,700 names Write-TcAtomicFile.
- MUST FIRE: the frozen text of ops/audit-readjson-inline-wrap.ps1 at blob cda0f7a3f838 names Get-TcTreeFiles.
- MUST NOT FIRE: the same Write to lib\atomic-write.ps1 itself; a .py that quotes 'Move-Item' in a string; a repo with no index.
- CLEAN TWIN: an Edit that already calls Write-TcAtomicFile stays silent, and a second offer of one helper in one session is suppressed.

Bars, written before shipping: fire rate <= 5% of Edit/Write calls on .ps1 under C:\Codex\ThriftyCrew, replayed over the 838 changes of 2026-09-11 (the 2a corpus); and >= 20 of 30 hand-labelled offers are real candidates.

CRITIQUE: The biggest risk is building a SECOND pattern engine (new hook, own dedup, own log, own fire-rate). That duplicates recall_reflex's must_fire/must_not_fire check_fixtures, max_fire_rate, tools/scope/code_only, stats and fire->outcome join; it is the 'implemented twice' shape. Prefer generated reflex rows, or a sibling table loaded by recall_reflex, with a `full_body` flag: match the whole body while the JOIN KEY stays on the truncated text. That also saves a Python spawn per Edit/Write (median 376 a day).
Most likely lower-effort error: raising the 2,000 cap in recall_core. That silently breaks the outcome join for every Edit/Write row. The CLEAN TWIN must assert command_hash is unchanged for existing rows.
Other points:
- The fire-rate bar cannot be measured with today's harness. recall-tool-probes.py:101 caps each edit body at 1,200 chars, and the '838 changes of 2026-09-11' corpus is prose only: I found no committed file (searched skills for '838' and candidate-3 names). Build and commit a full-body corpus first.
- REPLACES patterns lifted from PowerShell gates are .NET regex, and the hook is Python `re` (lookbehind and inline-flag rules differ). The ReDoS bound must be timed in Python, not in the PS generator.
- 'Skip when the text already names the helper' fails for Edit, whose new_string is a hunk.
- Dedup per (session_id, agent_id): Workflow agents carry the parent's session_id, and whether they carry a distinct agent_id is unverified. If they do not, every agent after the first is suppressed. Check a real payload first.
- ev=adopted has no control arm. Hold out a deterministic hash-of-session slice, or report adoption only as a rate.
- The amended set-content message conflicts: atomic-write.ps1 'keeps Set-Content's CRLF bytes on purpose', so a tracked ledger read by others gets two contradictory instructions. The message needs the tie-break.

### readjson-gate-reproduced-founding-bug [issue/code/high] VERDICT=CONFIRMED
A gate added 2026-09-21 reproduced tree-walk's founding bug in 12 lines and runs blind in every worktree, with all rules loaded and a compliant Store: line

CORRECTED: Confirmed. The count is now 12 of 12 worktree runs (3 worktrees), not 11 of 11: one row landed since the mapper counted. Every one scanned 0 files and exited 0. The walk also FILTERS rather than prunes, so on the main checkout it enumerates every worktree before dropping them. The daily ratchet that should flag the new full-path site ran last on 2026-09-12 in any gate log, and its scheduled task has read success on failing nights.

FIX: Instance fix (plan it; this review does not implement):
- Replace lines 67-68 with `Get-TcTreeFiles -RootFull $repo -Filter '*.ps1' -PruneBelow '\\(\.claude\\worktrees|archive|node_modules|\.git)\\'` plus a `(Get-TcPathBelowRoot ...) -notmatch` filter.
- Exit 3 with 'READJSON-INLINE-WRAP-COMPLETE scanned=0 blind=1' when $files.Count -eq 0.
- Add a New-TcWorktreeFixture MUST FIRE case: a planted `@(Read-JsonFile $x)` under a worktree-shaped root is found. MUST NOT FIRE: a sibling worktree's copy is not counted. CLEAN TWIN: the main-root scan still resolves 681+ files.
- Then run audit-full-path-excludes -Tighten and commit its baseline (2 sites).

Class fix: this is the fixture every process fix below must MUST-FIRE on:
- the edit-time hook (no-edit-time-construct-recognition)
- set-based ratchets (count-ratchet-slack)
- BLIND on zero (static-zero-scan-passes)
- the commit advisory (store-citation-blind-to-machinery)

CRITIQUE: Order matters: land this instance fix BEFORE static-zero-scan-passes. Otherwise every worktree push exits 3 on this gate.
For the walk, keep the `-ne $PSCommandPath` self-exclusion. Use Get-TcTreeFiles -PruneBelow AND keep the below-root filter, because tree-walk.ps1:59 says the prune cannot drop a file the filter keeps only if they share one pattern.
After the fix, run audit-full-path-excludes -Tighten (2 sites: the two probe-detector-*.py) and commit the baseline in the same change, or the slot stays open.
The fixture must prove:
- MUST FIRE: a planted inline wrap under a New-TcWorktreeFixture root is found and scanned>0.
- MUST NOT FIRE: a sibling worktree's copy is not counted.
- CLEAN TWIN: the main-root count stays in the 681-691 range, proving the prune did not drop real files.
- exit 3 with blind=1 on scanned=0.

### count-ratchet-slack [issue/code/medium] VERDICT=CONFIRMED
Count-only ratchets admit a NEW defect into slack left by a fixed old one

CORRECTED: Count-only ratchets admit a new defect into slack left by a fixed one. full-path-excludes does exactly that today: 3 sites against a mark of 4, and 1 of the 3 is new since the mark. At least 2 named-site ratchets already exist and could be lifted: grocery/test-native-stderr-eap.ps1:410-415 and ops/audit-typed-param-shadow.ps1 (Compare-TpsSites, :625-627).

FIX: lib/ratchet.ps1: add `Compare-TcRatchetSites -Current [string[] ] -Baseline [string[] ]` returning @{New; Gone}, as multisets, lifted from test-native-stderr-eap.ps1:410-415. Site key = '<path below root>|<whitespace-normalised line text>', with no line number, so an edit above a site does not move it.

Baselines gain `sites_named`, written only by -Tighten/-AcceptDrop. A run fails 'ROSE BY NAME' when New is non-empty, even with count <= mark. A baseline with no sites_named keeps the count check and prints 'count-only baseline: run -Tighten to name sites' (green on day one).

Convert in this order: full-path-excludes, write-seam, bare-replace, fixed-temp-names, cross-module-reach.

Fixtures in ratchet.ps1 -SelfTest:
- MUST FIRE: baseline {a,b}, current {a,c} gives New=[c] and exit 2.
- MUST NOT FIRE: current {a} gives can-tighten and New empty.
- CLEAN TWIN: the same site shifted 3 lines keeps its key.

Telemetry: the -COMPLETE marker adds new_by_name=N.

CRITIQUE: Lift ONE of the two existing implementations into lib/ratchet.ps1 and convert typed-param-shadow and native-stderr-eap to call it in the same change. Otherwise there are three.
Site keys must be built from Get-TcPathBelowRoot, so a worktree run and a main run produce identical keys. With full-path keys every worktree run reads 'ROSE BY NAME'.
Seeding gap: sites_named written 'only by -Tighten/-AcceptDrop' leaves a ratchet sitting exactly at its mark with no road to name its sites. Add a -NameSites mode that records names at an unchanged count and refuses when the count differs.
Text-keyed sites turn a rename inside a known bad line into gone+new, a false red on a refactor. Fixture it and state the -Accept road.
The fixture must prove:
- MUST FIRE: {a,b} to {a,c} exits 2.
- CLEAN TWIN: a site moved 3 lines keeps its key.
- CLEAN TWIN: a worktree-rooted run yields the same keys as a main-rooted one.
- a plain run leaves the baseline byte-identical.

### static-zero-scan-passes [issue/code/medium] VERDICT=CONFIRMED
run-gates scores a static detector that scanned 0 files as a pass

CORRECTED: Confirmed. run-gates scores a static detector that scanned 0 files as ok. A second gate, audit-lift-completeness, did the same on main 78 of 279 times (2026-09-10..11); whether its zero meant an empty set or a blind walk was not determined. The mapper's 'green on day one' check covered main only. In worktrees the proposed rule would be red on 12 of 12 readjson readings until that gate is fixed.

FIX: In ops/run-gates.ps1's static result loop (lines ~919-960), after reading each gate's COMPLETE marker, match `\b(scanned|files|examined|resolved)=(\d+)`. When the value is 0, rc is 0 and the $static entry lacks `zero_ok = $true`, score it 3 with token `blind=static-scanned-zero:<gate>`, which pre-push already names in its refusal.

Before landing, list every static entry's latest marker on main to prove the rule is green on day one: all main readings are non-zero today (readjson 681-691).

Fixtures, in lib/selftest-verdict.ps1 or run-gates' own discovery self-test:
- MUST FIRE: marker 'X-COMPLETE scanned=0 findings=0' with rc 0 scores 3.
- MUST NOT FIRE: scanned=681 scores ok.
- CLEAN TWIN: a marker with no count field is scored by rc exactly as before.

Waiver: `zero_ok = $true` on the entry, with its reason in the adjacent comment.

CRITIQUE: Ship order: readjson fix first, then this rule. Before landing, list the latest marker per gate in WORKTREE logs, not only main.
Decide zero_ok per gate by what zero means for it. lift-completeness shows zero can occur on main, and a checked set can legitimately be empty.
The new cause must be added in two places:
- ops/hooks/pre-push's cause table, or pre-push refuses naming no cause;
- ThriftyCrew CLAUDE.md's 'A 3 HAS FIVE CAUSES' (now six).
Apply the rule to the Python static loop as well.
Match only population fields (scanned|files|examined|resolved), never read=0 or findings=0. Fixture both: MUST NOT FIRE on 'files=725 read=0 sites=0'.
Confirm the gate-verdict fingerprint covers run-gates.ps1's own bytes, so a pass recorded before the rule is not replayed after it.

### store-citation-blind-to-machinery [gap/code/medium] VERDICT=CONFIRMED
The goal-1 record check (Store: line) covers the skills store and memories but never the estate's own machinery

CORRECTED: The Store: check does not cover estate machinery, and it is worse than the mapper says: citing it is punished. An estate markdown citation (.claude/rules/*.md, docs/*.md, design/*.md) is matched and then fails to resolve, because the resolver never looks in the repo. A .ps1 citation is not matched at all, so a Store: line that names only lib/atomic-write.ps1 reads as naming nothing. Over 2026-09-19..22, 11 of 11 commits that cited a rules file were marked unresolved. From 2026-09-25 each such commit is REFUSED, the opposite of goal 1.

FIX: ops/store_citation.py --commit-msg: after the Store: check, read `git diff --cached -U0 -- '*.ps1' '*.psm1' '*.py'` added lines and apply docs/machinery-index.json REPLACES patterns. On a hit where the diff does not name the helper, print 'MACHINERY ADVISORY: <file>:<line> <construct> - the estate has <helper> (<lib>)' and append {kind:'machinery', helper, file, construct} to its decision log. The exit code is unchanged: never refuse, because the gates refuse and a judgement has no exit code.

Extend PATH_RE so `docs/MACHINERY.md#...` and tracked lib/*.ps1 paths resolve as citations.

~/.claude/skills/store-usage-report.py adds 'machinery advisories: shown N, construct still pushed M of N'.

Fixtures (--selftest, temp repo with Clear-TcGitRepoEnv-equivalent env scrub):
- MUST FIRE: a staged diff adding `Move-Item $t $d -Force` prints an advisory naming Write-TcAtomicFile, exit 0.
- MUST NOT FIRE: a diff adding a Write-TcAtomicFile call.
- CLEAN TWIN: an unresolvable Store: line after REFUSE_FROM still refuses exactly as today.

CRITIQUE: This is time-critical: the resolver must accept repo paths (resolved against `git rev-parse --show-toplevel` of the committing checkout, so worktrees resolve their own files) BEFORE 2026-09-25. Treat it as a separate, small, first commit, not bundled with the advisory.
The advisory must read the staged diff the way :189 already does, with `git diff --cached` inheriting the hook env. A lower-effort implementer who scrubs GIT_INDEX_FILE (the Clear-TcGitRepoEnv habit) inside commit-msg reads the SHARED index. Since this repo commits with pathspecs over a temp index, it would then advise on other sessions' staged files.
The advisory stays exit 0.
The fixture must prove:
- CLEAN TWIN: `.claude/rules/ops-and-gates.md` and `lib/atomic-write.ps1` resolve in a temp repo.
- MUST FIRE: `.claude/rules/nope.md` still refuses after REFUSE_FROM.
- MUST NOT FIRE: an advisory under a pathspec commit names only the committed paths.

### ops-and-gates-too-large-to-follow [inefficiency/both/medium] VERDICT=OVERSTATED
ops-and-gates.md grew 38x in 13 days into narrative that is neither retrievable nor plausibly read at edit time

CORRECTED: The size and retrieval claims hold. The file grew 38x in 13 days to 48 bullets (4 of 48 at 300 chars or fewer). The hook index stores its body as ONE 10,978-token chunk, 30-40x the mean chunk, which BM25 length-normalises almost out of contention. 'Neither plausibly read at edit time' is inference from one incident (the readjson gate, written with the file loaded) and was not measured.

FIX: Rewrite to pointer form: each bullet is one sentence of rule + the helper + the gate that enforces it + one pointer (a [ [memory] ] or a docs/MACHINERY.md section). The incident narrative moves into the memory or design doc most bullets already cite. Add a `### <topic>` heading every 3-6 bullets so the hook chunker yields sections under ~1,500 tokens.

NEW ops/audit-rule-bullet-size.ps1, a ratchet on the count of top-level rules bullets over 400 chars. The mark is 66 on day one. A plain run never writes the mark; -Tighten records it via Test-RatchetMove, and it compares named keys (file|first 60 chars), per count-ratchet-slack. Register it in run-gates $static as daily.

Fixtures: MUST FIRE a new 401-char bullet over the mark gives exit 2; MUST NOT FIRE a 400-char bullet; CLEAN TWIN sub-bullets are counted with their parent.

Do this AFTER rules-frontmatter-inert step 4 (the split), so bullets land in the right file once.

CRITIQUE: The retrieval half is fixed cheaply and safely by adding ### topic headings every 3-6 bullets (chunk_file splits on levels 1-3). Do that first and on its own.
The pointer-form rewrite is riskier:
- Many bullets carry Brad's rulings verbatim: lock order 2026-09-12; I163 switch default; I196 at-the-bar cases; the 2026-09-19 ruling-push red. Inventory every ruling sentence first, and keep it verbatim in the pointer or in a design/ doc it points to.
- The memory directory is outside the repo, and rules forbid writing it from a worktree, so the rewrite cannot 'move narrative into the memory' from a spawned agent.
A bullet-size ratchet in run-gates makes adding a necessary rule a red. Keep it a report, or daily, and name-keyed as the mapper says.
Sequence it after rules-frontmatter-inert's scope decision, because that decides which file each bullet lands in.

### prose-only-helpers [gap/code/medium] VERDICT=CONFIRMED
7 of the 12 named helpers are enforced by prose alone; reinvention is rare but invisible

CORRECTED: 7 of the 12 named helpers have no gate that enforces their use: Add-TcLine, the prune half of Get-TcTreeFiles, Enter-TcLedgerLock, Write-TcLfFile, New-TcWorktreeFixture, Test-RatchetMove and Get-TcGlobalExclude. Reinvention after each helper existed, measured by git log -S over one regex per helper, is 1 real case in 3 constructs (the 2026-09-21 readjson walk). That regex census is unsound, so 'rare' is a lower bound on visibility, not a count of reinventions. The cited prior ruling 'no gate until a second lock is nested' is about lock ORDER and does not forbid a gate on hand-rolled ledger mutexes.

FIX: Do NOT add push gates for the seven. Carry them through the two recognition channels instead: the REPLACES patterns in docs/machinery-index.json feed recall-machinery-hook.py (edit time) and the store_citation advisory (commit time), and each entry's `enforced_by` reads mode:'none', so the offer text says 'no gate enforces this; the helper is the only guard'.

Patterns to seed:
- `New-Object\s+System\.Threading\.Mutex|\[System\.Threading\.Mutex\]::new` outside lib\ gives Enter-TcLedgerLock.
- `Add-Content\b[^\n]*\.(jsonl|log)\b` gives Add-TcLine.
- `Get-ChildItem\b[^\n]*-Recurse` in a file with no `Get-TcTreeFiles` gives Get-TcTreeFiles.
- `ConvertTo-Json[^\n]*\|\s*(Set-Content|Out-File)` gives Write-TcLfFile.
- `\[int\]\$\w+\s*-(gt|lt)\s*\$base` in an audit-*.ps1 gives Test-RatchetMove.

Measure after one week, off the ev=adopted/persisted join, before proposing any gate.

CRITIQUE: The seed patterns will be noisy:
- `Get-ChildItem\b[^\n]*-Recurse` in a file without Get-TcTreeFiles fires on walks of temp dirs and non-repo roots, where pruning is irrelevant.
- `ConvertTo-Json | Set-Content` fires on gitignored out\ reports that need no LF writer.
- The ratchet regex `\[int\]\$\w+\s*-(gt|lt)\s*\$base` guesses a code shape and will miss most ratchets.
Measure each pattern's fire rate on a FULL-BODY corpus before shipping. The existing probe corpus truncates edits at 1,200 chars.
The fixture per pattern is the helper gate's own MUST FIRE text plus one legitimate use that must stay silent.

### analysis-machinery-undiscoverable [gap/analysis/medium] VERDICT=CONFIRMED
For analysis, committed harnesses and prior measurements are as undiscoverable as the libs

CORRECTED: For analysis, committed harnesses and prior measurements are about as undiscoverable as the libs. 27 measurement docs exist in design/ and 6 of 27 are named in the skills store. About 31 committed harness-named scripts exist and 6 of 31 are named in the two rules files a session is given. The exact counts depend on the name pattern.

FIX: Covered by no-estate-machinery-index kinds 'harness' and 'measurement'. Per harness: purpose line, params, and which MEASURE doc cites it (grep design\ for the file name). Per measurement doc: title, date, harness(es) named, first line beginning 'Result'/'Verdict'/'Measured', and the audit-conclusion-currency status read from that audit's -Json output (never recomputed).

The MACHINERY.md section for a harness lists 'last cited by <MEASURE doc>'. The PreToolUse intent hook (recall-intent-hook.py, which fires on a judgement-shaped description) may additionally run `search.py --estate` over the description and append at most 2 harness or measurement pointers. That is similarity retrieval over a task description, which 2a did not measure, so write its bar first: >= 12 of 20 hand-labelled analysis descriptions retrieve the right harness or prior MEASURE doc at hit@3.

Fixtures (generator self-test): MUST FIRE a temp ops\probe-x.ps1 appears as kind=harness; MUST NOT FIRE a scratch file under grocery\out\ is excluded; CLEAN TWIN a MEASURE doc naming it links back.

CRITIQUE: The intent-hook extension is similarity retrieval over a task description (tier 2), so write its bar first, as the mapper does. Do not let it ride inside recall-intent-hook without its own log field, or its offers are indistinguishable from today's.
Read audit-conclusion-currency -Json at generation time only, never inside a push-time staleness check: its answer changes whenever a harness moves.
The biggest goal-2 risk sits in rules-frontmatter-inert. If measurement.md's scope ever becomes effective with its current code globs, analysis sessions lose the measurement rules entirely.
The fixture must also prove that a scratch harness under grocery\out\ or the session scratchpad is excluded.

### worktree-recall-drops-project-memory [issue/both/medium] VERDICT=CONFIRMED
From a worktree cwd, the hook's corpus drops all 187 project memories, and project_key could never match Claude's worktree directory spelling

CORRECTED: From a worktree cwd the hook's lexical corpus drops all 187 project memories. From a subdirectory cwd (for example C:\Codex\ThriftyCrew\grocery, 1 session transcript) it drops memory AND rules. project_key keeps '.', while Claude's own directory names replace every non-alphanumeric, so the key can never match a worktree's own project dir either. The agent hook and the embedding corpus derive from the same function.

FIX: recall_index.resolve_roots: before project_key, map a cwd whose path contains `\.claude\worktrees\<name>` to the prefix before `\.claude\worktrees` (the main checkout). Fall back to `git -C <cwd> rev-parse --path-format=absolute --git-common-dir`'s parent, with a 2 s timeout and fail open to today's behaviour. Use that main path for the memory corpus key and keep the worktree's own rules dir.

Fixtures in recall_index.selftest():
- MUST FIRE: cwd <tmp>\Repo\.claude\worktrees\wt1 with memory under <home>\projects\<key(Repo)>\memory gives a memory corpus present.
- MUST NOT FIRE: <tmp>\Repo\worktrees\x (not under .claude) is unchanged.
- CLEAN TWIN: the main checkout's roots are identical to today's.

Gate it through recall-hook-calibrate.py, because it changes what every worktree session is offered.

CRITIQUE: Prefer `git rev-parse --path-format=absolute --git-common-dir` over string-matching '\.claude\worktrees\'. The string match misses subdirectory cwds and checkouts outside the tree (20 C--Codex-tc-exp-* project dirs show sessions ran from such checkouts). Cache the answer per cwd, because UserPromptSubmit pays the git spawn on every prompt.
TAG COLLISION, the likeliest lower-effort bug: computing one main key and using it for both corpora tags the worktree's rules dir 'rules:C--Codex-ThriftyCrew', the same tag as main's rules with a different root. refresh_if_due then flips that corpus between two directories as sessions alternate. Keep the rules tag per worktree, or map rules to main deliberately and say so.
recall-embed-memory.py must embed the same corpus tags, or the semantic leg queries one that does not exist.
Also normalise project_key to Claude's spelling (every non-[A-Za-z0-9] becomes '-'), with a fixture path containing '.' and '_'.
The fixture must prove:
- MUST FIRE: worktree and subdirectory cwds get the main memory corpus.
- CLEAN TWIN: main roots are byte-identical to today's.
- the corpus tags are unique per root.

### reflex-ps-rows-fire-on-non-ps-files [inefficiency/code/low] VERDICT=CONFIRMED
PowerShell-construct reflex rows fire on Writes of Python files and regex literals

CORRECTED: Confirmed. PowerShell-construct rows with tools Edit/Write fire on Writes of .py files and on cmdlet names inside strings or regexes, because a row cannot be scoped by file type.

FIX: Add an optional `ext` field to reflex rows, read in recall_reflex.in_scope. For edit-kind text (the first line is file_path, per recall_core.py:550), skip when the path's extension is not in row.ext. Set ext [".ps1", ".psm1"] on set-content-no-encoding, get-content-no-encoding, ps-array-wrap-call and count-on-maybe-absent.

Fixtures in recall_reflex self-test:
- MUST NOT FIRE: a Write to x.py containing 'Set-Content' in a regex.
- MUST FIRE: a Write to x.ps1 with a bare `Set-Content out.json -Value $j`.
- CLEAN TWIN: a PowerShell tool command is unaffected.

Re-score max_fire_rate with recall-reflex-stats.py.

CRITIQUE: The likeliest lower-effort error is reusing the existing `scope` field with '.ps1'. `scope` is a substring test over the whole action text, so on the PowerShell tool it would require the COMMAND to contain '.ps1' and silence the row for nearly every PowerShell command. `ext` must apply only when kind == 'edit' (the first line is file_path).
Include .md in the MUST NOT FIRE set: docs about PowerShell trip it too.
Re-scoring with recall-reflex-stats.py is limited: the probe corpus truncates edits at 1,200 chars, so edit-kind fire rates are measured on partial text.

### shared-scratch-clobber [issue/general/low] VERDICT=PLAUSIBLE
The workflow gave nine concurrent reviewers one shared scratch directory; I overwrote a sibling's file

CORRECTED: The workflow handed concurrent reviewers one shared scratch directory with 296 top-level files. A same-name overwrite is likely but cannot now be verified. This verifier's brief also names only the shared parent.

FIX: In the workflow script, hand each reviewer `scratchpad\review\<subsystem-slug>\` and say in the brief that the parent directory is shared. Optionally create the directory with -ErrorAction Stop so a clash refuses rather than shares. The orchestrator should treat any sibling finding built on a file named coverage.py in review\ with suspicion.

CRITIQUE: Key the directory per AGENT, not per subsystem: a mapper and its verifier share a subsystem slug and would collide again. Create it with -ErrorAction Stop (or os.makedirs(exist_ok=False)) so a clash refuses. Name it in every brief, the verifier's included.

### strength-lib-headers [strength/both/low] VERDICT=CONFIRMED
Lib headers are already index-grade raw material

CORRECTED: Confirmed for purpose lines, 102 of 102. The function doc-comment count (525 of 737) was not re-measured here.

FIX: Generate from the headers and never author the index by hand. Add only the three optional machine lines (USE WHEN, REPLACES, ENFORCED BY) where a probe shows the purpose line is in estate vocabulary (for example global-exclude-lib's 'prepared/processed term list').

CRITIQUE: Generate, never hand-author. The risk is USE WHEN / REPLACES drifting from the gate that enforces the same construct. Fixture each REPLACES pattern against that gate's frozen MUST FIRE text, compiled in the engine that will run it (Python re for a hook).

### strength-bridges-and-gates [strength/code/low] VERDICT=OVERSTATED
The concurrency and software applies-here bridges and the helper gates demonstrably work

CORRECTED: The concurrency and software applies-here bridges reach 4 of 12 helpers by task and construct phrasing in both engines. The helper gates fired 11 times in 5,011 runs. A low red rate is also what a blind gate produces (readjson, 12 of 12 blind in worktrees) and what an unscheduled daily tier produces, so these numbers show the gates sometimes fire. They do not show coverage.

FIX: Keep both. MACHINERY.md sections link back to the applies-here section that names each helper (rule_refs extended to skills), and edit-time offers name the gate so the push-time refusal stays the enforcement.

CRITIQUE: Keep the bridges and gates, but do not cite a low red rate as health. Report reds together with per-gate scanned counts per checkout, which static-zero-scan-passes would make possible.

## Missed by mapper
- [high] From 2026-09-25 the Store: check refuses commits that cite the estate's own rules or docs: ops/store_citation.py:129-140: resolve() checks only ~/.claude/skills, ~/.claude and the two memory dirs. :146 and :161-162 turn an unresolved citation into mode 'refuse' from REFUSE_FROM=2026-09-25. In-process results: resolve('.claude/rules/ops-and-gates.md') False; resolve('docs/RUNTIME-MAP.md') False. PATH_RE does not match 'lib/atomic-write.ps1' at all, so a Store: line naming only a lib reads as naming nothing. ~/.claude/store-citation-log.jsonl, 335 rows, 2026-09-19 09:14 to 2026-09-22 20:57 UTC (citation-log.py):
- 15 of 335 had unresolved citations;
- 17 of 21 unresolved tokens were estate paths (12 .claude/rules, 5 design/);
- 11 of 11 commits citing a .claude/rules path were marked unresolved.
- [medium] The reflex fire-rate corpus truncates edits at 1,200 chars, so edit-time fire rates are measured on partial text, and the corpus the mapper's bar names is not committed: recall-tool-probes.py:101 `return "edit", (str(path) + "\n" + body[:1200])`. recall_reflex.load_probes (:849-864) feeds that corpus to fire_rates and max_fire_rate. The live hook matches 2,000 chars (recall_core.py:549), so every Edit/Write row's recorded fire rate comes from a shorter window than the hook uses. A full-body recognition hook cannot be measured with the existing harness at all. The '838 changes of 2026-09-11' corpus is described only in prose (automatic-recall.md:203); searching ~/.claude/skills *.py/*.jsonl/*.json for '838' and candidate-3 names found no committed file.
- [medium] The agent hook and the agent-reach memory depend on the rules scope staying inert: recall-agent-hook.py:13,127,303-304 exclude every rules and memory hit from subagent briefs because 'a subagent already has the MEMORY.md index and the rules files'. Memory what-actually-reaches-a-spawned-agent.md:20 records 'path-scoped rules ... Yes - quoted the known-wrong.json line'. That observation is consistent with unconditional loading and was read as scoped loading. If any rules file gains an effective `paths:` scope, subagents that have not touched a matching file lose it, and the agent hook still refuses to send it.
- [medium] measurement.md's declared scope does not cover analysis work, so making scope effective would remove the analysis rules from analysis sessions: measurement.md front matter: globs "sidecar/**, **/*eval*.py, **/*probe*.py, **/audit-*.ps1, **/*_eval.py". None covers design/MEASURE-*.md, design/EVAL-*.md, design/PLAN-*.md or scratch scripts outside the repo, which is where goal-2 analysis happens. Today the rules reach analysis sessions only because the field is inert (see rules-frontmatter-inert).
- [medium] The false 'rules load when you touch' belief is written in at least 9 carriers, and fixing 11.1 alone leaves the rest: Grep for 'load(s|ed) (only) when you touch|path-scoped|loads only when':
- ~/.claude: MEMORY.md, what-actually-reaches-a-spawned-agent.md, recall-agent-hook.py, claude-code-craft/claude-md-and-commands.md and MAP.md, agent-workflow-craft/applies-here.md, course/LEDGER.md, PLAN-applied-recall-2026-09-07.md, QUEUE.md;
- the repo: 5 of 6 rules files, ops/audit-rule-currency.ps1, design/BACKLOG-course-findings.md, design/PLAN-backlog-2026-09-06.md.
recall_core.py:546-547 also calls the rules 'the most reliably obeyed channel', selected by path. Archived claim C3 is marked RESOLVED for `globs`.
- [low] A second static gate reported scanned=0 with exit 0 on main: zero-scan.py over 26,587 distinct gate-readings rows (2026-09-10..23 UTC): ops\audit-lift-completeness.ps1 emitted 'LIFT-COMPLETENESS-COMPLETE scanned=0 findings=0' with rc 0 on 78 of 279 main rows, all 2026-09-10..11; scanned=1 since. Whether that zero was an empty checked set or a blind walk was not determined. Either way, a zero-scan rule needs a per-gate zero_ok decision.
- [low] resolve_roots keys on the raw cwd, so a session launched from a repo subdirectory gets skills only: In-process resolve_roots(r'C:\Codex\ThriftyCrew\grocery') returns ['skills']: no memory and no rules. projects\C--Codex-ThriftyCrew-grocery exists with 1 session transcript and no memory dir. The same function feeds recall-agent-hook.py:152 and recall-embed-memory.py:55,68.

## Open questions
- Scoped or always-on rules? Today every ThriftyCrew session gets all 118.5 KB by accident, because the scope field is inert. Brad needs to rule on reach vs attention before the `paths:` switch, and the InstructionsLoaded log proposed in rules-frontmatter-inert would say what each choice costs.
- Does a `paths:`-scoped rule load on Write or Edit of a NEW file when that file was never Read? Not measured; the two-file test is step 2 of rules-frontmatter-inert.
- Does Claude Code load MEMORY.md and the project memories for a session LAUNCHED in a worktree cwd, whose project dir is '--claude-worktrees-'? Only the hook side (recall_index) was verified here.
- Semantic-leg (sidecar :8077) hit rate for the 12 task-phrased helper queries: not measured.
- Do headless scheduled runs (Task Scheduler invoking claude) fire the user's PreToolUse hooks the way this Workflow agent did? Not measured; it decides whether the edit-time hook reaches unattended code writes.
- Should REPLACES patterns live in lib headers, or in the enforcing audits that already encode the construct, with the index reading both? The proposal is headers, fixtured against each gate's MUST FIRE so the two cannot drift silently.
- How many of the 737 lib functions have no caller at all? The index's caller count would surface this; not measured here.
- Prototype contamination: the 12 queries were written after reading 4 of the headers that own 5 of the 12 helpers. The uncontaminated 5 of 7 is the honest prototype number, and a probe set written by someone who has not read the headers is still needed.
