"""Guarded hillclimb of ONE text surface: the resolver's layer-5 system prompt (W5 of
design/PLAN-eval-heldout-and-hillclimb-2026-09-29.md).

    python graph/bench/hillclimb_prompt.py --round 0                      # live prompt, train rows
    python graph/bench/hillclimb_prompt.py --round K --candidate FILE     # one patched prompt
    python graph/bench/hillclimb_prompt.py --train-failures [--round K]   # what the next patch reads
    python graph/bench/hillclimb_prompt.py --report                       # totals DERIVED from the rows
    python graph/bench/hillclimb_prompt.py --selftest

THE SURFACE. `resolve.RESOLVE_SYSTEM` (PROMPT_VERSION resolve-v5-reject-only-adjudicated-priors),
tried through `Resolver(system_prompt=...)` so the live text is never edited. score.py --llm
exercises it: layer 5 runs on every case no include/exclude rule settles. THE LOOP NEVER PROMOTES.
Its output is a candidate prompt file plus these rows; promotion is a separate reviewed commit that
edits RESOLVE_SYSTEM and bumps PROMPT_VERSION.

WHAT IS SCORED, AND WHY NOT score.py's MISSED-MERGE. Verdict.is_match counts include_hit and
llm_confirmed only, and the local model can return neither, so score.py's false-merge and
missed-merge are the same number under ANY prompt. The pair a prompt moves is the model's own
verdict on the cases that reach it (score.score docstring):
    adj_missed   gold MATCH cases the model reached and did not lead as MATCH
    adj_false    gold NO_MATCH cases the model led as MATCH (the dangerous one)
Brad's D2 bar is applied to that pair. The arm is score.py's `llm` arm: bank OFF, so the model is
shown no prior rulings (the cold-start condition).

THE CASES. A FIXED KEYED SAMPLE (Brad 2026-09-29): score_health.sample_rows, 60 `uncertain` rows per
split, salt SAMPLE_SALT. Of those, the ones layer 5 reaches are the denominators. EVERY NUMBER HERE
IS A SAMPLE NUMBER.

THE BAR, WRITTEN BEFORE ANY CANDIDATE WAS SCORED (ms-03), in counts over the fixed denominators.
REVISED BY BRAD ON 2026-09-29, after the baseline reading (holdout floor run 1: adj_false 11 of 17,
adj_missed 3 of 14) and before any candidate was scored. The original D2 (STRICT: false may not rise
on either split AND holdout missed must fall past its spread) is branch (b) below, unchanged.
"Spread" is max minus min of the three noise-floor runs of that metric on that split.
Keep a round if EITHER
  (a) holdout adj_false FALLS by more than the holdout adj_false spread, AND holdout adj_missed does
      not RISE by more than the holdout adj_missed spread, AND train adj_false does not RISE by more
      than the train adj_false spread;
  OR
  (b) holdout adj_missed FALLS by more than the holdout adj_missed spread, AND adj_false does not
      rise at all on either split (candidate <= reference, not by one case).
Otherwise revert.
  The reference for round 1 is the MEDIAN of the three noise-floor runs; after a kept round it is
  that round's own measurement. A candidate whose reached-case denominators differ from the
  reference's is not comparable and is reverted (DENOMINATOR-MOVED).
  Train is scored first; a candidate whose train adj_false rises by more than the train spread
  fails both branches, and is reverted without spending the holdout pass; the row says so.

THE LOOP. One targeted patch per round, written from TRAIN-sample failures only (--train-failures
prints train cases and never a holdout case). Keep if the bar holds, else revert. Stop after 3
consecutive flat (reverted) rounds and write a failure analysis; never more than 6 rounds.
Who writes the patch: the session running the loop, by hand from the train failures; no API model.

TRANSCRIPTION BAN (mechanical). The text a candidate ADDS to the live prompt is refused if it holds
a HOLDOUT gold product string, a HOLDOUT commodity name (slug, hyphen or space form), or a TRAIN gold
product string verbatim ("never copy failing outputs into the prompt"). Only added lines are
checked, so a name the live prompt already carries does not refuse every candidate. Product strings
under 6 characters are not checked (they match ordinary words).

ROWS (ms-04): graph/bench/out/hillclimb-2026-09-29.jsonl, one row per case per split per round.
Every total --report prints is derived from that file, with the round count and variants tried.

SCOPE OF A CLEAN REPORT: UNSOUND as evidence a candidate is better beyond this sample (a two-split
verdict on about 25 and 31 reached cases is itself noisy; the overnight full-gold run confirms);
COMPLETE for a refusal by the ban (a matched string IS the transcription).
Exit: 0 round scored or report printed, 1 self-test fail, 2 could not run (model down, blind index,
ban refused, loop already stopped). Last line: HILLCLIMB-COMPLETE ...
"""
# gate-inputs: graph\bench\hillclimb_prompt.py

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
for sub in ("graph/lib", "graph/pipeline", "graph/gold", "graph/eval"):
    sys.path.insert(0, os.path.join(ROOT, sub))

