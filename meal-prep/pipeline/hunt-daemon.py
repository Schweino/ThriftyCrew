"""
hunt-daemon.py - the Recipe Hunter orchestrator, on the box (PLAN-recipe-hunter-v3 section 4.1, D9).

    C:\\Codex\\Python312\\python.exe hunt-daemon.py --run-dir <dir> --run <id> [--target N]
    C:\\Codex\\Python312\\python.exe hunt-daemon.py --run-dir <dir> --status
    C:\\Codex\\Python312\\python.exe hunt-daemon.py --selftest

WHAT THIS IS. Everything hunt-orchestrator.js does - lanes, queues, retries, the breaker, wave
sequencing - with three abilities the Workflow sandbox denies: mechanics are function calls, the
local LLM is a native client, and there is a real clock and a real resume.

THIS FILE IS A PORT, NOT A REWRITE, and that is the whole governance of it. Eleven of the twelve
orchestrator defects of 2026-08-15/16 came from re-deriving this logic from prose. So:
  * every pure decision lives in hunt_lib.py, ported decision-for-decision from hunt-lib.js and
    proven against SHARED test vectors that both implementations run (section 4.2's parity gate).
    This file CALLS those functions; it does not restate their rules;
  * the wave lane's control flow keeps runWave/trimWave's order and refusal conditions exactly, with
    the agent-as-shell steps inside it becoming direct calls and nothing else moving;
  * the extraction ladder is IMPORTED from extract_sweep, not re-derived - `run_sweep` with
    do_lane_log=False and do_advance=False, because the daemon holds the pen (the D9 pin).

WHAT CHANGES WITH THE DAEMON, and it is an accuracy feature rather than a style choice: judgment
agents stop running shell. They return schema'd verdicts and the daemon performs every state
advance, queue add, -Derive, lane-log line (both ends, since it owns a real clock) and ledger stamp,
attributed -By <stage>. Two deliberate exceptions the plan names: the pricer keeps -Record/-Promote
(script-enforced evidence contract), and content artifacts - extraction JSON, intake prose, spec
builds - remain the agents' own writes, because they are the work product rather than bookkeeping.

WHAT THE DAEMON NEVER DOES (section 4.4): it never starts or stops llama-server. The card is
hand-held. At extract-lane start it READS the live slot context and adapts; a shape that cannot fit
rung 2 makes escalations accumulate and the daemon's own --status names the pending narrow pass. It
is never scheduled by anything; install-nightly-task.ps1 remains the only scheduler in this estate.

EXIT CODES (section 4.5): 0 clean / 1 findings / 2 could-not-run. Marker HUNT-DAEMON-COMPLETE.
INTERPRETER: C:\\Codex\\Python312\\python.exe. Bare `python` is the Windows Store shim.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
REPO = os.path.dirname(MP)
sys.path.insert(0, HERE)

import harvest                                                   # noqa: E402
import hunt_dispatch                                             # noqa: E402
import hunt_lib                                                  # noqa: E402
import local_extract                                             # noqa: E402

HUNT_RUN_PS = os.path.join(HERE, "hunt-run.ps1")
INGREDIENT_QUEUE_PS = os.path.join(REPO, "grocery", "ingredient-queue.ps1")
WAVE_PREAUDIT_PS = os.path.join(HERE, "wave-preaudit.ps1")
WAVE_PUBLISH_PS = os.path.join(HERE, "wave-publish.ps1")
BATCH_LEDGER_PS = os.path.join(HERE, "batch-ledger.ps1")
BUILD_V2_SPEC_PS = os.path.join(HERE, "build-v2-spec.ps1")
FIND_SIMILAR_PS = os.path.join(HERE, "find-similar.ps1")
SPECS_DIR = os.path.join(MP, "db", "recipes")
RUNS_DIR = os.path.join(MP, "runs")

DEFAULT_COND = ("between 400 and 650 calories per serving AND 35 g carbohydrate or less per serving; "
                "budget meal-prep dinner; scalable to 14 servings; no seafood")
DEFAULT_BAND = {"calMin": 400, "calMax": 650, "carbMax": 35}


def say(m):
    print(m, flush=True)


# =====================================================================================================
# THE IN-FLIGHT DEDUP SIDE (S1's GAP, closed here - D9 was its latest allowed home).
#
# The dedup surface covers the live catalog, the backlog and prior rulings. A recipe BETWEEN
# acceptance and publication in a DIFFERENT run is in none of them: not in the digest (unpublished),
# not in the pool (taken by that run), not in the ledger (no ruling yet). Measured on the phase-1 gate
# run: `jalapeno-popper-chicken-casserole` sat at `priced` in the lowcarb-100 run dir while the pool
# offered `jalape-o-popper-chicken` as novel and the decider accepted it. Arguably the same dinner by
# its own three-of-four rule, and no signal could have shown it.
#
# It is a THIRD `side` on the dossier's neighbours, read from `runs\*\state`, and it is a FLAG - local
# ranks and flags, it never asserts an identity (section 10). The decider rules.
#
# THE STOP LIST IS READ FROM find-similar.ps1, NEVER COPIED. A quoted copy of another surface's
# vocabulary is the forked-taxonomy defect one level up, and this estate has the scar. If it cannot be
# read, the daemon scores NOTHING and says so - a blind pass would put "no in-flight neighbours" and
# "nobody looked" in the same bytes, which is the exact ambiguity `catalog_checked` exists to remove.
# =====================================================================================================

_STOP_RE = re.compile(r"\$script:STOP\s*=\s*@\((.*?)\)", re.S)
_WORD_RE = re.compile(r"'([^']*)'")
_TOK_RE = re.compile(r"[a-z0-9]+")

# States that mean a recipe is IN FLIGHT: not rejected, not published, not verified, not held.
INFLIGHT_STATES = ("sourced", "selected", "extracted", "mapped", "pricing", "parked", "priced",
                   "spec-built", "written", "qa-passed", "waved")


def read_stop_list(path=None):
    """find-similar.ps1's own STOP list. Returns (words, why) - an empty set means it could not be
    read, which the caller must treat as blind rather than as clean."""
    path = path or FIND_SIMILAR_PS
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            src = f.read()
    except Exception as e:                                        # noqa: BLE001
        return set(), "could not read %s (%s)" % (os.path.basename(path), e)
    m = _STOP_RE.search(src)
    if not m:
        return set(), "find-similar.ps1 no longer declares $script:STOP in a shape this can read"
    words = set(_WORD_RE.findall(m.group(1)))
    if len(words) < 20:
        return set(), "the STOP list read back as only %d word(s), which is not it" % len(words)
    return words, "%d stop words read from find-similar.ps1" % len(words)


def name_tokens(text, stop):
    """find-similar.ps1's Get-Tokens, ported: lowercase, non-alphanumerics to spaces, drop tokens of
    3 characters or fewer and anything in the STOP list, unique."""
    out = []
    for t in _TOK_RE.findall(str(text or "").lower()):
        if len(t) > 3 and t not in stop and t not in out:
            out.append(t)
    return out


def overlap_score(a_tokens, b_tokens):
    """find-similar.ps1's Get-Score for the name half: 10 points per shared word. The item half needs
    an ingredient list the state files do not carry, so it is absent here and the dossier says which
    signal produced the neighbour."""
    shared = [t for t in a_tokens if t in b_tokens]
    return 10 * len(shared), shared


def read_inflight(runs_dir=None, exclude_run=None):
    """Every recipe sitting between acceptance and publication in ANY open run dir."""
    runs_dir = runs_dir or RUNS_DIR
    rows = []
    if not os.path.isdir(runs_dir):
        return rows
    for run in sorted(os.listdir(runs_dir)):
        if exclude_run and run == exclude_run:
            continue
        state_dir = os.path.join(runs_dir, run, "state")
        if not os.path.isdir(state_dir):
            continue
        for fn in sorted(os.listdir(state_dir)):
            if not fn.endswith(".json"):
                continue
            try:
                with open(os.path.join(state_dir, fn), "r", encoding="utf-8-sig") as f:
                    st = json.load(f)
            except Exception:                                     # noqa: BLE001
                continue
            if str(st.get("state")) not in INFLIGHT_STATES:
                continue
            rows.append({"slug": str(st.get("slug") or fn[:-5]),
                         "name": str(st.get("title") or st.get("slug") or fn[:-5]),
                         "state": str(st.get("state")), "run": run})
    return rows


def inflight_neighbours(candidate_name, inflight, stop, cap=3, floor=20):
    """Neighbours from the in-flight side, scored the way find-similar scores the live side. `floor`
    is 20, i.e. two shared identity words - one shared word is noise at this corpus size."""
    if not stop:
        return []
    ct = name_tokens(candidate_name, stop)
    hits = []
    for row in inflight:
        score, shared = overlap_score(ct, name_tokens(row["name"], stop))
        if score >= floor:
            hits.append({"slug": row["slug"], "name": row["name"], "score": score,
                         "shared": shared, "source": "word-overlap", "side": "in-flight",
                         "in_flight_state": row["state"], "in_flight_run": row["run"]})
    hits.sort(key=lambda h: (-h["score"], h["slug"]))
    return hits[:cap]


# =====================================================================================================
# The daemon
# =====================================================================================================

class Daemon(object):

    def __init__(self, run_dir, run_id, conditions=DEFAULT_COND, band=None, wave_size=None,
                 target=0, dry_run_publish=True, pool_path=None, dispatcher=None, ps=None,
                 quiet=False, ledger_path=""):
        self.run_dir = run_dir
        self.run_id = run_id
        self.conditions = conditions
        self.band = dict(band or DEFAULT_BAND)
        self.wave_size = wave_size or hunt_lib.WAVE_SIZE
        self.target = target
        self.dry_run_publish = dry_run_publish
        # A SCRATCH BATCH LEDGER, and the precedent is wave-publish.ps1's own -LedgerPath, whose
        # header says it exists "ONLY so the gate drill can run over a scratch ledger instead of
        # writing a fake batch into the live one (a test row there would never close cleanly and
        # batch-ledger -Verify would report it as a stalled batch forever)". Measured 2026-08-24:
        # the first drain drill did exactly that, twice, and left two open w5/w6 rows behind.
        # Empty means the live ledger, which is what a real run wants.
        self.ledger_path = ledger_path
        self.pool_path = pool_path or harvest.POOL
        self.quiet = quiet

        # INJECTED, so every fixture below runs for zero tokens and zero shell.
        self._dispatch = dispatcher or hunt_dispatch.dispatch
        self._ps = ps or hunt_lib.ps_invoke

        self.breaker = hunt_lib.make_breaker()
        self.retry_counts = {}
        self.rec = {}                # slug -> ctx
        self.outcomes = []
        self.accepted_slugs = []
        self.absent_terms = []       # ordered, deduped: the queue dedupes by TERM across recipes
        self.pricing_slugs = set()
        self.qa_passed = []
        self.wave_results = []
        self.wave_no = 0
        self._wave_chain = None     # the ported waveChain: serial waves, concurrent with the lanes
        self.held = []               # mapped-with-open-holds and `held`: reported, never dispatched
        self.review_pending = []
        self.escalations_blocked = []   # rung-2-needing pages the live server shape cannot take
        self.slot_ctx = None
        self.lane_lines = 0
        self.findings = []

        self.ch = {k: hunt_lib.chan() for k in
                   ("decide", "extract", "map", "write", "qa", "price_wake")}
        self.wip_waiters = []
        self.seen_candidates = set()   # dossiers already built this run
        self.priced_terms = set()      # terms already sent to the pricer: never sent twice

        # THE COST-ENGINE MUTEX (section 4.5). build-v2-spec -RunCost shells the cost engine, which
        # rewrites db\costed.json; the write lane runs 3 concurrent writers, so v2 raced on that file
        # and the wave-2 audit watched costed.json rewritten mid-audit by wave-3 traffic. ONE
        # process-wide lock around EVERY cost-engine invocation - the -RunCost pass, preaudit cost
        # re-runs, compute-v2-perserving. Spec assembly stays parallel; only the cost pass serializes.
        self.cost_lock = asyncio.Lock()
        self.cost_passes = []        # (start, end) per pass, so the fixture can prove no overlap

    # ---- plumbing ------------------------------------------------------------------------------

    def log(self, m):
        if not self.quiet:
            say(m)

    async def ps(self, script, args, timeout=600):
        """EVERY PowerShell call goes through hunt_lib.ps_invoke - never a second invocation style.
        `-File` cannot bind a multi-element [string[]] from argv at all (it drops or composites), and
        both broken shapes are frozen as must-fire fixtures in decide_apply's suite."""
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, lambda: self._ps(script, args, timeout))

    async def lane(self, lane_name, label, items, by, event, tokens_in=-1, tokens_out=-1,
                   detail=""):
        """A lane-log line. BOTH ENDS, always: the daemon owns a real clock, so start/end pairing is
        what finally makes stage duration measurable. Section 4.5's completeness rule covers local
        work too - a page settled by the local ladder is work done, not work skipped."""
        args = ["-Lane", "-RunDir", self.run_dir, "-LaneName", lane_name, "-Label", label,
                "-Items", list(items or []), "-By", by, "-Event", event,
                "-InputTokens", tokens_in, "-OutputTokens", tokens_out]
        if detail:
            args += ["-Detail", detail]
        rc, out, err = await self.ps(HUNT_RUN_PS, args, timeout=120)
        if rc == 0:
            self.lane_lines += 1
        else:
            self.findings.append("lane-log %s/%s %s did not land: %s"
                                 % (lane_name, label, event, ((out or "") + (err or "")).strip()[:200]))
        return rc

    async def advance(self, slug, to, by, detail="", terms=None, optional_terms=None,
                      title=None, source_url=None, protein=None):
        args = ["-Advance", "-RunDir", self.run_dir, "-Slug", slug, "-To", to, "-By", by,
                "-Detail", detail or ""]
        if terms:
            args += ["-Terms", list(terms)]
        if optional_terms:
            args += ["-OptionalTerms", list(optional_terms)]
        # -Title / -SourceUrl / -Protein bind ONLY at state-file creation; no later -Advance can
        # back-fill them, and the wave manifest is built out of exactly these fields.
        if title is not None:
            args += ["-Title", title]
        if source_url is not None:
            args += ["-SourceUrl", source_url]
        if protein is not None:
            args += ["-Protein", protein]
        rc, out, err = await self.ps(HUNT_RUN_PS, args, timeout=180)
        if rc != 0:
            self.findings.append("%s: could not advance to %s (%s)"
                                 % (slug, to, ((out or "") + (err or "")).strip()[:200]))
        return rc == 0

    async def dispatch(self, agent, prompt, lane_name, label, items, schema=None, validator=None,
                       stage=None):
        """One judgment call, WITH ITS LANE-LOG PAIR AND ITS REAL TOKEN STAMP.

        Returns the payload or None. A None is NO VERDICT (B5) - the caller decides whether that is a
        retry or a STUCK; it is never a rejection, because nobody ruled on anything.
        """
        if self.halted():
            return None
        await self.lane(lane_name, label, items, stage or lane_name, "start")
        self.breaker.count_call()
        loop = asyncio.get_event_loop()
        res = await loop.run_in_executor(
            None, lambda: self._dispatch(agent, prompt, schema=schema, validator=validator))
        await self.lane(lane_name, label, items, stage or lane_name, "end",
                        tokens_in=res.tokens_in, tokens_out=res.tokens_out,
                        detail=("re-asked; " if res.reasked else "")
                        + (res.failure or "ok"))
        for f in res.findings:
            self.findings.append("%s/%s: %s" % (lane_name, label, f))
        if not res.ok:
            self.log("  %s %s: NO VERDICT (%s) %s" % (lane_name, label, res.failure,
                                                      (res.detail or "")[:120]))
        self.breaker.note(bool(res.ok))
        return res.payload

    def halted(self):
        if self.breaker.open:
            return True
        if self.breaker.check_budget():
            self.log("*** CIRCUIT BREAKER OPEN: %s" % self.breaker.reason)
            self.close_all()
            return True
        return False

    def trip(self, reason):
        if self.breaker.open:
            return
        self.breaker.trip(reason)
        self.log("*** CIRCUIT BREAKER OPEN: %s" % reason)
        self.log("*** No further agent calls. Lanes drain; every recipe resumes from its real state.")
        self.close_all()

    def close_all(self):
        for c in self.ch.values():
            c.close()
        self.notify_wip()

    async def with_retry(self, fn, slugs, stage):
        """Ported from hunt-orchestrator.js. Retries are accounted PER SLUG (B6): the map lane pulls a
        fresh slug combination each cycle, so a shape-keyed budget minted a new allowance every time
        and never saturated - 657 failed calls against a wall only a clock could clear."""
        lst = [s for s in (slugs if isinstance(slugs, (list, tuple)) else [slugs]) if s]
        while True:
            if self.halted():
                return None
            r = await fn()
            if r is not None:
                return r
            if self.breaker.open:
                return None
            worst = hunt_lib.bump_retries(self.retry_counts, lst, stage)
            if worst > hunt_lib.MAX_STAGE_RETRIES:
                self.log("%s: %s - out of retries after %d attempts; marking STUCK, not rejected"
                         % (stage, ",".join(lst), worst))
                return None
            self.log("%s: %s - no response, retry %d/%d"
                     % (stage, ",".join(lst), worst, hunt_lib.MAX_STAGE_RETRIES))

    # ---- bookkeeping ----------------------------------------------------------------------------

    def record(self, slug, patch):
        c = self.rec.setdefault(slug, {"slug": slug})
        c.update(patch)
        return c

    def finish(self, slug, status, state, detail):
        c = self.record(slug, {"status": status, "state": state, "detail": detail})
        self.outcomes.append(c)
        self.notify_wip()
        return c

    def stuck(self, slug, stage, detail):
        """A STUCK is not a rejection. Nobody rendered a verdict, so nothing may be recorded as if
        somebody had (B5: 14 recipes were reported rejected in 2026-08-15 by exactly that confusion)."""
        self.finish(slug, "stuck", None, "%s: %s" % (stage, detail))

    def wip(self):
        return len(self.accepted_slugs) - len(self.outcomes)

    def notify_wip(self):
        for w in self.wip_waiters[:]:
            if not w.done():
                w.set_result(None)
        self.wip_waiters = []

    async def wait_for_wip(self):
        """The circuitOpen check is load-bearing, not defensive: once the breaker trips no recipe can
        resolve, so wip() can never fall and a producer parked here would be woken, re-test, and park
        again forever. The run would hang instead of exiting cleanly (B9)."""
        while self.wip() >= hunt_lib.WIP_LIMIT and not self.breaker.open:
            fut = asyncio.get_event_loop().create_future()
            self.wip_waiters.append(fut)
            await fut

    # ---- the cost engine, serialized ------------------------------------------------------------

    async def cost_engine(self, script, args, timeout=1800):
        """EVERY cost-engine invocation goes through here and nowhere else."""
        async with self.cost_lock:
            t0 = time.time()
            try:
                return await self.ps(script, args, timeout)
            finally:
                self.cost_passes.append((t0, time.time()))

    # ---- lanes ----------------------------------------------------------------------------------

    async def pool_worker(self, n, worker):
        await asyncio.gather(*[worker(i) for i in range(n)])

    # ---------------------------------------------------------------------------------------------
    # POOL - the decide lane's producer. Zero agents: it reads the backlog and builds dossiers.
    #
    # THE WIP LIMIT GATES POOL POPS exactly as it gated sourcing in v2. Hunting is gone, but the same
    # thing is true of the backlog: it can always find more work, so it is the lane that has to yield.
    # The measure is accepted-but-unresolved recipes, which is how much unfinished work is already in
    # the building, and the channel's own backpressure keeps the queue shallow on top of that.
    # ---------------------------------------------------------------------------------------------

    async def pool_lane(self):
        try:
            while True:
                if self.halted():
                    return
                if self.target and len(self.accepted_slugs) >= self.target:
                    self.log("pool: target of %d reached - popping nothing further" % self.target)
                    return
                # Checked BEFORE the WIP park as well as after. Nothing but this lane closes the
                # decide channel in a live run, but a producer that parks on a limit only a consumer
                # can lower, with its own output already shut, is B9 exactly: it would be woken by
                # nothing and the run would hang instead of exiting.
                if self.ch["decide"].is_closed():
                    return
                await self.wait_for_wip()
                if self.breaker.open:
                    return
                await self.ch["decide"].wait_for_space(2 * hunt_lib.DECIDE_BATCH)
                if self.ch["decide"].is_closed():
                    return
                batch = self.pop_dossiers(hunt_lib.DECIDE_BATCH)
                if not batch:
                    self.log("pool: no available candidate left in the backlog")
                    return
                for d in batch:
                    self.ch["decide"].push(d)
        finally:
            self.ch["decide"].close()

    def pop_dossiers(self, n):
        """Build the next N dossiers, in harvest's own pop order. READ-ONLY: harvest.py is the pool's
        sole writer, and `--mark-taken` is a separate act performed at dispatch time. A dossier that
        was built and never dispatched must not strand its candidates as taken."""
        pool = harvest.read_pool(self.pool_path)
        avail = [c for c in pool["candidates"] if c.get("status") == "available"
                 and c["slug"] not in self.seen_candidates]
        if not avail:
            return []
        avail.sort(key=harvest.dossier_rank)
        picked = avail[:max(1, n)]
        catalog_n = harvest.catalog_size()
        out = []
        for c in picked:
            self.seen_candidates.add(c["slug"])
            d = harvest.build_dossier(c, catalog_n)
            out.append({"slug": c["slug"], "name": c.get("name"), "url": c.get("url"),
                        "domain": c.get("domain"), "dossier": d})
        return out

    # ---------------------------------------------------------------------------------------------
    # DECIDE - one worker, the single writer of shared state. Section S2.
    # ---------------------------------------------------------------------------------------------

    async def decide_lane(self):
        import decide_apply                                       # noqa: PLC0415
        methods, _u = harvest.load_methods()
        allowed = set(methods) | {"any"}
        stop, why = read_stop_list()
        if not stop:
            self.findings.append("in-flight dedup side: BLIND - %s. Dossiers will say so rather than "
                                 "claim an empty neighbour list" % why)
        batch_no = 0
        while True:
            items = await self.ch["decide"].take_batch(hunt_lib.DECIDE_BATCH)
            if items is None:
                break
            if self.halted():
                break
            await self.wait_for_wip()
            if self.breaker.open:
                break
            batch_no += 1
            slugs = [c["slug"] for c in items]

            # TAKEN AT POP, BEFORE DISPATCH. Two concurrent runs popping the same available
            # candidates would both pay a decider for them (the bridge does not do this, which is
            # safe only while exactly one run exists). harvest.py is the pool's SOLE writer, so the
            # mark goes through its verb rather than through a second hand on the same file.
            taken = []
            for c in items:
                if await self.mark_taken(c["slug"]):
                    taken.append(c)
                else:
                    # The pool refused the take, which means another run already holds this
                    # candidate. Dropping it here is the whole point of marking BEFORE dispatch:
                    # both runs would otherwise pay a decider for the same dossier.
                    self.log("decide: %s is already taken by another run - dropped from the batch"
                             % c["slug"])
            if not taken:
                continue
            items, slugs = taken, [c["slug"] for c in taken]

            payload = await self.with_retry(
                lambda: self.dispatch("recipe-dedup-selector",
                                      self.decide_prompt(items, stop),
                                      "select", "decide:%dx" % len(items), slugs,
                                      schema=hunt_lib.DECIDE,
                                      validator=lambda p: hunt_lib.validate_decide(p, methods=allowed),
                                      stage="decider"),
                slugs, "decide")
            if payload is None:
                for s in slugs:
                    self.stuck(s, "decide", "no verdict was ever rendered on this candidate")
                continue

            loop = asyncio.get_event_loop()
            applied, findings = await loop.run_in_executor(
                None, lambda: decide_apply.apply_verdict(payload, self.run_dir, self.run_id,
                                                         self.pool_path, "", False, True))
            self.findings.extend(findings)
            for slug, verdict, _how in applied:
                if verdict != "accepted":
                    continue
                if slug not in self.accepted_slugs:
                    self.accepted_slugs.append(slug)
                cand = next((c for c in items if c["slug"] == slug), {"slug": slug})
                self.ch["extract"].push(self.record(slug, dict(cand, state="selected")))
            self.log("decide batch %d: %d ruling(s), %d accepted so far"
                     % (batch_no, len(applied), len(self.accepted_slugs)))
        self.ch["extract"].close()

    async def mark_taken(self, slug):
        loop = asyncio.get_event_loop()
        import subprocess                                          # noqa: PLC0415
        args = [sys.executable, os.path.join(HERE, "harvest.py"), "--mark-taken", slug,
                "--run", self.run_id]
        if self.pool_path and self.pool_path != harvest.POOL:
            args += ["--pool", self.pool_path]
        p = await loop.run_in_executor(None, lambda: subprocess.run(args, capture_output=True))
        if p.returncode != 0:
            self.findings.append("%s: --mark-taken did not land (rc %d)" % (slug, p.returncode))
        return p.returncode == 0

    def decide_prompt(self, items, stop):
        """EVERY DISPATCH AFTER THE FIRST CARRIES THE RUN'S ACCEPTED-SO-FAR LIST (the gate run's own
        finding). Without it the single decider becomes N independent deciders wearing one name: it
        rejected `antipasto-salad` as a near-twin at bge 0.977 in batch 1 and then ACCEPTED
        `antipasto-pasta-salad` in batch 2, and accepted two different chicken salads across rounds.
        v2's dispatch carried it; dropping it in the port was the error."""
        inflight = read_inflight(exclude_run=os.path.basename(self.run_dir))
        dossiers = []
        for c in items:
            d = dict(c.get("dossier") or c)
            extra = inflight_neighbours(d.get("name") or d.get("slug"), inflight, stop)
            if extra:
                d["neighbours"] = list(d.get("neighbours") or []) + extra
            cc = dict(d.get("catalog_checked") or {})
            cc["in_flight_recipes_searched"] = len(inflight) if stop else None
            cc["in_flight_matches"] = len(extra)
            if not stop:
                cc["in_flight_note"] = ("NOT SEARCHED - the stop list could not be read from "
                                        "find-similar.ps1, so treat the in-flight side as unknown "
                                        "rather than empty")
            d["catalog_checked"] = cc
            dossiers.append(d)
        acc = self.accepted_slugs
        return (
            "Rule on %d candidate dossier(s) for run %s.\n\n"
            "ALREADY ACCEPTED THIS RUN (%d): %s\n\n"
            "Each dossier's `neighbours` carries a `side`: `live-catalog` is a published dinner this\n"
            "candidate would duplicate, `backlog` is another unruled candidate, and `in-flight` is a\n"
            "recipe another OPEN RUN has accepted but not yet published - invisible to the catalog and\n"
            "to the pool alike, and the collision class that put a jalapeno popper chicken through\n"
            "twice. `catalog_checked` states that the search HAPPENED, so an empty match list is\n"
            "evidence of absence rather than evidence nobody looked.\n\n"
            "DOSSIERS:\n%s\n\n"
            "Return the DECIDE payload and nothing else. Write no file.\n"
            % (len(dossiers), self.run_id, len(acc), ", ".join(acc) or "(nothing yet)",
               json.dumps(dossiers, indent=1, ensure_ascii=False)))

    # ---------------------------------------------------------------------------------------------
    # EXTRACT - the local ladder first, Claude only for the residue. Cap 3 counts CLAUDE agents ONLY;
    # the local ladder's concurrency is the GPU slot budget and the two are separate ledgers.
    # ---------------------------------------------------------------------------------------------

    async def extract_lane(self, ladder=None, jobs=4):
        import extract_sweep                                      # noqa: PLC0415
        esc_q = hunt_lib.chan()
        pool = None
        made_ladder = False
        if ladder is None:
            from concurrent.futures import ThreadPoolExecutor      # noqa: PLC0415
            pool = ThreadPoolExecutor(max_workers=jobs)
            ladder = RetryLadder(extract_sweep.Ladder(pool=pool, jobs=jobs), self)
            made_ladder = True
        self.slot_ctx = ladder.slot_ctx()
        rung2_fits = bool(self.slot_ctx) and self.slot_ctx >= local_extract.RUNG2_MIN_SLOT_CTX
        ladder.allow_rung2 = rung2_fits
        self.log("extract lane: llama-server reports %s tokens per slot; rung 2 needs ~%d -> %s"
                 % (self.slot_ctx or "an unknown number of", local_extract.RUNG2_MIN_SLOT_CTX,
                    "rung 2 available" if rung2_fits else
                    "RUNG 2 UNAVAILABLE, escalations will accumulate (see --status)"))

        async def local_worker():
            """The local ladder, serial over pages by design: one page settles at a time and its lines
            fan across the server's slots. The daemon never starts or stops llama-server."""
            try:
                while True:
                    c = await self.ch["extract"].take()
                    if c is None:
                        return
                    if self.breaker.open:
                        return
                    target = {"slug": c["slug"], "url": c.get("url") or c.get("source_url"),
                              "title": c.get("name") or c.get("title"),
                              "domain": c.get("domain"), "from": "daemon",
                              "dest": os.path.join(self.run_dir, "extracted"),
                              "run_dir": self.run_dir}
                    loop = asyncio.get_event_loop()
                    rec = await loop.run_in_executor(
                        None, lambda t=target: extract_sweep.sweep_one(t, ladder))
                    if rec.get("contract") is not None:
                        await loop.run_in_executor(
                            None, lambda r=rec, t=target: extract_sweep.write_record(r, t["dest"]))
                    if rec["settled"]:
                        # Section 4.5's lane-log completeness rule: a locally settled page is WORK
                        # DONE. -By local, tokens 0, which is the point - it cost the run nothing.
                        await self.lane("extract", "local rung %d" % rec["rung"], [rec["slug"]],
                                        "local", "start")
                        await self.lane("extract", "local rung %d" % rec["rung"], [rec["slug"]],
                                        "local", "end", 0, 0,
                                        "settled in %.1fs" % rec["seconds"])
                        await self.advance(rec["slug"], "extracted", "local",
                                           "extraction ladder rung %d, every line verified"
                                           % rec["rung"])
                        self.ch["map"].push(self.record(rec["slug"], {"state": "extracted"}))
                    elif rec["blocked"]:
                        # Could-not-run is BLOCKED, never an escalation and never a pass. A down
                        # server or an uncached page is not a page the Claude extractor should be
                        # paid to look at (rung 3 exists for pages the local pass FAILED on).
                        self.stuck(rec["slug"], "extract", "BLOCKED: %s" % rec["reason"])
                        self.findings.append("%s: extraction blocked - %s" % (rec["slug"], rec["reason"]))
                    else:
                        if not rung2_fits and rec["rung"] == 1:
                            self.escalations_blocked.append(rec["slug"])
                        esc_q.push(rec["slug"])
            finally:
                esc_q.close()

        async def claude_worker(_i):
            while True:
                slug = await esc_q.take()
                if slug is None:
                    return
                if self.halted():
                    return
                await self.rung3(slug)

        await asyncio.gather(local_worker(),
                             *[claude_worker(i) for i in range(hunt_lib.LANE_CAPS["extract"])])
        if made_ladder and pool is not None:
            pool.shutdown(wait=True)
        self.ch["map"].close()

    async def rung3(self, slug):
        """THE ESCALATION FILE IS THE DISPATCH PAYLOAD (S3: the failure reason and the unverified
        lines travel with the page, and the extractor is told not to re-run the local script)."""
        esc_path = os.path.join(self.run_dir, "extracted", "%s.escalation.json" % slug)
        if not os.path.exists(esc_path):
            self.findings.append("%s: rung 3 had no escalation file to dispatch" % slug)
            return
        with open(esc_path, "r", encoding="utf-8-sig") as f:
            esc = json.load(f)
        url = esc.get("source_url") or ""
        payload = await self.with_retry(
            lambda: self.dispatch("recipe-hunter-extractor", self.rung3_prompt(esc),
                                  "extract", "rung3:%s" % slug, [slug],
                                  schema=hunt_lib.EXTRACT3, stage="extractor"),
            slug, "extract")
        if payload is None:
            self.stuck(slug, "extract", "rung 3 rendered no verdict; the escalation file is untouched "
                                        "and this page is resumable")
            return
        if hunt_lib.norm_state(payload.get("state")) not in ("ok", "settled"):
            self.finish(slug, "rejected", "rejected-unreadable",
                        payload.get("reason") or "the extractor could not read the page")
            await self.advance(slug, "rejected-unreadable", "extractor",
                               (payload.get("reason") or "unreadable")[:200])
            return

        # THE VERIFICATION BLOCK IS THE DAEMON'S TO COMPUTE, never the agent's to assert - and it is
        # computed over page_text_from_html(cached HTML), NEVER over raw markup. An ingredient line
        # interleaved with inline tags ("1 lb <strong>chicken</strong>") never substring-matches raw
        # HTML, so skipping the strip would smear an honest Claude extraction with a false-low
        # verified_rate. Rung 2 feeds verify() through the same function.
        html = harvest.cached_body(url) if url else None
        if html is None:
            check = {"lines": len(payload.get("ingredients") or []), "verified": 0, "unverified": 0,
                     "verified_rate": None, "unverified_lines": [], "passed": None,
                     "bar": "not checkable (the page is no longer in the cache)"}
            self.findings.append("%s: rung 3 landed unverified - no cached page to check it against"
                                 % slug)
        else:
            check = local_extract.verify(payload, local_extract.page_text_from_html(html))
        out = {"extraction": dict(payload), "verification": check, "model": "claude",
               "tokens": 0, "rung": 3, "extracted_by": "claude", "escalate": False,
               "escalate_reason": None}
        contract = local_extract.to_contract(out, url, payload.get("title"))
        # RECORDING, NOT GATING. Rung 3 is the last rung, so a low verified_rate is surfaced to
        # source-QA as a concern rather than escalated to nowhere.
        rate = check.get("verified_rate")
        if rate is not None and not check.get("passed"):
            concern = ("rung-3 transcription verified only %.0f%% of its lines against the cached "
                       "page; unverified: %s" % (100 * rate, ", ".join(check.get("unverified_lines") or [])))
            contract["concerns"] = list(contract.get("concerns") or []) + [concern]
            self.findings.append("%s: %s" % (slug, concern))
        dest = os.path.join(self.run_dir, "extracted", "%s.json" % slug)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w", encoding="utf-8") as f:
            json.dump(contract, f, indent=2, ensure_ascii=False)
        # THE ONE-WAY CLEANUP: a settled page deletes its escalation, or the lane dispatches a Claude
        # extractor for a page that is already done.
        os.remove(esc_path)
        await self.advance(slug, "extracted", "extractor", "rung 3 (Claude), verification recorded")
        self.ch["map"].push(self.record(slug, {"state": "extracted"}))

    def rung3_prompt(self, esc):
        return (
            "Transcribe ONE recipe page the local extraction pass could not settle.\n\n"
            "DO NOT run the local script and do not try to re-earn the failure - everything it found\n"
            "is below. The page is at the source URL; fetch it from the cache if you can reach it, and\n"
            "if you cannot reach the page at all, say so: state \"unreadable\" is a complete and\n"
            "correct answer. An invented recipe is the worst outcome in this flow.\n\n"
            "TRANSCRIPTION ONLY. Convert no units, estimate no missing measurement, rewrite no prose.\n"
            "The `raw` field of each ingredient is the page's own line, verbatim.\n\n"
            "WHAT THE LOCAL PASS FOUND:\n%s\n\n"
            "Return the extraction contract as JSON and nothing else: "
            "{state, reason, title, source_url, servings, time_total, time_active, "
            "ingredients:[{raw,item,qty,unit,prep,optional,section}], instructions:[], concerns:[]}.\n"
            "Do not write `extracted_by` or `verification` - those are computed here, from the page.\n"
            % json.dumps(esc, indent=1, ensure_ascii=False)[:12000])

    # ---------------------------------------------------------------------------------------------
    # MAP - cap 2, micro-batches of up to 5 (section S4)
    # ---------------------------------------------------------------------------------------------

    async def map_lane(self):
        async def worker(_i):
            while True:
                batch = await self.ch["map"].take_batch(hunt_lib.MAP_BATCH)
                if batch is None:
                    return
                if self.halted():
                    return
                slugs = [b["slug"] for b in batch]
                woke = False
                self.log("map: micro-batch of %d (%s)" % (len(slugs), ", ".join(slugs)))
                r = await self.with_retry(
                    lambda: self.dispatch("recipe-ingredient-mapper", self.map_prompt(slugs),
                                          "map", "map:%dx" % len(slugs), slugs,
                                          schema=hunt_lib.MAPPED, stage="mapper"),
                    slugs, "map")
                if r is None:
                    if self.breaker.open:
                        # Do NOT requeue into a closed pipeline - the items would bounce forever.
                        for b in batch:
                            self.stuck(b["slug"], "map",
                                       "run halted by the breaker before mapping - resumable")
                        return
                    self.log("map: batch of %d got no response after retries - requeuing individually"
                             % len(slugs))
                    for b in batch:
                        self.ch["map"].push(b)
                    continue
                results = r.get("results") or []
                for b in batch:
                    res = next((x for x in results if x and x.get("slug") == b["slug"]), None)
                    if res is None:
                        # The batch answered but said nothing about this slug. Still not a verdict.
                        n = hunt_lib.bump_retries(self.retry_counts, [b["slug"]], "map")
                        if n > hunt_lib.MAX_STAGE_RETRIES:
                            self.stuck(b["slug"], "map",
                                       "the mapper never reported on this slug after %d batch attempts"
                                       % n)
                        else:
                            self.ch["map"].push(b)
                        continue
                    if hunt_lib.is_rejected(res.get("status")):
                        state = res.get("state") or "rejected-not-carried"
                        self.finish(b["slug"], "rejected", state,
                                    res.get("detail") or "mapper rejected")
                        await self.advance(b["slug"], state, "mapper",
                                           (res.get("detail") or "")[:200])
                        continue
                    absent = [t for t in (res.get("absent_terms") or []) if t]
                    optional = [t for t in (res.get("optional_absent") or []) if t]
                    await self.advance(b["slug"], "mapped", "mapper", res.get("detail") or "")
                    if not absent and hunt_lib.norm_state(res.get("state")) == "priced":
                        await self.advance(b["slug"], "priced", "mapper",
                                           "every term answered from the board")
                        self.ch["write"].push(self.record(b["slug"], {"state": "priced"}))
                    else:
                        # THE DAEMON HOLDS THE PEN, so B8 becomes impossible rather than warned
                        # against: the terms arrive as a JSON array and go to the queue and to
                        # -Terms as DISTINCT elements, through ps_invoke's -Command road.
                        for t in absent:
                            await self.ps(INGREDIENT_QUEUE_PS,
                                          ["-Add", "-Term", t, "-Recipe", b["slug"],
                                           "-Why", "%s needs it" % b["slug"]], timeout=180)
                            # A TERM THIS RUN HAS ALREADY SENT TO THE PRICER IS NOT SENT AGAIN.
                            # ingredient-queue.ps1 is keyed by TERM and dedupes across recipes, and
                            # `absent_terms` is consumed destructively - so without this, the second
                            # recipe wanting the same term re-queues it behind a pricer that has
                            # already ruled on it. audit-lane-shape's price-lane-duplicate-items
                            # finding exists to catch precisely that discarded dedup. The -Add above
                            # still runs per recipe on purpose: the queue attaches BOTH slugs to the
                            # one item, which is how a recipe learns its own term was answered.
                            if t not in self.absent_terms and t not in self.priced_terms:
                                self.absent_terms.append(t)
                        await self.advance(b["slug"], "pricing", "mapper", "",
                                           terms=absent, optional_terms=optional)
                        self.pricing_slugs.add(b["slug"])
                        self.record(b["slug"], {"state": "pricing", "absent": absent})
                        woke = True
                # ONE WAKE PER MICRO-BATCH, after every term in it is on the queue. Waking the pricer
                # inside the per-slug loop let it start on recipe one's terms while recipe two's were
                # still being enqueued, which turns a lane that batches ACROSS recipes into a
                # per-recipe stage - the exact shape audit-lane-shape.ps1 was written to refuse.
                if woke:
                    self.ch["price_wake"].push("micro-batch of %d" % len(slugs))
        await self.pool_worker(hunt_lib.LANE_CAPS["map"], worker)
        self.ch["price_wake"].close()

    def map_prompt(self, slugs):
        return (
            "Map this MICRO-BATCH of %d recipe(s). Section S4 batches up to %d per invocation.\n"
            "Slugs: %s\n"
            "Transcriptions: %s\\extracted\\<slug>.json\n"
            "Write:          %s\\mapped\\<slug>.json\n\n"
            "Resolve every ingredient against the CLOSED vocabulary first, map it to a canonical board\n"
            "commodity id or reject it with evidence, mark each line blocking or optional, and ask the\n"
            "cheap board pricing question for every term. Report per slug.\n\n"
            "DO NOT run hunt-run.ps1 and DO NOT add anything to the ingredient queue. Return the terms\n"
            "the board could not answer in `absent_terms` as a JSON ARRAY and the orchestrator will\n"
            "enqueue them and move the state itself. That is not a courtesy: -Terms 'a,b' binds as ONE\n"
            "composite string in PowerShell and parked two recipes forever on 2026-08-16, and a JSON\n"
            "array cannot be comma-joined by accident.\n\n"
            "This run's conditions: %s\n"
            % (len(slugs), hunt_lib.MAP_BATCH, ", ".join(slugs), self.run_dir, self.run_dir,
               self.conditions))

    # ---------------------------------------------------------------------------------------------
    # PRICE - SINGLETON, self-looping queue drainer. ARCHITECTURE, not config (section 4.1a).
    # ---------------------------------------------------------------------------------------------

    async def price_lane(self):
        n = 0
        while True:
            woke = await self.ch["price_wake"].take()
            if woke is None and not self.absent_terms:
                break
            if self.halted():
                break
            # GREEDY EXHAUSTIVE SERVICE, per section 2.4's own loop. Never waits for a full batch: a
            # wait-for-full-batch policy deadlocked against the WIP limit, and throughput comes from
            # batching terms INSIDE one invocation, never from more pricers.
            while self.absent_terms:
                if self.halted():
                    break
                terms = self.absent_terms[:hunt_lib.PRICE_BATCH]
                self.absent_terms = self.absent_terms[hunt_lib.PRICE_BATCH:]
                self.priced_terms.update(terms)
                n += 1
                self.log("price lane [singleton] invocation %d: %d term(s) across %d recipe(s)"
                         % (n, len(terms), len(self.pricing_slugs)))
                await self.with_retry(
                    lambda t=terms, k=n: self.dispatch("recipe-hunter-pricer",
                                                       self.price_prompt(t),
                                                       "price", "queue batch %d" % k, t,
                                                       stage="pricer"),
                    terms, "price")
                # Derived counts are the ONLY thing that moves a recipe out of pricing/parked, and
                # -Derive is a script call now, not an agent asked to run one.
                await self.ps(HUNT_RUN_PS, ["-Derive", "-RunDir", self.run_dir], timeout=600)
                await self.reap_priced()
            if woke is None:
                break
        for slug in sorted(self.pricing_slugs):
            self.finish(slug, "parked", "parked",
                        "a blocking ingredient is still PENDING - see the ingredient queue for the "
                        "stores nobody reached")
        self.ch["write"].close()

    async def reap_priced(self):
        for slug in sorted(self.pricing_slugs):
            st = self.state_of(slug)
            if st == "priced":
                self.pricing_slugs.discard(slug)
                self.ch["write"].push(self.record(slug, {"state": "priced"}))
            elif st == "rejected-not-carried":
                self.pricing_slugs.discard(slug)
                self.finish(slug, "rejected", "rejected-not-carried",
                            "no Omaha store carries a blocking ingredient")
            # parked stays in pricing_slugs; a later batch may resolve it

    def price_prompt(self, terms):
        return (
            "Price this batch of %d term(s) the board has never carried. They come from SEVERAL\n"
            "recipes at once - the ingredient queue is keyed by term and dedupes across recipes,\n"
            "which is exactly why this lane batches.\n\n"
            "TERMS: %s\n\n"
            "You are the ONLY pricer alive right now, by design. Open your proven-safe shape: the two\n"
            "server stores plus ONE tab per browser store, in-store mode verified per store, one\n"
            "search per term. Throughput comes from batching terms inside THIS invocation.\n\n"
            "A candidate row is not a price - probe-ingredient gathers, you adjudicate. Record every\n"
            "verdict with evidence through ingredient-queue.ps1 -Record, which stays yours: it is a\n"
            "script-enforced evidence contract, not bookkeeping. A store you could not reach is\n"
            "blocked or error, which reads as PENDING and never as not-carried. Do not write board\n"
            "cells and do not move any recipe state - the orchestrator derives that from the queue.\n"
            % (len(terms), ", ".join(terms)))

    # ---------------------------------------------------------------------------------------------
    # WRITE - cap 3, plus the band gate read off the BUILT SPEC (section 4.5's D9/D8 note)
    # ---------------------------------------------------------------------------------------------

    async def write_lane(self):
        async def worker(_i):
            while True:
                c = await self.ch["write"].take()
                if c is None:
                    return
                if self.halted():
                    return
                slug = c["slug"]
                r = await self.with_retry(
                    lambda: self.dispatch("recipe-writer", self.write_prompt(slug),
                                          "write", slug, [slug], schema=hunt_lib.WRITE,
                                          stage="writer"),
                    slug, "write")
                if r is None:
                    self.stuck(slug, "write", "no response after retries - never actually written")
                    continue
                if hunt_lib.is_rejected(r.get("status")):
                    self.finish(slug, "rejected", "rejected-qa", r.get("detail") or "writer rejected")
                    await self.advance(slug, "rejected-qa", "writer", (r.get("detail") or "")[:200])
                    continue
                # THE COST PASS IS SERIALIZED. Spec assembly stayed parallel; this does not.
                await self.cost_engine(BUILD_V2_SPEC_PS,
                                       ["-InFile", os.path.join(self.run_dir, "intake",
                                                                "%s.json" % slug), "-RunCost"])
                cal, carbs = self.spec_band(slug)
                verdict = hunt_lib.in_band(cal, carbs, self.band)
                if not verdict["ok"]:
                    self.log("macro gate: %s built at %s - retiring" % (slug, verdict["reason"]))
                    await self.advance(slug, "rejected-qa", "macro-gate",
                                       "macro gate: %s" % verdict["reason"])
                    self.finish(slug, "rejected", "rejected-qa", "macro gate: %s" % verdict["reason"])
                    continue
                await self.advance(slug, "spec-built", "writer", "")
                await self.advance(slug, "written", "writer", "")
                self.ch["qa"].push(self.record(slug, {"state": "written", "cal": cal, "carbs": carbs}))
        await self.pool_worker(hunt_lib.LANE_CAPS["write"], worker)
        self.ch["qa"].close()

    def spec_band(self, slug, specs_dir=None):
        """The band, read off the BUILT SPEC rather than off the writer's self-report. A mechanical
        postcondition over the artifact beats a claim about it, and it needs nothing from D8."""
        p = os.path.join(specs_dir or SPECS_DIR, "%s.json" % slug)
        try:
            with open(p, "r", encoding="utf-8-sig") as f:
                spec = json.load(f)
        except Exception:                                         # noqa: BLE001
            return None, None
        stat = spec.get("stat") or {}
        return stat.get("cal"), stat.get("carbs")

    def write_prompt(self, slug):
        return (
            "Write recipe %s in Brad's voice and complete its intake.\n"
            "Inputs: %s\\extracted\\%s.json (the transcription - the recipe of record)\n"
            "        %s\\mapped\\%s.json (commodity ids, food-DB rows)\n"
            "Produce %s\\intake\\%s.json.\n\n"
            "Voice rails: no em dashes, Brad's tone, the existing framework, 14 servings.\n"
            "Compute NO number: every macro and every cost comes from the engine, and the\n"
            "orchestrator runs the spec build and reads the band off the built spec itself. Do not\n"
            "run hunt-run.ps1 and do not move any state.\n\n"
            "This run's conditions: %s\n"
            % (slug, self.run_dir, slug, self.run_dir, slug, self.run_dir, slug, self.conditions))

    # ---------------------------------------------------------------------------------------------
    # QA - cap 2, one owner-routed repair cycle (section S7)
    # ---------------------------------------------------------------------------------------------

    async def qa_lane(self):
        async def worker(_i):
            while True:
                c = await self.ch["qa"].take()
                if c is None:
                    return
                if self.halted():
                    return
                slug = c["slug"]
                # The battery runs PRE-DISPATCH now (phase 0's bridge had the agent run it).
                await self.qa_battery(slug)
                q = await self.with_retry(
                    lambda: self.dispatch("recipe-source-qa", self.qa_prompt(slug, 1),
                                          "qa", slug, [slug], schema=hunt_lib.QA, stage="source-qa"),
                    slug, "qa1")
                if q is None:
                    self.stuck(slug, "qa", "initial QA rendered no verdict")
                    continue
                if not hunt_lib.is_pass(q.get("verdict")):
                    owner = self.owner_agent(q.get("owner"))
                    self.log("QA FAIL %s -> one repair cycle by %s" % (slug, owner))
                    await self.dispatch(owner, self.qa_repair_prompt(slug, q), "qa",
                                        "repair:%s" % slug, [slug], stage=owner)
                    q = await self.with_retry(
                        lambda: self.dispatch("recipe-source-qa", self.qa_prompt(slug, 2),
                                              "qa", "re-qa:%s" % slug, [slug],
                                              schema=hunt_lib.QA, stage="source-qa"),
                        slug, "qa2")
                    if q is None:
                        self.stuck(slug, "qa", "the repair cycle was spent but re-QA rendered no "
                                               "verdict")
                        continue
                    if not hunt_lib.is_pass(q.get("verdict")):
                        await self.advance(slug, "rejected-qa", "source-qa",
                                           "failed QA twice: %s" % (q.get("findings") or "")[:150])
                        self.finish(slug, "rejected", "rejected-qa", "failed source-QA twice")
                        continue
                await self.advance(slug, "qa-passed", "source-qa", "")
                self.finish(slug, "qa-passed", "qa-passed", "")
                self.qa_passed.append(slug)
                # the ported maybeCloseWave(false): a full pool closes a wave NOW, mid-run
                self.schedule_wave(False)
        await self.pool_worker(hunt_lib.LANE_CAPS["qa"], worker)

    @staticmethod
    def owner_agent(owner):
        return {"extractor": "recipe-hunter-extractor",
                "mapper": "recipe-ingredient-mapper"}.get(owner, "recipe-writer")

    async def qa_battery(self, slug):
        import subprocess                                          # noqa: PLC0415
        loop = asyncio.get_event_loop()
        args = [sys.executable, os.path.join(HERE, "coverage_check.py"), "--battery",
                "--spec", os.path.join(SPECS_DIR, "%s.json" % slug),
                "--source", os.path.join(self.run_dir, "extracted", "%s.json" % slug),
                "--run-dir", self.run_dir]
        p = await loop.run_in_executor(None, lambda: subprocess.run(args, capture_output=True))
        if p.returncode == hunt_lib.EXIT_CANNOT_RUN:
            # Exit 2 is a BLOCKED stage, never a pass. It is a finding for the QA agent to see, not
            # a reason to skip the QA agent.
            self.findings.append("%s: the QA battery could not run (exit 2)" % slug)
        return p.returncode

    def qa_prompt(self, slug, attempt):
        return (
            "Fidelity check on ONE built recipe: %s.\n"
            "Built spec:      %s\\%s.json\n"
            "Transcription:   %s\\extracted\\%s.json\n"
            "Battery report:  %s\\qa\\%s.battery.json  (already run for you; its findings are\n"
            "                 questions for you, not verdicts. Exit 2 there is a BLOCKED stage.)\n%s\n"
            "Anchor on the transcription always; read the live page too when the domain is fetchable.\n"
            "A BLOCKED DOMAIN IS NEVER A FINDING AGAINST THE RECIPE - it makes the transcription the\n"
            "sole anchor and the verdict says so. Catch invented, dropped and drifted ingredients and\n"
            "steps. Write your verdict JSON to %s\\qa\\%s.json. Verdict only: never edit, re-extract\n"
            "or price, and do not move any state - the orchestrator does that from your verdict.\n"
            % (slug, SPECS_DIR, slug, self.run_dir, slug, self.run_dir, slug,
               ("\nThis is the RE-QA after one owner-routed repair cycle. A second FAIL is terminal.\n"
                if attempt > 1 else ""),
               self.run_dir, slug))

    def qa_repair_prompt(self, slug, q):
        return (
            "Source-QA failed recipe %s and routed the repair to you. This is the ONE repair cycle it\n"
            "gets; a second failure is terminal, so fix the actual finding rather than papering over\n"
            "it.\nFindings: %s\nQA file: %s\\qa\\%s.json\n\n"
            "Rebuild through build-v2-spec.ps1 -InFile %s\\intake\\%s.json if the spec changes. Never\n"
            "hand-edit a spec. Never weaken a gate. Report exactly what you changed, and if nothing\n"
            "needed changing SAY SO - that is a legitimate answer and it is treated differently from\n"
            "claiming a change that did not happen.\n"
            % (slug, (q.get("findings") or "")[:2000], self.run_dir, slug, self.run_dir, slug))

    # ---------------------------------------------------------------------------------------------
    # WAVE - serial. A PORT of runWave/trimWave, decision-for-decision. The agent-as-shell steps
    # inside it become direct calls; everything else keeps its order and its refusal conditions.
    # ---------------------------------------------------------------------------------------------

    def schedule_wave(self, force=False):
        """THE PORTED waveChain (CORRECTED 2026-08-24 - the six-dimension check caught the first
        build of this file deviating from the port here). v2 closed a wave THE MOMENT the qa-passed
        pool reached wave_size and chained it onto `waveChain`, so wave 1 was being audited while
        wave 3's recipes were still in QA. The first daemon build closed waves only AFTER every lane
        drained, which is the same work at a strictly worse wall clock: on a 100-recipe run it would
        serialize ten audits behind the last QA verdict. Waves stay SERIAL among themselves (the
        chain), concurrent with everything else (the task)."""
        k = self.maybe_close_wave(force)
        if k is None:
            return None
        prev = self._wave_chain

        async def _next():
            if prev is not None:
                await prev
            try:
                await self.run_wave(k, drain=bool(force))
            except Exception as e:                                # noqa: BLE001
                # v2's `.catch(e => log(...))`: a wave that throws is a finding, never a crashed run.
                self.findings.append("wave %d threw: %s" % (k, str(e)[:300]))
                self.log("wave %d threw: %s" % (k, str(e)[:300]))

        self._wave_chain = asyncio.ensure_future(_next())
        return k

    def maybe_close_wave(self, force=False):
        if not force and len(self.qa_passed) < self.wave_size:
            return None
        if force and not self.qa_passed:
            return None
        n = min(self.wave_size, len(self.qa_passed))
        del self.qa_passed[:n]
        self.wave_no += 1
        return self.wave_no

    async def run_wave(self, k, drain=False):
        # Publishing must never start on a dying run: a half-dispatched wave leaves the ledger open
        # and the audit stranded. qa-passed recipes simply wait for the next resume.
        if self.halted():
            self.log("WAVE %d: not starting - run halted; qa-passed recipes wait for the resume" % k)
            return
        args = ["-WaveClose", "-RunDir", self.run_dir]
        if drain:
            args.append("-Drain")
        if self.ledger_path:
            # hunt-run's -WaveClose has no ledger override, only -NoLedger. So on a scratch ledger
            # the daemon takes the pen for the batch open too, which is the pen-ownership rule
            # applied one step further rather than an exception to it.
            args.append("-NoLedger")
        rc, out, err = await self.ps(HUNT_RUN_PS, args, timeout=600)
        wk, slugs, batch = self.read_wave(out)
        if not slugs:
            # A -WaveClose that FAILED must never read as "nothing to close". The first drain drill
            # printed exactly that over an empty stdout while the close had actually worked, and an
            # empty answer that looks like a legitimate one is how a wave goes missing.
            blob = ((out or "") + (err or "")).strip()
            if rc != 0 or not blob:
                self.findings.append("wave close exited %d with %s - this is a BLOCKED wave, not an "
                                     "empty one" % (rc, "no output at all" if not blob else
                                                    blob.splitlines()[-1][:200]))
                self.log("WAVE %d: could not close (exit %d) %s"
                         % (k, rc, blob.splitlines()[-1][:160] if blob else "[no output]"))
            else:
                self.log("WAVE %d: nothing to close - %s" % (k, blob.splitlines()[-1][:160]))
            return
        self.log("WAVE %d: %d recipes - %s" % (wk, len(slugs), ", ".join(slugs)))
        if self.ledger_path:
            await self.ledger(["-Start", "-Batch", batch, "-Slugs", list(slugs)])
            for st in ("select", "map", "write", "build-specs"):
                await self.ledger(["-Stamp", "-Batch", batch, "-Stage", st,
                                   "-Detail", "streamed pre-wave"])

        await self.preaudit(wk)
        audit = await self.dispatch("recipe-batch-auditor", self.audit_prompt(wk, slugs, batch,
                                                                             "whole-wave", None),
                                    "audit", "wave-%d:audit" % wk, slugs,
                                    schema=hunt_lib.AUDIT, stage="auditor")
        repair_spent = False

        if audit and not hunt_lib.is_go(audit.get("verdict")):
            blockers = [s for s in (audit.get("blocking_slugs") or []) if s]
            self.log("WAVE %d: NO-GO on %s (%s) - one repair cycle"
                     % (wk, ", ".join(blockers) or "the wave", audit.get("blocker_kind")))
            owner = self.owner_agent(audit.get("owner"))
            audit_path = os.path.join(self.run_dir, "waves", "wave-%d.audit.md" % wk)
            before = self.mtimes(slugs, audit_path)
            await self.dispatch(owner, self.repair_prompt(wk, blockers, audit), "audit",
                                "wave-%d:repair" % wk, blockers or slugs, stage=owner)
            repair_spent = True

            # THE B11 POSTCONDITION, and the daemon computes it itself. On 2026-08-16 a repair agent
            # reported success on wave 1 having changed nothing at all, and the ONLY thing that
            # caught it was paying for a second full audit - the most expensive agent in the flow.
            # In the workflow this cost an agent call to read mtimes; here it is a stat().
            after = self.mtimes(slugs, audit_path)
            changed = [f for f in after if after[f] > before.get(f, 0)]
            if not changed:
                self.log("WAVE %d: the repair changed NOTHING - not paying for a re-audit" % wk)
                self.wave_results.append({"wave": wk, "slugs": slugs, "published": [], "held": [],
                                          "verdict": "NO-GO",
                                          "note": "repair claim did not hold: no file changed"})
                await self.trim_wave(wk, slugs, audit, True)
                return

            # THE B-4 SCOPE GATE. Recipe-local blockers re-audit only the repaired slugs; a
            # shared-data fix moved every recipe's numbers and REQUIRES the whole wave.
            scope = hunt_lib.choose_scope(audit.get("blocker_kind"), blockers)
            if not hunt_lib.scope_is_legal(scope["scope"], audit.get("blocker_kind")):
                raise RuntimeError("scope gate: a shared-data blocker may not re-audit narrowly "
                                   "(got %r)" % scope["scope"])
            self.log("WAVE %d: re-audit scope: %s (%s)"
                     % (wk, scope["scope"], audit.get("blocker_kind")))
            await self.preaudit(wk)
            audit = await self.dispatch("recipe-batch-auditor",
                                        self.audit_prompt(wk, slugs, batch, scope["scope"],
                                                          scope["why"]),
                                        "audit", "wave-%d:reaudit" % wk, slugs,
                                        schema=hunt_lib.AUDIT, stage="auditor")

        if not audit or not hunt_lib.is_go(audit.get("verdict")):
            self.log("WAVE %d: still NO-GO after one repair cycle" % wk)
            self.wave_results.append({"wave": wk, "slugs": slugs, "published": [], "held": [],
                                      "verdict": "NO-GO"})
            await self.trim_wave(wk, slugs, audit, repair_spent)
            return

        # THE AUDIT STAMP IS THE DAEMON'S, and finding that out is what the drain drill was for. In
        # v2 the auditor's own dispatch text told it to run `batch-ledger -Stamp -Stage audit` on a
        # GO, and wave-publish P1 refuses to publish a batch with no audit stamp. Under the
        # pen-ownership rule the agent stops running shell, so if the daemon does not stamp it,
        # nothing does and every wave stops at the publish gate. The verdict is still the auditor's;
        # only the pen moved.
        await self.ledger(["-Stamp", "-Batch", batch, "-Stage", "audit",
                           "-Detail", "%d/%d GO" % (len(slugs), len(slugs))])

        pub_args = ["-RunDir", self.run_dir, "-Wave", wk]
        if self.dry_run_publish:
            pub_args.append("-DryRun")
        if self.ledger_path:
            pub_args += ["-LedgerPath", self.ledger_path]
        rc, out, err = await self.ps(WAVE_PUBLISH_PS, pub_args, timeout=3600)
        if rc != 0:
            refusal = ((out or "") + (err or "")).strip()[-800:]
            self.log("WAVE %d: publish refused (exit %d)" % (wk, rc))
            self.wave_results.append({"wave": wk, "slugs": slugs, "published": [], "held": [],
                                      "verdict": "PUBLISH-REFUSED", "refusal": refusal})
            self.findings.append("wave %d: publish refused - %s" % (wk, refusal[:300]))
            return
        published, held, collateral, dry = self.read_publish(out, slugs)
        self.log("WAVE %d: %s %d, held %d, collateral %d"
                 % (wk, "would publish" if dry else "published", len(published), len(held),
                    collateral))

        if dry:
            # A dry run publishes nothing, so there is nothing to review and nothing to stamp. Saying
            # so is the point: a drill that dispatched a post-publish reviewer at pages that are not
            # live would be reviewing yesterday's site and calling it this wave.
            self.wave_results.append({"wave": wk, "slugs": slugs, "published": [], "held": [],
                                      "verdict": "GO", "dry_run": True,
                                      "would_publish": published})
            return

        await self.dispatch("post-publish-reviewer",
                            self.review_prompt(wk, published, held, collateral, batch),
                            "review", "wave-%d:review" % wk, published, stage="reviewer")
        await self.ledger(["-Stamp", "-Batch", batch, "-Stage", "post-publish-review",
                           "-Detail", "reviewed"])
        await self.ledger(["-Close", "-Batch", batch])
        self.wave_results.append({"wave": wk, "slugs": slugs, "published": published, "held": held,
                                  "verdict": "GO", "collateral": collateral})

    async def trim_wave(self, wk, slugs, audit, repair_spent):
        """A wave that cannot publish must NOT strand its recipes. On 2026-08-16 a double NO-GO left
        ten recipes in `waved` - a state whose only exits are published / rejected-audit / qa-passed /
        written - and nothing ever picked them up again. Two of them were audit-clean."""
        blockers = [s for s in ((audit or {}).get("blocking_slugs") or []) if s]
        # An auditor that named NOBODY blocks the whole wave: a NO-GO blaming the wave as a whole is
        # not a licence to publish any of it.
        per_slug = {s: ("BLOCK" if (not blockers or s in blockers) else "GO") for s in slugs}
        plan = hunt_lib.plan_trim(slugs, per_slug, repair_spent)
        self.log("WAVE %d: trimming - %d blocked, %d clean%s"
                 % (wk, len(plan["blocked"]), len(plan["clean"]),
                    " (the auditor named no slugs, so the whole wave is blocked)" if not blockers
                    else ""))
        for s in plan["toReject"]:
            await self.advance(s, "rejected-audit", "auditor",
                               ((audit or {}).get("summary") or "blocked by the wave audit")[:200])
            self.finish(s, "rejected", "rejected-audit", "blocked by the wave audit, repair spent")
        for s in plan["toRepair"]:
            await self.advance(s, "qa-passed", "auditor",
                               "trimmed out of wave %d for repair" % wk)
        for s in plan["clean"]:
            # A clean recipe must NEVER be rejected for its neighbours' defects.
            await self.advance(s, "qa-passed", "auditor",
                               "audit-clean, trimmed out of blocked wave %d" % wk)
            if s not in self.qa_passed:
                self.qa_passed.append(s)
        self.log("WAVE %d: %d clean recipe(s) returned to the pool for the next wave"
                 % (wk, len(plan["clean"])))

    async def ledger(self, args, timeout=300):
        """Every batch-ledger call, one road, so the scratch override cannot be forgotten on one of
        them - which would put a drill row in the live ledger while the rest went to the copy."""
        if self.ledger_path:
            args = list(args) + ["-LedgerPath", self.ledger_path]
        return await self.ps(BATCH_LEDGER_PS, args, timeout)

    async def preaudit(self, wk):
        rc, _o, _e = await self.cost_engine(WAVE_PREAUDIT_PS,
                                            ["-RunDir", self.run_dir, "-Wave", wk], timeout=1800)
        if rc == hunt_lib.EXIT_CANNOT_RUN:
            self.findings.append("wave %d: the preaudit battery could not run (exit 2) - a BLOCKED "
                                 "stage, never a pass" % wk)
        return rc

    def mtimes(self, slugs, audit_path):
        out = {}
        paths = [os.path.join(SPECS_DIR, "%s.json" % s) for s in slugs]
        paths.append(os.path.join(MP, "db", "ingredients.json"))
        for p in paths:
            try:
                out[p] = os.path.getmtime(p)
            except OSError:
                out[p] = 0
        # The audit file's own mtime is the reference the workflow's REPAIRCHECK agent compared
        # against; kept so the two implementations mean the same thing by "newer than the audit".
        try:
            out["__audit__"] = os.path.getmtime(audit_path)
        except OSError:
            out["__audit__"] = 0
        return out

    def read_wave(self, out):
        """The wave number, its slug list and its batch id, read from the manifest the script wrote -
        never parsed out of an agent's summary of it."""
        # hunt-run prints "hunt-run: wave <k> closed with <n> recipe(s)  [batch <b>]". Anchored on
        # "closed" on purpose: the same output's "next:" line also carries a wave number, and a
        # loose match would read the advice line when the close itself refused.
        m = re.search(r"wave (\d+) closed", out or "", re.I)
        wk = int(m.group(1)) if m else 0
        if not wk:
            return 0, [], ""
        p = os.path.join(self.run_dir, "waves", "wave-%d.json" % wk)
        try:
            with open(p, "r", encoding="utf-8-sig") as f:
                man = json.load(f)
        except Exception:                                         # noqa: BLE001
            return wk, [], ""
        slugs = [str(s) for s in (man.get("slugs") or [])]
        return wk, slugs, str(man.get("batch") or "%s-w%d" % (self.run_id, wk))

    @staticmethod
    def read_publish(out, slugs):
        text = out or ""
        dry = "DRY RUN" in text
        held = re.findall(r"drafted \+ held\s+(\S+)", text)
        m = re.search(r"propagate carried (\d+) spec", text)
        collateral = int(m.group(1)) if m else 0
        published = [] if dry else [s for s in slugs if s not in held]
        return (slugs if dry else published), held, collateral, dry

    def audit_prompt(self, wk, slugs, batch, scope, why):
        return (
            "Audit wave %d of run %s before it publishes.\n"
            "Run dir: %s\nWave file: %s\\waves\\wave-%d.json\nSlugs: %s\n"
            "scope: %s%s\n\n"
            "The mechanical battery has ALREADY RUN for you; its report is at\n"
            "%s\\waves\\wave-%d.preaudit.json. Exit 2 there is a BLOCKED stage, never a pass. It does\n"
            "not audit and it cannot issue a GO - you remain the authority and may re-derive anything\n"
            "in it.\n\n"
            "This run's conditions: %s\nVerify each recipe's per-serving macros against that in\n"
            "addition to your normal battery.\n\n"
            "Report to %s\\waves\\wave-%d.audit.md. FIRST line exactly GO or NO-GO. SECOND line\n"
            "exactly \"scope: %s\". Return the verdict, the blocking slugs, whether each blocker is\n"
            "recipe-local or shared-data, and the repair owner. The orchestrator stamps the ledger.\n"
            % (wk, self.run_id, self.run_dir, self.run_dir, wk, ", ".join(slugs), scope,
               ("\nReason: " + why) if why else "  (first audit of this wave)",
               self.run_dir, wk, self.conditions, self.run_dir, wk, scope))

    def repair_prompt(self, wk, blockers, audit):
        return (
            "The batch auditor returned NO-GO on wave %d of run %s.\n"
            "Read %s\\waves\\wave-%d.audit.md and repair EXACTLY what it blocks on.\n"
            "Blocking slugs: %s\nAuditor summary: %s\n\n"
            "Repair through the sanctioned path: build-v2-spec.ps1 -InFile %s\\intake\\<slug>.json.\n"
            "Never hand-edit a spec. Never weaken a gate. Report exactly what you changed, per slug,\n"
            "and if nothing needed changing SAY SO explicitly - that is a legitimate answer and it is\n"
            "treated differently from claiming a change that did not happen. The orchestrator checks\n"
            "the files themselves before it pays for a re-audit.\n"
            % (wk, self.run_id, self.run_dir, wk, ", ".join(blockers) or "(whole wave)",
               ((audit or {}).get("summary") or "")[:1500], self.run_dir))

    def review_prompt(self, wk, published, held, collateral, batch):
        return (
            "Post-publish review of run %s wave %d, which just shipped.\n"
            "WAVE SLUGS (%d): %s\n"
            "COLLATERAL carried by propagate: %d additional recipes republished in the same push.\n"
            "Review BOTH numbers: propagate carries every dirty spec by design, so a review scoped to\n"
            "the wave alone samples a fraction of what actually shipped.\n%s"
            "Check live pages, pushed commits, data integrity and gates. Report bugs with fixes.\n"
            "The orchestrator stamps batch %s and advances the verified slugs.\n"
            % (self.run_id, wk, len(published), ", ".join(published), collateral,
               ("Serveability-held: %s - confirm these are DRAFTS, not live, and recorded held.\n"
                % ", ".join(held)) if held else "", batch))

    # ---- resume --------------------------------------------------------------------------------

    def state_of(self, slug):
        p = os.path.join(self.run_dir, "state", "%s.json" % slug)
        try:
            with open(p, "r", encoding="utf-8-sig") as f:
                return (json.load(f) or {}).get("state")
        except Exception:                                         # noqa: BLE001
            return None

    async def status_json(self):
        rc, out, err = await self.ps(HUNT_RUN_PS, ["-Status", "-RunDir", self.run_dir, "-Json"],
                                     timeout=300)
        if rc != 0:
            return None, ((out or "") + (err or "")).strip()[:400]
        try:
            return json.loads(out), ""
        except Exception as e:                                    # noqa: BLE001
            return None, "the -Status JSON did not parse (%s)" % e

    async def seed(self):
        """Section 4.5's resume seed table, NORMATIVE so nobody re-derives it. A recipe enters at the
        lane matching the state it actually stopped at, and flows down from there under its own steam."""
        st, err = await self.status_json()
        if st is None:
            return False, err
        rows = [(r["slug"], hunt_lib.norm_state(r["state"])) for r in (st.get("in_flight") or [])]
        parked = [p["slug"] for p in (st.get("parked") or [])]
        counts = {}

        # `pricing` / `parked`: run -Derive FIRST, then read the state again. Derived counts are the
        # only thing that moves a recipe out of pricing, and seeding off a stale state file would put
        # a recipe back on the price lane the queue has already answered for.
        if parked or any(s == "pricing" for _slug, s in rows):
            await self.ps(HUNT_RUN_PS, ["-Derive", "-RunDir", self.run_dir], timeout=900)
            st, err = await self.status_json()
            if st is None:
                return False, err
            rows = [(r["slug"], hunt_lib.norm_state(r["state"])) for r in (st.get("in_flight") or [])]
            parked = [p["slug"] for p in (st.get("parked") or [])]

        for slug, state in rows:
            self.record(slug, {"slug": slug, "state": state})
            if state in ("sourced", "selected"):
                self.ch["extract"].push(self.rec[slug]); counts["extract"] = counts.get("extract", 0) + 1
            elif state == "extracted":
                self.ch["map"].push(self.rec[slug]); counts["map"] = counts.get("map", 0) + 1
            elif state == "mapped":
                # mapped with open holds: the held list, NOT dispatched.
                self.held.append((slug, "mapped with open holds (unbid or vocabulary follow-ups)"))
            elif state == "pricing":
                self.pricing_slugs.add(slug)
                self.ch["price_wake"].push(slug); counts["price"] = counts.get("price", 0) + 1
            elif state == "priced":
                self.ch["write"].push(self.rec[slug]); counts["write"] = counts.get("write", 0) + 1
            elif state in ("spec-built", "written"):
                self.ch["qa"].push(self.rec[slug]); counts["qa"] = counts.get("qa", 0) + 1
            elif state == "qa-passed":
                self.qa_passed.append(slug); counts["wave"] = counts.get("wave", 0) + 1
            elif state == "waved":
                counts["waved"] = counts.get("waved", 0) + 1
        for slug in parked:
            self.pricing_slugs.add(slug)
            self.ch["price_wake"].push(slug)
            counts["price"] = counts.get("price", 0) + 1
        for slug in (st.get("held") or []):
            self.held.append((slug, "held: a live page that was taken down - never auto-republished"))
        # published-but-not-verified: a post-publish review is pending, and it is not a lane.
        self.review_pending = [s for s in (st.get("published") or [])
                               if self.state_of(s) == "published"]
        # Everything already in flight counts as accepted work in the building, so the WIP limit
        # reflects reality rather than reading zero on a resume.
        for slug, _s in rows:
            if slug not in self.accepted_slugs:
                self.accepted_slugs.append(slug)
        self.seed_counts = counts
        return True, ""

    def status_report(self):
        lines = ["hunt-daemon status: %s" % self.run_id, ""]
        lines.append("  seeded          %s" % (", ".join("%s=%d" % (k, v) for k, v in
                                                         sorted(getattr(self, "seed_counts", {}).items()))
                                               or "(nothing)"))
        lines.append("  accepted        %d" % len(self.accepted_slugs))
        lines.append("  resolved        %d  (%d stuck - no verdict was ever rendered)"
                     % (len(self.outcomes),
                        sum(1 for o in self.outcomes if o.get("status") == "stuck")))
        lines.append("  qa-passed pool  %d" % len(self.qa_passed))
        lines.append("  lane-log lines  %d" % self.lane_lines)
        lines.append("  agent calls     %d" % self.breaker.calls)
        if self.breaker.open:
            lines.append("  BREAKER OPEN    %s" % self.breaker.reason)
        # THE PENDING NARROW PASS. The daemon never starts or stops llama-server, so when the live
        # server shape cannot fit rung 2 the escalations ACCUMULATE and this surface names them. The
        # operator then either restarts the server narrow and lets the daemon drain rung 2 through
        # --from-report, or rules the batch straight to rung 3. Skipping an unavailable rung by
        # OPERATOR RULING is within doctrine; doing it silently is not.
        if self.slot_ctx is not None:
            fits = self.slot_ctx >= local_extract.RUNG2_MIN_SLOT_CTX
            lines.append("  slot context    %s tokens/slot (rung 2 needs ~%d) - %s"
                         % (self.slot_ctx, local_extract.RUNG2_MIN_SLOT_CTX,
                            "rung 2 available" if fits else "RUNG 2 UNAVAILABLE"))
        if self.escalations_blocked:
            lines += ["",
                      "  PENDING NARROW PASS (%d page(s) rung 1 could not settle and this server"
                      % len(self.escalations_blocked),
                      "  shape cannot take to rung 2). Restart llama-server narrow by hand",
                      "  (serve.ps1 -Slots 1) and drain them, or rule the batch straight to rung 3:"]
            for s in self.escalations_blocked:
                lines.append("    %s" % s)
        if self.held:
            lines += ["", "  HELD (reported, never auto-dispatched):"]
            for slug, why in self.held:
                lines.append("    %-38s %s" % (slug, why))
        if self.review_pending:
            lines += ["", "  POST-PUBLISH REVIEW PENDING:"]
            for s in self.review_pending:
                lines.append("    %s" % s)
        if self.findings:
            lines += ["", "  FINDINGS (%d):" % len(self.findings)]
            for f in self.findings:
                lines.append("    %s" % f)
        return "\n".join(lines)

    # ---- the run -------------------------------------------------------------------------------

    # Each lane closes the channel FEEDING the next one when its own input drains, which is what lets
    # a recipe be in QA while another is being extracted. A lane that is switched off must therefore
    # close what it would have closed, or the lane downstream waits on a channel nobody will ever
    # shut - the run hangs instead of exiting, which is B9 wearing a different hat.
    LANE_ORDER = ("pool", "decide", "extract", "map", "price", "write", "qa")
    CLOSES = {"pool": ("decide",), "decide": ("extract",), "extract": ("map",),
              "map": ("price_wake",), "price": ("write",), "write": ("qa",), "qa": ()}
    LANE_FN = {"pool": "pool_lane", "decide": "decide_lane", "extract": "extract_lane",
               "map": "map_lane", "price": "price_lane", "write": "write_lane",
               "qa": "qa_lane"}

    async def run(self, lanes=None):
        lanes = tuple(lanes or self.LANE_ORDER)
        tasks = []
        for name in self.LANE_ORDER:
            if name in lanes:
                tasks.append(getattr(self, self.LANE_FN[name])())
            else:
                for ch in self.CLOSES[name]:
                    self.ch[ch].close()
        await asyncio.gather(*tasks)
        # The drain, ported VERBATIM from the workflow's ending: force-close, await the chain, and
        # one more round if a trim returned clean recipes to the pool. Mid-run waves already ran -
        # the qa lane schedules one whenever the pool fills (see schedule_wave).
        self.schedule_wave(force=True)
        if self._wave_chain is not None:
            await self._wave_chain
        if self.qa_passed:
            self.schedule_wave(force=True)
            if self._wave_chain is not None:
                await self._wave_chain


