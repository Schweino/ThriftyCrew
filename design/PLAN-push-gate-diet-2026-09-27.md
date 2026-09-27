# PLAN: push gate diet (2026-09-27)

Status: D1-D5 RULED 2026-09-27 (see Brad's rulings below). W1 (M1, D1) built; M2 and M4 withdrawn; M3 and W0 open.

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

## Open items

- W0 (the catch column is unverified).
- Wall per run is not in the gate-times rows; the bar's wall half needs the push-main row, not these files.
