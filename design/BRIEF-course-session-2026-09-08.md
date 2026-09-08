# BRIEF: the course session

**Written 2026-09-08 by the orchestrating session that ran the last four course lanes.** You are one
of two sessions running in parallel. Read the boundary first: the two of you can corrupt each other's
work in exactly one way, and it is avoidable.

## Your territory, and the two things you must not do

**You own the knowledge store, `C:\Users\Owner\.claude\skills\`, and its git repository.** Route
course material there and commit there.

**You must NOT commit the `C:\Codex\ThriftyCrew` repository.** The backlog session owns it and is
actively changing it. Two sessions committing one repo with no coordination is the defect this
estate spent 2026-09-08 fixing one level down.

**You must NOT run `ops\run-gates.ps1`.** It judges estate code you do not touch, while the other
session edits it. A red you cannot attribute is worse than no gate.

**The one thing you write in the estate repo is a drop-box file per lane**, and you leave it there:

```
C:\Codex\ThriftyCrew\design\backlog-inbox\<lane>-<YYYY-MM-DD>.md
```

One finding per `##` heading, a state line under it, **claim no id number**. The states are `OPEN`,
`NEEDS A RULING`, `PARKED`, `PARTLY DONE`, `DONE` and nothing else. A lane that measured nothing
writes `NOTHING TO FILE` on a line of its own - that is a valid result and it is how "landed with
nothing" is told apart from "never landed". **Do not run the merge and do not edit
`BACKLOG-course-findings.md`.** The backlog session merges and commits them.

## Your gates

`check-skills.py` and `build-catalogue.py`, run **once, by you, after the last lane lands** - never
by the lanes themselves while siblings are editing the files those judge. Read the exit code
unpiped.

## The work

**11 courses remain in `skills\course\QUEUE-6.md`.** `skills\course\orchestration.md` is the
procedure and its spawn prompt is current - it carries the drop-box convention and the rule that
lanes do not run shared gates. Follow it rather than this brief, which only covers the boundary.

**Four things learned on 2026-09-08 that will cost you if you rediscover them:**

- **Check every Packt slug before spawning its lane.** Two of this queue's Packt entries 404'd
  because the slug was written without its five-character hash suffix. Six unworked Packt entries
  remain and all are suspect. A slug that 404s costs minutes; one that resolves to the WRONG course
  costs an hour and files material under the wrong name.
- **Grep the ledger for a slug before queueing or re-running it.** Two already-worked courses were
  queued because nobody did. `check-skills.py` now fails when a ticked course has no ledger entry
  naming its slug, so the ledger entry is not optional.
- **Lanes must not write `LEDGER.md` or `QUEUE-6.md`.** Shared append targets, no lock. Have each
  lane put its ledger-entry content in its report and write them yourself, after they land.
- **You cannot message a running lane.** The tool for it is removed on this surface. Everything a
  lane needs goes in its spawn prompt; anything you discover mid-run is verified when the lane lands.
  `TaskStop` does work, so a lane that has clearly gone wrong can be stopped and re-spawned with a
  corrected prompt.

## The consolidation trigger is not deferrable

`consolidation-due.py` fires on every tenth course. **If a trigger is live, you consolidate the named
domain BEFORE spawning the next course** - `skills\course\CONSOLIDATE.md` is the procedure, and it is
its own session's worth of work. The rule exists because the trigger fired unheeded at 40 courses
once and four domains crossed the size limit before anyone noticed.

The `experiment-craft` consolidation of 2026-09-08 is the worked example, and two things from it are
worth copying: move definition out of the core BEFORE writing the new core, which is what stops the
overshoot; and take the mandated three-term search check seriously, because that step is what found
"cause" to be a homonym losing its own query to another domain.
