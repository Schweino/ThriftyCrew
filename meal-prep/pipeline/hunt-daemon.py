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
import price_evidence                                            # noqa: E402

HUNT_RUN_PS = os.path.join(HERE, "hunt-run.ps1")
INGREDIENT_QUEUE_PS = os.path.join(REPO, "grocery", "ingredient-queue.ps1")
PROBE_INGREDIENT_PS = os.path.join(REPO, "grocery", "probe-ingredient.ps1")
PULL_BROWSER_STORES_PY = os.path.join(REPO, "grocery", "pull-browser-stores.py")
# 25 s/request x ladder rungs x 2 stores x up to 10 terms. One call for the whole batch.
PROBE_TIMEOUT = 900
# The driver's OWN --timeout-min default. Pacing dominates a browser sweep and that is the price of
# not tripping a wall; a subprocess timeout under it would kill a healthy lane mid-sweep.
LOOKUP_TIMEOUT_MIN = 40
LOOKUP_TIMEOUT = LOOKUP_TIMEOUT_MIN * 60 + 300
MAP_PRERESOLVE_PS = os.path.join(HERE, "map-preresolve.ps1")
BUILD_SKELETON_PS = os.path.join(HERE, "build-intake-skeleton.ps1")
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


def as_text(v, cap=0):
    """A report field the schema no longer constrains, rendered for a place that needs text.

    `detail` and `macro_cross_check` arrive as prose or as an object (see hunt_lib.MAPPED's note - a
    live batch bought a whole second session over that shape check). Every consumer here wants a
    string for a log line or a state-file detail, so the conversion happens once, in one place.
    """
    if v is None:
        return ""
    t = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
    return t[:cap] if cap else t


