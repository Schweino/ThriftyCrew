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
