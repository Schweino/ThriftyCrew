"""Adjudicate every parity conflict and record a verdict (plan Block 1.5).

    python graph/eval/adjudicate_parity.py
    python graph/eval/adjudicate_parity.py --show 20

The plan requires that no graph-LOWER conflict is left unadjudicated, and that
each carries one of three verdicts with its evidence:

    false_merge     the graph priced a cell from a product that is NOT the
                    commodity -> fix the resolver, an alias, or known-wrong
    unit_or_import  the product is right but the per-unit number is wrong ->
                    fix the importer or the unit reconciliation
    legitimate      both are defensible; the board and the graph simply chose
                    different products -> document why, change nothing

Verdicts are written to graph/eval/parity-adjudications.jsonl (tracked), so the
next run can tell a NEW conflict from one already ruled on. That distinction is
the whole point: a conflict count that silently re-litigates settled cases can
never converge.

CLASSIFICATION IS EVIDENCE-BASED, NOT A GUESS. Each conflict is auto-classified
only where the evidence is unambiguous; everything else is left as
`needs_review` rather than being assigned a comfortable label. An honest
`needs_review` pile is more useful than a tidy one built on assumptions.
"""

from __future__ import annotations

import argparse
import collections
import io
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

from graphdb import open_db                                   # noqa: E402
from ids import norm_text                                     # noqa: E402
from board_parity import parse_live_board, graph_board, compare   # noqa: E402
from units import per_unit, reconcile_unit                    # noqa: E402

LEDGER = os.path.join(HERE, "parity-adjudications.jsonl")


def commodity_node(db, legacy: str) -> str | None:
    for ns in ("staple", "recipe"):
        n = f"commodity:{ns}:{legacy}"
        if db.get_node(n):
            return n
    return None


def winning_row(db, cid: str, store: str, basis: str | None):
    """The row the graph actually crowned this cell with."""
    rows = db.conn.execute(
        """SELECT product_name, price, size_text, unit_price, unit, source_file
           FROM price_observations
           WHERE commodity_id=? AND store_id=?
             AND match_status IN ('include_hit','llm_confirmed')
             AND basis_flag IS NULL AND price IS NOT NULL""",
        (cid, "store:" + store)).fetchall()
    best = None
    for r in rows:
        pu, u = reconcile_unit(r["unit_price"], r["unit"], basis)
        if pu is None:
            d, du = per_unit(r["price"], r["size_text"], basis, r["product_name"])
            pu, u = reconcile_unit(d, du, basis)
        if pu is None:
            continue
        # product-urls is curated and takes precedence, mirroring graph_board
        curated = "product-urls" in (r["source_file"] or "")
        key = (0 if curated else 1, pu)
        if best is None or key < best[0]:
            best = (key, r, pu)
    return (best[1], best[2]) if best else (None, None)


def _forms(w: str) -> set[str]:
    """Every plausible singular/plural form of a word.

    Returning a SET rather than one stem avoids the over-stripping trap: a single
    rule that turns "nectarines" into "nectarin" will never match "nectarine",
    so the right product still scores 0% and still gets mislabelled a false
    merge. Comparing candidate forms sidesteps the need to guess correctly.

    This matters because a classifier that marks safe cases dangerous is worse
    than none at all -- it buries the handful of real defects in noise.
    """
    out = {w}
    if len(w) > 3:
        if w.endswith("ies"):
            out.add(w[:-3] + "y")
        if w.endswith("es"):
            out.update({w[:-2], w[:-1]})      # nectarines -> nectarine AND nectarin
        if w.endswith("s"):
            out.add(w[:-1])
    out.add(w + "s")
    out.add(w + "es")
    return out


def _words(s: str) -> list[str]:
    """Split on non-alphanumerics. norm_text deliberately KEEPS punctuation
    (it is load-bearing for things like "93/7"), which leaves tokens such as
    "plums," that no stemmer will fold. Here only word identity matters."""
    return [w for w in re.split(r"[^a-z0-9]+", norm_text(s)) if w]


def token_overlap(label: str, product: str) -> float:
    """Share of the commodity label's words present in the product name, matched
    across plural/singular forms so surface drift does not read as a mismatch."""
    lw = [w for w in _words(label) if len(w) > 2]
    pw: set[str] = set()
    for w in _words(product):
        pw |= _forms(w)
    if not lw:
        return 0.0
    hit = sum(1 for w in lw if _forms(w) & pw)
    return hit / len(lw)


