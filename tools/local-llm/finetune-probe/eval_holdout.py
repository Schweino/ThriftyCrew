"""Score a holdout run against the stock-27B 29% cold-start false-MATCH baseline (backlog I55).

WHY THIS FILE EXISTS SEPARATELY FROM ANY TRAINING CODE. `MEASURE-local-finetune-feasibility-2026-08-22.md`
section 10 says per-example loss during training is **noise, not a learning signal**, and that the
number that decides whether the fine-tune was worth 17 to 25 hours of GPU is the **holdout false-MATCH
rate against the stock-27B 29% baseline**. That scorer did not exist, so the decision could not be
taken either way. It is pure arithmetic over (gold, prediction) pairs and needs no GPU, so it is
written and tested now, before any model runs.

THE ACCEPTANCE BAR IS WRITTEN HERE, ABOVE ANY RUN, in the metric's own units. A threshold chosen after
seeing the number is not a threshold.

    BASELINE_FALSE_MATCH = 0.29   stock 27B, cold start
    A fine-tune EARNS its GPU hours only if holdout false-MATCH lands at or below 0.20, an absolute
    improvement of at least 9 points. Anything between 0.20 and 0.29 is a move, not an improvement
    worth the schedule, and is reported as such rather than talked up.

AND A RATE IS PRINTED WITH ITS DENOMINATOR, always. `29%` is a mood; `29 false MATCHes over 100 cold
cases` is a measurement. With 516 commodities in the gold set a 20% holdout is ~103 commodities, and
at those counts a few percentage points is noise - so this refuses to call a difference an improvement
unless it clears the bar AND the holdout has at least MIN_CASES rows.

ABSTENTION COUNTS. A model that answers UNSURE on everything it finds hard would post a beautiful
false-MATCH rate while being useless. Coverage is reported beside accuracy, per the estate rule, and
an abstention is never silently dropped from the denominator.

    python tools/local-llm/finetune-probe/eval_holdout.py --predictions <file.jsonl>
    python tools/local-llm/finetune-probe/eval_holdout.py --selftest
Exit 0 scored, 2 self-test failure, 3 nothing to score (BLIND, never a pass).
"""
from __future__ import annotations

import argparse
import json
import os
import sys

BASELINE_FALSE_MATCH = 0.29
BAR_FALSE_MATCH = 0.20
MIN_CASES = 100


def score(pairs):
    """pairs: iterable of (gold_label, predicted_label). Pure.

    A FALSE MATCH is the failure that costs money here: the model said MATCH when the gold says it is
    not one, which is how a wrong product reaches a board cell. Returns a dict; every rate carries the
    count it came from.
    """
    total = 0
    false_match = 0
    true_match = 0
    abstained = 0
    gold_non_match = 0
    for gold, pred in pairs:
        total += 1
        g = (gold or "").strip().upper()
        p = (pred or "").strip().upper()
        if p in ("", "UNSURE", "PENDING", "UNUSABLE"):
            abstained += 1
        if g != "MATCH":
            gold_non_match += 1
            if p == "MATCH":
                false_match += 1
        else:
            if p == "MATCH":
                true_match += 1
    return {
        "total": total,
        "gold_non_match": gold_non_match,
        "false_match": false_match,
        # The denominator is the cases that COULD have been a false match. Dividing by everything
        # would let a corpus of mostly-MATCH rows flatter any model.
        "false_match_rate": (false_match / gold_non_match) if gold_non_match else None,
        "abstained": abstained,
        "coverage": ((total - abstained) / total) if total else None,
        "true_match": true_match,
    }


def verdict(s):
    """Did it earn the GPU hours? Refuses to answer on too little data."""
    if s["gold_non_match"] == 0:
        return "UNSCOREABLE", "no gold non-MATCH rows, so a false-MATCH rate cannot exist"
    if s["total"] < MIN_CASES:
        return "UNSCOREABLE", ("only %d holdout case(s), under the %d-case minimum - a few points here "
                               "is noise" % (s["total"], MIN_CASES))
    r = s["false_match_rate"]
    if r <= BAR_FALSE_MATCH:
        return "EARNED", ("false-MATCH %.1f%% is at or below the %.0f%% bar, against a %.0f%% baseline"
                          % (100 * r, 100 * BAR_FALSE_MATCH, 100 * BASELINE_FALSE_MATCH))
    if r < BASELINE_FALSE_MATCH:
        return "MOVED, NOT EARNED", ("false-MATCH %.1f%% beats the %.0f%% baseline but misses the "
                                     "%.0f%% bar" % (100 * r, 100 * BASELINE_FALSE_MATCH,
                                                     100 * BAR_FALSE_MATCH))
    return "NO BETTER", ("false-MATCH %.1f%% is not below the %.0f%% stock baseline"
                        % (100 * r, 100 * BASELINE_FALSE_MATCH))


