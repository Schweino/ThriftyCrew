# BRIEF: stop paying the decider to discover duplicates the estate could already see

queue_id: dedup-before-the-decider-2026-09-04
shipped_commit: b3c1833c (2026-09-04) - the work is DONE: verify it and report, do not rebuild.
Read section 0a first: two of this brief's own instructions were wrong and were not followed.
author: Opus 5, 2026-09-04, from measurement on the live pool and on run hunt-2026-09-04-five-b.
ruled by: Brad, 2026-09-04: "I just dont want to waste token burn in the hunter because of
duplicates or near duplicates that get rejected."

## 0a. CORRECTIONS made at implementation time (2026-09-04)

Two things in this brief were wrong, both because I wrote them without reading the file I was
telling someone to change. They are recorded here rather than silently edited, because the shape of
the mistake is worth more than a clean-looking plan.

**3.2 could not be done here, and doing it would have broken a ruling.** The brief says to start
llama-server from the harvest chain. `harvest-crawl.ps1` forbids exactly that in THREE of its own
MUST-FIRE assertions - its executing region may not reference `serve`, `llama` or `nvidia` - and its
header records why: PLAN section 4.4 gives the card to the nightly chain, and only
`install-nightly-task.ps1` may schedule it. Moving the start into `harvest.py` would have slipped
past those greps while breaking the thing they protect, so it was not done.

WHAT SHIPPED INSTEAD, and it is a better fit for the actual goal: the ingest dedup drains from the
DAEMON, which already owns the card, already calls `ensure_local_model`, and is the place where a
duplicate actually costs a frontier decider call. The crawl keeps the half that is genuinely free -
a CPU rebuild of the embedding index. Section 3.2's own sentence, "this brief does not weaken the
ownership rule", is honoured more exactly than the mechanism it proposed.

**3.1's "the fingerprint check already in `load_embed_neighbours`" does not exist.** There was no
staleness check of any kind on the neighbour index, and the index recorded no fingerprint to check
against - that is `load_similarity_calibration`, a different function. This is not a footnote: it is
break 1's actual mechanism. A twelve-day-old index was read as current because nothing could tell
that it was not. `harvest_embed.py` now writes `catalog_fingerprint` and `load_embed_neighbours`
refuses an index it cannot date.

Minor: the ingest function is `refuse_near_dupes`; `dedup_at_ingest` is the TAG it writes.

## 0. Read these first

1. `meal-prep\pipeline\harvest.py`: `dedup_at_ingest` (~line 1911), `refresh_dossiers` (~1506),
   `load_embed_neighbours` (~1426), and the constants `DEDUP_SHORTLIST_MIN` / `DEDUP_ASK_CAP`.
   The docstring at 1905 is the design and it is RIGHT - this brief does not redesign it, it makes
   it actually run and makes its failure loud.
2. `meal-prep\pipeline\harvest_embed.py` - the writer of `db\harvest-neighbours.json`. Needs the
   SIDECAR venv (torch/numpy); the graph interpreter has none.
3. `meal-prep\pipeline\harvest-crawl.ps1` - the 18:00 task. It runs `harvest.py --crawl` and nothing
   else, which is the whole of break 2 below.
4. `EVAL-hunter-wall-clock-2026-09-04.md` section 2b - wall clock is OUTPUT TOKENS at ~81/sec, so a
   decider call avoided is ~8,000 tokens and ~100 seconds that never happen.

## 1. The measured defect

**Every dupe rejection this estate has ever made was on a candidate carrying no dedup evidence.**

    ever rejected as dupe                    152
      ...that had NO neighbours when ruled   152   (100%)

The decide lane is handed a candidate with nothing attached, derives from scratch that it duplicates
a live recipe, and we pay a frontier model to reach a conclusion the estate had the machinery to
compute. On hunt-2026-09-04-five-b all six rejections were of this kind, inside two decider calls
costing **16,761 output tokens** - roughly 3.5 minutes of pure generation, a third of it spent
saying no.

It is not historical. Right now:

| available candidates | 3,134 |
|---|---|
| carrying neighbour evidence (word-overlap) | 2,137 |
| **carrying none - blind to the decider** | **997** |
| `dedup_at_ingest` unset | 3,133 of 3,134 |

## 2. Three breaks, each silent, which is why this survived

**BREAK 1 - the embedding neighbour index is stale and nearly empty.**
`db\harvest-neighbours.json` was last written **2026-08-23 17:28**, twelve days ago. It holds 679
entries and covers **70 of the 3,134 available candidates (2.2%)**. `harvest_embed.py` writes it and
nothing schedules that. So `load_embed_neighbours` returns a map that answers for almost nothing, and
the good half of the dedup evidence - the semantic half, the one that separates "chicken cordon bleu
casserole" from "beef chili vs beef chili mac" - is absent.

**BREAK 2 - the ingest dedup cannot reach its model, by construction.**
`dedup_at_ingest` needs llama-server, and harvest.py's own docstring says it plainly: *"The 18:00
crawl calls this and nothing starts llama-server for it."* `harvest-crawl.ps1` runs
`harvest.py --crawl` and nothing else. So the pass tags `unavailable` and stores the candidate
undeduped - which is the honest behaviour, and it has been the behaviour every single night.

**BREAK 3 - and nothing anywhere reads those tags.**
This is the one that matters, and the reason "never again" needs more than a fix. The design already
records its own failure faithfully: `dedup_at_ingest` is `"unavailable"` when the model was down,
`"no-neighbour"` when there was nothing to ask about, and `neighbours: []` when the index could not
answer. Every one of those is a could-not-look, correctly written down - **and no gate, no alert, no
status line ever reads them.** A degradation that records itself and is never read is
indistinguishable from working, which is the exact failure class this estate has mechanised against
everywhere else and did not here.

