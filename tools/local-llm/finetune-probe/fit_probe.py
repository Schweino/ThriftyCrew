"""How much VRAM does the 4-bit 27B actually occupy, all-on-GPU?"""
import torch, time, sys
from transformers import AutoModelForCausalLM, BitsAndBytesConfig
M = r"C:\Codex\llm\models\Qwen3.8-27B-bf16"
SKIP = sys.argv[1] if len(sys.argv) > 1 else "default"
f, t = torch.cuda.mem_get_info()
print(f"card total={t/2**30:.2f} GiB  free at start={f/2**30:.2f} GiB")
kw = {}
if SKIP == "quantize_lm_head":
    kw["llm_int8_skip_modules"] = []
bnb = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
                         bnb_4bit_use_double_quant=True,
                         bnb_4bit_compute_dtype=torch.bfloat16, **kw)
t0 = time.time()
try:
    m = AutoModelForCausalLM.from_pretrained(M, quantization_config=bnb,
        dtype=torch.bfloat16, device_map={"": 0}, attn_implementation="sdpa")
except Exception as e:
    print(f"LOAD FAILED after {time.time()-t0:.0f}s: {type(e).__name__}: {str(e)[:300]}")
    sys.exit(2)
print(f"loaded in {time.time()-t0:.0f}s")
f2, _ = torch.cuda.mem_get_info()
print(f"weights resident: {(f-f2)/2**30:.2f} GiB   free now: {f2/2**30:.2f} GiB")
sizes = {}
for n, p in m.named_parameters():
    key = "lm_head" if "lm_head" in n else ("embed" if "embed" in n else "body")
    sizes[key] = sizes.get(key, 0) + p.numel() * p.element_size()
for k, v in sizes.items(): print(f"  {k:8s} {v/2**30:.2f} GiB  ")
