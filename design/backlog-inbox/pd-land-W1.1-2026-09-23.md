# Lane: pd-hook landing, W1.1 of design/PLAN-push-derived-conflicts-2026-09-23.md, 2026-09-23

Filed by W1.1's landing push, as section 8 ("Read-outs have an exit code") asks of every item with a bar until W3.4's
task runs `ops/probe-push-convergence.ps1 -Due`. W0.3 has not landed, so its bars table does not exist yet to carry
W1.1's landing commit and read-out date; this file is where they are tracked until it does.

## read out bar B2b for W1.1 (lock time on pushes refused for a missing rehearsal verdict) from 2026-09-30

`OPEN` `queue-7` `2-WAY` `RUNG1 MEASURE`

**The bar, as section 8 of the plan wrote it before the run.** B2b judges W1.1 alone.
- Metric: `lock_held_ms` on push ledger rows refused for a missing rehearsal verdict (`reject_class` `rehearsal`).
- Stratum and minimum N: at least 3 such rows.
- Baseline: a full test-auditors ran 792 s and 709 s inside the lock before two such refusals (the cost
  investigator's figures, plan section 2.2).
- Bar: median at most 60 s.
- Under its minimum N the bar is reported with its N and gives no verdict. Rows are counted only from push-main copies
  whose `pm_blob` maps to a commit at or after W1.1's landing, with `older-copy rows excluded N` printed.

**Read-out dates.** The plan does not fix a date for B2b, so the landing stage chose the same cadence the W3.1 landing
chose for B4: first read-out **2026-09-30**, 7 days after landing. If there are fewer than 3 qualifying rows that day,
report the N with no verdict and read it again on **2026-10-07**, 14 days after landing. The result is one line in
section 13 of the plan, `B2b: result <verdict> over <N> (<window>, W0.3 blob <id>)`, which is what `-Due` will look for
once W0.3 lands.

**What the read-out needs first.** Both fields the bar reads are written by W0.1, which has not landed: at this push
`lib/push-ledger.ps1` and `ops/push-main.ps1` write neither `lock_held_ms` nor `reject_class`, so no row from before
W0.1's landing can count, whatever its date. The window therefore opens at the LATER of W0.1's landing and the moment
the new hook was installed. The harness is `ops/probe-push-convergence.ps1 -Cost` (W0.3), cited by its blob at the
read-out, never by a commit.

**The hook is a copy, so the change binds only once it is installed.** `ops/hooks/pre-push` runs from the common
`.git\hooks`, installed by `ops/install-hooks.ps1`. The landing stage installs it from a clean worktree detached at the
landed origin/main straight after this push and reads `ops/audit-hook-installed.ps1` exit 0; until then every push on
the box runs the old hook and refuses a rehearsal only after run-gates and test-auditors. A read-out that finds the
installed copy's blob is not the one below reads the window as not started, not as a failed bar.

**What W1.1 landed, by blob** (a rebase cannot move these): `ops/hooks/pre-push`
1edfa22bba664754d04ca842686af264d1b062d8, `ops/test-prepush-hook.ps1` 15527e3fc153e2e9ca6dfeeb185c93b28a4f10e6.

**W1.1's own "Done when".** Item 1 is met: `ops/test-prepush-hook.ps1` exits 0 with "test-prepush-hook selftest: 63 of 63
cases pass" on the rebased tree, and the plan's mutant M2 (the rehearsal block moved back after run-gates) turned 2 of
63 red, both W1.1 cases. Items 2 and 3, the install and `ops/audit-hook-installed.ps1` exit 0, follow this push and are
recorded in the landing report, because they cannot happen before the content they install is on main.
