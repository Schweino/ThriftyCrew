# Subtitle and search-text fixes, round 3: the rest of the Money Hacks sweep (drafted 2026-09-19, NOT applied)

Round 2 (`subtitle-fixes-2.md`, applied 2026-09-19) ended with a sweep of all 182 live Money Hacks posts and three
lists it did not draft: twelve more pages whose search text says "real-dollar", nine that say "real dollar(s)", and
17 snippet figures that a mechanical check could not find written the same way in the page's body. It also found
two body problems: the cash-back page's numbers disagree with each other, and the mortgage page has a heading
that says "real example" over a made-up loan. Brad ruled "Draft all of it". This file is that draft.

**Nothing here has been sent to Ghost.** Every draft is a staged call in `staged/subtitle-fixes-3.jsonl`, one PUT
per page, **25 in all**. Every page was read again right after staging and all 25 were unchanged: `updated_at`,
subtitle, the three descriptions, the body html and the lexical, compared ordinally.

To apply, after reading the tables below:

```
powershell -NoProfile -File ops\review-staged.ps1 -Queue design\ready-for-brad\lessons\staged\subtitle-fixes-3.jsonl          # list
powershell -NoProfile -File ops\review-staged.ps1 -Queue design\ready-for-brad\lessons\staged\subtitle-fixes-3.jsonl -Apply   # send
```

Listing it on 2026-09-19 printed `REVIEW-STAGED-COMPLETE queued=25 concerns=0`, exit 0.

Each PUT carries the `updated_at` read from the live page just before staging, so if anyone edits one of these
pages first, Ghost refuses that PUT with a 409 and nothing on it changes. Re-draft that page; don't force it.
Each PUT sends only the fields that change:

| What the PUT sends | Pages |
|---|---|
| Meta, OG and Twitter description only | 21 |
| Subtitle and the three descriptions | 2 (`/high-protein-breakfast-meal-prep/`, `/false-frugal-traps/`) |
| Body card and the three descriptions | 1 (`/best-cash-back-apps/`) |
| Body card only | 1 (`/should-i-pay-off-my-mortgage-early/`) |

**After the apply, the Money Hacks hub needs rebuilding for the two subtitle changes**, the same way it was
rebuilt this morning after round 1 (body only, glossary left alone). The hub copies every subtitle into its own
html when it is built, so until then it shows the old high-protein breakfast line (with *"$30 a week"*) and the
old false-frugal line (with *"real dollar numbers"*). None of the other 23 PUTs touches a subtitle, so they cannot
make the hub stale. Why this keeps happening is filed in `design\backlog-inbox\subtitle-fixes-0919.md`.

As round 2 found, a search-text-only PUT does not move `updated_at`. After the apply, check the field values to
see that it landed.

## (a) "Real-dollar" and "real dollar(s)"

Every one of these pages' numbers is a worked example ("Say you...", "Picture two people...") or an estimate the
page itself calls ballpark, general or not a promise. "Real-dollar" says the opposite, which is why it came off the
homeowners, savings-by-age, emergency-fund and six round-2 pages. Each replacement below borrows the page's own
words where it could, and every figure the old line carried is still there unless a verdict in (b) says otherwise.

**"Real-dollar", 12 pages, 12 drafted:** `/monthly-bills-you-can-lower/`, `/what-to-do-with-a-tax-refund/`,
`/when-should-i-start-investing/`, `/should-i-pay-off-debt-or-save/`, `/online-bank-vs-traditional-bank/`,
`/lease-vs-buy-a-car/`, `/things-frugal-people-dont-buy/`, `/renting-vs-buying-a-home/`, `/new-vs-used-cars/`,
`/roth-ira-vs-401k/`, `/how-to-make-a-budget-that-actually-works/` and `/how-to-lower-your-electric-bill/`.

**"Real dollar(s)", 9 pages, 8 drafted, 1 kept:**

| Page | Where | Decision |
|---|---|---|
| `/credit-union-vs-bank/` | search | drafted |
| `/whats-a-good-credit-score/` | search | drafted |
| `/pay-off-debt-vs-invest/` | search | drafted |
| `/15-vs-30-year-mortgage/` | search | drafted |
| `/high-protein-breakfast-meal-prep/` | search | drafted (with a (b) fix to its subtitle) |
| `/best-side-hustles-to-pay-off-debt/` | search | drafted |
| `/grocery-bill-hacks/` | search | drafted |
| `/false-frugal-traps/` | subtitle and search | drafted, both |
| `/how-to-teach-your-kids-about-money/` | search | **KEPT.** *"using real dollars and cheap mistakes while the stakes are still small"* means kids handling actual cash, which is exactly what the body teaches: *"Use real coins and small bills. Let them hold it, count it, and hand it to the cashier themselves"*, and the bottom line, *"A kid who has handled real dollars, blown a little, and recovered..."*. It makes no claim about the page's numbers. |

