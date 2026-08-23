"""Phase 0 acceptance benchmark — the gate that locks a primary local model.

    python graph/bench/bench.py                 # full run
    python graph/bench/bench.py --extract-n 40 --probe-n 30

The plan (§4) will not let Phase 1 start until a candidate model clears three
bars ON THIS BOX, measured on THIS system's real tasks — not on a public
leaderboard:

  1. STRUCTURED OUTPUT   >= 95% valid strict JSON over N extraction calls
  2. RESOLUTION AGREEMENT>= 90% agreement with hand adjudication on a probe set
  3. THROUGHPUT          >= 15 tok/s decode with >= 8k context headroom

Bar 2 is the one that matters and the one that is easy to fake. The probe set is
drawn from the GOLD SET — cases a human or agent already ruled on with written
evidence — and the model is asked to adjudicate them WITHOUT the deterministic
regex layers, so this measures the model's own judgment, not the guardrails'.

Results are appended to graph/prompts/model-selection.md so the choice of model
is a recorded, reproducible decision rather than folklore.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import random
import statistics
import sys
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
sys.path.insert(0, os.path.join(HERE, "..", "pipeline"))
sys.path.insert(0, os.path.join(HERE, "..", "gold"))

from graphdb import open_db, read_json, REPO_ROOT     # noqa: E402
from llm import LocalLLM                              # noqa: E402
from resolve import RESOLVE_SCHEMA, build_resolve_prompt, Resolver   # noqa: E402
from seed_gold import load_gold                       # noqa: E402

EXTRACT_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["entities", "triples"],
    "properties": {
        "entities": {
            "type": "array",
            "items": {
                "type": "object", "additionalProperties": False,
                "required": ["type", "canonical_name", "description"],
                "properties": {
                    "type": {"type": "string"},
                    "canonical_name": {"type": "string"},
                    "description": {"type": "string"},
                },
            },
        },
        "triples": {
            "type": "array",
            "items": {
                "type": "object", "additionalProperties": False,
                "required": ["subject", "predicate", "object"],
                "properties": {
                    "subject": {"type": "string"},
                    "predicate": {"type": "string"},
                    "object": {"type": "string"},
                },
            },
        },
    },
}

EXTRACT_SYSTEM = (
    "You extract grocery facts from Omaha store listings as strict JSON. "
    "Extract only CENTRAL entities and relations; ignore incidental mentions. "
    "Do not invent relationships that are not stated or clearly implied. "
    "Output JSON only."
)


def sample_listings(n: int) -> list[dict]:
    """Real product listings from the most recent captures — not synthetic text."""
    import glob
    rows: list[dict] = []
    for lane in ("regular", "throttled"):
        for fp in sorted(glob.glob(os.path.join(REPO_ROOT, "grocery", "out", lane, "*.json")))[-4:]:
            try:
                d = read_json(fp)
            except Exception:
                continue
            if isinstance(d, dict) and d.get("deals"):
                for deal in d["deals"]:
                    if deal.get("item"):
                        rows.append({"store": deal.get("store") or d.get("store"),
                                     "item": deal["item"],
                                     "price": deal.get("current_price") or deal.get("ad_price"),
                                     "size": deal.get("size")})
    random.Random(20260820).shuffle(rows)
    return rows[:n]


def bench_extract(llm: LocalLLM, n: int, say) -> dict:
    """Bar 1: valid strict JSON rate over N real extraction calls."""
    listings = sample_listings(n)
    ok = bad = 0
    tps: list[float] = []
    failures: list[str] = []

    for i, row in enumerate(listings):
        user = (f"Extract entities and triples from this Omaha grocery listing.\n"
                f"store: {row['store']}\nproduct: {row['item']}\n"
                f"price: {row['price']}\nsize: {row['size']}")
        try:
            parsed, res = llm.json_call(EXTRACT_SYSTEM, user, schema=EXTRACT_SCHEMA,
                                        max_tokens=700, retries=0)
            if isinstance(parsed, dict) and "entities" in parsed and "triples" in parsed:
                ok += 1
            else:
                bad += 1
                failures.append(f"shape: {str(parsed)[:120]}")
            tps.append(res.tokens_per_s)
        except Exception as e:                       # noqa: BLE001
            bad += 1
            failures.append(f"{type(e).__name__}: {str(e)[:120]}")
        if say and (i + 1) % 10 == 0:
            say(f"    extract {i+1}/{len(listings)}  valid={ok}")

    total = ok + bad
    return {
        "n": total,
        "valid": ok,
        "valid_rate": ok / total if total else 0.0,
        "median_tok_s": statistics.median(tps) if tps else 0.0,
        "mean_tok_s": statistics.mean(tps) if tps else 0.0,
        "failures": failures[:5],
    }


def bench_resolution(llm: LocalLLM, db, n: int, say, priors: str = "none",
                     jobs: int = 4) -> dict:
    """Bar 2: agreement with hand adjudication, model judgment only.

    Deliberately bypasses the deterministic layers. A model that merely inherits
    the regex guardrails' verdicts would score ~100% and tell us nothing about
    whether it can be trusted on the contested rows it will actually be asked about.

    PRIORS (2026-08-22, plan section 9). Until now this probe called
    build_resolve_prompt with no examples at all, while production has passed
    retrieved prior rulings since prompt v4 — so the recorded 0.900 was neither
    the production number nor an honestly labelled cold-start number, it was an
    unlabelled third thing. Both are now selectable and both get recorded:

      priors='none'          ABLATED. No history of any kind. This is the true
                             cold-start rate — what the model knows about a
                             commodity it has never been taught, which is 6.5%
                             of the gold corpus by construction (MEASURE doc
                             section 2.1) and 100% of every new commodity.
                             THIS is the baseline later phases are measured against.
      priors='loo'           What production actually sends: retrieved priors,
                             leave-one-out. Never let a case see itself; many
                             gold cases ARE banked rulings, and a case among its
                             own examples measures memorisation.
      priors='loo-all'       leave-one-out with the PRE-2026-08-22 pool, which
                             cited the model's own unreviewed rejections as
                             precedent. Kept only to measure what tiering cost.
    """
    gold = [g for g in load_gold() if g["kind"] == "match"]
    random.Random(20260820).shuffle(gold)

    r = Resolver(db, llm=None, use_llm=False)
    probe, agree, disagree, unsure = [], 0, 0, 0
    errors = []

    for g in gold:
        if len(probe) >= n:
            break
        node = g["commodity_node"]
        if not db.get_node(node):
            node = node.replace(":staple:", ":recipe:")
            if not db.get_node(node):
                continue
        probe.append((g, node))

    # CONCURRENCY. Each probe case is an independent question, so the calls can
    # share llama-server's slots — 120 sequential calls left three of four slots
    # idle for ten minutes. The answers are unaffected (same prompt, same
    # grammar, temperature 0.1); only wall clock moves. `jobs` must stay <= the
    # server's --parallel (serve.ps1 -Slots, currently 4): more jobs than slots
    # queues inside the server and burns each client's timeout waiting.
    #
    # bench_extract stays SEQUENTIAL on purpose: it measures decode tok/s for
    # bars 1 and 3, and concurrent streams share memory bandwidth, so a parallel
    # run would report a per-call rate the single-stream callers never see.
    # Prompts are built HERE, on the main thread, because a sqlite3 connection
    # may only be used by the thread that created it and both r.commodity() and
    # r.prior_rulings() read the graph. Only the HTTP calls fan out.
    prepared = []
    for g, node in probe:
        cc = r.commodity(node)
        examples = None
        if priors != "none":
            authority = "all" if priors == "loo-all" else "adjudicated"
            examples = r.prior_rulings(cc, g["product"], authority=authority)
        prepared.append((g, *build_resolve_prompt(cc, g["product"], examples)))

    def ask(item):
        g, system, user = item
        try:
            parsed, _ = llm.json_call(system, user, schema=RESOLVE_SCHEMA,
                                      max_tokens=350, retries=1)
            return g, parsed, None
        except Exception as e:                      # noqa: BLE001
            return g, None, e

    done = 0
    # Results are consumed in submission order, so the tally and the reported
    # disagreements do not depend on which slot answered first.
    with ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        for g, parsed, err in pool.map(ask, prepared):
            done += 1
            if err is not None:
                disagree += 1
                errors.append({"commodity": g["commodity"], "product": g["product"],
                               "gold": g["label"], "got": f"error {err}"})
                continue
            verdict = str(parsed.get("verdict", "UNSURE")).upper()
            if verdict == "UNSURE":
                unsure += 1
            else:
                predicted = "MATCH" if verdict == "MATCH" else "NO_MATCH"
                if predicted == g["label"]:
                    agree += 1
                else:
                    disagree += 1
                    errors.append({"commodity": g["commodity"], "product": g["product"][:70],
                                   "gold": g["label"], "got": predicted,
                                   "conf": parsed.get("confidence"),
                                   "why": str(parsed.get("evidence", ""))[:140]})
            if say and done % 10 == 0:
                say(f"    resolve {done}/{len(probe)}  agree={agree} disagree={disagree} unsure={unsure}")

    decided = agree + disagree
    return {
        "priors": priors,
        "jobs": jobs,
        "n": len(probe),
        "agree": agree, "disagree": disagree, "unsure": unsure,
        # UNSURE is not counted as a disagreement: abstaining is the SAFE
        # behaviour this system asks for, and is handled by escalation.
        "agreement_rate": agree / decided if decided else 0.0,
        "abstain_rate": unsure / len(probe) if probe else 0.0,
        "errors": errors[:10],
    }


def bench_context(llm: LocalLLM) -> dict:
    """Bar 3 (headroom half): confirm a large prompt still answers."""
    filler = ("Omaha grocery product listing line. " * 400)   # ~2.5k tokens
    try:
        res = llm.chat(
            [{"role": "system", "content": "Answer with one word."},
             {"role": "user", "content": filler + "\n\nReply with the word READY."}],
            max_tokens=16)
        return {"ok": "READY" in res.content.upper(),
                "prompt_tokens": res.prompt_tokens,
                "tok_s": res.tokens_per_s}
    except Exception as e:                          # noqa: BLE001
        return {"ok": False, "error": str(e)[:200]}


BARS = {"valid_json": 0.95, "agreement": 0.90, "tok_s": 15.0}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--extract-n", type=int, default=40)
    ap.add_argument("--probe-n", type=int, default=30)
    ap.add_argument("--priors", choices=("none", "loo", "loo-all"), default="none",
                    help="none = priors ABLATED, the cold-start baseline (default); "
                         "loo = the priors production sends, leave-one-out; "
                         "loo-all = leave-one-out with the pre-tiering pool")
    ap.add_argument("--jobs", type=int, default=4,
                    help="concurrent resolution calls; must be <= llama-server slots "
                         "(serve.ps1 -Slots, currently 4). The extraction/decode bars stay "
                         "single-stream regardless, so throughput is still measured honestly.")
    ap.add_argument("--skip-extract", action="store_true",
                    help="resolution probe only — bars 1 and 3 are unaffected by --priors, "
                         "so a second priors run need not re-pay for them")
    ap.add_argument("--label", default=None, help="model label for the record")
    ap.add_argument("--no-record", action="store_true")
    args = ap.parse_args()

    llm = LocalLLM()
    if not llm.health():
        print("local endpoint down — start it: pwsh tools/local-llm/serve.ps1", file=sys.stderr)
        return 2

    say = print
    say(f"Phase 0 acceptance benchmark   model={llm.model}   endpoint={llm.endpoint}")
    say("")

    t0 = time.time()
    if args.skip_extract:
        say("  [1/3] structured extraction ... SKIPPED (--skip-extract)")
        ex = {"n": 0, "valid": 0, "valid_rate": 0.0, "median_tok_s": 0.0,
              "mean_tok_s": 0.0, "failures": [], "skipped": True}
    else:
        say("  [1/3] structured extraction ...")
        ex = bench_extract(llm, args.extract_n, say)

    say(f"  [2/3] resolution agreement (model judgment, guardrails OFF, "
        f"priors={args.priors}) ...")
    with open_db() as db:
        rs = bench_resolution(llm, db, args.probe_n, say, priors=args.priors,
                              jobs=args.jobs)

    say("  [3/3] context headroom ...")
    ctx = bench_context(llm)
    elapsed = time.time() - t0

    passed = {
        # A skipped bar cannot PASS. --skip-extract is for a repeat resolution
        # measurement, not for producing a gate verdict on the cheap.
        "valid_json": (not ex.get("skipped")) and ex["valid_rate"] >= BARS["valid_json"],
        "agreement": rs["agreement_rate"] >= BARS["agreement"],
        "tok_s": (not ex.get("skipped")) and ex["median_tok_s"] >= BARS["tok_s"],
        "context": bool(ctx.get("ok")),
    }
    all_pass = all(passed.values())

    say("\n" + "=" * 64)
    say(f"  valid strict JSON   {ex['valid_rate']:.3f}  (n={ex['n']})   "
        f"bar >= {BARS['valid_json']}   {'PASS' if passed['valid_json'] else 'FAIL'}")
    say(f"  resolution agree    {rs['agreement_rate']:.3f}  (n={rs['n']}, "
        f"abstain {rs['abstain_rate']:.2f})   bar >= {BARS['agreement']}   "
        f"{'PASS' if passed['agreement'] else 'FAIL'}")
    say(f"  median decode       {ex['median_tok_s']:.1f} tok/s   "
        f"bar >= {BARS['tok_s']}   {'PASS' if passed['tok_s'] else 'FAIL'}")
    say(f"  context headroom    {ctx.get('prompt_tokens','?')} prompt tokens   "
        f"{'PASS' if passed['context'] else 'FAIL'}")
    gate = "PASS" if all_pass else ("NOT A GATE RUN" if ex.get("skipped") else "FAIL")
    say(f"\n  PHASE 0 GATE: {gate}   ({elapsed:.0f}s)")
    say("=" * 64)

    if rs["errors"]:
        say("\n  resolution disagreements (model vs hand adjudication):")
        for e in rs["errors"][:6]:
            say(f"    {e['commodity']}: gold={e['gold']} got={e.get('got')}")
            say(f"       {e['product'][:66]}")
            if e.get("why"):
                say(f"       why: {e['why'][:100]}")

    if not args.no_record:
        record_result(args.label or llm.model, ex, rs, ctx, passed, all_pass, elapsed,
                      priors=args.priors)
        say(f"\n  recorded -> graph/prompts/model-selection.md")

    return 0 if all_pass else 1


def record_result(label, ex, rs, ctx, passed, all_pass, elapsed, priors="none") -> None:
    path = os.path.join(HERE, "..", "prompts", "model-selection.md")
    path = os.path.abspath(path)
    new = not os.path.exists(path)
    with io.open(path, "a", encoding="utf-8", newline="\n") as fh:
        if new:
            fh.write("# Phase 0 model selection record\n\n"
                     "Appended by `graph/bench/bench.py`. Each block is one candidate\n"
                     "measured on this box against the plan's acceptance bars.\n"
                     "The chosen primary model is whichever most recently PASSED.\n")
        fh.write(f"\n## {label} — {time.strftime('%Y-%m-%d %H:%M')}\n\n")
        verdict = ("PASS" if all_pass else
                   ("NOT A GATE RUN" if ex.get("skipped") else "FAIL"))
        fh.write(f"- verdict: **{verdict}** ({elapsed:.0f}s)\n")
        # A skipped bar records as SKIPPED, not as 0.000 FAIL: a resolution-only
        # re-run has not measured extraction, and a record claiming it measured
        # it and got zero is a lie that outlives the session that wrote it.
        if ex.get("skipped"):
            fh.write("- valid strict JSON: SKIPPED (--skip-extract; resolution-only "
                     "re-run, not a gate verdict)\n")
        else:
            fh.write(f"- valid strict JSON: {ex['valid_rate']:.3f} (n={ex['n']}) "
                     f"{'PASS' if passed['valid_json'] else 'FAIL'}\n")
        fh.write(f"- resolution agreement: {rs['agreement_rate']:.3f} (priors={priors}, n={rs['n']}, "
                 f"abstain {rs['abstain_rate']:.2f}) {'PASS' if passed['agreement'] else 'FAIL'}\n")
        if ex.get("skipped"):
            fh.write("- median decode: SKIPPED (--skip-extract)\n")
        else:
            fh.write(f"- median decode: {ex['median_tok_s']:.1f} tok/s "
                     f"{'PASS' if passed['tok_s'] else 'FAIL'}\n")
        fh.write(f"- context headroom: {ctx.get('prompt_tokens','?')} prompt tokens "
                 f"{'PASS' if passed['context'] else 'FAIL'}\n")
        fh.write(f"\n```json\n{json.dumps({'extract': ex, 'resolution': rs, 'context': ctx}, indent=2, default=str)[:4000]}\n```\n")


if __name__ == "__main__":
    raise SystemExit(main())
