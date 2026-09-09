"""Promote SHADOW-GATED learned aliases into the legacy catalog.

    python graph/learning/promote_aliases.py --dry-run
    python graph/learning/promote_aliases.py

THE ONE PLACE THE GRAPH WRITES BACK, and it needs its reason stated plainly.

Every other importer in this estate runs dual-write: the legacy PowerShell path
stays authoritative and the graph is a shadow that never touches it. That
doctrine is what made the graph safe to build. It also, silently, made the
learning loop useless to the thing customers actually read.

Measured 2026-08-21: 156 include patterns exist ONLY in graph.db, every one of
them proposed by Stage 1, checked against the whole corpus by
alias_blast_radius, reviewed, and applied only after the shadow gate scored it
against the gold set with no regression. The live board reads
grocery/commodities.json and had received none of them.

That is why Family Fare's whole-cloves cell read $11.92/oz. The board matched
exactly ONE clove product; the graph matched three, including a $2.99/oz jar,
because the graph holds a `cloves?,\\s*whole` pattern the catalog does not. Not
a precedence bug, not a curated pin, not a comma bug — the board was never told
what the loop learned. 118 commodities are in that state.

WHAT THIS PROMOTES, and nothing else:
  * kind='include' aliases whose source is 'learning-patch' — i.e. they came
    through Stage 1 -> blast radius -> review -> shadow gate. A hand-added
    alias or an import artefact is not eligible; if it is not in
    commodities.json already, that was somebody's decision.
  * only for commodities that exist in commodities.json under their legacy id.

WHAT IT REFUSES:
  * a pattern that will not compile, or that carries a control character (see
    stage2_review.payload_is_sane — \\b is legal JSON for backspace, so a
    word-boundary pattern can arrive inert and look healthy).
  * a duplicate of a pattern the catalog already has.
  * anything listed in promotion-holds.json. THIS IS THE IMPORTANT ONE. The
    first promotion (2026-08-21) put all 156 in and the guard suite went
    hard=0 -> hard=10: unit-basis outliers where the newly-matched product's
    own link disagreed with the board, one alias that cross-claimed another
    commodity's cell, and one that crowned a fl-oz product on a weight row.
    Passing the shadow gate is NOT passing the guard suite — the gold set does
    not know what a per-unit basis is. 141 promoted clean; those 15 are held
    with their measured reason. Do not clear an entry without re-running
    compare-deals + guards and reading the diff.

It writes ONLY commodities.json's `include` arrays. It never edits excludes,
never reorders, never reformats another field. Run --dry-run first, then diff
the rebuilt board before deploying: the guard suite is the real gate here, not
this script's own opinion.
"""

from __future__ import annotations

import argparse
import collections
import io
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

from graphdb import REPO_ROOT                              # noqa: E402

CATALOG = os.path.join(REPO_ROOT, "grocery", "commodities.json")
DB = os.path.join(REPO_ROOT, "graph", "sqlite", "graph.db")
HOLDS = os.path.join(HERE, "promotion-holds.json")


def held() -> dict[tuple[str, str], str]:
    """(commodity, pattern) -> why the guard suite threw it out."""
    if not os.path.exists(HOLDS):
        return {}
    with open(HOLDS, encoding="utf-8-sig") as fh:
        doc = json.load(fh)
    return {(h["commodity"], h["pattern"]): h["reason"] for h in doc.get("holds", [])}


def classify_hold(pattern: str, learned_pats, catalog_pats, board_items):
    """One hold against today's world. Pure, so the fixtures drive the whole verdict (backlog I92).

    Returns (still_learned, in_catalog, hits) where hits is a list of matching board items, or
    None when the pattern will not compile.

    THE THREE THINGS THAT MUST NOT COLLAPSE INTO EACH OTHER, because each means something different
    and each has a different repair:
      * an UNPARSEABLE pattern returns None, never [] - "this regex is broken" and "this regex
        matches nothing" are different findings, and reporting the first as the second would quietly
        retire a hold because its own pattern rotted.
      * an EMPTY board returns [] here, and the CALLER is responsible for saying BLIND rather than
        inert - grocery/out/comparison-*.json is gitignored, so a worktree has no board and would
        otherwise report every hold as harmless.
      * still_learned is about the LEARNER, in_catalog about the CATALOG. A hold can be moot and
        contradicted at once, and those want opposite actions.
    """
    still = pattern in (learned_pats or [])
    incat = pattern in (catalog_pats or set())
    try:
        rx = re.compile(pattern, re.I)
    except re.error:
        return still, incat, None
    return still, incat, [it for it in (board_items or []) if it and rx.search(it)]


