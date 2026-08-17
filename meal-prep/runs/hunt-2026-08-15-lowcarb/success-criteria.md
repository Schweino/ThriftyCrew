# Success criteria - hunt-2026-08-15-lowcarb (the v2.1 proving run)

Written BEFORE the run starts, per design\PLAN-recipe-hunter-v2.1-2026-08-15.md section 5.4.
Brad's conditions: 10 dinner recipes, over 475 calories per serving AND under 35 g carbs per serving.

## Pass/fail criteria

1. **2 waves published with zero rolled-back slugs.** Wave size is 5 (not the default 10) precisely so a
   10-recipe run produces the two waves section 5.4 asks for. A slug held by the serveability gate counts
   as a rolled-back slug and fails this criterion.
2. **Pricer verdicts recorded with evidence for every absent term.** Every term that reached the queue
   carries a per-store verdict with price, size and item name. A CARRIED claim with no price is not
   evidence, and the script already refuses it.
3. **Per-recipe token cost measured** and written to `usage.jsonl`. Target from the v2.1 retrospective:
   200-250k tokens per recipe, against the shakedown's 786k. Measuring it is the criterion; missing the
   target is a finding, not a failure.
4. **Any new defect class frozen as a fixture the same day.**

## Section 5.3 verifications this run must establish

- (a) The pricer lane stayed a singleton, and its per-store tabs behaved per its definition.
- (b) `hunt-run -Derive` moved recipes parked/priced off REAL queue verdicts, not self-test fixtures.
- (c) A mid-run resume via `-Status` after killing the session.

## Known deviations from the plan of record, recorded deliberately

- **HUNT lane runs 4 concurrent sourcers, not 1** (plan section 2.4 specifies one at a time). Brad's
  direction, 2026-08-15. The plan's stated reason for the singleton is streaming dedup - a second sourcer
  cannot see what the first just took. Disjoint protein lanes (chicken / beef / pork / turkey+bakes)
  remove that collision by construction.

- **SELECT runs 4 parallel lane adjudicators plus 1 serial decider** (plan section 2.4 specifies one
  selector per round). Brad's direction, 2026-08-15. Dedup was split rather than simply copied 4x,
  because the two halves have different safety properties:
  - *Adjudication* (rule each candidate against 544 catalog recipes) shards cleanly by protein - a
    chicken candidate can only collide with the chicken slice of the catalog. This is the expensive half.
  - *Deciding* does NOT shard. `accepted-slugs.json` must have exactly one writer or concurrent appends
    lose updates, and a cross-lane near-duplicate (the same dish in beef and in turkey) is invisible to
    any worker that sees only one lane. The decider is the single writer and the only stage that
    advances recipe state.
  Watch for: a cross-lane duplicate reaching publication. That is now the decider's job alone, and it is
  the specific failure this split could produce if the decider treats the adjudicators' cross-protein
  flags as a complete list instead of as leads.
- **Section 5.1 asks for ~20 recipes; this run is 10.** Brad's call. The pricer-lane exercise from 5.1 is
  preserved: sourcers are told NOT to filter out candidates with plausibly-absent ingredients, inverting
  the shakedown's selection bias.
- **(c) mid-run resume is not currently scripted as a live kill/resume drill.** If it is not performed,
  the verification must say so rather than claim it passed.

## Concurrency correction (2026-08-15, after Brad stopped the first attempt)

The first orchestrator ran the front of the pipeline as three awaited barriers per round:
4 sourcers -> wait -> 4 adjudicators -> wait -> 1 decider -> wait -> next round. Downstream
(extract/map/price/write/qa) were already continuous worker pools, but hunting could not start a new
round until deduping had finished the previous one, so the two never ran at the same time. Brad's
pipeline chart has no barriers anywhere: every agent is a continuous consumer on a queue, marked
"continuously processes / never pauses".

Corrected: all 8 lanes start at once and each closes its downstream queue only when its own input
drains. Sourcers keep hunting while adjudicators rule the pool they just produced and the decider
selects out of the one before that; selected recipes go straight into extraction without waiting for a
round to close. The decider stays single-threaded (single writer of accepted-slugs.json), and streaming
it actually strengthens cross-lane dedup, because it now checks every arriving pick against everything
accepted so far rather than against one round's merged pool.

One element of the chart is deliberately NOT implemented as drawn: the chart's "update shared DB pending
count (+1 for each ingredient task)". Plan section 2.2 already took that from Brad's chart and made it
race-free - a stored counter written after enqueue can race, and a recipe can ship at zero having been
checked zero times. Pending counts are DERIVED from the queue's own verdicts on every read instead.

## Macro gate

`hunt-run.ps1` has no `rejected-macros` state. A recipe whose COMPUTED per-serving macros miss the
conditions is retired via `rejected-qa` with the miss named in the detail. Recipes are never adjusted to
make the numbers fit - that would make the card a false claim, which is the one thing every gate here
exists to prevent.
