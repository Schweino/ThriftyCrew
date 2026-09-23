# Sam's started printing sub-dollar unit prices in cents, and it cost two thirds of the capture

2026-09-20. Sam's Club changed how it renders a unit price below $1.00: `$0.93/lb` became `92.8 c/lb`,
with the cent glyph U+00A2. Three separate pieces of this estate assumed the dollar spelling, and each
failed differently - one loudly, one quietly, and one in a way that would not have surfaced on any
report.

## What was reported, and what was actually true

The incident arrived as "6 of 8 terms settled UNUSABLE on the Sam's capture". That is correct and it is
also the smallest true statement about it.

| | measured |
|---|---|
| terms on the 2026-09-20 worklist | 8 |
| settled UNUSABLE for this cause | 6 - `creme fraiche`, `croissants`, `crushed tomatoes`, `cumin seeds`, `whole cumin`, `curry powder` |
| settled EMPTY | 0 - no wall, no 403, no 429. The store answered fine. |
| rows that did land | 31: 13 dollar form, 7 cents form, 11 blank |

The two terms that landed (`crushed thai chili`, `cucumber`) landed only because the guard checks
`rows[0]` and their first priced row happened to be at or above $1.00.

## The rendering change is mechanical, and that is what makes this big

Same item ids, one day apart, from `grocery/out/captures/`:

| item | 2026-09-19 | 2026-09-20 |
|---|---|---|
| Sweet Onions, 6 lbs. | `$0.93/lb` | `92.8 c/lb` |
| Avocados, 5 ct. | `$0.99/ea` | `99.2 c/ea` |
| Romaine Hearts, 6 ct. | `$0.79/ea` | `78.8 c/ea` |
| Taylor Farms Sweet Kale Chopped Salad Kit, 12 oz. | `$0.25/oz` | `24.8 c/oz` |
| Shirakiku White Miso Paste, 26.4 oz. | `$0.20/oz` | `20.0 c/oz` |
| Tomatoes on the Vine, 3 lbs. | `$1.66/lb` | `$1.66/lb` |

Over the 20 priced rows on 2026-09-20 the split had **zero exceptions**: every unit price below $1.00
printed in cents, every one at or above $1.00 printed in dollars. Twenty rows is a small denominator for
a rule with no exceptions, and it is stated as such - but the same-id switch above is what rules out
"a rare row shape we had not met" and leaves "Sam's changed its renderer".

Projecting that rule onto the 2026-09-19 sweep, the last full one:

- **5,264 of 7,410 priced rows (71.0%)** would now arrive in cents form.
- **251 of 382 terms (65.7%)** carry a sub-dollar unit price on their FIRST priced row, and would
  therefore have settled UNUSABLE.

So this was a two-thirds capture outage at Sam's, and 6 of 8 is the first day's sample of it.

**And an UNUSABLE is not free.** `runPacedSweep` treats a thrown probe as a wall: 3 retries behind
20s/40s/80s of backoff, about 140 seconds per falsely-UNUSABLE term, and three consecutive ones trip
`wallLimit` and hand off to Brad for a CAPTCHA that does not exist.

## Three failures, not one

**1. The capture guard threw** (`grocery/pull-sams-instore.js`, `assertSamsRowContract`). Verified by
executing the shipped function against the real 31 rows: it accepted 24 and threw on exactly the 7
cents-form ones. Its header already records this exact failure mode happening once before, for a blank
`up`, and calls it "the guard inventing a blockage". It was loosened for the blank and not for the
cents form, so the documented defect recurred in a new spelling.

Its own justification is false here. The header says build-sams-deals "would reject this capture
wholesale"; that is true of a malformed `lp` and not of a cents `up`, which the builder rejected
per-row as `no unitPrice` on a run that exited 0.

**2. The builder could not read it** (`grocery/build-sams-deals.ps1`), rejecting every cents row as
`no unitPrice` - silently discarding a real, usable number.

