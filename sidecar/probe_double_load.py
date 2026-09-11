r"""probe_double_load.py - does the sidecar load its models once per concurrent first request?

    <sidecar venv>\python.exe sidecar\probe_double_load.py --service-dir <checkout>\sidecar
        --arm unlocked <dir> <commit> --arm locked <dir> <commit> --rounds 3
        --out design\MEASURE-sidecar-double-load-2026-09-11.jsonl --log-dir <scratch>
    <any python>\python.exe sidecar\probe_double_load.py --summarise <rows.jsonl>

The design, the acceptance bar and the verdict are in design\MEASURE-sidecar-double-load-2026-09-11.md,
written before the first trial ran. This file is the harness that document names.

WHAT ONE TRIAL IS. A fresh server process on a probe port serving ONE arm's app.py, with the live service on
8077 stopped through sidecar\stop-sidecar.ps1 so the card holds nothing else of ours. Once /health answers
with the models NOT loaded, one request shape is fired; after every request has returned, the harness reads
/health's load_count and the card's memory.used. Then the process tree is killed and the card is waited back
down to idle before the next trial.

    single  one /embed. The control: what one load holds.
    pair0   two /embed released together by a barrier.
    hook    /recall-search at 0 s and /embed at 1.5 s - the recall hook's shape on 2026-09-10 06:30.

IT LAUNCHES THE ARM DIRECTLY, NOT THROUGH start-sidecar.ps1, and that is the point: the front door warms
the service with ONE request before it returns, which is exactly what prevents the race under test. The
probe server runs as `python -c`, so its command line does not carry the uvicorn-app shape stop-sidecar.ps1
matches: a nightly handoff can never mistake it for the service. The live service itself is only ever
stopped through that front door.

THE WATCHDOG. ops\sidecar-watchdog.ps1 fires every 15 minutes and restarts a service it finds down. A trial
never straddles a quarter-hour mark: one that would is postponed until the watchdog run has finished, and
the service it restarted is stopped again through the front door. A listener on 8077 at either end of a
trial marks the row invalid, and the row is kept.

ONE ROW PER TRIAL PER ARM (.claude\rules\measurement.md), carrying the harness commit, the commit and sha256
of the arm's app.py, and the idle reading the trial ran against. The verdicts are derived from the rows
file by --summarise, never from this process's memory.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import socket
import statistics
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

LIVE_PORT = 8077
GPU_WINDOW = ("21:30", "06:30")   # ruling R1: the nightly owns the card. No trial may run into it.
WATCHDOG_EVERY_MIN = 15           # TC Sidecar Watchdog repeats PT15M on the quarter hour
TRIAL_BUDGET_S = 180              # no trial starts closer than this to a watchdog mark or to the window
HOOK_OFFSET_S = 1.5               # the recall hook's client timeout between its two requests
IDLE_SLACK_MIB = 300              # a baseline further than this above the idle reference is not idle
STABLE_MIB = 20                   # two consecutive card readings this close count as settled
# HANG GUARDS, NEVER BARS. Each exists only to end a wait that would otherwise never end; no verdict
# depends on how long anything took.
HEALTH_GUARD_S = 180
REQUEST_GUARD_S = 300
SETTLE_GUARD_S = 90
WATCHDOG_GUARD_S = 300

# THE ACCEPTANCE BAR, copied from the MEASURE document where it was written before the first trial ran.
B2_MIN_RATIO = 1.6
B3_MAX_DRIFT = 0.15

INVALIDATING = ("no-health", "loaded-before-requests", "baseline-unsettled", "live-8077-at-start",
                "live-8077-at-end", "request-thread-hung", "server-exited")

EMBED = {"texts": ["double load probe"], "clean": False}
RECALL = {"query": "double load probe", "k": 8}
SHAPES = {
    "single": [("/embed", EMBED, 0.0)],
    "pair0": [("/embed", EMBED, 0.0), ("/embed", EMBED, 0.0)],
    "hook": [("/recall-search", RECALL, 0.0), ("/embed", EMBED, HOOK_OFFSET_S)],
}
CONCURRENT = ("pair0", "hook")

# The probe server. No double quotes, no uvicorn-app token: see the header.
SERVE = ("import sys; arm, lib, port = sys.argv[1], sys.argv[2], int(sys.argv[3]); "
         "sys.path[:0] = [arm]; sys.path.append(lib); "
         "import uvicorn; uvicorn.run('app:app', host='127.0.0.1', port=port, log_level='warning')")

_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def now_iso():
    return dt.datetime.now().isoformat(timespec="seconds")


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def card():
    """(memory.used, memory.total) in MiB for GPU 0."""
    r = subprocess.run(["nvidia-smi", "--query-gpu=memory.used,memory.total", "--format=csv,noheader,nounits"],
                       capture_output=True, text=True, timeout=30)
    used, total = (int(x.strip()) for x in r.stdout.strip().splitlines()[0].split(","))
    return used, total


def wait_card(pred, guard_s):
    """Poll the card until pred(used, previous_used) holds. Returns (used, held_before_guard)."""
    end = time.monotonic() + guard_s
    prev = None
    while True:
        used, _ = card()
        if pred(used, prev):
            return used, True
        if time.monotonic() >= end:
            return used, False
        prev = used
        time.sleep(0.5)


def port_open(port):
    s = socket.socket()
    s.settimeout(0.5)
    try:
        s.connect(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def call(method, url, body=None, timeout=REQUEST_GUARD_S):
    """(status or None, parsed body or {error}, ms). Never raises."""
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    try:
        with _OPENER.open(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode("utf-8")), round((time.monotonic() - t0) * 1000)
    except urllib.error.HTTPError as e:
        return e.code, None, round((time.monotonic() - t0) * 1000)
    except Exception as e:
        return None, {"error": repr(e)[:300]}, round((time.monotonic() - t0) * 1000)


def powershell(args, timeout):
    r = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass"] + args,
                       capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout


def watchdog_running():
    # THE NEEDLE IS SPLIT, because this query's own command line would otherwise match itself and the
    # count could never reach zero.
    rc, out = powershell(["-Command",
                          "@(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and "
                          "$_.Name -eq 'powershell.exe' -and $_.CommandLine -like ('*sidecar-watch' + 'dog.ps1*') }).Count"],
                         60)
    if rc != 0:
        raise SystemExit("COULD NOT EVALUATE: the process table could not be read to find the watchdog")
    return int(out.strip() or "0")


def in_gpu_window(t):
    start = dt.datetime.strptime(GPU_WINDOW[0], "%H:%M").time()
    end = dt.datetime.strptime(GPU_WINDOW[1], "%H:%M").time()
    return t.time() >= start or t.time() < end   # the window wraps midnight


def next_watchdog_mark(t):
    base = t.replace(second=0, microsecond=0)
    return base + dt.timedelta(minutes=WATCHDOG_EVERY_MIN - (t.minute % WATCHDOG_EVERY_MIN))


def clear_the_schedule(log):
    """Refuse inside the GPU window; wait out a watchdog mark a trial would otherwise straddle."""
    now = dt.datetime.now()
    if in_gpu_window(now) or in_gpu_window(now + dt.timedelta(seconds=TRIAL_BUDGET_S)):
        raise SystemExit("REFUSED: a trial starting now could run into the %s-%s GPU window (ruling R1)" % GPU_WINDOW)
    mark = next_watchdog_mark(now)
    if (mark - now).total_seconds() >= TRIAL_BUDGET_S:
        return False
    log("  waiting out the %s watchdog run before the next trial" % mark.strftime("%H:%M"))
    time.sleep(max(0.0, (mark + dt.timedelta(seconds=20) - dt.datetime.now()).total_seconds()))
    end = time.monotonic() + WATCHDOG_GUARD_S
    quiet = 0
    while quiet < 2:
        if time.monotonic() >= end:
            raise SystemExit("REFUSED: the watchdog was still running after %d s" % WATCHDOG_GUARD_S)
        quiet = quiet + 1 if watchdog_running() == 0 else 0
        time.sleep(3)
    return True


def ensure_live_stopped(service_dir, log):
    """Stop the live service through its front door. Returns the stop exit code, or None if nothing ran."""
    if not port_open(LIVE_PORT):
        return None
    rc, out = powershell(["-File", os.path.join(HERE, "stop-sidecar.ps1"), "-ServiceDir", service_dir], 180)
    log("  stop-sidecar.ps1 exit %s" % rc)
    if rc != 0 or port_open(LIVE_PORT):
        raise SystemExit("REFUSED: stop-sidecar.ps1 exit %s and port %d open=%s\n%s"
                         % (rc, LIVE_PORT, port_open(LIVE_PORT), out))
    return rc


class PeakSampler(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.done = threading.Event()
        self.peak = 0
        self.samples = 0

    def run(self):
        while not self.done.is_set():
            try:
                used, _ = card()
                self.peak = max(self.peak, used)
                self.samples += 1
            except Exception:
                pass
            self.done.wait(0.5)


def fire(base, plan):
    """Run one shape. Returns (request records, hung thread count)."""
    go = threading.Barrier(len(plan))
    out = [None] * len(plan)

    def one(i, path, body, offset):
        go.wait()
        if offset:
            time.sleep(offset)   # the shape under test, not a wait for a condition
        st, payload, ms = call("POST", base + path, body)
        rec = {"endpoint": path, "offset_s": offset, "status": st, "ms": ms}
        if isinstance(payload, dict):
            if path == "/recall-search":
                rec["recall_ok"] = payload.get("ok")
            if "error" in payload:
                rec["error"] = payload["error"]
        out[i] = rec

    threads = [threading.Thread(target=one, args=(i,) + tuple(x), daemon=True) for i, x in enumerate(plan)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(REQUEST_GUARD_S + 30)
    return out, sum(1 for t in threads if t.is_alive())


def kill_tree(p, port):
    # /T: the venv interpreter is a redirector whose CHILD owns the socket and the CUDA memory.
    subprocess.run(["taskkill", "/PID", str(p.pid), "/T", "/F"], capture_output=True, text=True, timeout=60)
    try:
        p.wait(timeout=30)
    except subprocess.TimeoutExpired:
        pass
    end = time.monotonic() + 60
    while port_open(port) and time.monotonic() < end:
        time.sleep(0.25)
    return not port_open(port)


def trial(ctx, arm, shape, rnd, n):
    name, arm_dir, arm_commit = arm
    flags = []
    waited = clear_the_schedule(ctx["log"])
    stopped = ensure_live_stopped(ctx["service_dir"], ctx["log"])
    if port_open(LIVE_PORT):
        flags.append("live-8077-at-start")
    if port_open(ctx["port"]):
        raise SystemExit("REFUSED: probe port %d is already held by something else" % ctx["port"])
    idle = ctx["idle_ref"]
    baseline, ok = wait_card(lambda u, prev: prev is not None and u <= idle + IDLE_SLACK_MIB
                             and abs(u - prev) <= STABLE_MIB, SETTLE_GUARD_S)
    if not ok:
        flags.append("baseline-unsettled")

    row = {"trial": n, "round": rnd, "arm": name, "shape": shape, "started": now_iso(),
           "harness": "sidecar/probe_double_load.py", "harness_commit": ctx["harness_commit"],
           "harness_dirty": ctx["harness_dirty"], "arm_commit": arm_commit,
           "arm_app_sha256": sha256(os.path.join(arm_dir, "app.py")),
           "lib_match_sha256": ctx["lib_match_sha256"], "port": ctx["port"],
           "card_total_mib": ctx["total"], "idle_ref_mib": idle, "baseline_mib": baseline,
           "waited_for_watchdog": waited, "stopped_live_first": stopped is not None}

    log_path = os.path.join(ctx["log_dir"], "trial-%02d-%s-%s.log" % (n, name, shape))
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    base = "http://127.0.0.1:%d" % ctx["port"]
    with open(log_path, "w", encoding="utf-8") as logf:
        p = subprocess.Popen([ctx["python"], "-c", SERVE, arm_dir, HERE, str(ctx["port"])], cwd=arm_dir,
                             stdout=logf, stderr=subprocess.STDOUT, env=env,
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        sampler = PeakSampler()
        sampler.start()
        try:
            health_pre = None
            end = time.monotonic() + HEALTH_GUARD_S
            while time.monotonic() < end:
                if p.poll() is not None:
                    flags.append("server-exited")
                    break
                st, payload, _ = call("GET", base + "/health", timeout=3)
                if st == 200:
                    health_pre = payload
                    break
                time.sleep(0.25)
            if health_pre is None:
                flags.append("no-health")
            else:
                row["health_pre"] = {k: health_pre.get(k) for k in ("models_loaded", "load_count", "device", "gpu")}
                if health_pre.get("models_loaded"):
                    flags.append("loaded-before-requests")
                reqs, hung = fire(base, SHAPES[shape])
                row["requests"] = reqs
                if hung:
                    flags.append("request-thread-hung")
                st, post, _ = call("GET", base + "/health", timeout=10)
                row["health_status"] = st
                post = post if isinstance(post, dict) else {}
                row["load_count"] = post.get("load_count")
                row["models_loaded"] = post.get("models_loaded")
                row["load_seconds"] = post.get("load_seconds")
                after, stable = wait_card(lambda u, prev: prev is not None and abs(u - prev) <= STABLE_MIB,
                                          SETTLE_GUARD_S)
                if not stable:
                    flags.append("after-unstable")
                row["after_mib"] = after
                row["held_mib"] = after - baseline
        finally:
            sampler.done.set()
            sampler.join(10)
            row["peak_mib"] = sampler.peak or None
            row["peak_held_mib"] = (sampler.peak - baseline) if sampler.peak else None
            row["port_released"] = kill_tree(p, ctx["port"])
    if port_open(LIVE_PORT):
        flags.append("live-8077-at-end")
    released, ok = wait_card(lambda u, prev: u <= idle + IDLE_SLACK_MIB, SETTLE_GUARD_S)
    row["released_mib"] = released
    if not ok:
        flags.append("release-unsettled")
    row["flags"] = flags
    row["valid"] = not any(f in INVALIDATING for f in flags)
    return row


def git(*args):
    r = subprocess.run(["git", "-C", REPO] + list(args), capture_output=True, text=True, timeout=60)
    return r.stdout.strip()


def run(a):
    if os.path.exists(a.out):
        raise SystemExit("REFUSED: %s exists - one run per rows file, so a verdict never mixes two runs" % a.out)
    arms = [tuple(x) for x in a.arm]
    for name, d, _ in arms:
        if not os.path.isfile(os.path.join(d, "app.py")):
            raise SystemExit("REFUSED: arm %s has no app.py in %s" % (name, d))
    python = a.python or os.path.join(a.service_dir, ".venv", "Scripts", "python.exe")
    os.makedirs(a.log_dir, exist_ok=True)
    shapes = [s for s in a.shapes.split(",") if s]

    def log(msg):
        print(msg, flush=True)

    ensure_live_stopped(a.service_dir, log)
    idle, ok = wait_card(lambda u, prev: prev is not None and abs(u - prev) <= STABLE_MIB, SETTLE_GUARD_S)
    _, total = card()
    ctx = {"log": log, "service_dir": a.service_dir, "port": a.port, "python": python, "log_dir": a.log_dir,
           "idle_ref": idle, "total": total, "harness_commit": git("rev-parse", "HEAD"),
           "harness_dirty": bool(git("status", "--porcelain", "--", "sidecar/probe_double_load.py")),
           "lib_match_sha256": sha256(os.path.join(HERE, "lib_match.py"))}
    log("probe_double_load: idle reference %d of %d MiB (settled=%s), %d round(s) x %d arm(s) x %d shape(s)"
        % (idle, total, ok, a.rounds, len(arms), len(shapes)))

    n = 0
    with open(a.out, "a", encoding="utf-8", newline="\n") as f:
        for rnd in range(a.rounds):
            k = rnd % len(shapes)
            j = rnd % len(arms)
            for shape in shapes[k:] + shapes[:k]:
                for arm in arms[j:] + arms[:j]:
                    n += 1
                    row = trial(ctx, arm, shape, rnd + 1, n)
                    f.write(json.dumps(row, sort_keys=True) + "\n")
                    f.flush()
                    log("  trial %2d r%d %-8s %-6s load_count=%s held=%s MiB peak_held=%s flags=%s"
                        % (n, rnd + 1, arm[0], shape, row.get("load_count"), row.get("held_mib"),
                           row.get("peak_held_mib"), ",".join(row["flags"]) or "-"))
    log("")
    return summarise(a.out)


def median(xs):
    return statistics.median(xs) if xs else None


def summarise(path):
    """Every total and every verdict, derived from the rows file."""
    with open(path, encoding="utf-8") as f:
        rows = [json.loads(line) for line in f if line.strip()]
    print("rows: %d in %s" % (len(rows), path))
    cells = {}
    for r in rows:
        cells.setdefault((r["arm"], r["shape"]), []).append(r)
    blind = set()
    for (arm, shape), rs in sorted(cells.items()):
        valid = [r for r in rs if r["valid"]]
        bad = [r for r in rs if not r["valid"]]
        if len(bad) > 1:
            blind.add((arm, shape))
        counts = {}
        for r in valid:
            counts[r.get("load_count")] = counts.get(r.get("load_count"), 0) + 1
        print("  %-8s %-6s valid %d of %d  load_count %s  held MiB %s (median %s)  peak held median %s%s"
              % (arm, shape, len(valid), len(rs),
                 " ".join("%s:%d" % (k, v) for k, v in sorted(counts.items(), key=lambda kv: str(kv[0]))),
                 [r.get("held_mib") for r in valid], median([r["held_mib"] for r in valid if r.get("held_mib") is not None]),
                 median([r["peak_held_mib"] for r in valid if r.get("peak_held_mib") is not None]),
                 ("  INVALID: " + "; ".join("trial %d %s" % (r["trial"], ",".join(r["flags"])) for r in bad)) if bad else ""))

    def pick(arm, shapes):
        return [r for r in rows if r["arm"] == arm and r["shape"] in shapes and r["valid"]]

    def is_blind(arm, shapes):
        return any((arm, s) in blind for s in shapes)

    print("")
    verdicts = {}
    un = pick("unlocked", CONCURRENT)
    k2 = [r for r in un if (r.get("load_count") or 0) >= 2]
    if is_blind("unlocked", CONCURRENT) or not un:
        verdicts["B1"] = "BLIND"
    elif k2:
        verdicts["B1"] = "CONFIRMED"
    elif all(r.get("load_count") == 1 for r in un):
        verdicts["B1"] = "REFUTED"
    else:
        verdicts["B1"] = "INCONCLUSIVE"
    print("B1 double load exists: %s - load_count >= 2 in %d of %d valid unlocked concurrent trials"
          % (verdicts["B1"], len(k2), len(un)))

    single_un = median([r["held_mib"] for r in pick("unlocked", ("single",)) if r.get("held_mib") is not None])
    double_un = median([r["held_mib"] for r in k2 if r.get("held_mib") is not None])
    if is_blind("unlocked", ("single",) + CONCURRENT) or single_un is None or double_un is None:
        verdicts["B2"] = "BLIND"
        ratio = None
    else:
        ratio = double_un / single_un
        verdicts["B2"] = "CONFIRMED" if ratio >= B2_MIN_RATIO else "NOT CONFIRMED"
    print("B2 double load is the 2x: %s - median held %s MiB with load_count 2 against %s MiB single, ratio %s (bar %.1f)"
          % (verdicts["B2"], double_un, single_un, ("%.2f" % ratio) if ratio else None, B2_MIN_RATIO))

    lk = pick("locked", CONCURRENT)
    ones = [r for r in lk if r.get("load_count") == 1]
    all200 = [r for r in lk if r.get("requests") and all(q.get("status") == 200 for q in r["requests"])]
    single_lk = median([r["held_mib"] for r in pick("locked", ("single",)) if r.get("held_mib") is not None])
    conc_lk = median([r["held_mib"] for r in lk if r.get("held_mib") is not None])
    drift = (abs(conc_lk - single_lk) / single_lk) if (single_lk and conc_lk is not None) else None
    expected = 3 * len(CONCURRENT)
    if is_blind("locked", ("single",) + CONCURRENT) or len(lk) < expected or drift is None:
        verdicts["B3"] = "BLIND"
    elif len(ones) == len(lk) and len(all200) == len(lk) and drift <= B3_MAX_DRIFT:
        verdicts["B3"] = "ACCEPTED"
    else:
        verdicts["B3"] = "REJECTED"
    print("B3 the fix: %s - load_count 1 in %d of %d valid locked concurrent trials (bar %d of %d), all requests 200 in %d of %d, "
          "median held %s MiB against %s MiB single, drift %s (bar %.0f%%)"
          % (verdicts["B3"], len(ones), len(lk), expected, expected, len(all200), len(lk), conc_lk, single_lk,
             ("%.1f%%" % (drift * 100)) if drift is not None else None, B3_MAX_DRIFT * 100))
    invalid = [r for r in rows if not r["valid"]]
    print("invalid trials: %d of %d" % (len(invalid), len(rows)))
    return 0 if all(v in ("CONFIRMED", "ACCEPTED", "REFUTED", "NOT CONFIRMED", "REJECTED") for v in verdicts.values()) else 3


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--summarise", metavar="ROWS")
    ap.add_argument("--arm", nargs=3, action="append", metavar=("NAME", "DIR", "COMMIT"))
    ap.add_argument("--service-dir")
    ap.add_argument("--python")
    ap.add_argument("--shapes", default="single,pair0,hook")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--port", type=int, default=8079)
    ap.add_argument("--out")
    ap.add_argument("--log-dir")
    a = ap.parse_args()
    if a.summarise:
        return summarise(a.summarise)
    if not (a.arm and a.service_dir and a.out and a.log_dir):
        ap.error("a run needs --arm (at least one), --service-dir, --out and --log-dir")
    return run(a)


if __name__ == "__main__":
    sys.exit(main())
