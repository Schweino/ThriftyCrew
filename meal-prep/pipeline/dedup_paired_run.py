r"""Dispatch the frozen paired dedup cases to the decider, the way the daemon does (backlog I48).

    python meal-prep/pipeline/dedup_paired_run.py --dry-run     # build every prompt, spend nothing
    python meal-prep/pipeline/dedup_paired_run.py               # the approved form: 4 paid calls
    python meal-prep/pipeline/dedup_paired_run.py --selftest    # zero tokens, the dispatch is injected
    python meal-prep/pipeline/dedup_paired_probe.py --score     # read the result against the bars

WHAT THIS IS. `dedup_paired_probe.py` froze 20 candidates in both arms (`cases.jsonl`, fingerprint
34be0270169e593c) and scores verdicts, but nothing dispatched the cases. This does, and it does it
through the pipeline's own two pieces rather than a copy of them:
  * the PROMPT is `Daemon.decide_prompt` from hunt-daemon.py, called on the frozen dossiers;
  * the CALL is `hunt_dispatch.dispatch("recipe-dedup-selector", ...)` with `hunt_lib.DECIDE` and
    `hunt_lib.validate_decide`, so the agent, its model pin, its effort and its tools come from
    `.claude/agents/recipe-dedup-selector.md` exactly as they do for the daemon's decide lane.
The batches are the daemon's too: `hunt_lib.DECIDE_BATCH` (10) candidates per call, in the frozen
file's order, which is `harvest.dossier_rank` order. Both arms get the same two batches.

WHAT IS HELD STILL, AND WHY, so the arms differ in the field under test and nothing else.
  * the in-flight side is EMPTY for both arms. It is live state from other open runs, and letting it
    in would put neighbours back into the arm that is defined to carry none;
  * the precedent window is not rebuilt: both arms carry the frozen dossier's own `prior_rulings`
    (empty on all 20) and a `prior_rulings_window` that says `blind` - the same bytes in both arms;
  * the run id in the prompt is one string for both arms, so the prompt never names its arm;
  * batch 2 carries THAT ARM's own batch-1 acceptances, as the daemon carries a run's
    accepted-so-far. If the arms agree on batch 1 the two lists are identical; if they do not, the
    disagreement is already recorded.
ONE THING THE PIPELINE DOES THAT THE PROBE'S ARM DEFINITION DID NOT ANTICIPATE: `decide_prompt`
always writes a `catalog_checked` block, carrying its in-flight fields. So the `without` arm, as the
pipeline dispatches it, carries `catalog_checked` with ONLY `in_flight_recipes_searched` and
`in_flight_matches` and without the live-catalog counts. That is what production would send for a
dossier with no search declaration, so it is kept rather than stripped, and `--dry-run` prints it.

NOTHING IS APPLIED. No `decide_apply`, no considered-dishes write, no pool mark, no run state. The
verdicts go to `meal-prep/db/dedup-paired/` and nowhere else.

THE PAID-CALL CAP IS HARD: PAID_CALL_CAP = 4 per invocation (Brad, 2026-09-19). It counts BILLED CLI
INVOCATIONS, so a schema re-ask is a paid call too. The runner refuses before it starts when the plan
needs more than the cap, and the counting runner refuses any call past it. A re-ask is allowed only
when it still leaves one first call for every batch not yet sent, so with 4 batches under a cap of 4
a re-ask never happens: a batch that fails its schema is NO VERDICT for its cases and says so, and
nobody pays a fifth call to rescue it.

THE COST FORM (`--form single`, one candidate per call, 40 calls) IS BUILT BUT NOT APPROVED. It is
still bound by the same cap, so one invocation sends at most 4 calls and a re-run skips every case
already written. Brad approved the 4-call batched form only.

THE ACCEPTANCE BAR IS NOT RESTATED HERE. It is `AGREEMENT_BAR` in dedup_paired_probe.py, written on
2026-09-09 before any decider ran, and `--score` reads it. This file imports nothing it could move.

BATCHED ROWS CARRY NO PER-CASE OUTPUT TOKENS, on purpose. One call bills one output total for all ten
candidates, so `output_tokens` is null on every row and the batch totals ride beside it as
`batch_output_tokens`. `--score` then reads bar 1 over all 20 pairs and says BLIND ON TOKENS for
bar 2, which is the true state: a batched call cannot price a single case.

Exit 0 = every planned call returned a verdict. 1 = at least one batch came back NO VERDICT.
2 = refused (cap, fingerprint, a planned call past the cap). 3 = could not evaluate.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import types

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
REPO = os.path.dirname(MP)
sys.path.insert(0, HERE)

import dedup_paired_probe as probe                               # noqa: E402
import hunt_dispatch                                             # noqa: E402
import hunt_lib                                                  # noqa: E402

AGENT = "recipe-dedup-selector"
PAID_CALL_CAP = 4                 # Brad, 2026-09-19. Not a flag. Lower it with --max-calls, never raise.
FROZEN_FINGERPRINT = "34be0270169e593c"
PROBE_RUN_ID = "dedup-paired-probe"
CALLS = os.path.join(probe.OUT_DIR, "calls.jsonl")                # one row per dispatch (arm x batch)

EXIT_OK, EXIT_NO_VERDICT, EXIT_REFUSED, EXIT_BLIND = 0, 1, 2, 3


# ---------------------------------------------------------------------------------------------------
# inputs
# ---------------------------------------------------------------------------------------------------

def load_cases(path=probe.CASES):
    rows = []
    with io.open(path, encoding="utf-8-sig") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def arms_of(rows):
    """{arm: [(case, dossier), ...]} in FILE order - the frozen dossier_rank order."""
    out = {}
    for r in rows:
        out.setdefault(r["arm"], []).append((r["case"], r["dossier"]))
    return out


def check_frozen(rows, want=FROZEN_FINGERPRINT):
    """Problems with the case set; empty means it is the one Brad approved calls for."""
    problems = []
    fps = sorted(set(str(r.get("input_fingerprint")) for r in rows))
    if fps != [want]:
        problems.append("the case set's fingerprint is %s, not the approved %s" % (", ".join(fps), want))
    arms = arms_of(rows)
    if sorted(arms) != ["with", "without"]:
        problems.append("the case set carries arms %s, not with and without" % sorted(arms))
    elif [c for c, _ in arms["with"]] != [c for c, _ in arms["without"]]:
        problems.append("the two arms do not list the same cases in the same order")
    return problems


def batches(cases, form):
    size = hunt_lib.DECIDE_BATCH if form == "batched" else 1
    return [cases[i:i + size] for i in range(0, len(cases), size)]


def load_daemon():
    spec = importlib.util.spec_from_file_location("hunt_daemon", os.path.join(HERE, "hunt-daemon.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def build_prompt(daemon_mod, cases, accepted, stop):
    """The daemon's own decide_prompt over frozen dossiers, with the in-flight side held empty."""
    stub = types.SimpleNamespace(run_dir=os.path.join(tempfile.gettempdir(), PROBE_RUN_ID),
                                 run_id=PROBE_RUN_ID, accepted_slugs=list(accepted), _precedents={})
    # PATCHED WHERE decide_prompt RESOLVES IT - the daemon module's globals - and restored after.
    g = daemon_mod.Daemon.decide_prompt.__globals__
    real = g["read_inflight"]
    g["read_inflight"] = lambda *a, **k: []
    try:
        items = [{"slug": c, "dossier": d} for c, d in cases]
        return daemon_mod.Daemon.decide_prompt(stub, items, stop)
    finally:
        g["read_inflight"] = real


