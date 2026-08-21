"""Verifier — the gate checks, as graph queries (Phase 3).

Separating the Verifier from the Executor is the point of the Planner/Executor/
Verifier split: the thing that DOES the work is never the thing that decides
whether the work was acceptable. An executor that grades its own output can
always find a reason to proceed.

Every check here answers from the GRAPH, and every one preserves a gate that
already exists in the legacy estate. These run in shadow alongside the real
guards during Phase 3; they never replace them until the parity gate passes.

A check returns (ok, detail). `ok=False` on a BLOCKING step stops the run.
"""

from __future__ import annotations

import json
import os
import re
import sys
from datetime import date as _date, datetime, timedelta

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

from graphdb import open_db                    # noqa: E402


def _parse(d: str | None):
    if not d:
        return None
    for fmt in ("%Y-%m-%d", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(d[:len(fmt) + 2][:19], fmt).date()
        except ValueError:
            continue
    return None


def check_omaha_identity(db, **_) -> tuple[bool, dict]:
    """Every Store node must be Omaha-scoped.

    The estate's oldest hard gate. A capture that silently came from a
    non-Omaha store prices the board for the wrong city.
    """
    bad = []
    for n in db.nodes_of_type("Store"):
        props = json.loads(n["properties_json"] or "{}")
        if not props.get("omaha_identity"):
            bad.append({"store": n["canonical_name"], "id": n["id"]})
    return (not bad), {"checked": len(db.nodes_of_type("Store")), "violations": bad}


def check_ad_window(db, today: str | None = None, grace_days: int = 1,
                    **_) -> tuple[bool, dict]:
    """The CURRENT ad cycle of every weekly-ad store must contain today.

    Walmart and Sam's are exempt: they genuinely have no weekly ad cycle.
    A stale window means the board is quoting last week's sale prices.

    DUE vs OVERDUE is a real distinction, not pedantry. A store whose window
    ended yesterday and whose `next_pull` is today is simply waiting for a pull
    that has not run yet — normal mid-morning state, and failing the run for it
    would cry wolf every week. A store whose `next_pull` has itself passed is a
    genuine miss: nothing captured it and nobody noticed. Only the latter fails.
    """
    today_d = _parse(today) or _date.today()
    due, overdue, checked = [], [], 0

    for n in db.nodes_of_type("Store"):
        props = json.loads(n["properties_json"] or "{}")
        if not props.get("cadence_days"):
            continue                                    # no weekly ad cycle
        checked += 1
        w = props.get("ad_window") or {}
        frm, to = _parse(w.get("from")), _parse(w.get("to"))
        nxt = _parse(props.get("next_pull"))

        if not (frm and to):
            overdue.append({"store": n["canonical_name"], "reason": "no current window"})
            continue
        if frm <= today_d <= to:
            continue                                    # in window, healthy

        rec = {"store": n["canonical_name"], "window": f"{frm}..{to}",
               "today": str(today_d), "days_past_window": (today_d - to).days,
               "next_pull": str(nxt) if nxt else None,
               "pull_method": props.get("pull_method")}

        if nxt and today_d > nxt + timedelta(days=grace_days):
            rec["days_overdue"] = (today_d - nxt).days
            overdue.append(rec)
        else:
            due.append(rec)                             # awaiting today's pull

    return (not overdue), {"checked": checked, "overdue": overdue, "due_today": due}


def check_known_wrong_not_priced(db, **_) -> tuple[bool, dict]:
    """No adjudicated known-wrong product may be pricing a cell.

    The graph mirror of audit-known-wrong.ps1, which exits 2 for exactly this.
    A ruling that can come back silently is not a ruling.

    TWO halves, and the second exists because the first was blind to it:
    a row already demoted to match_status='known_wrong' cannot price by
    construction — but a row adjudicated include_hit BEFORE the ruling existed
    kept its status and kept pricing (the 2026-08-20 strawberry-syrup ruling
    demoted nothing already in the graph). The import sweep retro-applies
    rulings; this check proves, by NAME, that nothing slipped either path.
    """
    from ids import norm_text                          # noqa: PLC0415
    rows = db.conn.execute(
        """SELECT commodity_id, store_id, product_name
           FROM price_observations
           WHERE match_status='known_wrong'
             AND id IN (SELECT id FROM v_current_cell)""").fetchall()
    viol = [dict(r) for r in rows]

    kw = db.conn.execute(
        """SELECT n.canonical_name AS nm, e.target_id AS cid
           FROM nodes n JOIN edges e ON e.source_id = n.id
           WHERE n.type='KnownWrong' AND e.predicate='known_wrong_for'""").fetchall()
    by_commodity: dict[str, set[str]] = {}
    for r in kw:
        by_commodity.setdefault(r["cid"], set()).add(norm_text(r["nm"]))
    priced = db.conn.execute(
        "SELECT commodity_id, store_id, product_name FROM v_current_cell").fetchall()
    for r in priced:
        names = by_commodity.get(r["commodity_id"])
        if names and norm_text(r["product_name"]) in names:
            viol.append({**dict(r), "via": "name-match: ruling never retro-applied"})
    return (not viol), {"violations": viol, "n": len(viol)}


def check_no_unresolved_pricing(db, **_) -> tuple[bool, dict]:
    """Only adjudicated rows may price a cell.

    Guards against a regression where 'unadjudicated' leaks into the board view.
    The whitelist is include_hit + llm_confirmed ONLY, and llm_confirmed means
    REVIEWER-confirmed: 'llm_match_unverified' (a confident local-model MATCH)
    is deliberately outside it — the local model may never mint a price.
    """
    n = db.conn.execute(
        """SELECT COUNT(*) FROM price_observations
           WHERE match_status NOT IN ('include_hit','llm_confirmed')
             AND id IN (SELECT id FROM v_current_cell)""").fetchone()[0]
    return (n == 0), {"leaked_rows": n}


def _policy_max_carry_days() -> int:
    """The everyday-price window, read from the ONE canonical definition.

    grocery/capture-policy.ps1 says of MaxCarryDays: "Change it HERE and
    nowhere else." A hardcoded copy here is exactly the private-window defect
    the estate spent three commits closing (audit-coverage-gaps said 14 while
    the engine moved to the 90-day quarter, and manufactured a false alarm) —
    and this check itself shipped with 21 while the policy said 90. A gate
    that cannot read its own window must fail loudly, never guess.
    """
    policy = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "..", "..", "grocery", "capture-policy.ps1")
    with open(policy, encoding="utf-8-sig") as fh:
        for line in fh:
            m = re.match(r"\s*\$script:MaxCarryDays\s*=\s*(\d+)\s*$", line)
            if m:
                return int(m.group(1))
    raise RuntimeError(f"cannot find $script:MaxCarryDays in {policy}; "
                       "row_age has no window to enforce")


