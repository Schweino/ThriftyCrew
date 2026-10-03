# How often a Family Fare term was scored bought with zero rows (2026-10-03)

Follows finding 4 of `design/MEASURE-chip-resolvers-2026-10-rerun.md`: Freshop sometimes answers a throttled search
with HTTP 200 and no `items` array, and `pull-regular-familyfare.ps1` read that as one `$null` product, so the term was
scored `success` for the day with no row. The fix (same commit as this file) makes it a refusal. This file answers
"how often has it happened", which that doc left unmeasured.

## What the artifacts can and cannot say

Every committed `grocery/out/regular/family-fare-regular-*.json` carries `capture_terms`: one entry per term with
`outcome` and `row_count` (fresh rows found by that term). A success with `row_count` 0 is what this bug leaves
behind. **It is not unique to the bug.** The same entry is written when every product the term returned was already
taken by an earlier term in that run (dedup on name and size), or when every product was priceless or a multi-buy.
No artifact records the raw response, and the old code recorded no answer for the null shape (it cleared the term's
`ffTermAnswer`). So **no single entry can be attributed to this bug**. What the history can do is bound it.

## Numbers

Harness: a one-off scratch script, not committed. It walks `git log --all` over
`grocery/out/regular/family-fare-regular-*.json`, takes each DISTINCT blob once, and writes one row per (blob, term)
from `capture_terms`; every total below is derived from those rows. A recount of `row_count` from the blob's own
`deals` (fresh rows by `found_by_term`) agreed on all 70,399 entries.

- Coverage: 200 distinct file versions, 116 carrying `capture_terms`, commit dates 2026-08-12 to 2026-10-02 (49 days).
  Only COMMITTED runs are visible: a window whose file was overwritten by a later window before a commit is absent.
- Successes: **578 of 2,334 (24.8%)** had zero fresh rows.
- Of those, **548 fall on 121 terms that never had a row-bearing success in any committed run** (`frozen french fries`
  23 times, `13 gallon trash bags` 21). A sporadic throttle cannot produce the same zero every run, so these are the
  deterministic causes (dedup or priceless rows), not this bug.
- **30, on 17 terms, fall on terms that did bring rows in other runs.** These are the only entries the bug's shape
  fits, so **at most 30 of 2,334 recorded successes (1.3%)** can be this bug, and some or all of them may be dedup
  against a term that happened to run earlier that window.
- Cross-check, weak: `api_said` is recorded only from 2026-09-24, and only 2 of the 116 runs recorded a 429 refusal.
  Neither held a zero-row success (0 of 7 successes in those runs). Too few throttled runs to say more.

## What it means

The upper bound is small, and the bug's effect per case is a term cursor, ledger date and expiry class moved past
one unanswered term until its next rotation. The 548 deterministic zero-row successes are a separate question, not
this bug: those terms are scored bought every rotation while pricing nothing of their own. Whether that matters
depends on whether their commodities are priced through the other term; it is not measured here.
