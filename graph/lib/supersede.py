"""The price-state rules the importers must respect, in ONE place (backlog I211, 2026-09-19).

    from supersede import (supersede_key, OPEN_STATUSES, PRICING_STATUSES, BANKABLE, VERDICT_RANK,
                           evidence_ids, cell_context, cell_candidate, SupersedeGuard)

WHY THIS MODULE EXISTS. graph/pipeline/state.py's supersede_prune deletes an observation a newer
sighting of the same product has replaced. The importers re-read EVERY capture file on every run, so
every row the last prune deleted came straight back as a new row, was resolved, and was deleted again.
Measured on a backup-API copy of the live graph.db over the captures at f4e50313b: one
`import_all.py --observations` pass inserted 477,950 rows and pruned 477,950, and the first pass grew
the file 323,358,720 -> 446,959,616 B. graph.db's size was the import's PEAK, not its data.

THE THREE RULES A SKIPPED ROW MUST NOT BREAK, because the rows the old import re-inserted were read by
cell_state and question_verdicts BEFORE the prune deleted them again. A row is skipped (never inserted)
only when ALL of these hold; any doubt inserts it exactly as before:

  1. THE PRUNE WOULD DELETE IT. Walk a key's rows newest first by (observed_at, id). A row cell_state
     cites as evidence, or one whose question is still open, is kept and never marks the key; the first
     other row marks it and every later row is superseded. So the database must already hold a row of
     the same key, neither evidence nor open, that sorts AHEAD of the incoming one - and the incoming
     row's own predicted status must not be open, or the prune would keep it.
  2. CELL_STATE'S ANSWER WOULD NOT MOVE. cell_state takes the newest PRICEABLE sighting per product
     (a tie on the date goes to the lower unit price), then the cheapest curated and the cheapest
     sweep product per cell. So a row predicted to price is skipped only when it cannot be priced, or
     cannot take its product's slot, or takes a slot that neither was nor becomes the best of its
     group. (Found by the paired runs: a newer sighting whose size will not convert, `24 fl oz`
     against an `oz` basis, left the older `10 oz` sighting as the cell's evidence; a same-day sweep
     row 0.0001 a unit cheaper than a curated row took its slot and moved the cell to another product;
     and a duplicate-named row carrying a second listing's price did the same to a corn-dog cell.)
  3. THE VERDICT BANK WOULD NOT READ IT. question_verdicts keeps the most restrictive status per
     question. A row whose predicted status is bankable and strictly more restrictive than every
     present row's is inserted. (Found by the same run: a known-wrong ruling reached a question only
     through the re-inserted rows, because the present one was a reviewer rejection nobody re-rolls.)

The predicted status is the resolver's own deterministic answer for (commodity, product name), which
graph/pipeline/resolve.py documents as a pure function of those two and re-computes for every
deterministic row on every run. The importer passes it in (`predict`), so this module owns the rules
and never the resolver.

A ROW ALREADY PRESENT IS NEVER SKIPPED: it is upserted as before, so a capture file rewritten under the
same name (boards and regular files are rebuilt under one dated name several times a day) still lands
its new price. And nothing is remembered between runs: if the row that superseded a sighting is later
deleted, the sighting has nothing ahead of it on the next run and comes back.
"""
from __future__ import annotations

import json
from typing import Callable

from ids import norm_text
from units import names_multiple_products, per_unit, reconcile_unit

# Questions still in flight: the prune never deletes these, so they never supersede anything.
OPEN_STATUSES = ("unadjudicated", "escalated", "llm_match_unverified")

# Only these two may price a cell - the same whitelist v_current_cell enforces and
# verifier.check_no_unresolved_pricing re-checks. llm_match_unverified is deliberately absent.
PRICING_STATUSES = ("include_hit", "llm_confirmed")

# The verdict bank's precedence and membership; see state.build_question_verdicts for why.
VERDICT_RANK = {"known_wrong": 0, "category_excluded": 1, "excluded": 2,
                "llm_rejected": 3, "helper_rejected": 3.5, "escalated": 4,
                "llm_match_unverified": 5,
                "no_include_hit": 6, "llm_confirmed": 7, "include_hit": 8}
BANKABLE = ("llm_rejected", "llm_confirmed", "llm_match_unverified",
            "escalated", "known_wrong", "helper_rejected")


def supersede_key(commodity_id, store_id, product_name, price_type) -> tuple:
    """The identity two sightings share when the prune lets the newer one supersede the older."""
    return (commodity_id, store_id, norm_text(product_name), (price_type or "").lower())


def cell_kind(price_type) -> str:
    return "ad" if (price_type or "").lower() in ("ad", "sale") else "everyday"


def evidence_ids(db) -> set:
    """Every observation id cell_state cites. The prune keeps these whatever their age."""
    ev = {r[0] for r in db.conn.execute(
        "SELECT everyday_evidence FROM cell_state WHERE everyday_evidence IS NOT NULL")}
    ev |= {r[0] for r in db.conn.execute(
        "SELECT ad_evidence FROM cell_state WHERE ad_evidence IS NOT NULL")}
    return ev


