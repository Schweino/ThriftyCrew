# WORKLIST: where the Recipe Hunter's tokens actually go, and what would fix it

Measured on the phase-6b proving run `hunt-2026-08-24-v3-phase6b`, 2026-08-24, from the daemon's own
C1 lane stamps and from the headless sessions' transcripts. This is the C2 sweep the 6b criteria block
asked for, arriving early because the numbers were bad enough to look at during the run.

**NOTHING BELOW IS BUILT. Every item is a proposal for Brad.** The 6b rules say C2/C4/C6-shaped work is
measure-first and that anything E-row-shaped is a proposal, not a follow-on build.

---

## 0. The mechanism, in one paragraph

`hunt_dispatch.py:331` bills `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`,
summed over every API round trip inside one headless session. **Each round trip re-reads the whole
conversation so far.** So a dispatch's cost is not the size of its prompt - measured uncached input is
1 to 53 tokens on every dispatch in this run - it is the size of its conversation multiplied by the
number of times the agent goes and looks something up. Because each tool RESULT also joins the
conversation, the cost is roughly quadratic in tool calls, not linear.

Traced through one mapper session, 47 assistant messages:

```
call  1   cache_read 14,365     <- agent definition + prompt
call  6   cache_read 20,693
call 42   cache_read 58,194
call 47   cache_read 61,590     <- the prefix has QUADRUPLED, and every call re-read it
```

**The proof that this is the whole story is the decider.** It makes ZERO tool calls, uses 2 API round
trips, and costs **2,519 tokens per candidate**. Same model tier, same estate, same run. Every
expensive agent in this pipeline is expensive for exactly one reason: it goes looking, repeatedly.

## 1. The measurement

Every closed dispatch of the 6b run, costed per item:

| dispatch | items | API calls | tool calls | dominant tools | input | in / item |
|---|---|---|---|---|---|---|
| decide:10x | 10 | 2 | **0** | none | 25,194 | **2,519** |
| decide:10x | 10 | 2 | 0 | none | 30,062 | 3,006 |
| map:5x | 5 | 41 | 22 | PowerShell 7, Read 6, WebSearch 4 | 1,061,220 | **212,244** |
| map:1x | 1 | 32 | 18 | **WebFetch 9** | 436,685 | **436,685** |
| map:1x | 1 | 47 | 22 | **WebFetch 10** | 577,141 | **577,141** |
| registrar:golden-beets | 1 | 11 | 7 | Grep 4 | 69,270 | 69,270 |
| registrar:chicken-drumsticks | 1 | 21 | 16 | Grep 7, PowerShell 5 | 227,068 | 227,068 |
| registrar x8 total | 8 | - | - | Grep-heavy | ~797,000 | ~99,600 |
| pricer queue batch 1 | 2 terms | 35 | 24 | **PowerShell 12, Bash 8** | 741,705 | **370,852** |

Cache read is 93-95% of input on every expensive dispatch. **Zero re-asks across all of them** - this
is not the 6a defect repeating, and no fix has regressed. It is a structural cost the earlier phases
never had enough recipes to see.

---

## 2. THE WORKLIST, worst offender first

### A. Seed extraction so the mapper never runs a batch of one  (C3 lever - seeding order)

**Evidence.** Per RECIPE, across all four mapper batches this run:

| batch | input / recipe | seconds / recipe |
|---|---|---|
| `map:1x` | 436,685 | 378 |
| `map:1x` | 577,141 | (unpaired) |
| `map:2x` | **444,975** | **449** |
| `map:5x` | **212,244** | **167** |

**CORRECTED 2026-08-24, same day, before anyone builds on it.** The first write-up of this item said
"batching five is 2.1 to 2.7x cheaper", comparing the best batch against the worst and reading as though
batch size alone did it. It does not: `map:2x` was WORSE per recipe than `map:1x` on BOTH axes. Batch
size correlates with efficiency; ingredient NOVELTY drives it at least as hard, and `map:2x` carried two
ingredient-heavy recipes (one of which parked on a garnish line). The honest claim is narrower: **the
5-recipe batch ran at ~2x the token efficiency and ~2.3x the speed of the singletons, and no batch of
2 has yet beaten a batch of 1.** Anything built here must be measured against batch CONTENT, not just
batch size, or the win will not reproduce.

