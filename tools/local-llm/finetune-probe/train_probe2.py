"""Fit probe, round 2. Three memory moves the first probe lacked:
  1. embed_tokens lives in system RAM (a lookup; ~10 MB/step crosses PCIe)
  2. loss computed only at answer positions -> the 248k-wide logits tensor is
     ~50-170 rows, not 1,024
  3. paged 8-bit AdamW (optimizer state can spill to RAM under pressure)
Writes train.pid for the watchdog and train.done at exit."""
import os, sys, json, time, traceback
os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")
SP = os.path.dirname(os.path.abspath(__file__))
open(os.path.join(SP, "train.pid"), "w").write(str(os.getpid()))

def done():
    open(os.path.join(SP, "train.done"), "w").write("done")

try:
    import torch, torch.nn.functional as F
    from transformers import AutoTokenizer, AutoModelForCausalLM, AutoConfig, BitsAndBytesConfig
    from accelerate import init_empty_weights
    from peft import LoraConfig, get_peft_model
    import bitsandbytes as bnb

    M = r"C:\Codex\llm\models\Qwen3.8-27B-bf16"
    STEPS = int(os.environ.get("STEPS", "30")); MAXLEN = 1024; R = int(os.environ.get("R", "8"))

    def vram(tag):
        f, t = torch.cuda.mem_get_info()
        print(f"[{tag}] free={f/2**30:.2f} GiB  torch_alloc={torch.cuda.memory_allocated()/2**30:.2f} "
              f"peak={torch.cuda.max_memory_allocated()/2**30:.2f}", flush=True)

    vram("start")
    cfg = AutoConfig.from_pretrained(M)
    with init_empty_weights():
        skel = AutoModelForCausalLM.from_config(cfg)
    device_map = {}
    for name, child in skel.named_children():
        if name == "model":
            for n2, _ in child.named_children():
                device_map[f"model.{n2}"] = "cpu" if n2 == "embed_tokens" else 0
        else:
            device_map[name] = 0
    del skel
    print("device_map:", device_map, flush=True)

    tok = AutoTokenizer.from_pretrained(M)
    bnbc = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
                              bnb_4bit_use_double_quant=True,
                              bnb_4bit_compute_dtype=torch.bfloat16,
                              llm_int8_skip_modules=[],
                              llm_int8_enable_fp32_cpu_offload=True)
    t0 = time.time()
    model = AutoModelForCausalLM.from_pretrained(M, quantization_config=bnbc, dtype=torch.bfloat16,
                                                 device_map=device_map, attn_implementation="sdpa")
    print(f"load: {time.time()-t0:.0f}s", flush=True)
    vram("loaded")
    # The loader leaves a CPU-mapped module as an empty META placeholder under
    # bnb offload. Materialise the one tensor ourselves, in RAM, from its shard.
    from safetensors import safe_open
    from accelerate.hooks import remove_hook_from_module
    idx = json.load(open(os.path.join(M, "model.safetensors.index.json")))["weight_map"]
    key = "model.language_model.embed_tokens.weight"
    with safe_open(os.path.join(M, idx[key]), framework="pt", device="cpu") as f:
        w = f.get_tensor(key).to(torch.bfloat16)
    emb = torch.nn.Embedding(w.shape[0], w.shape[1], _weight=w).cpu()
    emb.weight.requires_grad_(False)
    remove_hook_from_module(model.model.embed_tokens)
    model.model.embed_tokens = emb
    print("embed device:", emb.weight.device, emb.weight.dtype, f"{w.numel()*w.element_size()/2**30:.2f} GiB in RAM", flush=True)

    model.config.use_cache = False
    model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
    lc = LoraConfig(r=R, lora_alpha=2*R, lora_dropout=0.05, bias="none", task_type="CAUSAL_LM",
                    target_modules=["gate_proj","up_proj","down_proj","q_proj","k_proj","v_proj","o_proj",
                                    "in_proj_qkv","in_proj_z","in_proj_b","in_proj_a","out_proj"])
    pm = get_peft_model(model, lc)
    tr = [p for p in pm.parameters() if p.requires_grad]
    print(f"trainable: {sum(p.numel() for p in tr)/1e6:.1f}M params  dtype={tr[0].dtype}", flush=True)
    vram("lora attached")

    inner = pm.base_model.model          # Qwen3_5ForCausalLM
    decoder, head = inner.model, inner.lm_head

    rows = [json.loads(l) for l in open(os.path.join(SP, "corpus.jsonl"), encoding="utf-8")][:STEPS]
    def encode(r):
        msgs = [{"role":"system","content":r["system"]},{"role":"user","content":r["user"]}]
        try:    p = tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True, enable_thinking=False)
        except TypeError: p = tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
        pi = tok(p, add_special_tokens=False)["input_ids"]
        fi = tok(p + r["completion"] + (tok.eos_token or ""), add_special_tokens=False)["input_ids"][:MAXLEN]
        lab = list(fi); lab[:len(pi)] = [-100]*min(len(pi), len(lab))
        return torch.tensor([fi]), torch.tensor([lab])

    opt = bnb.optim.PagedAdamW8bit(tr, lr=1e-4)
    pm.train(); torch.cuda.reset_peak_memory_stats()
    times, ntok, nans = [], 0, 0
    for i, r in enumerate(rows):
        ids, labs = encode(r)
        torch.cuda.synchronize(); t = time.time()
        with torch.no_grad():
            x = emb(ids.to(emb.weight.device)).to("cuda", torch.bfloat16)   # lookup in RAM, ship 10 MB
        x.requires_grad_(True)
        out = decoder(inputs_embeds=x, attention_mask=torch.ones_like(ids).cuda(), use_cache=False)
        h = out.last_hidden_state[:, :-1]
        tgt = labs[:, 1:].cuda()
        m = tgt != -100
        logits = head(h[m]).float()                                         # only answer rows
        loss = F.cross_entropy(logits, tgt[m])
        loss.backward(); opt.step(); opt.zero_grad(set_to_none=True)
        torch.cuda.synchronize(); dt = time.time()-t
        times.append(dt); ntok += ids.numel(); nans += int(m.sum())
        if i < 5 or (i+1) % 5 == 0:
            print(f"  step {i+1:3d} {dt:6.2f}s loss={loss.item():.4f} seq={ids.shape[1]} ans={int(m.sum())} "
                  f"peak={torch.cuda.max_memory_allocated()/2**30:.2f} GiB", flush=True)
    warm = times[3:] or times
    tps = ntok/sum(times)
    print("\n=== RESULT ===")
    print(f"steps={len(times)} mean(step4+)={sum(warm)/len(warm):.2f}s min={min(times):.2f} max={max(times):.2f}")
    print(f"throughput {tps:.1f} tok/s   peak VRAM {torch.cuda.max_memory_allocated()/2**30:.2f} GiB")
    vram("end")
    print(f"epoch estimate (3198 ex x 536 tok): {3198*536/tps/3600:.2f} h")
except Exception:
    traceback.print_exc()
    print("FAILED", flush=True)
finally:
    done()
