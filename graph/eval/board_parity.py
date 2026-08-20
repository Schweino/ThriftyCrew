"""Phase 2 exit gate — does the graph reproduce the LIVE board?

    python graph/eval/board_parity.py
    python graph/eval/board_parity.py --min-agreement 0.99

The gate (plan §12 Phase 2): "a graph query reproduces the live board's
commodity-store price matrix with >= 99% cell agreement".

The live board is public/board.json — a map of commodity id -> rendered HTML,
where each store chip carries data-store and data-pu (the per-unit price the
site actually shows a shopper). Parsing those attributes gives the ground-truth
matrix without re-deriving anything.

HONEST SCOPING, and why it matters here: the graph can only be compared on cells
it has EVIDENCE for. If the observation backfill covered 3 Walmart captures, the
graph has no opinion about Hy-Vee, and scoring those absences as disagreements
would understate parity as badly as skipping them would overstate it. So this
reports three separate numbers and never blends them:

    coverage   — of the live board's cells, how many the graph can speak to
    agreement  — of the cells it CAN speak to, how many match within tolerance
    conflicts  — cells where both have a price and they disagree

Only `agreement` is gated. `coverage` is reported so nobody mistakes a narrow
backfill for a passing gate — the V3/V4 estate died of exactly that confusion,
declaring readiness on 1 of 14 required parity days.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

from graphdb import open_db, read_json, REPO_ROOT      # noqa: E402
from ids import norm_store, store_id                   # noqa: E402
from units import per_unit, reconcile_unit             # noqa: E402

BOARD_PATH = os.path.join(REPO_ROOT, "public", "board.json")


def _days_between(older: str, newer: str) -> int | None:
    """newer minus older, in days; None when either is not an ISO date."""
    try:
        from datetime import date
        o, n = date.fromisoformat(older[:10]), date.fromisoformat(newer[:10])
        return (n - o).days
    except (ValueError, TypeError):
        return None

CHIP_RE = re.compile(
    r"data-store=[\"']([^\"']+)[\"'][^>]*data-pu='([\d.]+)'", re.IGNORECASE)


def _unescape(s: str) -> str:
    return (s.replace("&#39;", "'").replace("&amp;", "&")
             .replace("&quot;", '"').replace("&rarr;", ""))


def parse_live_board(path: str = BOARD_PATH) -> dict[str, dict[str, float]]:
    """commodity id -> {store_slug: per_unit} from the rendered board."""
    if not os.path.exists(path):
        raise FileNotFoundError(f"live board not found at {path}")
    raw = read_json(path)
    out: dict[str, dict[str, float]] = {}
    for cid, html in raw.items():
        if not isinstance(html, str):
            continue
        cells = {}
        for store, pu in CHIP_RE.findall(html):
            try:
                cells[norm_store(_unescape(store))] = float(pu)
            except ValueError:
                continue
        if cells:
            out[cid] = cells
    return out


def graph_board(db) -> dict[str, dict[str, float]]:
    """The graph's own matrix: cheapest SURVIVING per-unit candidate per cell.

    Only rows that passed resolution can price a cell (v_current_cell enforces
    that), and only rows whose size parsed can be normalised — an unparsed size
    contributes nothing rather than a guess.
    """
    # basis_flag IS NULL is not optional here: a row with an implausible per-unit
    # price is barred from crowning (see graph/pipeline/flag_outliers.py). Without
    # it, a "221 fl oz" hand-soap pump prices the cell at $0.009.
    rows = db.conn.execute(
        """SELECT p.commodity_id, p.store_id, p.price, p.size_text,
                  p.unit_price, p.unit, p.source_file, p.product_name,
                  p.price_type, p.ad_cycle_id, p.observed_at, n.properties_json
           FROM price_observations p
           LEFT JOIN nodes n ON n.id = p.commodity_id
           WHERE p.match_status IN ('include_hit','llm_confirmed')
             AND p.basis_flag IS NULL
             AND p.price IS NOT NULL""").fetchall()

    # Overrides: the board pins certain cells to a corrected per-unit and those
    # win over anything the sweep saw. Modelling the board without them
    # guarantees a disagreement on every pinned cell.
    overrides: dict[tuple[str, str], float] = {}
    for r in db.conn.execute(
            """SELECT canonical_name, properties_json FROM nodes WHERE type='Override'"""):
        p = json.loads(r["properties_json"] or "{}")
        if p.get("commodity") and p.get("store") and p.get("per_unit") is not None:
            overrides[(p["commodity"], norm_store(p["store"]))] = float(p["per_unit"])

    # CURRENCY FIRST, then precedence. The board renders the CURRENT price; a
    # flat minimum over all history modelled "cheapest EVER observed", so any
    # old low price won forever — Aldi cucumbers crowned at the 08-09 $0.65
    # against the board's current 08-15 $0.75 with both files imported, and an
    # expired 07-23 blueberries sale still held its cell. Selection is now:
    #
    #   1. newest observation per (cell, product) — a product's older sightings
    #      are superseded by its latest one, exactly the price-state design's
    #      supersede rule, applied at read time until Phase C lands it at import
    #   2. ad/sale rows count only while their ad window CONTAINS today; an
    #      ad row with no resolvable window never crowns (missed-over-false)
    #   3. precedence: pinned override > curated product-urls row > cheapest
    #      surviving sweep row. Curated wins ONLY while reasonably current —
    #      a curated row more than 14 days older than the cell's newest sweep
    #      sighting has been overtaken by events (the July $1.89 strawberries
    #      entry was outranking August shelf data) and falls back to the sweep.
    today = time.strftime("%Y-%m-%d")
    cycles: dict[str, tuple[str, str]] = {}
    for c in db.conn.execute(
            "SELECT id, properties_json FROM nodes WHERE type='AdCycle'"):
        p = json.loads(c["properties_json"] or "{}")
        if p.get("from") and p.get("to"):
            cycles[c["id"]] = (p["from"], p["to"])

    # (legacy, store, norm product) -> (observed_at, pu, is_curated)
    newest: dict[tuple[str, str, str], tuple[str, float, bool]] = {}
    unparsed = 0
    for r in rows:
        props = json.loads(r["properties_json"] or "{}")
        legacy = props.get("legacy_id")
        if not legacy:
            continue
        # Ad/sale currency gate, before any price work.
        if (r["price_type"] or "").lower() in ("ad", "sale"):
            win = cycles.get(r["ad_cycle_id"] or "")
            if not win or not (win[0] <= today <= win[1]):
                continue

        # Prefer the legacy engine's own verified unit price, but ONLY after
        # reconciling its basis with the board's declared basis for this
        # commodity. The engine reports milk per fluid ounce while the board
        # declares gallons; comparing them raw understates milk 128-fold.
        basis = props.get("unit_basis")
        pu, unit = reconcile_unit(r["unit_price"], r["unit"], basis)
        if pu is None:
            # Fallback derivation — but it too must be reconciled to the board's
            # declared basis. per_unit() answers in whatever unit it managed to
            # PARSE ('floz' for a 0.5 gal jug, 'ct' for a 599-sheet pack), which
            # is not necessarily the basis the board compares on. Using it
            # unreconciled is what made milk look like $0.027 against a $3.49
            # board cell. Refuse rather than guess.
            derived, derived_unit = per_unit(r["price"], r["size_text"], basis,
                                            r["product_name"])
            pu, unit = reconcile_unit(derived, derived_unit, basis)
        if pu is None:
            unparsed += 1
            continue
        store = r["store_id"].replace("store:", "")
        pkey = re.sub(r"\s+", " ", (r["product_name"] or "").lower()).strip()
        key = (legacy, store, pkey)
        cur = newest.get(key)
        obs = r["observed_at"] or ""
        is_cur = "product-urls" in (r["source_file"] or "")
        # newer sighting supersedes; same-day ties keep the cheaper reading
        if cur is None or obs > cur[0] or (obs == cur[0] and pu < cur[1]):
            newest[key] = (obs, pu, is_cur)

    curated: dict[str, dict[str, tuple[float, str]]] = {}
    best: dict[str, dict[str, tuple[float, str]]] = {}
    for (legacy, store, _pkey), (obs, pu, is_cur) in newest.items():
        tgt = curated if is_cur else best
        cell = tgt.setdefault(legacy, {})
        if store not in cell or pu < cell[store][0]:
            cell[store] = (pu, obs)

    out: dict[str, dict[str, float]] = {}
    for legacy, stores in best.items():
        for store, (pu, _obs) in stores.items():
            out.setdefault(legacy, {})[store] = pu
    for legacy, stores in curated.items():
        for store, (pu, obs) in stores.items():
            sweep = best.get(legacy, {}).get(store)
            if sweep is not None:
                sweep_obs = sweep[1]
                stale = (_days_between(obs, sweep_obs) or 0) > 14
                if stale:
                    continue                     # overtaken curated row: sweep stands
            out.setdefault(legacy, {})[store] = pu
    for (legacy, store), pu in overrides.items():
        if legacy in out and store in out[legacy]:
            out[legacy][store] = pu

    graph_board.unparsed = unparsed          # type: ignore[attr-defined]
    return out


def compare(live: dict, graph: dict, tol: float = 0.02) -> dict:
    live_cells = {(c, s) for c, stores in live.items() for s in stores}
    graph_cells = {(c, s) for c, stores in graph.items() for s in stores}
    shared = live_cells & graph_cells

    agree = 0
    conflicts = []
    for c, s in sorted(shared):
        lv, gv = live[c][s], graph[c][s]
        denom = max(abs(lv), 1e-9)
        if abs(lv - gv) / denom <= tol:
            agree += 1
        else:
            conflicts.append({"commodity": c, "store": s, "live": lv, "graph": gv,
                              "pct_diff": round((gv - lv) / denom * 100, 1)})

    conflicts.sort(key=lambda x: -abs(x["pct_diff"]))

    # Classify by DIRECTION — the two are not equally alarming.
    #
    #   graph HIGHER than live: the graph is missing the cheaper product that won
    #   the live crown. Almost always a coverage gap (a lane not yet backfilled),
    #   not a correctness defect. Benign, and it self-heals as backfill widens.
    #
    #   graph LOWER than live: the graph believes something is cheaper than the
    #   published board does. That is the FALSE-MERGE direction — it is how a
    #   wrong product steals a crown, which is the exact failure this estate was
    #   built to prevent. Every one of these deserves individual review.
    higher = [c for c in conflicts if c["pct_diff"] > 0]
    lower = [c for c in conflicts if c["pct_diff"] < 0]

    return {
        "live_cells": len(live_cells),
        "graph_cells": len(graph_cells),
        "shared_cells": len(shared),
        "coverage": len(shared) / len(live_cells) if live_cells else 0.0,
        "agreement": agree / len(shared) if shared else 0.0,
        "agree": agree,
        "conflicts": conflicts,
        "graph_higher": len(higher),
        "graph_lower": len(lower),
        "graph_lower_cases": lower[:20],
        "graph_only": len(graph_cells - live_cells),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tolerance", type=float, default=0.02,
                    help="relative per-unit tolerance for 'agrees' (default 2%%)")
    ap.add_argument("--min-agreement", type=float, default=0.99)
    ap.add_argument("--show", type=int, default=8)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    live_all = parse_live_board()
    # SCOPE: this gate measures the STAPLE pricing mechanism. '::r' rows are
    # recipe-board cells the live board prices via recipe->ingredient mapping —
    # a different mechanism this comparison does not model, so scoring them
    # here counted 248 permanently-unreachable cells against coverage (0.876
    # blended vs 0.948 in scope). They are reported, not blended, and deserve
    # their own mapping-based parity gate.
    live = {c: v for c, v in live_all.items() if not c.endswith("::r")}
    recipe_cells = sum(len(v) for c, v in live_all.items() if c.endswith("::r"))
    with open_db() as db:
        graph = graph_board(db)
        res = compare(live, graph, args.tolerance)
        res["unparsed_sizes"] = getattr(graph_board, "unparsed", 0)
        res["recipe_cells_out_of_scope"] = recipe_cells
        db.log_event(run="run:parity:" + time.strftime("%Y%m%dT%H%M%S"),
                     timestamp=time.strftime("%Y-%m-%dT%H:%M:%S"),
                     etype="verify", decision="board_parity",
                     detail={k: v for k, v in res.items() if k != "conflicts"})

    if args.json:
        print(json.dumps(res, indent=2))
        return 0

    print("\n=== board parity (graph vs public/board.json, STAPLE scope) ===")
    print(f"  recipe cells        {res['recipe_cells_out_of_scope']}   "
          f"(::r rows; priced via ingredient mapping — separate gate, not blended)")
    print(f"  live board cells    {res['live_cells']}")
    print(f"  graph cells         {res['graph_cells']}   "
          f"(sizes unparsed, skipped: {res['unparsed_sizes']})")
    print(f"  comparable (shared) {res['shared_cells']}")
    print(f"  COVERAGE            {res['coverage']:.3f}   "
          f"<- share of the live board the graph can speak to")
    print(f"  AGREEMENT           {res['agreement']:.3f}   "
          f"gate >= {args.min_agreement}   "
          f"{'PASS' if res['agreement'] >= args.min_agreement else 'FAIL'}")
    print(f"  conflicts           {len(res['conflicts'])}")

    print(f"    graph higher  {res['graph_higher']:<5} (missing a cheaper row — coverage gap, benign)")
    print(f"    graph LOWER   {res['graph_lower']:<5} (believes something is cheaper than the board "
          f"— FALSE-MERGE direction, review each)")

    if res["graph_lower_cases"] and args.show:
        print(f"\n  --- graph-LOWER cases (the dangerous direction) ---")
        for c in res["graph_lower_cases"][:args.show]:
            print(f"    {c['commodity']:<28} {c['store']:<12} "
                  f"live={c['live']:<9.4f} graph={c['graph']:<9.4f} ({c['pct_diff']:+.1f}%)")

    if res["conflicts"] and args.show:
        print(f"\n  --- largest {args.show} disagreements overall ---")
        for c in res["conflicts"][:args.show]:
            print(f"    {c['commodity']:<28} {c['store']:<12} "
                  f"live={c['live']:<9.4f} graph={c['graph']:<9.4f} ({c['pct_diff']:+.1f}%)")

    if res["coverage"] < 0.9:
        print("\n  GATE NOT MEANINGFUL YET — the backfill is partial.")
        print("  Only the `regular` and `throttled` lanes carry parseable deal arrays, and only")
        print("  Walmart rows carry the engine's verified unit price. Baker's, Sam's, Aldi and")
        print("  Hy-Vee ad pulls use different file shapes and are NOT yet imported, so the graph")
        print("  cannot see the products that won many live crowns. Widening the backfill is")
        print("  Phase 2's remaining work; until then treat AGREEMENT as indicative, not passing.")

    return 0 if (res["agreement"] >= args.min_agreement and res["coverage"] >= 0.9) else 1


if __name__ == "__main__":
    raise SystemExit(main())