A fresh sweep of the 182 published Money Hacks posts at the start of this round found exactly these 12 and 9, and
none of round 2's seven pages (all seven now read "real-dollar" nowhere).

## (b) The 17 snippet figures the mechanical check could not find

Round 2's check looked for each figure in the body as the exact string, so "$1,000" missed "1,000 dollars". Each of
the 17 was read here by hand against the page's live body. **SUPPORTED** means the body says the same number another
way (quoted). **PARTLY** means the body says something close but not that. **UNSUPPORTED** means the body does not
say it at all. Only PARTLY and UNSUPPORTED get a fix.

| # | Page | Figure (where) | Verdict | What the body says |
|---|---|---|---|---|
| 1 | `/5-ingredient-meal-prep-recipes/` | $1.10 a serving (search) | SUPPORTED | *"Add all eight of these up and your weekly rotation averages around 1.10 per serving."* The eight per-serving figures do average $1.12. |
| 2 | `/batch-cooking-chicken-guide/` | $1 a serving (search) | **PARTLY** | *"That comes out to about 75 cents of protein per serving"*, and the full plate is *"about $1.20 a plate"*. The search text says protein at about $1, which is neither. |
| 3 | `/budget-breakfast-ideas/` | $1 a serving (search) | SUPPORTED | *"Almost every breakfast worth eating can be built for under a dollar a serving"*; all 20 listed are 20 to 85 cents, and the title says "Under $1 a Serving". |
| 4 | `/budget-breakfast-ideas/` | over $100 a month (search) | **PARTLY** | *"Do that five mornings a week and you've spent well over a hundred dollars a month"*. That is what the drive-thru costs, not what skipping it saves. At the body's own prices the saving is about $97 to $119 a month. |
| 5 | `/cheap-crockpot-meals/` | $1 to $2 a plate (search) | SUPPORTED | *"tender, filling meals for a dollar or two a serving"*. The search text's "$2" was already found by the check. |
| 6 | `/cheap-high-protein-snacks/` | under $1 each (search) | SUPPORTED | *"Here are 15 high-protein snacks that each cost under a dollar per serving"*; the priciest is 90 cents, and the title says "Under $1 Each". |
| 7 | `/fast-food-copycat-meal-prep/` | $0.75 (subtitle) | SUPPORTED | *"Each frozen breakfast sandwich costs about 0.75 to make."* |
| 8 | `/fast-food-copycat-meal-prep/` | $1.30 (subtitle) | SUPPORTED | *"Cost per sandwich comes to about 1.30, including the bun and pickles."* |
| 9 | `/ground-beef-meal-prep-ideas/` | about $1 a serving (search) | SUPPORTED | *"carry a family through a week of dinners and lunches for around a dollar a serving"*. |
| 10 | `/high-protein-breakfast-meal-prep/` | $30 a week (subtitle) | **PARTLY** | *"Do that five days a week and you have handed someone $25 to $35"*, and the bottom line, *"pocket the $25-plus a week you were handing to the drive-thru"*. $30 is inside that range but the body never says it. |
| 11 | `/how-to-do-a-pantry-challenge/` | $150 or more in a week (search) | SUPPORTED | *"Most families free up 150 to 250 dollars in a single week without a single coupon."* |
| 12 | `/how-to-make-a-grocery-budget/` | $100+ a month (search) | SUPPORTED | *"most families free up 100 to 150 dollars a month without eating worse."* But see "Anything odd": the body's own worked example gives less. |
| 13 | `/instant-pot-meal-prep/` | well under $2 a plate (search) | SUPPORTED | *"covers a week of lunches and dinners for well under two dollars a plate."* |
| 14 | `/kid-friendly-meal-prep/` | under $1 a serving (search) | **PARTLY** | *"veggie cups that run well under a dollar a serving"*, but its own items put the lunch trays at *"about 1 dollar per tray"* and the dinners at *"around 1 dollar 10 cents per serving"*. |
| 15 | `/sheet-pan-meal-prep-dinners/` | about $50 a week (search) | SUPPORTED | *"saves somewhere in the neighborhood of fifty dollars a week"*. |
| 16 | `/things-to-do-with-an-extra-1000-dollars/` | $1,000 (subtitle) | SUPPORTED | *"Here are the eight smartest things you can do with an extra 1,000 dollars"*; the title says "$1,000". |
| 17 | `/things-to-do-with-an-extra-1000-dollars/` | $1,000 (search) | SUPPORTED | The same. |

**Counts: 13 SUPPORTED, 4 PARTLY, 0 UNSUPPORTED**, over 17 figures on 14 pages. The 4 PARTLY figures are drafted
below (batch cooking, budget breakfast, high-protein breakfast and kid-friendly). Round 2 had already read four of
these pages by hand. It found the same number written another way on three of them (rows 1, 7, 8, 16 and 17 here),
and this round agrees. The fourth, batch cooking (row 2), it could not settle; this round rules it PARTLY.

