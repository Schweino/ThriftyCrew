"""Price STATE — derive the answer per cell, and bank the answer per question.

    python graph/pipeline/state.py                 # rebuild both tables + export
    python graph/pipeline/state.py --verify        # Phase A gate only, write nothing
    python graph/pipeline/state.py --prune         # Phase C supersede-prune
    python graph/pipeline/state.py --ad-reversions # Phase D worklist emit

Implements design/PLAN-price-state-2026-08-20.md. The estate stored a grocery
board as an event log — 128,162 observations over 37 days, 40 rows per cell of
which one was the answer, growing ~6,500/day with no retention. A board is a
STATE MACHINE: each (commodity, store) has a current everyday price, sometimes a
current ad price, and freshness rules for each.

Three tables, three growth curves:

  cell_state          one row per (commodity, store)     — grows with the CATALOG
  question_verdicts   one row per (commodity, product)   — grows with new PRODUCTS
  price_observations  evidence, superseded at import     — grows with ASSORTMENT

None of them grows with time, which was the whole complaint.

WHAT THIS FILE REFUSES TO DO: bake the 90-day everyday window in as a literal.
It lives in grocery/capture-policy.ps1 ($script:MaxCarryDays) and is read from
there at run time. This estate closed three private copies of that window on
2026-08-20 alone, one of them inside the graph's own row_age check.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

from authority import decided_by_stamp                          # noqa: E402
from graphdb import open_db, write_json, GRAPH_DIR, REPO_ROOT   # noqa: E402
from ids import norm_text                                       # noqa: E402
from units import per_unit, reconcile_unit, names_multiple_products  # noqa: E402

STATE_DIR = os.path.join(GRAPH_DIR, "state")
CELL_STATE_JSON = os.path.join(STATE_DIR, "cell-state.json")
VERDICTS_JSON = os.path.join(STATE_DIR, "question-verdicts.json")

# Only these two may price a cell — the same whitelist v_current_cell enforces
# and verifier.check_no_unresolved_pricing re-checks. llm_match_unverified is
# deliberately absent: a local-model MATCH is a lead for the reviewer, not a price.
PRICING_STATUSES = ("include_hit", "llm_confirmed")


def _days_between(older: str, newer: str) -> int | None:
    """newer minus older in days; None when either is not an ISO date."""
    try:
        from datetime import date
        return (date.fromisoformat(newer[:10]) - date.fromisoformat(older[:10])).days
    except (ValueError, TypeError):
        return None


def _resolve_pu(row, basis):
    """Per-unit price in the board's declared basis, or None. Mirrors the
    derivation board_parity uses, so state and parity cannot disagree."""
    pu, unit = reconcile_unit(row["unit_price"], row["unit"], basis)
    if pu is None:
        derived, derived_unit = per_unit(row["price"], row["size_text"], basis,
                                         row["product_name"])
        pu, unit = reconcile_unit(derived, derived_unit, basis)
    return pu, unit


def build_cell_state(db, ts: str) -> dict:
    """Collapse surviving observations into one answer per (commodity, store).

    Everyday and ad are tracked SEPARATELY rather than as one 'best price',
    because they expire on different rules: everyday on the capture quarter, ad
    on its cycle window. Merging them is how an expired sale price goes on
    looking like a shelf price — the failure this whole table exists to end.
    """
    props = {r["id"]: json.loads(r["properties_json"] or "{}")
             for r in db.conn.execute(
                 "SELECT id, properties_json FROM nodes WHERE type='Commodity'")}
    cycles = {}
    for c in db.conn.execute(
            "SELECT id, properties_json FROM nodes WHERE type='AdCycle'"):
        p = json.loads(c["properties_json"] or "{}")
        if p.get("from") and p.get("to"):
            cycles[c["id"]] = (p["from"], p["to"])

    today = ts[:10]
    rows = db.conn.execute(
        f"""SELECT id, commodity_id, store_id, product_name, price, unit_price,
                   unit, size_text, price_type, ad_cycle_id, observed_at, source_file
            FROM price_observations
            WHERE match_status IN ({','.join('?' * len(PRICING_STATUSES))})
              AND basis_flag IS NULL AND price IS NOT NULL""",
        PRICING_STATUSES).fetchall()

    # newest sighting per (cell, product, kind); an older sighting of the same
    # product is superseded by its latest one.
    newest: dict[tuple, dict] = {}
    for r in rows:
        # An "A or B" ad line names two products and one price; neither can be
        # priced from it. See units.names_multiple_products.
        if names_multiple_products(r["product_name"]):
            continue
        basis = (props.get(r["commodity_id"]) or {}).get("unit_basis")
        pu, unit = _resolve_pu(r, basis)
        if pu is None:
            continue
        kind = "ad" if (r["price_type"] or "").lower() in ("ad", "sale") else "everyday"
        if kind == "ad":
            win = cycles.get(r["ad_cycle_id"] or "")
            # An ad price with no resolvable window can never be shown to be
            # current, so it is not one. Missed-over-false, again.
            if not win or not (win[0] <= today <= win[1]):
                continue
        key = (r["commodity_id"], r["store_id"], kind,
               norm_text(r["product_name"]))
        prev = newest.get(key)
        obs = r["observed_at"] or ""
        if prev is None or obs > prev["observed_at"] or (
                obs == prev["observed_at"] and pu < prev["pu"]):
            newest[key] = {"row": r, "pu": pu, "unit": unit,
                           "observed_at": obs,
                           "curated": "product-urls" in (r["source_file"] or ""),
                           "window": cycles.get(r["ad_cycle_id"] or "")}

    # PRECEDENCE, mirroring what the live board renders — the same rule
    # board_parity.graph_board applies, and it must be the same in both places
    # or state and parity become two opinions about one answer:
    #   1. the CURATED product-urls row (the See-item link a human verified)
    #   2. otherwise the cheapest surviving sweep row
    # The sweep is a DISCOVERY lane and routinely sees a cheaper near-match the
    # board deliberately did not pick; taking a flat minimum across both was
    # measured here at 143 false-cheap cells against the board's 75.
    # Curated wins only while CURRENT: a curated sighting more than 14 days
    # older than the cell's newest sweep sighting has been overtaken by events
    # (July's $1.89 Aldi strawberries were outranking August shelf data).
    cur_best: dict[tuple[str, str, str], dict] = {}
    sweep_best: dict[tuple[str, str, str], dict] = {}
    for (cid, sid, kind, _pk), v in newest.items():
        tgt = cur_best if v["curated"] else sweep_best
        k = (cid, sid, kind)
        if k not in tgt or v["pu"] < tgt[k]["pu"]:
            tgt[k] = v

    best: dict[tuple[str, str], dict] = {}
    for k in set(cur_best) | set(sweep_best):
        cid, sid, kind = k
        c, s = cur_best.get(k), sweep_best.get(k)
        pick = c or s
        if c and s:
            stale = _days_between(c["observed_at"], s["observed_at"])
            pick = s if (stale is not None and stale > 14) else c
        best.setdefault((cid, sid), {})[kind] = pick

    # Preserve reverted_checked_at across rebuilds — it records that a HUMAN or
    # a capture actually verified the post-ad shelf price, which no derivation
    # can reproduce. Losing it on rebuild would silently clear an owed check.
    prior = {(r["commodity_id"], r["store_id"]): r["reverted_checked_at"]
             for r in db.conn.execute(
                 "SELECT commodity_id, store_id, reverted_checked_at FROM cell_state")}

    db.conn.execute("DELETE FROM cell_state")
    n = 0
    for (cid, sid), kinds in best.items():
        e, a = kinds.get("everyday"), kinds.get("ad")
        db.conn.execute(
            """INSERT INTO cell_state
                 (commodity_id, store_id,
                  everyday_price, everyday_unit_price, everyday_unit, everyday_size,
                  everyday_product, everyday_asof, everyday_evidence,
                  ad_price, ad_unit_price, ad_product, ad_from, ad_to, ad_evidence,
                  reverted_checked_at, updated_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (cid, sid,
             e["row"]["price"] if e else None,
             e["pu"] if e else None,
             e["unit"] if e else None,
             e["row"]["size_text"] if e else None,
             e["row"]["product_name"] if e else None,
             e["observed_at"] if e else None,
             e["row"]["id"] if e else None,
             a["row"]["price"] if a else None,
             a["pu"] if a else None,
             a["row"]["product_name"] if a else None,
             a["window"][0] if a and a["window"] else None,
             a["window"][1] if a and a["window"] else None,
             a["row"]["id"] if a else None,
             prior.get((cid, sid)),
             ts))
        n += 1
    db.conn.commit()
    return {"cells": n,
            "with_everyday": sum(1 for v in best.values() if "everyday" in v),
            "with_ad": sum(1 for v in best.values() if "ad" in v)}


