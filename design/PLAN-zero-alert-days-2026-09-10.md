# PLAN: days with no alerts, and triage that prevents instead of repairs

**Status: RULED 2026-09-10, building in the order of section 7.** Brad's answers to every open question are
recorded in section 7, which supersedes the options in section 1 wherever they differ.

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

## 7. Brad's rulings, 2026-09-10, and the build order they set

| # | Question | Ruling |
|---|---|---|
| 1 | What may page | **Enforced alert registry.** Every alert type is `page`, `review` or `digest`. An unregistered type is never dropped: it still queues, and it pages as a registry defect until someone registers it |
| 2 | Where bad data is stopped | **A row contract at capture, all 7 stores**, shadow first, enforced store by store |
| 3 | Product identity | **Two independent signals must agree** for a crown; 2 weeks in shadow before it refuses anything |
| 4 | Success | **Zero returns within 30 days** for any class that shipped a prevention fix; **3 quiet days a week by 2026-10-08, 5 by 2026-11-05** |
| 5 | A returned problem | **The plan gate demands a fix at the source**, every prior close named, a fixture from every occurrence |
| 6 | Weekly lane | **Prevention first, then leftovers**; every new store, feed or large commodity batch is checked against the row contract before it goes live |
| 7 | Capture limits | **Probe each browser-only store for the data its own page loads**, and Family Fare's term budget; recalibrate only where nothing is found |
| 8 | Muffins | **Two commodities, muffins and mini muffins**, each with an explicit piece-size definition |
| 8b | Brain digest | **Mail only when a stage is red** (an estate half that could not be read counts as red, because unknown is not green) |
| 9 | Start | After all answers, which is now |

### Build order, each with its bar written before it is built

1. **Phase 0, the scoreboard.** `grocery/audit-alert-census.ps1`. Bar: reproduces section 2 from the
   2026-09-10 queue (0 of 20 quiet days, 249 alerts, 25 types on 3+ days, all 25 back after a close), and
   prints progress against ruling 4 with its denominators.
2. **Ruling 8b, the digest.** Bar: an all-green estate sends nothing and queues nothing; a red or unreadable
   stage still sends.
3. **Ruling 7, the store probes** (read-only research, runs beside the rest). Bar: a verdict per store backed
   by a captured network request, or a recorded wall; a CAPTCHA is a hard stop and a verdict, never a bypass.
4. **Ruling 1, the alert registry, with Phase 1's incident key.** Bar: every type in the 30-day queue and every
   `Send-Alert` call site maps to exactly one registry entry; an unregistered subject queues and pages as a
   registry defect (must fire); a registered `page` alert is unchanged (clean twin); a `review` alert lands in
   the review packet with no queue item; the next guard-red morning yields one queue item, not four.
5. **Phase 5, test-auditors before a guard-touching push.** Bar as in section 4.
6. **Ruling 5, returns are failures.** Bar: a RETURN item with no `prevention`, or whose `prior_closes` misses
   a close in the queue history, fails the handoff gate; a first-time item is unaffected.
7. **Ruling 6, the weekly lane re-aimed.** Bar: the lane's first plan names the census's top recurring class
   and states its days-fired for the prior 14 days before any fix.
8. **Ruling 2, the row contract.** Written as a contract document first, then one validator the seven builders
   share, run in shadow for 7 days per store, then enforced store by store in the census's order of returns.
   Bar per store: after enforcement, 0 basis-class guard hard fails from that store over 14 days, and every
   cell the contract empties is one the shadow report already named.
9. **Ruling 3, two-signal identity.** First measure what share of each store's rows carries a usable category.
   Then 14 days of shadow on crowns. Enforce only if a hand-checked sample of at least 30 disagreements is at
   least 80% real wrong products, and enforcement would empty no more than 2% of live cells. Both numbers are
   first guesses, recorded as such, to be revisited against the shadow data.
10. **Ruling 8, muffins.** Through the commodity registrar and the money lane's gated chain. Bar: every current
    muffins row routes to exactly one of the two commodities, no row is lost, guards exit 0, and both cells read
    correctly on the live board.
11. **Phase 3, review intake as a packet,** after the registry exists. Bar as in section 4.

### Progress against the build order (updated 2026-09-10)

- **Step 1, the scoreboard: DONE** (263006cea). It reproduces section 2 exactly and runs daily as a lane in
  `check-ad-cycles.ps1`, plus at the start and end of every triage run.
- **Step 2, the digest: DONE** (263006cea). An all-green estate sends nothing.
- **Step 3, the store probes: DONE** (d94ec7776). See the next section; rulings R11 and R12 are open.
- **Step 4, the registry and one incident per alert: DONE** (9eee1e34b, 7dad4b07a, and 94f80972b for the census
  lane's consumer).
  - `grocery/alert-registry.json` has 96 entries: 65 page, 30 review, 1 digest. The full page list with each one's
    condition is in the file.
  - The check maps 78 readable call-site subjects and 69 queue types over 30 days to exactly one entry each.
  - `send-alert.ps1 -CausedBy guards-hold` folds the watchdog's held-by-guards lines, the board-aging alert and
    the smp-feed edge alerts into the open GUARDS FAILED item. Its fixture replays the 2026-09-10 morning and
    leaves one queue item where there were four.
  - The first live review-class alert, queue 2026-09-10-c069fa, queued with no mail.
  - **Leaves open:**
    - The board.json edge alert in `capture-run.ps1` is not wired to `-CausedBy`; 0 occurrences measured.
    - Four page-class types still fire on 10 or more of 20 days with close notes that mostly say echo, false
      alarm or by design: the capture watchdog, Family Fare catalog degrading, board prices aging, and recipe
      batch stalled. The watchdog's echoes are what 4b folds; the other three are Phase 2's starting set.
  - **Found on the way and filed:** `meal-prep/pipeline/source-domains.ps1`'s concurrency self-test lost 1 of 8
    writes under load and refused a push (1 failure in 4 runs). Weekly-lane queue item 2026-09-10-c069fa.
- **Next: step 5** (test-auditors before a guard-touching push), then step 6 (returns are failures).

### Ruling 7 result: the store probes (`design/PROBE-store-direct-data-2026-09-10.md`)

- **Family Fare: DIRECT DATA FOUND.**
  - A search-free catalog browse returned 18,557 products with price, size and in-stock status for store 6401. At 200 a page that is about 93 requests, against 602 search terms today.
  - **Unknown:** whether browse pages spend the same per-window allowance as search.
  - **Next (build step 3b, ops lane, no ruling needed):** one paced trial window. It records the catalog total against rows received, and whether the next search in that window still succeeds. The quarterly rotation ruling is untouched.
- **Aldi and Fareway: PARTIAL.**
  - Both pages load prices from the same Instacart JSON, with sale, regular and per-unit price as separate fields. At Fareway that would retire four known silent capture defects.
  - **Unproven:** that the In-Store shelf price comes through it, and anything outside the browser session.
  - **Both sites' robots.txt bars every unnamed agent from the whole site.** The browser sweep we run today is already automation against that same line.
  - **Needs a ruling (R11)** before any trial.
- **Sam's Club: NONE FOUND.** The data is already inside the page our capture reads. Keep the current method.
- **Walmart: NOT PROBED, on purpose.** It shares Sam's bot defence, and a cold probe risks the next 08:00 capture for both stores.
  - **Optional ruling (R12):** allow one headed load in the seeded browser profile right after a successful 08:00 run, or leave the question closed.
