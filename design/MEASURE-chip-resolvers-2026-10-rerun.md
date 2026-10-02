# MEASURE: the Family Fare chip resolver re-run after the blocked-is-unchecked fix (2026-10-02)

Harness: `grocery/resolve-familyfare-urls.ps1` at blob 60a754cc1b5d3f3cb5521f33091fa91b0b702db1, driven in 10-chip
slices by `design/chip-resolvers-2026-10/harness/slices.ps1.txt`, run 2026-10-02 10:50 to 14:16.

Re-runs W8 step 1 of `design/PLAN-browser-refresh-hardening-2026-10-02.md` for the Family Fare resolver only, after
the fix the first measurement asked for (`design/MEASURE-chip-resolvers-2026-10.md`, findings 1 and 2). Nothing is
wired. Rows: `design/MEASURE-chip-resolvers-2026-10-rerun.jsonl`, 65 rows, one per Family Fare chip.

## Bar (unchanged, written before the first run, verbatim from the plan)

> wire a resolver into the daily chain only if it resolves at least half its store's chips with zero wrong links on a
> 10-chip hand check.

In units, as before: resolved / 65 >= 50% (33 chips), AND wrong = 0 among the hand-checked resolved links. "Right"
means right for the chip's COMMODITY; whether the link opens the exact board item is a second column outside the
verdict. A chip the API never answered is UNCHECKED: counted, never resolved, never wrong.

## Inputs

| Input | Identity |
|---|---|
| `grocery/out/url-worklist.json` (main checkout, read only) | sha256 `57D3568D70392C35E136A57CC6478A04AF133730D0ADDFE5E6D215F8D44C050C`, byte-identical to the first measurement's |
| `grocery/commodities.json` | blob `74126abde9b4b06dbb5208dca6323d947ed4dfca` (same as the first run) |
| `grocery/recipe-commodities.json` | blob `3763e070bbfb3d9a59cbd255f6446b0810c7a0f8` (same) |
| `grocery/commodity-search.json` | blob `7edf03fd345f31bc2122ac206b322b93b10ad6b8` (same) |
| First run's rows `design/MEASURE-chip-resolvers-2026-10.jsonl` | blob `b4893d130a897c1b033507761fb6bec2e8925053` |

One input, so this is one case list measured twice: only the resolver differs between the two runs.

## Harness

Resolver variants this doc speaks about, by blob (a rebase cannot move a blob):

| Blob | What it is | Ran live? |
|---|---|---|
| `e8f4996aaefaec7e2d28ab0b5098beeb37bb5e46` | the original resolver (first measurement) | yes, by the first measurement |
| `60a754cc1b5d3f3cb5521f33091fa91b0b702db1` | blocked/empty/no-match split, board item first, pu-lib per-unit, breaker, `-Ids` | **yes, this run** |
| `6699b786b67e6e5952ca69af7643215708889dc1` | the above plus `relax_global` and `Get-TcGlobalExclude` (finding 2 below) | **no**, offline rules check only |

Clone and run, PowerShell 5.1, `$sp` the session scratchpad:

```
git -c core.longpaths=true clone --quiet --no-hardlinks <worktree> $sp\w8b-clone      # then checkout 7211c0055
powershell -NoProfile -File ops\seed-worktree.ps1 -Target $sp\w8b-clone -Source C:\Codex\ThriftyCrew   # exit 0
copy C:\Codex\ThriftyCrew\grocery\out\url-worklist.json  $sp\w8b-clone\grocery\out\     # the seed did not carry it
powershell -NoProfile -File $sp\w8b-slices.ps1 -Clone $sp\w8b-clone -Out $sp\w8b-out    # = slices.ps1.txt
```

The slice harness waited until 10:50 so the run came after the last production Family Fare search window of the
day (`capture-run.ps1 -Kind ad` at 07:00, the daily at 08:00, the watchdog at 10:30), because the resolver and the
price pull share one Freshop request budget. It ran 10 chips a slice, put any blocked or not-attempted chip back in
the pool, waited 30 minutes after a slice that did not answer every chip, and was due to stop at 17:00. **It was
stopped by hand at 14:16**: slices 5 to 8 (12:28 to 14:03) each answered 0 of 10 and spent 9 calls against a wall,
the estate's account is that repeated attempts push that wall further out, and the verdict below no longer depended
on the 32 unchecked chips.

A first full run at 07:52, before the slices, met a wall on its very first call (HTTP 400 carrying
`error_code 429`): 3 chips blocked, breaker tripped after 9 calls, 62 not attempted, `ff-notcarry.json` written as
an empty array. Production's 07:00 window had bought 9 terms cleanly at 07:01, so the morning's probing had spent
the window. That run answered nothing and is not counted below; it is the live proof of the MUST FIRE case.

Hand check: every resolved link rendered in the desktop browser pane with Family Fare 50th and Grover (store 6401)
selected, the page `h1` read after waiting for it to carry TEXT (an empty `h1` appears before the product loads,
the gr-17 `unsettled` cause; the first pass read 6 empty headings that way and they were re-read). Every page showed
the 50th and Grover store. Sheet: `design/chip-resolvers-2026-10/harness/handcheck-2026-10-02.tsv`. Rows built by
`build-rows.py.txt`; the old-vs-new rules check is `rules-old-vs-new.ps1.txt`.

