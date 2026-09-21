# INCIDENT 2026-09-19 - the 'grocery new price flag s' alert was confirmed right 3 times in 30 days

Status:      RESOLVED at the emitter 2026-09-21; the recurrence itself is a ruling (Q-fccb69-unit-of-triage)
Trigger-Key: alert-confirmed:grocery new price flag s:2026-09
Severity:    Time, and a week of one wrong price. The alert is review class and never mailed, so its cost is triage: it
             fired on 22 of the 30 days ending 2026-09-21 and each day was a queue item a person or an agent had to
             read line by line (251 flag lines over 20 sends from 2026-08-22). The reader-facing harm was in what it
             found, not in the alert: a Hy-Vee fuel-saver clause published as laundry pods at $0.10 a pod from
             2026-08-31 to 2026-09-06, and wrong products (a snack bar, a chowder, donut holes) holding a cheapest
             cell for about a day each before triage removed them.
Detected:    2026-09-19T11:46:44Z, by ops\incident-trigger.ps1 (alert confirmed x3) reading the event bus (lib\event-bus.ps1)
Resolved:    2026-09-21, grocery/triage-plans/plan-2026-09-21-6.json (queue 2026-09-19-fccb69)
Author:      the money-lane developer, 2026-09-21

## Timeline

- 2026-09-10T18:31:12Z  alert-closed 2026-09-10-b91a0a: confirmed
- 2026-09-11T20:04:56Z  alert-closed 2026-09-11-3b246c: confirmed
- 2026-09-18T18:24:18Z  alert-closed 2026-09-18-61f76c: confirmed
- 2026-09-19T11:46:44Z  this draft opened
- 2026-09-21            root cause measured over 18 board versions; the emitter fix, fixtures and this record shipped together

**The gap between the first sign and this draft: 8.7 day(s).** The honest reason nobody acted sooner is that each
close WAS right. Every close ruled that day's flags one at a time, and the next day's flags were different cells, so
nothing about any single close looked like a failure. The machine could see the type returning; the RETURN gate could
not see two of its three closes (below), so the 2026-09-18 close was allowed through as a first-timer.

"Confirmed" also overstates what the three closes found. Two held a defect (coconut and shrimp, both wrong products).
The third, 61f76c, confirmed that two flagged prices were REAL: an Aldi shelf move and a Fareway ad sale. The census
records two more confirmed closes of this type in the window (2026-09-07 laundry pods, 2026-09-09 donuts) that the
event bus, which records closes only from 2026-09-10, never saw.

## Root cause

Two mechanisms, both measured by re-running the real grocery/sanity-check.ps1 at the old and new blob over all 18
board versions of 2026-08-23..2026-09-21 (one row per flag per arm; the harness and blobs are in the plan).

1. **The emitter read every move of the cheapest as an event about a price.** sanity-check flags `wow` when the
   cheapest moves more than 40 percent against price-history's previous week. The cheapest moves when a price changes,
   and ALSO when the set of rows on the cell changes: a store drops off the cell, or a store comes back. Of 124 wow
   flags, 32 (26 percent) were only that, with the new cheapest a price the board already carried; on 2026-09-17 a
   store-churn build produced 14 of its 30. They were, in the language of the anomaly taxonomy, a change in the
   population, and flagging them is the detector being wrong at volume.
2. **The alert's unit is the day's batch.** Any day that brings one new outlier or one unexplained move re-opens the
   type, and the RETURN rule scores it as a failed fix of yesterday's close however right that close was. The outlier
   arm is where every confirmed defect of the window lived, and it has no referent that could explain an outlier away:
   0 of 677 paging outlier instances carry a store-published unit price (the 401 that do have been quiet as
   `outlier-verified` since 2026-09-04).

## The class

A detector that pages on a DIFFERENCE between two states of the board without asking whether the difference is a
change in what was measured or a change in what was included. Price moves are one instance; any week-over-week or
build-over-build comparison in this estate that reads only the headline number (the cheapest, a count, a total) has
the same exposure, because every rebuild and every capture gap changes the population under that number.

