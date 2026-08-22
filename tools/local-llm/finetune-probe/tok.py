"""Exact token counts for the fine-tune corpus, via the live llama.cpp tokenizer."""
import json, os, sys, urllib.request, statistics, random

REPO = r"C:\Codex\ThriftyCrew"
sys.path.insert(0, os.path.join(REPO, "graph", "lib"))
sys.path.insert(0, os.path.join(REPO, "graph", "gold"))
sys.path.insert(0, os.path.join(REPO, "graph", "pipeline"))
from graphdb import open_db
from seed_gold import load_gold
from resolve import Resolver, build_resolve_prompt

EP = "http://127.0.0.1:8080"
def ntok(text):
    req = urllib.request.Request(EP + "/tokenize",
        data=json.dumps({"content": text}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return len(json.loads(r.read())["tokens"])

db = open_db()
gold = [g for g in load_gold() if g.get("kind") == "match"]
r = Resolver(db, llm=None, use_llm=False)

built = []
for g in gold:
    node = g["commodity_node"]
    if not db.get_node(node):
        node = node.replace(":staple:", ":recipe:")
        if not db.get_node(node):
            continue
    try:
        cc = r.commodity(node)
    except Exception:
        continue
    built.append((g, node, cc))

random.Random(20260822).shuffle(built)
SAMPLE = int(sys.argv[1]) if len(sys.argv) > 1 else 300
sample = built[:SAMPLE]
print(f"tokenizing {len(sample)} of {len(built)} cases ...")

ptok, ctok, pchar, cchar = [], [], [], []
for i, (g, node, cc) in enumerate(sample):
    pool = r._verdict_index.get(node) or []
    saved = list(pool)
    tgt = (g["product"] or "").strip().lower()
    r._verdict_index[node] = [p for p in saved if (p[0] or "").strip().lower() != tgt]
    try:
        priors = r._prior_rulings(cc, g["product"])
        system, user = build_resolve_prompt(cc, g["product"], priors)
    finally:
        r._verdict_index[node] = saved
    completion = json.dumps({"verdict": g["label"], "confidence": 0.95,
                             "evidence": (g.get("evidence") or "")[:400]})
    p = system + "\n" + user
    ptok.append(ntok(p)); ctok.append(ntok(completion))
    pchar.append(len(p));  cchar.append(len(completion))
    if (i+1) % 50 == 0: print(f"  {i+1}/{len(sample)}")

def rep(name, v):
    v2 = sorted(v)
    print(f"{name:16s} median={statistics.median(v2):7.1f} mean={sum(v2)/len(v2):8.1f} "
          f"p95={v2[int(len(v2)*.95)]:7.0f} max={v2[-1]:7.0f}")

print()
rep("prompt tokens", ptok); rep("completion tokens", ctok)
per_ex = (sum(ptok)+sum(ctok))/len(ptok)
ratio  = (sum(pchar)+sum(cchar))/(sum(ptok)+sum(ctok))
print(f"\nmeasured chars/token : {ratio:.3f}")
print(f"mean tokens/example  : {per_ex:.1f}")
print(f"TOTAL corpus ({len(built)} cases) : {per_ex*len(built):,.0f} tokens/epoch")
seq = sorted(a+b for a,b in zip(ptok,ctok))
print(f"seq len p95={seq[int(len(seq)*.95)]:.0f}  max={seq[-1]:.0f}"
      f"   -> pack at {2**(max(seq)-1).bit_length()} tokens")
