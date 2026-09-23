# Lane: pd-backlog landing, W3.1 of design/PLAN-push-derived-conflicts-2026-09-23.md, 2026-09-23

Filed by W3.1's landing push, as section 8 ("Read-outs have an exit code") asks of every item with a bar until W3.4's
task runs `ops/probe-push-convergence.ps1 -Due`. W0.3 has not landed, so its bars table does not exist yet to carry
W3.1's landing commit and read-out date; this file is where they are tracked until it does.

## read out bar B4 for W3.1 (backlog conflicts and direct backlog edits) from 2026-09-30

`OPEN` `queue-7` `2-WAY` `RUNG1 MEASURE`

**The bar, as section 8 of the plan wrote it before the run.** B4 judges W3.1 and W3.2 together.
- Metric: (a) landings with `backlog_direct` over 0; (b) conflict rows whose `conflict_files` include
  `design/BACKLOG-course-findings.md`.
- Stratum and minimum N: (a) at least 50 landings; (b) at least 60 push-main rows from parallel runs (at least 4
  distinct checkouts sharing one `session`, each writing a push-main row inside one 2-hour window).
- Baseline: (a) 142 of 299 landings TOUCHED the backlog over 7 days (a touch, not only a direct edit); (b) 14 of 22
  conflict rows, about 5% of rows on 09-18 and 09-19 (14 in 276 to 278).
- Bar: (a) at most 10% of landings; (b) 0, where P(0 in 60 rows at 5%) = 0.95^60 = 4.6%.
- Under its minimum N a bar is reported with its N and gives no verdict. Rows are counted only from push-main copies
  whose `pm_blob` maps to a commit at or after W3.1's landing, with `older-copy rows excluded N` printed.

**Read-out dates.** The plan does not fix a date for B4, so the landing stage chose these: first read-out
**2026-09-30**, 7 days after landing, the window every B4 baseline figure was measured over and the one D3 names for
its evidence. If either half is still under its minimum N that day, report the N with no verdict and read it again on
**2026-10-07**, 14 days after landing, the cadence section 6 gives B6. The result is one line in section 13 of the plan,
`B4: result <verdict> over <N> (<window>, W0.3 blob <id>)`, which is what `-Due` will look for once W0.3 lands.

**What the read-out needs first.** (a) cannot be measured until W3.2 lands, because W3.2 is what writes
`backlog_direct` into the push ledger. (b) needs W0.1's `conflict_files` on the rows. The harness is
`ops/probe-push-convergence.ps1 -Cost` (W0.3), cited by its blob at the read-out, never by a commit.

**What W3.1 landed, by blob** (a rebase cannot move these): `ops/merge-backlog-inbox.ps1`
66d187b2a0f3f073b0bd73f9f7e81ca4dca82543, `ops/audit-backlog-status.ps1` 0bbbe8059a3d5c2b1bcc2357b3e1bbea9a741e3b,
`design/backlog-inbox/README.md` c09dae7831a5f94318b3056e01a9dfbfba0e6eed.

**W3.1's own "Done when" is half met.** The self-tests exit 0 with their verdict lines (62 of 62 and 39 of 39 on the
rebased tree). The other half, "the first real lane files an UPDATE that merges", has not happened yet, and the first
real `## UPDATE` block through `design/backlog-inbox/updates/` is the evidence that closes it.
