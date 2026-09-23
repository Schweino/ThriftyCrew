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

4. AN EXPORT RECONCILES BEFORE IT WRITES (2026-09-23, design/PLAN-graph-learning-reconcile-2026-09-23.md). A verdict
   committed from another checkout used to be reverted by this checkout's next export_learning(): 69 of 69 of Brad's
   2026-09-12 rulings on a stand-in. Each case builds the OTHER checkout's database, writes its tracked JSON with the
   pre-change export algorithm (so the files are exactly what a real export commits), then exports THIS checkout's
   database over them. The MUST FIREs are the D13 shape and the three other ways evidence arrives; the MUST NOT FIREs
   are a decision this checkout made later, which an older JSON must never undo.

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
import learning_reconcile                                # noqa: E402

_fails: list[str] = []
_ran = 0
CASES = 25


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


# ---- section 4 helpers: the other checkout's database, its tracked JSON, and this checkout's database ----------
def _prop(pid: str, status: str) -> dict:
    return {"id": pid, "created_at": "2026-09-12T00:00:00", "model": "fixture", "queue_hash": None,
            "kind": "add_alias", "target_id": "fixture-" + pid, "payload_json": json.dumps({"payload": "x " + pid}),
            "confidence": 0.5, "rationale": "fixture", "status": status}


def _patch(pid: str, verdict: str, shadow: str = "not_run", applied_at: str | None = None) -> dict:
    return {"id": "ap:%s:%s" % (pid, verdict), "proposal_id": pid, "reviewed_at": "2026-09-12T10:00:00",
            "reviewer": "fixture", "verdict": verdict, "payload_json": json.dumps({"payload": "x " + pid}),
            "rationale": None, "shadow_before_json": None, "shadow_after_json": None, "shadow_verdict": shadow,
            "applied_at": applied_at, "applied_by": "learning-loop" if applied_at else None}


def _eval(eid: str) -> dict:
    return {"id": eid, "run_at": "2026-09-12T00:00:00", "model": None, "prompt_version": "p", "gold_version": "g",
            "context": "fixture", "detail_json": "{}"}


def _db_with(path: str, props=(), patches=(), evals=(), cells=(), qvs=()) -> "graphdb.GraphDB":
    g = graphdb.GraphDB(path, allow_new=True, restore_learning=False)
    for table, rows in (("learning_proposals", props), ("approved_patches", patches), ("eval_runs", evals),
                        ("cell_state", cells), ("question_verdicts", qvs)):
        for r in rows:
            g.conn.execute("INSERT INTO %s (%s) VALUES (%s)" % (table, ", ".join(r), ", ".join("?" * len(r))),
                           list(r.values()))
    g.conn.commit()
    return g


def _old_export(g: "graphdb.GraphDB", out: str) -> None:
    """The export algorithm as it stood before 2026-09-23, byte for byte: the database over the files, no reconcile."""
    for table, fname in graphdb.GraphDB.LEARNING_TABLES:
        rows = [dict(r) for r in g.conn.execute("SELECT * FROM %s ORDER BY 1" % table).fetchall()]
        graphdb.write_json(os.path.join(out, fname), rows)


def _tracked(tmp: str, name: str, **rows) -> str:
    """Write the other checkout's tracked JSON into a fresh directory and return it."""
    out = os.path.join(tmp, name)
    g = _db_with(os.path.join(tmp, name + "-other.db"), **rows)
    _old_export(g, out)
    g.close()
    return out


def _status(g, pid):
    r = g.conn.execute("SELECT status FROM learning_proposals WHERE id=?", (pid,)).fetchone()
    return r[0] if r else None


def _file_rows(out: str, fname: str) -> dict:
    return {r["id"]: r for r in graphdb.read_json(os.path.join(out, fname))}


def _bytes(out: str) -> dict:
    res = {}
    for _, fname in graphdb.GraphDB.LEARNING_TABLES:
        with open(os.path.join(out, fname), "rb") as fh:
            res[fname] = fh.read()
    return res


