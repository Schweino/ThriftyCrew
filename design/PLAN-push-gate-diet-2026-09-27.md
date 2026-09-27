# PLAN: push gate diet (2026-09-27)

Status: D1-D5 RULED 2026-09-27 (see Brad's rulings below). W1 (M1, D1) built; M3 built (bar 2 still missed, see
"M3 as built"); M2 and M4 withdrawn; W0 open.

Goal: cut what every push costs in `ops/run-gates.ps1` without losing protection. Moving a gate to a
different tier is a design decision for Brad, and every tier still runs the gate: nothing here removes a
gate or a case.

## Knowledge consulted

- Searched the store for "gate runtime tiers nightly push cost" (knowledge-search --estate): nothing applicable.
- `.claude/rules/ops-and-gates.md` og-45: a keyed self-test still re-runs every push when its key is too wide;
  a file only parsed goes on `# gate-inputs-text:`; check a key's file list, run `-VerifyDeclared` after a change.
- `.claude/rules/measurement.md`: the acceptance bar is written before the run in the metric's units; every rate
  carries its denominator; one row per case per arm.
- Memory `rerun-gates-after-a-spawned-build`: exit code before the tally.
- Searched "gate input key static detector push cost" (knowledge-search --estate, 32 hits). Used:
  `software-craft/applies-here.md` #49 "Name the checking point": run-gates is the link-time point, the daily chain
  run time; every tier move below names which point a check moves to and why (M2, M5).
  Memory `flat-scaling-curve-is-not-saturation`: a flat wall curve is a barrier, not a full box; so wall is
  estimated from the longest single gate on the critical path, not from total CPU divided by width.
  `data-quality-craft/checks-and-thresholds.md` 5c: compare hash SETS by key; M1 keys on the per-path blob set
  of the scan glob, never on a count of files.

## What was measured

**Harness.** `ops/run-gates.ps1` already writes one row per job per run to
`%LOCALAPPDATA%\ThriftyCrew\gate-times\gate-times-<date>.jsonl` (fields `gate, arg, state, ms, rc, why`; state
is `reused`, `ran` or `unkeyable`). I aggregated those rows with a scratch script (not committed, described
here): median of `ms` over runs where the gate executed, and the state counts. Harness blob at measurement:
`ops/run-gates.ps1` as of origin/main `f56c713d9`; cite the blob (`git rev-parse <landed>:ops/run-gates.ps1`),
not that hash, if this is re-read after a rebase.

**Coverage.** 3 files (2026-09-25 to 2026-09-27), 45,592 rows, 86 runs, all 86 full (513 to 539 jobs). 66 of
the 86 are "warm era" runs (35 to 41 unkeyable jobs), after the key extension that took unkeyable from about
280 to about 35 on 2026-09-26. The 20 earlier runs are kept in the TSV but excluded from the per-push figures.

**Per push, warm era, 66 runs:**

| Quantity | Median | Range |
|---|---|---|
| Jobs executed (not reused) | 112.5 of about 530 | 103 to 539 |
| Gate CPU executed | 1,533 s | 1,168 to 4,638 s |
| Wall (from the brief, 2 push-main runs today, width 19 to 24) | 394 to 425 s | not in the rows |

**98 gates executed in all 66 warm runs.** They are the whole problem, and they come in two classes:

| Class | Gates | Sum of medians | Why they always run |
|---|---|---|---|
| Static detectors (`$staticJobs`) | 60 | 827 s | **Never keyed at all.** The keying loop (`run-gates.ps1` about line 776) walks only self-tests and Python suites; static jobs never reach `Get-TcGateInputKey`. |
| Unkeyable self-tests | 38 | 397 s | `Get-TcGateInputKey` refuses the key; the `why` column says which road (a repo path built from a variable, a read of a data directory, a Python suite with no declaration). |

The other ~430 gates are keyed narrowly enough that they are reused on a typical push (for example
`ops\push-main.ps1 -SelfTest`, 338 s when it runs, reused 76 of 86).

