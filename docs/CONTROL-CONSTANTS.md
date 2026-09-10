# Control constants: the register

**Why this exists (2026-09-09, backlog I93, ruled by Brad).** The estate tunes several correcting
loops, and every constant that tunes one was declared locally with a good comment and listed nowhere
together. `sidecar/THRESHOLDS.md` is the precedent and the model, but it covers **score spaces** -
bi-encoder cosine, cross-encoder sigmoid, BM25 - and says nothing about control loops.

A register is not a gate. Nothing here is enforced by a threshold, and it must not become one: a bar
over these numbers would be red on day one against most of them. What it buys is that the next person
tuning one can see the others, and that a constant with no stated direction stands out.

## How to read the columns

- **Direction** is the one that matters. A constant that can only move ONE WAY is an actuator, and an
  actuator needs a rate limit and a plausibility bar or it latches. That is the rule below.
- **When the producer stops** is the standing question from the `ops-and-gates.md` rule: every
  threshold here is an upper bound, so write down what the number does when the thing it watches goes
  quiet. If the answer is "nothing fires", the loop needs a floor as well.
- **Tuned how** is the `I94` convention: was this the first plausible value, or the survivor of a
  sweep? Those are different claims and only one of them is evidence.

## The register

| Constant | Where | What it controls | Direction | When the producer stops | Tuned how |
|---|---|---|---|---|---|
| `$script:BoardStaleHours = 26` | `grocery/capture-watchdog.ps1` | how old a board may be before the watchdog complains | two-way, an upper bound | **fires** - staleness is exactly the absence case | not recorded |
| `$script:NeverRanGraceHours = 30` | `grocery/capture-watchdog.ps1` | how long a task may have never run before it is a finding | two-way, an upper bound | **fires** | not recorded |
| `$REARM_DAYS = 14` | `grocery/check-ad-cycles.ps1` | how long before an alert may fire again for the same thing | two-way | goes quiet, and cannot fire | not recorded |
| `-MaxDropPct 60.0` | `lib/ratchet.ps1` | the largest single-run fall in a high-water mark that reads as real | **one-way actuator** (the mark may only go DOWN) | goes quiet | not recorded |
| `$SENT_LOG_KEEP_DAYS = 180` | `grocery/notify-item-added.ps1` | how long a sent-notification row is kept | two-way | goes quiet | not recorded |
| `$DELETE_GIVE_UP = 5` | `grocery/notify-item-added.ps1` | attempts before a delete is abandoned | two-way | goes quiet | not recorded |
| `MAX_NEW_HOLDS_PER_RUN = 10` | `graph/learning/promote_aliases.py` | the largest plausible batch of new promotion holds in one run | **one-way actuator** (holds only accumulate and never expire) | goes quiet | **first plausible value**, grounded on the live set of 16 holds across 10 commodities; NOT a sweep |
| `HISTORY_MAX_AGE_DAYS = 40` | `ops/member-cohorts.ps1` | how stale the monthly member snapshot series may get | a **floor**, watching for absence | **fires** - that is its whole job | **first plausible value**, 31 days plus a week of slack; NOT a sweep |
| `MIN_SCORE = 8.5` | `~/.claude/skills/recall-hook.py` | the recall floor | two-way | goes quiet | derived; see the file's own note on the 9.0 -> 8.5 move |
| `MAX_REASKS_PER_NIGHT = 200` | `graph/learning/verdict_expiry.py` | how many expired model verdicts one night may re-ask, oldest first | two-way, an upper bound: the rate limit on an expiry actuator that would otherwise re-ask every lapsed verdict at once | **spoken** - `--emit` counts how many of last night's list now carry a newer date, and prints DID NOT FULLY LAND into the nightly status when the resolve stage re-asked fewer than it was given | **first plausible value**, well under one night's model budget; NOT a sweep. No verdict can expire before 2026-11-19, so the first real reading is that night |
| `FRESH_HOURS = 18` | `graph/learning/verdict_expiry.py` | how old a re-ask list may be and still be tonight's | two-way | goes quiet by design: a stale list re-asks NOTHING, never yesterday's questions again | **first plausible value**, the 21:30 to 06:30 window plus slack; NOT a sweep |
| `FANOUT_WARN = 1000` | `graph/lib/fanout.py` | the traversal width that refuses an entry point | two-way, an upper bound | goes quiet | **first plausible value**, grounded on the live shape: max out-degree 4, max in-degree 20,146, so nothing sits near the bar; NOT a sweep |

**Most rows say "not recorded" and that is the honest state.** `I94` established the convention that a
constant records what ELSE was tried; retro-filling the existing ones was explicitly not asked for, so
only the ones added since carry it. A row here saying "not recorded" is a fact about the estate, not a
gap in this document.

## The rule this register exists to make visible

**A control constant that may only move ONE WAY needs a rate limit and a plausibility bar.**

`lib/ratchet.ps1` had it and `promote_aliases.py` did not, which is what backlog I93 found. The
audits' high-water mark may only fall, so the ratchet refuses a fall to zero and a fall larger than
`-MaxDropPct`, **keeps the old baseline**, and reports. `promotion-holds.json` may only accumulate -
holds never expire and nothing re-tested them until `--recheck-holds` - so a single degraded guard run
naming many commodities would have written a permanent hold for each of them in one pass, with nothing
calling that extraordinary. It now refuses a batch over `MAX_NEW_HOLDS_PER_RUN`, keeps the file it
has, and reports, with `--accept-holds` as the deliberate override.

**Both halves matter, and the second is the one that gets forgotten:** refusing is not enough. The old
state has to be KEPT and the refusal has to be SPOKEN, or a run that silently declined to act looks
exactly like a run with nothing to do.