## (c) The cash-back body: making its numbers agree

`/best-cash-back-apps/` gives a figure for each layer and a total for three of them, and they do not add up. Every
input below is the page's own; nothing is new.

| Layer | What the body says | Its own input, worked | Agrees? |
|---|---|---|---|
| Store app | *"saves $8 to $15 on a $120 cart. That is $400 to $700 a year"* | $8 x 52 = $416; $15 x 52 = $780 | **No.** The top end is $80 short. |
| Card | *"Spend $25,000 a year on it and that is $375 to $500 back"* | 1.5% and 2% of $25,000 | Yes |
| Browser extension | *"On $2,000 of online shopping a year at an average 4%, that is $80"* | 4% of $2,000 | Yes |
| Gas app (not in the total) | *"On 600 gallons a year, that is roughly $18 to $60"* | 3 and 10 cents x 600 | Yes |
| **Bottom line**: card, store app and extension | *"can quietly return $300 to $600 a year"* | $416 + $375 + $80 = **$871**; $780 + $500 + $80 = **$1,360** | **No.** The store app alone clears the whole range. |

So the page's inputs are consistent with each other, and the two figures that disagree are both arithmetic done on
them: the store app's yearly figure and the bottom-line total.

**Two ways to make them agree:**

- **A. Put the real sum in the bottom line**: "roughly $870 to $1,360 a year on the spending in the examples
  above". Every number is the page's own. But it would more than double the page's headline promise on the
  strength of three assumed spending levels stacked together (a $120 cart every single week, $25,000 a year on one
  card, $2,000 online), none of which has a source. And it would then contradict the subtitle and the intro, which
  both say *"a few hundred dollars a year"*, so those would have to change too, plus the Money Hacks hub.
- **B. Take the total out of the bottom line, and fix the one layer figure that is wrong.** This is the one
  drafted. It removes a figure rather than raising one, and changes two sentences and nothing else.

What B changes in the body, and nothing else:

| Where | Live now | Drafted |
|---|---|---|
| Store apps, first bullet | *...saves **$8 to $15** on a $120 cart. That is $400 to $700 a year for two minutes of tapping.* | *...saves **$8 to $15** on a $120 cart. That is $416 to $780 a year for two minutes of tapping.* |
| Bottom line | *...can quietly return **$300 to $600 a year** for a few taps per week.* | *...can quietly return **a few hundred dollars a year or more** for a few taps per week.* |

"A few hundred dollars" is the page's own phrase, from the subtitle and the intro, and "or more" is what the page's
own numbers say, because the three layers add up to at least $871. The yearly store-app figure is written exactly
($416 to $780), the way the card line already writes its product exactly ($375 to $500). With B, the subtitle and
intro need no change and neither does the hub. The search text did carry "$300 to $600", so it changes to the
bottom line's new wording.

The staging script checked that each old sentence appears exactly once in the card, that the card is the standard
single html card, that every other byte of the card is identical, and that no dash went in. The whole staged
PUT for the page is 8,859 bytes.

## The mortgage body heading

`/should-i-pay-off-my-mortgage-early/` has a heading *"Run the numbers on a real example"* over a section that
opens *"Let me make this concrete. Say you owe $250,000 at 6.5 percent with 25 years left."* It is the same shape as
the renters heading *"The real-dollar math"*, which round 1 changed to *"The math, with your own numbers"*. Here the
section really is one worked loan, so the heading keeps Brad's own "Run the numbers" and just says what it is:

| Live now | Drafted |
|---|---|
| `<h2>Run the numbers on a real example</h2>` | `<h2>Run the numbers on an example loan</h2>` |

Nothing else on the page changes. The search text was fixed in round 2 and says *"run your own numbers"* already, so
it is not in this PUT. I re-ran the section's own numbers: the payment is $1,688, the extra $300 pays it off in
17.6 years, and it saves about $85,700 in interest, which the body rounds to *"roughly 18 years"* and *"somewhere near
$90,000"*. That rounding is on the generous side; see "Anything odd".

## Old next to new

The meta, OG and Twitter descriptions were identical on every page before and are identical after, so each page has
one "search and share text" row that covers all three. Lengths are in characters. The longest search text drafted is
158 (the budget page); the longest subtitle is 184 (false-frugal traps), under Ghost's 300.

### `/monthly-bills-you-can-lower/` (post `6a49a18150682b0001cd446c`, updated_at `2026-07-05T00:12:49.000Z`, queue id `141e091e4210`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Fifteen common monthly bills you can lower this week, each with a real-dollar saving. Simple calls and clicks that can free up 300 dollars a month or more. | Fifteen monthly bills you can lower this week, each with a realistic saving to aim for. Simple calls and clicks that can free up 300 dollars a month or more. (157 chars) |