And a second, smaller class found on the way: **a record that two things read, rewritten by one of them only.**
price-history.json's entry for a week is written by update-history from the morning build; a later hand or triage
rebuild rewrites comparison-<week>.json under the same name and leaves the history as it was. The two records of one
board then disagree (71 of 7,401 commodity-weeks in the window), which is the estate's most common root cause (two
copies of one fact).

## Corrective actions

### Preventive

- grocery/sanity-check.ps1: `Get-WowExplanation`. A move is recorded as the quiet type `wow-explained` only when the
  previous board accounts for both ends: the new cheapest is the same item at the same 4 dp per-unit its store carried
  (or, for a store absent from the previous board, its last recorded per-unit), and the old cheapest is still there at
  the same price or left the cell as an everyday row. Every other wow stays `wow` and names what is unexplained.
- grocery/check-ad-cycles.ps1: `wow-explained` joins the quiet ALLOWLIST (an unknown type still pages).
- **Deliberately NOT done: a sale ending is not an explanation.** 11 of 124 wow flags were a sale row leaving, and one
  of them, laundry pods on 2026-09-07, was the only trace of a wrong ad price that had been live for a week (33 percent
  under its runner-up at the start, below both bars). **And no threshold moved**: the 35 and 40 percent bars and the
  outlier arm are exactly as they were.

### Detective

- grocery/test-auditors.ps1 unit u144: MUST FIRE on the frozen laundry-pods, coconut, shrimp and bouillon rows and on
  an older price coming back; MUST NOT FIRE on the frozen adobo and caraway store-churn moves and in the pager region;
  CLEAN TWIN on the frozen apples shelf move (still pages, with its reason); a case at the 4 dp bar and one step past.
- Each surviving wow now carries its reason in the flag line, so the reader of the queue sees WHY it was not explained.

### Responsive

- Filed weekly: 2026-09-21-57e5ae (the 18 moves the filter cannot explain because the history and the previous board
  disagree, and the type still paging on most days) and 2026-09-21-594c27 (169 resolved queue ids across 68 types were
  moved into grocery/out/archive/triage-queue.archived-2026-09-17.json inside the 30-day window, so the RETURN gate
  cannot see them; that is why the 2026-09-18 close recorded no prior closes).
- Ruling asked of Brad: Q-fccb69-unit-of-triage (one queue item per flagged cell at a mean of 7.6 a day, or exempt this
  review intake from the RETURN rule, or leave it).

## What worked

- The flag found real defects: ten defect cells in the window by the closes' own counts, every one surfacing as an
  outlier, as a move to a new price, or (laundry pods) as a sale row leaving, and every close fixed its own at cause.
- `outlier-verified` (2026-09-04) had already taken the referent-verified outliers off the page; the log's '30
  store-verified outlier(s) ... not paged' was exactly that set, which is why hypothesis (b) had nothing left to act on.
- Running the change over the real history before claiming anything: the first run of the filter explained 0 of 124
  moves (a PowerShell 5.1 [string] parameter turned $null into ''), which a fixture-only check would have missed.

## Accepted risks

- An everyday crown that was itself wrong and then left the cell is now quiet when it leaves. It is already off the
  board at that moment, and audit-capture-eviction watches a cell left dearer than its eligible rows allow. Measured:
  no defect of the window had this as its only trace.
- The type will keep firing on most days (15 of 17 simulated board versions after the fix, against 15 before) until
  Brad rules on the unit of triage. The volume falls (pager-visible flags 801 to 769; simulated new flags 149 to 129),
  and one version rose (2026-09-11, 3 to 7) because four pages moved two days later, each paging once either way.

## Independent re-review

Not yet done. What a re-reviewer should check: that `wow-explained` rows in grocery/out/guards-*.json over the next
14 days are store churn (a store left or returned and nothing about a price changed), and that no triage close in that
period finds a defect whose only trace was a quieted move. Measure the days fired and the new-flag counts for the 14
days after 2026-09-21 against the 14 before, both stated.
