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

# gate-inputs: graph\learning\stage2_review.py, graph\eval\audit_gold_circularity.py, graph\eval\score.py, graph\gold\seed_gold.py, graph\gold\gold_split.py, tools\local-llm\finetune-probe\split_holdout.py, graph\lib\graphdb.py, graph\lib\ids.py, graph\lib\learning_reconcile.py, graph\lib\supersede.py, graph\lib\units.py, graph\lib\authority.py, graph\lib\llm.py, graph\lib\service_time.py, graph\lib\placeholder_names.py, graph\pipeline\resolve.py, graph\pipeline\state.py, graph\sqlite\schema.sql, grocery\placeholder-name-patterns.json

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
from audit_gold_circularity import cases_moved, parse_derived_from   # noqa: E402
from gold_split import filter_split                     # noqa: E402

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

    # WS 7c (2026-09-10): hold-clear PROPOSALS ride the same packet, so a hold inert for a month reaches the
    # person who reads this. The packet never clears one - see the instruction below.
    try:
        from promote_aliases import clear_proposals, held_rows, load_rechecks
        hold_clears = clear_proposals(held_rows(), load_rechecks())
    except Exception as e:                                   # noqa: BLE001
        hold_clears = [{"missing": f"hold-clear proposals could not be computed: {e!r}"}]

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
            "proposal with none of either is noise. "
            "hold_clears are NOT proposals to rule on here: each names a promotion hold that has "
            "matched nothing on the board for 30 consecutive daily rechecks, with its readings. "
            "Clearing one means re-running the full guard suite (promote_aliases.py --gated) and "
            "stays with a person (ruling 2026-09-09, backlog I92)."
        ),
        "gates": {
            "false_merge_rate_max": GATE_FALSE_MERGE,
            "missed_merge_rate_max": GATE_MISSED_MERGE,
            "note": ("every accepted patch is shadow-scored against the gold set "
                     "before it goes live; a patch that regresses any metric is "
                     "dropped regardless of this review's verdict"),
        },
        "proposals": proposals,
        "hold_clears": hold_clears,
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


def untouched_hold(kind: str, target: str, payload, gold: list[dict]) -> str | None:
    """Why an add_alias patch cannot be shadow-proven because it matches no gold case, or None.

    Matched the way resolve.py step 4 matches an include: the raw product name, case-insensitive
    search, on gold rows of the patch's own commodity (staple and recipe twins share the bare id).
    Other kinds return None and keep their existing road; nothing here measures them.
    """
    if kind != "add_alias":
        return None
    n = cases_moved(str(payload), (target or "").split(":")[-1], gold)
    if n is None:
        return "the alias pattern does not compile - nothing can be shadow-scored"
    if n == 0:
        return ("no gold case matches this pattern - a delta of 0.0 would be no evidence, "
                "not safety")
    return None


# THE NOISE FLOOR PER ARM (W2; W4 of the same plan measures it). The shadow gate scores the DETERMINISTIC arm
# (use_llm=False), which must show zero spread run to run, so its floor is 0: any worsening is a regression.
# When W4 lands a measured floor for an arm that has spread, it goes here, per metric, never widened to pass.
NOISE_FLOOR = {"entity_precision": 0.0, "entity_recall": 0.0, "missed_merge_rate": 0.0}
ARM_METRICS = ("entity_precision", "entity_recall", "false_merge_rate", "missed_merge_rate")


def arm_regressed(before: dict, after: dict) -> list[str]:
    """The metrics that got worse on one arm, [] when none did.

    False-merge is judged with NO floor: a wrong product stealing a price is the worst outcome here, so a
    rise by any amount rejects (the asymmetry score.py's GATE_FALSE_MERGE already encodes). The others
    reject only past NOISE_FLOOR, which is 0 for the deterministic arm.
    """
    worse = []
    if after["false_merge_rate"] > before["false_merge_rate"]:
        worse.append("false_merge_rate")
    if after["missed_merge_rate"] > before["missed_merge_rate"] + NOISE_FLOOR["missed_merge_rate"]:
        worse.append("missed_merge_rate")
    for k in ("entity_precision", "entity_recall"):
        if after[k] < before[k] - NOISE_FLOOR[k]:
            worse.append(k)
    return worse


