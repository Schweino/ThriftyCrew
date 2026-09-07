r"""derive_coverage_floor.py - read the coverage prefilter off the data instead of choosing it.

    <sidecar venv>/python sidecar/derive_coverage_floor.py           # measure and write
    python sidecar/derive_coverage_floor.py --selftest              # pinned interpreter, no torch

BACKLOG I13 + I14, and the matcher-floor finding from E19.

I13 says every threshold in this estate is CHOSEN. I14 says the derivation technique it wants is
already in the repo, in the Python half: `harvest_embed.py` writes `catalog-similarity.json` with an
`ask_floor` READ off the labelled data - "the lowest max-cosine at which any of the 168 labelled
rejected-dupes sits, less a hair" - and states its basis in the artefact. This does the same thing for
`sweep.py`'s COVERAGE_COS_FLOOR, which is the one prefilter whose miss is unrecoverable.

WHY THAT FLOOR AND NOT ANOTHER. sweep.py's coverage lane takes products matching NO rule, finds each
one's BEST commodity by cosine, and reranks only those clearing 0.55. A product under the floor is
never reranked, so the cross-encoder - which aisle.py measured as the actual discriminator, separating
right from wrong by 4.4x where cosine manages 0.6% - never gets to see it. The floor's stated basis is
"set where Task C's true positives sat (0.58-0.69)". Measured 2026-09-07 against all 2,816 accepted
board pairs, true positives sit as low as **0.3948**, so that basis was drawn from too small a sample.

WHAT THIS DOES NOT CLAIM. The 2,816 accepted pairs are NOT the coverage lane's population - that lane
sees rule-invisible products, and these all match rules. A floor derived here is derived from the
right KIND of evidence (known-correct product-to-commodity pairs) on the wrong SLICE, and that is
stated in the artefact rather than glossed. It is strictly better than a number chosen from eight
observations, and it is not the same as a floor derived on the lane's own traffic.

THE CAP IS PART OF THE THRESHOLD. Lowering a prefilter costs cross-encoder calls, and sweep.py's
header records what an unbounded report does: the first full sweep returned 1,404 rows, "a firehose
nobody reads, and a guard nobody reads is worse than no guard". So this writes a floor AND a maximum
candidate count, and the consumer honours both.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
ARTEFACT = os.path.join(OUT, "coverage-floor.json")

# How far below the lowest observed true positive to sit. A floor exactly AT the minimum admits that
# one row and nothing softer, and the next unseen true positive is by definition lower than every one
# measured so far. harvest_embed.py uses the same "less a hair" reasoning for ask_floor.
HAIR = 0.01

# The compute bound. Not a tuning knob for precision - the cross-encoder floor does that - but the
# answer to "what does lowering the prefilter cost". Sized from sweep.py's own firehose note.
MAX_CANDIDATES = 1500


def derive(best_cosines_of_true_pairs, hair=HAIR):
    """(floor, basis) from the BEST-cosine of pairs a human has confirmed correct.

    Deliberately the minimum rather than a percentile: this is a RECALL floor, and the cost of setting
    it above a real pair is that the pair is never reranked and never appears in any report. A
    percentile would trade a known miss for a smaller number, which is the wrong direction for a
    prefilter whose whole job is to not lose things.
    """
    vals = [float(v) for v in (best_cosines_of_true_pairs or [])]
    if not vals:
        return None, "no labelled pair was scored, so no floor can be read off the data"
    lo = min(vals)
    floor = round(max(0.0, lo - hair), 4)
    return floor, ("the lowest BEST-cosine at which any of %d confirmed-correct pairs sits (%.4f), "
                   "less %.2f" % (len(vals), lo, hair))


def would_admit(best_cosines, floor, cap=MAX_CANDIDATES):
    """(admitted, capped) - how many rows a floor lets through, and whether the cap binds.

    Returned together on purpose: a floor without its volume is half a decision, and the estate has
    already been bitten by a guard that admitted 1,404 rows nobody read.
    """
    vals = sorted((float(v) for v in (best_cosines or [])), reverse=True)
    over = [v for v in vals if v >= floor]
    return min(len(over), cap), len(over) > cap


def selftest():
    fails = []

    def T(name, cond, got=""):
        if cond:
            print("  ok    %s" % name)
        else:
            print("  X     %s   got: %s" % (name, got))
            fails.append(name)

    f, why = derive([0.90, 0.72, 0.3948, 0.61])
    T("the floor is read off the LOWEST confirmed-correct pair", abs(f - 0.3848) < 1e-9, f)
    T("the basis travels with the number", "lowest BEST-cosine" in why, why)

    # MUST FIRE: the founding case. 0.55 was chosen from eight observations in the 0.58-0.69 band; a
    # real pair at 0.3948 sits under it and is never reranked.
    f, _ = derive([0.58, 0.62, 0.69])
    T("MUST FIRE  a floor derived from a narrow sample sits ABOVE a real pair outside it",
      f > 0.3948, f)
    f2, _ = derive([0.58, 0.62, 0.69, 0.3948])
    T("CLEAN TWIN  adding that pair to the evidence pulls the floor below it", f2 < 0.3948, f2)

    f, why = derive([])
    T("no evidence returns no floor rather than a default", f is None, f)
    T("and says why", "no floor can be read" in why, why)

    f, _ = derive([0.005])
    T("a floor cannot go negative", f >= 0.0, f)

    n, capped = would_admit([0.9, 0.8, 0.7, 0.2], 0.55)
    T("volume is reported beside the floor", n == 3 and not capped, "%s/%s" % (n, capped))
    n, capped = would_admit([0.9] * 5000, 0.55, cap=1500)
    T("MUST FIRE  the cap binds and SAYS it bound, rather than silently truncating",
      n == 1500 and capped, "%s/%s" % (n, capped))
    n, capped = would_admit([], 0.55)
    T("an empty population admits nothing without dividing by zero", n == 0 and not capped)

    if fails:
        print("SELF-TEST FAIL: %d case(s)" % len(fails))
        return 1
    print("SELF-TEST PASS: the floor is read off the lowest confirmed pair, a narrow sample is shown to "
          "sit above a real one, and the volume cap reports that it bound")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--defs", default=None)
    ap.add_argument("--write", action="store_true", help="write sidecar/out/coverage-floor.json")
    a = ap.parse_args([x for x in sys.argv[1:] if x != "--run"])

    import torch                                               # noqa: PLC0415,F401
    from lib_match import Matcher, clean_product, commodity_text  # noqa: PLC0415

    defs_path = a.defs or os.path.join(HERE, "data", "commodity-defs.json")
    with io.open(defs_path, encoding="utf-8-sig") as f:
        defs = json.load(f)
    with io.open(os.path.join(HERE, "data", "eval-positives.json"), encoding="utf-8-sig") as f:
        pos = json.load(f)
    by_id = {d["id"] for d in defs}
    rows = [r for r in pos if r.get("id") in by_id and (r.get("product") or "").strip()]
    print("confirmed-correct pairs: %d   commodities: %d" % (len(rows), len(defs)))
    if not rows:
        print("COULD NOT EVALUATE: no confirmed pair resolved to a commodity definition.")
        return 3

    m = Matcher.load(with_reranker=False)
    cvecs = m.embed([commodity_text(d) for d in defs])
    pvecs = m.embed([clean_product(r["product"]) for r in rows])
    sims = pvecs @ cvecs.T
    best = [float(v) for v in sims.max(dim=1).values]

    floor, basis = derive(best)
    admitted, capped = would_admit(best, floor)
    print("")
    print("derived floor : %.4f" % floor)
    print("basis         : %s" % basis)
    print("on THIS population it admits %d of %d%s"
          % (admitted, len(best), " (capped)" if capped else ""))
    print("")
    print("NOT the coverage lane's own population: that lane sees products matching NO rule, and these")
    print("all match rules. Right KIND of evidence, wrong slice - recorded in the artefact, not glossed.")

    doc = {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "coverage_cos_floor": floor,
        "basis": basis,
        "hair": HAIR,
        "max_candidates": MAX_CANDIDATES,
        "derived_from": {"file": "eval-positives.json", "pairs": len(rows), "defs": os.path.basename(defs_path)},
        "previous_chosen_value": 0.55,
        "previous_basis": "set where Task C's true positives sat (0.58-0.69) - eight observations",
        "CAVEAT": "Derived from ACCEPTED BOARD PAIRS, which all match rules. sweep.py's coverage lane "
                  "sees rule-invisible products, so this is the right kind of evidence on the wrong "
                  "slice. It is strictly better than a number chosen from eight observations and it is "
                  "NOT a floor measured on the lane's own traffic. Read it as such.",
        "NOT_APPLIED": "sweep.py still uses its own constant. Applying this changes a live daily "
                       "auditor's behaviour and wants the volume measured on the real unmatched "
                       "population first.",
    }
    if a.write:
        os.makedirs(OUT, exist_ok=True)
        with io.open(ARTEFACT, "w", encoding="utf-8", newline="\n") as f:
            json.dump(doc, f, indent=2, ensure_ascii=False)
        print("wrote %s" % ARTEFACT)
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
