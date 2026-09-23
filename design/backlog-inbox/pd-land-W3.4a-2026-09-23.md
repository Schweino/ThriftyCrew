# Lane: pd-backlog2 landing, W3.4a of design/PLAN-push-derived-conflicts-2026-09-23.md, 2026-09-23

Filed by W3.4a's landing push, as section 8 ("Read-outs have an exit code") asks of every item with a bar until W3.4's
task runs `ops/probe-push-convergence.ps1 -Due` twice a day. **B19 is NOT in that probe's literal bars table** (blob
363b6669283bd851d1cb5ec6dd9173c1d946d0bc at this push lists B1 to B11 and B2b only), so `-Due` will not page for it.
Section 15.6 says each item's landing adds its bar to that table; this landing did not, because the probe is not this
lane's file. Until somebody adds the row, this file is the only thing that carries B19's date.

## read out bar B19 for W3.4a (backlog conflict rows where both colliding commits carry a Backlog-Merged-From trailer) on 2026-10-07

`OPEN` `queue-7` `2-WAY` `RUNG1 MEASURE`

**The bar, as section 15.6 of the plan wrote it before the run.** B19 judges W3.4a (Brad's ruling D17: the scheduled
merge is the only allocator of backlog ids, and a hand merge needs `-AllowHandMerge "<reason>"`).
- Metric: push-ledger conflict rows in class `backlog-index` whose colliding commits BOTH carry a
  `Backlog-Merged-From:` trailer, which is two merges allocating from two copies.
- Stratum and minimum N: 14 days of rows. No minimum count: it is a mechanism bar.
- Baseline, as the plan wrote it: none observed since W3.1 (about 1 hour of rows).
- Bar: 0, as a mechanism, once D17 lands. Any counted row is a defect, so no P(zero | old rate) is owed.

**Read-out date.** **2026-10-07**, 14 days after this landing, the read-out every bar takes
(`$script:TcPpcReadoutDays = 14` in the probe blob above). The result goes in section 13 of the plan as
`B19: result <verdict> over <N> (<window>, merge-backlog-inbox blob <id>)`, the harness cited by its blob.

**The mechanism is only ARMED once the task is live, and the read-out must say which days it was.** W3.4a refuses a
hand merge only while an allocator is live on this box: some `<common .git>\worktrees\*\` holds a
`tc-backlog-allocator` marker whose checkout still exists. That marker is written by the TC Backlog Merge task
(`ops/run-backlog-merge.ps1`, W3.4), which lands after this and is registered later still. Until then a merge anywhere
proceeds as before, prints a WARN, and ends its trailer line with `; hand-merge: no scheduled allocator was live on
this box`. So:
- Count the window from the task's FIRST scheduled run (its log is `ops\out\logs\backlog-merge-<date>.log` in the main
  checkout), not from this landing, and print the days before it separately. A collision in those days is the old
  behaviour, not a defect in W3.4a.
- Read the trailer, not only its presence. A task merge's line is `Backlog-Merged-From: <files>` with no suffix; a hand
  merge's ends `; hand-merge: <reason>`. A counted row whose two commits are both hand merges with the no-allocator
  reason is the degrade working as designed; one where either commit is a hand merge made while the task was live, or
  both are task merges, is the defect B19 exists for. Print the three kinds separately.

**What W3.4a landed, by blob** (a rebase cannot move these): `ops/merge-backlog-inbox.ps1`
d44f2c8a598df5e570ec3532585cecf2f63fc48b (from 66d187b2a0f3f073b0bd73f9f7e81ca4dca82543).

**W3.4a's own checks on the rebased tree** (rebased onto origin/main at 69aaf57c4, 26 commits past the build base, no
conflict; none of the 26 touched this lane's files). `ops/merge-backlog-inbox.ps1 -SelfTest` exits 0 with
`merge-backlog-inbox self-test: 73 of 73 cases pass`.

**No re-read row was written, and why.** `ops/audit-conclusion-currency.ps1 -ReportOnly` on the rebased tree exits 0
and reads 4 of 26 UNQUALIFIED (`EVAL-alert-retention-2026-09-09.md`, `MEASURE-daily-chain-cost-2026-09-09.md`,
`MEASURE-daily-chain-stages-2026-09-09.md`, `MEASURE-gate-cost-2026-09-09.md`), whose moved harnesses are
`ops/member-cohorts.ps1`, `grocery/capture-watchdog.ps1`, `grocery/guards.ps1`, `grocery/check-ad-cycles.ps1` and
`ops/run-gates.ps1`. None is a file this lane changed, so no re-read is owed.
