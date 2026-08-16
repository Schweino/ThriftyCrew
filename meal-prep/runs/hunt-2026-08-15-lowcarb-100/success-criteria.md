# Success criteria - hunt-2026-08-15-lowcarb-100

Written BEFORE the run starts, per design\PLAN-recipe-hunter-v2.1-2026-08-15.md section 5.4.

**Brad's conditions:** 100 dinner recipes, 400-650 calories per serving, 35 g carbs or less per serving.
Wave size 10 (the plan default) so 100 recipes pay 10 audits, not 20.

## Pass/fail criteria

1. **Every published recipe's COMPUTED per-serving macros sit inside the band.** This is a band, not a
   floor: 650 is a ceiling and a recipe that computes to 660 fails exactly like one that computes to 390.
2. **Pricer verdicts recorded with evidence for every absent term** - per store, with price, size and item
   name. A CARRIED claim with no price is refused by the script, correctly.
3. **Per-recipe token cost measured** in `usage.jsonl`. The v2.1 target is 200-250k per recipe against the
   shakedown's 786k. At 100 recipes this run is the first real test of that number at scale; missing the
   target is a finding, not a failure, but it must be measured rather than estimated.
4. **`audit-lane-shape.ps1` returns clean** against this run's `lane-log.jsonl`. Every lane invocation is
   recorded as it is dispatched, so the batch shape is auditable rather than asserted.
5. **Any new defect class frozen as a fixture the same day.**

## Section 5.3 verifications

- (a) The pricer lane stayed a singleton, and its per-store tabs behaved per its definition. At 100
  recipes this lane will actually be exercised hard, which the shakedown never did.
- (b) `hunt-run -Derive` moved recipes parked/priced off REAL queue verdicts, not fixtures.
- (c) A mid-run resume via `-Status` after killing the session.

## Deviations from the plan of record, recorded deliberately

- **HUNT runs 12 concurrent sourcers, not 1** (plan section 2.4). Brad's direction. The lanes are disjoint
  on (protein x method) - chicken-braise, chicken-skillet, chicken-bake, beef-slow, beef-skillet,
  beef-roast, pork-chop, pork-sausage, pork-shoulder, turkey-skillet, turkey-bake, egg-cheese - so no two
  workers can re-find the same dish. Two workers both assigned "chicken" would collide constantly; these
  cannot.
- **Dedup runs 8 concurrent ADJUDICATORS plus 1 serial DECIDER** (plan section 2.4 specifies one selector
  per round). Brad's direction. Adjudication (ruling candidates against 544 catalog recipes) shards;
  deciding does not. The decider is the single writer of accepted-slugs.json and the only stage that
  advances recipe state. Streaming it strengthens cross-lane dedup rather than weakening it: it checks
  every arriving pick against everything accepted so far in the run.
- **All 8 lanes run continuously with no barrier between them**, per Brad's pipeline chart. The previous
  attempt awaited hunt -> adjudicate -> decide per round, so hunting and deduping never ran at the same
  time. Corrected.
- **The chart's "+1 pending count per ingredient task" is NOT implemented as drawn.** Plan section 2.2
  already took that from Brad's chart and made it race-free: a stored counter written after enqueue can
  race, and a recipe can ship at zero having been checked zero times. Counts are DERIVED from the queue's
  own verdicts on every read.

## Known constraint: the concurrency ceiling

The workflow harness caps CONCURRENT agents at min(16, cpus-2) = **16 on this box, for the whole run** -
front-end and downstream together. The 20 requested hunt/dedup workers therefore cannot all be alive at
once; excess calls queue. Left unmanaged, 20 front-end workers would hold every slot and starve
extract/map/price/write/qa, including publishing. Two throttles prevent that, and they park HUNTING
specifically, because hunting is the only lane with unbounded work: a sourcer stands down when 24 or more
candidates are already waiting for adjudication, or when 25 or more accepted recipes are not yet resolved
(the WIP limit). Watch for: publishing stalling behind hunting, which would show up as a large qa-passed
backlog with no waves closing.

## Fable conformance review (2026-08-15, against Brad's pipeline chart)

Reviewed the orchestrator lane-by-lane against the chart. One streaming violation found and fixed
BEFORE any pricing ran: the price lane had been written to WAIT for a full batch of 10 terms (with an
8-stuck-recipes release valve to break the deadlock that wait created against the WIP limit). That
contradicted both the chart's "continuously clears queue" and plan section 2.4's own loop, which reads
"snapshot pending terms -> spawn pricer -> record -> repeat" - greedy service with 10 as a CAP, not a
threshold. Corrected to greedy: the singleton pricer takes whatever is pending the moment it is free.
Under load this converges to full batches on its own (terms accumulate during each minutes-long
invocation); when sparse it prices a lone term immediately. Wall-safety lives in the singleton, not in
batch size. The release valve was deleted with the deadlock it existed to break.

Everything else either streams per the chart (per-candidate hunt -> adjudicate -> decide handoff; greedy
sweeps that never wait to fill a quota; per-recipe extract/write/qa) or deviates deliberately with the
reason recorded here (waved publishing behind the batch auditor; one QA repair cycle per estate S7;
extraction after acceptance so duplicates never pay extraction; derived pending counts per plan 2.2;
hunting parked under the harness's 16-slot cap).

## Failure handling added 2026-08-16 (after a 16.1M-token no-progress burn)

Two defects, both found the hard way, both fixed:

1. **An agent call returning null was treated as a verdict.** A session-limit outage killed the mapper
   and writer mid-batch, and the orchestrator recorded those recipes as `rejected-not-carried` /
   `writer failed` - permanent content rejections for stages that never ran. The real hunt-run state
   files still read `extracted`, so no estate damage was done, but the report was false and a later
   resume would have skipped those recipes forever. Now: only an explicit schema field (status
   'rejected', verdict 'FAIL') is a verdict. A null is retried, and if it never resolves the recipe is
   recorded **STUCK** - a fifth bucket, resumable, never conflated with REJECTED.

2. **Retry budgets were keyed by batch shape, so they never saturated.** The map lane pulls a new
   combination of slugs each cycle, minting a fresh 3-attempt allowance every time. Against a session
   limit - which clears at a wall-clock time, not on retry - the lanes manufactured new keys and burned
   657 failed calls before hitting the harness's 1000-call kill. Now retries are accounted PER SLUG, and
   a **circuit breaker** watches run-wide: 5 consecutive failures across any lanes stops all dispatch
   and unwinds cleanly. `agent()` returns a bare null with no error text, so the breaker matches on
   shape (an unbroken run of failures) rather than on message; isolated per-recipe flakiness between
   successes never trips it. A second trip condition caps total agent calls at 900, short of the
   harness's 1000, so the run always exits under its own control and stays resumable.

When the breaker trips, publishing never starts (a half-dispatched wave strands the ledger), the
instrumentation and final-report agents are skipped rather than describing a truncated run as a
finished one, and `hunt-run.ps1 -Status` remains the record of truth.

## Macro gate

`hunt-run.ps1` has no `rejected-macros` state. A recipe whose COMPUTED per-serving macros fall outside the
band is retired via `rejected-qa` with the miss named in the detail. Recipes are never adjusted to make the
numbers fit - that would make the card a false claim, which is the one thing every gate here exists to
prevent.
