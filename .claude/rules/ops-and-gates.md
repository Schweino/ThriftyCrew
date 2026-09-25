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

**HOW THIS FILE IS WRITTEN** (Brad, 2026-09-25, design/PLAN-rules-trim-2026-09-25.md). Every agent re-reads this
file on every call, so it holds each rule's OPERATIVE text only: what to do, what not to do, and the tool that does
it. The measurements, dates and incidents behind a rule live in `docs/rules-history/ops-and-gates.md` at the anchor
its tag names (`full: og-NN`), word for word. Every rule ends with a tag naming its channel: `gate <path>` when a
push gate enforces it (the gate refuses a violation even if this text is missed), or `judgement` when nothing but
this text carries it. A NEW rule follows the same shape: one bullet, the rule and its instruction, the tag, and its
story in the history file or a memory, never here. `ops/audit-rule-format.ps1` refuses a push that breaks this.

- **Read the EXIT CODE first and the tally second**, and do not decode the number: three vocabularies are live at
  once and the same `2` means "hard defect" in one family and "never ran" in another. Read the verdict LINE.
  [[exit-code-first-tally-second]] (channel: judgement; full: og-01)
- **A detector owes a `<NAME>-COMPLETE` marker as its LAST line** (`lib/guard-contract.ps1`). Without it "no
  findings" and "died halfway" are indistinguishable. (channel: judgement; full: og-02)
- **A self-test that greps its own source cannot fail.** Build needles by concatenation, and never let a detector
  scan itself. [[selftest-greps-its-own-source]] (channel: judgement; full: og-03)
- **A catch around a native redirect is not a guard.** Under `$ErrorActionPreference = 'Stop'` every redirect of a
  native child's stderr (`2>&1`, `2>$null`, `*>&1`) makes its first stderr line a throw, and a surrounding catch
  throws the child's answer away. Use `Invoke-Native`/`Invoke-NativeScript` (`grocery\native-lib.ps1`), or set
  `$ErrorActionPreference = 'Continue'` as its own statement before `try { call } finally { restore }`.
  (channel: gate grocery/test-native-stderr-eap.ps1; full: og-04)
- **Three fixture labels, three jobs** (Brad). `MUST FIRE`: the founding bug, the detector flags it. `MUST NOT
  FIRE`: a legal input, the detector is silent (the negative assertion). `CLEAN TWIN`: an adjacent behaviour that
  still works, a POSITIVE assertion of what your fix was most likely to break.
  (channel: gate ops/audit-fixture-vocabulary.ps1; full: og-05)
