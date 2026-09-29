"""Eval health checks for graph/eval/score.py --health (W4 of
design/PLAN-eval-heldout-and-hillclimb-2026-09-29.md).

    python graph/eval/score.py --health [--runs 3]
    python graph/eval/score.py --health --sample 60 [--runs 3]   # fixed keyed sample, per split
    python graph/eval/score_health.py --selftest

Three checks, run over the SAME gold blob:

  NOISE FLOOR   every arm is scored N times. The per-metric spread (max minus
                min) of the LLM arms is the measured noise floor: a later change
                that moves a metric by less than it has not been shown to move it.
                The deterministic arm must show ZERO spread; any spread there is a
                harness defect and exits 1 (DETERMINISTIC-SPREAD).
  ORDERING      recall must run deterministic <= +llm <= +bank (system). A flat or
                inverted step prints ORDERING-SUSPECT naming the arms. A finding,
                never an exit code.
  HEADROOM      a metric at exactly 0 or exactly 1 on every run of every arm prints
                SATURATED <metric>: a non-regression there is not an improvement.

Nothing here calls score.record(), so a health run writes no eval_runs row and
no tracked learning JSON.

Exit: 0 health run completed (findings may be printed), 1 deterministic spread
(harness defect), 2 could not run (no gold, model down, empty index).
Last line: SCORE-HEALTH-COMPLETE runs=N arms=K.

SCOPE OF A CLEAN REPORT: UNSOUND for noise beyond N runs (three runs bound the
spread from below, never above); COMPLETE for DETERMINISTIC-SPREAD (a nonzero
spread over identical inputs IS the defect).
Not a push gate: it needs a board-built index and a live model.
"""
# gate-inputs: graph\eval\score_health.py

from __future__ import annotations

import sys
import time

METRICS = ("entity_precision", "entity_recall", "f1",
           "false_merge_rate", "missed_merge_rate",
           # the layer-5 model's own verdicts (score.score docstring): the only pair a prompt moves
           "adj_false_merge_rate", "adj_missed_merge_rate")
DET = "deterministic"
ORDER = (DET, "llm", "system")   # recall must be non-decreasing along this
ZERO_SPREAD = 0.0                # the deterministic bar: exactly zero, no tolerance


SAMPLE_SALT = "tc-eval-sample-2026-09-29"   # changing it draws a different sample; say so if you do
SAMPLE_CLASS = "uncertain"                   # escalation-review rows (W3): where 16 of 17 holdout misses live


def sample_rows(gold: list[dict], n: int, split_of, salt: str = SAMPLE_SALT,
                selection: str = SAMPLE_CLASS) -> tuple[dict[str, list[dict]], dict]:
    """A FIXED KEYED SAMPLE (Brad 2026-09-29; ms-08 samples by KEY, never at random).

    Per split, the `selection` rows are ordered by sha256(salt + gold id) and the first n kept. The
    same gold blob and salt give the same ids on every call, so the noise floor and every hillclimb
    round score one case list. split_of is gold_split.split_of (injected so the self-test is hermetic).
    Returns ({split: rows}, info) where info names the salt, the fingerprint (sha256 of the sorted
    ids), and per split how many were available and whether n was CAPPED.
    """
    import hashlib
    out: dict[str, list[dict]] = {}
    info = {"salt": salt, "n": n, "selection": selection, "per_split": {}}
    for sp in ("train", "holdout"):
        pool = [g for g in gold if g.get("selection") == selection and split_of(g) == sp]
        pool.sort(key=lambda g: hashlib.sha256((salt + str(g["id"])).encode("utf-8")).hexdigest())
        out[sp] = pool[:n]
        info["per_split"][sp] = {"available": len(pool), "taken": len(out[sp]), "capped": len(pool) < n}
    ids = sorted(str(g["id"]) for sp in out for g in out[sp])
    info["fingerprint"] = hashlib.sha256("\n".join(ids).encode("utf-8")).hexdigest()
    return out, info


def print_sample_info(info: dict) -> None:
    print(f"SAMPLE salt={info['salt']} n={info['n']} per split, selection={info['selection']} "
          f"fingerprint={info['fingerprint']}")
    for sp, d in info["per_split"].items():
        cap = f"  CAPPED: asked {info['n']}, only {d['available']} available" if d["capped"] else ""
        print(f"  sample {sp}: {d['taken']} of {d['available']} {info['selection']} rows{cap}")
    print("  every number below is a SAMPLE number, not a full-gold number")


def spread(values: list[float]) -> float:
    return (max(values) - min(values)) if values else 0.0


