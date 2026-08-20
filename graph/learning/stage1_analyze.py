"""Learning Stage 1 — local analysis, free and offline (plan §5, Phase 5).

    python graph/learning/stage1_analyze.py
    python graph/learning/stage1_analyze.py --max-items 40 --dry-run

Runs after the daily pipeline (or 2-3x/week). Reads the learning queue and the
graph's own failure surface, and emits a structured **Learning Proposal**: a set
of concrete, minimal, high-specificity suggestions, each with its own confidence.

WHAT STAGE 1 MAY PROPOSE (deliberately narrow):
  * add_alias        an exact new include pattern for ONE named commodity
  * add_known_wrong  a specific (commodity, store, product) negative
  * add_gold         a specific case to add to the gold set
  * tighten_prompt   a small, targeted prompt edit

WHAT IT MAY NOT PROPOSE: broad schema changes, large prompt rewrites, anything
touching more than one commodity at a time. The constraint is the safety
mechanism — a local model given licence to restructure the catalog will
eventually do so, and a wide change is exactly the one whose blast radius nobody
can eyeball. Wide changes stay a human's job.

The queue itself (grocery/learning-queue.json) is GITIGNORED, following
triage-queue.json: producer and consumer are the same PC, so it never crosses
the git-bus, and its bodies carry raw store text.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
sys.path.insert(0, os.path.join(HERE, "..", "pipeline"))
sys.path.insert(0, os.path.join(HERE, "..", "gold"))

from graphdb import open_db, GRAPH_DIR, REPO_ROOT       # noqa: E402
from ids import hash_obj                                # noqa: E402
from llm import LocalLLM                                # noqa: E402

QUEUE = os.path.join(REPO_ROOT, "grocery", "learning-queue.json")

PROPOSAL_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["suggestions"],
    "properties": {
        "suggestions": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["kind", "target", "payload", "confidence", "rationale"],
                "properties": {
                    "kind": {"type": "string",
                             "enum": ["add_alias", "add_known_wrong", "add_gold",
                                      "tighten_prompt"]},
                    "target": {"type": "string",
                               "description": "the commodity id the suggestion touches"},
                    "payload": {"type": "string",
                                "description": "the exact pattern / product name / case"},
                    "confidence": {"type": "number", "minimum": 0, "maximum": 1},
                    "rationale": {"type": "string"},
                },
            },
        },
    },
}

STAGE1_SYSTEM = (
    "You are the offline analysis stage of a grocery price board's learning loop.\n"
    "You are shown cases the automated resolver could NOT settle, plus recent failures.\n\n"
    "Propose only CONCRETE, MINIMAL, SINGLE-COMMODITY fixes:\n"
    "  add_alias       — an exact regex include pattern for ONE commodity\n"
    "  add_known_wrong — a specific product that is NOT a given commodity\n"
    "  add_gold        — a specific case worth adding to the evaluation set\n"
    "  tighten_prompt  — a small, targeted prompt clarification\n\n"
    "HARD LIMITS. Do not propose schema changes. Do not propose broad prompt "
    "rewrites. Do not propose anything affecting more than one commodity. Do not "
    "propose a pattern so general it could match a different food — an over-broad "
    "alias is how a wrong product steals a price, which is the worst outcome here.\n\n"
    "WHAT A GOOD add_alias LOOKS LIKE. Most unresolved rows are the SAME food "
    "written in a different word order, or with a brand in front. Those are "
    "exactly what you should fix:\n"
    "  commodity 'Black Pepper (ground)' <- 'Our Family Pepper, Black, Pure Ground 2 Oz'\n"
    "    -> add_alias target='black-pepper' payload='pepper,?\\\\s*black' (confidence 0.9)\n"
    "  commodity 'Ranch Dressing' <- \"Newman's Own Dressing, Ranch 16 Fl Oz\"\n"
    "    -> add_alias target='ranch-dressing' payload='dressing,?\\\\s*ranch' (confidence 0.9)\n"
    "Anchor the pattern on words that name the FOOD. Never anchor on a brand "
    "alone, and never write a pattern that would also match a different food "
    "(e.g. 'ranch' alone would catch ranch-flavored chips).\n\n"
    "When a listing is genuinely a DIFFERENT product than the commodity (a "
    "'Snack Medley' under Dried Cranberries, a 'Fabric & Carpet Spray' under Air "
    "Freshener), propose add_known_wrong instead.\n\n"
    "Be useful AND careful: propose the clear cases, skip the ambiguous ones. "
    "An empty list is acceptable only if nothing shown is clear.\n"
    "Give each suggestion an honest confidence. Output JSON only."
)


def gather_queue(limit: int) -> list[dict]:
    if not os.path.exists(QUEUE):
        return []
    try:
        with open(QUEUE, encoding="utf-8-sig") as fh:
            rows = json.load(fh)
    except (json.JSONDecodeError, OSError):
        return []
    return rows[-limit:] if isinstance(rows, list) else []


def gather_contested(db, limit: int) -> list[dict]:
    """Rows the deterministic layers could not settle, most frequent first.

    Frequency matters: a product name that shows up unresolved in every capture
    is worth a rule, while a one-off is probably just noise.
    """
    rows = db.conn.execute(
        """SELECT p.commodity_id, p.product_name, COUNT(*) n,
                  MAX(n2.canonical_name) AS commodity_label
           FROM price_observations p
           LEFT JOIN nodes n2 ON n2.id = p.commodity_id
           WHERE p.match_status IN ('no_include_hit','escalated')
             AND p.product_name IS NOT NULL
           GROUP BY p.commodity_id, p.product_name
           ORDER BY n DESC
           LIMIT ?""", (limit,)).fetchall()
    return [dict(r) for r in rows]


def gather_gold_failures(db, limit: int) -> list[dict]:
    """Most recent gold-set errors, from the last scored run."""
    row = db.conn.execute(
        "SELECT detail_json FROM eval_runs ORDER BY run_at DESC LIMIT 1").fetchone()
    if not row:
        return []
    try:
        d = json.loads(row["detail_json"])
    except (json.JSONDecodeError, TypeError):
        return []
    return (d.get("errors") or [])[:limit]


def build_prompt(queue: list, contested: list, failures: list) -> str:
    parts = []
    if contested:
        parts.append("UNRESOLVED CANDIDATE ROWS (commodity <- product listing, seen N times):")
        for c in contested[:25]:
            parts.append(f"  [{c['n']}x] {c.get('commodity_label') or c['commodity_id']}"
                         f"  <-  {c['product_name']}")
    if failures:
        parts.append("\nRECENT GOLD-SET FAILURES:")
        for f in failures[:15]:
            parts.append(f"  [{f.get('type')}] {f.get('commodity')} <- {f.get('product')}"
                         f"   (got {f.get('status')})")
    if queue:
        parts.append("\nESCALATIONS FROM THE DAILY RUN:")
        for q in queue[:15]:
            parts.append(f"  {json.dumps(q, default=str)[:220]}")
    parts.append("\nPropose concrete single-commodity fixes, or an empty list.")
    return "\n".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-items", type=int, default=40)
    ap.add_argument("--dry-run", action="store_true", help="print the prompt, call nothing")
    ap.add_argument("--max-tokens", type=int, default=2500)
    args = ap.parse_args()

    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    run = f"run:learning1:{time.strftime('%Y%m%dT%H%M%S')}"

    with open_db() as db:
        queue = gather_queue(args.max_items)
        contested = gather_contested(db, args.max_items)
        failures = gather_gold_failures(db, args.max_items)

        if not (queue or contested or failures):
            print("learning queue is empty and nothing is contested — nothing to analyse.")
            return 0

        user = build_prompt(queue, contested, failures)
        print(f"queue={len(queue)}  contested={len(contested)}  gold_failures={len(failures)}")

        if args.dry_run:
            print("\n--- prompt ---\n" + user[:4000])
            return 0

        llm = LocalLLM()
        if not llm.health():
            print("local endpoint down — start it: pwsh tools/local-llm/serve.ps1",
                  file=sys.stderr)
            return 2

        parsed, res = llm.json_call(STAGE1_SYSTEM, user, schema=PROPOSAL_SCHEMA,
                                    max_tokens=args.max_tokens)
        suggestions = parsed.get("suggestions", []) or []
        qhash = hash_obj([queue, contested, failures])

        kept = 0
        for s in suggestions:
            # Stage 1 is not trusted to police its own scope; enforce it here.
            if s.get("kind") not in ("add_alias", "add_known_wrong", "add_gold",
                                     "tighten_prompt"):
                continue
            pid = "lp:" + hash_obj([s.get("kind"), s.get("target"), s.get("payload")])[:20]
            db.conn.execute(
                """INSERT INTO learning_proposals
                     (id, created_at, model, queue_hash, kind, target_id,
                      payload_json, confidence, rationale, status)
                   VALUES (?,?,?,?,?,?,?,?,?, 'proposed')
                   ON CONFLICT(id) DO NOTHING""",
                (pid, ts, res.model, qhash, s["kind"], s.get("target"),
                 json.dumps({"payload": s.get("payload")}, ensure_ascii=False),
                 float(s.get("confidence", 0) or 0), s.get("rationale")))
            kept += 1
        db.conn.commit()
        # Write through to tracked JSON immediately. Proposals exist nowhere
        # else, so the window between writing them and exporting them is a
        # window in which a crash destroys them.
        db.export_learning()

        db.log_event(run=run, timestamp=ts, etype="learning_proposal",
                     model=res.model, output_hash=res.output_hash,
                     decision="stage1_complete",
                     detail={"suggested": len(suggestions), "recorded": kept,
                             "queue_hash": qhash})

        print(f"\nStage 1 produced {len(suggestions)} suggestion(s), recorded {kept}:")
        for s in suggestions[:12]:
            print(f"  [{s.get('confidence', 0):.2f}] {s.get('kind'):<16} "
                  f"{str(s.get('target'))[:28]:<28} {str(s.get('payload'))[:44]}")
            print(f"         {str(s.get('rationale'))[:100]}")
        if kept:
            print(f"\nNext: python graph/learning/stage2_review.py --emit-packet")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
