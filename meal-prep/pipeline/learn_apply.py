r"""
learn_apply.py - the ENCODE pen for ingredient identity (PLAN-ingredient-memory-2026-08-25, D1/D2).

THE CHANGE THIS FILE IS. The estate already had an ingredient identity memory:
`meal-prep\db\ingredient-resolutions.json`, consulted as step 1 of the per-line resolution ladder
on EVERY recipe (map-preresolve.ps1's "1. THE PRIOR RULING FIRST"). It had been frozen at 23 rows
since 2026-08-16T13:45:42, because nothing called its writer. The writer existed, was mutexed
(Global\tc-ingredient-resolutions-*), handled supersede-by-key, and was fixtured for 4-way
concurrency - with zero callers. So every map dispatch re-derived answers the estate had already
paid a frontier session for, and every ruling died in its run dir.

This file is that caller, and it is the ledger's ONLY programmatic one. It does two things:

  * WRITES AN EVENT for every mapper residual ruling, every registrar ruling, every QA mapper-fail,
    every supersede, every invalidation and every morning review verdict -
    `meal-prep\db\ingredient-events.jsonl`, append-only, content-addressed, git-tracked. A veto that
    leaves no event is the same sin as the 44 decide-rejections that vanished on 2026-08-15.
  * PROJECTS the clean rulings into the ledger, through `ingredient-resolutions.ps1 -Record` and
    never by writing the file itself - the mutex and the envelope live in that script.

WHAT NEVER BECOMES A CACHE ROW, and it is the load-bearing half. `rejected` and `not-purchased` are
judgments about a LINE IN A RECIPE, not about the term's identity; `mapped-null` is a real food with
no commodity id; a bid no namespace carries and no registrar approved is an unminted id; an
unexplained ruling has nothing for the next reader to check. Every one of those is an EVENT with a
named `held_reason` and `projected: false`. The ledger keeps the invariant it has today: every row
carries evidence.

  <py> learn_apply.py --selftest
  <py> learn_apply.py --append-event <json-file-or-'-'> [--events e]
  <py> learn_apply.py --apply-reviews <verdicts.json> [--store s] [--events e]

EXIT CODES (section 4.5): 0 clean / 1 findings / 2 could-not-run. Marker LEARN-APPLY-COMPLETE.
INTERPRETER: C:\Codex\Python312\python.exe (bare `python` is the Windows Store shim, exit 49).
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import sys
import tempfile
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
REPO = os.path.dirname(MP)
sys.path.insert(0, HERE)

import hunt_lib                                                   # noqa: E402

RESOLUTIONS_PS = os.path.join(HERE, "ingredient-resolutions.ps1")
STORE = os.path.join(MP, "db", "ingredient-resolutions.json")
EVENTS = os.path.join(MP, "db", "ingredient-events.jsonl")
VOCAB = os.path.join(MP, "db", "ingredients.json")

# The three commodity NAMESPACES, exactly as map-preresolve.ps1's Get-CommodityIds reads them - and
# read for the same corrected reason: the first build of that gate asked db\ingredients.json (the
# recipe VOCABULARY) whether a bid was new and refused `brown-lentils`, a LIVE board id priced at 5
# of 7 stores. "Which existing NAME does this resolve to" and "which existing ID prices it" are
# different questions with different answers. The registrar gate is about the second.
COMMODITY_FILES = ("grocery/commodities.json",
                   "grocery/recipe-commodities.json",
                   "grocery/out/recipe-board-everyday.json")

# ONE marshalling road, the same one decide_apply takes. `-File` cannot bind a multi-element
# [string[]] from argv at all - that is the transport half of the B8 class, frozen as a must-fire in
# decide_apply's suite. Never subprocess + -File from here.
run_ps = hunt_lib.ps_invoke

# The event schema is FROZEN (plan 3.1). Every field is always present, null or empty rather than
# omitted: a reader of the JSONL must never have to tell "the field was absent" from "the field was
# empty", and a downstream GROUP BY over a missing key silently drops the row.
#
# **CORRECTED** on the count only: plan 3.1 says "ALL 14 fields" and then lists SIXTEEN keys in its
# own frozen JSON block (event_id, at, run, slug, kind, key, term, raw, decision, bid, predicted,
# surprise, projected, held_reason, evidence, by). The KEYS are the spec and are implemented
# verbatim; the number in the prose was miscounted. 15 below plus event_id, which is derived.
EVENT_FIELDS = ("at", "bid", "by", "decision", "evidence", "held_reason", "key",
                "kind", "predicted", "projected", "raw", "run", "slug", "surprise", "term")
EVENT_KINDS = ("ruling", "registrar", "qa_mapper_fail", "supersede", "invalidate", "review")

PROJECTING_DECISIONS = ("mapped", "mapped-optional")


def now_stamp():
    """hunt-run's own stamp format: local, no zone, sortable. The ledger writes the same shape."""
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


# =====================================================================================================
# KEY NORMALISATION - byte-identical to Get-TermKey, or the cache silently never hits
# =====================================================================================================

_NOT_KEY = re.compile(r"[^a-z0-9 ]")
_WS = re.compile(r"\s+")


def term_key(t):
    r"""`Get-TermKey`, in Python. It exists TWICE in PowerShell already
    (ingredient-resolutions.ps1 and map-preresolve.ps1) and both copies carry the same note: the
    cache is KEYED by this function's output, so a second spelling of it is a cache that never hits
    and nobody notices, because a miss and a cold cache look identical from the outside.

    The PS body, in order, and this mirrors it step for step:
        $t = $T.ToLower().Trim()
        $t = $t -replace '[^a-z0-9 ]', ' '
        $t = $t -replace '\s+', ' '
        return $t.Trim()

    NORMALISE THE INCIDENTAL, KEEP THE MEANINGFUL. Punctuation becomes a SPACE rather than being
    deleted, so "it's" is "it s" and never "its"; and no word is ever dropped, so 'beef steak' and
    'shaved beef steak' stay different questions.
    """
    if t is None:
        return ""
    s = str(t).lower().strip()
    s = _NOT_KEY.sub(" ", s)
    s = _WS.sub(" ", s)
    return s.strip()


# The PS function body, quoted once, so the cross-language pin runs the REAL text rather than a
# paraphrase of it. Kept beside term_key on purpose: an edit to one that forgets the other is the
# whole failure this pin exists to catch.
PS_TERMKEY_BODY = "\n".join([
    "param([string[]]$T=@())",
    "function Get-TermKey {",
    "  param([string]$T)",
    "  if (-not $T) { return '' }",
    "  $t = $T.ToLower().Trim()",
    "  $t = $t -replace '[^a-z0-9 ]', ' '",
    "  $t = $t -replace '\\s+', ' '",
    "  return $t.Trim()",
    "}",
    "foreach ($x in @($T)) { Write-Output ('<' + (Get-TermKey $x) + '>') }",
    "exit 0",
    ""])


def ps_term_keys(terms):
    """Run the PowerShell Get-TermKey body over `terms`. Returns (keys, why_not).

    Through hunt_lib.ps_invoke, which is the only road: a multi-element [string[]] cannot be bound
    by `-File` at all, and the whole point here is handing SIX strings to one invocation.
    """
    d = tempfile.mkdtemp(prefix="termkey-pin-")
    try:
        p = os.path.join(d, "tk.ps1")
        with io.open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(PS_TERMKEY_BODY)
        rc, out, err = run_ps(p, ["-T", list(terms)], timeout=120)
        if rc != 0:
            return None, ("exit %s: %s" % (rc, ((out or "") + (err or "")).strip()[:160]))
        keys = re.findall(r"<([^>]*)>", (out or "").replace("\r", ""))
        if len(keys) != len(terms):
            return None, "the shell returned %d key(s) for %d term(s)" % (len(keys), len(terms))
        return keys, ""
    finally:
        shutil.rmtree(d, ignore_errors=True)


# =====================================================================================================
# The estate, read
# =====================================================================================================

def _read_json(path):
    try:
        with io.open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f), ""
    except Exception as e:                                        # noqa: BLE001
        return None, str(e)[:160]