def check(runs: dict[str, list[dict]]) -> dict:
    """runs: arm -> list of metric dicts (one per repetition). Pure."""
    out = {"spread": {}, "values": {}, "findings": [], "harness_defect": False}
    for arm, ms in runs.items():
        for k in METRICS:
            vals = [float(m[k]) for m in ms]
            out["values"][(arm, k)] = vals
            out["spread"][(arm, k)] = spread(vals)
            if arm == DET and spread(vals) > ZERO_SPREAD:
                out["harness_defect"] = True
                out["findings"].append(f"DETERMINISTIC-SPREAD {k} {spread(vals)!r} values={vals}")
    present = [a for a in ORDER if a in runs and runs[a]]
    for lo, hi in zip(present, present[1:]):
        rlo = min(float(m["entity_recall"]) for m in runs[lo])
        rhi = max(float(m["entity_recall"]) for m in runs[hi])
        if rhi < rlo:
            out["findings"].append(f"ORDERING-SUSPECT inverted {lo}={rlo:.4f} > {hi}={rhi:.4f}")
        elif rhi == rlo:
            out["findings"].append(f"ORDERING-SUSPECT flat {lo}={rlo:.4f} == {hi}={rhi:.4f}")
    for k in METRICS:
        allv = [v for arm in runs for v in out["values"][(arm, k)]]
        if allv and (all(v == 0.0 for v in allv) or all(v == 1.0 for v in allv)):
            out["findings"].append(f"SATURATED {k} at {allv[0]:.1f} on every arm")
    return out


def report(res: dict, runs: dict[str, list[dict]]) -> None:
    for arm in runs:
        for k in METRICS:
            vals = res["values"][(arm, k)]
            print(f"  {arm:13s} {k:18s} spread={res['spread'][(arm, k)]:.4f}  "
                  f"values={' '.join(f'{v:.4f}' for v in vals)}")
    for f in res["findings"]:
        print(f)


def run_health(db, gold, llm, n: int, score_fn, arms=ORDER) -> int:
    """Score each arm n times. score_fn is score.score (injected to avoid a cycle). `arms` limits
    which of deterministic/llm/system run (the sample run skips system: its bank answers most cases)."""
    want = set(arms)
    arms = {DET: dict(use_llm=False, use_bank=False)}
    if llm is not None:
        if "llm" in want:
            arms["llm"] = dict(use_llm=True, use_bank=False)
        if "system" in want:
            arms["system"] = dict(use_llm=True, use_bank=True)
    else:
        print("BLIND llm arms: no model (deterministic arm only)")
    runs: dict[str, list[dict]] = {a: [] for a in arms}
    t0 = time.time()
    for i in range(n):
        for arm, kw in arms.items():
            t = time.time()
            m = score_fn(db, gold, llm=llm if kw["use_llm"] else None, **kw)
            runs[arm].append(m)
            c = m["counts"]
            print(f"  run {i+1}/{n} {arm}: recall={m['entity_recall']:.4f} "
                  f"fm={m['false_merge_rate']:.4f} mm={m['missed_merge_rate']:.4f} "
                  f"adj_fm={c['adj_false']}/{c['adj_no_match_n']} adj_mm={c['adj_missed']}/{c['adj_match_n']} "
                  f"adj_rejected_true={c['adj_rejected_true']} llm_errors={c['adj_error']} "
                  f"scored {c['gold_match'] + c['gold_no_match']} of {len(gold)} "
                  f"(missing_node={c['missing_node']}) {time.time()-t:.0f}s", flush=True)
    res = check(runs)
    print(f"=== score health: {n} runs x {len(arms)} arms, {len(gold)} gold rows, "
          f"{time.time()-t0:.0f}s wall ===")
    report(res, runs)
    print(f"SCORE-HEALTH-COMPLETE runs={n} arms={len(arms)}")
    return 1 if res["harness_defect"] else 0


def _m(recall=0.5, fm=0.25, mm=0.5, p=0.75):
    return {"entity_precision": p, "entity_recall": recall, "f1": 0.5,
            "false_merge_rate": fm, "missed_merge_rate": mm,
            "adj_false_merge_rate": 0.25, "adj_missed_merge_rate": 0.5}


