"""
decide_apply.py - the deterministic writer for a DECIDE verdict (PLAN-recipe-hunter-v3 S2 / D5).

THE CHANGE THIS FILE IS. In v2 the decider was the sole author of acceptances AND held the pen: its
dispatch told it, in prose, to run `hunt-run.ps1 -Advance` twice per candidate, `considered-dishes.ps1
-Record` once per candidate, and to append to accepted-slugs.json itself. Three consequences, all
dated and all real:
  * 44 rejections on 2026-08-15 left no trace outside the run dir, because a prose instruction to
    record a ruling is a request, not a contract, and the next run re-sourced every one of them.
  * agent-side argument marshalling produced the B8 class - `-Terms 'a,b'` bound as ONE composite
    string, parking recipes forever. A JSON array cannot be comma-joined by accident.
  * every state advance cost part of a frontier context window to type a shell line correctly.

In v3 the decider AUTHORS and this file WRITES (section S2: authorship vs pen). The agent returns a
schema'd verdict; every state advance, ledger record, pool ruling and accepted-slugs append happens
here, attributed `-By decider`. The agent stops running shell entirely.

VALIDATE EVERYTHING, THEN APPLY. A payload that does not conform to hunt_lib.DECIDE is could-not-run
(exit 2) and NOTHING is written - half a verdict on disk is worse than none, because the half that
landed looks decided. The pre-flight also refuses a slug the pool has never heard of: a ruling on a
candidate nobody harvested is a ruling about nothing, and writing it would put a phantom in the ledger.

  python decide_apply.py --verdict <file> --run-dir <dir> --run <id> [--pool p] [--store s] [--dry-run]
  python decide_apply.py --selftest

EXIT CODES (section 4.5): 0 clean / 1 findings / 2 could-not-run. Marker DECIDE-APPLY-COMPLETE.
INTERPRETER: C:\\Codex\\Python312\\python.exe.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import hunt_lib
import harvest

HUNT_RUN_PS = os.path.join(HERE, "hunt-run.ps1")
CONSIDERED_PS = os.path.join(HERE, "considered-dishes.ps1")


# ONE marshalling road for every PowerShell call this file makes. See hunt_lib.ps_invoke's header:
# `-File` cannot carry a multi-element [string[]] at all, which is the transport half of the B8 class.
run_ps = hunt_lib.ps_invoke


def current_state(run_dir, slug):
    p = os.path.join(run_dir, "state", slug + ".json")
    if not os.path.exists(p):
        return None
    try:
        with open(p, "r", encoding="utf-8-sig") as f:
            return (json.load(f) or {}).get("state")
    except Exception:
        return None


def append_accepted(run_dir, slugs):
    """The single write of accepted-slugs.json, done once for the whole batch.

    Read-modify-write through a temp file and os.replace, and de-duplicated on the way in: this file
    is what the run's downstream lanes count acceptances from, and a slug listed twice reads as two
    recipes accepted.
    """
    p = os.path.join(run_dir, "accepted-slugs.json")
    have = []
    if os.path.exists(p):
        try:
            with open(p, "r", encoding="utf-8-sig") as f:
                have = json.load(f) or []
        except Exception:
            have = []
    added = [s for s in slugs if s not in have]
    if not added:
        return have, []
    out = list(have) + added
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1)
    os.replace(tmp, p)
    return out, added


def apply_verdict(payload, run_dir, run_id, pool_path, store_path, dry_run=False, quiet=False):
    """Apply a validated DECIDE payload. Returns (applied, findings)."""
    def say(m):
        if not quiet:
            print(m, flush=True)

    pool = harvest.read_pool(pool_path)
    by_slug, _by_url = harvest.pool_index(pool)

    findings = []
    applied = []
    accepted = []

    # ---- pre-flight: every slug must be a candidate somebody actually harvested ------------------
    for d in payload["decisions"]:
        if d["slug"] not in by_slug:
            findings.append("%s: the pool has never heard of this slug - refusing to record a ruling "
                            "about a candidate nobody harvested" % d["slug"])
    if findings:
        return applied, findings

    for d in payload["decisions"]:
        slug = d["slug"]
        verdict = d["verdict"]
        cand = by_slug[slug]
        entry_state, final_state = hunt_lib.DECIDE_STATE_ROUTE[verdict]

        if dry_run:
            applied.append((slug, verdict, "dry-run"))
            continue

        # ---- 1. run state, only for the verdicts the state machine can honestly express ----------
        if entry_state:
            st = current_state(run_dir, slug)
            if st is None:
                # -Title / -SourceUrl / -Protein are settable ONLY at state-file creation - hunt-run
                # writes them in its -To sourced branch and no later -Advance can back-fill them, and
                # the WAVE MANIFEST is built from exactly these fields. The first build of this file
                # passed only -Detail, and the phase-1 mini-run's nine state files were created with
                # source_url/title/protein all empty (found on the 2026-08-23 cold read, repaired by
                # replaying the advances). The drill now asserts they are populated.
                sig = cand.get("signature") or {}
                rc, out, _e = run_ps(HUNT_RUN_PS, ["-Advance", "-RunDir", run_dir, "-Slug", slug,
                                                   "-To", entry_state, "-By", "harvest",
                                                   "-Detail", cand.get("url") or "",
                                                   "-Title", cand.get("name") or "",
                                                   "-SourceUrl", cand.get("url") or "",
                                                   "-Protein", sig.get("protein") or ""])
                if rc != 0:
                    findings.append("%s: could not enter %s (%s)" % (slug, entry_state, out.strip()))
                    continue
                st = entry_state
            if st != final_state:
                rc, out, _e = run_ps(HUNT_RUN_PS, ["-Advance", "-RunDir", run_dir, "-Slug", slug,
                                                   "-To", final_state, "-By", "decider",
                                                   "-Detail", d.get("reason") or ""])
                if rc != 0:
                    findings.append("%s: could not advance to %s (%s)" % (slug, final_state, out.strip()))
                    continue

        # ---- 2. the estate's memory, from the verdict's own record block, VERBATIM ----------------
        if hunt_lib.DECIDE_RECORDS_RULING[verdict]:
            rec = d["record"]
            args = ["-Record", "-Slug", slug, "-Name", rec["name"], "-Protein", rec["protein"],
                    "-Method", rec["method"], "-Verdict", rec["verdict"], "-Reason", rec["reason"],
                    "-Run", run_id, "-By", "decider"]
            if store_path:
                args += ["-Store", store_path]
            # Each dupe_of slug its OWN argument. The B8 class was a composite comma string bound as
            # one element; a JSON array marshalled element-by-element cannot re-create it.
            dupes = [x for x in (d.get("dupe_of") or []) if x]
            if dupes:
                args += ["-DupeOf", dupes]      # a LIST - ps_invoke makes it a real PS array
            rc, out, _e = run_ps(CONSIDERED_PS, args)
            if rc != 0:
                findings.append("%s: the ruling did not reach considered-dishes (%s)"
                                % (slug, out.strip()))

        # ---- 3. the pool ruling, through harvest.py's single-writer verb -------------------------
        rc = _mark_ruled(slug, verdict, d.get("reason") or "", pool_path)
        if rc != 0:
            findings.append("%s: the pool ruling did not land" % slug)

        if verdict == "accepted":
            accepted.append(slug)
        applied.append((slug, verdict, "applied"))

    # ---- 4. the single write of accepted-slugs.json ------------------------------------------------
    if accepted and not dry_run:
        _all, added = append_accepted(run_dir, accepted)
        say("  accepted-slugs.json += %d (%s)" % (len(added), ", ".join(added)))

    return applied, findings


def _mark_ruled(slug, verdict, reason, pool_path):
    """harvest.py is the pool's SOLE writer, so the ruling goes through its verb rather than through
    a second hand on the same file - even though this process could open it."""
    args = [sys.executable, os.path.join(HERE, "harvest.py"), "--mark-ruled", slug,
            "--verdict", verdict, "--reason", reason]
    if pool_path:
        args += ["--pool", pool_path]
    p = subprocess.run(args, capture_output=True)
    return p.returncode if p.returncode in (0, 1, 2) else 2


def flatten_workflow_verdicts(payload):
    """Accept hunt-pool-seed.js's OWN return shape, not just a bare DECIDE payload.

    The bridge workflow returns {runId, verdicts: [{batch, decisions, note}, ...]} - one DECIDE
    payload per batch. The first gate run made the operator merge those by hand with a throwaway
    one-liner, which is exactly the kind of undocumented glue step a future session re-invents
    wrong. So the merge lives here: a payload carrying `verdicts` is flattened into one
    {decisions, note}; a batch marked `stuck` contributes nothing (its candidates were never
    ruled - B5, a transport failure is not a verdict); validate_decide's duplicate-slug check
    still applies across the merged whole. A bare DECIDE payload passes through untouched.
    """
    if not isinstance(payload, dict) or "verdicts" not in payload:
        return payload
    decisions, notes = [], []
    for v in payload.get("verdicts") or []:
        if not isinstance(v, dict) or v.get("stuck"):
            continue
        decisions.extend(v.get("decisions") or [])
        if v.get("note"):
            notes.append(str(v["note"]))
    return {"decisions": decisions, "note": " || ".join(notes)}


def cmd_apply(a):
    if not a.verdict or not os.path.exists(a.verdict):
        print("decide_apply: CANNOT RUN - no verdict file at %s" % a.verdict)
        print("DECIDE-APPLY-COMPLETE")
        return hunt_lib.EXIT_CANNOT_RUN
    if not a.run_dir or not os.path.isdir(a.run_dir):
        print("decide_apply: CANNOT RUN - no run dir at %s" % a.run_dir)
        print("DECIDE-APPLY-COMPLETE")
        return hunt_lib.EXIT_CANNOT_RUN
    try:
        with open(a.verdict, "r", encoding="utf-8-sig") as f:
            payload = json.load(f)
    except Exception as e:
        print("decide_apply: CANNOT RUN - %s does not parse (%s)" % (a.verdict, e))
        print("DECIDE-APPLY-COMPLETE")
        return hunt_lib.EXIT_CANNOT_RUN
    payload = flatten_workflow_verdicts(payload)

    # The method enum comes from the LEDGER, not from a copy in this file. 'any' is the ledger's
    # wildcard and is always legal.
    ledger_methods, _unmapped = harvest.load_methods()
    problems = hunt_lib.validate_decide(payload, methods=set(ledger_methods) | {"any"})
    if problems:
        print("decide_apply: CANNOT RUN - the verdict does not conform to the DECIDE schema. "
              "NOTHING was written.")
        for p in problems:
            print("  " + p)
        print("DECIDE-APPLY-COMPLETE")
        return hunt_lib.EXIT_CANNOT_RUN

    applied, findings = apply_verdict(payload, a.run_dir, a.run or "unknown-run",
                                      a.pool or harvest.POOL, a.store, a.dry_run)
    counts = {}
    for _s, v, _how in applied:
        counts[v] = counts.get(v, 0) + 1
    print("decide_apply: %d decision(s) applied%s" % (len(applied), " (dry run)" if a.dry_run else ""))
    for v in sorted(counts):
        print("  %-18s %d" % (v, counts[v]))
    if payload.get("note"):
        print("  decider note: %s" % payload["note"])
    for f in findings:
        print("  FINDING  " + f)
    print("DECIDE-APPLY-COMPLETE")
    return hunt_lib.EXIT_FINDINGS if findings else hunt_lib.EXIT_CLEAN


# =====================================================================================================
# self-test - the schema fixtures are predicates; the apply is an END-TO-END DRILL against a scratch
# run dir, because the estate's own lesson (wave-preaudit, 2026-08-23) is that the defects which
# survive every pure-predicate fixture are the ones that only appear once results are COLLECTED.
# =====================================================================================================

def cmd_selftest(_a):
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    good = {"decisions": [
        {"slug": "a", "verdict": "accepted", "reason": "distinct", "dupe_of": [],
         "record": {"name": "A", "protein": "beef", "method": "skillet", "verdict": "accepted",
                    "reason": "distinct"}},
        {"slug": "b", "verdict": "rejected-dupe", "reason": "twin of a", "dupe_of": ["a"],
         "record": {"name": "B", "protein": "beef", "method": "skillet", "verdict": "rejected-dupe",
                    "reason": "twin of a"}}], "note": "ok"}
    T("CLEAN TWIN a conforming verdict validates", hunt_lib.validate_decide(good) == [],
      str(hunt_lib.validate_decide(good)))
    T("MUST FIRE  a decision with no record block is refused - that is how 44 rulings were lost",
      any("record" in p for p in hunt_lib.validate_decide(
          {"decisions": [{"slug": "a", "verdict": "accepted", "reason": "r"}]})), "accepted it")
    T("MUST FIRE  a verdict outside the enum is refused",
      any("not one of" in p for p in hunt_lib.validate_decide(
          {"decisions": [{"slug": "a", "verdict": "maybe", "reason": "r",
                          "record": {"name": "A", "protein": "beef", "method": "any",
                                     "verdict": "maybe", "reason": "r"}}]})), "accepted it")
    T("MUST FIRE  a ruling that disagrees with its own record block is refused",
      any("disagree" in p for p in hunt_lib.validate_decide(
          {"decisions": [{"slug": "a", "verdict": "accepted", "reason": "r",
                          "record": {"name": "A", "protein": "beef", "method": "any",
                                     "verdict": "rejected-dupe", "reason": "r"}}]})), "accepted it")
    T("MUST FIRE  the same slug ruled twice is refused",
      any("twice" in p for p in hunt_lib.validate_decide(
          {"decisions": [good["decisions"][0], good["decisions"][0]]})), "accepted it")
    T("MUST FIRE  an unexplained ruling is refused",
      any("no reason" in p for p in hunt_lib.validate_decide(
          {"decisions": [{"slug": "a", "verdict": "accepted", "reason": "",
                          "record": {"name": "A", "protein": "b", "method": "any",
                                     "verdict": "accepted", "reason": "x"}}]})), "accepted it")
    ledger_methods, _um = harvest.load_methods()
    allowed = set(ledger_methods) | {"any"}
    T("the ledger yields a non-empty method enum to check against (blind is not clean)",
      len(allowed) > 2, ",".join(sorted(allowed)))
    def rec(method="skillet", protein="beef"):
        return {"decisions": [{"slug": "a", "verdict": "accepted", "reason": "r",
                               "record": {"name": "A", "protein": protein, "method": method,
                                          "verdict": "accepted", "reason": "r"}}]}
    T("CLEAN TWIN a record using the ledger's own method and protein passes",
      hunt_lib.validate_decide(rec(), methods=allowed) == [],
      str(hunt_lib.validate_decide(rec(), methods=allowed)))
    T("MUST FIRE  an invented method is refused (`soup/stew` was really returned on 2026-08-23)",
      any("not one of the ledger" in p for p in hunt_lib.validate_decide(rec(method="soup/stew"),
                                                                        methods=allowed)),
      str(hunt_lib.validate_decide(rec(method="soup/stew"), methods=allowed)))
    T("MUST FIRE  a compound method like `skillet+salad` is refused",
      hunt_lib.validate_decide(rec(method="skillet+salad"), methods=allowed) != [], "accepted it")
    T("MUST FIRE  an invented protein is refused (`turkey/beef` was really returned)",
      any("closed enum" in p for p in hunt_lib.validate_decide(rec(protein="turkey/beef"),
                                                               methods=allowed)), "accepted it")
    T("MUST FIRE  `egg` is not a board protein",
      hunt_lib.validate_decide(rec(protein="egg"), methods=allowed) != [], "accepted it")
    T("CLEAN TWIN `any` is legal for both - it is the ledger's wildcard, not an invention",
      hunt_lib.validate_decide(rec(method="any", protein="any"), methods=allowed) == [],
      str(hunt_lib.validate_decide(rec(method="any", protein="any"), methods=allowed)))

    T("CLEAN TWIN a deferral needs no record block - there is no ruling to record",
      hunt_lib.validate_decide({"decisions": [{"slug": "a", "verdict": "deferred",
                                               "reason": "want more context"}]}) == [],
      str(hunt_lib.validate_decide({"decisions": [{"slug": "a", "verdict": "deferred",
                                                   "reason": "x"}]})))
    T("MUST FIRE  an empty decisions array is not a verdict",
      hunt_lib.validate_decide({"decisions": []}) != [], "accepted it")

    # ---- the workflow's own return shape is accepted directly -------------------------------------
    wf = {"runId": "r", "verdicts": [
        {"batch": 1, "decisions": [good["decisions"][0]], "note": "n1"},
        {"batch": 2, "stuck": True, "slugs": ["never-ruled"]},
        {"batch": 3, "decisions": [good["decisions"][1]], "note": "n2"}]}
    flat = flatten_workflow_verdicts(wf)
    T("MUST FIRE  hunt-pool-seed.js's {verdicts:[...]} output flattens to one DECIDE payload - no "
      "hand-merge step for the operator to re-invent",
      len(flat.get("decisions", [])) == 2 and flat.get("note") == "n1 || n2"
      and hunt_lib.validate_decide(flat) == [], json.dumps(flat)[:120])
    T("MUST FIRE  a STUCK batch contributes NOTHING - its candidates were never ruled (B5)",
      all(d["slug"] != "never-ruled" for d in flat["decisions"]), "stuck batch leaked")
    T("CLEAN TWIN a bare DECIDE payload passes through untouched",
      flatten_workflow_verdicts(good) is good, "was rewrapped")
    T("rejected-not-fit takes NO run state - it never entered the run",
      hunt_lib.DECIDE_STATE_ROUTE["rejected-not-fit"] == (None, None),
      str(hunt_lib.DECIDE_STATE_ROUTE["rejected-not-fit"]))
    T("MUST FIRE  deferred records no ruling and keeps the candidate available",
      hunt_lib.DECIDE_RECORDS_RULING["deferred"] is False, "it records one")

    # ---- THE MARSHALLING TRAP, PINNED (measured 2026-08-23; hunt_lib.ps_invoke's header) ----------
    # This is the transport half of the B8 class and it is invisible to every fixture over the payload:
    # the verdict can carry a perfect JSON array and STILL land on the ledger as one composite string,
    # because `powershell -File` cannot bind a multi-element [string[]] from argv at all. Both broken
    # shapes are frozen here so nobody "simplifies" ps_invoke back to -File.
    import tempfile as _tf
    _d = _tf.mkdtemp(prefix="ps-marshal-")
    try:
        _p = os.path.join(_d, "t.ps1")
        with open(_p, "w", encoding="utf-8") as f:
            f.write(chr(10).join([
                "param([string[]]$A=@())",
                "Write-Output ('{0}|{1}' -f @($A).Count, (@($A) -join '~'))",
                "exit 7", ""]))

        def _viaFile(args):
            r = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", _p]
                               + args, capture_output=True)
            return r.returncode, r.stdout.decode(errors="replace").strip()

        rc_a, out_a = _viaFile(["-A", "one", "two"])
        T("MUST FIRE  -File with two bare values binds ONE element and SILENTLY DROPS the rest",
          out_a.startswith("1|one"), out_a)
        rc_b, out_b = _viaFile(["-A", "one,two"])
        T("MUST FIRE  -File with a comma binds ONE composite string - this IS B8",
          out_b == "1|one,two", out_b)
        rc_c, out_c, _ec = hunt_lib.ps_invoke(_p, ["-A", ["one", "two,with,commas", "it's"]])
        T("CLEAN TWIN ps_invoke binds a real PowerShell array, commas and quotes and all",
          out_c.strip() == "3|one~two,with,commas~it's", out_c.strip())
        T("MUST FIRE  ps_invoke propagates the script's exit code, not powershell.exe's success",
          rc_c == 7 and rc_a == 7, "ps_invoke=%s file=%s" % (rc_c, rc_a))
        rc_d, out_d, _e = hunt_lib.ps_invoke(_p, ["-A", []])
        T("CLEAN TWIN an empty list stays an empty array rather than eating the next flag",
          out_d.strip() == "0|", out_d.strip())
    finally:
        shutil.rmtree(_d, ignore_errors=True)

    # ---- END-TO-END DRILL --------------------------------------------------------------------------
    tmp = tempfile.mkdtemp(prefix="decide-apply-drill-")
    try:
        run_dir = os.path.join(tmp, "run")
        pool_path = os.path.join(tmp, "candidate-pool.json")
        store_path = os.path.join(tmp, "considered-dishes.json")
        os.makedirs(run_dir, exist_ok=True)
        rc, out, _e = run_ps(HUNT_RUN_PS, ["-Init", "-RunDir", run_dir, "-Conditions",
                                           "drill", "-Stop", "2 accepted", "-WaveSize", "2"])
        T("the drill can init a scratch run dir", rc == 0, out.strip()[:160])

        pool = {"candidates": [
            harvest.new_entry("drill-accept", "Drill Accept", "https://d/accept", "d", "crawl"),
            harvest.new_entry("drill-dupe", "Drill Dupe", "https://d/dupe", "d", "crawl"),
            harvest.new_entry("drill-unfit", "Drill Unfit", "https://d/unfit", "d", "crawl"),
            harvest.new_entry("drill-defer", "Drill Defer", "https://d/defer", "d", "crawl")]}
        harvest.write_pool(pool, pool_path)

        payload = {"decisions": [
            {"slug": "drill-accept", "verdict": "accepted", "reason": "novel region", "dupe_of": [],
             "record": {"name": "Drill Accept", "protein": "beef", "method": "skillet",
                        "verdict": "accepted", "reason": "novel region"}},
            {"slug": "drill-dupe", "verdict": "rejected-dupe", "reason": "same dinner as drill-accept",
             "dupe_of": ["drill-accept", "some-live-slug"],
             "record": {"name": "Drill Dupe", "protein": "beef", "method": "skillet",
                        "verdict": "rejected-dupe", "reason": "same dinner as drill-accept"}},
            {"slug": "drill-unfit", "verdict": "rejected-not-fit", "reason": "not batch-scalable",
             "dupe_of": [],
             "record": {"name": "Drill Unfit", "protein": "pork", "method": "bake",
                        "verdict": "rejected-not-fit", "reason": "not batch-scalable"}},
            {"slug": "drill-defer", "verdict": "deferred", "reason": "want the next batch's context"}],
            "note": "drill"}
        applied, findings = apply_verdict(payload, run_dir, "drill-run", pool_path, store_path,
                                          quiet=True)
        T("the drill applied every decision", len(applied) == 4, str(applied))
        T("CLEAN TWIN a well-formed verdict produces no findings", findings == [], str(findings))

        T("MUST FIRE  the accepted slug reached `selected`",
          current_state(run_dir, "drill-accept") == "selected",
          str(current_state(run_dir, "drill-accept")))
        with open(os.path.join(run_dir, "state", "drill-accept.json"), encoding="utf-8-sig") as f:
            stf = json.load(f)
        T("MUST FIRE  the state file carries source_url/title at creation - the wave manifest is "
          "built from these and no later -Advance can back-fill them",
          stf.get("source_url") == "https://d/accept" and stf.get("title") == "Drill Accept",
          json.dumps({k: stf.get(k) for k in ("source_url", "title", "protein")}))
        T("MUST FIRE  the dupe reached `rejected-dupe`",
          current_state(run_dir, "drill-dupe") == "rejected-dupe",
          str(current_state(run_dir, "drill-dupe")))
        T("MUST FIRE  rejected-not-fit took NO run state - the state machine cannot say it honestly",
          current_state(run_dir, "drill-unfit") is None,
          str(current_state(run_dir, "drill-unfit")))
        T("MUST FIRE  a deferral took no run state either",
          current_state(run_dir, "drill-defer") is None,
          str(current_state(run_dir, "drill-defer")))

        with open(os.path.join(run_dir, "accepted-slugs.json"), "r", encoding="utf-8-sig") as f:
            acc = json.load(f)
        T("MUST FIRE  accepted-slugs.json holds exactly the accepted slug",
          acc == ["drill-accept"], str(acc))

        with open(store_path, "r", encoding="utf-8-sig") as f:
            ledger = json.load(f)
        rows = {r["slug"]: r for r in ledger.get("dishes", [])}
        T("MUST FIRE  three rulings reached considered-dishes and the deferral did not",
          set(rows) == {"drill-accept", "drill-dupe", "drill-unfit"}, ",".join(sorted(rows)))
        T("MUST FIRE  the ledger row is the verdict's record block, byte-for-byte",
          rows["drill-dupe"]["name"] == "Drill Dupe"
          and rows["drill-dupe"]["protein"] == "beef"
          and rows["drill-dupe"]["method"] == "skillet"
          and rows["drill-dupe"]["verdict"] == "rejected-dupe"
          and rows["drill-dupe"]["reason"] == "same dinner as drill-accept",
          json.dumps(rows["drill-dupe"]))
        T("the ruling is attributed to the decider, not to whoever held the pen",
          rows["drill-accept"].get("by") == "decider", str(rows["drill-accept"].get("by")))
        T("MUST FIRE  dupe_of arrives as DISTINCT terms, not one composite string (the B8 class)",
          list(rows["drill-dupe"].get("dupe_of") or []) == ["drill-accept", "some-live-slug"],
          json.dumps(rows["drill-dupe"].get("dupe_of")))

        after = {c["slug"]: c["status"] for c in harvest.read_pool(pool_path)["candidates"]}
        T("MUST FIRE  a ruled candidate is no longer available in the pool",
          after["drill-accept"] == "ruled:accepted" and after["drill-dupe"] == "ruled:rejected-dupe"
          and after["drill-unfit"] == "ruled:rejected-not-fit", json.dumps(after))
        T("MUST FIRE  a DEFERRED candidate goes back on the shelf, not into a grave",
          after["drill-defer"] == "available", after["drill-defer"])

        # re-applying the same verdict must not double-count the acceptance
        applied2, findings2 = apply_verdict(payload, run_dir, "drill-run", pool_path, store_path,
                                            quiet=True)
        with open(os.path.join(run_dir, "accepted-slugs.json"), "r", encoding="utf-8-sig") as f:
            acc2 = json.load(f)
        T("MUST FIRE  re-applying a verdict does not list the same acceptance twice",
          acc2 == ["drill-accept"], str(acc2))

        # a ruling about a candidate nobody harvested writes NOTHING
        phantom = {"decisions": [{"slug": "never-harvested", "verdict": "accepted", "reason": "r",
                                  "record": {"name": "N", "protein": "beef", "method": "any",
                                             "verdict": "accepted", "reason": "r"}}]}
        ap3, f3 = apply_verdict(phantom, run_dir, "drill-run", pool_path, store_path, quiet=True)
        T("MUST FIRE  a ruling on a slug the pool never held writes nothing and reports why",
          ap3 == [] and len(f3) == 1 and "never heard" in f3[0], str(f3))
        T("  and it left the accepted list untouched",
          json.load(open(os.path.join(run_dir, "accepted-slugs.json"), encoding="utf-8-sig"))
          == ["drill-accept"], "list changed")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("")
    if bad:
        print("decide_apply SELF-TEST FAIL (%d)" % len(bad))
        print("DECIDE-APPLY-COMPLETE")
        return hunt_lib.EXIT_CANNOT_RUN
    print("decide_apply SELF-TEST PASS")
    print("DECIDE-APPLY-COMPLETE")
    return hunt_lib.EXIT_CLEAN


def main(argv=None):
    ap = argparse.ArgumentParser(description="apply a DECIDE verdict")
    ap.add_argument("--verdict", default="")
    ap.add_argument("--run-dir", dest="run_dir", default="")
    ap.add_argument("--run", default="")
    ap.add_argument("--pool", default="")
    ap.add_argument("--store", default="")
    ap.add_argument("--dry-run", dest="dry_run", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return cmd_selftest(a)
    return cmd_apply(a)


if __name__ == "__main__":
    sys.exit(main())