TAG = "2026-09-29"
OUT_DIR = os.path.join(HERE, "out")
ROWS = os.path.join(OUT_DIR, f"hillclimb-{TAG}.jsonl")
STATE = os.path.join(OUT_DIR, f"hillclimb-{TAG}-state.json")
N_PER_SPLIT = 60
MAX_ROUNDS = 6
FLAT_STOP = 3
MIN_PRODUCT_LEN = 6

# THE MEASURED SAMPLE NOISE FLOOR (Part 2): `score.py --health --sample 60 --runs 3`, llm arm, live
# prompt. Filled from graph/bench/out/noise-floor-sample-2026-09-29.log before round 1 ran.
FLOOR = {
    "measured": True,   # 2026-09-29, live prompt, llm arm (bank off), deterministic spread 0 on every metric
    "sample_fingerprint": "350165098f67fc0f4080c06a0f1bf055bd3436ab2d9160577d63d2d9a45bafba",
    "gold_blob": "83bf82949038938221a4d125cafd251b8a91f864",
    "train": {"adj_false": [9, 7, 7], "adj_missed": [0, 0, 0], "adj_no_match_n": 13, "adj_match_n": 12},
    "holdout": {"adj_false": [11, 12, 12], "adj_missed": [3, 3, 3], "adj_no_match_n": 17, "adj_match_n": 14},
}


def spread_of(vals: list[int]) -> int:
    return (max(vals) - min(vals)) if vals else 0


def floor_reference(floor: dict) -> dict:
    """The round-1 reference: per split the MEDIAN of the three floor runs, plus the holdout spread."""
    ref = {}
    for sp in ("train", "holdout"):
        f = floor[sp]
        ref[sp] = {"adj_false": statistics.median(f["adj_false"]),
                   "adj_missed": statistics.median(f["adj_missed"]),
                   "adj_no_match_n": f["adj_no_match_n"], "adj_match_n": f["adj_match_n"]}
    ref["spreads"] = {"train_false": spread_of(floor["train"]["adj_false"]),
                      "holdout_false": spread_of(floor["holdout"]["adj_false"]),
                      "holdout_missed": spread_of(floor["holdout"]["adj_missed"])}
    return ref


# -- the ban -----------------------------------------------------------------------------------

def _norm(s: str) -> str:
    return re.sub(r"\s+", " ", str(s or "").lower()).strip()


def ban_terms(gold: list[dict], split_of, key_of) -> dict:
    t = {"holdout_product": set(), "holdout_name": set(), "train_product": set()}
    for g in gold:
        sp = split_of(g)
        prod = _norm(g.get("product"))
        if len(prod) >= MIN_PRODUCT_LEN:
            t["train_product" if sp == "train" else "holdout_product"].add(prod)
        if sp == "holdout":
            for name in (key_of(g), g.get("commodity")):
                if name:
                    t["holdout_name"].add(_norm(name))
    return t


def added_text(candidate: str, base: str) -> str:
    have = {_norm(x) for x in base.splitlines()}
    return "\n".join(x for x in candidate.splitlines() if _norm(x) not in have)


def transcription_violations(candidate: str, base: str, terms: dict) -> list[str]:
    add = _norm(added_text(candidate, base))
    out = []
    for p in sorted(terms["holdout_product"]):
        if p in add:
            out.append(f"holdout product: {p!r}")
    for p in sorted(terms["train_product"]):
        if p in add:
            out.append(f"train product verbatim: {p!r}")
    for n in sorted(terms["holdout_name"]):
        for form in {n, n.replace("-", " ")}:
            if re.search(r"(?<![a-z0-9])" + re.escape(form) + r"(?![a-z0-9])", add):
                out.append(f"holdout commodity: {form!r}")
                break
    return out


