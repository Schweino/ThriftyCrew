# Lane: sh-watch landing, W1.1 of design/PLAN-bot-checkout-self-heal-2026-09-23.md, 2026-09-23

Filed by W1.1's landing push, as the landing stage asks of every item that section 8 of the plan gives a bar. Section
8 gives W1.1 one live bar, B9, and one mutant, M12. What W1.1 landed, by blob, because a rebase cannot move a blob:
`grocery/capture-watchdog.ps1` c0aff393714ffdeb7db958ccd07b65c6721ba8ba.

## read out bar m12 for w1.1: gt to ge on the 93,600 s floor must turn the at-the-bar case red

`DONE` `queue-7`

**The bar, as section 8 wrote it before the run.** Mutant M12, "`-gt` to `-ge` on the 93,600 s floor", must turn
W1.1's at-the-bar case red, from a temp mirror, with the original md5-identical afterwards.

**Read out 2026-09-23 by the lane, before landing.** In `Get-CheckoutFloor`, `-gt` became `-ge` on the 93,600 s bar,
and the AT THE BAR 93,600 s case went red. It ran from a temp mirror, and the original was md5-identical afterwards
(4B62C77E...). The lane's eight other W1.1 mutants were each killed in their own named case, and an unmutated mirror
passed. The line for section 13 of the plan: `M12: killed in the AT THE BAR 93,600 s case (W1.1 blob c0aff393714f),
read 2026-09-23 by the lane`.

**Re-verified at landing, on the tree rebased onto origin/main.** `grocery/capture-watchdog.ps1 -SelfTest` gave exit
0, `CASES ok: exactly 61 case lines ran, the literal count of this suite`, then `SELFTEST PASSED`.
`lib/gate-input-key.ps1 -VerifyDeclared grocery\capture-watchdog.ps1` gave exit 0, `VERIFIED ... probes=9` and
`GATE-DECLARATIONS-VERIFIED 1 of 1`. The landing stage did not run the mutant again.

## read out bar b9 for w1.1 on 2026-10-07, 14 days after it lands

`OPEN` `queue-7` `2-WAY` `RUNG1 MEASURE`

**The bar, as section 8 wrote it before any run.** B9 counts watchdog runs where check 7's condition held (the
oldest commit the checkout is missing is more than 93,600 s old) and no BOT CHECKOUT STALE finding was raised.
Minimum N: any. Bar: 0, deterministic. Otherwise it is judged by the W1.1 fixtures at the bar: 93,600 s is not
stale, and 93,601 s is.

**Read-out date: 2026-10-07**, which is the landing date plus section 8's default 14 days. `grocery/report-checkout-sync.ps1` (W1.2)
works the landing out from the earliest origin/main commit whose message carries `Plan:
design/PLAN-bot-checkout-self-heal-2026-09-23.md W1.1`, so its `-Due` agrees with this date unless the landing slips
past midnight. From 2026-10-08, `powershell -NoProfile -File grocery\report-checkout-sync.ps1 -Due` exits 2 until
section 13 of the plan carries the line `B9: <result> (N=<n>, report blob <id>, window <from>..<to>)`. N is the number
of 10:30 watchdog transcripts that carry a `CHECKOUT-FLOOR` line. A run with no such line is unmeasured, never a pass.

**What it needs.** Nothing runs `-Due` on a schedule yet, so this heading is the reminder until a task does. The lane
filed the same bar in `design/backlog-inbox/sh-watch-2026-09-23.md`. This file adds the date, because the landing
now exists.
