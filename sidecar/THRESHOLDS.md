# Every similarity threshold, and the space it was tuned in

Backlog E25. Two traps sit under every similarity number here and neither is visible in the code:
**cosine and Euclidean answer different questions**, and **cosine's range depends on the space** it is
computed in. A threshold carried from one space to another is silently wrong by a large fraction of
the range, and it fails by admitting or refusing rows rather than by erroring.

`ops/audit-threshold-register.ps1` fails when a threshold appears in the scanned files without a row
here, so this file cannot fall behind the code without the gate saying so.

## The three score spaces in this estate

They are not comparable with each other. A number from one says nothing about a number from another.

| # | Space | Range | How it is produced |
|---|---|---|---|
| **S1** | bi-encoder cosine | in practice ~0.3 to 1.0 | `lib_match.py` encodes with `normalize_embeddings=True`, so cosine is a dot product of unit vectors. bge-m3 is a **signed** dense space, so the arithmetic range is -1 to 1 and 0 is the middle, **not** the floor. Real text pairs cluster well above 0. |
| **S2** | cross-encoder probability | 0 to 1 | `CrossEncoder.predict()`. Verified against the installed sentence-transformers 5.6.1 (`cross_encoder/model.py:114`): `nn.Sigmoid()` when `num_labels=1`, else `nn.Identity()`. |
| **S3** | BM25 | unbounded, non-negative | `meal-prep/pipeline/bm25_dedup_probe.py`. A **counting** space: every component is non-negative, so 0 is the floor and there is no upper bound to normalise against. **No threshold is set in S3 and none should be** - that probe compares ranks, never scores. |

### The hazard in S2, which is live and currently not biting

`get_default_activation_fn()` reads the **model's own config** first, either
`config.sentence_transformers["activation_fn"]` or the legacy `sbert_ce_default_activation_function`,
and only falls back to the num_labels rule. So two copies of "the reranker" can return scores on
different scales, and every threshold below tuned on one would silently mean something else on the
other - no error, just different rows admitted.

Checked 2026-09-06 across the pinned model and all three local fine-tunes:

| model | `num_labels` | declared activation | effective |
|---|---|---|---|
| `BAAI/bge-reranker-v2-m3` (pinned) | 1 | none | sigmoid |
| `sidecar/models/resolve-ce-v1` | 1 | none | sigmoid |
| `sidecar/models/resolve-ce-v2` | 1 | none | sigmoid |
| `sidecar/models/resolve-ce-v3` | 1 | none | sigmoid |

All four agree, so `hardeval --reranker <candidate>` is comparing like with like today. **This is
worth re-checking whenever a new base model is pinned**, because `finetune_reranker.py` saves an
`AutoModelForSequenceClassification` rather than a `CrossEncoder`, and a declared activation in a
future base is exactly the kind of key that does not survive that round trip.

## The register

| Threshold | Where | Value | Space | Basis |
|---|---|---|---|---|
| `COVERAGE_COS_FLOOR` | `sweep.py` | 0.55 | **S1** | Cheap prefilter, explicitly **not** the decision. Set where Task C's true positives sat - the cloves, ginger and red-pepper hits scored 0.58 to 0.69. |
| `COVERAGE_RERANK_FLOOR` | `sweep.py` | 0.90 | **S2** | The decision. Set on a banded sample: 0.05 returned 1,404 rows (a firehose nobody reads), 0.90 returns 89 and still catches the inverted-name shape that cost a live cell. |
| `IDENTITY_PEER_RATIO` | `sweep.py` | 0.10 | **S1, relative** | Not a bar at all: a shipped pair is suspicious when it scores below a tenth of its **own commodity's median**. Carries no absolute meaning and must not be compared with the two above. |
| `--margin` | `hardeval.py` | 0.08 | **S1, relative** | Mine a candidate only when it scores within this cosine of the product's own commodity. Relative, not absolute. |
| `--keep-above` | `hardeval.py` | 0.1 | **S2** | Round-2 mining cut. Measured 2026-08-23: 0.1 adds 431 pairs the bi-encoder margin never surfaced, 0.9 adds only 159. |
| `NOISE_MARGIN` | `checkpoint_selection.py` | 0.0033 | **neither - AUC** | Not a similarity. The within-arm holdout-AUC spread across four same-recipe seeds (0.9641 to 0.9674), used to refuse a checkpoint change smaller than measured noise. Listed here because its name matches and a reader could otherwise take it for a similarity margin. |
| `MIN_LABELLED_FOR_FLOOR` | `harvest_embed.py` | 20 | **a count** | Below 20 labelled rows the set is too small to read a floor off at all. A guard on the calibration, not a score. |
| `ask_floor` | `catalog-similarity.json` | 0.747, derived | **S1** | **Derived, never hand-set.** The lowest max-cosine at which any of the 168 labelled rejected-dupes sits (0.7516), less a hair. A floor for who to **ask** about, never a rule that refuses. |
| `dupe_threshold` | `catalog-similarity.json` | 0.9624, derived | **S1** | The corpus maximum: the highest score at which two published, therefore ruled-distinct, recipes sit. Read, never set. |

## Two numbers that look comparable and are not

**`COVERAGE_COS_FLOOR` 0.55 and `COVERAGE_RERANK_FLOOR` 0.90 sit ten lines apart in `sweep.py`** and
read like a loose bar and a strict one. They are in different spaces. 0.90 is not "stricter than"
0.55; the two do not share a scale, and neither number can be moved by reasoning about the other.

**`aisle.py` reports a cross-encoder floor for RIGHT answers of 0.004334** while `sweep.py` sets its
cross-encoder floor at 0.90 - both S2, three orders of magnitude apart. Neither is wrong. They score
different questions: `sweep.py` asks whether a product belongs to a commodity, and `aisle.py` scores
four adversarial founding failures where the model is confidently negative about everything and the
usable signal is the 4.4x separation deep in the tail. **An operating point is a property of the
question, not of the model**, so a threshold may never be carried between callers even inside one
space.

## Metric choice, where it was made deliberately

`aisle.py` is the one place that measured the choice rather than assuming it, and it is the exemplar
to copy: on the four founding failures the cross-encoder separated right from wrong by 4.4x, while
cosine separated them by 0.6%, which is noise. That is why it pays the reranker's cost instead of
using the cheap stage. Where magnitude carries meaning, Euclidean is the metric that keeps it; for
text of unequal length - a short ingredient string against a long product title - cosine is correct
because Euclidean would call two long strings similar for being long. Nothing in this estate uses
Euclidean today.
