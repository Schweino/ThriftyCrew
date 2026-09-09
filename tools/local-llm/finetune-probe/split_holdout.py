"""The commodity holdout split that `MEASURE-local-finetune-feasibility-2026-08-22.md` section 10 says
does not exist, and without which a training run cannot be scored (2026-09-09, backlog I55).

WHY THIS BLOCKS EVERYTHING ELSE. The point of the fine-tune is to move the cold-start false-MATCH rate
against the stock-27B 29% baseline. "Cold" means the model has never seen the commodity. If the test
rows are drawn at random from the same shuffled corpus, the model has already been trained on other
products of the SAME commodity and the test set is warm - so the number it reports is not the number
anybody wants, and it will look better than the truth. **A run scored that way spends 17 to 25 hours of
GPU to produce an answer to a different question.**

WHAT "FAMILY" MEANS HERE, STATED PLAINLY BECAUSE THE FEASIBILITY DOC DID NOT DEFINE IT. That doc says
"split by commodity family". There is no family taxonomy in this estate: the 516 commodity ids in the
gold set are slugs, and every cheap heuristic over them is wrong somewhere. First-token grouping puts
`laundry-detergent` with `laundry-pods` correctly and then puts `zero-sugar-soda-2l` under `zero`.
Last-token grouping separates the laundry pair.

So this does the unambiguous, strictly stronger thing instead: **the unit of holdout is the whole
COMMODITY.** Every row for a held-out commodity goes to the test side, so that commodity is cold by
construction. It does NOT claim to have solved families, and it therefore MEASURES the residual risk
rather than asserting it away: it reports the held-out commodities whose slug shares a token with a
training commodity, which is where a near twin could still leak. That list is for a human to read
before trusting a result, and pretending it is empty would be the fabrication.

    python tools/local-llm/finetune-probe/split_holdout.py
    python tools/local-llm/finetune-probe/split_holdout.py --selftest
Exit 0 ok, 2 self-test failure, 3 no corpus to split (BLIND, never a pass).
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus.jsonl")
SEED = 20260909


def split_by_commodity(rows, holdout_frac=0.2, seed=SEED):
    """Assign whole commodities to train or holdout. Pure, deterministic given (rows, frac, seed).

    Returns (train, holdout, stats). The commodity is the unit, never the row: one product of a
    commodity landing in train while another lands in holdout is exactly the warm-test defect.
    """
    by_commodity = collections.defaultdict(list)
    for r in rows:
        by_commodity[str(r.get("commodity", ""))].append(r)
    names = sorted(by_commodity)                    # sorted first, so the seed alone decides
    rng = random.Random(seed)
    rng.shuffle(names)
    n_hold = max(1, int(round(len(names) * holdout_frac))) if names else 0
    hold_names = set(names[:n_hold])
    train, holdout = [], []
    for name in names:
        (holdout if name in hold_names else train).extend(by_commodity[name])
    stats = {
        "commodities_total": len(names),
        "commodities_holdout": len(hold_names),
        "rows_total": len(rows),
        "rows_train": len(train),
        "rows_holdout": len(holdout),
    }
    return train, holdout, stats


def leakage_report(train, holdout):
    """Held-out commodities sharing a slug token with a training commodity - where a near twin could
    still leak despite a commodity-level split. Reported, never silently tolerated."""
    def toks(name):
        return set(t for t in str(name).split("-") if len(t) > 2)

    train_tokens = collections.defaultdict(set)
    for r in train:
        c = str(r.get("commodity", ""))
        for t in toks(c):
            train_tokens[t].add(c)
    hits = []
    for c in sorted({str(r.get("commodity", "")) for r in holdout}):
        shared = {}
        for t in toks(c):
            if t in train_tokens:
                shared[t] = sorted(train_tokens[t])[:3]
        if shared:
            hits.append((c, shared))
    return hits


def containment_leaks(train, holdout):
    """The TIGHT leak test, and the one worth acting on.

    Token sharing is deliberately over-cautious: `black-pepper` shares 'black' with `black-olives` and
    that is not a leak. Containment is different in kind - when a held-out slug's tokens are a superset
    of a training slug's, the model has been trained on the more general thing and tested on a
    qualified version of it (`asparagus` in train, `canned-asparagus` held out). That is the case where
    a cold holdout is not really cold.
    """
    def toks(name):
        return frozenset(t for t in str(name).split("-") if t)

    train_sets = {}
    for r in train:
        c = str(r.get("commodity", ""))
        train_sets[c] = toks(c)
    out = []
    for c in sorted({str(r.get("commodity", "")) for r in holdout}):
        ct = toks(c)
        for tc, tt in train_sets.items():
            if tc == c or not tt:
                continue
            if tt < ct or ct < tt:
                out.append((c, tc))
    return out


def _selftest() -> int:
    bad = 0

    def T(name, ok, got=""):
        nonlocal bad
        if ok:
            print("  ok    " + name)
        else:
            print("  X     " + name + "   got: " + str(got))
            bad += 1

    rows = []
    for c in ["eggs-large", "eggs-medium", "jasmine-rice", "chili-beans", "hot-honey"]:
        for i in range(4):
            rows.append({"commodity": c, "product": "%s product %d" % (c, i), "label": "MATCH"})

    train, hold, stats = split_by_commodity(rows, holdout_frac=0.4)

    # MUST FIRE - the founding defect. A commodity must never appear on both sides, or the test set is
    # warm and the reported false-MATCH rate is better than the truth.
    tc = {r["commodity"] for r in train}
    hc = {r["commodity"] for r in hold}
    T("MUST FIRE  no commodity appears in BOTH train and holdout", not (tc & hc), sorted(tc & hc))

    T("every row is placed exactly once", len(train) + len(hold) == len(rows),
      "%d + %d vs %d" % (len(train), len(hold), len(rows)))
    T("the holdout is not empty", len(hold) > 0, len(hold))
    T("the stats carry their denominators",
      stats["rows_total"] == len(rows) and stats["commodities_total"] == 5, stats)

    # MUST FIRE - determinism. A split that moves between runs makes two results incomparable, and this
    # estate has been bitten by inputs shifting underneath a measurement before.
    t2, h2, _ = split_by_commodity(rows, holdout_frac=0.4)
    T("MUST FIRE  the same seed reproduces the same split exactly",
      [r["product"] for r in h2] == [r["product"] for r in hold], "the split moved between runs")
    t3, h3, _ = split_by_commodity(rows, holdout_frac=0.4, seed=SEED + 1)
    T("MUST NOT FIRE  a different seed gives a different split, so the seed is doing work",
      [r["product"] for r in h3] != [r["product"] for r in hold] or len(rows) < 4)

    # MUST FIRE - the leakage the commodity split does NOT solve, surfaced rather than assumed away.
    lk = leakage_report(train, hold)
    if "eggs-large" in hc or "eggs-medium" in hc:
        pass  # only assert when the pair straddles the split
    straddles = ("eggs-large" in hc) != ("eggs-medium" in hc)
    if straddles:
        T("MUST FIRE  a held-out commodity sharing a token with a training one is REPORTED",
          any(c.startswith("eggs") for c, _ in lk), lk)
    else:
        T("MUST NOT FIRE  with both eggs on one side there is no eggs leak to report",
          not any(c.startswith("eggs") for c, _ in lk), lk)

    # MUST NOT FIRE - an empty corpus does not crash and does not invent a split.
    e_t, e_h, e_s = split_by_commodity([], holdout_frac=0.2)
    T("MUST NOT FIRE  an empty corpus yields empty sides, not one invented row",
      e_t == [] and e_h == [] and e_s["rows_total"] == 0, e_s)

    # MUST FIRE - containment is the leak worth acting on, and it is a different test from token sharing.
    tr = [{"commodity": "asparagus"}, {"commodity": "black-olives"}]
    ho = [{"commodity": "canned-asparagus"}, {"commodity": "black-pepper"}]
    cl = containment_leaks(tr, ho)
    T("MUST FIRE  a held-out slug that CONTAINS a training slug is a containment leak",
      ("canned-asparagus", "asparagus") in cl, cl)
    T("MUST NOT FIRE  merely sharing a token is NOT a containment leak",
      not any(c == "black-pepper" for c, _ in cl), cl)

    # CLEAN TWIN - the behaviour grouping was most likely to break: every row keeps its own fields.
    T("CLEAN TWIN  a split row is unchanged, fields and all",
      all(set(r) == {"commodity", "product", "label"} for r in train + hold))

    if bad:
        print("split-holdout SELF-TEST FAIL (%d)" % bad)
        return 2
    print("split-holdout SELF-TEST PASS: 9 case(s) resolved")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--corpus", default=CORPUS)
    ap.add_argument("--holdout-frac", type=float, default=0.2)
    args = ap.parse_args()

    if args.selftest:
        return _selftest()

    if not os.path.exists(args.corpus):
        print("split-holdout: no corpus at %s - BLIND, not clean." % args.corpus)
        print("  Build it first: python tools/local-llm/finetune-probe/build_corpus.py")
        return 3

    rows = []
    with open(args.corpus, encoding="utf-8-sig") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    if not rows:
        print("split-holdout: the corpus is empty - BLIND, not clean.")
        return 3

    train, hold, stats = split_by_commodity(rows, holdout_frac=args.holdout_frac)
    for name, data in (("corpus-train.jsonl", train), ("corpus-holdout.jsonl", hold)):
        p = os.path.join(HERE, name)
        with open(p, "w", encoding="utf-8", newline="\n") as fh:
            for r in data:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")

    print("split-holdout: seed %d, holdout fraction %.2f" % (SEED, args.holdout_frac))
    print("  commodities: %d holdout of %d total (%.1f%%)"
          % (stats["commodities_holdout"], stats["commodities_total"],
             100.0 * stats["commodities_holdout"] / max(1, stats["commodities_total"])))
    print("  rows:        %d holdout of %d total (%.1f%%)"
          % (stats["rows_holdout"], stats["rows_total"],
             100.0 * stats["rows_holdout"] / max(1, stats["rows_total"])))
    print("  THE UNIT IS THE COMMODITY, not the row, so every holdout commodity is cold by construction.")

    lk = leakage_report(train, hold)
    print("  near-twin risk: %d of %d holdout commodit(ies) share a slug token with a training one"
          % (len(lk), stats["commodities_holdout"]))
    for c, shared in lk[:10]:
        first = sorted(shared)[0]
        print("    %-30s shares '%s' with %s" % (c, first, ", ".join(shared[first])))
    if len(lk) > 10:
        print("    ... and %d more" % (len(lk) - 10))

    cl = containment_leaks(train, hold)
    print("  CONTAINMENT leaks: %d pair(s) - the tight test, and the one worth acting on." % len(cl))
    for c, tc in cl[:12]:
        print("    holdout '%s' contains or is contained by training '%s'" % (c, tc))
    if len(cl) > 12:
        print("    ... and %d more" % (len(cl) - 12))
    print("  Token sharing is deliberately over-cautious ('black-pepper' shares 'black' with")
    print("  'black-olives' and that is not a leak). CONTAINMENT is the case where a cold holdout is")
    print("  not really cold, because the model saw the general thing and is tested on a qualified one.")
    print("  Both numbers are reported rather than assumed away; neither is a gate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
