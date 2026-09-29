"""W0 of design/PLAN-eval-heldout-and-hillclimb-2026-09-29.md: how circular is the learning loop's evidence?

    C:/Codex/Python312/python.exe graph/eval/audit_gold_circularity.py [--db <graph.db>] [--json <out>]
    C:/Codex/Python312/python.exe graph/eval/audit_gold_circularity.py --selftest

Read-only. Prints, each with its denominator:
  a. gold rows by source, and the failure-derived share (known-wrong + escalation-review over total).
  b. applied learning patches whose shadow evidence is ONLY their own source case. approved_patches has
     no field naming the gold case a patch was derived from, so every patch is classified BLIND
     ("provenance absent") unless a `derived_from` list is present. A BLIND is counted, never zero.
     Beside it, a PROXY that needs no provenance: how many gold cases each applied alias actually moves
     (its regex matches the case's product, for its own target). A patch that moves none passed the
     shadow gate on a delta of 0.0 with nothing watching it.
  c. gold rows and proposals that came from Stage 1 `add_gold`.
  d. an input fingerprint: sha256 of every file read, the git blob where the file is tracked, and the
     index's Commodity node count.
  e. an index with no Commodity nodes (or no index) is BLIND, exit 3 (`_index_blind`, priors_ablation.py).
  f. the immediate lane: resolutions in meal-prep/db/ingredient-resolutions.json against the reversals
     recorded in meal-prep/db/ingredient-events.jsonl. There is no `rejects_mapping` event kind (the
     daemon acts on that flag and records `invalidate` / `qa_mapper_fail`), so those two are counted.

SCOPE OF A CLEAN REPORT: there is no clean report. This is a measurement, not a detector: every figure is
a count over what the files hold. Part b is UNSOUND by construction until patches record `derived_from`;
the proxy is COMPLETE for the question it asks (the match IS the move) and says nothing about why.

Exit: 0 measured, 3 could not evaluate (BLIND index), 1 the self-test failed.
Last line: GOLD-CIRCULARITY-COMPLETE.
"""

# gate-inputs: graph\eval\audit_gold_circularity.py

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
GOLD = os.path.join(REPO, "graph", "gold", "gold.jsonl")
PATCHES = os.path.join(REPO, "graph", "learning", "approved-patches.json")
PROPOSALS = os.path.join(REPO, "graph", "learning", "proposals.json")
RESOLUTIONS = os.path.join(REPO, "meal-prep", "db", "ingredient-resolutions.json")
EVENTS = os.path.join(REPO, "meal-prep", "db", "ingredient-events.jsonl")
DEFAULT_DB = os.path.join(REPO, "graph", "sqlite", "graph.db")

FAILURE_SOURCES = ("known-wrong.json", "escalation-review")
REVERSAL_KINDS = ("invalidate", "qa_mapper_fail")


def sha256(path: str) -> str:
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def blob(path: str) -> str:
    """The git blob of a tracked file as it sits in HEAD, or 'untracked'."""
    rel = os.path.relpath(path, REPO).replace("\\", "/")
    p = subprocess.run(["git", "-C", REPO, "rev-parse", f"HEAD:{rel}"], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else "untracked"


def load_json(path: str):
    with open(path, encoding="utf-8-sig") as fh:
        return json.load(fh)


def load_jsonl(path: str) -> list[dict]:
    with open(path, encoding="utf-8-sig") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def index_blind(db_path: str) -> tuple[str, str, int] | tuple[None, None, int]:
    """(code, why, 0) when the index cannot be read for Commodity nodes, else (None, None, count)."""
    if not os.path.exists(db_path) or os.path.getsize(db_path) == 0:
        return "no-db", f"no graph index at {db_path} (it is gitignored; a worktree has none)", 0
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        n = con.execute("SELECT COUNT(*) FROM nodes WHERE type='Commodity'").fetchone()[0]
        if n:
            return None, None, n
        total = con.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]
        return ("no-commodity-nodes",
                f"the index holds no Commodity nodes ({total} node(s) of any type) - a learning-only rebuild", 0)
    finally:
        con.close()


def target_of(commodity_node: str) -> str:
    """The bare id a proposal targets, from a namespaced node (commodity:staple:<id> or commodity:recipe:<id>)."""
    return (commodity_node or "").split(":")[-1]


def classify_patch(patch: dict, gold: list[dict]) -> str:
    """CIRCULAR, INDEPENDENT, UNCOVERED or BLIND for one patch.

    Needs patch['derived_from'], a list of gold ids. Absent means BLIND: the question cannot be asked,
    which is not the same as 'not circular'.
    """
    if "derived_from" not in patch:
        return "BLIND"
    own = set(patch["derived_from"] or [])
    covering = {g["id"] for g in gold if target_of(g.get("commodity_node")) == patch["target_id"]}
    if not covering:
        return "UNCOVERED"
    return "CIRCULAR" if covering <= own else "INDEPENDENT"


