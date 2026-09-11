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