# -- the bar -----------------------------------------------------------------------------------

def decide(ref: dict, cand: dict, spreads: dict) -> tuple[bool, list[str]]:
    """Brad's revised D2 (header). ref/cand: {split: {adj_false, adj_missed, adj_no_match_n,
    adj_match_n}}; cand may lack 'holdout' when train already failed. spreads: {"train_false",
    "holdout_false", "holdout_missed"} in counts. Returns (keep, reasons). Pure."""
    why = []
    for sp in ("train", "holdout"):
        if sp in cand:
            r, c = ref[sp], cand[sp]
            if (r["adj_no_match_n"], r["adj_match_n"]) != (c["adj_no_match_n"], c["adj_match_n"]):
                why.append(f"DENOMINATOR-MOVED {sp}: {r['adj_match_n']}/{r['adj_no_match_n']} -> "
                           f"{c['adj_match_n']}/{c['adj_no_match_n']}")
    if why:
        return False, why
    tr_rise = cand["train"]["adj_false"] - ref["train"]["adj_false"]
    if "holdout" not in cand:
        return False, [f"TRAIN-FALSE-ROSE {tr_rise} (past train spread {spreads['train_false']}); "
                       f"HOLDOUT-NOT-SCORED"]
    ho_false_fall = ref["holdout"]["adj_false"] - cand["holdout"]["adj_false"]
    ho_missed_fall = ref["holdout"]["adj_missed"] - cand["holdout"]["adj_missed"]
    a = (ho_false_fall > spreads["holdout_false"]
         and -ho_missed_fall <= spreads["holdout_missed"]
         and tr_rise <= spreads["train_false"])
    b = (ho_missed_fall > spreads["holdout_missed"] and tr_rise <= 0 and ho_false_fall >= 0)
    if a or b:
        return True, [f"KEPT by branch {'a' if a else 'b'}{' and b' if a and b else ''}"]
    return False, [f"(a) fails: holdout false fell {ho_false_fall} (need > {spreads['holdout_false']}), "
                   f"holdout missed rose {-ho_missed_fall} (max {spreads['holdout_missed']}), "
                   f"train false rose {tr_rise} (max {spreads['train_false']})",
                   f"(b) fails: holdout missed fell {ho_missed_fall} (need > {spreads['holdout_missed']}), "
                   f"false rose train {tr_rise} holdout {-ho_false_fall} (max 0)"]


def should_stop(history: list[bool], max_rounds: int = MAX_ROUNDS, flat_stop: int = FLAT_STOP) -> str | None:
    """history: kept? per scored round, in order. A reason to stop, or None."""
    if len(history) >= max_rounds:
        return f"ROUND-CAP {len(history)} of {max_rounds}"
    tail = 0
    for kept in reversed(history):
        if kept:
            break
        tail += 1
    if tail >= flat_stop:
        return f"FLAT-STOP {tail} consecutive flat rounds"
    return None


# -- the run -----------------------------------------------------------------------------------

def _sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _load_state() -> dict:
    if os.path.exists(STATE):
        with open(STATE, encoding="utf-8") as fh:
            return json.load(fh)
    return {"history": [], "incumbent": None, "rounds": {}}


def _save_state(st: dict) -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(st, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, STATE)


def _append_rows(rows: list[dict]) -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(ROWS, "a", encoding="utf-8", newline="\n") as fh:
        for r in rows:
            fh.write(json.dumps(r, sort_keys=True, ensure_ascii=False) + "\n")


def _read_rows() -> list[dict]:
    if not os.path.exists(ROWS):
        return []
    with open(ROWS, encoding="utf-8") as fh:
        return [json.loads(x) for x in fh if x.strip()]


def _counts(case_rows: list[dict]) -> dict:
    reached = [r for r in case_rows if r["reached_llm"]]
    m = [r for r in reached if r["label"] == "MATCH"]
    n = [r for r in reached if r["label"] != "MATCH"]
    return {"adj_match_n": len(m), "adj_no_match_n": len(n),
            "adj_missed": sum(1 for r in m if not r["llm_led_match"]),
            "adj_false": sum(1 for r in n if r["llm_led_match"]),
            "adj_rejected_true": sum(1 for r in m if r["status"] == "llm_rejected"),
            "llm_errors": sum(1 for r in reached if str(r.get("reason", "")).startswith("llm error"))}