def classify_reason(reason: str) -> str:
    """Which KIND of claim is this hold's reason making? (2026-09-09, backlog I92, ruled by Brad.)

    THE DISTINCTION THAT DECIDES WHETHER A HOLD CAN EVER EXPIRE, and age does not:

      'identity'   - the pattern claims the WRONG PRODUCT. A cross-claim on another commodity's cell
                     is a statement about what the pattern MEANS, and no amount of board rebuilding
                     makes it true. kosher-salt's `salt,...kosher` matches "Sea Salt, Coarse, Kosher"
                     and always will. These must never be cleared by a timer or by inertness.
      'board'      - the pattern produced a number that disagreed with its own link ON ONE BOARD.
                     A unit-basis outlier is a statement about the products present that week, and
                     the board is rebuilt daily. These are the re-testable ones.
      'unclassed'  - anything else, including the generic auto-hold reason. Reported as unclassed
                     rather than guessed into a bucket: a hold whose reason cannot be read is not
                     evidence of anything, and calling it re-testable would be inventing permission.

    Pure, so the fixtures drive it.
    """
    r = (reason or "").lower()
    # Identity signals. All of these say the pattern pulls in the WRONG KIND of thing, which is a
    # property of the pattern and not of any week's products. `wrong form` and `measure-kind mismatch`
    # were added 2026-09-09 after the first live run filed shredded-cheese ("a MELTING cheese, name
    # never says shredded") and honey-mustard ("crowned a 128 fl oz cell on a weight-priced row") as
    # unclassed. Both are identity claims, and leaving them unclassed UNDERSTATED how many holds can
    # never expire - which is the direction that matters, since the cost of a wrong 'board' label is
    # re-arming a bad alias.
    for sig in ("cross-claim", "cross claim", "claims the", "wrong form", "measure-kind",
                "measure kind", "crowned a"):
        if sig in r:
            return "identity"
    # Board signals. `x factor` is the GUARD'S OWN wording for the same finding - audit-tile-integrity
    # prints "1.59x factor  balsamic-vinegar / Family Fare  board=... link=..." - and omitting it left
    # the two holds re-recorded on 2026-09-09 reading as unclassed. That is the second time wording
    # alone moved a hold between classes, which is this classifier's real limitation: it reads prose,
    # so it is only ever as good as the vocabulary the guards happen to use.
    if "unit-basis" in r or "unit basis" in r or "outlier" in r or "x factor" in r:
        return "board"
    return "unclassed"


def _board_week() -> str:
    """The board a hold was recorded against, so a later re-check knows what its reason was true OF.
    Returns '' when there is no board - a worktree or a clean checkout has none, and an empty string
    is honest where a guessed date would not be."""
    import glob as _glob
    cands = sorted(_glob.glob(os.path.join(REPO_ROOT, "grocery", "out", "comparison-*.json")))
    if not cands:
        return ""
    m = re.search(r"(\d{4}-\d{2}-\d{2})", os.path.basename(cands[-1]))
    return m.group(1) if m else ""


