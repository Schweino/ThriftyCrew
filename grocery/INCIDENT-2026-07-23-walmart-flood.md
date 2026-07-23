# Incident post-mortem — 2026-07-23 "crap-ton of failure emails"

**Severity:** LOW (customer impact: none). **Status:** RESOLVED + prevention shipped.

## One-line summary
A brand-new Walmart price builder, introduced this morning, produced a partial and partly-junk
data file. The pipeline's guards did exactly their job — they refused to publish it and held the
last-good board — but the alerting had no de-duplication, so one contained incident turned into
~20 emails. **No wrong price ever reached the website.**

## What the customer saw
Nothing. The live board kept serving the previous good prices the entire time. This was a
*monitoring* failure (too many alarms), not a site failure.

## Timeline (2026-07-23, Central)
- **~06:30** — the scheduled cloud pipeline runs, recomputes the board, and its guards HARD-FAIL on
  the Walmart data. Board left at last-good. Alerts fire.
- **07:22** — a local browser-store refresh commits a **newly created** `build-walmart-deals.ps1`
  (it did not exist before this commit) plus its output `walmart-regular-2026-07-23.json` and a raw
  `walmart-capture-2026-07-23.csv`.
- **~07:39–07:41** — the pipeline runs again, guards HARD-FAIL again (34 invariants), board held,
  more alerts. Every alert channel re-fires because there is no per-type de-dup.
- **08:18–10:09** — fixes written, verified, and shipped (this document + the commits below).

## Root cause (the five whys)
1. **Why ~20 "failed" emails?** The fail-closed guards blocked publishing bad Walmart data, and
   every alert channel (guards-failed, coverage-held, stores-dropped, drift, soundness,
   sale-fallback, Wednesday-refresh-missed) re-fired on each of ~3 pipeline runs. `send-alert.ps1`
   had **no de-duplication**, so 7 alert types × 3 runs ≈ 20 emails for one incident.
2. **Why did the guards fail?** Today's Walmart data was bad in two independent ways:
   - **Partial coverage.** The Walmart browser pull is throttled by Walmart's bot wall (PerimeterX)
     to a ~50-term "core staples" subset on bad days. Under the old "newest file wins" rule that
     50-commodity file **replaced** the last full 410-commodity file, so Walmart collapsed from 410
     board cells to 80. The coverage-regression guard (correctly) blocked the publish.
   - **32 junk multipack rows.** The new `build-walmart-deals.ps1` was cloned from the Sam's builder
     but the Sam's multipack filter (guard-5 logic) was **not** ported, so 32 bulk multipacks
     (ice-cream 12/20-packs, 8-pack/4-pack flour cases) landed in the output and hard-failed guard 5.
   - A leftover raw `.csv` capture in `out/regular/` also tripped guard 7 (no non-data files there).
3. **Why did a partial pull break the whole board?** Because `compare-deals.ps1` used **newest-file-wins**
   for Walmart's everyday-price file. That is correct for a store you pull whole every time and
   **wrong** for a store that can come back partial.
4. **Why did the new builder ship without the multipack filter?** It was cloned from the Sam's
   builder and the filter wasn't carried over; nothing ran the builder's output through the guards
   before it reached the repo. (The runtime guard is what caught it — as designed.)
5. **Why a flood instead of one alert?** No per-type daily gate on `send-alert.ps1`.

## The class (this has happened before)
"Newest file wins" for a store that can be pulled in **slices** is a recurring class:
- **2026-07-16:** it cut **Sam's** from 251 → 116 cells. That incident is why the
  **coverage-regression guard exists** — and it is exactly what caught Walmart today.
- **2026-07-23 (today):** same class, **Walmart** 410 → 80.
Family Fare hits the same throttle but was already protected by carry-forward (it saved FF today
too: its API returned 708 of 1,937 items and the throttle-wipeout guard kept last-good live).

## What worked (defense in depth held)
- **coverage-regression guard** — blocked the publish the moment Walmart collapsed.
- **guard 5 (multipack)** — rejected the 32 junk rows.
- **guard 7 (stray file)** — flagged the raw csv in the data dir.
- **Net result: the board never published a wrong number.** The system failed *safe*.

## What didn't work
- **Alerting had no de-dup** → one incident read as twenty failures.
- **The "newest file wins" protection wasn't extended to Walmart** (only Sam's had the union;
  Family Fare/Hy-Vee had carry-forward). Walmart was the unprotected everyday store.

## Fixes shipped (with verification)
1. **`compare-deals.ps1` — Walmart now UNIONS its recent captures** (`$WalmartMaxAgeDays=14`) with a
   `src_date` tag, and the freshness-per-commodity ranker keeps today's price where it exists and the
   last full capture everywhere else. No stale-low, no coverage loss. *Verified:* Walmart back to 411
   cells, coverage-regression clean, guards green. Scoped to Walmart only; the ad-cycling stores stay
   newest-only (unioning them would resurrect expired sales).
2. **`build-walmart-deals.ps1` — multipack filter added in lockstep with guard 5.** Junk is rejected
   at the source now, not just at the gate. *Verified:* self-test passes; 32 rows rejected, output
   guard-5-clean.
3. **`send-alert.ps1` — one email per alert TYPE per day.** Subjects are normalized to a type key
   (dates/counts/rc-codes stripped) and recorded in `alert-sent-<date>.txt`; repeats suppress.
   `-Force` bypasses for callers with their own de-dup. *Verified:* today's ~20 emails would have
   been 5.
4. **Stray captures** moved to `out/captures/` (gitignored); guard 7 clean.

## The "never again" guarantee
- **Universal safety net (already in place, proven today):** the coverage-regression guard hard-fails
  on ANY store's collapse and holds the board. So even a store WITHOUT carry-forward can never publish
  a collapsed catalogue — it fails safe. This is the guarantee that "nothing bad ships."
- **Partial-pull prevention (now complete for the everyday stores):** Family Fare + Hy-Vee
  (carry-forward), Walmart + Sam's (union). These four can take a partial pull and the board still
  publishes full, fresh coverage instead of merely holding.
- **No more floods:** per-type daily alert gate.

## Known residual (safe, non-urgent)
Baker's, Aldi, and Fareway everyday files are still newest-file-wins with no carry-forward. If one of
them comes back partial, the coverage guard will HOLD the board (safe) and alert once — it cannot
publish bad data, but it would stop that day's refresh for that store until re-pulled. Extending
carry-forward to them is the remaining hardening step; it is an availability improvement, not a
correctness fix.

## Follow-ups
- [ ] (optional) Extend carry-forward to Baker's/Aldi/Fareway everyday pulls.
- [ ] (optional) A regression test that pins a partial + a prior full Walmart file and asserts
      compare-deals keeps full coverage, so the union can never silently regress.
