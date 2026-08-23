# The semantic sidecar

A local GPU service that answers one question the rest of the estate cannot: **is this product actually
an instance of this commodity?**

Everything here is **advisory**. Nothing in this folder changes a price, a crown, a rule or a link.

## Why it exists

The measured #1 defect class is identity: the wrong product wearing a commodity's crown. Price
verification cannot catch it (all four wrong products in the 2026-07-30 audit were top-of-ladder
price-verified), and the multipack guard cannot catch its mirror, a *right* product that no rule can
see. On 2026-08-01 that mirror cost a live cell: "Cloves, Ground" was invisible to a rule that only knew
"ground cloves", so a $45 jar of discount-brand spice won the cell unopposed at $36.00/oz.

Both are semantic entailment questions. 48,242 hand-maintained regex patterns are structurally bad at
them; a small embedding model on a local GPU is good at them, and cheap enough to run over the whole
catalogue every night.

## Layout

    lib_match.py   THE matcher. Bi-encoder + cross-encoder, per-commodity calibration. One
                   implementation, shared by everything below.
    sweep.py       The nightly GPU batch. Reads a corpus prepared by PowerShell, writes ranked
                   findings to out\semantic-findings.json. Scoring only. THREE lanes: identity,
                   coverage, and (2026-08-22) contested - the pairs the graph's deterministic
                   layers could not settle, listed by `resolve.py --emit-contested` in
                   data\contested-pairs.json and scored to out\contested-scores.json while the
                   models are already resident. That lane DECIDES NOTHING; it records scores and
                   warms the vectors the resolve lane wants hours later, on a card this process
                   has already given back. Measured: 3.2 s cold, 0.0 s and no model load warm.
    score_cache.py The on-disk memo sweep.py scores through: bi-encoder vectors and cross-encoder
                   pair scores keyed by (model id, exact text) in out\embed-cache\. Only text the
                   run has never seen reaches the card, and a model is loaded only on a miss that
                   needs it. Measured 2026-08-22: 46 s -> 4 s on an unchanged shelf, ~18 s with
                   1,500 new names, findings byte-identical either way. SWEEP_CACHE=0 bypasses it.
    app.py         FastAPI service on 127.0.0.1:8077 for interactive/ad-hoc scoring.
    backtest.py    An acceptance gate. Scores the matcher against defects the estate already
                   shipped. See out\backtest-report.md. NOT the gate that decides a fine-tune:
                   its 25 negatives are all dramatically wrong, so it never asks a hard question.
    hardeval.py    THE gate that decides. Same question against the ADJUDICATED negatives, which
                   are subtle. Stock scores AUC 0.9705 on the dramatic set and 0.8312 on GOLD.
    freeze_eval.py Snapshots the eval set under data\frozen\<name>\ (tracked). REQUIRED for any
                   before/after: commodity_text() is label + TODAY's accepted exemplars, so
                   scores drift with the shelf - dropping the exemplars moves TASK A AUC from
                   0.9705 to 0.7921, and the same eval files scored 24/24 on 2026-08-01 and
                   17/25 on 2026-08-22 with no model change at all. Pass the snapshot to BOTH
                   sides via --defs, or the comparison measures the board.
    build_pair_corpus.py
                   The (query, doc, label) training corpus for a fine-tuned cross-encoder
                   (PLAN-local-matching section 6). Read-only on the graph; holdout by commodity
                   family so the test is cold by construction. Excludes single-model rejections
                   by design - see its header for why that is not fastidiousness.

The estate-side front end is `grocery\audit-semantic-identity.ps1`. It owns the corpus and the regex,
because that matching must stay byte-identical to the pricing engine; Python never re-implements it.

## Setup

    uv venv --python 3.12
    uv pip install torch --index-url https://download.pytorch.org/whl/cu128
    uv pip install -r requirements.txt

**The cu128 index is not optional.** This card is Blackwell (compute capability 12.0, sm_120) and older
CUDA wheels will not run on it.

Model weights (~4.5 GB) download from HuggingFace on first use and are cached outside the repo.

**The GPU is shared and the sweep needs ~3 GB of it.** The llama.cpp model (`tools\local-llm\serve.ps1`)
takes ~13 GB and cannot be resident at the same time. Since 2026-08-22 that ordering has an owner:
`graph\pipeline\nightly.ps1` runs this sweep first, waits for this process to exit, and only then
starts llama-server - stopping it again in a finally block. `audit-semantic-identity.ps1` still checks
`nvidia-smi` before launching the sweep and still goes BLIND (exit 3) rather than OOM if llama-server
holds the card with under 3,500 MiB free; it is the backstop now, not the rule.

## The rules that make it safe to run unattended

1. **Advisory only.** Findings flow into the arrivals desk and the rule worklist. A wrong product still
   goes through `add-known-wrong.ps1`; a coverage gap still goes through a `commodities.json` edit with
   a crown-diff and a tile-integrity check.
2. **BLIND, never block.** Sidecar down, GPU busy, Python missing: the audit exits 3
   (could-not-evaluate) and the publish proceeds. The board must never depend on this box being healthy.
3. **Models are pinned.** `EMBED_MODEL` / `RERANK_MODEL` in `lib_match.py`. Swapping one changes every
   score in the estate, so it is a deliberate, fixtured act, never an implicit `latest`.
4. **Fixtures like everything else.** `audit-semantic-identity.ps1 -SelfTest` runs in test-auditors
   daily and asserts the actionable filter still admits fresh findings and still suppresses settled
   rulings.

## What Phase 1 measured

From `out\backtest-report.md`: cross-encoder AUC 0.985, **100% recall on the 24 true identity defects**
at an operating point costing roughly **6 advisory rows a day** (the board only churns 168 pairs daily).
Replaying the pre-widening ruleset from git history, it ranked the correct invisible product **#1 out of
3,404 candidates** for five of six known-blind commodities.

Honest limits are in the report and should stay there: 24 labelled negatives is a small evaluation set,
and nothing is fine-tuned yet, so those numbers are a floor rather than a ceiling.
