r"""matcher_eval.py - score the commodity matcher's TWO STAGES separately.

    python sidecar/matcher_eval.py --selftest          (pinned interpreter; no torch needed)
    <sidecar venv>/python sidecar/matcher_eval.py      (the real run)

BACKLOG E19, for the component whose errors reach a price on a live page.

WHAT ALREADY EXISTED AND WHY THIS IS STILL MISSING. hardeval.py scores the RERANK stage well: AUC
against GOLD, the 45 pairs expanded from adjudicated known-wrong rulings, which is the
recorded-failure corpus E23 says this estate does not build. Nothing scores the RETRIEVAL stage. That
is E19's load-bearing point, and it is not a technicality:

    A true match that scores 0.54 against sweep.py's COVERAGE_COS_FLOOR of 0.55 is gone before the
    cross-encoder is ever asked, and NO number in the estate would show it. The reranker's AUC is
    computed on pairs that survived the prefilter, so a recall failure upstream makes the downstream
    metric look BETTER, not worse.

"Never retrieved" and "retrieved but buried" need opposite fixes - a wider prefilter versus a better
ranker - and one end-to-end number cannot tell them apart.

THIS SCORES. IT DOES NOT TUNE. Nothing about the matcher changes in the same commit that builds the
thing that measures it, or the measurement is just a description of a decision already taken.

RULES CARRIED IN FROM THE SAME DAY'S WORK, and each one is here because it was learned the hard way:
  * the DENOMINATOR and every decline by reason (E20) - a recall figure over the rows that resolved
    is not a recall figure, and the dedup probe was quietly reporting one over 18% of its labels
  * an INPUT FINGERPRINT (E24) - that same probe disagreed with itself across two runs because its
    inputs moved underneath it and it recorded nothing about what it had read
  * ONE ROW PER CASE (E24), with the totals derived from the file rather than being it
  * the ACCEPTANCE BAR WRITTEN BEFORE THE RUN (E21), in the metric's own units
"""
from __future__ import annotations

import argparse
import io
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
DATA = os.path.join(HERE, "data")
OUT = os.path.join(HERE, "out")

# The prefilter this exists to measure. READ OUT OF sweep.py's SOURCE rather than imported, because
# importing it needs torch and run-gates runs this file's self-test on the pinned interpreter, which
# has none. The obvious `try: from sweep import ... except: COVERAGE_COS_FLOOR = 0.55` was written
# first and is a trap: on the pinned interpreter the except branch always fires, so the self-test
# compares the fallback against itself and would stay green if sweep.py moved its floor to 0.60 while
# the real run used the new number. Registered in THRESHOLDS.md as space S1.
_FLOOR_FALLBACK = 0.55


def sweep_cos_floor(path=None):
    """sweep.py's COVERAGE_COS_FLOOR, by reading the file. Returns (value, how) so a caller - and the
    self-test - can tell a real read from a fallback instead of being handed an agreeing number."""
    p = path or os.path.join(HERE, "sweep.py")
    try:
        for line in io.open(p, encoding="utf-8"):
            m = re.match(r"^COVERAGE_COS_FLOOR\s*=\s*([0-9.]+)", line)
            if m:
                return float(m.group(1)), "read from sweep.py"
    except OSError:
        pass
    return _FLOOR_FALLBACK, "FALLBACK - sweep.py could not be read, so this may not be the live floor"


COVERAGE_COS_FLOOR, COVERAGE_COS_FLOOR_SOURCE = sweep_cos_floor()

# THE ACCEPTANCE BAR, written here rather than decided after seeing the output (backlog E21). Stated
# in the metric's own units and chosen from what the stage is FOR: the prefilter's whole job is to
# hand the reranker a set that contains the right answer, so anything it drops is unrecoverable.
RETRIEVAL_BAR = 0.99   # recall@25 below this means the prefilter is losing true matches
FLOOR_BAR = 0.99       # fraction of true pairs clearing COVERAGE_COS_FLOOR


def rj(p):
    with io.open(p, encoding="utf-8-sig") as f:
        return json.load(f)


