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
    """
    rows = db.conn.execute(
        """SELECT commodity_id, store_id, product_name
           FROM price_observations
           WHERE match_status='known_wrong'
             AND id IN (SELECT id FROM v_current_cell)""").fetchall()
    viol = [dict(r) for r in rows]
    return (not viol), {"violations": viol, "n": len(viol)}


def check_no_unresolved_pricing(db, **_) -> tuple[bool, dict]:
    """Only adjudicated rows may price a cell.

    Guards against a regression where 'unadjudicated' leaks into the board view.
    """
    n = db.conn.execute(
        """SELECT COUNT(*) FROM price_observations
           WHERE match_status NOT IN ('include_hit','llm_confirmed')
             AND id IN (SELECT id FROM v_current_cell)""").fetchone()[0]
    return (n == 0), {"leaked_rows": n}


def check_row_age(db, max_age_days: int = 21, today: str | None = None, **_) -> tuple[bool, dict]:
    """No cell may be priced by an observation older than max_age_days."""
    today_d = _parse(today) or _date.today()
    cutoff = today_d - timedelta(days=max_age_days)
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


CHECKS = {
    "omaha_identity": check_omaha_identity,
    "ad_window": check_ad_window,
    "known_wrong_not_priced": check_known_wrong_not_priced,
    "no_unresolved_pricing": check_no_unresolved_pricing,
    "row_age": check_row_age,
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
    ap.add_argument("--max-age-days", type=int, default=21)
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
