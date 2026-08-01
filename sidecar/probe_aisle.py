"""probe_aisle.py - measurement ONLY, before any gate is designed.

The question: does the reranker separate the four crown flips the FF catalogue browse got WRONG
(watermelon -> Hefty Fabuloso Watermelon trash bags, milk -> M&M's Peanut Milk Chocolate,
coffee -> International Delight Iced Mocha, butter -> Our Family Butter Beans) from the products
those commodities SHOULD hold? If the scores overlap, an aisle test cannot be built this way and
that has to be discovered here, not after a threshold is invented to fit.

Usage: python probe_aisle.py
"""
from __future__ import annotations
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from lib_match import Matcher, clean_product, commodity_text

DEFS = os.path.join(HERE, "data", "commodity-defs.json")

# (commodity_id, product, label) - label WRONG = the browse test's actual mistakes, RIGHT = a real product
CASES = [
    ("watermelon", "Hefty Fabuloso Scent Trash Bags, Watermelon", "WRONG"),
    ("watermelon", "Whole Seedless Watermelon", "RIGHT"),
    ("watermelon", "Fresh Cut Watermelon Chunks 16 oz", "RIGHT"),
    ("milk", "M&M's Peanut Milk Chocolate Candy 10 oz", "WRONG"),
    ("milk", "Our Family 2% Reduced Fat Milk, 1 Gallon", "RIGHT"),
    ("milk", "Hy-Vee Whole Milk Gallon", "RIGHT"),
    ("coffee", "International Delight Iced Mocha Coffee Creamer 32 fl oz", "WRONG"),
    ("coffee", "Folgers Classic Roast Ground Coffee 30.5 oz", "RIGHT"),
    ("coffee", "Our Family Colombian Ground Coffee 24.2 oz", "RIGHT"),
    ("butter", "Our Family Butter Beans 15.5 oz", "WRONG"),
    ("butter", "Our Family Salted Butter Quarters 16 oz", "RIGHT"),
    ("butter", "Land O Lakes Unsalted Butter 1 lb", "RIGHT"),
]


def main() -> int:
    if not os.path.exists(DEFS):
        print("BLIND: no commodity-defs.json - run audit-semantic-identity.ps1 -PrepareOnly first")
        return 3
    defs = {d["id"]: d for d in json.load(open(DEFS, encoding="utf-8-sig"))}
    missing = sorted({c for c, _, _ in CASES if c not in defs})
    if missing:
        print("commodity ids absent from defs (cannot probe): " + ", ".join(missing))
        return 3

    m = Matcher.load(with_reranker=True)
    pairs, meta = [], []
    for cid, prod, tag in CASES:
        pairs.append((clean_product(prod), commodity_text(defs[cid])))
        meta.append((cid, prod, tag))
    ce = m.rerank(pairs)

    # cosine too, so we can see whether the cheap stage alone would do
    prods = [clean_product(p) for _, p, _ in meta]
    cids = [c for c, _, _ in meta]
    pv = m.embed(prods)
    import torch
    cvs = {c: m.embed([commodity_text(defs[c])])[0] for c in set(cids)}
    cos = [float(torch.dot(pv[i], cvs[cids[i]])) for i in range(len(prods))]

    print(f"{'verdict':8} {'commodity':12} {'cos':>7} {'ce':>12}  product")
    rows = []
    for i, (cid, prod, tag) in enumerate(meta):
        rows.append((tag, cid, cos[i], ce[i], prod))
    for tag, cid, c, e, prod in sorted(rows, key=lambda r: (r[1], -r[3])):
        print(f"{tag:8} {cid:12} {c:7.4f} {e:12.6f}  {prod[:56]}")

    wrong = [r for r in rows if r[0] == "WRONG"]
    right = [r for r in rows if r[0] == "RIGHT"]
    wmax_ce, rmin_ce = max(r[3] for r in wrong), min(r[3] for r in right)
    wmax_cos, rmin_cos = max(r[2] for r in wrong), min(r[2] for r in right)
    print()
    print(f"CE  : worst-WRONG {wmax_ce:.6f}   best-case-floor RIGHT {rmin_ce:.6f}   separated={rmin_ce > wmax_ce}")
    print(f"COS : worst-WRONG {wmax_cos:.4f}   floor RIGHT {rmin_cos:.4f}   separated={rmin_cos > wmax_cos}")
    if rmin_ce > wmax_ce:
        print(f"-> a CE threshold anywhere in ({wmax_ce:.6f}, {rmin_ce:.6f}] catches all 4 founding failures")
    else:
        print("-> CE does NOT separate these. An aisle test cannot be a single CE threshold.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
