# Body math fixes, round 4: the problems round 3 found (drafted and applied 2026-09-19)

## APPLIED

Brad gave the go-ahead and the queue was applied on 2026-09-19. **7 PUTs were sent**, 06:23:08 to 06:23:11 local
that morning (`-05:00` in the journal).

- **Queue ids** are the `id` on each line of `staged/subtitle-fixes-4.jsonl` and are listed per page below.
- **JOURNAL ids** (the main checkout's `ops\ghost-journal.jsonl`, one PUT per post, in queue order), matched by the
  post id in each entry's `uri` and its time. These are not the queue ids.

  | Page | Queue id | Journal id |
  |---|---|---|
  | `/best-side-hustles-to-pay-off-debt/` | `1b9be688586f` | `41128f061164` |
  | `/how-to-make-a-grocery-budget/` | `48985fd8886b` | `dd3fe29d7417` |
  | `/monthly-bills-you-can-lower/` | `726f6c2d0f1b` | `5f0adbf057ee` |
  | `/when-should-i-start-investing/` | `eb8488a79279` | `d78d742f63cb` |
  | `/high-protein-breakfast-meal-prep/` | `7543ad48dd02` | `548caf4e6ec4` |
  | `/kid-friendly-meal-prep/` | `da3b81747993` | `32719d0fcae6` |
  | `/should-i-pay-off-my-mortgage-early/` | `3a43c2eb9aa3` | `9ebe193a42d7` |

  Each of these seven posts has exactly one journal PUT on 2026-09-19 after round 3's sends (06:04:23 to 06:04:35),
  so the match is unambiguous. The handover for this step said the sends were after 06:30; the journal puts them at
  06:23, and the hub rebuild below at 06:23:51, which is the order the apply and the rebuild ran in.
- **Every page was read back: 7 of 7, 0 mismatches**, every sent field compared (the lexical by its html card).

**The Money Hacks hub was rebuilt right after, body only.** Journal id `a5eca70c4b85` (06:23:51, a PUT to the hub
page `6a498e4950682b0001cd3f3f`). The diff against the live hub was exactly the monthly-bills subtitle plus the signup
link written relative. **The glossary was not touched.** The live hub reads *"about 250 dollars a month"* and
*"182 guides"*.

The rest of this file is the draft as it was approved, kept as the record.

Round 3 (`subtitle-fixes-3.md`, applied 2026-09-19) ended with a list of body problems under "Anything odd": numbers
on a page that its own inputs do not support. Brad ruled "Draft fixes". This file is that draft.

**Nothing here has been sent to Ghost.** Every draft is a staged call in `staged/subtitle-fixes-4.jsonl`, one PUT
per page, **7 in all**. Every page was read again right after staging and all 7 were unchanged (`updated_at`,
subtitle, the three descriptions, the body html and the lexical, compared ordinally).

To apply, after reading the tables below:

```
powershell -NoProfile -File ops\review-staged.ps1 -Queue design\ready-for-brad\lessons\staged\subtitle-fixes-4.jsonl          # list
powershell -NoProfile -File ops\review-staged.ps1 -Queue design\ready-for-brad\lessons\staged\subtitle-fixes-4.jsonl -Apply   # send
```

Listing it on 2026-09-19 printed `REVIEW-STAGED-COMPLETE queued=7 concerns=0`, exit 0.

Each PUT carries the `updated_at` read from the live page just before staging, so if anyone edits one of these pages
first, Ghost refuses that PUT with a 409 and nothing on it changes. Re-draft that page; don't force it.

| What the PUT sends | Pages |
|---|---|
| Body card only | 5 (side hustles, investing, high-protein breakfast, kid-friendly, mortgage) |
| Body card and the three descriptions | 1 (grocery budget) |
| Body card, subtitle and the three descriptions | 1 (monthly bills) |

**One subtitle changes (monthly bills), so the Money Hacks hub needs rebuilding after the apply**, the same way as
after rounds 1 and 3 (body only, glossary left alone). Until then the hub shows the old monthly-bills line, *"can
free up 300 dollars a month or more"*.

**The rule every fix follows.** Each claim was worked from the page's own stated inputs. Where the claim and the
math disagree, the claim moves to the math, never the other way, unless an input is itself wrong and sourced
otherwise (only the Roth limit is). Understating counts as wrong as overstating, so a figure that was true but low
by a lot moves too. Each body edit is the smallest change that makes the sentence true; the staging script checked
that each old sentence appears exactly once in the card, that the card is the standard single html card, that every
byte outside the edits is identical, and that no dash went in.

## 1. Side hustles: the interest in the worked example

`/best-side-hustles-to-pay-off-debt/`. The page's inputs: *"Say you owe $6,000 on a credit card at 22 percent
interest, paying $150 a month"*, then *"a total payment of $550"*.

Worked month by month (interest 22/12 percent of the balance each month, then the payment):

| | $150 a month | $550 a month |
|---|---|---|
| Months to pay off | 73 (the last payment $113) | 13 (the last payment $157) |
| Interest paid | $4,913 | $757 |
| Interest saved | | $4,157 |

| Where | Live now | Drafted |
|---|---|---|
| Intro | *...can turn a five-year payoff into a **two-year** one.* | *...can turn a five-year payoff into a **one-year** one.* |
| Worked example | *...more than five years and roughly **$3,800** in interest.* | *...more than five years and roughly **$4,900** in interest.* |
| Worked example | *...in about **twelve** months and pay only around **$700** in interest.* | *...in about **thirteen** months and pay only around **$760** in interest.* |
| Worked example | *It saved you over **$3,000** in interest* | *It saved you over **$4,000** in interest* |

The intro now agrees with the subtitle, which already says *"a five-year payoff into a one-year one"* and is not
touched, and with the example (13 months). "Over $3,000" was true but low by more than a thousand, so it moves with
the $4,900. "More than five years" is kept: 73 months is true to it (see "Anything odd"). The search text says
*"cuts years and thousands of interest"*, which still holds, so it is not in this PUT.

## 2. Grocery budget: the bottom line against the worked example

`/how-to-make-a-grocery-budget/`. The page's input: *"If you have been spending 800 dollars a month, aim for 680 to
720"*, which is a trim of $80 to $120 (10 and 15 percent of $800). The bottom line said *"most families free up 100
to 150 dollars a month"* and the search text *"Free up $100+ a month"*. Nothing on the page works out $100 to $150.

| Field | Live now | Drafted |
|---|---|---|
| Bottom line | *Do that and most families free up 100 to 150 dollars a month without eating worse.* | *Do that and a family spending 800 dollars a month frees up 80 to 120 dollars without eating worse.* |
| Search and share text | Build a grocery budget from your real spending, trim it 10-15%, break it into weekly amounts, and use a system that makes you stop. Free up $100+ a month. | Build a grocery budget from your real spending, trim it 10-15%, shop by the week, and use a system that makes you stop. $800 a month frees up $80 to $120. (154 chars) |

"Shop by the week" is the body's own framing (*"nobody shops by the month"*); it replaces "break it into weekly
amounts" to fit the 160-character limit. The subtitle carries no figure and is not touched.

**A second reading Brad may prefer.** The page also quotes the USDA moderate plan for a family of four, *"250 to 300
dollars per week"*. That is $1,083 to $1,300 a month (times 52, divided by 12), and 10 to 15 percent of it is $108 to
$195. So "100 to 150" is inside what a family of four at the USDA figure would free up, but the page never does that
arithmetic, and "most families" is not something either number shows. The draft ties the claim to the example the
page actually works; if Brad would rather keep a family-of-four line, it should say "a family of four at the USDA
figure" and "about 110 to 195".

## 3. Monthly bills: the fifteen figures do not reach 300

`/monthly-bills-you-can-lower/`. The page's fifteen figures, as it states them:

| # | Bill | Per month |
|---|---|---|
| 1 | Cell phone | $30 |
| 2 | Internet | $20 |
| 3 | Streaming pileup | $25 |
| 4 | Premium tier | $10 |
| 5 | Auto insurance | $40 |
| 6 | Home or renters insurance | $15 |
| 7 | Life insurance rider | $8 |
| 8 | Bank fees | $12 |
| 9 | Overdraft | $35 per overdraft, not a monthly figure |
| 10 | Card interest | $17 |
| 11 | Electric | $18 |
| 12 | Water | $10 |
| 13 | Gym | $30 |
| 14 | App subscriptions | $20 |
| 15 | Delivery and memberships | $10 |
| | **The 14 monthly figures** | **$265** ($3,180 a year) |

The page says *"Add up the middle of those ranges"*, but they are single figures, not ranges, and they add to $265,
not *"well over 300"*. The subtitle and the bottom line both say *"a dozen of them"*: the twelve biggest monthly
figures add to $247 (the fourteen, less the $8 rider and one $10), so "about 250".

| Field | Live now | Drafted |
|---|---|---|
| Body, after the list | *Add up the middle of those ranges and you are looking at well over 300 dollars a month, or several thousand dollars a year,* | *Add up those monthly figures and you are looking at about 265 dollars a month, or more than 3,000 dollars a year,* |
| Bottom line | *Reopen a dozen of them this week and you can free up 300 dollars a month or more,* | *Reopen a dozen of them this week and you can free up about 250 dollars a month,* |
| Subtitle | Your bills are negotiations you stopped having, and reopening a dozen of them this week can free up 300 dollars a month or more. | Your bills are negotiations you stopped having, and reopening a dozen of them this week can free up about 250 dollars a month. (126 chars) |
| Search and share text | Fifteen monthly bills you can lower this week, each with a realistic saving to aim for. Simple calls and clicks that can free up 300 dollars a month or more. | Fifteen monthly bills you can lower this week, each with a realistic saving to aim for. Simple calls and clicks that can free up about 250 dollars a month. (155 chars) |

"Several thousand dollars a year" became "more than 3,000" because $3,180 is the page's own total and "several"
reads larger. The overdraft stays as the page wrote it, per overdraft. **This page's subtitle changes, so the hub
needs a rebuild after the apply.**

## 4. The Roth IRA limit on two pages

**Source: IRS, "Retirement topics - IRA contribution limits",
<https://www.irs.gov/retirement-plans/plan-participant-employee/retirement-topics-ira-contribution-limits>, page last
reviewed or updated 03-Aug-2026, read 2026-09-19.** It gives, for tax year 2026, $7,500 (or $8,600 if you're age 50
or older), and for 2025, $7,000 (or $8,000 at 50 or older). The limit is for all of a person's IRAs together,
traditional and Roth.

| Page | Live now | Against the IRS | Drafted |
|---|---|---|---|
| `/what-to-do-with-a-tax-refund/` | *"You can contribute up to $7,500 in 2026 if you are under 50"* | Agrees, and names the tax year | **No change**, not in the queue |
| `/when-should-i-start-investing/` | *"...the annual limit, which is $7,000 in 2025 for folks under 50."* | Right for 2025, a year stale | *"...the annual limit, which is $7,500 in 2026 for folks under 50."* |

Both pages now say $7,500 for 2026, under 50, as the IRS does. Every other live Money Hacks page that states the
current limit already says 2026 and $7,500 (Roth vs 401(k), how to open a Roth IRA, how to max out a Roth IRA, how to
open a brokerage account, starting to invest in your 30s); one more quotes 2025 figures, see "Anything odd".

## 5. High-protein breakfast: the 25-gram promise, and the muffin heading

`/high-protein-breakfast-meal-prep/`. The intro promises *"real protein numbers (25 grams or more)"*. The page's own
figures: two egg muffins *"around 20 grams of protein"*, an oat jar *"about 22 grams"* (30 with protein powder), a
burrito *"about 25 grams"*. Two of three miss 25; all three reach 20.

The egg-muffin heading says *"The $1.30 Grab-and-Go"*. The page's own math under it: *"$7.00 for 12 muffins. That is
about $0.58 per muffin. Eat two for breakfast and you have a $1.16 meal"*. $7.00 / 12 x 2 = $1.17, which the page
writes $1.16 (two times $0.58). Nothing on the page makes $1.30.

| Where | Live now | Drafted |
|---|---|---|
| Intro | *hit real protein numbers (25 grams or more)* | *hit real protein numbers (20 grams or more)* |
| Heading | *Egg Muffin Cups: The $1.30 Grab-and-Go* | *Egg Muffin Cups: The $1.16 Grab-and-Go* |

The heading uses the page's own $1.16 so the heading and the line under it match to the cent. The subtitle and
search text were rewritten in round 3 and say "high-protein" and "the cost and protein of each", which still hold.

## 6. Kid-friendly meal prep: the bottom line, and the pancakes

`/kid-friendly-meal-prep/`. The page's own figures:

| Item | What the page says | Per serving |
|---|---|---|
| Lunch trays | six trays for about six dollars | $1.00 |
| Pancakes | two dozen for roughly two dollars, *"around 15 cents per serving of three"* | 24 / 3 = 8 servings, $2 / 8 = **$0.25** |
| Egg muffins | twelve for about three dollars | $0.25 |
| Dinner | $1 + $4 + $1.50 = $6.50 for six portions | $1.08 (the page says $1.10) |
| Veggie cups | about 50 cents each | $0.50 |
| Veggie muffins | a dozen for about three dollars | $0.25 |

Three claims do not hold at those figures:

- **"Well under a dollar a serving"** (bottom line): the trays are $1 and the dinners $1.08. Round 3 already changed the
  search text to *"about a dollar a serving or less"*; the bottom line now says the same.
- **"15 cents per serving of three"**: two dozen pancakes in threes is eight servings at 25 cents. (Per pancake it
  would be about 8 cents, so 15 is right on neither reading.)
- **"For around fifteen dollars a week"** (bottom line): the week's batches the page lists cost $6 + $2 + $3 + $6.50 =
  **$17.50** before any veggie cups. With six cups (one per tray, which is my assumption; the page does not say how
  many) it is **$20.50**, and $23.50 with the optional veggie muffins. So "around twenty".

| Where | Live now | Drafted |
|---|---|---|
| Pancakes | *...or around <strong>15 cents per serving</strong> of three.* | *...or around <strong>25 cents per serving</strong> of three.* |
| Bottom line | *For around fifteen dollars a week you can stock...* | *For around twenty dollars a week you can stock...* |
| Bottom line | *...and veggie cups that run well under a dollar a serving and actually get eaten.* | *...and veggie cups that run about a dollar a serving or less and actually get eaten.* |

The pancake and weekly-total fixes were not in the brief; they turned up working the bottom line and are the same
kind of fault, the page's own inputs against its own claim. If Brad wants either left out, the PUT is re-staged
without it.

## 7. Mortgage: the roundings

`/should-i-pay-off-my-mortgage-early/`. The page's inputs: $250,000 at 6.5 percent with 25 years left, $300 a month
extra; and the same $300 a month invested at *"an average 7 percent for those same 25 years"*.

| Claim | Worked | Verdict |
|---|---|---|
| Payment *"around $1,688"* | $1,688.02 | Right |
| *"roughly 18 years instead of 25"* | 212 months, 17.7 years | Right |
| *"somewhere near $90,000 in interest"*, *"ninety grand"* | $256,405 base interest less $170,668 = **$85,737** | Rounds to $90,000 at the nearest ten thousand. Generous, not wrong. **Kept.** |
| *"Seven years of your life without a house payment"* | 25 - 17.7 = 7.3 years | Right |
| *"well over $240,000"* | $243,022 if the 7 percent is compounded monthly (7/12 percent a month, the convention the investing page's figures use); $234,913 if 7 percent is the annual return | **Wrong.** $3,000 over is not "well over", and on the annual reading it is under $240,000 |

| Where | Live now | Drafted |
|---|---|---|
| Investing comparison | *...you could end up with well over $240,000.* | *...you could end up with around $240,000.* |

"Around $240,000" is true on both readings ($235,000 to $243,000) and rounds to the same ten thousand the $90,000
does.

## Old next to new, per PUT

| Page (post id, updated_at sent) | Queue id | Fields sent | Body edits |
|---|---|---|---|
| `/best-side-hustles-to-pay-off-debt/` (`6a498fa850682b0001cd3ff8`, `2026-07-04T22:56:40.000Z`) | `1b9be688586f` | body | 4 |
| `/how-to-make-a-grocery-budget/` (`6a49991b50682b0001cd4210`, `2026-07-04T23:36:59.000Z`) | `48985fd8886b` | body, three descriptions | 1 |
| `/monthly-bills-you-can-lower/` (`6a49a18150682b0001cd446c`, `2026-07-05T00:12:49.000Z`) | `726f6c2d0f1b` | body, subtitle, three descriptions | 2 |
| `/when-should-i-start-investing/` (`6a499d9b50682b0001cd4399`, `2026-07-04T23:56:11.000Z`) | `eb8488a79279` | body | 1 |
| `/high-protein-breakfast-meal-prep/` (`6a49991e50682b0001cd4246`, `2026-09-19T11:04:29.000Z`) | `7543ad48dd02` | body | 2 |
| `/kid-friendly-meal-prep/` (`6a49a65d50682b0001cd45fc`, `2026-07-05T00:33:33.000Z`) | `da3b81747993` | body | 3 |
| `/should-i-pay-off-my-mortgage-early/` (`6a49a57a50682b0001cd45bc`, `2026-09-19T11:04:33.000Z`) | `3a43c2eb9aa3` | body | 1 |

The old next to new for every edit is in sections 1 to 7 above. Queue ids are staging ids, not journal ids; the
journal gives each send its own id when it is applied.

## Checks the staging script ran before it queued anything

- Each page was read again right before staging, and its `updated_at`, title, status, visibility, subtitle, all
  three descriptions, the body html and the lexical matched the draft read, compared ordinally. All 7 are published.
- Each old sentence found exactly once in its card; the card is the standard single html card; the card outside the
  edits is byte-identical; no em or en dash in any new value or new card.
- None of the wording being removed survives in the new sentences, and a check over each whole new card found none
  of it anywhere (the one "25 grams" left on the breakfast page is the burrito's, which is right).
- Every number in a new subtitle or search text appears in that page's new body.
- Search text at most 160 characters (longest 155), subtitle at most 300 (126).
- Each PUT came back from `lib\ghost-lib.ps1` marked staged, not sent, and a read-only GET of all 7 pages after
  staging showed nothing had moved (7 of 7 unchanged).

The script is kept at `scratchpad\subfix4\stage.ps1` in this session's scratchpad; its shape is round 3's.

## Voice: what the drafts were modelled on

Brad's ruling on 2026-09-19 is that reader copy is modelled on live posts and the July rewrite, never on
`content\lessons\*.md`. All reads were Admin API GETs through `lib\ghost-lib.ps1` with staging and the journal
cleared, on 2026-09-19. Nothing under `content\lessons\` was opened.

Every edit here is a number swap inside Brad's own live sentence, so the sentence around it is his, word for word.
Where words had to change:

- **"a family spending 800 dollars a month"** (grocery) is the page's own example, *"If you have been spending 800
  dollars a month"*, and "shop by the week" is its *"nobody shops by the month"*.
- **"Add up those monthly figures"** (monthly bills) keeps the page's *"Add up..."* and says what they are; the
  page's intro calls them *"a realistic dollar figure next to each one"*.
- **"about a dollar a serving or less"** (kid-friendly) is round 3's search-text line for the same page, now live.
- **"around $240,000"** keeps the page's own *"somewhere near $90,000"* register for a rounded figure.

## Anything odd

- **Side hustles: "more than five years" is 73 months, just over six.** True as written, so kept, and the subtitle's
  "five-year payoff" rests on it. If Brad wants it exact it becomes "about six years" and the subtitle and intro
  become "a six-year payoff into a one-year one"; not drafted.
- **Investing: "a gap of nearly $280,000".** At the page's own inputs ($200 a month, 7 percent, 40 years against 30,
  compounded monthly) the two totals are $524,963 and $243,994, a gap of $280,968, so "nearly" is $968 on the wrong
  side. Too small to draft on its own; "roughly $280,000" would fix it the next time the page is edited. The same
  page calls 7 percent *"a reasonable long-run assumption for a broad stock index after inflation"*, which is a rate
  claim with no source, the kind Brad's 2026-09-12 rate-of-return ruling covers.
- **Catch-up page quotes 2025 limits.** `/how-to-catch-up-on-retirement-savings/` says *"In 2025, that means putting
  up to $31,000 into a 401k and up to $8,000 into an IRA"*. Right for 2025 (the IRS page gives $8,000 for an IRA at
  50 or older in 2025), a year stale against the 2026 figures ($8,600 for an IRA). The 401(k) figure was not checked
  against an IRS source here. Not drafted.
- **Grocery budget has a family-of-four reading** that would support "100 to 150" (section 2). The draft takes the
  example the page actually works; say if the other is wanted.
- **The kid-friendly weekly total assumes six veggie cups.** The page gives the price per cup but not how many; with
  none it is $17.50, still over "around fifteen".
