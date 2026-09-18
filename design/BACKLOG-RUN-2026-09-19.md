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
| I205 | DONE | b986423a3 + 8f01557b2: literal ./ prefix stripped in pipeline-commit and bot-paths, MUST FIREs red under the old TrimStart, 0 of 8,563 tracked paths change verdict |
| I198 | DONE | 886796dff: Ghost POST no longer replayed on a timeout or 5xx, Friday send writes an invoking marker before it mails and refuses plus alerts on invoking-without-sent; 3 mutants killed |
| I199 | DONE | 886796dff: rules text names the headers that state idempotency |
| I195 | DONE | 3e5ee4b43: the 2026-09-11 lock cherry-picked onto main, harness re-run beside the live sidecar (6 of 6 double loads unlocked, 6 of 6 single locked), app_selftest MUST FIRE red with the lock broken; takes effect at the next sidecar restart |
| I183 | DONE | 4bb2295e9 + b262718d2: measured first (worst real name 15.1 ms over 42,753 names), then a 250 ms bound on every matcher regex, a timeout scored could-not-look and surfaced in the board health block and check-ad-cycles, 3-strike per-pattern breaker; 4 mutants red |
| I208 | DONE | 4bb2295e9: chicken-breast include atomic, 42,753 names resolve identically before and after, victim 7,354 ms to 13.6 ms |
| I209 | DONE | 4bb2295e9: the C# core catches the timeout; no RegexOptions.Compiled |
| I191 | NEEDS A RULING / READY FOR BRAD | built and landed as 32a035c34, then REVERTED on main because it moves 69 live prices and 26 cheapest-store verdicts; intact on branch claude/i191-add-norm-pid-fix. Found a live bug: the build's process id stored as the product id for Sam's and Fareway ad rows since 9c44c3a37 |
