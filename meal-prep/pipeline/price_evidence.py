"""
price_evidence.py - assemble the price lane's pre-gathered evidence (PLAN-recipe-hunter-v3, D10).

    C:\\Codex\\Python312\\python.exe price_evidence.py --selftest

WHAT THIS IS. The daemon gathers, before every pricer dispatch, what the mechanical surfaces already
know about a batch of never-priced terms: probe-ingredient.ps1 for the two server stores, and
pull-browser-stores.py's lookup mode for the two drivable ones. This module turns those two very
different outputs into ONE document in section 4.5's price-evidence shape, and renders it for the
prompt. It performs no I/O against a store and holds no policy about carriage - it is the join.

NO MUTEX, AND HERE IS WHY IT IS SAFE TO SAY SO. `<RunDir>\\price-evidence\\batch-<n>.json` has ONE
writer per distinct `n`: the price lane is a SINGLETON by architecture (hunt_lib.LANE_CAPS marks it,
a fixture asserts it), `n` is that lane's own invocation counter, and nothing else in the estate
writes this path. That is the same reasoning map-preresolve's per-slug table carries. If evidence
ever aggregates into ONE run-level file with more than one writer, that file takes the named-mutex
pattern WITH a barrier fixture proven to fail neutered - the fourth PS trap does not care what phase
it is.

THE TWO VOCABULARIES NEVER MIX. MATCHES / EMPTY / UNUSABLE are SEARCH states, and they are all this
file speaks. carried / not-carried / blocked / error are the QUEUE's per-store record states, and
only the PRICER converts one into the other. Nothing here writes a queue record, and an EMPTY here
PERMITS not-carried without recording it.

THE FIELD-MAPPING PIN (section 4.5, and it is the whole reason this file is not three lines).
probe-ingredient's per-store object carries TWO state-like fields:
    `state`   TRANSPORT: OK / ERROR / NO-CREDENTIALS
    `verdict` the search-verdict ladder state: MATCHES / EMPTY / UNUSABLE
The evidence `state` is probe's **verdict**. Probe's transport `state` and `note` fold into `reason`
when they are not OK, and a transport ERROR is UNUSABLE with the exception text as its reason.
Reading the wrong one records transport noise as a search answer - which, for an ERROR, would mean
recording "we did not reach the store" as "the store has nothing".

DEGRADE, NEVER BLOCK. This is the explicit OPPOSITE of map-preresolve's exit-2. A failed probe, a
walled sweep or a missing lookup output makes those STORES UNUSABLE in the document, and the pricer
is still dispatched: it is a judge that can also go and look. Could-not-look never reads as EMPTY.

THE SEVEN STORE NAMES ARE READ, NEVER COPIED. ingredient-queue.ps1 owns that roster (a worker
recording 'Bakers' creates a silent eighth store and the all-seven-checked test never fires). If the
roster cannot be read, this file enumerates only the stores it actually gathered and SAYS so - a
hardcoded fallback would be the forked-taxonomy defect this estate has a scar from.

EXIT CODES 0 clean / 1 findings / 2 could-not-run. Marker PRICE-EVIDENCE-COMPLETE.
"""
from __future__ import annotations

import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
REPO = os.path.dirname(MP)
INGREDIENT_QUEUE_PS = os.path.join(REPO, "grocery", "ingredient-queue.ps1")

SCHEMA = "price-evidence/1"
HIT_CAP = 8                      # section 4.5's cap, and probe-ingredient's own

# The pre-pass tiers, exactly as S5 stands after its 2026-08-24 correction. A store's tier decides
# who looks, and the pricer needs it in front of it: "nobody has looked yet, and it is yours" is a
# different instruction from "we looked and were blocked".
TIER_SERVER = "server"           # probe-ingredient.ps1 - Baker's, Family Fare
TIER_DRIVER = "driver"           # pull-browser-stores.py lookup mode - Fareway, Sam's Club
TIER_PRICER = "pricer-tab"       # Hy-Vee: no driver lane exists and D10 must not build one
TIER_ATTENDED = "attended"       # Walmart, Aldi: Brad's Chrome, only when Brad is present

