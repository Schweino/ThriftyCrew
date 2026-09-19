## the heartbeat paged a board hold as a dead free-dinner rotation, four mornings running

`DONE` `run-0919`

**Symptom.** `public/free-dinners.json` says `week_of=2026-09-11` and was last committed 2026-09-12, while the newest
board is `comparison-2026-09-17.json`. `grocery/health-heartbeat.ps1` paged OUTPUT NOT CURRENT for it in the capture
watchdog logs of 2026-09-13, 09-14, 09-17 and 09-18, each time saying "the job that writes it has not run for this
week".

**What actually happened (read-only, from `grocery/ad-cycle-log.txt` and `grocery/out/chain-verdict.json` in the main
checkout).** Nothing is wrong with the rotation or its week arithmetic. `rotate-free-dinners.ps1` last ran at
2026-09-12 09:23 against the 2026-09-11 board, flipped one recipe each way and wrote the file. From then on every
`check-ad-cycles` run logged `held: guards blocked - hub/rotation not republished from a refused board` (09-13 08:11,
09-14 08:12, 09-17 07:11, 09-18 08:13 and 14:53), which is the rule written after the 2026-09-07 incident: a held
board holds `top5-weekly`, the rotation and the hub publish with it. The rotation and the heartbeat both take "this
week" the same way (the newest `comparison-<date>.json` by name), so the page was true and named the wrong cause. The
capture watchdog already pages the hold itself (`HELD BY GUARDS` in the same 09-18 log).

**What readers saw.** The free list is not shown by its date. Two places read it: the join interstitial
(`site/pages/join-interstitial.html:127`, it decides whether a recipe page is one of the free ones) and the hub's
remove-only badge refresh (`meal-prep/build-hub-grid.ps1:724`). Both read the 2026-09-12 set: the 20 posts that run
confirmed public in Ghost (its log reads 21 flips, 0 errors), so the list and the paywall agreed. No error was shown. Since triage
republished the board at 13:11 and 16:07 on 2026-09-18, the board is the 09-17 one while the free set and the hub Top 5
still rank off 09-11 costs. That lag ends at the next `check-ad-cycles` run whose guards pass.

**Shipped.** `health-heartbeat.ps1` now reports a week-behind row as HELD WITH THE BOARD, and does not page it, only when
all four hold: the file was read and names an older week (never missing or unreadable); a chain verdict was recorded
TODAY; it says `guards_blocked`; and the board it judged is the board week the row is behind. Anything else pages
exactly as before, so a chain that stopped (no verdict today) or a rotation that does not move on a green day still
pages. Fixtures in `grocery/test-auditors.ps1` unit u138: one MUST FIRE, five MUST NOT FIRE, two CLEAN TWIN. With the
fix taken out the MUST FIRE went red (19 of 20 passed, exit 2); restored, 20 of 20 passed and the file md5 matched.
Replayed on the real 2026-09-18 verdict and the real file: HELD with today set to 2026-09-18, pages with today set to
2026-09-19 (no verdict yet that day).

**The one action, and it is not a code change.** Nothing is republished by this fix and no free-dinners.json was
written. Let the next `check-ad-cycles` run publish the rotation: if its guards pass, the rotation re-ranks, flips
posts in Ghost, rewrites `public/free-dinners.json` and republishes the hub, as designed. If Brad wants it sooner, it
is a hand run of `meal-prep/rotate-free-dinners.ps1` after a green guard run, and that changes which recipes are free.

**Left as it is, on purpose.** When triage republishes a held board by hand, nothing re-runs the three Ghost-side
steps the hold skipped; they wait for the next chain run, about 16 hours on 2026-09-18. Not built here: re-running
them from the triage lane would publish to Ghost from a lane that does not own that decision.
