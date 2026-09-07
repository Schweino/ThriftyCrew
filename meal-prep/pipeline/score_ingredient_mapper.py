r"""score_ingredient_mapper.py - a scored test set for the ingredient vocabulary matcher.

    python meal-prep/pipeline/score_ingredient_mapper.py            # build the set and score
    python meal-prep/pipeline/score_ingredient_mapper.py --selftest # hermetic

WHY THIS EXISTS (2026-09-07, backlog E19's open half). E19's point is that every retrieval-shaped
component here is changed on the strength of "it fixed the case I was looking at", with no held-out
set scored the same way before and after - so no change has ever been shown to help. The matcher and
the dedup pipeline have sets now. This is the third, for the component E19 names first: the
ingredient vocabulary matcher, whose errors reach a PRICE on a live page.

THE QUERY IS WHAT THE MATCHER ACTUALLY RECEIVES, and getting that wrong would have made this
worthless in the flattering direction's opposite. The mapped files carry `source_raw` - the page's
whole line, "16 ounces cauliflower chopped into macaroni sized pieces" - and scoring on that returns
GENUINE-GAP with zero candidates. But production never hands the matcher a raw line: the extractor
resolves the noun first, and the matcher sees "Cauliflower". Scoring a component on an input it never
sees is the mirror image of E23's bias and produces a falsely terrible number instead of a falsely
good one. So the pairs are built by JOINING `<run>/extracted/*.json` to `<run>/mapped/*.json` on the
raw line, which yields (what the matcher is asked) -> (what it should answer).

ONE INVOCATION, NOT ONE PER NAME. `ingredient-vocab.ps1 -Missing <file> -Json` classifies a whole
batch, which is the road map-preresolve uses and the reason its header says "ONE ingredient-vocab".
Re-implementing the head-noun rule here would be the forked-taxonomy defect this estate has scars
from.

THE CORPUS IS SUCCESS-DERIVED AND THAT IS STATED, NOT HIDDEN (backlog E23). Every pair comes from a
line that WAS mapped, so the ceiling this measures is "how often does the matcher retrieve an answer
it has already been shown to be capable of retrieving". Lines that failed to map are not in it, and
their absence is invisible in the score. This is an UPPER BOUND and the report says so on every run.

ABSTENTION IS COUNTED, NEVER DROPPED (backlog E20). A matcher that returns nothing on its hard names
and is scored only on the ones it answered outscores one that attempts everything. Zero-candidate
names are reported as their own number beside the recall figures.

IT SCORES AND DOES NOT TUNE. Nothing about the matcher changes here, or the measurement would be a
description of a decision already taken.

Exit 0 = scored. 3 = could not build a set or could not run the matcher.
"""
from __future__ import annotations

import argparse
import io
import json
import glob
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
RUNS = os.path.join(REPO, "meal-prep", "runs")
VOCAB_PS = os.path.join(HERE, "ingredient-vocab.ps1")
OUT = os.path.join(REPO, "meal-prep", "db", "mapper-eval-cases.jsonl")

EXIT_CLEAN, EXIT_CANNOT_RUN = 0, 3

# Only decisions that assert a canon name. A hold, an omission or a registrar-pending row is not a
# label - treating one as ground truth would score the matcher against a question nobody answered.
MAPPED = ("mapped", "mapped-optional", "mapped-precedent", "mapped-with-conflict")


def build_pairs(runs_dir):
    """(query, correct) from the extracted -> mapped join, plus why rows were skipped.

    The join key is the RAW line, because that is the only field both sides carry. Returns
    (pairs, skipped) where skipped counts reasons - a pair set with no skip reasons is a pair set
    nobody can check.
    """
    pairs, skipped = [], {}

    def skip(why):
        skipped[why] = skipped.get(why, 0) + 1

    for mp in sorted(glob.glob(os.path.join(runs_dir, "*", "mapped", "*.json"))):
        ep = mp.replace(os.sep + "mapped" + os.sep, os.sep + "extracted" + os.sep)
        if not os.path.exists(ep):
            skip("no extracted twin for the mapped file")
            continue
        try:
            m = json.load(io.open(mp, encoding="utf-8-sig"))
            e = json.load(io.open(ep, encoding="utf-8-sig"))
        except Exception:                                          # noqa: BLE001
            skip("a file did not parse")
            continue
        by_raw = {}
        for row in (e.get("ingredients") or []):
            if isinstance(row, dict) and row.get("raw"):
                by_raw[str(row["raw"]).strip()] = str(row.get("item") or "").strip()
        for row in (m.get("ingredients") or []):
            if not isinstance(row, dict):
                continue
            if str(row.get("decision") or "") not in MAPPED:
                skip("decision is not a mapping: " + str(row.get("decision")))
                continue
            canon = str(row.get("item") or "").strip()
            raw = str(row.get("source_raw") or "").strip()
            q = by_raw.get(raw, "")
            if not q:
                skip("no extractor noun for this raw line")
                continue
            if not canon:
                skip("mapped row states no canon item")
                continue
            pairs.append((q, canon))
    return pairs, skipped