**Cause.** The extraction ladder settles pages serially, so the first pages trickle into the map
channel one at a time, and `Chan.take_batch` correctly sweeps whatever is queued rather than waiting.

**THE TRAP, PINNED.** The fix is NOT a fill-wait in the channel. `take_batch` must never wait to fill a
quota - that policy was measured (B3) deadlocking against the WIP limit and adding 8-10 minutes to
first flow, and its docstring says so. The lever is **seeding order and backlog depth**: get several
extractions settled before the map lane first wakes, e.g. by seeding the whole accepted set into
extraction up front, or by letting the map lane's FIRST take (and only the first) coincide with a
settled-count the pool lane already knows.

**Risk.** Any wait risks reintroducing B3. Whatever is built must be fixtured to prove the lane cannot
park, with the wait removed as the neuter proof.

**Estimated saving on a 12-recipe run: 500k-900k tokens.**

### B. Hand the registrar its evidence, exactly as the decider is handed its dossier

**Evidence.** Eight registrar dispatches cost ~797,000 tokens, 58k-227k each, at 7-16 tool calls each,
dominated by **Grep 4-9 times** over the three commodity namespaces.

**Cause, and it is an avoidable one.** `registrar_prompt` (hunt-daemon.py) passes the slug, the
ingredient line, the proposed id, the mapper's case, and a **600-character** slice of the pre-resolve
evidence. It does NOT pass the namespaces. Meanwhile the daemon **already reads all three commodity
namespaces itself** - that is how `-NewBids` derives the proposal list and how the gate became
unskippable-by-omission in 6a. So the orchestrator reads the files, throws the read away, and pays a
Fable session to grep them again.

The mapper's own agent definition already states the principle this violates: *"THE TABLE IS THE
ESTATE, ALREADY READ FOR YOU... Each re-read costs a turn, and a turn re-reads the entire accumulated
context with it."* The registrar never got that treatment.

**Risk. LOW, and this is the item to do first if only one is done.** It gives the gate MORE evidence,
not less. The gate does not weaken; it stops paying to fetch what the caller already holds. The one
thing to get right: hand it the matching ROWS and near-misses, never a conclusion - the registrar must
still rule.

**Estimated saving: 50-70% of ~797k on this run, and it scales with every new commodity id forever.**

### C. Stop the nutrition label from entering the judgment conversation

**Evidence.** The two singleton mapper dispatches made **9 and 10 WebFetch calls**. Each fetched page's
full text then rides in the conversation for every one of the ~30 round trips that follow. This is the
quadratic term.

**Cause, and the mapper is NOT misbehaving.** Its agent definition sanctions exactly this: *"The ONE
read still worth a turn is a nutrition LABEL for a food the table marks as having no food-macros-db
row."* Nine novel ingredients means nine label reads. The behaviour is correct; the placement is wrong.

**Two sub-items.**

