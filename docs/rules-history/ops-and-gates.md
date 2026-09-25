# ops-and-gates rules: the full account (history, never loaded into a session)

This is `.claude/rules/ops-and-gates.md` exactly as it stood on 2026-09-25 before the trim of
design/PLAN-rules-trim-2026-09-25.md, byte for byte below the rule, with one `<a id="og-NN">` anchor added before
each of its 53 rules. The rules file keeps each rule's operative text and points here for the measurements,
dates and incidents behind it. Nothing loads this file: open it when a rule's pointer names its anchor.

---

---
description: Rules for gate, audit and shared-library code - exit codes, the guard contract, must-fire discipline.
---

> **Resolving the `[[citations]]` below.** Each is a filename without its extension, under
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/`. So `[[propagate-has-no-slugs]]` is
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/propagate-has-no-slugs.md`. The line here is a
> pointer; the file is the account. Read it before acting on the pointer, and never write to that
> directory - it is outside the repo and outside your worktree.


# Working in `ops/` or `lib/`

Loaded in every ThriftyCrew session: this file has no `paths:` key, on purpose
(design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md, W2.3). Gates, audits and shared
libraries are the machinery that keeps everything else honest, so a defect here is silent by
construction.

<a id="og-01"></a>
- **Read the EXIT CODE first and the tally second**, and do not decode the number: three vocabularies
  are live at once and the same `2` means "hard defect" in the guard-contract audits and "never ran" in
  the PLAN v3 batteries. Read the verdict LINE. [[exit-code-first-tally-second]]
<a id="og-02"></a>
- **A detector owes a `<NAME>-COMPLETE` marker as its LAST line** (`lib/guard-contract.ps1`). "No
  findings" and "died halfway" are indistinguishable without it, and this estate has been bitten by
  that shape at least five separate times.
<a id="og-03"></a>
- **A self-test that greps its own source cannot fail.** Build needles by concatenation, and never let
  a detector scan itself - `run-gates` and `audit-write-seam` both carry that exclusion for a reason.
  [[selftest-greps-its-own-source]]
<a id="og-04"></a>
- **A catch around a native redirect is not a guard** (2026-09-11). Under `$ErrorActionPreference = 'Stop'`
  EVERY redirect of a native child's stderr (`2>&1`, `2>$null`, `*>&1`, `> log 2>$null`, a bare `git ... 2>&1`)
  makes its first stderr line a terminating throw, and `try { } catch { }` keeps the caller alive while throwing
  the child's answer away: one git warning read as an empty staged set in `verify-commodities-gate`. Fix with
  `Invoke-Native`/`Invoke-NativeScript` (`grocery\native-lib.ps1`), or `$prevEap = $ErrorActionPreference;
  $ErrorActionPreference = 'Continue'` as its own statement before `try { call } finally { restore }`.
  `grocery\test-native-stderr-eap.ps1` is the gate in `run-gates`: an AST scan of every `.ps1` below the root,
  ratcheted by named site. It reads the preference lexically, so a guard it cannot see before the call is a site.
<a id="og-05"></a>
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
<a id="og-06"></a>
- **A threshold or count detector's self-test carries a case exactly AT its bar and one a step PAST it,
  and names the bar in the case text** (Brad's ruling, 2026-09-19, backlog I196). The labels record the
  verdict, never the input class: sampled over ten detectors from `docs/CONTROL-CONSTANTS.md`, the case
  at the bar was missing in 7 of 10 suites whose labels all read correctly, so a `-gt` to `-ge` flip
  passed the whole suite. The step past is one unit of the comparison's own resolution (a day, a
  minute, a row, a point). This is a habit for the next suite, **not a gate**: a bar on it would be
  red on day one.
  **AND THE CASE AT THE BAR IS BUILT FROM BINARY-EXACT NUMBERS, or the double decides it and the rule does
  not** (2026-09-19). `build-aldi-regular`'s pack-basis tolerance is 2%, and the first at-the-bar case put
  48.96 against 4 x 12: the difference and the band agree to fifteen decimal places, `48.96 - 48` rounds up
  and `0.02 * 4 * 12` rounds down, so the case failed by 8e-16 and said nothing whatever about the
  comparison. **The red is loud, and the trap is the fix it invites** - widening the tolerance to make it
  pass would move a real control constant to satisfy a fixture's arithmetic. Choose numbers the format
  represents exactly (halves, quarters, integers): 4 x 12.5 = 50 with a band of exactly 1.0 puts the case ON
  the bar for real, and 51.01 is the step past it.
<a id="og-07"></a>
- **A fixture built by string concatenation is not one argument.** `Test-Thing "a" + "b"` passes
  THREE positional arguments; a simple function binds the first and drops the rest into `$args`, so
  the case runs against a truncated line. Two must-not-fire cases passed that way on 2026-09-07 while
  being fed a fragment that could never have matched anything. Write fixtures as single-quoted
  literals with doubled inner quotes. **The same trap inside an array literal:** in `@($a + 'x', $b)`
  the comma binds tighter than `+`, so it is `$a` plus a two-element array, one string, not two lines.
  A multi-line fixture built that way ran on one line on 2026-09-11 (`audit-cross-module-reach`).
  Assign each concatenated line to a variable first.
<a id="og-08"></a>
- **Never wrap a function call inline as `@(Get-Thing ...)`.** A comma-returned array reads as ONE
  element, so an empty result counts 1 and a real result binds the whole array to your loop variable.
  Assign, then wrap. Hit four times in one session on 2026-09-06.
  [[ps-json-array-collapse]], [[ps-null-count-is-one]]
<a id="og-09"></a>
- **`@($v)` THROWS when `$v` came from `New-Object ...List[object]`**, and the wrap is what throws, not the `+`
  (2026-09-17). `@($l)`, `@($l).Count`, `foreach ($x in @($l))` and `[ordered]@{ p = @($l) }` all die with
  *"Argument types do not match"* even when the list is EMPTY, and the error points at whatever encloses the wrap;
  `$l + @($arr)` is fine, so is the same type built with `::new()`, so is `.ToArray()`, and so is every other element
  type (`List[string]`, `List[psobject]`, an ArrayList). New-Object returns its instance PSObject-wrapped and that
  wrapper is what `@()` cannot convert. It was hand-fixed in `build-deals-page`, then in
  `grocery\build-arrivals-docket.ps1:446`, then written into a memory, and 9c44c3a37 wrote it again in
  `build-sams-deals`: every Sam's build with a reject then died AFTER writing the deals file and before its rejects
  file, summary and cursor advance, for five days. A rule that recurs despite a memory needs a gate, so
  `ops/audit-list-array-wrap.ps1` holds it at push time, at ZERO, with `# list-array-wrap:allow <reason>` on the line
  for the two fixtures that execute the wrap to prove PS 5.1 still throws. Its first run found four more latent
  sites, every one on an error path nobody had taken. [[ps-list-object-array-wrap-throws]]
<a id="og-10"></a>
- **Under `powershell -File`, `-Count 1,2,4,8` into an `[int[]]` binds as the ONE number 1248.** The list
  arrives as one string and the number conversion reads its commas as thousands separators. A measurement
  harness launched 1,168 child processes on the shared box that way on 2026-09-11. A script meant to be run
  with `-File` takes a list as a `[string]` and splits it itself, into a NEW variable (assigning the array back
  to the `[string]` parameter coerces it to `"1 2 4 8"`), and caps anything that launches processes.
<a id="og-11"></a>
- **Do not add a gate that is red on day one** for a backlog nobody is about to clear - it teaches
  people to ignore red. Use a ratchet with a high-water mark that may only go DOWN
  (`audit-write-seam`, `audit-fact-claims`, `audit-band-censorship`).
  **A plain run of a ratchet never writes its mark** (2026-09-11). `run-gates` runs every static audit
  with no arguments on every pre-push, so a tighten there rewrote a TRACKED baseline inside the checkout
  being pushed, the push did not carry it, and a count taken over uncommitted edits is not a baseline
  anyway. A fall is SPOKEN (`ratchet CAN tighten`) and the committed mark KEPT; `-Tighten` records it
  through `Test-RatchetMove` in the bytes git stores (`lib/lf-write.ps1`), and `-Accept` / `-AcceptDrop`
  keep recording what they always did. `ops/audit-write-only-reports.ps1` is the exemplar and
  `ops/audit-write-seam.ps1` is the same shape: their last three self-test cases run the script as a child
  against a temp tree and a temp baseline, so a fall leaves the baseline byte-identical, `-Tighten` writes
  it, and a CLEAN TWIN proves a rise still exits 2. **Write the next ratchet that way from the start.**
<a id="og-12"></a>
- **`git add` names what it owns.** `ops/audit-git-sweepers.ps1` fails a sweep.
<a id="og-13"></a>
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
<a id="og-14"></a>
- **A tuning constant records what ELSE was tried, not just what it means** (2026-09-08, backlog I94).
  `measurement.md` already says a number that moved is not a number that improved - say how far, over
  how many cases, and how many variants were tried. That rule did not reach the control constants.
  `$script:BoardStaleHours = 26`, `$REARM_DAYS = 14` and `-MaxDropPct 60.0` each carry a good comment
  saying what the value means and, at best, which incident produced it. **None says whether it was the
  first plausible number or the survivor of a sweep**, and those are different claims. Retro-filling the
  existing ones is NOT asked for; the ask is that the next constant added carries it. Three simulations
  at gains 25, 13 and 7.5 do not establish a stable range - nothing rules out instability higher, or
  stability lower, and the stable set need not even be an interval.
<a id="og-15"></a>
- **A suite whose target set is DISCOVERED prints what it RESOLVED** (2026-09-09, backlog I39). A
  detector whose cases are a literal list in the same file cannot resolve empty; one that globs the
  tree, filters a board or queries a pool can, and then *"no findings"* and *"the glob matched
  nothing"* are the same bytes - the shape that has bitten this estate at least five separate times.
  **Measured 2026-09-09: 180 `.ps1` carry a real `if ($SelfTest)` branch (not the 217 that merely
  mention it - different test, stated), 151 of 180 already print a case count, and of the 143 whose
  target set is discovered only 23 print nothing.** So this is a line for the next suite, not a
  sweep, and **never a threshold**: a bar on resolved counts would be red on day one.
<a id="og-16"></a>
- **A `switch` on DATA carries a `default` that REFUSES loudly** (Brad's ruling, 2026-09-19, backlog
  I163), in NEW code: with no `default` an unmatched value falls through silently, so "matched nothing"
  and "matched a branch that does nothing" are the same bytes. Data is a subject read from JSON, a board
  row, a function's return or a parameter with no `[ValidateSet]`; write `default { throw "unknown
  <what>: $x" }` (or `Write-Error`, or a non-zero `exit`), and a deliberate fallback says in a comment
  why unmatched is safe. A switch over a literal set in the same file needs none. Census at d335a9a3f:
  120 switches, 114 on data, 1 refusing default. For new code only: no sweep, and never a gate.
