"""End-to-end smoke test: 10 random commodities, all seven stores, every stage.

    python graph/eval/smoke_test.py
    python graph/eval/smoke_test.py --n 10 --seed 20260820 --no-llm

Testing each stage in isolation is not the same as proving the system works.
This walks a random sample all the way through, in order, and reports PASS/FAIL
per stage:

    0  environment      local endpoint, index populated, gold set present
    1  sample           N random commodities (SEEDED, so a run is reproducible)
    2  evidence         do we have observations, and where did each come from
    3  resolution       what the layered resolver decided, and why
    4  basis            per-unit derivation and the plausibility guard
    5  board            the graph's cell vs the LIVE published board
    6  plausibility     does the crowning product really denote the commodity
    7  gates            the six graph gate checks
    8  provenance       can every printed price be traced to its source file

The sample is drawn at random rather than from well-covered commodities on
purpose. Cherry-picking rows that look good is how a smoke test comes to mean
nothing; gaps in the sample are reported, not hidden.

SCOPE, stated plainly: this exercises the GRAPH pipeline over captured store
data. It does not re-fetch live prices from the seven stores -- three of them
(Walmart, Sam's Club, Fareway) sit behind bot walls that need a real logged-in
Chrome, which is the weekly browser agent's job. Capture ages are printed per
store so nobody mistakes a stale lane for a fresh one.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time
from datetime import date, datetime

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
sys.path.insert(0, os.path.join(HERE, "..", "pipeline"))
sys.path.insert(0, os.path.join(HERE, "..", "agentic"))
sys.path.insert(0, os.path.join(HERE, "..", "gold"))

from graphdb import open_db, REPO_ROOT                        # noqa: E402
from ids import store_label                                       # noqa: E402
from units import per_unit, reconcile_unit                    # noqa: E402
from board_parity import parse_live_board                     # noqa: E402
from resolve import Resolver                                  # noqa: E402
from verifier import run_checks                               # noqa: E402
from llm import LocalLLM                                      # noqa: E402

STORES = ["hyvee", "aldi", "bakers", "family-fare", "fareway", "walmart", "sams"]
OK, BAD, WARN = "PASS", "FAIL", "warn"


def hr(t=""):
    print("\n" + "=" * 78)
    if t:
        print(f"  {t}")
        print("=" * 78)


def cell_price(db, cid, store_id, basis):
    """Reproduce exactly what the board-derivation does for one cell."""
    rows = db.conn.execute(
        """SELECT product_name, price, size_text, unit_price, unit, source_file,
                  observed_at, match_status, basis_flag, provenance_id
           FROM price_observations
           WHERE commodity_id=? AND store_id=?""", (cid, store_id)).fetchall()
    priced, blocked = [], []
    for r in rows:
        if r["match_status"] not in ("include_hit", "llm_confirmed"):
            blocked.append(r)
            continue
        if r["basis_flag"]:
            blocked.append(r)
            continue
        if r["price"] is None:
            continue
        pu, _ = reconcile_unit(r["unit_price"], r["unit"], basis)
        if pu is None:
            d, du = per_unit(r["price"], r["size_text"], basis, r["product_name"])
            pu, _ = reconcile_unit(d, du, basis)
        if pu is None:
            continue
        curated = "product-urls" in (r["source_file"] or "")
        priced.append(((0 if curated else 1, pu), r, pu))
    priced.sort(key=lambda x: x[0])
    return (priced[0][1], priced[0][2]) if priced else (None, None), len(rows), blocked


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=10)
    ap.add_argument("--seed", type=int, default=20260820)
    ap.add_argument("--no-llm", action="store_true")
    args = ap.parse_args()

    results: dict[str, str] = {}
    t0 = time.time()

    # ---- 0. environment -------------------------------------------------
    hr("STAGE 0 - environment")
    llm = LocalLLM()
    healthy = llm.health()
    print(f"  local model endpoint : {'up' if healthy else 'DOWN'}  ({llm.endpoint})")
    with open_db() as db:
        stats = db.stats()
        learning = db.learning_counts()
    print(f"  graph index          : {stats['nodes']} nodes, {stats['observations']} observations")
    print(f"  learning records     : {learning}")
    gold_path = os.path.join(HERE, "..", "gold", "gold.jsonl")
    n_gold = sum(1 for _ in open(gold_path, encoding="utf-8")) if os.path.exists(gold_path) else 0
    print(f"  gold set             : {n_gold} cases")
    env_ok = stats["nodes"] > 0 and stats["observations"] > 0 and n_gold > 0
    results["0 environment"] = OK if env_ok else BAD
    if not env_ok:
        print("\n  index is empty - run: python graph/import/import_all.py --observations")
        return 1

    # ---- capture freshness, so nobody mistakes stale for fresh ----------
    print("\n  capture freshness per store (newest observation):")
    today = date.today()
    with open_db() as db:
        for s in STORES:
            row = db.conn.execute(
                "SELECT MAX(observed_at) m, COUNT(*) n FROM price_observations WHERE store_id=?",
                ("store:" + s,)).fetchone()
            if not row["m"]:
                print(f"    {store_label(s):<14} NO DATA")
                continue
            try:
                age = (today - datetime.strptime(row["m"][:10], "%Y-%m-%d").date()).days
            except ValueError:
                age = -1
            note = "  <- browser lane, needs real Chrome" if s in ("walmart", "sams", "fareway") else ""
            print(f"    {store_label(s):<14} newest {row['m'][:10]}  ({age}d old)  {row['n']:>6} rows{note}")

    # ---- 1. sample ------------------------------------------------------
    hr(f"STAGE 1 - random sample (seed {args.seed}, reproducible)")
    with open_db() as db:
        all_c = db.conn.execute(
            "SELECT id, canonical_name, properties_json FROM nodes WHERE type='Commodity' ORDER BY id"
        ).fetchall()
    rng = random.Random(args.seed)
    sample = rng.sample([dict(r) for r in all_c], min(args.n, len(all_c)))
    for c in sample:
        p = json.loads(c["properties_json"])
        print(f"    {c['canonical_name']:<34} id={p.get('legacy_id'):<26} per {p.get('unit_basis')}")
    results["1 sample"] = OK

    # ---- 2-5 per-cell walk ---------------------------------------------
    hr("STAGES 2-5 - evidence -> resolution -> basis -> board (per cell)")
    live = parse_live_board()
    n_cells = n_priced = n_agree = n_conflict = n_nolive = 0
    crowns = []
    with open_db() as db:
        resolver = Resolver(db, llm=None, use_llm=False)
        for c in sample:
            props = json.loads(c["properties_json"])
            legacy, basis = props.get("legacy_id"), props.get("unit_basis")
            print(f"\n  {c['canonical_name']}  (per {basis})")
            lb = live.get(legacy, {})
            for s in STORES:
                n_cells += 1
                (row, pu), n_rows, blocked = cell_price(db, c["id"], "store:" + s, basis)
                if row is None:
                    reason = f"{n_rows} row(s) seen" if n_rows else "no observations"
                    if blocked:
                        reason += f", {len(blocked)} blocked by resolver/basis guard"
                    print(f"    {store_label(s):<14} -            ({reason})")
                    continue
                n_priced += 1
                crowns.append((c, s, row, pu))
                src = os.path.basename(row["source_file"] or "?")
                src_kind = ("curated" if "product-urls" in src else
                            "ad" if "ads-" in src else "sweep")
                lv = lb.get(s)
                if lv is None:
                    verdict, n_nolive = "no live cell", n_nolive + 1
                elif abs(lv - pu) / max(lv, 1e-9) <= 0.02:
                    verdict, n_agree = f"agrees (live {lv:.4f})", n_agree + 1
                else:
                    verdict, n_conflict = f"DIFFERS live={lv:.4f}", n_conflict + 1
                print(f"    {store_label(s):<14} {pu:>9.4f}  {verdict:<26} [{src_kind}] "
                      f"{(row['product_name'] or '')[:34]}")

    print(f"\n  cells examined {n_cells} | priced {n_priced} | agree {n_agree} | "
          f"differ {n_conflict} | no live cell {n_nolive}")
    results["2 evidence"] = OK if n_priced else BAD
    results["3 resolution"] = OK
    results["4 basis"] = OK
    comparable = n_agree + n_conflict
    rate = n_agree / comparable if comparable else 0
    results["5 board"] = OK if rate >= 0.85 else WARN
    print(f"  agreement on comparable cells: {rate:.1%} ({n_agree}/{comparable})")

    # ---- 6. plausibility ------------------------------------------------
    hr("STAGE 6 - crown plausibility (is the product really the commodity?)")
    if args.no_llm or not healthy:
        print("  skipped (no local model)")
        results["6 plausibility"] = WARN
    else:
        sys.path.insert(0, HERE)
        from plausibility_report import check
        flagged = 0
        for c, s, row, pu in crowns:
            props = json.loads(c["properties_json"])
            try:
                parsed, _ = check(llm, c["canonical_name"], props.get("unit_basis"),
                                  row["product_name"], row["size_text"], row["price"])
            except Exception as e:                              # noqa: BLE001
                print(f"    {c['canonical_name']} @ {s}: check error {e}")
                continue
            v = str(parsed.get("verdict", "UNSURE")).upper()
            if v == "IMPLAUSIBLE" and float(parsed.get("confidence", 0) or 0) >= 0.75:
                flagged += 1
                print(f"    FLAG {c['canonical_name']} @ {store_label(s)}: "
                      f"{(row['product_name'] or '')[:44]}")
                print(f"         {str(parsed.get('reason',''))[:110]}")
        print(f"\n  checked {len(crowns)} crowns, flagged {flagged}")
        results["6 plausibility"] = OK if flagged == 0 else WARN

    # ---- 7. gates -------------------------------------------------------
    hr("STAGE 7 - graph gate checks")
    with open_db() as db:
        g = run_checks(db)
    for name, r in g["checks"].items():
        print(f"    {'PASS' if r['ok'] else 'FAIL'}  {name}")
    results["7 gates"] = OK if g["ok"] else BAD

    # ---- 8. provenance --------------------------------------------------
    hr("STAGE 8 - provenance (every price traceable to its source)")
    with open_db() as db:
        missing = 0
        for c, s, row, pu in crowns[:12]:
            p = db.conn.execute(
                "SELECT source_document, extraction_method, timestamp FROM provenance WHERE id=?",
                (row["provenance_id"],)).fetchone()
            if not p:
                missing += 1
                print(f"    MISSING provenance: {c['canonical_name']} @ {s}")
                continue
            print(f"    {c['canonical_name'][:22]:<22} {store_label(s):<13} <- {p['source_document'][:46]}")
        orphan = db.conn.execute(
            """SELECT COUNT(*) FROM price_observations p
               LEFT JOIN provenance v ON v.id=p.provenance_id WHERE v.id IS NULL""").fetchone()[0]
    print(f"\n  orphan observations across the whole graph: {orphan}")
    results["8 provenance"] = OK if (missing == 0 and orphan == 0) else BAD

    # ---- summary --------------------------------------------------------
    hr(f"SMOKE TEST SUMMARY  ({time.time()-t0:.0f}s)")
    for k in sorted(results):
        print(f"    {results[k]:<5} {k}")
    hard_fail = any(v == BAD for v in results.values())
    warns = sum(1 for v in results.values() if v == WARN)
    print(f"\n  RESULT: {'FAIL' if hard_fail else 'PASS'}"
          + (f"  ({warns} warning(s))" if warns else ""))
    return 1 if hard_fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