def _reconcile_cases(tmp: str) -> None:
    P, A = "learning/proposals.json", "learning/approved-patches.json"

    # MUST FIRE, THE D13 SHAPE: two verdicts reached tracked JSON from another checkout; this database predates them.
    out = _tracked(tmp, "d13", props=[_prop("p1", "accepted"), _prop("p2", "rejected"), _prop("p3", "proposed")],
                   patches=[_patch("p1", "accept"), _patch("p2", "reject")], evals=[_eval("e1"), _eval("e3")])
    mine = _db_with(os.path.join(tmp, "d13-mine.db"),
                    props=[_prop("p1", "proposed"), _prop("p2", "proposed"), _prop("p3", "proposed"),
                           _prop("p4", "proposed")], evals=[_eval("e1"), _eval("e2")])
    mine.export_learning(out_dir=out)
    fp, fa = _file_rows(out, P), _file_rows(out, A)
    got = (_status(mine, "p1"), _status(mine, "p2"), fp["p1"]["status"], fp["p2"]["status"])
    T("MUST FIRE  D13: a verdict committed from another checkout survives this database's export, in the database "
      "and in the file it writes (accepted, rejected)", got == ("accepted", "rejected", "accepted", "rejected"),
      repr(got))
    in_db = [r[0] for r in mine.conn.execute("SELECT id FROM approved_patches ORDER BY id")]
    T("MUST FIRE  D13: each verdict's patch row exists after the export, in the database and in the file",
      in_db == ["ap:p1:accept", "ap:p2:reject"] and sorted(fa) == in_db, "db=%s file=%s" % (in_db, sorted(fa)))
    rep = mine.last_reconcile
    T("MUST FIRE  D13: the reconcile counts 2 statuses adopted and 2 patch rows inserted",
      rep.get("statuses_adopted") == 2 and rep.get("patches_inserted") == 2,
      json.dumps({k: rep.get(k) for k in ("statuses_adopted", "patches_inserted")}))
    fe = _file_rows(out, "eval/eval-runs.json")
    T("CLEAN TWIN  rows only this database holds survive (proposal p4, eval run e2), p3 stays proposed, and an "
      "eval run only the JSON holds (e3) is inserted", "p4" in fp and fp["p3"]["status"] == "proposed"
      and sorted(fe) == ["e1", "e2", "e3"], "props=%s evals=%s" % (sorted(fp), sorted(fe)))
    mine.close()

    # MUST NOT FIRE: a decision this checkout made after the JSON was written is never undone by it.
    out = _tracked(tmp, "newer", props=[_prop("p1", "proposed")])
    mine = _db_with(os.path.join(tmp, "newer-mine.db"), props=[_prop("p1", "rejected")],
                    patches=[_patch("p1", "reject")])
    mine.export_learning(out_dir=out)
    got = (_status(mine, "p1"), _file_rows(out, P)["p1"]["status"], sorted(_file_rows(out, A)),
           mine.last_reconcile.get("kept_db_newer"))
    T("MUST NOT FIRE a DB-side verdict newer than the tracked row is kept (rejected, its patch row, kept_db_newer=1)",
      got == ("rejected", "rejected", ["ap:p1:reject"], 1), repr(got))
    mine.close()

    # MUST NOT FIRE: a requeue made here (accepted -> proposed, patch requeued) is not undone by an older 'accepted'.
    out = _tracked(tmp, "requeued-here", props=[_prop("p1", "accepted")], patches=[_patch("p1", "accept")])
    mine = _db_with(os.path.join(tmp, "requeued-here-mine.db"), props=[_prop("p1", "proposed")],
                    patches=[_patch("p1", "accept", shadow="requeued")])
    mine.export_learning(out_dir=out)
    sv = mine.conn.execute("SELECT shadow_verdict FROM approved_patches").fetchone()[0]
    T("MUST NOT FIRE a DB-side requeue is kept against an older JSON still saying accepted (proposed, requeued)",
      (_status(mine, "p1"), sv) == ("proposed", "requeued"), repr((_status(mine, "p1"), sv)))
    mine.close()

    # MUST FIRE: a requeue made elsewhere is adopted - evidence, not "a reviewed status beats proposed".
    out = _tracked(tmp, "requeued-there", props=[_prop("p1", "proposed")],
                   patches=[_patch("p1", "accept", shadow="requeued")])
    mine = _db_with(os.path.join(tmp, "requeued-there-mine.db"), props=[_prop("p1", "accepted")],
                    patches=[_patch("p1", "accept")])
    mine.export_learning(out_dir=out)
    sv = mine.conn.execute("SELECT shadow_verdict FROM approved_patches").fetchone()[0]
    rep = mine.last_reconcile
    T("MUST FIRE  a requeue made in another checkout is adopted (proposed, requeued, 1 patch advanced)",
      (_status(mine, "p1"), sv, rep.get("patches_advanced")) == ("proposed", "requeued", 1),
      repr((_status(mine, "p1"), sv, rep.get("patches_advanced"))))
    mine.close()

    # MUST FIRE: a git merge kept the patch file's new row and lost the status line - the arrived verdict carries it.
    out = _tracked(tmp, "lost-line", props=[_prop("p1", "proposed")], patches=[_patch("p1", "accept")])
    mine = _db_with(os.path.join(tmp, "lost-line-mine.db"), props=[_prop("p1", "proposed")])
    mine.export_learning(out_dir=out)
    got = (_status(mine, "p1"), mine.last_reconcile.get("statuses_from_arrived_patch"))
    T("MUST FIRE  a patch row that arrives beside a status still 'proposed' on both sides sets the status from its "
      "verdict (accepted)", got == ("accepted", 1), repr(got))
    mine.close()

    # MUST NOT FIRE: equal evidence cannot order a status move without a clock; the database keeps its own.
    out = _tracked(tmp, "equal", props=[_prop("p1", "accepted")], patches=[_patch("p1", "accept")])
    mine = _db_with(os.path.join(tmp, "equal-mine.db"), props=[_prop("p1", "held_for_human")],
                    patches=[_patch("p1", "accept")])
    mine.export_learning(out_dir=out)
    got = (_status(mine, "p1"), mine.last_reconcile.get("undecided"), mine.last_reconcile.get("statuses_adopted"))
    T("MUST NOT FIRE equal evidence with a different status keeps the database's (held_for_human) and counts it "
      "undecided", got == ("held_for_human", 1, 0), repr(got))
    mine.close()

    # MUST FIRE: conflict markers in a tracked file refuse the export before a byte is written.
    out = _tracked(tmp, "markers", props=[_prop("p1", "accepted")], patches=[_patch("p1", "accept")])
    pj = os.path.join(out, P)
    with open(pj, "r", encoding="utf-8") as fh:
        text = fh.read()
    with open(pj, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("<<<<<<< Updated upstream\n" + text + "=======\n" + text + ">>>>>>> Stashed changes\n")
    before = _bytes(out)
    mine = _db_with(os.path.join(tmp, "markers-mine.db"), props=[_prop("p1", "proposed")])
    try:
        mine.export_learning(out_dir=out)
        raised = "no exception"
    except learning_reconcile.LearningMirrorUnreadable as e:
        raised = "refused: " + str(e)[:40]
    n_patch = mine.conn.execute("SELECT COUNT(*) FROM approved_patches").fetchone()[0]
    T("MUST FIRE  a tracked file with merge conflict markers refuses the export; no mirror file changes by a byte "
      "and nothing is adopted", raised.startswith("refused") and _bytes(out) == before and n_patch == 0,
      "%s, files unchanged=%s, patches=%d" % (raised, _bytes(out) == before, n_patch))
    mine.close()

    # CLEAN TWIN: a fresh database's restore is unchanged - every row of all five tables, counted as inserted.
    cell = {"commodity_id": "commodity:staple:eggs", "store_id": "store:aldi", "everyday_price": 1.5,
            "updated_at": "2026-09-12T00:00:00"}
    qv = {"commodity_id": "commodity:staple:eggs", "product_key": "large eggs", "product_name": "Large Eggs",
          "status": "include_hit", "decided_at": "2026-09-12T00:00:00"}
    out = _tracked(tmp, "fresh", props=[_prop("p1", "accepted"), _prop("p2", "proposed")],
                   patches=[_patch("p1", "accept")], evals=[_eval("e1")], cells=[cell], qvs=[qv])
    fresh = graphdb.GraphDB(os.path.join(tmp, "fresh-restore.db"), allow_new=True, restore_learning=False)
    restored = fresh.import_learning(out_dir=out)
    want = {"learning_proposals": 2, "approved_patches": 1, "eval_runs": 1, "cell_state": 1, "question_verdicts": 1}
    T("CLEAN TWIN  a fresh-database restore is unchanged: 6 rows over 5 tables restored and counted "
      "(2, 1, 1, 1, 1)", restored == want and _status(fresh, "p1") == "accepted", json.dumps(restored))

    # CLEAN TWIN: with nothing to reconcile the export is byte-identical to the pre-change algorithm's, and the
    # database is not written at all.
    expect = os.path.join(tmp, "fresh-expected")
    _old_export(fresh, expect)
    changes = fresh.conn.total_changes
    fresh.export_learning(out_dir=out)
    same = _bytes(out) == _bytes(expect)
    wrote = fresh.conn.total_changes - changes
    T("CLEAN TWIN  an export with nothing to reconcile writes all 5 files byte-identical to today's algorithm and "
      "writes 0 database rows", same and wrote == 0 and learning_reconcile.noteworthy(fresh.last_reconcile) == 0,
      "identical=%s rows_written=%d noteworthy=%d" % (same, wrote, learning_reconcile.noteworthy(fresh.last_reconcile)))
    fresh.close()


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

        # ---- 4. an export reconciles the tracked learning JSON before it writes ----------------
        _reconcile_cases(tmp)
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
          "a restore counts only the rows it inserted, a fresh build refuses a 0.0 price and an unknown proposal status, "
          "and an export keeps a verdict committed from another checkout" % (_ran, CASES))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(run())
    print("usage: graphdb_selftest.py --selftest")
    sys.exit(2)
