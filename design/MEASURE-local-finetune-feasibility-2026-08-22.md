# Can we fine-tune the local model on this box? — measured 2026-08-22

**Verdict: NO for Qwen3.8-27B on the RTX 5070 Ti. Measured, not estimated.**
The 4-bit weights occupy **100.0% of available VRAM** with 0.00 GiB left, before
a single byte of adapters, optimizer state, or activations. The deficit is ~3 GB
on a card that has none, and no quantization setting closes it.

Everything below is measurement from this box on this date. Scripts that produced
it live in `tools/local-llm/finetune-probe/` and re-run in minutes.

---

## 1. The question

The local model (`Qwen3.8-27B-UD-Q3_K_XL`, see `tools/local-llm/serve.ps1`) makes
false MATCH calls at high confidence. `resolve-v4-reject-only-with-priors` already
cut that 54% -> 29% by retrieving the board's own prior rulings as few-shot.

The residual weakness is **generalization**: the prior-ruling index is keyed per
commodity (`_verdict_index.get(cc.node_id)`), so 43 rejections banked on
powdered-sugar teach the model nothing about an identical trap on brown-sugar, and
a brand-new commodity is judged blind. That gap is what weights would close and
retrieval structurally cannot. Hence: is a local LoRA worth it, and is it possible?

## 2. The corpus — measured, and larger than assumed

`graph/gold/gold.jsonl` is **1,668 hand-adjudicated cases**, not the 30 the bench
samples. 1,653 resolve to a live commodity node (12 reference dead nodes — minor
gold hygiene issue, harmless because the bench skips them).

| | |
|---|---|
| Trainable cases | 1,653 |
| Labels | 1,089 MATCH / 564 NO_MATCH (66/34) |
| Sources | 1,079 escalation-review, 388 product-urls, 186 known-wrong |
| Distinct commodities | 478 (210 with exactly one case) |

Token counts via the live llama.cpp tokenizer (`tools/local-llm/finetune-probe/tok.py`,
n=300), building each case as the **real v4 prompt with leave-one-out priors**:

| | median | mean | p95 | max |
|---|---|---|---|---|
| prompt tokens | 472 | 483 | 657 | 762 |
| completion tokens | 50 | 53 | 90 | 173 |

- measured **3.569 chars/token**; 536 tokens/example
- **~886,000 tokens per epoch** — smaller than the 1.3M estimated from the
  Stage-1 figure in `serve.ps1`
- max sequence 800 -> **packs at 1,024**

### 2.1 The corpus is 93.5% warm — a design trap

Only **108 of 1,653** cases (6.5%) have no retrieved priors. Training on this
as-is teaches "trust the retrieved priors", which the model already does — while
cold-start generalization, the thing we actually want, would be represented by 6%
of the data.

Fix, decided before training rather than after: build each case **twice**, warm and
with priors ablated. `build_corpus.py` emits **3,198 rows — 1,653 warm + 1,545
cold**. This corpus is reusable regardless of where training eventually happens.

## 3. The model — architecture facts that matter

From `config.json` and a **meta-device enumeration** (`arch_probe.py`, no weights
loaded, no VRAM):

- `Qwen3_5ForConditionalGeneration`, but `AutoModelForCausalLM` resolves to
  **`Qwen3_5ForCausalLM`** — text-only, vision tower never instantiated.
  **26.90B params**, none visual.
- **Hybrid linear attention**: 64 layers, `full_attention_interval: 4` ->
  **48 linear_attention + 16 full_attention**, with `mamba_ssm_dtype: float32`.
- All **497 targetable modules are plain `nn.Linear`** and LoRA-attachable:
  - `gate_proj`/`up_proj`/`down_proj` — all 64 layers
  - `q_proj`/`k_proj`/`v_proj`/`o_proj` — the 16 full-attention layers only
  - `in_proj_qkv`/`in_proj_z`/`in_proj_b`/`in_proj_a`/`out_proj` — the 48 linear layers
  - SSM state and conv internals are not Linear; simply don't target them.
- **`vocab_size: 248,320`, untied embeddings** -> 2.54B params in embed + lm_head.

## 4. The fit measurement — the decisive result

`fit_probe.py quantize_lm_head`, NF4 + double quant, everything on GPU:

```
card total          15.92 GiB
free at start       14.68 GiB   (desktop holds 1.24 GiB)
weights resident    14.68 GiB
free after load      0.00 GiB
  body (4-bit)      11.34 GiB
  embeddings         2.37 GiB   <-- bf16, CANNOT be quantized
  lm_head (4-bit)    0.59 GiB
```

