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
- **A catch around a native redirect is not a guard** (2026-09-11). Under `$ErrorActionPreference = 'Stop'`
  EVERY redirect of a native child's stderr (`2>&1`, `2>$null`, `*>&1`, `> log 2>$null`, a bare `git ... 2>&1`)
  makes its first stderr line a terminating throw, and `try { } catch { }` keeps the caller alive while throwing
  the child's answer away: one git warning read as an empty staged set in `verify-commodities-gate`. Fix with
  `Invoke-Native`/`Invoke-NativeScript` (`grocery\native-lib.ps1`), or `$prevEap = $ErrorActionPreference;
  $ErrorActionPreference = 'Continue'` as its own statement before `try { call } finally { restore }`.
  `grocery\test-native-stderr-eap.ps1` is the gate in `run-gates`: an AST scan of every `.ps1` below the root,
  ratcheted by named site. It reads the preference lexically, so a guard it cannot see before the call is a site.
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
  literals with doubled inner quotes. **The same trap inside an array literal:** in `@($a + 'x', $b)`
  the comma binds tighter than `+`, so it is `$a` plus a two-element array, one string, not two lines.
  A multi-line fixture built that way ran on one line on 2026-09-11 (`audit-cross-module-reach`).
  Assign each concatenated line to a variable first.
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
- **The `Get-Random` refusals cover WORK SELECTION, not TEST INPUT** (Brad, 2026-09-09, backlog I38).
  `Get-Random` appears in three files here and all three refuse it: a deterministic verification sample,
  a reproducible worklist, a retry jitter that uses the attempt index. **Each is right about what it
  refuses** - work that cannot be replayed. **None of them is an argument against a seeded test-input
  generator**, because a seeded generator is reproducible by construction: print the seed, re-feed it,
  and every case replays byte for byte, which is the exact property the deterministic-sample rule was
  protecting. `ops/probe-hostile-input.ps1` is the exemplar. It is a REPORT, not a gate.
