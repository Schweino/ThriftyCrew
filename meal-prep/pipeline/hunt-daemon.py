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
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
REPO = os.path.dirname(MP)
sys.path.insert(0, HERE)

import fdc_lookup                                                # noqa: E402
import harvest                                                   # noqa: E402
import hunt_dispatch                                             # noqa: E402
import hunt_lib                                                  # noqa: E402
import learn_apply                                               # noqa: E402
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
RESOLUTION_EMBED_PY = os.path.join(HERE, "resolution_embed.py")
# THE SIDECAR'S OWN INTERPRETER, and it is not a preference. torch and sentence-transformers live in
# sidecar\.venv and nowhere else on this box; C:\Codex\Python312 has neither, and the graph's
# interpreter has no numpy at all (graph\pipeline\resolve.py says so in its own header). Named here
# so the ONE call site that needs it cannot drift into shelling `python`.
SIDECAR_PY = os.path.join(REPO, "sidecar", ".venv", "Scripts", "python.exe")
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
    _tee(m)


# ---- T2: THE RUN'S NARRATIVE OUTLIVES ITS TERMINAL (2026-08-25) ---------------------------------
#
# MEASURED: say() printed to stdout and nowhere else, and run.json carried `created` with no
# `finished`. The lane log records what every stage COST; the narrative records what happened to it -
# every finding, every park, every STUCK message, every degrade notice. On a multi-hour attended run
# that is the half a person actually reads, and it existed only in scrollback: close the window, or
# let it scroll past the buffer, and the run is unreviewable while its own artifacts still sit on
# disk looking complete.
#
# UTC-STAMPED PER LINE, because the console had no timestamps at all and the lane log's own `at` is
# second-resolution local time with no zone - correlating a finding against a lane line meant
# guessing. The file is opened per line and appended: a run this long cannot hold a handle across
# hours of subprocess churn, and an append-per-line survives a kill -9 with everything up to the last
# line intact.
#
# IT CAN NEVER RAISE. This is the say() lesson exactly - a log line must not be able to end a run -
# so every failure here is swallowed, including the failure to open the file. A narrative that
# refuses to write is a lost narrative; a narrative that throws is a lost RUN, and one of those has
# already happened to this estate.
_LOG_PATH = [None]


def set_log_file(path):
    """Point say() at a file. Called once the run dir is known; before that, stdout only."""
    _LOG_PATH[0] = path
    return path


def _tee(m):
    path = _LOG_PATH[0]
    if not path:
        return
    try:
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(path, "a", encoding="utf-8", errors="replace", newline="\n") as fh:
            fh.write("%s %s\n" % (stamp, m))
    except Exception:                                             # noqa: BLE001
        pass


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


# ---------------------------------------------------------------------------------------------------
# THE TARGET CAP (2026-08-26). See decide_lane's header for the run that paid for it.
#
# PURE, and separated from the lane for the usual reason: the arithmetic is worth a fixture of its own.
# But the arithmetic is not where the defect was - the defect was that nothing called anything - so the
# suite pins the CALL SITE too. (Twice in the map-judge build a neuter came back 0 red because a
# fixture pinned a function while the bug lived at its call site; PLAN-map-judge-split-2026-08-25 s4.)
#
# DEFERRED, NOT REJECTED, and the difference is the whole reason this verdict is the right one to
# rewrite to. `deferred` means "the decider looked and did not decide": no run state, no
# considered-dishes record, and harvest --mark-ruled puts the pool entry back to `available`. A
# candidate held back by an arithmetic limit has had nothing said about it, and burying it under a
# rejection would teach every future run a ruling no decider ever made. Its OWN reason is carried
# through verbatim inside the deferral so the ruling that was overruled is still legible.
#
# The record block goes with it: DECIDE_RECORDS_RULING["deferred"] is False, so nothing would read it,
# and a decision that says `deferred` while carrying a record that says `accepted` is a payload that
# lies about itself.
# ---------------------------------------------------------------------------------------------------

def cap_accepts_to_target(payload, already_accepted, target):
    """Rewrite every acceptance PAST the run's target into a deferral.

    Returns (payload, deferred_slugs). The payload is rebuilt rather than mutated - the caller holds
    the agent's own reply and a run report that reprinted a doctored verdict as the decider's would be
    a second lie. A falsy target means no limit was asked for and nothing is touched."""
    if not target:
        return payload, []
    decisions = (payload or {}).get("decisions") or []
    room = target - already_accepted
    out, deferred = [], []
    for d in decisions:
        if d.get("verdict") != "accepted":
            out.append(d)
            continue
        if room > 0:
            room -= 1
            out.append(d)
            continue
        held = dict((k, v) for k, v in d.items() if k not in ("record", "dupe_of"))
        held["verdict"] = "deferred"
        held["reason"] = ("held back by this run's target of %d acceptance(s), which was already "
                          "met - back on the shelf unruled, not rejected. The decider's own ruling "
                          "was ACCEPT: %s" % (target, d.get("reason") or "(no reason given)"))
        out.append(held)
        deferred.append(d.get("slug"))
    return dict(payload, decisions=out), deferred


# =====================================================================================================
# The daemon
# =====================================================================================================

