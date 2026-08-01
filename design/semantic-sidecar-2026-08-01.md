# The Semantic Sidecar: what the GPU is actually for

Written 2026-08-01 by Fable, at Brad's direction to question the current design rather than defend it.
Hardware confirmed: RTX 5070 Ti, 16,303 MiB, driver 596.49, compute capability 12.0 (Blackwell, sm_120).
Environment confirmed greenfield: no Python, no Ollama, no WSL on the machine today.

## The one-sentence answer

The estate's measured bottleneck is not compute, it is semantic judgment, which the current architecture
RATIONS because it is expensive (agent sessions, API tokens, Brad's eyes); a 16 GB local GPU makes
semantic judgment ABUNDANT, and abundant judgment is what the accuracy program has been starved of.

## Why this is the right target (measured, not vibes)

- 99 defects reached shoppers in 22 days; guards caught 5%, Brad caught 7% (accuracy-ceiling memo).
  The dominant class is IDENTITY: the wrong product wearing a commodity's crown. All 4 wrong products
  audited were top-of-ladder VERIFIED, so price-verification cannot catch them by construction.
- The defect parade is word-shaped, not number-shaped: bath soap matched as coconut oil by substring;
  beef jerky reached the garlic commodity through a stale exclude bake; watermelon linked to trash bags;
  yesterday, "Cloves, Ground" invisible to a rule that only knew "ground cloves", so a $45 jar won a
  cell unopposed. Every one of these is a semantic entailment question ("is X an instance of Y?") that
  48,242 hand-maintained regex patterns are structurally bad at.
- The discovery program is BLOCKED on exactly this capability. pull-depth-findings: Hy-Vee's puller
  misses 89.3% of the catalogue, and a Family Fare full-catalogue browse flips 26 crowns, two-thirds to
  WRONG products, so the shallow feed is an accidental relevance filter. The memo's own conclusion:
  "depth needs an aisle test first." A product-to-commodity semantic verifier IS the aisle test. Until
  it exists, the board cannot safely get deeper coverage; with it, the biggest known accuracy ceiling
  (absent catalogue) becomes addressable.
- Bulk semantic sweeps are priced out today. Judging 137,389 product names against 503 commodities via
  API is tens of millions of tokens per sweep; via agent sessions it is hours of interactive time. On
  the local GPU it is minutes, nightly, free. That is the architectural shift: checks that currently
  do not happen because of cost start happening every night.

## What we already own that makes this work (the flywheel)

The estate has been accidentally building a training set for a month:

| Asset | Count | Label type |
|---|---|---|
| Live board (product, commodity) pairs | 2,816 | positives, guard-vetted |
| Verified product-URL identities | 3,205 | positives, human/tile-verified |
| known-wrong.json entries | 22 | HARD negatives with written evidence |
| Category-exclude library | ~2,165 patterns | negative vocabulary (which words disqualify) |
| Arrivals-desk + contested-match rulings | ongoing | fresh labels weekly |

Every future adjudication (add-known-wrong, arrivals ruling, contested-match resolution) becomes a new
labeled pair at zero extra cost. A weekly fine-tune (minutes on this GPU) makes the matcher better
exactly where OUR data is hard, which a generic embedding model will never give us.

## Architecture: one sidecar, three lanes, advisory only

One local Python service (FastAPI on localhost, started by the same Task Scheduler estate that runs
everything else). The PowerShell estate calls it with Invoke-RestMethod exactly like it calls the smp
Worker. It exposes four endpoints and NOTHING it says is ever auto-applied to the board.

    /embed        names[] -> vectors          (bge-m3 class model, ~2 GB VRAM)
    /score-match  (product, commodity) -> p   (cross-encoder reranker + our fine-tune)
    /judge        structured judgment call    (Qwen2.5-14B-Instruct quantized, ~10 GB VRAM)
    /extract      flyer jpg / screenshot ->   (Qwen2.5-VL-7B, ~7 GB VRAM)
                  structured rows

Models load and unload per job (Ollama semantics); nothing needs to be co-resident.

### Lane 1: identity second opinion (the accuracy lane, highest value)

Nightly, after the board builds:
1. Embed all ~137K product names across every feed (under a minute on this card).
2. For every commodity, retrieve top-k nearest products; cross-encode (product, commodity definition +
   exemplars) for a calibrated match score.
3. Emit THREE advisory reports into the existing intake surfaces:
   - "matches a rule but semantically does not belong" -> arrivals-desk docket (the bath-soap class)
   - "semantically belongs but NO rule can see it" -> coverage report (the Cloves-Ground class; this
     is the report that would have caught yesterday's $45 jar a month early)
   - "two commodities both claim this product" -> contested-match review (the collision class)
4. Weekly SetFit/LoRA fine-tune on the adjudication ledger. Minutes on GPU.

Consumers beyond the board: the product-URL resolver (an independent identity axis for link
verification, attacking the all-4-wrong-were-price-verified failure), recipe-dedup, and above all the
FAMILY FARE AISLE TEST that unblocks resume-list item 2 and then the Hy-Vee discovery program.

### Lane 2: vision extraction (the capture lane)

58 Fareway + 15 Baker's flyer JPGs currently get vision-read inside interactive agent sessions. A local
VLM turns that into a headless nightly pipeline step: jpg in, structured {item, price, size} rows out,
same guards downstream. Second use: re-read the walled-store browser captures from screenshots as an
independent SECOND READING, diffed against the JSON exfil (the 1,100-char truncation and staging pain in
the exfil path gets a cross-check it has never had). Accuracy rule: extraction output enters through the
same import gates as every other capture, never directly.

### Lane 3: bulk judgment (the priced-out-checks lane)

The 14B local model does the high-volume, low-stakes chores that today simply do not happen: taxonomy
second opinions across the full catalogue, exclude-library candidate generation (proposing the inverted
word-order patterns BEFORE a bad price surfaces one), size-string sanity reads on new captures. It does
NOT touch triage: the Fable-reviewer/Opus-developer pipeline stays on frontier models, because those are
judgment tasks where a 14B is measurably worse and the estate's memory says exactly that.

## The speed answer (honest: it is CPU work, not GPU work)

Total daily compute is 6.3 minutes; the GPU has no meaningful wall-clock to win there. The real speed
items, both CPU:
1. The reparse tax: audits re-read and re-parse the same multi-MB JSON repeatedly (4.7 s a pass, many
   passes). A DuckDB cache materialized once per run (source of truth stays the JSON files; the cache is
   derived, per the bid-single-source rule) makes every subsequent query sub-second.
2. The watcher suite spends most of its 81 s spawning ~40 child PowerShell 5.1 processes. PS7 with a
   consolidated runner roughly halves it. Not urgent; do it when convenient.

## Explicitly rejected, so nobody re-litigates it later

- CUDA-ifying the regex sweep: 38 s/day of branchy string work, the worst shape for SIMT. No.
- RAPIDS/cuDF for board math: ~500 rows. No.
- GPU JSON parsing: DuckDB solves the actual problem. No.
- Local LLM replacing Claude triage: quality regression on exactly the judgment calls that produced
  this month's bugs. No.
- Price forecasting models: 22 weeks of history and the product's promise is verified prices, not
  predictions. The robust-statistics outlier audits already do the defensible version. Not yet.
- Stealth-automation frameworks for the walled stores: the sanctioned pattern is Brad's own browser
  session, human-paced. The VLM lane reduces the pain inside that pattern instead.

## Integration rules (the guard culture is not negotiable)

1. ADVISORY ONLY. Sidecar findings flow into arrivals-desk, contested-match, coverage reports, and
   worklists. Nothing it says changes a price, a crown, or a rule without the existing adjudication
   path (add-known-wrong, commodity-rule edit + crown-diff + tile-integrity).
2. BLIND, never block. Sidecar down = advisory checks report BLIND (exit 3 convention), publish
   proceeds. The board must never depend on the GPU box being healthy.
3. Fixtures like everything else. Each lane ships frozen must-fire cases (the cloves word-order pair,
   the bath-soap pair, a flyer jpg with known rows) wired into test-auditors. Model files pinned and
   hashed; scores asserted with tolerance bands (GPU nondeterminism is real; exact-match fixtures
   would flake).
4. The backtest IS the acceptance gate. Before anything wires in: run Lane 1 against July's captured
   feeds and score it against the 99-defect ledger. Ship only if it flags a meaningful share of the
   known identity defects at a false-positive rate the arrivals desk can absorb (target: under ~30
   advisory rows/day). If it fails the backtest, we learned something cheap.
5. Freeze-compatible rollout. Phase 1 (install + backtest) touches zero grocery scripts: it reads
   captured data offline. Wiring into the nightly chain is a grocery-code change and waits for the
   freeze to lift (~08-07) or Brad's explicit go, same as the board redesign did.

## Install list (greenfield; ~25 GB disk total)

- Python 3.12 via uv (uv manages everything; no system pip sprawl)
- PyTorch cu128 wheels (Blackwell sm_120 REQUIRES CUDA 12.8-era builds; older cu121 wheels will not
  run on this card; driver 596.49 is fine)
- sentence-transformers + BAAI/bge-m3 (embeddings) + BAAI/bge-reranker-v2-m3 (cross-encoder)
- Ollama for Windows: qwen2.5:14b-instruct (Q5, ~10.5 GB) + qwen2.5-vl:7b (~7 GB)
- duckdb (pip) for the cache layer
- FastAPI + uvicorn for the sidecar shell
- Optional later: WSL2 + vLLM if nightly batch times ever matter; Ollama is enough to start

## Phases

- P1 (no grocery code): install stack, build sidecar, embed the July corpora, run the 99-defect
  backtest, publish the score. One focused day.
- P2 (post-freeze, Brad's go): wire Lane 1 advisories into arrivals/contested/coverage + fixtures.
- P3: Lane 2 flyer extraction behind the existing import gates; screenshot second-reading diff.
- P4: the Family Fare aisle test built on /score-match, then the depth/discovery program it unblocks.
- P5: weekly fine-tune scheduled task + drift watch (fixture scores re-asserted after every model swap).