def _score_split(db, llm, rows_gold, system_prompt, rnd, sp, variant, gold_by_id):
    from score import score
    case_rows: list[dict] = []
    t = time.time()
    m = score(db, rows_gold, use_llm=True, llm=llm, use_bank=False,
              system_prompt=system_prompt, case_rows=case_rows)
    if m["counts"]["missing_node"] == len(rows_gold):
        raise SystemExit("BLIND: the index holds none of the sampled commodities (copy graph.db in)")
    out = []
    for r in case_rows:
        g = gold_by_id[r["id"]]
        out.append({**r, "round": rnd, "split": sp, "variant": variant,
                    "commodity": g["commodity"], "product": g["product"]})
    c = _counts(out)
    print(f"  round {rnd} {sp}: adj_false {c['adj_false']} of {c['adj_no_match_n']}  "
          f"adj_missed {c['adj_missed']} of {c['adj_match_n']}  rejected_true {c['adj_rejected_true']}  "
          f"llm_errors {c['llm_errors']}  (score.py fm={m['false_merge_rate']:.4f} "
          f"mm={m['missed_merge_rate']:.4f}, unmovable by a prompt)  {time.time()-t:.0f}s", flush=True)
    return out, c


def run_round(rnd: int, candidate_path: str | None) -> int:
    from graphdb import open_db
    from llm import LocalLLM
    from resolve import RESOLVE_SYSTEM
    from seed_gold import load_gold
    from gold_split import split_of, key_of
    from score_health import sample_rows, print_sample_info

    st = _load_state()
    if rnd > 0:
        stop = should_stop(st["history"])
        if stop:
            print(f"REFUSED: the loop has stopped ({stop}); write the failure analysis")
            return 2
        if not FLOOR["measured"]:
            print("REFUSED: FLOOR is not measured yet; the bar needs it before round 1 (ms-03)")
            return 2
    base = RESOLVE_SYSTEM
    cand = base if candidate_path is None else open(candidate_path, encoding="utf-8").read()
    gold = load_gold()
    if candidate_path is not None:
        v = transcription_violations(cand, base, ban_terms(gold, split_of, key_of))
        if v:
            print("REFUSED by the transcription ban:")
            for x in v:
                print(f"  {x}")
            print(f"HILLCLIMB-COMPLETE round={rnd} refused=ban")
            return 2
        if cand == base:
            print("REFUSED: the candidate IS the live prompt")
            return 2
    variant = "live" if cand == base else "cand:" + _sha(cand)[:12]
    sample, info = sample_rows(gold, N_PER_SPLIT, split_of)
    print_sample_info(info)
    if info["fingerprint"] != FLOOR["sample_fingerprint"]:
        print(f"REFUSED: sample fingerprint {info['fingerprint'][:16]} is not the floor's "
              f"{FLOOR['sample_fingerprint'][:16]} (gold moved?)")
        return 2
    llm = LocalLLM()
    if not llm.health():
        print("could not run: local model down (tools/local-llm/serve.ps1 -Slots 1)")
        return 2
    gold_by_id = {g["id"]: g for g in gold}
    sp_list = ("train",) if rnd == 0 else ("train", "holdout")
    measured, all_rows = {}, []
    ref = None
    if rnd > 0:
        ref = st["incumbent"] or floor_reference(FLOOR)
    with open_db() as db:
        for sp in sp_list:
            rows, c = _score_split(db, llm, sample[sp], None if cand == base else cand,
                                   rnd, sp, variant, gold_by_id)
            all_rows += rows
            measured[sp] = c
            if (rnd > 0 and sp == "train" and c["adj_false"] - ref["train"]["adj_false"]
                    > floor_reference(FLOOR)["spreads"]["train_false"]):
                print("  train false rose past its spread (fails both branches): holdout pass skipped")
                break
    keep, why = (False, ["baseline round"]) if rnd == 0 else decide(
        ref, measured, floor_reference(FLOOR)["spreads"])
    for r in all_rows:
        r["kept"] = keep
    _append_rows(all_rows)
    st["rounds"][str(rnd)] = {"variant": variant, "candidate": candidate_path, "measured": measured,
                              "reference": ref, "kept": keep, "why": why}
    if rnd > 0:
        st["history"].append(keep)
        if keep:
            st["incumbent"] = {**measured, "variant": variant, "round": rnd}
            with open(os.path.join(OUT_DIR, f"hillclimb-{TAG}-candidate.txt"), "w",
                      encoding="utf-8", newline="\n") as fh:
                fh.write(cand)
    _save_state(st)
    print(f"  round {rnd} {'KEPT' if keep else 'REVERTED'}: {'; '.join(why) or 'bar met on both splits'}")
    stop = should_stop(st["history"])
    print(f"HILLCLIMB-COMPLETE round={rnd} variant={variant} kept={keep} stop={stop or 'no'}")
    return 0


