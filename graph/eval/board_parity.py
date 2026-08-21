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
from units import per_unit, reconcile_unit, names_multiple_products  # noqa: E402

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


def graph_board_from_state(db) -> dict[str, dict[str, float]] | None:
    """PHASE B: the graph's matrix, read straight off cell_state.

    cell_state already holds the one current answer per cell, derived once by
    pipeline/state.py with the same unit reconciliation this file used to redo
    itself. Reading it means parity and the state table cannot drift apart —
    they were two implementations of "what does the graph think this cell costs",
    and two implementations of one answer is how the estate got a curated file
    that disagreed with its own board.

    Returns None when the table is absent or empty, so the pre-state derivation
    below still runs on a fresh index mid-migration.
    """
    try:
        rows = db.conn.execute("""
            SELECT c.commodity_id, c.store_id, c.everyday_unit_price, c.ad_unit_price,
                   n.properties_json
            FROM cell_state c LEFT JOIN nodes n ON n.id = c.commodity_id""").fetchall()
    except Exception:                                        # noqa: BLE001
        return None
    if not rows:
        return None
    out: dict[str, dict[str, float]] = {}
    for r in rows:
        legacy = (json.loads(r["properties_json"] or "{}")).get("legacy_id")
        if not legacy:
            continue
        vals = [v for v in (r["everyday_unit_price"], r["ad_unit_price"]) if v is not None]
        if not vals:
            continue
        out.setdefault(legacy, {})[r["store_id"].replace("store:", "")] = min(vals)

    # Overrides are a BOARD-level correction pinned by a human; they outrank
    # anything derived, exactly as before.
    for r in db.conn.execute(
            "SELECT properties_json FROM nodes WHERE type='Override'"):
        p = json.loads(r["properties_json"] or "{}")
        if p.get("commodity") and p.get("store") and p.get("per_unit") is not None:
            legacy, store = p["commodity"], norm_store(p["store"])
            if legacy in out and store in out[legacy]:
                out[legacy][store] = float(p["per_unit"])
    graph_board.unparsed = 0                 # type: ignore[attr-defined]
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
        # A choice-of-products ad line prices neither of them.
        if names_multiple_products(r["product_name"]):
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
        # THE GATED NUMBER (decision 2026-08-21, Brad). Blended agreement mixed
        # two disagreements that mean opposite things: graph-HIGHER is a benign
        # coverage gap that self-heals as lanes backfill, while graph-LOWER is
        # the false-merge direction — the only one that can publish a wrong
        # price. Blending them punished the graph for being honest about what it
        # could not yet see, and made the target recede as coverage grew.
        "graph_lower_rate": len(lower) / len(shared) if shared else 0.0,
        # ALL of them, not a sample: adjudicate_lower must see every case or
        # the gate would be computed over a truncated denominator.
        "graph_lower_cases": lower,
        "graph_only": len(graph_cells - live_cells),
    }


