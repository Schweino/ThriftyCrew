# Lane: pd-promptbackup landing, W8.4 of design/PLAN-push-derived-conflicts-2026-09-23.md, 2026-09-23

Filed by W8.4's landing push, as section 8 ("Read-outs have an exit code") asks of every item with a bar until W3.4's
task runs `ops/probe-push-convergence.ps1 -Due` twice a day. **B15 is NOT in that probe's literal bars table** (blob
363b6669283bd851d1cb5ec6dd9173c1d946d0bc at this push lists B1 to B11 only), so `-Due` will not page for it. Section
15.6 says each item's landing adds its bar to that table; this landing did not, because the probe is not this lane's
file. Until somebody adds the row, this file is the only thing that carries B15's date.

## read out bar B15 for W8.4 (prompt-backup refusals of pushes that changed no prompt, and the daily floor) on 2026-10-07

`OPEN` `queue-7` `2-WAY` `RUNG1 MEASURE`

**The bar, as section 15.6 of the plan wrote it before the run.** B15 judges W8.4 alone.
- Metric: push refusals classed `run-gates:ops\audit-prompt-backup.ps1` on a push that changes nothing under
  `ops/prompt-backup/` and not the audit.
- Stratum and minimum N: 14 days.
- Baseline, as the plan wrote it: 5 of 19 kept in-hook red logs dated 09-20 to 09-23 (SCRATCH, correctness skeptic).
- Bar: 0, as a mechanism (any counted row is a defect in W8.4, so no P(zero | old rate) is owed); and the daily
  check's COMPLETE marker on at least 13 of 14 days (the floor).

**Read-out date.** **2026-10-07**, 14 days after this landing, the read-out every bar takes
(`$script:TcPpcReadoutDays = 14` in the probe blob above). The result goes in section 13 of the plan as
`B15: result <verdict> over <N> (<window>, audit-prompt-backup blob <id>)`, the harness cited by its blob.

**How to count the first half, and what it cannot see.** A refusal inside the hook ends with the fixed line
`PRE-PUSH-REFUSED cause=run-gates gate=<first failing gate>` (`ops/hooks/pre-push`, blob
1231686d9532d172537dfd723c6f6da068205749). A plain push's refusal is a `hook-refused` push-ledger row carrying `cause`
and `gate` (`ops/record-hook-refusal.ps1`, blob df6c7841afe7cee2468c7c8bc82fc4e430f86fe5); an in-lock refusal under
push-main is a `push-rejected` row whose `reject_class` push-main reads off that line. Count the rows from this landing
to 2026-10-07 whose cause is run-gates and whose gate is `ops\audit-prompt-backup.ps1`, then keep those whose pushed
range changes nothing under `ops/prompt-backup/`, `.claude/agents/` or `.claude/skills/`, and not the audit or
`ops/prompt-backup-exempt.json` (the paths the push mode still judges as the push's own). **One road names no gate**:
push-main's own gate BEFORE the lock writes `refused-gate-red` with no gate field (`ops/push-main.ps1` blob
c63e2a7cda577beef80ffebdfb5c25e807cba745, line 426). Those rows are attributed from their run logs where one was kept,
and the read-out prints how many it could not attribute beside the count, rather than reading them as zero.
Every gated push after this landing runs the new audit: push-main rebases before it gates, and a plain push from a base
origin/main has moved past is refused by `lib/push-landable.ps1` before any gate runs. So no older-copy exclusion is
needed for the first half, and the read-out says so if it finds otherwise.

**How to count the floor.** Every chain run logs the whole marker into `grocery/ad-cycle-log.txt`, on a line whose
text after the timestamp begins `prompt-backup daily` (clean: `prompt-backup daily: nothing on the mirror on main has
disagreed ...`; a finding: `prompt-backup daily rc=<n> - ...`), carrying `PROMPT-BACKUP-COMPLETE mode=daily
scanned=<n> findings=<n> failed=<n> fresh=<n> source=<sha>`. A run that did not finish logs `prompt-backup daily DID
NOT RUN TO THE END` or `prompt-backup daily threw:` instead, and a day with only those counts as a missed day. Count distinct dates with the marker line. **The window starts on the first chain run whose checkout
holds this landing**, which the read-out takes from the log's first `prompt-backup daily` line, never from an assumed
date: the chain runs from the main checkout's working tree, which moves only when that checkout is rebased. Read once
by hand from this lane's worktree (read-only, no write mode): `-Daily` exit 0, `PROMPT-BACKUP-COMPLETE mode=daily
scanned=30 findings=0 failed=0 fresh=0`. That is a worktree run, which skips SCOPE DRIFT, so it is not a floor day.

**What W8.4 landed, by blob** (a rebase cannot move these): `ops/audit-prompt-backup.ps1`
560ed0178c99a2a784855c5ce7d02bf4091464c3, `grocery/check-ad-cycles.ps1` 92654f01612f9a2ab0af04a42bc1c1ce7d472cd6, and
`design/backlog-inbox/pd-promptbackup-2026-09-23.md` 6fa6737a38c59a12439c096de37898bbbef8a141 (four findings in files
this lane did not own).

**W8.4's own checks on the rebased tree.** Every suite exits 0 with its verdict line: `ops/audit-prompt-backup.ps1
-SelfTest` 81 of 81, `grocery/check-ad-cycles.ps1 -SelfTest` 33 of 33, `lib/gate-input-key.ps1 -VerifyDeclared
ops\audit-prompt-backup.ps1` 1 of 1 (probes=2), and `ops/merge-backlog-inbox.ps1 -ValidateFile` on the lane's inbox
file would merge 4 findings.

**No re-read row was written, and why.** `ops/audit-conclusion-currency.ps1 -ReportOnly` (blob
e4e5d60f9d016250ea25ae2e5b348034c151e771) on the rebased tree reads 4 of 26 UNQUALIFIED, the baseline of 4. The one
document that enrols a file this lane changed is `design/MEASURE-daily-chain-stages-2026-09-09.md` (harness
`grocery/check-ad-cycles.ps1`), which was UNQUALIFIED before this lane by 59 commits of its harness and reads 60 now.
Read against W8.4: its conclusions are about the stages of one 2026-09-09 run (test-auditors, the INSPECT fan-out,
publish-deals-page, paywall-leak, instore-channel), and W8.4 changes none of those; it moves one audit from once a
week to every run. A ledger row qualifies the pair at this blob for all 60 commits, and nobody has read the other 59,
so a row would claim a re-read that did not happen. For whoever does it: the committed log at this push reads chain
totals of 2,179 to 3,249 s and test-auditors of 637 to 1,167 s over its last five `run complete` runs (2026-09-21 to
2026-09-23), against the document's 1,630 s and 421 s, so its numbers now describe that one day only.
