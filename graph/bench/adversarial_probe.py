"""
adversarial_probe.py - does the §3.3 second pass SEPARATE, or does it just reject?

THE PRE-REGISTERED TEST, from PLAN-local-matching §3.3, written before any result existed:

    "Every local MATCH is re-asked with the instruction to argue NO_MATCH. Test before
     wiring: run on the 375 llm_confirmed and the known false matches; if survival does
     not separate them, drop it."

This file is that test and nothing else. It writes no verdict, banks nothing, and touches the
database read-only.

WHY §3.3 MATTERS MORE THAN IT LOOKED. It was third in a list of three local upgrades. Phase 3
then measured that the model's REJECTIONS are ~100% correct (117 sampled, 0 wrong) while its
MATCH side carries a 37% false rate and produced 326 unconfirmed leads now waiting for Claude.
The reject side is solved; the match side is the whole remaining cost. §3.3 is the only item in
the plan that attacks it directly.

THE TWO POPULATIONS, and why they are the right ones:

  SHOULD SURVIVE   pairs the Claude review lane ruled llm_confirmed. A reasoner looked and said
                   yes. If the challenge kills these, it is killing real cells.
  SHOULD DIE       pairs adjudicated wrong-product (known-wrong). These ARE false matches - each
                   one was crowned on the board and had to be blocklisted. They are the exact
                   error class §3.3 exists to catch.

THE NUMBER THAT DECIDES: survival(confirmed) - survival(known-wrong). A challenge that kills
everything, or spares everything, separates nothing whatever its individual rates look like.
Recorded here so that a later reader can see the bar was set before the run.
"""
from __future__ import annotations
import argparse, json, os, sys, time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "graph", "lib"))
sys.path.insert(0, os.path.join(REPO, "graph", "pipeline"))

from graphdb import open_db                                                    # noqa: E402
from llm import LocalLLM                                                       # noqa: E402
from resolve import (RESOLVE_SCHEMA, Resolver, build_adversarial_prompt,       # noqa: E402
                     ADVERSARIAL_PROMPT_VERSION)

OUT = os.path.join(REPO, "graph", "bench", "out")


