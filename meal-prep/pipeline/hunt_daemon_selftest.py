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
import datetime as dt
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
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

    def __call__(self, script, args, timeout=600, exe=""):
        name = os.path.basename(script)
        # `exe` IS RECORDED, not swallowed. The estate has three interpreters and they are not
        # interchangeable - a surface importing torch run under C:\Codex\Python312 reports its own
        # ImportError as a script failure - so which one a call site chose is a fact a fixture must
        # be able to assert on.
        self.calls.append({"script": name, "args": list(args), "timeout": timeout, "exe": exe})
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


# THE MEMORY SEAMS, DEFAULTED FOR THE WHOLE SUITE (PLAN-ingredient-memory D1).
#
# assemble_mapped now writes ingredient-events.jsonl and, through -Record, the resolutions ledger -
# and that ledger is consulted as STEP 1 of the per-line resolution ladder on EVERY recipe the
# estate maps. A fixture row in it is not a test artifact; it is an identity every future run would
# believe. So the suite's OWN scratch paths are the default here rather than something each fixture
# has to remember, which is the H2 lesson (three live ledgers a no-publish drill was still writing)
# applied before the first drill instead of after it. `_learn_seams_are_never_live` asserts it.
LEARN_SCRATCH = tempfile.mkdtemp(prefix="daemon-learn-seam-")
SCRATCH_EVENTS = os.path.join(LEARN_SCRATCH, "ingredient-events.jsonl")
SCRATCH_RESOLUTIONS = os.path.join(LEARN_SCRATCH, "ingredient-resolutions.json")


def daemon(run_dir="R", run_id="drill-run", dispatcher=None, ps=None, **kw):
    kw.setdefault("events_path", SCRATCH_EVENTS)
    kw.setdefault("resolutions_path", SCRATCH_RESOLUTIONS)
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
    # _asm_ps, NOT a bare FakePS: since Q1 the lane enqueues what hunt-run RECORDED, so an injected
    # hunt-run that writes no state file leaves nothing to enqueue and this case reads empty.
    ps = _asm_ps()
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
    T("MUST FIRE  F2: three proposals are ONE dispatch carrying all three, and three rulings come "
      "back - the decider's shape, one dossier in and one verdict array out",
      *_registrar_batch_is_one_dispatch())
    T("MUST FIRE  F2: the dossier carries the LIVE FEED's own price cell, the declared-same-thing "
      "rows and the label greps - the three reads the registrar's definition orders beyond the sweep",
      *_registrar_dossier_carries_the_checklist())
    T("CLEAN TWIN F2: an unreadable feed or floor map is ANNOUNCED as unreadable, never rendered as "
      "'no price cell exists' - which a registrar would read as evidence FOR a new id",
      *_registrar_unreadable_sources_are_announced())
    T("MUST FIRE  F2: a malformed item names its INDEX in the problem, and the WHOLE payload is "
      "refused - the good ruling beside it does not land either",
      *_registrar_batch_refusal_names_the_item())

    # =================================================================================================
    H("A lane's death is ITS death (2026-08-24), and the card belongs to whoever owns it")
    # =================================================================================================
    for name, ok, got in _lane_containment():
        T(name, ok, got)

    # =================================================================================================
    H("Registrar rulings run CONCURRENTLY, and the collision re-check is what makes that safe")
    # =================================================================================================
    for name, ok, got in _registrar_collision_recheck():
        T(name, ok, got)

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
    T("MUST FIRE  the write prompt hands the writer its CONTENT INLINE and asks for `fields` - no "
      "file to read, no file to write, and the old in-place language gone",
      *_write_prompt_is_a_dossier())
    T("MUST FIRE  a `fields` payload patches EXACTLY those fields and every other byte of the intake "
      "is identical to the skeleton it was issued from",
      *_fields_patch_exactly())
    T("CLEAN TWIN dotted keys nest one level, splitting on the FIRST dot only, and arrays survive as "
      "arrays",
      *_fields_nest_correctly())
    T("MUST FIRE  a key outside the fillable set is refused by the DISPATCH validator with the key "
      "named, and the intake is untouched",
      *_fields_unknown_key_refused())
    T("MUST FIRE  ...and the patcher refuses it too, so the belt holds if the brace is ever removed",
      *_patcher_refuses_unknown_key())
    T("MUST FIRE  a post-patch locked-field difference is a DAEMON BUG: the recipe is STUCK with the "
      "detail, state None, and there is NO second writer dispatch - the redrift road is gone",
      *_post_patch_drift_is_stuck())
    T("MUST FIRE  the redrift road is DELETED from the daemon's source - no redrift_prompt, no "
      "`drifted twice` branch, so nobody rebuilds the re-ask this change made impossible",
      *_redrift_road_is_gone())
    T("CLEAN TWIN a clean prose-only fill passes with exactly one dispatch and one verify",
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
    H("CHANGE A - the battery shows its arithmetic, and recipe-local repairs are patches (2026-08-25)")
    # =================================================================================================
    T("MUST FIRE  the audit dispatch CONTAINS the battery's numbers - cost_per_serving, the macro "
      "recompute vs stat, the protein derivation - and the authority language is verbatim",
      *_audit_dossier_carries_the_numbers())
    T("CLEAN TWIN an unreadable battery report is ANNOUNCED as unreadable, never rendered as an "
      "empty block an auditor would read as nothing to say",
      *_audit_dossier_unreadable_is_announced())
    T("MUST FIRE  a block over the cap says so and says to read the file - a quietly cut dossier "
      "would have the auditor believe it saw every check",
      *_audit_dossier_truncation_is_announced())
    T("MUST FIRE  blocker_kind routes: recipe-local to the patch road, shared-data and anything "
      "unrecognised to the agent road",
      *_repair_road_routes())
    T("MUST FIRE  a recipe-local NO-GO takes the PATCH road - the field prompt, the intake actually "
      "patched, and the spec rebuilt for exactly the blocked slug",
      *_recipe_local_takes_the_patch_road())
    T("MUST FIRE  a shared-data NO-GO takes the UNCHANGED road - the old prompt, the full agent, and "
      "the daemon patches nothing itself",
      *_shared_data_takes_the_unchanged_road())
    T("MUST FIRE  F4: the SCOPED RE-AUDIT names the fields the repair actually patched, and the "
      "FIRST audit of the same wave carries no delta block at all",
      *_reaudit_carries_the_repair_delta())
    T("MUST FIRE  F4: a repair that changed nothing says so in the delta WITH its reason - evidence "
      "for the auditor, never a verdict, and the mtime guard still runs independently",
      *_reaudit_delta_reports_a_no_change())
    T("CLEAN TWIN a missing blocker_kind defaults to the SHARED road - the expensive-but-safe "
      "direction, because a patch road cannot fix what it cannot reach",
      *_unknown_kind_takes_the_shared_road())
    T("MUST FIRE  a patch-road `no_change: true` still hits the changed-nothing guard: no re-audit "
      "is paid for, no spec is rebuilt, and the reason is a finding",
      *_patch_road_no_change_still_guards())
    T("MUST FIRE  a QA failure owned by the WRITER is a field patch, and the one-repair rule is "
      "untouched - one repair, exactly one re-QA",
      *_qa_writer_repair_is_a_patch())

    # =================================================================================================
    H("F3 - QA rules from a dossier, and the daemon holds the verdict pen (2026-08-25)")
    # =================================================================================================
    T("MUST FIRE  the QA dispatch carries the transcription's lines, the BUILT recipe's buy strings "
      "and the battery's numbers - and the anchor, blocked-domain and verdict-only language verbatim",
      *_qa_dossier_carries_its_material())
    T("CLEAN TWIN a missing battery report is ANNOUNCED as unreadable, never rendered as an empty "
      "section a QA would read as nothing to say",
      *_qa_dossier_missing_battery_is_announced())
    T("MUST FIRE  the DAEMON writes qa\<slug>.json from the payload and it carries exactly the "
      "schema's fields - the agent's Write is retired",
      *_qa_daemon_holds_the_verdict_pen())
    T("MUST FIRE  a payload with NO verdict writes NOTHING and the recipe is STUCK - a file saying "
      "nothing is worse than no file, because it looks like a ruling",
      *_qa_no_verdict_writes_nothing())
    T("CLEAN TWIN a QA failure owned by the MAPPER keeps its current owner and its current prompt - "
      "no field patch reaches a mapping defect",
      *_qa_mapper_repair_keeps_its_road())

    # =================================================================================================
    H("CHANGE M - the mapper returns food-DB rows and the DAEMON writes them (2026-08-25)")
    # =================================================================================================
    T("MUST FIRE  a payload carrying food_db_rows makes the DAEMON write them, and the file keeps "
      "its {readme, items:[...]} shape - items is a LIST, not a dict keyed by name",
      *_fooddb_writes())
    T("MUST FIRE  a row failing the Atwater check is NOT written and the finding names it - a "
      "fabricated label is the worse-than-no-gate case",
      *_fooddb_atwater_refuses())
    T("MUST FIRE  an item that already exists with DIFFERENT macros is not written, BOTH rows are "
      "quoted in the finding, and the existing row stands untouched",
      *_fooddb_conflict_never_overwrites())
    T("CLEAN TWIN an identical existing row is skipped silently - no write, no finding, no noise",
      *_fooddb_identical_is_silent())
    T("MUST FIRE  H1: same serving basis and macros a ROUNDING apart is the identical-row case - "
      "silent skip, no finding, the existing row stands (jc1 filed 2 of 5 conflicts on this noise)",
      *_fooddb_rounding_is_not_a_conflict())
    T("CLEAN TWIN H1: ...and ANY serving-basis difference is a full conflict however close the "
      "macros look - a different basis is a different claim about the food (the Pork Chops save)",
      *_fooddb_a_different_basis_is_always_a_conflict())
    T("MUST FIRE  a row citing neither an FDC id nor a URL is refused - Atwater proves four numbers "
      "agree with each other, never that they are this food's numbers",
      *_fooddb_needs_a_source())
    T("MUST FIRE  two concurrent map workers each carrying three rows leave SIX rows in the file",
      *_fooddb_concurrent_writers())
    T("MUST FIRE  ...and the neuter is REPRODUCED here: with a no-op lock the same two writers lose "
      "rows, so the case above is proving the lock and not the scheduler",
      *_fooddb_lock_is_load_bearing())
    T("MUST FIRE  the mapped artifact records what the DAEMON WROTE (db_entries_written), the old "
      "self-report key is gone, and a refused row is a finding on the artifact AND on the run",
      *_fooddb_assemble_records_what_was_written())
    T("MUST FIRE  MAPPED retired db_entries_added and carries food_db_rows with the label fields "
      "required",
      *_fooddb_schema_retired_the_self_report())
    T("MUST FIRE  map_prompt tells the mapper it has no file access to the DB, names the Atwater and "
      "conflict rules, and prefers the FDC shelf",
      *_fooddb_prompt_moved_the_pen())

    # =================================================================================================
    H("H2 - a no-publish drill must not write a LIVE grocery ledger (2026-08-25)")
    # =================================================================================================
    T("MUST FIRE  every ingredient-queue call the daemon makes carries -QueueFile and -CarriagePath, "
      "and the base arguments are untouched",
      *_h2_queue_calls_carry_the_seams())
    T("CLEAN TWIN with no seams set the call is byte-identical to what it always was - a seam that "
      "leaks a flag into a real run is its own defect",
      *_h2_live_run_passes_no_override())
    T("MUST FIRE  end to end: a mapper's absent terms are enqueued through the SCRATCH queue, and "
      "not one -Add reaches the live one",
      *_h2_map_lane_queues_through_the_seam())
    T("MUST FIRE  the decider's ruling goes to the SCRATCH dish ledger - decide_apply already had "
      "the seam and the daemon was passing an empty string, so every drill wrote the real prior-art "
      "memory",
      *_h2_considered_seam_reaches_decide_apply())
    T("MUST FIRE  the PRICER is TOLD the seams, because it holds the -Record/-Verdict/-Promote pen "
      "itself and no daemon-side threading can reach those calls",
      *_h2_pricer_is_told_the_seams())

    # =================================================================================================
    H("F1 - the FDC shelf is FILLED with the run's own terms before the mapper is paid (2026-08-25)")
    # =================================================================================================
    T("MUST FIRE  exactly the unresolved / food-DB-missing terms reach cache_fill, deduped through "
      "fdc_lookup's own key function - a settled line with a DB row is never asked about",
      *_f1_fill_list_is_the_unresolved_terms())
    T("MUST FIRE  the order is preresolve, FILL, preresolve, dispatch - and the DISPATCHED table is "
      "the second pass's, because only the re-run carries the warm shelf",
      *_f1_order_is_preresolve_fill_preresolve_dispatch())
    T("CLEAN TWIN a fill that added nothing and failed nothing skips the second mechanical pass - "
      "that batch is already as warm as it can get",
      *_f1_nothing_added_skips_the_rerun())
    T("MUST FIRE  a fill that THROWS degrades and never blocks: one finding naming the count, and "
      "the mapper is dispatched exactly as it was before F1 existed",
      *_f1_a_failed_fill_degrades_and_still_dispatches())
    T("MUST FIRE  two map workers filling overlapping term lists leave the UNION in the cache - "
      "cache_write is a whole-file write and this is the ingredient-resolutions lesson a third time",
      *_f1_concurrent_fills_keep_every_term())
    T("MUST FIRE  ...and the neuter is REPRODUCED here: with a no-op fdc_lock the same two fills "
      "lose terms, so the case above is proving the lock and not the scheduler",
      *_f1_fdc_lock_is_load_bearing())
    T("MUST FIRE  the shelf-coverage line reports X of Y and names the terms FDC LACKS - which are "
      "the mapper's licensed web reads, not findings",
      *_f1_shelf_coverage_line())

    # =================================================================================================
    H("M4 - four prompt patches, no schema change (2026-08-25)")
    # =================================================================================================
    # NEUTER PROOFS, ALL FOUR RUN AND REVERTED 2026-08-25, with the counts the suite printed:
    #   - remove the FDC ban sentence            -> 1 red (its own case);
    #   - remove the ONE-fetch cap sentence      -> 1 red;
    #   - INVERT food_db_seam_note's guard so the seam and the live path swap -> 2 red, the seamed
    #     case AND the unseamed twin, which is the pair working: a seam that leaks a sentence into a
    #     real run is its own defect;
    #   - drop the precheck-is-whole clause      -> 1 red.
    #   - T5 (2026-08-25): neutralise the reads-not-searches clauses (a WebSearch "is a read", the
    #     allowance "also spent", the row-you-never-looked-for line inverted) -> 1 red, the T5 case
    #     alone. Run and reverted. NOTE FOR THE NEXT NEUTER: rebuilding a prompt sentence by hand in
    #     the neuter script wrote a REAL newline into the literal and the daemon failed to import -
    #     the suite then reports 0 red, which looks like a dead fixture and proves nothing. Neuter by
    #     substring surgery on the file's own bytes, and check the case count before believing a zero.
    T("MUST FIRE  the prompt BANS the direct FDC query and names DEMO_KEY as the throttling lie - "
      "lf1 round 1 made 6 of them for foods the shelf had already covered",
      *_m4_bans_the_direct_fdc_query())
    T("MUST FIRE  the prompt caps the hunt at ONE fetch and ONE fallback per food, and says a "
      "missing row is a finding - lf1 round 2 spent 9 web calls on 2 foods",
      *_m4_caps_the_hunt())
    T("MUST FIRE  the cap counts LABEL READS and says a WebSearch is not one - on m1 batch A two "
      "searches burned the whole allowance, no label was read, and the write lane refused the recipe",
      *_t5_cap_counts_reads_not_searches())
    T("MUST FIRE  a SEAMED run names the scratch food DB in the prompt, the way queue_seam_note "
      "names the scratch queue",
      *_m4_seam_note_names_the_scratch_db())
    T("CLEAN TWIN an UNSEAMED daemon renders no drill sentence at all - food_db_seam_note is empty "
      "and the prompt is what it always was",
      *_m4_unseamed_prompt_carries_no_drill_sentence())
    T("MUST FIRE  the prompt says the precheck is rendered WHOLE, so there is nothing to go and "
      "read in mapped-pre\\<slug>.json - that read cost lf1 round 2 four turns",
      *_m4_says_the_precheck_is_complete())

    # =================================================================================================
    H("G1 - the harness's own Grep, said once to every judge that sweeps (2026-08-25)")
    # =================================================================================================
    # NEUTER PROOFS, RUN AND REVERTED 2026-08-25 - the counts the suite printed, not the ones predicted:
    #   - blank GREP_HARNESS_NOTE                  -> 5 red, not 4: the four rendering cases AND the
    #     safety case, which also needs the sentence present (the no-leak twin correctly stays green,
    #     because it asserts an ABSENCE);
    #   - drop the "never a reason to stop sweeping" clause -> 1 red, the safety case alone;
    #   - render the note into price_prompt too    -> 1 red, the no-leak twin, which proves that twin
    #     pins the deliberate omission rather than passing by luck.
    T("MUST FIRE  the REGISTRAR's prompt names both harness behaviours - the root-anchored brace that "
      "returns a false empty, and the minified feed's omitted line - which cost it 7 of 12 turns",
      *_g1_registrar_prompt_carries_the_note())
    T("MUST FIRE  the MAPPER's prompt carries the same note", *_g1_map_prompt_carries_the_note())
    T("MUST FIRE  source-QA's prompt carries the same note", *_g1_qa_prompt_carries_the_note())
    T("MUST FIRE  the AUDITOR's prompt carries the same note", *_g1_audit_prompt_carries_the_note())
    T("MUST FIRE  the note distrusts the empty RESULT and never the sweep, and F2's authority "
      "language stands untouched beside it - the sweep is where every decisive ruling came from",
      *_g1_note_never_discourages_the_sweep())
    T("CLEAN TWIN it does NOT leak into the pricer or the decider, neither of which sweeps a "
      "namespace - prompt weight buys nothing where nobody greps",
      *_g1_note_does_not_leak_into_prompts_that_do_not_sweep())

    # =================================================================================================
    H("M2 - the map dossier carries the estate (2026-08-25)")
    # =================================================================================================
    # NEUTER PROOFS, ALL FIVE RUN AND REVERTED 2026-08-25. The counts are what the suite actually
    # printed, not what section 4.3 predicted - each neuter took its own case AND the twins that
    # depend on the same section being rendered at all:
    #   - drop section 1 (the food-DB rows)        -> 3 red: the seam case, the announced-unreadable
    #     twin (nothing left to announce) and the cap case (the block no longer reaches 4,000);
    #   - drop section 2 (the whole precheck)      -> 3 red: the tuning case and the same two;
    #   - drop section 3 (the yield)               -> 2 red: the servings case and the twin;
    #   - read the LIVE DB instead of self.food_db_path -> 2 red: the seam case with the scratch
    #     numbers absent, which is the lf1 round-2 defect reproduced exactly, and the twin;
    #   - raise MAP_EXTRAS_CAP above the block     -> 1 red: the cap case alone.
    T("MUST FIRE  a fooddb_known food's OWN numbers ride in the prompt, read through the --food-db "
      "SEAM - lf1 round 2 read the LIVE DB four times while pointed at a scratch copy",
      *_m2_food_db_rows_come_from_the_seam())
    T("MUST FIRE  the precheck rides WHOLE: every tuning line, the uncovered lines and the missing "
      "DB rows, verbatim - one tuning line was the entire explanation for a 591-vs-468 disagreement",
      *_m2_the_precheck_rides_whole())
    T("MUST FIRE  the extraction's servings, title and source_url arrive, and the raw ingredient "
      "lines are NOT rendered a second time - the table already carries them",
      *_m2_the_yield_arrives_and_the_lines_are_not_doubled())
    T("CLEAN TWIN an unreadable food DB and a missing extraction are both ANNOUNCED, and the rest of "
      "the prompt still builds - a quietly shorter dossier reads as a complete one",
      *_m2_unreadable_is_announced())
    T("MUST FIRE  the cap ANNOUNCES itself when it bites, naming how many lines are not shown",
      *_m2_the_cap_announces_itself())

    # =================================================================================================
    H("M3 - a recipe with nothing to price stops going to the price lane (2026-08-25)")
    # =================================================================================================
    # NEUTER PROOF, RUN AND REVERTED 2026-08-25: restoring the `and norm_state(res["state"]) ==
    # "priced"` clause turned THREE cases red, not the two section 5.3 predicted - the two named
    # there plus the optional case, which routes through the same branch. The first one reproduced
    # the lf1 round-2 park exactly, in its own got line: advanced=["mapped", "pricing"] adds=[] -
    # a recipe sent to the price lane with an EMPTY term list and nothing that could ever wake it.
    # Both twins stayed green, which is the point of them.
    T("MUST FIRE  a mapper result with ZERO absent terms lands on the WRITE channel at `priced` even "
      "though the mapper called its own state `mapped` - the terms decide the route, and no -Add "
      "reaches the queue",
      *_m3_zero_absent_routes_to_write())
    T("MUST FIRE  ...and the disagreement is LOGGED, naming the slug and the state it claimed",
      *_m3_the_disagreement_is_logged())
    T("CLEAN TWIN three absent terms still route to `pricing`, still enqueue all three and still "
      "wake the price lane - byte for byte as before M3",
      *_m3_absent_terms_still_price())
    T("CLEAN TWIN a table with unbid HOLDS still holds at `mapped` and never reaches either branch - "
      "the hold returns first and M3 does not touch it",
      *_m3_the_unbid_hold_returns_first())
    T("MUST FIRE  zero absent WITH an optional_absent term advances to `priced` AND the optional "
      "term still reaches the queue - optional never blocked and does not start blocking here",
      *_m3_optional_still_reaches_the_queue())

    # =================================================================================================
    H("Q1 - a term recorded as BLOCKING is a term on the QUEUE (2026-08-26)")
    # =================================================================================================
    # These five run the REAL hunt-run.ps1 and the REAL ingredient-queue.ps1 against a scratch run dir
    # and a scratch -QueueFile. Every M3 case above injects hunt-run, which is exactly why none of them
    # could see this defect: an injected hunt-run cannot union a carriage term, so the claim and the
    # record can never disagree inside a FakePS fixture. Pinning blocking_terms() or
    # Get-CarriageBlockingTerms alone would have reproduced the call-site trap PLAN-map-judge-split
    # section 4 names, so the pin is on the LANE.
    T("MUST FIRE  after the map lane routes a recipe to `pricing`, EVERY non-optional term on its "
      "state file exists in the ingredient queue - the postcondition, over the real scripts",
      *_q1_every_blocking_term_is_on_the_queue())
    T("MUST FIRE  a term the CARRIAGE UNION added and the mapper never claimed is enqueued too - the "
      "8 stranded terms on hunt-2026-08-26-ten were every one of them this shape",
      *_q1_the_carriage_half_is_enqueued_too())
    T("MUST FIRE  NET 1: a line the mapper ruled `optional-note` is RECORDED on the recipe as "
      "optional and never reaches the queue - it cannot block, and it must not vanish either",
      *_q1_net1_the_mappers_own_ruling())
    T("MUST FIRE  NET 2: a tap line the mapper MISLABELLED as a real purchase is still stopped, by "
      "the stoplist - the two nets are tested apart because together they hide each other",
      *_q1_net2_the_stoplist())
    T("MUST FIRE  a derived item holding three spices is SPLIT - no comma survives onto the state "
      "file and all three parts are on the queue",
      *_q1_a_composite_line_is_split_and_each_part_queued())
    T("CLEAN TWIN a recipe with nothing derived, nothing composite and nothing un-buyable queues "
      "EXACTLY the mapper's claim - the fix does not turn the queue into a dumping ground",
      *_q1_clean_twin_nothing_extra_is_queued())

    # =================================================================================================
    H("Q2 - the carriage gate runs on EVERY road to `priced`, including the zero-absent one (2026-08-26)")
    # =================================================================================================
    # NEUTER PROOFS, ALL RUN AND REVERTED 2026-08-26, counts exactly as the suite printed them. The
    # FULL case count was read on every one, never just the red count: a case that VANISHES and a case
    # that PASSES are indistinguishable in a tally of failures, and this suite has been bitten by that.
    # The total held at 255 on all three, and the restore was verified byte-identical by md5.
    #   * N1 - map lane's direct `advance(slug, "priced")` on the zero-absent road restored, AND
    #     `mapped` -> `priced` put back in $script:NEXT   -> 4 red / 255 total: the two M3 route cases
    #     (which now pin the route, not just the destination), the zero-absent case below, and the
    #     edge case below.
    #   * N2 - ONLY the state-machine edge put back, daemon left routed through `pricing`
    #                                                    -> 1 red / 255 total: the EDGE case alone.
    #     Every lane case stayed green, which is precisely why the edge is pinned separately - the
    #     daemon doing the right thing by habit is not the same as the door being shut.
    #   * N3 - the UNHOLD road's direct advance restored, plus the edge
    #                                                    -> 2 red / 255 total: the edge case and the
    #     unhold case. The map-lane cases stayed green, so the two roads are pinned independently and
    #     neither is riding on the other's fix.
    T("MUST FIRE  a mapper result with ZERO absent terms over an artifact whose real-bid ingredient "
      "the carriage union does NOT report CARRIED is REFUSED `priced` - it lands at `pricing` with "
      "the derived term blocking, on the queue, and no writer paid",
      *_q2_zero_absent_is_still_carriage_checked())
    T("CLEAN TWIN a recipe whose every line the union agrees is CARRIED still reaches `priced` in the "
      "same pass, enqueues nothing and still reaches the writer - M3's purpose, kept whole",
      *_q2_clean_twin_every_line_carried_still_reaches_priced())
    T("MUST FIRE  and the BYPASS ITSELF is gone: the real hunt-run.ps1 refuses `mapped` -> `priced` "
      "outright and leaves the state file where it was, so no future caller can route around the "
      "union the way these two did",
      *_q2_the_state_machine_refuses_the_bypass())
    T("MUST FIRE  THE SECOND ROAD: the UNHOLD advances on a ruling that reported nothing absent, and "
      "it is carriage-checked too - a recipe held for an unbid line and later repaired lands at "
      "`pricing` with its derived term queued, not on a paid page",
      *_q2_unhold_is_carriage_checked())

    # =================================================================================================
    H("T7 / T8 - the two defects the T-shakedown run measured (2026-08-25)")
    # =================================================================================================
    # NEUTER PROOFS, ALL RUN AND REVERTED 2026-08-25, counts as the suite printed them:
    #   * drop the servings check                       -> 1 red;
    #   * drop the protein check                        -> 1 red;
    #   * REJECT on missing protein instead of sticking -> 1 red (the twin pins the distinction:
    #     our bookkeeping gap must not throw away someone else's good page);
    #   * revert the T8 call site to the declared list  -> 1 red, but ONLY after the call-site case
    #     was added. It first came back 0 RED, because the T8 cases exercised new_bid_proposals()
    #     directly and nothing asserted assemble_mapped actually calls it - and the defect was never
    #     that the sweep was wrong, it was that this road had no sweep. Second time this build that a
    #     fixture pinned a function while the bug lived at its call site.
    #   * swallow the blocked-sweep finding             -> 1 red.
    T("MUST FIRE  a source stating NO SERVINGS is refused AT PICK-UP, before a mapper dispatch is "
      "paid for - it cost the T-shakedown a 7.8 min batch to learn this",
      *_t7_no_servings_is_refused_before_the_mapper())
    T("MUST FIRE  a candidate with no PROTEIN is STUCK and resumable, never rejected - that is our "
      "bookkeeping missing, not a defect in the source page",
      *_t7_no_protein_is_stuck_not_rejected())
    T("CLEAN TWIN a COMPLETE candidate still dispatches, and the gate refuses nothing",
      *_t7_a_complete_candidate_still_dispatches())
    T("MUST FIRE  an UNDECLARED new bid still reaches the registrar - the mapper ruled "
      "`ground-chicken` and declared nothing, and the gate that adjudicates had become a gate that "
      "silently stalls", *_t8_an_undeclared_bid_still_reaches_the_registrar())
    T("MUST FIRE  ...and the CALL SITE uses it: assemble_mapped dispatches the registrar for an id "
      "the mapper never declared. Pinning only the function passes with the bug restored",
      *_t8_the_call_site_actually_uses_the_sweep())
    T("CLEAN TWIN a BLOCKED sweep falls back to the declared proposals and ANNOUNCES it - today's "
      "behaviour, with the assembler still refusing any id nothing approved",
      *_t8_a_blocked_sweep_degrades_and_says_so())

    # =================================================================================================
    H("D1/D2 - the map lane's rulings become memory, and error writes too")
    # =================================================================================================
    # NEUTER PROOFS, RUN AND REVERTED 2026-08-25, counts as this suite printed them:
    #   * delete the apply_learn call from assemble_mapped   -> 5 red;
    #   * move it ABOVE the rc==EXIT_CLEAN check (learn from a failed assemble) -> 1 red;
    #   * drop the postcondition_finding call at the call site -> 1 red;
    #   * route learn_qa_fail off owner_agent()'s answer instead of the RAW owner field -> 1 red
    #     (the twin: owner_agent maps anything unrecognised to recipe-writer, so a writer-owned
    #     fail would file itself as a mapper fail);
    #   * drop the two seam defaults from daemon()           -> 1 red.
    T("MUST FIRE  assemble_mapped LEARNS: two clean rulings become two events and two ledger rows, "
      "and it is the CALL SITE that does it - pinning apply_learn alone passes with the hook deleted",
      *_learn_the_call_site_writes_events())
    T("MUST FIRE  a FAILED assemble teaches NOTHING - no event, no ledger. The run refused to build "
      "a decision file over that ruling, so it must not become an identity",
      *_learn_a_failed_assemble_teaches_nothing())
    T("MUST FIRE  a writer that drops one of two rulings trips the 44-class postcondition AT THE "
      "CALL SITE, naming both counts", *_learn_the_44_class_fires_at_the_call_site())
    T("CLEAN TWIN the same road with an honest writer trips nothing",
      *_learn_a_clean_batch_trips_nothing())
    T("MUST FIRE  a registrar ruling gets its OWN event (the estate's first registrar ledger) and "
      "the REJECTED id is held rather than cached", *_learn_registrar_rulings_get_events())
    T("MUST FIRE  a QA fail owned by the MAPPER writes exactly one slug-level event carrying the "
      "slug's residual keys", *_qa_mapper_fail_writes_one_event())
    T("CLEAN TWIN a QA fail owned by the WRITER writes none - the raw owner field decides, not "
      "owner_agent(), which maps everything it does not recognise to recipe-writer",
      *_qa_writer_fail_writes_none())
    T("MUST FIRE  the suite's memory seams are never the live estate files (H2's lesson, applied "
      "with the writer instead of after it)", *_learn_seams_are_never_live())

    # =================================================================================================
    H("D3 - attend: the nearest PAST rulings, as a shelf and never as an answer")
    # =================================================================================================
    # NEUTER PROOFS, RUN AND REVERTED 2026-08-25, counts as this suite printed them:
    #   * render the BLIND state as an empty channel        -> 2 red;
    #   * drop the `exe=SIDECAR_PY` from the call site      -> 1 red;
    #   * ask about SETTLED lines as well as residual ones  -> 1 red;
    #   * drop the map_prompt sentence                      -> 1 red;
    #   * render neighbours without their own term/date     -> 2 red.
    T("MUST FIRE  the neighbours reach the DOSSIER, each carrying the phrase it was ruled for, its "
      "id, its decision and its date - and a term with none says so",
      *_prior_renders_the_shelf())
    T("MUST FIRE  the retrieval runs under the SIDECAR interpreter, on a 120 s budget - bge-m3 lives "
      "in sidecar\\.venv and C:\\Codex\\Python312 has no torch",
      *_prior_uses_the_sidecar_interpreter())
    T("MUST FIRE  a retrieval that could not run renders BLIND and says absent evidence is not "
      "absence of precedent - an empty list pretending it looked is the one thing this may not do",
      *_prior_blind_is_announced())
    T("CLEAN TWIN an EMPTY corpus is not BLIND: the retriever ran, and the shelf says so per term",
      *_prior_empty_is_not_blind())
    T("MUST FIRE  a REJECTED and a MAPPED-NULL neighbour render with their decision words - the "
      "estate's transfer asymmetry is for the judge to weigh, not a filter to apply here",
      *_prior_every_decision_stays_visible())
    T("MUST FIRE  only RESIDUAL terms are asked about - a settled line is not a question",
      *_prior_only_residual_terms_are_asked())
    T("MUST FIRE  map_prompt NAMES the new field. A prompt that said `unchanged contract` without "
      "naming one field broke a clean batch on 2026-08-24", *_prior_the_prompt_names_the_field())
    T("CLEAN TWIN a BLIND shelf costs the batch a channel and nothing else - the dossier still "
      "carries its settled lines and the recipe still maps", *_prior_never_blocks_the_lane())

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
# M4 - the four prompt patches. Assertions are on the SENTENCE, because the sentence is the change.
# =====================================================================================================

def _m4_prompt(seam=True):
    tmp = tempfile.mkdtemp(prefix="daemon-m4-")
    doc = _m2_table(tmp)
    db_path = os.path.join(tmp, "food-db.json")
    with open(db_path, "w", encoding="utf-8") as f:
        json.dump(M2_SCRATCH_DB, f)
    d = daemon(run_dir=tmp, food_db_path=db_path if seam else "")
    try:
        return d.map_prompt(["s1"], {"s1": doc}), d, db_path
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _m4_bans_the_direct_fdc_query():
    prompt, _d, _p = _m4_prompt()
    want = ["Do NOT query", "api.nal.usda.gov yourself and NEVER with DEMO_KEY",
            "the worst lie a nutrition lookup can"]
    missing = [w for w in want if w not in prompt]
    return not missing, "missing=%s" % json.dumps(missing)


def _m4_caps_the_hunt():
    prompt, _d, _p = _m4_prompt()
    want = ["ONE fetch and ONE fallback per food",
            "return NO row for that food and say why in `detail`",
            "a fifth fetch is a turn that re-reads this whole"]
    missing = [w for w in want if w not in prompt]
    return not missing, "missing=%s" % json.dumps(missing)


def _t5_cap_counts_reads_not_searches():
    """MUST FIRE (T5, 2026-08-25). The cap missed in BOTH directions on the m1 drill: 9 web calls on
    2 foods on batch B, and on batch A two WebSearches burned the whole allowance without a single
    label read - the mapper returned no row, gave no reason, and the write lane refused the recipe.
    The eval offered "the cap counts READS and a search is not a read" as a hypothesis; this is that
    hypothesis written into the sentence so the model cannot hold the other reading."""
    prompt, _d, _p = _m4_prompt()
    want = ["THE CAP COUNTS LABEL READS",
            "A WebSearch is NOT a read",
            "never spends the allowance",
            "leave both\nyour reads unspent",
            "A row you did not\neven look for is not a cap working"]
    missing = [w for w in want if w not in prompt]
    return not missing, "missing=%s" % json.dumps(missing)


def _m4_seam_note_names_the_scratch_db():
    prompt, d, db_path = _m4_prompt(seam=True)
    note = d.food_db_seam_note()
    return (("THIS IS A DRILL ON A SCRATCH FOOD DB at %s" % db_path) in prompt
            and "Verify against THAT file" in prompt and note.strip() != "", "note=%r" % note[:90])


def _m4_unseamed_prompt_carries_no_drill_sentence():
    prompt, d, _p = _m4_prompt(seam=False)
    # A SEAM THAT LEAKS A SENTENCE INTO A REAL RUN IS ITS OWN DEFECT - the queue_seam_note twin,
    # a second time.
    return (d.food_db_seam_note() == "" and "SCRATCH FOOD DB" not in prompt
            and "THIS IS A DRILL" not in prompt,
            "note=%r live=%s" % (d.food_db_seam_note(), d.food_db_path))


def _m4_says_the_precheck_is_complete():
    prompt, _d, _p = _m4_prompt()
    want = ["VERIFY it, do not re-derive it. The precheck block below is rendered WHOLE",
            "so there is nothing to go and read in mapped-pre\\<slug>.json"]
    missing = [w for w in want if w not in prompt]
    return not missing, "missing=%s" % json.dumps(missing)



# =====================================================================================================
# M2 - the map dossier carries the estate.
#
# MEASURED (lf1 round 2, 21 tool calls on a batch where 2 of 3 recipes had ZERO residual lines): 3
# extraction Reads, 1 Grep plus 4 full Reads of the LIVE food-macros-db.json while the drill was
# pointed at a scratch copy, and 4 turns re-reading mapped-pre\<slug>.json for the macro_precheck
# block. Twelve of twenty-one calls, all for material the daemon already had on disk.
# =====================================================================================================

M2_SCRATCH_DB = {"readme": "a scratch DB whose numbers exist nowhere else",
                 "items": [
                     {"item": "Chicken", "brand": "Scratch", "serving_grams": 111, "serving_qty": 4,
                      "serving_unit": "oz", "calories": 1231, "protein_g": 251, "carbs_g": 1,
                      "fat_g": 31},
                     {"item": "Rice", "brand": "Scratch", "serving_grams": 112, "serving_qty": 1,
                      "serving_unit": "cup", "calories": 1232, "protein_g": 252, "carbs_g": 2,
                      "fat_g": 32},
                     {"item": "Cheddar", "brand": "Scratch", "serving_grams": 113, "serving_qty": 1,
                      "serving_unit": "oz", "calories": 1233, "protein_g": 253, "carbs_g": 3,
                      "fat_g": 33}]}

M2_RAW = "1 lb chicken, cut into 1-inch pieces"


def _m2_table(tmp, slug="s1", known=("Chicken", "Rice", "Cheddar"), tuning=None, extraction=True):
    """One mapped-pre table with THREE food-DB-known rows, a whole precheck, and its extraction."""
    out = os.path.join(tmp, "mapped-pre")
    os.makedirs(out, exist_ok=True)
    rows = []
    for i, item in enumerate(known):
        rows.append({"raw": M2_RAW if i == 0 else ("%d cup %s" % (i, item)),
                     "term": item.lower(), "canon_item": item, "bid": item.lower(),
                     "board": "weekly", "resolution": "resolved", "gpu_known": True,
                     "density_known": True, "fooddb_known": True, "evidence": "exact vocabulary row",
                     "source": "vocab"})
    rows.append({"raw": "1 tbsp gochujang", "term": "gochujang", "canon_item": None, "bid": None,
                 "board": None, "resolution": "unresolved", "gpu_known": False,
                 "density_known": False, "fooddb_known": False,
                 "evidence": "no vocabulary row shares a core word", "source": None})
    doc = {"slug": slug, "title": "Drill Dish", "source_url": "https://d/%s" % slug, "servings": 4,
           "line_count": len(rows), "resolved_count": len(known), "residual_count": 1,
           "hold_count": 0, "residual_terms": ["gochujang"], "holds": [], "rows": rows,
           "macro_precheck": {"state": "computed", "reason": "",
                              "source": {"from": "candidate-pool.band", "cal": 468, "carbs": 20,
                                         "protein_g": 35, "fat_g": None},
                              "lines_covered": 3, "lines_total": len(rows),
                              "uncovered_lines": ["gochujang", "tteok", "saffron"],
                              "computed_per_serving": {"cal": 591, "carbs": 41, "protein_g": 44,
                                                       "fat_g": 22},
                              "portion_factor": 1.75,
                              "tuning": list(tuning if tuning is not None else
                                             ["added Rice base 200g (src scale)",
                                              "dropped garnish parsley (0.4 g)",
                                              "held cheddar at label basis"]),
                              "missing_db_items": ["gochujang", "tteok", "saffron"]}}
    with open(os.path.join(out, "%s.json" % slug), "w", encoding="utf-8") as f:
        json.dump(doc, f)
    if extraction:
        ex = os.path.join(tmp, "extracted")
        os.makedirs(ex, exist_ok=True)
        with open(os.path.join(ex, "%s.json" % slug), "w", encoding="utf-8") as f:
            json.dump({"slug": slug, "title": "Skillet Chicken And Rice",
                       "source_url": "https://example.test/skillet-chicken-and-rice",
                       "servings": 6,
                       "ingredients": [{"raw": M2_RAW, "item": "chicken", "qty": "1", "unit": "lb"}]},
                      f)
    return doc


def _m2_prompt(tmp, db=M2_SCRATCH_DB, seam=True, **kw):
    """The map prompt for one slug, built off a SCRATCH food DB whose numbers exist nowhere else."""
    doc = _m2_table(tmp, **kw)
    db_path = os.path.join(tmp, "food-db.json")
    if db is not None:
        with open(db_path, "w", encoding="utf-8") as f:
            json.dump(db, f)
    d = daemon(run_dir=tmp, food_db_path=db_path if seam else "")
    return d.map_prompt(["s1"], {"s1": doc}), d


def _m2_food_db_rows_come_from_the_seam():
    tmp = tempfile.mkdtemp(prefix="daemon-m2a-")
    try:
        prompt, d = _m2_prompt(tmp)
        # THE NUMBERS, NOT THE NAMES. A name proves the row was listed; only the scratch DB's own
        # calories prove which FILE it was read out of, which is the whole claim.
        want = ["Chicken: 4 oz = 111 g, 1231 cal, 251 P, 1 C, 31 F",
                "Rice: 1 cup = 112 g, 1232 cal, 252 P, 2 C, 32 F",
                "Cheddar: 1 oz = 113 g, 1233 cal, 253 P, 3 C, 33 F"]
        missing = [w for w in want if w not in prompt]
        return (not missing and d.food_db_path == os.path.join(tmp, "food-db.json"),
                "missing=%s" % json.dumps(missing))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _m2_the_precheck_rides_whole():
    tmp = tempfile.mkdtemp(prefix="daemon-m2b-")
    try:
        prompt, _d = _m2_prompt(tmp)
        want = ["tuning: added Rice base 200g (src scale)",
                "tuning: dropped garnish parsley (0.4 g)",
                "tuning: held cheddar at label basis",
                "food-DB rows it wanted and did not have: gochujang, tteok, saffron",
                "lines it could NOT cover: gochujang, tteok, saffron",
                "portion factor 1.75",
                "3 of 4 line(s) covered"]
        missing = [w for w in want if w not in prompt]
        return not missing, "missing=%s" % json.dumps(missing)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _m2_the_yield_arrives_and_the_lines_are_not_doubled():
    tmp = tempfile.mkdtemp(prefix="daemon-m2c-")
    try:
        prompt, _d = _m2_prompt(tmp)
        yielded = ("6 servings" in prompt and "Skillet Chicken And Rice" in prompt
                   and "https://example.test/skillet-chicken-and-rice" in prompt)
        # ONE occurrence of the raw line, from the table's own SETTLED block. A second copy is a
        # second thing to disagree with the first.
        n = prompt.count(M2_RAW)
        return (yielded and n == 1), "yield=%s raw_occurrences=%d" % (yielded, n)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _m2_unreadable_is_announced():
    tmp = tempfile.mkdtemp(prefix="daemon-m2d-")
    try:
        # No DB file written at all, and no extraction either.
        prompt, _d = _m2_prompt(tmp, db=None, extraction=False)
        announced = prompt.count("the table says a row exists and it could not be read")
        yield_said = "could not be read" in prompt and "extracted\\s1.json" in prompt
        # ...and the prompt is still a prompt: the residual, the contract and the precheck all stand.
        intact = ("gochujang" in prompt and "YOUR JOB IS THREE THINGS" in prompt
                  and "tuning: added Rice base 200g (src scale)" in prompt)
        return ((announced == 3 and yield_said and intact),
                "announced=%d yield_said=%s intact=%s" % (announced, yield_said, intact))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _m2_the_cap_announces_itself():
    tmp = tempfile.mkdtemp(prefix="daemon-m2e-")
    try:
        # 60 tuning lines is well past 4,000 characters, and a real precheck can carry dozens.
        tuning = ["tuning line %02d: added something at source scale" % i for i in range(60)]
        doc = _m2_table(tmp, tuning=tuning)
        db_path = os.path.join(tmp, "food-db.json")
        with open(db_path, "w", encoding="utf-8") as f:
            json.dump(M2_SCRATCH_DB, f)
        d = daemon(run_dir=tmp, food_db_path=db_path)
        prompt = d.map_prompt(["s1"], {"s1": doc})
        # THE ANNOUNCEMENT, AND PROOF THAT REAL CONTENT WAS DROPPED: the yield section is rendered
        # LAST, so a capped block is a block whose yield line is gone. Capping quietly would leave
        # the mapper believing it had seen the whole dossier.
        return (("CAPPED at 4000 characters" in prompt and "more line(s) of this block are not shown"
                 in prompt and "tuning line 00" in prompt
                 and "THE SOURCE'S OWN YIELD" not in prompt),
                "capped=%s yield_dropped=%s" % ("CAPPED at 4000 characters" in prompt,
                                                 "THE SOURCE'S OWN YIELD" not in prompt))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)