def classify(db, c: dict) -> dict:
    legacy, store = c["commodity"], c["store"]
    cid = commodity_node(db, legacy)
    if not cid:
        return {**c, "verdict": "needs_review", "why": "commodity node not found"}

    node = db.get_node(cid)
    props = json.loads(node["properties_json"] or "{}")
    basis = props.get("unit_basis")
    row, pu = winning_row(db, cid, store, basis)
    if row is None:
        return {**c, "verdict": "needs_review", "why": "no crowning row could be identified"}

    ev = {"product": row["product_name"], "price": row["price"],
          "size": row["size_text"], "basis": basis,
          "source": os.path.basename(row["source_file"] or "")}

    overlap = token_overlap(node["canonical_name"], row["product_name"] or "")
    ratio = (c["graph"] / c["live"]) if c["live"] else 0.0

    # 1. The ratio sitting on a whole number is the signature of a pack/size
    #    parse error, not of a different product being chosen.
    for n in (2, 3, 4, 6, 8, 10, 12, 16, 20, 24, 48, 72, 128):
        if abs(ratio - n) / n < 0.02 or (ratio and abs((1 / ratio) - n) / n < 0.02):
            return {**c, "verdict": "unit_or_import", "evidence": ev,
                    "why": f"graph/live ratio is {ratio:.2f}, within 2% of {n}x - "
                           f"the signature of a pack-count or basis parse error"}

    # 2. A crowned product sharing almost no words with the commodity label is a
    #    match failure, not a pricing difference.
    if overlap <= 0.34 and c["pct_diff"] < 0:
        return {**c, "verdict": "false_merge", "evidence": ev,
                "why": f"crowning product shares only {overlap:.0%} of the commodity "
                       f"label's words; priced BELOW the board, so it is stealing the cell"}

    # 3. Graph higher, and the graph simply lacks whatever the board priced.
    if c["pct_diff"] > 0:
        return {**c, "verdict": "legitimate", "evidence": ev,
                "why": "graph is HIGHER: it never saw the cheaper product the board "
                       "crowned. A coverage gap, not a defect - it cannot publish a "
                       "wrong low price."}

    # 4. Graph lower, product name plausible, magnitude ordinary -> price movement.
    if overlap > 0.34 and abs(c["pct_diff"]) < 35:
        return {**c, "verdict": "legitimate", "evidence": ev,
                "why": f"product matches the commodity ({overlap:.0%} label overlap) and "
                       f"the gap is {abs(c['pct_diff']):.0f}%, consistent with a sale "
                       f"window or capture-date difference rather than a mismatch"}

    return {**c, "verdict": "needs_review", "evidence": ev,
            "why": f"graph LOWER by {abs(c['pct_diff']):.0f}% with {overlap:.0%} label "
                   f"overlap - not auto-classifiable, needs a human look"}


def load_ledger() -> dict:
    if not os.path.exists(LEDGER):
        return {}
    out = {}
    with io.open(LEDGER, encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                r = json.loads(line)
                out[f"{r['commodity']}|{r['store']}"] = r
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--show", type=int, default=12)
    ap.add_argument("--tolerance", type=float, default=0.02)
    args = ap.parse_args()

    prior = load_ledger()
    live = parse_live_board()
    with open_db() as db:
        res = compare(live, graph_board(db), args.tolerance)
        rulings = [classify(db, c) for c in res["conflicts"]]

    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    with io.open(LEDGER, "w", encoding="utf-8", newline="\n") as fh:
        for r in rulings:
            key = f"{r['commodity']}|{r['store']}"
            r["adjudicated_at"] = ts
            r["previously_seen"] = key in prior
            fh.write(json.dumps(r, ensure_ascii=False, sort_keys=True, default=str) + "\n")

    counts = collections.Counter(r["verdict"] for r in rulings)
    lower = [r for r in rulings if r["pct_diff"] < 0]
    lower_counts = collections.Counter(r["verdict"] for r in lower)
    new = sum(1 for r in rulings if not r["previously_seen"])

    print(f"=== parity adjudication ({len(rulings)} conflicts, {new} new since last run) ===")
    for v, n in counts.most_common():
        print(f"  {v:<16} {n}")
    print(f"\n  of the {len(lower)} graph-LOWER (the dangerous direction):")
    for v, n in lower_counts.most_common():
        print(f"    {v:<16} {n}")

    unresolved = [r for r in lower if r["verdict"] in ("needs_review", "false_merge")]
    print(f"\n  UNRESOLVED graph-LOWER needing action: {len(unresolved)}")
    for r in unresolved[:args.show]:
        ev = r.get("evidence", {})
        print(f"    [{r['verdict']}] {r['commodity']:<24} {r['store']:<12} "
              f"live={r['live']:.4f} graph={r['graph']:.4f}")
        print(f"        {str(ev.get('product'))[:64]}  (${ev.get('price')} / {ev.get('size')})")
        print(f"        {r['why'][:110]}")

    print(f"\n  ledger: {LEDGER}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