SERVER_STORES = ("Baker's", "Family Fare")
DRIVER_STORES = (("fareway", "Fareway"), ("samsclub", "Sam's Club"))
PRICER_TAB_STORES = ("Hy-Vee",)
ATTENDED_STORES = ("Walmart", "Aldi")

TIER_OF = {}
for _s in SERVER_STORES:
    TIER_OF[_s] = TIER_SERVER
for _k, _s in DRIVER_STORES:
    TIER_OF[_s] = TIER_DRIVER
for _s in PRICER_TAB_STORES:
    TIER_OF[_s] = TIER_PRICER
for _s in ATTENDED_STORES:
    TIER_OF[_s] = TIER_ATTENDED

TIER_REASON = {
    TIER_PRICER: ("no pre-pass tier covers this store - Hy-Vee has no driver lane (its puller is a "
                  "refresh, not a search), so a new term is the pricer's own browser tab"),
    TIER_ATTENDED: ("attended lane - this store answers Brad's own Chrome and not an automated one, "
                    "so it is only checkable while he is present"),
}

_STORES_RE = re.compile(r"\$STORES\s*=\s*@\((.*?)\)", re.S)
_QUOTED_RE = re.compile(r'"([^"]*)"' + r"|'([^']*)'")


def read_store_roster(path=None):
    """ingredient-queue.ps1's own seven store names. Returns (names, why).

    An empty list means it could not be read, which the caller must treat as BLIND rather than as
    clean - exactly as the daemon treats find-similar's stop list. The alternative, a copy of the
    roster living here, is how two surfaces come to disagree about how many stores there are.
    """
    path = path or INGREDIENT_QUEUE_PS
    try:
        with open(path, "r", encoding="utf-8-sig") as fh:
            src = fh.read()
    except Exception as e:
        return [], "could not read %s (%s)" % (os.path.basename(path), e)
    m = _STORES_RE.search(src)
    if not m:
        return [], "%s no longer declares $STORES = @(...)" % os.path.basename(path)
    names = [a or b for a, b in _QUOTED_RE.findall(m.group(1))]
    names = [n for n in names if n.strip()]
    if not names:
        return [], "%s declares an empty $STORES" % os.path.basename(path)
    return names, ""


def row(store, state, term_used="", attempts=None, hits=None, reason="", tier=""):
    """One per-term per-store evidence row - section 4.5's shape, and nothing beyond it except the
    `tier` that says WHO is expected to look."""
    if state not in ("MATCHES", "EMPTY", "UNUSABLE"):
        raise ValueError("not a search state: %r (the queue's carried/not-carried vocabulary never "
                         "appears in evidence)" % (state,))
    return {"store": store, "state": state, "term_used": term_used, "attempts": list(attempts or []),
            "hits": list(hits or [])[:HIT_CAP], "reason": reason,
            "tier": tier or TIER_OF.get(store, "")}


def unchecked_row(store, reason=""):
    """A store no pre-pass reaches. UNUSABLE is the honest state for it: search-verdict-lib's own
    definition of UNUSABLE is "we never got to look", and it reads PENDING, never not-carried."""
    return row(store, "UNUSABLE", reason=reason or TIER_REASON.get(TIER_OF.get(store, ""), "not gathered"))


def from_probe(doc):
    """probe-ingredient.ps1 -Json -> {term: {store: evidence row}} plus a unit per term.

    Returns (by_term, units). Applies the FIELD-MAPPING PIN: the evidence state is probe's `verdict`,
    and probe's transport `state`/`note` fold into the reason when the transport was not OK.
    """
    by_term, units = {}, {}
    for res in (doc or {}).get("results") or []:
        term = str(res.get("term") or "")
        if not term:
            continue
        units[term] = str(res.get("unit") or "")
        per = {}
        for st in res.get("stores") or []:
            store = str(st.get("store") or "")
            transport = str(st.get("state") or "")
            verdict = str(st.get("verdict") or "")
            reason = str(st.get("reason") or "")
            if transport and transport != "OK":
                # A transport failure is UNUSABLE with the exception text as the reason, and it is
                # NEVER an empty shelf. probe already rules these UNUSABLE; this keeps the mapping
                # true even if a future probe path forgets to.
                verdict = "UNUSABLE"
                note = str(st.get("note") or "")
                reason = ("%s: %s" % (transport, note or reason)).strip()
            if verdict not in ("MATCHES", "EMPTY", "UNUSABLE"):
                verdict = "UNUSABLE"
                reason = reason or ("probe returned no verdict for this store (transport %s)"
                                    % (transport or "unknown"))
            per[store] = row(store, verdict, term_used=str(st.get("term_used") or ""),
                             attempts=st.get("attempts") or [], hits=st.get("hits") or [],
                             reason=reason, tier=TIER_SERVER)
        by_term[term] = per
    return by_term, units