<a id="og-17"></a>
- **A survivor from a mutation probe names the exact missing case** (2026-09-09, backlog I37). Eight
  single compiling mutations across three detectors killed 7 times; the survivor was
  `audit-backlog-status.ps1`'s heading regex losing its `^` anchor, which left twenty-one cases green
  while every heading quoted mid-line or inside a fenced code block would have parsed as a real item.
  **Worth running against a detector whose logic you have just rewritten** - that is when a survivor
  is most likely. Never a gate, and mutants run from a temp mirror with the original verified
  byte-identical by md5 afterwards.
<a id="og-18"></a>
- **TWO GUARDS OVER ONE RULE MAKE THE FIXTURE INSENSITIVE, and a mutation probe is how you find out**
  (2026-09-11). `ops/audit-mustfire-census.ps1` blanks comment tokens twice over when it decides whether a span
  outside a self-test body is a fixture: once when testing whether the span is LABELLED, once when COUNTING it.
  Two fixtures asserted the outcome - a prose-only function counts 0, a trailing-comment table counts 0 - and
  both **SURVIVED** the single mutants that removed either half, 0 reds each, because the other half still held
  the count at 0. The assertion was true, the cases were live, and neither could see which half worked. The
  repair is an assertion on the MECHANISM, not the aggregate: the prose-only function is never PROMOTED, so no
  span is added for it at all. With those two cases added, 7 of 7 single mutants died in their own named case
  (control 34 pass, exit 0, originals md5-identical afterwards, temp mirror removed). **A defence worth having
  twice is worth a case per copy**; otherwise the probe scores a survivor and the honest reading is that the
  fixture is insensitive, not that the code is wrong.
<a id="og-19"></a>
- **A control constant that may only move ONE WAY needs a RATE LIMIT and a PLAUSIBILITY BAR**
  (2026-09-09, backlog I93). `lib/ratchet.ps1` has it: the audits' high-water mark may only fall, so it
  refuses a fall to zero and a fall larger than `-MaxDropPct`, **keeps the old baseline**, and reports.
  `graph/learning/promote_aliases.py`'s holds are the estate's other one-directional actuator - they
  only accumulate and never expire - and had none of it, so one degraded guard run naming many
  commodities would have latched a permanent hold for each of them in a single pass. It now refuses a
  batch over `MAX_NEW_HOLDS_PER_RUN`, keeps the file, and reports, with `--accept-holds` as the
  deliberate override. **Refusing is only half: the old state must be KEPT and the refusal SPOKEN**, or
  a run that declined to act is indistinguishable from a run with nothing to do. The register of every
  such constant, with its direction and what it does when the producer stops, is
  `docs/CONTROL-CONSTANTS.md`.
<a id="og-20"></a>
- **The `Get-Random` refusals cover WORK SELECTION, not TEST INPUT** (Brad, 2026-09-09, backlog I38).
  `Get-Random` appears in three files here and all three refuse it: a deterministic verification sample,
  a reproducible worklist, a retry jitter that uses the attempt index. **Each is right about what it
  refuses** - work that cannot be replayed. **None of them is an argument against a seeded test-input
  generator**, because a seeded generator is reproducible by construction: print the seed, re-feed it,
  and every case replays byte for byte, which is the exact property the deterministic-sample rule was
  protecting. `ops/probe-hostile-input.ps1` is the exemplar. It is a REPORT, not a gate.
  **A seed replays only against the same DRAW** (2026-09-18, backlog I210): the draw is an index into a
  kind list, so one added kind moves every later case of an old seed. Print the draw version, a fingerprint
  of the kind list and the commit beside the seed; draw from ONE `[System.Random]($Seed)` the generator
  owns, never the session-global `Get-Random` stream; and keep a found failure as a recorded VALUE that
  every run executes, never as a seed. **And count distinct INPUTS, not draws** (backlog I203): ten of that
  probe's twelve kinds ignored the drawn offset, so its "12 ACCEPTED CORRUPT" was 2 inputs and 2 failures.
<a id="og-21"></a>
- **PowerShell's `-ne` on strings is CULTURE-SENSITIVE, and culture-sensitive comparison IGNORES NUL**
  (2026-09-09, found by `probe-hostile-input.ps1`'s own must-fire). `('Bana' + [char]0 + 'nas') -ne
  'Bananas'` is **`$false`**, though the two differ in length. So the default operator is blind to
  exactly the corruption class a parser probe exists to find, and the first version of that probe
  reported two real malformations as no-ops because of it. **Compare with
  `[string]::Equals($a,$b,[StringComparison]::Ordinal)` anywhere the text might carry damage.** This is
  the same family as the `[StringComparer]::Ordinal` hashtable trap in `ops/consistency-oracle.ps1`: a
  bare `@{}` is case-insensitive and a bare `-ne` is culture-sensitive, and both defaults are wrong for
  data that arrived from outside.
<a id="og-22"></a>
- **A detector's header says what its CLEAN report MEANS** (2026-09-08, backlog I66). A static analysis
  must approximate, and it can err in two INDEPENDENT directions, so there are four cases, not two. A
  **sound** one never misses a real defect (no false negatives), so a clean report is trustworthy; an
  **unsound** one can miss one, so **a clean report proves nothing**. A **complete** one never reports
  a defect that is not there (no false positives), so a finding is real; an **incomplete** one can
  report a harmless site, so a finding is a candidate to read. **Unsound says nothing about findings**:
  "it is unsound, so what it reports is real" does not follow, and this bullet said exactly that until
  backlog I178 (2026-09-18). Almost every detector in `ops/` is a pattern matcher over source text and
  is therefore unsound by construction - it finds the spellings it knows - and a pattern matcher is
  usually incomplete too, which is what an allow-marker (`# atomic-replace:allow`, the cmdlet-shadow
  allowlist) exists to absorb. That is not a defect in any of them; reading their clean reports as
  proofs, or their findings as verdicts, is. Every `ops/audit-*.ps1` carried a
  `SCOPE OF A CLEAN REPORT:` line saying which it is on 2026-09-08 (7 of 22 already did, in their own
  words; 15 were silent); on 2026-09-18, 41 of 47 did, and the six without one (`arg-binding`,
  `fixture-vocabulary`, `run-log-claims`, `source-control-bytes`, `threshold-register` and
  `write-only-reports`) got one the same day under backlog I227, so 47 of 47 do. **A new detector owes that line the way it owes its `<NAME>-COMPLETE` marker, and when the
  line says a finding is real it gives the reason it is COMPLETE** (the match IS the defect, as in
  `audit-cmdlet-shadow`), never the unsoundness.
<a id="og-23"></a>
- **A git hook in a LINKED worktree exports `GIT_DIR`, and everything it spawns inherits it**
  (2026-09-10). From the main checkout it exports none, which is why nothing showed until the first push
  from a detached gate-check checkout: `run-gates`' hermetic git self-tests then ran their temp-repo
  `git init` and `git config` against the SHARED `.git`, set `core.bare=true` and a test identity, and
  `git status` failed in every checkout on the box. While it was bare, `pre-push` could not resolve a
  working tree and exited 0, so a sibling session's push went out ungated. `ops/hooks/pre-push` and
  `ops/run-gates.ps1` now clear the repository environment, the hook refuses when it cannot find a tree,
  and `ops/test-prepush-hook.ps1` drives both from a sandbox linked worktree. **A new hook that spawns
  tests, or a fixture that builds a temp repo, clears `GIT_DIR` first** - a fixture by calling
  `Clear-TcGitRepoEnv` from `lib/git-repo-env.ps1` (2026-09-11), whose header records why a fixture scrubs
  rather than refuses, and `ops/audit-git-fixture-env.ps1` fails a push that adds a `git init` without it.
  **`pre-commit` has the same exposure and must keep `GIT_INDEX_FILE`** (measured 2026-09-11: from a linked
  worktree it gets `GIT_DIR`, and a `git -C <temp> config` inside it wrote the main config). `GIT_INDEX_FILE`
  names the index being committed - `.git/index`, or a lock file for `commit -a` and `commit -- <paths>` - so
  under that hook a temp-repo `git add` writes the commit's index. That is why the fixture clears the full set
  itself rather than trusting the hook above it.
<a id="og-24"></a>
- **A walk over this tree excludes on the path BELOW its root, never on the full path** (2026-09-11). A
  linked worktree lives at `<main>\.claude\worktrees\<name>`, so `$_.FullName -notmatch '\\worktrees\\'`,
  or `-like '*\.claude\*'`, excludes EVERY file when the walk runs from one, and every spawned session
  runs from one. Nineteen walks in seventeen files did exactly that: from a worktree, twelve of fourteen
  ops detectors exited 3, `run-gates`' Python discovery found no suites, and `audit-twin-drift`'s sweep
  printed a clean count over nothing. It was recorded on 2026-08-26 and left standing for two weeks.
  `lib/tree-walk.ps1` is the one rule (`Get-TcPathBelowRoot`), and its `New-TcWorktreeFixture` builds the
  MUST FIRE case: a root under `.claude\worktrees\` with a sibling worktree below it. **A new walk puts its
  discovery in a function that takes the root, so its self-test can point it there.** The rule does not
  recognise a checkout under a directory with some other name; `grocery/audit-script-census.ps1` prunes on
  the `.git` entry instead, which is the stronger boundary.
  **A rule in a file is not a block**, so `ops/audit-full-path-excludes.ps1` holds this at push time: a ratchet
  over the PowerShell AST and Python `os.walk` roots, wired into `run-gates`. Run it for the count rather than
  quoting one.
  **AND AN EXCLUSION MUST PRUNE, NOT ONLY FILTER** (2026-09-12). `Get-ChildItem -Recurse | Where-Object` still
  LISTS every worktree before the filter drops it. From a worktree that costs nothing; from the main checkout,
  which holds all 135, a recursive `.ps1` listing enumerated 100,747 files against 780, and a push gated there took
  233 to 258 s against 48 to 93 s from a worktree (`audit-guard-contract` alone 222 s). **A new walk over the root
  calls `Get-TcTreeFiles -RootFull $root [-Filter] -PruneBelow <its own exclusion>` and keeps its filter**: it
  returns `Get-ChildItem -Recurse -File`'s exact list and order and never enters a directory that exclusion drops
  (verified on the main checkout, 93,835 files in 85.3 s against 3.7 s, identical). Do not convert from `-Include`
  by copying it: `-Include` enters junctions and orders its output differently, so check the extension instead.

<a id="og-25"></a>
- **A mutex serialises WRITERS, never READERS, and under PS 5.1 a lock-free reader can cost a locked writer
  its write** (2026-09-11). `Move-Item -Force x.tmp x` fails with *"Cannot create a file when that file
  already exists"* whenever another handle holds `x` shared ReadWrite but not Delete - which is exactly how
  `Get-Content` and `Read-TextFile` open it. It fails INSIDE the lock, with the lock held and the old file
  intact, so the write is simply gone. run-gates went red that way on two concurrency fixtures at 839c5e666;
  driven under 32 CPU burners with every writer's output kept, the fixture shape lost a write in 3 of 100
  trials, every one this error and none a lock timeout (worst wait 10,433 ms of the 15 s budget).
  `lib/atomic-write.ps1` (`Write-TcAtomicFile`) retries the move, and the three `Invoke-Locked` ledgers use it.
  **A concurrency fixture keeps every writer's exit code and output** and counts a refusal as a refusal: the
  `| Out-Null` those fixtures carried threw away the one line that named the cause.
  **Its barrier goes INSIDE each writer, immediately before the contended call, never ahead of the writer's own
  process start-up.** A barrier in the parent or a `Start-Job` child releases writers that each then spend about a
  second starting powershell.exe, which spreads them further than the barrier closed: a disabled lock went uncaught
  in 5 of 11 runs, then 1 of 10. `lib/ledger-fixture.ps1` holds them on a kernel event inside `Invoke-Locked` (red
  50 of 50 with the lock disabled across the three ledgers, asserted as a count of writers at the barrier), gives
  self-test writers a hang-guard lock wait instead of the production 15 s, and names a writer that could not run.
  **The other replaces were swept the same day** over `grocery/`, `meal-prep/`, `ops/` and `lib/`: of 21
  tmp-then-replace sites, the 9 whose file a lane, a scheduled task or a daemon can read mid-replace now use
  `Write-TcAtomicFile` too (the triage queue, the capture cursor, sale-windows, the ad schedule, the rollback ledger,
  capture-run's status, hunt-run state, considered-dishes, saturation). The 12 left are written by one serial chain
  step with no concurrent reader, already retry, or are run by hand. **A new replace of a file something else reads
  uses `Write-TcAtomicFile`**, and a site that wrote with `WriteAllText` and no BOM passes `-NoBom -NoNewline` so its
  bytes do not change. **Under the default ErrorActionPreference a bare refusal is SILENT**: `Move-Item -Force` over a
  held file prints an error and the script carries on as if the write landed, so a writer without `EAP=Stop` loses
  it with no throw. The lib moves with `-ErrorAction Stop`, fails fast on what waiting cannot fix (a missing temp file
  or directory), takes `-UniqueTemp` where writers share no mutex, and runs `-OnRefusal` so a test can PROVE a replace
  met a reader instead of timing it. `ops/audit-bare-replace.ps1` ratchets the bare form in `run-gates`: run it for
  the count, and mark a deliberate exception `# atomic-replace:allow <reason>` on the command's own line.
