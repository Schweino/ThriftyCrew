"""Seed the evaluation gold set from the estate's own adjudicated rulings.

    python graph/gold/seed_gold.py

The plan (§12 Phase 1) requires a gold set before any automation is trusted. This
repo already contains years of adjudicated judgment; building the gold set by
hand from scratch would both waste that and risk contradicting it. So the seed
comes from rows a human or agent ALREADY ruled on, with written evidence:

  NEGATIVES  grocery/known-wrong.json      — adjudicated "this product is NOT this
                                             commodity", each with evidence prose.
                                             The highest-value rows in the estate.
  POSITIVES  grocery/product-urls.json     — per-commodity, per-store product links
                                             that were verified against the shelf.
                                             `verified:` rows are the strongest.
  CONSTRAINTS commodity-dupe-allowlist.json— reviewed near-duplicate commodity pairs
                                             ruled genuinely DIFFERENT purchases.

Output: graph/gold/gold.jsonl, one labelled case per line.

A gold case is a JUDGEMENT, not a snapshot: it records that a given product name
either is or is not an instance of a commodity. It stays valid as prices change.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

from graphdb import read_json, REPO_ROOT          # noqa: E402
from ids import commodity_id, hash_obj            # noqa: E402

GOLD_DIR = os.path.dirname(os.path.abspath(__file__))
GOLD_PATH = os.path.join(GOLD_DIR, "gold.jsonl")
GROCERY = os.path.join(REPO_ROOT, "grocery")


def case(kind: str, commodity: str, product: str, label: str, source: str,
         store: str | None = None, evidence: str | None = None,
         namespace: str = "staple") -> dict:
    c = {
        "kind": kind,                 # match | do_not_merge
        "commodity": commodity,
        "commodity_node": commodity_id(commodity, namespace),
        "product": product,
        "store": store,
        "label": label,               # MATCH | NO_MATCH | DIFFERENT
        "source": source,
        "evidence": (evidence or "")[:500],
    }
    c["id"] = "gold:" + hash_obj([kind, commodity, product, store])[:20]
    return c


def from_known_wrong() -> list[dict]:
    path = os.path.join(GROCERY, "known-wrong.json")
    if not os.path.exists(path):
        return []
    data = read_json(path)
    out = []
    for e in data.get("entries", []):
        commodity, store = e.get("commodity"), e.get("store")
        if not commodity:
            continue
        for nm in e.get("names") or []:
            if nm:
                out.append(case("match", commodity, nm, "NO_MATCH",
                                "known-wrong.json", store, e.get("evidence")))
    return out


def from_product_urls(verified_only: bool = False) -> list[dict]:
    path = os.path.join(GROCERY, "product-urls.json")
    if not os.path.exists(path):
        return []
    data = read_json(path)
    out = []
    for cid, entry in (data.get("items") or {}).items():
        for store, v in entry.items():
            if store == "commodity" or not isinstance(v, dict):
                continue
            name = v.get("name")
            if not name:
                continue
            if verified_only and not v.get("verified"):
                continue
            ev = ("verified against shelf on " + v["verified"]) if v.get("verified") \
                else "curated per-commodity store product link"
            out.append(case("match", cid, name, "MATCH", "product-urls.json", store, ev))
    return out


def from_escalation_review() -> list[dict]:
    """Cases the confirm-match review lane ruled (review_escalations.py). They
    are stored pre-built in the seeder's own format; without this merge, every
    rebuild would silently erase the reviewer's labelled judgements."""
    path = os.path.join(GOLD_DIR, "escalation-review.jsonl")
    if not os.path.exists(path):
        return []
    with io.open(path, encoding="utf-8") as fh:
        return [json.loads(l) for l in fh if l.strip()]


def from_dupe_allowlist() -> list[dict]:
    path = os.path.join(GROCERY, "commodity-dupe-allowlist.json")
    if not os.path.exists(path):
        return []
    data = read_json(path)
    out = []
    for p in data.get("allow", []):
        a, b = p.get("a"), p.get("b")
        if a and b:
            out.append(case("do_not_merge", a, b, "DIFFERENT",
                            "commodity-dupe-allowlist.json", None, p.get("reason")))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verified-only", action="store_true",
                    help="positives only from shelf-verified product-urls rows")
    ap.add_argument("--max-positives", type=int, default=400,
                    help="cap positives so the set stays balanced and hand-auditable")
    args = ap.parse_args()

    neg = from_known_wrong()
    pos = from_product_urls(args.verified_only)
    dnm = from_dupe_allowlist()
    rev = from_escalation_review()

    # Balance: an evaluation dominated by easy positives hides false merges, which
    # are the error type this system most needs to see.
    if args.max_positives and len(pos) > args.max_positives:
        step = len(pos) / args.max_positives
        pos = [pos[int(i * step)] for i in range(args.max_positives)]

    cases, seen = [], set()
    for c in neg + rev + pos + dnm:
        if c["id"] in seen:
            continue
        seen.add(c["id"])
        cases.append(c)

    with io.open(GOLD_PATH, "w", encoding="utf-8", newline="\n") as fh:
        for c in cases:
            fh.write(json.dumps(c, ensure_ascii=False, sort_keys=True) + "\n")

    stores = {c["store"] for c in cases if c.get("store")}
    print(f"wrote {GOLD_PATH}")
    print(f"  total cases : {len(cases)}")
    print(f"  NO_MATCH    : {sum(1 for c in cases if c['label']=='NO_MATCH')}")
    print(f"  MATCH       : {sum(1 for c in cases if c['label']=='MATCH')}")
    print(f"  DIFFERENT   : {sum(1 for c in cases if c['label']=='DIFFERENT')}")
    print(f"  stores      : {len(stores)}  {sorted(stores)}")
    print(f"  commodities : {len({c['commodity'] for c in cases})}")
    return 0


def load_gold(path: str = GOLD_PATH) -> list[dict]:
    if not os.path.exists(path):
        return []
    with io.open(path, encoding="utf-8") as fh:
        return [json.loads(l) for l in fh if l.strip()]


if __name__ == "__main__":
    raise SystemExit(main())