def parse_probe_stdout(text):
    """probe-ingredient.ps1 -Json prints one JSON document. Returns (doc, why).

    Tolerant of anything PowerShell printed BEFORE it (a Write-Output from a dot-sourced lib, a
    warning) and intolerant of guessing: a stdout with no object in it returns a why, and the caller
    degrades the whole server tier to UNUSABLE rather than inventing an empty result.
    """
    t = (text or "").strip()
    if not t:
        return None, "probe printed nothing"
    i = t.find("{")
    if i < 0:
        return None, "probe printed no JSON object: %s" % t[:160]
    try:
        return json.loads(t[i:]), ""
    except Exception as e:
        return None, "probe output did not parse (%s): %s" % (e, t[i:i + 160])


def probe_failed(store_names, terms, reason):
    """The whole server tier, UNUSABLE, because the probe call itself did not answer."""
    return {t: {s: row(s, "UNUSABLE", reason=reason, tier=TIER_SERVER) for s in store_names}
            for t in terms}


def from_lookup(store_name, doc, terms, missing_reason=""):
    """One store's lookup output -> {term: evidence row}. A missing or unreadable document makes the
    store UNUSABLE for every term of the batch, which is the degrade path, not an error path."""
    if not doc or not isinstance(doc, dict) or not isinstance(doc.get("results"), list):
        why = missing_reason or "no lookup output was produced for this store"
        return {t: row(store_name, "UNUSABLE", reason=why, tier=TIER_DRIVER) for t in terms}
    seen = {}
    for r in doc.get("results") or []:
        t = str(r.get("term") or "")
        if not t:
            continue
        state = str(r.get("state") or "")
        if state not in ("MATCHES", "EMPTY", "UNUSABLE"):
            state = "UNUSABLE"
        seen[t] = row(store_name, state, term_used=str(r.get("term_used") or t),
                      attempts=r.get("attempts") or [], hits=r.get("hits") or [],
                      reason=str(r.get("reason") or ""), tier=TIER_DRIVER)
    out = {}
    for t in terms:
        out[t] = seen.get(t) or row(store_name, "UNUSABLE", tier=TIER_DRIVER,
                                    reason="the lookup output does not mention this term")
    return out


def build(run_id, batch, terms, probe_by_term=None, units=None, lookups=None, roster=None,
          roster_why="", findings=None, generated=""):
    """The evidence document. `lookups` is {store_name: {term: row}}."""
    terms = list(terms)
    probe_by_term = probe_by_term or {}
    lookups = lookups or {}
    units = units or {}
    findings = list(findings or [])
    roster = list(roster or [])
    if not roster:
        # BLIND, AND SAID SO. Enumerate what was actually gathered rather than a copy of the roster.
        gathered = []
        for t in terms:
            for s in (probe_by_term.get(t) or {}):
                if s not in gathered:
                    gathered.append(s)
        for s in lookups:
            if s not in gathered:
                gathered.append(s)
        roster = gathered
        if roster_why:
            findings.append("the seven-store roster could not be read (%s) - this file enumerates "
                            "only the stores it gathered, so Rule B must be applied from the queue "
                            "itself, not from this file" % roster_why)

    out_terms = []
    for t in terms:
        per = dict(probe_by_term.get(t) or {})
        for store_name, by_term in lookups.items():
            r = by_term.get(t)
            if r:
                per[store_name] = r
        stores = []
        for s in roster:
            stores.append(per.get(s) or unchecked_row(s))
        # Anything gathered under a name the roster does not carry is still shown - a store we
        # looked at and cannot file is a finding, never a silent drop.
        for s, r in per.items():
            if s not in roster:
                stores.append(r)
                findings.append("evidence for '%s' names a store the queue roster does not: %s"
                                % (t, s))
        out_terms.append({"term": t, "unit": units.get(t, ""), "stores": stores})

    return {"schema": SCHEMA, "run": run_id, "batch": batch, "generated": generated,
            "batch_terms": terms, "roster": roster, "findings": findings, "terms": out_terms}