**The embeddings are the wall.** `nn.Embedding` is not quantizable by
bitsandbytes, so 2.37 GiB stays bf16 under every setting. That is the 248k
vocabulary charging rent. Quantizing `lm_head` (not the default) already bought
back ~1.9 GiB and it was not enough.

Still needed and unavailable: LoRA adapters + gradients + Adam (~0.3–1.5 GiB),
activations with gradient checkpointing (~1–2 GiB), and the logits tensor —
1,024 x 248,320 x 2 bytes = **508 MiB per forward**, roughly 1 GiB once
cross-entropy upcasts to fp32.

**Deficit ~3 GB against 0.00 GiB free.**

### 4.1 Why CPU offload does not rescue it

`device_map` with a 13 GiB cap fails outright:

> ValueError: Some modules are dispatched on the CPU or the disk... you need to
> set `llm_int8_enable_fp32_cpu_offload=True`

And that flag is not the cheap thing it sounds like. It **executes the offloaded
modules on the CPU in fp32** — it does not stream weights to the GPU per step.
Any estimate treating offload as a PCIe-bandwidth cost (~55 ms per 1,024-token
step, <1% overhead) is describing a mechanism this stack does not implement.

## 5. No smaller sibling exists

The Qwen3.8 family ships exactly two sizes: **27B** and **2.4T-A95B** (MoE).
There is no 14B. "Train the smaller one" therefore means adopting a **different
model generation** as primary — forfeiting the single-variable experiment and
forcing a full re-bench of resolve, Learning Stage 1, and
`meal-prep/pipeline/local_extract.py`, all of which share the `local-primary`
endpoint.

## 6. What would have to change

| Path | Viability |
|---|---|
| Cloud GPU (A100 80GB, few hours) | **Works.** Keeps the production model; adapter drops into `serve.ps1` via `--lora`. Corpus is already built. |
| Different smaller base, trained locally | Works technically; costs a primary-model swap and a full re-bench of four callers. |
| Bigger local card (24 GB+) | Works. A 24 GB card leaves ~9 GB of headroom. |
| Any config change on the 5070 Ti | **No.** The embedding floor is not configurable. |

## 7. Design decisions that survive regardless

1. **Ship as a detached LoRA adapter, never a merged GGUF.** Three callers share
   `local-primary`; a merged checkpoint specialized on adjudication risks
   degrading extraction (currently 1.000 valid JSON) and Stage 1.
2. **Hold out whole commodity families**, not random rows. With 478 commodities
   and 210 singletons this is easy, and it makes the test set cold-start by
   construction — which is the capability being bought.
3. **Keep reject-only afterward.** Fine-tuning tends to make models more
   confident, not better calibrated. A fine-tune is not a license to publish a
   local MATCH.
4. **Gates before starting:** false reject stays <= 1/34, and the full bench
   re-passes (extraction validity and decode speed, not just the resolution slice).

## 8. Corrections to earlier reasoning in this session

Recorded because the wrong turns are the reusable part:

- **"You only have 30 gold examples."** Wrong — 1,668. The 30 was the bench's
  sample size, mistaken for the corpus.
- **"27B QLoRA fits with a bit of RAM offload."** Wrong. Off by ~3 GB, and the
  offload mechanism was misunderstood (see 4.1).
- **"27B is the better first run because it isolates one variable."** The
  argument was sound; the hardware defeats it.
- **"Use the 14B instead."** No such model in this family.
- **Multimodality and the SSM layers were flagged as risks.** Both dissolved on
  inspection: text-only class, all projections plain `nn.Linear`.

The estimate that held up was the corpus arithmetic. The one that did not was
every claim about memory made without loading the model — which took 55 seconds
to settle definitively.

## 9. Artifacts

- `tools/local-llm/finetune-probe/` — all six probes, re-runnable
- `C:\Codex\llm\.venv-train` — torch 2.11+cu128, transformers 5.15.1, peft 0.20.0,
  bitsandbytes 0.50.1, trl 1.10.0 (deliberately NOT `sidecar/.venv`, which runs the
  07:00 semantic sweep and must not be contaminated)
- `C:\Codex\llm\models\Qwen3.8-27B-bf16` — 55.56 GB, 18 shards, kept for now
- Corpus JSONL is regenerated by `build_corpus.py`; not committed, per the
  repo's reproducible-from-script rule.

**GPU hygiene:** every probe here ran on-demand and released the card. The 07:00
semantic sweep was never at risk. Any future local training run would hold the
GPU for hours and must be scheduled after the sweep, never before it.