def known_bids(repo=REPO):
    """Every commodity id the estate already prices, across all THREE namespaces. (ids, why_not).

    A read that COULD NOT RUN is reported, never collapsed into "no ids": the could-not-look-is-not-
    a-clean-bill rule. With an empty set every bid would look new and nothing would ever project,
    which is the safe direction but must be VISIBLE rather than silent.
    """
    ids, misses = set(), []
    for rel in COMMODITY_FILES:
        doc, why = _read_json(os.path.join(repo, rel.replace("/", os.sep)))
        if doc is None:
            misses.append("%s (%s)" % (rel, why))
            continue
        rows = doc
        if isinstance(doc, dict):
            rows = doc.get("commodities") or doc.get("comparison") or []
        for r in (rows if isinstance(rows, list) else []):
            if not isinstance(r, dict):
                continue
            for f in ("id", "bid", "commodity_id"):
                if str(r.get(f) or "").strip():
                    ids.add(str(r[f]).strip())
                    break
    return ids, ("could not read " + "; ".join(misses) if misses else "")


def wired_bids(vocab=VOCAB):
    """Every bid db\\ingredients.json actually wires. (bids, ok).

    This is what `-BidExists` is a fact ABOUT - the WIRING, never a price - so when the file cannot
    be read the switch is OMITTED rather than guessed either way. A row claiming `bid_exists: true`
    on a hunch is worse than a row that does not claim it: the mapper uses that flag to decide
    whether a recipe holds at `mapped` instead of dying at the audit.
    """
    doc, why = _read_json(vocab)
    if doc is None:
        return set(), False
    rows = doc if isinstance(doc, list) else (doc.get("ingredients") or [])
    out = set()
    for r in (rows if isinstance(rows, list) else []):
        if isinstance(r, dict) and str(r.get("bid") or "").strip():
            out.add(str(r["bid"]).strip())
    return out, True


def read_ledger(store=STORE):
    """(rows_by_key, count, why_not). A missing ledger is an empty one; an UNREADABLE one says so."""
    if not os.path.exists(store):
        return {}, 0, ""
    doc, why = _read_json(store)
    if doc is None:
        return {}, 0, why
    rows = (doc or {}).get("resolutions") or []
    by_key = {}
    for r in rows:
        if isinstance(r, dict) and str(r.get("key") or ""):
            by_key[str(r["key"])] = r
    return by_key, len(rows), ""


# =====================================================================================================
# The event log
# =====================================================================================================

def event_id(kind, key, slug, decision, bid, evidence):
    """Content-addressed, over exactly the six fields plan 3.1 names.

    APPENDING THE SAME RULING TWICE WRITES ONE LINE, and that is what makes the whole log safe to
    re-run: a resumed run, a repaired recipe re-assembled, a double-ingest - none of them can inflate
    the count the falsification test in section 1 reads.
    """
    blob = json.dumps([kind, key, slug, decision, bid, evidence], sort_keys=True,
                      ensure_ascii=False, default=str)
    return "ie:" + hashlib.sha256(blob.encode("utf-8")).hexdigest()[:20]


def make_event(kind, slug, run="", key="", term="", raw="", decision="", bid="",
               predicted=None, surprise=False, projected=False, held_reason="", evidence="",
               by="daemon", at=""):
    """One event, all 14 fields, sorted on the way out. Never construct one by dict literal."""
    ev = {
        "at": at or now_stamp(),
        "bid": str(bid or ""),
        "by": str(by or ""),
        "decision": str(decision or ""),
        "evidence": str(evidence or ""),
        "held_reason": str(held_reason or ""),
        "key": str(key or ""),
        "kind": str(kind or ""),
        "predicted": {"source": str((predicted or {}).get("source") or "none"),
                      "bid": str((predicted or {}).get("bid") or "")},
        "projected": bool(projected),
        "raw": str(raw or ""),
        "run": str(run or ""),
        "slug": str(slug or ""),
        "surprise": bool(surprise),
        "term": str(term or ""),
    }
    ev["event_id"] = event_id(ev["kind"], ev["key"], ev["slug"], ev["decision"], ev["bid"],
                              ev["evidence"])
    return ev


