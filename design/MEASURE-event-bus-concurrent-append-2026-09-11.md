# Does the event bus lose events when several processes write at once

**Question.** `lib\event-bus.ps1`'s `Write-TcEvent` appends to the bus through
`New-Object IO.StreamWriter($p, $true, ...)`, which opens the file with a share that denies other writers, and
it swallows every error and returns `$false`. A bare `Add-Content` with the same kind of open landed 13 of 200
lines with 2 processes and 5 of 1,200 with 4 (`lib\append-line.ps1` header). `Write-TcEvent` was never
measured. Its producers include `ops\run-gates.ps1` (one per push, and several sessions push from this box),
`lib\ledger-lock.ps1` and `meal-prep\pipeline\source-domains.ps1` refusals (written exactly when writers are
contending), so concurrent producers are plausible.

## The acceptance bar (written 2026-09-11, BEFORE any trial ran)

**Design.** N child processes each dot-source a copy of `lib\event-bus.ps1` and call the real `Write-TcEvent`
E times against one temp bus passed through `-Path`, never the live bus. One row per trial per arm.

- Cells: W = 1 (the control), 2, 4 and 8 writer processes; E = 200 events per writer; 5 trials per cell per
  arm. The event is ~250 characters of JSON.
- **Overlap is proven by rendezvous, never by a clock.** Every child waits until all W children are ready
  before its first write, and waits until all W children have MADE their first write before its LAST write.
  When every child saw all W first-write markers, every child was inside its write loop at the instant the
  last one began writing, so the writing windows overlapped. No wall-clock bar decides anything; elapsed time
  is recorded as information only.
- Landed is counted from the bus: lines that parse as JSON, carry `kind = measure`, and are DISTINCT on
  (tag, i). Unparseable lines and duplicates are counted separately.
- Arms: `old` is `lib\event-bus.ps1` as committed at the base commit; `new` is the fix, when there is one. In
  the comparison run the arms ALTERNATE trial by trial, so a change in machine load cannot fall on one arm.

**A trial is VALID** when all W children reported and, for W of 2 or more, every child saw all W first-write
markers. An invalid trial is BLIND and counts for neither verdict.

**The harness check.** The W = 1 control must land 200 of 200 in every trial of every arm. If it does not, the
whole run is BLIND and no verdict below is drawn.

**Verdict on the old code.** `Write-TcEvent` LOSES EVENTS UNDER CONCURRENCY if at least one valid trial with
W of 2 or more lands fewer distinct events than it sent. It DOES NOT LOSE THEM AT THIS SCALE only if every
valid W >= 2 trial lands sent of sent AND at least 10 of the 15 W >= 2 trials are valid. That second verdict
would prove nothing about wider contention.

**The fix is accepted** only if all of these hold in the alternated run:

1. The new arm lands sent of sent in EVERY valid trial of every cell: zero lost over the whole run's total,
   zero duplicates, zero unparseable lines.
2. In every new-arm trial `Write-TcEvent` returned `$true` exactly `sent` times and never threw.
3. At least 12 of the 15 new-arm W >= 2 trials are valid.
4. The old arm, in the SAME alternated run, still loses in at least one valid trial. If it does not, the run
   did not reproduce the defect and the comparison says nothing about the fix.

**The boolean must be honest in both arms.** In every trial the number of `$true` returns must equal the
number of events that landed. A `$true` whose line is absent would be a separate and worse defect, reported
whatever else happens.

## Results

(filled in after the runs)
