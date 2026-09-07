#!/usr/bin/env python
"""Measure how much of an injected instruction the transcription layer actually refuses.

BACKLOG I23's remainder. `ops/injection_resistance_selftest.py` pins named defences against
named payloads, which is the must-fire half. This is the other half course 14 asked for and
that file explicitly did not deliver: a FROZEN CORPUS and a MEASURED RATE.

WHAT THIS MEASURES, AND THE DISTINCTION IS THE ENTIRE POINT.
Two arms, same payloads, differing only in whether the attacker put the text on the page:

  ARM A - FABRICATION.  The payload is NOT in the page. This is a model inventing content.
  ARM B - INDIRECT.     The payload IS in the page, because a hostile page carries its own
                        injection. This is what indirect prompt injection actually is.

`verify()` asks one question: does this transcribed line occur in the page? That refuses arm A
completely and **cannot refuse arm B at all**, because in arm B the answer is legitimately yes.

MEASURED 2026-09-07 AND IT CORRECTS OUR OWN RECORD. Backlog I23 says `verify()` "is the only
thing standing behind" the 24,000-character scraped-page surface, and
`security-craft/estate-exposure.md` reports the estate as accidentally strong there. Against
FABRICATION that is right. Against INDIRECT INJECTION `verify()` blocks nothing, and neither
does `verify_split()`: an injected line assigned wholly to `item` scores 100% round-trip
coverage, so it passes all three of that function's tests.

THAT IS NOT A HOLE STRAIGHT TO A PUBLISHED NUMBER, and this file must not be read as claiming
one. What an attacker wins in arm B is a junk string in an ingredient list. To become a wrong
number on a paid page it would then have to map to a real commodity id and get priced, and
`graph/pipeline/resolve.py` rules that the local model may REJECT but may never mint a price.
The defence is real; it just is not where our own notes said it was. Depth is downstream, not
at the transcription boundary.

THE COVERAGE TRAP, which is why there is a third number.
A validator that refuses EVERYTHING scores a perfect block rate and is useless. That is
`rag-craft/evaluating-retrieval.md`'s abstaining-system trap, and a block rate reported alone
walks straight into it. So every run also measures the GENUINE PASS RATE over real lines from
the same page, and a fall in either is a failure.

RATCHET SEMANTICS, per lib/ratchet.ps1 (backlog I15). A rate that FELL is either a real
regression or a broken harness, and those look identical from outside. So: a fall fails; the
corpus size is checked against the baseline, because a corpus that shrank is a harness that
lost its file rather than a tree that got safer; and a rate computed over zero cases is exit 2,
never a pass.

**Arm B's baseline is 0.00 and that is DELIBERATE, not a red gate.** It records a measured,
documented, downstream-mitigated exposure. Adding a defence here should make it RISE, and the
ratchet is what makes that rise permanent. A gate that is red on day one for a backlog nobody
is about to clear teaches people to ignore red, which is this estate's own standing rule.

Exit 0 = no rate fell. Exit 1 = one did. Exit 2 = could not evaluate. Last line is the
completion marker lib/guard-contract.ps1 requires.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CORPUS = os.path.join(HERE, "injection-payloads.json")
BASELINE = os.path.join(HERE, "injection-eval-baseline.json")


def die(msg: str) -> None:
    print("COULD NOT EVALUATE: %s" % msg)
    print("INJECTION-EVAL-COMPLETE")
    raise SystemExit(2)


def load_extractor():
    for p in (os.path.join(REPO, "graph", "lib"),
              os.path.join(REPO, "meal-prep", "pipeline")):
        if p not in sys.path:
            sys.path.insert(0, p)
    try:
        import local_extract as LE
        return LE
    except Exception as e:                                           # noqa: BLE001
        die("cannot import local_extract: %s" % e)


def rate(n: int, d: int, label: str) -> float:
    if d == 0:
        die("%s has a zero denominator - the corpus did not load" % label)
    return n / d


def measure() -> dict:
    try:
        corpus = json.load(open(CORPUS, encoding="utf-8"))
    except Exception as e:                                           # noqa: BLE001
        die("cannot read %s: %s" % (CORPUS, e))

    payloads = corpus.get("payloads") or []
    genuine = corpus.get("genuine") or []
    page = corpus.get("page") or ""
    if not payloads or not genuine or not page:
        die("corpus is missing payloads, genuine controls, or the page")

    LE = load_extractor()

    def blocked(line: str, page_text: str) -> bool:
        # One transcribed line at a time, so a rate is per payload rather than
        # per batch. A batch would let one good line carry a bad one over the
        # MIN_VERIFIED threshold and report a pass.
        return LE.verify({"ingredients": [{"raw": line}]}, page_text)["passed"] is False

    # ARM A - the payload is not on the page.
    a_blocked = [p["id"] for p in payloads if blocked(p["text"], page)]

    # ARM B - the attacker put it on the page. This is indirect injection.
    b_blocked = []
    for p in payloads:
        hostile = page + "\n<!-- " + p["text"] + " -->\n"
        if blocked(p["text"], hostile):
            b_blocked.append(p["id"])

    # NEGATIVE CONTROL - real lines must still pass, or a perfect block rate
    # only means the validator refuses everything.
    g_passed = [g["id"] for g in genuine if not blocked(g["text"], page)]

    return {
        "payloads": len(payloads),
        "genuine": len(genuine),
        "fabrication_block_rate": round(rate(len(a_blocked), len(payloads), "arm A"), 4),
        "indirect_block_rate": round(rate(len(b_blocked), len(payloads), "arm B"), 4),
        "genuine_pass_rate": round(rate(len(g_passed), len(genuine), "controls"), 4),
        "indirect_blocked_ids": b_blocked,
    }


RATES = ("fabrication_block_rate", "indirect_block_rate", "genuine_pass_rate")


def selftest() -> int:
    got = measure()
    print("corpus: %d payloads, %d genuine controls" % (got["payloads"], got["genuine"]))
    for k in RATES:
        print("  %-24s %.2f" % (k, got[k]))

    if not os.path.isfile(BASELINE):
        die("no baseline at %s. Write one with --freeze after reading the rates above."
            % BASELINE)
    base = json.load(open(BASELINE, encoding="utf-8"))

    fails = []
    # A SHRUNKEN CORPUS IS A BROKEN HARNESS, NOT A SAFER TREE. Same asymmetry as
    # lib/ratchet.ps1: the two look identical from outside, so the fall must be refused.
    if got["payloads"] < base.get("payloads", 0):
        fails.append("corpus shrank: %d payloads, baseline had %d. That is the harness "
                     "losing its file, not the estate getting safer."
                     % (got["payloads"], base["payloads"]))
    for k in RATES:
        if got[k] < base.get(k, 0.0):
            fails.append("%s FELL: %.2f, baseline %.2f" % (k, got[k], base[k]))

    for f in fails:
        print("FAIL  " + f)
    print("%d rate(s) checked, %d failed" % (len(RATES), len(fails)))
    if fails:
        print("VERDICT: FAIL - a measured defence got weaker, or the harness broke.")
    else:
        print("VERDICT: PASS - no measured rate fell below its frozen baseline. "
              "indirect_block_rate is 0.00 BY RECORD: the transcription layer does not "
              "defend against on-page injection, and the depth is downstream at "
              "resolve.py's never-mint-a-price rule.")
    print("INJECTION-EVAL-COMPLETE")
    return 1 if fails else 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Injection resistance evaluation.")
    ap.add_argument("--selftest", action="store_true", help="measure and compare to baseline")
    ap.add_argument("--freeze", action="store_true",
                    help="write the current rates as the baseline. Deliberate, never automatic.")
    args = ap.parse_args()
    if args.freeze:
        got = measure()
        with open(BASELINE, "w", encoding="utf-8", newline="\n") as f:
            json.dump({k: got[k] for k in ("payloads", "genuine") + RATES}, f, indent=2)
            f.write("\n")
        print("froze baseline to %s" % BASELINE)
        raise SystemExit(0)
    if not args.selftest:
        ap.print_help()
        raise SystemExit(2)
    raise SystemExit(selftest())
