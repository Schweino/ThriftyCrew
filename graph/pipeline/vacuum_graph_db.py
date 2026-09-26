"""One-time VACUUM of graph/sqlite/graph.db, with the proof printed beside it (backlog I211).

    python graph/pipeline/vacuum_graph_db.py            # report only: pages, freelist, no write
    python graph/pipeline/vacuum_graph_db.py --apply    # VACUUM, then prove it
    python graph/pipeline/vacuum_graph_db.py --selftest # hermetic, temp databases only

WHEN IT IS SAFE: nothing else has graph.db open for writing. The writers are the daily capture
chain's import (about 08:15) and `TC Graph Nightly Matching` (21:30 to 06:30). Run it between
those, with no python.exe holding the file. It needs free disk for one more copy of the live
data (about 140 MB). A writer that is active makes it refuse (SQLITE_BUSY) and change nothing:
VACUUM is one transaction, so it either lands whole or not at all.

WHAT IT BUYS, measured 2026-09-18 on a backup-API copy: 322,392,064 B to 137,703,424 B in 0.82 s,
integrity_check ok, all 11 tables' row counts identical. Until 2026-09-19 that was only a reset: one
replay of `importers.import_observations` on the vacuumed copy regrew it to 67,489 pages (75.1% of
what the VACUUM removed), because every import re-inserted every capture row the last prune deleted.
The importer no longer does (backlog I211, graph/lib/supersede.py). Measured 2026-09-19 on a copy
carrying that importer's own steady state: 323,358,720 B to 143,343,616 B in 1.11 s, then two full
`import_all.py --observations` passes on the vacuumed copy left it at 145,444,864 and 145,637,376 B.
So it is now a one-time step: run it once after the importer change has done one nightly import.

The proof, all of which must hold or it exits 1: integrity_check returns 'ok', every table's row
count is identical before and after, and freelist_count is 0 after. It never changes the schema,
the page size or auto_vacuum.
"""
# The self-test builds its own temp databases and imports only the stdlib; it reads no repo file but this one.
# gate-inputs: graph\pipeline\vacuum_graph_db.py
from __future__ import annotations

import argparse
import os
import sqlite3
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.abspath(os.path.join(HERE, "..", "sqlite", "graph.db"))


def counts(conn: sqlite3.Connection) -> dict[str, int]:
    tabs = [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]
    return {t: conn.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0] for t in tabs}


def pages(conn: sqlite3.Connection) -> tuple[int, int, int]:
    q = lambda p: conn.execute(f"PRAGMA {p}").fetchone()[0]     # noqa: E731
    return q("page_count"), q("freelist_count"), q("page_size")


def vacuum(path: str, apply: bool, busy_ms: int = 2000) -> dict:
    """Report, and with apply=True VACUUM and prove. Returns a result dict with 'ok'."""
    if not os.path.exists(path):
        return {"ok": False, "error": f"no database at {path}"}
    conn = sqlite3.connect(path, timeout=busy_ms / 1000)
    try:
        pc, fl, ps = pages(conn)
        res = {"path": path, "bytes_before": os.path.getsize(path), "page_count_before": pc,
               "freelist_before": fl, "page_size": ps, "applied": False}
        if not apply:
            res["ok"] = True
            return res
        before = counts(conn)
        t0 = time.time()
        try:
            conn.execute("VACUUM")
        except sqlite3.OperationalError as e:
            res.update(ok=False, error=f"VACUUM refused, nothing changed: {e}")
            return res
        res["vacuum_s"] = round(time.time() - t0, 2)
        ck = conn.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        ic = [r[0] for r in conn.execute("PRAGMA integrity_check").fetchall()]
        after = counts(conn)
        pc2, fl2, _ = pages(conn)
        res.update(applied=True, checkpoint_busy=ck[0], integrity_check=ic,
                   tables=len(after), row_counts_identical=(before == after),
                   page_count_after=pc2, freelist_after=fl2)
        res["ok"] = (ic == ["ok"] and before == after and fl2 == 0)
        if before != after:
            res["row_count_diff"] = {t: (before.get(t), after.get(t))
                                     for t in set(before) | set(after) if before.get(t) != after.get(t)}
        return res
    finally:
        conn.close()
        if "res" in locals() and res.get("applied"):
            res["bytes_after"] = os.path.getsize(path)


