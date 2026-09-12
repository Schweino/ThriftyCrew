# The capture-eviction stamp travels with the board (2026-09-11)

Status: SHIPPED with this file. Record of a cause, a fix, and the fix that was measured and refused.

## What happened

A push touching only `lib/event-bus.ps1`, `ops/audit-event-bus.ps1`, `.claude/rules/ops-and-gates.md` and two
`design/MEASURE-event-bus-concurrent-append-2026-09-11` files passed `ops/run-gates.ps1` (357 of 357) and was then
REFUSED by `ops/prepush-test-auditors.ps1`. `lib/event-bus.ps1` is a test-auditors input, so 42 of 140 units ran,
and one case was new against the known-failures record:

    capture-evictions.json audited comparison-2026-09-09.json but the newest board is comparison-2026-09-11.json

`grocery/out/capture-evictions.json` is TRACKED. `grocery/out/comparison-*.json` is gitignored and reaches a
worktree by copy (`.worktreeinclude`). So the case compared a file that crosses checkouts by COMMIT with a board
that crosses them by COPY, and any push selecting that unit was refused from any worktree carrying the new board,
however unrelated, until somebody committed the refreshed report.

## Which producer, and why the committed copy lagged

The only writer is `grocery/audit-capture-eviction.ps1` (live run). The only machine reader was test-auditors unit
`u108`. Timeline, all 2026-09-11, read from file mtimes and `built_at` in the main checkout, `grocery/ad-cycle-log.txt`
and `git log`:

| Time | Event |
|---|---|
| 08:11:25 | daily chain builds `comparison-2026-09-09.json` |
| 08:20:59 | the rostered pass (check-ad-cycles fan-out lane `capture-eviction`) writes the report naming it |
| 08:32:12 | `fa915e454` daily bot commit carries the report |
| 12:19:32 | `comparison-2026-09-09.json` rebuilt IN PLACE by a hand-run chain. No ad-cycle-log entry, no eviction pass |
| 14:27:41 | `comparison-2026-09-11.json` built by the triage plan-2026-09-11 hand-run chain |
| 14:32:52 | that chain runs the pass in the main checkout; the report there names 09-11, uncommitted (` M`) |
| 14:42:42 | `2c0d9c45c` commits the chain's SOURCE only (4 files), correctly staging explicit paths |

Answers to the two questions asked:

- **Does the daily commit run before the rostered pass?** No. Board, then pass, then commit (08:11, 08:20, 08:32),
  and the daily test-auditors outputs in `grocery/out/test-auditors-*-2026-*.txt` show the currency case passing on
  every daily run read except 2026-08-31, which is a different shape (the pass ran 6 minutes BEFORE the board).
- **Does the pass run later in a lane that never commits?** Yes. Mid-day rebuilds happen in hand-run triage chains
  outside check-ad-cycles. Those chains either do not run the pass (12:19 today; 11:47 on 2026-09-09, repaired by
  hand in `5f5f5d877`) or run it and commit their source only (14:32 today). The report is bot-owned data under
  `grocery/out`, so the next commit of it is the next morning's bot run: about 17 hours of refused pushes.

The first lag (12:19 to 14:32) was a TRUE positive: no pass had run on that generation. The second (from 14:32) was
a false one: the pass had run, and its record was on the wrong road. The fix has to keep the first and remove the
second.

## The fix

- `audit-capture-eviction.ps1` still writes the TRACKED report, then writes `out/capture-evictions-stamp.json` LAST:
  `generated`, `compare_file`, `compare_built_at` (copied verbatim from the board it read), `candidates_file`,
  `finding_count`. The stamp is gitignored and listed in `.worktreeinclude`, so it reaches a checkout exactly the
  way the board does. `New-CaptureEvictionStamp` is pure and carries a self-test case.
- test-auditors u108 reads the STAMP wherever the checkout has one, and then also requires `compare_built_at` to
  equal the board's `built_at`, which catches a same-name rebuild directly instead of through a clock comparison.
  A checkout with no stamp is judged on the report exactly as before.
- Nothing that failed before passes now except a current stamp beside a lagging committed report. The generation
  match is stricter than before.

## Refused: untracking the report

The obvious repair is to gitignore `capture-evictions.json` itself, which is also what `.gitignore`'s own
"regenerable pipeline OUTPUTS" rule says a pure function of the boards should be. It was measured first, in scratch
repos under the session scratchpad, git 2.54.0.windows.1, reproducing the bot's own commands from
`grocery/capture-run.ps1:1047` (`-c rebase.autoStash=true rebase -X theirs origin/main`):

| Checkout state when the untrack commit arrives | Result |
|---|---|
| uncommitted local edit of the file, `rebase --autostash` | rebase EXIT 0, "Applying autostash resulted in conflicts", path left `DU`; the next `git commit` exits 128 |
| a local commit that modified the file (the bot commits first), `rebase -X theirs` | `CONFLICT (modify/delete)`, rebase exit 1 |
| clean | rebase exit 0, file deleted from the working tree |