def recheck_holds(learned: dict, catalog) -> int:
    """--recheck-holds: WHICH HELD PATTERNS ARE STILL HELD AGAINST SOMETHING? (backlog I92.)

    THE SHAPE THIS FIXES. promotion-holds.json is a LATCHING ACTUATOR: it can only ever withhold
    more, holds never expire, and nothing re-tests them. Its reasons are statements about the
    COMPARISON BOARD ON ONE DAY - "1.59x unit-basis outlier vs its own link (Alessi 12.75 Oz)" - and
    the board is rebuilt daily. Every hold on file today was written 2026-08-21; the board has been
    rebuilt about eighteen times since. A held alias is an alias the identity graph never learns, so
    those are a standing, invisible loss for a reason that may have expired weeks ago.

    THIS WRITES NOTHING AND PROMOTES NOTHING, and it deliberately does NOT run the guard suite. It
    answers the cheap question that makes the expensive one worth asking: for each hold, is there
    still anything for it to be held against? Four independent signals, each with its denominator:

      age          days since it was held.
      still-learned  does the learner STILL propose this pattern? If it has stopped, the hold is
                   moot - it is refusing something nobody is offering.
      in-catalog   is the pattern ALREADY in commodities.json? Then the hold is being contradicted
                   by the catalog and one of the two is wrong.
      board-rows   how many rows on TODAY'S board the pattern matches, and what they are. Zero means
                   promoting it could not move a single cell today, so the hold is currently inert.

    A hold that is moot, contradicted or inert is a CANDIDATE for a human to clear - never an
    automatic clear. Clearing still means re-running the full guard suite, exactly as the file's own
    note says, and that ruling (automatic cadence versus on-demand) is Brad's and is not taken here.
    """
    if not os.path.exists(HOLDS):
        print("no promotion-holds.json - nothing is held, and that is not the same as nothing to check.")
        return 3
    with open(HOLDS, encoding="utf-8-sig") as fh:
        doc = json.load(fh)
    holds = doc.get("holds", [])
    if not holds:
        print("promotion-holds.json declares zero holds. Nothing to re-check.")
        return 0

    # today's board, for the inertness test. Its absence is BLIND, never "matches nothing":
    # grocery/out/comparison-*.json is gitignored, so a worktree or a clean checkout has no board
    # and would otherwise report every hold as inert - the confident wrong zero this estate keeps
    # paying for.
    board_rows, board_name = [], None
    import glob as _glob
    cands = sorted(_glob.glob(os.path.join(REPO_ROOT, "grocery", "out", "comparison-*.json")))
    if cands:
        board_name = os.path.basename(cands[-1])
        with open(cands[-1], encoding="utf-8-sig") as fh:
            for row in (json.load(fh).get("comparison") or []):
                for st in (row.get("stores") or []):
                    if st.get("item"):
                        board_rows.append((row.get("id"), st.get("item")))

    in_catalog = {}
    for c in catalog:
        in_catalog[c.get("id")] = set(c.get("include") or [])

    today = __import__("datetime").date.today()
    print(f"PROMOTION HOLDS - {len(holds)} pattern(s) across "
          f"{len({h['commodity'] for h in holds})} commodities")
    if board_name:
        print(f"board read for the inertness test: {board_name}, {len(board_rows)} store row(s)")
    else:
        print("BOARD IS ABSENT (grocery/out/comparison-*.json is gitignored) - the board column below")
        print("is BLIND, not zero. Do not read 'inert' off this run.")
    print()
    print(f"{'commodity':<22} {'age':>5}  {'why':<10} {'learned':<8} {'in-cat':<7} {'board':<6} pattern")
    print("-" * 104)

    moot = contradicted = inert = 0
    by_class = {"identity": 0, "board": 0, "unclassed": 0}
    for h in holds:
        cid, pat = h.get("commodity"), h.get("pattern")
        try:
            age = (today - __import__("datetime").date.fromisoformat(str(h.get("held"))[:10])).days
            age_s = f"{age}d"
        except Exception:
            age_s = "?"          # 'gated-run' and friends carry no date - that is I92's other half
        still, incat, hits = classify_hold(
            pat, learned.get(cid), in_catalog.get(cid, set()),
            [item for (_rid, item) in board_rows])
        if not still:
            moot += 1
        if incat:
            contradicted += 1
        if board_rows and hits is not None and not hits:
            inert += 1
        hit_s = "n/a" if not board_rows else ("BADRX" if hits is None else str(len(hits)))
        klass = classify_reason(h.get("reason"))
        by_class[klass] = by_class.get(klass, 0) + 1
        print(f"{cid:<22} {age_s:>5}  {klass:<10} {str(still):<8} {str(incat):<7} {hit_s:<6} {pat[:44]}")
        if hits:
            print(f"{'':<22} {'':>5}  would newly claim e.g. {hits[0][:64]!r}")

    print("-" * 104)
    n = len(holds)
    print(f"MOOT         (the learner no longer proposes it) : {moot} of {n}")
    print(f"CONTRADICTED (already in commodities.json)       : {contradicted} of {n}")
    if board_rows:
        print(f"INERT TODAY  (matches no row on today's board)   : {inert} of {n}")
    else:
        print(f"INERT TODAY  : NOT MEASURED - no board in this checkout")
    print()
    print(f"REASON CLASS - identity {by_class['identity']}, board {by_class['board']}, "
          f"unclassed {by_class['unclassed']}, of {n}")
    print("  identity  = the pattern claims the WRONG PRODUCT. No amount of board rebuilding makes")
    print("              that true, so these can NEVER expire and must not be cleared by a timer.")
    print("  board     = it disagreed with its own link on ONE board, weeks ago. The board is rebuilt")
    print("              daily, so these are the re-testable ones - the only real candidates here.")
    print("  unclassed = the reason could not be read. Reported as such rather than guessed into a")
    print("              bucket, because calling it re-testable would be inventing permission.")
    print()
    print("NOTHING WAS CLEARED AND NOTHING WAS PROMOTED. A hold that is moot, contradicted or inert")
    print("is a CANDIDATE for review, not a verdict: clearing one still means re-running the full")
    print("guard suite, which is what the file's own note has always said.")
    print("RULED 2026-09-09 (backlog I92): this READ runs on a cadence from the daily chain; the")
    print("CLEAR never does. A hold that ages out on a timer would have re-armed the kosher-salt")
    print("cross-claim on a live board, which is why the dangerous half stays human.")
    return 0


