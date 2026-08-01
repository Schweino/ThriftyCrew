"""aisle.py - the aisle test: does this product actually BELONG to this commodity?

WHY THIS EXISTS
---------------
Family Fare's shallow search feed has been doing double duty as an accidental RELEVANCE FILTER. Browsing
the full catalogue is cheap (18,441 products, 185 requests) but simulated through the real matcher it flips
26 cheapest-store verdicts, about two thirds to the WRONG product: watermelon -> Hefty Fabuloso Watermelon
TRASH BAGS, milk -> M&M's Peanut MILK Chocolate, coffee -> International Delight Iced Mocha CREAMER,
butter -> Our Family BUTTER BEANS. Every one of those shares a word with the commodity, which is exactly
why regex could not catch them: `audit-food-category` caught 0 of 26 and `audit-store-taxonomy` caught 3.

So depth is only safe behind a per-commodity relevance test, and this is it.

WHAT IT SCORES ON, AND WHY NOT COSINE
-------------------------------------
Measured on the four founding failures against real products for the same commodities:

    CE  : worst WRONG 0.000983   floor RIGHT 0.004334   -> separated, 4.4x margin
    COS : worst WRONG 0.5066     floor RIGHT 0.5094     -> "separated" by 0.6%, which is noise

The bi-encoder alone would NOT be a safe gate; the cross-encoder is the discriminator. That is the whole
reason this pays the reranker's cost instead of using the cheap stage.

ADVISORY, AND BLIND-NEVER-BLOCK: this returns scores. It never writes a price, a crown, a rule or a link.
A caller that cannot reach it must treat the answer as could-not-evaluate and NOT flip the crown - refusing
a flip is the safe direction here, because the flip is the change and today's board is the known state.

Modes:
  --calibrate         score every shipped board pair; print the CE distribution (operating-point evidence)
  --score <in> <out>  score candidate flips [{id,store,product}] -> adds cos/ce to each
"""
from __future__ import annotations
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from lib_match import Matcher, clean_product, commodity_text

DATA = os.path.join(HERE, "data")
DEFS = os.path.join(DATA, "commodity-defs.json")
PAIRS = os.path.join(DATA, "board-pairs.json")


def _load_defs() -> dict:
    return {d["id"]: d for d in json.load(open(DEFS, encoding="utf-8-sig"))}


def _score(m: Matcher, defs: dict, rows: list) -> list:
    """rows: [{id, product, ...}] -> same rows with cos + ce added. Rows whose commodity has no def are
    marked scorable=False rather than dropped: a silently shorter list is how a gate stops covering things."""
    out, pairs, idx = [], [], []
    for r in rows:
        cid = str(r.get("id") or r.get("commodity") or "")
        prod = str(r.get("product") or r.get("item") or "")
        rec = dict(r)
        rec["id"] = cid
        rec["product"] = prod
        if cid not in defs or not prod:
            rec["scorable"] = False
            rec["cos"] = None
            rec["ce"] = None
        else:
            rec["scorable"] = True
            idx.append(len(out))
            pairs.append((clean_product(prod), commodity_text(defs[cid]), cid))
        out.append(rec)

    if pairs:
        import torch
        prods = [p for p, _, _ in pairs]
        pv = m.embed(prods)
        cvs = {}
        for _, ctext, cid in pairs:
            if cid not in cvs:
                cvs[cid] = m.embed([ctext])[0]
        cos = [float(torch.dot(pv[i], cvs[pairs[i][2]])) for i in range(len(pairs))]
        ce = m.rerank([(p, c) for p, c, _ in pairs])
        for k, i in enumerate(idx):
            out[i]["cos"] = round(cos[k], 4)
            out[i]["ce"] = round(float(ce[k]), 8)
    return out


def calibrate() -> int:
    """Score what we ALREADY SHIP. These are the positives at scale: products the rules matched and that
    reached a live board. The threshold question is not 'does it catch the four' - it is 'how much real
    shipped product would it also refuse', because every refusal is depth we do not get."""
    if not (os.path.exists(DEFS) and os.path.exists(PAIRS)):
        print("BLIND: run audit-semantic-identity.ps1 -PrepareOnly first")
        return 3
    defs = _load_defs()
    rows = json.load(open(PAIRS, encoding="utf-8-sig"))
    m = Matcher.load(with_reranker=True)
    scored = _score(m, defs, rows)
    ok = [r for r in scored if r["scorable"]]
    unscorable = len(scored) - len(ok)
    ce = sorted(r["ce"] for r in ok)
    n = len(ce)
    if not n:
        print("no scorable board pairs")
        return 3

    def pct(p: float) -> float:
        return ce[min(n - 1, int(n * p))]

    print(f"scored {n} shipped board pair(s); {unscorable} unscorable (no commodity def)")
    print("CE percentiles across products we ALREADY SHIP:")
    for p in (0.001, 0.005, 0.01, 0.02, 0.05, 0.10, 0.25, 0.50):
        print(f"   p{p*100:<6.1f} {pct(p):.8f}")
    print()
    print("share of SHIPPED product that a given threshold would refuse:")
    for t in (0.0005, 0.001, 0.002, 0.004, 0.01, 0.05):
        below = sum(1 for v in ce if v < t)
        print(f"   thr {t:<8} refuses {below:5d} / {n}  ({below/n*100:5.2f}%)")
    out = os.path.join(DATA, "aisle-calibration.json")
    json.dump({"n": n, "unscorable": unscorable,
               "percentiles": {str(p): pct(p) for p in (0.001, 0.005, 0.01, 0.02, 0.05, 0.10, 0.25, 0.50)},
               "worst": [{"id": r["id"], "product": r["product"], "ce": r["ce"]}
                         for r in sorted(ok, key=lambda r: r["ce"])[:40]]},
              open(out, "w", encoding="utf-8"), indent=1)
    print(f"-> {out}")
    return 0


def score_file(inp: str, outp: str) -> int:
    if not os.path.exists(DEFS):
        print("BLIND: no commodity-defs.json")
        return 3
    defs = _load_defs()
    rows = json.load(open(inp, encoding="utf-8-sig"))
    if isinstance(rows, dict):
        rows = rows.get("candidates") or rows.get("rows") or []
    m = Matcher.load(with_reranker=True)
    scored = _score(m, defs, rows)
    json.dump(scored, open(outp, "w", encoding="utf-8"), indent=1)
    print(f"scored {len(scored)} candidate(s) -> {outp}")
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "--calibrate":
        raise SystemExit(calibrate())
    if len(a) >= 3 and a[0] == "--score":
        raise SystemExit(score_file(a[1], a[2]))
    print(__doc__)
    raise SystemExit(2)