class Daemon(object):

    def __init__(self, run_dir, run_id, conditions=DEFAULT_COND, band=None, wave_size=None,
                 target=0, dry_run_publish=True, pool_path=None, dispatcher=None, ps=None,
                 quiet=False, ledger_path="", preresolve_args=(), specs_dir="",
                 costed_path="", pyrun=None, food_db_path="", queue_path="",
                 carriage_path="", considered_path="", events_path="", resolutions_path=""):
        self.run_dir = run_dir
        self.run_id = run_id
        # T2: the narrative gets a file the moment the run dir is known. A QUIET daemon is a fixture
        # and never writes one - the same guard self.log already uses, so no suite grows a side effect.
        if not quiet:
            set_log_file(os.path.join(run_dir, "daemon.log"))
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
        # A SCRATCH FOOD DB, for exactly the reason the three above exist, and added with CHANGE M
        # (2026-08-25) because that change makes the daemon a WRITER of this file. Before it, a drill
        # could not put a row into food-macros-db.json even by accident; now it can, and the live DB
        # is read by every spec build and every macro recompute in the estate. Empty means the live
        # one, which is what a real run wants.
        self.food_db_path = food_db_path or os.path.join(MP, "food-macros-db.json")
        # WHERE A REFUSAL GOES TO BE READ A WEEK LATER (rung 3, 2026-08-26). The conflict rule's
        # verdict was right and stays exactly as it is - nothing is ever overwritten - but its whole
        # output was one line in one run's findings, which scrolls away with the run. A gate whose
        # result nobody can find later is a gate that only ever fires once. BESIDE THE FOOD DB, not
        # at a fixed path, so the food_db_path test seam carries the ledger with it and a drill can
        # never append to the live one.
        self.food_db_conflicts_path = os.path.join(
            os.path.dirname(os.path.abspath(self.food_db_path)), "food-db-conflicts.jsonl")
        # ONE PEN, ONE LOCK. The map lane runs two workers and both may carry new rows for the same
        # single file, which is the ingredient-resolutions lesson (S4: 2,293 outcomes recorded as 65
        # under last-writer-wins) arriving at the food DB. Modelled on cost_lock above.
        # H2 (2026-08-25): THE THREE LEDGERS A NO-PUBLISH DRILL WAS STILL WRITING. Measured on jc1:
        # with --ledger, --specs, --costed and --food-db all engaged and publish dry, the run still
        # wrote live grocery\ingredient-queue.json, grocery\carriage.json and
        # meal-prep\db\considered-dishes.json. The queue rows were real evidence and were kept
        # deliberately, but the SEAM GAP is the defect - the next drill may not be so lucky.
        # Two of the three seams already existed on the scripts (-QueueFile, and -Store on
        # considered-dishes.ps1, which decide_apply already threads); only carriage needed a new one
        # (-CarriagePath on ingredient-queue.ps1's -Promote). Empty means the live ledger, which is
        # what a real run wants.
        self.queue_path = queue_path
        self.carriage_path = carriage_path
        self.considered_path = considered_path
        # TWO MORE SEAMS, AND THE H2 LESSON IS WHY THEY EXIST BEFORE THE FIRST DRILL RATHER THAN
        # AFTER IT (PLAN-ingredient-memory D1). This build makes the daemon a WRITER of two more
        # estate-wide files: meal-prep\db\ingredient-events.jsonl and, through
        # ingredient-resolutions.ps1 -Record, meal-prep\db\ingredient-resolutions.json. The second
        # is read as STEP 1 of the per-line resolution ladder on every recipe the estate ever maps,
        # so a drill row in it is not a test artifact - it is an identity every future run will
        # believe. H2 found three live ledgers a no-publish drill was still writing precisely
        # because their seams were added late; these are added with the writer.
        self.events_path = events_path
        self.resolutions_path = resolutions_path
        self.food_db_lock = asyncio.Lock()
        # F1 (2026-08-25): THE SAME ONE-PEN-ONE-LOCK RULE FOR THE FDC CACHE. fdc_lookup.cache_write is
        # a whole-file write and two map workers can fill overlapping term lists at the same moment;
        # this is the ingredient-resolutions lesson arriving at a third file. See fill_fdc_shelf for
        # why the fill runs in the executor - without a real await between read and write the lock
        # would be decorative and its neuter proof unproducible.
        self.fdc_lock = asyncio.Lock()
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
        self.lane_deaths = {}           # lane -> why, for any lane `contained` caught

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

    def queue_seam_note(self):
        """H2: the drill's queue seams, said to the PRICER - which holds this pen itself.

        The daemon can thread -QueueFile onto its own calls, and does; it cannot thread anything onto
        a call an agent makes. So on a seamed run the prompt names the flags, and the note exists at
        all only when a seam is set - a real run's prompt is byte-identical to what it was.
        """
        if not (self.queue_path or self.carriage_path):
            return ""
        flags = []
        if self.queue_path:
            flags.append("-QueueFile '%s'" % self.queue_path)
        if self.carriage_path:
            flags.append("-CarriagePath '%s'" % self.carriage_path)
        return ("\nTHIS IS A DRILL ON SCRATCH LEDGERS. Add %s to EVERY ingredient-queue.ps1 call you\n"
                "make - -RecordBatch, -Verdict and -Promote alike. Without those flags your evidence\n"
                "lands in the live Omaha ledgers, which the cost engine and the publish gate read as\n"
                "fact.\n" % " and ".join(flags))

    def specs_seam_note(self):
        r"""T6 (2026-08-25): the drill's SPEC STORE, said to the AUDITOR - which holds its own tools.

        Measured on lf1: the wave-1 auditor reported that "the certified spec is the stale 2026-08-16
        lowcarb-100 build". It had read meal-prep\db\recipes while the drill was pointed at a scratch
        store through --specs, because the drill reused a slug that already exists live. It produced
        a real NO-GO on a real disagreement, so no gate was fooled - but the disagreement was between
        two DIFFERENT FILES, which is not a finding about the recipe, and a drill on a fresh slug
        would never have surfaced it.

        The mechanical half is seamed in the same commit (the preaudit battery, the QA battery and
        the staleness mtimes). This is the half no argument can reach: an agent that decides to open
        the file itself needs to be told which file is this run's.

        THE NOTE EXISTS ONLY WHEN A SEAM IS SET, so an unseamed run's prompt is byte-identical.
        """
        if not self.specs_dir:
            return ""
        return ("\nTHIS IS A DRILL ON A SCRATCH SPEC STORE at %s. Every certified spec in this wave\n"
                "is THERE, not in meal-prep\\db\\recipes. A slug that also exists live has an OLDER\n"
                "file at the live path, and a disagreement with THAT file is a disagreement between\n"
                "two files rather than a finding about this recipe.\n" % self.specs_dir)

    def food_db_seam_note(self):
        """M4 (2026-08-25): the drill's FOOD DB seam, said to the MAPPER.

        Modelled exactly on queue_seam_note, and for the same measured reason: on lf1 round 2 the
        mapper verified against meal-prep\food-macros-db.json four times while the drill was pointed
        at a scratch copy through --food-db, so every conflict it weighed was against the wrong file.

        THE NOTE EXISTS ONLY WHEN A SEAM IS SET. food_db_path defaults to the live file, so an
        unseamed run's prompt stays byte-identical to what it was.
        """
        live = os.path.join(MP, "food-macros-db.json")
        if os.path.normcase(os.path.abspath(self.food_db_path)) == os.path.normcase(
                os.path.abspath(live)):
            return ""
        return ("\nTHIS IS A DRILL ON A SCRATCH FOOD DB at %s. Verify against THAT file, not\n"
                "meal-prep\\food-macros-db.json.\n" % self.food_db_path)

    # ---- THE HARNESS'S OWN GREP, SAID ONCE TO EVERY JUDGE THAT SWEEPS ------------------------------
    #
    # MEASURED 2026-08-25 (EVAL-registrar-batch-2026-08-25.md), reproduced with controls before a word
    # of this was written. The 2-proposal registrar opened with the RIGHT move - one parallel request,
    # one semantic sweep per food family, the identical shape that closed a batch of ONE in 3 turns -
    # and its brace glob carried `out/recipe-board-everyday.json`. Both sweeps returned "No matches
    # found" against files that demonstrably carry the matches. It then spent 2 turns proving the
    # silence was false, 4 redoing the sweep file by file, and 1 more on the minified feed: 7 of 12
    # turns, and at least 44,109 raw of a 123,401 session, none of it registrar work.
    #
    # THE MECHANISM IS RIPGREP'S, NOT A BUG TO ROUTE AROUND BLIND. A glob with no separator matches the
    # BASENAME at any depth; a glob WITH one is anchored at the REPO ROOT rather than at the `path`
    # argument; and one separator anywhere in a brace anchors EVERY alternative in it, which is what
    # turned a four-file sweep into a false empty. Naming the real rule is why this says "use
    # grocery/out/x.json or **/out/x.json" instead of the superstition "avoid slashes" - a rule that
    # explains itself survives the next harness change, and a taboo does not.
    #
    # THE ONE THING THIS MUST NEVER DO IS DISCOURAGE THE SWEEP. In all three registrar transcripts read
    # for that eval the sweep produced the DECISIVE evidence of the ruling: pork-shoulder's own
    # `pulled` exclude, gouda existing in the estate only inside another cheese's exclude pattern, and
    # reduced-fat-mozzarella, which the word-overlap dossier could not see. The dossier cannot carry
    # that work - ranking by shared words is mechanical, but choosing which OTHER words a food hides
    # under is judgment, the fork PLAN-latency 3.2 closed and this note keeps closed. So every sentence
    # here distrusts the empty RESULT and none of them distrusts the sweep.
    #
    # THE PRICER AND THE DECIDER ARE DELIBERATELY LEFT OUT. Both carry Grep, and neither sweeps a
    # namespace: the pricer adjudicates store rows gathered by the pre-pass, and the decider ruled 3
    # candidates in 1 turn off a whole dossier. Prompt weight buys nothing where nobody greps.
    GREP_HARNESS_NOTE = (
        "\nYOUR `glob` AND THIS HARNESS, measured 2026-08-25 - this cost one registrar 7 of its 12\n"
        "turns. A glob with NO separator matches the BASENAME AT ANY DEPTH, so `commodities.json` also\n"
        "reads the `regression-inputs\\` and `engine-backup\\` copies - read the paths in your hits. A\n"
        "glob CONTAINING a separator is anchored at the REPO ROOT, not at your `path` argument:\n"
        "`out/smp-feed.json` matches NOTHING, while `grocery/out/smp-feed.json` and\n"
        "`**/out/smp-feed.json` both work. And ONE separator anywhere in a brace anchors EVERY\n"
        "alternative in it, so `{commodities.json,out/recipe-board-everyday.json}` returns \"No matches\n"
        "found\" for both files - a FALSE EMPTY that reads exactly like proof the estate is clean. A\n"
        "backslash in a glob never matches at all. An empty sweep is the thing to distrust, never a\n"
        "reason to stop sweeping: re-run it per file before you believe it.\n"
        "`grocery\\out\\smp-feed.json` IS ONE MINIFIED LINE, so a content-mode grep on it returns\n"
        "\"[Omitted long matching line]\" and shows you nothing. Use `-o` with a context pattern such as\n"
        "`.{60}(?:your|terms).{60}`.\n")

    def queue_args(self, args):
        """H2: the queue call, with the drill's seams appended when they are set.

        ONE ROAD for the same reason ps_invoke is one road: three call sites appending their own
        flags is three places for a drill seam to be forgotten, and the forgetting is silent - it
        writes a live grocery ledger and nothing says so.
        """
        out = list(args)
        if self.queue_path:
            out += ["-QueueFile", self.queue_path]
        if self.carriage_path:
            out += ["-CarriagePath", self.carriage_path]
        return out

    async def ps(self, script, args, timeout=600):
        """EVERY PowerShell call goes through hunt_lib.ps_invoke - never a second invocation style.
        `-File` cannot bind a multi-element [string[]] from argv at all (it drops or composites), and
        both broken shapes are frozen as must-fire fixtures in decide_apply's suite."""
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, lambda: self._ps(script, args, timeout))

    async def py(self, script, args, timeout=600, exe=""):
        """EVERY Python surface goes through hunt_lib.py_invoke, for the same one-road reason `ps`
        exists - and never through ps_invoke, which would try to marshal a Python script as a
        PowerShell command line.

        `exe` names a DIFFERENT interpreter for the surfaces that need one. The estate has three and
        they are not interchangeable: resolution_embed.py imports torch, which lives only in
        sidecar\\.venv. It still rides this road, because a second subprocess style in the daemon is
        the thing the one-road rule exists to prevent."""
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, lambda: self._py(script, args, timeout, exe))

    @staticmethod
    def _stamp_ago(seconds):
        """hunt-run's own stamp format (yyyy-MM-ddTHH:mm:ss, local, no zone), N seconds back."""
        return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(time.time() - max(0.0, seconds)))

    async def lane(self, lane_name, label, items, by, event, tokens_in=-1, tokens_out=-1,
                   detail="", cache_read=-1, cache_creation=-1, calls=-1,
                   all_in=-1, all_out=-1, models="", api_turns=-1, at=""):
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
        if at:
            args += ["-At", at]
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

    # ---- Q3 (2026-08-26): THE OUTCOME AND THE STATE FILE MOVE TOGETHER, OR NEITHER DOES -----------
    #
    # THE DEFECT THIS DELETES. Every terminal outcome in this daemon was written by a PAIR of calls -
    # `finish` (the run record) and `-Advance` (the state file on disk) - and NOT ONE of the eight
    # call sites checked whether the second one was accepted. `advance` returns a bool and appends a
    # finding on refusal; every caller threw it away. So a refused transition left the run reporting a
    # verdict that the state file does not carry, which reads on disk as a recipe STILL IN FLIGHT and
    # is invisible to everyone watching - the same shape as the first build's priced -> rejected-qa
    # advance, which _band_gate_real_machine exists to catch.
    #
    # THE ONE THAT WAS LIVE, found in the map lane on 2026-08-26. A mapper rejection defaulted its
    # state to `rejected-not-carried` while the recipe was still `extracted`, and hunt-run.ps1's table
    # allows that state only from `mapped`, `pricing` and `parked`. The rejection was written, the
    # advance was refused, and the recipe sat at `extracted` looking stuck with a rejection already
    # recorded against it - the worst of both halves. ORDERING WAS NOT THE CAUSE and swapping it is
    # not the fix. Three of the eight sites called finish first and four called advance first, and
    # every one of those seven wrote the outcome unconditionally either way; the eighth (the map
    # lane's no-servings pick-up refusal) advanced and recorded NO outcome at all, which is the same
    # pair broken at the other end. What was missing everywhere was the ANSWER.
    #
    # THE STATE MACHINE STAYS THE ONLY AUTHORITY ON WHAT IS LEGAL. This helper duplicates NO part of
    # hunt-run.ps1's `$script:NEXT` - it asks, and it believes the answer. A legality table copied
    # into Python is a second table, and two tables are two tables that drift.
    async def settle(self, slug, state, by, detail, stage, status="rejected", outcome_detail=None):
        """Advance FIRST; record the outcome only if the state file actually moved. Returns bool.

        A missing state or a refused transition is a STUCK - a recipe a person can act on, with the
        refusal quoted - and never an outcome. Same rule as `stuck`'s own note: nothing is recorded
        as if somebody had ruled when the record cannot be made to say it.
        """
        said = as_text(detail)
        if not state:
            why = ("%s returned a %s verdict but named no terminal state, so nothing here can say "
                   "which one it is: %s" % (by, status, said[:200] or "no detail given"))
            self.stuck(slug, stage, why)
            self.log("  %s: %s STUCK - a %s verdict naming no state" % (stage, slug, status))
            return False
        was = self.state_of(slug) or "?"
        if not await self.advance(slug, state, by, said[:200]):
            why = ("the state machine refused %s -> %s, so this %s is NOT on disk and the recipe is "
                   "still at %s: %s" % (was, state, status, was, said[:200] or "no detail given"))
            self.stuck(slug, stage, why)
            self.log("  %s: %s STUCK - %s -> %s was refused" % (stage, slug, was, state))
            return False
        self.finish(slug, status, state, said if outcome_detail is None else outcome_detail)
        return True

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

    # ---- THE FREE END LINE (2026-08-25) ---------------------------------------------------------
    #
    # A STAGE THAT BILLED NOTHING SAYS ZERO IN EVERY TOKEN FIELD, NOT IN TWO OF THEM. -1 means "not
    # reported" in this log, and the difference matters: -LaneSummary and every future reader treat
    # -1 as unmeasured Claude work and 0 as work that cost the run nothing.
    #
    # MEASURED on hunt-2026-08-24-v3-phase6b's lane-log.jsonl: every mechanical end line carries
    # in=0 out=0 (which the G fixture asserted) and cache_read=-1, cache_creation=-1, calls=-1,
    # api_turns=-1, all_in=-1, all_out=-1 (which nothing asserted). The pre-pass road stamped -1 in
    # all eight. The instrument that Thursday's wide run gets measured with was reporting its own
    # free stages as unmeasured.
    #
    # ONE ROAD, so the contract cannot fork across the three call sites that need it: ps_timed /
    # py_timed (mechanical), the local extraction ladder (local), and the price pre-pass (pre-pass).
    async def lane_free_end(self, lane_name, label, items, by, detail=""):
        return await self.lane(lane_name, label, items, by, "end",
                               tokens_in=0, tokens_out=0, detail=detail,
                               cache_read=0, cache_creation=0, calls=0,
                               api_turns=0, all_in=0, all_out=0)

    # ---- MECHANICAL STAGE TIMING (2026-08-24) ---------------------------------------------------
    #
    # WHY. Token burn was fully instrumented; wall clock was not. Measured on the 6b run, 99% of the
    # 63.5-minute span had SOMETHING logged in flight and only 49 s sat in gaps - but that is
    # COVERAGE, not ATTRIBUTION. Every mechanical stage - map-preresolve, the skeleton, the spec
    # build, build-card2, the preaudit battery, wave-publish - emitted nothing, so its time either
    # fell in a gap or hid underneath a concurrent lane. Two of the three gaps over 5 s were the
    # preaudit battery, which self-times in its own report and tells the lane log nothing. At 9
    # recipes that is invisible; at 200 those stages scale and stay invisible.
    #
    # THE CONVENTION IS THE LOCAL LADDER'S, so no reader changes: a start/end pair with tokens 0,
    # which -LaneSummary already reads as work done rather than work unmeasured.
    #
    # THE RECURSION TRAP, NAMED SO NOBODY REBUILDS IT: `lane()` itself calls `ps()`. Timing every
    # ps() call would make each lane line spawn two more, forever. So this is a SEPARATE verb that
    # call sites opt into, and lane() keeps using plain ps().
    async def ps_timed(self, lane_name, label, items, script, args, timeout=600, by="mechanical"):
        await self.lane(lane_name, label, items, by, "start")
        t0 = time.time()
        try:
            return await self.ps(script, args, timeout)
        finally:
            await self.lane_free_end(lane_name, label, items, by,
                                     "%.1fs" % (time.time() - t0))

    async def py_timed(self, lane_name, label, items, script, args, timeout=600, by="mechanical"):
        await self.lane(lane_name, label, items, by, "start")
        t0 = time.time()
        try:
            return await self.py(script, args, timeout)
        finally:
            await self.lane_free_end(lane_name, label, items, by,
                                     "%.1fs" % (time.time() - t0))

    # ---- the cost engine, serialized ------------------------------------------------------------

    async def cost_engine(self, script, args, timeout=1800, lane=None, stage=None, items=None):
        """EVERY cost-engine invocation goes through here and nowhere else."""
        async with self.cost_lock:
            t0 = time.time()
            try:
                # TIMED, AND THE TIMING NO LONGER THROWN AWAY. cost_passes existed only so a fixture
                # could prove the passes never overlap; the durations were collected and discarded.
                if stage:
                    return await self.ps_timed(lane or "write", stage, items or [], script, args, timeout)
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
                # A SAVING, NOT THE BOUND (2026-08-26). This reads a count only the decide lane
                # writes, and by the time it reads it the channel already holds up to
                # 2*DECIDE_BATCH unruled dossiers - so it stops the POPS and cannot stop the
                # ACCEPTANCES. The bound itself lives in decide_lane, whose header carries the run
                # that proved it: `--target 10` closed with 20 slugs in accepted-slugs.json.
                if self.target_met():
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
    #
    # AND THE ONLY PLACE `--target N` CAN ACTUALLY BE ENFORCED (measured 2026-08-26, hunt-2026-08-26-ten).
    #
    # WHAT THE RUN DID. Launched at `--target 10`, it printed "pool: target of 10 reached - popping
    # nothing further" after batch 4 and then ruled batches 5 and 6 anyway. accepted-slugs.json closed
    # with TWENTY slugs against a target of ten.
    #
    # WHY THE POOL GATE COULD NEVER HAVE HELD IT. The pool checks the target BEFORE it pops, but by
    # then it has already pushed up to `2 * DECIDE_BATCH` dossiers into the decide channel - that
    # pre-fill is the channel's backpressure limit and it is the whole reason the decider never waits
    # on the pool. So the count the pool reads is STALE BY EVERYTHING IN FLIGHT: at pop time nothing
    # in the buffer has been ruled yet, and a producer cannot bound a number only its consumer
    # writes. Worst case a `--target N` run decided N + 2*DECIDE_BATCH candidates.
    #
    # WHY THAT IS EXPENSIVE. An acceptance costs nothing upstream and everything DOWNSTREAM -
    # extraction, the Opus mapper, the Opus pricer, the writer, source-QA and the batch auditor all
    # run per accepted recipe. Ten extra acceptances is roughly double the run's intended spend.
    #
    # SO THE BOUND MOVED TO THE WRITER OF THE COUNTER. Two halves, and both are needed:
    #   1. A batch taken while the target is already met is NOT DISPATCHED at all - no decider call,
    #      no --mark-taken, and its candidates stay `available` for the next run.
    #   2. A batch that CROSSES the target mid-verdict is capped: the acceptances past the target are
    #      rewritten to `deferred` BEFORE decide_apply sees the payload, because decide_apply is what
    #      advances the state machine, records the ruling and appends accepted-slugs.json. Capping
    #      after it would be capping a number that has already been spent.
    #
    # WHY NOT SHRINK THE PRE-FILL OR TRIM THE POP INSTEAD. Both were weighed and neither BOUNDS
    # anything: they read the same stale count the pool gate reads, so a full batch of acceptances
    # can still cross the target from under either of them. Trimming the dispatch also shrinks the
    # decider's own cross-candidate view, which is what makes it one decider rather than N; and a
    # `wait_for_space` computed from `target - accepted` reaches zero, and `wait_for_space(0)` parks
    # on a limit nothing can lower - B9, exactly the trap the pool lane's own comment names. This
    # lane keeps DRAINING the channel in half 1 rather than breaking out of its loop for the same
    # reason: the take is what wakes a pool parked on backpressure, and a consumer that stops taking
    # while its producer is parked is B9 wearing a different hat.
    # ---------------------------------------------------------------------------------------------

    def target_met(self):
        """Has this run bought everything it was asked to buy? ONE reading of the target, shared with
        the pool gate, so the two cannot come to disagree about what `--target N` counts. On a
        --resume `accepted_slugs` is seeded with everything already in flight, which makes N a TOTAL
        for the run rather than N more - the pool gate has always meant that and this keeps it."""
        return bool(self.target) and len(self.accepted_slugs) >= self.target

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
            # HALF 1 OF THE TARGET BOUND. Drained, deliberately, and not dispatched: the take is
            # what wakes a pool parked on the channel's backpressure, so breaking out of this loop
            # here would strand the producer (B9). Nothing is marked taken and no decider is paid -
            # these candidates stay `available` and are the next run's to rule on.
            #
            # AHEAD OF THE WIP PARK, not behind it: a lane that has decided to spend nothing has no
            # reason to wait for room to spend it in, and parking here would hold the drained batch
            # and stop feeding a pool parked on backpressure until some recipe downstream resolved.
            if self.target_met():
                self.log("decide: the target of %d acceptance(s) is met - %d buffered dossier(s) "
                         "left unruled and available (%s)"
                         % (self.target, len(items), ", ".join(c["slug"] for c in items)))
                continue
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

            # HALF 2 OF THE TARGET BOUND, and it is BEFORE apply_verdict on purpose. apply_verdict
            # is what advances the state machine, writes the ledger and appends accepted-slugs.json;
            # a cap applied after it would be capping money already spent.
            payload, over = cap_accepts_to_target(payload, len(self.accepted_slugs), self.target)
            if over:
                self.log("decide: %d acceptance(s) past the target of %d deferred rather than "
                         "accepted - back on the shelf, not rejected (%s)"
                         % (len(over), self.target, ", ".join(over)))
            loop = asyncio.get_event_loop()
            applied, findings = await loop.run_in_executor(
                None, lambda: decide_apply.apply_verdict(payload, self.run_dir, self.run_id,
                                                         self.pool_path, self.considered_path,
                                                         False, True))
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
                        #
                        # T3 (2026-08-25): THE START LINE IS BACKDATED, and it has to be. The rung is
                        # only known once the page has settled, so the label cannot exist before the
                        # work - which is why both lines used to be written here, back to back, and
                        # -StageSummary ranked every local extraction at ~0 s while the real duration
                        # sat in `detail` as prose no reader parses. A fake zero is worse than a gap:
                        # it reads as a stage that cost nothing. sweep_one reports its own seconds, so
                        # the start line is stamped that far back and the pair now measures the work.
                        await self.lane("extract", "local rung %d" % rec["rung"], [rec["slug"]],
                                        "local", "start",
                                        at=self._stamp_ago(rec.get("seconds") or 0))
                        await self.lane_free_end("extract", "local rung %d" % rec["rung"],
                                                 [rec["slug"]], "local",
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
            await self.settle(slug, "rejected-unreadable", "extractor",
                              payload.get("reason") or "the extractor could not read the page",
                              "extract")
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
        rc, out, err = await self.ps_timed(
            "map", "map-preresolve", list(slugs), MAP_PRERESOLVE_PS,
            ["-RunDir", self.run_dir, "-Slugs", list(slugs)] + self.preresolve_args, timeout=1200)
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

    # ---------------------------------------------------------------------------------------------
    # F1 (2026-08-25): THE FDC SHELF IS FILLED WITH THE RUN'S OWN TERMS BEFORE THE MAPPER IS PAID.
    #
    # THE MEASURED DEFECT. map-preresolve attaches FDC candidates per unresolved term from
    # meal-prep\db\fdc-cache.json, and PLAN-hunter-judge-contract 3.1 assumed "candidates arrive".
    # On the jc1 drill they did not: 4 of 19 residual lines carried a candidate and 15 did not, and
    # the mapper spent ~12 minutes at 61 s/turn acquiring labels it then cited as `fdc:<id>` - proof
    # the data was reachable by the offline tool the whole time. The root cause was not the shelf
    # code. It was that NOTHING CALLED fdc_lookup.cache_fill for a run's terms; the cached terms were
    # leftovers from a manual pass.
    #
    # WHY EXACT TERMS AND NOT HEAD NOUNS. cache_get's docstring is a ruling: the cache is "KEYED BY
    # THE RECIPE'S OWN TERM, not by a canonical food name, and that is the point". Filling per run
    # with the recipe's own phrasing makes exact-key hits and respects it. Fuzzy or head-noun keying
    # was REFUSED in plan 3.2: stripping `garlic cloves` toward its head noun reaches `cloves`, and
    # the near-miss table already shows `garlic cloves` sitting beside `Ground Cloves` - a wrong-food
    # shelf served with mechanical confidence. Local code may rank; it may never assert identity.
    # ---------------------------------------------------------------------------------------------

    # The exact string map-preresolve.ps1 prepends when it attaches the shelf (its FDC attach, the
    # `$evidence.Add("USDA FDC rows that MENTION this term...` line). Matching on the marker is how
    # coverage is read back out of the table without a second renderer.
    FDC_SHELF_MARKER = "USDA FDC rows that MENTION this term"

    def fdc_fill_terms(self, tables):
        """The fill list, taken from the pre-resolve TABLES and never from the extraction.

        Every row that is not fully settled: `resolution != 'resolved'` OR no food-DB row. A settled
        line with a food-DB row needs no label and no shelf. Deduped case-insensitively through
        fdc_lookup's own key function, so the dedup here and the cache's keying cannot drift apart.
        """
        terms, seen = [], set()
        for slug in sorted(tables or {}):
            for r in ((tables.get(slug) or {}).get("rows") or []):
                if not isinstance(r, dict):
                    continue
                if r.get("resolution") == "resolved" and r.get("fooddb_known") is not False:
                    continue
                term = str(r.get("term") or r.get("raw") or "").strip()
                key = fdc_lookup._cache_key(term)                  # noqa: SLF001
                if not key or key in seen:
                    continue
                seen.add(key)
                terms.append(term)
        return terms

    async def fill_fdc_shelf(self, slugs, tables):
        """Ask FDC about this batch's own terms and store the candidates. Returns cache_fill's stat
        dict {added, skipped, failed}, or None when there was nothing to fill or the fill could not run.

        IN THE EXECUTOR, UNDER A LOCK, AND BOTH HALVES ARE THE SPEC. cache_fill is synchronous
        network code; run on the event loop it would stall every other lane for its whole wall. The
        executor is also what puts a real await between the cache's read and its write, which is what
        makes fdc_lock LOAD-BEARING rather than decorative - the CHANGE M correction, a second time:
        with the I/O synchronous nothing can interleave, so a neuter proof cannot be produced and the
        fixture would be proving the scheduler.

        DEGRADE, NEVER BLOCK. This stage can only ADD evidence. A missing key, a transport failure or
        a whole fill that throws logs ONE finding naming the count and the map dispatch proceeds
        exactly as it did before this method existed. Exit 2 semantics do not apply here.

        NOT PARALLELISED, DELIBERATELY. api.data.gov rate limits, and a throttled key reads as "FDC
        has nothing" - which fdc_lookup's own header calls the worst possible lie for a nutrition
        lookup to tell. page_size 4 with a 0.5s pause over a micro-batch's residual is ~30-60s - four
        rows per term rather than three costs no extra request, only a longer reply (M1).
        """
        terms = self.fdc_fill_terms(tables)
        if not terms:
            return None
        label = "fdc-fill"
        await self.lane("map", label, list(slugs), "mechanical", "start")
        t0 = time.time()
        st = None
        try:
            loop = asyncio.get_event_loop()
            async with self.fdc_lock:
                st = await loop.run_in_executor(
                    None, lambda: fdc_lookup.cache_fill(terms, page_size=4, pause=0.5))
        except Exception as e:                                    # noqa: BLE001
            self.findings.append("F1: the FDC fill could not run (%s) - the mapper will acquire "
                                 "labels itself for %d term(s)" % (str(e)[:160], len(terms)))
            st = None
        finally:
            await self.lane_free_end("map", label, list(slugs), "mechanical",
                                     "%.1fs, %d term(s)" % (time.time() - t0, len(terms)))
        if st and st.get("failed"):
            # A failed lookup is NOT stored by fdc_lookup (its own rule, fixtured there), so this is
            # a retry next run and not a frozen "FDC has nothing". It is still worth a finding: a
            # whole batch failing is what a missing or throttled key looks like from here.
            self.findings.append("F1: the FDC fill could not run for %d of %d term(s) - the mapper "
                                 "will acquire those labels itself"
                                 % (st["failed"], len(terms)))
        return st

    def shelf_coverage(self, tables):
        """(shelved, needing, lacking_terms) read back off the tables through the attach's marker.

        The population is the rows map-preresolve marks as having NO food-macros-db row, because
        those are the only rows the attach can serve - a settled line with a DB row never gets a
        shelf and counting it as a gap would report a defect that does not exist.

        A TERM FDC GENUINELY LACKS IS NOT A FINDING. It is the mapper's licensed open-web read, which
        is the correct residue. This exists so the drill and Thursday can correlate mapper turns
        against shelf coverage without transcript archaeology.
        """
        shelved, lacking, seen = 0, [], set()
        for slug in sorted(tables or {}):
            for r in ((tables.get(slug) or {}).get("rows") or []):
                if not isinstance(r, dict) or r.get("fooddb_known") is not False:
                    continue
                term = str(r.get("term") or r.get("raw") or "").strip()
                key = fdc_lookup._cache_key(term)                  # noqa: SLF001
                if not key or key in seen:
                    continue
                seen.add(key)
                if self.FDC_SHELF_MARKER in str(r.get("evidence") or ""):
                    shelved += 1
                else:
                    lacking.append(term)
        return shelved, shelved + len(lacking), lacking

    def log_shelf_coverage(self, tables):
        shelved, needing, lacking = self.shelf_coverage(tables)
        if not needing:
            return None
        line = ("map shelf: %d of %d term(s) with no food-DB row carry FDC candidates%s"
                % (shelved, needing,
                   ("; FDC lacks: %s" % ", ".join(lacking[:12])) if lacking else ""))
        self.log(line)
        return line

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
            # Q2 (2026-08-26): THE UNHOLD ROAD TRANSITS `pricing` TOO. This is the sibling site the M3
            # note named and deliberately left - it carried the identical condition (zero absent terms
            # plus the mapper's own "priced" claim) and advanced `mapped` -> `priced` on that pair
            # alone, so a held recipe whose missing bid was later wired reached a paid page without the
            # carriage union ever reading it. The same hole as the map lane's, on a narrower road: only
            # a recipe held for an unbid line and then unheld travels it. M3 left it because the unbid
            # hold was out of its scope and reported it instead; Brad ruled both roads in scope on
            # 2026-08-26. The state machine now refuses `mapped` -> `priced` outright, so this road
            # could not keep its shortcut even if it wanted one.
            #
            # AND IT GAINS Q1'S POSTCONDITION ON THE WAY, which it never had. This road still enqueued
            # the CLAIM and then advanced - the pre-Q1 order the map lane was fixed out of - so the
            # carriage half of its term list was written to the state file and never put on the queue.
            # That is the stranded-park shape exactly, and it is why the enqueue below reads the record
            # back rather than trusting `absent`.
            if not await self.advance(slug, "pricing", "unhold", "hold cleared",
                                      terms=absent, optional_terms=optional):
                self.stuck(slug, "unhold",
                           "hunt-run refused the advance to pricing; nothing was enqueued")
                self.log("  unhold: %s STUCK - hunt-run refused the advance to pricing" % slug)
                continue
            # THE STATE HAS MOVED OFF `mapped`, so the recipe counts as advanced from here on. Counting
            # it only at the far end would report a recipe that reached `pricing` and then stuck as one
            # the unhold never touched, which is the opposite of what a reader needs to know.
            advanced += 1
            blocking, why_bt = self.blocking_terms(slug)
            if why_bt:
                self.stuck(slug, "unhold", why_bt)
                self.log("  unhold: %s STUCK - %s" % (slug, why_bt))
                continue
            extra = [t for t in blocking if t not in absent]
            if extra:
                self.log("unhold: %s - hunt-run's carriage union added %d blocking term(s) the mapper "
                         "did not report: %s" % (slug, len(extra), ", ".join(extra)))
            if not blocking:
                # Nothing blocks: the board answered every line AND the carriage union found nothing
                # this town does not stock. Out to the writer, no pricer wake, exactly as before -
                # what changed is that the union got to read the recipe first.
                await self.advance(slug, "priced", "unhold",
                                   "hold cleared: every term answered from the board and the "
                                   "carriage union found nothing uncarried")
                self.ch["write"].push(self.record(slug, {"state": "priced"}))
                continue
            refused = []
            for t in blocking:
                rc_q, out_q, err_q = await self.ps(
                    INGREDIENT_QUEUE_PS,
                    self.queue_args(["-Add", "-Term", t, "-Recipe", slug,
                                     "-Why", "%s needs it" % slug]), timeout=180)
                if rc_q != hunt_lib.EXIT_CLEAN:
                    refused.append("%s (%s)" % (t, ((out_q or "") + (err_q or "")).strip()[:120]))
                    continue
                if t not in self.absent_terms and t not in self.priced_terms:
                    self.absent_terms.append(t)
            if refused:
                self.stuck(slug, "unhold",
                           "the queue refused %d blocking term(s): %s"
                           % (len(refused), "; ".join(refused)))
                self.log("  unhold: %s STUCK - the queue refused %d blocking term(s): %s"
                         % (slug, len(refused), "; ".join(refused)))
                continue
            self.pricing_slugs.add(slug)
            self.record(slug, {"state": "pricing", "absent": blocking})
            self.ch["price_wake"].push("unhold of %s" % slug)
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
        table = (tables or {}).get(slug) or {}
        rows = table.get("rows") or []

        work = []
        seen = set()
        for prop in (proposals or []):
            bid = str((prop or {}).get("proposed_bid") or "").strip()
            term = str((prop or {}).get("term") or "").strip()
            if not bid or bid in seen:
                continue
            seen.add(bid)
            row = next((r for r in rows if str(r.get("term") or "") == term), None)
            work.append((bid, term, str((prop or {}).get("evidence") or ""), row))

        if not work:
            # No proposal, no gate to pay for. The dispatch is per BATCH now, so an empty batch would
            # otherwise buy a session to rule on nothing.
            return []

        async def rule(items, siblings=None):
            """ONE dispatch, one dossier, one schema'd verdict array. Returns {proposed_bid: ruling}.

            F2 (2026-08-25). This was one dispatch PER PROPOSAL: measured on jc1, 10 turns and 81,929
            raw tokens to rule ONE id, each paying its own ~7s startup and ~18k fixed input over a
            cold cache. The decider's shape is the answer - 8 candidates, one dossier, one verdict
            array - and it is the same move CHANGE A made one gate over.
            """
            expected = [w[0] for w in items]
            payload = await self.dispatch(
                "commodity-registrar",
                self.registrar_batch_prompt(slug, items, siblings=siblings),
                "map", "registrar:%dx" % len(items), [slug],
                schema=hunt_lib.REGISTRAR_BATCH,
                validator=lambda p: hunt_lib.validate_registrar_batch(p, expected=expected),
                stage="registrar")
            if payload is None:
                # SILENCE IS NOT CONSENT, AND IT IS NOT PARTIAL EITHER. A batch that does not answer
                # leaves EVERY id in it unruled; the assembler then refuses each one.
                self.findings.append("map/%s: the commodity-registrar returned no verdict on %d "
                                     "proposed id(s) (%s) - the line(s) stay unsettled, which is the "
                                     "safe direction" % (slug, len(expected), ", ".join(expected)))
                return {}
            out = {}
            for item in (payload.get("rulings") or []):
                if not isinstance(item, dict):
                    continue
                pb = str(item.get("proposed_bid") or "").strip()
                if pb not in expected or pb in out:
                    continue
                out[pb] = {"proposed_bid": pb,
                           "verdict": str(item.get("verdict") or "").strip().lower(),
                           "bid": str(item.get("bid") or "").strip(),
                           "reason": str(item.get("reason") or "")}
            for pb in expected:
                if pb not in out:
                    self.findings.append("map/%s: the commodity-registrar's batch verdict said "
                                         "nothing about the proposed id '%s' - it stays unsettled, "
                                         "which is the safe direction" % (slug, pb))
            return out

        # ---- PASS 1: ONE DISPATCH FOR THE WHOLE BATCH. Each proposal is still ruled on its own
        # merits against the ESTATE - the three namespaces are on disk and immutable under a hunt -
        # but one session sees its siblings, which is the collision the re-check below exists for
        # made visible IN-PROMPT rather than only after the fact.
        ruled = await rule(work)
        out = [ruled[w[0]] for w in work if w[0] in ruled]

        # ---- PASS 2: THE COLLISION RE-CHECK, which is what makes pass 1 safe to run concurrently.
        # The one thing a concurrent ruling CANNOT see is its siblings in the same batch. Two
        # near-duplicate proposals - `bread-crumbs` and `breadcrumbs`, the exact pair the registrar
        # exists to prevent - would each check the estate, each correctly find no clash there, and each
        # be approved, minting the duplicate the gate is for. Serial rulings never saw each other
        # either (nothing told a later ruling about an earlier one), so this closes a hole that
        # predates the concurrency rather than one the concurrency opened.
        #
        # Only `approve` mints a NEW id, so only approvals can collide. An `alias` resolves to an
        # id that already exists, and two aliases onto the same target are correct, not a clash.
        groups = {}
        for r in out:
            if r["verdict"] == "approve":
                groups.setdefault(hunt_lib.collision_key(r["bid"] or r["proposed_bid"]), []).append(r)
        clashes = {k: v for k, v in groups.items() if len(v) > 1}
        if clashes:
            bybid = {w[0]: w for w in work}
            for _key, group in clashes.items():
                names = [g["bid"] or g["proposed_bid"] for g in group]
                self.findings.append(
                    "map/%s: %d proposals in ONE batch normalise to the same commodity (%s) - "
                    "re-adjudicated serially, each told about the others" % (slug, len(group),
                                                                            ", ".join(names)))
                for g in group:
                    w = bybid.get(g["proposed_bid"])
                    if not w:
                        continue
                    sib = [n for n in names if n != (g["bid"] or g["proposed_bid"])]
                    # A BATCH OF ONE, and deliberately not a special case: the same dossier with one
                    # entry, through the same road, so the re-check stays what it was.
                    redo = await rule([w], siblings={w[0]: sib})
                    if redo.get(w[0]) is not None:
                        g.update(redo[w[0]])
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

    # ---- F2: THE REST OF THE REGISTRAR'S OWN CHECKLIST, PRE-GATHERED --------------------------------
    #
    # commodity-registrar.md orders three more reads beyond the near-miss sweep: the declared-same-thing
    # layer (recipe-floor-id-map.json), the LIVE FEED ("ALWAYS check the live feed too... the only place
    # that says whether an id is actually PRICED"), and the LABELS of near rows ("the EXISTING ROW'S
    # LABEL IS 'Yellow Mustard' - read labels, not just ids"). Every one of those is a file the daemon
    # can read for free. What is removed is the OBLIGATION to fetch, never the RIGHT - the registrar
    # keeps every tool it had and may re-derive anything it distrusts. This is CHANGE A's exact recipe
    # applied one gate over.
    #
    # COULD-NOT-LOOK IS NEVER A CLEAN BILL, here as everywhere: an unreadable feed or floor map is
    # ANNOUNCED as unreadable in the dossier, never rendered as "nothing there".

    FEED_PATH = os.path.join(REPO, "grocery", "out", "smp-feed.json")
    FLOOR_MAP_PATH = os.path.join(REPO, "grocery", "recipe-floor-id-map.json")

    def feed_prices(self):
        """id -> its live price cell, or None if the feed could not be read. Cached per run."""
        if getattr(self, "_feed_prices", None) is not None:
            return self._feed_prices[0]
        try:
            with open(self.FEED_PATH, "r", encoding="utf-8-sig") as f:
                doc = json.load(f)
            ing = doc.get("ingredients")
            got = dict((str(k), v) for k, v in (ing or {}).items() if isinstance(v, dict)) \
                if isinstance(ing, dict) else None
        except Exception:                                         # noqa: BLE001
            got = None
        self._feed_prices = (got,)
        return got

    def floor_map(self):
        """The declared-same-thing pairs, or None if the file could not be read. Cached per run."""
        if getattr(self, "_floor_map", None) is not None:
            return self._floor_map[0]
        try:
            with open(self.FLOOR_MAP_PATH, "r", encoding="utf-8-sig") as f:
                doc = json.load(f)
            m = doc.get("map")
            got = dict((str(k), str(v)) for k, v in m.items()) if isinstance(m, dict) else None
        except Exception:                                         # noqa: BLE001
            got = None
        self._floor_map = (got,)
        return got

    @staticmethod
    def _stems(text):
        out = set()
        for w in re.split(r"[^a-z0-9]+", str(text or "").lower()):
            if len(w) > 3:
                out.add(w[:-1] if w.endswith("s") else w)
        return out

    def feed_block(self, term, bid, near):
        feed = self.feed_prices()
        if feed is None:
            return ("\nTHE LIVE FEED: could NOT be read at %s. Nobody has answered the priced\n"
                    "question for this proposal - check it yourself.\n" % self.FEED_PATH)
        lines, seen = [], set()
        for i in [bid] + [r["id"] for r in near]:
            if not i or i in seen:
                continue
            seen.add(i)
            cell = feed.get(i)
            if cell is None:
                lines.append("    %-34s not in the feed - no price cell exists for this id today" % i[:34])
            else:
                lines.append("    %-34s $%s / %s cheapest at %s (%s store(s))"
                             % (i[:34], cell.get("cheapest"), cell.get("unit"),
                                cell.get("store"), cell.get("n")))
        return ("\nTHE LIVE FEED (grocery\\out\\smp-feed.json), ALREADY CHECKED FOR YOU - and note the\n"
                "distinction your own definition draws: 'already exists' and 'already PRICED' are\n"
                "different answers to the caller.\n" + "\n".join(lines) + "\n")

    def floor_map_block(self, term, bid, near):
        fm = self.floor_map()
        if fm is None:
            return ("\nTHE DECLARED-SAME-THING LAYER: could NOT be read at %s - check it yourself.\n"
                    % self.FLOOR_MAP_PATH)
        want = set([bid] + [r["id"] for r in near])
        want.add(re.sub(r"[^a-z0-9]+", "-", str(term or "").lower()).strip("-"))
        hits = ["    %s -> %s" % (k, v) for k, v in sorted(fm.items()) if k in want or v in want]
        if not hits:
            return ("\nTHE DECLARED-SAME-THING LAYER (grocery\\recipe-floor-id-map.json, %d verified\n"
                    "pairs): no entry names this proposal or any row above.\n" % len(fm))
        return ("\nTHE DECLARED-SAME-THING LAYER (grocery\\recipe-floor-id-map.json) - recipe spelling\n"
                "to weekly id, each pair a ONE-TIME HUMAN VERIFICATION that they are the same food in\n"
                "the same form:\n" + "\n".join(hits) + "\n")

    def label_grep_block(self, term, near):
        """Rows whose LABEL carries a stem of this term but whose id does not - the yellow-mustard
        seam, where the existing row's id says `mustard` and only its label says Yellow Mustard."""
        want = self._stems(term)
        if not want:
            return ""
        shown = set(r["id"] for r in near)
        hits = []
        for r in self.commodity_rows():
            if r["id"] in shown or not r["label"]:
                continue
            lab = r["label"].lower()
            if any(w in lab for w in want):
                hits.append("    %-34s %-30s [%s]" % (r["id"][:34], r["label"][:30], r["ns"]))
            if len(hits) >= 8:
                break
        if not hits:
            return ""
        return ("\nLABEL MATCHES NOT ALREADY LISTED - greps over the LABELS rather than the ids,\n"
                "because the yellow-mustard seam hides exactly there:\n" + "\n".join(hits) + "\n")

    def registrar_dossier(self, term, bid, evidence, row=None, siblings=()):
        """Everything the registrar's checklist orders, for ONE proposal, gathered."""
        near = self.commodity_near_misses(term, bid)
        parts = ["  ingredient line  : %s" % (term or "(the mapper did not name the term)"),
                 "  proposed id      : %s" % bid,
                 "  the mapper's case: %s" % (evidence or "(none given)")]
        if row:
            parts.append("  the mechanical pre-resolve found: %s" % (row.get("evidence") or "")[:600])
        if siblings:
            parts.append(
                "\n  RE-ADJUDICATION. Another proposal in this SAME batch normalises to the same\n"
                "  commodity as this one: %s. You were both approved, which would mint the same food\n"
                "  twice under two ids - the bread-crumbs / breadcrumbs failure, where one food\n"
                "  carried two disagreeing prices while every per-file guard read green. Rule again\n"
                "  knowing this. If they are one food, exactly one id may be born: `alias` this one\n"
                "  onto the better name, or `approve` it and say plainly why the other is the alias.\n"
                "  If they are genuinely different foods, `approve` and say what distinguishes them."
                % ", ".join(siblings))
        return ("\n".join(parts) + "\n"
                + self.registrar_evidence_block(term, bid)
                + self.feed_block(term, bid, near)
                + self.floor_map_block(term, bid, near)
                + self.label_grep_block(term, near))

    def registrar_batch_prompt(self, slug, work_items, siblings=None):
        """ONE dossier, every proposal in the batch, one schema'd verdict array back."""
        siblings = siblings or {}
        blocks = []
        for n, (bid, term, evidence, row) in enumerate(work_items, 1):
            blocks.append("---- PROPOSAL %d of %d ----------------------------------------------\n%s"
                          % (n, len(work_items),
                             self.registrar_dossier(term, bid, evidence, row,
                                                    siblings=siblings.get(bid) or ())))
        return (
            "Rule on %d proposed new grocery commodity id(s), for the recipe `%s`. This is the gate\n"
            "before an id is born. For EACH proposal: prove the food is not already priced under\n"
            "another name across all three id namespaces and the live feed, rule variant-vs-duplicate\n"
            "on the evidence, and answer:\n"
            "  approve  a genuinely new id, and `bid` is the id to mint\n"
            "  alias    it is already priced under another id, and `bid` is THAT EXISTING id\n"
            "  reject   it should not be minted and no existing id fits either\n\n"
            "THESE PROPOSALS ARE SIBLINGS IN ONE BATCH, and that is why they arrive together. Two of\n"
            "them approving near-identical ids is the exact defect you exist to prevent, and ruling\n"
            "them one at a time is how it slips through: each ruling checks a clean estate, neither\n"
            "sees the other, and one food is minted twice. Read them against each other as well as\n"
            "against the estate. The orchestrator ALSO re-checks approvals for collisions mechanically\n"
            "and sends any pair back to you - belt and braces, not a substitute for your reading.\n\n"
            "THE SWEEP BELOW IS ALREADY RUN FOR YOU: the three namespaces, the live feed's price\n"
            "cells, the declared-same-thing pairs, and label greps. You keep every tool you had and\n"
            "may re-derive anything you distrust - what is gone is the OBLIGATION to fetch it, never\n"
            "the right. Spend your turns on the variant-vs-duplicate JUDGMENT, which is the half of\n"
            "this gate no file read can do.\n"
            "%s\n"
            "%s\n"
            "Return `rulings`: one entry per proposal, each carrying `proposed_bid` EXACTLY as stated\n"
            "above (it is the key every ruling is joined on), `verdict`, `bid` and `reason`. A\n"
            "proposal you cannot rule on is a `reject` carrying what would settle it - never an\n"
            "omission, because an id nobody ruled on is refused and the recipe stops.\n\n"
            "`reason` is the sentence a person reads when this blocks a recipe, so make it the\n"
            "evidence rather than the conclusion. A reject leaves the ingredient line UNSETTLED and\n"
            "the recipe STUCK carrying your sentence - which is the right outcome when the honest\n"
            "answer is no, and an expensive one when it is guesswork.\n"
            % (len(work_items), slug, self.GREP_HARNESS_NOTE, "\n".join(blocks)))

    # ---- CHANGE M: THE DAEMON WRITES THE FOOD DB --------------------------------------------------
    #
    # WHY THE PEN MOVED. map_prompt already forbids re-reads ("the table above is the estate, already
    # read for you"), and the mapper's one licensed read is a nutrition LABEL for a food with no
    # food-macros-db row. It then said "add those rows as you always have", so the mapper EDITED
    # meal-prep\food-macros-db.json itself. Measured on 6b: a 3-recipe map batch took 22 turns and
    # 1.08M raw tokens, and the turns were label acquisition plus Edit-and-verify round trips on that
    # one file. The mapper returns `food_db_rows` now and has no file access to the DB at all.
    #
    # AND WHAT THE MOVE BUYS BEYOND TURNS - this is the part that is accuracy, not cost. A row that
    # arrives in a payload can be CHECKED before it lands. `db_entries_added` was a names-only
    # self-report: it said what the mapper CLAIMED to have written, which is precisely the thing a
    # gate cannot be built on. Every row now passes the Atwater derivation and the conflict rule
    # before the file changes, and the mapped artifact records what the DAEMON WROTE.
    #
    # THE CONFLICT RULE IS THE MEAL-MACRO SKILL'S, arriving here unchanged: "When a label conflicts
    # with the DB, STOP and surface it. Do NOT silently overwrite." An existing row always stands.
    # H1: the tolerances the conflict rule forgives, and only within one identical serving basis.
    # 5 CALORIES is the estate's own macro-recompute tolerance, arriving here unchanged. 0.5 g is
    # TIGHTER than the 2 g recompute tolerance ON PURPOSE: a food-DB row is a SOURCE OF TRUTH that
    # every spec build and every macro recompute reads, not a derived figure that a chain of
    # arithmetic has already blurred. Forgiving 2 g here would forgive a real label disagreement.
    FOOD_DB_CAL_TOLERANCE = 5.0
    FOOD_DB_MACRO_TOLERANCE = 0.5

    def _rounding_apart(self, new, old, field):
        """True when two values for the same field are the same number rounded differently.

        A missing or non-numeric value on either side is NOT rounding - it is a difference nobody
        can measure, so it stays a conflict and a person rules on it.
        """
        if not isinstance(new, (int, float)) or not isinstance(old, (int, float)):
            return False
        tol = self.FOOD_DB_CAL_TOLERANCE if field == "calories" else self.FOOD_DB_MACRO_TOLERANCE
        return abs(float(new) - float(old)) <= tol

    MACRO_FIELDS = ("calories", "protein_g", "carbs_g", "fat_g")

    @staticmethod
    def _loose_name_key(name):
        r"""Two food names that differ only in punctuation, spacing or a trailing plural.

        DELIBERATELY BLUNT AND DELIBERATELY NOT THE HEAD-NOUN SCORING. It keeps the DIGITS, which is
        what separates '90/10 Ground Beef' from '93/7 Ground Beef' - the head-noun road strips both
        to the single word "beef" and calls them the same food. It keeps every modifier too, so
        'Hot Sauce' and 'Alfredo Sauce' stay apart where the head-noun road pairs them (because
        "hot" is a noise word and vanishes, leaving no modifier to disagree with).

        THE 'ss' GUARD IS DORMANT AND IS KEPT ANYWAY, which is worth saying rather than implying.
        It is inherited from coverage_check's _words so the two normalisations read the same, and it
        exists so a future 'Watercress' does not become 'watercres'. Measured 2026-08-26 across the
        food DB and the vocabulary together: not one name ends in 'ss' and the collision set is
        identical with it on or off, so its neuter fires nothing. The suite asserts that dormancy
        directly instead of dressing it up in a fixture that would only prove itself.
        The length floor keeps three-letter foods intact.
        """
        s = re.sub(r"[^a-z0-9]+", "", str(name or "").lower())
        if len(s) > 3 and s.endswith("s") and not s.endswith("ss"):
            s = s[:-1]
        return s

    @staticmethod
    def _basis_text(r):
        """How a row states its serving, in the row's own words."""
        qty, unit, g = r.get("serving_qty"), r.get("serving_unit"), r.get("serving_grams")
        if qty is not None and unit:
            return "%s %s = %s g" % (qty, unit, g)
        return "%s g" % g

    @staticmethod
    def _per_100g(r):
        """The four macros per 100 g, or None when the row states no usable weight.

        ONE BASIS BEFORE ANYTHING IS CALLED DIFFERENT. This is H2's lesson pointed at the REPORT
        rather than at the verdict. H2 already stopped the rule from CALLING a per-100-g row and a
        household row different; it did not change what the finding PRINTS, so a real conflict still
        read `existing={"calories": 2} new={"calories": 233}` - two true numbers that look like a
        116x error and are a 1 g teaspoon against 100 g. A reader a week later has to do the
        arithmetic before they can even see the question.
        """
        g = r.get("serving_grams")
        if not isinstance(g, (int, float)) or g <= 0:
            return None
        out = {}
        for k in ("calories", "protein_g", "carbs_g", "fat_g"):
            v = r.get(k)
            if not isinstance(v, (int, float)):
                return None
            out[k] = round(float(v) * 100.0 / float(g), 1)
        return out

    def _one_basis_text(self, prior, row):
        """Both rows per 100 g in one line, or an honest sentence saying why they cannot be put
        there. A row with no weight cannot be normalised, and printing nothing would read as though
        the two had been compared."""
        a, b = self._per_100g(prior), self._per_100g(row)
        if a is None or b is None:
            which = "the DB's row" if a is None else "the mapper's row"
            return "%s states no usable serving weight, so the two cannot be put on one basis." % which
        return ("On one basis, per 100 g: DB %s cal / %s P / %s C / %s F  vs  mapper %s / %s / %s / %s."
                % (a["calories"], a["protein_g"], a["carbs_g"], a["fat_g"],
                   b["calories"], b["protein_g"], b["carbs_g"], b["fat_g"]))

    def _append_food_db_conflicts(self, entries):
        """Append refusals to the ledger. NEVER raises: a ledger that cannot be written must not cost
        a recipe its run, and the finding it duplicates has already been raised."""
        try:
            with open(self.food_db_conflicts_path, "a", encoding="utf-8") as f:
                for e in entries:
                    f.write(json.dumps(e, ensure_ascii=False) + "\n")
        except Exception:                                          # noqa: BLE001
            pass

    def _same_food_other_basis(self, new, old):
        """(agree, why) - do two rows on DIFFERENT serving bases state the SAME food?

        Returns agree=False with an empty reason when the question cannot be asked, which is the
        honest answer for a row that carries no usable weight: an unanswerable question is a conflict
        a person rules on, never a pass.

        THE COMPARISON RUNS ON THE EXISTING ROW'S OWN BASIS, not on a neutral per-100 g one, and that
        is deliberate. The tolerances below are the estate's own (5 kcal, 0.5 g) and they were set
        against a SERVING - forgiving 5 kcal per 100 g of dried basil would forgive 0.05 kcal per
        tsp, which is a tolerance that has stopped meaning anything. Scaling the incoming row down
        onto the household serving keeps the numbers the size the tolerance was written for.
        """
        gn, go = new.get("serving_grams"), old.get("serving_grams")
        if not isinstance(gn, (int, float)) or not isinstance(go, (int, float)) or gn <= 0 or go <= 0:
            return False, ""
        f = float(go) / float(gn)
        apart = []
        for k in self.MACRO_FIELDS:
            a, b = new.get(k), old.get(k)
            if not isinstance(a, (int, float)) or not isinstance(b, (int, float)):
                # A macro missing on either side is a difference nobody can measure - the same rule
                # _rounding_apart states, arriving here.
                return False, ""
            scaled = float(a) * f
            tol = self.FOOD_DB_CAL_TOLERANCE if k == "calories" else self.FOOD_DB_MACRO_TOLERANCE
            if abs(scaled - float(b)) > tol:
                apart.append("%s %.4g vs %.4g" % (k, scaled, float(b)))
        onto = "the mapper's row scaled onto the DB's %s" % self._basis_text(old)
        if apart:
            return False, "On one basis (%s) they still disagree: %s." % (onto, "; ".join(apart))
        return True, "%s reproduces the DB's own numbers within %g kcal and %g g" % (
            onto, self.FOOD_DB_CAL_TOLERANCE, self.FOOD_DB_MACRO_TOLERANCE)

    async def write_food_db_rows(self, slug, rows):
        r"""Returns (written_names, findings, notes). Never raises on a bad row - a bad row is a FINDING.

        Order per row: shape, then source, then Atwater, then conflict. Nothing is written until
        every check on that row has passed, and one bad row never costs a good one its write.

        NOTES ARE NOT FINDINGS. A row that agrees with the DB on a different serving basis is not a
        problem anybody has to act on, so it does not go in the run's findings list - but it is worth
        recording on the mapped artifact, because it is the difference between "we looked and they
        agree" and "nobody looked".
        """
        written, findings, notes = [], [], []
        rows = [r for r in (rows or []) if isinstance(r, dict)]
        if not rows:
            return written, findings, notes
        # THE WHOLE READ-MODIFY-WRITE IS INSIDE THE LOCK, not just the write. Two map workers can
        # carry rows for this one file at the same time (the MAP cap is 2), and a read outside the
        # lock is exactly the last-writer-wins shape that cost ingredient-resolutions 97% of its
        # outcomes in the source-domains measurement S4 records.
        # THE DISK I/O RUNS IN THE EXECUTOR, exactly like ps() and py() do, and it is not a detail.
        # A synchronous read-modify-write of a growing JSON file on the event loop stalls every other
        # lane for its duration. It also has a second consequence that the fixtures depend on: it puts
        # a real await between the read and the write, which is what makes the lock LOAD-BEARING
        # rather than decorative. Measured 2026-08-25 - with the I/O synchronous, removing the lock
        # changed nothing, because nothing could ever interleave; the neuter proof the estate's rule
        # demands could not be produced, which is a fixture proving the scheduler, not the mutex.
        loop = asyncio.get_event_loop()

        def _read():
            with open(self.food_db_path, "r", encoding="utf-8-sig") as f:
                return json.load(f)

        def _write(payload):
            tmp = self.food_db_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False, indent=1)
            os.replace(tmp, self.food_db_path)

        async with self.food_db_lock:
            try:
                doc = await loop.run_in_executor(None, _read)
            except Exception as e:                                # noqa: BLE001
                return written, ["%s: the food DB could not be read, so %d new row(s) were NOT "
                                 "written (%s)" % (slug, len(rows), e)], notes
            # THE FILE IS {readme, items:[...]} - A LIST OF ROWS, not a dict keyed by item name.
            # Measured 2026-08-25 on the live file. PLAN-hunter-judge-contract said "the DB is a DICT
            # keyed by item name - preserve that shape" and is CORRECTED in the same commit.
            # Preserving the REAL shape matters: recipe-macros.ps1 and the meal-macro skill both read
            # `items` as an array, and a dict written here would be a silently unreadable DB.
            if not isinstance(doc, dict) or not isinstance(doc.get("items"), list):
                return written, ["%s: the food DB is not the expected {readme, items:[...]} shape, "
                                 "so %d new row(s) were NOT written" % (slug, len(rows))], notes
            items = doc["items"]
            by_name = {}
            by_loose = {}
            for r in items:
                if isinstance(r, dict) and r.get("item"):
                    by_name[str(r["item"]).strip().lower()] = r
                    by_loose.setdefault(self._loose_name_key(r["item"]), str(r["item"]))
            added = []
            # REFUSALS ARE COLLECTED AND FLUSHED ONCE, not appended row by row. One open-append per
            # row inside the lock would put a file handle in the middle of the read-modify-write the
            # concurrency fixture exists to protect.
            conflicts = []
            for row in rows:
                name = str(row.get("item") or "").strip()
                if not name:
                    findings.append("%s: a food_db_rows entry carries no `item` name and was not "
                                    "written" % slug)
                    continue
                missing = [k for k in ("serving_grams", "calories", "protein_g", "carbs_g", "fat_g")
                           if not isinstance(row.get(k), (int, float))]
                if missing:
                    findings.append("%s: the food-DB row for %r is missing %s and was NOT written"
                                    % (slug, name, ", ".join(missing)))
                    continue
                # SECTION 9's NAMED BACKFIRE, GATED. The Atwater check catches fabricated
                # ARITHMETIC; it cannot catch a wrong-but-self-consistent label. The defence against
                # that one is provenance, so a row citing neither an FDC id nor a URL is a finding
                # and does not land.
                src = str(row.get("source") or "").strip()
                if not (src.lower().startswith("fdc:") or "://" in src):
                    findings.append("%s: the food-DB row for %r cites no source (expected "
                                    "'fdc:<id>' or a URL) and was NOT written. Atwater proves the "
                                    "four numbers agree with each other, never that they are this "
                                    "food's numbers" % (slug, name))
                    continue
                chk = fdc_lookup.atwater_check(row)
                if not chk.get("ok"):
                    findings.append("%s: the food-DB row for %r FAILED the Atwater check (%s) and "
                                    "was NOT written"
                                    % (slug, name, chk.get("why") or "no reason given"))
                    continue
                prior = by_name.get(name.lower())
                if prior is not None:
                    # H1 (2026-08-25): DISAGREEMENT AND ROUNDING ARE NOT THE SAME CLAIM.
                    # Measured on the jc1 drill: 5 conflict findings, of which 2 were pure rounding
                    # (Spinach protein 2.9 vs 2.86, Fresh Parsley 3 vs 2.97 - same serving basis,
                    # hundredths apart) and 3 were real (Pork Chops on a 112 g basis against a 100 g
                    # one). At width the noise buries the saves, and a finding nobody reads is a gate
                    # nobody has.
                    # THE BASIS IS JUDGED FIRST AND ABSOLUTELY. A different serving basis is a
                    # different claim about the food no matter how close the macros look - that IS
                    # the Pork Chops save - so any basis difference stays a full conflict.
                    basis = [k for k in ("serving_grams", "serving_qty", "serving_unit")
                             if k in row and row.get(k) != prior.get(k)]
                    macro = [k for k in ("calories", "protein_g", "carbs_g", "fat_g")
                             if k in row and row.get(k) != prior.get(k)]
                    if macro and not basis and all(
                            self._rounding_apart(row.get(k), prior.get(k), k) for k in macro):
                        # The identical-row case, reached through rounding: silent skip, no finding,
                        # and the existing row stands exactly as it does for a byte-identical row.
                        macro = []
                    # H2 (2026-08-26): A DIFFERENT BASIS IS NOT A DIFFERENT CLAIM.
                    # The line above this - "the basis is judged first and ABSOLUTELY" - was written
                    # from the Pork Chops save and it over-reached. Measured on run
                    # hunt-2026-08-26-ten: 10 of the 13 conflict findings were the mapper returning a
                    # per-100 g FDC row against a household row this DB already held, and every one of
                    # them was the SAME FOOD. Dried Basil 2 cal per 1 g tsp against 233 cal per 100 g
                    # is 2.33 against 2. Reporting that as a DIFFERS conflict is not a save, it is a
                    # false statement about the data, and at width it buries the real ones - which is
                    # the same sentence H1 wrote about rounding, one layer up.
                    # WHAT SURVIVES: the refusal. Nothing is overwritten either way, and per Brad's
                    # standing rule the HOUSEHOLD row is the one to keep, so agreement is silence and
                    # the existing row stands untouched. Only DISAGREEMENT is reported.
                    # AND IT IS STILL A GATE. Beef Broth in the same run states 2 g protein per 240 g
                    # cup against the mapper's 1.97 per 100 g - 0.83 against 1.97 once put on one
                    # basis, more than twice - and that stays a conflict, which is the fixture.
                    agree, why_basis = self._same_food_other_basis(row, prior)
                    if basis and agree:
                        basis, macro = [], []
                        notes.append(
                            "%s: %r arrived on a different serving basis (%s) than the row the DB "
                            "holds, and the two AGREE once put on one basis - %s. Nothing was written "
                            "and the household row stands, which is the rule."
                            % (slug, name, self._basis_text(row), why_basis))
                    diff = basis + macro
                    if diff:
                        # NEVER OVERWRITE ON A CONFLICT - the verdict is untouched, and the Great
                        # Value tortellini case is why. The mapper proposed 307 cal / 13.5 g protein
                        # per 100 g against a row that a photographed label later proved EXACTLY
                        # right at 175 / 5.8. The rule refused, and it was refusing a worse reading.
                        #
                        # WHAT CHANGED IS ONLY WHAT IT SAYS. Both rows are now put on per 100 g
                        # before the reader is asked to judge them, and the refusal is appended to a
                        # ledger that outlives the run.
                        one = self._one_basis_text(prior, row)
                        findings.append(
                            "%s: the food DB already carries %r and the mapper's row DIFFERS on %s. "
                            "Nothing was written and the existing row stands. %s%s existing=%s new=%s"
                            % (slug, name, ", ".join(diff), one,
                               (" " + why_basis) if why_basis else "",
                               json.dumps(dict((k, prior.get(k)) for k in diff), ensure_ascii=False),
                               json.dumps(dict((k, row.get(k)) for k in diff), ensure_ascii=False)))
                        conflicts.append({
                            "run": self.run_id, "slug": slug, "item": name,
                            "verdict": "REFUSED - nothing written, the existing row stands",
                            "differs_on": diff,
                            "one_basis": one,
                            "db_per_100g": self._per_100g(prior),
                            "mapper_per_100g": self._per_100g(row),
                            "db_row": dict((k, prior.get(k)) for k in self.MACRO_FIELDS
                                           + ("serving_grams", "serving_qty", "serving_unit")),
                            "mapper_row": dict((k, row.get(k)) for k in self.MACRO_FIELDS
                                               + ("serving_grams", "serving_qty", "serving_unit")),
                            "mapper_source": str(row.get("source") or ""),
                            "why_basis": why_basis})
                    continue                      # an identical row is skipped silently, per plan 3.2
                # H3 (2026-08-26): THE EXACT-NAME CHECK IS WHY THIS DB HAS DUPLICATES.
                # Everything above this line asks "is there a row called exactly that", so 'Apples'
                # landed while 'Apple' was already there, 'Lemons' beside 'Lemon', 'Green Bell
                # Peppers' beside 'Green Bell Pepper', and 'Fresh Thyme' TWICE - four collisions in
                # 369 rows, every one of them a food the DB already had. The lookup is a name-keyed
                # dict in both the conflict rule here and Get-MacroRecompute, so a duplicate does not
                # announce itself: one row silently shadows the other and a recipe can be costed off
                # whichever won.
                #
                # A FINDING, NEVER A REFUSAL, and that is the whole design. Refusing would put the
                # recipe STUCK over a NAMING question, which is the exact failure class the rest of
                # this commit exists to remove - and the row landing is what keeps the recipe moving.
                # The collision is named where it is CAUSED, with the mapper still in the loop and
                # the source page still in hand, instead of being found by an audit months later.
                #
                # AND IT IS THE PRECISE KEY, NOT THE HEAD-NOUN ONE. Measured over the live DB the day
                # this was written: this key finds 4 collisions and all 4 are real duplicates, while
                # the head-noun scoring finds 103 pairs of which 21 are the word "sauce" - it would
                # fire on every new sauce row forever. Recall belongs on the mapper's shelf, where a
                # near name is EVIDENCE it can rule against; precision belongs here, where a finding
                # that cries wolf is a finding nobody reads. So '90/10 Ground Beef' beside '93/7'
                # says nothing, and it should not.
                twin = by_loose.get(self._loose_name_key(name))
                if twin and twin.strip().lower() != name.lower():
                    findings.append(
                        "%s: the food DB already carries %r and this row is landing as %r - the same "
                        "name modulo punctuation and plural, so these are almost certainly ONE food "
                        "with two rows. The row was WRITTEN (a naming question must not park a "
                        "recipe) and the lookup is name-keyed, so until they are merged one of them "
                        "silently shadows the other." % (slug, twin, name))
                clean = dict((k, v) for k, v in row.items() if v not in (None, ""))
                clean["item"] = name
                clean["added_by"] = "recipe-hunter map lane (%s)" % self.run_id
                added.append(clean)
                by_name[name.lower()] = clean
                by_loose.setdefault(self._loose_name_key(name), name)
                written.append(name)
            if conflicts:
                await loop.run_in_executor(None, self._append_food_db_conflicts, conflicts)
            if not added:
                return written, findings, notes
            try:
                items.extend(added)
                await loop.run_in_executor(None, _write, doc)
            except Exception as e:                                # noqa: BLE001
                out = ["%s: the food DB could not be written, so the row for %r did NOT land (%s)"
                       % (slug, n, e) for n in written]
                return [], findings + out, notes
            # the daemon's own cached index is now stale, and unverified_foods reads it
            self._food_db = None
        return written, findings, notes

    def food_db_debt(self, slug, res, tables):
        r"""The NAMES this recipe still owes a food-macros-db row, from the table plus the mapper's
        own rulings. One computation, asked two different questions by the two readers below.

        THE DEBT IS A FACT ABOUT THE DB; A SHORTFALL IS A FINDING ABOUT THE MAPPER. Keeping the two
        in one function was itself a defect: `food_db_shortfall` excuses a row that came back and was
        REFUSED - it was ruled on, and its own finding already says why - which is the right way to
        judge the MAPPER and the wrong way to judge the RECIPE. A refused row is exactly as absent
        from the DB as a silent one, and the skeleton builder refuses on absence. So the debt is
        computed once, here, and the two readers subtract different things from it.
        """
        table = (tables or {}).get(slug) or {}
        # THE TABLE ASKS IN THE RECIPE'S WORDS AND THE DB ANSWERS IN THE ESTATE'S. A residual row's
        # `term` is the page's own phrase - "med onion", "bone-in skin-on chicken thighs" - and its
        # canon_item is null precisely because the table could not settle it. The name that has to be
        # checked against the food DB is the one the MAPPER ruled, so the ruling is joined first and
        # the raw term is only the fallback. Comparing "med onion" against a written "Yellow Onion"
        # would report a shortfall on every residual line in the run.
        ruled = {}
        for r in (res.get("rulings") or []):
            if not isinstance(r, dict):
                continue
            for k in ("raw", "term"):
                if r.get(k):
                    ruled[str(r[k]).strip().lower()] = r
        # NOT EVERY DECISION NEEDS A LABEL. not-purchased is charcoal and wood chips; rejected is a
        # line the mapper threw out. Everything else - mapped, mapped-null, mapped-optional - IS
        # counted in the macros by the skeleton builder, so every one of them needs a row.
        no_label = ("not-purchased", "rejected")
        db = dict((str(k).strip().lower(), v) for k, v in (self.food_db() or {}).items())
        need = []
        for r in (table.get("rows") or []):
            if not isinstance(r, dict) or r.get("fooddb_known"):
                continue
            rule = ruled.get(str(r.get("raw") or "").strip().lower()) \
                or ruled.get(str(r.get("term") or "").strip().lower()) or {}
            if str(rule.get("decision") or "").strip().lower() in no_label:
                continue
            name = rule.get("canon_item") or r.get("canon_item") or r.get("term")
            if not name:
                continue
            name = str(name)
            # The row may have been unknown to the TABLE and known to the DB all along - the table
            # asks by the page's phrase and the mapper's ruling is what maps it onto a name the DB
            # already carries. That is a lookup the table could not do, not a missing row.
            if name.strip().lower() in db:
                continue
            if name not in need:
                need.append(name)
        return need

    @staticmethod
    def food_db_declared_absent(res, names):
        """The subset of `names` the mapper DECLARED it could not acquire a row for, in
        `food_db_absent`.

        A declaration is an ANSWER, not a pass: the recipe still blocks on the missing row, because
        `food_db_outstanding` subtracts only what landed. What the declaration buys is that the block
        carries the mapper's own sentence instead of carrying nothing.
        """
        out = set()
        low = set(str(n).strip().lower() for n in (names or []))
        for a in ((res or {}).get("food_db_absent") or []):
            item = (str(a.get("item") or "") if isinstance(a, dict) else str(a or "")).strip().lower()
            if item in low:
                out.add(item)
        return out

    @staticmethod
    def food_db_absent_reason(res, name):
        """The mapper's stated reason for a declared-absent row, or "" when it declared none."""
        want = str(name or "").strip().lower()
        for a in ((res or {}).get("food_db_absent") or []):
            if isinstance(a, dict) and str(a.get("item") or "").strip().lower() == want:
                return str(a.get("why") or "").strip()
        return ""

    def map_row_debts(self, payload, tables):
        """{slug: [names]} for a whole map payload - the input validate_map_food_rows needs.

        THE DEBT IS READ OFF THE ANSWER, not off the dispatch. Which foods still need a row depends on
        how the lines were RULED - a term the mapper ruled `not-purchased` needs no label, and a term
        it ruled onto a canon_item the DB already carries needs no new row - and nothing knows either
        until the payload is in hand. That is the whole reason this is computed inside the validator's
        closure rather than before the dispatch.
        """
        out = {}
        for r in ((payload or {}).get("results") or []):
            if not isinstance(r, dict):
                continue
            slug = str(r.get("slug") or "").strip()
            if not slug:
                continue
            try:
                out[slug] = self.food_db_debt(slug, r, tables)
            except Exception:                                     # noqa: BLE001
                # A DEBT NOBODY COULD COMPUTE IS NOT A VIOLATION. The food DB may be mid-write by
                # another worker; refusing the batch over that would turn a read race into a re-ask.
                out[slug] = []
        return out

    def food_db_outstanding(self, slug, res, tables, written):
        """The names that STILL HAVE NO ROW IN THE DB after this map dispatch - the fact the write
        lane will refuse on, computed in the lane that caused it.

        THE ONLY SUBTRACTION IS WHAT ACTUALLY LANDED. Not what was ruled on, not what was explained,
        not what was refused for a good reason: `written` is the list write_food_db_rows returned,
        and a name outside it has no row however well its absence was argued. That is the whole
        difference between this and `food_db_shortfall`, and it is why they are two functions.
        """
        need = self.food_db_debt(slug, res, tables)
        if not need:
            return []
        have = set(str(n).strip().lower() for n in (written or []))
        return [n for n in need if n.strip().lower() not in have]

    def food_db_shortfall(self, slug, res, tables, written, findings):
        r"""The finding for rows the pre-resolve table ASKED FOR and the mapper never returned, or
        None when every food that needed a row got one ruled on.

        WHY THIS EXISTS, MEASURED ON RUN hunt-2026-08-26-ten. The table named between 1 and 9 foods
        with no food-DB row on every one of the run's 22 recipes. The mapper returned ZERO rows for
        TWELVE of them - including recipes whose own `detail` said in words that rows were returned
        ("New DB rows returned: Yellow Onion, Apple, Chicken Thighs, Fresh Rosemary" against an empty
        payload) - and NOT ONE recipe in the run returned a row for every food that needed one. The
        recipes then went STUCK a whole lane later at the write gate, over a missing row nobody had
        said was missing. `food_db_rows` is optional in the MAPPED schema and write_food_db_rows
        returns silently on an empty list, so between the table asking and the skeleton refusing there
        was no place the shortfall could be seen. This is that place.

        IT JUDGES THE MAPPER, NOT THE RECIPE, and that split is the 2026-08-26 postcondition work.
        The RECIPE is judged by `food_db_outstanding` above, which BLOCKS. This stays a finding,
        because what it reports is a CONTRACT the mapper did not keep - and a contract violation and
        a missing row are two different facts that happened to share one detector.

        A ROW THAT WAS RETURNED AND REFUSED IS NOT A SHORTFALL - it was ruled on, and its own finding
        already says why. Only silence counts, and a row the mapper explicitly declared it could not
        acquire in `food_db_absent` is not silence either.
        """
        need = self.food_db_debt(slug, res, tables)
        if not need:
            return None
        # Every name the mapper ACCOUNTED FOR: written, refused BY NAME in a finding, or declared
        # absent in `food_db_absent`.
        #
        # AND `detail` IS NOT ON THAT LIST, WHICH THIS FUNCTION'S OWN FIXTURE INSISTED ON. The first
        # cut of the postcondition let a name appearing anywhere in the mapper's prose count as an
        # answer, and _shortfall_reaches_the_run_findings went red on the spot - because the founding
        # payload of run hunt-2026-08-26-ten carried exactly that: `detail` reading "New DB rows
        # returned: Spaghetti Squash, Fresh Basil" against an EMPTY food_db_rows. The prose is the
        # thing that lied. An answer has to be somewhere a claim can be CHECKED, which is why the
        # declaration road is a structured array and not a sentence.
        seen = set(str(n).strip().lower() for n in (written or []))
        for f in (findings or []):
            for n in need:
                if ("'%s'" % n) in f or ('"%s"' % n) in f:
                    seen.add(n.strip().lower())
        seen |= self.food_db_declared_absent(res, need)
        missing = [n for n in need if n.strip().lower() not in seen]
        if not missing:
            return None
        return ("map/%s: the pre-resolve table named %d food(s) with no food-DB row and the mapper "
                "returned nothing at all for %d of them (%s). Those rows are not refused, they are "
                "ABSENT - the write lane will refuse this recipe for a missing row that nobody said "
                "was missing. A row the mapper could not acquire is a finding it is asked to state in "
                "`detail`; silence is not."
                % (slug, len(need), len(missing), ", ".join(repr(m) for m in missing[:8])
                   + (" and %d more" % (len(missing) - 8) if len(missing) > 8 else "")))

    async def new_bid_proposals(self, slug, res):
        r"""Every bid the three namespaces do NOT already wire - declared or not.

        T8, MEASURED ON THE T-SHAKEDOWN (2026-08-25). map_prompt promises, in as many words: "The
        orchestrator checks the three commodity namespaces itself and sends every genuinely new one
        to the registrar, so you cannot skip that gate by omission." It did not. This road read
        `res["new_commodity_proposals"]` and nothing else, so a mapper that ruled
        `bid='ground-chicken'` while returning an EMPTY proposals array bought no registrar dispatch
        at all. The assembler then refused the unapproved id and the recipe STUCK - safe, and
        useless: the gate that exists to ADJUDICATE a new commodity had instead become a gate that
        silently stalls the recipe, after a 7.8-minute map dispatch was already paid for.

        THE SWEEP WAS ALREADY BUILT AND NOBODY CALLED IT. map-preresolve's `-NewBids` takes this
        exact payload, loads all three namespaces, and returns the union of ruled-but-unwired bids
        and declared proposals, each flagged `declared`. It even carries the same >=300-id
        plausibility floor the assembler uses, so a half-read namespace file reports BLOCKED instead
        of declaring every id in the estate brand new. This is the F1 shape exactly - a fixtured
        capability with no daemon road to it - and the fix is to call it, not to write a second one.

        DEGRADE, NEVER SILENTLY NARROW. If the sweep cannot run, fall back to what the mapper
        declared and say so in a finding. That is the same set this road used before T8, so the
        failure mode is today's behaviour rather than a new one, and the assembler stays the backstop
        that refuses any id nothing approved.
        """
        declared = [p for p in (res.get("new_commodity_proposals") or []) if isinstance(p, dict)]
        probe_dir = os.path.join(self.run_dir, "mapped-pre")
        probe = os.path.join(probe_dir, "%s.newbids.json" % slug)
        try:
            os.makedirs(probe_dir, exist_ok=True)
            with open(probe, "w", encoding="utf-8") as f:
                json.dump({"slug": slug,
                           "rulings": res.get("rulings") or [],
                           "new_commodity_proposals": declared}, f, ensure_ascii=False)
        except Exception as e:                                    # noqa: BLE001
            self.findings.append("map/%s: the new-bid sweep could not write its probe (%s) - falling "
                                 "back to the %d proposal(s) the mapper declared"
                                 % (slug, e, len(declared)))
            return declared
        rc, out, err = await self.ps(MAP_PRERESOLVE_PS,
                                     ["-NewBids", "-RulingsFile", probe], timeout=300)
        if rc != hunt_lib.EXIT_CLEAN:
            self.findings.append(
                "map/%s: the new-bid sweep could not run (exit %s: %s) - falling back to the %d "
                "proposal(s) the mapper declared, and any id it missed will be REFUSED by the "
                "assembler rather than minted" % (slug, rc, ((out or "") + (err or "")).strip()[:160],
                                                  len(declared)))
            return declared
        try:
            doc = json.loads((out or "").strip())
            found = [p for p in (doc.get("proposals") or []) if isinstance(p, dict) and
                     str(p.get("proposed_bid") or "").strip()]
        except Exception as e:                                    # noqa: BLE001
            self.findings.append("map/%s: the new-bid sweep returned unreadable JSON (%s) - falling "
                                 "back to the mapper's %d declared proposal(s)"
                                 % (slug, e, len(declared)))
            return declared
        undeclared = [p for p in found if not p.get("declared")]
        if undeclared:
            # WORTH SEEING AT WIDTH. A model that keeps forgetting to declare is a prompt problem;
            # the gate holding anyway is what makes it a log line instead of a stalled recipe.
            self.findings.append(
                "map/%s: %d new commodity id(s) reached the registrar that the mapper did NOT declare "
                "(%s) - the by-omission sweep is what caught them"
                % (slug, len(undeclared), ", ".join(str(p.get("proposed_bid")) for p in undeclared)))
        return found

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
        proposals = await self.new_bid_proposals(slug, res)
        rulings = await self.registrar_rulings(slug, proposals, tables)
        db_written, db_findings, db_notes = await self.write_food_db_rows(
            slug, res.get("food_db_rows"))
        shortfall = self.food_db_shortfall(slug, res, tables, db_written, db_findings)
        if shortfall:
            db_findings = db_findings + [shortfall]
        outstanding = self.food_db_outstanding(slug, res, tables, db_written)
        for f in db_findings:
            self.findings.append(f)
        payload = {
            "slug": slug,
            "lines": res.get("lines") or [],
            "rulings": res.get("rulings") or [],
            "absent_terms": [t for t in (res.get("absent_terms") or []) if t],
            # WHAT THE DAEMON WROTE, not what the mapper claimed to have written. The key is
            # renamed along with the meaning, so a reader of an old artifact and a reader of a new
            # one cannot mistake the two.
            "db_entries_written": db_written,
            "db_row_findings": db_findings,
            # Rows that were LOOKED AT and agreed with the DB on a different serving basis. Not
            # findings - nobody has to act on them - but the difference between "we compared them"
            # and "nobody compared them" is worth keeping on the artifact.
            "db_row_notes": db_notes,
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
        rc, out, err = await self.ps_timed("map", "map-preresolve verify", [slug],
                                          MAP_PRERESOLVE_PS, args, timeout=600)
        text = ((out or "") + (err or "")).strip()
        if rc == hunt_lib.EXIT_CLEAN:
            # ---- D1: THE RULINGS BECOME MEMORY, AND ONLY AFTER THE ASSEMBLE SAID OK ---------------
            #
            # WHY HERE AND NOT IN THE MAP LANE. A ruling that failed assembly must not become an
            # identity: the run refused to build a decision file over it, and caching something the
            # estate would not write down is worse than caching nothing. This is the only point
            # where "the mapper ruled it AND the assembler accepted it" is both true and known.
            #
            # ADVISORY, ALWAYS. Every problem apply_learn reports joins the findings road below; not
            # one of them fails the assemble. Memory must never block the lane - a broken pen is a
            # finding, not a parked recipe.
            learned, lfindings = await asyncio.get_running_loop().run_in_executor(
                None, learn_apply.apply_learn, self.run_dir, slug, res, tables, payload,
                self.resolutions_path, self.events_path)
            for f in lfindings:
                self.findings.append("learn/" + f)
            # THE 44-CLASS POSTCONDITION, ENFORCED AT THE CALL SITE. `Events / mapped residuals = 1`,
            # made mechanical. On 2026-08-15 forty-four decide rejections left no trace outside a run
            # dir and the next run re-sourced every one of them; the only reason anyone knows the
            # number is that a human counted afterwards. This is the counter that would have said so
            # the same night.
            gap = learn_apply.postcondition_finding(slug, learned, payload)
            if gap:
                self.findings.append("learn/" + gap)
            self.log("  map: %s learned %d event(s) (%d projected, %d held, %d surprise)"
                     % (slug, learned.get("events_written", 0), learned.get("projected", 0),
                        learned.get("held", 0), learned.get("surprises", 0)))
            # ---- THE ROW DEBT BLOCKS, HERE, AND ONLY AFTER EVERYTHING ELSE SUCCEEDED --------------
            #
            # WHY IT BLOCKS AT ALL, reversing this detector's own founding note. That note argued a
            # missing row "is already refused downstream by the skeleton builder, and refusing here as
            # well would turn one honest block into two". It does not: it is ONE recipe and only one
            # of the two gates can ever fire on it. What the reversal actually changes is WHERE the
            # recipe stops - in the lane that caused it, with the map dossier still on disk, before
            # the price lane enqueues terms and the spec lane builds over macros that are computed
            # WITHOUT the missing food (build-intake-skeleton.ps1's own words). Measured 2026-08-26:
            # salisbury-steak-burgers travelled a whole lane past its cause to die at the write gate
            # over 'Kaiser Rolls'.
            #
            # AND IT BLOCKS ON WHAT LANDED, NOT ON WHO IS AT FAULT. A row the mapper never mentioned,
            # a row it declared it could not find, and a row that came back and FAILED the Atwater
            # check are three different findings about the mapper and one identical fact about the
            # recipe: there is no row, so the skeleton cannot be completed. The shortfall finding
            # above judges the mapper; this judges the recipe.
            #
            # AFTER THE LEARN, ON PURPOSE. The identity work is good work - it assembled, so the
            # estate wants it - and a STUCK is resumable: add the row and the recipe walks on from
            # `mapped`. Refusing before the learn would make a missing nutrition label cost the run
            # every ruling in the recipe.
            if outstanding:
                why = []
                for n in outstanding:
                    said = self.food_db_absent_reason(res, n)
                    why.append("%r (%s)" % (n, said or "the mapper said nothing about it"))
                return False, ("%d food(s) the recipe needs still have NO food-macros-db row, so the "
                               "intake skeleton cannot be completed and the macros would be computed "
                               "WITHOUT them: %s. The map dossier IS on disk and the rulings were "
                               "learned - add the row(s) and this recipe resumes from `mapped`."
                               % (len(outstanding), "; ".join(why)))
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
                # F1: FILL THE SHELF, THEN RE-RUN THE MECHANICAL PASS SO THE TABLE CARRIES IT.
                # The re-run is how the warm cache reaches the dossier: map-preresolve owns the
                # rendering of a shelf into a row's `evidence` (its FDC attach), and splicing
                # candidates into the already-built table here would be a second renderer of the same
                # thing - the forked-taxonomy defect this estate has scars from. It is mechanical,
                # ~5s, idempotent, and stamps its own lane pair through the road it already uses.
                fill = await self.fill_fdc_shelf(slugs, tables)
                if fill and (fill.get("added") or fill.get("failed")):
                    ok2, tables2, why2 = await self.preresolve(slugs)
                    if ok2:
                        tables = tables2
                    else:
                        # DEGRADE, NEVER BLOCK. The first pass already returned a clean table and the
                        # batch is not blocked by a warm-up step failing; the mapper rides the colder
                        # table exactly as it did before F1 existed.
                        self.findings.append(
                            "F1: the post-fill re-resolve could not run (%s) - the batch of %d rides "
                            "the pre-fill table" % (why2[:120], len(slugs)))
                # D3: THE PRIOR-RULINGS SHELF, FETCHED BEFORE THE DOSSIER IS BUILT.
                # Same stretch as the FDC fill and for the same reason: everything the judge is
                # going to want must be on the page before the page is written, or it goes and
                # fetches it a turn at a time.
                await self.fill_prior_rulings(slugs, tables)
                self.log_shelf_coverage(tables)
                # ---- T7: THE COMPLETENESS GATE, AND IT IS A PICK-UP CHECK ON PURPOSE ---------------
                #
                # MEASURED on the T-shakedown (2026-08-25): 2 of 3 recipes died AFTER a 7.8-minute
                # mapper dispatch, on facts a millisecond of arithmetic already knew - one extraction
                # stated no servings at all, and one candidate carried no protein. D8 refuses to scale
                # a recipe of unknown yield and refuses to build a skeleton with no protein, both
                # correctly, but by then the whole batch had been paid for.
                #
                # THE DATA IS NOT CORRUPT, IT IS INCOMPLETE, and the difference is the whole design.
                # local_extract is FORBIDDEN to guess ("servings AS STATED, or null. Do not infer it
                # from pan size or volume"), so a null yield is an honest record of a page that never
                # said. Nothing was broken upstream; what was missing is anyone asking BEFORE paying.
                #
                # WHY REJECT RATHER THAN STICK. A source page that never states its yield cannot
                # become a costed 14-serving recipe by any later effort, so `rejected-unreadable` is
                # the truthful verdict and it is a legal move from `extracted`. A recipe that is
                # merely missing its PROTEIN is a different case - that is run bookkeeping, not a
                # defect in the source - so it is STUCK and resumable, never rejected.
                keep = []
                for b in batch:
                    s = b["slug"]
                    ext, _why = self.read_extraction(s)
                    if ext is None:
                        keep.append(b)                # unreadable here is the mapper's own problem
                        continue
                    if not ext.get("servings"):
                        # Q3: AND THE OUTCOME IS RECORDED, which it was not. This site advanced the
                        # state file and wrote a finding but never called finish, so the slug stayed
                        # in flight for the whole run: `wip()` counts accepted minus OUTCOMES, and a
                        # recipe that is rejected on disk and in flight in the record holds a WIP
                        # slot that nothing can ever free. The same pair, the same rule, the other
                        # half missing.
                        await self.settle(s, "rejected-unreadable", "daemon",
                                          "the source states no servings, so nothing can ever be "
                                          "scaled to a 14-serving batch - refused before the mapper "
                                          "was paid rather than after", "map")
                        self.findings.append(
                            "map/%s: REFUSED AT PICK-UP - the source states no servings. A yield "
                            "nobody stated cannot be guessed, and the cost of learning that after a "
                            "map dispatch is the whole dispatch." % s)
                        continue
                    if not str(self.state_row(s).get("protein") or "").strip():
                        self.stuck(s, "map",
                                   "no protein is named for this candidate, and D8 refuses to build "
                                   "a skeleton without one. This is run bookkeeping rather than a "
                                   "defect in the source, so it is resumable: name the protein and "
                                   "re-run.")
                        continue
                    keep.append(b)
                if not keep:
                    self.log("  map: every slug in this micro-batch failed the pick-up check - "
                             "nothing was dispatched")
                    continue
                if len(keep) != len(batch):
                    batch = keep
                    slugs = [b["slug"] for b in batch]
                    self.log("  map: dispatching %d of the batch after the pick-up check (%s)"
                             % (len(slugs), ", ".join(slugs)))
                # THE FOOD-ROW POSTCONDITION IS PINNED HERE, AT THE CALL SITE (2026-08-26), because
                # a predicate nothing calls is the F1 shape this file already has scars from -
                # validate_map sits one module over, fully built, wired into nothing.
                #
                # WHAT IT CHANGES: a payload that answers for neither a row nor an absence on a food
                # the table asked about is RE-ASKED, once, with those foods named. That is the only
                # moment in the run when the row can still be acquired cheaply - the session still
                # holds the table, the FDC shelf and the source page. A finding could not do it; the
                # shortfall detector built the same morning proved that by watching
                # salisbury-steak-burgers die at the write lane over 'Kaiser Rolls' anyway.
                #
                # THE BLAST RADIUS IS THE BATCH AND THAT IS ACCEPTED, on the registrar's own
                # precedent: a batch is refused ENTIRE and re-asked, never applied in part. If the
                # re-ask still will not answer, with_retry below returns None and the batch is
                # requeued INDIVIDUALLY, so one unanswerable slug cannot hold the other two.
                r = await self.with_retry(
                    lambda: self.dispatch("recipe-ingredient-mapper", self.map_prompt(slugs, tables),
                                          "map", "map:%dx" % len(slugs), slugs,
                                          schema=hunt_lib.MAPPED, stage="mapper",
                                          validator=lambda pay: hunt_lib.validate_map_food_rows(
                                              pay, self.map_row_debts(pay, tables))),
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
                        # Q3 (2026-08-26): THERE IS NO DEFAULT TERMINAL STATE HERE ANY MORE, and the
                        # one that was here was BOTH illegal and untrue. It read
                        # `res.get("state") or "rejected-not-carried"`, and `rejected-not-carried`
                        # is the PRICE lane's own derived verdict - "no Omaha store carries a
                        # blocking ingredient", written by Get-DerivedPricingState after a recipe has
                        # been mapped and priced. hunt-run.ps1 allows it from `mapped`, `pricing` and
                        # `parked` for exactly that reason. This branch runs while the recipe is
                        # still `extracted` (the success path advances to `mapped` a few lines
                        # below), so the transition was refused, the rejection was already written,
                        # and the recipe read as stuck with a verdict recorded against it.
                        #
                        # THE TABLE IS NOT THE THING THAT IS WRONG. Widening `extracted` to accept
                        # `rejected-not-carried` would let the run record say no store carries an
                        # ingredient of a recipe nothing has mapped yet - a carriage claim standing
                        # on work nobody did, which is the same objection the 2026-08-24 note above
                        # `priced` raises against walking a recipe forward to reach a rejection. And
                        # advancing to `mapped` first to make the state reachable is that objection
                        # exactly: no mapped artifact was assembled, so the advance would be a claim
                        # about a file that does not exist.
                        #
                        # NOR IS A SAFER DEFAULT THE FIX. The three states legal from `extracted` -
                        # unreadable, dupe, macros - are FINDINGS ABOUT THE RECIPE, and picking one
                        # on the mapper's behalf would file a false one; the 2026-08-16 note above
                        # `extracted` refused to do precisely that ("both would have been false").
                        # MAPPED's schema already REQUIRES `state` and names `rejected-macros` on it.
                        # A rejection that arrives without one is a payload we cannot read, and the
                        # honest outcome is a STUCK carrying the mapper's own sentence - which is
                        # what `settle` does with an empty state.
                        await self.settle(b["slug"], as_text(res.get("state")).strip(), "mapper",
                                          as_text(res.get("detail")) or "mapper rejected", "map")
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
                    # M3 (2026-08-25): THE TERMS DECIDE THE ROUTE, NOT THE MAPPER'S OWN STATE FIELD.
                    # This read `not absent and norm_state(res["state"]) == "priced"`, so a recipe
                    # whose absent_terms was EMPTY still routed to pricing unless the mapper also
                    # named its own state "priced". Measured on lf1 round 2: both fully-resolved
                    # recipes advanced mapped -> pricing carrying an EMPTY term list, enqueued
                    # nothing, and sat. The price lane had nothing to answer for them and no wake
                    # could ever clear them; the drill only reached the write lane because a SECOND
                    # daemon start ran hunt-run -Derive. On an attended drill that is a restart. On
                    # an unattended run it is a park with no exit, and it is INVISIBLE - the state
                    # file says `pricing`, which reads like a recipe legitimately waiting on a price.
                    #
                    # Zero absent terms means the board answered every line and there is nothing for
                    # the price lane to do. The unbid hold returns ABOVE this and is untouched, so
                    # nothing unbid can reach the writer through here: the only recipes this moves
                    # are ones the pre-resolve and the mapper BOTH settled.
                    #
                    # AMENDED BY Q2 (2026-08-26), and the sentence above is the one it amends: "zero
                    # absent terms means the board answered every line" was the MAPPER'S account of
                    # the recipe, and it is not sufficient. An ingredient can map perfectly to a real
                    # commodity id and still be a food no Omaha store stocks, in which case the mapper
                    # truthfully reports nothing absent and the recipe is still unbuyable. What is
                    # still true is the second half - the unbid hold returns above this, so nothing
                    # unbid reaches the writer through here.
                    #
                    # Q2 (2026-08-26): EVERY RECIPE TRANSITS `pricing`, AND THE CARRIAGE UNION IS WHY.
                    # M3's zero-absent branch advanced `mapped` -> `priced` directly, so a recipe the
                    # mapper reported no absent terms for was never carriage-checked at all - and that is
                    # the union's FOUNDING CASE, not an edge of it. doubanjiang, rice-cakes and
                    # ground-sumac all mapped to real commodity ids; the mapper therefore reported nothing
                    # absent; nothing was ever priced; the recipe sailed to a paid page. The 2026-08-22
                    # union closed that hole on the road into `pricing`, and M3 (2026-08-25) reopened it
                    # for every recipe that skipped that road.
                    #
                    # M3'S INTENT IS KEPT WHOLE - the terms still decide the route, and a recipe with
                    # nothing blocking still reaches the write lane in this same pass, with no pricer wake
                    # and no park. What changes is WHOSE term list decides. The mapper's claim no longer
                    # opens the gate; hunt-run's own RECORD does - the union of that claim and the carriage
                    # derivation - and it is read back off the state file rather than trusted. `mapped` ->
                    # `priced` is refused by the state machine as of today, so this is the only road left.
                    claimed = hunt_lib.norm_state(res.get("state"))
                    if not absent:
                        # LOG THE DISAGREEMENT RATHER THAN SWALLOWING IT. A contract the model keeps
                        # missing is worth seeing at width, and this is now the only place it shows.
                        if claimed != "priced":
                            self.log("map: %s has ZERO absent terms but the mapper called its state "
                                     "%s - routing on the terms, not on the claim"
                                     % (b["slug"], claimed or "(none)"))
                        # OPTIONAL NEVER BLOCKED AND MUST NOT START BLOCKING HERE. The estate still
                        # learns of an optional term the board cannot answer - it reaches the queue -
                        # but it wakes no pricer and holds up no recipe.
                        #
                        # IT STAYS ON THIS ROAD ONLY, deliberately. The absent road records its optional
                        # terms through -OptionalTerms and enqueues exactly its BLOCKING ones; B8 pins
                        # that -Add list at three terms and a fourth would break it. The asymmetry
                        # predates Q2 and is not Q2's to settle.
                        for t in optional:
                            await self.ps(INGREDIENT_QUEUE_PS,
                                          self.queue_args(["-Add", "-Term", t, "-Recipe", b["slug"],
                                                           "-Why", "%s lists it as optional"
                                                                   % b["slug"]]),
                                          timeout=180)
                    # ---- Q1 (2026-08-26): THE ADVANCE COMES FIRST, AND THAT REVERSAL IS THE FIX.
                    # This loop used to enqueue `absent` - the MAPPER'S CLAIM - and then advance.
                    # But -Advance -To pricing is itself a WRITER of the term list: it unions in
                    # Get-CarriageBlockingTerms, ingredients the mapper mapped fine that no Omaha
                    # store carries. Nobody ever enqueued those. -Derive then scored them PENDING
                    # (an unchecked term is never not-carried, correctly), so the recipe parked on
                    # every pass, forever, with a state file reading `pricing` -> `parked` like a
                    # recipe legitimately waiting on a price. Measured on hunt-2026-08-26-ten:
                    # 5 of 7 parked recipes, 8 terms, none of them ever on the queue.
                    #
                    # So the queue is now driven by WHAT WAS WRITTEN, never by what was claimed.
                    # The state file is the record; the record is what gets enqueued; a term
                    # cannot be recorded as blocking without being enqueued because the recording
                    # is what the enqueue reads. B8 stays impossible for the same reason it was
                    # before - the terms ride to -Terms as DISTINCT array elements through
                    # ps_invoke's -Command road - and now the derived half rides the same road.
                    if not await self.advance(b["slug"], "pricing", "mapper", "",
                                              terms=absent, optional_terms=optional):
                        self.stuck(b["slug"], "map",
                                   "hunt-run refused the advance to pricing; nothing was enqueued")
                        self.log("  map: %s STUCK - hunt-run refused the advance to pricing"
                                 % b["slug"])
                        continue
                    blocking, why_bt = self.blocking_terms(b["slug"])
                    if why_bt:
                        self.stuck(b["slug"], "map", why_bt)
                        self.log("  map: %s STUCK - %s" % (b["slug"], why_bt))
                        continue
                    # THE CARRIAGE HALF IS NAMED, not inferred from a count. A term the daemon
                    # never claimed is the interesting one, and at width it is the only way to see
                    # the gate working.
                    extra = [t for t in blocking if t not in absent]
                    if extra:
                        self.log("map: %s - hunt-run's carriage union added %d blocking term(s) "
                                 "the mapper did not report: %s"
                                 % (b["slug"], len(extra), ", ".join(extra)))
                    # THE ZERO-BLOCKING EXIT, and it is what keeps M3 alive. hunt-run wrote the term list
                    # and the read-back says nothing on it blocks: the board answered every line AND the
                    # carriage union found nothing this town does not stock. There is no pricing question
                    # left to ask, so the recipe leaves for the writer now rather than waiting on a lane
                    # with nothing to do - which is the park-with-no-exit M3 was written to end.
                    #
                    # `pricing` -> `priced` IS A LEGAL TRANSITION and always has been; it is the same edge
                    # -Derive uses when every term comes back CARRIED. The recipe is not counted into
                    # pricing_slugs and no wake is pushed, so the price lane never learns of it.
                    if not blocking:
                        await self.advance(b["slug"], "priced", "mapper",
                                           "every term answered from the board and the carriage "
                                           "union found nothing uncarried")
                        self.ch["write"].push(self.record(b["slug"], {"state": "priced"}))
                        continue
                    refused = []
                    for t in blocking:
                        rc_q, out_q, err_q = await self.ps(
                            INGREDIENT_QUEUE_PS,
                            self.queue_args(["-Add", "-Term", t, "-Recipe", b["slug"],
                                             "-Why", "%s needs it" % b["slug"]]),
                            timeout=180)
                        # AN -Add THAT FAILED USED TO BE SWALLOWED WHOLE. ingredient-queue exits 1
                        # when it cannot take the write lock in 15s, saying "NOTHING was written",
                        # and the map lane discarded that and advanced anyway - a second, rarer
                        # road to the same permanent park.
                        if rc_q != hunt_lib.EXIT_CLEAN:
                            refused.append("%s (%s)" % (t, ((out_q or "") + (err_q or "")).strip()[:120]))
                            continue
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
                    if refused:
                        # LOUD, AND THE RECIPE IS NOT COUNTED AS PRICING. The state file already
                        # says `pricing` - the advance landed - so this recipe would park on the
                        # next -Derive exactly as before. The difference is that it now parks with
                        # a STUCK outcome and the offending terms NAMED, which is a state a person
                        # can act on, instead of a silence nobody could see.
                        self.stuck(b["slug"], "map",
                                   "the queue refused %d blocking term(s): %s"
                                   % (len(refused), "; ".join(refused)))
                        self.log("  map: %s STUCK - the queue refused %d blocking term(s): %s"
                                 % (b["slug"], len(refused), "; ".join(refused)))
                        continue
                    self.pricing_slugs.add(b["slug"])
                    self.record(b["slug"], {"state": "pricing", "absent": blocking})
                    woke = True
                # ONE WAKE PER MICRO-BATCH, after every term in it is on the queue. Waking the pricer
                # inside the per-slug loop let it start on recipe one's terms while recipe two's were
                # still being enqueued, which turns a lane that batches ACROSS recipes into a
                # per-recipe stage - the exact shape audit-lane-shape.ps1 was written to refuse.
                if woke:
                    self.ch["price_wake"].push("micro-batch of %d" % len(slugs))
        await self.pool_worker(hunt_lib.LANE_CAPS["map"], worker)
        self.ch["price_wake"].close()

    # M2 (2026-08-25): the dossier cap, the same bound render_audit_dossier gives itself. Round 2 of
    # the lf1 drill spent 12 of its 21 tool calls fetching things the daemon could have rendered.
    MAP_EXTRAS_CAP = 4000

    def food_db_index(self):
        """The food DB, keyed by item name, read ONCE per run off the SEAM path.

        THE SEAM, NOT THE LIVE FILE, and that is half the point of this method. lf1 round 2 read
        meal-prep\food-macros-db.json four times while the drill was pointed at a scratch copy
        through --food-db, so every number the mapper verified against came from the wrong file.

        CACHED PER RUN, the commodity_rows pattern: these rows do not change under a hunt except by
        the daemon's own hand, and re-reading 348 rows per dispatch is the waste this removes.

        A read that COULD NOT RUN is recorded as such rather than collapsing to "no rows" - the
        could-not-look-is-not-a-clean-bill rule, arriving here. The renderer announces it.
        """
        if getattr(self, "_food_db_index", None) is not None:
            return self._food_db_index
        self._food_db_why = ""
        idx = {}
        try:
            with open(self.food_db_path, "r", encoding="utf-8-sig") as f:
                doc = json.load(f)
            rows = doc.get("items") if isinstance(doc, dict) else doc
            for r in (rows if isinstance(rows, list) else []):
                if isinstance(r, dict) and str(r.get("item") or "").strip():
                    idx[str(r["item"]).strip().lower()] = r
        except Exception as e:                                    # noqa: BLE001
            self._food_db_why = str(e)[:120]
        self._food_db_index = idx
        return idx

    # D3 (PLAN-ingredient-memory 5.2). The retrieval's three states, and the daemon must be able to
    # tell them apart at RENDER time - which is why the state travels with the answer instead of
    # being inferred from an empty list.
    PRIOR_TIMEOUT = 120

    async def fill_prior_rulings(self, slugs, tables):
        r"""Ask resolution_embed for the k nearest PAST rulings to this batch's residual terms.

        WHY IT IS A SEPARATE PROCESS AND NOT AN IMPORT. bge-m3 lives in sidecar\.venv; this daemon
        runs under C:\Codex\Python312, which has no torch. sweep.py's own header makes the same call
        for the same reason ("the resolve lane runs under the graph's interpreter, which has no
        numpy, and adding it there would put the nightly matching chain's dependencies at the mercy
        of a retrieval feature"). One road, hunt_lib.py_invoke, with the interpreter named.

        THREE STATES, NEVER FAKED. `ok` with neighbours, `ok`/`empty` with none, and `blind` when it
        could not run at all. The third is the one that matters: an empty list pretending it looked
        is how a judge concludes there is no precedent when nobody checked. The renderer says which.

        NEVER BLOCKING. This is evidence, not a gate. A blind retrieval costs the batch a channel
        and nothing else - the recipe still maps, exactly as it did before this existed.
        """
        self._prior = getattr(self, "_prior", {})
        want = []
        for slug in slugs:
            t = (tables or {}).get(slug) or {}
            for r in (t.get("rows") or []):
                if r.get("resolution") not in ("unresolved", "different-form", "new-food-suspect"):
                    continue
                term = str(r.get("term") or "").strip()
                if not term:
                    continue
                want.append({"slug": slug, "key": learn_apply.term_key(term), "term": term,
                             "raw": str(r.get("raw") or "")})
        if not want:
            for slug in slugs:
                self._prior[slug] = {"state": "ok", "terms": []}
            return
        d = os.path.join(self.run_dir, "mapped-pre")
        qin = os.path.join(d, "prior-query.json")
        qout = os.path.join(d, "prior-neighbours.json")
        try:
            os.makedirs(d, exist_ok=True)
            with open(qin, "w", encoding="utf-8") as f:
                json.dump({"terms": [{"key": w["key"], "term": w["term"], "raw": w["raw"]}
                                     for w in want]}, f, ensure_ascii=False)
        except Exception as e:                                    # noqa: BLE001
            for slug in slugs:
                self._prior[slug] = {"state": "blind", "why": "the query could not be written (%s)" % e,
                                     "terms": []}
            return
        args = ["--query", qin, "--out", qout]
        if self.events_path:
            args += ["--events", self.events_path]
        rc, out, err = await self.py(RESOLUTION_EMBED_PY, args, timeout=self.PRIOR_TIMEOUT,
                                     exe=SIDECAR_PY)
        why = ""
        doc = None
        if rc != hunt_lib.EXIT_CLEAN:
            why = "exit %s: %s" % (rc, ((out or "") + (err or "")).strip()[:160])
        else:
            try:
                with open(qout, "r", encoding="utf-8-sig") as f:
                    doc = json.load(f)
            except Exception as e:                                # noqa: BLE001
                why = "the neighbours file could not be read (%s)" % e
        if doc is None:
            for slug in slugs:
                self._prior[slug] = {"state": "blind", "why": why, "terms": []}
            self.findings.append("map: the prior-rulings shelf is BLIND for this batch of %d (%s) - "
                                 "the dossier says so rather than showing an empty list"
                                 % (len(slugs), why))
            return
        by_key = {str(t.get("key") or ""): t for t in (doc.get("terms") or [])}
        state = str(doc.get("state") or "ok")
        for slug in slugs:
            rows = []
            for w in want:
                if w["slug"] != slug:
                    continue
                t = by_key.get(w["key"]) or {}
                rows.append({"term": w["term"], "key": w["key"],
                             "neighbours": list(t.get("neighbours") or [])})
            self._prior[slug] = {"state": state, "why": str(doc.get("why") or ""), "terms": rows}
        n = sum(len(x["neighbours"]) for s in slugs for x in self._prior[s]["terms"])
        self.log("  map: prior-rulings shelf %s - %d neighbour(s) over %d term(s) from %d past "
                 "ruling(s)" % (state, n, len(want), doc.get("corpus", 0)))

    def map_dossier_extras(self, slug, table):
        """M2: the three things lf1 round 2 measurably went to disk for, rendered into the prompt.

        1. THE FOOD-DB ROWS THIS BATCH ALREADY HAS - 1 Grep and 4 full Reads of the DB on round 2.
        2. THE MACRO PRECHECK, WHOLE - 4 turns re-reading mapped-pre\\<slug>.json, three of them lost
           to environment friction. One tuning line ("added Rice base 200g (src scale)") was the
           entire explanation for a 591-vs-468 calorie disagreement the mapper was otherwise going to
           litigate by hand.
        3. THE SOURCE'S OWN YIELD - 3 extraction Reads.

        The raw ingredient lines are NOT re-rendered: the table above already carries `raw` per row,
        and a second copy of the lines is a second thing to disagree with the first.

        BOUNDED, AND THE CAP ANNOUNCES ITSELF. A quietly cut dossier has the mapper believe it saw
        everything.
        """
        table = table or {}
        rows = table.get("rows") or []
        out = []

        # ---- 1. the food-DB rows this batch already has -----------------------------------------
        known = []
        for r in rows:
            if not r.get("fooddb_known"):
                continue
            item = str(r.get("canon_item") or r.get("term") or "").strip()
            if item and item.lower() not in [k.lower() for k in known]:
                known.append(item)
        if known:
            idx = self.food_db_index()
            shown, missed = [], 0
            for item in known:
                row = idx.get(item.lower())
                if not row:
                    # ANNOUNCED-UNREADABLE, NEVER SILENCE. The table says a row exists; if this cannot
                    # produce it, the mapper is told so rather than shown a shorter list.
                    why = self._food_db_why
                    shown.append("    %s: the table says a row exists and it could not be read%s "
                                 "- check it yourself"
                                 % (item, (" (%s)" % why) if why else ""))
                    missed += 1
                    continue
                shown.append("    %s: %s %s = %s g, %s cal, %s P, %s C, %s F"
                             % (item, row.get("serving_qty"), row.get("serving_unit"),
                                row.get("serving_grams"), row.get("calories"), row.get("protein_g"),
                                row.get("carbs_g"), row.get("fat_g")))
            out.append("  THE FOOD-DB ROWS THIS BATCH ALREADY HAS - do not go and read them:")
            out.extend(shown)
            if missed:
                out.append("    (%d of the %d rows above could not be read out of the DB at %s)"
                           % (missed, len(known), self.food_db_path))

        # ---- 2. the macro precheck, whole -------------------------------------------------------
        mp = table.get("macro_precheck") or {}
        if mp:
            out.append("  THE MACRO PRECHECK, WHOLE - state %s%s, %s of %s line(s) covered, portion "
                       "factor %s:"
                       % (mp.get("state"),
                          (" (%s)" % mp.get("reason")) if mp.get("reason") else "",
                          mp.get("lines_covered"), mp.get("lines_total"), mp.get("portion_factor")))
            for t in (mp.get("tuning") or []):
                out.append("    tuning: %s" % t)
            if mp.get("uncovered_lines"):
                out.append("    lines it could NOT cover: %s"
                           % ", ".join(str(x) for x in mp["uncovered_lines"]))
            if mp.get("missing_db_items"):
                out.append("    food-DB rows it wanted and did not have: %s"
                           % ", ".join(str(x) for x in mp["missing_db_items"]))

        # ---- 3. the source's own yield ----------------------------------------------------------
        ex, why = self.read_extraction(slug)
        if ex is None:
            out.append("  THE SOURCE'S OWN YIELD: extracted\\%s.json could not be read (%s) - the "
                       "servings figure this block exists to carry is NOT available, so treat the "
                       "table's line count as all you have." % (slug, why))
        else:
            out.append("  THE SOURCE'S OWN YIELD: %s servings, titled %s (%s)"
                       % (ex.get("servings"), ex.get("title") or "(untitled)",
                          ex.get("source_url") or "no source_url"))

        # ---- 4. the prior-rulings shelf (D3) -----------------------------------------------------
        out.extend(self.render_prior_rulings(slug))

        if not out:
            return ""
        text = "\n".join(out)
        if len(text) > self.MAP_EXTRAS_CAP:
            # CUT AT A LINE BOUNDARY. Half a rendered row is a row the mapper can read as whole.
            cut = text[:self.MAP_EXTRAS_CAP].rsplit("\n", 1)[0]
            dropped = text[len(cut):].count("\n")
            text = (cut + "\n    ... CAPPED at %d characters: %d more line(s) of this block are not "
                          "shown - read the DB and mapped-pre\\%s.json for those."
                    % (self.MAP_EXTRAS_CAP, dropped, slug))
        return text

    def render_prior_rulings(self, slug):
        r"""The fourth dossier channel, in map-preresolve's FDC-shelf framing. Returns a line list.

        THE FRAMING IS THE FEATURE. map-preresolve's FDC block is the model and its wording is
        load-bearing for the same reason: FDC's top hit for "chicken drumstick" is
        "Chicken, skin (drumsticks and thighs)", a real row with real numbers that is not the food.
        Here the hazard is one step subtler - every neighbour IS a real ruling this estate made and
        stands by, and it was made about a DIFFERENT PHRASE. "Ruled X for a different phrase" must
        never render as "ruled X for this phrase", which is why each line carries the phrase it was
        ruled for, its decision and its date, and why the heading says a shelf and not an answer.

        DECISIONS ARE ALL SHOWN AND NONE ARE RANKED. sidecar measured that rejections transfer
        across foods and confirmations do not - the worst cross-food examples score HIGHEST - but
        that is a fact for the judge to weigh, not a filter to apply here. Encoding it as a filter
        would be this file deciding an identity question, which is the one thing it may not do.

        BLIND IS SAID OUT LOUD (hunt-daemon's own announced-unreadable idiom). Absent evidence is
        not evidence of absence, and a judge shown nothing concludes there is no precedent.
        """
        p = (getattr(self, "_prior", {}) or {}).get(slug)
        if p is None:
            return []
        if p.get("state") == "blind":
            return ["  PRIOR RULINGS: BLIND - %s. Absent evidence, not absence of precedent - the "
                    "estate may well have ruled on a phrase like these and this run could not look."
                    % (p.get("why") or "the retriever could not run")]
        rows = [t for t in (p.get("terms") or []) if t.get("term")]
        if not rows:
            return []
        out = ["  PRIOR RULINGS NEAR THESE TERMS - a shelf, not an answer. Each was ruled for a "
               "DIFFERENT phrase; cosine ranks wording likeness, not food identity, so any of these "
               "can be the wrong precedent. Weigh them; you still rule this line yourself:"]
        for t in rows:
            hits = t.get("neighbours") or []
            if not hits:
                out.append("    %s: no prior rulings near this term (we looked)" % t["term"])
                continue
            out.append("    %s:" % t["term"])
            for n in hits:
                bid = n.get("bid") or "no id"
                out.append("      '%s' -> %s (%s, %s, cos %.2f): \"%s\""
                           % (n.get("term"), bid, n.get("decision") or "?",
                              str(n.get("at") or "")[:10], float(n.get("cos") or 0.0),
                              str(n.get("evidence") or "").replace("\n", " ")))
        return out

    def read_extraction(self, slug):
        """(doc, why). A missing or unparseable extraction is ANNOUNCED, never silently absent."""
        path = os.path.join(self.run_dir, "extracted", "%s.json" % slug)
        try:
            with open(path, "r", encoding="utf-8-sig") as f:
                return json.load(f), ""
        except Exception as e:                                    # noqa: BLE001
            return None, str(e)[:120]

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
                lines.append("      VERIFY it, do not re-derive it. The precheck block below is "
                             "rendered WHOLE - its tuning lines, its uncovered lines and its missing "
                             "DB rows are all shown - so there is nothing to go and read in "
                             "mapped-pre\\<slug>.json. If the two disagree by more than the dish can "
                             "explain, say so in `detail`.")
            else:
                lines.append("    MACRO CROSS-CHECK: NOT pre-computed (%s). Source published %s cal / "
                             "%s carbs / %s protein (%s). Do the check yourself over the lines you rule."
                             % (mp.get("reason") or mp.get("state") or "no table",
                                src.get("cal"), src.get("carbs"), src.get("protein_g"),
                                src.get("from") or "unknown"))
            # M2: the batch's own estate, rendered per slug directly after its block - the same move
            # CHANGE W made for the writer and CHANGE A for the auditor.
            extras = self.map_dossier_extras(slug, t)
            if extras:
                lines.append(extras)
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
            # D3: NAME THE FIELD. The lesson three paragraphs down is that a prompt saying
            # \"unchanged contract\" without naming one new field broke a clean batch, and a shelf
            # the judge does not know is a shelf reads as an unexplained block of quotes.
            "Some residual lines carry a PRIOR RULINGS shelf - rulings on SIMILAR past phrases,\n"
            "evidence only; they resolve nothing and you may disagree with them. Each one was ruled\n"
            "for a DIFFERENT phrase and carries that phrase, its decision and its date, because\n"
            "cosine ranks wording likeness and not food identity. A shelf that says BLIND means the\n"
            "lookup could not run, which is absent evidence and not absence of precedent.\n\n"
            "READS. The table above is the estate, already read for you. Do NOT open the vocabulary, the\n"
            "commodity files, the board, the feed or the resolutions ledger - every question they answer\n"
            "is answered above, and a re-read costs a turn that re-reads the whole accumulated context\n"
            "with it. The ONE read still worth a turn is a nutrition LABEL for a food the table marks as\n"
            "having no food-macros-db row, because that transcription has to be label-accurate and\n"
            "nothing here can supply it - and even that read has a shelf in front of it. Where the table\n"
            "shows FDC CANDIDATES for a term, PREFER one of them and cite it as `fdc:<id>`; go to the\n"
            "open web ONLY when the shelf has no match for that food, and cite the URL you read.\n"
            "Most terms now arrive with the shelf already FILLED FOR THIS RUN - the orchestrator asks\n"
            "FDC about this batch's own terms before you are dispatched. So a term with no shelf\n"
            "candidates means FDC WAS ASKED and lacks it: go straight to the open web for that one\n"
            "without re-checking FDC yourself.\n"
            "THE SHELF IS fdc_lookup's OWN OUTPUT, already fetched for this run. Do NOT query\n"
            "api.nal.usda.gov yourself and NEVER with DEMO_KEY - a demo key silently throttles and\n"
            "reads as 'FDC has no data for this food', which is the worst lie a nutrition lookup can\n"
            "tell. If the shelf has no candidate for a food, FDC was asked and lacks it: go to the\n"
            "open web.\n"
            "ONE fetch and ONE fallback per food, AND THE CAP COUNTS LABEL READS - a page you opened\n"
            "and could transcribe. A WebSearch is NOT a read: it returns snippets, it is how you FIND\n"
            "the label, and it never spends the allowance. Two searches that found nothing leave both\n"
            "your reads unspent, so go and read. If two LABEL READS have not produced a printed label\n"
            "you can transcribe, return NO row for that food and say why in `food_db_absent` - a\n"
            "missing row is a finding a person can act on, and a fifth fetch is a turn that re-reads\n"
            "this whole session. Measured 2026-08-25, both directions in one drill: 9 web calls on 2\n"
            "foods on one batch, and on the other the mapper spent 2 SEARCHES, read no label at all,\n"
            "returned no row and gave no reason - and the write lane then refused the recipe. A row\n"
            "you did not even look for is not a cap working.\n\n"
            "EVERY FOOD THE TABLE MARKS AS HAVING NO ROW COMES BACK ONE OF EXACTLY TWO WAYS, and this\n"
            "is now CHECKED before your answer is accepted - a payload that answers for neither is\n"
            "re-asked with the foods named:\n"
            "  a row in `food_db_rows`      - a label you actually read, transcribed as printed; or\n"
            "  an entry in `food_db_absent` - {item, why}, naming what you looked at and what was\n"
            "                                 missing. This does NOT unblock the recipe; the row is\n"
            "                                 still gone and the skeleton still refuses. It makes the\n"
            "                                 block carry your sentence instead of nothing.\n"
            "A FOOD THAT CARRIES NO MACROS IS NOT AN ABSENCE - IT IS A ROW OF ZEROES. Salt, black\n"
            "pepper and plain water have printed labels reading 0 calories, 0 protein, 0 carbs, 0 fat,\n"
            "and that row is label-accurate, passes the Atwater check for free and costs the recipe\n"
            "nothing. Declaring salt absent stops a recipe over a number the label states.\n"
            "Measured 2026-08-26 on why this is a field and not a sentence: a mapper returned an EMPTY\n"
            "food_db_rows while its own `detail` read \"New DB rows returned: Yellow Onion, Apple,\n"
            "Chicken Thighs, Fresh Rosemary\". The prose is the thing that lied, so the prose is not\n"
            "what clears the silence.\n\n"
            "YOU DO NOT EDIT meal-prep\\food-macros-db.json ANY MORE EITHER. No file access to it.\n"
            "Return each new row in `food_db_rows` and the ORCHESTRATOR writes the DB: same shape as the\n"
            "DB's own entries, one row per food the table marks as having none.\n"
            "  required : item, serving_grams, calories, protein_g, carbs_g, fat_g\n"
            "  also give: brand, serving_qty, serving_unit, fiber_g, notes, and `source` - which is\n"
            "             `fdc:<id>` off the shelf, or the URL of the label you read. A row citing\n"
            "             NEITHER is refused, because arithmetic can prove four numbers agree with each\n"
            "             other and only provenance can say they are THIS food's numbers.\n"
            "The orchestrator Atwater-checks every row (4/4/9 against the stated calories) and REFUSES a\n"
            "conflict: if the DB already carries that item with different macros, nothing is written, both\n"
            "rows are quoted in the run's findings and the existing row stands. So give the label AS\n"
            "PRINTED, never a reconstruction - a row you reasoned your way to will either fail the check\n"
            "or, worse, pass it while describing a different food.\n\n"
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
            "%s%s"
            % (len(slugs), hunt_lib.MAP_BATCH, "\n\n".join(blocks), hunt_lib.TARGET_SERVINGS,
               self.run_dir, " | ".join(hunt_lib.MAPPED_RULING_DECISIONS),
               self.run_dir, self.conditions, self.food_db_seam_note(),
               self.GREP_HARNESS_NOTE))

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
        await self.lane_free_end("price", "pre-pass batch %d" % n, terms, "pre-pass",
                                 ", ".join("%s %d" % kv for kv in sorted(tal.items())))
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
        # T3 (2026-08-25): TIMED, because this is the longest thing a run can do and it logged
        # NOTHING. LOOKUP_TIMEOUT is 45 minutes; a store sweep that takes half of that fell into a
        # lane-log gap, so the one block most likely to dominate a wide run's wall clock was the one
        # block no summary could see. Per STORE, because that is the unit that varies - a seeded
        # Sam's and a NEEDS-SEEDING Sam's differ by the entire timeout.
        rc, so, se = await self.py_timed("price", "store-lookup:%s" % store_key, [],
                                         PULL_BROWSER_STORES_PY,
                                         ["--store", store_key, "--lookup-terms-file", tf,
                                          "--lookup-out", out], timeout=LOOKUP_TIMEOUT,
                                         by="pre-pass")
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
            "that from the queue.\n%s"
            % (len(terms), ", ".join(terms),
               ", ".join(blocked) or "(the evidence names none)",
               price_evidence.NO_BROWSER_EVIDENCE,
               (" - today that is: " + ", ".join(walled)) if walled else "",
               len(terms), 7 * len(terms), self.queue_seam_note()))
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
        rc, out, err = await self.ps_timed("write", "build-intake-skeleton", [slug],
                                          BUILD_SKELETON_PS,
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
        rc, out, err = await self.ps_timed("write", "skeleton verify", [slug], BUILD_SKELETON_PS, [
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

    def unverified_foods(self, slug):
        """Food-DB rows THIS recipe's macros rest on that we ourselves flagged `needs_verify`.

        B4 (Brad's ruling 2026-08-24). 11 of 345 rows carry the flag - 3.2% - and six of the eleven are
        BONE-IN CUTS failing the same way: USDA states the EDIBLE portion, the board needs
        AS-PURCHASED, and the bridge is an estimated edible-yield factor. `Beef Back Ribs` is
        9 g protein per 100 g as-purchased via `USDA lean-only x 0.45 edible yield`, and its own note
        says "TWO DISCLOSED ESTIMATES". 6b retired that recipe at 41.6 g against a 50 g floor, and the
        entire 15 g gap was that one estimate.
        """
        out = []
        try:
            with open(os.path.join(self.run_dir, "intake", "%s.json" % slug),
                      "r", encoding="utf-8-sig") as f:
                items = [str(i.get("item") or "") for i in ((json.load(f) or {}).get("ingredients") or [])]
        except Exception:                                         # noqa: BLE001
            return out
        for name in items:
            row = self.food_db().get(name)
            if isinstance(row, dict) and row.get("needs_verify"):
                out.append(name)
        return out

    def food_db(self):
        if getattr(self, "_food_db", None) is not None:
            return self._food_db
        idx = {}
        try:
            with open(self.food_db_path, "r", encoding="utf-8-sig") as f:
                doc = json.load(f)
            rows = doc.get("foods") or doc.get("items") or doc
            if isinstance(rows, dict):
                rows = list(rows.values())
            for r in (rows if isinstance(rows, list) else []):
                if isinstance(r, dict) and r.get("item"):
                    idx[str(r["item"])] = r
        except Exception:                                         # noqa: BLE001
            pass
        self._food_db = idx
        return idx

    async def retire_out_of_band(self, slug, verdict, where):
        """priced -> rejected-macros, in ONE advance. Both band gates land the same way: the pre-write
        one because no prose was ever paid for, and the post-build one because the state advances
        happen after it, so the recipe is still at `priced` when it rules.

        B4: A GATE MAY FAIL CLOSED ON A NUMBER WE STAND BEHIND. It may not KILL a dish on one we have
        ourselves labelled an estimate - that is the same class as the qty engine guessing a density
        (B2), one stage later and with a recipe's life on it. When the macros rest on a `needs_verify`
        row the recipe PARKS for verification instead, resumable, saying which row and why.
        """
        unverified = self.unverified_foods(slug)
        if unverified:
            why = ("the band would retire this recipe (%s), but its macros rest on food-DB row(s) we "
                   "flagged needs_verify: %s. A gate may fail closed on a number we stand behind; it "
                   "may not kill a dish on one we called an estimate. Verify the row (fetch the FDC "
                   "panel, cross-check by Atwater, record it) and resume."
                   % (verdict["reason"], ", ".join(sorted(set(unverified)))))
            self.log("macro gate (%s): %s PARKED for verification - %s" % (where, slug, ", ".join(sorted(set(unverified)))))
            self.findings.append("%s: %s" % (slug, why))
            self.stuck(slug, "macro-gate", why[:400])
            return
        self.log("macro gate (%s): %s at %s - retiring" % (where, slug, verdict["reason"]))
        await self.settle(slug, "rejected-macros", "macro-gate",
                          "macro gate (%s): %s" % (where, verdict["reason"]), "macro-gate")

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
                                          validator=hunt_lib.validate_writer_fields,
                                          stage="writer"),
                    slug, "write")
                if r is None:
                    self.stuck(slug, "write", "no response after retries - never actually written")
                    continue
                if hunt_lib.is_rejected(r.get("status")):
                    await self.settle(slug, "rejected-qa", "writer",
                                      r.get("detail") or "writer rejected", "write")
                    continue

                # CHANGE W: THE DAEMON PATCHES THE INTAKE from the payload. A writer that never opens
                # the file cannot drift a locked field.
                okp, whyp = self.apply_writer_fields(slug, r.get("fields"))
                if not okp:
                    self.stuck(slug, "write", whyp[:250])
                    continue

                # THE LOCKED-FIELD DIFF STAYS, AND ITS MEANING INVERTS. It used to catch the writer
                # editing a machine field, and the answer was the one re-ask. Post-patch, the writer
                # could not have touched a locked field - only apply_writer_fields writes this file -
                # so a difference here is an ORCHESTRATOR DEFECT. That is a STUCK carrying the detail,
                # never a re-ask, because there is nobody to ask. The redrift road is DELETED: the
                # prompt, the re-dispatch and the "drifted twice" rejected-qa branch are gone, and the
                # dispatch count is the fixture that proves it.
                clean, drift, vdetail = await self.verify_skeleton(slug)
                if not clean and not drift:
                    self.stuck(slug, "write", vdetail[:250])
                    continue
                if not clean:
                    detail = ("the patcher touched a locked field - daemon bug, not a writer defect. "
                              "%s" % "; ".join(drift))
                    self.findings.append("%s: %s" % (slug, detail))
                    self.stuck(slug, "write", detail[:250])
                    continue
                # THE COST PASS IS SERIALIZED. Spec assembly stayed parallel; this does not.
                rc_spec, sp_out, sp_err = await self.cost_engine(
                    BUILD_V2_SPEC_PS, self.spec_args(slug),
                    lane="write", stage="build-v2-spec", items=[slug])
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

    # ---- CHANGE W: THE WRITER RETURNS FIELDS, THE DAEMON PATCHES THE INTAKE ----------------------
    #
    # The old contract said "COMPLETE its intake IN PLACE": the writer Read extracted\<slug>.json,
    # mapped\<slug>.json and intake\<slug>.json, then Edited the intake field by field. Measured on
    # 6b: 23 turns, 1,169,531 raw tokens for ONE recipe, and a whole re-ask class (redrift) existing
    # only to police what construction can prevent. A writer that never opens the intake cannot drift
    # a locked field.
    #
    # WHAT THIS DELETES, AND WHY THAT IS SAFE. The redrift road is gone: redrift_prompt, the r2
    # re-dispatch, and the "drifted twice" rejected-qa branch. verify_skeleton STAYS and its meaning
    # INVERTS - post-patch, a locked-field difference can no longer be the writer's doing, so it is
    # an ORCHESTRATOR DEFECT and the recipe goes STUCK carrying that sentence. It is never re-asked,
    # because there is nobody to ask. The one-correction discipline is untouched where it still
    # applies (QA); here the defect class is dead rather than managed.
    def apply_writer_fields(self, slug, fields):
        """Patch the intake with exactly the writer-fillable fields. Returns (ok, why_not).

        REFUSES the whole patch if any key is outside the fillable set. That refusal normally never
        reaches here - validate_writer_fields runs at DISPATCH so the model gets the re-ask with the
        key named - and this is the belt behind that brace, because the patcher is the thing actually
        holding the pen.
        """
        fields = fields or {}
        if not isinstance(fields, dict):
            return False, "the writer returned `fields` as %s, not an object" % type(fields).__name__
        bad = [k for k in sorted(fields) if k not in hunt_lib.WRITER_FIELDS]
        if bad:
            return False, ("the writer returned field(s) outside the fillable set and NOTHING was "
                           "patched: %s" % ", ".join(bad))
        path = os.path.join(self.run_dir, "intake", "%s.json" % slug)
        try:
            with open(path, "r", encoding="utf-8-sig") as f:
                doc = json.load(f)
        except Exception as e:                                    # noqa: BLE001
            return False, "the intake could not be read for patching (%s)" % e
        if not isinstance(doc, dict):
            return False, "the intake is not an object, so there is nothing to patch"
        for key in fields:
            # SPLIT ON THE FIRST DOT ONLY. `prose.cost_closing_html` is a two-level path, not three,
            # and a naive split on every dot would invent a nesting the spec builder cannot read.
            head, sep, tail = key.partition(".")
            if not sep:
                doc[key] = fields[key]
                continue
            sub = doc.get(head)
            if not isinstance(sub, dict):
                sub = {}
                doc[head] = sub
            sub[tail] = fields[key]
        try:
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(doc, f, ensure_ascii=False, indent=1)
            os.replace(tmp, path)
        except Exception as e:                                    # noqa: BLE001
            return False, "the patched intake could not be written (%s)" % e
        return True, ""

    def writer_dossier(self, slug):
        """Everything the writer used to spend turns READING, rendered inline.

        The bound is worth stating because section 9 names it as a way this backfires: the
        transcription plus the locked view is ~10-20k chars for a normal recipe against 23 turns at
        ~51k of context each. If it ever runs long the drill reports it rather than shipping blind.
        """
        def read(*parts):
            try:
                with open(os.path.join(self.run_dir, *parts), "r", encoding="utf-8-sig") as f:
                    return json.load(f) or {}
            except Exception:                                     # noqa: BLE001
                return {}

        ex = read("extracted", "%s.json" % slug)
        sk = read("intake", "%s.skeleton.json" % slug) or {}
        # the snapshot is {slug, findings, intake:{...}}; the intake itself is the bare document. Read
        # whichever arrived rather than assuming, so a dossier is never silently empty.
        if isinstance(sk.get("intake"), dict):
            sk = sk["intake"]
        if not sk:
            sk = read("intake", "%s.json" % slug)
        out = []
        out.append("THE TRANSCRIPTION - the recipe of record, exactly as the source page states it:")
        out.append("  title  : %s" % as_text(ex.get("title") or sk.get("name")))
        out.append("  source : %s" % as_text(ex.get("source_url") or sk.get("source_url")))
        ings = [i for i in (ex.get("ingredients") or []) if i]
        out.append("  ingredients as written (%d):" % len(ings))
        for i in ings:
            out.append("    - %s" % as_text(i if isinstance(i, str) else
                                            (i.get("raw") or i.get("text") or json.dumps(i)), 300))
        steps = [i for i in (ex.get("instructions") or ex.get("steps") or []) if i]
        out.append("  instructions as written (%d):" % len(steps))
        for n, st in enumerate(steps, 1):
            out.append("    %d. %s" % (n, as_text(st if isinstance(st, str)
                                                  else (st.get("text") or json.dumps(st)), 900)))
        out.append("")
        out.append("THE SKELETON'S LOCKED VIEW - these are the engine's own figures. They are already")
        out.append("in the intake, they are not yours to set, and they are the ONLY numbers that may")
        out.append("appear in your prose:")
        out.append("  name      : %s" % as_text(sk.get("name")))
        out.append("  protein   : %s" % as_text(sk.get("protein")))
        out.append("  servings  : 14")
        mac = sk.get("macros_per_serving") or {}
        out.append("  per serving: %s" % ", ".join(
            "%s %s" % (k, mac.get(k)) for k in ("calories", "protein_g", "carbs_g", "fat_g")
            if mac.get(k) is not None))
        head = sk.get("head") or {}
        out.append("  times     : prep %s, cook %s, total %s"
                   % (head.get("prepTime") or "-", head.get("cookTime") or "-",
                      head.get("totalTime") or "-"))
        lines = [i for i in (sk.get("ingredients") or []) if isinstance(i, dict)]
        out.append("  the %d LOCKED ingredient lines, as the reader will see them:" % len(lines))
        for i in lines:
            out.append("    - %s%s" % (as_text(i.get("item"), 90),
                                       (" | buy: %s" % as_text(i.get("buy"), 160))
                                       if i.get("buy") else ""))
        return "\n".join(out)


    def write_prompt(self, slug):
        """PROSE ONLY, AND NOT A FILE IN SIGHT (CHANGE W). The content the writer used to Read is
        rendered inline; its entire deliverable is the `fields` object in its payload."""
        return (
            "Write recipe %s in Brad's voice. Your entire deliverable is the `fields` object in your\n"
            "payload. You have NO files to read and NO files to write: everything you would have\n"
            "opened is below, and the ORCHESTRATOR patches the intake with what you return.\n\n"
            "%s\n\n"
            "FILL EXACTLY THESE FIELDS, as literal dotted keys inside `fields`:\n"
            "  prose.intro_html        - the opening, Brad talking about this dish\n"
            "  prose.shop_smart        - how to buy for it well\n"
            "  prose.make_it           - the method in Brad's voice, faithful to the transcription\n"
            "  prose.portion_html      - how it portions across the 14 containers\n"
            "  prose.cost_closing_html - the closing on what it costs to eat this way\n"
            "  prose.upsell_html       - the close\n"
            "  cuisine                 - one short label\n"
            "  head.description        - the SEO description\n"
            "  head.keywords           - the SEO keywords\n"
            "  head.steps              - ARRAY of strings, the schema steps\n"
            "  head.step_names         - ARRAY of strings, one short name per step, same length\n"
            "  writer_notes            - ARRAY of strings, anything a later reader needs\n"
            "  forbidden_prose_terms   - ARRAY of strings\n"
            "Any other key refuses the WHOLE payload and comes back to you with the key named. Every\n"
            "field not in that list belongs to the skeleton and is LOCKED - and you cannot reach it\n"
            "anyway, which is the point: the prose-number defect class is dead by construction now\n"
            "rather than caught at QA.\n\n"
            "Voice rails, unchanged: no em dashes, Brad's tone, the existing framework, 14 servings.\n"
            "Compute NO number. Every macro and every cost comes from the engine, and the only figures\n"
            "that may appear in your prose are the ones shown in the locked view above. The\n"
            "orchestrator runs the spec build and reads the band off the built spec itself. Do not run\n"
            "hunt-run.ps1 and do not move any state.\n\n"
            "This run's conditions: %s\n"
            % (slug, self.writer_dossier(slug), self.conditions))

    # redrift_prompt DELETED 2026-08-25 (CHANGE W). It re-asked the writer to put back locked fields
    # it had edited. The writer has no file access now, so that payload class cannot exist: a
    # post-patch locked-field difference is the PATCHER's doing, which is a daemon bug and a STUCK,
    # not a question to ask a model. See write_lane below.

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
                self.write_qa_verdict(slug, q)
                if not hunt_lib.is_pass(q.get("verdict")):
                    owner = self.owner_agent(q.get("owner"))
                    self.log("QA FAIL %s -> one repair cycle by %s" % (slug, owner))
                    # D2: ERROR HAS TO WRITE. A QA fail the MAPPER owns is the estate discovering
                    # that an identity it settled was wrong, and until now that discovery lived in
                    # one run dir and died there. The event does not touch the ledger - a fail is not
                    # a new identity - but it is what makes the correction loop legible afterwards:
                    # the repair re-ruling re-projects, the old row is superseded, and this event is
                    # the reason anyone can see WHY.
                    await asyncio.get_running_loop().run_in_executor(
                        None, self.learn_qa_fail, slug, q)
                    # CHANGE A (section 5.3): THE SAME SPLIT, ONE LANE OVER. A QA finding the WRITER
                    # owns lives in the fillable fields, so it is a field patch through the same
                    # road. A finding owned by the extractor or the mapper needs re-extraction or
                    # re-mapping and keeps its current owner and its current prompt, unchanged - the
                    # owner routing above is what decides, and it decided this before CHANGE A too.
                    if owner == "recipe-writer":
                        await self.qa_repair_by_patch(slug, q)
                    else:
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
                    self.write_qa_verdict(slug, q)
                    if not hunt_lib.is_pass(q.get("verdict")):
                        await self.settle(slug, "rejected-qa", "source-qa",
                                          "failed QA twice: %s" % (q.get("findings") or "")[:150],
                                          "qa", outcome_detail="failed source-QA twice")
                        continue
                # A PASS IS A TERMINAL OUTCOME TOO, and it is the one with money behind it: only
                # `qa-passed` opens a wave, and a wave publishes. A refused advance here would leave
                # the recipe queued for a wave it can never legally enter (`waved` is reachable from
                # `qa-passed` alone), so it takes the same road as every rejection.
                if not await self.settle(slug, "qa-passed", "source-qa", "", "qa",
                                         status="qa-passed"):
                    continue
                self.qa_passed.append(slug)
                # the ported maybeCloseWave(false): a full pool closes a wave NOW, mid-run
                self.schedule_wave(False)
        await self.pool_worker(hunt_lib.LANE_CAPS["qa"], worker)

    @staticmethod
    def owner_agent(owner):
        return {"extractor": "recipe-hunter-extractor",
                "mapper": "recipe-ingredient-mapper"}.get(owner, "recipe-writer")

    def learn_qa_fail(self, slug, q):
        r"""One `qa_mapper_fail` event, and ONLY when the raw owner field is `mapper`.

        THE RAW FIELD, NOT owner_agent()'s ANSWER, and the difference is the whole check.
        owner_agent maps anything it does not recognise to `recipe-writer`, so routing tells you
        who repairs it; only the raw field tells you the QA agent actually blamed the MAPPING. An
        event keyed off the routed name would file every unowned fail under the writer and none of
        them here.

        The slug's residual keys ride inside `evidence`, read from the run's own
        mapped-pre\<slug>.rulings.json - and when that file cannot be read the event SAYS SO rather
        than listing nothing, because "this recipe had no residual terms" and "we could not find out
        which terms it had" are different facts about a failure.

        Sync on purpose: it appends ONE line and is called through run_in_executor, so nothing here
        holds a file handle across an await.
        """
        if str((q or {}).get("owner") or "").strip().lower() != "mapper":
            return None
        keys, why = learn_apply.residual_keys_for(self.run_dir, slug)
        how, _ev = learn_apply.qa_fail_event(
            slug, as_text(q.get("findings"), 600), run=self.run_id,
            residual_keys=keys, why_keys=why, events=self.events_path)
        if how == "failed":
            self.findings.append("learn/%s: the QA mapper-fail could not be recorded as an event"
                                 % slug)
        return how

    def qa_battery_args(self, slug):
        """The battery's command line, SPLIT OUT so its seam is assertable.

        This call shells straight through subprocess.run rather than ps()/py(), so a fixture has
        nothing to intercept and the T6 seam here was unpinned - measured 2026-08-25, when reverting
        it to the live path produced ZERO red on a full roster. A seam no neuter can reach is a seam
        that will quietly come undone.
        """
        return [sys.executable, os.path.join(HERE, "coverage_check.py"), "--battery",
                # T6: the QA battery grades the spec this RUN built, not the live one that happens to
                # share the slug. A drill reusing a live slug was grading a file it never wrote.
                "--spec", os.path.join(self.specs_dir or SPECS_DIR, "%s.json" % slug),
                "--source", os.path.join(self.run_dir, "extracted", "%s.json" % slug),
                "--run-dir", self.run_dir]

    async def qa_battery(self, slug):
        import subprocess                                          # noqa: PLC0415
        loop = asyncio.get_event_loop()
        args = self.qa_battery_args(slug)
        p = await loop.run_in_executor(None, lambda: subprocess.run(args, capture_output=True))
        if p.returncode == hunt_lib.EXIT_CANNOT_RUN:
            # Exit 2 is a BLOCKED stage, never a pass. It is a finding for the QA agent to see, not
            # a reason to skip the QA agent.
            self.findings.append("%s: the QA battery could not run (exit 2)" % slug)
        return p.returncode

    async def qa_repair_by_patch(self, slug, q):
        """The QA lane's patch road. Same payload shape, same validator, same patcher as the wave
        lane's - and the ONE-REPAIR RULE is untouched: this consumes the single cycle exactly as the
        full-agent road did, and the caller re-QAs once regardless of what happened here."""
        r = await self.dispatch("recipe-writer",
                                self.qa_repair_patch_prompt(slug, q),
                                "qa", "repair-patch:%s" % slug, [slug],
                                schema=hunt_lib.REPAIRPATCH,
                                validator=hunt_lib.validate_writer_fields,
                                stage="recipe-writer")
        if r is None:
            self.findings.append("%s: the QA repair returned NO VERDICT, so nothing was patched"
                                 % slug)
            return
        if r.get("no_change") or not r.get("fields"):
            self.findings.append("%s: the QA repair changed nothing BY ITS OWN ACCOUNT: %s"
                                 % (slug, as_text(r.get("reason"), 300)))
            return
        ok, why = self.apply_writer_fields(slug, r.get("fields"))
        if not ok:
            self.findings.append("%s: the QA repair was REFUSED and nothing was patched - %s"
                                 % (slug, why))
            return
        rc, out, err = await self.cost_engine(BUILD_V2_SPEC_PS, self.spec_args(slug),
                                              lane="qa", stage="repair-spec-build", items=[slug])
        if rc != 0:
            self.findings.append("%s: the QA repair patched the intake but the spec build REFUSED "
                                 "(rc %d): %s" % (slug, rc, hunt_lib.first_guard_line(out, err)))

    def qa_repair_patch_prompt(self, slug, q):
        def read(*parts):
            try:
                with open(os.path.join(self.run_dir, *parts), "r", encoding="utf-8-sig") as f:
                    return json.load(f) or {}
            except Exception:                                     # noqa: BLE001
                return {}

        cur = read("intake", "%s.json" % slug)
        shown = []
        for key in hunt_lib.WRITER_FIELDS:
            head, sep, tail = key.partition(".")
            val = (cur.get(head) or {}).get(tail) if sep else cur.get(key)
            if isinstance(val, list):
                shown.append("  %s (array of %d):" % (key, len(val)))
                for x in val:
                    shown.append("      - %s" % as_text(x, 300))
            else:
                shown.append("  %s: %s" % (key, as_text(val, 700)))
        return (
            "Source-QA failed recipe %s and routed the repair to you. This is the ONE repair cycle it\n"
            "gets; a second failure is terminal, so fix the actual finding rather than papering over\n"
            "it.\n\nFINDINGS:\n%s\n\n"
            "THE FIELDS AS THEY STAND RIGHT NOW:\n%s\n\n"
            "Return a `fields` object carrying ONLY the fields you are changing, keyed by the same\n"
            "literal dotted names. The ORCHESTRATOR patches the intake and rebuilds the spec; you have\n"
            "no files to open and none to write, and you must not run build-v2-spec or hunt-run\n"
            "yourself. Any key outside the fillable set refuses the whole payload.\n\n"
            "IF NOTHING NEEDED CHANGING, SAY SO: return `no_change: true` with a reason and no\n"
            "`fields`. That is a legitimate answer and it is treated differently from claiming a change\n"
            "that did not happen. Never weaken a gate. If the finding is NOT reachable from these\n"
            "fields - if it needs the recipe re-extracted or re-mapped - say that plainly with\n"
            "`no_change: true` rather than patching something adjacent to it.\n"
            % (slug, "\n".join("  - %s" % x for x in
                               (str(q.get("findings") or "").replace("\r", "").split("\n") or [])
                               if x.strip()) or "  (source-QA named no finding)",
               "\n".join(shown)))

    # ---- F3 (2026-08-25): QA RULES FROM A DOSSIER TOO -------------------------------------------
    #
    # THE STAGE IS NOT MERGED, AND THAT IS A DECISION, not an omission. The eval's F3 named the
    # write -> qa -> repair -> re-qa tail as four sessions over the same material and asked whether to
    # collapse it. A writer QAing its own work is worth nothing and source-qa's whole value is an
    # INDEPENDENT reader, so what lands here is the smaller proven move: source-qa keeps its own
    # session and gets its material INLINE, exactly as the auditor did in CHANGE A. Independence is
    # about WHO RULES, not about who does the file I/O.
    #
    # THE LIVE-PAGE FETCH STAYS A RIGHT. It is the one thing a dossier cannot carry, and it is part of
    # the fidelity check's value - so QA turns are expected to land around 2-3, not 1.
    def qa_dossier(self, slug):
        """The transcription, the BUILT SPEC's reader-facing view, and the battery's numbers."""
        def read(*parts):
            try:
                with open(os.path.join(*parts), "r", encoding="utf-8-sig") as f:
                    return json.load(f) or {}
            except Exception as e:                                # noqa: BLE001
                return {"_unreadable": str(e)[:160]}

        ex = read(self.run_dir, "extracted", "%s.json" % slug)
        spec = read(self.specs_dir or SPECS_DIR, "%s.json" % slug)
        bat = read(self.run_dir, "qa", "%s.battery.json" % slug)
        out = []
        out.append("THE TRANSCRIPTION - the recipe of record, and your anchor:")
        if ex.get("_unreadable"):
            # ANNOUNCED, never rendered as an empty section: a QA reading "ingredients as written (0)"
            # would take a dropped-everything recipe for a faithful one.
            out.append("  COULD NOT BE READ (%s) - read %s\\extracted\\%s.json yourself before ruling."
                       % (ex["_unreadable"], self.run_dir, slug))
        else:
            out.append("  title  : %s" % as_text(ex.get("title")))
            out.append("  source : %s" % as_text(ex.get("source_url")))
            ings = [i for i in (ex.get("ingredients") or []) if i]
            out.append("  ingredients as written (%d):" % len(ings))
            for i in ings:
                out.append("    - %s" % as_text(i if isinstance(i, str) else
                                                (i.get("raw") or i.get("text") or json.dumps(i)), 300))
            steps = [i for i in (ex.get("instructions") or ex.get("steps") or []) if i]
            out.append("  instructions as written (%d):" % len(steps))
            for n, st in enumerate(steps, 1):
                out.append("    %d. %s" % (n, as_text(st if isinstance(st, str)
                                                      else (st.get("text") or json.dumps(st)), 900)))
        out.append("")
        out.append("THE BUILT RECIPE, as a reader will meet it - this is what we are about to sell:")
        if spec.get("_unreadable"):
            out.append("  COULD NOT BE READ (%s) - the spec is at %s\\%s.json."
                       % (spec["_unreadable"], self.specs_dir or SPECS_DIR, slug))
        else:
            out.append("  name     : %s" % as_text(spec.get("name") or spec.get("title")))
            out.append("  servings : %s" % as_text(spec.get("servings")))
            mac = spec.get("macros_per_serving") or spec.get("stat") or {}
            if isinstance(mac, dict) and mac:
                out.append("  per serving: %s" % ", ".join(
                    "%s %s" % (k, mac.get(k)) for k in sorted(mac) if mac.get(k) is not None))
            lines = [i for i in (spec.get("ingredients") or []) if isinstance(i, dict)]
            out.append("  the %d ingredient lines, with the buy strings the reader sees:" % len(lines))
            for i in lines:
                out.append("    - %s%s" % (as_text(i.get("item"), 90),
                                           (" | buy: %s" % as_text(i.get("buy"), 160))
                                           if i.get("buy") else ""))
            steps = (spec.get("make_it") or (spec.get("prose") or {}).get("make_it")
                     or (spec.get("head") or {}).get("steps") or [])
            if isinstance(steps, str):
                steps = [steps]
            out.append("  the %d make-it step(s) as written:" % len(steps))
            for n, st in enumerate(steps, 1):
                out.append("    %d. %s" % (n, as_text(st if isinstance(st, str)
                                                      else json.dumps(st), 900)))
        out.append("")
        out.append("THE BATTERY, already run - its findings are QUESTIONS for you, never verdicts:")
        if bat.get("_unreadable"):
            out.append("  COULD NOT BE READ (%s) - and a battery nobody could read is not a battery "
                       "that passed. Read %s\\qa\\%s.battery.json or say plainly that you ruled "
                       "without it." % (bat["_unreadable"], self.run_dir, slug))
        else:
            checks = bat.get("checks") or bat.get("slug_checks") or []
            if isinstance(checks, dict):
                checks = [c for v in checks.values() for c in (v if isinstance(v, list) else [v])]
            for c in (checks if isinstance(checks, list) else []):
                if not isinstance(c, dict):
                    continue
                nums = c.get("numbers")
                out.append("  %-28s %-6s %s"
                           % (as_text(c.get("check"), 28), as_text(c.get("verdict"), 6),
                              (" ".join("%s=%s" % (k, nums[k]) for k in sorted(nums))
                               if isinstance(nums, dict) and nums
                               else as_text(c.get("detail"), 160))))
            if not checks:
                out.append("  (the battery report names no checks - say so in your verdict rather "
                           "than treating it as a pass)")
        return "\n".join(out)

    def qa_prompt(self, slug, attempt):
        return (
            "Fidelity check on ONE built recipe: %s. Is the recipe we are about to sell the recipe we\n"
            "actually found?\n\n%s\n\n"
            "EVERYTHING ABOVE IS ALREADY READ FOR YOU. The artifacts are still on disk if you want the\n"
            "raw ones - spec %s\\%s.json, transcription %s\\extracted\\%s.json, battery\n"
            "%s\\qa\\%s.battery.json (exit 2 there is a BLOCKED stage) - but a re-read costs a turn and\n"
            "a turn re-reads your whole accumulated context with it.\n%s\n"
            "Anchor on the transcription always; read the live page too when the domain is fetchable -\n"
            "that read is YOURS and it is the one thing the block above cannot carry.\n"
            "A BLOCKED DOMAIN IS NEVER A FINDING AGAINST THE RECIPE - it makes the transcription the\n"
            "sole anchor and the verdict says so. Catch invented, dropped and drifted ingredients and\n"
            "steps. Verdict only: never edit, re-extract or price, and do not move any state - the\n"
            "orchestrator does that from your verdict, and it writes the verdict file itself now, so\n"
            "your entire deliverable is the payload.\n"
            "%s"
            % (slug, self.qa_dossier(slug), self.specs_dir or SPECS_DIR, slug,
               self.run_dir, slug, self.run_dir, slug,
               ("\nThis is the RE-QA after one owner-routed repair cycle. A second FAIL is terminal.\n"
                if attempt > 1 else ""),
               self.GREP_HARNESS_NOTE))

    def write_qa_verdict(self, slug, q):
        r"""THE PEN MOVES TO THE DAEMON (plan 5.2.3, decided from the grep and not from memory).

        source-qa used to Write qa\<slug>.json itself. Nothing reads it: not the daemon (which rules
        off the payload), not wave-preaudit.ps1, not hunt-run.ps1, not any agent definition. The one
        reference in the estate is qa_repair_prompt telling a repairing agent where the file is - and
        that pointer keeps working, because the daemon writes the same file from the same fields.
        The plan expected wave-preaudit and the auditor to read it; they do not, and it is CORRECTED
        there in this commit.

        A payload with NO verdict writes NOTHING: B5 - no verdict is never a pass, and a file on disk
        saying nothing is worse than no file, because it looks like a ruling.
        """
        if not q or not str(q.get("verdict") or "").strip():
            return None
        path = os.path.join(self.run_dir, "qa", "%s.json" % slug)
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"slug": str(q.get("slug") or slug),
                           "verdict": str(q.get("verdict") or ""),
                           "owner": str(q.get("owner") or ""),
                           "findings": str(q.get("findings") or "")}, f, indent=2)
            return path
        except Exception as e:                                    # noqa: BLE001
            self.findings.append("qa/%s: the verdict file could not be written (%s) - the ruling "
                                 "still stands, it is the record that is missing" % (slug, e))
            return None

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
            road = hunt_lib.repair_road(audit.get("blocker_kind"))
            repair_delta = {}
            if road == "patch" and blockers:
                # THE PATCH ROAD. A recipe-local defect lives in this recipe's own fillable fields,
                # so it is a field patch through the writer's own road: same payload shape, same
                # validator, same patcher. Per blocked slug, and the spec is rebuilt for exactly the
                # slugs that actually changed - not the wave.
                repair_delta = await self.repair_by_patch(wk, blockers, audit) or {}
            else:
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
                                                          scope["why"], delta=repair_delta),
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
        rc, out, err = await self.ps_timed("publish", "wave-publish", list(slugs),
                                          WAVE_PUBLISH_PS, pub_args, timeout=3600)
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

    async def repair_by_patch(self, wk, blockers, audit):
        """One patch dispatch per blocked slug, then a spec rebuild for the slugs that changed.

        The findings are split per slug from the auditor's summary where it names one, and every
        blocked slug gets the whole summary otherwise - an under-informed repair is worse than a
        verbose one, and this block costs input tokens, not turns.

        F4 (2026-08-25): RETURNS THE DELTA - {slug: {fields:[...], no_change:"reason"}} - so the
        scoped re-audit can be told what the repair actually touched instead of diffing blind.
        """
        summary = str((audit or {}).get("summary") or "")
        delta = {}
        for slug in blockers:
            findings = [ln.strip() for ln in summary.replace("\r", "").split("\n")
                        if slug in ln and ln.strip()]
            if not findings:
                findings = [summary[:1500]] if summary else []
            r = await self.dispatch("recipe-writer",
                                    self.repair_patch_prompt(wk, slug, findings),
                                    "audit", "wave-%d:repair-patch:%s" % (wk, slug), [slug],
                                    schema=hunt_lib.REPAIRPATCH,
                                    validator=hunt_lib.validate_writer_fields,
                                    stage="recipe-writer")
            if r is None:
                self.findings.append("wave %d: the recipe-local repair of %s returned NO VERDICT, so "
                                     "nothing was patched" % (wk, slug))
                delta[slug] = {"fields": [], "no_change": "the repair returned NO VERDICT"}
                continue
            if r.get("no_change") or not r.get("fields"):
                # A LEGAL ANSWER, and it feeds the changed-nothing guard rather than bypassing it:
                # the guard still reads the mtimes, and this is the second, independent answer.
                self.log("wave %d: %s repair returned no_change - %s"
                         % (wk, slug, as_text(r.get("reason"), 160)))
                self.findings.append("wave %d: the repair of %s changed nothing BY ITS OWN ACCOUNT: %s"
                                     % (wk, slug, as_text(r.get("reason"), 300)))
                delta[slug] = {"fields": [],
                               "no_change": as_text(r.get("reason"), 300) or "no reason given"}
                continue
            ok, why = self.apply_writer_fields(slug, r.get("fields"))
            if not ok:
                self.findings.append("wave %d: the recipe-local repair of %s was REFUSED and nothing "
                                     "was patched - %s" % (wk, slug, why))
                delta[slug] = {"fields": [], "no_change": "the patch was REFUSED: %s" % why[:200]}
                continue
            delta[slug] = {"fields": sorted(str(k) for k in (r.get("fields") or {})),
                           "no_change": ""}
            rc, out, err = await self.cost_engine(BUILD_V2_SPEC_PS, self.spec_args(slug),
                                                  lane="audit", stage="repair-spec-build",
                                                  items=[slug])
            if rc != 0:
                self.findings.append("wave %d: %s was patched but its spec build REFUSED (rc %d): %s"
                                     % (wk, slug, rc, hunt_lib.first_guard_line(out, err)))
        return delta

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
            await self.settle(s, "rejected-audit", "auditor",
                              ((audit or {}).get("summary") or "blocked by the wave audit")[:200],
                              "audit",
                              outcome_detail="blocked by the wave audit, repair spent")
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
        rc, _o, _e = await self.cost_engine(
            WAVE_PREAUDIT_PS,
            ["-RunDir", self.run_dir, "-Wave", wk]
            # T6: the battery reads the spec store this run built. Without it the preaudit graded
            # live specs for any slug the drill happened to reuse, and every downstream number the
            # auditor is handed came from a file the run never wrote.
            + (["-SpecsDir", self.specs_dir] if self.specs_dir else []),
            timeout=1800, lane="audit", stage="wave-preaudit w%d" % wk, items=[])
        if rc == hunt_lib.EXIT_CANNOT_RUN:
            self.findings.append("wave %d: the preaudit battery could not run (exit 2) - a BLOCKED "
                                 "stage, never a pass" % wk)
        return rc

    def mtimes(self, slugs, audit_path):
        out = {}
        # T6: the staleness reference is the spec store this run WROTE. Against the live store a
        # drill's freshly built spec looks older than an audit it predates, which is the changed-
        # nothing guard reasoning about the wrong file.
        paths = [os.path.join(self.specs_dir or SPECS_DIR, "%s.json" % s) for s in slugs]
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

    # ---- CHANGE A: THE BATTERY SHOWS ITS ARITHMETIC ----------------------------------------------
    #
    # wave-preaudit.ps1 already COMPUTES the chains and carries the numbers - macro-recompute holds
    # `recompute` and `stat` per macro, cost-engine-consistency holds cost_batch / cost_batch_true /
    # cost_per_serving / cost_first_run / lines / lines_unpriced, protein-derivation holds claimed vs
    # derived vs the tally. But audit_prompt only POINTED at the file. The 6b re-audit's own report
    # says it "re-summed both engine rows by hand" and hand-recomputed macros: 28 turns re-deriving
    # what the battery had already derived, because a pass/fail without shown work is - rightly - not
    # taken on faith.
    #
    # SO THE NUMBERS GO INLINE. This is NOT a trim of the audit tier: the authority language below is
    # unchanged word for word, the auditor keeps every tool it had, and the discretionary half of its
    # job is now stated out loud rather than left implied.
    AUDIT_DOSSIER_CAP = 6000

    def render_audit_dossier(self, wk):
        """The preaudit report as a compact numbers block. Returns text, or a plain sentence saying
        the report could not be read - which is a thing the auditor must be TOLD, never left to infer
        from an absence."""
        path = os.path.join(self.run_dir, "waves", "wave-%d.preaudit.json" % wk)
        try:
            with open(path, "r", encoding="utf-8-sig") as f:
                doc = json.load(f) or {}
        except Exception as e:                                    # noqa: BLE001
            return ("THE BATTERY REPORT COULD NOT BE READ (%s). Nothing below is available to you, "
                    "so derive everything yourself and say in your report that the battery was "
                    "unreadable - a missing check is never a passed one." % e)

        def flat(numbers, prefix=""):
            out = []
            for k in sorted(numbers or {}):
                v = numbers[k]
                if isinstance(v, dict):
                    out.extend(flat(v, "%s%s." % (prefix, k)))
                elif isinstance(v, list):
                    out.append("%s%s=[%s]" % (prefix, k, ", ".join(as_text(x, 40) for x in v)))
                else:
                    out.append("%s%s=%s" % (prefix, k, as_text(v, 60)))
            return out

        lines = ["THE BATTERY'S ARITHMETIC, SHOWN. Report: %s" % os.path.basename(path),
                 "  battery %s v%s, scope %s, %s check(s) over %s slug(s), %s FAILED, %.1fs"
                 % (doc.get("battery"), doc.get("version"), doc.get("scope"),
                    (doc.get("summary") or {}).get("checks"),
                    (doc.get("summary") or {}).get("slugs"),
                    (doc.get("summary") or {}).get("failed"), float(doc.get("elapsed_sec") or 0))]
        inputs = doc.get("inputs") or {}
        if inputs:
            lines.append("  inputs: %s" % ", ".join(flat(inputs)))
        for slug in (doc.get("wave_slugs") or doc.get("slugs") or []):
            lines.append("")
            lines.append("  %s" % slug)
            for chk in ((doc.get("slug_checks") or {}).get(slug) or []):
                nums = flat(chk.get("numbers"))
                lines.append("    %-26s %-4s %s" % (chk.get("check"), chk.get("verdict"),
                                                    "  ".join(nums)))
                if str(chk.get("verdict")).lower() != "pass":
                    lines.append("        %s" % as_text(chk.get("detail"), 400))
        shared = doc.get("shared_checks") or []
        if shared:
            lines.append("")
            lines.append("  SHARED (%d)" % len(shared))
            for chk in shared:
                lines.append("    %-26s %-4s %s"
                             % (chk.get("check"), chk.get("verdict"),
                                as_text(chk.get("detail"), 160)))
        nc = doc.get("not_checked") or []
        if nc:
            lines.append("")
            lines.append("  THE BATTERY DID NOT LOOK AT (its own list, and it is your half of the job):")
            for x in nc:
                lines.append("    - %s" % as_text(x, 200))
        text = "\n".join(lines)
        if len(text) > self.AUDIT_DOSSIER_CAP:
            # TRUNCATION IS ANNOUNCED, NEVER SILENT. An auditor reading a quietly cut block would
            # believe it had seen every check, which is worse than not showing it the numbers at all.
            text = (text[:self.AUDIT_DOSSIER_CAP]
                    + "\n  ... THIS BLOCK WAS TRUNCATED at %d chars. The rest is in the report file; "
                      "read it before you rule." % self.AUDIT_DOSSIER_CAP)
        return text

    def repair_delta_block(self, delta):
        """F4: WHAT THE REPAIR CHANGED, for a re-audit only.

        The auditor was re-reading a wave it had already read and diffing it blind against its own
        memory of the first pass. The daemon holds the repair's payload, so it can simply say which
        fields moved on which slug - and which slugs the repair says it deliberately left alone. The
        auditor then VERIFIES the delta against the refreshed battery numbers, which is a much
        smaller job than rebuilding the comparison.

        EVIDENCE, NEVER A VERDICT: a repair that says it changed nothing is still the auditor's to
        disbelieve, and the changed-nothing mtime guard has already run independently of this.
        """
        if not delta:
            return ""
        lines = ["WHAT THE REPAIR CHANGED, from the repair's own payload - the orchestrator applied",
                 "it, so this is what LANDED rather than what was promised:"]
        for slug in sorted(delta):
            d = delta.get(slug) or {}
            fields = [f for f in (d.get("fields") or []) if f]
            if fields:
                lines.append("  %-38s patched %d field(s): %s"
                             % (slug, len(fields), ", ".join(fields)))
            else:
                lines.append("  %-38s CHANGED NOTHING - %s"
                             % (slug, as_text(d.get("no_change"), 240) or "no reason given"))
        lines.append("Verify that delta against the refreshed numbers below rather than re-deriving "
                     "the whole")
        lines.append("wave. Anything NOT listed above was not touched by the repair.")
        return "\n".join(lines) + "\n\n"

    def audit_prompt(self, wk, slugs, batch, scope, why, delta=None):
        return (
            "Audit wave %d of run %s before it publishes.\n"
            "Run dir: %s\nWave file: %s\\waves\\wave-%d.json\nSlugs: %s\n"
            "scope: %s%s\n\n"
            "The mechanical battery has ALREADY RUN for you; its report is at\n"
            "%s\\waves\\wave-%d.preaudit.json. Exit 2 there is a BLOCKED stage, never a pass. It does\n"
            "not audit and it cannot issue a GO - you remain the authority and may re-derive anything\n"
            "in it.\n\n"
            "%s%s\n\n"
            "The arithmetic is shown so you can verify the CHAINS rather than rebuild them; spend your\n"
            "turns where a chain is absent, suspicious, or where external reality (a price that smells\n"
            "wrong, a claim no gate covers) needs eyes. That discretionary look is the half of your job\n"
            "no battery can do.\n\n"
            "This run's conditions: %s\nVerify each recipe's per-serving macros against that in\n"
            "addition to your normal battery.\n\n"
            "Report to %s\\waves\\wave-%d.audit.md. FIRST line exactly GO or NO-GO. SECOND line\n"
            "exactly \"scope: %s\". Return the verdict, the blocking slugs, whether each blocker is\n"
            "recipe-local or shared-data, and the repair owner. The orchestrator stamps the ledger.\n"
            "%s%s"
            % (wk, self.run_id, self.run_dir, self.run_dir, wk, ", ".join(slugs), scope,
               ("\nReason: " + why) if why else "  (first audit of this wave)",
               self.run_dir, wk,
               # THE DELTA RIDES ON RE-AUDITS ONLY, and `why` is non-empty exactly then: a first
               # audit has no repair behind it, so a block there would be describing nothing.
               (self.repair_delta_block(delta) if why else ""),
               self.render_audit_dossier(wk),
               self.conditions, self.run_dir, wk, scope, self.specs_seam_note(),
               self.GREP_HARNESS_NOTE))

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

    # ---- THE REPAIR SPLIT (CHANGE A, section 5.3) ------------------------------------------------
    #
    # Repair writers across both lanes were 22.0% of the 6b run - the single largest consumer - at 20
    # turns and 61k of context per turn, tree-walking a repair the auditor had already described. The
    # AUDIT schema already returns `blocker_kind`, so route on it:
    #
    #   recipe-local -> this prompt: the findings plus the intake's CURRENT fillable values inline,
    #                   and the SAME `fields` payload the writer returns, through the SAME patcher and
    #                   the SAME validator. A prose defect is a field patch.
    #   shared-data  -> the UNCHANGED road. A moved cost basis or a lib defect is genuinely not
    #                   patch-shaped, and repair_prompt keeps its tools and its full agent.
    #
    # AND AN ABSENT OR UNKNOWN KIND TAKES THE SHARED ROAD. That is the conservative direction: a
    # whole-wave re-audit is the expensive-but-safe default, and a patch road asked to fix something
    # it cannot reach would report success over an unrepaired defect.
    PATCH_ROAD_KIND = "recipe-local"

    def repair_patch_prompt(self, wk, slug, findings):
        def read(*parts):
            try:
                with open(os.path.join(self.run_dir, *parts), "r", encoding="utf-8-sig") as f:
                    return json.load(f) or {}
            except Exception:                                     # noqa: BLE001
                return {}

        cur = read("intake", "%s.json" % slug)
        shown = []
        for key in hunt_lib.WRITER_FIELDS:
            head, sep, tail = key.partition(".")
            val = (cur.get(head) or {}).get(tail) if sep else cur.get(key)
            if isinstance(val, list):
                shown.append("  %s (array of %d):" % (key, len(val)))
                for x in val:
                    shown.append("      - %s" % as_text(x, 300))
            else:
                shown.append("  %s: %s" % (key, as_text(val, 700)))
        return (
            "The batch auditor returned NO-GO on wave %d of run %s and blocked %s on a RECIPE-LOCAL\n"
            "defect - one that lives in this recipe's own fillable fields.\n\n"
            "WHAT IT BLOCKS ON:\n%s\n\n"
            "THE FIELDS AS THEY STAND RIGHT NOW:\n%s\n\n"
            "Return a `fields` object carrying ONLY the fields you are changing, keyed by the same\n"
            "literal dotted names. The ORCHESTRATOR patches the intake and rebuilds the spec; you have\n"
            "no files to open and none to write, and you must not run build-v2-spec or hunt-run\n"
            "yourself. Any key outside the fillable set refuses the whole payload.\n\n"
            "IF NOTHING NEEDED CHANGING, SAY SO: return `no_change: true` with a reason and no\n"
            "`fields`. That is a legitimate answer and it is treated differently from claiming a change\n"
            "that did not happen - the orchestrator checks the files themselves before it pays for a\n"
            "re-audit, and it has done since a repair on 2026-08-24 changed nothing at all.\n"
            "Never weaken a gate. If the defect is NOT reachable from these fields, say that plainly\n"
            "with `no_change: true` rather than patching something adjacent to it.\n"
            % (wk, self.run_id, slug,
               "\n".join("  - %s" % as_text(f, 900) for f in (findings or ["(the auditor named no "
                                                                          "finding for this slug)"])),
               "\n".join(shown)))

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

    def state_row(self, slug):
        """The WHOLE state file, not just its state. `hunt-run.ps1 -Status -Json` emits only
        {slug, state} per in_flight row, so a resume that seeds from the status alone hands the
        extract lane a recipe with no URL - and extract_sweep reports that as "the state file
        carries no source_url", which is a lie about the data: the state file has it, the seed
        never read it. Measured 2026-08-24: three recipes STUCK at `selected` on a resumed 6b run,
        all three with a good source_url on disk. Only resumes are affected, which is why the
        original pass never saw it."""
        p = os.path.join(self.run_dir, "state", "%s.json" % slug)
        try:
            with open(p, "r", encoding="utf-8-sig") as f:
                return json.load(f) or {}
        except Exception:                                         # noqa: BLE001
            return {}

    def state_of(self, slug):
        return self.state_row(slug).get("state")

    def blocking_terms(self, slug):
        """Q1. Every NON-OPTIONAL term hunt-run ACTUALLY WROTE to the recipe's state file. Returns
        (terms, why_not) - a non-empty `why_not` is a STUCK, never an empty list.

        THIS IS THE AUTHORITY FOR WHAT GETS ENQUEUED, and that is the whole point. The map lane used
        to enqueue the mapper's `absent_terms` and then advance; -Advance -To pricing is itself a
        writer of this list (the carriage union), so the two lists were allowed to differ and did.
        Reading the record back means the set that blocks and the set that is enqueued are the same
        set by construction rather than by agreement.

        FAIL-CLOSED, LOUDLY. An unreadable state file, a missing `terms` array or a term row that is
        not an object all return a reason and NO terms. The tempting fallback - "use the mapper's
        list, it is probably the same" - is exactly the assumption this function exists to delete: a
        silent empty here is indistinguishable from a recipe that legitimately needs nothing, and the
        recipe would sail to the writer unpriced.

        A SINGLE-ELEMENT ARRAY THAT COLLAPSED TO A SCALAR IS STILL READ. hunt-run guards against
        writing one (its own suite pins it), but this reader is downstream of a PowerShell writer and
        the one-element collapse is the estate's most-paid-for JSON trap.
        """
        row = self.state_row(slug)
        if not row:
            return [], "%s's state file could not be read back after the advance" % slug
        rows = row.get("terms")
        if rows is None:
            return [], "%s's state file carries no `terms` array after the advance" % slug
        if isinstance(rows, dict):
            rows = [rows]
        if not isinstance(rows, list):
            return [], "%s's `terms` is %s, not an array" % (slug, type(rows).__name__)
        out = []
        for t in rows:
            if not isinstance(t, dict):
                return [], ("%s has a term row that is not an object (%r) - the state file cannot be "
                            "trusted to say what blocks" % (slug, t))
            if t.get("optional"):
                continue
            name = as_text(t.get("term")).strip()
            if name and name not in out:
                out.append(name)
        return out, ""

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
                                     self.queue_args(["-List", "-Status", "pending", "-Json"]),
                                     timeout=300)
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
            # The status row is {slug, state} and nothing else, so carry the identity fields off the
            # state file itself. Without this the extract lane gets a stub with no url and blames the
            # data for it (see state_row). `state` stays the STATUS's value: -Derive above may have
            # moved it, and the file on disk can be the staler of the two.
            row = self.state_row(slug)
            self.record(slug, {"slug": slug, "state": state,
                               "url": row.get("source_url") or row.get("url"),
                               "source_url": row.get("source_url") or row.get("url"),
                               "title": row.get("title"), "protein": row.get("protein")})
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
        # A CONTAINED DEATH IS NOT A CLEAN RUN. Containment keeps the other lanes draining; it must
        # never make the death quiet, or a run that lost a whole lane reads as a run that finished.
        if self.lane_deaths:
            lines.append("")
            lines.append("  LANES THAT DIED (contained - the rest kept draining, but this run is NOT "
                         "a clean bill):")
            for lane, why in sorted(self.lane_deaths.items()):
                lines.append("    %-9s %s" % (lane, why))
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

    async def contained(self, name, coro):
        """One lane, wrapped so its death is ITS death and not the run's.

        THE DEFECT THIS CLOSES, measured 2026-08-24. `run` gathered the lanes bare, so the first lane
        to raise cancelled every sibling. The extract lane hit an unreachable llama-server
        (`127.0.0.1:8080`, connection refused - the server is started by hand and had gone down with
        the previous session) and took the whole run with it, including a PRICER that was mid-session:
        that dispatch has a start line in the lane log and no end line, and nobody ever ruled on its
        terms. A dependency one lane needs is not a verdict on the other six.

        Containment is not swallowing. The lane's exception becomes a FINDING with the traceback's
        last line, which makes the daemon exit non-clean, and the recipes behind it are recorded by
        the drain as STUCK - never rejected, because nobody ruled on them.

        THE CHANNELS STILL CLOSE, and that is the load-bearing half. Every lane closes the channel
        feeding the next one when its own input drains; a lane that dies without closing leaves the
        lane downstream waiting on a channel nobody will ever shut, so the run HANGS instead of
        exiting - B9 wearing a different hat. That is strictly worse than the crash this replaces,
        which is why the close happens in a `finally` and not on the success path."""
        try:
            return await coro
        except asyncio.CancelledError:
            raise
        except Exception as e:                                    # noqa: BLE001
            detail = "%s: %s" % (type(e).__name__, str(e).strip().splitlines()[-1][:300]
                                 if str(e).strip() else "(no message)")
            self.findings.append(
                "LANE DIED: the %s lane raised and was contained - the other lanes kept draining, and "
                "anything waiting on this one is STUCK, not rejected: %s" % (name, detail))
            self.log("lane %s DIED (contained, the run continues): %s" % (name, detail))
            self.lane_deaths[name] = detail
            return None
        finally:
            for ch in self.CLOSES.get(name, ()):                  # or the next lane waits forever
                self.ch[ch].close()

    async def run(self, lanes=None):
        lanes = tuple(lanes or self.LANE_ORDER)
        tasks = []
        for name in self.LANE_ORDER:
            if name in lanes:
                tasks.append(self.contained(name, getattr(self, self.LANE_FN[name])()))
            else:
                for ch in self.CLOSES[name]:
                    self.ch[ch].close()
        # return_exceptions as a BACKSTOP, not as the mechanism: `contained` already catches, so a
        # raise reaching here means the containment itself failed and that must be visible, not fatal.
        for name, res in zip([n for n in self.LANE_ORDER if n in lanes],
                             await asyncio.gather(*tasks, return_exceptions=True)):
            if isinstance(res, BaseException) and not isinstance(res, asyncio.CancelledError):
                self.findings.append("LANE DIED OUTSIDE CONTAINMENT: %s raised %s past its own "
                                     "guard - the guard has a hole in it"
                                     % (name, type(res).__name__))
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