def circular_hold(kind: str, target: str, payload, gold: list[dict], own: set[str] | None) -> str | None:
    """Why a patch's only gold evidence is its own source case (D1: HOLD, Brad 2026-09-29), or None.

    `own` is the proposal's derived_from. None is BLIND (a proposal older than the column): the question
    cannot be asked, so this returns None and the patch keeps the road it had; the caller counts it.
    An alias is judged on the cases its pattern matches (the untouched hold's test); any other kind on the
    gold cases of its target, because that is all it can move.
    """
    if own is None:
        return None
    bare = (target or "").split(":")[-1]
    mine = [g for g in gold if (g.get("commodity_node") or "").split(":")[-1] == bare]
    if kind == "add_alias":
        try:
            rx = re.compile(str(payload), re.IGNORECASE)
        except re.error:
            return None                       # the untouched hold names this case
        mine = [g for g in mine if rx.search(g.get("product") or "")]
    if mine and all(g.get("id") in own for g in mine):
        return "only circular evidence - every gold case this patch touches is one it was derived from"
    return None


def shadow_and_apply(db, dry_run: bool = False) -> dict:
    """Score every accepted patch against the gold set, apply only clean ones.

    TWO ARMS, NOT ONE (W2 of design/PLAN-eval-heldout-and-hillclimb-2026-09-29.md). Beside today's whole-gold
    before/after, which still decides the baseline the next patch builds on, each patch is scored on the TRAIN
    and HOLDOUT arms (graph/gold/gold_split.py) with the gold cases it was derived from taken out of both. A
    worsening on EITHER arm rejects it (arm_regressed), so a fix to its own source case can no longer pay for a
    break elsewhere, which is exactly what one pooled score lets it do. A patch whose every touched gold case
    is its own source is held (D1). A proposal with no recorded provenance (NULL derived_from) cannot be
    asked either question about its source, so it is scored on both arms whole and counted as BLIND.
    """
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
                  p.kind, p.target_id, p.derived_from
           FROM approved_patches a
           JOIN learning_proposals p ON p.id = a.proposal_id
           WHERE a.verdict IN ('accept','modify')
             AND a.applied_at IS NULL
             AND a.shadow_verdict = 'not_run'""").fetchall()

    applied, rejected, held = [], [], []
    blind_provenance = 0
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

        # Coverage of the TARGET is not coverage of the PATCH. An alias that matches no gold case
        # changes no score, so it passes on a delta of exactly 0.0 with nothing watching it: W0 of
        # design/PLAN-eval-heldout-and-hillclimb-2026-09-29.md found 155 of the 159 applied aliases
        # matched none, and a dry run on 2026-09-29 passed 19 of 24 waiting ones on 0.0 everywhere.
        why = untouched_hold(kind, target, payload, gold)
        if why:
            held.append({"patch": r["id"], "target": target, "payload": payload,
                         "why": why, "untouched": True})
            db.conn.execute("UPDATE learning_proposals SET status='held_for_human' "
                            "WHERE id=?", (r["proposal_id"],))
            db.conn.execute("UPDATE approved_patches SET shadow_verdict='not_run' "
                            "WHERE id=?", (r["id"],))
            continue

        # Its own source cases are no evidence for it (D1, Brad 2026-09-29: hold, by the no-coverage road).
        own = parse_derived_from(r["derived_from"])
        if own is None:
            blind_provenance += 1
        why = circular_hold(kind, target, payload, gold, own)
        if why:
            held.append({"patch": r["id"], "target": target, "payload": payload,
                         "why": why, "circular": True})
            db.conn.execute("UPDATE learning_proposals SET status='held_for_human' "
                            "WHERE id=?", (r["proposal_id"],))
            db.conn.execute("UPDATE approved_patches SET shadow_verdict='not_run' "
                            "WHERE id=?", (r["id"],))
            continue

        independent = [g for g in gold if g.get("id") not in (own or set())]
        arms = {a: filter_split(independent, a) for a in ("train", "holdout")}
        arm_before = {a: {k: score(db, gs, use_llm=False)[k] for k in ARM_METRICS} for a, gs in arms.items()}

        # Apply inside a savepoint so a regressing patch leaves no trace.
        db.conn.execute("SAVEPOINT shadow")
        try:
            _apply_to_graph(db, kind, target, payload, ts, prov)
            after = score(db, gold, use_llm=False)
            arm_after = {a: {k: score(db, gs, use_llm=False)[k] for k in ARM_METRICS} for a, gs in arms.items()}
        except Exception as e:                                  # noqa: BLE001
            db.conn.execute("ROLLBACK TO shadow")
            rejected.append({"patch": r["id"], "why": f"error: {e}"})
            continue

        arm_worse = {a: arm_regressed(arm_before[a], arm_after[a]) for a in arms}
        arm_delta = {a: {k: round(arm_after[a][k] - arm_before[a][k], 5) for k in ARM_METRICS} for a in arms}
        regressed = (
            after["false_merge_rate"] > base["false_merge_rate"] or
            after["missed_merge_rate"] > base["missed_merge_rate"] or
            after["entity_precision"] < base["entity_precision"] or
            after["entity_recall"] < base["entity_recall"] or
            any(arm_worse.values())
        )
        delta = {k: round(after[k] - base[k], 5) for k in base}
        worse_text = "; ".join(f"{a} arm worse on {', '.join(w)}" for a, w in arm_worse.items() if w)

        if regressed or dry_run:
            db.conn.execute("ROLLBACK TO shadow")
            verdict = "regression" if regressed else "not_run"
            (rejected if regressed else held).append(
                {"patch": r["id"], "target": target, "payload": payload,
                 "delta": delta, "delta_train": arm_delta["train"], "delta_holdout": arm_delta["holdout"],
                 "why": ("regressed the gold set" + (f" ({worse_text})" if worse_text else ""))
                        if regressed else "dry run"})
        else:
            db.conn.execute("RELEASE shadow")
            verdict = "no_regression"
            db.conn.execute(
                "UPDATE approved_patches SET applied_at=?, applied_by='learning-loop' "
                "WHERE id=?", (ts, r["id"]))
            db.conn.execute("UPDATE learning_proposals SET status='applied' WHERE id=?",
                            (r["proposal_id"],))
            applied.append({"patch": r["id"], "target": target, "payload": payload,
                            "delta": delta, "delta_train": arm_delta["train"],
                            "delta_holdout": arm_delta["holdout"]})
            base = {k: after[k] for k in base}      # subsequent patches build on this

        db.conn.execute(
            """UPDATE approved_patches
               SET shadow_before_json=?, shadow_after_json=?, shadow_verdict=?
               WHERE id=?""",
            (json.dumps(base),
             json.dumps(dict({k: after[k] for k in base},
                             arms={a: {"cases": len(arms[a]), "before": arm_before[a], "after": arm_after[a],
                                       "delta": arm_delta[a]}
                                   for a in arms},
                             excluded_source_cases=sorted(own or []), provenance=("blind" if own is None
                                                                                   else "recorded"))),
             verdict, r["id"]))

    db.conn.commit()
    # Write through: the shadow before/after metrics are the EVIDENCE that a
    # patch was safe to apply. Losing them leaves applied changes with no record
    # of why they were allowed.
    db.export_learning()
    db.log_event(run=run, timestamp=ts, etype="learning_approval",
                 decision="shadow_and_apply",
                 detail={"applied": len(applied), "rejected": len(rejected),
                         "held": len(held), "baseline": base,
                         "held_circular": sum(1 for h in held if h.get("circular")),
                         "blind_provenance": blind_provenance},
                 provenance_ids=[prov])
    return {"applied": applied, "rejected": rejected, "held": held,
            "baseline": base, "candidates": len(rows), "blind_provenance": blind_provenance}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--emit-packet", action="store_true")
    ap.add_argument("--ingest", metavar="VERDICTS_JSON")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--requeue-stuck", action="store_true",
                    help="demote approved-but-unresolvable patches back to "
                         "'proposed'; run BEFORE widening resolve_target")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return _selftest()

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
            untouched = sum(1 for h in res["held"] if h.get("untouched"))
            print(f"  held     {len(res['held'])}  (human review; {untouched} of them "
                  f"match no gold case, so the shadow score could not see them)")
            circ = sum(1 for h in res["held"] if h.get("circular"))
            print(f"held circular={circ} of {res['candidates']} accepted  "
                  f"(provenance blind on {res['blind_provenance']}: scored whole, source cases unknown)")
    return 0


def _selftest() -> int:
    """Drives the REAL shadow_and_apply over an in-memory stub, so each hold and the two-arm rule are proven as
    wired, not only as helpers. The graph, scorer and gold loader are swapped for fixtures and put back; the
    train/holdout split is the REAL gold_split.filter_split, so the fixture commodities are chosen by it."""
    import sqlite3
    from gold_split import split_of_id
    g = globals()

    def pick(side, avoid=()):
        return next(n for n in (f"st-cheese-{i}" for i in range(500))
                    if split_of_id(n) == side and n not in avoid)
    tn, hn = pick("train"), pick("holdout")

    def case(cid, commodity, product, label, base=False):
        return {"id": cid, "commodity": commodity, "commodity_node": f"commodity:staple:{commodity}",
                "product": product, "label": label, "base": base}
    gold = [case("g1", "feta", "Athenos Feta Crumbles", "MATCH"),
            case("g2", "ricotta", "Whole Milk Ricotta", "MATCH", base=True),
            # A: fixes its source (train), keeps an independent train case, and STEALS a holdout case.
            case("gA-src", tn, f"{tn} Crumbles Tub", "MATCH"),
            case("gA-ind", tn, f"{tn} Crumbles Tub Large", "MATCH", base=True),
            case("gA-hold", hn, f"{hn} Crumbles Tub", "MATCH", base=True),
            # B: its only matching case is its source.
            case("gB-src", tn, f"{tn} Organic", "MATCH"),
            # C: fixes its source AND an independent train case; the holdout arm does not move.
            case("gC-src", tn, f"{tn} Block 8oz", "MATCH"),
            case("gC-ind", tn, f"{tn} Block 16oz", "MATCH")]

    class Stub:
        def __init__(self):
            self.conn = sqlite3.connect(":memory:")
            self.conn.row_factory = sqlite3.Row
            self.conn.executescript(
                "CREATE TABLE learning_proposals (id TEXT, kind TEXT, target_id TEXT, status TEXT,"
                " derived_from TEXT);"
                "CREATE TABLE approved_patches (id TEXT, proposal_id TEXT, verdict TEXT, payload_json TEXT,"
                " applied_at TEXT, applied_by TEXT, shadow_verdict TEXT, shadow_before_json TEXT,"
                " shadow_after_json TEXT);"
                "CREATE TABLE st_applied (kind TEXT, target TEXT, payload TEXT);")

        def add(self, pid, kind, target, pattern, derived=None):
            self.conn.execute("INSERT INTO learning_proposals VALUES (?,?,?, 'accepted', ?)",
                              (pid, kind, target, None if derived is None else json.dumps(derived)))
            self.conn.execute("INSERT INTO approved_patches (id, proposal_id, verdict, payload_json, shadow_verdict)"
                              " VALUES (?,?, 'accept', ?, 'not_run')",
                              ("ap-" + pid, pid, json.dumps({"payload": pattern})))

        def get_node(self, node):
            return True

        def record_provenance(self, *a, **k):
            return "prov:test"

        def export_learning(self):
            pass

        def log_event(self, **k):
            pass

    def stub_score(db, gs, use_llm=False):
        """A resolver in miniature: an alias claims matching products for its target and STEALS them from any
        other commodity (the price-stealing shape); a known-wrong unmatches one product. Applied patches live
        in the stub's own table, so the real SAVEPOINT/ROLLBACK in shadow_and_apply undoes them."""
        pats = db.conn.execute("SELECT kind, target, payload FROM st_applied").fetchall()
        tp = fp = tn_ = fn = 0
        for c in gs:
            pred = c["base"]
            for kind, target, payload in pats:
                bare = target.split(":")[-1]
                if kind == "add_alias" and re.search(payload, c["product"], re.IGNORECASE):
                    pred = bare == c["commodity"]
                if kind == "add_known_wrong" and payload == c["product"] and bare == c["commodity"]:
                    pred = False
            if c["label"] == "MATCH":
                tp, fn = tp + pred, fn + (not pred)
            else:
                fp, tn_ = fp + pred, tn_ + (not pred)
        div = lambda a, b: a / b if b else 0.0                     # noqa: E731
        return {"entity_precision": div(tp, tp + fp), "entity_recall": div(tp, tp + fn),
                "false_merge_rate": div(fp, fp + tn_), "missed_merge_rate": div(fn, tp + fn)}

    saved = {k: g[k] for k in ("load_gold", "score", "resolve_target", "_apply_to_graph")}
    g["load_gold"] = lambda: gold
    g["score"] = stub_score
    g["resolve_target"] = lambda db, t: f"commodity:staple:{t}" if t else None
    g["_apply_to_graph"] = lambda db, kind, target, payload, ts, prov: db.conn.execute(
        "INSERT INTO st_applied VALUES (?,?,?)", (kind, target, payload))
    fails = 0
    try:
        db = Stub()
        db.add("p1", "add_alias", "feta", r"athenos\s+feta")      # matches g1, no provenance (BLIND)
        db.add("p2", "add_alias", "feta", r"president\s+feta")    # target covered, pattern matches nothing
        db.add("p3", "add_alias", "ricotta", r"ricotta(")         # does not compile
        db.add("p4", "add_known_wrong", "ricotta", "Galbani Ricotta Dip")
        db.add("pA", "add_alias", tn, r"crumbles\s+tub", ["gA-src"])
        db.add("pB", "add_alias", tn, r"organic", ["gB-src"])
        db.add("pC", "add_alias", tn, r"block\s+\d+oz", ["gC-src"])
        res = shadow_and_apply(db)
        held = {h["patch"]: h for h in res["held"]}
        rejected = {x["patch"]: x for x in res["rejected"]}
        applied = {a["patch"]: a for a in res["applied"]}
        live = {r[0] for r in db.conn.execute("SELECT payload FROM st_applied")}
        after_c = json.loads(db.conn.execute("SELECT shadow_after_json FROM approved_patches WHERE id='ap-pC'")
                             .fetchone()[0] or "{}")
        full = lambda ps: stub_score(type("D", (), {"conn": _mem(ps)})(), gold)   # noqa: E731
        cases = [
            ("MUST FIRE: an alias whose target gold covers but which matches no gold case is held",
             "ap-p2" in held and held["ap-p2"].get("untouched") is True),
            ("MUST FIRE: the held alias is never applied to the graph, even inside the savepoint",
             r"president\s+feta" not in live and r"athenos\s+feta" in live),
            ("CLEAN TWIN: a recipe-namespaced target is judged on its staple twin's gold cases",
             untouched_hold("add_alias", "commodity:recipe:feta", r"athenos\s+feta", gold) is None),
            ("MUST FIRE: an alias that will not compile is held with that reason",
             "ap-p3" in held and "compile" in held["ap-p3"]["why"]),
            ("MUST NOT FIRE: an alias that matches a gold case of its own commodity is applied",
             "ap-p1" in applied),
            ("CLEAN TWIN: a known-wrong patch keeps its old road and is not held as untouched",
             "ap-p4" in applied and "ap-p4" not in held),
            ("CLEAN TWIN: a held patch's proposal is marked held_for_human",
             db.conn.execute("SELECT status FROM learning_proposals WHERE id='p2'").fetchone()[0] == "held_for_human"),
            ("at the bar: exactly one matching case is enough to be scored",
             untouched_hold("add_alias", "commodity:staple:ricotta", "ricotta", gold) is None),
            ("one step past it: zero matching cases is held",
             untouched_hold("add_alias", "commodity:staple:ricotta", "mascarpone", gold) is not None),
            # --- W2: two arms, source cases excluded ---
            (f"fixture: the real split puts {tn} in train and {hn} in holdout",
             split_of_id(tn) == "train" and split_of_id(hn) == "holdout"),
            ("fixture: the pooled whole-gold score cannot see A's break (recall +1 source, -1 holdout = flat)",
             full([("add_alias", tn, r"crumbles\s+tub")]) == full([])),
            ("MUST FIRE: a patch that fixes its source case and breaks an independent holdout case is REJECTED",
             "ap-pA" in rejected and "holdout arm worse" in rejected["ap-pA"]["why"]
             and r"crumbles\s+tub" not in live),
            ("MUST FIRE: a patch whose only matching gold case is its own source is HELD, circular, never applied",
             "ap-pB" in held and held["ap-pB"].get("circular") is True and "only circular evidence" in
             held["ap-pB"]["why"] and "organic" not in live),
            ("CLEAN TWIN: the circular hold sets not_run and holds its proposal for a human",
             db.conn.execute("SELECT shadow_verdict FROM approved_patches WHERE id='ap-pB'").fetchone()[0] == "not_run"
             and db.conn.execute("SELECT status FROM learning_proposals WHERE id='pB'").fetchone()[0]
             == "held_for_human"),
            ("CLEAN TWIN: an independent train case improves, holdout at the bar (delta 0), so it is APPLIED",
             "ap-pC" in applied and applied["ap-pC"]["delta_train"]["entity_recall"] > 0
             and all(v == 0 for v in applied["ap-pC"]["delta_holdout"].values())),
            ("CLEAN TWIN: the applied row records both arms and the source case it excluded",
             after_c.get("excluded_source_cases") == ["gC-src"] and set(after_c.get("arms", {})) == {"train", "holdout"}),
            ("MUST FIRE: the source case is OUT of the scored arms (both arms together hold every case but gC-src)",
             sum(a.get("cases", -1) for a in after_c.get("arms", {}).values()) == len(gold) - 1),
            ("MUST NOT FIRE: a proposal with NULL provenance is counted BLIND, never held as circular",
             "ap-p1" not in held and res["blind_provenance"] == 2),
            ("the circular-hold count is one of the accepted candidates",
             sum(1 for h in res["held"] if h.get("circular")) == 1 and res["candidates"] == 7),
            ("at the bar: false-merge unchanged is no regression",
             arm_regressed(_m(fm=0.25), _m(fm=0.25)) == []),
            ("one step past it: false-merge up by 0.25 rejects with no floor",
             arm_regressed(_m(fm=0.25), _m(fm=0.5)) == ["false_merge_rate"]),
            ("one step past it: recall down by 0.25 rejects at the deterministic floor of 0",
             arm_regressed(_m(), _m(rec=0.25)) == ["entity_recall"]),
            ("MUST NOT FIRE: a circular check with BLIND provenance returns None (the patch keeps its road)",
             circular_hold("add_alias", tn, "organic", gold, None) is None),
        ]
    except Exception as e:                                        # noqa: BLE001
        cases = [(f"the suite raised {type(e).__name__}: {e}", False)]
    finally:
        g.update(saved)
    for name, ok in cases:
        fails += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name}")
    want = 23
    if len(cases) != want:
        fails += 1
        print(f"FAIL ran {len(cases)} of {want} case(s)")
    print(f"cases={len(cases)} failed={fails}")
    print(f"STAGE2-REVIEW-SELFTEST-COMPLETE selftest={'pass' if not fails else 'fail'}")
    return 0 if not fails else 1


def _m(prec=0.5, rec=0.5, fm=0.0, mm=0.5) -> dict:
    """A metric row for arm_regressed cases; quarters and halves only, so the bar is binary-exact (og-06)."""
    return {"entity_precision": prec, "entity_recall": rec, "false_merge_rate": fm, "missed_merge_rate": mm}


def _mem(patches):
    """An in-memory st_applied holding `patches`, for scoring the pooled gold outside shadow_and_apply."""
    import sqlite3
    c = sqlite3.connect(":memory:")
    c.execute("CREATE TABLE st_applied (kind TEXT, target TEXT, payload TEXT)")
    c.executemany("INSERT INTO st_applied VALUES (?,?,?)", patches)
    return c


if __name__ == "__main__":
    raise SystemExit(main())
