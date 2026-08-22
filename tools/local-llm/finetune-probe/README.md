# Fine-tune feasibility probes

Probes that answered "can we LoRA the local model on this box?"
Verdict and full numbers: `design/MEASURE-local-finetune-feasibility-2026-08-22.md`
**Short version: YES - 57.3 tok/s, 8.3 h/epoch, peak 15.59 of 15.92 GiB, 51 C.**

The naive arrangement does NOT fit (`fit_probe.py` shows the 4-bit weights taking
100% of VRAM). `train_probe2.py` fits by keeping the 2.37 GiB embedding table in
system RAM (it is a lookup, not a resident need), computing loss only at answer
positions, and using a paged 8-bit optimizer. Headroom is 0.33 GiB - keep the
desktop clear during a run.

Run with the training venv, NOT sidecar/.venv:

    C:\Codex\llm\.venv-train\Scripts\python.exe tools/local-llm/finetune-probe/<probe>.py

| probe | needs | what it answers |
|---|---|---|
| `measure_corpus.py` | repo only | corpus size, char lengths, warm/cold split, commodity spread |
| `tok.py [n]`        | llama-server up | exact token counts via the real tokenizer |
| `build_corpus.py`   | repo only | emits corpus.jsonl (warm + priors-ablated cold pairs) |
| `arch_probe.py`     | bf16 weights | module map on a meta device — no VRAM, no weight reads |
| `fit_probe.py [quantize_lm_head]` | bf16 weights + GPU | actual 4-bit VRAM footprint |
| `step_probe.py`     | bf16 weights + GPU | naive 20-step attempt - kept because it documents the arrangement that does NOT fit |
| `train_probe2.py`   | bf16 weights + GPU | **the one that works.** 30 steps, embed in RAM, answer-only loss, paged 8-bit AdamW |
| `gpu_watchdog.sh`   | nvidia-smi | thermal guard: samples every 5 s, kills training at 84 C / headroom <= 6 / any thermal flag |

`tok.py` needs the endpoint: `tools/local-llm/serve.ps1`, and STOP IT after
(`Get-Process llama-server | Stop-Process -Force`) — it holds ~13 GB and the
07:00 semantic sweep goes BLIND if it is still up.

Run any local training under the watchdog (one shell each; training writes
train.pid and train.done, which the watchdog reads):

    bash tools/local-llm/finetune-probe/gpu_watchdog.sh

Measured peak on this box was 51 C at 166 W (cap 250 W, throttle ~88 C), so heat
is not the risk here - VRAM is.

All probes write only to their own directory or the scratchpad; none mutate the
graph DB, the board, or gold.
