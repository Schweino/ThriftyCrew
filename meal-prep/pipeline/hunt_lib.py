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

import subprocess

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