The body says *"I put a realistic dollar figure next to each one. Your mileage will vary"*, so "a realistic saving to aim for" is its own word. The 300 dollars is kept because the subtitle and the bottom line both say it, but see "Anything odd": the fifteen figures on the page add up to $265 a month, not "well over 300".

### `/what-to-do-with-a-tax-refund/` (post `6a499e7550682b0001cd43af`, updated_at `2026-07-05T11:02:30.000Z`, queue id `1cd176072e91`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | The smartest order for your tax refund: starter emergency fund, high-interest debt, overdue gaps, then long-term growth. Real-dollar examples inside. | The smartest order for your tax refund: starter emergency fund, high-interest debt, overdue gaps, then long-term growth. Simple examples inside. (144 chars) |

The body calls its numbers *"general examples"* and says *"Run your own numbers before you move money"*. "Simple examples" is the wording Brad approved in round 1.

### `/when-should-i-start-investing/` (post `6a499d9b50682b0001cd4399`, updated_at `2026-07-04T23:56:11.000Z`, queue id `7d1b747f9fc1`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | When should you start investing? Today, once you have a small emergency fund and no high-interest debt. See the real-dollar cost of waiting ten years. | When should you start investing? Today, once you have a small emergency fund and no high-interest debt. See what waiting ten years can cost you. (144 chars) |

The ten-year gap is one worked pair (*"Picture two people who both invest $200 a month"*) at an assumed 7 percent, which the page itself calls *"a long-run average, not a promise"*. The new line keeps the promise and drops "real-dollar".

### `/should-i-pay-off-debt-or-save/` (post `6a499cc650682b0001cd4341`, updated_at `2026-07-05T11:02:45.000Z`, queue id `3e5d525c07e6`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Should you pay off debt or save first? Build a small cushion, attack high-interest debt, then save. A simple order of operations with real-dollar examples. | Should you pay off debt or save first? Build a small cushion, attack high-interest debt, then save. A simple order of operations, and the math behind it. (153 chars) |

The subtitle already says *"The math makes the order obvious"*, and the body's examples start *"Say you have $5,000"* and *"Picture someone with $400 a month"*.

### `/online-bank-vs-traditional-bank/` (post `6a499cc350682b0001cd4323`, updated_at `2026-07-04T23:52:35.000Z`, queue id `19c76e28afb7`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Online banks pay more and charge less. Traditional banks give you a branch. Here is the real-dollar difference and which one fits your life. | Online banks pay more and charge less. Traditional banks give you a branch. Here is what the gap can mean on $10,000 in savings, and which one fits you. (152 chars) |

Both of the body's comparisons are on *"a $10,000 emergency fund"*, and its caveat says the 4 percent *"will drift up or down"*. The $500 in the subtitle is the body's *"a swing of roughly $500 a year"* and is not touched.

### `/lease-vs-buy-a-car/` (post `6a499cc350682b0001cd431d`, updated_at `2026-07-04T23:52:35.000Z`, queue id `632cc6607f46`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Leasing keeps payments low but you never own a thing. Buying costs more now, then pays you back. Here is the honest, real-dollar math on both. | Leasing keeps payments low but you never own a thing. Buying costs more now, then pays you back. Here is the honest math on both, using one common car. (151 chars) |

The body closes *"these are ballpark figures on one common car"*. "Honest math" was already the page's own phrase (*"Let me walk you through the honest math"*).

### `/things-frugal-people-dont-buy/` (post `6a499c0550682b0001cd42ef`, updated_at `2026-07-04T23:49:25.000Z`, queue id `e11746de655c`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | 20 things frugal people quietly stop buying, from bottled water to new cars, with real-dollar savings for each so you can bank thousands this year. | 20 things frugal people quietly stop buying, from bottled water to new cars, and roughly what walking away from most of them is worth over a year. (146 chars) |

"With real-dollar savings for each" was wrong twice: 18 of the 20 items carry a dollar figure (item 5 gives a percentage, item 17 none), and the page ends *"treat these figures as ballpark, not gospel"*. The new line is the body's own: *"roughly what walking away from each one is worth"*, with "most of them" because two have no figure. "Bank thousands this year" came off because the body only says that of picking three items (*"you could bank a few thousand dollars this year"*).

### `/renting-vs-buying-a-home/` (post `6a499c0350682b0001cd42d7`, updated_at `2026-07-04T23:49:23.000Z`, queue id `66649a40fd49`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Renting vs buying a home, with real-dollar examples on equity, repairs, and fees, plus clear guidance on which one actually fits your life. | Renting vs buying a home, with simple examples on equity, repairs, and fees, plus clear guidance on which one actually fits your life. (134 chars) |

The body ends *"These are general examples, not a promise."* Same fix as round 2's house-afford page.