**3. The quiet one: the rounding band, and the crown test.** This is the half nothing would have
reported. `Get-DerivedRoundingPct` required a `$` sign, so a cents-form unit price returned `$null` -
and `$null` there does not mean "a wide band", it means **no band at all**. `Get-CellRoundingPct` then
reports no uncertainty, `Get-RoundingBandTies` returns empty, and the crown test is skipped: the board
would rank a back-solved size as an exact number. Measured across the two arms:

```
             up=$0.45/oz     up=45.2 c/oz    up=92.8 c/lb
  old arm    1.11%           NULL            NULL
  new arm    1.11%           0.11%           0.05%
```

Had only the guard and an obvious `/100` conversion shipped, the rows would have landed on the board
**claiming zero uncertainty on a quotient-derived size**, on the same day the capture started working
again.

## The precision is the whole of the risky half

The cents form is not a re-spelling, it is a **more precise number**: `$0.25/oz` became `24.8 c/oz`.
A cents-form price is rounded to a tenth of a cent - ten times finer than the cent the entire builder
was written around, including the hard-coded `0.005001` that decides whether a name's stated size
"reproduces Sam's own unit price".

Reading a cents price as dollars while keeping a cent-wide window would accept a size up to ten times
further out than the printed number can justify, and publish a per-unit price to match. That is the
class `.claude/rules/grocery.md` calls the hardest defect here to find later.

So the bound travels with the value: **half of the last printed digit**, in dollars. That makes the old
constant a special case rather than a parallel path - two-decimal dollars gives exactly 0.005 - and the
census below is what makes that a no-op claim rather than a hope.

## Every unit-price shape this estate has ever captured from Sam's

`grocery/probe-sams-unit-price-shapes.ps1` (committed, `-SelfTest` 14 cases), over 29 capture files:

```
cents    1 decimal place(s)  ->  rounding bound +/- $0.0005       7 of 25434 rows (0.03%)
dollar   2 decimal place(s)  ->  rounding bound +/- $0.005    24073 of 25434 rows (94.65%)
blank                                                          1354 of 25434
UNPARSED                                                          0 of 25434
```

**All 24,073 historical dollar rows carry exactly two decimal places**, so the precision rule computes
exactly 0.005 for every one of them. Zero rows are unparsed, so the reader understands every shape on
disk.

## The no-op is measured, not argued

Two arms differing in exactly two files (`build-sams-deals.ps1`, `pricing-math-lib.ps1`), every other
file in `grocery/` and the whole of `lib/` copied identically into both, built over the 8,016-row
2026-09-19 capture:

| | old arm | new arm |
|---|---|---|
| exit | 0 | 0 |
| `sams-deals-2026-09-19.json` | 2,802 rows | **byte-identical** |
| `sams-rejects-2026-09-19.json` | 756 rows | **byte-identical** |

Over the 2026-09-20 capture, where they should differ:

| | old arm | new arm |
|---|---|---|
| deals | 12 | **19** |
| rejects | 19 | **12** |
| the 12 rows both arms priced | - | unchanged, 0 moved |

All seven recovered rows were hand-checked against Sam's own arithmetic. Six resolve to the name's
stated size, one (`FujiSan Cucumber Avocado Roll`, whose name is silent in the priced unit) to the
derived quotient, which is the designed behaviour:

```
  Macayo chile     6.88/8      = 0.86     printed 86.0c   err 0
  Miso paste       5.28/26.4   = 0.20     printed 20.0c   err 0
  Kale salad kit   2.97/12     = 0.2475   printed 24.8c   err 0.0005
  FujiSan roll     5.74/12.699 = 0.452    printed 45.2c   err 4e-06
  Romaine hearts   4.73/6      = 0.78833  printed 78.8c   err 0.000333
  Sweet onions     5.57/6      = 0.92833  printed 92.8c   err 0.000333
  Avocados         4.96/5      = 0.992    printed 99.2c   err 0
```

