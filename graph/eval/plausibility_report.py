"""Crown plausibility — ask, generically, "is this product really this food?"

    python graph/eval/plausibility_report.py --limit 200        # shadow report
    python graph/eval/plausibility_report.py --all --json

SHADOW ONLY. This reports; it gates nothing. Precision has to be measured before
an unproven checker is ever allowed to block a publish, because a checker that
blocks good cells is its own outage.

WHY IT EXISTS. The estate already has three defences, and a blueberry jam still
reached the live board priced as habanero peppers on 2026-08-20:

  known-wrong        only catches what a human ALREADY ruled on. Retrospective
                     by construction: it cannot catch a first occurrence.
  category-excludes  class-level guardrails ("no beverages in Fruit"). Powerful,
                     but only for classes somebody thought to write down.
  per-commodity regex  the include/exclude lists. The jam slipped because the
                     exclude said \\bjam\\b and the product said "Jams".

Every one of those needs the specific failure to have been ANTICIPATED. None of
them ever asks the general question a person would ask in one glance: *does this
product name actually denote this food?* That is the gap this fills, and a local
model answers it for free.

It runs ONLY on crown-holders — the row that actually prices a cell — because
that is the only row a shopper can be misled by. Roughly 3,000 calls, not 119,000.

BIAS. The model is asked to answer IMPLAUSIBLE only when it is confident, and to
say UNSURE otherwise. A false alarm here costs a human a few seconds; a miss
costs a wrong published price. But an alarm that cries wolf gets ignored, which
is why precision is measured first and the report leads with it.
"""

from __future__ import annotations

import argparse
import collections
import io
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

from graphdb import open_db                                  # noqa: E402
from llm import LocalLLM                                     # noqa: E402
from units import per_unit, reconcile_unit                   # noqa: E402

OUT = os.path.join(HERE, "plausibility-findings.jsonl")

SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["verdict", "confidence", "reason"],
    "properties": {
        "verdict": {"type": "string", "enum": ["PLAUSIBLE", "IMPLAUSIBLE", "UNSURE"]},
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "reason": {"type": "string"},
    },
}

SYSTEM = (
    "You check a grocery price board for ONE specific failure: a product that is "
    "not really the item it is being sold as, pricing that item's row.\n\n"
    "You are shown a COMMODITY the board tracks and the PRODUCT whose price is "
    "currently published for it. Answer whether that product genuinely IS that item.\n\n"
    "THE BOARD IS NOT ONLY FOOD. It tracks household and personal-care goods too "
    "-- all-purpose cleaner, bar soap, shampoo, toilet paper, pet food. A cleaning "
    "product priced under a cleaning-product commodity is completely correct. "
    "Never flag something merely for not being edible.\n\n"
    "PLAUSIBLE covers all of these -- do not flag them:\n"
    "  - any brand, store brand or generic version\n"
    "  - any package size, count or format (bag, clamshell, can, frozen, jar, refill)\n"
    "  - organic/conventional, and ordinary descriptors (fresh, jumbo, large, value)\n"
    "  - a cut or variety of the same item when the commodity does not name one\n"
    "  - a DIFFERENT TRADE NAME for the same product. Neufchatel IS reduced-fat "
    "    (1/3-less-fat) cream cheese; scallions are green onions; garbanzo beans "
    "    are chickpeas; soda/pop/cola are the same aisle. Judge the product, not "
    "    the wording.\n\n"
    "IMPLAUSIBLE is for a genuinely DIFFERENT product that merely mentions the item "
    "in its name -- something a shopper sent to buy the commodity would not accept. "
    "Real cases that reached this board:\n"
    "  habanero peppers  <- 'Bonnie's Jams Blueberry Habanero Pepper Conserve' (a jam)\n"
    "  apricots          <- 'Smuckers Natural Apricot Fruit Spread' (a jam)\n"
    "  coconut oil       <- \"Dr Teal's Foaming Bath with Coconut Oil\" (bath soap)\n"
    "  blueberries       <- a Bai flavoured beverage\n"
    "  ground cinnamon   <- 'Cinnamon Swirl Crumb Cake & Muffin Mix'\n"
    "The pattern: a spread, jam, sauce, drink, snack, soap, candle or prepared meal "
    "FLAVOURED WITH or CONTAINING the item is not the item itself.\n\n"
    "Also IMPLAUSIBLE when the commodity names a specific variety, grade or "
    "preparation and the product is a different one (Deglet Noor dates are not "
    "Medjool; 85/15 beef is not 93/7; 'apple cider FLAVORED distilled vinegar' is "
    "not apple cider vinegar).\n\n"
    "Answer IMPLAUSIBLE only when you are confident a shopper would reject it. "
    "Otherwise answer UNSURE -- a false alarm wastes a person's time and teaches "
    "them to ignore you, which is worse than silence. Output JSON only."
)