def _fixture(path: str) -> None:
    c = sqlite3.connect(path)
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("CREATE TABLE obs (id INTEGER PRIMARY KEY, body TEXT)")
    c.execute("CREATE INDEX ix_obs_body ON obs(body)")
    c.executemany("INSERT INTO obs(body) VALUES (?)", [("x" * 300 + str(i),) for i in range(4000)])
    c.commit()
    c.execute("DELETE FROM obs WHERE id > 500")                  # the import-then-prune shape
    c.commit()
    c.close()


def selftest() -> int:
    bad: list[str] = []
    n = 0

    def T(label: str, cond: bool, got: str) -> None:
        nonlocal n
        n += 1
        print(("  ok    " if cond else "  FAIL  ") + label + ("" if cond else f"   got: {got}"))
        if not cond:
            bad.append(label)

    tmp = tempfile.mkdtemp(prefix="i211-vac-")
    try:
        db = os.path.join(tmp, "g.db")
        _fixture(db)
        r0 = vacuum(db, apply=False)
        T("CLEAN TWIN  report mode reads a real freelist and writes nothing",
          r0["ok"] and r0["freelist_before"] > 0 and not r0["applied"], str(r0))
        r1 = vacuum(db, apply=True)
        T("MUST FIRE  --apply empties the freelist and shrinks the file (the founding shape: "
          "pages a prune freed that no insert reused)",
          r1["ok"] and r1["freelist_after"] == 0 and r1["bytes_after"] < r0["bytes_before"], str(r1))
        T("CLEAN TWIN  every table's row count is identical and integrity_check is ok after it",
          r1["row_counts_identical"] and r1["integrity_check"] == ["ok"] and r1["tables"] == 1, str(r1))

        db2 = os.path.join(tmp, "busy.db")
        _fixture(db2)
        holder = sqlite3.connect(db2)
        holder.execute("BEGIN IMMEDIATE")
        holder.execute("INSERT INTO obs(body) VALUES ('writer in flight')")
        size = os.path.getsize(db2)
        r2 = vacuum(db2, apply=True, busy_ms=200)
        T("MUST FIRE  a writer holding the database makes it REFUSE and change nothing",
          (not r2["ok"]) and "refused" in r2.get("error", "") and not r2["applied"]
          and os.path.getsize(db2) == size, str(r2))
        holder.rollback()
        holder.close()
        r3 = vacuum(os.path.join(tmp, "absent.db"), apply=True)
        T("MUST FIRE  a missing database is an error, never a created empty one",
          (not r3["ok"]) and not os.path.exists(os.path.join(tmp, "absent.db")), str(r3))
    finally:
        import shutil                                              # noqa: PLC0415
        shutil.rmtree(tmp, ignore_errors=True)

    if bad or n != 5:
        print(f"\nSELF-TEST FAIL: {len(bad)} of {n} check(s) failed (expected 5 run)")
        return 1
    print(f"\nvacuum_graph_db SELF-TEST PASS: {n} of 5 cases")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="one-time VACUUM of graph.db, with its proof")
    ap.add_argument("--apply", action="store_true", help="VACUUM (default: report only)")
    ap.add_argument("--db", default=DB_PATH)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    r = vacuum(a.db, apply=a.apply)
    for k, v in r.items():
        print(f"  {k:<22} {v}")
    print(f"VACUUM-GRAPH-DB-COMPLETE ok={r['ok']} applied={r.get('applied')}")
    return 0 if r["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
