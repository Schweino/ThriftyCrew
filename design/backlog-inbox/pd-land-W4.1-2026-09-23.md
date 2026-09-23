# Lane: pd-currency landing, W4.1 of design/PLAN-push-derived-conflicts-2026-09-23.md, 2026-09-23

Filed by W4.1's landing push, as section 8 ("Read-outs have an exit code") asks of every item with a bar until W3.4's
task runs `ops/probe-push-convergence.ps1 -Due` twice a day. W0.3 has landed, so its bars table already carries B5 and
reads W4.1's landing from the first commit on the main ref whose message carries
`Plan: design/PLAN-push-derived-conflicts-2026-09-23.md W4.1`; this file is the human-readable half until W3.4 pages.

## read out bar B5 for W4.1 (re-reads written as ledger rows, and re-read conflicts) on 2026-10-07

`OPEN` `queue-7` `2-WAY` `RUNG1 MEASURE`

**The bar, as section 8 of the plan wrote it before the run.** B5 judges W4.1 alone.
- Metric: (a) re-reads written as ledger rows, of all re-reads added (ledger rows plus new `Re-read at` doc lines,
  `reread_doc_lines`); (b) conflict rows in class `reread`.
- Stratum and minimum N: (a) at least 10 re-reads.
- Baseline: (a) 0 (there was no ledger); (b) 2 of 365 rows, 0.55% (the census in plan section 2.2).
- Bar: (a) at least 90% ledger rows. (b) is reported with P(0 under the old rate) and gives no verdict: at 0.55% a zero
  in 200 rows has a 33% chance with no fix at all, and 5% needs about 545 rows.
- Under its minimum N the bar is reported with its N and gives no verdict.

**Read-out date.** `ops/probe-push-convergence.ps1` (blob 571be8393ecc7861cbb0eb857a5abcfabbe390db at this push) applies
the same 14 days to every bar (`$script:TcPpcReadoutDays`), so B5 is due **2026-10-07**, 14 days after this landing,
and `-Due` exits 2 after that date until section 13 of the plan carries a line
`B5: result <verdict> over <N> (<window>, W0.3 blob <id>)`. If (a) is still under 10 re-reads that day, the result line
reports the N with no verdict. The harness is cited by its blob at the read-out, never by a commit.

**What the read-out needs first.** (a)'s denominator counts re-reads written as doc lines, and the push-ledger field
that records them, `reread_doc_lines`, is written by W4.1 step 7 in `ops/push-main.ps1`, which lands in wave 2. Until it
does, the doc lines can only be counted from git history (commits on main that add a `Re-read at` line to a
`design/*.md` file), and the read-out says which count it used. (b) reads the class of each conflict row's files
(`design/reread-ledger.tsv` and `design/MEASURE-*` / `design/EVAL-*` are class `reread` in W0.3's class table).

**What is already in the window.** This landing recorded its own four re-reads as the ledger's first four rows (one
push, one checkout), so they count toward (a) and toward its minimum N. W1.2's two re-reads landed before W4.1 as doc
lines, because the ledger did not exist yet, and fall outside the window.

**What W4.1 landed, by blob** (a rebase cannot move these): `ops/audit-conclusion-currency.ps1`
9543df597f69d0c27a5abcbbc7d4eea99240db1a, `ops/audit-reread-ledger.ps1` bd2f2e57283b557a58ae2a3dd92e7146f572bf88,
`ops/add-reread.ps1` 144d4cd5524cf8a964fe46c1809eaf69f9a95bab, `.gitattributes` 7b216ba5984a8d7a911ae5d08a7aeeaccfd88b07,
`ops/run-gates.ps1` ce455bcbda391ff253a9414c94b00a409b61ef34, `grocery/audit-script-census.ps1`
eff45e20302f78974654bc71e49fc599d3b5791b, `.claude/rules/measurement.md` ef37dcd8e6ebb923da8fd2b20d0406c0725113e1, and
`design/reread-ledger.tsv` 8b3d0679256f8b6a6c0bf3d0ac0d0dba9f1732ca (the header and this landing's four rows).

**W4.1's own "Done when" is met on the rebased tree.** Every suite exits 0 with its verdict line:
`ops/audit-conclusion-currency.ps1` 51 of 51, `ops/audit-reread-ledger.ps1` 24 of 24 (the union case under a plain
rebase and under `git -c rebase.autoStash=true rebase -X theirs` among them), `ops/add-reread.ps1` 11 of 11. The live
ledger audit reads `files=1 rows=4 base_rows=absent findings=0` with exit 0. Step 7 is not in this push, as the plan's
wave split says.
