# Subtitle and search-text fixes for six live pages (drafted 2026-09-19, APPLIED 2026-09-19)

## APPLIED

Brad approved this queue and it was applied on 2026-09-19 with `ops\review-staged.ps1 -Apply`. All 6 PUTs went
out. Their write-journal ids are `145c1330f136`, `1ad25062578f`, `3b443f4e4b8f`, `5ab25918e665`,
`a6745443b873` and `f86e3b6b09ec`. All 6 pages were read back afterwards and every sent field matched the
draft, and the renters card html is byte-identical to the staged one.

A later read-only GET the same morning (05:35, for `subtitle-fixes-2.md`) shows the same thing on the four of
these pages that carry the Money Hacks tag: renters and car insurance carry the new subtitle and search text,
savings by age and the emergency fund carry the new search text, and the renters body has "The math, with your
own numbers" once and "real-dollar" nowhere.

Two things the apply did not reach, both written up in `subtitle-fixes-2.md` under "Anything odd":

- **The Money Hacks hub still shows the old subtitles** for renters (*"For about 15 dollars a month"*) and car
  insurance (*"Cut $300 to $600 a year"*). The hub page copies every card's subtitle into its own html when it
  is built, so it only changes when the hub is rebuilt.
- On savings by age and the emergency fund, where only the search text changed, Ghost left `updated_at` where
  it was (09:59:04 and 09:59:03). Renters and car insurance, whose subtitle changed too, moved to 10:33. So on
  a search-text-only change, `updated_at` does not show the write happened; the field values do.

The rest of this file is the draft as it was approved, kept as the record.

The overlap body fixes went live on 2026-09-19 (`overlap-review.md`, "Left standing"). They changed each page's
body card only, so the subtitle under the title and the text search engines and link previews show still carry
figures and labels the bodies no longer have. This is the second PUT per page that `overlap-review.md` said
would need its own approval.

**Nothing here has been sent to Ghost.** Every draft is a staged call in
`staged/subtitle-fixes.jsonl`, one PUT per page, 6 in all. Every live page was re-read after staging and its
`updated_at` and text were unchanged.

To apply, after reading the table below:

```
powershell -NoProfile -File ops\review-staged.ps1 -Queue design\ready-for-brad\lessons\staged\subtitle-fixes.jsonl          # list
powershell -NoProfile -File ops\review-staged.ps1 -Queue design\ready-for-brad\lessons\staged\subtitle-fixes.jsonl -Apply   # send
```

Listing it on 2026-09-19 printed `REVIEW-STAGED-COMPLETE queued=6 concerns=0`, exit 0.

Each PUT carries the `updated_at` read from the live page just before staging. If anyone edits one of these
pages first, Ghost refuses that PUT with a 409 and nothing on it changes. Re-draft that page; don't force it.
Each PUT sends only the fields that change. Titles, `meta_title`, `og_title`, `twitter_title`, tags,
visibility, status and slug are not in the request, so Ghost leaves them as they are.

## Old next to new

The meta, OG and Twitter descriptions were identical on every page before, and they are identical after, so
each page has one "search and share text" row that covers all three.

### `/is-renters-insurance-worth-it/` (post `6a499cc750682b0001cd434d`, updated_at `2026-09-19T09:59:00.000Z`)

| Field | Live now | Drafted |
|---|---|---|
| Subtitle (`custom_excerpt`) | For about 15 dollars a month, renters insurance protects thousands of dollars of your stuff and shields your savings from liability claims. | For one small, predictable bill, renters insurance protects thousands of dollars of your stuff and shields your savings from liability claims. (142 chars) |
| Search and share text (`meta_description`, `og_description`, `twitter_description`) | Is renters insurance worth it? For roughly 15 dollars a month it protects thousands in belongings plus liability. Here is the real-dollar math. | Is renters insurance worth it? For one small bill it protects thousands in belongings plus liability. Here is how to do the math with your own quote. (149 chars) |
| Body heading (the one change to the body) | The real-dollar math | The math, with your own numbers |

The new subtitle borrows the body's new bottom line (*"For one small, predictable bill you protect
thousands of dollars of belongings"*). The heading had to go because the section under it now says *"These
numbers are made up to show the math"*, and "real-dollar" says the opposite. It is the only body change: the
staging script checked that the heading appeared exactly once and that everything else in the card is
unchanged, byte for byte.

### `/how-to-save-on-car-insurance/` (post `6a498da450682b0001cd3f34`, updated_at `2026-09-19T09:59:04.000Z`)

| Field | Live now | Drafted |
|---|---|---|
| Subtitle | Cut $300 to $600 a year off your car insurance while keeping every bit of protection that matters. | Knock real money off your car insurance while keeping every bit of protection that matters. (91 chars) |
| Search and share text | Save $300 to $600 a year on car insurance without cutting coverage. Smart shopping, deductibles, and every discount you should be claiming. | Save on car insurance without cutting coverage. Smart shopping, deductibles, and every discount you should be claiming. (119 chars) |

"Knock real money off" is the body's own opening line (*"You can knock real money off your premium"*).
The search text only loses the figure.

### `/term-vs-whole-life/` (post `6a498d9c50682b0001cd3ec2`, updated_at `2026-09-19T09:58:59.000Z`)

| Field | Live now | Drafted |
|---|---|---|
| Subtitle | Term life is cheap protection for now. Whole life is pricier and easy to oversell. | Term life is simple protection that costs less. Whole life costs a lot more and is easy to oversell. (100 chars) |
| Search and share text | Compare term and whole life insurance in plain English, with real monthly costs, so you can see which one actually fits your family. | Compare term and whole life insurance in plain English, and how to get a real quote on both, so you can see which one actually fits your family. (144 chars) |

