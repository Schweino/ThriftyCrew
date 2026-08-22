# Can we fine-tune the local model on this box? — measured 2026-08-22

**Verdict: YES. Qwen3.8-27B trains on the RTX 5070 Ti at 57.3 tok/s, 8.3 h per
epoch, peaking at 15.59 of 15.92 GiB and 51 C.**

> **This document was wrong on first commit (9e93f49b) and says so deliberately.**
> The first verdict was "NO — the embedding table is the wall". That was a real
> measurement of a naive configuration, generalised into a claim about the
> hardware. Three changes overturned it. Section 8 keeps the error on the record
> because the reasoning failure is the reusable part: *a measurement of one
> configuration is not a measurement of the machine.*

Everything below is measured on this box on this date. Scripts are in
`tools/local-llm/finetune-probe/` and re-run in minutes.

---

## 1. The question

The local model (`Qwen3.8-27B-UD-Q3_K_XL`, `tools/local-llm/serve.ps1`) makes
false MATCH calls at high confidence. `resolve-v4-reject-only-with-priors`
already cut that 54% -> 29% by retrieving the board's own prior rulings as
few-shot.

The residual weakness is **generalization**: the prior-ruling index is keyed per
commodity (`_verdict_index.get(cc.node_id)`), so 43 rejections banked on
powdered-sugar teach nothing about an identical trap on brown-sugar, and a new
commodity is judged blind. That gap is what weights close and retrieval
structurally cannot.

## 2. The corpus — measured, and larger than assumed

`graph/gold/gold.jsonl` holds **1,668 hand-adjudicated cases**, not the 30 the
bench samples. 1,653 resolve to a live commodity node (12 reference dead nodes —
minor gold hygiene issue; the bench skips them).

| | |
|---|---|
| Trainable cases | 1,653 |
| Labels | 1,089 MATCH / 564 NO_MATCH (66/34) |
| Sources | 1,079 escalation-review, 388 product-urls, 186 known-wrong |
| Distinct commodities | 478 (210 with exactly one case) |

Token counts via the live llama.cpp tokenizer (`tok.py`, n=300), each case built
as the **real v4 prompt with leave-one-out priors**:

| | median | mean | p95 | max |
|---|---|---|---|---|
| prompt tokens | 472 | 483 | 657 | 762 |
| completion tokens | 50 | 53 | 90 | 173 |

- **3.569 chars/token** measured; 536 tokens/example
- **~886,000 tokens per epoch** (1,653 cases) — smaller than the 1.3M estimated
  from the Stage-1 figure in `serve.ps1`
- max sequence 800 -> packs at 1,024

### 2.1 The corpus is 93.5% warm — a design trap

Only **108 of 1,653** cases (6.5%) have no retrieved priors. Training as-is
teaches "trust the retrieved priors" — which the model already does — while
cold-start generalization, the thing actually being bought, is 6% of the data.

Fix: build each case **twice**, warm and with priors ablated. `build_corpus.py`
emits **3,198 rows — 1,653 warm + 1,545 cold**.

## 3. The model — architecture facts that matter

From `config.json` and a **meta-device enumeration** (`arch_probe.py`, no weights,
no VRAM):

- `Qwen3_5ForConditionalGeneration`, but `AutoModelForCausalLM` resolves to
  **`Qwen3_5ForCausalLM`** — text-only; the vision tower never instantiates.
  **26.90B params**, none visual.
- **Hybrid linear attention**: 64 layers, `full_attention_interval: 4` ->
  **48 linear_attention + 16 full_attention**, `mamba_ssm_dtype: float32`.
- All **497 targetable modules are plain `nn.Linear`** and LoRA-attachable:
  - `gate_proj`/`up_proj`/`down_proj` — all 64 layers
  - `q_proj`/`k_proj`/`v_proj`/`o_proj` — the 16 full-attention layers
  - `in_proj_qkv`/`in_proj_z`/`in_proj_b`/`in_proj_a`/`out_proj` — the 48 linear layers
  - SSM state and conv internals are not Linear; don't target them.
- **`vocab_size: 248,320`, untied embeddings** -> 2.54B params in embed + lm_head.
- The embedding tensor is `model.language_model.embed_tokens.weight`, in shard 3.

## 4. The naive configuration does NOT fit — and why that is not the whole story

`fit_probe.py quantize_lm_head`, NF4 + double quant, everything on GPU:

```
card total          15.92 GiB
free at start       14.68 GiB   (desktop held 1.24 GiB)
weights resident    14.68 GiB
free after load      0.00 GiB
  body (4-bit)      11.34 GiB
  embeddings         2.37 GiB   <-- bf16, nn.Embedding is not quantizable
  lm_head (4-bit)    0.59 GiB
```

True, and it is where the first verdict stopped. The error was concluding the
machine could not do it, when what had been shown was that *this arrangement*
could not.

## 5. The configuration that DOES fit

`train_probe2.py`. Three changes, each attacking a different consumer:

1. **Embeddings live in system RAM.** A 248k x 5120 embedding is a *lookup*: a
   step touches ~500 rows of it. Materialise it on the CPU
   (`safetensors.safe_open` on shard 3 — the loader leaves a meta placeholder
   under bnb offload, so it must be built by hand and its accelerate hook
   removed), do the lookup there, ship ~10 MB of vectors to the GPU.
   **Frees 2.37 GiB.**
2. **Loss only at answer positions.** Running `lm_head` over all ~500 positions
   makes a 500 x 248,320 logits tensor (~500 MiB, ~1 GiB once cross-entropy
   upcasts to fp32). Only the ~50 answer tokens carry a label. Gathering the
   hidden states first turns that into ~50 x 248,320. **~10x off the largest
   activation.**
