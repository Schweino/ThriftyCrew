# BRIEF: redesign the map lane for speed, at zero cost to accuracy

Date: 2026-08-25. This file IS the prompt. Hand it to a fresh reviewer whole, or point them at it in
the repo. It is written to be read cold by someone who has never seen this codebase.

---

## THE PROMPT

You are reviewing one stage of a working food-pricing and recipe-publishing pipeline, with fresh
eyes, and your job is to find a **better architecture**, not to tune a setting.

**Repository: https://github.com/Schweino/ThriftyCrew** (branch `main`). Everything cited below is in
that repo at commit `fe0ed34c` or later, including the raw evidence from the run that prompted this.

### What the system does

It hunts dinner recipes on the open web, maps every ingredient to a canonical grocery commodity id,
prices those commodities across seven Omaha grocery stores, computes per-serving cost and macros,
and publishes finished recipes to a live site. Correctness is the product: a wrong ingredient mapping
means a recipe is priced against the wrong food, and a duplicate commodity id means the same food
carries two disagreeing prices while every per-file check reads green.

The pipeline runs as an async daemon with concurrent lanes (`hunt -> select -> extract -> map ->
price -> write -> qa -> audit -> publish`). Expensive judgment is done by LLM agents dispatched per
stage; everything mechanical is done by PowerShell and Python and costs nothing.

### The problem, stated as measurement

On 2026-08-25 a 3-recipe end-to-end run took **8 minutes 11 seconds** and published nothing. The
breakdown, from the pipeline's own instrumentation:

```
lane   calls turns trips  items      input     output      total  total_min
map        7     1    13     15    310,803     38,489    349,292        8.2

stage                     n  total_min  mean_sec   share  kind
map:3x                    1        7.8       469   95.9%  judgment     <-- ONE agent dispatch
map-preresolve            2        0.2         5    2.0%  mechanical
fdc-fill                  1        0.1         8    1.6%  mechanical
map-preresolve verify     3        0.0         1    0.4%  mechanical
```

**One agent dispatch is 95.9% of the run.** Every mechanical stage together is 18 seconds. There is
no plumbing overhead left to reclaim; the mapping dispatch *is* the run.

The goal is **3 to 4 recipes end to end in 6 to 7 minutes total** (not per recipe), including
pricing, writing, quality check, audit and publish. Today the mapping dispatch alone exceeds that
budget, and the full chain's measured floor is roughly 10 minutes before the price lane is even
entered.

### What that dispatch is actually doing

Decomposed from the session transcript (`meal-prep/runs/hunt-2026-08-25-t-shakedown/`):

- 13 tool round trips: 3 file reads, 3 web searches, 5 web fetches (several returned under 250 bytes).
  All tool time together is roughly 30 to 40 seconds.
- **The remaining ~430 seconds is generation and reasoning.** Two single reasoning blocks account for
  169 s and 135 s.
- Output was 38,489 tokens, of which only ~6,400 are visible payload. **~83% is reasoning.**
- Its input prompt is 28,586 characters for 3 recipes.

And the workload split, measured from what it returned:

| | count |
|---|---|
| purchasable lines it wrote a shopping ("buy") string for | **30** |
| residual lines it actually had to adjudicate | **11** |

**2.7 times more bulk transcription than judgment**, all inside one expensive reasoning context.

That single dispatch is asked to do **five different jobs at once**:

1. write a human shopping line for *every* purchasable ingredient (prose formatting)
2. adjudicate the *residual* ingredients the mechanical pass could not resolve (identity judgment)
3. go to the open web and transcribe nutrition labels for foods with no database row (retrieval and
   transcription)
4. propose new commodity ids for foods the catalog does not carry (identity judgment)
5. state a gram weight for every line at the source recipe's scale (arithmetic)

### The question

**Is there an architecture that makes this dramatically faster with ZERO loss of accuracy?**

Not a cheaper model, not a lower reasoning effort, not fewer checks. A different shape.

The obvious hypothesis, which you should attack rather than accept: jobs 1, 3 and 5 are bulk work
that does not need the expensive reasoning that jobs 2 and 4 require, and splitting them would let
the costly judgment run over 11 lines instead of 41. **Be aware this is an inference, not a proven
fact.** The reasoning content is cryptographically redacted in the transcripts, so nobody has
actually observed which of the five jobs consumes the time. The workload split (2.7:1) is measured;
the causal claim is not.

