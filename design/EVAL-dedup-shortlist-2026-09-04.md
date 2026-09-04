# EVAL: does bge-m3 separate duplicates, and what should the shortlist actually do?

author: Opus 5, 2026-09-04. Measured on the live pool and the estate's own labelled rulings.
shipped with: the per-source shortlist in `harvest.py` (`dedup_shortlist`) and `ask_floor` in
`harvest_embed.py --calibrate`.

## 1. The defect this started from

`DEDUP_SHORTLIST_MIN = 20` is a word-overlap COUNT. The embedding rows are cosines. The pass
compared both against 20:

| source | rows in the live pool | score range |
|---|---|---|
| word-overlap | 9,641 | 2 – 64 |
| bge-m3 | 31,340 | 0.559 – 1.000 |

**Zero of the 31,340 embedding rows could ever clear 20.** The semantic half of the evidence reached
the decider's dossier and never reached the ingest gate - the gate whose entire job is to stop a
duplicate before it costs a decider call. Rebuilding the index (b3c1833c, earlier the same day)
therefore improved the expensive end of the pipeline and left the cheap end exactly as it was.

A second defect sat beside it: `near.sort(key=-score)` ranked the two sources together, so a
word-overlap 64 outranked a bge-m3 0.998 and, at `DEDUP_ASK_CAP = 3`, word-overlap rows would have
crowded out every semantic one. **Ranks are comparable across scales; scores are not.**

## 2. Does the embedding score separate dupes from acceptances?

The question that decides whether a threshold may refuse anything. Measured over 152 labelled
`ruled:rejected-dupe` and 85 labelled `ruled:accepted` candidates, max cosine to the live catalog,
**self excluded** (an accepted candidate BECAME a live recipe and scores ~1.0 against itself; without
that exclusion the accepted distribution is meaningless).

    dupes     n=152  min 0.752  p25 0.829  median 0.861  p75 0.900  max 0.998
    accepted  n=85   min 0.741  p25 0.808  median 0.833  p75 0.864  max 0.953

**No.** There is real signal - the dupes sit higher - and the distributions overlap end to end.

| cut | dupes caught | acceptances also caught |
|---|---|---|
| 0.7481 (corpus p90) | 152/152 (100%) | 84/85 (99%) |
| 0.8000 | 140/152 (92%) | 69/85 (81%) |
| 0.8345 (corpus p99) | 109/152 (72%) | 42/85 (49%) |
| 0.9000 | 38/152 (25%) | 4/85 (5%) |
| 0.9624 (corpus max) | 3/152 (2%) | 0/85 (0%) |

This reproduces, from the LABELLED side, what S2a asserted from the corpus side: no auto-rejection on
similarity at any score. It is the same verdict word overlap got on 2026-08-27 (both classes median
20, max 40) - the embedding is a better signal and still not a separating one.

**Why a corpus percentile was the wrong instrument.** The calibration corpus is every published
recipe, and publishing means a decider ruled it distinct - so it contains no duplicates by
construction. It can say what is UNUSUAL. It cannot say what is DIAGNOSTIC. Only the labelled
rulings can, and the estate had 237 of them sitting unused in the pool.

## 3. So the number is a floor, and it is read, not chosen

`ask_floor = 0.747` - just under 0.752, the lowest score at which any known duplicate has ever sat.
It catches 152/152. It is recomputed by `--calibrate` as the labelled set grows, and it is a floor
for **who to ASK the local model about**, never a rule that refuses.

Two bounds already make a wide floor safe, and both are why optimising this cut for volume would be
a mistake:

- **Cost is bounded elsewhere.** The daemon asks about at most `max(40, target*4)` candidates, in
  pop order, under a 180 s deadline. The floor does not control spend; the cap does.
- **Risk is bounded by the two-polarity contract**, which also short-circuits: `llm_same_dinner(...)
  == "yes" and llm_different_dinner(...)` does not ask the mirror unless the first says yes, so a
  non-duplicate costs ONE local call.

Effect on the live pool:

| shortlist | candidates asked about |
|---|---|
| word overlap >= 20 (before) | 1,232 |
| bge-m3 >= 0.747 | 1,637 |
| **union (now)** | **1,748** |

