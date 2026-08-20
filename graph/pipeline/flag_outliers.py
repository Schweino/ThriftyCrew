"""Basis plausibility guard — refuse to let an impossible per-unit price crown.

    python graph/pipeline/flag_outliers.py
    python graph/pipeline/flag_outliers.py --factor 5.0 --report

WHY THIS EXISTS. A capture row can be a perfectly CORRECT product match and still
carry an unusable per-unit price. Two mechanisms produce that, and they were both
found in real data on 2026-08-20:

  bad source size   Softsoap hand-soap pump listed at "221 fl oz" (a pump is
                    ~7.5). $1.99 / 221 = $0.009/fl oz, which is 13x below the
                    median for that commodity and instantly the cheapest cell.

  loose include     ground-cinnamon's include list carries a bare `\\bcinnamon\\b`
                    and its excludes do not mention cake or muffin, so "Krusteaz
                    Cinnamon Swirl Crumb Cake & Muffin Mix" matched, and a 21 oz
                    cake mix priced cinnamon at $0.19/oz against a real $0.97.

Both are the FALSE-CHEAP direction — the one that publishes a wrong "cheapest"
and the exact failure this estate exists to prevent.

THE RULE. For each commodity, take the median per-unit price across every
priceable observation of it. A row more than `factor` BELOW that median is
flagged and barred from pricing a cell. It is never deleted: it stays in the
table as evidence, with the reason recorded, and it still shows up in audits.

WHY A MEDIAN, AND WHY ONLY DOWNWARD. The median is robust to exactly the outliers
being hunted, so the bad rows cannot drag the threshold toward themselves. Only
the downward direction is flagged because an implausibly HIGH per-unit price is
harmless — it simply never wins a crown — while an implausibly low one always does.

ON THE FACTOR. 5.0 is a judgement call, not a derivation, and it is stated here
rather than buried: real grocery price dispersion for one commodity runs roughly
2-3x between the cheapest and typical offering, so a >5x gap is far outside it.
Measured against this catalog the separation is clean — the hand-soap defect sits
at 13.3x and the cinnamon false merge at 5.1x, while a genuine bargain (canned
chopped spinach at $0.147/oz against fresh bagged at $0.436) sits at 3.0x and
correctly survives. Raise the factor if real bargains start being refused; do not
lower it to make a number look better.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

from graphdb import open_db                        # noqa: E402
from units import per_unit, reconcile_unit         # noqa: E402

DEFAULT_FACTOR = 5.0
# Below this many priceable rows a median means nothing, so nothing is flagged.
MIN_ROWS_FOR_MEDIAN = 4


def row_unit_price(row, basis: str | None) -> float | None:
    """The same precedence board_parity uses: engine-verified first, then derived,
    and both reconciled to the commodity's declared basis or refused."""
    pu, unit = reconcile_unit(row["unit_price"], row["unit"], basis)
    if pu is None:
        d, du = per_unit(row["price"], row["size_text"], basis)
        pu, unit = reconcile_unit(d, du, basis)
    return pu


def flag(db, factor: float = DEFAULT_FACTOR, run: str = "", ts: str | None = None,
         reset: bool = True) -> dict:
    ts = ts or time.strftime("%Y-%m-%dT%H:%M:%S")
    if reset:
        db.conn.execute("UPDATE price_observations SET basis_flag=NULL, basis_detail=NULL")

    commodities = [r["id"] for r in db.conn.execute(
        "SELECT id FROM nodes WHERE type='Commodity' ORDER BY id").fetchall()]

    n_flag = n_checked = n_commodities = 0
    examples: list[dict] = []

    for cid in commodities:
        node = db.get_node(cid)
        basis = json.loads(node["properties_json"] or "{}").get("unit_basis")
        rows = db.conn.execute(
            """SELECT id, product_name, price, unit_price, unit, size_text, store_id
               FROM price_observations
               WHERE commodity_id=? AND match_status IN ('include_hit','llm_confirmed')""",
            (cid,)).fetchall()
        priced = []
        for r in rows:
            pu = row_unit_price(r, basis)
            if pu is not None and pu > 0:
                priced.append((pu, r))
        if len(priced) < MIN_ROWS_FOR_MEDIAN:
            continue

        n_commodities += 1
        n_checked += len(priced)
        med = statistics.median([p for p, _ in priced])
        threshold = med / factor

        for pu, r in priced:
            if pu < threshold:
                detail = (f"per-unit {pu:.4f} is {med/pu:.1f}x below the commodity "
                          f"median {med:.4f} (n={len(priced)}); size={r['size_text']!r}")
                db.conn.execute(
                    "UPDATE price_observations SET basis_flag='low_outlier', basis_detail=? "
                    "WHERE id=?", (detail, r["id"]))
                n_flag += 1
                if len(examples) < 40:
                    examples.append({
                        "commodity": cid.split(":")[-1], "store": r["store_id"].replace("store:", ""),
                        "product": (r["product_name"] or "")[:60], "unit_price": round(pu, 4),
                        "median": round(med, 4), "ratio": round(med / pu, 1),
                        "size": r["size_text"], "price": r["price"],
                    })
    db.conn.commit()

    out = {"flagged": n_flag, "checked_rows": n_checked,
           "commodities_with_median": n_commodities, "factor": factor,
           "examples": examples}
    if run:
        db.log_event(run=run, timestamp=ts, etype="verify", decision="flag_basis_outliers",
                     detail={k: v for k, v in out.items() if k != "examples"})
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--factor", type=float, default=DEFAULT_FACTOR)
    ap.add_argument("--report", action="store_true", help="show the flagged examples")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    run = f"run:outliers:{time.strftime('%Y%m%dT%H%M%S')}"
    with open_db() as db:
        res = flag(db, factor=args.factor, run=run)

    if args.json:
        print(json.dumps(res, indent=2, default=str))
        return 0

    print(f"basis plausibility guard (factor {res['factor']}x below median)")
    print(f"  commodities with a usable median : {res['commodities_with_median']}")
    print(f"  priceable rows checked           : {res['checked_rows']}")
    print(f"  FLAGGED (barred from crowning)   : {res['flagged']}")
    if args.report and res["examples"]:
        print("\n  worst offenders:")
        for e in sorted(res["examples"], key=lambda x: -x["ratio"])[:15]:
            print(f"    {e['ratio']:>6.1f}x  {e['commodity']:<24} {e['store']:<12} "
                  f"${e['price']} / {str(e['size'])[:16]:<16} = {e['unit_price']:.4f} "
                  f"(median {e['median']:.4f})")
            print(f"             {e['product']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
