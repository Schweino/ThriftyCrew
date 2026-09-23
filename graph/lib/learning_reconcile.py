"""learning_reconcile.py - a learning verdict committed from ANY checkout survives the next export.

WHY THIS EXISTS (2026-09-23, design/PLAN-graph-learning-reconcile-2026-09-23.md). `GraphDB.export_learning()` writes
the learning tables from the DATABASE over the tracked JSON after every write, and `import_learning()` restores tracked
JSON only into a FRESH database. Nothing moved a tracked row into an existing one, so a verdict ingested in a worktree
and committed was reverted by the main checkout's next export: measured on a stand-in, 69 of 69 of Brad's 2026-09-12
rulings went back to `proposed` and 69 of 69 patch rows were dropped, with every row count matching afterwards.

THE RULE: A JOIN ON DECISION EVIDENCE, NEVER AN OVERWRITE. `reconcile()` runs inside `export_learning()` before its first
write. The database takes from the tracked JSON only what the JSON can PROVE is further along, and keeps the rest:

  learning_proposals  a row the DB lacks is inserted. A different status is adopted only when the tracked side's
                      EVIDENCE for that proposal strictly contains the DB's. Evidence is the proposal's approved_patches
                      rows: each row's id, its shadow_verdict when not 'not_run', and its applied_at when set.
  approved_patches    union by id; a row the DB lacks is inserted AFTER its proposal (the pointed-to object first); a
                      row both hold takes the tracked apply fields only when the tracked row moved forward and the DB's
                      did not. The id hashes (proposal, verdict, payload), so those are fixed by the key.
  eval_runs           union by id; rows are immutable, so only a missing row is inserted.
  cell_state, question_verdicts   NOT reconciled: state.py re-derives both with DELETE then INSERT on every import, so a
                      tracked row from another checkout is another derivation, not a decision. The DB wins, as before.

Nothing is ever deleted from the DB. A stale JSON's evidence is a subset of the DB's, so a JSON that went BACKWARDS (a
`rebase -X theirs` hunk, a checkout of an older version) changes nothing - which is why this is a join and not a
three-way merge, which would read a backwards JSON as "tracked changed" and revert the DB. EQUAL evidence with a
different status is UNDECIDED and the DB keeps its own: three stage2_review transitions leave no evidence (the two
--apply holds and a same-verdict re-ingest), and those cannot be ordered without a clock. An ARRIVED patch row whose
proposal is still 'proposed' on both sides sets the status from its verdict, because no writer leaves a reviewed,
un-requeued, unapplied patch beside a 'proposed' status. An UNREADABLE tracked file raises before anything is written:
exporting over conflict markers would resolve the merge for the DB, silently.

A NEW WRITER OF THESE TABLES MUST LEAVE EVIDENCE. A status move with no patch fact beside it is invisible here and will
be counted undecided in every other checkout. Say which in the writer, and add a fixture to graph/lib/graphdb_selftest.py.

SCOPE OF A CLEAN REPORT: all-zero counts mean the tracked files held nothing the database lacked by these rules. They do
not mean the two agree: a row only the DB holds, and a status the DB decided later, are both silent by design.
"""
from __future__ import annotations

import io
import json
import os
import sqlite3

RECONCILED = ("learning_proposals", "approved_patches", "eval_runs")
VERDICT_STATUS = {"accept": "accepted", "reject": "rejected", "modify": "modified",
                  "defer": "deferred", "hold_for_human": "held_for_human"}
PATCH_FIXED = ("proposal_id", "verdict", "payload_json")
PATCH_APPLY = ("shadow_verdict", "shadow_before_json", "shadow_after_json", "applied_at", "applied_by")
ID_CAP = 200          # ids listed per kind in the report; the counts are never capped


class LearningMirrorUnreadable(ValueError):
    """A tracked learning file exists and is not a JSON list. Nothing was written."""


