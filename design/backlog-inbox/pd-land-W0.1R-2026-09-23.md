# W0.1R landed - the soak that gates Row 2 (2026-09-23)

Source: the landing stage of W0.1R, `design/PLAN-push-derived-conflicts-2026-09-23.md`.

W0.1R (the push-main ledger row: refusal class, writer copy, rounds, lock takes, catch-up conflict target,
reject_rc, subject_shas, subject_count, head_ref) is on origin/main as of this push. Landing it is not the
done-when of the rows that read it.

**The soak is W0.3 step 7:** 30 lock-taken `push-main` rows in the production push ledger
(`%LOCALAPPDATA%\ThriftyCrew\push-ledger\pushes-<date>.jsonl`) that carry the W0.1 and W0.1R fields, written
from checkouts that have pulled this change. Rows from a checkout that has not pulled it keep the old shape
and do not count toward the 30; count them apart rather than folding them in.

**Row 2 may start when the soak is met**, and not before. Until then, a figure read off these fields is over
fewer than 30 rows and says so with its denominator.

How to count it: read the production ledger and count rows with `event = push-main`, `schema = 2` and
`lock_takes` of at least 1.
