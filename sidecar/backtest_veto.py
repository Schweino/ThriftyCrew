r"""backtest_veto.py - the bar backtest.py states and never enforced.

    python sidecar/backtest_veto.py --selftest

BACKLOG I17. `backtest.py` opens by calling itself "the ACCEPTANCE GATE for the semantic sidecar" and
says, in its own words, "it is allowed to fail". It cannot. `main()` writes a JSON report, returns
None, and there is no `sys.exit` anywhere in the file, so every run exits 0 no matter what it
measured. A gate that cannot fail is a report with a misleading name.

WHAT THE BAR ACTUALLY IS, taken from that file rather than invented here. For a CANDIDATE reranker it
states the rule twice:

    "beating stock on a cold holdout is not enough if the new weights lose a defect the old ones
     caught [...] it ships only if it still catches what stock catches"

So this is a VETO, not the decider. `hardeval.py` is explicit that GOLD is the number that decides and
that backtest's 25 negatives "never ask a hard question". A veto that never fires is exactly the
failure I17 describes, and making it fire does not promote backtest above hardeval.

WHY A MISMATCHED --defs REFUSES RATHER THAN COMPARES. `commodity_text()` is "label + up to 5 of the
products the board currently accepts", so every score is a function of what the shelf looked like that
morning. backtest.py measured it: same model, same eval files, only the commodity text changed, and
AUC moved 0.9705 to 0.7921 with known-wrong caught going 17/25 to 0/25. The same file reported 24/24
on 2026-08-01 and 17/25 on 2026-08-22 because the BOARD changed, not the model. A candidate compared
against a baseline built on different defs is measuring board churn, and the difference is larger than
any fine-tune is likely to buy - so that comparison is refused as could-not-evaluate rather than
reported as a verdict.

EXIT CODES follow lib/guard-contract.ps1's vocabulary: 0 clean, 2 hard finding, 3 could-not-evaluate.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import sys


def _points(report):
    """budget -> known_wrong_caught, as ints, from a backtest report."""
    out = {}
    ops = ((report or {}).get("task_a") or {}).get("operating_points") or {}
    for k, v in ops.items():
        try:
            out[int(k)] = int((v or {}).get("known_wrong_caught"))
        except (TypeError, ValueError):
            continue
    return out


def defs_comparable(candidate, stock):
    """(ok, why). Whether the two reports were scored against the same commodity text.

    A report predating the `defs` field cannot prove it, and 'cannot prove it' is not 'it matched' -
    this estate has a standing rule that an agreeing number escapes scrutiny, and a missing field that
    silently passes is that rule violated.
    """
    c = (candidate or {}).get("defs")
    s = (stock or {}).get("defs")
    if not c or not s:
        return False, ("one of the reports does not record which commodity-defs it used "
                       "(candidate=%r, stock=%r), so the comparison cannot be shown to be like for "
                       "like" % (c, s))
    if c != s:
        return False, "scored against different commodity defs: candidate=%r, stock=%r" % (c, s)
    return True, "both scored against %s" % c


def veto(candidate, stock):
    """(rc, lines). The candidate ships only if it still catches what stock catches, at every budget."""
    lines = []
    if not candidate:
        return 3, ["VETO COULD NOT EVALUATE: no candidate report was produced."]
    if not stock:
        return 3, ["VETO COULD NOT EVALUATE: no stock baseline at sidecar/out/backtest.json to compare "
                   "against. A veto with nothing to veto against is not a pass - run the stock backtest "
                   "first, with the same --defs."]

    ok, why = defs_comparable(candidate, stock)
    if not ok:
        return 3, ["VETO COULD NOT EVALUATE: %s." % why,
                   "backtest.py measured this itself: same model and same eval files, only the "
                   "commodity text changed, and known-wrong caught went 17/25 to 0/25. A comparison "
                   "across different defs measures the board, not the model."]

    cp, sp = _points(candidate), _points(stock)
    shared = sorted(set(cp) & set(sp))
    if not shared:
        return 3, ["VETO COULD NOT EVALUATE: the two reports share no operating budget, so there is "
                   "nothing to compare."]

    lost = [(b, sp[b], cp[b]) for b in shared if cp[b] < sp[b]]
    for b in shared:
        lines.append("  budget %-4d stock caught %-3d candidate caught %-3d %s"
                     % (b, sp[b], cp[b], "LOST" if cp[b] < sp[b] else ""))
    lines.append("  %s" % why)
    if lost:
        worst = max(sp[b] - cp[b] for b, _, _ in lost)
        lines.append("VETO: the candidate catches FEWER known-wrong pairs than stock at %d of %d "
                     "budget(s), worst by %d. backtest.py's own rule is that it ships only if it "
                     "still catches what stock catches, so this one does not ship - whatever it "
                     "scored on a cold holdout."
                     % (len(lost), len(shared), worst))
        return 2, lines
    lines.append("VETO PASSED: the candidate catches at least as many known-wrong pairs as stock at "
                 "every shared budget. This is a veto and not an endorsement - hardeval GOLD is the "
                 "number that decides.")
    return 0, lines


def find_stock_baseline(out_dir, reports=None):
    """(report, path, why) - the newest STOCK report that records the defs it was scored against.

    `backtest.json` is the conventional name and it predates the `defs` field, so preferring it by name
    would make every veto a permanent could-not-evaluate. What the comparison needs is not a filename:
    it is a report from the PINNED model that says which commodity text it saw. That is what this looks
    for, and it names the file it chose so the number is reproducible.

    `reports` is for the self-test: a list of (path, doc) instead of a directory read.
    """
    cands = []
    if reports is None:
        reports = []
        try:
            for fn in sorted(os.listdir(out_dir)):
                if fn.startswith("backtest") and fn.endswith(".json"):
                    d = load(os.path.join(out_dir, fn))
                    if d:
                        reports.append((os.path.join(out_dir, fn), d))
        except OSError:
            return None, None, "could not read %s" % out_dir
    for path, d in reports:
        if not d.get("defs"):
            continue
        if d.get("is_pinned_model") is not True:
            continue
        cands.append((d.get("generated") or "", path, d))
    if not cands:
        return None, None, ("no stock report in %s records the commodity defs it was scored against, so "
                            "no honest baseline exists yet - run backtest.py with --defs against the "
                            "pinned model first" % out_dir)
    cands.sort(key=lambda x: x[0])
    _, path, d = cands[-1]
    return d, path, "baseline: %s (pinned model, defs %s)" % (os.path.basename(path), d.get("defs"))


def load(path):
    try:
        with io.open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def selftest():                                                # noqa: C901
    fails = []

    def T(name, cond, got=""):
        if cond:
            print("  ok    %s" % name)
        else:
            print("  X     %s   got: %s" % (name, got))
            fails.append(name)

    def rep(points, defs="frozen.json"):
        return {"defs": defs,
                "task_a": {"operating_points": {str(k): {"known_wrong_caught": v}
                                                for k, v in points.items()}}}

    stock = rep({10: 4, 20: 8, 30: 12, 50: 15, 100: 17})

    rc, lines = veto(rep({10: 4, 20: 8, 30: 12, 50: 15, 100: 17}), stock)
    T("CLEAN TWIN a candidate that matches stock everywhere passes", rc == 0, "%s %s" % (rc, lines[-1]))

    rc, lines = veto(rep({10: 5, 20: 9, 30: 13, 50: 16, 100: 18}), stock)
    T("CLEAN TWIN a candidate that beats stock everywhere passes", rc == 0, rc)

    # THE FOUNDING CASE. backtest.py's stated rule, which nothing enforced: a candidate that wins
    # elsewhere but LOSES a defect stock caught must not ship.
    rc, lines = veto(rep({10: 4, 20: 8, 30: 11, 50: 15, 100: 17}), stock)
    T("MUST FIRE  losing ONE known-wrong pair at ONE budget is a veto",
      rc == 2 and any("does not ship" in x for x in lines), "%s" % rc)

    rc, lines = veto(rep({10: 0, 20: 0, 30: 0, 50: 0, 100: 0}), stock)
    T("MUST FIRE  a candidate that catches nothing is a veto", rc == 2, rc)

    rc, lines = veto(rep({10: 4}), None)
    T("MUST FIRE  no stock baseline is could-not-evaluate, NOT a pass", rc == 3, rc)
    T("the could-not-evaluate says a veto with nothing to compare is not a pass",
      any("is not a pass" in x for x in lines), lines[0])

    rc, lines = veto(None, stock)
    T("no candidate report is could-not-evaluate", rc == 3, rc)

    # THE DEFS TRAP, which backtest.py measured on itself: 17/25 to 0/25 on the same model.
    rc, lines = veto(rep({10: 4, 100: 17}, defs="today.json"), rep({10: 4, 100: 17}, defs="frozen.json"))
    T("MUST FIRE  different commodity defs refuses rather than comparing", rc == 3, rc)
    rc, lines = veto(rep({10: 4, 100: 17}, defs=None), stock)
    T("MUST FIRE  a report that does not RECORD its defs cannot prove they matched", rc == 3, rc)
    T("a missing defs field is not silently treated as a match",
      any("cannot be shown to be like for like" in x for x in lines), lines[0])

    rc, lines = veto(rep({200: 20}), stock)
    T("no shared budget is could-not-evaluate rather than a vacuous pass", rc == 3, rc)

    ok, why = defs_comparable({"defs": "a.json"}, {"defs": "a.json"})
    T("CLEAN TWIN matching defs compare", ok, why)

    # THE BASELINE CHOOSER. Preferring the conventional filename made every veto a permanent
    # could-not-evaluate, because backtest.json predates the defs field.
    old = ("out/backtest.json", {"generated": "2026-08-22 21:05:30", "is_pinned_model": True, "defs": None})
    good = ("out/backtest-phase3-frozen.json",
            {"generated": "2026-08-22 21:11:05", "is_pinned_model": True, "defs": "commodity-defs.json"})
    cand = ("out/backtest-ft-v1.json",
            {"generated": "2026-08-23 09:00:00", "is_pinned_model": False, "defs": "commodity-defs.json"})
    d, p, why = find_stock_baseline(None, reports=[old, good, cand])
    T("MUST FIRE  a baseline with no recorded defs is passed over for one that has them",
      p == "out/backtest-phase3-frozen.json", p)
    T("MUST FIRE  a CANDIDATE report is never chosen as the baseline, however new",
      d is not None and d.get("is_pinned_model") is True, d)
    T("the chosen baseline is named, so the number is reproducible", "phase3-frozen" in (why or ""), why)

    d, p, why = find_stock_baseline(None, reports=[old])
    T("MUST FIRE  when nothing records its defs, it says so rather than picking one",
      d is None and "no honest baseline" in why, why)

    newer = ("out/backtest-later.json",
             {"generated": "2026-09-01 10:00:00", "is_pinned_model": True, "defs": "commodity-defs.json"})
    d, p, why = find_stock_baseline(None, reports=[good, newer])
    T("CLEAN TWIN the NEWEST qualifying stock report wins", p == "out/backtest-later.json", p)

    if fails:
        print("SELF-TEST FAIL: %d case(s)" % len(fails))
        return 1
    print("SELF-TEST PASS: the founding case where a candidate wins elsewhere and loses one known-wrong "
          "pair, plus the two could-not-evaluate refusals that a vacuous pass would hide")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Enforce backtest.py's own candidate bar")
    ap.add_argument("--candidate", required=True, help="path to a tagged backtest report")
    ap.add_argument("--stock", default=None, help="path to the stock backtest.json")
    a = ap.parse_args([x for x in sys.argv[1:] if x != "--run"])
    here = os.path.dirname(os.path.abspath(__file__))
    if a.stock:
        stock, why = load(a.stock), "baseline: %s (named on the command line)" % os.path.basename(a.stock)
    else:
        stock, _p, why = find_stock_baseline(os.path.join(here, "out"))
    print(why)
    rc, lines = veto(load(a.candidate), stock)
    for ln in lines:
        print(ln)
    return rc


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
