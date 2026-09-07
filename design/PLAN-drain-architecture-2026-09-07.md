# PLAN - the estate models producers and artefacts, and has no model for BACKLOGS

**Status: DRAFT FOR BRAD. Nothing here is built.** Written 2026-09-07 after 120 corrected recipe
cards were found sitting unpublished for five days, and the question "how can we scale if it requires
me" turned out to have a precise answer.

---

## 1. The finding, stated exactly

`propagate-recipes.ps1` last ran **2026-09-02 14:56**. Since then 120 specs accumulated real content
changes - the scaler fix that had reached 33 of 584 cards, seventeen recipes whose macros came off the
wrong panel, the Shop Smart bullet change on 49 - and readers have been served none of them.

**Nothing was broken.** Every component worked. The spec hash is accurate, `cost_ps` and
`costPerServing` are correctly masked so a daily reprice does not republish 584 cards, and the dirty
set is exactly right. The corrections were *made*; they were never *shipped*.

**And nothing could have told us.** `grocery/expected-automations.json` exists precisely to catch
silent death, and `health-heartbeat.ps1` reads it daily from the watchdog. It watches three kinds:

| Kind | Question it answers |
|---|---|
| `windows_tasks` | did the producer run? |
| `output_files` | is this artefact fresh? |
| `output_globs` | is this artefact family fresh? |

**A queue is none of those.** When `propagate` does not run it produces no stale artefact - it
produces *nothing*, and the pending set grows in silence. There is no producer that failed and no file
that aged. The registry is structurally blind to it.

> **The gap in one line: this estate models PRODUCERS and ARTEFACTS. It has no model for a BACKLOG.**

---

## 2. Why this is the scaling answer and not just a bug

Three different things currently stop and wait for Brad, wearing the same costume:

1. **JUDGEMENT** - genuinely his. *Does a verdict-only agent lose `Write`?* *Is generic culinary
   comparison acceptable house voice?* Four of these were put to him on 2026-09-07 and all four were
   correct asks. **Automating these away is the failure, not the goal.**
2. **AUTHORISATION** - a decision already made, never written down. Publishing 120 corrected cards is
   not a fresh judgement 120 times; it is the same call repeatedly, and it is automatable the moment
   the rule is stated.
3. **ABSENCE** - nothing invokes it, so it waits for a human to wander past. **This is not a decision
   at all**, and today it was mistaken for one.

Category 3 is the whole of the propagate gap, and it has appeared **five times in one day**:
`propagate` (unscheduled), `rebuild.py --verify` (zero callers), `golden-test.ps1` (was ungated),
`audit-twin-drift` (sat red for weeks), and the pipeline committer bound to the entry point rather
than the work. That is not five bugs. It is one absent property showing up five times.

---

## 3. What NOT to do

- **Do not auto-publish.** That removes a decision from Brad to fix a visibility problem, on a live
  paid site. Wrong trade.
- **Do not build a scheduler.** One exists: five Windows tasks plus `health-heartbeat` on a daily
  trigger. The problem is what it can express, not that it is missing.
- **Do not add another call to `check-ad-cycles.ps1`.** It is 3,110 lines and already invokes eight
  child processes, three of them added on 2026-09-07 by me. That file has become the de facto
  scheduler by accretion, and the path of least resistance perpetuates exactly the problem this plan
  is about.
- **Do not rewrite the spec/build/propagate design.** It is sound. Incremental, idempotent, with an
  accurate dirty set and correctly masked machine fields.

---

## 4. The change - rung 1: teach the registry about queues

Add a fourth kind to `grocery/expected-automations.json`:

```json
"queues": [
  { "name": "recipe specs awaiting propagate",
    "count": "spec-hash != propagate-stamps.json",
    "age_from": "the oldest commit touching a dirty spec",
    "max_age_hours": 72,
    "cost_if_undrained":
      "corrected cards are on disk and readers are served the old ones. On 2026-09-07 this was 120 cards and five days." }
]
```

`cost_if_undrained` is the field this estate keeps needing and never has: **what it costs when this
does not happen**. `windows_tasks` entries carry a `why` that says what the task does; none says what
is lost when it does not run, which is the number that decides whether anyone should care.

`health-heartbeat.ps1` already runs daily and already reads this file, so **the check inherits an
existing trigger**. No new schedule, no new framework, no new call in `check-ad-cycles`.

**Queues to declare, all of them the same shape and all currently unwatched:**

| Queue | Where | What it costs undrained |
|---|---|---|
| specs awaiting propagate | spec hash vs `propagate-stamps.json` | readers served stale cards |
| staged Ghost writes | `ops/staged-writes.jsonl` | an agent's work never lands |
| open triage items | `grocery/triage-queue.json` | a live alert nobody answered |
| hunter review packet | `graph/learning/hunter-review-packet.json` | learning that never promotes |
| unbid ingredients | the worklist | recipes that cannot be priced |

**Cost: small.** One JSON kind, one function in `health-heartbeat`, fixtures both directions. No
behaviour changes anywhere - it turns an invisible gap into a number, and the publish decision stays
Brad's.

---

## 5. Rung 2 - a stated drain POLICY per queue (category 2)

Rung 1 makes the backlog visible. Rung 2 is what stops it needing Brad every time, and it is a
**ruling** rather than a build: for each queue, what may the machine drain by itself?

For the propagate queue the policy has to answer:

- must `run-gates` be green? (almost certainly yes)
- must the feed-coverage gate pass? (`propagate` already refuses without it)
- is there a cost-movement bar above which a card holds for review?
- do NEW cards - never published - stay excluded? (`propagate` already treats create as a separate
  authority, for a measured reason: on 2026-08-16 the dirty set was 49, of which 21 had never been
  published and three had been rejected hours earlier)

**Staging is the mechanism and it already exists.** E1 built it; I21 armed it for agent runs on
2026-09-07. Extending it to the publish path turns 120 decisions into **one**: the machine does the
work, queues the irreversible part, Brad approves a batch. That is category 2 solved without giving up
control of a live paid site.

---

## 6. Rung 3 - one decision queue (category 1)

Judgement calls should arrive as a list read once a day, not as discoveries scattered through fifteen
hours - which is how all four of 2026-09-07's rulings actually reached Brad.

**This half exists.** `NEEDS A RULING` is a state on the backlog board and
`ops/audit-backlog-status.ps1 -Summary` already prints it. What is missing is that everything needing
Brad lands there - a staged write awaiting approval, a queue past its age, a contradicted price claim -
rather than only backlog items.

---

## 7. The honest limits

- **Accountability cannot be automated away.** It is a live paid site with Brad's name on it. Someone
  owns "is this right". What changes is whether that ownership costs minutes a day or is the
  bottleneck on everything downstream.
- **Legibility is part of scaling.** Automation that accretes without structure eventually needs Brad
  again, to understand it. A 3,110-line script with eight children is already at that edge.
- **Rung 1 fixes nothing on its own.** It makes a gap visible. That is deliberate: on 2026-09-07 every
  problem worth solving was a measurement nobody had taken, and every one became tractable the moment
  it was a number.

---

## 8. What is being asked of Brad

1. **Is publish-on-demand a deliberate safety decision, or an oversight?** This plan assumes oversight.
   If it is deliberate, rung 1 still applies (the backlog should be visible either way) and rungs 2
   and 3 change shape.
2. **Rung 1 - build it?** Small, no behaviour change, closes the visibility half for five queues.
3. **Rung 2 - the drain policy.** Needs the four answers in section 5 before anything is built.
