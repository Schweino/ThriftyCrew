# The older live pages that overlap the three new lessons

Brad asked on 2026-09-19 to review the pages already on the site about insurance, emergency funds and net worth
BEFORE the three drafts in this folder go live. This is that review. **Nothing was published, edited or
unpublished.** Every page was read from Ghost with read-only Admin API GETs (write journal cleared), and search
numbers came from a read-only Search Console query.

## Where this stands: APPLIED AND VERIFIED LIVE (2026-09-19)

Queue 1, the redirect and queue 2 are all live. They were sent from the main checkout with
`ops\review-staged.ps1 -Apply` at the orchestrator's hand on Brad's "all as drafted" approval in chat, and each
page was then read back with a read-only GET and loaded at 375px. What follows the APPLIED record below is the plan
as it was staged, kept as the record of what was approved.

**Two id spaces, and only one of them undoes a write.** Each call carries a STAGED id (its line in the queue file)
and a separate WRITE-JOURNAL id (its entry in `ops\ghost-journal.jsonl`, holding the before-copy).
`ops\revert-ghost-write.ps1` takes the journal id.

### Queue 1: APPLIED 2026-09-19 04:59 (US Central), verified 14 of 14

| Page | Staged id | Journal id | New updated_at | html sha256 read back |
|---|---|---|---|---|
| `/life-insurance/` | `6f68329397f2` | `511c5e41de5f` | 2026-09-19T09:58:59.000Z | `b5045843b8c07c5c`, matches |
| `/term-vs-whole-life/` | `0cf899d47b2f` | `18705e3ed1a5` | 2026-09-19T09:58:59.000Z | `9086a009a48133fe`, matches |
| `/is-renters-insurance-worth-it/` | `e6c52e28f8e7` | `bf3a68bc8be0` | 2026-09-19T09:59:00.000Z | `bf996281c510feba`, matches |
| `/homeowners-insurance/` | `6ad589ae801c` | `eb34ba4c43af` | 2026-09-19T09:59:00.000Z | `674b8f02823c53b3`, matches |
| `/umbrella-insurance/` | `09e0ed40bfc9` | `164c7fea3891` | 2026-09-19T09:59:01.000Z | `5a580eccc5013554`, matches |
| `/insurance-premium/` | `000ca6237493` | `70dde4f968e9` | 2026-09-19T09:59:02.000Z | `ae8667c0818d9e6d`, matches |
| `/insurance-deductible/` | `9592fe0895c6` | `f96dd7d76fc5` | 2026-09-19T09:59:02.000Z | `f29267d4cab58634`, matches |
| `/how-to-build-an-emergency-fund/` | `4c7e8a707297` | `8b573ce85396` | 2026-09-19T09:59:03.000Z | `68337fb18f9ad596`, matches |
| `/emergency-fund-calculator/` | `be3e12ab67b5` | `83729c4ccbcf` | 2026-09-19T09:59:03.000Z | `675e9ab5f8b602e7`, matches |
| `/how-much-should-i-have-in-savings-by-age/` | `71a97db4b622` | `11c1a89454e6` | 2026-09-19T09:59:04.000Z | `87e5a07678e87f9b`, matches |
| `/how-to-save-on-car-insurance/` | `8d0af76beb6c` | `d606063640da` | 2026-09-19T09:59:04.000Z | `00143dcc19dce255`, matches |
| `/how-to-track-your-net-worth/` | `e236ef28e664` | `998c3d64a5cb` | 2026-09-19T09:59:05.000Z | `cae643bbadc91819`, matches |
| `/net-worth-calculator/` | `e41638b54583` | `8361968bca17` | 2026-09-19T09:59:05.000Z | `bdbb51296d31ff3c`, matches |
| `/net-worth/` | `b97277d9ab19` | `e2082497766e` | 2026-09-19T09:59:06.000Z | `6a28c26221f60e9f`, matches |

**What was checked on every page (read-only GETs, write journal cleared).** The lexical is still ONE html card, and
its html is byte-identical (ordinal compare) to the staged body. Its sha256 starts with the value in the table at
the top of the staged plan below. Every sentence the fix added appears exactly once. Every removed figure is gone
from the body. The body carries no em or en dash, before or after. Status (`published`), visibility (`public`),
slug, title, excerpt, meta, OG and Twitter fields, tags, tiers and the author id all equal the journal's before-copy.
Then each live page was loaded in the built-in browser at 375px with a cache-busting query: every page's
`scrollWidth` is 375 with no body element past the right edge, and the changed words were read on the rendered
page (for example *"What would that policy cost? I'm not going to guess."* and *"Get the number in dollars."*), with
the Fed link on `/how-to-build-an-emergency-fund/` pointing at the 2025 report. The one dash on any rendered page is
the theme's byline (*"04 Jul 2026 - 1 min read"* with an em dash), which no post body carries.

**Left standing, because queue 1 changed the card only (by design, see Queue 1 below).** These fields still carry
wording the body fixes took out, and they are what a reader sees under the title and what search shows:

- `/is-renters-insurance-worth-it/`: the excerpt shown under the title, *"For about 15 dollars a month..."*, and the
  meta, OG and Twitter descriptions, *"For roughly 15 dollars a month ... Here is the real-dollar math."* The body's
  heading is also still *"The real-dollar math"*, which was not in the drafted fixes.
- `/how-to-save-on-car-insurance/`: the excerpt shown under the title, *"Cut $300 to $600 a year off your car
  insurance..."*, and the meta, OG and Twitter descriptions, *"Save $300 to $600 a year..."*.
- `/term-vs-whole-life/`: the excerpt, *"Term life is cheap protection for now."*, where the body now says
  "costs less".
- "real-dollar" in the meta descriptions of `/homeowners-insurance/`, `/how-much-should-i-have-in-savings-by-age/`
  and `/how-to-build-an-emergency-fund/`.

Fixing them is a second PUT per page and a new approval; nothing was changed for them.

### The redirect: APPLIED 2026-09-19

Uploaded in Ghost Admin (Settings, Advanced, Redirects): the live file is the previous one plus exactly one line,
`^/good-net-worth-by-age/?$: /net-worth-by-age/`. **The previous file is backed up at
`C:\Users\Owner\Downloads\redirects-backup-2026-09-19.yaml`** (27,387 bytes, 490 lines), which is outside the repo;
upload it back to undo. Checked after queue 2 with curl: `/good-net-worth-by-age/` and `/good-net-worth-by-age` both
answer **301** to `https://www.thriftycrew.com/net-worth-by-age/`, which answers 200, and the browser lands there.