class RetryLadder(object):
    """ONE CHEAP RETRY BEFORE PAYING ANYTHING MORE (the 2026-08-24 pin).

    Rung 1 at temp 0.1 is not deterministic: a page whose ONE failing line sat at 88% round-trip
    coverage settled on re-run with zero code change, and a different page flipped the other way
    between rounds. So a borderline page is a coin the sweep flips, and one escalation is not a
    permanent property of a URL.

    This WRAPS extract_sweep.Ladder rather than replacing it: the ladder, the contract writer and the
    sweep driver are D6's and stay D6's. All this adds is the re-roll, exactly between rung 1 and
    rung 2, keyed on hunt_lib's constants and the `coverage` field local_extract already puts in each
    escalation failure. ONE retry, never a loop - a second identical failure is the page telling you
    the answer, and ~10 GPU-seconds is only worth spending against a ~50 s rung-2 attempt.
    """

    def __init__(self, inner, daemon=None):
        self.inner = inner
        self.daemon = daemon
        self.retries = 0

    @property
    def allow_rung2(self):
        return self.inner.allow_rung2

    @allow_rung2.setter
    def allow_rung2(self, v):
        self.inner.allow_rung2 = v

    def slot_ctx(self):
        return self.inner.slot_ctx()

    def rung1(self, html, url):
        out = self.inner.rung1(html, url)
        if not out.get("escalate"):
            return out
        eligible, why = hunt_lib.rung1_retry_eligible(out.get("verification") or {})
        if not eligible:
            return out
        self.retries += 1
        if self.daemon is not None:
            self.daemon.log("  rung 1 re-roll (%s): %s" % (why, url))
        second = self.inner.rung1(html, url)
        return second if not second.get("escalate") else out

    def rung2(self, html, url):
        return self.inner.rung2(html, url)