- **PowerShell's `-ne` on strings is CULTURE-SENSITIVE, and culture-sensitive comparison IGNORES NUL**
  (2026-09-09, found by `probe-hostile-input.ps1`'s own must-fire). `('Bana' + [char]0 + 'nas') -ne
  'Bananas'` is **`$false`**, though the two differ in length. So the default operator is blind to
  exactly the corruption class a parser probe exists to find, and the first version of that probe
  reported two real malformations as no-ops because of it. **Compare with
  `[string]::Equals($a,$b,[StringComparison]::Ordinal)` anywhere the text might carry damage.** This is
  the same family as the `[StringComparer]::Ordinal` hashtable trap in `ops/consistency-oracle.ps1`: a
  bare `@{}` is case-insensitive and a bare `-ne` is culture-sensitive, and both defaults are wrong for
  data that arrived from outside.
- **A detector's header says what its CLEAN report MEANS** (2026-09-08, backlog I66). A static analysis
  must approximate, and the direction decides what a verdict is worth: a **sound** one never misses a
  real defect, so a clean report is trustworthy; an **unsound** one stays quiet, so a reported defect is
  real and **a clean report proves nothing**. Almost every detector in `ops/` is a pattern matcher over
  source text and is therefore unsound by construction - it finds the spellings it knows. That is not a
  defect in any of them; reading their clean reports as proofs is. Every `ops/audit-*.ps1` now carries a
  `SCOPE OF A CLEAN REPORT:` line saying which it is (7 of 22 already did, in their own words; 15 were
  silent). **A new detector owes that line the way it owes its `<NAME>-COMPLETE` marker.**
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
  bytes do not change.
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
- **A self-test can run ZERO cases and exit 0** (2026-09-11). A helper named `R` resolved to the built-in alias
  for `Invoke-History` before the function, every case line errored non-terminating, and the suite printed PASS
  over nothing. Aliases beat functions, so never name a helper `r`, `h`, `gc`, `ls` or any other alias; and run
  the cases under `$ErrorActionPreference = 'Stop'` inside a try whose catch is a counted failure.
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
- **A sandbox that runs a real script copies the WHOLE `lib\`, and a library the script cannot load is exit 3**
  (2026-09-11). `ops/test-prepush-hook.ps1` copied `prepush-test-auditors.ps1` with a hand list of two libraries
  older than `lib/git-repo-env.ps1`. Under `Continue` the dot-source printed "is not recognized" and carried on,
  the hook sends that script's stderr to `/dev/null`, and all 26 cases passed while its `Clear-TcGitRepoEnv` never
  ran. The sandbox now copies every `lib\*.ps1`, and the check loads each library under `Stop` inside a try that
  exits 3. try alone catches a missing file, a parse error and a throw; an error WRITTEN while loading needs `Stop`.
  Hand-listed library copies still standing, not swept: `grocery/send-alert.ps1`, `grocery/triage-close.ps1`,
  `grocery/test-auditors.ps1` and `meal-prep/pipeline/wave-preaudit.ps1`. Unguarded dot-sources elsewhere were
  not counted.
- **Under PS 5.1 `VariablePath.UnqualifiedPath` is INTERNAL and reads as `$null`** (2026-09-11). An AST walk
  that used it as a hashtable key threw, which is the lucky case; the same value in a `-match` matches nothing, so
  a walk that collects variable names finds none and returns an agreeing empty. Strip the scope from `UserPath`
  instead: `Get-SelfTestVariableName` in `lib/selftest-lib.ps1`.
- **A self-test the census cannot find can lose its must-fires and stay green** (2026-09-11). `ops/audit-mustfire-census.ps1`
  and `ops/audit-fixture-inputs.ps1` read only the bodies `Get-SelfTestBlock` in `lib/selftest-lib.ps1` returns: an
  `if` gated on a self-test switch or a copy of one, the code after `if (-not $SelfTest) { ...; exit }`, a function
  named `Invoke-<name>SelfTest`, and a whole file NAMED `test-*.ps1` that reads no self-test switch. Measured that
  day, 17 files and 230 must-fire lines sat outside every shape the census then read, 65 of them in
  `grocery/test-auditors.ps1`. **Open a new suite in one of these shapes.** Fixtures run from a function with another
  name (`Invoke-NamesFixtures`), or behind a guard that ends in a try rather than an exit, are still invisible.
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
  check `Get-ScheduledTask` before saying it runs. **Not every red under load is a
  clock:** the two concurrency-fixture reds the same day were lost writes, the mutex rule above.
- **A timed lock wait is a BRANCH, and an append is not a locked write** (2026-09-11). `grocery/send-alert.ps1`
  stored `WaitOne(10000)`'s answer and never read it, so a timeout rewrote the whole triage queue UNLOCKED over
  the writer that held the lock, and `grocery/triage-close.ps1` never took the lock at all. Every other `WaitOne`
  in the tree already refused on `$false`. **The timed-out branch needs a MUST FIRE, and a clock cannot give it
  one:** `lib/mutex-hold.ps1` holds a fixture mutex from ANOTHER PROCESS until released, so the wait times out
  however loaded the box is, and a fixture never holds a live name. The spool that branch lands in had its own
  hole: **a bare `Add-Content` loses lines to a concurrent appender** - 13 of 200 landed with two processes, 5 of
  1,200 with four, every failure *"Stream was not readable."* A file several processes append to goes through
  `lib/append-line.ps1` (`Add-TcLine`: append-only rights, shared ReadWrite, one write), which landed 1,200 of
  1,200. Other concurrent appenders were NOT swept; `lib/event-bus.ps1`'s `StreamWriter` opens with the same
  writer-denying share and was not measured.

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
  states a fall and keeps the committed mark, and `-Tighten` records it. Five other gate ratchets still write
  their baseline on a fall (read, not changed), and four that write through `WriteAllText` were not checked. The bot-owned data writers, archive and fixtures were left alone.
  **A typed parameter keeps its type**: `$json = '...'` in a script that declares `[switch]$Json` throws, because
  variable names are case-insensitive. It broke `audit-fact-claims`' tighten in this sweep, and only running
  that path showed it. It recurred the same day as `$rule = @(...)` beside `[string]$Rule` in a new self-test helper,
  where `.Count` read 1 and a case passed over nothing, so **`ops/audit-typed-param-shadow.ps1` holds it at push
  time**: a ratchet over the AST that reports a value whose KIND changes on the way into a typed parameter (an array
  into `[string]`, a string into `[switch]` or `[bool]`, `$null` into `[string]`). A same-kind reassignment is legal:
  in the 2026-09-11 census, 485 of 507 assignments to a typed parameter's name were default fills or read the
  parameter they replace. Its first live site was `golden-test.ps1`'s `$structural = @(...)` beside
  `[switch]$Structural`, which threw on every `-Provenance -Force` run. Run it for the count rather than quoting one.

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

Regime: this holds for gate and library code. Data-dependent audits live in the daily chain, not in
`run-gates`, and the split is deliberate - see `run-gates.ps1`'s own header.
