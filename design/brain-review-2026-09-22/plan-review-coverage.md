# Coverage of Brad's two goals, end to end: what knowledge reaches code and analysis work, at what moment, in each of the eight scenarios, once every item and recommended ruling has landed.

The plan is mostly sound for goal 1. It has four holes that a lower-effort build would ship as they stand, and it is thin on goal 2 outside record files. Here is each scenario in the end state.

(i) A main-session bug fix in grocery\*.ps1 works. After D3, the first Edit is denied once. The deny carries the --estate command and exact matches from the 6 .ps1 machinery rows. The search reaches the skills, both memory stores, the rules one bullet at a time, the machinery index and a grep. Later writes get remind rows, and the commit record accepts estate citations. This holds only if the command parses (issue 2) and the file is written through Edit/Write (issue 1).

(ii) An Agent-tool subagent building a new ops audit in a worktree gets the brief gate, skills-only agent-hook pointers, its own agent-keyed marker, the deny, and the worktree memory fix. A NEW file has no path routes, though, and nothing at the brief names estate machinery. So the audit contract reaches it only as always-loaded rules prose, whatever its own query finds, plus 2 of the 6 rows (walk, temp). W6.10 catches a zero-file scan at push.

(iii) A Workflow agent editing lib\*.ps1 is covered only if W1.1 shows that agent_id is present and that an Edit deny is honoured. No fallback is stated if the deny is not honoured. The W4.4 script gate needs D5.

(iv) A scheduled triage-reviewer at C:\Codex loses its prompt offers (fine: 0 were opened). Its task and agent files carry the search step, and --estate falls back to the ThriftyCrew default. But the reviewer has no Write tool and wrote 6 of its 6 plans with PowerShell, so W4.1 never stops it (issue 1). W5.3 refuses at validation, and it checks presence only.

(v) A chat answer to "did X improve?" gets push only: the CLAUDE.md block, a conditional prompt route and a 6-verb intent card. No search is ever required, and the only answer-time check is a log-only footer rung. This is still the largest hole (issue 6).

(vi) Fantasy Python is denied once. Its --estate searches the skills, the ThriftyCrew and C--Codex memories, and a module index and grep of Fantasy. It never searches Fantasy's own memory store. No machinery row covers Python, and the Store: hook waits on D8.

(vii) A brain edit is in W4.1's scope. But the deny's search is rooted at the session cwd, so a brain edit from a ThriftyCrew cwd searches ThriftyCrew (issue 3).

(viii) A MEASURE doc is covered when it is the context's first in-scope write. When the context already searched for a code change, it gets no analysis pointer (issue 8).

Would Brad recognise the plan as "a hook to reference all our internal machinery knowledge"? Partly. He would recognise "the first code write is stopped and told to search everything we know". But the hook itself references only six .ps1 constructs. The rest of "all our machinery" depends on the words the model picks, and the analysis half refuses only at a record file. One change makes it recognisable: generate the edit-time recognition rows from the W3.2 index's REPLACES headers, and print the matched index entries (helper, lib, gate) in the deny and in every later remind. Then the hook itself visibly references the whole catalogue by exact recognition, not similarity, so 2a still holds, and the catalogue grows as each lib declares what it replaces (issue 4). Issue 10 is outside this lens and is still worth fixing: W6.4 reverses a critic guardrail.

Scratch scripts behind the new measurements are in C:\Users\Owner\AppData\Local\Temp\claude\C--Codex-ThriftyCrew\134f2f6e-7fb9-4057-a890-b2c27ba9dfc0\scratchpad\planreview\goal-coverage\. All of them exited 0.

