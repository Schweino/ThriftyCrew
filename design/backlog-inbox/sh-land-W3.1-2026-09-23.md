# Lane: sh-sync landing, W3.1 of design/PLAN-bot-checkout-self-heal-2026-09-23.md, 2026-09-23

Filed by W3.1's landing push, as the landing stage asks of every item that section 8 of the plan gives a bar. Section
8 names W3.1 in three live bars, B4, B5 and B8, and in seven mutants, M2, M3, M5, M6, M7, M10 and M11. What W3.1
landed, by blob, because a rebase cannot move a blob: `lib/checkout-sync.ps1` eb1b66d6a56d22b97a80e7488bcdf32eb7fb53f2,
`lib/test-checkout-sync.ps1` 7a6ba2088be7af6753fb84fa2ac7ae7310b60608.

**Nothing calls the lib in production yet.** `grocery/capture-run.ps1` gains its call in W4.1, and until then no armed
run syncs through it. So B4, B5 and B8 each read N=0 however long they wait. Their 14-day clock is counted from
W4.1's landing, and 2026-10-07 below is the earliest date the read-out can happen.

## read out the section 8 mutants for w3.1: M2, M3, M5, M6, M7, M10, M11

`DONE` `queue-sh-sync`

**The bar, as section 8 wrote it before the run.** Each mutant runs from a temp mirror, one at a time, with the
original md5-identical afterwards, and turns its named W3.1 case red. A survivor means the item is not done.

**Read out 2026-09-23 by the lane, on the first lib, before the review fixes.** From the lane's first W3.1 commit
message: the control exited 0 with 0 red. M2 was killed with 2 red in the M2 TARGET case, M5 with 3 red (autostash
ONE PAST), M6 with 5 red (the JSON markers case), M7 with 1 red (detached during a rebase), M10 with 1 red (the undo
copy after a throw past read-tree) and M11 with 7 red (F11). That message records M3 as run, but the tally is cut off.

**Not re-run on the landed lib.** The review fixes changed the lib after that read-out. The landing ran the lane's own
review-fix probe instead: 16 single mutants plus a control, each from its own temp mirror, 3 at a time rather than one
at a time. The control passed 162 of 162. All 16 mutants were red, each in its own named case. The original's md5 was
1231CAB244819E44F404A89136A53599 before and after. The harness is the scratch file `cs-mutants.ps1` and is not
committed. **The plan's seven should be run again against blob eb1b66d6a56d before section 13 records them as holding
for the landed lib.**

**Re-verified at landing, on the tree rebased onto origin/main.** `lib/checkout-sync.ps1 -SelfTest` exited 0 with
`checkout-sync: 162 passed, 0 failed, 162 of 162 literal cases ran`, then `CHECKOUT-SYNC SELF-TEST PASS`.
`lib/gate-input-key.ps1 -VerifyDeclared lib\checkout-sync.ps1` exited 0 with `GATE-DECLARATIONS-VERIFIED 1 of 1`.

## read out bars b4, b5 and b8 for w3.1 on 2026-10-07 at the earliest, 14 days after W4.1 lands

`OPEN` `queue-sh-sync` `2-WAY` `RUNG1 MEASURE`

**The bars, as section 8 wrote them before any run.** Each is measured by `grocery/report-checkout-sync.ps1` (W1.2),
cited by its blob, over armed capture-run runs.
- **B4**: dirty paths outside the write set whose fingerprint (porcelain line, length, mtime) changed across a sync,
  summed over syncs that moved HEAD. Minimum N: 10 moving syncs. Bar: 0 paths, deterministic. Shared with W4.
- **B5**: armed runs whose captures started with unmerged entries, or with new marker triples in any dirty tracked
  file. Minimum N: 20 armed runs. Bar: 0, deterministic. `blocked-checkout` exits are reported beside it. Shared with
  W4.1.
- **B8**: syncs whose read-tree hit `unable to unlink`, counted as ending verified (`synced`, or `blocked` class
  `held-file`) out of all such syncs. Reported at any N and judged at 3. Bar: all of them, with 0 `mixed-tree`
  outcomes, deterministic.

**Read-out date: 2026-10-07 at the earliest**, which is this landing date plus section 8's default 14 days. The real
date is W4.1's landing date plus 14 days, because no run can sync through this lib before W4.1. Section 13 of the plan
carries one line per bar: `B<n>: <result> (N=<n>, report blob <id>, window <from>..<to>)`. A bar whose N is under its
minimum gets no verdict, never a pass.

**What it needs.** W4.1 has to land first. Nothing runs the report's `-Due` on a schedule, so this heading is the
reminder until a task does.
