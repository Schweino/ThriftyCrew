r"""app_selftest.py - the sidecar loads its models ONCE, however many first requests arrive together.

    python sidecar/app_selftest.py --selftest                (pinned interpreter; no torch, no fastapi)
    python sidecar/app_selftest.py --selftest --app <path>   (the same cases against another copy of app.py)

THE FOUNDING BUG. app.matcher() checked `_M is None` with no lock, and FastAPI runs sync endpoints on a
threadpool, so two first requests arriving together both saw None and both called Matcher.load. The recall
hook sends exactly that after every cold start: /recall-search, then /embed 1.5 s later, both inside a load
that takes about 10 s. Measured in design/MEASURE-sidecar-double-load-2026-09-11.md.

IT IMPORTS THE REAL app.py. fastapi, pydantic, torch and lib_match are replaced in sys.modules by stubs for
the length of the run, and Matcher.load by a stub that blocks. The real matcher() and the real health() run;
only what they call is fake. So an import app.py grows that the stubs do not provide fails this suite by
name, which is the intended price of testing the real file rather than a copy of its logic.

NO CLOCK DECIDES ANY CASE (.claude/rules/ops-and-gates.md: prove the OVERLAP, not the speed). The stub load
does not sleep and hope the other callers turn up in time: a sleep long enough on a quiet box is too short
under a loaded gate. It holds until every caller has ARRIVED - entered the load, or reached the load lock,
which the suite swaps for one that records arrivals. Under the fix only the first caller can enter and the
rest queue at the lock; under the founding bug nothing queues and every caller enters. Every wait carries a
hang guard, and a guard is never a bar.
"""
# The self-test loads sidecar\app.py with its model imports stubbed, and reads nothing else local.
# gate-inputs: sidecar\app_selftest.py, sidecar\app.py
from __future__ import annotations

import argparse
import importlib.util
import os
import sys
import threading
import types

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "app.py")
GUARD_S = 30        # the hang guard on every wait below; no case passes or fails on elapsed time
CALLERS = 8
LOCK_TYPES = (type(threading.Lock()), type(threading.RLock()))
STUBBED = ("fastapi", "pydantic", "torch", "lib_match")
EXPECTED_CASES = 9

# THE PRE-FIX matcher(), verbatim, so the first MUST FIRE can prove this driver produces real overlap. If the
# founding bug stopped loading more than once under it, the green on the fixed code would mean nothing.
FOUNDING_MATCHER = '''
def matcher():
    global _M, _loaded_at
    if _M is None:
        t0 = time.time()
        _M = Matcher.load(with_reranker=True)
        _loaded_at = time.time() - t0
    return _M
'''


def stub_modules():
    fastapi = types.ModuleType("fastapi")

    class FastAPI:
        def __init__(self, *a, **kw):
            pass

        def _route(self, *a, **kw):
            return lambda fn: fn

        get = post = put = delete = _route

    fastapi.FastAPI = FastAPI

    pydantic = types.ModuleType("pydantic")

    class BaseModel:
        pass

    pydantic.BaseModel = BaseModel
    pydantic.Field = lambda *a, **kw: (a[0] if a else None)

    torch = types.ModuleType("torch")
    torch.cuda = types.SimpleNamespace(is_available=lambda: False, get_device_name=lambda i: None)

    lib_match = types.ModuleType("lib_match")

    class Matcher:
        @staticmethod
        def load(**kw):
            raise AssertionError("no case installed a load stub")

    lib_match.Matcher = Matcher
    lib_match.clean_product = lambda s: s
    lib_match.commodity_text = lambda c: ""
    lib_match.DEVICE = "cpu"
    lib_match.EMBED_MODEL = "stub-embed"
    lib_match.RERANK_MODEL = "stub-rerank"
    return {"fastapi": fastapi, "pydantic": pydantic, "torch": torch, "lib_match": lib_match}


_loads = [0]


def load_app(path):
    """A fresh module built from app.py, importing fresh stubs."""
    sys.modules.update(stub_modules())
    _loads[0] += 1
    spec = importlib.util.spec_from_file_location("sidecar_app_under_test_%d" % _loads[0], path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Arrivals:
    """Which caller threads have reached the load or the load lock."""

    def __init__(self, n):
        self.n = n
        self.cv = threading.Condition()
        self.threads = set()
        self.entries = 0
        self.lock_attempts = 0

    def arrive(self, at):
        with self.cv:
            self.threads.add(threading.get_ident())
            if at == "load":
                self.entries += 1
            else:
                self.lock_attempts += 1
            self.cv.notify_all()

    def all_here(self):
        with self.cv:
            return self.cv.wait_for(lambda: len(self.threads) >= self.n, GUARD_S)


class ArrivalLock:
    """A drop-in for the module's load lock that records each caller reaching it."""

    def __init__(self, arrivals):
        self._lock = threading.Lock()
        self._arrivals = arrivals

    def acquire(self, blocking=True, timeout=-1):
        self._arrivals.arrive("lock")
        return self._lock.acquire(blocking, timeout)

    def release(self):
        self._lock.release()

    def locked(self):
        return self._lock.locked()

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, *exc):
        self.release()
        return False