## [high] W4.1 step 1 (scope), section 1 Goals 1 and 2, section 7 M1
W4.1 judges only the file_path of an Edit/Write. Code and analysis records are also written by shell commands, and the same hook already sees those. The triage-reviewer is the one agent whose job is diagnosis, and it has no Write tool: it writes every plan through PowerShell. So section 1's goal-2 property (before the first write of a triage plan, the context has searched or been stopped once) is false for the daily analysis lane. Goal 1 has the same hole for code written through a shell. M1's instrument ('before the context's first in-scope Edit/Write') cannot see these contexts at all, so the bar would read green over them.

EVIDENCE: - .claude/agents/triage-reviewer.md:6 `tools: Read, Grep, Glob, Bash, PowerShell, WebFetch, WebSearch` (no Write or Edit); :197 'Write TWO files: the plan ...'.
- settings.json PreToolUse matcher `Bash|PowerShell|Edit|Write` runs recall-reflex-hook.py (listed by scratch hooks_list.py, exit 0).
- Scratch plan_writers.py and plan_writer_types.py, transcripts modified in the last 10 days, exit 0: 37 plans had an observed first writer, and 14 of 37 were first written by PowerShell or Bash. triage-reviewer: 6 of 6 by PowerShell.
- Scratch shell_code_writes_strict.py, exit 0. The regex is UNSOUND: it misses paths built from variables. It found 614 shell writes of code files against 10,190 Edit/Write, and 56 of 481 code-writing transcripts wrote code ONLY through a shell. Samples: `cat > /c/Codex/ThriftyCrew/grocery/native-lib.ps1`, `WriteAllText('C:\Codex\ThriftyCrew\.claude\worktrees\i221-notcarried\grocery\derive-not-carried.ps1'`.
- Plan lines 668-673 and 725-727.

FIX: Replace W4.1 step 1's first sentence with: "The target is the `file_path` of an Edit/Write, OR, for a Bash/PowerShell call, each literal path that is the direct target of a write in the command: `[IO.File]::WriteAllText(`, `Set-Content`, `Out-File`, `Add-Content`, `Write-TcLfFile`, `Write-TcAtomicFile`, the destination of `Copy-Item`/`Move-Item`/`cp`/`mv`, `cat >`/`cat >>`, `tee`, a `> <path>` redirect, and Python `open(<path>, 'w'...)`. Each target goes through the same in-scope test. A target built from a variable is not resolved: log `unresolved_target: true` and never deny on it."

Add fixtures:
- MUST FIRE: deny mode, no marker, PowerShell `[IO.File]::WriteAllText('C:\Codex\ThriftyCrew\grocery\triage-plans\plan-2026-09-30.json', $j)` is denied with the analysis wording.
- MUST NOT FIRE: `Get-Content C:\Codex\ThriftyCrew\grocery\triage-plans\plan-2026-09-30.json`.
- MUST NOT FIRE: `Set-Content $p $x` logs unresolved_target and does not deny.
- CLEAN TWIN: the existing heredoc-writes-a-file block still wins on `cat > x.ps1 <<EOF`.

Change M1's instrument to: "before the context's first in-scope write (an Edit/Write, or a shell write resolved as in W4.1 step 1)".

## [high] W3.3 Definition (--estate [ROOT]) and W4.1 step 2 (the marker)
search.py already takes its query as `nargs="*"` positionals and already has a `--root` option, which means the SKILLS root. A lower-effort build will read `--estate [ROOT]` as an option with an optional value (argparse nargs='?'). Then `search.py --estate "path below root"` treats the query as ROOT and searches an empty query. That is exactly the shape of W3.3's own MUST FIRE fixture and of W4.1's deny command. search.py logs nothing on an empty query, but W4.1 creates the marker on 'a successful search.py run', which is undefined and in W1.6 is a match on the command string. So a misparsed or empty search passes the gate while searching nothing, and M1 counts it as compliance.

EVIDENCE: - search.py:1101 `ap.add_argument("query", nargs="*", ...)`; :1120 `ap.add_argument("--root", default=SKILLS_ROOT, help="skills root to index")`; :1141 `takes_value = {s: (a.nargs != 0)`; :1094-1096 logs only `if ... args.query and rc is not None`.
- Plan 616-618 (`--estate [ROOT]`), 632 (fixture `--estate "path below root"`), 690 (deny command), 674-677 (marker 'On a successful search.py run'), 369-372 (W1.6's command-string test).

FIX: Replace W3.3's first Definition bullet with: "`--estate` is a flag (`action=\"store_true\"`) and never takes a value. The checkout is `--estate-root <path>`, a NEW option (never reuse `--root`, which is the skills root at search.py:1120), else checkout_root(cwd), else the estates.json default."

Add a W3.3 fixture: CLEAN TWIN `search.py --estate "path below root"` parses to query == ['path below root'] with estate_root None.

Add to W3.3: "Whenever a query ran, search.py prints `KNOWLEDGE-SEARCH-COMPLETE legs=<n> hits=<n> blind=<n>` as its LAST line."

In W4.1 step 2, replace "On a successful search.py run" with: "When the PostToolUse tool_response content contains a `KNOWLEDGE-SEARCH-COMPLETE` line. hits=0 still counts. An empty query, a usage error, `--help` or `--selftest` prints no such line and creates no marker."

Add a fixture: MUST NOT FIRE, a search.py call with no query creates no marker.

## [medium] W4.1 step 6 (the deny command) and W3.3 MEMORY leg; scenarios vii and vi
The deny command takes the estate from the session cwd, not from the file being written. A session at C:\Codex\ThriftyCrew is the usual cwd for brain work. When it edits ~/.claude/skills/recall-hook.py, it is told to search ThriftyCrew's rules, machinery and grep. The brain's own modules are indexed only when ~/.claude is the checkout. Separately, the MEMORY leg is a hard-coded pair (ThriftyCrew and C--Codex), while W2.1 picks the store by canonical_root. So a Fantasy session never searches Fantasy's own store, and the plan now holds two rules for 'which memory store'.

EVIDENCE: - Plan 616-618: the checkout is ROOT, else checkout_root(cwd).
- Plan 690: the deny text passes no root.
- Plan 578-579: kind=py indexes first-party modules of the checkout only.
- Plan 621-622: MEMORY is 'both stores ... duplicated from store_citation.MEMORY_PROJECTS'.
- Plan 409: W2.1 takes memory from project_key(canonical_root).
- critic.md:117 (scenario vii): the brain has no rules dir and no CLAUDE.md.

FIX: In W4.1 step 6, change the command line to `C:\Codex\Python312\python.exe C:\Users\Owner\.claude\skills\knowledge-search\search.py --estate --estate-root "<checkout_root(file_path)>" "<3-6 words for what this change does>"`. The hook computes the root from the TARGET path with W2.1's checkout_root.

Add a fixture: MUST FIRE, a payload with cwd C:\Codex\ThriftyCrew writing C:\Users\Owner\.claude\skills\x.py is denied with `--estate-root "C:\Users\Owner\.claude"`.

In W3.3's MEMORY leg, replace the hard-coded pair with: "the store of canonical_root(checkout) plus store_citation.MEMORY_PROJECTS, de-duplicated, each hit tagged with its store".

## [medium] W4.2 rows and W3.2 REPLACES headers; section 1 line 57
Section 1 promises that 'Every later write that re-types a construct the estate already has a helper for is reminded of the helper by name.' W4.2 ships six hand-written rows, all exts .ps1/.psm1, and 5 of the 6 guard constructs a push gate already refuses. W3.2 has authors write `# REPLACES:` regexes into 19 libs and tests them against the gates, but no item feeds those patterns to the reflex engine (critic C5 allowed exactly that). So the prose-only helpers get no edit-time recognition, although for them it is the only guard: Enter-TcLedgerLock, Write-TcLfFile, New-TcWorktreeFixture, Test-RatchetMove, Get-TcGlobalExclude. No ThriftyCrew Python construct is recognised either. This is also why the hook does not read as 'reference ALL our machinery'.

EVIDENCE: - Plan 57-58, 584-591, 605 (REPLACES is parsed and tested, never consumed), 759-770 (six rows; the Gate column is non-empty for 5 of 6).
- digest-estate-machinery.md prose-only-helpers CORRECTED: '7 of the 12 named helpers have no gate that enforces their use'. Its FIX routes REPLACES patterns to edit time and commit time.
- critic.md:146: 'Header REPLACES: lines may generate rows but never run as a second matcher.'

FIX: Add a W4.2 step, 'Generated rows':
"`machinery_index.py --reflex-rows` writes `~/.claude/cache/machinery/<key>/reflex-rows.json`: one row per `# REPLACES:` pattern, with class 'machinery', helper = the lib file plus the function its USE WHEN names, gate = the ENFORCED BY path or 'none', exts from the lib's language, except_paths = the lib and its gate, and rung remind. recall_reflex loads this file after recall-reflexes.json (one engine). A generated row whose id collides with a hand row is dropped and counted. Every generated row passes the same `--rate` bar (at most 2%) and the same two-must_fire, two-must_not_fire rule. The fixtures come from the gate's MUST FIRE literal, or, when ENFORCED BY is none, from `# REPLACES-FIRE:` and `# REPLACES-SILENT:` example lines beside the header. A pattern missing either is not emitted and is listed as BLIND."

Seed the prose-only helpers first:
- Enter-TcLedgerLock: `New-Object\s+System\.Threading\.Mutex` outside lib/;
- Write-TcLfFile: ConvertTo-Json piped to Set-Content or Out-File;
- Add-TcLine.

The deny's 'Estate machinery this text already touches' block and every remind print the matched index entry (helper, lib, gate or 'no gate enforces this').

Amend line 57 to: "...is reminded of the helper by name when the helper's header declares what it REPLACES."

## [medium] W4.1 step 6 and fixture versus W3.3's bar, W3.4 and section 6 row 8
W3.3's bar may keep --estate opt-in. W3.4 is conditional on that bar and lists 'W4.1's deny text' as a place to switch. Yet W4.1 step 6 and its MUST FIRE fixture hard-code `search.py --estate`, and section 6 row 8 lets deny go live on 'shadow bars, W1.1' without W3.3's bar. A lower-effort build will either ship a deny whose command the plan's own bar rejected, or drop --estate and force searches over the skills-only corpus, which section 3.2 says 'teaches ceremony'.

EVIDENCE: - Plan 638-642 (W3.3 bar: 'Otherwise ... keep it opt-in').
- Plan 644-653 (W3.4 'only if W3.3's bar holds' ... 'W4.1's deny text').
- Plan 690, 704-705 (the fixture asserts `search.py --estate`).
- Plan 1259 (row 8 Needs: 'shadow bars, W1.1').
- Plan 127-129.

FIX: In section 6 row 8, change Needs to "shadow bars, W1.1, W3.3's bar held".

Append to W4.1 step 6: "The command always carries `--estate` (its SKILLS leg is byte-identical to today's output, so it is never worse). If W3.3's bar did not hold, W4.1 does not leave remind mode, and D3 is put to Brad with W3.3's result attached."

## [medium] W5.7 step 4 and W5.5 step 3; section 1 Goal 2 (scenario v)
An analysis answered in chat (python -c plus Read, no file) never reaches W4.1. The only answer-time analysis check, W5.7's analysis rung, asks for a Consulted: or Checked: line, and that footer is a habit. So goal 2's 'same concept' has no pull anywhere for chat answers. The log cannot even say whether an analysed answer was preceded by a search, although the W4.1 marker answers that per context for free.

EVIDENCE: - Plan 60-64, 1068-1071, 1028-1042.
- digest-analysis-path.md consulted-gate-blind-to-prompt-offers CORRECTED: footers appear on 384 of 453 turns with nothing offered; armed turns named anything in 34 of 159.
- critic.md:99-100 (scenario v): 'What enforces: nothing ... This is the largest hole in goal 2.'
- Plan line 122: pull converts 18.8% against push's 3.1%.

FIX: Append to W5.7 step 4: "Every analysis-rung row also logs `searched` (a valid W4.1 marker exists for this session_key under the same TTL) and `marker_age_s`. The report prints 'analysis answers with no search in the context: N of M'. D4 then offers Brad two refusal shapes: a missing footer, or no search in the context (refuse once, with the same command and brake as W4.1)."

Append to W5.5 step 3: "The intent log row for kind 'analysis' also logs `searched`."

## [medium] Section 7 M1/M2, W1.6 step 1, W3.3 log row
Under a deny-once gate, M1 (searched before the first write, at least 80%) is almost implied by M2 (redo without search, at most 20% of denies). Both measure obedience to the gate. No metric says whether the forced search returned anything the context then cited, and line 1279 counts 'a search' as a use. The plan's own rule is that an open is not a use, and the same holds for a search. The data is nearly free: the search row already logs the returned `paths`, and store_citation logs cited tokens. But nothing says the row will carry the keys from the non-skills legs.

EVIDENCE: - search.py:1052-1057: search_row already carries `"paths": list(paths)`.
- Plan 1269-1270 (M1, M2), 1279-1280 ('USED as an action (a search, ...)'), 367-368 (W1.6 adds corpus, cwd, child and flags, not per-leg keys).
- critic.md:247: 'The residual risk is ceremonial searches, which named-item rates can measure.'

FIX: Add to W3.3: "The log row's `paths` lists every returned key from every leg, prefixed by leg: `memory:<store>/<slug>`, `rules:<file>#<lead>`, `machinery:<relpath>`, `grep:<relpath>`."

Add to section 7 as M10: "Denied-then-searched contexts whose Store: line, Knowledge consulted section or triage `knowledge_consulted` names at least one key that their own search returned: N of M, reported per origin (main, agent, workflow). Bar, written now as the first plausible value and not a swept one: at least 25% after 14 days of deny. Below that, the finding goes to Brad as ceremony, never into a second deny."

## [medium] W4.1 steps 2, 6 and 7 (one marker and one brake for both kinds; scenario viii)
Code files and analysis records share one marker and one deny brake. A common shape is to fix code, then write design/MEASURE-*.md about it. A context that searched for its code fix and then writes the record is never shown the analysis preflight at the record moment, because the analysis wording exists only inside the deny.

EVIDENCE: Plan 674-677 (one marker per session_key), 685-697 (the analysis wording appears only in the deny; one `.denied` per context).

FIX: Add a W4.1 step 6b: "On the FIRST analysis-record write in a context that already holds a valid marker, emit one line of additionalContext, once per context (O_EXCL `<session_key>.record-pointed`): `Analysis record: the preflight is C:\Users\Owner\.claude\skills\experiment-craft\analysis-preflight.md; the rules are C:\Codex\ThriftyCrew\.claude\rules\measurement.md.` It lands after the write, and records are revised."

Fixtures:
- CLEAN TWIN: a context with a code marker writes design\MEASURE-x-2026-09-30.md, proceeds, and gets the pointer once.
- MUST NOT FIRE: its second record write gets nothing.

## [medium] W4.1 (headless contexts) and section 1 line 54
Section 1 lists 'a headless run' as in scope, and W4.1 never mentions headless. On 2026-09-19 Brad approved that a headless pipeline call is never refused at Stop, because a refusal in `claude -p` costs a schema'd answer and a re-ask. A lower-effort build will either copy headless_reason() into W4.1, silently exempting every headless coder, or leave it out, denying inside the pipeline calls the ruling protects. Neither choice is recorded anywhere.

EVIDENCE: - recall-consulted-hook.py:35: '*** A HEADLESS PIPELINE CALL IS NEVER REFUSED. *** [ADDED 2026-09-19, Brad approved]'; headless_reason at :87-88.
- Plan 54 and 663-734: no headless case in W4.1's steps or fixtures.

FIX: W4.1 step 5: the shadow row adds `headless: <headless_reason() or \"\">`. Move headless_reason() from recall-consulted-hook.py into recall_core, one copy used by both.

W4.1 step 6: "Deny mode never denies when headless_reason() is non-empty. It logs would_deny instead, until Brad rules." Add D3b to section 9: "Deny headless coders: yes or no, decided on the shadow count."

Fixture: MUST NOT FIRE, deny mode with TC_HEADLESS=1 logs would_deny and emits nothing.

## [high] W6.4 step 1 and section 8 (outside this lens, verified)
W6.4 step 1 says to re-run the graph-alias ingest 'by hand, in the main tree'. The critic's guardrail list, which the plan claims to honour, forbids exactly that. An ingest from C:\Codex\ThriftyCrew writes the tracked exports graph/learning/proposals.json and approved-patches.json into the shared main tree, and the 07:00 bot then commits them ungated. Section 8 copied the guardrail without its 'main tree' half. Step 1 also says 'the reviewer model must be named', but the critique says the reviewer is Brad, not a model, and each ruling must be re-checked against today's proposal before ingest.

EVIDENCE: - Plan 1135-1136; plan 1310 ('Do not run graph ingest in a worktree without graph.db').
- critic.md:337: 'Graph ingest. Do not run it in the main tree or in a worktree without graph.db'.
- digest-offline-loop.md approvals-applies-dead CRITIQUE (2), (3) and (4).

FIX: Replace W6.4 step 1 with: "Re-run the killed batch once, from the place D13 names: a linked worktree that has graph.db, landing the exports through ops\\push-main.ps1, or a graph-owned command. Never the main tree (the 07:00 bot commits its exports ungated), and never a worktree without graph.db. The verdicts file carries `reviewer: 'Brad via approvals page 2026-09-12'`. Before ingesting, re-check each ruling against today's proposal (same id, status still 'proposed', payload hash unchanged), and skip and name anything that moved. Never pass --apply."

In section 8, change the clause to: "Do not run graph ingest in the main tree or in a worktree without graph.db."

## [medium] Digest findings the plan neither implements nor explicitly defers or rejects
Each high or medium finding below has no work item, no deferral line and no rejection in the plan. I checked by id and by key terms: 0 hits for dir_routes, advisory, agent-offer, py-text-mode or newline=, audit-memory-backup or TC store, offer-open or cross-session, the footer position rule, and the registrar provenance case. A lower-effort build will silently drop all of them.

EVIDENCE: - digest-estate-machinery.md store-citation-blind-to-machinery [medium]: W0.1 lands only the resolver half. The commit-time MACHINERY ADVISORY is absent.
- digest-estate-machinery.md prose-only-helpers [medium]: only Add-TcLine and the Get-TcTreeFiles prune get a channel. 5 of 7 get none (issue 4).
- digest-tool-tier.md python-and-brain-code-uncovered [medium]: the brain row is taken (W4.5). py-text-mode-tracked-write and the graph bare-id cue (moved to the analysis side by its critique) are absent.
- digest-agent-tier.md agent-tier-never-points-at-estate [medium]: the brief-time 'existing estate machinery' block. The finding deferred it to the index that W3.2 now builds, and nothing then uses it.
- digest-agent-tier.md pointer-use-unmeasured [medium]: the per-pointer agent-hook offer log.
- digest-record-tier.md analysis-record-thin [high]: steps 1-3 are W5.6/W5.7. Step 4 (footer position rule, log-only first) and step 5 (the 'nothing relevant after an open' contradiction count) are absent.
- digest-bridge-and-routing.md reader-facing-and-analysis-unbridged [medium]: dir_routes for design/MEASURE|EVAL, probes and site/.
- digest-offline-loop.md no-estate-vocabulary-bridge [high, PLAUSIBLE]: W4.3 hosts Read and Edit only. The Bash/PowerShell host, a command that RUNS a cited script or harness (the analysis action), is absent.
- digest-memory-and-budget.md tc-store-audit-gap [medium]: no audit of the ThriftyCrew memory store.
- digest-memory-and-budget.md missed-by-mapper, 'split already produces wrong provenance' [medium]: W5.3 checks presence only, so grocery/triage-plans/registrar-2026-09-22.json:217, which cites a memo from the wrong store, would pass.
- digest-offline-loop.md course-routing-skips-rules [medium]: the Lands-in field.
- digest-prompt-tier.md offer-open-join-crosses-sessions [medium].
- digest-tool-tier.md miss-pipeline-noise-and-person-bound [medium].
- digest-prompt-tier.md prompt-tier-cannot-reach-subagents [high, OVERSTATED]: W1.1 probes SubagentStart, but plan line 300 names only W4.4, W5.7 and W6.1 as reading the probe's answers.
- digest-record-tier.md behaviour-files-unjudged [medium]: D11 recommends yes, but its 'optional W0.1 follow-on' has no steps.
- Low: critic.md:336 'The sleep pass commit. Do not commit without a pathspec' is missing from section 8. The new runtime outputs I checked are gitignored (git check-ignore rc 0), so the added risk is small.

FIX: Add a section 8b, 'Findings deliberately not in this plan', one line each, with the id and a disposition. Suggested dispositions:
- DEFER to W4.2's generated rows: store-citation-blind-to-machinery (the advisory as a WARN-only follow-on), prose-only-helpers, and py-text-mode-tracked-write (measure --rate on 16,000-char probes first).
- ADD to W4.3: a Bash/PowerShell host that routes the script a command runs (kind 'run', shadow, the same 28-of-40 bar counted separately), plus reader-facing dir_routes under the same shadow.
- ADD to W5.3: WARN (never refuse) when a knowledge_consulted memory entry resolves in neither store or in the other store than it names.
- ADD to W5.7: analysis-record-thin step 4 as log-only, recording footer position before any rule ships.
- DEFER, after W3.2 lands and with a 20-case bar mined first: agent-tier-never-points-at-estate.
- REJECT for now per critic C8 ('the measured gap is behaviour'): the SubagentStart primer. Record the W1.1 answer and this decision.
- NAME as not in scope: tc-store-audit-gap, pointer-use-unmeasured, course-routing-skips-rules, offer-open-join-crosses-sessions and miss-pipeline, each as open for a later plan.
- D11: give it a W0.1b item or mark it 'ruling only, no build'.
- Add to section 8: "Do not commit from the sleep pass without a pathspec."

## [low] W4.1 step 1, W5.3 step 1 and W3.2 kind=measurement (the analysis-record prefix lists)
Three different prefix lists define an 'analysis record': W4.1 and W5.3 use PLAN|MEASURE|EVAL|RCA|REVIEW|AUDIT, while W3.2 uses MEASURE|EVAL|TRIAL. design/ also holds analysis-shaped FINDING, FINDINGS, TRIAL and PROBE documents that none of the lists covers consistently. That breaks the plan's own 'one of everything' rule.

EVIDENCE: - Plan 671, 982, 582.
- Counted by name prefix under C:\Codex\ThriftyCrew\design: PLAN 63, MEASURE 27, EVAL 8, FINDING 4, FINDINGS 1, TRIAL 1, PROBE 1, RCA 1, REVIEW 1, AUDIT 1.

FIX: Define one constant in store_citation.py, `ANALYSIS_RECORD_PREFIXES = ('PLAN','MEASURE','EVAL','TRIAL','RCA','REVIEW','AUDIT','FINDING','FINDINGS','PROBE')`. W4.1's scope, W5.3's PLAN_RE and W3.2's kind=measurement all import or mirror it with a comment naming the source. W5.3 still runs the tree first and puts 'judged=N missing=0' in the commit message, so the wider list is green on day one.

