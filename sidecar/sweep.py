"""
sweep.py - the nightly GPU batch. Reads a corpus prepared by the PowerShell side, writes ranked
advisory findings. It does the scoring and NOTHING else.

DIVISION OF LABOUR (deliberate)
-------------------------------
PowerShell owns which products exist and which rules match them, because that regex must stay
byte-identical to what the pricing engine does; a second copy in Python is exactly the
two-implementations bug this estate keeps getting bitten by (pu-lib had three, the category-exclude
bake drifted 2,165 patterns, the record tooltips carried a second price formatter). Python owns the
GPU maths. Neither reimplements the other.

TWO LANES, both advisory:

  IDENTITY  - for every (product, commodity) pair the board ships, how well does the product actually
              match what the commodity means? Low scores are candidate wrong-crowns. This is the
              bath-soap-as-coconut-oil class, which no price check can catch.

  COVERAGE  - for every product NO rule matches, which commodity does it look like? High scores are
              candidate blind spots. This is the "Cloves, Ground" class: the right product sitting in
              the feed, invisible, while a $45 jar wins the cell unopposed.

Output: out/semantic-findings.json. Nothing else is written, and nothing is applied.
"""
from __future__ import annotations
import json, os, sys, time

import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib_match import Matcher, clean_product, commodity_text, load_json, DEVICE, EMBED_MODEL, RERANK_MODEL
import score_cache

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
OUT = os.path.join(HERE, "out")
CACHE = os.path.join(OUT, "embed-cache")
os.makedirs(OUT, exist_ok=True)

# Operating points from the Phase 1 backtest (backtest-report.md). IDENTITY_KEEP is the 100/2816
# threshold that caught 24 of 24 identity defects; COVERAGE_MIN is set where Task C's true positives
# sat (the cloves/ginger/red-pepper hits scored 0.58-0.69 on cosine).
# A shipped pair is suspicious when it scores far BELOW its own commodity's median, not below a global
# bar. 0.10 = "less than a tenth as good a match as this commodity's typical accepted product".
IDENTITY_PEER_RATIO = 0.10
COVERAGE_COS_FLOOR = 0.55        # bi-encoder cosine; cheap prefilter, NOT the decision
# The coverage floor was set on evidence, not taste. The first full sweep at 0.05 returned 1,404 rows,
# which is a firehose nobody reads, and a guard nobody reads is worse than no guard (see the link-drift
# alert that fired daily on unfixable cells until 2026-08-01). Sampling the bands:
#   >=0.95 -> 35 rows, nearly all real     >=0.90 -> 89 rows, still nearly all real
#   >=0.80 -> 163, mixed                   >=0.20 -> 843, mostly near-misses the rules correctly reject
# 0.90 keeps the real gaps (La Costena "Jalapeno Peppers, Pickled", Hormel "Corned Beef, Hash" - both the
# same inverted-name shape that cost a live cell) while dropping the Tide-liquid-for-detergent-PODS class
# of near miss. Findings also cluster hard by commodity (12 of the 89 are one detergent), so the report
# groups them: a human reviews "this commodity is missing 12 products" once, not twelve times.
COVERAGE_RERANK_FLOOR = 0.90


