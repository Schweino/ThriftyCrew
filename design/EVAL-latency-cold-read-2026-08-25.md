# EVAL: Where the minutes go - a cold read of per-recipe latency

Date: 2026-08-25. Author: the judge-contract build session, on Brad's direction after the jc1 drill.
Status: EVALUATION ONLY. No fixes are proposed in detail and nothing here is ordered; every lever is
named so Brad can rank them. Measured off two lane logs this session can vouch for line by line:
`meal-prep\runs\hunt-2026-08-24-v3-phase6b\lane-log.jsonl` (24 recipes ruled, 2 published, ~106 min
of active span across its segments) and `C:\tmp\jc1\run\lane-log.jsonl` (today's 3-candidate drill,
16.1 min to park 2 recipes at pricing).

The question asked: a single recipe end to end should take about 2 minutes, and it takes 16 to 37.
Why, structurally.

## 0. The verdict in one paragraph

The system's unit of spend is the JUDGMENT DISPATCH: a fresh headless session (~18k fixed input,
~7s startup, measured in v3 4.1a) that then takes API turns, and a turn costs 10 to 60+ seconds of
wall clock depending on whether it calls tools. A recipe today rides a SERIAL CHAIN of 6 to 10 such
dispatches (decide share, map share, registrar per new commodity, price when blocked, write, QA,
QA repair sometimes, audit share, audit repair sometimes), and the expensive dispatches spend most
of their turns on RETRIEVAL - fetching labels, grepping namespaces, re-deriving arithmetic - not on
the judgment the stage exists for. The judge-contract build just removed the retrieval half from
write and audit and part of map; the drill shows what is left. Two minutes is not reachable by
tuning this chain. At the plan's own post-build targets the chain still sums to roughly 5 to 7
minutes serial; 2 minutes per recipe exists only as a THROUGHPUT number at lane width, or after a
structural collapse of the per-recipe tail into one or two dispatches. Both of those are Brad-level
decisions, which is why this is an evaluation and not a patch.

## 1. The measured decomposition

### 1.1 jc1 drill (today, post-judge-contract, 2 recipes in flight)

16.1 minutes of wall from first pop to park. Where it went:

| stage       | wall     | share | turns | sec/turn | note |
|-------------|----------|-------|-------|----------|------|
| mapper      | 12.3 min | 77%   | 12    | 61       | 15 of 19 residual lines needed label acquisition |
| pricer      | 1.2 min  | 7%    | 6     | 12       | evidence pre-gathered; unusable stores parked it |
| registrar   | 0.9 min  | 6%    | 10    | 5.5      | one new commodity (prosciutto) |
| decider     | 0.5 min  | 3%    | 1     | 31       | 3 candidates ruled in one turn |
| pre-pass    | 0.5 min  | 3%    | 0     | -        | mechanical store gathering |
| mechanical  | 0.1 min  | <1%   | 0     | -        | preresolve, verify x2 |
| local       | 0.03 min | <1%   | 0     | -        | both extractions, rung 1 |

Write, QA and audit never ran (both recipes parked on one PENDING term), so the drill measured the
front half only - and the front half alone is already 8x the 2-minute budget.

### 1.2 6b (pre-judge-contract, the baseline run)

~106 min active span, 24 recipes ruled, 2 published. Judgment wall clock sums to ~154 min, so the
lanes genuinely overlap; the span is not idle-dominated.

| stage         | dispatches | wall     | sec/turn (where stamped) |
|---------------|------------|----------|--------------------------|
| mapper        | 5          | 52.9 min | 26-61 |
| repair writers| 3          | 21.4 min | 8-23  |
| pricer        | 7          | 21.3 min | 12-19 |
| writer        | 4          | 17.7 min | 11-15 |
| auditor       | 3          | 16.3 min | 14    |
| registrar     | 12         | 12.0 min | ~5 (fast turns, many of them) |
| decider       | 4          | 7.6 min  | one turn per dispatch, 16-186s each |
| source-qa     | 4          | 4.4 min  | 9-12  |
| pre-pass      | 8          | 3.8 min  | mechanical |
| mechanical    | 17         | 0.9 min  | free  |
| local extract | 12         | 0.1 min  | free  |

42 judgment dispatches for 2 published recipes: 21 dispatches per publish. Most of the ruled
recipes were correctly rejected cheap (band, dupe), so that ratio overstates steady-state waste,
but the shape is honest: the pipeline is dispatch-dense.

### 1.3 One real recipe's serial chain (6b wave 2, creamy-roasted-garlic-chicken)

