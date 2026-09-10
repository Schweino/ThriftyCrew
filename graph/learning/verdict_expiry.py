"""Verdict expiry: a model verdict is a statement about a listing on one day, and it expires.

    python graph/learning/verdict_expiry.py              # report, writes nothing
    python graph/learning/verdict_expiry.py --json       # for ops/brain-report.ps1
    python graph/learning/verdict_expiry.py --emit       # nightly stage 0b: write tonight's re-ask list
    python graph/learning/verdict_expiry.py --db COPY --now 2026-12-01T00:00:00 --emit --reask-file X
                                                         # rehearse on a copy of graph.db
    python graph/learning/verdict_expiry.py --selftest

WS 7b of design/PLAN-brain-v2-2026-09-09.md.

THE PROPERTY. A brain forgets on evidence. This graph never did: a model's `llm_rejected` from August
is still refusing that listing in November, after the store changed the product, the catalog grew a
new include, and the model itself was replaced. The board's own quarter is 90 days; a verdict about
the board is given the same life.

*** THE PLAN'S VERSION WOULD HAVE EXPIRED NOTHING, AND THEN EVERYTHING. *** Measured 2026-09-10 before
building: all 4,141 rows of question_verdicts carry the SAME decided_at, 2026-08-21T01:37:15, because
graph/pipeline/state.py rebuilds the table with DELETE and re-stamps every row with the rebuild's own
time. So "decided_at + 90 days" would expire all 4,141 on one night, and a rebuild the day before would
reset all of them. state.py now CARRIES the date forward for an unchanged verdict (carried_decided_at),
and this file reads it. And dropping an expired row from the bank - the plan's "layer 4.5 treats it as
absent" - re-asks nothing on its own: resolve.py's pending_questions never selects an observation already
at llm_*, so the question would simply never be posed again. resolve.py therefore reads the list this
writes, selects those questions, skips their banked answer and their own precedent, and re-banks the
new answer with a new date.

WHAT EXPIRES. Only `llm_rejected` and `llm_confirmed`, and only when authority.decided_by_stamp reads
the reason as the MODEL's. Never:
  known_wrong            an adjudicated ruling. Absolute, by the resolver's own design.
  escalated, llm_match_unverified
                         a question WAITING for a reviewer. Expiring it answers nothing.
  a reviewer's verdict   a person's ruling does not lapse on a timer; that is a ruling for a person.
An expired `llm_rejected` is re-asked only if the listing was still captured inside the quarter - a
product nobody sells any more has nothing to re-decide. An expired `llm_confirmed` is re-asked only if
that commodity's GOLD changed after the verdict, because a match nothing has contradicted is not made
wrong by age alone.

THE RATE LIMIT AND ITS STOP BEHAVIOUR. At most MAX_REASKS_PER_NIGHT, oldest first, recorded in
docs/CONTROL-CONSTANTS.md. `--emit` also reads the list it wrote LAST night and counts how many of those
questions carry a newer date now; a list that did not land is spoken, because a re-ask stage that
silently stopped reads exactly like a night with nothing expired.

THE QUARTER IS READ, NEVER RESTATED. From grocery/capture-policy-lib.ps1 `$script:QuarterDays`, the
same way graph/agentic/verifier.py reads MaxCarryDays. A file without it is refused, not defaulted.

SCOPE OF A CLEAN REPORT: "nothing expired" is a statement about the dates in the bank. The bank is
rebuilt only when someone runs state.py, so a verdict the nightly resolver made and nobody banked has
no row here and cannot expire - it is absent, not fresh.

AND "STILL CAPTURED" IS ONLY AS CURRENT AS price_observations. Measured while building this, 2026-09-10:
all 26,740 observation rows in graph.db are dated 2026-07-14 to 2026-08-21, so the graph has perceived
no capture for 20 days while the nightly input check read green on the database file's mtime. Until
that import runs again, every verdict that expires reads "no longer captured" and nothing is re-asked -
which is the correct answer to the question asked, and a loud sign the question's input stopped.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import re
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GRAPH = os.path.dirname(HERE)
REPO = os.path.dirname(GRAPH)
sys.path.insert(0, os.path.join(GRAPH, "lib"))

DB = os.path.join(GRAPH, "sqlite", "graph.db")
POLICY = os.path.join(REPO, "grocery", "capture-policy-lib.ps1")
GOLD = os.path.join(GRAPH, "gold", "gold.jsonl")
REASK_FILE = os.environ.get("GRAPH_VERDICT_REASK") or os.path.join(GRAPH, "sqlite", "verdict-reask.json")
FINGERPRINTS = os.path.join(GRAPH, "sqlite", "gold-fingerprints.json")

# A FIRST PLAUSIBLE VALUE, NOT A SWEEP. The nightly resolve lane has run 150 minutes of window with
# 20,478 questions settled deterministically and 0 contested on 2026-09-09; 200 re-asks is well under
# one checkpoint batch-set of model calls and leaves the window for new captures. When the first real
# expiry night lands (2026-11-19 for the rows dated 2026-08-21), the number that moved gets recorded here
# with what else was tried.
MAX_REASKS_PER_NIGHT = 200
# A list older than this is not tonight's list. The nightly window runs 21:30 to 06:30, so a list
# written at 21:31 is still current at 06:29; one from a night the stage failed must not re-ask twice.
FRESH_HOURS = 18

EXPIRABLE = ("llm_rejected", "llm_confirmed")
MODEL_AUTHORS = ("model",)


def quarter_days(policy_path: str = POLICY) -> int:
    """The board's quarter, read from the capture policy. Raises rather than defaulting."""
    with open(policy_path, encoding="utf-8-sig") as fh:
        for line in fh:
            m = re.match(r"\s*\$script:QuarterDays\s*=\s*(\d+)\s*$", line)
            if m:
                return int(m.group(1))
    raise RuntimeError("no $script:QuarterDays in %s - the quarter is read, never assumed" % policy_path)


