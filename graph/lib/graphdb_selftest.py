"""graphdb_selftest.py - the store layer's two I229 boundaries (backlog I229, 2026-09-18) and I214's constraints.

    python graph/lib/graphdb_selftest.py --selftest

WHAT IT GUARDS.

1. A MISSING DATABASE IS REFUSED. sqlite3.connect() creates whatever path it is handed, so GraphDB used
   to build a fresh, empty graph.db wherever an open_db() script ran (a worktree has none), restore the
   learning records into it, and answer every later question from an index with no nodes, edges or
   observations. It now raises GraphDBMissing unless the caller passes allow_new=True, which only
   graph/import/import_all.py and graph/lib/rebuild.py do.

2. A RESTORE COUNTS WHAT IT INSERTED. import_learning() used INSERT OR IGNORE and counted every row it
   OFFERED, so a cell-state.json whose rows were refused (a NULL key, a duplicate key) reported them as
   restored: 3 counted, 1 in the table. It now counts rowcount and puts the rest in restore_skipped.

3. A FRESH BUILD DECLARES ITS CONSTRAINTS (backlog I214, 2026-09-19). price_observations.price is positive or
   NULL (a 0.0 is refused), learning_proposals.status is one of its eight words, and ix_cell_adto is partial
   (WHERE ad_to IS NOT NULL) and still serves the ad-reversion readers' filter.

HERMETIC. Every database is a fresh file in a per-run temp directory; graphdb.DB_PATH is pointed there
for the open_db() case and restored in a finally. Nothing reads or writes graph/sqlite/graph.db or any
tracked JSON, and no case calls log_event, so the tracked graph/provenance trail is never touched.

EXIT: 0 all cases pass, 1 at least one failed. Read the verdict LINE, not the number.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import graphdb                                           # noqa: E402

_fails: list[str] = []
_ran = 0
CASES = 13


def T(label: str, ok: bool, got: str = "") -> None:
    global _ran
    _ran += 1
    if ok:
        print("  ok    " + label)
    else:
        _fails.append(label)
        print("  FAILED " + label + ("   got: " + got if got else ""))


def _raises_missing(fn) -> tuple[bool, str]:
    try:
        db = fn()
    except graphdb.GraphDBMissing as e:
        return True, str(e)[:80]
    except Exception as e:                                # noqa: BLE001
        return False, "raised %r instead" % (e,)
    db.conn.close()
    return False, "opened without raising"


def _refused(fn) -> tuple[bool, str]:
    """True when fn raises sqlite3.IntegrityError naming a CHECK constraint."""
    try:
        fn()
    except graphdb.sqlite3.IntegrityError as e:
        return "CHECK" in str(e), str(e)[:80]
    return False, "accepted"


def run() -> int:
    tmp = tempfile.mkdtemp(prefix="gdb-st-")
    saved_path = graphdb.DB_PATH
    try:
        # ---- 1. a missing database ------------------------------------------------------------
        missing = os.path.join(tmp, "nope", "graph.db")
        ok, got = _raises_missing(lambda: graphdb.GraphDB(missing, restore_learning=False))
        T("MUST FIRE  GraphDB on a MISSING path refuses (GraphDBMissing) instead of creating an empty "
          "index", ok and not os.path.exists(missing), got + " exists=%s" % os.path.exists(missing))

        graphdb.DB_PATH = os.path.join(tmp, "live-standin", "graph.db")
        ok, got = _raises_missing(lambda: graphdb.open_db())
        T("MUST FIRE  open_db() - the call every pipeline script makes - refuses a missing graph.db "
          "and leaves no file behind", ok and not os.path.exists(graphdb.DB_PATH),
          got + " exists=%s" % os.path.exists(graphdb.DB_PATH))
        ok, got = _raises_missing(lambda: graphdb.open_db(create=True))
        T("MUST FIRE  create=True is NOT the create flag - it re-runs the schema on an existing file "
          "and still refuses a missing one", ok and not os.path.exists(graphdb.DB_PATH), got)

        made = os.path.join(tmp, "new", "graph.db")
        db = graphdb.GraphDB(made, restore_learning=False, allow_new=True)
        tables = set(r[0] for r in db.conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        db.close()
        T("CLEAN TWIN  allow_new=True still builds a fresh database with the schema (the import_all "
          "and rebuild road)", os.path.exists(made) and {"nodes", "edges", "cell_state"} <= tables,
          "exists=%s tables=%d" % (os.path.exists(made), len(tables)))

        db = graphdb.GraphDB(made, restore_learning=False)
        n = db.conn.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]
        db.close()
        T("CLEAN TWIN  an EXISTING database opens with no flag at all, exactly as before", n == 0,
          "nodes=%s" % n)

        # ---- 2. a restore counts what it inserted ---------------------------------------------
        out = os.path.join(tmp, "tracked")
        good = {"commodity_id": "commodity:staple:eggs", "store_id": "store:aldi",
                "everyday_price": 1.0, "updated_at": "2026-09-18T00:00:00"}
        rows = [good,
                dict(good, commodity_id=None, everyday_price=2.0),      # NOT NULL key refused
                dict(good, everyday_price=3.0)]                         # duplicate key ignored
        os.makedirs(os.path.join(out, "state"))
        with open(os.path.join(out, "state", "cell-state.json"), "w", encoding="utf-8",
                  newline="\n") as fh:
            json.dump(rows, fh)
        rdb = graphdb.GraphDB(os.path.join(tmp, "restore.db"), restore_learning=False,
                              allow_new=True)
        restored = rdb.import_learning(out_dir=out)
        in_table = rdb.conn.execute("SELECT COUNT(*) FROM cell_state").fetchone()[0]
        price = rdb.conn.execute("SELECT everyday_price FROM cell_state").fetchone()[0]
        skipped = dict(rdb.restore_skipped)
        rdb.close()
        T("MUST FIRE  a restore that kept 1 row of 3 reports 1 restored, never 3",
          restored.get("cell_state") == 1 and in_table == 1,
          "restored=%s in_table=%s" % (restored.get("cell_state"), in_table))
        T("MUST FIRE  the 2 refused rows are COUNTED in restore_skipped, not dropped silently",
          skipped.get("cell_state") == 2, json.dumps(skipped))
        T("CLEAN TWIN  the row that did land is the first one offered, value intact (1.0)",
          price == 1.0, repr(price))

        # ---- 3. the constraints a fresh build declares (backlog I214) ---------------------------
        cdb = graphdb.GraphDB(os.path.join(tmp, "checks.db"), restore_learning=False,
                              allow_new=True)
        cdb.record_provenance("fixture", "selftest", "2026-09-19T00:00:00")
        prov = cdb.conn.execute("SELECT id FROM provenance").fetchone()[0]

        def obs(oid, price):
            return {"id": oid, "commodity_id": "commodity:staple:eggs", "store_id": "store:aldi",
                    "provenance_id": prov, "observed_at": "2026-09-19", "price": price}

        refused, got = _refused(lambda: cdb.add_observation(obs("po:zero", 0.0)))
        T("MUST FIRE  a price_observations row priced 0.0 is REFUSED by the CHECK (a zero is an "
          "unknown written as a price, I200)", refused, got)
        refused, got = _refused(lambda: cdb.add_observation(obs("po:null", None)))
        n_null = cdb.conn.execute(
            "SELECT count(*) FROM price_observations WHERE id='po:null' AND price IS NULL").fetchone()[0]
        T("CLEAN TWIN  a NULL price (unknown) still inserts - the CHECK passes NULL", not refused and
          n_null == 1, got + " rows=%d" % n_null)

        def lp(lid, status):
            cdb.conn.execute(
                "INSERT INTO learning_proposals (id, created_at, model, kind, payload_json, "
                "confidence, status) VALUES (?, '2026-09-19', 'fixture', 'add_alias', '{}', 0.5, ?)",
                (lid, status))

        refused, got = _refused(lambda: lp("lp:bogus", "approved"))
        T("MUST FIRE  a learning_proposals status outside its eight-word vocabulary ('approved') is "
          "REFUSED", refused, got)
        refused, got = _refused(lambda: lp("lp:ok", "held_for_human"))
        T("CLEAN TWIN  a status in the vocabulary ('held_for_human') still inserts", not refused, got)

        plan = " ".join(r[3] for r in cdb.conn.execute(
            "EXPLAIN QUERY PLAN SELECT commodity_id, store_id, ad_to FROM cell_state "
            "WHERE ad_to IS NOT NULL AND ad_to < ? AND reverted_checked_at IS NULL ORDER BY ad_to",
            ("2026-09-19",)))
        isql = cdb.conn.execute(
            "SELECT sql FROM sqlite_master WHERE name='ix_cell_adto'").fetchone()[0] or ""
        cdb.close()
        T("CLEAN TWIN  ix_cell_adto is PARTIAL (WHERE ad_to IS NOT NULL) and the readers' filter "
          "still searches it", "WHERE ad_to IS NOT NULL" in isql and "ix_cell_adto" in plan,
          "plan=%s sql=%s" % (plan, isql))
    except Exception as e:                                # noqa: BLE001
        _fails.append("suite raised: %r" % (e,))
        print("  FAILED suite raised: %r" % (e,))
    finally:
        graphdb.DB_PATH = saved_path
        shutil.rmtree(tmp, ignore_errors=True)

    if _ran != CASES and not _fails:
        _fails.append("ran %d of %d cases" % (_ran, CASES))
    if _fails:
        print("SELF-TEST FAIL: graphdb %d of %d case(s) failed, %d ran" % (len(_fails), CASES, _ran))
        return 1
    print("SELF-TEST PASS: graphdb %d of %d cases - a missing graph.db is refused unless allow_new, "
          "a restore counts only the rows it inserted, and a fresh build refuses a 0.0 price and an unknown proposal status" % (_ran, CASES))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(run())
    print("usage: graphdb_selftest.py --selftest")
    sys.exit(2)