def crown_rows(db, limit: int | None):
    """The row currently pricing each cell — the only row a shopper can see."""
    rows = db.conn.execute(
        """SELECT p.commodity_id, p.store_id, p.product_name, p.price, p.size_text,
                  p.unit_price, p.unit, p.source_file, n.canonical_name, n.properties_json
           FROM price_observations p
           JOIN nodes n ON n.id = p.commodity_id
           WHERE p.match_status IN ('include_hit','llm_confirmed')
             AND p.basis_flag IS NULL AND p.price IS NOT NULL
             AND p.product_name IS NOT NULL""").fetchall()

    best: dict[tuple[str, str], tuple] = {}
    for r in rows:
        props = json.loads(r["properties_json"] or "{}")
        basis = props.get("unit_basis")
        pu, _ = reconcile_unit(r["unit_price"], r["unit"], basis)
        if pu is None:
            d, du = per_unit(r["price"], r["size_text"], basis, r["product_name"])
            pu, _ = reconcile_unit(d, du, basis)
        if pu is None:
            continue
        key = (r["commodity_id"], r["store_id"])
        curated = "product-urls" in (r["source_file"] or "")
        rank = (0 if curated else 1, pu)
        if key not in best or rank < best[key][0]:
            best[key] = (rank, r, pu)

    out = [(r, pu) for (_, r, pu) in best.values()]
    out.sort(key=lambda x: (x[0]["canonical_name"], x[0]["store_id"]))
    return out[:limit] if limit else out


def check(llm, commodity: str, unit: str | None, product: str, size, price):
    user = (f"COMMODITY: {commodity}\n"
            f"the board prices it by: {unit or 'unspecified'}\n\n"
            f"PRODUCT CURRENTLY PRICING THAT ROW:\n"
            f"  name: {product}\n  size: {size}\n  price: ${price}\n\n"
            "Is this product genuinely that food?")
    parsed, res = llm.json_call(SYSTEM, user, schema=SCHEMA, max_tokens=260)
    return parsed, res


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=200)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--min-confidence", type=float, default=0.75)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    llm = LocalLLM()
    if not llm.health():
        print("local endpoint down - start it: pwsh tools/local-llm/serve.ps1", file=sys.stderr)
        return 2

    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    with open_db() as db:
        rows = crown_rows(db, None if args.all else args.limit)

    print(f"checking {len(rows)} crown-holders (shadow only, gates nothing)\n")
    verdicts = collections.Counter()
    findings, t0 = [], time.time()

    for i, (r, pu) in enumerate(rows):
        props = json.loads(r["properties_json"] or "{}")
        try:
            parsed, _ = check(llm, r["canonical_name"], props.get("unit_basis"),
                              r["product_name"], r["size_text"], r["price"])
        except Exception as e:                                # noqa: BLE001
            verdicts["ERROR"] += 1
            continue
        v = str(parsed.get("verdict", "UNSURE")).upper()
        conf = float(parsed.get("confidence", 0) or 0)
        verdicts[v] += 1
        if v == "IMPLAUSIBLE" and conf >= args.min_confidence:
            findings.append({
                "commodity": r["commodity_id"].split(":")[-1],
                "commodity_label": r["canonical_name"],
                "store": r["store_id"].replace("store:", ""),
                "product": r["product_name"], "price": r["price"],
                "size": r["size_text"], "per_unit": round(pu, 4),
                "confidence": conf, "reason": str(parsed.get("reason", ""))[:300],
                "source": os.path.basename(r["source_file"] or ""),
                "checked_at": ts,
            })
        if (i + 1) % 25 == 0:
            rate = (i + 1) / max(time.time() - t0, 1e-9)
            print(f"  {i+1}/{len(rows)}  flagged={len(findings)}  {rate:.1f}/s")

    with io.open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        for f in findings:
            fh.write(json.dumps(f, ensure_ascii=False, sort_keys=True) + "\n")

    elapsed = time.time() - t0
    checked = sum(verdicts.values())
    if args.json:
        print(json.dumps({"verdicts": dict(verdicts), "findings": findings}, indent=2))
        return 0

    print(f"\n=== crown plausibility (SHADOW) — {checked} checked in {elapsed/60:.1f} min ===")
    for v, n in verdicts.most_common():
        print(f"  {v:<12} {n:>5}  ({n/checked:.1%})")
    print(f"\n  flagged at confidence >= {args.min_confidence}: {len(findings)}")
    print(f"  FLAG RATE: {len(findings)/checked:.2%}  <- precision must be judged by hand")
    print("     A believable rate here is a fraction of a percent. A high rate means the")
    print("     checker is too eager and would cry wolf, not that the board is broken.")
    for f in findings[:20]:
        print(f"\n  [{f['confidence']:.2f}] {f['commodity_label']} @ {f['store']}  "
              f"${f['price']} ({f['per_unit']}/unit)")
        print(f"        {f['product'][:74]}")
        print(f"        {f['reason'][:120]}")
    print(f"\n  findings -> {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