def cell_context(db) -> tuple[dict, dict]:
    """(unit basis per commodity node, (from, to) per AdCycle node): what cell_candidate reads."""
    basis = {}
    for r in db.conn.execute("SELECT id, properties_json FROM nodes WHERE type='Commodity'"):
        basis[r[0]] = (json.loads(r[1] or "{}") or {}).get("unit_basis")
    cycles = {}
    for r in db.conn.execute("SELECT id, properties_json FROM nodes WHERE type='AdCycle'"):
        p = json.loads(r[1] or "{}")
        if p.get("from") and p.get("to"):
            cycles[r[0]] = (p["from"], p["to"])
    return basis, cycles


def resolve_pu(row, basis):
    """Per-unit price in the board's declared basis, or None. Mirrors the
    derivation board_parity uses, so state and parity cannot disagree."""
    pu, unit = reconcile_unit(row["unit_price"], row["unit"], basis)
    if pu is None:
        derived, derived_unit = per_unit(row["price"], row["size_text"], basis,
                                         row["product_name"])
        pu, unit = reconcile_unit(derived, derived_unit, basis)
    return pu, unit


def cell_candidate(row, basis, cycles: dict, today: str):
    """(kind, pu, unit) when cell_state may price this row, else None. The row has already passed
    the SQL half of the filter (a pricing status, no basis_flag, a price)."""
    # An "A or B" ad line names two products and one price; neither can be
    # priced from it. See units.names_multiple_products.
    if names_multiple_products(row["product_name"]):
        return None
    pu, unit = resolve_pu(row, basis)
    if pu is None:
        return None
    kind = cell_kind(row["price_type"])
    if kind == "ad":
        win = cycles.get(row["ad_cycle_id"] or "")
        # An ad price with no resolvable window can never be shown to be
        # current, so it is not one. Missed-over-false, again.
        if not win or not (win[0] <= today <= win[1]):
            return None
    return kind, pu, unit


def is_curated(source_file) -> bool:
    """A product-urls row: the See-item link a human verified, which cell_state prefers."""
    return "product-urls" in (source_file or "")


def stored_rows(observations: list) -> dict:
    """oid -> the row GraphDB.add_observation's upsert leaves behind when several of `observations`
    share one oid: the first copy's fields, with the LAST copy's price and unit_price (the only two
    value columns its ON CONFLICT clause overwrites)."""
    out: dict = {}
    for o in observations:
        cur = out.get(o["id"])
        if cur is None:
            out[o["id"]] = dict(o)
        else:
            cur["price"] = o.get("price")
            cur["unit_price"] = o.get("unit_price")
    return out


