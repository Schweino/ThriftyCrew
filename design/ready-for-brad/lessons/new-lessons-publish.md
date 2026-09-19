# Publishing the three new lessons

## Where this stands: APPLIED (2026-09-19)

All three lessons are live and the ten cross-link PUTs are applied. They were sent from the main checkout with
`ops\review-staged.ps1 -Apply` at the orchestrator's hand on Brad's "Publish all three" in chat, 07:18 US Central.
Everything below the APPLIED record is the plan as it was staged, kept as the record of what was approved.

**Two id spaces, and only one of them undoes a PUT.** Each call carries a STAGED id (its line in the queue file)
and a separate WRITE-JOURNAL id (its entry in `ops\ghost-journal.jsonl`, holding the before-copy).
`ops\revert-ghost-write.ps1` takes the journal id. The journal ids below were matched to the staged calls by method,
uri and request byte length (13 of 13 matched, each exactly once), and they are the last 13 entries written after
the I143 batch-2 publish.

### Queue 1, the three POSTs: APPLIED 07:18:22 to 07:18:24

**A journal id does NOT undo a POST.** The journal read the collection (`/posts/`) before each create and recorded
that list as its before-copy; it never learns the new post's id. So the new ids below come from a read-only GET by
slug. To undo one of these lessons, set it to draft or delete it in Ghost Admin (Posts, the lesson, Settings): that
is Brad's call, and `revert-ghost-write.ps1` must not be pointed at these three journal ids.

| Lesson | Staged id | Journal id (not an undo) | New post id | created and published_at |
|---|---|---|---|---|
| `/how-much-emergency-fund/` | `c589a2ce1031` | `bb48e74dcc65` | `6aae7d8da443720001d0242e` | 2026-09-19T12:18:21.000Z |
| `/insurance-basics/` | `7cd3ae161fa6` | `98f2aa18b54d` | `6aae7d8ea443720001d02434` | 2026-09-19T12:18:22.000Z |
| `/personal-balance-sheet/` | `609c8bc1cdfa` | `4dddd26544a8` | `6aae7d8fa443720001d0243a` | 2026-09-19T12:18:23.000Z |

Read back by GET (`include=tags,authors,newsletter,email`): all three `published` and `paid`, tags exactly
`financial-lessons` (id `6a43b3cd5e9f16000182e8b5`, the tag itself public), primary tag the same, author exactly
`brad` (id `6a436289e02523000897527f`), no newsletter and no email on any of them, so nothing was mailed. The same
GET of the live lessons `save-money-on-vacation` and `net-worth-by-age` returns the same one tag and the same author.
Each post's paywall JSON-LD names its own `https://www.thriftycrew.com/<slug>/` (the other 52 lessons with one still
name `simplemoneyplaybook.com`: backlog I272). The orchestrator's checks at apply time: logged out, each shows the
paid box and 0 of 7 sampled body sentences; the admin copy holds all 7; the FAQ html card survived.

**A later edit to `/insurance-basics/`, APPLIED 08:02:59 (journal id `4993b9062ebc`, a PUT, so this one does undo).**
On Brad's go-ahead the orchestrator added the two links held back from the lesson as drafted (see "Not staged, a
decision for Brad" below): "Term life", the bold lead-in of the life section, now links to `/term-vs-whole-life/`,
and a new line closes the renter's section, *"Wondering if it's worth the money? Here's the math."*, with "Here's
the math" linking to `/is-renters-insurance-worth-it/`. Removing just those two edits gives back the prior lexical
exactly, the read-back lexical equals what was sent, the post is still published and paid, both link targets
answer 200, and logged out the page still shows the paid box and not the new line.

### Queue 2, the three lesson link lines: APPLIED 07:18:50 to 07:18:51

| Page | Staged id | Journal id | updated_at now | Status, visibility |
|---|---|---|---|---|
| Week 29, The Custodial Account Conversation | `40d5f2c275f2` | `4f0257828b1e` | 2026-09-19T12:18:49.000Z | published, paid |
| Week 30, Boring Wins: Index Funds 101 | `1331a6a32726` | `7c84d6691b74` | 2026-09-19T12:18:49.000Z | published, paid |
| Net Worth by Age | `d79b03e3a6ce` | `aa69c6bee292` | 2026-09-19T12:18:50.000Z | published, public |

