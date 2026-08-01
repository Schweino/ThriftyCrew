# Semantic sidecar: Phase 1 backtest

Run 2026-08-01 on the RTX 5070 Ti (compute capability 12.0, 17.1 GB visible, torch 2.11.0+cu128).
Models: `BAAI/bge-m3` (bi-encoder) + `BAAI/bge-reranker-v2-m3` (cross-encoder). Nothing in this run
touched the board, a feed, a rule, or a price.

**Verdict: PASSES the acceptance gate, with room to spare.**

---

## The gate, as written in the design doc

> Run Lane 1 against July's captured feeds and score it against the defect ledger. Ship only if it
> flags a meaningful share of the known identity defects at a false-positive rate the arrivals desk
> can absorb (target: under ~30 advisory rows/day).

Result: **100% of identity defects at roughly 6 advisory rows/day.**

---

## Task A: does it catch wrong products?

Scored the 25 adjudicated-wrong pairs from `known-wrong.json` against the 2,816 pairs the board
currently ships, using one function for both so the comparison is honest.

| Metric | Value |
|---|---|
| AUC, bi-encoder (cosine) | 0.943 |
| AUC, cross-encoder | **0.985** |

AUC 0.985 means a randomly chosen accepted pair outranks a randomly chosen adjudicated-wrong pair
98.5% of the time.

**One label was mine to correct.** `Spice Supreme Spice Ground Cloves` scored highest of all the
negatives (0.196) and it *should have*: that product genuinely is ground cloves. It was ruled wrong for
its **$45 price**, not its identity. Marking the tool down for that would be penalising it for being
right. Scoring on the 24 true identity defects:

| Threshold (flags per 2,816 board pairs) | Identity recall |
|---|---|
| 10 | 8/24 (33%) |
| 20 | 14/24 (58%) |
| 50 | 16/24 (67%) |
| **100** | **24/24 (100%)** |

## Task B: can a human live with the noise?

100 flags out of 2,816 sounds unusable. It is not, because **the board only changes by 168 pairs a
day** (measured, comparison-2026-07-30 to 07-31). Score only pairs seen for the first time and the
threshold that catches every identity defect produces:

| Threshold | Realistic daily queue | Identity recall |
|---|---|---|
| 20/2816 | ~1 flag/day | 58% |
| 50/2816 | ~3 flags/day | 67% |
| **100/2816** | **~6 flags/day** | **100%** |

Six rows a day is an arrivals-desk item, not a burden. This is the finding that turns the whole idea
from plausible into obviously worth doing.

### What it misses, and why that is fine

At a 20/day threshold the misses cluster into two honest groups:

- **Form defects** (`Contadina Roma Tomatoes Puree` for Tomatoes (fresh), `Nature's Own Butter Buns`
  for Butter). Semantically adjacent, genuinely hard, and caught once the threshold widens.
- **Category jumps that share vocabulary** (`Dr Teal's Foaming Bath ... with Coconut Oil`,
  `Blue Buffalo ... Dry Food` for Salmon). Both caught at the 100 threshold, which is the one we would
  actually run.

Every one of the 24 is caught at the operating point above.

## Task C: does it find gaps regex structurally cannot see?

This is the test that matters, and it is a genuine replay rather than a simulation. I pulled the
**pre-widening `commodities.json` out of git history** (the ruleset as it stood before yesterday's fix),
re-derived which of 22,884 products it could match, and pointed the sidecar at the 3,404 it could not.

The question: without anyone writing a pattern, does it surface the products the old rules were blind to?

| Commodity | Plausible instances in top-25 | Best rank |
|---|---|---|
| ground-cloves | 3 | **1** |
| ground-ginger | 5 | **1** |
| red-pepper-flakes | 7 | **1** |
| garlic-powder | 13 | **1** |
| minced-garlic | 17 | **1** |
| onion-powder | 2 | 3 |

The `ground-cloves` result, verbatim:

```
#1  0.6347  Family Fare   Our Family Cloves, Ground 2 Oz
#2  0.6048  Family Fare   Tone's Cloves, Ground 0.55 Oz
#3  0.5880  Family Fare   Sugar 'N Spice Cloves Ground Pp
```

Those are the exact three products the old rule could not see. **#1 is the $2.99 jar that should have
won the cell instead of the $45 one.** The sidecar ranks it first out of 3,404 candidates, with no
pattern written and no knowledge of yesterday's fix.

It also found instances my manual widening missed, e.g. `VAHDAM Organic Ginger Powder Spice ... Ground
Ginger Root` for ground-ginger, which no pattern I wrote would catch.

Ranks 2 and below carry real noise (a frozen-vegetable bag under red-pepper-flakes, a garlic rice mix
under minced-garlic). That is expected and is exactly why this is a **ranked advisory list for a human**,
never an auto-applied rule.

## Throughput

| Stage | Time |
|---|---|
| Embed 503 commodity definitions | 1.9 s |
| Embed 2,841 product names | 2.4 s (1,186/s) |
| Cross-encode 2,841 pairs | 12.0 s |
| Embed 3,404 unmatched products | 3.3 s |

A full nightly pass over the whole 137K-name catalogue extrapolates to roughly two minutes of GPU time.
Model load is ~100 s cold, once.

## What this does not prove

- Only 24 identity defects exist as labelled negatives. That is a small evaluation set, and the honest
  read is "consistent with the tool working", not "proven at scale". The fix is the flywheel: every
  future adjudication adds a label.
- Task C was scored on six commodities I already knew were broken. The unbiased version is to run all
  503 and see what comes back that nobody has looked at yet. That is Phase 2's first job, and it is
  where the real discovery value lands.
- No fine-tune yet. These are stock models. The estate's ~6,000 vetted pairs have not been used for
  training at all, so this is the floor, not the ceiling.

## Recommendation

Proceed to Phase 2 as designed: wire Lane 1 in as an advisory feed to the arrivals desk at the
100/2816 threshold (~6 rows/day), with frozen fixtures and BLIND-not-block semantics. Phase 1 changed
no grocery code, so it is freeze-clean; Phase 2 waits for the freeze to lift or an explicit go.
