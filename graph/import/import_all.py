"""Run every seed importer (Phase 2 entry point).

    python graph/import/import_all.py                 # structure only, fast
    python graph/import/import_all.py --observations  # + price observation backfill
    python graph/import/import_all.py --observations --limit-files 8

Dual-write: this reads the legacy estate and writes only the graph. It never
writes back to grocery/*.json. Safe to run while the daily pipeline is idle;
by design it takes no locks on the legacy files.
"""

from __future__ import annotations

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

from graphdb import open_db                      # noqa: E402
from ids import run_id as make_run_id            # noqa: E402
import importers                                 # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description="Seed the knowledge graph from the legacy estate")
    ap.add_argument("--observations", action="store_true",
                    help="also backfill PriceObservations from grocery/out captures")
    ap.add_argument("--limit-files", type=int, default=None,
                    help="only the N most recent capture files per lane")
    ap.add_argument("--export", action="store_true",
                    help="write the durable git-tracked JSON after importing")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    run = make_run_id("import", time.strftime("%Y%m%dT%H%M%S"))
    say = (lambda *a: None) if args.quiet else print

    say(f"run: {run}")
    say(f"repo: {importers.REPO_ROOT}")
    say("")

    totals: dict[str, int] = {}
    with open_db() as db:
        db.log_event(run=run, timestamp=ts, etype="state_transition",
                     decision="import_start", detail={"observations": args.observations})

        for name, fn in importers.ALL_IMPORTERS:
            t0 = time.time()
            try:
                res = fn(db, ts, run)
            except Exception as e:                      # noqa: BLE001
                say(f"  {name:<20} FAILED: {e}")
                db.log_event(run=run, timestamp=ts, etype="escalate", step_id=name,
                             decision="importer_failed", detail={"error": str(e)})
                continue
            totals.update(res)
            db.conn.commit()
            say(f"  {name:<20} {res}   ({time.time()-t0:.1f}s)")

        if args.observations:
            say("\n  observations (this reads every capture file; slowest step)")
            t0 = time.time()
            res = importers.import_observations(
                db, ts, run, limit_files=args.limit_files,
                progress=None if args.quiet else (lambda m: say(m)))
            totals.update(res)
            db.conn.commit()
            say(f"  {'observations':<20} {res}   ({time.time()-t0:.1f}s)")

        stats = db.stats()
        db.log_event(run=run, timestamp=ts, etype="state_transition",
                     decision="import_complete", detail={"totals": totals, "stats": stats})

        if args.export:
            say("\n  exporting durable JSON ...")
            say(f"  {db.export_json()}")

    say("\n--- graph stats ---")
    for k, v in stats.items():
        say(f"  {k:<14} {v}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
