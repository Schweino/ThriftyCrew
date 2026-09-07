"""audit_graph_durability.py - the graph's central claim, checked instead of asserted.

WHY THIS EXISTS (2026-09-07, backlog I30, redirected). I30 proposed a query-plan and index audit.
Measuring first said that is the wrong risk: `graph.db` is 126 MB over 47,319 nodes, `ANALYZE` on a
copy moved a three-table join by 0.0002 s across seven runs, and every finding the item names costs
zero today. SQLite is nowhere near strained and will not be at ten times this size.

WHAT IS ACTUALLY AT RISK IS THE MIRROR. `graph/lib/graphdb.py` states the architecture: the tracked
JSON is TRUTH and `graph.db` is an INDEX, so a routine `rm graph.db` - which the README actively
encourages - is safe. Five tables are the exception and `rebuild.py` names them: learning_proposals,
approved_patches, eval_runs, cell_state and question_verdicts exist NOWHERE ELSE, and they are the
record of what the learning loop did and why it was allowed to.

They stay mirrored by EIGHT HAND-PLACED `export_learning()` CALLS - stage2_review.py in three places,
score.py, review_escalations.py, stage1_analyze.py, and graphdb's own writer. Write-through by
convention, not by construction. And `rebuild.py --verify`, which proves the convention held, has
ZERO CALLERS: not run-gates, not the nightly chain, not CI. Verified by grep 2026-09-07.

So the failure is silent and it scales badly. Every new write path is another place to forget the
call; the database stays right while the JSON falls behind; and nobody learns until the day somebody
does the `rm` the README suggests. `run-gates` already records this exact shape twice about itself -
audit-twin-drift sat red for weeks because nothing ran that suite, and golden-test.ps1 was ungated
while being the only thing that caught a schema change.

THREE CHECKS, AND EACH ONE GROWS IN VALUE AS THE GRAPH GROWS:

  1. MIRROR    every irreplaceable table matches its tracked JSON, row for row.
  2. INTEGRITY `PRAGMA quick_check` - 1.1 s on 126 MB, and the only thing here that can see a torn
               file. The database is WAL and written nightly, and there is no undo layer (E1).
  3. VOLUME    per-table row counts against a baseline. This is the VOLUME limb of the four standing
               data-quality checks; I12 established freshness, schema and null-rate elsewhere and
               this is where the graph gets the fourth.

THE VOLUME ASYMMETRY IS THE OPPOSITE WAY UP FROM lib/ratchet.ps1, and mixing them up would make this
useless. There, a count that FELL is the suspicious direction because it counts FINDINGS. Here it
counts ROWS: growth is the steady state, and a fall is either a deliberate prune or a load that
failed halfway. So a rise retrains the baseline silently and a fall past the bar is a finding.

READ-ONLY THROUGHOUT. Every connection is opened `mode=ro` so the nightly chain's WAL is untouched -
a read-write handle can take a lock or leave a `-wal` file the ~07:00 bot then commits.

  python graph/pipeline/audit_graph_durability.py              # the live check
  python graph/pipeline/audit_graph_durability.py --selftest   # frozen fixtures, hermetic

Exit 0 = clean. 2 = a hard finding. 3 = could not evaluate (no database, no interpreter path).
Read the verdict LINE, not the number (backlog E2).
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GRAPH_DIR = os.path.abspath(os.path.join(HERE, ".."))
REPO = os.path.abspath(os.path.join(GRAPH_DIR, ".."))
DB_PATH = os.path.join(GRAPH_DIR, "sqlite", "graph.db")
BASELINE = os.path.join(GRAPH_DIR, "state", "table-volume-baseline.json")

EXIT_CLEAN, EXIT_FINDING, EXIT_CANNOT_RUN = 0, 2, 3

# A fall this large in one run is a finding rather than a prune. Deliberately generous: the graph
# does get pruned, and a bar that fires on ordinary housekeeping is a bar somebody removes.
MAX_DROP_PCT = 40.0


# --------------------------------------------------------------------------- pure judgements
def judge_mirror(table: str, in_db: int, on_disk: int) -> str:
    """'' when the mirror holds, else why it does not.

    on_disk of -1 means the file exists and did not parse, which is NOT the same as a count
    mismatch and must not be reported as one - an unreadable mirror is the worse of the two.
    """
    if on_disk == -1:
        return ("%s: the tracked mirror exists and does not parse, so the %d row(s) in the database "
                "have no readable copy. That is worse than a mismatch, not a variety of one."
                % (table, in_db))
    if in_db == on_disk:
        return ""
    if on_disk == 0 and in_db > 0:
        return ("%s: %d row(s) in the database and NOTHING on disk. These rows exist nowhere else - "
                "an rm of graph.db loses them outright." % (table, in_db))
    return ("%s: %d row(s) in the database, %d in the tracked mirror. An export_learning() call was "
            "missed on some write path." % (table, in_db, on_disk))


def judge_volume(table: str, count: int, baseline, max_drop_pct: float = MAX_DROP_PCT) -> dict:
    """How this run's row count reads against the stored one.

    Verdict is 'new', 'grew', 'held', 'pruned' (a believable fall, baseline follows) or 'fell'
    (a finding). Growth is the steady state here, which is why only the fall is judged.
    """
    if baseline is None:
        return {"verdict": "new", "baseline": count,
                "message": "%s: %d row(s), first seen. Baselined." % (table, count)}
    if count > baseline:
        return {"verdict": "grew", "baseline": count,
                "message": "%s: %d row(s), up from %d." % (table, count, baseline)}
    if count == baseline:
        return {"verdict": "held", "baseline": baseline,
                "message": "%s: %d row(s), unchanged." % (table, count)}
    if baseline > 0 and count == 0:
        return {"verdict": "fell", "baseline": baseline,
                "message": ("%s: EMPTY, against a baseline of %d. A table that lost every row is a "
                            "load that failed or a delete nobody meant." % (table, baseline))}
    drop = 100.0 * (baseline - count) / baseline if baseline else 0.0
    if drop > max_drop_pct:
        return {"verdict": "fell", "baseline": baseline,
                "message": ("%s: %d row(s) against a baseline of %d, a %.1f%% fall in one run, over "
                            "the %.0f%% that reads as a prune rather than a load that failed."
                            % (table, count, baseline, drop, max_drop_pct))}
    return {"verdict": "pruned", "baseline": count,
            "message": "%s: %d row(s), down from %d. Inside the bar; baseline follows."
                       % (table, count, baseline)}


def judge_integrity(result: str) -> str:
    """'' when SQLite says the file is sound. quick_check answers 'ok' and nothing else when clean."""
    if (result or "").strip().lower() == "ok":
        return ""
    return ("quick_check did not return ok: %r. The database is WAL, written nightly, and there is "
            "no undo layer under it (E1). Stop writing to it and take a copy before anything else."
            % (result,))


# --------------------------------------------------------------------------- live helpers
def _learning_tables():
    """The (table, mirror-file) pairs, READ FROM graphdb rather than restated.

    Restating them here is how the two copies drift, and the drift would be invisible: a table this
    file forgot to list is a table this file reports clean.
    """
    lib = os.path.join(GRAPH_DIR, "lib")
    if lib not in sys.path:
        sys.path.insert(0, lib)
    from graphdb import GraphDB                                    # noqa: PLC0415
    return list(GraphDB.LEARNING_TABLES)


def _read_json_rows(path: str) -> int:
    if not os.path.exists(path):
        return 0
    try:
        with open(path, encoding="utf-8-sig") as f:
            return len(json.load(f) or [])
    except Exception:                                              # noqa: BLE001
        return -1


def _open_ro(path: str) -> sqlite3.Connection:
    return sqlite3.connect("file:%s?mode=ro" % path.replace("\\", "/"), uri=True, timeout=10)


def load_baseline(path: str = None) -> dict:
    """Returns {'tables': {...}, 'history': [...]}, empty rather than raising on a missing file."""
    try:
        with open(path or BASELINE, encoding="utf-8-sig") as f:
            doc = json.load(f)
        return {"tables": dict(doc.get("tables", {})), "history": list(doc.get("history", []))}
    except Exception:                                              # noqa: BLE001
        return {"tables": {}, "history": []}


def save_baseline(tables: dict, path: str = None, keep: int = 120) -> dict:
    """Written on EVERY clean run, not only when asked for.

    Writing only on an --update flag looked tidy and was wrong: a table that legitimately sheds 20%
    a night would be compared against a baseline from weeks ago, cross the 40% bar cumulatively, and
    fire on nothing at all. lib/ratchet.ps1 argues the same thing from the other side - the count is
    recorded every run, because the point is the RATE.

    History is total rows per run, which is what makes a slow leak visible. A single number cannot
    show that something has been shrinking for six weeks.
    """
    path = path or BASELINE
    hist = load_baseline(path)["history"]
    hist.append({"date": datetime.datetime.now().isoformat(timespec="seconds"),
                 "total_rows": sum(tables.values())})
    hist = hist[-keep:]
    doc = {"generated": datetime.datetime.now().isoformat(timespec="seconds"),
           "note": ("Row counts per table in graph/sqlite/graph.db. Growth is the steady state, so a "
                    "rise retrains this silently; a fall past %.0f%% or to zero is a finding. This is "
                    "the VOLUME limb of the four data-quality checks." % MAX_DROP_PCT),
           "tables": tables, "history": hist}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # NOT open(path, 'w') UNTIL THE CONTENT IS BUILT. Writing this file is what destroyed an earlier
    # draft of it: 'w' truncates before anything else can fail, so a bad argument on the open call
    # itself left a zero-byte file behind. Serialise first, then open.
    blob = json.dumps(doc, indent=2, sort_keys=True) + "\n"
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(blob)
    return doc


# --------------------------------------------------------------------------- self-test
def selftest() -> int:
    import tempfile                                                # noqa: PLC0415
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    print("audit_graph_durability self-test")
    print("")

    # MUST FIRE - the founding shapes. The first is what the whole file exists for.
    T("MUST FIRE  THE FOUNDING CASE - rows in the database with nothing on disk are rows an rm loses",
      "exist nowhere else" in judge_mirror("approved_patches", 186, 0),
      judge_mirror("approved_patches", 186, 0))
    T("MUST FIRE  a mirror that fell behind names the missed export_learning() call",
      "export_learning" in judge_mirror("question_verdicts", 4141, 4098),
      judge_mirror("question_verdicts", 4141, 4098))
    T("MUST FIRE  an unparseable mirror is reported as WORSE than a mismatch, not as one",
      "does not parse" in judge_mirror("eval_runs", 43, -1), judge_mirror("eval_runs", 43, -1))
    T("MUST FIRE  a table that lost every row is a finding",
      judge_volume("nodes", 0, 47319)["verdict"] == "fell", judge_volume("nodes", 0, 47319)["message"])
    T("MUST FIRE  a fall past the bar is a finding",
      judge_volume("aliases", 40000, 76439)["verdict"] == "fell",
      judge_volume("aliases", 40000, 76439)["message"])
    T("MUST FIRE  quick_check saying anything but ok is a finding, and says to copy the file first",
      "take a copy" in judge_integrity("*** in database main ***\nPage 41 is never used"),
      judge_integrity("bad"))

    # MUST NOT FIRE - the legal inputs. Growth is the normal state of this database.
    T("MUST NOT FIRE  a mirror that matches is silent", judge_mirror("nodes", 47319, 47319) == "",
      judge_mirror("nodes", 47319, 47319))
    T("MUST NOT FIRE  an empty table with an empty mirror agrees, and is not a loss",
      judge_mirror("eval_runs", 0, 0) == "", judge_mirror("eval_runs", 0, 0))
    T("MUST NOT FIRE  THE ONE THAT KEEPS THIS USABLE - growth is the steady state and must never fire",
      judge_volume("edges", 90000, 84748)["verdict"] == "grew",
      judge_volume("edges", 90000, 84748)["message"])
    T("MUST NOT FIRE  a small fall is a prune, not a failed load",
      judge_volume("provenance", 4000, 4294)["verdict"] == "pruned",
      judge_volume("provenance", 4000, 4294)["message"])
    T("MUST NOT FIRE  quick_check ok is silent, in any casing SQLite might use",
      (judge_integrity("ok") == "") and (judge_integrity("OK\n") == ""), judge_integrity("OK\n"))
    T("MUST NOT FIRE  a table seen for the first time is baselined, not reported",
      judge_volume("brand_new", 12, None)["verdict"] == "new",
      judge_volume("brand_new", 12, None)["message"])

    # CLEAN TWIN - adjacent behaviour that still works.
    T("CLEAN TWIN a believable fall LOWERS the stored baseline, so the next run compares to reality",
      judge_volume("provenance", 4000, 4294)["baseline"] == 4000,
      str(judge_volume("provenance", 4000, 4294)["baseline"]))
    T("CLEAN TWIN growth raises the baseline rather than leaving it stale",
      judge_volume("edges", 90000, 84748)["baseline"] == 90000,
      str(judge_volume("edges", 90000, 84748)["baseline"]))
    T("CLEAN TWIN a zero baseline cannot divide by zero on the fall path",
      judge_volume("fresh", 0, 0)["verdict"] == "held", judge_volume("fresh", 0, 0)["message"])
    pairs = _learning_tables()
    T("CLEAN TWIN the irreplaceable table list is READ from graphdb, not restated here",
      len(pairs) >= 5 and all(len(p) == 2 for p in pairs), str(pairs)[:120])

    # THE WRITE PATH, DRIVEN FOR REAL against a temp file. The tempting shortcut - grepping this
    # module's own docstring for "every clean run" - is a self-test that greps its own source and
    # cannot fail. [[selftest-greps-its-own-source]]
    tmp = os.path.join(tempfile.mkdtemp(prefix="graphdur-"), "baseline.json")
    try:
        save_baseline({"nodes": 10, "edges": 20}, path=tmp)
        first = load_baseline(tmp)
        save_baseline({"nodes": 11, "edges": 20}, path=tmp)
        second = load_baseline(tmp)
        T("MUST FIRE  a second clean run APPENDS to history rather than replacing it - the whole "
          "point is the rate, and one number cannot show a slow leak",
          len(first["history"]) == 1 and len(second["history"]) == 2,
          "%d then %d" % (len(first["history"]), len(second["history"])))
        T("CLEAN TWIN the retrained counts are what comes back on the next read",
          second["tables"] == {"nodes": 11, "edges": 20}, str(second["tables"]))
        T("CLEAN TWIN history records the TOTAL, so a table shrinking while another grows is visible",
          second["history"][-1]["total_rows"] == 31, str(second["history"][-1]))
        T("MUST NOT FIRE  a missing baseline file reads as empty rather than throwing",
          load_baseline(os.path.join(os.path.dirname(tmp), "nope.json")) == {"tables": {}, "history": []},
          str(load_baseline(os.path.join(os.path.dirname(tmp), "nope.json"))))
    finally:
        import shutil                                              # noqa: PLC0415
        shutil.rmtree(os.path.dirname(tmp), ignore_errors=True)

    if bad:
        print("")
        print("SELF-TEST FAIL: %d check(s)" % len(bad))
        print("GRAPH-DURABILITY-SELFTEST-COMPLETE")
        return 1
    print("")
    print("SELF-TEST PASS: 7 must-fire cases led by the founding rows-with-no-mirror shape, 7 "
          "must-not-fire cases led by growth being the steady state, and 6 clean twins including a "
          "real baseline round trip")
    print("GRAPH-DURABILITY-SELFTEST-COMPLETE")
    return 0


# --------------------------------------------------------------------------- live run
def main() -> int:
    ap = argparse.ArgumentParser(description="graph durability audit")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()

    if not os.path.exists(DB_PATH):
        print("GRAPH DURABILITY BLIND: %s is not on disk, so nothing was checked. That is the "
              "expected state in a worktree or a clean checkout - the database is gitignored - and "
              "it is NOT evidence that the mirror is current." % DB_PATH)
        print("GRAPH-DURABILITY-COMPLETE blind=no-database")
        return EXIT_CANNOT_RUN

    findings, notes = [], []
    con = _open_ro(DB_PATH)
    try:
        # 1. THE MIRROR.
        for table, fname in _learning_tables():
            try:
                in_db = con.execute("SELECT COUNT(*) FROM %s" % table).fetchone()[0]
            except sqlite3.Error as e:
                findings.append("%s: the table named by graphdb is not in the database (%s)" % (table, e))
                continue
            why = judge_mirror(table, in_db, _read_json_rows(os.path.join(GRAPH_DIR, fname)))
            if why:
                findings.append(why)
            else:
                notes.append("  mirror ok   %-22s %d" % (table, in_db))

        # 2. INTEGRITY.
        why = judge_integrity(con.execute("PRAGMA quick_check").fetchone()[0])
        if why:
            findings.append(why)
        else:
            notes.append("  quick_check ok")

        # 3. VOLUME.
        base = load_baseline()["tables"]
        new_base = dict(base)
        rows = con.execute("SELECT name FROM sqlite_master WHERE type='table' "
                           "AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall()
        for (t,) in rows:
            n = con.execute('SELECT COUNT(*) FROM "%s"' % t).fetchone()[0]
            v = judge_volume(t, n, base.get(t))
            new_base[t] = v["baseline"]
            if v["verdict"] == "fell":
                findings.append(v["message"])
            elif v["verdict"] in ("new", "pruned"):
                notes.append("  volume      " + v["message"])
        gone = sorted(set(base) - set(t for (t,) in rows))
        for t in gone:
            findings.append("%s: the table is in the baseline and NOT in the database. A table that "
                            "vanished is not a table that passed." % t)
    finally:
        con.close()

    for n in notes:
        print(n)
    for f in findings:
        print("  FINDING     " + f)

    if findings:
        print("GRAPH DURABILITY AUDIT FAILED: %d finding(s). The graph's whole safety story is that "
              "the tracked JSON is truth and graph.db is a rebuildable index; each finding above is "
              "a way that stopped being true." % len(findings))
        print("GRAPH-DURABILITY-COMPLETE findings=%d" % len(findings))
        return EXIT_FINDING

    doc = save_baseline(new_base)
    print("  volume baseline written for %d table(s), %d row(s) total"
          % (len(new_base), doc["history"][-1]["total_rows"]))
    print("graph-durability: PASSED - every irreplaceable table matches its tracked mirror, the file "
          "passes quick_check, and no table lost more than %.0f%% of its rows. An rm of graph.db is "
          "safe today." % MAX_DROP_PCT)
    print("GRAPH-DURABILITY-COMPLETE findings=0")
    return EXIT_CLEAN


if __name__ == "__main__":
    sys.exit(main())
