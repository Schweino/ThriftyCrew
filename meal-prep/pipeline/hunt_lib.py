"""
hunt_lib.py - the ONE module holding v3's dispatch schemas and daemon config (section 4.5).

SCOPE TODAY (2026-08-23, phase 1). This file was created by D5 because the DECIDE schema had to live
somewhere normative the moment the decider started returning verdicts instead of running shell, and
section 4.5 names exactly one home for it. D9 PORTS hunt-lib.js's pure functions into this same
module under section 4.2's parity gate - planTrim, chooseScope, repairClaimHolds, the channel
semantics, the B5-B11 fixtures - against shared test vectors. Nothing in this file may be re-derived
from prose when that happens: eleven of twelve orchestrator defects came from exactly that, and
SKILL.md forbids it. Add to this file; do not reinvent hunt-lib.js inside it.

WHY THE SCHEMAS ARE DATA AND NOT PROSE IN A PROMPT. A stage contract stated in an agent's dispatch
text is a request. A schema the harness enforces is a contract - and the one delta v3 makes to the
inherited set exists because of a dated defect: the decider used to be told, in prose, to run
`considered-dishes.ps1 -Record` for every candidate it ruled on. When it did not, the ruling was lost
and the next run re-sourced the same dish. In v3 the ruling comes back INSIDE the verdict, as
`record`, and the orchestrator performs the write. A field the schema requires cannot be forgotten.

EXIT-CODE CONVENTION for every new v3 battery / pre-resolve script (section 4.5). This DIFFERS from
lib\\guard-contract.ps1's older vocabulary (0/1/2 hard/3 could-not-evaluate) and from the existing
audit-*.ps1 scripts (2 = self-test failure), and the difference is deliberate: one convention for
every new surface, so a caller never has to know which script it is talking to. Do not "fix" a new
battery back to the old numbering.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

EXIT_CLEAN = 0          # ran, nothing to report
EXIT_FINDINGS = 1       # ran, has findings - the machine report is STILL written
EXIT_CANNOT_RUN = 2     # missing input, parse failure, a dependency that is down.
#                         BLOCKED, never a pass. Could-not-look is never a clean bill.

# ---------------------------------------------------------------------------------------------------
# DECIDE - section 4.5, verbatim. Replaces hunt-orchestrator.js's SEL.
#
# The two named deltas from the inherited baseline, and only these:
#   * SEL -> DECIDE. SEL returned `selected: [candidate objects]` and left the ledger write to prose
#     instructions. DECIDE returns a verdict for EVERY candidate dispatched - including the rejections,
#     which are the ones that repeat - and carries the considered-dishes row inside it.
#   * WRITE drops its macro fields (the band is settled pre-write in S6). Ported by D8.
#
# `record` is what the orchestrator writes to considered-dishes VERBATIM. The decider remains the sole
# AUTHOR of acceptances and rulings; what changes is who holds the pen (section S2).
# ---------------------------------------------------------------------------------------------------
DECIDE_VERDICTS = ("accepted", "rejected-dupe", "rejected-not-fit", "deferred")

# THE RECORD BLOCK'S ENUMS ARE CLOSED, and they are checked HERE rather than asked for in the prompt.
# Measured 2026-08-23 on the phase-1 gate run: a decider whose prompt named the closed method enum in
# as many words returned `soup/stew`, `skillet+salad`, `no-cook`, `skillet+assemble` and `grill`, and
# proteins `turkey/beef`, `sausage/chorizo`, `salami/cheese` and `egg`. Every one of those goes
# VERBATIM into considered-dishes, where Get-DishKey builds the dish identity out of
# protein|method|sauce-family - so a free-text method does not just look untidy, it mints an identity
# nothing will ever match again, and the ledger silently stops recognising its own entries.
#
# The protein list is normative here. The METHOD list is NOT: it is read from the ledger's own -Method
# values at call time (harvest.load_methods), because the ledger owns that vocabulary and this file
# quoting a copy of it is the same forked-taxonomy defect one level up.
DECIDE_PROTEINS = ("chicken", "beef", "pork", "turkey", "sausage", "any")

DECIDE = {
    "type": "object",
    "properties": {
        "decisions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "slug": {"type": "string"},
                    "verdict": {"type": "string",
                                "description": "accepted | rejected-dupe | rejected-not-fit | deferred"},
                    "reason": {"type": "string"},
                    "dupe_of": {"type": "array", "items": {"type": "string"}},
                    "record": {
                        "type": "object",
                        "description": "written to considered-dishes verbatim, -By decider",
                        "properties": {
                            "name": {"type": "string"},
                            "protein": {"type": "string"},
                            "method": {"type": "string"},
                            "verdict": {"type": "string"},
                            "reason": {"type": "string"},
                        },
                        "required": ["name", "protein", "method", "verdict", "reason"],
                    },
                },
                "required": ["slug", "verdict", "reason", "record"],
            },
        },
        "note": {"type": "string"},
    },
    "required": ["decisions"],
}

# ---------------------------------------------------------------------------------------------------
# How a DECIDE verdict lands on the run state machine.
#
# NORMATIVE, and it fills a gap section 4.5 left open: hunt-run.ps1's legal graph allows exactly two
# exits from `sourced` (selected, rejected-dupe), while DECIDE has four verdicts. Inventing a state
# for the other two would be a lie in the run report, and forcing them into rejected-dupe would be a
# worse one - "not a fit" is not "a duplicate", and the ledger is read by the next run.
#
#   accepted          -> sourced -> selected            + considered-dishes record + accepted-slugs
#   rejected-dupe     -> sourced -> rejected-dupe       + considered-dishes record
#   rejected-not-fit  -> NO run state (it never entered the run) + considered-dishes record
#                        + the pool ruling. The run's report counts what the run worked on; a
#                        candidate ruled unfit at the door was never work in flight.
#   deferred          -> NO run state, NO ledger record. The pool entry goes back to `available`:
#                        the decider looked and did not decide, and burying a candidate nobody
#                        rejected is how a backlog quietly loses its best entries.
# ---------------------------------------------------------------------------------------------------
DECIDE_STATE_ROUTE = {
    "accepted": ("sourced", "selected"),
    "rejected-dupe": ("sourced", "rejected-dupe"),
    "rejected-not-fit": (None, None),
    "deferred": (None, None),
}

# considered-dishes gets a record for every ruling EXCEPT deferred - there is no ruling to record.
DECIDE_RECORDS_RULING = {"accepted": True, "rejected-dupe": True, "rejected-not-fit": True,
                         "deferred": False}

# ---------------------------------------------------------------------------------------------------
# daemon config (section 4.1a: caps, WIP and budgets are CONFIG, not architecture - with one exception
# that IS architecture and is marked as such)
# ---------------------------------------------------------------------------------------------------
LANE_CAPS = {
    "decide": 1,
    "extract": 3,
    # 2 -> 4 ON 2026-09-04. THE ONLY LEVER HERE THAT TOUCHES NO QUALITY DECISION AT ALL: each mapper
    # call stays byte-identical - same model, same effort, same prompt - and more of them run at once.
    # Generation is serial WITHIN a call and parallel ACROSS calls, and the map lane was 22.6 of the
    # 23.0 covered minutes of hunt-2026-09-04-five. The food DB write is already behind food_db_lock,
    # so the added concurrency cannot race it. Caps now total 17 concurrent slots on a 32-core box.
    #
    # AND THE 'global min(16, cpus-2) = 16' THE COMMENT BELOW CITES IS NOT ENFORCED ANYWHERE -
    # checked 2026-09-04: no semaphore, no cpu_count, no limiter of any kind in the daemon, the
    # lib or the dispatcher. It is an aspiration someone wrote down, and its arithmetic was
    # already stale (it says the caps totalled 13; they totalled 15). Recorded rather than
    # quietly relied on: raising a cap here raises real concurrency with nothing above it to
    # catch an over-subscription, so the next cap change should measure the box, not the ceiling.
    "map": 4,
    "price": 1,      # ARCHITECTURE, not config. The price lane stays a singleton, full stop.
    # 5 as of 2026-08-24, raised from 3 by Brad against a measurement rather than a hunch. WRITE IS
    # THE BOTTLENECK LANE: measured 5.0 min per recipe per writer, so at cap 3 the whole pipeline's
    # steady-state ceiling was 1.67 min/recipe - the slowest lane sets throughput, and every other
    # lane was faster (map 1.39, price 1.19, audit 1.04, qa 0.50). At 5 it is 1.00 and MAP becomes
    # the binding lane at 1.39. Raising it further buys nothing until map moves.
    #
    # There is room: these caps now total 13 of the global min(16, cpus-2) = 16 on this 32-core box.
    # Nothing about quality changes - each writer still takes ONE recipe and writes prose over a
    # machine-built skeleton; this only allows more of them to be in flight at once.
    "write": 5,
    "qa": 2,
    "wave": 1,       # serial
}
WIP_LIMIT = 25             # accepted-but-unresolved recipes; gates pool pops as it gated sourcing
DECIDE_BATCH = 10          # section S2: one decider call per <=10 candidates. A CAP, not a quota.


def validate_decide(payload, methods=None, proteins=DECIDE_PROTEINS):
    """Validate a DECIDE payload. Returns a list of problems; empty means it conforms.

    `methods` is the ledger's closed method enum plus 'any'; pass None to skip that check (used by
    the pure-schema fixtures). `proteins` defaults to the normative list above.

    Deliberately hand-rolled and total: it reports EVERY problem rather than raising on the first, so
    a malformed verdict produces one actionable message instead of a game of whack-a-mole across
    re-asks. A payload that does not conform is could-not-run (exit 2) at the caller, never a partial
    apply - half a verdict written is worse than none, because the half that landed looks decided.
    """
    problems = []
    if not isinstance(payload, dict):
        return ["the verdict is not an object"]
    decisions = payload.get("decisions")
    if not isinstance(decisions, list):
        return ["the verdict has no `decisions` array"]
    if not decisions:
        problems.append("`decisions` is empty - a dispatch that ruled on nothing is not a verdict")
    seen = set()
    for i, d in enumerate(decisions):
        where = "decisions[%d]" % i
        if not isinstance(d, dict):
            problems.append("%s is not an object" % where)
            continue
        slug = d.get("slug")
        if not slug or not isinstance(slug, str):
            problems.append("%s has no slug" % where)
        elif slug in seen:
            problems.append("%s rules on %s twice - which ruling is the ruling?" % (where, slug))
        else:
            seen.add(slug)
        v = d.get("verdict")
        if v not in DECIDE_VERDICTS:
            problems.append("%s verdict %r is not one of %s" % (where, v, ", ".join(DECIDE_VERDICTS)))
        if not d.get("reason"):
            problems.append("%s has no reason - an unexplained ruling teaches the next run nothing"
                            % where)
        if v == "deferred":
            continue                      # a deferral records nothing, so it needs no record block
        rec = d.get("record")
        if not isinstance(rec, dict):
            problems.append("%s has no `record` block, so its ruling cannot reach considered-dishes "
                            "- which is exactly how 44 rejections were lost on 2026-08-15" % where)
            continue
        for k in ("name", "protein", "method", "verdict", "reason"):
            if not rec.get(k):
                problems.append("%s record is missing %s" % (where, k))
        if rec.get("verdict") and v and rec["verdict"] != v:
            problems.append("%s rules %r but records %r - the ledger and the run would disagree "
                            "forever" % (where, v, rec["verdict"]))
        if proteins and rec.get("protein") and rec["protein"] not in proteins:
            problems.append("%s records protein %r, which is not in the closed enum (%s). "
                            "considered-dishes keys dish identity on it; a new value mints an "
                            "identity nothing will match again"
                            % (where, rec["protein"], ", ".join(proteins)))
        if methods and rec.get("method") and rec["method"] not in methods:
            problems.append("%s records method %r, which is not one of the ledger's recorded methods "
                            "(%s). Do not invent a taxonomy"
                            % (where, rec["method"], ", ".join(sorted(methods))))
    return problems


# ---------------------------------------------------------------------------------------------------
# THE MARSHALLING ROAD (measured 2026-08-23, during D5's drill; this is a CORRECTION to section 4.1a)
#
# `powershell -File script.ps1 -DupeOf a b` binds ONE element and silently drops the rest.
# `powershell -File script.ps1 -DupeOf a,b` binds ONE element whose value is the string "a,b".
# Measured on PS 5.1, both shapes, against a [string[]] parameter. So `-File` STRUCTURALLY CANNOT
# carry a multi-element string array from a subprocess argv - it can only produce the B8 composite
# string that parked recipes forever, or a silent truncation, which is worse.
#
# Section 4.1a says agent-side marshalling bugs "become impossible rather than warned against" once
# the daemon holds the pen. That is TRUE, and this function is the reason it is true: the daemon must
# marshal through `-Command` with every element quoted individually, which produces a REAL PowerShell
# array. Handing a JSON array to `-File` would re-create B8 with a Python accent.
#
# `; exit $LASTEXITCODE` is not decoration: without it powershell.exe reports its OWN success, and the
# 0/1/2 convention above would read every script as clean.
# ---------------------------------------------------------------------------------------------------

def ps_quote(v):
    """One PowerShell single-quoted literal. Doubling is the only escape a single-quoted PS string has,
    which is why single quotes are used: nothing inside them expands, so a `$` or a backtick in a
    decider's reason cannot become code."""
    return "'" + str(v).replace("'", "''") + "'"


def ps_arg(v):
    """A scalar, or a real PS array from a Python list. An EMPTY list emits @() rather than nothing,
    so a parameter that was passed stays passed - `-DupeOf` with no value would otherwise swallow the
    next flag as its argument."""
    if isinstance(v, (list, tuple)):
        if not v:
            return "@()"
        return ",".join(ps_quote(x) for x in v)
    return ps_quote(v)


def ps_invoke(script, args, timeout=180):
    """Call a PowerShell surface the way the daemon must. Returns (rc, stdout, stderr).

    `args` is a flat list where a switch/flag is a plain string starting with '-' and everything else
    is a value; a LIST value becomes a real PS array. One road, so no caller has to remember which
    invocation form carries an array and which quietly mangles it.
    """
    parts = ["&", ps_quote(script)]
    for a in args:
        if isinstance(a, str) and a.startswith("-") and " " not in a and not a[1:2].isdigit():
            parts.append(a)          # a parameter NAME is code, not data
        else:
            parts.append(ps_arg(a))
    cmd = " ".join(parts) + "; exit $LASTEXITCODE"
    try:
        p = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", cmd],
                           capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return EXIT_CANNOT_RUN, "", "timed out after %ss" % timeout
    return (p.returncode,
            (p.stdout or b"").decode("utf-8", errors="replace"),
            (p.stderr or b"").decode("utf-8", errors="replace"))


