# PLAN: days with no alerts, and triage that prevents instead of repairs

**Status: PROPOSED 2026-09-10. Nothing below is built.** Three rulings in section 1 gate most of it.
Phases 0, 1 and 5 need no ruling and can start on "go".

Brad's goal, 2026-09-10: "get to a place where we have days with no alerts and triage agent is planning
fixes to future proof and not just immediate fix."

## 1. Rulings needed

**R1. What may page.**
- **(A) Recommended.** Page on four conditions only:
  1. the live board or feed is wrong or held;
  2. a guard or watcher cannot see;
  3. scheduled work did not run or did not land;
  4. a live cell moved in a way automatic adjudication could not explain.

  Everything else becomes review intake that triage works from a daily packet, with no queue item and no mail.
- **(B)** Keep every alert, but collapse echoes and recalibrate (Phases 1 and 2 only). Quiet days stay rare,
  because the five review-intake types in section 3 fire on 6 to 16 of 20 days by construction.
- **(C)** Status quo.

**R2. The target.** Proposed: at least 3 alert-free days a week by 2026-10-08, measured over a rolling 7 days
by the Phase 0 census.

**R3. The weekly lane spends its budget on PREVENTION.** One upstream fix per week for the top recurring
class, chosen from the census, whether or not that class fired that day.

## 2. Baseline, measured 2026-09-10

Harness: a read-only census over `grocery/triage-queue.json` and 52 plan files (`plan-2026-07-31` to
`plan-2026-09-10-2`), run at commit 2bb6d3ffd.
- The queue window is 2026-08-22 to 2026-09-10, which is the 30 days of resolved history send-alert keeps.
- Phase 0 commits the census script, so these numbers can be re-run rather than trusted.

- **Alert-free days: 0 of 20.** 249 alerts (new ids plus absorbed recurrences) over 20 days is 12.5 a day,
  ranging from 2 to 21.
- **69 alert types.** 25 fired on 3 or more days, and those 25 carry 246 of the 297 fires (83%).
- **All 25 of those came back after triage had closed them.** Closing an alert has not meant it stopped.
- **Dispositions:** only 34 closes carry one, since `triage-close.ps1` began recording them on 2026-09-07:
  25 confirmed, 5 false-alarm, 3 superseded, 1 by-design. Older closes are prose.
- **Plans:** 137 code items, 93 of them (68%) with a `root_fix`.
  - The class fixes exist, but they are aimed at the triage frame: a rule, an exclude, a fixture.
  - They are not aimed at the source that keeps producing the alert.

## 3. Why no day is quiet: the most frequent types, read from their close notes

The bucket for each type is MY READING of its close notes, not a recorded field. It is the part of this
plan most worth checking.

**Bucket 1: review intake wired as alerts.**
- The types (days fired, of 20):
  - matching soundness review: 16
  - new price flags: 15
  - semantic sweep: 14
  - stores dropped from a commodity: 11
  - wrong store department: 6
- They fire because the data changes daily. They are work, not failures, and the work pays. Real wrong products they found:
  - a Belvita bar crowned breakfast sandwiches (09-07)
  - a fuel-saver reward was published as a $0.10 laundry pod (09-07)
  - a KIND bar was priced as coconut (09-10)
  - canned salmon routed to honey (09-05)
- Keep the work; stop paging for it.

**Bucket 2: one incident paging many times.**
- The types (days fired, of 20):
  - capture watchdog: 13
  - board prices aging: 10
  - smp-feed edge: 3
  - test-guards could not evaluate: 3
  - surface staleness
- The notes say so outright:
  - "all four issues were one condition: guards refused the board" (09-07)
  - "the same held-back board one job later" (09-03)
  - "one condition seen by two emitters" (09-09)
- On 09-10 one guard hold produced four queue items.

**Bucket 3: by design or miscalibrated.**
- Family Fare catalog degrading, 11 days: "miscalibrated alert, healthy store"; "throttle, not decay".
- On-sale with no everyday fallback, 9 days: "rolling condition by design".
- Store-registry drift, 8 days: "fifth false alert of one shape".
- Walmart full capture aging, 7 days: routed to the browser agent each time.
- Family Fare carried item, 5 days: the term rotation working as designed.

**Bucket 4: real recurring defect classes.**
- **GUARDS FAILED, 9 days.** Every listed instance was one class, a size or basis the capture got wrong:
  - orange juice sized 128 oz by weight (08-31)
  - teriyaki fl oz against oz (09-03)
  - disinfectant spray (09-06)
  - case notation 12 x 12 oz (09-07)
  - a size derived from a price quotient (09-10)
- **A guard gone blind, 9 days.** At least three were self-inflicted by a triage session's own in-flight edits (08-30, and twice on 08-31).

**The long tail.** 44 more types fired on 1 or 2 days each. A quiet day needs those silent too, so this plan
measures what is left after each phase rather than promising a number.

## 4. Phases

Each phase names its lane, what ships, and its ACCEPTANCE BAR, written here before anything is built.

### Phase 0: the scoreboard (ops lane, no ruling)

**What ships:**
- `grocery/audit-alert-census.ps1`, which appends one row per day per type to `grocery/out/alert-census.jsonl`: fires, new ids, closes, dispositions, returns after a close.
- It prints alert-free days over a rolling 7, fires a day, the top recurring types, the echo share and returns.
- It carries a `SCOPE OF A CLEAN REPORT:` line, a COMPLETE marker, and a `-SelfTest` over a frozen three-day queue.
- It runs in the daily chain after triage; the triage report and the weekly lane both read it.

