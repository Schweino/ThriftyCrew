# Backlog run 2026-09-19: the Fareway and Sam's Club capture stall

Worked by the worklist-terms lane on 2026-09-18 (the orchestrator's run-0919). The evidence was read from the main
checkout read-only: its `grocery\out\worklists\capture-*-2026-09-1*.json`, its raw captures and its
`grocery\out\logs\capture-run-daily-*.log`.

## The daily worklist lost `terms` and `commodities` on 2026-09-12, and the browser driver read that as "nothing owed today"
`DONE` `run-0919`

**What broke.** 7e1c7d94e (2026-09-12 11:58, the Walmart store-drift ruling terms) replaced the two lines of
`Write-CaptureWorklist` (`grocery/capture-policy-lib.ps1`) that wrote `terms` and `commodities` with the new
`ruling_terms` block, instead of adding it beside them. `grocery/pull-browser-stores.py` reads exactly those two
fields (`read_worklist` for the sweep lane, `read_worklist_pairs` for Fareway's navigate lane), read the missing
field as an empty list, and returned "worklist is empty - nothing owed today", which `run_store` scored `ok
skipped` and the driver exited 0. Every fixture read `Get-CaptureWorklist` in memory, where `Terms` was still
right, so nothing went red.

**Measured in the main checkout.** Of the 49 worklist files dated 2026-09-10 to 09-18 (7 stores x 7 days), the 21
dated 09-10, 09-11 and 09-12 carry `terms` and `commodities` and all 28 dated 09-13, 09-14, 09-17 and 09-18 carry
neither. Each of those four chain logs queues "Fareway 42 term(s)" and "Sam's Club 7 term(s)", then prints
`Fareway ok skipped: worklist is empty - nothing owed today` and the same for Sam's Club, then `browser driver
rc=0`. There is no chain log for 09-15 or 09-16 at all, which is a separate gap this did not cause.

**Capture days lost.** Fareway: the driver captured nothing on 4 of 4 chain runs since 09-12 (09-13, 09-14, 09-17,
09-18); the newest raw capture is still `fareway-shop-2026-09-12.jsonl`, so no Fareway capture exists for 6
calendar days. Sam's Club: the driver captured nothing on 4 of 4 runs, and the 09:00 browser agent landed
`sams-capture-2026-09-17.csv`, so 3 of 4 run days were lost (09-13, 09-14, 09-18); no Sam's capture exists for 5
calendar days. Capture-run only advances a cursor after a capture lands, so Fareway's rotation slice was re-owed
rather than skipped.

**Other lanes that read this shape.** The only programmatic readers of the worklist FILE are the two driver
functions above. The 09:00 browser agent's runbook (`ops/prompt-backup/scheduled-tasks/grocery-browser-stores-refresh/SKILL.md`)
also reads the file's `terms` and its term-to-commodity map for Walmart and Aldi (and Fareway and Sam's when the
driver fails), so it too was handed a file without them from 09-13; that includes the Walmart ruling terms
7e1c7d94e exists to lead with. Walmart and Aldi each have one capture after 09-12 (09-17), and whether the
others were missed because of this cannot be told from the files. Hy-Vee, Family Fare and Baker's never read the
file: they call `Get-CaptureWorklist` in process.

**Fixed.** `Write-CaptureWorklist` writes `terms` and `commodities` again, the merged capped list as parallel
arrays, with every part list (`ruling_terms`, `ad_terms`, `rotation_terms`, `sale_terms`) kept. The driver's
readers now raise `WorklistUnreadable` for a worklist that is missing, not JSON, has no `terms` list, has an empty
`terms` over non-empty part lists, has `commodities` of a different length, or has a blank term or id; `run_store`
reports that as a FAIL beginning `BLIND - could not read the worklist`, and `main()` exits 3. Only a present,
empty `terms` with every part list empty still reads "nothing owed today".

**Verified.** `test-capture-policy.ps1` case Q writes Fareway, Sam's Club and Family Fare worklists with
`Write-CaptureWorklist` and reads each back through the driver's own two readers in a child python: 3, 2 and 2
pairs, in order, Fareway's including both terms of one commodity. Exit 0. With the two restored lines removed:
exit 1, all three Q cases red, each naming `has no terms list`. `pull-browser-stores.py --selftest-lookup` gained
seven cases in `worklist_shape_self_test`: MUST FIRE on the real 09-13 shape through both readers, through
`run_store` on both lanes and through `main()` (exit 3); MUST FIRE on an empty `terms` over owed parts, a length
mismatch and a missing file; CLEAN TWIN on a genuinely empty day (`ok skipped`, exit 0) and on a good list. Exit 0.
With `run_store` scoring the refusal as a skip again: exit 1, the run_store and main() cases red. With the
missing-`terms` refusal disabled: exit 1, its own case red (the empty-over-owed check still caught the run_store
path, so that one mutant was only partly killed: two guards over one rule). Both files restored hash-identical.

**A sibling holds a rival version.** `claude/restore-worklist-terms` (692e1d36b, pushed to origin, not on main)
carries the same writer fix and a narrower reader guard, held as READY FOR BRAD on the grounds that resumed
captures move prices. Both were run over one 8-case list through `run_store` with Chrome stubbed: they agree on 5
(the 09-13 shape fails, an empty day skips, a good list proceeds, a length mismatch and a blank term fail). They
differ on 3: a missing worklist and a worklist with no `terms` and empty parts read `ok skipped` on the sibling
and BLIND here, and a non-JSON worklist throws out of the sibling's reader (scored FAIL, exit 1) and reads BLIND
here. This lane landed under the orchestrator's instruction that restoring the pipeline changes no price by
itself; the sibling branch can be retired.
