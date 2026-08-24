"""
hunt_daemon_drill.py - the drain-mode drill (PLAN-recipe-hunter-v3 section 4.2, D9's phase-3 gate).

    C:\\Codex\\Python312\\python.exe hunt_daemon_drill.py [--source <run dir>] [--keep]

WHAT SECTION 4.2 ORDERS: "Drain-mode drill before any live run: seed from the existing lowcarb-100
run dir's -Status, walk 2-3 recipes through write/qa/wave with publish in -DryRun, diff the run dir
against the contract."

WHAT IS REAL HERE AND WHAT IS STOOD IN FOR, stated up front because a drill that hides its stubs is
a drill nobody can read:

  REAL - the whole point of the exercise:
    * `hunt-run.ps1 -Status -Json`, and the section 4.5 seed table driven off it;
    * every state advance and every lane-log line, through hunt-run.ps1 itself;
    * `wave-preaudit.ps1`, `hunt-run.ps1 -WaveClose`, `batch-ledger.ps1`, and
      `wave-publish.ps1 -DryRun` - the publish path, walking every gate and publishing nothing;
    * `audit-lane-shape.ps1` over the lane log the daemon just wrote.

  STOOD IN FOR, each for a reason:
    * the JUDGMENT AGENTS (writer, source-qa, batch-auditor). The adapter is drilled separately and
      exhaustively in `hunt_dispatch_drill.py` against a Workflow twin; paying six more frontier
      calls to re-prove it would measure nothing this gate does not already have. The stand-ins
      return the same schema'd shapes and DO the agents' file work - the auditor writes its
      wave-<k>.audit.md, because wave-publish P1/P1b read that file and a drill that skipped it
      would be walking a gate that was never there.
    * `build-v2-spec.ps1 -RunCost`. It shells the cost engine, which rewrites the LIVE
      `db\\costed.json` - a shared file this estate has already watched get rewritten mid-audit, and
      another session may be working in the tree. The cost-engine MUTEX around it is proven in
      hunt-daemon's own fixture, where two concurrent write-lane completions are shown to serialize.

  AND THE RUN DIR IS A COPY. The drill seeds from the real lowcarb-100 dir and then works on a copy
  in the scratchpad: 20 of those recipes are LIVE pages and their run record is the only account of
  how they got there. `db\\recipes`, the pool and the ledger are read, never written.

EXIT CODES (section 4.5): 0 clean / 1 findings / 2 could-not-run. Marker DRAIN-DRILL-COMPLETE.
"""
from __future__ import annotations

import argparse
import asyncio
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
REPO = os.path.dirname(MP)
sys.path.insert(0, HERE)

import hunt_lib                                                  # noqa: E402

spec = importlib.util.spec_from_file_location("hunt_daemon", os.path.join(HERE, "hunt-daemon.py"))
HD = importlib.util.module_from_spec(spec)
sys.modules["hunt_daemon"] = HD
spec.loader.exec_module(HD)

SOURCE_RUN = os.path.join(MP, "runs", "hunt-2026-08-15-lowcarb-100")
OUT_DIR = os.path.join(MP, "out", "d9-gate", "drain-drill")
AUDIT_LANE_SHAPE_PS = os.path.join(HERE, "audit-lane-shape.ps1")

# The section 4.5 contract for a run dir, as a shape rather than as prose. A run dir the daemon
# produced must be indistinguishable from one the workflow produced, and this is what that means.
RUN_DIR_CONTRACT = {
    "files": ["run.json", "lane-log.jsonl", "accepted-slugs.json"],
    "dirs": ["state", "extracted", "mapped", "intake", "qa", "waves"],
    "lane_line_keys": ["at", "lane", "label", "count", "items", "by", "detail", "in", "out", "event"],
    "lanes": ["hunt", "select", "extract", "map", "price", "write", "qa", "audit", "publish",
              "review"],
    "state_keys": ["slug", "title", "source_url", "protein", "state", "wave", "created", "updated",
                   "terms", "reject_reason", "parked_on", "history"],
}


def say(m):
    print(m, flush=True)