def build_question_verdicts(db, ts: str) -> dict:
    """Bank each adjudication once, keyed by the question it answers.

    Precedence when the same question carries different statuses across rows
    (which happens when a ruling retro-applied to some rows but a later import
    re-asserted others): the most RESTRICTIVE verdict wins. A question ruled
    known_wrong anywhere is known_wrong everywhere — that is what makes an
    absolute ruling absolute.
    """
    rank = {"known_wrong": 0, "category_excluded": 1, "excluded": 2,
            "llm_rejected": 3, "escalated": 4, "llm_match_unverified": 5,
            "no_include_hit": 6, "llm_confirmed": 7, "include_hit": 8}
    # Only EXPENSIVE verdicts are banked. A deterministic one (include_hit,
    # excluded, category_excluded, no_include_hit) is re-derived from the rules
    # in ~1.5s for 100k rows, the resolver's bank never reads it, and banking it
    # would freeze a rule the next commodities.json edit is meant to change.
    # Banking all of them also made the tracked export 11.5 MB of daily churn to
    # store answers nobody consults. What IS banked: model calls (55 GPU-minutes
    # to reproduce), reviewer rulings (human time), and known-wrong (absolute).
    BANKABLE = ("llm_rejected", "llm_confirmed", "llm_match_unverified",
                "escalated", "known_wrong")
    rows = db.conn.execute(
        f"""SELECT commodity_id, product_name, match_status, match_reason, confidence
            FROM price_observations
            WHERE product_name IS NOT NULL
              AND match_status IN ({','.join('?' * len(BANKABLE))})""",
        BANKABLE).fetchall()
    picked: dict[tuple[str, str], dict] = {}
    for r in rows:
        key = (r["commodity_id"], norm_text(r["product_name"]))
        cur = picked.get(key)
        if cur is None or rank.get(r["match_status"], 9) < rank.get(cur["match_status"], 9):
            picked[key] = dict(r)

    db.conn.execute("DELETE FROM question_verdicts")
    db.conn.executemany(
        """INSERT INTO question_verdicts
             (commodity_id, product_key, product_name, status, reason,
              confidence, decided_by, prompt_version, decided_at)
           VALUES (?,?,?,?,?,?,?,?,?)""",
        [(cid, pk, v["product_name"], v["match_status"], v["match_reason"],
          v["confidence"],
          # AUTHORSHIP, not status. This column used to read
          # `"model" if status.startswith("llm_")`, which stamped 'model' on
          # every Claude reviewer ruling too — reviewer verdicts land as
          # llm_confirmed/llm_rejected because those are match_status values,
          # not authorship. The column therefore held two values across 4,141
          # rows and told nobody anything. decided_by_stamp reads the reason's
          # authorship marker instead (graph/lib/authority.py). ADVISORY ONLY:
          # the resolver re-derives the tier from `reason` at retrieval time, so
          # a bank written before this fix is stale, never wrong.
          decided_by_stamp(v["match_status"], v["match_reason"]),
          None, ts)
         for (cid, pk), v in picked.items()])
    db.conn.commit()
    by = {}
    for v in picked.values():
        by[v["match_status"]] = by.get(v["match_status"], 0) + 1
    return {"questions": len(picked), "by_status": by}


