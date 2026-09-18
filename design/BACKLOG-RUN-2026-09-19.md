# Backlog run, 2026-09-18 to 2026-09-19

The run log for working `design\BACKLOG-course-findings.md` end to end (Brad's brief of 2026-09-18). One line
per item: state, landed commit on origin/main, or the reason it stopped. **If this session is compacted or
restarted, read this file first and resume from the first item without a final state.**

Order: live-business risks first (I198, I205, I208+I209+I183, I195, I191), then every other `OPEN` and
`PARTLY DONE` item by the reversibility of its first rung (`2-WAY` before `1-WAY`; READ and MEASURE before
DOC before BUILD). `NEEDS A RULING` items are collected, not worked. Anything that reaches a reader or a
member, or cannot be undone, is prepared on a branch and marked READY FOR BRAD.

Orchestration branch: `claude/backlog-run-0919`. Each item lands through its own worktree and
`ops\push-main.ps1`; the landed hash is the one on origin/main.

## Items

| Item | State after this run | Landed / reason |
|---|---|---|
| I108 | NEEDS A RULING | lesson content: risk and insurance lesson shape, options written into the item |
| I109 | NEEDS A RULING | lesson content: emergency-fund lesson and cross-references to published Weeks 29-30 |
| I111 | NEEDS A RULING | lesson content: balance-sheet lesson and worksheet |
| I177 | NEEDS A RULING | rules text: does the lock order cover waits held under a lock |
