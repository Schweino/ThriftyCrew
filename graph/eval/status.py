"""Graph status report — Phase 6 observability.

    python graph/eval/status.py
    python graph/eval/status.py --json      # for the triage agent

One place that answers "where does the graph-native redesign actually stand?"
without anyone having to remember which gate lives in which script. Written to be
read by the grocery-alert-triage agent as well as by a human, which is why every
gate reports its NUMBER next to its TARGET rather than a bare pass/fail — a gate
that fails by 0.001 and one that fails by 0.4 need different responses.

Time-based gates (decision 2026-08-20, Brad): AD TIMING and the 90-DAY TIMER,
nothing else. The consecutive-clean-days counters (14 daily cycles, 4 Wednesday
browser cycles) that the first build carried over from the V4 postmortem were
removed on the owner's call — readiness is judged by the numeric gates plus the
two windows the capture policy actually defines: every weekly-ad store inside
its current window (check_ad_window) and no everyday row older than the 90-day
quarter (check_row_age, read from grocery/capture-policy.ps1 MaxCarryDays).
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
}


def latest_eval(db) -> dict | None:
    r = db.conn.execute(
        """SELECT * FROM eval_runs ORDER BY run_at DESC LIMIT 1""").fetchone()
    return dict(r) if r else None


def state_summary(db) -> dict:
    """The price-state tables: the answer, and how fresh it is."""
    try:
        cells = db.conn.execute("SELECT COUNT(*) FROM cell_state").fetchone()[0]
    except Exception:                                        # noqa: BLE001
        return {}
    if not cells:
        return {}
    row = db.conn.execute(
        """SELECT COUNT(*) n,
                  SUM(everyday_price IS NOT NULL) everyday,
                  SUM(ad_price IS NOT NULL) on_ad,
                  SUM(ad_to IS NOT NULL AND ad_to < date('now','localtime')
                      AND reverted_checked_at IS NULL) reversions_owed
           FROM cell_state""").fetchone()
    q = db.conn.execute("SELECT COUNT(*) FROM question_verdicts").fetchone()[0]
    obs = db.conn.execute("SELECT COUNT(*) FROM price_observations").fetchone()[0]
    return {"cells": row["n"], "with_everyday": row["everyday"],
            "on_ad_now": row["on_ad"], "ad_reversions_owed": row["reversions_owed"],
            "banked_questions": q, "evidence_rows": obs,
            "rows_per_answer": round(obs / row["n"], 1) if row["n"] else None}


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
        "state": state_summary(db),
        "gate_checks": {k: v["ok"] for k, v in checks["checks"].items()},
        "gate_check_detail": {k: v["detail"] for k, v in checks["checks"].items()
                              if not v["ok"]},
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

    if rep.get("state"):
        s = rep["state"]
        print(f"\n  price state: {s['cells']} cells "
              f"({s['with_everyday']} everyday, {s['on_ad_now']} on ad now), "
              f"{s['banked_questions']} banked questions")
        print(f"     evidence rows {s['evidence_rows']}  "
              f"({s['rows_per_answer']} per answer)   "
              f"ad reversions owed: {s['ad_reversions_owed']}")

    print("\n  gate checks:")
    for name, ok in rep["gate_checks"].items():
        print(f"     {'PASS' if ok else 'FAIL'}  {name}")
    for name, detail in rep["gate_check_detail"].items():
        print(f"           {json.dumps(detail, default=str)[:200]}")

    if rep["learning"]:
        print(f"\n  learning: {rep['learning']}")

    print("\n  NOTE: the graph is non-authoritative. The legacy pipeline runs the")
    print("        live board. The only time-based gates are ad timing and the")
    print("        90-day quarter (capture-policy.ps1 MaxCarryDays).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