**The search text here was not on the leftover list.** It promises "real monthly costs", and the body fix took
out the only monthly costs the page had ($30 and $400). The body now says to get a quote on both, so the new text
says that. Drop this row if you would rather leave it.

### `/homeowners-insurance/` (post `6a49916550682b0001cd4062`, updated_at `2026-09-19T09:59:00.000Z`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Homeowners insurance in plain English: what it covers, why lenders require it, and how a deductible works, with a real-dollar example. | Homeowners insurance in plain English: what it covers, why lenders require it, and how a deductible works, with a simple example. (129 chars) |

The body now calls its $60,000 fire a *"made-up example"*. The subtitle (*"The policy that pays to fix or replace
your home if disaster hits."*) is fine and is not touched.

### `/how-much-should-i-have-in-savings-by-age/` (post `6a49a57950682b0001cd45b6`, updated_at `2026-09-19T09:59:04.000Z`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | See how much to have saved by 30, 40, 50, and 60, with real-dollar targets, an emergency-fund rule, and a plan to catch up if you are behind. | See how much to have saved by 30, 40, 50, and 60, what those targets look like in dollars, an emergency-fund rule, and a plan to catch up if you are behind. (156 chars) |

The body's dollar targets are worked off an example salary (*"If you earn $60,000, the target at 40 is around
$180,000"*), so "what those targets look like in dollars" is true and "real-dollar targets" oversold it. The
subtitle is not touched.

### `/how-to-build-an-emergency-fund/` (post `6a498da350682b0001cd3f22`, updated_at `2026-09-19T09:59:03.000Z`)

| Field | Live now | Drafted |
|---|---|---|
| Search and share text | Build a $1,000 emergency fund in about 60 days with simple steps, real-dollar examples, and automatic transfers that keep the next surprise off your credit card. | Build a $1,000 emergency fund in about 60 days with simple steps, easy math, and automatic transfers that keep the next surprise off your credit card. (150 chars) |

"Easy math" is from the body (*"The math is friendlier than it looks"*: $1,000 in two months is about $500 a
month). The live text was 161 characters, and this one comes in under 160. The subtitle is not touched.

## Checks the staging script ran before it queued anything

- Each page was read again right before staging, and its `updated_at` and every field being replaced matched
  the draft read. If anything had changed, the script would have stopped.
- No em or en dash in any new value or in the new renters body.
- Every number in a new value appears on that page's body or title: `$1,000` and `60` on the emergency fund page,
  `30`, `40`, `50` and `60` on the savings page. No other new value has a number in it.
- None of the removed wording survives in its page's new values: `15 dollars` and `real-dollar` (renters),
  `$300` and `$600` (car), `cheap` and `real monthly costs` (term), `real-dollar` (the other three).
- Ghost's limits: subtitles at most 300 characters (longest drafted is 142), descriptions at most 500, and
  every description is also held to 160 so a search snippet isn't cut off (longest drafted is 156).
- Each PUT came back from `lib\ghost-lib.ps1` marked staged, not sent.

## Voice: what the drafts were modelled on

Brad's ruling on 2026-09-19 is that reader copy is modelled on live posts and the July rewrite, never on
`content\lessons\*.md`. Read-only Admin API GETs through `lib\ghost-lib.ps1` (staging and journal cleared, no
write), 2026-09-19:

- **The six pages' own live bodies**, with the approved fix wording. That wording is the strongest guide here,
  because each new line has to agree with the body under it, and where it could, a draft reuses the body's own
  phrase ("one small, predictable bill", "knock real money off", "costs less", "made-up example").
- **Week 2, The Compounding Secret** (*"Small things repeated don't add up. They multiply."*) and **Week 14, No
  One Is Coming to Save You** for how Brad writes a subtitle: short plain sentences, no hype, no figure it has to
  defend.
- **Vacations: Approaches We Use to Save Hundreds** and **Basics of Investing** for the money-hacks register
  and for how he pairs a subtitle with a longer search line.
- The subtitles and search lines of the 50 live Money Hacks posts, which is where these pages sit, for length
  and shape.

`archive\ghost-config\voice-rewrite\` has the July before and after bodies and the publish script, but no written
brief, the same as the lesson drafts' README found.

## Not in this queue, and worth knowing

Several other live Money Hacks pages carry the same kinds of subtitle and search wording this cleanup removed.
They weren't in the overlap review and aren't drafted here:

- "real-dollar" in the search text of `/how-to-save-money-on-utilities/`, `/how-much-house-can-i-afford/`,
  `/money-rules-to-live-by/`, `/how-to-track-your-expenses/`, `/should-i-pay-off-my-mortgage-early/` and
  `/frugal-habits-that-build-wealth/`.
- Unsourced dollar ranges in subtitles or search text: `/how-to-save-money-on-utilities/` ($500 to $700 a year),
  `/best-cash-back-apps/` ($300 to $600 a year), `/frugal-habits-that-build-wealth/` ($5,000 to $10,000 a year),
  `/how-to-do-a-spending-fast/` ($300 to $500).

Whether their bodies back those figures up wasn't checked. They are listed so they can be looked at on purpose,
not found by accident.

**Followed up in `subtitle-fixes-2.md`** (drafted 2026-09-19): each of those pages checked against its own body,
seven more search lines staged, and every live Money Hacks post swept.