def log(m: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def main() -> None:
    t_start = time.time()
    defs = load_json(os.path.join(DATA, "commodity-defs.json"))
    pairs = load_json(os.path.join(DATA, "board-pairs.json"))
    corpus = load_json(os.path.join(DATA, "corpus-current.json"))
    log(f"device={DEVICE} commodities={len(defs)} board-pairs={len(pairs)} corpus={len(corpus)}")

    # SCORE CACHE (2026-08-22). Both model answers are pure functions of (model id, exact text), so they
    # are memoised on disk in out/embed-cache and only the texts this run has never seen reach the card.
    # A model is loaded lazily, on the first miss that needs it: a run on an unchanged shelf loads
    # neither and finishes in a few seconds instead of ~46 s, with a byte-identical findings file
    # (modulo generated/elapsed). See score_cache.py. SWEEP_CACHE=0 forces a cold, uncached run.
    if score_cache.enabled():
        m = score_cache.CachedScorer(
            CACHE, DEVICE,
            embed_factory=lambda: Matcher.load(with_reranker=False),
            rerank_factory=Matcher.load_reranker_only,
            embed_model=EMBED_MODEL, rerank_model=RERANK_MODEL)
    else:
        m = Matcher.load(with_reranker=True)
    defs_by_id = {d["id"]: d for d in defs}
    cids = [d["id"] for d in defs]
    cidx = {c: i for i, c in enumerate(cids)}
    ctexts = [commodity_text(d) for d in defs]
    cvecs = m.embed(ctexts)
    log(f"embedded {len(ctexts)} commodity definitions")

    # ---------------- LANE 1: IDENTITY ----------------
    pairs = [p for p in pairs if p["id"] in defs_by_id]
    pnames = [clean_product(p["product"]) for p in pairs]
    t0 = time.time()
    pvecs = m.embed(pnames)
    log(f"embedded {len(pnames)} shipped product names in {time.time()-t0:.1f}s")
    cos = torch.tensor([float(torch.dot(pvecs[i], cvecs[cidx[pairs[i]['id']]])) for i in range(len(pairs))])
    # Cross-encode only the weakest tail. Reranking all 2,816 costs 12 s and tells us nothing new about
    # the pairs that already look obviously right; the decision only ever concerns the bottom.
    # Rerank EVERY shipped pair, because the decision below is relative and needs the whole distribution.
    # 2,816 pairs costs about twelve seconds, which is nothing against getting the judgement right.
    ce_all = m.rerank([(pnames[i], ctexts[cidx[pairs[i]["id"]]]) for i in range(len(pairs))])

    # RELATIVE, NOT ABSOLUTE. The first full sweep used a global floor and flagged "Yellow Bananas" as a
    # suspicious instance of Bananas, alongside "Kroger Thin Spaghetti" for Pasta - all correct pairs.
    # The cause is not the model being wrong, it is the question being wrong: short generic product names
    # score low against every commodity, so an absolute bar just selects for short names.
    # The honest question is the one the basis-outlier audit asks about price: is this cell an outlier
    # AMONG ITS OWN PEERS? If all six banana products score 0.001, that is the commodity's baseline. If
    # five coconut-oil products score 0.9 and a bath soap scores 0.02, THAT is a defect.
    by_com: dict[str, list[int]] = {}
    for i, p in enumerate(pairs):
        by_com.setdefault(p["id"], []).append(i)
    identity = []
    for cid, idxs in by_com.items():
        if len(idxs) < 3:
            continue  # too few peers for a median to mean anything; silence beats a guess
        vals = sorted(ce_all[i] for i in idxs)
        med = vals[len(vals) // 2]
        if med < 0.05:
            continue  # the whole commodity scores low (short names): no peer signal to use
        for i in idxs:
            if ce_all[i] >= med * IDENTITY_PEER_RATIO:
                continue
            identity.append({
                "kind": "identity", "id": cid, "commodity": pairs[i]["commodity"],
                "store": pairs[i]["store"], "product": pairs[i]["product"],
                "cos": round(float(cos[i]), 4), "score": round(ce_all[i], 6),
                "peer_median": round(med, 4),
                "why": "shipped on the board but reads as a far poorer instance of this commodity than the same commodity's other stores",
            })
    identity.sort(key=lambda r: r["score"] / max(1e-9, r["peer_median"]))
    log(f"LANE identity: {len(identity)} shipped pair(s) below the floor")

    # ---------------- LANE 2: COVERAGE ----------------
    unmatched = [r for r in corpus if not r.get("rule_match")]
    log(f"LANE coverage: {len(unmatched)} products match no rule")
    unames = [clean_product(r["product"]) for r in unmatched]
    t0 = time.time()
    uvecs = m.embed(unames)
    log(f"embedded {len(unames)} rule-invisible products in {time.time()-t0:.1f}s")

    # best commodity per unmatched product, in chunks so VRAM stays bounded
    best_score = torch.full((len(unames),), -1.0)
    best_idx = torch.zeros(len(unames), dtype=torch.long)
    CH = 4096
    for s in range(0, len(unames), CH):
        blk = uvecs[s:s + CH] @ cvecs.T          # (chunk, commodities)
        v, a = torch.max(blk, dim=1)
        best_score[s:s + CH] = v.cpu()
        best_idx[s:s + CH] = a.cpu()
    cand = [i for i in range(len(unames)) if float(best_score[i]) >= COVERAGE_COS_FLOOR]
    log(f"  {len(cand)} candidate(s) above the cosine floor; cross-encoding")
    coverage = []
    if cand:
        ce2 = m.rerank([(unames[i], ctexts[int(best_idx[i])]) for i in cand])
        for k, i in enumerate(cand):
            if ce2[k] < COVERAGE_RERANK_FLOOR:
                continue
            cid = cids[int(best_idx[i])]
            coverage.append({
                "kind": "coverage", "id": cid, "commodity": defs_by_id[cid]["label"],
                "store": unmatched[i]["store"], "product": unmatched[i]["product"],
                "cos": round(float(best_score[i]), 4), "score": round(ce2[k], 6),
                "why": "no rule matches it, but it reads as an instance of this commodity",
            })
    coverage.sort(key=lambda r: -r["score"])
    log(f"LANE coverage: {len(coverage)} rule-invisible product(s) that look real")

    report = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "device": DEVICE,
        "elapsed_sec": round(time.time() - t_start, 1),
        "thresholds": {
            "identity_peer_ratio": IDENTITY_PEER_RATIO,
            "coverage_cos_floor": COVERAGE_COS_FLOOR,
            "coverage_rerank_floor": COVERAGE_RERANK_FLOOR,
        },
        "examined": {"board_pairs": len(pairs), "corpus": len(corpus), "rule_invisible": len(unmatched)},
        "identity": identity,
        "coverage": coverage,
    }
    if isinstance(m, score_cache.CachedScorer):
        m.save()
        report["cache"] = m.stats()
        log(f"cache: {report['cache']}")
    p = os.path.join(OUT, "semantic-findings.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    log(f"wrote {p}  ({len(identity)} identity + {len(coverage)} coverage) in {report['elapsed_sec']}s")


if __name__ == "__main__":
    main()