def rank_of(correct, candidates):
    """1-based rank of the correct item, or None when it is not in the list at all."""
    for i, c in enumerate(candidates, 1):
        if str(c).strip().lower() == str(correct).strip().lower():
            return i
    return None


def score(results, gold, ks=(1, 5, 25)):
    """recall@k, MRR and the ABSTENTION count, over the same denominator.

    An unranked name lowers MRR rather than vanishing from it - that is the whole trick E20 names,
    and dropping it would let a matcher that gives up on its hard names outscore one that tries.
    """
    n = 0
    hits = {k: 0 for k in ks}
    rr = 0.0
    abstained = 0
    exact = 0
    for q, correct in gold:
        r = results.get(q)
        if r is None:
            continue                       # the matcher was never asked; not an abstention
        n += 1
        if r.get("resolves_to"):
            if str(r["resolves_to"]).strip().lower() == str(correct).strip().lower():
                exact += 1
                for k in ks:
                    hits[k] += 1
                rr += 1.0
                continue
        cands = [c.get("item") for c in (r.get("candidates") or [])]
        if not cands and not r.get("resolves_to"):
            abstained += 1
        rank = rank_of(correct, cands)
        if rank:
            rr += 1.0 / rank
            for k in ks:
                if rank <= k:
                    hits[k] += 1
    return {"n": n, "exact": exact, "abstained": abstained,
            "recall": {k: (round(hits[k] / n, 4) if n else None) for k in ks},
            "mrr": round(rr / n, 4) if n else None}


