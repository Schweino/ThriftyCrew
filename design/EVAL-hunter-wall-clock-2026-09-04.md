# EVAL: where the Recipe Hunter's WALL CLOCK goes (2026-09-04)

> **CORRECTED the same day - read section 2b before acting on anything here.** The first
> pass concluded the unit of wall clock is the API round trip. It is the OUTPUT TOKEN, at
> ~81 per second, and the difference reverses this file's advice on batching and on
> concurrency. Sections 3 to 8 are left standing because their MEASUREMENTS are sound and
> the reasoning is worth seeing corrected rather than deleted.

Brad, 2026-09-04: "We need to figure out WHY it takes so long. We're a machine - it should not take
so long to send 10 recipes through our system. We need to figure out where the time burn is happening
and re-think it architecturally."

Measured on `meal-prep\runs\hunt-2026-08-27-highprotein` - the largest run the estate has done, 12
recipes published - from its own `lane-log.jsonl` start/end pairs. This is a LATENCY eval; the token
eval is `EVAL-hunter-repeat-work-2026-09-04.md` and its findings shipped the same day.

## 1. The headline: three quarters of the "25.6 hours" is dead air

| measure | value |
|---|---|
| run span, first lane line to last | **25.6 h** |
| wall time with SOMETHING running | **6.5 h (25%)** |
| idle, nothing running at all | **19.1 h** |
| ...of which one overnight gap | **10.9 h** (19:56 -> 06:53) |
| summed stage time | 13.2 h |
| effective concurrency (13.2 / 6.5) | **2.03x** |

**The run was not slow. It was stopped.** 17 daemon starts, a 10.9-hour overnight halt, and four more
gaps over an hour. Any statement of the form "a run takes 25 hours" is a statement about supervision,
not about the pipeline. The number that matters is **6.5 hours of activity for 12 published recipes**
- 32 active minutes per published recipe, which is exactly the ceiling the token eval quoted.

## 2. The pipeline's own machinery is not the problem

| kind | stages | wall time | mean |
|---|---|---|---|
| **AGENT** (an LLM session) | 245 | **12.18 h (92%)** | 3.0 min |
| mechanical (scripts) | 436 | **1.03 h (8%)** | 0.1 min |

436 invocations of the spec builder, the cost engine, the preaudit battery, the card builder, the
publish chain and the guards cost **one hour between them**. Every optimisation aimed at our own code
is aimed at 8% of the clock.

## 2b. CORRECTED SAME DAY: the unit is the OUTPUT TOKEN, not the round trip

**Everything in section 3 below is arithmetically true and causally wrong, and section 6's plan was
built on it.** The correction came from `hunt-2026-09-04-five`, a 23-minute run measured with no
restarts at all.

That run's mapper spent **14.0 minutes on one call**. Splitting it from the session transcript:

| | |
|---|---|
| waiting on tools (10 WebFetch, 8 WebSearch, 1 Read) | **0.3 min** |
| waiting on the model | **13.6 min** |

Four pauses - 229 s, 227 s, 138 s, 125 s - are 12 of the 14 minutes. The web lookups everyone
assumed were the cost came to 18 seconds.

What actually predicts the wall clock is the OUTPUT VOLUME, and the rate is a constant:

| call | agent | sec | output tokens | tok/sec |
|---|---|---:|---:|---:|
| map:4x | mapper | 841 | 71,643 | 85.2 |
| map:1x | mapper | 255 | 19,712 | 77.3 |
| queue batch 1 | pricer | 182 | 14,869 | 81.7 |
| decide:9x | decider | 116 | 9,998 | 86.2 |
| registrar:3x | registrar | 124 | 9,835 | 79.3 |
| registrar:1x | registrar | 134 | 7,000 | 52.2 |
| **all agent calls** | | **1,834** | **148,111** | **80.8** |

**wall clock = output tokens / ~81 per second.** It back-predicts the big run: 3.1M output tokens is
10.7 hours against 12.18 h measured.

Round trips looked causal because they CORRELATE with output - more turns means more generated text.
They are not the thing being paid for. Three consequences, each of which reverses a recommendation
made earlier in this file:

* **Batching cannot help, and section 6's concurrency plan is not the lever.** `map:4x` produced 3.63x
  the output of `map:1x` and took 3.30x as long, while TURNS went only 17 -> 20. A batch multiplies
  the output the model must generate, and generation is serial. Five singletons at map cap 2 finish
  in ~12.6 min with the first recipe reaching pricing at 4.2 min; one batch of five takes ~17.5 min
  and moves nothing downstream until it ends. **The token eval and this one point in OPPOSITE
  directions on batch size, and for wall clock this one wins.**
* **Cutting turns only helps when it cuts OUTPUT.** The dossier work does, because it removes
  derivation the agent would otherwise write out. Removing a `Read` does not.
* **`effort: high` is generated output.** The mapper is opus-5 at effort high and its four multi-minute
  pauses are exactly that shape. Model tier and effort are the first-order levers, not the fourth.

