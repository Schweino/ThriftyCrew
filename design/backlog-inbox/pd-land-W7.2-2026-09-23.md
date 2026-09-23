# Lane: pd-plancite landing, W7.2 of design/PLAN-push-derived-conflicts-2026-09-23.md, 2026-09-23

Filed by W7.2's landing push, as section 8 ("Read-outs have an exit code") asks of every item with a bar until W3.4's
task runs `ops/probe-push-convergence.ps1 -Due` twice a day. **Unlike B5, B18 is NOT in that probe's literal bars
table** (blob 571be8393ecc7861cbb0eb857a5abcfabbe390db at this push lists B1 to B11 only), so `-Due` will not page for
it. Section 15.6 says each item's landing adds its bar to that table; this landing did not, because the probe is not
this lane's file and W0.3b is changing it in the same wave. Until somebody adds the row, this file is the only thing
that carries B18's dates.

## read out bar B18 for W7.2 (session commits that change a file an under-way plan names and cite no plan) on 2026-09-30 and 2026-10-07

`OPEN` `queue-7` `2-WAY` `RUNG1 MEASURE`

**The bar, as section 15.6 of the plan wrote it before the run.** B18 judges W7.2 alone.
- Metric: session commits that change a file named by an under-way plan and carry neither a `Plan:` line for that plan
  nor a `Plan-not-applicable: <reason>` line.
- Stratum and minimum N: at least 10 such commits.
- Baseline, as the plan wrote it: 1 known (`5841e96b1`).
- Bar: reported while warn-only; 0 after D18's cutoff.
- Under its minimum N the bar is reported with its N and gives no verdict.

**The baseline is larger than the plan's "1 known", measured before the bar is read.** The build ran
`ops/plan_citation.py --replay 2026-09-16` (harness blob 3e3fc44542991632a8ba87a0ff2101bc16c0dca3, the blob this push
lands) over 598 first-parent non-merge commits on origin/main: 572 session commits by the `Co-Authored-By: Claude` mark,
96 of them changed a file an under-way plan names, 10 of the 96 cited it and 86 did not. 83 of the 86 come from
`design/PLAN-zero-alert-days-2026-09-10.md`, whose Status line still reads RULED. That is filed for a ruling in
`design/backlog-inbox/pd-plancite-2026-09-23.md`, and its answer moves this bar's numerator more than anything W7.2 does.
The read-out prints the replay's count and the log's count side by side and says which test each is: the replay marks
a session by its trailer, the hook by `CLAUDE_CODE_SESSION_ID`, and those are different tests.

**Read-out dates.**
- **2026-09-30, the warn phase.** `REFUSE_FROM = "2026-09-30"` in `ops/plan_citation.py` (the blob above) is 7 days after
  this landing, as D18 ruled. Report the week's warn rows with their denominator (judged commits) and name the plans
  they came from. No verdict: the bar says "reported while warn-only".
- **2026-10-07, the bar.** 14 days after this landing, the read-out every bar takes. Count the commits from 2026-09-30 to
  2026-10-07 that meet the metric. The bar is 0. Name the route of every non-zero row: a checkout whose installed hook
  predates this landing, a commit with no session id, or a bypass. Under 10 such commits in the window the result
  reports its N and gives no verdict.
- The result goes in section 13 of the plan as `B18: result <verdict> over <N> (<window>, plan_citation blob <id>)`.

**Where the rows come from.** Every judged commit appends one row to `%USERPROFILE%\.claude\plan-citation-log.jsonl`
(verdict clear, cited, escape, warn, refuse or blind, with its pairs, the plans under way and the checkout), best effort.
`ops/plan_citation.py --replay <since>` derives the same verdicts from landed history through the same `judge()`, so the
read-out can be rebuilt from main when the log is thin. The log and the replay count blind rows too: a BLIND verdict is a
could-not-look and is counted as neither cited nor uncited.

**What starts the window.** The commit-msg hook is a copy in the common `.git\hooks`. Nothing is judged on this box
until `ops/install-hooks.ps1` has run from a clean worktree at the landed origin/main and `ops/audit-hook-installed.ps1`
reads exit 0. The landing stage does that right after this push. A log row from before the install cannot exist, and the
replay has no such limit, which is one more reason to print both.

**What W7.2 landed, by blob** (a rebase cannot move these): `ops/plan_citation.py`
3e3fc44542991632a8ba87a0ff2101bc16c0dca3 and `ops/hooks/commit-msg` 2e963c6d01de4f0e1960d6fe5ec8cde6d8749a66.

**W7.2's own checks on the rebased tree.** Every suite exits 0 with its verdict line: `ops/plan_citation.py --selftest`
40 of 40, `ops/store_citation.py --selftest` 72 of 72, `ops/test-precommit-hook.ps1 -SelfTest` 19 of 19, and
`lib/gate-input-key.ps1 -VerifyDeclared ops\plan_citation.py` 1 of 1. No re-read is owed:
`ops/audit-conclusion-currency.ps1 -ListHarnessSources` lists 33 pairs and none enrols either file, and `-ReportOnly`
reads 4 UNQUALIFIED, the baseline.
