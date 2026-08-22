"""Measure the REAL fine-tune corpus: build each gold case as the v4 resolve
prompt it would actually be served as, with leave-one-out priors, and report
size. Read-only. Writes nothing to the repo."""
import json, os, sys, collections, statistics

REPO = r"C:\Codex\ThriftyCrew"
sys.path.insert(0, os.path.join(REPO, "graph", "lib"))
sys.path.insert(0, os.path.join(REPO, "graph", "gold"))
sys.path.insert(0, os.path.join(REPO, "graph", "pipeline"))

from graphdb import open_db
from seed_gold import load_gold
from resolve import Resolver, build_resolve_prompt

db = open_db()
gold = [g for g in load_gold() if g.get("kind") == "match"]
print(f"gold cases (kind=match): {len(gold)}")

r = Resolver(db, llm=None, use_llm=False)
print(f"verdict index commodities: {len(getattr(r, '_verdict_index', {}) or {})}")

rows, missing = [], 0
for g in gold:
    node = g["commodity_node"]
    if not db.get_node(node):
        node = node.replace(":staple:", ":recipe:")
        if not db.get_node(node):
            missing += 1
            continue
    try:
        cc = r.commodity(node)
    except Exception:
        missing += 1
        continue

    # LEAVE-ONE-OUT: strip this very product from its own prior pool.
    pool = (r._verdict_index.get(node) or [])
    saved = list(pool)
    tgt = (g["product"] or "").strip().lower()
    r._verdict_index[node] = [p for p in saved if (p[0] or "").strip().lower() != tgt]
    try:
        priors = r._prior_rulings(cc, g["product"])
        system, user = build_resolve_prompt(cc, g["product"], priors)
    finally:
        r._verdict_index[node] = saved

    completion = json.dumps({"verdict": g["label"],
                             "confidence": 0.95,
                             "evidence": (g.get("evidence") or "")[:400]})
    rows.append({
        "node": node,
        "commodity": g["commodity"],
        "label": g["label"],
        "source": g.get("source"),
        "n_rej": len(priors.get("rejected", [])),
        "n_conf": len(priors.get("confirmed", [])),
        "chars_prompt": len(system) + len(user),
        "chars_completion": len(completion),
    })

print(f"built: {len(rows)}   unresolvable commodity node: {missing}")
if not rows:
    sys.exit("no rows built")

def stats(key):
    v = sorted(x[key] for x in rows)
    return (statistics.median(v), sum(v)/len(v), v[int(len(v)*0.95)], v[-1], sum(v))

for key in ("chars_prompt", "chars_completion"):
    med, mean, p95, mx, tot = stats(key)
    print(f"{key:18s} median={med:6.0f} mean={mean:7.0f} p95={p95:6.0f} max={mx:6.0f} total={tot:,}")

tot_chars = sum(x["chars_prompt"] + x["chars_completion"] for x in rows)
print(f"\nTOTAL chars/epoch : {tot_chars:,}")
for cpt in (3.5, 4.0, 4.5):
    print(f"  est tokens @ {cpt} chars/tok : {tot_chars/cpt:,.0f}")

print("\nlabel distribution:", dict(collections.Counter(x['label'] for x in rows)))
print("source distribution:", dict(collections.Counter(x['source'] for x in rows)))

withp = sum(1 for x in rows if x['n_rej'] or x['n_conf'])
print(f"\ncases WITH retrieved priors: {withp} ({withp/len(rows):.1%})")
print(f"cases COLD (no priors)     : {len(rows)-withp} ({(len(rows)-withp)/len(rows):.1%})")
print(f"mean priors: {sum(x['n_rej'] for x in rows)/len(rows):.2f} rejections, "
      f"{sum(x['n_conf'] for x in rows)/len(rows):.2f} confirms")

fam = collections.Counter(x["node"] for x in rows)
print(f"\ndistinct commodities: {len(fam)}")
print("top 10 by case count:", fam.most_common(10))
singles = sum(1 for c in fam.values() if c == 1)
print(f"commodities with exactly 1 case: {singles}")

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "corpus-measure.json")
json.dump(rows, open(out, "w", encoding="utf-8"), indent=1)
print(f"\nper-row detail -> {out}")