def log(m: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def populations(db, limit: int | None) -> tuple[list, list]:
    """(should survive, should die). Both read-only, both adjudicated - no model's own work."""
    survive = [(r["commodity_id"], r["product_name"]) for r in db.conn.execute(
        """SELECT commodity_id, product_name FROM question_verdicts
           WHERE status = 'llm_confirmed' AND product_name IS NOT NULL""")]
    die = [(r["cid"], r["product"]) for r in db.conn.execute(
        """SELECT n.id AS cid, k.canonical_name AS product
           FROM nodes k JOIN edges e ON e.source_id = k.id AND e.predicate = 'known_wrong_for'
           JOIN nodes n ON n.id = e.target_id
           WHERE k.type = 'KnownWrong' AND k.canonical_name IS NOT NULL""")]
    if limit:
        survive, die = survive[:limit], die[:limit]
    return survive, die


def main() -> int:
    ap = argparse.ArgumentParser(description="Pre-registered test of the §3.3 adversarial pass")
    ap.add_argument("--jobs", type=int, default=4, help="coupled to serve.ps1 -Slots")
    ap.add_argument("--limit", type=int, default=None, help="cap each population, for a smoke run")
    ap.add_argument("--tag", default="adv-v1")
    a = ap.parse_args()

    llm = LocalLLM()
    if not llm.health():
        print("local endpoint down - start it: powershell tools/local-llm/serve.ps1 -Slots 4",
              file=sys.stderr)
        return 2

    with open_db() as db:
        survive, die = populations(db, a.limit)
        r = Resolver(db, llm=llm, use_llm=True)
        log(f"should SURVIVE (Claude confirmed): {len(survive)}   "
            f"should DIE (adjudicated wrong-product): {len(die)}")

        # Warm every commodity on THIS thread. resolve_pending does the same, for the same
        # reason: the workers do HTTP and nothing else, because a sqlite connection belongs to
        # the thread that opened it and the estate's single-writer rule is not negotiable.
        warm: dict = {}
        for cid, _ in survive + die:
            if cid not in warm:
                try:
                    warm[cid] = r.commodity(cid)
                except KeyError:
                    warm[cid] = None
        missing = sum(1 for v in warm.values() if v is None)
        if missing:
            log(f"{missing} commodity id(s) have no node and are skipped, not guessed at")

        # Priors on the main thread too, and EXCLUDING the pair under test - many of these
        # cases ARE banked rulings, and a case that appears among its own examples measures
        # memorisation. prior_rulings takes exclude_keys for exactly this reason.
        priors: dict = {}
        for cid, name in survive + die:
            cc = warm.get(cid)
            if cc is not None:
                priors[(cid, name)] = r.prior_rulings(cc, name)

        def challenge(item):
            cid, name = item
            cc = warm.get(cid)
            if cc is None:
                return None
            system, user = build_adversarial_prompt(cc, name, examples=priors.get((cid, name)))
            try:
                parsed, _ = llm.json_call(system, user, schema=RESOLVE_SCHEMA, max_tokens=400)
            except Exception as e:                                             # noqa: BLE001
                return {"cid": cid, "product": name, "verdict": "ERROR", "why": str(e)[:120]}
            return {"cid": cid, "product": name,
                    "verdict": str(parsed.get("verdict", "UNSURE")).upper(),
                    "conf": float(parsed.get("confidence", 0) or 0),
                    "why": str(parsed.get("evidence", ""))[:200]}

        out = {}
        for label, pop in (("confirmed", survive), ("known_wrong", die)):
            t0 = time.time()
            with ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
                res = [x for x in ex.map(challenge, pop) if x]
            n = len([x for x in res if x["verdict"] != "ERROR"])
            surv = sum(1 for x in res if x["verdict"] == "MATCH")
            killed = sum(1 for x in res if x["verdict"] == "NO_MATCH")
            unsure = sum(1 for x in res if x["verdict"] == "UNSURE")
            err = sum(1 for x in res if x["verdict"] == "ERROR")
            out[label] = {"n": n, "survived": surv, "killed": killed, "unsure": unsure,
                          "errors": err, "survival_rate": (surv / n if n else None),
                          "sec": round(time.time() - t0), "rows": res}
            log(f"{label:12s} n={n:4d}  SURVIVED {surv:4d} ({100*surv/max(1,n):5.1f}%)  "
                f"killed {killed:4d}  unsure {unsure:3d}  errors {err}  in {out[label]['sec']}s")

    c, k = out["confirmed"], out["known_wrong"]
    sep = ((c["survival_rate"] or 0) - (k["survival_rate"] or 0))
    # THE BAR, set in the plan before the run: the challenge must spare real matches far more
    # often than false ones. A pass that kills or spares everything separates nothing.
    verdict = ("SHIP - it separates" if sep >= 0.30 else
               "DROP - it does not separate; the plan says drop it rather than ship it")
    report = {"generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
              "prompt_version": ADVERSARIAL_PROMPT_VERSION,
              "confirmed_survival": c["survival_rate"], "known_wrong_survival": k["survival_rate"],
              "separation": sep, "bar": 0.30, "verdict": verdict,
              "counts": {kk: {x: vv[x] for x in ("n", "survived", "killed", "unsure", "errors")}
                         for kk, vv in out.items()},
              "rows": {kk: vv["rows"] for kk, vv in out.items()}}
    os.makedirs(OUT, exist_ok=True)
    p = os.path.join(OUT, f"adversarial-{a.tag}.json")
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        json.dump(report, f, indent=1, ensure_ascii=False)
    print(f"\n  confirmed matches surviving the challenge : {100*(c['survival_rate'] or 0):.1f}%")
    print(f"  known-WRONG matches surviving the challenge: {100*(k['survival_rate'] or 0):.1f}%")
    print(f"  separation {100*sep:.1f} points against a bar of 30.0  ->  {verdict}")
    log(f"wrote {p}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
