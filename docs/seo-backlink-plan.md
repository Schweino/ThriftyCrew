# Thrifty Crew - Backlink & Outreach Plan `[RETIRED 2026-09-09]`

> **THIS PLAN IS RETIRED. Do not execute it. Read the two sections below instead, and if you want the
> original text it is in git history at any commit before 2026-09-09 (backlog I67).**
>
> It was refuted three separate times and each refutation survived fixing the previous one:
>
> 1. **`[2026-08-31]`** its premise was wrong.
> 2. **`[2026-09-07, backlog I25/I26]`** every target URL pointed at the site's FORMER domain,
>    `simplemoneyplaybook.com`, and it claimed search properties that had never been verified.
>    That was repaired, which is what let the third refutation be seen clearly.
> 3. **`[2026-09-08, backlog I67]`** links are scored by the traffic they actually carry, so a plan
>    whose target is a COUNT of acquired links is aimed at the wrong quantity. **A link nobody clicks
>    is worth close to nothing.** This one cannot be repaired by updating URLs, because it is about
>    what the plan was trying to maximise.

## The measurement that closed it, taken 2026-09-09

The item's rung 1 was a read, not a build: *is anyone searching for this brand at all, and with what
wording?*

Over the 28-day window **2026-08-10 to 2026-09-06**, Google Search Console returned **55 distinct
queries carrying 95 impressions and 0 clicks**, and **not one of them contains any spelling of the
brand** - `thrifty`, `thriftycrew`, `thrifty crew`, or the near-misses a typing reader produces.
Site totals for the same window are **1 click and 289 impressions at impression-weighted position
40.02**.

**The gap between 95 and 289 is not a discrepancy, it is Google withholding rare queries.** Search
Console anonymises them, so roughly two thirds of the impressions are in rows nobody can read. **That
means this measurement cannot prove there is NO brand query** - one with a single impression could be
sitting in the anonymised tail. What it can say, and does, is that **there is no brand signal large
enough to be visible at all**, over four weeks, on a site with 1,331 indexed pages.

Harness: `ops/seo_search_console.py` (its own token exchange and query body, asked for the full query
list rather than the 25 rows the history file keeps). Baseline for comparison:
`ops/seo-search-console-history.jsonl` and the `seo-baseline-2026-08-31` memory.

## So the honest conclusion, and it is a decline

**Off-page work is premature here.** Backlink acquisition is how a site that people already look for
turns interest into authority. Nobody is looking for this one by name yet, and the constrained layer
is still crawl and content: an average position of 40 means the pages that DO rank are on page four,
where no link count rescues them.

**What is agency-scale, and the right answer is to decline it:** digital PR, journalist
relationships, editorial-calendar targeting, guest blogging at volume, syndication, and competitor
backlink analysis behind a paid tool. A one-person site does not execute these, and a plan that lists
them is a plan nobody runs.

**What is executable alone, kept as the shortlist for whenever this becomes worth doing:**

- read brand queries in Search Console on the cadence `ops/seo_search_console.py` already records
- a Google Alert on the brand name
- reclaim broken links that already pointed here
- convert unlinked brand mentions into links, one email at a time

**The prohibition, stated so it is not re-derived by somebody reading only this file.** Buying links
or using a brokerage is manipulation. Link velocity and index-tier scoring exist to catch it, and the
downside lands on a live paid site. Not a trade worth making at any price.

## When to reopen this

When a Search Console read shows brand queries with impressions in the double digits, or when average
position for the free tool pages moves inside the top 20. Either is a signal that there is something
for a link to amplify. Until then the same hour spent on content or on crawl is worth more, and this
file exists to stop the question being re-litigated from scratch a fourth time.
