"""Who decided this? — the authority tier behind a banked verdict.

WHY THIS EXISTS (2026-08-22, plan §3.1). `Resolver._verdict_index` retrieved
every `llm_rejected` / `known_wrong` / `llm_confirmed` row in
`question_verdicts` and showed it to the local model as PRECEDENT — "already
ruled NOT this commodity, do not repeat these mistakes". Most of those rows are
the model's OWN unreviewed rejections. So a wrong rejection became the authority
for rejecting its neighbours, the neighbours' rejections became authority in
turn, and nothing in the loop ever reviewed any of it. The model was being
taught by itself and told it was being taught by the board.

The obvious fix was `question_verdicts.decided_by`. It does not work as it
stands, and the reason is worth keeping on the record: `state.py` stamps that
column

    "model" if status.startswith("llm_") else "deterministic"

so a Claude reviewer's ruling — which lands as `llm_confirmed` / `llm_rejected`
by design, those being match_status values, not authorship — is stamped
'model' exactly like the local model's own guess. Measured on the live graph:
`decided_by` takes precisely two values, 'model' (4,070 rows) and
'deterministic' (71), and carries no authorship information at all.

The authorship IS recorded, in `reason`:

    reviewer CONFIRM: ... / reviewer REJECT: ...   the Claude review lane
    adjudicated: ... / retro-applied: ...          absolute known-wrong rulings
    llm: ...                                       the local model, unreviewed

with any number of `banked: ` prefixes in front, one per re-bank cycle. Measured
on the live graph after stripping those prefixes:

    llm_rejected   llm       3,315      <- the model's own; NOT precedent
    llm_rejected   reviewer    377
    llm_confirmed  reviewer    375
    known_wrong    adjudicated  58 + 7 retro-applied
    escalated      llm           6
    llm_match_unverified llm     3

The plan quoted 1,145 model-only rejections, from `reason LIKE 'llm%'` — that
counts only the rows whose reason had not yet been re-banked behind a prefix.
The true figure is 3,315 of 3,692 (90%), so the loop was even more self-referential
than the plan assumed.

THE THREE TIERS (plan §3.1):

  adjudicated   human, the Claude review lane, known-wrong. Shown as precedent.
  consensus     helper + local LLM agreeing (plan §4). Shown, labelled TENTATIVE.
                No such row exists yet — the helper lands in phase 3 — so this
                tier is provisioned, not populated. It is here so the phase-3
                writer has one place to stamp, and so the ablation harness can
                measure with and without it the day it exists.
  single_model  one model, unreviewed. NEVER shown as precedent. It is still a
                banked verdict and still prunes its own row (layer 4.5); what it
                loses is the right to testify about OTHER rows.

This module is the single place that decides which is which. `resolve.py` reads
it at retrieval time and `state.py` writes it into `decided_by` at bank time, so
the column stops lying going forward without the retrieval depending on it.

    python graph/lib/authority.py --selftest
"""

from __future__ import annotations

import re

TIER_ADJUDICATED = "adjudicated"
TIER_CONSENSUS = "consensus"
TIER_SINGLE_MODEL = "single_model"
TIER_DETERMINISTIC = "deterministic"

# Tiers that may be cited to the model as precedent, and how.
CITABLE_AS_PRECEDENT = (TIER_ADJUDICATED,)
CITABLE_AS_TENTATIVE = (TIER_CONSENSUS,)

# Statuses the deterministic layers own. They are never banked as verdicts
# (state.py's BANKABLE list), but classify them rather than guess if one appears.
DETERMINISTIC_STATUSES = frozenset(
    {"include_hit", "excluded", "category_excluded", "no_include_hit"})

# decided_by values that actually identify an author. 'model' is deliberately
# ABSENT: state.py has stamped it on reviewer rulings too (see the module
# docstring), so it is noise, and trusting it would re-open the very hole this
# module closes. When decided_by is uninformative we fall through to `reason`.
_AUTHOR_BY_DECIDED_BY = {
    "reviewer": TIER_ADJUDICATED,
    "human": TIER_ADJUDICATED,
    "claude": TIER_ADJUDICATED,
    "claude-review": TIER_ADJUDICATED,
    "consensus": TIER_CONSENSUS,
    "helper+llm": TIER_CONSENSUS,
    "deterministic": TIER_DETERMINISTIC,
}

_BANKED_PREFIX = re.compile(r"^(?:\s*banked:\s*)+", re.IGNORECASE)


def strip_banked(reason: str | None) -> str:
    """The innermost reason, with every `banked: ` re-bank prefix removed.

    A verdict re-banked five times reads
    `banked: banked: banked: banked: banked: llm: ...` — the authorship marker
    is at the END of the prefixes, not the start of the string, which is why a
    `reason LIKE 'llm%'` count under-reports the model's own rulings 3x.
    """
    return _BANKED_PREFIX.sub("", (reason or "").strip())