def train_failures(rnd: int | None) -> int:
    rows = [r for r in _read_rows() if r["split"] == "train"]
    if rnd is None:
        rnd = max((r["round"] for r in rows), default=None)
    rows = [r for r in rows if r["round"] == rnd]
    bad = [r for r in rows if r["reached_llm"] and (
        (r["label"] == "MATCH") != bool(r["llm_led_match"]))]
    print(f"train failures, round {rnd}: {len(bad)} of {sum(1 for r in rows if r['reached_llm'])} reached")
    for r in bad:
        kind = "MISSED" if r["label"] == "MATCH" else "FALSE-LEAD"
        print(f"  [{kind}] {r['commodity']} | {r['product']}\n      {r['status']}: {r['reason'][:200]}")
    print(f"HILLCLIMB-COMPLETE train-failures round={rnd} n={len(bad)}")
    return 0


def full_confirm() -> int:
    """The overnight confirmation (Brad 2026-09-29): FULL gold, each split, live prompt then the kept
    candidate (if any), llm arm. Rows go to an UNTRACKED file; nothing here is committed by a run."""
    from graphdb import open_db
    from llm import LocalLLM
    from seed_gold import load_gold
    from gold_split import filter_split
    out_path = os.path.join(OUT_DIR, f"overnight-full-confirm-{TAG}.jsonl")
    cand_path = os.path.join(OUT_DIR, f"hillclimb-{TAG}-candidate.txt")
    cand = open(cand_path, encoding="utf-8").read() if os.path.exists(cand_path) else None
    llm = LocalLLM()
    if not llm.health():
        print("could not run: local model down")
        return 2
    gold = [g for g in load_gold() if g["kind"] == "match"]
    arms = [("live", None)] + ([("cand:" + _sha(cand)[:12], cand)] if cand else [])
    by_id = {g["id"]: g for g in gold}
    res = {}
    with open_db() as db:
        for sp in ("train", "holdout"):
            sub = filter_split(gold, sp)
            for name, text in arms:
                from score import score
                rows: list[dict] = []
                t = time.time()
                score(db, sub, use_llm=True, llm=llm, use_bank=False, system_prompt=text, case_rows=rows)
                with open(out_path, "a", encoding="utf-8", newline="\n") as fh:
                    for r in rows:
                        g = by_id[r["id"]]
                        fh.write(json.dumps({**r, "split": sp, "variant": name, "commodity": g["commodity"],
                                             "product": g["product"]}, ensure_ascii=False) + "\n")
                c = _counts([{**r} for r in rows])
                res[(sp, name)] = c
                print(f"  FULL {sp} {name}: adj_false {c['adj_false']} of {c['adj_no_match_n']}  "
                      f"adj_missed {c['adj_missed']} of {c['adj_match_n']}  {time.time()-t:.0f}s", flush=True)
    if cand:
        live, cn = arms[0][0], arms[1][0]
        for sp in ("train", "holdout"):
            a, b = res[(sp, live)], res[(sp, cn)]
            print(f"  FULL {sp} delta candidate minus live: adj_false {b['adj_false'] - a['adj_false']:+d}  "
                  f"adj_missed {b['adj_missed'] - a['adj_missed']:+d}  (one run per arm; the full-gold noise "
                  f"floor is in the --health block above this in the log)")
    print(f"HILLCLIMB-COMPLETE full-confirm arms={len(arms)} rows_file={out_path}")
    return 0