- **C-i. A label cache.** There is no nutrition-label cache anywhere in `meal-prep\`. `fresh thyme`
  fetched for recipe 1 is fetched again for recipe 7. A content-addressed cache in the shape of
  `fetch-recipe.ps1`'s already exists as a pattern to copy.
- **C-ii. A label PRE-PASS.** `map-preresolve.ps1` already resolves what it can mechanically before the
  mapper is dispatched. Labels could join it, so the mapper receives a label BLOCK in its table instead
  of fetching a page - the page text never enters the priced conversation at all.

**Risk. MEDIUM, and it is an accuracy risk, not a cost one.** Section 10 and the agent definition both
forbid *"a website summary over label data"*. A pre-pass must hand over the LABEL - serving size in both
household measure and grams, and the macro figures - or it converts a label transcription into a
summary, which is the exact defect class the food DB exists to prevent. If that cannot be guaranteed
mechanically, build C-i alone and leave the fetch where it is.

**Estimated saving: the largest structural win after A, but unquantified until C-i is measured.**

### D. The pricer's shell loop  (this is C2 verbatim)

**Evidence.** One pricer invocation for **2 terms**: 35 API round trips, 24 tool calls (PowerShell 12,
Bash 8), **741,705 input - 370,852 per term.** The mechanical pre-pass had already run on those terms
and reported `MATCHES 8, UNUSABLE 6` before the pricer was dispatched.

This is the N-shell-calls pattern B2 fixed in one place and nobody ever swept. The 6b criteria block
names the writer's in-place field fills and any consult loop as the other places to look; the pricer is
now the confirmed worst instance.

**Risk. MEDIUM.** Rule B and *"unchecked is never not-carried"* do not move. The pricer must still
ATTEND the stores no pre-pass reaches (Hy-Vee in its own tab, Walmart and Aldi through Brad's Chrome)
and must still rule from the estate's own captures where they answer. What can change is how many
separate shell invocations it takes to get evidence it already has coming.

### E. Larger price batches  (the same C3 lever as A)

`PRICE_BATCH` is 10; the lane's first invocation took **2 terms**. Same cause as A - terms trickle out
of the map lane - and the same forbidden fix. Per-term cost should fall the way per-recipe cost falls
between `map:1x` and `map:5x`, but this is unmeasured and should not be assumed.

### F. THE INSTRUMENT IS BLIND TO THE COST DRIVER

`-LaneSummary`'s `turns` column reads **1** for a session that made 47 API round trips. That is not a
bug - `turns` is `hunt_dispatch`'s `calls`, which counts billed CLI invocations so a re-ask reads as 2,
and criterion 1 depends on it meaning exactly that. But it means **the estate's cost instrument cannot
see the thing that drives its cost.** Diagnosing this run required going outside the pipeline entirely,
to `~\.claude\projects\*.jsonl` transcripts, which is the transcript archaeology C1 was built to end.

**Proposal:** stamp the real API round-trip count and the tool-call count alongside `turns`. Without it,
every item above is unverifiable after the fact and the next regression is invisible again. This is the
same class as the 6a aftercare finding, where `-LaneSummary` silently reported zero tokens on every
daemon lane.

**Risk. LOW.** Additive fields; `turns` keeps its meaning and criterion 1 is untouched.

---

## 3. Accuracy items found in the same run (not cost)

### G. An ingredient line that is a LIST OF ALTERNATIVES has no gram weight

`one-pan-chicken-with-sweet-potatoes-kale-and-cranberries` parked at:

> `'Prepared brown and wild rice blend, brown rice, quinoa, or cauliflower rice' has no gram weight from
> the engine or from a ruling`

The source line offers a CHOICE, not an ingredient. There is no single gram weight, the assembler
refused to invent one, and the recipe parked rather than publishing on a fabricated number. **The
pipeline behaved correctly** - this is the never-a-silent-zero rule earning its keep. What is missing is
a decision about what SHOULD happen to an alternatives line, and a fixture freezing the class either
way. Owed same-day per the 6b criteria.

### H. The ingest pre-filter can be narrower than a run band

`harvest.py` qualifies at hard-coded 400-650 cal / <= 35 carbs. A run band admitting 36-40 g carbs
cannot reach those candidates - measured: 3 stranded under the 6b band. Fix is a re-qualify pass over
numbers already stored on each candidate; no re-fetch needed. Recorded in the plan's 2026-08-24
correction block as a proposal.

### I. Cosmetic

`hunt-daemon.py:1115` emits `SyntaxWarning: invalid escape sequence '\m'` on every invocation - an
unescaped backslash in a docstring. One-line fix, held out of the run's commits so the file was not
edited while the daemon was executing it.

---

## 4. Explicitly NOT proposed

- **No model-tier change.** Section 11 forbids it, and the residue principle says v3 makes each
  remaining call harder. Every number above is a plumbing problem, not a model problem.
- **No gate weakened, and no gate skipped to save tokens.** The registrar, the band gates, Rule B and
  the auditor all stay. Item B makes a gate cheaper by feeding it better, which is the opposite move.
- **No fill-wait in any channel.** B3 measured that deadlocking.
- **C4 (lane-log spawn tax) and C6 (effort tuning) remain measure-first.** Nothing in this run's data
  justifies either yet, and neither was measured here.

---

## 5. What could move to Qwen (asked by Brad, 2026-08-24, during the run)

Judged against section 1.4's doctrine, which section 10 makes an invariant. One measured number governs
the whole question: **asserting a MATCH is 37% false at 0.90-0.98 confidence, so a local YES is at most
a lead.** Structured transcription, by contrast, measured 1.000 valid strict JSON and is "local by
default, always mechanically verified".

### J. Nutrition label transcription - the one real opportunity

This is item C's quadratic term seen from the other side. Local transcribes, Claude rules:

- **LOCAL:** transcribe the label VERBATIM - every serving row, every number - substring-proven against
  the page text, in the shape `local_extract.verify_split` already uses at rung 1.
- **CLAUDE:** choose which serving basis applies and which food it is. Picking between "per 100 g" and
  "per 2 tbsp" is nearer a match assertion than a transcription, and the mapper's definition requires
  the household measure and the grams to AGREE - that is a ruling, not a copy.

The saving survives the split, because the saving is that the PAGE TEXT never enters the priced
conversation: Claude receives a compact label block instead of a fetched web page that then rides along
on ~30 round trips.

**Two conditions, both non-negotiable.**
1. **Substring proof cannot prove ABSENCE.** Section 4.3 already names this about rung 2 truncation - a
   page cut at the slot ceiling still verifies line by line with ingredients silently missing. A label
   verifier must additionally assert COMPLETENESS (serving size plus every macro the food DB needs), or
   a dropped line reads as clean.
2. **No verifier, no local placement.** Doctrine rule 1.

### K. Two things that look like Qwen work and are not

The registrar's 4-9 Greps (item B) and the pricer's 12 PowerShell + 8 Bash calls (item D) are expensive,
but they are dictionary lookups and shell invocations, not model work. Qwen would be slower AND
wrong-shaped. Both are already fixed by handing over evidence the caller holds; putting a GPU on them
would be paying for the same lookup twice.

### L. What may never move, and why

| stage | why it stays frontier |
|---|---|
| commodity-registrar | its whole job is asserting identity - the 37% number |
| the mapper's `canon_item` decision | same |
| the pricer's adjudication | "this row is the ingredient" is a named forbidden case |
| recipe-dedup-selector | "these two dishes are the same" is also named - and it costs 2,519 per candidate, so there is no upside to weigh against the risk |
| recipe-writer | Brad's voice, doctrine rule 3 |
| source-QA and the batch auditor | section 11 puts cheapening the audit tier out of scope; its 31% bought every correct NO-GO this estate has |

### M. The constraint that is NOT throughput

Qwen is fast enough: 2.74 s per short call, 3.6x at jobs=4, and this run's extraction averaged 26 s per
page. Nine labels fanned 4-wide adds perhaps 15-30 s per recipe to a lane that runs CONCURRENTLY with
the Claude lanes, so wall clock barely moves. The real cost is CARD OWNERSHIP: llama-server (~13.5 GB)
and the sidecar (~3.5 GB) cannot co-reside, so more local work means holding the card longer, against
the 07:00 ad pull, the 08:00 capture and the nightly's 21:30-06:30. Scheduling, not throughput.

### N. Cheaper than any of the above

The alternatives ingredient line that parked a recipe (item G) could be FLAGGED before the mapper is
ever dispatched. Flagging is explicitly permitted locally - but this case does not need a model at all,
only a check for an `or`-list in an ingredient line.

---

## 6. SPEED (Brad asked whether the improvements cover wall clock too; the first draft was cost-only)

**They do, and it is the same mechanism, because round trips are SERIAL inside a session.** Every
re-read of the conversation costs milliseconds as well as tokens, so the cost levers in section 2 are
speed levers with no change of plan. Measured across this run's dispatches:

| dispatch | input | sec | tokens/sec |
|---|---|---|---|
| map:1x | 436,685 | 378 | 1,155 |
| map:2x | 889,950 | 898 | 991 |
| map:5x | 1,061,220 | 837 | 1,267 |
| registrar (avg of 9) | ~110,000 | 64 | 1,718 |
| pricer batch 1 | 741,705 | 217 | 3,417 |
| write (avg of 2) | ~1,240,000 | 300 | ~4,100 |
| audit REPAIR | 2,890,062 | 717 | 4,030 |

The tool-heavy stages (mapper, registrar) run at ~1,000-1,700 tokens/sec because they spend their time
waiting on tool round trips; the think-heavy ones (write, audit) run at 4,000-5,000. **The expensive
dispatches are the slow ones, and for the same reason.**

### 6.1 The run achieved only 1.54x effective concurrency
98.0 lane-minutes of dispatch work compressed into a 63.5-minute wall span. The design permits far more
(v2 section 2.4: 3 extractors, 2 mappers, 3 writers, 2 QA, 1 pricer). The cause here was STARVATION, not
a scheduling defect: 9 accepted recipes, of which 3 parked and 2 retired at the band gate, so the lanes
had nothing to overlap. **This number is not a defect to fix; it is a reason to distrust any wall-clock
figure taken from a thin run** - including this one. A fuller pipeline would overlap far more.

### 6.2 The audit path dominates a small wave
The three audit-lane dispatches cost 1,307 s (21.8 min) - a third of the run's wall clock - to certify
TWO recipes, and the repair dispatch alone was 717 s and 2,890,062 tokens, the single most expensive
dispatch of the run. Amortised over a wave of 10 that is exactly the trade section 11 defends. Over a
wave of 2 it is the dominant cost. **The lever is not a cheaper auditor - section 11 puts that out of
scope - it is fuller waves.** See item A and OPEN Q 4.5.

### 6.3 What each cost item is worth in SECONDS
- **A (batching):** `map:5x` ran at 167 s/recipe against 378-449 s for the small batches. On the
  measured spread, the single biggest wall-clock lever in the pipeline.
- **B (registrar evidence):** 9 registrar dispatches x ~64 s = ~10 minutes of the run. Cutting round
  trips cuts that roughly in proportion.
- **C / J (labels out of the conversation):** the mapper's 9-10 WebFetches are round trips AND large
  context; both terms are wall clock. And a Qwen label pass runs CONCURRENTLY with the Claude lanes, so
  its own 15-30 s per recipe hides inside work already happening.
- **D (pricer shell loop):** 24 tool calls for 2 terms took 217 s. The pre-pass had already answered.
- **F (instrumentation):** `-LaneSummary` already reports `mean_sec` and `total_min` per lane, so speed
  regressions ARE visible today. The blind spot is only in attributing them - the round-trip count is
  what ties a slow lane to a cause.

### 6.4 The headline
**63.5 wall minutes produced 2 publishable recipes: ~32 minutes per published recipe.** Section 7's
target and 6a's 453 s / ~227 s per-recipe map figures are not comparable to it, because this run never
reached a steady state (criterion 3 is unreportable for the same reason). Treat 32 min/recipe as a
CEILING measured on a starved pipeline, not as the pipeline's speed.

---

## 7. THE 5-MINUTE TARGET (Brad, 2026-08-24: "it needs to get under 5 minutes per recipe")

Modelled from this run's own per-stage seconds. 6b measured **~32 wall minutes per published recipe**.
The target is a 6.4x improvement, and **it is reachable - but not by optimising tokens.**

### 7.1 Where the 98 minutes of work went

| lane | dispatch-seconds | share | normalised |
|---|---|---|---|
| map | 2,794 | 47.5% | 310 s per ACCEPTED recipe |
| audit | 1,307 | 22.2% | 1,307 s per WAVE -> 131 s/recipe at wave size 10 |
| price | 754 | 12.8% | 84 s per accepted |
| write | 600 | 10.2% | 300 s per written |
| select | 301 | 5.1% | 14 s per candidate |
| qa | 120 | 2.0% | 60 s per written |
| extract | 3 | 0.1% | local, free |

### 7.2 The model

```
THIS RUN (yield 22%, no fixes, starved)     work 2327 s/published  @1.5x -> 25.2 min
this run's cost/yield, concurrency 3        work 2327 s/published  @3.0x -> 12.9 min
yield 80%, map unchanged, concurrency 3     work 1001 s/published  @3.0x ->  5.6 min
yield 80% + map fixes (A/B/C/D), conc 3     work  838 s/published  @3.0x ->  4.7 min
yield 90% + map fixes, concurrency 3.5      work  800 s/published  @3.5x ->  3.8 min
```

### 7.3 THE DOMINANT TERM IS YIELD, AND IT IS NOT IN THIS WORKLIST

9 accepted, 2 published: **22%**. Concurrency alone takes 25.2 min to 12.9 and stops. Yield alone,
with no token work whatsoever, takes it to 5.6. Where the 7 losses went:

- **3 parked** on a line with no gram weight - the alternatives line and the garnish line
  (OPEN-ITEMS 2.1, 2.2). Every one had already been paid for through map, registrar and pricing.
  **Blocked on Brad's answers to OPEN Q 4.1 and 4.2 - nothing can be built until those land.**
- **2 retired at the band gate.** CORRECT losses - but wasted ones. The pop passed them on the source
  page's own claims and the gate ruled on our recompute (OPEN-ITEMS 3.1); both died after the most
  expensive stages had run. Moving that rejection earlier is pure win with no gate touched.
- **2 unfinished** at `mapped` when the run ended.

**So the largest single speed lever in the pipeline is three parked recipes and a pre-filter that
trusts source numbers.** Neither is a token problem, and neither appears anywhere in sections 2-6.

### 7.4 Three multiplicative parts. None alone gets there.

1. **YIELD 22% -> 80%+.** Answer 4.1/4.2, fixture the two park classes, and close the pop/gate
   divergence in 3.1. Biggest factor by a wide margin.
2. **CONCURRENCY 1.54x -> ~3x.** This run STARVED - the lanes had nothing to overlap. It needs a deeper
   qualifying backlog, which is OPEN-ITEMS 5.1 (re-qualify the pool against the run band) plus enough
   harvest to keep it fed. No new scheduling machinery is implied; v2 section 2.4 already permits 3
   extractors, 2 mappers, 3 writers, 2 QA.
3. **ROUND TRIPS - items A, B, C/J, D.** Worth ~130 s/recipe off the map lane on the modelled numbers.
   The smallest of the three, and the only one anybody has been working on.

### 7.5 Two constraints that bound this, and one wall

- **Full waves are load-bearing.** The audit costs 1,307 s per wave whatever the wave holds: 131 s per
  recipe at size 10, but **653 s per recipe at size 2**, which is what 6b actually paid. A thin wave
  cannot hit 5 minutes no matter what else is fixed.
- **The write lane is 300 s/recipe** and the auditor is protected by section 11. Neither is a target.
- **THE WALL: the price lane is a singleton and section 10 forbids widening it.** At 84 s per accepted
  recipe it has real headroom today - roughly 43 accepted/hour against one lane's 3,600 s - so it is not
  the bottleneck at 5 minutes. But it is the one lane that cannot be widened, so it is where scaling
  eventually stops, and any target below ~90 s/recipe needs that conversation first.
