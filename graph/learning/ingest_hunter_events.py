r"""ingest_hunter_events.py - the SLEEP stage for ingredient identity
(PLAN-ingredient-memory-2026-08-25, D4).

WHAT IT IS FOR. The map lane writes one append-only event per identity ruling all day
(meal-prep\db\ingredient-events.jsonl). Nothing reads it. This stage is what reads it, once a
night, and it does four things that a day-time writer cannot afford to do:

  1. FILES the day's events in the graph's decision_log, so "why does this ingredient carry this
     commodity id" is answerable from the same place every other why-question in the estate is.
  2. FINDS CONTRADICTIONS - a key whose cached row disagrees with the newest ruling about it, or
     whose own SURPRISE events are newer than the row they contradict. A cache is only as good as
     the day somebody checks it against what actually happened since.
  3. ACCRUES GOLD, into graph\gold\hunter-gold.jsonl and NEVER into gold.jsonl (see the header
     there and PLAN section 7.3): the SKU gold's NO_MATCH rows feed alias_blast_radius kill
     detection scoped by commodity slug, and recipe PHRASES in that corpus have unvetted effects on
     grocery alias kills. Merging is a later, human decision.
  4. QUEUES SURPRISES onto grocery\learning-queue.json, whose consumer dumps items opaquely - so
     Stage 1 SEES hunter surprises in its prompt with zero changes to Stage 1, and its proposal
     kinds stay grocery-only.

AND IT PROMOTES NOTHING. Everything it cannot settle mechanically goes into
graph\learning\hunter-review-packet.json for a person to rule on in the morning, applied by
`learn_apply.py --apply-reviews`. Nothing here writes the resolutions ledger, ever. The one error
this estate froze promotions over was a false merge ("fresh garlic" -> Ground Cloves, the $11.92/oz
clove cell), and a 3am promoter is exactly what would re-open it.

CPU-ONLY AND STDLIB-ONLY. It runs under the GRAPH's interpreter, which has no numpy at all
(graph\pipeline\resolve.py:1244-1251 says so in its own words), and it runs BEFORE the nightly
chain's GPU window opens.

  <graph python> ingest_hunter_events.py [--events e] [--store s] [--db d] [--gold g]
                                         [--queue q] [--packet p] [--cursor c] [--provenance-dir P]
  <graph python> ingest_hunter_events.py --selftest

EXIT CODES: 0 clean / 1 findings / 2 could-not-run / 3 BLIND. Marker HUNTER-INGEST-COMPLETE.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
sys.path.insert(0, os.path.join(HERE, "..", "gold"))

import graphdb                                                    # noqa: E402
from graphdb import GraphDB, REPO_ROOT                            # noqa: E402
from ids import commodity_id, hash_obj                            # noqa: E402
from seed_gold import resolve_commodity_node                      # noqa: E402

GRAPH = os.path.abspath(os.path.join(HERE, ".."))
EVENTS = os.path.join(REPO_ROOT, "meal-prep", "db", "ingredient-events.jsonl")
STORE = os.path.join(REPO_ROOT, "meal-prep", "db", "ingredient-resolutions.json")
HUNTER_GOLD = os.path.join(GRAPH, "gold", "hunter-gold.jsonl")
SKU_GOLD = os.path.join(GRAPH, "gold", "gold.jsonl")
PACKET = os.path.join(GRAPH, "learning", "hunter-review-packet.json")
CURSOR = os.path.join(GRAPH, "state", "hunter-ingest-cursor.json")
QUEUE = os.path.join(REPO_ROOT, "grocery", "learning-queue.json")

ETYPE = "hunter_identity"

MARKER = "HUNTER-INGEST-COMPLETE"
EXIT_CLEAN, EXIT_FINDINGS, EXIT_CANNOT_RUN, EXIT_BLIND = 0, 1, 2, 3

PACKET_INSTRUCTIONS = (
    "Each case is an identity the nightly ingest could not settle mechanically. Rule each one and "
    "write a verdicts file: {\"verdicts\": [{event_id, verdict: record|supersede|leave, item_id "
    "(required for record and supersede), evidence, by: \"adjudication\"}]}. Apply it with "
    "meal-prep\\pipeline\\learn_apply.py --apply-reviews <that file>. Nothing here has been "
    "applied: this stage promotes nothing, by design."
)


def now_stamp():
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def read_events(path):
    """(events, why_not_blind). ABSENT IS NOT EMPTY, and the difference is the whole exit code.

    A missing log means the map lane has never written one here - a BLIND night, exit 3, with the
    path named. An EMPTY log is a clean zero-event day and exits 0. Collapsing the two would make
    "the encoder has been broken for a week" read exactly like "nobody mapped a recipe today".
    """
    if not path or not os.path.exists(path):
        return None, "no event log at %s - the map lane has never written one here" % path
    out = []
    try:
        with io.open(path, "r", encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if isinstance(e, dict) and e.get("event_id"):
                    e["_line"] = n
                    out.append(e)
    except OSError as ex:
        return None, "the event log could not be read (%s)" % ex
    return out, ""


def read_json(path, default=None):
    try:
        with io.open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def ledger_rows(store):
    doc = read_json(store) or {}
    return {str(r.get("key") or ""): r for r in (doc.get("resolutions") or [])
            if isinstance(r, dict) and str(r.get("key") or "")}


# =====================================================================================================
# The three pure decisions. Fixtured, and the nightly -SelfTest touches nothing but these.
# =====================================================================================================

def contradictions(events, rows):
    """Which keys need a human. PURE over (events, ledger rows) -> list of cases.

    TWO SHAPES, AND THEY ARE DIFFERENT QUESTIONS.

      DISAGREES - a key whose events name two or more distinct commodity ids and whose CACHED ROW
      does not agree with the newest ruling. That is the cache serving an answer the estate has
      since changed its mind about, on the ladder's first rung, to every future recipe.

      REFUTED - a key whose SURPRISE events are newer than its cached row's own timestamp. The row
      may still be right; something ruled against it and nobody looked. Every one of those was
      written by the notes-refuse-bid check, a predicted/ruled disagreement, or a re-ruling.

    A key with a clean history and an agreeing row produces NOTHING. A packet full of settled cases
    is a packet nobody reads, and a review lane nobody reads is the promotion road being closed by
    boredom instead of by policy.
    """
    by_key = {}
    for e in events:
        if e.get("kind") not in ("ruling", "supersede"):
            continue
        k = str(e.get("key") or "")
        if not k:
            continue
        by_key.setdefault(k, []).append(e)
    cases = []
    for k in sorted(by_key):
        evs = sorted(by_key[k], key=lambda x: (str(x.get("at") or ""), int(x.get("_line") or 0)))
        newest = evs[-1]
        bids = sorted(set(str(x.get("bid") or "") for x in evs if str(x.get("bid") or "")))
        row = rows.get(k)
        row_bid = str((row or {}).get("item_id") or "")
        row_at = str((row or {}).get("at") or "")
        newest_bid = str(newest.get("bid") or "")
        if len(bids) >= 2 and row is not None and row_bid and newest_bid and row_bid != newest_bid:
            cases.append({"why": "disagrees", "key": k, "event": _clean(newest),
                          "ledger_row": row, "ids_seen": bids,
                          "detail": ("the ledger serves '%s' and the newest ruling says '%s'; this "
                                     "key has carried %d distinct ids"
                                     % (row_bid, newest_bid, len(bids)))})
            continue
        if row is not None:
            newer = [x for x in evs if x.get("surprise")
                     and str(x.get("at") or "") > row_at]
            if newer:
                cases.append({"why": "refuted", "key": k, "event": _clean(newer[-1]),
                              "ledger_row": row, "ids_seen": bids,
                              "detail": ("%d surprise event(s) are newer than the cached row "
                                         "(row at %s)" % (len(newer), row_at or "unknown"))})
                continue
        held = [x for x in evs if x.get("held_reason") and not x.get("projected")]
        if held and row is None:
            cases.append({"why": "held", "key": k, "event": _clean(held[-1]),
                          "ledger_row": None, "ids_seen": bids,
                          "detail": "held with reason: %s" % held[-1].get("held_reason")})
    return cases


def _clean(e):
    return {k: v for k, v in e.items() if k != "_line"}


def gold_row(e, db=None):
    """One hunter-gold row from one event, or None.

    THE SCHEMA MIRRORS gold.jsonl's rows and the FILE STAYS SEPARATE. Same fields, same id recipe,
    so a later human decision to merge is a concatenation rather than a migration - and until that
    decision is made, nothing recipe-shaped is in reach of alias_blast_radius' kill detection.

    LABEL. A projected ruling is a MATCH: the estate wrote it into the identity ledger and stands
    by it. A supersede is a NO_MATCH about the id it replaced - "this phrase is NOT that commodity"
    is exactly what the row records, and it is the more valuable of the two, because a rejection
    transfers across foods where a confirmation does not.
    """
    kind = e.get("kind")
    term = str(e.get("term") or "").strip()
    if not term:
        return None
    if kind == "ruling" and e.get("projected") and str(e.get("bid") or ""):
        commodity, label, ev = str(e["bid"]), "MATCH", str(e.get("evidence") or "")
    elif kind == "supersede":
        # The id that was REPLACED is what this row says the phrase is not. It is recoverable from
        # the supersede event's own evidence, which learn_apply writes as "superseded 'X' -> 'Y'".
        old = ""
        m = str(e.get("evidence") or "")
        if m.startswith("superseded '"):
            old = m.split("'")[1] if m.count("'") >= 2 else ""
        if not old:
            return None
        commodity, label, ev = old, "NO_MATCH", m
    else:
        return None
    row = {"kind": "ingredient", "commodity": commodity,
           "commodity_node": commodity_id(commodity, "staple"),
           "product": term, "store": None, "label": label,
           "source": "hunter-event:%s" % str(e.get("slug") or ""),
           "evidence": ev[:500]}
    if db is not None:
        node = resolve_commodity_node(db, row["commodity_node"], commodity)
        if node:
            row["commodity_node"] = node
    row["id"] = "gold:" + hash_obj(["ingredient", commodity, term, None])[:20]
    return row


def queue_items(events, already):
    """Surprises not yet queued, in the executor's own item shape.

    THE CONSUMER IS SCHEMA-FREE - stage1_analyze dumps queue items opaquely into its prompt - so a
    hunter surprise reaches Stage 1's eyes with ZERO changes to Stage 1, and Stage 1's proposal
    kinds stay grocery-only (PLAN 7.2). This is deliberately the cheapest possible integration: the
    local model sees what surprised the identity layer last night and nothing about the loop moves.
    """
    out = []
    for e in events:
        if not e.get("surprise"):
            continue
        if e.get("event_id") in already:
            continue
        out.append({"step": "hunter-ingest", "type": "hunter_surprise",
                    "tool": "meal-prep/pipeline/learn_apply.py", "detail": _clean(e),
                    "attempts": 1, "policy": "triage_queue_or_learning_queue",
                    "queued_at": now_stamp()})
    return out


# =====================================================================================================
# The writes
# =====================================================================================================

def append_queue(path, items):
    """Read-modify-write, the executor._queue idiom (graph\\agentic\\executor.py).

    APPEND, NEVER REPLACE. The queue is shared with the escalation road, and a writer that rewrote
    it would silently drop whatever the pipeline put there an hour earlier. The fixture pins
    1 existing + 1 new = 2, because that is exactly the arithmetic a truncating writer gets wrong.
    """
    if not items:
        return 0
    rows = read_json(path, default=[])
    if not isinstance(rows, list):
        rows = []
    rows.extend(items)
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(rows, f, indent=2, ensure_ascii=False)
    return len(items)


def append_gold(path, rows):
    """Append to hunter-gold.jsonl, deduped on the row's own content-addressed id."""
    if not rows:
        return 0
    have = set()
    if os.path.exists(path):
        try:
            with io.open(path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        try:
                            have.add(json.loads(line).get("id"))
                        except ValueError:
                            continue
        except OSError:
            pass
    fresh = [r for r in rows if r.get("id") not in have and not have.add(r.get("id"))]
    if not fresh:
        return 0
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    with io.open(path, "a", encoding="utf-8", newline="\n") as f:
        for r in fresh:
            f.write(json.dumps(r, sort_keys=True, ensure_ascii=False) + "\n")
    return len(fresh)


def already_ingested(db):
    """The output_hashes decision_log already holds for this type.

    **CORRECTED** against PLAN 6.1 step 2, which says "idempotency via the content-addressed
    event_id inside detail". It cannot be: GraphDB.log_event mints its OWN event_id from
    `event_id(run, step_id, etype, hash_obj([decision, detail, output_hash]))` and the run id
    carries a timestamp, so tonight's insert of an event ingested yesterday gets a DIFFERENT primary
    key and the ON CONFLICT DO NOTHING never fires. The dedupe truth is therefore a SELECT over
    `output_hash`, which IS the event's own content-addressed id - the plan's intent, through the
    column that actually holds it. The cursor file stays a cheap skip, never the truth.
    """
    try:
        return set(r[0] for r in db.conn.execute(
            "SELECT output_hash FROM decision_log WHERE type=? AND output_hash IS NOT NULL",
            (ETYPE,)).fetchall())
    except Exception:                                             # noqa: BLE001
        return set()


def write_packet(path, cases):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    doc = {"generated_at": now_stamp(), "instructions": PACKET_INSTRUCTIONS, "cases": cases}
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False, sort_keys=True)
    return doc


