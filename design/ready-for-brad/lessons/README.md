# Three lesson drafts for Brad's approval (backlog I108, I109, I111)

Ruled by Brad in chat on 2026-09-19: draft three new normal-titled lessons outside the closed Week 1-52
series. **Nothing here is published.** No Ghost call of any kind was made to prepare them (only public
read-only page loads, to check slugs and links). Each lesson is here twice: the `.md` source in the
`lesson` skill's skeleton, and the `.html` body `publish-lesson.ps1` takes (generated from the `.md`).

| Backlog | Display title | Slug | Hub | Visibility |
|---|---|---|---|---|
| I109 | The Money That Sits There on Purpose | `how-much-emergency-fund` | `saving-and-banking` | paid (skill default) |
| I108 | What You're Really Buying When You Buy Insurance | `insurance-basics` | `saving-and-banking` (see note) | paid (skill default) |
| I111 | The One Page That Shows Where You Really Stand | `personal-balance-sheet` | `money-mindset-and-habits` | paid (skill default) |

Paywall: a lesson is gated whole-post by `-Visibility paid`, and the script writes the paywall JSON-LD
itself. There is no in-body paywall marker for lessons (the `<!--TC-PAYWALL-->` split is the recipe
convention, not the lesson one). Say if any of the three should be free (`-Visibility public` and a
`free-` slug prefix, per the skill).

## Every number in the drafts, and where it comes from

- **Emergency fund:** 63 percent of adults would cover a $400 surprise entirely with cash or its equivalent
  (the Fed counts a credit card paid off at the next statement as equivalent), and 55 percent have three
  months of expenses set aside. Federal Reserve, *Economic Well-Being of U.S. Households in 2025*, published
  May 2026, Savings and Investments section. The "37 percent" is 100 minus 63.
- **Emergency fund range:** three to six months, six to twelve on a single income, stated as the range
  planners quote with how replaceable the income is as the driver, exactly as ruled. No single number.
- **Insurance:** definitions of liability, collision, comprehensive; what renter's covers (personal
  property, liability, and on some policies additional living expenses) versus the landlord's (the
  building's structure); actual cash value versus replacement cost; term versus permanent. All from NAIC
  consumer pages, each linked in the text. **No price for any policy appears**, including life insurance:
  the course's $20-a-month figure is not used anywhere.
