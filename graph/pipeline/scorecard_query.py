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
    the nightly chain, and the helper      from the two run artefacts (phase 2)

The last row reads FILES, not the graph, because the two facts phase 2 added
are not decisions and do not belong in decision_log: whether the chain got the
card back (grocery/out/logs/graph-nightly-status.json) and how many contested
pairs the sidecar scored (sidecar/out/contested-scores.json). A missing file is
reported as BLIND, never as a zero -- "the chain did not run" and "the chain ran
and found nothing" are different weeks and a scorecard that conflates them is
worse than no scorecard.
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


def read_json(path: str):
    """A local artefact, or None. Never raises: every caller reports BLIND."""
    try:
        with open(path, encoding="utf-8-sig") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None


def local_lane(repo: str) -> dict:
    """Phase 2's two questions: did the chain hand the card back, and did the
    helper see the contested set before the model did?

    Both answers live in files a run wrote, so BLIND is a first-class outcome
    here. `card_free: false` is the only line in this whole report that means
    something is wrong RIGHT NOW rather than last week: it says llama-server is
    still holding the GPU, which makes tomorrow's 07:00 semantic sweep BLIND.
    """
    n = read_json(os.path.join(repo, "grocery", "out", "logs",
                               "graph-nightly-status.json"))
    c = read_json(os.path.join(repo, "sidecar", "out", "contested-scores.json"))
    out: dict = {}
    if n is None:
        out["nightly"] = {"state": "BLIND", "why": "no graph-nightly-status.json - the chain has never run here"}
    else:
        stages = {str(x.get("stage")): str(x.get("state")) for x in (n.get("stages") or [])}
        out["nightly"] = {
            "state": "ran",
            "at": n.get("started"),
            "elapsed_sec": n.get("elapsed_sec"),
            "contested": n.get("contested"),
            "card_free": n.get("card_free"),
            "free_vram_mib": n.get("free_vram_mib"),
            "stages": stages,
            "blind_stages": sorted(k for k, v in stages.items() if v in ("BLIND", "FAILED")),
        }
    if c is None:
        out["helper"] = {"state": "BLIND", "why": "no contested-scores.json - the sweep's contested lane has not run"}
    else:
        out["helper"] = {
            "state": "ran",
            "at": c.get("generated"),
            "model": c.get("rerank_model"),
            "offered": c.get("offered"),
            "scored": c.get("scored"),
            "no_definition": c.get("no_definition"),
            "vectors_warmed": c.get("vectors_warmed"),
            "elapsed_sec": c.get("elapsed_sec"),
            "defs": c.get("defs"),
            # WHICH MODEL HELD THE OPINION. Phase 3 trains a separate copy for
            # this lane; a report that cannot say whether the numbers came from
            # the pinned model or the candidate is a report nobody can act on.
            "helper_model": c.get("helper_model"),
            # Phase 2 CACHED and phase 3 FILTERS - but only where the filter is
            # actually switched on, which is resolve.py --helper-scores. A file
            # scored by the pinned model routes nothing, by refusal.
            "routes": ("reject-only, below the threshold in resolve.py --helper-threshold"
                       if c.get("helper_model") else "nothing - the pinned model's scores never filter"),
        }
    # -- what the filter actually did last night, from the graph rather than a file.
    # A status count, not a rate: "the helper rejected 0" and "the helper never ran"
    # are different weeks, and only the artefact above can tell them apart.
    out["helper_filter"] = {"state": "off" if not (out.get("helper") or {}).get("helper_model")
                            else "on"}
    return out


def helper_filter_counts(conn: sqlite3.Connection, since: str, until: str) -> dict:
    """How many rows the §2 step 2 filter rejected in the window. Zero is a real answer."""
    try:
        r = conn.execute(
            """SELECT COUNT(*) n FROM question_verdicts
               WHERE status = 'helper_rejected' AND decided_at BETWEEN ? AND ?""",
            (since, until + "T23:59:59")).fetchone()
        return {"rejected": r["n"] if r else 0}
    except sqlite3.Error as e:
        return {"rejected": None, "why": str(e)}


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
            "learning_proposals": learning,
            "local_lane": {**local_lane(os.path.join(HERE, "..", "..")),
                           "helper_filter_window": helper_filter_counts(conn, since, until)}}


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

    # MUST FIRE: a missing artefact is BLIND, not a zero. The whole point of the
    # phase-2 section is telling "the chain did not run" apart from "it ran clean".
    blind = local_lane(os.path.join(HERE, "no-such-repo-dir"))
    T("MUST FIRE  a missing nightly status reads BLIND, not 0",
      blind["nightly"]["state"] == "BLIND", blind["nightly"])
    T("MUST FIRE  a missing contested-scores reads BLIND, not 0",
      blind["helper"]["state"] == "BLIND", blind["helper"])
    T("read_json returns None rather than raising on a missing file",
      read_json(os.path.join(HERE, "nope.json")) is None)

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
