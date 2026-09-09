---
description: Rules for gate, audit and shared-library code - exit codes, the guard contract, must-fire discipline.
globs: "ops/**, lib/**"
alwaysApply: false
---

> **Resolving the `[[citations]]` below.** Each is a filename without its extension, under
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/`. So `[[propagate-has-no-slugs]]` is
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/propagate-has-no-slugs.md`. The line here is a
> pointer; the file is the account. Read it before acting on the pointer, and never write to that
> directory - it is outside the repo and outside your worktree.


# Working in `ops/` or `lib/`

Loaded only when you touch a gate, an audit or a shared library. This is the machinery that keeps
everything else honest, so a defect here is silent by construction.

- **Read the EXIT CODE first and the tally second**, and do not decode the number: three vocabularies
  are live at once and the same `2` means "hard defect" in the guard-contract audits and "never ran" in
  the PLAN v3 batteries. Read the verdict LINE. [[exit-code-first-tally-second]]
- **A detector owes a `<NAME>-COMPLETE` marker as its LAST line** (`lib/guard-contract.ps1`). "No
  findings" and "died halfway" are indistinguishable without it, and this estate has been bitten by
  that shape at least five separate times.
- **A self-test that greps its own source cannot fail.** Build needles by concatenation, and never let
  a detector scan itself - `run-gates` and `audit-write-seam` both carry that exclusion for a reason.
  [[selftest-greps-its-own-source]]
- **Three fixture labels, three jobs** (Brad, 2026-09-07). `CLEAN TWIN` meant two OPPOSITE things
  here, so "add a must-fire and a clean twin" could be read either way:
  - `MUST FIRE` - the founding bug. The detector flags it, or the guard has stopped guarding.
  - `MUST NOT FIRE` - a legal input. The detector is SILENT, or it is crying wolf. **This is the
    negative assertion**, and it is what most of this estate's older `CLEAN TWIN` cases actually are.
  - `CLEAN TWIN` - an adjacent behaviour that **still works**. A POSITIVE assertion: the thing your
    fix was most likely to have broken on its way past.

  `ops/audit-fixture-vocabulary.ps1` fails a `CLEAN TWIN` whose assertion proves an absence. It reads
  the ASSERTION and never the prose, so labels whose sense lives only in their wording are out of its
  reach - it does not claim to have swept the estate.
- **A fixture built by string concatenation is not one argument.** `Test-Thing "a" + "b"` passes
  THREE positional arguments; a simple function binds the first and drops the rest into `$args`, so
  the case runs against a truncated line. Two must-not-fire cases passed that way on 2026-09-07 while
  being fed a fragment that could never have matched anything. Write fixtures as single-quoted
  literals with doubled inner quotes.
- **Never wrap a function call inline as `@(Get-Thing ...)`.** A comma-returned array reads as ONE
  element, so an empty result counts 1 and a real result binds the whole array to your loop variable.
  Assign, then wrap. Hit four times in one session on 2026-09-06.
  [[ps-json-array-collapse]], [[ps-null-count-is-one]]
- **Do not add a gate that is red on day one** for a backlog nobody is about to clear - it teaches
  people to ignore red. Use a ratchet with a high-water mark that may only go DOWN
  (`audit-write-seam`, `audit-fact-claims`, `audit-band-censorship`).
- **`git add` names what it owns.** `ops/audit-git-sweepers.ps1` fails a sweep.
- **Every threshold here is an UPPER bound, so not one of them can fire on nothing happening**
  (2026-09-08, backlog I80). The alert conditions are staleness and band breaches, the `ops/` ratchets
  carry a high-water mark that may only go DOWN, and `run-gates` answers a boolean. The only two checks
  that watch for ABSENCE are `grocery/health-heartbeat.ps1` and the cloud `heartbeat.yml`, and both
  watch **scheduled tasks**, never throughput. **When adding any threshold, write down what the number
  does when the producer STOPS.** If the answer is "goes quiet, and the alert cannot fire", add the
  floor in the same change. A floor on a rate is detective by construction and a preventive gate cannot
  substitute for it, because the failure it catches is one where nothing ran to be gated. This is NOT
  the volume check: that asks whether the expected ROWS arrived, and a stage that runs and emits nothing
  fails it while passing this one. Keep both; do not fold either into the other.
- **A tuning constant records what ELSE was tried, not just what it means** (2026-09-08, backlog I94).
  `measurement.md` already says a number that moved is not a number that improved - say how far, over
  how many cases, and how many variants were tried. That rule did not reach the control constants.
  `$script:BoardStaleHours = 26`, `$REARM_DAYS = 14` and `-MaxDropPct 60.0` each carry a good comment
  saying what the value means and, at best, which incident produced it. **None says whether it was the
  first plausible number or the survivor of a sweep**, and those are different claims. Retro-filling the
  existing ones is NOT asked for; the ask is that the next constant added carries it. Three simulations
  at gains 25, 13 and 7.5 do not establish a stable range - nothing rules out instability higher, or
  stability lower, and the stable set need not even be an interval.
- **A suite whose target set is DISCOVERED prints what it RESOLVED** (2026-09-09, backlog I39). A
  detector whose cases are a literal list in the same file cannot resolve empty; one that globs the
  tree, filters a board or queries a pool can, and then *"no findings"* and *"the glob matched
  nothing"* are the same bytes - the shape that has bitten this estate at least five separate times.
  **Measured 2026-09-09: 180 `.ps1` carry a real `if ($SelfTest)` branch (not the 217 that merely
  mention it - different test, stated), 151 of 180 already print a case count, and of the 143 whose
  target set is discovered only 23 print nothing.** So this is a line for the next suite, not a
  sweep, and **never a threshold**: a bar on resolved counts would be red on day one.
- **A survivor from a mutation probe names the exact missing case** (2026-09-09, backlog I37). Eight
  single compiling mutations across three detectors killed 7 times; the survivor was
  `audit-backlog-status.ps1`'s heading regex losing its `^` anchor, which left twenty-one cases green
  while every heading quoted mid-line or inside a fenced code block would have parsed as a real item.
  **Worth running against a detector whose logic you have just rewritten** - that is when a survivor
  is most likely. Never a gate, and mutants run from a temp mirror with the original verified
  byte-identical by md5 afterwards.
- **A detector's header says what its CLEAN report MEANS** (2026-09-08, backlog I66). A static analysis
  must approximate, and the direction decides what a verdict is worth: a **sound** one never misses a
  real defect, so a clean report is trustworthy; an **unsound** one stays quiet, so a reported defect is
  real and **a clean report proves nothing**. Almost every detector in `ops/` is a pattern matcher over
  source text and is therefore unsound by construction - it finds the spellings it knows. That is not a
  defect in any of them; reading their clean reports as proofs is. Every `ops/audit-*.ps1` now carries a
  `SCOPE OF A CLEAN REPORT:` line saying which it is (7 of 22 already did, in their own words; 15 were
  silent). **A new detector owes that line the way it owes its `<NAME>-COMPLETE` marker.**

Regime: this holds for gate and library code. Data-dependent audits live in the daily chain, not in
`run-gates`, and the split is deliberate - see `run-gates.ps1`'s own header.