**Startup, corrected.** The brief's 102 s of process startup is about 539 spawns at ~0.19 s. A reused gate
spawns nothing (run-gates filters `$cacheHit` before dispatch, about line 829), so a warm push spawns about 113
processes: ~113 x 0.209 s (the PS 5.1 spawn figure in run-gates' own header) = **about 24 s of CPU, under 2 s
of wall at width 19 to 24.** Startup is not where the time is.

**How often a push changes code.** Of 938 commits on origin/main since 2026-09-13 (about 67 a day), 491 touch
a `.ps1`, 70 a `.py`, 536 any code file, and **402 (43%) touch no code at all** (boards, ledgers, stamps).
A static detector that reads only source has nothing new to read on those 402.

**What each gate has caught.** The TSV column `real_red_candidate_mentions_unverified` counts commit messages
(origin/main since 2026-08-11) and `grocery/triage-plans/*` that name the gate within 160 characters of a red
word (red, refused, caught, failed, flagged) and not a fixture word. **It is a candidate list, not a catch
count**: 366 of 539 gates have at least one mention, and a hand-check of four shows the noise (for
`audit-list-array-wrap` the only hit, 4ad20f97e, is its own founding commit repairing four latent sites, which
is a catch at introduction, not on a push). Verifying it is W0 below and is owed before D3 is ruled.

## Acceptance bar (written before any change)

Measured from the gate-times rows, over at least 20 warm pushes after each move, one row per gate per run:

1. **Code-touching push: executed gate CPU median at most 800 s** (from 1,533 s), and **wall at most 240 s** at
   width 19 to 24 (from 394 to 425 s).
2. **Data-only push: executed gate CPU median at most 150 s.**
3. **Protection held, both halves:** every gate still runs on some tier on every commit that reaches main
   (nightly covers what a push tier skipped, at the landed tip), and each moved gate's case NAMES are unchanged
   (`--names-diff` style, not counts). A mutant of each moved detector's founding bug still reds a push that
   touches its inputs.

A move that misses its own estimate below by more than half is reported as missed, with the rows.

## Moves

### M1. Key the static detectors on their scan set (extends gate-input-key; no new mechanism)

A static detector reads source, not data. Give each one a declaration its key can hash:
`# gate-scan: <glob>` (for example `**/*.ps1`), and have `Get-TcGateInputKey` hash the blob ids of the matching
TRACKED files (`git ls-files -s`, which the index already holds, so no file is read) plus the detector's own
walk as today. Then route `$staticJobs` through the same keying loop as self-tests.

- Saving: 827 s on every data-only push (43%) and on any code push that touches no file in the scan set.
  Expected mean about 360 s CPU per push from this alone.
- Risk: LOW-MEDIUM. A glob narrower than the detector's real walk makes it skip a push it should see. Guard:
  `-VerifyDeclared` extended to compare the declared glob against the files the detector actually opened on a
  traced run, and a MUST FIRE case that edits one in-scope file and expects a re-run.
- Reversible: delete the declarations; the loop falls back to run-every-push.

### M2. Diff-scoped mode for the three heaviest static detectors

`test-native-stderr-eap` (199 s), `audit-list-array-wrap` (85 s) and `audit-literal-newline-escape` (39 s) scan
every script for a shape. run-gates' own comment (about line 492) says the value of test-native-stderr-eap on a
push is catching the new site IN THIS DIFF. Add `-Paths <changed files>` so the push tier scans the diff against
origin/main, and the nightly tier scans the whole tree.

- Saving: about 300 s on every code push (a diff is usually a handful of files).
- Risk: MEDIUM. A defect created by a change to a file the diff does not touch (a library a caller relies on)
  is found nightly, not at push. The nightly red lands on main already, so it is a day's exposure, not a loss.
- This is a tier decision: **D2**.

### M3. Make the 38 unkeyable self-tests keyable (extends gate-input-key)

Work the `unkeyable_why` column top down. The first three are 212 s of the 397: `rehearse-chain` (105 s) and
`prepush-test-auditors` (64 s) build a repo path from a variable, `wave-preaudit` (43 s) joins a nested
expression. Each gets explicit `# gate-inputs:` / `# gate-inputs-text:` lines (og-45) instead of a new
inference rule; the Python suites with no declaration get one.

- Saving: up to 397 s CPU on pushes that do not touch their inputs; about 250 s realistic.
- Risk: LOW. A missed input is the og-45 failure in reverse (key too narrow). Guard: `-VerifyDeclared` per
  declaration, and the rehearse-chain key must include the chain step list.

### M4. Batch the cheap always-run gates into fewer processes

66 of the 98 always-run gates take under 10 s each (181 s together). Batching them 10 to a process saves about
60 spawns x 0.209 s = **about 13 s of CPU and well under 1 s of wall per push.** After M1 most of the 66 stop
running on a typical push anyway. Batching also costs isolation: one self-test that leaks state or calls `exit`
takes its batch-mates with it, which the og-29/og-30 verdict rules exist to catch.

- Recommendation: **do not do this now.** Revisit only if, after M1 to M3, spawn cost exceeds 10% of executed
  CPU. **D4.**

### M5. Nightly tier for high-cost gates with no candidate catch

Only two always-run gates over 20 s have zero candidate mentions: `audit-literal-newline-escape` (39 s) and
`audit-capture-ingest-reporting` (25.5 s). Zero mentions in a noisy search is weak evidence either way; W0 must
confirm before this is even proposed. **D3.**

## Estimated effect (against the bar)

| After | Code push CPU | Data-only push CPU |
|---|---|---|
| Today | about 1,533 s | about 1,533 s |
| M1 | about 1,300 s (some code pushes skip some scan sets) | about 300 s |
| M1 + M3 | about 1,050 s | about 100 s |
| M1 + M2 + M3 | about 750 s (meets bar 1) | about 100 s (meets bar 2) |

These are estimates from medians and the 43% data-only share, not measurements. Wall scales roughly with the
longest single gate once the rest run in parallel, so M2 (removing the 199 s gate from the critical path) is
what moves wall most.

## Work order

- **W0** Verify the candidate column for the top 20 always-run gates by reading each cited commit; record
  `caught_real`, `introduced_with_fix`, or `fixture` per row in the TSV. (No gate change.)
- **W1** M1 behind D1. **W2** M3 (needs no ruling; it only narrows keys under existing rules, but it goes after
  W1 so each move is measured alone). **W3** M2 behind D2. **W4** re-measure 20 warm pushes against the bar.
- Each W lands through `ops\push-main.ps1`, one move per push, so the gate-times rows separate the arms.

## Decisions for Brad

- **D1.** May static detectors be keyed on a declared scan set (M1), with `-VerifyDeclared` checking the glob
  against a traced run? Recommended: yes.
- **D2.** Push tier for the three heaviest static detectors: diff-scoped at push, whole tree nightly (M2)?
  Recommended: yes for `test-native-stderr-eap` and `audit-list-array-wrap`; the third after W0.
- **D3.** Any gate to a nightly-only tier (M5)? Recommended: no ruling until W0 has verified what each has
  caught.
- **D4.** Batching cheap self-tests into shared processes (M4)? Recommended: no, the saving is about 13 s CPU.
- **D5.** Is the bar right: code push at most 800 s CPU and 240 s wall, data-only at most 150 s CPU?

### Brad's rulings (2026-09-27)

- **D1 YES.** The static detectors run by `ops/run-gates.ps1` get an input key: the tracked files they scan (by their
  own globs), their own script, and the libraries they load. When none of those changed since a recorded pass, the pass
  is reused exactly as self-tests' are, so a data-only push skips them. A push that changes any scanned file runs the
  detector over the WHOLE tree, as today. A detector whose scanned set cannot be declared stays unkeyed and runs every push.
- **D2 NO.** No changed-files-only scanning and no nightly tier. Brad: full scans are safer and leave less for the
  triage agent. M2 is withdrawn.
- **D3 not yet.** No gate moves to a nightly-only tier (M5 stays unproposed; W0 still owed before it is asked again).
- **D4 NO.** No batching of cheap self-tests into shared processes (M4 withdrawn).
- **D5 accepted.** The bar stands for data-only pushes: at most 150 s gate CPU. A code push is to be unchanged by the
  D1 work (a code push touching a scan set runs every keyed detector as before).

### W1 as built (D1)

`scan = <git pathspecs>` on each `$static` entry in `ops/run-gates.ps1`; `Get-TcGateScanRows` in
`lib/gate-input-key.ps1` lists the set (index blob ids, working-tree bytes of modified files, and every untracked file
under the specs), and `Get-TcGateInputKey -ScanRows` adds them to the detector's ordinary key (own bytes, loaded
libraries, named literals, runner). A pass is recorded only for exit 0 with no `blind=` and no zero-population marker.
33 of the 61 push-time static entries declare a set: 32 on code (`*.ps1 *.psm1 *.psd1 *.py *.sh ops/hooks/*`, three
of them also `*.js *.yml *.yaml *.vbs *.bat *.cmd`; `audit-forbidden-prose`'s recipe specs reach its key through its
own `# gate-inputs:` line) and `audit-lesson-rate-claims` on `content/*.md`. The other 28 run every push; the
gate-times `why` column names each.