## A shape we cannot read is refused, not guessed

`walmart-row-lib.ps1` accepts **any 1-3 non-digit characters** where the cent sign goes. That would read
a hypothetical `0.20 USD/oz` as `$0.0020/oz` - a silent hundredfold basis error on a live paid board.
The Sam's reader anchors on the cent glyph family (U+00A2, the cp1252-mangled U+00C2 U+00A2, and a bare
`c`) and returns `$null` for anything else, which downstream is an ordinary per-row reject: a row we
decline to price, never a row we price wrongly. The divergence from the sibling lane is deliberate.

## Mutation probe: what the fixtures can actually see

Five single compiling mutants, each removing one half of the fix, run from a temp mirror; the three
subject files were md5-verified byte-identical afterwards.

| mutant | outcome |
|---|---|
| A. the guard forgets the cents form (the defect restored) | **killed** - `MUST NOT FIRE the CENTS form` |
| B. the display window back to a hard-coded cent | **killed** - `8i A STEP PAST` |
| C. the rounding band back to a hard-coded cent | **killed** - `8h derived cents row band` (read 1.11%) |
| D. the rounding band cannot read cents at all (the crown-test hole) | **killed** - `8h derived cents row band` (read empty) |
| E. `$roundErr` back to a hard-coded cent | **SURVIVED** |

**E survived and the honest reading is that the path is unreachable, not that the fixture is lazy.**
`$roundErr` feeds only `$tol = max(0.02, $roundErr + 0.005)`. The 0.02 floor dominates until
`halfUlp/up > 0.015`, which for the cents form means a unit price **below 3.33 cents**; the cheapest
cents-form row ever captured is 20.0c. And even there the two arms could only differ if the pricing
engine's reproduction missed Sam's printed price by between the two tolerances, which cannot happen for
a row that has already passed the far tighter name test or taken the derived path by construction. The
change to `$roundErr` is kept because it keeps the two expressions consistent and the tighter value is
the correct one if anything ever reaches it - but **it is unexercised, and no case is claimed for it**.

## The negative assertion this guard has now lacked twice

Both of this guard's regressions were OVER-firing, and neither had a case that could catch it. The
fixtures added are one `MUST NOT FIRE` per legal shape of `up` - dollar, cents, blank/absent - which is
the only arrangement in which a third spelling cannot repeat this, plus `MUST FIRE` cases kept sharp on
the malformed `lp` the guard actually exists for. 18 cases in
`grocery/test-pull-agent-lib.ps1` section 7; `lp` was not touched.

## Knowledge consulted

Searched `unit price cents`, `rounding band crown`, `sams capture contract`, `must not fire negative
assertion`, `at the bar step past`, `cent glyph cp1252`.

- `.claude/rules/ops-and-gates.md`, **Three fixture labels, three jobs**: "`MUST NOT FIRE` - a legal
  input. The detector is SILENT, or it is crying wolf. **This is the negative assertion**." Both of this
  guard's regressions were over-firing, so this is the label that was missing both times, and it is why
  there is now one case per legal shape of `up` rather than one case for the cents form.
- `.claude/rules/ops-and-gates.md`, on threshold detectors: "carries a case exactly AT its bar and one a
  step PAST it, and names the bar in the case text ... AND THE CASE AT THE BAR IS BUILT FROM
  BINARY-EXACT NUMBERS, or the double decides it and the rule does not." This is why section 8i is built
  on 2.97/12 = 0.2475, which sits exactly halfway between the two printable tenth-cent values, rather
  than on the 62.55c fixture first written - that one silently changed the precision under test, because
  two decimals in cents is a four-decimal dollar price, and it went red for a reason unrelated to the rule.