class Stand(object):
    """The judgment stand-ins. Same schema'd shapes the real agents return, and the same file work."""

    def __init__(self, run_dir):
        self.run_dir = run_dir
        self.calls = []

    def __call__(self, agent, prompt, schema=None, validator=None, **kw):
        self.calls.append(agent)
        res = HD.hunt_dispatch.DispatchResult(agent)
        res.tokens_in, res.tokens_out = 15470, 224   # the drill's measured per-dispatch medians
        if agent == "recipe-writer":
            slug = prompt.split("Write recipe ", 1)[1].split(" ", 1)[0]
            res.payload = {"slug": slug, "status": "ok", "state": "written",
                           "detail": "stand-in writer"}
        elif agent == "recipe-source-qa":
            slug = prompt.split("ONE built recipe: ", 1)[1].split("\n", 1)[0].strip().rstrip(".")
            res.payload = {"slug": slug, "verdict": "PASS", "owner": "", "findings": ""}
        elif agent == "recipe-batch-auditor":
            wk = int(prompt.split("Audit wave ", 1)[1].split(" ", 1)[0])
            scope = prompt.split("scope: ", 1)[1].split("\n", 1)[0].strip()
            p = os.path.join(self.run_dir, "waves", "wave-%d.audit.md" % wk)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as f:
                f.write("GO\nscope: %s\n\nStand-in auditor for the section 4.2 drain drill.\n" % scope)
            res.payload = {"verdict": "GO", "blocking_slugs": [], "blocker_kind": "",
                           "owner": "", "summary": "stand-in GO"}
        elif agent == "post-publish-reviewer":
            res.payload = {}
        else:
            res.payload = {}
        return res


def queue_redirected_ps(scratch_queue):
    """Real ps_invoke for everything, with ingredient-queue calls pointed at a SCRATCH -QueueFile.

    ADDED 2026-08-24 (phase-4 aftercare, measured): the fresh-lane drill ran with NO ps injection, so
    its map lane's real -Add calls wrote `drill term one..four` into the LIVE grocery worklist on
    every run - four pending rows a real pricer would have driven seven stores to answer. The same
    class as the drill that opened w5/w6 in the live batch ledger, found the same way: by reading the
    live file after a green drill. The script grew -QueueFile for fixtures; this drill uses it too.
    """
    def ps(script, args, timeout=180):
        if "ingredient-queue" in os.path.basename(script):
            args = list(args) + ["-QueueFile", scratch_queue]
        return hunt_lib.ps_invoke(script, args, timeout)
    return ps


def filtered_ps(stub_scripts):
    """Real ps_invoke for everything except the named scripts, which are stood in for."""
    calls = []

    def ps(script, args, timeout=180):
        name = os.path.basename(script)
        calls.append({"script": name, "args": list(args)})
        for s in stub_scripts:
            if s in name:
                return 0, "%s: STOOD IN FOR by the drain drill" % name, ""
        return hunt_lib.ps_invoke(script, args, timeout)
    ps.calls = calls
    return ps


def check_contract(run_dir):
    """Diff the run dir against section 4.2's contract: a daemon-produced run dir must be
    indistinguishable in SHAPE from a workflow-produced one."""
    findings = []
    for f in RUN_DIR_CONTRACT["files"]:
        if not os.path.exists(os.path.join(run_dir, f)):
            findings.append("the run dir has no %s" % f)
    for dd in RUN_DIR_CONTRACT["dirs"]:
        if not os.path.isdir(os.path.join(run_dir, dd)):
            findings.append("the run dir has no %s\\ directory" % dd)

    lines = []
    p = os.path.join(run_dir, "lane-log.jsonl")
    if os.path.exists(p):
        with open(p, "r", encoding="utf-8-sig") as f:
            for i, raw in enumerate(f, 1):
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    lines.append(json.loads(raw))
                except Exception as e:                            # noqa: BLE001
                    findings.append("lane-log line %d does not parse (%s)" % (i, e))
    for i, ln in enumerate(lines[-40:], 1):
        missing = [k for k in RUN_DIR_CONTRACT["lane_line_keys"] if k not in ln]
        if missing:
            findings.append("a lane-log line is missing %s" % ", ".join(missing))
            break
        if ln.get("lane") not in RUN_DIR_CONTRACT["lanes"]:
            findings.append("a lane-log line names lane %r, which audit-lane-shape does not judge"
                            % ln.get("lane"))
            break

    for fn in sorted(os.listdir(os.path.join(run_dir, "state")))[:200]:
        if not fn.endswith(".json"):
            continue
        with open(os.path.join(run_dir, "state", fn), "r", encoding="utf-8-sig") as f:
            st = json.load(f)
        missing = [k for k in RUN_DIR_CONTRACT["state_keys"] if k not in st]
        if missing:
            findings.append("state\\%s is missing %s" % (fn, ", ".join(missing)))
            break
    return findings, lines


