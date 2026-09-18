"""graphdb_selftest.py - the store layer's two I229 boundaries (backlog I229, 2026-09-18).

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
CASES = 8


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
          "and a restore counts only the rows it inserted" % (_ran, CASES))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(run())
    print("usage: graphdb_selftest.py --selftest")
    sys.exit(2)
