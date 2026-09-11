r"""hardeval_baseline.py - does a hardeval run still reproduce the tracked record of the SAME configuration?

    python sidecar/hardeval_baseline.py --selftest      (pinned interpreter; no torch needed)
    <sidecar venv>/python sidecar/hardeval.py --stage score --tag weekly \
        --defs sidecar/data/frozen/phase3-baseline/commodity-defs.json --baseline phase3-frozen

WHY THIS EXISTS (2026-09-11). graph\pipeline\nightly.ps1 re-scores the pinned cross-encoder once a week on
the frozen phase3-baseline defs, and until today it only RECORDED what it got. hardeval-phase3-frozen.json is
the tracked record of that same configuration, generated 2026-08-23, and a re-run on 2026-09-11 reproduced its
OLD and GOLD AUCs to every digit. So a week that does NOT reproduce them is a change in the model, the weights
on disk or the environment that runs them - and nothing compared the two, so it would have raised nothing.

WHY IT IS ITS OWN FILE. hardeval.py imports torch on its first lines, and run-gates runs every discovered
--selftest on the pinned interpreter, which has no torch. The comparison is arithmetic over two JSON records
plus a read of three input files, so it lives here, hardeval.py imports it, and the self-test runs on every
push. sidecar/matcher_eval.py is the same split for the same reason.

THREE VERDICTS, AND THE ORDER THEY ARE DECIDED IN.
  UNCOMPARABLE  the two records are not the same configuration, so a difference would not be attributable to
                anything. Decided FIRST, and it wins over a moved number: a DRIFT between two different setups
                is a false alarm about the model, and an OK between them is an agreeing number about nothing.
  DRIFT         same configuration, and OLD or GOLD (or MINED, when its size matches) moved past the bar.
  OK            same configuration, and every compared set held.

WHAT EACH SET NEEDS BEFORE IT IS COMPARED.
  OLD, GOLD   always compared. They are the sets that decide, so a size that differs from the baseline is
              UNCOMPARABLE, never a silent skip.
  MINED       compared only when the mined counts match. The mined set grew after round-2 labelling on
              2026-08-23 (4701 in the baseline, 5132 on 2026-09-11), and an AUC over a different set of
              negatives is a different number, not a moved one. A size mismatch here is reported per set and
              does not change the verdict. EQUAL COUNTS ARE NECESSARY, NOT SUFFICIENT: the baseline carries no
              fingerprint of its mined rows, so a relabelled set of the same size would be compared.
  positives   are inside every AUC, so a different count is UNCOMPARABLE.

INPUT FINGERPRINT. Counts can agree over different rows. When --defs names a frozen snapshot directory that
also holds copies of the eval sets (phase3-baseline does, frozen 2026-08-22 21:08, before the baseline run),
each live file in sidecar\data must PARSE equal to its copy, or the run is UNCOMPARABLE. Parsed, not hashed:
git checks the tracked copies out LF while the live files are CRLF, and a byte hash would call identical rows
different in every worktree. Measured 2026-09-11: all three live files hash-match the snapshot manifest's
sha256_16 and parse equal to the LF copies.

SCOPE OF A CLEAN REPORT. OK means the aggregate AUCs held within the bar on the sets that could be compared.
It does not mean no pair's score moved: the records carry no per-pair scores, so a change that reorders pairs
without moving an AUC by more than the bar is invisible here.
"""
from __future__ import annotations

import io
import json
import math
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

