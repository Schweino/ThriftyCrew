r"""analyse_coverage_tolerances.py - are the hand-set coverage tolerances the right size?

    python grocery/analyse_coverage_tolerances.py            # the analysis
    python grocery/analyse_coverage_tolerances.py --selftest # frozen fixtures, hermetic

WHY THIS EXISTS (2026-09-07, backlog I13). Every threshold in this estate is CHOSEN, because almost
nothing keeps the history you would need to derive one. `coverage-baseline.json` is the exception in
waiting: eighteen checks carry a hand-set `tolerance` - a fraction of the baseline `examined` count,
below which the row is in breach - and `out/coverage-ledger-history.jsonl` has been appending what
each check actually examined, run after run, since 2026-08-01. So for these tolerances alone the
question "is this number right" is answerable from data already on disk.

THIS ANSWERS IT AND CHANGES NOTHING. A tolerance is a live gate; moving one on the strength of an
afternoon's arithmetic is how a guard gets loosened by a script instead of by a person. It names the
ones that look wrong and says which direction.

WHAT IT MEASURES, AND THE TRAP IT AVOIDS. Naively, "how far does examined swing?" is answered by the
max deviation - and that is dominated by STEP CHANGES, which are not noise. The everyday-mismatch row
fell from ~2,900 to ~2,500 on 2026-08-22 because a carry-forward fix retired 530 rows: a real,
permanent, explained shrink. A tolerance sized to absorb that would absorb everything.

So it reports the DOWNWARD deviation from a ROLLING median rather than from a global one, which
tracks a step change within a few runs instead of being permanently distorted by it, and it prints
the p95 and the max side by side - a tolerance has to sit above the ordinary variation and below the
fall you want caught, and those are different numbers.

EVERY FIGURE CARRIES ITS CASE COUNT (backlog E20, and `.claude/rules/measurement.md`). A p95 over six
runs is not a p95. Rows with too little history say so instead of producing a number.

Exit 0 always: this is an analysis, not a gate.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HISTORY = os.path.join(HERE, "out", "coverage-ledger-history.jsonl")
BASELINE = os.path.join(HERE, "coverage-baseline.json")

# Below this many runs, no percentile is claimed. Ten is not a statistical threshold, it is the point
# below which a p95 is just the maximum wearing a percentile's clothes.
MIN_RUNS = 10
# The rolling window a value is judged against. Short enough to follow a real step change within a
# few runs; long enough that one bad day does not move the reference.
WINDOW = 15


def rolling_downward_deviations(series, window=WINDOW):
    """For each point, how far BELOW the median of the preceding window it sat, as a fraction.

    Upward moves are not deviations for this purpose: the tolerance only fires on a FALL, so an
    examined count that doubled tells you nothing about whether the floor is the right height.
    Returns [] when there is not enough history to have a reference at all.
    """
    out = []
    for i in range(1, len(series)):
        prev = series[max(0, i - window):i]
        if not prev:
            continue
        ref = sorted(prev)[len(prev) // 2]
        if ref <= 0:
            continue                       # a zero reference makes every fraction meaningless
        d = (ref - series[i]) / float(ref)
        out.append(d if d > 0 else 0.0)
    return out


def pctile(vals, q):
    """Nearest-rank percentile. None when there is nothing to take one of."""
    if not vals:
        return None
    s = sorted(vals)
    k = max(0, min(len(s) - 1, int(round(q * (len(s) - 1)))))
    return s[k]


def judge_tolerance(name, tol, devs, min_runs=MIN_RUNS):
    """What the history says about a hand-set tolerance. Returns a dict; never mutates anything.

    Verdicts:
      too-few-runs  no claim made
      too-tight     ordinary variation already exceeds it, so it fires on days nothing is wrong
      too-loose     nothing in the record comes near it, so a real fall would not reach it either
      ok            sits above the ordinary variation and inside the observed range
      ratchet-off   tolerance of 1.0 or more disables the check by construction; not judged
    """
    n = len(devs)
    if tol is not None and tol >= 1.0:
        return {"name": name, "verdict": "ratchet-off", "n": n, "tol": tol, "p95": None, "max": None,
                "line": "%s: tolerance %.2f disables the floor by construction - not judged here" % (name, tol)}
    if n < min_runs:
        return {"name": name, "verdict": "too-few-runs", "n": n, "tol": tol, "p95": None, "max": None,
                "line": "%s: %d run(s) of history, under the %d needed to state a percentile" % (name, n, min_runs)}
    p95, mx = pctile(devs, 0.95), max(devs)
    if tol is None:
        v = "no-tolerance"
    elif tol < p95:
        v = "too-tight"
    elif mx > 0 and tol > 3.0 * mx:
        v = "too-loose"
    else:
        v = "ok"
    return {"name": name, "verdict": v, "n": n, "tol": tol, "p95": p95, "max": mx,
            "line": ("%s: tolerance %.2f vs ordinary variation p95 %.3f and worst observed %.3f, over %d run(s) -> %s"
                     % (name, tol if tol is not None else -1, p95, mx, n, v))}


def selftest():
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    print("analyse_coverage_tolerances self-test")
    print("")

    # MUST FIRE - the founding shapes.
    flat = [100] * 20 + [60]
    devs = rolling_downward_deviations(flat)
    T("MUST FIRE  a 40% fall off a flat history is measured as a 0.40 downward deviation",
      abs(max(devs) - 0.4) < 1e-9, str(max(devs)))
    T("MUST FIRE  a tolerance under the ordinary variation is called too-tight",
      judge_tolerance("x", 0.05, [0.10] * 20)["verdict"] == "too-tight",
      judge_tolerance("x", 0.05, [0.10] * 20)["line"])
    T("MUST FIRE  a tolerance nothing comes near is called too-loose",
      judge_tolerance("x", 0.90, [0.01] * 20)["verdict"] == "too-loose",
      judge_tolerance("x", 0.90, [0.01] * 20)["line"])

    # MUST NOT FIRE - the legal inputs, and the trap the whole file is shaped around.
    step = [3000] * 20 + [2500] * 20
    sdev = rolling_downward_deviations(step)
    late = sdev[-5:]
    T("MUST NOT FIRE  THE ONE THIS FILE IS SHAPED AROUND - a permanent STEP DOWN stops registering as "
      "a deviation once the rolling reference has followed it",
      max(late) < 1e-9, str(max(late)))
    T("MUST NOT FIRE  a rise is not a deviation - the floor only fires on a fall",
      max(rolling_downward_deviations([100] * 20 + [400])) == 0.0,
      str(max(rolling_downward_deviations([100] * 20 + [400]))))
    T("MUST NOT FIRE  THE E20 RULE - six runs produce no percentile, they produce a refusal",
      judge_tolerance("x", 0.10, [0.05] * 6)["verdict"] == "too-few-runs",
      judge_tolerance("x", 0.10, [0.05] * 6)["line"])
    T("MUST NOT FIRE  a deliberately disabled ratchet (tolerance 1.0) is reported, not judged",
      judge_tolerance("audit-ff-carry", 1.0, [0.5] * 40)["verdict"] == "ratchet-off",
      judge_tolerance("audit-ff-carry", 1.0, [0.5] * 40)["line"])
    T("MUST NOT FIRE  a well-sized tolerance is called ok",
      judge_tolerance("x", 0.10, [0.02] * 19 + [0.08])["verdict"] == "ok",
      judge_tolerance("x", 0.10, [0.02] * 19 + [0.08])["line"])

    # CLEAN TWIN - adjacent behaviour that still works.
    T("CLEAN TWIN a zero reference cannot divide by zero and is skipped",
      rolling_downward_deviations([0, 0, 0]) == [], str(rolling_downward_deviations([0, 0, 0])))
    T("CLEAN TWIN one point has no preceding window, so it yields no deviation",
      rolling_downward_deviations([5]) == [], str(rolling_downward_deviations([5])))
    T("CLEAN TWIN the percentile is nearest-rank and returns a real observation, never an interpolation",
      pctile([1, 2, 3, 4], 0.95) == 4, str(pctile([1, 2, 3, 4], 0.95)))
    T("CLEAN TWIN an empty series yields no percentile rather than a zero",
      pctile([], 0.95) is None, str(pctile([], 0.95)))

    if bad:
        print("")
        print("SELF-TEST FAIL: %d check(s)" % len(bad))
        print("COVERAGE-TOLERANCES-SELFTEST-COMPLETE")
        return 1
    print("")
    print("SELF-TEST PASS: 3 must-fire cases, 5 must-not-fire cases led by the step-change trap this "
          "file is shaped around, and 4 clean twins")
    print("COVERAGE-TOLERANCES-SELFTEST-COMPLETE")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="are the hand-set coverage tolerances the right size")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()

    if not os.path.exists(HISTORY) or not os.path.exists(BASELINE):
        print("COVERAGE TOLERANCES BLIND: history or baseline missing, so nothing was analysed. "
              "Expected in a worktree - out/ is gitignored - and NOT evidence the tolerances are right.")
        print("COVERAGE-TOLERANCES-COMPLETE blind=no-inputs")
        return 0

    series = {}
    runs = 0
    with io.open(HISTORY, encoding="utf-8-sig") as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            try:
                row = json.loads(ln)
            except Exception:                                      # noqa: BLE001
                continue
            ex = row.get("examined") or {}
            if not isinstance(ex, dict):
                continue
            runs += 1
            for k, v in ex.items():
                if isinstance(v, (int, float)):
                    series.setdefault(k, []).append(v)

    with io.open(BASELINE, encoding="utf-8-sig") as f:
        checks = json.load(f).get("checks", {})

    print("coverage tolerances, judged against %d run(s) of history in %s"
          % (runs, os.path.basename(HISTORY)))
    print("")
    verdicts = []
    for name in sorted(set(list(series.keys()) + list(checks.keys()))):
        tol = None
        if name in checks and isinstance(checks[name], dict):
            tol = checks[name].get("tolerance")
        devs = rolling_downward_deviations(series.get(name, []))
        v = judge_tolerance(name, tol, devs)
        verdicts.append(v)
        print("  " + v["line"])

    print("")
    for want, why in (("too-tight", "fires on days nothing is wrong, which is how a real red gets ignored"),
                      ("too-loose", "a genuine fall would not reach it, so the row is watched in name only")):
        hits = [v["name"] for v in verdicts if v["verdict"] == want]
        print("  %-10s %d of %d check(s)%s - %s"
              % (want, len(hits), len(verdicts), (": " + ", ".join(hits)) if hits else "", why))
    unjudged = [v["name"] for v in verdicts if v["verdict"] in ("too-few-runs", "ratchet-off", "no-tolerance")]
    print("  %-10s %d of %d check(s): %s" % ("unjudged", len(unjudged), len(verdicts), ", ".join(unjudged) or "none"))
    print("")
    print("NOTHING WAS CHANGED. A tolerance is a live gate and moving one on an afternoon's arithmetic "
          "is how a guard gets loosened by a script instead of by a person.")
    print("COVERAGE-TOLERANCES-COMPLETE checks=%d runs=%d" % (len(verdicts), runs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