The bot rewrites and commits this file every morning, and capture-run's foreign-held rule leaves a session's
dirty copy uncommitted, so both of the first two rows are on the bot's normal path. The second row aborts the
publish and retries; the first leaves the main checkout unable to commit at all while reporting success. That is a
stale live board or a stuck shared tree in exchange for a test fix, so the report stays tracked.

## Refused: a stamp-only reader

- `ops/audit-write-only-reports.ps1` reads 41 families against a baseline of 41. With the report's only machine
  reader moved to the stamp, `capture-evictions` becomes write-only and the gate goes red. Raising that mark is a
  weakened gate. The report fallback keeps a real reader.
- **A worktree cannot write a stamp.** `audit-capture-eviction.ps1` in this worktree exited 3 in 1 second, `BLIND:
  no candidates-*.json to audit`: `.worktreeinclude` copies the boards and not the candidates. A stamp-only reader
  would have left every worktree made before this change red with no repair it could run.

## Verification

Harness: `grocery/test-auditors.ps1 -SkipUnitsFile` with the other 139 unit ids (generated from the file's own
`Use-Unit` declarations), so unit u108 ran alone, 8 cases, about 34 seconds a run. Run in worktree
`goofy-shannon-f67f47` on this change over `2c0d9c45c`, whose disk held `comparison-2026-09-11.json` (built_at
14:27:41) and the committed report naming 09-09. The bar, stated before the runs: the no-stamp run reproduces the
incident message byte for byte, the incident shape with a stamp passes, and every failure branch fires on its own.

| Run | Exit | Case line |
|---|---|---|
| no stamp (fallback) | 2 | `capture-evictions.json audited comparison-2026-09-09.json but the newest board is comparison-2026-09-11.json` |
| live pass with `-CandidatesFile` read from the main checkout: 13 s, 3,179 cells, 20,770 dated rows, 0 findings; report restored from git | 0 | `roster is ARMED: capture-evictions-stamp.json (2026-09-11T15:10:52) post-dates ... (built_at 2026-09-11T14:27:41)` |
| stamp names comparison-2026-09-09.json | 2 | `capture-evictions-stamp.json audited comparison-2026-09-09.json but the newest board is ...` |
| stamp `compare_built_at` 08:11:25, same file name | 2 | `... read comparison-2026-09-11.json as built at 2026-09-11T08:11:25 but the board on disk was built at 2026-09-11T14:27:41` |
| stamp `generated` 14:00:00 | 2 | `... is stamped 2026-09-11T14:00:00, OLDER than ...` |
| stamp `generated` unparseable | 2 | `... carries an unparseable timestamp` |
| stamp and report both absent | 2 | `a board exists but neither out\capture-evictions-stamp.json nor out\capture-evictions.json does` |
| stamp restored (md5 identical), report restored (`git status` clean) | 0 | ARMED |

Also at exit 0: `audit-capture-eviction.ps1 -SelfTest` (2 must-fire, 6 clean twins), `ops/audit-write-only-reports.ps1`
(41 of 41), `ops/audit-fixture-inputs.ps1` (0 new), `ops/audit-mustfire-census.ps1` (0 lost),
`ops/audit-fixture-vocabulary.ps1` (0 mislabelled), `ops/seed-worktree.ps1 -SelfTest` (27 of 27). The push itself
runs `run-gates` and a FULL test-auditors run, because `grocery/test-auditors.ps1` is the harness.

## What this leaves, stated

- **Worktrees made before this change have no stamp** and keep the old behaviour until they are recreated or copy
  `grocery/out/capture-evictions-stamp.json` from the main checkout. They cannot write one themselves (no
  candidates). Not a regression: their verdict is exactly what it was.
- **The main checkout has no stamp until its first eviction pass under this code**, the next daily chain at about
  08:20 or any hand-run chain that runs the pass. Until then `ops/seed-worktree.ps1` reports the new
  `.worktreeinclude` line MISSING-SOURCE and exits non-zero, which is true, and a new worktree is judged on the report.
- **The main checkout's uncommitted 14:32 report was not touched** from this worktree. The next bot run commits it.
- **Hand-run chains still do not commit the report, and no longer need to.** A chain that rebuilds a board and
  skips the pass is still refused, in the checkout that holds that board, which is the true positive this case
  exists for.

# Second pass, same day: with no stamp the answer is a SKIP, not the report

Status: SHIPPED with this section. The first two bullets above turned out to be the defect, not a footnote.

This is the other half of `78db9d6a9` (session practical-hypatia-083434), which found the same split from the
seeding side, measured the whole class - 304 tracked undated-name records in the two directories a seeded file
lands in, 12 carrying a dated-board pointer, 4 then 5 disagreeing within half an hour - and made
`ops/seed-worktree.ps1` REPORT each disagreement without moving its exit code. Its own message names what it left:
"no eviction pass has written that stamp yet ... the case still falls back to the tracked report. The founding
failure recurs on the next rebuild-before-commit. The case itself is untouched here." That fallback is what this
section closes. The two changes do not overlap: that one reports at the seeder, this one decides in the case, and
neither refuses a push for a disagreement no pusher can repair.

## What was still wrong