def write(path, doc):
    d = os.path.dirname(os.path.abspath(path))
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=1)
    return path


def tally(doc):
    """{state: count} across every term-store pair - the one number a lane log can carry."""
    out = {}
    for t in doc.get("terms") or []:
        for s in t.get("stores") or []:
            out[s["state"]] = out.get(s["state"], 0) + 1
    return out


def _price(v):
    if v is None or v == "":
        return "no-honest-price"
    try:
        return "$%.2f" % float(v)
    except Exception:
        return str(v)


NO_BROWSER_EVIDENCE = "blocked - no browser in this session"


def headless_blocked_stores(doc):
    """The stores a DAEMON-DISPATCHED pricer structurally cannot reach (B3 / pin P9).

    Gate finding 2, and it is the phase's most important measurement. The adapter dispatches
    `claude -p --agent recipe-hunter-pricer` in a headless subprocess. MCP servers are not there:
    `mcp__Claude_Browser__*` is the app's own pane and `mcp__claude-in-chrome__*` needs the extension
    attached to an interactive session. Declaring a tool in frontmatter does not conjure the server.
    The agent's own final evidence said so plainly - and what it wrote FIRST, mid-session, was three
    verified-sounding store visits that never happened, one of them carrying a street address that
    does not match the estate's own record for that supercenter. It corrected itself afterwards, which
    is the only reason the queue is clean, and SELF-CORRECTION IS NOT A CONTROL.

    So the prompt stops asking for what the session cannot do. These are the pricer-tab and attended
    tiers - Hy-Vee, Walmart, Aldi - named off the evidence's OWN tier field rather than a second list.
    """
    out = []
    for t in (doc or {}).get("terms") or []:
        for srow in t.get("stores") or []:
            if srow.get("tier") in (TIER_PRICER, TIER_ATTENDED) and srow["store"] not in out:
                out.append(srow["store"])
    return out


def walled_stores(doc):
    """Stores a pre-pass DID reach for and was refused by: UNUSABLE at the server or driver tier.

    "Nobody has looked and it is yours" and "we looked and were walled" are both UNUSABLE, and the
    tier is what tells them apart - which is why the tier is on every row. Family Fare answered
    `(400) Bad Request` to all five terms on the phase-5 batch (Freshop is search-budget bound and the
    daily capture had already spent it) and ate three futile retries from the pricer. Re-probing a
    store the transport just refused buys nothing but minutes.
    """
    out = []
    for t in (doc or {}).get("terms") or []:
        for srow in t.get("stores") or []:
            if (srow.get("state") == "UNUSABLE"
                    and srow.get("tier") in (TIER_SERVER, TIER_DRIVER)
                    and srow["store"] not in out):
                out.append(srow["store"])
    return out


def render(doc, path=""):
    """The evidence, INLINE for the prompt. Compact on purpose: the 8-hit cap bounds it and phase 1
    measured an inline dossier beating a tool-call read, but a raw JSON dump would spend most of its
    tokens on punctuation."""
    lines = []
    if path:
        lines.append("PRE-GATHERED EVIDENCE (full JSON on disk: %s)" % path)
    for f in doc.get("findings") or []:
        lines.append("  ! %s" % f)
    for t in doc.get("terms") or []:
        unit = (" [unit: %s]" % t["unit"]) if t.get("unit") else " [unit: unknown]"
        lines.append("")
        lines.append("TERM '%s'%s" % (t["term"], unit))
        for s in t.get("stores") or []:
            head = "  %-13s %-8s" % (s["store"], s["state"])
            if s.get("term_used") and s["term_used"] != t["term"]:
                head += " via '%s'" % s["term_used"]
            att = s.get("attempts") or []
            if att:
                head += "  ladder: " + " -> ".join(
                    "'%s'=%s" % (a.get("term", "?"), a.get("hits", "?")) for a in att)
            lines.append(head)
            if s.get("reason"):
                lines.append("        reason: %s" % s["reason"])
            for h in (s.get("hits") or [])[:HIT_CAP]:
                extra = ""
                if h.get("unit_price"):
                    extra = "  (%s)" % h["unit_price"]
                rel = h.get("relevance")
                rels = ("rel %-4s" % rel) if rel is not None else "rel -   "
                lines.append("        %s %-16s %-12s %s%s"
                             % (rels, _price(h.get("price")), (h.get("size") or "")[:12],
                                str(h.get("item") or "")[:70], extra))
    return "\n".join(lines)