def _parse(ts):
    try:
        return _dt.datetime.fromisoformat(str(ts)[:19])
    except Exception:
        return None


def _author(status, reason):
    from authority import decided_by_stamp
    return decided_by_stamp(status, reason)


def plan(rows, now, qdays, cap, captured, gold_since, author=_author):
    """What expires tonight and what is re-asked. PURE over its inputs.

    rows        dicts with commodity_id, product_key, status, reason, decided_at
    captured    {(commodity_id, product_key)} seen inside the quarter
    gold_since  {commodity_id: iso of the last gold change, or ""}
    """
    life = _dt.timedelta(days=qdays)
    dates = set()
    first_expiry = None
    expired = {}
    out = {"total": len(rows), "undated": 0, "not_expirable": 0, "reviewer_authored": 0,
           "skipped_not_captured": 0, "skipped_gold_unchanged": 0}
    eligible = []
    for r in rows:
        d = _parse(r.get("decided_at"))
        if d is None:
            out["undated"] += 1
            continue
        dates.add(d.date().isoformat())
        st = r.get("status")
        if st not in EXPIRABLE:
            out["not_expirable"] += 1
            continue
        if author(st, r.get("reason")) not in MODEL_AUTHORS:
            out["reviewer_authored"] += 1
            continue
        exp = d + life
        if first_expiry is None or exp < first_expiry:
            first_expiry = exp
        if exp > now:
            continue
        expired[st] = expired.get(st, 0) + 1
        key = (r.get("commodity_id"), r.get("product_key"))
        if st == "llm_rejected" and key not in captured:
            out["skipped_not_captured"] += 1
            continue
        if st == "llm_confirmed":
            since = _parse(gold_since.get(r.get("commodity_id")) or "")
            if since is None or since <= d:
                out["skipped_gold_unchanged"] += 1
                continue
        eligible.append((d, key, st))
    eligible.sort(key=lambda x: (x[0], x[1]))
    take = eligible[:max(0, int(cap))]
    out.update({
        "distinct_dates": len(dates),
        "first_expiry": first_expiry.strftime("%Y-%m-%dT%H:%M:%S") if first_expiry else None,
        "expired": expired,
        "expired_total": sum(expired.values()),
        "eligible": len(eligible),
        "reask": [[k[0], k[1], st, d.strftime("%Y-%m-%dT%H:%M:%S")] for d, k, st in take],
        "deferred_by_cap": max(0, len(eligible) - len(take)),
    })
    return out


