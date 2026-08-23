"""Does the adjudication actually cause the win, or is it seed noise?

Trains the SAME recipe on two corpora that differ only by the Fable agents' corrections
(r2 = regex labels, r3 = adjudicated labels), across several shuffles, and scores every
run on the two arenas neither corpus chose. Weights are deleted after each run; only the
numbers are kept.
"""
import json, os, subprocess, sqlite3, sys, shutil, time

REPO = r"C:\Codex\ThriftyCrew"
SC = os.path.join(REPO, "sidecar")
PY = os.path.join(SC, ".venv", "Scripts", "python.exe")
OUT = sys.argv[1]
SEEDS = [int(x) for x in sys.argv[2].split(",")]

sys.path.insert(0, SC)
os.chdir(SC)
from lib_match import Matcher, clean_product, commodity_text, load_json   # noqa: E402
from hardeval import auc                                                  # noqa: E402

r1 = [json.loads(l) for l in open("data/pair-corpus/test.jsonl", encoding="utf-8")]
defsg = {d["node_id"]: d for d in load_json("data/commodity-defs-graph.json")}
cp = json.load(open("out/contested-scores-phase3.json", encoding="utf-8-sig"))["pairs"]
db = sqlite3.connect("file:../graph/sqlite/graph.db?mode=ro", uri=True)
db.row_factory = sqlite3.Row
got = {}
for p in cp:
    r = db.execute("SELECT match_status s,COUNT(*) n FROM price_observations WHERE "
                   "commodity_id=? AND product_name=? GROUP BY 1 ORDER BY 2 DESC",
                   (p["id"], p["product"])).fetchone()
    got[(p["id"], p["product"])] = r["s"] if r else None
A_pairs = [(r["query"], r["doc"]) for r in r1]
B_pairs = [(clean_product(p["product"]), commodity_text(defsg[p["id"]])) for p in cp]
MATCHED = ("llm_confirmed", "llm_match_unverified", "include_hit")


def evaluate(path):
    m = Matcher.load(with_reranker=True, reranker_path=path)
    s = [float(v) for v in m.rerank(A_pairs)]
    pos = [v for v, r in zip(s, r1) if r["label"] == 1]
    neg = [v for v, r in zip(s, r1) if r["label"] == 0]
    c = [float(v) for v in m.rerank(B_pairs)]
    f = [(p, v) for p, v in zip(cp, c) if v < 1e-4]
    del m
    import torch; torch.cuda.empty_cache()
    return {"auc": auc(pos, neg),
            "neg_caught": sum(1 for v in neg if v < 1e-4),
            "true_lost": sum(1 for v in pos if v < 1e-4),
            "filtered": len(f),
            "disagreed": sum(1 for p, _ in f if got[(p["id"], p["product"])] in MATCHED)}


rows = []
for arm, corpus in (("regex", "data/pair-corpus-r2"), ("adjudicated", "data/pair-corpus-r3")):
    for seed in SEEDS:
        d = os.path.join(SC, "models", f"tmp-{arm}-{seed}")
        t0 = time.time()
        subprocess.run([PY, os.path.join(SC, "finetune_reranker.py"), "--epochs", "2",
                        "--corpus", os.path.join(SC, corpus), "--out", d, "--seed", str(seed)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        r = evaluate(d)
        r.update(arm=arm, seed=seed, sec=round(time.time() - t0))
        rows.append(r)
        print(f"{arm:12s} seed {seed:<9} AUC {r['auc']:.4f}  neg {r['neg_caught']:3d}  "
              f"TRUE lost {r['true_lost']}  |  filtered {r['filtered']:2d}  DISAGREED {r['disagreed']}",
              flush=True)
        shutil.rmtree(d, ignore_errors=True)

json.dump(rows, open(OUT, "w", encoding="utf-8"), indent=1)
print(f"\nwrote {OUT}")
