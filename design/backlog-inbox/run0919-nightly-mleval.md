# Backlog run 2026-09-18: graph nightly ml-eval and the harvest crawl's staleness

Found under the I236 work and worked by the nightly-mleval lane on 2026-09-18. Both findings were measured from
the main checkout read-only (its logs, its status file's committed history, and `Get-ScheduledTask`).

## graph nightly's stage runner leaked its echo lines into its return value, and ml-eval's first write ended the chain
`DONE` `run-0919`

**What broke.** `graph/pipeline/nightly.ps1` `Invoke-Stage` echoed the child's last four lines with `Write-Output`,
so every stage that printed anything returned `[line, ..., result]` instead of one result. Reads such as `$r.Ok` and
`$r.Tail` kept working by member enumeration, which is why nothing noticed; the first WRITE, ml-eval's
`$r.Tail = @($mlDetail)` (added by 2a0c60298 on 2026-09-11), threw *"The property 'Tail' cannot be found on this
object"* and the chain's catch recorded `chain FAILED`. The file's own header already warned about exactly this
for `Stop-Llama`; the rule had not reached the runner.

**How many nights.** Over the 19 committed versions of `grocery/out/logs/graph-nightly-status.json` on origin/main
(2026-08-23 to 2026-09-18), exactly 1 carries it: the 2026-09-17 21:30 run (1a20a05c6). It was the first night
ml-eval was DUE after 2a0c60298: the weekly stamp read 2026-09-07T21:33:43, so the 09-11 to 09-14 runs were all
inside 7 days (the 09-11 status records `ml-eval SKIP`; the 09-12 to 09-14 statuses were never committed because
bot-commit-scope refused those commits until a34add59f), and no graph-nightly transcript exists for 09-15 or 09-16.
It would have failed every night from 09-17 on, because the failure came before the stamp write.

**What the graph missed.** Nothing downstream: ml-eval is the LAST stage in the chain's try, and the finally
(llama-server stop, status write) and the commit still ran, rc 0. What was lost is ml-eval's own output: its stage
record, which is the only committed copy of the week's hardeval summary line, and `ml-eval-last.txt`, so the suite
would have re-run every night instead of weekly. hardeval itself did run to completion and wrote its gitignored
`weekly`-tagged pair.

**Fix.** The echo goes through `Log` (`[Console]::WriteLine`), which reaches stdout without touching the return.
`nightly.ps1 -SelfTest` drives `Invoke-Stage` through a real `cmd` child that prints three lines: MUST FIRE asserts
one result object whose `Tail` can be set, CLEAN TWIN asserts Ok, rc 0 and the three lines as Tail. With the old
`Write-Output` restored the MUST FIRE went red (`got 4`, exit 2); restored, exit 0, md5 identical. No other
`$r.<prop> =` site exists in the file. Two unlanded sibling branches (`claude/serene-lichterman-3e9092`,
`claude/commit-outcome-exit-codes-v2`, 2026-09-12) had changed the same line to `Write-Host`; neither landed.

**What the next nightly does.** Once the main checkout carries this, ml-eval is due (last stamp 2026-09-07), so it
runs `hardeval.py --stage score --tag weekly` on the frozen defs within min(1800 s, remaining window), records
`ml-eval OK` with the `hardeval:` summary in the status file, and writes `ml-eval-last.txt`. It changes no price and
nothing on the board.

## TC Recipe Harvest Crawl reads stale because it is paused by ruling until 2026-09-20, and its registrar would have undone that ruling
`NEEDS A RULING` `run-0919` `2-WAY` `RUNG1 RULING`

**Why it is stale.** `Get-ScheduledTaskInfo` on 2026-09-18: LastRunTime 2026-09-17 07:12:19, LastTaskResult 1,
NumberOfMissedRuns 0, NextRunTime 2026-09-20 18:00. The three scheduled runs that morning (05:12, 06:12, 07:12)
each crawled and then exited 1 because bot-commit-scope refused `candidate-pool.json` and `harvest-state.json`, the
lane-ownership gap a34add59f closed at 08:21 the same morning; a hand run at 08:28 then exited 0. At 08:41,
Brad's ruling (4d5d96b43) retired the daily crawl to a five-evening retry of four 429 publishers: the live task
now has one daily trigger from 2026-09-20 18:00 to an EndBoundary of 2026-09-25, no repetition, and `-Domains`.
So nothing is broken on the repo side and no run was missed; health-heartbeat's `max_age_hours: 30` simply does not
know about a deliberate pause, and reads the task TASK STALE (33.3 h at 16:30, 35.7 h later) until the 09-20 run.

**Fixed here (repo side).** `meal-prep/pipeline/install-harvest-task.ps1` built the pre-ruling task: no `-Domains`,
an open-ended trigger and hourly repetition, so a re-run would have silently restored the full daily crawl. Its
defaults are now the live task's values (read with `Get-ScheduledTask`, not changed), and its self-test compares
what it would register with `ops/scheduled-tasks/tc-recipe-harvest-crawl.xml`: the argument string exactly, the
trigger's wall-clock start and EndBoundary, and whether repetition is added. Three mutants (domains, end and start
defaults blanked) each went red in their named case, exit 1; restored 15 of 15 pass, md5 identical.

**The question for Brad.** After 2026-09-25 the trigger never fires again, so from about 2026-09-26 the heartbeat
will page TASK STALE for this task every morning, permanently. Options:
1. Retire it when the window closes: unregister the task, and drop its `windows_tasks` row and committed definition
   in the same change (the registration audit requires the three to agree).
2. Teach health-heartbeat to read a task's trigger boundaries: not due before StartBoundary, retired after
   EndBoundary, printed as an OK line rather than paged. General, but it widens what a silent death can hide behind.
3. Leave it, and accept the page as the reminder to do 1.

**Recommendation: 1**, done by whoever reads the 09-24 run's result, because the ruling already says the crawl
stops at 09-25 and a paging row for a retired task is exactly the ignored-red the rules warn about. Option 2 is
worth it only if a second task gets a bounded schedule.
