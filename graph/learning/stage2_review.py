"""Learning Stage 2 — Fable review, then gated application (plan §5, Phase 5).

    python graph/learning/stage2_review.py --emit-packet        # -> review packet
    python graph/learning/stage2_review.py --ingest verdicts.json
    python graph/learning/stage2_review.py --apply              # shadow-eval + apply

Stage 2 is Claude Fable at medium effort. In THIS estate Claude runs as scheduled
agents with repo and real-Chrome access, not as a library call from the daily
pipeline — so this module does not call an API. It does the three things around
the review that must be mechanical and auditable:

  --emit-packet  distils the proposals into a review packet. Fable sees ONLY the
                 distilled proposals, never the raw logs or full history (plan §5).
  --ingest       records Fable's verdicts (accept/reject/modify/defer/hold).
  --apply        SHADOW-EVALUATES every accepted patch against the gold set and
                 applies ONLY those that do not regress.

THE SAFETY GATE IS THE WHOLE POINT. An accepted patch is scored before and after
against the gold set; if precision, recall, false-merge rate or missed-merge rate
gets worse, the patch is REJECTED no matter who approved it. A review is a human
(or model) judgement; the gold set is evidence, and evidence wins. High-impact
changes additionally stay held for human confirmation during early phases.

AN APPROVAL IS SCOPED TO THE RESOLUTION REGIME THAT GRANTED IT.
`resolve_target` decides which commodity a patch touches. A patch whose target
does not resolve is left retryable rather than failed (the index can legitimately
be empty mid-rebuild) — but that leaves pre-approved patches parked indefinitely,
and the moment anyone WIDENS the resolution ladder they all apply at once, with
no fresh eyes. Four were found parked on 2026-08-20, all approved months earlier
against LEGACY-style target ids the graph never adopted (`black-pepper-ground`,
`dish-soap-liquid`) rather than namespaced node ids. Their payloads are not
obviously wrong — that is the point. Nobody re-read them, and a one-line change
to the ladder would have applied all four unreviewed.

    python graph/learning/stage2_review.py --requeue-stuck

demotes exactly that state back to `proposed` so it re-enters review. RUN IT
BEFORE ANY CHANGE TO `resolve_target`. The invariant it protects: an approval
granted under one target-resolution regime never applies under a different one.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
sys.path.insert(0, os.path.join(HERE, "..", "pipeline"))
sys.path.insert(0, os.path.join(HERE, "..", "eval"))
sys.path.insert(0, os.path.join(HERE, "..", "gold"))

from graphdb import open_db, GRAPH_DIR                  # noqa: E402
from ids import hash_obj                                # noqa: E402
from score import score, GATE_FALSE_MERGE, GATE_MISSED_MERGE   # noqa: E402
from seed_gold import load_gold                         # noqa: E402

PACKET = os.path.join(GRAPH_DIR, "learning", "review-packet.json")

# A patch touching more than this many cells is "high impact" and is held for a
# human during early phases regardless of its shadow score.
HIGH_IMPACT_CELLS = 25


def _blast_radius_index() -> dict:
    """The alias blast-radius report, if one has been generated. Keyed by
    proposal id. Absent file is not an error — the report is derived evidence,
    not a dependency."""
    path = os.path.join(GRAPH_DIR, "learning", "alias-blast-radius.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8-sig") as fh:
            return json.load(fh).get("proposals", {})
    except (json.JSONDecodeError, OSError):
        return {}


def emit_packet(db) -> str:
    rows = db.conn.execute(
        """SELECT id, kind, target_id, payload_json, confidence, rationale, created_at
           FROM learning_proposals WHERE status='proposed' ORDER BY confidence DESC"""
    ).fetchall()
    blast = _blast_radius_index()
    proposals = []
    for r in rows:
        payload = json.loads(r["payload_json"] or "{}")
        node = db.get_node(r["target_id"]) if r["target_id"] else None
        entry = {
            "proposal_id": r["id"],
            "kind": r["kind"],
            "target": r["target_id"],
            "target_label": node["canonical_name"] if node else None,
            "payload": payload.get("payload"),
            "stage1_confidence": r["confidence"],
            "rationale": r["rationale"],
        }
        # An add_alias verdict made without the blast radius is made on the gold
        # set alone — and for review-derived aliases the gold set is circular
        # evidence (see alias_blast_radius.py). Attach what the corpus says.
        b = blast.get(r["id"])
        if b:
            entry["blast_radius"] = {
                "counts": b.get("counts"),
                "kill": b.get("kill", False),
                "kill_reasons": b.get("kill_reasons", []),
                "warn_reasons": b.get("warn_reasons", []),
                "examples": b.get("examples", {}),
            }
        elif r["kind"] == "add_alias":
            entry["blast_radius"] = {
                "missing": "no blast-radius report for this proposal — run "
                           "graph/learning/alias_blast_radius.py before ruling on it"}
        proposals.append(entry)

    packet = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "reviewer": "claude-fable-medium",
        "instructions": (
            "For each proposal return one verdict object: "
            "{proposal_id, verdict: accept|reject|modify|defer|hold_for_human, "
            "payload (required if modify), rationale}. "
            "Reject anything whose pattern could match a DIFFERENT food — an "
            "over-broad alias lets a wrong product take a price, which is the "
            "failure this board exists to prevent. Prefer reject over accept "
            "when uncertain; a missed alias costs one empty cell. Mark "
            "hold_for_human when the change is broad or the evidence is thin. "
            "For add_alias, READ blast_radius first: kill=true is an automatic "
            "reject (the pattern re-litigates an adjudicated ruling or "
            "resurrects a rejection, and include runs before the model). Any "
            "cross_commodity hit needs a written reason why the collision is "
            "benign, or a `modify` payload that tightens the pattern. "
            "absorbs_review + intended_capture are what the alias BUYS; a "
            "proposal with none of either is noise."
        ),
        "gates": {
            "false_merge_rate_max": GATE_FALSE_MERGE,
            "missed_merge_rate_max": GATE_MISSED_MERGE,
            "note": ("every accepted patch is shadow-scored against the gold set "
                     "before it goes live; a patch that regresses any metric is "
                     "dropped regardless of this review's verdict"),
        },
        "proposals": proposals,
    }
    os.makedirs(os.path.dirname(PACKET), exist_ok=True)
    with open(PACKET, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(packet, fh, indent=2, ensure_ascii=False)
    return PACKET


def ingest(db, path: str) -> dict:
    with open(path, encoding="utf-8-sig") as fh:
        data = json.load(fh)
    verdicts = data.get("verdicts", data if isinstance(data, list) else [])
    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    n = 0
    for v in verdicts:
        pid = v.get("proposal_id")
        verdict = (v.get("verdict") or "").lower()
        if not pid or verdict not in ("accept", "reject", "modify", "defer",
                                      "hold_for_human"):
            continue
        row = db.conn.execute(
            "SELECT payload_json FROM learning_proposals WHERE id=?", (pid,)).fetchone()
        if not row:
            continue
        payload = json.loads(row["payload_json"] or "{}")
        if verdict == "modify" and v.get("payload"):
            payload["payload"] = v["payload"]
        apid = "ap:" + hash_obj([pid, verdict, payload])[:20]
        db.conn.execute(
            """INSERT INTO approved_patches
                 (id, proposal_id, reviewed_at, reviewer, verdict, payload_json,
                  rationale, shadow_verdict)
               VALUES (?,?,?,?,?,?,?, 'not_run')
               ON CONFLICT(id) DO NOTHING""",
            (apid, pid, ts, data.get("reviewer", "claude-fable-medium"), verdict,
             json.dumps(payload, ensure_ascii=False), v.get("rationale")))
        status = {"accept": "accepted", "reject": "rejected", "modify": "modified",
                  "defer": "deferred", "hold_for_human": "held_for_human"}[verdict]
        db.conn.execute("UPDATE learning_proposals SET status=? WHERE id=?", (status, pid))
        n += 1
    db.conn.commit()
    db.export_learning()      # write through: a verdict exists nowhere else
    db.log_event(run=f"run:learning2:{time.strftime('%Y%m%dT%H%M%S')}", timestamp=ts,
                 etype="learning_approval", decision="stage2_ingest",
                 detail={"verdicts": n, "source": os.path.basename(path)})
    return {"ingested": n}


# ---------------------------------------------------------------------------
# shadow evaluation + application
# ---------------------------------------------------------------------------

def resolve_target(db, target: str | None) -> str | None:
    """Map whatever Stage 1 called the commodity onto a real node id.

    Stage 1 sees human labels ("Ranch Dressing") and answers with legacy-style
    ids ("ranch-dressing"), while the graph keys on namespaced node ids
    ("commodity:staple:ranch-dressing"). Resolving here — rather than trusting
    the model to produce a node id — keeps a wrong guess from silently creating
    an orphan patch that applies to nothing.
    """
    if not target:
        return None
    if db.get_node(target):
        return target
    for ns in ("staple", "recipe"):
        cand = f"commodity:{ns}:{target}"
        if db.get_node(cand):
            return cand
    # Last resort: match on canonical label, case-insensitively.
    row = db.conn.execute(
        """SELECT id FROM nodes WHERE type='Commodity'
           AND lower(canonical_name)=lower(?) LIMIT 1""", (target,)).fetchone()
    return row["id"] if row else None


def payload_is_sane(kind: str, payload: str) -> tuple[bool, str]:
    """Reject a payload that would silently become a different rule than it reads.

    Two failure modes, both from carrying regexes through JSON:

    * A CONTROL CHARACTER means an escape was eaten. "\\b" is a LEGAL JSON escape
      for backspace, so a word-boundary pattern the model meant as \\\\b parses
      cleanly into a literal backspace and installs a rule that can never match
      anything. json.loads succeeds, the shadow gate sees no regression because
      the pattern is inert, and a dead rule enters the catalog looking healthy.
    * A pattern that will not COMPILE is caught here rather than swallowed by
      _compile_all(), which skips bad regexes silently by design so one broken
      stored pattern cannot take down a pipeline run.
    """
    if kind not in ("add_alias",):
        return True, ""
    if not payload:
        return False, "empty payload"
    bad = [c for c in payload if ord(c) < 32]
    if bad:
        return False, (f"contains control character {bad[0]!r} — an escape was "
                       f"eaten in transit (\\b is legal JSON for backspace); "
                       f"the rule would be inert")
    try:
        re.compile(payload, re.IGNORECASE)
    except re.error as e:
        return False, f"does not compile as a regex: {e}"
    return True, ""


def _apply_to_graph(db, kind: str, target: str, payload: str, ts: str,
                    prov: str) -> int:
    """Effect one patch on the graph. Returns rows touched."""
    ok, why = payload_is_sane(kind, payload)
    if not ok:
        raise ValueError(f"refusing to apply {kind} {payload!r}: {why}")
    if kind == "add_alias":
        db.add_alias(target, payload, "learning-patch", ts, kind="include",
                     is_regex=True, confidence=0.9, provenance=prov)
        return 1
    if kind == "add_known_wrong":
        from ids import known_wrong_id
        kwid = known_wrong_id(target, "*", payload)
        db.upsert_node(kwid, "KnownWrong", payload, ts,
                       description="added by the learning loop",
                       properties={"commodity": target, "source": "learning"},
                       provenance=prov)
        db.upsert_edge(kwid, "known_wrong_for", target, ts, provenance=prov)
        return 1
    # add_gold and tighten_prompt are handled outside the graph (files), and are
    # never auto-applied — they change what "correct" MEANS, so a model may not
    # edit them unreviewed.
    return 0


def reapply_applied_patches(db, ts: str, run: str = "") -> dict:
    """Re-materialise every patch already marked applied. Idempotent.

    The learning loop's RECORD is durable (learning_proposals and
    approved_patches are tracked JSON), but its EFFECT lived only in the
    rebuildable index: `learned` aliases are written into the graph, never back
    into commodities.json, because nothing here writes to the legacy estate.
    So a routine `rm graph.db` + re-import silently un-applied every patch the
    loop had ever landed — 157 of them on 2026-08-20 — while the proposals went
    on reporting status='applied'. The README's promise that deleting the index
    is always safe was false for exactly this table.

    Called from import_all after the lanes land, so the graph a rebuild produces
    is the graph that was there before it.
    """
    rows = db.conn.execute(
        """SELECT p.id, p.kind, p.target_id, a.payload_json
           FROM learning_proposals p JOIN approved_patches a ON a.proposal_id = p.id
           WHERE p.status='applied' AND a.verdict IN ('accept','modify')""").fetchall()
    if not rows:
        return {"reapplied": 0}
    prov = db.record_provenance("graph/learning/approved-patches.json",
                                "learning:reapply", ts, run=run)
    n = 0
    for r in rows:
        payload = (json.loads(r["payload_json"] or "{}") or {}).get("payload")
        if not payload:
            continue
        target = resolve_target(db, r["target_id"])
        if not target:
            continue
        n += _apply_to_graph(db, r["kind"], target, payload, ts, prov)
    db.conn.commit()
    return {"reapplied": n}


def requeue_stuck(db) -> dict:
    """Demote approved-but-unappliable patches back to proposals.

    Selects the exact parked state — approved (accept|modify), never applied,
    shadow never run — and keeps only those whose target STILL does not resolve.
    A patch whose target resolves today is not stuck; it is simply waiting for
    the next --apply, and demoting it would throw away a valid review.

    This is deliberately a DEMOTION and never a promotion: it can only move work
    back toward review, so running it when in doubt is always safe.
    """
    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    run = f"run:learning-requeue:{time.strftime('%Y%m%dT%H%M%S')}"
    rows = db.conn.execute(
        """SELECT a.id, a.proposal_id, a.verdict, p.kind, p.target_id
           FROM approved_patches a
           JOIN learning_proposals p ON p.id = a.proposal_id
           WHERE a.verdict IN ('accept','modify')
             AND a.applied_at IS NULL
             AND a.shadow_verdict = 'not_run'""").fetchall()

    requeued = []
    for r in rows:
        if resolve_target(db, r["target_id"]):
            continue                      # resolves now — not stuck, leave it
        db.conn.execute(
            "UPDATE approved_patches SET shadow_verdict='requeued' WHERE id=?",
            (r["id"],))
        db.conn.execute(
            "UPDATE learning_proposals SET status='proposed' WHERE id=?",
            (r["proposal_id"],))
        db.log_event(run=run, timestamp=ts, etype="learning_approval",
                     decision="requeued_stuck",
                     detail={"patch": r["id"], "proposal": r["proposal_id"],
                             "prior_verdict": r["verdict"], "kind": r["kind"],
                             "target_id": r["target_id"],
                             "why": "approved patch whose target does not resolve; "
                                    "demoted so a widened resolution ladder cannot "
                                    "apply it without re-review"})
        requeued.append({"patch": r["id"], "proposal": r["proposal_id"],
                         "target": r["target_id"], "kind": r["kind"]})

    db.conn.commit()
    if requeued:
        db.export_learning()
    return {"candidates": len(rows), "requeued": requeued}


def shadow_and_apply(db, dry_run: bool = False) -> dict:
    """Score every accepted patch against the gold set, apply only clean ones."""
    gold = load_gold()
    if not gold:
        return {"error": "no gold set — run graph/gold/seed_gold.py"}

    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    run = f"run:learning-apply:{time.strftime('%Y%m%dT%H%M%S')}"

    before = score(db, gold, use_llm=False)
    base = {k: before[k] for k in ("entity_precision", "entity_recall",
                                   "false_merge_rate", "missed_merge_rate")}

    # Which commodities the gold set can actually speak to. A patch outside this
    # set cannot be shadow-proven; see the hold below.
    gold_targets: set[str] = set()
    for g in gold:
        node = g.get("commodity_node")
        if node and db.get_node(node):
            gold_targets.add(node)
        else:
            alt = (node or "").replace(":staple:", ":recipe:")
            if alt and db.get_node(alt):
                gold_targets.add(alt)

    rows = db.conn.execute(
        """SELECT a.id, a.proposal_id, a.verdict, a.payload_json,
                  p.kind, p.target_id
           FROM approved_patches a
           JOIN learning_proposals p ON p.id = a.proposal_id
           WHERE a.verdict IN ('accept','modify')
             AND a.applied_at IS NULL
             AND a.shadow_verdict = 'not_run'""").fetchall()

    applied, rejected, held = [], [], []
    prov = db.record_provenance("graph/learning/stage2_review.py",
                                "learning:apply", ts, run=run)

    for r in rows:
        payload = json.loads(r["payload_json"] or "{}").get("payload")
        kind = r["kind"]
        target = resolve_target(db, r["target_id"])
        if not (payload and target):
            # NOT a regression, and recording it as one was a real bug: a patch
            # whose target cannot be resolved has told us nothing about the gold
            # set. Worse, 'regression' is terminal -- these rows are filtered out
            # of future runs -- so a transient condition became permanent. The
            # index is DERIVED and can legitimately be empty (immediately after a
            # rebuild drill, before import_all has run), and every patch would be
            # written off forever for a reason that fixes itself.
            # Left as 'not_run' so it is retried once the index is populated.
            rejected.append({"patch": r["id"], "target": r["target_id"],
                             "why": "target did not resolve to a commodity node "
                                    "(is the index populated? run import_all) - "
                                    "left retryable"})
            continue
        if kind in ("add_gold", "tighten_prompt"):
            held.append({"patch": r["id"], "why": f"{kind} changes the definition of "
                                                  f"correct; never auto-applied"})
            db.conn.execute("UPDATE learning_proposals SET status='held_for_human' "
                            "WHERE id=?", (r["proposal_id"],))
            continue

        # A shadow gate can only catch a regression the GOLD SET CAN SEE. If no
        # gold case touches this commodity, "no regression" means "no evidence",
        # not "safe" — the patch would sail through on a delta of 0.0 precisely
        # because nothing was watching. That is the most dangerous way to pass a
        # safety gate, so uncovered commodities are held for a human instead.
        if target not in gold_targets:
            held.append({"patch": r["id"], "target": target, "payload": payload,
                         "why": "no gold-set coverage for this commodity — shadow "
                                "evaluation cannot prove it safe"})
            db.conn.execute("UPDATE learning_proposals SET status='held_for_human' "
                            "WHERE id=?", (r["proposal_id"],))
            db.conn.execute("UPDATE approved_patches SET shadow_verdict='not_run' "
                            "WHERE id=?", (r["id"],))
            continue

        # Apply inside a savepoint so a regressing patch leaves no trace.
        db.conn.execute("SAVEPOINT shadow")
        try:
            _apply_to_graph(db, kind, target, payload, ts, prov)
            after = score(db, gold, use_llm=False)
        except Exception as e:                                  # noqa: BLE001
            db.conn.execute("ROLLBACK TO shadow")
            rejected.append({"patch": r["id"], "why": f"error: {e}"})
            continue

        regressed = (
            after["false_merge_rate"] > base["false_merge_rate"] or
            after["missed_merge_rate"] > base["missed_merge_rate"] or
            after["entity_precision"] < base["entity_precision"] or
            after["entity_recall"] < base["entity_recall"]
        )
        delta = {k: round(after[k] - base[k], 5) for k in base}

        if regressed or dry_run:
            db.conn.execute("ROLLBACK TO shadow")
            verdict = "regression" if regressed else "not_run"
            (rejected if regressed else held).append(
                {"patch": r["id"], "target": target, "payload": payload,
                 "delta": delta, "why": "regressed the gold set" if regressed else "dry run"})
        else:
            db.conn.execute("RELEASE shadow")
            verdict = "no_regression"
            db.conn.execute(
                "UPDATE approved_patches SET applied_at=?, applied_by='learning-loop' "
                "WHERE id=?", (ts, r["id"]))
            db.conn.execute("UPDATE learning_proposals SET status='applied' WHERE id=?",
                            (r["proposal_id"],))
            applied.append({"patch": r["id"], "target": target, "payload": payload,
                            "delta": delta})
            base = {k: after[k] for k in base}      # subsequent patches build on this

        db.conn.execute(
            """UPDATE approved_patches
               SET shadow_before_json=?, shadow_after_json=?, shadow_verdict=?
               WHERE id=?""",
            (json.dumps(base), json.dumps({k: after[k] for k in base}), verdict, r["id"]))

    db.conn.commit()
    # Write through: the shadow before/after metrics are the EVIDENCE that a
    # patch was safe to apply. Losing them leaves applied changes with no record
    # of why they were allowed.
    db.export_learning()
    db.log_event(run=run, timestamp=ts, etype="learning_approval",
                 decision="shadow_and_apply",
                 detail={"applied": len(applied), "rejected": len(rejected),
                         "held": len(held), "baseline": base},
                 provenance_ids=[prov])
    return {"applied": applied, "rejected": rejected, "held": held,
            "baseline": base, "candidates": len(rows)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--emit-packet", action="store_true")
    ap.add_argument("--ingest", metavar="VERDICTS_JSON")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--requeue-stuck", action="store_true",
                    help="demote approved-but-unresolvable patches back to "
                         "'proposed'; run BEFORE widening resolve_target")
    args = ap.parse_args()

    if not (args.emit_packet or args.ingest or args.apply or args.requeue_stuck):
        ap.print_help()
        return 1

    with open_db() as db:
        if args.requeue_stuck:
            res = requeue_stuck(db)
            print(f"parked patches examined: {res['candidates']}   "
                  f"requeued: {len(res['requeued'])}")
            for r in res["requeued"]:
                print(f"   {r['kind']:<16} target={r['target']}  ({r['patch']})")
            if res["requeued"]:
                print("These are back at status='proposed' and will appear in the "
                      "next --emit-packet.")

        if args.emit_packet:
            p = emit_packet(db)
            n = len(json.load(open(p, encoding="utf-8"))["proposals"])
            print(f"review packet: {p}  ({n} proposal(s))")
            print("Hand this to the Fable review agent; ingest its verdicts with --ingest.")

        if args.ingest:
            print(ingest(db, args.ingest))

        if args.apply:
            res = shadow_and_apply(db, dry_run=args.dry_run)
            if "error" in res:
                print(res["error"], file=sys.stderr)
                return 2
            print(f"candidates: {res['candidates']}")
            print(f"  applied  {len(res['applied'])}")
            for a in res["applied"][:10]:
                print(f"     {a['target']}  <- {str(a['payload'])[:44]}   delta={a['delta']}")
            print(f"  rejected {len(res['rejected'])}  (gold-set regression, or an "
                  f"unresolvable target)")
            for x in res["rejected"][:10]:
                print(f"     {x.get('target')}  {x['why']}")
            print(f"  held     {len(res['held'])}  (human review)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