def export_state(db) -> dict:
    """Write both tables to tracked JSON. This is the price historian: every
    change becomes a commit diff, so history costs nothing and is never lost."""
    os.makedirs(STATE_DIR, exist_ok=True)
    cells = [dict(r) for r in db.conn.execute(
        "SELECT * FROM cell_state ORDER BY commodity_id, store_id")]
    verdicts = [dict(r) for r in db.conn.execute(
        "SELECT * FROM question_verdicts ORDER BY commodity_id, product_key")]
    write_json(CELL_STATE_JSON, cells)
    write_json(VERDICTS_JSON, verdicts)
    return {"cell_state_rows": len(cells), "question_verdict_rows": len(verdicts)}


def verify_against_matrix(db) -> dict:
    """PHASE A GATE: cell_state must reproduce the board matrix the graph
    derives the OLD way, cell for cell and price for price.

    RUN THIS BEFORE THE SUPERSEDE-PRUNE, which is why import_all calls it there.
    The comparison is only meaningful while both derivations see the SAME
    evidence: after the prune, graph_board() can read only the rows that
    survived, so it becomes a degraded view of the very table it is meant to
    audit, and the gate starts reporting a gap that is the prune's doing rather
    than the migration's. Run standalone post-prune it will read a little low;
    the number recorded during the import is the honest one.

    The comparison target is board_parity.graph_board() — the from-observations
    derivation — and not v_current_cell, because those answer different
    questions: the view names the NEWEST row in a cell, while both graph_board
    and cell_state name the row the BOARD would render (curated precedence, ad
    windows, override pins). Gating state against the view compared a price to
    a different price and called the gap a defect; gating it against
    graph_board asks the only question that matters — does moving the readers
    onto state change any answer?
    """
    sys.path.insert(0, os.path.join(HERE, "..", "eval"))
    from board_parity import graph_board                     # noqa: PLC0415
    props = {r["id"]: json.loads(r["properties_json"] or "{}")
             for r in db.conn.execute(
                 "SELECT id, properties_json FROM nodes WHERE type='Commodity'")}
    legacy_of = {cid: (p or {}).get("legacy_id") for cid, p in props.items()}

    old = graph_board(db)                     # legacy_id -> store -> per_unit
    new: dict[str, dict[str, float]] = {}
    for r in db.conn.execute("SELECT * FROM cell_state"):
        legacy = legacy_of.get(r["commodity_id"])
        if not legacy:
            continue
        vals = [v for v in (r["everyday_unit_price"], r["ad_unit_price"]) if v is not None]
        if vals:
            new.setdefault(legacy, {})[r["store_id"].replace("store:", "")] = min(vals)

    old_cells = {(c, s) for c, v in old.items() for s in v}
    new_cells = {(c, s) for c, v in new.items() for s in v}
    shared = old_cells & new_cells
    differ = [(c, s, old[c][s], new[c][s]) for c, s in sorted(shared)
              if abs(old[c][s] - new[c][s]) > max(old[c][s], 1e-9) * 0.001]

    # THE GATE IS NOT BYTE-IDENTITY, and that is a deliberate call. Demanding
    # every price match the old derivation would freeze a derivation measured
    # WRONG: on the 14 cells where the two differ, the live board sides with
    # state on clementines ($0.998) and grapes ($1.77) and with the old path on
    # beef-jerky — the residue is the unsettled ad-versus-curated precedence
    # question, where the legacy board is itself inconsistent.
    #
    # What must hold is that moving the readers onto state changes no answer
    # for the WORSE: identical cell coverage, and agreement with the LIVE board
    # no lower than the path being replaced.
    from board_parity import parse_live_board, compare      # noqa: PLC0415
    live_all = parse_live_board()
    live = {c: v for c, v in live_all.items() if not c.endswith("::r")}
    agree_old = compare(live, old, 0.02)["agreement"]
    agree_new = compare(live, new, 0.02)["agreement"]
    return {"observation_cells": len(old_cells), "state_cells": len(new_cells),
            "shared": len(shared),
            "only_from_observations": len(old_cells - new_cells),
            "only_in_state": len(new_cells - old_cells),
            "price_differs": len(differ),
            "agreement_from_observations": round(agree_old, 4),
            "agreement_from_state": round(agree_new, 4),
            "examples_only_obs": sorted(old_cells - new_cells)[:5],
            "examples_differ": differ[:5],
            "ok": not (old_cells - new_cells) and agree_new >= agree_old}