# THE ACCEPTANCE BAR, written before the run it judges (backlog E21), in AUC units, the same for every set.
# A set DRIFTS when |auc_now - auc_baseline| is STRICTLY GREATER than this.
#
# HOW IT WAS CHOSEN (backlog I94): the first plausible number from the evidence below, not the survivor of a
# sweep. It was written down, with the rule for keeping or revising it, before the benign-noise probe ran.
#   - NOTHING CHANGED gives 0.000000. OLD and GOLD reproduced to every digit on 2026-08-23, 09-07 and 09-11.
#   - RESOLUTION. 0.0005 AUC is 35 positive/negative orderings on OLD (2816 x 25 = 70,400 pairs), 63 on GOLD
#     (2816 x 45 = 126,720) and 7,226 on MINED at 5132.
#   - WHAT IT MUST CATCH. The one real defect measured on the stock model, query and document passed in reverse
#     order, moved GOLD 0.8329 -> 0.8312, which is 0.0017 or 3.4x the bar (hardeval.py score_pairs). A retrain
#     differing only by seed spans 0.0033 on holdout AUC, 6.6x.
#   - WHAT IT MUST NOT CATCH. Float noise from an environment change that means nothing. MEASURED 2026-09-11
#     16:48 at commit fa944730b, torch 2.11.0+cu128 on the RTX 5070 Ti, by a scratch harness that scored all
#     8,018 pairs (2816 positives, 25 OLD, 45 GOLD, 5132 MINED) on the frozen defs through lib_match.Matcher
#     three times, varying ONLY the cross-encoder's batch_size (128, 16, 512), which changes per-batch padding
#     and so the GPU kernels. One row per pair per arm, 24,054 rows, totals derived from them. Arm 128
#     reproduced the baseline's OLD and GOLD to every digit, so the harness matched hardeval. The largest
#     benign move: GOLD -0.0000079 at batch 16, exactly ONE ordering (1/126,720), from a largest per-pair
#     score change of 0.0000065. OLD and MINED did not move. The rule written before the probe kept the bar
#     if every benign move was under half of it (0.00025); the largest was 63x under the bar, so it stands.
#     One variant, no revision. Not measured: a CPU fallback, a driver or torch upgrade, fp16.
DRIFT_BAR_AUC = 0.0005

VERDICT_OK, VERDICT_DRIFT, VERDICT_UNCOMPARABLE = "OK", "DRIFT", "UNCOMPARABLE"
# 3 is this estate's could-not-evaluate code. 4 because Python itself exits 1 on an uncaught exception and
# argparse exits 2, so neither can be mistaken for a drift. A caller still reads the verdict= token, never the
# number alone (backlog E2), and graph\pipeline\nightly.ps1 requires the two to agree.
EXIT_CODES = {VERDICT_OK: 0, VERDICT_DRIFT: 4, VERDICT_UNCOMPARABLE: 3}

ALWAYS_COMPARED = ("old", "gold")
COMPARED_WHEN_SIZES_MATCH = ("mined",)
SNAPSHOT_INPUTS = ("eval-positives.json", "negatives-gold.json", "negatives.json")
SAME_CONFIG_KEYS = ("embed_model", "rerank_model", "is_pinned_model", "holdout_only", "positives")


def record_path(out_dir: str, tag: str) -> str:
    """Where hardeval.py writes a tag's record. hardeval.py calls this too, so the two cannot disagree."""
    suffix = "" if tag == "stock" else f"-{tag}"
    return os.path.join(out_dir, f"hardeval{suffix}.json")


def report_path(out_dir: str, tag: str) -> str:
    suffix = "" if tag == "stock" else f"-{tag}"
    return os.path.join(out_dir, f"hardeval-report{suffix}.md")


def defs_label(defs: str | None, frozen: bool | None) -> str:
    """The snapshot a record was scored on, the way hardeval.py's summary line names it."""
    if not frozen or not defs:
        return "today"
    return os.path.basename(os.path.dirname(defs)) or "today"


def load_baseline(out_dir: str, tag: str) -> dict:
    """The baseline record, read BEFORE the run writes anything, so a run can never compare with its own output.

    Returns {"tag", "record", "defs", "defs_source", "why"}. `why` is None when the record is usable.
    """
    got = {"tag": tag, "record": None, "defs": None, "defs_source": None, "why": None}
    p = record_path(out_dir, tag)
    if not os.path.exists(p):
        got["why"] = f"no baseline record {os.path.basename(p)}"
        return got
    try:
        with io.open(p, encoding="utf-8-sig") as f:
            rec = json.load(f)
    except (OSError, ValueError) as e:
        got["why"] = f"baseline {os.path.basename(p)} unreadable: {e}"
        return got
    if not isinstance(rec, dict):
        got["why"] = f"baseline {os.path.basename(p)} is not a record"
        return got
    got["record"] = rec
    if "defs_frozen" in rec:
        got["defs"], got["defs_source"] = defs_label(rec.get("defs"), rec.get("defs_frozen")), "record"
    else:
        # A RECORD OLDER THAN THE defs KEY (added 2026-09-11) still names its snapshot, in the first line of the
        # report the same run wrote at the same moment: "... tag `phase3-frozen`, defs `phase3-baseline`)".
        try:
            with io.open(report_path(out_dir, tag), encoding="utf-8-sig") as f:
                m = re.search(r"defs `([^`]+)`", f.readline())
            if m:
                got["defs"], got["defs_source"] = m.group(1), "report header"
        except OSError:
            pass
    return got