def write_cursor(path, n_lines, last_id):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump({"at": now_stamp(), "lines": n_lines, "last_event_id": last_id,
                   "note": "a cheap skip, not the dedupe truth - that is decision_log.output_hash"},
                  f, indent=1)


def run_ingest(a):
    events, why = read_events(a.events or EVENTS)
    if events is None:
        print("ingest_hunter_events: BLIND - %s" % why)
        print(MARKER)
        return EXIT_BLIND
    if not events:
        print("ingest_hunter_events: 0 events - a clean zero-event day (the log is present and "
              "empty, which is not the same as absent)")
        write_cursor(a.cursor or CURSOR, 0, "")
        print(MARKER)
        return EXIT_CLEAN

    findings = []
    if a.provenance_dir:
        # THE DRILL SEAM. graphdb mirrors every decision to GRAPH_DIR\provenance\<day>.jsonl, which
        # is tracked; a drill must not add a line to the estate's audit trail. Empty means the live
        # one, which is what a real night wants.
        graphdb.GRAPH_DIR = a.provenance_dir
    db = GraphDB(path=(a.db or graphdb.DB_PATH), create=True,
                 restore_learning=not bool(a.db))
    # ONE RUN ID PER NIGHT, stamped. `--run` overrides it for a drill, and that seam is not a
    # convenience: the run id feeds GraphDB.log_event's OWN primary key, so two ingests inside the
    # same SECOND collide there and ON CONFLICT DO NOTHING hides a missing dedupe. The double-ingest
    # fixture below came back 0 RED against a neuter that deleted already_ingested() entirely,
    # because both its runs landed in the same second. Two nights never do.
    run = a.run or ("run:hunter-ingest:%s" % time.strftime("%Y%m%dT%H%M%S"))
    have = already_ingested(db)
    stamp = now_stamp()

    logged = 0
    for e in events:
        eid = e.get("event_id")
        if eid in have:
            continue
        db.log_event(run=run, timestamp=stamp, etype=ETYPE, decision=str(e.get("kind") or ""),
                     detail=_clean(e), output_hash=eid)
        have.add(eid)
        logged += 1

    rows = ledger_rows(a.store or STORE)
    cases = contradictions(events, rows)

    gold = []
    for e in events:
        r = gold_row(e, db)
        if r:
            gold.append(r)
    gold_added = append_gold(a.gold or HUNTER_GOLD, gold)

    qpath = a.queue or QUEUE
    queued_ids = set()
    for it in (read_json(qpath, default=[]) or []):
        if isinstance(it, dict) and isinstance(it.get("detail"), dict):
            queued_ids.add(it["detail"].get("event_id"))
    items = queue_items(events, queued_ids)
    n_queued = append_queue(qpath, items)

    write_packet(a.packet or PACKET, cases)
    write_cursor(a.cursor or CURSOR, len(events), events[-1].get("event_id"))

    counts = {"events": len(events), "logged": logged, "cases": len(cases),
              "gold_added": gold_added, "queued": n_queued}
    db.log_event(run=run, timestamp=stamp, etype=ETYPE, decision="hunter_ingest_complete",
                 detail=counts, output_hash=hash_obj([run, counts]))
    db.conn.commit()

    print("ingest_hunter_events: %d event(s) in the log, %d newly filed, %d review case(s), "
          "%d gold row(s), %d surprise(s) queued"
          % (len(events), logged, len(cases), gold_added, n_queued))
    print("  packet -> %s" % (a.packet or PACKET))
    for f in findings:
        print("  FINDING  " + f)
    print(MARKER)
    return EXIT_FINDINGS if findings else EXIT_CLEAN


