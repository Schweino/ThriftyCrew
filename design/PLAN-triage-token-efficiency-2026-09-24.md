# PLAN: triage token efficiency (2026-09-24)

Brad, 2026-09-24: *"Do all proposed fixes ... to make sure this triage system is as efficient as possible token
wise, while also not losing sight on not just resolving the issue, but future proofing so we dont have the alert
happen again."* The grocery-alert-triage task is paused until 2026-09-25 09:00; this lands before then.

## Knowledge consulted

- searched "push ref race", "retry budget", "cost ledger": `concurrency-craft/applies-here.md` section 22 (push-main
  holds the push lock across `git push`) and `ops/push-main.ps1`'s header, which is why F5 lands through push-main
  and never retries a push inside an agent.
- `memory:triage-cost-controls` (the 2026-09-10 ceilings this plan measures against).
- `.claude/rules/measurement.md`: a rate carries its denominator, the bar is written before the run, the harness is
  committed (`grocery/triage-cost.py`).

## What was measured (harness: `grocery/triage-cost.py`, committed with this plan)

1. **The cost ledger has recorded the wrong number since it was created.** Its `tokens` column is the harness
   `total_tokens` of each spawn, which is the size of the agent's FINAL context window, not what the agent consumed.
   Checked on 4 of 4 spawns of the 2026-09-19 run (session 5f9934ec): each ledger value equals input + cache read +
   cache write + output of that agent's LAST API call, exactly (270,488 / 603,094 / 317,364 / 174,424). What a run
   actually processes is the sum over every call, and it is one to two orders of magnitude larger.
2. **Real spend, in input-token equivalents** (`cost_units` = input + 1.25 x cache write + 0.1 x cache read + 5 x
   output; relative Opus list-price weights, an approximation stated as one):

   | session | dates | cost_units | largest share |
   |---|---|---|---|
   | 74c896e6 | 09-06 | 18.2M | triage-developer 81% |
   | 5f9934ec | 09-19 | 26.2M | triage-developer 48%, orchestrator 31% |
   | 0d5b6bf1 | 09-18 to 09-19 | 44.9M | triage-developer 67% |
   | ffbacbef | 09-20 to 09-23 | **402.3M** | 23 developer spawns 212M, 13 ops 73M, 11 general-purpose 65M, orchestrator 36M |

   The 09-20 scheduled session stayed open for three days of follow-on work (56 spawns, 19 plan files on 09-21 and
   09-22) and none of it reached the ledger. That session alone is about 15 times a normal day.
3. **Where a developer's tokens go.** Across ffbacbef's 23 developer spawns: 3,492 API calls at an average context of
   about 312k tokens, so cache READS were 109M units and cache WRITES 82M. Writes that large mean the cache expired
   and the whole context was re-written many times, which is what an agent waiting on a 10 to 30 minute gate or push
   does. Cost grows with (calls x context), so one long agent is roughly quadratic in its own length.
4. **Outcomes.** Of 201 plan items since 09-10, 95 ended `done` (47%), 61 `deviated`, 17 `needs-more-time`.
5. **Rounds.** README rule 3 says two rounds maximum; plans reached round 5 (09-20) and round 6 (09-22). Nothing
   enforces it.
6. **Ceilings.** Self-counted and overrun (203 of 200, 125 of 120, about 101 of 100). The harness has a real cap,
   `maxTurns` in agent frontmatter (counts API round trips, returns a partial resumable result at the limit).

## Fixes

| id | fix | where | future-proofing |
|---|---|---|---|
| F1 | Ledger rows are DERIVED from session transcripts, never typed: per agent and for the orchestrator, `cost_units`, the four token classes, `final_context` (the old number, kept and named), api calls, tool uses, duration. Idempotent by agent id. Any agent type counts, including general-purpose. | `grocery/triage-cost.py` | a transcript with no usage block is BLIND (exit 3), never a zero |
| F2 | `-Closing` refuses a plan no ledger row names. | `validate-triage-plan.ps1` | the 09-21/22 gap cannot recur silently |
| F3 | Handoff refuses `round` above 2 unless the plan carries `round_override` (Brad's words and date). | same | README rule 3 becomes a gate |
| F4 | Every `planned` code item names its `lane` (money or ops) and `est_tool_calls`; the sum per lane must fit the lane ceiling (money 200, ops 100). Overflow is planned as `deferred-budget`: its queue id stays open and is due tomorrow. | same, README | "take the fewest items you can finish" becomes arithmetic the gate checks, not a hope |
| F5 | Agent definitions: `maxTurns` backstop (developer 180, ops 160, reviewer 90; above all but the top 5 of 30 developer spawns, the top 1 of 17 ops spawns and every one of 9 reviewer spawns measured); land ONCE through `ops\push-main.ps1`, never `git push`, never retry a refused push inside the agent; send long command output to a file and read the verdict lines; stop and hand back rather than grow the context. | three copies of each triage agent (repo, `C:\Codex\.claude\agents`, `~\.claude\agents`) | the harness enforces the turn cap; the copies are checked identical by `triage-cost.py --check-agents` |
| F6 | SKILL: a per-run budget of 30M `cost_units`, checked with `triage-cost.py --budget` before every spawn; one developer spawn per `publish_batch` (fresh, small context); no general-purpose spawns; the scheduled session ends at STEP 5 and follow-on work starts a fresh session; the report quotes `cost_units` per `done` item. | `~\.claude\scheduled-tasks\grocery-alert-triage\SKILL.md` | spend is measured by a script between spawns, not self-counted |
| F7 | Baseline and bar written before the next run. | `design/MEASURE-triage-token-spend-2026-09-24.md` | re-measure after 5 runs |
| F8 | Memory: the ledger unit trap, and the cost-controls memo updated. | memory store | recall on the next "is triage efficient" question |

The budget (30M) and the maxTurns values are first plausible numbers taken from the measured runs above (18M, 26M, 45M
single-day; developer calls 67 to 256 per spawn), not the survivors of a sweep.

## What is NOT changed

No gate, guard or threshold on the board is weakened; the reviewer still diagnoses every Class A item and every item
still needs `root_fix` / `must_fire_case` / `clean_twin`. Tiering, RETURN routing and the weekly lane are unchanged.