### `/new-vs-used-cars/` (post `6a499c0250682b0001cd42d1`, updated_at `2026-07-04T23:49:22.000Z`, queue id `f6833d4d1de9`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | New or used? A real-dollar breakdown of depreciation, warranty, and insurance, plus clear guidance on which car choice actually saves you money. | New or used? A plain breakdown of depreciation, warranty, and insurance on a $35,000 example, plus clear guidance on which choice actually saves you money. (155 chars) |

Every figure on the page hangs off one example car (*"Buy a $35,000 car"*). See "Anything odd": the body's own intro still says *"let me lay both out with real dollars attached"*.

### `/roth-ira-vs-401k/` (post `6a499c0150682b0001cd42bf`, updated_at `2026-07-05T11:02:31.000Z`, queue id `3a8c071809c1`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Roth IRA or 401(k) first? Grab the full employer match, then fund the Roth for tax-free growth. Real-dollar examples and a simple funding order. | Roth IRA or 401(k) first? Grab the full employer match, then fund the Roth for tax-free growth. A simple funding order, worked on a $60,000 salary. (147 chars) |

The body works everything on one salary (*"If you make $60,000"*). The intro's *"with real numbers"* is left alone; it is a body line and this round only touches the two bodies it was asked to.

### `/how-to-make-a-budget-that-actually-works/` (post `6a498fa650682b0001cd3fe6`, updated_at `2026-07-04T22:56:38.000Z`, queue id `1130c782bb8a`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Build a budget that finally sticks. Real-dollar examples, the zero-based method, the 50/30/20 rule, and how to automate it so you never have to be a hero. | Build a budget that finally sticks. A sample month on $3,800, the zero-based method, the 50/30/20 rule, and how to automate it so you never have to be a hero. (158 chars) |

The body's budget is one example (*"Say that is $3,800 a month"*), laid out line by line.

### `/how-to-lower-your-electric-bill/` (post `6a498da450682b0001cd3f2e`, updated_at `2026-07-04T22:48:04.000Z`, queue id `191a0e1b60ba`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Cut your electric bill 10 to 20 percent with 13 real moves, from thermostat setbacks to utility rebates. Simple steps and real-dollar savings. | Cut your electric bill 10 to 20 percent with 13 real moves, from thermostat setbacks to utility rebates. Simple steps, and no sitting in the dark. (146 chars) |

"Real-dollar savings" is gone. "13 real moves" is kept because it is the body's own phrase (*"Here are thirteen real moves"*) and it says the moves are real, not that the dollars are. "No sitting in the dark" is the body's *"you do not have to sit in the dark"*.

### `/credit-union-vs-bank/` (post `6a499d9850682b0001cd4369`, updated_at `2026-07-04T23:56:08.000Z`, queue id `bab05a44828d`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Credit union or bank? Compare fees, loan rates, savings yields, ATM access, and safety with real dollar examples so you can pick the right one for your money. | Credit union or bank? Compare fees, loan rates, savings yields, ATM access, and safety, with simple examples, so you can pick the right one for your money. (155 chars) |

The body's numbers are examples it tells you to re-check (*"check the current numbers at the specific bank or credit union before you decide"*).

### `/whats-a-good-credit-score/` (post `6a499cc750682b0001cd4353`, updated_at `2026-07-05T11:02:44.000Z`, queue id `2efef17b815b`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | What is a good credit score? 670 is good, 740-plus is very good. See the ranges, what each tier costs you in real dollars, and how to climb. | What is a good credit score? 670 is good, 740-plus is very good. See the ranges, what a lower score can cost you on a mortgage or car loan, and how to climb. (157 chars) |

"What each tier costs you" oversold it: the body compares two scores on a mortgage (760 and 640) and two on a car loan, not every tier.

### `/pay-off-debt-vs-invest/` (post `6a499cc350682b0001cd4317`, updated_at `2026-07-04T23:52:35.000Z`, queue id `a4ba8b1e62fe`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Pay off debt or invest? Compare guaranteed returns, real dollar examples, and a simple rule to decide which one grows your money faster. | Pay off debt or invest? Weigh a guaranteed return against a hoped-for one, and use a simple rule to decide which one grows your money faster. (141 chars) |

"A hoped-for one" is the body's *"That 22 percent credit card beats a hoped for 7 percent in the market"*.

### `/15-vs-30-year-mortgage/` (post `6a499cc250682b0001cd4311`, updated_at `2026-07-04T23:52:34.000Z`, queue id `9638e112b910`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | 15 vs 30 year mortgage compared with real dollar examples: monthly payments, total interest, and how to pick the one that fits your budget. | 15 vs 30 year mortgage compared on one $300,000 loan: monthly payments, total interest, and how to pick the one that fits your budget. (134 chars) |

All of the body's figures are one loan (*"Say you borrow $300,000 at 7 percent"*). I re-ran the payments and interest: $1,996 and about $418,500 at 30 years, $2,613 and about $170,400 at 15 years, a gap of about $248,000, so the subtitle's $248,000 holds and is not touched.

