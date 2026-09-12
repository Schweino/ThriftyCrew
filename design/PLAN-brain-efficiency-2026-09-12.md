# What to change to make this estate's learning system actually pay

2026-09-12. Written after the 24-hour review and the prose-gateability audit, and after measuring
the recall logs properly. It corrects a number I reported earlier in the same session.

## THE CORRECTION FIRST

I earlier reported the recall system as offering something on "under 3% of turns". That was the
wrong log: `recall-consulted-log.jsonl` records whether a turn ENDED with a named source, which is
a different question. The right log is `recall-log.jsonl`, which carries an `ev` field and a
`path` per row.

Measured over 10,427 rows:

| | |
|---|---|
| offers | **7,266** across 157 distinct sections |
| opens | **1,549** across 229 distinct sections |
| open rate | **21.3% (1,549 of 7,266)** |

So the retrieval layer is NOT nearly silent. It offers constantly and about one offer in five gets
opened. The earlier "3%" should not be used for anything.

The real defect is narrower, sharper and worse, and it is two separate things.

## DEFECT 1: a handful of sections are offered constantly and opened never

Applying the store's OWN retirement test (`MIN_OFFERS = 5` AND `MIN_SESSIONS = 3`, from
`knowledge-search/automatic-recall.md`), **22 of the 157 offered sections have been offered at
least five times across at least three sessions and opened zero times.**

The distribution is the point. The worst single section:

```
1,164 offers / 214 sessions / 0 opens   claude-code-automation/surfaces.md
  598 offers / 113 sessions / 0 opens   claude-api-craft/server-tools-and-thinking.md
  128 offers /  98 sessions / 0 opens   agent-workflow-craft/applies-here.md
```

**One file accounts for 16.0% of every offer this system has ever made (1,167 of 7,282) and has
never once been opened.** The two never-opened files in the top three are 1,765 offers between
them, **24.2% of everything the channel has ever said**. Across all 22, it is **2,474 offers,
34.0%**. That is not a tuning problem: a third of the channel's entire output goes to sections
nobody has ever opened.

Worse than the waste: every dead offer occupies a slot a better match could have had. The channel
is not just noisy, it is CROWDED OUT.

**The repair is already specified and must not be improvised.** `automatic-recall.md` states it:
"never opened" has two causes with OPPOSITE repairs - search cannot find the right thing and
offered this instead, or search found it and the reader declined the label. **Prefer reword over
retire whenever the knowledge is still true**, and score the section first. Retirement is gated,
reversible and never automatic (`recall-forget.py` keeps the file and records `size -1`, so
reversing a ruling re-indexes it).

**DO NOT rebuild per-file use weighting.** It was built and REFUTED on the labelled probes
(2026-09-07): right-domain-at-1 fell 103 to 70. Retrieval strengthens the association between a
CUE and a memory, not a memory's global loudness, so any weight has to be per cue. The query
tokens already travel with every offer row for exactly this reason.

## DEFECT 2: the project memory store is invisible to recall

**Of 7,266 offers, 2 pointed at the project memory store.** Effectively zero.

That is the "170 notes in a folder nobody opens" problem, measured. The recall hook searches the
skills store; the 170 memory files under
`~/.claude/projects/C--Codex-ThriftyCrew/memory/` are reachable only when something already names
them. Meanwhile their INDEX, `MEMORY.md`, is 18,047 bytes paid on EVERY turn, and 365,156 bytes of
memory files sit behind it that automatic recall never reaches.

So the estate pays the index cost on every turn and gets the retrieval benefit almost never. The
worst of both: `agent-workflow-craft/agent-memory.md` is blunt that a self-edited always-loaded
region "is not free storage, it is the most expensive storage in the system".

Two ways to close it, and they are not equivalent:

- **(a) Index the memory store into the same BM25 corpus the skills store uses.** Cheap, uses
  machinery that exists and is already measured, and immediately gives the 170 files the same
  offer/open loop everything else has - which also means they become RETIREABLE on evidence
  instead of accumulating forever.
- **(b) Shrink the always-loaded index instead.** Cuts cost but not the invisibility, and the
  entries most worth cutting are the ones already enforced by a gate (see the gateability audit),
  which is a separate and already-planned lever.

(a) first. (b) is only safe once (a) is running, because until the files are retrievable the index
is the ONLY thing making them exist at all, and cutting it would make the store less reachable
rather than more.

## DEFECT 3: prose that a machine could enforce (already in flight)

