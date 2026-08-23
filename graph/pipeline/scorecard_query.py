"""Read-only scorecard query — the graph half of graph/pipeline/scorecard.ps1.

    python graph/pipeline/scorecard_query.py --since 2026-08-16 --until 2026-08-23
    python graph/pipeline/scorecard_query.py --selftest

Emits ONE JSON object on stdout. The PowerShell wrapper adds the Claude-token
attribution (which lives in transcripts, not in the graph) and the formatting.
Split this way because the token side is a file-scanning job PowerShell already
does for the recipe hunter (meal-prep/pipeline/lane-tokens.ps1) and the graph
side is SQL.

STRICTLY READ-ONLY. Opens the database with SQLite's `mode=ro` URI so a bug
here cannot write, and so it can run while another session holds the file. It
answers plan section 9's standing questions:

    questions asked                        resolve runs, from decision_log
    settled by the deterministic layers    layers 1-4 (see resolve.py)
    settled by layer 5 (the local model)   llm_* verdicts
    sent to Claude                         escalations the reviewer picked up
    confirmed / rejected / deferred        what Claude ruled
    tokens per Claude ruling               added by the .ps1 wrapper
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DB = os.path.join(HERE, "..", "sqlite", "graph.db")

# Which layer settled a row. Layers 1-4 are the deterministic guardrails; the
# llm_* statuses are the only ones a model produced (resolve.py's layer list).
DETERMINISTIC_STATUSES = ("include_hit", "excluded", "category_excluded",
                          "known_wrong", "no_include_hit", "banked")
LAYER5_STATUSES = ("llm_rejected", "llm_match_unverified", "llm_confirmed", "escalated")

# The review lane's verdicts, as decision_log records them (review_escalations.py).
CLAUDE_DECISIONS = ("confirmed", "rejected", "deferred")


def classify_status(status: str) -> str:
    """'deterministic' | 'layer5' | 'other'. One place, so the .ps1 self-test and
    the report cannot drift apart on what counts as a model decision."""
    s = (status or "").strip()
    if s in LAYER5_STATUSES:
        return "layer5"
    if s in DETERMINISTIC_STATUSES:
        return "deterministic"
    return "other"


def open_ro(path: str) -> sqlite3.Connection:
    uri = "file:" + os.path.abspath(path).replace("\\", "/").replace("?", "%3f") + "?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def collect(conn: sqlite3.Connection, since: str, until: str) -> dict:
    win = (since, until)

    runs = []
    questions = model_calls = 0
    by_status: dict[str, int] = {}
    for r in conn.execute(
            """SELECT timestamp, detail_json FROM decision_log
               WHERE type='resolve' AND decision='resolve_pending'
                 AND timestamp >= ? AND timestamp < ? ORDER BY timestamp""", win):
        d = json.loads(r["detail_json"] or "{}")
        questions += int(d.get("questions") or 0)
        model_calls += int(d.get("model_calls") or 0)
        for k, v in (d.get("by_status") or {}).items():
            by_status[k] = by_status.get(k, 0) + int(v)
        runs.append({"at": r["timestamp"], "questions": d.get("questions"),
                     "model_calls": d.get("model_calls"),
                     "prompt_version": d.get("prompt_version"),
                     "escalations": d.get("escalations")})

    settled = {"deterministic": 0, "layer5": 0, "other": 0}
    for status, n in by_status.items():
        settled[classify_status(status)] += n

    # Layer 5's own outcomes, per judgment rather than per row.
    layer5 = {}
    for r in conn.execute(
            """SELECT decision, COUNT(*) n FROM decision_log
               WHERE type='resolve' AND model IS NOT NULL
                 AND timestamp >= ? AND timestamp < ? GROUP BY decision""", win):
        layer5[r["decision"]] = r["n"]

    # What Claude was asked, and what it ruled. One row per observation the
    # reviewer touched; `rulings` counts the questions, which is the denominator
    # the tokens-per-ruling figure needs.
    claude: dict[str, int] = {}
    reviewers: dict[str, int] = {}
    for r in conn.execute(
            """SELECT decision, model, COUNT(*) n FROM decision_log
               WHERE type='escalate' AND decision IN ('confirmed','rejected','deferred')
                 AND timestamp >= ? AND timestamp < ? GROUP BY decision, model""", win):
        claude[r["decision"]] = claude.get(r["decision"], 0) + r["n"]
        reviewers[r["model"] or "unknown"] = reviewers.get(r["model"] or "unknown", 0) + r["n"]
    rulings = sum(claude.values())

    # The queue as it stands right now — not window-bounded, because a backlog
    # is a fact about today, not about the week.
    queue = {r["status"]: r["n"] for r in conn.execute(
        """SELECT match_status AS status, COUNT(*) n FROM price_observations
           WHERE match_status IN ('llm_match_unverified','escalated') GROUP BY 1""")}

    tiers: dict[str, int] = {}
    try:
        sys.path.insert(0, os.path.join(HERE, "..", "lib"))
        from authority import authority_tier                    # noqa: PLC0415
        for r in conn.execute(
                """SELECT status, reason, decided_by FROM question_verdicts
                   WHERE status IN ('llm_rejected','known_wrong','llm_confirmed')"""):
            t = authority_tier(r["status"], r["reason"], r["decided_by"])
            tiers[t] = tiers.get(t, 0) + 1
    except Exception as e:                                       # noqa: BLE001
        tiers = {"error": str(e)[:120]}

    learning = {r["status"]: r["n"] for r in conn.execute(
        "SELECT status, COUNT(*) n FROM learning_proposals GROUP BY 1")}

    return {"since": since, "until": until,
            "resolve_runs": runs,
            "questions_asked": questions,
            "model_calls": model_calls,
            "settled_by": settled,
            "by_status": by_status,
            "layer5_outcomes": layer5,
            "claude_rulings": claude,
            "claude_rulings_total": rulings,
            "reviewers": reviewers,
            "queue_now": queue,
            "prior_authority_tiers": tiers,
            "learning_proposals": learning}


def _selftest() -> int:
    bad = 0

    def T(name, ok, got=""):
        nonlocal bad
        if ok:
            print(f"  ok    {name}")
        else:
            print(f"  X     {name}   got: {got}")
            bad += 1

    T("an include hit is a deterministic settlement",
      classify_status("include_hit") == "deterministic")
    T("MUST FIRE  a local-model rejection is NOT counted as deterministic",
      classify_status("llm_rejected") == "layer5", classify_status("llm_rejected"))
    T("an escalation is layer 5's outcome, not a deterministic one",
      classify_status("escalated") == "layer5")
    T("MUST FIRE  an unknown status is 'other', never silently deterministic",
      classify_status("brand_new_status") == "other", classify_status("brand_new_status"))

    db = os.environ.get("SCORECARD_DB", DEFAULT_DB)
    if os.path.exists(db):
        conn = open_ro(db)
        try:
            conn.execute("CREATE TABLE _scorecard_probe (x)")
            T("MUST FIRE  the connection is READ-ONLY", False, "a write succeeded")
        except sqlite3.OperationalError:
            T("MUST FIRE  the connection is READ-ONLY", True)
        out = collect(conn, "1970-01-01", "2999-01-01")
        T("a full-history collect returns every section",
          all(k in out for k in ("questions_asked", "claude_rulings", "settled_by")))
        T("settled_by totals equal the status tally",
          sum(out["settled_by"].values()) == sum(out["by_status"].values()),
          f"{out['settled_by']} vs {sum(out['by_status'].values())}")
        conn.close()
    else:
        T(f"graph db present at {db} (skipped, not an error in a fresh worktree)", True)

    if bad:
        print(f"scorecard_query SELF-TEST FAIL ({bad})")
        return 2
    print("scorecard_query SELF-TEST PASS")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", default="1970-01-01")
    ap.add_argument("--until", default="2999-01-01")
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return _selftest()
    if not os.path.exists(args.db):
        print(json.dumps({"error": f"no graph db at {args.db}"}))
        return 3
    conn = open_ro(args.db)
    try:
        print(json.dumps(collect(conn, args.since, args.until), indent=2, default=str))
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