The 516 additional candidates are the ones word overlap structurally cannot see: the same dish under
a different vocabulary, which is precisely the class the embedding lane was built for.

## 4. What was NOT done

`DEDUP_SHORTLIST_MIN` is untouched at 20. Nothing here refuses a candidate on a score. No live recipe
is deleted. The decider remains the sole author of acceptances.

## 5. Aside: where the daemon suite's 300 seconds go, and why not to cut it

Measured by the section timer this change also ships (`hunt-daemon.py --selftest` now reports its own
slowest sections):

        65.7s  22%  Q1 - a term recorded as BLOCKING is a term on the QUEUE
        33.2s  11%  Q2 - the carriage gate runs on EVERY road to `priced`
        31.6s  11%  Q3 - a rejection the state machine REFUSED is not a rejection

Top three = 43% of the suite. They are slow because they launch the REAL `hunt-run.ps1` and
`ingredient-queue.ps1` rather than injecting them, and Q1's own comment records why that is
load-bearing: *an injected hunt-run cannot union a carriage term, so the claim and the record can
never disagree inside a FakePS fixture.* These are the highest-value cases in the suite. **Do not
cut them.** `-NoProfile` is already passed, so there is no free win in the process launch either.

The suite is 300 s, not the ~13 minutes it appears to take from the outside: that figure is a
gate that runs it TWICE, once for the HEAD reference and once for the change. The saving is to pin
the reference once per session and diff case NAMES against it, not to make the suite weaker.

## 6. THE GATE CANNOT FIRE. Measured against the live model, 2026-09-04.

Everything above widens who the ingest pass ASKS about. It then refused **0 of 60** real candidates
with the model up (llm=59, no-neighbour=1, 106 s - comfortably inside the 180 s budget). That is not
a clean slice. The gate cannot fire at all.

`refuse_near_dupes` requires `llm_same_dinner(...) == "yes" AND llm_different_dinner(...) == "no"`.
Asked over controls whose answers are not in doubt, the model answers **yes to both questions on
every pair, including a name against itself**:

    same=yes  diff=yes  FIRES=False   Taco Casserole                vs Taco Casserole
    same=yes  diff=yes  FIRES=False   Chicken Cordon Bleu Casserole vs Chicken Cordon Bleu Casserole
    same=yes  diff=yes  FIRES=False   Beef Stroganoff               vs Slow Cooker Beef Stroganoff

So the mirror can never contradict, the conjunction is never true, and **no candidate has ever been
or can ever be refused at ingest**. The 2026-08-27 comment in the code records the same observation
("the local model answered YES to BOTH framings on every single pair") and responds by requiring
contradiction - which is honest about the evidence and, unmeasured, turns the safeguard into an off
switch. It reads as a careful gate and behaves as a disabled one.

The model is not incapable of discriminating - it is the two-yes/no-questions FORM that is
uninformative. `same=no` does appear for obviously different dishes (Beef Stroganoff vs Chicken
Burrito). It is `different_dinner` that is constant.

### The measured repair: one forced choice, agreed across both ORDERS

A forced choice makes the options compete inside one answer, so agreement bias has nowhere to go;
and swapping A and B is a genuine independence check where re-phrasing was not.

| control set | two yes/no questions | forced choice | forced choice + order swap |
|---|---|---|---|
| positives (should fire) | 0/5 | 4/5 | 3/4 |
| published, ruled DISTINCT (must not fire) | 0/5 correct-by-accident | 2/5 WRONG refusals | **0/5 wrong refusals** |
| far apart | - | 3/3 | - |

Both false refusals - `Chicken Bacon Ranch Burrito` vs `Ranch Chicken Burrito`, and
`Slow Cooker Pork Posole Verde Bowls` vs `Slow Cooker Salsa Verde Pork Bowls` - answered `same` in
one order and `different` in the other, and the swap killed both.

**NOT IMPLEMENTED.** The two-polarity contract is a ruled mechanism and replacing it is Brad's call,
not a session's. This section is the evidence for that decision, and until it is taken the ingest
dedup widens the ask and refuses nobody.

