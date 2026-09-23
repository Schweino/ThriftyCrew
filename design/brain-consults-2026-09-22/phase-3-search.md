# Phase 3 - the search can answer

Part of `design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md`. Read its sections 4, 6 and 8, and your item's row in section 5, first. An evidence
id "x/y" resolves to `design/brain-review-2026-09-22/digest-x.md`, finding y.

## W3.1 Rules are chunked one bullet per chunk in the persisted index

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** S.

**Why.** The recall index stores ops-and-gates.md's 48 rules as ONE 68,054-byte chunk: 13 chunks for 99 bullets across
all six rules files. BM25 length-normalises that almost out of contention. (bridge-and-routing/rules-unchunked-and-unsearchable)

**Steps.**
1. In `recall_index.chunks_for`, add a `kind == "rules"` branch:
   - a chunk starts at each column-0 line matching `^- \*\*`;
   - its heading is the bold lead up to the closing `**`, at most 120 chars. 11 of 99 leads wrap a line, so read the
     lead across a line break;
   - indented sub-bullets stay with their parent;
   - `##` headings still start a chunk;
   - drop the front-matter chunk.
2. Reindex once (`recall-reindex.py`).

BM25 statistics are computed per corpus (recall_index.py:516-525), and the prompt and agent hooks query `['skills']` only.
So this changes no live offer. It serves `--estate`.

**Fixtures.**
- MUST FIRE: a 3-bullet rules file with one wrapped lead gives 3 chunks with full leads.
- MUST NOT FIRE: a skills file with bullets still chunks by heading only.
- CLEAN TWIN: the existing "a .claude/rules file is retrievable" case passes.

## W3.2 A generated index of the estate's own machinery

**Repo:** both. **Lands via:** the brain generator first (`~/.claude` commit); then the ThriftyCrew header seeds through
push-main. **Effort:** M. **Needs:** W2.1, W3.1, W5.3 step 1.

**Why.** No catalogue of estate functions exists; section 7 of automatic-recall.md records it as open. 102 of 102 lib
files already open with a purpose line, and 525 of 737 top-level functions carry a doc comment (a mapper count, not
re-measured), but nothing collects them. (estate-machinery/no-estate-machinery-index)

**Where it lives.** A generated, UNTRACKED cache: `~/.claude/cache/machinery/<project_key(checkout_root)>/MACHINERY.md`
plus `index.json` (env RECALL_MACHINERY_CACHE for the parent dir).
- `~/.claude/cache/` is gitignored, checked 2026-09-22.
- ThriftyCrew's `ops/out/` is NOT ignored, so never put it there.
- A tracked copy was rejected: volatile fields would make every push stale (critic C6).

**Generator.** New `~/.claude/skills/knowledge-search/machinery_index.py`, Python only.
- It walks with `git -C <root> ls-files`, so worktrees resolve their own files and nothing untracked is indexed.
- API: `ensure_current(root) -> path` rebuilds when the cache is missing, or when any indexed file's mtime is newer than
  recorded; about 2 s. Plus `--build <root>`, `--reflex-rows <root>` (used by W4.1) and `--selftest`.
- The nightly sleep pass calls `ensure_current` for the main checkout as a new step.
- No push gate.

**Population.**
- **kind=lib:** `lib/*.ps1`, `grocery/*-lib.ps1`, `meal-prep/lib/*.ps1`. Record the first non-empty line inside the
  header comment block (skip a bare `<#`), and every column-0 `function <Name>` with its first doc line. Indented
  functions, such as self-test helpers, are skipped by construction.
- **kind=py:** first-party `.py` modules imported by at least one other first-party file (regex over
  `^\s*(from|import)\s+`), with the module docstring's first line.
- **kind=gate:** each line starting `@{` inside the `$static = @(` and `$pyStatic = @(` blocks of `ops/run-gates.ps1`.
  - The path is `\bf\s*=\s*'([^']+)'`.
  - The purpose is `\bn\s*=\s*'((?:[^']|'')*)'`, with doubled `''` un-doubled.
  - `daily = $true` is recorded as `when: daily`.
  - The live run must index at least 50 gates, and prints the count.
- **kind=harness:** `ops|grocery|meal-prep/pipeline` `(probe|count|report|observe|measure|census)-*.ps1|py`.
- **kind=measurement:** dated `design/<PREFIX>-*.md` for `<PREFIX>` in `recall_core.ANALYSIS_RECORD_PREFIXES` minus
  PLAN (defined by W5.3 step 1, which lands first), with the title, the date, and the first line beginning Result,
  Verdict or Measured.