# =====================================================================================================
# self-test - scratch files only. Nothing here reads or writes the live graph, ledger or queue.
# =====================================================================================================

def _ev(**kw):
    base = {"at": "2026-08-25T10:00:00", "bid": "", "by": "mapper", "decision": "mapped",
            "evidence": "e", "held_reason": "", "key": "k", "kind": "ruling",
            "predicted": {"source": "none", "bid": ""}, "projected": False, "raw": "",
            "run": "r", "slug": "s", "surprise": False, "term": "T"}
    base.update(kw)
    base["event_id"] = "ie:" + hash_obj([base["kind"], base["key"], base["slug"],
                                         base["decision"], base["bid"], base["evidence"]])[:20]
    return base


def selftest():
    import shutil
    import tempfile
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    T("MUST FIRE  hunter gold is a SEPARATE file from the SKU gold - merging is a later human "
      "decision, not a side effect of a nightly",
      os.path.abspath(HUNTER_GOLD) != os.path.abspath(SKU_GOLD), HUNTER_GOLD)

    # ---- contradictions, pure ----------------------------------------------------------------------
    disagree = [_ev(key="apple", bid="apples", projected=True, at="2026-08-20T00:00:00"),
                _ev(key="apple", bid="apple-each", projected=True, at="2026-08-24T00:00:00",
                    evidence="re-ruled")]
    rows = {"apple": {"key": "apple", "item_id": "apples", "at": "2026-08-20T00:00:00"}}
    c = contradictions(disagree, rows)
    T("MUST FIRE  a key whose cached row disagrees with the NEWEST ruling is a review case",
      len(c) == 1 and c[0]["why"] == "disagrees" and c[0]["key"] == "apple"
      and "apples" in c[0]["detail"] and "apple-each" in c[0]["detail"], json.dumps(c)[:220])
    agree = [_ev(key="apple", bid="apples", projected=True, at="2026-08-20T00:00:00"),
             _ev(key="apple", bid="apples", projected=True, at="2026-08-24T00:00:00",
                 evidence="confirmed again")]
    T("CLEAN TWIN  a key ruled the SAME way twice, with an agreeing row, is not a case - a packet "
      "full of settled cases is a packet nobody reads",
      contradictions(agree, rows) == [], json.dumps(contradictions(agree, rows))[:220])
    refute = [_ev(key="apple", bid="apples", projected=True, at="2026-08-20T00:00:00"),
              _ev(key="apple", bid="apples", surprise=True, at="2026-08-24T00:00:00",
                  held_reason="notes refuse the bid", evidence="the notes refuse apples")]
    c2 = contradictions(refute, rows)
    T("MUST FIRE  a SURPRISE newer than the cached row is a case even when the ids agree - the row "
      "may still be right and nobody looked",
      len(c2) == 1 and c2[0]["why"] == "refuted", json.dumps(c2)[:220])
    old = [_ev(key="apple", bid="apples", surprise=True, at="2026-08-19T00:00:00")]
    T("CLEAN TWIN  a surprise OLDER than the row is not a case - the row was written knowing it",
      contradictions(old, rows) == [], json.dumps(contradictions(old, rows))[:200])
    held = [_ev(key="labneh", bid="labneh-x", held_reason="bid unknown to every namespace",
                surprise=False)]
    c3 = contradictions(held, rows)
    T("MUST FIRE  a HELD ruling with no ledger row at all reaches the packet - that is the whole "
      "point of a morning verb", len(c3) == 1 and c3[0]["why"] == "held", json.dumps(c3)[:200])
    T("MUST FIRE  registrar and QA events are not identity contradictions",
      contradictions([_ev(kind="registrar", key="x", bid="y"),
                      _ev(kind="qa_mapper_fail", key="", bid="")], {}) == [], "produced cases")

    # ---- gold rows, pure ---------------------------------------------------------------------------
    g = gold_row(_ev(key="apple", term="Apple", bid="apples", projected=True))
    T("MUST FIRE  a PROJECTED ruling accrues a MATCH gold row in gold.jsonl's own schema",
      g and g["label"] == "MATCH" and g["kind"] == "ingredient" and g["commodity"] == "apples"
      and g["product"] == "Apple" and g["store"] is None and g["id"].startswith("gold:")
      and g["source"] == "hunter-event:s", json.dumps(g))
    sup = gold_row(_ev(kind="supersede", key="apple", term="Apple", bid="apple-each",
                       projected=True, evidence="superseded 'apples' -> 'apple-each': re-ruled"))
    T("MUST FIRE  a SUPERSEDE accrues a NO_MATCH row about the id it REPLACED - a rejection is what "
      "transfers across foods",
      sup and sup["label"] == "NO_MATCH" and sup["commodity"] == "apples", json.dumps(sup))
    T("MUST FIRE  a HELD ruling accrues no gold at all - nothing was decided",
      gold_row(_ev(key="x", term="X", bid="y", projected=False)) is None, "made a row")
    T("MUST FIRE  the id recipe is gold.jsonl's own, so a future merge is a concatenation",
      g["id"] == "gold:" + hash_obj(["ingredient", "apples", "Apple", None])[:20], g["id"])

    tmp = tempfile.mkdtemp(prefix="hunter-ingest-fixture-")
    try:
        # ---- the queue append -------------------------------------------------------------------
        q = os.path.join(tmp, "learning-queue.json")
        with io.open(q, "w", encoding="utf-8") as f:
            json.dump([{"step": "somebody-else", "type": "escalation", "detail": {}}], f)
        items = queue_items([_ev(key="a", term="A", bid="b", surprise=True)], set())
        n = append_queue(q, items)
        rows_q = read_json(q)
        T("MUST FIRE  the queue APPEND preserves what was already there: 1 existing + 1 new = 2, "
          "never 1 - a truncating writer drops the pipeline's own escalations",
          n == 1 and len(rows_q) == 2 and rows_q[0]["step"] == "somebody-else"
          and rows_q[1]["type"] == "hunter_surprise", json.dumps(rows_q)[:200])
        T("  and the item is the executor's own shape, which stage1 dumps opaquely",
          set(["step", "type", "tool", "detail", "attempts", "policy", "queued_at"])
          .issubset(rows_q[1]), ",".join(sorted(rows_q[1])))
        again = queue_items([_ev(key="a", term="A", bid="b", surprise=True)],
                            set([rows_q[1]["detail"]["event_id"]]))
        T("MUST FIRE  a surprise already on the queue is not queued twice", again == [],
          json.dumps(again)[:160])
        T("CLEAN TWIN  a non-surprise is never queued",
          queue_items([_ev(key="a", term="A", bid="b", surprise=False)], set()) == [], "queued it")

        # ---- gold append dedupe -------------------------------------------------------------------
        gp = os.path.join(tmp, "hunter-gold.jsonl")
        T("MUST FIRE  a gold row is written once and never again",
          append_gold(gp, [g, g]) == 1 and append_gold(gp, [g]) == 0,
          str(len(io.open(gp, encoding="utf-8").read().strip().split("\n"))))

        # ---- END TO END, twice, against a scratch graph ------------------------------------------
        ev = os.path.join(tmp, "events.jsonl")
        allev = disagree + refute + [
            _ev(key="labneh", term="Labneh", bid="labneh-x", held_reason="bid unknown to every "
                "namespace"),
            _ev(kind="registrar", key="gochujang", term="Gochujang", bid="gochujang",
                decision="approve", by="registrar")]
        with io.open(ev, "w", encoding="utf-8", newline="\n") as f:
            for x in allev:
                f.write(json.dumps(x, sort_keys=True) + "\n")
        store = os.path.join(tmp, "ledger.json")
        with io.open(store, "w", encoding="utf-8") as f:
            json.dump({"count": 1, "resolutions": [
                {"key": "apple", "term": "Apple", "item_id": "apples", "bid_exists": True,
                 "evidence": "e", "by": "mapper", "at": "2026-08-20T00:00:00"}]}, f)

        class A(object):
            events, db = ev, os.path.join(tmp, "graph.db")
            store = ""
            gold = os.path.join(tmp, "hg.jsonl")
            queue = os.path.join(tmp, "q2.json")
            packet = os.path.join(tmp, "packet.json")
            cursor = os.path.join(tmp, "cursor.json")
            provenance_dir = os.path.join(tmp, "prov")
            run = "run:hunter-ingest:NIGHT-ONE"
        A.store = store
        live_prov = os.path.join(GRAPH, "provenance", time.strftime("%Y-%m-%d") + ".jsonl")
        live_before = os.path.getsize(live_prov) if os.path.exists(live_prov) else -1
        rc = run_ingest(A())
        T("MUST FIRE  the ingest runs end to end against a scratch graph", rc == EXIT_CLEAN,
          "rc=%s" % rc)
        d1 = GraphDB(path=A.db, create=False, restore_learning=False)
        n1 = d1.conn.execute("SELECT COUNT(*) FROM decision_log WHERE type=?", (ETYPE,)).fetchone()[0]
        d1.conn.close()
        class A2(A):
            run = "run:hunter-ingest:NIGHT-TWO"      # a SECOND night, not a second call in one second
        rc2 = run_ingest(A2())
        d2 = GraphDB(path=A.db, create=False, restore_learning=False)
        n2 = d2.conn.execute("SELECT COUNT(*) FROM decision_log WHERE type=?", (ETYPE,)).fetchone()[0]
        d2.conn.close()
        T("MUST FIRE  DOUBLE INGEST IS IDEMPOTENT: the second night files no event twice. The run id "
          "carries a stamp, so log_event's own primary key never collides - the dedupe truth has to "
          "be output_hash (CORRECTED against 6.1 step 2)",
          rc2 == EXIT_CLEAN and n2 == n1 + 1, "first=%d second=%d" % (n1, n2))
        pkt = read_json(A.packet)
        T("the packet carries its cases and the verdict contract a reviewer has to follow",
          pkt and len(pkt["cases"]) >= 2 and "apply-reviews" in pkt["instructions"],
          json.dumps([c["why"] for c in (pkt or {}).get("cases", [])]))
        T("MUST FIRE  the packet's events carry their event_id, or a verdict could not name one",
          all(c["event"].get("event_id") for c in pkt["cases"]),
          json.dumps([c["event"].get("event_id") for c in pkt["cases"]]))
        scratch_prov = os.path.join(A.provenance_dir, "provenance",
                                    time.strftime("%Y-%m-%d") + ".jsonl")
        live_after = os.path.getsize(live_prov) if os.path.exists(live_prov) else -1
        T("MUST FIRE  the decision mirror landed in the SCRATCH provenance dir and the LIVE tracked "
          "trail did not grow by a byte - a drill must not add a line to the estate's audit trail",
          os.path.exists(scratch_prov) and os.path.getsize(scratch_prov) > 0
          and live_after == live_before,
          "scratch=%s live %s -> %s" % (os.path.exists(scratch_prov), live_before, live_after))
        T("MUST FIRE  the ingest promoted NOTHING - the scratch ledger is byte-identical",
          json.dumps(read_json(store), sort_keys=True) ==
          json.dumps({"count": 1, "resolutions": [
              {"key": "apple", "term": "Apple", "item_id": "apples", "bid_exists": True,
               "evidence": "e", "by": "mapper", "at": "2026-08-20T00:00:00"}]}, sort_keys=True),
          "the ledger moved")

        # ---- the two absent/empty exits ------------------------------------------------------------
        class B(A):
            events = os.path.join(tmp, "no-such-log.jsonl")
        T("MUST FIRE  a MISSING event log is BLIND (exit 3), not a clean zero",
          run_ingest(B()) == EXIT_BLIND, str(run_ingest(B())))

        class C(A):
            events = os.path.join(tmp, "empty.jsonl")
        io.open(C.events, "w", encoding="utf-8").close()
        T("CLEAN TWIN  an EMPTY event log is a clean zero-event day (exit 0) - absent and empty are "
          "different facts about a night", run_ingest(C()) == EXIT_CLEAN, str(run_ingest(C())))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("")
    if bad:
        print("ingest_hunter_events SELF-TEST FAIL (%d)" % len(bad))
        print(MARKER)
        return EXIT_CANNOT_RUN
    print("ingest_hunter_events SELF-TEST PASS")
    print(MARKER)
    return EXIT_CLEAN


def main(argv=None):
    ap = argparse.ArgumentParser(description="file the day's identity events into the graph")
    ap.add_argument("--events", default="")
    ap.add_argument("--store", default="", help="the resolutions ledger to check the events against")
    ap.add_argument("--db", default="", help="a scratch graph db, for a drill")
    ap.add_argument("--gold", default="")
    ap.add_argument("--queue", default="")
    ap.add_argument("--packet", default="")
    ap.add_argument("--cursor", default="")
    ap.add_argument("--run", default="", help="override the run id. A DRILL SEAM with teeth: the run "
                                              "id feeds log_event's own primary key, so two ingests "
                                              "inside one second collide there and hide a missing "
                                              "dedupe. Two real nights never do.")
    ap.add_argument("--provenance-dir", dest="provenance_dir", default="",
                    help="a scratch graph dir for the decision mirror. Empty means the live "
                         "graph\\provenance, which is TRACKED - a drill must not add a line to it.")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    return run_ingest(a)


if __name__ == "__main__":
    raise SystemExit(main())