> **SUPERSEDED, 2026-09-04 evening (PLAN-after-review P3).** The two tables in this subsection -
> 8.4% recall at 0 of 300 wrong refusals - were produced by a forced-choice prompt that was never
> implemented and whose text is recorded NOWHERE. It cannot be reproduced, and section 8 measured
> the same design at 43.3% / 4.67% with a prompt that IS recorded. Do not average the two and do not
> quote these numbers: read them as "an unrecorded prompt scored differently", which is itself the
> finding section 8 draws from them. The reproducible measurement is section 8's.

### The wide validation, and why the repair was NOT implemented after all

Brad approved "validate wide, then implement" on the section-6 evidence. Validated wide, the repair
does not earn implementation. Both halves were measured against real labelled data.

**Safety - 300 hardest PUBLISHED pairs (score 0.8779-0.9624), every one a known non-duplicate a
decider ruled distinct. Any `same` here is a recipe the estate would have thrown away.**

| design | wrong refusals |
|---|---|
| A  two-polarity contract (shipped) | 0 of 300 - *but only because it cannot fire* |
| B  forced choice, one order | 4 of 300 (1.3%) |
| C  forced choice, both orders agree | **0 of 300** |

**Recall - 155 pairs a decider actually ruled duplicate, from the ledger's `dupe_of`.**

| design | fires on a real duplicate |
|---|---|
| A | 0 of 155 (0.0%) |
| B | 15 of 155 (9.7%) |
| C | **13 of 155 (8.4%)** |

C is safe and nearly useless. At 8.4% it would have caught roughly half of one of the six dupe
rejections on hunt-2026-09-04-five-b, in exchange for two extra local calls on every popped
candidate. Safety alone proves nothing here, because the BROKEN contract also scores 0 wrong
refusals - that is what an off switch looks like on a safety metric.

**WHY, and it is not a prompt bug.** The misses are systematic:

    different/different   Ground Beef Stroganoff  vs  Ground Beef Stroganoff Pasta
    different/different   Swedish Meatballs       vs  Swedish Meatball and Potato Bowls
    different/different   Pork Stew               vs  Creamy Pork Stew with Potatoes and Carrots
    different/different   Chicken Burrito         vs  Chicken and Bean Burrito

The decider rules these duplicates because they are the same DINNER IDENTITY. The local model reads
them as different dishes because the names differ. Both readings are defensible; they are simply not
the same question. And every design tested is name-only, because that is all the local model is
given - `signature_text` is `"dish: <name>. protein: <protein>"`, while the decider rules on a
dossier carrying ingredients, method, band and neighbour evidence.

**So the honest conclusion is that the ingest gate cannot reproduce the decider's judgement from
names, and no amount of question design fixes that.** The next thing worth testing is a RICHER
prompt - the ingredient list, which is what actually distinguishes "Beef Chili" from "Beef Chili
Mac" - and that test cannot be run today: `slim_ruled` strips a ruled candidate to `RULED_KEEP`, so
the 155 labelled positives have no ingredients left to prompt with. The `dupe_of` fix below is what
starts accumulating the data that would answer it.

### And a second defect it uncovered

A `ruled:rejected-dupe` candidate in the POOL records no `dupe_of` - only `ruled_reason`, which is
prose ("...shares the flavor identity of live s..."). So the file every dedup tool actually reads
held 152 duplicate rulings and not one joinable pair, and the floor in section 3 had to be read from
each dupe's max cosine to the WHOLE catalog rather than to its actual twin. That is a strictly weaker
measurement: it asks "how close is this to anything live" where the labelled question is "how close
is it to the thing it duplicates".

**CORRECTION, made the same day.** An earlier version of this section said the estate could not audit
its duplicate rulings at all. That was wrong, and wrong in the direction that flatters the finding.
`db\considered-dishes.json` has carried a structured `dupe_of` from the beginning: 155 of its 199
rejected-dupe rows name their twin. The ledger was never the problem. The ruling simply stopped
there and never travelled the last hop to the pool - which is also why the gap survived the
decide_apply drill, whose every `dupe_of` assertion was made against the ledger, the one surface that
already had it.

