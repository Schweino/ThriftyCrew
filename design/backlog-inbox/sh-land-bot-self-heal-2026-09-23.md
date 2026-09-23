## the bot self-heal plan's section 8 bars and when each one is read

`OPEN` `queue-sh-land` `2-WAY` `RUNG1 MEASURE`

**Source.** The landing of the `cr` lane of design/PLAN-bot-checkout-self-heal-2026-09-23.md on 2026-09-23, in five
push-main runs from the `sh-cr` worktree: W2.1 with W2.2 (17:27 local), W0.2 step 3 (17:49), W3.2 step 3 (18:09), W4.1
(18:35), and W4.2 with W5.1 items 1 to 3 and the lane's review fixes (this push, the evening of 2026-09-23). Every bar is
measured by `grocery/report-checkout-sync.ps1`, blob 6f9ec14c3d7b48a52716b70b3507c86a8b646426 on origin/main when this
was written; `-Due` turns a read-out date into an exit code. Each bar's minimum N and value are in section 8 of the plan
and are not copied here, so there is one copy of each.

| Bar | What it reads | Item | Read-out |
|---|---|---|---|
| B1a | start syncs ending `current` or `synced` with `behind_after` not 0 | W4.1 | 2026-10-07 |
| B1b | armed runs whose start sync ended `current` or `synced` | W4.1 | 2026-10-07 |
| B2 | runs that started after a fix reached origin and ran without it | W4.1 | 2026-10-07 |
| B3 | `Created autostash` lines in capture-run logs | W4.2 | 2026-10-07 |
| B4 | dirty paths outside the write set rewritten across a moving sync | W3.1, W4 | 2026-10-07 |
| B5 | armed runs whose captures started over unmerged entries or markers | W3.1, W4.1 | 2026-10-07 |
| B6a | size-gate refusals inside one run's caps with every carry `within-caps` | W2.2 | 2026-10-07 |
| B6b | longest run of days with no bot `[daily]` commit | W2.2 | 2026-10-23 (30 days) |
| B7 | start-sync seconds, median and p90 | W4.1 | 2026-10-07 |
| B8 | syncs whose read-tree hit `unable to unlink`, ending verified | W3.1 | read by the report at W3.1's own date (W3.1's inbox entry says 14 days after W4.1 gives the lib its caller, so 2026-10-07) |
| B9 | watchdog runs 26 h behind that raised no BOT CHECKOUT STALE | W1.1 | as filed by the W1.1 landing (9ef5384cc) |

A bar under its minimum N on its read-out date gives no verdict, and says so. It does not pass.

## report-checkout-sync opens the W4.1 and W4.2 windows at 12:35, six hours before either landed

`OPEN` `queue-sh-land` `2-WAY` `RUNG1 BUILD`

**Source.** The same landing. Run at this push's base, `report-checkout-sync.ps1` printed
`landed items: ... W4.1 1d59fbfba, W4.2 1d59fbfba` and `since W4.1 landed 1d59fbfba at 2026-09-23 12:35` for B1a, B1b, B2,
B4, B5 and B7 (B3 the same for W4.2). 1d59fbfba is the daily-chain stale-code commit. Its Plan line reads
`Plan: design/PLAN-bot-checkout-self-heal-2026-09-23.md W4.2 (complements it: ... no start sync here, W4.1 owns it)`.
`Get-CsLandings` takes every `W<n>.<n>` token anywhere on a Plan line, so the words in the parenthesis count as landing
W4.1. W4.1 actually reached origin/main at 18:35 local and W4.2 on this push.

**Why it matters.** The read-out dates are not affected (the same calendar day). The windows are. The hourly capture runs
between 12:35 and the real landings ran without the start sync, and each one counts against B1b, B2 and B3 as a run
after the item landed. A bar can then fail on runs that never had the code, which is `a-number-that-moved` in reverse.

**What fixes it.** Read only the item list right after the plan path, stopping at the first `(`, or require the item
tokens to come before any prose. Add a MUST FIRE fixture from this exact Plan line: W4.2 lands and W4.1 does not. A
date-only `landing` pin in the bars table is the wrong repair, because it opens the window at midnight, which is
earlier still. Until then, whoever reads these bars out drops the runs before 18:35 on 2026-09-23 (W4.1) and before
this push (W4.2) by hand, and says so.
