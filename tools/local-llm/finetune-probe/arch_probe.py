"""Enumerate module names on a META-device model built from config alone.
No weights loaded, no VRAM, no disk reads of the shards."""
import collections, re
import torch
from transformers import AutoConfig, AutoModelForCausalLM
from accelerate import init_empty_weights

M = r"C:\Codex\llm\models\Qwen3.8-27B-bf16"
cfg = AutoConfig.from_pretrained(M, trust_remote_code=False)
print("config class :", type(cfg).__name__)
print("architectures:", getattr(cfg, "architectures", None))

with init_empty_weights():
    model = AutoModelForCausalLM.from_config(cfg, trust_remote_code=False)
print("model class  :", type(model).__name__)

lin = collections.Counter()
tot = 0
by_layer_type = collections.defaultdict(collections.Counter)
for name, mod in model.named_modules():
    if isinstance(mod, torch.nn.Linear):
        leaf = name.split(".")[-1]
        lin[leaf] += 1
        tot += 1
        m = re.search(r"layers\.(\d+)\.", name)
        if m:
            by_layer_type[int(m.group(1))][leaf] += 1

print(f"\ntotal nn.Linear modules: {tot}")
print("\nby leaf name:")
for k, v in lin.most_common():
    print(f"  {k:28s} {v}")

# Which leaves appear on a full-attention layer vs a linear-attention layer?
lt = getattr(getattr(cfg, "text_config", cfg), "layer_types", None)
if lt:
    full = [i for i, t in enumerate(lt) if t == "full_attention"]
    linr = [i for i, t in enumerate(lt) if t != "full_attention"]
    print(f"\nfull_attention layers: {len(full)}  e.g. {full[:4]}")
    print(f"linear_attention layers: {len(linr)}  e.g. {linr[:4]}")
    if full: print(f"  leaves on layer {full[0]} (full)  :", sorted(by_layer_type[full[0]]))
    if linr: print(f"  leaves on layer {linr[0]} (linear):", sorted(by_layer_type[linr[0]]))

# Param accounting on meta
n_all = sum(p.numel() for p in model.parameters())
print(f"\ntotal params: {n_all/1e9:.2f}B")
for tag in ("visual", "vision"):
    n = sum(p.numel() for nm, p in model.named_parameters() if nm.startswith(tag) or f".{tag}." in nm)
    if n: print(f"  {tag}: {n/1e9:.2f}B")
emb = sum(p.numel() for nm, p in model.named_parameters() if "embed" in nm or "lm_head" in nm)
print(f"  embeddings+lm_head: {emb/1e9:.2f}B")