FIXED: `--mark-ruled --dupe-of` carries the twin onto the candidate, `RULED_KEEP` preserves it
through `slim_ruled`, and the drill now asserts it on the POOL. Existing rows are not backfilled;
the 155 ledger pairs remain joinable by slug for anyone who wants them.

## 8. The richer prompt WAS run, and it made the gate worse. The refusal path is retired.

author: Opus 5, 2026-09-04, later the same day, under PLAN-after-dedup-2026-09-04 P1. Ruled by
Brad on the numbers below: retire the refusal path (P1c).

Section 7 said the ingredient-carrying prompt "cannot be run today" because `slim_ruled` had
stripped the labelled positives. The plan corrected that - every one of the 152 pooled
`ruled:rejected-dupe` rows still had a cached page - and `harvest.py --reingredients-ruled` restored
all 152 from the page cache with no network and no model (152 restored, 0 uncached, 0 without
JSON-LD ingredients). So the test that was supposed to be the road to a working gate was run.

**It refutes its own hypothesis.** Adding the ingredient lines did not make the local model
reproduce the decider's judgement. It made it more conservative in BOTH directions.

    pairs: 134 labelled duplicates (the 152 pooled rows joined to a LIVE twin by the ledger's
    `dupe_of`; 18 twins are no longer live), and the 300 hardest published pairs, cosine
    0.8775-0.9624, every one a non-duplicate a decider ruled distinct.
    local model, temperature 0, grammar root ::= ("same" | "different"), 434 pairs x 2 orders x 2
    prompts = 1,736 calls, 608 s, zero Claude tokens.

| design | recall on 134 real dupes | wrong refusals on 300 published |
|---|---|---|
| B  forced choice, names only, ONE order | 60.4% (81) | 6.00% (18) |
| C  forced choice, names only, BOTH orders | 43.3% (58) | 4.67% (14) |
| D1 forced choice, WITH ingredients, ONE order | 29.9% (40) | 4.67% (14) |
| **D  forced choice, WITH ingredients, BOTH orders** | **23.9% (32)** | **2.00% (6)** |

The bars the plan set were ~50% recall at **0** wrong refusals. Nothing came close, and the richer
prompt moved recall the wrong way by 19 points.

**These numbers are NOT comparable to section 7's 8.4% / 0-of-300, and that is itself a finding.**
Section 7's forced-choice prompt was never implemented and its text is recorded nowhere, so it
cannot be reproduced. The prompt used here carries the same rubric as `llm_same_dinner`. Same model,
same grammar, same temperature, same 300 negatives, a 134-of-155 subset of the positives - and the
"safe" design scores 14 wrong refusals rather than 0. A contract whose safety swings from 0% to
4.67% on prompt wording alone is not a contract, and that is the strongest argument in this
document against shipping any of these as a gate.

**C and D are not nested.** C fires on 33 pairs D misses; D fires on 7 C misses; 25 in common. The
ingredients do not refine the name judgement, they replace it with a different one. Their union
would be 48.5% recall at 14+ wrong refusals - still under one bar and far over the other.

**What both miss, and why no prompt fixes it.** The systematic misses are the estate's own
definition of a duplicate:

    Chicken Cordon Bleu              vs  Chicken Cordon Bleu Casserole
    Chicken and Stuffing Casserole   vs  Turkey and Stuffing Casserole
    Chicken Enchilada Skillet        vs  Chicken Enchilada Rice Bowls
    Taco Stack                       vs  Turkey Taco Casserole

The decider rules these duplicates because they are the same DINNER IDENTITY in a catalog it can
see the shape of. The local model, given names or given ingredients, is answering "are these the
same recipe" - a different question that no wording turns into the first one.

### What shipped, and what shipped LATER THE SAME DAY

