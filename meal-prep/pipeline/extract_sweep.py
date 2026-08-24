"""extract_sweep.py - the pre-extraction sweep (PLAN-recipe-hunter-v3, the phase-2 bridge).

    python meal-prep/pipeline/extract_sweep.py --run-dir meal-prep/runs/<run> --jobs 4
    python meal-prep/pipeline/extract_sweep.py --from-pool 46 --out-dir meal-prep/out/extract-gate
    python meal-prep/pipeline/extract_sweep.py --selftest

WHAT THIS IS. Until the daemon exists (D9), rungs 1 and 2 of the extraction ladder run as a
script pass on the box, and the Workflow's extract lane is dispatched only for the escalations
this sweep leaves behind. It reads `source_url` from each accepted slug's state file, pulls the
page FROM THE FETCH CACHE ONLY, runs local_extract's ladder, writes the section 4.5 contract to
`<RunDir>\\extracted\\<slug>.json`, and writes the lane-log line per settle. The sweep can shell,
so section 4.5's lane-log completeness rule is its job until the daemon takes it: a page settled
locally is WORK DONE, not work skipped, and the lane log is the only record of a run's shape.

CACHE ONLY, DELIBERATELY. This driver never fetches. 2,293 pages sit in the harvester's cache
against a politeness budget already spent; a sweep that re-fetches would spend it twice and would
also make the extraction of a page depend on a publisher being up on the day. A target whose page
is not cached is recorded as could-not-run and the sweep exits 2 - blocked, never a clean bill.

CONCURRENCY (section 4.3's local-27B row, and the measurement is in this file's report). Rung-1
line splits are short calls and fan across the server's slots: one ThreadPoolExecutor at
jobs <= serve.ps1 -Slots, shared by the whole sweep so no slot idles at a page boundary. Rung 2
sends a whole page and needs a slot context serve.ps1's 4-slot default does not give it, so it
runs one page at a time and refuses rather than truncating - see local_extract.RUNG2_MIN_SLOT_CTX.

EXIT CODES (section 4.5): 0 every target settled, 1 findings (escalations to the Claude
extractor), 2 could-not-run (server down, no cached page, rung 2 blocked). Marker:
EXTRACT-SWEEP-COMPLETE.

INTERPRETER: C:\\Codex\\Python312\\python.exe. Bare `python` is the Windows Store shim.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
REPO = os.path.dirname(MP)
sys.path.insert(0, HERE)

import harvest                                                  # noqa: E402
import hunt_lib                                                 # noqa: E402
import local_extract                                            # noqa: E402
from llm import LocalLLM                                        # noqa: E402

HUNT_RUN_PS = os.path.join(HERE, "hunt-run.ps1")
DEFAULT_OUT = os.path.join(MP, "out", "extract-gate")

# The states whose next lane is extraction (section 4.5's resume seed table).
EXTRACTABLE = ("sourced", "selected")


def say(msg):
    print(msg)
    sys.stdout.flush()


# =====================================================================================================
# Targets
# =====================================================================================================

def run_dir_targets(run_dir, slugs=None):
    """Every slug the run has advanced to a state whose next lane is extraction."""
    state_dir = os.path.join(run_dir, "state")
    if not os.path.isdir(state_dir):
        return None, "no state directory at %s" % state_dir
    out = []
    for fn in sorted(os.listdir(state_dir)):
        if not fn.endswith(".json"):
            continue
        with open(os.path.join(state_dir, fn), "r", encoding="utf-8-sig") as fh:
            st = json.load(fh)
        if slugs and st.get("slug") not in slugs:
            continue
        if not slugs and st.get("state") not in EXTRACTABLE:
            continue
        out.append({"slug": st.get("slug"), "url": st.get("source_url"),
                    "title": st.get("title"), "domain": harvest.domain_of(st.get("source_url") or ""),
                    "dest": os.path.join(run_dir, "extracted"), "run_dir": run_dir,
                    "from": "run-state"})
    return out, None


def pool_targets(count, out_dir, per_domain=0, band_verified=True, exclude=()):
    """Gate corpus from the backlog: available candidates, ranked, spread across publishers.

    Round-robin by domain rather than top-N, because a top-N of a ranked pool is one publisher's
    day and a settle rate measured on one publisher's HTML is not a settle rate.
    """
    pool = harvest.read_pool()
    avail = [c for c in pool["candidates"]
             if c.get("status") == "available"
             and (not band_verified or (c.get("band") or {}).get("verified"))
             and c.get("slug") not in exclude]
    by_domain = {}
    for c in avail:
        by_domain.setdefault(c.get("domain"), []).append(c)
    order = sorted(by_domain)
    picked, i = [], 0
    while len(picked) < count and any(by_domain[d] for d in order):
        d = order[i % len(order)]
        i += 1
        bucket = by_domain[d]
        if not bucket:
            continue
        if per_domain and sum(1 for p in picked if p["domain"] == d) >= per_domain:
            bucket.clear()
            continue
        c = bucket.pop(0)
        picked.append({"slug": c.get("slug"), "url": c.get("url"), "title": c.get("name"),
                       "domain": c.get("domain"), "dest": out_dir, "run_dir": None,
                       "from": "pool"})
    return picked


def report_targets(report_path, run_dir="", out_dir=DEFAULT_OUT):
    """The pages a PRIOR sweep escalated, rebuilt as targets.

    This exists because of the slots/context split (section 4.3): rung 1 fans across four slots and
    rung 2 needs a server restarted narrow, so the two rungs are two passes on two server shapes.
    Without this, pass 2 would have to re-pop the same corpus and re-run rung 1 on every page that
    already settled - forty minutes of GPU to re-earn an answer sitting on disk.
    """
    if not os.path.exists(report_path):
        return None, "no sweep report at %s" % report_path
    with open(report_path, "r", encoding="utf-8-sig") as fh:
        rep = json.load(fh)
    out = []
    for r in rep.get("pages_detail") or []:
        if r.get("settled") or r.get("blocked"):
            continue
        from_run = r.get("from") == "run-state"
        out.append({"slug": r.get("slug"), "url": r.get("url"), "title": r.get("title"),
                    "domain": r.get("domain"),
                    "dest": os.path.join(run_dir, "extracted") if from_run else out_dir,
                    "run_dir": run_dir if from_run else None,
                    "from": r.get("from")})
    return out, None


# =====================================================================================================
# The ladder
# =====================================================================================================

class Ladder:
    """Rung 1 then rung 2, over one cached page. Injected in the fixtures."""

    def __init__(self, pool=None, jobs=4, allow_rung2=True):
        self.pool = pool
        self.jobs = jobs
        self.allow_rung2 = allow_rung2
        self.split_llm = LocalLLM(timeout=180)
        self.page_llm = LocalLLM(timeout=600)
        self._slot_ctx = None

    def slot_ctx(self):
        if self._slot_ctx is None:
            self._slot_ctx = local_extract.slot_context(self.page_llm) or 0
        return self._slot_ctx

    def rung1(self, html, url):
        return local_extract.extract_from_jsonld(html, url, self.split_llm, pool=self.pool)

    def rung2(self, html, url):
        ctx = self.slot_ctx()
        if ctx and ctx < local_extract.RUNG2_MIN_SLOT_CTX:
            return None, ("rung 2 BLOCKED: this server gives each slot %d tokens and a full-page "
                          "transcription needs ~%d. Restart narrow (serve.ps1 -Slots 1) and re-run; "
                          "truncating the page instead would substring-verify cleanly with "
                          "ingredients silently missing."
                          % (ctx, local_extract.RUNG2_MIN_SLOT_CTX))
        return local_extract.extract(local_extract.page_text_from_html(html), url,
                                     self.page_llm), None


def sweep_one(target, ladder, cache_dir=None):
    """One page through the ladder. Returns the record; writes nothing."""
    rec = {"slug": target["slug"], "domain": target.get("domain"), "url": target.get("url"),
           "title": target.get("title"), "from": target.get("from"),
           "rung": None, "settled": False, "blocked": False,
           "lines": 0, "unverified": 0, "seconds": 0.0, "reason": None, "contract": None}
    t0 = time.time()
    if not target.get("url"):
        rec["blocked"] = True
        rec["reason"] = "the state file carries no source_url"
        return rec
    html = harvest.cached_body(target["url"], cache_dir or harvest.PAGE_CACHE)
    if html is None:
        rec["blocked"] = True
        rec["reason"] = ("no cached page for %s - this sweep never fetches (the politeness budget "
                         "was spent once already)" % target["url"])
        return rec

    out = ladder.rung1(html, target["url"])
    rec["rung"] = 1
    if not out["escalate"]:
        rec.update(settled=True, lines=out["verification"]["lines"],
                   contract=local_extract.to_contract(out, target["url"], target.get("title")),
                   seconds=round(time.time() - t0, 2))
        return rec
    rung1_reason = out["escalate_reason"]
    rec["unverified"] = out["verification"]["unverified"]

    if not ladder.allow_rung2:
        rec["reason"] = rung1_reason
        rec["contract"] = local_extract.to_contract(out, target["url"], target.get("title"))
        rec["seconds"] = round(time.time() - t0, 2)
        return rec

    out2, blocked = ladder.rung2(html, target["url"])
    if blocked:
        rec["blocked"] = True
        rec["reason"] = blocked
        rec["seconds"] = round(time.time() - t0, 2)
        return rec
    rec["rung"] = 2
    rec["lines"] = out2["verification"]["lines"]
    rec["unverified"] = out2["verification"]["unverified"]
    rec["contract"] = local_extract.to_contract(out2, target["url"], target.get("title"))
    rec["settled"] = not out2["escalate"]
    if not rec["settled"]:
        rec["reason"] = "rung 1: %s | rung 2: %s" % (rung1_reason, out2["escalate_reason"])
    rec["seconds"] = round(time.time() - t0, 2)
    return rec


def write_record(rec, dest_dir):
    """A SETTLED page becomes `<slug>.json` - the section 4.5 extraction contract, and the only
    file downstream reads. An escalation becomes `<slug>.escalation.json` instead, carrying the
    failure reason and the unverified lines the Claude extractor's dispatch needs (S3: it must not
    re-run the local pass to re-earn a failure the dispatch already holds). The two names are
    deliberately different files: a half-settled extraction sitting under the settled name is how a
    run publishes a recipe nothing verified."""
    os.makedirs(dest_dir, exist_ok=True)
    settled_path = os.path.join(dest_dir, "%s.json" % rec["slug"])
    esc_path = os.path.join(dest_dir, "%s.escalation.json" % rec["slug"])

    # THE CLEANUP RUNS ONE WAY ONLY, and the asymmetry is the whole point.
    #
    # Settling CLEARS an earlier escalation: a page rung 2 transcribed must not leave rung 1's
    # escalation lying next to it, or the extract lane dispatches a Claude extractor for a page that
    # is already done, and a stale escalation is indistinguishable from a live one.
    #
    # Escalating does NOT clear an earlier SETTLE. Found the hard way 2026-08-23: the round-2
    # rung-1-only pass re-ran a page that round 1 had settled at rung 2, escalated it (rung 2 was
    # switched off, so of course it did), and deleted a verified extraction to put a failure in its
    # place. A verified transcription is not made wrong by a later, cheaper pass not reaching it.
    if not rec["settled"] and os.path.exists(settled_path):
        rec["already_settled"] = True
        return settled_path
    path = settled_path if rec["settled"] else esc_path
    stale = esc_path if rec["settled"] else None
    if stale and os.path.exists(stale):
        os.remove(stale)
    doc = dict(rec["contract"] or {})
    if not rec["settled"]:
        doc["escalate"] = True
        doc["escalate_reason"] = rec["reason"]
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2, ensure_ascii=False)
    return path


def lane_log(run_dir, slug, rung, seconds, ps=None):
    """Section 4.5's lane-log completeness rule: EVERY settle gets a line, including a local one.
    `-By local`, tokens 0 - it cost the run no Claude tokens, which is the point, and a lane with
    no lines reads afterwards as a run that never extracted anything."""
    call = ps or hunt_lib.ps_invoke
    rc, out, err = call(HUNT_RUN_PS, [
        "-Lane", "-RunDir", run_dir, "-LaneName", "extract",
        "-Label", "local rung %d (%.1fs)" % (rung, seconds),
        "-Items", [slug], "-By", "local", "-InputTokens", 0, "-OutputTokens", 0], timeout=120)
    return rc, (out or "") + (err or "")


def advance(run_dir, slug, rung, ps=None):
    call = ps or hunt_lib.ps_invoke
    rc, out, err = call(HUNT_RUN_PS, [
        "-Advance", "-RunDir", run_dir, "-Slug", slug, "-To", "extracted", "-By", "local",
        "-Detail", "extraction ladder rung %d, every line verified" % rung], timeout=120)
    return rc, (out or "") + (err or "")


# =====================================================================================================
# The sweep
# =====================================================================================================

def run_sweep(targets, ladder, cache_dir=None, do_lane_log=True, do_advance=False, ps=None,
              quiet=False):
    records = []
    t0 = time.time()
    for n, t in enumerate(targets, 1):
        rec = sweep_one(t, ladder, cache_dir)
        if rec["contract"] is not None:
            rec["path"] = write_record(rec, t["dest"])
        if rec["settled"] and t.get("run_dir"):
            if do_lane_log:
                rc, blob = lane_log(t["run_dir"], rec["slug"], rec["rung"], rec["seconds"], ps)
                rec["lane_logged"] = (rc == 0)
                if rc != 0:
                    rec["lane_log_error"] = blob[:300]
            if do_advance:
                rc, blob = advance(t["run_dir"], rec["slug"], rec["rung"], ps)
                rec["advanced"] = (rc == 0)
                if rc != 0:
                    rec["advance_error"] = blob[:300]
        records.append(rec)
        if not quiet:
            mark = ("settled rung %d" % rec["rung"]) if rec["settled"] else (
                "BLOCKED" if rec["blocked"] else "escalate -> Claude")
            say("  [%3d/%3d] %-46s %-22s %5.1fs  %s"
                % (n, len(targets), rec["slug"][:46], mark, rec["seconds"], rec["domain"] or ""))
    return records, round(time.time() - t0, 1)


def report(records, wall, jobs, slot_ctx=None):
    settled = [r for r in records if r["settled"]]
    r1 = [r for r in settled if r["rung"] == 1]
    r2 = [r for r in settled if r["rung"] == 2]
    esc = [r for r in records if not r["settled"] and not r["blocked"]]
    blocked = [r for r in records if r["blocked"]]
    timed = [r["seconds"] for r in records if not r["blocked"]]
    n = len(records)
    return {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "pages": n,
        "jobs": jobs,
        "slot_context": slot_ctx,
        "rung1_settled": len(r1),
        "rung2_settled": len(r2),
        "escalated_to_claude": len(esc),
        "blocked": len(blocked),
        "rung1_settle_rate": round(len(r1) / n, 4) if n else 0.0,
        "settle_rate": round(len(settled) / n, 4) if n else 0.0,
        "escalation_rate": round(len(esc) / n, 4) if n else 0.0,
        "unverified_lines_in_settled": sum(r["unverified"] for r in settled),
        "seconds_per_page_mean": round(statistics.mean(timed), 2) if timed else None,
        "seconds_per_page_median": round(statistics.median(timed), 2) if timed else None,
        "wall_clock_seconds": wall,
        "by_domain": _by_domain(records),
        "pages_detail": [{k: v for k, v in r.items() if k != "contract"} for r in records],
    }


def _by_domain(records):
    out = {}
    for r in records:
        d = out.setdefault(r["domain"] or "?", {"pages": 0, "settled": 0, "escalated": 0,
                                                "blocked": 0})
        d["pages"] += 1
        if r["settled"]:
            d["settled"] += 1
        elif r["blocked"]:
            d["blocked"] += 1
        else:
            d["escalated"] += 1
    return out


def print_report(rep):
    say("")
    say("extract sweep: %d page(s), jobs=%d, per-slot context %s"
        % (rep["pages"], rep["jobs"], rep["slot_context"] or "unknown"))
    say("  settled rung 1 (JSON-LD + verified line split) : %d  (%.0f%%)"
        % (rep["rung1_settled"], 100 * rep["rung1_settle_rate"]))
    say("  settled rung 2 (full-page transcription)       : %d" % rep["rung2_settled"])
    say("  escalated to the Claude extractor (rung 3)     : %d  (%.0f%%)"
        % (rep["escalated_to_claude"], 100 * rep["escalation_rate"]))
    say("  BLOCKED (could-not-run, never a pass)          : %d" % rep["blocked"])
    say("  unverified lines inside a SETTLED extraction   : %d" % rep["unverified_lines_in_settled"])
    say("  wall clock %.1fs   mean %.1fs/page   median %.1fs/page"
        % (rep["wall_clock_seconds"], rep["seconds_per_page_mean"] or 0,
           rep["seconds_per_page_median"] or 0))
    say("  by publisher:")
    for d in sorted(rep["by_domain"]):
        v = rep["by_domain"][d]
        say("    %-24s %3d pages   %3d settled   %3d escalated   %3d blocked"
            % (d, v["pages"], v["settled"], v["escalated"], v["blocked"]))


def main(argv=None):
    ap = argparse.ArgumentParser(description="Pre-extraction sweep: the ladder over cached pages")
    ap.add_argument("--run-dir", dest="run_dir", default="")
    ap.add_argument("--slugs", default="", help="comma-separated; default is every extractable slug")
    ap.add_argument("--from-pool", dest="from_pool", type=int, default=0,
                    help="add N available candidates from the backlog, spread across publishers")
    ap.add_argument("--per-domain", dest="per_domain", type=int, default=0)
    ap.add_argument("--from-report", dest="from_report", default="",
                    help="re-run ONLY the pages a prior sweep report escalated (the narrow rung-2 pass)")
    ap.add_argument("--out-dir", dest="out_dir", default=DEFAULT_OUT)
    ap.add_argument("--jobs", type=int, default=4, help="coupled to serve.ps1 -Slots")
    ap.add_argument("--no-rung2", dest="no_rung2", action="store_true",
                    help="rung 1 only (rung 2 needs a narrow server; see the header)")
    ap.add_argument("--advance", action="store_true",
                    help="advance a settled run-dir slug to `extracted` through hunt-run.ps1")
    ap.add_argument("--no-lane-log", dest="no_lane_log", action="store_true")
    ap.add_argument("--report", default="")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)

    if a.selftest:
        return selftest()

    targets = []
    if a.from_report:
        found, err = report_targets(a.from_report, a.run_dir, a.out_dir)
        if err:
            say("extract sweep: BLOCKED - %s" % err)
            say("EXTRACT-SWEEP-COMPLETE")
            return hunt_lib.EXIT_CANNOT_RUN
        targets.extend(found)
    elif a.run_dir:
        slugs = set(x.strip() for x in a.slugs.split(",") if x.strip())
        found, err = run_dir_targets(a.run_dir, slugs or None)
        if err:
            say("extract sweep: BLOCKED - %s" % err)
            say("EXTRACT-SWEEP-COMPLETE")
            return hunt_lib.EXIT_CANNOT_RUN
        targets.extend(found)
    if a.from_pool and not a.from_report:
        have = set(t["slug"] for t in targets)
        targets.extend(pool_targets(a.from_pool, a.out_dir, a.per_domain, exclude=have))
    if a.limit:
        targets = targets[:a.limit]
    if not targets:
        say("extract sweep: BLOCKED - no targets. Pass --run-dir and/or --from-pool N.")
        say("EXTRACT-SWEEP-COMPLETE")
        return hunt_lib.EXIT_CANNOT_RUN

    llm = LocalLLM(timeout=60)
    if not llm.health():
        say(local_extract.SERVER_DOWN % llm.endpoint)
        say("  Nothing was swept. %d target(s) are untouched." % len(targets))
        say("EXTRACT-SWEEP-COMPLETE")
        return hunt_lib.EXIT_CANNOT_RUN

    from concurrent.futures import ThreadPoolExecutor             # noqa: PLC0415
    jobs = max(1, int(a.jobs))
    say("extract sweep: %d target(s), rung-1 line splits fanned across %d slot(s)"
        % (len(targets), jobs))
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        ladder = Ladder(pool=pool, jobs=jobs, allow_rung2=not a.no_rung2)
        ctx = ladder.slot_ctx()
        say("  llama-server reports %s tokens per slot; rung 2 needs ~%d"
            % (ctx or "an unknown number of", local_extract.RUNG2_MIN_SLOT_CTX))
        records, wall = run_sweep(targets, ladder, do_lane_log=not a.no_lane_log,
                                  do_advance=a.advance)
    rep = report(records, wall, jobs, ladder.slot_ctx())
    print_report(rep)

    if a.report:
        path = a.report
    elif a.run_dir:
        path = os.path.join(a.run_dir, "extracted", "sweep-report.json")
    else:
        path = os.path.join(a.out_dir, "sweep-report.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(rep, fh, indent=2, ensure_ascii=False)
    say("  report -> %s" % path)
    say("EXTRACT-SWEEP-COMPLETE")
    if rep["blocked"]:
        return hunt_lib.EXIT_CANNOT_RUN
    return hunt_lib.EXIT_FINDINGS if rep["escalated_to_claude"] else hunt_lib.EXIT_CLEAN


# =====================================================================================================
# FIXTURES. No GPU: the ladder is injected. What is under test is the DRIVER - what it writes,
# what it logs, and what it refuses.
# =====================================================================================================

class FakeLadder:
    def __init__(self, plan, allow_rung2=True):
        self.plan = plan            # slug -> ("settle1" | "settle2" | "escalate" | "block")
        self.allow_rung2 = allow_rung2
        self.calls = []

    def _out(self, settled, rung, lines=2):
        ings = [{"raw": "1 lb chicken thighs", "item": "chicken thighs", "qty": "1", "unit": "lb",
                 "prep": None, "optional": False, "section": None},
                {"raw": "2 cups rice", "item": "rice", "qty": "2", "unit": "cups", "prep": None,
                 "optional": False, "section": None}]
        bad = 0 if settled else 1
        return {"extraction": {"usable": True, "unusable_reason": None, "title": "T",
                               "servings": 4, "total_time": "45 minutes", "active_time": None,
                               "ingredients": ings, "instructions": ["Cook."]},
                "verification": {"lines": lines, "verified": lines - bad, "unverified": bad,
                                 "verified_rate": 1.0 if settled else 0.5,
                                 "unverified_lines": [] if settled else ["2 cups rice"],
                                 "passed": settled},
                "model": "fake", "tokens": 0, "rung": rung,
                "extracted_by": "jsonld-local" if rung == 1 else "local-page",
                "escalate": not settled,
                "escalate_reason": None if settled else "a line failed the split check"}

    def slot_ctx(self):
        return 16384

    def rung1(self, html, url):
        self.calls.append(("rung1", url))
        want = self.plan.get(url, "settle1")
        return self._out(want == "settle1", 1)

    def rung2(self, html, url):
        self.calls.append(("rung2", url))
        want = self.plan.get(url, "settle1")
        if want == "block":
            return None, "rung 2 BLOCKED: slot context too small"
        return self._out(want == "settle2", 2), None


def selftest():
    import shutil                                                # noqa: PLC0415
    import subprocess                                            # noqa: PLC0415
    import tempfile                                              # noqa: PLC0415
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    td = tempfile.mkdtemp(prefix="sweep-test-")
    cache = os.path.join(td, "cache")
    os.makedirs(cache)
    dest = os.path.join(td, "extracted")

    def cache_page(url, body="<html>page</html>"):
        with open(os.path.join(cache, harvest.cache_key(url) + ".html"), "w",
                  encoding="utf-8") as fh:
            fh.write(body)

    u_ok = "https://example.com/settles"
    u_esc = "https://example.com/escalates"
    u_r2 = "https://example.com/rung2"
    u_missing = "https://example.com/never-fetched"
    for u in (u_ok, u_esc, u_r2):
        cache_page(u)

    def tgt(slug, url, run_dir=None):
        return {"slug": slug, "url": url, "title": slug, "domain": harvest.domain_of(url),
                "dest": dest, "run_dir": run_dir, "from": "test"}

    ladder = FakeLadder({u_ok: "settle1", u_esc: "escalate", u_r2: "settle2"})
    recs, _wall = run_sweep([tgt("settles", u_ok), tgt("escalates", u_esc), tgt("two", u_r2)],
                            ladder, cache_dir=cache, do_lane_log=False, quiet=True)

    T("a rung-1 settle writes <slug>.json (the section 4.5 contract)",
      os.path.exists(os.path.join(dest, "settles.json")), os.listdir(dest))
    doc = json.load(open(os.path.join(dest, "settles.json"), encoding="utf-8"))
    T("MUST FIRE  ZERO unverified lines are in a settled extraction",
      doc["verification"]["unverified"] == 0 and doc["state"] == "ok", json.dumps(doc)[:160])
    T("  and it is stamped with the rung that settled it",
      doc["extracted_by"] == "jsonld-local", str(doc.get("extracted_by")))
    T("MUST FIRE  an ESCALATION never lands under the settled name",
      not os.path.exists(os.path.join(dest, "escalates.json"))
      and os.path.exists(os.path.join(dest, "escalates.escalation.json")), os.listdir(dest))
    esc = json.load(open(os.path.join(dest, "escalates.escalation.json"), encoding="utf-8"))
    T("  and the escalation file carries the reason and the unverified line the dispatch needs",
      esc["escalate"] and esc["verification"]["unverified_lines"] == ["2 cups rice"],
      json.dumps(esc)[:200])
    T("rung 1 is tried BEFORE rung 2, and rung 2 only for what rung 1 could not settle",
      [c for c in ladder.calls] == [("rung1", u_ok), ("rung1", u_esc), ("rung2", u_esc),
                                    ("rung1", u_r2), ("rung2", u_r2)], str(ladder.calls))
    T("CLEAN TWIN a rung-2 settle is written and stamped local-page",
      json.load(open(os.path.join(dest, "two.json"),
                     encoding="utf-8"))["extracted_by"] == "local-page")

    # ---- an uncached page is could-not-run: this sweep NEVER fetches -----------------------------
    recs2, _ = run_sweep([tgt("missing", u_missing)], ladder, cache_dir=cache,
                         do_lane_log=False, quiet=True)
    T("MUST FIRE  an uncached page is BLOCKED, never fetched",
      recs2[0]["blocked"] and "never fetches" in recs2[0]["reason"], str(recs2[0]["reason"]))
    T("  and a blocked page writes no extraction at all",
      not os.path.exists(os.path.join(dest, "missing.json"))
      and not os.path.exists(os.path.join(dest, "missing.escalation.json")))
    rep = report(recs + recs2, 12.0, 4, 16384)
    T("MUST FIRE  a blocked page makes the sweep exit 2, never a clean bill",
      rep["blocked"] == 1, json.dumps(rep["by_domain"]))
    T("the report carries the gate's three numbers",
      rep["rung1_settle_rate"] == 0.25 and rep["escalation_rate"] == 0.25
      and rep["seconds_per_page_mean"] is not None, json.dumps(
          {k: rep[k] for k in ("rung1_settle_rate", "escalation_rate")}))

    # ---- the narrow rung-2 pass targets exactly what pass 1 escalated -----------------------------
    rep_path = os.path.join(td, "pass1.json")
    with open(rep_path, "w", encoding="utf-8") as fh:
        json.dump(rep, fh)
    again, err = report_targets(rep_path, out_dir=dest)
    T("--from-report targets exactly the pages a prior sweep escalated, and nothing it settled",
      err is None and [t["slug"] for t in again] == ["escalates"], str(err or [t["slug"] for t in again]))
    r2 = FakeLadder({u_esc: "settle2"})
    run_sweep(again, r2, cache_dir=cache, do_lane_log=False, quiet=True)
    T("MUST FIRE  a rung-2 settle CLEARS pass 1's escalation file, never leaves it beside the answer",
      os.path.exists(os.path.join(dest, "escalates.json"))
      and not os.path.exists(os.path.join(dest, "escalates.escalation.json")), os.listdir(dest))
    T("MUST FIRE  an escalating pass NEVER deletes an extraction an earlier rung settled",
      (lambda: (run_sweep([tgt("escalates", u_esc)],
                          FakeLadder({u_esc: "escalate"}, allow_rung2=False),
                          cache_dir=cache, do_lane_log=False, quiet=True),
                os.path.exists(os.path.join(dest, "escalates.json"))
                and not os.path.exists(os.path.join(dest, "escalates.escalation.json")))[1])(),
      os.listdir(dest))
    T("  a missing report is BLOCKED, not an empty pass",
      report_targets(os.path.join(td, "nope.json"))[1] is not None)

    # ---- rung 2 blocked by slot context is BLOCKED, not an escalation ----------------------------
    blocker = FakeLadder({u_r2: "block"})
    recs3, _ = run_sweep([tgt("blocked-rung2", u_r2)], blocker, cache_dir=cache,
                         do_lane_log=False, quiet=True)
    T("MUST FIRE  a rung-2 slot-context refusal is BLOCKED, never an escalation to Claude",
      recs3[0]["blocked"] and not recs3[0]["settled"]
      and "BLOCKED" in recs3[0]["reason"], str(recs3[0]["reason"]))

    # ---- rung-1-only mode still escalates rather than blocking -----------------------------------
    only1 = FakeLadder({u_esc: "escalate"}, allow_rung2=False)
    recs4, _ = run_sweep([tgt("r1only", u_esc)], only1, cache_dir=cache, do_lane_log=False,
                         quiet=True)
    T("CLEAN TWIN --no-rung2 leaves an unsettled page as an escalation, not a block",
      not recs4[0]["settled"] and not recs4[0]["blocked"] and ("rung2", u_esc) not in only1.calls,
      str(only1.calls))

    # ---- the lane-log line, against the REAL hunt-run.ps1 in a scratch run dir --------------------
    run_dir = os.path.join(td, "run-scratch")
    rc, out, err = hunt_lib.ps_invoke(HUNT_RUN_PS, ["-Init", "-RunDir", run_dir,
                                                    "-Conditions", "fixture", "-Stop", "fixture"],
                                      timeout=180)
    if rc != 0:
        T("DRILL     hunt-run -Init built a scratch run dir", False, (out or "") + (err or ""))
    else:
        ladder2 = FakeLadder({u_ok: "settle1"})
        run_sweep([tgt("settles", u_ok, run_dir=run_dir)], ladder2,
                  cache_dir=cache, do_lane_log=True, quiet=True)
        lp = os.path.join(run_dir, "lane-log.jsonl")
        rows = [json.loads(x) for x in open(lp, encoding="utf-8-sig").read().splitlines() if x.strip()] \
            if os.path.exists(lp) else []
        T("DRILL     every settle writes a lane-log line (section 4.5 completeness)",
          len(rows) == 1, str(rows))
        if rows:
            r = rows[0]
            T("DRILL     the line is lane=extract, by=local, tokens 0, naming the slug",
              r["lane"] == "extract" and r["by"] == "local" and r["in"] == 0 and r["out"] == 0
              and r["items"] == ["settles"], json.dumps(r))
        # an escalation is NOT a settle, and must not be logged as one
        run_sweep([tgt("escalates", u_esc, run_dir=run_dir)],
                  FakeLadder({u_esc: "escalate"}, allow_rung2=False),
                  cache_dir=cache, do_lane_log=True, quiet=True)
        rows2 = [json.loads(x) for x in open(lp, encoding="utf-8-sig").read().splitlines()
                 if x.strip()]
        T("MUST FIRE  an escalation writes NO local settle line - the Claude call is the work",
          len(rows2) == 1, str(len(rows2)))

    # ---- END-TO-END DRILL: a down server sweeps nothing and exits 2 -------------------------------
    env = dict(os.environ, TC_LLM_ENDPOINT="http://127.0.0.1:59117/v1")
    r = subprocess.run([sys.executable, os.path.abspath(__file__), "--run-dir", run_dir,
                        "--from-pool", "2", "--out-dir", os.path.join(td, "gate")],
                       capture_output=True, text=True, env=env, timeout=300)
    blob = (r.stdout or "") + (r.stderr or "")
    T("DRILL     a down llama-server exits 2 with nothing swept",
      r.returncode == 2 and not os.path.exists(os.path.join(td, "gate")), "exit %s" % r.returncode)
    T("DRILL     and it names llama-server rather than escalating the whole corpus to Claude",
      "llama-server" in blob and "NOT an escalation" in blob, blob[:240])
    T("DRILL     the completion marker is printed even when blocked",
      "EXTRACT-SWEEP-COMPLETE" in blob, blob[-120:])

    shutil.rmtree(td, ignore_errors=True)
    print("")
    if bad:
        print("extract_sweep selftest: %d FAILED - %s" % (len(bad), "; ".join(bad[:4])))
        print("EXTRACT-SWEEP-COMPLETE")
        return 1
    print("extract_sweep selftest: all green")
    print("EXTRACT-SWEEP-COMPLETE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
