# The shared checkout: a verified push that starves, and five weeks of debris

Written 2026-09-12 by the course-orchestrating session, after two of its own pushes failed
identically. **Nothing here is built yet.** `PLAN-push-livelock-2026-09-11.md` fixed the livelock this
sits next to, and section 5 of that plan says plainly what it left undone. This is the residual, plus
two hygiene items that are not about pushing at all.

## 1. The report, measured rather than described

A commit carrying 18 course findings, verified and ready, could not land in two attempts:

| attempt | waited for the push lock | outcome |
|---|---|---|
| 1 | **1,255 s** | `run-gates` exit 3, `refs/heads/main` moved cef0d0f6a to 8c310df9e |
| 2 | **1,130 s** | `run-gates` exit 3, `refs/heads/main` moved 8c310df9e to 39e8af0bd |

`origin/main` took **8 commits in 3 hours** from other sessions on this box. A push that waits about
nineteen minutes for the lock is, at that arrival rate, very likely to be invalidated before it holds
it. The gate never ran in either attempt, which is correct: `lib/push-landable.ps1` refuses to spend a
25-minute gate on a tree that can no longer land, and exit 3 is never a pass.

**The one-line statement.** The lock made pushes fair to each other, and the staleness check keeps the
gate honest, but nothing rebases the waiter. So the longer a push waits, the likelier it is to be
thrown away, which is starvation by another name and the exact property `lib/gate-slots.ps1`'s ticket
queue was built to remove from the gate pool.

## 2. What NOT to do, first, because both are tempting

- **Not `--no-verify`.** It is the deliberate loud bypass and it is not a fix for a queueing problem.
- **Not weakening the staleness check.** Refusing to gate a tree that cannot land is right, and the
  refusal is what told me the cause in one line both times.

## 3. PROPOSAL A WAS ALREADY BUILT, AND THIS PLAN'S FIRST DRAFT PROPOSED IT ANYWAY

**`ops\push-main.ps1` shipped 2026-09-11 and does exactly what the draft asked for**, and better: it
takes the machine-wide lock FIRST, then fetches, rebases and pushes inside it, so the base cannot go
stale between the rebase and the ref update. A helper that rebases *between attempts*, which is what
the draft proposed, only shortens the odds; taking the lock first removes the race.

`CLAUDE.md` names it in the sentence *"ONE PUSH AT A TIME ON THIS BOX, and `ops\push-main.ps1` is how
you land one"*. This session read that file and hand-rolled a retry loop anyway, three times.

**The measurement that settles it, from this session, same commits, same box, within one hour:**

| route | outcome |
|---|---|
| plain `git push`, attempt 1 | waited 1,255 s for the lock, exit 3, remote had moved |
| plain `git push`, attempt 2 | waited 1,130 s, exit 3, remote had moved |
| plain `git push`, attempt 3 | waited 1,853 s, exit 3, remote had moved |
| plain `git push`, attempt 4 | waited 1,505 s, **gate PASSED 386 of 386**, then rejected: *cannot lock ref* |
| `ops\push-main.ps1` | **LANDED on the first attempt** |

Attempt 4 is the one worth keeping: the gate ran, everything passed, and the push still lost the ref
in the moment between. That is the livelock `PLAN-push-livelock-2026-09-11.md` diagnosed, still live
for anyone who reaches for `git push`, and already solved for anyone who does not.

**So there is nothing to build here.** The residual is that a plain `git push` remains available, works,
is fully gated, and starves under contention - and the estate deliberately keeps it working, because
the hook must not hard-fail in a checkout older than itself. The gap is knowledge, not machinery:
**this plan's own author had the rule delivered and did not apply it.** What a rules file cannot do, a
tool that lands on the first attempt can, so the honest recommendation is to reach for `push-main.ps1`
and to stop treating a slow push as a queueing problem to be outwitted.

## 4. Proposal B: WITHDRAWN, for the same reason

The draft proposed checking staleness before queueing rather than after. `push-main.ps1` makes the
question moot for anyone using it: there is no wait during which the base can go stale. Adding a
pre-check to the hook would improve only the message a plain `git push` gets before it fails, which is
not worth touching a hook standing in front of 130 checkouts.

## 5. The debris, which is separate from the queueing and older

- **11 autostashes, the oldest from 2026-08-07**, nearly all timestamped around 09:00, which is the
  daily bot's rebase window. These are failed reapplications that have accumulated for five weeks.
  The newest is from 2026-09-11 21:38 and holds another session's graph data after this session's own
  rebase could not reapply it. `autostash-restores-content-not-the-index` records the mechanism; what
  is new is that nobody ever looks at the pile.
  **Proposal: a report, never an automatic drop.** A stash is somebody's uncommitted work and deleting
  it is one-way. Print age, file count and first paths; let a human decide.
- **130 linked worktrees**, oldest 2026-09-10, so roughly 130 in two days. Each is a full checkout.
  **Proposal: a reaper that only removes a worktree whose HEAD is an ancestor of `origin/main` AND
  whose tree is clean**, refusing everything else and naming it. Never touch one with work in it.
- **The shared index is the sharpest edge and needs no tool.** Tonight `git add` of ONE file produced a
  21-file commit, because the index belongs to the checkout and not to the session. The fix is the
  pathspec commit form, now recorded in memory; the reason it belongs in this plan is that it is the
  same root cause as the other two: **one checkout, many sessions.**

## 6. The acceptance bar, written before any of it is built

Proposals A and B are withdrawn, so only the debris work has a bar left to meet.

- **The reaper:** run against a mirror first. It must refuse every worktree with uncommitted work,
  and the count it removes must equal the count it names. A reaper that removes something it did not
  print is the bug that matters.
- **The stash report:** it prints and never deletes, so its bar is that a human can act on it - age,
  file count, and the first paths, for each of the 11.
- **What was already measured, so nobody re-derives it:** four plain pushes failed and one
  `push-main.ps1` landed first time, section 3. The gate is not the bottleneck the draft assumed: on
  attempt 4 it passed 386 of 386 and the push was still rejected.

## 7. What this is deliberately not

Not a change to the gate, its budget, or the staleness check. Not a daemon. Not an automatic stash
drop. Not a change to the hook's behaviour for checkouts that lack the newer libraries.