def eligible(db) -> dict[str, list[str]]:
    """legacy_id -> learned include patterns not already in the catalog."""
    legacy = {}
    for r in db.execute("SELECT id, properties_json FROM nodes WHERE type='Commodity'"):
        lid = (json.loads(r["properties_json"] or "{}")).get("legacy_id")
        if lid:
            legacy[r["id"]] = lid
    out: dict[str, list[str]] = collections.defaultdict(list)
    for r in db.execute("""SELECT node_id, alias FROM aliases
                           WHERE kind='include' AND source='learning-patch'"""):
        lid = legacy.get(r["node_id"])
        if lid:
            out[lid].append(r["alias"])
    return out


def _ps(script: str) -> tuple[int, str]:
    """Run a grocery PowerShell script, return (exit code, combined output)."""
    p = subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
         os.path.join(REPO_ROOT, "grocery", script)],
        capture_output=True, text=True, errors="replace", cwd=REPO_ROOT)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def blame(output: str, candidates: dict) -> set:
    """Which promoted commodities does the guard output accuse?

    Guards name a commodity three different ways depending on which audit fired -
    by id ('balsamic-vinegar / Family Fare'), by LABEL ('Honey Mustard  Sam's
    Club'), or only inside a product name. So rather than parse each audit's
    line shape, scan every HARD FAIL line for any id or label we just promoted
    to. Over-blaming costs one held alias; under-blaming costs a red tree.
    """
    labels = {}
    with open(CATALOG, encoding="utf-8-sig") as fh:
        for row in json.load(fh):
            if row.get("id") in candidates:
                labels[row["id"]] = str(row.get("label") or "")
    accused = set()
    for line in output.splitlines():
        if "HARD FAIL" not in line:
            continue
        low = line.lower()
        for cid in candidates:
            lab = labels.get(cid, "")
            if re.search(rf"\b{re.escape(cid)}\b", low) or (lab and re.search(
                    rf"(?<![\w-]){re.escape(lab.lower())}(?![\w-])", low)):
                accused.add(cid)
    return accused


def gated(learned, holds, max_rounds: int, accept_batch: bool = False) -> int:
    """promote -> guard -> withhold the accused -> repeat, until the tree is green.

    This is the loop I ran by hand on 2026-08-21: promote all 156, watch guards go
    hard=0 -> hard=10, bisect by commodity, re-run, repeat. Eight full
    compare-deals+guards cycles, about 45 minutes, and the only judgement involved
    was reading which commodity each HARD FAIL named. That is a script's job.

    The catalog is restored from its on-disk backup at the START of every round, so
    a round is never built on the previous round's edits, and a failure to converge
    leaves the tree exactly as it was found.
    """
    baseline_rc, baseline_out = _ps("guards.ps1")
    if baseline_rc != 0:
        print("REFUSING: guards is already failing before promotion.")
        print("A gate cannot attribute new failures when the baseline is red - fix the tree first.")
        for ln in baseline_out.splitlines():
            if "HARD FAIL" in ln:
                print("   " + ln.strip())
        return 2
    print("baseline: guards green\n")

    backup = CATALOG + ".pre-gate"
    shutil.copyfile(CATALOG, backup)
    skip: set = set()
    promoted_ok = False

    def restore() -> None:
        """Put the tree back the way it was found - INCLUDING what was derived from it.

        Restoring commodities.json alone is not restoring the system. The board
        (comparison-*.json) and the drift flags are built FROM the catalog, and the
        last thing every failing round does is build them from the aliases we are
        about to withdraw. Leave those in place and the next guard run reads a red
        tree that no longer matches any file on disk - which is exactly what the
        first version of this did: the follow-up run refused to start, correctly
        reporting a baseline failure for aliases that were no longer in the catalog.
        """
        shutil.copyfile(backup, CATALOG)
        _ps("compare-deals.ps1")
        _ps("audit-name-drift.ps1")

    try:
        for rnd in range(1, max_rounds + 1):
            shutil.copyfile(backup, CATALOG)
            with open(CATALOG, encoding="utf-8-sig") as fh:
                catalog = json.load(fh)
            added, _refused, _seen = promote_into(catalog, learned, holds, skip)
            total = sum(len(v) for v in added.values())
            if not total:
                # Every candidate failed the guard suite. That is a CONVERGED result, not an
                # aborted one: the tree is back at its green baseline and we know exactly which
                # aliases cannot go in. Recording that is the whole value of the run - the first
                # version of this returned here without calling record_holds, threw away two
                # verdicts it had just spent two guard cycles earning, and would have re-tested
                # them identically on the next run forever. Caught by the must-fire fixture.
                print("nothing left to promote once the withheld set is removed")
                record_holds(skip, {}, learned, accept_batch)
                return 1
            with io.open(CATALOG, "w", encoding="utf-8", newline="\n") as fh:
                json.dump(catalog, fh, indent=2, ensure_ascii=False)
            print(f"round {rnd}: promoting {total} alias(es) across {len(added)} commodities "
                  f"({len(skip)} withheld so far)")

            _ps("compare-deals.ps1")
            _ps("audit-name-drift.ps1")          # tile-integrity reads its output; see finding #1
            rc, out = _ps("guards.ps1")
            if rc == 0:
                print(f"  -> guards GREEN with {total} promoted, {len(skip)} withheld")
                record_holds(skip, added, learned, accept_batch)
                promoted_ok = True
                return 0

            accused = blame(out, added) - skip
            hard = [l.strip() for l in out.splitlines() if "HARD FAIL" in l]
            print(f"  -> guards FAILED ({len(hard)} hard). accused: {sorted(accused) or 'NOBODY'}")
            for ln in hard[:6]:
                print("     " + ln[:150])
            if not accused:
                # The failure exists but names no commodity we touched. Withholding at
                # random would be guessing; a human has to read this one.
                print("\n  STOPPING: guards fail but name no commodity this run promoted to.")
                print("  The tree is restored. Read the failures above - this is not an alias problem,")
                print("  or the audit reports it in a shape `blame` cannot see (widen it, do not guess).")
                return 2
            skip |= accused
        print(f"\nno convergence in {max_rounds} rounds; tree restored, nothing promoted")
        return 2
    finally:
        # ONE restore path, covering every exit including an exception or a Ctrl-C.
        # The earlier version restored only if the catalog had been left missing or
        # empty, so the three ordinary failure exits each announced "tree restored"
        # while leaving the last round's aliases in place. Green is the only
        # outcome that keeps its edits.
        if os.path.exists(backup):
            if not promoted_ok:
                restore()
            os.remove(backup)