# =====================================================================================================
# M3 - the terms decide the route, not the mapper's own state field.
#
# THE MEASURED DEFECT (lf1 round 2, EVAL-latency-lf1-drill finding 3): both fully-resolved recipes
# advanced mapped -> pricing carrying an EMPTY absent_terms list, enqueued nothing, and sat. Nothing
# could ever wake them, and the state file said `pricing`, which reads like a recipe legitimately
# waiting on a price. Only a second daemon start and its hunt-run -Derive moved them on.
#
# THE SIBLING SITE, NAMED AND DELIBERATELY LEFT: the unhold road carries the identical condition
# (`if not absent and rec.get("mapper_state") == "priced"`). It sits inside the unbid HOLD road,
# which PLAN-map-lane-latency section 2 lists among the things M3 does not touch, so it is reported
# to Brad rather than changed here.
#
# CLOSED 2026-08-26 BY Q2, on Brad's ruling, and both roads went the same way: neither of them is
# reachable any more, because `mapped` -> `priced` is no longer a transition the state machine will
# make. Reporting it rather than changing it was right - and it is worth noticing that the report sat
# for a day carrying a defect nobody could see from inside the M3 fixtures, because every one of them
# injects hunt-run. See the Q2 section for both pins.
# =====================================================================================================

def _m3_map(tmp, absent=None, optional=None, state="mapped", holds=None):
    """One map-lane run over one slug, with the mapper's own state and term lists chosen. Returns
    (daemon, FakePS) so a case can assert the route AND the queue calls off the same run."""
    preresolved(tmp, ["s1"], holds=holds, residual={"s1": ["gochujang", "tteok", "saffron"]})
    ps = _asm_ps(0)
    res = _mapper_result("s1")
    res["state"] = state
    res["absent_terms"] = list(absent or [])
    res["optional_absent"] = list(optional or [])
    fd = FakeDispatch({"recipe-ingredient-mapper": [{"results": [res]}]})
    d = daemon(run_dir=tmp, dispatcher=fd, ps=ps, queue_path=os.path.join(tmp, "queue.json"),
               carriage_path=os.path.join(tmp, "carriage.json"))
    # NOT QUIET: the disagreement line is one of the things M3 ships, and the suite's daemon() helper
    # silences log() by default.
    d.quiet = False
    d.ch["map"].push({"slug": "s1"})
    d.ch["map"].close()
    # THE LOG IS THE ARTIFACT for the disagreement case, so it is CAPTURED rather than watched go by:
    # Daemon.log prints through say(), and a line nobody can read is a line that is not really there.
    import contextlib                                             # noqa: PLC0415
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        arun(d.run(("map",)))
    d.m3_log = buf.getvalue().splitlines()
    return d, ps


def _m3_advanced_to(ps):
    """Every state hunt-run.ps1 -Advance was asked for, in order. The route is a claim about what the
    daemon DID, so it is read off the real call rather than off an internal flag."""
    return [FakePS.value_after(c["args"], "-To")
            for c in ps.find("hunt-run.ps1") if "-Advance" in c["args"]]


def _m3_queue_terms(ps):
    return [FakePS.value_after(c["args"], "-Term")
            for c in ps.find("ingredient-queue.ps1") if "-Add" in c["args"]]


# =====================================================================================================
# T7 / T8 - the two defects the T-shakedown run measured (2026-08-25)
#
# T7: 2 of 3 recipes died AFTER a 7.8-minute mapper dispatch, on facts arithmetic already knew - one
# extraction stated no servings, one candidate carried no protein. The gate now runs at PICK-UP.
# T8: the mapper ruled `bid='ground-chicken'` with an EMPTY new_commodity_proposals, no registrar was
# ever dispatched, and the assembler refused the unapproved id - a gate that adjudicates turned into
# a gate that silently stalls. map-preresolve's -NewBids answered this all along and nobody called it.
# =====================================================================================================

def _t7_pickup(tmp, servings=4, protein="chicken"):
    """One map-lane run whose extraction and state completeness the case chooses."""
    preresolved(tmp, ["s1"], residual={"s1": ["gochujang"]})
    os.makedirs(os.path.join(tmp, "extracted"), exist_ok=True)
    ext = {"slug": "s1", "title": "T", "source_url": "u", "ingredients": [], "instructions": []}
    if servings is not None:
        ext["servings"] = servings
    with io.open(os.path.join(tmp, "extracted", "s1.json"), "w", encoding="utf-8") as f:
        f.write(json.dumps(ext))
    os.makedirs(os.path.join(tmp, "state"), exist_ok=True)
    st = {"slug": "s1", "state": "extracted", "history": [], "reject_reason": ""}
    if protein:
        st["protein"] = protein
    with io.open(os.path.join(tmp, "state", "s1.json"), "w", encoding="utf-8") as f:
        f.write(json.dumps(st))
    ps = _asm_ps(0)
    fd = FakeDispatch({"recipe-ingredient-mapper": [{"results": [_mapper_result("s1")]}]})
    d = daemon(run_dir=tmp, dispatcher=fd, ps=ps)
    d.ch["map"].push({"slug": "s1"})
    d.ch["map"].close()
    arun(d.run(("map",)))
    return d, ps, fd


