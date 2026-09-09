"""Per-request service time for the local LLM, because a mean is not a distribution.

WHY (2026-09-09, backlog I61). `tools/local-llm/serve.ps1` runs a multi-slot queue, and queueing theory
writes a system as `arrival / service / servers`. This estate has only ever recorded the SERVICE half as
a mean: `graph/pipeline/resolve.py` writes one whole-run `elapsed_sec` and nothing per request. A mean
cannot answer the only question that matters for a queue - **how heavy is the tail** - and the wait a
caller experiences is driven by the tail, not the average.

WHAT THIS RECORDS. One row per model call: wall time, prompt and completion tokens, and which call site
asked. `LLMResult` already carries `elapsed_s`, so nothing new is timed - it was being thrown away.

THE ROW IS THE DELIVERABLE, NOT THE SUMMARY (backlog E24). A pair of totals cannot be un-aggregated, so
the totals here are always derived from the file. That also makes the tokens/time pairing available for
free later, which is the shape that would separate "the server is slow" from "we asked for more".

THE BAR IS WRITTEN HERE, BEFORE ANY DATA EXISTS. For an exponential distribution the coefficient of
variation (sd / mean) is exactly 1. So:

    CV <= 1.20              near-exponential. An M/M/c model is a fair description and the standard
                            queueing results apply. No build is owed.
    CV >  1.20              the tail is heavier than exponential. The wait is dominated by a minority of
                            slow requests, and I61's rung 2 (a BOUNDED WAIT, not a timeout) is owed.

A bar chosen after seeing the number is not a threshold, it is a description of a decision already
taken, which is why this sentence is above the run rather than below it.

READ IT WITH:  python graph/lib/service_time.py --report
SELF-TEST:     python graph/lib/service_time.py --selftest
Exit 0 ok, 2 self-test failure, 3 no rows yet - BLIND, and BLIND IS NEVER A PASS.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GRAPH = os.path.dirname(HERE)
DEFAULT_LOG = os.path.join(GRAPH, "out", "llm-service-time.jsonl")

CV_EXPONENTIAL_BAR = 1.20


def record(kind: str, elapsed_s: float, prompt_tokens: int = 0, completion_tokens: int = 0,
           path: str = DEFAULT_LOG) -> None:
    """Append one service-time row. NEVER raises into the caller.

    A measurement that can break the pipeline it measures will be removed the first time it does, and
    then the pipeline is unmeasured again. So every failure here is swallowed on purpose.
    """
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        row = {"t": time.strftime("%Y-%m-%dT%H:%M:%S"), "kind": kind,
               "elapsed_s": round(float(elapsed_s), 4),
               "prompt_tokens": int(prompt_tokens), "completion_tokens": int(completion_tokens)}
        with open(path, "a", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(row) + "\n")
    except Exception:                                            # noqa: BLE001
        pass


def percentile(values, q: float) -> float:
    """Linear-interpolated percentile. Written out rather than imported so this module stays
    dependency-free - it is imported by the pipeline, and numpy is not wanted on that path."""
    if not values:
        raise ValueError("no values")
    s = sorted(values)
    if len(s) == 1:
        return float(s[0])
    k = (len(s) - 1) * (q / 100.0)
    lo = math.floor(k)
    hi = math.ceil(k)
    if lo == hi:
        return float(s[int(k)])
    return float(s[lo] + (s[hi] - s[lo]) * (k - lo))


def coefficient_of_variation(values) -> float:
    n = len(values)
    if n < 2:
        raise ValueError("need at least 2 values")
    mean = sum(values) / n
    if mean <= 0:
        raise ValueError("non-positive mean")
    var = sum((v - mean) ** 2 for v in values) / (n - 1)
    return math.sqrt(var) / mean


def tail_verdict(cv: float) -> str:
    return "NEAR-EXPONENTIAL" if cv <= CV_EXPONENTIAL_BAR else "HEAVY-TAILED"


def _load(path: str):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8-sig") as fh:      # the estate writes BOMs; a bare load would score 0
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def _selftest() -> int:
    bad = 0

    def T(name, ok, got=""):
        nonlocal bad
        if ok:
            print("  ok    " + name)
        else:
            print("  X     " + name + "   got: " + str(got))
            bad += 1

    T("the median of 1..9 is 5", percentile(list(range(1, 10)), 50) == 5.0, percentile(list(range(1, 10)), 50))
    T("p90 interpolates rather than rounding to a member", abs(percentile([1, 2, 3, 4], 90) - 3.7) < 1e-9,
      percentile([1, 2, 3, 4], 90))

    # MUST FIRE: a constant service time has CV 0 and must NOT be called heavy-tailed.
    T("MUST FIRE  a constant service time is CV 0", abs(coefficient_of_variation([2.0] * 20)) < 1e-9,
      coefficient_of_variation([2.0] * 20))
    T("and it is NEAR-EXPONENTIAL side of the bar", tail_verdict(0.0) == "NEAR-EXPONENTIAL", tail_verdict(0.0))

    # MUST FIRE: the founding case. One request 50x slower than the rest is exactly the tail a mean
    # hides, and it must cross the bar.
    spiky = [1.0] * 50 + [50.0]
    cv = coefficient_of_variation(spiky)
    T("MUST FIRE  one 50x outlier in 51 requests is HEAVY-TAILED", tail_verdict(cv) == "HEAVY-TAILED", cv)
    T("MUST FIRE  and the mean alone would have hidden it (mean stays near 2s)",
      abs(sum(spiky) / len(spiky) - 1.96) < 0.05, sum(spiky) / len(spiky))

    # MUST NOT FIRE: a genuinely exponential sample sits near CV 1 and is not called heavy.
    # Deterministic inverse-transform sample, so this fixture cannot flake.
    n = 400
    expo = [-math.log(1.0 - (i + 0.5) / n) for i in range(n)]
    cve = coefficient_of_variation(expo)
    T("MUST NOT FIRE  an exponential sample is not called heavy-tailed",
      tail_verdict(cve) == "NEAR-EXPONENTIAL", cve)
    T("and its CV really is near 1", abs(cve - 1.0) < 0.15, cve)

    T("the bar is the one written above the run", CV_EXPONENTIAL_BAR == 1.20, CV_EXPONENTIAL_BAR)

    # CLEAN TWIN: recording still works and stays parseable after all of the above.
    tmp = os.path.join(GRAPH, "out", "_service_time_selftest.jsonl")
    try:
        if os.path.exists(tmp):
            os.remove(tmp)
        record("selftest", 1.25, 10, 20, path=tmp)
        rows = _load(tmp)
        T("CLEAN TWIN  a recorded row reads back with its fields intact",
          len(rows) == 1 and rows[0]["elapsed_s"] == 1.25 and rows[0]["kind"] == "selftest", str(rows))
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)

    # MUST NOT FIRE: record() must never raise into the pipeline, even pointed somewhere impossible.
    try:
        record("selftest", 1.0, path=os.path.join(GRAPH, "out", "\0bad", "x.jsonl"))
        T("MUST NOT FIRE  record() swallows its own failure rather than breaking the caller", True)
    except Exception as e:                                       # noqa: BLE001
        T("MUST NOT FIRE  record() swallows its own failure rather than breaking the caller", False, str(e))

    if bad:
        print("service-time SELF-TEST FAIL (%d)" % bad)
        return 2
    print("service-time SELF-TEST PASS")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--log", default=DEFAULT_LOG)
    args = ap.parse_args()

    if args.selftest:
        return _selftest()
    if not args.report:
        ap.print_help()
        return 0

    rows = _load(args.log)
    vals = [float(r["elapsed_s"]) for r in rows if isinstance(r.get("elapsed_s"), (int, float))]
    if len(vals) < 2:
        print("service-time: %d row(s) in %s - BLIND, not clean. Run the pipeline against a live"
              % (len(vals), args.log))
        print("  llama-server and the rows appear; port 8080 was refusing on 2026-09-09.")
        return 3

    cv = coefficient_of_variation(vals)
    print("service-time: %d request(s) from %s" % (len(vals), os.path.basename(args.log)))
    print("  mean %.2fs   p50 %.2fs   p90 %.2fs   p99 %.2fs   max %.2fs"
          % (sum(vals) / len(vals), percentile(vals, 50), percentile(vals, 90),
             percentile(vals, 99), max(vals)))
    print("  coefficient of variation %.3f   (exponential is exactly 1.000)" % cv)
    print("  BAR (written before any data existed): CV <= %.2f near-exponential, above it heavy-tailed"
          % CV_EXPONENTIAL_BAR)
    print("  VERDICT: %s" % tail_verdict(cv))
    by_kind = {}
    for r in rows:
        by_kind.setdefault(r.get("kind", "?"), []).append(float(r.get("elapsed_s", 0)))
    for k, v in sorted(by_kind.items(), key=lambda kv: -len(kv[1])):
        print("    %-22s %5d request(s)  p50 %.2fs  p90 %.2fs"
              % (k, len(v), percentile(v, 50), percentile(v, 90)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
