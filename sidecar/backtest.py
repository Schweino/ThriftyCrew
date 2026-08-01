"""
backtest.py - the ACCEPTANCE GATE for the semantic sidecar.

The design doc says: do not wire anything in until it is scored against defects the estate already knows
about. This is that score. It answers three questions, and it is allowed to fail.

  TASK A - IDENTITY (does it catch wrong products?)
      Rank the 25 adjudicated-wrong (product, commodity) pairs against the 2,816 pairs the board
      currently ships. A useful detector puts the known-wrong ones in the bottom tail. Reported as
      AUC plus recall at a false-positive budget the arrivals desk can actually absorb.

  TASK B - NOISE (can a human live with it?)
      At the operating threshold, how many ACCEPTED board pairs get flagged? Anything much over ~30/day
      is a guard nobody will read, which is worse than no guard (see the link-drift alert that fired
      daily on unfixable cells until it was fixed on 2026-08-01).

  TASK C - DISCOVERY (does it find gaps regex cannot see?) <- the one that matters most
      Using the PRE-widening commodities.json from git, replay yesterday's blind spot: 3,404 products
      that matched NO rule. Does the sidecar surface the 12 inverted-name misses (Cloves Ground, Ginger
      Ground, Red Pepper Crushed, Garlic Minced, ...) near the top? Those cost a $45 jar on the live
      board. If it finds them without anyone writing a pattern, that is the whole thesis proved.

Nothing here writes to the board, the feeds, or any rule. Output is a report.
"""
from __future__ import annotations
import json, os, sys, time
from collections import defaultdict

import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib_match import Matcher, clean_product, commodity_text, load_json, calibrate, DEVICE

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
OUT = os.path.join(HERE, "out")
os.makedirs(OUT, exist_ok=True)


