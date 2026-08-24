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
        self.calls.append({"agent": agent, "prompt": prompt})
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
    for lane_name, agent, seed_ch, schema in (
            ("write", "recipe-writer", "write", hunt_lib.WRITE),
            ("qa", "recipe-source-qa", "qa", hunt_lib.QA)):
        d = daemon(dispatcher=FakeDispatch({agent: [None, None, None, None]}))
        d.ch[seed_ch].push({"slug": "s1"})
        d.ch[seed_ch].close()
        arun(d.run((lane_name,)))
        o = d.outcomes[0] if d.outcomes else {}
        T("MUST FIRE  a %s dispatch that never answered marks the recipe STUCK, not rejected"
          % lane_name,
          o.get("status") == "stuck" and o.get("state") is None, json.dumps(o))
    d = daemon(dispatcher=FakeDispatch({"recipe-writer": [None, None, None, None]}))
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
    d = daemon(dispatcher=FakeDispatch({"recipe-writer": [None, None, None, {"slug": "s1",
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
    d = daemon(dispatcher=FakeDispatch({"recipe-writer": [None] * 30}))
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
    d = daemon(dispatcher=fd, ps=ps)
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

    # =================================================================================================
    H("The band gate, read off the built spec")
    # =================================================================================================
    T("MUST FIRE  a spec outside the band is retired and never reaches QA, down v2's exact route "
      "(spec-built -> written -> rejected-qa; priced has no other legal exit)",
      *_band_gate_fires())
    T("MUST FIRE  and against the REAL state machine the rejection LANDS on disk - the first build's "
      "direct priced->rejected-qa advance would have been refused and nobody would have seen it",
      *_band_gate_real_machine())
    T("CLEAN TWIN a spec inside the band advances to written and reaches QA",
      *_band_gate_clean())
    T("MUST FIRE  the WIP limit gates pool pops",
      *_wip_gates_pops())

    # =================================================================================================
    H("Resume, against a real scratch run dir")
    # =================================================================================================
    for name, ok, got in _resume_seed_table():
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

def _rejects_explicitly():
    fd = FakeDispatch({"recipe-ingredient-mapper": [
        {"results": [{"slug": "s1", "status": "rejected", "state": "rejected-not-carried",
                      "detail": "nobody carries it"}]}]})
    d = daemon(dispatcher=fd)
    d.ch["map"].push({"slug": "s1"})
    d.ch["map"].close()
    arun(d.run(("map",)))
    return bool(d.outcomes) and d.outcomes[0]["status"] == "rejected"


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
        d = daemon(dispatcher=fd, ps=slow_cost)
        d.spec_band = lambda slug, specs_dir=None: (500, 20)      # in band, so the lane completes
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


def _decide_pool(tmp, slugs):
    import harvest                                               # noqa: PLC0415
    pool = {"candidates": [harvest.new_entry(s, s.replace("-", " ").title(),
                                             "https://d/%s" % s, "d", "drill") for s in slugs]}
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


def _lane_daemon():
    fd = FakeDispatch({"recipe-writer": [{"slug": "s1", "status": "ok", "state": "written"}]})
    ps = FakePS()
    d = daemon(dispatcher=fd, ps=ps)
    d.spec_band = lambda slug, specs_dir=None: (500, 20)
    d.ch["write"].push({"slug": "s1"})
    d.ch["write"].close()
    arun(d.run(("write",)))
    return d, ps


def _lane_pairs():
    d, ps = _lane_daemon()
    lanes = ps.find("hunt-run.ps1", "-Lane")
    events = [FakePS.value_after(c["args"], "-Event") for c in lanes]
    return (events == ["start", "end"], json.dumps(events))


def _lane_tokens():
    d, ps = _lane_daemon()
    end = [c for c in ps.find("hunt-run.ps1", "-Lane")
           if FakePS.value_after(c["args"], "-Event") == "end"]
    if not end:
        return False, "no end line"
    tin = FakePS.value_after(end[0]["args"], "-InputTokens")
    tout = FakePS.value_after(end[0]["args"], "-OutputTokens")
    start = [c for c in ps.find("hunt-run.ps1", "-Lane")
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


def _band(cal, carbs):
    fd = FakeDispatch({"recipe-writer": [{"slug": "s1", "status": "ok", "state": "written"}]})
    ps = FakePS()
    d = daemon(dispatcher=fd, ps=ps)
    d.spec_band = lambda slug, specs_dir=None: (cal, carbs)
    d.ch["write"].push({"slug": "s1"})
    d.ch["write"].close()
    arun(d.run(("write",)))
    to = [FakePS.value_after(c["args"], "-To") for c in ps.find("hunt-run.ps1", "-Advance")]
    return d, to


def _band_gate_fires():
    """The route is load-bearing: the recipe sits at `priced`, whose ONLY legal exit is spec-built,
    so the rejection must travel spec-built -> written -> rejected-qa (v2's measured on-disk trace).
    The first build advanced priced -> rejected-qa directly; FakePS accepted it and the real state
    machine would have refused it, leaving the recipe at `priced` on disk while the daemon counted
    it rejected. The real-machine twin below is what actually pins that."""
    d, to = _band(700, 20)
    return (to == ["spec-built", "written", "rejected-qa"]
            and d.outcomes and d.outcomes[0]["status"] == "rejected"
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
                                                     "drill", "-Stop", "1", "-WaveSize", "2"])
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
        fd = FakeDispatch({"recipe-writer": [{"slug": "band-drill", "status": "ok",
                                              "state": "written"}]})
        d = HD.Daemon(run_dir, "band-drill-run", dispatcher=fd, quiet=True)   # REAL ps_invoke
        d.spec_band = lambda slug, specs_dir=None: (700, 20)
        d.ch["write"].push({"slug": "band-drill"})
        d.ch["write"].close()
        arun(d.run(("write",)))
        final = d.state_of("band-drill")
        return (final == "rejected-qa" and not d.findings,
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


def _resume_seed_table():
    """The section 4.5 seed table, against a REAL scratch run dir driven by hunt-run.ps1 itself."""
    out = []
    tmp = tempfile.mkdtemp(prefix="daemon-resume-")
    try:
        run_dir = os.path.join(tmp, "run")
        os.makedirs(run_dir, exist_ok=True)
        rc, o, _e = hunt_lib.ps_invoke(HUNT_RUN_PS, ["-Init", "-RunDir", run_dir, "-Conditions",
                                                     "drill", "-Stop", "2 accepted", "-WaveSize", "2"])
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