def reask_keys(doc, now, fresh_hours=FRESH_HOURS):
    """{(commodity_id, product_key)} from a re-ask list, or an EMPTY set when it is not tonight's.

    resolve.py imports this. A stale list is empty, never partly honoured: a night whose expiry stage
    failed must re-ask nothing rather than repeat yesterday's questions.
    """
    if not isinstance(doc, dict):
        return set()
    g = _parse(doc.get("generated_at"))
    if g is None or not (0 <= (now - g).total_seconds() <= fresh_hours * 3600):
        return set()
    out = set()
    for item in doc.get("reask") or []:
        if isinstance(item, (list, tuple)) and len(item) >= 2 and item[0] and item[1]:
            out.add((item[0], item[1]))
    return out


def landed(prev_doc, rows):
    """(landed, of): how many of last night's re-asks now carry a date newer than that list."""
    if not isinstance(prev_doc, dict):
        return None
    g = _parse(prev_doc.get("generated_at"))
    keys = [(i[0], i[1]) for i in (prev_doc.get("reask") or []) if isinstance(i, (list, tuple)) and len(i) >= 2]
    if g is None or not keys:
        return None
    by = {(r.get("commodity_id"), r.get("product_key")): _parse(r.get("decided_at")) for r in rows}
    n = sum(1 for k in keys if by.get(k) is None or (by.get(k) and by[k] >= g))
    return n, len(keys)


def gold_fingerprints(gold_rows, prior, now_iso):
    """{commodity_id: {"sha", "since"}}. `since` moves only when a commodity's gold CHANGES.

    A commodity seen for the first time gets since="" - a baseline, not a change. Without that rule the
    first night would call every commodity's gold "changed today" and every expired confirmed match
    would be re-asked at once.
    """
    by = {}
    for g in gold_rows:
        cid = g.get("commodity_node")
        if cid:
            by.setdefault(cid, []).append(json.dumps(g, sort_keys=True))
    out = {}
    for cid, items in by.items():
        sha = hashlib.sha1("\n".join(sorted(items)).encode("utf-8")).hexdigest()[:16]
        p = (prior or {}).get(cid)
        if p is None:
            out[cid] = {"sha": sha, "since": ""}
        elif p.get("sha") != sha:
            out[cid] = {"sha": sha, "since": now_iso}
        else:
            out[cid] = p
    return out


def _load_json(path):
    try:
        with open(path, encoding="utf-8-sig") as fh:
            return json.load(fh)
    except Exception:
        return None


def read_state(db_path, now, qdays):
    from ids import norm_text
    con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
    con.row_factory = sqlite3.Row
    try:
        rows = [dict(r) for r in con.execute(
            "SELECT commodity_id, product_key, status, reason, decided_at FROM question_verdicts")]
        # DATE-granular: observed_at is stored as a bare date ('2026-08-20'), and a string comparison
        # against '2026-08-21T02:00:00' would drop that whole first day of the quarter.
        since = (now - _dt.timedelta(days=qdays)).date().isoformat()
        newest = (con.execute("SELECT max(observed_at) FROM price_observations").fetchone() or [None])[0]
        captured = set()
        for r in con.execute("SELECT DISTINCT commodity_id, product_name FROM price_observations "
                             "WHERE observed_at >= ? AND match_status IN ('llm_rejected','llm_confirmed')",
                             (since,)):
            captured.add((r["commodity_id"], norm_text(r["product_name"] or "")))
    finally:
        con.close()
    return rows, captured, newest