**Bar:** re-running it over the 2026-09-10 queue snapshot reproduces section 2's numbers exactly.

### Phase 1: one incident, one alert (ops lane, no ruling)

**What ships:**
- `send-alert.ps1 -CausedBy <incident key>`. An alert that is a consequence of an open incident is absorbed as a recurrence of that incident's queue item; no new id, no new mail.
- The first key is the day's guard hold (`chain-verdict.json` guards_blocked). It is used by:
  - the watchdog's NOT PUBLISHED, FAILED and COMPUTED BUT NOT SHIPPED lines
  - the board-aging check
  - the feed edge check
- Surface staleness and test-guards already stand down on a red verdict as of 2026-09-10.
- Fixtures replay the 09-07 and 09-10 mornings.
  - MUST FIRE: a watchdog finding the hold did NOT cause still mints its own item.

**Bar:** the next guard-red morning produces one queue item where 09-10 produced four.

### Phase 2: recalibrate or retire what keeps being by design (weekly lane, needs R1)

**What ships:**
- The census flags a type MISCALIBRATED when 3 of its last 5 closes were false-alarm, by-design, superseded, or routed to another owner.
- The weekly lane must then either recalibrate its trigger with a fixture built from the false fires, or move it to the digest.
- Starting set: Family Fare catalog degrading, on-sale no fallback, Walmart capture aging, Family Fare carried item.

**Bar:** each retuned type fires on at most 2 of the next 14 days, AND its known real positives still fire on replay. Example: the 08-30 Family Fare throughput drop, which that day's notes called "RIGHT and its trigger is sound".

### Phase 3: review intake becomes a packet, not alerts (money lane, needs R1 = A)

**What ships:**
- The five bucket-1 types write to `grocery/out/review-packet.json` instead of calling send-alert. Daily triage works the packet the way it works Class C items today.
- Automatic adjudication runs first:
  - a flag that is the footprint of an earlier ruling (09-10's donuts +74% was the previous day's exclude working)
  - an acknowledged flag still inside its expiry
  - a move a committed routing artifact already predicted
- Only a crown change, or a move beyond the commodity's band, on a live cell that adjudication could not explain, pages.

**Bar:** those five types page on at most 4 of 14 days, while the packet carries every row the alerts used to. The census checks row-count parity.

### Phase 4: prevention, not repair (triage contract, needs R3)

**RETURNS ARE FAILURES.**
- `triage-due.ps1` prints RETURN for an open item whose type was closed in the last 30 days, naming the prior close ids.
- `validate-triage-plan.ps1` requires a RETURN item to carry `prevention`, with three parts:
  - the upstream source that produces the class: a capture builder, the ingest parser, or the rule schema;
  - `prior_closes` naming every earlier close of that type, checked against the queue;
  - a fixture built from ALL the prior occurrences, not only today's.
- For a type that has returned twice, a rule or an exclude alone does not satisfy it.

**THE WEEKLY LANE PLANS AHEAD.**
- Each week it takes the top recurring class from the census and writes a prevention plan, whether or not that class fired that day.
- Success is that type's days-fired over the next 14 days against the prior 14, stated with both counts.

**Seed prevention candidates, from the evidence above:**
- **P1. Ad-line shapes at ingest.**
  - Covers:
    - "A, size or B, size" lines (queue 2026-09-10-582032; the 08-31 romaine-or-cauliflower line)
    - reward lines published as prices (09-07)
    - multibuys
  - One ingest parser splits or refuses these before any matching rule sees them.
- **P2. A basis contract at capture.**
  - Every row declares its size kind (weight, volume or count) and where the size came from (label, name or derived). A derived size is never divided on.
  - This is the class behind every GUARDS FAILED day listed in section 3, and behind residual 2026-09-10-c8eb72.
  - It goes first because it is the only class that has held the whole board.
- **P3. Product kind from the store's own category, not from exclude tokens.**
  - Walmart's breadcrumb already proved a frozen bag on 09-01, and the semantic sweep already embeds every product to FIND invisible ones.
  - Unmeasured: whether either signal can REFUSE a wrong kind before it wins a cell.
  - Per-product exclude tokens are how each of these cost a day: Belvita, KIND, Honey Boy salmon, a pistachio ice cream and a gruyere chicken sausage.

### Phase 5: stop self-inflicted alerts (ops lane, no ruling)

**What ships:** a triage or dev push that touched a guard, a fixture, or test-auditors' inputs runs `test-auditors.ps1` before pushing. `ops/run-gates.ps1` does not reach it: queue 2026-09-10-4ac6ae went red past a clean pre-push gate.

**Bar:** zero guard-blind alerts traced to an in-flight triage edit over the following 30 days.

## 5. Order

1. This week, no rulings needed: Phase 0, then Phases 1 and 5.
2. After R1: Phases 2 and 3.
3. After R3: Phase 4, starting with P2.

If alert-free days have not moved after Phases 1 to 3, the long tail is the problem, and the census ranking
will say which part of it.

## 6. What this plan does not change

- Guards stay blocking and fail closed.
- No threshold is loosened to buy a quiet day. A quiet day bought by silencing a real positive is this plan failing, which is why every recalibration replays its real positives.
- Triage still fixes today's instance today. Prevention is added to that, never swapped for it.