def adjudicate_lower(db, lower_cases: list[dict], today: str | None = None,
                     live_by_commodity: dict | None = None,
                     max_discount: float = 3.0) -> dict:
    """Split graph-LOWER cells into VERIFIED findings and UNVERIFIED residue.

    Decision 2026-08-21 (Brad): "if the item is right, in the right commodity,
    and it fetched the correct price, why is it a defect to begin with?" It is
    not. The live board is the INCUMBENT, not ground truth — it held the
    strawberry-syrup crown and the 6-18x multipack overprices this estate spent
    the day removing — so a cell where the graph is cheaper carries no
    information about WHO is wrong until the graph's claim is adjudicated.

    A LOWER cell is VERIFIED when every check this estate owns has passed:

      identity  the crowning row is reviewer-confirmed (llm_confirmed), or it
                is a deterministic include_hit on a commodity the gold set
                actually covers — an untested pattern regime is exactly where
                the syrup class of defect lives, so no gold means no credit.
      price     the observation is inside the capture policy's window (row_age
                enforces this globally; re-checked here per cell), and an ad
                price only counts inside its ad window (cell_state enforces).
      guards    known-wrong, class guards and the plausibility flag all had
                their chance to demote the row and did not.

    Verified cells are NOT defects. They are the graph finding value the board
    missed, they flow to the board-gap worklist, and they stop counting against
    the gate. The UNVERIFIED residue is where the next wrong price hides, and
    that is what gates at ~0.
    """
    import time as _t
    live_by_commodity = live_by_commodity or {}
    today = today or _t.strftime("%Y-%m-%d")
    max_age = None
    try:
        sys.path.insert(0, os.path.join(HERE, "..", "agentic"))
        from verifier import _policy_max_carry_days           # noqa: PLC0415
        max_age = _policy_max_carry_days()
    except Exception:                                          # noqa: BLE001
        max_age = 90
    # commodities the gold set can actually see
    gold_cov = set()
    gold_path = os.path.join(HERE, "..", "gold", "gold.jsonl")
    if os.path.exists(gold_path):
        with open(gold_path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    gold_cov.add(json.loads(line).get("commodity"))
                except json.JSONDecodeError:
                    continue
    legacy_to_node = {}
    for r in db.conn.execute("SELECT id, properties_json FROM nodes WHERE type='Commodity'"):
        lid = (json.loads(r["properties_json"] or "{}")).get("legacy_id")
        if lid:
            legacy_to_node.setdefault(lid, []).append(r["id"])

    verified, unverified = [], []
    for c in lower_cases:
        cell = None
        for nid in legacy_to_node.get(c["commodity"], []):
            cell = db.conn.execute(
                "SELECT * FROM cell_state WHERE commodity_id=? AND store_id=?",
                (nid, f"store:{c['store']}")).fetchone()
            if cell:
                break
        why = None
        if cell is None:
            why = "no cell_state row resolvable"
        else:
            # whichever side (everyday/ad) produced the cheaper number is the claim
            use_ad = (cell["ad_unit_price"] is not None and
                      (cell["everyday_unit_price"] is None or
                       cell["ad_unit_price"] <= cell["everyday_unit_price"]))
            ev_id = cell["ad_evidence"] if use_ad else cell["everyday_evidence"]
            asof = (cell["ad_from"] if use_ad else cell["everyday_asof"]) or ""
            row = db.conn.execute("SELECT * FROM price_observations WHERE id=?",
                                  (ev_id,)).fetchone() if ev_id else None
            if row is None:
                why = "evidence row pruned or missing"
            elif row["match_status"] == "llm_confirmed":
                pass                                          # reviewer-verified
            elif row["match_status"] == "include_hit":
                if c["commodity"] not in gold_cov:
                    why = "include_hit on a commodity with NO gold coverage"
            else:
                why = f"crowning row status {row['match_status']!r}"
            if why is None and not use_ad:
                d = _days_between(asof[:10], today)
                if d is None or d > max_age:
                    why = f"everyday price {d if d is not None else '?'}d old (window {max_age}d)"
        # PRICE PLAUSIBILITY, and this clause exists because the first version
        # of this bar did not have it and passed a lie. Brandy at Baker's read
        # $6.99 for 59.2 fl oz — a 1.75 L bottle — and cleared identity,
        # freshness and every guard, because each of those asks whether the
        # PRODUCT is right and none of them asks whether the PRICE is possible.
        # flag_outliers bars rows 5x below the commodity median; this one sat at
        # roughly 3x and sailed through.
        #
        # A cell may only be credited as a board-gap finding if its discount is
        # within reach of the rest of the market for that commodity. Beyond that
        # the cheaper number is far more likely to be a bad capture than a real
        # bargain, and crediting it would let a data defect masquerade as
        # savings — the exact inversion this split was built to prevent.
        if why is None and c.get("live"):
            others = [v for v in (live_by_commodity.get(c["commodity"]) or {}).values()
                      if v is not None]
            if len(others) >= 2:
                med = sorted(others)[len(others) // 2]
                if med and c["graph"] < med / max_discount:
                    why = (f"price implausible: {c['graph']:.4f} is "
                           f"{med / c['graph']:.1f}x under the {med:.4f} market median")
        entry = dict(c)
        if why is None and row is not None:
            entry["product"] = row["product_name"]
            entry["observed_at"] = row["observed_at"]
            verified.append(entry)
        else:
            entry["unverified_because"] = why
            unverified.append(entry)
    return {"verified": verified, "unverified": unverified}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tolerance", type=float, default=0.02,
                    help="relative per-unit tolerance for 'agrees' (default 2%%)")
    ap.add_argument("--min-agreement", type=float, default=0.99,
                    help="reported only; the gate is --max-lower + --min-coverage")
    ap.add_argument("--max-lower", type=float, default=0.01,
                    help="max share of shared cells where the graph is CHEAPER "
                         "than the board - the false-merge direction")
    ap.add_argument("--min-coverage", type=float, default=0.90)
    ap.add_argument("--max-discount", type=float, default=3.0,
                    help="a verified board-gap finding may not be more than this "
                         "many times under the commodity market median; beyond it "
                         "a bad capture is likelier than a real bargain")
    ap.add_argument("--show", type=int, default=8)
    ap.add_argument("--from-observations", action="store_true",
                    help="bypass cell_state and re-derive from observations "
                         "(the Phase B identity check)")
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
        graph = None if args.from_observations else graph_board_from_state(db)
        source = "cell_state"
        if graph is None:
            graph, source = graph_board(db), "observations"
        res = compare(live, graph, args.tolerance)
        res["unparsed_sizes"] = getattr(graph_board, "unparsed", 0)
        res["recipe_cells_out_of_scope"] = recipe_cells
        res["graph_source"] = source
        db.log_event(run="run:parity:" + time.strftime("%Y%m%dT%H%M%S"),
                     timestamp=time.strftime("%Y-%m-%dT%H:%M:%S"),
                     etype="verify", decision="board_parity",
                     detail={k: v for k, v in res.items() if k != "conflicts"})

    if args.json:
        print(json.dumps(res, indent=2))
        return 0

    print("\n=== board parity (graph vs public/board.json, STAPLE scope) ===")
    print(f"  graph source        {res['graph_source']}")
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

    # Gate on the UNVERIFIED residue, not on every cell where the graph is
    # cheaper. Being cheaper is only dangerous when the PRODUCT IS WRONG; a
    # cheaper cell whose identity and price both survived adjudication is the
    # graph finding value the board missed, which is the entire point of it.
    with open_db() as db2:
        adj = adjudicate_lower(db2, res.get("graph_lower_cases") or [],
                               live_by_commodity=live, max_discount=args.max_discount)
    n_ver, n_unver = len(adj["verified"]), len(adj["unverified"])
    shared = res["shared_cells"] or 1
    unver_rate = n_unver / shared
    res["lower_verified"], res["lower_unverified"] = n_ver, n_unver
    res["lower_unverified_rate"] = unver_rate

    lower_ok = unver_rate <= args.max_lower
    cov_ok = res["coverage"] >= args.min_coverage
    print(f"\n  graph-LOWER {res['graph_lower']} splits into:")
    print(f"     {n_ver:>4} VERIFIED   - identity adjudicated, price in window, guards passed.")
    print(f"            NOT defects: these are cells where the board is dearer than")
    print(f"            the shelf. Worklist written for the board to adopt.")
    print(f"     {n_unver:>4} UNVERIFIED - cheaper, and the claim did NOT clear the bar.")
    print(f"            This is where the next wrong price hides.")
    print(f"\n  GATED: unverified-LOWER rate {unver_rate:.4f} (<= {args.max_lower}) "
          f"{'PASS' if lower_ok else 'FAIL'}   |   coverage {res['coverage']:.3f} "
          f"(>= {args.min_coverage}) {'PASS' if cov_ok else 'FAIL'}")
    print(f"  blended agreement {res['agreement']:.3f} is REPORTED, not gated.")

    if adj["verified"]:
        out = os.path.join(REPO_ROOT, "grocery", "out", "board-gap-worklist.json")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        total = sum(max(0.0, c["live"] - c["graph"]) for c in adj["verified"])
        with open(out, "w", encoding="utf-8", newline="\n") as fh:
            json.dump({"generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
                       "note": ("Cells where the graph has an ADJUDICATED cheaper answer "
                                "than the live board. Not defects - the board is dearer "
                                "than the shelf here. Each entry names the product to check."),
                       "cells": len(adj["verified"]),
                       "per_unit_gap_total": round(total, 4),
                       "findings": sorted(adj["verified"], key=lambda c: c["pct_diff"])},
                      fh, indent=2, ensure_ascii=False)
        print(f"\n  board-gap worklist: {len(adj['verified'])} cells, "
              f"{total:.2f} total per-unit gap -> {os.path.relpath(out, REPO_ROOT)}")
    if adj["unverified"]:
        print(f"\n  --- unverified residue (the gated set) ---")
        for c in sorted(adj["unverified"], key=lambda x: x["pct_diff"])[:8]:
            print(f"    {c['commodity'][:22]:<24}@{c['store']:<12}{c['pct_diff']:>7}%  "
                  f"{c['unverified_because']}")
    return 0 if (lower_ok and cov_ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