def input_fingerprint(paths):
    """Size and mtime of what this run read, so two runs can be told apart from a change.

    Not a content hash: these files are large and the question is only "did this move". Size carries
    the weight and mtime is the tie-breaker, because this estate has a standing scar about mtime
    moving on byte-identical files after a reanchor.
    """
    out = {}
    for label, p in paths.items():
        try:
            st = os.stat(p)
            out[label] = {"bytes": st.st_size,
                          "mtime": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(st.st_mtime))}
        except OSError:
            out[label] = None
    return out


def recall_at(ranks, k):
    """How many true commodities landed in the top k. Ranks are 1-based; None means not ranked."""
    return sum(1 for r in ranks if r is not None and r <= k)


def mrr(ranks):
    """Mean reciprocal rank over the SCOREABLE cases. An unranked case contributes 0, not nothing -
    dropping it would score the matcher only on the rows it managed to place, which is exactly the
    abstention trick E20 is about."""
    if not ranks:
        return 0.0
    return sum((1.0 / r) if r else 0.0 for r in ranks) / len(ranks)


def verdict(recall25_frac, floor_frac):
    """The stated bars, applied. Returns (ok, lines) - the reasoning before the verdict, deliberately,
    because a verdict with its reasoning after it is decoration."""
    lines = []
    ok = True
    if recall25_frac < RETRIEVAL_BAR:
        ok = False
        lines.append("RETRIEVAL recall@25 is %.4f, under the %.2f bar: the prefilter is dropping true "
                     "matches, and every one it drops is unrecoverable downstream." % (recall25_frac, RETRIEVAL_BAR))
    else:
        lines.append("RETRIEVAL recall@25 %.4f clears the %.2f bar." % (recall25_frac, RETRIEVAL_BAR))
    if floor_frac < FLOOR_BAR:
        ok = False
        lines.append("Only %.4f of true pairs clear COVERAGE_COS_FLOOR %.2f, under the %.2f bar. Rows "
                     "under that floor are never reranked and never appear in any AUC."
                     % (floor_frac, COVERAGE_COS_FLOOR, FLOOR_BAR))
    else:
        lines.append("%.4f of true pairs clear COVERAGE_COS_FLOOR %.2f, over the %.2f bar."
                     % (floor_frac, COVERAGE_COS_FLOOR, FLOOR_BAR))
    return ok, lines