def selftest():
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    print("score_ingredient_mapper self-test")
    print("")

    T("MUST FIRE  the correct item at position 1 ranks 1", rank_of("Cauliflower", ["Cauliflower", "Kale"]) == 1,
      str(rank_of("Cauliflower", ["Cauliflower", "Kale"])))
    T("MUST FIRE  an item absent from the list has NO rank rather than a large one",
      rank_of("Saffron", ["Kale"]) is None, str(rank_of("Saffron", ["Kale"])))
    T("MUST NOT FIRE  matching is case- and space-insensitive, or a canon name would miss itself",
      rank_of(" cauliflower ", ["CAULIFLOWER"]) == 1, str(rank_of(" cauliflower ", ["CAULIFLOWER"])))

    gold = [("a", "A"), ("b", "B"), ("c", "C"), ("d", "D")]
    res = {"a": {"resolves_to": "A", "candidates": []},
           "b": {"resolves_to": None, "candidates": [{"item": "X"}, {"item": "B"}]},
           "c": {"resolves_to": None, "candidates": []},
           "d": {"resolves_to": None, "candidates": [{"item": "Z"}]}}
    s = score(res, gold)
    T("MUST FIRE  THE E20 TRICK - a name the matcher ABSTAINED on stays in the denominator and lowers "
      "MRR, instead of vanishing and flattering the score",
      s["n"] == 4 and s["abstained"] == 1, json.dumps(s))
    T("MUST FIRE  an exact resolve counts at every k", s["recall"][1] == 0.25, str(s["recall"]))
    T("MUST FIRE  a correct item at rank 2 counts at k=5 but not k=1",
      s["recall"][5] == 0.5 and s["recall"][1] == 0.25, str(s["recall"]))
    T("MUST FIRE  MRR is 1 + 1/2 over 4 = 0.375, so a lower rank is worth less than a higher one",
      s["mrr"] == 0.375, str(s["mrr"]))
    T("MUST NOT FIRE  a name the matcher was never asked about is NOT in the denominator - it is a "
      "gap in the run, not an abstention",
      score({}, gold)["n"] == 0, json.dumps(score({}, gold)))

    T("CLEAN TWIN an empty gold set yields None rather than a divide by zero",
      score({}, [])["mrr"] is None, str(score({}, [])["mrr"]))
    T("CLEAN TWIN a wrong answer at rank 1 still counts in the denominator and scores nothing",
      score({"a": {"candidates": [{"item": "WRONG"}]}}, [("a", "A")])["recall"][1] == 0.0,
      json.dumps(score({"a": {"candidates": [{"item": "WRONG"}]}}, [("a", "A")])))
    p, sk = build_pairs(os.path.join(tempfile.mkdtemp(prefix="mapeval-"), "nope"))
    T("CLEAN TWIN an absent runs directory yields no pairs rather than throwing", p == [] and sk == {},
      str((p, sk)))

    if bad:
        print("")
        print("SELF-TEST FAIL: %d check(s)" % len(bad))
        print("MAPPER-EVAL-SELFTEST-COMPLETE")
        return 1
    print("")
    print("SELF-TEST PASS: 7 must-fire cases led by the abstention that must stay in the denominator, "
          "2 must-not-fire cases, and 3 clean twins")
    print("MAPPER-EVAL-SELFTEST-COMPLETE")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="score the ingredient vocabulary matcher")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    if a.selftest:
        return selftest()

    pairs, skipped = build_pairs(RUNS)
    gold = sorted(set(pairs))
    if a.limit:
        gold = gold[:a.limit]
    if not gold:
        print("MAPPER EVAL BLIND: no (query, canon) pairs could be built, so nothing was scored.")
        for w, c in sorted(skipped.items(), key=lambda kv: -kv[1]):
            print("  skipped %5d  %s" % (c, w))
        print("MAPPER-EVAL-COMPLETE blind=no-pairs")
        return EXIT_CANNOT_RUN

    tmp = os.path.join(tempfile.mkdtemp(prefix="mapeval-"), "names.txt")
    with io.open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(q for q, _ in gold) + "\n")
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                              VOCAB_PS, "-Missing", tmp, "-Json"],
                             capture_output=True, timeout=1800, cwd=REPO)
        doc = json.loads((out.stdout or b"").decode("utf-8", errors="replace"))
    except Exception as e:                                         # noqa: BLE001
        print("MAPPER EVAL BLIND: the vocabulary matcher could not be run (%s). NOT a clean score." % e)
        print("MAPPER-EVAL-COMPLETE blind=matcher-did-not-run")
        return EXIT_CANNOT_RUN

    results = {str(r.get("name")): r for r in (doc.get("results") or [])}
    s = score(results, gold)

    with io.open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps({"_run": __import__("datetime").datetime.now().isoformat(timespec="seconds"),
                            "_pairs": len(gold), "_skipped": skipped,
                            "_corpus": "success-derived: every pair is a line that WAS mapped"}) + "\n")
        for q, c in gold:
            r = results.get(q) or {}
            cands = [x.get("item") for x in (r.get("candidates") or [])]
            f.write(json.dumps({"query": q, "correct": c, "class": r.get("class"),
                                "resolves_to": r.get("resolves_to"),
                                "rank": rank_of(c, cands), "n_candidates": len(cands)}) + "\n")

    print("ingredient vocabulary matcher, scored over %d distinct (query, canon) pair(s)" % s["n"])
    print("  built from %d mapped row(s) across the run corpus; one row per case in %s"
          % (len(pairs), os.path.relpath(OUT, REPO)))
    for w, c in sorted(skipped.items(), key=lambda kv: -kv[1])[:6]:
        print("    not usable %5d  %s" % (c, w))
    print("")
    print("  exact resolve      %5d of %d" % (s["exact"], s["n"]))
    for k in (1, 5, 25):
        print("  recall@%-3d         %s   (%d of %d)" % (k, s["recall"][k],
                                                         round((s["recall"][k] or 0) * s["n"]), s["n"]))
    print("  MRR                %s" % s["mrr"])
    print("  ABSTAINED          %5d of %d - names it returned nothing for. They stay in the "
          "denominator above; dropping them is how a matcher that gives up outscores one that tries "
          "(E20)." % (s["abstained"], s["n"]))
    print("")
    print("  THIS IS AN UPPER BOUND. Every pair is a line that WAS mapped, so the corpus is filtered")
    print("  toward the matcher's own successes and the lines that failed are invisible in it (E23).")
    print("  Nothing was tuned: this scores and does not change the matcher.")
    print("MAPPER-EVAL-COMPLETE pairs=%d recall@1=%s abstained=%d" % (s["n"], s["recall"][1], s["abstained"]))
    return EXIT_CLEAN


if __name__ == "__main__":
    sys.exit(main())