### Queue 3, the seven older pages: APPLIED 07:18:52 to 07:18:55

| Page | Staged id | Journal id | updated_at now | Status, visibility |
|---|---|---|---|---|
| `/emergency-fund/` | `2b96e009bed1` | `5dc53d4a6834` | 2026-09-19T12:18:50.000Z | published, public |
| `/insurance-premium/` | `11e7dcf9e38a` | `5ae475ffac5b` | 2026-09-19T12:18:51.000Z | published, public |
| `/insurance-deductible/` | `0fe6e779b654` | `0f27eadbe155` | 2026-09-19T12:18:51.000Z | published, public |
| `/liability-coverage/` | `4737e830e9df` | `fa5741866d54` | 2026-09-19T12:18:52.000Z | published, public |
| `/net-worth/` | `2fe9f41bf4ee` | `3a610a989ec7` | 2026-09-19T12:18:52.000Z | published, public |
| `/how-to-build-an-emergency-fund/` | `c9ffa50d93c3` | `d7018545f0ff` | 2026-09-19T12:18:53.000Z | published, public |
| `/how-to-track-your-net-worth/` | `9631dee15cfa` | `f7d751b7892e` | 2026-09-19T12:18:53.000Z | published, public |

The orchestrator read all ten PUTs back with lexical equal to what was sent; the `updated_at` and status columns
above are a later read-only GET, and each page's `updated_at` is still the one its PUT set.

### The census export

`ops\audit-ghost-page-census.ps1 -Export` refreshed `content\ghost-adopted\` afterwards: 196 of 196 declared pages
read, 33 files changed. Four of them are the two declared pages queue 3 moved (`liability-coverage` and
`how-to-track-your-net-worth`, `.html` and `.json` each). The other 29 files are 24 declared pages edited live by
other work since the last export (the meta description on all 24, the excerpt on 3, the body on 5), which the
export now matches.
The census then read 1,086 live web pages (1,083 at the last run, plus these three lessons), 890 named by a tracked
file, 196 declared, 0 findings, exit 0. The three lessons need no declaration: their slugs are named in tracked files
(the drafts in this folder and `.claude\skills\lesson\build-hubs.ps1`), and lessons are not in
`ops\ghost-page-estate.json`.

### The lesson hubs: STAGED, NOT SENT (`staged\lesson-hubs.jsonl`)

**`build-hubs.ps1` must not be run as it stands.** Built offline (a scratch copy with its one write cut out) and
compared with the six live hub pages, its output differs from every one of them beyond the new lessons: it would put
`&mdash;` back into each hub's lead line and the membership box (the live hubs read "Pay yourself first. Then make it
automatic." and "All 52 weeks and every recipe. And it pays for itself"), turn every absolute
`https://www.thriftycrew.com/` link into a relative one, and change each "Week 9. Pay Yourself First" to "Week 9: Pay
Yourself First". The live hubs were last edited on 2026-07-03 and the script never caught up. Titles, meta, OG and
Twitter fields match the script exactly on all six.

So the hub update is staged as a splice instead: two body-only PUTs (`updated_at` and `lexical`), each the LIVE
lexical string with the new list items inserted before its one `</ul>`, in the live page's own convention (absolute
URL, the post's title as Ghost holds it, no "free" badge because all three are paid). Cutting the inserted text back
out gives the live lexical byte for byte, and the parsed html equals the live html with only those items added
(both checked in the staging script). `review-staged` lists 2 calls, 0 concerns, exit 0.

| Hub page (id) | updated_at read at staging | Adds | Staged id | New html sha256 (first 16) |
|---|---|---|---|---|
| `/saving-and-banking/` (`6a44cd01cc3094000187b7ad`) | 2026-07-03T10:53:40.000Z | The Money That Sits There on Purpose; What You're Really Buying When You Buy Insurance | `22c59a96bcd2` | `2fad35442f679299` |
| `/money-mindset-and-habits/` (`6a44cd00cc3094000187b7a3`) | 2026-07-03T10:53:40.000Z | The One Page That Shows Where You Really Stand | `a7d3d8eeb4ac` | `2d85c25972adb6bf` |