def supersede_prune(db, ts: str, dry_run: bool = False) -> dict:
    """PHASE C: delete observations a newer sighting of the same product has
    superseded — bounded by the CATALOG, not by elapsed time.

    Two rows are never deleted, and this is what makes the prune safe:
      * anything cell_state cites as evidence (the live answer's receipt)
      * anything still open — unadjudicated, escalated, llm_match_unverified —
        because those are questions in flight, not stale data.
    Adjudication is not lost either: it lives in question_verdicts, one row per
    question, so deleting the 39 duplicate askers destroys no work.
    """
    evidence = {r[0] for r in db.conn.execute(
        "SELECT everyday_evidence FROM cell_state WHERE everyday_evidence IS NOT NULL")}
    evidence |= {r[0] for r in db.conn.execute(
        "SELECT ad_evidence FROM cell_state WHERE ad_evidence IS NOT NULL")}
    open_statuses = ("unadjudicated", "escalated", "llm_match_unverified")

    rows = db.conn.execute(
        """SELECT id, commodity_id, store_id, product_name, price_type,
                  observed_at, match_status
           FROM price_observations
           ORDER BY observed_at DESC, id DESC""").fetchall()
    seen: set[tuple] = set()
    doomed: list[str] = []
    for r in rows:
        if r["id"] in evidence or r["match_status"] in open_statuses:
            continue
        key = (r["commodity_id"], r["store_id"], norm_text(r["product_name"]),
               (r["price_type"] or "").lower())
        if key in seen:
            doomed.append(r["id"])          # an older sighting of the same thing
        else:
            seen.add(key)
    if not dry_run and doomed:
        db.conn.executemany("DELETE FROM price_observations WHERE id=?",
                            [(i,) for i in doomed])
        db.conn.commit()
    return {"examined": len(rows), "superseded": len(doomed),
            "kept_as_evidence": len(evidence), "dry_run": dry_run}


