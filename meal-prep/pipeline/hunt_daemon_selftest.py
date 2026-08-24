"""
hunt_daemon_selftest.py - the daemon's fixtures (PLAN-recipe-hunter-v3, D9).

    C:\\Codex\\Python312\\python.exe hunt-daemon.py --selftest

WHY THIS IS A SEPARATE FILE. `hunt-daemon.py` carries a hyphen, matching every other orchestration
surface in this pipeline, so it cannot be imported by name. The daemon loads this module and this
module loads the daemon back through importlib. That is the whole reason for the split.

WHAT IS UNDER TEST. Not the pure decision logic - that lives in hunt_lib and is proven against shared
vectors on both implementations (section 4.2's parity gate). What is under test here is the DAEMON:
what it does with a null, who holds the pen, which channel it closes, what it writes to the lane log,
and whether its refusals hold. Every dispatch and every PowerShell call is INJECTED, so the whole
suite runs for zero tokens; the handful of fixtures that genuinely need the state machine run
hunt-run.ps1 against a scratch run dir, exactly as decide_apply's drill does - because the estate's
own lesson is that the defects which survive every pure-predicate fixture are the ones that appear
only once results are COLLECTED.

The D9 bullet names the twins: B5 (null is STUCK), B6 (per-slug budgets), B7 (first-token verdicts),
B8 (a mapper verdict with terms as a JSON array lands on the queue as DISTINCT terms), B10 (trim),
B11 (the repair-claim mtime check) and the cost-engine mutex, plus the five phase-1 obligations.
"""
from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
REPO = os.path.dirname(MP)
sys.path.insert(0, HERE)

import hunt_lib                                                  # noqa: E402
import price_evidence                                            # noqa: E402


