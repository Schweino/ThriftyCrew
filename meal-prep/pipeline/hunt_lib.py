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
    "map": 2,
    "price": 1,      # ARCHITECTURE, not config. The price lane stays a singleton, full stop.
    "write": 3,
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


def py_invoke(script, args, timeout=600):
    """Call a PYTHON surface. Returns (rc, stdout, stderr).

    ONE ROAD PER LANGUAGE, and this is the Python one. ps_invoke exists because `-File` cannot carry
    a multi-element array; this exists for a different hazard with the same shape - a Python surface
    must be run by THIS interpreter, `sys.executable`. Bare `python` on this box is the Windows Store
    shim, which exits 49 without running anything, and a daemon that shelled it would report a
    could-not-run for a script that is perfectly fine. argv carries strings straight through, so
    there is no marshalling problem here and none is invented: a list argument would be a defect in
    the CALLER, which is why every element is stringified rather than joined.
    """
    cmd = [sys.executable, script] + [str(a) for a in args]
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

def plan_trim(wave_slugs, per_slug, already_repaired):
    blocked, clean = [], []
    for s in wave_slugs:
        v = (per_slug or {}).get(s)
        if v and str(v).upper().startswith("BLOCK"):
            blocked.append(s)
        else:
            clean.append(s)
    return {
        "clean": clean,
        "blocked": blocked,
        # A slug that has already had its one repair cycle is terminal; anything else goes back.
        "toReject": blocked if already_repaired else [],
        "toRepair": [] if already_repaired else blocked,
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


def in_band(cal, carbs, band):
    cal_min, cal_max = band.get("calMin"), band.get("calMax")
    carb_max = band.get("carbMax")
    if not _is_number(cal) or not _is_number(carbs):
        return {"ok": True, "reason": "not reported"}
    if cal < cal_min:
        return {"ok": False, "reason": "%s cal below the %s floor" % (_num(cal), _num(cal_min))}
    if cal > cal_max:
        return {"ok": False, "reason": "%s cal above the %s ceiling" % (_num(cal), _num(cal_max))}
    if carbs > carb_max:
        return {"ok": False, "reason": "%sg carbs above the %s limit" % (_num(carbs), _num(carb_max))}
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

MAPPED = {"type": "object", "properties": {
    "results": {"type": "array", "items": {"type": "object", "properties": {
        "slug": {"type": "string"},
        "status": {"type": "string", "description": "ok | rejected"},
        "state": {"type": "string", "description": "mapped -> then pricing or priced"},
        "absent_terms": {"type": "array", "items": {"type": "string"},
                         "description": "blocking terms enqueued for the pricer"},
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
        "db_entries_added": {"type": "array", "items": {"type": "string"}},
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

REGISTRAR_VERDICTS = ("approve", "reject", "alias")


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

DERIVE = {"type": "object", "properties": {
    "resolved": {"type": "array", "items": {"type": "object", "properties": {
        "slug": {"type": "string"}, "state": {"type": "string"}, "detail": {"type": "string"}},
        "required": ["slug", "state"]}},
    "still_pending_terms": {"type": "array", "items": {"type": "string"}}},
    "required": ["resolved"]}

# The delta: no cal_per_serving / carbs_per_serving / protein_per_serving / cost_per_serving.
WRITE = {"type": "object", "properties": {
    "slug": {"type": "string"}, "status": {"type": "string"}, "state": {"type": "string"},
    "detail": {"type": "string"}},
    "required": ["slug", "status", "state"]}

QA = {"type": "object", "properties": {
    "slug": {"type": "string"}, "verdict": {"type": "string"},
    "owner": {"type": "string"}, "findings": {"type": "string"}},
    "required": ["slug", "verdict"]}

WAVECLOSE = {"type": "object", "properties": {
    "wave": {"type": "number"}, "slugs": {"type": "array", "items": {"type": "string"}},
    "batch": {"type": "string"}},
    "required": ["wave", "slugs"]}

AUDIT = {"type": "object", "properties": {
    "verdict": {"type": "string"},
    "blocking_slugs": {"type": "array", "items": {"type": "string"}},
    "blocker_kind": {"type": "string"}, "owner": {"type": "string"}, "summary": {"type": "string"}},
    "required": ["verdict"]}

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
MAP_BATCH = 5              # section S4: mapper micro-batches of up to 5 recipes
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