Apply from the main checkout, copying the queue first because `-Apply` deletes what it sends:

    Copy-Item design\ready-for-brad\lessons\staged\lesson-hubs.jsonl $env:TEMP\lesson-hubs.jsonl
    powershell -NoProfile -File ops\review-staged.ps1 -Queue $env:TEMP\lesson-hubs.jsonl -Apply

A page edited since staging answers 409 and nothing stale lands. The hub titles in the list are the post titles, so
if a lesson title changes, re-stage. Neither hub page is declared in the census estate.

**Hub update APPLIED 2026-09-19.** The queue as staged was refused: `review-staged -Apply` sent both PUTs and Ghost
answered `(400) Bad Request` to each, `sent=0 failed=2`, and neither page changed. The staged lines carried no
`Content-Type` header (every queue that applied cleanly that day carried `application/json`). The same bodies were
resent through `Invoke-GhostApi` with `Content-Type: application/json` added: journal `4b6506c3602f`
(saving-and-banking) and `349fc7d8459f` (money-mindset-and-habits). Both read back with html identical to what
was sent, both still published, and the live pages link the emergency-fund and insurance lessons (saving and
banking) and the balance-sheet lesson (money mindset). The missing-header defect is filed through the backlog inbox.

## As staged (the approved plan)

Brad ruled on 2026-09-19, "Publish all three": the drafts in this folder for backlog I108, I109 and I111, with
their cross-links from existing lessons. **Nothing had been sent to Ghost when this was written.** Every live read was a GET (write
journal cleared in that process); every write is queued in the estate's staging format (`lib\ghost-lib.ps1`
`TC_STAGE_WRITES`) and waits for `ops\review-staged.ps1 -Apply`.

| Queue | Calls | What | Apply |
|---|---|---|---|
| `staged\new-lessons.jsonl` | 3 POST | the three new paid lessons | FIRST |
| `staged\new-lessons-links.jsonl` | 3 PUT | one link line each on Week 29, Week 30 and Net Worth by Age | only after all three posts answer 200 |
| `staged\new-lessons-oldpage-links.jsonl` | 7 PUT | the link lines `overlap-review.md` approved and held "once each new lesson is live" | after the posts, any time |

`review-staged` (no `-Apply`) lists each queue with **0 concerns, exit 0** (3, 3 and 7 calls). That needs this
commit's `lib\ghost-lib.ps1`: until now three POSTs to `/posts/` read as "3 calls target the same uri", because
the duplicate check keyed a POST on its uri alone. A POST now keys on uri plus body, so the same create queued
twice still fires (fixtures in `ops\review-staged.ps1 -SelfTest`).

## The three posts

Built field for field as `.claude\skills\lesson\publish-lesson.ps1` builds a lesson and as the live standalone
lessons carry it (read by GET: `save-money-on-vacation`, `net-worth-by-age`, Weeks 29, 30 and 42): tag
`financial-lessons` only (id `6a43b3cd5e9f16000182e8b5`), author Brad (`6a436289e02523000897527f`), status
`published`, visibility `paid`, no feature image and no og_image (the standalone lessons have none; the theme
default applies), meta, OG and Twitter title and description all set, the paywall JSON-LD in
`codeinjection_head`, `?source=html`, and **no `newsletter` parameter, so no email goes to anyone**. Ghost
stamps `published_at` at the moment of the POST, so each lands at the top of `/financial-lessons/`.

