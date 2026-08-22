"""Load Qwen3.8-27B in 4-bit, attach LoRA, run N steps. Measure VRAM + throughput."""
import json, os, time, sys
import torch
from transformers import AutoTokenizer, AutoModelForCausalLM, BitsAndBytesConfig
from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training

M = r"C:\Codex\llm\models\Qwen3.8-27B-bf16"
SP = os.path.dirname(os.path.abspath(__file__))
STEPS = int(os.environ.get("STEPS", "20"))
MICRO = int(os.environ.get("MICRO", "1"))
MAXLEN = int(os.environ.get("MAXLEN", "1024"))

def vram(tag):
    f, t = torch.cuda.mem_get_info()
    print(f"[{tag}] used={(t-f)/2**30:.2f} GiB  free={f/2**30:.2f} GiB "
          f"torch_alloc={torch.cuda.memory_allocated()/2**30:.2f} "
          f"peak={torch.cuda.max_memory_allocated()/2**30:.2f}", flush=True)

vram("start")
tok = AutoTokenizer.from_pretrained(M)
print("tokenizer ok, vocab", len(tok), flush=True)

bnb = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
                         bnb_4bit_use_double_quant=True,
                         bnb_4bit_compute_dtype=torch.bfloat16)
t0 = time.time()
model = AutoModelForCausalLM.from_pretrained(
    M, quantization_config=bnb, dtype=torch.bfloat16,
    device_map="auto", max_memory={0: "13GiB", "cpu": "48GiB"},
    attn_implementation="sdpa")
print(f"load: {time.time()-t0:.0f}s", flush=True)
vram("loaded")

dm = getattr(model, "hf_device_map", {})
onc = sum(1 for v in dm.values() if v == "cpu" or v == "disk")
print(f"device_map entries: {len(dm)}  on cpu/disk: {onc}", flush=True)

model.config.use_cache = False
model = prepare_model_for_kbit_training(model, use_gradient_checkpointing=True)
model.gradient_checkpointing_enable()
model.enable_input_require_grads()

lc = LoraConfig(r=16, lora_alpha=32, lora_dropout=0.05, bias="none", task_type="CAUSAL_LM",
                target_modules=["gate_proj","up_proj","down_proj",
                                "q_proj","k_proj","v_proj","o_proj",
                                "in_proj_qkv","in_proj_z","in_proj_b","in_proj_a","out_proj"])
model = get_peft_model(model, lc)
tr = sum(p.numel() for p in model.parameters() if p.requires_grad)
print(f"trainable params: {tr/1e6:.1f}M", flush=True)
vram("lora attached")

rows = [json.loads(l) for l in open(os.path.join(SP, "corpus.jsonl"), encoding="utf-8")][:STEPS*MICRO*2]
def encode(r):
    msgs = [{"role":"system","content":r["system"]},{"role":"user","content":r["user"]}]
    try:
        p = tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True,
                                    enable_thinking=False)
    except TypeError:
        p = tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
    full = p + r["completion"] + (tok.eos_token or "")
    pi = tok(p, add_special_tokens=False)["input_ids"]
    fi = tok(full, add_special_tokens=False)["input_ids"][:MAXLEN]
    lab = list(fi)
    for i in range(min(len(pi), len(lab))): lab[i] = -100
    return fi, lab

batches, buf = [], []
for r in rows:
    buf.append(encode(r))
    if len(buf) == MICRO:
        L = max(len(x[0]) for x in buf)
        pad = tok.pad_token_id or tok.eos_token_id
        ids  = torch.tensor([x[0]+[pad]*(L-len(x[0])) for x in buf])
        labs = torch.tensor([x[1]+[-100]*(L-len(x[1])) for x in buf])
        att  = torch.tensor([[1]*len(x[0])+[0]*(L-len(x[0])) for x in buf])
        batches.append((ids, labs, att)); buf = []
    if len(batches) >= STEPS: break
print(f"batches: {len(batches)}  seq lens: {[b[0].shape[1] for b in batches[:8]]}", flush=True)

opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=1e-4)
model.train()
torch.cuda.reset_peak_memory_stats()
times, ntok = [], 0
for i, (ids, labs, att) in enumerate(batches):
    torch.cuda.synchronize(); t = time.time()
    out = model(input_ids=ids.cuda(), attention_mask=att.cuda(), labels=labs.cuda())
    out.loss.backward(); opt.step(); opt.zero_grad(set_to_none=True)
    torch.cuda.synchronize(); dt = time.time()-t
    times.append(dt); ntok += ids.numel()
    if i < 3 or (i+1) % 5 == 0:
        print(f"  step {i+1:3d}  {dt:6.2f}s  loss={out.loss.item():.4f}  "
              f"tok={ids.numel()}  peak={torch.cuda.max_memory_allocated()/2**30:.2f} GiB", flush=True)

warm = times[3:] or times
print(f"\n=== RESULT ===")
print(f"steps={len(times)}  mean(step 4+)={sum(warm)/len(warm):.2f}s  min={min(times):.2f}s  max={max(times):.2f}s")
tps = ntok/sum(times)
print(f"throughput: {tps:.1f} tok/s")
vram("end")
CORPUS = 3198; MEANTOK = 536
print(f"\nepoch estimate: {CORPUS} ex x {MEANTOK} tok = {CORPUS*MEANTOK:,} tok "
      f"-> {CORPUS*MEANTOK/tps/3600:.2f} h/epoch")
