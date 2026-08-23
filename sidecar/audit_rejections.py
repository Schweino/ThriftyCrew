"""
audit_rejections.py - what fraction of the local model's own rejections are wrong?

THE QUESTION THIS ANSWERS (2026-08-23). 3,315 of the banked `llm_rejected` rows are the local
model's own, unreviewed by anyone, and never citable as precedent (authority.py: single_model).
Nobody has ever measured whether they are RIGHT. Until that number exists, three separate
questions have no answer: whether the 27B earns the machinery built to schedule it, how many
board cells are missing because of it, and whether the 568M helper could do the same job.

TWO SETS, AND THEY ANSWER DIFFERENT THINGS. Reporting only one of them would mislead:

  RANDOM       a uniform sample of the rejections. The UNBIASED error rate, and the only number
               that can be scaled up to "so how many cells are missing".
  DISAGREEMENT the rows the trained helper scores high - i.e. where a second, independent model
               says the rejection was wrong. Errors concentrate here BY CONSTRUCTION, so its rate
               is not the population rate and must never be quoted as one. This is plan section 4.

BLINDED. The two sets are shuffled together and carry no mark, so a reviewer cannot be primed to
hunt for errors in the set that was chosen for being suspicious. The unblinding happens here, on
the join, after the rulings are written.

AND THE THIRD NUMBER, which is the one worth the most. If the disagreement set is full of errors
while the random sample is clean, the helper is a reliable DETECTOR of the local model's mistakes -
and a detector that runs in five seconds turns a one-off review session into a standing audit that
costs nothing and runs every night. That is a far larger prize than the cells this session finds.
"""
from __future__ import annotations
import argparse, glob, json, os, time

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")


def log(m: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def wilson(k: int, n: int) -> tuple[float, float]:
    """95% confidence interval for a rate. A bare fraction from n=120 invites over-reading;
    the interval is what says how much the number is allowed to carry."""
    if n == 0:
        return (0.0, 0.0)
    z = 1.96
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * ((p * (1 - p) / n + z * z / (4 * n * n)) ** 0.5) / d
    return (max(0.0, c - h), min(1.0, c + h))


def main() -> int:
    ap = argparse.ArgumentParser(description="Score the local model's rejections against rulings")
    ap.add_argument("--key", required=True, help="the blinding key (row -> set, id, product)")
    ap.add_argument("--verdicts", nargs="+", required=True)
    ap.add_argument("--population", type=int, default=3315,
                    help="how many unreviewed model rejections exist, for the scale-up")
    ap.add_argument("--out", default=os.path.join(OUT, "rejection-audit.json"))
    a = ap.parse_args()

    key = {r["n"]: r for r in json.load(open(a.key, encoding="utf-8-sig"))}
    ruled: dict[int, dict] = {}
    stray = 0
    for p in sorted(sum([glob.glob(g) for g in a.verdicts], [])):
        for r in json.load(open(p, encoding="utf-8-sig")):
            n = r.get("n")
            if n not in key or n in ruled:
                stray += 1
                continue
            v = (r.get("verdict") or "").strip().upper()
            if v in ("YES", "NO", "UNSURE"):
                ruled[n] = {**key[n], "verdict": v, "why": (r.get("why") or "").strip()}
    log(f"asked {len(key)}, ruled {len(ruled)}" + (f", {stray} stray/duplicate dropped" if stray else ""))

    report = {"generated": time.strftime("%Y-%m-%dT%H:%M:%S"), "asked": len(key),
              "ruled": len(ruled), "population": a.population, "sets": {}}
    for s in ("random", "disagreement"):
        rows = [r for r in ruled.values() if r["set"] == s]
        # A YES means the product IS the commodity - so the local model's REJECTION was WRONG.
        wrong = [r for r in rows if r["verdict"] == "YES"]
        unsure = [r for r in rows if r["verdict"] == "UNSURE"]
        decided = [r for r in rows if r["verdict"] in ("YES", "NO")]
        lo, hi = wilson(len(wrong), len(decided))
        report["sets"][s] = {
            "n": len(rows), "decided": len(decided), "abstained": len(unsure),
            "model_was_wrong": len(wrong),
            "error_rate": (len(wrong) / len(decided)) if decided else None,
            "ci95": [round(lo, 4), round(hi, 4)],
            "examples": [{"commodity": r["id"], "product": r["product"],
                          "helper": round(r["helper"], 4), "why": r["why"]} for r in wrong[:15]],
        }
        if s == "random" and decided:
            report["sets"][s]["implied_missing_cells"] = {
                "point": round(a.population * len(wrong) / len(decided)),
                "range": [round(a.population * lo), round(a.population * hi)],
                "note": "rejections the model got wrong across the whole unreviewed pile. Not all "
                        "of them would price a cell - a wrong rejection only costs a cell where "
                        "nothing else already prices it.",
            }

    r_, d_ = report["sets"]["random"], report["sets"]["disagreement"]
    if r_["error_rate"] is not None and d_["error_rate"] is not None:
        lift = (d_["error_rate"] / r_["error_rate"]) if r_["error_rate"] > 0 else None
        report["helper_as_detector"] = {
            "random_error_rate": round(r_["error_rate"], 4),
            "disagreement_error_rate": round(d_["error_rate"], 4),
            "lift": (round(lift, 1) if lift else None),
            "verdict": ("the helper concentrates the model's errors and can stand as a nightly "
                        "audit" if lift and lift >= 3 else
                        "the helper does NOT reliably pick out the model's errors; its "
                        "disagreements are no better than a random sample as a place to look"),
        }
    # EVERY RULING, not just the examples. These cost tokens, a reasoner made them, and the next
    # person to ask "how do you know the model's rejections are sound" needs the rows, not the rate.
    report["rulings"] = sorted(ruled.values(), key=lambda r: r["n"])
    os.makedirs(OUT, exist_ok=True)
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(report, f, indent=1, ensure_ascii=False)
    log(f"wrote {a.out}")
    print(json.dumps({k: v for k, v in report.items() if k != "sets"}, indent=1))
    for s, v in report["sets"].items():
        rate = "n/a" if v["error_rate"] is None else f"{100 * v['error_rate']:.1f}%"
        print(f"\n  {s}: n={v['n']} decided={v['decided']} abstained={v['abstained']} "
              f"MODEL WRONG={v['model_was_wrong']} rate={rate} "
              f"ci95=[{100 * v['ci95'][0]:.1f}%, {100 * v['ci95'][1]:.1f}%]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
