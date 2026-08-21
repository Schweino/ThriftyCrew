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

            for name, fn in importers.LANE_IMPORTERS:
                t0 = time.time()
                try:
                    res = fn(db, ts, run, limit_files=args.limit_files)
                except Exception as e:                  # noqa: BLE001
                    say(f"  {name:<20} FAILED: {e}")
                    db.log_event(run=run, timestamp=ts, etype="escalate", step_id=name,
                                 decision="lane_importer_failed", detail={"error": str(e)})
                    continue
                totals.update(res)
                db.conn.commit()
                say(f"  {name:<20} {res}   ({time.time()-t0:.1f}s)")

        # PHASE C: the answer is rebuilt and the evidence bounded as part of the
        # import, not as a chore someone remembers. The ORDER is load-bearing,
        # and getting it wrong is silent rather than loud:
        #
        #   1. resolve (deterministic)  — freshly imported rows arrive
        #      'unadjudicated', and the prune refuses to delete an open question.
        #      Building state before this produced a prune that removed 2,400
        #      rows instead of 103,000 and looked like it had worked.
        #   2. rebuild cell_state       — the current answer per cell
        #   3. bank question_verdicts   — so pruning destroys no adjudication
        #   4. supersede-prune          — drop rows a newer sighting replaced
        #   5. export                   — cell_state's git diff IS the price history
        #
        # The resolver consults the banked verdicts (layer 4.5), so questions a
        # model already answered in an earlier run cost nothing to re-settle.
        if args.observations:
            pipeline_dir = os.path.join(
                os.path.dirname(os.path.abspath(__file__)), "..", "pipeline")
            sys.path.insert(0, pipeline_dir)
            from resolve import Resolver                                  # noqa: PLC0415
            from state import (build_cell_state, build_question_verdicts,  # noqa: PLC0415
                               supersede_prune, export_state)
            say("\n  adjudicate + price state ...")
            # Rulings first, and again here rather than only in the seed pass:
            # the lanes above insert rows pre-marked include_hit, so a ruling
            # that swept before they landed never touched them.
            # The learning loop's applied patches live only in this index, so a
            # rebuild must re-materialise them or it silently un-applies work
            # the proposals still report as applied.
            sys.path.insert(0, os.path.join(
                os.path.dirname(os.path.abspath(__file__)), "..", "learning"))
            from stage2_review import reapply_applied_patches      # noqa: PLC0415
            t0 = time.time()
            res = reapply_applied_patches(db, ts, run)
            totals.update(res)
            say(f"  {'reapply patches':<20} {res}   ({time.time()-t0:.1f}s)")

            t0 = time.time()
            n_demoted = importers.retro_apply_known_wrong(db, ts, run)
            totals["known_wrong_retro_demoted"] = n_demoted
            say(f"  {'known-wrong sweep':<20} {n_demoted} rows demoted   "
                f"({time.time()-t0:.1f}s)")
            t0 = time.time()
            res = Resolver(db, use_llm=False).resolve_pending(run=run, ts=ts,
                                                              allow_llm=False)
            totals["resolved_rows"] = res["resolved"]
            say(f"  {'resolve':<20} {res['resolved']} rows, "
                f"{res['questions']} questions   ({time.time()-t0:.1f}s)")
            for label, fn in (("cell_state", build_cell_state),
                              ("verdicts", build_question_verdicts)):
                t0 = time.time()
                out = fn(db, ts)
                totals.update(out)
                say(f"  {label:<20} {out}   ({time.time()-t0:.1f}s)")

            # The migration gate, measured while both derivations still see the
            # same evidence — the prune below removes rows the observations path
            # would need to answer with, so this is the only honest moment for it.
            from state import verify_against_matrix            # noqa: PLC0415
            gate = verify_against_matrix(db)
            totals["state_gate_ok"] = gate["ok"]
            say(f"  {'state gate':<20} {'PASS' if gate['ok'] else 'FAIL'}  "
                f"cells {gate['state_cells']}, live-board agreement "
                f"{gate['agreement_from_state']} vs {gate['agreement_from_observations']} "
                f"from observations")

            t0 = time.time()
            out = supersede_prune(db, ts)
            totals.update(out)
            say(f"  {'prune':<20} {out}   ({time.time()-t0:.1f}s)")
            say(f"  {'state export':<20} {export_state(db)}")

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