def selftest():                                                # noqa: C901
    fails = []

    def T(name, cond, got=""):
        if cond:
            print("  ok    %s" % name)
        else:
            print("  X     %s   got: %s" % (name, got))
            fails.append(name)

    T("recall@k counts a rank AT k as a hit", recall_at([1, 5, 10], 5) == 2, recall_at([1, 5, 10], 5))
    T("recall@k does not count an unranked case", recall_at([1, None, None], 25) == 1)
    T("MRR of a perfect run is 1.0", abs(mrr([1, 1, 1]) - 1.0) < 1e-9, mrr([1, 1, 1]))

    # THE ABSTENTION CASE, and it is the one that matters (backlog E20). An unranked case must drag
    # the mean down, not vanish from it - otherwise a matcher that gives up on its hard rows outscores
    # one that attempts everything, and neither number looks wrong.
    T("MUST FIRE  an unranked case lowers MRR rather than being dropped from it",
      abs(mrr([1, None]) - 0.5) < 1e-9, mrr([1, None]))
    T("CLEAN TWIN two ranked cases average normally", abs(mrr([1, 2]) - 0.75) < 1e-9, mrr([1, 2]))
    T("MRR of an empty set is 0, not a division by zero", mrr([]) == 0.0)

    # THE FOUNDING CASE. A true match under the prefilter floor is invisible to every downstream
    # metric, so the verdict must fail on it even when ranking looks perfect.
    ok, lines = verdict(1.0, 0.90)
    T("MUST FIRE  perfect ranking still FAILS when true pairs sit under the cosine floor",
      (not ok) and any("COVERAGE_COS_FLOOR" in x for x in lines), "; ".join(lines))
    ok, lines = verdict(0.80, 1.0)
    T("MUST FIRE  a prefilter that drops true matches FAILS even at a clean floor rate", not ok)
    ok, lines = verdict(1.0, 1.0)
    T("CLEAN TWIN both bars met is a pass", ok)

    T("the bar is a module constant, not decided at report time",
      RETRIEVAL_BAR == 0.99 and FLOOR_BAR == 0.99, "%s/%s" % (RETRIEVAL_BAR, FLOOR_BAR))
    # THE FLOOR MUST BE READ, NOT ASSUMED. A fallback that happens to equal the live value is the
    # agreeing number this estate keeps getting caught by, so the SOURCE is asserted and not just the
    # value - and a wrong-valued fixture must still be detected.
    T("the prefilter floor is READ from sweep.py rather than falling back",
      COVERAGE_COS_FLOOR_SOURCE == "read from sweep.py", COVERAGE_COS_FLOOR_SOURCE)
    T("the floor read from sweep.py is the value sweep.py actually declares",
      abs(COVERAGE_COS_FLOOR - 0.55) < 1e-9,
      "%s (%s)" % (COVERAGE_COS_FLOOR, COVERAGE_COS_FLOOR_SOURCE))

    _tmp = os.path.join(HERE, "_floor_probe_selftest.py")
    try:
        io.open(_tmp, "w", encoding="utf-8").write("COVERAGE_COS_FLOOR = 0.61\n")
        v, how = sweep_cos_floor(_tmp)
        T("MUST FIRE  a CHANGED floor in the source is read, not silently replaced by the fallback",
          abs(v - 0.61) < 1e-9 and how == "read from sweep.py", "%s (%s)" % (v, how))
    finally:
        if os.path.exists(_tmp):
            os.remove(_tmp)

    v, how = sweep_cos_floor(os.path.join(HERE, "no-such-file.py"))
    T("CLEAN TWIN an unreadable source reports itself as a FALLBACK rather than as a read",
      abs(v - _FLOOR_FALLBACK) < 1e-9 and how.startswith("FALLBACK"), how)

    fp = input_fingerprint({"self": os.path.abspath(__file__), "absent": os.path.join(HERE, "nope.nope")})
    T("the fingerprint reads a real file", fp["self"] and fp["self"]["bytes"] > 0)
    T("a missing input is recorded as missing rather than skipped", fp["absent"] is None)

    if fails:
        print("SELF-TEST FAIL: %d case(s)" % len(fails))
        return 1
    print("SELF-TEST PASS: recall and MRR arithmetic, the abstention case, and the founding verdict "
          "where perfect ranking still fails because true pairs sit under the prefilter floor")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--top-k", type=int, default=25, help="how deep to look for the true commodity")
    ap.add_argument("--limit", type=int, default=0, help="score only the first N positives (a smoke run)")
    ap.add_argument("--defs", default=None, help="a frozen commodity-defs snapshot; default is today's")
    a = ap.parse_args([x for x in sys.argv[1:] if x != "--run"])

    import torch                                               # noqa: PLC0415
    from lib_match import Matcher, clean_product, commodity_text  # noqa: PLC0415

    defs_path = a.defs or os.path.join(DATA, "commodity-defs.json")
    pos_path = os.path.join(DATA, "eval-positives.json")
    fp = input_fingerprint({"commodity_defs": defs_path, "eval_positives": pos_path})
    print("INPUTS THIS RUN READ (a different fingerprint means a different measurement, not a change):")
    for k in sorted(fp):
        v = fp[k]
        print("   %-18s %s" % (k, "MISSING" if v is None else "%d bytes, %s" % (v["bytes"], v["mtime"])))

    defs = rj(defs_path)
    by_id = {d["id"]: d for d in defs}
    pos = rj(pos_path)

    # THE DENOMINATOR AND EVERY DECLINE BY REASON (backlog E20).
    declined = {"commodity not in defs": 0, "no product text": 0}
    rows = []
    for r in pos:
        cid = r.get("id")
        if cid not in by_id:
            declined["commodity not in defs"] += 1
            continue
        if not (r.get("product") or "").strip():
            declined["no product text"] += 1
            continue
        rows.append(r)
    resolved = len(rows)
    if a.limit:
        rows = rows[:a.limit]

    print("accepted board pairs in the file : %d" % len(pos))
    print("scoreable                        : %d" % len(rows))
    for k, v in sorted(declined.items(), key=lambda kv: -kv[1]):
        if v:
            print("   declined: %-34s %d" % (k, v))
    if pos:
        print("COVERAGE: %.0f%% of the positives resolved to a definition (%d of %d). Read every "
              "number below against that." % (100.0 * resolved / len(pos), resolved, len(pos)))
    if a.limit and len(rows) < resolved:
        print("SMOKE RUN: --limit %d, so only %d of the %d resolved pairs were scored. This is NOT "
              "the coverage figure above and must not be quoted as a result." % (a.limit, len(rows), resolved))
    if not rows:
        print("MATCHER EVAL COULD NOT EVALUATE: no positive pair resolved to a commodity definition.")
        return 3

    m = Matcher.load(with_reranker=False)
    cids = [d["id"] for d in defs]
    print("embedding %d commodity definition(s) and %d product(s) on %s"
          % (len(cids), len(rows), getattr(m, "device", "?")))
    t0 = time.time()
    cvecs = m.embed([commodity_text(d) for d in defs])
    pvecs = m.embed([clean_product(r["product"]) for r in rows])
    sims = pvecs @ cvecs.T                       # both normalised, so this is cosine
    print("embedded in %.1fs" % (time.time() - t0))

    pos_of = {c: i for i, c in enumerate(cids)}
    ranks, floor_hits, cases = [], 0, []
    k = min(a.top_k, len(cids))
    top = torch.topk(sims, k=k, dim=1)
    for i, r in enumerate(rows):
        j = pos_of[r["id"]]
        true_score = float(sims[i][j])
        # rank by how many commodities beat the true one - the same construction the dedup probe
        # uses, so the two numbers mean the same thing.
        rank = int((sims[i] > true_score).sum()) + 1
        ranks.append(rank if rank <= k else None)
        cleared = true_score >= COVERAGE_COS_FLOOR
        if cleared:
            floor_hits += 1
        cases.append({"product": r.get("product"), "commodity": r["id"], "store": r.get("store"),
                      "rank": rank, "cosine": round(true_score, 4), "clears_floor": cleared})

    n = len(rows)
    print("")
    print("STAGE 1 - RETRIEVAL. Where the TRUE commodity ranks among all %d, by bi-encoder cosine:" % len(cids))
    for kk in (1, 5, 10, 25):
        if kk <= k:
            print("  recall@%-3d %5d / %d   (%.4f)" % (kk, recall_at(ranks, kk), n, recall_at(ranks, kk) / n))
    print("  MRR       %.4f" % mrr(ranks))
    print("")
    print("  clearing COVERAGE_COS_FLOOR %.2f : %d / %d  (%.4f)   [%s]"
          % (COVERAGE_COS_FLOOR, floor_hits, n, floor_hits / n, COVERAGE_COS_FLOOR_SOURCE))
    print("  THESE ARE KNOWN-CORRECT PAIRS. Every one under that floor is a true match the prefilter")
    print("  drops before the cross-encoder is asked, and it appears in no AUC anywhere.")

    worst = sorted([c for c in cases if not c["clears_floor"]], key=lambda c: c["cosine"])[:10]
    if worst:
        print("")
        print("  the ten true pairs furthest under the floor:")
        for c in worst:
            print("    %.4f  %-22s %s" % (c["cosine"], c["commodity"][:22], (c["product"] or "")[:52]))

    os.makedirs(OUT, exist_ok=True)
    out_path = os.path.join(OUT, "matcher-eval-cases.jsonl")
    with io.open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps({"_run": time.strftime("%Y-%m-%dT%H:%M:%S"), "_inputs": fp,
                            "_cases": n, "_positives_in_file": len(pos), "_declined": declined,
                            "_top_k": k, "_floor": COVERAGE_COS_FLOOR}, ensure_ascii=False) + "\n")
        for c in cases:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
    print("")
    print("per-case rows: %s (%d case(s))" % (out_path, n))

    ok, lines = verdict(recall_at(ranks, 25) / n, floor_hits / n)
    print("")
    print("ACCEPTANCE BARS, fixed in this file before the run: recall@25 >= %.2f and floor-clearance "
          ">= %.2f." % (RETRIEVAL_BAR, FLOOR_BAR))
    for ln in lines:
        print("  " + ln)
    print("VERDICT: %s" % ("PASS" if ok else "RETRIEVAL STAGE FAILS ITS BAR"))
    return 0 if ok else 2


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
