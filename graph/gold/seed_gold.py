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


def resolve_commodity_node(db, node_id: str, slug: str) -> str | None:
    """Map a gold case's commodity onto a real node, or None.

    The ladder, cheapest rung first:
      1. the node id as written
      2. the staple namespace
      3. the recipe namespace
      4. **IngredientMapping traversal** — the legacy boards key by slugs the
         graph never adopted (`penne-pasta`, `sriracha`, `93-7-ground-beef`),
         and IngredientMapping nodes carry exactly that slug as `board_id` with
         a `maps_to` edge to the real commodity. Without this rung those cases
         resolve to nothing and are SILENTLY SKIPPED at score time — 27 of them
         were, so the gold set was quietly 2% smaller than it reported.
      5. case-insensitive canonical-label match, as a last resort.
    """
    if db is None:
        return None
    for cand in (node_id, f"commodity:staple:{slug}", f"commodity:recipe:{slug}"):
        if cand and db.get_node(cand):
            return cand

    row = db.conn.execute(
        """SELECT e.target_id FROM nodes n
           JOIN edges e ON e.source_id = n.id AND e.predicate='maps_to'
           WHERE n.type='IngredientMapping'
             AND json_extract(n.properties_json, '$.board_id') = ?
           LIMIT 1""", (slug,)).fetchone()
    if row and db.get_node(row["target_id"]):
        return row["target_id"]

    row = db.conn.execute(
        """SELECT id FROM nodes WHERE type='Commodity'
           AND lower(canonical_name)=lower(?) LIMIT 1""",
        (slug.replace("-", " "),)).fetchone()
    return row["id"] if row else None


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
    ap.add_argument("--no-db", action="store_true",
                    help="skip commodity-node resolution (for a rebuild drill, "
                         "where the index is legitimately empty)")
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

    # Resolve every case's commodity to a real node, HERE, where a failure can be
    # reported — rather than at score time, where an unresolvable case is counted
    # as `missing_node` and silently dropped from both metrics.
    unresolved: list[dict] = []
    db = None
    if not args.no_db:
        try:
            sys.path.insert(0, os.path.join(GOLD_DIR, "..", "lib"))
            from graphdb import open_db
            db = open_db(create=False)
        except Exception as e:                                  # noqa: BLE001
            print(f"  (no graph index available: {e}; skipping node resolution)")
    if db is not None:
        try:
            for c in cases:
                if c["kind"] != "match":
                    continue
                node = resolve_commodity_node(db, c.get("commodity_node"), c["commodity"])
                if node:
                    c["commodity_node"] = node
                    c.pop("unresolved", None)
                else:
                    c["unresolved"] = True
                    unresolved.append(c)
        finally:
            db.close()

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

    if unresolved:
        # Loud on purpose. These cases are in the file but cannot be scored, so a
        # quiet count is how the set shrinks without anyone noticing.
        print(f"\n  *** {len(unresolved)} GOLD CASE(S) RESOLVE TO NO COMMODITY NODE ***")
        print("  They are stamped \"unresolved\": true and CANNOT BE SCORED. Each is a "
              "real catalog question")
        print("  (does this board price that food at all?) — minting an id is the "
              "commodity-registrar's call,")
        print("  not the seeder's. Residual list:")
        for c in sorted({x["commodity"] for x in unresolved}):
            print(f"      {c}")
    return 0


def load_gold(path: str = GOLD_PATH) -> list[dict]:
    if not os.path.exists(path):
        return []
    with io.open(path, encoding="utf-8") as fh:
        return [json.loads(l) for l in fh if l.strip()]


if __name__ == "__main__":
    raise SystemExit(main())
