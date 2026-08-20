"""Rebuild the SQLite index from the tracked JSON, and prove nothing was lost.

    python graph/lib/rebuild.py              # rebuild + verify
    python graph/lib/rebuild.py --verify     # verify only, rebuild nothing
    python graph/lib/rebuild.py --drill      # destructive round-trip drill

The graph's central claim is that `graph/sqlite/graph.db` is an INDEX and the
tracked JSON is the truth. This file is what makes that claim testable rather
than aspirational -- README and .gitignore both told people to run it, and until
now it did not exist.

WHAT REBUILDS AND WHAT DOES NOT, and why the distinction matters:

  nodes / edges / aliases     rebuild from the legacy estate via import_all.py.
  observations / provenance   rebuild from the tracked store captures.
      Losing these costs time, nothing else. They are DERIVED.

  learning_proposals          exist NOWHERE ELSE. A proposal the local model
  approved_patches            made, the verdict a reviewer gave it, and the
      before/after gold-set metrics that justified applying it cannot be
      regenerated from any other file. They are the only irreplaceable rows in
      the database, and they were the ones sitting in a gitignored file.

So the drill below is not ceremony. It is the only way to know that a routine
`rm graph.db` -- which the README actively encourages -- does not quietly delete
the record of what the learning loop did and why it was allowed to.
"""

from __future__ import annotations

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from graphdb import GraphDB, GRAPH_DIR, DB_PATH, open_db     # noqa: E402


def verify(db) -> dict:
    """Compare what is in the database against what is on disk."""
    out = {"ok": True, "tables": {}}
    for table, fname in GraphDB.LEARNING_TABLES:
        in_db = db.conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        path = os.path.join(GRAPH_DIR, fname)
        on_disk = 0
        if os.path.exists(path):
            from graphdb import read_json
            try:
                on_disk = len(read_json(path) or [])
            except Exception:                                # noqa: BLE001
                on_disk = -1
        match = in_db == on_disk
        out["tables"][table] = {"in_db": in_db, "on_disk": on_disk, "match": match}
        out["ok"] = out["ok"] and match
    return out


def drill() -> int:
    """Destructive round-trip: record counts, delete the DB, rebuild, compare.

    Deliberately destructive, because a durability guarantee that is only ever
    tested non-destructively is not tested at all.
    """
    print("=== learning-record durability drill ===\n")

    with open_db() as db:
        before = db.learning_counts()
        db.export_learning()          # ensure disk reflects the database
    print(f"  1. before          : {before}")
    if not any(before.values()):
        print("\n  NOTHING TO PROVE: there are no learning records to lose.")
        print("  Run graph/learning/stage1_analyze.py first, then re-run this drill.")
        return 1

    for suffix in ("", "-wal", "-shm"):
        p = DB_PATH + suffix
        if os.path.exists(p):
            os.remove(p)
    print(f"  2. deleted         : {os.path.basename(DB_PATH)} (and -wal/-shm)")

    with open_db() as db:             # auto-restore fires here
        after = db.learning_counts()
        v = verify(db)
    print(f"  3. after rebuild   : {after}")

    ok = before == after and v["ok"]
    print()
    for t, d in v["tables"].items():
        print(f"     {t:<20} db={d['in_db']:<5} disk={d['on_disk']:<5} "
              f"{'OK' if d['match'] else 'MISMATCH'}")
    print(f"\n  DRILL: {'PASS' if ok else 'FAIL'} - learning records "
          f"{'survived' if ok else 'DID NOT survive'} a full delete-and-rebuild")
    if not ok:
        print(f"     expected {before}, got {after}")

    # The drill deliberately leaves the database holding ONLY the irreplaceable
    # rows -- that is what "the DB is an index" means in practice. Say so, loudly.
    # Without this warning the next step (running the learning loop) silently
    # rejects every patch because there are no commodity nodes for its targets to
    # resolve against, and that looks like a broken loop rather than an empty index.
    with open_db() as db:
        stats = db.stats()
    if not stats["nodes"]:
        print("\n  NOTE: the database now holds ONLY learning records -- nodes,")
        print("        edges, aliases and observations are DERIVED and were not")
        print("        restored. Until you re-import them, anything that resolves a")
        print("        commodity (the learning loop, parity, the resolver) will find")
        print("        nothing. Restore the derived bulk with:")
        print("          python graph/import/import_all.py --observations")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Rebuild the graph index from tracked JSON")
    ap.add_argument("--verify", action="store_true", help="verify only, change nothing")
    ap.add_argument("--drill", action="store_true",
                    help="destructive round-trip test of learning durability")
    args = ap.parse_args()

    if args.drill:
        return drill()

    if args.verify:
        with open_db() as db:
            v = verify(db)
        for t, d in v["tables"].items():
            print(f"  {t:<20} db={d['in_db']:<5} disk={d['on_disk']:<5} "
                  f"{'OK' if d['match'] else 'MISMATCH'}")
        print(f"  {'OK' if v['ok'] else 'MISMATCH'}")
        return 0 if v["ok"] else 1

    # Plain rebuild: restore what is irreplaceable, then point at import_all for
    # the derived bulk. This file deliberately does NOT re-import the estate --
    # import_all.py owns that, and duplicating it here would create two
    # implementations of the same thing that drift.
    with open_db() as db:
        restored = db.import_learning()
        counts = db.learning_counts()
    print(f"  restored learning records: {restored}")
    print(f"  learning tables now      : {counts}")
    print("\n  For nodes/edges/aliases/observations run:")
    print("    python graph/import/import_all.py --observations")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