- `.claude/rules/ops-and-gates.md`, on detector headers: "an **unsound** one can miss one, so a clean
  report proves nothing". `probe-sams-unit-price-shapes.ps1` carries its `SCOPE OF A CLEAN REPORT` line
  saying it reads the capture files and nothing else.
- `.claude/rules/ops-and-gates.md`, on mutation probes: "A survivor from a mutation probe names the exact
  missing case" and "the honest reading is that the fixture is insensitive, not that the code is wrong".
  Mutant E is reported as a survivor with the analysis of why its path is unreachable, and no case is
  claimed for it.
- `.claude/rules/grocery.md`: "Right prices in the wrong basis is the hardest defect here to find later."
  This is the whole reason the rounding bound travels with the value instead of the cents form being
  converted and handed to a cent-wide window, and why an unrecognised currency token is refused rather
  than divided by 100.
- `.claude/rules/grocery.md`: "A 200 with a correct selector and ZERO ROWS has FOUR causes ... *UNCHECKED
  IS NEVER NOT-CARRIED*." The 6 terms are UNUSABLE, never EMPTY; nothing here may become a not-carried
  ruling.
- `.claude/rules/measurement.md`: "A rate is printed with its DENOMINATOR, always", and "NAMING A SCRATCH
  HARNESS IS NOT NAMING A HARNESS ... a measurement that anyone may want to repeat COMMITS its harness".
  The shape census is committed as `grocery/probe-sams-unit-price-shapes.ps1` because "has Sam's notation
  moved?" is a question that will recur; the A/B arm comparison and the mutation probe are one-offs and
  are described here instead.
- `.claude/rules/measurement.md`: "Never cite your own unlanded commit hash, anywhere: cite a blob."
  Hence the blob table below.
- `CLAUDE.md` (workspace): "`Set-Content`/`Add-Content` default to ANSI" and the non-ASCII round-trip
  warning. This cost two rounds here - `¢` escapes were written into the sources as real glyph
  bytes, PS 5.1 read the `.ps1` as ANSI, and both a parse failure and a false red followed. Every file
  touched is now pure ASCII with the glyph built from `[char]0x00A2` / `String.fromCharCode`.
- Memory `ps-json-array-collapse` and the case-insensitivity trap in `.claude/rules/ops-and-gates.md`
  ("a fixture variable `$pS` IS `$PS`"): hit directly here, as `$C` being the same variable as a `$c`
  holding a parsed result, which put a Hashtable into three fixture rows.

## Harness and provenance

**Measured through** `grocery/probe-sams-unit-price-shapes.ps1` (the shape census), `grocery/build-sams-deals.ps1 -SelfTest`
and `grocery/test-pull-agent-lib.ps1 -SelfTest` (the fixtures), run on 2026-09-20 at base commit
`4f4fef40b79eb8fb9a38a38fbf56b906ed9239a1`, against `grocery/out/captures/sams-capture-2026-09-19.csv`
and `sams-capture-2026-09-20.csv`.

Blobs at the base commit `4f4fef40b79eb8fb9a38a38fbf56b906ed9239a1`, cited as blobs because a rebase
rewrites a commit id and cannot move a blob:

| file | blob |
|---|---|
| `grocery/pull-sams-instore.js` | `3c3882b5aab113a4d112df176227f9c1db25cee9` |
| `grocery/build-sams-deals.ps1` | `79345e86f5c09cdb530f4d7fd783388e883f86e3` |
| `grocery/pricing-math-lib.ps1` | `1419c3cd34872540efe9c43cb243002423ade56f` |
| `grocery/walmart-row-lib.ps1` | `22ed2960844c4493e1482c3b99bc000858ed9f09` |
| `grocery/test-pull-agent-lib.ps1` | `4a1cb6e77936dec4167a403f78e93aca28293f25` |

