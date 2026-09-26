# PLAN: the board's clock is the real date, never the ad date (2026-09-26)

Status: APPROVED by Brad 2026-09-26 (D1, D2 as reworded below, D3). Building.

## Knowledge consulted
- searched "board freshness age from file name date" and "rehearsal stale data board date" (knowledge-search --estate).
- memory:dates-written-not-measured: "A row is as old as its own evidence, never as young as its file." and "every
  freshness guard downstream reads a number the builder wrote to be true". This is why `built_at` is NOT the fix for
  the rehearsal: it is a build date, and a board rebuilt today from week-old captures would read fresh.
- data-quality-craft/checks-and-thresholds.md section 1: "there are two freshness checks, not one" (source freshness
  and delivery freshness) and "Measure freshness from a timestamp inside the data".
- memory:mtime-is-not-liveness-for-a-noop-writer: "prove currency from the file's own content stamp".
- .claude/rules/ops-and-gates.md og-11 (a new gate is a ratchet whose mark only falls), og-05 (fixture labels),
  og-06 (a case at the bar and one step past), og-13 (write down what a threshold does when the producer stops).
- .claude/rules/measurement.md: the acceptance bar is written before the run, one row per case per arm.

## What happened
The Fareway change (branch `claude/fareway-scope-to-own-query`) passed all 526 gates and was refused by the chain
rehearsal: `blind=stale-data - the newest board is 2026-09-23, older than 2 day(s)`. The board had been rebuilt at
08:06 that morning from captures read that day at 6 of 7 stores (Hy-Vee the day before).

## The root cause: one variable does two jobs
`grocery/compare-deals.ps1` line 2449: `$today = $ads.today`, from the newest `out/ads-<D>.json`. That date is
correctly **which ad set this board is for** (`week_of`, and the file name `comparison-<D>.json`). But the same
variable is also used as **the date the board judges validity at**: whether a sale has ended, whether a price is
inside the 90-day publish window, which captures the Walmart and Sam's unions admit. The code says why it does
this: "set from the ads file rather than the clock so a pinned regression run stays reproducible".