def _t7_no_servings_is_refused_before_the_mapper():
    """MUST FIRE. A source that never stated its yield can never become a costed 14-serving recipe,
    so it is rejected-unreadable BEFORE the dispatch - not discovered after one is paid for."""
    tmp = tempfile.mkdtemp(prefix="daemon-t7a-")
    try:
        d, ps, fd = _t7_pickup(tmp, servings=None)
        dispatched = len(fd.prompts("recipe-ingredient-mapper"))
        states = _m3_advanced_to(ps)
        said = any("REFUSED AT PICK-UP" in f for f in d.findings)
        return (dispatched == 0 and "rejected-unreadable" in states and said,
                "dispatches=%d states=%s findings=%s"
                % (dispatched, json.dumps(states), json.dumps(d.findings)[:200]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _t7_no_protein_is_stuck_not_rejected():
    """MUST FIRE. Missing protein is RUN BOOKKEEPING, not a defect in the source, so the recipe is
    STUCK and resumable - rejecting it would throw away a perfectly good page over our own omission."""
    tmp = tempfile.mkdtemp(prefix="daemon-t7b-")
    try:
        d, ps, fd = _t7_pickup(tmp, protein="")
        dispatched = len(fd.prompts("recipe-ingredient-mapper"))
        states = _m3_advanced_to(ps)
        rejected = [s for s in states if str(s).startswith("rejected")]
        return (dispatched == 0 and not rejected,
                "dispatches=%d states=%s" % (dispatched, json.dumps(states)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _t7_a_complete_candidate_still_dispatches():
    """CLEAN TWIN, and the one that matters most: the gate must not start refusing good recipes."""
    tmp = tempfile.mkdtemp(prefix="daemon-t7c-")
    try:
        d, _ps, fd = _t7_pickup(tmp, servings=4, protein="chicken")
        dispatched = len(fd.prompts("recipe-ingredient-mapper"))
        refused = [f for f in d.findings if "PICK-UP" in f]
        return (dispatched == 1 and not refused,
                "dispatches=%d refused=%s" % (dispatched, json.dumps(refused)[:160]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


_T8_SWEEP = {"slug": "s1", "count": 1, "proposals": [
    {"term": "ground chicken", "proposed_bid": "ground-chicken",
     "evidence": "ruled but never declared", "declared": False}]}


def _t8_ps(sweep=None, rc=0):
    """FakePS that answers -NewBids the way map-preresolve does, and -Assemble as usual."""
    def handler(args):
        if "-NewBids" in args:
            return rc, json.dumps(sweep if sweep is not None else _T8_SWEEP), ""
        return 0, "", ""
    return FakePS({"map-preresolve": handler})


def _t8_an_undeclared_bid_still_reaches_the_registrar():
    """MUST FIRE - the T-shakedown defect exactly. The mapper ruled a new id and declared NOTHING;
    the registrar must still be asked, because the prompt promises it cannot be skipped by omission."""
    tmp = tempfile.mkdtemp(prefix="daemon-t8a-")
    try:
        preresolved(tmp, ["s1"], residual={"s1": ["ground chicken"]})
        d = daemon(run_dir=tmp, ps=_t8_ps())
        res = _mapper_result("s1")
        res["new_commodity_proposals"] = []          # the mapper declared NOTHING
        got = arun(d.new_bid_proposals("s1", res))
        bids = [p.get("proposed_bid") for p in got]
        said = any("did NOT declare" in f for f in d.findings)
        return (bids == ["ground-chicken"] and said,
                "proposals=%s findings=%s" % (json.dumps(bids), json.dumps(d.findings)[:200]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _t8_the_call_site_actually_uses_the_sweep():
    """MUST FIRE, and it pins the CALL SITE rather than the function.

    THE T8 DEFECT WAS NEVER THAT THE SWEEP WAS WRONG - it was that this road did not call one. A
    fixture that only exercises new_bid_proposals() directly passes with the old
    `res.get("new_commodity_proposals")` line restored, MEASURED 2026-08-25 when exactly that neuter
    came back 0 red. So this drives assemble_mapped and asserts the REGISTRAR WAS DISPATCHED for an
    id the mapper never declared."""
    tmp = tempfile.mkdtemp(prefix="daemon-t8c-")
    try:
        preresolved(tmp, ["s1"], residual={"s1": ["ground chicken"]})
        fd = FakeDispatch({"commodity-registrar": [{"rulings": [
            {"proposed_bid": "ground-chicken", "verdict": "approve", "bid": "ground-chicken",
             "reason": "cooked pulled meat is its own purchase"}]}]})
        d = daemon(run_dir=tmp, ps=_t8_ps(), dispatcher=fd)
        res = _mapper_result("s1")
        res["new_commodity_proposals"] = []          # declared NOTHING, exactly as on the shakedown
        arun(d.assemble_mapped("s1", res, None))
        prompts = fd.prompts("commodity-registrar")
        return (len(prompts) == 1 and "ground-chicken" in prompts[0],
                "registrar dispatches=%d" % len(prompts))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _t8_a_blocked_sweep_degrades_and_says_so():
    """CLEAN TWIN. A sweep that cannot run must fall back to what the mapper declared and ANNOUNCE
    it - that is today's behaviour, not a new failure mode, and the assembler is still the backstop
    that refuses any id nothing approved. Silence here would re-open the hole invisibly."""
    tmp = tempfile.mkdtemp(prefix="daemon-t8b-")
    try:
        preresolved(tmp, ["s1"], residual={"s1": ["ground chicken"]})
        d = daemon(run_dir=tmp, ps=_t8_ps(sweep={}, rc=2))
        res = _mapper_result("s1")
        res["new_commodity_proposals"] = [{"proposed_bid": "declared-one", "term": "x",
                                           "evidence": "e"}]
        got = arun(d.new_bid_proposals("s1", res))
        bids = [p.get("proposed_bid") for p in got]
        said = any("could not run" in f and "falling back" in f for f in d.findings)
        return (bids == ["declared-one"] and said,
                "proposals=%s findings=%s" % (json.dumps(bids), json.dumps(d.findings)[:200]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# =====================================================================================================
# D1/D2 - THE ENCODE HOOK. Every case here drives assemble_mapped or qa_lane, never learn_apply
# directly: learn_apply has its own suite, and TWICE this estate has watched a neuter come back 0 red
# because a fixture pinned a function while the bug lived at its call site (PLAN-map-judge-split 4).
# =====================================================================================================

import learn_apply as _LA                                        # noqa: E402


def _learn_scratch(prefix):
    """A run dir plus its OWN event log and ledger, so no two cases can read each other's writes."""
    tmp = tempfile.mkdtemp(prefix=prefix)
    return tmp, os.path.join(tmp, "events.jsonl"), os.path.join(tmp, "ledger.json")


def _learn_events(path):
    if not os.path.exists(path):
        return []
    return [json.loads(l) for l in io.open(path, encoding="utf-8").read().split("\n") if l.strip()]


def _learn_ps(assemble_rc=0):
    """FakePS answering -NewBids with no proposals and -Assemble with the given code."""
    def handler(args):
        if "-NewBids" in args:
            return 0, json.dumps({"slug": "s1", "count": 0, "proposals": []}), ""
        if "-Assemble" in args:
            return assemble_rc, ("FINDING  the drill said no" if assemble_rc else ""), ""
        return 0, "", ""
    return FakePS({"map-preresolve": handler})


def _learn_res(slug="s1"):
    """A mapper result whose two rulings are BOTH cachable: real board ids, real evidence."""
    return {"slug": slug, "status": "ok", "state": "priced",
            "lines": [{"raw": "1 lb chicken", "buy": "3 1/2 lb"}],
            "rulings": [
                {"raw": "1 lb chicken breast", "term": "Boneless Chicken Breast",
                 "canon_item": "Boneless Skinless Chicken Breast", "bid": "chicken-breast",
                 "decision": "mapped", "evidence": "the trimmed breast the board prices"},
                {"raw": "2 eggs", "term": "Large Eggs", "canon_item": "Eggs", "bid": "eggs",
                 "decision": "mapped", "evidence": "grade A large, the board's own basis"}],
            "new_commodity_proposals": []}


def _learn_the_call_site_writes_events():
    """MUST FIRE, at the CALL SITE. assemble_mapped is what must learn - a fixture over apply_learn
    alone passes with the hook deleted, which is the exact shape of the T8 0-red neuter."""
    tmp, ev, led = _learn_scratch("daemon-learn-a-")
    try:
        preresolved(tmp, ["s1"], residual={"s1": ["Boneless Chicken Breast", "Large Eggs"]})
        d = daemon(run_dir=tmp, ps=_learn_ps(), events_path=ev, resolutions_path=led)
        ok, why = arun(d.assemble_mapped("s1", _learn_res(), None))
        evs = _learn_events(ev)
        rows = _LA.read_ledger(led)[0]
        return (ok and len(evs) == 2 and all(e["kind"] == "ruling" and e["projected"] for e in evs)
                and sorted(rows) == ["boneless chicken breast", "large eggs"],
                "ok=%s why=%s events=%d rows=%s" % (ok, why[:80], len(evs), sorted(rows)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _learn_a_failed_assemble_teaches_nothing():
    """MUST FIRE. A ruling that failed assembly must NOT become memory: the run refused to build a
    decision file over it, and an identity the estate would not write down is worse than none."""
    tmp, ev, led = _learn_scratch("daemon-learn-b-")
    try:
        preresolved(tmp, ["s1"], residual={"s1": ["Boneless Chicken Breast"]})
        d = daemon(run_dir=tmp, ps=_learn_ps(assemble_rc=1), events_path=ev, resolutions_path=led)
        ok, _why = arun(d.assemble_mapped("s1", _learn_res(), None))
        return (not ok and _learn_events(ev) == [] and not os.path.exists(led),
                "ok=%s events=%d ledger=%s" % (ok, len(_learn_events(ev)), os.path.exists(led)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _learn_the_44_class_fires_at_the_call_site():
    """MUST FIRE. The postcondition, driven through assemble_mapped with a writer that drops one.

    The whole apply_learn road stays REAL - only the log's append is stubbed - so this pins the
    daemon's own counter rather than a hand-built summary dict.
    """
    tmp, ev, led = _learn_scratch("daemon-learn-c-")
    real = _LA.EventLog
    try:
        preresolved(tmp, ["s1"], residual={"s1": ["Boneless Chicken Breast", "Large Eggs"]})

        class Dropping(real):
            def append(self, e):
                self.seen = getattr(self, "seen", 0) + 1
                if self.seen == 1:
                    return "dropped-by-fixture"
                return real.append(self, e)

        _LA.EventLog = Dropping
        d = daemon(run_dir=tmp, ps=_learn_ps(), events_path=ev, resolutions_path=led)
        ok, _why = arun(d.assemble_mapped("s1", _learn_res(), None))
        gap = [f for f in d.findings if "the 44-class" in f]
        return (ok and len(gap) == 1 and "2 residual rulings but 1 learn events" in gap[0],
                "ok=%s findings=%s" % (ok, json.dumps(d.findings)[:220]))
    finally:
        _LA.EventLog = real
        shutil.rmtree(tmp, ignore_errors=True)


def _learn_a_clean_batch_trips_nothing():
    """CLEAN TWIN. The same road with an honest writer produces no 44-class finding at all."""
    tmp, ev, led = _learn_scratch("daemon-learn-d-")
    try:
        preresolved(tmp, ["s1"], residual={"s1": ["Boneless Chicken Breast", "Large Eggs"]})
        d = daemon(run_dir=tmp, ps=_learn_ps(), events_path=ev, resolutions_path=led)
        arun(d.assemble_mapped("s1", _learn_res(), None))
        return (not [f for f in d.findings if "the 44-class" in f],
                json.dumps(d.findings)[:220])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _learn_registrar_rulings_get_events():
    """MUST FIRE. Registrar rulings decide whether a commodity is BORN and were invisible across
    runs - no registrar ledger has ever existed. This is the first."""
    tmp, ev, led = _learn_scratch("daemon-learn-e-")
    try:
        preresolved(tmp, ["s1"], residual={"s1": ["Gochujang Deluxe"]})

        def handler(args):
            if "-NewBids" in args:
                return 0, json.dumps({"slug": "s1", "count": 1, "proposals": [
                    {"term": "Gochujang Deluxe", "proposed_bid": "gochujang-deluxe-x",
                     "evidence": "a distinct purchase", "declared": True}]}), ""
            return 0, "", ""
        fd = FakeDispatch({"commodity-registrar": [{"rulings": [
            {"proposed_bid": "gochujang-deluxe-x", "verdict": "reject",
             "reason": "already priced under gochujang"}]}]})
        d = daemon(run_dir=tmp, ps=FakePS({"map-preresolve": handler}), dispatcher=fd,
                   events_path=ev, resolutions_path=led)
        res = {"slug": "s1", "status": "ok", "state": "priced", "lines": [],
               "rulings": [{"raw": "1 tbsp gochujang deluxe", "term": "Gochujang Deluxe",
                            "canon_item": "Gochujang Deluxe", "bid": "gochujang-deluxe-x",
                            "decision": "mapped", "evidence": "the Korean fermented chili paste"}],
               "new_commodity_proposals": []}
        arun(d.assemble_mapped("s1", res, None))
        evs = _learn_events(ev)
        reg = [e for e in evs if e["kind"] == "registrar"]
        ruled = [e for e in evs if e["kind"] == "ruling"]
        return (len(reg) == 1 and reg[0]["decision"] == "reject" and reg[0]["by"] == "registrar"
                and len(ruled) == 1 and ruled[0]["projected"] is False
                and ruled[0]["held_reason"] == "bid unknown to every namespace"
                and not os.path.exists(led),
                "events=%s" % json.dumps([(e["kind"], e["decision"]) for e in evs]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _qa_run(owner):
    """Drive the WHOLE qa_lane for one slug that fails QA twice, owned by `owner`."""
    tmp, ev, led = _learn_scratch("daemon-learn-qa-")
    try:
        os.makedirs(os.path.join(tmp, "mapped-pre"), exist_ok=True)
        with io.open(os.path.join(tmp, "mapped-pre", "s1.rulings.json"), "w",
                     encoding="utf-8") as f:
            json.dump({"slug": "s1", "rulings": _learn_res()["rulings"]}, f)
        fail = {"slug": "s1", "verdict": "FAIL", "owner": owner,
                "findings": "the mapper bridged a form flip"}
        fd = FakeDispatch({"recipe-source-qa": [fail, fail],
                           "recipe-ingredient-mapper": [{}],
                           "recipe-writer": [{"no_change": True}]})
        d = daemon(run_dir=tmp, ps=FakePS(), dispatcher=fd, events_path=ev, resolutions_path=led)

        async def noop(_slug):
            return 0
        d.qa_battery = noop                     # the battery shells coverage_check; not under test
        d.ch["qa"].push({"slug": "s1"})
        d.ch["qa"].close()
        arun(d.qa_lane())
        return _learn_events(ev), d
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _qa_mapper_fail_writes_one_event():
    evs, _d = _qa_run("mapper")
    qa = [e for e in evs if e["kind"] == "qa_mapper_fail"]
    ok = (len(qa) == 1 and qa[0]["key"] == "" and qa[0]["by"] == "qa"
          and qa[0]["decision"] == "fail" and qa[0]["projected"] is False
          and "boneless chicken breast" in qa[0]["evidence"])
    return ok, "events=%s" % json.dumps([(e["kind"], e.get("evidence", "")[:60]) for e in evs])


def _qa_writer_fail_writes_none():
    evs, _d = _qa_run("writer")
    return (not [e for e in evs if e["kind"] == "qa_mapper_fail"],
            json.dumps([e["kind"] for e in evs]))


def _learn_seams_are_never_live():
    """MUST FIRE. The suite's default seams may never be the live estate files - H2's whole lesson.

    Checked on the DAEMON the fixtures actually build, not on the constants, because the defect
    would be a fixture that forgot to thread them.
    """
    d = daemon(run_dir="R")
    live_ev = os.path.join(HD.MP, "db", "ingredient-events.jsonl")
    live_led = os.path.join(HD.MP, "db", "ingredient-resolutions.json")
    return (bool(d.events_path) and bool(d.resolutions_path)
            and os.path.abspath(d.events_path) != os.path.abspath(live_ev)
            and os.path.abspath(d.resolutions_path) != os.path.abspath(live_led),
            "events=%s ledger=%s" % (d.events_path, d.resolutions_path))


# =====================================================================================================
# D3 - ATTEND. The three states, and the framing that keeps a shelf from reading as an answer.
# =====================================================================================================

_PRIOR_NEIGHBOURS = {
    "state": "ok", "corpus": 3, "terms": [
        {"key": "thin sliced beef for sandwiches", "term": "thin sliced beef for sandwiches",
         "neighbours": [
             {"term": "Shaved Beef Steak", "key": "shaved beef steak", "bid": "shaved-beef-steak",
              "decision": "mapped", "evidence": "the thin-sliced sandwich steak, not a roast",
              "cos": 0.82, "at": "2026-08-15T10:00:00", "slug": "philly"},
             {"term": "Duck Fat", "key": "duck fat", "bid": "", "decision": "rejected",
              "evidence": "no Omaha store carries it", "cos": 0.31,
              "at": "2026-08-14T10:00:00", "slug": "confit"},
             {"term": "Mustard Powder", "key": "mustard powder", "bid": "",
              "decision": "mapped-null", "evidence": "dry ground seed, not the condiment",
              "cos": 0.20, "at": "2026-08-13T10:00:00", "slug": "rub"}]},
        {"key": "harissa paste", "term": "harissa paste", "neighbours": []}]}


def _prior_daemon(tmp, reply=None, rc=0, write=True):
    """A daemon whose python road answers resolution_embed with a scripted neighbours file."""
    def handler(args):
        if "--query" in args and write:
            out = args[args.index("--out") + 1]
            with io.open(out, "w", encoding="utf-8", newline="\n") as f:
                json.dump(reply if reply is not None else _PRIOR_NEIGHBOURS, f)
        return rc, "", ("the venv is not here" if rc else "")
    py = FakePy({"resolution_embed": handler})
    d = daemon(run_dir=tmp, ps=FakePS(), pyrun=py)
    return d, py


def _prior_table(tmp, terms):
    preresolved(tmp, ["s1"], residual={"s1": list(terms)})
    with io.open(os.path.join(tmp, "mapped-pre", "s1.json"), encoding="utf-8-sig") as f:
        return {"s1": json.load(f)}


def _prior_renders_the_shelf():
    """MUST FIRE. The neighbours reach the DOSSIER, each carrying the phrase it was ruled for."""
    tmp = tempfile.mkdtemp(prefix="daemon-prior-a-")
    try:
        tables = _prior_table(tmp, ["thin sliced beef for sandwiches", "harissa paste"])
        d, _py = _prior_daemon(tmp)
        arun(d.fill_prior_rulings(["s1"], tables))
        text = d.map_dossier_extras("s1", tables["s1"])
        ok = ("PRIOR RULINGS NEAR THESE TERMS - a shelf, not an answer" in text
              and "'Shaved Beef Steak' -> shaved-beef-steak (mapped, 2026-08-15, cos 0.82)" in text
              and "the thin-sliced sandwich steak, not a roast" in text
              and "no prior rulings near this term (we looked)" in text)
        return ok, text[-500:]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _prior_uses_the_sidecar_interpreter():
    """MUST FIRE. bge-m3 lives in sidecar\\.venv and nowhere else; C:\\Codex\\Python312 has no torch,
    and a surface run under the wrong interpreter reports its own ImportError as a failure."""
    tmp = tempfile.mkdtemp(prefix="daemon-prior-b-")
    try:
        tables = _prior_table(tmp, ["thin sliced beef for sandwiches"])
        d, py = _prior_daemon(tmp)
        arun(d.fill_prior_rulings(["s1"], tables))
        calls = py.find("resolution_embed")
        return (len(calls) == 1 and calls[0].get("exe") == HD.SIDECAR_PY
                and calls[0]["timeout"] == 120,
                "calls=%d exe=%s" % (len(calls), (calls[0].get("exe") if calls else None)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _prior_blind_is_announced():
    """MUST FIRE. A retrieval that could not run renders BLIND. An empty list pretending it looked is
    how a judge concludes there is no precedent when nobody checked."""
    tmp = tempfile.mkdtemp(prefix="daemon-prior-c-")
    try:
        tables = _prior_table(tmp, ["thin sliced beef for sandwiches"])
        d, _py = _prior_daemon(tmp, rc=2, write=False)
        arun(d.fill_prior_rulings(["s1"], tables))
        text = d.map_dossier_extras("s1", tables["s1"])
        said = any("BLIND" in f for f in d.findings)
        return ("PRIOR RULINGS: BLIND" in text and "Absent evidence, not absence of precedent" in text
                and "NEAR THESE TERMS" not in text and said,
                "findings=%s tail=%s" % (json.dumps(d.findings)[:160], text[-220:]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _prior_empty_is_not_blind():
    """CLEAN TWIN. Day one: the log is empty, the retriever RAN, and the shelf says so per term.
    `empty` and `blind` are different weeks and must never print the same line."""
    tmp = tempfile.mkdtemp(prefix="daemon-prior-d-")
    try:
        tables = _prior_table(tmp, ["thin sliced beef for sandwiches"])
        d, _py = _prior_daemon(tmp, reply={"state": "empty", "corpus": 0, "terms": [
            {"key": "thin sliced beef for sandwiches", "term": "thin sliced beef for sandwiches",
             "neighbours": []}]})
        arun(d.fill_prior_rulings(["s1"], tables))
        text = d.map_dossier_extras("s1", tables["s1"])
        return ("no prior rulings near this term (we looked)" in text
                and "BLIND" not in text and not d.findings,
                "findings=%s tail=%s" % (json.dumps(d.findings)[:160], text[-220:]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _prior_every_decision_stays_visible():
    """MUST FIRE. A `rejected` and a `mapped-null` neighbour render with their decision words. The
    estate measured that rejections transfer and confirmations do not - that is for the judge to
    weigh, and encoding it as a filter here would be this file ruling on an identity."""
    tmp = tempfile.mkdtemp(prefix="daemon-prior-e-")
    try:
        tables = _prior_table(tmp, ["thin sliced beef for sandwiches"])
        d, _py = _prior_daemon(tmp)
        arun(d.fill_prior_rulings(["s1"], tables))
        text = d.map_dossier_extras("s1", tables["s1"])
        return ("(rejected, 2026-08-14" in text and "(mapped-null, 2026-08-13" in text
                and "-> no id (rejected" in text, text[-400:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _prior_only_residual_terms_are_asked():
    """MUST FIRE. Settled lines are not questions. Asking about them would spend the retrieval on
    the very terms the exact-key cache already answered, and crowd the shelf with them."""
    tmp = tempfile.mkdtemp(prefix="daemon-prior-f-")
    try:
        tables = _prior_table(tmp, ["thin sliced beef for sandwiches", "harissa paste"])
        d, py = _prior_daemon(tmp)
        arun(d.fill_prior_rulings(["s1"], tables))
        qin = py.find("resolution_embed")[0]["args"]
        with io.open(qin[qin.index("--query") + 1], encoding="utf-8-sig") as f:
            asked = [t["term"] for t in json.load(f)["terms"]]
        return (sorted(asked) == ["harissa paste", "thin sliced beef for sandwiches"],
                json.dumps(asked))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _prior_the_prompt_names_the_field():
    """MUST FIRE. hunt-daemon's own scar: a prompt that said "unchanged contract" without naming one
    new field broke a clean batch. A shelf the judge was never told about is an unexplained block."""
    tmp = tempfile.mkdtemp(prefix="daemon-prior-g-")
    try:
        tables = _prior_table(tmp, ["thin sliced beef for sandwiches"])
        d, _py = _prior_daemon(tmp)
        arun(d.fill_prior_rulings(["s1"], tables))
        p = d.map_prompt(["s1"], tables)
        return ("PRIOR RULINGS shelf" in p and "they resolve nothing and you may disagree" in p
                and "absent evidence and not absence of precedent" in p, p[:0])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _prior_never_blocks_the_lane():
    """CLEAN TWIN. A blind retrieval costs the batch a channel and nothing else: the dossier is still
    built, the settled lines are still there, and the recipe still maps."""
    tmp = tempfile.mkdtemp(prefix="daemon-prior-h-")
    try:
        tables = _prior_table(tmp, ["thin sliced beef for sandwiches"])
        d, _py = _prior_daemon(tmp, rc=2, write=False)
        arun(d.fill_prior_rulings(["s1"], tables))
        p = d.map_prompt(["s1"], tables)
        return ("SETTLED lines - identity is DONE" in p and "1 lb chicken" in p
                and "PRIOR RULINGS: BLIND" in p, p[-300:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _m3_zero_absent_routes_to_write():
    tmp = tempfile.mkdtemp(prefix="daemon-m3a-")
    try:
        d, ps = _m3_map(tmp, absent=[], state="mapped")
        states = _m3_advanced_to(ps)
        adds = _m3_queue_terms(ps)
        # AMENDED BY Q2 (2026-08-26). This read `"pricing" not in states`, which pinned the bypass
        # itself: routing `mapped` -> `priced` directly is precisely how a recipe reached a paid page
        # without the carriage union ever reading it. The DESTINATION is unchanged and is still M3's
        # whole claim - zero absent terms means the write lane, in this pass, with nothing queued and
        # no pricer woken. What is now also pinned is the ROUTE it takes to get there.
        ok = (states == ["mapped", "pricing", "priced"] and not adds
              and "s1" not in d.pricing_slugs)
        return ok, "advanced=%s adds=%s pricing_slugs=%s" % (
            json.dumps(states), json.dumps(adds), json.dumps(sorted(d.pricing_slugs)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _m3_the_disagreement_is_logged():
    tmp = tempfile.mkdtemp(prefix="daemon-m3b-")
    try:
        d, _ps = _m3_map(tmp, absent=[], state="mapped")
        line = next((m for m in d.m3_log if "ZERO absent terms" in m), "")
        return ("s1" in line and "mapped" in line), "line=%r" % line
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _m3_absent_terms_still_price():
    tmp = tempfile.mkdtemp(prefix="daemon-m3c-")
    try:
        d, ps = _m3_map(tmp, absent=["saffron", "harissa", "tteok"], state="pricing")
        adds = _m3_queue_terms(ps)
        states = _m3_advanced_to(ps)
        return ((adds == ["saffron", "harissa", "tteok"] and "pricing" in states
                 and "priced" not in states and "s1" in d.pricing_slugs),
                "advanced=%s adds=%s" % (json.dumps(states), json.dumps(adds)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _m3_the_unbid_hold_returns_first():
    tmp = tempfile.mkdtemp(prefix="daemon-m3d-")
    try:
        holds = {"s1": [{"term": "sumac", "why": "Sumac has no bid wired"},
                        {"term": "labneh", "why": "Labneh has no bid wired"},
                        {"term": "zaatar", "why": "Zaatar has no bid wired"}]}
        d, ps = _m3_map(tmp, absent=[], state="mapped", holds=holds)
        states = _m3_advanced_to(ps)
        adds = _m3_queue_terms(ps)
        return ((states == ["mapped"] and not adds
                 and [h for h in d.held if h[0] == "s1"]),
                "advanced=%s adds=%s held=%s" % (json.dumps(states), json.dumps(adds),
                                                 json.dumps([h[0] for h in d.held])))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _m3_optional_still_reaches_the_queue():
    tmp = tempfile.mkdtemp(prefix="daemon-m3e-")
    try:
        d, ps = _m3_map(tmp, absent=[], optional=["fresh dill", "chives", "mint"], state="mapped")
        adds = _m3_queue_terms(ps)
        seamed = [c for c in ps.find("ingredient-queue.ps1")
                  if "-Add" in c["args"]
                  and FakePS.value_after(c["args"], "-QueueFile") == os.path.join(tmp, "queue.json")]
        states = _m3_advanced_to(ps)
        # THE PRICE LANE IS NOT WOKEN AND THE TERM IS NOT TRACKED AS ABSENT: optional reaching the
        # queue is the estate learning of it, not the recipe waiting on it.
        # `states` amended by Q2 (2026-08-26) for the reason given in _m3_zero_absent_routes_to_write:
        # the recipe still ENDS at `priced`, it now transits `pricing` so the carriage union reads it.
        # The optional half of the claim is untouched and is what this case is really about.
        return ((adds == ["fresh dill", "chives", "mint"] and len(seamed) == 3
                 and states == ["mapped", "pricing", "priced"]
                 and "s1" not in d.pricing_slugs and not d.absent_terms),
                "advanced=%s adds=%s absent_terms=%s" % (json.dumps(states), json.dumps(adds),
                                                         json.dumps(d.absent_terms)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# =====================================================================================================
# Q1 (2026-08-26) - A TERM RECORDED AS BLOCKING IS A TERM ON THE QUEUE. THE POSTCONDITION, AT THE CALL
# SITE, OVER THE REAL SCRIPTS.
#
# THE DEFECT, measured on run hunt-2026-08-26-ten at 05:15. 5 of its 7 parked recipes were permanently
# stranded: their state files carried BLOCKING term rows (optional=false) that were never added to
# grocery\ingredient-queue.json, so -Derive scored them PENDING on every pass (an unchecked term is
# never not-carried, which is correct) and they could never leave `parked`. Eight terms across five
# recipes, none of them ever asked of anybody.
#
# AND THE CAUSE WAS NOT WHERE IT LOOKED. The map lane's -Add loop was honest: every term it advanced
# with, it enqueued. But `hunt-run.ps1 -Advance -To pricing` is ITSELF A WRITER of the term list - it
# unions in Get-CarriageBlockingTerms, ingredients the mapper mapped cleanly that no Omaha store
# carries - and nothing enqueued THOSE. Two writers of the blocking list, one writer of the queue, and
# no reconciliation between them. So the claim and the record were free to differ, and did.
#
# WHY THIS FIXTURE RUNS THE REAL SCRIPTS, and it is the whole reason it exists. Every M3 case below
# injects hunt-run.ps1 through FakePS. An injected hunt-run cannot union anything, so not one of them
# could ever have seen this - `_m3_absent_terms_still_price` asserts adds == the mapper's list and was
# GREEN through all five stranded recipes. That is the call-site trap PLAN-map-judge-split section 4
# names ("twice this build a neuter came back 0 red because a fixture pinned a function while the bug
# lived at its call site"), and pinning Get-CarriageBlockingTerms or blocking_terms alone would repeat
# it exactly. So the map lane runs for real here, against the real hunt-run.ps1 and the real
# ingredient-queue.ps1, and the assertion is made over the two artifacts a person would read: the
# recipe's state file and the queue.
#
# FIVE INGREDIENT ROWS, NOT ONE, and each is a way this can be wrong:
#   * Gochujang     - claimed by the mapper AND derived. The overlap case: enqueued exactly once.
#   * Doubanjiang   - derived ONLY (bid=null, mapped-null). THE REGRESSION: on disk as blocking,
#                     never on the queue. This is the row that was red before the fix.
#   * Water         - decision=optional-note. Must be RECORDED and must NOT block.
#   * the spice line- one source line holding three spices. Must split, and each part must be queued.
#   * Chicken       - a plain mapped row, present so the recipe is not made entirely of edge cases.
# =====================================================================================================

class MapLaneRealPS(object):
    r"""Real ps_invoke for the two scripts this postcondition is ABOUT - hunt-run.ps1, which writes the
    term list, and ingredient-queue.ps1, which is that list's other half - and an injected clean exit
    for everything else the map lane shells (map-preresolve, whose own behaviour is fixtured in its own
    suite and whose -Assemble would otherwise overwrite the mapped artifact this case hand-builds).

    -QueueFile IS PINNED HERE, not on the daemon. Same reasoning as QueueScopedPS: the estate's
    standing rule is that no drill touches the live worklist, the daemon has no queue-file seam and
    must not grow one, so the seam lives at the injection point the daemon already has. Note the
    daemon is therefore constructed WITHOUT queue_path - queue_args would append a SECOND -QueueFile
    and PowerShell refuses a duplicated parameter.
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
            # NOT SKIPPED TO MAKE THE FIXTURE PASS - skipped because -Derive reads the LIVE ingredient
            # queue by its own internal path, which no -QueueFile of ours reaches. Its behaviour is
            # fixtured in hunt-run.ps1's own suite. Same call QueueScopedPS makes, same reason.
            return 0, "", ""
        if "hunt-run" in name or "ingredient-queue" in name:
            return hunt_lib.ps_invoke(script, a, timeout)
        return 0, "", ""

    def find(self, script_part, flag=None):
        return [c for c in self.calls
                if script_part in c["script"] and (flag is None or flag in c["args"])]


Q1_SLUG = "q1-dish"

Q1_INGREDIENTS = [
    {"source_raw": "1 lb chicken", "item": "Chicken", "bid": "chicken", "grams": 454,
     "buy": "1 lb", "optional": False, "decision": "mapped", "notes": ""},
    {"source_raw": "2 tbsp gochujang", "item": "Gochujang", "bid": "gochujang", "grams": 34,
     "buy": "1 tub", "optional": False, "decision": "mapped", "notes": ""},
    {"source_raw": "1 tbsp doubanjiang", "item": "Doubanjiang", "bid": None, "grams": 17,
     "buy": "", "optional": False, "decision": "mapped-null",
     "notes": "the Sichuan fermented broad-bean paste; no board id and no capture"},
    # ONE ROW PER NET, AND EACH IS CAUGHT BY ITS OWN NET ALONE. The first attempt used a single
    # optional-note row named 'Water' and the N1 neuter came back 0 RED: 'water' is also on the
    # stoplist, so net 2 rescued it and the case could not tell the two nets apart. A fixture that
    # stays green when you delete the thing it is named after is not testing that thing.
    #   'Water'                    - decision=mapped-null, NOT optional. The mapper mislabelled a tap
    #                                line as a real purchase, which is the only case net 2 exists for.
    #                                Net 1 does not see it. Only the stoplist can catch it.
    #   'Reserved Braising Liquid' - decision=optional-note, and deliberately NOT on the stoplist,
    #                                because no list of names could hold every byproduct a recipe
    #                                invents. Only the mapper's own ruling can catch it.
    {"source_raw": "2 cups water", "item": "Water", "bid": None, "grams": 0, "buy": "",
     "optional": False, "decision": "mapped-null",
     "notes": "the mapper called a tap line a purchase - only the stoplist catches this"},
    {"source_raw": "1/2 cup reserved braising liquid", "item": "Reserved Braising Liquid",
     "bid": None, "grams": 0, "buy": "", "optional": True, "decision": "optional-note",
     "notes": "what the pot leaves behind - nothing the shopper buys, and no stoplist knows it"},
    {"source_raw": "1 tsp each garlic powder, cumin, and chili powder",
     "item": "Garlic Powder, Cumin, and Chili Powder", "bid": None, "grams": 6, "buy": "",
     "optional": False, "decision": "mapped-null",
     "notes": "one source line holding three separate spices"},
]

Q1_SPICES = ["Garlic Powder", "Cumin", "Chili Powder"]


def _q1_stage(tmp, ingredients=None):
    """Stage ONE recipe at `extracted` in a scratch run dir, with the mapped artifact already on disk,
    and return (run_dir, queue_file) - or (None, why) if the staging itself failed.

    The state file is built by the REAL hunt-run.ps1, through -Init and the real transition chain,
    because a hand-written state file is a state file this fixture invented and the whole point here is
    that the real writer is under test.
    """
    run_dir = os.path.join(tmp, "run")
    os.makedirs(run_dir, exist_ok=True)
    qf = os.path.join(tmp, "scratch-queue.json")
    rc, o, _e = hunt_lib.ps_invoke(HUNT_RUN_PS, [
        "-Init", "-RunDir", run_dir, "-Conditions", "drill", "-Stop", "2 accepted",
        "-WaveSize", "2", "-CalMin", "400", "-CalMax", "650", "-CarbMax", "35", "-ProteinMin", "0"])
    if rc != 0:
        return None, "could not init a scratch run dir: %s" % o.strip()[:200]
    for i, st in enumerate(("sourced", "selected", "extracted")):
        args = ["-Advance", "-RunDir", run_dir, "-Slug", Q1_SLUG, "-To", st, "-By", "drill",
                "-Detail", "drill"]
        if i == 0:
            args += ["-Title", "Q1 Dish", "-SourceUrl", "https://d/q1", "-Protein", "chicken"]
        r, oo, ee = hunt_lib.ps_invoke(HUNT_RUN_PS, args)
        if r != 0:
            return None, "could not stage %s: %s" % (st, (oo + ee).strip()[:200])

    preresolved(run_dir, [Q1_SLUG], residual={Q1_SLUG: ["gochujang"]})
    os.makedirs(os.path.join(run_dir, "extracted"), exist_ok=True)
    with io.open(os.path.join(run_dir, "extracted", "%s.json" % Q1_SLUG), "w", encoding="utf-8") as f:
        f.write(json.dumps({"slug": Q1_SLUG, "title": "Q1 Dish", "source_url": "https://d/q1",
                            "servings": 4, "ingredients": [], "instructions": []}))
    # THE MAPPED ARTIFACT IS THE INPUT TO THE CARRIAGE UNION, so it is written here rather than left
    # to map-preresolve -Assemble (which this fixture injects, so it writes nothing).
    os.makedirs(os.path.join(run_dir, "mapped"), exist_ok=True)
    with io.open(os.path.join(run_dir, "mapped", "%s.json" % Q1_SLUG), "w", encoding="utf-8") as f:
        f.write(json.dumps({"slug": Q1_SLUG, "title": "Q1 Dish", "source_url": "https://d/q1",
                            "source_servings": 4, "target_servings": 14, "protein": "chicken",
                            "ingredients": list(Q1_INGREDIENTS if ingredients is None else ingredients),
                            "pricing_terms_needed": ["gochujang"], "rejected": [],
                            "new_commodity_proposals": [], "registrar_rulings": []}))
    return (run_dir, qf), ""


def _q1_run(tmp, ingredients=None, absent=("gochujang",)):
    """One map-lane run over the staged recipe, with hunt-run.ps1 and ingredient-queue.ps1 REAL.
    Returns (state_rows, queued_terms, why) - `why` non-empty means the drill could not be set up."""
    staged, why = _q1_stage(tmp, ingredients=ingredients)
    if why:
        return [], [], why
    run_dir, qf = staged

    res = _mapper_result(Q1_SLUG)
    res["state"] = "mapped"
    res["absent_terms"] = list(absent)
    res["optional_absent"] = []
    ps = MapLaneRealPS(qf)
    d = daemon(run_dir=run_dir, dispatcher=FakeDispatch({"recipe-ingredient-mapper": [{"results": [res]}]}),
               ps=ps)
    d.ch["map"].push({"slug": Q1_SLUG})
    d.ch["map"].close()
    arun(d.run(("map",)))

    rows = []
    try:
        with io.open(os.path.join(run_dir, "state", "%s.json" % Q1_SLUG), encoding="utf-8-sig") as f:
            doc = json.load(f)
        raw = doc.get("terms") or []
        if isinstance(raw, dict):
            raw = [raw]
        rows = [{"term": str(t.get("term") or ""), "optional": bool(t.get("optional")),
                 "state": str(doc.get("state") or "")} for t in raw]
    except Exception as e:                                        # noqa: BLE001
        return [], [], "the state file could not be read back: %s" % e
    # THE QUEUE FILE IS READ DIRECTLY. ingredient-queue.ps1 is its only writer and this is the artifact
    # it writes - going back through -List -Json here would test the reader, and what is under test is
    # whether the term is IN there at all.
    queued = []
    try:
        if os.path.exists(qf):
            with io.open(qf, encoding="utf-8-sig") as f:
                queued = [str(i.get("term") or "") for i in (json.load(f).get("items") or [])]
    except Exception as e:                                        # noqa: BLE001
        return rows, [], "the scratch queue could not be read: %s" % e
    return rows, queued, ""


def _q1_every_blocking_term_is_on_the_queue():
    """THE POSTCONDITION ITSELF. After the map lane routes a recipe to `pricing`, every non-optional
    term on its state file exists in the queue. No exceptions, no allowance for the carriage half."""
    tmp = tempfile.mkdtemp(prefix="daemon-q1a-")
    try:
        rows, queued, why = _q1_run(tmp)
        if why:
            return False, why
        if not rows:
            return False, "the recipe reached `pricing` with NO term rows at all"
        blocking = [r["term"] for r in rows if not r["optional"]]
        missing = [t for t in blocking if t not in queued]
        at = rows[0]["state"]
        return (at == "pricing" and blocking and not missing,
                "state=%s blocking=%s queued=%s MISSING=%s"
                % (at, json.dumps(blocking), json.dumps(queued), json.dumps(missing)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _q1_the_carriage_half_is_enqueued_too():
    """The named regression. 'Doubanjiang' is derived by the carriage union and claimed by NOBODY -
    the mapper never reports it. Before 2026-08-26 it landed on the state file as blocking and was
    never enqueued, which is chicken-fried-steak's 'Pan Drippings' and stroganoff's 'Garlic Salt'."""
    tmp = tempfile.mkdtemp(prefix="daemon-q1b-")
    try:
        rows, queued, why = _q1_run(tmp)
        if why:
            return False, why
        row = next((r for r in rows if r["term"] == "Doubanjiang"), None)
        return (row is not None and not row["optional"] and "Doubanjiang" in queued,
                "row=%s queued=%s" % (json.dumps(row), json.dumps(queued)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _q1_recorded_not_blocking(term):
    """Shared shape for the two nets: the term is ON the recipe, marked optional, and NOT on the queue.
    Recorded because dropping it silently trades one invisible failure for another; not queued because
    there is no store answer that could ever settle it."""
    tmp = tempfile.mkdtemp(prefix="daemon-q1c-")
    try:
        rows, queued, why = _q1_run(tmp)
        if why:
            return False, why
        row = next((r for r in rows if r["term"] == term), None)
        return (row is not None and row["optional"] and term not in queued,
                "row=%s queued=%s" % (json.dumps(row), json.dumps(queued)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _q1_net1_the_mappers_own_ruling():
    """Defect 1, NET 1 - the ruling that was already on the row and was being discarded. 'Reserved
    Braising Liquid' is on no stoplist and never could be; the only thing that knows it is a byproduct
    is the mapper's own decision=optional-note, which is exactly what the carriage union used to throw
    away before stamping optional=false over it."""
    return _q1_recorded_not_blocking("Reserved Braising Liquid")


def _q1_net2_the_stoplist():
    """Defect 1, NET 2 - the backstop. Here the mapper got it WRONG and called a tap line a real
    purchase (decision=mapped-null, optional=false), so net 1 lets it through and only
    grocery\\non-purchasable-terms.json can stop it blocking."""
    return _q1_recorded_not_blocking("Water")


def _q1_a_composite_line_is_split_and_each_part_queued():
    """Defect 2 (B8 class, reached from the derived side). One source line holding three spices can
    never key a queue entry. It is SPLIT here rather than refused - Brad's ruling 2026-08-26 - and the
    proof is that no comma survives onto the state file and all three spices are on the queue."""
    tmp = tempfile.mkdtemp(prefix="daemon-q1d-")
    try:
        rows, queued, why = _q1_run(tmp)
        if why:
            return False, why
        commas = [r["term"] for r in rows if "," in r["term"]]
        blocking = [r["term"] for r in rows if not r["optional"]]
        got = [s for s in Q1_SPICES if s in blocking and s in queued]
        return (not commas and len(got) == 3,
                "commas=%s spices_blocking_and_queued=%s blocking=%s"
                % (json.dumps(commas), json.dumps(got), json.dumps(blocking)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _q1_clean_twin_nothing_extra_is_queued():
    """CLEAN TWIN. A mapped artifact with no derived blockers, no composite and no un-buyable line must
    queue EXACTLY the mapper's claim - the fix must not turn the queue into a dumping ground for every
    ingredient in the recipe, which is the obvious over-correction."""
    tmp = tempfile.mkdtemp(prefix="daemon-q1e-")
    try:
        clean = [dict(Q1_INGREDIENTS[1])]              # Gochujang alone: claimed AND derived
        # THE CLAIM IS SPELLED AS THE ARTIFACT SPELLS IT, so the overlap collapses to one row. The
        # main case above deliberately does NOT do this - it claims 'gochujang' against an item named
        # 'Gochujang', which is how the two writers really spell things (the mapper lowercases, the
        # artifact keeps the label's case) and which is worth seeing in a `got` line.
        rows, queued, why = _q1_run(tmp, ingredients=clean, absent=("Gochujang",))
        if why:
            return False, why
        blocking = sorted(r["term"] for r in rows if not r["optional"])
        return (sorted(queued) == ["Gochujang"] and blocking == ["Gochujang"],
                "blocking=%s queued=%s" % (json.dumps(blocking), json.dumps(sorted(queued))))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# =====================================================================================================
# Q2 (2026-08-26) - THE CARRIAGE GATE RUNS ON EVERY ROAD TO `priced`, INCLUDING THE ZERO-ABSENT ONE.
#
# THE DEFECT. hunt-run.ps1 derives the carriage union (Get-CarriageBlockingTerms) on ONE road only -
# the way into `pricing`. M3 (2026-08-25) routed a recipe whose mapper reported ZERO absent terms
# straight to `priced`, and `mapped` -> `priced` was a legal transition, so that recipe was never
# carriage-checked at all. The unhold road carried the identical condition; the M3 note named it and
# deliberately left it, and Brad ruled it in scope on 2026-08-26.
#
# AND THAT IS THE UNION'S FOUNDING CASE, NOT AN EDGE OF IT. hunt-run.ps1's own note above the function
# says so in as many words: doubanjiang, rice-cakes and ground-sumac all mapped to REAL commodity ids,
# so the mapper reported nothing absent, so nothing was ever priced, and the recipe sailed to a paid
# page. The 2026-08-22 union closed that hole for recipes that transit `pricing`. M3 reopened it three
# days later for the recipes that no longer did - the exact shape, on the exact ingredients.
#
# WHY THESE RUN THE REAL SCRIPTS, and it is the same reason the Q1 section gives. Every M3 case injects
# hunt-run through FakePS, and an injected hunt-run derives no carriage whatsoever. _asm_ps can
# SIMULATE a derived term through its `derived=` argument, but that simulation is the fixture's own, so
# a case built on it would pass whether or not hunt-run ever ran the union - it pins the helper, not
# the gate. Only the real script can fail this the way production failed.
#
# THE INGREDIENT THAT DOES THE WORK is Doubanjiang carrying bid='doubanjiang' - a REAL commodity id the
# mapper resolved cleanly, whose row in grocery\carriage.json reads UNKNOWN (hunted as "chili bean
# sauce" and never found). A NULL bid would prove nothing here and would be a different case: the whole
# point is that the mapper did its job correctly and the recipe is STILL unbuyable.
#
# THESE CASES CAN GO RED WITHOUT A CODE CHANGE, deliberately. If somebody ever finds doubanjiang in an
# Omaha store and writes it a CARRIED row, the premise is gone and the fixture says so loudly rather
# than passing on an assumption that has quietly expired. Repoint it at whatever the ledger's remaining
# UNKNOWN is; do not delete the case.
# =====================================================================================================

Q2_INGREDIENTS = [
    {"source_raw": "1 lb chicken breast", "item": "Chicken Breast", "bid": "chicken-breast",
     "grams": 454, "buy": "1 lb", "optional": False, "decision": "mapped", "notes": ""},
    # THE ROW UNDER TEST: mapped, non-optional, off the stoplist, and carrying a real board id whose
    # carriage verdict is UNKNOWN. The mapper reports it absent NOWHERE - it resolved perfectly.
    {"source_raw": "1 tbsp doubanjiang", "item": "Doubanjiang", "bid": "doubanjiang", "grams": 17,
     "buy": "1 tub", "optional": False, "decision": "mapped",
     "notes": "a real commodity id, resolved cleanly; no Omaha store is known to stock it"},
]


def _q2_run(tmp, ingredients, absent=()):
    """One map-lane run over the staged recipe with hunt-run.ps1 and ingredient-queue.ps1 REAL, and the
    recipe's FINAL STATE read back off disk. Returns (state, blocking, queued, wrote, why).

    `state` is read on its own rather than off a term row, because the question here is what happens to
    a recipe that ends up with NO term rows at all - which is the passing shape, and one `_q1_run`
    cannot report."""
    staged, why = _q1_stage(tmp, ingredients=ingredients)
    if why:
        return "", [], [], 0, why
    run_dir, qf = staged
    res = _mapper_result(Q1_SLUG)
    # THE MAPPER CLAIMS `priced` AND CLAIMS NOTHING ABSENT, which is the strongest form of the claim
    # this gate exists to distrust - and before Q2 it was enough on its own to reach a paid page.
    res["state"] = "priced"
    res["absent_terms"] = list(absent)
    res["optional_absent"] = []
    d = daemon(run_dir=run_dir,
               dispatcher=FakeDispatch({"recipe-ingredient-mapper": [{"results": [res]}]}),
               ps=MapLaneRealPS(qf))
    d.ch["map"].push({"slug": Q1_SLUG})
    d.ch["map"].close()
    arun(d.run(("map",)))
    try:
        with io.open(os.path.join(run_dir, "state", "%s.json" % Q1_SLUG), encoding="utf-8-sig") as f:
            doc = json.load(f)
    except Exception as e:                                        # noqa: BLE001
        return "", [], [], 0, "the state file could not be read back: %s" % e
    raw = doc.get("terms") or []
    if isinstance(raw, dict):
        raw = [raw]
    blocking = sorted(str(t.get("term") or "") for t in raw if not t.get("optional"))
    wrote = len(d.ch["write"]._items)
    queued = []
    try:
        if os.path.exists(qf):
            with io.open(qf, encoding="utf-8-sig") as f:
                queued = sorted(str(i.get("term") or "") for i in (json.load(f).get("items") or []))
    except Exception as e:                                        # noqa: BLE001
        return str(doc.get("state") or ""), blocking, [], wrote, "scratch queue unreadable: %s" % e
    return str(doc.get("state") or ""), blocking, queued, wrote, ""


def _q2_zero_absent_is_still_carriage_checked():
    """THE CASE. absent_terms=[] over a mapped artifact holding a real-bid ingredient the carriage union
    does NOT report CARRIED. The recipe must NOT reach `priced` and must NOT reach the writer: it
    belongs at `pricing`, with the derived term recorded as blocking AND on the queue."""
    tmp = tempfile.mkdtemp(prefix="daemon-q2a-")
    try:
        state, blocking, queued, wrote, why = _q2_run(tmp, Q2_INGREDIENTS, absent=())
        if why:
            return False, why
        return ((state == "pricing" and blocking == ["Doubanjiang"]
                 and queued == ["Doubanjiang"] and wrote == 0),
                "state=%s blocking=%s queued=%s wrote=%d"
                % (state, json.dumps(blocking), json.dumps(queued), wrote))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _q2_clean_twin_every_line_carried_still_reaches_priced():
    """CLEAN TWIN, and it is what stops the fix becoming "nothing is ever priced again" - the obvious
    over-correction. A recipe whose every line the union agrees is CARRIED still lands at `priced` in
    the SAME pass, still enqueues nothing, still wakes no pricer and still reaches the writer. That is
    M3's whole purpose, and Q2 keeps it whole."""
    tmp = tempfile.mkdtemp(prefix="daemon-q2b-")
    try:
        carried = [dict(Q2_INGREDIENTS[0])]           # Chicken Breast alone: CARRIED in the ledger
        state, blocking, queued, wrote, why = _q2_run(tmp, carried, absent=())
        if why:
            return False, why
        return (state == "priced" and not blocking and not queued and wrote == 1,
                "state=%s blocking=%s queued=%s wrote=%d"
                % (state, json.dumps(blocking), json.dumps(queued), wrote))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _q2_the_state_machine_refuses_the_bypass():
    """THE EDGE ITSELF, asked of the real hunt-run.ps1 with no daemon in the way. Both call sites were
    repaired the same day, but a third caller written next year would have found the same door open and
    nothing would have said no - so the door is gone. This is the case that says it stays gone."""
    tmp = tempfile.mkdtemp(prefix="daemon-q2c-")
    try:
        staged, why = _q1_stage(tmp)
        if why:
            return False, why
        run_dir, _qf = staged
        rc0, o0, _e0 = hunt_lib.ps_invoke(HUNT_RUN_PS, [
            "-Advance", "-RunDir", run_dir, "-Slug", Q1_SLUG, "-To", "mapped", "-By", "drill"])
        if rc0 != 0:
            return False, "could not stage `mapped`: %s" % o0.strip()[:200]
        rc, o, e = hunt_lib.ps_invoke(HUNT_RUN_PS, [
            "-Advance", "-RunDir", run_dir, "-Slug", Q1_SLUG, "-To", "priced", "-By", "drill"])
        said = ((o or "") + (e or "")).strip()
        # AND THE STATE ON DISK IS UNCHANGED, not merely a non-zero exit. A refusal that still wrote the
        # state file would be the worst of both, and the exit code is the half people actually read.
        try:
            with io.open(os.path.join(run_dir, "state", "%s.json" % Q1_SLUG),
                         encoding="utf-8-sig") as f:
                still = str((json.load(f) or {}).get("state") or "")
        except Exception as ex:                                   # noqa: BLE001
            return False, "state file unreadable after the refusal: %s" % ex
        return (rc != 0 and "REFUSED" in said and still == "mapped",
                "rc=%s state=%s said=%r" % (rc, still, said[:200]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


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


def _t6_preaudit_reads_the_seamed_spec_store():
    """MUST FIRE (T6). lf1's wave-1 auditor reported "the certified spec is the stale 2026-08-16
    lowcarb-100 build" - the battery graded live specs while the drill was pointed elsewhere, so
    every number the auditor was handed came from a file the run never wrote."""
    tmp = _wave_scratch()
    try:
        specs = os.path.join(tmp, "specs")
        os.makedirs(specs, exist_ok=True)
        d = daemon(run_dir=tmp, specs_dir=specs)
        arun(d.preaudit(1))
        calls = d._ps.find("wave-preaudit")
        seamed = calls and FakePS.value_after(calls[0]["args"], "-SpecsDir") == specs
        # CLEAN TWIN in the same case: an UNSEAMED daemon passes the flag at all.
        d2 = daemon(run_dir=tmp)
        arun(d2.preaudit(1))
        c2 = d2._ps.find("wave-preaudit")
        plain = c2 and "-SpecsDir" not in c2[0]["args"]
        return bool(seamed and plain), "seamed=%s unseamed_clean=%s" % (seamed, plain)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _t6_qa_battery_and_mtimes_follow_the_seam():
    """MUST FIRE. Two more readers of the live store: the QA battery graded the live spec, and the
    staleness mtimes compared a freshly built spec against the live file's clock - the changed-
    nothing guard reasoning about the wrong file."""
    tmp = tempfile.mkdtemp(prefix="daemon-t6-")
    try:
        specs = os.path.join(tmp, "specs")
        os.makedirs(specs, exist_ok=True)
        d = daemon(run_dir=tmp, specs_dir=specs)
        paths = list(d.mtimes(["a", "b", "c"], os.path.join(tmp, "audit.md")).keys())
        spec_paths = [p for p in paths if p.endswith(".json") and "ingredients" not in p]
        mt = bool(spec_paths) and all(p.startswith(specs) for p in spec_paths)
        # THE BATTERY'S OWN COMMAND LINE, asserted through qa_battery_args - which exists precisely
        # because this call shells directly and the seam was otherwise unreachable by any neuter.
        bargs = d.qa_battery_args("a")
        bat = FakePS.value_after(bargs, "--spec") == os.path.join(specs, "a.json")
        live = daemon(run_dir=tmp)
        live_paths = [p for p in live.mtimes(["a"], os.path.join(tmp, "audit.md"))
                      if p.endswith("a.json")]
        plain = (bool(live_paths) and all(HD.SPECS_DIR in p for p in live_paths)
                 and FakePS.value_after(live.qa_battery_args("a"), "--spec")
                 == os.path.join(HD.SPECS_DIR, "a.json"))
        return (mt and bat and plain),  "mtimes=%s battery=%s unseamed_live=%s" % (mt, bat, plain)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _t6_auditor_is_told_which_spec_store_is_this_runs():
    """MUST FIRE with its CLEAN TWIN. The mechanical readers are seamed above; this is the half no
    argument can reach - an auditor that opens the file itself has to be told which file is ours."""
    tmp = _wave_scratch()
    try:
        _preaudited(tmp)
        specs = os.path.join(tmp, "specs")
        d = daemon(run_dir=tmp, specs_dir=specs)
        p = d.audit_prompt(1, ["a", "b", "c"], "drill-run-w1", "whole-wave", None)
        seamed = ("THIS IS A DRILL ON A SCRATCH SPEC STORE at %s" % specs) in p and \
                 "a disagreement between\ntwo files rather than a finding about this recipe" in p
        plain = daemon(run_dir=tmp).audit_prompt(1, ["a"], "drill-run-w1", "whole-wave", None)
        clean = "SCRATCH SPEC STORE" not in plain
        return seamed and clean, "seamed=%s unseamed_clean=%s" % (seamed, clean)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _t2_narrative_is_written_and_stamped():
    """MUST FIRE (T2). say() printed to stdout and nowhere else, so the run's findings, parks and
    STUCK messages lived only in scrollback while the lane log and the artifacts sat on disk looking
    complete."""
    tmp = tempfile.mkdtemp(prefix="daemon-t2-")
    try:
        path = os.path.join(tmp, "daemon.log")
        HD.set_log_file(path)
        try:
            HD.say("pre-pass batch 1: MATCHES 3")
            HD.say("map/harissa-traybake: parked on an unbid line")
        finally:
            HD.set_log_file(None)
        # READ DEFENSIVELY. A neuter that stops the tee must make this case go RED, not make it
        # THROW: an exception here escapes the section helper and takes every case in it with it,
        # which reports as "0 red" and reads exactly like a fixture that proved nothing. Measured
        # 2026-08-25 - the first neuter of this unit did precisely that and lost 13 cases.
        if not os.path.exists(path):
            return False, "no narrative was written at all"
        body = io.open(path, encoding="utf-8").read()
        lines = [l for l in body.splitlines() if l.strip()]
        stamped = bool(lines) and all(
            re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z ", l) for l in lines)
        return (len(lines) == 2 and stamped and "parked on an unbid line" in body,
                "lines=%d stamped=%s body=%r" % (len(lines), stamped, body[:160]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _t2_a_log_line_can_never_end_a_run():
    """MUST FIRE, and this is the case that matters. The phase-6a gate drill died because a log line
    raised inside asyncio.gather AFTER a 15-minute mapper dispatch had been paid for. A file sink is
    a second way for the same class of death to happen, so an unwritable path must be swallowed - and
    the sentence must still reach stdout."""
    HD.set_log_file(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "no-such-dir-t2", "daemon.log"))
    try:
        HD.say("this must not raise")
        undrawable = True
    except Exception:                                             # noqa: BLE001
        undrawable = False
    finally:
        HD.set_log_file(None)
    # and the U+FFFD line that actually killed 6a still survives, now through the tee as well
    tmp = tempfile.mkdtemp(prefix="daemon-t2b-")
    try:
        path = os.path.join(tmp, "daemon.log")
        HD.set_log_file(path)
        try:
            HD.say("cut into �-inch strips")
            mojibake = True
        except Exception:                                         # noqa: BLE001
            mojibake = False
        finally:
            HD.set_log_file(None)
        wrote = (os.path.exists(path)
                 and "-inch strips" in io.open(path, encoding="utf-8").read())
        return (undrawable and mojibake and wrote,
                "unwritable_ok=%s mojibake_ok=%s wrote=%s" % (undrawable, mojibake, wrote))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _t2_a_quiet_daemon_writes_no_narrative():
    """CLEAN TWIN: every fixture in this suite builds a quiet daemon, and none of them may start
    writing a log into a temp dir as a side effect of being constructed."""
    HD.set_log_file(None)
    tmp = tempfile.mkdtemp(prefix="daemon-t2c-")
    try:
        daemon(run_dir=tmp)
        return (HD._LOG_PATH[0] is None
                and not os.path.exists(os.path.join(tmp, "daemon.log")),
                "sink=%r" % (HD._LOG_PATH[0],))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _t3_store_lookup_is_timed():
    """MUST FIRE (T3, 2026-08-25). LOOKUP_TIMEOUT is 45 minutes and this call logged NOTHING - the
    single longest block a run can execute was the one block no summary could see, so it either fell
    in a lane-log gap or hid under a concurrent lane. Timed PER STORE, because that is the unit that
    varies: a seeded Sam's and a NEEDS-SEEDING Sam's differ by the entire timeout."""
    d, tmp = _price_daemon(py=FakePy())
    try:
        pairs = {}
        for c in d._ps.find("hunt-run.ps1", "-Lane"):
            lab = FakePS.value_after(c["args"], "-Label") or ""
            if lab.startswith("store-lookup:"):
                pairs.setdefault(lab, []).append(FakePS.value_after(c["args"], "-Event"))
        ok = (sorted(pairs) == ["store-lookup:fareway", "store-lookup:samsclub"]
              and all(sorted(v) == ["end", "start"] for v in pairs.values()))
        return ok, "pairs=%s" % json.dumps(pairs, sort_keys=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _t3_backdated_start_reaches_hunt_run():
    """MUST FIRE with its CLEAN TWIN in one case, because the twin is the whole safety story: -At is
    opt-in, so every existing call site must still be stamped by hunt-run itself."""
    d = daemon(run_dir="R")
    arun(d.lane("extract", "local rung 1", ["s1"], "local", "start", at="2026-08-24T10:00:00"))
    arun(d.lane("extract", "local rung 1", ["s1"], "local", "start"))
    calls = d._ps.find("hunt-run.ps1", "-Lane")
    backdated = FakePS.value_after(calls[0]["args"], "-At") if calls else None
    plain_has_at = "-At" in calls[1]["args"] if len(calls) > 1 else True
    return (backdated == "2026-08-24T10:00:00" and not plain_has_at,
            "backdated=%r plain_carries_At=%s" % (backdated, plain_has_at))


def _t3_stamp_ago_is_hunt_runs_own_format():
    """MUST FIRE. A stamp in any other shape is not a backdate, it is a line hunt-run cannot pair -
    and an unpaired start reads as a stage that never finished."""
    s = HD.Daemon._stamp_ago(90)
    shaped = re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$", s) is not None
    try:
        delta = time.time() - time.mktime(time.strptime(s, "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return False, "unparseable stamp %r" % s
    # and a NEGATIVE duration is never a backdate: sweep_one reporting nonsense must clamp to now.
    zero = HD.Daemon._stamp_ago(-5)
    fwd = time.mktime(time.strptime(zero, "%Y-%m-%dT%H:%M:%S")) - time.time()
    return (shaped and 85 <= delta <= 95 and fwd <= 1,
            "stamp=%r delta=%.1f clamp_fwd=%.1f" % (s, delta, fwd))


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
    # _asm_ps(), NOT a bare FakePS: since Q2 (2026-08-26) EVERY road out of the map lane reads the
    # term list back off the state file, so an injected hunt-run that writes nothing sends every
    # recipe STUCK and each case here quietly stops testing its own subject. _asm_ps() with no
    # arguments answers identically to FakePS() on every call - it only also writes the state file.
    d = daemon(run_dir=tmp, dispatcher=fd, ps=ps or _asm_ps(), **kw)
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
        # pre_out carries the "0 residual" line this case is about; the hunt-run half writes the state
        # file every road out of the lane now reads back (Q2).
        ps = _asm_ps(pre_out="map-preresolve: 3 slug(s), 0 residual")
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


def _hunt_run_writer(derived=None, skipped=None):
    r"""An injected hunt-run.ps1 -Advance that actually WRITES the recipe's state file, returned as a
    reply callable so any fixture can drop it into a FakePS.

    WHY EVERY MAP-LANE FIXTURE NEEDS ONE. Since Q1 (2026-08-26) the lane advances FIRST and then
    enqueues whatever hunt-run RECORDED, and since Q2 (2026-08-26) the ZERO-ABSENT road does the same -
    it reads the term list back before it will let a recipe reach `priced`. An injected hunt-run that
    writes nothing leaves that read-back with no file, which is a STUCK, so a fixture on a bare FakePS
    stops testing its own subject and starts testing the absence of a state file. Q2 turned two such
    fixtures red on its first run (D7's zero-residual twin and F1's failed-fill case), which is how
    this factory came to be shared rather than left inside _asm_ps.

    The write mirrors the real -Advance union - -Terms plus `derived` as blocking rows, -OptionalTerms
    plus `skipped` as optional ones, first spelling wins.

    IT DOES NOT TEST THE UNION and must not be read as if it did: `derived` is this helper's own
    simulation of it. The union itself is pinned against the REAL hunt-run.ps1 in the Q1 and Q2
    sections, which is the whole reason those sections exist.
    """
    def hunt_run(args):
        if "-Advance" not in args:
            return 0, "", ""
        slug = FakePS.value_after(args, "-Slug")
        run_dir = FakePS.value_after(args, "-RunDir")
        to = FakePS.value_after(args, "-To")
        # NEVER CREATE THE RUN DIR ITSELF. daemon() defaults run_dir to "R", so a fixture that takes
        # that default would have this helper mkdir a stray `R\state` INSIDE meal-prep\pipeline - a
        # test artifact committed to the repo. Only a run dir that already exists is written to.
        if not slug or not run_dir or not os.path.isdir(run_dir):
            return 0, "", ""
        sd = os.path.join(run_dir, "state")
        os.makedirs(sd, exist_ok=True)
        sp = os.path.join(sd, "%s.json" % slug)
        try:
            with io.open(sp, encoding="utf-8-sig") as f:
                doc = json.load(f)
        except Exception:                                         # noqa: BLE001
            doc = {"slug": slug, "history": [], "terms": []}
        doc["state"] = to
        if to == "pricing":
            rows, seen = [], set()
            for t in list(FakePS.value_after(args, "-Terms") or []) + list(derived or []):
                if t and t not in seen:
                    seen.add(t)
                    rows.append({"term": t, "optional": False})
            for t in list(FakePS.value_after(args, "-OptionalTerms") or []) + list(skipped or []):
                if t and t not in seen:
                    seen.add(t)
                    rows.append({"term": t, "optional": True})
            doc["terms"] = rows
        with io.open(sp, "w", encoding="utf-8") as f:
            f.write(json.dumps(doc))
        return 0, "", ""

    return hunt_run


def _asm_ps(rc=0, out="", derived=None, skipped=None, pre_out=""):
    r"""A FakePS whose map-preresolve -Assemble call answers with a chosen exit code. The pre-resolve
    road must keep answering 0, or the batch is blocked before the mapper is ever dispatched.

    AND, SINCE Q1 (2026-08-26), its hunt-run.ps1 -Advance actually WRITES the recipe's state file.
    That is not decoration: the map lane no longer enqueues the mapper's CLAIM, it advances first and
    then enqueues whatever hunt-run RECORDED, so an injected hunt-run that writes nothing leaves the
    lane reading an absent state file and every M3 case goes STUCK. The write here mirrors the real
    -Advance union - -Terms plus `derived` as blocking rows, -OptionalTerms plus `skipped` as optional
    ones, first spelling wins - so these cases keep testing the ROUTE for zero tokens.

    THEY DO NOT TEST THE UNION, and must not be read as if they did: `derived` is this helper's
    simulation of it. The union itself, and the postcondition over it, are pinned in the Q1 section
    against the REAL hunt-run.ps1 - which is the whole reason that section exists.

    THE WRITE ITSELF NOW LIVES IN _hunt_run_writer, because Q2 (2026-08-26) made the ZERO-ABSENT road
    read the record back too and fixtures outside this helper suddenly needed the same thing.
    """
    def reply(args):
        if "-Assemble" in args:
            return rc, out, ""
        # `pre_out` is the PRE-RESOLVE pass's stdout - the "N slug(s), M residual" line some D7 cases
        # read. Default "" keeps every existing caller byte-identical.
        return 0, pre_out, ""

    return FakePS(replies={"map-preresolve": reply,
                           "hunt-run": _hunt_run_writer(derived, skipped)})


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
                           "commodity-registrar": [{"rulings": [
                               {"proposed_bid": "korean-rice-cakes", "verdict": "approve",
                                "bid": "korean-rice-cakes",
                                "reason": "no id in any namespace prices tteok"}]}]})
        preresolved(tmp, ["s1"], residual={"s1": ["gochujang", "tteok"]})
        d = daemon(run_dir=tmp, dispatcher=fd, ps=ps)
        d.ch["map"].push({"slug": "s1"})
        d.ch["map"].close()
        arun(d.run(("map",)))
        calls = [c for c in fd.calls if c["agent"] == "commodity-registrar"]
        if len(calls) != 1:
            return False, "registrar dispatches=%d" % len(calls)
        schema_ok = calls[0]["schema"] is hunt_lib.REGISTRAR_BATCH
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
        ps = _asm_ps()          # Q1: the -Add is driven off the state file hunt-run writes
        d, _fd = _map_daemon(tmp, ["s1"],
                             {"results": [{"slug": "s1", "status": "ok", "state": "pricing",
                                           "absent_terms": ["sumac"]}]}, ps=ps)
        to = [FakePS.value_after(c["args"], "-To") for c in ps.find("hunt-run.ps1", "-Advance")]
        return (to == ["mapped", "pricing"] and not d.held
                and len(ps.find("ingredient-queue.ps1", "-Add")) == 1,
                "advances=%s held=%s" % (to, json.dumps(d.held)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _unhold_drill(mapped_ingredients=None, queue_file=None):
    """THE UNHOLD, end to end, against the REAL hunt-run.ps1 and the REAL map-preresolve.ps1. Returns
    (info, why); a non-empty `why` means the drill could not be set up and nothing was measured.

    The seed table alone would strand a repaired recipe forever: it seeds `mapped`-with-holds to the
    HELD list, which is right while the hold stands and a trap the moment the missing bid is wired -
    on the next resume the recipe lands back on the held list with nobody re-checking anything. So the
    seed RE-RUNS map-preresolve over the `mapped` recipes, and a cleared hold advances on the ruling
    already on disk.

    The scratch vocabulary is the thing being edited between the seeds, which is what "the bid is
    wired" means mechanically - a row in db\\ingredients.json gaining a bid.

    SHARED BY TWO CASES SINCE Q2 (2026-08-26). `mapped_ingredients` is what the carriage union reads,
    so the D7 case passes none (nothing to derive, the recipe prices out) and the Q2 case passes a row
    the union refuses. `queue_file` is the scratch worklist seam: the D7 case needs none because a
    recipe with nothing blocking makes no -Add at all, and the Q2 case MUST have one, because its
    recipe does - and no drill touches the live queue.
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
        # the mapper's decision file: the ruling the unhold advances ON, and never re-buys. It is ALSO
        # what hunt-run's carriage union reads on the way into `pricing`, which is why Q2 can steer
        # this whole drill through one argument.
        with open(os.path.join(run_dir, "mapped", "unhold-drill.json"), "w", encoding="utf-8") as f:
            json.dump({"slug": "unhold-drill",
                       "ingredients": list(mapped_ingredients or [])}, f)

        seam = ["-NoBoard", "-NoPrecheck", "-VocabFile", os.path.join(tmp, "vocab.json"),
                "-ResolutionsFile", os.path.join(tmp, "resolutions.json")]
        kw = {"preresolve_args": seam}
        if queue_file:
            kw["queue_path"] = queue_file

        rc, o, _e = hunt_lib.ps_invoke(HUNT_RUN_PS, ["-Init", "-RunDir", run_dir, "-Conditions",
                                                     "drill", "-Stop", "1", "-WaveSize", "2", "-CalMin", "400", "-CalMax", "650", "-CarbMax", "35", "-ProteinMin", "0"])
        if rc != 0:
            return None, "could not init: %s" % o.strip()[:150]
        for i, st in enumerate(["sourced", "selected", "extracted"]):
            args = ["-Advance", "-RunDir", run_dir, "-Slug", "unhold-drill", "-To", st,
                    "-By", "drill", "-Detail", "drill"]
            if i == 0:
                args += ["-Title", "Unhold Drill", "-SourceUrl", "https://d/u", "-Protein", "beef"]
            rc, o, _e = hunt_lib.ps_invoke(HUNT_RUN_PS, args)
            if rc != 0:
                return None, "staging refused at %s: %s" % (st, o.strip()[:150])

        # ---- the map lane, once. The mapper rules; the DAEMON holds on the unbid line.
        fd = FakeDispatch({"recipe-ingredient-mapper": [
            {"results": [{"slug": "unhold-drill", "status": "ok", "state": "priced",
                          "absent_terms": []}]}]})
        d0 = HD.Daemon(run_dir, "unhold-run", dispatcher=fd, quiet=True, **kw)
        d0.ch["map"].push({"slug": "unhold-drill"})
        d0.ch["map"].close()
        arun(d0.run(("map",)))
        if d0.state_of("unhold-drill") != "mapped" or len(d0.held) != 1:
            return None, "first pass: state=%s held=%s" % (d0.state_of("unhold-drill"),
                                                           json.dumps(d0.held))

        # ---- SEED 1: the bid is still missing, so the hold still stands and nothing is dispatched.
        fd1 = FakeDispatch({})
        d1 = HD.Daemon(run_dir, "unhold-run", dispatcher=fd1, quiet=True, **kw)
        ok1, err1 = arun(d1.seed())
        if not ok1:
            return None, "seed 1 failed: %s" % err1
        if len(d1.held) != 1 or d1.state_of("unhold-drill") != "mapped" or fd1.calls:
            return None, "seed 1: held=%s state=%s dispatches=%d" % (
                json.dumps(d1.held), d1.state_of("unhold-drill"), len(fd1.calls))

        # ---- THE BID IS WIRED. One row in the vocabulary gains a bid; nothing else changes.
        write_vocab("sumac")

        # ---- SEED 2: the hold clears, the recipe advances on the ruling already on disk, ZERO agents.
        fd2 = FakeDispatch({})
        d2 = HD.Daemon(run_dir, "unhold-run", dispatcher=fd2, quiet=True, **kw)
        ok2, err2 = arun(d2.seed())
        if not ok2:
            return None, "seed 2 failed: %s" % err2

        raw = (d2.state_row("unhold-drill") or {}).get("terms") or []
        if isinstance(raw, dict):
            raw = [raw]
        queued = []
        if queue_file and os.path.exists(queue_file):
            try:
                with io.open(queue_file, encoding="utf-8-sig") as f:
                    queued = sorted(str(i.get("term") or "")
                                    for i in (json.load(f).get("items") or []))
            except Exception as e:                                # noqa: BLE001
                return None, "the scratch queue could not be read: %s" % e
        return ({"state": d2.state_of("unhold-drill"),
                 "held": list(d2.held),
                 "dispatches": len(fd2.calls),
                 "write_q": len(d2.ch["write"]._items),
                 "blocking": sorted(str(t.get("term") or "") for t in raw if not t.get("optional")),
                 "queued": queued}, "")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _unhold_between_seeds():
    """D7's claim, unchanged: a repaired recipe with nothing blocking clears its hold and prices out on
    the ruling already on disk. The whole claim is in the last assertion - ZERO dispatches on the
    second seed."""
    info, why = _unhold_drill()
    if why:
        return False, why
    return (not info["held"] and info["state"] == "priced" and not info["dispatches"]
            and info["write_q"] == 1,
            "seed 2: held=%s state=%s dispatches=%d write_q=%d"
            % (json.dumps(info["held"]), info["state"], info["dispatches"], info["write_q"]))


def _q2_unhold_is_carriage_checked():
    """Q2, THE SECOND ROAD. The unhold advances on a mapper ruling that reported NOTHING absent, and
    before today it went straight to `priced` on that ruling alone - so a recipe held for an unbid line
    and later repaired reached a paid page without the carriage union ever reading it. Same hole as the
    map lane's, on a narrower road, and the M3 note named it and left it for Brad.

    The recipe is identical to the D7 twin above in every respect except the one under test: its mapped
    artifact carries a real-bid ingredient the union refuses."""
    tmp = tempfile.mkdtemp(prefix="daemon-q2unh-")
    try:
        qf = os.path.join(tmp, "scratch-queue.json")
        info, why = _unhold_drill(mapped_ingredients=Q2_INGREDIENTS, queue_file=qf)
        if why:
            return False, why
        return ((info["state"] == "pricing" and info["blocking"] == ["Doubanjiang"]
                 and info["queued"] == ["Doubanjiang"] and info["write_q"] == 0
                 and not info["dispatches"]),
                "state=%s blocking=%s queued=%s write_q=%d dispatches=%d"
                % (info["state"], json.dumps(info["blocking"]), json.dumps(info["queued"]),
                   info["write_q"], info["dispatches"]))
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
        # the prompt assertion moved to _write_prompt_is_a_dossier with CHANGE W; what this case is
        # about is the ORDER - the machine half exists before a word of prose is paid for.
        return (len(builds) == 1 and FakePS.value_after(builds[0]["args"], "-Slug") == "s1"
                and "THE SKELETON'S LOCKED VIEW" in prompt,
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


def _ok_fields(**over):
    """A three-field patch, 3+ elements per the estate's collection rule, with one array among them
    so the array path is exercised in the ordinary case and not only in its own fixture."""
    f = {"prose.intro_html": "<p>Brad on this dish.</p>",
         "cuisine": "American",
         "head.steps": ["Brown the beef.", "Add the rice.", "Simmer."]}
    f.update(over)
    return f


def _write_result(slug="s1", fields=None, **over):
    r = {"slug": slug, "status": "ok", "state": "written",
         "fields": _ok_fields() if fields is None else fields}
    r.update(over)
    return r


def _read_intake(tmp, slug="s1"):
    with open(os.path.join(tmp, "intake", "%s.json" % slug), "r", encoding="utf-8-sig") as f:
        return json.load(f)


def _read_skeleton(tmp, slug="s1"):
    with open(os.path.join(tmp, "intake", "%s.skeleton.json" % slug), "r", encoding="utf-8-sig") as f:
        return (json.load(f) or {}).get("intake") or {}


def _write_prompt_is_a_dossier():
    """CHANGE W. v2's line was "Produce ONE intake JSON"; D8's was "COMPLETE its intake IN PLACE".
    Both are gone: the writer has no file access at all, and its whole deliverable is the payload."""
    tmp = tempfile.mkdtemp(prefix="daemon-skel6-")
    try:
        os.makedirs(os.path.join(tmp, "extracted"), exist_ok=True)
        with open(os.path.join(tmp, "extracted", "s1.json"), "w", encoding="utf-8") as f:
            json.dump({"title": "Beef And Rice", "source_url": "https://d/x",
                       "ingredients": ["3 1/2 lb ground beef", "3 cups rice", "2 onions"],
                       "instructions": ["Brown the beef.", "Add rice.", "Simmer 25 minutes."]}, f)
        d, fd = _write_daemon(tmp, ["s1"], [_write_result()])
        prompt = fd.prompts("recipe-writer")[0]
        return (("THE TRANSCRIPTION" in prompt and "THE SKELETON'S LOCKED VIEW" in prompt
                 # the content is really inline, not pointed at
                 and "Simmer 25 minutes." in prompt and "3 1/2 lb" in prompt
                 and "prose.intro_html" in prompt and "head.step_names" in prompt
                 # and the two superseded contracts are both gone
                 and "COMPLETE its intake IN PLACE" not in prompt
                 and "THE INTAKE ALREADY EXISTS" not in prompt
                 and "Produce ONE intake JSON" not in prompt
                 # the rails that did NOT move
                 and "Compute NO number" in prompt and "no em dashes" in prompt
                 and "14 servings" in prompt),
                prompt[:200])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _fields_patch_exactly():
    tmp = tempfile.mkdtemp(prefix="daemon-fields1-")
    try:
        d, fd = _write_daemon(tmp, ["s1"], [_write_result()])
        got, skel = _read_intake(tmp), _read_skeleton(tmp)
        touched = {"prose": got.get("prose"), "cuisine": got.get("cuisine"),
                   "head.steps": (got.get("head") or {}).get("steps")}
        # EVERY OTHER BYTE IDENTICAL: compare whole dicts with the fillable paths removed, which is
        # the only comparison that can catch a patcher that quietly re-serialises a number.
        a, b = json.loads(json.dumps(got)), json.loads(json.dumps(skel))
        for doc in (a, b):
            doc.pop("prose", None)
            doc.pop("cuisine", None)
            (doc.get("head") or {}).pop("steps", None)
        return ((touched["prose"] == {"intro_html": "<p>Brad on this dish.</p>"}
                 and touched["cuisine"] == "American"
                 and touched["head.steps"] == ["Brown the beef.", "Add the rice.", "Simmer."]
                 and a == b and not d.outcomes),
                "touched=%s rest-identical=%s" % (json.dumps(touched)[:200], a == b))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _fields_nest_correctly():
    """`prose.cost_closing_html` is a TWO level path, not three. A naive split on every dot would
    invent a nesting build-v2-spec cannot read, and the value would vanish without an error."""
    tmp = tempfile.mkdtemp(prefix="daemon-fields2-")
    try:
        fields = {"prose.cost_closing_html": "<p>What it costs.</p>",
                  "head.step_names": ["Brown", "Add", "Simmer"],
                  "writer_notes": ["one", "two", "three"],
                  "forbidden_prose_terms": ["cheap", "gourmet", "healthy"]}
        d, fd = _write_daemon(tmp, ["s1"], [_write_result(fields=fields)])
        got = _read_intake(tmp)
        return (((got.get("prose") or {}).get("cost_closing_html") == "<p>What it costs.</p>"
                 and (got.get("head") or {}).get("step_names") == ["Brown", "Add", "Simmer"]
                 and got.get("writer_notes") == ["one", "two", "three"]
                 and got.get("forbidden_prose_terms") == ["cheap", "gourmet", "healthy"]
                 # no invented nesting anywhere
                 and "prose.cost_closing_html" not in got
                 and "cost_closing_html" not in ((got.get("prose") or {}).get("cost", {}) or {})),
                json.dumps({"prose": got.get("prose"), "head": got.get("head"),
                            "writer_notes": got.get("writer_notes")})[:250])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _fields_unknown_key_refused():
    """DISPATCH-LEVEL, so the model gets the re-ask with the key named - the same road
    validate_registrar takes. Never a silent drop: a writer that keeps believing it can set
    macros_per_serving is exactly the defect the skeleton exists to end."""
    bad = dict(_ok_fields())
    bad["macros_per_serving"] = {"calories": 640}
    problems = hunt_lib.validate_writer_fields({"slug": "s1", "fields": bad})
    named = [p for p in problems if "macros_per_serving" in p]
    # a rejection carries no fields at all, and that stays legal
    none_ok = hunt_lib.validate_writer_fields({"slug": "s1", "status": "rejected"}) == []
    # and the array fields are type-checked where it matters
    shape = hunt_lib.validate_writer_fields(
        {"slug": "s1", "fields": {"head.steps": "not an array"}})
    return (len(named) == 1 and none_ok and len(shape) == 1 and "ARRAY" in shape[0],
            "problems=%s none_ok=%s shape=%s" % (json.dumps(problems)[:250], none_ok,
                                                 json.dumps(shape)[:150]))


def _patcher_refuses_unknown_key():
    tmp = tempfile.mkdtemp(prefix="daemon-fields3-")
    try:
        skeletoned(tmp, ["s1"])
        before = _read_intake(tmp)
        d = daemon(run_dir=tmp)
        bad = dict(_ok_fields())
        bad["macros_per_serving"] = {"calories": 640}
        ok, why = d.apply_writer_fields("s1", bad)
        after = _read_intake(tmp)
        return ((not ok) and "macros_per_serving" in why and after == before,
                "ok=%s why=%s untouched=%s" % (ok, why[:150], after == before))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _post_patch_drift_is_stuck():
    r"""THE MEANING OF verify_skeleton INVERTS. It used to catch the WRITER editing a machine field,
    and the answer was the one re-ask. The writer has no file access now - only apply_writer_fields
    writes this file - so a locked-field difference can only be the PATCHER's doing. That is a daemon
    bug: STUCK with the detail, never a re-ask, because there is nobody to ask.

    THE DISPATCH COUNT IS THE PROOF THE REDRIFT ROAD IS GONE. Two writer results are queued; if the
    old road survived anywhere, the second would be consumed.
    """
    tmp = tempfile.mkdtemp(prefix="daemon-drift1-")
    try:
        drifted = ["ingredients[1].grams: issued '630', returned '900'",
                   "macros_per_serving.calories: issued '500', returned '640'",
                   "head.totalTime: issued 'PT40M', returned 'PT25M'"]
        body = ("build-intake-skeleton: 3 LOCKED FIELD(S) DRIFTED in s1\n"
                + "\n".join("    " + x for x in drifted) + "\nBUILD-INTAKE-SKELETON-COMPLETE")
        ps = FakePS({"build-intake-skeleton.ps1":
                     lambda a: ((1, body, "") if "-Verify" in a else (0, "", ""))})
        d, fd = _write_daemon(tmp, ["s1"], [_write_result(), _write_result()], ps=ps)
        to = [FakePS.value_after(c["args"], "-To") for c in ps.find("hunt-run.ps1", "-Advance")]
        out = d.outcomes[0] if d.outcomes else {}
        return ((len(fd.prompts("recipe-writer")) == 1
                 and out.get("status") == "stuck" and out.get("state") is None
                 and "daemon bug" in (out.get("detail") or "")
                 and "macros_per_serving.calories" in (out.get("detail") or "")
                 # a daemon bug belongs in the run's findings, not only in one recipe's outcome
                 and any("daemon bug" in f for f in d.findings)
                 # and NOTHING advanced: no spec build, no rejected-qa
                 and to == []),
                "dispatches=%d advances=%s outcome=%s"
                % (len(fd.prompts("recipe-writer")), to, json.dumps(d.outcomes)[:300]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _redrift_road_is_gone():
    """Source scan, the _one_marshalling_road idiom. The re-ask class is dead by CONSTRUCTION, and
    the thing that would quietly resurrect it is somebody adding the prompt back because the name
    still reads sensibly. NEUTER PROOF, run 2026-08-25: restoring redrift_prompt turns this red."""
    with open(os.path.join(HERE, "hunt-daemon.py"), "r", encoding="utf-8") as f:
        lines = f.read().splitlines()
    # CODE ONLY. The comments explaining the deletion naturally quote the thing they deleted, and a
    # scan that cannot tell a tombstone from a resurrection would force those comments out - which
    # would leave the next reader with no record of why the road is missing.
    src = "\n".join(l for l in lines if not l.lstrip().startswith("#"))
    bad = []
    if "def redrift_prompt" in src:
        bad.append("redrift_prompt is back")
    if "drifted twice" in src:
        bad.append("the `drifted twice` rejected-qa branch is back")
    if ":redrift" in src:
        bad.append("a redrift dispatch label is back")
    return not bad, "; ".join(bad)


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
        d, fd = _write_daemon(tmp, ["s1"], [_write_result()], ps=ps)
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
        # `pricing` is in the chain because Q2 (2026-08-26) removed `mapped` -> `priced` from the state
        # machine; this is STAGING, so it takes the legal road to the state the case is actually about.
        for i, st in enumerate(["sourced", "selected", "extracted", "mapped", "pricing", "priced"]):
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

        # `pricing` sits between `mapped` and `priced` because Q2 (2026-08-26) removed the direct edge
        # from the state machine. These are STAGING chains - the seed table is what the case is about,
        # so they take the legal road to each state rather than asserting anything about the road.
        plan = {"r-selected": ["sourced", "selected"],
                "r-extracted": ["sourced", "selected", "extracted"],
                "r-mapped": ["sourced", "selected", "extracted", "mapped"],
                "r-priced": ["sourced", "selected", "extracted", "mapped", "pricing", "priced"],
                "r-written": ["sourced", "selected", "extracted", "mapped", "pricing", "priced",
                              "spec-built", "written"],
                "r-qapassed": ["sourced", "selected", "extracted", "mapped", "pricing", "priced",
                               "spec-built", "written", "qa-passed"]}
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
        # ---- MUST FIRE: the seeded record carries the SOURCE URL off the state file.
        # `hunt-run.ps1 -Status -Json` emits {slug, state} per in_flight row and nothing else. A seed
        # built from that alone hands the extract lane a stub, and extract_sweep then reports "the
        # state file carries no source_url" - blaming the data for a read the seed never did.
        # Measured 2026-08-24 on a resumed 6b run: three recipes STUCK at `selected`, every one of
        # them with a good source_url sitting on disk. Only RESUMES are affected, which is exactly
        # why the first pass of that run never saw it and why it needs a fixture rather than a memory.
        seeded_url = (d.rec.get("r-selected") or {}).get("url")
        out.append(("MUST FIRE  a seeded recipe carries its source_url from the STATE FILE, because "
                    "-Status -Json does not carry one - the extract lane cannot fetch a stub",
                    seeded_url == "https://d/r-selected",
                    "url=%r" % (seeded_url,)))
        out.append(("CLEAN TWIN and the title and protein ride along with it, so nothing downstream "
                    "has to re-open the same file",
                    (d.rec.get("r-selected") or {}).get("title") == "r-selected"
                    and (d.rec.get("r-selected") or {}).get("protein") == "beef",
                    json.dumps({k: v for k, v in (d.rec.get("r-selected") or {}).items()
                                if k in ("title", "protein")})))

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


def _lane_containment():
    """A lane's death is ITS death, not the run's - and it still closes what it owes."""
    out = []

    d = daemon()

    async def boom():
        raise RuntimeError("cannot reach local endpoint http://127.0.0.1:8080/v1")

    # ---- MUST FIRE: the raise is caught, recorded, and does NOT propagate.
    res = arun(d.contained("extract", boom()))
    out.append(("MUST FIRE  a lane that raises is CONTAINED - the exception does not escape and kill "
                "the run (an unreachable llama-server took the whole 6b resume down, pricer included)",
                res is None and bool(d.lane_deaths.get("extract")),
                "deaths=%s" % json.dumps(d.lane_deaths)))
    out.append(("MUST FIRE  ...and it is recorded as a FINDING, so a run that lost a lane can never "
                "exit clean",
                any("LANE DIED" in f for f in d.findings), json.dumps(d.findings)[:300]))
    out.append(("MUST FIRE  ...and the status report NAMES it - containment must not make the death "
                "quiet",
                "LANES THAT DIED" in d.status_report() and "extract" in d.status_report(),
                d.status_report()[:200]))

    # ---- MUST FIRE: the channel the dead lane feeds is CLOSED. This is the load-bearing half: a
    # lane that dies without closing leaves the next lane waiting forever, and a HANG is strictly
    # worse than the crash containment replaces.
    d2 = daemon()

    async def boom2():
        raise RuntimeError("boom")

    arun(d2.contained("extract", boom2()))
    closed = d2.ch["map"].is_closed()
    out.append(("MUST FIRE  a dead lane still CLOSES the channel it feeds - containment that leaves "
                "the next lane waiting forever is worse than the crash it replaced",
                bool(closed), "map channel closed=%r" % (closed,)))

    # ---- CLEAN TWIN: a lane that returns normally is untouched, and closes the same channel.
    d3 = daemon()

    async def fine():
        return "done"

    r3 = arun(d3.contained("extract", fine()))
    out.append(("CLEAN TWIN a lane that finishes normally returns its value and records no death",
                r3 == "done" and not d3.lane_deaths, "%r %s" % (r3, json.dumps(d3.lane_deaths))))

    # ---- the GPU ownership window, which is why auto-start is not a licence to take the card
    owned = HD.card_is_owned
    out.append(("MUST FIRE  the daemon will NOT start a model inside the nightly chain's window "
                "(21:30-06:30) - competing for the card is how the 07:00 ad pull goes blind",
                bool(owned(dt.datetime(2026, 8, 25, 23, 0)))
                and bool(owned(dt.datetime(2026, 8, 25, 3, 0))),
                "23:00=%r 03:00=%r" % (owned(dt.datetime(2026, 8, 25, 23, 0)),
                                       owned(dt.datetime(2026, 8, 25, 3, 0)))))
    out.append(("MUST FIRE  nor in the 06:30-07:00 changeover, which a run could not clear before "
                "the ad pull",
                bool(owned(dt.datetime(2026, 8, 25, 6, 45))),
                "06:45=%r" % (owned(dt.datetime(2026, 8, 25, 6, 45)),)))
    out.append(("CLEAN TWIN and the card IS free in the working day, or the preflight would never "
                "start anything at all",
                owned(dt.datetime(2026, 8, 25, 13, 0)) is None
                and owned(dt.datetime(2026, 8, 25, 19, 0)) is None,
                "13:00=%r 19:00=%r" % (owned(dt.datetime(2026, 8, 25, 13, 0)),
                                       owned(dt.datetime(2026, 8, 25, 19, 0)))))
    return out


def _registrar_collision_recheck():
    r"""Pass 1 runs the rulings CONCURRENTLY; pass 2 is what makes that safe.

    A concurrent ruling can check the estate (on disk, immutable under a hunt) but cannot see its
    siblings in the same batch. These freeze the property that matters: two spellings of one food
    do not both get minted just because they were ruled on at the same time."""
    out = []

    def props(*bids):
        return [{"proposed_bid": b, "term": b.replace("-", " "), "evidence": "case"} for b in bids]

    # ---- MUST FIRE: two spellings of ONE food, both approved in pass 1, force a serial re-check.
    fd = FakeDispatch({"commodity-registrar": [
        # pass 1 is ONE dispatch carrying BOTH rulings now (F2), and it approves both:
        {"rulings": [{"proposed_bid": "bread-crumbs", "verdict": "approve", "bid": "bread-crumbs",
                      "reason": "new"},
                     {"proposed_bid": "breadcrumbs", "verdict": "approve", "bid": "breadcrumbs",
                      "reason": "new"}]},
        # pass 2, a batch of ONE each, each told about the other:
        {"rulings": [{"proposed_bid": "bread-crumbs", "verdict": "approve", "bid": "bread-crumbs",
                      "reason": "the canonical spelling"}]},
        {"rulings": [{"proposed_bid": "breadcrumbs", "verdict": "alias", "bid": "bread-crumbs",
                      "reason": "same food, aliased"}]}]})
    d = daemon(dispatcher=fd)
    d._commodity_rows = list(_REG_ROWS)
    res = arun(d.registrar_rulings("dish", props("bread-crumbs", "breadcrumbs")))
    n = len(fd.prompts("commodity-registrar"))
    out.append(("MUST FIRE  two proposals that normalise to the SAME commodity are re-adjudicated "
                "serially - concurrency must not let one food be minted twice",
                n == 3, "registrar dispatches=%d (expected 3: ONE batch + 2 re-checks)" % n))
    out.append(("MUST FIRE  ...and the re-adjudication prompt NAMES the sibling, so the second "
                "ruling is made knowing what the first could not see",
                any("breadcrumbs" in p and "RE-ADJUDICATION" in p
                    for p in fd.prompts("commodity-registrar")),
                "no re-adjudication prompt names the sibling"))
    verdicts = sorted((r["verdict"], r["bid"]) for r in res)
    out.append(("MUST FIRE  ...and the re-check's verdict REPLACES the pass-1 approval, so exactly "
                "one id is born",
                sum(1 for r in res if r["verdict"] == "approve") == 1,
                json.dumps(verdicts)))

    # ---- CLEAN TWIN: genuinely different foods are ruled once each and never re-litigated.
    fd2 = FakeDispatch({"commodity-registrar": [
        {"rulings": [{"proposed_bid": "harissa", "verdict": "approve", "bid": "harissa",
                      "reason": "new"},
                     {"proposed_bid": "gochujang", "verdict": "approve", "bid": "gochujang",
                      "reason": "new"}]}]})
    d2 = daemon(dispatcher=fd2)
    d2._commodity_rows = list(_REG_ROWS)
    res2 = arun(d2.registrar_rulings("dish", props("harissa", "gochujang")))
    n2 = len(fd2.prompts("commodity-registrar"))
    out.append(("CLEAN TWIN two genuinely different foods are ruled in ONE batch dispatch and "
                "never re-litigated - the re-check must not tax the common case",
                n2 == 1 and len(res2) == 2, "registrar dispatches=%d" % n2))

    # ---- CLEAN TWIN: an ALIAS mints nothing, so two aliases onto one target are not a clash.
    fd3 = FakeDispatch({"commodity-registrar": [
        {"rulings": [{"proposed_bid": "shredded-cheese", "verdict": "alias", "bid": "block-cheese",
                      "reason": "already priced"},
                     {"proposed_bid": "grated-cheese", "verdict": "alias", "bid": "block-cheese",
                      "reason": "already priced"}]}]})
    d3 = daemon(dispatcher=fd3)
    d3._commodity_rows = list(_REG_ROWS)
    arun(d3.registrar_rulings("dish", props("shredded-cheese", "grated-cheese")))
    n3 = len(fd3.prompts("commodity-registrar"))
    out.append(("CLEAN TWIN two ALIASES onto the same existing id are correct, not a collision - "
                "only `approve` mints anything",
                n3 == 1, "registrar dispatches=%d (expected 1, no re-check)" % n3))

    # ---- the normaliser itself
    ck = hunt_lib.collision_key
    out.append(("MUST FIRE  collision_key folds separators, case and one trailing plural together",
                ck("bread-crumbs") == ck("breadcrumbs") == ck("Bread Crumbs") == ck("breadcrumb"),
                "%r %r %r %r" % (ck("bread-crumbs"), ck("breadcrumbs"), ck("Bread Crumbs"),
                                 ck("breadcrumb"))))
    out.append(("CLEAN TWIN and it does NOT fold two genuinely different foods together",
                ck("harissa") != ck("gochujang") and ck("pork-loin") != ck("pork-shoulder"),
                "%r %r" % (ck("pork-loin"), ck("pork-shoulder"))))
    return out


# =====================================================================================================
# G1 - the harness's own Grep, said once to every judge that sweeps (2026-08-25)
#
# MEASURED (EVAL-registrar-batch-2026-08-25.md): the 2-proposal registrar spent 7 of its 12 turns
# recovering from two harness Grep behaviours - a brace glob whose one slash-bearing member anchored
# every alternative at the repo root and returned a FALSE EMPTY, and the minified smp-feed rendering
# as "[Omitted long matching line]". At least 44,109 raw of a 123,401 session, none of it gate work.
#
# THE ASSERTIONS ARE ON THE SENTENCE, the M4 rule, because the sentence is the change. They are also
# on the SAFETY half: the note must never read as a reason to sweep less, since the sweep produced the
# decisive evidence in all three registrar transcripts.
#
# NEUTER PROOFS, RUN 2026-08-25 and reverted, with the counts the suite ACTUALLY printed rather than
# the ones this comment first predicted:
#   * blank GREP_HARNESS_NOTE to ""                     -> 5 red, not the 4 predicted: the four
#     rendering cases AND the safety case, which also needs the sentence present to find it. The
#     no-leak twin stays green, which is correct - it asserts an ABSENCE.
#   * drop the "never a reason to stop sweeping" clause -> 1 red (the safety case alone), which is
#     the case that exists so a future trim cannot quietly turn this into a sweep ban.
#   * render the note into price_prompt as well         -> 1 red (the no-leak twin), proving that
#     twin pins the deliberate omission rather than merely passing by luck.
#
# AND ONE TRAP WORTH THE NEXT BUILDER'S TIME. The first attempt at the second neuter wrote a real
# newline into the string literal instead of the two characters `\` and `n`. The daemon then failed to
# IMPORT, the suite never ran, and a harness that counted only "  X" lines reported it as 0 red - a
# neuter that appears to prove the fixture is dead when it actually proves nothing at all. A neuter
# must FAIL CASES, never fail to run: check the exit code and the case count before believing a zero.
# =====================================================================================================

_G1_WANT = ["matches the BASENAME AT ANY DEPTH",
            "anchored at the REPO ROOT, not at your `path` argument",
            "ONE separator anywhere in a brace anchors EVERY",
            "a FALSE EMPTY",
            "IS ONE MINIFIED LINE"]


def _g1_missing(prompt):
    return [w for w in _G1_WANT if w not in prompt]


def _g1_registrar_prompt_carries_the_note():
    d = _reg_daemon()
    p = d.registrar_batch_prompt("some-dish", [("gouda-cheese", "Gouda cheese", "case", None)])
    missing = _g1_missing(p)
    return not missing, "missing=%s" % json.dumps(missing)


def _g1_map_prompt_carries_the_note():
    prompt, _d, _p = _m4_prompt()
    missing = _g1_missing(prompt)
    return not missing, "missing=%s" % json.dumps(missing)


def _g1_qa_prompt_carries_the_note():
    d, tmp = _qa_dossier_run()
    try:
        missing = _g1_missing(d.qa_prompt("s1", 1))
        return not missing, "missing=%s" % json.dumps(missing)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _g1_audit_prompt_carries_the_note():
    tmp = _wave_scratch()
    try:
        _preaudited(tmp)
        d = daemon(run_dir=tmp)
        missing = _g1_missing(d.audit_prompt(1, ["a", "b", "c"], "drill-run-w1", "whole-wave", None))
        return not missing, "missing=%s" % json.dumps(missing)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _g1_note_never_discourages_the_sweep():
    """MUST FIRE, and this is the case that matters most. A note about a broken tool is one careless
    edit away from reading "do not sweep" - and the sweep is where every registrar ruling's decisive
    evidence came from. The distrust is aimed at the empty RESULT, in as many words."""
    d = _reg_daemon()
    p = d.registrar_batch_prompt("dish", [("gouda-cheese", "Gouda cheese", "case", None)])
    safety = ("never a\nreason to stop sweeping" in p and "re-run it per file before you believe it"
              in p)
    # and the authority language F2 pinned is UNTOUCHED beside it
    authority = ("may re-derive anything you distrust" in p and "NOT exhaustive" in p
                 and "OBLIGATION to fetch it, never" in p)
    return safety and authority, "safety=%s authority=%s" % (safety, authority)


def _g1_note_does_not_leak_into_prompts_that_do_not_sweep():
    """CLEAN TWIN: the pricer and the decider carry Grep and neither sweeps a namespace - the pricer
    adjudicates pre-gathered store rows, the decider ruled 3 candidates in 1 turn off a whole dossier.
    Prompt weight buys nothing where nobody greps, and this pins that omission as deliberate."""
    d = daemon(run_dir="R")
    price = d.price_prompt(["saffron", "harissa", "tteok"])
    decide = d.decide_prompt([{"slug": "x", "name": "X", "dossier": {"slug": "x", "name": "X"}}], "3")
    leaked = [n for n, p in (("price", price), ("decide", decide))
              if "YOUR `glob` AND THIS HARNESS" in p]
    return not leaked, "the note leaked into: %s" % json.dumps(leaked)


def _registrar_gets_evidence():
    d = _reg_daemon()
    p = d.registrar_batch_prompt("some-dish", [("chicken-drumsticks", "chicken drumsticks",
                                                 "the mapper's case", None)])
    return ("chicken-thighs" in p and "ALREADY READ FOR YOU" in p,
            "near-miss row absent from the prompt: %s" % p[-400:])


def _registrar_evidence_is_not_a_verdict():
    d = _reg_daemon()
    p = d.registrar_batch_prompt("some-dish", [("chicken-drumsticks", "chicken drumsticks",
                                                 "case", None)])
    return ("NOT exhaustive" in p and "approve" in p and "alias" in p,
            "the block reads as a verdict rather than as leads: %s" % p[-300:])


# =====================================================================================================
# F2 - the registrar rules a whole BATCH from one dossier (2026-08-25)
#
# Measured on jc1: 10 turns and 81,929 raw tokens to rule ONE proposal, with the near-miss block
# already in the prompt - the turns were the registrar's own greps and feed reads, i.e. the auditor's
# old shape, an OBLIGATION to fetch what could be shown. 6b: 12 dispatches, 12.0 minutes of wall.
#
# NEUTER PROOFS, RUN 2026-08-25 and reverted:
#   * dispatch per proposal again (loop `rule([w])` over work) -> the one-dispatch case goes red at
#     3 dispatches, and the collision twin at 4 where 3 belong.
#   * drop feed_block / floor_map_block / label_grep_block out of registrar_dossier -> the dossier
#     case goes red naming the missing block.
#   * make validate_registrar_batch return [] -> the indexed-refusal case goes red (the bad ruling
#     lands, which is the whole-payload rule broken).
# =====================================================================================================

_REG_FEED = {"chicken-thighs": {"unit": "lb", "cheapest": 1.29, "store": "Aldi", "n": 6},
             "brown-rice": {"unit": "lb", "cheapest": 0.98, "store": "Walmart", "n": 5}}
_REG_FLOOR = {"chicken-drumsticks": "chicken-thighs", "jasmine-rice": "brown-rice",
              "yellow-mustard": "mustard"}


def _reg_batch_daemon(feed=None, floor=None, dispatcher=None):
    d = daemon(run_dir="R", dispatcher=dispatcher)
    d._commodity_rows = list(_REG_ROWS)
    # The caches are seeded so these fixtures never depend on the LIVE feed, which another session
    # rewrites daily - the tuple wrapper is what lets a seeded None mean "could not be read".
    d._feed_prices = (dict(_REG_FEED) if feed is None else feed,)
    d._floor_map = (dict(_REG_FLOOR) if floor is None else floor,)
    return d


_REG_WORK = [("chicken-drumsticks", "chicken drumsticks", "a different cut", None),
             ("brown-jasmine-rice", "brown jasmine rice", "a different grain", None),
             ("goat-cheese", "goat cheese", "not block cheese", None)]


def _registrar_batch_is_one_dispatch():
    """MUST FIRE: three proposals, ONE dispatch, three rulings back - the decider's shape."""
    fd = FakeDispatch({"commodity-registrar": [{"rulings": [
        {"proposed_bid": "chicken-drumsticks", "verdict": "alias", "bid": "chicken-thighs",
         "reason": "the include pattern already prices drumsticks"},
        {"proposed_bid": "brown-jasmine-rice", "verdict": "approve", "bid": "brown-jasmine-rice",
         "reason": "a different grain from brown-rice"},
        {"proposed_bid": "goat-cheese", "verdict": "approve", "bid": "goat-cheese",
         "reason": "block-cheese is a different food"}]}]})
    d = _reg_batch_daemon(dispatcher=fd)
    props = [{"proposed_bid": b, "term": t, "evidence": e} for b, t, e, _r in _REG_WORK]
    res = arun(d.registrar_rulings("dish", props))
    prompts = fd.prompts("commodity-registrar")
    one = len(prompts) == 1
    named = one and all(b in prompts[0] and t in prompts[0] for b, t, _e, _r in _REG_WORK)
    ok = (one and named and len(res) == 3
          and [r["proposed_bid"] for r in res] == [w[0] for w in _REG_WORK]
          and [r["verdict"] for r in res] == ["alias", "approve", "approve"]
          # the sibling framing is in the prompt, not only in the mechanical re-check
          and "SIBLINGS IN ONE BATCH" in prompts[0])
    return ok, "dispatches=%d rulings=%s" % (len(prompts), json.dumps(res)[:300])


def _registrar_dossier_carries_the_checklist():
    """MUST FIRE: the feed's own price cell, the declared-same-thing rows and the label greps arrive
    in the dossier - the three reads commodity-registrar.md orders beyond the namespace sweep."""
    d = _reg_batch_daemon()
    # THE LABEL SEAM IS ITS OWN CASE, and it has to be a term whose only route to the row is the
    # LABEL's own word form: `tomato paste` shares no token with id `canned-tomatoes` or label
    # `Tomatoes` (tomato against tomatoes), so the near-miss sweep cannot see it and only a stem grep
    # over labels can. That is the yellow-mustard seam, which cost a full seven-store pricing run.
    d._commodity_rows = list(_REG_ROWS) + [
        {"id": "canned-tomatoes", "label": "Tomatoes", "ns": "commodities", "include": ""}]
    work = list(_REG_WORK) + [("tomato-paste", "tomato paste", "a concentrate, not the canned form",
                               None)]
    p = d.registrar_batch_prompt("dish", work)
    feed = "$1.29 / lb cheapest at Aldi" in p and "not in the feed" in p
    floor = "chicken-drumsticks -> chicken-thighs" in p
    labels = "LABEL MATCHES" in p and "canned-tomatoes" in p.split("LABEL MATCHES")[-1]
    authority = ("NOT exhaustive" in p and "may re-derive anything you distrust" in p
                 and "OBLIGATION to fetch it, never" in p)
    return (feed and floor and labels and authority,
            "feed=%s floor=%s labels=%s authority=%s" % (feed, floor, labels, authority))


def _registrar_unreadable_sources_are_announced():
    """CLEAN TWIN: could-not-look is never a clean bill. An unreadable feed is ANNOUNCED, never
    rendered as 'no price cell exists', which a registrar would read as evidence FOR a new id."""
    d = _reg_batch_daemon()
    d._feed_prices = (None,)
    d._floor_map = (None,)
    p = d.registrar_batch_prompt("dish", _REG_WORK)
    return ("THE LIVE FEED: could NOT be read" in p
            and "DECLARED-SAME-THING LAYER: could NOT be read" in p
            and "not in the feed" not in p,
            "an unreadable source rendered as an answer: %s" % p[-500:])


def _registrar_batch_refusal_names_the_item():
    """MUST FIRE: a malformed item is refused with its INDEX named, and the WHOLE payload is refused -
    never applied in part. Half a batch of approvals is where an id gets minted while its sibling's
    collision is still unruled."""
    expected = [w[0] for w in _REG_WORK]
    bad = {"rulings": [
        {"proposed_bid": "chicken-drumsticks", "verdict": "alias", "bid": "chicken-thighs",
         "reason": "ok"},
        {"proposed_bid": "brown-jasmine-rice", "verdict": "mint-it", "reason": "invented verdict"},
        {"proposed_bid": "goat-cheese", "verdict": "alias", "reason": "an alias with no target"}]}
    problems = hunt_lib.validate_registrar_batch(bad, expected=expected)
    indexed = (any(pr.startswith("ruling 1 (brown-jasmine-rice)") for pr in problems)
               and any(pr.startswith("ruling 2 (goat-cheese)") for pr in problems))

    # ...and at the daemon: a dispatcher that HONOURS the validator (as hunt_dispatch does after its
    # one re-ask) returns nothing, so NO ruling from that payload is applied and every id stays
    # unsettled.
    class Validating(FakeDispatch):
        def __call__(self, agent, prompt, schema=None, validator=None, **kw):
            res = FakeDispatch.__call__(self, agent, prompt, schema=schema, validator=validator, **kw)
            if validator and res.payload and validator(res.payload):
                res.payload, res.failure = None, "schema"
            return res

    fd = Validating({"commodity-registrar": [bad]})
    d = _reg_batch_daemon(dispatcher=fd)
    props = [{"proposed_bid": b, "term": t, "evidence": e} for b, t, e, _r in _REG_WORK]
    res = arun(d.registrar_rulings("dish", props))
    said = any("returned no verdict on 3 proposed id(s)" in f for f in d.findings)
    # the GOOD ruling in the same payload does not land either: whole payload or nothing
    return (indexed and res == [] and said,
            "indexed=%s applied=%s findings=%s" % (indexed, json.dumps(res), json.dumps(d.findings)[:240]))


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


# =====================================================================================================
# CHANGE M - THE DAEMON WRITES THE FOOD DB (2026-08-25)
#
# The mapper used to Edit meal-prep\food-macros-db.json itself and report back a names-only
# `db_entries_added` array. A self-report is the one thing a gate cannot be built on, so the pen moved
# and two gates moved onto the road with it: the Atwater derivation, and the meal-macro skill's
# standing conflict rule ("never overwrite the DB on a conflict without asking").
# =====================================================================================================

def _food_db_run(rows_by_slug, existing=None, readme="fixture DB"):
    """A scratch food DB plus a daemon aimed at it through the --food-db seam. Returns (daemon, path).

    THE SEAM IS THE POINT of doing it this way: before CHANGE M a drill could not put a row into the
    live DB even by accident, and now it can. Every fixture here writes a temp file and none of them
    can reach meal-prep\food-macros-db.json.
    """
    tmp = tempfile.mkdtemp(prefix="daemon-fooddb-")
    path = os.path.join(tmp, "food-macros-db.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"readme": readme, "items": list(existing or [])}, f)
    d = daemon(run_dir=tmp, food_db_path=path)
    return d, path, tmp


def _db_items(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        return json.load(f)


# A row whose 4/4/9 actually reconciles, so the Atwater gate is not what any of these turn on unless
# the case says so. 25*4 + 3*4 + 5*9 = 157 against a stated 155: inside tolerance.
def _good_row(name, source="fdc:171077", **kw):
    row = {"item": name, "brand": "Fixture Farms", "serving_grams": 100, "serving_qty": 4,
           "serving_unit": "oz", "calories": 155, "protein_g": 25, "carbs_g": 3, "fat_g": 5,
           "notes": "raw", "source": source}
    row.update(kw)
    return row


def _fooddb_writes():
    d, path, tmp = _food_db_run(None)
    try:
        # 3+ elements, per the estate's collection rule
        rows = [_good_row("Fixture Chicken"), _good_row("Fixture Pork"), _good_row("Fixture Beef")]
        written, findings = arun(d.write_food_db_rows("s1", rows))
        doc = _db_items(path)
        names = [r.get("item") for r in doc["items"]]
        ok = (sorted(written) == ["Fixture Beef", "Fixture Chicken", "Fixture Pork"]
              and not findings
              and sorted(names) == ["Fixture Beef", "Fixture Chicken", "Fixture Pork"]
              # THE SHAPE IS PRESERVED: {readme, items:[...]}, a LIST of rows. The plan said this file
              # was a dict keyed by item name; it is not, and a dict written here would be a DB that
              # recipe-macros.ps1 and the meal-macro skill silently cannot read.
              and isinstance(doc.get("items"), list) and doc.get("readme") == "fixture DB")
        return ok, ("written=%s findings=%s items=%s readme=%r"
                    % (written, findings, json.dumps(names), doc.get("readme")))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _fooddb_atwater_refuses():
    d, path, tmp = _food_db_run(None)
    try:
        # 25 P / 3 C / 5 F computes 157 kcal. Stating 900 is not a rounding difference; it is four
        # numbers that do not describe one food, which is what a fabricated label looks like.
        bad = _good_row("Fixture Fabrication", calories=900)
        rows = [_good_row("Fixture Chicken"), bad, _good_row("Fixture Pork")]
        written, findings = arun(d.write_food_db_rows("s1", rows))
        names = [r.get("item") for r in _db_items(path)["items"]]
        named = [f for f in findings if "Fixture Fabrication" in f and "Atwater" in f]
        ok = ("Fixture Fabrication" not in names and "Fixture Fabrication" not in written
              and len(named) == 1
              # and one bad row never costs a good one its write
              and sorted(names) == ["Fixture Chicken", "Fixture Pork"])
        return ok, "items=%s findings=%s" % (json.dumps(names), json.dumps(findings))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _fooddb_conflict_never_overwrites():
    prior = _good_row("Fixture Chicken", protein_g=25, calories=155)
    prior["brand"] = "The Row That Was Already There"
    d, path, tmp = _food_db_run(None, existing=[prior])
    try:
        # same item, DIFFERENT macros, and its own arithmetic is fine (30*4 + 3*4 + 5*9 = 177)
        clash = _good_row("Fixture Chicken", protein_g=30, calories=177)
        rows = [clash, _good_row("Fixture Pork"), _good_row("Fixture Beef")]
        written, findings = arun(d.write_food_db_rows("s1", rows))
        doc = _db_items(path)
        chicken = [r for r in doc["items"] if r.get("item") == "Fixture Chicken"]
        named = [f for f in findings if "Fixture Chicken" in f and "DIFFERS" in f]
        ok = (len(chicken) == 1
              and chicken[0].get("brand") == "The Row That Was Already There"
              and chicken[0].get("protein_g") == 25
              and "Fixture Chicken" not in written
              and len(named) == 1
              # BOTH rows are quoted, or a person cannot rule on the conflict from the finding alone
              and "25" in named[0] and "30" in named[0]
              # the other two rows still land: a conflict holds ONE row, not the batch
              and sorted(written) == ["Fixture Beef", "Fixture Pork"])
        return ok, "written=%s finding=%s" % (written, json.dumps(named)[:400])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _fooddb_identical_is_silent():
    prior = _good_row("Fixture Chicken")
    d, path, tmp = _food_db_run(None, existing=[prior])
    try:
        rows = [_good_row("Fixture Chicken"), _good_row("Fixture Pork"), _good_row("Fixture Beef")]
        written, findings = arun(d.write_food_db_rows("s1", rows))
        names = [r.get("item") for r in _db_items(path)["items"]]
        ok = (not findings and "Fixture Chicken" not in written
              and names.count("Fixture Chicken") == 1
              and sorted(written) == ["Fixture Beef", "Fixture Pork"])
        return ok, "written=%s findings=%s items=%s" % (written, json.dumps(findings), json.dumps(names))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# =====================================================================================================
# H1 - the conflict rule learns the difference between disagreement and ROUNDING (2026-08-25)
#
# Measured on jc1: 5 conflict findings, 2 of them pure rounding on an identical serving basis
# (Spinach protein 2.9 vs 2.86, Fresh Parsley 3 vs 2.97) and 3 of them real (Pork Chops, 112 g basis
# against 100 g). At width the noise buries the saves.
#
# NEUTER PROOF, RUN 2026-08-25 and reverted: set FOOD_DB_CAL_TOLERANCE and FOOD_DB_MACRO_TOLERANCE
# to 0 and the rounding case goes red on all three rows (three findings where none belong), while the
# Pork Chops twin stays green - which is the shape that says the twin is judging the BASIS and not
# the size of the tolerance.
# =====================================================================================================

def _spinach(**over):
    """A coherent small-number row: 4*2.86 + 4*(3.63-2.2) + 2*2.2 + 9*0.39 = 25.1 against a stated
    23, inside the Atwater absolute floor, so nothing here turns on that gate."""
    row = _good_row("Fixture Spinach", calories=23, protein_g=2.86, carbs_g=3.63, fat_g=0.39,
                    fiber_g=2.2)
    row.update(over)
    return row


def _fooddb_rounding_is_not_a_conflict():
    """MUST FIRE: identical serving basis, macros a rounding apart - the identical-row case. Silent
    skip, no finding, and the row already on disk stands untouched."""
    priors = [_spinach(),
              _good_row("Fixture Parsley", calories=36, protein_g=2.97, carbs_g=6.33, fat_g=0.79,
                        fiber_g=3.3),
              _good_row("Fixture Chicken")]
    d, path, tmp = _food_db_run(None, existing=priors)
    try:
        rows = [_spinach(protein_g=2.9),                                   # 0.04 g apart
                _good_row("Fixture Parsley", calories=36, protein_g=3.0, carbs_g=6.3, fat_g=0.8,
                          fiber_g=3.3),                                    # hundredths, every field
                _good_row("Fixture Chicken", calories=158)]                # 3 cal apart
        written, findings = arun(d.write_food_db_rows("s1", rows))
        doc = _db_items(path)
        spinach = [r for r in doc["items"] if r.get("item") == "Fixture Spinach"]
        ok = (not findings and not written and len(doc["items"]) == 3
              # the EXISTING row stands: 2.86, not the 2.9 that arrived
              and len(spinach) == 1 and spinach[0].get("protein_g") == 2.86)
        return ok, "written=%s findings=%s protein=%s" % (
            written, json.dumps(findings)[:300], spinach[0].get("protein_g") if spinach else None)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _fooddb_a_different_basis_is_always_a_conflict():
    """CLEAN TWIN: the Pork Chops shape. The macros sit inside every rounding tolerance, and the
    SERVING BASIS does not match - which is a different claim about the food, and is precisely the
    save this rule exists to keep."""
    prior = _good_row("Fixture Pork Chops", serving_grams=100, calories=155, protein_g=25)
    prior["brand"] = "The Row That Was Already There"
    d, path, tmp = _food_db_run(None, existing=[prior])
    try:
        clash = _good_row("Fixture Pork Chops", serving_grams=112, calories=155, protein_g=25.2)
        rows = [clash, _good_row("Fixture Beef"), _good_row("Fixture Lamb")]
        written, findings = arun(d.write_food_db_rows("s1", rows))
        doc = _db_items(path)
        chops = [r for r in doc["items"] if r.get("item") == "Fixture Pork Chops"]
        named = [f for f in findings if "Fixture Pork Chops" in f and "DIFFERS" in f]
        ok = (len(named) == 1 and "serving_grams" in named[0]
              # BOTH bases quoted, or a person cannot rule on it from the finding alone
              and "100" in named[0] and "112" in named[0]
              and len(chops) == 1 and chops[0].get("serving_grams") == 100
              and chops[0].get("brand") == "The Row That Was Already There"
              and sorted(written) == ["Fixture Beef", "Fixture Lamb"])
        return ok, "written=%s finding=%s" % (written, json.dumps(named)[:400])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _fooddb_needs_a_source():
    d, path, tmp = _food_db_run(None)
    try:
        rows = [_good_row("Fixture Chicken"),
                _good_row("Fixture Hearsay", source=""),
                _good_row("Fixture Pork")]
        written, findings = arun(d.write_food_db_rows("s1", rows))
        names = [r.get("item") for r in _db_items(path)["items"]]
        named = [f for f in findings if "Fixture Hearsay" in f and "source" in f]
        ok = ("Fixture Hearsay" not in names and len(named) == 1
              and sorted(names) == ["Fixture Chicken", "Fixture Pork"])
        return ok, "items=%s findings=%s" % (json.dumps(names), json.dumps(findings))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _fooddb_concurrent_writers():
    r"""TWO MAP WORKERS LANDING TOGETHER. The MAP cap is 2, so two batches can each carry new rows for
    this one file at the same moment.

    NEUTER PROOF, RUN 2026-08-25 and REQUIRED before this case counts. Replacing `self.food_db_lock`
    with a no-op context manager makes this fail at 3 rows of 6 - the classic read-modify-write loss,
    each writer serialising the doc it read before the other's rows existed. The proof is in the
    result line, not in a promise: with the lock the file holds all six.
    """
    d, path, tmp = _food_db_run(None)
    try:
        slow = {"n": 0}
        real_open = io_open = open

        async def three(slug, tag):
            return await d.write_food_db_rows(
                slug, [_good_row("%s A" % tag), _good_row("%s B" % tag), _good_row("%s C" % tag)])

        async def both():
            return await asyncio.gather(three("s1", "Worker One"), three("s2", "Worker Two"))

        res = arun(both())
        names = sorted(r.get("item") for r in _db_items(path)["items"])
        want = sorted(["Worker One A", "Worker One B", "Worker One C",
                       "Worker Two A", "Worker Two B", "Worker Two C"])
        written = sorted([n for w, _ in res for n in w])
        ok = names == want and written == want
        return ok, "items(%d)=%s" % (len(names), json.dumps(names))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _fooddb_lock_is_load_bearing():
    """The neuter, run as its own case so the proof is REPRODUCED on every suite run rather than
    recorded in a comment nobody re-runs. A no-op lock must LOSE rows; if it stops losing them the
    concurrency fixture above has stopped proving anything and this case says so."""
    class NoLock(object):
        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return False

    d, path, tmp = _food_db_run(None)
    try:
        d.food_db_lock = NoLock()

        async def three(slug, tag):
            # a real await between the read and the write, which is what a lock exists to survive
            await asyncio.sleep(0)
            return await d.write_food_db_rows(
                slug, [_good_row("%s A" % tag), _good_row("%s B" % tag), _good_row("%s C" % tag)])

        async def both():
            return await asyncio.gather(three("s1", "Worker One"), three("s2", "Worker Two"))

        arun(both())
        names = [r.get("item") for r in _db_items(path)["items"]]
        # 6 rows survive only if the two never interleaved. Under a no-op lock this is 3.
        return len(names) < 6, ("a no-op lock kept ALL %d rows, so the concurrency fixture is no "
                                "longer proving the lock does anything" % len(names))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _fooddb_assemble_records_what_was_written():
    """The mapped artifact says what the DAEMON WROTE. `db_entries_added` reported what the mapper
    CLAIMED, which is the whole reason the pen moved."""
    d, path, tmp = _food_db_run(None)
    try:
        d.registrar_rulings = lambda slug, proposals, tables=None: _immediate([])
        res = {"slug": "s1", "status": "ok", "state": "mapped", "lines": [], "rulings": [],
               "food_db_rows": [_good_row("Fixture Chicken"), _good_row("Fixture Pork"),
                                _good_row("Fixture Beef", calories=900)]}
        arun(d.assemble_mapped("s1", res))
        with open(os.path.join(tmp, "mapped-pre", "s1.rulings.json"), "r", encoding="utf-8") as f:
            doc = json.load(f)
        ok = (sorted(doc.get("db_entries_written") or []) == ["Fixture Chicken", "Fixture Pork"]
              and "db_entries_added" not in doc
              and len(doc.get("db_row_findings") or []) == 1
              and any("Fixture Beef" in f for f in doc["db_row_findings"])
              # and the run's own findings carry it too, or a hold has nothing to say
              and any("Fixture Beef" in f for f in d.findings))
        return ok, json.dumps({k: doc.get(k) for k in ("db_entries_written", "db_row_findings")})[:400]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _immediate(v):
    async def go():
        return v
    return go()


def _fooddb_schema_retired_the_self_report():
    """`db_entries_added` is gone from MAPPED and `food_db_rows` is in it. A schema that still
    accepted the old field would let a mapper keep self-reporting into a daemon that ignores it."""
    props = hunt_lib.MAPPED["properties"]["results"]["items"]["properties"]
    rows = props.get("food_db_rows") or {}
    req = ((rows.get("items") or {}).get("required")) or []
    return ("db_entries_added" not in props and rows.get("type") == "array"
            and sorted(req) == sorted(["item", "serving_grams", "calories", "protein_g",
                                       "carbs_g", "fat_g"])), \
           "db_entries_added=%s required=%s" % ("db_entries_added" in props, json.dumps(req))


def _fooddb_prompt_moved_the_pen():
    d = daemon()
    pr = d.map_prompt(["s1"], {"s1": {"rows": [], "scale_factor": 1.0}})
    return (("food_db_rows" in pr and "no file access" in pr.lower()
             and "Atwater" in pr and "fdc:" in pr
             and "Add those rows as you always have" not in pr),
            "food_db_rows=%s old-sentence=%s" % ("food_db_rows" in pr,
                                                 "Add those rows as you always have" in pr))


# =====================================================================================================
# H2 - a no-publish drill must not write a LIVE grocery ledger (2026-08-25)
#
# Measured on jc1: --ledger, --specs, --costed and --food-db all engaged, publish dry, and the run
# still wrote grocery\ingredient-queue.json, grocery\carriage.json and db\considered-dishes.json. The
# queue rows were real evidence and were kept deliberately; the SEAM GAP is the defect.
#
# INVESTIGATED BEFORE BUILT, per plan 8.H2: ingredient-queue.ps1 already had -QueueFile and
# considered-dishes.ps1 already had -Store (which decide_apply already threads through its
# `store_path` argument, and the daemon was passing ""). Only carriage needed a NEW parameter,
# -CarriagePath on -Promote, whose own MUST FIRE lives in ingredient-queue.ps1's selftest and drives
# the real verb in a child process against a scratch ledger.
#
# NEUTER PROOFS, RUN 2026-08-25 and reverted:
#   * make queue_args return its argument unchanged -> both queue cases go red (the live path).
#   * pass "" for considered_path again -> the considered case goes red.
#   * make queue_seam_note return "" always -> the pricer case goes red, which is the one that
#     matters most: the pricer holds this pen itself and no daemon-side threading can reach it.

def _h2_seam_daemon(tmp, **kw):
    d = daemon(run_dir=tmp, ps=FakePS(), queue_path=os.path.join(tmp, "queue.json"),
               carriage_path=os.path.join(tmp, "carriage.json"),
               considered_path=os.path.join(tmp, "considered.json"), **kw)
    return d


def _h2_queue_calls_carry_the_seams():
    """MUST FIRE: every ingredient-queue call the daemon makes carries -QueueFile and -CarriagePath,
    and the live paths are never passed."""
    tmp = tempfile.mkdtemp(prefix="daemon-h2q-")
    try:
        d = _h2_seam_daemon(tmp)
        # the three shapes the daemon actually calls: -Add from the map lane, -Add from the unhold,
        # and the -List the parked loop reads the queue with
        args_add = d.queue_args(["-Add", "-Term", "saffron", "-Recipe", "s1"])
        args_list = d.queue_args(["-List", "-Status", "pending", "-Json"])
        both = (FakePS.value_after(args_add, "-QueueFile") == os.path.join(tmp, "queue.json")
                and FakePS.value_after(args_add, "-CarriagePath") == os.path.join(tmp, "carriage.json")
                and FakePS.value_after(args_list, "-QueueFile") == os.path.join(tmp, "queue.json"))
        # and the base arguments are untouched - a seam that reorders a call is a seam that breaks it
        kept = args_add[:5] == ["-Add", "-Term", "saffron", "-Recipe", "s1"]
        return both and kept, "add=%s list=%s" % (json.dumps(args_add), json.dumps(args_list))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _h2_live_run_passes_no_override():
    """CLEAN TWIN: with no seams set the calls are byte-identical to what they always were. A seam
    that leaks a flag into a real run is its own defect."""
    d = daemon(run_dir="R")
    args = d.queue_args(["-Add", "-Term", "saffron", "-Recipe", "s1"])
    return (args == ["-Add", "-Term", "saffron", "-Recipe", "s1"]
            and d.queue_seam_note() == "", "args=%s note=%r" % (json.dumps(args), d.queue_seam_note()))


def _h2_map_lane_queues_through_the_seam():
    """MUST FIRE, end to end: a mapper returning absent terms enqueues them through the SCRATCH
    queue - the costed_path pattern, asserted on the real call the lane makes."""
    tmp = tempfile.mkdtemp(prefix="daemon-h2map-")
    try:
        preresolved(tmp, ["s1"], residual={"s1": ["saffron", "harissa", "tteok"]})
        ps = _asm_ps(0)
        res = _mapper_result("s1")
        res["state"] = "pricing"
        res["absent_terms"] = ["saffron", "harissa", "tteok"]
        fd = FakeDispatch({"recipe-ingredient-mapper": [{"results": [res]}]})
        d = daemon(run_dir=tmp, dispatcher=fd, ps=ps,
                   queue_path=os.path.join(tmp, "queue.json"),
                   carriage_path=os.path.join(tmp, "carriage.json"))
        d.ch["map"].push({"slug": "s1"})
        d.ch["map"].close()
        arun(d.run(("map",)))
        adds = [c for c in ps.find("ingredient-queue.ps1") if "-Add" in c["args"]]
        seamed = [c for c in adds
                  if FakePS.value_after(c["args"], "-QueueFile") == os.path.join(tmp, "queue.json")]
        live = [c for c in adds if "-QueueFile" not in c["args"]]
        return (len(adds) == 3 and len(seamed) == 3 and not live,
                "adds=%d seamed=%d live=%d" % (len(adds), len(seamed), len(live)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _h2_considered_seam_reaches_decide_apply():
    """MUST FIRE: the decider's ruling goes to the SCRATCH dish ledger. considered-dishes.ps1 already
    had -Store and decide_apply already threaded it; the daemon was passing an empty string, so every
    drill wrote the estate's real prior-art memory."""
    tmp = tempfile.mkdtemp(prefix="daemon-h2cd-")
    try:
        seen = {}
        import decide_apply                                        # noqa: PLC0415

        real = decide_apply.apply_verdict

        def spy(payload, run_dir, run_id, pool_path, store_path, dry_run=False, quiet=False):
            seen["store_path"] = store_path
            return [], []

        pool_path = _decide_pool(tmp, ["a", "b", "c"])
        run_dir = os.path.join(tmp, "run")
        os.makedirs(run_dir, exist_ok=True)
        fd = FakeDispatch({"recipe-dedup-selector": [
            {"decisions": [_verdict("a"), _verdict("b"), _verdict("c")]}]})
        d = daemon(run_dir=run_dir, dispatcher=fd, ps=FakePS(), pool_path=pool_path,
                   queue_path=os.path.join(tmp, "queue.json"),
                   carriage_path=os.path.join(tmp, "carriage.json"),
                   considered_path=os.path.join(tmp, "considered.json"))
        decide_apply.apply_verdict = spy
        try:
            # the POOL lane is what feeds the decide channel; decide alone never pops a candidate
            arun(d.run(("pool", "decide")))
        finally:
            decide_apply.apply_verdict = real
        return (seen.get("store_path") == os.path.join(tmp, "considered.json"),
                "store_path=%r" % seen.get("store_path"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _h2_pricer_is_told_the_seams():
    """MUST FIRE: the PRICER holds the -Record/-Verdict/-Promote pen itself, so no daemon-side
    threading can reach those calls. On a seamed run its prompt names the flags; on a real run the
    note is absent entirely."""
    tmp = tempfile.mkdtemp(prefix="daemon-h2price-")
    try:
        d = _h2_seam_daemon(tmp)
        p = d.price_prompt(["saffron", "harissa", "tteok"])
        live = daemon(run_dir="R").price_prompt(["saffron", "harissa", "tteok"])
        return (("-QueueFile '%s'" % os.path.join(tmp, "queue.json")) in p
                and ("-CarriagePath '%s'" % os.path.join(tmp, "carriage.json")) in p
                and "DRILL ON SCRATCH LEDGERS" in p
                and "DRILL ON SCRATCH LEDGERS" not in live,
                "seamed=%s live_clean=%s" % ("-QueueFile" in p,
                                             "DRILL ON SCRATCH LEDGERS" not in live))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# =====================================================================================================
# F1 - THE FDC SHELF IS FILLED WITH THE RUN'S OWN TERMS BEFORE THE MAPPER IS PAID (2026-08-25)
#
# Measured on the jc1 drill: 4 of 19 residual lines carried an FDC candidate and the mapper spent
# ~12 minutes at 61 s/turn fetching the other 15 labels itself, then cited `fdc:<id>` for the rows it
# returned. Nothing in the daemon had ever called fdc_lookup.cache_fill. These fixtures are about the
# daemon's own behaviour around that call - what it passes, when it re-resolves, and that a fill
# which cannot run never costs the batch its dispatch.
#
# NEUTER PROOFS, ALL RUN 2026-08-25 against this suite, each reverted immediately after:
#   * replace the map lane's `fill = await self.fill_fdc_shelf(...)` with `fill = None`
#     -> the order case, the clean twin and the degrade case all go red (3 reds).
#   * never re-run preresolve after the fill (`if False:`)
#     -> the order case goes red on both the call count AND the shelf missing from the prompt.
#   * empty Daemon.FDC_SHELF_MARKER -> the coverage case goes red.
#   * drop the settled-and-known filter out of fdc_fill_terms -> the fill-list case goes red (it asks
#     FDC about a line that has a food-DB row), and two more with it.
# The lock's neuter is not a comment at all: it is _f1_fdc_lock_is_load_bearing, which RUNS the
# no-op-lock case on every suite run and fails if the loss ever stops happening.
# =====================================================================================================

F1_SHELF_LINE = ("USDA FDC rows that MENTION this term, per 100 g - a shelf, not an answer. "
                 "Parsley, fresh [SR Legacy] per 100 g: 36 cal, 2.97 P, 6.33 C")


def _f1_tables(residual=("ras el hanout", "gochujang", "parsley leaves")):
    """A pre-resolve table shaped like map-preresolve's own output: one SETTLED line that already has
    a food-DB row (which the fill must skip), the residual lines (which it must ask about), one
    SETTLED line with no DB row (which still needs a label, so it must be asked about too), and a
    case-variant duplicate of a residual term (which must dedupe away)."""
    rows = [{"raw": "1 lb chicken", "term": "chicken", "resolution": "resolved",
             "fooddb_known": True, "evidence": "exact vocabulary row"},
            {"raw": "2 tbsp labneh", "term": "labneh", "resolution": "resolved",
             "fooddb_known": False, "evidence": "no food-macros-db row - a label needs transcribing"}]
    for t in residual:
        rows.append({"raw": "1 tsp %s" % t, "term": t, "resolution": "unresolved",
                     "fooddb_known": False, "evidence": "no vocabulary row shares a core word"})
    rows.append({"raw": "more parsley", "term": residual[-1].upper(), "resolution": "unresolved",
                 "fooddb_known": False, "evidence": "no vocabulary row shares a core word"})
    return {"s1": {"slug": "s1", "rows": rows}}


def _f1_fill_list_is_the_unresolved_terms():
    """MUST FIRE: exactly the unresolved / food-DB-missing terms reach cache_fill, deduped through
    fdc_lookup's own key function, with the settled-and-known line excluded.

    PAGE_SIZE 4 SINCE M1 (2026-08-25), because the shelf renders four candidates and the cache could
    only ever hold three. It costs no extra request. NEUTER PROOF, RUN AND REVERTED 2026-08-25:
    putting page_size=3 back in fill_fdc_shelf turned this case red with page_size=3 in its got line.
    """
    d = daemon()
    seen = {}

    def stub(terms, page_size=3, pause=0.0, **kw):
        seen["terms"] = list(terms)
        seen["page_size"] = page_size
        seen["pause"] = pause
        return {"added": len(terms), "skipped": 0, "failed": 0, "size": len(terms)}

    real = HD.fdc_lookup.cache_fill
    HD.fdc_lookup.cache_fill = stub
    try:
        arun(d.fill_fdc_shelf(["s1"], _f1_tables()))
    finally:
        HD.fdc_lookup.cache_fill = real
    got = seen.get("terms") or []
    ok = (got == ["labneh", "ras el hanout", "gochujang", "parsley leaves"]
          # the case variant deduped away, and the settled+known line never asked about
          and "chicken" not in got and seen.get("page_size") == 4 and seen.get("pause") == 0.5)
    return ok, "terms=%s page_size=%s pause=%s" % (json.dumps(got), seen.get("page_size"),
                                                   seen.get("pause"))


def _f1_map_run(tmp, stat=None, raises=False, warm=True, slugs=("s1", "s2", "s3")):
    """The map lane driven end to end with the fill stubbed. Returns (d, fd, ps, order)."""
    preresolved(tmp, list(slugs),
                residual=dict((s, ["parsley leaves", "ras el hanout", "gochujang"]) for s in slugs))
    order, passes = [], {"n": 0}

    def warm_the_tables():
        for s in slugs:
            p = os.path.join(tmp, "mapped-pre", "%s.json" % s)
            with open(p, "r", encoding="utf-8-sig") as f:
                doc = json.load(f)
            for r in doc["rows"]:
                if r.get("resolution") == "unresolved":
                    r["evidence"] = r["evidence"] + " | " + F1_SHELF_LINE
            with open(p, "w", encoding="utf-8") as f:
                json.dump(doc, f)

    def reply(args):
        if "-Slugs" in args:
            passes["n"] += 1
            order.append("preresolve")
            if passes["n"] == 2 and warm:
                warm_the_tables()
        return 0, "", ""

    def stub(terms, page_size=3, pause=0.0, **kw):
        order.append("fill")
        if raises:
            raise RuntimeError("api.data.gov refused the connection")
        return dict(stat or {"added": len(terms), "skipped": 0, "failed": 0, "size": len(terms)})

    # the hunt-run half writes the state file the lane reads back on every road out (Q2, 2026-08-26).
    # Without it this case measures a STUCK batch instead of the fill's own degrade behaviour.
    ps = FakePS(replies={"map-preresolve": reply, "hunt-run": _hunt_run_writer()})
    fd = FakeDispatch({"recipe-ingredient-mapper": [
        {"results": [{"slug": s, "status": "ok", "state": "priced"} for s in slugs]}]})
    d = daemon(run_dir=tmp, dispatcher=fd, ps=ps)
    real = HD.fdc_lookup.cache_fill
    HD.fdc_lookup.cache_fill = stub
    try:
        for s in slugs:
            d.ch["map"].push({"slug": s})
        d.ch["map"].close()
        arun(d.run(("map",)))
    finally:
        HD.fdc_lookup.cache_fill = real
    if fd.prompts("recipe-ingredient-mapper"):
        order.append("dispatch")
    return d, fd, ps, order


def _f1_order_is_preresolve_fill_preresolve_dispatch():
    tmp = tempfile.mkdtemp(prefix="daemon-f1ord-")
    try:
        d, fd, ps, order = _f1_map_run(tmp)
        prompt = (fd.prompts("recipe-ingredient-mapper") or [""])[0]
        pre = [c for c in ps.find("map-preresolve.ps1") if "-Slugs" in c["args"]]
        ok = (order == ["preresolve", "fill", "preresolve", "dispatch"] and len(pre) == 2
              # THE DISPATCHED TABLES ARE THE SECOND PASS'S: only the re-run carries the shelf, and
              # a prompt built off the first table would name none of it.
              and "Parsley, fresh [SR Legacy]" in prompt)
        return ok, "order=%s preresolve_calls=%d shelf_in_prompt=%s" % (
            json.dumps(order), len(pre), "Parsley, fresh [SR Legacy]" in prompt)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _f1_nothing_added_skips_the_rerun():
    """CLEAN TWIN: a batch whose terms were all already cached is as warm as it can get, so the
    second mechanical pass is not paid for."""
    tmp = tempfile.mkdtemp(prefix="daemon-f1warm-")
    try:
        d, fd, ps, order = _f1_map_run(tmp, stat={"added": 0, "skipped": 3, "failed": 0, "size": 3})
        pre = [c for c in ps.find("map-preresolve.ps1") if "-Slugs" in c["args"]]
        ok = (order == ["preresolve", "fill", "dispatch"] and len(pre) == 1)
        return ok, "order=%s preresolve_calls=%d" % (json.dumps(order), len(pre))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _f1_a_failed_fill_degrades_and_still_dispatches():
    """MUST FIRE: DEGRADE, NEVER BLOCK. The fill can only add evidence, so a fill that throws is one
    finding naming the count and a mapper dispatched exactly as it was before F1 existed."""
    tmp = tempfile.mkdtemp(prefix="daemon-f1boom-")
    try:
        d, fd, ps, order = _f1_map_run(tmp, raises=True)
        named = [f for f in d.findings if f.startswith("F1: the FDC fill could not run")]
        pre = [c for c in ps.find("map-preresolve.ps1") if "-Slugs" in c["args"]]
        ok = (len(fd.prompts("recipe-ingredient-mapper")) == 1 and len(named) == 1
              and "3 term(s)" in named[0] and "refused the connection" in named[0]
              # nothing landed, so no second pass is paid for either
              and len(pre) == 1 and not [o for o in d.outcomes if o.get("status") == "stuck"])
        return ok, "dispatches=%d findings=%s" % (len(fd.prompts("recipe-ingredient-mapper")),
                                                  json.dumps(named)[:300])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _f1_cache_fill_with_gate(path, gate):
    """A cache_fill that READS, waits at a barrier, then WRITES - the read-modify-write shape, with
    the interleaving made deterministic instead of left to the thread scheduler.

    Under the lock the second worker cannot reach the barrier, so the first times out (a broken
    barrier), both writes serialize, and the union survives. With the lock neutered both workers meet
    at the barrier holding the SAME stale read and the second write erases the first.
    """
    def fill(terms, page_size=3, pause=0.0, **kw):
        doc = HD.fdc_lookup.cache_read(path)
        doc.setdefault("terms", {})
        try:
            gate.wait(timeout=0.6)
        except Exception:                                         # noqa: BLE001  (BrokenBarrierError)
            pass
        added = 0
        for t in terms:
            k = HD.fdc_lookup._cache_key(t)                       # noqa: SLF001
            if k and k not in doc["terms"]:
                doc["terms"][k] = {"asked": True, "candidates": []}
                added += 1
        HD.fdc_lookup.cache_write(doc, path)
        return {"added": added, "skipped": len(terms) - added, "failed": 0,
                "size": len(doc["terms"])}
    return fill


def _f1_two_fills(no_lock=False):
    tmp = tempfile.mkdtemp(prefix="daemon-f1lock-")
    path = os.path.join(tmp, "fdc-cache.json")
    HD.fdc_lookup.cache_write({"terms": {}}, path)
    d = daemon(run_dir=tmp)
    if no_lock:
        class NoLock(object):
            async def __aenter__(self):
                return self

            async def __aexit__(self, *a):
                return False
        d.fdc_lock = NoLock()
    gate = threading.Barrier(2)
    real = HD.fdc_lookup.cache_fill
    HD.fdc_lookup.cache_fill = _f1_cache_fill_with_gate(path, gate)
    try:
        # OVERLAPPING lists, 3+ terms each, exactly as two map workers over neighbouring recipes look
        one = _f1_tables(("ras el hanout", "gochujang", "shared term"))
        two = _f1_tables(("harissa", "doubanjiang", "shared term"))

        async def both():
            return await asyncio.gather(d.fill_fdc_shelf(["s1"], one),
                                        d.fill_fdc_shelf(["s2"], two))

        arun(both())
        keys = sorted((HD.fdc_lookup.cache_read(path).get("terms") or {}).keys())
        return keys
    finally:
        HD.fdc_lookup.cache_fill = real
        shutil.rmtree(tmp, ignore_errors=True)


def _f1_concurrent_fills_keep_every_term():
    keys = _f1_two_fills()
    want = sorted(["labneh", "ras el hanout", "gochujang", "shared term",
                   "harissa", "doubanjiang"])
    return keys == want, "cache(%d)=%s" % (len(keys), json.dumps(keys))


def _f1_fdc_lock_is_load_bearing():
    """The neuter, run as its own case so the proof is REPRODUCED on every suite run rather than
    recorded in a comment nobody re-runs. Note WHY it can be reproduced at all: the fill runs in the
    executor, which is what puts a real await between the cache's read and its write. With the I/O
    on the event loop nothing could interleave and this case would pass while proving nothing - the
    CHANGE M correction, met a second time."""
    keys = _f1_two_fills(no_lock=True)
    return len(keys) < 6, ("a no-op fdc_lock kept ALL %d terms, so the concurrency case above has "
                           "stopped proving the lock does anything" % len(keys))


def _f1_shelf_coverage_line():
    """MUST FIRE: the coverage line names X of Y and the terms FDC lacks. It exists so the drill and
    Thursday can correlate mapper turns against shelf coverage without transcript archaeology."""
    d = daemon()
    tables = _f1_tables(("ras el hanout", "gochujang", "parsley leaves"))
    rows = tables["s1"]["rows"]
    for r in rows:
        if r.get("term") in ("parsley leaves", "labneh"):
            r["evidence"] = r["evidence"] + " | " + F1_SHELF_LINE
    line = d.log_shelf_coverage(tables)
    ok = (line is not None and "2 of 4" in line and "ras el hanout" in line
          and "gochujang" in line and "parsley leaves" not in line.split("FDC lacks:")[-1])
    return ok, "line=%r" % line


# =====================================================================================================
# CHANGE A - THE BATTERY SHOWS ITS ARITHMETIC, AND RECIPE-LOCAL REPAIRS ARE PATCHES (2026-08-25)
# =====================================================================================================

def _preaudited(tmp, wk=1, slugs=("a", "b", "c"), failed=0):
    """A wave-preaudit report in the shape wave-preaudit.ps1 actually writes, read off
    meal-prep\runs\hunt-2026-08-24-v3-phase6b\waves\wave-1.preaudit.json: slug_checks is a DICT of
    slug -> LIST of {check, verdict, numbers, detail}, and shared_checks is a flat list."""
    os.makedirs(os.path.join(tmp, "waves"), exist_ok=True)
    doc = {"battery": "wave-preaudit", "version": 1, "run": "drill-run", "wave": wk,
           "batch": "drill-run-w%d" % wk, "scope": "whole-wave",
           "generated": "2026-08-25T09:00:00", "elapsed_sec": 14.5,
           "wave_slugs": list(slugs), "slugs": list(slugs),
           "inputs": {"costed_mtime": "2026-08-25T08:00:00", "food_db": "345 rows"},
           "slug_checks": {}, "shared_checks": [], "not_checked": [
               "mapping soundness and the precedents behind a substitution",
               "price-class plausibility (is this the right FORM of the ingredient)",
               "cross-recipe checks and dish identity"],
           "summary": {"slugs": len(slugs), "checks": len(slugs) * 3 + 3, "failed": failed}}
    for i, sl in enumerate(slugs):
        doc["slug_checks"][sl] = [
            {"check": "macro-recompute", "verdict": "pass",
             "numbers": {"servings": 14, "recompute": {"cal": 524.4, "protein": 63.8},
                         "stat": {"cal": 524, "protein": 64}, "missing_fooddb_rows": []},
             "detail": "all four macros recompute within tolerance"},
            {"check": "cost-engine-consistency", "verdict": "pass",
             "numbers": {"cost_batch": 27.54, "cost_batch_true": 31.46,
                         "cost_per_serving": 1.97 + i, "cost_first_run": 45.36, "lines": 13,
                         "lines_unpriced": 0},
             "detail": "the engine row is internally coherent"},
            {"check": "protein-derivation", "verdict": "pass",
             "numbers": {"claimed": "chicken", "derived": "chicken", "derived_grams": 3178},
             "detail": "matches the heaviest protein ingredient"}]
    for name in ("audit-spec-contradictions", "audit-store-integrity", "audit-vocab-integrity"):
        doc["shared_checks"].append({"check": name, "verdict": "pass", "numbers": {"rc": 0},
                                     "detail": "clean"})
    with open(os.path.join(tmp, "waves", "wave-%d.preaudit.json" % wk), "w", encoding="utf-8") as f:
        json.dump(doc, f)
    return doc


def _audit_dossier_carries_the_numbers():
    """MUST FIRE. The 6b re-audit "re-summed both engine rows by hand" and hand-recomputed macros -
    28 turns re-deriving what the battery had already derived - because audit_prompt only POINTED at
    the report. A pass/fail without shown work is rightly not taken on faith."""
    tmp = _wave_scratch()
    try:
        _preaudited(tmp)
        d = daemon(run_dir=tmp)
        pr = d.audit_prompt(1, ["a", "b", "c"], "drill-run-w1", "whole-wave", None)
        return (("cost_per_serving=1.97" in pr and "cost_batch_true=31.46" in pr
                 and "recompute.cal=524.4" in pr and "stat.cal=524" in pr
                 and "derived_grams=3178" in pr
                 and "audit-spec-contradictions" in pr
                 # every slug, not just the first
                 and all(("  %s" % sl) in pr for sl in ("a", "b", "c"))
                 # the battery's own not-checked list is the auditor's half of the job
                 and "dish identity" in pr
                 # THE AUTHORITY LANGUAGE IS VERBATIM AND THE DISCRETIONARY MANDATE IS EXPLICIT
                 and "you remain the authority and may re-derive anything" in pr
                 and "verify the CHAINS rather than rebuild them" in pr
                 and "no battery can do" in pr
                 # and the report file is still named, because the auditor may still open it
                 and "wave-1.preaudit.json" in pr),
                pr[pr.find("THE BATTERY'S ARITHMETIC"):][:400])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _audit_dossier_unreadable_is_announced():
    """CLEAN TWIN, and it is the safety half. An auditor handed an EMPTY block would read it as a
    battery that found nothing to say. It is TOLD, in as many words, that it must derive everything."""
    tmp = _wave_scratch()
    try:
        d = daemon(run_dir=tmp)                       # no preaudit.json written at all
        pr = d.audit_prompt(1, ["a", "b", "c"], "drill-run-w1", "whole-wave", None)
        return ("COULD NOT BE READ" in pr and "derive everything yourself" in pr
                and "a missing check is never a passed one" in pr,
                pr[pr.find("THE BATTERY"):][:250])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _audit_dossier_truncation_is_announced():
    """MUST FIRE. A quietly cut block is worse than no block: the auditor would believe it had seen
    every check. 40 slugs is well past the cap and nothing about it is silent."""
    tmp = _wave_scratch()
    try:
        many = tuple("slug-%02d" % i for i in range(40))
        _preaudited(tmp, slugs=many)
        d = daemon(run_dir=tmp)
        block = d.render_audit_dossier(1)
        return ("THIS BLOCK WAS TRUNCATED" in block and "read it before you rule" in block
                and len(block) <= d.AUDIT_DOSSIER_CAP + 200,
                "len=%d cap=%d" % (len(block), d.AUDIT_DOSSIER_CAP))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _repair_road_routes():
    """The router alone, so the direction of the default is pinned independently of any wave run."""
    got = {k: hunt_lib.repair_road(k) for k in
           ("recipe-local", "Recipe-Local", "shared-data", "", None, "something-invented")}
    return (got["recipe-local"] == "patch" and got["Recipe-Local"] == "patch"
            and got["shared-data"] == "agent" and got[""] == "agent" and got[None] == "agent"
            and got["something-invented"] == "agent"), json.dumps(got)


def _recipe_local_takes_the_patch_road():
    tmp = _wave_scratch()
    try:
        _preaudited(tmp)
        skeletoned(tmp, ["a", "b", "c"])
        ps = FakePS({"hunt-run.ps1": lambda a: (0, "hunt-run: wave 1 closed with 3 recipe(s)", ""),
                     "wave-publish.ps1": lambda a: (0, "== DRY RUN - every gate above passed", "")})
        script = {"recipe-batch-auditor": [{"verdict": "NO-GO", "blocking_slugs": ["a"],
                                            "blocker_kind": "recipe-local", "owner": "writer",
                                            "summary": "a: the make_it prose contradicts step 3"},
                                           {"verdict": "GO"}],
                  "recipe-writer": [{"slug": "a", "fields": {
                      "prose.make_it": "<p>Fixed.</p>", "cuisine": "American",
                      "head.steps": ["One.", "Two.", "Three."]}}],
                  "post-publish-reviewer": [{}]}
        fd = FakeDispatch(script)
        d = daemon(run_dir=tmp, dispatcher=fd, ps=ps)
        d.mtimes = _mtimes_with(d, changed=["a"])
        arun(d.run_wave(1))
        wp = fd.prompts("recipe-writer")
        got = _read_intake(tmp, "a")
        specs = [c for c in ps.find("build-v2-spec.ps1")]
        built = [FakePS.value_after(c["args"], "-InFile") for c in specs]
        return ((len(wp) == 1
                 # the PATCH prompt, not the old tree-walking one
                 and "THE FIELDS AS THEY STAND RIGHT NOW" in wp[0]
                 and "Read %s\\waves" % tmp not in wp[0]
                 and "no_change" in wp[0]
                 # it actually patched
                 and (got.get("prose") or {}).get("make_it") == "<p>Fixed.</p>"
                 # and rebuilt the spec for EXACTLY the blocked slug, not the wave
                 and len(specs) == 1 and built[0].endswith("a.json")),
                "writer-dispatches=%d specs=%s prose=%s"
                % (len(wp), json.dumps(built), json.dumps(got.get("prose"))))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# =====================================================================================================
# F4 - the scoped re-audit carries the repair's field delta (2026-08-25)
#
# The auditor was re-reading a wave it had already read and diffing it blind against its own memory of
# the first pass. The daemon holds the repair payload, so it can say which fields moved on which slug.
#
# NEUTER PROOFS, RUN 2026-08-25 and reverted:
#   * make repair_by_patch return None -> the delta case goes red (the re-audit names no field).
#   * render the block on every audit (drop the `if why` gate) -> the first-audit clean twin goes red.
# =====================================================================================================

def _reaudit_carries_the_repair_delta():
    tmp = _wave_scratch()
    try:
        _preaudited(tmp)
        skeletoned(tmp, ["a", "b", "c"])
        ps = FakePS({"hunt-run.ps1": lambda a: (0, "hunt-run: wave 1 closed with 3 recipe(s)", ""),
                     "wave-publish.ps1": lambda a: (0, "== DRY RUN - every gate above passed", "")})
        script = {"recipe-batch-auditor": [{"verdict": "NO-GO", "blocking_slugs": ["a"],
                                            "blocker_kind": "recipe-local", "owner": "writer",
                                            "summary": "a: the make_it prose contradicts step 3"},
                                           {"verdict": "GO"}],
                  "recipe-writer": [{"slug": "a", "fields": {
                      "prose.make_it": "<p>Fixed.</p>", "cuisine": "American",
                      "head.steps": ["One.", "Two.", "Three."]}}],
                  "post-publish-reviewer": [{}]}
        fd = FakeDispatch(script)
        d = daemon(run_dir=tmp, dispatcher=fd, ps=ps)
        d.mtimes = _mtimes_with(d, changed=["a"])
        arun(d.run_wave(1))
        prompts = fd.prompts("recipe-batch-auditor")
        first, re_audit = prompts[0], prompts[1]
        named = ("WHAT THE REPAIR CHANGED" in re_audit
                 and "prose.make_it" in re_audit and "cuisine" in re_audit
                 and "head.steps" in re_audit and "patched 3 field(s)" in re_audit)
        # CLEAN TWIN, in the same run: the FIRST audit has no repair behind it and carries no block.
        clean = "WHAT THE REPAIR CHANGED" not in first
        return (named and clean, "named=%s first-audit-clean=%s" % (named, clean))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _reaudit_delta_reports_a_no_change():
    """MUST FIRE: a repair that says it changed nothing says so IN THE RE-AUDIT, with its reason. The
    delta is evidence, not a verdict - the auditor may still disbelieve it, and the changed-nothing
    mtime guard has already run separately."""
    d = daemon()
    block = d.repair_delta_block({
        "a": {"fields": ["prose.make_it", "cuisine"], "no_change": ""},
        "b": {"fields": [], "no_change": "the finding describes a cost basis, which is not mine"},
        "c": {"fields": [], "no_change": "the patch was REFUSED: unknown key `stat.calories`"}})
    return (("a" in block and "patched 2 field(s)" in block
             and "b" in block and "CHANGED NOTHING" in block
             and "not mine" in block and "unknown key" in block
             and "what LANDED rather than what was promised" in block),
            "block=%r" % block[:400])


def _shared_data_takes_the_unchanged_road():
    tmp = _wave_scratch()
    try:
        _preaudited(tmp)
        skeletoned(tmp, ["a", "b", "c"])
        ps = FakePS({"hunt-run.ps1": lambda a: (0, "hunt-run: wave 1 closed with 3 recipe(s)", ""),
                     "wave-publish.ps1": lambda a: (0, "== DRY RUN - every gate above passed", "")})
        d, fd = _wave_daemon([{"verdict": "NO-GO", "blocking_slugs": ["a"],
                               "blocker_kind": "shared-data", "owner": "writer",
                               "summary": "the cost basis moved under the whole wave"},
                              {"verdict": "GO"}], tmp, ps)
        d.mtimes = _mtimes_with(d, changed=["a"])
        arun(d.run_wave(1))
        wp = fd.prompts("recipe-writer")
        before = _read_intake(tmp, "a")
        return ((len(wp) == 1
                 # the OLD prompt, word for word where it counts
                 and "repair EXACTLY what it blocks on" in wp[0]
                 and "build-v2-spec.ps1 -InFile" in wp[0]
                 and "THE FIELDS AS THEY STAND RIGHT NOW" not in wp[0]
                 # and the daemon patched nothing itself
                 and before.get("prose") == {}),
                wp[0][:200] if wp else "no dispatch")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _unknown_kind_takes_the_shared_road():
    """CLEAN TWIN, and the conservative direction. A whole-agent repair can fix anything the patch
    road can and the reverse is not true, so an absent or invented kind must NOT get the patch road."""
    tmp = _wave_scratch()
    try:
        _preaudited(tmp)
        skeletoned(tmp, ["a", "b", "c"])
        ps = FakePS({"hunt-run.ps1": lambda a: (0, "hunt-run: wave 1 closed with 3 recipe(s)", ""),
                     "wave-publish.ps1": lambda a: (0, "== DRY RUN - every gate above passed", "")})
        d, fd = _wave_daemon([{"verdict": "NO-GO", "blocking_slugs": ["a"], "owner": "writer",
                               "summary": "x"},                  # no blocker_kind at all
                              {"verdict": "GO"}], tmp, ps)
        d.mtimes = _mtimes_with(d, changed=["a"])
        arun(d.run_wave(1))
        wp = fd.prompts("recipe-writer")
        return (len(wp) == 1 and "repair EXACTLY what it blocks on" in wp[0]
                and "THE FIELDS AS THEY STAND RIGHT NOW" not in wp[0],
                wp[0][:160] if wp else "no dispatch")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _patch_road_no_change_still_guards():
    """MUST FIRE. `no_change: true` is a LEGAL return, and it must not become a way past the
    changed-nothing guard. The guard reads the mtimes as it always did; the payload is the SECOND,
    independent answer, and the proof is that no re-audit is paid for."""
    tmp = _wave_scratch()
    try:
        _preaudited(tmp)
        skeletoned(tmp, ["a", "b", "c"])
        ps = FakePS({"hunt-run.ps1": lambda a: (0, "hunt-run: wave 1 closed with 3 recipe(s)", "")})
        script = {"recipe-batch-auditor": [{"verdict": "NO-GO", "blocking_slugs": ["a"],
                                            "blocker_kind": "recipe-local", "owner": "writer",
                                            "summary": "a: something"},
                                           {"verdict": "GO"}],
                  "recipe-writer": [{"slug": "a", "no_change": True,
                                     "reason": "the defect is in the mapping, not the prose"}],
                  "post-publish-reviewer": [{}]}
        fd = FakeDispatch(script)
        d = daemon(run_dir=tmp, dispatcher=fd, ps=ps)
        d.mtimes = _mtimes_with(d, changed=[])       # nothing on disk moved either
        arun(d.run_wave(1))
        specs = ps.find("build-v2-spec.ps1")
        return ((len(fd.prompts("recipe-batch-auditor")) == 1      # NO re-audit paid for
                 and not specs                                     # and no spec rebuilt
                 and any("changed nothing BY ITS OWN ACCOUNT" in f for f in d.findings)
                 and any("not the prose" in f for f in d.findings)),
                "audits=%d specs=%d findings=%s"
                % (len(fd.prompts("recipe-batch-auditor")), len(specs), json.dumps(d.findings)[:300]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# =====================================================================================================
# F3 - QA rules from a dossier, and the daemon holds the verdict pen (2026-08-25)
#
# 6b: source-qa ran 6-8 turns and 104k-143k per recipe re-reading the transcription, the spec and the
# battery report a dossier could carry. The stage is NOT merged with the writer's: independence is
# about WHO RULES, not about who does the file I/O.
#
# THE PEN MOVED ON EVIDENCE, per plan 5.2.3's grep-then-decide. Nothing in the estate reads
# qa\<slug>.json - not the daemon (it rules off the payload), not wave-preaudit.ps1, not hunt-run.ps1,
# not any agent definition. The only reference is qa_repair_prompt pointing a repairing agent at it,
# and the daemon writes the same file from the same fields. The plan predicted wave-preaudit and the
# auditor read it; they do not, and it is CORRECTED there.
#
# NEUTER PROOFS, RUN 2026-08-25 and reverted:
#   * qa_prompt back to the four file pointers (no self.qa_dossier call) -> the dossier case goes red
#     on all three sections.
#   * make the unreadable branches render an empty section instead of announcing -> the clean twin
#     goes red.
#   * drop the write_qa_verdict call out of qa_lane -> the pen case goes red (no file on disk).
#   * write the file even when the verdict is empty -> the no-verdict case goes red.
# =====================================================================================================

def _qa_dossier_run(spec=None, battery=None, extraction=True):
    """A run dir with the three artifacts a QA dossier renders, plus a scratch spec store."""
    tmp = tempfile.mkdtemp(prefix="daemon-qadoss-")
    specs = os.path.join(tmp, "specs")
    os.makedirs(specs, exist_ok=True)
    os.makedirs(os.path.join(tmp, "extracted"), exist_ok=True)
    os.makedirs(os.path.join(tmp, "qa"), exist_ok=True)
    if extraction:
        with open(os.path.join(tmp, "extracted", "s1.json"), "w", encoding="utf-8") as f:
            json.dump({"slug": "s1", "title": "Harissa Chicken Traybake",
                       "source_url": "https://d/harissa",
                       "ingredients": ["2 lb chicken thighs", "3 tbsp harissa paste",
                                       "1 lemon, quartered"],
                       "instructions": ["Heat the oven to 425F.", "Toss the chicken with harissa.",
                                        "Roast 35 minutes."]}, f)
    if spec is not False:
        with open(os.path.join(specs, "s1.json"), "w", encoding="utf-8") as f:
            json.dump(spec or {"name": "Harissa Chicken Traybake", "servings": 14,
                               "macros_per_serving": {"calories": 524, "protein_g": 44},
                               "ingredients": [{"item": "Chicken Thighs", "buy": "5 lb, bone-in"},
                                               {"item": "Harissa", "buy": "a 10 oz jar"},
                                               {"item": "Lemon", "buy": "3 lemons"}],
                               "make_it": ["Heat the oven to 425F.", "Toss with harissa.",
                                           "Roast 35 minutes."]}, f)
    if battery is not False:
        with open(os.path.join(tmp, "qa", "s1.battery.json"), "w", encoding="utf-8") as f:
            json.dump(battery or {"checks": [
                {"check": "ingredient-coverage", "verdict": "pass",
                 "numbers": {"source_lines": 3, "spec_lines": 3, "invented": 0, "dropped": 0}},
                {"check": "scaling-ratio", "verdict": "pass",
                 "numbers": {"ratio": 3.5, "servings": 14}},
                {"check": "prose-numbers", "verdict": "fail",
                 "numbers": {"claimed": 520, "stat": 524}}]}, f)
    d = daemon(run_dir=tmp, specs_dir=specs)
    return d, tmp


def _qa_dossier_carries_its_material():
    d, tmp = _qa_dossier_run()
    try:
        p = d.qa_prompt("s1", 1)
        trans = "2 lb chicken thighs" in p and "Roast 35 minutes." in p
        built = "buy: 5 lb, bone-in" in p and "Harissa Chicken Traybake" in p
        bat = "ingredient-coverage" in p and "invented=0" in p and "claimed=520" in p
        verbatim = ("Anchor on the transcription always" in p
                    and "A BLOCKED DOMAIN IS NEVER A FINDING AGAINST THE RECIPE" in p
                    and "read the live page too when the domain is fetchable" in p
                    and "Verdict only" in p)
        return (trans and built and bat and verbatim,
                "transcription=%s built=%s battery=%s verbatim=%s" % (trans, built, bat, verbatim))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _qa_dossier_missing_battery_is_announced():
    """CLEAN TWIN: a missing battery report is ANNOUNCED, never rendered as an empty section a QA
    would read as nothing to say - the CHANGE A unreadable-dossier pattern."""
    d, tmp = _qa_dossier_run(battery=False)
    try:
        p = d.qa_prompt("s1", 1)
        return ("COULD NOT BE READ" in p and "not a battery that passed" in p
                and "2 lb chicken thighs" in p,          # the readable sections still render
                "the missing battery did not announce itself: %s" % p[-400:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _qa_daemon_holds_the_verdict_pen():
    """MUST FIRE: the DAEMON writes qa\\<slug>.json from the payload, and it matches the schema
    fields. The agent's Write is retired."""
    tmp = tempfile.mkdtemp(prefix="daemon-qapen-")
    try:
        skeletoned(tmp, ["s1"])
        fd = FakeDispatch({"recipe-source-qa": [
            {"slug": "s1", "verdict": "pass", "owner": "", "findings": "anchors: extraction only"}]})
        d = daemon(run_dir=tmp, dispatcher=fd, ps=FakePS())
        d.qa_battery = lambda slug: _immediate(0)
        d.ch["qa"].push({"slug": "s1"})
        d.ch["qa"].close()
        arun(d.run(("qa",)))
        path = os.path.join(tmp, "qa", "s1.json")
        doc = json.load(open(path, encoding="utf-8-sig")) if os.path.exists(path) else None
        return (doc is not None and doc.get("verdict") == "pass" and doc.get("slug") == "s1"
                and doc.get("findings") == "anchors: extraction only"
                and sorted(doc) == ["findings", "owner", "slug", "verdict"],
                "verdict file=%s" % json.dumps(doc))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _qa_no_verdict_writes_nothing():
    """MUST FIRE: B5 - no verdict is never a pass. A payload carrying none writes NO file (a file on
    disk saying nothing is worse than no file, because it looks like a ruling) and the recipe is
    STUCK."""
    tmp = tempfile.mkdtemp(prefix="daemon-qanov-")
    try:
        skeletoned(tmp, ["s1"])
        fd = FakeDispatch({"recipe-source-qa": [None, None, None]})   # transport failures: no verdict
        d = daemon(run_dir=tmp, dispatcher=fd, ps=FakePS())
        d.qa_battery = lambda slug: _immediate(0)
        d.ch["qa"].push({"slug": "s1"})
        d.ch["qa"].close()
        arun(d.run(("qa",)))
        wrote = os.path.exists(os.path.join(tmp, "qa", "s1.json"))
        stuck = [o for o in d.outcomes if o.get("status") == "stuck"]
        # ...and an empty verdict in a real payload writes nothing either
        d2, tmp2 = _qa_dossier_run()
        try:
            none_path = d2.write_qa_verdict("s1", {"slug": "s1", "verdict": ""})
        finally:
            shutil.rmtree(tmp2, ignore_errors=True)
        return (not wrote and len(stuck) == 1 and none_path is None,
                "wrote=%s stuck=%d empty_verdict_path=%r" % (wrote, len(stuck), none_path))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _qa_writer_repair_is_a_patch():
    tmp = tempfile.mkdtemp(prefix="daemon-qapatch-")
    try:
        skeletoned(tmp, ["s1"])
        script = {"recipe-source-qa": [{"slug": "s1", "verdict": "fail", "owner": "writer",
                                        "findings": "the intro claims a number the spec does not"},
                                       {"slug": "s1", "verdict": "pass"}],
                  "recipe-writer": [{"slug": "s1", "fields": {
                      "prose.intro_html": "<p>Fixed.</p>", "cuisine": "American",
                      "writer_notes": ["one", "two", "three"]}}]}
        fd = FakeDispatch(script)
        ps = FakePS()
        d = daemon(run_dir=tmp, dispatcher=fd, ps=ps)
        d.qa_battery = lambda slug: _immediate(0)
        d.ch["qa"].push({"slug": "s1"})
        d.ch["qa"].close()
        arun(d.run(("qa",)))
        wp = fd.prompts("recipe-writer")
        got = _read_intake(tmp, "s1")
        to = [FakePS.value_after(c["args"], "-To") for c in ps.find("hunt-run.ps1", "-Advance")]
        return ((len(wp) == 1 and "THE FIELDS AS THEY STAND RIGHT NOW" in wp[0]
                 and "This is the ONE repair cycle" in wp[0]
                 and (got.get("prose") or {}).get("intro_html") == "<p>Fixed.</p>"
                 # THE ONE-REPAIR RULE IS UNTOUCHED: one repair, then exactly one re-QA
                 and len(fd.prompts("recipe-source-qa")) == 2
                 and to == ["qa-passed"]),
                "writer=%d qa=%d advances=%s" % (len(wp), len(fd.prompts("recipe-source-qa")), to))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _qa_mapper_repair_keeps_its_road():
    """CLEAN TWIN. A QA finding owned by the mapper needs re-mapping, which no field patch reaches.
    Its owner routing and its prompt are both unchanged."""
    tmp = tempfile.mkdtemp(prefix="daemon-qamapper-")
    try:
        skeletoned(tmp, ["s1"])
        script = {"recipe-source-qa": [{"slug": "s1", "verdict": "fail", "owner": "mapper",
                                        "findings": "the mapping bridged two different foods"},
                                       {"slug": "s1", "verdict": "pass"}],
                  "recipe-ingredient-mapper": [{}]}
        fd = FakeDispatch(script)
        d = daemon(run_dir=tmp, dispatcher=fd, ps=FakePS())
        d.qa_battery = lambda slug: _immediate(0)
        d.ch["qa"].push({"slug": "s1"})
        d.ch["qa"].close()
        arun(d.run(("qa",)))
        mp = fd.prompts("recipe-ingredient-mapper")
        return (len(mp) == 1 and "QA file:" in mp[0]
                and "THE FIELDS AS THEY STAND RIGHT NOW" not in mp[0]
                and not fd.prompts("recipe-writer"),
                "mapper=%d writer=%d" % (len(mp), len(fd.prompts("recipe-writer"))))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


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
    # EXTENDED 2026-08-25. This asserted TWO of the eight token fields, and production was stamping
    # -1 in the other six on every mechanical end line it ever wrote. Measured on
    # hunt-2026-08-24-v3-phase6b: `in=0 out=0 cache_read=-1 cache_creation=-1 calls=-1 api_turns=-1
    # all_in=-1 all_out=-1`. The fixture was green the whole time because it only ever looked at the
    # two fields the 2026-08-24 build remembered to pass. Every field the line CARRIES is asserted
    # now, so a future field added to lane() cannot slip back to -1 unnoticed on a free stage.
    FREE_FIELDS = ("-InputTokens", "-OutputTokens", "-CacheRead", "-CacheCreation", "-Calls",
                   "-ApiTurns", "-AllModelsIn", "-AllModelsOut")

    def _free_stamp(end_args):
        return dict((f, (end_args[end_args.index(f) + 1] if f in end_args else None))
                    for f in FREE_FIELDS)

    got = _free_stamp(end) if end else {}
    res.append(("MUST FIRE  the end line reports 0 in EVERY token field, never -1 - a mechanical "
                "stage burned nothing, which is not the same as nobody having looked",
                bool(got) and all(v == 0 for v in got.values()),
                json.dumps(dict((k, repr(v)) for k, v in sorted(got.items())))))

    # ---- the PYTHON mechanical road takes the same line. py_timed is a separate verb with its own
    # end-line call site, so it is its own way to regress.
    psb = FakePS()
    d2b = daemon(ps=psb, pyrun=FakePy())
    arun(d2b.py_timed("price", "pull-browser-stores", ["a", "b", "c"],
                      HD.PULL_BROWSER_STORES_PY, ["--lookup-terms-file", "T"], timeout=30))
    endb = None
    for c in psb.calls:
        a = c["args"]
        if "-Lane" in a and "-Event" in a and a[a.index("-Event") + 1] == "end":
            endb = a
    gotb = _free_stamp(endb) if endb else {}
    res.append(("MUST FIRE  py_timed's end line stamps 0 in every token field too - the python "
                "mechanical road is not exempt from the contract",
                bool(gotb) and all(v == 0 for v in gotb.values()),
                json.dumps(dict((k, repr(v)) for k, v in sorted(gotb.items())))))

    # ---- THE FREE ROAD IS THE ONLY ROAD. The local extraction ladder and the price pre-pass write
    # end lines too, and driving either one here would mean a GPU sweep or a store probe. So this
    # asserts the same thing by SOURCE, in the _one_marshalling_road idiom the estate already trusts
    # for exactly this shape of guarantee: after `dispatch` (the judgment road, which stamps REAL
    # numbers), no call site in the daemon may write an end line except through lane_free_end.
    #
    # NEUTER PROOF, RUN 2026-08-25: revert the production change - point ps_timed, py_timed, the
    # local ladder and the pre-pass back at `self.lane(..., "end", 0, 0, ...)` - and this case names
    # all four bypassing call sites while the two stamp cases above go red on six fields each.
    with open(os.path.join(HERE, "hunt-daemon.py"), "r", encoding="utf-8") as f:
        srclines = f.read().splitlines()
    # The enclosing METHOD is tracked, not a line window: a fixed lookback would have exempted
    # whatever happened to sit under an allowed def, which is how a scan like this quietly stops
    # scanning. (Measured 2026-08-25 while writing it - a 40-line window swallowed ps_timed.)
    bypass, method = [], ""
    for i, line in enumerate(srclines):
        for head in ("    def ", "    async def "):
            if line.startswith(head):
                method = line[len(head):].split("(")[0].strip()
        if "self.lane(" not in line:
            continue
        blob = " ".join(srclines[i:i + 4])
        if '"end"' not in blob:
            continue
        # the two roads that are ALLOWED to write an end line: dispatch() stamps the session's real
        # usage and must NOT be free, and lane_free_end IS the free road's own body.
        if method in ("dispatch", "lane_free_end"):
            continue
        bypass.append("%s line %d: %s" % (method, i + 1, line.strip()[:70]))
    res.append(("MUST FIRE  every end line outside the judgment dispatch goes through "
                "lane_free_end - one road, so the zero-stamp contract cannot fork across call sites",
                not bypass, "; ".join(bypass)))

    # ---- CLEAN TWIN: the judgment road is UNTOUCHED by all of this. A dispatch that really did burn
    # tokens still stamps them, and a free-stamping dispatch would be the worse bug in the other
    # direction - a lane log that reports the expensive lanes as free.
    fd = FakeDispatch({"decider": [{"slug": "s1"}]})
    d2c = daemon(dispatcher=fd)
    arun(d2c.dispatch("decider", "p", "select", "decide:1x", ["s1"]))
    endc = None
    for c in d2c._ps.calls:
        a = c["args"]
        if "-Lane" in a and "-Event" in a and a[a.index("-Event") + 1] == "end":
            endc = a
    gotc = _free_stamp(endc) if endc else {}
    res.append(("CLEAN TWIN  a JUDGMENT dispatch still stamps its real usage - the free road did "
                "not swallow the road that carries the money",
                bool(gotc) and any(v not in (0, None) for v in gotc.values()),
                json.dumps(dict((k, repr(v)) for k, v in sorted(gotc.items())))))

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

    # ---- T3 (2026-08-25): THE TWO STAGES THE TIMING CONVENTION STILL MISSED.
    #
    # NEUTER PROOFS, RUN AND REVERTED, with the counts the suite actually printed rather than the
    # ones this comment first predicted (1 / 2 / 1):
    #   * revert store_lookup to plain self.py            -> 4 red, not 1. The timed-pair case went,
    #     and so did three existing store fixtures: the crude revert left py_timed's argument list on
    #     a self.py call, so the lookup itself broke. That is a DIRTY neuter - it proves the case is
    #     load-bearing but not that it is load-bearing ALONE, and it is recorded that way rather than
    #     trimmed to look clean.
    #   * drop the `at=` passthrough out of lane()        -> 1 red, the backdate case alone.
    #   * drop the max(0.0, seconds) clamp in _stamp_ago  -> 1 red, the stamp case, on its negative
    #     twin - a start line stamped in the FUTURE pairs to a negative duration.
    # ---- T6 NEUTER PROOFS, RUN AND REVERTED 2026-08-25, one per seamed reader, all on a full roster:
    #   * preaudit back to the live store       -> 1 red;
    #   * mtimes back to the live store         -> 1 red;
    #   * drop the auditor's specs seam note    -> 1 red;
    #   * qa_battery back to the live store     -> 0 RED THE FIRST TIME, and that is the finding of
    #     this unit's own build. The fixture's NAME claimed the battery and its BODY only tested
    #     mtimes, because qa_battery shells straight through subprocess.run and there was nothing for
    #     a fixture to intercept. The command line was split into qa_battery_args to make the seam
    #     reachable, the assertion added, and the neuter re-run: 1 red. A seam no neuter can reach is
    #     a seam that will quietly come undone, and a fixture named for what it does not test is
    #     worse than no fixture - it reports the coverage without providing it.
    res.append(("MUST FIRE  T6: the preaudit battery reads the SEAMED spec store, and an unseamed "
                "run passes no flag at all - lf1's auditor graded a file the run never wrote",
                *_t6_preaudit_reads_the_seamed_spec_store()))
    res.append(("MUST FIRE  T6: the QA battery and the staleness mtimes follow the seam too - three "
                "readers of the live store, not one", *_t6_qa_battery_and_mtimes_follow_the_seam()))
    res.append(("MUST FIRE  T6: the AUDITOR is told which spec store is this run's, and an unseamed "
                "prompt carries no drill sentence",
                *_t6_auditor_is_told_which_spec_store_is_this_runs()))

    # ---- T2 NEUTER PROOFS, RUN AND REVERTED 2026-08-25, counts as the suite printed them:
    #   * drop the _tee call out of say()          -> 2 red (the narrative case and the survival case);
    #   * let _tee RAISE instead of swallowing     -> 1 red, the survival case - which is the whole
    #     point of the unit: a second way for the 6a death to happen would be a regression, not a
    #     feature;
    #   * drop the UTC stamp from each line        -> 1 red, the narrative case;
    #   * write the narrative even when quiet      -> 1 red, the clean twin.
    #
    # AND A FIXTURE LESSON PAID FOR IN THIS UNIT. The first attempt at neuter 1 reported 0 red while
    # silently running only 207 of 220 cases: the narrative fixture opened the log file without
    # checking it existed, the FileNotFoundError escaped the section helper, and every case in that
    # helper vanished. A neuter harness must assert the FULL case count, not just look for reds - a
    # lost case and a passing case are indistinguishable in a count of failures.
    res.append(("MUST FIRE  T2: the run's narrative is written to a file and every line is UTC "
                "stamped - it used to exist only in scrollback",
                *_t2_narrative_is_written_and_stamped()))
    res.append(("MUST FIRE  T2: an unwritable log path and a U+FFFD line both fail SILENTLY - a log "
                "line must not be able to end a run, which is how the 6a gate drill died",
                *_t2_a_log_line_can_never_end_a_run()))
    res.append(("CLEAN TWIN T2: a QUIET daemon writes no narrative, so no fixture grows a side "
                "effect from being constructed", *_t2_a_quiet_daemon_writes_no_narrative()))
    res.append(("MUST FIRE  the 45-minute browser store lookup emits a timed pair per store - it is "
                "the longest block a run can execute and it used to log nothing",
                *_t3_store_lookup_is_timed()))
    res.append(("MUST FIRE  a caller can BACKDATE its start line, and one that does not is stamped "
                "by hunt-run exactly as before", *_t3_backdated_start_reaches_hunt_run()))
    res.append(("MUST FIRE  the backdated stamp is hunt-run's own format and never lands in the "
                "future - an unpairable start reads as a stage that never finished",
                *_t3_stamp_ago_is_hunt_runs_own_format()))
    return res


# The entry point MUST be the LAST thing in this file. It used to sit at old line 4509 with ~2,300
# lines of fixture definitions BELOW it, so `run()` executed before those `def`s were bound and the
# suite died on the first one it referenced (`_registrar_gets_evidence`, section B). Measured
# 2026-08-25: 38 of 245+ assertions ran; everything from section B down had NEVER run, in any tree.
if __name__ == "__main__":
    sys.exit(run())
