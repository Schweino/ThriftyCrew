# PLAN: triage lean, cut what each step costs (2026-09-24)

Brad, 2026-09-24, after the first pass (design/PLAN-triage-token-efficiency-2026-09-24.md) measured and capped spend
but set a 30M budget: *"30M tokens per run (which runs every day) is not sustainable."* Then, before choosing a budget:
*"can we look at where/why there is so much token usage? Are we using tokens inefficiently?"* and *"Implement ALL the
fixes."*

## Knowledge consulted

- `.claude/rules/measurement.md`: a rate carries its denominator; the harness is committed (`grocery/triage-cost.py`).
- `memory:harness-tokens-is-final-context` and `memory:triage-cost-controls` (the unit trap and the first pass).
- `ops/push-main.ps1`'s header: it lands on its first attempt and runs every gate, so a plain process can own the
  landing with nothing weakened.

## Where the tokens went (harness `grocery/triage-cost.py`, session 5f9934ec, the 2026-09-19 run, 26.2M units)

| cause | share | measured |
|---|---|---|
| re-reading accumulated context each call | about 53% | developer 30k to 600k over 142 calls; 92% of what it re-read was accumulated, 8% its instructions |
| re-caching the whole context after an idle wait over 5 minutes | about 25% | 13 of 16 re-writes over 50k followed such a wait (median about 10 minutes); developer 8 re-writes = 4.95M of its 12.46M |
| output | about 15% | |

By agent: developer 48%, orchestrator 31% (228 calls, context to 437k), ops 16%, reviewer 6%. The same shape on 09-18
(75% of cache writes were post-wait re-writes) and 09-20 to 09-23 (83%, 192 of 267 after a wait over 5 minutes).
Biggest single reads: the whole plan (56,189 chars), the README (28,913), one script four times.

## Fixes

| id | fix | where |
|---|---|---|
| L1 | No model waits on a landing: agents commit and exit; `grocery/triage-land.ps1` runs push-main (every gate) as a plain process in the background, optional feed-week parity after, and prints one `TRIAGE-LAND-COMPLETE` line. Queue items close only after `outcome=landed`. | `grocery/triage-land.ps1`, SKILL STEP 3.9, both lane agents |
| L2 | One developer spawn per item; the item is read and written through `grocery/triage-plan-item.py`, never by reading the plan. | `grocery/triage-plan-item.py`, SKILL STEP 3, developer agent |
| L3 | The orchestrator is a dispatcher: Class C/D items go to `triage-ops-developer` JOB 3 in their own plan; the orchestrator reads verdict lines only; target 60 calls. | SKILL STEP 0.9 and COST CONTROLS, ops agent JOB 3, reviewer |
| L4 | Read only what you need: grep or slice, output to a file and read the verdict. `triage-cost.py` now records per agent `ctx_first`, `ctx_avg`, wait re-writes and the three biggest reads, so each run shows which rule it broke. | all three agents, `grocery/triage-cost.py` |

## What is NOT changed

Every gate still runs (push-main runs them on landing), every item still owes root_fix, must_fire_case and clean_twin,
and the budget question to Brad stays open until these changes are measured on real runs (bars in
design/MEASURE-triage-token-spend-2026-09-24.md).

## Left for later, measured but not changed here

A spawned agent that reads any file under `C:\Codex\ThriftyCrew` also loads that checkout's CLAUDE.md and every
`.claude/rules/*.md` (all carry no `paths:` key, on purpose), tens of thousands of tokens re-read on every later call.
Trimming them is an estate-wide decision, not a triage one.
