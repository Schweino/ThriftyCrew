"""Do planner statistics change a plan graph.db's nightly import actually runs? (backlog I212)

    python graph/bench/probe_statistics.py --out <dir>
    python graph/bench/probe_statistics.py --out <dir> --captures C:\\Codex\\ThriftyCrew\\grocery

READ-ONLY AGAINST THE LIVE FILE. The live graph.db is opened once, `mode=ro`, and copied with the
backup API into --out; every write below lands on a copy in that directory. Nothing is written to
the repo either: the decision-log JSONL mirror and the state export are stubbed for the run, and
capture files are only read.

What it does, in the order the I212 acceptance bar states it:
  1. SNAPSHOT  the live file -> today.db (backup API from a mode=ro connection).
  2. CAPTURE   replays `import_all.py --observations` on a copy of today.db with a trace callback,
               and backs the copy up to peak.db at the import's peak (after the importers, before
               reapply / resolve / state / prune), which is when the heavy statements run.
  3. ARMS      for each state (today, peak): NONE (no sqlite_stat1), OPT (`PRAGMA optimize`) and FULL
               (`PRAGMA analysis_limit=0; ANALYZE`). Supplementary, added after the bar: STALE, the
               peak copy carrying today's FULL statistics, which is what a nightly ANALYZE at the end
               of an import would hand the next import's peak.
  4. PLANS     EXPLAIN QUERY PLAN of every distinct traced statement shape in every arm. One JSONL
               row per shape per arm per state in <out>/rows.jsonl.
  5. TIMES     every shape whose plan differs from NONE's is run 5 times per arm, arms interleaved
               (a DML statement inside a savepoint that is rolled back).
  6. CLOSE     the cost of `PRAGMA optimize` at a close: 10 closes with current statistics, 10 with none.

The verdict is not printed here; the bar in design/BACKLOG-course-findings.md (I212) reads the rows.
The last line is PROBE-STATISTICS-COMPLETE with the counts, so a run that died halfway is visible.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GRAPH = os.path.abspath(os.path.join(HERE, ".."))
for sub in ("lib", "import", "pipeline", "learning", "eval"):
    sys.path.insert(0, os.path.join(GRAPH, sub))

LIVE = os.path.join(GRAPH, "sqlite", "graph.db")

_STR = re.compile(r"'(?:[^']|'')*'")
_NUM = re.compile(r"(?<![\w.])-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?(?![\w.])")
_LIST = re.compile(r"\?(?:\s*,\s*\?)+")
_WS = re.compile(r"\s+")


def shape_of(sql: str) -> str:
    s = _STR.sub("?", sql)
    s = _NUM.sub("?", s)
    s = re.sub(r"\bNULL\b", "?", s)
    s = _LIST.sub("?..", s)
    return _WS.sub(" ", s).strip()


def kind_of(shape: str) -> str:
    return shape.split(" ", 1)[0].upper() if shape else ""


def snapshot(src_path: str, dst_path: str) -> dict:
    st = os.stat(src_path)
    src = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)
    dst = sqlite3.connect(dst_path)
    try:
        src.backup(dst)
        has_stat = dst.execute(
            "SELECT COUNT(*) FROM sqlite_master WHERE name='sqlite_stat1'").fetchone()[0]
        pc = dst.execute("PRAGMA page_count").fetchone()[0]
    finally:
        dst.close()
        src.close()
    return {"source": src_path, "source_mtime": time.strftime("%Y-%m-%dT%H:%M:%S",
                                                               time.localtime(st.st_mtime)),
            "source_bytes": st.st_size, "page_count": pc, "had_sqlite_stat1": bool(has_stat)}


def capture(today: str, work: str, peak: str, captures: str | None) -> tuple[dict, dict]:
    """Replay the nightly import on `work` (a copy of today), tracing every statement."""
    import graphdb
    import importers
    shutil.copyfile(today, work)
    # Nothing leaves the copy: the JSONL mirror and the state export are the two repo writers.
    graphdb.GraphDB._append_jsonl = staticmethod(lambda run, record: None)
    if captures:
        importers.GROCERY = captures
    import state
    state.write_json = lambda path, obj: None

    shapes: dict[str, dict] = {}
    step = {"name": "open"}

    def trace(sql: str) -> None:
        sh = shape_of(sql)
        d = shapes.get(sh)
        if d is None:
            shapes[sh] = {"exemplar": sql, "count": 1, "steps": {step["name"]: 1}}
        else:
            d["count"] += 1
            d["steps"][step["name"]] = d["steps"].get(step["name"], 0) + 1

    db = graphdb.GraphDB(work)
    db.conn.set_trace_callback(trace)
    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    run = "run:probe-statistics:" + time.strftime("%Y%m%dT%H%M%S")
    timings: dict[str, float] = {}

    def do(name, fn):
        step["name"] = name
        t0 = time.time()
        out = fn()
        db.conn.commit()
        timings[name] = round(time.time() - t0, 2)
        return out

    for name, fn in importers.ALL_IMPORTERS:
        do(name, lambda fn=fn: fn(db, ts, run))
    do("observations", lambda: importers.import_observations(db, ts, run))
    for name, fn in importers.LANE_IMPORTERS:
        do(name, lambda fn=fn: fn(db, ts, run))

    db.conn.set_trace_callback(None)
    pk = sqlite3.connect(peak)
    db.conn.backup(pk)
    pk.close()
    db.conn.set_trace_callback(trace)

    from stage2_review import reapply_applied_patches
    from resolve import Resolver
    from state import (build_cell_state, build_question_verdicts, supersede_prune,
                       export_state, verify_against_matrix)
    do("reapply", lambda: reapply_applied_patches(db, ts, run))
    do("known_wrong", lambda: importers.retro_apply_known_wrong(db, ts, run))
    do("resolve", lambda: Resolver(db, use_llm=False).resolve_pending(run=run, ts=ts,
                                                                        allow_llm=False))
    do("cell_state", lambda: build_cell_state(db, ts))
    do("verdicts", lambda: build_question_verdicts(db, ts))
    do("verify", lambda: verify_against_matrix(db))
    prune = do("prune", lambda: supersede_prune(db, ts))
    do("export", lambda: export_state(db))
    step["name"] = "views"
    for v in [r[0] for r in db.conn.execute(
            "SELECT name FROM sqlite_master WHERE type='view' ORDER BY name")]:
        db.conn.execute(f'SELECT * FROM "{v}"').fetchall()
    db.conn.set_trace_callback(None)
    db.conn.close()
    timings["prune_result"] = prune
    return shapes, timings


def make_arm(base: str, dst: str, arm: str, stale_from: str | None = None) -> dict:
    shutil.copyfile(base, dst)
    c = sqlite3.connect(dst)
    t0 = time.perf_counter()
    info: dict = {"arm": arm}
    try:
        if arm == "OPT":
            c.execute("PRAGMA optimize").fetchall()
        elif arm in ("FULL", "STALE"):
            c.execute("PRAGMA analysis_limit=0")
            c.execute("ANALYZE").fetchall()
            if arm == "STALE":
                c.execute("ATTACH ? AS s", (stale_from,))
                c.execute("DELETE FROM main.sqlite_stat1")
                c.execute("INSERT INTO main.sqlite_stat1 SELECT * FROM s.sqlite_stat1")
                c.commit()
                c.execute("DETACH s")
        c.commit()
        info["seconds"] = round(time.perf_counter() - t0, 3)
        has = c.execute("SELECT COUNT(*) FROM sqlite_master WHERE name='sqlite_stat1'").fetchone()[0]
        info["stat1_rows"] = c.execute("SELECT COUNT(*) FROM sqlite_stat1").fetchone()[0] if has else 0
        if has:
            info["stat1"] = {f"{r[0]}.{r[1]}": r[2] for r in c.execute(
                "SELECT tbl, idx, stat FROM sqlite_stat1 ORDER BY tbl, idx")}
    finally:
        c.close()
    return info


def plan(conn: sqlite3.Connection, sql: str) -> str:
    try:
        rows = conn.execute("EXPLAIN QUERY PLAN " + sql).fetchall()
    except sqlite3.Error as e:
        return f"ERROR: {e}"
    depth: dict[int, int] = {0: -1}
    lines = []
    for rid, parent, _nu, detail in rows:
        depth[rid] = depth.get(parent, -1) + 1
        lines.append("  " * depth[rid] + detail)
    return "\n".join(lines)


def time_once(conn: sqlite3.Connection, sql: str) -> float:
    k = kind_of(sql.lstrip())
    t0 = time.perf_counter()
    if k in ("SELECT", "WITH", "VALUES"):
        conn.execute(sql).fetchall()
    else:
        conn.execute("SAVEPOINT probe")
        try:
            conn.execute(sql).fetchall()
        finally:
            conn.execute("ROLLBACK TO probe")
            conn.execute("RELEASE probe")
    return (time.perf_counter() - t0) * 1000


def optimize_close_cost(src: str, work: str, analysed: bool, n: int = 10) -> list[float]:
    out = []
    for _ in range(n):
        shutil.copyfile(src, work)
        c = sqlite3.connect(work)
        c.execute("SELECT COUNT(*) FROM nodes").fetchone()
        t0 = time.perf_counter()
        c.execute("PRAGMA optimize").fetchall()
        out.append(round((time.perf_counter() - t0) * 1000, 2))
        c.close()
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--source", default=LIVE)
    ap.add_argument("--captures", default=None,
                    help="grocery/ directory the importers read capture files from")
    ap.add_argument("--reps", type=int, default=5)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=False)
    p = lambda n: os.path.join(a.out, n)                     # noqa: E731

    meta = {"sqlite": sqlite3.sqlite_version, "python": sys.version.split()[0],
            "started": time.strftime("%Y-%m-%dT%H:%M:%S")}
    meta["snapshot"] = snapshot(a.source, p("today.db"))
    print("snapshot", meta["snapshot"], flush=True)
    t0 = time.time()
    shapes, timings = capture(p("today.db"), p("capture.db"), p("peak.db"), a.captures)
    meta["capture_seconds"] = round(time.time() - t0, 1)
    meta["step_seconds"] = timings
    os.remove(p("capture.db"))
    print(f"capture: {len(shapes)} shapes in {meta['capture_seconds']} s", flush=True)

    arms_info = {}
    arm_paths: dict[tuple[str, str], str] = {}
    for st in ("today", "peak"):
        for arm in ("NONE", "OPT", "FULL"):
            dst = p(f"{st}-{arm}.db")
            arms_info[f"{st}/{arm}"] = make_arm(p(f"{st}.db"), dst, arm)
            arm_paths[(st, arm)] = dst
    dst = p("peak-STALE.db")
    arms_info["peak/STALE"] = make_arm(p("peak.db"), dst, "STALE", stale_from=p("today-FULL.db"))
    arm_paths[("peak", "STALE")] = dst
    meta["arms"] = {k: {kk: vv for kk, vv in v.items() if kk != "stat1"} for k, v in arms_info.items()}
    with open(p("stat1.json"), "w", encoding="utf-8", newline="\n") as fh:
        json.dump({k: v.get("stat1", {}) for k, v in arms_info.items()}, fh, indent=1)

    items = sorted(shapes.items(), key=lambda kv: -kv[1]["count"])
    ids = {sh: f"s{i:03d}" for i, (sh, _) in enumerate(items)}
    conns = {k: sqlite3.connect(v, isolation_level=None) for k, v in arm_paths.items()}
    rows = []
    changed: list[tuple[str, str]] = []
    for st in ("today", "peak"):
        arms = ["NONE", "OPT", "FULL"] + (["STALE"] if st == "peak" else [])
        for sh, d in items:
            plans = {arm: plan(conns[(st, arm)], d["exemplar"]) for arm in arms}
            for arm in arms:
                ch = plans[arm] != plans["NONE"]
                rows.append({"state": st, "arm": arm, "shape_id": ids[sh], "kind": kind_of(sh),
                             "count": d["count"], "steps": d["steps"], "shape": sh[:600],
                             "plan": plans[arm], "changed": ch, "times_ms": None})
            if any(plans[arm] != plans["NONE"] for arm in arms):
                changed.append((st, sh))
    print(f"plans: {len(rows)} rows, {len(changed)} (state, shape) pairs with a plan change",
          flush=True)

    # Time every changed shape, arms interleaved per repetition.
    idx = {(r["state"], r["arm"], r["shape_id"]): r for r in rows}
    for st, sh in changed:
        arms = ["NONE", "OPT", "FULL"] + (["STALE"] if st == "peak" else [])
        ex = shapes[sh]["exemplar"]
        for arm in arms:
            idx[(st, arm, ids[sh])]["times_ms"] = []
        for _ in range(a.reps):
            for arm in arms:
                try:
                    ms = time_once(conns[(st, arm)], ex)
                except sqlite3.Error as e:
                    ms = f"ERROR: {e}"
                idx[(st, arm, ids[sh])]["times_ms"].append(
                    round(ms, 2) if isinstance(ms, float) else ms)
    for c in conns.values():
        c.close()

    with open(p("rows.jsonl"), "w", encoding="utf-8", newline="\n") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")

    meta["optimize_close_ms_current_stats"] = optimize_close_cost(
        p("today-FULL.db"), p("close-work.db"), True)
    meta["optimize_close_ms_no_stats"] = optimize_close_cost(
        p("today.db"), p("close-work.db"), False)
    for k in ("optimize_close_ms_current_stats", "optimize_close_ms_no_stats"):
        meta[k.replace("_ms_", "_median_ms_")] = statistics.median(meta[k])
    os.remove(p("close-work.db"))

    summary = []
    for st, sh in changed:
        arms = ["NONE", "OPT", "FULL"] + (["STALE"] if st == "peak" else [])
        med = {}
        for arm in arms:
            t = [x for x in idx[(st, arm, ids[sh])]["times_ms"] if isinstance(x, float)]
            med[arm] = statistics.median(t) if t else None
        verdicts = {}
        for arm in arms[1:]:
            if med[arm] is None or med["NONE"] is None:
                verdicts[arm] = "ERROR"
            elif idx[(st, arm, ids[sh])]["plan"] == idx[(st, "NONE", ids[sh])]["plan"]:
                verdicts[arm] = "same-plan"
            elif med[arm] <= 0.8 * med["NONE"]:
                verdicts[arm] = "HELP"
            elif med[arm] >= 1.2 * med["NONE"]:
                verdicts[arm] = "HARM"
            else:
                verdicts[arm] = "NEUTRAL"
        summary.append({"state": st, "shape_id": ids[sh], "kind": kind_of(sh),
                        "count": shapes[sh]["count"], "steps": shapes[sh]["steps"],
                        "median_ms": med, "verdict": verdicts, "shape": sh[:300]})
    meta["changed"] = summary
    meta["shapes"] = len(shapes)
    meta["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    with open(p("meta.json"), "w", encoding="utf-8", newline="\n") as fh:
        json.dump(meta, fh, indent=1, default=str)
    for s in summary:
        print(json.dumps(s, default=str), flush=True)
    print(f"optimize at close, median ms: current stats "
          f"{meta['optimize_close_median_ms_current_stats']}, none "
          f"{meta['optimize_close_median_ms_no_stats']}")
    print(f"PROBE-STATISTICS-COMPLETE shapes={len(shapes)} rows={len(rows)} "
          f"changed_pairs={len(changed)} out={a.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