def done_cases(path=probe.VERDICTS):
    return set((r.get("case"), r.get("arm")) for r in probe.load_verdicts(path))


def git_blob(rel):
    try:
        p = subprocess.run(["git", "-C", REPO, "hash-object", rel], capture_output=True, timeout=30)
        return (p.stdout or b"").decode("ascii", "replace").strip() or None
    except Exception:                                             # noqa: BLE001
        return None


# ---------------------------------------------------------------------------------------------------
# the cap
# ---------------------------------------------------------------------------------------------------

class CallBudget(object):
    """Counts billed CLI invocations and refuses past the cap.

    `reserve` is the number of first calls still owed to batches not yet sent. A call is allowed
    only if it leaves room for all of them, so a re-ask can never starve a later batch.
    """

    def __init__(self, cap):
        self.cap = int(cap)
        self.used = 0
        self.refused = 0
        self.reserve = 0

    def wrap(self, real):
        def runner(argv, prompt, timeout, cwd):
            if self.used + 1 + self.reserve > self.cap:
                self.refused += 1
                return (None, "transport",
                        "PAID-CALL CAP: %d of %d paid call(s) used and %d still owed to later batches - "
                        "this call was NOT made" % (self.used, self.cap, self.reserve), 0.0)
            self.used += 1
            return real(argv, prompt, timeout, cwd)
        return runner


