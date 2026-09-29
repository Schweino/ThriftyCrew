"""Eval health checks for graph/eval/score.py --health (W4 of
design/PLAN-eval-heldout-and-hillclimb-2026-09-29.md).

    python graph/eval/score.py --health [--runs 3]
    python graph/eval/score_health.py --selftest

Three checks, run over the SAME gold blob:

  NOISE FLOOR   every arm is scored N times. The per-metric spread (max minus
                min) of the LLM arms is the measured noise floor: a later change
                that moves a metric by less than it has not been shown to move it.
                The deterministic arm must show ZERO spread; any spread there is a
                harness defect and exits 1 (DETERMINISTIC-SPREAD).
  ORDERING      recall must run deterministic <= +llm <= +bank (system). A flat or
                inverted step prints ORDERING-SUSPECT naming the arms. A finding,
                never an exit code.
  HEADROOM      a metric at exactly 0 or exactly 1 on every run of every arm prints
                SATURATED <metric>: a non-regression there is not an improvement.

Nothing here calls score.record(), so a health run writes no eval_runs row and
no tracked learning JSON.

Exit: 0 health run completed (findings may be printed), 1 deterministic spread
(harness defect), 2 could not run (no gold, model down, empty index).
Last line: SCORE-HEALTH-COMPLETE runs=N arms=K.

SCOPE OF A CLEAN REPORT: UNSOUND for noise beyond N runs (three runs bound the
spread from below, never above); COMPLETE for DETERMINISTIC-SPREAD (a nonzero
spread over identical inputs IS the defect).
Not a push gate: it needs a board-built index and a live model.
"""
# gate-inputs: graph\eval\score_health.py

from __future__ import annotations

import sys
import time

METRICS = ("entity_precision", "entity_recall", "f1",
           "false_merge_rate", "missed_merge_rate")
DET = "deterministic"
ORDER = (DET, "llm", "system")   # recall must be non-decreasing along this
ZERO_SPREAD = 0.0                # the deterministic bar: exactly zero, no tolerance


def spread(values: list[float]) -> float:
    return (max(values) - min(values)) if values else 0.0


def check(runs: dict[str, list[dict]]) -> dict:
    """runs: arm -> list of metric dicts (one per repetition). Pure."""
    out = {"spread": {}, "values": {}, "findings": [], "harness_defect": False}
    for arm, ms in runs.items():
        for k in METRICS:
            vals = [float(m[k]) for m in ms]
            out["values"][(arm, k)] = vals
            out["spread"][(arm, k)] = spread(vals)
            if arm == DET and spread(vals) > ZERO_SPREAD:
                out["harness_defect"] = True
                out["findings"].append(f"DETERMINISTIC-SPREAD {k} {spread(vals)!r} values={vals}")
    present = [a for a in ORDER if a in runs and runs[a]]
    for lo, hi in zip(present, present[1:]):
        rlo = min(float(m["entity_recall"]) for m in runs[lo])
        rhi = max(float(m["entity_recall"]) for m in runs[hi])
        if rhi < rlo:
            out["findings"].append(f"ORDERING-SUSPECT inverted {lo}={rlo:.4f} > {hi}={rhi:.4f}")
        elif rhi == rlo:
            out["findings"].append(f"ORDERING-SUSPECT flat {lo}={rlo:.4f} == {hi}={rhi:.4f}")
    for k in METRICS:
        allv = [v for arm in runs for v in out["values"][(arm, k)]]
        if allv and (all(v == 0.0 for v in allv) or all(v == 1.0 for v in allv)):
            out["findings"].append(f"SATURATED {k} at {allv[0]:.1f} on every arm")
    return out


def report(res: dict, runs: dict[str, list[dict]]) -> None:
    for arm in runs:
        for k in METRICS:
            vals = res["values"][(arm, k)]
            print(f"  {arm:13s} {k:18s} spread={res['spread'][(arm, k)]:.4f}  "
                  f"values={' '.join(f'{v:.4f}' for v in vals)}")
    for f in res["findings"]:
        print(f)


