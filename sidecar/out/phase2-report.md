# Semantic sidecar: Phase 2 (wiring), 2026-08-01

Phase 1 asked "does this work?" and answered yes. Phase 2 asked "does it work on the *whole board*?"
and the answer split in two: **one lane ships, one lane does not.** That split is the main result.

Full sweep: 2,816 shipped pairs + 3,395 rule-invisible products, **30.6 s end to end on the GPU**.

---

## COVERAGE lane: SHIPPING

**89 products across 45 commodities that no rule can see but that read as real instances.**

Spot-checked four against the live `commodities.json` include/exclude patterns; all four are genuinely
invisible today:

| Product | Commodity | Matched by any rule? |
|---|---|---|
| `La Costena Jalapeno Peppers, Pickled 12 Oz` | pickled-jalapenos | no |
| `Hormel Corned Beef, Hash, Homestyle 25 Oz` | corned-beef-hash | no |
| `Libby's 100% Pure Canned Pumpkin` | canned-pumpkin | no |
| `Arm & Hammer Stain Fighters Fresh Scent Detergent` | laundry-detergent | no |

The first two are the **same inverted-name shape** that cost a live cell this morning ("Cloves, Ground"
invisible to a rule that only knew "ground cloves"). The sweep rediscovered that defect class on its
own, in commodities nobody had looked at. `Libby's` is the flagship brand for canned pumpkin.

### Threshold set on evidence

The first run returned **1,404** rows, which is a firehose, and a guard nobody reads is worse than no
guard. Sampling the bands settled it:

| Cross-encoder floor | Rows | Character |
|---|---|---|
| 0.05 | 1,404 | firehose |
| 0.20 | 843 | mostly near-misses the rules correctly reject (Tide *liquid* for detergent **pods**) |
| 0.80 | 163 | mixed |
| **0.90** | **89** | **nearly all real** |
| 0.95 | 35 | real, but starts dropping true gaps |

Findings also cluster hard by commodity (12 of the 89 are one detergent), so the report **groups by
commodity**: a coverage gap is fixed by editing one rule, so twelve rows saying the same thing is one
job, not twelve. 89 products becomes 45 review items, and this is a first-run *backlog* rather than a
daily rate.

## IDENTITY lane: NOT SHIPPING, and this is the honest part

Phase 1 scored it at AUC 0.985. Run against the entire live board it flags **173 pairs and every one
inspected is correct**:

```
Wimmer's Wieners, Skinless 24 Oz    -> Hot Dogs      correct
Kroger Olive Oil Mayo               -> Mayonnaise    correct
Yellow Bananas                      -> Bananas       correct
Dole Classic Romaine                -> Lettuce       correct
Febreze Air Original                -> Air Freshener correct
```

Two fixes were tried and neither rescued it. An absolute floor just selected for short names. Switching
to a **peer-relative** test (is this cell an outlier among its own commodity's other stores, the same
question the basis-outlier audit asks about price) did not help either, because the failure is not
calibration. Even the six pairs that *both* the bi-encoder and the cross-encoder call weak are correct.

**Why Phase 1 missed this.** The 24 labelled negatives are all *dramatically* wrong: bath soap as
coconut oil, dog food as salmon. Those are easy. The evaluation set never contained a subtle error,
because the estate does not have labelled subtle errors, so AUC 0.985 measured the wrong thing. That is
a flaw in my backtest design, not a surprise about the model.

The lane stays behind `-IncludeIdentity` for evaluation. It needs the fine-tune on the ~6,000 adjudicated
pairs before it can distinguish a genuinely wrong product from a correctly-matched one that is tersely
or synonymously named. Stock models cannot.

There is a second, more cheerful reading: the current board may simply not contain identity defects of
the kind this could find. The known-wrong entries were all caught and removed already.

## What is wired in

- `grocery\audit-semantic-identity.ps1` - owns the corpus and the engine regex, orchestrates the sweep,
  filters to actionable findings, writes `out\semantic-findings.json`. **Advisory only.**
- `sidecar\sweep.py` - the GPU batch. Scoring only.
- Fixture in `test-auditors` (now 282 checks): asserts the actionable filter still admits fresh findings
  and still suppresses settled rulings.

**BLIND-not-block verified for real**, not asserted: run with `-Python C:\nope\python.exe` and it exits 3
with "the semantic check did not run. This is never a publish blocker." A `-Python` override exists
precisely so that failure path can be exercised on demand, because "it degrades gracefully" is the
easiest claim in software to believe and never check.

Two bugs found and fixed while wiring: a Python `SyntaxWarning` on stderr killed the whole audit under
`$ErrorActionPreference='Stop'` (the logger-kills-pipeline trap in a new hat), and the sweep's docstring
carried an unescaped backslash.

## Next

1. **Work the 45-commodity coverage backlog.** Each is a `commodities.json` edit through the normal path:
   crown-diff plus tile-integrity, exactly as the cloves fix went in this morning.
2. **Fine-tune on the adjudication ledger**, then re-run the identity lane against a *harder* negative
   set before considering it again.
3. Schedule the sweep nightly once the backlog is worked, so it reports only what is new.
