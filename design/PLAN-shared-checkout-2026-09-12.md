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

## 3. Proposal A: rebase the waiter, in a shared helper rather than in the hook

`ops\push-main.ps1`, which every session uses instead of a bare `git push`: fetch, rebase onto what
the remote holds now, push, and **on the staleness refusal only**, loop, bounded. Stop immediately on
a real gate red, a rebase conflict, or an attempt limit, and say which.

- The hook stays as it is. It stands in front of 130 checkouts, most older than any change here, and
  `PLAN-push-livelock` 4.4's degrade-never-block property must survive untouched.
- **A retry that rebases is not a blind retry**: every attempt has a different input, which is the
  distinction `software-craft/distributed-coordination.md` draws between a repair and an amplifier.
- This session ran exactly that loop tonight, by hand. Shipping it is making a habit mechanical.

**Weakness, stated:** it does not reduce the wait, so under heavier arrival rates the loop gets longer.
It converts a failed push into a slow one, which is the right direction but not a ceiling.

## 4. Proposal B: check staleness BEFORE queueing, not only after

Today a push waits nineteen minutes and is then told its base moved. The same check before the wait
costs one `git ls-remote` and would send the caller to rebase immediately. It does not remove the race
(the remote can move during the wait regardless) but it removes the case where the answer was already
knowable at the start. **Cheap, and strictly an improvement in the message the caller gets.**

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

- **Proposal A:** over the next 20 pushes from sessions using the helper, **no push fails with the
  staleness refusal as its final outcome**. Failing an attempt and landing on a later one is a pass.
  Measured from the helper's own log, which records attempts per landing.
- **Proposal B:** a push whose base is already stale learns so **before** it waits for the lock, and
  the hook's degrade-never-block paths still behave as `PLAN-push-livelock` 4.4 describes, proven by
  that plan's existing fixtures still passing unchanged.
- **The reaper:** run against a mirror first. It must refuse every worktree with uncommitted work,
  and the count it removes must equal the count it names. A reaper that removes something it did not
  print is the bug that matters.
- **What would make me wrong about A:** if the arrival rate is the real problem rather than the
  waiter, the loop will simply take longer without failing, and the honest reading is then that the
  gate's cost, not the queueing, is what needs the work. That is Brad's ruling and
  `docs/CONTROL-CONSTANTS.md` holds the budget.

## 7. What this is deliberately not

Not a change to the gate, its budget, or the staleness check. Not a daemon. Not an automatic stash
drop. Not a change to the hook's behaviour for checkouts that lack the newer libraries.