def run_health(db, gold, llm, n: int, score_fn) -> int:
    """Score each arm n times. score_fn is score.score (injected to avoid a cycle)."""
    arms = {DET: dict(use_llm=False, use_bank=False)}
    if llm is not None:
        arms["llm"] = dict(use_llm=True, use_bank=False)
        arms["system"] = dict(use_llm=True, use_bank=True)
    else:
        print("BLIND llm arms: no model (deterministic arm only)")
    runs: dict[str, list[dict]] = {a: [] for a in arms}
    t0 = time.time()
    for i in range(n):
        for arm, kw in arms.items():
            t = time.time()
            m = score_fn(db, gold, llm=llm if kw["use_llm"] else None, **kw)
            runs[arm].append(m)
            c = m["counts"]
            print(f"  run {i+1}/{n} {arm}: recall={m['entity_recall']:.4f} "
                  f"fm={m['false_merge_rate']:.4f} mm={m['missed_merge_rate']:.4f} "
                  f"scored {c['gold_match'] + c['gold_no_match']} of {len(gold)} "
                  f"(missing_node={c['missing_node']}) {time.time()-t:.0f}s", flush=True)
    res = check(runs)
    print(f"=== score health: {n} runs x {len(arms)} arms, {len(gold)} gold rows, "
          f"{time.time()-t0:.0f}s wall ===")
    report(res, runs)
    print(f"SCORE-HEALTH-COMPLETE runs={n} arms={len(arms)}")
    return 1 if res["harness_defect"] else 0


def _m(recall=0.5, fm=0.25, mm=0.5, p=0.75):
    return {"entity_precision": p, "entity_recall": recall, "f1": 0.5,
            "false_merge_rate": fm, "missed_merge_rate": mm}


def selftest() -> int:
    cases = []

    def case(name, runs, want_defect, want_sub, absent_sub=()):
        r = check(runs)
        ok = r["harness_defect"] == want_defect
        text = "\n".join(r["findings"])
        ok = ok and all(s in text for s in want_sub) and not any(s in text for s in absent_sub)
        cases.append((name, ok, text))

    mono = {DET: [_m(0.5)] * 3, "llm": [_m(0.625)] * 3, "system": [_m(0.75)] * 3}
    case("MUST NOT FIRE zero deterministic spread, monotone ordering", mono, False, [],
         ["DETERMINISTIC-SPREAD", "ORDERING-SUSPECT", "SATURATED"])
    case("MUST FIRE deterministic spread one step past the zero bar (0.25 vs 0.5 recall)",
         {DET: [_m(0.5), _m(0.5), _m(0.25)], "llm": [_m(0.625)], "system": [_m(0.75)]},
         True, ["DETERMINISTIC-SPREAD entity_recall"])
    case("MUST NOT FIRE deterministic spread exactly AT the zero bar",
         {DET: [_m(0.5), _m(0.5)]}, False, [], ["DETERMINISTIC-SPREAD"])
    case("CLEAN TWIN llm-arm spread is a noise floor, not a defect",
         {DET: [_m(0.5)] * 2, "llm": [_m(0.625), _m(0.75)], "system": [_m(0.875)] * 2},
         False, [], ["DETERMINISTIC-SPREAD", "ORDERING-SUSPECT"])
    case("MUST FIRE inverted ordering names the arms",
         {DET: [_m(0.5)], "llm": [_m(0.75)], "system": [_m(0.625)]},
         False, ["ORDERING-SUSPECT inverted llm=0.7500 > system=0.6250"])
    case("MUST FIRE flat ordering AT the bar (equal recall)",
         {DET: [_m(0.5)], "llm": [_m(0.5)], "system": [_m(0.75)]},
         False, ["ORDERING-SUSPECT flat deterministic=0.5000 == llm=0.5000"])
    case("MUST NOT FIRE one step past flat (0.5 -> 0.625)",
         {DET: [_m(0.5)], "llm": [_m(0.625)], "system": [_m(0.75)]},
         False, [], ["ORDERING-SUSPECT"])
    case("MUST FIRE false_merge saturated at 0 on every arm",
         {DET: [_m(0.5, fm=0.0)], "llm": [_m(0.625, fm=0.0)], "system": [_m(0.75, fm=0.0)]},
         False, ["SATURATED false_merge_rate at 0.0"])
    case("MUST FIRE precision saturated at 1 on every arm",
         {DET: [_m(0.5, p=1.0)], "llm": [_m(0.625, p=1.0)]},
         False, ["SATURATED entity_precision at 1.0"])
    case("MUST NOT FIRE saturation when one arm leaves 0",
         {DET: [_m(0.5, fm=0.0)], "llm": [_m(0.625, fm=0.25)]},
         False, [], ["SATURATED false_merge_rate"])

    fails = 0
    for name, ok, text in cases:
        print(f"  {'ok  ' if ok else 'FAIL'} {name}")
        if not ok:
            fails += 1
            print(f"       findings: {text!r}")
    ran = len(cases)
    if ran != 10:
        print(f"score_health self-test FAIL: ran {ran} cases, expected 10")
        return 1
    print(f"score_health: {ran - fails} of {ran} cases passed")
    print(f"score_health self-test {'pass' if fails == 0 else 'FAIL'}")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(selftest())
    print("run via: python graph/eval/score.py --health", file=sys.stderr)
    raise SystemExit(2)