class EventLog(object):
    r"""`meal-prep\db\ingredient-events.jsonl`, the graph\provenance\*.jsonl idiom.

    One sorted-keys JSON object per line, LF, ensure_ascii=False, APPEND ONLY. The ids already on
    disk are loaded ONCE per invocation - a per-append re-read would make a 3-recipe batch re-parse
    the whole log five times, and the log only ever grows.
    """

    def __init__(self, path=EVENTS):
        self.path = path
        self.ids = set()
        self.written = 0
        self.duplicates = 0
        self.why = ""
        self._loaded = False

    def load(self):
        if self._loaded:
            return
        self._loaded = True
        if not self.path or not os.path.exists(self.path):
            return
        try:
            with io.open(self.path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        self.ids.add(json.loads(line).get("event_id"))
                    except ValueError:
                        continue
        except Exception as e:                                    # noqa: BLE001
            self.why = str(e)[:160]

    def count(self):
        self.load()
        return len(self.ids)

    def append(self, ev):
        """'written' | 'duplicate' | 'failed'. Never raises - a broken pen is a finding, not a park."""
        self.load()
        if ev.get("event_id") in self.ids:
            self.duplicates += 1
            return "duplicate"
        try:
            d = os.path.dirname(self.path)
            if d and not os.path.isdir(d):
                os.makedirs(d, exist_ok=True)
            with io.open(self.path, "a", encoding="utf-8", newline="\n") as f:
                f.write(json.dumps(ev, sort_keys=True, ensure_ascii=False) + "\n")
        except Exception as e:                                    # noqa: BLE001
            self.why = str(e)[:160]
            return "failed"
        self.ids.add(ev["event_id"])
        self.written += 1
        return "written"


# =====================================================================================================
# The notes-vs-bid check (OPEN-ITEMS-recipe-hunter-2026-08-24 section 2.6, built)
# =====================================================================================================
#
# **CORRECTED** against PLAN-ingredient-memory 3.4's literal regex, and the correction is measured
# rather than stylistic. The plan freezes:
#
#     re.compile(r"(refus\w*|reject\w*|not\s+the|is\s+not)\W{0,80}" + re.escape(bid), re.I)
#
# `\W` matches only NON-word characters, so the gap between the refusal word and the id may contain
# spaces and punctuation but NOT A SINGLE LETTER. Run against the very evidence section 2.6 is
# written from -
#
#     "...Refused the chicken-thighs bridge on the standing 'leg quarters are not thighs'
#      precedent: drumsticks are a distinct cut ... so the thigh id would overprice and mis-weigh."
#
# - with bid `chicken-thighs`, the word "the" sits between "Refused" and the id, so `\W{0,80}`
# cannot reach it and the check DOES NOT FIRE on the only real example the estate has. A must-fire
# that cannot fire on its own founding case is gate theater.
#
# So the gap class is widened to "up to 80 characters that do not end the clause", `[^.;:!?]{0,80}?`,
# and the bound is doing the work the plan intended: the refusal has to be talking about THIS id, in
# THIS clause. Both halves are pinned below against the verbatim 2.6 text - the MUST-FIRE with bid
# `chicken-thighs` (the slip), and the CLEAN TWIN with bid `chicken-drumsticks` (the correct ruling
# 2.7 describes, whose id appears only after the colon that ends the refusal).
_REFUSE_HEAD = r"(refus\w*|reject\w*|not\s+the|is\s+not)"


def refuse_near_bid(bid):
    return re.compile(_REFUSE_HEAD + r"[^.;:!?]{0,80}?" + re.escape(str(bid)), re.I)


def notes_refuse_bid(evidence, bid):
    """Does this ruling's OWN evidence refuse the id it ruled?

    Reads the ruling's evidence and nothing else - it does not re-open the mapped files, because the
    contradiction 2.6 found is INSIDE one ruling: the prose refused `chicken-thighs` and the
    machine-readable field WAS `chicken-thighs`. Had it priced, the dish would have been costed from
    thigh rows, which is exactly the mispricing its own note forbids.
    """
    b = str(bid or "").strip()
    if not b or not evidence:
        return False
    return bool(refuse_near_bid(b).search(str(evidence)))


# =====================================================================================================
# The pen
# =====================================================================================================

def _predicted_for(table, key):
    """What the pre-resolve ladder SAID before the judge ruled: {'source','bid'}.

    `source` is the ladder rung that answered - map-preresolve stamps 'cache' | 'vocab' | 'alias' on
    the row - collapsed to the plan's three-value vocabulary. A residual line that nothing answered
    predicts NOTHING, which is not the same as predicting the empty string and must not read as a
    surprise later.
    """
    for r in ((table or {}).get("rows") or []):
        if not isinstance(r, dict):
            continue
        if term_key(r.get("term")) != key:
            continue
        src = str(r.get("source") or "").strip().lower()
        if src == "cache":
            source = "cache"
        elif src in ("vocab", "alias"):
            source = "vocab"
        else:
            source = "none"
        return {"source": source, "bid": str(r.get("bid") or "")}
    return {"source": "none", "bid": ""}


def _record(term, bid, evidence, slug, run, store, bid_exists, by="mapper"):
    """The ONE road to the ledger: ingredient-resolutions.ps1 -Record, through ps_invoke.

    NEVER a direct write of the JSON. The named mutex, the re-read INSIDE the lock, the
    supersede-by-key and the envelope (_doc / _rule / updated / count) all live in that script, and
    the map lane writes two-wide - the measured cost of skipping exactly this on source-domains was
    2,293 outcomes recorded as 65.
    """
    args = ["-Record", "-Term", str(term), "-ItemId", str(bid),
            "-Evidence", "%s [slug %s, run %s]" % (str(evidence).strip(), slug, run or "-"),
            "-By", by]
    if bid_exists:
        # A FACT ABOUT THE WIRING, not a guess. Omitted rather than asserted when the vocabulary
        # could not be read - see wired_bids.
        args.append("-BidExists")
    if store:
        args += ["-Store", store]
    return run_ps(RESOLUTIONS_PS, args, timeout=180)


def postcondition_finding(slug, summary, payload):
    """The 44-class postcondition, as a predicate so the CALL SITE and the fixtures share it.

    EVENTS WRITTEN == RULINGS RULED, or a finding names the gap. The proposal's "Events / mapped
    residuals = 1" metric, made mechanical: on 2026-08-15 forty-four decide rejections left no trace
    outside a run dir and the next run re-sourced every one of them, and the only reason anyone
    knows the number is that someone counted by hand afterwards.

    `events_written + events_skipped_duplicate` counts the PRIMARY events only - one per ruling plus
    one per registrar ruling. Supersede events are counted separately (`supersede_events`) precisely
    so they cannot mask a missing primary by inflating the total.
    """
    expected = len(((payload or {}).get("rulings") or [])) + \
        len(((payload or {}).get("registrar_rulings") or []))
    got = int(summary.get("events_written", 0)) + int(summary.get("events_skipped_duplicate", 0))
    if got == expected:
        return ""
    return ("%s: %d residual rulings but %d learn events - a ruling left no trace (the 44-class)"
            % (slug, expected, got))


def apply_learn(run_dir, slug, res, tables, payload, store="", events="", log=None, run_id=""):
    """Encode one slug's map result. Returns (summary, findings).

    ADVISORY, ALWAYS. Every problem here is a finding and none of them fails the assemble: memory
    must never block the lane. A broken pen is a finding, not a parked recipe.

    Called ONLY after `-Assemble` returned exit 0 (plan 3.2 rule 2). A ruling that failed assembly
    must not become memory - the run refused to build a decision file over it, and caching an
    identity the estate would not write down is worse than caching nothing.
    """
    findings = []
    store = store or ""
    lg = log if log is not None else EventLog(events or EVENTS)
    run = run_id or os.path.basename(str(run_dir or "").rstrip("\\/"))

    summary = {"events_written": 0, "events_skipped_duplicate": 0, "events_failed": 0,
               "supersede_events": 0, "projected": 0, "held": 0, "surprises": 0,
               "registrar_events": 0, "ruling_events": 0}

    def emit(ev, primary=True):
        how = lg.append(ev)
        if how == "written":
            if primary:
                summary["events_written"] += 1
            else:
                summary["supersede_events"] += 1
        elif how == "duplicate":
            if primary:
                summary["events_skipped_duplicate"] += 1
        elif how == "failed":
            summary["events_failed"] += 1
            findings.append("%s: an event could not be appended to %s (%s) - the ruling happened and "
                            "the log does not say so" % (slug, lg.path, lg.why or "unknown"))
        # ANY OTHER ANSWER IS COUNTED NOWHERE, AND THAT IS DELIBERATE. A writer that reports
        # something this counter does not recognise has not written and has not said it failed -
        # which is the 44-class in miniature. It is not papered over here; the postcondition at the
        # CALL SITE is the backstop that notices the gap, and the drill's dropping-writer fixture
        # drives exactly this path.
        if ev.get("surprise"):
            summary["surprises"] += 1
        return how

    # ---- pre-flight. The validator guards the PEN, not the dispatch (plan 3.5) ---------------------
    problems = hunt_lib.validate_map({"results": [res or {}]})
    if problems:
        findings.append("%s: the map result does not conform to the MAP contract, so nothing is "
                        "cached from it: %s" % (slug, "; ".join(problems[:4])))

    table = (tables or {}).get(slug) or {}
    rulings = list((payload or {}).get("rulings") or [])
    reg = [r for r in ((payload or {}).get("registrar_rulings") or []) if isinstance(r, dict)]
    reg_by_bid = {}
    for g in reg:
        pb = str(g.get("proposed_bid") or "").strip()
        if pb:
            reg_by_bid[pb] = g

    ids, why_ids = known_bids()
    if why_ids:
        findings.append("%s: the commodity namespaces could not all be read (%s) - a bid this run "
                        "cannot verify is held as an event, never cached" % (slug, why_ids))
    wired, wired_ok = wired_bids()
    ledger, _n, why_ledger = read_ledger(store or STORE)
    if why_ledger:
        findings.append("%s: the resolutions ledger could not be read (%s) - supersede detection is "
                        "BLIND for this slug" % (slug, why_ledger))

    # ---- 1. one event per residual ruling, and a projection for the clean ones --------------------
    for ru in rulings:
        if not isinstance(ru, dict):
            findings.append("%s: a ruling is not an object and left no event" % slug)
            continue
        term = str(ru.get("term") or "").strip()
        raw = str(ru.get("raw") or "")
        if not term:
            term = raw
        key = term_key(term)
        decision = str(ru.get("decision") or "").strip().lower()
        bid = str(ru.get("bid") or "").strip()
        evidence = str(ru.get("evidence") or "").strip()
        predicted = _predicted_for(table, key)
        summary["ruling_events"] += 1

        held = ""
        aliased = ""
        if decision not in PROJECTING_DECISIONS:
            held = "decision %s" % (decision or "(none)")
        elif not bid:
            held = "no bid ruled"
        elif not evidence:
            # The ledger's rows all carry evidence today. An unexplained ruling is a fact about a run,
            # not a memory anyone can later check, so it is recorded and never cached.
            held = "no evidence"
        elif notes_refuse_bid(evidence, bid):
            held = "notes refuse the bid"
        elif bid not in ids:
            g = reg_by_bid.get(bid) or {}
            verdict = str(g.get("verdict") or "").strip().lower()
            if verdict == "approve":
                pass
            elif verdict == "alias":
                aliased = str(g.get("bid") or "").strip()
                if not aliased or aliased not in ids:
                    held = "the registrar aliased '%s' to an id no namespace carries" % bid
            else:
                held = "bid unknown to every namespace"
        if problems:
            held = held or "the map result did not validate"

        prior = ledger.get(key) or {}
        prior_bid = str(prior.get("item_id") or "").strip()
        effective = aliased or bid
        surprise = bool(
            (predicted["bid"] and predicted["bid"] != effective)
            or held == "notes refuse the bid"
            or (prior_bid and effective and prior_bid != effective))

        ev = make_event("ruling", slug, run=run, key=key, term=term, raw=raw, decision=decision,
                        bid=effective, predicted=predicted, surprise=surprise,
                        projected=False, held_reason=held, evidence=evidence, by="mapper")
        if held:
            summary["held"] += 1
            emit(ev)
            if held == "notes refuse the bid":
                findings.append("%s: the ruling on '%s' refuses '%s' in its own evidence and bids it "
                                "anyway - not cached (OPEN-ITEMS 2.6)" % (slug, term, bid))
            continue

        rc, out, err = _record(term, effective, evidence, slug, run, store,
                               bid_exists=(wired_ok and effective in wired))
        if rc != 0:
            findings.append("%s: '%s' -> %s did not reach the resolutions ledger (exit %s: %s)"
                            % (slug, term, effective, rc, ((out or "") + (err or "")).strip()[:160]))
            ev["held_reason"] = "the ledger refused the write"
            emit(ev)
            continue

        ev["projected"] = True
        ev["event_id"] = event_id(ev["kind"], ev["key"], ev["slug"], ev["decision"], ev["bid"],
                                  ev["evidence"])
        summary["projected"] += 1
        emit(ev)

        # THE CACHE-CORRECTION LOOP, written down. -Record replaces by key, so a repair re-ruling
        # silently overwrites whatever the first pass believed. The supersede event is the only trace
        # that the estate ever thought otherwise.
        if prior_bid and prior_bid != effective:
            emit(make_event("supersede", slug, run=run, key=key, term=term, raw=raw,
                            decision=decision, bid=effective, predicted=predicted, surprise=True,
                            projected=True, held_reason="",
                            evidence="superseded '%s' -> '%s': %s" % (prior_bid, effective, evidence),
                            by="mapper"), primary=False)

    # ---- 2. one event per registrar ruling ---------------------------------------------------------
    # THE FIRST REGISTRAR LEDGER THIS ESTATE HAS. Its rulings decide whether a commodity is BORN and
    # they were invisible across runs: the verdict lived in one run dir and the next batch proposing
    # the same id asked again from scratch.
    for g in reg:
        pb = str(g.get("proposed_bid") or "").strip()
        emit(make_event("registrar", slug, run=run, key=term_key(pb), term=pb, raw="",
                        decision=str(g.get("verdict") or "").strip().lower(),
                        bid=str(g.get("bid") or "").strip() or pb,
                        predicted={"source": "none", "bid": ""},
                        surprise=False, projected=False,
                        held_reason="registrar rulings are never cached as identities",
                        evidence=str(g.get("reason") or ""), by="registrar"))
        summary["registrar_events"] += 1

    return summary, findings


def append_event(kind, slug, events="", **kw):
    """The sync one-event door, for callers that are not the map lane (QA fails, invalidations).

    Returns (how, event). Deliberately not a method on anything: the QA lane appends ONE event and
    must not construct an EventLog it then holds open across an await.
    """
    lg = EventLog(events or EVENTS)
    ev = make_event(kind, slug, **kw)
    return lg.append(ev), ev


def qa_fail_event(slug, findings_text, run="", residual_keys=None, why_keys="", events=""):
    r"""One `qa_mapper_fail` event: slug-level, key '', decision 'fail', by 'qa'.

    IT NEVER TOUCHES THE LEDGER. A QA fail is not a new identity - the correction loop is the repair
    re-ruling, which re-projects and leaves a `supersede` behind (plan 3.2). What this buys is that
    the day the cache is wrong, the log says which terms were in the recipe that failed.
    """
    keys = list(residual_keys or [])
    if keys:
        tail = " residual keys: %s" % ", ".join(keys)
    else:
        tail = " residual keys: %s" % (why_keys or "none listed")
    return append_event("qa_mapper_fail", slug, events=events, run=run, key="", term="", raw="",
                        decision="fail", bid="", predicted={"source": "none", "bid": ""},
                        surprise=False, projected=False,
                        held_reason="a QA fail is not an identity", by="qa",
                        evidence=(str(findings_text or "").strip() + tail).strip())


def residual_keys_for(run_dir, slug):
    r"""The slug's residual keys, from <RunDir>\mapped-pre\<slug>.rulings.json. (keys, why_not).

    ABSENT IS ANNOUNCED. "no residual keys" and "the file the keys live in was not there" are
    different facts, and the event says which.
    """
    p = os.path.join(str(run_dir or ""), "mapped-pre", "%s.rulings.json" % slug)
    doc, why = _read_json(p)
    if doc is None:
        return [], ("mapped-pre\\%s.rulings.json could not be read (%s)" % (slug, why))
    keys = []
    for ru in (doc.get("rulings") or []):
        if isinstance(ru, dict):
            k = term_key(ru.get("term") or ru.get("raw"))
            if k and k not in keys:
                keys.append(k)
    return keys, ""


# =====================================================================================================
# D4's morning apply verb (plan 6.2)
# =====================================================================================================

REVIEW_VERDICTS = ("record", "supersede", "leave")


def apply_reviews(verdicts_path, store="", events="", packet="", log=None):
    """Apply a REVIEWED verdicts file. Returns (summary, findings).

    THE ONLY PROMOTION ROAD. Nothing applies automatically at 3am: the nightly ingest emits a packet
    of held and contradicting cases and stops there, and a person rules on them in the morning. That
    is the same shape as the grocery learning loop's Stage 2 and it is deliberate - the one error the
    estate froze promotions over was a false merge ("fresh garlic" -> Ground Cloves, the $11.92/oz
    clove cell), and an automated promoter is exactly what would re-open it.

    A verdict on an event_id the packet never held is REFUSED LOUDLY, not applied: it is either a
    typo or a verdict about something nobody reviewed.
    """
    findings = []
    summary = {"recorded": 0, "left": 0, "refused": 0, "events_written": 0,
               "events_skipped_duplicate": 0}
    doc, why = _read_json(verdicts_path)
    if doc is None:
        return None, ["the verdicts file at %s could not be read (%s)" % (verdicts_path, why)]
    verdicts = doc.get("verdicts") if isinstance(doc, dict) else doc
    if not isinstance(verdicts, list) or not verdicts:
        return None, ["%s carries no `verdicts` array" % verdicts_path]

    known = {}
    pkt_path = packet or os.path.join(REPO, "graph", "learning", "hunter-review-packet.json")
    pkt, pkt_why = _read_json(pkt_path)
    if pkt is None:
        findings.append("the review packet at %s could not be read (%s) - every verdict is refused, "
                        "because a verdict nobody can attribute to a reviewed case is not a review"
                        % (pkt_path, pkt_why))
    else:
        for c in (pkt.get("cases") or []):
            for ev in ([c.get("event")] if isinstance(c, dict) else []):
                if isinstance(ev, dict) and ev.get("event_id"):
                    known[ev["event_id"]] = ev

    lg = log if log is not None else EventLog(events or EVENTS)
    for i, v in enumerate(verdicts):
        if not isinstance(v, dict):
            findings.append("verdict %d is not an object" % i)
            summary["refused"] += 1
            continue
        eid = str(v.get("event_id") or "").strip()
        kind = str(v.get("verdict") or "").strip().lower()
        item = str(v.get("item_id") or "").strip()
        evidence = str(v.get("evidence") or "").strip()
        src = known.get(eid)
        if not eid or src is None:
            findings.append("verdict %d names event_id %r, which this packet never held - REFUSED"
                            % (i, eid))
            summary["refused"] += 1
            continue
        if kind not in REVIEW_VERDICTS:
            findings.append("verdict %d on %s: %r is not one of %s - REFUSED"
                            % (i, eid, v.get("verdict"), ", ".join(REVIEW_VERDICTS)))
            summary["refused"] += 1
            continue
        if kind in ("record", "supersede") and not item:
            findings.append("verdict %d on %s: a %s needs an `item_id` - REFUSED" % (i, eid, kind))
            summary["refused"] += 1
            continue
        term = str(src.get("term") or "")
        key = str(src.get("key") or term_key(term))
        if kind == "leave":
            how = lg.append(make_event("review", str(src.get("slug") or ""), run="adjudication",
                                       key=key, term=term, raw=str(src.get("raw") or ""),
                                       decision="leave", bid="",
                                       predicted={"source": "none", "bid": ""}, surprise=False,
                                       projected=False, held_reason="reviewer left it unrecorded",
                                       evidence=evidence, by="adjudication"))
            summary["left"] += 1
        else:
            wired, wired_ok = wired_bids()
            rc, out, err = _record(term, item, evidence or "adjudicated in the morning packet",
                                   str(src.get("slug") or ""), "adjudication", store,
                                   bid_exists=(wired_ok and item in wired), by="adjudication")
            if rc != 0:
                findings.append("verdict %d on %s: the ledger refused the write (exit %s: %s)"
                                % (i, eid, rc, ((out or "") + (err or "")).strip()[:160]))
                summary["refused"] += 1
                continue
            how = lg.append(make_event("review", str(src.get("slug") or ""), run="adjudication",
                                       key=key, term=term, raw=str(src.get("raw") or ""),
                                       decision=kind, bid=item,
                                       predicted={"source": "none",
                                                  "bid": str(src.get("bid") or "")},
                                       surprise=(kind == "supersede"), projected=True,
                                       held_reason="", evidence=evidence, by="adjudication"))
            summary["recorded"] += 1
        if how == "written":
            summary["events_written"] += 1
        elif how == "duplicate":
            summary["events_skipped_duplicate"] += 1
    return summary, findings


# =====================================================================================================
# CLI
# =====================================================================================================

def cmd_append_event(a):
    src = a.append_event
    try:
        if src == "-":
            raw = sys.stdin.read()
        elif os.path.exists(src):
            with io.open(src, "r", encoding="utf-8-sig") as f:
                raw = f.read()
        else:
            raw = src
        obj = json.loads(raw)
    except Exception as e:                                        # noqa: BLE001
        print("learn_apply: CANNOT RUN - --append-event did not parse (%s)" % e)
        print("LEARN-APPLY-COMPLETE")
        return hunt_lib.EXIT_CANNOT_RUN
    kind = str(obj.get("kind") or "").strip()
    if kind not in EVENT_KINDS:
        print("learn_apply: CANNOT RUN - kind %r is not one of %s" % (kind, ", ".join(EVENT_KINDS)))
        print("LEARN-APPLY-COMPLETE")
        return hunt_lib.EXIT_CANNOT_RUN
    fields = {k: obj.get(k) for k in ("run", "key", "term", "raw", "decision", "bid", "predicted",
                                      "surprise", "projected", "held_reason", "evidence", "by", "at")
              if k in obj}
    if "key" not in fields and obj.get("term"):
        fields["key"] = term_key(obj.get("term"))
    how, ev = append_event(kind, str(obj.get("slug") or ""), events=a.events, **fields)
    print("learn_apply --append-event: %s %s (%s)" % (how, ev["event_id"], kind))
    print("LEARN-APPLY-COMPLETE")
    return hunt_lib.EXIT_CLEAN if how in ("written", "duplicate") else hunt_lib.EXIT_FINDINGS


def cmd_apply_reviews(a):
    summary, findings = apply_reviews(a.apply_reviews, store=a.store, events=a.events,
                                      packet=a.packet)
    if summary is None:
        for f in findings:
            print("  FINDING  " + f)
        print("LEARN-APPLY-COMPLETE")
        return hunt_lib.EXIT_CANNOT_RUN
    print("learn_apply --apply-reviews: %d recorded, %d left, %d refused"
          % (summary["recorded"], summary["left"], summary["refused"]))
    for f in findings:
        print("  FINDING  " + f)
    print("LEARN-APPLY-COMPLETE")
    return hunt_lib.EXIT_FINDINGS if findings else hunt_lib.EXIT_CLEAN


# =====================================================================================================
# self-test - pure predicates first, then an END-TO-END DRILL against a scratch ledger and event log.
# decide_apply's own structure, for decide_apply's own reason: the defects that survive every
# pure-predicate fixture are the ones that only appear once results are COLLECTED.
# =====================================================================================================

# The verbatim evidence from OPEN-ITEMS-recipe-hunter-2026-08-24 section 2.6. Both halves of the
# notes-vs-bid check are pinned against THIS string, because a check that only fires on a sentence
# written to make it fire has proved nothing.
OI26 = ("Bone-in skinless chicken drumstick. Refused the chicken-thighs bridge on the standing "
        "'leg quarters are not thighs' precedent: drumsticks are a distinct cut, so the thigh id "
        "would overprice and mis-weigh.")


def _ruling(raw, term, bid, decision="mapped", evidence="e", canon=None):
    return {"raw": raw, "term": term, "canon_item": canon if canon is not None else term.title(),
            "bid": bid, "decision": decision, "evidence": evidence}


def _payload(rulings, registrar=None):
    return {"rulings": list(rulings), "registrar_rulings": list(registrar or [])}


def _res(slug, rulings):
    return {"slug": slug, "status": "ok", "state": "priced", "lines": [], "rulings": list(rulings)}


class _DroppingLog(EventLog):
    """An event writer that SILENTLY drops the Nth append - the 44-class, reproduced in a fixture.

    It does not write, and it does not report a failure either: it answers something the counter
    does not recognise. That is the shape that makes the defect invisible from inside apply_learn,
    and it is why the postcondition is a separate check over the totals rather than a sum of the
    writer's own self-reports.
    """

    def __init__(self, path, drop_index=1):
        EventLog.__init__(self, path)
        self.drop_index = drop_index
        self.seen = 0

    def append(self, ev):
        self.seen += 1
        if self.seen == self.drop_index:
            return "dropped-by-fixture"
        return EventLog.append(self, ev)


def cmd_selftest(_a):
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    # ---- term_key ----------------------------------------------------------------------------------
    print("term_key - the cache is KEYED by this, so a second spelling is a cache that never hits")
    T("case and punctuation are normalised away",
      term_key("  Shaved Beef Steak, ") == "shaved beef steak", term_key("  Shaved Beef Steak, "))
    T("MUST FIRE  a DIFFERENT ingredient does not collide with a shorter one",
      term_key("beef steak") != term_key("shaved beef steak"), "collided")
    T("MUST FIRE  punctuation becomes a SPACE and never deletes a word: \"it's\" -> 'it s'",
      term_key("it's") == "it s", term_key("it's"))
    T("internal whitespace collapses", term_key("sour    cream") == "sour cream",
      term_key("sour    cream"))
    T("an empty term keys to empty rather than throwing", term_key("") == "" and term_key(None) == "",
      "threw")
    T("a leading quantity is normalised, not dropped - '2 lbs Shaved Beef Steak,' keys with its "
      "numbers", term_key("2 lbs Shaved Beef Steak,") == "2 lbs shaved beef steak",
      term_key("2 lbs Shaved Beef Steak,"))

    # THE CROSS-LANGUAGE PIN (plan 3.1). Six fixed strings through BOTH implementations.
    pin = ["  Shaved Beef Steak, ", "beef steak", "it's", "sour    cream", "",
           "2 lbs Shaved Beef Steak,"]
    ps_keys, why = ps_term_keys(pin)
    if ps_keys is None:
        T("MUST FIRE  the PowerShell Get-TermKey body could be run for the cross-language pin "
          "(BLIND is not clean)", False, why)
    else:
        mine = [term_key(x) for x in pin]
        T("MUST FIRE  term_key() agrees with PowerShell's Get-TermKey on all 6 pinned strings - a "
          "drift here is a cache that silently never hits",
          mine == ps_keys, "py=%s ps=%s" % (json.dumps(mine), json.dumps(ps_keys)))

    # ---- validate_map ------------------------------------------------------------------------------
    print("")
    print("validate_map - the map lane's first semantic validator")
    good = {"results": [{"slug": "s", "status": "ok", "state": "priced", "rulings": [
        _ruling("a", "gochujang", "gochujang"),
        _ruling("b", "tteok", "korean-rice-cakes"),
        _ruling("c", "sumac", "", decision="mapped-null")]}]}
    T("CLEAN TWIN a conforming map result validates", hunt_lib.validate_map(good) == [],
      str(hunt_lib.validate_map(good)))
    T("MUST FIRE  a decision outside the closed set is refused - 21 distinct values across 550 lines",
      any("closed set" in p for p in hunt_lib.validate_map(
          {"results": [{"slug": "s", "rulings": [_ruling("a", "x", "y", decision="sure")]}]})),
      "accepted it")
    T("MUST FIRE  `mapped` with neither a bid nor a canon_item is refused",
      any("settles no identity" in p for p in hunt_lib.validate_map(
          {"results": [{"slug": "s", "rulings": [_ruling("a", "x", "", canon="")]}]})), "accepted it")
    T("CLEAN TWIN  `mapped` with NO bid but a canon_item is legal - a named food with no id is the "
      "safe answer, not a malformed one",
      hunt_lib.validate_map(
          {"results": [{"slug": "s", "rulings": [_ruling("a", "x", "", canon="Mustard Powder")]}]})
      == [], "refused it")
    dupe = {"results": [{"slug": "s", "rulings": [_ruling("same raw", "a", "a"),
                                                  _ruling("same raw", "b", "b"),
                                                  _ruling("other", "c", "c")]}]}
    T("MUST FIRE  two rulings on ONE raw line are refused - `raw` is the assembler's join key, so "
      "one of them silently never happened",
      any("join" in p for p in hunt_lib.validate_map(dupe)), str(hunt_lib.validate_map(dupe)))
    T("MUST FIRE  a payload with no results array is refused",
      hunt_lib.validate_map({"x": 1}) != [], "accepted it")

    # ---- the notes-vs-bid check, against the REAL 2.6 evidence --------------------------------------
    print("")
    print("the notes-vs-bid check (OPEN-ITEMS 2.6), pinned against its own founding evidence")
    T("MUST FIRE  the 2.6 slip: the prose refuses `chicken-thighs` and the bid IS `chicken-thighs`",
      notes_refuse_bid(OI26, "chicken-thighs"), "did not fire")
    T("CLEAN TWIN  the SAME evidence with the CORRECT bid `chicken-drumsticks` does not fire - the "
      "refusal is about a different id (2.7's reading)",
      not notes_refuse_bid(OI26, "chicken-drumsticks"), "fired")
    T("MUST FIRE  'not the <bid>' fires",
      notes_refuse_bid("this is not the white-wine-vinegar the recipe means", "white-wine-vinegar"),
      "did not fire")
    T("CLEAN TWIN  evidence that merely NAMES the bid does not fire",
      not notes_refuse_bid("the Korean fermented chili paste, priced as gochujang", "gochujang"),
      "fired")
    T("CLEAN TWIN  a refusal in a PREVIOUS clause does not reach across the punctuation",
      not notes_refuse_bid("rejected the bridge; salt is the right id here", "salt"), "fired")
    T("an empty bid or empty evidence never fires", not notes_refuse_bid("", "x")
      and not notes_refuse_bid("refused x", ""), "fired")

    # ---- event identity ----------------------------------------------------------------------------
    print("")
    print("the event log")
    e1 = make_event("ruling", "s", key="k", decision="mapped", bid="b", evidence="e")
    e2 = make_event("ruling", "s", key="k", decision="mapped", bid="b", evidence="e")
    T("MUST FIRE  the same ruling content-addresses to the SAME event_id whatever the clock says",
      e1["event_id"] == e2["event_id"], "%s vs %s" % (e1["event_id"], e2["event_id"]))
    T("MUST FIRE  a different bid is a different event",
      make_event("ruling", "s", key="k", decision="mapped", bid="c", evidence="e")["event_id"]
      != e1["event_id"], "collided")
    T("MUST FIRE  all 16 fields are present on every event, null/empty rather than omitted",
      sorted(e1.keys()) == sorted(EVENT_FIELDS + ("event_id",)) and len(e1) == 16,
      ",".join(sorted(e1.keys())))

    # ---- END-TO-END DRILL ---------------------------------------------------------------------------
    print("")
    print("END-TO-END DRILL - scratch ledger, scratch event log, the REAL -Record through ps_invoke")
    tmp = tempfile.mkdtemp(prefix="learn-apply-drill-")
    try:
        store = os.path.join(tmp, "ingredient-resolutions.json")
        events = os.path.join(tmp, "ingredient-events.jsonl")
        run_dir = os.path.join(tmp, "run-drill")
        os.makedirs(run_dir, exist_ok=True)

        ids, _why = known_bids()
        T("the three commodity namespaces yield a non-empty id set (BLIND is not clean)",
          len(ids) > 100, str(len(ids)))
        live = "chicken-breast" if "chicken-breast" in ids else sorted(ids)[0]
        live2 = "eggs" if "eggs" in ids else sorted(ids)[1]

        table = {"rows": [
            {"term": "shaved beef steak", "bid": None, "source": None, "resolution": "unresolved"},
            {"term": "kosher salt", "bid": "salt", "source": "cache", "resolution": "unresolved"}]}
        tables = {"drill-a": table}

        # 1. a clean mapped ruling -> ONE event, projected, a ledger row under the normalised key
        r1 = _ruling("2 lbs Shaved Beef Steak", "Shaved Beef Steak", live,
                     evidence="the thin-sliced sandwich steak, not a roast")
        s1, f1 = apply_learn(run_dir, "drill-a", _res("drill-a", [r1]), tables, _payload([r1]),
                             store=store, events=events)
        led, n, _w = read_ledger(store)
        T("MUST FIRE  a clean `mapped` ruling projects: one event, one ledger row, keyed normalised",
          s1["events_written"] == 1 and s1["projected"] == 1 and n == 1
          and "shaved beef steak" in led, "summary=%s ledger=%s" % (json.dumps(s1), sorted(led)))
        T("CLEAN TWIN  and it produced no findings", f1 == [], str(f1))
        T("MUST FIRE  the ledger row is attributed to the mapper and carries the evidence plus its "
          "slug and run",
          led["shaved beef steak"].get("by") == "mapper"
          and "drill-a" in str(led["shaved beef steak"].get("evidence")),
          json.dumps(led.get("shaved beef steak")))
        T("MUST FIRE  the event says projected: true",
          json.loads(io.open(events, encoding="utf-8").read().strip().split("\n")[0])["projected"]
          is True, "not projected")

        # 2. idempotence: the same ruling twice is ONE line and ONE row
        s2, _f2 = apply_learn(run_dir, "drill-a", _res("drill-a", [r1]), tables, _payload([r1]),
                              store=store, events=events)
        lines = [l for l in io.open(events, encoding="utf-8").read().split("\n") if l.strip()]
        led, n, _w = read_ledger(store)
        T("MUST FIRE  the same ruling applied twice writes ONE event line and keeps ONE ledger row",
          len(lines) == 1 and n == 1 and s2["events_skipped_duplicate"] == 1,
          "lines=%d rows=%d summary=%s" % (len(lines), n, json.dumps(s2)))

        # 3. the notes-vs-bid refusal, at the pen
        r3 = _ruling("2 lb chicken drumsticks", "Chicken Drumsticks", "chicken-thighs",
                     evidence=OI26)
        s3, f3 = apply_learn(run_dir, "drill-a", _res("drill-a", [r3]), tables, _payload([r3]),
                             store=store, events=events)
        led3, n3, _w = read_ledger(store)
        ev3 = json.loads([l for l in io.open(events, encoding="utf-8").read().split("\n")
                          if l.strip()][-1])
        T("MUST FIRE  a ruling whose evidence refuses its own bid is NOT cached, is surprising, and "
          "names its reason",
          n3 == 1 and ev3["held_reason"] == "notes refuse the bid" and ev3["surprise"] is True
          and ev3["projected"] is False and any("OPEN-ITEMS 2.6" in x for x in f3),
          "rows=%d event=%s findings=%s" % (n3, json.dumps(ev3)[:200], json.dumps(f3)[:200]))

        # 3b. CLEAN TWIN: the same evidence, the id 2.7 says is right
        r3b = _ruling("2 lb chicken drumsticks", "Chicken Drumsticks", live2, evidence=OI26)
        s3b, f3b = apply_learn(run_dir, "drill-b", _res("drill-b", [r3b]), {}, _payload([r3b]),
                               store=store, events=events)
        T("CLEAN TWIN  the same evidence with a DIFFERENT bid projects normally",
          s3b["projected"] == 1 and f3b == [], "summary=%s findings=%s"
          % (json.dumps(s3b), json.dumps(f3b)))

        # 4. rejected / not-purchased / mapped-null: events only, never a row
        before = read_ledger(store)[1]
        rs = [_ruling("x1", "Duck Fat", "duck-fat", decision="rejected", evidence="the store has none"),
              _ruling("x2", "Yuzu Kosho", "yuzu-kosho", decision="not-purchased",
                      evidence="pantry static"),
              _ruling("x3", "Mustard Powder", "", decision="mapped-null",
                      canon="Mustard Powder", evidence="dry ground seed, not the condiment")]
        s4, _f4 = apply_learn(run_dir, "drill-c", _res("drill-c", rs), {}, _payload(rs),
                              store=store, events=events)
        after = read_ledger(store)[1]
        held = [json.loads(l) for l in io.open(events, encoding="utf-8").read().split("\n")
                if l.strip()][-3:]
        T("MUST FIRE  rejected / not-purchased / mapped-null are EVENTS ONLY - a judgment about a "
          "LINE in a RECIPE is not an identity",
          after == before and s4["events_written"] == 3 and s4["projected"] == 0
          and all(h["projected"] is False and h["held_reason"].startswith("decision") for h in held),
          "before=%d after=%d summary=%s" % (before, after, json.dumps(s4)))

        # 5. an unknown bid, then the same bid with an approve, then an alias
        r5 = _ruling("y1", "Gochujang Deluxe", "gochujang-deluxe-not-a-real-id",
                     evidence="the Korean fermented chili paste")
        s5, f5 = apply_learn(run_dir, "drill-d", _res("drill-d", [r5]), {}, _payload([r5]),
                             store=store, events=events)
        ev5 = json.loads([l for l in io.open(events, encoding="utf-8").read().split("\n")
                          if l.strip()][-1])
        T("MUST FIRE  a bid no namespace carries and no registrar approved is held, and the reason "
          "names it", s5["projected"] == 0
          and ev5["held_reason"] == "bid unknown to every namespace", json.dumps(ev5)[:200])
        s5b, _f = apply_learn(run_dir, "drill-e", _res("drill-e", [r5]), {},
                              _payload([r5], registrar=[
                                  {"proposed_bid": "gochujang-deluxe-not-a-real-id",
                                   "verdict": "approve", "bid": "gochujang-deluxe-not-a-real-id",
                                   "reason": "a distinct purchase"}]),
                              store=store, events=events)
        led5, _n, _w = read_ledger(store)
        T("MUST FIRE  the SAME bid with an `approve` ruling in this batch projects",
          s5b["projected"] == 1
          and led5.get("gochujang deluxe", {}).get("item_id") == "gochujang-deluxe-not-a-real-id",
          "summary=%s row=%s" % (json.dumps(s5b), json.dumps(led5.get("gochujang deluxe"))))
        T("  and the registrar ruling left its OWN event - the estate's first registrar ledger",
          s5b["registrar_events"] == 1, json.dumps(s5b))
        r5c = _ruling("y2", "Deluxe Gochujang", "another-not-real-id",
                      evidence="the same paste under another name")
        s5c, _f = apply_learn(run_dir, "drill-f", _res("drill-f", [r5c]), {},
                              _payload([r5c], registrar=[
                                  {"proposed_bid": "another-not-real-id", "verdict": "alias",
                                   "bid": live, "reason": "already priced under that id"}]),
                              store=store, events=events)
        led5c, _n, _w = read_ledger(store)
        T("MUST FIRE  an `alias` ruling projects the ALIASED-TO id, never the proposed one",
          led5c.get("deluxe gochujang", {}).get("item_id") == live,
          json.dumps(led5c.get("deluxe gochujang")))

        # 6. supersede
        r6 = _ruling("2 lbs Shaved Beef Steak", "Shaved Beef Steak", live2,
                     evidence="re-ruled on the repair pass: the other cut entirely")
        s6, _f6 = apply_learn(run_dir, "drill-a", _res("drill-a", [r6]), tables, _payload([r6]),
                              store=store, events=events)
        led6, _n, _w = read_ledger(store)
        sup = [json.loads(l) for l in io.open(events, encoding="utf-8").read().split("\n")
               if l.strip() and json.loads(l)["kind"] == "supersede"]
        keyrows = [k for k in led6 if k == "shaved beef steak"]
        T("MUST FIRE  a re-ruling with a different bid supersedes: ONE row per key, and a "
          "`supersede` event records old -> new",
          len(keyrows) == 1 and led6["shaved beef steak"]["item_id"] == live2 and len(sup) == 1
          and live in sup[0]["evidence"] and live2 in sup[0]["evidence"],
          "rows=%d bid=%s supersedes=%d" % (len(keyrows),
                                            led6["shaved beef steak"]["item_id"], len(sup)))
        T("  and the supersede event does NOT count toward the 44-class primary total",
          s6["events_written"] == 1 and s6["supersede_events"] == 1, json.dumps(s6))

        # 7. the surprise wire
        r7 = _ruling("1 tbsp kosher salt", "kosher salt", live2,
                     evidence="ruled against what the cache predicted")
        s7, _f7 = apply_learn(run_dir, "drill-a", _res("drill-a", [r7]), tables, _payload([r7]),
                              store=store, events=events)
        ev7 = json.loads([l for l in io.open(events, encoding="utf-8").read().split("\n")
                          if l.strip()][-1])
        T("MUST FIRE  a ruling that disagrees with what preresolve PREDICTED is a surprise, and the "
          "prediction is recorded with its source",
          ev7["surprise"] is True and ev7["predicted"] == {"source": "cache", "bid": "salt"},
          json.dumps(ev7)[:200])

        # 8. no evidence
        before8 = read_ledger(store)[1]
        r8 = _ruling("z1", "Sumac", live, evidence="")
        s8, _f8 = apply_learn(run_dir, "drill-g", _res("drill-g", [r8]), {}, _payload([r8]),
                              store=store, events=events)
        ev8 = json.loads([l for l in io.open(events, encoding="utf-8").read().split("\n")
                          if l.strip()][-1])
        T("MUST FIRE  an unexplained ruling is an EVENT and never a ledger row - every row in that "
          "file carries evidence and the invariant holds",
          read_ledger(store)[1] == before8 and ev8["held_reason"] == "no evidence",
          "held=%r rows=%d" % (ev8["held_reason"], read_ledger(store)[1]))

        # 9. the pen fails loudly
        dead = os.path.join(tmp, "no-such-dir", "locked", "store.json")
        r9 = _ruling("q1", "Harissa", live, evidence="the North African chili paste")
        s9, f9 = apply_learn(run_dir, "drill-h", _res("drill-h", [r9]), {}, _payload([r9]),
                             store=dead, events=events)
        ev9 = json.loads([l for l in io.open(events, encoding="utf-8").read().split("\n")
                          if l.strip()][-1])
        T("MUST FIRE  a -Record that cannot write is a FINDING and the event says the ledger refused "
          "it - never silence",
          s9["projected"] == 0 and any("did not reach the resolutions ledger" in x for x in f9)
          and ev9["held_reason"] == "the ledger refused the write",
          "summary=%s findings=%s" % (json.dumps(s9), json.dumps(f9)[:220]))

        # 10. the 44-class postcondition, over a dropped write
        three = [_ruling("t1", "Tteok", live, evidence="cylindrical rice cake"),
                 _ruling("t2", "Doenjang", live2, evidence="fermented soybean paste"),
                 _ruling("t3", "Perilla", live, evidence="the leaf, not the seed oil")]
        pay = _payload(three)
        drop = _DroppingLog(os.path.join(tmp, "dropped.jsonl"), drop_index=2)
        sD, _fD = apply_learn(run_dir, "drill-i", _res("drill-i", three), {}, pay,
                              store=store, events="", log=drop)
        fin = postcondition_finding("drill-i", sD, pay)
        T("MUST FIRE  a writer that drops ONE of three rulings trips the 44-class postcondition, and "
          "the finding names both counts",
          bool(fin) and "3 residual rulings but 2 learn events" in fin, "finding=%r summary=%s"
          % (fin, json.dumps(sD)))
        ok_log = EventLog(os.path.join(tmp, "clean.jsonl"))
        sC, _fC = apply_learn(run_dir, "drill-j", _res("drill-j", three), {}, pay,
                              store=store, events="", log=ok_log)
        T("CLEAN TWIN  the same three rulings through an honest writer trip nothing",
          postcondition_finding("drill-j", sC, pay) == "",
          postcondition_finding("drill-j", sC, pay))
        payr = _payload(three, registrar=[{"proposed_bid": "p1", "verdict": "reject",
                                           "reason": "already priced"}])
        okl2 = EventLog(os.path.join(tmp, "clean2.jsonl"))
        sR, _fR = apply_learn(run_dir, "drill-k", _res("drill-k", three), {}, payr,
                              store=store, events="", log=okl2)
        T("CLEAN TWIN  the postcondition counts registrar events too - 3 rulings + 1 registrar = 4",
          postcondition_finding("drill-k", sR, payr) == "" and sR["events_written"] == 4,
          "summary=%s finding=%r" % (json.dumps(sR), postcondition_finding("drill-k", sR, payr)))

        # 11. the QA mapper-fail event (plan 4.1)
        mp = os.path.join(run_dir, "mapped-pre")
        os.makedirs(mp, exist_ok=True)
        with io.open(os.path.join(mp, "drill-a.rulings.json"), "w", encoding="utf-8") as f:
            json.dump({"slug": "drill-a", "rulings": three}, f)
        keys, whyk = residual_keys_for(run_dir, "drill-a")
        T("the slug's residual keys are read off its own rulings file",
          keys == ["tteok", "doenjang", "perilla"] and whyk == "", json.dumps(keys))
        before11 = read_ledger(store)[1]
        howq, evq = qa_fail_event("drill-a", "the mapper bridged a form flip", run="run-drill",
                                  residual_keys=keys, events=events)
        T("MUST FIRE  a QA mapper-fail writes exactly one slug-level event with an empty key, by qa",
          howq == "written" and evq["kind"] == "qa_mapper_fail" and evq["key"] == ""
          and evq["by"] == "qa" and "tteok" in evq["evidence"], json.dumps(evq)[:220])
        T("MUST FIRE  and it touched NO ledger row - a QA fail is not a new identity, the repair "
          "re-ruling is",
          read_ledger(store)[1] == before11, "%d -> %d" % (before11, read_ledger(store)[1]))
        keysX, whyX = residual_keys_for(run_dir, "never-mapped")
        T("MUST FIRE  a missing rulings file is ANNOUNCED, not reported as 'no residual keys'",
          keysX == [] and "could not be read" in whyX, whyX)

        # 12. --apply-reviews (plan 6.2), including the loud refusal
        pkt = os.path.join(tmp, "packet.json")
        held_ev = make_event("ruling", "drill-r", key="labneh", term="Labneh", decision="mapped",
                             bid="labneh-not-real", evidence="strained yogurt cheese",
                             held_reason="bid unknown to every namespace")
        with io.open(pkt, "w", encoding="utf-8") as f:
            json.dump({"generated_at": now_stamp(), "instructions": "x",
                       "cases": [{"event": held_ev, "ledger_row": None, "why": "held"}]}, f)
        vf = os.path.join(tmp, "verdicts.json")
        with io.open(vf, "w", encoding="utf-8") as f:
            json.dump({"verdicts": [
                {"event_id": held_ev["event_id"], "verdict": "record", "item_id": live,
                 "evidence": "adjudicated: it is the same purchase", "by": "adjudication"},
                {"event_id": "ie:doesnotexist", "verdict": "record", "item_id": live,
                 "evidence": "x", "by": "adjudication"}]}, f)
        before12 = read_ledger(store)[1]
        sv, fv = apply_reviews(vf, store=store, events=events, packet=pkt)
        led12, n12, _w = read_ledger(store)
        T("MUST FIRE  a `record` verdict writes the row, attributed to adjudication",
          sv["recorded"] == 1 and n12 == before12 + 1
          and led12.get("labneh", {}).get("by") == "adjudication",
          "summary=%s row=%s" % (json.dumps(sv), json.dumps(led12.get("labneh"))))
        T("MUST FIRE  a verdict on an event_id the packet never held is REFUSED LOUDLY",
          sv["refused"] == 1 and any("never held" in x for x in fv), json.dumps(fv)[:200])
        with io.open(vf, "w", encoding="utf-8") as f:
            json.dump({"verdicts": [{"event_id": held_ev["event_id"], "verdict": "leave",
                                     "evidence": "still not sure", "by": "adjudication"}]}, f)
        before13 = read_ledger(store)[1]
        sv2, _fv2 = apply_reviews(vf, store=store, events=events, packet=pkt)
        T("MUST FIRE  a `leave` verdict writes only the event and changes no row",
          sv2["left"] == 1 and read_ledger(store)[1] == before13, json.dumps(sv2))

        # 13. every line on disk is a sorted-keys 14-field object
        allev = [json.loads(l) for l in io.open(events, encoding="utf-8").read().split("\n")
                 if l.strip()]
        T("MUST FIRE  every line of the log carries all 16 fields (a GROUP BY over a missing key "
          "silently drops the row)",
          all(sorted(e.keys()) == sorted(EVENT_FIELDS + ("event_id",)) for e in allev),
          str(len(allev)))
        raw_first = io.open(events, encoding="utf-8", newline="").read().split("\n")[0]
        T("MUST FIRE  lines are LF-terminated and sorted-keys, the graph\\provenance idiom",
          "\r" not in raw_first and raw_first.startswith('{"at":'), raw_first[:60])
        T("the drill wrote a real corpus to assert over", len(allev) >= 12, str(len(allev)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("")
    if bad:
        print("learn_apply SELF-TEST FAIL (%d)" % len(bad))
        print("LEARN-APPLY-COMPLETE")
        return hunt_lib.EXIT_CANNOT_RUN
    print("learn_apply SELF-TEST PASS")
    print("LEARN-APPLY-COMPLETE")
    return hunt_lib.EXIT_CLEAN


def main(argv=None):
    ap = argparse.ArgumentParser(description="the encode pen for ingredient identity")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--append-event", dest="append_event", default="",
                    help="a JSON object (file path, '-' for stdin, or the literal text) to append as "
                         "ONE event. The door for PowerShell callers - grocery/meal-prep scripts "
                         "that settle an identity outside the map lane.")
    ap.add_argument("--apply-reviews", dest="apply_reviews", default="",
                    help="a verdicts file for graph\\learning\\hunter-review-packet.json. The ONLY "
                         "promotion road: nothing applies automatically at 3am.")
    ap.add_argument("--packet", default="", help="the packet the verdicts rule on")
    ap.add_argument("--store", default="", help="a scratch resolutions ledger, for a drill")
    ap.add_argument("--events", default="", help="a scratch event log, for a drill")
    a = ap.parse_args(argv)
    if a.selftest:
        return cmd_selftest(a)
    if a.append_event:
        return cmd_append_event(a)
    if a.apply_reviews:
        return cmd_apply_reviews(a)
    ap.print_help()
    print("LEARN-APPLY-COMPLETE")
    return hunt_lib.EXIT_CANNOT_RUN


if __name__ == "__main__":
    sys.exit(main())
