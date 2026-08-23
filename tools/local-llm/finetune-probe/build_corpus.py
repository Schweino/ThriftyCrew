"""Emit the fine-tune corpus as JSONL: the v4 resolve prompt (LOO priors) -> verdict JSON.
Read-only against the repo; writes only to the scratchpad."""
import json, os, sys, random, collections

REPO = r"C:\Codex\ThriftyCrew"
for p in ("graph/lib", "graph/gold", "graph/pipeline"):
    sys.path.insert(0, os.path.join(REPO, *p.split("/")))
from graphdb import open_db
from seed_gold import load_gold
from resolve import Resolver, build_resolve_prompt

OUT = os.path.dirname(os.path.abspath(__file__))
db = open_db()
r = Resolver(db, llm=None, use_llm=False)
gold = [g for g in load_gold() if g.get("kind") == "match"]

rows = []
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
    pool = r._verdict_index.get(node) or []
    saved = list(pool)
    tgt = (g["product"] or "").strip().lower()
    r._verdict_index[node] = [p for p in saved if (p[0] or "").strip().lower() != tgt]
    try:
        # Since prompt v5 (2026-08-22) this returns ADJUDICATED rulings only, so the
        # "warm" half of the corpus no longer teaches the model to trust its own
        # unreviewed rejections. Deliberate: training on self-citation would bake the
        # loop into the weights, where no retrieval change could undo it. Pass
        # authority="all" here only to reproduce a pre-v5 corpus for comparison.
        priors_warm = r._prior_rulings(cc, g["product"])
    finally:
        r._verdict_index[node] = saved

    completion = json.dumps({"verdict": g["label"], "confidence": 0.95,
                             "evidence": (g.get("evidence") or "")[:400]}, ensure_ascii=False)

    for variant, priors in (("warm", priors_warm), ("cold", {})):
        if variant == "cold" and not (priors_warm.get("rejected") or priors_warm.get("confirmed")):
            continue  # already cold as warm; don't duplicate
        system, user = build_resolve_prompt(cc, g["product"], priors)
        rows.append({"node": node, "commodity": g["commodity"], "label": g["label"],
                     "variant": variant, "system": system, "user": user,
                     "completion": completion})

random.Random(20260822).shuffle(rows)
path = os.path.join(OUT, "corpus.jsonl")
with open(path, "w", encoding="utf-8") as fh:
    for x in rows:
        fh.write(json.dumps(x, ensure_ascii=False) + "\n")

print(f"rows: {len(rows)}  -> {path}")
print("variant:", dict(collections.Counter(x['variant'] for x in rows)))
print("label  :", dict(collections.Counter(x['label'] for x in rows)))
print("commodities:", len({x['node'] for x in rows}))