def _parsed(path: str):
    with io.open(path, encoding="utf-8-sig") as f:
        return json.load(f)


def snapshot_inputs(data_dir: str, defs_path: str | None) -> dict:
    """Does each live eval set still equal the copy frozen beside the defs? name -> match|differs|no-copy|unreadable."""
    out = {}
    snap = os.path.dirname(defs_path) if defs_path else None
    for name in SNAPSHOT_INPUTS:
        copy = os.path.join(snap, name) if snap else None
        if not copy or not os.path.exists(copy):
            out[name] = "no-copy"
            continue
        try:
            out[name] = "match" if _parsed(os.path.join(data_dir, name)) == _parsed(copy) else "differs"
        except (OSError, ValueError):
            out[name] = "unreadable"
    return out


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) and not math.isnan(v) else None


def compare(current: dict, baseline: dict, inputs: dict | None = None, bar: float = DRIFT_BAR_AUC) -> dict:
    """The verdict, one row per set, and every reason the two records are not the same configuration."""
    rec = baseline.get("record") or {}
    why = []
    if baseline.get("why"):
        why.append(baseline["why"])
    if rec:
        if baseline.get("tag") == current.get("tag"):
            why.append(f"baseline tag {baseline.get('tag')} is this run's own tag, so it would agree with itself")
        for k in SAME_CONFIG_KEYS:
            if rec.get(k) != current.get(k):
                why.append(f"{k} {current.get(k)} vs baseline {rec.get(k)}")
        now_defs = defs_label(current.get("defs"), current.get("defs_frozen"))
        if now_defs == "today":
            why.append("this run scored today's defs, which drift with the board")
        if baseline.get("defs") is None:
            why.append("the baseline names no defs snapshot")
        elif baseline["defs"] != now_defs:
            why.append(f"defs {now_defs} vs baseline {baseline['defs']} ({baseline.get('defs_source')})")
    for name, state in sorted((inputs or {}).items()):
        if state in ("differs", "unreadable"):
            why.append(f"{name} {state} from the snapshot copy")

    sets = []
    moved = []
    for s in ALWAYS_COMPARED + COMPARED_WHEN_SIZES_MATCH:
        row = {"set": s, "n_now": current.get(s), "n_base": rec.get(s),
               "auc_now": _num(current.get("auc_" + s)), "auc_base": _num(rec.get("auc_" + s)),
               "delta": None, "state": None}
        if not rec:
            row["state"] = "no-baseline"
        elif row["auc_now"] is None or row["auc_base"] is None:
            row["state"] = "no-auc"
            if s in ALWAYS_COMPARED:
                why.append(f"{s} has no AUC (now {row['auc_now']}, baseline {row['auc_base']})")
        elif row["n_now"] != row["n_base"]:
            row["state"] = "not-compared"
            if s in ALWAYS_COMPARED:
                why.append(f"{s} n {row['n_now']} vs baseline {row['n_base']}")
        else:
            row["delta"] = row["auc_now"] - row["auc_base"]
            row["state"] = "moved" if abs(row["delta"]) > bar else "held"
            if row["state"] == "moved":
                moved.append(s)
        sets.append(row)

    verdict = VERDICT_UNCOMPARABLE if why else (VERDICT_DRIFT if moved else VERDICT_OK)
    return {"tag": baseline.get("tag"), "verdict": verdict, "bar": bar, "sets": sets, "moved": moved,
            "why": why, "inputs": inputs or {}, "baseline_generated": rec.get("generated"),
            "baseline_defs": baseline.get("defs"), "baseline_defs_source": baseline.get("defs_source")}


def exit_code(result: dict) -> int:
    return EXIT_CODES[result["verdict"]]


def summary_fields(result: dict) -> str:
    """The part of hardeval.py's last line that says what the comparison found, every delta with its sizes."""
    parts = [f"baseline={result['tag']}", f"verdict={result['verdict']}", f"bar={result['bar']:g}"]
    for r in result["sets"]:
        if r["state"] in ("held", "moved"):
            parts.append(f"{r['set']}={r['state']}({r['delta']:+.6f})")
        elif r["state"] == "not-compared":
            parts.append(f"{r['set']}=not-compared(n {r['n_now']} vs {r['n_base']})")
        else:
            parts.append(f"{r['set']}={r['state']}")
    if result["why"]:
        parts.append("why=" + "; ".join(result["why"]).replace(" ", "_"))
    return " ".join(parts)