### `/high-protein-breakfast-meal-prep/` (post `6a49991e50682b0001cd4246`, updated_at `2026-07-04T23:37:02.000Z`, queue id `3a7950e3bbbb`)

| Field | Live now | Drafted |
|---|---|---|
| Subtitle | Batch a week of 25-gram-protein breakfasts on Sunday for under $2 each and stop handing the drive-thru $30 a week. | Batch a week of high-protein breakfasts on Sunday for under $2 each and stop handing the drive-thru $25 or more a week. (119 chars) |
| Search and share text | High-protein breakfast meal prep under $2 a serving: egg muffins, overnight oats, and freezer burritos with real dollar costs and 25g+ protein. | High-protein breakfast meal prep under $2 a serving: egg muffins, overnight oats, and freezer burritos, with the cost and protein of each. (138 chars) |

Two changes, one PUT. **(a)** "real dollar costs" comes off the search text. **(b)** The subtitle's *"$30 a week"* is PARTLY supported (see the verdict table): the body says *"$25 to $35"* and closes *"pocket the $25-plus a week"*, so the new line says "$25 or more". **Also changed, because both lines were being rewritten anyway:** "25-gram-protein breakfasts" and "25g+ protein" promise more than the recipes give. The body's own figures are about 20 grams for two egg muffins, about 22 for an oat jar and about 25 for a burrito. So the subtitle now says "high-protein" and the search text says "the cost and protein of each". The body's intro makes the same 25-gram promise and is not touched here (see "Anything odd"). This page's subtitle changes, so the Money Hacks hub goes stale until it is rebuilt.

### `/best-side-hustles-to-pay-off-debt/` (post `6a498fa850682b0001cd3ff8`, updated_at `2026-07-04T22:56:40.000Z`, queue id `c8262fa50bfd`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | The side hustles that actually pay off debt fast, with real dollar math on how extra income cuts years and thousands of interest off your balance. | The side hustles that actually pay off debt fast, with simple math on how extra income cuts years and thousands of interest off your balance. (141 chars) |

The body's math is one worked example (*"Say you owe $6,000 on a credit card at 22 percent"*). See "Anything odd": that example's interest figure is understated.

### `/grocery-bill-hacks/` (post `6a498b7c50682b0001cd3e50`, updated_at `2026-07-04T22:38:52.000Z`, queue id `cf90073d39ce`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Cut your grocery bill $150 to $200 a month with unit-price math, store brands, loss leaders, cash-back apps, and less food waste. Real dollar examples inside. | Cut your grocery bill $150 to $200 a month with unit-price math, store brands, loss leaders, cash-back apps, and less food waste. Simple examples inside. (153 chars) |

The body's examples start *"If your normal run is $120"* and *"If a name brand costs $3.29"*. The $150 to $200 was already checked in round 2 and is kept.

### `/false-frugal-traps/` (post `6a498b7c50682b0001cd3e4a`, updated_at `2026-07-04T22:38:52.000Z`, queue id `81e07b451a74`)

| Field | Live now | Drafted |
|---|---|---|
| Subtitle | Some money moves feel thrifty but quietly drain your wallet. Here are seven false-frugal traps, from cheap shoes to bare-bones insurance, with real dollar numbers showing what they truly cost. | Some money moves feel thrifty but quietly drain your wallet. Here are seven false-frugal traps, from cheap shoes to bare-bones insurance, with the simple math on what they really cost. (184 chars) |
| Search and share text | Seven money moves that feel frugal but cost you more, from cheap tools and extreme couponing to skipped maintenance and bare-bones insurance, with real dollar examples. | Seven money moves that feel frugal but cost you more, from cheap tools and extreme couponing to skipped maintenance and bare-bones insurance, with the math. (156 chars) |

Both lines said "real dollar". The body's examples are illustrations (*"Say you save 40 dollars a month"*). The new subtitle keeps everything else word for word. This page's subtitle changes, so the Money Hacks hub goes stale until it is rebuilt. The body's own intro still says *"with real numbers"*; see "Anything odd".

### `/batch-cooking-chicken-guide/` (post `6a49a3cc50682b0001cd44c4`, updated_at `2026-07-05T00:22:36.000Z`, queue id `094d33509ff4`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Learn how to batch cook chicken that stays juicy, not dry. Five simple steps for a week of cheap, healthy protein at about $1 a serving. | Learn how to batch cook chicken that stays juicy, not dry. Five simple steps for a week of cheap, healthy protein at about 75 cents a serving. (142 chars) |

**(b) PARTLY.** The body puts the chicken at *"about 75 cents of protein per serving"* and a whole plate at *"about $1.20 a plate"*. "Protein at about $1" is neither, so the line now says 75 cents, which is what it is describing. The subtitle's *"about a buck a serving"* is left: it reads as a loose round of the $1.20 plate, not a figure.

