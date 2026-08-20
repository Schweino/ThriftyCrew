"""Gold-set scoring — the plan's four first-class metrics (§11).

    python graph/eval/score.py                 # deterministic layers only
    python graph/eval/score.py --llm           # include the LLM adjudication layer
    python graph/eval/score.py --llm --context "shadow:patch-123"

Metrics, and why each exists:

  entity/relation precision & recall
      the standard extraction quality pair.

  FALSE-MERGE RATE   fraction of gold NO_MATCH cases the system called MATCH.
      The dangerous error. A false merge publishes a wrong price — the
      2026-07-14 blueberries-as-Bai-beverage and 2026-07-28 coconut-oil-as-Epsom-
      salt incidents were both false merges. Phase 2's exit gate caps this at 2%.

  MISSED-MERGE RATE  fraction of gold MATCH cases the system failed to match.
      The safe error: one empty board cell. Gate is a far looser 10%, and that
      asymmetry is deliberate — it encodes "prefer a missed merge over a false one".

Every scored run is written to eval_runs with the exact model and prompt version,
so a regression can always be attributed to a specific change.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pipeline"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "gold"))

from graphdb import open_db                        # noqa: E402
from ids import hash_obj                           # noqa: E402
from llm import LocalLLM                           # noqa: E402
from resolve import Resolver                       # noqa: E402
from seed_gold import load_gold                    # noqa: E402

# Phase-gate thresholds from the implementation plan §12.
GATE_FALSE_MERGE = 0.02
GATE_MISSED_MERGE = 0.10


def _safe_div(a: float, b: float) -> float:
    return a / b if b else 0.0


def score(db, gold: list[dict], use_llm: bool = False,
          llm: LocalLLM | None = None, progress=None) -> dict:
    """Run every gold case through the resolver and score the verdicts."""
    r = Resolver(db, llm=llm, use_llm=use_llm)

    tp = fp = tn = fn = 0          # w.r.t. the MATCH class
    unsure = missing = 0
    errors: list[dict] = []

    match_cases = [g for g in gold if g["kind"] == "match"]
    for i, g in enumerate(match_cases):
        node = g["commodity_node"]
        if not db.get_node(node):
            # try the recipe namespace before giving up
            alt = node.replace(":staple:", ":recipe:")
            node = alt if db.get_node(alt) else None
        if not node:
            missing += 1
            continue

        v = r.resolve(node, g["product"], allow_llm=use_llm)
        predicted_match = v.is_match
        if v.status == "escalated":
            unsure += 1

        if g["label"] == "MATCH":
            if predicted_match:
                tp += 1
            else:
                fn += 1
                errors.append({"type": "missed_merge", "commodity": g["commodity"],
                               "product": g["product"], "status": v.status,
                               "reason": v.reason[:200]})
        else:  # NO_MATCH
            if predicted_match:
                fp += 1
                errors.append({"type": "false_merge", "commodity": g["commodity"],
                               "product": g["product"], "status": v.status,
                               "reason": v.reason[:200],
                               "gold_evidence": g.get("evidence", "")[:200]})
            else:
                tn += 1

        if progress and (i + 1) % 100 == 0:
            progress(f"    scored {i+1}/{len(match_cases)}")

    n_pos = tp + fn      # gold MATCH count
    n_neg = tn + fp      # gold NO_MATCH count

    metrics = {
        "entity_precision": _safe_div(tp, tp + fp),
        "entity_recall": _safe_div(tp, tp + fn),
        # Relation P/R: in this catalog the relation IS instance_of(product,
        # commodity), so it coincides with the entity pair. Kept as distinct
        # fields because the plan names them separately and a future extraction
        # stage will produce relations that do NOT coincide.
        "relation_precision": _safe_div(tp, tp + fp),
        "relation_recall": _safe_div(tp, tp + fn),
        "false_merge_rate": _safe_div(fp, n_neg),
        "missed_merge_rate": _safe_div(fn, n_pos),
        "counts": {"tp": tp, "fp": fp, "tn": tn, "fn": fn,
                   "gold_match": n_pos, "gold_no_match": n_neg,
                   "escalated": unsure, "missing_node": missing},
        "by_status": dict(r.stats),
    }
    metrics["f1"] = _safe_div(2 * metrics["entity_precision"] * metrics["entity_recall"],
                              metrics["entity_precision"] + metrics["entity_recall"])
    metrics["gates"] = {
        "false_merge_ok": metrics["false_merge_rate"] <= GATE_FALSE_MERGE,
        "missed_merge_ok": metrics["missed_merge_rate"] <= GATE_MISSED_MERGE,
    }
    metrics["errors"] = errors
    return metrics


def record(db, metrics: dict, model: str | None, prompt_version: str,
           gold: list[dict], context: str, ts: str) -> str:
    eid = "eval:" + hash_obj([ts, model, prompt_version, context])[:20]
    db.conn.execute(
        """INSERT INTO eval_runs
             (id, run_at, model, prompt_version, gold_version,
              entity_precision, entity_recall, relation_precision, relation_recall,
              false_merge_rate, missed_merge_rate, n_gold, n_pred, context, detail_json)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(id) DO NOTHING""",
        (eid, ts, model, prompt_version, hash_obj([g["id"] for g in gold])[:16],
         metrics["entity_precision"], metrics["entity_recall"],
         metrics["relation_precision"], metrics["relation_recall"],
         metrics["false_merge_rate"], metrics["missed_merge_rate"],
         len(gold), metrics["counts"]["tp"] + metrics["counts"]["fp"],
         context, json.dumps({k: v for k, v in metrics.items() if k != "errors"},
                             default=str)))
    db.conn.commit()
    return eid


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--llm", action="store_true", help="include the LLM adjudication layer")
    ap.add_argument("--context", default="phase2")
    ap.add_argument("--prompt-version", default="resolve.v1")
    ap.add_argument("--show-errors", type=int, default=8)
    ap.add_argument("--json", action="store_true", help="emit metrics as JSON only")
    args = ap.parse_args()

    gold = load_gold()
    if not gold:
        print("no gold set — run: python graph/gold/seed_gold.py", file=sys.stderr)
        return 2

    llm = LocalLLM() if args.llm else None
    if args.llm and not llm.health():
        print("local endpoint is down — start it with tools/local-llm/serve.ps1", file=sys.stderr)
        return 2

    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    with open_db() as db:
        t0 = time.time()
        m = score(db, gold, use_llm=args.llm, llm=llm,
                  progress=None if args.json else print)
        elapsed = time.time() - t0
        model = (llm.model if args.llm else "deterministic-only")
        record(db, m, model, args.prompt_version, gold, args.context, ts)

    if args.json:
        print(json.dumps(m, indent=2, default=str))
        return 0

    c = m["counts"]
    print(f"\n=== gold-set score ({model}, {len(gold)} cases, {elapsed:.1f}s) ===")
    print(f"  entity precision  {m['entity_precision']:.3f}")
    print(f"  entity recall     {m['entity_recall']:.3f}")
    print(f"  f1                {m['f1']:.3f}")
    print(f"  false-merge rate  {m['false_merge_rate']:.4f}   "
          f"gate <= {GATE_FALSE_MERGE}   {'PASS' if m['gates']['false_merge_ok'] else 'FAIL'}")
    print(f"  missed-merge rate {m['missed_merge_rate']:.4f}   "
          f"gate <= {GATE_MISSED_MERGE}   {'PASS' if m['gates']['missed_merge_ok'] else 'FAIL'}")
    print(f"  tp={c['tp']} fp={c['fp']} tn={c['tn']} fn={c['fn']} "
          f"escalated={c['escalated']} missing_node={c['missing_node']}")

    if args.show_errors and m["errors"]:
        print(f"\n  --- first {args.show_errors} errors ---")
        for e in m["errors"][:args.show_errors]:
            print(f"  [{e['type']}] {e['commodity']}")
            print(f"      product: {e['product'][:70]}")
            print(f"      got: {e['status']} — {e['reason'][:90]}")

    ok = m["gates"]["false_merge_ok"] and m["gates"]["missed_merge_ok"]
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
