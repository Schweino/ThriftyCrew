"""importers_selftest.py - the product-urls importer's price boundary (backlog I200, 2026-09-18), the capture
lanes' commodity-id search terms and the fareway-shop observed_at (backlog I235, same day), and the
supersede guard that stops every import re-inserting what the last prune deleted (backlog I211, 2026-09-19).

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
sys.path.insert(0, os.path.join(REPO, "graph", "pipeline"))
sys.path.insert(0, os.path.join(REPO, "graph", "lib"))

import graphdb                                           # noqa: E402
import importers as I                                    # noqa: E402

_fails: list[str] = []
_ran = 0
CASES = 27


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


def _fresh(tmp: str) -> "graphdb.GraphDB":
    return graphdb.GraphDB(os.path.join(tmp, "g.db"), restore_learning=False, allow_new=True)


def _write(path: str, doc) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(doc, fh)


def _deal(item: str, term: str, price: float) -> dict:
    return {"store": "Baker's", "item": item, "current_price": price, "size": "16 oz",
            "as_of": "2026-09-18", "found_by_term": term}


def run_capture_terms() -> None:
    """Backlog I235: a capture whose found_by_term is a commodity ID, not a search term.

    grocery/pull-regular-bakers-api.ps1 writes `found_by_term = $id` on purpose (its carry-merge
    keys on it), and only search-term aliases resolved, so 229,788 Baker's rows per run were
    dropped. The id resolves only as the NAMESPACED node `commodity:staple:<id>`, only when that
    node exists, and only after the alias lookup has had its turn.
    """
    tmp = tempfile.mkdtemp(prefix="i235-imp-")
    saved_grocery = I.GROCERY
    db = None
    try:
        gro = os.path.join(tmp, "grocery")
        I.GROCERY = gro
        db = _fresh(tmp)
        ts = "2026-09-18T00:00:00"
        db.upsert_node(I.store_id("Baker's"), "Store", "Baker's", ts)
        almonds = I.commodity_id("almonds", "staple")
        nuts = I.commodity_id("mixed-nuts", "staple")
        bread = I.commodity_id("bread", "staple")
        for nid, label in ((almonds, "Almonds"), (nuts, "Mixed Nuts"), (bread, "Bread")):
            db.upsert_node(nid, "Commodity", label, ts)
        # an id that exists ONLY in the recipe namespace
        db.upsert_node(I.commodity_id("hot-honey", "recipe"), "Commodity", "Hot Honey", ts)
        # the alias path: "sandwich bread" is bread's search term, and "almonds" is (in this
        # fixture) the search term of a DIFFERENT node than its id-namesake, so alias-first shows
        db.add_alias(bread, "sandwich bread", "fixture", ts, kind="search_term")
        db.add_alias(nuts, "almonds", "fixture", ts, kind="search_term")

        _write(os.path.join(gro, "out", "regular", "bakers-regular-2026-09-18.json"), {
            "store": "Baker's", "captured": "2026-09-18", "price_type": "everyday",
            "deals": [
                _deal("Fixture Bread Loaf", "bread", 1.19),               # staple id, not an alias
                _deal("Fixture Sandwich Bread", "sandwich bread", 2.49),  # alias
                _deal("Fixture Almonds", "almonds", 10.99),               # alias AND an id
                _deal("Fixture Unknown", "no-such-commodity", 3.00),      # neither
                _deal("Fixture Hot Honey", "hot-honey", 6.49),            # recipe-only id
                _deal("Fixture No Term", "", 1.00),                       # no term
            ]})
        res = I.import_observations(db, ts, "run:i235-selftest", dirs=("regular",))
        by_item = {r["product_name"]: r["commodity_id"] for r in db.conn.execute(
            "SELECT product_name, commodity_id FROM price_observations")}

        T("MUST FIRE a found_by_term that is a staple id resolves to commodity:staple:bread",
          by_item.get("Fixture Bread Loaf") == bread, repr(by_item.get("Fixture Bread Loaf")))
        T("MUST FIRE the run counts the row it resolved by staple id (1)",
          res.get("resolved_by_staple_id_rows") == 1, json.dumps(res, sort_keys=True))
        T("MUST NOT FIRE an id with no commodity:staple node stays unresolved (no row written)",
          "Fixture Unknown" not in by_item, repr(by_item.get("Fixture Unknown")))
        T("MUST NOT FIRE a recipe-only id is not resolved, bare or namespaced",
          "Fixture Hot Honey" not in by_item, repr(by_item.get("Fixture Hot Honey")))
        n_bare = db.conn.execute("SELECT count(*) FROM price_observations "
                                 "WHERE commodity_id NOT LIKE 'commodity:%'").fetchone()[0]
        T("MUST NOT FIRE no observation is keyed on a bare id", n_bare == 0, str(n_bare))
        T("MUST NOT FIRE the unknown term is counted (unknown 2, unresolved 3 with the empty term)",
          res.get("unresolved_unknown_term_rows") == 2 and res.get("unresolved_rows") == 3,
          json.dumps(res, sort_keys=True))
        T("CLEAN TWIN an alias term resolves to its node as before (sandwich bread -> bread)",
          by_item.get("Fixture Sandwich Bread") == bread, repr(by_item.get("Fixture Sandwich Bread")))
        T("CLEAN TWIN the alias wins over a same-named id (almonds -> mixed-nuts, not almonds)",
          by_item.get("Fixture Almonds") == nuts, repr(by_item.get("Fixture Almonds")))
        T("CLEAN TWIN the run writes the 3 resolvable rows", res.get("observations") == 3,
          json.dumps(res, sort_keys=True))
    except Exception as e:                                # noqa: BLE001
        _fails.append("capture-terms suite raised: %r" % (e,))
        print("  FAILED capture-terms suite raised: %r" % (e,))
    finally:
        I.GROCERY = saved_grocery
        if db is not None:
            db.conn.close()
        shutil.rmtree(tmp, ignore_errors=True)


def run_fareway_dates() -> None:
    """Backlog I235: import_fareway_shop built observed_at from the file NAME, so
    fareway-shop-rescue-2026-09-10.json stored observed_at='rescue-2026-09-10' on 8 rows."""
    tmp = tempfile.mkdtemp(prefix="i235-fw-")
    saved_grocery = I.GROCERY
    db = None
    try:
        gro = os.path.join(tmp, "grocery")
        I.GROCERY = gro
        db = _fresh(tmp)
        ts = "2026-09-18T00:00:00"
        db.upsert_node(I.store_id("Fareway"), "Store", "Fareway", ts)
        cid = I.commodity_id("cauliflower", "staple")
        db.upsert_node(cid, "Commodity", "Cauliflower", ts)
        fw = os.path.join(gro, "out", "fareway")
        _write(os.path.join(fw, "fareway-shop-rescue-2026-09-10.json"),
               [{"id": "cauliflower", "name": "Fixture Rescue Cauliflower", "price": 1.98}])
        _write(os.path.join(fw, "fareway-shop-2026-09-11.json"),
               [{"id": "cauliflower", "name": "Fixture Dated Cauliflower", "price": 2.29}])
        _write(os.path.join(fw, "fareway-shop-rescue.json"),
               [{"id": "cauliflower", "name": "Fixture Undated Cauliflower", "price": 2.99}])
        # the row the OLD rule left behind for the rescue file
        prov = db.record_provenance("grocery/out/fareway/fareway-shop-rescue-2026-09-10.json",
                                    "import:fareway-shop", ts, run="run:old")
        db.add_observation({"id": "obs:fixture-legacy", "commodity_id": cid,
                            "store_id": I.store_id("Fareway"),
                            "product_name": "Fixture Rescue Cauliflower", "price": 1.98,
                            "provenance_id": prov, "observed_at": "rescue-2026-09-10",
                            "source_file": I.rel(os.path.join(fw, "fareway-shop-rescue-2026-09-10.json")),
                            "match_status": "include_hit"})
        res = I.import_fareway_shop(db, ts, "run:i235-fw-selftest")
        got = {r["product_name"]: r["observed_at"] for r in db.conn.execute(
            "SELECT product_name, observed_at FROM price_observations")}
        n_nondate = db.conn.execute("SELECT count(*) FROM price_observations "
                                    "WHERE observed_at NOT GLOB '[0-9][0-9][0-9][0-9]-*'").fetchone()[0]

        T("MUST FIRE a 'rescue-2026-09-10' file name dates its rows 2026-09-10",
          got.get("Fixture Rescue Cauliflower") == "2026-09-10", repr(got.get("Fixture Rescue Cauliflower")))
        T("MUST FIRE the row the old rule wrote with a non-date is replaced (1), none remain",
          res.get("fareway_nondate_rows_replaced") == 1 and n_nondate == 0,
          "replaced=%r nondate=%d" % (res.get("fareway_nondate_rows_replaced"), n_nondate))
        T("MUST FIRE a file name with no date is refused and counted (1), no row written",
          res.get("fareway_files_undated_refused") == 1 and "Fixture Undated Cauliflower" not in got,
          json.dumps(res, sort_keys=True))
        T("CLEAN TWIN a dated file keeps its date (2026-09-11)",
          got.get("Fixture Dated Cauliflower") == "2026-09-11", repr(got.get("Fixture Dated Cauliflower")))
    except Exception as e:                                # noqa: BLE001
        _fails.append("fareway-dates suite raised: %r" % (e,))
        print("  FAILED fareway-dates suite raised: %r" % (e,))
    finally:
        I.GROCERY = saved_grocery
        if db is not None:
            db.conn.close()
        shutil.rmtree(tmp, ignore_errors=True)


def _pb(item: str, price, as_of: str, size: str = "16 oz") -> dict:
    return {"store": "Baker's", "item": item, "current_price": price, "size": size,
            "as_of": as_of, "found_by_term": "peanut butter"}


def _cycle(db, ts: str, run: str) -> tuple[dict, dict, set]:
    """One import_all --observations pass over the regular lane: import, resolve, state, prune."""
    import state as S                                              # noqa: PLC0415
    from resolve import Resolver                                   # noqa: PLC0415
    before = {r[0] for r in db.conn.execute("SELECT id FROM price_observations")}
    res = I.import_observations(db, ts, run, dirs=("regular",))
    after = {r[0] for r in db.conn.execute("SELECT id FROM price_observations")}
    Resolver(db, use_llm=False).resolve_pending(run=run, ts=ts, allow_llm=False)
    S.build_cell_state(db, ts)
    S.build_question_verdicts(db, ts)
    pr = S.supersede_prune(db, ts)
    return res, pr, after - before


def run_supersede_guard() -> None:
    """Backlog I211: the importer re-inserted every row the last prune deleted, every run.

    Measured on a backup-API copy of the live graph.db over the captures at f4e50313b: 477,950
    rows inserted and 477,950 pruned by one import, so the file's size was the import's peak. The
    guard (graph/lib/supersede.py) leaves out an absent row the prune would delete, and only when
    nothing tonight reads it; a present row is always upserted, and files are never skipped.
    """
    tmp = tempfile.mkdtemp(prefix="i211-imp-")
    saved_grocery = I.GROCERY
    db = None
    try:
        gro = os.path.join(tmp, "grocery")
        I.GROCERY = gro
        db = _fresh(tmp)
        ts0 = "2026-09-02T00:00:00"
        db.upsert_node(I.store_id("Baker's"), "Store", "Baker's", ts0)
        pb = I.commodity_id("peanut-butter", "staple")
        db.upsert_node(pb, "Commodity", "Peanut Butter", ts0, properties={"unit_basis": "oz"})
        db.add_alias(pb, "peanut butter", "fixture", ts0, kind="search_term")
        db.add_alias(pb, "peanut butter", "fixture", ts0, kind="include", is_regex=True)
        reg = os.path.join(gro, "out", "regular")

        def cap(day: str, deals: list) -> None:
            _write(os.path.join(reg, "bakers-regular-%s.json" % day),
                   {"store": "Baker's", "captured": day, "price_type": "everyday", "deals": deals})

        # Three sightings of two products. "Peanut Butter" matches the include pattern and prices
        # the cell, so the prune keeps its evidence (09-02) and newest other row (09-01) and deletes
        # 08-31. "Almond Butter" matches nothing (no_include_hit), so only its 09-02 row survives.
        pbn, abn = "Fixture Peanut Butter 16 oz", "Fixture Almond Butter 16 oz"
        cap("2026-08-31", [_pb(pbn, 1.90, "2026-08-31"), _pb(abn, 4.00, "2026-08-31")])
        cap("2026-09-01", [_pb(pbn, 2.00, "2026-09-01"), _pb(abn, 4.10, "2026-09-01")])
        cap("2026-09-02", [_pb(pbn, 2.10, "2026-09-02"), _pb(abn, 4.20, "2026-09-02")])
        _res1, pr1, new1 = _cycle(db, ts0, "run:i211-1")
        # Run 2, the SAME captures: the founding defect re-inserted the 3 rows run 1 pruned.
        res2, pr2, new2 = _cycle(db, "2026-09-02T01:00:00", "run:i211-2")
        T("MUST FIRE a re-import of unchanged captures inserts 0 rows (run 1 inserted %d, pruned %d)"
          % (len(new1), pr1["superseded"]),
          len(new1) == 6 and pr1["superseded"] == 3 and not new2,
          "run1 new=%d pruned=%d run2 new=%s" % (len(new1), pr1["superseded"], sorted(new2)))
        T("MUST FIRE ... and the prune after it deletes 0, the guard counting the 3 rows it left out",
          pr2["superseded"] == 0 and res2.get("skipped_already_superseded_rows") == 3,
          "pruned=%d %s" % (pr2["superseded"], json.dumps(res2, sort_keys=True)))

        cap("2026-09-03", [_pb(pbn, 2.20, "2026-09-03"), _pb(abn, 4.30, "2026-09-03")])
        _res3, pr3, new3 = _cycle(db, "2026-09-03T00:00:00", "run:i211-3")
        left = {r["observed_at"]: r["price"] for r in db.conn.execute(
            "SELECT observed_at, price FROM price_observations WHERE product_name=?", (pbn,))}
        ev = db.conn.execute("SELECT everyday_asof, everyday_price FROM cell_state "
                             "WHERE commodity_id=?", (pb,)).fetchone()
        T("CLEAN TWIN a new capture's row is inserted, prices the cell, and the prune moves up one "
          "(09-01 superseded; 09-03 evidence and 09-02 kept)",
          left == {"2026-09-03": 2.20, "2026-09-02": 2.10}
          and ev is not None and tuple(ev) == ("2026-09-03", 2.20),
          "new=%d pruned=%d left=%r cell=%r" % (len(new3), pr3["superseded"], left,
                                                 None if ev is None else tuple(ev)))
        # The same, for a row that prices nothing: nothing tonight READS it, but it is the newest
        # sighting, so it is the prune's survivor and tomorrow's reason to leave the older ones out.
        # Rule 2 cannot rescue it, so this is the case that sees rule 1's ORDER (09-03 is ahead).
        ab = {r["observed_at"]: r["match_status"] for r in db.conn.execute(
            "SELECT observed_at, match_status FROM price_observations WHERE product_name=?", (abn,))}
        T("CLEAN TWIN a new capture's row that prices nothing is inserted too, and supersedes 09-02 "
          "(2 new, 2 pruned in all)",
          ab == {"2026-09-03": "no_include_hit"} and len(new3) == 2 and pr3["superseded"] == 2,
          "almond=%r new=%d pruned=%d" % (ab, len(new3), pr3["superseded"]))

        # The 09-03 capture is rebuilt under the SAME name: a new price, and a product it lacked.
        cap("2026-09-03", [_pb(pbn, 2.30, "2026-09-03"), _pb(abn, 4.30, "2026-09-03"),
                           _pb("Fixture Crunchy Peanut Butter 16 oz", 2.25, "2026-09-03")])
        _res4, _pr4, new4 = _cycle(db, "2026-09-03T06:00:00", "run:i211-4")
        got = {r["product_name"]: r["price"] for r in db.conn.execute(
            "SELECT product_name, price FROM price_observations WHERE observed_at='2026-09-03'")}
        T("MUST FIRE a capture rewritten under the same name is re-read: its new price lands (2.30) "
          "and its new product is inserted",
          got.get("Fixture Peanut Butter 16 oz") == 2.30
          and got.get("Fixture Crunchy Peanut Butter 16 oz") == 2.25 and len(new4) == 1,
          "got=%r new=%d" % (got, len(new4)))

        # Rules 2 and 3 on the guard alone, with the resolver's prediction stubbed. The founding
        # shapes are the paired run's: a newer sighting that cannot be priced (price None here, a
        # `24 fl oz` against an `oz` basis there) left the older sighting as the cell's price; and a
        # known-wrong ruling reached a question only through a re-inserted row.
        from supersede import SupersedeGuard                         # noqa: PLC0415
        prov = db.record_provenance("fixture", "fixture", ts0, run="run:i211-g")
        st = I.store_id("Baker's")
        db.conn.execute("DELETE FROM price_observations")
        for oid, name, price, day, status in (
                ("po:g-newer-unpriced", "Fixture Jar", None, "2026-09-03", "include_hit"),
                ("po:g-other", "Fixture Other Jar", 3.20, "2026-09-03", "include_hit"),
                ("po:g-reviewed", "Fixture Ruled Jar", 3.10, "2026-09-03", "llm_rejected")):
            db.add_observation({"id": oid, "commodity_id": pb, "store_id": st, "product_name": name,
                                "price": price, "size_text": "16 oz", "price_type": "everyday",
                                "provenance_id": prov, "observed_at": day, "source_file": "fixture",
                                "match_status": status})
        db.conn.execute("DELETE FROM cell_state")
        db.conn.execute("INSERT INTO cell_state (commodity_id, store_id, everyday_evidence, updated_at) "
                        "VALUES (?,?,?,?)", (pb, st, "po:g-other", ts0))
        verdict = {"Fixture Ruled Jar": "known_wrong"}
        g = SupersedeGuard(db, "2026-09-03T00:00:00",
                           lambda cid, name: verdict.get(name, "include_hit"))

        def absent(oid, name, price, day="2026-09-02"):
            row = {"price": price, "unit_price": None, "unit": None, "size_text": "16 oz",
                   "product_name": name, "price_type": "everyday", "ad_cycle_id": None,
                   "source_file": "fixture"}
            return g.already_superseded(oid, pb, st, name, "everyday", day, row=row)

        T("MUST FIRE an absent row whose only newer sighting cannot be priced, and that would beat "
          "the cell's best, is inserted (rule 2)",
          absent("po:g-cheap", "Fixture Jar", 1.00) is False
          and g.inserted_because.get("may_price_becomes_best") == 1, repr(g.inserted_because))
        T("CLEAN TWIN the same shape priced ABOVE the cell's best is still left out",
          absent("po:g-dear", "Fixture Jar", 4.00) is True and g.skipped == 1,
          repr(g.inserted_because))
        T("MUST FIRE an absent row predicted known_wrong, where the present one is only a reviewer "
          "rejection, is inserted (rule 3: it moves the verdict bank)",
          absent("po:g-kw", "Fixture Ruled Jar", 3.10, "2026-09-02") is False
          and g.inserted_because.get("may_bank") == 1, repr(g.inserted_because))
    except Exception as e:                                # noqa: BLE001
        _fails.append("supersede-guard suite raised: %r" % (e,))
        print("  FAILED supersede-guard suite raised: %r" % (e,))
    finally:
        I.GROCERY = saved_grocery
        if db is not None:
            db.conn.close()
        shutil.rmtree(tmp, ignore_errors=True)


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
        db = graphdb.GraphDB(os.path.join(tmp, "g.db"), restore_learning=False, allow_new=True)
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
        # I235's two groups run here, inside the provenance stub, each on its own temp tree
        run_capture_terms()
        run_fareway_dates()
        run_supersede_guard()
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
          "a real one unchanged; a staple-id capture term resolves namespaced, an unknown one stays counted; "
          "a fareway-shop file is dated from the date in its name or refused; a re-import inserts 0 "
          "rows the prune deletes, and a new or rewritten capture still lands" % (_ran, CASES))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(run())
    print("usage: importers_selftest.py --selftest")
    sys.exit(2)
