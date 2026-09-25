---
description: Traps when working on the grocery board, captures, or the comparison pipeline - one line each; the account is grocery-depth.md.
---

# Grocery rules, one line each

LEAD FILE: loads in every ThriftyCrew session, because it has no `paths:` key, on purpose
(design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md, W2.3 option B, D2). The account behind each line, with
its rulings, dates and measurements, is `.claude/rules/grocery-depth.md`, which loads only after a session reads a
file under `grocery/` or `sidecar/`. A `[[name]]` is `~/.claude/projects/C--Codex-ThriftyCrew/memory/<name>.md`: read it,
never write it.

- A bad cell quarantines itself, a bad store drops itself, and only a board-scoped failure or the circuit breaker holds the board; guards exit 4 (`GUARDS QUARANTINED`) is neither clean nor held, and teaching a guard to scope is a per-guard change with its own fixture; use `grocery/cell-quarantine-lib.ps1`, fixtures `grocery/test-cell-quarantine.ps1`.
- `known-wrong.json` is the MAIN-board corrector and `comparison-*.json` is rebuilt daily, so a fresh ruling reads red until the next build on purpose. [[known-wrong-is-the-main-board-corrector]]
- `compare-deals.ps1` is not standalone (a mid-day rebuild needs identity emission AND link repair; never revert-to-isolate), and never quote how many scripts lift it: run `ops\count-source-lifters.ps1 -Script compare-deals.ps1` and say which test (NAMES, READS, EXECUTES); a lifted `$script:` constant does not travel, so export a function (`Get-TcGlobalExclude`). [[compare-deals-is-not-standalone]]
- A wrong product is a SELLER SHAPE, not a brand: blocking the brand hands the cell to the next bulk seller. [[wrong-product-class-is-a-seller-shape]]
- One bad Walmart pull holds a ship-only cell for 90 days once Marketplace rows enter the union. [[walmart-marketplace-rows-pollute-the-union]]
- A capture that cannot name its store is refused (Walmart, Aldi, Sam's, Fareway): post the emitter's output unaltered, never strip its `#tc-store` line or per-row stamp, and judge by the store id from `stores.json` `store_identity`, never the word "Omaha". [[walmart-session-store-3153-drift]]
- An Aldi multipack card is one unit or the pack total and the row usually cannot say which: resolve the basis by arithmetic proof or refuse it, and add no plausibility bar; `design/MEASURE-aldi-pack-basis-2026-09-19.md`.
- A standing ruling's owed terms are DERIVED (`Get-WalmartRulingOwed` in `capture-policy-lib.ps1`) and lead the worklist: never edit a ruling file to mark a term done, and a `-WaiveMissingStoreLine` build discharges nothing.
- No hard-coded bands (Brad, 2026-09-04). [[no-hardcoded-bands]]
- Every price is fetched from an Omaha store's ad or website by the pipeline, never typed or agent-captured; `pull-regular-hyvee.ps1` builds its lookup from `$script:HvRequest*` by name, because a bare `$StoreId` resolved by dynamic scope and every lookup was refused.
- An everyday price is re-read about once every 90 days at every store: `RotationDays = MaxPublishAgeDays = QuarterDays` in `capture-policy-lib.ps1`, and `test-capture-policy.ps1` fails a push that moves either off the quarter. [[graph-time-gates-decision]]
- A script you edit that holds its own copy of the store list reads `stores.json` instead, in the same change (convert on touch, no sweep).
- The boards are gitignored, so a worktree or clean checkout is BLIND and the engines exit 0 having priced nothing: seed with `ops/seed-worktree.ps1` (it refreshes a file whose source was rewritten).
- A check comparing a derived file with a board reads that file by the BOARD'S road (a gitignored stamp `.worktreeinclude` carries), never untracks a file the bot rewrites daily, and with no record on that road counts a SKIP, never a FAIL.
- `cohort` here means the PEER GROUP OF PRODUCTS holding a commodity's board cells; member work writes `member cohort` in full, every time.
- A 200 with a correct selector and zero rows has four causes (`blocked`, `not-carried`, `unrendered`, `unsettled`), and UNCHECKED IS NEVER NOT-CARRIED: wait on a count-based selector, never a sleep, and look for the page's own JSON call first. [[a-could-not-look-must-not-settle-the-question]]
- A deep discount is evidence about a cell's FUTURE: it must not raise confidence that a store carries the item, because an exit markdown looks the same as a promotion.

Regime: this holds for files under `grocery/`. It says nothing about `meal-prep/`, which has its own rules file and its
own corrector.