**Optional hand-authored header lines**, parsed when present:
- `# USE WHEN: <plain task words>`;
- `# REPLACES: <python regex> ;; <python regex>`;
- `# REPLACES-FIRE: <one literal line the pattern must match>`;
- `# REPLACES-SILENT: <one legitimate line it must not match>`;
- `# ENFORCED BY: <gate path> (push|daily|none)`.

**Header seeds** (a ThriftyCrew commit, authored by someone who READS each lib, never scraped):
- `lib/`: atomic-write, append-line, lf-write, tree-walk, git-repo-env, ledger-lock, ratchet, gate-slots, push-lock,
  guard-contract, selftest-lib, json-io, parallel-run, concurrency-probe, mutex-hold;
- `grocery/`: native-lib, global-exclude-lib, pricing-math-lib;
- `meal-prep/lib/`: render-tokens.

Rules for the seeds:
- Each REPLACES pattern must fire on its gate's own frozen MUST FIRE text, or on its REPLACES-FIRE line when ENFORCED BY
  is none. Compile it with Python `re`, because the consumers are Python and .NET regex differs on lookbehind and inline
  flags.
- The PROSE-ONLY helpers go first, because edit-time recognition is their only guard:
  - Enter-TcLedgerLock: `New-Object\s+System\.Threading\.Mutex` outside lib/;
  - Write-TcLfFile: `ConvertTo-Json` piped to `Set-Content` or `Out-File`;
  - Add-TcLine: `Add-Content` onto a `.jsonl` or `.log` path.
- **Before landing the seeds,** run `powershell -NoProfile -File ops\audit-conclusion-currency.ps1` in the worktree; a
  plain run writes nothing. A header-only edit changes the blob, and `grocery/pricing-math-lib.ps1` qualifies
  `design/MEASURE-sams-cents-unit-price-2026-09-20.md`, with the ratchet at unqualified=4 against baseline=4.
  - Every doc the edit leaves UNQUALIFIED gets, in the same commit:
    `Re-read at harness blob <git hash-object <path>, taken after the edit> (<path>): header comment lines only; <the conclusion> still holds`.
  - Never `-Accept` the rise.

**Output shape.**
- MACHINERY.md holds one `## <relpath> :: <purpose>` section per file, capped at about 1,500 tokens. Its body carries USE
  WHEN, REPLACES in words, enforced-by, and `- Name (params): doc` lines.
- index.json is `{schema:1, head, built_at, files:{rel: mtime}, entries:[...]}`.

**Fixtures** (`machinery_index.py --selftest`, temp git repo, per-run dir, eight git variables cleared):
- MUST FIRE: a new column-0 function appears after a rebuild.
- MUST FIRE: a lib with an unreadable header is listed as BLIND, not skipped silently.
- MUST FIRE: a `@{ daily = $true; f = 'x.ps1'; n = 'it''s' }` line is indexed as a gate with purpose `it's`.
- MUST NOT FIRE: a function inside `if ($SelfTest) {` is not indexed.
- MUST NOT FIRE: an untracked scratch `.ps1` is not indexed.
- CLEAN TWIN: an unchanged tree rebuilt with `--build` gives a byte-identical MACHINERY.md, and an index.json identical
  except `built_at`.
- CLEAN TWIN: `ensure_current` on an unchanged tree rewrites neither file (both mtimes unchanged).
- CLEAN TWIN: a worktree root resolves every lib.
- Per REPLACES line: its FIRE text matches, its SILENT text and the helper's own call do not.

**Bar (written now; scored after W3.3 lands, through `search.py --estate` with the MACHINERY (index) leg read alone).**
- Write the probe set BEFORE building: `~/.claude/skills/knowledge-search/machinery-probes.jsonl`, at least 12
  task-phrased queries, each taken from a real commit subject or brief that used the helper, never from its header, each
  with a `source` field.
- Bar: hit@3 of at least 9 of 12.
- The honest prototype figure is 5 of 7 (71%), which is below this bar. Record a miss as a miss, and never rewrite a
  probe after seeing its score.

## W3.3 `search.py --estate`: one definition

**Repo:** brain. **Lands via:** `~/.claude` commit. **Effort:** M. **Needs:** W3.1, W3.2, W1.6.

**Why.** The command every rule tells a session to run cannot see memory, rules or code. Re-running b453a01fb's own
"nothing applicable" query over the rules root finds the governing rule; over the skills root it finds nothing.
(record-tier/null-search-blind-to-estate)

**Definition.**
- `--estate` is a FLAG (`action="store_true"`) and never takes a value.
  - The checkout is the new option `--estate-root <path>`, else `checkout_root(cwd)`, else `RECALL_ESTATE_ROOT` (default
    `C:\Codex\ThriftyCrew`).
  - Never reuse `--root`: that is the skills root (search.py:1120).