def check_row_age(db, max_age_days: int | None = None, today: str | None = None,
                  **_) -> tuple[bool, dict]:
    """No cell may be priced by an observation older than the capture policy's
    everyday-price window (MaxCarryDays, the 90-day quarter). Ad freshness is
    check_ad_window's job; this one is about everyday rows outliving the
    rotation that would have re-verified them.

    PHASE B: reads cell_state.everyday_asof — the freshness stamp on the ANSWER —
    instead of scanning every surviving observation. Same question, one row per
    cell instead of forty, and it is the field the capture worklist will key off.
    """
    if max_age_days is None:
        max_age_days = _policy_max_carry_days()
    today_d = _parse(today) or _date.today()
    cutoff = today_d - timedelta(days=max_age_days)
    try:
        rows = db.conn.execute(
            """SELECT commodity_id, store_id, everyday_asof AS observed_at
               FROM cell_state WHERE everyday_asof IS NOT NULL""").fetchall()
        if not rows:
            raise ValueError("empty cell_state")
    except Exception:                                        # noqa: BLE001
        rows = db.conn.execute(
            "SELECT commodity_id, store_id, observed_at FROM v_current_cell").fetchall()
    old = []
    for r in rows:
        d = _parse(r["observed_at"])
        if d and d < cutoff:
            old.append({"commodity": r["commodity_id"], "store": r["store_id"],
                        "observed_at": r["observed_at"],
                        "age_days": (today_d - d).days})
    old.sort(key=lambda x: -x["age_days"])
    return (not old), {"cells": len(rows), "stale": len(old), "worst": old[:10],
                       "max_age_days": max_age_days}