From `design/AUDIT-prose-gateability-2026-09-12.md`: of 62 rule bullets, 21 are already enforced
by a gate, **18 are mechanically decidable and enforced by nothing**, and 23 are genuine judgement
calls. Two of the 18 shipped today (`ops/audit-unread-wait.ps1`,
`ops/audit-internal-ast-members.ps1`), both at a baseline of zero over 768 scripts.

This is the highest-confidence lever we have, because it is the one with a measured track record:
the tree-walk rule sat written and unread for two weeks while twelve detectors returned nothing,
and started working the day it became a gate.

## DEFECT 4: half the reflex layer is still a draft, and nothing retires one

46% of all reflex fires come from rows still labelled `draft:`, which run in SHADOW mode and do
nothing. Several have fired over a hundred times with no adjudicated outcome at all
(`draft:cmdletbinding-empties-psscriptroot-in-param-defaults`: 161 fires, 0 verdicts). A draft that
has fired 161 times has enough evidence to be promoted or dropped; leaving it in shadow is paying
the matching cost for none of the benefit.

This one is now measurable and was not before today: the block-vs-burn fix means a blocking row's
successes stop being counted as its failures, so a promotion decision can finally be made on a
number that means what it says.

## THE ORDER, AND WHY

1. **Index the memory store into recall** (defect 2a). Largest single gap, uses existing machinery,
   and it is a precondition for ever retiring a memory on evidence.
2. **Score and reword-or-retire the 22 dead-offer sections** (defect 1), top three first. Roughly a
   quarter of the channel's output, recoverable, with the procedure already written down.
3. **Keep converting the 18 gate-able rules** (defect 3). Steady, proven, no risk of making
   retrieval worse.
4. **Adjudicate the long-running drafts** (defect 4), now that the scorer is honest.

Deliberately NOT on the list: rebuilding per-file weighting (refuted), automatic forgetting
(forgetting here is gated and reversible by design, and should stay that way), and cutting the
always-loaded index before step 1 lands.

## THE ACCEPTANCE BAR FOR STEP 1, WRITTEN BEFORE THE RUN (2026-09-12)

Two corrections to this plan's own step 1, found while starting it:

- **The memory store is already INDEXED.** `recall-index.sqlite3` holds 170 chunks under
  `memory:C--Codex-ThriftyCrew`, one per file, retrievable by description. The reason it is never
  offered is that `recall-hook.py` queries `["skills"]` only, and that is DELIBERATE and recorded
  at the call site: "The index also holds the memory and rules corpora from today, and this hook
  does not query them. That is build 5's job and it gets its own measurement, so the plan's
  section 7 numbers have one change to attribute at a time." So step 1 is a pending build with a
  stated discipline, not an oversight to fix.
- **There were ZERO labelled cases for it.** All 39 expected targets in
  `course/consult-questions.jsonl` are skills files. A harness with no memory answer in it cannot
  show a memory gain, so running it before and after would have produced a flat number that meant
  nothing - the unqualified-delta trap in `.claude/rules/measurement.md`. That gap is why
  `course/memory-questions.jsonl` was written first: 20 questions, 21 targets, all resolved,
  each phrased from the SITUATION rather than the memory's own wording so a lexical retriever
  cannot win by echo.

**The bar, in the metric's own units, set before either arm ran:**

- **Arm A, today's behaviour** (skills corpus only). Expected hit@3 of **0 of 20**. Anything above
  zero would mean a skills file answers a memory question, which is worth knowing on its own.
- **Arm B, the memory store queried directly.** Wiring the memory corpus into recall is worth
  doing only if **hit@3 >= 12 of 20 (60%)**. Below that the limiting factor is how the memories
  are WRITTEN, not whether they are queried, and the repair is to reword descriptions rather than
  widen the corpus - which is also the cheaper repair and the one the store's own retirement rule
  already prefers.

**What arm B is and is not.** It is `search.py`'s lexical BM25 over the memory root. Production
answers with the SEMANTIC leg on 72.6% of turns (measured today: 1,810 of 2,494 leg rows semantic,
684 lexical), and semantic beat BM25 19/30 against 10/30 on the skills question set. So arm B is a
LOWER BOUND on what recall could achieve, and a failure at arm B is not proof the idea is dead -
it is proof that the lexical path alone cannot carry it.

## THE RESULT (2026-09-12), against the bar above

Harness: `course/memory-questions.jsonl` (20 questions, 21 targets, all resolved), scored by
`knowledge-search/search.py` for arms A and B and by the live sidecar's `bge-m3` embeddings for
arm C. One row per case per arm in `memory-arms-cases.jsonl`, totals derived from it.

