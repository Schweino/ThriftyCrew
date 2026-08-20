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

from graphdb import open_db, GRAPH_DIR, REPO_ROOT, read_json   # noqa: E402
from ids import hash_obj, store_label                   # noqa: E402
from seed_gold import case as gold_case, GOLD_PATH      # noqa: E402
from flag_outliers import flag as flag_basis            # noqa: E402

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


# The row status each queue kind is waiting on. A verdict may only move rows
# that are still in its kind's source status — that is what makes
# refuse-don't-clobber meaningful across both lanes.
KIND_STATUS = {
    "confirm_match": "llm_match_unverified",   # model said MATCH; confirm the lead
    "contested": "escalated",                  # model could not say; rule from scratch
}


def _question_rows(db, cid: str, product: str,
                   status: str = "llm_match_unverified") -> list[dict]:
    """Every live row still asking this question, in the status it is waiting in."""
    return [dict(r) for r in db.conn.execute(
        """SELECT id, store_id, observed_at FROM price_observations
           WHERE commodity_id=? AND product_name=? AND match_status=?""",
        (cid, product, status)).fetchall()]


def _store_page_hint(cid: str, rows: list[dict]) -> dict:
    """Where a later session should go looking for the evidence a title lacks.

    product-urls.json already holds curated per-(commodity, store) product links.
    When one exists for a store this question actually appears in, hand it over
    rather than making the evidence pass re-derive it."""
    hint: dict = {"stores": sorted({r["store_id"].replace("store:", "") for r in rows})}
    path = os.path.join(REPO_ROOT, "grocery", "product-urls.json")
    if not os.path.exists(path):
        return hint
    try:
        items = (read_json(path).get("items") or {})
    except (ValueError, OSError):
        return hint
    entry = items.get(cid.rpartition(":")[2]) or {}
    urls = {}
    for store, v in entry.items():
        if store == "commodity" or not isinstance(v, dict):
            continue
        if v.get("url"):
            urls[store] = v["url"]
    if urls:
        hint["known_product_urls"] = urls
    return hint