Summing only the dispatches this recipe actually waited through, ignoring queue idle:
decide:8x 154s + map:3x 561s + registrar 41s + price batch 184s + write 205s + qa 87s + qa repair
109s + re-qa 56s + audit 388s + audit repair 459s = **~37 minutes** from pop to wave verdict, for a
recipe that needed one QA repair and rode a wave that needed one audit repair. A clean recipe on
the same run shape is ~20-25 minutes.

## 2. The unit economics

Everything above reduces to three numbers:

1. **A dispatch costs ~7s startup + ~18k fixed input** (measured, v3 4.1a adapter drill) before it
   does anything, and creates its prompt cache from cold.
2. **A turn costs 10-60+ seconds.** Toolless reasoning turns run ~10-20s (source-qa 9-12, pricer
   12-19, writer 11-15). Tool-using turns run 25-60+s (mapper 26-61: each one is a WebFetch or FDC
   read plus a full re-read of the accumulated context). One BIG single turn over a dossier runs
   30-190s (the decider) - the model thinks once over everything and answers once.
3. **Context re-reads scale with turns.** Cost is turns x ~50k (the 6b finding that motivated the
   whole judge contract). Latency is turns x sec/turn. Both are attacked by the same move: fewer
   turns, which means the daemon hands the agent what it would otherwise fetch.

The decider is the existence proof at both ends: dossier in, schema out, 1 turn, 27k, and its wall
is dominated by a single thinking pass. Every stage that still takes >2 turns is spending them on
something the daemon could gather or already has.

## 3. The 2-minute arithmetic

At 15-30s per toolless turn plus 7s per session, a 2-minute budget buys **4-5 turns TOTAL across
the whole per-recipe chain, in at most 2-3 dispatches**. Compare:

- Today (jc1 front half alone): 12 mapper turns + 10 registrar turns + 6 pricer turns = 28 turns
  before a word of prose.
- At the judge-contract plan's own targets, fully met: map <=6/batch (~1.5 turns per recipe at
  batch 4) + write <=4 + QA ~6 + audit <=10/wave (~1 per recipe) + decide ~0.1 + registrar ~9 per
  NEW commodity + pricer ~6 per blocking term. A clean no-new-ingredient recipe: ~13 turns across
  5 dispatches = **~5-7 minutes serial**. A recipe with one new commodity and one unpriced term:
  add ~4-6 minutes.

So: the current build direction, completed and hitting every target, lands at 5-7 minutes serial
latency, not 2. The remaining 3x does not live in any stage's turn count. It lives in the CHAIN
SHAPE: five to eight separate sessions, each with startup, cache creation, and its own turns, run
one after another per recipe.

Two readings of "2 minutes," with different verdicts:

- **Throughput at width** (the number PLAN v3 states and the Thursday run measures): 24 recipes
  through a 106-minute active span was already 4.4 min/recipe of throughput on 6b WITH all the
  waste this session measured. With map/write/audit turns cut to targets and lanes kept full,
  2-3 min/recipe throughput is arithmetic, not aspiration. This needs no architecture change.
- **Single-recipe serial latency**: 2 minutes requires the per-recipe tail to collapse into one or
  two dispatches total, plus mechanical everything else. That is an architecture change.

## 4. Findings, ranked by leverage (no fixes designed here)

**F1. Label acquisition is the single largest wall item and is mechanically automatable.**
77% of the drill's wall was one mapper dispatch, and 15 of its 19 residual lines had no FDC shelf
candidate, so the agent fetched labels itself at ~60s/turn - then cited `fdc:` ids for all nine
rows it returned, proving the data was reachable by the offline tool that already exists
(`fdc_lookup.py`). The plan's premise that "candidates arrive" is false in practice: nothing fills
the cache for a run's terms, and the cache key is the recipe's phrasing (`Parsley leaves` misses
`parsley`; 5 of the 15 misses were foods the cache already held). This is the biggest single
minutes-per-recipe lever in the system and it is retrieval, not judgment.

**F2. The registrar is a per-commodity serial toll worth one decider-shaped rethink.**
12 dispatches and 12 minutes of wall on 6b; 10 turns for ONE commodity on jc1 - after the daemon
already hands it the near-miss evidence block. Its turns are its own greps and feed reads across
the three namespaces, i.e. the auditor's old shape: an OBLIGATION to fetch what could be shown.
The decider rules 8 candidates
in one turn from one dossier; the registrar rules 1 in ten turns. Same gate, same authority, the
difference is only what arrives pre-gathered and whether proposals batch.