# ---------------------------------------------------------------------------------------------------
# the run
# ---------------------------------------------------------------------------------------------------

def plan(rows, form, done):
    """[(arm, batch_no, [(case, dossier)])] still to send, arms interleaved batch by batch."""
    arms = arms_of(rows)
    out = []
    per_arm = {a: batches(arms[a], form) for a in ("with", "without")}
    for i in range(max(len(v) for v in per_arm.values())):
        for a in ("with", "without"):
            if i < len(per_arm[a]):
                b = per_arm[a][i]
                if any((c, a) not in done for c, _ in b):
                    out.append((a, i + 1, b))
    return out


def run(rows, form="batched", max_calls=PAID_CALL_CAP, dispatch=None, real_runner=None,
        verdicts_path=probe.VERDICTS, calls_path=CALLS, daemon_mod=None, stop=None, methods=None,
        log=print):
    """Send the planned batches. Returns (exit_code, summary dict)."""
    cap = min(int(max_calls), PAID_CALL_CAP)
    problems = check_frozen(rows)
    if problems:
        for p in problems:
            log("dedup-paired-run: REFUSED - " + p)
        return EXIT_REFUSED, {"refused": problems}
    todo = plan(rows, form, done_cases(verdicts_path))
    if form == "batched" and len(todo) > cap:
        log("dedup-paired-run: REFUSED - the plan needs %d paid call(s) and the cap is %d"
            % (len(todo), cap))
        return EXIT_REFUSED, {"refused": ["plan %d > cap %d" % (len(todo), cap)]}
    if form == "single" and len(todo) > cap:
        log("dedup-paired-run: the single-candidate form has %d call(s) left; this invocation sends %d"
            % (len(todo), cap))
        todo = todo[:cap]
    if not todo:
        log("dedup-paired-run: nothing to send - every case already has a row in both arms")
        return EXIT_OK, {"calls": 0}

    daemon_mod = daemon_mod or load_daemon()
    if stop is None:
        stop, why = daemon_mod.read_stop_list()
        log("  stop list: %s" % why)
    if methods is None:
        import harvest                                            # noqa: PLC0415
        methods, _u = harvest.load_methods()
    allowed = set(methods) | {"any"}
    budget = CallBudget(cap)
    runner = budget.wrap(real_runner or hunt_dispatch._run)
    dispatch = dispatch or hunt_dispatch.dispatch
    blobs = {p: git_blob(p) for p in ("meal-prep/pipeline/dedup_paired_run.py",
                                      "meal-prep/pipeline/hunt-daemon.py",
                                      "meal-prep/pipeline/hunt_dispatch.py",
                                      ".claude/agents/recipe-dedup-selector.md",
                                      "meal-prep/db/dedup-paired/cases.jsonl")}
    accepted = {"with": [], "without": []}
    exit_code = EXIT_OK
    summary = {"calls": [], "cap": cap}
    for idx, (arm, bno, cases) in enumerate(todo):
        budget.reserve = len(todo) - idx - 1
        prompt = build_prompt(daemon_mod, cases, accepted[arm], stop)
        slugs = [c for c, _ in cases]
        res = dispatch(AGENT, prompt, schema=hunt_lib.DECIDE,
                       validator=lambda p: hunt_lib.validate_decide(p, methods=allowed),
                       runner=runner)
        now = time.strftime("%Y-%m-%dT%H:%M:%S")
        decisions = {}
        if res.payload:
            for d in res.payload.get("decisions") or []:
                if isinstance(d, dict) and d.get("slug") in slugs:
                    decisions[d["slug"]] = d
        missing = [s for s in slugs if s not in decisions]
        call_row = {"generated": now, "form": form, "arm": arm, "batch": bno, "cases": slugs,
                    "input_fingerprint": FROZEN_FINGERPRINT,
                    "prompt_sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest()[:16],
                    "prompt_chars": len(prompt), "ok": res.ok, "failure": res.failure,
                    "detail": res.detail, "problems": list(res.problems), "reasked": res.reasked,
                    "billed_invocations": res.calls, "api_turns": res.api_turns,
                    "tokens_in": res.tokens_in, "tokens_out": res.tokens_out,
                    "cache_read": res.cache_read, "cache_creation": res.cache_creation,
                    "cost_usd_cli": round(res.cost_usd, 6), "seconds": res.seconds,
                    "model_usage": res.model_usage, "findings": list(res.findings),
                    "denials": list(res.denials), "missing_cases": missing,
                    "note": (res.payload or {}).get("note") if res.payload else None,
                    "blobs": blobs}
        _append(calls_path, call_row)
        summary["calls"].append(call_row)
        for c in slugs:
            d = decisions.get(c)
            if not d:
                continue          # NO ROW: a case with no verdict is unpaired, never a disagreement
            if arm == "with" or arm == "without":
                if d.get("verdict") == "accepted":
                    accepted[arm].append(c)
            _append(verdicts_path, {
                "case": c, "arm": arm, "verdict": d.get("verdict"),
                "output_tokens": res.tokens_out if len(slugs) == 1 else None,
                "batch": bno, "batch_size": len(slugs), "form": form,
                "batch_input_tokens": res.tokens_in, "batch_output_tokens": res.tokens_out,
                "reason": d.get("reason"), "dupe_of": d.get("dupe_of") or [],
                "precedents": d.get("precedents") or [], "generated": now,
                "input_fingerprint": FROZEN_FINGERPRINT, "source": "dedup_paired_run.py"})
        log("  %-8s batch %d: %s  in=%d out=%d cost_cli=$%.4f  %d of %d ruled%s"
            % (arm, bno, "VERDICT" if res.ok else "NO VERDICT (%s)" % res.failure,
               res.tokens_in, res.tokens_out, res.cost_usd, len(slugs) - len(missing), len(slugs),
               ("  missing: " + ", ".join(missing)) if missing else ""))
        if not res.ok or missing:
            exit_code = EXIT_NO_VERDICT
    summary["paid_calls"] = budget.used
    summary["refused_calls"] = budget.refused
    return exit_code, summary


