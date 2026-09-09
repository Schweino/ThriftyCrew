# What the daily guard chain costs, and why its August profile is obsolete

**Harness:** `grocery/guards.ps1`, run as `powershell -NoProfile -File grocery\guards.ps1`.
**Commit it ran at:** `47150b330` (main, 2026-09-09).
**Board:** `grocery/out/comparison-2026-09-09.json`, the live board of the day.
**Machine:** 32 logical cores, Windows 11, PowerShell 5.1.
**Verdict read:** exit code first. Both runs exited **0** at `GUARDS-COMPLETE hard=0 warn=20`.

Written because `guards.ps1`'s own header quotes a 2026-08-22 measurement and this estate's rule is
that a measurement whose harness has moved is UNQUALIFIED until somebody re-reads it. That file has
changed since. This is the re-read, not a correction of it: the August number was honest about the
state it measured.

## The chain

| | measured |
|---|---:|
| `guards.ps1` wall clock | **49.3s**, then 48.9s |
| its 19 child audits, summed serially and uncontended | 51.8s |
| its longest single child | **22.0s** |

## The finding: the cost has moved to a child that did not exist in August

`guards.ps1`'s header records the 2026-08-22 profile as *audit-known-wrong 15.7s, audit-walmart-fullpull
4.8s, audit-household-in-food 4.6s, and the remaining eleven 8.1s between them*. Measured today, with
the same arguments `Register-Kid` passes:

| child | Aug 22 | today |
|---|---:|---:|
| `audit-capture-encoding` | not in the list | **22.0s** |
| `audit-walmart-fullpull` | 4.8s | 6.3s |
| `test-pull-agent-lib -SelfTest` | not in the list | 5.4s |
| `audit-known-wrong` | **15.7s** | 3.4s |
| `audit-household-in-food` | 4.6s | 2.9s |
| the other fourteen | - | 11.8s between them |

**The child the August tuning was aimed at is now the fourth cheapest.** `audit-known-wrong` fell from
15.7s to 3.4s. In its place `audit-capture-encoding`, which is not in the August list at all, is
**22.0s and 42% of all child work**.

That matters because of how the chain is built. The children are launched concurrently and harvested
lazily, so **the batch cannot cost less than its longest member** - that is the header's own sentence.
In August the floor was known-wrong at 15.7s. Today the floor is capture-encoding at 22.0s, and
the next longest child is 6.3s. So one audit alone sets the batch floor, and nothing else is close.

## What the chain does NOT have

It does not have the barrier defect found in `ops/run-gates.ps1` the same day
(`design/MEASURE-gate-cost-2026-09-09.md`). Checked in source rather than assumed: all 20 children are
registered up front at `guards.ps1:284-306` and harvested at `330, 347, 365, 570`, all after the last
registration. **Launch early, harvest late** - already the correct shape. Whoever built that in August
got the architecture right, and there is no second win of the gate's kind waiting here.

The estate has two independent parallel runners, `lib/parallel-run.ps1` (used only by `run-gates`) and
`grocery/fanout-lib.ps1` (used by `check-ad-cycles`), plus this file's own `Register-Kid` mechanism.
Only `run-gates` had barriers.

## What this does not claim

- **The children were timed SERIALLY and COLD, one at a time, so these are UNCONTENDED costs.** Inside
  `guards.ps1` they run concurrently and each will be slower; the gate measured that inflation at about
  55% the same day. So 51.8s is a floor on the child work, not what it costs in place, and the two
  columns of the table above are not measured the same way as each other either - the August figures
  come from that header, not from this run.
- **It does not decompose `guards.ps1`'s own inline work.** Wall 49s with a batch floor of 22s bounds
  the rest at no more than 27s; it does not measure it. `audit-coverage-ledger` is deliberately serial
  and last, by the header's own note, and is part of that remainder.
- One board, one machine, one day. The chain sits on the ship path, so its cost varies with the board.
- **No alert was sent by this measurement.** `audit-board-mojibake` is the only child that can send
  one, and `guards.ps1` registers it with `-Quiet`, which gates the send at its line 261. Checked
  before running, not after.

## Recommendation

**Nothing here is urgent and nothing should be changed on this measurement alone.** The chain passes,
it costs 49 seconds, and its architecture is already right.

If the daily chain is ever worth speeding up, the whole question is `audit-capture-encoding`: at 22.0s
it is 42% of child work and the sole thing setting the batch floor, and getting it under the 6.3s next
longest would drop that floor by two thirds. **Whether it earns 22 seconds is not answered here** - it
guards the BOM-less-read corruption class, which is the single most recurrent defect family in this
estate's memory, so the answer is not obviously no.

The durable half is the re-read itself: this file's numbers will go stale the same way the August ones
did, and the next reader is owed the same warning rather than the same surprise.