# THE RATE LIMIT ON A ONE-DIRECTIONAL ACTUATOR (2026-09-09, backlog I93, ruled by Brad).
#
# `lib/ratchet.ps1` already carries this shape for the audits: a high-water mark that may only move
# one way gets a RATE LIMIT plus a SENSOR PLAUSIBILITY CHECK - it refuses a fall to zero and a fall
# larger than -MaxDropPct, KEEPS the old baseline, and reports. promotion-holds.json is the estate's
# other one-directional actuator (it can only ever withhold more, and holds never expire) and it had
# none of that. One degraded guard run that hard-failed naming many commodities would have written a
# permanent hold for every one of them in a single pass, with nothing calling that extraordinary.
#
# WHAT ELSE WAS TRIED: nothing. 10 is the FIRST PLAUSIBLE VALUE, not the survivor of a sweep. It is
# grounded on the live set - 16 held patterns across 10 commodities on 2026-09-08 - so a run adding
# more than 10 at once would grow the entire hold set by more than half, which is the shape of a
# broken guard rather than a normal batch. Nothing rules out 5 or 20 behaving as well.
MAX_NEW_HOLDS_PER_RUN = 10


def should_refuse_hold_batch(new_count: int, existing_count: int,
                             limit: int = MAX_NEW_HOLDS_PER_RUN) -> str:
    """'' when the batch is plausible, or the reason it is not. Pure, so the fixtures drive it.

    The asymmetry is deliberate and mirrors the ratchet: this actuator's dangerous direction is UP,
    because holds only accumulate. A small batch is always allowed; the check is on the jump.
    """
    if new_count <= limit:
        return ""
    return ("%d new hold(s) in one run, over the limit of %d, against %d already held. A jump this "
            "large reads as a degraded guard run rather than %d genuinely bad patterns. Holds are "
            "PERMANENT and nothing expires them, so the existing file is KEPT and nothing was "
            "written." % (new_count, limit, existing_count, new_count))