def _append(path, row):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with io.open(path, "a", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def dry_run(rows, form, log=print):
    problems = check_frozen(rows)
    for p in problems:
        log("dedup-paired-run: REFUSED - " + p)
    if problems:
        return EXIT_REFUSED
    mod = load_daemon()
    stop, why = mod.read_stop_list()
    log("  stop list: %s" % why)
    todo = plan(rows, form, done_cases())
    for arm, bno, cases in todo:
        p = build_prompt(mod, cases, [], stop)
        log("  %-8s batch %d: %d case(s), %d chars, sha %s"
            % (arm, bno, len(cases), len(p), hashlib.sha256(p.encode("utf-8")).hexdigest()[:16]))
    arms = arms_of(rows)
    one_w = json.loads(_dossiers_json(build_prompt(mod, arms["with"][:1], [], stop)))[0]
    one_o = json.loads(_dossiers_json(build_prompt(mod, arms["without"][:1], [], stop)))[0]
    diff = sorted(k for k in set(one_w) | set(one_o) if one_w.get(k) != one_o.get(k))
    log("  first case, fields that differ between the arms' prompts: %s" % ", ".join(diff))
    log("  without-arm catalog_checked as the pipeline writes it: %s"
        % json.dumps(one_o.get("catalog_checked")))
    log("  planned paid calls: %d (cap %d)" % (len(todo), PAID_CALL_CAP))
    log("DEDUP-PAIRED-RUN-COMPLETE dry-run calls_planned=%d" % len(todo))
    return EXIT_OK if len(todo) <= PAID_CALL_CAP or form == "single" else EXIT_REFUSED


def _dossiers_json(prompt):
    a = prompt.index("DOSSIERS:\n") + len("DOSSIERS:\n")
    b = prompt.rindex("\n\nReturn the DECIDE payload")
    return prompt[a:b]


# ---------------------------------------------------------------------------------------------------
# self-test: every dispatch injected, zero tokens
# ---------------------------------------------------------------------------------------------------

def _fake_rows(n=20, fp=FROZEN_FINGERPRINT):
    rows = []
    for i in range(n):
        full = {"slug": "c%02d" % i, "name": "Zorbled Quimbish Plate %d" % i, "neighbours": [{"slug": "x", "side": "live-catalog"}],
                "catalog_checked": {"live_recipes_searched": 5}, "prior_rulings": [],
                "signature": {"protein": "chicken", "method": "skillet"}}
        rows.append({"case": full["slug"], "arm": "with", "input_fingerprint": fp, "dossier": full})
        rows.append({"case": full["slug"], "arm": "without", "input_fingerprint": fp,
                     "dossier": probe.strip_neighbours(full)})
    return rows


def _fake_env(verdicts, out_tok=900):
    payload = {"decisions": [{"slug": s, "verdict": v, "reason": "fixture",
                              "record": {"name": s, "protein": "chicken", "method": "skillet",
                                         "verdict": v, "reason": "fixture"}}
                             for s, v in verdicts]}
    return {"result": json.dumps(payload), "usage": {"input_tokens": 1000, "output_tokens": out_tok},
            "total_cost_usd": 0.5, "num_turns": 1, "session_id": "",
            "modelUsage": {"claude-opus-4-8": {"inputTokens": 1000, "outputTokens": out_tok}}}


def selftest():
    bad = []
    ran = []

    def T(label, name, ok, got=""):
        ran.append(name)
        if not ok:
            bad.append(name)
        print("  %-14s %-70s %s" % (label, name, "ok" if ok else "FAIL " + str(got)[:300]))

    real_mod = load_daemon()
    fake_mod = real_mod
    stop, _why = real_mod.read_stop_list()
    # A LIVE IN-FLIGHT TWIN, planted where decide_prompt looks. The runner must hold it out.
    g = real_mod.Daemon.decide_prompt.__globals__
    planted = lambda *a, **k: [{"slug": "live-inflight", "name": "Zorbled Quimbish Plate Twin",
                                "state": "selected", "run": "r"}]
    orig_inflight = g["read_inflight"]
    g["read_inflight"] = planted
    stub = types.SimpleNamespace(run_dir="x", run_id="x", accepted_slugs=[], _precedents={})
    leak = real_mod.Daemon.decide_prompt(stub, [{"slug": "c01", "dossier": {"slug": "c01",
                                         "name": "Zorbled Quimbish Plate 1"}}], stop)
    tmp = tempfile.mkdtemp(prefix="dpr-")
    try:
        rows = _fake_rows()
        sent = []

        def runner_ok(argv, prompt, timeout, cwd):
            sent.append((argv, prompt))
            slugs = [s for s in ("c%02d" % i for i in range(20)) if '"slug": "%s"' % s in prompt]
            return _fake_env([(s, "accepted" if s != "c03" else "rejected-dupe") for s in slugs]), None, "", 0.1

        vp, cp = os.path.join(tmp, "v1.jsonl"), os.path.join(tmp, "c1.jsonl")
        rc, summ = run(rows, real_runner=runner_ok, verdicts_path=vp, calls_path=cp,
                       daemon_mod=fake_mod, stop=stop, methods=["skillet"], log=lambda *_: None)
        written = probe.load_verdicts(vp)
        T("CLEAN TWIN", "the approved form sends exactly 4 calls and writes 40 rows",
          rc == EXIT_OK and len(sent) == 4 and summ["paid_calls"] == 4 and len(written) == 40,
          (rc, len(sent), len(written)))
        T("CLEAN TWIN", "every call goes through --agent recipe-dedup-selector",
          all(a[a.index("--agent") + 1] == AGENT for a, _ in sent if "--agent" in a)
          and all("--agent" in a for a, _ in sent), [a for a, _ in sent][:1])
        T("CLEAN TWIN", "each call carries 10 candidates, the daemon's DECIDE_BATCH",
          all(p.startswith("Rule on 10 candidate dossier(s)") for _, p in sent), sent[0][1][:60])
        sc = probe.score(written)
        T("CLEAN TWIN", "the harness pairs all 20 and reads bar 1, BLIND on per-case tokens",
          sc["pairs"] == 20 and sc["state"] == "BLIND ON TOKENS" and sc["agreed"] == 20, sc)

        # MUST FIRE: the in-flight side is live state and must not put neighbours into either arm.
        w = [p for _, p in sent][1]
        T("MUST FIRE", "a live in-flight twin is NOT injected into the without arm's prompt",
          "live-inflight" in leak and "live-inflight" not in w and g["read_inflight"] is planted,
          ("planted reaches a bare decide_prompt" if "live-inflight" in leak else "fixture inert", w[:200]))
        T("MUST FIRE", "the prompt never names its arm",
          all(" with" not in p.split(chr(10))[0] and "without" not in p.split("RETURN CONTRACT")[0]
              for _, p in sent))
        T("CLEAN TWIN", "batch 2 carries that arm's own batch-1 acceptances",
          "ALREADY ACCEPTED THIS RUN (9)" in sent[2][1] and "c00" in sent[2][1].split("\n\n")[1],
          sent[2][1].split("\n\n")[1][:200])

        # MUST FIRE: the cap. A fifth call is refused and never reaches the runner.
        n0 = len(sent)
        b = CallBudget(4)
        wrapped = b.wrap(runner_ok)
        outs = [wrapped([], '"slug": "c00"', 1, None) for _ in range(5)]
        T("MUST FIRE", "the fifth paid call in one invocation is refused",
          b.used == 4 and b.refused == 1 and outs[4][1] == "transport"
          and "PAID-CALL CAP" in outs[4][2] and len(sent) == n0 + 4, (b.used, b.refused))
        T("MUST FIRE", "--max-calls can lower the cap and can never raise it",
          run(rows, max_calls=40, real_runner=runner_ok, verdicts_path=os.path.join(tmp, "v9.jsonl"),
              calls_path=os.path.join(tmp, "c9.jsonl"), daemon_mod=fake_mod, stop=stop,
              methods=["skillet"], log=lambda *_: None)[1]["cap"] == 4
          and run(rows, max_calls=3, real_runner=runner_ok, verdicts_path=os.path.join(tmp, "v8.jsonl"),
                  calls_path=os.path.join(tmp, "c8.jsonl"), daemon_mod=fake_mod, stop=stop,
                  methods=["skillet"], log=lambda *_: None)[0] == EXIT_REFUSED)

        # MUST FIRE: a schema failure may not re-ask when the re-ask would starve a later batch.
        seen = []

        def runner_bad_first(argv, prompt, timeout, cwd):
            seen.append(argv)
            if len(seen) == 1:
                return {"result": "not json", "usage": {"input_tokens": 5, "output_tokens": 5},
                        "total_cost_usd": 0.1, "num_turns": 1, "session_id": "s1",
                        "modelUsage": {"claude-opus-4-8": {}}}, None, "", 0.1
            return runner_ok(argv, prompt, timeout, cwd)

        vp2, cp2 = os.path.join(tmp, "v2.jsonl"), os.path.join(tmp, "c2.jsonl")
        rc2, s2 = run(rows, real_runner=runner_bad_first, verdicts_path=vp2, calls_path=cp2,
                      daemon_mod=fake_mod, stop=stop, methods=["skillet"], log=lambda *_: None)
        T("MUST FIRE", "a schema failure under a full budget is NO VERDICT, not a fifth call",
          rc2 == EXIT_NO_VERDICT and s2["paid_calls"] == 4 and len(seen) == 4
          and len(probe.load_verdicts(vp2)) == 30, (rc2, s2.get("paid_calls"), len(seen)))
        T("MUST NOT FIRE", "a batch with no verdict writes no row, so it is unpaired, not a disagreement",
          probe.score(probe.load_verdicts(vp2))["unpaired"] == 10
          and probe.score(probe.load_verdicts(vp2))["pairs"] == 10)

        # CLEAN TWIN: a re-run resumes and pays nothing for cases already written.
        sent_before = len(sent)
        rc3, s3 = run(rows, real_runner=runner_ok, verdicts_path=vp, calls_path=cp,
                      daemon_mod=fake_mod, stop=stop, methods=["skillet"], log=lambda *_: None)
        T("CLEAN TWIN", "a re-run over a complete verdict file sends nothing",
          rc3 == EXIT_OK and len(sent) == sent_before and s3.get("calls") == 0, s3)

        # MUST FIRE: a case set that is not the frozen one is refused before any call.
        rc4, _ = run(_fake_rows(fp="0000000000000000"), real_runner=runner_ok,
                     verdicts_path=os.path.join(tmp, "v4.jsonl"), calls_path=os.path.join(tmp, "c4.jsonl"),
                     daemon_mod=fake_mod, stop=stop, methods=["skillet"], log=lambda *_: None)
        T("MUST FIRE", "a case set with another fingerprint is refused and costs nothing",
          rc4 == EXIT_REFUSED and len(sent) == sent_before)

        # CLEAN TWIN: the single form is still capped per invocation.
        vp5 = os.path.join(tmp, "v5.jsonl")
        n5 = len(sent)
        rc5, s5 = run(rows, form="single", real_runner=runner_ok, verdicts_path=vp5,
                      calls_path=os.path.join(tmp, "c5.jsonl"), daemon_mod=fake_mod, stop=stop,
                      methods=["skillet"], log=lambda *_: None)
        rows5 = probe.load_verdicts(vp5)
        T("CLEAN TWIN", "the 40-call form sends 4 per invocation and records per-case tokens",
          len(sent) - n5 == 4 and s5["paid_calls"] == 4 and len(rows5) == 4
          and all(r["output_tokens"] == 900 for r in rows5), (len(sent) - n5, len(rows5)))

        # The real frozen file is the approved one.
        if os.path.isfile(probe.CASES):
            T("CLEAN TWIN", "the committed cases.jsonl is the approved frozen set",
              check_frozen(load_cases()) == [], check_frozen(load_cases()))
    finally:
        g["read_inflight"] = orig_inflight
        for f in os.listdir(tmp):
            os.remove(os.path.join(tmp, f))
        os.rmdir(tmp)

    print("")
    total = len(ran)
    if bad:
        print("dedup-paired-run SELF-TEST FAIL: %d of %d" % (len(bad), total))
        return 1
    print("dedup-paired-run SELF-TEST PASS (%d cases)" % total)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="build every prompt, send nothing")
    ap.add_argument("--form", choices=("batched", "single"), default="batched",
                    help="batched = the approved 4 calls; single = the unapproved cost form")
    ap.add_argument("--max-calls", type=int, default=PAID_CALL_CAP,
                    help="lowers the paid-call cap for this invocation; it can never raise it")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    rows = load_cases()
    if a.dry_run:
        return dry_run(rows, a.form)
    rc, summ = run(rows, form=a.form, max_calls=a.max_calls)
    calls = summ.get("calls") or []
    if isinstance(calls, list) and calls:
        tin = sum(c["tokens_in"] for c in calls)
        tout = sum(c["tokens_out"] for c in calls)
        cost = sum(c["cost_usd_cli"] for c in calls)
        print("  total: %d paid call(s), in=%d out=%d, cost as the CLI reports it $%.4f"
              % (summ.get("paid_calls", 0), tin, tout, cost))
    print("DEDUP-PAIRED-RUN-COMPLETE rc=%d paid_calls=%s" % (rc, summ.get("paid_calls", 0)))
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
