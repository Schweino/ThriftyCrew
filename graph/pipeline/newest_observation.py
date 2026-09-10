"""The newest price observation graph.db has perceived. Read-only, and it reports a DATE, never a verdict.

    python graph/pipeline/newest_observation.py                          # the live graph.db
    python graph/pipeline/newest_observation.py --db COPY --today 2026-09-10
    python graph/pipeline/newest_observation.py --selftest

WHY THIS EXISTS (2026-09-10). graph/pipeline/nightly.ps1's input assertion read the database FILE's
mtime and said OK every night, while price_observations had not moved since 2026-08-21: 26,740 rows
dated 2026-07-14 to 2026-08-21, and all 4,141 question_verdicts on one decided_at. The file kept being
written - grocery/audit-graph-gates.ps1 ran a structure-only import every morning - so its mtime was a
clock for "something opened this database", not for "a price arrived". This prints the other clock.

THE DECISION IS NOT HERE. It is lib/input-assert.ps1's Get-TcInputState, so there is one rule and this
is only its reader. graph/pipeline/nightly.ps1 and grocery/audit-graph-gates.ps1 both read the line this
prints, with Get-TcStampFromLines.

OUTPUT, as the last lines and in this order:
    lane <lane> newest=<date> rows=<n>                          one per source lane, information only
    NEWEST-OBSERVATION observed_at=<date> rows=<n> future_rows=<n>
    NEWEST-OBSERVATION-COMPLETE rc=<rc>

A FUTURE-DATED ROW IS COUNTED, NEVER REPORTED AS NEWEST. One row dated next week would otherwise make
this clock read fresh for a week after every capture stopped - the exact false green it exists to end.
None existed when this was written (0 of 41,824 on a freshly imported copy), which is why it is a count
and not a refusal.

EXIT: 0 read. 3 could not read - no database, no price_observations table, or no dated row at or before
today. Exit 3 prints an EMPTY observed_at, which lib/input-assert.ps1 reads as UNREADABLE, never FRESH.

SCOPE OF A CLEAN REPORT: UNSOUND by lane. The newest date is the newest across every lane, so one lane
that stopped while another kept flowing still reads current; the per-lane lines say which, and nothing
here turns them into a verdict. It says how RECENT the rows are, never whether they are right.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import os
import shutil
import sqlite3
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GRAPH = os.path.dirname(HERE)
DB = os.path.join(GRAPH, "sqlite", "graph.db")


def lane_of(source_file: str | None) -> str:
    """grocery/out/regular/x.json -> 'regular'; anything else keeps its first two segments. PURE."""
    parts = [p for p in (source_file or "").replace("\\", "/").split("/") if p]
    if len(parts) >= 3 and parts[0] == "grocery" and parts[1] == "out":
        return parts[2]
    return "/".join(parts[:2]) if parts else "(none)"


def read_newest(db_path: str, today: str) -> dict:
    """Read the clock. Returns {rc, newest, rows, future, lanes, reason}. Opens mode=ro, so reading an
    absent or live database can neither create it nor take its write lock."""
    out = {"rc": 3, "newest": "", "rows": 0, "future": 0, "lanes": {}, "reason": ""}
    if not os.path.exists(db_path):
        out["reason"] = "no database at %s" % db_path
        return out
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db_path.replace("\\", "/"), uri=True)
    except sqlite3.Error as e:
        out["reason"] = "could not open %s: %s" % (db_path, e)
        return out
    try:
        try:
            out["rows"] = con.execute("SELECT count(*) FROM price_observations").fetchone()[0]
        except sqlite3.Error as e:
            out["reason"] = "no price_observations table: %s" % e
            return out
        out["future"] = con.execute(
            "SELECT count(*) FROM price_observations WHERE substr(observed_at,1,10) > ?",
            (today,)).fetchone()[0]
        lanes: dict[str, dict] = {}
        for sf, newest, n in con.execute(
                """SELECT source_file, max(observed_at), count(*) FROM price_observations
                   WHERE observed_at IS NOT NULL AND substr(observed_at,1,10) <= ?
                   GROUP BY source_file""", (today,)):
            lane = lanes.setdefault(lane_of(sf), {"newest": "", "rows": 0})
            lane["rows"] += n
            if newest and newest > lane["newest"]:
                lane["newest"] = newest
        out["lanes"] = lanes
        out["newest"] = max((v["newest"] for v in lanes.values()), default="")
        if not out["newest"]:
            out["reason"] = "no dated observation at or before %s (%d row(s), %d future-dated)" % (
                today, out["rows"], out["future"])
            return out
        out["rc"] = 0
        return out
    finally:
        con.close()


def key_line(r: dict) -> str:
    """The one line the PowerShell side parses. An unreadable clock carries an EMPTY observed_at. PURE."""
    newest = r.get("newest") if r.get("rc") == 0 else ""
    return "NEWEST-OBSERVATION observed_at=%s rows=%d future_rows=%d" % (
        newest or "", int(r.get("rows") or 0), int(r.get("future") or 0))


def selftest() -> int:
    n = bad = 0

    def case(label, ok, got=None):
        nonlocal n, bad
        n += 1
        print(("ok    " if ok else "FAIL  ") + label + ("" if ok else "   got: %r" % (got,)))
        if not ok:
            bad += 1

    tmp = tempfile.mkdtemp(prefix="newest-observation-selftest-")
    try:
        def make(name, rows, table=True):
            p = os.path.join(tmp, name)
            con = sqlite3.connect(p)
            if table:
                con.execute("CREATE TABLE price_observations "
                            "(id TEXT PRIMARY KEY, observed_at TEXT, source_file TEXT)")
                con.executemany("INSERT INTO price_observations VALUES (?,?,?)", rows)
            con.commit()
            con.close()
            return p

        # MUST FIRE, THE FOUNDING CASE. A database written seconds ago whose newest row is 2026-08-21
        # must report 2026-08-21. The mtime is fresh by construction; the clock must not be.
        frozen = make("frozen.db", [("a", "2026-07-14", "grocery/out/regular/x-2026-07-14.json"),
                                    ("b", "2026-08-21", "grocery/out/regular/x-2026-08-21.json")])
        age = time.time() - os.path.getmtime(frozen)
        r = read_newest(frozen, "2026-09-10")
        case("MUST FIRE  a database written seconds ago still reports its OLD newest observation",
             age < 300 and r["rc"] == 0 and r["newest"] == "2026-08-21", (age, r))

        # MUST FIRE: a future-dated row cannot speak for today.
        fut = make("future.db", [("a", "2026-08-21", "grocery/out/bakers/d1.json"),
                                 ("b", "2026-09-17", "grocery/out/bakers/d2.json")])
        r = read_newest(fut, "2026-09-10")
        case("MUST FIRE  a future-dated row is counted, and the newest date stays the real one",
             r["rc"] == 0 and r["newest"] == "2026-08-21" and r["future"] == 1, r)

        # CLEAN TWIN: the healthy shape still reads, lane by lane.
        live = make("live.db", [("a", "2026-09-09", "grocery/out/regular/r.json"),
                                ("b", "2026-09-10", "grocery/out/fareway/f.json")])
        r = read_newest(live, "2026-09-10")
        case("CLEAN TWIN  a capture dated today reads as today, and each lane keeps its own newest",
             r["rc"] == 0 and r["newest"] == "2026-09-10"
             and r["lanes"].get("regular", {}).get("newest") == "2026-09-09", r)

        # MUST FIRE: every could-not-read shape is exit 3 with no date.
        r = read_newest(make("notable.db", [], table=False), "2026-09-10")
        case("MUST FIRE  no price_observations table is could-not-read (3), never a date",
             r["rc"] == 3 and not r["newest"], r)
        r = read_newest(make("empty.db", []), "2026-09-10")
        case("MUST FIRE  an EMPTY table is could-not-read (3) - zero rows is not a fresh clock",
             r["rc"] == 3 and not r["newest"], r)
        absent = os.path.join(tmp, "absent.db")
        r = read_newest(absent, "2026-09-10")
        case("MUST FIRE  an absent database is could-not-read (3)", r["rc"] == 3 and not r["newest"], r)
        case("MUST NOT FIRE  reading an absent database does not create one", not os.path.exists(absent),
             "created")

        # The line the PowerShell side parses.
        line = key_line({"rc": 0, "newest": "2026-08-21", "rows": 2, "future": 0})
        case("CLEAN TWIN  the key line carries observed_at=<date> for lib/input-assert.ps1",
             line.startswith("NEWEST-OBSERVATION ") and " observed_at=2026-08-21 " in line, line)
        line = key_line({"rc": 3, "newest": "2026-08-21", "rows": 0, "future": 0})
        case("MUST FIRE  a could-not-read line carries an EMPTY observed_at, whatever it was handed",
             " observed_at= " in line, line)
        case("CLEAN TWIN  lane_of names the capture lane and keeps a non-lane source readable",
             lane_of("grocery/out/sams/s.json") == "sams"
             and lane_of("grocery\\product-urls.json") == "grocery/product-urls.json",
             (lane_of("grocery/out/sams/s.json"), lane_of("grocery\\product-urls.json")))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if bad:
        print("NEWEST-OBSERVATION SELFTEST FAIL: %d of %d case(s)" % (bad, n))
        return 2
    print("NEWEST-OBSERVATION SELFTEST PASS: %d case(s) resolved - led by the founding case, a database "
          "written seconds ago that still reports its 2026-08-21 newest row" % n)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Print the newest price observation graph.db has perceived")
    ap.add_argument("--db", default=DB)
    ap.add_argument("--today", default=None, help="YYYY-MM-DD; defaults to the local date")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    today = a.today or _dt.date.today().isoformat()
    r = read_newest(a.db, today)
    for lane, v in sorted(r["lanes"].items(), key=lambda kv: kv[1]["newest"], reverse=True):
        print("lane %s newest=%s rows=%d" % (lane, v["newest"], v["rows"]))
    if r["rc"] != 0:
        print("could not read the observation clock: %s" % r["reason"])
    print(key_line(r))
    print("NEWEST-OBSERVATION-COMPLETE rc=%d" % r["rc"])
    return r["rc"]


if __name__ == "__main__":
    sys.exit(main())