def install(mod, arrivals, release):
    """Swap Matcher.load for a stub that holds until every caller has arrived and `release` is set, and
    every module-level lock for an ArrivalLock. Returns (lock names found, matchers the stub made)."""
    made = []

    def load(*a, **kw):
        arrivals.arrive("load")
        everyone = arrivals.all_here()
        release.wait(GUARD_S)
        if not everyone:
            raise TimeoutError("hang guard: %d of %d callers arrived" % (len(arrivals.threads), arrivals.n))
        m = object()
        made.append(m)
        return m

    mod.Matcher.load = load
    names = sorted(k for k, v in vars(mod).items() if isinstance(v, LOCK_TYPES))
    for k in names:
        setattr(mod, k, ArrivalLock(arrivals))
    return names, made


def drive(mod, n):
    """n callers into mod.matcher() at once, with /health probed while the load is still held open."""
    arrivals = Arrivals(n)
    release = threading.Event()
    names, made = install(mod, arrivals, release)
    got = [None] * n
    errors = []

    def caller(i):
        try:
            got[i] = mod.matcher()
        except BaseException as e:   # noqa: B902 - a caller's failure is a finding, never a crash of the suite
            errors.append(repr(e))

    threads = [threading.Thread(target=caller, args=(i,), daemon=True) for i in range(n)]
    for t in threads:
        t.start()
    everyone = arrivals.all_here()
    # /health WHILE THE LOAD IS HELD OPEN. The stub cannot return until `release` is set below, so a health()
    # that has returned by then answered DURING the load, and one that waits on the load lock cannot have.
    mid = {}
    h = threading.Thread(target=lambda: mid.update(mod.health()), daemon=True)
    h.start()
    h.join(GUARD_S)
    mid_answered = not h.is_alive()
    mid_seen = dict(mid)
    release.set()
    for t in threads:
        t.join(GUARD_S)
    h.join(GUARD_S)
    return {"locks": names, "everyone": everyone, "entries": arrivals.entries,
            "lock_attempts": arrivals.lock_attempts, "made": made, "got": got, "errors": errors,
            "hung": sum(1 for t in threads if t.is_alive()), "mid": mid_seen if mid_answered else None,
            "after": mod.health()}