### M3 as built

Measured before M3 (the D1 agent's run C, one run, one worktree, exit 0): a data-only push ran **748 s** of gate CPU:
586 s of refused self-tests and Python suites, 128 s of unkeyed static detectors, 34 s of three keyed static detectors
that re-ran anyway.

**What changed** (`lib/gate-input-key.ps1`, `ops/run-gates.ps1`, and declaration lines in ten suites):

1. **`# gate-scan: <git pathspecs>` in a suite's own source.** run-gates hands D1's scan rows to the key for a self-test
   or Python suite exactly as for a static entry (`Get-TcGateOwnScanRows`). `ops/rehearse-chain.ps1` (115 s) reads the
   chain manifest set at HEAD, its dot-source closure and the whole `lib\`, so it declares `*.ps1 *.psm1
   ops/chain-manifest.json ops/hooks/*`, which also covers the brief's "key must include the chain step list".
2. **Why the three keyed detectors re-ran.** Each names `*.ps1` beside itself, and the key walked INTO every listed
   script, inheriting its data literals and its own self-test's declared inputs: 1,777 files (1,218 of them data such
   as `meal-prep\db`, `content\ghost-adopted`, bot logs) for `audit-json-readers` and `audit-store-registry -CodeOnly`,
   2,053 files with 33 gitignored boards for `audit-guard-contract`. Any bot data commit moved all three keys. Under a
   scan set, a listed file the set already hashes is now text (hashed, not walked); one the gate or its walk LOADS is
   still walked. Keys now: 343, 399 and 9 files. The load check reads each file's loaded leaf names once
   (`Get-TcGateLoadedLeafSet`), because with hundreds of text inputs the per-leaf regex took 69 s for one key (now 1.2 s).
3. **Declarations on nine suites** whose `-SelfTest` reads only code and %TEMP% fixtures. `-VerifyDeclared`: 9 of 9.
   `ops/verify-gate-declaration.ps1` (sandbox vs real arm) first REFUSED `audit-db-agreement` (its held-state library
   loads `lib\json-io.ps1` through a variable), which was then declared and verified; review-staged and
   apply-coverage-batch cannot run in its git-less sandbox, the same limit D1 recorded for gate-input-key itself.

**Suites newly keyed: 10 of the 45 refused on the pre-M3 cheapest run** (rehearse-chain, review-staged, check-ad-cycles,
apply-coverage-batch, build-live-price-script, verify-gate-declaration, audit-db-agreement, audit-category-coverage,
sidecar-watchdog, gen-planner-data). run-gates' own count of unkeyable self-tests: 34 before, 23 after (run A).

**Left unkeyed, with the reason** (each read from its source; the classification was delegated and spot-checked):

| Suite | Why it stays unkeyed |
|---|---|
| `ops\prepush-test-auditors.ps1` (65 s) | runs `git ls-files` over the whole checkout for its live cases; only a whole-tree scan covers it, which gains nothing |
| `meal-prep\pipeline\wave-preaudit.ps1` (40 s) | reads a gitignored built card (`db\built\...body.html`) |
| `ops\audit-memory-backup.ps1` (30 s) | a real network probe (github.com) changes its output |
| `ops\audit-secrets.ps1 -SelfTest` (21 s) | `git grep` over every tracked file; narrowing that case to one file would make it declarable |
| `grocery\audit-sale-fallback.ps1`, `audit-store-registry.ps1 -SelfTest` | data reads run above the self-test block (newest board, `out\regular`) |
| `grocery\test-flag-verification.ps1`, `pull-regular-bakers-api.ps1`, `pull-regular-familyfare.ps1`, `commit-capture-cursor.ps1` | `Get-CapturePlan` with no `-OutDir` reads gitignored `sale-windows.json` and `out\sale-fallback-*` |
| `grocery\validate-triage-plan.ps1` | its child runs read gitignored `out\archive` and the clock |
| `grocery\audit-guard-contract.ps1 -SelfTest` | walks the whole tree including ignored files |
| `grocery\send-friday-email.ps1`, `send-price-alerts.ps1` | `git check-ignore` reads `.git\info\exclude` and the home directory's global excludes |
| `grocery\audit-ghost-drift.ps1` | compares the working tree with HEAD |
| `meal-prep\pipeline\monitor-live-recipe-prices.ps1`, `feed-covers-published.ps1` | read gitignored built cards |
| `ops\audit-rule-currency.ps1` | declarable (tracked reads only) but not done in this pass |
| `grocery\compare-deals.ps1` | not finished: about ten libraries and a list of files read from its own text |
| Python: `harvest.py`, `decide_apply.py`, `extract_sweep.py` | live `considered-dishes.json`, catalog digest, candidate pool, `hunt-run.ps1` |
| Python: `priors_ablation.py`, `scorecard_query.py` | the live `graph.db` |
| Python: `fdc_lookup.py` | branches on a gitignored API key file; pinning it in the self-test would make it declarable |
| Python: `local_extract.py`, `dedup_paired_run.py` | declarable, but the delegated import lists missed modules (`harvest_embed` -> `sidecar\lib_match.py`, `score_cache.py`), so not declared until traced |

`check-ad-cycles` keys but still re-runs on data: its key walks the ~150 audits the LIVE path runs, and the key cannot
separate that from the self-test path.

**Measurement** (same shape as D1's: run A records, run B same content, run C one tracked `.json` edited, one worktree):
one row per gate per run from the gate-times harness (`ops/run-gates.ps1` writes them; totals derived from the rows),
all in one worktree on 2026-09-27, content = the M3 commits.

| Run | Exit | Jobs executed of 540 | Gate CPU executed |
|---|---|---|---|
| A (records; after the fixture-label fix) | 0, pass=541 fail=0 | 540 | 3,789 s |
| B (same content) | 0, pass=541 fail=0 | 74 | 497 s |
| C (`grocery\notify-known-ids.json` edited, then restored) | 0, pass=541 fail=0 | 71 | **484 s** |

**Bar 2 (data-only push at most 150 s): MISSED.** Run C is 484 s against 748 s before M3: 264 s lower, over ONE run per
arm, one variant tried. That is one case, not a median over 20 pushes, so it is a direction, not a rate. Run C splits as
306 s in 59 unkeyed jobs and 179 s in 12 keyed jobs that re-ran on identical content.

**Why the 12 keyed jobs re-run, measured:** `ops\test-prepush-hook.ps1` (129 s) and `grocery\capture-watchdog.ps1` (17 s)
hash `ops\out\gate-verdict.json` and `ops\out\gate-readings.jsonl`, which run-gates itself rewrites on every run, so each
run invalidates the next. A `# gate-output:` on run-gates was tried and reverted: the log's reader
(`ops\report-ratchet-trends.ps1`) is in the same walks and really reads it, and `lib\gate-verdict.ps1` names
`Read-TcGateVerdict`, so the rule correctly keeps both. Separating them needs the suites to stop walking run-gates' live
path, which is design work, not a declaration.

**What stands between run C and the bar, largest first:** test-prepush-hook's self-invalidating key (129 s),
prepush-test-auditors (47 s, whole-tree `ls-files`), the 28 undeclared static detectors (about 110 s, largest
`audit-conclusion-currency` 22 s and `audit-secrets` 18 s, which read git history or the whole tree), audit-memory-backup's
network probe (22 s), audit-secrets -SelfTest (19 s). Even with every declarable item done, the unkeyable-by-nature set
(network, history, gitignored data) is roughly 150 to 200 s on its own, so the bar is likely unreachable without D3's
tier question or narrowing those suites' live cases.

## Round 3 (Brad, 2026-09-27: items 1 and 2, then re-measure; the 150 s bar stands; D2 no, D3 wait, D4 no)

### Round 3 design, item 1: a runner's own output is keyed by who last wrote it

**The defect, measured in this worktree before any change.** With `ops\out\gate-verdict.json` and
`ops\out\gate-readings.jsonl` absent, `Get-TcGateInputKey` for `ops\test-prepush-hook.ps1 -SelfTest` holds 787 files
and neither output (each is a `cand ... absent` row); with both present it holds 789, both outputs included, and
`grocery\capture-watchdog.ps1 -SelfTest` goes from 119 to 120 (the readings file). They get in because the walk reaches
files that NAME them: `ops\run-gates.ps1` (the writer), `lib\gate-verdict.ps1`, `ops\report-ratchet-trends.ps1` (a
reader: its live default `out\gate-readings.jsonl`) and `ops\observe-gate-queue.ps1` (a reader of every checkout's
file). run-gates rewrites both files at the end of every run, so every run changes the next run's key.

**Why the suites' verdicts do not depend on those bytes.** test-prepush-hook drives the hook in a sandbox repo with a
stub `ops\run-gates.ps1` written into it (its line ~375) and copies `lib\*.ps1` there, so every path it resolves is
under the sandbox root. capture-watchdog reaches `report-ratchet-trends.ps1` only in its live section 5a3a3, which its
`-SelfTest` does not run. So the key is wide, not wrong, and the og-45 remedies do not fit: `# gate-output:` was tried
and correctly refused, because real readers of the file are in the same walk.

**Options considered.**
- (a) Make the suites stop walking run-gates' live path. Each suite would need its declaration narrowed below code it
  really loads (test-prepush-hook declares `lib\*.ps1` on purpose, and `lib\gate-verdict.ps1` is one of them), which is
  the unsafe direction.
- (b) Drop a runner's own outputs from every key. Unsafe: a person editing the file by hand would then replay a pass
  over content no gate saw.
- (c) **Chosen: key a runner's own output by WHO LAST WROTE IT.** run-gates declares the files it writes with a new
  line `# gate-runner-output: <path>`. Right after each write, run-gates records the file's SHA-256 in a stamp under
  its gate cache directory (the common git directory's `tc-gate-inputs`, outside the tree, so no walked file names it).
  When a key's walk reaches a declared runner output, the row is `runnerout <path> as-written` if the file is absent or
  its bytes equal the stamp, and `ref <path> <sha256>` (today's row) otherwise. So run-gates rewriting its own file
  moves no key, and a person's edit (or anything else's write) moves every key that reaches it exactly as today.
  Absent counts as as-written because a fresh checkout is a state only the runner ever leaves; a key reached while the
  stamp is missing or unreadable falls back to the real SHA, the conservative direction.

**Fixtures** (in `lib\gate-input-key.ps1`'s self-test, which already builds temp repos):
- MUST FIRE: a person edits a declared runner output after the runner stamped it, and the key moves.
- MUST NOT FIRE: the runner rewrites its output with new bytes and re-stamps, and the key does not move.
- CLEAN TWIN: a file the runner does NOT declare, rewritten the same way, still moves the key (the exemption is by
  declaration only), and a missing stamp falls back to the real SHA (the key moves on a rewrite).

**Cost:** one SHA-256 of two small files per stamp write and per key that reaches them; no new process, no new gate.

### Round 3 as built

**Item 1** built as designed (`lib/gate-input-key.ps1`: `Get-TcGateRunnerOutputs`, `Save-TcGateRunnerOutputStamp`,
`Get-TcGateRunnerOutputStates`, `-RunnerOutputs` on `Get-TcGateInputKey`; `ops/run-gates.ps1` declares its two outputs and
stamps each after writing). Self-test 115 -> 123 cases, exit 0, with the fixtures listed in the design.

**Item 2: 11 of 13 static detectors keyed** (scan sets read from each detector's live path by a read-only helper and
spot-checked; every pathspec matches 1 to 587 tracked files): audit-json-encoding, audit-fact-claims,
audit-ingredient-routes, audit-category-coverage, audit-instore-shutout, audit-ruling-drift, audit-backlog-status,
audit-threshold-register, golden-test, audit-phantom-paths, audit-rule-format. Left unkeyed: audit-rule-currency (its
file set is chosen by the rules files' `paths:` entries through `git ls-files`) and audit-secrets (reads
`git log origin/main..HEAD`). fdc_lookup.py NOT changed: its self-test branches on a gitignored API-key file; the
helper's proposed fix (clear `FDC_API_KEY`, point `FDC_KEY_FILE` at a missing temp path, run the no-key case always,
restore in `finally`, then declare `# gate-scan:`) is open. Two notes kept beside the sets in run-gates: a new
ruling-registry row naming a non-code file must join audit-ruling-drift's set, and a channel tag naming a non-code gate
must join audit-rule-format's. golden-test writes two tracked files on failure (an og-39 matter, not fixed here). The
pathspecs tripped audit-cross-module-reach (118 -> 127); each line carries a `reach-fixture-ok:` reason (they are names
hashed from the index, never opened), back to 118.

**Measurement** (same shape as D1 and M3; harness: the gate-times rows `ops/run-gates.ps1` writes, totals derived from
the rows; one worktree, 2026-09-27; before B and C the whole-run verdict file was deleted so per-gate reuse is what is
measured, which is also the absent state item 1 keys as as-written):

| Run | Exit | Jobs executed of 540 | Gate CPU executed |
|---|---|---|---|
| A (records) | 0, pass=541 fail=0 | 540 | 4,188 s |
| B (same content) | 0, pass=541 fail=0 | 62 | 425 s |
| C (`grocery\notify-known-ids.json` edited, then restored) | 0, pass=541 fail=0 | 58 | **292 s** |

**Bar 2 (data-only push at most 150 s): MISSED.** Run C is 292 s against 484 s after M3 and 748 s after D1: ONE run per
arm, one variant tried, so it is a direction and not a median. Split: 257 s in 49 unkeyable jobs, 36 s in 9 keyed jobs
that correctly re-ran (audit-json-encoding scans `grocery/*.json`, the edited file; check-ad-cycles 14 s re-runs on data
as M3 recorded). test-prepush-hook was REUSED in C after B had rewritten both runner outputs, and capture-watchdog was
reused in B and C, so the self-invalidation is gone. test-prepush-hook did re-run in B (133 s); the only files run A
wrote were the two declared outputs, so the likeliest cause is that A recorded no pass for it (4 gates reported BLIND
cases in A). Not verified; open.

**What stands between run C and the bar**, largest first: prepush-test-auditors 45 s (whole-tree `ls-files`),
audit-conclusion-currency 22 s and audit-secrets (static 20 s, self-test 19 s) (git history), audit-memory-backup 19 s
(network), decide_apply.py 15 s, audit-sale-fallback 12 s, audit-source-comment-strip 12 s. These are unkeyable by
nature, so without D3 the bar stays out of reach; the remaining keyable items are fdc_lookup and rule-currency, a few
seconds each.

## Round 4 as built (Brad's D3 ruling, 2026-09-27)

**D3, ruled 2026-09-27: MOVE NO CHECK TO NIGHTLY.** Key the always-run checks so they skip data-only pushes and still
run in full on code pushes; a check that cannot stop reading live data stays on push and is listed for Brad.
audit-secrets' static run stays on push, unkeyed. Evidence: `design/W0-gate-catches-2026-09-27.md`.

**Round 4's keying is NOT landed.** It is on branch `gate-diet-round4` (19 of the 49 run-C jobs keyed, every
declaration VERIFIED; its own "Round 4 as built" account is on that branch). Brad's land rule after round 4: land it
only if run C, with the safety fix below, is at or below round 3's 292 s. It was not (538.5 s), so only the safety fix
lands, and Brad has paused further push-diet work. Unlanded, and not to be narrowed now: the wide keys of
test-prepush-hook, prepush-test-auditors, test-flag-verification, audit-guard-contract and check-ad-cycles.

**The safety fix, landed** (`lib/gate-input-key.ps1`, `Get-TcGateUnpinnedBase`, Brad's ruling). Found in round 4:
monitor-live-recipe-prices read a built card through `Join-Path $mp ...`, and the key silently dropped any path built on
a variable outside `$repo`, `$root`, `$RepoRoot`, `$here` and `$PSScriptRoot`. Now such a base must be PINNED as a sandbox
(every assignment is a temp folder, or a Join-Path/Split-Path on a pinned variable), or the key is refused and the
suite runs. Scope: the inference road (gates and libraries that declare nothing); a `# gate-inputs:` declaration still
answers for what its gate reads. Fixtures (self-test 123 -> 126 cases, exit 0): MUST FIRE a read via `Join-Path $mp`
is refused a key; MUST NOT FIRE a read via `$repo` still keys; CLEAN TWIN a temp-pinned sandbox variable is unchanged.

**Gates at risk, newly refused: 76 of the 397 self-tests keyed on origin/main** (448 tracked). Each was being skipped
on a matching key while reading through a base the key could not see. Many read real repo data this way (`$mp`,
`$__jioroot`: the meal-prep pipeline); others are libraries whose base is a function parameter, which cannot be pinned
by construction and so now always run. The list: graph\pipeline\scorecard.ps1; grocery: audit-json-encoding,
browser-feeds-lib, feed-served-lib, merge-product-urls, provenance-contract-lib, refresh-sams-verified,
regular-fileset-lib, rollback-ttl-lib; lib: atomic-write, bot-paths, gate-verdict, git-blob-lib, main-checkout;
meal-prep\archive\retired-by-templating\repair-unreachable-prose-money; meal-prep\pipeline: annotate-writer-note,
audit-buy-label-plurals, audit-cost-line-coverage, audit-cost-plausibility, audit-fact-claims, audit-ghost-field-limits,
audit-ingredient-identity, audit-live-price-contract, audit-vocab-integrity, audit-wave-blocker-headings,
build-intake-skeleton, build-v2-spec, compute-v2-perserving, considered-dishes, db-build, feed-freshness, fetch-recipe,
ingredient-resolutions, ingredient-vocab, migrate-prose-tokens, nutrient-claim-lib, rebase-spec-ingredient,
recost-spec-cost-block, repair-absurd-units, repair-basis-relabel, repair-bulk-buy-line, repair-cook-measures,
repair-head-ingredients, repair-measure-vs-grams, repair-plural-unit, repair-range-buy, repair-scaled-notes,
repair-spec-contradictions, repair-to-taste-labels, repair-unitless-buy, repair-unmeasurable-qty, retire-recipe,
retrofit-source-credit, source-domains, stamp-live-price-fallback, sync-prose-from-spec, sync-recipesdb-buy,
sync-recipesdb-cost, sync-recipesdb-macros; ops: add-reread, audit-cpu-load, audit-fixed-temp-names,
audit-readjson-inline-wrap, audit-ruling-drift, audit-selftest-fallthrough, audit-typed-param-shadow, audit-write-seam,
count-tracked-writers, drill-push-main-runner, hold-push-lock, observe-gate-queue, probe-gate-slot-fairness,
verify-bot-commit-scope, verify-commodities-gate; sidecar: start-sidecar, stop-sidecar.

**Measurement** (harness: the gate-times rows `ops/run-gates.ps1` writes; one seeded worktree, 2026-09-27, the safety
fix plus round 4; whole-run verdict file deleted first; ONE run per arm):

| Run | Exit | Jobs executed of 540 | Gate CPU executed | unkeyable | keyed that re-ran |
|---|---|---|---|---|---|
| A (records) | 0, pass=541 fail=0 | 540 | 3,759 s | 100 jobs | - |
| C (`grocery\notify-known-ids.json` edited, restored) | 0, pass=541 fail=0 | 117 | **538.5 s** | 100 jobs, 330.8 s | 207.7 s |

Against the 292 s land bar: over by 246.5 s. Round 4 alone measured 332 s. The safety fix's cost on a data-only push is
therefore about 205 s of now-unkeyable jobs, the price of never replaying a pass over a read the key cannot see.
The safety-fix-only tree was not measured separately.
## Open items

- W0 (the catch column is unverified).
- Wall per run is not in the gate-times rows; the bar's wall half needs the push-main row, not these files.
