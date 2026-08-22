# Fine-tune feasibility probes

Six read-only probes that answered "can we LoRA the local model on this box?"
Verdict and full numbers: `design/MEASURE-local-finetune-feasibility-2026-08-22.md`
(short version: no — the 4-bit 27B fills 100% of this card's VRAM, and the
2.37 GiB bf16 embedding table is not quantizable).

Run with the training venv, NOT sidecar/.venv:

    C:\Codex\llm\.venv-train\Scripts\python.exe tools/local-llm/finetune-probe/<probe>.py

| probe | needs | what it answers |
|---|---|---|
| `measure_corpus.py` | repo only | corpus size, char lengths, warm/cold split, commodity spread |
| `tok.py [n]`        | llama-server up | exact token counts via the real tokenizer |
| `build_corpus.py`   | repo only | emits corpus.jsonl (warm + priors-ablated cold pairs) |
| `arch_probe.py`     | bf16 weights | module map on a meta device — no VRAM, no weight reads |
| `fit_probe.py [quantize_lm_head]` | bf16 weights + GPU | actual 4-bit VRAM footprint |
| `step_probe.py`     | bf16 weights + GPU | 20 training steps: VRAM peak + throughput (does not fit today) |

`tok.py` needs the endpoint: `tools/local-llm/serve.ps1`, and STOP IT after
(`Get-Process llama-server | Stop-Process -Force`) — it holds ~13 GB and the
07:00 semantic sweep goes BLIND if it is still up.

All probes write only to their own directory or the scratchpad; none mutate the
graph DB, the board, or gold.