# =====================================================================================================
# Fixtures. HERMETIC: no network, no PowerShell, no browser. The literals below are frozen shapes of
# the real surfaces, and each one names its source script and the date it was taken.
# =====================================================================================================

# probe-ingredient.ps1 -Json, shape frozen 2026-08-24 from the script's own emitter (the `if ($Json)`
# block and the [pscustomobject] above it). TWO state-like fields per store is the point of this
# fixture: `state` is transport, `verdict` is the ladder.
PROBE_JSON_SAMPLE = {
    "probed": ["bakers", "family-fare"],
    "browser_required": ["Hy-Vee", "Aldi", "Fareway", "Sam's Club", "Walmart"],
    "results": [
        {"term": "guacamole", "server_result": "CANDIDATES-FOUND",
         "adjudication": "REQUIRED - a candidate is not a carriage claim; the pricer agent decides "
                         "which row, if any, is the ingredient",
         "responded": ["Baker's"], "unit": "each", "ms": 1841,
         "stores": [
             {"store": "Baker's", "state": "OK", "note": "kroger-public-api, locationId 61500319",
              "verdict": "MATCHES", "term_used": "guacamole",
              "attempts": [{"term": "guacamole", "state": "OK", "hits": 12}],
              "reason": "",
              "hits": [{"item": "Wholly Guacamole Classic", "price": 4.99, "size": "15 oz",
                        "relevance": 118, "url": "https://www.bakersplus.com/p/1"},
                       {"item": "Kroger Guacamole Mix", "price": 1.29, "size": "1 oz",
                        "relevance": 104, "url": "https://www.bakersplus.com/p/2"}]},
             {"store": "Family Fare", "state": "ERROR",
              "note": "The remote server returned an error: (400) Bad Request.",
              "verdict": "UNUSABLE", "term_used": "guacamole",
              "attempts": [{"term": "guacamole", "state": "ERROR", "hits": 0}],
              "reason": "The remote server returned an error: (400) Bad Request.  [likely Freshop "
                        "throttling - it is search-budget bound; retry later. This is BLOCKED, not "
                        "absence.]",
              "hits": []}]},
        {"term": "pico de gallo", "server_result": "NO-CANDIDATES",
         "adjudication": "REQUIRED", "responded": [], "unit": "", "ms": 2210,
         "stores": [
             {"store": "Baker's", "state": "OK", "note": "kroger-public-api, locationId 61500319",
              "verdict": "EMPTY", "term_used": "pico",
              "attempts": [{"term": "pico de gallo", "state": "OK", "hits": 0},
                           {"term": "pico", "state": "OK", "hits": 0}],
              "reason": "no candidates on any of 2 ladder rung(s)", "hits": []},
             {"store": "Family Fare", "state": "NO-CREDENTIALS",
              "note": "grocery\\.krogerkey missing and KROGER_CLIENT_ID/SECRET unset",
              "verdict": "UNUSABLE", "term_used": "pico de gallo",
              "attempts": [], "reason": "", "hits": []}]},
        {"term": "korean-rice-cakes", "server_result": "NO-CANDIDATES",
         "adjudication": "REQUIRED", "responded": [], "unit": "", "ms": 3010,
         "stores": [
             {"store": "Baker's", "state": "OK", "note": "", "verdict": "EMPTY",
              "term_used": "korean-rice-cakes",
              "attempts": [{"term": "korean-rice-cakes", "state": "OK", "hits": 0}],
              "reason": "no candidates on any of 1 ladder rung(s)", "hits": []},
             {"store": "Family Fare", "state": "OK", "note": "", "verdict": "EMPTY",
              "term_used": "korean-rice-cakes",
              "attempts": [{"term": "korean-rice-cakes", "state": "OK", "hits": 0}],
              "reason": "no candidates on any of 1 ladder rung(s)", "hits": []}]},
    ],
}

