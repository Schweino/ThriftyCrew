# Plan: stop paying full price for the same alert twice

Written 2026-09-20. Supersedes the first draft of this file, which aimed at alert VOLUME. Brad's
clarification redirected it: the problem is not that alerts fire, it is that we spend heavily
resolving them and they come back, which means we are fixing instances and not classes.

Read this and edit it before anything is built.

## The measurement of the complaint

From `grocery/triage-plans/cost-ledger.jsonl` (5 triage days) and `grocery/audit-alert-census.ps1`:

| Reading | Value |
|---|---|
| Tokens spent on triage, 5 days | **6,691,421** |
| Items worked | 86 |
| Items that changed the board | 26 |
| **Tokens per board change** | **257,362** |
| Alerts in 30 days | 360 |
| **Alerts that were a type triage had already closed** | **121 (34%)** |
| Types doing the returning | 27 of 103 |

Brad is right, and there is a number for it: **one alert in three is a repeat of something triage
already closed.**

## Why they come back, from our own plan files

Every plan item carries an outcome status. Across 2026-09-10 to 2026-09-20:

| Status | Count | What it means |
|---|---|---|
| `done` | 20 | the fix shipped as planned |
| `deviated` | 17 | something shipped, but not what the plan specified |
| `needs-more-time` | 9 | the item hit its ceiling unfinished |
| `superseded` | 5 | folded into another item |
| `bounced` | 4 | handed back for re-diagnosis |
| `blocked` / `needs-brad` | 2 | genuinely waiting on something |

**Of 52 real work outcomes, only 20 are a clean `done`.** Half are `deviated` or
`needs-more-time`, which both mean the root fix as specified did not fully land.

Today's own plan is the worst case on record: of six items, one `done`, one `superseded`, one
`needs-more-time`, and **four `deviated`**.

The return chains follow directly, and each one is checkable:

- `2026-09-18-f90ba6` closed **`needs-more-time`**. It returned today as `b66b54`, and its prior
  plan's own must-fire case named the exact audit that failed today.
- `2026-09-18-35e0f5` closed **`done`**. It returned the **next day** as `4fc24c`.
- `2026-09-19-4fc24c` closed `needs-more-time` on 09-19, was never worked on 09-20, and is open now
  for the third consecutive day.
- `2026-09-19-d240fd` closed **`deviated`** today and returned **the same day** as `fb37b9`.
- `plan-2026-09-18-3.json` carried an item literally named
  `prevention:grocery capture watchdog issue s`, and closed it **`needs-more-time`**. The capture
  watchdog has fired on 20 of the last 30 days and returned again today as `7bac4b`.

That last one is the whole diagnosis in one row: **the prevention item itself was left unfinished,
and the thing it existed to prevent kept firing.**

## The holistic cause

The estate already has good root-cause machinery and it is not the gap. `validate-triage-plan.ps1`
has demanded a `root_fix` (or a written `root_fix_none_because`) plus a `must_fire_case` and a
`clean_twin` on every code item since 2026-09-03. RETURN detection, `prior_closes`, `prevention` and
`fixture_occurrences` all exist. Today's ROUTE mechanism correctly skipped the reviewer for two
returning items.

**The gate checks that a root fix is DESCRIBED. Nothing checks that it SHIPPED.** An item can carry
a precisely specified class fix, ship a partial version of it, close `deviated`, and satisfy every
gate. The queue item closes. The class survives. The alert returns, and the next run pays a fresh
reviewer diagnosis for it.

Second, the per-run ceilings (money 200 calls, ops 100, weekly 40 per item) are applied to a run
that takes on everything the queue holds that day. Today's run took six items and finished one. The
ceiling does not reduce work, it fragments it: six items each 80 percent done produce six items that
can return, where two items fully done produce zero.

That is a feedback loop. Unfinished items become returns; returns add to tomorrow's queue; a bigger
queue means less budget per item; less budget per item means more unfinished items.

## The changes, in the order they pay

### 1. An item whose root fix did not land does not CLOSE

> **REVERSED BY BRAD BEFORE IT WAS BUILT, 2026-09-20, and what SHIPPED is below this box.** The section
> as written is wrong and is kept so the reasoning is on the record. The queue's `disposition` answers
> "was the ALERT RIGHT" (confirmed / false-alarm / superseded / by-design / wont-fix, `grocery/triage-lib.ps1`'s
> own header) and exists so a detector's live precision becomes knowable. Whether the FIX FINISHED is a
> different axis and lives in the plan item's `status`. Blocking a close on plan status would jam the two
> axes together and corrupt the precision measure that field exists for.
>
> **What shipped instead: the close is unchanged, and unfinished work becomes VISIBLE and DUE.**
> `Get-TriageUnfinished` in `grocery/triage-return-lib.ps1` returns one record per queue item whose NEWEST
> plan item closed `deviated` or `needs-more-time` (newest wins by `Get-TriageReturnRoute`'s own walk, and
> the lane by `Get-TriageRouteLane`). `grocery/triage-due.ps1` prints them as a `RESUME` section ABOVE the
> DUE list, and RESUME work alone makes the run DUE. An item still `open` is today's work, not unfinished
> work; a `needs-brad` item is parked on a ruling and is never re-triaged. IDLE keeps its meaning otherwise.
> On the day it landed the live run named 9 unfinished root fixes that nothing else in the report could see.

Today `deviated` and `needs-more-time` still close the queue item. They should not.