## Results (derived from the 65 rows)

| | First run (blob e8f4996) | This run (blob 60a754cc) |
|---|---|---|
| Resolved | 17 of 65 | 26 of 65 (40%) |
| Not-carried candidates written | 48 (incl. 38 HTTP 400s) | 7, **all false** (finding 2) |
| Unchecked (blocked, empty or not attempted) | 0 reported (the 400s were hidden as misses) | 32 of 65 |
| Hand check right / wrong / unchecked | 15 / 2 / 0 of 17 | 23 / 3 / 0 of 26 |
| Opens the board item | 7 of 17 | 26 of 26 |

Every resolved link this run was a board-item match (`match: board`); no chip needed the commodity fallback.

The three wrong links:

| Chip | Commodity | Page opened (= the board item) | Why wrong |
|---|---|---|---|
| iced-tea | Iced Tea (bottled/gallon) | Twisted Tea Hard Iced Tea, Peach 24 Fl Oz | an alcoholic malt drink |
| ground-cinnamon | Ground Cinnamon | Cinnamon Twirls | a bakery pastry |
| sponges | Dish Sponges | Mr. Clean Magic Eraser Sponge, Shower & Tub Cleaner | a bath cleaning eraser (a judgement) |

All three open exactly the product the board prices, and all three names are in `public/board.json` today. The
resolver did what it was built to do; the BOARD holds a wrong product in those cells. That is filed separately
(a chip to correct them through `known-wrong.json` and fix the commodity rules), not repaired here.

The two wrong links of the first run are gone: avocados now opens Hass Avocados, Small (hand-checked right).
Cantaloupe was unchecked this run (blocked in slice 2 and never re-answered); its replacement behaviour is covered
by a self-test case only.

## Verdict

**`resolve-familyfare-urls.ps1` at blob 60a754cc: NOT MET.** Wrong = 3 among 26 checked, against a bar of zero. The
resolution half is UNDECIDED, not met: 26 of 65 resolved with 32 unchecked, so it could land anywhere from 40% to
above the 50% bar. A number that moved: resolved went 17 -> 26 and board-item links 7 of 17 -> 26 of 26, over one
input list and two resolver variants; the 7 more answered chips came from slicing past the wall, not only from the
fix, so the resolved count is not a like-for-like improvement.

The wrong links will clear only when the board does. A resolver whose job is to open the board item cannot be right
for the commodity where the board itself is wrong, and making it disagree with the price would break the invariant
`fix-links-ff.ps1` exists for (the link opens the product the board named).

## Findings

1. **Blocked is now unchecked, live.** 32 of 65 chips went unanswered across the run and none reached
   `ff-notcarry.json`. The old code would have written each as not-carried.
2. **All 7 no-match verdicts were false, and the cause was a second defect in the resolver.** Each chip's own
   board item was blocked by a global-exclude token its commodity relaxes (cereal by `cereal`, baked-beans by
   `\bbaked\b`, alfredo-sauce and pasta-sauce by `\bsauce\b`, caesar-salad-kit by `\bkit\b`, frozen-broccoli by
   `\bfrozen\b`, coffee-creamer by `\bcreamer\b`). The resolver held a stale hand copy of the staple exclude list
   and ignored `relax_global`. Fixed at blob 6699b786 (`compare-deals`' Match-Category rule, and the list read from
   `Get-TcGlobalExclude`). Offline, over all 65 worklist board items: old gate passes 57, new gate 65; 8 move
   blocked to pass (the 7 and potato-chips), 0 move the other way. **Not yet run live.**
3. **One run does not fit one Freshop window.** About 7 to 10 chips answered per window, then a wall that held from
   12:28 to at least 14:03. The budget is shared with the production price pull. Wiring this resolver into the
   daily chain would need it to take a fixed share of a window and resume across windows (as `fix-links-ff.ps1`'s
   accumulating plan does), or it competes with the pull that prices the board.
4. **A new throttle shape.** Some blocked answers were HTTP 200 with no `items` array at all
   (pepperoni, slice 4). The resolver counts that as blocked. The price pull's `Get-FreshopItems` tests
   `@($r.items).Count -eq 0`, and for a missing array that count is 1 (`@($null)`), so such an answer is recorded
   neither as an empty 200 nor as a refusal. Read from the code afterwards (not run): it returns that one `$null`
   element, the term loop's `if (@($items).Count -eq 0)` is false, so the term is scored `$termSuccess = today`, and
   `Ingest-Items` skips the `$null` row. A throttled term is recorded as freshly bought with no rows. Filed as its own
   task; how often it has happened was not measured.

## Not done, and why

- The 32 unchecked chips and the 7 false no-matches were not re-run at blob 6699b786. They need a run after the
  10:30 production window on a day the morning has not been spent on probes. It cannot change the verdict while
  the three board cells stay wrong.
- Nothing wired: NOT MET.