SERVE_PS1 = os.path.join(REPO, "tools", "local-llm", "serve.ps1")


def card_is_owned(now):
    """Is the GPU somebody else's right now? Section 4.4 is the authority, not this function.

    The nightly chain owns 21:30-06:30, and a hunt must be OFF the card before the 07:00 ad pull and
    the 08:00 capture, whose sweeps go blind without it. Returns the owner's name, or None if the
    card is free for a hunt. `now` is passed in rather than read so this is testable."""
    hm = now.hour * 60 + now.minute
    if hm >= 21 * 60 + 30 or hm < 6 * 60 + 30:
        return "the nightly chain (21:30-06:30)"
    if hm >= 6 * 60 + 30:
        # 06:30-07:00 is the changeover: nightly is off, but a hunt started here cannot finish and
        # release the card before the ad pull, so it is not free either.
        if hm < 7 * 60:
            return "the 07:00 ad pull, which this run could not clear in time"
    return None


def ensure_local_model(now=None, start=True, wait_sec=300, log=say):
    """Preflight the local model, and START it if the card is free. Returns (ok, why_not).

    THE DEFECT THIS CLOSES, measured 2026-08-24. The daemon depended on a service it never checked:
    llama-server had been started by hand for an earlier session and went down with it, so the extract
    lane raised `connection refused` and (before containment) took the whole run with it. Every other
    prerequisite in this flow is preflighted - five self-tests, board freshness, digest date, feed
    liveness - and the one the extract lane cannot run a single recipe without was checked by crashing
    on it.

    IT REFUSES RATHER THAN COMPETING FOR THE CARD. Auto-start is not a licence to take the GPU from
    whoever owns it; section 4.4 gives the nightly chain 21:30-06:30 and requires a hunt to be off the
    card before the 07:00 ad pull. Starting a server inside those windows would make the ad pull and
    the capture sweeps go blind, which is a far worse outcome than a hunt that waits."""
    now = now or dt.datetime.now()
    import urllib.request                                        # noqa: PLC0415
    endpoint = os.environ.get("TC_LLM_ENDPOINT", "http://127.0.0.1:8080/v1")
    base = endpoint.rsplit("/v1", 1)[0]

    def healthy():
        try:
            with urllib.request.urlopen(base + "/health", timeout=5) as r:
                return b'"ok"' in r.read()
        except Exception:                                        # noqa: BLE001
            return False

    if healthy():
        return True, ""
    owner = card_is_owned(now)
    if owner:
        return False, ("llama-server is down and the GPU belongs to %s right now. Not starting one - "
                       "competing for the card is how the 07:00 ad pull and the 08:00 capture go "
                       "blind. Start it by hand if you mean to override that." % owner)
    if not start:
        return False, ("llama-server is not answering at %s. Start it with: pwsh %s"
                       % (base, SERVE_PS1))
    if not os.path.isfile(SERVE_PS1):
        return False, "llama-server is down and there is no serve.ps1 at %s to start" % SERVE_PS1
    log("preflight: llama-server is down and the card is free - starting %s" % SERVE_PS1)
    spawned, why = hunt_lib.ps_spawn_detached(SERVE_PS1, ["-Slots", "1"])   # the one marshalling road
    # -Slots 1 OR THE EXTRACT LANE GOES HALF-BLIND. serve.ps1 defaults to 4 slots and splits its
    # context between them: floor(16384/4) = 4096 tokens/slot, under local_extract.RUNG2_MIN_SLOT_CTX
    # (~11,465). A server this preflight started itself would therefore announce RUNG 2 UNAVAILABLE
    # and send every page rung 1 could not settle to the Claude extractor. Measured 2026-08-26 on the
    # hunt-2026-08-26-ten resume, which started its own server and lost rung 2 for the whole run.
    if not spawned:
        return False, "could not launch serve.ps1: %s" % why
    waited = 0
    while waited < wait_sec:
        time.sleep(5)
        waited += 5
        if healthy():
            log("preflight: llama-server answered after %ds" % waited)
            return True, ""
    return False, ("llama-server did not answer within %ds of being started - the model may still be "
                   "loading, or the start failed. Nothing was extracted." % wait_sec)


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
                    help="accept at most N candidates; the decide lane defers the rest rather than "
                         "accepting them, and 0 runs until the backlog runs dry or the WIP limit "
                         "parks the lane")
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
    ap.add_argument("--food-db", dest="food_db", default="",
                    help="a scratch meal-prep\\food-macros-db.json, for a drill. Empty means the "
                         "live one. Same seam as --ledger / --specs / --costed / --pool, and it "
                         "exists because CHANGE M made the daemon a WRITER of this file: a drill "
                         "row in the live DB would be read by every spec build in the estate.")
    # H2 (2026-08-25). The jc1 drill had every seam above engaged, published nothing, and still wrote
    # three LIVE grocery ledgers. These are those three.
    ap.add_argument("--queue", default="",
                    help="a scratch grocery\\ingredient-queue.json, for a drill. Empty means the live "
                         "one. Threaded onto every ingredient-queue.ps1 call the daemon makes AND "
                         "named to the pricer, which holds the -Record/-Verdict/-Promote pen itself.")
    ap.add_argument("--carriage", default="",
                    help="a scratch grocery\\carriage.json, for a drill. Empty means the live one. "
                         "This is where a settled queue verdict is PROMOTED to, and it is read by the "
                         "cost engine and the publish gate, so a drill row in it is a live fact.")
    ap.add_argument("--considered", default="",
                    help="a scratch meal-prep\\db\\considered-dishes.json, for a drill. Empty means "
                         "the live one. It is the estate's dish-rulings memory, so a drill ruling in "
                         "it changes what a later real run treats as prior art.")
    # D1/D2 (PLAN-ingredient-memory-2026-08-25). The two files this build makes the daemon a writer
    # of. --resolutions is the one that matters most: that ledger is STEP 1 of the per-line
    # resolution ladder on every recipe the estate maps, so a drill row in it is an identity every
    # future run will believe.
    ap.add_argument("--events", default="",
                    help="a scratch meal-prep\\db\\ingredient-events.jsonl, for a drill. Empty means "
                         "the live log.")
    ap.add_argument("--resolutions", default="",
                    help="a scratch meal-prep\\db\\ingredient-resolutions.json, for a drill. Empty "
                         "means the live ledger - which map-preresolve consults FIRST on every line "
                         "of every recipe, so a drill row there is not a test artifact.")
    ap.add_argument("--publish", action="store_true",
                    help="publish for real. WITHOUT this the wave lane runs wave-publish -DryRun.")
    ap.add_argument("--no-start-model", dest="no_start_model", action="store_true",
                    help="preflight llama-server but never START one - refuse instead. For when you "
                         "want to own the card yourself.")
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
               specs_dir=a.specs, costed_path=a.costed, pool_path=(a.pool or None),
               food_db_path=a.food_db, queue_path=a.queue, carriage_path=a.carriage,
               considered_path=a.considered, events_path=a.events,
               resolutions_path=a.resolutions)

    async def go():
        ok, err = await d.seed()
        if not ok:
            say("hunt-daemon: CANNOT RUN - %s" % err)
            return hunt_lib.EXIT_CANNOT_RUN
        if a.status:
            say(d.status_report())
            return hunt_lib.EXIT_FINDINGS if d.findings else hunt_lib.EXIT_CLEAN
        # The extract lane cannot run a recipe without the local model, so preflight it BEFORE any
        # agent is dispatched - a run that spends on decide and map and then dies at extract has
        # bought nothing. Only when the extract lane is actually switched on: a --lanes run without
        # it has no business holding the card.
        if "extract" in a.lanes.split(","):
            ok, why = ensure_local_model(start=not a.no_start_model)
            if not ok:
                say("hunt-daemon: CANNOT RUN - %s" % why)
                return hunt_lib.EXIT_CANNOT_RUN
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