def git_invoke(args, cwd=None, timeout=60):
    """Call git. Returns (rc, stdout, stderr).

    ONE ROAD PER TOOL, for the reason ps_invoke and py_invoke each exist: the alternative is a third
    subprocess style growing inside the daemon where no fixture can reach it. The post-publish review
    dossier needs exactly two facts from git - the sha before the publish and the sha after - and the
    estate has already been bitten by a seam a neuter could not reach (`qa_battery_args`, 2026-08-25:
    reverting it to the live path produced ZERO red on a full roster).

    argv goes straight through, so there is no marshalling hazard here and none is invented. A git
    that cannot run is a could-not-run, never a fabricated sha: the caller gets rc and decides, and
    the dossier says the range is unavailable rather than printing a range that is a guess.
    """
    try:
        p = subprocess.run(["git"] + [str(a) for a in args], capture_output=True, timeout=timeout,
                           cwd=cwd or None)
    except (subprocess.TimeoutExpired, OSError) as e:                 # noqa: BLE001
        return EXIT_CANNOT_RUN, "", "git could not run: %s" % e
    return (p.returncode,
            (p.stdout or b"").decode("utf-8", errors="replace"),
            (p.stderr or b"").decode("utf-8", errors="replace"))


def triage_ids(doc):
    """The triage queue's item ids, as a SET. Pure, so the shape is pinned without a queue on disk.

    The reviewer's contract includes "alert-triage queue empty of NEW items caused by this work", and
    NEW is the whole difficulty: after the publish there is no way to tell a pre-existing item from
    one this run caused. So the daemon snapshots the ids BEFORE the publish and the reviewer diffs.
    A queue that cannot be read returns the empty set and the dossier SAYS it could not be read -
    an unreadable queue must never render as "nothing was pending", which would make every
    pre-existing item look new.
    """
    if not isinstance(doc, dict):
        return set()
    out = set()
    for it in (doc.get("items") or []):
        if isinstance(it, dict) and it.get("id") is not None:
            out.add(str(it["id"]))
    return out


def db_slugs(doc):
    """Every slug in recipes-db, as a SET. Pure, same reason as triage_ids.

    Used for the row-count-moved-implausibly check (the reviewer's category 2): the daemon holds the
    count before and after, and the reviewer is handed both plus the wave's own slugs. It is a COUNT
    and a set of identities - never the row CONTENTS, because the numbers on the page are what the
    reviewer must verify against the artifact itself.
    """
    if not isinstance(doc, dict):
        return set()
    return set(str(r.get("slug")) for r in (doc.get("recipes") or [])
               if isinstance(r, dict) and r.get("slug") is not None)


def ps_spawn_detached(script, args=None):
    """Start a long-running PowerShell script and DO NOT wait for it. Returns (ok, why_not).

    The sibling of ps_invoke, and it lives here for the same reason ps_invoke does: the daemon's
    `_one_marshalling_road` fixture greps hunt-daemon.py for hand-built PowerShell command lines, so
    there is exactly ONE module that knows how to marshal a call. That guard caught this function
    being written inline in the daemon on 2026-08-24 and it was right to - the answer is to put the
    second invocation style next to the first, not to exempt the daemon from its own rule.

    SEPARATE FROM ps_invoke BECAUSE WAITING IS THE DIFFERENCE. ps_invoke runs a script to completion
    and reads its output; this starts a SERVER, which by definition never completes, and whose output
    must not be piped into a buffer nobody drains. The only caller today is the llama-server
    preflight.

    ARGS ARE SCALARS ONLY, and that is not a limitation worth removing. `-File` cannot bind a
    multi-element [string[]] from argv at all - that is the B8 class, frozen in decide_apply.py's
    selftest - so anything needing a real array must use ps_invoke instead. The one caller passes
    `-Slots 1`, an [int], which binds fine. Measured 2026-08-26: without it serve.ps1 took its own
    default of 4 slots, floor(16384/4) = 4096 tokens per slot, and the extract lane announced
    RUNG 2 UNAVAILABLE (it needs ~11,465) - so every page rung 1 could not settle escalated to the
    Claude extractor instead of the local model, at width."""
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script]
    for a in (args or []):
        cmd.append(str(a))
    try:
        subprocess.Popen(cmd,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         stdin=subprocess.DEVNULL)
    except Exception as e:                                       # noqa: BLE001
        return False, str(e)
    return True, ""


def py_invoke(script, args, timeout=600, exe=""):
    """Call a PYTHON surface. Returns (rc, stdout, stderr).

    ONE ROAD PER LANGUAGE, and this is the Python one. ps_invoke exists because `-File` cannot carry
    a multi-element array; this exists for a different hazard with the same shape - a Python surface
    must be run by THIS interpreter, `sys.executable`. Bare `python` on this box is the Windows Store
    shim, which exits 49 without running anything, and a daemon that shelled it would report a
    could-not-run for a script that is perfectly fine. argv carries strings straight through, so
    there is no marshalling problem here and none is invented: a list argument would be a defect in
    the CALLER, which is why every element is stringified rather than joined.

    `exe` NAMES A DIFFERENT INTERPRETER, and it exists because this estate has THREE and they are
    not interchangeable (2026-08-25, PLAN-ingredient-memory D3). meal-prep\\pipeline runs under
    C:\\Codex\\Python312; anything importing numpy or torch runs under sidecar\\.venv and nothing
    else; the graph's interpreter has no numpy at all. `resolution_embed.py` is a meal-prep surface
    that needs the SIDECAR one, so the choice belongs at the call site - but it stays on this ONE
    road, because the alternative is a second subprocess style growing in the daemon, which is
    exactly what ps_invoke exists to prevent on the other side of the fence. A named exe that does
    not exist is a could-not-run naming the path, never a fallback to whatever is on PATH: falling
    back would run the wrong environment and report its ImportError as this script's failure.
    """
    if exe and not os.path.exists(exe):
        return EXIT_CANNOT_RUN, "", "no interpreter at %s" % exe
    cmd = [exe or sys.executable, script] + [str(a) for a in args]
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return EXIT_CANNOT_RUN, "", "timed out after %ss" % timeout
    return (p.returncode,
            (p.stdout or b"").decode("utf-8", errors="replace"),
            (p.stderr or b"").decode("utf-8", errors="replace"))


# =====================================================================================================
# THE PORT OF hunt-lib.js (D9, section 4.2's parity gate).
#
# Every function below is a DECISION-FOR-DECISION port of meal-prep\pipeline\hunt-lib.js. It is not a
# re-derivation from the plan's prose, and it must never become one: eleven of the twelve orchestrator
# defects of 2026-08-15/16 came from re-deriving this logic from prose, and each one is a fixture here
# and in hunt-lib.js at the same time.
#
# THE PARITY GATE. The fixtures are not written twice. They live as SHARED TEST VECTORS in
# `hunt-lib-vectors.json`, and both implementations run the same file:
#     C:\Codex\Python312\python.exe hunt_lib.py --parity        (this module)
#     hunt-lib-parity.js, a zero-agent Workflow run              (hunt-lib.js, evaluated from source)
# A vector that passes here and fails there is a port defect, which is the only thing the gate is
# looking for. The daemon may not dispatch a single agent until both sides are green.
#
# The defect each block freezes (from hunt-lib.js's own header):
#   B5  a null agent result treated as an explicit rejection        -> 14 false rejections
#   B6  retry budgets keyed by batch SHAPE, so they never saturated -> 657 failed calls, zero progress
#   B7  "pass" compared against 'PASS'                              -> 12 real passes read as failures
#   B8  -Terms 'a,b' bound as ONE composite string                  -> recipes parked forever
#   B9  WIP limit + closed lanes = unwakeable producers             -> a run that hangs instead of exits
#   B10 a double NO-GO stranded 10 recipes in `waved`               -> 2 clean recipes held hostage
#   B11 a repair agent's claim believed without checking the files  -> a re-audit paid for nothing
# =====================================================================================================

import asyncio
import re

# ---------------------------------------------------------------------------------------------------
# VERDICT PARSING (B7). An agent verdict is free text from a model. Compare the FIRST TOKEN, case-
# insensitively, so "pass" / "PASS" / "PASS (with notes)" all read alike - while "NO-GO" can never be
# mistaken for "GO", because its first token is "NO-GO".
# ---------------------------------------------------------------------------------------------------
_TOKEN_SPLIT = re.compile(r"[^A-Z-]+")


def first_token(v):
    parts = [p for p in _TOKEN_SPLIT.split(str("" if v is None else v).strip().upper()) if p]
    return parts[0] if parts else ""


def is_pass(v):
    return first_token(v) == "PASS"


def is_go(v):
    return first_token(v) == "GO"


def is_rejected(v):
    return first_token(v) == "REJECTED"


def norm_state(v):
    return str("" if v is None else v).strip().lower()


# ---------------------------------------------------------------------------------------------------
# TERM MARSHALLING (B8). Ported for parity, and note what it is FOR in Python: the daemon does not
# build shell strings - it marshals through ps_invoke, which is the transport half of the same class
# (see that function's header). `term_has_comma` still earns its place as a pre-flight predicate, and
# `quote_terms` is kept so the vector file can prove both implementations agree about the quoting rule
# every PowerShell surface in this estate is built around.
# ---------------------------------------------------------------------------------------------------

def quote_terms(terms):
    return ",".join("'" + str(t).replace("'", "''") + "'" for t in (terms or []) if t)


def term_has_comma(t):
    return "," in str("" if t is None else t)


# ---------------------------------------------------------------------------------------------------
# RETRY ACCOUNTING (B6). Budgets are keyed PER SLUG, never per batch shape. The map lane pulls a new
# slug combination each cycle, so a shape-keyed budget minted a fresh allowance every time and never
# saturated - 657 failed calls against a session limit that only a clock could clear.
# ---------------------------------------------------------------------------------------------------
MAX_STAGE_RETRIES = 2


def bump_retries(counts, slugs, stage):
    lst = [s for s in (slugs if isinstance(slugs, (list, tuple)) else [slugs]) if s]
    worst = 0
    for s in lst:
        key = "%s:%s" % (stage, s)
        n = counts.get(key, 0) + 1
        counts[key] = n
        if n > worst:
            worst = n
    return worst


# ---------------------------------------------------------------------------------------------------
# CIRCUIT BREAKER (B6). A failed dispatch returns None - the daemon never sees the error text - so the
# breaker matches on SHAPE: consecutive failures run-wide, any success resetting the count. Isolated
# flakiness never trips it; a hard wall trips it almost immediately.
# ---------------------------------------------------------------------------------------------------
CIRCUIT_THRESHOLD = 5
MAX_AGENT_CALLS = 900     # a run-wide ceiling that stops a runaway loop; ported from the workflow


class Breaker(object):
    def __init__(self, threshold=CIRCUIT_THRESHOLD, max_calls=MAX_AGENT_CALLS):
        self.threshold = threshold
        self.max_calls = max_calls
        self._consecutive = 0
        self.calls = 0
        self.open = False
        self.reason = ""

    def count_call(self):
        self.calls += 1

    def note(self, ok):
        if ok:
            self._consecutive = 0
            return
        self._consecutive += 1
        if self._consecutive >= self.threshold and not self.open:
            self.open = True
            self.reason = ("%d consecutive agent failures run-wide - a systemic wall, not per-recipe "
                           "flakiness" % self._consecutive)

    def check_budget(self):
        if not self.open and self.calls >= self.max_calls:
            self.open = True
            self.reason = "agent call budget reached (%d/%d)" % (self.calls, self.max_calls)
        return self.open

    def trip(self, r):
        if not self.open:
            self.open = True
            self.reason = r


def make_breaker(threshold=CIRCUIT_THRESHOLD, max_calls=MAX_AGENT_CALLS):
    return Breaker(threshold, max_calls)


# ---------------------------------------------------------------------------------------------------
# WAVE TRIM (B10). Plan section S8: on NO-GO the blocking slugs LEAVE the wave - to one repair, or to
# rejected-audit - and the trimmed manifest re-audits. Without this, a double NO-GO left all ten
# recipes in `waved`, a state whose only exits are published / rejected-audit / qa-passed / written,
# and nothing ever picked them up again. Two audit-clean recipes sat hostage to eight blocked ones.
# ---------------------------------------------------------------------------------------------------

def plan_trim(wave_slugs, per_slug, already_repaired, blocker_kind=""):
    blocked, clean = [], []
    for s in wave_slugs:
        v = (per_slug or {}).get(s)
        if v and str(v).upper().startswith("BLOCK"):
            blocked.append(s)
        else:
            clean.append(s)
        # A SHARED-DATA BLOCKER IS NOT THIS RECIPE'S DEFECT, AND MUST NOT SPEND ITS ONE REPAIR
        # (2026-08-28). Measured on wave 11 of hunt-2026-08-27-highprotein: honey-bbq-chicken-mac-
        # and-cheese was made TERMINAL with zero open defects of its own. Its three blockers were one
        # recipe-local (a doubled gram token, fixed and verified) and two shared-data - a gate red
        # over three PHANTOM specs in three OTHER recipes, and cheddar-cheese priced by mozzarella,
        # a board-wide defect owned by the pricer. Neither was anything its owner could fix, and
        # neither said a word about the recipe; both were closed hours later by other work. The
        # budget had already been spent, `rejected-audit` is not a key in hunt-run's transition
        # table, and the recipe was unrecoverable.
        #
        # THE INFORMATION WAS ALREADY WRITTEN DOWN. Every audit labels its blockers
        # `(shared-data, owner: X)` or `(recipe-local, owner: X)`, and choose_scope right below this
        # already branches on exactly that field to decide re-audit scope. Nothing read it here.
        #
        # DEFAULTS TO THE OLD BEHAVIOUR. An absent or unknown kind spends the budget exactly as
        # before, so every existing vector stays green and no caller has to be updated to keep the
        # rule it already had.
        shared = str(blocker_kind or "").strip().lower() == "shared-data"
        terminal = bool(already_repaired) and not shared
    return {
        "clean": clean,
        "blocked": blocked,
        # A slug that has already had its one repair cycle is terminal; anything else goes back.
        "toReject": blocked if terminal else [],
        "toRepair": [] if terminal else blocked,
        # Publishing the clean remainder is the whole point: never hold good recipes for bad neighbours.
        "canPublishClean": len(clean) > 0,
    }


# ---------------------------------------------------------------------------------------------------
# RE-AUDIT SCOPE (v2.1 B2, and the B-4 gate). Recipe-local blockers re-audit ONLY the repaired slugs;
# shared-data blockers REQUIRE the whole wave, because the fix moved every recipe's numbers. Declaring
# the scope is mandatory; defaulting to whole-wave is what made the 2026-08-15 shakedown spend 31% of
# its tokens on three audits.
# ---------------------------------------------------------------------------------------------------

def choose_scope(blocker_kind, repaired_slugs):
    if blocker_kind == "shared-data" or not repaired_slugs:
        return {"scope": "whole-wave",
                "why": "the fix moved shared data, so every recipe in the wave has new numbers"}
    return {"scope": ",".join(repaired_slugs),
            "why": "the blocker was recipe-local, so nothing outside the repaired slugs moved"}


def scope_is_legal(scope, blocker_kind):
    if blocker_kind == "shared-data":
        return scope == "whole-wave"
    return True