# pull-browser-stores.py --lookup-out, shape frozen 2026-08-24 from write_lookup()/lookup_verdict().
LOOKUP_SAMPLE_FAREWAY = {
    "store": "Fareway", "store_key": "fareway", "generated": "2026-08-24T09:00:00",
    "ladder": "rung 1 only - this driver searches the term AS GIVEN ...", "note": "",
    "results": [
        {"term": "guacamole", "state": "MATCHES", "term_used": "guacamole",
         "attempts": [{"term": "guacamole", "state": "OK", "hits": 6}],
         "hits": [{"item": "Fareway Guacamole 8 oz", "price": 3.99, "size": "8 oz",
                   "relevance": None, "url": "https://shop.fareway.com/p/1"}],
         "reason": "rung 1 only ..."},
        {"term": "pico de gallo", "state": "EMPTY", "term_used": "pico de gallo",
         "attempts": [{"term": "pico de gallo", "state": "OK", "hits": 0}], "hits": [],
         "reason": "rung 1 only ..."},
        {"term": "korean-rice-cakes", "state": "UNUSABLE", "term_used": "korean-rice-cakes",
         "attempts": [{"term": "korean-rice-cakes", "state": "UNUSABLE", "hits": 0}], "hits": [],
         "reason": "could not read the page: ERR:REFUSING TO EXTRACT: no __APOLLO_CLIENT__"},
    ],
}