3. **Paged 8-bit AdamW** (`bnb.optim.PagedAdamW8bit`), r=8, gradient
   checkpointing with `use_reentrant=False`.

### Measured, 30/30 steps, no OOM

| | |
|---|---|
| Free VRAM after load | **1.59 GiB** (was 0.00) |
| Trainable params | 58.4M |
| Mean step (step 4+) | **8.14 s** (min 5.02, max 20.72) |
| Throughput | **57.3 tok/s** |
| Peak VRAM | **15.59 / 15.92 GiB** |
| **Epoch (3,198 rows)** | **8.31 h** |
| Max temp / power | **51 C / 166 W** (cap 250 W; throttles ~88 C) |

## 6. The two numbers that govern any real run

**Headroom is 0.33 GiB.** Peak 15.59 against 15.92 total. A few Chrome tabs or a
game launching mid-run OOMs it. An 8-hour job needs the desktop left alone, and
that is an operational constraint, not a tuning one.

**8.3 h/epoch, and 2-3 epochs are wanted: 17-25 h of continuous GPU.** That does
not fit one overnight window before the 07:00 sweep. Either interleave across
nights with save/resume, or the sweep goes BLIND — which the estate's own rules
forbid.

Why slower than the 2-4 h predicted from FLOPs: batch size 1 at ~500 tokens does
not saturate the card, so most of a step is overhead rather than math. Bigger
batches would fix it; there is no memory for bigger batches. **The FLOP
arithmetic was not wrong about the card, it was wrong about the utilisation.**

### 6.1 Local vs cloud, both sides now measured

| | local | cloud A100 80GB |
|---|---|---|
| Wall clock | 17-25 h across nights | ~1 h |
| Cost | electricity | ~$10 |
| Failure risk | OOM if the desktop takes VRAM | none |
| Sweep impact | must interleave nightly | none |

Local is possible and is the better fallback. Cloud is the better way to get the
answer. Both use the same corpus and the same script.

## 7. Design decisions that hold regardless of venue

1. **Ship as a detached LoRA adapter, never a merged GGUF.** Three callers share
   `local-primary`; a merged checkpoint specialized on adjudication risks
   degrading extraction (currently 1.000 valid JSON) and Learning Stage 1.
2. **Hold out whole commodity families**, not random rows. 478 commodities, 210
   singletons — this is easy, and it makes the test set cold-start by
   construction, which is the capability being bought.
3. **Keep reject-only afterward.** Fine-tuning tends to make models more
   confident, not better calibrated. A fine-tune is not a license to publish a
   local MATCH.
4. **Gates before starting:** false reject stays <= 1/34, and the full bench
   re-passes — extraction validity and decode speed, not just the resolution slice.
5. **Thermal watchdog on any local run.** `gpu_watchdog.sh` samples every 5 s and
   kills the training process at 84 C, T.Limit headroom <= 6, or any thermal
   slowdown flag — roughly 10 C below where the card would even throttle. In
   practice the run peaked at 51 C with the fans never spinning up; the real
   risk on this box is VRAM, not heat.

## 8. Corrections — kept on the record

- **"You only have 30 gold examples."** Wrong: 1,668. The bench's sample size was
  mistaken for the corpus.
- **"27B QLoRA fits with a bit of RAM offload."** Wrong at the time (off by ~3 GB)
  and the mechanism was misunderstood: bitsandbytes' `fp32_cpu_offload`
  *executes* modules on the CPU rather than streaming weights, so the
  PCIe-bandwidth estimate described something the stack does not do.
- **"27B is the better first run because it isolates one variable."** Sound
  argument; appeared defeated by hardware; ultimately correct after all.
- **"Use the 14B instead."** No such model — the Qwen3.8 family is 27B and
  2.4T-A95B only.
- **"Not possible on this hardware. Verdict: NO."** **Wrong, and committed to the
  repo as fact.** One naive configuration was measured and the conclusion was
  generalised to the machine. Three memory changes overturned it in about an
  hour. The tell was there in the first measurement and went unexamined: the
  blocking 2.37 GiB was an *embedding table*, and an embedding table is a lookup
  that never needed to be resident.
- **"On your hardware it is about as capable as it is going to get."** Unfounded.
  True of one model at one setting, not of the box. Untested levers remain:
  other candidate models through `graph/bench/bench.py`, a less-compressed quant
  now that prompts are known to be ~480 tokens, and thinking mode — currently
  disabled globally for a budget reason, on a reasoning model, for exactly the
  hard cases where reasoning might pay.

**The pattern in every one of these:** the estimates that held were about data
(corpus size, token counts). The estimates that failed were about memory and
capability, asserted without loading anything. Loading the model settles it in
55 seconds. Load first.

## 9. Artifacts

- `tools/local-llm/finetune-probe/` — probes and the thermal watchdog, re-runnable
- `C:\Codex\llm\.venv-train` — torch 2.11+cu128, transformers 5.15.1, peft 0.20.0,
  bitsandbytes 0.50.1, trl 1.10.0. Deliberately **not** `sidecar/.venv`, which
  runs the 07:00 semantic sweep and must not be contaminated.
- `C:\Codex\llm\models\Qwen3.8-27B-bf16` — 55.56 GB, 18 shards
- Corpus JSONL regenerates from `build_corpus.py`; not committed, per the
  reproducible-from-script rule.

**GPU hygiene:** every probe ran on demand and released the card; the 07:00 sweep
was never at risk. A real training run holds the GPU for hours and must be
scheduled after the sweep, never before it.

## 10. Not yet done

The holdout split does not exist. Before any real run, split by **commodity
family** so the test set is cold by construction, and fix the training-time
report to show holdout false-MATCH rate against the stock-27B 29% baseline —
per-example loss during training is noise, not a learning signal.
