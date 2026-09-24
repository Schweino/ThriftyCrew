# Lane: pd-rehearse2 (W6.0, W9.5 and the rehearse-chain half of W9.1 of design/PLAN-push-derived-conflicts-2026-09-23.md), 2026-09-23

Filed by the lane that owns `ops/rehearse-chain.ps1` for that plan. The first entry publishes the interface the
sibling lanes (push-main -Prepare and W9.3's starter, the post-commit hook of D19, W9.2's chain queue) call. The other
two are findings made on the way, outside the lane's items.

## rehearse-chain gains -onto, -stackfile, -early and -stopfile, the interface w9.1, w9.2 and w9.3 call

`DONE`

**What landed** (W9.1 steps 0, 1, 2, 4 and 6, rehearse-chain's side only; `-Prepare`, `early_hit` and the hook are
push-main's and the hooks lane's):

- `-Onto <sha>` / `-StackFile <path>`, on any mode that rehearses. The file is line 1 the base (the origin sha), then
  one commit sha per line: every commit of every ticket ahead, oldest first. The stacked tip is HEAD's
  `<merge-base>..<Commit>` replayed onto that, each commit applied as `git rebase` applies it (a merge-ort
  `git merge-tree --write-tree --merge-base=<parent>`, merges skipped), in a private bare `--shared` clone under
  %TEMP%. No worktree ever moves. The verdict key is the stacked tip's manifest set, by the unchanged key function.
- A replay conflict records NO verdict and prints `chain-rehearsal: STACK CONFLICT - applying <sha9> onto the stack
  conflicts in: <files>`. `-ForPush` then ends `CHAIN-REHEARSAL-CHECK-COMPLETE code=3 outcome=could-not-rehearse
  blind=stack-conflict`, exit 3.
- `-ForPush -StackFile <file>`: the push is still judged chain-touching on HEAD against origin/main (W6.0's union).
  When it is, the verdict looked up, and rehearsed when missing, is the STACKED tip's.
- `-Early -Onto <origin sha> [-Commit HEAD]`, meant to be started DETACHED. It starts nothing (exit 0) when the stacked
  content touches no member (`reason=not-chain`), when a pass or fail verdict over fresh data exists for its key
  (`verdict-exists`), or when a live early run in ANY checkout holds its key (`in-flight`). Otherwise it:
  - writes `%LOCALAPPDATA%\ThriftyCrew\chain-rehearsal\early\<SHA-256 of the lower-cased checkout path>.json` with
    `pid`, `pid_start`, `key`, `onto`, `head`, `tip`, `start`, `stop_file` and `checkout`, through Write-TcAtomicFile;
  - supersedes this checkout's older live run of a different key by writing that run's `stop_file` first;
  - takes one of 4 early caps (`Global\tc-rehearsal-early-`), then a rehearsal slot, and rehearses;
  - ends `CHAIN-REHEARSAL-EARLY-COMPLETE started=yes|no reason=<r> [verdict=<v>] key=<k12>[ superseded=<pid>]`. The
    exit is the rehearsal's when it started, 3 for a blind reason (stack-conflict, no-early-cap, cannot-read-push).
- `-StopFile <path>`: polled every 5 s while any child runs and between stages. On seeing it the run stops its OWN
  child tree, records nothing, removes its scratch root and ends `blind=stopped`. `-ForPush` prints
  `CHAIN-REHEARSAL-CHECK-COMPLETE code=3 outcome=could-not-rehearse blind=stopped`. W9.3's starter passes a per-run
  file and writes it on a red leg.
- Every chain child gets `TC_REHEARSAL_RUN=1`, so the post-commit hook must exit 0 when it is set. It also gets a
  TEMP inside the scratch root. The verdict record gains `early`, `onto`, `head`, `checkout` (hashed like the in-flight
  file) and `stage_secs` (`stack`, `clone`, `checkout`, `seed`, `selftest`, `ship`, `commit`). `-CheckPush` and
  `-ForPush` read none of these.

**Step 0, what a stopped rehearsal leaves behind: nothing shared, so the stop IS built.**
- Read: the chain child writes nothing under %LOCALAPPDATA%\ThriftyCrew. Its ledger and Invoke-Locked mutexes are
  named from paths inside the clone. Its only fixed Global mutexes are send-alert's two, behind -NoAlert, and both of
  their waiters treat an abandoned mutex as acquired (`grocery/send-alert.ps1`, the two `AbandonedMutexException`
  catches). Its temp leftovers now land in the scratch root.
- Measured by the fixture: a stopped early run left no `tc-rh*` or `rh-index-*` entry in its TEMP, removed its
  in-flight file, freed all 6 of its slots, and left every verdict file's SHA-256 unchanged.

## a self-test case body `a -and b, 'got'` never judges b, because the comma binds tighter than -and

`OPEN` `queue-7` `2-WAY` `RUNG1 MEASURE`

**What is wrong.** `ops/rehearse-chain.ps1`'s cases returned `(cond1) -and (cond2), ('got text')`. PowerShell parses
that as `(cond1) -and ((cond2), ('got text'))`. A two-element array is truthy, so the LAST condition of every
multi-condition case was never judged, and the body returned one boolean, so no got-text was ever printed. Found
2026-09-23 while killing mutant M11: 32 of that file's 39 cases had the shape. All 32 were rewritten to
`((cond1) -and (cond2)), 'got'` by an AST pass, and every newly judged condition held. Its Test-RhCase now fails any
body that does not return exactly (verdict, got), and a MUST FIRE case proves it does.

**Not measured:** how many other suites use the same `{ a -and b, 'got' }` idiom. A census would walk every
self-test's case-call scriptblocks through the AST, looking for a last statement that is a BinaryExpressionAst whose
right spine ends in a two-element ArrayLiteralAst. That is the exact rewrite rule, and it is in the commit that
carries W6.0.

## a relative [io.file] path in the powershell tool resolves against the process directory, not the cd'd location

`OPEN` `queue-7` `2-WAY` `RUNG1 DOC`

**What happened, 2026-09-23.** From a worktree session, after `cd <worktree>`, a PowerShell-tool command ran
`[IO.File]::ReadAllText('ops\rehearse-chain.ps1')` and wrote the result back. .NET resolves a relative path against
`[Environment]::CurrentDirectory`, which the tool kept at the MAIN checkout. So the write landed in
`C:\Codex\ThriftyCrew\ops\rehearse-chain.ps1`, three times over about 30 minutes, while the cmdlets (`Select-String`,
`git`) in the same commands read the worktree. It was caught because a self-test count did not move. The main file
was then proven to be its HEAD blob plus exactly those three writes (reconstructed and compared ordinally) and
restored to the HEAD bytes (`git hash-object` equals `HEAD:ops/rehearse-chain.ps1`, 17170b387). Nothing was
committed from it.

**The fix wanted:** the "spawned tasks write through repo-relative paths only" rule is exactly the trap for .NET
calls. Pass absolute paths to `[IO.File]` and `[IO.Directory]`, or `Resolve-Path` them first. Say so wherever that rule
is stated.