"Worktrees made before this change keep the old behaviour ... not a regression: their verdict is exactly what it
was" is true and is exactly the problem. The old verdict in those checkouts was the commit-lag measurement this
document is about. Putting the record on the board's road fixes nothing for a checkout that has no record on that
road - it still fell through to the tracked report, and a checkout that carries a copied board beside a committed
report is comparing two files that arrived by different roads.

Established before changing anything:

- **The writer** is `grocery/audit-capture-eviction.ps1`'s live run. It writes `out/capture-evictions.json` and
  then `out/capture-evictions-stamp.json` into `<repo>/grocery/out`, always the script's own root - there is no
  `-OutDir`, so a run only ever stamps the checkout it runs in.
- **The runner** is the `capture-eviction` fan-out lane in `grocery/check-ad-cycles.ps1:1509`. It carries no
  `-Due`, so it runs on every ad-cycle generation, and the consumer at `:2593` reads its exit code and its verdict
  line. In `grocery/ad-cycle-log.txt` that lane has recorded a real verdict on **12 of 12** runs - 0 BLIND, 0
  did-not-complete, 0 threw.
- **Will the daily chain produce a stamp?** Yes. `TC Grocery Daily Capture 0800` (Ready, last result 0, next run
  2026-09-12 08:00) runs `grocery/capture-run.ps1 -Kind daily`, which calls `check-ad-cycles` downstream in the
  MAIN checkout, where both inputs the pass needs are present (`candidates-2026-09-11.json` and the 09-11 board).
  So the first stamp lands in `C:\Codex\ThriftyCrew\grocery\out` at about 08:2x, and every worktree seeded after
  that carries it. **Not in any existing worktree**, and not anywhere until then.
- **`ops/seed-worktree.ps1` exiting 2 on it is correct** and is left alone: a `.worktreeinclude` line matching no
  file in the source is MISSING-SOURCE, the target really is blind on it, and the pre-push hook's call is
  best-effort (`|| echo`), so it refuses no push.

## The change

`Get-CaptureEvictionCurrency` in `grocery/test-auditors.ps1` holds the decision as a pure function, and the case
asks it in two steps instead of one:

1. a STAMP decides wherever the checkout has one (unchanged, including the generation match);
2. with no stamp, could this checkout ever have RUN the pass? The live run resolves its input as a dated
   `out/candidates-*.json`, which `.worktreeinclude` does not carry. With none present the verdict is a counted
   **SKIP** naming that, because the tracked report there measures another checkout's commit clock;
3. with candidates present - the chain's own checkout, where the report is that run's own output - the report is
   judged exactly as before, message for message.

The `compare_file` comparison also moved from `-ne` to `[string]::Equals(..., Ordinal)`, for the reason the
`compare_built_at` line beside it already had: PS 5.1's culture-sensitive `-ne` ignores a NUL, so a damaged name
would have read as a clean match.

Two things kept it honest rather than convenient. `ops/audit-write-only-reports.ps1` still finds a reader for the
`capture-evictions` family, because the report is still read in the checkout that writes it - a stamp-only reader
was refused in the first pass for that reason and is still refused. And the SKIP is narrow: it cannot fire where a
stamp exists, and it cannot fire where the pass can run, which is asserted by two of the frozen cases below.

## Verification

Paired, one row per case per arm, same inputs to both arms, in a temp tree that touches no repo file: the HEAD
block and the working-tree block lifted verbatim from the same file and driven with `$root` pointed at the fixture
(`scratchpad/arm-probe.ps1`). Bar stated before the runs: exactly one cell may move, the incident cell, and the
other three lines must be identical text.

| Case (board comparison-2026-09-11.json, built_at 14:27:41) | old | new |
|---|---|---|
| seeded worktree, no candidates, committed report names 09-09 | FAIL `capture-evictions.json audited comparison-2026-09-09.json but the newest board is comparison-2026-09-11.json` | **SKIP** `this checkout holds 1 dated board(s) and 0 dated out\candidates-*.json ...` |
| seeded worktree, no candidates, current stamp | PASS ARMED (stamp) | PASS ARMED (stamp), identical text |
| the chain's checkout, candidates present, report names 09-09 | FAIL | FAIL, identical text |
| the chain's checkout, candidates present, current report | PASS ARMED (report) | PASS ARMED (report), identical text |

1 of 4 cells moved, and it is the incident. The other 3 are byte-identical across arms.

## What this leaves, stated

- **A checkout with a fresh board and zero dated candidates now SKIPs rather than FAILs.** In the main checkout
  that cannot arise from retention: `grocery/prune-intermediates.ps1` keeps the newest 3 and refuses to prune to
  zero. If it ever did arise there, the case reports a counted SKIP with its reason, which is a could-not-look and
  is printed in both summaries - never a silent pass.
- **Existing worktrees get the SKIP, not the stamp.** The pre-push hook seeds once, gated on a missing built card,
  so it will not re-copy into a worktree that already has one. That is the honest outcome for a checkout that
  cannot run the pass, and any worktree made after tomorrow's 08:2x chain gets the stricter stamp test instead.
- **Nothing here makes a hand-run chain commit the report**, and nothing here needs it to.