<a id="og-26"></a>
- **A lock around the SAVE is not a lock around the read-modify-write when the ledger was loaded earlier**
  (2026-09-11). `grocery/sale-windows.json`, `grocery/out/capture-cursor.json` and
  `grocery/rollback-first-seen.json` were read-modify-written by concurrent lanes and builders with no lock at
  all. `lib/ledger-lock.ps1` (`Enter-TcLedgerLock`) is the lock for a single-file ledger written from a LIBRARY:
  it throws where the CLI copies `exit`, keys on SHA-256 of the full path rather than `GetHashCode`, and is
  reentrant in one thread. The READ goes inside it. A ledger held in memory across a run - `rollback-ttl-lib`
  loads at the first markdown and saves at the end - must RE-READ and MERGE under the lock, taking only the keys
  it touched: a lock around its save alone still writes the copy it loaded, and loses every sibling's entry.
  Each ledger's fixture launches its writers through `lib/ledger-fixture.ps1`, whose gate sits inside
  `Enter-TcLedgerLock` immediately before `WaitOne`; the rates at which they went red with a lock neutered in a
  temp mirror are in the commit that added them.
<a id="og-27"></a>
- **THE LOCK ORDER IS DECLARED, OUTERMOST FIRST** (Brad's ruling, 2026-09-12, backlog I104). This estate has four
  independent mutual-exclusion mechanisms, and until this line nothing said which order they nest in. **Any change
  that holds two of them at once takes them in this order, releases in REVERSE, and SAYS IN ITS COMMIT that it is
  the first nested acquisition of that pair** - the pair nobody has nested before is the one with no precedent to
  copy, so the commit is where the next reader finds out one exists:
  0. **the capture-run mutex** - `Global\tc-capture-run`, taken in `grocery\capture-run.ps1` (Brad's ruling D6, 2026-09-23,
     `design\PLAN-bot-checkout-self-heal-2026-09-23.md`). OUTERMOST, because it already nests over the others: the tail's
     `git push` runs the `pre-push` hook, which takes the push lock, and the run writes the pipeline write journal and the
     commit carry ledger under `lib\ledger-lock.ps1`. The checkout sync it runs at the start and the tail takes no push
     lock and no gate slot. A run that re-executes itself onto synced code holds this mutex across a wait on its child,
     which is safe under the blocking-wait paragraph below because the child INHERITS the mutex by token and does not wait
     for it. When the token is NOT honoured (malformed, naming another lock, or a holder pid the probe reads as dead) the
     child does ask for the lock, and that wait is BOUNDED, never a deadlock: 60 s, then `skipped-locked`, and the parent
     pages `handoff-failed` and exits 1.
  0a. **the per-checkout guard** - `ops\push-main.ps1` (`Enter-TcCheckoutGuard`, W2.1R of
     `design\PLAN-push-derived-conflicts-2026-09-23.md`): one push-main per checkout, a mutex named from SHA-256 of the
     lower-cased worktree path. It is taken with ZERO wait, so it waits on nothing and nothing waits on it, and it can form
     no wait-for edge with anything below it; it sits outermost of push-main's own locks only because it is held for the
     whole run.
  0b. **the chain queue ticket** - `lib\chain-queue.ps1` (`Join-TcChainQueue`, W9.2 of
     `design\PLAN-push-derived-conflicts-2026-09-23.md`, section 16.6). **It is not a lock held across a leg**: while a
     member holds a ticket every other push, member or not, runs run-gates, test-auditors and its rehearsal freely. The
     only thing a ticket defers is the next member's SWAP, which `refs/heads/main` serialises already, so it serialises
     the push and never the gate (the 2026-09-12 ruling). It sits outside 1, 2 and 2b because a holder waits on all three
     (its swap, its run-gates, its rehearsal child in another process). Its own blocking wait, for the tickets ahead, is
     safe under the blocking-wait paragraph below: a ticket ahead never waits on anything behind it, and no holder of the
     push lock, a gate slot or a rehearsal slot ever waits on a ticket. The hook's W8.3 probe waits on nothing. Since
     push-main's W9.2 integration a member holds its ticket across its own run-gates (gate slots) and its own rehearsal
     child (a rehearsal slot, in another process): the first nested acquisitions of ticket over gate slots and ticket
     over a rehearsal slot, both outermost-first as this list reads, and neither waits on the ticket. `2a`, the
     early-rehearsal cap, is placed below.
  1. **the push lock** - `lib\push-lock.ps1` (`Enter-TcPushLock`)
  2. **the gate worker slots** - `lib\gate-slots.ps1` (`Enter-TcGateSlots`)
  2a. **the early-rehearsal cap** - `Global\tc-rehearsal-early-`, 4 of the 6 rehearsal slots, taken in
     `ops\rehearse-chain.ps1` only by an `-Early` run and always BEFORE its rehearsal slot (W9.1, plan 16.6): the first
     nested acquisition of early cap over rehearsal slot. A push-time rehearsal never takes it.
  2b. **the rehearsal slots** - `Global\tc-rehearsal-slot-`, taken in `ops\rehearse-chain.ps1`. A PEER of the gate slots,
     never nested with them: read 2026-09-23 for W9.2, nothing a rehearsal runs while it holds its slot (the arm's clone,
     seed, the rehearsed tree's `check-ad-cycles -SelfTest` and ship path, and its own pre-commit hook) takes a gate slot
     or the push lock, and no script under `grocery\` or `meal-prep\` calls `Enter-TcGateSlots` or `Enter-TcPushLock`.
  3. **the `Invoke-Locked` mutexes** - `grocery\ingredient-queue.ps1`, `meal-prep\pipeline\ingredient-resolutions.ps1`,
     `meal-prep\pipeline\source-domains.ps1`
  4. **the ledger locks** - `lib\ledger-lock.ps1` (`Enter-TcLedgerLock`), and **between two ledger locks, ASCENDING
     by full ledger path compared ORDINALLY**.

  **The tie-break sorts on the same string that NAMES the mutex**: the lower-cased full path `Get-TcLedgerLockName`
  already builds (`GetFullPath` of the provider path, trailing separators trimmed, `ToLowerInvariant`), compared with
  `[string]::CompareOrdinal`. Sorting on the caller's own spelling would not be a total order at all, because the path
  is the identity there - `ledger.json`, its upper-cased form and a `sub\..\.\` detour are ONE lock that would sort
  into three different positions, and two callers could then take the same two ledgers in opposite orders while each
  believed it was ascending. Ordinal for the reason the `-ne` rule above gives: the default comparison here is
  culture-sensitive, and a culture-sensitive order is not a stable base for a deadlock-freedom claim.

  **One nesting already exists and already obeys this**, checked 2026-09-12: `ops\push-main.ps1:203` takes the push
  lock and then runs `git push` inside it, whose `pre-push` hook runs the warm `run-gates`, which takes gate worker
  slots at `ops\run-gates.ps1:594`. That is (1) over (2). Nothing takes two ledger locks, and nothing takes a ledger
  lock under an `Invoke-Locked` mutex, so 3-over-4 and 4-over-4 are declared and unexercised.

  **The order covers every BLOCKING WAIT, not only the four locks** (Brad's ruling, 2026-09-19, backlog I177). A wait
  on an event, a process, a slot or the remote while holding one of these locks is a nesting, and it is safe only if
  the thing waited on can never need the lock held. The classic bounded-buffer deadlock has no second lock in it at
  all: a consumer waits on a semaphore while holding the mutex the producer needs to post it. **The one live nesting
  is safe for exactly that reason**, not merely because it is (1) over (2): `push-main` holds the push lock across a
  `git push` whose hook waits for gate slots, and no gate-slot holder ever waits for the push lock. A change that makes
  anything under a gate slot wait on the push lock, or on a process that takes it, turns that nesting into a cycle.
  No detector, for the reason the next paragraph gives.

  **Why write an order nobody needs yet, and why it is not a gate.** **No gate is added until a second lock is
  actually nested** - a detector over a case that cannot occur is the shape these rules already refuse, and it would
  have no production caller. What is bought instead is the thing a gate could not buy anyway: a lock-ordering
  deadlock is the failure where *some* interleavings succeed, so it survives its own fixture, review, and a week of
  production before it wedges two lanes at 07:00. Declaring the order is free while it is still arbitrary, and
  expensive once two callers already disagree and one of them has to be unwound.
<a id="og-28"></a>
- **A self-test can run ZERO cases and exit 0** (2026-09-11). A helper named `R` resolved to the built-in alias
  for `Invoke-History` before the function, every case line errored non-terminating, and the suite printed PASS
  over nothing. Aliases beat functions, so never name a helper `r`, `h`, `gc`, `ls` or any other alias; and run
  the cases under `$ErrorActionPreference = 'Stop'` inside a try whose catch is a counted failure.
  **And a script function beats a CMDLET of the same name, which turns an assertion inert rather than erroring.**
  `grocery/ingredient-queue.ps1` defined a queue lookup `Get-Item($doc, $term)`, so its `-Promote` fixture's
  `(Get-Item $live).Length` called the lookup, got nothing back for a path, and read 0 before and after: the
  "live ledger untouched" half could not fire from 2026-08-25 to 2026-09-11. Never name a function after a cmdlet,
  and compare a file by content (`Get-FileHash -LiteralPath`). On 2026-09-11, 3 of 747 tracked `.ps1` defined one.
  **`ops/audit-cmdlet-shadow.ps1` holds it at push time** against a pinned name list: the lookup became
  `Get-QueueItem`, `media/reels/build-reel.ps1`'s `Format-List` became `Format-RowList`, and
  `grocery/test-auditors.ps1`'s scoped `Get-Date` clock mock is its one allowlist entry, keyed on file and name
  with its reason. It sees literal definitions only, never `Set-Item function:` or an alias.
<a id="og-29"></a>
- **A self-test's exit 0 is not its verdict** (2026-09-11). 8253ded82 glued pull-grocery-ads' closing `if/else`
  onto its last case line, so the `-SelfTest` branch never exited, fell through to the LIVE three-store pull and
  exited 0, and run-gates scored it ok on every push for hours. run-gates now reads each self-test's stdout through
  `lib\selftest-verdict.ps1`: after skipping trailing `<NAME>-COMPLETE` markers that do not name the self-test, the
  last line must name the self-test (`self-test`, `selftest`, `-SelfTest`) and carry a result word (`pass`, `ok`,
  `green`, `fail`), or a marker must name it (`X-SELFTEST-COMPLETE`, `selftest=pass`). Exit 0 without that is scored
  3, never ok, for PowerShell and Python suites alike. **A new suite's last line is its verdict and says it is a
  self-test**: `failures: 0`, `all assertions passed` and a bare `VERDICT: PASS` are tallies, not verdicts. Measured at
  2c0d9c45c over run-gates' own discovery: 6 of 316 suites had none, and all six got one in the same change. **What a
  suite SAYS outweighs its exit 0 too:** a case-sensitive `SELF-TEST FAIL` or a line starting `FAIL` scores fail (exit
  1) - a lost exit after a failing verdict read ok before. 0 of 314 exit-0 suites printed either that day. So never
  echo a captured child's `FAIL` lines as your own at exit 0. It cannot see a passing fall-through into a path that
  prints nothing.
<a id="og-30"></a>
- **And the STATIC half: a self-test block must LEAVE on every path** (2026-09-11). The verdict rule above is a
  runtime read, so by the time it speaks the block has already done the live work: that afternoon every gated push
  ran a real three-store pull and wrote `grocery\out\ads-<today>.json` into its own checkout before anything was
  scored, and 29 checkouts held one by evening. `ops/audit-selftest-fallthrough.ps1` reads the AST at push time and
  fails a top-level self-test `if` that live statements follow and that can end without `exit`, `throw`, `return` or
  `Exit-Guard`. A verdict `if` with no `else` is one, a `catch` that only reports is another, and so is the passing
  fall-through into a silent path the verdict check states it cannot see. Close a self-test block with an
  unconditional `exit` after its verdict. Measured over 761 tracked scripts: 274 top-level gates and one site,
  `grocery/import-aldi-batch.ps1`, whose gate only appended `-SelfTest` and fell out to the call below; it now calls
  the child and exits inside the gate.
<a id="og-31"></a>
- **A HARNESS that runs a child's self-test owes the same two reads** (2026-09-11), and run-gates' rule above does
  not reach it: `grocery/test-auditors.ps1` spawns its children itself. u141 read rc 0, every case name and no `FAIL`
  line from the fall-through above and passed it. Over the 46 `-SelfTest` call sites in that file, each child run
  once: 45 required the child's verdict (the matched text hit exactly one line, the child's last or the one before
  its `-COMPLETE` marker), u141 did not, and 7 of the 45 never read the exit code. All eight now require both.
  Choose the text from the child's real last lines, never a word that also sits in a case label, and hand the child
  a temp output directory where it takes one: `pull-grocery-ads` creates its `-OutDir` before the self-test runs, so
  the default was the live `grocery\out`.
<a id="og-32"></a>
- **A BLIND case that gates a BLOCK is scored on the BLOCK, and only the SEEING arm can check that number**
  (2026-09-12). `blind=` on a `-COMPLETE` marker is what run-gates prints on a green run, so it is the whole
  statement of what a passing gate did not cover. `meal-prep/pipeline/wave-preaudit.ps1` reported `blind=1` for a
  single could-not-look case that skipped its entire end-to-end drill: run-gates printed *"wave-preaudit (1
  case(s))"*, which reads as one case of 50, and the real figure was **14 of 64**, every one an END-TO-END MUST
  FIRE or CLEAN TWIN over the real publish drill. Measured by diffing CASE NAMES between an unseeded and a seeded
  run in one checkout, never counts. This is `measurement.md`'s abstention and denominator rules landing on a gate
  marker: **count the cases the blind branch SUPPRESSED, not the one that noticed**, and print `cases` beside
  `blind` so the two add to the suite. **The blind arm cannot verify its own number** - it is a claim about code
  it could not run - so the seeing arm asserts it: a CLEAN TWIN after the block checks that it ran exactly what a
  blind checkout reports as not covered, and goes red in the main checkout the day somebody adds a case without
  moving the constant. Swept that day: 3 self-tests carry `blind=` on their marker, and `sidecar/start-sidecar.ps1`
  was already right because its blind case stays inside its own `$ran` total. Not a gate - a three-file class does
  not earn a ratchet, and a bar on blind counts would be red on day one.
<a id="og-33"></a>
- **A sandbox that runs a real script copies the WHOLE `lib\`, and a library the script cannot load is exit 3**
  (2026-09-11). `ops/test-prepush-hook.ps1` copied `prepush-test-auditors.ps1` with a hand list of two libraries
  older than `lib/git-repo-env.ps1`. Under `Continue` the dot-source printed "is not recognized" and carried on,
  the hook sends that script's stderr to `/dev/null`, and all 26 cases passed while its `Clear-TcGitRepoEnv` never
  ran. The sandbox now copies every `lib\*.ps1`, and the check loads each library under `Stop` inside a try that
  exits 3. try alone catches a missing file, a parse error and a throw; an error WRITTEN while loading needs `Stop`.
  **The four hand-listed copies it left standing were swept the same day**, each probed from a temp mirror with one
  library dropped. `grocery/send-alert.ps1` WAS blind: two of its library loads sit in a try that logs and falls
  back, so without `atomic-write` or without `append-line` all 60 cases passed. It now copies every `lib\*.ps1` and
  fails a run whose sandbox log names a library that did not load. `grocery/test-auditors.ps1` WAS blind another way:
  its two libraries went into ONE fixed `%TEMP%\lib` shared by every run, so a dropped copy was answered by an earlier
  run's leftover (exit 0, 6 of 6). Each run now has its own root holding every library, and unit u142 names a missing
  or stale one. `grocery/triage-close.ps1` and `meal-prep/pipeline/wave-preaudit.ps1` were already LOUD, because the
  dot-source runs under `Stop` and exits 1, and were left alone. **A fallback that logs is the blind kind: when a
  load failure is caught, the only case that can see it is one that reads the log.** A fifth sandbox with no `lib\`
  at all, `ops/consistency-oracle.ps1`'s flat `%TEMP%` one, was given the repo's shape the same day (5e5b09e62).
  Unguarded dot-sources elsewhere were not counted.
  **PROVE A SANDBOX BY BUILDING ONE AND RUNNING A SUBJECT IN IT, not by path arithmetic** (2026-09-12). The
  oracle's first cases for that repair computed where `lib\` would be and asserted the arithmetic, so they stayed
  green when `New-TcSandbox` was reverted to flat, and when it kept the layout but copied no library. Its sandbox
  cases now build real sandboxes from a fixture repo and run subjects out of process, and the MUST FIRE removes a
  library from the arm's own `lib\` while planting a working copy where the flat layout looked. **That decoy is
  load-bearing**: the flat revert turned 8 of 19 cases red with it, and 7 without it, where the must-fire stayed
  GREEN because a flat sandbox fails the subject too, for the wrong reason.
<a id="og-34"></a>
- **Under PS 5.1 `VariablePath.UnqualifiedPath` is INTERNAL and reads as `$null`** (2026-09-11). An AST walk
  that used it as a hashtable key threw, which is the lucky case; the same value in a `-match` matches nothing, so
  a walk that collects variable names finds none and returns an agreeing empty. Strip the scope from `UserPath`
  instead: `Get-SelfTestVariableName` in `lib/selftest-lib.ps1`.
<a id="og-35"></a>
- **A self-test the census cannot find can lose its must-fires and stay green** (2026-09-11). `ops/audit-mustfire-census.ps1`
  and `ops/audit-fixture-inputs.ps1` read only the bodies `Get-SelfTestBlock` in `lib/selftest-lib.ps1` returns: an
  `if` gated on a self-test switch or a copy of one, the code after `if (-not $SelfTest) { ...; exit }`, a function
  named `Invoke-<name>SelfTest`, and a whole file NAMED `test-*.ps1` that reads no self-test switch. Measured that
  day, 17 files and 230 must-fire lines sat outside every shape the census then read, 65 of them in
  `grocery/test-auditors.ps1`. **Open a new suite in one of these shapes.** Fixtures run from a function with another
  name (`Invoke-NamesFixtures`), or behind a guard that ends in a try rather than an exit, are still invisible.
<a id="og-36"></a>
- **A hermetic self-test never asserts an UPPER wall-clock bar** (2026-09-11). Several sessions push from
  one box, so a pre-push `run-gates` shares the cores with theirs: a set that takes 106 s quiet took 792 s,
  and `fanout-lib`'s "under 12 s" and `parallel-run`'s "under 2.5 s" concurrency cases blocked a push that
  touched neither file - the red that teaches `--no-verify`. Paired under the same load, the old cases
  failed 8 of 20 while their rewrites passed 20 of 20. **To prove work runs concurrently, prove the
  OVERLAP, not the speed:** `lib/concurrency-probe.ps1` has N children wait until all N have started,
  which no serial pool can satisfy and no load can break (its width-1 and width-2 mutants went red 12 of
  12). A clock survives as a generous hang guard, or as a LOWER bar that load can only help.
  **To prove a regex bound, count the timeout the code RECORDS, never time the call** (2026-09-11).
  `grocery/audit-coverage-gaps.ps1` and `grocery/price-ingredient.ps1` timed their ReDoS match against 1 s
  and 2 s bars, and neither bar could go red: with the bound removed, their 58-character victim ran past a
  90 s guard, so the must-fire HUNG - and under `run-gates` a hang is the 900 s job timeout scored exit 3,
  never a red that names the case. **A ReDoS fixture needs a victim whose UNBOUNDED cost is a few seconds**:
  far above the bound, so the timeout still fires on a faster box, and short enough that a neutered bound
  finishes and goes red. The cost climbs steeply with length (29 characters 7.8 s CPU, 32 past a 20 s
  guard), so measure it rather than pick one. **A timer racing a retry window is the same bar in disguise:**
  `meal-prep/pipeline/harvest.py`'s pool-write case closed its reader from a thread after 0.9 s against a
  ~1.6 s retry window, and now closes it from inside the retry's own wait.
  **A poll with a deadline is the same bar again, and so is a barrier with a timeout** (2026-09-11).
  `meal-prep/pipeline/hunt_daemon_selftest.py` decided five cases that way: a 3 s dispatch poll, two ~6 s
  release loops and a 0.6 s `threading.Barrier`. Each now waits on an event the daemon produces. **End a wait
  from inside a swappable seam, then give the real timer its own twin:** the price hold's wait is
  `price_hold_wait()`, a case ends it by raising the TimeoutError itself, and a separate CLEAN TWIN reads that
  the unswapped wait ENDS in TimeoutError, never how long it took - the half the seam gives up. **"The lane is
  done" is a consumer back at its channel:** `_TakeProbe` counts a task that returns to `take()` after being
  handed an item. **A contention fixture waits for OVERLAP, BLOCKED or WRITTEN**, never for seconds: `_F1Gate`
  wraps the real lock and reports only a real wait. Six mutants went red in their named case in both arms and
  none hung; paired under 10 `cpu-load` burners, both arms passed 200 of 200 on every case, so the flake did
  not reproduce and the change rests on the mechanism and the mutants. Still standing, found and not fixed:
  `_hb_heartbeat_reports_and_names_a_stall`, whose NO PROGRESS case needs about four event-loop ticks inside a
  0.25 s sleep. **That battery ran on no schedule until 2026-09-11**, whatever `run-gates`' skip reason used to say.
  It is now defined as `TC Daemon Battery 0230` (`ops/run-daemon-battery.ps1`: exit code first, `--names-diff`
  against the committed `hunt_daemon_selftest.names.txt`, red on any `git status` line in a throwaway checkout), so
  these bars redden the nightly run as well as whoever runs it by hand. **A definition is not a registration**:
  check `Get-ScheduledTask` before saying it runs. **So is a sample taken "during" a subject that ends on its
  own clock:** `ops/cpu-load.ps1`'s clean twin sampled a 4 s load and read it already finished when its process
  query came back late; a 6 s delay injected before the sample reproduced the gate's exact got line in 2 of 2.
  **Hold the subject open on a CONDITION the test controls (a stop file), sample, then read it STILL RUNNING
  before releasing it.** The tool had the production twin: a burner's own deadline could land before the hold
  loop's last alive check and read as "a burner exited early". A check that reads the subject BEFORE the clock
  cannot mistake one for the other. **Not every red under load is a
  clock:** the two concurrency-fixture reds the same day were lost writes, the mutex rule above.
<a id="og-37"></a>
- **A timed lock wait is a BRANCH, and an append is not a locked write** (2026-09-11). `grocery/send-alert.ps1`
  stored `WaitOne(10000)`'s answer and never read it, so a timeout rewrote the whole triage queue UNLOCKED over
  the writer that held the lock, and `grocery/triage-close.ps1` never took the lock at all. Every other `WaitOne`
  in the tree already refused on `$false`. **The timed-out branch needs a MUST FIRE, and a clock cannot give it
  one:** `lib/mutex-hold.ps1` holds a fixture mutex from ANOTHER PROCESS until released, so the wait times out
  however loaded the box is, and a fixture never holds a live name. The spool that branch lands in had its own
  hole: **a bare `Add-Content` loses lines to a concurrent appender** - 13 of 200 landed with two processes, 5 of
  1,200 with four, every failure *"Stream was not readable."* A file several processes append to goes through
  `lib/append-line.ps1` (`Add-TcLine`: append-only rights, shared ReadWrite, one write), which landed 1,200 of
  1,200. **The event bus had the same hole, and nobody could see it** (measured and fixed the same day):
  `Write-TcEvent`'s `StreamWriter` landed 1,878 of 2,000 events with two processes and 4,792 of 8,000 with
  eight, every loss a `$false` that every producer discards with `$null =`. Through `Add-TcLine` it landed
  15,000 of 15,000 (`design/MEASURE-event-bus-concurrent-append-2026-09-11.md`). That doc also lists the
  appenders still standing, NOT fixed: `grocery/alert-log.txt` and `grocery/out/capture-cursor-log.jsonl`
  have writers shown running at once, and the cursor log swallows a failure silently.

<a id="og-38"></a>
- **A self-test names every temp path PER RUN, never by a fixed name under `%TEMP%`** (2026-09-11). `run-gates`
  runs every `-SelfTest` and `pre-push` runs `run-gates`, so pushes from concurrent sessions run the SAME suite
  over each other in one `%TEMP%`. `lib/guard-contract.ps1` wrote `gc-clobber-probe.ps1`, `gc-invoke-probe.ps1`
  and `gc-probe-out-<mode>.txt` there and was red in 6 of 6 run-gates passes under three concurrent loops;
  `grocery/test-guards.ps1 -SelfTest` journalled into the one fixed `tg-restore-journal`, where another run's
  `JournalClear` deleted its snapshot or its `JournalRecover` REPLAYED it. Measured with 4 copies launched
  together, 5 rounds, original and fix alternating round by round: guard-contract green 0 of 20 before and 20
  of 20 after, test-guards 15 of 20 before and 20 of 20 after, no temp entry left in 10 of 10 fixed rounds.
  **Allocate one unique directory per run, hand out every path through one function that records it, and
  remove it in `finally`** - `GcScratch` in guard-contract is the exemplar. Create it with `-ErrorAction Stop`
  so a clash refuses rather than shares, and keep the name short: every character lands on every fixture path,
  and PS 5.1 stops at 260. A name deliberately shared ACROSS runs, like the journal a killed run's successor must
  find, stays fixed on the production path and is redirected inside the self-test. **To measure it, isolate
  `TEMP` per batch directly under the real `%TEMP%`**: a root inside the session scratchpad put the fixed probe
  at exactly 260 characters and every arm went red for the harness's reason, not the code's.
  **A rule in a file is not a block**, so `ops/audit-fixed-temp-names.ps1` holds this at push time: a ratchet over
  the PowerShell AST, wired into `run-gates`, counting a `Join-Path`, `[IO.Path]::Combine`, `"$env:TEMP\..."` or
  `+` chain under a temp root whose leaf spells text and holds no `[guid]::NewGuid()`, `$PID` or
  `New-TemporaryFile`. An absence probe passed straight to a Get-, Read- or Test- command is LISTED and not
  counted, because two runs that only read an absence cannot collide. Its first run listed five fixed names that
  no rule had named, among them `meal-prep/pipeline/feed-freshness.ps1`'s `ff-clobber-probe.ps1`, the
  guard-contract shape copied into another suite. Run it for the list rather than quoting one.
  **That one is now fixed and the mark is 10** (2026-09-11, after a pre-push `run-gates` went red on it at 18:30
  while the same file at the same commit passed standalone a minute later). Measured before and after with 6
  writers released together on a kernel event inside each writer, 10 rounds per arm, arms alternating round by
  round, `TEMP` isolated per round: **red in 29 of 60 writer runs before, 0 of 60 after**. **The half worth
  keeping is that only 10 of the 29 named a case** - the other **19 printed no verdict line at all**, because
  `Set-Content` on the contended path throws *"Stream was not readable."* or *"cannot access the file ... used by
  another process"*, and under a suite's `EAP='Stop'` that is TERMINATING: the suite dies mid-run and reaches
  run-gates as a bare `exit 1` with a line count and no case. **So a self-test red that names no case is a
  concurrency suspect, not a mystery.** Of the two fixed names left, both are robocopy `/MIR` fixture trees
  (`test-precedence-ladders`, `run-test-guards-weekly`) and are the same shape at tree scale - `/MIR` deletes what
  the source lacks, and real scripts execute from inside. `test-auditors`' shared `%TEMP%\lib` left that list on
  2026-09-11: each run copies every `lib\*.ps1` into its own root, and unit u142 names a missing or stale one.
  **The oracle's arm logs left it on 2026-09-12**: `ops/consistency-oracle.ps1` keeps both arms and both arms'
  logs in one root per run and removes it in a `finally`, which also ends the two sandboxes every run leaked.
<a id="og-39"></a>
- **A child a gate spawns must not write a TRACKED path, and a tracked file written under PS 5.1 must be
  written LF** (2026-09-11). `test-auditors`' early `spec-live` child ran `audit-spec-contradictions`, which
  wrote the committed `meal-prep\out\spec-contradictions.json` through `ConvertTo-Json | Set-Content -Encoding
  UTF8`. Under PS 5.1 both halves write CRLF over an `eol=lf` blob, so every full pre-push run left the pushing
  checkout ` M` with a ZERO-line `git diff`, and the post-push `git rebase origin/main` refused. Both repairs
  were needed. The writer now emits the committed bytes and skips an identical write. Read the blob's BOM with
  `git cat-file` to a file: `Format-Hex` on a decoded string hides it, and this blob has one. The gate also
  passes `-ReportDir` to a temp directory, because LF bytes cannot stop a run over a DIFFERENT catalogue from
  rewriting real content. **Verify by bytes: `git status --short` empty and a CR count of 0.** Measured the
  same day: a CRLF rewrite of unchanged content (169 -> 174 bytes) read ` M` with zero diff lines, and the same
  LF bytes written back with a new mtime read clean.
  **Moving a write into a helper can hide it from a source-text ratchet, which then records a FALSE
  improvement.** Here `audit-write-only-reports` read 41 -> 40 twice, once for the helper verb and once
  because the new self-test spelled the report path next to a `Test-Path`, and each time it wrote the lower
  baseline. Compare the family NAMES against the committed baseline, not the count.
  **The class was swept the same day.** `ops\count-tracked-writers.ps1` is the census (PowerShell AST over every
  tracked `.ps1`, paths resolved through assignments, UNSOUND for any computed path; run it for the count). At
  5d1968736 it read 1,042 `Set-Content`/`Add-Content`/`Out-File`/`>` sites over 746 scripts, 911 resolved and 324
  matching a tracked file; 3 of the 1,042 pass `-NoNewline`, so the rest write CRLF. Its first cut counted depth per
  AST node, never resolved a `$here = if ($PSScriptRoot) ...` root, and read 382 on the same tree: a number that
  moved because the tool was wrong, not the tree. The 13 inside scripts `run-gates` runs live now write through `lib\lf-write.ps1`
  (`Write-TcLfFile`: LF, one trailing LF, BOM unless `-NoBom`, identical bytes skipped), each verified against
  its blob. **A plain run of a gate ratchet does not rewrite its tracked baseline**: `audit-write-only-reports`
  states a fall and keeps the committed mark, and `-Tighten` records it. The next change read the other nine:
  seven wrote on a plain run (`arg-binding`, `source-comment-strip`, `fact-claims`, `ruling-drift`, `write-seam`,
  `full-path-excludes`, `conclusion-currency`) and now take the same rule, each with the three live-path cases;
  `measurement-provenance` and `cross-module-reach` write only under `-UpdateBaseline`, so neither could dirty a
  gate run; `measurement-provenance`'s CRLF writer folds to LF in that change, and `cross-module-reach`'s went to
  `Write-TcLfFile` in 5b4cc0982. The bot-owned data writers, archive and fixtures were left alone.
  **A typed parameter keeps its type**: `$json = '...'` in a script that declares `[switch]$Json` throws, because
  variable names are case-insensitive. It broke `audit-fact-claims`' tighten in this sweep, and only running
  that path showed it. It recurred the same day as `$rule = @(...)` beside `[string]$Rule` in a new self-test helper,
  where `.Count` read 1 and a case passed over nothing, so **`ops/audit-typed-param-shadow.ps1` holds it at push
  time**: a ratchet over the AST that reports a value whose KIND changes on the way into a typed parameter (an array
  into `[string]`, a string into `[switch]` or `[bool]`, `$null` into `[string]`). A same-kind reassignment is legal:
  in the 2026-09-11 census, 485 of 507 assignments to a typed parameter's name were default fills or read the
  parameter they replace. Its first live site was `golden-test.ps1`'s `$structural = @(...)` beside
  `[switch]$Structural`, which threw on every `-Provenance -Force` run. Run it for the count rather than quoting one.
  **Python text mode on Windows writes CRLF too, and a DEFAULT path is a write nobody sees.** `fdc_lookup.cache_write`
  opened the tracked `meal-prep\db\fdc-cache.json` in text mode, and `hunt-daemon.py --selftest` reached it through
  the daemon's real fill with the default path: traced 2026-09-11 at 36 writes from 36 map-lane fixtures in one
  battery, each flipping 41,527 line endings, and from a checkout holding `db\fdc-api-key.txt` (the main one does)
  each fill was also a live api.data.gov call. The writer now passes `newline="\n"` (the blob round-trips
  md5-identical) and skips a fill that added nothing; the suite points `CACHE_FILE` at scratch and runs keyless for
  EVERY fixture, as `LEARN_SCRATCH` does, and `_fdc_seams_are_never_live` asserts both. **When code under test writes
  a tracked path by default, redirect the default suite-wide, never per fixture.** `count-tracked-writers` does not
  see Python, so Python text-mode writers of tracked files were not counted.

<a id="og-40"></a>
- **The gate worker slots are handed out in ARRIVAL ORDER, and a green verdict is not earned twice** (2026-09-11).
  Measured at 16:39 that day: 27 `run-gates` live, 8 of them holding all 10 slots at width 1 or 2, 19 holding
  nothing, and 24 kept pre-push logs between 15:08 and 16:35 ending in exit 3 after the full 1,200 s - the red that
  teaches `--no-verify`. A probe of `Enter-TcGateSlots` (one slot, 8 waiter processes 400 ms apart, 3 rounds) served
  the FIRST arrival 6th, 8th and 5th of 8, with 19, 13 and 15 of 28 pairs out of order against a random average of
  14: polling `WaitOne(0)` is a race, not a queue. `lib\gate-slots.ps1` now gives each waiter a TICKET, hands slots
  to the oldest LIVE one, refuses only when the count ahead has not fallen for `WaitSec` (so a long queue that moves
  is waited out, and a wedge is still a loud 3), stops a holder topping up past a run that holds nothing, and keeps
  deliberate load from jumping the queue. **A ticket's liveness is its MUTEX, never its file**: a killed waiter's
  ticket is swept by the next probe, while a frozen-but-alive one wedges the queue into a refusal rather than a pass.
  `lib\gate-verdict.ps1` records a run that exits 0 against a fingerprint of the HEAD tree, every `git status` entry
  and the BYTES of every script discovery walked - so an ignored script and a line-ending flip both move it - and the
  next run in THAT checkout over identical content prints the pass instead of running 362 gates again (`-NoReuse`
  overrides; a red run over that content withdraws it; an ignored input that is not a script is outside the
  fingerprint, which is why reuse is same-checkout and time-limited). `lib\push-landable.ps1` refuses a push whose
  refs the remote has already moved past, before it queues, because git fixes a push's refs when it connects: about
  half that day's completions were a session's own run rather than a push, and 34 scratch files carry a push to main
  rejected because main had moved. **The pool is still not stopped mid-flight** when a push becomes doomed after
  dispatch, which is the largest waste left. `design\MEASURE-gate-slot-starvation-2026-09-11.md` has every number
  and what was deliberately not done.
  **FOUR SESSIONS FIXED THIS ON THE SAME DAY AND THREE OF THE FIXES WERE THROWN AWAY WITH THEIR EVIDENCE**
  (folded in 2026-09-12). Only `b1aab0424` landed; the other three branches each carried a working queue, a
  measurement and an observer, and conflicted in the same two files. **The code was the cheap half and the
  measurements were the expensive half**, so the fold kept every number and re-landed no second queue. What the
  others knew that the winner did not:
  - **ORDER DECIDES WHICH PUSHES ARE REFUSED, NEVER HOW MANY.** A held slot is running a gate 99 to 100% of the
    time it is held, so this box does about **41 run-gates an hour**, and **a queue longer than about 14 cannot
    clear inside a 20-minute wait whatever the order**. No arrival-order change adds a run to that figure. The
    levers on capacity are the gate work per run, the slot budget (10 when this was measured, 24 since 2026-09-12 in
    39be9900e, so the 41 an hour is a figure at 10), and how often sessions push, and the queue
    touches none of them. `design\MEASURE-gate-queue-live-sampling-2026-09-11.md`, the best live sampling of the
    four. **State that bound beside any fairness fix**, or the fix reads as a throughput fix and the next person
    measures it against a number it was never going to move.
  - **EVERY LOCK PATH DEGRADES TO THE DAY BEFORE, AND THAT NOW INCLUDES THE QUEUE.** `New-TcGateTicket` threw when
    it could not create or write the queue directory, straight out of `Enter-TcGateSlots`, into a `run-gates` that
    runs under `EAP=Stop` and a `pre-push` under that: one stray file, one full disk or one permission change and
    every push on the box is a could-not-evaluate. The rule the push lock already followed had not reached the
    queue. A ticket that cannot be written now returns `$null`, the run waits **out of turn** exactly as it did
    before there was a queue, and carries the reason in `.QueueBroke`. It still takes only FREE slots, so the
    budget is untouched and the degraded run is gated no less. **A run that cannot join the queue must also stop
    DEFERRING to it**, or it is passed over for as long as the line keeps moving, which is a livelock and a worse
    refusal than the one being avoided.
  - **A SUITE WHOSE CASES ARE A LITERAL LIST ASSERTS HOW MANY RAN.** This is the counterpart of the discovered-set
    rule above: a literal list knows its own number, so a shortfall is a defect rather than a smaller tree. One
    branch printed PASS with a case never reached because a fixture variable `$pS` IS `$PS` - PowerShell names are
    case-insensitive - so it overwrote the powershell.exe path and every child after it failed to start.
  - **AND A FIXTURE NAME CLAIMED TWICE PASSES AGAINST A MACHINE NOBODY IS HOLDING.** A name is the stem of a
    fixture's `.ready` and `.release` files, so the second claimant reads the first's stale ready file and finds a
    release that already says go: its holder frees the slots at once and the case asserts nothing. Two names were
    doubled folding these branches in, and the case that caught it read `got=1` where it should have read 0. The
    fixed-temp-name rule below is the same trap one scope out. `lib\gate-slots.ps1` now claims each name once and
    THROWS on a reuse, because the quiet version looks exactly like a pass.
  - **AND THE REUSE NUMBER THAT LOOKS LIKE A VERDICT ON `gate-verdict` IS ABOUT A DIFFERENT QUESTION.** One branch
    measured reuse at **0 runs saved** and rejected it: over 2026-09-11 the shared repo's `origin/*` reflogs hold 42
    push updates carrying 39 distinct trees, and the three trees pushed twice were each one `git push` updating two
    refs, so one hook run. That is keyed on **the same tree pushed twice**. `lib\gate-verdict.ps1` is keyed on a
    hand `run-gates` followed by a push **in the same checkout**, which those reflogs say nothing about, and it
    fingerprints raw script bytes rather than a tree hash precisely because a tree hash cannot name what run-gates
    read. Same shape as `identity-graph-commodity-is-namespaced`: an agreeing number about something else. **How
    often a hand run is followed by a push of identical content in the same checkout is still unmeasured by
    anybody**, and it is the number gate-verdict's value actually turns on.
  Three read-only observers survived and are on main, uncalled on purpose and censused:
  `ops\probe-gate-slot-admission.ps1` and `ops\report-gate-slot-admission.ps1` answer who got each freed slot,
  `ops\observe-gate-queue.ps1` answers how long the line is and who is in it. The rejected head-takes-one design is
  `design\PLAN-gate-slot-fair-admission-2026-09-11.md`, kept so it need not be re-derived; the whole ruling, with
  what was deliberately NOT folded in, is `design\PLAN-gate-slot-consolidation-2026-09-12.md`.
<a id="og-41"></a>
- **A statement keyword written after a command is an ARGUMENT, and a gate run must leave nothing where the bot
  stages** (2026-09-11). `grocery/pull-grocery-ads.ps1` put its self-test verdict after its last case on one line,
  `_T '<label>' (<cond>)  if (...) { exit 0 } else { exit 1 }`. PowerShell read `if`, the condition and both blocks as
  arguments to `_T`, so from 8253ded82 every `-SelfTest` exited 0 whatever its 21 cases said, fell through into the
  LIVE ad pull, and wrote `grocery\out\ads-<today>.json` from every push's gate, a path `capture-run` stages whole.
  `ops/audit-keyword-arguments.ps1` fails the shape (one command in 747 tracked scripts, so not a ratchet), and
  `lib/gate-leftovers.ps1` snapshots the bot-staged paths around `run-gates`' pool and fails a LINKED worktree whose
  pool changed a file there; the main checkout, where capture lanes write, prints REVIEW. It watches that pool only:
  `prepush-test-auditors` runs after it and outside it.
<a id="og-42"></a>
- **A typed backslash-n is two characters, never a line break, and a case in a comment never runs** (2026-09-23).
  The 2dae07 edit joined two self-test cases onto a line of `grocery/audit-match-soundness.ps1` that began with `#`,
  with a literal backslash-n between them; neither case ran and the suite printed PASS until 8847c9fa5 (founding blob
  8b8320d27, line 708). `ops/audit-literal-newline-escape.ps1` holds it at push time over the TOKENS, never the text: a
  bareword that begins or ends with the escape, a line comment where the escape is followed by what reads as a new
  source line, and a line comment carrying a `T 'MUST FIRE ...' (...)`-shaped case call. Strings, regexes and block
  comments are never read; prose about line endings is listed, not counted. Zero sites on day one over 839 scripts, so
  a gate at zero, not a ratchet. **Its pair is the literal-list rule above: a suite's own count catches a lost case of
  ANY shape**, which is why `audit-match-soundness` now asserts its 62.
<a id="og-43"></a>
- **A comma binds tighter than `-and`, so a case body `a -and b, 'got'` never judges b** (2026-09-23). It parses as
  `a -and (b, 'got')`, a two-element array is always truthy, and the case passes whatever b says: 28 case bodies in
  `ops/rehearse-chain.ps1` (founding blob 17170b387). Write the verdict in parentheses, `((a) -and (b)), 'got'`.
  `ops/audit-and-comma-case.ps1` holds it at push time over the AST: a `-and`, `-or` or `-xor` whose right operand is
  an unparenthesised array literal, inside a self-test span or a labelled case call's arguments. A gate at zero outside
  one named pin (`rehearse-chain`, while its own lane lands the rewrite); a fixture that executes the shape on purpose
  carries `# and-comma-case:allow <reason>`. Its pair is a case harness that refuses a body not returning exactly
  (verdict, got), which rehearse-chain's now does.

<a id="og-44"></a>
- **A RULING PUSH IS RED ON PURPOSE, AND THE GATE ACCEPTS THAT RED ONLY WHEN THE PUSH CAUSES IT** (Brad's ruling,
  2026-09-19, "Teach the gate"). `ops/prepush-test-auditors.ps1` refuses a new failing test-auditors case, and the
  food-category and known-wrong live twins go red whenever a push adds a ruling against a product still on the board,
  which is the intended red. The next build, the only thing that clears it, builds from origin/main, which cannot get
  the ruling: a deadlock (found on `claude/gc-fence`, refused with exactly those two cases at run-gates pass=441 fail=0).
  So a new failing case whose Bad line carries `# live-board-ruling-case audit=<script>` gets a PAIRED RUN: the same
  audit on the same board (hardlinked into throwaway arms), rule files at the push's base, then at its tip, then
  ruling files at the tip over the rest at the base when a non-ruling rule file also moved. Accepted, and printed as
  `EXPECTED-LIVE-RED`, only when base is exit 0, tip is exit 2, and every tip finding is one the ruling files alone
  flag. Any exit 3, a base already red, an unrelated new case or an uncommitted rule edit refuses as before. Compare a
  working-tree file with a blob through `git hash-object`, never by bytes: a fresh checkout is CRLF over LF blobs. A
  stale worktree board is judged as it stands, so re-seed before pushing a ruling.
<a id="og-45"></a>
- **A KEYED SELF-TEST CAN STILL RE-RUN ON EVERY PUSH, when its key is too WIDE** (2026-09-24). `lib\gate-input-key.ps1`
  walks every declared `.ps1` like a loaded library, so declaring a file the suite only PARSES or COPIES drags in its
  whole closure: `lib\checkout-sync.ps1`'s key held 2,968 files (1,202 gitignored boards and cards) through one
  `grocery\capture-run.ps1` it AST-scans, and moved on 201 of 287 commits. A file read as text goes on a
  `# gate-inputs-text:` line: hashed, never walked, and refused if anything in the walk loads or runs it. Check a key's
  file list, not only `Ok`, and run `-VerifyDeclared` after any declaration change. **Two more roads in, closed the same
  day:** a DATA GLOB in a walked file (`'meal-prep\db\recipes\*.json'` in capture-run) was hashed under a declaration where a
  data literal was not, so eight suites keyed 585 to 2,210 boards and cards; it is now left out like the literal, and the
  GATE'S OWN data glob stays hashed (hunt-run's `-Init` fixture really lists the boards). And a file a library only WRITES
  goes on a `# gate-output: <path> read-by <functions>` line (`lib\event-bus.ps1`), which keeps it out of a caller's key
  unless something else in the walk names a reader or the file. A new reader of that file joins its `read-by` list.
<a id="og-46"></a>
- **A PUSH IS A COMPARE-AND-SWAP WHOSE CRITICAL SECTION IS THE WHOLE HOOK, so the SLOWEST push converges on never
  landing** (2026-09-11). git fixes a push's refs when it connects and the remote updates a ref only if it still
  holds the sha the hook was handed. Measured across 11 consecutive attempts from one session: the hook took 577 to
  1,840 s, **`run-gates` PASSED every time** (341 to 368 gates plus a 127 to 411 s test-auditors leg), and every
  attempt was rejected with *"cannot lock ref 'refs/heads/main' ... is at X but expected Y"* while other sessions
  landed every 15 to 25 minutes. That is optimistic concurrency control with no contention management, and green
  gates have nothing to do with who wins it. The retry is not free either: the session must rebase, a rebase is
  genuinely new content, so `gate-verdict` correctly declines to reuse the pass and every gate runs again.
  **Serialising costs no throughput, which is the objection to answer first:** `refs/heads/main` is ALREADY
  serialised, so today's parallelism is parallel GATING of which all but one result is discarded - N sessions each
  pay T and N-1 of those T are thrown away, and landings per hour are 1/T either way. `lib\push-lock.ps1` is that
  lock (the `gate-slots` queue at a budget of one, deliberately not a second copy of the arrival-order rules);
  `ops\hooks\pre-push` holds it across the gate through `ops\hold-push-lock.ps1`, because a mutex needs a live
  process and the hook's two PowerShell children each exit; `ops\push-main.ps1` takes it BEFORE it fetches and
  rebases, which is the only place a base can be guaranteed not to go stale, so that push lands on its first
  attempt. **SUPERSEDED, kept because the measurement above is of it:** that was the 2026-09-11 design. The gate left
  the lock on 2026-09-12 (CLAUDE.md, "THE GATE MUST NOT RUN INSIDE THE LOCK"), the hook now takes it for the ref update
  only, and since 2026-09-23 push-main takes it for the swap only and rebases OUTSIDE it (the next bullet). The base is
  still guaranteed fresh, now by the fetch inside the lock and the hand-back, never by a rebase under it.
  **Every lock path degrades to the behaviour of the day before, never to a refusal** - no holder script in
  an older checkout, a wedged queue, anything thrown, and the hook says so and pushes on. The lock is a FAIRNESS
  device and the gate is what makes a push safe, which is why a bypassed lock is not a hole in anything and why one
  that could refuse would be worse than the livelock. `design\MEASURE-push-lock-2026-09-11.md` has the numbers, the
  acceptance bars written before the run, and the first harness that was confounded by its own queue.
  **A CONSEQUENCE FOR EVERY SUITE, and it went red before it was understood: `run-gates` now often runs WITH THE REAL
  PUSH LOCK HELD** - `ops\push-main.ps1` takes it, then pushes, so the hook and every gate under it are descendants of
  the holder and inherit `TC_PUSH_LOCK_HOLDER`. The token therefore names the LOCK it was taken on and a mismatch is
  not an inheritance: while it was a bare `<pid>:<guid>`, every suite that redirects to a private `Local\` lock was
  handed `inherited` and believed it held a lock nobody had taken, and `hold-push-lock` and `test-prepush-hook` both
  failed the push for it. **A suite that reads ambient state a gate's own caller may be holding must say which
  instance it means** - the `identity-graph-commodity-is-namespaced` shape, an agreeing answer about something else.
  Drive such a suite once with the real lock held before believing it.
<a id="og-47"></a>
- **PUSH-MAIN FITS FIRST, RE-CHECKS WHAT MOVED, AND LOCKS ONLY THE SWAP** (2026-09-23,
  `design\PLAN-push-derived-conflicts-2026-09-23.md` W2.1R with W8.1, W2.2R, W9.4; design A, Brad's ruling that
  evening). `ops\push-main.ps1`'s own header is the full account; the shape, in order:
  1. **The pre-flight rebases BEFORE any leg.** One push-main per checkout (a zero-wait guard named from the worktree
     path); a fetch that retries once on `cannot lock ref`; a conflict read and refused in seconds with the files named,
     told apart from a rebase that could not start, and an abort that is checked; a branch the rebase empties refused as
     `refused-already-on-main`, never read as a landing; a dirty tree refused with its paths (at most 20) and
     `dirty_since=start` or `during-legs`; a rebase that brings a newer push-main re-executes onto it once. Then the seed,
     which refreshes what the source rewrote. A later red leaves the branch rebased, which is where it has to land anyway.
  2. **The legs run outside the lock**: run-gates, test-auditors, and the chain rehearsal for a chain-touching push.
  3. **Catch-up rounds, outside the lock**, at most `$script:PmMaxCatchUpRounds = 3`: one fetch after a round's legs;
     moved, rebase there (a conflict refuses, `phase=catchup`) and run the next round warm on each leg's own keys. The
     rehearsal budget (`$script:PmMaxRehearsalRounds = 3`) counts only rounds whose rehearsal REHEARSED, so cheap rounds
     never spend it, and at the budget the push is refused `refused-rehearsal-churn` (D11a, the rehearsal leg only: the
     hook never rehearses, so pushing into the lock without a covering verdict is a certain refusal there; run-gates and
     test-auditors still degrade to the lock, because the hook can run them again).
  4. **The lock holds the swap only.** Inside it, a fetch that only ASKS whether origin moved since the last outside
     round. Unmoved, `git push`, and the hook replays the recorded verdicts (about 25 s). Moved, the lock is HANDED BACK
     with no rebase under it, the next round rebases and re-runs outside, and the lock is taken again, at most
     `$script:PmMaxHandBacks = 3` times. At the cap it rebases inside the lock with the in-lock verdict check as the
     backstop, which is the day before, so the rule cannot livelock and never refuses. A hand-back spends the rehearsal
     budget only when its rehearsal leg rehearsed. The cap of 3 is the first plausible value, not a swept one.
  **This is still the 2026-09-12 ruling, not an exception to it**: no lock is held across a leg. The chain lease (the
  plan's W6.1) would have held one and needed D8's named exception; design A replaced it before it was built, and D8 is
  superseded. **Two rules go with it (W7.1a)**, each from a measured refusal class: run board steps, guards and
  reconcilers in a scratch clone, never in the checkout you land from (row 50 of the plan's case list: a lane's own
  `reconcile-ghost-drift` wrote `grocery/ghost-tool-published.json` while its legs ran, `dirty_since=during-legs`); and
  land a chain change only through push-main, never `git push origin HEAD:main`, with every orchestrator brief saying so
  (6 of 17 chain landings after the rehearsal gate were plain pushes from one orchestrator's lanes, and one of them,
  `855171a1e`, voided a rehearsal another push was relying on). From the main checkout,
  push-main lands through a throwaway worktree by itself (W8.2, the paragraph that closes the next bullet).
  **The rest of design A landed the same day (2026-09-24)**; each item's own commit and script header is the account.
  The lock order paragraph above carries `0a`, `0b` and `2b`, and `2a` below.
  - **Commit-time rehearsal** (W9.1, D19 ruled yes). `ops/hooks/post-commit` starts `push-main -Prepare` detached under
    `CLAUDE_CODE_SESSION_ID`, never inside a rehearsal (`TC_REHEARSAL_RUN`), never for the commits a rebase replays, and
    never fails a commit; `-Prepare` fetches and starts `rehearse-chain.ps1 -Early -Onto <origin sha>`, which rehearses
    HEAD rebased onto origin as it stood at commit time, and a later commit that moves the key supersedes it through a
    stop file. An early run first takes one of `$script:RhEarlyMaxSlots = 4` early caps (`Global\tc-rehearsal-early-`,
    lock order `2a`, always before its rehearsal slot), so 2 of the 6 slots stay for pushes. **The rebase is the design,
    not an optimisation**: over 23 chain landings on 2026-09-23 the rebased variant would have covered 10 (43%) and the
    unrebased one 6 (26%), against a 30% bar written before the run; B22 re-measures it live on push-main landings,
    from the row's `early_hit`, which reads the `early=yes|no` token on rehearse-chain's check marker.
  - **The legs start together** (W9.3, absorbing W2.3). The rehearsal starts beside run-gates, then test-auditors runs,
    and a red leg writes the stop file so the rehearsal ends `blind=stopped` and the push refuses `refused-gate-red`
    without waiting up to about 14 minutes. No process holds one pool while waiting on the other.
  - **The chain queue** (W9.2, replacing W6.1's lease). A chain-touching push, `-NoRehearsal` included, takes an
    arrival-order ticket (`lib\chain-queue.ps1`, on `lib\gate-slots.ps1`'s ticket functions, never `Enter-TcGateSlots`),
    and its rehearsal judges HEAD stacked on the ranges of the live tickets ahead, in the rehearsal's clone only: the
    worktree is NEVER rebased onto another ticket's commits. It waits for the tickets ahead to land or leave before its
    swap, holding nothing but its ticket, and a ticket ahead that leaves makes it restack and rehearse once more.
    **ORDER, NOT CAPACITY**: its ceiling is 6 rehearsal slots over an 800 to 1,240 s rehearsal, about 17 to 27 chain
    landings an hour (review, SCRATCH); its cost is head-of-line, up to about 21 minutes. `-ChainQueue off` is the
    rollback.
  - **The pre-push queue-head check** (W8.3, amended). Right after the rehearsal record check and before run-gates, a
    chain-touching push whose `TC_CHAIN_QUEUE_HOLDER` does not name the queue's head is refused in seconds with
    `PRE-PUSH-REFUSED cause=chain-queue` while any live ticket that has not landed or left exists. A head whose record
    has not changed for longer than the library's own stall bound is WEDGED, and the push proceeds, because the queue's timed-out
    waiters push unqueued. It probes with ZERO wait and acquires nothing, so the hook never waits on the queue and no
    wait-for edge is added.
<a id="og-48"></a>
- **A LANE WRITES ONLY WHAT IT OWNS** (2026-09-23, W3.1, W3.3, W4.1 of the same plan). A file several lanes append to,
  or one derived from the whole tree, is a conflict factory: **20 of 22 push-main rebase conflicts conflicted ONLY on
  shared append-shaped or derived files, and 14 of the 22 named `design/BACKLOG-course-findings.md`** (a row can
  name more than one file: 5 named the ready-for-brad README and 2 named re-read lines in MEASURE docs). The other 2 were
  genuine code, and those must never be auto-resolved.
  20 of the 22 also came from one session's parallel lanes on 09-18 and 09-19, so the rate is a busy-day rate. So:
  - **Backlog progress is an inbox UPDATE**, a new file under `design\backlog-inbox\updates\`, never an edit of the
    backlog itself and never an edit of an existing `updates\` file. The merge (`ops\merge-backlog-inbox.ps1`, one
    allocator) folds it in; a new finding is its own top-level inbox file and claims no id. `design\backlog-inbox\README.md`
    has the format.
  - **A re-read is a ledger row**, written by `ops\add-reread.ps1` into `design\reread-ledger.tsv`, which git merges by
    union, never a `Re-read at` line added to the doc (`.claude/rules/measurement.md` has the command).
  - **A ready-for-brad item is its own file** under `design\ready-for-brad\`; the README is an explainer and carries no
    item.
  push-main's pre-flight counts each of the first two shapes and WARNS (`backlog_direct`, `inbox_invalid`,
  `inbox_updates_modified`, `reread_doc_lines` on the row). None refuses yet. Brad ruled D3 yes: from a literal cutoff
  one week after W3.1 and W4.1 landed (both 2026-09-23), a push that edits the backlog directly or adds a re-read as a
  doc line is to be refused. That refusal is not built when this is written.

  **A session in the MAIN checkout lands with `ops\push-main.ps1` too, which goes through a throwaway worktree by itself**
  (2026-09-23, W8.2): a plain push from the main checkout is the one road left that races the whole hook, and 11 of 82
  main-checkout pushes that passed every hook check since 09-16 were then rejected. The throwaway runs the whole sequence,
  the main checkout is never rebased, and local main is moved to the landed tip by `git reset --keep` only when HEAD did
  not move meanwhile. It adds no lock. A plain push is the fallback, and it is still fully gated.

## The words these rules were written without `[2026-09-12, backlog I102, I103, I118, I120, I135]`

Every rule above was derived here, from an incident, without the vocabulary that names it. That was
not a mistake - the scar tissue is worth more than the theory - but the names buy three things the
incidents could not: they say which of two failures you are looking at, they say what the OTHER
failure mode of your fix is, and they turn "how much isolation does this need" into a question with
enumerated answers. None of the following is a gate, and none of it asks for a sweep.

<a id="og-49"></a>
- **`starvation` and `deadlock` each mean two or three different things in this tree, and nothing
  said so.** Measured 2026-09-11 over first-party `.ps1`, `.py` and `.md`, and **the test is stated
  with every number because two greps disagreed and not one word of the disagreement was about the
  tree** - all of it was about which test was meant, the `compare-deals` shape from
  `.claude/rules/grocery.md`. `starvation` alone, excluding `grocery/out/`, `archive/`, `.claude/`
  and `.venv`: **13 files**, of which 7 are the gate-slot SCHEDULING sense. Including `starved`,
  `.claude/rules/` and `archive/`: **26**. `deadlock` on the same filter as the 13: **71**. Say which
  sense you mean, the way `cohort` in the grocery rules has to.
<a id="og-50"></a>
- **A blocking lock can DEADLOCK and cannot livelock. A `tryLock`-with-retry can LIVELOCK and cannot
  deadlock.** A timeout does not remove a hang; it converts a deadlock into a livelock, where the
  threads are responsive and still finish nothing. This sharpens the timed-lock-wait rule above by
  one step that rule does not reach: **the refusal branch must RELEASE what it already holds before
  it loops.** A retry that keeps its resource while spinning is strictly worse than blocking, because
  it holds the thing everyone else is waiting for and makes no progress itself. And the real fix is
  neither construct: **break the symmetry** - a deadlock needs a cycle in the who-waits-for-whom
  graph, so having one participant acquire in the opposite order removes the cycle and no timeout is
  needed. `lib\gate-slots.ps1` already does the equivalent by serving the oldest live ticket.
<a id="og-51"></a>
- **Write the POINTED-TO object before the object that points to it.** Data before the inode, the
  file before the directory entry naming it, the artefact before the row claiming it exists. Every
  interruption then leaves an object nothing refers to yet, which is a **leak**, and never a
  reference to an object that is not there, which is **corruption**. Those are not equally bad, and
  the ordering is the whole of what chooses between them. Two incidents here are this one rule and
  were each recorded as neither: `[[repairs-that-never-reach-a-commit]]` (*"commit the source WITH
  the artifact"* - the artefact is pointed-to, the commit is the pointer), and the 2026-09-11
  `spec-contradictions.json` incident where a gate's child moved a tracked artefact without the
  reason for it moving. **When a change touches two files where one refers to the other, name which
  is the pointed-to object, write it first, and say so in the commit.** A detector cannot see this;
  the habit is the whole prevention.
<a id="og-52"></a>
- **State whether a retried operation is IDEMPOTENT, and what makes it so.** This is the estate's
  cheapest concurrency fix and almost no header claims it: of the nine `lib\*.ps1` that mention a retry
  (measured 2026-09-18, backlog I199), only `lib/append-line.ps1:18` said which, and since 2026-09-19
  `lib/ghost-lib.ps1`'s header does too, per HTTP method, because a replayed POST can mail the list
  twice (backlog I198). `lib/atomic-write.ps1` is the one that should and does not yet. It is better than the delivery guarantee it
  replaces: make a duplicate harmless and a lost request, a lost reply and a crashed-then-restarted
  server become indistinguishable and need no distinguishing, because retrying is correct in all
  three. The property is invisible at the call site and turns on small details - NFS's `WRITE` is
  idempotent only because the request carries the **offset**, and "append these bytes" would not be.
  **Two adjacent files in `lib\` are the two sides of it:** `Write-TcAtomicFile` replaces a whole
  file with a whole text and is **idempotent**, which is exactly why its retry loop is safe;
  `Add-TcLine` appends and is **NOT**, so a retry duplicates a line - which is why only its OPEN is
  retried and never its write. Every other retry in the tree is safe or unsafe for this reason and
  almost none of them says which.
<a id="og-53"></a>
- **The ledger WRITERS are serializable and the READERS are lock-free, and nothing says which
  decisions are safe at that level.** `lib/ledger-lock.ps1` puts the read inside the mutex, so a
  writer gets the strongest level there is and that is right for it. The readers get no level at all:
  `grocery/capture-policy-lib.ps1:62` states plainly that the store lanes read the cursor and
  `sale-windows.json` lock-free. In the isolation vocabulary that permits a **non-repeatable read**
  (two reads of one key in one pass disagree) and a **phantom** (a key appears mid-pass), and neither
  is a defect in the readers - it is a level, and the four levels are each DEFINED by the anomaly
  they still permit. **So the question to ask of a new lock-free reader is not "is this safe" but
  "which of the three anomalies can this decision survive".** A reader that samples one key once
  survives all three. A reader that compares two keys, or iterates and then acts on the count, does
  not.

Regime: this holds for gate and library code. Data-dependent audits live in the daily chain, not in
`run-gates`, and the split is deliberate - see `run-gates.ps1`'s own header.