> **UPDATE, 2026-09-04 evening (PLAN-after-review P3): the ask is DELETED, not merely disarmed.**
> The minimal disposal below left the estate asking a local model a question whose answer nothing
> acted on. Worse, on re-reading, the one number it still reported - "N candidates the retired gate
> WOULD have refused" - was computed with the same two-polarity conjunction section 6 proved can
> never be true, so it was structurally 0 and watched nothing. `judge_near_dupes`, `dedup_pending`,
> `dedup_ingest_pool`, `--dedup-ingest`, `llm_same_dinner`, `llm_different_dinner`, the
> `dedup_at_ingest` tag, the daemon's preflight and both its flags, and the 13 fixtures that held
> them honest are gone. `dedup_shortlist` and `dedup_ask_floor` are kept and now SAY they have no
> caller. The evidence the decider actually rules on - the `neighbours` block, the embedding index,
> the STALE-INDEX alert - is untouched.

`refuse_near_dupes` is now `judge_near_dupes` and **writes no `status`**. It still asks, still
records `dedup_at_ingest`, and still reports how many the retired gate WOULD have refused - a number
to watch, never a number to act on. The name changed because a function called `refuse_near_dupes`
that refuses nothing is the exact "reads as a working safeguard, behaves as an off switch" failure
section 6 named. Three fixtures changed name with it, and the daemon's pass is off by default.

### And the negatives are not all clean negatives

Six published pairs D would have refused, and fourteen C would have. Several read as genuine
duplicates a decider let through - `Chicken Tetrazzini` vs `Turkey Tetrazzini` (0.9080),
`Salsa Verde Chicken Burrito` vs `...Burrito Bowl` (0.9624). Ruled by Brad 2026-09-04 to be opened
as its own item rather than folded in here: `OPEN-ITEM-published-near-duplicates-2026-09-04.md`.
Every recall figure above is therefore a LOWER bound by an unknown amount: some "wrong" refusals
were right, and the labelled negatives inherit whatever the catalog's own duplicate rate is.

### CORRECTIONS, from the adversarial review the same evening (REVIEW-after-dedup-2026-09-04)

Two things in the table above are wrong, and neither changes the ruling.

**1. `norm_line` was unfair to the LIVE side of every pair.** The quantity/unit stripper in
`dedup_prompt_drill_pairs.py` made the unit optional with no word boundary after it, so a line
carrying a quantity kept its food (`1 lb ground beef` -> `ground beef`) while a line with no
quantity lost its first letters (`Garlic` -> `arlic`, `Ground beef 93/7` -> `round beef`). Candidate
lines come from `ingredients_verbatim` and nearly always carry a quantity; live lines come from
`ingredients_display` and never do. Measured: 17.5% of the 7,845 live display lines were mangled
against 2.8% of the 2,176 candidate lines, and 123 of the 134 recall pairs had a mangled live side.

Re-run on the SAME 434 pairs, same model, same prompt, same grammar, with the boundary fixed (868
calls, 285 s):

| design | as published above | with the boundary fixed |
|---|---|---|
| D1 ingredients, ONE order | 29.9% / 4.67% | **35.1% (47) / 5.00% (15)** |
| D  ingredients, BOTH orders | 23.9% / 2.00% | **24.6% (33) / 2.67% (8)** |

The bars were ~50% recall at 0 wrong refusals. Corrected, D is still 25 points under one bar and
still above the other, and the C-to-D comparison still says the ingredient lines made the gate more
conservative in both directions. **P1c stands on the corrected numbers.** The fix adds one pair to
the wrong-refusal list that the open item does not have: `Slow Cooker Chicken Taco Rice Bowls ||
Slow Cooker Salsa Chicken Burrito Bowl`.

**2. The 300 negatives were never ruled by a decider.** This section, and the open item it spawned,
both describe them as "every one a non-duplicate a decider ruled distinct". Measured: the ledger
holds 93 accepted candidates, of which 16 join to a live recipe by slug and 17 by source URL - so
**17 of 584 live recipes came through a decider at all**, and ZERO of the 300 pairs contains one.
The 300 hardest pairs are the pre-hunter catalog, whose distinctness no gate this estate has ever
ruled on. That does not weaken the safety measurement, because a live recipe thrown away is thrown
away either way. It changes what the OPEN ITEM is: not "the decider let these through" but "the
catalog was never deduplicated by the decider's rule at all".

