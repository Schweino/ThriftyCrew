"""Confirm-match review — the reviewer lane that turns local-model leads into
priced cells (design/PLAN-confirm-match-review-2026-08-20.md).

    python graph/pipeline/review_escalations.py --emit-packet   # queue -> review packet
    python graph/pipeline/review_escalations.py --ingest verdicts.json
    python graph/pipeline/review_escalations.py --status        # queue/verdict counts

The resolver's layer 5 is reject-only: a confident local MATCH lands as
`llm_match_unverified`, which CANNOT price a cell, and queues a
`kind: "confirm_match"` packet. Only THIS lane may write `llm_confirmed` — one
of exactly two statuses `v_current_cell` lets price a board cell. The review
itself is Claude in-session, never an API call from the pipeline; this module
is the mechanical, auditable machinery around it, mirroring
graph/learning/stage2_review.py:

  --emit-packet  groups the queue by commodity and enriches each question with
                 what "belonging" looks like (include/exclude patterns, sibling
                 include_hit names, known-wrong names). Also sweeps in orphaned
                 llm_match_unverified questions the queue never recorded — an
                 interrupted resolve run banks row verdicts at checkpoints but
                 only writes the queue at exit, so rows can exist with no entry.
  --ingest       writes verdicts to every row that asked the question, with
                 provenance + one decision-log row per question. Single-writer,
                 main thread. Refuses to clobber rows someone else already ruled.

VERDICTS (each carries written `evidence` naming the deciding words):
  CONFIRM  rows -> llm_confirmed (may price a cell)
  REJECT   rows -> llm_rejected; board-grade evidence ALSO goes to known-wrong
           via grocery/add-known-wrong.ps1 (this module prints the command —
           the ps1 is the one canonical intake; never hand-edit known-wrong.json)
  DEFER    rows stay llm_match_unverified; the entry stays queued with a
           written deferred_reason for a later session with store-page evidence

Side products ingest handles mechanically (plan §5 — half the value):
  * every CONFIRM/REJECT becomes a gold case (source "escalation-review"),
    appended to graph/gold/escalation-review.jsonl (tracked; the seeder merges
    it on rebuild) AND to gold.jsonl directly.
  * a CONFIRM carrying an `alias_proposal` files an include-alias learning
    proposal — through the NORMAL Stage-2 shadow gate, never applied here.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
sys.path.insert(0, os.path.join(HERE, "..", "gold"))

from graphdb import open_db, GRAPH_DIR, REPO_ROOT       # noqa: E402
from ids import hash_obj, store_label                   # noqa: E402
from seed_gold import case as gold_case, GOLD_PATH      # noqa: E402

QUEUE = os.path.join(REPO_ROOT, "grocery", "escalation-queue.json")
PACKET = os.path.join(REPO_ROOT, "grocery", "escalation-review-packet.json")
REVIEW_GOLD = os.path.join(GRAPH_DIR, "gold", "escalation-review.jsonl")

# Version of the review rubric + packet shape. Recorded on every provenance and
# decision-log row so a verdict is attributable months later. Bump on change.
PROMPT_VERSION = "review-v1"

# The rubric the reviewer judges under — the SAME law build_resolve_prompt
# states for the local model, plus the reviewer-specific bias. Embedded in the
# packet so the packet alone documents the standard its verdicts were held to.
RUBRIC = [
    "The board prices PACKAGED RETAIL PRODUCTS; brand is never a reason to reject.",
    "Package SIZE is never a reason to reject (per-unit normalisation handles it).",
    "REJECT: different food; different cut/grade; prepared/cooked vs raw; "
    "non-food that merely mentions the food.",
    "Variety differences REJECT when the commodity names the variety "
    "(Deglet Noor is not Medjool; 93/7 is not 85/15).",
    "BIAS: prefer a missed match over a false one. A wrong CONFIRM can publish "
    "a wrong price — the one failure this estate exists to prevent. When "
    "genuinely torn, DEFER; never confirm on vibes.",
    "The three commodity id namespaces stay separate; staple and recipe ids "
    "never cross.",
]


def _load_queue() -> list[dict]:
    if not os.path.exists(QUEUE):
        return []
    try:
        with open(QUEUE, encoding="utf-8-sig") as fh:
            data = json.load(fh)
    except (json.JSONDecodeError, OSError):
        return []
    return data if isinstance(data, list) else []


def _save_queue(entries: list[dict]) -> None:
    with open(QUEUE, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(entries, fh, indent=2, ensure_ascii=False)


def _commodity_context(db, cid: str) -> dict:
    """Everything the reviewer needs to know what 'belonging' looks like."""
    node = db.get_node(cid)
    props = json.loads(node["properties_json"] or "{}") if node else {}
    cat = db.conn.execute(
        """SELECT n.canonical_name FROM nodes n
           JOIN edges e ON e.target_id = n.id
           WHERE e.predicate='in_category' AND e.source_id=? LIMIT 1""",
        (cid,)).fetchone()
    siblings = [r["product_name"] for r in db.conn.execute(
        """SELECT DISTINCT product_name FROM price_observations
           WHERE commodity_id=? AND match_status='include_hit'
             AND product_name IS NOT NULL LIMIT 5""", (cid,)).fetchall()]
    known_wrong = [r["canonical_name"] for r in db.conn.execute(
        """SELECT n.canonical_name FROM nodes n
           JOIN edges e ON e.source_id = n.id
           WHERE e.predicate='known_wrong_for' AND e.target_id=?""",
        (cid,)).fetchall()]
    return {
        "commodity": cid,
        "label": node["canonical_name"] if node else None,
        "unit_basis": props.get("unit_basis"),
        "category": cat["canonical_name"] if cat else None,
        "include_patterns": [a["alias"] for a in db.aliases_for(cid, "include")],
        "exclude_patterns": [a["alias"] for a in db.aliases_for(cid, "exclude")],
        "confirmed_siblings": siblings,
        "known_wrong": known_wrong,
    }


def _question_rows(db, cid: str, product: str) -> list[dict]:
    """Every live row still asking this question."""
    return [dict(r) for r in db.conn.execute(
        """SELECT id, store_id, observed_at FROM price_observations
           WHERE commodity_id=? AND product_name=?
             AND match_status='llm_match_unverified'""",
        (cid, product)).fetchall()]


def emit_packet(db) -> str:
    queue = _load_queue()
    # This lane rules CONFIRM_MATCH questions only. A 'contested' entry is a row
    # nobody could settle (status 'escalated'), which needs adjudication from
    # scratch rather than confirmation of a lead — and --ingest deliberately
    # touches only 'llm_match_unverified' rows, so a verdict here could not move
    # it anyway. They are COUNTED and reported rather than silently dropped, so
    # a queue quietly filling with contested work is visible.
    entries = [e for e in queue if e.get("kind") == "confirm_match"]
    contested = sum(1 for e in queue if e.get("kind") != "confirm_match")

    # Orphan sweep: questions whose rows are llm_match_unverified but which the
    # queue never recorded (a killed resolve run banks rows at checkpoints yet
    # writes its queue only at exit). Without this, those rows would wait forever.
    queued_keys = {(e.get("commodity"), e.get("product")) for e in entries}
    orphans = db.conn.execute(
        """SELECT commodity_id, product_name, MIN(id) AS obs, COUNT(*) AS n,
                  MAX(match_reason) AS reason, MAX(confidence) AS confidence
           FROM price_observations
           WHERE match_status='llm_match_unverified' AND product_name IS NOT NULL
           GROUP BY commodity_id, product_name""").fetchall()
    swept = 0
    for r in orphans:
        key = (r["commodity_id"], r["product_name"])
        if key in queued_keys:
            continue
        entries.append({
            "observation": r["obs"], "commodity": r["commodity_id"],
            "product": r["product_name"], "reason": r["reason"],
            "rows_settled": r["n"], "kind": "confirm_match",
            "confidence": r["confidence"], "swept_from_db": True,
        })
        swept += 1

    # Group by commodity; biggest coverage return first.
    by_commodity: dict[str, list[dict]] = {}
    for e in entries:
        by_commodity.setdefault(e["commodity"], []).append(e)

    commodities = []
    for cid, group in by_commodity.items():
        ctx = _commodity_context(db, cid)
        questions = []
        for e in group:
            rows = _question_rows(db, cid, e["product"])
            q = {
                "observation": e["observation"],
                "product": e["product"],
                "model_reason": e.get("reason"),
                "model_confidence": e.get("confidence"),
                "rows_live": len(rows),
                "stores": sorted({r["store_id"] for r in rows}),
            }
            if e.get("deferred_reason"):
                q["deferred_reason"] = e["deferred_reason"]
            questions.append(q)
        questions.sort(key=lambda q: -q["rows_live"])
        ctx["rows_total"] = sum(q["rows_live"] for q in questions)
        ctx["questions"] = questions
        commodities.append(ctx)
    commodities.sort(key=lambda c: -c["rows_total"])

    packet = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "prompt_version": PROMPT_VERSION,
        "rubric": RUBRIC,
        "instructions": (
            "For each question return one verdict object: {observation, "
            "commodity, product, verdict: CONFIRM|REJECT|DEFER, evidence}. "
            "evidence must name the DECIDING WORDS — same standard as "
            "known-wrong.json and the gold set. A DEFER carries "
            "deferred_reason instead (what store-page evidence would settle "
            "it). A REJECT seen on/near the live board carries board_grade: "
            "true so the ruling also enters known-wrong. A CONFIRM may carry "
            "alias_proposal (an include regex anchored on words naming the "
            "FOOD) + alias_rationale, filed through the normal shadow gate. "
            "Ingest with: python graph/pipeline/review_escalations.py "
            "--ingest verdicts.json"
        ),
        "questions_total": sum(len(c["questions"]) for c in commodities),
        "swept_from_db": swept,
        "contested_not_in_this_lane": contested,
        "commodities": commodities,
    }
    with open(PACKET, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(packet, fh, indent=2, ensure_ascii=False)
    return PACKET


# ---------------------------------------------------------------------------
# ingest
# ---------------------------------------------------------------------------

def _append_gold(cases: list[dict]) -> int:
    """Append review gold cases, deduped by id, to BOTH the durable review file
    (which seed_gold merges on rebuild) and the live gold.jsonl."""
    added = 0
    for path in (REVIEW_GOLD, GOLD_PATH):
        seen = set()
        if os.path.exists(path):
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    if line.strip():
                        seen.add(json.loads(line).get("id"))
        with open(path, "a", encoding="utf-8", newline="\n") as fh:
            for c in cases:
                if c["id"] in seen:
                    continue
                fh.write(json.dumps(c, ensure_ascii=False, sort_keys=True) + "\n")
                if path == REVIEW_GOLD:
                    added += 1
    return added


def _file_alias_proposal(db, ts: str, reviewer: str, target: str,
                         pattern: str, rationale: str | None) -> str:
    """File an include-alias learning proposal. It goes through the NORMAL
    Stage-2 shadow gate (stage2_review.py --apply) — nothing here bypasses it."""
    pid = "lp:" + hash_obj(["add_alias", target, pattern])[:20]
    db.conn.execute(
        """INSERT INTO learning_proposals
             (id, created_at, model, queue_hash, kind, target_id,
              payload_json, confidence, rationale, status)
           VALUES (?,?,?,?,?,?,?,?,?, 'proposed')
           ON CONFLICT(id) DO NOTHING""",
        (pid, ts, reviewer, None, "add_alias", target,
         json.dumps({"payload": pattern}, ensure_ascii=False), 0.9,
         rationale or "escalation-review: confirmed match shows an include-pattern gap"))
    return pid


def ingest(db, path: str) -> dict:
    with open(path, encoding="utf-8-sig") as fh:
        data = json.load(fh)
    verdicts = data.get("verdicts", data if isinstance(data, list) else [])
    reviewer = data.get("reviewer", "claude-review") if isinstance(data, dict) \
        else "claude-review"

    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    run = f"run:escalation-review:{time.strftime('%Y%m%dT%H%M%S')}"
    prov = db.record_provenance(
        source_document="escalation-review", extraction_method="claude-review",
        timestamp=ts, model=reviewer, prompt_version=PROMPT_VERSION, run=run)

    queue = _load_queue()
    # Key by the QUESTION, not the representative observation id: a swept
    # orphan's MIN(id) can shift between packet emissions as more rows of the
    # same question land, and a verdict must still find its entry.
    by_q = {(e.get("commodity"), e.get("product")): e for e in queue}

    confirmed, rejected, deferred, refused = [], [], [], []
    gold_cases: list[dict] = []
    kw_commands: list[str] = []
    proposals: list[str] = []

    for v in verdicts:
        verdict = (v.get("verdict") or "").upper()
        obs, cid, product = v.get("observation"), v.get("commodity"), v.get("product")
        evidence = (v.get("evidence") or v.get("deferred_reason") or "").strip()
        if verdict not in ("CONFIRM", "REJECT", "DEFER") or not (cid and product):
            refused.append({"verdict": v, "why": "malformed: needs verdict/commodity/product"})
            continue
        if not evidence:
            # The evidence standard is not optional — a ruling with no written
            # deciding words cannot enter the gold set or the decision log.
            refused.append({"observation": obs, "why": "no written evidence"})
            continue

        if verdict == "DEFER":
            entry = by_q.get((cid, product))
            if entry is None:
                # A swept orphan has no queue entry yet; give it one so the
                # deferral is durable and the next --emit-packet shows it.
                entry = {"observation": obs, "commodity": cid, "product": product,
                         "reason": v.get("model_reason"), "rows_settled": 0,
                         "kind": "confirm_match", "confidence": None}
                queue.append(entry)
                by_q[(cid, product)] = entry
            entry["deferred_reason"] = evidence
            deferred.append({"observation": obs, "product": product})
            db.log_event(run=run, timestamp=ts, etype="escalate", model=reviewer,
                         decision="deferred", provenance_ids=[prov],
                         detail={"observation": obs, "commodity": cid,
                                 "product": product, "evidence": evidence,
                                 "prompt_version": PROMPT_VERSION})
            continue

        status = "llm_confirmed" if verdict == "CONFIRM" else "llm_rejected"
        reason = f"reviewer {verdict}: {evidence}"[:400]
        cur = db.conn.execute(
            """UPDATE price_observations SET match_status=?, match_reason=?, confidence=?
               WHERE commodity_id=? AND product_name=?
                 AND match_status='llm_match_unverified'""",
            (status, reason, float(v.get("confidence", 1.0) or 1.0), cid, product))
        if cur.rowcount == 0:
            # Someone else already ruled this question. Report, don't clobber —
            # and leave the queue entry for a human to reconcile.
            refused.append({"observation": obs, "commodity": cid, "product": product,
                            "why": "no rows still llm_match_unverified"})
            continue

        db.log_event(run=run, timestamp=ts, etype="escalate", model=reviewer,
                     decision="confirmed" if verdict == "CONFIRM" else "rejected",
                     confidence=float(v.get("confidence", 1.0) or 1.0),
                     provenance_ids=[prov],
                     detail={"observation": obs, "commodity": cid, "product": product,
                             "rows_updated": cur.rowcount, "evidence": evidence,
                             "prompt_version": PROMPT_VERSION})

        # Gold case: every ruled question is a labelled, evidenced judgement.
        ns, _, slug = cid.rpartition(":")
        ns = ns.split(":")[-1] if ns else "staple"
        store_row = db.conn.execute(
            "SELECT store_id FROM price_observations WHERE id=?", (obs,)).fetchone()
        # Display name, not the raw node id: the gold set keys stores by label
        # ("Walmart"), and a mix of 'Walmart' and 'store:walmart' rows would make
        # the set's own store counts wrong. store_label expects a slug, so the
        # 'store:' prefix comes off first — passing the node id straight in
        # returns it unchanged, which is exactly how the split crept in.
        gold_cases.append(gold_case(
            "match", slug, product,
            "MATCH" if verdict == "CONFIRM" else "NO_MATCH",
            "escalation-review",
            store=(store_label(store_row["store_id"].split(":", 1)[-1])
                   if store_row and store_row["store_id"] else None),
            evidence=evidence, namespace=ns))

        if verdict == "CONFIRM":
            confirmed.append({"observation": obs, "product": product,
                              "rows": cur.rowcount})
            if v.get("alias_proposal"):
                proposals.append(_file_alias_proposal(
                    db, ts, reviewer, cid, v["alias_proposal"],
                    v.get("alias_rationale")))
        else:
            rejected.append({"observation": obs, "product": product,
                             "rows": cur.rowcount})
            if v.get("board_grade"):
                # The ps1 is the ONE canonical intake for known-wrong rulings.
                store = (store_row["store_id"].split(":")[-1]
                         if store_row else "UNKNOWN")
                kw_commands.append(
                    f"pwsh grocery/add-known-wrong.ps1 -Commodity {slug} "
                    f"-Store {store} -RuledBy escalation-review "
                    f"-Name {product!r} -Evidence {evidence!r}")

        # Ruled entries leave the queue (deferred ones stay above).
        entry = by_q.get((cid, product))
        if entry is not None and entry in queue:
            queue.remove(entry)

    db.conn.commit()
    _save_queue(queue)
    gold_added = _append_gold(gold_cases)
    if proposals:
        db.export_learning()

    db.log_event(run=run, timestamp=ts, etype="escalate", model=reviewer,
                 decision="ingest_complete", provenance_ids=[prov],
                 detail={"confirmed": len(confirmed), "rejected": len(rejected),
                         "deferred": len(deferred), "refused": len(refused),
                         "gold_added": gold_added,
                         "alias_proposals": len(proposals),
                         "source": os.path.basename(path)})
    db.conn.commit()
    return {"confirmed": confirmed, "rejected": rejected, "deferred": deferred,
            "refused": refused, "gold_added": gold_added,
            "alias_proposals": proposals, "known_wrong_commands": kw_commands,
            "queue_remaining": len(queue)}


def status(db) -> None:
    queue = _load_queue()
    kinds: dict[str, int] = {}
    deferred = 0
    for e in queue:
        kinds[e.get("kind", "?")] = kinds.get(e.get("kind", "?"), 0) + 1
        if e.get("deferred_reason"):
            deferred += 1
    print(f"queue: {len(queue)} entries  {kinds}  ({deferred} deferred)")
    for st in ("llm_match_unverified", "llm_confirmed", "llm_rejected"):
        n = db.conn.execute(
            "SELECT COUNT(*) c FROM price_observations WHERE match_status=?",
            (st,)).fetchone()["c"]
        print(f"  {st:<22} {n} rows")
    rows = db.conn.execute(
        """SELECT decision, COUNT(*) c FROM decision_log
           WHERE type='escalate' AND run_id LIKE 'run:escalation-review:%'
           GROUP BY decision""").fetchall()
    if rows:
        print("review verdicts logged: " +
              ", ".join(f"{r['decision']}={r['c']}" for r in rows))


def main() -> int:
    ap = argparse.ArgumentParser(description="Confirm-match review lane")
    ap.add_argument("--emit-packet", action="store_true")
    ap.add_argument("--ingest", metavar="VERDICTS_JSON")
    ap.add_argument("--status", action="store_true")
    args = ap.parse_args()

    if not (args.emit_packet or args.ingest or args.status):
        ap.print_help()
        return 1

    with open_db() as db:
        if args.emit_packet:
            p = emit_packet(db)
            packet = json.load(open(p, encoding="utf-8"))
            print(f"review packet: {p}")
            print(f"  {packet['questions_total']} question(s) across "
                  f"{len(packet['commodities'])} commodities "
                  f"({packet['swept_from_db']} swept from DB, not the queue)")
            if packet["contested_not_in_this_lane"]:
                print(f"  {packet['contested_not_in_this_lane']} 'contested' "
                      f"queue entries are NOT in this packet — they need "
                      f"adjudication from scratch, not confirmation")
            print("Review in batches of ~50, biggest rows_live first; "
                  "ingest each batch with --ingest.")
        if args.ingest:
            res = ingest(db, args.ingest)
            print(f"confirmed {len(res['confirmed'])}  "
                  f"rejected {len(res['rejected'])}  "
                  f"deferred {len(res['deferred'])}  "
                  f"refused {len(res['refused'])}")
            print(f"gold cases added: {res['gold_added']}   "
                  f"alias proposals filed: {len(res['alias_proposals'])}   "
                  f"queue remaining: {res['queue_remaining']}")
            for r in res["refused"]:
                print(f"  REFUSED: {r}")
            if res["known_wrong_commands"]:
                print("\nboard-grade rejections — run each through the canonical intake:")
                for c in res["known_wrong_commands"]:
                    print(f"  {c}")
            if res["confirmed"]:
                # A CONFIRM is the moment a row becomes able to crown a cell, so
                # it is also the moment its per-unit price starts mattering. A
                # correct match can still carry a nonsense basis: "Boulder
                # Everyday PaperTowel" ($5.39, size '660 ct') divided a SHEET
                # count as rolls, giving $0.0082 each — 345x under the median and
                # instantly the cheapest cell. flag_outliers caught it, but only
                # because someone re-ran it (2026-08-20).
                print("\nNEXT (not optional): python graph/pipeline/flag_outliers.py")
                print("  Confirmed rows can now crown a cell, so their per-unit "
                      "basis must be re-checked before any parity read.")
        if args.status:
            status(db)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
