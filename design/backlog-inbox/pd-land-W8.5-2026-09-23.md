# Lane: pd-tapre landing, W8.5 of design/PLAN-push-derived-conflicts-2026-09-23.md, 2026-09-23

Filed by W8.5's landing push, as section 8 ("Read-outs have an exit code") asks of every item with a bar until W3.4's
task runs `ops/probe-push-convergence.ps1 -Due` twice a day. **B16 is NOT in that probe's literal bars table** (blob
363b6669283bd851d1cb5ec6dd9173c1d946d0bc at this push lists B1 to B11 and B2b only), so `-Due` will not page for it.
Section 15.6 says each item's landing adds its bar to that table; this landing did not, because the probe is not this
lane's file (the build lane's own inbox file, `pd-tapre-2026-09-23.md`, files that as a finding). Until somebody adds
the row, this file is the only thing that carries B16's date.

## read out bar B16 for W8.5 (test-auditors refusals whose only newly failing cases are PREEXISTING) on 2026-10-07

`OPEN` `queue-7` `2-WAY` `RUNG1 MEASURE`

**The bar, as section 15.6 of the plan wrote it before the run.** B16 judges W8.5 alone.
- Metric: test-auditors refusals whose only newly failing cases are PREEXISTING.
- Stratum and minimum N: at least 10 test-auditors refusals. Under 10 the read-out states its N and gives no verdict.
- Baseline, as the plan wrote it: 13 of 44 named gate refusals over 7 days were board-data reds (SCRATCH, residual,
  coverage 44 of 78).
- Bar: 0, as a mechanism (a refusal whose every new failing case failed at the base too is a defect in W8.5, so no
  P(zero | old rate) is owed). Reported beside it, with no verdict: PREEXISTING cases per day, and test-auditors
  refusals per 100 push-main rows against W0.3's recomputed baseline.

**Read-out date.** **2026-10-07**, 14 days after this landing, the read-out every bar takes
(`$script:TcPpcReadoutDays = 14` in the probe blob above). The result goes in section 13 of the plan as
`B16: result <verdict> over <N> (<window>, prepush-test-auditors blob <id>)`, the harness cited by its blob.

**What to count.** W8.5 prints one line per case it judged at the base, and the case key is what makes the metric
countable: `  PREEXISTING           <case key>: fails at the base <sha9> too (base run rc=<n>) ...` for a case that fails
there too, and a `NOT PREEXISTING` line naming why for one that does not (it passes at the base, the base could not be
resolved, the base run was blind, and so on). The check's completion marker carries `preexisting=<n>` whenever n is
above 0. A counted row for B16 is a test-auditors refusal whose kept output shows at least one new failing case and
every one of them on a `PREEXISTING` line.

**Where the refusals are, and what each road can and cannot see.**
- A plain push refused in the hook writes a `hook-refused` push-ledger row with `cause` `test-auditors` and `log`
  naming the kept `tc-prepush-ta-<pid>.log` (`ops/hooks/pre-push` blob 1231686d9532d172537dfd723c6f6da068205749,
  `ops/record-hook-refusal.ps1` blob df6c7841afe7cee2468c7c8bc82fc4e430f86fe5). Read the log the row names.
- push-main runs the same check before the lock and, on a red, writes `refused-gate-red` with no gate field
  (`ops/push-main.ps1` blob c63e2a7cda577beef80ffebdfb5c25e807cba745, line 426), so run-gates and test-auditors reds
  share one outcome there. Those rows are attributed from their run logs where one was kept, and the read-out prints
  how many it could not attribute beside the count, rather than reading them as zero.
- **The per-day PREEXISTING figure has no machine-wide record for an ALLOWED push.** The hook deletes its log when the
  check passes (the `rm -f "$talog"` on its pass path), and a push-main row carries event, wait, state, base, grant,
  outcome and checkout only. So the reported-only half can be read from kept run logs alone, and the read-out prints
  how many pushes it could read beside it.

**Older copies.** The hook runs `ops/prepush-test-auditors.ps1` from the pushing checkout. push-main rebases before it
gates, and a plain push from a base origin/main has moved past is refused by `lib/push-landable.ps1` before any check
runs, so every judged push after this landing runs W8.5. The read-out says so if it finds otherwise.

**What W8.5 landed, by blob** (a rebase cannot move these): `ops/prepush-test-auditors.ps1`
f2940061f53137e428bf010dca357dac805a6452 (from 822dee11f36b2a61fee4d508bee4b769e56140d8), and
`design/backlog-inbox/pd-tapre-2026-09-23.md` 3a1c3f9b348849bd1ccd36f65b2a51a19b196646 (three findings, among them
EXPECTED-LIVE-RED not recognising a real `LIVE-RED` line).

**W8.5's own checks on the rebased tree** (rebased onto origin/main at dbc7b87d8, 23 commits past the build base, no
conflict; the owned file was not touched on main in between). Every suite exits 0 with its verdict line:
`ops/prepush-test-auditors.ps1 -SelfTest` 119 of 119 in 63 s, `ops/test-prepush-hook.ps1 -SelfTest` 67 of 67 (it copies
the check and drives it through real pushes; 63 at the build base, the 4 added are main's), and
`ops/merge-backlog-inbox.ps1 -ValidateFile` on the lane's inbox file would merge 3 findings.
`lib/gate-input-key.ps1 -VerifyDeclared ops\prepush-test-auditors.ps1` exits 1 NOT-VERIFIED because the self-test
declares no `# gate-inputs:` line, so it is never skipped by key: unchanged by this lane.

**No re-read row was written, and why.** `ops/audit-conclusion-currency.ps1 -ReportOnly` (blob
e4e5d60f9d016250ea25ae2e5b348034c151e771) on the rebased tree exits 0 and reads 4 of 26 UNQUALIFIED
(`EVAL-alert-retention-2026-09-09.md`, `MEASURE-daily-chain-cost-2026-09-09.md`,
`MEASURE-daily-chain-stages-2026-09-09.md`, `MEASURE-gate-cost-2026-09-09.md`), whose harnesses are
`ops/member-cohorts.ps1`, `grocery/guards.ps1`, `grocery/check-ad-cycles.ps1` and `ops/run-gates.ps1`. None is a file
this lane changed. `git grep -l prepush-test-auditors -- design/MEASURE-*.md design/EVAL-*.md` finds 0 documents, with
the same search for `run-gates` finding 10 as the positive control, and `design/reread-ledger.tsv` has no row naming
it. So no document enrols the changed file as a harness and no re-read is owed.
