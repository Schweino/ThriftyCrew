# backlog-inbox - one file per writer, merged by one process

**This directory is normally EMPTY, and that is correct.** It is a drop box, not a store. Files
appear here while a parallel run is in flight and are removed by the merge once their contents have
landed in `BACKLOG-course-findings.md`. New findings go at the top level; progress on an item that
already exists goes in `updates\` (see "Recording progress on an existing item" below).

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

## Recording progress on an existing item

`[2026-09-23, W3.1 of design/PLAN-push-derived-conflicts-2026-09-23.md, Brad's ruling D2]`

**A lane never edits `design/BACKLOG-course-findings.md` directly.** Not to close an item, not to add
a paragraph, not to change a tag. That file was touched by 142 of 299 landings over 7 days and
overlapped in 12 of 19 recent rebase conflicts (the plan's section 2.3, A3). Progress goes through this
drop box as an UPDATE, in a file of the lane's own under the `updates` subdirectory:

```
design\backlog-inbox\updates\<lane>-<YYYY-MM-DD>.md
```

Create the folder if it is not there (`New-Item -ItemType Directory -Force design\backlog-inbox\updates`).
One block per item, any number of blocks per file:

```
## UPDATE I165
`DONE` `queue-7`
<body paragraphs, appended to that item>
```

- **The heading is exactly `## UPDATE <id>`**, the id letters then digits (`I165`, `E7`). Every `##`
  heading in an updates file must be one; a new finding belongs at the top level instead.
- **The next non-empty line is the item's new tag spans, and its first span is the state.** They
  REPLACE the item's state span and every backticked span right after it, so restate the ones you mean
  to keep: a queue tag, a commit hash, and for an open state the `2-WAY`/`1-WAY` and `RUNG1 <TYPE>`
  axes. The title before the state span, backticked code in it included, and any prose after the last
  replaced span stay exactly as they were.
- **The body is appended at the end of that item's section**, after a blank line, followed by
  `**Merged from design\backlog-inbox\updates\<file> on <date>.**`. A body line that is itself a
  heading (`#`, `##` or `###`) is refused: it would start a new section, or a new item.
- **Why a separate folder.** The merge before this change read only the top level, so a copy of it
  that some other checkout has not pulled yet never sees an UPDATE file and cannot mint `## UPDATE I165`
  as a brand new item with a bogus id. An UPDATE heading filed at the top level is quarantined for the
  same reason.

**Two files that give one item DIFFERENT tag sets are never settled by order.** File names start with
the lane, so "the later file wins" would really mean "alphabetical by lane". The merge quarantines both
files into `updates\quarantine\`, each `.reason.txt` naming the other, merges nothing for that item, and
exits 2, and a person decides. Two files giving the SAME tag set both merge, and the output says
`I165 updated by 2 files: <a>, <b>`.

**Every update is judged by the push gate's own rules before it lands.** The merge applies each file's
updates to a temp copy of the backlog and runs `ops\audit-backlog-status.ps1 -Backlog <that copy>`. A
file whose update would fail it (a missing reversibility or first-rung tag on an open item, two state
spans, an unknown state), or that names an id the backlog does not have, is quarantined whole with the
gate's finding in its `.reason.txt`. If the backlog is ALREADY failing that gate, no update can be
judged, so every update file stays where it is and the merge exits 3.

**Until the merge runs, the board still shows it.** `powershell -NoProfile -File
ops\audit-backlog-status.ps1 -Summary` prints each item with a pending UPDATE under its NEW state,
marked `(pending inbox: <file>)`. The gate mode, without `-Summary`, judges only the backlog file.

Check an UPDATE file the same way as any other, where it sits (the `updates` folder is how the merge
knows to read it as UPDATE blocks):

```
powershell -NoProfile -File ops\merge-backlog-inbox.ps1 -ValidateFile design\backlog-inbox\updates\<your file>
```

## Merging

After the last lane lands, once:

```
powershell -NoProfile -File C:\Codex\ThriftyCrew\ops\merge-backlog-inbox.ps1
```

Add `-DryRun` to see the plan and write nothing.

**One merge at a time `[2026-09-23]`.** A real merge holds a ledger lock on the backlog's path
(`lib\ledger-lock.ps1`) across its inbox read, its id allocation, its write and its consume, so a hand
run and a scheduled run never allocate at once: the second waits, then finds the drop box empty. One
that cannot take the lock within `-LockWaitSec` (120 s) writes nothing and exits 3. `-DryRun` and
`-ValidateFile` take no lock.

**Commit the merge with its trailer.** A merge that changed the backlog prints a line
`Backlog-Merged-From: <file>[, <file>...]`, each entry a path below `design/backlog-inbox/` in forward
slashes (`lane-a-2026-09-23.md`, `updates/lane-b-2026-09-23.md`). Put that line, as printed, in the
commit that carries the merged backlog: it is how a merge is told apart from a direct edit.

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
files, MOVES the bad one to `quarantine\` (an UPDATE file to `updates\quarantine\`) with its bytes
unchanged and a `.reason.txt` beside it, and names it. **Exit 0 merged everything, 2 merged the rest and
quarantined at least one, 3 could not evaluate** (no backlog, the lock not taken, the backlog already
failing its gate while updates wait, or a write or move that failed). What did not change is why the old
behaviour existed: the destination still never receives a heading the status audit would fail, ids are
still allocated by one writer over one accepted set, and nothing is half written. Then confirm with
`ops\audit-backlog-status.ps1`.