# =====================================================================================================
# main
# =====================================================================================================

def main(argv=None):
    ap = argparse.ArgumentParser(description="the Recipe Hunter daemon (PLAN v3 section 4.1)")
    ap.add_argument("--run-dir", dest="run_dir", default="")
    ap.add_argument("--run", default="")
    ap.add_argument("--conditions", default=DEFAULT_COND)
    ap.add_argument("--cal-min", dest="cal_min", type=int, default=DEFAULT_BAND["calMin"])
    ap.add_argument("--cal-max", dest="cal_max", type=int, default=DEFAULT_BAND["calMax"])
    ap.add_argument("--carb-max", dest="carb_max", type=int, default=DEFAULT_BAND["carbMax"])
    ap.add_argument("--wave-size", dest="wave_size", type=int, default=hunt_lib.WAVE_SIZE)
    ap.add_argument("--target", type=int, default=0,
                    help="stop popping the pool after N acceptances; 0 pops until the backlog runs "
                         "dry or the WIP limit parks the lane")
    ap.add_argument("--lanes", default="pool,decide,extract,map,price,write,qa")
    ap.add_argument("--ledger", default="",
                    help="a scratch batch ledger, for a drill. Empty means the live one.")
    ap.add_argument("--publish", action="store_true",
                    help="publish for real. WITHOUT this the wave lane runs wave-publish -DryRun.")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)

    if a.selftest:
        import hunt_daemon_selftest                               # noqa: PLC0415
        return hunt_daemon_selftest.run()

    if not a.run_dir or not os.path.isdir(a.run_dir):
        say("hunt-daemon: CANNOT RUN - no run dir at %r" % a.run_dir)
        say("HUNT-DAEMON-COMPLETE")
        return hunt_lib.EXIT_CANNOT_RUN

    d = Daemon(a.run_dir, a.run or os.path.basename(a.run_dir), a.conditions,
               {"calMin": a.cal_min, "calMax": a.cal_max, "carbMax": a.carb_max},
               a.wave_size, target=a.target, dry_run_publish=not a.publish, ledger_path=a.ledger)

    async def go():
        ok, err = await d.seed()
        if not ok:
            say("hunt-daemon: CANNOT RUN - %s" % err)
            return hunt_lib.EXIT_CANNOT_RUN
        if a.status:
            say(d.status_report())
            return hunt_lib.EXIT_FINDINGS if d.findings else hunt_lib.EXIT_CLEAN
        say("hunt-daemon: %s  lanes %s  publish %s"
            % (d.run_id, a.lanes, "LIVE" if a.publish else "DRY RUN"))
        await d.run(tuple(x.strip() for x in a.lanes.split(",") if x.strip()))
        say("")
        say(d.status_report())
        return hunt_lib.EXIT_FINDINGS if d.findings else hunt_lib.EXIT_CLEAN

    rc = asyncio.new_event_loop().run_until_complete(go())
    say("HUNT-DAEMON-COMPLETE")
    return rc


if __name__ == "__main__":
    sys.exit(main())