### `/budget-breakfast-ideas/` (post `6a499cc450682b0001cd4329`, updated_at `2026-07-04T23:52:36.000Z`, queue id `a03e53a576cc`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | 20 cheap breakfast ideas under $1 a serving, from oatmeal to freezer burritos. Skip the drive-thru and save over $100 a month with real per-serving costs. | 20 cheap breakfast ideas under $1 a serving, from oatmeal to freezer burritos. Skip the drive-thru and save about $100 a month with real per-serving costs. (155 chars) |

**(b) PARTLY on the $100.** The body says the drive-thru habit costs *"well over a hundred dollars a month"*, which is spending, not saving. At the body's own numbers (five or six dollars, five mornings a week, and about 50 cents a serving at home) the saving is roughly $97 to $119 a month, so "about $100" and not "over $100". The *"under $1 a serving"* is SUPPORTED and kept. "Real per-serving costs" is not touched here (see "Anything odd").

### `/kid-friendly-meal-prep/` (post `6a49a65d50682b0001cd45fc`, updated_at `2026-07-05T00:33:33.000Z`, queue id `5411ea2d145c`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Kid-friendly meal prep that works: DIY lunch trays, freezer pancakes, deconstructed dinners, and veggie cups for under $1 a serving. | Kid-friendly meal prep that works: DIY lunch trays, freezer pancakes, deconstructed dinners, and veggie cups for about a dollar a serving or less. (146 chars) |

**(b) PARTLY.** The body's bottom line says *"well under a dollar a serving"*, but its own items put the lunch trays at *"about 1 dollar per tray"* and the dinners at *"around 1 dollar 10 cents per serving"*. Everything else is under a dollar. "About a dollar a serving or less" is true of all of them.

### `/best-cash-back-apps/` (post `6a49a3cb50682b0001cd44b8`, updated_at `2026-07-05T00:22:35.000Z`, queue id `878eab5afffc`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | The best cash-back apps and tools, catches included, plus how to stack store apps, browser extensions, and card rewards to earn $300 to $600 a year. | The best cash-back apps, catches included, and how to stack store apps, browser extensions, and card rewards for a few hundred dollars a year or more. (150 chars) |
| Body card | see part (c) or the mortgage section above | see above |

The body fix is worked through in part (c) above. The search text drops "$300 to $600 a year", which the body no longer says, for the body's new wording.

### `/should-i-pay-off-my-mortgage-early/` (post `6a49a57a50682b0001cd45bc`, updated_at `2026-07-05T00:29:46.000Z`, queue id `af935dafed70`)

| Field | Live now | Drafted |
|---|---|---|
| Body card | see part (c) or the mortgage section above | see above |

Body heading only, worked through above. The search text was fixed in round 2 and is not touched.

## Checks the staging script ran before it queued anything

- Each page was read again right before staging, and its `updated_at`, title, status, visibility, subtitle, all
  three descriptions, the body html and the lexical matched the draft read, compared ordinally.
- No em or en dash in any new value or in either new body card.
- Search text at most 160 characters (longest 158), subtitle at most 300 (longest 184).
- Every number in a new value appears in that page's body or title, or in the line it replaces.
- None of the wording being removed survives in its page's new value: "real-dollar" or "real dollar" on 20 pages,
  and on the PARTLY pages `$30`, `25g`, `25-gram`, `over $100`, `under $1` and "$1 a serving"; on cash back
  `$300`, `$600` and `$700`; on things frugal people don't buy, "for each".
- For the two body edits: each old sentence found exactly once, the card is the standard single html card, and the
  card outside the edit is byte-identical.
- Each PUT came back from `lib\ghost-lib.ps1` marked staged, not sent, and a read-only GET of all 25 pages after
  staging showed nothing had moved (25 of 25 unchanged).

The script is kept at `scratchpad\subfix3\stage.ps1` in this session's scratchpad; its shape is round 1's, which
carried the renters body edit.

## Voice: what the drafts were modelled on