class SupersedeGuard:
    """Built once per importer run from the database as it stands; see the module docstring.

    `predict(commodity_id, product_name)` returns the status the resolver will give a new row.
    """

    def __init__(self, db, ts: str, predict: Callable[[str, str], str], doomed: set | None = None):
        """`doomed`: ids of present rows this run deletes before its prune (a lane's stale or legacy
        rows). They are read as already gone: never a newer sighting, never a slot, never a verdict."""
        self.predict = predict
        doomed = doomed or set()
        evidence = evidence_ids(db)
        basis, cycles = cell_context(db)
        today = ts[:10]
        self._basis, self._cycles, self._today = basis, cycles, today
        self.present: set = set()
        self.ahead: dict = {}         # prune key -> newest (observed_at, id) that would mark it
        # product slot (commodity, store, kind, product) -> (observed_at, unit price, curated), in
        # first-seen order: exactly what cell_state's newest-sighting slot holds once every present
        # row is read, since both read the table in rowid order
        self.priced: dict = {}
        self.bank_rank: dict = {}     # question -> most restrictive present bankable rank
        self._decided: dict = {}      # oid -> the answer given, so every copy of one oid agrees
        for r in db.conn.execute(
                "SELECT id, commodity_id, store_id, product_name, price_type, observed_at, "
                "match_status, price, unit_price, unit, size_text, ad_cycle_id, basis_flag, "
                "source_file FROM price_observations"):
            oid, status, obs = r["id"], r["match_status"], r["observed_at"] or ""
            if oid in doomed:
                continue
            self.present.add(oid)
            if status in BANKABLE and r["product_name"] is not None:
                q = (r["commodity_id"], norm_text(r["product_name"]))
                rank = VERDICT_RANK.get(status, 9)
                if rank < self.bank_rank.get(q, 99):
                    self.bank_rank[q] = rank
            if (status in PRICING_STATUSES and r["basis_flag"] is None
                    and r["price"] is not None):
                c = cell_candidate(r, basis.get(r["commodity_id"]), cycles, today)
                if c is not None:
                    ck = (r["commodity_id"], r["store_id"], c[0], norm_text(r["product_name"]))
                    cur = self.priced.get(ck)
                    if cur is None or obs > cur[0] or (obs == cur[0] and c[1] < cur[1]):
                        self.priced[ck] = (obs, c[1], is_curated(r["source_file"]))
            if oid in evidence or status in OPEN_STATUSES:
                continue
            k = supersede_key(r["commodity_id"], r["store_id"], r["product_name"], r["price_type"])
            mark = (obs, oid)
            cur = self.ahead.get(k)
            if cur is None or mark > cur:
                self.ahead[k] = mark
        # (commodity, store, kind, curated) -> (lowest slot unit price, the normalised product name
        # holding it): the two bests cell_state's precedence chooses between (curated first, unless
        # 14 days stale)
        self.best: dict = {}
        for (cid, sid, kind, norm), (_obs, pu, cur_) in self.priced.items():
            g = (cid, sid, kind, cur_)
            if g not in self.best or pu < self.best[g][0]:
                self.best[g] = (pu, norm)
        self.skipped = 0
        # absent rows inserted, by the rule that kept them (a present row is not counted)
        self.inserted_because: dict = {}

    def already_superseded(self, oid: str, commodity_id, store_id, product_name,
                           price_type, observed_at, row: dict | None = None) -> bool:
        """True only when the row is absent and inserting it would change nothing but the freelist.

        `row`, when given, is the row AS IT WOULD BE STORED (see stored_rows): price, unit_price,
        unit, size_text, product_name, price_type, ad_cycle_id. It lets rule 2 see that a row cannot
        be priced at all, or loses its date's tie on unit price. Without it rule 2 inserts any row
        predicted to price that has no strictly newer priceable sighting. Every call for one oid gets
        the first call's answer, because every copy of one oid lands on one stored row.
        """
        if oid in self.present:
            return False
        if oid in self._decided:
            skip = self._decided[oid]
            if skip:
                self.skipped += 1
            return skip
        skip = self._decide(oid, commodity_id, store_id, product_name, price_type,
                            observed_at or "", row)
        self._decided[oid] = skip
        if skip:
            self.skipped += 1
        return skip

    def _decide(self, oid, commodity_id, store_id, product_name, price_type, obs, row) -> bool:
        cur = self.ahead.get(supersede_key(commodity_id, store_id, product_name, price_type))
        if cur is None or not cur > (obs, oid):
            return self._keep("nothing_ahead")               # rule 1: the prune would keep it
        status = self.predict(commodity_id, product_name or "")
        if status in OPEN_STATUSES:
            return self._keep("open")                        # rule 1: the prune keeps open rows
        norm = norm_text(product_name)
        if status in PRICING_STATUSES:
            why = self._may_take_slot(commodity_id, store_id, norm, price_type, obs, row)
            if why:
                return self._keep(why)                       # rule 2: it could be the cell's price
        if status in BANKABLE and product_name is not None:
            if VERDICT_RANK.get(status, 9) < self.bank_rank.get((commodity_id, norm), 99):
                return self._keep("may_bank")                # rule 3: it would move the bank
        return True

    def _may_take_slot(self, commodity_id, store_id, norm, price_type, obs, row) -> str:
        """Why cell_state's newest-sighting slot for this product COULD hold this row, or "" when it
        never can.

        The slot is read in rowid order and a new row's rowid is past every present row's
        (EXPLAIN QUERY PLAN on build_cell_state's SELECT is a full SCAN; no index covers
        match_status), so on its date a new row takes the slot only with a STRICTLY lower unit price.
        """
        if row is None:
            slot = self.priced.get((commodity_id, store_id, cell_kind(price_type), norm))
            return "" if (slot is not None and slot[0] > obs) else "may_price_unread"
        if row.get("price") is None:
            return ""                                        # the SQL half refuses it
        c = cell_candidate(row, self._basis.get(commodity_id), self._cycles, self._today)
        if c is None:
            return ""                                        # it cannot be priced at all
        kind, pu = c[0], c[1]
        prod = (commodity_id, store_id, kind, norm)
        slot = self.priced.get(prod)
        if slot is not None and (slot[0] > obs or (slot[0] == obs and pu >= slot[1])):
            return ""
        # It WOULD take its product's slot. The cell's answer moves only if that slot is, or
        # becomes, the best of its group (curated or sweep); an equal price is counted as moving
        # it, because which of two equal slots wins depends on their order.
        if slot is not None and self.best.get((commodity_id, store_id, kind, slot[2]),
                                              (None, None))[1] == norm:
            return "may_price_replaces_best"
        best = self.best.get((commodity_id, store_id, kind, is_curated(row.get("source_file"))))
        if best is None or pu <= best[0]:
            return "may_price_becomes_best"
        return ""

    def _keep(self, why: str) -> bool:
        self.inserted_because[why] = self.inserted_because.get(why, 0) + 1
        return False