def cases_moved(pattern: str, target: str, gold: list[dict]) -> int | None:
    """How many gold cases for `target` an alias pattern matches; None when the pattern will not compile."""
    try:
        rx = re.compile(pattern, re.IGNORECASE)
    except re.error:
        return None
    return sum(1 for g in gold
               if target_of(g.get("commodity_node")) == target and rx.search(g.get("product") or ""))


def pct(n: int, d: int) -> str:
    return f"{n} of {d} ({(100.0 * n / d) if d else 0:.1f}%)"


def measure(db_path: str) -> tuple[dict, int]:
    code, why, n_commodity = index_blind(db_path)
    out: dict = {"db": db_path}
    if code:
        out["blind"] = {"code": code, "why": why}
        return out, 3
    out["commodity_nodes"] = n_commodity

    gold = load_jsonl(GOLD)
    by_source = collections.Counter(g.get("source") for g in gold)
    failure = sum(by_source[s] for s in FAILURE_SOURCES)
    out["a"] = {"total": len(gold), "by_source": dict(by_source), "failure_derived": failure}

    patches = load_json(PATCHES)
    proposals = {p["id"]: p for p in load_json(PROPOSALS)}
    applied = [p for p in patches if p.get("applied_at")]
    classes = collections.Counter()
    moved_hist = collections.Counter()
    zero_moved = []
    for p in applied:
        prop = proposals.get(p["proposal_id"], {})
        rec = dict(p, target_id=prop.get("target_id"))
        classes[classify_patch(rec, gold)] += 1
        if prop.get("kind") != "add_alias":
            moved_hist["not-an-alias"] += 1
            continue
        pattern = (json.loads(p.get("payload_json") or "{}").get("payload")) or ""
        n = cases_moved(pattern, prop.get("target_id"), gold)
        key = "uncompilable" if n is None else ("0" if n == 0 else "1" if n == 1 else "2+")
        moved_hist[key] += 1
        if n == 0:
            zero_moved.append(prop.get("target_id"))
    out["b"] = {"applied": len(applied), "approved_rows": len(patches), "classes": dict(classes),
                "provenance_field_present": any("derived_from" in p for p in patches),
                "proxy_cases_moved": dict(moved_hist), "zero_moved_targets": sorted(set(zero_moved))}

    kinds = collections.Counter(p.get("kind") for p in proposals.values())
    out["c"] = {"proposals": len(proposals), "add_gold_proposals": kinds.get("add_gold", 0),
                "gold_rows_from_learner": sum(1 for g in gold if "learn" in (g.get("source") or "").lower())}

    res = load_json(RESOLUTIONS)
    ev = load_jsonl(EVENTS)
    kinds_ev = collections.Counter(e.get("kind") for e in ev)
    rulings = [e for e in ev if e.get("kind") == "ruling"]
    reversals = [e for e in ev if e.get("kind") in REVERSAL_KINDS]
    dropped = 0
    for e in reversals:
        m = re.search(r"(\d+) cached resolution", e.get("evidence") or "")
        dropped += int(m.group(1)) if m else 0
    span = lambda xs: [min(e["at"] for e in xs), max(e["at"] for e in xs)] if xs else None  # noqa: E731
    out["f"] = {"resolutions": len(res.get("resolutions") or []), "events": len(ev),
                "events_by_kind": dict(kinds_ev), "rulings": len(rulings), "rulings_span": span(rulings),
                "reversal_events": len(reversals), "reversal_span": span(reversals),
                "resolutions_dropped_by_reversals": dropped}

    out["d"] = {rel: {"sha256": sha256(p), "blob": blob(p)} for rel, p in
                (("gold", GOLD), ("patches", PATCHES), ("proposals", PROPOSALS),
                 ("resolutions", RESOLUTIONS), ("events", EVENTS))}
    out["d"]["harness_blob"] = blob(os.path.abspath(__file__))
    return out, 0