def emit_packet(db, kind: str = "confirm_match", deferred_only: bool = False) -> str:
    """Build a review packet for one KIND of queued question.

    confirm_match — the local model said MATCH with confidence; the reviewer is
                    confirming or overturning a LEAD.
    contested     — the model said UNSURE or scored below threshold; there is no
                    lead, and the reviewer adjudicates FROM SCRATCH. Expect a
                    higher DEFER rate here; that is the rubric working, not
                    failure.

    The two kinds share every piece of machinery except which rows they are
    waiting on (KIND_STATUS). Splitting them into separate modules would have
    duplicated the ingest invariants — refuse-don't-clobber, gold write-through,
    provenance, queue bookkeeping — and those are exactly the things that must
    not drift between two copies.
    """
    if kind not in KIND_STATUS:
        raise ValueError(f"unknown kind {kind!r}; expected one of {sorted(KIND_STATUS)}")
    status = KIND_STATUS[kind]

    queue = _load_queue()
    entries = [e for e in queue if e.get("kind") == kind]
    other = sum(1 for e in queue if e.get("kind") != kind)

    # Orphan sweep: questions whose rows sit in this kind's status but which the
    # queue never recorded (a killed resolve run banks rows at checkpoints yet
    # writes its queue only at exit). Without this, those rows would wait forever.
    queued_keys = {(e.get("commodity"), e.get("product")) for e in entries}
    orphans = db.conn.execute(
        """SELECT commodity_id, product_name, MIN(id) AS obs, COUNT(*) AS n,
                  MAX(match_reason) AS reason, MAX(confidence) AS confidence
           FROM price_observations
           WHERE match_status=? AND product_name IS NOT NULL
           GROUP BY commodity_id, product_name""", (status,)).fetchall()
    swept = 0
    for r in orphans:
        key = (r["commodity_id"], r["product_name"])
        if key in queued_keys:
            continue
        entries.append({
            "observation": r["obs"], "commodity": r["commodity_id"],
            "product": r["product_name"], "reason": r["reason"],
            "rows_settled": r["n"], "kind": kind,
            "confidence": r["confidence"], "swept_from_db": True,
        })
        swept += 1

    if deferred_only:
        # The evidence pass: only questions a previous review could not settle
        # from the title alone, each carrying what it is waiting on.
        entries = [e for e in entries if e.get("deferred_reason")]

    # Group by commodity; biggest coverage return first.
    by_commodity: dict[str, list[dict]] = {}
    for e in entries:
        by_commodity.setdefault(e["commodity"], []).append(e)

    commodities = []
    for cid, group in by_commodity.items():
        ctx = _commodity_context(db, cid)
        questions = []
        for e in group:
            rows = _question_rows(db, cid, e["product"], status)
            q = {
                "observation": e["observation"],
                "product": e["product"],
                "model_reason": e.get("reason"),
                "model_confidence": e.get("confidence"),
                "rows_live": len(rows),
                "stores": sorted({r["store_id"] for r in rows}),
                # Echoed onto every verdict at ingest so the UPDATE can scope
                # itself to the status this question is actually waiting in.
                "from_status": status,
            }
            if kind == "contested":
                q["adjudicate_from_scratch"] = True
            if e.get("deferred_reason"):
                q["deferred_reason"] = e["deferred_reason"]
                q["store_page_hint"] = _store_page_hint(cid, rows)
            questions.append(q)
        questions.sort(key=lambda q: -q["rows_live"])
        ctx["rows_total"] = sum(q["rows_live"] for q in questions)
        ctx["questions"] = questions
        commodities.append(ctx)
    commodities.sort(key=lambda c: -c["rows_total"])

    instructions = (
        "For each question return one verdict object: {observation, "
        "commodity, product, verdict: CONFIRM|REJECT|DEFER, evidence}. "
        "evidence must name the DECIDING WORDS — same standard as "
        "known-wrong.json and the gold set. A DEFER carries "
        "deferred_reason instead (what store-page evidence would settle "
        "it). A REJECT seen on/near the live board carries board_grade: "
        "true so the ruling also enters known-wrong. A CONFIRM may carry "
        "alias_proposal (an include regex anchored on words naming the "
        "FOOD) + alias_rationale, filed through the normal shadow gate. "
        "Echo each question's from_status onto its verdict. "
        "Ingest with: python graph/pipeline/review_escalations.py "
        f"--ingest verdicts.json"
    )
    if kind == "contested":
        instructions += (
            "\n\nTHIS IS THE CONTESTED LANE. The local model could NOT lean "
            "either way on these — there is no lead to confirm, so adjudicate "
            "each from scratch against the rubric and the commodity's own "
            "evidence. A HIGHER DEFER RATE IS CORRECT HERE: if the title cannot "
            "settle it, DEFER with what would. Never confirm to clear the queue."
        )
    if deferred_only:
        instructions += (
            "\n\nDEFERRED-EVIDENCE PASS. Every question here was already "
            "deferred once, so the title alone is known to be insufficient — "
            "read the store page. Family Fare and Aldi product pages are "
            "client-rendered: use the browser, not a plain fetch. Put what the "
            "PAGE showed (aisle, unit, ingredient panel) into evidence. You may "
            "re-defer only with a NEW reason naming what the page failed to show."
        )

    packet = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "kind": kind,
        "from_status": status,
        "deferred_only": deferred_only,
        "prompt_version": PROMPT_VERSION,
        "rubric": RUBRIC,
        "instructions": instructions,
        "questions_total": sum(len(c["questions"]) for c in commodities),
        "swept_from_db": swept,
        "other_kinds_not_in_this_packet": other,
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

    # A packet-level from_status applies to every verdict in the file; a verdict
    # may override it. Default keeps every pre-contested-lane verdict file valid.
    file_status = data.get("from_status", "llm_match_unverified") \
        if isinstance(data, dict) else "llm_match_unverified"

    for v in verdicts:
        verdict = (v.get("verdict") or "").upper()
        obs, cid, product = v.get("observation"), v.get("commodity"), v.get("product")
        evidence = (v.get("evidence") or v.get("deferred_reason") or "").strip()
        from_status = v.get("from_status", file_status)
        if from_status not in KIND_STATUS.values():
            refused.append({"observation": obs,
                            "why": f"from_status {from_status!r} is not a status this "
                                   f"lane may move rows out of"})
            continue
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
                kind_of = next((k for k, s in KIND_STATUS.items() if s == from_status),
                               "confirm_match")
                entry = {"observation": obs, "commodity": cid, "product": product,
                         "reason": v.get("model_reason"), "rows_settled": 0,
                         "kind": kind_of, "confidence": None}
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

        # llm_confirmed means REVIEWER-confirmed regardless of how the question
        # arrived here (schema.md defines it that way), so a contested CONFIRM
        # lands in the same status as a confirm_match CONFIRM. What differs is
        # only the status the rows are moved OUT of — scoped so a verdict written
        # against one lane can never silently move the other lane's rows.
        status = "llm_confirmed" if verdict == "CONFIRM" else "llm_rejected"
        reason = f"reviewer {verdict}: {evidence}"[:400]
        cur = db.conn.execute(
            """UPDATE price_observations SET match_status=?, match_reason=?, confidence=?
               WHERE commodity_id=? AND product_name=? AND match_status=?""",
            (status, reason, float(v.get("confidence", 1.0) or 1.0), cid, product,
             from_status))
        if cur.rowcount == 0:
            # Someone else already ruled this question. Report, don't clobber —
            # and leave the queue entry for a human to reconcile.
            refused.append({"observation": obs, "commodity": cid, "product": product,
                            "why": f"no rows still {from_status}"})
            continue

        db.log_event(run=run, timestamp=ts, etype="escalate", model=reviewer,
                     decision="confirmed" if verdict == "CONFIRM" else "rejected",
                     confidence=float(v.get("confidence", 1.0) or 1.0),
                     provenance_ids=[prov],
                     detail={"observation": obs, "commodity": cid, "product": product,
                             "rows_updated": cur.rowcount, "evidence": evidence,
                             "from_status": from_status,
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

    # A CONFIRM is the moment a row first becomes able to CROWN a cell, so it is
    # also the first moment its per-unit basis matters. A correct match can still
    # carry a nonsense basis: "Boulder Everyday PaperTowel" ($5.39, size '660 ct')
    # is genuinely paper towels, but 660 is a SHEET count divided as though it
    # were rolls -> $0.0082 each, 345x under the median, instantly the cheapest
    # cell. On 2026-08-20 that was caught only because someone re-ran the guard by
    # hand. Printed advice is not a control, so the sweep runs HERE, in-process,
    # on the same connection and after the verdicts are committed.
    basis = {"flagged": 0, "checked_rows": 0}
    if confirmed:
        basis = flag_basis(db, run=run, ts=ts)

    db.log_event(run=run, timestamp=ts, etype="escalate", model=reviewer,
                 decision="ingest_complete", provenance_ids=[prov],
                 detail={"confirmed": len(confirmed), "rejected": len(rejected),
                         "deferred": len(deferred), "refused": len(refused),
                         "gold_added": gold_added,
                         "alias_proposals": len(proposals),
                         "basis_flagged": basis["flagged"],
                         "source": os.path.basename(path)})
    db.conn.commit()
    return {"confirmed": confirmed, "rejected": rejected, "deferred": deferred,
            "refused": refused, "gold_added": gold_added,
            "alias_proposals": proposals, "known_wrong_commands": kw_commands,
            "queue_remaining": len(queue), "basis": basis}


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
    ap = argparse.ArgumentParser(description="Escalation review lanes "
                                             "(confirm-match and contested)")
    ap.add_argument("--emit-packet", action="store_true")
    ap.add_argument("--kind", choices=sorted(KIND_STATUS), default="confirm_match",
                    help="which queued question kind to emit (default confirm_match)")
    ap.add_argument("--deferred-only", action="store_true",
                    help="emit only previously-deferred questions, with store-page hints")
    ap.add_argument("--ingest", metavar="VERDICTS_JSON")
    ap.add_argument("--status", action="store_true")
    args = ap.parse_args()

    if not (args.emit_packet or args.ingest or args.status):
        ap.print_help()
        return 1

    with open_db() as db:
        if args.emit_packet:
            p = emit_packet(db, kind=args.kind, deferred_only=args.deferred_only)
            packet = json.load(open(p, encoding="utf-8"))
            print(f"review packet [{packet['kind']}"
                  f"{', deferred-only' if packet['deferred_only'] else ''}]: {p}")
            print(f"  {packet['questions_total']} question(s) across "
                  f"{len(packet['commodities'])} commodities "
                  f"({packet['swept_from_db']} swept from DB, not the queue)")
            print(f"  verdicts must move rows out of: {packet['from_status']}")
            if packet["other_kinds_not_in_this_packet"]:
                print(f"  {packet['other_kinds_not_in_this_packet']} queue entr(ies) "
                      f"of another kind are NOT in this packet — emit them with "
                      f"--kind")
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
                b = res["basis"]
                print(f"basis guard ran automatically: {b['checked_rows']} priceable "
                      f"rows checked, {b['flagged']} barred from crowning")
                print("Parity is now safe to re-read: python graph/eval/board_parity.py")
        if args.status:
            status(db)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