def selftest():
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    print("price-evidence self-test (hermetic: no network, no shell, no browser)")

    roster, why = read_store_roster()
    T("the seven store names are READ out of ingredient-queue.ps1, never copied",
      len(roster) == 7 and "Baker's" in roster and "Sam's Club" in roster, "%s %s" % (roster, why))
    blind, why2 = read_store_roster(os.path.join(HERE, "no-such-file.ps1"))
    T("MUST FIRE  an unreadable roster reads BLIND (empty + a why), never a hardcoded fallback",
      blind == [] and why2, "%s %s" % (blind, why2))

    terms = ["guacamole", "pico de gallo", "korean-rice-cakes"]
    by_term, units = from_probe(PROBE_JSON_SAMPLE)
    T("MUST FIRE  the evidence state is probe's VERDICT field, not its transport state",
      by_term["guacamole"]["Baker's"]["state"] == "MATCHES",
      json.dumps(by_term["guacamole"]["Baker's"]))
    ff = by_term["guacamole"]["Family Fare"]
    T("MUST FIRE  a probe transport ERROR lands as UNUSABLE with the exception text in the reason - "
      "and NEVER as EMPTY",
      ff["state"] == "UNUSABLE" and "400" in ff["reason"] and "ERROR" in ff["reason"],
      json.dumps(ff))
    nc = by_term["pico de gallo"]["Family Fare"]
    T("MUST FIRE  NO-CREDENTIALS is UNUSABLE with its note as the reason, not an empty shelf",
      nc["state"] == "UNUSABLE" and "krogerkey" in nc["reason"], json.dumps(nc))
    T("CLEAN TWIN a real ladder EMPTY stays EMPTY, and keeps the rung that answered",
      by_term["pico de gallo"]["Baker's"]["state"] == "EMPTY"
      and by_term["pico de gallo"]["Baker's"]["term_used"] == "pico",
      json.dumps(by_term["pico de gallo"]["Baker's"]))
    T("the unit probe looked up rides along", units["guacamole"] == "each", json.dumps(units))

    fw = from_lookup("Fareway", LOOKUP_SAMPLE_FAREWAY, terms)
    T("a driver lookup keeps its three states per term",
      [fw[t]["state"] for t in terms] == ["MATCHES", "EMPTY", "UNUSABLE"],
      json.dumps([fw[t]["state"] for t in terms]))
    missing = from_lookup("Sam's Club", None, terms, "the lookup never produced an output file")
    T("MUST FIRE  a MISSING lookup output makes that store UNUSABLE for every term of the batch",
      all(missing[t]["state"] == "UNUSABLE" for t in terms)
      and all("never produced" in missing[t]["reason"] for t in terms),
      json.dumps(missing))
    partial = from_lookup("Sam's Club", {"results": [LOOKUP_SAMPLE_FAREWAY["results"][0]]}, terms)
    T("MUST FIRE  a term the lookup never mentions is UNUSABLE, never assumed EMPTY",
      partial["pico de gallo"]["state"] == "UNUSABLE"
      and partial["guacamole"]["state"] == "MATCHES", json.dumps(partial["pico de gallo"]))

    doc = build("drill-run", 1, terms, by_term, units,
                {"Fareway": fw, "Sam's Club": missing}, roster, generated="2026-08-24T09:00:00")
    per = {s["store"]: s for s in doc["terms"][0]["stores"]}
    T("every one of the seven stores is present for every term",
      all(len(t["stores"]) == 7 for t in doc["terms"]),
      json.dumps([len(t["stores"]) for t in doc["terms"]]))
    T("MUST FIRE  a store no pre-pass reaches is UNUSABLE with its tier named - Hy-Vee is the "
      "pricer's own tab, Walmart and Aldi are attended",
      per["Hy-Vee"]["state"] == "UNUSABLE" and per["Hy-Vee"]["tier"] == TIER_PRICER
      and per["Walmart"]["tier"] == TIER_ATTENDED and per["Aldi"]["state"] == "UNUSABLE",
      json.dumps([per["Hy-Vee"], per["Walmart"]]))
    T("MUST FIRE  no evidence row ever carries a QUEUE state - the two vocabularies never mix",
      all(s["state"] in ("MATCHES", "EMPTY", "UNUSABLE")
          for t in doc["terms"] for s in t["stores"]),
      json.dumps(tally(doc)))
    try:
        row("Aldi", "not-carried")
        T("MUST FIRE  a queue state offered as a search state is refused", False, "accepted")
    except ValueError:
        T("MUST FIRE  a queue state offered as a search state is refused", True)
    T("hits stay capped at 8 in the row builder",
      len(row("Aldi", "MATCHES", hits=[{"item": str(i)} for i in range(30)])["hits"]) == HIT_CAP)

    blinddoc = build("drill-run", 2, terms, by_term, units, {"Fareway": fw}, [],
                     roster_why="ingredient-queue.ps1 is unreadable")
    T("MUST FIRE  a blind roster enumerates only what was gathered AND records a finding saying so",
      any("roster could not be read" in f for f in blinddoc["findings"])
      and all(len(t["stores"]) == 3 for t in blinddoc["terms"]),
      json.dumps(blinddoc["findings"]))

    d2, why3 = parse_probe_stdout("WARNING: something\n" + json.dumps(PROBE_JSON_SAMPLE))
    T("probe stdout parses even with a PowerShell warning printed ahead of it",
      d2 is not None and len(d2["results"]) == 3, why3)
    d3, why4 = parse_probe_stdout("Get-KrogerToken : the remote server refused")
    T("MUST FIRE  stdout with no JSON in it returns a why, never a silently empty result",
      d3 is None and "no JSON object" in why4, "%s %s" % (d3, why4))

    txt = render(doc, path="R\\price-evidence\\batch-1.json")
    T("the render names every term and every store state",
      all(("'%s'" % t) in txt for t in terms) and "UNUSABLE" in txt and "MATCHES" in txt,
      txt[:200])
    T("MUST FIRE  the render shows a no-honest-price row as such, never as $0.00",
      "no-honest-price" in render(build("r", 1, ["x"], {"x": {"Baker's": row(
          "Baker's", "MATCHES", hits=[{"item": "a", "price": None}])}}, {}, {}, ["Baker's"])),
      "a null price rendered as a number")

    print("")
    if bad:
        print("price-evidence SELF-TEST FAIL (%d)" % len(bad))
        print("PRICE-EVIDENCE-COMPLETE")
        return 1
    print("price-evidence SELF-TEST PASS")
    print("PRICE-EVIDENCE-COMPLETE")
    return 0


if __name__ == "__main__":
    import sys
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    print(__doc__)
    print("PRICE-EVIDENCE-COMPLETE")
    sys.exit(2)