- **Every dollar figure in the three worked examples is made up and labelled as an example in the
  sentence that introduces it** (the $500 deductible, the $3,200-a-month household, the new graduate at
  minus $8,000, which is the course's example figure rebuilt from stated made-up line items).
- **No rate of return appears in any draft.** `ops\audit-lesson-rate-claims.ps1` over the three drafts
  (pointed at a temp copy with a zero baseline): 3 files, 112 paragraphs, 0 rate-of-return claims,
  0 findings, exit 0. That detector is unsound, so its zero means it found none of the spellings it knows;
  the drafts were also written to carry no return rate at all.
- Em dashes: 0 in all six files. Non-ASCII characters: 0.

## The three cross-link lines (DRAFTS, not applied to any published page)

Each is one line, set in the italic note style the published lessons already use.

**Week 29, The Custodial Account Conversation** (`content\lessons\lesson-29-the-custodial-account-conversation.md`),
placed directly under the existing "Quick note: Nothing in this lesson is financial advice" block:

    *Before you open this account: if your household doesn't have an emergency fund yet, start with [how much should be in an emergency fund](/how-much-emergency-fund/). The buffer comes first, so the investments never have to be sold in a hurry.*

**Week 30, Boring Wins: Index Funds 101** (`content\lessons\lesson-30-boring-wins-index-funds-101.md`),
placed directly under its "Nothing here is financial advice" block:

    *One step before index funds: money you might need in the next few months belongs in an emergency fund, not the market. [Here's how big yours should be](/how-much-emergency-fund/).*

**Net Worth by Age** (`content\lessons\net-worth-by-age.md`), appended to step 1 of its "Try this together"
("Figure out your real number..."):

    Want a worksheet for it? [Here's how to build your personal balance sheet](/personal-balance-sheet/), step by step, with a version to do alongside a teen.

Week 29 and 30 are published paid lessons. Applying a line means editing the `.md`, then republishing
that week with the skill's legacy form (`-WeekNumber 29` / `-WeekNumber 30`, keeping its `Week N` title)
so its archive slot does not move. Week 30 quotes a historical return rate that
`audit-lesson-rate-claims` lists as unqualified, and Brad's I112 ruling says a lesson that quotes a rate is
checked "the next time they are edited", so **adding this line to Week 30 obliges fixing that rate in the
same edit.** The net-worth page is a standalone lesson and republishes with its own slug.

## Publish steps (Brad, in this order)

Order matters: the insurance lesson links to the emergency-fund lesson, and both cross-link lines point at
new slugs, so a link published before its target is a 404.

**0. Check each slug is free.** `publish-lesson.ps1` UPSERTS BY SLUG, so a slug a live post already holds
would overwrite that post. On 2026-09-19 all three returned 404 on www.thriftycrew.com (and `emergency-fund`,
the obvious slug, is a live Glossary post, which is why it was not used). Ghost drafts are not visible
publicly, so glance at Ghost admin for a draft with the same slug too.

**1. Publish the three lessons** (from the main checkout, after this commit is on main):

    powershell -ExecutionPolicy Bypass -File ".claude\skills\lesson\publish-lesson.ps1" -Title "The Money That Sits There on Purpose" -Slug "how-much-emergency-fund" -HtmlFile "design\ready-for-brad\lessons\how-much-emergency-fund.html" -Excerpt "The honest answer to how much emergency money you need, why it comes before investing, and a worked example you can copy with your own numbers." -MetaTitle "How Much Should Be in an Emergency Fund? | Thrifty Crew" -MetaDesc "How much should be in an emergency fund? The honest range, why it depends on how replaceable your income is, and why the buffer comes before investing."

    powershell -ExecutionPolicy Bypass -File ".claude\skills\lesson\publish-lesson.ps1" -Title "What You're Really Buying When You Buy Insurance" -Slug "insurance-basics" -HtmlFile "design\ready-for-brad\lessons\insurance-basics.html" -Excerpt "Policy, premium, deductible: the three words behind every insurance bill, and the coverage to buy first, whether it is for you or a new driver in the house." -MetaTitle "Insurance Basics: Premium, Deductible, Policy | Thrifty Crew" -MetaDesc "Insurance basics in plain English: policy, premium and deductible, what renters insurance covers that your landlord's does not, and term vs permanent life."

    powershell -ExecutionPolicy Bypass -File ".claude\skills\lesson\publish-lesson.ps1" -Title "The One Page That Shows Where You Really Stand" -Slug "personal-balance-sheet" -HtmlFile "design\ready-for-brad\lessons\personal-balance-sheet.html" -Excerpt "One page, once a year: what you own minus what you owe. A worksheet to do with a teen, and why a negative number in your twenties is a starting line." -MetaTitle "Personal Balance Sheet: Find Your Net Worth | Thrifty Crew" -MetaDesc "A personal balance sheet is what you own minus what you owe. Calculate your net worth once a year with our parent-and-teen worksheet. Negative early on is normal."

Add `-Draft` to any of them to stage it in Ghost for a look first. None of them emails members.

**2. Add to the topic hubs.** In `.claude\skills\lesson\build-hubs.ps1`, append `'how-much-emergency-fund'` and
`'insurance-basics'` to the `saving-and-banking` hub's `lessons` array and `'personal-balance-sheet'` to
`money-mindset-and-habits`, then run it. None of the six hubs is about protection, so `saving-and-banking` is
the nearest fit for insurance (it protects what you saved); a seventh hub is the alternative and is your call.

**3. Move the sources into the published set.** Copy each `.md` to `content\lessons\<slug>.md` (where the
published standalone lessons live, so `audit-lesson-rate-claims` covers them from then on), and delete this
folder once all three are live.

**4. Cross-links, if you approve them:** apply the three lines above and republish those pages.

**5. Verify live** per the skill's Step 5 (disclaimer banner, Keep going block, breadcrumb and paywall
JSON-LD, tab title = MetaTitle, top of `/financial-lessons/`), plus the 375px mobile check on the
balance-sheet worksheet, the one layout here that is not plain paragraphs.

## What the site already has on these topics (found while drafting, worth knowing before you publish)

The backlog items measured the 52 lessons only. The live sitemap (1,098 URLs on 2026-09-19) also carries
Glossary and Money Hacks pages on all three topics: `/emergency-fund/`, `/how-to-build-an-emergency-fund/`,
`/emergency-fund-calculator/`, `/insurance-premium/`, `/insurance-deductible/`, `/is-renters-insurance-worth-it/`,
`/life-insurance/`, `/net-worth/`, `/how-to-track-your-net-worth/`, `/net-worth-calculator/`. Their source is
not in this repo. So these lessons are not the site's first word on the topics; they are the first in the
lesson series. The slugs were chosen not to collide (`how-much-emergency-fund` is the "how much" question,
`personal-balance-sheet` rather than a second "track your net worth"), but some search overlap is likely.

**Two of those live pages publish what your I108 ruling keeps out of the lesson.** `/life-insurance/` states
that a healthy 35-year-old "can often buy a 20-year, $500,000 term policy for around $25 to $35 a month", with
no source. `/is-renters-insurance-worth-it/` states "about 15 dollars a month", with no source, and
`/how-to-build-an-emergency-fund/` states an online-bank savings rate "as of 2025" and a set of repair costs, with
no source. The drafts deliberately do not link to those pages. That is a separate question for you.