| | I109 | I108 | I111 |
|---|---|---|---|
| Title | The Money That Sits There on Purpose | What You're Really Buying When You Buy Insurance | The One Page That Shows Where You Really Stand |
| Slug and URL | `how-much-emergency-fund`, https://www.thriftycrew.com/how-much-emergency-fund/ | `insurance-basics`, https://www.thriftycrew.com/insurance-basics/ | `personal-balance-sheet`, https://www.thriftycrew.com/personal-balance-sheet/ |
| Tags | financial-lessons | financial-lessons | financial-lessons |
| Visibility | paid | paid | paid |
| Excerpt | The honest answer to how much emergency money you need, why it comes before investing, and a worked example you can copy with your own numbers. | Policy, premium, deductible: the three words behind every insurance bill, and the coverage to buy first, whether it is for you or a new driver in the house. | One page, once a year: what you own minus what you owe. A worksheet to do with a teen, and why a negative number in your twenties is a starting line. |
| Meta title (also OG, Twitter) | How Much Should Be in an Emergency Fund? \| Thrifty Crew | Insurance Basics: Premium, Deductible, Policy \| Thrifty Crew | Personal Balance Sheet: Find Your Net Worth \| Thrifty Crew |
| Meta description (also OG, Twitter) | How much should be in an emergency fund? The honest range, why it depends on how replaceable your income is, and why the buffer comes before investing. | Insurance basics in plain English: policy, premium and deductible, what renters insurance covers that your landlord's does not, and term vs permanent life. | A personal balance sheet is what you own minus what you owe. Calculate your net worth once a year with our parent-and-teen worksheet. Negative early on is normal. |
| Staged id | `c589a2ce1031` | `7cd3ae161fa6` | `609c8bc1cdfa` |

The titles, excerpts and meta are the README's publish commands, character for character. The queue order
matters: the insurance lesson links to `/how-much-emergency-fund/`, so the emergency-fund POST is first.

**The paywall split point: there is none in the body, by design.** A lesson is gated whole-post by
`visibility: paid`; the `<!--TC-PAYWALL-->` split is the recipe convention and no lesson carries it. Read live on
2026-09-19, a logged-out load of the paid `save-money-on-vacation` serves `gh-content` holding ONLY Ghost's
"This post is for paying subscribers only" box and none of the body. That is the state each new post must match.
The JSON-LD says the same thing to search engines (`isAccessibleForFree: false` on `.gh-content`).

**What was changed from the drafts, all mechanical, none of it prose:**

1. **Internal links made absolute** on `https://www.thriftycrew.com/`, as every internal link in the live lessons
   is (3 of 3 found in the five posts read). The drafts wrote `/slug/`.
2. **The FAQ block wrapped in Ghost's own html-card markers** (`<!--kg-card-begin: html-->` and
   `<!--kg-card-end: html-->`, the markers Ghost itself writes around every html card). `?source=html` converts
   the body to native paragraphs, and a bare `<div class="mts-faq">` would lose its class, which is what the
   global injection reads to build the FAQ structured data. **This is the one thing here not proven before
   sending**: no live lesson carries an FAQ, and Ghost's converter is not available on this box. The checklist
   below checks it, and if the FAQ came through flattened, the fix is one PUT of that post's lexical.
3. **The JSON-LD `mainEntityOfPage` is the real URL** (`https://www.thriftycrew.com/<slug>/`). `publish-lesson.ps1`
   would have written the ghost.io host, and the live lessons carry the retired `simplemoneyplaybook.com` domain
   (see Findings).

