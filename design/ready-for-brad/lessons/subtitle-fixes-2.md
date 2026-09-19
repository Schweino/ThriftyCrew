# Subtitle and search-text fixes, round 2: seven more Money Hacks pages (drafted 2026-09-19, APPLIED 2026-09-19)

## APPLIED

Brad gave the go-ahead and the queue was applied on 2026-09-19. All 7 PUTs were sent, at 05:46 that morning.

- **Queue ids** (the `id` on each line of `staged/subtitle-fixes-2.jsonl`): `5f6e422e6b37`, `d8173f3624a6`,
  `e29a8e280639`, `bcf0ba701a60`, `d9d16403e71f`, `721ac633c03a` and `5df6ff240633`.
- **Write-journal entries** for the same seven sends (the main checkout's `ops\ghost-journal.jsonl`, one per post,
  05:46:40 to 05:46:42): `3d30b02498cc`, `c7807a9e8609`, `72ca4c983bef`, `3c4b3bbb1891`, `18c59ef93af3`,
  `2e1cef6df0e2` and `1a0cd3ff8e2c`. The queue ids are not journal ids: none of the seven appears in the journal.
- All 7 pages were read back after the apply and all 3 sent fields (meta, OG and Twitter description) matched the
  draft on every page. A second read-only GET at the start of round 3 (`subtitle-fixes-3.md`) found the same 7 of 7.
  As predicted below, `updated_at` did not move on any of them, because the change was search text only.

