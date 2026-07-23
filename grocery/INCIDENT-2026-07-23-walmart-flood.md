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
- [x] A regression test that pins a partial + a prior full Walmart file and asserts compare-deals
      keeps full coverage, so the union can never silently regress. (Shipped same day - see below.)
- [ ] (optional) Extend carry-forward to Baker's/Aldi/Fareway everyday pulls.

---

# Re-review (independent second pass, same day)

A from-scratch adversarial review of the incident and every fix, done after the original work.

## RCA correction
The ~20 Gmail alerts came from **local** pipeline runs, not the cloud. The cloud job runs
`check-ad-cycles.ps1 -NoAlert` and its only secret is GHOST_ADMIN_KEY - it has no Gmail token and
cannot send these emails at all. Its email channel is GitHub's own workflow-failure notification,
which the already-committed-today gate caps at one scheduled run (= one possible email) per day.
The flood mechanics and fixes are unchanged; the source attribution in the timeline is corrected.

## What the re-review verified
- **Mechanics**: single definitions, correct function ordering ($root before the moved filter),
  Add-Norm srcDate wiring matches the pre-existing Sam's pattern, self-test helpers defined before use.
- **End-to-end negative proof**: with the union deliberately reverted to newest-file-wins, the FULL
  guard gate (not just the self-test) exits 2 with
  `HARD FAIL: partial-pull union (compare-deals) self-test regressed ... re-opens the flood`.
  Restored; gate green again.
- **Audit states**: all three states of the new aging watch (fresh-full ok / aging-full warn /
  only-partials warn) verified against synthetic fixtures.
- **Full negative suite**: test-guards.ps1 (every guard's sabotage case) run over the final code.

## New gap found by the re-review - and closed
**The union created a fresh blind spot: partial pulls keep every freshness signal green while the
comprehensive capture silently ages toward the 14-day cliff.** Guard 9 watches file AGE (daily
partials keep the newest file perpetually fresh); the Wednesday watchdog watches mtimes (a partial
refresh updates them). Deal COUNT cannot detect partiality either - today's 50-term partial had
1,329 deals vs the full pull's 886 (deep on few commodities). So a run of throttled weeks would
surface only as a surprise coverage HOLD on day 15.

Closed with a machine-readable partial/full marker plus a watcher:
- `build-walmart-deals.ps1` now stamps `pull_terms` (distinct search terms in the raw capture; a
  full worklist runs ~400+ of commodity-search.json's 447 terms, a throttled partial ~50).
- `audit-walmart-fullpull.ps1` (single copy of the logic, on purpose): advisory exit 1 when the
  newest comprehensive capture is >= 10 days old, or the window holds only partials.
- `guards.ps1` surfaces it as a warn on every gate run; `check-ad-cycles.ps1` emails it (deduped to
  once/day by send-alert, and even under -NoAlert - same precedent as the consistency-drift alert,
  because only a local browser pull can fix it).
- Arming delay, stated honestly: files predating the stamp are "unknown", and the watch stays silent
  rather than cry wolf while an unknown outranks every stamped-full capture. It arms permanently at
  the next full (stamped) Wednesday pull. In the interim the cliff is still covered by the
  fail-closed coverage guard - safety is never dependent on this advisory.

Also: send-alert now purges prior days' `alert-sent-*.txt` so the cloud's `git add -A` does not
commit one new file to the repo every day forever.

## Second gap found by the re-review - a silently dead negative test
Running the full guard sabotage suite (test-guards.ps1) over the final code exposed that its
"stale sale" case had gone silently ineffective: guard 8's rule honours an undated markdown ON its
capture day (a markdown seen today IS live), and a weekly hygiene file `extra-deals-<today>.json`
now exists - so the test's fixture landed in a today-dated file, read as live, the guard correctly
stayed quiet, and the test failed while proving nothing. This is the THIRD occurrence of the
rotating-data trap the test file itself documents twice. Fixed: the test now moves any today-dated
extra-deals file aside so its fixture lands in a genuinely pre-today file (creating one if none
remains), and restores everything after. Full suite re-run to 16/16 before shipping.
Pre-existing, unrelated to the day's fixes - but it means guard 8's negative proof had a scheduled
blind spot every week, which is precisely what a re-review exists to catch.

## Accepted risks (deliberate, with bounds)
1. **The builder's multipack filter duplicates guard 5's logic** (the "two copies of the same math"
   trap this repo documents). Accepted because the failure is BOUNDED: if the copies drift, guard 5
   still hard-blocks the publish - worst case is one held refresh day and one deduped email, never a
   wrong price. The incident fixtures are pinned in the builder's self-test, so drift on the known
   cases is caught in the gate.
2. **The alert de-dup can suppress a second, DIFFERENT incident of the same type the same day**
   (subjects are normalized per type/day). Accepted trade-off for a quiet inbox; every suppression
   is written to alert-log.txt as SUPPRESSED, so nothing is invisible - and callers with finer
   de-dup can pass -Force.
3. **Baker's/Aldi/Fareway everyday pulls still lack carry-forward/union.** A partial pull there
   HOLDS the board (safe) rather than backfilling - an availability gap, not a correctness one, and
   the union is deliberately NOT extended to them: dating an ad-cycling store's everyday rows would
   let the freshness ranker filter out a still-valid weekly sale (self-test case 13 pins this).

## The layered "never again" model (final)
1. Producer cannot emit the junk (builder filter, self-tested).
2. Consumer cannot collapse on a partial (union, self-tested).
3. A creeping partial streak warns at day 10, not day 15 (fullpull watch, state-tested).
4. Gate hard-fails if 1 or 2 ever regress (guards invariant 0b, proven end-to-end).
5. Nothing wrong can ship regardless (coverage-regression guard, proven in production today).
6. One incident = a handful of emails, not twenty (per-type daily de-dup).