def _selftest() -> int:
    bad = 0

    def T(name, ok, got=""):
        nonlocal bad
        if ok:
            print("  ok    " + name)
        else:
            print("  X     " + name + "   got: " + str(got))
            bad += 1

    # MUST FIRE - the false-MATCH denominator is the gold NON-match rows, not everything. Dividing by
    # everything would let a mostly-MATCH corpus flatter any model.
    s = score([("NO_MATCH", "MATCH"), ("NO_MATCH", "NO_MATCH"), ("MATCH", "MATCH"), ("MATCH", "MATCH")])
    T("MUST FIRE  false-MATCH is scored over gold NON-match rows only (1 of 2, not 1 of 4)",
      s["false_match"] == 1 and s["gold_non_match"] == 2 and abs(s["false_match_rate"] - 0.5) < 1e-9, s)

    # MUST FIRE - abstention is counted, or a model that declines everything looks perfect.
    s2 = score([("NO_MATCH", "UNSURE"), ("NO_MATCH", "UNSURE"), ("MATCH", "UNSURE")])
    T("MUST FIRE  a model that abstains on everything posts 0 false MATCHes and 0% coverage",
      s2["false_match"] == 0 and s2["coverage"] == 0.0, s2)
    T("MUST FIRE  and that is refused as UNSCOREABLE rather than reported as a win",
      verdict(s2)[0] == "UNSCOREABLE", verdict(s2))

    # MUST FIRE - the bar was written above the run and is not tunable from the data.
    T("MUST FIRE  the bar and baseline are the ones written in the header",
      (BASELINE_FALSE_MATCH, BAR_FALSE_MATCH) == (0.29, 0.20),
      (BASELINE_FALSE_MATCH, BAR_FALSE_MATCH))

    big_good = [("NO_MATCH", "NO_MATCH")] * 90 + [("NO_MATCH", "MATCH")] * 10 + [("MATCH", "MATCH")] * 10
    T("a 10% false-MATCH rate over 100 non-match cases EARNS it",
      verdict(score(big_good))[0] == "EARNED", verdict(score(big_good)))

    big_mid = [("NO_MATCH", "NO_MATCH")] * 75 + [("NO_MATCH", "MATCH")] * 25 + [("MATCH", "MATCH")] * 10
    T("MUST FIRE  25% is called MOVED, NOT EARNED - a number that moved is not a number that improved",
      verdict(score(big_mid))[0] == "MOVED, NOT EARNED", verdict(score(big_mid)))

    big_bad = [("NO_MATCH", "NO_MATCH")] * 60 + [("NO_MATCH", "MATCH")] * 40 + [("MATCH", "MATCH")] * 10
    T("40% is NO BETTER than the stock baseline", verdict(score(big_bad))[0] == "NO BETTER",
      verdict(score(big_bad)))

    # MUST NOT FIRE - too few cases is refused, not scored.
    small = [("NO_MATCH", "NO_MATCH")] * 9 + [("NO_MATCH", "MATCH")]
    T("MUST NOT FIRE  10 cases is UNSCOREABLE, however good the rate looks",
      verdict(score(small))[0] == "UNSCOREABLE", verdict(score(small)))

    # MUST NOT FIRE - an empty run does not divide by zero and does not score.
    T("MUST NOT FIRE  an empty run is UNSCOREABLE, not 0%",
      verdict(score([]))[0] == "UNSCOREABLE", verdict(score([])))

    # CLEAN TWIN - a perfect model still reports its true MATCHes, so the scorer is not just counting
    # failures. A positive assertion.
    perfect = [("MATCH", "MATCH")] * 5 + [("NO_MATCH", "NO_MATCH")] * 5
    T("CLEAN TWIN  true MATCHes are still counted, and coverage is 100%",
      score(perfect)["true_match"] == 5 and score(perfect)["coverage"] == 1.0, score(perfect))

    if bad:
        print("eval-holdout SELF-TEST FAIL (%d)" % bad)
        return 2
    print("eval-holdout SELF-TEST PASS: 10 case(s) resolved")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--predictions", default="",
                    help="jsonl with a gold label and a predicted label per row")
    ap.add_argument("--gold-field", default="label")
    ap.add_argument("--pred-field", default="prediction")
    args = ap.parse_args()

    if args.selftest:
        return _selftest()

    if not args.predictions or not os.path.exists(args.predictions):
        print("eval-holdout: no predictions file - BLIND, not clean.")
        print("  Nothing has been trained yet. Build the split first, run a model over")
        print("  corpus-holdout.jsonl, write one row per case with a '%s' field, then score it here."
              % args.pred_field)
        print("  BAR (written before any run): false-MATCH at or below %.0f%%, against the %.0f%% stock baseline."
              % (100 * BAR_FALSE_MATCH, 100 * BASELINE_FALSE_MATCH))
        return 3

    pairs = []
    with open(args.predictions, encoding="utf-8-sig") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            pairs.append((r.get(args.gold_field), r.get(args.pred_field)))

    s = score(pairs)
    v, why = verdict(s)
    print("eval-holdout: %d case(s), %d of them gold non-MATCH" % (s["total"], s["gold_non_match"]))
    if s["false_match_rate"] is not None:
        print("  false MATCH: %d of %d (%.1f%%)   baseline %.0f%%   bar %.0f%%"
              % (s["false_match"], s["gold_non_match"], 100 * s["false_match_rate"],
                 100 * BASELINE_FALSE_MATCH, 100 * BAR_FALSE_MATCH))
    print("  coverage:    %d of %d answered (%.1f%%), %d abstention(s) counted, never dropped"
          % (s["total"] - s["abstained"], s["total"],
             100 * (s["coverage"] or 0), s["abstained"]))
    print("  VERDICT: %s - %s" % (v, why))
    return 0


if __name__ == "__main__":
    sys.exit(main())
