# E1: the two designs, scored against the rubric

2026-09-06. Both branches are off the same base `1b5fc966` and hook the same function, so the approach
is the only variable. Pre-scored here so only the close calls need your time; the rubric and its
weights were fixed in `E1-safety-layer-brief.md` section 5 **before** either was built.

| | `e1-staging` (v1) | `e1-undo-log` (v2) |
|---|---|---|
| Bet | prevent | recover |
| Mutating call | queued, not sent | sent, with its inverse captured first |
| Armed by | `TC_STAGE_WRITES` | `TC_WRITE_JOURNAL` |
| Operator tool | `ops/review-staged.ps1` | `ops/revert-ghost-write.ps1` |

---

## The measurement that changed my expectation

I expected v1's cost - "a staged write is not a write, so any caller reading the response breaks" - to
be disqualifying across 29 callers. **It is not, on the chain that matters.** Every mutating call in
the live publish chain discards its response:

    publish.ps1:273      PUT  ... | Out-Null
    publish.ps1:276      POST ... | Out-Null
    wave-publish.ps1:1116 PUT ... | Out-Null

and every call whose response *is* read (`publish.ps1` 161, 190, 285; `wave-publish.ps1` 700, 760,
1111) is a **GET**, which falls straight through v1's gate untouched.

**But there is one real interaction, and it is not response round-tripping.** `publish.ps1:285` GETs
the public page *after* the PUT to confirm it shipped. Under staging the PUT has not happened, so that
verification reads an unchanged page and the chain reports a failure. That is one site to teach about
staging, not twenty-nine - and it is arguably the correct behaviour anyway, since nothing did ship.

## Scoring

### 1. Blast radius of adopting it — **v2**, but by one file, not by twenty-nine
v2 changes nothing: the call executes, the caller gets the real response. v1 needs exactly one change
(`publish.ps1:285`'s post-write verification) before it can be armed on the publish chain. I had this
weighted high on the assumption v1 would need many; measured, it needs one.

### 2. Does it fix E1's actual complaint — **v1, decisively**
E1's complaint is *timing*: `post-publish-reviewer` is the last set of eyes and it runs after the
irreversible step. v1 moves the check to before it. **v2 does not fix this at all** - the review still
happens after, it just adds a route back. On the highest-weighted criterion, and the one the item
exists for, these are not close.

### 3. Failure when the layer itself is wrong — **v1**
v1's bad day: the queue is lost, so nothing ships. Loud by absence, and safe. A half-parsing queue
refuses with exit 3 rather than sending an unknown subset.

v2's bad day is worse and I want to name it plainly rather than let the demo flatter it. **The
before-image can be stale.** It is fetched at write time; if anything changes the resource between
then and the revert, replaying it silently overwrites that newer content on a live paid site. v2 has
no staleness check - no `updated_at` comparison before the restoring PUT - so its worst case is
*writing wrong data*, while v1's worst case is *writing nothing*. If v2 is chosen, that check is not
optional and should be built before it is armed.

### 4. Autonomy — **v2**
v1 needs a second pass; an unattended overnight run stops at a queue nobody drains. v2 lets an agent
undo its own mistake in seconds, which is exactly the recovery-as-a-move-it-can-choose property the
course argues for.

### 5. Surface area paid on every future change — **even**
v1: every future mutating caller must know staging may swallow it. v2: every mutating call buys an
extra GET, so it costs latency and rate limit on every write forever.

### 6. Honest about what it cannot do — **even**
Both refuse rather than guess, and both were driven to their own limit rather than described. v2's
end-to-end is the better demonstration: the call died mid-flight, the entry was still journalled, and
the reverter then **refused** because the before-GET had also failed - proving its coverage is only as
good as that GET.

## Where I come out

**v1 on the merits of the item, v2 on the merits of the estate.** v1 answers what E1 asked; v2 is what
this estate can switch on tonight. If you want one, I would take **v1**, because being on the correct
side of an irreversible write is the whole point and the adoption cost measured far smaller than I
expected.

**But they are not exclusive, and that may be the real answer.** They hook the same function with
different env vars and do not collide: journal *always* so every write has a recorded inverse, and
stage *when armed* for a run nobody is watching. That gets the correct-side check where a human is
present and a way back where one is not. It is more surface than either alone, which is why I am
naming it rather than assuming it.

**One thing I did not build into either:** neither covers R2, which the backlog names alongside Ghost.
Both hook `Invoke-GhostApi`, and R2 does not go through it. That is a separate seam and a separate
piece of work, and calling E1 done without saying so would overstate what these two branches cover.

## To look at them

    git checkout e1-staging   # then: powershell -File ops\review-staged.ps1 -SelfTest
    git checkout e1-undo-log  # then: powershell -File ops\revert-ghost-write.ps1 -SelfTest

Both gate identically: 189 passed, 2 failed in a seeded worktree, and the two are the known CRLF pair
(`audit-ghost-drift`, `golden-test`) that fail the same way on the unmodified base.