def pair_report(lines, since):
    """Start/end pairing on the lines this drill wrote. The pair is the only measurement of how long
    a stage takes, and it is why the daemon writes both ends."""
    mine = [ln for ln in lines if str(ln.get("at") or "") >= since]
    keyed = {}
    for ln in mine:
        keyed.setdefault((ln.get("lane"), ln.get("label")), []).append(ln)
    paired, unpaired, stamped = 0, [], 0
    for key, group in keyed.items():
        events = sorted(str(g.get("event") or "") for g in group)
        if events == ["end", "start"]:
            paired += 1
            end = [g for g in group if g.get("event") == "end"][0]
            if int(end.get("in") or -1) >= 0 and int(end.get("out") or -1) >= 0:
                stamped += 1
        else:
            unpaired.append("%s/%s %s" % (key[0], key[1], events))
    return {"lines_written": len(mine), "pairs": paired, "unpaired": unpaired,
            "pairs_with_token_stamps": stamped}


async def drill(source, keep):
    t_start = time.strftime("%Y-%m-%dT%H:%M:%S")
    os.makedirs(OUT_DIR, exist_ok=True)
    rec = {"generated": t_start, "source_run": source, "phases": [], "findings": []}

    if not os.path.isdir(source):
        say("drain drill: CANNOT RUN - no source run dir at %s" % source)
        return hunt_lib.EXIT_CANNOT_RUN, rec

    # ---- 1. seed off the REAL run dir's -Status, then work on a copy ---------------------------
    say("== 1. seed from the real run dir's -Status (read-only) ====================")
    real = HD.Daemon(source, os.path.basename(source), quiet=True)
    ok, err = await real.seed()
    if not ok:
        say("  CANNOT RUN - %s" % err)
        return hunt_lib.EXIT_CANNOT_RUN, rec
    seeded = dict(getattr(real, "seed_counts", {}))
    say("  seeded %s" % (", ".join("%s=%d" % kv for kv in sorted(seeded.items())) or "(nothing)"))
    say("  held   %d   review pending %d" % (len(real.held), len(real.review_pending)))
    rec["phases"].append({"phase": "seed-from-real", "seed_counts": seeded,
                          "held": [h[0] for h in real.held],
                          "review_pending": real.review_pending,
                          "wip": real.wip()})

    scratch = tempfile.mkdtemp(prefix="drain-drill-")
    run_dir = os.path.join(scratch, os.path.basename(source))
    shutil.copytree(source, run_dir)
    ledger = os.path.join(scratch, "batch-ledger.json")
    say("  working copy: %s" % run_dir)

    lane_since = time.strftime("%Y-%m-%dT%H:%M:%S")
    stand = Stand(run_dir)
    # build-intake-skeleton.ps1 JOINED THE STAND-IN LIST 2026-08-24 (v3 D8), for the same reason
    # build-v2-spec is on it. D8 put the skeleton builder and its locked-field -Verify in front of
    # and behind the writer, and this drill's writer is a stand-in that produces no prose - so the
    # real -Verify would refuse every walked recipe on "the writer returned NO prose at all",
    # which is the postcondition working and tells this drill nothing. What this drill measures is
    # section 4.2's LANE SHAPE, so the surfaces the stand-in cannot satisfy are stood in for and
    # the skeleton itself is written below. The write lane's own behaviour is fixtured in
    # hunt_daemon_selftest.py and was demonstrated live by the phase-4 gate run.
    ps = filtered_ps(["build-v2-spec.ps1", "build-intake-skeleton.ps1"])
    # A LEDGER OF ITS OWN. Measured 2026-08-24: the first two runs of this drill opened w5 and w6
    # in the LIVE batch ledger and left them open, which batch-ledger -Verify would report as
    # stalled batches forever. wave-publish.ps1 built -LedgerPath for exactly this reason.
    d = HD.Daemon(run_dir, os.path.basename(source), dispatcher=stand, ps=ps,
                  ledger_path=ledger)
    await d.seed()

    # ---- 2. the wave lane FIRST, with publish in -DryRun -----------------------------------------
    #
    # ORDER MATTERS AND THE FIRST RUN OF THIS DRILL GOT IT WRONG. Walking three recipes through
    # write/qa first swept them into the same wave, and wave-publish then refused - correctly - with
    # "no v2 spec in db\recipes" for exactly those three, because the cost engine that builds
    # a spec is the thing this drill stands in for. So the wave runs over the recipes that
    # is the thing this drill stands in for. So the wave runs over the recipes that ALREADY have
    # built specs, where every publish gate is real and can actually be walked, and the write/qa lanes
    # are exercised after it on recipes the wave is no longer waiting for.
    say("")
    say("== 2. the wave lane over the already-specced qa-passed pool, publish -DryRun ==")
    d.dry_run_publish = True
    pool_before = list(d.qa_passed)
    k = d.maybe_close_wave(force=True)
    if k is None:
        rec["findings"].append("no wave could be closed from a pool of %d" % len(pool_before))
    else:
        await d.run_wave(k, drain=True)
    say("  wave results: %s" % json.dumps(d.wave_results)[:600])
    rec["phases"].append({"phase": "wave", "qa_passed_pool": pool_before,
                          "results": d.wave_results, "publish_dry_run": True})
    if not d.wave_results:
        rec["findings"].append("the wave lane produced no result at all")
    else:
        w = d.wave_results[-1]
        if w.get("verdict") != "GO":
            rec["findings"].append("the wave did not reach GO: %s"
                                   % json.dumps({kk: w[kk] for kk in w if kk != "refusal"})[:300])
            if w.get("refusal"):
                rec["findings"].append("  the publish refusal, verbatim: %s"
                                       % w["refusal"].replace(chr(13), " ")
                                       .replace(chr(10), " | ")[:600])
        elif not w.get("dry_run"):
            rec["findings"].append("the wave was not recognised as a dry run - it must publish "
                                   "nothing and dispatch no reviewer")
        if "post-publish-reviewer" in stand.calls:
            rec["findings"].append("a post-publish reviewer was dispatched at pages a DRY RUN did "
                                   "not publish")

    # ---- 3. walk 3 recipes through write and qa --------------------------------------------------
    say("")
    say("== 3. walk 3 recipes through the write and qa lanes ========================")
    picked = []
    while d.ch["write"].size() and len(picked) < 3:
        picked.append(await d.ch["write"].take())
    while d.ch["write"].size():
        await d.ch["write"].take()      # this drill walks THREE, not the whole backlog
    for c in picked:
        d.ch["write"].push(c)
    d.ch["write"].close()
    d.spec_band = lambda slug, specs_dir=None: (520, 12)   # the cost engine is stood in for
    # The skeleton the stood-in builder would have written, so the pre-write band gate has real
    # numbers to rule on. In band on purpose: this drill is about lane shape, and the band gate's own
    # behaviour has its fixtures elsewhere.
    for c in picked:
        ip = os.path.join(run_dir, "intake", "%s.json" % c["slug"])
        os.makedirs(os.path.dirname(ip), exist_ok=True)
        doc = {"name": c["slug"], "slug": c["slug"], "protein": "beef", "cuisine": "",
               "source_url": "https://d/x", "visibility": "paid",
               "ingredients": [{"item": "93/7 Ground Beef", "grams": 1568, "buy": "3 1/2 lb"}],
               "macros_per_serving": {"calories": 520, "protein_g": 35.0, "carbs_g": 12,
                                      "fat_g": 20.0},
               "writer_notes": [], "forbidden_prose_terms": [], "prose": {},
               "head": {"description": "", "keywords": "", "image": "", "prepTime": "PT15M",
                        "cookTime": "PT25M", "totalTime": "PT40M", "steps": []}}
        with open(ip, "w", encoding="utf-8") as fh:
            json.dump(doc, fh)
        with open(os.path.join(run_dir, "intake", "%s.skeleton.json" % c["slug"]), "w",
                  encoding="utf-8") as fh:
            json.dump({"slug": c["slug"], "findings": [], "notes": [], "intake": doc}, fh)
    say("  walking: %s" % ", ".join(c["slug"] for c in picked))
    # The LANES directly rather than run(): run() ends by force-closing a wave, which is the
    # workflow's own order and correct in a live run, but here it would sweep these three into a
    # second wave whose specs the stand-in never built.
    await asyncio.gather(d.write_lane(), d.qa_lane())
    walked = [c["slug"] for c in picked]
    states = {s: d.state_of(s) for s in walked}
    say("  states after: %s" % json.dumps(states))
    rec["phases"].append({"phase": "write-qa", "slugs": walked, "states_after": states,
                          "outcomes": d.outcomes})
    if any(v != "qa-passed" for v in states.values()):
        rec["findings"].append("write/qa did not carry every walked recipe to qa-passed: %s"
                               % json.dumps(states))
    rec["findings"].extend(d.findings)

    # ---- 4. diff the run dir against the contract ------------------------------------------------
    say("")
    say("== 4. diff the run dir against the section 4.2 contract ====================")
    cfindings, lines = check_contract(run_dir)
    pairs = pair_report(lines, lane_since)
    say("  lane-log lines written by this drill: %d   start/end pairs: %d   with token stamps: %d"
        % (pairs["lines_written"], pairs["pairs"], pairs["pairs_with_token_stamps"]))
    for u in pairs["unpaired"]:
        cfindings.append("an unpaired lane-log entry: %s" % u)
    if pairs["pairs"] and pairs["pairs_with_token_stamps"] != pairs["pairs"]:
        cfindings.append("%d of %d pairs carry no token stamp"
                         % (pairs["pairs"] - pairs["pairs_with_token_stamps"], pairs["pairs"]))
    for f in cfindings:
        say("  FINDING  %s" % f)
    if not cfindings:
        say("  the run dir matches the contract: files, directories, lane-line keys, lane "
            "vocabulary, state-file keys.")
    rec["phases"].append({"phase": "contract-diff", "pairs": pairs, "findings": cfindings})
    rec["findings"].extend(cfindings)

    # ---- 5. audit-lane-shape, on a lane log the DAEMON ALONE WROTE -------------------------------
    #
    # THE GATE SAYS "clean on a DAEMON-PRODUCED lane log", and the copied run dir is not one: it
    # carries 834 lines of the v2 workflow's own history, whose price and map shape audit-lane-shape
    # has always had findings about. Judging that log would be judging v2 and calling it D9. So this
    # phase does both halves and keeps them apart:
    #   5a. a FRESH run dir the daemon wrote from -Init onwards, which must be CLEAN;
    #   5b. the copy, alongside the untouched original, to show the daemon's 14 lines added no
    #       finding that was not already there.
    say("")
    say("== 5a. audit-lane-shape on a run dir the daemon alone wrote ================")
    fresh_rc, fresh_out, fresh_detail = await fresh_lane_log_drill(scratch)
    for ln in (fresh_out or "").strip().splitlines()[-12:]:
        say("  " + ln)
    rec["phases"].append({"phase": "audit-lane-shape-fresh", "exit": fresh_rc,
                          "detail": fresh_detail, "output": (fresh_out or "")[-4000:]})
    if fresh_rc != 0:
        rec["findings"].append("audit-lane-shape exited %d on a lane log the daemon alone wrote"
                               % fresh_rc)
    if "LANE-SHAPE-COMPLETE" not in (fresh_out or ""):
        rec["findings"].append("audit-lane-shape never printed its completion marker on the fresh log")

    say("")
    say("== 5b. the copy, against the untouched original ============================")
    rc, out, _e = hunt_lib.ps_invoke(AUDIT_LANE_SHAPE_PS, ["-RunDir", run_dir], timeout=600)
    rc0, out0, _e0 = hunt_lib.ps_invoke(AUDIT_LANE_SHAPE_PS, ["-RunDir", source], timeout=600)
    codes = sorted(set(_finding_codes(out)))
    codes0 = sorted(set(_finding_codes(out0)))
    say("  after the daemon's lines : exit %d  %s" % (rc, ", ".join(codes) or "(clean)"))
    say("  the original, untouched  : exit %d  %s" % (rc0, ", ".join(codes0) or "(clean)"))
    rec["phases"].append({"phase": "audit-lane-shape-appended", "exit": rc,
                          "codes_after": codes, "exit_original": rc0, "codes_original": codes0,
                          "output": (out or "")[-4000:]})
    new_codes = [c for c in codes if c not in codes0]
    if new_codes:
        rec["findings"].append("the daemon's own lane lines introduced a NEW lane-shape finding: %s"
                               % ", ".join(new_codes))
    else:
        say("  the daemon added no finding that was not already in the v2 history.")

    # EXPECTED, BECAUSE OF A STUB THIS DRILL DECLARED - not swept away, MOVED and labelled. The QA
    # battery reads the built spec, and build-v2-spec is the one script stood in for, so it cannot
    # run for the three walked recipes. The daemon's handling of that is itself correct and is the
    # thing worth reading: exit 2 is recorded as a finding and the QA agent is still dispatched,
    # because could-not-look is never a clean bill and it is also never a reason to skip the judge.
    expected, real = [], []
    for f in rec["findings"]:
        if "the QA battery could not run (exit 2)" in f:
            expected.append(f)
        else:
            real.append(f)
    rec["expected_findings"] = {
        "why": ("build-v2-spec.ps1 is stood in for, so the three walked recipes have no built spec "
                "and coverage_check --battery correctly exits 2. The daemon recorded each one as a "
                "finding and dispatched source-QA anyway, which is the ordered behaviour."),
        "findings": expected}
    rec["findings"] = real

    rec["run_dir_copy"] = run_dir if keep else "(removed)"
    with open(os.path.join(OUT_DIR, "drain-drill.json"), "w", encoding="utf-8") as f:
        json.dump(rec, f, indent=1, ensure_ascii=False)
    say("")
    say("  -> %s" % os.path.join(OUT_DIR, "drain-drill.json"))
    if keep:
        say("  the working copy is kept at %s" % run_dir)
    else:
        shutil.rmtree(scratch, ignore_errors=True)
    return (hunt_lib.EXIT_FINDINGS if rec["findings"] else hunt_lib.EXIT_CLEAN), rec