**The Money Hacks hub was rebuilt the same morning, body only.** Write-journal entry `897631adc2e8` (05:47:59, a
PUT to the hub page `6a498e4950682b0001cd3f3f`). The html was built offline from a copy of
`.claude\skills\meal-macro\build-content-hubs.ps1`, and the diff against the live hub was exactly two cards'
subtitles (renters and car insurance, round 1's new lines) plus the signup link written relative. **The glossary hub
was deliberately NOT rebuilt**, although that script always rewrites both. The live hub now reads the new renters
and car-insurance subtitles, neither old line ("For about 15 dollars" / "Cut $300 to $600 a year") appears, and it
says "182 guides" (read-only GET at the start of round 3; the hub's `updated_at` is 10:47:58 UTC). That closes the first item under
"Anything odd" below. The builder's own problems are filed in `design\backlog-inbox\subtitle-fixes-0919.md`.

The rest of this file is the draft as it was approved, kept as the record.

`subtitle-fixes.md` (applied 2026-09-19) ended with a list of other live Money Hacks pages carrying the same
leftovers: "real-dollar" in six pages' search text, and dollar ranges on four. Brad asked to check and draft
them. This file checks each figure against the page's own body, drafts new wording where it is needed, and
sweeps every live Money Hacks post for anything the list missed.

**Nothing here has been sent to Ghost.** Every draft is a staged call in `staged/subtitle-fixes-2.jsonl`, one
PUT per page, 7 in all. Every page was read again right after staging and its `updated_at`, subtitle, search
text and body were all unchanged.

To apply, after reading the table below:

```
powershell -NoProfile -File ops\review-staged.ps1 -Queue design\ready-for-brad\lessons\staged\subtitle-fixes-2.jsonl          # list
powershell -NoProfile -File ops\review-staged.ps1 -Queue design\ready-for-brad\lessons\staged\subtitle-fixes-2.jsonl -Apply   # send
```

Listing it on 2026-09-19 printed `REVIEW-STAGED-COMPLETE queued=7 concerns=0`, exit 0.

Each PUT carries the `updated_at` read from the live page just before staging. If anyone edits one of these
pages first, Ghost refuses that PUT with a 409 and nothing on it changes. Re-draft that page; don't force it.
Each PUT sends only `meta_description`, `og_description` and `twitter_description`. **No subtitle and no body
changes in this round**, so titles, subtitles, tags, visibility, status, slug and the page text all stay as
they are, and the Money Hacks hub (which copies subtitles, see "Anything odd") is not affected.

## The body check, page by page

The test: does the page's own body carry the same figure, with its basis stated? SUPPORTED quotes the body
sentence. A SUPPORTED figure is kept. The eight shorthand names resolve to these slugs (Admin API GET, 2026-09-19).

| Page | Figure in subtitle or search text | Verdict | What the body says |
|---|---|---|---|
| `/how-to-save-money-on-utilities/` | $500 to $700 a year (both) | SUPPORTED | *"Do all of it and a typical household can trim $500 to $700 a year off bills you were treating as fixed."* It also says to *"treat these numbers as realistic estimates rather than promises."* |
| `/best-cash-back-apps/` | $300 to $600 a year (search only; the subtitle already says "a few hundred dollars") | SUPPORTED, with a caveat | *"One good card, your main store's app, and a browser extension can quietly return $300 to $600 a year for a few taps per week."* But see "Anything odd": the body's own layer figures add up to more than that. |
| `/frugal-habits-that-build-wealth/` | $5,000 to $10,000 a year (both) | SUPPORTED | *"Stack a handful of these and you can redirect $5,000 to $10,000 a year from leaking away to building something."* It also says *"these figures are typical estimates."* |
| `/how-to-do-a-spending-fast/` | $300 to $500 (both) | SUPPORTED | *"Run it for two to four weeks, and a typical household can redirect $300 to $500."* The search text says "in a month", and the body's own worked example is *"$380 you are about to redirect in a single month"*, so that holds too. **No change drafted for this page.** |

The other four pages carry no figure in their subtitle or search text, only "real-dollar":
`/how-much-house-can-i-afford/`, `/money-rules-to-live-by/`, `/how-to-track-your-expenses/` and
`/should-i-pay-off-my-mortgage-early/`. On all six "real-dollar" pages the body's numbers are worked
examples (*"Say your household brings in $84,000 a year"*, *"Say you owe $250,000 at 6.5 percent"*,
*"Coffee, 4 dollars. Gas, 42 dollars."*) or estimates the page itself calls typical, so "real-dollar" oversells
them, the same reason it came off the homeowners, savings-by-age and emergency-fund pages in round 1.

## Old next to new

The meta, OG and Twitter descriptions were identical on every page before, and they are identical after, so
each page has one "search and share text" row that covers all three. No subtitle changes.

### `/how-to-save-money-on-utilities/` (post `6a49a7da50682b0001cd4676`, updated_at `2026-07-05T00:39:54.000Z`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Cut $500 to $700 a year off utilities with real-dollar fixes for heating, hot water, phantom power, and your water and trash bills. No freezing required. | Cut $500 to $700 a year off utilities with simple fixes for heating, hot water, phantom power, and your water and trash bills. No freezing required. (148 chars) |

One word changes. The figure is SUPPORTED and stays. The subtitle (*"A room-by-room, bill-by-bill plan to trim
$500 to $700 a year off utility costs you were treating as fixed."*) is fine and is not touched.

### `/best-cash-back-apps/` (post `6a49a3cb50682b0001cd44b8`, updated_at `2026-07-05T00:22:35.000Z`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | The best cash-back apps and tools, ranked by real value, plus how to stack store apps, browser extensions, and card rewards to earn $300 to $600 a year. | The best cash-back apps and tools, catches included, plus how to stack store apps, browser extensions, and card rewards to earn $300 to $600 a year. (148 chars) |

The figure is kept. The wording around it had the problem: nothing on the page is ranked. The body says
*"Here is the honest lay of the land, grouped by type, with real numbers and the catches nobody puts on the
homepage"*, so "catches included" comes from there. The subtitle has no figure and is not touched.

### `/frugal-habits-that-build-wealth/` (post `6a49a3cc50682b0001cd44be`, updated_at `2026-07-05T00:22:36.000Z`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | 25 simple frugal habits, each with a real-dollar figure, that quietly build wealth over time. Stack a handful and redirect $5,000 to $10,000 a year. | 25 simple frugal habits, most with what they typically save, that quietly build wealth over time. Stack a handful and redirect $5,000 to $10,000 a year. (152 chars) |

"Each with a real-dollar figure" was wrong twice: habits 7 and 10 give a percentage and no dollar figure (23 of
25 carry one), and the body calls its figures *"typical estimates"*. "What they typically save" is that
phrase. The figure is SUPPORTED and stays; so does the subtitle.

### `/how-much-house-can-i-afford/` (post `6a49a71450682b0001cd4654`, updated_at `2026-07-05T00:36:36.000Z`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Use the 28 percent rule and the 36 percent debt backstop to find a house payment you can afford, with real-dollar examples and a purchase-price estimate. | Use the 28 percent rule and the 36 percent debt backstop to find a house payment you can afford, with a simple example and a purchase-price estimate. (149 chars) |

The body works one example household all the way through (*"Say your household brings in $84,000 a year"*).
"With a simple example" is the wording Brad approved for the homeowners page in round 1.

### `/money-rules-to-live-by/` (post `6a49a65b50682b0001cd45ea`, updated_at `2026-07-05T00:33:31.000Z`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Twenty simple money rules you can actually follow, with real-dollar examples, from paying yourself first to cutting debt and saving every raise. | Twenty simple money rules you can actually follow, no spreadsheet or finance degree needed, from paying yourself first to cutting debt and saving every raise. (158 chars) |

The body tells the reader to *"adjust the numbers to fit your real life"*, so its dollar amounts are
illustrations. The new phrase is the body's own: *"None of them require a spreadsheet or a finance degree."*

### `/how-to-track-your-expenses/` (post `6a49a65a50682b0001cd45de`, updated_at `2026-07-05T00:33:30.000Z`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Learn 5 simple ways to track your expenses, from a paper notebook to a budgeting app, with real-dollar examples to help you find where your money goes. | Learn 5 simple ways to track your expenses, from a paper notebook to a budgeting app, and let the numbers show you where your money goes. (137 chars) |

The body's amounts are everyday illustrations (*"Coffee, 4 dollars. Gas, 42 dollars."*). The new ending
borrows the bottom line: *"let the numbers tell you the truth. Once you can see where the money goes..."*

### `/should-i-pay-off-my-mortgage-early/` (post `6a49a57a50682b0001cd45bc`, updated_at `2026-07-05T00:29:46.000Z`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Should you pay off your mortgage early? Weigh your interest rate, other debts, and peace of mind with real-dollar examples to make the right call. | Should you pay off your mortgage early? Weigh your interest rate, other debts, and peace of mind, then run your own numbers to make the right call. (147 chars) |

The body's one example is a made-up loan (*"Say you owe $250,000 at 6.5 percent with 25 years left"*) and it
closes by asking the reader to *"run your specific numbers before making a big move"*. See "Anything odd" for
this page's body heading.

## Checks the staging script ran before it queued anything

- Each page was read again right before staging, and its `updated_at`, subtitle, all three descriptions and
  the whole body html matched the draft read, compared ordinally. If anything had changed, the script would
  have stopped.
- No em or en dash in any new value.
- Every number in a new value appears in that page's body or title: `$500` and `$700` (utilities), `$300` and
  `$600` (cash back), `25`, `$5,000` and `$10,000` (frugal habits), `28` and `36` (house), `5` (tracking).
- Every dollar figure in the old search text survives in the new one, because each was SUPPORTED.
- None of the removed wording survives in its page's new value: `real-dollar` on six pages, `ranked by real
  value` on cash back, `each with` on frugal habits.
- Every description is held to 160 characters so a search snippet isn't cut off (longest drafted is 158).
  Ghost's own limit is 500.
- Each PUT came back from `lib\ghost-lib.ps1` marked staged, not sent, and a read-only GET of all seven pages
  after staging showed nothing had moved.

## Voice: what the drafts were modelled on

Brad's ruling on 2026-09-19 is that reader copy is modelled on live posts and the July rewrite, never on
`content\lessons\*.md`. All reads were Admin API GETs through `lib\ghost-lib.ps1` with staging and the journal
cleared, on 2026-09-19:

- **Each page's own live body.** The drafts reuse its phrases wherever they could: "catches", "typical",
  "no spreadsheet or finance degree", "let the numbers", "run your own numbers".
- **The round 1 lines now live**, which Brad approved: *"Save on car insurance without cutting coverage. Smart
  shopping, deductibles, and every discount you should be claiming."* (car insurance) and *"Build a $1,000
  emergency fund in about 60 days with simple steps, easy math, and automatic transfers..."* (emergency fund),
  plus "with a simple example" from the homeowners line.
- **Live Money Hacks search lines with no figure to defend**, for length and shape: *"Stop letting raises
  vanish into nicer everything..."* (`/how-to-avoid-lifestyle-creep/`) and *"Most budgets fail by week three.
  Learn the five steps to build a budget that is honest, automatic, and forgiving enough to actually stick
  to."* (`/how-to-stick-to-your-budget/`).

## The sweep: every live Money Hacks post

**Scanned 182 of 182.** The Admin API returns 196 posts tagged Money Hacks, 182 published and 14 drafts. The
hub page (`/money-hacks/`) lists 182 cards, and they are the same 182 slugs, none missing either way. For each
one the subtitle and the meta, OG and Twitter descriptions were read; the three descriptions are identical on
all 182.

**71 of the 182** carry a dollar figure or "real dollar" wording in a subtitle or search text.

"Real-dollar" (hyphenated), **18 pages.** Six are drafted above. The other twelve are not drafted here:
`/monthly-bills-you-can-lower/`, `/what-to-do-with-a-tax-refund/`, `/when-should-i-start-investing/`,
`/should-i-pay-off-debt-or-save/`, `/online-bank-vs-traditional-bank/`, `/lease-vs-buy-a-car/`,
`/things-frugal-people-dont-buy/`, `/renting-vs-buying-a-home/`, `/new-vs-used-cars/`, `/roth-ira-vs-401k/`,
`/how-to-make-a-budget-that-actually-works/` and `/how-to-lower-your-electric-bill/`.

"Real dollar" or "real dollars" (no hyphen), **9 pages**, none drafted: `/credit-union-vs-bank/`,
`/whats-a-good-credit-score/`, `/pay-off-debt-vs-invest/`, `/15-vs-30-year-mortgage/`,
`/high-protein-breakfast-meal-prep/`, `/best-side-hustles-to-pay-off-debt/`, `/grocery-bill-hacks/`,
`/false-frugal-traps/` (subtitle too) and `/how-to-teach-your-kids-about-money/`. The last one means
something else (*"using real dollars and cheap mistakes"*: kids handling actual money), so it is probably
fine as it is.

Dollar figures: **97 distinct figures across those pages. A mechanical check found 80 written the same way in
the page's own body and 17 not**, on 14 pages. That check only looks for the exact string, so a miss is a
candidate, not a verdict. Four were read by hand and three were the same number written another way:
`/things-to-do-with-an-extra-1000-dollars/` (body: "1,000 dollars"), `/5-ingredient-meal-prep-recipes/` (body:
"1.10 per serving") and `/fast-food-copycat-meal-prep/` (body: "1.30" and "0.75"). The fourth,
`/batch-cooking-chicken-guide/`'s "about $1 a serving", did not turn up in the body lines read. These eleven are
still open (batch cooking, plus ten not read at all):

| Page | Figure not found as written |
|---|---|
| `/batch-cooking-chicken-guide/` | $1 (search) |
| `/budget-breakfast-ideas/` | $1 and $100 (search) |
| `/cheap-crockpot-meals/` | $1 (search) |
| `/cheap-high-protein-snacks/` | $1 (search) |
| `/ground-beef-meal-prep-ideas/` | $1 (search) |
| `/high-protein-breakfast-meal-prep/` | $30 (subtitle) |
| `/how-to-do-a-pantry-challenge/` | $150 (search) |
| `/how-to-make-a-grocery-budget/` | $100 (search) |
| `/instant-pot-meal-prep/` | $2 (search) |
| `/kid-friendly-meal-prep/` | $1 (search) |
| `/sheet-pan-meal-prep-dinners/` | $50 (search) |

A figure found in the body passed only the mechanical half of the test, not the "basis stated" half. The
figures that were checked properly are the four in the table at the top.

Titles were out of scope: 13 of the 182 carry a dollar figure in the SEO title (for example *"20 Cheap
Breakfast Ideas Under $1 a Serving"*), none of which were checked.

## Anything odd

- **The Money Hacks hub still shows round 1's old subtitles.** The hub page copies every card's subtitle into
  its own html when it is built (`.claude\skills\meal-macro\build-content-hubs.ps1`, line 151), and it was not
  rebuilt after round 1 went live. Of its 182 cards, 180 match the live subtitle and 2 do not: renters (*"For
  about 15 dollars a month..."*) and car insurance (*"Cut $300 to $600 a year..."*). So the figures round 1
  took off those pages are still on the hub. Rebuilding the hub is a live write and is not staged here. This
  round changes no subtitle, so it adds nothing to that gap.
- **The cash-back page disagrees with itself.** The bottom line says the three layers return $300 to $600 a
  year, but the body gives the store app alone as *"$400 to $700 a year"* and the card as *"$375 to $500
  back"* on $25,000 of spending. The figure was kept in the search text because the body states it, but the
  body is where the fix belongs, and that is Brad's call.
- **The mortgage page's body heading says "Run the numbers on a real example"** over a loan it introduces with
  "Say you owe". It is the same shape as the renters heading round 1 changed. Not staged, because this round
  touches no body.
- **A search-text-only change does not move `updated_at`.** Round 1's savings-by-age and emergency-fund pages
  still read 09:59:04 and 09:59:03 after the apply, while renters and car insurance, whose subtitles changed
  too, read 10:33. Every PUT in this round is search-text-only, so after the apply, check the field values,
  not `updated_at`, to see that it landed.