| arm | what it is | hit@1 | hit@3 |
|---|---|---|---|
| A | skills corpus only - **today's behaviour** | 0 of 20 (0%) | **0 of 20 (0%)** |
| B | memory store, LEXICAL (BM25) | 5 of 20 (25%) | **8 of 20 (40%)** |
| C | memory store, SEMANTIC (bge-m3) | 11 of 20 (55%) | **16 of 20 (80%)** |

**Arm A came in exactly as predicted at zero**, which is the useful half of predicting it: the
memory store is not merely under-served today, it is unreachable, and no amount of tuning the
lexical path changes that.

**Arm B MISSED the bar (8 of 20 against 12).** On the lexical path alone, widening the corpus is
not worth doing.

**Arm C CLEARED it (16 of 20).** So the answer to "should the memory store be in automatic
recall" is YES, but ONLY on the semantic leg - which is the leg that answers 72.6% of live turns
anyway. That is a much narrower and cheaper change than "index the memory store", which was this
plan's original step 1 and was wrong in its cause.

**A caveat that makes 16 of 20 a FLOOR, not a ceiling.** Two of the four misses returned defensible
answers that the ground truth does not list: q13 ("how do I know a number got better rather than
just moved") returned `a-number-that-improved-after-a-plumbing-change` and
`an-agreeing-number-escapes-scrutiny`, both of which answer the question; q7 returned
`a-negative-search-result-must-prove-itself` at rank 3. The existing skills question set documents
this exact hazard - its question 1 carries a `[KEY CORRECTED]` note for the same reason. The keys
are NOT being widened after seeing the results, because a threshold or a key adjusted after the
run is a description of a decision already taken. They are recorded here as a known narrowness for
whoever scores this set next.

## THE REGRESSION RUN: what adding memory costs the skills answers

Bar, set before the run: **no memory chunk may cost a skills answer**; the skills set must hold at
or above 19 of 30.

Method: load the LIVE skills embedding index (1,339 vectors), append the 170 memory vectors
(1,509 total), and score the 30 skills questions both ways. One row per case per arm in
`skills-regression-cases.jsonl`.

| arm | hit@1 | hit@3 | cross-domain | direct | lexical |
|---|---|---|---|---|---|
| skills-only | 8 of 30 | **22 of 30** | 11 of 14 | 10 of 15 | 1 of 1 |
| skills+memory | 8 of 30 | **21 of 30** | 11 of 14 | 10 of 15 | **0 of 1** |

**Exactly ONE case changed**, and the paired file names it: q5, the set's single `lexical`
question, went True to False, displaced by `memory/run-gates-blind-in-worktrees.md` and
`memory/prepush-gate-goes-blind-on-slot-starvation.md`. Cross-domain - the class this whole
retrieval effort exists for - did not move at all.

**So the bar is cleared (21 >= 19), and the honest reading of the cost is narrower than "one
case".** The loss is on the LEXICAL class, and that is explainable rather than random: memory
files are written about specific identifiers, paths and error strings, which is precisely BM25's
and the lexical class's home ground, so memory chunks compete hardest exactly where they are least
wanted. **n = 1 is not a significant result and must not be reported as one.** It is one
observation consistent with a mechanism, and the set holds a single lexical question, so the set
cannot measure this class at all. **Before shipping, the lexical class needs more than one
question.**

**NAME THE HARNESS.** These numbers came from a scratch harness at this session's commit, scoring
top-3 by raw cosine with NO floor, embedding memory files as their first 4,000 characters and
reusing the live skills index unchanged. Production applies a floor (0.548) and further filters.
**So my skills-only 22 of 30 is NOT the recorded 19 of 30** and the two must not be compared: the
arms here are comparable to EACH OTHER and to nothing else. A shippable build has to be measured
through the production path.

## THE SECOND REGRESSION: the lexical class, measured properly

The first regression's whole cost landed on a class the question set could not measure - one
question. `course/lexical-questions.jsonl` adds ten more (14 targets, all resolved, each verified
by grep against the target rather than by running the retriever, which would be circular), taking
the lexical class from 1 to 11 and the set from 30 to 40.

| arm | hit@3 | cross-domain | direct | **lexical** |
|---|---|---|---|---|
| skills-only | 28 of 40 | 11 of 14 | 10 of 15 | **7 of 11** |
| skills+memory | 27 of 40 | 11 of 14 | 10 of 15 | **6 of 11** |

**Still exactly ONE case changed, and it is the SAME case.** Ten new lexical questions, zero
additional losses. The feared class-wide displacement did not appear: the concern that memory
chunks would crowd out identifier queries in general is now measured and refuted, over 11x the
coverage that raised it.

**And the one remaining loss is a GROUND-TRUTH artifact, not a regression.** q5 asks *"why did the
gate exit 3 instead of 1"*. It is keyed to `course/rule-evidence.md` and
`claude-code-automation/hooks.md`. With memory present it returns
`memory/prepush-gate-goes-blind-on-slot-starvation.md`, whose description reads *"run-gates exits
3 after waiting 1,200s for a gate slot and the hook blocks the push; that is BLIND"* - which
answers the question more directly than either keyed file. The estate's own question set carries a
`[KEY CORRECTED]` note for exactly this hazard.

**The key is NOT being widened**, because a key adjusted after seeing the run describes a decision
already taken. It is recorded here so the next person to score this set can decide with the
evidence in front of them. The honest summary is that the measured cost of adding the memory store
is **one question, whose new answer is better than its key**, against 16 of 20 on questions that
previously scored zero.

## THE PRODUCTION PATH, AND IT REVERSES THE VERDICT

Arms B and C scored top-3 with NO floor. Production applies one: `MIN_COSINE = 0.548`. A floor
does not re-rank, it DELETES - a correct answer at rank 3 below the floor becomes nothing
returned at all - so the shipping decision belongs to the number measured through the real path.

Measured by calling the sidecar's `/recall-search` against the built memory index
(`recall-embed-memory-C--Codex-ThriftyCrew.npz`, 170 vectors), k=4 as the hook uses:

| arm | hit@1 | hit@3 | avg hits returned | returned NOTHING |
|---|---|---|---|---|
| E - no floor (arm C's setting) | 11 of 20 | **16 of 20** | 4.0 | 0 of 20 |
| D - floor 0.548, **production** | 9 of 20 | **11 of 20** | 1.4 | **4 of 20** |

**11 of 20 is BELOW the bar of 12, so on the production path this change does NOT clear the bar
it was given, and it is NOT shipped.** Arm C's 16 of 20 was an over-estimate produced by a
setting production does not use, and had the build gone out on it, the live result would have
been a third worse than the number that justified it.

**The cause is identifiable and it is not that the idea is wrong.** 0.548 was calibrated on
SKILLS chunks - long, multi-paragraph sections. A memory file is one fact, often a few hundred
bytes, and short documents sit lower in cosine against a conversational query. Five cases show it
exactly: q5, q18 and q20 return NOTHING at the floor while returning the correct answer at rank 1
or 2 without it, and q9 and q17 keep only their wrong first hit. Applying a floor calibrated on
one corpus to a different corpus is precisely the defect `sidecar/THRESHOLDS.md` exists to
prevent - three score spaces that do not share a scale - reproduced one level up.

**THE NEXT STEP, AND ITS DISCIPLINE.** Derive a memory-specific floor with
`course/derive-semantic-floor.py`. Two rules on it, or it is worthless:
- **It must NOT be fitted to these 20 questions.** A floor tuned until this set passes is a
  description of a decision already taken. Hold out half, derive on the other half, and report
  the held-out number.
- **The new floor is registered in `sidecar/THRESHOLDS.md`** with its corpus, or the estate has
  a fourth unregistered score space, which is the thing that register exists to stop.

**VERDICT: NOT SHIPPED.** The build is written and tested (`recall-embed-memory.py`, 5 of 5
cases, 170 vectors in 1.0 s) and the index exists, but nothing in `recall-hook.py` has been
changed to consult it. The decision to wire it in waits on a memory-corpus floor measured on
held-out questions. Both earlier bars stand as recorded; this one was failed, and the failure is
the reason the change is not live.

## HOW WE WILL KNOW IT WORKED

Write the bar before the run, in the metric's own units, per `.claude/rules/measurement.md`:

- **Step 1 succeeds** if, after indexing, the project memory store receives at least 5% of offers
  over 3+ sessions, at an open rate not worse than the current 21.3% overall. Baseline today:
  2 of 7,266 offers (0.03%).
- **Step 2 succeeds** if the share of offers going to never-opened sections falls from its current
  level. Baseline today, computed rather than estimated: the 22 dead sections hold **2,474 of
  7,282 offers (34.0%)**, and the single worst holds 1,167 (16.0%) at zero opens. A rewording
  that merely moves offers to a different dead section is not an improvement, so the measurement is
  over the whole dead set, not per file.
- Both are read WITH their denominators, and neither number is a pass on its own: an offer is not
  an open, and an open is not a use. The only thing in the system that measures whether an
  injection changed BEHAVIOUR is `recall-reflex-stats.py`, and it can do it for the reflex tier
  only.