def report() -> int:
    rows = _read_rows()
    rounds = sorted({r["round"] for r in rows})
    variants = sorted({r["variant"] for r in rows if r["round"] > 0})
    print(f"rows {len(rows)} from {ROWS}")
    kept_any = None
    for rnd in rounds:
        for sp in ("train", "holdout"):
            sub = [r for r in rows if r["round"] == rnd and r["split"] == sp]
            if not sub:
                continue
            c = _counts(sub)
            print(f"  round {rnd} {sp:7s} {sub[0]['variant']:22s} adj_false {c['adj_false']} of "
                  f"{c['adj_no_match_n']}  adj_missed {c['adj_missed']} of {c['adj_match_n']}  "
                  f"kept={sub[0]['kept']}")
            if sub[0]["kept"] and rnd > 0:
                kept_any = sub[0]["variant"]
    print(f"FLOOR measured={FLOOR['measured']} holdout adj_missed values={FLOOR['holdout']['adj_missed']} "
          f"train adj_false values={FLOOR['train']['adj_false']} holdout adj_false values="
          f"{FLOOR['holdout']['adj_false']}")
    n_rounds = len([x for x in rounds if x > 0])
    print(f"HILLCLIMB-COMPLETE rounds={n_rounds} variants_tried={len(variants)} "
          f"candidate={kept_any or 'none'} (SAMPLE numbers)")
    return 0


# -- self-test ---------------------------------------------------------------------------------

