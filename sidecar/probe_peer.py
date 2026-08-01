"""probe_peer.py - test the PEER-RELATIVE formulation, after the absolute one failed.

WHAT KILLED THE ABSOLUTE THRESHOLD
----------------------------------
Calibrating against 2,825 shipped board pairs showed the score distributions INTERLEAVE:

    0.000141  M&M's Peanut Milk Chocolate      <- WRONG (browse-test failure)
    0.000299  Our Family Butter Beans          <- WRONG
    0.000312  Wimmer's Wieners, Skinless       <- RIGHT, a real hot dog
    0.000318  Blue Diamond Mike's Hot Honey Almonds  <- RIGHT
    0.000365  International Delight Iced Mocha <- WRONG
    0.000983  Hefty Fabuloso Watermelon Trash Bags   <- WRONG

No global cut separates those. The reason is structural: a cross-encoder scores VOCABULARY OVERLAP with
the commodity's own words, so a regional brand name that shares none of them ("Wimmer's Wieners" for
hot-dogs) scores as low as a wrong product that shares one ("Butter Beans" for butter). The absolute score
is measuring name-transparency, not membership.

THE HYPOTHESIS HERE
-------------------
Membership is RELATIVE. Ask instead: how does this candidate score against the products ALREADY HOLDING
this commodity's cells at other stores? hot-dogs' whole cohort scores low (everyone's franks are branded),
so Wimmer's FITS its peers. watermelon's cohort scores ~0.7-0.97 (real watermelons are named "watermelon"),
so trash bags at 0.00098 sits ~1000x below its peers. Same idea as the identity lane's peer ratio.

If the ratio separates where the absolute score could not, the aisle test is a peer test.
"""
from __future__ import annotations
import json, os, sys, statistics

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from lib_match import Matcher, clean_product, commodity_text

DATA = os.path.join(HERE, "data")

CASES = [
    ("watermelon", "Hefty Fabuloso Scent Trash Bags, Watermelon", "WRONG"),
    ("milk", "M&M's Peanut Milk Chocolate Candy 10 oz", "WRONG"),
    ("coffee", "International Delight Iced Mocha Coffee Creamer 32 fl oz", "WRONG"),
    ("butter", "Our Family Butter Beans 15.5 oz", "WRONG"),
    # the hard positives the absolute threshold would have refused - these MUST pass
    ("hot-dogs", "Wimmer's Wieners, Skinless 24 Oz", "RIGHT"),
    ("almonds", "Blue Diamond Mike's Hot Honey Almonds", "RIGHT"),
    ("mayonnaise", "Our Family Mayo, Real 30 Fl Oz", "RIGHT"),
    ("bananas", "Yellow Bananas", "RIGHT"),
    ("cilantro", "Fresh Cut Cilantro Clamshell", "RIGHT"),
    ("cereal", "Hy Vee Whole Grain Raisin Bran", "RIGHT"),
    ("carrots", "Dole Carrots, Mini Cut", "RIGHT"),
    ("coffee-creamer", "Planet Oat Brown Sugar Cookie Oatmilk Creamer 32 Fl Oz", "RIGHT"),
]


def main() -> int:
    defs = {d["id"]: d for d in json.load(open(os.path.join(DATA, "commodity-defs.json"), encoding="utf-8-sig"))}
    pairs = json.load(open(os.path.join(DATA, "board-pairs.json"), encoding="utf-8-sig"))
    cal = os.path.join(DATA, "aisle-calibration.json")

    # cohort = the products already holding this commodity's cells
    cohort: dict[str, list[str]] = {}
    for r in pairs:
        cid = str(r.get("id") or r.get("commodity") or "")
        prod = str(r.get("product") or r.get("item") or "")
        if cid and prod:
            cohort.setdefault(cid, []).append(prod)

    m = Matcher.load(with_reranker=True)

    need = sorted({c for c, _, _ in CASES})
    missing = [c for c in need if c not in defs]
    if missing:
        print("no def for: " + ", ".join(missing))
        return 3

    print(f"{'verdict':8} {'commodity':16} {'cand ce':>11} {'peers':>5} {'peer med':>11} {'ratio':>9}")
    rows = []
    for cid, prod, tag in CASES:
        peers = [p for p in cohort.get(cid, []) if p]
        ctext = commodity_text(defs[cid])
        # exclude the candidate itself from its own cohort
        peers = [p for p in peers if p.strip().lower() != prod.strip().lower()]
        if not peers:
            print(f"{tag:8} {cid:16}  (no peers - cannot judge relatively)")
            continue
        scored = m.rerank([(clean_product(p), ctext) for p in peers])
        med = statistics.median(scored)
        cand = m.rerank([(clean_product(prod), ctext)])[0]
        ratio = (cand / med) if med > 0 else 0.0
        rows.append((tag, cid, cand, len(peers), med, ratio))
        print(f"{tag:8} {cid:16} {cand:11.8f} {len(peers):5d} {med:11.8f} {ratio:9.4f}")

    wrong = [r for r in rows if r[0] == "WRONG"]
    right = [r for r in rows if r[0] == "RIGHT"]
    if wrong and right:
        wmax, rmin = max(r[5] for r in wrong), min(r[5] for r in right)
        print()
        print(f"RATIO: worst-WRONG {wmax:.6f}   floor-RIGHT {rmin:.6f}   separated={rmin > wmax}")
        if rmin > wmax:
            print(f"-> a peer-ratio threshold in ({wmax:.6f}, {rmin:.6f}] separates BOTH the four failures")
            print("   AND the hard positives the absolute score could not.")
        else:
            print("-> the peer ratio does NOT separate either. Report that; do not tune until it does.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