Brad's ruling on 2026-09-19 is that reader copy is modelled on live posts and the July rewrite, never on
`content\lessons\*.md`. All reads were Admin API GETs through `lib\ghost-lib.ps1` with staging and the journal
cleared, on 2026-09-19. Nothing under `content\lessons\` was opened.

- **Each page's own live body.** Wherever a draft could, it reuses the body's phrase, and the notes above quote it:
  "realistic" (monthly bills), "honest math" and "one common car" (lease), "roughly what walking away from each one
  is worth" (things frugal people don't buy), "thirteen real moves" and "sit in the dark" (electric bill), "a hoped
  for 7 percent" (debt vs invest), "a few hundred dollars" (cash back), "Run the numbers" (mortgage).
- **The round 1 and round 2 lines now live**, which Brad approved: "with a simple example" (homeowners),
  *"Build a $1,000 emergency fund in about 60 days with simple steps, easy math, and automatic transfers..."*
  (emergency fund), and round 2's *"Should you pay off your mortgage early? Weigh your interest rate, other debts,
  and peace of mind, then run your own numbers to make the right call."* and *"...with a simple example and a
  purchase-price estimate."* (house afford). "Simple examples" and "simple math" in this round come from there.
- **The renters heading round 1 changed** (*"The real-dollar math"* to *"The math, with your own numbers"*) for the
  mortgage heading.

## Anything odd

These were found while reading the 36 pages above. None is drafted here, because each is a body change or a
different sweep, and each is Brad's call.

- **Monthly bills: the list does not add up to the promise.** The body says *"Add up the middle of those ranges and
  you are looking at well over 300 dollars a month"*, and the subtitle and search text both say 300 dollars a month
  or more. The fifteen figures on the page are single numbers, not ranges, and they add up to **$265 a month**, plus
  $35 for each overdraft avoided. The search text drafted here keeps the 300 because the subtitle and the body both
  say it, but the body is where the fix belongs.
- **Side hustles: the worked example understates its own interest.** *"Say you owe $6,000 on a credit card at 22
  percent interest, paying $150 a month... roughly $3,800 in interest."* Worked month by month, that takes 73
  months and costs about **$4,900** in interest. At $550 a month it takes 13 months and about $760, which matches
  the body's *"around $700"*. So the saving is about $4,200, and the body says *"over $3,000"*: true, but low by a
  thousand. The subtitle also says *"a five-year payoff into a one-year one"* while the body's intro says *"a
  five-year payoff into a two-year one"*.
- **Grocery budget: the bottom line is bigger than the example.** The body's worked example trims 10 to 15 percent
  off *"800 dollars a month"*, which is $80 to $120. The bottom line and the search text say *"100 to 150 dollars a
  month"*. Row 12 in (b) is SUPPORTED because the bottom line says it, but the example and the bottom line disagree.
- **High-protein breakfast: the intro promises 25 grams that two of the three recipes do not reach.** *"hit real
  protein numbers (25 grams or more)"*, then about 20 grams for two egg muffins and about 22 for an oat jar. This
  round took the 25-gram promise off the subtitle and search text because it was rewriting both anyway. The body
  line is untouched.
- **Kid-friendly meal prep: the bottom line says "well under a dollar a serving"** while two of its own items are
  about $1 and $1.10. The search text is fixed in (b); the body line is not.
- **Mortgage: two roundings lean generous.** The extra $300 a month saves about $85,700 in interest (body: *"somewhere
  near $90,000"*), and $300 a month for 25 years at 7 percent comes to about $243,000 if the 7 percent is compounded
  monthly but about $235,000 if it is an annual 7 percent (body: *"well over $240,000"*).
- **"Real" is still in some bodies.** The new-vs-used body says *"let me lay both out with real dollars attached"*,
  Roth says *"with real numbers"*, and false-frugal says *"with real numbers so you can see exactly how they get
  you"*. The debt-or-save page has a heading *"What this looks like on a real budget"* over *"Picture someone with
  $400 a month"*, the same shape as the mortgage heading. None is drafted: this round was asked for the mortgage
  heading only.
- **"Real per-serving costs", "real costs" and "real prices" are the next sweep of the same shape.** Counted over
  all 182 published Money Hacks posts (subtitle plus the three descriptions, the pattern "real", optionally
  "per-serving", then cost, costs, price or prices): **21 pages**, 20 of them food or meal-prep pages (the other is preparing for a baby), among them
  5-ingredient, budget breakfast, crockpot, ground beef, fast-food copycat, sheet pan and high-protein snacks from
  (b) above. Several of those bodies call their own figures estimates (*"treat these per-serving figures as ballpark
  estimates rather than promises"*, crockpot). Not drafted. A looser "real" plus any word matches 58 of the 182, most
  of them harmless ("real life", "real money off"), so that wider count is not a worklist.
- **Two Roth IRA limits on two live pages.** The tax-refund page says *"You can contribute up to $7,500 in 2026"*;
  the when-to-start-investing page says *"$7,000 in 2025"*. The investing page is a year stale. Also, its 7 percent
  is described as *"a reasonable long-run assumption for a broad stock index after inflation"*, which is a rate
  claim that `ops\audit-lesson-rate-claims.ps1` does not read, because it only reads markdown under `content\`.
- **The ids the round 2 apply was recorded under are queue ids, not journal ids.** The seven ids in the round 2
  handover are the `id` on each line of the staged queue; the write journal gave the same seven sends different
  ids. `subtitle-fixes-2.md`'s APPLIED section now lists both. Round 1's APPLIED section calls its six queue ids
  "write-journal ids" too; none of the six appears in the journal.