def _read(path: str) -> list | None:
    """The tracked rows, or None when the file is absent (nothing to adopt, not an error)."""
    if not os.path.exists(path):
        return None
    try:
        with io.open(path, encoding="utf-8-sig") as fh:
            rows = json.load(fh)
    except (OSError, ValueError) as e:
        raise LearningMirrorUnreadable(
            f"{path} is not readable JSON ({type(e).__name__}: {str(e)[:120]}). Refusing to export over it: a tracked "
            f"learning file with merge conflict markers holds both sides, and an export would resolve it for this "
            f"database. Resolve the file (it is tracked, so git holds both versions), then re-run.") from e
    if not isinstance(rows, list):
        raise LearningMirrorUnreadable(f"{path} holds a {type(rows).__name__}, not a list of rows. Refusing to export.")
    return rows


def _patch_facts(p: dict) -> set:
    facts = {("patch", p["id"])}
    if p.get("shadow_verdict") not in (None, "not_run"):
        facts.add(("shadow", p["id"], p["shadow_verdict"]))
    if p.get("applied_at"):
        facts.add(("applied", p["id"]))
    return facts


def _evidence(patches: dict) -> dict:
    ev: dict = {}
    for p in patches.values():
        ev.setdefault(p.get("proposal_id"), set()).update(_patch_facts(p))
    return ev


def _keyed(rows: list | None, key: str, report: dict) -> dict:
    out = {}
    for r in rows or []:
        if isinstance(r, dict) and r.get(key):
            out[r[key]] = r
        else:
            report["refused"] += 1
    return out


def _insert(conn, table: str, cols: list, row: dict) -> bool:
    use = [c for c in cols if c in row]
    try:
        conn.execute(f"INSERT INTO {table} ({', '.join(use)}) VALUES ({', '.join('?' * len(use))})",
                     [row[c] for c in use])
        return True
    except sqlite3.IntegrityError:
        return False


def _note(report: dict, kind: str, rid: str) -> None:
    ids = report["ids"].setdefault(kind, [])
    if len(ids) < ID_CAP:
        ids.append(rid)


def empty_report() -> dict:
    return {"read": {}, "proposals_inserted": 0, "patches_inserted": 0, "eval_runs_inserted": 0,
            "statuses_adopted": 0, "patches_advanced": 0, "statuses_from_arrived_patch": 0,
            "kept_db_newer": 0, "undecided": 0, "conflicts": 0, "refused": 0, "ids": {}}


def changed(report: dict) -> int:
    return sum(report[k] for k in ("proposals_inserted", "patches_inserted", "eval_runs_inserted",
                                   "statuses_adopted", "patches_advanced", "statuses_from_arrived_patch"))


def noteworthy(report: dict) -> int:
    return changed(report) + report["undecided"] + report["conflicts"] + report["refused"]


