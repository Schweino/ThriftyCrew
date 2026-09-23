"""Priors ablation — what the model's memory is worth, and whose memory it is.

    python graph/bench/priors_ablation.py --modes none,loo-all,loo --n 60
    python graph/bench/priors_ablation.py --selftest          # no GPU, no server

THE QUESTION. Layer 5 shows the local model this board's own prior rulings
(prompt v4). Three things were never separated:

  none      no priors at all — the COLD-START condition, and the honest baseline
            (plan section 9). Every brand-new commodity is judged this way.
  loo-all   the priors v4 actually sent: every banked ruling, including the
            3,315 unreviewed rejections the model itself produced. This is the
            self-citation loop plan section 3.1 exists to break.
  loo       the priors v5 sends: ADJUDICATED rulings only (human, the Claude
            review lane, known-wrong), plus any model-CONSENSUS rulings shown
            separately and labelled tentative. See graph/lib/authority.py.

LEAVE-ONE-OUT IS NOT OPTIONAL. Many gold cases ARE banked rulings, so a case that
appears among its own examples measures memorisation, not learning. Every mode
here excludes the case under test by normalised product key, and the exclusion
lives in Resolver.prior_rulings itself rather than in this harness, so the
production path cannot cite a listing to itself either.

METRICS are the four prompt v4 was measured on (resolve.py's module docstring),
so this run and that one can be read against each other:

    false MATCH    gold NO_MATCH, model said MATCH        the dangerous error
    correct        model agreed with the adjudication
    escalated      model said UNSURE, or fell below the escalation threshold
    false reject   gold MATCH, model said NO_MATCH        one empty cell

Read-only against the graph. Writes nothing but its report.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import random
import shutil
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
sys.path.insert(0, os.path.join(HERE, "..", "pipeline"))
sys.path.insert(0, os.path.join(HERE, "..", "gold"))

from authority import authority_tier                              # noqa: E402
from graphdb import GraphDB, open_db                              # noqa: E402
from ids import norm_text                                         # noqa: E402
from llm import LocalLLM, should_escalate                         # noqa: E402
from resolve import RESOLVE_SCHEMA, build_resolve_prompt, Resolver  # noqa: E402
from seed_gold import load_gold                                   # noqa: E402

# The mode name here -> the `authority` argument Resolver.prior_rulings takes.
MODES = {"none": "none", "loo-all": "all", "loo": "adjudicated"}

# Matches the layer-5 default (Resolver.escalate_below) so an answer counted as
# "escalated" here is one production would also have escalated.
ESCALATE_BELOW = 0.75

# The self-test's leave-one-out half needs a commodity carrying at least this many banked
# rulings, so one can be held out and others still shown. The first plausible number, not the
# survivor of a sweep: it has stood since the half was written.
LOO_MIN_HISTORY = 3
# The checks that half runs when it can look. A checkout where it cannot reports every one of
# them BLIND, and the clean twin asserts the seeing arm ran exactly these, so the blind count is
# checked by the arm that can see rather than claimed by the one that cannot.
LOO_CHECKS = ("MUST FIRE  a case never appears among its own examples",
              "MUST FIRE  only adjudicated rulings are cited as precedent")


def _index_blind(db) -> tuple[str, str] | None:
    """Why this index cannot compile a commodity, as (code, why), or None when it can.

    A LEARNING-ONLY INDEX IS A SANCTIONED SHAPE, NOT A BROKEN ONE (2026-09-23). graph/lib/rebuild.py's
    plain mode restores the five learning tables and nothing else, by design, and says to run
    import_all.py for the nodes. question_verdicts then names thousands of commodities the nodes
    table does not hold, so Resolver._verdict_index is full while Resolver.commodity() raises
    KeyError for every one of them. On branch claude/d13-graph-rulings that red a push (run-gates
    pass=471 fail=1) for a reason unrelated to the change. Anything else wrong with the file, not a
    database or no schema, is NOT this shape: the query raises, and the caller scores a failure.
    """
    if db.conn.execute("SELECT COUNT(*) FROM nodes WHERE type='Commodity'").fetchone()[0]:
        return None
    total = db.conn.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]
    return ("no-commodity-nodes",
            f"the index holds no Commodity nodes ({total} node(s) of any type) - a learning-only "
            f"rebuild (graph/lib/rebuild.py plain mode); graph/import/import_all.py builds them")


def probe_cases(db, r: Resolver, n: int, require_history: bool, seed: int) -> list[dict]:
    """Gold cases to judge, leave-one-out applied when history is required.

    `require_history` reproduces the v4 measurement's population: cases whose
    commodity carries at least one prior ruling OTHER THAN THE CASE ITSELF under
    the widest pool. Without that filter a "with priors" run is mostly cases with
    no priors to show, and the comparison measures nothing.
    """
    gold = [g for g in load_gold() if g.get("kind") == "match"]
    random.Random(seed).shuffle(gold)
    out: list[dict] = []
    for g in gold:
        if len(out) >= n:
            break
        node = g["commodity_node"]
        if not db.get_node(node):
            node = node.replace(":staple:", ":recipe:")
            if not db.get_node(node):
                continue
        if require_history:
            pool = r._verdict_index.get(node) or []
            key = norm_text(g["product"])
            if not any(norm_text(p[0]) != key for p in pool):
                continue
        out.append({**g, "node": node})
    return out


def prepare(r: Resolver, case: dict, mode: str) -> tuple[dict, str, str, int]:
    """Build one prompt. MAIN THREAD ONLY — a sqlite3 connection belongs to the
    thread that opened it, and both calls below read the graph."""
    cc = r.commodity(case["node"])
    examples = r.prior_rulings(cc, case["product"], authority=MODES[mode]) or None
    system, user = build_resolve_prompt(cc, case["product"], examples)
    return case, system, user, sum(len(v) for v in (examples or {}).values())


def judge(llm: LocalLLM, prepared: tuple[dict, str, str, int]) -> dict:
    """One adjudication, scored the way production would route it."""
    case, system, user, n_priors = prepared
    try:
        parsed, res = llm.json_call(system, user, schema=RESOLVE_SCHEMA,
                                    max_tokens=400, retries=1)
    except Exception as e:                                       # noqa: BLE001
        return {"outcome": "error", "detail": f"{type(e).__name__}: {e}"[:160],
                "gold": case["label"], "commodity": case["commodity"],
                "product": case["product"][:80], "priors": n_priors}

    verdict = str(parsed.get("verdict", "UNSURE")).upper()
    conf = float(parsed.get("confidence", 0.0) or 0.0)
    if verdict == "UNSURE" or should_escalate(conf, ESCALATE_BELOW):
        outcome = "escalated"
    elif verdict == "MATCH":
        outcome = "correct" if case["label"] == "MATCH" else "false_match"
    else:
        outcome = "correct" if case["label"] == "NO_MATCH" else "false_reject"
    return {"outcome": outcome, "gold": case["label"], "got": verdict,
            "conf": conf, "commodity": case["commodity"],
            "product": case["product"][:80], "priors": n_priors,
            "why": str(parsed.get("evidence", ""))[:160],
            "completion_tokens": res.completion_tokens}


def run_mode(llm: LocalLLM, r: Resolver, cases: list[dict], mode: str,
             jobs: int, say) -> dict:
    t0 = time.time()
    prepared = [prepare(r, c, mode) for c in cases]      # main thread: sqlite
    with ThreadPoolExecutor(max_workers=jobs) as pool:   # workers: HTTP only
        rows = list(pool.map(lambda p: judge(llm, p), prepared))
    n_match = sum(1 for c in cases if c["label"] == "MATCH")
    n_no = sum(1 for c in cases if c["label"] == "NO_MATCH")
    tally = {k: sum(1 for x in rows if x["outcome"] == k)
             for k in ("correct", "false_match", "false_reject", "escalated", "error")}
    say(f"    {mode:8s} correct={tally['correct']:3d}  "
        f"false MATCH={tally['false_match']:2d}/{n_no}  "
        f"false reject={tally['false_reject']:2d}/{n_match}  "
        f"escalated={tally['escalated']:2d}  ({time.time()-t0:.0f}s)")
    return {"mode": mode, "n": len(cases), "gold_match": n_match,
            "gold_no_match": n_no, **tally,
            "false_match_rate": tally["false_match"] / n_no if n_no else None,
            "false_reject_rate": tally["false_reject"] / n_match if n_match else None,
            "mean_priors_shown": (sum(x["priors"] for x in rows) / len(rows)) if rows else 0,
            "seconds": round(time.time() - t0, 1),
            "rows": rows}


def _leave_one_out(db_path: str, T) -> tuple[str, str] | None:
    """The leave-one-out checks over the index at `db_path`, each reported through T.

    Returns None when they ran, or (code, why) when this index cannot answer them: no file
    (graph.db is gitignored, so a fresh worktree has none), a learning-only index
    (`_index_blind`), or no compiled commodity with LOO_MIN_HISTORY rulings. Each of those is a
    could-not-look, reported BLIND by the caller, never a failure and never a pass. A genuine
    error, a file that is not a database or a query that raises, is still a failing case.

    Opened with no learning restore: open_db() writes the tracked learning records into an index
    whose learning tables are empty, and a self-test must not write the index it reads.
    """
    if not os.path.exists(db_path):
        return ("no-db", "no graph.db here - it is gitignored (graph/.gitignore), so a fresh worktree has none")
    try:
        with GraphDB(db_path, create=False, restore_learning=False) as db:
            blind = _index_blind(db)
            if blind:
                return blind
            r = Resolver(db, llm=None, use_llm=False)
            # A partly built index can bank rulings on a commodity it holds no node for, so the
            # case is chosen among commodities that compile: the check is about the leave-one-out
            # rule, not about whether the import finished.
            hit = next(((node, pool) for node, pool in r._verdict_index.items()
                        if len(pool) >= LOO_MIN_HISTORY and db.get_node(node)), None)
            if hit is None:
                return ("no-history", f"no commodity with a node carries {LOO_MIN_HISTORY} or more "
                                      f"banked rulings ({len(r._verdict_index)} carry any)")
            node, pool = hit
            cc = r.commodity(node)
            own = pool[0][0]
            ex = r.prior_rulings(cc, own, authority="all")
            shown = {norm_text(x) for v in ex.values() for x in v}
            T(LOO_CHECKS[0], norm_text(own) not in shown, own[:60])
            adj = r.prior_rulings(cc, own, authority="adjudicated")
            cited = [x for x in (adj.get("rejected", []) + adj.get("confirmed", []))]
            tiers = {norm_text(p[0]): p[3] for p in pool}
            T(LOO_CHECKS[1],
              all(tiers.get(norm_text(c)) == "adjudicated" for c in cited),
              str([(c, tiers.get(norm_text(c))) for c in cited])[:160])
    except Exception as e:                                        # noqa: BLE001
        T(f"graph available for the leave-one-out check ({type(e).__name__})", False, str(e)[:120])
    return None


def _fixture_index(root: str, name: str, commodities=(), verdicts=()) -> str:
    """A temp index: the real schema, these Commodity nodes and question_verdicts rows, nothing else."""
    path = os.path.join(root, name + ".db")
    at = "2026-09-23T00:00:00"
    with GraphDB(path, allow_new=True, restore_learning=False) as db:
        for cid in commodities:
            db.upsert_node(cid, "Commodity", cid.rsplit(":", 1)[-1], at)
        for cid, product, status, reason in verdicts:
            db.conn.execute(
                "INSERT INTO question_verdicts (commodity_id, product_key, product_name, status, "
                "reason, decided_at) VALUES (?,?,?,?,?,?)",
                (cid, norm_text(product), product, status, reason, at))
    return path


def _fixtures(T) -> None:
    """The leave-one-out half against temp indexes of each shape. Never the live graph.db."""
    adobo = "commodity:staple:adobo-seasoning"
    beans = "commodity:staple:black-beans"

    def rulings(cid, n):
        # One adjudicated rejection, one model-only rejection and one adjudicated confirmation,
        # so both checks have something to get wrong: the held-out case is among the rulings
        # `all` would show, and a model-only row is among those `adjudicated` must not cite.
        rows = [(cid, "Goya Adobo All Purpose Seasoning 8 oz", "llm_rejected", "reviewer: wrong pack"),
                (cid, "Adobo Chipotle Peppers 7 oz", "llm_rejected", "banked: llm: not a seasoning"),
                (cid, "Badia Adobo Seasoning 7 oz", "llm_confirmed", "adjudicated: match")]
        return rows[:n]

    def run(path):
        seen: list[tuple[str, bool]] = []
        blind = _leave_one_out(path, lambda name, ok, got="": seen.append((name, bool(ok))))
        return blind, seen

    root = tempfile.mkdtemp(prefix="pa-st-")
    try:
        # MUST FIRE, the founding shape. The precondition proves this fixture IS the input that
        # went red: the verdict index is full and compiling the commodity raises KeyError.
        lo = _fixture_index(root, "learning-only", verdicts=rulings(adobo, 3))
        with GraphDB(lo, create=False, restore_learning=False) as db:
            r = Resolver(db, llm=None, use_llm=False)
            try:
                r.commodity(adobo)
                founding = "commodity() compiled"
            except KeyError:
                pool_n = len(r._verdict_index.get(adobo) or [])
                founding = "KeyError" if pool_n >= LOO_MIN_HISTORY else f"KeyError, but the pool holds {pool_n}"
        blind, seen = run(lo)
        T("MUST FIRE  a learning-only index (rebuild.py plain mode: 3 rulings on adobo-seasoning, "
          "0 nodes) reads BLIND no-commodity-nodes, never the KeyError failure",
          founding == "KeyError" and blind is not None and blind[0] == "no-commodity-nodes" and not seen,
          f"precondition={founding} blind={blind} seen={seen}")

        blind, seen = run(os.path.join(root, "absent.db"))
        T("MUST FIRE  an absent graph.db reads BLIND no-db and creates no file",
          blind is not None and blind[0] == "no-db" and not seen
          and not os.path.exists(os.path.join(root, "absent.db")), f"blind={blind} seen={seen}")

        partial = _fixture_index(root, "partial", commodities=[beans], verdicts=rulings(adobo, 3))
        blind, seen = run(partial)
        T("MUST FIRE  a partly built index whose only history sits on a commodity with no node "
          "reads BLIND no-history, never the KeyError failure",
          blind is not None and blind[0] == "no-history" and not seen, f"blind={blind} seen={seen}")

        below = _fixture_index(root, "below-bar", commodities=[adobo], verdicts=rulings(adobo, 2))
        blind, seen = run(below)
        T("MUST FIRE  a commodity with 2 rulings, one below the bar of 3, reads BLIND no-history",
          blind is not None and blind[0] == "no-history" and not seen, f"blind={blind} seen={seen}")

        at_bar = _fixture_index(root, "at-bar", commodities=[adobo], verdicts=rulings(adobo, 3))
        blind, seen = run(at_bar)
        T("CLEAN TWIN  a built index with 3 rulings, exactly the bar of 3, runs every leave-one-out "
          "check and each passes - the checks a blind checkout reports as not covered",
          blind is None and [n for n, _ in seen] == list(LOO_CHECKS) and all(ok for _, ok in seen),
          f"blind={blind} seen={seen}")

        junk = os.path.join(root, "not-a-database.db")
        with io.open(junk, "wb") as fh:
            fh.write(b"this file is not an SQLite database\n" * 64)
        blind, seen = run(junk)
        T("CLEAN TWIN  a graph.db that is not a database is still a failing case, never BLIND - "
          "only the sanctioned shapes above could not look",
          blind is None and len(seen) == 1 and not seen[0][1], f"blind={blind} seen={seen}")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def _selftest() -> int:
    """No GPU, no server: the routing and the leave-one-out rule."""
    ran: list[str] = []
    bad: list[str] = []

    def T(name, ok, got=""):
        ran.append(name)
        if ok:
            print(f"  ok    {name}")
        else:
            print(f"  X     {name}   got: {got}")
            bad.append(name)

    T("every mode maps to a prior_rulings authority",
      set(MODES.values()) == {"none", "all", "adjudicated"}, str(MODES))
    T("the escalation threshold matches layer 5's default", ESCALATE_BELOW == 0.75)
    T("a confident MATCH on a NO_MATCH case is a false match",
      not should_escalate(0.95, ESCALATE_BELOW))
    T("MUST FIRE  a low-confidence answer is escalated, never scored as correct",
      should_escalate(0.5, ESCALATE_BELOW))
    T("MUST FIRE  a model-only rejection is not citable as precedent",
      authority_tier("llm_rejected", "banked: llm: x") == "single_model")
    _fixtures(T)

    # Leave-one-out over the real index. A checkout that cannot answer it, no graph.db or a
    # learning-only one, reports those checks BLIND: counted, named, and neither passed nor
    # failed. It used to print an ok line for the absent case and fail the learning-only one.
    blind = _leave_one_out(os.path.join(HERE, "..", "sqlite", "graph.db"), T)
    n_blind = len(LOO_CHECKS) if blind else 0
    cases = len(ran) + n_blind
    marker = f"PRIORS-ABLATION-SELFTEST-COMPLETE cases={cases} failed={len(bad)} blind={n_blind}"
    if bad:
        print(f"priors_ablation SELF-TEST FAIL ({len(bad)} of {cases} case(s))")
        print(marker)
        return 2
    if blind:
        print(f"priors_ablation selftest: {len(ran)} of {cases} cases pass, {n_blind} BLIND - "
              f"could not look, NOT passed ({blind[0]}: {blind[1]}):")
        for name in LOO_CHECKS:
            print(f"  {name}")
    else:
        print(f"priors_ablation SELF-TEST PASS: {cases} of {cases} case(s)")
    print(marker)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--modes", default="none,loo-all,loo",
                    help="comma-separated: none, loo-all, loo")
    ap.add_argument("--n", type=int, default=60)
    ap.add_argument("--jobs", type=int, default=4,
                    help="concurrent calls; must be <= llama-server slots (serve.ps1 -Slots)")
    ap.add_argument("--seed", type=int, default=20260822)
    ap.add_argument("--all-cases", action="store_true",
                    help="do NOT require the commodity to carry history "
                         "(use for a pure cold-start population)")
    ap.add_argument("--out", default=None, help="write the full JSON report here")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return _selftest()

    modes = [m.strip() for m in args.modes.split(",") if m.strip()]
    unknown = [m for m in modes if m not in MODES]
    if unknown:
        print(f"unknown mode(s): {unknown}; choose from {list(MODES)}", file=sys.stderr)
        return 2

    llm = LocalLLM()
    if not llm.health():
        print("local endpoint down — start it: pwsh tools/local-llm/serve.ps1", file=sys.stderr)
        return 2

    with open_db(create=False) as db:
        # A learning-only index resolves no gold case, so the run below would measure zero cases
        # and print a table of zeros: an agreeing answer to a question nobody asked it.
        blind = _index_blind(db)
        if blind:
            print(f"PRIORS ABLATION BLIND: {blind[1]}. Nothing was measured, which is not "
                  f"a measurement of nothing.")
            print(f"PRIORS-ABLATION-COMPLETE blind={blind[0]}")
            return 3
        r = Resolver(db, llm=None, use_llm=False)
        cases = probe_cases(db, r, args.n, not args.all_cases, args.seed)
        print(f"priors ablation   model={llm.model}   cases={len(cases)}   "
              f"history_required={not args.all_cases}   seed={args.seed}")
        print(f"  banked rulings by authority tier: {r.prior_tier_counts}")
        print(f"  gold split: MATCH={sum(1 for c in cases if c['label']=='MATCH')} "
              f"NO_MATCH={sum(1 for c in cases if c['label']=='NO_MATCH')}")
        results = [run_mode(llm, r, cases, m, args.jobs, print) for m in modes]

    print("\n" + "=" * 72)
    print(f"  {'mode':9s} {'correct':>8s} {'falseMATCH':>12s} {'falseREJECT':>12s} "
          f"{'escalated':>10s} {'priors/case':>12s}")
    for res in results:
        print(f"  {res['mode']:9s} {res['correct']:8d} "
              f"{res['false_match']:>6d}/{res['gold_no_match']:<5d} "
              f"{res['false_reject']:>6d}/{res['gold_match']:<5d} "
              f"{res['escalated']:10d} {res['mean_priors_shown']:12.1f}")
    print("=" * 72)

    report = {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
              "model": llm.model, "seed": args.seed,
              "history_required": not args.all_cases,
              "n_cases": len(cases), "results": results}
    if args.out:
        with io.open(args.out, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(report, fh, indent=2, default=str)
        print(f"  report -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