`ads-<D>.json` is only written on a day a weekly ad is pulled. Most weeks some store's ad rolls almost daily, so
the lag is 0 or 1 day and nobody sees it. This week none was due 09-24 to 09-26 (Family Fare and Fareway roll on
09-27, Hy-Vee 09-28, Aldi and Baker's 09-30), so the ad date lagged the real date by 3 days, and every reader that
treats `week_of` or the file-name date as "now" went wrong at once.

## Measured harm (2026-09-26, not predicted)
- **Ended sales priced on the board.** On the board built at 08:06 today, 9 cells carry a sale or rollback window
  that ended before 09-26 (7 Sam's Club, 2 Fareway, ending 09-23 to 09-25), and 5 of them hold the "Cheapest"
  crown: avocado oil, black peppercorns, coconut oil, fruit cups, smoked turkey sausage. The LIVE board
  (`public/board.json` at origin, committed 00:27 today) crowns Sam's Club on all five of the same cells. How far
  each price is from the shelf is NOT yet measured; Sam's windows are our own 30-day rollback TTL.
- **Every chain push refused** by the rehearsal on a false blind for as long as the lag exceeds 2 days.
- **A stopped-feed detector reading fresh.** `audit-board-freshness.ps1` measures PRODUCER STOPPED against
  `week_of`, so a stopped store reads up to the lag fresher than it is.

## Every consumer, surveyed
A sweep of 961 tracked files (777 .ps1, 156 .py, 28 .js; `grocery/archive` and `grocery/out` excluded) found these
CLOCK uses. Each one is re-verified by hand before it is changed; the sweep is an input, not a verdict.

| # | where | what reads the ad date as now | error when the ad date lags |
|---|---|---|---|
| C1 | compare-deals.ps1:2418 (Add-Norm) | sale expiry `$AdTo -lt $script:BoardToday` | ended sales stay priced (false fresh) |
| C2 | compare-deals.ps1:2570, Test-AdWindowClosed | Baker's / Fareway / Sam's / extra files | ended flyer kept; a flyer that opened after D refused |
| C3 | compare-deals.ps1:2679, ad-match-lib.ps1:117 | undated rows inherit an ended ad's window | ended sales stay priced |
| C4 | compare-deals.ps1:3466, price-table-lib.ps1:65 | price-table sale columns | audit inputs wrong |
| C5 | compare-deals.ps1:3074, provenance-contract-lib.ps1:144 | 90-day publish window | limit becomes 90 + lag |
| C6 | compare-deals.ps1:2538 | Sam's union age | admits captures 90 + lag old |
| C7 | compare-deals.ps1:2702, regular-fileset-lib.ps1:133 | Walmart union age | admits files 90 + lag old |
| C8 | compare-deals.ps1:2628 | extra-deals (BOGO) file age, 7 days | a 7 + lag day old BOGO file treated as live |
| C9 | compare-deals.ps1:2793, rollback-ttl-lib.ps1:192 | rollback first-seen anchor | a rollback's window ends early, permanently |
| C10 | ops/rehearse-chain.ps1:941-944, 540-545, 755, 1092 | data age from the file name | every chain push refused (false blind) |
| C11 | grocery/audit-board-freshness.ps1:58 | PRODUCER STOPPED against week_of | a stopped store reads fresh |
| C12 | grocery/audit-sale-without-ad.ps1:45,85 | review-list ages | understated ages |
| C13 | grocery/publish-trend-pages.ps1:71, publish-deals-page.ps1:404 | republish only when week_of changes | public trend pages keep the first build of the week |
| C14 | grocery/sanity-check.ps1:62, prune-out.ps1:61 | look-back and pruning windows | negligible; named and left |

About 60 more readers use the file-name date only to pick the newest board or find a sibling file. Those are
correct and are not touched.

## The fix: two dates, each named for what it is

**W1. The engine gets an explicit judge date.** `compare-deals.ps1` gains `-JudgeDate yyyy-MM-dd`, defaulting to the
real local date of the run. `week_of` and the file name keep the ad date, so the 60 name-only readers are
untouched. C1 to C9 read the judge date. The board records it as `judged_on` beside `week_of` and `built_at`.
The pinned runs (`regression-test.ps1`, `build-regression-baseline.ps1`, `test-precedence-ladders.ps1`, and any
other caller the sweep finds passing a frozen `-AdsFile`) pass `-JudgeDate` explicitly, so reproducibility is kept
by saying the date rather than by borrowing it. A pinned caller that forgets it fails LOUDLY (every July sale
expires), never silently.

**W2. One shared clock library, `lib/board-clock.ps1`.** `Get-TcBoardClock <board>` returns `week_of`, `built_at`,
`judged_on`, and the evidence dates: the newest `as_of` per store and overall, walked once (the loop now inline in
`audit-board-freshness.ps1:59-74`, moved and reused, not copied). Timed on today's 3.9 MB board: 178 ms to parse,
21 ms to walk 2,653 dated cells.

**W3. The rehearsal judges data age by evidence.** `rehearse-chain.ps1` asks the clock library for the board's
newest read date instead of parsing the file name (C10, all four sites). Brad's F2 bar ("data no older than two
days") keeps its number; only what it measures changes. What it does when the producer stops (og-13): the newest
read stops moving, so the rehearsal goes blind two days after the last capture, which is the behaviour F2 asked for.
Today it would read 2026-09-26 (0 days).

**W4. The freshness audit measures against the real date.** `audit-board-freshness.ps1` takes an injected `-Now`
(the real date in production, a literal in fixtures) and reads per-store newest reads from the clock library (C11).

**W5. The low-severity readers.** C12 reads the real date. C13 republishes when the board's CONTENT changes
(a hash of what the page renders), not when `week_of` changes. C14 is named in the plan and left alone.

**W6. The gate that keeps it fixed.** `ops/audit-board-clock.ps1`, a static detector over tracked .ps1 and .py
files: date arithmetic (`AddDays`, `TotalDays`, `.Days`, `-lt`/`-gt` on a date, `timedelta`) whose operand traces
to `week_of`, `$ads.today` / `.today` of an ads file, `BoardToday`, or a date parsed out of a `comparison-`,
`ads-`, `candidates-`, `flagged-`, `provenance-withheld-` or `price-table-` file name. A deliberate use carries
`# board-clock:allow <reason>`. It is a ratchet (og-11), with the mark set to what is left after W1 to W5, expected
to be 0. It carries a MUST FIRE for each founding shape (C1's comparison, C10's name parse, C11's week_of age), a
MUST NOT FIRE for the name-only reads (newest-file pick, sibling lookup), and a CLEAN TWIN proving a read of
`judged_on` or the clock library passes. SCOPE OF A CLEAN REPORT: unsound (it finds the spellings it knows), so
the rules line in W7 is the half that reaches the writer first.

**W1b. A rollback reverts to the store's own was-price (found while answering D2).** Sam's rollback rows arrive in
`sams-deals-*.json` typed `everyday` (the file's `price_type`), with `marked_down: true`, the store's strikethrough
price in `base_price`, and the 30-day TTL window in `ad_from`/`ad_to` (Brad's rule, 2026-08-21). The engine's
expiry check fires only on `sale` rows, and nothing emits `base_price`, so on 2026-09-26 the TTL was DECORATIVE:
7 Sam's cells carried a window ending 09-23 to 09-25 and still priced the board as `everyday`, 5 of them crowned.
Fix: a marked-down row with a window is emitted as a `sale` half (its window, so it expires) plus an `everyday`
half at `base_price` (read in the same capture, so it is a fetched price, never a typed one), the same two-row shape
the out\regular path already uses ("AND THE PRICE IT REVERTS TO"). The cell then reverts to the store's regular
price on the day the window ends, with no gap. Walmart's rollback path is checked for the same shape and fixed the
same way if it has it.

**W8. The routine that detects an ended sale and fixes the price the next day (Brad's D2).**
- `build-sale-windows.ps1` logs rollback windows too, not only rows typed `sale`, so `refresh_on = end + 1` exists
  for them and `capture-policy-lib.ps1` asks the next capture to re-read the item (the existing SALE EXPIRY slice,
  owed until a landed capture marks `repriced_for`).
- A detector over the built board (daily chain, and a CELL-scope guard so it quarantines one cell and never holds
  the board): a cell priced from a window that ended before `judged_on` is a finding. After W1 and W1b it should
  never fire; it is the backstop that makes a regression loud.
- A re-price owed longer than the store's capture cadence allows pages, naming the item, so "the routine did not
  run" is seen the next morning rather than at the next quarterly rotation.

**W7. The rule and the memory.** One line in `.claude/rules/grocery.md` in the house format: the board has three
dates (`week_of` = which ad set, `judged_on` = the date validity is judged at, `as_of` per cell = when a price was
read), and "now" is never `week_of`. A memory recording this episode and linking `dates-written-not-measured`.

## Verification, with the bar written before the run
- **The A/B.** Build the board twice over today's exact inputs in a scratch copy: arm A = current code, arm B =
  `-JudgeDate 2026-09-26`. One row per commodity-store cell per arm in a JSONL, totals derived from it.
- **Acceptance bar (written now, before the run):** every cell whose price or crown differs between the arms must
  be explained by one of C1 to C9 (a window that ended between 09-23 and 09-26, a capture that crosses the 90-day
  line inside that span, or the BOGO file age). **Zero unexplained differences.** Expected, not promised: the 9
  ended-window cells leave, and the 5 crowns move to the next cheapest store.
- **A second A/B at zero lag.** The same build with `-JudgeDate` equal to `week_of` must be byte-identical to arm A
  apart from `judged_on`, which proves the change does nothing when the dates agree.
- Every touched script's self-test passes and its exit code is read; a mutant per new branch (C1 and C10 at least)
  fails its named case; `run-gates` green; the regression test green with its explicit `-JudgeDate`.

## Landing order
1. W2 + W3 + W4 + W6 + W7, with the rehearsal fix first, because nothing that changes the chain can land while the
   rehearsal is falsely blind. If W3 itself counts as a chain change and is refused by the very blind it fixes,
   that one push goes with `-NoRehearsal -NoRehearsalReason` naming this plan, and it is the only bypass.
2. W1 + W5 (the engine and the pinned callers), rehearsed normally by the fixed rehearsal.
3. The Fareway branch, rehearsed normally.
Each through `ops\push-main.ps1`.

## Build record (2026-09-26)
Everything above was built on `claude/board-clock`. What the build itself found, beyond the plan:
- **The A/B's first run did NOT meet the bar**: at zero lag 3 Sam's cells (oatmeal, olive-oil, sliced-cheese) moved to
  an older, cheaper product. Cause, found by instrumenting both engines in sandboxes: the identical-row dedupe keys on
  price_type and doubles as the union's "newest sighting wins"; W1b's retype broke the key, an older identical row
  survived and made its capture "deeper". Fixed (a split row dedupes on its pre-split type) and fixtured in
  test-board-clock. Second run, same harness and bar: A vs B26 53 of 2808 cells differ, 53 explained, 0 unexplained,
  3 crowns moved (fruit cups to Aldi, black peppercorns to Sam's Club, avocado oil to Walmart); A vs B23 0 price
  changes. All 9 ended cells revert to the same store's own regular price, 4-26% higher than the ended price shown.
- **W6's detector found two clock uses the survey missed**: update-history cut its 21-day daily window from the real date
  while entries are dated in week_of. Both cuts now use the board's ad set. Its other 15 findings: 8 equalities (the
  rule no longer treats -eq as a sink), 1 fixed by renaming the engine's `$script:BoardToday` to `$script:JudgeDay`, 6
  allowed with a stated reason. Mark 0.
- test-board-clock runs daily as a check-ad-cycles lane (7-day cadence, or when the engine's date libraries move).
- Harness and data: scratchpad `ab-board-clock.ps1` (one row per cell per arm), real inputs of 2026-09-26.

## Decisions (Brad, 2026-09-26)
- **D1. RULED: the judge date for a live build is the real date of the run.**
- **D2. RULED, in Brad's words:** *"If a sale price is dropped, it should be part of the automated job to detect that
  and fix the price on the day after the sale. I think one of our routines should be detecting this."* Read as: an
  ended sale leaves the board on its end date AND the cell is automatically re-priced from the store the next day,
  with a detector that makes a miss loud. That is W1 (the drop), W1b (the same-capture revert for rollbacks) and W8
  (the re-price routine covers rollbacks, plus the detector and the page).
- **D3. RULED: the trend pages republish when their content changes.**
</content>
</invoke>
