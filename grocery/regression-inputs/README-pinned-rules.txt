These two files are the RULES half of the frozen fixture, pinned 2026-07-29.

The harness used to freeze only the DATA (ads / bakers / sams / regular / extra) and then let the engine read
the LIVE commodities.json and price-bands.json. So every ordinary rule edit - a widened include, a new
exclude, and there is at least one most weeks - showed up as "regression drift". The guard went red, stayed
red, and stopped being read: on 2026-07-29 it was reporting 66 differences and not one of them was a code bug.

Pinning them here means the regression test can now only fail when the CODE changes a known-good number,
which is the one thing it exists to catch. Rule drift already has its own owner - audit-match-soundness -
which compares matching against a reviewed baseline and has an -Accept workflow for intentional change.

Refresh these two snapshots ONLY as part of a deliberate re-baseline (build-regression-baseline.ps1), and
only after every diff has been explained. Never copy them in to make a red test go green.
