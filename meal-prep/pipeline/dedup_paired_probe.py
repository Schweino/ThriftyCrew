r"""The SAME candidates ruled twice, with and without the neighbour block (backlog I48).

WHY A WITHIN-PAIRS DESIGN, and it is the whole point of this file.
`design/EVAL-dedup-shortlist-2026-09-04.md` measured "output tokens per candidate ruled" across two
RUNS and found the comparison confounded: the run selects its own denominator. Between the two arms
the duplicate mix moved from 32% to 53% because the BAND moved, and a decider facing more duplicates
writes more rejections and fewer acceptances, which cost different amounts. Per candidate the second
arm got dearer; per dupe rejection it got cheaper. Neither number could be attributed to the
neighbour evidence, and MORE DATA OF THE SAME SHAPE WOULD NOT HAVE HELPED - the defect was in the
design, not the sample size.

Running the same units through both arms removes that confounding by construction rather than
modelling it away. `meal-prep/pipeline/extractor_model_probe.py` is this estate's other worked example
and its docstring gives the same reason: scoring a new model against stored transcriptions "would
confound a model difference with a page edit".

WHAT THE ARMS ARE, stated exactly, because "without the neighbour block" has two honest readings.
  with     - the dossier as `harvest.build_dossier` produces it today.
  without  - neighbours AND `catalog_checked` both removed. That is the state the estate was actually
             in before the evidence existed, and it is what the 152 recorded dupe rejections were
             ruled from. `catalog_checked` goes too because harvest.py's own comment says an empty
             neighbour block without it makes "no neighbours" and "nobody looked" the same bytes.
  --keep-catalog-checked runs the OTHER contrast: evidence removed but the search still declared. That
             isolates the evidence from the did-anyone-look signal, which is a different question, so
             it is a flag rather than a silent choice.

THE ACCEPTANCE BARS ARE WRITTEN HERE, BEFORE ANY DECIDER HAS RUN, and there are two in a fixed order.

  BAR 1, SAFETY, and it is read FIRST: the two arms must agree on the VERDICT for at least
  AGREEMENT_BAR of pairs. If the arms rule differently, the question is not cost at all - a cheaper
  arm that reaches different answers is not cheaper, it is different, and comparing its token count
  to the other's is comparing two different jobs.

  BAR 2, COST, and it is read ONLY if bar 1 holds: the median PAIRED reduction in decider output
  tokens must be at least TOKEN_BAR to call the evidence worth carrying.

Both numbers are stated below with what would have to be true for them to be wrong, because a
threshold chosen after seeing the data is not a threshold, it is a description of a decision already
taken.

WHAT THIS FILE CAN AND CANNOT DO. It can freeze a case set, emit both arms' dossiers, and score the
returned verdicts. It CANNOT make the decider calls: those are dispatched Opus runs. So `--emit`
produces the two arms and `--score` reads them back, and `--score` with nothing to read exits 3 and
says BLIND rather than reporting a clean zero.

    python meal-prep/pipeline/dedup_paired_probe.py --emit --n 20
    ... dispatch each arm's dossiers to the dedup selector, save its verdicts beside them ...
    python meal-prep/pipeline/dedup_paired_probe.py --score
    python meal-prep/pipeline/dedup_paired_probe.py --selftest

Exit 0 = emitted or scored. 2 = a bar was missed. 3 = could not evaluate (never read that as ok).
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import io
import json
import os
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
REPO = os.path.dirname(MP)
sys.path.insert(0, HERE)

OUT_DIR = os.path.join(MP, "db", "dedup-paired")
CASES = os.path.join(OUT_DIR, "cases.jsonl")          # one row per case per arm
VERDICTS = os.path.join(OUT_DIR, "verdicts.jsonl")    # one row per case per arm, filled by the run
REPORT = os.path.join(OUT_DIR, "report.json")

EXIT_OK, EXIT_BAR_MISSED, EXIT_BLIND = 0, 2, 3

# ---------------------------------------------------------------------------------------------
# BAR 1. Verdict agreement, read first.
#
# 0.90 is chosen from the estate's own record rather than from taste: every one of the 152 dupe
# rejections it has ever made was of a candidate carrying NO neighbour evidence, so the evidence has
# never yet been observed to change a verdict - only, allegedly, the cost of reaching it. A design
# whose premise is "same answer, cheaper" should hold agreement far above 0.90; setting it there
# leaves room for the decider's own run-to-run variance without leaving room for a real behavioural
# difference. IF THIS BAR FAILS, BAR 2 IS NOT READ, and the finding is that the evidence changes
# WHAT is decided, which is a bigger and more interesting result than any token count.
AGREEMENT_BAR = 0.90

# BAR 2. Median paired reduction in decider output tokens.
#
# 0.20 is derived, not picked. The 2026-09-04 run measured the decider writing on the order of 1,000
# output tokens per candidate, and roughly 8,000 on a dupe rejection derived from scratch. On a pool
# whose duplicate share sat between 32% and 53%, evidence that removes the from-scratch derivation on
# duplicates alone moves the median by more than a fifth. Below that the evidence is not paying for
# the embedding index and the rescoring pass that produce it.
TOKEN_BAR = 0.20

MIN_PAIRS = 12   # below this the median is a rumour; --score says BLIND rather than reporting one


def _read_json(path):
    with io.open(path, encoding="utf-8-sig") as fh:
        return json.load(fh)


def strip_neighbours(dossier, keep_catalog_checked=False):
    """Arm B's dossier: the same candidate with its neighbour evidence removed.

    A COPY, never a mutation of the caller's object - the two arms must differ in exactly the field
    under test and in nothing else, and an in-place edit would silently make arm A into arm B.
    """
    d = copy.deepcopy(dossier)
    d["neighbours"] = []
    if not keep_catalog_checked:
        d.pop("catalog_checked", None)
    return d


def fingerprint(rows, extra=""):
    """What this case set was built from. A result whose inputs are not recorded disagreed with
    itself across two runs once already (backlog E-series, the dedup probe)."""
    h = hashlib.sha256()
    for r in sorted(rows, key=lambda x: x.get("slug", "")):
        h.update((r.get("slug", "") + "|").encode("utf-8"))
    h.update(("|" + extra).encode("utf-8"))
    return h.hexdigest()[:16]


def emit(n, keep_catalog_checked=False, out_dir=OUT_DIR, pool_path=None):
    """Freeze a case set and write BOTH arms. Returns (path, pairs)."""
    import harvest                                                # noqa: E402

    pool = harvest.read_pool(pool_path) if pool_path else harvest.read_pool()
    avail = [c for c in pool["candidates"] if c.get("status") == "available"]
    # THE SAME POP ORDER THE DAEMON USES. A case set drawn in a different order than production would
    # measure a different population than the one the decider actually sees.
    avail.sort(key=harvest.dossier_rank)
    picked = avail[:max(1, n)]
    if not picked:
        return None, 0
    catalog_n = harvest.catalog_size()

    if not os.path.isdir(out_dir):
        os.makedirs(out_dir)
    fp = fingerprint(picked, extra="keep_cc=%s" % bool(keep_catalog_checked))
    path = os.path.join(out_dir, "cases.jsonl")
    now = time.strftime("%Y-%m-%dT%H:%M:%S")
    with io.open(path, "w", encoding="utf-8", newline="\n") as fh:
        for c in picked:
            full = harvest.build_dossier(c, catalog_n)
            for arm, doss in (("with", full),
                             ("without", strip_neighbours(full, keep_catalog_checked))):
                fh.write(json.dumps({
                    "case": c["slug"], "arm": arm, "generated": now, "input_fingerprint": fp,
                    "n_neighbours": len(doss.get("neighbours") or []),
                    "dossier": doss,
                }) + "\n")
    return path, len(picked)


def load_verdicts(path=VERDICTS):
    """[{case, arm, verdict, output_tokens}] - whatever the dispatched run wrote back."""
    rows = []
    if not os.path.isfile(path):
        return rows
    with io.open(path, encoding="utf-8-sig") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except ValueError:
                continue
    return rows


def pair_up(rows):
    """Only cases present in BOTH arms. A case ruled in one arm and not the other is not a pair, and
    silently keeping it is how a paired design decays back into a between-runs one."""
    by = {}
    for r in rows:
        by.setdefault(r.get("case"), {})[r.get("arm")] = r
    return [(c, v["with"], v["without"]) for c, v in sorted(by.items())
            if "with" in v and "without" in v]


def score(rows, agreement_bar=AGREEMENT_BAR, token_bar=TOKEN_BAR, min_pairs=MIN_PAIRS):
    """The verdict, as a dict. Pure, so the fixtures can drive it exactly."""
    pairs = pair_up(rows)
    unpaired = len(set(r.get("case") for r in rows)) - len(pairs)
    if len(pairs) < min_pairs:
        return {"state": "BLIND", "pairs": len(pairs), "unpaired": unpaired,
                "min_pairs": min_pairs}

    agree = sum(1 for _, a, b in pairs
                if str(a.get("verdict", "")).upper() == str(b.get("verdict", "")).upper())
    rate = float(agree) / len(pairs)
    out = {"state": "OK", "pairs": len(pairs), "unpaired": unpaired,
           "agreement": rate, "agreement_bar": agreement_bar,
           "agreed": agree}

    if rate < agreement_bar:
        # BAR 1 FAILED. Bar 2 is NOT computed, and that is deliberate: comparing the token cost of two
        # arms that reach different answers compares two different jobs.
        out["state"] = "VERDICTS DIFFER"
        return out

    deltas = []
    for c, a, b in pairs:
        wa, wb = a.get("output_tokens"), b.get("output_tokens")
        if isinstance(wa, (int, float)) and isinstance(wb, (int, float)) and wb > 0:
            deltas.append((wb - wa) / float(wb))     # positive = the evidence arm wrote LESS
    if len(deltas) < min_pairs:
        out["state"] = "BLIND ON TOKENS"
        out["token_pairs"] = len(deltas)
        return out
    med = statistics.median(deltas)
    out["token_pairs"] = len(deltas)
    out["median_reduction"] = med
    out["token_bar"] = token_bar
    out["state"] = "EVIDENCE PAYS" if med >= token_bar else "EVIDENCE DOES NOT PAY"
    return out


def render(v):
    lines = []
    if v["state"] == "BLIND":
        lines.append("dedup-paired: BLIND - %d complete pair(s), under the %d needed to state a median. "
                     "%d case(s) are present in only one arm." % (v["pairs"], v["min_pairs"], v["unpaired"]))
        return lines
    lines.append("dedup-paired: %d complete pair(s), %d case(s) in only one arm"
                 % (v["pairs"], v["unpaired"]))
    lines.append("  BAR 1 (read first)  verdict agreement %d of %d = %.2f  against a bar of %.2f"
                 % (v["agreed"], v["pairs"], v["agreement"], v["agreement_bar"]))
    if v["state"] == "VERDICTS DIFFER":
        lines.append("  VERDICT: THE ARMS RULE DIFFERENTLY. Bar 2 is deliberately NOT read - a cheaper arm")
        lines.append("  that reaches different answers is not cheaper, it is different. The finding is about")
        lines.append("  ACCURACY, not cost, and it is the more interesting one.")
        return lines
    if v["state"] == "BLIND ON TOKENS":
        lines.append("  BLIND ON TOKENS - only %d pair(s) carry an output-token count on both sides"
                     % v.get("token_pairs", 0))
        return lines
    lines.append("  BAR 2 (cost)        median paired reduction %.1f%% over %d pair(s)  against a bar of %.0f%%"
                 % (100.0 * v["median_reduction"], v["token_pairs"], 100.0 * v["token_bar"]))
    lines.append("  VERDICT: %s" % v["state"])
    return lines


def selftest():
    bad = []

    def T(label, name, ok, got=""):
        if not ok:
            bad.append(name)
        print("  %-14s %-62s %s" % (label, name, "ok" if ok else "FAIL " + str(got)))

    # MUST FIRE: the founding defect. A between-runs comparison cannot see this and a paired one can -
    # the arms agree on every verdict and the evidence arm writes a third fewer tokens.
    rows = []
    for i in range(20):
        rows.append({"case": "c%d" % i, "arm": "with", "verdict": "ACCEPT", "output_tokens": 600})
        rows.append({"case": "c%d" % i, "arm": "without", "verdict": "ACCEPT", "output_tokens": 900})
    v = score(rows)
    T("MUST FIRE", "a real 33% paired saving clears the cost bar",
      v["state"] == "EVIDENCE PAYS" and abs(v["median_reduction"] - (1.0 / 3)) < 1e-9, v)

    # MUST NOT FIRE: a saving under the bar is not a saving worth carrying, and the bar was written
    # into this file before any decider ran.
    rows2 = []
    for i in range(20):
        rows2.append({"case": "c%d" % i, "arm": "with", "verdict": "ACCEPT", "output_tokens": 950})
        rows2.append({"case": "c%d" % i, "arm": "without", "verdict": "ACCEPT", "output_tokens": 1000})
    T("MUST NOT FIRE", "a 5% saving does NOT clear the 20% bar",
      score(rows2)["state"] == "EVIDENCE DOES NOT PAY", score(rows2))

    # MUST FIRE: bar 1 comes first, and a token count is not read past it.
    rows3 = []
    for i in range(20):
        rows3.append({"case": "c%d" % i, "arm": "with",
                      "verdict": "ACCEPT" if i % 2 else "REJECT", "output_tokens": 100})
        rows3.append({"case": "c%d" % i, "arm": "without", "verdict": "ACCEPT", "output_tokens": 5000})
    v3 = score(rows3)
    T("MUST FIRE", "arms that rule differently report DISAGREEMENT, not a saving",
      v3["state"] == "VERDICTS DIFFER" and "median_reduction" not in v3, v3)

    # BLIND, never clean: too few pairs is a refusal to state a median, not a zero.
    T("MUST FIRE", "under the pair floor it is BLIND rather than a clean zero",
      score(rows[:6])["state"] == "BLIND", score(rows[:6]))
    T("MUST FIRE", "an empty verdict file is BLIND, never 'no difference'",
      score([])["state"] == "BLIND")

    # MUST NOT FIRE: a case ruled in one arm only is not a pair.
    half = [{"case": "solo", "arm": "with", "verdict": "ACCEPT", "output_tokens": 1}]
    T("MUST NOT FIRE", "a case present in one arm only is not counted as a pair",
      len(pair_up(half)) == 0 and score(rows + half)["unpaired"] == 1, score(rows + half))

    # CLEAN TWIN: the arm-B transform touches the field under test and nothing else.
    src = {"slug": "s", "name": "n", "neighbours": [{"a": 1}], "catalog_checked": {"x": 1},
           "band": {"cal": 500}, "signature": {"protein": "chicken"}}
    b = strip_neighbours(src)
    T("CLEAN TWIN", "arm B differs in the neighbour block and nothing else",
      b["neighbours"] == [] and "catalog_checked" not in b
      and b["band"] == src["band"] and b["signature"] == src["signature"], b)
    T("MUST NOT FIRE", "building arm B does not mutate arm A",
      src["neighbours"] == [{"a": 1}] and "catalog_checked" in src, src)
    T("CLEAN TWIN", "--keep-catalog-checked leaves the search declaration in place",
      "catalog_checked" in strip_neighbours(src, True))

    # The fingerprint has to move when the case set does, or two different runs read as one.
    T("MUST FIRE", "the input fingerprint changes when the case set changes",
      fingerprint([{"slug": "a"}]) != fingerprint([{"slug": "b"}]))
    T("MUST NOT FIRE", "the fingerprint is stable under row ORDER",
      fingerprint([{"slug": "a"}, {"slug": "b"}]) == fingerprint([{"slug": "b"}, {"slug": "a"}]))

    print("")
    if bad:
        print("dedup-paired SELF-TEST: %d FAILED of %d" % (len(bad), len(bad) + 10))
        print("DEDUP-PAIRED-COMPLETE selftest failed=%d" % len(bad))
        return 1
    print("dedup-paired SELF-TEST PASS (11 cases)")
    print("DEDUP-PAIRED-COMPLETE selftest ok")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--emit", action="store_true", help="freeze a case set and write both arms")
    ap.add_argument("--score", action="store_true", help="read the returned verdicts back")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--n", type=int, default=20, help="candidates (pairs), not rows")
    ap.add_argument("--keep-catalog-checked", action="store_true",
                    help="arm B keeps the search declaration - a DIFFERENT contrast, see the header")
    a = ap.parse_args(argv)

    if a.selftest:
        return selftest()

    if a.emit:
        path, pairs = emit(a.n, a.keep_catalog_checked)
        if not path:
            print("dedup-paired: BLIND - the pool holds no available candidate to draw a case set from")
            print("DEDUP-PAIRED-COMPLETE emit=0")
            return EXIT_BLIND
        print("dedup-paired: %d pair(s) = %d dossier row(s) -> %s" % (pairs, pairs * 2, path))
        print("  arm 'with'    : the dossier as harvest.build_dossier produces it")
        print("  arm 'without' : neighbours%s removed"
              % ("" if a.keep_catalog_checked else " AND catalog_checked"))
        print("  Dispatch each arm to the dedup selector and write one row per case per arm to")
        print("  %s as {case, arm, verdict, output_tokens}." % VERDICTS)
        print("DEDUP-PAIRED-COMPLETE emit=%d" % pairs)
        return EXIT_OK

    if a.score:
        rows = load_verdicts()
        v = score(rows)
        for line in render(v):
            print(line)
        if not os.path.isdir(OUT_DIR):
            os.makedirs(OUT_DIR)
        with io.open(REPORT, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(v, indent=2))
        print("DEDUP-PAIRED-COMPLETE pairs=%d state=%s" % (v["pairs"], v["state"]))
        if v["state"].startswith("BLIND"):
            return EXIT_BLIND
        if v["state"] in ("VERDICTS DIFFER", "EVIDENCE DOES NOT PAY"):
            return EXIT_BAR_MISSED
        return EXIT_OK

    ap.print_help()
    return EXIT_BLIND


if __name__ == "__main__":
    raise SystemExit(main())