- **A threshold or count detector's self-test carries a case exactly AT its bar and one a step PAST it**, naming
  the bar in the case text (Brad's ruling). The step is one unit of the comparison's own resolution. Build the
  at-bar case from BINARY-EXACT numbers (halves, quarters, integers), or floating point decides it; never widen a
  real tolerance to make a fixture's arithmetic pass. (channel: judgement; full: og-06)
- **A fixture built by string concatenation is not one argument.** `Test-Thing "a" + "b"` passes three arguments,
  and in `@($a + 'x', $b)` the comma binds before `+`. Write fixtures as single-quoted literals, or assign each
  concatenated line to a variable first. (channel: judgement; full: og-07)
- **Never wrap a function call inline as `@(Get-Thing ...)`.** A comma-returned array reads as ONE element. Assign,
  then wrap. [[ps-json-array-collapse]], [[ps-null-count-is-one]] (channel: judgement; full: og-08)
- **`@($v)` THROWS when `$v` came from `New-Object ...List[object]`**, even empty, and the error points at the
  enclosing expression. Build it with `::new()`, use `.ToArray()`, or another element type. A fixture that executes
  the wrap on purpose carries `# list-array-wrap:allow <reason>`. [[ps-list-object-array-wrap-throws]]
  (channel: gate ops/audit-list-array-wrap.ps1; full: og-09)
- **Under `powershell -File`, `-Count 1,2,4,8` into an `[int[]]` binds as the ONE number 1248.** A script meant for
  `-File` takes a list as a `[string]` and splits it into a NEW variable, and caps anything that launches
  processes. (channel: judgement; full: og-10)
- **Do not add a gate that is red on day one** for a backlog nobody is about to clear; use a ratchet whose mark
  may only go DOWN. **A plain run of a ratchet never writes its mark**: a fall is SPOKEN and the committed mark
  kept; `-Tighten` records it (`Test-RatchetMove`, `lib/lf-write.ps1`). `ops/audit-write-only-reports.ps1` is the
  exemplar, including its three child-run cases. (channel: judgement; full: og-11)
- **`git add` names what it owns.** (channel: gate ops/audit-git-sweepers.ps1; full: og-12)
- **Every threshold here is an UPPER bound, so none can fire on nothing happening.** When adding a threshold, write
  down what the number does when the producer STOPS; if it goes quiet, add the floor in the same change. A floor on
  a rate is not the volume check; keep both. (channel: judgement; full: og-13)
- **A tuning constant records what ELSE was tried, not just what it means**: first plausible value or survivor of
  a sweep, over how many variants. For the next constant added, not a retro-fill. (channel: judgement; full: og-14)
- **A suite whose target set is DISCOVERED prints what it RESOLVED**, so "no findings" and "the glob matched
  nothing" differ. A line for the next suite, never a threshold. (channel: judgement; full: og-15)
- **A `switch` on DATA carries a `default` that REFUSES loudly** (Brad's ruling), in NEW code: `default { throw
  "unknown <what>: $x" }`, or a comment saying why unmatched is safe. A switch over a literal set in the same file
  needs none. (channel: judgement; full: og-16)
- **A survivor from a mutation probe names the exact missing case.** Worth running against a detector whose logic
  you just rewrote; mutants run from a temp mirror, the original verified byte-identical by md5 afterwards. Never a
  gate. (channel: judgement; full: og-17)
- **Two guards over one rule make the fixture insensitive.** A fixture that asserts only the aggregate cannot tell
  which copy worked: assert the MECHANISM, and give a defence worth having twice a case per copy.
  (channel: judgement; full: og-18)
- **A control constant that may only move ONE WAY needs a RATE LIMIT and a PLAUSIBILITY BAR** (`lib/ratchet.ps1`;
  `promote_aliases.py`'s `MAX_NEW_HOLDS_PER_RUN`). Refusing is half: the old state is KEPT and the refusal SPOKEN.
  The register is `docs/CONTROL-CONSTANTS.md`. (channel: judgement; full: og-19)
- **The `Get-Random` refusals cover WORK SELECTION, not TEST INPUT** (Brad). A seeded test-input generator is fine
  (`ops/probe-hostile-input.ps1`): print the seed, the draw version, a fingerprint of the kind list and the commit;
  draw from one `[System.Random]($Seed)` the generator owns; keep a found failure as a recorded VALUE; count
  distinct INPUTS, not draws. (channel: judgement; full: og-20)
- **PowerShell's `-ne` on strings is CULTURE-SENSITIVE and ignores NUL.** Compare text that may carry damage with
  `[string]::Equals($a,$b,[StringComparison]::Ordinal)`; a bare `@{}` is case-insensitive the same way.
  (channel: judgement; full: og-21)
- **A detector's header says what its CLEAN report MEANS**: a `SCOPE OF A CLEAN REPORT:` line. SOUND means a clean
  report is trustworthy; UNSOUND means it proves nothing. COMPLETE means a finding is real; INCOMPLETE means a
  finding is a candidate. Unsound says nothing about findings. A line saying a finding is real gives the reason it
  is complete (the match IS the defect). (channel: judgement; full: og-22)
- **A git hook in a LINKED worktree exports `GIT_DIR`, and everything it spawns inherits it.** A new hook that
  spawns tests, or a fixture that builds a temp repo, clears the repository environment first
  (`Clear-TcGitRepoEnv`, `lib/git-repo-env.ps1`); `pre-commit` must keep `GIT_INDEX_FILE`.
  (channel: gate ops/audit-git-fixture-env.ps1; full: og-23)
- **A walk over this tree excludes on the path BELOW its root, never the full path** (`Get-TcPathBelowRoot`,
  `lib/tree-walk.ps1`; `New-TcWorktreeFixture` builds the must-fire). Put discovery in a function taking the root.
  **An exclusion must PRUNE, not only filter**: call `Get-TcTreeFiles -RootFull $root -PruneBelow <exclusion>` and
  keep the filter; never convert from `-Include` by copying it. [[filtering-a-walk-is-not-pruning-it]]
  (channel: gate ops/audit-full-path-excludes.ps1; full: og-24)
- **A mutex serialises WRITERS, never READERS.** Under PS 5.1 a lock-free reader can make a locked writer's
  `Move-Item -Force` fail inside the lock, and without `EAP=Stop` silently. A replace of a file something else reads
  uses `Write-TcAtomicFile` (`lib/atomic-write.ps1`; `-NoBom -NoNewline` to keep a `WriteAllText` site's bytes); a
  deliberate exception carries `# atomic-replace:allow <reason>`. A concurrency fixture keeps every writer's exit
  code and output, and its barrier sits INSIDE each writer just before the contended call (`lib/ledger-fixture.ps1`).
  (channel: gate ops/audit-bare-replace.ps1; full: og-25)
- **A lock around the SAVE is not a lock around the read-modify-write.** Single-file ledgers written from a library
  use `Enter-TcLedgerLock` (`lib/ledger-lock.ps1`) with the READ inside it; a ledger held in memory across a run
  RE-READS and MERGES under the lock, taking only the keys it touched. (channel: judgement; full: og-26)
- **THE LOCK ORDER IS DECLARED, OUTERMOST FIRST** (Brad's ruling). Take in this order, release in reverse, and say
  in the commit when a change is the first to nest a pair: 0 capture-run mutex (`Global\tc-capture-run`); 0a
  push-main's per-checkout guard (zero wait); 0b the chain queue ticket (defers only a SWAP, never a gate); 1 push
  lock (`lib\push-lock.ps1`); 2 gate worker slots (`lib\gate-slots.ps1`); 2a the early-rehearsal cap, always before
  2b; 2b rehearsal slots, a PEER of the gate slots, never nested with them; 3 the `Invoke-Locked` mutexes; 4 ledger
  locks, and between two ledgers ASCENDING by `Get-TcLedgerLockName`'s lower-cased full path compared with
  `[string]::CompareOrdinal`. **The order covers every BLOCKING WAIT** (Brad's ruling): holding one of these while
  waiting on an event, process, slot or the remote is a nesting, safe only if the thing waited on can never need
  the lock held. No gate until a second lock is actually nested. (channel: judgement; full: og-27)
- **A self-test can run ZERO cases and exit 0.** Never name a helper after an alias (`r`, `h`, `gc`, `ls`) or a
  cmdlet; run cases under `EAP='Stop'` inside a try whose catch counts a failure; compare a file by content
  (`Get-FileHash -LiteralPath`). (channel: gate ops/audit-cmdlet-shadow.ps1; full: og-28)
- **A self-test's exit 0 is not its verdict.** Its LAST line names the self-test and carries a result word
  (`self-test pass`), or a `X-SELFTEST-COMPLETE` / `selftest=pass` marker names it (`lib\selftest-verdict.ps1`); a
  tally is not a verdict. A line starting `FAIL` or `SELF-TEST FAIL` scores fail, so never echo a child's FAIL lines
  as your own at exit 0. (channel: gate ops/run-gates.ps1; full: og-29)
- **A self-test block must LEAVE on every path**: close it with an unconditional `exit` after its verdict, or a
  passing fall-through runs the live code below it. (channel: gate ops/audit-selftest-fallthrough.ps1; full: og-30)
- **A HARNESS that runs a child's self-test owes the same two reads**: the child's exit code AND its own verdict
  line, matched on text from the child's real last lines, never a case-label word; hand the child a temp output
  directory where it takes one. (channel: judgement; full: og-31)
- **A BLIND case that gates a BLOCK is scored on the BLOCK.** Count the cases the blind branch SUPPRESSED, print
  `cases` beside `blind`, and let the seeing arm assert the blind arm's number with a CLEAN TWIN.
  (channel: judgement; full: og-32)
- **A sandbox that runs a real script copies the WHOLE `lib\`**, loads each library under `Stop` inside a try that
  exits 3, and a fallback that only logs a load failure needs a case that reads the log. **Prove a sandbox by
  building one and running a subject in it**, never by path arithmetic, with a decoy where the wrong layout would
  look. (channel: judgement; full: og-33)
- **Under PS 5.1 `VariablePath.UnqualifiedPath` reads as `$null`.** Strip the scope from `UserPath` instead
  (`Get-SelfTestVariableName`, `lib/selftest-lib.ps1`). (channel: judgement; full: og-34)
- **A self-test the census cannot find can lose its must-fires and stay green.** Open a new suite in a shape
  `Get-SelfTestBlock` reads: an `if` on a self-test switch, the code after `if (-not $SelfTest) { ...; exit }`, a
  function `Invoke-<name>SelfTest`, or a file named `test-*.ps1`. (channel: gate ops/audit-mustfire-census.ps1; full: og-35)
- **A hermetic self-test never asserts an UPPER wall-clock bar**: the box is shared and load makes it red. Prove
  concurrency by OVERLAP (`lib/concurrency-probe.ps1`); a clock survives only as a generous hang guard or a LOWER
  bar. Prove a regex bound by the timeout the code RECORDS, with a victim whose unbounded cost is a few seconds. A
  poll with a deadline, a barrier with a timeout, or a timer racing a retry window is the same bar: wait on an event
  the subject produces, end a wait from inside a swappable seam, and give the real timer its own twin. Hold a
  subject open on a CONDITION the test controls (a stop file), sample, and read it still running before releasing
  it. A definition is not a registration: check `Get-ScheduledTask`. (channel: judgement; full: og-36)
- **A timed lock wait is a BRANCH**: read `WaitOne`'s answer and refuse on `$false`; its timed-out branch gets a
  MUST FIRE held from another process (`lib/mutex-hold.ps1`). **An append is not a locked write**: a file several
  processes append to goes through `Add-TcLine` (`lib/append-line.ps1`). (channel: gate ops/audit-unread-wait.ps1; full: og-37)
- **A self-test names every temp path PER RUN**, never by a fixed name under `%TEMP%`: one unique directory per run,
  every path handed out through one recording function, removed in `finally` (`GcScratch` in guard-contract), created
  with `-ErrorAction Stop`, the name short. A self-test red that names no case is a concurrency suspect.
  (channel: gate ops/audit-fixed-temp-names.ps1; full: og-38)
- **A child a gate spawns must not write a TRACKED path, and a tracked file written under PS 5.1 is written LF**
  (`Write-TcLfFile`, `lib/lf-write.ps1`; Python `newline="\n"`). Verify by bytes: `git status --short` empty and a CR
  count of 0. When code under test writes a tracked path by default, redirect the default suite-wide. Moving a write
  into a helper can hide it from a source-text ratchet: compare family NAMES against the baseline, not the count.
  **A typed parameter keeps its type**: never reassign a typed parameter's name with a value of another kind.
  (channel: gate ops/audit-typed-param-shadow.ps1; full: og-39)
- **The gate worker slots are handed out in ARRIVAL ORDER** (`lib\gate-slots.ps1`, a ticket per waiter, liveness by
  MUTEX), and a green run over identical content is reused (`lib\gate-verdict.ps1`, same checkout). Order decides
  WHICH pushes are refused, never how many: state that bound beside any fairness fix. Every lock path degrades to the
  day before, never to a refusal, and a run that cannot join the queue stops deferring to it. A suite whose cases are
  a literal list asserts how many ran; a fixture name is claimed once. (channel: judgement; full: og-40)
- **A statement keyword written after a command is an ARGUMENT**: never put `if (...) { exit }` on a case line. A
  gate run must leave nothing where the bot stages (`lib/gate-leftovers.ps1`).
  (channel: gate ops/audit-keyword-arguments.ps1; full: og-41)
- **A typed backslash-n is two characters, never a line break, and a case in a comment never runs.** A suite's own
  case count is the pair that catches a lost case of any shape. (channel: gate ops/audit-literal-newline-escape.ps1; full: og-42)
- **A comma binds tighter than `-and`**, so `a -and b, 'got'` never judges b. Write `((a) -and (b)), 'got'`; a
  fixture that executes the shape on purpose carries `# and-comma-case:allow <reason>`.
  (channel: gate ops/audit-and-comma-case.ps1; full: og-43)
- **A RULING PUSH IS RED ON PURPOSE, and the gate accepts that red only when the push causes it** (Brad's ruling).
  Mark the new failing case's Bad line `# live-board-ruling-case audit=<script>` for the paired base/tip run; compare
  a working-tree file with a blob through `git hash-object`; re-seed a stale worktree board before pushing a ruling.
  (channel: gate ops/prepush-test-auditors.ps1; full: og-44)
- **A KEYED SELF-TEST CAN STILL RE-RUN ON EVERY PUSH when its key is too WIDE** (`lib\gate-input-key.ps1`). A file
  the suite only parses or copies goes on a `# gate-inputs-text:` line; a file a library only writes on a
  `# gate-output: <path> read-by <functions>` line. Check a key's file list, not only `Ok`, and run
  `-VerifyDeclared` after any declaration change. (channel: judgement; full: og-45)
- **A push is a compare-and-swap whose critical section is the whole hook**, so serialise the SWAP, never the gate:
  `lib\push-lock.ps1` is taken for the ref update only, and every lock path degrades to the day before, never to a
  refusal. `run-gates` often runs WITH the real push lock held, so a suite reading ambient state a caller may hold
  must say which instance it means, and be driven once with the real lock held. (channel: judgement; full: og-46)
- **PUSH-MAIN FITS FIRST, RE-CHECKS WHAT MOVED, AND LOCKS ONLY THE SWAP** (design A, Brad's ruling;
  `ops\push-main.ps1`'s header is the account): pre-flight rebase and seed, legs outside the lock, at most 3
  catch-up rounds (the rehearsal budget counts only rounds that rehearsed), the lock held for the swap with at most
  3 hand-backs. Run board steps, guards and reconcilers in a scratch clone, never the checkout you land from. **Land
  a chain change only through push-main, never `git push origin HEAD:main`, and say so in every orchestrator
  brief.** The commit-time rehearsal (`ops/hooks/post-commit`, `-Prepare`), the chain queue (`lib\chain-queue.ps1`,
  `-ChainQueue off` is the rollback) and the pre-push queue-head check are in the header too.
  (channel: judgement; full: og-47)
- **A LANE WRITES ONLY WHAT IT OWNS.** Backlog progress is a new file under `design\backlog-inbox\updates\`, never
  an edit of the backlog; a re-read is a ledger row via `ops\add-reread.ps1`, never a doc line; a ready-for-brad item
  is its own file under `design\ready-for-brad\`. A MAIN-checkout session lands with `ops\push-main.ps1` too.
  (channel: judgement; full: og-48)

## The words these rules were written without

None of the following is a gate, and none of it asks for a sweep.

- **`starvation` and `deadlock` each mean two or three things in this tree.** Say which sense you mean.
  (channel: judgement; full: og-49)
- **A blocking lock can DEADLOCK and cannot livelock; a tryLock-with-retry can LIVELOCK and cannot deadlock.** A
  refusal branch must RELEASE what it holds before it loops, and the real fix is to break the symmetry of the
  who-waits-for-whom cycle. (channel: judgement; full: og-50)
- **Write the POINTED-TO object before the object that points to it**, so an interruption leaves a leak, never a
  dangling reference. When a change touches two files where one refers to the other, name the pointed-to one, write
  it first, and say so in the commit. (channel: judgement; full: og-51)
- **State whether a retried operation is IDEMPOTENT, and what makes it so.** `Write-TcAtomicFile` replaces a whole
  file and is idempotent; `Add-TcLine` appends and is not, so only its OPEN is retried. (channel: judgement; full: og-52)
- **Ledger writers are serializable and readers lock-free.** Ask of a new lock-free reader which anomaly its
  decision can survive (a non-repeatable read, a phantom): sampling one key once survives all; comparing two keys, or
  iterating then acting on the count, does not. (channel: judgement; full: og-53)

Regime: this holds for gate and library code. Data-dependent audits live in the daily chain, not in
`run-gates`, and the split is deliberate - see `run-gates.ps1`'s own header.