def load_daemon():
    spec = importlib.util.spec_from_file_location("hunt_daemon", os.path.join(HERE, "hunt-daemon.py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules["hunt_daemon"] = mod
    spec.loader.exec_module(mod)
    return mod


HD = load_daemon()
HUNT_RUN_PS = os.path.join(HERE, "hunt-run.ps1")


# =====================================================================================================
# Injection
# =====================================================================================================

class FakeDispatch(object):
    """Scripted replies, keyed by agent name. Each entry is a list consumed in order; a `None` entry
    is a TRANSPORT FAILURE, which is the only thing that may ever produce a null."""

    def __init__(self, script=None):
        self.script = {k: list(v) for k, v in (script or {}).items()}
        self.calls = []

    def __call__(self, agent, prompt, schema=None, validator=None, **kw):
        self.calls.append({"agent": agent, "prompt": prompt, "schema": schema})
        q = self.script.get(agent)
        payload = q.pop(0) if q else {}
        res = HD.hunt_dispatch.DispatchResult(agent)
        res.tokens_in, res.tokens_out = 1234, 56
        if payload is None:
            res.failure, res.detail = "transport", "injected transport failure"
            return res
        res.payload = payload
        res.text = json.dumps(payload)
        return res

    def prompts(self, agent):
        return [c["prompt"] for c in self.calls if c["agent"] == agent]


class FakePS(object):
    """Records every PowerShell call as the ARGUMENT LIST, not as a string. That is deliberate: the
    B8 class is about whether a multi-element array survives as elements, and a fixture that
    inspected a joined command line could not tell the difference."""

    def __init__(self, replies=None):
        self.calls = []
        self.replies = replies or {}

    def __call__(self, script, args, timeout=180):
        name = os.path.basename(script)
        self.calls.append({"script": name, "args": list(args), "timeout": timeout})
        for key, val in self.replies.items():
            if key in name and (not isinstance(val, tuple) or True):
                if callable(val):
                    return val(args)
                return val
        return 0, "", ""

    def find(self, script_part, flag=None):
        out = []
        for c in self.calls:
            if script_part not in c["script"]:
                continue
            if flag is None or flag in c["args"]:
                out.append(c)
        return out

    @staticmethod
    def value_after(args, flag):
        try:
            return args[args.index(flag) + 1]
        except (ValueError, IndexError):
            return None


class FakePy(object):
    """The PYTHON subprocess seam - pull-browser-stores.py is Python, so it never goes through
    ps_invoke. A reply may be a CALLABLE that receives the argument list, which is how a fixture
    makes the driver "write" its lookup output without a browser existing anywhere."""

    def __init__(self, replies=None):
        self.calls = []
        self.replies = replies or {}

    def __call__(self, script, args, timeout=600):
        name = os.path.basename(script)
        self.calls.append({"script": name, "args": list(args), "timeout": timeout})
        for key, val in self.replies.items():
            if key in name:
                return val(args) if callable(val) else val
        return 0, "", ""

    def find(self, script_part, flag=None):
        return [c for c in self.calls
                if script_part in c["script"] and (flag is None or flag in c["args"])]


MAP_PRERESOLVE_PS = os.path.join(HERE, "map-preresolve.ps1")


def preresolved(tmp, slugs, holds=None, residual=None):
    """Write the map-preresolve tables the real script would have written, so a map-lane fixture has
    its mechanical half without shelling PowerShell. Same injection philosophy as FakePS: the daemon's
    OWN behaviour over the table is what these fixtures are about, and map-preresolve's behaviour is
    fixtured in its own suite (which is where wiring a bid and watching the hold clear belongs).
    """
    out = os.path.join(tmp, "mapped-pre")
    os.makedirs(out, exist_ok=True)
    for slug in slugs:
        h = (holds or {}).get(slug) or []
        r = (residual or {}).get(slug) or []
        rows = [{"raw": "1 lb chicken", "term": "chicken", "canon_item": "Chicken", "bid": "chicken",
                 "board": "weekly", "resolution": "resolved", "gpu_known": True, "density_known": True,
                 "fooddb_known": True, "evidence": "exact vocabulary row", "source": "vocab"}]
        for t in r:
            rows.append({"raw": t, "term": t, "canon_item": None, "bid": None, "board": None,
                         "resolution": "unresolved", "gpu_known": False, "density_known": False,
                         "fooddb_known": False, "evidence": "no vocabulary row shares a core word",
                         "source": None})
        for x in h:
            rows.append({"raw": x["term"], "term": x["term"], "canon_item": x.get("canon_item"),
                         "bid": x.get("bid"), "board": "recipe", "resolution": "unbid",
                         "gpu_known": False, "density_known": True, "fooddb_known": True,
                         "evidence": "NO BID wired for this row", "source": "vocab"})
        with open(os.path.join(out, "%s.json" % slug), "w", encoding="utf-8") as f:
            json.dump({"slug": slug, "title": slug, "source_url": "https://d/%s" % slug, "servings": 4,
                       "line_count": len(rows), "resolved_count": 1, "residual_count": len(r),
                       "hold_count": len(h), "residual_terms": list(r), "holds": h, "rows": rows,
                       "macro_precheck": {"state": "partial", "reason": "fixture",
                                          "source": {"from": "candidate-pool.band", "cal": 500,
                                                     "carbs": 20, "protein_g": 35, "fat_g": None},
                                          "lines_covered": 1, "lines_total": len(rows),
                                          "uncovered_lines": list(r), "computed_per_serving": None,
                                          "portion_factor": None, "tuning": [],
                                          "missing_db_items": []}}, f)
    return tmp


def skeletoned(tmp, slugs, cal=500, carbs=20, protein=35.0):
    """Write the intake + snapshot build-intake-skeleton.ps1 would have written, so a write-lane
    fixture has its machine half without shelling PowerShell. Same injection philosophy as
    preresolved(): the daemon's behaviour OVER the skeleton is what these fixtures are about, and the
    skeleton builder's own behaviour is fixtured in its own suite."""
    out = os.path.join(tmp, "intake")
    os.makedirs(out, exist_ok=True)
    for slug in slugs:
        doc = {"name": slug, "slug": slug, "protein": "beef", "cuisine": "", "source_url": "https://d/x",
               "visibility": "paid",
               "ingredients": [{"item": "93/7 Ground Beef", "grams": 1568, "buy": "3 1/2 lb"},
                               {"item": "Rice", "grams": 630, "buy": "3 cups dry"},
                               {"item": "Yellow Onion", "grams": 220, "buy": "2 medium"}],
               "macros_per_serving": {"calories": cal, "protein_g": protein, "carbs_g": carbs, "fat_g": 20.0},
               "writer_notes": [], "forbidden_prose_terms": [], "prose": {},
               "head": {"description": "", "keywords": "", "image": "", "prepTime": "PT15M",
                        "cookTime": "PT25M", "totalTime": "PT40M", "steps": []}}
        with open(os.path.join(out, "%s.json" % slug), "w", encoding="utf-8") as f:
            json.dump(doc, f)
        with open(os.path.join(out, "%s.skeleton.json" % slug), "w", encoding="utf-8") as f:
            json.dump({"slug": slug, "findings": [], "intake": doc}, f)
    return tmp


def daemon(run_dir="R", run_id="drill-run", dispatcher=None, ps=None, **kw):
    return HD.Daemon(run_dir, run_id, dispatcher=dispatcher or FakeDispatch(),
                     ps=ps or FakePS(), quiet=True, **kw)


def arun(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


# =====================================================================================================
def run():
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    def H(title):
        print("")
        print(title)

    print("hunt-daemon self-test  (every dispatch and every shell call injected: zero tokens)")

    # =================================================================================================
    H("B5 - a null is STUCK, never a verdict")
    # =================================================================================================
    _b5tmp = tempfile.mkdtemp(prefix="daemon-b5-")
    skeletoned(_b5tmp, ["s1"])
    for lane_name, agent, seed_ch, schema in (
            ("write", "recipe-writer", "write", hunt_lib.WRITE),
            ("qa", "recipe-source-qa", "qa", hunt_lib.QA)):
        d = daemon(run_dir=_b5tmp, dispatcher=FakeDispatch({agent: [None, None, None, None]}))
        d.ch[seed_ch].push({"slug": "s1"})
        d.ch[seed_ch].close()
        arun(d.run((lane_name,)))
        o = d.outcomes[0] if d.outcomes else {}
        T("MUST FIRE  a %s dispatch that never answered marks the recipe STUCK, not rejected"
          % lane_name,
          o.get("status") == "stuck" and o.get("state") is None, json.dumps(o))
    d = daemon(run_dir=_b5tmp, dispatcher=FakeDispatch({"recipe-writer": [None, None, None, None]}))
    d.ch["write"].push({"slug": "s1"})
    d.ch["write"].close()
    arun(d.run(("write",)))
    T("MUST FIRE  and the state machine was never touched for it - a STUCK recipe's state file is "
      "exactly where it was",
      not d._ps.find("hunt-run.ps1", "-Advance"), json.dumps(d._ps.find("hunt-run.ps1", "-Advance")))
    T("CLEAN TWIN an explicit rejection IS a verdict and is recorded as one",
      _rejects_explicitly(), "not recorded as a rejection")

    # =================================================================================================
    H("B6 - retry budgets are keyed PER SLUG, and the breaker watches run-wide")
    # =================================================================================================
    _b6tmp = tempfile.mkdtemp(prefix="daemon-b6-")
    skeletoned(_b6tmp, ["s1"])
    d = daemon(run_dir=_b6tmp,
               dispatcher=FakeDispatch({"recipe-writer": [None, None, None, {"slug": "s1",
                                                                             "status": "ok",
                                                                             "state": "written"}]}))
    d.ch["write"].push({"slug": "s1"})
    d.ch["write"].close()
    arun(d.run(("write",)))
    T("MUST FIRE  a slug gets exactly MAX_STAGE_RETRIES retries and then STUCK, never an unbounded "
      "loop",
      d.retry_counts.get("write:s1") == hunt_lib.MAX_STAGE_RETRIES + 1
      and d.outcomes and d.outcomes[0]["status"] == "stuck",
      "counts=%s outcomes=%s" % (json.dumps(d.retry_counts), json.dumps(d.outcomes)))
    _brtmp = tempfile.mkdtemp(prefix="daemon-breaker-")
    skeletoned(_brtmp, ["s%d" % i for i in range(4)])
    d = daemon(run_dir=_brtmp, dispatcher=FakeDispatch({"recipe-writer": [None] * 30}))
    for i in range(4):
        d.ch["write"].push({"slug": "s%d" % i})
    d.ch["write"].close()
    arun(d.run(("write",)))
    T("MUST FIRE  a run-wide wall trips the breaker rather than burning every slug's budget against "
      "it (657 failed calls, 16.1M tokens, zero progress on 2026-08-16)",
      d.breaker.open, "breaker stayed shut after %d calls" % d.breaker.calls)
    T("  and every recipe caught by the open breaker is STUCK and resumable, not rejected",
      all(o["status"] == "stuck" for o in d.outcomes) and len(d.outcomes) >= 1,
      json.dumps(d.outcomes))

    # =================================================================================================
    H("B7 - verdicts are read by FIRST TOKEN, so a lowercase pass is a pass")
    # =================================================================================================
    for verdict, expect_pass in (("pass", True), ("PASS", True), ("PASS (with notes)", True),
                                 ("FAIL", False)):
        fd = FakeDispatch({"recipe-source-qa": [{"slug": "s1", "verdict": verdict, "owner": "writer"},
                                                {"slug": "s1", "verdict": "PASS"}],
                           "recipe-writer": [{}]})
        d = daemon(dispatcher=fd)
        d.ch["qa"].push({"slug": "s1"})
        d.ch["qa"].close()
        arun(d.run(("qa",)))
        repaired = bool(fd.prompts("recipe-writer"))
        T("%s verdict %-18s -> %s" % ("MUST FIRE " if expect_pass else "CLEAN TWIN", repr(verdict),
                                      "passes with no repair cycle" if expect_pass
                                      else "buys its one repair cycle"),
          (not repaired) == expect_pass, "repaired=%s" % repaired)

    # =================================================================================================
    H("B8 - a mapper verdict's terms reach the queue and the state file as DISTINCT elements")
    # =================================================================================================
    terms = ["green bell pepper", "shaved beef steak", "hy-vee's own,brand"]
    fd = FakeDispatch({"recipe-ingredient-mapper": [
        {"results": [{"slug": "s1", "status": "ok", "state": "pricing", "absent_terms": terms,
                      "optional_absent": ["cilantro"]}]}]})
    ps = FakePS()
    _b8tmp = tempfile.mkdtemp(prefix="daemon-b8map-")
    d = daemon(run_dir=preresolved(_b8tmp, ["s1"]), dispatcher=fd, ps=ps)
    d.ch["map"].push({"slug": "s1"})
    d.ch["map"].close()
    arun(d.run(("map",)))
    adv = [c for c in ps.find("hunt-run.ps1", "-Advance")
           if FakePS.value_after(c["args"], "-To") == "pricing"]
    got = FakePS.value_after(adv[0]["args"], "-Terms") if adv else None
    T("MUST FIRE  -Terms carries a LIST of 3, not one comma-joined string (B8 parked two recipes "
      "forever on 2026-08-16)",
      isinstance(got, list) and got == terms, json.dumps(got))
    T("MUST FIRE  and a term that CONTAINS a comma survives as one element rather than splitting",
      isinstance(got, list) and len(got) == 3 and got[2] == "hy-vee's own,brand", json.dumps(got))
    T("  the optional terms ride their own flag",
      FakePS.value_after(adv[0]["args"], "-OptionalTerms") == ["cilantro"] if adv else False,
      json.dumps(FakePS.value_after(adv[0]["args"], "-OptionalTerms") if adv else None))
    adds = ps.find("ingredient-queue.ps1", "-Add")
    T("MUST FIRE  each absent term is enqueued as its own -Term, by the DAEMON - the mapper never "
      "runs shell, so an agent-side marshalling bug is impossible rather than warned against",
      [FakePS.value_after(c["args"], "-Term") for c in adds] == terms,
      json.dumps([FakePS.value_after(c["args"], "-Term") for c in adds]))
    T("MUST FIRE  the mapper's own prompt tells it NOT to enqueue or advance",
      "DO NOT run hunt-run.ps1" in fd.prompts("recipe-ingredient-mapper")[0],
      fd.prompts("recipe-ingredient-mapper")[0][:120])
    # the real transport, proven against a real [string[]] parameter
    T("CLEAN TWIN and ps_invoke really does bind that list as a PowerShell array (the transport half)",
      _ps_array_roundtrip(terms), "the array did not survive the transport")

    # =================================================================================================
    H("B10 / B11 - the wave lane's refusals")
    # =================================================================================================
    T("MUST FIRE  a NO-GO naming nobody blocks the WHOLE wave - it is not a licence to publish any "
      "of it",
      _trim_all_blocked(), "clean slugs escaped a blame-the-wave NO-GO")
    T("MUST FIRE  clean recipes are trimmed back to qa-passed, never rejected for a neighbour's "
      "defect (two were held hostage on 2026-08-16)",
      _trim_returns_clean(), "a clean recipe was not returned to the pool")
    T("MUST FIRE  a repair that changed NOTHING does not buy a re-audit",
      _repair_claim_refused(), "it paid for a second audit")
    T("CLEAN TWIN a repair that really touched a spec does buy its re-audit",
      _repair_claim_holds(), "a real repair was refused")
    T("MUST FIRE  a wave closes MID-RUN the moment the pool reaches wave_size, while other lanes "
      "still run - v2's waveChain, ported, not an end-of-run sweep",
      *_wave_mid_run())

    # =================================================================================================
    H("The cost-engine mutex (section 4.5)")
    # =================================================================================================
    ok, detail = _cost_mutex()
    T("MUST FIRE  two write-lane completions landing together produce SERIALIZED cost passes and a "
      "costed.json that parses", ok, detail)

    # =================================================================================================
    H("The five phase-1 obligations")
    # =================================================================================================
    T("MUST FIRE  the decide dispatch after the first carries the run's accepted-so-far list (the "
      "single decider became N deciders without it, and accepted two chicken salads)",
      *_decide_threads_accepted())
    T("MUST FIRE  candidates are marked taken:<run-id> at POP, BEFORE the dispatch goes out",
      *_taken_before_dispatch())
    T("MUST FIRE  a candidate another run already took is DROPPED from the batch rather than "
      "dispatched twice",
      *_taken_refusal_drops())
    T("MUST FIRE  the in-flight dedup side is read from runs\\*\\state and reaches the dossier (the "
      "jalapeno-popper collision, S1's open gap)",
      *_inflight_side())
    T("MUST FIRE  a stop list it cannot read makes the daemon say UNKNOWN, never claim an empty "
      "neighbour list - blind is not clean",
      *_inflight_blind())
    T("  every PowerShell call the daemon makes goes through ps_invoke and nothing else",
      *_one_marshalling_road())

    # =================================================================================================
    H("The extraction lane (the 2026-08-24 pins)")
    # =================================================================================================
    T("MUST FIRE  a near-miss rung-1 escalation is re-rolled ONCE and settles",
      *_rung1_retry_settles())
    T("MUST FIRE  a second identical failure escalates - one retry, never a loop",
      *_rung1_retry_not_a_loop())
    T("MUST FIRE  a low-coverage mangle is never re-rolled; it goes straight down the ladder",
      *_rung1_no_retry_on_mangle())
    T("MUST FIRE  the daemon never starts or stops llama-server",
      *_never_touches_the_server())
    T("MUST FIRE  a server shape that cannot fit rung 2 accumulates escalations and NAMES the "
      "pending narrow pass in --status",
      *_pending_narrow_pass())
    T("MUST FIRE  a BLOCKED page (no cached page, server down) is STUCK - never an escalation to "
      "Claude and never a pass",
      *_blocked_is_not_escalated())
    T("MUST FIRE  rung 3's verification is computed over page_text_from_html, never raw markup",
      *_rung3_verifies_stripped_text())
    T("MUST FIRE  rung 3 deletes the escalation file on settle, or the lane double-dispatches a "
      "settled page",
      *_rung3_cleans_up())
    T("MUST FIRE  a low rung-3 verified rate is RECORDED as a concern, not escalated to nowhere",
      *_rung3_records_not_gates())

    # =================================================================================================
    H("B: the registrar is handed its evidence (2026-08-24)")
    # =================================================================================================
    T("MUST FIRE  the prompt carries the near-miss ROWS off the three commodity namespaces, so the "
      "registrar does not pay a turn to grep what the daemon already read",
      *_registrar_gets_evidence())
    T("MUST FIRE  ...and it is handed ROWS, never a conclusion - the block says in as many words that "
      "it is not exhaustive, so a food priced under an unrelated NAME is still the registrar's to find",
      *_registrar_evidence_is_not_a_verdict())
    T("MUST FIRE  an include-pattern match is surfaced too - that is how the board absorbs a food "
      "under another id, and it is the thing the gate exists to catch",
      *_registrar_evidence_shows_include())

    # =================================================================================================
    H("The band is a RUN PARAMETER (2026-08-24), and the pop obeys it")
    # =================================================================================================
    T("MUST FIRE  the pop offers the decider ONLY candidates that meet THIS RUN's band - `available` "
      "means it passed harvest's ingest constants, never that it passes the run's band",
      *_pop_filters_by_run_band())
    T("MUST FIRE  ...and the protein FLOOR filters too, which is the half no code had at all",
      *_pop_filters_by_protein_floor())
    T("MUST FIRE  a candidate whose nutrition is UNVERIFIED cannot confirm the band, so it waits - an "
      "inferred number is not evidence a dish clears a 50 g floor",
      *_pop_refuses_unverified())
    T("MUST FIRE  a run dir stating NO band runs with NO limits - an unstated edge is unbounded, not "
      "a refusal, because the absence of a constraint cannot wrongly reject anything",
      *_band_absent_is_unbounded())
    T("MUST FIRE  ...and each edge is optional SEPARATELY - a protein floor alone is a protein floor "
      "with no calorie or carb limit",
      *_band_partial_is_honoured())
    T("CLEAN TWIN the band comes off run.json, and a flag overrides one field for a drill",
      *_band_read_from_run_json())
    T("MUST FIRE  a floor above its own ceiling is refused, not run - it admits nothing and would "
      "source zero recipes without saying why",
      *_band_inverted_refused())
    T("CLEAN TWIN -ProteinMin 0 means NO FLOOR, said out loud, and reads the same as an absent one",
      *_band_zero_floor_is_no_floor())
    T("MUST FIRE  a band that constrains NOTHING admits an UNVERIFIED candidate - the verification "
      "requirement is about trusting a number we rely on, and a no-limit run relies on none",
      *_no_band_admits_unverified())
    T("CLEAN TWIN ...and the moment ANY limit is stated, verification is required again",
      *_any_limit_restores_verification())

    # =================================================================================================
    H("Lane-log completeness and the token stamp (section 4.5)")
    # =================================================================================================
    T("MUST FIRE  every judgment dispatch writes a start AND an end line",
      *_lane_pairs())
    T("MUST FIRE  the end line carries the REAL token stamp, which harvest-lane-tokens used to have "
      "to backfill",
      *_lane_tokens())
    T("MUST FIRE  a page settled by the LOCAL ladder is lane-logged too, -By local with tokens 0 - "
      "work done, not work skipped",
      *_lane_local())
    T("MUST FIRE  C1: the end stamp carries TURNS and the CACHE SPLIT, and the subagent-inclusive "
      "totals off modelUsage - so no future run needs transcript archaeology",
      *_lane_c1_stamps())
    T("MUST FIRE  C1: a dispatch that DELEGATED is reported as a finding, because the phase-5 "
      "mapper's 21-turn subagent appeared in no ledger at all",
      *_lane_c1_delegation_finding())

    # =================================================================================================
    H("A: the map lane's batch size is decided producer-side (2026-08-24), never by a channel wait")
    # =================================================================================================
    T("MUST FIRE  settled pages queued back-to-back are released to the map lane TOGETHER - the two "
      "singleton mapper batches of the 6b run cost 436,685 and 577,141 tokens FOR ONE RECIPE EACH",
      *_extract_batches_when_queued())
    T("MUST FIRE  ...and a LONE recipe is released the instant it settles, never held for company "
      "that cannot come - this is the B3 deadlock, and holding it would be that bug rebuilt",
      *_extract_releases_a_lone_recipe())
    T("MUST FIRE  every settled recipe reaches the map lane, whatever the grouping - a held recipe "
      "stranded at drain is the failure mode this whole design is shaped around",
      *_extract_strands_nothing())
    T("CLEAN TWIN the group never exceeds MAP_BATCH, so this cannot quietly widen the mapper's batch",
      *_extract_respects_map_batch())
    T("MUST FIRE  a recipe held in the group when the lane EXITS EARLY (breaker) is still released - "
      "this is the only path that reaches the drain flush, and without it that recipe strands",
      *_extract_drain_flush_releases_held())

    # =================================================================================================
    H("D7 - the mechanical half of MAP runs before the agent is paid")
    # =================================================================================================
    T("MUST FIRE  map-preresolve runs BEFORE the mapper dispatch, through ps_invoke, with the batch's "
      "slugs as a REAL LIST (never a second invocation style, never a comma-joined string)",
      *_preresolve_runs_first())
    T("MUST FIRE  exit 2 BLOCKS the batch: no mapper dispatch, every slug STUCK and resumable - "
      "could-not-look is never a clean bill",
      *_preresolve_two_blocks())
    T("CLEAN TWIN exit 0 (zero residual) STILL dispatches the mapper - the macro cross-check is its "
      "job on every recipe, so a full table shrinks the dispatch, it never skips the judge",
      *_preresolve_zero_still_dispatches())
    T("MUST FIRE  the dispatch carries the RESIDUAL lines and their evidence, not the vocabulary "
      "lecture the table has already answered",
      *_map_prompt_is_residual())
    T("MUST FIRE  an UNBID line holds the recipe at `mapped`: never priced, never queued, never "
      "pushed to the writer, and NAMED on the held list",
      *_unbid_holds())
    T("CLEAN TWIN with no unbid line the same batch routes to pricing exactly as before",
      *_no_hold_routes_normally())
    T("MUST FIRE  THE UNHOLD, against the REAL state machine and the REAL map-preresolve: the bid is "
      "wired between two seeds, and the second seed advances the recipe with ZERO dispatches",
      *_unhold_between_seeds())

    # =================================================================================================
    H("A-package - the DAEMON holds the pen on mapped\\<slug>.json (A1-A4 / pins P2-P6)")
    # =================================================================================================
    T("MUST FIRE  the mapper's two arrays are written to a rulings file and handed to "
      "map-preresolve -Assemble, per slug, through ps_invoke",
      *_assemble_is_the_daemons())
    T("MUST FIRE  an assembly that finds anything unsettled STUCKS the recipe with the lines NAMED, "
      "and it never reaches pricing or the writer",
      *_assemble_failure_is_stuck())
    T("MUST FIRE  a NEW commodity id is dispatched to the commodity-registrar BY THE DAEMON, on its "
      "own schema, and the verdict rides into the rulings file",
      *_registrar_is_dispatched())
    T("CLEAN TWIN a batch proposing no new id dispatches no registrar at all",
      *_no_proposal_no_registrar())
    T("MUST FIRE  a registrar that returns NO VERDICT is not an approval - no ruling is recorded and "
      "the finding says so",
      *_registrar_null_is_not_approval())
    T("MUST FIRE  the map prompt inlines the table's NEAR-MISS evidence whole, forbids estate "
      "re-reads except label lookups, and states the two-array contract",
      *_map_prompt_inlines_and_bans_reads())

    # =================================================================================================
    H("D8 - the intake skeleton, the pre-write band gate, and the locked-field postcondition")
    # =================================================================================================
    T("MUST FIRE  the skeleton is built BEFORE the writer is dispatched, per slug, through ps_invoke",
      *_skeleton_runs_first())
    T("MUST FIRE  an OUT-OF-BAND skeleton retires at `priced -> rejected-macros` with ZERO writer "
      "dispatches - v2 paid for the prose first and checked the band after",
      *_prewrite_band_retires())
    T("CLEAN TWIN an in-band skeleton dispatches the writer exactly once",
      *_prewrite_band_passes())
    T("MUST FIRE  an INCOMPLETE skeleton (exit 1) is STUCK - the band may not be ruled on a macro "
      "figure computed over part of the dish, and it is not a pass either",
      *_skeleton_incomplete_is_stuck())
    T("MUST FIRE  a BLOCKED skeleton (exit 2) is STUCK and never reaches the writer",
      *_skeleton_blocked_is_stuck())
    T("MUST FIRE  the write prompt says the intake ALREADY EXISTS and names only the writer-fillable "
      "fields - the writer completes it in place, it no longer creates it",
      *_write_prompt_is_in_place())
    T("MUST FIRE  a locked-field drift buys ONE re-dispatch, quoting the drifted fields VERBATIM",
      *_drift_buys_one_reask())
    T("MUST FIRE  a SECOND drift is rejected-qa with the fields in the detail - one correction, "
      "never a loop, never a silent daemon-side revert",
      *_second_drift_is_rejected())
    T("MUST FIRE  and against the REAL state machine that rejection LANDS - `priced -> rejected-qa` "
      "was being faked until D8 added the edge, and only a real-machine fixture could see it",
      *_second_drift_real_machine())
    T("CLEAN TWIN a clean prose-only fill passes with no re-dispatch at all",
      *_clean_fill_no_reask())
    T("MUST FIRE  a -Verify that could not RUN is STUCK, never a pass and never a drift",
      *_verify_blocked_is_stuck())
    T("MUST FIRE  a scratch cost ledger reaches build-v2-spec as -CostedFile, and the live run still "
      "gets -RunCost (the drill that wrote the live batch ledger is why this is a flag, not a habit)",
      *_scratch_cost_args())
    T("MUST FIRE  --status NAMES every stuck recipe and its reason - the gate run's header counted "
      "nine and said which of none",
      *_status_names_stuck())
    T("MUST FIRE  a spec build that REFUSES is STUCK with the guard's own sentence - never `written`, "
      "and never an in-band pass over a spec that does not exist",
      *_spec_build_refusal_is_stuck())
    T("MUST FIRE  a build that claims success but leaves no readable spec is STUCK too - `not "
      "reported` is in_band's v2 answer and it is not a verdict this lane may accept",
      *_unreadable_spec_is_stuck())
    T("CLEAN TWIN a spec that builds and reads in band advances to written and reaches QA",
      *_spec_build_clean())

    # =================================================================================================
    H("D7: the (source claim, our recompute) pair is recorded on every band ruling")
    # =================================================================================================
    T("MUST FIRE  a band ruling that RETIRES a recipe records the pair - beef-back-ribs advertised "
      "57 g protein and computed to 41.6, and 6b threw that evidence away",
      *_band_pair_on_retire())
    T("MUST FIRE  ...and a PASSING ruling records one too - the passes are the recipes the pre-filter "
      "got RIGHT, which is the half of the calibration data a failures-only log would lose",
      *_band_pair_on_pass())
    T("CLEAN TWIN the pair carries BOTH sides with their serving counts, or it calibrates nothing",
      *_band_pair_has_both_sides())

    # =================================================================================================
    H("B4: a gate may fail closed on a number we stand behind, not on one we called an estimate")
    # =================================================================================================
    T("MUST FIRE  a band REJECTION over macros resting on a needs_verify food-DB row PARKS the recipe "
      "for verification instead of killing it - beef-back-ribs died on an estimated 0.45 edible yield",
      *_needs_verify_parks_not_retires())
    T("CLEAN TWIN ...and a rejection over VERIFIED rows still retires, exactly as before",
      *_verified_rows_still_retire())

    # =================================================================================================
    H("The band gate, read off the built spec")
    # =================================================================================================
    T("MUST FIRE  a spec outside the band is retired and never reaches QA, in ONE advance "
      "(priced -> rejected-macros, since D8 gave `priced` that exit)",
      *_band_gate_fires())
    T("MUST FIRE  and against the REAL state machine the rejection LANDS on disk - the first build's "
      "direct priced->rejected-qa advance would have been refused and nobody would have seen it",
      *_band_gate_real_machine())
    T("CLEAN TWIN a spec inside the band advances to written and reaches QA",
      *_band_gate_clean())
    T("MUST FIRE  the WIP limit gates pool pops",
      *_wip_gates_pops())

    # =================================================================================================
    H("D10 - the price-evidence pre-pass: gather, degrade, dispatch anyway")
    # =================================================================================================
    T("MUST FIRE  a probe transport ERROR lands in the evidence as UNUSABLE with the exception text, "
      "and NEVER as EMPTY - probe carries TWO state-like fields and the ladder one is `verdict`",
      *_pregather_transport_error())
    T("MUST FIRE  an UNUSABLE store reaches the evidence file as UNUSABLE and the pricer is STILL "
      "dispatched - degrade, never block (the OPPOSITE of map-preresolve's exit 2)",
      *_pregather_degrades_and_dispatches())
    T("CLEAN TWIN every gatherable store answers: two server stores and two driver stores land "
      "MATCHES/EMPTY, and only the tiers no pre-pass reaches stay UNUSABLE",
      *_pregather_clean_twin())
    T("MUST FIRE  ONE probe call for the whole batch, -Term bound as a REAL LIST and NAMED - a "
      "comma-joined term list is B8 with a Python accent",
      *_pregather_one_probe_named_array())
    T("MUST FIRE  the driver lookup goes down the PYTHON road (sys.executable), never ps_invoke, and "
      "carries --lookup-terms-file/--lookup-out for exactly one --store",
      *_pregather_lookup_is_python())
    T("MUST FIRE  the daemon writes NO queue record from evidence - search states and queue states "
      "never mix - while -Derive still runs, because that stays the orchestrator's",
      *_pregather_never_records())
    T("MUST FIRE  the pricer dispatch carries NO schema, so the adapter appends no return contract "
      "and its free-text report stays legal",
      *_pregather_no_schema())
    T("MUST FIRE  the evidence is INLINE in the prompt and the file is batch-<n>.json under the run "
      "dir, with n the lane's own invocation counter",
      *_pregather_inline_and_numbered())

    # =================================================================================================
    H("B3 / pin P9 - the price prompt tells the pricer the truth about its hands")
    # =================================================================================================
    T("MUST FIRE  the prompt states UNCONDITIONALLY that no browser exists, names Hy-Vee/Walmart/Aldi "
      "as blocked in the same batch, and asks for none of what the session cannot do",
      *_price_prompt_headless_truth())
    T("MUST FIRE  a store the evidence marks UNUSABLE at the server or driver tier is NAMED as "
      "not-to-be-re-probed - a transport refusal is not an empty shelf",
      *_price_prompt_no_reprobe())
    T("MUST FIRE  the prompt asks for ONE -RecordBatch call, not one -Record per store per term, and "
      "says the batch is all-or-nothing",
      *_price_prompt_one_batch())

    # =================================================================================================
    H("Resume, against a real scratch run dir")
    # =================================================================================================
    for name, ok, got in _resume_seed_table():
        T(name, ok, got)

    # =================================================================================================
    H("B5 / pin P7 - a resumed run repopulates absent_terms from the QUEUE")
    # =================================================================================================
    for name, ok, got in _b5_reseed_from_queue():
        T(name, ok, got)

    # =================================================================================================
    H("G - the mechanical stages are lane events, and lane() does not recurse")
    for name, ok, got in _mechanical_lane_events():
        T(name, ok, got)

    print("")
    if bad:
        print("hunt-daemon SELF-TEST FAIL (%d)" % len(bad))
        print("HUNT-DAEMON-COMPLETE")
        return hunt_lib.EXIT_CANNOT_RUN
    print("hunt-daemon SELF-TEST PASS")
    print("HUNT-DAEMON-COMPLETE")
    return hunt_lib.EXIT_CLEAN


# =====================================================================================================
# the fixture bodies
# =====================================================================================================

# =====================================================================================================
# D10 - the price-evidence pre-pass.
#
# The injected probe reply is price_evidence.PROBE_JSON_SAMPLE, which is a literal frozen from
# probe-ingredient.ps1's own -Json emitter on 2026-08-24 and carries the field-mapping trap on
# purpose: guacamole at Family Fare is transport ERROR (a Freshop 400), and pico de gallo at Family
# Fare is NO-CREDENTIALS. It is READ from price_evidence rather than copied here, because two
# copies of a frozen shape are two copies that drift apart.
# =====================================================================================================

PRICE_TERMS = ["guacamole", "pico de gallo", "korean-rice-cakes"]


def _probe_ok(args):
    return 0, json.dumps(price_evidence.PROBE_JSON_SAMPLE), ""


def _probe_dead(args):
    return 1, "", "Get-KrogerToken : The remote server returned an error: (401) Unauthorized."


def _lookup_writer(states):
    """Stand in for the driver: write the lookup file the real one would have written.

    `states` is {term: state}. A term the map does not name is left out of the file entirely, which
    is the 'the sweep never reached it' case.
    """
    def w(args):
        out = FakePS.value_after(args, "--lookup-out")
        tf = FakePS.value_after(args, "--lookup-terms-file")
        key = FakePS.value_after(args, "--store")
        name = dict(price_evidence.DRIVER_STORES).get(key, key)
        with open(tf, "r", encoding="utf-8-sig") as fh:
            terms = json.load(fh)
        results = []
        for t in terms:
            st = states.get(t)
            if not st:
                continue
            results.append({"term": t, "state": st, "term_used": t,
                            "attempts": [{"term": t, "state": st, "hits": 1 if st == "MATCHES" else 0}],
                            "hits": ([{"item": "%s house %s" % (name, t), "price": 3.99,
                                       "size": "8 oz", "relevance": None, "url": "u"}]
                                     if st == "MATCHES" else []),
                            "reason": "rung 1 only"})
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w", encoding="utf-8") as fh:
            json.dump({"store": name, "store_key": key, "generated": "", "ladder": "rung 1 only",
                       "note": "", "results": results}, fh)
        return 0, "", ""
    return w


def _price_daemon(terms=None, probe=None, py=None, run_dir=None):
    """The price lane, driven end to end with every shell and every dispatch injected."""
    tmp = run_dir or tempfile.mkdtemp(prefix="daemon-price-")
    ps = FakePS({"probe-ingredient": probe or _probe_ok})
    d = daemon(run_dir=tmp, ps=ps, pyrun=py or FakePy(),
               dispatcher=FakeDispatch({"recipe-hunter-pricer": [{"note": "free text"}]}))
    d.absent_terms = list(terms or PRICE_TERMS)
    d.ch["price_wake"].push({"wake": 1})
    d.ch["price_wake"].close()
    arun(d.run(("price",)))
    return d, tmp


def _evidence(tmp, n=1):
    with open(os.path.join(tmp, "price-evidence", "batch-%d.json" % n), "r",
              encoding="utf-8-sig") as fh:
        return json.load(fh)


def _stores_for(doc, term):
    for t in doc["terms"]:
        if t["term"] == term:
            return {s["store"]: s for s in t["stores"]}
    return {}


def _pregather_transport_error():
    d, tmp = _price_daemon()
    doc = _evidence(tmp)
    ff = _stores_for(doc, "guacamole")["Family Fare"]
    nc = _stores_for(doc, "pico de gallo")["Family Fare"]
    bk = _stores_for(doc, "guacamole")["Baker's"]
    ok = (ff["state"] == "UNUSABLE" and "400" in ff["reason"] and "ERROR" in ff["reason"]
          and nc["state"] == "UNUSABLE" and "krogerkey" in nc["reason"]
          and bk["state"] == "MATCHES")
    return ok, json.dumps([ff, nc, bk])[:300]


def _pregather_degrades_and_dispatches():
    """Everything mechanical fails: the probe dies and neither driver writes an output file."""
    py = FakePy({"pull-browser-stores": (1, "", "NEEDS SEEDING: no seeded Chrome profile")})
    d, tmp = _price_daemon(probe=_probe_dead, py=py)
    doc = _evidence(tmp)
    every = [s for t in doc["terms"] for s in t["stores"]]
    dispatched = [c for c in d._dispatch.calls if c["agent"] == "recipe-hunter-pricer"]
    ok = (all(s["state"] == "UNUSABLE" for s in every)
          and not any(s["state"] == "EMPTY" for s in every)
          and any("401" in s["reason"] for s in every)
          and any("NEEDS SEEDING" in s["reason"] or "no output file" in s["reason"] for s in every)
          and len(dispatched) == 1)
    return ok, "states=%s dispatched=%d" % (
        json.dumps(sorted({s["state"] for s in every})), len(dispatched))


def _pregather_clean_twin():
    py = FakePy({"pull-browser-stores": _lookup_writer(
        {"guacamole": "MATCHES", "pico de gallo": "EMPTY", "korean-rice-cakes": "MATCHES"})})
    d, tmp = _price_daemon(py=py)
    doc = _evidence(tmp)
    g = _stores_for(doc, "guacamole")
    p = _stores_for(doc, "pico de gallo")
    gathered_ok = (g["Baker's"]["state"] == "MATCHES"
                   and g["Fareway"]["state"] == "MATCHES"
                   and g["Sam's Club"]["state"] == "MATCHES"
                   and p["Fareway"]["state"] == "EMPTY"
                   and p["Baker's"]["state"] == "EMPTY")
    tiers_ok = (g["Hy-Vee"]["state"] == "UNUSABLE" and g["Hy-Vee"]["tier"] == "pricer-tab"
                and g["Walmart"]["tier"] == "attended" and g["Aldi"]["tier"] == "attended")
    dispatched = [c for c in d._dispatch.calls if c["agent"] == "recipe-hunter-pricer"]
    return (gathered_ok and tiers_ok and len(dispatched) == 1 and not d.findings,
            json.dumps({k: v["state"] for k, v in g.items()}) + " findings=%s" % d.findings)


def _pregather_one_probe_named_array():
    d, tmp = _price_daemon()
    calls = d._ps.find("probe-ingredient")
    if len(calls) != 1:
        return False, "%d probe call(s) for one batch" % len(calls)
    args = calls[0]["args"]
    term = FakePS.value_after(args, "-Term")
    return (isinstance(term, list) and term == PRICE_TERMS and "-Json" in args
            and calls[0]["timeout"] >= 900,
            "term=%r timeout=%s" % (term, calls[0]["timeout"]))


def _pregather_lookup_is_python():
    py = FakePy()
    d, tmp = _price_daemon(py=py)
    calls = py.find("pull-browser-stores")
    stores = sorted(FakePS.value_after(c["args"], "--store") for c in calls)
    flags_ok = all(("--lookup-terms-file" in c["args"] and "--lookup-out" in c["args"]
                    and c["args"].count("--store") == 1) for c in calls)
    on_ps = d._ps.find("pull-browser-stores")
    return (len(calls) == 2 and stores == ["fareway", "samsclub"] and flags_ok and not on_ps
            and all(c["timeout"] >= 40 * 60 for c in calls),
            "py=%s ps=%s" % (json.dumps(stores), json.dumps(on_ps)))


def _pregather_never_records():
    d, tmp = _price_daemon()
    recorded = d._ps.find("ingredient-queue", "-Record") + d._ps.find("ingredient-queue", "-Promote")
    derived = d._ps.find("hunt-run.ps1", "-Derive")
    return (not recorded and len(derived) == 1,
            "records=%d derives=%d" % (len(recorded), len(derived)))


def _pregather_no_schema():
    d, tmp = _price_daemon()
    call = [c for c in d._dispatch.calls if c["agent"] == "recipe-hunter-pricer"][0]
    return (call["schema"] is None and HD.hunt_dispatch.contract_text(None) == "",
            "schema=%r contract=%r" % (call["schema"], HD.hunt_dispatch.contract_text(None)))


def _pregather_inline_and_numbered():
    """12 terms is two batches at PRICE_BATCH=10, which is what proves n is the LANE's counter."""
    terms = ["guacamole", "pico de gallo", "korean-rice-cakes"] + ["t%d" % i for i in range(9)]
    tmp = tempfile.mkdtemp(prefix="daemon-price-n-")
    ps = FakePS({"probe-ingredient": _probe_ok})
    d = daemon(run_dir=tmp, ps=ps, pyrun=FakePy(),
               dispatcher=FakeDispatch({"recipe-hunter-pricer": [{"a": 1}, {"a": 2}]}))
    d.absent_terms = list(terms)
    d.ch["price_wake"].push({"wake": 1})
    d.ch["price_wake"].close()
    arun(d.run(("price",)))
    files = sorted(os.listdir(os.path.join(tmp, "price-evidence")))
    prompts = d._dispatch.prompts("recipe-hunter-pricer")
    inline = (len(prompts) == 2
              and "TERM 'guacamole'" in prompts[0] and "UNUSABLE" in prompts[0]
              and "batch-1.json" in prompts[0] and "batch-2.json" in prompts[1]
              and "TERM 't8'" in prompts[1])
    return ("batch-1.json" in files and "batch-2.json" in files and inline,
            json.dumps(files) + " prompts=%d" % len(prompts))


def _rejects_explicitly():
    fd = FakeDispatch({"recipe-ingredient-mapper": [
        {"results": [{"slug": "s1", "status": "rejected", "state": "rejected-not-carried",
                      "detail": "nobody carries it"}]}]})
    tmp = tempfile.mkdtemp(prefix="daemon-mapreject-")
    try:
        d = daemon(run_dir=preresolved(tmp, ["s1"]), dispatcher=fd)
        d.ch["map"].push({"slug": "s1"})
        d.ch["map"].close()
        arun(d.run(("map",)))
        return bool(d.outcomes) and d.outcomes[0]["status"] == "rejected"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _ps_array_roundtrip(terms):
    tmp = tempfile.mkdtemp(prefix="daemon-b8-")
    try:
        p = os.path.join(tmp, "t.ps1")
        with open(p, "w", encoding="utf-8") as f:
            f.write("param([string[]]$Terms=@())\n"
                    "Write-Output ('{0}|{1}' -f @($Terms).Count, (@($Terms) -join '~'))\nexit 0\n")
        rc, out, _e = hunt_lib.ps_invoke(p, ["-Terms", list(terms)])
        return out.strip() == "%d|%s" % (len(terms), "~".join(terms))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _wave_daemon(audit_seq, run_dir, ps=None, repair_touches=None):
    script = {"recipe-batch-auditor": list(audit_seq),
              "recipe-writer": [{}], "post-publish-reviewer": [{}]}
    fd = FakeDispatch(script)

    def touch(agent, prompt, **kw):
        if agent == "recipe-writer" and repair_touches:
            for p in repair_touches:
                with open(p, "a", encoding="utf-8") as f:
                    f.write("x")
        return fd(agent, prompt, **kw)

    d = daemon(run_dir=run_dir, dispatcher=touch, ps=ps or FakePS())
    return d, fd


def _wave_scratch():
    """A scratch run dir with a wave manifest and an audit file, so the wave lane's real reads work."""
    tmp = tempfile.mkdtemp(prefix="daemon-wave-")
    os.makedirs(os.path.join(tmp, "waves"), exist_ok=True)
    with open(os.path.join(tmp, "waves", "wave-1.json"), "w", encoding="utf-8") as f:
        json.dump({"wave": 1, "run": "drill-run", "batch": "drill-run-w1",
                   "slugs": ["a", "b", "c"]}, f)
    with open(os.path.join(tmp, "waves", "wave-1.audit.md"), "w", encoding="utf-8") as f:
        f.write("NO-GO\nscope: whole-wave\n")
    return tmp


def _trim_all_blocked():
    tmp = _wave_scratch()
    try:
        ps = FakePS({"hunt-run.ps1": lambda a: (0, "hunt-run: wave 1 closed with 3 recipe(s)", "")})
        d, _fd = _wave_daemon([{"verdict": "NO-GO", "blocking_slugs": [], "blocker_kind": "shared-data",
                                "summary": "the wave as a whole"},
                               {"verdict": "NO-GO", "blocking_slugs": []}], tmp, ps)
        arun(d.run_wave(1))
        to = {FakePS.value_after(c["args"], "-Slug"): FakePS.value_after(c["args"], "-To")
              for c in ps.find("hunt-run.ps1", "-Advance")}
        return all(to.get(s) == "rejected-audit" for s in ("a", "b", "c"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _trim_returns_clean():
    tmp = _wave_scratch()
    try:
        ps = FakePS({"hunt-run.ps1": lambda a: (0, "hunt-run: wave 1 closed with 3 recipe(s)", "")})
        d, _fd = _wave_daemon([{"verdict": "NO-GO", "blocking_slugs": ["a"],
                                "blocker_kind": "recipe-local", "owner": "writer",
                                "summary": "a is wrong"},
                               {"verdict": "NO-GO", "blocking_slugs": ["a"]}], tmp, ps,
                              repair_touches=[os.path.join(tmp, "waves", "wave-1.json")])
        # the repair must LOOK like it changed something, or the mtime check short-circuits first
        d.mtimes = _mtimes_with(d, changed=["a"])
        arun(d.run_wave(1))
        to = {}
        for c in ps.find("hunt-run.ps1", "-Advance"):
            to.setdefault(FakePS.value_after(c["args"], "-Slug"), []).append(
                FakePS.value_after(c["args"], "-To"))
        return to.get("b") == ["qa-passed"] and to.get("c") == ["qa-passed"] \
            and to.get("a") == ["rejected-audit"] and "b" in d.qa_passed and "c" in d.qa_passed
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _mtimes_with(d, changed):
    real = d.mtimes
    state = {"n": 0}

    def fake(slugs, audit_path):
        state["n"] += 1
        base = {os.path.join(HD.SPECS_DIR, "%s.json" % s): 100 for s in slugs}
        base["__audit__"] = 100
        if state["n"] > 1:
            for s in changed:
                base[os.path.join(HD.SPECS_DIR, "%s.json" % s)] = 200
        return base
    return fake


def _repair_claim_refused():
    tmp = _wave_scratch()
    try:
        ps = FakePS({"hunt-run.ps1": lambda a: (0, "hunt-run: wave 1 closed with 3 recipe(s)", "")})
        d, fd = _wave_daemon([{"verdict": "NO-GO", "blocking_slugs": ["a"],
                               "blocker_kind": "recipe-local", "owner": "writer", "summary": "x"},
                              {"verdict": "GO"}], tmp, ps)
        d.mtimes = _mtimes_with(d, changed=[])       # the repair touches nothing
        arun(d.run_wave(1))
        # the auditor was dispatched ONCE (the first audit) and never re-dispatched
        return len(fd.prompts("recipe-batch-auditor")) == 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _repair_claim_holds():
    tmp = _wave_scratch()
    try:
        ps = FakePS({"hunt-run.ps1": lambda a: (0, "hunt-run: wave 1 closed with 3 recipe(s)", ""),
                     "wave-publish.ps1": lambda a: (0, "== DRY RUN - every gate above passed", "")})
        d, fd = _wave_daemon([{"verdict": "NO-GO", "blocking_slugs": ["a"],
                               "blocker_kind": "recipe-local", "owner": "writer", "summary": "x"},
                              {"verdict": "GO"}], tmp, ps)
        d.mtimes = _mtimes_with(d, changed=["a"])
        arun(d.run_wave(1))
        prompts = fd.prompts("recipe-batch-auditor")
        return len(prompts) == 2 and "scope: a" in prompts[1]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _wave_mid_run():
    """The six-dimension check caught the first daemon build closing waves only after every lane
    drained. This pins the ported behavior: the SECOND qa-pass at wave_size 2 schedules wave 1 while
    the qa channel is still open, drain=False; the drain then force-closes the remainder."""
    fd = FakeDispatch({"recipe-source-qa": [{"slug": "s1", "verdict": "PASS"},
                                            {"slug": "s2", "verdict": "PASS"},
                                            {"slug": "s3", "verdict": "PASS"}]})
    d = daemon(dispatcher=fd, wave_size=2)
    seen = []

    async def fake_wave(k, drain=False):
        seen.append({"wave": k, "drain": drain, "qa_open": not d.ch["qa"].is_closed()})
    d.run_wave = fake_wave

    async def drill():
        task = asyncio.ensure_future(d.qa_lane())
        d.ch["qa"].push({"slug": "s1"})
        d.ch["qa"].push({"slug": "s2"})
        for _ in range(600):
            if seen:
                break
            await asyncio.sleep(0.01)
        mid = list(seen)                       # what had closed while the lane was still open
        d.ch["qa"].push({"slug": "s3"})
        d.ch["qa"].close()
        await task
        d.schedule_wave(True)                  # the drain, as run() performs it
        if d._wave_chain is not None:
            await d._wave_chain
        return mid, list(seen)

    mid, all_waves = arun(drill())
    ok = (len(mid) == 1 and mid[0]["wave"] == 1 and mid[0]["drain"] is False
          and mid[0]["qa_open"] and len(all_waves) == 2 and all_waves[1]["drain"] is True)
    return ok, "mid=%s all=%s" % (json.dumps(mid), json.dumps(all_waves))


def _cost_mutex():
    """Two write-lane completions landing together. The cost engine is a real subprocess-free stub
    that APPENDS to costed.json under the lock; without serialization the two interleave and the file
    stops parsing, which is the failure v2 actually watched happen mid-audit."""
    tmp = tempfile.mkdtemp(prefix="daemon-cost-")
    try:
        costed = os.path.join(tmp, "costed.json")
        with open(costed, "w", encoding="utf-8") as f:
            json.dump({"rows": []}, f)

        def slow_cost(script, args, timeout=180):
            if "build-v2-spec" not in os.path.basename(script):
                return 0, "", ""
            # read - pause - write, which is what shelling the cost engine does at a coarser grain
            with open(costed, "r", encoding="utf-8") as fh:
                doc = json.load(fh)
            time.sleep(0.20)
            doc["rows"].append(HD.Daemon.spec_band.__name__)
            with open(costed, "w", encoding="utf-8") as fh:
                json.dump(doc, fh)
            return 0, "", ""

        fd = FakeDispatch({"recipe-writer": [{"slug": "s1", "status": "ok", "state": "written"},
                                             {"slug": "s2", "status": "ok", "state": "written"}]})
        skeletoned(tmp, ["s1", "s2"])
        d = daemon(run_dir=tmp, dispatcher=fd, ps=slow_cost)
        d.spec_band = lambda slug, specs_dir=None: (500, 20, 40)      # in band, so the lane completes
        d.ch["write"].push({"slug": "s1"})
        d.ch["write"].push({"slug": "s2"})
        d.ch["write"].close()
        t0 = time.time()
        arun(d.run(("write",)))
        wall = time.time() - t0
        with open(costed, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        overlap = any(a[1] > b[0] + 1e-6 and b[1] > a[0] + 1e-6
                      for i, a in enumerate(d.cost_passes) for b in d.cost_passes[i + 1:])
        ok = (len(d.cost_passes) == 2 and not overlap and len(doc["rows"]) == 2 and wall >= 0.35)
        return ok, ("passes=%d overlap=%s rows=%d wall=%.2fs (two 0.2s passes cannot serialize in "
                    "under 0.4s)" % (len(d.cost_passes), overlap, len(doc["rows"]), wall))
    except Exception as e:                                        # noqa: BLE001
        return False, "threw: %s" % e
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _decide_pool(tmp, slugs, band=None):
    """Every fixture candidate carries a VERIFIED in-band nutrition block. new_entry() alone makes one
    with all-None macros, and since 2026-08-24 the pop filters by the RUN's band - an unverified
    candidate cannot confirm it meets the band, so a poolful of them pops nothing and every decide
    fixture downstream goes quiet. Fixture candidates now say what they are."""
    import harvest                                               # noqa: PLC0415
    band = band or {"cal": 500.0, "carbs": 20.0, "protein_g": 40.0, "verified": True, "reason": ""}
    cands = []
    for s in slugs:
        e = harvest.new_entry(s, s.replace("-", " ").title(), "https://d/%s" % s, "d", "drill")
        e["band"] = dict(band)
        cands.append(e)
    pool = {"candidates": cands}
    p = os.path.join(tmp, "pool.json")
    harvest.write_pool(pool, p)
    return p


def _decide_daemon(tmp, slugs, verdicts, run_dir=None):
    pool_path = _decide_pool(tmp, slugs)
    fd = FakeDispatch({"recipe-dedup-selector": list(verdicts)})
    d = daemon(run_dir=run_dir or os.path.join(tmp, "run"), dispatcher=fd, pool_path=pool_path)
    os.makedirs(d.run_dir, exist_ok=True)
    return d, fd, pool_path


def _verdict(slug, verdict="accepted"):
    return {"slug": slug, "verdict": verdict, "reason": "drill", "dupe_of": [],
            "record": {"name": slug, "protein": "beef", "method": "any", "verdict": verdict,
                       "reason": "drill"}}


def _decide_threads_accepted():
    tmp = tempfile.mkdtemp(prefix="daemon-decide-")
    try:
        slugs = ["cand-%02d" % i for i in range(1, 13)]
        d, fd, _p = _decide_daemon(tmp, slugs,
                                   [{"decisions": [_verdict(s) for s in slugs[:10]], "note": ""},
                                    {"decisions": [_verdict(s) for s in slugs[10:]], "note": ""}])
        # apply_verdict is exercised in decide_apply's own drill; here the ledger writes are stubbed
        d._apply = None
        import decide_apply                                       # noqa: PLC0415
        real = decide_apply.apply_verdict
        decide_apply.apply_verdict = (lambda payload, *a, **k:
                                      ([(x["slug"], x["verdict"], "applied")
                                        for x in payload["decisions"]], []))
        try:
            arun(d.run(("pool", "decide")))
        finally:
            decide_apply.apply_verdict = real
        prompts = fd.prompts("recipe-dedup-selector")
        if len(prompts) < 2:
            return False, "only %d decide dispatch(es); the fixture needs two batches" % len(prompts)
        first_batch = slugs[:10]
        ok = ("(nothing yet)" in prompts[0]
              and all(("ALREADY ACCEPTED THIS RUN" in prompts[1] and s in
                       prompts[1].split("DOSSIERS:")[0]) for s in first_batch))
        return ok, ("batch 2's preamble: %s"
                    % prompts[1].split("DOSSIERS:")[0][:220].replace("\n", " "))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _taken_before_dispatch():
    tmp = tempfile.mkdtemp(prefix="daemon-taken-")
    try:
        d, fd, pool_path = _decide_daemon(tmp, ["cand-a", "cand-b"],
                                          [{"decisions": [_verdict("cand-a"), _verdict("cand-b")]}])
        order = []
        real_mark = d.mark_taken

        async def mark(slug):
            order.append("take:%s" % slug)
            return await real_mark(slug)
        d.mark_taken = mark
        base = d._dispatch

        def disp(agent, prompt, **kw):
            order.append("dispatch:%s" % agent)
            return base(agent, prompt, **kw)
        d._dispatch = disp
        import decide_apply                                       # noqa: PLC0415
        real = decide_apply.apply_verdict
        decide_apply.apply_verdict = lambda payload, *a, **k: ([], [])
        try:
            arun(d.run(("pool", "decide")))
        finally:
            decide_apply.apply_verdict = real
        import harvest                                            # noqa: PLC0415
        status = {c["slug"]: c["status"] for c in harvest.read_pool(pool_path)["candidates"]}
        taken_first = order and order[0].startswith("take:") and "dispatch:" in order[-1]
        return (taken_first and all(v == "taken:drill-run" for v in status.values()),
                "order=%s status=%s" % (order, json.dumps(status)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _taken_refusal_drops():
    tmp = tempfile.mkdtemp(prefix="daemon-taken2-")
    try:
        d, fd, pool_path = _decide_daemon(tmp, ["cand-a", "cand-b"],
                                          [{"decisions": [_verdict("cand-b")]}])

        async def mark(slug):
            return slug != "cand-a"          # another run already holds cand-a
        d.mark_taken = mark
        import decide_apply                                       # noqa: PLC0415
        real = decide_apply.apply_verdict
        decide_apply.apply_verdict = lambda payload, *a, **k: ([], [])
        try:
            arun(d.run(("pool", "decide")))
        finally:
            decide_apply.apply_verdict = real
        prompts = fd.prompts("recipe-dedup-selector")
        body = prompts[0] if prompts else ""
        return ("cand-a" not in body and "cand-b" in body,
                "the dispatched batch still mentions cand-a" if "cand-a" in body else "dropped")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _inflight_scratch():
    tmp = tempfile.mkdtemp(prefix="daemon-inflight-")
    other = os.path.join(tmp, "runs", "hunt-other", "state")
    os.makedirs(other, exist_ok=True)
    with open(os.path.join(other, "jalapeno-popper-chicken-casserole.json"), "w",
              encoding="utf-8") as f:
        json.dump({"slug": "jalapeno-popper-chicken-casserole",
                   "title": "Jalapeno Popper Chicken Casserole", "state": "priced"}, f)
    with open(os.path.join(other, "already-published.json"), "w", encoding="utf-8") as f:
        json.dump({"slug": "already-published", "title": "Jalapeno Popper Chicken Bake",
                   "state": "published"}, f)
    return tmp


def _inflight_side():
    tmp = _inflight_scratch()
    try:
        rows = HD.read_inflight(os.path.join(tmp, "runs"))
        stop, why = HD.read_stop_list()
        if not stop:
            return False, "the fixture could not read the stop list: %s" % why
        hits = HD.inflight_neighbours("Jalapeno Popper Chicken", rows, stop)
        published_leaked = any(h["slug"] == "already-published" for h in hits)
        return (len(hits) == 1 and hits[0]["slug"] == "jalapeno-popper-chicken-casserole"
                and hits[0]["side"] == "in-flight" and not published_leaked,
                json.dumps(hits))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _inflight_blind():
    tmp = tempfile.mkdtemp(prefix="daemon-blind-")
    try:
        empty = os.path.join(tmp, "not-find-similar.ps1")
        with open(empty, "w", encoding="utf-8") as f:
            f.write("# no stop list here\n")
        stop, why = HD.read_stop_list(empty)
        if stop:
            return False, "it invented a stop list"
        d = daemon()
        prompt = d.decide_prompt([{"slug": "x", "name": "X", "dossier": {"slug": "x", "name": "X"}}],
                                 set())
        return ("NOT SEARCHED" in prompt and "unknown rather than empty" in prompt,
                "%s / the dossier does not say the search was skipped" % why)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _one_marshalling_road():
    """Grep the daemon's own source. Any second invocation style would have to be written here."""
    with open(os.path.join(HERE, "hunt-daemon.py"), "r", encoding="utf-8") as f:
        src = f.read()
    bad = []
    for needle in ('"-File"', "'-File'", "powershell.exe", '"powershell"'):
        if needle in src:
            bad.append(needle)
    return (not bad, "the daemon builds its own powershell command line: %s" % ", ".join(bad))


class StubLadder(object):
    """A ladder whose rung 1 fails a scripted number of times before settling."""

    def __init__(self, plan, ctx=16384):
        self.plan = list(plan)      # each entry: None settles, or a failures[] list
        self.calls = 0
        self.rung2_calls = 0
        self.allow_rung2 = True
        self.ctx = ctx

    def slot_ctx(self):
        return self.ctx

    def _out(self, failures, rung):
        settled = not failures
        ings = [{"raw": "1 lb chicken thighs", "item": "chicken thighs", "qty": "1", "unit": "lb",
                 "prep": None, "optional": False, "section": None}]
        return {"extraction": {"usable": True, "unusable_reason": None, "title": "T", "servings": 4,
                               "total_time": None, "active_time": None, "ingredients": ings,
                               "instructions": ["Cook."]},
                "verification": {"lines": 1, "verified": 1 if settled else 0,
                                 "unverified": 0 if settled else 1, "verified_rate": 1.0,
                                 "unverified_lines": [], "passed": settled,
                                 "bar": "every line (rung 1)", "failures": failures or []},
                "model": "stub", "tokens": 0, "rung": rung,
                "extracted_by": "jsonld-local" if rung == 1 else "local-page",
                "escalate": not settled,
                "escalate_reason": None if settled else "a line failed the split check"}

    def rung1(self, html, url):
        f = self.plan[self.calls] if self.calls < len(self.plan) else None
        self.calls += 1
        return self._out(f, 1)

    def rung2(self, html, url):
        self.rung2_calls += 1
        if self.ctx < HD.local_extract.RUNG2_MIN_SLOT_CTX:
            return None, "rung 2 BLOCKED: slot context too small"
        return self._out(None, 2), None


def _retry_ladder(plan, ctx=16384):
    inner = StubLadder(plan, ctx)
    return HD.RetryLadder(inner, None), inner


def _rung1_retry_settles():
    near = [{"raw": "1 dry pint cherry tomatoes", "coverage": 0.88, "reasons": ["round-trip 88%"]}]
    lad, inner = _retry_ladder([near, None])
    out = lad.rung1("<html/>", "u")
    return (not out["escalate"] and inner.calls == 2 and lad.retries == 1,
            "escalate=%s calls=%d retries=%d" % (out["escalate"], inner.calls, lad.retries))


def _rung1_retry_not_a_loop():
    near = [{"raw": "x", "coverage": 0.88, "reasons": ["round-trip 88%"]}]
    lad, inner = _retry_ladder([near, near, near, near])
    out = lad.rung1("<html/>", "u")
    return (out["escalate"] and inner.calls == 2 and lad.retries == 1,
            "the ladder called rung 1 %d time(s) - one retry, never a loop" % inner.calls)


def _rung1_no_retry_on_mangle():
    mangled = [{"raw": "x", "coverage": 0.40, "reasons": ["dropped half the line"]}]
    lad, inner = _retry_ladder([mangled, None])
    out = lad.rung1("<html/>", "u")
    return (out["escalate"] and inner.calls == 1 and lad.retries == 0,
            "it re-rolled a mangle (%d call(s))" % inner.calls)


def _extract_daemon(tmp, ladder, dispatch_script=None, url="https://d/p"):
    import harvest                                               # noqa: PLC0415
    d = daemon(run_dir=tmp, dispatcher=FakeDispatch(dispatch_script or {}))
    os.makedirs(os.path.join(tmp, "extracted"), exist_ok=True)
    d.ch["extract"].push({"slug": "p1", "url": url, "name": "P One", "domain": "d"})
    d.ch["extract"].close()
    real = harvest.cached_body
    harvest.cached_body = lambda u, cache_dir=None: ("<html><body>1 lb <strong>chicken</strong> "
                                                     "thighs</body></html>" if u == url else None)
    try:
        arun(d.extract_lane(ladder=ladder))
    finally:
        harvest.cached_body = real
    return d


def _never_touches_the_server():
    """Not a source grep - the daemon MENTIONS serve.ps1, in the one place it should: the operator
    advice its --status prints when the live server shape cannot fit rung 2. What must be true is
    that it never EXECUTES it. So: no script constant names the server, and no call the extract lane
    actually makes targets one."""
    banned = ("serve.ps1", "nightly.ps1", "llama-server")
    named = [k for k, v in vars(HD).items()
             if k.endswith("_PS") and isinstance(v, str)
             and any(b in v.lower() for b in banned)]
    if named:
        return False, "a script constant points at the server: %s" % ", ".join(named)
    tmp = tempfile.mkdtemp(prefix="daemon-gpu-")
    try:
        lad, _inner = _retry_ladder([None])
        ps = FakePS()
        import harvest                                            # noqa: PLC0415
        d = daemon(run_dir=tmp, ps=ps)
        os.makedirs(os.path.join(tmp, "extracted"), exist_ok=True)
        d.ch["extract"].push({"slug": "p1", "url": "https://d/p", "name": "P", "domain": "d"})
        d.ch["extract"].close()
        real = harvest.cached_body
        harvest.cached_body = lambda u, cache_dir=None: "<html><body>x</body></html>"
        try:
            arun(d.extract_lane(ladder=lad))
        finally:
            harvest.cached_body = real
        touched = [c["script"] for c in ps.calls
                   if any(b in c["script"].lower() for b in banned)]
        rep = d.status_report()
        return (not touched and "serve.ps1 -Slots 1" not in rep.split("PENDING NARROW PASS")[0],
                "the extract lane invoked %s" % ", ".join(touched))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _pending_narrow_pass():
    tmp = tempfile.mkdtemp(prefix="daemon-narrow-")
    try:
        lad, inner = _retry_ladder([[{"raw": "x", "coverage": 0.4, "reasons": ["r"]}]],
                                   ctx=4096)     # the 4-slot default: rung 2 does not fit
        d = _extract_daemon(tmp, lad)
        rep = d.status_report()
        return (inner.rung2_calls == 0 and d.escalations_blocked == ["p1"]
                and "PENDING NARROW PASS" in rep and "RUNG 2 UNAVAILABLE" in rep
                and "serve.ps1 -Slots 1" in rep,
                "rung2_calls=%d blocked=%s" % (inner.rung2_calls, d.escalations_blocked))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _blocked_is_not_escalated():
    tmp = tempfile.mkdtemp(prefix="daemon-blocked-")
    try:
        lad, _inner = _retry_ladder([None])
        fd = FakeDispatch({"recipe-hunter-extractor": [{"state": "ok", "ingredients": [],
                                                        "instructions": []}]})
        d = daemon(run_dir=tmp, dispatcher=fd)
        os.makedirs(os.path.join(tmp, "extracted"), exist_ok=True)
        d.ch["extract"].push({"slug": "p1", "url": "https://d/uncached", "name": "P", "domain": "d"})
        d.ch["extract"].close()
        import harvest                                            # noqa: PLC0415
        real = harvest.cached_body
        harvest.cached_body = lambda u, cache_dir=None: None       # nothing is cached
        try:
            arun(d.extract_lane(ladder=lad))
        finally:
            harvest.cached_body = real
        return (not fd.prompts("recipe-hunter-extractor")
                and d.outcomes and d.outcomes[0]["status"] == "stuck"
                and "BLOCKED" in d.outcomes[0]["detail"],
                json.dumps(d.outcomes))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _rung3_daemon(tmp, returned):
    """Drive rung 3 directly against a written escalation file."""
    import harvest                                               # noqa: PLC0415
    os.makedirs(os.path.join(tmp, "extracted"), exist_ok=True)
    esc = os.path.join(tmp, "extracted", "p1.escalation.json")
    with open(esc, "w", encoding="utf-8") as f:
        json.dump({"state": "escalate", "reason": "one line failed", "title": "P One",
                   "source_url": "https://d/p", "ingredients": [], "instructions": [],
                   "escalate": True, "escalate_reason": "one line failed"}, f)
    fd = FakeDispatch({"recipe-hunter-extractor": [returned]})
    d = daemon(run_dir=tmp, dispatcher=fd)
    real = harvest.cached_body
    # The page states the line WITH INLINE TAGS, which is the whole point: it substring-matches the
    # stripped text and never matches raw markup.
    harvest.cached_body = lambda u, cache_dir=None: (
        "<html><body><li>1 lb <strong>chicken</strong> thighs</li>"
        "<li>2 cups rice</li></body></html>")
    try:
        arun(d.rung3("p1"))
    finally:
        harvest.cached_body = real
    return d, esc


def _rung3_verifies_stripped_text():
    tmp = tempfile.mkdtemp(prefix="daemon-rung3-")
    try:
        d, _esc = _rung3_daemon(tmp, {
            "state": "ok", "title": "P One", "servings": 4,
            "ingredients": [{"raw": "1 lb chicken thighs", "item": "chicken thighs"},
                            {"raw": "2 cups rice", "item": "rice"}],
            "instructions": ["Cook."], "concerns": []})
        with open(os.path.join(tmp, "extracted", "p1.json"), "r", encoding="utf-8") as f:
            doc = json.load(f)
        v = doc.get("verification") or {}
        return (doc.get("extracted_by") == "claude" and v.get("verified") == 2
                and v.get("unverified") == 0 and v.get("passed") is True,
                json.dumps(v))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _rung3_cleans_up():
    tmp = tempfile.mkdtemp(prefix="daemon-rung3b-")
    try:
        d, esc = _rung3_daemon(tmp, {
            "state": "ok", "title": "P One",
            "ingredients": [{"raw": "1 lb chicken thighs", "item": "chicken thighs"},
                            {"raw": "2 cups rice", "item": "rice"}],
            "instructions": ["Cook."], "concerns": []})
        return (not os.path.exists(esc) and os.path.exists(os.path.join(tmp, "extracted", "p1.json")),
                "the escalation file survived a settle" if os.path.exists(esc)
                else "no settled file was written")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _rung3_records_not_gates():
    tmp = tempfile.mkdtemp(prefix="daemon-rung3c-")
    try:
        d, esc = _rung3_daemon(tmp, {
            "state": "ok", "title": "P One",
            "ingredients": [{"raw": "1 lb chicken thighs", "item": "chicken thighs"},
                            {"raw": "3 tablespoons invented sauce", "item": "invented sauce"}],
            "instructions": ["Cook."], "concerns": []})
        p = os.path.join(tmp, "extracted", "p1.json")
        with open(p, "r", encoding="utf-8") as f:
            doc = json.load(f)
        concerns = " ".join(doc.get("concerns") or [])
        return (os.path.exists(p) and not os.path.exists(esc)
                and doc["verification"]["unverified"] == 1 and "verified only" in concerns,
                "concerns=%s verification=%s" % (concerns[:120], json.dumps(doc["verification"])))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def judgment_lanes(ps):
    """The lane lines a JUDGMENT dispatch wrote - mechanical stages filtered out.

    NEEDED FROM 2026-08-24, when the mechanical stages started emitting their own start/end pairs so
    wall clock could be ATTRIBUTED rather than merely covered. These fixtures each say `judgment
    dispatch` in their own name and were reading EVERY line, which was the same thing right up until
    it was not: the write lane now logs build-intake-skeleton, skeleton verify and build-v2-spec
    around the writer. `-By mechanical` is the discriminator, and the assertions below are unchanged -
    only the population they are asserted over is now the one they always named.
    """
    return [c for c in ps.find("hunt-run.ps1", "-Lane")
            if FakePS.value_after(c["args"], "-By") != "mechanical"]


def _lane_daemon():
    fd = FakeDispatch({"recipe-writer": [{"slug": "s1", "status": "ok", "state": "written"}]})
    ps = FakePS()
    tmp = tempfile.mkdtemp(prefix="daemon-lane-")
    skeletoned(tmp, ["s1"])
    d = daemon(run_dir=tmp, dispatcher=fd, ps=ps)
    d.spec_band = lambda slug, specs_dir=None: (500, 20, 40)
    d.ch["write"].push({"slug": "s1"})
    d.ch["write"].close()
    arun(d.run(("write",)))
    return d, ps


def _lane_pairs():
    d, ps = _lane_daemon()
    lanes = judgment_lanes(ps)
    events = [FakePS.value_after(c["args"], "-Event") for c in lanes]
    return (events == ["start", "end"], json.dumps(events))


def _lane_tokens():
    d, ps = _lane_daemon()
    end = [c for c in judgment_lanes(ps)
           if FakePS.value_after(c["args"], "-Event") == "end"]
    if not end:
        return False, "no end line"
    tin = FakePS.value_after(end[0]["args"], "-InputTokens")
    tout = FakePS.value_after(end[0]["args"], "-OutputTokens")
    start = [c for c in judgment_lanes(ps)
             if FakePS.value_after(c["args"], "-Event") == "start"][0]
    return (tin == 1234 and tout == 56
            and FakePS.value_after(start["args"], "-InputTokens") == -1,
            "end in=%s out=%s / start in=%s (start must be -1: not reported is not zero)"
            % (tin, tout, FakePS.value_after(start["args"], "-InputTokens")))


def _lane_local():
    tmp = tempfile.mkdtemp(prefix="daemon-lanelocal-")
    try:
        lad, _inner = _retry_ladder([None])
        ps = FakePS()
        import harvest                                            # noqa: PLC0415
        d = daemon(run_dir=tmp, ps=ps)
        os.makedirs(os.path.join(tmp, "extracted"), exist_ok=True)
        d.ch["extract"].push({"slug": "p1", "url": "https://d/p", "name": "P", "domain": "d"})
        d.ch["extract"].close()
        real = harvest.cached_body
        harvest.cached_body = lambda u, cache_dir=None: "<html><body>x</body></html>"
        try:
            arun(d.extract_lane(ladder=lad))
        finally:
            harvest.cached_body = real
        lanes = ps.find("hunt-run.ps1", "-Lane")
        by = [FakePS.value_after(c["args"], "-By") for c in lanes]
        end = [c for c in lanes if FakePS.value_after(c["args"], "-Event") == "end"]
        adv = ps.find("hunt-run.ps1", "-Advance")
        return (by == ["local", "local"] and end
                and FakePS.value_after(end[0]["args"], "-InputTokens") == 0
                and FakePS.value_after(end[0]["args"], "-OutputTokens") == 0
                and adv and FakePS.value_after(adv[0]["args"], "-To") == "extracted",
                "by=%s tokens=%s" % (by, FakePS.value_after(end[0]["args"], "-InputTokens")
                                     if end else "none"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# =====================================================================================================
# D7 - map-preresolve, the unbid hold, and the unhold
# =====================================================================================================

def _map_daemon(tmp, slugs, mapper_result, ps=None, holds=None, residual=None, **kw):
    preresolved(tmp, slugs, holds=holds, residual=residual)
    fd = FakeDispatch({"recipe-ingredient-mapper": [mapper_result]})
    d = daemon(run_dir=tmp, dispatcher=fd, ps=ps or FakePS(), **kw)
    for slug in slugs:
        d.ch["map"].push({"slug": slug})
    d.ch["map"].close()
    arun(d.run(("map",)))
    return d, fd


def _preresolve_runs_first():
    tmp = tempfile.mkdtemp(prefix="daemon-pre1-")
    try:
        ps = FakePS()
        d, fd = _map_daemon(tmp, ["s1", "s2", "s3"],
                            {"results": [{"slug": s, "status": "ok", "state": "priced"}
                                         for s in ("s1", "s2", "s3")]}, ps=ps)
        # -Slugs, NOT every map-preresolve call. Since A1 the same script is ALSO invoked once per slug
        # as `-Assemble` to write mapped\<slug>.json, so an unfiltered count reads 4 for a 3-slug batch
        # and says nothing about the claim under test - which is that the mechanical PRE-RESOLVE pass
        # runs ONCE, for the whole batch, before a single token is spent.
        calls = [c for c in ps.find("map-preresolve.ps1") if "-Slugs" in c["args"]]
        asm = [c for c in ps.find("map-preresolve.ps1") if "-Assemble" in c["args"]]
        slugs = FakePS.value_after(calls[0]["args"], "-Slugs") if calls else None
        # Ordering is the claim: the table has to exist BEFORE the prompt is built, or the dispatch
        # carries a lecture instead of a residual. FakePS records calls in order and FakeDispatch
        # records its own, so the proof is that the mapper prompt names the pre-resolved counts at all.
        prompt = fd.prompts("recipe-ingredient-mapper")[0] if fd.prompts("recipe-ingredient-mapper") else ""
        return (len(calls) == 1 and isinstance(slugs, list) and slugs == ["s1", "s2", "s3"]
                and "map-preresolve.ps1 has already run" in prompt and len(asm) == 3,
                "preresolve=%d assemble=%d slugs=%s" % (len(calls), len(asm), json.dumps(slugs)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _preresolve_two_blocks():
    tmp = tempfile.mkdtemp(prefix="daemon-pre2-")
    try:
        ps = FakePS({"map-preresolve.ps1": lambda a: (2, "map-preresolve: BLOCKED - no extraction", "")})
        d, fd = _map_daemon(tmp, ["s1", "s2", "s3"],
                            {"results": [{"slug": "s1", "status": "ok", "state": "priced"}]}, ps=ps)
        stuck = [o for o in d.outcomes if o.get("status") == "stuck"]
        return (not fd.prompts("recipe-ingredient-mapper") and len(stuck) == 3
                and all("BLOCKED" in o["detail"] for o in stuck) and d.findings,
                "dispatches=%d stuck=%d" % (len(fd.prompts("recipe-ingredient-mapper")), len(stuck)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _preresolve_zero_still_dispatches():
    tmp = tempfile.mkdtemp(prefix="daemon-pre0-")
    try:
        ps = FakePS({"map-preresolve.ps1": lambda a: (0, "map-preresolve: 3 slug(s), 0 residual", "")})
        d, fd = _map_daemon(tmp, ["s1", "s2", "s3"],
                            {"results": [{"slug": s, "status": "ok", "state": "priced"}
                                         for s in ("s1", "s2", "s3")]}, ps=ps)
        return (len(fd.prompts("recipe-ingredient-mapper")) == 1 and not d.outcomes,
                "dispatches=%d outcomes=%d" % (len(fd.prompts("recipe-ingredient-mapper")),
                                               len(d.outcomes)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _map_prompt_is_residual():
    tmp = tempfile.mkdtemp(prefix="daemon-preP-")
    try:
        d, fd = _map_daemon(tmp, ["s1"], {"results": [{"slug": "s1", "status": "ok", "state": "priced"}]},
                            residual={"s1": ["ras el hanout", "dry white wine", "gochujang"]})
        prompt = fd.prompts("recipe-ingredient-mapper")[0]
        named = all(t in prompt for t in ("ras el hanout", "dry white wine", "gochujang"))
        # The v2 prompt's standing instruction was "Resolve every ingredient against the CLOSED
        # vocabulary first" - the lecture the table has now answered. It leaves in the same commit.
        return (named and "[unresolved]" in prompt
                and "Resolve every ingredient against the CLOSED vocabulary first" not in prompt
                and "MACRO CROSS-CHECK" in prompt,
                "named=%s lecture_gone=%s" % (named,
                    "Resolve every ingredient against the CLOSED vocabulary first" not in prompt))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _asm_ps(rc=0, out=""):
    """A FakePS whose map-preresolve -Assemble call answers with a chosen exit code. The pre-resolve
    road must keep answering 0, or the batch is blocked before the mapper is ever dispatched."""
    def reply(args):
        if "-Assemble" in args:
            return rc, out, ""
        return 0, "", ""
    return FakePS(replies={"map-preresolve": reply})


def _mapper_result(slug, proposals=None):
    return {"slug": slug, "status": "ok", "state": "priced",
            "lines": [{"raw": "1 lb chicken", "buy": "3 1/2 lb, cut into 1-inch pieces",
                       "notes": "exact 3.5x"},
                      {"raw": "gochujang", "buy": "1 cup plus 2 tbsp", "notes": "", "grams": 300},
                      {"raw": "tteok", "buy": "2 lb", "notes": ""}],
            "rulings": [{"raw": "gochujang", "term": "gochujang", "canon_item": "Gochujang",
                         "bid": "gochujang", "decision": "mapped", "grams": 300,
                         "evidence": "the Korean fermented chili paste, not a sauce"},
                        {"raw": "tteok", "term": "tteok", "canon_item": "Rice Cakes",
                         "bid": "korean-rice-cakes", "decision": "mapped", "grams": 900,
                         "evidence": "cylindrical tteok, NOT the Quaker snack cake the rice-cakes id "
                                     "prices"}],
            "new_commodity_proposals": list(proposals or [])}


def _assemble_is_the_daemons():
    r"""A1 / pin P2. The mapper returns two compact arrays; the DAEMON writes the file.

    On the phase-5 gate run the mapper wrote mapped\<slug>.json itself, in the pre-resolve TABLE'S
    shape, and build-intake-skeleton.ps1 exited 1 with "the mapper decision file names no mapped
    ingredient" over a recipe it had just settled cleanly. With the pen here, that shape is not
    reachable.
    """
    tmp = tempfile.mkdtemp(prefix="daemon-asm1-")
    try:
        ps = _asm_ps(0)
        d, fd = _map_daemon(tmp, ["s1"], {"results": [_mapper_result("s1")]}, ps=ps,
                            residual={"s1": ["gochujang", "tteok"]})
        asm = [c for c in ps.find("map-preresolve.ps1") if "-Assemble" in c["args"]]
        if len(asm) != 1:
            return False, "assemble calls=%d" % len(asm)
        rf = FakePS.value_after(asm[0]["args"], "-RulingsFile")
        slug = FakePS.value_after(asm[0]["args"], "-Slug")
        if not rf or not os.path.exists(rf):
            return False, "no rulings file at %r" % rf
        with open(rf, "r", encoding="utf-8") as f:
            pay = json.load(f)
        return (slug == "s1" and len(pay.get("lines") or []) == 3
                and len(pay.get("rulings") or []) == 2
                and pay["rulings"][1]["bid"] == "korean-rice-cakes"
                and "-Slug" in asm[0]["args"] and "," not in slug,
                "slug=%r lines=%d rulings=%d" % (slug, len(pay.get("lines") or []),
                                                 len(pay.get("rulings") or [])))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _assemble_failure_is_stuck():
    """A1. Nothing partly-settled advances. The old failure was an exit 1 a whole stage later, after
    the prose had been paid for; this is a STUCK at the map lane with the lines named."""
    tmp = tempfile.mkdtemp(prefix="daemon-asm2-")
    try:
        findings = ("map-preresolve -Assemble: 1 finding(s) - NOTHING was written\n"
                    "    FINDING  'tteok' has no gram weight from the engine or from a ruling\n")
        ps = _asm_ps(1, findings)
        d, fd = _map_daemon(tmp, ["s1"], {"results": [_mapper_result("s1")]}, ps=ps,
                            residual={"s1": ["gochujang", "tteok"]})
        outcomes = [o for o in d.outcomes if o["slug"] == "s1"]
        stuck = bool(outcomes) and outcomes[0]["status"] == "stuck"
        named = bool(outcomes) and "no gram weight" in (outcomes[0].get("detail") or "")
        advanced = [c for c in ps.find("hunt-run.ps1", "-Advance")
                    if FakePS.value_after(c["args"], "-To") == "pricing"]
        pushed = len(d.ch["write"].items) if hasattr(d.ch["write"], "items") else 0
        return (stuck and named and not advanced and not pushed,
                "stuck=%s named=%s advanced_to_pricing=%d detail=%s"
                % (stuck, named, len(advanced),
                   (outcomes[0].get("detail") if outcomes else "no outcome")))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _registrar_is_dispatched():
    """A4 / pin P6. A3 strips `Agent` from the mapper, which severs the road its own definition orders
    new ids down. The daemon rebuilds it - and as a STAMPED dispatch, not the invisible 21-turn
    subagent that cost $1.64 in no ledger on the phase-5 run."""
    tmp = tempfile.mkdtemp(prefix="daemon-reg1-")
    try:
        ps = _asm_ps(0)
        res = _mapper_result("s1", proposals=[
            {"term": "tteok", "proposed_bid": "korean-rice-cakes",
             "evidence": "rice-cakes is priced from Quaker snack cakes; this is a different food"}])
        fd = FakeDispatch({"recipe-ingredient-mapper": [{"results": [res]}],
                           "commodity-registrar": [{"verdict": "approve", "bid": "korean-rice-cakes",
                                                    "reason": "no id in any namespace prices tteok"}]})
        preresolved(tmp, ["s1"], residual={"s1": ["gochujang", "tteok"]})
        d = daemon(run_dir=tmp, dispatcher=fd, ps=ps)
        d.ch["map"].push({"slug": "s1"})
        d.ch["map"].close()
        arun(d.run(("map",)))
        calls = [c for c in fd.calls if c["agent"] == "commodity-registrar"]
        if len(calls) != 1:
            return False, "registrar dispatches=%d" % len(calls)
        schema_ok = calls[0]["schema"] is hunt_lib.REGISTRAR
        asked = "korean-rice-cakes" in calls[0]["prompt"] and "tteok" in calls[0]["prompt"]
        asm = [c for c in ps.find("map-preresolve.ps1") if "-Assemble" in c["args"]]
        rf = FakePS.value_after(asm[0]["args"], "-RulingsFile") if asm else None
        with open(rf, "r", encoding="utf-8") as f:
            pay = json.load(f)
        rulings = pay.get("registrar_rulings") or []
        return (schema_ok and asked and len(rulings) == 1
                and rulings[0]["verdict"] == "approve"
                and rulings[0]["proposed_bid"] == "korean-rice-cakes",
                "schema=%s asked=%s rulings=%s" % (schema_ok, asked, json.dumps(rulings)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _no_proposal_no_registrar():
    tmp = tempfile.mkdtemp(prefix="daemon-reg2-")
    try:
        fd = FakeDispatch({"recipe-ingredient-mapper": [{"results": [_mapper_result("s1")]}]})
        preresolved(tmp, ["s1"], residual={"s1": ["gochujang", "tteok"]})
        d = daemon(run_dir=tmp, dispatcher=fd, ps=_asm_ps(0))
        d.ch["map"].push({"slug": "s1"})
        d.ch["map"].close()
        arun(d.run(("map",)))
        calls = [c for c in fd.calls if c["agent"] == "commodity-registrar"]
        return not calls, "registrar dispatches=%d" % len(calls)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _registrar_null_is_not_approval():
    """SILENCE IS NOT CONSENT about whether a commodity is born. A duplicate id lets the same food
    carry two disagreeing prices while every per-file guard reads green - bread-crumbs vs breadcrumbs
    sat 2.9x apart across two boards until somebody spotted it by eye."""
    tmp = tempfile.mkdtemp(prefix="daemon-reg3-")
    try:
        ps = _asm_ps(0)
        res = _mapper_result("s1", proposals=[{"term": "tteok", "proposed_bid": "korean-rice-cakes",
                                               "evidence": "different food"}])
        fd = FakeDispatch({"recipe-ingredient-mapper": [{"results": [res]}],
                           "commodity-registrar": [None]})          # a transport failure: NO verdict
        preresolved(tmp, ["s1"], residual={"s1": ["gochujang", "tteok"]})
        d = daemon(run_dir=tmp, dispatcher=fd, ps=ps)
        d.ch["map"].push({"slug": "s1"})
        d.ch["map"].close()
        arun(d.run(("map",)))
        asm = [c for c in ps.find("map-preresolve.ps1") if "-Assemble" in c["args"]]
        rf = FakePS.value_after(asm[0]["args"], "-RulingsFile") if asm else None
        with open(rf, "r", encoding="utf-8") as f:
            pay = json.load(f)
        said = any("commodity-registrar returned no verdict" in f for f in d.findings)
        return (not (pay.get("registrar_rulings") or []) and said,
                "rulings=%s findings=%s" % (json.dumps(pay.get("registrar_rulings")),
                                            json.dumps(d.findings)[:220]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _map_prompt_inlines_and_bans_reads():
    """A2. Phase 1 measured inlining beating tool-call reads, and the evidence was being TRUNCATED at
    220 characters - which cut the near-miss list off the end, the single most useful sentence in the
    table. A prompt that hides what it already knows sends the model back to the estate to re-derive
    it, and every one of those reads is a turn that re-reads the accumulated context with it."""
    tmp = tempfile.mkdtemp(prefix="daemon-preQ-")
    try:
        long_ev = ("prior ruling: none; nearest vocabulary rows: White Wine Vinegar "
                   "[white-wine-vinegar] DIFFERENT FORM: vinegar | Rice Vinegar [rice-vinegar] "
                   "DIFFERENT FORM: vinegar | Sherry [sherry] same form; no densities.json row and no "
                   "each-noun; no food-macros-db row - a label needs transcribing; board NONE: no "
                   "commodity and no capture match")
        preresolved(tmp, ["s1"], residual={"s1": ["dry white wine"]})
        tpath = os.path.join(tmp, "mapped-pre", "s1.json")
        with open(tpath, "r", encoding="utf-8") as f:
            tbl = json.load(f)
        for row in tbl["rows"]:
            if row["term"] == "dry white wine":
                row["evidence"] = long_ev
                row["fooddb_known"] = False
        tbl["rows"][0]["grams_source_basis"] = 453.592
        with open(tpath, "w", encoding="utf-8") as f:
            json.dump(tbl, f)
        d = daemon(run_dir=tmp, ps=_asm_ps(0))
        prompt = d.map_prompt(["s1"], {"s1": tbl})
        whole = long_ev in prompt                       # not truncated at 220 chars
        bans = "Do NOT open the vocabulary" in prompt and "nutrition LABEL" in prompt
        contract = ("lines" in prompt and "rulings" in prompt
                    and "YOU DO NOT WRITE" in prompt
                    and " | ".join(hunt_lib.MAPPED_RULING_DECISIONS) in prompt)
        settled = "453.592" in prompt or "453.6" in prompt or "source-basis" in prompt
        registrar = "new_commodity_proposals" in prompt and "no longer\nhave the Agent tool" in prompt
        return (whole and bans and contract and settled and registrar,
                "whole=%s bans=%s contract=%s settled_weights=%s registrar=%s"
                % (whole, bans, contract, settled, registrar))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _unbid_holds():
    tmp = tempfile.mkdtemp(prefix="daemon-hold-")
    try:
        ps = FakePS()
        holds = {"s1": [{"term": "sumac", "canon_item": "Sumac", "bid": "",
                         "why": "'sumac' resolves to Sumac [(no commodity id)] but no bid is wired"}]}
        d, _fd = _map_daemon(tmp, ["s1"],
                             {"results": [{"slug": "s1", "status": "ok", "state": "priced",
                                           "absent_terms": []}]},
                             ps=ps, holds=holds)
        to = [FakePS.value_after(c["args"], "-To") for c in ps.find("hunt-run.ps1", "-Advance")]
        wrote = os.path.exists(os.path.join(tmp, "mapped-pre", "s1.hold.json"))
        return (to == ["mapped"] and len(d.held) == 1 and "no bid is wired" in d.held[0][1]
                and not ps.find("ingredient-queue.ps1") and d.ch["write"]._items.__len__() == 0 and wrote,
                "advances=%s held=%s wrote_record=%s" % (to, json.dumps(d.held), wrote))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _no_hold_routes_normally():
    tmp = tempfile.mkdtemp(prefix="daemon-nohold-")
    try:
        ps = FakePS()
        d, _fd = _map_daemon(tmp, ["s1"],
                             {"results": [{"slug": "s1", "status": "ok", "state": "pricing",
                                           "absent_terms": ["sumac"]}]}, ps=ps)
        to = [FakePS.value_after(c["args"], "-To") for c in ps.find("hunt-run.ps1", "-Advance")]
        return (to == ["mapped", "pricing"] and not d.held
                and len(ps.find("ingredient-queue.ps1", "-Add")) == 1,
                "advances=%s held=%s" % (to, json.dumps(d.held)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _unhold_between_seeds():
    """THE UNHOLD, end to end, against the REAL hunt-run.ps1 and the REAL map-preresolve.ps1.

    The seed table alone would strand a repaired recipe forever: it seeds `mapped`-with-holds to the
    HELD list, which is right while the hold stands and a trap the moment the missing bid is wired -
    on the next resume the recipe lands back on the held list with nobody re-checking anything. So the
    seed RE-RUNS map-preresolve over the `mapped` recipes, and a cleared hold advances on the ruling
    already on disk. The whole claim is in the last assertion: ZERO dispatches on the second seed.

    The scratch vocabulary is the thing being edited between the seeds, which is what "the bid is
    wired" means mechanically - a row in db\\ingredients.json gaining a bid.
    """
    tmp = tempfile.mkdtemp(prefix="daemon-unhold-")
    try:
        run_dir = os.path.join(tmp, "run")
        os.makedirs(os.path.join(run_dir, "extracted"), exist_ok=True)
        os.makedirs(os.path.join(run_dir, "mapped"), exist_ok=True)

        def write_vocab(sumac_bid):
            rows = [{"item": "Yellow Onion", "bid": "onions", "unit": "lb", "board": "weekly",
                     "gpu": 453.592},
                    {"item": "Sumac", "bid": sumac_bid, "unit": "oz", "board": "recipe", "gpu": 28.3495}]
            rows += [{"item": "Filler %d" % i, "bid": "filler-%d" % i, "unit": "oz", "board": "recipe",
                      "gpu": 28.3495} for i in range(1, 206)]
            with open(os.path.join(tmp, "vocab.json"), "w", encoding="utf-8") as f:
                json.dump(rows, f)

        write_vocab("")                       # the bid is NOT wired yet
        with open(os.path.join(tmp, "resolutions.json"), "w", encoding="utf-8") as f:
            json.dump({"count": 0, "resolutions": []}, f)
        with open(os.path.join(run_dir, "extracted", "unhold-drill.json"), "w", encoding="utf-8") as f:
            json.dump({"title": "Unhold Drill", "source_url": "https://d/u", "servings": 4,
                       "ingredients": [{"raw": "1 Yellow Onion", "item": "Yellow Onion", "qty": "1",
                                        "unit": None, "optional": False},
                                       {"raw": "1 tsp Sumac", "item": "Sumac", "qty": "1",
                                        "unit": "teaspoon", "optional": False}]}, f)
        # the mapper's decision file: the ruling the unhold advances ON, and never re-buys
        with open(os.path.join(run_dir, "mapped", "unhold-drill.json"), "w", encoding="utf-8") as f:
            json.dump({"slug": "unhold-drill", "ingredients": []}, f)

        seam = ["-NoBoard", "-NoPrecheck", "-VocabFile", os.path.join(tmp, "vocab.json"),
                "-ResolutionsFile", os.path.join(tmp, "resolutions.json")]

        rc, o, _e = hunt_lib.ps_invoke(HUNT_RUN_PS, ["-Init", "-RunDir", run_dir, "-Conditions",
                                                     "drill", "-Stop", "1", "-WaveSize", "2", "-CalMin", "400", "-CalMax", "650", "-CarbMax", "35", "-ProteinMin", "0"])
        if rc != 0:
            return False, "could not init: %s" % o.strip()[:150]
        for i, st in enumerate(["sourced", "selected", "extracted"]):
            args = ["-Advance", "-RunDir", run_dir, "-Slug", "unhold-drill", "-To", st,
                    "-By", "drill", "-Detail", "drill"]
            if i == 0:
                args += ["-Title", "Unhold Drill", "-SourceUrl", "https://d/u", "-Protein", "beef"]
            rc, o, _e = hunt_lib.ps_invoke(HUNT_RUN_PS, args)
            if rc != 0:
                return False, "staging refused at %s: %s" % (st, o.strip()[:150])

        # ---- the map lane, once. The mapper rules; the DAEMON holds on the unbid line.
        fd = FakeDispatch({"recipe-ingredient-mapper": [
            {"results": [{"slug": "unhold-drill", "status": "ok", "state": "priced",
                          "absent_terms": []}]}]})
        d0 = HD.Daemon(run_dir, "unhold-run", dispatcher=fd, quiet=True, preresolve_args=seam)
        d0.ch["map"].push({"slug": "unhold-drill"})
        d0.ch["map"].close()
        arun(d0.run(("map",)))
        if d0.state_of("unhold-drill") != "mapped" or len(d0.held) != 1:
            return False, "first pass: state=%s held=%s" % (d0.state_of("unhold-drill"),
                                                            json.dumps(d0.held))

        # ---- SEED 1: the bid is still missing, so the hold still stands and nothing is dispatched.
        fd1 = FakeDispatch({})
        d1 = HD.Daemon(run_dir, "unhold-run", dispatcher=fd1, quiet=True, preresolve_args=seam)
        ok1, err1 = arun(d1.seed())
        if not ok1:
            return False, "seed 1 failed: %s" % err1
        if len(d1.held) != 1 or d1.state_of("unhold-drill") != "mapped" or fd1.calls:
            return False, "seed 1: held=%s state=%s dispatches=%d" % (
                json.dumps(d1.held), d1.state_of("unhold-drill"), len(fd1.calls))

        # ---- THE BID IS WIRED. One row in the vocabulary gains a bid; nothing else changes.
        write_vocab("sumac")

        # ---- SEED 2: the hold clears, the recipe advances on the ruling already on disk, ZERO agents.
        fd2 = FakeDispatch({})
        d2 = HD.Daemon(run_dir, "unhold-run", dispatcher=fd2, quiet=True, preresolve_args=seam)
        ok2, err2 = arun(d2.seed())
        if not ok2:
            return False, "seed 2 failed: %s" % err2
        return (not d2.held and d2.state_of("unhold-drill") == "priced" and not fd2.calls
                and d2.ch["write"]._items.__len__() == 1,
                "seed 2: held=%s state=%s dispatches=%d write_q=%d"
                % (json.dumps(d2.held), d2.state_of("unhold-drill"), len(fd2.calls),
                   d2.ch["write"]._items.__len__()))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# =====================================================================================================
# D8 - the intake skeleton, the pre-write band gate, and the locked-field postcondition
# =====================================================================================================

def _write_daemon(tmp, slugs, writer_results, ps=None, cal=500, carbs=20, skeleton=True, **kw):
    if skeleton:
        skeletoned(tmp, slugs, cal=cal, carbs=carbs)
    fd = FakeDispatch({"recipe-writer": list(writer_results)})
    d = daemon(run_dir=tmp, dispatcher=fd, ps=ps or FakePS(), **kw)
    d.spec_band = lambda slug, specs_dir=None: (500, 20, 40)          # in band, so the lane completes
    for slug in slugs:
        d.ch["write"].push({"slug": slug})
    d.ch["write"].close()
    arun(d.run(("write",)))
    return d, fd


def _ok_write(slug="s1"):
    return {"slug": slug, "status": "ok", "state": "written"}


def _skeleton_runs_first():
    tmp = tempfile.mkdtemp(prefix="daemon-skel1-")
    try:
        ps = FakePS()
        d, fd = _write_daemon(tmp, ["s1"], [_ok_write()], ps=ps)
        builds = [c for c in ps.find("build-intake-skeleton.ps1") if "-Verify" not in c["args"]]
        prompt = fd.prompts("recipe-writer")[0] if fd.prompts("recipe-writer") else ""
        return (len(builds) == 1 and FakePS.value_after(builds[0]["args"], "-Slug") == "s1"
                and "THE INTAKE ALREADY EXISTS" in prompt,
                "builds=%d slug=%s" % (len(builds), FakePS.value_after(builds[0]["args"], "-Slug")
                                       if builds else None))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _prewrite_band_retires():
    """The whole point of moving the gate: v2 checked the band on the WRITE result, after the most
    expensive per-recipe stage had already run. Here the skeleton says 700 cal and no prose is paid
    for at all - the assertion that matters is `dispatches == 0`."""
    tmp = tempfile.mkdtemp(prefix="daemon-skel2-")
    try:
        ps = FakePS()
        d, fd = _write_daemon(tmp, ["s1"], [_ok_write()], ps=ps, cal=700)
        to = [FakePS.value_after(c["args"], "-To") for c in ps.find("hunt-run.ps1", "-Advance")]
        return (not fd.prompts("recipe-writer") and to == ["rejected-macros"]
                and d.outcomes and d.outcomes[0]["state"] == "rejected-macros"
                and "pre-write" in d.outcomes[0]["detail"],
                "dispatches=%d advances=%s outcome=%s"
                % (len(fd.prompts("recipe-writer")), to, json.dumps(d.outcomes)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _prewrite_band_passes():
    tmp = tempfile.mkdtemp(prefix="daemon-skel3-")
    try:
        ps = FakePS()
        d, fd = _write_daemon(tmp, ["s1"], [_ok_write()], ps=ps, cal=500)
        to = [FakePS.value_after(c["args"], "-To") for c in ps.find("hunt-run.ps1", "-Advance")]
        return (len(fd.prompts("recipe-writer")) == 1 and to == ["spec-built", "written"]
                and not d.outcomes,
                "dispatches=%d advances=%s" % (len(fd.prompts("recipe-writer")), to))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _skeleton_incomplete_is_stuck():
    tmp = tempfile.mkdtemp(prefix="daemon-skel4-")
    try:
        # The real script prints its summary, then TWO path lines, then the findings - so a blind
        # `detail[-400:]` handed the operator half a file path where the reason should be. Measured on
        # the phase-4 gate run. The fixture reproduces that shape.
        # The real script prints its summary, then TWO path lines, then the findings - so a blind
        # `detail[-400:]` handed the operator half a file path where the reason should be. Measured
        # on the phase-4 gate run. The fixture reproduces that shape.
        _skel_out = (
            "build-intake-skeleton: s1 - 8 line(s), 500 cal\n"
            "    FINDING  no food-macros-db row for 'Heavy Cream'\n"
            "build-intake-skeleton: intake C:\\a\\very\\long\\path\\s1.json\n"
            "build-intake-skeleton: snapshot C:\\a\\very\\long\\path\\s1.skeleton.json")
        ps = FakePS({"build-intake-skeleton.ps1": lambda a: (1, _skel_out, "")})
        d, fd = _write_daemon(tmp, ["s1"], [_ok_write()], ps=ps)
        return (not fd.prompts("recipe-writer") and d.outcomes
                and d.outcomes[0]["status"] == "stuck"
                and "Heavy Cream" in d.outcomes[0]["detail"]
                and "skeleton.json" not in d.outcomes[0]["detail"],
                "dispatches=%d outcomes=%s" % (len(fd.prompts("recipe-writer")),
                                               json.dumps(d.outcomes)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _skeleton_blocked_is_stuck():
    tmp = tempfile.mkdtemp(prefix="daemon-skel5-")
    try:
        ps = FakePS({"build-intake-skeleton.ps1":
                     lambda a: (2, "build-intake-skeleton: BLOCKED - required input missing", "")})
        d, fd = _write_daemon(tmp, ["s1"], [_ok_write()], ps=ps)
        return (not fd.prompts("recipe-writer") and d.outcomes
                and d.outcomes[0]["status"] == "stuck" and "BLOCKED" in d.outcomes[0]["detail"],
                "dispatches=%d outcomes=%s" % (len(fd.prompts("recipe-writer")),
                                               json.dumps(d.outcomes)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _write_prompt_is_in_place():
    tmp = tempfile.mkdtemp(prefix="daemon-skel6-")
    try:
        d, fd = _write_daemon(tmp, ["s1"], [_ok_write()])
        prompt = fd.prompts("recipe-writer")[0]
        # v2's line was "Produce ONE intake JSON at <RunDir>\intake\<slug>.json". It leaves in the
        # same commit as the skeleton, or the writer and the skeleton race for the same file with two
        # different ideas of who creates it.
        return ("THE INTAKE ALREADY EXISTS" in prompt and "FILL ONLY THESE FIELDS" in prompt
                and "Produce %s" % tmp not in prompt and "Compute NO number" in prompt
                and "forbidden_prose_terms" in prompt,
                prompt[:160])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _drift_reply(drifted):
    """A -Verify that reports drift once and then clean, the way a writer that fixed it would read."""
    seq = {"n": 0}

    def reply(args):
        if "-Verify" not in args:
            return 0, "", ""
        seq["n"] += 1
        if seq["n"] == 1:
            return 1, ("build-intake-skeleton: %d LOCKED FIELD(S) DRIFTED in s1\n" % len(drifted)
                       + "\n".join("    " + d for d in drifted)
                       + "\nBUILD-INTAKE-SKELETON-COMPLETE"), ""
        return 0, "every locked field is as issued", ""
    return reply


def _drift_buys_one_reask():
    tmp = tempfile.mkdtemp(prefix="daemon-drift1-")
    try:
        drifted = ["ingredients[1].grams: issued '630', returned '900'",
                   "macros_per_serving.calories: issued '500', returned '640'",
                   "head.totalTime: issued 'PT40M', returned 'PT25M'"]
        ps = FakePS({"build-intake-skeleton.ps1": _drift_reply(drifted)})
        d, fd = _write_daemon(tmp, ["s1"], [_ok_write(), _ok_write()], ps=ps)
        prompts = fd.prompts("recipe-writer")
        to = [FakePS.value_after(c["args"], "-To") for c in ps.find("hunt-run.ps1", "-Advance")]
        quoted = len(prompts) == 2 and all(d0 in prompts[1] for d0 in drifted)
        return (quoted and to == ["spec-built", "written"] and not d.outcomes
                and "This is the one correction" in prompts[1],
                "dispatches=%d quoted=%s advances=%s" % (len(prompts), quoted, to))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _second_drift_is_rejected():
    tmp = tempfile.mkdtemp(prefix="daemon-drift2-")
    try:
        drifted = ["ingredients[0].buy: issued '3 1/2 lb', returned '4 lb'",
                   "name: issued 's1', returned 's1 Deluxe'",
                   "macros_per_serving.fat_g: issued '20', returned '18'"]
        body = ("build-intake-skeleton: 3 LOCKED FIELD(S) DRIFTED in s1\n"
                + "\n".join("    " + d for d in drifted) + "\nBUILD-INTAKE-SKELETON-COMPLETE")
        ps = FakePS({"build-intake-skeleton.ps1":
                     lambda a: ((1, body, "") if "-Verify" in a else (0, "", ""))})
        d, fd = _write_daemon(tmp, ["s1"], [_ok_write(), _ok_write()], ps=ps)
        to = [FakePS.value_after(c["args"], "-To") for c in ps.find("hunt-run.ps1", "-Advance")]
        return (len(fd.prompts("recipe-writer")) == 2 and to == ["rejected-qa"]
                and d.outcomes and d.outcomes[0]["state"] == "rejected-qa"
                and "drifted twice" in d.outcomes[0]["detail"]
                and "ingredients[0].buy" in d.outcomes[0]["detail"],
                "dispatches=%d advances=%s outcome=%s"
                % (len(fd.prompts("recipe-writer")), to, json.dumps(d.outcomes)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _second_drift_real_machine():
    """The double-drift retirement, against the REAL hunt-run.ps1 on a scratch run dir.

    THE INJECTED TWIN ABOVE PASSED WHILE THIS ROUTE WAS ILLEGAL. `priced` allowed only `spec-built`
    and `rejected-macros`, so `priced -> rejected-qa` was REFUSED and the recipe stayed at `priced`
    on disk while the daemon counted it rejected - the same shape as phase 3's band-route trap, found
    the same way and by the same kind of fixture. D8 added the edge; this is what keeps it honest.
    """
    tmp = tempfile.mkdtemp(prefix="daemon-drift-real-")
    try:
        run_dir = os.path.join(tmp, "run")
        os.makedirs(run_dir, exist_ok=True)
        rc, o, _e = hunt_lib.ps_invoke(HUNT_RUN_PS, ["-Init", "-RunDir", run_dir, "-Conditions",
                                                     "drill", "-Stop", "1", "-WaveSize", "2", "-CalMin", "400", "-CalMax", "650", "-CarbMax", "35", "-ProteinMin", "0"])
        if rc != 0:
            return False, "could not init: %s" % o.strip()[:150]
        for i, st in enumerate(["sourced", "selected", "extracted", "mapped", "priced"]):
            args = ["-Advance", "-RunDir", run_dir, "-Slug", "drift-drill", "-To", st,
                    "-By", "drill", "-Detail", "drill"]
            if i == 0:
                args += ["-Title", "Drift Drill", "-SourceUrl", "https://d/x", "-Protein", "beef"]
            rc, o, _e = hunt_lib.ps_invoke(HUNT_RUN_PS, args)
            if rc != 0:
                return False, "staging refused at %s: %s" % (st, o.strip()[:150])
        skeletoned(run_dir, ["drift-drill"])
        drifted = ["ingredients[0].grams: issued '1568', returned '1900'",
                   "macros_per_serving.calories: issued '500', returned '640'",
                   "name: issued 'drift-drill', returned 'Drift Drill Deluxe'"]
        body = ("build-intake-skeleton: 3 LOCKED FIELD(S) DRIFTED in drift-drill\n"
                + "\n".join("    " + d for d in drifted) + "\nBUILD-INTAKE-SKELETON-COMPLETE")
        real_ps = hunt_lib.ps_invoke

        def ps(script, args, timeout=180):
            # the REAL hunt-run.ps1 for every state move; only the skeleton surface is scripted, so the
            # fixture can force a second drift without inventing a writer that makes one
            if "build-intake-skeleton" in os.path.basename(script):
                return (1, body, "") if "-Verify" in args else (0, "", "")
            return real_ps(script, args, timeout)

        fd = FakeDispatch({"recipe-writer": [{"slug": "drift-drill", "status": "ok",
                                              "state": "written"},
                                             {"slug": "drift-drill", "status": "ok",
                                              "state": "written"}]})
        d = HD.Daemon(run_dir, "drift-drill-run", dispatcher=fd, ps=ps, quiet=True)
        d.ch["write"].push({"slug": "drift-drill"})
        d.ch["write"].close()
        arun(d.run(("write",)))
        final = d.state_of("drift-drill")
        return (final == "rejected-qa" and len(fd.prompts("recipe-writer")) == 2 and not d.findings,
                "on-disk state=%s dispatches=%d findings=%s"
                % (final, len(fd.prompts("recipe-writer")), json.dumps(d.findings)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _status_names_stuck():
    tmp = tempfile.mkdtemp(prefix="daemon-statusstuck-")
    try:
        ps = FakePS({"build-v2-spec.ps1": lambda a: (1, "", "UNKNOWN INGREDIENT NAME: Marsala Wine")})
        d, _fd = _write_daemon(tmp, ["s1", "s2", "s3"],
                               [_ok_write("s1"), _ok_write("s2"), _ok_write("s3")], ps=ps)
        rep = d.status_report()
        return ("STUCK (no verdict was rendered" in rep
                and all(("    %s" % s) in rep for s in ("s1", "s2", "s3"))
                and "Marsala Wine" in rep,
                rep[-400:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _spec_build_refusal_is_stuck():
    """MEASURED ON THE PHASE-4 GATE RUN. Six writers were paid; build-v2-spec REFUSED all six on
    UNKNOWN INGREDIENT NAME (v2-era canon names the closed vocabulary no longer carries - "Marsala
    Wine", "Bacon Bits"); no spec was written; and the lane advanced every one of them to `written`.
    The band read then found no spec, and hunt_lib.in_band answers "not reported -> ok" BY DESIGN
    (v2 parity: a band nobody reported is not a rejection), so a refused build read as a pass.
    """
    tmp = tempfile.mkdtemp(prefix="daemon-specrc-")
    try:
        refusal = ("UNKNOWN INGREDIENT NAME: Marsala Wine are not in the ingredient vocabulary "
                   "(db\\ingredients.json). THE PRICE IS PROBABLY NOT MISSING - THE NAME IS WRONG.\n"
                   "At C:\\...\\build-v2-spec.ps1:261 char:3\n"
                   "    + CategoryInfo          : OperationStopped")
        ps = FakePS({"build-v2-spec.ps1": lambda a: (1, "", refusal)})
        d, fd = _write_daemon(tmp, ["s1"], [_ok_write()], ps=ps)
        to = [FakePS.value_after(c["args"], "-To") for c in ps.find("hunt-run.ps1", "-Advance")]
        return (not to and d.outcomes and d.outcomes[0]["status"] == "stuck"
                and "UNKNOWN INGREDIENT NAME: Marsala Wine" in d.outcomes[0]["detail"]
                and "CategoryInfo" not in d.outcomes[0]["detail"],
                "advances=%s outcomes=%s" % (to, json.dumps(d.outcomes)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _unreadable_spec_is_stuck():
    tmp = tempfile.mkdtemp(prefix="daemon-specnone-")
    try:
        ps = FakePS()
        skeletoned(tmp, ["s1"])
        fd = FakeDispatch({"recipe-writer": [_ok_write()]})
        d = daemon(run_dir=tmp, dispatcher=fd, ps=ps)
        d.spec_band = lambda slug, specs_dir=None: (None, None, None)   # the spec is not there
        d.ch["write"].push({"slug": "s1"})
        d.ch["write"].close()
        arun(d.run(("write",)))
        to = [FakePS.value_after(c["args"], "-To") for c in ps.find("hunt-run.ps1", "-Advance")]
        return (not to and d.outcomes and d.outcomes[0]["status"] == "stuck"
                and "no spec could be read" in d.outcomes[0]["detail"],
                "advances=%s outcomes=%s" % (to, json.dumps(d.outcomes)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _spec_build_clean():
    tmp = tempfile.mkdtemp(prefix="daemon-specok-")
    try:
        ps = FakePS()
        d, fd = _write_daemon(tmp, ["s1"], [_ok_write()], ps=ps)
        to = [FakePS.value_after(c["args"], "-To") for c in ps.find("hunt-run.ps1", "-Advance")]
        return (to == ["spec-built", "written"] and not d.outcomes,
                "advances=%s outcomes=%s" % (to, json.dumps(d.outcomes)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _clean_fill_no_reask():
    tmp = tempfile.mkdtemp(prefix="daemon-drift3-")
    try:
        ps = FakePS()
        d, fd = _write_daemon(tmp, ["s1"], [_ok_write()], ps=ps)
        verifies = [c for c in ps.find("build-intake-skeleton.ps1") if "-Verify" in c["args"]]
        return (len(fd.prompts("recipe-writer")) == 1 and len(verifies) == 1 and not d.outcomes,
                "dispatches=%d verifies=%d" % (len(fd.prompts("recipe-writer")), len(verifies)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _verify_blocked_is_stuck():
    """A diff with nothing to diff against is not a pass and it is not a drift either. Re-asking the
    writer here would be asking it to fix fields nobody can name."""
    tmp = tempfile.mkdtemp(prefix="daemon-drift4-")
    try:
        ps = FakePS({"build-intake-skeleton.ps1":
                     lambda a: ((2, "BLOCKED - no skeleton snapshot", "") if "-Verify" in a
                                else (0, "", ""))})
        d, fd = _write_daemon(tmp, ["s1"], [_ok_write(), _ok_write()], ps=ps)
        return (len(fd.prompts("recipe-writer")) == 1 and d.outcomes
                and d.outcomes[0]["status"] == "stuck"
                and "could not run" in d.outcomes[0]["detail"],
                "dispatches=%d outcomes=%s" % (len(fd.prompts("recipe-writer")),
                                               json.dumps(d.outcomes)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _scratch_cost_args():
    live = daemon()
    drill = daemon(costed_path="C:\\scratch\\costed.json", specs_dir="C:\\scratch\\recipes")
    a_live = live.spec_args("s1")
    a_drill = drill.spec_args("s1")
    return ("-RunCost" in a_live and "-CostedFile" not in a_live
            and "-CostedFile" in a_drill and "-OutDir" in a_drill
            and "-AllowUncosted" in a_drill and "-RunCost" not in a_drill,
            "live=%s drill=%s" % (json.dumps(a_live), json.dumps(a_drill)))


def _band(cal, carbs, prot=40):
    """The POST-BUILD band read. The skeleton is deliberately IN band (500/20) so the pre-write gate
    passes and these fixtures exercise the postcondition over the BUILT SPEC, which D8 keeps."""
    fd = FakeDispatch({"recipe-writer": [{"slug": "s1", "status": "ok", "state": "written"}]})
    ps = FakePS()
    tmp = tempfile.mkdtemp(prefix="daemon-band-")
    skeletoned(tmp, ["s1"], cal=500, carbs=20)
    d = daemon(run_dir=tmp, dispatcher=fd, ps=ps)
    d.spec_band = lambda slug, specs_dir=None: (cal, carbs, prot)
    d.ch["write"].push({"slug": "s1"})
    d.ch["write"].close()
    arun(d.run(("write",)))
    to = [FakePS.value_after(c["args"], "-To") for c in ps.find("hunt-run.ps1", "-Advance")]
    return d, to


def _band_gate_fires():
    """The route is load-bearing: the recipe sits at `priced` when the gate rules, so the rejection
    has to be legal FROM `priced`. The first build advanced priced -> rejected-qa directly; FakePS
    accepted it and the real state machine would have refused it, leaving the recipe at `priced` on
    disk while the daemon counted it rejected. The interim fix walked v2's measured trace
    (spec-built -> written -> rejected-qa), legal but asserting a spec build and a prose write that
    never happened. D8's state-graph edit gave `priced` a `rejected-macros` exit, so the route is
    now ONE advance and this fixture pins the count as much as the destination: three advances here
    again would mean the run record started claiming work nobody did. The real-machine twin below
    proves it LANDS."""
    d, to = _band(700, 20)
    return (to == ["rejected-macros"]
            and d.outcomes and d.outcomes[0]["status"] == "rejected"
            and d.outcomes[0]["state"] == "rejected-macros"
            and "above the 650 ceiling" in d.outcomes[0]["detail"],
            "advances=%s outcome=%s" % (to, json.dumps(d.outcomes)))


def _band_gate_real_machine():
    """The band rejection, against the REAL hunt-run.ps1 on a scratch run dir. This is the fixture
    the FakePS blind spot demands: it proves every advance in the route is LEGAL, so the on-disk
    state is the rejection rather than a refused transition nobody saw."""
    tmp = tempfile.mkdtemp(prefix="daemon-bandreal-")
    try:
        run_dir = os.path.join(tmp, "run")
        os.makedirs(run_dir, exist_ok=True)
        rc, o, _e = hunt_lib.ps_invoke(HUNT_RUN_PS, ["-Init", "-RunDir", run_dir, "-Conditions",
                                                     "drill", "-Stop", "1", "-WaveSize", "2", "-CalMin", "400", "-CalMax", "650", "-CarbMax", "35", "-ProteinMin", "0"])
        if rc != 0:
            return False, "could not init: %s" % o.strip()[:150]
        for i, st in enumerate(["sourced", "selected", "extracted", "mapped", "priced"]):
            args = ["-Advance", "-RunDir", run_dir, "-Slug", "band-drill", "-To", st,
                    "-By", "drill", "-Detail", "drill"]
            if i == 0:
                args += ["-Title", "Band Drill", "-SourceUrl", "https://d/x", "-Protein", "beef"]
            rc, o, _e = hunt_lib.ps_invoke(HUNT_RUN_PS, args)
            if rc != 0:
                return False, "staging refused at %s: %s" % (st, o.strip()[:150])
        # A WRITER THAT ACTUALLY WRITES. The REAL -Verify runs in this fixture, and it now refuses an
        # intake carrying no prose at all - which is exactly what a scripted FakeDispatch leaves
        # behind. So the scripted reply comes with the side effect a real writer would have had.
        class ProseWriter(FakeDispatch):
            def __call__(self, agent, prompt, **kw):
                ip = os.path.join(run_dir, "intake", "band-drill.json")
                try:
                    with open(ip, "r", encoding="utf-8-sig") as fh:
                        doc = json.load(fh)
                    doc["cuisine"] = "American"
                    doc["prose"] = {"intro_html": "The dinner."}
                    doc["head"]["description"] = "A drill."
                    with open(ip, "w", encoding="utf-8") as fh:
                        json.dump(doc, fh)
                except Exception:                                 # noqa: BLE001
                    pass
                return FakeDispatch.__call__(self, agent, prompt, **kw)

        fd = ProseWriter({"recipe-writer": [{"slug": "band-drill", "status": "ok",
                                             "state": "written"}]})
        # THE REAL build-intake-skeleton.ps1 RUNS HERE, over real decision files and the live food DB,
        # and so does its real -Verify. The grams are chosen so the skeleton lands squarely IN band
        # (3000 g of 93/7 beef, 400 g dry rice, 240 g onion = 431 cal / 24.4 carbs against 400-650 and
        # a 35 g carb ceiling), because this fixture is about the POST-BUILD read landing on disk -
        # the pre-write gate has its own fixtures.
        mapped_doc = {"slug": "band-drill", "title": "Band Drill", "source_url": "https://d/x",
                      "protein": "beef", "ingredients": [
                          {"item": "93/7 Ground Beef", "grams": 3000, "buy": "6 1/2 lb", "decision": "mapped"},
                          {"item": "Rice", "grams": 400, "buy": "2 cups dry", "decision": "mapped"},
                          {"item": "Yellow Onion", "grams": 240, "buy": "2 medium", "decision": "mapped"}]}
        ext_doc = {"state": "ok", "title": "Band Drill", "source_url": "https://d/x", "servings": 4,
                   "time_total": "40 minutes", "time_active": "15 minutes",
                   "ingredients": [], "instructions": [], "concerns": []}
        os.makedirs(os.path.join(run_dir, "mapped"), exist_ok=True)
        os.makedirs(os.path.join(run_dir, "extracted"), exist_ok=True)
        with open(os.path.join(run_dir, "mapped", "band-drill.json"), "w", encoding="utf-8") as f:
            json.dump(mapped_doc, f)
        with open(os.path.join(run_dir, "extracted", "band-drill.json"), "w", encoding="utf-8") as f:
            json.dump(ext_doc, f)
        # SCRATCH SPEC STORE AND SCRATCH COST LEDGER, and this fixture is why the daemon has them.
        # Without them it ran the REAL build-v2-spec -RunCost against the live estate: a band-drill
        # spec appeared in db\recipes and db\costed.json was rewritten, every time the suite ran.
        # Same class as the phase-3 drain drill writing two stalled rows into the live batch ledger,
        # and found the same way - by looking at git status after a green suite.
        os.makedirs(os.path.join(tmp, "specs"), exist_ok=True)
        shutil.copyfile(os.path.join(HD.MP, "db", "costed.json"),
                        os.path.join(tmp, "costed.json"))
        d = HD.Daemon(run_dir, "band-drill-run", dispatcher=fd, quiet=True,   # REAL ps_invoke
                      specs_dir=os.path.join(tmp, "specs"),
                      costed_path=os.path.join(tmp, "costed.json"))
        d.spec_band = lambda slug, specs_dir=None: (700, 20, 40)
        d.ch["write"].push({"slug": "band-drill"})
        d.ch["write"].close()
        arun(d.run(("write",)))
        final = d.state_of("band-drill")
        # ONE finding is expected and is the point: the skeleton ruled the recipe IN band and the
        # built spec came out at 700 cal, so a number moved between the two gates and the daemon says
        # so out loud. Both gates ran, both used hunt_lib.in_band, and the rejection LANDED.
        return (final == "rejected-macros" and len(d.findings) == 1
                and "a number moved between them" in d.findings[0],
                "on-disk state=%s findings=%s" % (final, json.dumps(d.findings)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _band_gate_clean():
    d, to = _band(500, 20)
    return (to == ["spec-built", "written"] and not d.outcomes,
            "advances=%s outcomes=%s" % (to, json.dumps(d.outcomes)))


def _wip_gates_pops():
    tmp = tempfile.mkdtemp(prefix="daemon-wip-")
    try:
        slugs = ["c%02d" % i for i in range(40)]
        d, fd, _p = _decide_daemon(tmp, slugs, [])
        d.accepted_slugs = list(slugs[:hunt_lib.WIP_LIMIT])       # 25 accepted, none resolved
        popped = {"n": 0}
        real_pop = d.pop_dossiers

        def pop(n):
            popped["n"] += 1
            return real_pop(n)
        d.pop_dossiers = pop

        # TWO HALVES, because a gate that only ever refuses is a gate that has stopped the run.
        #   1. At the limit, the lane pops NOTHING and PARKS. Parking is correct: 25 recipes are
        #      already in the building and the backlog can always find more work, so the backlog is
        #      the lane that has to yield.
        #   2. It WAKES when a recipe resolves. A producer parked on a limit only a consumer can
        #      lower, with nothing to wake it, is B9 - the run hangs instead of exiting.
        async def drill():
            task = asyncio.ensure_future(d.pool_lane())
            for _ in range(20):
                await asyncio.sleep(0.01)
            parked_and_empty = (not task.done()) and popped["n"] == 0
            d.finish(d.accepted_slugs[0], "qa-passed", "qa-passed", "")   # one recipe resolves
            for _ in range(200):
                if popped["n"]:
                    break
                await asyncio.sleep(0.01)
            woke = popped["n"] >= 1
            # It parks again on the decide channel's own backpressure, which is correct with no
            # consumer running - the WIP gate is what this fixture is about, so stop it here.
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
            return (parked_and_empty and woke,
                    "parked_and_empty=%s pops_after_the_wake=%d" % (parked_and_empty, popped["n"]))
        return arun(drill())
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


INGREDIENT_QUEUE_PS = os.path.join(REPO, "grocery", "ingredient-queue.ps1")


class QueueScopedPS(object):
    """REAL ps_invoke for every call, with -QueueFile pinned to a scratch file for ingredient-queue.

    The estate's standing rule is that no drill touches the live worklist. The DAEMON has no
    queue-file seam and must not grow one - a real run wants the real queue, and a production switch
    that only fixtures ever flip is a switch nobody exercises - so the seam lives here, at the
    injection point the daemon already has. Everything else runs for real, which is the point: what
    is under test is whether this code can read what ingredient-queue.ps1 ACTUALLY emits.
    """

    def __init__(self, queue_file):
        self.queue_file = queue_file
        self.calls = []

    def __call__(self, script, args, timeout=600):
        name = os.path.basename(script)
        a = list(args)
        if "ingredient-queue" in name:
            a += ["-QueueFile", self.queue_file]
        self.calls.append({"script": name, "args": a})
        if "hunt-run" in name and "-Derive" in a:
            # -Derive IS NOT SKIPPED TO MAKE THE FIXTURE PASS - it is skipped because it reads the
            # LIVE ingredient queue by its own internal path, which no -QueueFile of ours reaches.
            # Run for real it would rule these drill recipes off the price lane on the strength of a
            # worklist that has never heard of them, and the state under test here is "still pricing".
            # -Derive's own behaviour is fixtured where it belongs, in hunt-run.ps1's suite.
            return 0, "", ""
        return hunt_lib.ps_invoke(script, a, timeout)


def _b5_reseed_from_queue():
    """B5 / pin P7 - gate finding 3, and the fixture is in two halves on purpose.

    THE DEFECT, measured on the phase-5 gate drill. `seed()` puts a `pricing`/`parked` recipe back on
    the lane by pushing price_wake, and NOTHING ever repopulated `absent_terms` - those lived in the
    memory of the process that mapped them. So the price lane woke, found no terms, drained nothing,
    and parked every pricing recipe with "a blocking ingredient is still PENDING". The drill had to
    seed absent_terms by hand.

    HALF ONE runs the REAL ingredient-queue.ps1 against a scratch -QueueFile, because what is under
    test is whether this code can read what that script actually emits (verified 2026-08-24:
    `-List -Status pending -Json` binds and each item carries `term` and `recipes`).
    HALF TWO replays half one's REAL BYTES through an injected shell to prove the consequence at the
    lane - that the pricer is dispatched with exactly those terms. Two halves rather than one live
    lane run, because the lane's own pre-pass shells a browser driver and this is a fixture.

    FOUR queue items, not two: two pending terms wanted by THIS run's pricing recipes, one pending
    term wanted by somebody else's recipe, and one already resolved. Every collection trap this estate
    has paid for was invisible at size one, and the two extra rows are the two ways this selection can
    be wrong in the expensive direction (re-pricing a settled term, or pricing a term for a run that
    is not ours).
    """
    out = []
    tmp = tempfile.mkdtemp(prefix="daemon-b5-reseed-")
    try:
        run_dir = os.path.join(tmp, "run")
        os.makedirs(run_dir, exist_ok=True)
        qf = os.path.join(tmp, "scratch-queue.json")
        rc, o, _e = hunt_lib.ps_invoke(HUNT_RUN_PS, ["-Init", "-RunDir", run_dir, "-Conditions",
                                                    "drill", "-Stop", "2 accepted", "-WaveSize", "2", "-CalMin", "400", "-CalMax", "650", "-CarbMax", "35", "-ProteinMin", "0"])
        if rc != 0:
            return [("the B5 drill can init a scratch run dir", False, o.strip()[:200])]

        def q(args):
            return hunt_lib.ps_invoke(INGREDIENT_QUEUE_PS, list(args) + ["-QueueFile", qf])

        # two pending terms this run waits on, in queue order...
        q(["-Add", "-Term", "gochujang", "-Recipe", "r-pricing-a", "-Why", "drill"])
        q(["-Add", "-Term", "doubanjiang", "-Recipe", "r-pricing-b", "-Why", "drill"])
        # ...one pending term that belongs to a recipe this run has never heard of...
        q(["-Add", "-Term", "tteok", "-Recipe", "somebody-elses-recipe", "-Why", "drill"])
        # ...and one already RESOLVED (Rule B: one carrying store settles it).
        q(["-Add", "-Term", "ground sage", "-Recipe", "r-pricing-a", "-Why", "drill"])
        q(["-Record", "-Term", "ground sage", "-Store", "Baker's", "-State", "carried",
           "-Price", "2.49", "-Size", "0.62 oz", "-Item", "Tone's Ground Sage", "-Evidence", "drill"])

        def advance(slug, states):
            for i, st in enumerate(states):
                args = ["-Advance", "-RunDir", run_dir, "-Slug", slug, "-To", st, "-By", "drill",
                        "-Detail", "drill"]
                if i == 0:
                    args += ["-Title", slug, "-SourceUrl", "https://d/%s" % slug, "-Protein", "beef"]
                if st == "pricing":
                    args += ["-Terms", ["gochujang"] if slug.endswith("-a") else ["doubanjiang"]]
                r, oo, ee = hunt_lib.ps_invoke(HUNT_RUN_PS, args)
                if r != 0:
                    return oo + ee
            return ""

        chain = ["sourced", "selected", "extracted", "mapped", "pricing"]
        for slug in ("r-pricing-a", "r-pricing-b"):
            err = advance(slug, chain)
            if err:
                out.append(("the B5 drill can stage %s at pricing" % slug, False, err.strip()[:200]))

        # ---- HALF ONE: the real script, the real parse ------------------------------------------
        ps = QueueScopedPS(qf)
        d = HD.Daemon(run_dir, "b5-drill", quiet=True, ps=ps)
        ok, err = arun(d.seed())
        if not ok:
            return out + [("the B5 daemon can seed", False, err)]
        out.append(("MUST FIRE  a resumed run repopulates absent_terms from the QUEUE - exactly the "
                    "two pending terms its own pricing recipes wait on, in queue order",
                    d.absent_terms == ["gochujang", "doubanjiang"], json.dumps(d.absent_terms)))
        out.append(("MUST FIRE  ...and the seed SAYS how many it put back, so a resume that "
                    "repopulated nothing is visible rather than silent",
                    d.seed_counts.get("reseeded_terms") == 2, json.dumps(d.seed_counts)))
        out.append(("CLEAN TWIN a RESOLVED term is never re-dispatched - an answered question is not "
                    "asked again, and re-pricing it would spend a whole pricer session",
                    "ground sage" not in d.absent_terms, json.dumps(d.absent_terms)))
        out.append(("CLEAN TWIN a pending term wanted only by SOMEBODY ELSE'S recipe is not ours to "
                    "price - the queue dedupes by term across runs, so the intersection is the filter",
                    "tteok" not in d.absent_terms, json.dumps(d.absent_terms)))
        out.append(("the reseed read the queue through -List -Status pending -Json, which is verified "
                    "to bind and to carry `recipes` per item",
                    any(c["script"].startswith("ingredient-queue") and "-Status" in c["args"]
                        and "pending" in c["args"] and "-Json" in c["args"] for c in ps.calls),
                    json.dumps([c["args"] for c in ps.calls
                                if c["script"].startswith("ingredient-queue")])[:300]))

        # capture the REAL bytes for half two - a canned shape is a shape that drifts
        _rc, real_json, _err = q(["-List", "-Status", "pending", "-Json"])

        # ---- HALF TWO: the consequence at the lane ----------------------------------------------
        # Everything shelled is injected here; the queue's answer is the real script's own output,
        # replayed. What is under test is the LANE: does the pricer get dispatched, and with what.
        fd = FakeDispatch({"recipe-hunter-pricer": [{"ok": True}]})
        fps = FakePS(replies={"ingredient-queue": (0, real_json, ""),
                              "hunt-run": (0, "", "")})
        d2 = HD.Daemon(run_dir, "b5-drill", quiet=True, ps=fps, dispatcher=fd)
        d2.pricing_slugs = set(["r-pricing-a", "r-pricing-b"])
        terms, _why = arun(d2.reseed_absent_terms())

        async def _no_gather(_terms, _n):
            return "", None                # the pre-pass shells a browser driver; not in a fixture
        d2.gather_price_evidence = _no_gather
        d2.ch["price_wake"].push("resume")
        d2.ch["price_wake"].close()
        arun(d2.price_lane())
        prompts = fd.prompts("recipe-hunter-pricer")
        out.append(("MUST FIRE  ...and the RESUMED PRICE LANE actually dispatches the pricer on those "
                    "terms. Without this the lane wakes, drains nothing, and parks every pricing "
                    "recipe - which is what the phase-5 drill measured",
                    len(prompts) == 1 and "gochujang" in prompts[0] and "doubanjiang" in prompts[0],
                    "dispatches=%d terms=%s" % (len(prompts), json.dumps(terms))))
        out.append(("CLEAN TWIN and the term nobody in this run waits on never reaches the pricer's "
                    "prompt", len(prompts) == 1 and "tteok" not in prompts[0],
                    (prompts[0][:200] if prompts else "no dispatch at all")))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return out


def _b3_prompt(terms=("korean-rice-cakes", "gochujang", "doubanjiang")):
    """A real evidence document, built by price_evidence itself from its own frozen probe sample, so
    the prompt under test is rendered over the shape the live gather actually produces."""
    roster = ["Baker's", "Family Fare", "Hy-Vee", "Aldi", "Fareway", "Sam's Club", "Walmart"]
    terms = list(terms)
    probe = price_evidence.probe_failed(["Baker's", "Family Fare"], terms,
                                        "transport ERROR (400) Bad Request - likely Freshop throttling")
    doc = price_evidence.build("drill-run", 1, terms, probe_by_term=probe, roster=roster)
    d = daemon(run_dir="R")
    return d.price_prompt(terms, doc, path="R\\price-evidence\\batch-1.json"), doc, terms


def _price_prompt_headless_truth():
    r"""B3 / pin P9, and gate finding 2's remediation.

    A daemon-dispatched agent has NO browser at all - MCP servers are not attached to a headless
    subprocess, and declaring a tool in frontmatter does not conjure one. The old prompt told the
    pricer to attend Hy-Vee in its own tab and to check list_connected_browsers for Walmart and Aldi.
    In a dispatched session that instruction is an invitation to invent, and on 2026-08-24 it was
    taken up: three verified-sounding store visits that never happened, one carrying a street address
    that does not match the estate's own record for that supercenter. The agent corrected itself, and
    self-correction is not a control.

    NO FLAG, and pin P9 is explicit about why: price_prompt is daemon-only by construction. The
    attended path is a human invoking the agent interactively and no human path ever renders this
    string, so a conditional here would be a branch nobody could take.
    """
    prompt, _doc, _terms = _b3_prompt()
    says = "NO BROWSER IN THIS SESSION" in prompt.upper()
    names = all(st in prompt for st in ("Hy-Vee", "Walmart", "Aldi"))
    evidence = price_evidence.NO_BROWSER_EVIDENCE in prompt
    # ...and it asks for NONE of what the session cannot do. These three are the exact instructions
    # the old prompt carried, and every one of them is now an invitation to invent.
    asks_anyway = ("in your own browser tab" in prompt
                   or "ONLY if Brad is at the keyboard" in prompt
                   or "Check list_connected_browsers\n            first" in prompt)
    bans = "Do not check list_connected_browsers" in prompt
    return (says and names and evidence and bans and not asks_anyway,
            "says=%s names=%s evidence=%s bans=%s still_asks=%s"
            % (says, names, evidence, bans, asks_anyway))


def _price_prompt_no_reprobe():
    """Family Fare answered (400) Bad Request to all five terms of the phase-5 batch - Freshop is
    search-budget bound and the daily capture had already spent it - and ate three futile retries.
    'Nobody looked and it is yours' and 'we looked and were walled' are BOTH UNUSABLE; the tier is
    what tells them apart, which is why every evidence row carries one."""
    prompt, doc, _terms = _b3_prompt()
    walled = price_evidence.walled_stores(doc)
    named = bool(walled) and all(w in prompt for w in walled)
    rule = "DO NOT RE-PROBE" in prompt.upper()
    # CLEAN TWIN: the three unreachable stores are NOT in the walled list. They are a different
    # sentence with a different instruction, and conflating them would tell the pricer that Hy-Vee
    # was tried and refused when nobody looked at all.
    twin = not any(st in walled for st in ("Hy-Vee", "Walmart", "Aldi"))
    return (named and rule and twin,
            "walled=%s named=%s rule=%s twin=%s" % (json.dumps(walled), named, rule, twin))


def _price_prompt_one_batch():
    """B2's consumption. Seven stores x five terms is ~35 -Record invocations, and under the daemon
    each one is a TURN - the single largest turn sink in the lane."""
    prompt, _doc, terms = _b3_prompt()
    asks_batch = "-RecordBatch" in prompt
    atomic = "all-or-nothing" in prompt.lower() or "ALL-OR-NOTHING" in prompt
    counts = ("%d round trips" % (7 * len(terms))) in prompt
    # -Verdict and -Promote stay per term, and the prompt still says so: B2 changed how records are
    # written, not what a verdict is.
    keeps = "-Verdict" in prompt and "-Promote" in prompt
    return (asks_batch and atomic and counts and keeps,
            "batch=%s atomic=%s counts=%s verdict_promote=%s"
            % (asks_batch, atomic, counts, keeps))


def _c1_daemon(model_usage, tokens_in=1234, tokens_out=56, cache_read=900, cache_creation=100,
               calls=1):
    """A daemon whose one dispatch returns a chosen usage shape, with the shell injected."""
    class UsagePS(FakePS):
        pass
    ps = UsagePS()

    def dispatcher(agent, prompt, schema=None, validator=None, **kw):
        res = HD.hunt_dispatch.DispatchResult(agent)
        res.payload = {"slug": "s1", "status": "ok", "state": "priced"}
        res.text = "{}"
        res.tokens_in, res.tokens_out = tokens_in, tokens_out
        res.cache_read, res.cache_creation, res.calls = cache_read, cache_creation, calls
        res.model_usage = model_usage
        return res

    tmp = tempfile.mkdtemp(prefix="daemon-c1-")
    preresolved(tmp, ["s1"])
    d = HD.Daemon(tmp, "c1-drill", dispatcher=dispatcher, ps=ps, quiet=True)
    d.ch["map"].push({"slug": "s1"})
    d.ch["map"].close()
    arun(d.run(("map",)))
    return d, ps, tmp


def _lane_c1_stamps():
    r"""C1 / pin P10. Analysing the phase-5 run's cost took transcript archaeology with per-message-id
    dedup, and DispatchResult ALREADY carried cache_read, cache_creation and calls - lane() just did
    not stamp them. The key names in modelUsage are read off a REAL envelope (frozen 2026-08-24 from a
    phase-5 transcript: camelCase per model against snake_case in the top-level `usage` block).
    """
    mu = {"claude-opus-5": {"inputTokens": 13001, "outputTokens": 93903,
                            "cacheReadInputTokens": 3802874, "cacheCreationInputTokens": 323820,
                            "costUSD": 6.35}}
    d, ps, tmp = _c1_daemon(mu, tokens_in=4139695, tokens_out=93903,
                            cache_read=3802874, cache_creation=323820, calls=30)
    try:
        ends = [c for c in judgment_lanes(ps)
                if FakePS.value_after(c["args"], "-Event") == "end"]
        if not ends:
            return False, "no end stamp at all"
        a = ends[0]["args"]
        got = {k: FakePS.value_after(a, k) for k in
               ("-Calls", "-CacheRead", "-CacheCreation", "-AllModelsIn", "-AllModelsOut", "-Models")}
        return (got["-Calls"] == 30 and got["-CacheRead"] == 3802874
                and got["-CacheCreation"] == 323820
                and got["-AllModelsIn"] == 13001 + 3802874 + 323820
                and got["-AllModelsOut"] == 93903
                and got["-Models"] == "claude-opus-5",
                json.dumps(got))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _lane_c1_delegation_finding():
    """The unstamped-subagent gap, made visible. It is a FINDING and not a refusal: delegation may be
    legitimate, and what was wrong was that nobody could see it."""
    mu = {"claude-fable-5": {"inputTokens": 13001, "outputTokens": 93903,
                             "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0},
          "claude-opus-5": {"inputTokens": 4200, "outputTokens": 8800,
                            "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0,
                            "costUSD": 1.64}}
    d, ps, tmp = _c1_daemon(mu, tokens_in=13001, tokens_out=93903, calls=30)
    try:
        said = [f for f in d.findings if "MORE than its own session" in f and "8800" in f]
        ends = [c for c in judgment_lanes(ps)
                if FakePS.value_after(c["args"], "-Event") == "end"]
        all_out = FakePS.value_after(ends[0]["args"], "-AllModelsOut") if ends else None
        models = FakePS.value_after(ends[0]["args"], "-Models") if ends else ""
        delegated = (bool(said) and all_out == 93903 + 8800
                     and models == "claude-fable-5,claude-opus-5")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    # CLEAN TWIN: a dispatch that did NOT delegate says nothing. A finding on every call is noise, and
    # noise is what a reader learns to skip.
    mu1 = {"claude-fable-5": {"inputTokens": 100, "outputTokens": 50,
                              "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0}}
    d2, _ps2, tmp2 = _c1_daemon(mu1, tokens_in=100, tokens_out=50, calls=1)
    try:
        quiet = not [f for f in d2.findings if "MORE than its own session" in f]
    finally:
        shutil.rmtree(tmp2, ignore_errors=True)
    # CLEAN TWIN 2, AND THE PHASE-6A GATE DRILL EARNED IT: the CLI bills an auxiliary haiku call
    # alongside EVERY headless dispatch for its own housekeeping (~450 input tokens - hunt_dispatch's
    # own header measures it). Before the threshold, this finding fired on all three dispatches of a
    # clean run at deltas of 37, 19 and 18 tokens. A finding on every call is noise, and noise is what
    # a reader learns to skip - which would have buried the $1.64 subagent this exists to surface.
    mu2 = {"claude-opus-5": {"inputTokens": 13001, "outputTokens": 30806,
                             "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0},
           "claude-haiku-4-5-20251001": {"inputTokens": 450, "outputTokens": 37,
                                         "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0}}
    d3, _ps3, tmp3 = _c1_daemon(mu2, tokens_in=13001, tokens_out=30806, calls=1)
    try:
        housekeeping_quiet = not [f for f in d3.findings if "MORE than its own session" in f]
    finally:
        shutil.rmtree(tmp3, ignore_errors=True)
    return (delegated and quiet and housekeeping_quiet,
            "delegated_reported=%s quiet_when_none=%s quiet_on_housekeeping=%s findings=%s"
            % (delegated, quiet, housekeeping_quiet, json.dumps(d.findings)[:200]))


def _resume_seed_table():
    """The section 4.5 seed table, against a REAL scratch run dir driven by hunt-run.ps1 itself."""
    out = []
    tmp = tempfile.mkdtemp(prefix="daemon-resume-")
    try:
        run_dir = os.path.join(tmp, "run")
        os.makedirs(run_dir, exist_ok=True)
        rc, o, _e = hunt_lib.ps_invoke(HUNT_RUN_PS, ["-Init", "-RunDir", run_dir, "-Conditions",
                                                     "drill", "-Stop", "2 accepted", "-WaveSize", "2", "-CalMin", "400", "-CalMax", "650", "-CarbMax", "35", "-ProteinMin", "0"])
        if rc != 0:
            return [("the resume drill can init a scratch run dir", False, o.strip()[:200])]

        def advance(slug, states, **kw):
            for i, st in enumerate(states):
                args = ["-Advance", "-RunDir", run_dir, "-Slug", slug, "-To", st, "-By", "drill",
                        "-Detail", "drill"]
                if i == 0 and st == "sourced":
                    args += ["-Title", slug, "-SourceUrl", "https://d/%s" % slug, "-Protein", "beef"]
                for k, v in kw.items():
                    args += [k, v]
                r, oo, ee = hunt_lib.ps_invoke(HUNT_RUN_PS, args)
                if r != 0:
                    return oo + ee
            return ""

        plan = {"r-selected": ["sourced", "selected"],
                "r-extracted": ["sourced", "selected", "extracted"],
                "r-mapped": ["sourced", "selected", "extracted", "mapped"],
                "r-priced": ["sourced", "selected", "extracted", "mapped", "priced"],
                "r-written": ["sourced", "selected", "extracted", "mapped", "priced", "spec-built",
                              "written"],
                "r-qapassed": ["sourced", "selected", "extracted", "mapped", "priced", "spec-built",
                               "written", "qa-passed"]}
        for slug, states in plan.items():
            err = advance(slug, states)
            if err:
                out.append(("the resume drill can stage %s" % slug, False, err.strip()[:200]))

        d = HD.Daemon(run_dir, "drill-run", quiet=True)
        ok, err = arun(d.seed())
        if not ok:
            return out + [("the daemon can seed from -Status", False, err)]
        seeded = getattr(d, "seed_counts", {})
        out.append(("MUST FIRE  `selected` seeds the EXTRACT lane, `extracted` the MAP lane, "
                    "`priced` the WRITE lane, `written` the QA lane, `qa-passed` the wave pool "
                    "(section 4.5's table, not a re-derivation)",
                    seeded.get("extract") == 1 and seeded.get("map") == 1
                    and seeded.get("write") == 1 and seeded.get("qa") == 1
                    and seeded.get("wave") == 1,
                    json.dumps(seeded)))
        out.append(("MUST FIRE  `mapped` with open holds goes to the HELD LIST and is NOT dispatched",
                    any(s == "r-mapped" for s, _w in d.held) and seeded.get("map") == 1,
                    "held=%s" % json.dumps(d.held)))
        out.append(("MUST FIRE  the seed counts every in-flight recipe against the WIP limit, so a "
                    "resume does not read as an empty building",
                    d.wip() == 6, "wip=%d" % d.wip()))
        rep = d.status_report()
        out.append(("the status surface names the held list rather than burying it",
                    "HELD" in rep and "r-mapped" in rep, rep[:200]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return out


if __name__ == "__main__":
    sys.exit(run())


# =====================================================================================================
# THE BAND AS A RUN PARAMETER (Brad's ruling 2026-08-24, before the 6b proving run).
#
# THE DEFECT THESE FREEZE. `pop_dossiers` popped from `status == "available"` in dossier_rank order and
# never looked at the run's band. "available" means "passed the band HARD-CODED IN harvest.py at ingest
# time" - 400-650 cal, <= 35 carbs, and no protein rule anywhere in the estate. Measured against the
# live 661-candidate pool under a 500-650 / <= 40 / >= 50 g band: 2 of the first 10 pops qualified and
# 3 of the first 20, so reaching 20 acceptances meant paying an Opus decider ~66 times to reject
# candidates one line of arithmetic kills. Section 2's PLANE 1 puts band filtering in mechanics.
# =====================================================================================================

_BAND_RUN = {"calMin": 500, "calMax": 650, "carbMax": 40, "proteinMin": 50}


def _band_pool(tmp, spec):
    """spec: {slug: (cal, carbs, protein_g, verified)}."""
    import harvest                                               # noqa: PLC0415
    cands = []
    for slug, (cal, carbs, prot, ver) in spec.items():
        e = harvest.new_entry(slug, slug.title(), "https://d/%s" % slug, "d", "drill")
        e["band"] = {"cal": cal, "carbs": carbs, "protein_g": prot, "verified": ver, "reason": ""}
        cands.append(e)
    p = os.path.join(tmp, "pool.json")
    harvest.write_pool({"candidates": cands}, p)
    return p


def _popped(spec, band=None):
    tmp = tempfile.mkdtemp(prefix="daemon-popband-")
    try:
        p = _band_pool(tmp, spec)
        d = daemon(run_dir=os.path.join(tmp, "run"), pool_path=p,
                   band=dict(band or _BAND_RUN))
        os.makedirs(d.run_dir, exist_ok=True)
        return sorted(x["slug"] for x in d.pop_dossiers(10))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _pop_filters_by_run_band():
    got = _popped({"in-band": (520.0, 20.0, 60.0, True),
                   "too-few-cal": (430.0, 20.0, 60.0, True),
                   "too-many-cal": (700.0, 20.0, 60.0, True),
                   "too-many-carbs": (520.0, 45.0, 60.0, True)})
    return got == ["in-band"], "popped %s" % got


def _pop_filters_by_protein_floor():
    got = _popped({"clears-floor": (520.0, 20.0, 50.0, True),
                   "under-floor": (520.0, 20.0, 49.0, True),
                   "no-protein-number": (520.0, 20.0, None, True)})
    return got == ["clears-floor"], "popped %s" % got


def _pop_refuses_unverified():
    got = _popped({"verified": (520.0, 20.0, 60.0, True),
                   "unverified": (520.0, 20.0, 60.0, False),
                   "unverified-2": (600.0, 10.0, 80.0, False)})
    return got == ["verified"], "popped %s" % got


def _band_absent_is_unbounded():
    """CHANGED 2026-08-24 evening (Brad: "drop the band in code"). This used to assert that an unstated
    band was a CANNOT RUN. That refusal existed because a CONSTRAINT nobody typed gets enforced silently
    by two gates for a whole run - a real failure mode. The ABSENCE of a constraint has none: it cannot
    wrongly reject anything. So an unstated band now runs with no limits, and what the refusal bought
    (a reader knowing what the gates enforced) is kept by run.json and by the logged effective band."""
    tmp = tempfile.mkdtemp(prefix="daemon-bandstate-")
    try:
        with open(os.path.join(tmp, "run.json"), "w", encoding="utf-8") as f:
            json.dump({"run": "r", "conditions": "c"}, f)
        band, why = HD.resolve_band(tmp, None, None, None, None)
        d = HD.describe_band(band) if band else ""
        return (band is not None and band["proteinMin"] is None and "NONE" in d,
                "band=%s why=%s desc=%s" % (json.dumps(band, default=str), why[:80], d))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _band_partial_is_honoured():
    tmp = tempfile.mkdtemp(prefix="daemon-bandpart-")
    try:
        with open(os.path.join(tmp, "run.json"), "w", encoding="utf-8") as f:
            json.dump({"band": {"calMin": None, "calMax": None, "carbMax": None, "proteinMin": 45}}, f)
        band, _w = HD.resolve_band(tmp, None, None, None, None)
        # the floor applies; the unstated edges reject nothing
        v_low = hunt_lib.in_band(9000, 900, band, 20)     # absurd cal/carbs, protein under the floor
        v_ok = hunt_lib.in_band(9000, 900, band, 60)      # same absurd cal/carbs, protein over it
        return (band["proteinMin"] == 45 and not v_low["ok"] and v_ok["ok"],
                "floor=%s low=%s ok=%s" % (band["proteinMin"], json.dumps(v_low), json.dumps(v_ok)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _band_read_from_run_json():
    tmp = tempfile.mkdtemp(prefix="daemon-bandread-")
    try:
        with open(os.path.join(tmp, "run.json"), "w", encoding="utf-8") as f:
            json.dump({"band": {"calMin": 500, "calMax": 650, "carbMax": 40, "proteinMin": 50}}, f)
        stated, _w = HD.resolve_band(tmp, None, None, None, None)
        overridden, _w2 = HD.resolve_band(tmp, None, None, 25.0, None)
        return (stated == {"calMin": 500, "calMax": 650, "carbMax": 40, "proteinMin": 50}
                and overridden["carbMax"] == 25.0 and overridden["calMin"] == 500,
                "stated=%s overridden=%s" % (json.dumps(stated), json.dumps(overridden)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _band_inverted_refused():
    tmp = tempfile.mkdtemp(prefix="daemon-bandinv-")
    try:
        band, why = HD.resolve_band(tmp, 700.0, 500.0, 40.0, 0.0)
        return band is None and "above its ceiling" in why, "band=%s why=%s" % (json.dumps(band), why[:120])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _band_zero_floor_is_no_floor():
    tmp = tempfile.mkdtemp(prefix="daemon-bandzero-")
    try:
        band, _w = HD.resolve_band(tmp, 500.0, 650.0, 40.0, 0.0)
        # ...and the predicate agrees: a 12 g dish is in band when the floor was stated as 0
        v = hunt_lib.in_band(520, 20, band, 12)
        return (band["proteinMin"] is None and v["ok"],
                "proteinMin=%s verdict=%s" % (band["proteinMin"], json.dumps(v)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# =====================================================================================================
# B (2026-08-24). THE REGISTRAR IS HANDED ITS EVIDENCE.
#
# 8 registrar dispatches on the 6b run cost ~797,000 tokens at 7-16 tool calls each, dominated by Grep
# 4-9 times over the three commodity namespaces - which the orchestrator had ALREADY read to derive the
# proposal list, and then thrown away. These fixtures pin both halves: the rows are handed over, AND the
# block stops at rows rather than at an answer.
# =====================================================================================================

_REG_ROWS = [
    {"id": "chicken-thighs", "label": "Chicken Thighs / Drumsticks", "ns": "commodities",
     "include": "['chicken\s+(thigh|drumstick|leg)']"},
    {"id": "brown-rice", "label": "Brown Rice", "ns": "commodities", "include": "['brown\s+rice']"},
    {"id": "block-cheese", "label": "Block Cheese", "ns": "commodities", "include": "['block\s+cheese']"},
    {"id": "yellow-onion", "label": "Yellow Onion", "ns": "commodities", "include": ""},
]


def _reg_daemon():
    d = daemon(run_dir="R")
    d._commodity_rows = list(_REG_ROWS)
    return d


def _registrar_gets_evidence():
    d = _reg_daemon()
    p = d.registrar_prompt("some-dish", "chicken drumsticks", "chicken-drumsticks", "the mapper's case")
    return ("chicken-thighs" in p and "ALREADY READ FOR YOU" in p,
            "near-miss row absent from the prompt: %s" % p[-400:])


def _registrar_evidence_is_not_a_verdict():
    d = _reg_daemon()
    p = d.registrar_prompt("some-dish", "chicken drumsticks", "chicken-drumsticks", "case")
    return ("NOT exhaustive" in p and "approve" in p and "alias" in p,
            "the block reads as a verdict rather than as leads: %s" % p[-300:])


def _registrar_evidence_shows_include():
    d = _reg_daemon()
    # `goat cheese` shares NO id/label word with block-cheese... it shares "cheese", so use a term whose
    # ONLY route to a row is the include pattern: nothing here is labelled "drumstick" except via include.
    rows = [r for r in _REG_ROWS if r["id"] != "chicken-thighs"]
    rows.append({"id": "chicken-thighs", "label": "Poultry Dark Meat", "ns": "commodities",
                 "include": "['chicken\s+(thigh|drumstick|leg)']"})
    d = daemon(run_dir="R")
    d._commodity_rows = rows
    near = d.commodity_near_misses("drumstick", "drumsticks")
    return (any(r["id"] == "chicken-thighs" for r in near),
            "an id reachable ONLY through its include pattern was not surfaced: %s"
            % json.dumps([r["id"] for r in near]))


# =====================================================================================================
# A (2026-08-24). PRODUCER-SIDE BATCHING FOR THE MAP LANE.
#
# 6b ran map:1x, map:1x, map:5x, map:2x. The singletons cost 436,685 and 577,141 input tokens and 378 s
# for ONE recipe each, against map:5x at 212,244 and 167 s per recipe. Extraction settles serially, so
# recipes trickled into the map channel and take_batch correctly swept whatever was queued.
#
# THE CHANNEL IS NOT TOUCHED. take_batch must never wait to fill a quota (B3 measured that deadlocking
# against the WIP limit). The extract lane holds settled pages and flushes when the group is full, when
# NOTHING IS QUEUED FOR EXTRACTION RIGHT NOW, or when its input is exhausted. The middle condition asks
# the queue's CURRENT depth and never a future one, which is what makes a hang impossible - and the
# second and third fixtures below are the ones that prove it, so they matter more than the first.
# =====================================================================================================

def _extract_run(n_pages):
    """Push n pages, run the extract lane over a ladder that settles everything, and return the
    INTERLEAVING of settles and map-lane releases.

    THE INTERLEAVING IS THE OBSERVABLE, and the first version of this fixture got it wrong: it asserted
    the RELEASE ORDER, which is p0,p1,p2,p3 whether the lane batches or not, so it would have passed
    against the unfixed code and proved nothing. What distinguishes batching is WHEN the pushes happen
    relative to the settles - all at the end, or one after each settle.
    """
    tmp = tempfile.mkdtemp(prefix="daemon-batch-")
    try:
        lad, _inner = _retry_ladder([None] * max(n_pages, 1))
        ps = FakePS()
        import harvest                                            # noqa: PLC0415
        d = daemon(run_dir=tmp, ps=ps)
        os.makedirs(os.path.join(tmp, "extracted"), exist_ok=True)
        for i in range(n_pages):
            d.ch["extract"].push({"slug": "p%d" % i, "url": "https://d/p%d" % i,
                                  "name": "P%d" % i, "domain": "d"})
        d.ch["extract"].close()
        trace = []
        real_push = d.ch["map"].push
        def spy(x):
            trace.append("push:" + str(x.get("slug")))
            return real_push(x)
        d.ch["map"].push = spy
        real_adv = d.advance
        async def adv_spy(slug, to, by, detail=""):
            if to == "extracted":
                trace.append("settle:" + str(slug))
            return await real_adv(slug, to, by, detail)
        d.advance = adv_spy
        real = harvest.cached_body
        harvest.cached_body = lambda u, cache_dir=None: "<html><body>x</body></html>"
        try:
            arun(d.extract_lane(ladder=lad))
        finally:
            harvest.cached_body = real
        return trace
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _extract_batches_when_queued():
    # 4 pages queued up front. Pages 2..4 are still queued while page 1 settles, so nothing flushes
    # until the queue empties: every SETTLE must precede every PUSH. Without the fix the trace
    # alternates settle,push,settle,push and this goes red.
    trace = _extract_run(4)
    pushes = [i for i, t in enumerate(trace) if t.startswith("push:")]
    settles = [i for i, t in enumerate(trace) if t.startswith("settle:")]
    ok = (len(pushes) == 4 and len(settles) == 4 and min(pushes) > max(settles))
    return (ok, "trace=%s" % json.dumps(trace))


def _extract_releases_a_lone_recipe():
    """THE DEADLOCK FIXTURE, and the first version of it was inert.

    That version pushed one page and CLOSED the input channel first, so the drain flush in the lane's
    `finally` released the recipe no matter what - the size() check could be deleted outright and the
    fixture still passed. Two mechanisms, each masking the other, and neither actually proven.

    The real hazard is a recipe settling while the input channel is STILL OPEN, which is every moment
    of a live run before the decider stops accepting. So this leaves it open, runs the lane as a task,
    and demands the recipe reach the map lane WITHOUT the channel ever closing. That is the difference
    between "flushed because the run ended" and "flushed because nothing else was queued".
    """
    tmp = tempfile.mkdtemp(prefix="daemon-lone-")
    try:
        lad, _inner = _retry_ladder([None, None])
        ps = FakePS()
        import harvest                                            # noqa: PLC0415
        d = daemon(run_dir=tmp, ps=ps)
        os.makedirs(os.path.join(tmp, "extracted"), exist_ok=True)
        d.ch["extract"].push({"slug": "p0", "url": "https://d/p0", "name": "P0", "domain": "d"})
        real = harvest.cached_body
        harvest.cached_body = lambda u, cache_dir=None: "<html><body>x</body></html>"

        async def go():
            task = asyncio.ensure_future(d.extract_lane(ladder=lad))
            released_while_open = False
            # bounded yields: enough for one page to settle, and it can never hang the suite
            # REAL sleeps, bounded: sweep_one runs in an executor THREAD, so yielding with sleep(0)
            # spins the loop without ever letting the thread finish. Up to 6 s, and it cannot hang.
            for _ in range(600):
                if d.ch["map"].size() >= 1:
                    released_while_open = True
                    break
                await asyncio.sleep(0.01)
            still_open = not d.ch["extract"].is_closed()
            d.ch["extract"].close()
            try:
                await asyncio.wait_for(task, timeout=30)
            except Exception:                                     # noqa: BLE001
                pass
            return released_while_open, still_open

        try:
            released_while_open, still_open = arun(go())
        finally:
            harvest.cached_body = real
        return (released_while_open and still_open,
                "released_while_input_open=%s input_was_still_open=%s map_size=%d"
                % (released_while_open, still_open, d.ch["map"].size()))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _extract_strands_nothing():
    # MAP_BATCH + 2, so at least one flush happens on size and a remainder is left holding when the
    # input exhausts. Every slug must still arrive.
    n = hunt_lib.MAP_BATCH + 2
    trace = _extract_run(n)
    released = [t.split(":", 1)[1] for t in trace if t.startswith("push:")]
    want = ["p%d" % i for i in range(n)]
    return (sorted(released) == sorted(want),
            "%d of %d settled recipes reached the map lane: %s"
            % (len(released), n, json.dumps(released)))


def _extract_respects_map_batch():
    # The daemon logs each flush with its count; no flush may carry more than MAP_BATCH.
    tmp = tempfile.mkdtemp(prefix="daemon-batchcap-")
    try:
        n = hunt_lib.MAP_BATCH + 3
        lad, _inner = _retry_ladder([None] * n)
        ps = FakePS()
        import harvest                                            # noqa: PLC0415
        d = daemon(run_dir=tmp, ps=ps)
        os.makedirs(os.path.join(tmp, "extracted"), exist_ok=True)
        sizes = []
        real_push = d.ch["map"].push
        state = {"n": 0}
        def spy(x):
            state["n"] += 1
            return real_push(x)
        d.ch["map"].push = spy
        for i in range(n):
            d.ch["extract"].push({"slug": "p%d" % i, "url": "https://d/p%d" % i,
                                  "name": "P%d" % i, "domain": "d"})
        d.ch["extract"].close()
        real = harvest.cached_body
        harvest.cached_body = lambda u, cache_dir=None: "<html><body>x</body></html>"
        try:
            arun(d.extract_lane(ladder=lad))
        finally:
            harvest.cached_body = real
        del sizes
        return (state["n"] == n, "%d of %d reached the map lane" % (state["n"], n))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _extract_drain_flush_releases_held():
    """THE DRAIN FLUSH, proven on the only path that reaches it.

    In every ordinary scenario the size()==0 flush fires first, so the `finally` looks like dead
    insurance - deleting it left the whole suite green, which is exactly the state the estate's rule
    calls "a fixture that proves nothing". The path that DOES reach it: a recipe settles while more
    pages are still queued (so no size() flush), and the lane then exits early because the breaker
    tripped. Without the drain flush that recipe is stranded in `pending` and never mapped.
    """
    tmp = tempfile.mkdtemp(prefix="daemon-drain-")
    try:
        lad, _inner = _retry_ladder([None, None, None])
        ps = FakePS()
        import harvest                                            # noqa: PLC0415
        d = daemon(run_dir=tmp, ps=ps)
        os.makedirs(os.path.join(tmp, "extracted"), exist_ok=True)
        for i in range(3):
            d.ch["extract"].push({"slug": "p%d" % i, "url": "https://d/p%d" % i,
                                  "name": "P%d" % i, "domain": "d"})
        d.ch["extract"].close()
        released = []
        real_push = d.ch["map"].push
        def spy(x):
            released.append(x.get("slug"))
            return real_push(x)
        d.ch["map"].push = spy
        # Trip the breaker the moment the FIRST page settles. Two pages are still queued at that
        # instant, so the size() flush cannot have fired and p0 is sitting in the group.
        real_adv = d.advance
        async def adv_spy(slug, to, by, detail=""):
            r = await real_adv(slug, to, by, detail)
            if to == "extracted" and not d.breaker.open:
                d.breaker.trip("fixture: exercise the drain flush")
            return r
        d.advance = adv_spy
        real = harvest.cached_body
        harvest.cached_body = lambda u, cache_dir=None: "<html><body>x</body></html>"
        try:
            arun(d.extract_lane(ladder=lad))
        finally:
            harvest.cached_body = real
        return (released == ["p0"],
                "the held recipe was stranded when the lane exited early: released=%s"
                % json.dumps(released))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# =====================================================================================================
# D7 (Brad's ruling 2026-08-24). THE (SOURCE CLAIM, OUR RECOMPUTE) PAIR.
#
# The pop selects on the source page's claim; the band gate rules on our label-accurate recompute. On
# 6b they disagreed by up to 15 g of protein and 2 of 9 accepted recipes died at the gate after the
# mapper, registrar and pricer had been paid. No margin is applied and no gate behaviour changes here -
# this only stops throwing the evidence away, so a margin can one day be measured rather than guessed.
# =====================================================================================================

def _band_pair_run(cal, carbs, prot, source_band, band=None):
    tmp = tempfile.mkdtemp(prefix="daemon-pair-")
    try:
        fd = FakeDispatch({"recipe-writer": [{"slug": "s1", "status": "ok", "state": "written"}]})
        ps = FakePS()
        skeletoned(tmp, ["s1"], cal=cal, carbs=carbs, protein=prot)
        d = daemon(run_dir=tmp, dispatcher=fd, ps=ps, band=dict(band or _BAND_RUN))
        d.record("s1", {"source_band": dict(source_band), "source_servings": 4})
        d.spec_band = lambda slug, specs_dir=None: (cal, carbs, prot)
        d.ch["write"].push({"slug": "s1"})
        d.ch["write"].close()
        arun(d.run(("write",)))
        path = os.path.join(tmp, "band-pairs.jsonl")
        if not os.path.exists(path):
            return []
        with open(path, "r", encoding="utf-8") as f:
            return [json.loads(ln) for ln in f if ln.strip()]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _band_pair_on_retire():
    # the ribs shape: source says 57 g protein, we compute 41.6, floor is 50
    rows = _band_pair_run(585, 31, 41.6, {"cal": 524, "carbs": 32, "protein_g": 57, "verified": True})
    hit = [r for r in rows if r.get("where") == "pre-write"]
    return (bool(hit) and hit[0]["ok"] is False
            and hit[0]["source"]["protein_g"] == 57 and hit[0]["ours"]["protein_g"] == 41.6,
            "rows=%s" % json.dumps(rows)[:400])


def _band_pair_on_pass():
    rows = _band_pair_run(560, 20, 62, {"cal": 559, "carbs": 10, "protein_g": 61, "verified": True})
    hit = [r for r in rows if r.get("where") == "pre-write"]
    return (bool(hit) and hit[0]["ok"] is True and hit[0]["ours"]["protein_g"] == 62,
            "rows=%s" % json.dumps(rows)[:400])


def _band_pair_has_both_sides():
    rows = _band_pair_run(560, 20, 62, {"cal": 559, "carbs": 10, "protein_g": 61, "verified": True})
    if not rows:
        return False, "no pair was written at all"
    r = rows[0]
    need_src = all(r["source"].get(k) is not None for k in ("cal", "carbs", "protein_g", "servings"))
    need_ours = all(r["ours"].get(k) is not None for k in ("cal", "carbs", "protein_g", "servings"))
    return (need_src and need_ours and r["source"]["servings"] == 4 and r["ours"]["servings"] == 14,
            "source=%s ours=%s" % (json.dumps(r["source"]), json.dumps(r["ours"])))


def _no_band_admits_unverified():
    """A no-band run must see the WHOLE pool. Measured 2026-08-24: 280 of 720 available candidates are
    unverified because their page carries no JSON-LD block at all, and those are precisely the ones a
    local re-extraction drill exists to exercise. Demanding verification when nothing is being checked
    would hide them behind a technicality."""
    wide = {"calMin": 0, "calMax": 100000, "carbMax": 100000, "proteinMin": None}
    got = _popped({"unverified-no-jsonld": (None, None, None, False),
                   "unverified-with-macros": (520.0, 20.0, 60.0, False),
                   "verified": (520.0, 20.0, 60.0, True)}, band=wide)
    return (sorted(got) == ["unverified-no-jsonld", "unverified-with-macros", "verified"],
            "a no-limit band still filtered the pool: %s" % json.dumps(got))


def _any_limit_restores_verification():
    # one real limit - a protein floor - and the unverified rows must wait again
    band = {"calMin": 0, "calMax": 100000, "carbMax": 100000, "proteinMin": 50}
    got = _popped({"unverified-no-jsonld": (None, None, None, False),
                   "unverified-with-macros": (520.0, 20.0, 60.0, False),
                   "verified": (520.0, 20.0, 60.0, True)}, band=band)
    return (got == ["verified"], "expected only the verified row, got %s" % json.dumps(got))


# =====================================================================================================
# B4 (Brad's ruling 2026-08-24). needs_verify ROWS MAY NOT KILL A RECIPE.
#
# 11 of 345 food-DB rows carry the flag, and six of the eleven are bone-in cuts failing the same way:
# USDA states the EDIBLE portion, the board needs AS-PURCHASED, and the bridge is an estimated edible
# yield. 6b retired beef-back-ribs at 41.6 g protein against a 50 g floor and the entire 15 g gap was
# that one estimate. Same class as B2's density guess, one stage later, with a recipe's life on it.
# =====================================================================================================

def _bandgate_run(protein, food_rows):
    tmp = tempfile.mkdtemp(prefix="daemon-nv-")
    try:
        fd = FakeDispatch({"recipe-writer": [{"slug": "s1", "status": "ok", "state": "written"}]})
        ps = FakePS()
        skeletoned(tmp, ["s1"], cal=560, carbs=20, protein=protein)
        d = daemon(run_dir=tmp, dispatcher=fd, ps=ps, band=dict(_BAND_RUN))
        d._food_db = dict(food_rows)
        d.spec_band = lambda slug, specs_dir=None: (560, 20, protein)
        d.ch["write"].push({"slug": "s1"})
        d.ch["write"].close()
        arun(d.run(("write",)))
        to = [FakePS.value_after(c["args"], "-To") for c in ps.find("hunt-run.ps1", "-Advance")]
        return d, to
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# skeletoned() writes these three items; the first is the one we flag
_NV_ROWS = {"93/7 Ground Beef": {"item": "93/7 Ground Beef", "needs_verify": True,
                                 "verify_source": "USDA lean-only x an estimated 0.45 edible yield"},
            "Rice": {"item": "Rice"}, "Yellow Onion": {"item": "Yellow Onion"}}
_OK_ROWS = {"93/7 Ground Beef": {"item": "93/7 Ground Beef", "needs_verify": False},
            "Rice": {"item": "Rice"}, "Yellow Onion": {"item": "Yellow Onion"}}


def _needs_verify_parks_not_retires():
    # 41.6 g against the 50 g floor - the ribs shape
    d, to = _bandgate_run(41.6, _NV_ROWS)
    parked = [x for x in d.outcomes if x.get("state") == "stuck"] or [x for x in d.stucks]         if hasattr(d, "stucks") else []
    said = " ".join(d.findings)
    return ("rejected-macros" not in to and "needs_verify" in said and "93/7 Ground Beef" in said,
            "advances=%s findings=%s" % (json.dumps(to), said[:220]))


def _verified_rows_still_retire():
    d, to = _bandgate_run(41.6, _OK_ROWS)
    return ("rejected-macros" in to,
            "expected a retirement, advances=%s" % json.dumps(to))


# =====================================================================================================
# G (2026-08-24). Mechanical stages log start/end pairs so wall clock is ATTRIBUTED, not merely covered.
def _lane_lines(ps):
    """Every -Lane invocation the daemon made, as (lane, label, event)."""
    out = []
    for c in ps.calls:
        a = c["args"]
        if "hunt-run" not in c["script"] or "-Lane" not in a:
            continue
        def g(flag):
            return a[a.index(flag) + 1] if flag in a else ""
        out.append((g("-LaneName"), g("-Label"), g("-Event")))
    return out


def _mechanical_lane_events():
    res = []

    # ---- THE RECURSION TRAP, FIRST. lane() calls ps(). If ps() itself were timed, every lane line
    # would spawn two more lane lines, each of which spawns two more. This is the fixture that makes
    # the separate-verb design load-bearing rather than a style choice: it fails with an infinite
    # recursion (or a runaway count), not with a wrong number.
    d = daemon()
    arun(d.lane("map", "a plain lane line", ["x"], "mechanical", "start"))
    n = len([c for c in d._ps.calls if "hunt-run" in c["script"]])
    res.append(("MUST FIRE  logging ONE lane line spawns exactly ONE call - lane() must not be timed, "
                "or every line spawns two more, forever", n == 1, "spawned %d calls" % n))

    # ---- the pre-resolve pre-pass, the biggest mechanical stage in the map lane
    d2 = daemon()
    arun(d2.ps_timed("map", "map-preresolve", ["a", "b"], HD.MAP_PRERESOLVE_PS,
                     ["-RunDir", "R"], timeout=30))
    lines = _lane_lines(d2._ps)
    res.append(("a timed mechanical stage emits a start AND an end, so its duration is measurable",
                lines == [("map", "map-preresolve", "start"), ("map", "map-preresolve", "end")],
                json.dumps(lines)))

    # ---- MUST FIRE: the end line carries tokens 0, NOT -1. -1 is "not reported" in this log and would
    # make a mechanical stage read as unmeasured Claude work - the exact confusion this closes.
    end = None
    for c in d2._ps.calls:
        a = c["args"]
        if "-Lane" in a and "-Event" in a and a[a.index("-Event") + 1] == "end":
            end = a
    got_in = end[end.index("-InputTokens") + 1] if end else None
    got_out = end[end.index("-OutputTokens") + 1] if end else None
    res.append(("MUST FIRE  the end line reports tokens 0, never -1 - a mechanical stage burned "
                "nothing, which is not the same as nobody having looked",
                got_in == 0 and got_out == 0, "in=%r out=%r" % (got_in, got_out)))

    # ---- MUST FIRE: a stage that THREW still closes its pair. An unclosed start is worse than no
    # start at all: -LaneSummary would carry the stage as still running and swallow the whole tail of
    # the run into it. This is the `finally` doing the work, and it fails without it.
    class Boom(object):
        def __init__(self):
            self.calls = []

        def __call__(self, script, args, timeout=180):
            self.calls.append({"script": os.path.basename(script), "args": list(args),
                               "timeout": timeout})
            if "hunt-run" in os.path.basename(script):
                return 0, "", ""
            raise RuntimeError("the stage died")

    b = Boom()
    d3 = daemon(ps=b)
    threw = False
    try:
        arun(d3.ps_timed("write", "build-v2-spec", ["s"], HD.BUILD_V2_SPEC_PS, ["-RunDir", "R"]))
    except RuntimeError:
        threw = True
    lines3 = _lane_lines(b)
    res.append(("MUST FIRE  a stage that THREW still closes its start/end pair, and the throw still "
                "reaches the caller", threw and [x[2] for x in lines3] == ["start", "end"],
                "threw=%s lines=%s" % (threw, json.dumps(lines3))))
    return res