def cases(T, app_path):
    # MUST FIRE, THE FOUNDING BUG: the pre-fix matcher() under this same driver. Every caller enters the load.
    try:
        mod = load_app(app_path)
        exec(FOUNDING_MATCHER, vars(mod))
        r = drive(mod, CALLERS)
        T("MUST FIRE  the pre-fix matcher() loads once PER CALLER under this driver (%d callers)" % CALLERS,
          r["entries"] == CALLERS and r["everyone"], "entries=%d everyone=%s" % (r["entries"], r["everyone"]))
    except Exception as e:
        T("MUST FIRE  the pre-fix matcher() loads once PER CALLER under this driver", False, "raised %r" % e)

    # THE FIX: the real matcher() under the same driver.
    try:
        mod = load_app(app_path)
        r = drive(mod, CALLERS)
        T("MUST FIRE  the load is guarded by exactly one module-level lock", len(r["locks"]) == 1, r["locks"])
        T("MUST FIRE  %d concurrent first callers enter Matcher.load ONCE" % CALLERS,
          r["entries"] == 1 and r["everyone"],
          "entries=%d everyone=%s lock_attempts=%d" % (r["entries"], r["everyone"], r["lock_attempts"]))
        T("every caller gets the one loaded matcher, and none fails or hangs",
          len(r["made"]) == 1 and all(g is r["made"][0] for g in r["got"]) and not r["errors"] and r["hung"] == 0,
          "made=%d errors=%s hung=%d" % (len(r["made"]), r["errors"][:2], r["hung"]))
        T("MUST FIRE  /health's load_count is the number of loads that actually started",
          r["after"].get("load_count") == r["entries"] == 1 and r["after"].get("models_loaded") is True,
          "health=%s entries=%d" % (r["after"], r["entries"]))
        # CLEAN TWIN: start-sidecar.ps1 polls /health with a 3 s timeout WHILE the ~10 s load runs. A /health
        # that waited on the load lock would read as a dead service for the whole load.
        T("CLEAN TWIN /health answers WHILE the load holds the lock, reporting it unloaded and started",
          r["mid"] is not None and r["mid"].get("models_loaded") is False and r["mid"].get("load_count") == 1,
          r["mid"])
    except Exception as e:
        T("MUST FIRE  concurrent first callers enter Matcher.load ONCE", False, "raised %r" % e)

    # MUST NOT FIRE: /health is the cheap probe callers use to tell clean from BLIND. It never loads.
    try:
        mod = load_app(app_path)
        arrivals = Arrivals(1)
        release = threading.Event()
        release.set()
        install(mod, arrivals, release)
        h = mod.health()
        T("MUST NOT FIRE  /health on a cold service starts no load and takes no lock",
          arrivals.entries == 0 and arrivals.lock_attempts == 0 and h.get("models_loaded") is False
          and h.get("load_count") == 0, "entries=%d lock_attempts=%d health=%s" % (arrivals.entries, arrivals.lock_attempts, h))
    except Exception as e:
        T("MUST NOT FIRE  /health on a cold service starts no load", False, "raised %r" % e)

    # CLEAN TWIN: the double check. Every request after the first goes straight to the loaded matcher.
    try:
        mod = load_app(app_path)
        arrivals = Arrivals(1)
        release = threading.Event()
        release.set()
        install(mod, arrivals, release)
        first = mod.matcher()
        attempts = arrivals.lock_attempts
        again = [mod.matcher() for _ in range(3)]
        T("CLEAN TWIN a loaded matcher is handed to later callers without taking the load lock",
          first is not None and all(x is first for x in again) and arrivals.entries == 1
          and arrivals.lock_attempts == attempts,
          "entries=%d lock_attempts %d -> %d" % (arrivals.entries, attempts, arrivals.lock_attempts))
    except Exception as e:
        T("CLEAN TWIN a loaded matcher is handed to later callers", False, "raised %r" % e)

    # CLEAN TWIN: a load that raises (CUDA out of memory, a missing weight file) must release the lock and
    # leave the service unloaded, so the NEXT request tries again rather than hanging or reading a half-state.
    try:
        mod = load_app(app_path)
        arrivals = Arrivals(1)
        release = threading.Event()
        release.set()
        install(mod, arrivals, release)
        good = mod.Matcher.load
        calls = [0]

        def flaky(*a, **kw):
            calls[0] += 1
            if calls[0] == 1:
                raise RuntimeError("CUDA out of memory (stub)")
            return good(*a, **kw)

        mod.Matcher.load = flaky
        try:
            mod.matcher()
            raised = False
        except RuntimeError:
            raised = True
        h1 = mod.health()
        second = {}
        # From ANOTHER thread, so a lock left held hangs the caller into the guard instead of re-entering it.
        t = threading.Thread(target=lambda: second.update(m=mod.matcher()), daemon=True)
        t.start()
        t.join(GUARD_S)
        h2 = mod.health()
        T("CLEAN TWIN a load that raises releases the lock, and the next caller loads",
          raised and h1.get("models_loaded") is False and not t.is_alive() and second.get("m") is not None
          and h2.get("models_loaded") is True and h2.get("load_count") == 2,
          "raised=%s first=%s hung=%s second=%s" % (raised, h1, t.is_alive(), h2))
    except Exception as e:
        T("CLEAN TWIN a load that raises releases the lock", False, "raised %r" % e)


def selftest(app_path=APP):
    fails, ran = [], []

    def T(name, cond, got=""):
        ran.append(name)
        if cond:
            print("  ok    %s" % name)
        else:
            print("  X     %s   got: %s" % (name, got))
            fails.append(name)

    saved = {k: sys.modules.get(k) for k in STUBBED}
    saved_path = list(sys.path)
    try:
        cases(T, app_path)
    finally:
        for k, v in saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v
        sys.path[:] = saved_path

    # A SUITE THAT RAN FEWER CASES THAN IT HOLDS IS NOT A PASS (ops-and-gates.md, 2026-09-11).
    if len(ran) != EXPECTED_CASES:
        print("SELF-TEST FAIL: ran %d case(s), expected %d - a case group died before it could assert"
              % (len(ran), EXPECTED_CASES))
        return 1
    if fails:
        print("SELF-TEST FAIL: %d of %d case(s) against %s" % (len(fails), len(ran), app_path))
        return 1
    print("SELF-TEST PASS: %d of %d cases - %d concurrent first callers load the sidecar's models once, "
          "and /health answers during the load" % (len(ran), EXPECTED_CASES, CALLERS))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--app", default=APP, help="the app.py to test (default: the one beside this file)")
    a = ap.parse_args()
    if a.selftest:
        return selftest(a.app)
    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