The harnesses named below were written or changed by this same change, so the numbers above were taken
through them at the state they landed in. Blobs rather than commit ids, because `ops/push-main.ps1`
rebases before it pushes and a rebase cannot move a blob:

    Re-read at harness blob 7819e3e5849478d1532f97876c6eaae9786e695d (grocery/probe-sams-unit-price-shapes.ps1): the shape census - 25,434 rows, 24,073 dollar at 2 decimals, 7 cents at 1, 0 unparsed - is this file's own output.
    Re-read at harness blob d80e5c63c7379feaf567e3a48635f3f1a5a0b882 (grocery/test-pull-agent-lib.ps1): the 18 guard cases, and the mutant-A kill, are this file's.
    Re-read at harness blob c176e71e6e5360029a30c4e1ae82d5cc368a3b2f (grocery/build-sams-deals.ps1): the 77 builder cases, the at-the-bar trio and mutants B and E are this file's; the A/B arm figures were taken against its parent blob 79345e86f5c09cdb530f4d7fd783388e883f86e3 as the "old" arm.
    Re-read at harness blob 512460b8ab0a227ed248c54d80b673417a992824 (grocery/pricing-math-lib.ps1): the rounding-band table (NULL/0.11%/0.05%) and mutants C and D are this file's.
    Re-read at harness blob 501b0090e356767304ac8513c0591f6b63a82485 (grocery/pull-sams-instore.js): the 24-accept/7-throw execution against the real capture was taken against its parent blob 3c3882b5aab113a4d112df176227f9c1db25cee9; at this blob the same 31 rows all pass.
    Re-read at harness blob b29e08564dd551a04730a40edaffbfe01fc4b0e7 (grocery/audit-basis-reconcile.ps1): exit 0, 52 cells checked, 0 findings after the cents-form repair.

