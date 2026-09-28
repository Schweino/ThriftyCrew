# Q-coverage-worklist-executor: who applies the matching worklist's decided rule changes?

**The question.** Each day the matching worklist collects products the board mis-files or misses (a stuffing mix
filed under onions, sourdough crackers filed under flour). Once a key is decided as "release" or "widen", the fix is
a change to `grocery/commodities.json`, and the tool that makes it safely is `apply-coverage-batch -FromWorklist`.
The daily page tells the reader that "the weekly lane" runs it. **Nothing does.** Should it run on a schedule by
itself, or stay a hand step with a named owner?

Raised by queue items 2026-09-26-564dc6 and 2026-09-27-c744ba. Source: `grocery/triage-plans/plan-2026-09-28-13.json`.

## What I checked (2026-09-28)

- **Who runs it.** `-FromWorklist` is named in `check-ad-cycles.ps1` (the page text), `match-worklist-lib`,
  `resolve-match-worklist`, `audit-band-refusals` and the verdict ledger. No scheduled task, no runner script and no
  agent definition calls it.
- **How often it has run.** The verdict ledger (`grocery/match-verdicts.json`, 68 keys before today) records 6 outcomes
  from `-FromWorklist`, all on 2026-09-23 (5 applied, 1 reverted), from a hand run in that day's triage. It has not run
  since, until today's hand run in this triage.
- **What piled up meanwhile.** Before today's run, 6 decided release or widen keys were waiting: one decided by hand on
  2026-09-25 in plan-2026-09-25-8, whose own reason says "the weekly batch applies this exclude" (Lay's Honey Barbecue
  Potato Chips, filed under honey, three days waiting), two from 2026-09-27, two decided today, and one
  already fixed by hand in another commit whose key was still listed. The coverage page (item 564dc6) has fired as a
  new queue item 9 times since 2026-08-31 (its `prior_closes` list) because nothing drains the list.
- **What the tool guarantees.** Every batch rebuilds the board and runs the crown diff, coverage delta, known-wrong,
  tile-integrity and guards gates, and puts `commodities.json` back if any of them fails. What it does NOT do is
  accept the match-soundness baseline: after a batch that moves any product, the daily publish HOLDS the board until
  someone reads the moved list and runs `audit-match-soundness.ps1 -Accept`.
- **How good the automatic decisions are.** For coverage rows the classifier writes the release or widen itself. For
  contested rows it only suggests, and plan-2026-09-25-6 measured those suggestions wrong on 2 of 11. Today one
  suggestion was wrong again: it proposed releasing "Del Monte Whole Green Beans No Soy Teriyaki" to teriyaki sauce,
  when canned green beans is right.

## Options

- **A. Schedule it (weekly, unattended).** Decided keys stop piling up and the page stops re-firing. The cost: a rule
  change to the file every price depends on ships with nobody reading it first, including the classifier's own coverage
  decisions, and any batch that moves a product holds the next daily board until a person accepts it. So the board
  could go stale over a weekend because of a change nobody asked for that day.
- **B. Keep it a hand step and give it a named owner and cadence.** The money-lane triage developer runs
  `-FromWorklist` whenever a coverage or contested item reaches it (as today), and the page text names that owner
  instead of "the weekly lane". Nothing changes the rules unread. The cost: keys still wait for a triage run, and a quiet
  week lets them pile up.
- **C. Schedule a dry run only.** A weekly `-FromWorklist -WhatIfOnly` measures the pending batch and pages the result
  (what would move, what each gate says) to the money lane, which then applies it by hand. Keys cannot sit unnoticed, and
  no rule changes unread. The cost: one more weekly page, and about one board rebuild of machine time each week.

**Recommendation: C.** It closes the "nothing notices" gap that made this item recur nine times, without letting an
unread matching rule reach a paid board. The page text should change with it, so it names what actually runs.