# ---------------------------------------------------------------------------------------------------
# POSTCONDITIONS (B11). A repair agent reported success having changed nothing; the only thing that
# caught it was paying for a second full audit. Verify the claim BEFORE paying for the next stage.
# "Nothing needed changing" is a legitimate answer and is treated differently from "I changed X" with
# X untouched.
# ---------------------------------------------------------------------------------------------------

def repair_claim_holds(claimed_changed, mtimes_before, mtimes_after):
    if not claimed_changed:
        return {"ok": True, "reason": "no change claimed"}
    untouched = [f for f in claimed_changed
                 if (mtimes_after or {}).get(f, 0) <= (mtimes_before or {}).get(f, 0)]
    if not untouched:
        return {"ok": True, "reason": "every claimed file changed"}
    return {"ok": False, "reason": "claimed to change but did not: " + ", ".join(untouched),
            "untouched": untouched}


# ---------------------------------------------------------------------------------------------------
# MACRO BAND. A band has a ceiling as well as a floor: a recipe computing to 660 fails exactly like one
# computing to 390. Recipes are never adjusted to fit - that would make the card a false claim.
# ---------------------------------------------------------------------------------------------------

def first_guard_line(out, err):
    """The sentence a refusing PowerShell guard actually wanted the caller to read.

    build-v2-spec and its siblings `throw`, so the useful line is the first one naming the guard, and
    PowerShell then wraps it in six lines of ErrorRecord noise plus a repeat inside
    FullyQualifiedErrorId. Picking the first line that reads like a verdict keeps a STUCK detail
    readable instead of turning it into a stack trace.
    """
    text = ((out or "") + "\n" + (err or "")).replace("\r", "")
    lines = [ln.strip() for ln in text.split("\n") if ln.strip()]
    for ln in lines:
        if ln.startswith(("At ", "+ ", "~", "CategoryInfo", "FullyQualifiedErrorId")):
            continue
        if ln.startswith("+ Category") or ln.startswith("+ Fully"):
            continue
        return ln[:300]
    return (lines[0][:300] if lines else "no output")


def in_band(cal, carbs, band, protein=None):
    """THE BAND IS A RUN PARAMETER, AND PROTEIN IS PART OF IT (Brad's ruling 2026-08-24, before the
    6b proving run). Calories, carbs and protein all move run to run, so the band arrives as data and
    the predicate reads whatever the run stated rather than a constant somebody has to remember to
    edit. `proteinMin` is OPTIONAL: a band that does not state one has no protein rule, which is what
    keeps every pre-2026-08-24 vector green.

    The cal/carb clauses are evaluated FIRST and their reason strings are unchanged, byte for byte,
    because six parity vectors assert them.
    """
    cal_min, cal_max = band.get("calMin"), band.get("calMax")
    carb_max = band.get("carbMax")
    protein_min = band.get("proteinMin")
    if not _is_number(cal) or not _is_number(carbs):
        return {"ok": True, "reason": "not reported"}
    if cal < cal_min:
        return {"ok": False, "reason": "%s cal below the %s floor" % (_num(cal), _num(cal_min))}
    if cal > cal_max:
        return {"ok": False, "reason": "%s cal above the %s ceiling" % (_num(cal), _num(cal_max))}
    if carbs > carb_max:
        return {"ok": False, "reason": "%sg carbs above the %s limit" % (_num(carbs), _num(carb_max))}
    if _is_number(protein_min):
        # AN ABSENT PROTEIN NUMBER IS NOT A BAND FAILURE, exactly as an absent cal/carb is not: this
        # is a retirement gate, and retiring a good dish on a number nobody read is the mirror of D8's
        # named worse-than-no-gate case. It passes and SAYS SO, so the run can report it. Both live
        # call sites carry protein (the skeleton's macros_per_serving.protein_g, the built spec's
        # stat.protein), so this reason firing at all is itself worth hearing about.
        if not _is_number(protein):
            return {"ok": True, "reason": "protein not reported"}
        if protein < protein_min:
            return {"ok": False, "reason": "%sg protein below the %s floor"
                                           % (_num(protein), _num(protein_min))}
    return {"ok": True, "reason": ""}