def _sample_cases() -> list:
    """(name, ok, detail) for the fixed keyed sample. Hermetic: split_of is a fake keyed on id."""
    def fake_split(g):
        return "holdout" if g["id"].startswith("h") else "train"
    gold = ([{"id": f"t{i}", "selection": "uncertain"} for i in range(8)]
            + [{"id": f"h{i}", "selection": "uncertain"} for i in range(3)]
            + [{"id": f"s{i}", "selection": "success"} for i in range(4)])
    out = []
    a, ia = sample_rows(gold, 4, fake_split)
    b, ib = sample_rows(list(reversed(gold)), 4, fake_split)
    same = ([g["id"] for g in a["train"]] == [g["id"] for g in b["train"]]
            and ia["fingerprint"] == ib["fingerprint"])
    out.append(("CLEAN TWIN the same ids and fingerprint on every call, whatever the input order",
                same, f"{[g['id'] for g in a['train']]} vs {[g['id'] for g in b['train']]}"))
    leak = [g["id"] for g in a["train"] if fake_split(g) != "train"]
    out.append(("MUST NOT FIRE no holdout row in the train sample", not leak, str(leak)))
    # the leak detector itself, on a planted row: the check above must be able to see one
    planted = a["train"] + [{"id": "h9", "selection": "uncertain"}]
    caught = [g["id"] for g in planted if fake_split(g) != "train"]
    out.append(("MUST FIRE a holdout row planted in the train sample is caught", caught == ["h9"], str(caught)))
    out.append(("MUST NOT FIRE success rows never enter an uncertain sample",
                all(g["selection"] == "uncertain" for sp in a for g in a[sp]), ""))
    cap = ia["per_split"]["holdout"]
    out.append(("MUST FIRE n=4 past the 3 available holdout rows is capped and SAID",
                cap == {"available": 3, "taken": 3, "capped": True}, str(cap)))
    at = sample_rows(gold, 3, fake_split)[1]["per_split"]["holdout"]
    out.append(("MUST NOT FIRE n=3 exactly AT the 3 available is not capped",
                at == {"available": 3, "taken": 3, "capped": False}, str(at)))
    other = sample_rows(gold, 4, fake_split, salt="another-salt")[1]["fingerprint"]
    out.append(("CLEAN TWIN a different salt draws a different fingerprint", other != ia["fingerprint"], ""))
    return out


def selftest() -> int:
    cases = []

    def case(name, runs, want_defect, want_sub, absent_sub=()):
        r = check(runs)
        ok = r["harness_defect"] == want_defect
        text = "\n".join(r["findings"])
        ok = ok and all(s in text for s in want_sub) and not any(s in text for s in absent_sub)
        cases.append((name, ok, text))

    mono = {DET: [_m(0.5)] * 3, "llm": [_m(0.625)] * 3, "system": [_m(0.75)] * 3}
    case("MUST NOT FIRE zero deterministic spread, monotone ordering", mono, False, [],
         ["DETERMINISTIC-SPREAD", "ORDERING-SUSPECT", "SATURATED"])
    case("MUST FIRE deterministic spread one step past the zero bar (0.25 vs 0.5 recall)",
         {DET: [_m(0.5), _m(0.5), _m(0.25)], "llm": [_m(0.625)], "system": [_m(0.75)]},
         True, ["DETERMINISTIC-SPREAD entity_recall"])
    case("MUST NOT FIRE deterministic spread exactly AT the zero bar",
         {DET: [_m(0.5), _m(0.5)]}, False, [], ["DETERMINISTIC-SPREAD"])
    case("CLEAN TWIN llm-arm spread is a noise floor, not a defect",
         {DET: [_m(0.5)] * 2, "llm": [_m(0.625), _m(0.75)], "system": [_m(0.875)] * 2},
         False, [], ["DETERMINISTIC-SPREAD", "ORDERING-SUSPECT"])
    case("MUST FIRE inverted ordering names the arms",
         {DET: [_m(0.5)], "llm": [_m(0.75)], "system": [_m(0.625)]},
         False, ["ORDERING-SUSPECT inverted llm=0.7500 > system=0.6250"])
    case("MUST FIRE flat ordering AT the bar (equal recall)",
         {DET: [_m(0.5)], "llm": [_m(0.5)], "system": [_m(0.75)]},
         False, ["ORDERING-SUSPECT flat deterministic=0.5000 == llm=0.5000"])
    case("MUST NOT FIRE one step past flat (0.5 -> 0.625)",
         {DET: [_m(0.5)], "llm": [_m(0.625)], "system": [_m(0.75)]},
         False, [], ["ORDERING-SUSPECT"])
    case("MUST FIRE false_merge saturated at 0 on every arm",
         {DET: [_m(0.5, fm=0.0)], "llm": [_m(0.625, fm=0.0)], "system": [_m(0.75, fm=0.0)]},
         False, ["SATURATED false_merge_rate at 0.0"])
    case("MUST FIRE precision saturated at 1 on every arm",
         {DET: [_m(0.5, p=1.0)], "llm": [_m(0.625, p=1.0)]},
         False, ["SATURATED entity_precision at 1.0"])
    case("MUST NOT FIRE saturation when one arm leaves 0",
         {DET: [_m(0.5, fm=0.0)], "llm": [_m(0.625, fm=0.25)]},
         False, [], ["SATURATED false_merge_rate"])

    cases.extend(_sample_cases())
    fails = 0
    for name, ok, text in cases:
        print(f"  {'ok  ' if ok else 'FAIL'} {name}")
        if not ok:
            fails += 1
            print(f"       findings: {text!r}")
    ran = len(cases)
    if ran != 17:
        print(f"score_health self-test FAIL: ran {ran} cases, expected 17")
        return 1
    print(f"score_health: {ran - fails} of {ran} cases passed")
    print(f"score_health self-test {'pass' if fails == 0 else 'FAIL'}")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(selftest())
    print("run via: python graph/eval/score.py --health", file=sys.stderr)
    raise SystemExit(2)