def reconcile(conn: sqlite3.Connection, paths: dict) -> dict:
    """Join the tracked rows at `paths` (table -> JSON path) into the database. Returns the report.

    Every file is read before anything is written, so an unreadable one leaves the database untouched."""
    report = empty_report()
    tracked = {}
    for t in RECONCILED:
        if t in paths:
            tracked[t] = _read(paths[t])
            report["read"][t] = None if tracked[t] is None else len(tracked[t])
    if all(v is None for v in tracked.values()):
        return report

    def cols(table):
        return [r[1] for r in conn.execute(f"PRAGMA table_info({table})")]

    def db_rows(table):
        c = conn.execute(f"SELECT * FROM {table}")
        names = [d[0] for d in c.description]
        return {r[0]: dict(zip(names, r)) for r in c.fetchall()}

    tr_props = _keyed(tracked.get("learning_proposals"), "id", report)
    tr_patch = _keyed(tracked.get("approved_patches"), "id", report)
    tr_eval = _keyed(tracked.get("eval_runs"), "id", report)
    db_props, db_patch, db_eval = db_rows("learning_proposals"), db_rows("approved_patches"), db_rows("eval_runs")
    ev_db, ev_tr = _evidence(db_patch), _evidence(tr_patch)       # both read BEFORE the merge moves anything

    conn.execute("SAVEPOINT learning_reconcile")
    try:
        # 1. proposals the DB lacks - the pointed-to object, before any patch that names it
        pcols = cols("learning_proposals")
        for pid, row in tr_props.items():
            if pid not in db_props:
                if _insert(conn, "learning_proposals", pcols, row):
                    report["proposals_inserted"] += 1
                    _note(report, "proposal_inserted", pid)
                else:
                    report["refused"] += 1
                    _note(report, "refused", pid)

        # 2. patch rows the DB lacks; 3. patch rows the tracked side moved forward
        acols = cols("approved_patches")
        arrived: dict = {}
        for apid, row in tr_patch.items():
            mine = db_patch.get(apid)
            if mine is None:
                if _insert(conn, "approved_patches", acols, row):
                    report["patches_inserted"] += 1
                    _note(report, "patch_inserted", apid)
                    arrived.setdefault(row.get("proposal_id"), []).append(row)
                else:
                    report["refused"] += 1                     # an orphan: its proposal is on neither side
                    _note(report, "refused", apid)
                continue
            ft, fd = _patch_facts(row), _patch_facts(mine)
            if ft == fd or fd > ft:
                continue                                       # same, or the DB is further along: keep it
            if ft > fd and all(row.get(k) == mine.get(k) for k in PATCH_FIXED):
                conn.execute(f"UPDATE approved_patches SET {', '.join(k + '=?' for k in PATCH_APPLY)} WHERE id=?",
                             [row.get(k) for k in PATCH_APPLY] + [apid])
                report["patches_advanced"] += 1
                _note(report, "patch_advanced", apid)
            else:
                report["conflicts"] += 1
                _note(report, "conflict", apid)

        # 4. a status both hold differently: adopted only on strictly larger evidence
        for pid, row in tr_props.items():
            mine = db_props.get(pid)
            if mine is None or row.get("status") == mine.get("status"):
                continue
            et, ed = ev_tr.get(pid, set()), ev_db.get(pid, set())
            if et > ed:
                try:
                    conn.execute("UPDATE learning_proposals SET status=? WHERE id=?", (row.get("status"), pid))
                    report["statuses_adopted"] += 1
                    _note(report, "status_adopted", pid)
                except sqlite3.IntegrityError:                 # a status outside the CHECK vocabulary
                    report["refused"] += 1
                    _note(report, "refused", pid)
            elif et == ed:
                report["undecided"] += 1
                _note(report, "undecided", pid)
            elif ed > et:
                report["kept_db_newer"] += 1
            else:
                report["conflicts"] += 1
                _note(report, "conflict", pid)

        # 5. an arrived verdict carries its status
        for pid, rows in arrived.items():
            now = conn.execute("SELECT status FROM learning_proposals WHERE id=?", (pid,)).fetchone()
            if not now or now[0] != "proposed":
                continue
            if conn.execute("SELECT 1 FROM approved_patches WHERE proposal_id=? AND shadow_verdict='requeued'",
                            (pid,)).fetchone():
                continue
            live = [r for r in rows if r.get("shadow_verdict") in (None, "not_run") and not r.get("applied_at")
                    and r.get("verdict") in VERDICT_STATUS]
            if live:
                newest = max(live, key=lambda r: str(r.get("reviewed_at") or ""))
                conn.execute("UPDATE learning_proposals SET status=? WHERE id=?",
                             (VERDICT_STATUS[newest["verdict"]], pid))
                report["statuses_from_arrived_patch"] += 1
                _note(report, "status_from_arrived_patch", pid)

        # 6. eval runs the DB lacks
        ecols = cols("eval_runs")
        for eid, row in tr_eval.items():
            if eid not in db_eval:
                if _insert(conn, "eval_runs", ecols, row):
                    report["eval_runs_inserted"] += 1
                    _note(report, "eval_run_inserted", eid)
                else:
                    report["refused"] += 1
                    _note(report, "refused", eid)
    except BaseException:
        conn.execute("ROLLBACK TO learning_reconcile")
        conn.execute("RELEASE learning_reconcile")
        raise
    conn.execute("RELEASE learning_reconcile")
    if changed(report) and conn.in_transaction:
        conn.commit()
    return report