def ad_reversions_owed(db, ts: str) -> list[dict]:
    """PHASE D: cells whose ad window has closed with no verification pull.

    Brad's rule: when an ad stops, somebody must confirm the shelf went back to
    the everyday price. Until then the cell is carrying an assumption, and this
    estate's history is a list of assumptions that turned out to be stale prices.
    """
    today = ts[:10]
    return [dict(r) for r in db.conn.execute(
        """SELECT commodity_id, store_id, ad_to, ad_product, everyday_price
           FROM cell_state
           WHERE ad_to IS NOT NULL AND ad_to < ?
             AND reverted_checked_at IS NULL
           ORDER BY ad_to""", (today,))]


def emit_reversion_worklist(db, ts: str) -> dict:
    """Write the owed re-checks where the capture policy already looks.

    Deliberately NOT a new scheduling mechanism: grocery/out/worklists/ is the
    file set capture-run.ps1 already paces per store, so this rides the existing
    cadence instead of inventing a second one that could drift from it.
    """
    owed = ad_reversions_owed(db, ts)
    if not owed:
        return {"owed": 0, "written": None}
    by_store: dict[str, list] = {}
    for o in owed:
        by_store.setdefault(o["store_id"].replace("store:", ""), []).append(
            {"commodity": o["commodity_id"].split(":")[-1],
             "reason": f"ad ended {o['ad_to']}; confirm shelf reverted to everyday",
             "was_ad_product": o["ad_product"]})
    out = os.path.join(REPO_ROOT, "grocery", "out", "worklists",
                       f"ad-reversion-{ts[:10]}.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    write_json(out, {"generated": ts, "kind": "ad-reversion-verification",
                     "note": "Each entry is a cell whose ad window closed with no "
                             "post-ad price check. Capture these terms and the "
                             "state builder will clear or update the cell.",
                     "stores": by_store})
    return {"owed": len(owed), "written": os.path.relpath(out, REPO_ROOT),
            "stores": {k: len(v) for k, v in by_store.items()}}


def main() -> int:
    ap = argparse.ArgumentParser(description="Build and maintain price state")
    ap.add_argument("--verify", action="store_true", help="Phase A gate only")
    ap.add_argument("--prune", action="store_true", help="Phase C supersede-prune")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--ad-reversions", action="store_true", help="Phase D worklist")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    run = f"run:state:{time.strftime('%Y%m%dT%H%M%S')}"
    out: dict = {}
    with open_db() as db:
        if args.verify:
            out["gate"] = verify_against_matrix(db)
        elif args.ad_reversions:
            out["ad_reversions"] = emit_reversion_worklist(db, ts)
        elif args.prune:
            out["prune"] = supersede_prune(db, ts, dry_run=args.dry_run)
        else:
            out["cell_state"] = build_cell_state(db, ts)
            out["verdicts"] = build_question_verdicts(db, ts)
            out["gate"] = verify_against_matrix(db)
            out["export"] = export_state(db)
        db.log_event(run=run, timestamp=ts, etype="state_transition",
                     decision="price_state", detail=out)

    if args.json:
        print(json.dumps(out, indent=2, default=str))
        return 0
    for section, body in out.items():
        print(f"\n=== {section} ===")
        if isinstance(body, dict):
            for k, v in body.items():
                print(f"  {k:<26} {v}")
        else:
            print(f"  {body}")
    gate = out.get("gate")
    if gate is not None:
        print(f"\n  PHASE A GATE: {'PASS' if gate['ok'] else 'FAIL'}")
        return 0 if gate["ok"] else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