### Queue 2: APPLIED 2026-09-19 05:01 (US Central), verified 2 of 2

| Call | Staged id | Journal id | New updated_at | Read back |
|---|---|---|---|---|
| `/good-net-worth-by-age/` to draft | `31b75e67716c` | `69417ca37264` | 2026-09-19T10:01:40.000Z | status `published` to `draft`; body, slug, visibility, published_at and meta unchanged |
| Money Hacks hub card and count | `af95a0568161` | `d7f82cd0db95` | 2026-09-19T10:01:40.000Z | card byte-identical to the staged body; item list 183 to 182, none the retired slug; "183 free guides" and "Search 183 guides..." now read 182, and the page shows 182 at 375px |

Afterwards `ops\audit-ghost-page-census.ps1 -Export` refreshed `content\ghost-adopted\` (196 of 196 declared pages
read; 10 files changed, the 5 edited pages that are declared), and `good-net-worth-by-age` left
`ops\ghost-page-estate.json` and the export. The census then read 1,083 live web pages, 887 named by a tracked file,
196 declared, 0 findings. The other 9 edited pages are not declared, because the census's whole-token test finds
their slugs in tracked files: the glossary hub list in `.claude\skills\meal-macro\build-content-hubs.ps1`, the
redirect files, the new lesson drafts, this review and the backlog. None of those holds the page body, so the
census cannot see what changed on those 9; this review and the write journal are the record.

### The held link lines: APPLIED 2026-09-19 07:18 (US Central), once the lessons were live

The seven link lines this review held "once each new lesson is live" (section near the end) went out with the three
new lessons, staged in `new-lessons-oldpage-links.jsonl` and applied from the main checkout with
`ops\review-staged.ps1 -Apply`. Each is one paragraph inserted after the page's "Bottom line" paragraph; the full
record, with the three POSTs and the staged ids, is the APPLIED section at the top of `new-lessons-publish.md`.

| Page | Staged id | Journal id | updated_at now |
|---|---|---|---|
| `/emergency-fund/` | `2b96e009bed1` | `5dc53d4a6834` | 2026-09-19T12:18:50.000Z |
| `/insurance-premium/` | `11e7dcf9e38a` | `5ae475ffac5b` | 2026-09-19T12:18:51.000Z |
| `/insurance-deductible/` | `0fe6e779b654` | `0f27eadbe155` | 2026-09-19T12:18:51.000Z |
| `/liability-coverage/` | `4737e830e9df` | `fa5741866d54` | 2026-09-19T12:18:52.000Z |
| `/net-worth/` | `2fe9f41bf4ee` | `3a610a989ec7` | 2026-09-19T12:18:52.000Z |
| `/how-to-build-an-emergency-fund/` | `c9ffa50d93c3` | `d7018545f0ff` | 2026-09-19T12:18:53.000Z |
| `/how-to-track-your-net-worth/` | `9631dee15cfa` | `f7d751b7892e` | 2026-09-19T12:18:53.000Z |

All seven are still published and public (read-only GET). The orchestrator read each back with lexical equal to what
was sent. `liability-coverage` and `how-to-track-your-net-worth` are declared, so `ops\audit-ghost-page-census.ps1
-Export` refreshed their copies in `content\ghost-adopted\`, and the census then read 1,086 live web pages, 196
declared, 0 findings, exit 0.

## As staged (the approved plan)

Brad approved the whole plan as drafted on 2026-09-19 and ruled that **$1,000 stays the site's starter
emergency-fund number**. Everything below is prepared. **No Ghost write has been made and no redirect uploaded:**
the session that prepared it was a delegated agent, which may read Ghost but may not change the live site on a
relayed approval, so the writes wait in two queues in the estate's own staging format (`lib\ghost-lib.ps1`
`TC_STAGE_WRITES`, applied by `ops\review-staged.ps1`). Each queued PUT carries the `updated_at` read on
2026-09-19, so if any page changes before it is applied, Ghost refuses that one call with a 409 and nothing
stale lands.

**What was checked before staging (read-only GETs, write journal cleared).** All 22 pages still had the
`updated_at` the review read (none changed after 2026-07-05). The 7 staged pages that have an I167 export in
`content\ghost-adopted\` match it exactly (updated_at, lexical, html sha256). Every staged page is ONE html card,
and re-wrapping its live html with `Get-GhostLexical` reproduces its live lexical, so a PUT changes the card text
and nothing else. Each fix's old text occurs exactly once on its page; outside the fixed spans the new body is
byte-identical to the live one; no new body carries an em or en dash; and none still carries any of the removed
figures (for example `$25 to $35`, `15 dollars`, `24 percent`, `10 to 40 percent`, `every few months`). The new
bodies were read in full at 375px in the built-in browser (rendered locally, not live): no horizontal scroll.

### Queue 1: the sentence fixes, 14 pages, 37 replacements

`staged\overlap-fixes.jsonl`. Body sent per page: `lexical` and `updated_at` only (status, visibility, tags and
meta are not in the request, so Ghost leaves them as they are). The last column is the first 16 hex digits of the
sha256 of the new html card, to check each page against after the write.

| Page | Ghost id | Fixes | updated_at read | new html sha256 |
|---|---|---|---|---|
| `/life-insurance/` | `6a49916350682b0001cd4050` | 3 | 2026-07-04T23:04:03.000Z | `b5045843b8c07c5c` |
| `/term-vs-whole-life/` | `6a498d9c50682b0001cd3ec2` | 2 | 2026-07-04T22:47:56.000Z | `9086a009a48133fe` |
| `/is-renters-insurance-worth-it/` | `6a499cc750682b0001cd434d` | 7 | 2026-07-04T23:52:39.000Z | `bf996281c510feba` |
| `/homeowners-insurance/` | `6a49916550682b0001cd4062` | 1 | 2026-07-04T23:04:05.000Z | `674b8f02823c53b3` |
| `/umbrella-insurance/` | `6a49916350682b0001cd404a` | 1 | 2026-07-04T23:04:03.000Z | `5a580eccc5013554` |
| `/insurance-premium/` | `6a498d9b50682b0001cd3eb0` | 1 | 2026-07-04T22:47:55.000Z | `ae8667c0818d9e6d` |
| `/insurance-deductible/` | `6a498d9b50682b0001cd3eb6` | 1 | 2026-07-04T22:47:55.000Z | `f29267d4cab58634` |
| `/how-to-build-an-emergency-fund/` | `6a498da350682b0001cd3f22` | 6 | 2026-07-04T22:48:03.000Z | `68337fb18f9ad596` |
| `/emergency-fund-calculator/` | `6a498f9b50682b0001cd3f4a` | 1 | 2026-07-04T22:56:27.000Z | `675e9ab5f8b602e7` |
| `/how-much-should-i-have-in-savings-by-age/` | `6a49a57950682b0001cd45b6` | 2 | 2026-07-05T00:29:45.000Z | `87e5a07678e87f9b` |
| `/how-to-save-on-car-insurance/` | `6a498da450682b0001cd3f34` | 7 | 2026-07-04T22:48:04.000Z | `00143dcc19dce255` |
| `/how-to-track-your-net-worth/` | `6a4994d850682b0001cd41bc` | 3 | 2026-07-04T23:18:48.000Z | `cae643bbadc91819` |
| `/net-worth-calculator/` | `6a49943b50682b0001cd40f6` | 1 | 2026-07-04T23:16:11.000Z | `bdbb51296d31ff3c` |
| `/net-worth/` | `6a498b7250682b0001cd3dbe` | 1 | 2026-07-04T22:38:42.000Z | `6a28c26221f60e9f` |

**Three places where the applied text differs from the drafts below, and why:**

1. `/is-renters-insurance-worth-it/`: the live paragraph just above the drafted span, *"Let me show you why 15
   dollars a month is one of the best deals in personal finance."*, carries the same unsourced price. The drafted
   two paragraphs (labelled inventory, then the cost side) replace it together with the old inventory, cost and
   ratio paragraphs, so the section now opens on the labelled example.
2. `/how-to-build-an-emergency-fund/`: the draft said *"37 percent said they couldn't cover it all"*. The Fed
   reports that 63 percent WOULD cover it with cash or its equivalent; the 37 percent is the complement and said
   nothing as a group, so the sentence reads *"37 percent wouldn't cover it all with cash or something just as
   good"*, linked to the Fed report as the new lesson links it.
3. `/how-to-save-on-car-insurance/`: the bottom-line sentence's closing *"their finances"* follows the drafted
   new subject (*"you'll often pay less"*) and becomes *"your finances"*.

**Held, not staged: every link line that points at one of the three new lessons.** The plan's own heading says
*"once each new lesson is live"*, and all three are unpublished drafts, so a link today is a 404. That is the
italic lines for `/emergency-fund/`, `/insurance-premium/`, `/insurance-deductible/`, `/liability-coverage/` and
`/net-worth/`, the closing lines of the `/how-to-build-an-emergency-fund/` and `/how-to-track-your-net-worth/`
fixes, and the `/net-worth-by-age/` line in `README.md`. Add them when each target lesson goes live (a fresh GET,
because queue 1 will have moved every page's `updated_at`).

### Queue 2: retire `/good-net-worth-by-age/`, 2 calls, ONLY after the redirect answers 301

`staged\overlap-retire.jsonl`: the post to `status: draft` (body `status` and `updated_at` only), and the Money
Hacks hub with that one guide's card removed and its two "183 guides" counts set to 182 (the hub's own item list
then parses to 182 entries, none of them the retired slug).

The redirect line is in `grocery\redirects-base.yaml`:

    ^/good-net-worth-by-age/?$: /net-worth-by-age/

The redirect cannot go through the API: the integration key gets a 403 on `/ghost/api/admin/redirects/download/`
(checked 2026-09-19), as it does on every settings write. And an upload REPLACES the whole redirect set. So the
safe order is:

1. Ghost Admin, Settings, Advanced, Redirects: **download** the current file, add the one line above under `301:`,
   upload it back. (Do not upload a regenerated file: the live set may hold rules the repo does not.)
2. Check `/good-net-worth-by-age/` answers **301 to `/net-worth-by-age/`** while the post is still published
   (Ghost checks uploaded redirects before its own routes; this step is what confirms it here). On 2026-09-19 it
   answered 200. If it still answers 200 after the upload, stop: queue 2 must not run.
3. Only then apply queue 2. At no point does a reader get a 404.

### Commands, from the main checkout once this is on main

    Copy-Item design\ready-for-brad\lessons\staged\overlap-fixes.jsonl $env:TEMP\overlap-fixes.jsonl
    powershell -NoProfile -File ops\review-staged.ps1 -Queue $env:TEMP\overlap-fixes.jsonl          # list
    powershell -NoProfile -File ops\review-staged.ps1 -Queue $env:TEMP\overlap-fixes.jsonl -Apply   # send

(`-Apply` deletes the queue file it sends, hence the copy. `TC_WRITE_JOURNAL` is armed for every process on this
box, so each PUT's before-image lands in the journal and `ops\revert-ghost-write.ps1` can undo it.) Then the
redirect steps above, then the same two commands on `overlap-retire.jsonl`. Afterwards:
`ops\audit-ghost-page-census.ps1 -Export` refreshes `content\ghost-adopted\` for the declared pages that moved
(so the daily census does not report EDITED-SINCE-EXPORT), and `good-net-worth-by-age` comes out of
`ops\ghost-page-estate.json` and the export, or the census reports DECLARED-NOT-LIVE.

### The three drafts, changed the same day (nothing published)

- `how-much-emergency-fund`: the first milestone is now **$1,000** (*"Your first stop is $1,000..."*, linking to
  `/how-to-build-an-emergency-fund/`), and the $400-a-month worked example starts there (2.5 months to $1,000,
  $1,000 divided by $400). "Try This Together" step 2 sends the reader to `/emergency-fund-calculator/`.
- `insurance-basics`: step 3 of "Try This Together" links `/liability-coverage/`. The renters and term-life links
  wait for queue 1, as drafted below.
- `personal-balance-sheet`: the "Rather do it on a screen?" line under the worksheet.

## The short version

- **22 live pages** sit on these topics. Every one is **public**, every one was published between 2026-07-02 and
  2026-07-05, and none was updated after 2026-07-05.
- **Search sends almost nothing to any of them.** Over 90 days (2026-06-19 to 2026-09-16) Google showed 21 of
  the 22 pages zero times. The one exception is `/is-renters-insurance-worth-it/`: 11 impressions, 0 clicks,
  best position 64.5, all for the query "is renters insurance worth it". For scale, the whole site drew 1,135
  impressions and 5 clicks across 256 URLs in that window. So none of these decisions is about protecting
  traffic. They're about what a reader sees.
- **Five pages put an unsourced price on insurance**, the exact thing Brad's I108 ruling keeps out of the
  lesson: `/life-insurance/` ($25 to $35 a month), `/term-vs-whole-life/` ($30 and $400 a month),
  `/is-renters-insurance-worth-it/` (about $15 a month, and a typical policy's limits), `/homeowners-insurance/`
  ($1,800 a year) and `/umbrella-insurance/` ($150 to $300 a year).
- **Five more state unsourced rates or statistics.** `/how-to-build-an-emergency-fund/` gives a savings rate "as
  of 2025" and a list of repair costs, `/how-to-save-on-car-insurance/` a string of discount percentages,
  `/good-net-worth-by-age/` and `/how-much-should-i-have-in-savings-by-age/` each project a 7 percent return with
  nothing next to it, and `/emergency-fund-calculator/` a "20 plus percent" card rate.
- **One page contradicts the site's own sourced numbers.** `/good-net-worth-by-age/` says the median net worth
  in the late 40s and 50s "runs a bit above $200,000". The site's own `/net-worth-by-age/` lesson, quoting the
  Federal Reserve's 2022 Survey of Consumer Finances, gives $247,200 for 45 to 54 and $364,500 for 55 to 64.
- **Four pages give three different answers to "how often do I check my net worth?"** The new lesson says
  once a year. `/how-to-track-your-net-worth/` says the same day every month, `/net-worth-calculator/` says
  every few months, and `/net-worth/` says once or twice a year.
- **None of the 20 glossary, Money Hacks and calculator pages reads like Brad.** They're written without
  contractions ("Here is", "It is", "do not"): 0 to 0.45 contractions per 100 words, against 2.48 to 4.13 in
  the seven live weeks the new drafts were modelled on. The two pages that do read like him are
  `/net-worth-by-age/` (4.34) and `/where-do-you-stand/` (3.74). That is a shape check, not a verdict; the
  read-aloud is Brad's.
- **Recommendation in one line:** keep almost everything, fix the priced and contradicting sentences (drafted
  below in Brad's voice), link the old pages to the new lessons, and retire exactly one page,
  `/good-net-worth-by-age/`, with a redirect to `/net-worth-by-age/`.

## One thing to know before any redirect

The three new lessons are drafted as **paid**. Every old page is **public**. Redirecting a public page into a
paid lesson swaps a free page for a paywall, and the free Glossary and Money Hacks pages are the ones a
non-member can read. So the only redirect recommended here is public to public. If Brad makes a lesson free,
the `how-to-track-your-net-worth` merge below becomes worth doing.

## The table

"Numbers" lists every figure the page states that is not pure arithmetic on its own example. "Inbound" is links
inside the body of any of the 1,084 published posts and pages; theme menus, tag archives and the sitemap are not
counted. "Search" is Google impressions and clicks over the 90 days above.

### Emergency fund (overlaps `how-much-emergency-fund`)

| Page | Type, visibility, published | Words | What it teaches | Numbers, and are they sourced? | Brad's voice? | Search | Inbound | Recommendation |
|---|---|---|---|---|---|---|---|---|
| `/emergency-fund/` | Glossary post, public, 2026-07-04 | 325 | The definition. Start with $1,000, then 3 to 6 months. Keep it in a separate savings account. A teen "oops fund". | $1,000 starter and 3 to 6 months as "a common" goal, not sourced but stated as convention. The rest is a labelled example ($3,000 a month, $250 a month). | No | 0 / 0 | money-glossary | **Keep as is, link to the new lesson.** It's the definition; the lesson is the "how much". |
| `/how-to-build-an-emergency-fund/` | Money Hacks post, public, 2026-07-04 | 885 | The $1,000 starter sprint: why $1,000 first, where to find it in 60 days, automate, protect. | **Unsourced:** car repair $500 to $900, vet $800 to $1,500, dental crown $1,000+, credit card at 24 percent, online banks "around 4 percent as of 2025" (so $40 a year), "hundreds of dollars" of stuff at home, $200 to $400 from selling it, "four or five" forgotten subscriptions. | No | 0 / 0 | money-hacks | **Keep and fix sentences** (drafted below). Different job from the lesson (the first $1,000, not the full target), and two existing redirects already point here (`/how-to-save-1000-dollars-in-30-days/` and `/how-to-build-a-financial-cushion/` in `grocery\redirects-base.yaml`), so retiring it would need those re-pointed. |
| `/emergency-fund-calculator/` | Resource post (tool), public, 2026-07-04 | 390 | A calculator: target, months covered, time to fully funded. Start with $1,000, keep it out of stocks. | "20 plus percent" credit card, "earns a few percent". Not sourced, loosely stated. | No | 0 / 0 | none in any body | **Keep, fix one sentence, and link to it from the new lesson.** Its month choices (1, 3, 6, 9, 12) fit the lesson's range exactly. |
| `/how-much-should-i-have-in-savings-by-age/` | Money Hacks post, public, 2026-07-05 | 865 | Mostly retirement multiples by age, with an emergency-fund section (3 to 6 months, $3,200 example). | Fidelity named for the salary multiples. **Unsourced:** "roughly half of Americans" could not cover $1,000. **Unqualified rate:** 7 percent return projecting $720,000 and $340,000. | No | 0 / 0 | money-hacks | **Keep and fix two sentences.** Adjacent, not a duplicate. |

### Insurance (overlaps `insurance-basics`)

| Page | Type, visibility, published | Words | What it teaches | Numbers, and are they sourced? | Brad's voice? | Search | Inbound | Recommendation |
|---|---|---|---|---|---|---|---|---|
| `/insurance-premium/` | Glossary, public, 2026-07-04 | 259 | Premium defined; weigh it against the deductible. | Policy A $120 a month and $500 deductible vs Policy B $85 and $1,500, called a "real-dollar example" though the figures are made up. Arithmetic checks ($420 a year, $1,000 more on a claim). | No | 0 / 0 | money-glossary | **Keep, fix one label**, link to the lesson. |
| `/insurance-deductible/` | Glossary, public, 2026-07-04 | 235 | Deductible defined; higher deductible, lower premium; only pick a deductible you have saved. | $2,000 deductible on $9,000 of roof damage, same "real-dollar" label on made-up figures. Arithmetic checks. | No | 0 / 0 | money-glossary | **Keep, fix one label**, link to the lesson. It uses the same "trapdoor" line the lesson does, which is consistent, not a clash. |
| `/life-insurance/` | Glossary, public, 2026-07-04 | 270 | Death benefit, term vs whole, term for most families. | **Unsourced price:** "a healthy 35-year-old can often buy a 20-year, $500,000 term policy for around $25 to $35 a month." Term "is cheap", whole "costs a lot more". | No | 0 / 0 | money-glossary | **Keep and fix** (drafted below). The price goes. |
| `/term-vs-whole-life/` | Glossary, public, 2026-07-04 | 283 | Term vs whole in plain terms. | **Unsourced prices:** "around $30 a month" for 20-year $500,000 term, whole life "$400 or more a month", "over $4,000 a year" difference. Ends by suggesting people "would do better investing on their own". | No | 0 / 0 | money-glossary | **Keep and fix** (drafted below). Same class as `/life-insurance/`, and it wasn't on the list Brad was given. |
| `/is-renters-insurance-worth-it/` | Money Hacks, public, 2026-07-04 | 941 | What renters covers, the landlord's policy covers the building only, the cost math, cutting cost, ACV vs replacement cost. | **Unsourced:** "about 15 dollars a month", "between 12 and 20 dollars a month", "call it 180 dollars a year", a "typical" $30,000 property and $100,000 liability, bundling saves "10 to 15 percent", "most renters land between 15,000 and 30,000 dollars", dog-bite claims "tens of thousands". The whole math section rests on the $180. | No | 11 impressions, 0 clicks, position 64.5 | money-hacks | **Keep and fix** (drafted below). It's the only page in this set Google shows for anything, and its question-shaped title is the reason. The lesson covers the same ground but doesn't answer "is it worth it". |
| `/liability-coverage/` | Glossary, public, 2026-07-05 | 265 | Liability defined; how to read 100/300/100; why the state minimum can leave you exposed. | "State minimum of, say, $25,000" and a $180,000 wreck, both labelled with "say". Arithmetic checks. | No | 0 / 0 | money-glossary | **Keep as is, link to it from the lesson.** It explains exactly the limits the lesson's "Try This Together" asks the reader to find. |
| `/homeowners-insurance/` | Glossary, public, 2026-07-04 | 273 | What it covers; lenders require it. | **Unsourced price:** "A typical policy might run $1,800 a year, or $150 a month." | No | 0 / 0 | money-glossary | **Keep and fix one sentence.** Not a direct overlap (the lesson does renters, not homeowners), same price class. |
| `/umbrella-insurance/` | Glossary, public, 2026-07-04 | 249 | Extra liability on top of auto and home. | **Unsourced price:** a $1 million umbrella "often runs $150 to $300 a year". | No | 0 / 0 | money-glossary | **Keep and fix one sentence.** Same price class. |
| `/how-to-save-on-car-insurance/` | Money Hacks, public, 2026-07-04 | 902 | Shop every year, raise the deductible only if you've saved it, ask for every discount. | **Unsourced:** switchers save "$300 to $600", a higher deductible trims "10 to 20 percent", bundling "10 to 25 percent", telematics "10 to 40 percent", under "7,500 miles", defensive driving "5 to 10 percent" for a "$20 to $30" course, and "$300 to $600 a year" again in the bottom line. | No | 0 / 0 | money-hacks | **Keep and fix sentences** (drafted below). Good advice, and a fair companion to the lesson's auto section once the percentages are gone. |
| `/coinsurance/`, `/copay/`, `/out-of-pocket-maximum/` | Glossary, public, 2026-07-04 and 05 | 271 to 274 each | Health insurance cost-sharing. | Labelled examples only. | No | 0 / 0 | money-glossary, and each other | **Keep as is.** The new lesson doesn't cover health insurance, so there's no overlap to manage. |

### Net worth (overlaps `personal-balance-sheet`)

| Page | Type, visibility, published | Words | What it teaches | Numbers, and are they sourced? | Brad's voice? | Search | Inbound | Recommendation |
|---|---|---|---|---|---|---|---|---|
| `/net-worth/` | Glossary, public, 2026-07-04 | 316 | Assets minus liabilities; negative early is common; track it once or twice a year. | Labelled example ($8,000 car, $2,000 savings, net $2,000). Arithmetic checks. | No | 0 / 0 | money-glossary, start-here | **Keep as is, link to the new lesson.** |
| `/how-to-track-your-net-worth/` | Money Hacks, public, 2026-07-04 | 883 | The same steps as the new lesson (sell value, skip the small stuff, today's balances, subtract, negative is a starting line), then **track it the same day every month**. | Labelled examples ($48,000 minus $61,000, $400 a month to nearly $5,000 a year). The page ends by saying its figures are examples. | No | 0 / 0 | money-hacks | **Keep and fix the cadence section** (drafted below) so it matches the lesson. This is the closest duplicate in the whole set. If Brad publishes the balance-sheet lesson free, merge instead: 301 this page to the lesson. |
| `/net-worth-calculator/` | Resource post (tool), public, 2026-07-04 | 354 | A calculator, "check this number every few months". | "Plenty of quiet, steady savers are millionaires", not sourced, soft. | No | 0 / 0 | none in any body | **Keep, fix the cadence sentence, link to it from the lesson's worksheet.** |
| `/good-net-worth-by-age/` | Money Hacks, public, 2026-07-05 | 915 | Net worth targets by decade as salary multiples, plus medians. | **Contradicts the site's own sourced page:** median in the late 40s and 50s "a bit above $200,000" (Fed 2022 gives $247,200 and $364,500). **Unqualified rate:** $300 a month from 22 "at around 7 percent a year" to "roughly $35,000 by 30" (at that rate the arithmetic gives about $37,000 compounded yearly and about $38,500 monthly, so even the example understates). **Unsourced:** Social Security "replaces only about 40 percent", "a dollar invested at 25 can grow to eight or ten dollars by 65", salary multiples with no source named. | No | 0 / 0 | money-hacks | **Retire and redirect to `/net-worth-by-age/`.** It answers the same question as a lesson that already does it with the Fed's own numbers, and gets that answer wrong. Both pages are public, so no paywall issue. |
| `/net-worth-by-age/` | Standalone lesson, public, 2026-07-03 | 927 | Medians by age from the Fed's 2022 Survey of Consumer Finances; why averages mislead. | Every figure names its source in the sentence (Fed SCF 2022, medians by age, mean over $1 million vs median about $193,000). I did not re-check them against the Fed's tables. | **Yes** | 0 / 0 | none in any body (it's in the lesson hubs) | **Keep as is**, and apply the link line already drafted in `README.md`. It becomes the redirect target above. |
| `/where-do-you-stand/` | Resource post (tool), public, 2026-07-02 | 321 | The free tool that places your number on the Fed's medians. | Fed SCF 2022, named. | **Yes** | 0 / 0 | my-crew, net-worth-by-age, start-here, welcome | **Keep as is.** The balance-sheet lesson could point at it. |

## Should the new lessons change?

**Insurance (`insurance-basics`).** Keep its own definitions of policy, premium and deductible: a lesson a
parent works through with a teen has to stand on its own. Three changes worth making:

1. In "Try This Together", step 3, point at the page that already explains how to read the limits:
   > 3. The **liability limits**, the most the policy will pay for damage you cause to someone else. They're
   > often written as three numbers, like 100/300/100. [Here's how to read them](/liability-coverage/).
2. **Keep NOT linking** to `/life-insurance/`, `/term-vs-whole-life/`, `/is-renters-insurance-worth-it/`,
   `/homeowners-insurance/` or `/umbrella-insurance/` until their price sentences are fixed. Once they are, the
   renter's section can end with *"Wondering if it's worth the money? [Here's the math](/is-renters-insurance-worth-it/)."*
   and the life section can link "Term life" to `/term-vs-whole-life/`.
3. Nothing to change on health insurance. The lesson doesn't cover it and the three health glossary pages
   already do.

**Emergency fund (`how-much-emergency-fund`).** Two changes worth making, one question:

1. In "Try This Together", step 2, send them to the tool that already exists:
   > Then let [the emergency fund calculator](/emergency-fund-calculator/) do the multiplying, and show you how
   > long it takes at what you can set aside each month.
2. Every public page on the site tells readers to **start with $1,000**. The lesson's first milestone is one
   month of essentials. They don't contradict, but a reader who has seen both will wonder. Once
   `/how-to-build-an-emergency-fund/` is fixed, one line under "don't try to climb it in one day" joins them:
   > If even one month feels far off, a first $1,000 is a great first stop. [Here's how to build it fast](/how-to-build-an-emergency-fund/).
3. **Question for Brad:** is $1,000 still the starter number you want the site to teach? It's not sourced
   anywhere, and it's the one thing the old pages and the new lesson say differently. **Answered 2026-09-19:**
   keep $1,000. The old pages keep their $1,000 starter, and the lesson's first milestone is now $1,000.

**Balance sheet (`personal-balance-sheet`).** It already links `/net-worth-by-age/`. Two changes worth making:

1. Keep **once a year**. It's the course's advice and the lesson's whole argument ("staring at it every day
   turns a planning tool into a worry machine"). Fix the three old pages to match it (drafted below), so the
   site stops giving three answers.
2. Under the worksheet, for anyone who'd rather do it on a screen:
   > Rather do it on a screen? [The net worth calculator](/net-worth-calculator/) adds it up for you. Then
   > [Where Do You Stand?](/where-do-you-stand/) shows where your number sits next to the Fed's numbers for your age.

## The drafted fixes

Each fix is written in Brad's voice: contractions, short sentences, no invented prices, no em dashes, and no
story about something Brad did. Every figure that stays is either an example labelled as one or a figure with its
source named in the sentence. **Approved 2026-09-19 and staged, not yet sent: see the top of this file.**

Where each fix lands: twelve of the 22 pages have no source in this repo at all (nine Glossary pages,
`/how-to-build-an-emergency-fund/`, `/is-renters-insurance-worth-it/` and `/where-do-you-stand/`), so a fix is an
edit to the live post in Ghost: fetch it, change the paragraph, put it back. Eight more have the I167 export in
`content\ghost-adopted\`, and `ops\audit-ghost-page-census.ps1` reports a declared page edited after its export,
so re-export those in the same sitting as the edit. `/net-worth-by-age/` has its source in `content\lessons\`.

### `/life-insurance/`

Replace *"Term life covers you for a set stretch, like 20 or 30 years, and it is cheap. Whole life lasts your whole
life and builds a cash value, but it costs a lot more. For most families raising kids or carrying a mortgage, plain
term life does the job at a fraction of the price."* with:

> Term life covers you for a set stretch, like 20 or 30 years. Whole life lasts your whole life and builds a cash
> value, and that's a big part of why it costs more for the same payout. For a lot of families raising kids or
> carrying a mortgage, term is the simple way to get the coverage they need for the years they need it.

Replace the paragraph starting *"Here is a real-dollar example. A healthy 35-year-old..."* with:

> Here's a made-up example to show how it works. Say a parent buys a 20-year term policy with a $500,000 death
> benefit. If they die during those 20 years, the people they named get $500,000. That can pay off a house and
> cover years of the paycheck the family runs on. What would that policy cost? I'm not going to guess. Your price
> depends on your age, your health, how much coverage you buy and for how long, so the only number that counts is
> the quote you get when you ask. What's true for almost everybody is the shape of it: the same coverage tends to
> cost less when you buy it younger and healthier.

Replace the bottom line with:

> **Bottom line:** If someone depends on your income, term life is one of the simplest ways to make sure they're
> taken care of if you're gone. Get a real quote. It's the only price that's actually yours.

### `/term-vs-whole-life/`

In the first sentence, replace *"and is cheap"* with *"and costs less"*. Replace the paragraph starting *"This
matters because for most families..."* with:

> This matters because for most families, the whole point of life insurance is replacing your income while
> people depend on you. So how big is the price gap? Big enough to ask about. For the same payout, whole life
> costs a lot more, because part of every premium goes into that cash value. Don't take anybody's example price
> for it, including mine. Ask for a quote on both, same payout, same you, and put the two monthly numbers side by
> side. That comparison will tell you more than any article can.

### `/is-renters-insurance-worth-it/`

Opening, replace *"For most renters, yes, it is worth it, because a policy that runs about 15 dollars a month
protects thousands of dollars of your stuff and shields you from liability claims that could wipe out your
savings."* with:

> For most renters, yes. It pays to replace your stuff if it's stolen or ruined, and it covers you if someone gets
> hurt at your place. The only way to know what it costs you is to get a quote, so let's do the math with yours.

"The real-dollar math" section. Keep the inventory example but label it, and replace everything from *"Now the cost
side"* through *"You only need one."* with:

> Say a kitchen fire next door sends smoke into your place. These numbers are made up to show the math, so swap in
> your own: a 700 dollar laptop, a 500 dollar TV, 3,000 dollars in furniture, 1,500 in clothes, 400 in kitchen gear
> and a 300 dollar bike. That's 6,400 dollars. Most people guess low until they actually count.
>
> Now the cost side. I'm not going to hand you an average price, because yours depends on where you live, the
> building, how much coverage you pick and your deductible. So get one real quote. Ask what it pays for your things
> and how much liability coverage comes with it. Then divide. If your stuff adds up to 6,400 dollars and your quote
> came back at, say, 200 dollars a year, one covered loss pays for 32 years of premiums. You don't need disasters
> to be common for that trade to make sense. You only need one.

Replace *"because a serious dog-bite claim can run tens of thousands of dollars"* with *"because a serious dog-bite
claim can get expensive fast"*.

Replace *"Bundle it. If you already carry car insurance, adding a renters policy with the same company often knocks
10 to 15 percent off both."* with:

> Bundle it. If you already carry car insurance, ask what adding renters with the same company does to both bills.
> There's often a discount. Ask for the actual number.

Replace *"Replacement cost usually costs a couple dollars more a month and is almost always worth it."* with
*"Replacement cost usually costs a bit more. Ask for both prices and look at the difference in dollars."*

Replace *"Most renters land between 15,000 and 30,000 dollars once they honestly count. Set 180 dollars a year next
to that number, and the gap is your answer."* with *"Most people are surprised how high it goes once they honestly
count. Set your quote next to that number, and the gap is your answer."*

Bottom line, replace *"For roughly 15 dollars a month you protect thousands of dollars of belongings..."* with:

> **Bottom line:** For one small, predictable bill you protect thousands of dollars of belongings and guard against
> the kind of liability claim that could drain your savings. Get a quote and do the math with your own numbers.

### `/homeowners-insurance/`

Replace *"A typical policy might run $1,800 a year, or $150 a month, often folded into your escrow. If a kitchen
fire..."* with:

> Your premium is often folded into your mortgage payment through escrow, so it's easy to forget you're paying it.
> Here's a made-up example of what it does for you. If a kitchen fire causes $60,000 in damage and your deductible
> is $2,000, you pay the $2,000 and the insurer covers the other $58,000.

### `/umbrella-insurance/`

Replace *"A $1 million umbrella policy, which often runs $150 to $300 a year, would cover that gap and keep the money
out of your pocket."* with:

> A $1 million umbrella policy would cover that gap. What it costs depends on you and your insurer, so ask for a
> quote the next time you review your auto and home policies.

### `/insurance-premium/` and `/insurance-deductible/`

In both, replace *"Here is a real-dollar example."* with *"Here's a made-up example to show the math."* The figures
are invented, and "real-dollar" says otherwise.

### `/how-to-build-an-emergency-fund/`

Replace the paragraph starting *"Think about the real emergencies that hit most households."* with:

> Think about the surprises that actually show up. A car repair. A vet visit. A cracked tooth. Every year the
> Federal Reserve asks adults how they'd handle a $400 surprise, and in its report on 2025, 37 percent said they
> couldn't cover it all with cash or something just as good. A grand won't cover every disaster. But it covers a
> lot of the everyday ones, the kind that usually land on a credit card and sit there collecting interest.

(The 37 percent is the same Federal Reserve figure the new lesson uses; link it the same way, to
`federalreserve.gov/publications/2026-economic-well-being-of-us-households-in-2025-savings-investments.htm`.)

In "Why $1,000 First", replace *"A thousand dollars covers the vast majority of everyday emergencies"* with *"A
thousand dollars handles a lot of everyday emergencies"*.

Replace *"A high-yield savings account at an online bank works well. As of 2025, many online banks pay somewhere
around 4 percent, which means your $1,000 earns roughly $40 a year while it waits. Not life-changing, but better than
the near-zero most big banks pay."* with:

> A savings account at a federally insured bank or credit union works well. Some pay a lot more interest than
> others, so compare before you pick one. Just don't let the rate become the point. This money's job is to be
> there, not to grow.

Replace *"Sell what you are not using. The average household is sitting on hundreds of dollars in stuff. A few hours
listing an old phone, a bike, and a bin of clutter on Facebook Marketplace can bring in $200 to $400."* with:

> Sell what you're not using. Most of us have stuff sitting around we don't touch. An old phone, a bike, a bin of
> clutter. A few hours listing it on Facebook Marketplace turns it into cash.

Replace *"Pause the subscriptions. Most people carry four or five they forgot about. Cutting $60 a month in
streaming, apps, and box services adds up to real money over two months."* with:

> Pause the subscriptions. Go through last month's card statement and find the ones you forgot about. Every one you
> cancel puts money back in the fund, every month.

Replace *"Ten hours of delivery driving or a weekend of odd jobs at $18 an hour is $180."* with *"Say you pick up
ten hours of delivery driving or odd jobs at $18 an hour. That's a made-up rate, so use yours. That's $180."*

Add at the end, before the disclaimer:

> Once you've hit $1,000, the next question is how big the whole fund should be. [Here's how much should be in an
> emergency fund](/how-much-emergency-fund/).

### `/emergency-fund-calculator/`

Replace *"a single surprise sends you straight to a credit card at 20 plus percent"* with *"a single surprise sends
you straight to a credit card at a high interest rate"*.

### `/how-much-should-i-have-in-savings-by-age/`

Replace *"Roughly half of Americans say they could not cover a surprise $1,000 expense from savings."* with:

> In the Federal Reserve's report on 2025, 55 percent of adults said they had three months of expenses set aside.
> So if you've got even one month, you're on your way, and you're in good company if you're still building it.

(and drop the following sentence, *"So if you have even one month of expenses set aside, you are already ahead of a
lot of folks."*, which the replacement covers.)

Replace *"Say you put away $300 a month starting at 25 and earn a 7 percent average return."* with:

> Say you put away $300 a month starting at 25. To keep the math simple, we'll use a made-up 7 percent a year.
> That's an example rate, not a promise, and it ignores fees and inflation.

### `/how-to-save-on-car-insurance/`

Replace *"People who switch commonly save a few hundred dollars a year, and swings of $300 to $600 are not rare."*
with *"Rates for the same driver and the same coverage can be surprisingly far apart, and you only find out by
asking."*

Replace *"Going from a $500 to a $1,000 deductible often trims 10 to 20 percent off your collision and comprehensive
premium."* with *"Ask your agent what going from a $500 to a $1,000 deductible does to your collision and
comprehensive premium. Get the number in dollars."*

In the discount list, replace the percentage clauses: *"commonly saves 10 to 25 percent on the pair"* with *"often
comes with a discount on both"*; *"can save 10 to 40 percent if you drive gently"* with *"can lower your rate if you
drive gently"*; *"often 5 to 10 percent for a course that costs $20 to $30 online"* with *"for a short course. Ask
what it saves before you pay for one"*; and *"drive under about 7,500 miles a year"* with *"don't drive much"*.

Bottom line, replace *"Do those three and most drivers cut $300 to $600 a year while keeping..."* with *"Do those
three and you'll often pay less while keeping..."*.

### `/how-to-track-your-net-worth/`

Replace the whole section "Track It on the Same Day Every Month" with:

> **Write It Down Once a Year**
>
> A net worth you figure out once and forget is a photograph. What you want is a photo album. The trend is where
> the truth lives.
>
> Pick one date a year and make it your net worth day. A birthday works. So does the first week of January. Open the
> same page or spreadsheet, update every balance, and write the new number next to last year's. Once your list is
> built, it's a quick job.
>
> Why not every month? Because net worth moves slowly, and some months it dips for reasons that don't mean much, like
> a car repair or a rough week in the market. Checking it all the time turns a planning tool into a worry machine.
> Once a year gives the small, boring, good choices time to show up. Going from negative $13,000 to negative $9,000
> is a $4,000 win, even though the number is still red.

Replace *"measure your progress against last month, not against anyone else"* with *"measure your progress against
last year, not against anyone else"*, and in the bottom line replace *"Check it the same day every month"* with
*"Check it the same day every year"*. Add at the end:

> Want to do this with your teen? [Here's the one-page version, with a worksheet for each of you](/personal-balance-sheet/).

### `/net-worth-calculator/`

Replace *"Check this number every few months."* with *"Come back once a year, same date, and compare."*

### `/net-worth/`

Replace *"Track it once or twice a year"* with *"Track it once a year"*.

### `/good-net-worth-by-age/`: retire, with a redirect

No sentence fixes. Add one line to `grocery\redirects-base.yaml` under `301:`

    ^/good-net-worth-by-age/?$: /net-worth-by-age/

then rebuild and upload the redirects file the way that file's header says (Ghost Admin, Settings, Advanced,
Redirects; the upload replaces the whole set, so it must be the complete file), unpublish the post, and remove it
from the Money Hacks hub. The salary multiples it carries are also on `/how-much-should-i-have-in-savings-by-age/`,
where Fidelity is named, so nothing is lost.

## Link lines for the old pages (once each new lesson is live)

One line each, in the italic note style, added at the end of the body before the disclaimer:

- `/emergency-fund/`: *How much should yours be? [Here's the honest range, and why it depends on your paycheck](/how-much-emergency-fund/).*
- `/insurance-premium/`, `/insurance-deductible/`, `/liability-coverage/`: *Want the whole picture, with your teen? [Here's what you're really buying when you buy insurance](/insurance-basics/).*
- `/net-worth/`: *Ready to find yours? [Here's the one-page worksheet](/personal-balance-sheet/).*
- `/how-to-build-an-emergency-fund/` and `/how-to-track-your-net-worth/`: in their fixes above.

Links from a public page to a paid lesson are fine; a non-member lands on the lesson's paywall with its excerpt.

## How this was measured

- **Pages:** every published post and page in Ghost, read on 2026-09-19 with paged Admin API GETs (`formats=html`),
  1,065 posts and 19 pages, 1,084 in all, matching the I167 census count. The set was chosen by the words insurance,
  emergency, rainy, net worth, balance sheet, deductible, premium, renter, umbrella, coinsurance, liability, copay,
  out-of-pocket, annuity and disability in the slug or title (25 hits), plus pages whose body mentions the topics
  four or more times (5 more). Left out as not overlapping: `/annuity/`, `/fdic-insurance/`, `/pmi/`,
  `/title-insurance/`, `/llc/`, `/how-to-make-a-financial-plan/`, `/high-yield-savings-vs-cd/`,
  `/high-yield-savings-account/`, `/how-to-prepare-for-a-baby-financially/`. All 22 were read live from Ghost;
  the I167 export in `content\ghost-adopted\` holds 8 of them.
- **Word count:** whitespace-separated tokens of the rendered body text, including the disclaimer and membership
  line.
- **Inbound links:** a page counts as linking when another page's body HTML contains the slug as a whole token.
- **Voice:** contractions per 100 words, against the seven live weeks the drafts were modelled on (Weeks 9, 10, 29,
  35, 37, 38, 42). A crude shape check, not a verdict.
- **Search:** Search Console `searchAnalytics` by page, 2026-06-19 to 2026-09-16 (90 days ending three days back for
  Google's lag), property `https://www.thriftycrew.com/`, read-only scope, through `ops\seo_search_console.py`'s
  token and query functions. 256 page rows came back.
- The scripts were one-off scratch reads and are not committed. The repo was at `23ef8f58a` when the worktree was cut.