def selftest() -> int:
    cases = []

    def T(name, ok, detail=""):
        cases.append((name, bool(ok), detail))

    def fsplit(g):
        return "holdout" if g["commodity_node"].endswith(("feta", "ground-beef")) else "train"

    def fkey(g):
        return g["commodity_node"].rsplit(":", 1)[1]

    gold = [{"commodity": "feta-cheese", "commodity_node": "commodity:staple:feta",
             "product": "Athenos Crumbled Feta Cheese 6 oz"},
            {"commodity": "ground-beef", "commodity_node": "commodity:staple:ground-beef",
             "product": "Hy-Vee 80/20 Ground Chuck 1 lb"},
            {"commodity": "rice", "commodity_node": "commodity:staple:rice",
             "product": "Mahatma Extra Long Grain White Rice 5 lb"},
            {"commodity": "oats", "commodity_node": "commodity:staple:oats", "product": "Oats"}]
    terms = ban_terms(gold, fsplit, fkey)
    base = "You adjudicate listings.\nNever match ground beef to anything but ground beef.\n"
    ban = lambda c: transcription_violations(c, base, terms)   # noqa: E731
    T("MUST FIRE a holdout product string added to the prompt is refused",
      any("holdout product" in v for v in ban(base + "- e.g. athenos crumbled feta cheese 6 OZ\n")))
    T("MUST FIRE a holdout commodity slug, hyphen form, is refused",
      any("holdout commodity" in v for v in ban(base + "- treat feta-cheese as cheese\n")))
    T("MUST FIRE a holdout commodity, space form, is refused",
      any("holdout commodity" in v for v in ban(base + "- Feta cheese crumbles count\n")))
    T("MUST FIRE a train product copied verbatim is refused",
      any("train product" in v for v in ban(base + "Mahatma Extra Long Grain White Rice 5 lb is rice\n")))
    T("MUST NOT FIRE a generic rule naming no gold string",
      ban(base + "- A flavour word alone never makes a different food.\n") == [])
    T("CLEAN TWIN a holdout name the LIVE prompt already carries does not refuse the candidate",
      ban(base + "- Seasoning packets are not the food.\n") == [])
    T("MUST NOT FIRE a train product under 6 characters ('Oats') is not checked",
      ban(base + "- Oats are a grain.\n") == [])
    T("MUST NOT FIRE a slug inside a longer word is not a hit ('fetal')",
      ban(base + "- fetal is not a food\n") == [])

    def S(f_tr, f_ho, m_ho, n=(4, 8)):
        return {"train": {"adj_false": f_tr, "adj_missed": 4, "adj_no_match_n": n[0], "adj_match_n": n[1]},
                "holdout": {"adj_false": f_ho, "adj_missed": m_ho, "adj_no_match_n": n[0], "adj_match_n": n[1]}}
    sp2 = {"train_false": 2, "holdout_false": 2, "holdout_missed": 2}
    ref = S(4, 6, 6)
    D = lambda c: decide(ref, c, sp2)   # noqa: E731
    # branch (b): missed falls past its spread, false flat everywhere
    T("MUST NOT FIRE (b) holdout missed falls 2, exactly AT a spread of 2, is REVERTED", D(S(4, 6, 4))[0] is False, D(S(4, 6, 4)))
    T("MUST FIRE (b) holdout missed falls 3, one step PAST a spread of 2, is KEPT", D(S(4, 6, 3))[0] is True, D(S(4, 6, 3)))
    T("MUST FIRE (b) misses fall but a holdout wrong merge rises by ONE: REVERTED", D(S(4, 7, 0))[0] is False, D(S(4, 7, 0)))
    T("MUST FIRE (b) misses fall but a train wrong merge rises by ONE (holdout false flat): REVERTED",
      D(S(5, 6, 0))[0] is False, D(S(5, 6, 0)))
    # branch (a): holdout false falls past its spread
    T("MUST NOT FIRE (a) holdout false falls 2, exactly AT a spread of 2, is REVERTED", D(S(4, 4, 6))[0] is False, D(S(4, 4, 6)))
    T("MUST FIRE (a) holdout false falls 3, one step PAST a spread of 2, is KEPT", D(S(4, 3, 6))[0] is True, D(S(4, 3, 6)))
    T("CLEAN TWIN (a) holdout missed rises 2, exactly AT its spread, still KEPT", D(S(4, 3, 8))[0] is True, D(S(4, 3, 8)))
    T("MUST FIRE (a) holdout missed rises 3, one step PAST its spread: REVERTED", D(S(4, 3, 9))[0] is False, D(S(4, 3, 9)))
    T("CLEAN TWIN (a) train false rises 2, exactly AT its spread, still KEPT", D(S(6, 3, 6))[0] is True, D(S(6, 3, 6)))
    T("MUST FIRE (a) train false rises 3, one step PAST its spread: REVERTED", D(S(7, 3, 6))[0] is False, D(S(7, 3, 6)))
    T("MUST FIRE revert: a moved denominator is not comparable",
      "DENOMINATOR-MOVED" in " ".join(D(S(4, 0, 0, n=(5, 8)))[1]))
    T("MUST FIRE revert: train failed, holdout unscored, says so",
      D({"train": S(7, 0, 0)["train"]})[0] is False and "HOLDOUT-NOT-SCORED" in " ".join(D({"train": S(7, 0, 0)["train"]})[1]))

    T("MUST NOT FIRE stop: 2 consecutive flat rounds continue", should_stop([True, False, False]) is None)
    T("MUST FIRE stop: 3 consecutive flat rounds stop", (should_stop([False, False, False]) or "").startswith("FLAT-STOP 3"))
    T("CLEAN TWIN a kept round resets the flat count", should_stop([False, False, True, False, False]) is None)
    T("MUST FIRE stop: the 6-round cap", (should_stop([True, False, True, False, True, False]) or "").startswith("ROUND-CAP"))
    T("MUST NOT FIRE stop: 5 rounds with no flat run is under the cap", should_stop([True, False, True, False, True]) is None)
    fl = {"train": {"adj_false": [1, 2, 1], "adj_missed": [5, 5, 6], "adj_no_match_n": 4, "adj_match_n": 8},
          "holdout": {"adj_false": [0, 0, 1], "adj_missed": [7, 9, 8], "adj_no_match_n": 4, "adj_match_n": 8}}
    fr = floor_reference(fl)
    T("CLEAN TWIN the round-1 reference is the median of three floor runs, spread max minus min",
      fr["train"]["adj_false"] == 1 and fr["holdout"]["adj_missed"] == 8
      and fr["spreads"] == {"train_false": 1, "holdout_false": 1, "holdout_missed": 2}, fr)

    fails = 0
    for name, ok, detail in cases:
        print(f"  {'ok  ' if ok else 'FAIL'} {name}")
        if not ok:
            fails += 1
            print(f"       {detail!r}")
    if len(cases) != 26:
        print(f"hillclimb_prompt self-test FAIL: ran {len(cases)} cases, expected 26")
        return 1
    print(f"hillclimb_prompt: {len(cases) - fails} of {len(cases)} cases passed")
    print(f"hillclimb_prompt self-test {'pass' if fails == 0 else 'FAIL'}")
    return 0 if fails == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--round", type=int)
    ap.add_argument("--candidate")
    ap.add_argument("--train-failures", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--full-confirm", action="store_true", help="overnight: full gold, live vs candidate")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.full_confirm:
        return full_confirm()
    if a.train_failures:
        return train_failures(a.round)
    if a.report:
        return report()
    if a.round is None:
        ap.error("--round, --train-failures, --report or --selftest")
    if a.round > 0 and not a.candidate:
        ap.error("--round K>0 needs --candidate FILE")
    return run_round(a.round, a.candidate)


if __name__ == "__main__":
    raise SystemExit(main())