## 3. The change

### 3.1 Refresh the index the crawl depends on (break 1)
Add an embedding refresh to the harvest chain, under the sidecar interpreter, BEFORE `--crawl` uses
it. It is a `harvest_embed.py` invocation, not new logic. Guard rails:
- it must DEGRADE, never block: a crawl that cannot embed still crawls, and says so;
- the fingerprint check already in `load_embed_neighbours` stays - an index built against a different
  catalog digest must not be used as if it were current;
- it is the SIDECAR venv, never `C:\Codex\Python312` and never a bare `python`.

### 3.2 Give the ingest dedup its model (break 2)
The crawl runs at 18:00, when `card_is_owned` says the card is free (the nightly chain owns
21:30-06:30). Start llama-server for the pass the way hunt-daemon's `ensure_local_model` does -
same guard, same refusal inside an owned window, same "never wait for it" rule - and stop it after,
so the 21:30 chain finds the card free.

**If the card is not free, the pass stays `unavailable` and that is correct.** This brief does not
weaken the ownership rule; it stops the pass silently never trying.

### 3.3 Make the silence impossible (break 3) - THE PART THAT IS ACTUALLY "NEVER AGAIN"
Everything above is a fix. This is the thing that stops the next silent degradation:

- **A pool health line in `hunt-run.ps1 -Status` and in the daemon's `status_report`**: how many
  AVAILABLE candidates carry neighbours, how many carry `dedup_at_ingest`, and the age of
  `harvest-neighbours.json`. Three numbers, read off the data, printed every run.
- **A finding when a run pops blind candidates**: if the decide lane is about to rule a candidate
  with `neighbours: []`, the daemon appends a finding naming the count. A decider call spent on an
  undeduped candidate is a measurable waste and it should be visible in the run's own report.
- **An ops alert when the index goes stale** (> 3 days) or when a crawl records `unavailable` for the
  whole batch. The estate already has the triage queue; this is one more row in it.

The rule this encodes, which is the estate's own and was not applied here: **a could-not-look that
nobody reads is a clean bill.** Recording the degradation is half the job; surfacing it is the half
that was missing.

## 4. What this brief deliberately does NOT do

- **It does not let a script rule a duplicate.** The decider remains "the sole author of acceptances
  and of the dish-rulings ledger" (PLAN v3). The ingest pass may only refuse what the LOCAL MODEL
  judged under the two-polarity contract, which already exists and is already careful: a verdict
  counts only when the mirrored question contradicts it, because on 2026-08-27 the local model
  answered YES to both framings on all seven labelled pairs, including stroganoff vs burrito.
- **It does not delete or retire any live recipe.** Measured 2026-09-04: 0 exact duplicates among the
  583; the 113 name-similar pairs are dominated by shared boilerplate ("Slow Cooker … Rice Bowls"
  makes Orange Chicken and Chicken Adobo look 0.67 similar) and by deliberate protein variants. On
  INGREDIENTS even the worst pair shares 0.26, and one that scored 1.00 on names shares 0.07. There
  is no catalogue duplicate problem to solve, and 563 of the 583 are paid.
- **It does not raise `DEDUP_SHORTLIST_MIN` or widen what the ingest pass refuses.** Tuning the
  threshold is a separate, measured decision for Brad.

## 5. Fixtures

In `harvest.py`'s own self-test:
1. MUST FIRE: a candidate whose neighbours are empty is tagged `no-neighbour`, never silently passed.
2. MUST FIRE: with the model down, every candidate is tagged `unavailable` and NONE is refused.
3. CLEAN TWIN: with the model up and a mirrored-contradiction verdict, the candidate is refused at
   ingest and never stored as available.
4. MUST FIRE: a stale index (fingerprint mismatch) is NOT used - `load_embed_neighbours` refuses it.
5. MUST FIRE: the pool health numbers are computed from the data, and a pool with 997 blind
   candidates reports 997 rather than a share or a rounding.

In the daemon suite:
6. MUST FIRE: popping a candidate with `neighbours: []` appends a finding naming the count.
7. CLEAN TWIN: a candidate carrying neighbours appends nothing.

Neuters, one at a time, restored by md5, counts MEASURED: (a) the `unavailable` tag replaced by a
clean one; (b) the fingerprint check dropped; (c) the blind-candidate finding removed; (d) the health
line removed; (e) the two-polarity contract reduced to one question.

## 6. Gates
`harvest.py --selftest`, `hunt-daemon.py --selftest` (diff case NAMES, nothing removed),
`hunt-run.ps1 -SelfTest`. Run the daemon suite in the background and read the file.

## 7. What to measure afterwards, and the honest expectation

Re-run the pool numbers: blind candidates should fall toward zero, and `dedup_at_ingest` should read
`llm` or `no-neighbour` rather than unset. Then, on the next hunt, compare decider output tokens per
ACCEPTED recipe against today's baseline (16,761 output tokens across two calls, 19 candidates ruled,
6 rejected as dupes).

**The expectation is a reduction, not an elimination.** The decider still rules on everything that
reaches it; what changes is that the obvious duplicates never arrive and the rest arrive with their
evidence attached. If the rejection rate does not move once candidates carry evidence, that is the
finding - it would mean the decider is rejecting on grounds the neighbours do not capture, and the
next question is which grounds.