The mapper writes about 18,000 output tokens per recipe - an evidence ruling for every ingredient
line. That volume IS the fourteen minutes. So the three real levers are **generate less** (a tighter
output contract), **generate faster** (tier and effort), and **generate in parallel** (more concurrent
calls, each small).

---

## 3. The unit of wall clock is the API round trip

    1,943 round trips across 245 sessions, at 22.6 s each = 12.2 h of agent time

That is the whole equation. A round trip is serial inside a session and re-reads the conversation, so
turns - not tokens, not calls - are what the clock is made of.

| lane | calls | hours | turns | turns/call | calls per published recipe |
|---|---:|---:|---:|---:|---:|
| write | 95 | 3.08 | 167 | 1.8 | 7.9 |
| map | 33 | 2.92 | 368 | 11.2 | 2.8 |
| audit | 24 | 2.74 | 615 | **25.6** | 2.0 |
| qa | 48 | 1.45 | 376 | 7.8 | 4.0 |
| price | 30 | 1.23 | 379 | 12.6 | 2.5 |
| select | 13 | 0.42 | 13 | 1.0 | 1.1 |
| review | 1 | 0.33 | 22 | 22.0 | 0.1 |
| extract | 1 | 0.01 | 3 | 3.0 | 0.1 |

**20.4 agent calls per published recipe.** The write lane makes the most calls and they are the
cheapest (1.8 turns); the audit makes few and they are the fattest (25.6 turns, 6.8 min each).

And the extract lane is the proof of what "architecturally different" looks like: the local ladder
settled 25 of 26 pages, so the whole lane spent **0.01 h** and made ONE agent call all run.

## 4. Model tier is a 1.8x lever on every turn

| model | calls | hours | turns | sec/turn |
|---|---:|---:|---:|---:|
| opus | 177 | **8.65 (71%)** | 1,115 | **27.9** |
| fable | 68 | 3.52 | 828 | **15.3** |

Opus costs 27.9 s per round trip against Fable's 15.3, and holds 71% of the wall clock. Every stage
pinned to Opus pays that multiplier on every turn it takes. This is not an argument to move judgment
off Opus - it is an argument that the pinning is a LATENCY decision as well as a quality one, and it
has never been made as one.

## 5. Why concurrency was 2.03x when the caps allow 13

`LANE_CAPS` totals 13 concurrent slots (decide 1, extract 3, map 2, price 1, write 5, qa 2, wave 1)
on a 32-core box, and the run achieved 2.03x. The pipeline did not fill its own lanes.

The cause is in the token eval's own numbers: the run **starved**. 9 accepted, 3 parked, 2 retired,
against a qualifying pool of 21 candidates. A recipe's path is serial - select, extract, map, price,
write, qa, then the wave stages - so with only a handful of recipes alive at once there is nothing to
overlap. Concurrency is not a scheduler setting here; it is a function of how many recipes are in
flight.

**That constraint is gone.** Measured 2026-09-04: 3,192 available candidates, 190 qualifying at
350-650/35c/30g protein and 58 at a 40g floor. The pool that starved this run no longer exists.

## 6. The arithmetic for "10 recipes in an hour"

    wall = round_trips x seconds_per_round_trip / concurrency

At this run's rates, 10 recipes = ~1,620 round trips x 22.6 s / 2.03 = **5.0 hours**.
To reach 1 hour the product has to improve about 5x. The levers, with measured leverage:

| lever | today | plausible | effect |
|---|---|---|---|
| **concurrency** | 2.03x | 6-8x | the caps already allow 13; this run starved and the pool no longer does |
| **round trips** | 162/recipe | ? | what the 2026-09-04 fixes attack; unproven at width |
| **model tier** | 27.9 s/turn on 71% of the clock | 15.3 | per-stage pinning is a latency decision nobody has made |
| **off the frontier** | 8% mechanical | more | the extract ladder is the existence proof: 26 pages, 1 agent call |

Concurrency alone plausibly gets 5.0 h to ~1.5 h. Concurrency plus the shipped round-trip fixes is
where an hour becomes arguable. **None of this is proven** - it is arithmetic over one run's
measurements, and the fixes have never run at width.

## 7. What this says about the wave barrier

`wave: 1` is serial by design, and audit + publish + review sit behind it. This run bought 15 auditor
calls for 6 publishes at 6.8 min each. The P5 precheck (shipped 561f4062) removes the audits that
were bought for waves wave-publish would refuse - 5 of 15 on this run - so the wave barrier's cost
should fall materially without the barrier itself moving. Measure it before designing anything
further: a barrier that costs 2.7 h today may cost 1.5 h once it stops buying refused audits.

## 8. Recommendation

Do not redesign anything yet, and do not run 10 blind. **Run 5 with the instrumentation that already
exists and read `hunt-run -StageSummary` afterwards.** Every number in this eval came out of the lane
log, so a 5-recipe run produces the same table and answers the only question that matters: what did
the 2026-09-04 fixes actually buy, in round trips per recipe and in concurrency, on a pool that does
not starve?

Redesigning against this run's numbers would be designing against a starved pipeline that stopped
overnight. Redesigning against a fresh, fed 5-recipe run is designing against the system as it now is.