def report(out: dict) -> None:
    if "blind" in out:
        print(f"BLIND {out['blind']['code']}: {out['blind']['why']}")
        return
    a, b, c, f = out["a"], out["b"], out["c"], out["f"]
    print(f"index: {out['db']}  Commodity nodes={out['commodity_nodes']}")
    print(f"a. gold rows={a['total']}  by source={a['by_source']}")
    print(f"   failure-derived (known-wrong + escalation-review): {pct(a['failure_derived'], a['total'])}")
    print(f"b. applied patches: {b['applied']} of {b['approved_rows']} approved rows")
    print(f"   circularity classes: {b['classes']}  (derived_from recorded: {b['provenance_field_present']})")
    if b["classes"].get("BLIND"):
        print(f"   BLIND provenance absent, circularity not measurable for {b['classes']['BLIND']} patches")
    print(f"   proxy, gold cases each applied patch moves: {b['proxy_cases_moved']}")
    print(f"   targets of aliases that moved no gold case: {len(b['zero_moved_targets'])}")
    print(f"c. add_gold proposals: {c['add_gold_proposals']} of {c['proposals']}; "
          f"gold rows from the learner: {c['gold_rows_from_learner']} of {a['total']}")
    print(f"f. resolutions={f['resolutions']}  events={f['events']} {f['events_by_kind']}")
    print(f"   rulings in the event ledger: {f['rulings']} over {f['rulings_span']}")
    print(f"   reversal events ({'/'.join(REVERSAL_KINDS)}): {f['reversal_events']} over {f['reversal_span']}, "
          f"dropping {f['resolutions_dropped_by_reversals']} cached resolutions")
    for k, v in out["d"].items():
        print(f"d. {k}: {v}")


def self_test() -> int:
    gold = [{"id": "g1", "commodity_node": "commodity:staple:feta", "product": "Feta Crumbles 4oz"},
            {"id": "g2", "commodity_node": "commodity:staple:feta", "product": "Athenos Feta Block"},
            {"id": "g3", "commodity_node": "commodity:recipe:ricotta", "product": "Whole Milk Ricotta"}]
    cases = [
        ("MUST FIRE: a patch whose only gold coverage is its source case is CIRCULAR",
         classify_patch({"target_id": "ricotta", "derived_from": ["g3"]}, gold), "CIRCULAR"),
        ("MUST NOT FIRE: a patch with an independent case is INDEPENDENT",
         classify_patch({"target_id": "feta", "derived_from": ["g1"]}, gold), "INDEPENDENT"),
        ("CLEAN TWIN: a patch with no provenance is BLIND, not clean",
         classify_patch({"target_id": "feta"}, gold), "BLIND"),
        ("CLEAN TWIN: an empty derived_from on a covered target is INDEPENDENT, not BLIND",
         classify_patch({"target_id": "feta", "derived_from": []}, gold), "INDEPENDENT"),
        ("MUST FIRE: a target no gold case covers is UNCOVERED",
         classify_patch({"target_id": "tahini", "derived_from": []}, gold), "UNCOVERED"),
        ("MUST NOT FIRE: a bare id never matches another commodity's cases",
         cases_moved("feta", "ricotta", gold), 0),
        ("proxy counts the cases an alias moves on its own target", cases_moved(r"feta\s+\w+", "feta", gold), 2),
        ("proxy reports an uncompilable pattern as None, not 0", cases_moved("feta(", "feta", gold), None),
    ]
    fails = 0
    for name, got, want in cases:
        ok = got == want
        fails += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name} (got {got!r}, want {want!r})")
    with tempfile.TemporaryDirectory() as d:
        empty = os.path.join(d, "g.db")
        con = sqlite3.connect(empty)
        con.execute("CREATE TABLE nodes (id TEXT, type TEXT)")
        con.execute("INSERT INTO nodes VALUES ('learn:1', 'Proposal')")
        con.commit()
        con.close()
        for name, path, want in (("MUST FIRE: an index with no Commodity nodes is BLIND", empty, "no-commodity-nodes"),
                                 ("MUST FIRE: a missing index is BLIND", os.path.join(d, "none.db"), "no-db")):
            got = index_blind(path)[0]
            ok = got == want
            fails += not ok
            print(f"{'ok  ' if ok else 'FAIL'} {name} (got {got!r})")
        _, rc = measure(empty)
        fails += rc != 3
        print(f"{'ok  ' if rc == 3 else 'FAIL'} CLEAN TWIN: measure() on a BLIND index exits 3 (got {rc})")
    n = len(cases) + 3
    print(f"cases={n} failed={fails}")
    print(f"audit_gold_circularity self-test {'pass' if not fails else 'FAIL'}")
    return 0 if not fails else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--json", help="also write the result here")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        rc = self_test()
        print("GOLD-CIRCULARITY-COMPLETE selftest=" + ("pass" if rc == 0 else "fail"))
        return rc
    out, rc = measure(args.db)
    report(out)
    if args.json:
        with open(args.json, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(out, fh, indent=2, ensure_ascii=False)
    print(f"GOLD-CIRCULARITY-COMPLETE exit={rc}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