def authority_tier(status: str | None, reason: str | None = None,
                   decided_by: str | None = None) -> str:
    """Which tier a banked verdict belongs to. Conservative by construction.

    An unrecognised reason is `single_model`, not `adjudicated`: the cost of
    mistaking a model guess for a human ruling is the feedback loop this module
    exists to break, while the cost of the opposite mistake is one prior the
    model does not get to see.
    """
    st = (status or "").strip()
    # known_wrong is an ABSOLUTE ruling with written evidence, whatever route it
    # travelled to get here (KnownWrong nodes carry no reason string at all).
    if st == "known_wrong":
        return TIER_ADJUDICATED
    if st in DETERMINISTIC_STATUSES:
        return TIER_DETERMINISTIC

    tier = _AUTHOR_BY_DECIDED_BY.get((decided_by or "").strip().lower())
    if tier:
        return tier

    core = strip_banked(reason).lower()
    if core.startswith("reviewer"):
        return TIER_ADJUDICATED
    if core.startswith(("adjudicated", "retro-applied", "known-wrong", "known_wrong")):
        return TIER_ADJUDICATED
    if core.startswith(("consensus", "helper+llm")):
        return TIER_CONSENSUS
    return TIER_SINGLE_MODEL


def decided_by_stamp(status: str | None, reason: str | None = None) -> str:
    """What `question_verdicts.decided_by` SHOULD say for this row.

    Used by state.py when it rebuilds the bank, so the column becomes an honest
    record of authorship instead of a restatement of the status prefix. Nothing
    reads the column for a decision — `authority_tier` re-derives from `reason`
    every time — so a stale bank is a cosmetic problem, never a correctness one.
    """
    tier = authority_tier(status, reason)
    if tier == TIER_ADJUDICATED:
        return "deterministic" if (status or "") in DETERMINISTIC_STATUSES else "reviewer"
    if tier == TIER_CONSENSUS:
        return "consensus"
    if tier == TIER_DETERMINISTIC:
        return "deterministic"
    return "model"


def _selftest() -> int:
    bad = 0

    def T(name, got, want):
        nonlocal bad
        if got == want:
            print(f"  ok    {name}")
        else:
            print(f"  X     {name}   got {got!r} want {want!r}")
            bad += 1

    T("a bare model rejection is single-model",
      authority_tier("llm_rejected", "llm: different food"), TIER_SINGLE_MODEL)
    T("MUST FIRE  a re-banked model rejection is STILL single-model",
      authority_tier("llm_rejected",
                     "banked: banked: banked: llm: different food"), TIER_SINGLE_MODEL)
    T("a reviewer rejection is adjudicated",
      authority_tier("llm_rejected", "reviewer REJECT: prepared chili"), TIER_ADJUDICATED)
    T("MUST FIRE  a re-banked reviewer rejection is adjudicated",
      authority_tier("llm_rejected",
                     "banked: banked: reviewer REJECT: prepared chili"), TIER_ADJUDICATED)
    T("a reviewer confirmation is adjudicated",
      authority_tier("llm_confirmed", "reviewer CONFIRM: a rye loaf"), TIER_ADJUDICATED)
    T("known_wrong is adjudicated even with no reason at all",
      authority_tier("known_wrong", None), TIER_ADJUDICATED)
    T("retro-applied known-wrong is adjudicated",
      authority_tier("known_wrong", "retro-applied: absolute ruling"), TIER_ADJUDICATED)
    T("MUST FIRE  decided_by='model' is NOT trusted (state.py stamps it on reviewers too)",
      authority_tier("llm_rejected", "reviewer REJECT: x", "model"), TIER_ADJUDICATED)
    T("an informative decided_by wins",
      authority_tier("llm_rejected", None, "consensus"), TIER_CONSENSUS)
    T("MUST FIRE  an unrecognised reason is single-model, never precedent",
      authority_tier("llm_rejected", "something nobody wrote a parser for"),
      TIER_SINGLE_MODEL)
    T("MUST FIRE  an EMPTY reason is single-model, never precedent",
      authority_tier("llm_rejected", ""), TIER_SINGLE_MODEL)
    T("a deterministic status is deterministic",
      authority_tier("include_hit", "include pattern matched"), TIER_DETERMINISTIC)
    T("strip_banked leaves a clean reason alone",
      strip_banked("llm: x"), "llm: x")
    T("strip_banked removes every prefix, not just one",
      strip_banked("banked: banked: banked: llm: x"), "llm: x")
    T("stamp: reviewer ruling", decided_by_stamp("llm_rejected", "reviewer REJECT: x"),
      "reviewer")
    T("stamp: model ruling", decided_by_stamp("llm_rejected", "llm: x"), "model")
    T("stamp: known_wrong", decided_by_stamp("known_wrong", "adjudicated: x"), "reviewer")

    if bad:
        print(f"authority SELF-TEST FAIL ({bad})")
        return 2
    print("authority SELF-TEST PASS")
    return 0


if __name__ == "__main__":
    import sys
    raise SystemExit(_selftest() if "--selftest" in sys.argv else _selftest())