- Legs, each under its own header, in this order:
  - **SKILLS:** the existing output, byte-identical.
  - **MEMORY:** the store of `canonical_root(checkout)` plus `store_citation.MEMORY_PROJECTS` (duplicated here, with a
    comment naming the source), de-duplicated. Each hit is tagged with its store.
  - **RULES:** the checkout's `.claude/rules`, one chunk per bullet (W3.1).
  - **MACHINERY (index):** W3.2's cache for the checkout, via `ensure_current`.
  - **MACHINERY (grep, unranked):** `git -C <checkout> grep -l -i -F --all-match -e <t1> -e <t2> ...` over tracked
    `*.ps1 *.py *.js`, at most 10 files. Never fused into any score: three score spaces share no scale.
- Memory, rules and machinery go through `recall_index`, the persisted corpus-tagged index, with an explicit roots list.
  Add `recall_index.ready_roots(roots)`. Do NOT build a third BM25 index.
- A leg that cannot look prints `ESTATE-LEG BLIND <leg> <why>`, and the other legs still print.
- The log row (W1.6) lists every returned key from every leg, prefixed by leg: `memory:<store>/<slug>`,
  `rules:<file>#<lead>`, `machinery:<relpath>`, `grep:<relpath>`. M3 is computed from these keys.
- The last line is `KNOWLEDGE-SEARCH-COMPLETE legs=<n> hits=<n> blind=<n>`.

**Fixtures** (search.py --selftest; temp roots; `RECALL_INDEX_DB` redirected, never the live index):
- CLEAN TWIN: `search.py --estate "path below root"` parses to query == ['path below root'] with estate_root None.
- MUST FIRE: `--estate "path below root"` returns a temp rules bullet holding that rule.
- MUST NOT FIRE: the same query without `--estate` does not return it, which proves the flag is the difference.
- MUST FIRE: the grep leg names a temp tracked `.ps1` containing `Get-TcPathBelowRoot`.
- MUST NOT FIRE: an untracked file with the same text is not named.
- CLEAN TWIN: default output over the existing fixture set is byte-identical.
- MUST FIRE: a worktree cwd returns a main-store memory hit.
- MUST FIRE: `--estate-root <temp brain repo>` from a ThriftyCrew cwd indexes the brain's modules, not ThriftyCrew's.

**Bar (written now).**
- Commit `~/.claude/skills/knowledge-search/estate-null-cases.jsonl` BEFORE the run. It holds the 16 landed commits of
  2026-09-18..22 whose Store: line says "nothing applicable": sha, quoted terms, the flags from each one's own search-log
  row, and `source`.
- Re-run each with `--estate`. If a named single reader judges that a relevant rules, memory or machinery section came
  back for at least 5 of 16, `--estate` becomes the recommended command (W3.4).
- Otherwise record the result in automatic-recall.md s7, and keep it opt-in everywhere except W4.2 (see W4.2 step 6).

## W3.4 Add `--estate` to every carrier, in one sweep

**Repo:** both. **Lands via:** one ThriftyCrew push-main commit (store-step.md, the agents, their mirrors, the CLAUDE.md
line, store_citation's text); one `~/.claude` commit (the brief gate, knowledge-search SKILL.md); the scheduled task by
procedure P3. **Effort:** S. **Needs:** W3.3's bar held, W5.2 landed.

W5.2 has already moved every carrier to the Bash-safe section 4.7 string without `--estate`. This item adds only
`--estate`, everywhere at once:
- **`ops/agent-blocks/store-step.md`, BOTH variants,** in the SAME ThriftyCrew commit as:
  - every agent that carries a variant (10 after W5.2);
  - their `ops/prompt-backup/agents/` mirrors, refreshed with `ops\audit-prompt-backup.ps1 -SyncMirror` in the worktree.
  Before committing, run `powershell -NoProfile -File ops\audit-agent-tools.ps1` and `ops\audit-prompt-backup.ps1`, and
  read exit 0 and each one's COMPLETE line.
- The brief gate's HOW text.
- store_citation's refusal text.
- `scheduled-tasks/grocery-alert-triage/SKILL.md` line 17 (the command), through procedure P3.
- `knowledge-search/SKILL.md`: its "Deduplicating" step 3 becomes "`--estate` first, grep second".
- One line in ThriftyCrew CLAUDE.md's Orientation: "Before writing a file write, walk, lock, native call or
  helper-shaped function, run `C:/Codex/Python312/python.exe C:/Users/Owner/.claude/skills/knowledge-search/search.py
  --estate "<3-6 words>"`."

**Trap.** Never paste "run search.py" into an agent without Bash (recipe-dedup-selector, recipe-writer); see W5.2.
