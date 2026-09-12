# backlog-inbox - one file per writer, merged by one process

**This directory is normally EMPTY, and that is correct.** It is a drop box, not a store. Files
appear here while a parallel run is in flight and are removed by the merge once their contents have
landed in `BACKLOG-course-findings.md`.

## Why it exists

`BACKLOG-course-findings.md` is a shared file with a shared id counter and no lock. On 2026-09-08
four course agents ran at once, each owing it an item. They were told to report their findings so the
orchestrator could merge them. **Nine findings from three lanes were still sitting in agent reports
hours later.** "Report it and I will merge" is not a mechanism. It is an intention, and an intention
has no exit code.

Brad's fix: every writer gets its own file. No two writers touch one file, so there is nothing to
lock and nothing depends on anyone remembering. A single merge pass afterwards is also a **review
point** - four lanes on one estate produce near-duplicate findings, and this is where they are seen
side by side before they become two items that drift apart.

## Writing a file

Name it `<lane>-<YYYY-MM-DD>.md`. One finding per `##` heading, a state line directly under it, then
the body:

```
## the title, one line, lower case, says what is wrong

`OPEN` `queue-6` `2-WAY` `RUNG1 MEASURE`

**Source.** ...
```

**An OPEN, PARTLY DONE or NEEDS A RULING finding owes two more tags on that line**: a reversibility
(`2-WAY` or `1-WAY`) and a first-rung type (`RUNG1 <READ|MEASURE|DOC|BUILD|RULING|BLOCKED>`). Both
classify the FIRST RUNG, not the whole item. `ops/audit-backlog-status.ps1` fails a heading without
them, so the merge refuses rather than writing one - added 2026-09-09, after it wrote exactly such a
heading for I101 and that gate went red on the next run. A closed state owes neither.

**Claim no id number.** Ids belong to the merge, which is the only process that allocates them, which
is the entire reason they are safe there and were not safe in four agents.

The state must be one of `DONE`, `PARKED`, `NEEDS A RULING`, `PARTLY DONE`, `OPEN`. That vocabulary
is closed and `ops\audit-backlog-status.ps1` enforces it; a sixth invented state turns that gate red,
so the merge refuses rather than writing one. Use `NEEDS A RULING` when the next step is a decision
Brad has to make rather than work somebody can do.

A finding is worth filing when it names something measured. "The estate should have more tests" is
not one. "17 files read this script's source and the rules file says 3, measured by grep over these
five directories on this date" is.

## Merging

After the last lane lands, once:

```
powershell -NoProfile -File C:\Codex\ThriftyCrew\ops\merge-backlog-inbox.ps1
```

Add `-DryRun` to see the plan and write nothing.

**CHECK YOUR OWN FILE BEFORE YOU LEAVE IT HERE. `[2026-09-12]`**

```
powershell -NoProfile -File C:\Codex\ThriftyCrew\ops\merge-backlog-inbox.ps1 -ValidateFile <your file>
```

It copies that ONE file into a fresh temp drop box and runs the same parser over it, so it can never
report a sibling's problem as yours and can never touch the real box. **Exit 0 would merge, 2 would be
quarantined, 3 could not evaluate. Read the exit code.** The trap that has fired four times is a
closing `## Nothing else` or `## nothing for the estate` section with no state line under it: every
`##` heading is a finding and every finding owes a state line, including the one that says there is
nothing to report.

**A malformed file is QUARANTINED, not fatal `[CHANGED 2026-09-12]`.** It used to refuse the WHOLE
merge, which cost three innocent lanes on each of its three firings. Now the merge writes the good
files, MOVES the bad one to `quarantine\` with its bytes unchanged and a `.reason.txt` beside it, and
names it. **Exit 0 merged everything, 2 merged the rest and quarantined at least one, 3 could not
evaluate.** What did not change is why the old behaviour existed: the destination still never receives
a heading the status audit would fail, ids are still allocated by one writer over one accepted set,
and nothing is half written. Then confirm with `ops\audit-backlog-status.ps1`.
