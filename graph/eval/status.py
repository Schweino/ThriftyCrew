"""Graph status report — Phase 6 observability.

    python graph/eval/status.py
    python graph/eval/status.py --json      # for the triage agent

One place that answers "where does the graph-native redesign actually stand?"
without anyone having to remember which gate lives in which script. Written to be
read by the grocery-alert-triage agent as well as by a human, which is why every
gate reports its NUMBER next to its TARGET rather than a bare pass/fail — a gate
that fails by 0.001 and one that fails by 0.4 need different responses.

Gates that require elapsed calendar time (14 consecutive daily cycles, 4
consecutive Wednesday browser cycles) are counted from the decision log, not
asserted. There is no way to shortcut them and no reason to pretend otherwise.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
sys.path.insert(0, os.path.join(HERE, "..", "agentic"))

from graphdb import open_db                    # noqa: E402
from verifier import run_checks                # noqa: E402

PHASE_GATES = {
    "phase0_valid_json": ("Phase 0 valid strict JSON", 0.95, "min"),
    "phase0_agreement": ("Phase 0 resolution agreement", 0.90, "min"),
    "phase0_tok_s": ("Phase 0 decode tok/s", 15.0, "min"),
    "false_merge_rate": ("gold-set false-merge rate", 0.02, "max"),
    "missed_merge_rate": ("gold-set missed-merge rate", 0.10, "max"),
    "board_agreement": ("Phase 2 board parity agreement", 0.99, "min"),
    "shadow_days": ("Phase 2/3 consecutive clean daily cycles", 14, "min"),
    "chrome_cycles": ("Phase 4 consecutive Wednesday browser cycles", 4, "min"),
}


def latest_eval(db) -> dict | None:
    r = db.conn.execute(
        """SELECT * FROM eval_runs ORDER BY run_at DESC LIMIT 1""").fetchone()
    return dict(r) if r else None


def count_clean_daily_runs(db) -> int:
    """Consecutive daily runs that completed without halting, most recent first.

    Counted from the decision log rather than tracked in a counter, so it cannot
    drift from what actually happened.
    """
    rows = db.conn.execute(
        """SELECT run_id, decision, timestamp FROM decision_log
           WHERE type='state_transition'
             AND decision IN ('run_complete','run_halted')
             AND run_id LIKE 'run:daily:%'
           ORDER BY timestamp DESC""").fetchall()
    streak = 0
    for r in rows:
        if r["decision"] == "run_complete":
            streak += 1
        else:
            break
    return streak


def learning_summary(db) -> dict:
    out = defaultdict(int)
    for r in db.conn.execute(
            "SELECT status, COUNT(*) n FROM learning_proposals GROUP BY status"):
        out[r["status"]] = r["n"]
    for r in db.conn.execute(
            "SELECT shadow_verdict, COUNT(*) n FROM approved_patches GROUP BY shadow_verdict"):
        out[f"shadow_{r['shadow_verdict']}"] = r["n"]
    return dict(out)


def build(db) -> dict:
    stats = db.stats()
    ev = latest_eval(db)
    checks = run_checks(db)

    resolved = {r["match_status"]: r["n"] for r in db.conn.execute(
        "SELECT match_status, COUNT(*) n FROM price_observations GROUP BY 1")}
    total = sum(resolved.values()) or 1
    # Unsettled = nobody has reached a final ruling: never adjudicated, no layer
    # matched, waiting on the reviewer, or a local-model MATCH the reviewer has
    # not confirmed. 'escalated' used to be counted as settled — it is the
    # definition of not settled.
    pending = ("unadjudicated", "no_include_hit", "escalated", "llm_match_unverified")
    settled = total - sum(resolved.get(s, 0) for s in pending)

    return {
        "graph": stats,
        "resolution": {
            "total_rows": total,
            "by_status": resolved,
            "deterministically_settled_pct": round(100 * settled / total, 1),
        },
        "latest_eval": {
            "run_at": ev["run_at"], "model": ev["model"],
            "prompt_version": ev["prompt_version"],
            "entity_precision": ev["entity_precision"],
            "entity_recall": ev["entity_recall"],
            "false_merge_rate": ev["false_merge_rate"],
            "missed_merge_rate": ev["missed_merge_rate"],
        } if ev else None,
        "gate_checks": {k: v["ok"] for k, v in checks["checks"].items()},
        "gate_check_detail": {k: v["detail"] for k, v in checks["checks"].items()
                              if not v["ok"]},
        "consecutive_clean_daily_runs": count_clean_daily_runs(db),
        "learning": learning_summary(db),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    with open_db() as db:
        rep = build(db)

    if args.json:
        print(json.dumps(rep, indent=2, default=str))
        return 0

    g = rep["graph"]
    print("=== ThriftyCrew graph status ===\n")
    print(f"  nodes {g['nodes']}   edges {g['edges']}   aliases {g['aliases']}")
    print(f"  observations {g['observations']}   provenance {g['provenance']}   "
          f"events {g['events']}")
    print(f"  node types: {g['by_type']}\n")

    r = rep["resolution"]
    print(f"  resolution: {r['total_rows']} rows, "
          f"{r['deterministically_settled_pct']}% settled without a model")
    for k, v in sorted(r["by_status"].items(), key=lambda x: -x[1]):
        print(f"     {k:<20} {v}")

    ev = rep["latest_eval"]
    if ev:
        print(f"\n  latest gold-set eval ({ev['run_at']}, {ev['model']}):")
        print(f"     precision {ev['entity_precision']:.3f}   recall {ev['entity_recall']:.3f}")
        print(f"     false-merge {ev['false_merge_rate']:.4f} (gate <=0.02)   "
              f"missed-merge {ev['missed_merge_rate']:.4f} (gate <=0.10)")

    print("\n  gate checks:")
    for name, ok in rep["gate_checks"].items():
        print(f"     {'PASS' if ok else 'FAIL'}  {name}")
    for name, detail in rep["gate_check_detail"].items():
        print(f"           {json.dumps(detail, default=str)[:200]}")

    print(f"\n  consecutive clean daily runs: {rep['consecutive_clean_daily_runs']} / 14")
    if rep["learning"]:
        print(f"  learning: {rep['learning']}")

    print("\n  NOTE: the graph is non-authoritative. The legacy pipeline runs the")
    print("        live board. Time-based gates (14 daily cycles, 4 Wednesdays)")
    print("        cannot be shortened by code.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
