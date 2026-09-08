# BRIEF: the backlog session

**Written 2026-09-08 by the orchestrating session that produced most of this backlog.** You are one
of two sessions running in parallel. Read the boundary before you touch anything, because the two of
you can corrupt each other's work in exactly one way and it is avoidable.

## Your territory, and the one thing you must not touch

**You own the `C:\Codex\ThriftyCrew` repository.** Estate code, gates, data, docs, and
`design/BACKLOG-course-findings.md`. You commit and push it. The other session does not.

**You must NOT write anything under `C:\Users\Owner\.claude\skills\`.** That is the course session's
repository and it commits there. Reading it is fine and often useful - `skills/CATALOGUE.md` maps
what the estate has already learned.

**The one shared object is `design\backlog-inbox\`.** The course session drops one file per course
lane in there and never merges them. **You own the merge:**

```
powershell -NoProfile -File ops\merge-backlog-inbox.ps1 -DryRun
powershell -NoProfile -File ops\merge-backlog-inbox.ps1
```

It reads every file before writing anything, refuses the whole merge on a malformed one with nothing
written, allocates ids itself, and empties the drop box only after a successful append. Run
`ops\audit-backlog-status.ps1` afterwards. A lane that measured nothing writes `NOTHING TO FILE` and
that is a valid result, not an error.

**Gates split with the boundary.** You run `ops\run-gates.ps1`. The course session does not, because
it touches no estate code. Do not run `check-skills.py` or `build-catalogue.py` - those judge the
store while the other session is editing it, and a red you cannot attribute is worse than no gate.

## FIRST, CHECK WHICH BRANCH YOU ARE ON, AND KEEP CHECKING

`[ADDED 2026-09-08, an hour after this brief was written, because it happened to me.]`

**15 live sessions share this working directory.** Measured that day. A git checkout has one
working tree, one index and one current branch, so **any of those sessions can change the branch
under you between one command and the next** - and one did: it created `triage/2026-09-08` at 10:32,
and the commit carrying this brief landed on that branch instead of `main` because I never looked.

```
git branch --show-current
```

**Run it before every commit.** If you are not where you expect, do not switch the tree back - another
session may be mid-task on it. Push your commit to where it belongs instead, which needs no checkout
and disturbs nobody:

```
git push origin <current-branch>:main      # only when it is a true fast-forward
git fetch origin && git branch -f main origin/main
```

**If this session is going to do sustained estate work, take a worktree rather than sharing this
tree.** The estate already owns that path - `ops\seed-worktree.ps1` and `.worktreeinclude` exist
because a fresh worktree lacks the gitignored boards and every data audit is blind without them.
Ask Brad before doing it; it is his machine and his other sessions.

## Your first task is TRIAGE, and you change nothing until Brad approves the order

**Do not start working items.** Read all of them, then come back with a proposed order.

```
powershell -NoProfile -File ops\audit-backlog-status.ps1 -Summary
```

As of 2026-09-08: **125 items, 52 OPEN, 7 NEEDS A RULING, 2 PARTLY DONE, 11 PARKED, 51 DONE.**

**Group them by two axes and report both:**

1. **Blast radius.** This is a live, paid site. An item that can produce a wrong number on a page, a
   duplicate email to a member of the public, or a broken paid recipe is not the same as a tidy-up,
   however small the diff. Understating is exactly as wrong as overstating.
2. **Shared code.** Items that touch the same script or the same data file must be worked together or
   in a stated order, or the second one lands on a tree the first reshaped. This is the axis that
   decides whether an item is cheap.

**The 7 `NEEDS A RULING` items are Brad's decisions, not your work.** Prepare each one - state the
question, the options, and what each costs - and stop. Do not decide them. They are I38, I42, I55,
I81, I86, I91, I93.

**Four that I would put in front of Brad during triage, because they are risk rather than debt:**

- **I89** - a successful email send whose draft delete fails re-sends to a real member of the public,
  with no attempt counter and no upper bound.
- **I90** - `meal-prep` reads `grocery/out` directly in 36 scripts. That is a module reaching into
  another's gitignored working directory rather than its published artefact, and nothing declares it,
  so no gate can see a new one appear.
- **I92** - a promotion hold latches forever and records the date but not the condition it latched
  against. 15 aliases have been held since 2026-08-21 against a board that is rebuilt daily.
- **I73 to I77** - the graph findings, which are coherent as a set: 205 nodes joined to nothing, no
  cached degree so any query entering from a store fans out 20,133 ways, commodity retirement being a
  graph cut that two name-based gates guard, and edges accumulating 1.6x faster than nodes.

## Estate hazards you will hit

Read `CLAUDE.md`, `.claude/rules/*.md` and `docs/RUNTIME-MAP.md` first. The ones that cost a day if
missed:

- **`ops\run-gates.ps1`: exit 0 passed, 1 failed, 3 COULD NOT EVALUATE.** Never read 3 as a pass.
  Read the exit code before the tally, and never pipe the thing whose exit code you are reading.
- **The boards are gitignored**, so a worktree or a clean checkout is blind and the pricing engines
  exit 0 having priced nothing. A green run off-main proves nothing.
- **A bot commits the whole tree around 07:00** with an autostash rebase. Only rebase when
  `origin/main` actually moved, and remember the other session may also be pushing - to a different
  repository, but the bot touches this one.
- **Stage explicit paths, never `git add -A`.** Unrelated data churn is always sitting in the tree.
- **Commit messages go in a file and ship with `-F`**, written without a BOM. An inline `-m` executes
  backticks.
- **Never weaken a gate to get something through.** If a gate is wrong, fix the gate and say so.

## What "done" means for an item

Set its state in the closed vocabulary - `DONE`, `PARTLY DONE`, `PARKED`, `NEEDS A RULING`, `OPEN` -
and say what actually happened, including what you did not do. `PARKED` with a reason is a real
outcome and better than a silent skip. If an item turns out to be already fixed or filed against a
stale premise, close it `DONE` with the account rather than deleting it: I88 is the worked example.