def check_provenance_complete(db, **_) -> tuple[bool, dict]:
    """Every observation must trace to a provenance row.

    "Provenance is non-negotiable" has to be enforced somewhere or it is a
    slogan. This is where.
    """
    orphan = db.conn.execute(
        """SELECT COUNT(*) FROM price_observations p
           LEFT JOIN provenance v ON v.id = p.provenance_id
           WHERE v.id IS NULL""").fetchone()[0]
    return (orphan == 0), {"orphan_observations": orphan}


def check_ad_reversion_owed(db, max_days_owed: int = 3, today: str | None = None,
                            **_) -> tuple[bool, dict]:
    """PHASE D: every closed ad window owes a price check, and this counts them.

    Brad's rule, made a gate: when an ad stops, somebody must confirm the shelf
    went back to the everyday price. Until `reverted_checked_at` is stamped the
    cell is carrying an ASSUMPTION about what a shopper pays — and this estate's
    incident list is a list of assumptions that turned out to be stale prices
    (the V4 blueberries served wrong for two days at HTTP 200).

    Grace of a few days is deliberate: the capture lanes are paced per store by
    capture-policy, so a cell whose ad ended yesterday has not had its turn yet.
    Past the grace the run goes red, and pipeline/state.py --ad-reversions emits
    the worklist that clears it.
    """
    today_d = _parse(today) or _date.today()
    cutoff = (today_d - timedelta(days=max_days_owed)).isoformat()
    try:
        rows = db.conn.execute(
            """SELECT commodity_id, store_id, ad_to, ad_product
               FROM cell_state
               WHERE ad_to IS NOT NULL AND ad_to < ?
                 AND reverted_checked_at IS NULL
               ORDER BY ad_to""", (cutoff,)).fetchall()
    except Exception:                                        # noqa: BLE001
        return True, {"skipped": "cell_state not built yet"}
    owed = [dict(r) for r in rows]
    return (not owed), {"owed": len(owed), "grace_days": max_days_owed,
                        "worst": owed[:10]}


CHECKS = {
    "omaha_identity": check_omaha_identity,
    "ad_window": check_ad_window,
    "known_wrong_not_priced": check_known_wrong_not_priced,
    "no_unresolved_pricing": check_no_unresolved_pricing,
    "row_age": check_row_age,
    "ad_reversion_owed": check_ad_reversion_owed,
    "provenance_complete": check_provenance_complete,
}


def run_checks(db, names: list[str] | None = None, **kw) -> dict:
    names = names or list(CHECKS)
    results, all_ok = {}, True
    for name in names:
        fn = CHECKS.get(name)
        if not fn:
            results[name] = {"ok": False, "detail": {"error": "unknown check"}}
            all_ok = False
            continue
        try:
            ok, detail = fn(db, **kw)
        except Exception as e:                      # noqa: BLE001
            ok, detail = False, {"error": f"{type(e).__name__}: {e}"}
        results[name] = {"ok": ok, "detail": detail}
        all_ok = all_ok and ok
    return {"ok": all_ok, "checks": results}


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="Run graph gate checks")
    ap.add_argument("--check", action="append", help="run only this check (repeatable)")
    ap.add_argument("--today", default=None)
    # Default None = read MaxCarryDays from capture-policy.ps1. A literal here
    # would be a THIRD private copy of the everyday-price window — the CLI
    # shipped with 21 and silently overrode the policy-reading check.
    ap.add_argument("--max-age-days", type=int, default=None)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    with open_db() as db:
        res = run_checks(db, args.check, today=args.today, max_age_days=args.max_age_days)

    if args.json:
        print(json.dumps(res, indent=2, default=str))
        return 0 if res["ok"] else 1

    print("=== graph gate checks ===")
    for name, r in res["checks"].items():
        print(f"  {'PASS' if r['ok'] else 'FAIL'}  {name}")
        if not r["ok"]:
            print(f"        {json.dumps(r['detail'], default=str)[:300]}")
    print(f"\n  OVERALL: {'PASS' if res['ok'] else 'FAIL'}")
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