**CORRECTED 2026-08-25, same day, while writing the F1-F7 plan against the code.** This finding
originally added "dispatched once per proposal, serially, inside assemble." That is stale: pass-1
concurrency with the sibling-collision re-check landed in commit c36879cd, and 6b's 12 serial
registrar dispatches predate it. The live defects are turn economy and session count only, which
is what PLAN-latency-F1-F7 section 4 addresses.

**BUILT 2026-08-25 (F2).** Both live defects are closed the way this finding described: ONE dispatch
per slug-batch of proposals carrying one dossier and returning one schema'd verdict array, and the
dossier now pre-gathers the rest of the registrar's own checklist - the live feed's price cell per id,
the declared-same-thing pairs, and label greps - beside the near-miss block it already had. The
collision re-check is unchanged and still re-adjudicates a colliding pair, now as a batch of one each
with the sibling named. Turn and token numbers against this finding's 10-turns-per-proposal go in the
H3 drill report; nothing here is claimed until that measurement exists.

**F3. The per-recipe tail is four sessions where the content could support one or two.**
write, then source-qa, then (sometimes) qa-repair, then re-qa - each a fresh session over largely
the SAME material: the transcription, the skeleton, the prose. CHANGE W already renders that
material inline for the writer; QA then re-receives it in its own session an average of 60-90s
later. Merging judgment stages weakens independence of checks, which is a gate question and
explicitly Brad's, not a build-time convenience - but it is where the last 3x lives, and no amount
of turn-trimming inside the existing chain reaches 2 minutes without it.

**F4. Repairs double the lanes they land in, and half of that class is now dead.**
6b: repair writers were 22% of tokens and ~21 minutes of wall; wave 1's repair alone was 12
minutes plus a 5-minute re-audit. The judge-contract build deleted the redrift class outright and
routed recipe-local audit/QA repairs onto the field-patch road (target <=5 turns vs the measured
20). Shared-data repairs keep the full road by design. What remains structural: every NO-GO still
costs a scoped re-audit dispatch, and QA's repair cycle is two extra sessions on the chain.

**F5. Turn latency is not uniform, and the slowest turns sit in the most turn-heavy stage.**
Mapper turns cost 2-4x everyone else's (26-61s vs 9-19s) because they are tool turns on the
largest accumulated context under the Opus pin. The pins are ratified and out of scope (v3 s11);
the observation is that removing ONE mapper turn buys as much wall as removing three writer turns,
which is another way of saying F1 is the lever.

**F6. The price lane is a latency cliff only for recipes with unpriced ingredients - but it can
park the whole tail.** The singleton and the attended-store reality are architecture (not
relitigated here). The jc1 consequence is still worth stating: one PENDING term parked both
recipes and the run's write/audit lanes never executed. Any recipe with a genuinely new ingredient
inherits minutes-to-hours of latency that no other lane can pay down, and unattended runs cannot
finish such recipes at all. The 2-minute figure can only ever describe recipes whose ingredients
are already board-priced.

**F7. The mechanical floor is effectively free and is not the problem.**
Extraction (rung 1, cached page): 8-18s. Preresolve: 5s. Skeleton, spec build, preaudit battery:
seconds. The pre-pass: 30-50s, zero tokens. Everything the estate moved to code costs nothing
worth optimizing. The entire latency problem is the judgment dispatches and their chain shape.

## 5. What this does NOT question

The gates and thresholds; the price singleton; the registrar's existence and authority (only its
turn ECONOMY, per F2); the model pins; QA one-repair; the wave boundary; the auditor's authority
and tools. Nothing in section 4 proposes weakening a check - every lever is "move retrieval to the
daemon" or "merge sessions over identical material," both of which are the same shape as the
already-ratified judge contract, one step further.

## 6. The honest bound

- Hitting the existing judge-contract targets (map <=6, write <=4, audit <=10, repair <=5) gets a
  clean recipe to roughly **5-7 minutes serial, 2-3 minutes throughput at width**. The write and
  audit halves of that are built but UNMEASURED (the drill parked before reaching them); the map
  half measured 12 turns against the <=6 target, and F1 explains the gap.
- **2 minutes serial** requires, beyond that: F1 (mechanical labels), F2 (a one-turn batched
  registrar), and F3 (a collapsed tail) - in descending order of certainty. F1 and F2 are the same
  proven pattern applied to the last two stages that lack it. F3 changes what a "stage" is and
  touches check independence, so it is a design conversation, not an extension.
- Recipes needing a new PRICED ingredient sit outside any 2-minute promise regardless (F6).