### The measurement itself

Two scratch scripts, deliberately not shipped: one builds the pair sets (the sidecar venv, for the
catalog-vs-catalog cosines that pick the 300 hardest), one asks the local model. What IS shipped is
`--reingredients-ruled`, because without it the pairs cannot be rebuilt, and a measurement whose
inputs cannot be reconstructed is an anecdote.

## 9. P3: does the decider rule more cheaply now the dossiers carry evidence? INCONCLUSIVE, and the
## metric is why.

author: Opus 5, 2026-09-04. Run `hunt-2026-09-04-p3`, decide lane only, dry-run publish, launched by
Brad's ruling. Band ruled by Brad: 350-650 cal, NO carb limit, >= 40 g protein.

**Why the band moved, and it is a finding of its own.** P3 was specified as "one run at the same band
and target" as `hunt-2026-09-04-five-b`. That is impossible: of 3,134 available candidates, **0**
cleared five-b's band (350-650 / <= 35 g carb / >= 40 g protein) on verified numbers. A full
`harvest-crawl.ps1` was run specifically to unblock it, added 148 candidates, and **none of them were
in band either**. The breakdown after the crawl, of 3,282 available:

    unverified band  2,125      out on calories  514
    out on carbs       422      out on protein   221
    IN BAND              0

`candidate_in_band` requires `band.verified` - an inferred macro is not evidence a dish clears a 40 g
floor - so roughly two thirds of the shelf is structurally unpoppable at ANY band. "3,282 available"
is not a number of candidates a run can use.

### The comparison

five-b's decide calls ran 08:32-08:36; the evidence fix (b3c1833c) landed 09:57. So five-b is a
genuine BEFORE: its dossiers carried word-overlap neighbours and almost no embedding ones (70 of
3,134 at the time). Every p3 dossier carried both.

| | five-b (before) | p3 (after) |
|---|---|---|
| decider calls | 2 | 3 |
| candidates ruled | 19 | 30 |
| output tokens | 16,761 | 33,057 |
| **per candidate ruled** | **882** | **1,102**  (+25%) |
| dupe rejections | 6 (32%) | 16 (53%) |
| **per dupe rejection** | **2,794** | **2,066**  (-26%) |

**The two numbers move in opposite directions, and that is the answer.** Per candidate it got dearer;
per dupe rejection it got cheaper. Both are explained by the same thing - the MIX changed, from 32%
duplicates to 53% - and the mix changed because the band changed. Neither figure can be attributed to
the neighbour evidence.

**So the plan's chosen metric is confounded, and would have been even at the same band.** "Output
tokens per candidate ruled" is a ratio whose denominator the run itself selects: a decider facing
more duplicates writes more rejections and fewer acceptances, and those cost different amounts. The
measurement that would actually answer the question is the SAME candidates ruled twice, once with the
neighbour block and once without - a within-pairs design, not a between-runs one. That costs two
decider calls on identical dossiers and is the honest next experiment.

**What IS clean, and it is worth stating.** The decider writes on the order of 1,000 output tokens
per candidate either way. At ~81 tokens/sec that is ~12 seconds of wall clock per candidate ruled.
Whatever the evidence did, it did not make the decide lane cheap, and the ingest gate that was
supposed to stop duplicates before they got there is retired (section 8). Duplicates are being paid
for at the decider, and on this run they were 53% of everything ruled.

### And a defect the run surfaced: candidates stranded as `taken:`

p3 reported one finding - `creamy-chicken-feta-pasta: the pool ruling did not land`. Reading the pool
for that shape found **21 candidates stuck at `status: taken:<run>`** by runs that have since ended:
20 from `hunt-2026-09-04-five` and 1 from p3. A `taken:` candidate is not `available`, so `pool_lane`
never pops it and no ruling ever settles it: it is leased to a dead run, permanently, and silently.

`--mark-ruled` on the p3 one succeeded when re-run by hand, so the failure is transient rather than
structural - which makes it worse, not better: nothing retries, and nothing sweeps. Not fixed here,
because it is outside this plan and the fix is a lease-expiry decision, not a patch.