def run(db_path, now, emit, reask_file, fp_file):
    qdays = quarter_days()
    rows, captured, newest = read_state(db_path, now, qdays)
    gold_rows = []
    try:
        with open(GOLD, encoding="utf-8") as fh:
            gold_rows = [json.loads(l) for l in fh if l.strip()]
    except OSError:
        pass
    now_iso = now.strftime("%Y-%m-%dT%H:%M:%S")
    fps = gold_fingerprints(gold_rows, _load_json(fp_file) or {}, now_iso)
    p = plan(rows, now, qdays, MAX_REASKS_PER_NIGHT, captured,
             {cid: v.get("since") for cid, v in fps.items()})
    p["quarter_days"] = qdays
    p["cap"] = MAX_REASKS_PER_NIGHT
    p["last_night"] = landed(_load_json(reask_file), rows)
    # WS 11: "still captured" is only as current as this. A graph whose newest observation is weeks old cannot
    # tell a listing nobody sells from a listing nobody imported, and the report must say which it is judging.
    p["observations_newest"] = newest
    nd = _parse(newest) if newest else None
    p["observations_newest_age_days"] = (now.date() - nd.date()).days if nd else None
    if emit:
        # Fingerprints first and the list LAST: a crash between them leaves no list, and no list is
        # "re-ask nothing", which is the safe reading of a failed stage.
        with open(fp_file, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(fps, fh, indent=1, sort_keys=True)
        doc = {"generated_at": now_iso, "quarter_days": qdays, "cap": MAX_REASKS_PER_NIGHT,
               "expired_total": p["expired_total"], "deferred_by_cap": p["deferred_by_cap"],
               "reask": [[k[0], k[1]] for k in p["reask"]]}
        tmp = reask_file + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(doc, fh, indent=1)
        os.replace(tmp, reask_file)
    return p


def render(p, emitted):
    ex = p["expired"]
    lines = [
        "VERDICT EXPIRY - a model verdict lives one quarter (%d days, read from the capture policy)" % p["quarter_days"],
        "",
        "  verdicts in the bank        : %d, decided on %d distinct date(s)" % (p["total"], p["distinct_dates"]),
        "  never expire                : %d known-wrong / queued for a reviewer, %d reviewer-authored, %d undated"
        % (p["not_expirable"], p["reviewer_authored"], p["undated"]),
        "  first model verdict expires : %s" % (p["first_expiry"] or "none can"),
        "  expired now                 : %d (%s)" % (p["expired_total"],
                                                       ", ".join("%s %d" % kv for kv in sorted(ex.items())) or "none"),
        "  not re-asked                : %d no longer captured, %d confirmed with gold unchanged"
        % (p["skipped_not_captured"], p["skipped_gold_unchanged"]),
        "  re-asked tonight            : %d of %d eligible, cap %d, %d deferred to later nights"
        % (len(p["reask"]), p["eligible"], p["cap"], p["deferred_by_cap"]),
        "  graph observations newest   : %s (%s day(s) old) - 'still captured' is judged against these"
        % (p.get("observations_newest") or "none", p.get("observations_newest_age_days")),
    ]
    ln = p.get("last_night")
    if ln is not None:
        lines.append("  last night's list landed    : %d of %d" % ln)
        if ln[0] < ln[1]:
            lines.append("  LAST NIGHT'S RE-ASK DID NOT FULLY LAND - the resolve stage re-asked fewer than it was given.")
    if p["distinct_dates"] <= 1 and p["total"]:
        lines.append("  ONE DATE ACROSS THE WHOLE BANK: the dates are a rebuild's, not decisions'. Nothing can expire")
        lines.append("  on evidence until verdicts carry the day they were decided (state.py now carries it forward).")
    lines += ["", "  list %s" % ("written for resolve.py tonight" if emitted else "NOT written (report only)"), "",
              "SCOPE OF A CLEAN REPORT: dates in the bank only. A verdict nobody banked cannot expire; it is absent.",
              "VERDICT-EXPIRY-COMPLETE total=%d expired=%d reask=%d deferred=%d"
              % (p["total"], p["expired_total"], len(p["reask"]), p["deferred_by_cap"])]
    return "\n".join(lines)


def selftest():
    import shutil
    import tempfile

    fails, ran = [], []

    def case(label, name, ok, detail=""):
        ran.append(name)
        if not ok:
            fails.append("%s %s" % (label, name))
        print("  %-14s %-60s %s" % (label, name, "ok" if ok else "FAIL " + str(detail)[:80]))

    tmp = tempfile.mkdtemp(prefix="verdict-expiry-selftest-")
    try:
        pol = os.path.join(tmp, "policy.ps1")
        with open(pol, "w", encoding="utf-8") as fh:
            fh.write("# The quarter.\n$script:QuarterDays = 90\n$script:MaxCarryDays = 90\n")
        case("MUST FIRE", "the quarter is read from the capture policy", quarter_days(pol) == 90)
        with open(pol, "w", encoding="utf-8") as fh:
            fh.write("$script:MaxCarryDays = 90\n")
        try:
            quarter_days(pol)
            refused = False
        except RuntimeError:
            refused = True
        case("MUST FIRE", "a policy without QuarterDays is REFUSED, never defaulted to 90", refused)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    now = _dt.datetime(2026, 12, 1, 0, 0, 0)
    model = lambda st, reason: "model"
    auth = lambda st, reason: "reviewer" if "reviewer" in (reason or "") else "model"

    def row(cid, pk, st, at, reason="llm: no"):
        return {"commodity_id": cid, "product_key": pk, "status": st, "reason": reason, "decided_at": at}

    old, fresh = "2026-08-21T01:37:15", "2026-11-20T00:00:00"
    rows = [row("c:a", "p1", "llm_rejected", old), row("c:a", "p2", "llm_rejected", fresh)]
    p = plan(rows, now, 90, 200, {("c:a", "p1"), ("c:a", "p2")}, {}, model)
    case("MUST FIRE", "an expired model rejection of a listing still captured is re-asked",
         [r[:2] for r in p["reask"]] == [["c:a", "p1"]], p["reask"])
    case("MUST NOT FIRE", "a verdict inside its quarter is not expired",
         p["expired_total"] == 1, p["expired"])
    case("CLEAN TWIN", "the first expiry is the oldest date plus the quarter",
         p["first_expiry"] == "2026-11-19T01:37:15" and p["distinct_dates"] == 2, p)

    never = [row("c:b", "k", "known_wrong", old), row("c:b", "e", "escalated", old),
             row("c:b", "u", "llm_match_unverified", old)]
    p2 = plan(never, now, 90, 200, {("c:b", "k"), ("c:b", "e"), ("c:b", "u")}, {}, model)
    case("MUST NOT FIRE", "known-wrong, escalated and unverified verdicts never expire",
         p2["expired_total"] == 0 and p2["not_expirable"] == 3, p2)
    p3 = plan([row("c:c", "r", "llm_rejected", old, reason="reviewer: not this")], now, 90, 200,
              {("c:c", "r")}, {}, auth)
    case("MUST NOT FIRE", "a reviewer's ruling does not lapse on a timer",
         p3["reask"] == [] and p3["reviewer_authored"] == 1, p3)
    p4 = plan([row("c:d", "gone", "llm_rejected", old)], now, 90, 200, set(), {}, model)
    case("MUST NOT FIRE", "an expired rejection of a listing no longer captured is not re-asked",
         p4["reask"] == [] and p4["skipped_not_captured"] == 1 and p4["expired_total"] == 1, p4)
    conf = [row("c:e", "m", "llm_confirmed", old)]
    p5 = plan(conf, now, 90, 200, set(), {"c:e": ""}, model)
    case("MUST NOT FIRE", "an expired match whose gold never changed is not re-asked",
         p5["reask"] == [] and p5["skipped_gold_unchanged"] == 1, p5)
    p6 = plan(conf, now, 90, 200, set(), {"c:e": "2026-10-01T00:00:00"}, model)
    case("MUST FIRE", "an expired match whose gold changed after it is re-asked",
         [r[:2] for r in p6["reask"]] == [["c:e", "m"]], p6)
    p7 = plan([row("c:f", "x", "llm_rejected", "not a date")], now, 90, 200, {("c:f", "x")}, {}, model)
    case("MUST NOT FIRE", "an undated verdict is counted, never expired", p7["undated"] == 1 and p7["reask"] == [])

    many = [row("c:g", "p%d" % i, "llm_rejected", "2026-08-%02dT00:00:00" % (10 + i)) for i in range(5)]
    p8 = plan(many, now, 90, 2, {("c:g", "p%d" % i) for i in range(5)}, {}, model)
    case("MUST FIRE", "over the cap, the OLDEST are re-asked and the rest deferred",
         [r[1] for r in p8["reask"]] == ["p0", "p1"] and p8["deferred_by_cap"] == 3, p8["reask"])

    doc = {"generated_at": "2026-11-30T21:31:00", "reask": [["c:a", "p1"], ["c:b", "p2"]]}
    case("CLEAN TWIN", "tonight's list yields its keys",
         reask_keys(doc, _dt.datetime(2026, 12, 1, 6, 29)) == {("c:a", "p1"), ("c:b", "p2")})
    case("MUST NOT FIRE", "a list older than FRESH_HOURS yields NO keys, not some",
         reask_keys(doc, _dt.datetime(2026, 12, 2, 6, 0)) == set())
    case("MUST NOT FIRE", "a list from the future yields no keys",
         reask_keys(doc, _dt.datetime(2026, 11, 30, 12, 0)) == set())
    case("MUST NOT FIRE", "a malformed list yields no keys", reask_keys(["x"], now) == set())

    prev = {"generated_at": "2026-11-30T21:31:00", "reask": [["c:a", "p1"], ["c:a", "p2"]]}
    after = [row("c:a", "p1", "llm_rejected", "2026-12-01T01:00:00"), row("c:a", "p2", "llm_rejected", old)]
    case("MUST FIRE", "a re-ask that did not land is counted as not landed",
         landed(prev, after) == (1, 2), landed(prev, after))

    g1 = [{"commodity_node": "c:a", "label": "MATCH", "product": "x"}]
    f1 = gold_fingerprints(g1, {}, "2026-11-01T00:00:00")
    case("MUST NOT FIRE", "a commodity's first fingerprint is a baseline, not a change", f1["c:a"]["since"] == "")
    f2 = gold_fingerprints(g1, f1, "2026-11-02T00:00:00")
    case("CLEAN TWIN", "unchanged gold keeps its fingerprint and its since", f2 == f1)
    f3 = gold_fingerprints(g1 + [{"commodity_node": "c:a", "label": "NO_MATCH", "product": "y"}], f1,
                           "2026-11-03T00:00:00")
    case("MUST FIRE", "a changed gold row moves since to now", f3["c:a"]["since"] == "2026-11-03T00:00:00", f3)

    # state.py carries the decision date: the prerequisite this whole file stands on.
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("graph_state", os.path.join(GRAPH, "pipeline", "state.py"))
        st = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(st)
        prior = {("c:a", "p1"): ("llm_rejected", old)}
        case("MUST FIRE", "state.py keeps the decision date of an unchanged verdict",
             st.carried_decided_at(prior, ("c:a", "p1"), "llm_rejected", "2026-09-10T00:00:00") == old)
        case("MUST NOT FIRE", "a CHANGED verdict is not given its predecessor's date",
             st.carried_decided_at(prior, ("c:a", "p1"), "llm_confirmed", "2026-09-10T00:00:00")
             == "2026-09-10T00:00:00")
        case("CLEAN TWIN", "a new question is stamped with the rebuild time",
             st.carried_decided_at(prior, ("c:z", "q"), "llm_rejected", "2026-09-10T00:00:00")
             == "2026-09-10T00:00:00")
    except Exception as e:
        case("MUST FIRE", "state.py's carried_decided_at could be loaded", False, repr(e))

    print("")
    if fails:
        print("verdict_expiry selftest: %d FAILED of %d" % (len(fails), len(ran)))
        for f in fails:
            print("  " + f)
        print("VERDICT-EXPIRY-SELFTEST-COMPLETE")
        return 1
    print("verdict_expiry selftest: %d of %d cases pass" % (len(ran), len(ran)))
    print("VERDICT-EXPIRY-SELFTEST-COMPLETE")
    return 0


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--emit", action="store_true")
    ap.add_argument("--db", default=DB)
    ap.add_argument("--now", default=None, help="ISO time; for a rehearsal on a copy only")
    ap.add_argument("--reask-file", default=REASK_FILE)
    ap.add_argument("--fingerprints", default=FINGERPRINTS)
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    now = _parse(a.now) if a.now else _dt.datetime.now()
    if now is None:
        print("--now is not an ISO time", file=sys.stderr)
        return 2
    if not os.path.exists(a.db):
        print("VERDICT EXPIRY BLIND: no graph.db at %s - nothing was judged, which is not nothing expired" % a.db)
        print("VERDICT-EXPIRY-COMPLETE blind=1")
        return 3
    p = run(a.db, now, a.emit, a.reask_file, a.fingerprints)
    if a.json:
        slim = dict(p)
        slim["reask"] = len(p["reask"])
        print(json.dumps(slim, sort_keys=True))
        return 0
    print(render(p, a.emit))
    return 0


if __name__ == "__main__":
    sys.exit(main())