def _finding_codes(out):
    import re                                                    # noqa: PLC0415
    return re.findall(r"\[([a-z0-9-]+)\]", out or "")


async def fresh_lane_log_drill(scratch):
    """A run dir the daemon wrote from -Init onwards, so audit-lane-shape judges D9 and nothing else.

    It is driven through the two lanes that audit-lane-shape actually SHAPE-JUDGES - map at batch 5
    and price at batch 10 - because a lane log with no map and no price line would pass that audit by
    having nothing in it, which is the could-not-look-is-not-a-clean-bill failure wearing a rosette.
    """
    run_dir = os.path.join(scratch, "daemon-fresh")
    os.makedirs(run_dir, exist_ok=True)
    rc, out, err = hunt_lib.ps_invoke(os.path.join(HERE, "hunt-run.ps1"),
                                      ["-Init", "-RunDir", run_dir, "-Conditions", "drain drill",
                                       "-Stop", "3 accepted", "-WaveSize", "3"])
    if rc != 0:
        return 2, "", "could not init the fresh run dir: %s" % (out + err)[:200]

    slugs = ["drill-alpha", "drill-beta", "drill-gamma"]
    terms = ["drill term one", "drill term two", "drill term three", "drill term four"]
    for s in slugs:
        for to in ("sourced", "selected", "extracted"):
            args = ["-Advance", "-RunDir", run_dir, "-Slug", s, "-To", to, "-By", "drill",
                    "-Detail", "drain drill"]
            if to == "sourced":
                args += ["-Title", s, "-SourceUrl", "https://d/%s" % s, "-Protein", "beef"]
            hunt_lib.ps_invoke(os.path.join(HERE, "hunt-run.ps1"), args)
    # EXTRACTION FILES, because D7 put map-preresolve in front of the mapper dispatch and it exits 2
    # BLOCKED on a slug with no extraction. Before these were written this drill went VACUOUS after
    # D7: the map batch blocked, ZERO lane lines were written, and audit-lane-shape passed on an
    # empty log - the exact could-not-look-wearing-a-rosette failure this function's own docstring
    # warns about. The drill terms are not in the closed vocabulary, so the REAL pre-resolver reads
    # them as residual (exit 1, the normal case) and the dispatch proceeds - which is also a live run
    # of D7's mechanical pass inside this drill, for free.
    os.makedirs(os.path.join(run_dir, "extracted"), exist_ok=True)
    for i, s in enumerate(slugs):
        with open(os.path.join(run_dir, "extracted", "%s.json" % s), "w", encoding="utf-8") as fh:
            json.dump({"state": "ok", "title": s, "source_url": "https://d/%s" % s, "servings": 4,
                       "time_total": "30 minutes", "time_active": "10 minutes",
                       "ingredients": [{"raw": "1 cup %s" % terms[i], "item": terms[i],
                                        "qty": "1", "unit": "cup", "prep": None,
                                        "optional": False, "section": None},
                                       {"raw": "1 tsp %s" % terms[3], "item": terms[3],
                                        "qty": "1", "unit": "tsp", "prep": None,
                                        "optional": False, "section": None}],
                       "instructions": ["Combine.", "Simmer.", "Portion."],
                       "concerns": []}, fh)

    # A mapper that reports one micro-batch of three, each with absent terms, and a pricer that
    # drains those terms in ONE batch across recipes - the shape the audit exists to enforce.
    class FreshStand(object):
        def __init__(self):
            self.calls = []

        def __call__(self, agent, prompt, schema=None, validator=None, **kw):
            self.calls.append(agent)
            r = HD.hunt_dispatch.DispatchResult(agent)
            r.tokens_in, r.tokens_out = 15470, 224
            if agent == "recipe-ingredient-mapper":
                r.payload = {"results": [{"slug": s, "status": "ok", "state": "pricing",
                                          "absent_terms": [terms[i], terms[3]],
                                          "optional_absent": []}
                                         for i, s in enumerate(slugs)]}
            else:
                r.payload = {}
            return r

    d = HD.Daemon(run_dir, "daemon-fresh", dispatcher=FreshStand(), quiet=True,
                  ledger_path=os.path.join(scratch, "fresh-ledger.json"),
                  ps=queue_redirected_ps(os.path.join(scratch, "fresh-queue.json")))
    for s in slugs:
        d.ch["map"].push({"slug": s})
    d.ch["map"].close()
    await d.run(("map", "price"))
    # VACUITY IS A FAILURE, NOT A PASS. An empty lane log satisfies audit-lane-shape by having
    # nothing in it, and this function exists precisely because that is not a clean bill. Post-D7 the
    # honest floor is 4 lines: one start/end pair for the map micro-batch and one for the price batch.
    if d.lane_lines < 4:
        return 2, "", ("VACUOUS: only %d lane-log line(s) were written - the lanes never actually "
                       "ran, so the audit below would be judging an empty log" % d.lane_lines)
    rc, out, _e = hunt_lib.ps_invoke(AUDIT_LANE_SHAPE_PS, ["-RunDir", run_dir], timeout=600)
    detail = ("3 recipes through map (one micro-batch) and their %d distinct terms through price "
              "(one batch); %d lane-log line(s)" % (len(terms), d.lane_lines))
    return rc, out, detail


def main(argv=None):
    ap = argparse.ArgumentParser(description="the section 4.2 drain-mode drill")
    ap.add_argument("--source", default=SOURCE_RUN)
    ap.add_argument("--keep", action="store_true", help="keep the working copy for inspection")
    a = ap.parse_args(argv)
    rc, rec = asyncio.new_event_loop().run_until_complete(drill(a.source, a.keep))
    say("")
    exp = (rec.get("expected_findings") or {}).get("findings") or []
    if exp:
        say("drain drill: %d expected finding(s), from a stub this drill declared:" % len(exp))
        for f in exp:
            say("  " + f)
        say("  why: %s" % rec["expected_findings"]["why"])
        say("")
    if rec["findings"]:
        say("drain drill: %d finding(s)" % len(rec["findings"]))
        for f in rec["findings"]:
            say("  " + f)
    else:
        say("drain drill: CLEAN")
    say("DRAIN-DRILL-COMPLETE")
    return rc


if __name__ == "__main__":
    sys.exit(main())
