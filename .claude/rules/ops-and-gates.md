---
description: Rules for gate, audit, self-test and shared-library code - one line each; the account is ops-and-gates-depth.md.
---

# Gate, audit and library rules, one line each

LEAD FILE: loads in every ThriftyCrew session, because it has no `paths:` key, on purpose
(design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md, W2.3 option B, D2). These rules bite wherever
PowerShell or Python is written, not only in `ops/` and `lib/`: the account behind each line, with its incidents and
measurements, is `.claude/rules/ops-and-gates-depth.md`, which loads after a session reads any `.ps1` or `.py` file,
or anything under `ops/` or `lib/`. A `[[name]]` is
`~/.claude/projects/C--Codex-ThriftyCrew/memory/<name>.md`: read it, never write it.

## Verdicts and markers

- Read the EXIT CODE first and the tally second, and read the verdict LINE rather than decoding the number: the same `2` means different things in different vocabularies. [[exit-code-first-tally-second]]
- A detector owes a `<NAME>-COMPLETE` marker as its LAST line (`lib/guard-contract.ps1`), or "no findings" and "died halfway" are the same bytes.
- A self-test's exit 0 is not its verdict: its last line names the self-test and a result word (`lib\selftest-verdict.ps1`), and it never echoes a captured child's `FAIL` lines as its own at exit 0.
- A self-test block must LEAVE on every path: close it with an unconditional `exit` after its verdict (`ops/audit-selftest-fallthrough.ps1`).
- A harness that runs a child's self-test reads both the child's exit code and its verdict line (text chosen from the child's real last lines), and hands the child a temp output directory.
- A suite whose cases are a literal list asserts how many ran; one whose target set is DISCOVERED prints what it resolved.
- A BLIND case that gates a block is scored on the block: count the cases it suppressed, print `cases` beside `blind`, and let the seeing arm assert that number.
- A detector's header carries a `SCOPE OF A CLEAN REPORT:` line saying whether a clean report proves anything (sound) and whether a finding is real (complete, with its reason); unsound says nothing about findings.

## Fixtures

- A self-test that greps its own source cannot fail: build needles by concatenation, and never let a detector scan itself. [[selftest-greps-its-own-source]]
- Three fixture labels, three jobs: `MUST FIRE` (the founding bug is flagged), `MUST NOT FIRE` (a legal input is silent), `CLEAN TWIN` (a POSITIVE assertion that an adjacent behaviour still works); `ops/audit-fixture-vocabulary.ps1`.
- A threshold or count detector's self-test carries a case exactly AT its bar and one a step PAST it, names the bar in the case text, and builds them from binary-exact numbers; never widen a tolerance to satisfy a fixture.
- A fixture built by string concatenation is not one argument, and inside an array literal the comma binds tighter than `+`: assign each concatenated line to a variable first, or write a single-quoted literal.
- A comma binds tighter than `-and`, so write a case body as `((a) -and (b)), 'got'`; `ops/audit-and-comma-case.ps1`.
- A typed backslash-n is two characters and a case in a comment never runs; `ops/audit-literal-newline-escape.ps1`, paired with the suite asserting its own count.
- A statement keyword written after a command is an ARGUMENT (`_T 'x' (c) if ...` never exits); `ops/audit-keyword-arguments.ps1`, and a gate run leaves nothing where the bot stages (`lib/gate-leftovers.ps1`).
- A self-test can run ZERO cases and exit 0: never name a helper after an alias (`r`, `h`, `gc`, `ls`) or a cmdlet (`ops/audit-cmdlet-shadow.ps1`), run cases under `$ErrorActionPreference = 'Stop'` with a counted catch, and compare files with `Get-FileHash`.
- A hermetic self-test never asserts an UPPER wall-clock bar: prove OVERLAP (`lib/concurrency-probe.ps1`), count the timeout the code RECORDS, wait on an event rather than a deadline, and hold a subject open on a condition the test controls; a task definition is not a registration, so check `Get-ScheduledTask` before saying it runs.
- A self-test names every temp path PER RUN (one unique directory, one allocating function, removed in `finally`; `GcScratch` in `lib/guard-contract.ps1`), and a red that names no case is a concurrency suspect; `ops/audit-fixed-temp-names.ps1`.
- A sandbox that runs a real script copies the WHOLE `lib\` and loads each library under `Stop` inside a try that exits 3; prove a sandbox by building one and running a subject in it, with a decoy.
- A self-test the census cannot find can lose its must-fires and stay green: open a new suite in a shape `Get-SelfTestBlock` (`lib/selftest-lib.ps1`) reads.
- Two guards over one rule make the fixture insensitive: assert on the MECHANISM, a case per copy, and a mutation probe (temp mirror, md5 back) is how you find out.
- A mutation-probe survivor names the exact missing case: run one against a detector whose logic you just rewrote. Never a gate.
- The `Get-Random` refusals cover WORK SELECTION, not test input: a seeded generator is fine (`ops/probe-hostile-input.ps1`) if it prints seed, draw version and commit, owns one `[System.Random]($Seed)`, keeps a found failure as a VALUE, and counts distinct inputs.
- A keyed self-test re-runs on every push when its key is too WIDE: a file read as text goes on `# gate-inputs-text:`, one only written on `# gate-output: <path> read-by <functions>`; check the key's file list and run `-VerifyDeclared`.

## PowerShell and Python traps

- A catch around a native redirect is not a guard under `EAP=Stop`: use `Invoke-Native`/`Invoke-NativeScript` (`grocery\native-lib.ps1`) or set `Continue` as its own statement around a `try/finally`; `grocery\test-native-stderr-eap.ps1`.
- Never wrap a function call inline as `@(Get-Thing ...)`: assign, then wrap. [[ps-json-array-collapse]]
- `@($v)` THROWS when `$v` came from `New-Object ...List[object]`: build it with `::new()` or use `.ToArray()`; `ops/audit-list-array-wrap.ps1` holds it at zero. [[ps-list-object-array-wrap-throws]]
- Under `powershell -File`, `-Count 1,2,4,8` into `[int[]]` binds as 1248: take a `[string]`, split it into a NEW variable, and cap anything that launches processes.
- A typed parameter keeps its type (`$json = '...'` beside `[switch]$Json` throws); `ops/audit-typed-param-shadow.ps1`.
- PowerShell's `-ne` is culture-sensitive and ignores NUL, and a bare `@{}` is case-insensitive: compare damaged text with `[string]::Equals($a,$b,[StringComparison]::Ordinal)`.
- Under PS 5.1 `VariablePath.UnqualifiedPath` reads as `$null`: take the name from `UserPath` via `Get-SelfTestVariableName` (`lib/selftest-lib.ps1`).
- A `switch` on DATA in new code carries a `default` that refuses loudly; a deliberate fallback says why in a comment.

## Ratchets, thresholds and constants

- Do not add a gate that is red on day one: use a ratchet whose mark may only fall, a plain run never writes the mark, and `-Tighten` records it (`ops/audit-write-only-reports.ps1` is the exemplar).
- Moving a write into a helper can hide it from a source-text ratchet and record a FALSE improvement: compare family NAMES against the committed baseline, not the count.
- Every threshold here is an UPPER bound: when adding one, write down what it does when the producer STOPS, and add the floor in the same change.
- A tuning constant records what ELSE was tried, not just what it means.
- A control constant that may only move one way needs a rate limit and a plausibility bar, keeps the old state and SPEAKS its refusal (`lib/ratchet.ps1`; register `docs/CONTROL-CONSTANTS.md`).

## Files, walks and writes

- `git add` names what it owns; `ops/audit-git-sweepers.ps1` fails a sweep.
- A git hook in a linked worktree exports `GIT_DIR`: a new hook or temp-repo fixture clears it with `Clear-TcGitRepoEnv` (`lib/git-repo-env.ps1`), and `pre-commit` keeps `GIT_INDEX_FILE`; `ops/audit-git-fixture-env.ps1`.
- A walk excludes on the path BELOW its root (`Get-TcPathBelowRoot`) and PRUNES rather than filters (`Get-TcTreeFiles -RootFull $root -PruneBelow <exclusion>`, `lib/tree-walk.ps1`), with discovery in a function that takes the root; `ops/audit-full-path-excludes.ps1`.
- A replace of a file something else reads goes through `Write-TcAtomicFile` (`lib/atomic-write.ps1`), because a lock-free reader can cost a locked writer its write; mark a deliberate bare replace `# atomic-replace:allow <reason>` (`ops/audit-bare-replace.ps1`).
- A concurrency fixture keeps every writer's exit code and output, and puts its barrier INSIDE each writer immediately before the contended call (`lib/ledger-fixture.ps1`).
- A lock around the SAVE is not a lock around the read-modify-write: take `Enter-TcLedgerLock` (`lib/ledger-lock.ps1`) before the READ, and a ledger held in memory re-reads and merges under the lock.
- A timed lock wait is a BRANCH that refuses on `$false` (its MUST FIRE holds the mutex from another process, `lib/mutex-hold.ps1`), and a file several processes append to goes through `Add-TcLine` (`lib/append-line.ps1`).
- A child a gate spawns must not write a TRACKED path, and a tracked file written from PS 5.1 is written LF through `Write-TcLfFile` (`lib/lf-write.ps1`); Python writes one with `newline="\n"`, and a default path under test is redirected suite-wide. Verify by bytes.

## Locks, queues and pushing

- THE LOCK ORDER IS DECLARED, outermost first: 0 capture-run mutex, 0a per-checkout guard, 0b chain queue ticket, 1 push lock, 2 gate slots, 2a early-rehearsal cap, 2b rehearsal slots (a peer of 2), 3 `Invoke-Locked` mutexes, 4 ledger locks ascending by lower-cased full path compared ORDINALLY; release in reverse, say in the commit when a pair is nested for the first time, and treat every blocking wait under a lock as a nesting.
- The gate worker slots are served in arrival order and a green verdict is reused for identical content in the same checkout (`lib\gate-verdict.ps1`); order decides WHICH pushes are refused, never how many, so state the capacity bound beside any fairness fix.
- Every lock path degrades to the behaviour of the day before, never to a refusal, and a run that cannot join a queue stops deferring to it.
- A fixture name claimed twice passes against a machine nobody is holding: `lib\gate-slots.ps1` throws on a reuse.
- `run-gates` often runs WITH THE REAL PUSH LOCK HELD, so a suite reading ambient state a caller may hold names which instance it means, and is driven once with the real lock held.
- Land with `ops\push-main.ps1` (also from the main checkout, which it routes through a throwaway worktree): it rebases and gates OUTSIDE the lock and locks only the swap; land a chain change only through it, never `git push origin HEAD:main`, and run board steps and reconcilers in a scratch clone, never the checkout you land from.
- A ruling push is red on purpose: mark the Bad line `# live-board-ruling-case audit=<script>` so the paired run can accept it as `EXPECTED-LIVE-RED`, compare a working file with a blob through `git hash-object`, and re-seed before pushing a ruling.
- A lane writes only what it owns: backlog progress is a new file under `design\backlog-inbox\updates\`, a re-read is a row from `ops\add-reread.ps1`, and a ready-for-brad item is its own file under `design\ready-for-brad\`.

## Words to be exact with

- `starvation` and `deadlock` each mean two or three things in this tree: say which sense you mean.
- A blocking lock can deadlock and a try-with-retry can livelock: the refusal branch RELEASES what it holds before it loops, and the real fix breaks the symmetry.
- Write the POINTED-TO object before the object that points to it, and say which it is in the commit.
- State whether a retried operation is IDEMPOTENT and what makes it so (`Write-TcAtomicFile` is; `Add-TcLine` is not, so only its open is retried).
- Ask of a new lock-free ledger reader which anomaly its decision can survive (a non-repeatable read, a phantom), not whether it is safe.

Regime: this holds for gate, library and self-test code wherever it lives. Data-dependent audits live in the daily chain,
not in `run-gates`, and the split is deliberate - see `run-gates.ps1`'s own header.
