# Phase 3 plan - E5, E29 durable half, E19 for the commodity matcher

Written 2026-09-06 after Brad ruled on four open questions. Written to a file BEFORE building because
one of the three touches live scheduled tasks, and fixing a plan is cheaper than unwinding an
implementation.

## Brad's rulings, as given

| Item | Ruling |
|---|---|
| E5 | **Build the full four-layer stack** - format, business rules, self-prompted semantic, human review |
| E29 durable half | **Move the three registry registrations in-repo AND converge the logging** |
| E19 | **The commodity matcher first** - the one whose errors reach a price on a live page |
| E11 / E12 / E13 | asked for the reasoning rather than deciding; answered in chat, still open |

## Order, and why this order

**E19 first, then E5, then E29.** E5's whole claim is that validation is missing or wrong at the
capture readers and the ingredient queue, and E9 and E4 both inverted their own premise the moment
they were measured. E19 builds the thing that can tell us whether E5's premise holds. Doing E5 first
risks building a four-layer stack against a defect that is differently shaped than described.

E29 goes last because it is the only one that can break a running schedule, and it should not be
in flight while anything else is.

---

## E19 - a scored test set for the commodity matcher

**The two-stage point is the load-bearing one.** One end-to-end number cannot say whether the right
answer was **never retrieved** or was **retrieved and buried**, and those need opposite fixes: the
first is a recall problem in the bi-encoder prefilter, the second is a ranking problem in the
cross-encoder. So the set is scored twice, `recall@k` for the retrieval stage and `MRR` for the
rerank stage, exactly as `rag-craft/evaluating-retrieval.md` 12 and 18 prescribe.

Where the pairs come from, and the honesty problem with all of them:

- the shipped board's accepted commodity-to-product pairs (plenty, and **biased toward successes** -
  E23 exactly, and the dedup set already showed this filtering is invisible until the denominator
  is printed)
- `grocery/known-wrong.json` - human rulings that a cell was WRONG. These are the valuable half
  because they are recorded failures, which is the corpus E23 says we do not build
- the identity-defect cases `sidecar/hardeval.py` already mines

**Rules carried in from what shipped today, non-negotiable:**
1. Print the **denominator and every decline by reason** (E20). A recall figure over the pairs that
   resolved is not a recall figure.
2. Write an **input fingerprint** - size and mtime of every file read (E24). The dedup probe
   disagreed with itself across two runs because the pool moved underneath it and it recorded
   nothing about what it had read.
3. Write **one row per case per arm** and derive the totals from that file, never the reverse (E24).
4. **State the acceptance bar before running it** (E21), in the metric's own units.
5. Register any new threshold in `sidecar/THRESHOLDS.md` with its space (E25).
6. `--selftest` on the pinned interpreter, registered in `run-gates`, with a must-fire and a clean
   twin. It must be runnable where the gate runs, so no torch at module scope.

**Deliverable:** `sidecar/matcher_eval.py` plus a frozen pair file. Not a change to the matcher.
Nothing about the matcher gets tuned in the same commit that builds the thing that scores it.

---

## E5 - validate at source, four layers

Scope per the item: **the ingredient queue and the capture readers.**

| Layer | What it is here | Notes |
|---|---|---|
| 1. Format | is the row parseable at all - price, size, unit, name present and typed | mostly exists; the gap is what happens to a row that fails |
| 2. Business rules | band floors, pack-form declarations, channel, membership | largely exists in `compare-deals.ps1` |
| 3. Self-prompted semantic | is this row actually the food it claims to be | exists as `sidecar/`; not wired into ingest |
| 4. Human review | the queue | exists |

**The load-bearing requirement is the routing, not the layers.** The item's actual claim is that
**low confidence must be routed to review rather than rejected**. A silently rejected row is
invisible; a queued one is not. So the first build step is to find every place ingest DROPS a row and
determine whether it is dropped or queued.

**Step 0, before any building: measure.** Count what each capture reader and the ingredient queue
drops today, by reason, on a real board. Brad ruled for the full stack, so this does not gate the
build - but it decides the ORDER of the four layers and it will be recorded either way. If the
measurement contradicts the item's premise, that gets written down and the build continues, because
Brad ruled.

**Known trap to respect:** `capture-lib.ps1` already emits a `CaptureIngestWarning` and
`ops/audit-capture-ingest-reporting.ps1` already requires a caller of `Import-CaptureCsv` to report
what it dropped. Build ON that seam, do not add a second one beside it.

---

## E29 durable half - move the registrations, converge the logging

**This is the one with blast radius. Three live scheduled tasks and two more that change convention.**

The tasks, and the naming lie to fix: `docs/RUNTIME-MAP.md:58` records that one task is named 0930
and runs at **10:30**, because the registry key says so.

**Method, and it is deliberately paranoid:**

1. **Read the live registry first and write it down** - `Get-ScheduledTask` / `Export` for all five,
   saved to a file in the repo BEFORE anything changes. This is the before-image; without it there is
   no way back.
2. Write `ops/install-grocery-tasks.ps1` that registers the three TC Grocery tasks **to match what
   the export says they are today**, not to match what their names imply. Fix the 0930/10:30 lie by
   correcting the NAME, never by moving the time - the time is what the estate has been running and
   validating against for months.
3. **Verify by re-exporting and diffing against the before-image.** Trigger times, working
   directories, run-as account, and `-WindowStyle Hidden` must be identical. A name change is the
   only intended difference.
4. Converge the logging: bring `graph/pipeline`'s nightly wrapper and `harvest-crawl.ps1` onto
   `run-log-lib`, preserving their existing output paths so nothing downstream that reads
   `graph-nightly-status.json` breaks.
5. Update `run-log-lib`'s header table and `audit-run-log-claims.ps1`'s convention list together -
   the gate should go from "names 2 other conventions" to "there is 1 convention", and its self-test
   must still have a live must-fire after that.
6. `docs/RUNTIME-MAP.md` updated, because it currently documents the registry as the authority.

**What could go wrong, and the stop condition:** if the export shows any of the three tasks differs
from what this repo believes about it - a different account, a different working directory, an extra
trigger - **stop and report rather than reconciling silently.** A scheduled task that has drifted
from its documentation is a finding in its own right and Brad should see it before it is overwritten.

**Do not run any of this against the live scheduler between 06:45 and 10:45**, when the three
TC Grocery tasks and the ~07:00 bot are active.