def report_lines(result: dict) -> list[str]:
    """A section for hardeval's markdown report."""
    lines = [f"## Against the baseline `{result['tag']}`\n",
             f"Verdict **{result['verdict']}**. A set drifts when its AUC moves by more than {result['bar']:g} "
             f"from the tracked record (generated {result['baseline_generated']}, defs "
             f"`{result['baseline_defs']}` from its {result['baseline_defs_source']}).\n",
             "| set | n now | n baseline | AUC now | AUC baseline | delta | state |",
             "|---|---:|---:|---:|---:|---:|---|"]

    def f(v, spec):
        return "n/a" if v is None else format(v, spec)
    for r in result["sets"]:
        lines.append(f"| {r['set']} | {r['n_now']} | {r['n_base']} | {f(r['auc_now'], '.4f')} | "
                     f"{f(r['auc_base'], '.4f')} | {f(r['delta'], '+.6f')} | {r['state']} |")
    lines.append("")
    for w in result["why"]:
        lines.append(f"- not comparable: {w}")
    if result["inputs"]:
        lines.append("- eval sets against the snapshot copies: "
                     + ", ".join(f"{k} {v}" for k, v in sorted(result["inputs"].items())))
    lines.append("")
    return lines


# ------------------------------------------------------------------------------------------------ self-test
def selftest() -> int:                                         # noqa: C901
    passed, failed = [], []

    def T(name, cond, got=""):
        (passed if cond else failed).append(name)
        if not cond:
            print(f"  X {name}  (got: {got})")

    # THE TRACKED BASELINE AS IT STANDS, and the 2026-09-11 weekly run that reproduced it.
    base_rec = {"tag": "phase3-frozen", "embed_model": "BAAI/bge-m3", "rerank_model": "BAAI/bge-reranker-v2-m3",
                "is_pinned_model": True, "generated": "2026-08-23 01:06:50", "positives": 2816, "old": 25,
                "gold": 45, "mined": 4701, "holdout_only": None, "auc_old": 0.9705113636363636,
                "auc_gold": 0.8328559027777778, "auc_mined": 0.9559493658264199}
    week = {"tag": "weekly", "embed_model": "BAAI/bge-m3", "rerank_model": "BAAI/bge-reranker-v2-m3",
            "is_pinned_model": True, "defs": "sidecar\\data\\frozen\\phase3-baseline\\commodity-defs.json",
            "defs_frozen": True, "positives": 2816, "old": 25, "gold": 45, "mined": 5132, "holdout_only": None,
            "auc_old": 0.9705113636363636, "auc_gold": 0.8328559027777778, "auc_mined": 0.9543822904857224}

    def base(**over):
        r = dict(base_rec)
        r.update(over)
        return {"tag": "phase3-frozen", "record": r, "defs": "phase3-baseline", "defs_source": "report header",
                "why": None}

    def cur(**over):
        r = dict(week)
        r.update(over)
        return r

    def row(res, s):
        return next(r for r in res["sets"] if r["set"] == s)

    # -- the founding case: the week that reproduced the baseline
    res = compare(cur(), base())
    T("MUST NOT FIRE  the 2026-09-11 reproduction is OK, though MINED moved 0.0016 over a different-sized set",
      res["verdict"] == VERDICT_OK, res)
    T("CLEAN TWIN MINED is reported not-compared WITH both sizes, rather than dropped from the record",
      row(res, "mined")["state"] == "not-compared" and row(res, "mined")["n_now"] == 5132
      and row(res, "mined")["n_base"] == 4701, row(res, "mined"))
    T("CLEAN TWIN OLD and GOLD are compared and held at a delta of exactly 0",
      row(res, "old")["state"] == "held" and row(res, "gold")["state"] == "held"
      and row(res, "old")["delta"] == 0.0 and row(res, "gold")["delta"] == 0.0, res["sets"])
    T("CLEAN TWIN an OK exits 0", exit_code(res) == 0, exit_code(res))

    # -- DRIFT
    res = compare(cur(auc_gold=0.8312), base())
    T("MUST FIRE  GOLD moved by the reversed query/document defect's size (0.8329 -> 0.8312) is DRIFT",
      res["verdict"] == VERDICT_DRIFT and res["moved"] == ["gold"], res)
    T("CLEAN TWIN a DRIFT exits 4 and its line names the moved set with a signed delta",
      exit_code(res) == 4 and "verdict=DRIFT" in summary_fields(res)
      and "gold=moved(-0.001656)" in summary_fields(res), summary_fields(res))
    res = compare(cur(auc_old=week["auc_old"] + 0.0006), base())
    T("MUST FIRE  OLD alone moving 0.0006, just past the bar, is DRIFT", res["verdict"] == VERDICT_DRIFT, res)
    res = compare(cur(auc_old=week["auc_old"] - 0.0004), base())
    T("MUST NOT FIRE  OLD moving 0.0004, inside the bar, is OK", res["verdict"] == VERDICT_OK, res)
    T("CLEAN TWIN a move inside the bar is still written into the line to six places",
      "old=held(-0.000400)" in summary_fields(res), summary_fields(res))
    res = compare(cur(mined=4701, auc_mined=0.9540), base())
    T("MUST FIRE  MINED is compared when the sizes match, and a move past the bar is DRIFT",
      res["verdict"] == VERDICT_DRIFT and res["moved"] == ["mined"], res)

    # -- UNCOMPARABLE beats a moved number
    res = compare(cur(gold=46, auc_gold=0.70), base())
    T("MUST FIRE  a GOLD set of a different size is UNCOMPARABLE, never DRIFT and never a silent skip",
      res["verdict"] == VERDICT_UNCOMPARABLE and any("gold n 46" in w for w in res["why"]), res)
    T("CLEAN TWIN an UNCOMPARABLE exits 3 and its line carries the reason",
      exit_code(res) == 3 and "why=gold_n_46_vs_baseline_45" in summary_fields(res), summary_fields(res))
    res = compare(cur(positives=2900), base())
    T("MUST FIRE  a different positive count is UNCOMPARABLE", res["verdict"] == VERDICT_UNCOMPARABLE, res)
    res = compare(cur(rerank_model="C:/models/ft-v3", is_pinned_model=False, auc_gold=0.99), base())
    T("MUST FIRE  a candidate reranker against the stock baseline is UNCOMPARABLE, not a DRIFT",
      res["verdict"] == VERDICT_UNCOMPARABLE, res)
    res = compare(cur(defs="commodity-defs.json (today)", defs_frozen=False), base())
    T("MUST FIRE  a run on today's drifting defs is UNCOMPARABLE", res["verdict"] == VERDICT_UNCOMPARABLE, res)
    # FOUND BY A MUTANT (2026-09-11): with the today's-defs refusal deleted, the case above stayed green, because
    # the snapshot names already disagree. Two TODAY runs agree on the name and still measure two different shelves.
    today = base(defs="today", defs_source="record")
    res = compare(cur(defs="commodity-defs.json (today)", defs_frozen=False), today)
    T("MUST FIRE  a today's-defs run against a today's-defs baseline is UNCOMPARABLE, though both say today",
      res["verdict"] == VERDICT_UNCOMPARABLE and any("today's defs" in w for w in res["why"]), res)
    res = compare(cur(defs="sidecar\\data\\frozen\\phase4-baseline\\commodity-defs.json"), base())
    T("MUST FIRE  a different frozen snapshot is UNCOMPARABLE",
      res["verdict"] == VERDICT_UNCOMPARABLE and any("phase4-baseline" in w for w in res["why"]), res)
    res = compare(cur(tag="phase3-frozen"), base())
    T("MUST FIRE  a run compared with its own tag is refused, because it would agree with itself",
      res["verdict"] == VERDICT_UNCOMPARABLE, res)
    res = compare(cur(auc_gold=float("nan")), base())
    T("MUST FIRE  a GOLD AUC of NaN is UNCOMPARABLE, never a held set", res["verdict"] == VERDICT_UNCOMPARABLE, res)
    res = compare(cur(), {"tag": "phase3-frozen", "record": None, "defs": None, "defs_source": None,
                          "why": "no baseline record hardeval-phase3-frozen.json"})
    T("MUST FIRE  a missing baseline is UNCOMPARABLE and says which file",
      res["verdict"] == VERDICT_UNCOMPARABLE and "hardeval-phase3-frozen.json" in "; ".join(res["why"]), res)
    res = compare(cur(), base(), inputs={"eval-positives.json": "differs", "negatives-gold.json": "match"})
    T("MUST FIRE  an eval set that no longer equals its snapshot copy is UNCOMPARABLE",
      res["verdict"] == VERDICT_UNCOMPARABLE and any("eval-positives.json differs" in w for w in res["why"]), res)
    res = compare(cur(), base(), inputs={n: "no-copy" for n in SNAPSHOT_INPUTS})
    T("CLEAN TWIN a snapshot that holds no copies is still compared, and OK", res["verdict"] == VERDICT_OK, res)

    # -- files: paths, the report-header fallback, the fingerprint, and the tracked record itself
    tmp = tempfile.mkdtemp(prefix="hb-")
    try:
        T("CLEAN TWIN record_path matches hardeval's suffix rule",
          record_path("o", "stock") == os.path.join("o", "hardeval.json")
          and record_path("o", "phase3-frozen") == os.path.join("o", "hardeval-phase3-frozen.json"),
          record_path("o", "phase3-frozen"))
        with io.open(record_path(tmp, "phase3-frozen"), "w", encoding="utf-8") as f:
            json.dump(base_rec, f)
        with io.open(report_path(tmp, "phase3-frozen"), "w", encoding="utf-8") as f:
            f.write("# Identity matcher: the harder eval (2026-08-23, tag `phase3-frozen`, defs `phase3-baseline`)\n")
        got = load_baseline(tmp, "phase3-frozen")
        T("CLEAN TWIN a record older than the defs key reads its snapshot from its own report header",
          got["why"] is None and got["defs"] == "phase3-baseline" and got["defs_source"] == "report header", got)
        T("CLEAN TWIN that loaded baseline compares OK against the reproduction",
          compare(cur(), got)["verdict"] == VERDICT_OK, compare(cur(), got))
        os.remove(report_path(tmp, "phase3-frozen"))
        got = load_baseline(tmp, "phase3-frozen")
        T("MUST FIRE  with neither a defs key nor a report header the baseline is UNCOMPARABLE",
          compare(cur(), got)["verdict"] == VERDICT_UNCOMPARABLE, compare(cur(), got))
        T("MUST FIRE  a tag with no record reports the missing file by name",
          "hardeval-nope.json" in (load_baseline(tmp, "nope")["why"] or ""), load_baseline(tmp, "nope"))

        data, snap = os.path.join(tmp, "data"), os.path.join(tmp, "data", "frozen", "snap")
        os.makedirs(snap)
        rows = [{"product": "Yellow Bananas", "id": "bananas"}, {"product": "Wimmer's Wieners", "id": "hot-dogs"}]
        for name in SNAPSHOT_INPUTS:
            with io.open(os.path.join(data, name), "w", encoding="utf-8", newline="\r\n") as f:
                json.dump(rows, f, indent=1)
            with io.open(os.path.join(snap, name), "w", encoding="utf-8", newline="\n") as f:
                json.dump(rows, f, indent=1)
        defs = os.path.join(snap, "commodity-defs.json")
        got = snapshot_inputs(data, defs)
        T("MUST NOT FIRE  a CRLF live file and its LF snapshot copy with the same rows match",
          set(got.values()) == {"match"}, got)
        with io.open(os.path.join(data, "negatives-gold.json"), "w", encoding="utf-8") as f:
            json.dump(rows[:1], f)
        got = snapshot_inputs(data, defs)
        T("MUST FIRE  a live eval set with a row removed differs from its snapshot copy",
          got["negatives-gold.json"] == "differs" and got["negatives.json"] == "match", got)
        T("CLEAN TWIN no snapshot directory reads as no-copy for every input",
          set(snapshot_inputs(data, None).values()) == {"no-copy"}, snapshot_inputs(data, None))

        tracked = os.path.join(HERE, "out")
        got = load_baseline(tracked, "phase3-frozen")
        T("CLEAN TWIN the TRACKED phase3-frozen record loads, names phase3-baseline, and the reproduction is OK",
          got["why"] is None and got["defs"] == "phase3-baseline"
          and compare(cur(), got)["verdict"] == VERDICT_OK, (got, compare(cur(), got) if got["record"] else None))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    total = len(passed) + len(failed)
    print(f"hardeval_baseline selftest: {len(passed)} of {total} cases passed")
    return 0 if not failed else 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    print(__doc__)
    sys.exit(2)