Checked on the bodies as sent: 0 em or en dashes and 0 non-ASCII characters in any body, title, excerpt or meta
field; each HTML body's word sequence is identical to its `.md` source (1,387, 1,568 and 1,298 words);
`ops\audit-lesson-rate-claims.ps1` over the three `.md` files (a temp tree, baseline 0): 3 files, 120 paragraphs,
0 rate-of-return claims, 0 findings, exit 0. The detector is unsound, so that zero means none of the spellings it
knows; the drafts carry no return rate at all. The I111 worksheet is part of the lesson body (the "Try This
Together" section, plain HTML lists), not a file, so **nothing needs an upload** and the content-workbook rule
does not reach it.

## The cross-links

### Queue 2, from existing lessons (`new-lessons-links.jsonl`)

These three posts are native lexical, not an html card, so each PUT carries only `updated_at` and `lexical`, and
the new lexical is the live string with the new nodes spliced in: cutting them back out gives the live lexical
byte for byte (checked in the staging script). Ghost regenerates the html. Every other field is untouched.

| Page (id, updated_at read) | Next to this existing sentence | New sentence (link text in brackets, italic like the note above it where marked) | Staged id |
|---|---|---|---|
| Week 29, The Custodial Account Conversation, paid (`6a43b4155e9f16000182e973`, 2026-07-03T11:28:14.000Z) | *"Quick note: nothing in this lesson is financial advice. ... Talk to a financial professional before you make investing decisions."* The new italic paragraph goes directly under it, inside the same two horizontal rules. | *Before you open this account: if your household doesn't have an emergency fund yet, start with [how much should be in an emergency fund]. The buffer comes first, so the investments never have to be sold in a hurry.* | `40d5f2c275f2` |
| Week 30, Boring Wins: Index Funds 101, paid (`6a43b4155e9f16000182e978`, 2026-09-19T08:57:44.000Z) | *"Nothing here is financial advice. ... talk to a qualified financial professional."* The new italic paragraph goes directly under it, inside the two rules. | *One step before index funds: money you might need in the next few months belongs in an emergency fund, not the market. [Here's how big yours should be].* | `1331a6a32726` |
| Net Worth by Age, public (`6a47a06850682b0001cd3d3d`, 2026-07-03T11:43:36.000Z) | Step 1 under "Two quick moves": *"Figure out your real number. Add up what you own, subtract what you owe, and write it down. ... a goal you refuse to look at."* The sentence is appended to that same list item. | Want a worksheet for it? [Here's how to build your personal balance sheet], step by step, with a version to do alongside a teen. | `d79b03e3a6ce` |

Links: the Week 29 and Week 30 lines point at https://www.thriftycrew.com/how-much-emergency-fund/, the Net Worth
by Age line at https://www.thriftycrew.com/personal-balance-sheet/.

**Week 30 and the rate ruling.** The README said adding this line obliges fixing Week 30's rate under I112. That
is already done: I60 swapped in the sourced paragraph (Damodaran, 1928 through 2025, about 10% nominal and closer
to 7% after inflation, before fees) at 08:57 UTC today, which is the `updated_at` this PUT carries. This PUT does
not touch that paragraph. The repo file `content\lessons\lesson-30-...md` still holds the old text and is what
`audit-lesson-rate-claims` counts; bringing it up to the live text is I60's remaining step, not this one.

### Queue 3, the older public pages (`new-lessons-oldpage-links.jsonl`)

Approved in `overlap-review.md` ("Link lines for the old pages (once each new lesson is live)") and held until
now. Each page is ONE html card whose lexical re-wraps exactly with `Get-GhostLexical`, so each PUT carries
`updated_at` and `lexical` only, and the card is the live html with one paragraph inserted directly after its
"Bottom line" paragraph: the end of the body, before any disclaimer and the membership line. Outside the inserted
paragraph the card is byte-identical (checked).

| Page (id, updated_at read) | After this paragraph | New paragraph | Links to | Staged id | New card sha256 (first 16) |
|---|---|---|---|---|---|
| `/emergency-fund/` (`6a498b7050682b0001cd3dac`, 2026-07-04T22:38:40.000Z) | Bottom line: An emergency fund is your buffer ... | *How much should yours be? [Here's the honest range, and why it depends on your paycheck].* | how-much-emergency-fund | `2b96e009bed1` | `30f9688edb7d3fe3` |
| `/insurance-premium/` (`6a498d9b50682b0001cd3eb0`, 2026-09-19T09:59:02.000Z) | Bottom line: The premium is what you pay ... (the disclaimer is inside this paragraph) | *Want the whole picture, with your teen? [Here's what you're really buying when you buy insurance].* | insurance-basics | `11e7dcf9e38a` | `1de4ca327c06d843` |
| `/insurance-deductible/` (`6a498d9b50682b0001cd3eb6`, 2026-09-19T09:59:02.000Z) | Bottom line: Only choose a high deductible ... (disclaimer inside) | the same line as `/insurance-premium/` | insurance-basics | `0fe6e779b654` | `081c7d60eeb8996c` |
| `/liability-coverage/` (`6a49a89950682b0001cd46f8`, 2026-07-05T00:43:05.000Z) | Bottom line: Liability coverage pays ... | the same line as `/insurance-premium/` | insurance-basics | `4737e830e9df` | `740e075f7dd3c3ce` |
| `/net-worth/` (`6a498b7250682b0001cd3dbe`, 2026-09-19T09:59:06.000Z) | Bottom line: Net worth is the single number ... | *Ready to find yours? [Here's the one-page worksheet].* | personal-balance-sheet | `2fe9f41bf4ee` | `f5efea65054daa1e` |
| `/how-to-build-an-emergency-fund/` (`6a498da350682b0001cd3f22`, 2026-09-19T09:59:03.000Z) | Bottom line: A $1,000 emergency fund is small enough ... | Once you've hit $1,000, the next question is how big the whole fund should be. [Here's how much should be in an emergency fund]. | how-much-emergency-fund | `c9ffa50d93c3` | `fe9d288122473f29` |
| `/how-to-track-your-net-worth/` (`6a4994d850682b0001cd41bc`, 2026-09-19T09:59:05.000Z) | Bottom line: Add up what you own ... | Want to do this with your teen? [Here's the one-page version, with a worksheet for each of you]. | personal-balance-sheet | `9631dee15cfa` | `237851de1142e84f` |

All seven are public pages linking to a paid lesson, which is fine: a non-member lands on the lesson's excerpt and
the subscribe box. Two of the seven, `/liability-coverage/` and `/how-to-track-your-net-worth/`, are declared in
`ops\ghost-page-estate.json` with an export in `content\ghost-adopted\` (checked 2026-09-19; the other five and the
three lessons in queue 2 are not), so re-export afterwards (step 6 below) or the daily census reports
EDITED-SINCE-EXPORT for those two.

**Not staged, a decision for Brad:** `overlap-review.md` also drafted two links INSIDE the insurance lesson, held
"until their price sentences are fixed": the renter's section ending *"Wondering if it's worth the money? [Here's
the math](/is-renters-insurance-worth-it/)."* and "Term life" linking `/term-vs-whole-life/`. Those pages were
fixed today (body at 04:59, excerpt and meta at 05:33 US Central), so the condition is met, but adding them edits
the lesson Brad approved as drafted, so the lesson goes out without them. Say the word and they are one PUT.

## Apply, in this order (from the main checkout, once this commit is on main)

`-Apply` deletes the queue file it sends, so copy each queue first. `TC_WRITE_JOURNAL` is armed for every process
on this box, so each PUT's before-image lands in the journal.

    Copy-Item design\ready-for-brad\lessons\staged\new-lessons.jsonl $env:TEMP\new-lessons.jsonl
    powershell -NoProfile -File ops\review-staged.ps1 -Queue $env:TEMP\new-lessons.jsonl           # list: 3 calls, 0 concerns
    powershell -NoProfile -File ops\review-staged.ps1 -Queue $env:TEMP\new-lessons.jsonl -Apply    # send

**If a POST fails, do NOT re-run `-Apply` on the same file.** A POST is not idempotent: `Invoke-GhostApi` sends it
once and throws on a timeout or a 5xx because Ghost may already have created it, and a second POST of a slug that
exists makes `how-much-emergency-fund-2`. GET each slug first, delete the lines that landed from the copy, then
apply the rest. The write journal cannot undo a POST either (it records a GET of the collection, not the new id),
so the undo for a new lesson is a PUT to `status: draft` or a delete in Ghost Admin.

Then, only when all three new URLs answer 200 (check 1 below):

    Copy-Item design\ready-for-brad\lessons\staged\new-lessons-links.jsonl $env:TEMP\new-lessons-links.jsonl
    powershell -NoProfile -File ops\review-staged.ps1 -Queue $env:TEMP\new-lessons-links.jsonl -Apply
    Copy-Item design\ready-for-brad\lessons\staged\new-lessons-oldpage-links.jsonl $env:TEMP\new-lessons-oldpage-links.jsonl
    powershell -NoProfile -File ops\review-staged.ps1 -Queue $env:TEMP\new-lessons-oldpage-links.jsonl -Apply

Each PUT carries the `updated_at` read on 2026-09-19. If a page changed since, Ghost answers 409 for that one call
and nothing stale lands: re-run the staging read, never edit the timestamp by hand.

Then the hubs. This commit already adds `how-much-emergency-fund` and `insurance-basics` to the `saving-and-banking`
hub and `personal-balance-sheet` to `money-mindset-and-habits` in `.claude\skills\lesson\build-hubs.ps1` (a slug
not yet live is skipped with a MISSING line, so the edit is safe before the posts exist). It writes to Ghost
directly and is not staged, so run it by hand after the posts are live. **SUPERSEDED: do not run it.** Its output
would put em dashes back on all six live hubs; the hub update is staged as a splice instead (see the APPLIED record
at the top).

## Verification checklist (after applying)

1. **GET back each new post** (`/ghost/api/admin/posts/slug/<slug>/?formats=html,lexical&include=tags,authors,newsletter,email`):
   status `published`, visibility `paid`, tags exactly `financial-lessons`, author `brad`, title, excerpt, meta,
   OG and Twitter fields equal to the table above, `codeinjection_head` naming its own thriftycrew.com URL, and
   no `newsletter` and no `email` on the post (nothing was mailed). The lexical holds exactly one `html` node and it contains
   `mts-faq`; if instead the FAQ questions came through as plain paragraphs, PUT the lexical with that block as an
   html card. The html carries 0 em or en dashes, and a distinctive sentence from each section appears once
   (for example "Anybody who hands you one exact number for everybody is quoting a default.", "If the honest
   answer is $300, a $1,000 deductible isn't a savings.", "Negative at 22 isn't a verdict.").
2. **The paywall, in the direction that loses money.** Load each of the three URLs LOGGED OUT, with a
   cache-busting query (`?v=check1`), through a plain HTTP GET (not the admin API) and in a private browser window.
   `gh-content` must hold ONLY the "This post is for paying subscribers only" box, exactly like
   `save-money-on-vacation` does, and NONE of the body: search the page source for the three sentences above and
   for "Try This Together", "Worksheet: My Balance Sheet" and "Common questions". Any hit means paid content is
   served free: set the post to draft at once. Then do the same for Week 29 and Week 30 after queue 2 (still paid,
   still only the box), and confirm Net Worth by Age is still public and shows its whole body.
3. **Logged in as a paying member** (the cosmetic direction): the body renders, the disclaimer banner is at the
   top, the "Keep going" block and the "Put it into practice" card are at the end, the browser tab title is the
   meta title, the page `<head>` carries the breadcrumb and the paywall JSON-LD, the FAQ shows as a styled
   "Common questions" block, and each lesson is at the top of `/financial-lessons/?v=check`.
4. **375px.** Load each new lesson, Week 29, Week 30, Net Worth by Age and the seven older pages at 375px wide:
   `scrollWidth` 375, nothing crushed, and read the new sentence or link on the rendered page. The balance-sheet
   worksheet is the one layout here that is not plain paragraphs, so look at it and read it.
5. **The cross-links resolve.** Each new link on the ten edited pages answers 200 at its target (not 404, not a
   redirect), the Week 29 and 30 lines sit inside the two rules under their disclaimer, and on the seven older
   pages each card's html sha256 starts with the value in the queue 3 table and the new paragraph appears once.
6. **Afterwards.** `ops\audit-ghost-page-census.ps1 -Export` refreshes `content\ghost-adopted\` for the declared
   pages queue 3 moved. Copy each `.md` here to `content\lessons\<slug>.md` so `audit-lesson-rate-claims` covers
   the live lessons from then on, and record the applied ids and `updated_at` values at the top of this file.

## Findings made while staging (not fixed here)

Filed 2026-09-19: the first is merged into backlog I272 (the same defect: the 52 old lessons and the skill that would
write a 53rd), the second is I293, and the stale hub builder found while applying is I294.

- `.claude\skills\lesson\publish-lesson.ps1` writes the paywall JSON-LD's `mainEntityOfPage` as
  `$apiUrl/<slug>/`, which is the ghost.io admin host, not the site. And every live paid lesson read
  (Weeks 29, 30, 42 and `save-money-on-vacation`) carries `https://www.simplemoneyplaybook.com/<slug>/` there, a
  retired domain. The staged posts use the thriftycrew.com URL.
- `ops\revert-ghost-write.ps1` cannot reverse a POST. The journal's before-GET of a POST uri reads the collection
  (`/posts/`), records it as `captured`, and the reverter would offer to PUT that list back, when the real inverse
  is a DELETE of an id the journal never learns.