def log(m: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def auc(pos: list[float], neg: list[float]) -> float:
    """P(a random accepted pair scores above a random known-wrong pair). 0.5 = coin flip."""
    if not pos or not neg:
        return float("nan")
    allv = sorted([(v, 0) for v in neg] + [(v, 1) for v in pos])
    ranks: dict[int, float] = {}
    i = 0
    r = 1
    while i < len(allv):
        j = i
        while j + 1 < len(allv) and allv[j + 1][0] == allv[i][0]:
            j += 1
        avg = (r + (r + (j - i))) / 2.0
        for k in range(i, j + 1):
            ranks[k] = avg
        r += (j - i + 1)
        i = j + 1
    sr = sum(ranks[k] for k in range(len(allv)) if allv[k][1] == 1)
    n1, n0 = len(pos), len(neg)
    return (sr - n1 * (n1 + 1) / 2.0) / (n1 * n0)


def main() -> None:
    log(f"device={DEVICE} torch={torch.__version__}")
    positives = load_json(os.path.join(DATA, "positives.json"))
    negatives = load_json(os.path.join(DATA, "negatives.json"))
    defs = load_json(os.path.join(DATA, "commodity-defs.json"))
    log(f"positives={len(positives)} hard-negatives={len(negatives)} commodities={len(defs)}")

    m = Matcher.load(with_reranker=True)
    log("models loaded")

    defs_by_id = {d["id"]: d for d in defs}
    cids = [d["id"] for d in defs]
    ctexts = [commodity_text(d) for d in defs]

    t0 = time.time()
    cvecs = m.embed(ctexts)
    log(f"embedded {len(ctexts)} commodity definitions in {time.time()-t0:.1f}s")

    # ---------------- TASK A + B ----------------
    # Score every accepted pair and every known-wrong pair with the SAME function, so the comparison is
    # apples to apples. Bi-encoder cosine first, then cross-encoder on the same pairs.
    all_pairs = [(p["id"], clean_product(p["product"]), "pos", p) for p in positives] + \
                [(n["id"], clean_product(n["product"]), "neg", n) for n in negatives]
    all_pairs = [p for p in all_pairs if p[0] in defs_by_id]
    prods = [p[1] for p in all_pairs]
    t0 = time.time()
    pvecs = m.embed(prods)
    log(f"embedded {len(prods)} product names in {time.time()-t0:.1f}s "
        f"({len(prods)/max(1e-9,(time.time()-t0)):.0f}/s)")

    cidx = {c: i for i, c in enumerate(cids)}
    cos = torch.tensor([
        float(torch.dot(pvecs[i], cvecs[cidx[all_pairs[i][0]]]))
        for i in range(len(all_pairs))
    ])

    t0 = time.time()
    ce_pairs = [(all_pairs[i][1], commodity_text(defs_by_id[all_pairs[i][0]])) for i in range(len(all_pairs))]
    ce = m.rerank(ce_pairs)
    log(f"cross-encoded {len(ce_pairs)} pairs in {time.time()-t0:.1f}s")

    pos_cos = [float(cos[i]) for i in range(len(all_pairs)) if all_pairs[i][2] == "pos"]
    neg_cos = [float(cos[i]) for i in range(len(all_pairs)) if all_pairs[i][2] == "neg"]
    pos_ce = [ce[i] for i in range(len(all_pairs)) if all_pairs[i][2] == "pos"]
    neg_ce = [ce[i] for i in range(len(all_pairs)) if all_pairs[i][2] == "neg"]

    auc_cos = auc(pos_cos, neg_cos)
    auc_ce = auc(pos_ce, neg_ce)
    log(f"TASK A  AUC bi-encoder={auc_cos:.3f}  AUC cross-encoder={auc_ce:.3f}")

    # operating point: flag the worst N accepted pairs per day; measure recall of known-wrong there
    results_a = {}
    for budget in (10, 20, 30, 50, 100):
        thr = sorted(pos_ce)[min(len(pos_ce) - 1, budget)]
        caught = sum(1 for v in neg_ce if v <= thr)
        results_a[budget] = {
            "threshold": thr,
            "known_wrong_caught": caught,
            "known_wrong_total": len(neg_ce),
            "recall": caught / max(1, len(neg_ce)),
            "accepted_flagged": budget,
        }
        log(f"  budget {budget:>3} accepted-pairs flagged/day -> catches {caught}/{len(neg_ce)} known-wrong "
            f"({caught/max(1,len(neg_ce)):.0%})")

    # ---------------- TASK C ----------------
    # Replay the blind spot. Only products that matched NO pre-widening rule are eligible, which is
    # exactly the pool a coverage gap hides in.
    corpus = load_json(os.path.join(DATA, "corpus-prewiden.json"))
    unmatched = [r for r in corpus if not r.get("rule_match")]
    log(f"TASK C  replaying pre-widening blind spot: {len(unmatched)} products matched no rule")

    targets = {
        "ground-cloves": ["cloves"],
        "ground-ginger": ["ginger"],
        "red-pepper-flakes": ["red pepper"],
        "onion-powder": ["onion"],
        "garlic-powder": ["garlic"],
        "minced-garlic": ["garlic"],
    }
    unames = [clean_product(r["product"]) for r in unmatched]
    t0 = time.time()
    uvecs = m.embed(unames)
    log(f"embedded {len(unames)} unmatched products in {time.time()-t0:.1f}s")

    task_c = {}
    for cid in targets:
        if cid not in cidx:
            continue
        sims = torch.mv(uvecs, cvecs[cidx[cid]])
        k = min(25, len(sims))
        top = torch.topk(sims, k)
        rows = []
        for rank, (score, idx) in enumerate(zip(top.values.tolist(), top.indices.tolist()), 1):
            rows.append({
                "rank": rank, "score": round(score, 4),
                "store": unmatched[idx]["store"], "product": unmatched[idx]["product"],
            })
        task_c[cid] = rows
        hits = [r for r in rows if any(t in r["product"].lower() for t in targets[cid])]
        log(f"  {cid:<20} top-{k}: {len(hits)} plausible instance(s); best rank "
            f"{hits[0]['rank'] if hits else '-'}")

    report = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "device": DEVICE,
        "counts": {"positives": len(pos_ce), "hard_negatives": len(neg_ce), "commodities": len(defs),
                   "unmatched_prewiden": len(unmatched)},
        "task_a": {"auc_bi_encoder": auc_cos, "auc_cross_encoder": auc_ce, "operating_points": results_a},
        "task_c": task_c,
        "negatives_detail": [
            {"commodity": all_pairs[i][3]["commodity"], "store": all_pairs[i][3]["store"],
             "product": all_pairs[i][3]["product"], "cos": round(float(cos[i]), 4), "ce": round(ce[i], 4)}
            for i in range(len(all_pairs)) if all_pairs[i][2] == "neg"
        ],
    }
    with open(os.path.join(OUT, "backtest.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    log(f"wrote {os.path.join(OUT,'backtest.json')}")


if __name__ == "__main__":
    main()