A queue item closes only on `done`, `superseded`, `by-design`, `false-alarm` or `needs-brad`. On
`deviated` or `needs-more-time` it stays **open**, carrying a pointer to its plan item as the resume
point, and it is the next run's first work, ahead of any new alert.

This is the single change that breaks the loop, and most of the machinery exists: the ROUTE lines
added 2026-09-20 already tell a lane to resume from a prior plan item instead of re-diagnosing. This
makes that the default for unfinished work rather than something rediscovered by the census.

Blast radius: `grocery/triage-close.ps1`, `grocery/triage-due.ps1`, `grocery/triage-lib.ps1`. Needs
a MUST FIRE that a `deviated` close leaves the item open, a MUST NOT FIRE that a `done` close still
closes it, and a CLEAN TWIN that `needs-brad` parking is unchanged.

Cost effect: a resumed item skips the reviewer. Today's reviewer cost 408,197 tokens.

### 2. Fewer items, finished

Replace the per-run call ceiling with a **completion target**: a run takes the smallest number of
items it can finish, in the order STEP 0.75 already ranks them, and stops taking on more when the
remaining budget cannot finish another one.

Two items fully done beats six items 80 percent done, because the four unfinished ones return at
full diagnosis price. On today's numbers that trade is 257,362 tokens per board change against a
return costing roughly a reviewer run to re-derive an answer a committed plan already held.

Blast radius: the scheduled-task SKILL only. No code. Reversible immediately.

### 3. Make the return rate the scoreboard number

`grocery/audit-alert-census.ps1` already computes and prints returns (121 of 360). The scoreboard's
stated targets are quiet days: 3 a week by 2026-10-08, 5 by 2026-11-05.

Quiet days are the wrong target twice over. They measure volume, which is not the complaint, and
they are arithmetically near-unreachable: with 103 active types, a quiet day needs all 103 silent,
which back-solves to a per-type daily fire rate of about 2.6 percent today. The store's own rule is
that an SLO declared before the data exists is a wish.

Return rate is the number that matches the complaint, is already computed, and is directly moved by
changes 1 and 2. Proposal: keep printing quiet days as an observation, and make **return rate the
target**. Current 34 percent; first target worth stating only after two weeks of data under change 1.

### 4. Only then, the volume work

The first draft of this plan proposed a pending/duration state in `send-alert.ps1` so a condition
must hold N runs before it pages, and re-testing the 77 page-class types against "does a human have
to act". Both are still worth doing and both are cheaper than they look. But they reduce how many
alerts arrive, not how many come back, so they go after 1 to 3 rather than before.

## What this does NOT do

- No detector's sensitivity changes. No band, ratchet or guard threshold moves.
- Nothing is silenced. Every condition still reaches the queue.
- `guards.ps1` and `test-auditors.ps1` are untouched. A board that should be held is still held.

## Expected result, as a checkable claim

If change 1 lands, the returns caused by unfinished items should stop, because those items never
close and so can never be counted as a return. That is most of the 121: of the return chains traced
above, four of five originate in a `needs-more-time` or `deviated` close.

The residue is the harder class: `2026-09-18-35e0f5` closed `done` and returned anyway. That is a
genuinely insufficient root fix, and only change 4 plus better diagnosis touches it.

My estimate is that changes 1 and 2 take the return rate from 34 percent to somewhere between 10 and
18 percent, and cut tokens per board change by roughly half. That is a first plausible number from
one 5-day ledger, not the survivor of a sweep. The way to find out is to land change 1, leave it two
weeks, and re-read the census and the ledger.

## Open questions for Brad

**Q1. Should an unfinished item block new work?** Change 1 makes resumed items the next run's first
work. If a day brings a page-class alert about a wrong price while three resumed items are queued,
does the new alert jump the queue? I would say yes for anything reader-facing or money-touching, no
for everything else, and that STEP 0.75's existing tiering already expresses it.

**Q2. Is there a cap on resumes before it becomes a ruling?** An item that has been resumed three
times is telling us something the plan machinery cannot fix. I would escalate it to needs-brad with
its history rather than resume a fourth time.

**Q3. Do you want change 4 at all,** given it reduces arrivals rather than returns? It is the only
part that makes the daily mail quieter in the short term.

## Knowledge consulted

Searched: "alert fatigue threshold", "firing check is not an alert", "silence a check safely",
"guard hard fail publish held", "guard blind fixture live twin".

- `data-quality-craft/checks-and-thresholds.md` section 7, "A firing check is not yet an alert".
  Source of the three-state inactive/pending/firing model behind change 4, of the rule that duration
  is a different knob from the cutoff, and of the operative test that an alert is only warranted
  where a human has to act.
- `reliability-craft/MAP.md` section 4, "An alert is not a check that fired". The routing half: page,
  panel or log line.
- `reliability-craft/applies-here.md`, "The scoreboard". Source of the SLO-before-data rule used in
  change 3, and the record that `audit-alert-precision.ps1` is designed with no number yet.
- `software-craft/applies-here.md`, "A guard that exists and reads green while its defect is live".
  The 21-incident family that is why nothing in this plan lowers a detector's sensitivity.

Read on disk rather than assumed: `grocery/triage-plans/cost-ledger.jsonl` (21 rows, 5 dates),
every `plan-2026-09-*.json` item status, `grocery/triage-queue.json` (46 items, 26 resolved, 0
undispositioned), `grocery/triage-close.ps1` (refuses without a disposition, five legal values),
`grocery/alert-registry.json` (116 entries, 77 page / 38 review / 1 digest).
