"""importers_selftest.py - the product-urls importer's price boundary (backlog I200, 2026-09-18).

    python graph/import/importers_selftest.py --selftest

WHY THIS FILE EXISTS. graph\\import was covered by nothing that run-gates runs: no --selftest, and the
only other importer of importers.py is import_all.py, which rebuilds the real index. So the one rule
I200 added had no fixture of any kind.

WHAT IT GUARDS. grocery/product-urls.json carries `"price": 0` on 53 entries (measured 2026-09-18): the
2026-07-08 store backfill captured a per-unit figure only and wrote a zero beside `recipe_pu`. The
importer passed that zero straight through, graph.db held 34 rows priced 0.0 (the other 19 have no
commodity node), and graph/pipeline/state.py's `price IS NOT NULL` admits a zero. Probed on a copy:
the 3 of them banked llm_match_unverified, given a reviewer CONFIRM and a current observed date,
priced 3 cells at 0.0. A zero is an unknown, so it is stored as NULL, which that filter already
refuses, and the row is KEPT as evidence.

HERMETIC. A temp directory holds the fixture product-urls.json and a fresh temp database; the module's
GROCERY constant is pointed there for the run, and GraphDB._append_jsonl (the tracked graph/provenance
trail) is replaced for the whole suite so no fixture writes a tracked file. Nothing reads graph.db.

EXIT: 0 all cases pass, 1 at least one failed. Read the verdict LINE, not the number.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "graph", "lib"))

import graphdb                                           # noqa: E402
import importers as I                                    # noqa: E402

_fails: list[str] = []
_ran = 0
CASES = 6


def T(label: str, ok: bool, got: str = "") -> None:
    global _ran
    _ran += 1
    if ok:
        print("  ok    " + label)
    else:
        _fails.append(label)
        print("  FAILED " + label + ("   got: " + got if got else ""))


def _fixture_doc() -> dict:
    return {
        "updated": "2026-08-29",
        "items": {
            "fixture-sauce": {
                "commodity": "Fixture Sauce",
                # the founding shape: a link with a per-unit figure and a zero price
                "Walmart": {"url": "https://example.invalid/w", "price": 0, "size": "16 oz",
                            "name": "Fixture Zero Sauce", "recipe_pu": 0.2},
                # the same unknown spelled as text
                "Sam's Club": {"url": "https://example.invalid/s", "price": "$0.00", "size": "1 gal",
                               "name": "Fixture Text Zero Sauce", "recipe_pu": 0.13},
                # a real shelf price, which must arrive untouched
                "Aldi": {"url": "https://example.invalid/a", "price": 3.49, "size": "12 oz",
                         "name": "Fixture Real Sauce", "verified": "2026-09-01"},
            }
        },
    }


def run() -> int:
    tmp = tempfile.mkdtemp(prefix="i200-imp-")
    saved_grocery = I.GROCERY
    saved_append = graphdb.GraphDB._append_jsonl
    graphdb.GraphDB._append_jsonl = staticmethod(lambda run, record: None)
    db = None
    try:
        gro = os.path.join(tmp, "grocery")
        os.makedirs(gro)
        with open(os.path.join(gro, "product-urls.json"), "w", encoding="utf-8", newline="\n") as fh:
            json.dump(_fixture_doc(), fh)
        I.GROCERY = gro
        db = graphdb.GraphDB(os.path.join(tmp, "g.db"), restore_learning=False)
        ts = "2026-09-18T00:00:00"
        cid = I.commodity_id("fixture-sauce", "recipe")
        db.upsert_node(cid, "Commodity", "Fixture Sauce", ts)

        res = I.import_product_url_prices(db, ts, "run:i200-selftest")
        rows = {r["store_id"]: r for r in db.conn.execute(
            "SELECT store_id, price, match_status FROM price_observations WHERE commodity_id=?",
            (cid,))}
        w = rows.get(I.store_id("Walmart"))
        s = rows.get(I.store_id("Sam's Club"))
        a = rows.get(I.store_id("Aldi"))

        T("MUST FIRE a product-urls price of 0 lands as NULL, never 0.0",
          w is not None and w["price"] is None, repr(None if w is None else w["price"]))
        T("MUST FIRE a product-urls price of '$0.00' lands as NULL, never 0.0",
          s is not None and s["price"] is None, repr(None if s is None else s["price"]))
        n_nonpos = db.conn.execute(
            "SELECT count(*) FROM price_observations WHERE price <= 0").fetchone()[0]
        T("MUST FIRE the table holds no price <= 0 after the import", n_nonpos == 0, str(n_nonpos))
        T("CLEAN TWIN a positive shelf price arrives unchanged (3.49)",
          a is not None and a["price"] == 3.49, repr(None if a is None else a["price"]))
        T("CLEAN TWIN every entry still leaves its evidence row (3 of 3)", len(rows) == 3, str(len(rows)))
        T("CLEAN TWIN the run reports what it nulled (2) and wrote (3)",
          res.get("product_url_zero_price_nulled") == 2 and res.get("product_url_observations") == 3,
          json.dumps(res, sort_keys=True))
    except Exception as e:                                # noqa: BLE001
        _fails.append("suite raised: %r" % (e,))
        print("  FAILED suite raised: %r" % (e,))
    finally:
        I.GROCERY = saved_grocery
        graphdb.GraphDB._append_jsonl = saved_append
        if db is not None:
            db.conn.close()
        shutil.rmtree(tmp, ignore_errors=True)

    if _ran != CASES and not _fails:
        _fails.append("ran %d of %d cases" % (_ran, CASES))
    if _fails:
        print("SELF-TEST FAIL: %d of %d case(s) failed, %d ran" % (len(_fails), CASES, _ran))
        return 1
    print("SELF-TEST PASS: importers %d of %d cases - a zero product-urls price is stored NULL, "
          "a real one unchanged" % (_ran, CASES))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(run())
    print("usage: importers_selftest.py --selftest")
    sys.exit(2)