def record_holds(skip: set, added: dict, learned: dict, accept_batch: bool = False) -> None:
    """Write the withheld patterns to promotion-holds.json so a later run refuses them."""
    if not skip:
        return
    doc = {"note": "", "holds": []}
    if os.path.exists(HOLDS):
        with open(HOLDS, encoding="utf-8-sig") as fh:
            doc = json.load(fh)
    have = {(h["commodity"], h["pattern"]) for h in doc.get("holds", [])}

    # COUNT THE BATCH BEFORE WRITING ANY OF IT. Checking as we go would leave the file half-written
    # on refusal, which is worse than either outcome.
    pending = []
    for cid in sorted(skip):
        for pat in learned.get(cid, []):
            if (cid, pat) not in have:
                pending.append((cid, pat))
    why = should_refuse_hold_batch(len(pending), len(have))
    if why and not accept_batch:
        print("  PROMOTION HOLDS REFUSED: " + why)
        print("  Re-run with --accept-holds if this batch is genuine. This is the same shape")
        print("  lib/ratchet.ps1 applies to the audits: a one-directional actuator gets a rate")
        print("  limit and a plausibility bar, keeps its old state, and reports.")
        return
    if why and accept_batch:
        print("  --accept-holds: writing %d hold(s) despite the rate limit, on purpose." % len(pending))

    n = 0
    for cid in sorted(skip):
        for pat in learned.get(cid, []):
            if (cid, pat) in have:
                continue
            # A DATE, NOT THE LITERAL STRING "gated-run" (2026-09-08, backlog I92). A hold whose
            # `held` field carries no date can never be aged, so --recheck-holds cannot tell a hold
            # written this morning from one written in August - and the whole reason those holds are
            # a standing loss is that nobody can see how stale they are. `held_by` keeps the
            # provenance the old literal was carrying, in a field that is not also the timestamp.
            #
            # `board_week` IS THE HALF THAT MAKES AN AUTO-HOLD RE-TESTABLE AT ALL. The reason below
            # is generic on purpose - the gate said no, which is not a diagnosis - but a reason that
            # at least names WHICH BOARD it was true of can be re-checked against a later one. A
            # hold that records neither a cause nor a board is unfalsifiable, and that is what the
            # automatic path used to write.
            doc.setdefault("holds", []).append({
                "commodity": cid, "pattern": pat,
                "held": __import__("datetime").date.today().isoformat(),
                "held_by": "promote_aliases --gated",
                "board_week": _board_week(),
                "reason": "promote_aliases --gated: the guard suite hard-failed naming this "
                          "commodity, and went green once it was withheld"})
            n += 1
    with io.open(HOLDS, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(doc, fh, indent=2, ensure_ascii=False)
    print(f"  recorded {n} new hold(s) in {os.path.basename(HOLDS)}")
    print("  NOTE: the reasons are generic. Replace them with the measured cause before")
    print("        anyone tries to clear one - 'the gate said no' is not a diagnosis.")


def promote_into(catalog, learned, holds, skip: set) -> tuple[dict, list, int]:
    """Add every eligible pattern to `catalog` IN PLACE, except commodities in `skip`.

    Pure and re-runnable: callers hand it a freshly-loaded catalog each round, so
    growing `skip` is the only thing that changes between rounds.
    """
    added = collections.defaultdict(list)
    refused: list[tuple[str, str, str]] = []
    n_seen = 0
    for row in catalog:
        cid = row.get("id")
        if not cid or cid not in learned:
            continue
        have = list(row.get("include") or [])
        for pat in learned[cid]:
            n_seen += 1
            if pat in have:
                continue
            if cid in skip:
                refused.append((cid, pat, "WITHHELD by the gate this run"))
                continue
            if (cid, pat) in holds:
                refused.append((cid, pat, "HELD: " + holds[(cid, pat)]))
                continue
            bad = [c for c in pat if ord(c) < 32]
            if bad:
                refused.append((cid, pat, f"control character {bad[0]!r} — escape eaten in transit"))
                continue
            try:
                re.compile(pat, re.IGNORECASE)
            except re.error as e:
                refused.append((cid, pat, f"does not compile: {e}"))
                continue
            have.append(pat)
            added[cid].append(pat)
        if added.get(cid):
            row["include"] = have
    return added, refused, n_seen


def _selftest() -> int:
    """Frozen fixtures over classify_hold, the pure half of --recheck-holds (backlog I92).

    Every case is a real shape from promotion-holds.json as it stood 2026-09-08.
    """
    fails = []

    def T(name, cond, got=""):
        print(("  ok    " if cond else "  X     ") + name + ("" if cond else f"   got: {got}"))
        if not cond:
            fails.append(name)

    board = [
        "Our Family Sea Salt, Coarse, Kosher 16 Oz",
        "Fareway Balsamic Vinegar",
        "Member's Mark Pimento Stuffed Manzanilla Olives, 2 pk.",
        "Great Value Black Beans, 15 oz",
    ]

    # MUST FIRE - the founding case. kosher-salt was held because its pattern cross-claims the
    # sea-salt cell, and that row is STILL on the board, so the hold is still right. A recheck that
    # could not show this would be worse than none: it would invite clearing a correct hold.
    still, incat, hits = classify_hold(r"salt,\s*(?:[^,]*,\s*)?kosher", [r"salt,\s*(?:[^,]*,\s*)?kosher"], set(), board)
    T("MUST FIRE  a hold whose stated cause is STILL on the board reports its match, so a correct hold is not cleared",
      still and not incat and hits == ["Our Family Sea Salt, Coarse, Kosher 16 Oz"], f"hits={hits}")

    # MUST NOT FIRE - inert: nothing on the board matches, so promoting it could move no cell today.
    _, _, hits = classify_hold(r"\bbug\s+stop\b", [], set(), board)
    T("MUST NOT FIRE  a pattern matching NO board row reports zero hits - inert, and a candidate for review",
      hits == [], f"hits={hits}")

    # MUST FIRE - a broken pattern is None, NEVER []. Reporting it as 'matches nothing' would quietly
    # retire a hold because its own regex rotted.
    _, _, hits = classify_hold(r"olives(", ["x"], set(), board)
    T("MUST FIRE  an UNPARSEABLE pattern returns None, never an empty list - a broken regex and a regex that matches nothing are different findings",
      hits is None, f"hits={hits!r}")

    # The two axes are independent and must not collapse into each other.
    still, incat, _ = classify_hold("p", [], {"p"}, board)
    T("MUST FIRE  CONTRADICTED - a pattern already in the catalog is flagged even though the learner has stopped proposing it",
      incat and not still, f"still={still} incat={incat}")
    still, incat, _ = classify_hold("p", ["p"], set(), board)
    T("MUST NOT FIRE  a pattern the learner still proposes and the catalog lacks is neither moot nor contradicted",
      still and not incat, f"still={still} incat={incat}")

    # CLEAN TWIN - an EMPTY board yields [], and the CALLER must call that BLIND rather than inert.
    _, _, hits = classify_hold(r"balsamic", ["balsamic"], set(), [])
    T("CLEAN TWIN an empty board yields [] here; saying BLIND rather than 'inert' is the caller's job, and it does",
      hits == [], f"hits={hits}")
    _, _, hits = classify_hold(r"balsamic\b.{0,20}vinegar", [], set(), board)
    T("CLEAN TWIN matching is case-insensitive and substring, as the promoter's own patterns assume",
      hits == ["Fareway Balsamic Vinegar"], f"hits={hits}")
    still, incat, hits = classify_hold("p", None, None, None)
    T("CLEAN TWIN None inputs are treated as empty rather than throwing - a commodity with no learned patterns is normal",
      (not still) and (not incat) and hits == [], f"{still}/{incat}/{hits}")

    # ---- reason class (2026-09-09, backlog I92) --------------------------------------------------
    # MUST FIRE: the kosher-salt hold, verbatim. A cross-claim is about what the pattern MEANS, so it
    # can never expire, and a timer that cleared it would have re-armed a known-wrong claim on a live
    # board. This is the case that decided the whole ruling.
    T("MUST FIRE  a cross-claim reason is 'identity' - it can never expire",
      classify_reason('guards 2026-08-21: cross-claims the sea-salt cell ("Sea Salt, Coarse, Kosher")')
      == "identity", classify_reason("cross-claims the sea-salt cell"))

    # MUST FIRE: a unit-basis outlier is a statement about ONE board, and the board is rebuilt daily.
    T("MUST FIRE  a unit-basis outlier is 'board' - re-testable, because the board moved",
      classify_reason("guards 2026-08-21: 1.59x unit-basis outlier vs its own link (Alessi 12.75 Oz)")
      == "board", classify_reason("1.59x unit-basis outlier"))

    # MUST NOT FIRE: the generic auto-hold reason must NOT be read as re-testable. Guessing it into
    # the 'board' bucket would invent permission to clear a hold nobody diagnosed.
    T("MUST NOT FIRE  the generic auto-hold reason is 'unclassed', never 'board'",
      classify_reason("promote_aliases --gated: the guard suite hard-failed naming this commodity, "
                      "and went green once it was withheld") == "unclassed",
      classify_reason("promote_aliases --gated: the guard suite hard-failed"))
    T("MUST NOT FIRE  an empty reason is unclassed, not identity", classify_reason("") == "unclassed",
      classify_reason(""))

    # MUST FIRE: the two real reasons that came back unclassed on the first live run. Both say the
    # pattern pulls in the wrong KIND of thing, which no board rebuild can fix.
    T("MUST FIRE  'wrong FORM' is identity - a melting cheese is not a shredded one on any board",
      classify_reason("match-soundness 2026-08-21: pulled La Morenita Queso Quesadilla (a MELTING "
                      "cheese, name never says shredded) into the shredded row - wrong FORM")
      == "identity", classify_reason("wrong FORM"))
    T("MUST FIRE  a measure-kind mismatch is identity, not a board accident",
      classify_reason("guards 2026-08-21: crowned a 128 fl oz cell on a weight-priced row "
                      "(measure-kind mismatch)") == "identity", classify_reason("measure-kind mismatch"))
    T("MUST NOT FIRE  a None reason does not throw", classify_reason(None) == "unclassed", "threw")

    # MUST FIRE: the guard's own wording for the same finding. Frozen from the 2026-09-09 re-test,
    # which recorded "1.59x factor" and was read as unclassed until this signal was added.
    T("MUST FIRE  the guard's own 'x factor' wording is a board reason too",
      classify_reason("guards 2026-09-09 RE-TEST: 1.59x factor, balsamic-vinegar / Family Fare, "
                      "board=0.2465 link=0.3914") == "board", classify_reason("1.59x factor"))

    # CLEAN TWIN: classification is case-insensitive, so a reason written in caps is not unclassed.
    T("CLEAN TWIN  the match is case-insensitive",
      classify_reason("1.59X UNIT-BASIS OUTLIER") == "board", classify_reason("1.59X UNIT-BASIS OUTLIER"))

    # ---- the rate limit on the hold actuator (2026-09-09, backlog I93) --------------------------
    # MUST FIRE: the founding hazard. One degraded guard run naming many commodities would have
    # written a permanent hold for every one of them in a single pass.
    T("MUST FIRE  a batch over the limit is REFUSED, and the existing file is kept",
      should_refuse_hold_batch(25, 16) != "", should_refuse_hold_batch(25, 16))
    T("and the refusal says how many, against how many already held",
      "25" in should_refuse_hold_batch(25, 16) and "16" in should_refuse_hold_batch(25, 16),
      should_refuse_hold_batch(25, 16))

    # MUST NOT FIRE: an ordinary batch is allowed, or the actuator stops working entirely.
    T("MUST NOT FIRE  a small batch is allowed", should_refuse_hold_batch(3, 16) == "",
      should_refuse_hold_batch(3, 16))
    T("MUST NOT FIRE  a batch exactly AT the limit is allowed, not refused",
      should_refuse_hold_batch(MAX_NEW_HOLDS_PER_RUN, 16) == "",
      should_refuse_hold_batch(MAX_NEW_HOLDS_PER_RUN, 16))
    T("MUST FIRE  one over the limit is refused, so the boundary is where it says it is",
      should_refuse_hold_batch(MAX_NEW_HOLDS_PER_RUN + 1, 16) != "", "not refused")

    # MUST NOT FIRE: the FIRST batch against an empty file is not special-cased into a refusal - a
    # brand-new holds file legitimately starts at zero.
    T("MUST NOT FIRE  a first small batch against an empty holds file is allowed",
      should_refuse_hold_batch(2, 0) == "", should_refuse_hold_batch(2, 0))

    # CLEAN TWIN: the limit is the one written in the source, not one derived from the data it sees.
    T("CLEAN TWIN  the limit is the constant declared above the run, not inferred",
      MAX_NEW_HOLDS_PER_RUN == 10, str(MAX_NEW_HOLDS_PER_RUN))

    if fails:
        print(f"SELF-TEST FAIL: {len(fails)} case(s)")
        return 1
    print("SELF-TEST PASS: 24 case(s) resolved - 10 must-fire, 8 must-not-fire, 5 clean twins. Led by "
          "the founding one (a hold whose cause is still on the board keeps its evidence) and, since "
          "backlog I93, by the rate limit that refuses an implausibly large hold batch rather than "
          "latching every one of them permanently in a single pass")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--gated", action="store_true",
                    help="promote, run the guard suite, withhold whatever it fails on, repeat until green")
    ap.add_argument("--max-rounds", type=int, default=6)
    ap.add_argument("--recheck-holds", action="store_true",
                    help="report which held patterns are still held against anything. Read-only: "
                         "promotes nothing, clears nothing, and does not run the guard suite.")
    ap.add_argument("--accept-holds", action="store_true",
                    help="write a hold batch that exceeds the rate limit, on purpose (I93)")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    # BEFORE THE DATABASE CONNECT, on purpose: the suite must run on the pinned interpreter with no
    # graph.db present, which is what run-gates gives it.
    if args.selftest:
        return _selftest()

    db = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    learned = eligible(db)
    holds = held()

    if args.gated:
        return gated(learned, holds, args.max_rounds, args.accept_holds)

    with open(CATALOG, encoding="utf-8-sig") as fh:
        catalog = json.load(fh)

    if args.recheck_holds:
        return recheck_holds(learned, catalog)

    added, refused, n_seen = promote_into(catalog, learned, holds, set())
    total = sum(len(v) for v in added.values())
    print(f"learned patterns examined : {n_seen}")
    print(f"already in the catalog    : {n_seen - total - len(refused)}")
    print(f"REFUSED                   : {len(refused)}")
    for cid, pat, why in refused[:10]:
        print(f"    {cid:<24}{pat[:34]!r:<38}{why}")
    print(f"to promote                : {total} across {len(added)} commodities")
    for cid, pats in list(added.items())[:10]:
        print(f"    {cid:<24}{len(pats)}  e.g. {pats[0][:44]!r}")

    if args.dry_run:
        print("\n(dry run — commodities.json untouched)")
        return 0
    if not total:
        print("\nnothing to promote")
        return 0

    with io.open(CATALOG, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(catalog, fh, indent=2, ensure_ascii=False)
    print(f"\nwrote {CATALOG}")
    print("NEXT, and not optional: re-run compare-deals + guards + audit-known-wrong")
    print("and diff the board before deploying. This script's opinion is not the gate.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