The strongest argument *against* splitting, which you must address: the mapper currently sees the
whole recipe at once, and some of its judgment plausibly depends on that. Ruling "is this ground
chicken a genuinely new commodity" may be better with the full ingredient list in view. A split that
is too clean could cost accuracy on the stage whose entire purpose is accuracy.

### Where to look

- `meal-prep/pipeline/hunt-daemon.py` - `map_lane` (~2207), `map_prompt` (~2565), `assemble_mapped`
  (~2148), `new_bid_proposals` (~2082), `registrar_rulings` (~1518), `preresolve` (~1258).
  Re-grep rather than trusting these line numbers.
- `meal-prep/pipeline/map-preresolve.ps1` - the mechanical pre-resolve that runs *before* the agent:
  the vocabulary match, the FDC nutrition shelf, `-Assemble`, `-NewBids`.
- `.claude/agents/recipe-ingredient-mapper.md` - the agent definition.
- `design/PLAN-hunter-judge-contract-2026-08-25.md` - the ratified pattern this estate uses
  everywhere else: **"the daemon gathers, the judge rules."** It has already been applied to the
  commodity registrar, the quality check and the wave auditor. **The mapper is the last stage that
  still gathers, transcribes AND rules in one breath.** That is the strongest clue available.
- `design/PLAN-latency-F1-F7-2026-08-25.md`, `design/PLAN-map-lane-latency-M1-M4-2026-08-25.md` -
  two prior optimisation rounds, with what worked and what did not.
- `design/EVAL-latency-lf1-drill-2026-08-25.md`, `design/EVAL-map-lane-latency-m1-drill-2026-08-25.md`,
  `design/EVAL-registrar-batch-2026-08-25.md` - measured drills. Note that two prior rounds of
  optimisation cut this stage's token cost substantially and **did not move its wall clock**.
- `meal-prep/runs/hunt-2026-08-25-t-shakedown/` - the raw evidence: `lane-log.jsonl` for the timings,
  `mapped-pre/*.rulings.json` for what the agent actually returned, `state/` for where each recipe
  died.

### What must not move

These are ratified and are not yours to trade away. A proposal that weakens any of them is refused
regardless of how much time it saves.

- **Every gate and threshold.** An id nothing approves never reaches the catalog. A recipe blocked on
  pricing parks rather than proceeding. No verdict is never a pass.
- **Local or mechanical code may RANK, but may never ASSERT an identity.** This is the founding rule.
  Mechanical code can say "these rows share a word"; only a judge may say "this is that food."
- **The commodity registrar's existence, authority and its collision re-check.**
- **The quality check's independence.** A stage checking its own work is worth nothing.
- **Model pins and reasoning effort.** The owner ruled on 2026-08-25 that Opus 5 at high effort is
  correct for this stage. Speed must come from a better shape, not a cheaper judge.
- The single-writer-per-file rule, and the daemon owning every write.

### Forks already closed, with the reason - do not re-propose these

Each was considered and rejected on evidence. Proposing them again wastes the review.

1. **Fuzzy or head-noun ingredient matching.** Shortening `garlic cloves` toward its head noun
   reaches `cloves`, which matches `Ground Cloves` - a wrong food served with mechanical confidence.
   Mechanical code asserting identity is the one thing the founding rule forbids.
2. **Parallelising the nutrition-database HTTP calls.** The API rate-limits, and a throttled key
   reads as "this food has no data," which the code calls the worst lie a nutrition lookup can tell.
3. **Folding the quality check into the writer**, or any merge that removes an independent reader.
4. **Lowering the model tier or the reasoning effort.** Ruled on, above.
5. **Querying the nutrition API directly with a demo key.** It silently throttles.

### What a useful answer looks like

- It names which of the five jobs genuinely need the expensive reasoning and which do not, **with a
  reason**, not an assertion.
- It states what accuracy risk each proposed split carries, and how that risk would be detected.
- It is **falsifiable**: it proposes a measurement that would show the redesign worked, and one that
  would show it failed. This estate reports missed targets with their numbers rather than softening
  them, and expects the same of a proposal.
- It distinguishes what it measured from what it inferred.
- If your honest conclusion is that the current shape is close to optimal and the 6-to-7-minute
  target is unreachable without giving something up, **say that plainly and show the arithmetic.**
  That is a legitimate and useful answer.