def say(m):
    r"""MEASURED ON THE PHASE-6A GATE DRILL, 2026-08-24, and it killed the run.

    A STUCK message quoted an ingredient line carrying U+FFFD - the replacement character an
    extraction picks up from a mojibake'd source page ("1 pound boneless (skinless chicken breasts,
    cut into �-inch strips)"). Windows' console encoding is cp1252, `print` raised
    UnicodeEncodeError inside the log call, the exception escaped through asyncio.gather, and the
    daemon died AFTER a live 15-minute mapper dispatch had already been paid for - with the second
    recipe of the batch never assembled.

    A LOG LINE MUST NOT BE ABLE TO END A RUN. The recipe corpus is full of source text this estate
    does not control, and the whole point of the STUCK message is to be readable when something has
    gone wrong. So the undrawable characters are replaced and the sentence still gets printed.
    """
    try:
        print(m, flush=True)
    except UnicodeEncodeError:
        enc = getattr(sys.stdout, "encoding", None) or "ascii"
        print(str(m).encode(enc, errors="replace").decode(enc, errors="replace"), flush=True)


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
                 quiet=False, ledger_path="", preresolve_args=(), specs_dir="",
                 costed_path="", pyrun=None):
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
        # A SCRATCH SPEC STORE AND A SCRATCH COST LEDGER, for exactly the reason ledger_path exists.
        # The phase-3 drain drill wrote two stalled rows into the LIVE batch ledger before --ledger
        # existed; the write lane can do the same to db\recipes and db\costed.json, which are read by
        # the live site's own pipeline. Empty means the real ones, which is what a real run wants.
        # NOTE the coupling, which is build-v2-spec's rule and not ours: `-RunCost` is refused unless
        # OutDir IS the real db\recipes, because cost-recipes reads its specs from there. So a scratch
        # spec store means an UNCOSTED spec, and the daemon says so in the log rather than quietly
        # producing a spec whose cost block is zeros and letting a reader assume it was priced.
        self.specs_dir = specs_dir
        self.costed_path = costed_path
        self.pool_path = pool_path or harvest.POOL
        self.quiet = quiet
        # A TEST SEAM, and the ONLY thing it may ever carry is a path: extra arguments appended to
        # every map-preresolve call so a fixture can point its composed lookups (vocabulary, prior
        # rulings, board) at scratch files instead of the live estate. No production caller passes it.
        # It exists because the unhold fixture has to WIRE A BID between two seeds and watch the hold
        # clear, and doing that against db\ingredients.json would mean a fixture that edits the live
        # vocabulary. Behaviour is never switched here - only where the lookups live.
        self.preresolve_args = list(preresolve_args or ())

        # INJECTED, so every fixture below runs for zero tokens and zero shell.
        self._dispatch = dispatcher or hunt_dispatch.dispatch
        self._ps = ps or hunt_lib.ps_invoke
        # And one for PYTHON surfaces. pull-browser-stores.py is Python, so it goes through
        # sys.executable, never through ps_invoke - ps_invoke is for PowerShell and its whole reason
        # for existing (array marshalling through -Command) does not apply and would not survive.
        self._py = pyrun or hunt_lib.py_invoke

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

    async def py(self, script, args, timeout=600):
        """EVERY Python surface goes through hunt_lib.py_invoke, for the same one-road reason `ps`
        exists - and never through ps_invoke, which would try to marshal a Python script as a
        PowerShell command line."""
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, lambda: self._py(script, args, timeout))

    async def lane(self, lane_name, label, items, by, event, tokens_in=-1, tokens_out=-1,
                   detail="", cache_read=-1, cache_creation=-1, calls=-1,
                   all_in=-1, all_out=-1, models="", api_turns=-1):
        """A lane-log line. BOTH ENDS, always: the daemon owns a real clock, so start/end pairing is
        what finally makes stage duration measurable. Section 4.5's completeness rule covers local
        work too - a page settled by the local ladder is work done, not work skipped."""
        args = ["-Lane", "-RunDir", self.run_dir, "-LaneName", lane_name, "-Label", label,
                "-Items", list(items or []), "-By", by, "-Event", event,
                "-InputTokens", tokens_in, "-OutputTokens", tokens_out,
                # C1: turns and the cache split, so no future run needs transcript archaeology to
                # answer "where did the money go". -1 stays "not reported", which is not 0.
                "-CacheRead", cache_read, "-CacheCreation", cache_creation, "-Calls", calls,
                # F (2026-08-24): the API ROUND TRIPS, which is what actually drives cost - each one
                # re-reads the whole conversation. `-Calls` is billed CLI invocations and stays that.
                "-ApiTurns", api_turns,
                "-AllModelsIn", all_in, "-AllModelsOut", all_out]
        if models:
            args += ["-Models", models]
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
        all_in, all_out, _cost, models = res.all_models
        await self.lane(lane_name, label, items, stage or lane_name, "end",
                        tokens_in=res.tokens_in, tokens_out=res.tokens_out,
                        cache_read=res.cache_read, cache_creation=res.cache_creation,
                        calls=res.calls, api_turns=res.api_turns,
                        all_in=all_in, all_out=all_out,
                        models=",".join(models),
                        detail=("re-asked; " if res.reasked else "")
                        + (res.failure or "ok"))
        # THE UNSTAMPED-SUBAGENT GAP, MADE VISIBLE RATHER THAN LEFT TO ARCHAEOLOGY. The phase-5 mapper
        # delegated to a 21-turn Opus subagent that appeared in no ledger at all. It is a FINDING, not
        # a refusal: delegation may be legitimate, and what was wrong was that nobody could see it.
        #
        # THE THRESHOLD IS THE CORRECTION, and the phase-6a gate drill earned it: this fired on ALL
        # THREE dispatches of a clean run, at deltas of 37, 19 and 18 tokens. That is not delegation,
        # it is the auxiliary haiku call the CLI bills alongside every headless invocation for its own
        # housekeeping - hunt_dispatch's own header measures it at ~450 input tokens. A finding on
        # every call is noise, and noise is what a reader learns to skip, which would have buried the
        # $1.64 subagent this exists to surface. A real delegation is a SESSION, not a rounding error:
        # the phase-5 one was 21 turns and thousands of output tokens.
        delegated = all_out - res.tokens_out
        if all_out > 0 and res.tokens_out > 0 and delegated > max(500, 0.05 * res.tokens_out):
            self.findings.append(
                "%s/%s: this dispatch billed %d output tokens MORE than its own session (%d across %s "
                "vs %d for the main agent). That difference is delegation, and it used to appear in "
                "no ledger." % (lane_name, label, int(delegated), all_out,
                                "/".join(models) or "?", res.tokens_out))
        # A RE-ASK THAT SUCCEEDS COSTS A WHOLE SECOND SESSION AND USED TO LEAVE NO RECORD OF WHY.
        # Measured on the phase-6a gate drill: a live mapper batch came back `re-asked; ok`, and the
        # violation that caused it - "payload is missing required field `results`" - existed only in a
        # headless transcript nobody keeps. That is the single most expensive RECOVERABLE defect in
        # this pipeline and it was invisible, which is exactly what C1 exists to end.
        if res.reasked and res.ok and res.problems:
            self.findings.append(
                "%s/%s: RE-ASKED and then succeeded, at the price of a second session. The first "
                "answer's violations were: %s" % (lane_name, label, "; ".join(res.problems)[:400]))
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

    # "Beyond any real dish" thresholds. A band stated wider than these cannot reject anything, so it
    # is not a constraint - it is a run saying out loud that it has no limit. Named rather than
    # inlined so the two places that ask "is this band actually limiting anything" cannot drift.
    NO_CAL_LIMIT = 10000        # cal per serving
    NO_CARB_LIMIT = 1000        # g per serving

    def band_constrains_anything(self):
        return (self.band.get("calMin", 0) > 0
                or self.band.get("calMax", 0) < self.NO_CAL_LIMIT
                or self.band.get("carbMax", 0) < self.NO_CARB_LIMIT
                or bool(self.band.get("proteinMin")))

    def candidate_in_band(self, cand):
        """Does THIS candidate's harvested nutrition meet THIS RUN's band? Selection, not retirement:
        a number that is missing or unverified cannot confirm the band, so the candidate waits. The
        pool records `verified` False whenever any macro had to be inferred, and an inferred number is
        not evidence that a dish clears a 50 g protein floor."""
        b = cand.get("band") or {}
        # A BAND THAT CONSTRAINS NOTHING VERIFIES NOTHING (2026-08-24). The `verified` requirement
        # exists because an inferred number is not evidence that a dish clears a 50 g floor - it is
        # about TRUSTING a number we are about to rely on. A run stated with no effective limits relies
        # on no number, so demanding verification would exclude 280 candidates on a technicality while
        # nothing was being checked. Those 280 are exactly the pages with no JSON-LD block at all, so
        # this is the difference between a no-band run seeing the whole pool and seeing half of it.
        if not self.band_constrains_anything():
            return True
        if not b.get("verified"):
            return False
        cal, carbs, prot = b.get("cal"), b.get("carbs"), b.get("protein_g")
        if not _is_num(cal) or not _is_num(carbs):
            return False
        if cal < self.band["calMin"] or cal > self.band["calMax"]:
            return False
        if carbs > self.band["carbMax"]:
            return False
        floor = self.band.get("proteinMin")
        if floor:
            if not _is_num(prot) or prot < floor:
                return False
        return True

    def pop_dossiers(self, n):
        """Build the next N dossiers, in harvest's own pop order. READ-ONLY: harvest.py is the pool's
        sole writer, and `--mark-taken` is a separate act performed at dispatch time. A dossier that
        was built and never dispatched must not strand its candidates as taken."""
        pool = harvest.read_pool(self.pool_path)
        avail = [c for c in pool["candidates"] if c.get("status") == "available"
                 and c["slug"] not in self.seen_candidates]
        if not avail:
            return []
        # THE POP IS FILTERED BY THE RUN'S OWN BAND (found 2026-08-24, before the 6b proving run, and
        # it would have wrecked the run's headline number). `available` means "passed the band that was
        # HARD-CODED IN harvest.py AT INGEST TIME" - 400-650 cal, <= 35 carbs, no protein rule at all.
        # It does NOT mean "passes the band this run stated". This pop ignored the run band entirely, so
        # a run at 500-650 cal / <= 40 carbs / >= 50 g protein would have popped in dossier_rank order
        # and let the DECIDER discover the mismatch - measured against the live pool: 2 of the first 10
        # and 3 of the first 20 pops qualified, so reaching 20 acceptances meant paying an Opus decider
        # roughly 66 times to reject candidates one line of arithmetic kills. Section 2's PLANE 1 puts
        # band filtering in mechanics, "instant"; this is that line.
        #
        # STRICTER THAN THE GATE, AND DELIBERATELY SO. hunt_lib.in_band passes an unreported macro,
        # because it is a RETIREMENT gate and must never retire a dish on a number nobody read. This is
        # a SELECTION filter over a backlog of hundreds: a candidate whose numbers cannot confirm it
        # meets the run's band is simply not the next one to spend a decider on.
        avail = [c for c in avail if self.candidate_in_band(c)]
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
                        "domain": c.get("domain"), "dossier": d,
                        # D7: the SOURCE PAGE'S OWN CLAIM, carried so the band gate can record it
                        # beside our recompute. It is the pool's harvested `band` verbatim - the
                        # publisher's numbers at the publisher's serving count - and nothing rules on
                        # it downstream. See record_band_pair.
                        "source_band": dict(c.get("band") or {}),
                        "source_servings": c.get("servings")})
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

        # A (2026-08-24, off the 6b run). THE MAP LANE'S BATCH SIZE IS DECIDED HERE, ON THE PRODUCER
        # SIDE, AND NEVER BY MAKING THE CHANNEL WAIT.
        #
        # MEASURED: 6b's mapper ran map:1x, map:1x, map:5x, map:2x. The two singletons cost 436,685 and
        # 577,141 input tokens and 378 s FOR ONE RECIPE EACH, against map:5x at 212,244 and 167 s per
        # recipe. Cause: extraction settles pages SERIALLY by design, so they trickled into the map
        # channel one at a time and take_batch correctly swept whatever was queued.
        #
        # THE TRAP, AND WHY THIS IS NOT IT. `Chan.take_batch` must NEVER wait to fill a quota - that
        # policy was measured (B3) deadlocking against the WIP limit and adding 8-10 minutes to first
        # flow, and its docstring says so. Nothing here changes the channel. This holds settled pages on
        # the PRODUCER side and flushes on three conditions, one of which is always eventually true:
        #
        #   1. the group reaches MAP_BATCH                        - the batch is as big as it may be
        #   2. NOTHING IS QUEUED FOR EXTRACTION RIGHT NOW         - the anti-deadlock condition
        #   3. the input channel is exhausted (the finally below) - the run is draining
        #
        # (2) is the one that makes a hang impossible. It asks the queue's CURRENT depth, never a
        # future one, so a lone recipe is flushed the instant it settles and behaves exactly as today.
        # Waiting only ever happens while pages are ALREADY queued behind this one, which is precisely
        # the case that produced the two singletons. No promise, no timer, nothing to wake.
        pending = []

        async def flush_pending(why):
            if not pending:
                return
            for rec in pending:
                self.ch["map"].push(rec)
            self.log("extract: released %d settled recipe(s) to the map lane (%s)"
                     % (len(pending), why))
            pending.clear()

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
                        pending.append(self.record(rec["slug"], {"state": "extracted"}))
                        # Flush on size, or the instant nothing else is queued behind this one. Asking
                        # the CURRENT depth is what keeps this from ever being a wait.
                        if len(pending) >= hunt_lib.MAP_BATCH:
                            await flush_pending("batch full")
                        elif self.ch["extract"].size() == 0:
                            await flush_pending("nothing else queued for extraction")
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
                # THE THIRD FLUSH, AND THE ONE THAT MAKES A HELD RECIPE IMPOSSIBLE TO STRAND. Every
                # exit from the loop above runs this - input exhausted, breaker open, or an exception -
                # so a settled recipe can never be left holding in `pending` while the run drains.
                await flush_pending("extraction lane closing")
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

    # ---------------------------------------------------------------------------------------------
    # D7: THE MECHANICAL HALF OF MAP. map-preresolve.ps1 answers everything that does not need
    # judgment BEFORE the agent is paid, and the daemon reads its table.
    # ---------------------------------------------------------------------------------------------

    async def preresolve(self, slugs):
        """Run map-preresolve over a micro-batch and read back its per-slug tables.

        THE EXIT CODES MEAN WHAT SECTION 4.5 SAYS AND NOTHING ELSE, and 1 is the NORMAL case:
          0  every line pre-resolved. The mapper is STILL dispatched - the macro cross-check is its
             job on every recipe, so this shrinks the dispatch, it never skips the judge.
          1  residual lines exist. Dispatch proceeds over the residual. A healthy batch looks like this.
          2  BLOCKED. The batch is NOT dispatched. Could-not-look is never a clean bill.
        Returns (ok, tables, detail).
        """
        rc, out, err = await self.ps(MAP_PRERESOLVE_PS,
                                     ["-RunDir", self.run_dir, "-Slugs", list(slugs)]
                                     + self.preresolve_args, timeout=1200)
        detail = ((out or "") + (err or "")).strip()
        if rc == hunt_lib.EXIT_CANNOT_RUN:
            return False, {}, detail[-400:]
        tables = {}
        for slug in slugs:
            path = os.path.join(self.run_dir, "mapped-pre", "%s.json" % slug)
            try:
                with open(path, "r", encoding="utf-8-sig") as f:
                    tables[slug] = json.load(f)
            except Exception as e:                                # noqa: BLE001
                # The script said it ran and the table is not there. That is not a clean bill either.
                return False, {}, "no pre-resolve table for %s (%s)" % (slug, e)
        return True, tables, detail[-400:]

    HOLD_FILE_DOC = ("The mapper's routing for a recipe the daemon HELD at `mapped`. Written by the "
                     "daemon, read by the next seed's unhold. Without it a repaired recipe could only "
                     "be re-mapped, which is paying an agent twice for one judgment.")

    def write_hold_record(self, slug, res, holds):
        """The routing a held recipe would have taken, parked where the next seed can find it.

        WHY THIS FILE EXISTS AT ALL. The unhold path re-runs map-preresolve at seed time and advances a
        cleared recipe "exactly as it would have on first pass" - but first pass's routing came from the
        MAPPER's absent_terms, and a held recipe never reached the branch that consumes them. A fresh
        daemon process has no memory of it. Without this record the only ways to resume a repaired
        recipe are to re-dispatch the mapper (paying twice for a judgment already rendered) or to guess
        its routing from the decision file (which is how a recipe skips pricing). So the daemon writes
        down what it was about to do, and the seed does it.
        """
        path = os.path.join(self.run_dir, "mapped-pre", "%s.hold.json" % slug)
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"_doc": self.HOLD_FILE_DOC, "slug": slug,
                           "held_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                           "absent_terms": [t for t in (res.get("absent_terms") or []) if t],
                           "optional_absent": [t for t in (res.get("optional_absent") or []) if t],
                           "mapper_state": hunt_lib.norm_state(res.get("state")),
                           "mapper_detail": (res.get("detail") or "")[:400],
                           "holds": holds}, f, indent=2)
        except Exception as e:                                    # noqa: BLE001
            self.findings.append("%s: could not write the hold record (%s) - a repaired recipe would "
                                 "have to be re-mapped" % (slug, e))

    def read_hold_record(self, slug):
        path = os.path.join(self.run_dir, "mapped-pre", "%s.hold.json" % slug)
        try:
            with open(path, "r", encoding="utf-8-sig") as f:
                return json.load(f)
        except Exception:                                         # noqa: BLE001
            return None

    async def unhold_mapped(self, slugs):
        """THE UNHOLD PATH (D7's pin). At seed time the daemon re-runs map-preresolve over the recipes
        sitting at `mapped` - mechanical, zero agents, seconds - and a hold that has CLEARED advances
        through the mapper decision file that is already on disk. Its term set was ruled once and is
        not re-ruled: no agent is paid twice for one judgment.

        The seed table alone would strand a repaired recipe forever. It seeds `mapped`-with-holds to
        the HELD list, which is right while the hold stands and a trap the moment Brad wires the
        missing bid: on the next resume the recipe lands back on the held list with nobody re-checking
        anything. This is the re-check.
        """
        if not slugs:
            return 0
        ok, tables, detail = await self.preresolve(sorted(slugs))
        if not ok:
            for slug in sorted(slugs):
                self.held.append((slug, "mapped, and the hold could not be re-checked: %s" % detail[:160]))
            return 0
        advanced = 0
        for slug in sorted(slugs):
            holds = (tables.get(slug) or {}).get("holds") or []
            if holds:
                self.held.append((slug, holds[0].get("why") or "an unbid ingredient still has no bid"))
                continue
            decision = os.path.join(self.run_dir, "mapped", "%s.json" % slug)
            if not os.path.exists(decision):
                # The unhold advances ON the mapper's ruling. No ruling file, no advance: a recipe at
                # `mapped` whose decision file is missing was never actually mapped, and advancing it
                # would be inventing the judgment this path exists to avoid re-buying.
                self.held.append((slug, "mapped, but there is no mapper decision file at "
                                        "mapped\\%s.json - the ruling this would advance on does not "
                                        "exist" % slug))
                continue
            rec = self.read_hold_record(slug)
            if rec is None:
                # NEVER GUESS THE ROUTING. A recipe at `mapped` with no hold record is a recipe this
                # daemon did not hold - a hand-advanced state, or a run from before this file existed.
                # Re-dispatching the mapper would pay twice and inventing a route could skip pricing.
                self.held.append((slug, "mapped with no hold record - nothing on disk says whether its "
                                        "terms were all answered, so it needs a look, not a guess"))
                continue
            absent = [t for t in (rec.get("absent_terms") or []) if t]
            optional = [t for t in (rec.get("optional_absent") or []) if t]
            self.log("unhold: %s - the bid is wired, advancing on the mapper ruling already on disk "
                     "(zero dispatches)" % slug)
            if not absent and rec.get("mapper_state") == "priced":
                await self.advance(slug, "priced", "unhold",
                                   "hold cleared: every term answered from the board")
                self.ch["write"].push(self.record(slug, {"state": "priced"}))
            else:
                for t in absent:
                    await self.ps(INGREDIENT_QUEUE_PS,
                                  ["-Add", "-Term", t, "-Recipe", slug,
                                   "-Why", "%s needs it" % slug], timeout=180)
                    if t not in self.absent_terms and t not in self.priced_terms:
                        self.absent_terms.append(t)
                await self.advance(slug, "pricing", "unhold", "hold cleared",
                                   terms=absent, optional_terms=optional)
                self.pricing_slugs.add(slug)
                self.record(slug, {"state": "pricing", "absent": absent})
                self.ch["price_wake"].push("unhold of %s" % slug)
            advanced += 1
        return advanced

    async def registrar_rulings(self, slug, proposals, tables=None):
        """A4 / pin P6. Dispatch commodity-registrar on each NEW-id proposal; return its rulings.

        WHY THE DAEMON HOLDS THIS ROAD NOW. A3 strips the `Agent` tool from the mapper (the phase-5
        batch spawned a 21-turn Opus subagent that appears in NO lane stamp - $1.64 of invisible
        spend, which is exactly the class C1 exists to end). But the mapper's own definition orders
        every new commodity id "through the commodity-registrar gate", and that consult rides the
        Agent tool: frontmatter `tools:` cannot scope WHICH subagents are reachable, so stripping
        Agent severs the road. Rebuilding it here makes the consult a STAMPED dispatch on its own
        pin (fable/medium, read from the frontmatter as every dispatch is) instead of an invisible
        one, which is a gain rather than a workaround.

        A REGISTRAR THAT DOES NOT ANSWER IS NOT AN APPROVAL. A null comes back as no ruling at all,
        and the assembler refuses a new id nothing approved - silence is not consent about whether a
        commodity is born, and a duplicate id lets the same food carry two disagreeing prices while
        every per-file guard reads green (bread-crumbs vs breadcrumbs, 2.9x apart across two boards).
        """
        out = []
        seen = set()
        table = (tables or {}).get(slug) or {}
        rows = table.get("rows") or []
        for prop in (proposals or []):
            bid = str((prop or {}).get("proposed_bid") or "").strip()
            term = str((prop or {}).get("term") or "").strip()
            if not bid or bid in seen:
                continue
            seen.add(bid)
            row = next((r for r in rows if str(r.get("term") or "") == term), None)
            payload = await self.dispatch(
                "commodity-registrar",
                self.registrar_prompt(slug, term, bid, str((prop or {}).get("evidence") or ""), row),
                "map", "registrar:%s" % bid, [slug],
                schema=hunt_lib.REGISTRAR, validator=hunt_lib.validate_registrar,
                stage="registrar")
            if payload is None:
                self.findings.append("map/%s: the commodity-registrar returned no verdict on the "
                                     "proposed id '%s' - the line stays unsettled, which is the safe "
                                     "direction" % (slug, bid))
                continue
            out.append({"proposed_bid": bid,
                        "verdict": str(payload.get("verdict") or "").strip().lower(),
                        "bid": str(payload.get("bid") or "").strip(),
                        "reason": str(payload.get("reason") or "")})
        return out

    # -----------------------------------------------------------------------------------------------
    # B (2026-08-24, off the 6b run). THE REGISTRAR IS HANDED ITS EVIDENCE, exactly as the decider is
    # handed its dossier - and for exactly the reason the decider is the cheapest agent in the estate.
    #
    # MEASURED: 8 registrar dispatches on the 6b run cost ~797,000 tokens, 58k-227k each, at 7-16 tool
    # calls each, dominated by Grep 4-9 times over the three commodity namespaces. Meanwhile the
    # ORCHESTRATOR has already read all three - that is how the new-id proposal list is derived and how
    # the gate became unskippable-by-omission in 6a. It read the files, threw the read away, and paid a
    # Fable session to grep them again. The mapper's own definition already states the principle this
    # violated: "THE TABLE IS THE ESTATE, ALREADY READ FOR YOU... Each re-read costs a turn, and a turn
    # re-reads the entire accumulated context with it."
    #
    # ROWS AND NEAR-MISSES, NEVER A CONCLUSION. This hands over candidate rows and says they are a
    # starting point; the registrar keeps its tools, still rules, and is told in as many words that the
    # list is not exhaustive. Giving a gate MORE evidence is the opposite of weakening it - handing it
    # an ANSWER would be - so this deliberately stops at the rows.
    # -----------------------------------------------------------------------------------------------

    COMMODITY_FILES = (("grocery/commodities.json", "commodities"),
                       ("grocery/recipe-commodities.json", "recipe-commodities"),
                       ("grocery/out/recipe-board-everyday.json", "recipe-board-everyday"))

    def commodity_rows(self):
        """Every id across the three namespaces, with its label and where it lives. Cached per run -
        these files do not change under a hunt, and re-reading 816 rows per registrar call is the very
        waste this exists to remove."""
        if getattr(self, "_commodity_rows", None) is not None:
            return self._commodity_rows
        out = []
        for rel, ns in self.COMMODITY_FILES:
            path = os.path.join(REPO, rel.replace("/", os.sep))
            try:
                with open(path, "r", encoding="utf-8-sig") as f:
                    doc = json.load(f)
            except Exception:                                     # noqa: BLE001
                continue
            rows = doc
            if isinstance(doc, dict):
                for k in ("commodities", "comparison", "items", "rows"):
                    if isinstance(doc.get(k), list):
                        rows = doc[k]
                        break
            for r in (rows if isinstance(rows, list) else []):
                if not isinstance(r, dict):
                    continue
                rid = str(r.get("id") or r.get("bid") or r.get("commodity_id") or "").strip()
                if not rid:
                    continue
                out.append({"id": rid,
                            "label": str(r.get("label") or r.get("commodity") or "").strip(),
                            "ns": ns,
                            "include": str(r.get("include") or "")})
        self._commodity_rows = out
        return out

    @staticmethod
    def _id_tokens(text):
        return set(t for t in re.split(r"[^a-z0-9]+", str(text or "").lower()) if len(t) > 2)

    def commodity_near_misses(self, term, bid, cap=12):
        """Rows whose id, label or include-pattern shares a food word with the proposal, ranked by
        overlap. A LEAD LIST, not a verdict."""
        want = self._id_tokens(term) | self._id_tokens(bid)
        if not want:
            return []
        scored = []
        for r in self.commodity_rows():
            have = self._id_tokens(r["id"]) | self._id_tokens(r["label"])
            n = len(want & have)
            if not n:
                # An include pattern that literally names the term still counts: it is how the board
                # silently absorbs a food under another id (chicken-thighs matching 'drumstick'), and
                # that is precisely what the registrar is here to catch.
                inc = str(r.get("include") or "").lower()
                if inc and any(w in inc for w in want):
                    n = 1
            if n:
                scored.append((n, r))
        scored.sort(key=lambda x: (-x[0], x[1]["id"]))
        return [r for _n, r in scored[:cap]]

    NOT_EXHAUSTIVE = (
        "This list is mechanical and NOT exhaustive: it matches on shared words, so a food priced under\n"
        "an unrelated NAME will not appear here, and an include-pattern match is a LEAD rather than a\n"
        "ruling - the board's `chicken-thighs` include pattern matches 'drumstick' and prices a different\n"
        "cut. Look further whenever the food could plausibly be carried under another word.\n")

    def registrar_evidence_block(self, term, bid):
        near = self.commodity_near_misses(term, bid)
        head = ("\nWHAT THE THREE COMMODITY NAMESPACES ALREADY CARRY - ALREADY READ FOR YOU.\n"
                "%d ids across %s. Below are the rows whose id, label or include-pattern shares a food\n"
                "word with this proposal, ranked by overlap. Re-reading these files costs you a turn, and\n"
                "a turn re-reads your whole context, so start here.\n"
                % (len(self.commodity_rows()), ", ".join(ns for _f, ns in self.COMMODITY_FILES)))
        if not near:
            return head + ("    (nothing in any namespace shares a food word with this term - which is\n"
                           "     EVIDENCE FOR a new id, not proof of one)\n") + self.NOT_EXHAUSTIVE
        lines = "".join("    %-34s %-30s [%s]%s\n"
                        % (r["id"][:34], (r["label"] or "(no label)")[:30], r["ns"],
                           ("  include=" + r["include"][:44]) if r["include"] else "")
                        for r in near)
        return head + lines + self.NOT_EXHAUSTIVE

    def registrar_prompt(self, slug, term, bid, evidence, row=None):
        near = ""
        if row:
            near = "\nWhat the mechanical pre-resolve found for this line:\n    %s\n" % (
                (row.get("evidence") or "")[:600])
        return (
            "Rule on ONE proposed new grocery commodity id, for the recipe `%s`.\n\n"
            "  ingredient line : %s\n"
            "  proposed id     : %s\n"
            "  the mapper's case: %s\n%s%s\n"
            "This is the gate before the id is born. Prove the food is not already priced under\n"
            "another name across all three id namespaces and the live feed, rule variant-vs-duplicate\n"
            "on the evidence, and answer:\n"
            "  approve  a genuinely new id, and `bid` is the id to mint\n"
            "  alias    it is already priced under another id, and `bid` is THAT EXISTING id\n"
            "  reject   it should not be minted and no existing id fits either\n\n"
            "`reason` is the sentence a person reads when this blocks a recipe, so make it the\n"
            "evidence rather than the conclusion. A reject leaves the ingredient line UNSETTLED and\n"
            "the recipe STUCK carrying your sentence - which is the right outcome when the honest\n"
            "answer is no, and an expensive one when it is guesswork.\n"
            % (slug, term or "(the mapper did not name the term)", bid,
               evidence or "(none given)", near, self.registrar_evidence_block(term, bid)))

    async def assemble_mapped(self, slug, res, tables=None):
        r"""A1 / pins P2-P6. Build `<RunDir>\mapped\<slug>.json` from the table plus the mapper's two
        arrays. Returns (ok, why_not).

        THE DAEMON HOLDS THE PEN, and that is the whole point rather than a tidy-up. On the phase-5
        gate run the mapper wrote that file itself, in the PRE-RESOLVE TABLE'S shape, and
        build-intake-skeleton.ps1 exited 1 with "the mapper decision file names no mapped ingredient"
        over a recipe it had just settled cleanly. The daemon routed correctly regardless (it reads
        the dispatch payload, not the file), so the defect was invisible until something tried to READ
        the file - a whole stage later, with the prose already paid for.
        """
        proposals = res.get("new_commodity_proposals") or []
        rulings = await self.registrar_rulings(slug, proposals, tables)
        payload = {
            "slug": slug,
            "lines": res.get("lines") or [],
            "rulings": res.get("rulings") or [],
            "absent_terms": [t for t in (res.get("absent_terms") or []) if t],
            "db_entries_added": res.get("db_entries_added") or [],
            "rejected": res.get("rejected") or [],
            "ruled_substitutions": res.get("ruled_substitutions") or [],
            "new_commodity_proposals": proposals,
            "registrar_rulings": rulings,
            # kept in whatever shape it arrived: the mapped file is read by people and by the
            # auditor, and an object is the richer artifact. Only the log lines need text.
            "macro_cross_check": res.get("macro_cross_check") or res.get("detail") or "",
        }
        # ONE WRITER PER SLUG - the map lane's workers never share a slug - so no mutex, exactly as
        # map-preresolve's own header says about the table beside it.
        out_dir = os.path.join(self.run_dir, "mapped-pre")
        try:
            if not os.path.isdir(out_dir):
                os.makedirs(out_dir, exist_ok=True)
            path = os.path.join(out_dir, "%s.rulings.json" % slug)
            with open(path, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False, indent=1)
        except Exception as e:                                    # noqa: BLE001
            return False, "the mapper's rulings could not be written to disk (%s)" % e
        args = ["-Assemble", "-RunDir", self.run_dir, "-Slug", slug, "-RulingsFile", path]
        args += list(self.preresolve_args)
        rc, out, err = await self.ps(MAP_PRERESOLVE_PS, args, timeout=600)
        text = ((out or "") + (err or "")).strip()
        if rc == hunt_lib.EXIT_CLEAN:
            return True, ""
        found = [ln.strip() for ln in text.replace("\r", "").split("\n")
                 if ln.strip().startswith("FINDING")]
        why = "; ".join(found)[:500] if found else text[-400:]
        if rc == hunt_lib.EXIT_CANNOT_RUN:
            return False, ("mapped\\%s.json could not be assembled at all (exit 2): %s" % (slug, why))
        return False, ("the mapper's rulings do not assemble into a decision file: %s" % why)

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
                # D7: THE MECHANICAL PASS RUNS FIRST, AND EXIT 2 BLOCKS THE BATCH.
                ok, tables, why = await self.preresolve(slugs)
                if not ok:
                    for b in batch:
                        self.stuck(b["slug"], "map",
                                   "map-preresolve exit 2 - BLOCKED, never dispatched: %s" % why[:200])
                    self.findings.append("map: a micro-batch of %d was blocked by map-preresolve (%s)"
                                         % (len(slugs), why[:160]))
                    continue
                r = await self.with_retry(
                    lambda: self.dispatch("recipe-ingredient-mapper", self.map_prompt(slugs, tables),
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
                                    as_text(res.get("detail")) or "mapper rejected")
                        await self.advance(b["slug"], state, "mapper",
                                           as_text(res.get("detail"), 200))
                        continue
                    absent = [t for t in (res.get("absent_terms") or []) if t]
                    optional = [t for t in (res.get("optional_absent") or []) if t]
                    await self.advance(b["slug"], "mapped", "mapper", as_text(res.get("detail"), 400))
                    # THE UNBID HOLD IS THE DAEMON'S AND IT IS MECHANICAL, and phase 3 measured exactly
                    # why. The adapter drill asked the mapper its own standing rule - resolved
                    # ingredient, no bid wired, advance or hold? - twice, same prompt and same model,
                    # and got ADVANCE once and HOLD once. A rule a model must remember is a rule it
                    # sometimes forgets, and this one gates whether a writer gets paid. So the rule
                    # lives here, over map-preresolve's `holds` rows, and the mapper is never asked.
                    holds = (tables.get(b["slug"]) or {}).get("holds") or []
                    if holds:
                        self.write_hold_record(b["slug"], res, holds)
                        self.held.append((b["slug"], holds[0].get("why")
                                          or "an unbid ingredient has no bid wired"))
                        self.record(b["slug"], {"state": "mapped", "holds": holds})
                        self.log("map: %s HELD at mapped - %d unbid line(s); nothing unbid reaches the "
                                 "writer" % (b["slug"], len(holds)))
                        continue
                    # ---- A1: THE DECISION FILE IS ASSEMBLED HERE, BY THE DAEMON. ------------------
                    # Gate finding 1 dies by construction: the mapper no longer holds this pen, so it
                    # can no longer write the wrong shape into it. An assembly that finds anything
                    # unsettled writes NOTHING and the recipe is STUCK with the lines NAMED - a state
                    # a person can act on, where the old failure was an exit 1 a whole stage later.
                    ok_asm, why_asm = await self.assemble_mapped(b["slug"], res, tables)
                    if not ok_asm:
                        self.stuck(b["slug"], "map", why_asm)
                        self.log("  map: %s STUCK - %s" % (b["slug"], why_asm[:200]))
                        continue
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

    def map_prompt(self, slugs, tables=None):
        """THE RESIDUAL CONTRACT (D7). The vocabulary lecture left this prompt in the same commit that
        shipped the pre-resolve table, because the table IS the lecture, answered. What is left is what
        map-preresolve could not answer: identity judgments, form flips, each-weight calls, label
        transcription, and the macro cross-check.

        The pre-computed macro numbers travel HERE, in the prompt, as inputs to verify. They are not a
        schema field - section 4.5's two named deltas (SEL->DECIDE, WRITE drops its macro fields) stay
        the only two, and adding a third by accident is how a contract stops being a contract.
        """
        tables = tables or {}
        blocks = []
        for slug in slugs:
            t = tables.get(slug) or {}
            rows = t.get("rows") or []
            resid = [r for r in rows if r.get("resolution") in
                     ("unresolved", "different-form", "new-food-suspect")]
            lines = ["%s  (%d line(s): %d pre-resolved, %d for you)"
                     % (slug, t.get("line_count", len(rows)), t.get("resolved_count", 0), len(resid))]
            for r in resid:
                # THE RAW LINE IS THE JOIN KEY, so it travels with the residual rather than being
                # looked up: the return contract below is keyed by `raw`, and the assembler matches
                # the mapper's arrays to the table's rows on exactly this string.
                lines.append("    [%s] %s" % (r.get("resolution"), r.get("term")))
                lines.append("        raw: %s" % (r.get("raw") or ""))
                # A2: THE EVIDENCE TRAVELS WHOLE. It was truncated at 220 characters, which cut the
                # near-miss list - "White Wine Vinegar [white-wine-vinegar] DIFFERENT FORM: vinegar" is
                # the single most useful sentence in the table and it sits at the END of that string,
                # after the prior-ruling and board notes. Truncating it sent the mapper back to the
                # estate to re-derive what the table had already computed. Phase 1 measured inlining
                # beating tool-call reads by a wide margin; this is that finding applied here.
                lines.append("        evidence: %s" % (r.get("evidence") or "(none gathered)"))
                if r.get("fooddb_known") is False:
                    lines.append("        NO food-macros-db row - this is the one thing a label "
                                 "lookup is still for")
            if not resid:
                lines.append("    (every line pre-resolved - the buy strings and the cross-check "
                             "below are the whole job)")
            settled = [r for r in rows if r.get("resolution") in ("resolved",)]
            if settled:
                lines.append("  SETTLED lines - identity is DONE, do not re-derive it. You owe each "
                             "one a `buy` string and nothing else:")
                for r in settled:
                    g = r.get("grams_source_basis")
                    lines.append("    %s  [%s]  raw: %s%s"
                                 % (r.get("canon_item") or r.get("term"), r.get("bid") or "no bid",
                                    r.get("raw") or "",
                                    ("   source-basis %sg" % g) if g else "   (no weight computed)"))
            mp = t.get("macro_precheck") or {}
            src = mp.get("source") or {}
            if mp.get("state") == "computed":
                c = mp.get("computed_per_serving") or {}
                lines.append("    MACRO CROSS-CHECK, pre-computed over all %d lines by parse-compute.ps1:"
                             % mp.get("lines_total", 0))
                lines.append("      ours   %s cal / %s carbs / %s protein / %s fat per serving"
                             % (c.get("cal"), c.get("carbs"), c.get("protein_g"), c.get("fat_g")))
                lines.append("      source %s cal / %s carbs / %s protein  (%s)"
                             % (src.get("cal"), src.get("carbs"), src.get("protein_g"), src.get("from")))
                if mp.get("missing_db_items"):
                    lines.append("      food-DB rows missing: %s" % ", ".join(mp["missing_db_items"]))
                lines.append("      VERIFY it, do not re-derive it. If the two disagree by more than the"
                             " dish can explain, say so in `detail`.")
            else:
                lines.append("    MACRO CROSS-CHECK: NOT pre-computed (%s). Source published %s cal / "
                             "%s carbs / %s protein (%s). Do the check yourself over the lines you rule."
                             % (mp.get("reason") or mp.get("state") or "no table",
                                src.get("cal"), src.get("carbs"), src.get("protein_g"),
                                src.get("from") or "unknown"))
            blocks.append("\n".join(lines))

        return (
            "Map the RESIDUAL of this micro-batch of %d recipe(s). Section S4 batches up to %d.\n\n"
            "map-preresolve.ps1 has already run. It resolved every line it could from the prior-rulings\n"
            "ledger, the closed vocabulary and its adjudicated aliases, and it checked the board, the\n"
            "densities, the each-nouns and the food DB for each one. EVERYTHING IT FOUND IS BELOW, in\n"
            "full - the residual lines with the whole of their evidence, and the settled lines with\n"
            "their ids and their computed source-basis weights. Do not re-derive any of it.\n\n"
            "%s\n\n"
            "YOUR JOB IS THREE THINGS AND NOTHING ELSE.\n"
            "  1. Rule the RESIDUAL lines: identity, form flips on their merits (a form word is a\n"
            "     different price AND a different gram weight - never bridge one with an alias),\n"
            "     each-weights, and an honest rejection where the answer is no. `null` is safe; a\n"
            "     plausible wrong match is not.\n"
            "  2. Write a `buy` string for EVERY purchasable line, settled ones included. That string is\n"
            "     printed verbatim in the reader's Ingredients section and the skeleton builder LOCKS it,\n"
            "     which is what makes it impossible for the writer to introduce a number. It states what\n"
            "     goes IN THE POT at the %d-serving batch scale, not what a package is called: \"3 lb,\n"
            "     sliced into thin rounds\", \"an 8 oz brick minus 2 tbsp\", \"5 1/4 cups grated, divided\".\n"
            "  3. The macro cross-check, per recipe, as described in each block above.\n\n"
            "READS. The table above is the estate, already read for you. Do NOT open the vocabulary, the\n"
            "commodity files, the board, the feed or the resolutions ledger - every question they answer\n"
            "is answered above, and a re-read costs a turn that re-reads the whole accumulated context\n"
            "with it. The ONE read still worth a turn is a nutrition LABEL for a food the table marks as\n"
            "having no food-macros-db row, because that transcription has to be label-accurate and\n"
            "nothing here can supply it. Add those rows as you always have.\n\n"
            "YOU DO NOT WRITE %s\\mapped\\<slug>.json ANY MORE, and this is the change to read twice.\n"
            "The ORCHESTRATOR assembles that file from the table plus your two arrays. On 2026-08-24 a\n"
            "live batch wrote it in the pre-resolve TABLE'S shape and the skeleton builder exited 1 over\n"
            "a recipe that had just been settled cleanly - because a prompt said \"unchanged contract\"\n"
            "without naming one field. Now the shape is not yours to get wrong. Return, per slug:\n"
            "  lines    - EVERY purchasable line: {raw, buy, notes}. `raw` is the extraction's own line,\n"
            "             copied EXACTLY - it is the key everything is joined on, so copy it, do not\n"
            "             retype it. Add `grams_source` where you weighed the line yourself.\n"
            "  rulings  - the RESIDUAL lines only: {raw, term, canon_item, bid, decision,\n"
            "             grams_source, evidence}. `decision` is a CLOSED SET: %s. Free text here\n"
            "             produced 21 distinct values across 550 lines and silently dropped 1588 g of\n"
            "             chicken out of a recipe, so anything outside that set refuses the whole file.\n\n"
            "EVERY GRAM YOU STATE IS AT THE SOURCE RECIPE'S OWN SCALE, exactly like the\n"
            "`grams_source_basis` figures above, and the field is called `grams_source` so there is\n"
            "nothing to remember. DO NOT scale anything: the orchestrator multiplies by the scale\n"
            "factor exactly once, for every line, from both roads. On 2026-08-24 this field was called\n"
            "`grams` and specified as the TARGET weight, and ten lines across two recipes came back at\n"
            "source scale - every one of them off by exactly the recipe's own factor, which would have\n"
            "retired two good dishes at 212 and 217 calories against a 400 floor. Your BUY STRING is\n"
            "still the target-scale prose a cook reads (\"3 lb, sliced into thin rounds\"); only the\n"
            "number is source basis.\n\n"
            "A `mapped-null` LINE STILL NEEDS A NAME. No commodity id is a fine and often correct\n"
            "answer - pantry-static pricing is safe, and refusing to bridge dry mustard powder onto a\n"
            "prepared-mustard id is exactly right. But `canon_item` null as well leaves a line with no\n"
            "food on it, and a line with no food cannot be costed or weighed. Name the food.\n\n"
            "ANY `bid` NOT ALREADY SHOWN ABOVE IS A NEW COMMODITY ID, whether or not you list it. The\n"
            "orchestrator checks the three commodity namespaces itself and sends every genuinely new\n"
            "one to the registrar, so you cannot skip that gate by omission - but you CAN make it\n"
            "cheap by putting your case in `new_commodity_proposals` where the registrar will read it.\n"
            "Note the reverse too: an id that already prices a food is a REUSE, not a proposal.\n\n"
            "KEEP `evidence` AND `notes` TO ONE OR TWO SENTENCES - the decisive fact, not the whole\n"
            "argument. Output is the most expensive thing you produce, at five times the price of\n"
            "input, and a two-recipe batch returned 38,000 output tokens of it on 2026-08-24. A form\n"
            "flip needs \"dry ground seed, not the prepared condiment: different price class and\n"
            "different gram weight\", not a paragraph.\n\n"
            "A NEW COMMODITY ID GOES IN `new_commodity_proposals`, NOT THROUGH A SUBAGENT. You no longer\n"
            "have the Agent tool. Put {term, proposed_bid, evidence} there and the orchestrator\n"
            "dispatches the commodity-registrar itself and applies its verdict. An id nothing approves\n"
            "never reaches the file, so make the evidence the case you would have made to it.\n\n"
            "DO NOT rule on whether an ingredient with no bid should hold the recipe. That is mechanical\n"
            "and the orchestrator does it from the table's `holds` rows: asked the same question twice\n"
            "with the same prompt and the same model, this stage answered ADVANCE once and HOLD once,\n"
            "and it gates whether a writer gets paid.\n\n"
            "DO NOT run hunt-run.ps1 and DO NOT add anything to the ingredient queue. Return the terms\n"
            "the board could not answer in `absent_terms` as a JSON ARRAY and the orchestrator will\n"
            "enqueue them and move the state itself. That is not a courtesy: -Terms 'a,b' binds as ONE\n"
            "composite string in PowerShell and parked two recipes forever on 2026-08-16, and a JSON\n"
            "array cannot be comma-joined by accident.\n\n"
            "Transcriptions, if you need a line's full context: %s\\extracted\\<slug>.json\n"
            "This run's conditions: %s\n"
            % (len(slugs), hunt_lib.MAP_BATCH, "\n\n".join(blocks), hunt_lib.TARGET_SERVINGS,
               self.run_dir, " | ".join(hunt_lib.MAPPED_RULING_DECISIONS),
               self.run_dir, self.conditions))

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
                # THE PRE-PASS RUNS HERE, BETWEEN THE SLICE AND THE DISPATCH (D10). It gathers; it
                # never rules. Whatever it could not reach is UNUSABLE in the evidence and the
                # pricer is dispatched anyway - see gather_price_evidence.
                ev_path, ev_doc = await self.gather_price_evidence(terms, n)
                await self.with_retry(
                    lambda t=terms, k=n, e=ev_doc, p=ev_path: self.dispatch(
                        "recipe-hunter-pricer",
                        self.price_prompt(t, e, p),
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

    async def gather_price_evidence(self, terms, n):
        r"""THE PRICE-EVIDENCE PRE-PASS (D10). Returns (path, doc).

        THREE GATHERERS, ONE FILE:
          1. ONE probe-ingredient.ps1 call for the WHOLE batch (Baker's + Family Fare), through
             ps_invoke with -Term as a NAMED real array - the -File-binding family is why ps_invoke
             exists, and a comma-joined term list is B8 with a Python accent.
          2. pull-browser-stores.py --lookup-terms-file, one subprocess PER DRIVABLE STORE (Fareway,
             Sam's Club), through sys.executable. The two run concurrently for the same reason the
             daily capture runs its lanes concurrently - separate profiles, separate ports, separate
             outputs - and that is not "parallelising around the singleton": the singleton is one
             PRICER at a time, and this is one batch's gathering.
          3. the join, into <RunDir>\price-evidence\batch-<n>.json. `n` is the lane's own invocation
             counter, so this path has exactly ONE writer and needs NO mutex (price_evidence.py's
             header carries the argument in full).

        DEGRADE, NEVER BLOCK - the explicit OPPOSITE of map-preresolve's exit 2. A mapper ruling on
        unreadable inputs would be a guess, so that lane refuses. This is EVIDENCE for a judge who
        can also go and look: a failed probe, a walled sweep or a missing lookup output makes those
        STORES UNUSABLE and the pricer is dispatched anyway. Could-not-look never reads as EMPTY,
        and the daemon never skips the judge. The one thing that holds this lane is the singleton
        cap, which is architecture.

        AND IT NEVER WRITES A QUEUE RECORD. Search states (MATCHES/EMPTY/UNUSABLE) and queue states
        (carried/not-carried/blocked/error) never mix; only the PRICER converts.
        """
        ev_dir = os.path.join(self.run_dir, "price-evidence")
        path = os.path.join(ev_dir, "batch-%d.json" % n)
        await self.lane("price", "pre-pass batch %d" % n, terms, "pre-pass", "start")
        findings = []
        probe_by_term, units, lookups = {}, {}, {}
        try:
            os.makedirs(ev_dir, exist_ok=True)

            rc, out, err = await self.ps(PROBE_INGREDIENT_PS, ["-Term", list(terms), "-Json"],
                                         timeout=PROBE_TIMEOUT)
            doc, why = price_evidence.parse_probe_stdout(out)
            if rc != 0 or doc is None:
                # A NONZERO EXIT'S OWN SENTENCE OUTRANKS THE PARSER'S. parse_probe_stdout answers
                # "probe printed nothing" for an empty stdout, which is true and useless; the guard
                # line on stderr is the one that says WHY (measured: a 401 from Get-KrogerToken was
                # being reported as "printed nothing" until a fixture asked for the 401 by name).
                if rc != 0:
                    why = hunt_lib.first_guard_line(out, err) or why or ("probe exited %s" % rc)
                else:
                    why = why or "the probe returned no readable JSON"
                probe_by_term = price_evidence.probe_failed(price_evidence.SERVER_STORES, terms, why)
                findings.append("price pre-pass: the server probe did not answer (%s) - Baker's and "
                                "Family Fare are UNUSABLE for this batch" % why[:160])
                self.log("  pre-pass: server probe UNUSABLE - %s" % why[:120])
            else:
                probe_by_term, units = price_evidence.from_probe(doc)

            got = await asyncio.gather(*[self.store_lookup(k, name, terms, n)
                                         for k, name in price_evidence.DRIVER_STORES])
            for store_name, ldoc, lwhy in got:
                lookups[store_name] = price_evidence.from_lookup(store_name, ldoc, terms, lwhy)
                if ldoc is None:
                    findings.append("price pre-pass: %s is UNUSABLE for this batch (%s)"
                                    % (store_name, lwhy[:160]))
        except Exception as e:
            # A pre-pass that THREW still produces a file and still dispatches. The alternative is a
            # judge that never runs because its briefing crashed.
            findings.append("price pre-pass threw (%s) - every gathered store is UNUSABLE for this "
                            "batch" % e)
            self.log("  pre-pass THREW: %s" % e)
            if not probe_by_term:
                probe_by_term = price_evidence.probe_failed(price_evidence.SERVER_STORES, terms,
                                                            "the pre-pass threw: %s" % e)
            for k, name in price_evidence.DRIVER_STORES:
                lookups.setdefault(name, price_evidence.from_lookup(
                    name, None, terms, "the pre-pass threw: %s" % e))

        roster, roster_why = price_evidence.read_store_roster()
        doc = price_evidence.build(self.run_id, n, terms, probe_by_term, units, lookups,
                                   roster, roster_why, findings,
                                   generated=time.strftime("%Y-%m-%dT%H:%M:%S"))
        try:
            price_evidence.write(path, doc)
        except Exception as e:
            # The file is a courtesy to the reader; the prompt carries the evidence inline, so a
            # write failure must not cost the batch its judge.
            doc["findings"].append("could not write the evidence file (%s)" % e)
            self.log("  pre-pass: could not write %s (%s)" % (path, e))
        tal = price_evidence.tally(doc)
        self.log("  pre-pass batch %d: %s" % (n, ", ".join("%s %d" % kv for kv in sorted(tal.items()))))
        for f in doc.get("findings") or []:
            self.findings.append(f)
        await self.lane("price", "pre-pass batch %d" % n, terms, "pre-pass", "end",
                        detail=", ".join("%s %d" % kv for kv in sorted(tal.items())))
        return path, doc

    async def store_lookup(self, store_key, store_name, terms, n):
        """One drivable store's lookup. Returns (store_name, doc or None, why).

        THE SAM'S PRECONDITION IS THIS CALL, and there is no separate session probe to build: an
        unseeded or logged-out profile fails the driver's own seeded check / samsIdentity(), the
        store ends NEEDS-SEEDING, and the lookup file comes back all-UNUSABLE with that as the
        reason. The puller owns the session and is the only honest source on it; the daemon never
        opens a browser to find out.
        """
        ev_dir = os.path.join(self.run_dir, "price-evidence")
        tf = os.path.join(ev_dir, "batch-%d-%s.terms.json" % (n, store_key))
        out = os.path.join(ev_dir, "batch-%d-%s.json" % (n, store_key))
        try:
            with open(tf, "w", encoding="utf-8", newline="\n") as fh:
                json.dump(list(terms), fh, ensure_ascii=False)
        except Exception as e:
            return store_name, None, "could not write the lookup term list (%s)" % e
        rc, so, se = await self.py(PULL_BROWSER_STORES_PY,
                                   ["--store", store_key, "--lookup-terms-file", tf,
                                    "--lookup-out", out], timeout=LOOKUP_TIMEOUT)
        why = ""
        doc = None
        if os.path.exists(out):
            try:
                with open(out, "r", encoding="utf-8-sig") as fh:
                    doc = json.load(fh)
            except Exception as e:
                doc, why = None, "the lookup output did not parse (%s)" % e
        else:
            tail = ((so or "") + (se or "")).strip().splitlines()
            why = ("the lookup produced no output file (exit %s): %s"
                   % (rc, tail[-1][:160] if tail else "no output"))
        if doc is not None and rc != 0:
            # A partial answer is still evidence - the file says per term which of it is UNUSABLE.
            self.log("  pre-pass: %s lookup exited %s (partial evidence kept)" % (store_name, rc))
        return store_name, doc, why

    def price_prompt(self, terms, evidence=None, path=""):
        """B3 / pin P9. THE PROMPT STATES THE HEADLESS TRUTH UNCONDITIONALLY, and there is no flag.

        price_prompt is DAEMON-ONLY BY CONSTRUCTION. The attended path is a human invoking the agent
        interactively in the app, and no human path ever renders this string - so there is nothing to
        switch on, and a conditional here would be a branch nobody could ever take. The agent
        definition keeps its attended instructions for that other entry point: two entry points, one
        agent, zero conditionals.
        """
        blocked = price_evidence.headless_blocked_stores(evidence) if evidence else []
        walled = price_evidence.walled_stores(evidence) if evidence else []
        body = (
            "Price this batch of %d term(s) the board has never carried. They come from SEVERAL\n"
            "recipes at once - the ingredient queue is keyed by term and dedupes across recipes,\n"
            "which is exactly why this lane batches. You are the ONLY pricer alive right now, by\n"
            "design.\n\n"
            "TERMS: %s\n\n"
            "THE MECHANICAL PRE-PASS HAS ALREADY RUN, and its result is below. Your minutes go to\n"
            "the two things only you can do: ADJUDICATE what was gathered, and ATTEND the stores no\n"
            "pre-pass reaches.\n\n"
            "ADJUDICATE. MATCHES is a pile of candidates, never a carriage ruling. Ask of each row\n"
            "whether it is THE INGREDIENT, in a form a cook would buy for this recipe.\n\n"
            "YOU HAVE NO BROWSER IN THIS SESSION. Read that as a fact about this process, not as a\n"
            "difficulty to work around. You were dispatched headless, so no MCP server is attached:\n"
            "mcp__Claude_Browser__* is the app's own pane and mcp__claude-in-chrome__* needs the\n"
            "extension on an interactive session. Your frontmatter DECLARES both, and declaring a\n"
            "tool does not conjure the server. Do not check list_connected_browsers, do not try a\n"
            "tab, and do not describe a store page you did not load. On 2026-08-24 a dispatched\n"
            "pricer wrote three verified-sounding store visits - a Walmart store address, an Aldi\n"
            "header, a Hy-Vee store selector - that never happened, then corrected itself. The\n"
            "correction is why the queue is clean and it is not a control, which is why this\n"
            "paragraph exists.\n\n"
            "SO THESE STORES ARE RECORDED BLOCKED, MECHANICALLY, IN THE SAME BATCH: %s.\n"
            "State `blocked`, evidence exactly `%s`. That is not a defeat - blocked is honest and it\n"
            "keeps the term PENDING, which is what an unchecked store is meant to do. Brad checks\n"
            "those three in an attended run.\n\n"
            "WITH ONE EXCEPTION, AND A DISPATCHED PRICER FOUND IT BEFORE THIS PROMPT DID: the estate\n"
            "already has those stores on disk. `grocery\\price-ingredient.ps1 -Name \'<term>\'` reads\n"
            "today\'s captures across all seven, and a capture row is a product a store really put on\n"
            "its own shelf listing - checkable, re-runnable, and a great deal better than `blocked`.\n"
            "So: if price-ingredient names a product at one of those three that IS this ingredient,\n"
            "record it `carried` with the product, the price and `no browser this session; ruled from\n"
            "disk instead - price-ingredient.ps1 ...` as the evidence, exactly as you would cite a\n"
            "page. Adjudicate it as hard as any other row: a capture row is a candidate, never a\n"
            "carriage ruling.\n"
            "  BUT A CAPTURE MISS IS NEVER `not-carried`. The captures are a weekly sweep of what a\n"
            "  store chose to publish, not a shelf audit, and absence from them is not absence from\n"
            "  the store. No row means `blocked`, and the term stays PENDING for an attended run.\n\n"
            "AND DO NOT RE-PROBE A STORE THE EVIDENCE ALREADY MARKS UNUSABLE AT THE SERVER OR DRIVER\n"
            "TIER%s. That is a transport refusal, not an empty shelf: on 2026-08-24 Family Fare\n"
            "answered (400) Bad Request to all five terms of a batch (Freshop is search-budget bound\n"
            "and the daily capture had already spent it) and ate three futile retries. Record it\n"
            "`blocked` with the reason the evidence gives, and move on.\n\n"
            "WHAT IS LEFT IS THE WHOLE OF YOUR JUDGMENT, and it is worth the session: which gathered\n"
            "row is really this ingredient, in a form a cook would buy.\n\n"
            "READ THE STATES AS THEY ARE WRITTEN. MATCHES / EMPTY / UNUSABLE are SEARCH states.\n"
            "carried / not-carried / blocked / error are what YOU record, and you are the only one\n"
            "who converts between them. An EMPTY from the two server stores is a FULL LADDER empty;\n"
            "an EMPTY from Fareway or Sam's Club is RUNG 1 ONLY and does not support not-carried\n"
            "until you have walked the ladder yourself. UNUSABLE is never not-carried.\n\n"
            "YOU STILL HOLD THE PEN, AND IT IS ONE CALL NOW, NOT THIRTY-FIVE.\n"
            "  ingredient-queue.ps1 -RecordBatch -File <a JSON array you write to a temp file>\n"
            "with one object per store per term: {term, store, state, price, size, item, evidence}.\n"
            "Seven stores across %d terms is one write, not %d round trips, and each round trip is a\n"
            "turn that re-reads this whole session. THE BATCH IS ALL-OR-NOTHING: every row is checked\n"
            "against the same contract -Record enforces (exact store names, a carried row needs a\n"
            "price, the state enum), and one bad row means NOTHING is written and every violation is\n"
            "named with its row number - so you get one correction pass rather than a hole in your\n"
            "own evidence. Then -Verdict, then -Promote when a term settles; those stay per term.\n"
            "Do not write board cells and do not move any recipe state - the orchestrator derives\n"
            "that from the queue.\n"
            % (len(terms), ", ".join(terms),
               ", ".join(blocked) or "(the evidence names none)",
               price_evidence.NO_BROWSER_EVIDENCE,
               (" - today that is: " + ", ".join(walled)) if walled else "",
               len(terms), 7 * len(terms)))
        if evidence:
            body += "\n" + price_evidence.render(evidence, path=path) + "\n"
        else:
            body += ("\nNO EVIDENCE FILE WAS GATHERED for this batch - treat every store as\n"
                     "unchecked and look for yourself.\n")
        return body

    # ---------------------------------------------------------------------------------------------
    # WRITE - cap 3, plus the band gate read off the BUILT SPEC (section 4.5's D9/D8 note)
    # ---------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------
    # D8: THE MACHINE HALF OF THE INTAKE, and the band gate that now runs BEFORE the prose is paid for.
    # ---------------------------------------------------------------------------------------------

    async def build_skeleton(self, slug):
        """build-intake-skeleton.ps1, before the writer. Returns (ok, macros, detail).

        `ok` False means the skeleton is not a thing the band can be ruled on - either BLOCKED (exit 2)
        or INCOMPLETE (exit 1, named findings: a missing food-DB row makes the macros partial, and
        build-v2-spec would throw on it downstream anyway). Unlike map-preresolve, exit 1 here is NOT
        the normal case: a skeleton is either complete or it is not.
        """
        rc, out, err = await self.ps(BUILD_SKELETON_PS,
                                     ["-RunDir", self.run_dir, "-Slug", slug], timeout=600)
        detail = ((out or "") + (err or "")).strip()
        if rc != hunt_lib.EXIT_CLEAN:
            # THE FINDINGS, NOT THE TAIL. The script prints two path lines after its summary, so a
            # blind `detail[-400:]` handed the operator half a file path where the reason should be -
            # seen on the phase-4 gate run, where "the intake cannot be built over an unsettled line"
            # was pushed off the end by the snapshot's own filename.
            found = [ln.strip() for ln in detail.replace("\r", "").split("\n")
                     if ln.strip().startswith("FINDING")
                     or ln.strip().startswith("build-intake-skeleton: BLOCKED")]
            return False, None, ("; ".join(found)[:400] if found else detail[-400:])
        path = os.path.join(self.run_dir, "intake", "%s.json" % slug)
        try:
            with open(path, "r", encoding="utf-8-sig") as f:
                mac = (json.load(f) or {}).get("macros_per_serving") or {}
        except Exception as e:                                    # noqa: BLE001
            return False, None, "the skeleton reported clean but %s will not read (%s)" % (path, e)
        return True, mac, detail[-400:]

    async def verify_skeleton(self, slug):
        """The locked-field diff, AFTER the writer. Returns (clean, drifted_fields, detail).

        THE SKELETON IS A POSTCONDITION, NOT A SUGGESTION. Exit 1 names the fields, and the daemon
        quotes them verbatim back to the writer for its ONE re-ask.
        """
        rc, out, err = await self.ps(BUILD_SKELETON_PS, [
            "-Verify",
            "-InFile", os.path.join(self.run_dir, "intake", "%s.json" % slug),
            "-Skeleton", os.path.join(self.run_dir, "intake", "%s.skeleton.json" % slug),
        ], timeout=300)
        text = ((out or "") + (err or "")).strip()
        if rc == hunt_lib.EXIT_CLEAN:
            return True, [], text[-400:]
        fields = [ln.strip() for ln in text.splitlines()
                  if ln.startswith("    ") and ":" in ln and "COMPLETE" not in ln]
        if rc == hunt_lib.EXIT_CANNOT_RUN:
            # A diff with nothing to diff against is not a pass, and it is not a drift either.
            return False, [], "the locked-field diff could not run: %s" % text[-300:]
        return False, fields, text[-400:]

    def spec_args(self, slug):
        """The build-v2-spec arguments, honouring a scratch spec store / cost ledger when a drill set
        one. -RunCost is build-v2-spec's own coupling: it is refused unless OutDir IS db\recipes."""
        args = ["-InFile", os.path.join(self.run_dir, "intake", "%s.json" % slug)]
        if self.costed_path:
            args += ["-CostedFile", self.costed_path]
        if self.specs_dir:
            args += ["-OutDir", self.specs_dir, "-AllowUncosted", "-Force"]
        else:
            args += ["-RunCost"]
        return args

    def record_band_pair(self, slug, where, verdict, cal, carbs, protein):
        """D7 (Brad's ruling 2026-08-24). Append the (SOURCE CLAIM, OUR RECOMPUTE) pair for every band
        ruling - pass or fail - to `<RunDir>\\band-pairs.jsonl`.

        WHY, MEASURED ON 6b. The pop filter selects on the pool's band, which is the SOURCE PAGE'S own
        claim at the source's serving count. The band gate rules on OUR label-accurate recompute at 14
        servings. They disagreed by up to 15 g of protein - beef-back-ribs advertised 57 g and computed
        to 41.6 - so 2 of 9 accepted recipes died at the gate AFTER the mapper, the registrar and the
        pricer had been paid. There is no cheap fix, because the gate needs the skeleton and the
        skeleton needs the map; every lever is on the pre-filter side and every one needs a margin
        nobody can honestly pick yet.

        So this picks NO margin and changes NO gate. It only stops throwing the evidence away: 6b
        produced three of these pairs and recorded none of them. Enough runs of this and a margin can be
        derived from measurement instead of from a guess.
        """
        rec = self.rec.get(slug) or {}
        src = dict(rec.get("source_band") or {})
        line = {"at": time.strftime("%Y-%m-%dT%H:%M:%S"), "run": self.run_id, "slug": slug,
                "where": where,
                "ok": bool(verdict.get("ok")), "reason": verdict.get("reason") or "",
                "band": {k: self.band.get(k) for k in ("calMin", "calMax", "carbMax", "proteinMin")},
                "source": {"cal": src.get("cal"), "carbs": src.get("carbs"),
                           "protein_g": src.get("protein_g"),
                           "verified": src.get("verified"),
                           "servings": rec.get("source_servings")},
                "ours": {"cal": cal, "carbs": carbs, "protein_g": protein,
                         "servings": hunt_lib.TARGET_SERVINGS}}
        try:
            with open(os.path.join(self.run_dir, "band-pairs.jsonl"), "a", encoding="utf-8") as f:
                f.write(json.dumps(line, ensure_ascii=False) + "\n")
        except Exception as e:                                    # noqa: BLE001
            # A calibration LOG may never break a run. It is evidence for later, not a gate.
            self.findings.append("%s: the band pair could not be recorded (%s)" % (slug, e))

    async def retire_out_of_band(self, slug, verdict, where):
        """priced -> rejected-macros, in ONE advance. Both band gates land the same way: the pre-write
        one because no prose was ever paid for, and the post-build one because the state advances
        happen after it, so the recipe is still at `priced` when it rules."""
        self.log("macro gate (%s): %s at %s - retiring" % (where, slug, verdict["reason"]))
        await self.advance(slug, "rejected-macros", "macro-gate",
                           "macro gate (%s): %s" % (where, verdict["reason"]))
        self.finish(slug, "rejected", "rejected-macros",
                    "macro gate (%s): %s" % (where, verdict["reason"]))

    async def write_lane(self):
        async def worker(_i):
            while True:
                c = await self.ch["write"].take()
                if c is None:
                    return
                if self.halted():
                    return
                slug = c["slug"]

                # D8: THE SKELETON FIRST. Every gram, buy string and macro in the intake comes from the
                # mapper's decision file and the food DB, so the writer receives a file it can only add
                # prose to - it structurally cannot introduce a number.
                ok, macros, why = await self.build_skeleton(slug)
                if not ok:
                    self.stuck(slug, "write",
                               "the intake skeleton is not complete, so the band cannot be ruled on "
                               "it: %s" % why[:250])
                    continue

                # THE PRE-WRITE BAND GATE. v2 checked the band on the WRITE result - after the most
                # expensive per-recipe stage had already run. The skeleton carries macros_per_serving,
                # so an out-of-band recipe retires before a single word of prose is paid for.
                verdict = hunt_lib.in_band(macros.get("calories"), macros.get("carbs_g"), self.band,
                                           macros.get("protein_g"))
                # D7: EVERY ruling, pass or fail. A pass is as much calibration data as a failure -
                # more of it, in fact, since the passes are the recipes the pre-filter got right.
                self.record_band_pair(slug, "pre-write", verdict, macros.get("calories"),
                                      macros.get("carbs_g"), macros.get("protein_g"))
                if verdict["reason"] == "protein not reported":
                    # A STATED FLOOR THAT COULD NOT BE READ IS A FINDING, NOT A QUIET PASS. The
                    # skeleton always carries macros_per_serving.protein_g, so this firing means the
                    # skeleton changed shape under the gate - and the gate passing on the number it
                    # could not find is exactly the failure this run is supposed to be able to see.
                    self.findings.append("%s: the band states a %s g protein floor and the skeleton "
                                         "reported no protein - the floor did not rule on this recipe"
                                         % (slug, self.band.get("proteinMin")))
                if not verdict["ok"]:
                    await self.retire_out_of_band(slug, verdict, "pre-write")
                    continue

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

                # THE LOCKED-FIELD DIFF, and the adapter's one-correction discipline. On a named drift
                # the writer is re-dispatched ONCE with the drifted fields quoted VERBATIM - never a
                # silent daemon-side revert, because the writer has to see what it did. A second drift
                # is rejected-qa with the fields in the detail. One correction, never a loop, never a
                # coercion.
                clean, drift, vdetail = await self.verify_skeleton(slug)
                if not clean and not drift:
                    self.stuck(slug, "write", vdetail[:250])
                    continue
                if not clean:
                    self.log("write: %s drifted %d locked field(s) - one re-ask" % (slug, len(drift)))
                    r2 = await self.with_retry(
                        lambda: self.dispatch("recipe-writer", self.redrift_prompt(slug, drift),
                                              "write", "%s:redrift" % slug, [slug],
                                              schema=hunt_lib.WRITE, stage="writer"),
                        slug, "write")
                    if r2 is None:
                        self.stuck(slug, "write", "no response to the locked-field re-ask")
                        continue
                    clean, drift2, vdetail = await self.verify_skeleton(slug)
                    if not clean:
                        detail = "locked fields drifted twice: %s" % "; ".join(drift2 or drift)
                        self.finish(slug, "rejected", "rejected-qa", detail)
                        await self.advance(slug, "rejected-qa", "writer", detail[:200])
                        continue
                # THE COST PASS IS SERIALIZED. Spec assembly stayed parallel; this does not.
                rc_spec, sp_out, sp_err = await self.cost_engine(BUILD_V2_SPEC_PS,
                                                                 self.spec_args(slug))
                if rc_spec != 0:
                    # THE SPEC BUILD'S OWN GUARDS ARE GATES, AND THIS LANE WAS NOT READING THEM.
                    # Measured on the phase-4 gate run: six writers were paid, build-v2-spec REFUSED
                    # all six on UNKNOWN INGREDIENT NAME (v2-era canon names the closed vocabulary no
                    # longer carries - "Marsala Wine", "Bacon Bits"), no spec was written, and the
                    # lane advanced every one of them to `written` anyway. The band read then found no
                    # spec, and hunt_lib.in_band answers "not reported -> ok" by design (v2 parity: a
                    # band nobody reported is not a rejection), so a refused build read as a pass.
                    # The predicate is right and the lane was wrong: a build that refused is a
                    # could-not-look, and could-not-look is never a clean bill.
                    self.stuck(slug, "write",
                               "the spec build REFUSED this recipe (rc %d): %s"
                               % (rc_spec, hunt_lib.first_guard_line(sp_out, sp_err)))
                    continue
                cal, carbs, prot = self.spec_band(slug, specs_dir=self.specs_dir or None)
                if cal is None and carbs is None:
                    self.stuck(slug, "write",
                               "the spec build reported success but no spec could be read for the "
                               "band - the band may not be ruled on a spec nobody can find")
                    continue
                verdict = hunt_lib.in_band(cal, carbs, self.band, prot)
                self.record_band_pair(slug, "post-build", verdict, cal, carbs, prot)
                if verdict["reason"] == "protein not reported":
                    self.findings.append("%s: the band states a %s g protein floor and the BUILT SPEC "
                                         "reported no stat.protein - the floor did not rule on this "
                                         "recipe" % (slug, self.band.get("proteinMin")))
                if not verdict["ok"]:
                    # THE POST-BUILD READ STAYS, and D8 does not get to "simplify" it away. The
                    # pre-write gate is a PREDICTION about the artifact; this is a mechanical
                    # POSTCONDITION over the artifact itself, read off the built spec's own
                    # stat.cal/stat.carbs. Both call the same parity-covered hunt_lib.in_band, and
                    # keeping both costs one file read. If they ever disagree, something between the
                    # skeleton and the spec moved a number, which is exactly the thing worth hearing
                    # about.
                    #
                    # THE ROUTE MATTERS, AND THE FIRST BUILD GOT IT WRONG (found on the 2026-08-24
                    # cold read). The recipe sits at `priced` here - the state advances below happen
                    # AFTER the gate - so the route out has to be legal FROM `priced`. The first
                    # build advanced priced -> rejected-qa directly; the FakePS fixtures accepted it
                    # and the real state machine refused it, which would have left the recipe at
                    # `priced` on disk while this process counted it rejected. The interim fix
                    # reproduced v2's measured on-disk trace, spec-built -> written -> rejected-qa,
                    # which was legal but claimed a spec build and a prose write that never happened.
                    # SHORTENED 2026-08-24 (v3 D8): `priced` now has `rejected-macros` among its
                    # exits, so the honest verdict lands in ONE advance.
                    self.findings.append("%s: the BUILT SPEC is out of band (%s) although the "
                                         "skeleton was in band - a number moved between them"
                                         % (slug, verdict["reason"]))
                    await self.retire_out_of_band(slug, verdict, "post-build")
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
            return None, None, None
        stat = spec.get("stat") or {}
        return stat.get("cal"), stat.get("carbs"), stat.get("protein")

    # The fields the writer owns, named once so the prompt and the re-ask cannot drift apart.
    WRITER_FILLABLE = ("prose.* (intro_html, shop_smart, make_it, portion_html, cost_closing_html, "
                       "upsell_html), cuisine, head.description, head.keywords, head.steps, "
                       "head.step_names, writer_notes, forbidden_prose_terms")

    def write_prompt(self, slug):
        """PROSE ONLY, IN PLACE. D8 changed the old 'Produce ONE intake JSON' line in the same commit
        that shipped the skeleton: the writer and the skeleton must not race for the same file with two
        different ideas of who creates it."""
        return (
            "Write recipe %s in Brad's voice and COMPLETE its intake IN PLACE.\n"
            "Inputs: %s\\extracted\\%s.json (the transcription - the recipe of record)\n"
            "        %s\\mapped\\%s.json (commodity ids, food-DB rows)\n\n"
            "THE INTAKE ALREADY EXISTS at %s\\intake\\%s.json. build-intake-skeleton.ps1 wrote it: the\n"
            "name, slug, protein, source_url, visibility, every ingredient line with its grams and buy\n"
            "string, macros_per_serving, and head.prepTime/cookTime/totalTime are all in it already,\n"
            "derived from the decision files above. Do not create it and do not re-derive it.\n\n"
            "FILL ONLY THESE FIELDS, in place: %s.\n"
            "Every other field is LOCKED. A snapshot of the file as issued sits beside it at\n"
            "intake\\%s.skeleton.json, and the orchestrator diffs your result against it: any change to a\n"
            "locked field is refused and comes back to you with the field named. That is not a\n"
            "formality - the reason you receive the numbers instead of computing them is that the\n"
            "prose-number defect class dies by construction rather than at QA.\n\n"
            "Voice rails: no em dashes, Brad's tone, the existing framework, 14 servings.\n"
            "Compute NO number. Every macro and every cost comes from the engine, and the orchestrator\n"
            "runs the spec build and reads the band off the built spec itself. Do not run hunt-run.ps1\n"
            "and do not move any state.\n\n"
            "This run's conditions: %s\n"
            % (slug, self.run_dir, slug, self.run_dir, slug, self.run_dir, slug,
               self.WRITER_FILLABLE, slug, self.conditions))

    def redrift_prompt(self, slug, drift):
        """THE ONE RE-ASK, quoting the drifted fields VERBATIM. Never a silent daemon-side revert: the
        writer has to see what it did, or the same edit comes back on the next recipe. One correction,
        never a loop - a second drift is rejected-qa."""
        return (
            "%s\\intake\\%s.json came back with LOCKED fields changed. These are machine fields; the\n"
            "skeleton issued them and nothing downstream re-derives them, so a change here publishes a\n"
            "wrong number.\n\n"
            "%s\n\n"
            "Put each of those back to the ISSUED value exactly as quoted, leave your prose as it is,\n"
            "and change nothing else. You may still edit only: %s.\n"
            "This is the one correction. A second drift retires the recipe at rejected-qa.\n"
            % (self.run_dir, slug, "\n".join("  - %s" % d for d in drift), self.WRITER_FILLABLE))

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

    async def reseed_absent_terms(self):
        """B5 / pin P7. Returns (terms_added, why_not) - the terms this seed put back on the price lane.

        THE QUEUE IS THE AUTHORITY AND NOTHING HERE RE-DERIVES IT. `-List -Status pending -Json` is
        verified as the road (2026-08-24, against the live queue): it binds, and each item carries
        `term` and `recipes`. A term is ours if any recipe waiting on it is a recipe THIS run has at
        `pricing` or `parked` - which is precisely `self.pricing_slugs`, already populated above by the
        row loop, the unhold and the parked loop. Queue order is preserved, because that is the order
        the map lane enqueued them in and there is no better one.

        A QUEUE THAT WILL NOT ANSWER IS A FINDING, NEVER A SILENT EMPTY. An empty absent_terms and an
        unreadable queue produce the identical park message, and the phase-5 drill spent a person's
        afternoon on that ambiguity.
        """
        rc, out, err = await self.ps(INGREDIENT_QUEUE_PS,
                                     ["-List", "-Status", "pending", "-Json"], timeout=300)
        text = (out or "").strip()
        if rc != hunt_lib.EXIT_CLEAN:
            return [], "ingredient-queue exited %s: %s" % (rc, ((text + (err or "")).strip())[:200])
        i = text.find("{")
        if i < 0:
            return [], "the queue printed no JSON object: %s" % text[:200]
        try:
            doc = json.loads(text[i:])
        except Exception as e:                                    # noqa: BLE001
            return [], "the queue's -Json output would not parse (%s): %s" % (e, text[:200])
        added = []
        for it in (doc.get("items") or []):
            term = str(it.get("term") or "").strip()
            if not term:
                continue
            recipes = [str(r) for r in (it.get("recipes") or []) if r]
            if not any(r in self.pricing_slugs for r in recipes):
                continue
            # The same two guards the map lane applies: a term already queued for this process, and a
            # term this run has already sent to the pricer, are never sent twice.
            if term in self.absent_terms or term in self.priced_terms:
                continue
            self.absent_terms.append(term)
            added.append(term)
        return added, ""

    async def seed(self):
        """Section 4.5's resume seed table, NORMATIVE so nobody re-derives it. A recipe enters at the
        lane matching the state it actually stopped at, and flows down from there under its own steam."""
        st, err = await self.status_json()
        if st is None:
            return False, err
        rows = [(r["slug"], hunt_lib.norm_state(r["state"])) for r in (st.get("in_flight") or [])]
        parked = [p["slug"] for p in (st.get("parked") or [])]
        counts = {}
        mapped_holds = []

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
                # NOT the held list yet - the hold gets RE-CHECKED first (D7's unhold path). Collected
                # here and handled in one mechanical map-preresolve pass below, because seeding
                # straight to the held list is what strands a recipe whose bid has since been wired.
                mapped_holds.append(slug)
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
        # THE UNHOLD, before anything is reported as held. One mechanical pass, zero agents.
        if mapped_holds:
            n = await self.unhold_mapped(mapped_holds)
            if n:
                counts["unheld"] = n
        for slug in parked:
            self.pricing_slugs.add(slug)
            self.ch["price_wake"].push(slug)
            counts["price"] = counts.get("price", 0) + 1
        # ---- B5 / PIN P7: absent_terms COME BACK FROM THE QUEUE. -----------------------------
        # Gate finding 3, measured on the phase-5 drill: a resumed run puts every pricing/parked
        # recipe back on the lane by pushing price_wake, and then the lane wakes with NOTHING to
        # drain, because `absent_terms` lived in the memory of the process that mapped them. So it
        # parks every one of them with "a blocking ingredient is still PENDING" and the run cannot
        # re-price at all. The gate drill had to seed absent_terms by hand for exactly this reason.
        # The QUEUE is the durable handoff - its own header says so - and it already knows which
        # terms are pending and which recipes wait on each one. So it is read back here.
        if self.pricing_slugs:
            terms, why = await self.reseed_absent_terms()
            if why:
                self.findings.append("seed: absent_terms could not be repopulated from the queue "
                                     "(%s) - the price lane will park every pricing recipe" % why)
            if terms:
                counts["reseeded_terms"] = len(terms)
                self.log("seed: repopulated %d pending term(s) from the ingredient queue: %s"
                         % (len(terms), ", ".join(terms)))
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
        # THE STUCK LIST, NAMED (added 2026-08-24, phase-4 gate run). The header counted "9 stuck" and
        # said not one word about WHICH or WHY, so the only way to learn that six writers had been paid
        # and every spec build refused was to go and read the run dir. A count is not a report.
        stuck = [o for o in self.outcomes if o.get("status") == "stuck"]
        if stuck:
            lines += ["", "  STUCK (no verdict was rendered - resumable, and each one says why):"]
            for o in stuck:
                lines.append("    %-38s %s" % (o["slug"], (o.get("detail") or "")[:150]))
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

def _is_num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def read_run_band(run_dir):
    """The band the run dir was MINTED with. hunt-run.ps1 -Init refuses to create one without it, so
    a run dir carrying no band block is either pre-2026-08-24 or was made by hand."""
    try:
        with open(os.path.join(run_dir, "run.json"), "r", encoding="utf-8-sig") as f:
            return (json.load(f) or {}).get("band") or None
    except Exception:                                             # noqa: BLE001
        return None


def resolve_band(run_dir, cal_min, cal_max, carb_max, protein_min):
    """Returns (band, why). The run dir states the band; a flag overrides one field for a drill.
    NOTHING supplies a default - a band nobody typed is a band nobody agreed to, and two gates would
    enforce it silently for the whole run."""
    stated = read_run_band(run_dir) or {}
    band = {}
    for key, flag in (("calMin", cal_min), ("calMax", cal_max),
                      ("carbMax", carb_max), ("proteinMin", protein_min)):
        v = flag if flag is not None else stated.get(key)
        band[key] = v
    # EVERY EDGE IS OPTIONAL, SEPARATELY (Brad 2026-08-24 evening). An unstated edge is UNBOUNDED, not
    # a refusal. -Init used to demand the whole band because a CONSTRAINT nobody typed is enforced
    # silently by two gates for a run; the ABSENCE of one cannot wrongly reject anything, so the
    # refusal bought nothing here. What it did buy - a reader knowing what the gates enforced - is kept
    # by run.json and by the effective band this logs on every run.
    if not isinstance(band["calMin"], (int, float)):
        band["calMin"] = 0
    if not isinstance(band["calMax"], (int, float)):
        band["calMax"] = float("inf")
    if not isinstance(band["carbMax"], (int, float)):
        band["carbMax"] = float("inf")
    if band["calMin"] > band["calMax"]:
        return None, ("the band's floor (%s cal) is above its ceiling (%s cal), so it admits nothing "
                      "and the run would source zero recipes without saying why"
                      % (band["calMin"], band["calMax"]))
    # A floor of 0 is how "no protein floor" is said out loud; in_band reads absence as "no rule", so
    # the two must mean the same thing here or a stated 0 would behave like an unstated band.
    if not isinstance(band["proteinMin"], (int, float)) or band["proteinMin"] <= 0:
        band["proteinMin"] = None
    return band, ""


def _edge(v, unbounded_when):
    return "any" if (v is None or unbounded_when) else v


def describe_band(band):
    lo, hi, cm = band["calMin"], band["calMax"], band["carbMax"]
    cal = "any" if (lo <= 0 and hi == float("inf")) else "%s-%s" % (
        lo if lo > 0 else "any", "any" if hi == float("inf") else hi)
    carbs = "any" if cm == float("inf") else "<= %s" % cm
    prot = ">= %s" % band["proteinMin"] if band.get("proteinMin") else "any"
    if cal == "any" and carbs == "any" and prot == "any":
        return "NONE - no calorie, carb or protein limit"
    return "cal %s, carbs %s, protein %s" % (cal, carbs, prot)


def main(argv=None):
    ap = argparse.ArgumentParser(description="the Recipe Hunter daemon (PLAN v3 section 4.1)")
    ap.add_argument("--run-dir", dest="run_dir", default="")
    ap.add_argument("--run", default="")
    ap.add_argument("--conditions", default=DEFAULT_COND)
    # THE BAND IS A RUN PARAMETER AND IS NEVER DEFAULTED HERE (Brad's ruling 2026-08-24). It is stated
    # once, at `hunt-run.ps1 -Init`, written into run.json, and read back below. A flag overrides it for
    # a drill; a run dir whose run.json states no band CANNOT RUN, because the alternative is two gates
    # silently enforcing a constant nobody agreed to. `--protein-min 0` means "no floor", stated out loud.
    ap.add_argument("--cal-min", dest="cal_min", type=float, default=None)
    ap.add_argument("--cal-max", dest="cal_max", type=float, default=None)
    ap.add_argument("--carb-max", dest="carb_max", type=float, default=None)
    ap.add_argument("--protein-min", dest="protein_min", type=float, default=None)
    ap.add_argument("--wave-size", dest="wave_size", type=int, default=hunt_lib.WAVE_SIZE)
    ap.add_argument("--target", type=int, default=0,
                    help="stop popping the pool after N acceptances; 0 pops until the backlog runs "
                         "dry or the WIP limit parks the lane")
    ap.add_argument("--lanes", default="pool,decide,extract,map,price,write,qa")
    ap.add_argument("--ledger", default="",
                    help="a scratch batch ledger, for a drill. Empty means the live one.")
    ap.add_argument("--specs", default="",
                    help="a scratch spec store, for a drill. Empty means the live db\\recipes. NOTE "
                         "build-v2-spec refuses -RunCost unless OutDir IS db\\recipes, so a scratch "
                         "spec store means an UNCOSTED spec and the daemon says so.")
    ap.add_argument("--costed", default="",
                    help="a scratch db\\costed.json, for a drill that runs the REAL cost pass. Empty "
                         "means the live one.")
    ap.add_argument("--pool", default="",
                    help="a scratch candidate pool, for a drill. Empty means the live "
                         "db/candidate-pool.json. Same seam as --ledger / --specs / --costed: it "
                         "exists so a drill can aim the run at a chosen corpus without editing the "
                         "live pool, which harvest.py is the sole writer of.")
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

    band, why = resolve_band(a.run_dir, a.cal_min, a.cal_max, a.carb_max, a.protein_min)
    if band is None:
        say("hunt-daemon: CANNOT RUN - %s" % why)
        say("HUNT-DAEMON-COMPLETE")
        return hunt_lib.EXIT_CANNOT_RUN
    say("hunt-daemon: band %s" % describe_band(band))

    d = Daemon(a.run_dir, a.run or os.path.basename(a.run_dir), a.conditions, band,
               a.wave_size, target=a.target, dry_run_publish=not a.publish, ledger_path=a.ledger,
               specs_dir=a.specs, costed_path=a.costed, pool_path=(a.pool or None))

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
