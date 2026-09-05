# FINDING: the "Family Fare dropped a carried item" alert is unfounded, and the real gap is elsewhere

queue_id: 2026-09-05-18d67c (closed on this evidence)
author: Opus 5, 2026-09-05. Measured against every Family Fare capture on disk.
ruled by: Brad, 2026-09-05 - close the alert, write the gap up separately.

## What the alert said

> The Family Fare pull dropped item(s) FF actually carries (Freshop rate-limit survived the recovery
> passes). Board shows 'No price yet' for: jarred-gravy <- Heinz Home Style Turkey Gravy, 12 Oz Jar.
> Re-run pull-regular-familyfare.ps1 (recovery should catch them)

Three claims, and the evidence supports none of them.

## What is actually true

**1. Nothing was dropped. `Heinz Home Style Turkey Gravy` has NEVER appeared in a Family Fare
capture** - zero hits across every `out\regular\family-fare-regular-*.json` on disk. An item that was
never captured cannot have been dropped by a rate limit, and the recovery pass has nothing to recover.

**2. The cell emptied for a different reason, and it is a GOOD one.** Three products stopped matching
`jarred-gravy` between the 09-02 board and now:

    Park Street Deli Sirloin Steak Tips With Gravy 16 OZ
    Park Street Deli Sirloin Steak Tips With Mushroom Gravy 16 OZ
    Kevin's Natural Foods Sirloin Steak Tips with Gravy

None is jarred gravy. The `jarred-gravy` exclude list correctly caught them (`\b(?:and|&|n)\s+gravy\b`
among others). The commodity lost its FF price because its only FF "matches" were wrong matches. This
is the same rule improvement that shows up as five DROPPED rows and seven drift rows in
`audit-match-soundness` on the same morning - one cause, three alerts.

**3. Family Fare's captured catalog contains no jarred gravy at all.** 32 products carry "grav" in the
name; every one is cat food, dog food, gravy MIX in a packet, a breakfast bowl, or sliced turkey with
gravy. The include is `\bgravy\b` and the excludes remove all of them, correctly.

## A CORRECTION I made mid-investigation, recorded because the wrong version is plausible

I first read `pull_terms: 0` on the latest FF file as "the pull carries no gravy search term, so this
commodity can never win an FF cell." That is wrong. `pull_terms` is empty on EVERY FF file
(2026-08-31 through 2026-09-05, ~5,258-5,335 deals each), because the Family Fare capture is a full
catalog crawl and not a term-driven pull like Walmart's. There is no term list to add a term to.

## The real open question

FF's captured catalog is ~5,300 items and holds no shelf-stable jarred gravy - not Heinz, not
McCormick, not the store brand - while carrying 32 other gravy-named products. Either:

- Family Fare genuinely does not stock it (plausible; the Omaha stores are small-format), or
- the catalog crawl does not reach that shelf, in which case every commodity on it is invisible and
  `jarred-gravy` is just the one that happened to page.

**Not answered here, and it needs a look at the store rather than at the data**: the capture cannot
distinguish "not stocked" from "not crawled", and nothing in the estate currently can. That is the
finding worth keeping.

## What was NOT done

- No commodity rule was changed. The `jarred-gravy` excludes are right and the drops are correct.
- The FF pull was not re-run: on this evidence it would change nothing.
- No board cell was touched, and the empty `jarred-gravy` FF cell is honest.