Harnesses: `grocery/probe-sams-unit-price-shapes.ps1` for the shape census (committed, because "has
Sam's notation moved?" is a question that will recur); `grocery/build-sams-deals.ps1 -SelfTest` and
`grocery/test-pull-agent-lib.ps1 -SelfTest` for the fixtures. The A/B arm comparison and the mutation
probe were one-off and are described here rather than committed.

Evidence file: `grocery/out/captures/sams-capture-2026-09-20.csv` (gitignored, 31 rows, opens with its
`#tc-store` line).

## Every downstream reader of the field, checked - one was blind

`sams_unit_price` is emitted verbatim in Sam's own notation, so everything that re-reads it had to be
checked rather than assumed. Four readers:

| reader | what it takes from the field | state |
|---|---|---|
| `compare-deals.ps1` -> `Get-DisplayedUnitPrice` (`derived-size-density-lib.ps1`) | `native_up`, the store's own per-unit on the board | **already cents-aware** |
| `compare-deals.ps1` -> `Get-DerivedRoundingPct` | `pu_rounding_pct`, the crown test's error bar | fixed here |
| `build-sams-deals.ps1` | the size derivation | fixed here |
| `audit-basis-reconcile.ps1` | the independent store-declared cross-check | **was blind, fixed here** |

**`audit-basis-reconcile.ps1` could not read the cents form at all.** Its regex wants a slash straight
after the number, so `92.8 c/lb` simply did not match, `$their` stayed `$null`, and the row lost its
independent cross-check silently. This guard's entire job is to compare our per-unit against the store's
own, and its sibling comment in `compare-deals.ps1` states the principle it was about to break: *"an
absent proof must never read as an agreeing one."* At 71.0% of priced rows it would have gone from
checking most Sam's rows to checking almost none while reporting nothing about it. It now reads through
the shared library.

**And `Get-DisplayedUnitPrice` had already derived this same rule independently** - value and half-width
both divided by 100 for the cents form, half-ulp from the printed decimals. Checked against the new
reader on five shapes:

```
  $0.93/lb    mine=(0.93,  +/-0.005 )   Get-DisplayedUnitPrice=(0.93,  +/-0.005 )   agree
  $0.25/oz    mine=(0.25,  +/-0.005 )   Get-DisplayedUnitPrice=(0.25,  +/-0.005 )   agree
  92.8 c/lb   mine=(0.928, +/-0.0005)   Get-DisplayedUnitPrice=(0.928, +/-0.0005)   agree
  24.8 c/oz   mine=(0.248, +/-0.0005)   Get-DisplayedUnitPrice=(0.248, +/-0.0005)   agree
  86 c/ea     mine=(0.86,  +/-0.005 )   Get-DisplayedUnitPrice=(0.86,  +/-0.005 )   agree
```

Exact agreement on value and half-width in all five. That is worth more than it looks: the half-ulp rule
was arrived at here from the 2026-09-20 capture, and independently by whoever wrote
`Get-DisplayedUnitPrice`, and the two land on the same numbers. **It is also a second copy of one rule,
which this estate's own rules warn about.** They are not folded together here because
`Get-DisplayedUnitPrice` also serves `wm_unit_price` under Walmart's deliberately looser glyph rule, so
unifying them is a cross-lane change with its own blast radius - recorded, not done.

## Still standing, deliberately not done

- **`walmart-row-lib.ps1` treats its cents-form rows as cent-rounded.** Measured over the Walmart
  captures on disk: **50,600 rows in cents form with exactly 1 decimal place, 11,131 in dollar form with
  2**. So 82% of Walmart's priced rows carry a tenth-of-a-cent number judged against a cent-wide window -
  the same over-loose bound this change closes for Sam's, on six times as many rows. It is a separate
  lane with its own blast radius on a live board and was **not** touched here. Walmart does not stamp
  `pu_rounding_pct`, so the crown-test half does not apply to it.
- **The rotation cursor already advanced past the 6 lost terms** (Sam's #197 -> #205), because the
  builder's cursor check only asks whether rows landed and two terms did. At 8 terms/day over 639 they
  will not come round again for about 80 days, so they need driving deliberately through Brad's Chrome,
  not waiting for the rotation.
- **Nothing here may become a `not-carried` ruling.** The 6 terms are UNUSABLE, never EMPTY:
  `UNCHECKED IS NEVER NOT-CARRIED`.

**Re-read at harness blob `bd299bc63f0d` (`grocery/build-sams-deals.ps1`, `git rev-parse HEAD:<path>`):**
2026-09-21, queue 2026-09-21-e291a1 (`grocery/triage-plans/plan-2026-09-21-3.json`). Build-Row now refuses a
DERIVED size the product cannot physically have, as a per-row `DENSITY CONFLICT`, through
`derived-size-density-lib.ps1`. Nothing this document measured moved: the cents reading, the half-ulp bound,
`$upDisplayTol` and the crown band are untouched. The 2026-09-20 counts (19 deals, 12 rejects) hold, because
that slice has no derived row the density rule can judge. The 2026-09-19 A/B would now read 2,800 deals in
BOTH arms rather than 2,802: that file carries the two 35 lb oil jugs at 799.6 and 799.429 fl oz (0.671 and
0.672 g/mL), and the new rule refuses both. The arms still differ in exactly the two files named above, so
the byte-identity finding stands.

Re-read at harness blob e3a9b356ef7817e6c890045b8aa32ad4df60812d (grocery/build-sams-deals.ps1): the cents-form reading (Get-SamsUnitPriceReading) and the display window it feeds are untouched by the three later changes (the dca1a1 per-piece guard, the count-first name rule of 2026-09-22, and its exemption of count-first names from that guard); build-sams-deals -SelfTest reads SELF-TEST PASS, exit 0, at this blob. The A/B arm figures above were NOT re-measured.
Re-read at harness blob 3004e2df162df2204dcbe93ea2adb8d2bc7a789c (grocery/pricing-math-lib.ps1): the one later change reads an 'A or B' size as the smaller size and does not touch the cents reading or the rounding-band table; not re-measured.