def _is_number(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def _num(x):
    """JS prints 500 for 500.0, and the vector file's expected strings are the same strings both
    implementations must produce. Agreeing about the printed form keeps the parity gate firing on
    logic rather than on float formatting."""
    if isinstance(x, float) and x.is_integer():
        return str(int(x))
    return str(x)


# ---------------------------------------------------------------------------------------------------
# CHANNEL (B9). Lanes block on futures, never on timers. close() must wake BOTH takers and
# backpressure-parked producers, or a producer parks forever and the run hangs instead of exiting.
#
# The workflow's version parks on bare promises because its sandbox has no clock. asyncio HAS one, and
# the port deliberately does not reach for it: a timeout here would turn a hang into a slow hang, and
# what B9 froze is precisely "a lane nothing can wake". Same wake discipline, same shape.
# ---------------------------------------------------------------------------------------------------

class Chan(object):
    def __init__(self):
        self._items = []
        self._waiters = []
        self._space_waiters = []
        self._closed = False

    def push(self, x):
        self._items.append(x)
        while self._waiters:
            w = self._waiters.pop(0)
            if not w.done():
                w.set_result(None)
                break

    def close(self):
        self._closed = True
        pending = self._waiters[:] + self._space_waiters[:]
        self._waiters = []
        self._space_waiters = []
        for w in pending:
            if not w.done():
                w.set_result(None)

    def is_closed(self):
        return self._closed

    def size(self):
        return len(self._items)

    def _wake_space(self):
        pending = self._space_waiters[:]
        self._space_waiters = []
        for w in pending:
            if not w.done():
                w.set_result(None)

    async def wait_for_space(self, limit):
        while len(self._items) >= limit and not self._closed:
            fut = asyncio.get_event_loop().create_future()
            self._space_waiters.append(fut)
            await fut

    async def take(self):
        while True:
            if self._items:
                v = self._items.pop(0)
                self._wake_space()
                return v
            if self._closed:
                return None
            fut = asyncio.get_event_loop().create_future()
            self._waiters.append(fut)
            await fut

    async def take_batch(self, n):
        """Blocks ONLY for the first item, then sweeps whatever is already queued. Never waits to fill
        a quota - that is the difference between a buffer and a batch, and getting it wrong (B3) made
        the pipeline take 8-10 minutes to produce its first flowing recipe."""
        first = await self.take()
        if first is None:
            return None
        batch = [first]
        while len(batch) < n and self._items:
            batch.append(self._items.pop(0))
        return batch


def chan():
    return Chan()


# =====================================================================================================
# THE INHERITED DISPATCH SCHEMAS (section 4.5). hunt-orchestrator.js's inline set, moved here VERBATIM
# apart from the two named deltas the plan allows and only those:
#   * SEL -> DECIDE (above).
#   * WRITE drops its macro fields - the band is settled pre-write in S6.
#
# A THIRD DIVERGENCE, AND IT IS BEHAVIOURAL RATHER THAN STRUCTURAL (2026-08-26, Q1/Q2). MAPPED's
# `state` and `absent_terms` DESCRIPTIONS no longer read as hunt-orchestrator.js's do, and that file
# is not stale for keeping the old wording: its map lane still routes on the mapper's own `state`
# and still advances `mapped` -> `priced` (hunt-orchestrator.js ~806), so the old text describes IT
# correctly. The daemon does neither - hunt-run refuses `mapped` -> `priced` as of Q2, and Q1 made
# the RECORDED term union (Daemon.blocking_terms) the authority over what is enqueued rather than
# the mapper's claim. So "VERBATIM" now ends at these two field descriptions: re-syncing them from
# the JS would put stale routing back in front of a live model.
#
# WHAT THE SECOND DELTA COSTS UNTIL D8 LANDS, stated so nobody reads a hole here as a weakened gate.
# The workflow's write lane gated the band on the WRITER'S OWN REPORTED numbers (WRITE carried
# cal_per_serving / carbs_per_serving). Those fields are gone, and D8's build-intake-skeleton.ps1 -
# the pre-write band gate that replaces them - is a phase-4 deliverable. The daemon therefore reads the
# band off the BUILT SPEC (`db\recipes\<slug>.json`'s `stat.cal` / `stat.carbs`) after the write lane
# returns: a mechanical postcondition over the artifact instead of a self-report about it, which is
# strictly the stronger of the two and needs nothing from D8. See hunt-daemon.py's write lane.
# =====================================================================================================

CANDS = {"type": "object", "properties": {
    "round": {"type": "number"},
    "candidates": {"type": "array", "items": {"type": "object", "properties": {
        "name": {"type": "string"}, "slug": {"type": "string"}, "protein": {"type": "string"},
        "cuisine": {"type": "string"}, "source_url": {"type": "string"},
        "source_servings": {"type": "number"}, "src_cal": {"type": "number"},
        "src_carbs": {"type": "number"}, "method": {"type": "string"},
        "unmapped": {"type": "array", "items": {"type": "string"}}, "why": {"type": "string"}},
        "required": ["name", "slug", "source_url", "src_cal", "src_carbs"]}}},
    "required": ["round", "candidates"]}

STAGE = {"type": "object", "properties": {
    "slug": {"type": "string"}, "status": {"type": "string"},
    "state": {"type": "string"}, "detail": {"type": "string"}},
    "required": ["slug", "status", "state"]}

# THE THIRD SCHEMA DELTA, RATIFIED BY BRAD 2026-08-24 (phase 6a, A1 / cold-read pin P2). The "only two
# deltas" rule bends here by his order, and this comment is the dated record.
#
# WHAT CHANGED AND WHY. The mapper no longer writes `<RunDir>\mapped\<slug>.json`; the daemon assembles
# it through `map-preresolve.ps1 -Assemble`. On the phase-5 gate run the mapper wrote that file in the
# PRE-RESOLVE TABLE'S shape and build-intake-skeleton.ps1 exited 1 over a recipe it had just settled
# cleanly - not carelessness, but a prompt that said "unchanged contract" without naming one field.
# With the daemon holding the pen, the wrong shape becomes impossible by construction.
#
# TWO ARRAYS PER SLUG, and the first one is why this is a delta rather than a deletion. Measured against
# hunt-2026-08-15-lowcarb-100\mapped\baked-cauliflower-mac-smoked-sausage.json: EVERY line carries a
# mapper-authored `buy` string ("7 oz, room temperature (an 8 oz brick minus 2 tbsp)") that D8 LOCKS
# into the intake, and locked-means-locked is where the prose-number defect died. A mechanical assembler
# cannot invent those, so the mapper still speaks on every purchasable line - just in a compact array
# rather than a whole file.
#   lines    {raw, buy, notes, grams_source?} for EVERY purchasable line.
#   rulings  {raw, term, canon_item, bid, decision, grams_source, evidence} for the RESIDUAL lines only.
#            `decision` is a CLOSED set - free text produced 21 distinct values across 550 v2 lines.
#
# `grams_source` IS SOURCE BASIS, AND THE NAME IS THE CORRECTION (phase-6a gate drill, 2026-08-24).
# The field was called `grams` and specified as TARGET weight, and the live mapper returned SOURCE
# grams on all ten lines it weighed across two recipes - the ratio was EXACTLY each recipe's own scale
# factor every time ("3 1/2 lb chicken breast" carrying 454 g). That is the only sensible reading of
# its inputs: every gram it is shown is source basis. So every road is source basis now and
# map-preresolve applies the scale exactly once, which is where it always belonged.
# `raw` is the join key on both: it is the extraction's own line, and it is what the pre-resolve table
# is keyed by.
MAPPED_RULING_DECISIONS = ("mapped", "mapped-null", "mapped-optional", "not-purchased", "rejected")

# THE REJECTION STATES A MAPPER MAY NAME - AND THIS IS PROMPT COPY, NOT A GATE (2026-08-26).
#
# WHAT IT IS FOR. The map lane rules on a recipe that is STILL AT `extracted` - the lane's own advance
# to `mapped` sits below its rejection branch - so a mapper rejection may only name a state hunt-run.ps1
# will actually accept from there. This tuple is that set, and its ONE job is to say so IN THE SCHEMA
# DESCRIPTION the mapper reads. Told nothing, a live mapper reaches for the words it actually means -
# "not carried" - and every recipe it rejects becomes a STUCK a person has to clear by hand.
#
# IT IS NOT WHAT ENFORCES ANYTHING, AND THAT DISTINCTION IS LOAD-BEARING. Daemon.settle() is the gate,
# and it holds no copy of $script:NEXT at all: it offers the transition to hunt-run.ps1 and believes the
# answer, so a refusal is a STUCK whatever this tuple happens to say. Nothing routes on this constant.
# If it ever disagrees with hunt-run, the cost is a worse PROMPT - never a wrong verdict - and the Q3
# drift case in hunt_daemon_selftest.py fails the day that happens, because it ASKS the real
# hunt-run.ps1 which rejection states `extracted` accepts rather than reading this line.
#
# `rejected-not-carried` IS DELIBERATELY ABSENT, AND IT WAS THE DAEMON'S DEFAULT UNTIL TODAY. It is a
# CARRIAGE verdict, and since Q2 carriage is DERIVED by hunt-run - Get-CarriageBlockingTerms on the road
# into `pricing`, Get-DerivedPricingState on the way out - never claimed by an agent. Every legitimate
# writer of that state reads it off a derivation over real store answers (hunt-run.ps1 ~198, the
# daemon's reap_priced). Widening `extracted` to accept it instead would let an unevidenced claim mint a
# carriage verdict for a recipe nothing has even mapped - Q2's founding case arriving through a
# different door, which is exactly the door-beside-the-gate that comment refuses.
#
# WHERE A REAL "NOTHING CARRIES THIS" GOES. Into `absent_terms`, not into a rejection. That is the road
# that ends at `rejected-not-carried` legitimately - through `pricing`, with the ingredient queue's
# answer behind it - and it is open to the mapper on every result it returns.
MAPPER_REJECTION_STATES = ("rejected-unreadable", "rejected-dupe", "rejected-macros")

MAPPED = {"type": "object", "properties": {
    "results": {"type": "array", "items": {"type": "object", "properties": {
        "slug": {"type": "string"},
        "status": {"type": "string", "description": "ok | rejected"},
        "state": {"type": "string", "description":
                  "`pricing` when absent_terms is non-empty, `priced` when it is EMPTY - the two "
                  "must agree. On a status=ok result this is ADVISORY: the orchestrator routes on "
                  "the TERMS and only logs a disagreement. On status=rejected this field IS the "
                  "outcome and must name exactly one of: " + " | ".join(MAPPER_REJECTION_STATES) +
                  ". Those are the only verdicts a recipe at `extracted` can be moved to, so a "
                  "rejection naming anything else cannot be recorded and the recipe is held for a "
                  "person instead. An ingredient no Omaha store carries is NOT a rejection here - "
                  "report it in absent_terms and the pricing road rules on it"},
        "absent_terms": {"type": "array", "items": {"type": "string"},
                         "description":
                             "YOUR half of the blocking-term list: the terms the board could not "
                             "answer. NOT the enqueue list - the orchestrator unions it with its "
                             "own carriage derivation (foods that map to a real id but that no "
                             "Omaha store carries), RECORDS that union, and enqueues what it "
                             "recorded. Report every term you found; never trim it to what you "
                             "think needs pricing"},
        "optional_absent": {"type": "array", "items": {"type": "string"}},
        "lines": {"type": "array", "description":
                  "EVERY purchasable line: {raw, buy, notes} plus `grams_source` where you weighed it "
                  "yourself. `raw` is the extraction's own line, copied verbatim - it is the join key",
                  "items": {"type": "object", "properties": {
                      "raw": {"type": "string"}, "buy": {"type": "string"},
                      "notes": {"type": "string"},
                      "grams_source": {"type": "number", "description":
                                       "grams AT THE SOURCE RECIPE'S OWN SCALE, exactly like the "
                                       "table's grams_source_basis. The orchestrator scales it"}},
                      "required": ["raw", "buy"]}},
        "rulings": {"type": "array", "description":
                    "the RESIDUAL lines only - the ones the pre-resolve table could not settle",
                    "items": {"type": "object", "properties": {
                        "raw": {"type": "string"}, "term": {"type": "string"},
                        "canon_item": {"type": "string",
                                       "description": "the food's name. Required even on mapped-null "
                                                      "- no id is fine, no name is not"},
                        "bid": {"type": "string"},
                        "decision": {"type": "string",
                                     "description": "one of: " + " | ".join(MAPPED_RULING_DECISIONS)},
                        "grams_source": {"type": "number", "description":
                                         "grams AT THE SOURCE RECIPE'S OWN SCALE. The orchestrator "
                                         "scales it exactly once"},
                        "evidence": {"type": "string",
                                     "description": "ONE or two sentences naming the decisive fact"}},
                        "required": ["raw", "decision"]}},
        "new_commodity_proposals": {"type": "array", "items": {"type": "object", "properties": {
            "term": {"type": "string"}, "proposed_bid": {"type": "string"},
            "evidence": {"type": "string"}}, "required": ["proposed_bid"]}},
        # THE MAPPER RETURNS ITS FOOD-DB ROWS; THE DAEMON WRITES THE DB (CHANGE M, 2026-08-25).
        # This replaces `db_entries_added`, a names-only array reporting what the mapper CLAIMED to
        # have written with the Edit tool. The 22 turns of a 3-recipe map batch were label
        # acquisition plus Edit/verify round-trips on food-macros-db.json; the daemon now holds that
        # pen too, exactly as 6a moved mapped\<slug>.json, and it Atwater-checks and conflict-checks
        # every row on the way in - neither of which a self-report could ever be.
        "food_db_rows": {"type": "array", "description":
            "Label-accurate food-macros-db rows for foods the table marks as having NO row. The "
            "ORCHESTRATOR writes the DB; you never edit it. Same shape as the DB's own entries.",
            "items": {"type": "object", "properties": {
                "item": {"type": "string"}, "brand": {"type": "string"},
                "serving_grams": {"type": "number"}, "serving_qty": {"type": "number"},
                "serving_unit": {"type": "string"}, "calories": {"type": "number"},
                "protein_g": {"type": "number"}, "carbs_g": {"type": "number"},
                "fat_g": {"type": "number"}, "fiber_g": {"type": "number"},
                "notes": {"type": "string"},
                "source": {"type": "string", "description":
                    "where the label came from: 'fdc:<fdcId>' when chosen off the shelf, else the URL"}},
                "required": ["item", "serving_grams", "calories", "protein_g", "carbs_g", "fat_g"]}},
        # THE OTHER HALF OF food_db_rows, AND THE POSTCONDITION'S ONLY OTHER LEGAL ANSWER
        # (2026-08-26). The prompt has told the mapper since 2026-08-25 to "return NO row for that
        # food and say why in `detail`" when two label reads produce nothing. Measured over run
        # hunt-2026-08-26-ten, it did not: the table named between 1 and 9 rowless foods on all 22
        # recipes, TWELVE returned no row at all, not one recipe returned a row for every food that
        # needed one, and no recipe said why. A rule a model must remember is a rule it sometimes
        # forgets - the same finding that moved the unbid hold out of the map prompt and into the
        # daemon - so the answer moved from prose into a field, where validate_map_food_rows can
        # check that it was given.
        #
        # AND IT IS A FIELD RATHER THAN A SENTENCE FOR ONE MEASURED REASON. The founding payload
        # carried `detail` = "New DB rows returned: Yellow Onion, Apple, Chicken Thighs, Fresh
        # Rosemary" against an EMPTY food_db_rows. The prose is what lied, so the prose cannot be
        # what clears the silence.
        "food_db_absent": {"type": "array", "description":
            "One entry per food the table marks as having NO food-macros-db row that you could NOT "
            "acquire a label for: {item, why}. `item` is the food's name as you would have written "
            "the row's `item`. This does NOT unblock the recipe - the row is still missing and the "
            "skeleton still refuses - it makes the block carry YOUR sentence instead of nothing. A "
            "food that genuinely carries no macros is not an entry here: it is a ROW OF ZEROES in "
            "food_db_rows, which is the label-accurate answer for salt, and it costs the recipe "
            "nothing.",
            "items": {"type": "object", "properties": {
                "item": {"type": "string"},
                "why": {"type": "string", "description":
                        "what you looked at and what was missing, in a sentence a person can act on"}},
                "required": ["item", "why"]}},
        "rejected": {"type": "array", "items": {"type": "string"}},
        "ruled_substitutions": {"type": "array", "items": {"type": "string"}},
        # NO `type` ON THESE THREE, AND IT IS DELIBERATE (phase-6a gate drill, 2026-08-24).
        # A live batch re-asked - a whole second session at the price of the first - over exactly
        # this: "payload.results[0].macro_cross_check should be a string, got dict" and the same for
        # `detail`. The model was right and the schema was wrong. The v2 decision files carry
        # macro_cross_check as an OBJECT ({source_published_per_serving, computed_per_serving,
        # protein_gap_pct, verdict}), which is the better shape for a number-bearing cross-check, and
        # a rich `detail` is a report rather than a sentence. These are report fields nothing branches
        # on, so constraining their shape bought nothing and cost the most expensive recoverable thing
        # in the pipeline. A property with no `type` is not validated for shape - see validate_schema -
        # and the daemon renders whichever arrives.
        "macro_cross_check": {"description": "the cross-check, as prose or as an object"},
        "registrar_rulings": {"description": "free-form; the daemon dispatches the registrar itself"},
        "detail": {"description": "your report for this slug, as prose or as an object"}},
        "required": ["slug", "status", "state"]}}},
    "required": ["results"]}

# A NEW DISPATCH SCHEMA, RATIFIED BY BRAD 2026-08-24 (phase 6a, A4 / cold-read pin P6). Not a delta to
# an inherited stage - the commodity-registrar has never been dispatched by the daemon before.
#
# WHY IT EXISTS. A3 strips the `Agent` tool from the mapper (D11's minimal-tools rule, applied early:
# the phase-5 batch spawned a 21-turn Opus subagent that appears in NO lane stamp, $1.64 of invisible
# spend). But the mapper's own definition orders every new commodity id "through the commodity-registrar
# gate", and that consult rides the Agent tool - frontmatter `tools:` cannot scope WHICH subagents are
# reachable, so stripping Agent severs the road. So the DAEMON dispatches the registrar itself, on the
# proposals the mapper returns, and only an approve or an alias lets the assembler mint the id. A reject
# leaves the line unsettled and the recipe STUCK with the registrar's own sentence attached.
REGISTRAR = {"type": "object", "properties": {
    "verdict": {"type": "string", "description": "approve | reject | alias"},
    "bid": {"type": "string",
            "description": "on approve, the id to mint; on alias, the EXISTING id it resolves to"},
    "reason": {"type": "string",
               "description": "the evidence, in a sentence a person can act on"}},
    "required": ["verdict", "reason"]}

# F2 (2026-08-25): THE REGISTRAR RULES A WHOLE BATCH FROM ONE DOSSIER. Measured on the jc1 drill, one
# dispatch per proposal cost 10 turns and 81,929 raw tokens to rule a single id, each session paying
# its own startup and fixed input over a cold cache. This is the decider's shape - one dossier in, one
# verdict array out - and `proposed_bid` is what every ruling is joined on, which is why it is
# required: a ruling nobody can attribute to a proposal is a ruling that cannot be applied.
#
# The single-item REGISTRAR above STAYS for now, per plan 4.2.3: it is retired only once the drill has
# proven the batch road, and only if nothing else references it.
# THE PRESCRIPTION, SO AN APPROVAL CAN BE EXECUTED (2026-08-28). A ruling used to carry a verdict, an
# id and a sentence - everything a PERSON needs and nothing a script can run. So an approved id sat
# inert until somebody minted it by hand: the daemon calls none of new-commodity.ps1,
# add-recipe-board-rows.ps1 or add-ingredient-row.ps1, and every one of the 156 recipe-board rows
# "arrived by hand" in that file's own words. Seven mints on 2026-08-27 and two more on 08-28 were
# executed by hand off prose, and meanwhile `Reduced Fat Cheddar Cheese` and `Whole Wheat Flour` each
# blocked a finished recipe for a whole day for want of a row nobody had typed.
#
# These are exactly the arguments the three sanctioned tools take. Nothing here decides anything - the
# verdict already did that - it only states the decision in a form that can be carried out.
MINT_SPEC = {"type": "object", "properties": {
    "unit": {"type": "string", "description": "lb | oz | floz | each | dozen | gallon"},
    "include": {"type": "array", "items": {"type": "string"}, "description":
                "regex patterns that must survive CONTIGUOUSLY in real product names"},
    "clone_exclude_from": {"type": "string", "description":
                           "an EXISTING id in the same namespace whose exclude armour this inherits. "
                           "It must not exclude this food's own include - a parent that fences this "
                           "food out cannot be its armour, and new-commodity refuses that outright."},
    "extra_exclude": {"type": "array", "items": {"type": "string"}, "description":
                      "patterns specific to this food, on top of the inherited armour"},
    "band_min": {"type": "number"}, "band_max": {"type": "number"},
    "namespace": {"type": "string", "description": "recipe | weekly"},
    "category": {"type": "string", "description":
                 "the board section this food is sold in, EXACTLY one of the labels in "
                 "grocery\\categories.json. It decides where build-deals-page places the row, and "
                 "there is no sane default - a guess files a cheese under Pasta."},
    "gpu": {"type": "number", "description": "grams in ONE unit of the priced basis"},
    "buy_pkg_g": {"type": "number"}, "buy_pkg_label": {"type": "string"},
    "pantry_pkg_g": {"type": "number", "description":
                     "use INSTEAD of buy_pkg when the package outlives one recipe - a spice jar, a "
                     "flour bag. buy_pkg charges the whole package to the recipe."},
    "pantry_pkg_label": {"type": "string"},
    "companion_edits": {"type": "array", "items": {"type": "string"}, "description":
                        "any EXISTING id whose patterns would fight this one, and what to change - "
                        "prose, for a person. Two ids claiming one product is the defect this "
                        "estate keeps paying for (lasagna-noodles already claimed no-boil; queso "
                        "would have swallowed 'Queso Cotija')."}},
    "required": ["unit", "include", "clone_exclude_from", "namespace", "category"]}

REGISTRAR_BATCH = {"type": "object", "properties": {
    "rulings": {"type": "array", "description":
                "one entry per proposal in the dossier, in any order",
                "items": {"type": "object", "properties": {
                    "proposed_bid": {"type": "string", "description":
                                     "the proposed id EXACTLY as the dossier states it"},
                    "verdict": {"type": "string", "description": "approve | reject | alias"},
                    "bid": {"type": "string", "description":
                            "on approve, the id to mint; on alias, the EXISTING id it resolves to"},
                    "reason": {"type": "string", "description":
                               "the evidence, in a sentence a person can act on"},
                    "mint": MINT_SPEC}, "required": ["proposed_bid", "verdict", "reason"]}}},
    "required": ["rulings"]}

REGISTRAR_VERDICTS = ("approve", "reject", "alias")


def collision_key(bid):
    """Normalise a commodity id far enough that two SPELLINGS of one food collide.

    This exists so registrar rulings can run concurrently. A concurrent ruling checks the estate,
    which is on disk and immutable under a hunt, but it cannot see the other proposals in its own
    batch - so `bread-crumbs` and `breadcrumbs` would each be approved against a clean estate and
    mint the duplicate the gate exists to prevent (that pair really shipped, and carried two
    disagreeing prices while every per-file guard read green).

    Deliberately CRUDE, and deliberately biased toward false positives: separators die, case dies,
    and one trailing plural `s` dies. A false collision costs one extra re-adjudication; a missed
    one costs a duplicate commodity nobody notices for weeks. This is not a duplicate DETECTOR -
    the registrar is - it only decides which pairs must look at each other before being minted."""
    s = "".join(ch for ch in str(bid or "").lower() if ch.isalnum())
    if len(s) > 4 and s.endswith("s"):
        s = s[:-1]
    return s


def validate_registrar(payload):
    """The closed verdict set, checked as the DECIDE enums are - an invented value mints an identity
    nothing downstream will ever match again, and here it would decide whether a commodity is born."""
    problems = []
    v = str((payload or {}).get("verdict") or "").strip().lower()
    if v not in REGISTRAR_VERDICTS:
        problems.append("verdict %r is not one of: %s" % ((payload or {}).get("verdict"),
                                                          ", ".join(REGISTRAR_VERDICTS)))
    if v == "alias" and not str((payload or {}).get("bid") or "").strip():
        problems.append("an `alias` verdict must name the EXISTING id in `bid` - an alias with no "
                        "target is not an alias")
    return problems

def validate_registrar_batch(payload, expected=()):
    """The batch road's validator. Every problem NAMES ITS ITEM, because the dispatch re-ask has to
    tell the model WHICH ruling was malformed - "verdict is not one of" over an eight-item array is a
    re-ask nobody can act on.

    IT IS A WHOLE-PAYLOAD CHECK, the CHANGE W rule arriving here: a batch carrying one bad ruling is
    refused entire and re-asked, never applied in part. Half a batch of approvals is exactly the shape
    where an id gets minted while its sibling's collision is still unruled.

    `expected` is the proposal list the dossier actually asked about. An omission is a problem rather
    than a silent drop: a proposal the registrar could not rule on is a `reject` carrying what would
    settle it, and an id nobody ruled on is refused downstream and stops the recipe.
    """
    rulings = (payload or {}).get("rulings")
    if not isinstance(rulings, list) or not rulings:
        return ["`rulings` must be a non-empty array with one entry per proposal in the dossier"]
    problems, seen = [], set()
    for i, item in enumerate(rulings):
        if not isinstance(item, dict):
            problems.append("ruling %d is not an object" % i)
            continue
        pb = str(item.get("proposed_bid") or "").strip()
        if not pb:
            problems.append("ruling %d names no `proposed_bid` - that field is the key every ruling "
                            "is joined on, so a ruling without it cannot be applied to anything" % i)
        else:
            if pb in seen:
                problems.append("ruling %d rules on '%s' a second time - one verdict per proposal"
                                % (i, pb))
            seen.add(pb)
        for p in validate_registrar(item):
            problems.append("ruling %d (%s): %s" % (i, pb or "unnamed", p))
    missing = [b for b in expected if b not in seen]
    if missing:
        problems.append("no ruling for: %s - every proposal in the dossier needs one, and a proposal "
                        "you cannot rule on is a `reject` carrying what would settle it, never an "
                        "omission" % ", ".join(missing))
    stray = [b for b in sorted(seen) if expected and b not in expected]
    if stray:
        problems.append("ruling(s) for id(s) this dossier did not ask about: %s" % ", ".join(stray))
    return problems


def validate_map_food_rows(payload, debts):
    """THE MAP LANE'S "SILENCE IS NOT CONSENT" POSTCONDITION - the registrar's `expected=` contract,
    arriving at the stage that needed it most.

    `debts` is {slug: [names]}: the foods the pre-resolve table named as having NO food-macros-db row,
    minus the ones this payload's own rulings excuse (not-purchased, rejected) and the ones the
    mapper's ruling maps onto a name the DB already carries. The daemon computes it from THIS payload,
    because a debt depends on how the lines were ruled and nothing knows that until the answer is in.

    WHY IT IS A DISPATCH VALIDATOR AND NOT A FINDING. There already was a finding - food_db_shortfall,
    built the same day - and a finding does not stop a recipe reaching a write lane that will
    certainly refuse it. What a validator buys that a finding cannot is the RE-ASK: the adapter quotes
    every named violation back, so the mapper is told which foods it silently dropped while its
    session still has the table, the shelf and the source page in hand. That is the one moment the
    row can still be acquired for the price of one re-ask instead of a stuck recipe.

    MEASURED, AND THIS IS WHY IT IS MECHANICAL RATHER THAN A BETTER PROMPT. The prompt has ordered
    this since 2026-08-25, in as many words. On run hunt-2026-08-26-ten the mapper returned ZERO rows
    for twelve of twenty-two recipes and gave no reason for any of them, and the run published
    nothing; on the 3-recipe proving run of 2026-08-26, salisbury-steak-burgers died at the write lane
    over 'Kaiser Rolls' and easy-beef-enchiladas over four more.

    TWO LEGAL ANSWERS PER FOOD AND NO THIRD. A row in `food_db_rows`, or an entry in `food_db_absent`
    saying what was looked at and what was missing. A mention in `detail` is NOT one of them: the
    founding payload's `detail` claimed rows it had not returned.

    AN UNKNOWN SLUG IS NOT THIS VALIDATOR'S PROBLEM. The map lane already handles a batch that says
    nothing about a slug (it re-queues, then sticks), and a debt this cannot join is not a violation
    it can name usefully.
    """
    problems = []
    if not isinstance(payload, dict):
        return problems
    for r in (payload.get("results") or []):
        if not isinstance(r, dict):
            continue
        slug = str(r.get("slug") or "").strip()
        need = [n for n in ((debts or {}).get(slug) or []) if n]
        if not need:
            continue
        # A REJECTED RECIPE OWES NOTHING. It is not being built, so no row it lacks can block it, and
        # demanding labels for a dish the mapper just threw out is a re-ask nobody can act on.
        if is_rejected(r.get("status")):
            continue
        answered = set()
        for row in (r.get("food_db_rows") or []):
            if isinstance(row, dict) and str(row.get("item") or "").strip():
                answered.add(str(row["item"]).strip().lower())
        for a in (r.get("food_db_absent") or []):
            if isinstance(a, dict) and str(a.get("item") or "").strip():
                answered.add(str(a["item"]).strip().lower())
        missing = [n for n in need if str(n).strip().lower() not in answered]
        if missing:
            problems.append(
                "%s: the pre-resolve table names %d food(s) with no food-macros-db row and this "
                "payload answers for neither a row nor an absence on %d of them: %s. Every one of "
                "those needs EITHER an entry in `food_db_rows` (a label you read, transcribed as "
                "printed - a food that truly carries no macros is a row of ZEROES, not an omission) "
                "OR an entry in `food_db_absent` as {item, why} naming what you looked at and what "
                "was missing. Silence is not an answer: the write lane refuses this recipe for a "
                "missing row, and a row nobody said was missing is a block nobody can act on."
                % (slug, len(need), len(missing),
                   ", ".join(repr(m) for m in missing[:8])
                   + (" and %d more" % (len(missing) - 8) if len(missing) > 8 else "")))
    return problems


DERIVE = {"type": "object", "properties": {
    "resolved": {"type": "array", "items": {"type": "object", "properties": {
        "slug": {"type": "string"}, "state": {"type": "string"}, "detail": {"type": "string"}},
        "required": ["slug", "state"]}},
    "still_pending_terms": {"type": "array", "items": {"type": "string"}}},
    "required": ["resolved"]}

# The delta: no cal_per_serving / carbs_per_serving / protein_per_serving / cost_per_serving.
#
# CHANGE W (2026-08-25): THE WRITER RETURNS ITS FIELDS AND THE DAEMON PATCHES THE INTAKE. It used to
# Read three files and Edit the intake field by field: 23 turns and 1,169,531 raw tokens for one
# recipe on 6b, plus a whole re-ask class (redrift) policing what construction can simply prevent.
# A writer that never opens the intake cannot drift a locked field.
#
# THE KEYS ARE THE DOTTED NAMES, AS LITERAL JSON KEYS ("prose.intro_html"), so the payload stays flat
# and apply_writer_fields owns the nesting. And the value types are DELIBERATELY LOOSE - the 6a
# lesson pinned above MAPPED's report fields, arriving here: an over-constrained type cost a whole
# session's re-ask when the model was right and the schema was wrong. head.steps and head.step_names
# are the two that must be arrays, and they say so in their descriptions rather than in a `type` this
# validator would refuse a good answer over.
WRITER_FIELDS = ("prose.intro_html", "prose.shop_smart", "prose.make_it", "prose.portion_html",
                 "prose.cost_closing_html", "prose.upsell_html", "cuisine", "head.description",
                 "head.keywords", "head.steps", "head.step_names", "writer_notes",
                 "forbidden_prose_terms")

WRITE = {"type": "object", "properties": {
    "slug": {"type": "string"}, "status": {"type": "string"}, "state": {"type": "string"},
    "detail": {"type": "string"},
    "fields": {"type": "object", "description":
               "your entire deliverable. The dotted names are literal keys: " +
               ", ".join(WRITER_FIELDS) + ". head.steps, head.step_names, writer_notes and "
               "forbidden_prose_terms are ARRAYS of strings; the rest are strings. The ORCHESTRATOR "
               "patches the intake - you have no file to open and none to write."}},
    "required": ["slug", "status", "state"]}


def validate_writer_fields(payload):
    """Any key outside WRITER_FIELDS is an orchestrator-contract violation by the model, and it is
    refused at DISPATCH - the same road validate_registrar takes - so the re-ask quotes the offending
    key back rather than the daemon silently dropping it or, worse, patching it.

    A KEY OUTSIDE THE SET IS NEVER COERCED AWAY. Dropping it would let a writer keep believing it can
    set `macros_per_serving` and let the run keep passing, which is exactly the shape of defect the
    skeleton exists to end. It is also why this refuses the WHOLE payload rather than the key: a
    partial patch is a file half in one contract and half in another.
    """
    problems = []
    fields = (payload or {}).get("fields")
    if fields is None:
        return problems                      # a rejection carries no fields, and that is legal
    if not isinstance(fields, dict):
        return ["`fields` must be an object keyed by the dotted field names, got %s"
                % type(fields).__name__]
    for k in sorted(fields.keys()):
        if k not in WRITER_FIELDS:
            problems.append("`fields` carries %r, which is not writer-fillable. The writable set is "
                            "exactly: %s. Every other field is the skeleton's and is LOCKED."
                            % (k, ", ".join(WRITER_FIELDS)))
    for k in ("head.steps", "head.step_names", "writer_notes", "forbidden_prose_terms"):
        if k in fields and not isinstance(fields[k], list):
            problems.append("`fields[%r]` must be an ARRAY of strings, got %s"
                            % (k, type(fields[k]).__name__))
    return problems


def _ruling_identity(ru):
    """What a ruling actually SETTLES, normalised: (decision, bid, canon_item).

    Two rulings that agree on all three settle the same thing about their line, whatever else
    differs between them (evidence, grams source, wording). That is the test `map_problems` uses to
    tell a line ruled TWICE from a line ruled twice DIFFERENTLY.
    """
    if not isinstance(ru, dict):
        return None
    return (str(ru.get("decision") or "").strip().lower(),
            str(ru.get("bid") or "").strip().lower(),
            str(ru.get("canon_item") or "").strip().lower())


def map_problems(payload):
    """`validate_map`'s three rules, with every problem ATTRIBUTED to the rulings it implicates.

    Returns `(problems, notes)`. Each entry is
    `{"result": int, "slug": str, "rulings": [int], "rule": str, "message": str}`, in the order
    `validate_map` has always printed them.

      - `problems[i]["rulings"]` names the indices into THAT result's `rulings` array that the
        problem condemns. It is EMPTY when the problem condemns the whole result or the whole
        payload (`results` missing, `rulings` not an array): nothing can be salvaged from a shape
        nobody can walk.
      - `notes` are not problems. Today it holds one kind: a raw line ruled twice by rulings that
        settle the SAME identity, collapsed rather than refused (see rule 3 below).

    WHY THE ATTRIBUTION EXISTS, MEASURED. Run hunt-2026-08-26-smoke3, slug
    sheet-pan-meatballs-with-chickpeas-cauliflower-and-butternut: the recipe legitimately lists
    "1 teaspoon cumin" twice (once in the meatballs, once on the vegetables), the mapper ruled both
    lines, and `validate_map` refused the WHOLE payload for it. The pen has no per-ruling verdict to
    fall back on, so learn_apply held all 13 events with "the map result did not validate" - among
    them ten rulings with real bids (cauliflower, butternut-squash, ground-cumin, eggs, fresh-dill,
    fresh-parsley, lemons, bread-crumbs, ground-bison) that had nothing to do with the duplicate.
    Every other recipe that day projected most of its rulings (5 of 8, 9 of 12, 6 of 8, 5 of 5);
    this one projected ZERO. The RULE was right and its BLAST RADIUS was wrong, and PLAN-ingredient-
    memory 3.2 already says what right looks like: every other refusal in the pen is per-ruling with
    its own held_reason.
    """
    problems = []
    notes = []

    def prob(result, slug, rulings, rule, message):
        problems.append({"result": result, "slug": slug, "rulings": list(rulings),
                         "rule": rule, "message": message})

    if not isinstance(payload, dict):
        prob(-1, "", [], "shape", "the map payload is not an object")
        return problems, notes
    results = payload.get("results")
    if not isinstance(results, list):
        prob(-1, "", [], "shape", "the map payload has no `results` array")
        return problems, notes
    if not results:
        prob(-1, "", [], "shape",
             "`results` is empty - a map dispatch that settled nothing is not a result")
    for i, r in enumerate(results):
        if not isinstance(r, dict):
            prob(i, "", [], "shape", "results[%d] is not an object" % i)
            continue
        slug = str(r.get("slug") or "").strip() or "results[%d]" % i
        rulings = r.get("rulings")
        if rulings is not None and not isinstance(rulings, list):
            prob(i, slug, [], "shape", "%s: `rulings` must be an array, got %s"
                 % (slug, type(rulings).__name__))
            continue
        rulings = rulings or []
        seen_raw = {}
        for j, ru in enumerate(rulings):
            where = "%s ruling %d" % (slug, j)
            if not isinstance(ru, dict):
                prob(i, slug, [j], "shape", "%s is not an object" % where)
                continue
            dec = str(ru.get("decision") or "").strip().lower()
            if dec not in MAPPED_RULING_DECISIONS:
                prob(i, slug, [j], "decision",
                     "%s decision %r is not one of %s - a value outside the closed set "
                     "mints an identity nothing downstream will ever match again"
                     % (where, ru.get("decision"), " | ".join(MAPPED_RULING_DECISIONS)))
            if dec in ("mapped", "mapped-optional"):
                if not str(ru.get("bid") or "").strip() and not str(ru.get("canon_item") or "").strip():
                    prob(i, slug, [j], "identity",
                         "%s is %s with neither a `bid` nor a `canon_item` - it settles "
                         "no identity and names no food, so nothing can cost or weigh it"
                         % (where, dec))
            raw = str(ru.get("raw") or "")
            if raw in seen_raw:
                first = seen_raw[raw]
                if _ruling_identity(rulings[first]) == _ruling_identity(ru):
                    # THE SAME RULING WRITTEN TWICE, and the hazard rule 3 names cannot happen here:
                    # whichever of the two the assembler's join keeps, the line is settled the same
                    # way. A recipe that lists one ingredient in two of its components (the smoke3
                    # meatballs: cumin in the mix and cumin on the vegetables) is a real recipe, not
                    # a malformed payload. Collapsed for validation; both still leave EVENTS, because
                    # the pen's postcondition counts one event per ruling.
                    notes.append({"result": i, "slug": slug, "rulings": [first, j],
                                  "rule": "duplicate-raw-agreed",
                                  "message": "%s and ruling %d rule the same raw line (%r) the same "
                                             "way (%s -> %s) - the same ruling written twice, "
                                             "collapsed rather than refused: the assembler's join "
                                             "keeps one of them and the answer it keeps is identical"
                                             % (where, first, raw[:80], dec,
                                                str(ru.get("bid") or "").strip()
                                                or str(ru.get("canon_item") or "").strip()
                                                or "(no identity)")})
                else:
                    # A GENUINE CONFLICT, AND BOTH SIDES ARE IMPLICATED. Nothing here knows which of
                    # the two the assembler's iteration order kept, so neither may become memory.
                    prob(i, slug, [first, j], "duplicate-raw",
                         "%s rules on the same raw line as ruling %d (%r) and rules it DIFFERENTLY "
                         "(%s vs %s) - `raw` is the key the assembler joins rulings to table rows "
                         "on, so one of the two would silently never have happened"
                         % (where, first, raw[:80],
                            _describe_ruling(rulings[first]), _describe_ruling(ru)))
            else:
                seen_raw[raw] = j
    return problems, notes


def _describe_ruling(ru):
    """`decision -> identity`, for a conflict message that says WHAT the two rulings disagree on."""
    ident = _ruling_identity(ru)
    if not ident:
        return "(not a ruling)"
    return "%s -> %s" % (ident[0] or "(no decision)", ident[1] or ident[2] or "(no identity)")


def validate_map(payload):
    """The MAP lane's semantic validator - the one judge that had none (PLAN-ingredient-memory 3.5).

    DECIDE has validate_decide, the REGISTRAR has validate_registrar/_batch, the WRITER has
    validate_writer_fields. The mapper had only the MAPPED json-schema, which checks SHAPE and
    nothing about MEANING: `decision` is typed `string` with the closed set stated only in a
    description, so `"decision": "sure"` conforms. The assembler refuses it one stage later
    (map-preresolve's ASM_RULING_DECISIONS check), which is a park, not a validation.

    WHERE THIS IS CALLED, AND WHERE IT DELIBERATELY IS NOT. It guards the PEN - learn_apply's
    pre-flight - the way validate_decide guards decide_apply's. It is NOT wired into the daemon's
    dispatch path in this build: changing what the daemon ACCEPTS from the mapper would change the
    map lane's routing, which PLAN-map-judge-split reserves (its U1-U4 are not ordered). A payload
    the assembler accepted and this refuses becomes an EVENT-only ruling with a named held_reason,
    never a silent cache row.

    Three rules, and each one is a way a bad row would become a permanent identity:
      1. every ruling's `decision` is in MAPPED_RULING_DECISIONS - free text here produced 21
         distinct values across 550 v2 lines;
      2. a `mapped` / `mapped-optional` ruling with BOTH an empty `bid` and an empty `canon_item`
         is refused - it settles nothing and names no food, so it can neither be cached nor costed;
      3. a `raw` line ruled twice inside ONE slug, BY RULINGS THAT SETTLE IT DIFFERENTLY, is refused
         - `raw` is the join key the assembler matches rulings to table rows on, so two rulings on
         one raw means the assembler picks one of them by iteration order and the other ruling
         silently never happened. Two rulings that settle the line the SAME way are the same ruling
         written twice (a recipe listing cumin in the meatballs and again on the vegetables), and
         `map_problems` collapses them into a note instead: whichever one the join keeps, the answer
         it keeps is identical, so there is nothing here for this rule to protect.

    THE LIST IS FLAT AND THAT IS WHY IT IS NOT THE WHOLE STORY. A caller that must decide what to do
    with EACH ruling - the pen does - calls `map_problems` and reads the ruling indices each problem
    implicates. Refusing a whole recipe's memory over one bad line was this validator's first
    production defect (map_problems' docstring carries the measurement).
    """
    problems, _notes = map_problems(payload)
    return [p["message"] for p in problems]


QA = {"type": "object", "properties": {
    "slug": {"type": "string"}, "verdict": {"type": "string"},
    "owner": {"type": "string"}, "findings": {"type": "string"}},
    "required": ["slug", "verdict"]}

WAVECLOSE = {"type": "object", "properties": {
    "wave": {"type": "number"}, "slugs": {"type": "array", "items": {"type": "string"}},
    "batch": {"type": "string"}},
    "required": ["wave", "slugs"]}

# THE AUDITOR'S FINDINGS ARE STRUCTURED NOW (2026-08-27), and that is what lets the back half of the
# pipeline LEARN. Until this change a wave audit returned a verdict, a list of blocking slugs and a
# prose summary; the findings themselves lived only in waves\wave-<k>.audit.md, were read once by a
# repair cycle, and were never seen again. Four waves of hunt-2026-08-27-highprotein produced 96
# mapper events and ZERO audit events, so the estate learned from the lane that proposes identities
# and heard nothing from the one that overturns them.
#
# The case that named the gap: the mapper ruled `Ground Turkey` -> the GENERIC ground-turkey family
# and that projected into the resolutions cache immediately, as designed. Three lanes later the wave
# auditor proved it wrong - priced as 85/15, macro'd as 93/7, 860 cal as actually shopped - and the
# cache kept the disproved identity because nothing carried the refusal back.
#
# `term` + `bid` + `rejects_mapping` are the three fields that make a finding actionable rather than
# narrative: they are what an invalidation needs to know WHICH cached identity this refutes.
AUDIT_FINDING = {"type": "object", "properties": {
    "slug": {"type": "string"},
    "kind": {"type": "string", "description":
             "short slug for the defect class, e.g. price-class, macro-basis, template-token, "
             "prose-drift, cost-drift, dish-identity"},
    "owner": {"type": "string", "description":
              "which stage must repair it: mapper | writer | pricer | pipeline | shared-data"},
    "blocking": {"type": "boolean", "description": "true if this alone stops the wave publishing"},
    "term": {"type": "string", "description":
             "the ingredient NAME this finding is about, verbatim as the recipe line spells it, when "
             "the finding is about an ingredient at all. Empty otherwise - never guess one."},
    "bid": {"type": "string", "description":
            "the commodity id the finding says is WRONG for that term. Empty unless the finding "
            "really is about an identity."},
    "rejects_mapping": {"type": "boolean", "description":
                        "true ONLY when this finding means the term->bid identity itself is wrong, so "
                        "the cached resolution pointing at `bid` must be thrown away. A price that "
                        "merely moved, a prose defect, or a stale number is NOT a rejected mapping."},
    "why": {"type": "string", "description": "one sentence, the reason, in your own words"}},
    "required": ["slug", "kind", "why"]}

AUDIT = {"type": "object", "properties": {
    "verdict": {"type": "string"},
    "blocking_slugs": {"type": "array", "items": {"type": "string"}},
    "blocker_kind": {"type": "string"}, "owner": {"type": "string"}, "summary": {"type": "string"},
    "findings": {"type": "array", "items": AUDIT_FINDING, "description":
                 "EVERY finding you made, blocking or not, including the ones you re-derived clean "
                 "and the non-blocking notes. A passing check is calibration data too - the same "
                 "reason the band gate logs its passes."}},
    "required": ["verdict"]}

# CHANGE A (2026-08-25): THE RECIPE-LOCAL REPAIR RETURNS THE WRITER'S OWN PAYLOAD SHAPE, so it goes
# through apply_writer_fields and validate_writer_fields unchanged - one patcher, one validator, one
# fillable set. `no_change: true` with a reason is a LEGAL return and feeds the existing
# changed-nothing guard, which now has two independent answers rather than one: the payload says so,
# and the mtimes say so. Belt and braces, because the guard exists precisely because an agent once
# reported a change it had not made.
REPAIRPATCH = {"type": "object", "properties": {
    "slug": {"type": "string"},
    "no_change": {"type": "boolean", "description":
                  "true if nothing needed changing, or if the defect is NOT reachable from the "
                  "fillable fields. Say which in `reason`"},
    "reason": {"type": "string"},
    "fields": {"type": "object", "description":
               "ONLY the fields you are changing, keyed by the literal dotted names: " +
               ", ".join(WRITER_FIELDS)}},
    "required": ["slug"]}


def repair_road(blocker_kind):
    """Which repair road a NO-GO takes. Returns 'patch' or 'agent'.

    AN ABSENT OR UNKNOWN KIND TAKES THE AGENT ROAD, and that is the conservative direction rather
    than a default nobody thought about: a whole-agent repair with tools can fix anything the patch
    road can, and the reverse is not true. A patch road asked to repair a moved cost basis would
    report success over an unrepaired defect.
    """
    return "patch" if str(blocker_kind or "").strip().lower() == "recipe-local" else "agent"


REPAIRCHECK = {"type": "object", "properties": {
    "changed_count": {"type": "number",
                      "description": "how many wave specs are NEWER than the audit file"},
    "changed": {"type": "array", "items": {"type": "string"}},
    "untouched": {"type": "array", "items": {"type": "string"}},
    "detail": {"type": "string"}},
    "required": ["changed_count"]}

PUB = {"type": "object", "properties": {
    "ok": {"type": "boolean"}, "published": {"type": "array", "items": {"type": "string"}},
    "held": {"type": "array", "items": {"type": "string"}},
    "collateral": {"type": "number"}, "refusal": {"type": "string"}},
    "required": ["ok"]}

# The extractor's rung-3 return. It is the section 4.5 extraction contract MINUS the machine-computed
# parts: `extracted_by` and `verification` are the DAEMON's to write (it computes verification with
# local_extract.verify over the cached page, per the D9 pin), never the agent's to assert.
EXTRACT3 = {"type": "object", "properties": {
    "state": {"type": "string", "description": "ok | unreadable"},
    "reason": {"type": "string"}, "title": {"type": "string"}, "source_url": {"type": "string"},
    "servings": {}, "time_total": {}, "time_active": {},
    "ingredients": {"type": "array", "items": {"type": "object", "properties": {
        "raw": {"type": "string"}, "item": {"type": "string"}, "qty": {}, "unit": {},
        "prep": {}, "optional": {"type": "boolean"}, "section": {}},
        "required": ["raw", "item"]}},
    "instructions": {"type": "array", "items": {"type": "string"}},
    "concerns": {"type": "array", "items": {"type": "string"}}},
    "required": ["state", "ingredients", "instructions"]}


# =====================================================================================================
# A TOTAL, HAND-ROLLED SCHEMA CHECK - the same shape and the same reason as validate_decide.
#
# It reports EVERY problem instead of raising on the first, because section 4.1a allows the daemon
# exactly ONE re-ask and that re-ask has to quote every named violation back. A validator that stops at
# the first problem turns one re-ask into a game of whack-a-mole the budget does not have.
#
# It is deliberately a SUBSET of JSON Schema: type, properties, required, array items, and enum. That
# is the whole vocabulary the inherited schemas use. An unrecognised keyword is IGNORED rather than
# guessed at - a validator that invents a rule the schema did not state would refuse honest payloads.
# =====================================================================================================

_TYPES = {"object": dict, "array": list, "string": str, "number": (int, float), "boolean": bool}


def validate_schema(payload, schema, where="payload"):
    problems = []
    if not isinstance(schema, dict) or not schema:
        return problems
    t = schema.get("type")
    if t:
        py = _TYPES.get(t)
        ok = isinstance(payload, py) if py else True
        if t == "number" and isinstance(payload, bool):
            ok = False           # a bool is an int in Python and is NOT a number here
        if t == "boolean" and not isinstance(payload, bool):
            ok = False
        if not ok:
            problems.append("%s should be a %s, got %s" % (where, t, type(payload).__name__))
            return problems
    if "enum" in schema and payload not in schema["enum"]:
        problems.append("%s is %r, which is not one of the closed enum (%s)"
                        % (where, payload, ", ".join(str(x) for x in schema["enum"])))
    if isinstance(payload, dict):
        for k in schema.get("required") or []:
            if k not in payload or payload[k] is None:
                problems.append("%s is missing required field `%s`" % (where, k))
        for k, sub in (schema.get("properties") or {}).items():
            if k in payload and payload[k] is not None:
                problems.extend(validate_schema(payload[k], sub, "%s.%s" % (where, k)))
    elif isinstance(payload, list):
        item = schema.get("items")
        if isinstance(item, dict):
            for i, v in enumerate(payload):
                problems.extend(validate_schema(v, item, "%s[%d]" % (where, i)))
    return problems


# =====================================================================================================
# DAEMON CONFIG - caps, budgets and thresholds. Section 4.1a: these are CONFIG, not architecture, with
# the one exception marked as such in LANE_CAPS. Changing one is a measured decision for Brad.
# =====================================================================================================
TARGET_SERVINGS = 14       # the house batch size. Named here so the mapper's prompt, the assembler's
                           # -TargetServings default and the scale in every mapped file cannot drift
                           # apart - the same reason section 4.5 has one contract per artifact.
# ---------------------------------------------------------------------------------------------------
# THE P5 GATE LIST - a MIRROR of wave-publish.ps1's own `$gates = @(` array, first six entries.
#
# wave-publish P5 hard-refuses a publish when any of these is not clean, and wave-preaudit.ps1 runs
# EXACTLY these six as its shared gates and writes their verdicts into wave-<k>.preaudit.json BEFORE
# the auditor is dispatched. So the daemon can know the publish will be refused without paying for an
# audit to find out. Measured on hunt-2026-08-27-highprotein: audit-spec-contradictions was already
# red in the report for waves 1, 2, 9, 10 and 11, each of which then bought a full auditor session
# that returned NO-GO citing that gate - 21.8M tokens, 38% of audit spend, ~14% of the run.
#
# THE DISCIPLINE THIS NEEDS. `recipes-db-dryrun` failed in twelve of fifteen preaudits and waves 3, 4
# and 8 PUBLISHED anyway, because it is not a P5 gate. Neither are p8-endpoint-provenance and
# p8-feed-liveness. "Any red in the battery" would have blocked three good publishes. Nothing is
# added to this tuple that wave-publish does not refuse on, and the cross-file pin in the self-test
# regexes the labels out of wave-publish.ps1 itself so a drift there turns this red.
#
# The three gates BELOW these six in wave-publish's array (audit-ghost-field-limits,
# audit-wave-blocker-headings, test-guards) are real P5 gates that the BATTERY does not run, so no
# preaudit report can ever carry a verdict for them. An absent check is not red here - see below.
# ---------------------------------------------------------------------------------------------------
P5_GATES = ("audit-spec-contradictions", "audit-store-integrity", "audit-vocab-integrity",
            "audit-unbid-ingredients", "audit-cost-plausibility", "audit-cost-line-coverage")


def p5_red_gates(doc):
    """Which P5 gates the battery report says are NOT clean, in P5_GATES order.

    A gate ABSENT from shared_checks is NOT red: the battery did not run it, and could-not-look is
    announced by its own road (an unreadable report is a finding) rather than refused here. A doc
    that is not a dict returns [] for the same reason - this function never invents a refusal out of
    a shape it does not recognise.
    """
    if not isinstance(doc, dict):
        return []
    verdicts = {}
    for chk in (doc.get("shared_checks") or []):
        if not isinstance(chk, dict):
            continue
        name = chk.get("check")
        if isinstance(name, str):
            verdicts[name] = str(chk.get("verdict") or "").strip().lower()
    return [g for g in P5_GATES if g in verdicts and verdicts[g] != "pass"]


# 5 -> 2 ON 2026-09-04, and this is not the batching TRADE recorded earlier that day - it is a CLIFF.
#
# The mapper returns ONE JSON payload for the whole batch, and a headless answer has an output-token
# ceiling of 32,000 that counts thinking as well as text. Read off the map:4x session of
# hunt-2026-09-04-five:
#
#     10:04:11  stop=max_tokens   output_tokens=32000   <- the first payload, cut off mid-field:
#                                                          ..."carbs_g": 25.2, "
#     10:06:28  stop=end_turn     output_tokens=15405   <- the whole answer, generated again
#
# 47,405 output tokens for a 15,405-token answer. At ~81 tok/s that is 6.6 of the call's 14 minutes
# spent generating text nothing ever read - and the result envelope cannot show it, because its
# `result` is the final text block only. A batch that crosses the ceiling does not degrade; it pays
# double, and the useful output of that 4-recipe call was LESS than the 1-recipe call's.
#
# Four recipes at effort high produced ~15,400 useful tokens plus ~53,000 of thinking, so five sat
# right at the edge. Two recipes at effort medium is ~8,000 of answer with the thinking cut, well
# inside the ceiling with margin for a hard batch.
#
# THE TOKEN MEASUREMENT STILL STANDS and still pulls the other way: map:1x cost 436,685 and 577,141
# INPUT tokens for one recipe each against map:5x's 212,244, because every call re-sends the standing
# context. 2 rather than 1 keeps that half-alive - and keeps the registrar's proposals batched, which
# is the one stage batching genuinely helps. Three self-test cases encode the input-token decision;
# they are written against MAP_BATCH rather than a literal now, so they hold at any size that does
# not cross the cliff.
MAP_BATCH = 2              # section S4: mapper micro-batches (was 5; see the ceiling note above)
PRICE_BATCH = 10           # section 2.4: up to 10 absent terms per pricer invocation, across recipes
DECIDE_TAKE_BATCH = 5      # the decide channel's greedy sweep; DECIDE_BATCH caps the dispatch itself
WAVE_SIZE = 10             # plan default
DISPATCH_TIMEOUT = 3600    # seconds per headless dispatch. A wall, not a verdict: a timeout is B5.

# ---------------------------------------------------------------------------------------------------
# RUNG-1 RETRY (the 2026-08-24 phase-3 pin, measured during the D6 gate).
#
# Rung 1 at temp 0.1 is NOT deterministic. `jalape-o-popper-chicken` escalated on one line at 88%
# round-trip coverage (17 of 18 lines verified) and settled on the next pass with zero code change
# between them; a different page flipped the other way between rounds. So a borderline page is a coin
# the sweep flips, and one escalation is not a permanent property of a URL.
#
# The rule, keyed on the `coverage` field local_extract already puts in each escalation failure:
# retry rung 1 ONCE when at most RUNG1_RETRY_MAX_FAILED_LINES lines failed AND every failing line's
# coverage is >= RUNG1_RETRY_MIN_COVERAGE. Near-misses only - a qty/unit substring failure or a
# low-coverage mangle goes straight down the ladder, because those are not coin flips.
#
# ONE retry, never a loop: ~10 GPU-seconds is worth spending against a ~50 s rung-2 attempt or a Claude
# dispatch, and a second identical failure is the page telling you the answer.
# ---------------------------------------------------------------------------------------------------
RUNG1_RETRY_MAX_FAILED_LINES = 1
RUNG1_RETRY_MIN_COVERAGE = 0.85


def rung1_retry_eligible(verification):
    """Does this rung-1 result earn its one cheap re-roll? Takes the verification block (rung 1's,
    which carries `failures[]` with a per-line `coverage`). Returns (bool, why)."""
    if not isinstance(verification, dict):
        return False, "no verification block to read"
    failures = verification.get("failures")
    if failures is None:
        # A rung-1 MISS (no JSON-LD at all) has no failures list. There is nothing to re-roll: the
        # page does not carry the input rung 1 needs, and running it again would ask the same
        # question of the same bytes.
        return False, "rung 1 did not apply to this page, so a re-roll asks the same question"
    if not failures:
        return False, "nothing failed"
    if len(failures) > RUNG1_RETRY_MAX_FAILED_LINES:
        return False, ("%d lines failed, over the %d-line near-miss ceiling"
                       % (len(failures), RUNG1_RETRY_MAX_FAILED_LINES))
    for f in failures:
        cov = f.get("coverage")
        if not _is_number(cov) or cov < RUNG1_RETRY_MIN_COVERAGE:
            return False, ("a failing line sits at %s coverage, under the %.2f near-miss bar - that "
                           "is a mangle or a substring failure, not a coin flip"
                           % (cov, RUNG1_RETRY_MIN_COVERAGE))
    return True, ("%d failing line(s), all at >= %.2f coverage - one cheap re-roll before the ladder"
                  % (len(failures), RUNG1_RETRY_MIN_COVERAGE))


# =====================================================================================================
# THE PARITY RUNNER (section 4.2). One vector file, two implementations, one verdict.
#
# The vectors are DATA, not code, precisely so the two runners cannot drift into testing different
# things. Three vector kinds cover everything hunt-lib.js's selfTest asserts:
#   * "call"     - a pure function, JSON in, JSON out. Most of the suite.
#   * "retries"  - a SEQUENCE of bump_retries calls, because B6 is about state carried between calls.
#   * "breaker"  - a sequence of breaker operations, for the same reason.
#   * "chan"     - a NAMED async scenario. Channel semantics are not expressible as data, so both
#                  runners implement the same five scenarios under the same names and the vector says
#                  which one and what it must produce. This is the one place the suite is written
#                  twice, and it is named here so a reader knows to check both bodies when it changes.
# =====================================================================================================

VECTORS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hunt-lib-vectors.json")

_CALLS = {}


def _register_calls():
    _CALLS.update({
        "firstToken": lambda a: first_token(*a),
        "isPass": lambda a: is_pass(*a),
        "isGo": lambda a: is_go(*a),
        "isRejected": lambda a: is_rejected(*a),
        "normState": lambda a: norm_state(*a),
        "quoteTerms": lambda a: quote_terms(*a),
        "termHasComma": lambda a: term_has_comma(*a),
        "planTrim": lambda a: plan_trim(*a),
        "chooseScope": lambda a: choose_scope(*a),
        "scopeIsLegal": lambda a: scope_is_legal(*a),
        "repairClaimHolds": lambda a: repair_claim_holds(*a),
        "inBand": lambda a: in_band(*a),
    })


def _canon(v):
    return json.dumps(v, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


async def _chan_scenario(name):
    """The five channel scenarios, ported line for line from hunt-lib.js's selfTest."""
    if name == "takeBatch-sweeps":
        c = chan()
        c.push(1); c.push(2); c.push(3)
        b = await c.take_batch(5)
        return len(b)
    if name == "closed-empty-returns-null":
        c = chan()
        c.push(1); c.push(2); c.push(3)
        await c.take_batch(5)
        c.close()
        return (await c.take()) is None
    if name == "lone-item-immediate":
        c = chan()
        c.push("x")
        one = await c.take_batch(5)
        return len(one)
    if name == "close-releases-parked":
        c = chan()
        c.push(1); c.push(2)
        released = {"v": False}

        async def parked():
            await c.wait_for_space(2)
            released["v"] = True

        task = asyncio.ensure_future(parked())
        await asyncio.sleep(0)
        c.close()
        await task
        return released["v"]
    if name == "drain-before-close":
        c = chan()
        got = []

        async def consumer():
            while True:
                v = await c.take()
                if v is None:
                    break
                got.append(v)

        task = asyncio.ensure_future(consumer())
        c.push("a"); c.push("b"); c.close()
        await task
        return ",".join(got)
    raise KeyError("unknown chan scenario %r" % name)


def _run_one(vec):
    kind = vec.get("kind", "call")
    if kind == "call":
        fn = _CALLS.get(vec["fn"])
        if fn is None:
            raise KeyError("the vector file names a function this runner does not have: %s" % vec["fn"])
        return fn(vec.get("args") or [])
    if kind == "retries":
        counts, returns = {}, []
        for step in vec["args"]:
            returns.append(bump_retries(counts, step[0], step[1]))
        return {"counts": counts, "returns": returns}
    if kind == "breaker":
        a = vec["args"]
        b = make_breaker(a.get("threshold", CIRCUIT_THRESHOLD), a.get("maxCalls", MAX_AGENT_CALLS))
        for op in a.get("ops") or []:
            if op[0] == "note":
                b.note(op[1])
            elif op[0] == "countCall":
                b.count_call()
            elif op[0] == "checkBudget":
                b.check_budget()
            elif op[0] == "trip":
                b.trip(op[1])
            else:
                raise KeyError("unknown breaker op %r" % op[0])
        return {"open": b.open, "calls": b.calls}
    if kind == "chan":
        return asyncio.new_event_loop().run_until_complete(_chan_scenario(vec["scenario"]))
    raise KeyError("unknown vector kind %r" % kind)


def run_parity(path=None, quiet=False):
    """Run every shared vector against THIS implementation. Returns (bad, total, rows)."""
    _register_calls()
    path = path or VECTORS
    with open(path, "r", encoding="utf-8-sig") as f:
        doc = json.load(f)
    rows, bad = [], 0
    for vec in doc["vectors"]:
        try:
            got = _run_one(vec)
            ok = _canon(got) == _canon(vec["expect"])
        except Exception as e:                                    # noqa: BLE001
            got, ok = "THREW: %s" % e, False
        rows.append({"id": vec["id"], "ok": ok, "got": _canon(got) if not ok else "",
                     "must_fire": bool(vec.get("must_fire")), "note": vec.get("note", "")})
        if not ok:
            bad += 1
        if not quiet:
            tag = "MUST FIRE " if vec.get("must_fire") else "CLEAN TWIN"
            if ok:
                print("  ok    %s %-52s %s" % (tag, vec["id"], vec.get("note", "")))
            else:
                print("  X     %s %-52s expected %s, got %s"
                      % (tag, vec["id"], _canon(vec["expect"]), rows[-1]["got"]))
    return bad, len(doc["vectors"]), rows


# =====================================================================================================
# THE PINNED-REFERENCE GATE, for every Python suite in the pipeline (PLAN-after-review P5).
#
# WHY IT LIVES HERE. It shipped on 2026-09-04 inside hunt_daemon_selftest.py, where only the daemon
# suite could reach it - so harvest (164 cases), decide_apply (46) and the two PowerShell suites were
# still diffed by a hand-rolled `sed | sort | comm`, and the review of that very change could only
# reproduce its case-name diff because a scratchpad happened to survive. A gate that cannot be re-run
# by the next reader is not a gate. This module is the one home the estate has for shared pipeline
# logic (section 4.5), so the two functions move here whole and the daemon suite re-exports them:
# nothing about its behaviour changes and none of its case names move.
#
# The PowerShell twin is `selftest-names-lib.ps1`, and it is a SECOND implementation of the same
# rule because PowerShell cannot import this. The two are held in lockstep by a shared vector file -
# see that file's header.
# =====================================================================================================

def names_diff(seen, ref_path):
    """Removed / added case NAMES against a pinned reference. Returns (removed, added, why_not).

    WHY BY NAME AND NOT BY COUNT (PLAN-after-dedup P4, and the rule it comes from). A tally settles
    nothing: deleting one case and adding one leaves the count identical, and deleting a case on its
    own leaves the suite GREEN at exit 0 - measured. Only the names can see a case that vanished.
    """
    try:
        with open(ref_path, encoding="utf-8-sig") as f:
            ref = [ln.strip() for ln in f if ln.strip()]
    except Exception as e:                                        # noqa: BLE001
        return [], [], "no reference at %s (%s)" % (ref_path, e)
    if not ref:
        return [], [], ("the reference at %s names no cases, and an empty reference cannot see a "
                        "removal - re-pin it from HEAD" % ref_path)
    # STRIPPED ON BOTH SIDES. Some case names are indented to read as a continuation of the one
    # above; that indentation is layout, not identity, and comparing it made 31 unchanged cases
    # read as 31 removals and 31 additions at once - a diff that cries wolf is a diff nobody reads.
    rs, ss = set(x.strip() for x in ref), set(x.strip() for x in seen)
    return sorted(rs - ss), sorted(ss - rs), ""


def names_report(seen, ref_path):
    """The VERDICT, so the exit code and the fixture read the same function. Returns (rc, lines).

    rc is EXIT_CLEAN when nothing was removed - an ADDED case is a new fixture and is fine - and
    EXIT_CANNOT_RUN when any reference case did not run, whatever the cases that did run said.
    """
    removed, added, why = names_diff(seen, ref_path)
    if why:
        return EXIT_CANNOT_RUN, ["  CANNOT DIFF - %s" % why]
    lines = ["  vs %s: %d removed, %d added" % (ref_path, len(removed), len(added))]
    lines += ["    +  %s" % n for n in added]
    lines += ["    -  %s" % n for n in removed]
    if removed:
        lines.append("")
        lines.append("  A CASE THAT VANISHED IS NOT A PASS. %d case name(s) in the reference did "
                     "not run. Either the commit says which and why, or this is coverage lost "
                     "silently." % len(removed))
        return EXIT_CANNOT_RUN, lines
    return EXIT_CLEAN, lines


def names_finish(seen, names_out, names_ref, emit=print):
    """The whole of what a suite has to do at its end: pin, diff, and hand back the rc to fold into
    its own. ONE call site per suite, so four suites cannot drift into four dialects of it.

    Returns EXIT_CLEAN or EXIT_CANNOT_RUN. The suite's own failures still win - a suite with red
    cases reports its own failure - but a suite that is GREEN and has lost a case must not exit 0.
    """
    if names_out:
        # newline="" ON PURPOSE: a pinned reference is compared by other tools and by hand, and a
        # file whose line endings depend on which OS emitted it is a diff that lies.
        with open(names_out, "w", encoding="utf-8", newline="") as f:
            f.write("\n".join(seen) + "\n")
        emit("  case NAMES pinned to %s (%d) - diff a later run against it with --names-diff"
             % (names_out, len(seen)))
    if not names_ref:
        return EXIT_CLEAN
    rc, lines = names_report(seen, names_ref)
    for ln in lines:
        emit(ln)
    return rc


def names_fixtures(T, seen):
    """The fixtures for the RULE, run inside every suite that owns a copy of the gate.

    Called with the caller's own T and its own live `seen` list, so case 1 is a real behavioural
    check: it asserts that names recorded EARLIER IN THIS RUN are in the list. A fixture that
    grepped the suite's source for `seen.append` would match its own text and could never fail -
    the 2026-08-31 trap. This one goes red the moment a suite prints a case it does not record.
    """
    import tempfile                                               # noqa: PLC0415
    T("MUST FIRE  this suite RECORDS the case names it prints - the pinned reference is built from "
      "the list, so a suite that prints without recording would pin a lie",
      len(seen) > 3 and all(isinstance(x, str) and x.strip() for x in seen),
      "seen=%d" % len(seen))
    tmp = tempfile.mkdtemp(prefix="names-gate-")
    ref = os.path.join(tmp, "ref.txt")
    with open(ref, "w", encoding="utf-8", newline="") as f:
        f.write("case one\ncase two\ncase three\n")
    rc, lines = names_report(["case one", "case two"], ref)
    T("MUST FIRE  a case name that VANISHED exits 2 even though every case that ran passed",
      rc == EXIT_CANNOT_RUN and any("-  case three" in x for x in lines),
      "rc=%s | %s" % (rc, " | ".join(lines)))
    rc, lines = names_report(["case one", "case two", "case three", "case four"], ref)
    T("CLEAN TWIN an ADDED case is a new fixture, not a regression - exit 0, and it is named",
      rc == EXIT_CLEAN and any("+  case four" in x for x in lines),
      "rc=%s | %s" % (rc, " | ".join(lines)))
    rc, lines = names_report(["  case one", "case two", "   case three"], ref)
    T("CLEAN TWIN indentation is layout, not identity - an indented continuation name is the same "
      "case",
      rc == EXIT_CLEAN and "0 removed, 0 added" in lines[0], "rc=%s | %s" % (rc, lines[0]))
    rc, lines = names_report(["case one"], os.path.join(tmp, "nope.txt"))
    T("MUST FIRE  a MISSING reference is a could-not-look, never a clean diff",
      rc == EXIT_CANNOT_RUN and any("CANNOT DIFF" in x for x in lines),
      "rc=%s | %s" % (rc, " | ".join(lines)))
    empty = os.path.join(tmp, "empty.txt")
    with open(empty, "w", encoding="utf-8") as f:
        f.write("")
    rc, _lines = names_report(["case one"], empty)
    T("MUST FIRE  ...and so is an EMPTY reference - it can never see a removal, so it may not "
      "report one",
      rc == EXIT_CANNOT_RUN, "rc=%s" % rc)
    # The PowerShell twin must agree case for case, and the only way to hold two implementations in
    # step is to make one file the source of both. This writes the vectors the .ps1 lib reads.
    vec = os.path.join(os.path.dirname(os.path.abspath(__file__)), "selftest-names-vectors.json")
    try:
        with open(vec, encoding="utf-8-sig") as f:
            vectors = json.load(f)
    except Exception as e:                                        # noqa: BLE001
        T("MUST FIRE  the cross-language vectors for this rule are readable - the PowerShell twin "
          "is held in step by them and by nothing else", False, str(e))
        return
    rows = vectors.get("cases") or []
    bad = []
    for row in rows:
        rpath = os.path.join(tmp, "v-%s.txt" % row["name"])
        if row.get("ref") is None:
            rpath = os.path.join(tmp, "v-missing-%s.txt" % row["name"])
        else:
            with open(rpath, "w", encoding="utf-8", newline="") as f:
                f.write("".join(x + "\n" for x in row["ref"]))
        rc, _lines = names_report(row["seen"], rpath)
        want = EXIT_CANNOT_RUN if row["exit"] == 2 else EXIT_CLEAN
        if rc != want:
            bad.append("%s: got %s want %s" % (row["name"], rc, want))
    T("MUST FIRE  Python answers every cross-language vector exactly as the file states - the "
      "PowerShell twin answers the same file, and that is what keeps the two in step",
      rows and not bad, "%d vector(s): %s" % (len(rows), "; ".join(bad) or "all green"))


# =====================================================================================================
# hunt_lib's own self-test: the parity vectors, plus the fixtures that are NOT shared because they have
# no JS counterpart - the rung-1 retry rule (a D9 addition) and the generic schema validator.
# =====================================================================================================

def selftest():
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    print("hunt_lib self-test")
    print("")
    print("shared parity vectors (%s):" % os.path.basename(VECTORS))
    nbad, ntot, _rows = run_parity()
    print("  %d/%d vectors green on the Python side" % (ntot - nbad, ntot))
    if nbad:
        bad.append("%d parity vector(s)" % nbad)
    print("")

    # ---- the rung-1 retry rule (the 2026-08-24 pin). Not shared: hunt-lib.js has no extract lane. ----
    print("rung-1 retry rule (D9 addition, keyed on the escalation's failures[].coverage):")
    near = {"failures": [{"raw": "1 dry pint cherry tomatoes", "coverage": 0.88,
                          "reasons": ["round-trip covered 88%"]}]}
    T("CLEAN TWIN one line at 0.88 coverage earns its one cheap re-roll",
      rung1_retry_eligible(near)[0], str(rung1_retry_eligible(near)))
    low = {"failures": [{"raw": "x", "coverage": 0.40, "reasons": ["dropped half the line"]}]}
    T("MUST FIRE  a low-coverage mangle goes straight down the ladder, no re-roll",
      not rung1_retry_eligible(low)[0], str(rung1_retry_eligible(low)))
    two = {"failures": [{"raw": "a", "coverage": 0.9}, {"raw": "b", "coverage": 0.95}]}
    T("MUST FIRE  two failing lines is not a near-miss, however high each one scores",
      not rung1_retry_eligible(two)[0], str(rung1_retry_eligible(two)))
    sub = {"failures": [{"raw": "a", "coverage": 1.0,
                         "reasons": ["unit 'tablespoon' is not in the line"]}]}
    T("a qty/unit substring failure at full coverage is still eligible by the stated rule - the rule "
      "is coverage-keyed and says so",
      rung1_retry_eligible(sub)[0], str(rung1_retry_eligible(sub)))
    T("MUST FIRE  a rung-1 MISS (no JSON-LD, so no failures list) is never re-rolled",
      not rung1_retry_eligible({"lines": 0, "unverified": 0})[0],
      str(rung1_retry_eligible({"lines": 0})))
    T("CLEAN TWIN the boundary value 0.85 is inside the bar, not outside it",
      rung1_retry_eligible({"failures": [{"raw": "a", "coverage": RUNG1_RETRY_MIN_COVERAGE}]})[0],
      "the bar excluded its own value")
    T("MUST FIRE  a coverage field that is missing entirely is not read as a pass",
      not rung1_retry_eligible({"failures": [{"raw": "a"}]})[0], "treated a null as a near-miss")

    # ---- the generic schema validator ----
    print("")
    print("schema validation (one re-ask has to quote EVERY violation, so the check is total):")
    T("CLEAN TWIN a conforming STAGE payload validates",
      validate_schema({"slug": "a", "status": "ok", "state": "extracted"}, STAGE) == [],
      str(validate_schema({"slug": "a", "status": "ok", "state": "extracted"}, STAGE)))
    p = validate_schema({"slug": "a"}, STAGE)
    T("MUST FIRE  two missing required fields are BOTH named, not just the first",
      len(p) == 2 and any("status" in x for x in p) and any("state" in x for x in p), str(p))
    T("MUST FIRE  a wrong type is named with the field path",
      any("changed_count" in x for x in validate_schema({"changed_count": "none"}, REPAIRCHECK)),
      str(validate_schema({"changed_count": "none"}, REPAIRCHECK)))
    T("MUST FIRE  a bad row inside an array is named by its index",
      any("results[1]" in x for x in validate_schema(
          {"results": [{"slug": "a", "status": "ok", "state": "mapped"}, {"slug": "b"}]}, MAPPED)),
      str(validate_schema({"results": [{"slug": "a", "status": "ok", "state": "mapped"},
                                       {"slug": "b"}]}, MAPPED)))
    T("MUST FIRE  a JSON true is not a number (Python would otherwise read it as 1)",
      validate_schema({"changed_count": True}, REPAIRCHECK) != [], "accepted a bool as a number")
    T("CLEAN TWIN a boolean field accepts a boolean",
      validate_schema({"ok": False}, PUB) == [], str(validate_schema({"ok": False}, PUB)))
    T("MUST FIRE  an explicit null in a required field reads as missing, not as present",
      validate_schema({"slug": "a", "status": "ok", "state": None}, STAGE) != [], "accepted null")
    T("an unrecognised schema keyword is IGNORED rather than guessed at",
      validate_schema({"x": 1}, {"type": "object", "minProperties": 9}) == [], "invented a rule")
    T("MUST FIRE  a closed enum in the schema is enforced and names the legal values",
      any("closed enum" in x for x in validate_schema(
          "maybe", {"type": "string", "enum": ["yes", "no"]})), "accepted it")

    # ---- WRITE's named delta, pinned so nobody restores the macro fields by reflex ----
    # ---- the JS half's embedded copy must still be the shipped file ----
    print("")
    print("parity runner drift check (a copy a machine writes and a machine checks):")
    ok, detail = parity_embed_state()
    T("MUST FIRE  hunt-lib-parity.js embeds the CURRENT hunt-lib.js and the current vectors", ok,
      detail)
    if ok:
        print("        " + detail)

    print("")
    T("MUST FIRE  WRITE carries no macro fields (section 4.5's second named delta)",
      not any(k in WRITE["properties"] for k in
              ("cal_per_serving", "carbs_per_serving", "protein_per_serving", "cost_per_serving")),
      ",".join(sorted(WRITE["properties"])))
    T("CLEAN TWIN every other inherited schema kept its required set verbatim",
      CANDS["required"] == ["round", "candidates"] and QA["required"] == ["slug", "verdict"]
      and PUB["required"] == ["ok"] and WAVECLOSE["required"] == ["wave", "slugs"], "drifted")
    T("MUST FIRE  the price lane's cap is 1 - architecture, not config",
      LANE_CAPS["price"] == 1, str(LANE_CAPS["price"]))

    print("")
    if bad:
        print("hunt_lib SELF-TEST FAIL (%d)" % len(bad))
        print("HUNT-LIB-COMPLETE")
        return EXIT_CANNOT_RUN
    print("hunt_lib SELF-TEST PASS")
    print("HUNT-LIB-COMPLETE")
    return EXIT_CLEAN


# =====================================================================================================
# THE GENERATOR THAT KEEPS THE JS HALF HONEST.
#
# A workflow script cannot read the repo, so hunt-lib.js's text has to be COPIED into the parity runner.
# The estate has done that by hand once already (hunt-lib.selftest.js, 2026-08-16) and its own header
# admits the copy will drift. A copy a machine writes and a machine checks does not: --emit-parity
# rewrites the EMBEDDED line, stamping the source's length and SHA-256, and the drift check below fires
# in --selftest the moment hunt-lib.js changes without a regeneration.
# =====================================================================================================
HUNT_LIB_JS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hunt-lib.js")
PARITY_JS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hunt-lib-parity.js")
_SRC_BEGIN = "// >>> GENERATED-HUNT-LIB-BEGIN"
_SRC_END = "// >>> GENERATED-HUNT-LIB-END"
_VEC_BEGIN = "// >>> GENERATED-VECTORS-BEGIN"
_VEC_END = "// >>> GENERATED-VECTORS-END"

# The source is SPLICED AS CODE, not carried as a string, and that is not a style choice. MEASURED
# 2026-08-24: the first build passed hunt-lib.js's text through the workflow's `args` and evaluated it
# with `new Function` - the one shape that tests the shipped bytes with no copy at all - and the
# harness refused it ("EvalError: Code generation from strings disallowed for this context"). A
# generated splice is the honest second-best: one copy, written by a machine, hashed by a machine.


def _src_sha(text):
    import hashlib                                               # noqa: PLC0415
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def _region(lines, begin, end):
    b = [i for i, ln in enumerate(lines) if ln.startswith(begin)]
    e = [i for i, ln in enumerate(lines) if ln.startswith(end)]
    if not b or not e or e[0] <= b[0]:
        raise RuntimeError("the parity runner has no %s..%s region" % (begin, end))
    return b[0], e[0]


def _js_body(src):
    """hunt-lib.js is an ES module. Strip only the `export ` keyword - nothing else is touched, so what
    the gate runs is the shipped file's own declarations."""
    return re.sub(r"^export\s+", "", src, flags=re.M)


def emit_parity_js(js_path=None, vectors_path=None, out_path=None):
    """Rewrite the parity runner's two generated regions from the shipped files. Returns (out, sha, n)."""
    js_path = js_path or HUNT_LIB_JS
    vectors_path = vectors_path or VECTORS
    out_path = out_path or PARITY_JS
    with open(js_path, "r", encoding="utf-8") as f:
        src = f.read()
    with open(vectors_path, "r", encoding="utf-8-sig") as f:
        vec = json.load(f)
    with open(out_path, "r", encoding="utf-8") as f:
        lines = f.read().split("\n")
    sha = _src_sha(src)

    vb, ve = _region(lines, _VEC_BEGIN, _VEC_END)
    lines[vb + 1:ve] = ["const VECTORS = " + json.dumps(vec, ensure_ascii=False),
                        "const SRC_SHA = " + json.dumps(sha)]
    sb, se = _region(lines, _SRC_BEGIN, _SRC_END)
    lines[sb + 1:se] = (["// hunt-lib.js @ %s, %d bytes, spliced verbatim apart from the `export` keyword"
                         % (sha, len(src.encode("utf-8")))]
                        + _js_body(src).split("\n"))
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    return out_path, sha, len(vec["vectors"])


def parity_embed_state(js_path=None, vectors_path=None, out_path=None):
    """Is the spliced copy still the shipped file? Returns (ok, detail)."""
    js_path = js_path or HUNT_LIB_JS
    vectors_path = vectors_path or VECTORS
    out_path = out_path or PARITY_JS
    try:
        with open(out_path, "r", encoding="utf-8") as f:
            lines = f.read().split("\n")
        sb, se = _region(lines, _SRC_BEGIN, _SRC_END)
        if se - sb < 3:
            return False, "the parity runner carries no spliced source - run --emit-parity"
        with open(js_path, "r", encoding="utf-8") as f:
            src = f.read()
        spliced = "\n".join(lines[sb + 2:se])
        if spliced != _js_body(src):
            return False, ("hunt-lib.js has changed since the parity runner was generated (it is %s "
                           "on disk now) - run `hunt_lib.py --emit-parity` or the JS half of the gate "
                           "is testing yesterday's code" % _src_sha(src))
        vb, ve = _region(lines, _VEC_BEGIN, _VEC_END)
        emb = json.loads("\n".join(lines[vb + 1:ve]).split("const VECTORS = ", 1)[1]
                         .rsplit("\nconst SRC_SHA", 1)[0])
        with open(vectors_path, "r", encoding="utf-8-sig") as f:
            vec = json.load(f)
        if emb != vec:
            return False, "the spliced vectors and hunt-lib-vectors.json differ - run --emit-parity"
        return True, "%d vectors, hunt-lib.js @ %s" % (len(vec["vectors"]), _src_sha(src))
    except Exception as e:                                        # noqa: BLE001
        return False, "could not read the parity runner's generated regions (%s)" % e


def main(argv=None):
    import argparse                                              # noqa: PLC0415
    ap = argparse.ArgumentParser(description="hunt_lib: schemas, daemon config, and the ported "
                                             "hunt-lib.js decision logic")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--emit-parity", dest="emit_parity", action="store_true",
                    help="embed hunt-lib.js + the vectors into hunt-lib-parity.js")
    ap.add_argument("--parity", action="store_true",
                    help="run the shared vectors against THIS implementation and print a JSON summary")
    ap.add_argument("--vectors", default="")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    if a.emit_parity:
        out, sha, n = emit_parity_js()
        print("hunt_lib --emit-parity: %s  (hunt-lib.js @ %s, %d vectors)"
              % (os.path.basename(out), sha, n))
        print("HUNT-LIB-COMPLETE")
        return EXIT_CLEAN
    if a.parity:
        bad, total, rows = run_parity(a.vectors or None, quiet=a.json)
        if a.json:
            print(json.dumps({"impl": "python", "total": total, "failed": bad, "rows": rows},
                             indent=1))
        else:
            print("")
            print("hunt-lib parity (python): %d/%d green" % (total - bad, total))
        print("HUNT-LIB-COMPLETE")
        return EXIT_FINDINGS if bad else EXIT_CLEAN
    if a.selftest:
        return selftest()
    ap.print_help()
    return EXIT_CANNOT_RUN


if __name__ == "__main__":
    import sys                                                   # noqa: PLC0415
    sys.exit(main())
