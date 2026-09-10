"""Where the graph's learning loop stands, cheaply, as numbers with ages on them.

    python graph/learning/learning_status.py            # a table
    python graph/learning/learning_status.py --json     # for ops/brain-digest.ps1 and ops/brain-report.ps1
    python graph/learning/learning_status.py --selftest

WS 5d and WS 11 of design/PLAN-brain-v2-2026-09-09.md.

WHY A NEW ENTRY POINT RATHER THAN READING THE FILES FROM ops/. The morning digest first read
graph/learning/proposals.json directly, and ops/audit-cross-module-reach.ps1 correctly called that a
new reach into graph's internals. A sibling module is entitled to graph's FRONT DOOR - a script it
runs - and not to the state files behind it, because those change shape when graph reorganises and
nothing points at the reader when they do. graph/eval/status.py already exists and was considered: it
is the phase-gate report, it opens graph.db and runs the verifier, and a once-a-morning digest has no
business paying for that to count a JSON list.

WHAT IT MEASURED ON ITS FIRST RUN, AND WHY IT EXISTS. The loop PRODUCES and nothing CONSUMES. Stage 1
runs nightly; Stage 2 has no scheduler. 60 proposals had waited since 2026-08-21, the review packet was
frozen at 2026-08-21T01:01, every applied patch was dated 08-20 or 08-21, and the gold scoreboard's
newest run was 2026-08-21 - while nothing anywhere put an age next to any of those numbers.

AN ABSENT INPUT IS NULL AND NAMED, NEVER ZERO. `proposals_pending: 0` and "proposals.json could not be
read" are opposite findings, and a report that prints the same byte for both is the failure this
estate keeps paying for. Every field that could not be computed is null and listed under `unknown`.

SCOPE OF A CLEAN REPORT: UNSOUND. It reads what these files say. It cannot tell a proposal nobody
should accept from one nobody has looked at, and an old packet is a fact about the packet, not proof
that the review is wrong.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GRAPH = os.path.dirname(HERE)


def _load(path):
    """(value, ok). ok=False means the file was absent or would not parse - never a clean empty."""
    try:
        with open(path, encoding="utf-8-sig") as fh:
            return json.load(fh), True
    except Exception:
        return None, False


def _parse(ts):
    """A naive or Z-suffixed ISO timestamp, or None. Naive stamps here are LOCAL (the graph writes
    `datetime.now().isoformat()`), so they are compared against a local `now`, never mixed with UTC."""
    if not isinstance(ts, str) or not ts.strip():
        return None
    try:
        t = _dt.datetime.fromisoformat(ts.strip().replace("Z", "+00:00"))
        return t.replace(tzinfo=None) if t.tzinfo else t
    except Exception:
        try:
            return _dt.datetime.strptime(ts.strip()[:10], "%Y-%m-%d")
        except Exception:
            return None


def _age(ts, now):
    t = _parse(ts)
    return None if t is None else round((now - t).total_seconds() / 86400.0, 1)


def status(root=None, now=None):
    """The whole report as a dict. Pure over a directory, so the fixtures drive a temp tree."""
    graph = root or GRAPH
    now = now or _dt.datetime.now()
    out, unknown = {}, []

    props, ok = _load(os.path.join(graph, "learning", "proposals.json"))
    if ok and isinstance(props, list):
        pend = [p for p in props if isinstance(p, dict) and p.get("status") == "proposed"]
        ages = [a for a in (_age(p.get("created_at"), now) for p in pend) if a is not None]
        out["proposals_total"] = len(props)
        out["proposals_pending"] = len(pend)
        out["proposals_oldest_days"] = max(ages) if ages else None
        out["proposals_held_for_human"] = sum(1 for p in props if isinstance(p, dict)
                                             and p.get("status") == "held_for_human")
        # WS 11: FLOW, not backlog. A queue that is not draining and a producer that has STOPPED both show
        # a large pending count; only the age of the NEWEST proposal tells them apart.
        made = [a for a in (_age(p.get("created_at"), now) for p in props if isinstance(p, dict)) if a is not None]
        out["proposals_newest_days"] = min(made) if made else None
        out["proposals_new_7d"] = sum(1 for a in made if a <= 7)
    else:
        out["proposals_newest_days"] = None
        out["proposals_new_7d"] = None
        for k in ("proposals_total", "proposals_pending", "proposals_oldest_days",
                  "proposals_held_for_human"):
            out[k] = None
        unknown.append("learning/proposals.json")

    pkt, ok = _load(os.path.join(graph, "learning", "review-packet.json"))
    if ok and isinstance(pkt, dict):
        out["review_packet_generated_at"] = pkt.get("generated_at")
        out["review_packet_age_days"] = _age(pkt.get("generated_at"), now)
        out["review_packet_proposals"] = len(pkt.get("proposals") or [])
    else:
        out.update(review_packet_generated_at=None, review_packet_age_days=None,
                   review_packet_proposals=None)
        unknown.append("learning/review-packet.json")

    hpk, ok = _load(os.path.join(graph, "learning", "hunter-review-packet.json"))
    if ok and isinstance(hpk, dict):
        out["hunter_cases_pending"] = len(hpk.get("cases") or [])
        out["hunter_packet_age_days"] = _age(hpk.get("generated_at"), now)
    else:
        out.update(hunter_cases_pending=None, hunter_packet_age_days=None)
        unknown.append("learning/hunter-review-packet.json")

    patches, ok = _load(os.path.join(graph, "learning", "approved-patches.json"))
    if ok and isinstance(patches, list):
        applied = [p.get("applied_at") for p in patches if isinstance(p, dict) and p.get("applied_at")]
        out["patches_total"] = len(patches)
        out["patches_unapplied"] = len(patches) - len(applied)
        out["patches_last_applied_at"] = max(applied) if applied else None
        out["patches_last_applied_age_days"] = _age(max(applied), now) if applied else None
        out["patches_applied_30d"] = sum(1 for a in applied if (_age(a, now) is not None and _age(a, now) <= 30))
    else:
        out.update(patches_total=None, patches_unapplied=None, patches_last_applied_at=None,
                   patches_last_applied_age_days=None, patches_applied_30d=None)
        unknown.append("learning/approved-patches.json")

    holds, ok = _load(os.path.join(graph, "learning", "promotion-holds.json"))
    if ok and isinstance(holds, dict):
        hs = [h for h in (holds.get("holds") or []) if isinstance(h, dict)]
        hages = [a for a in (_age(h.get("held"), now) for h in hs) if a is not None]
        out["holds"] = len(hs)
        out["holds_oldest_days"] = max(hages) if hages else None
        # WS 7c: the rechecks the watchdog records, and the clear proposals they add up to. Computed by
        # promote_aliases' own functions, so there is one rule for what a streak is, not two.
        try:
            if HERE not in sys.path:
                sys.path.insert(0, HERE)
            from promote_aliases import clear_proposals, consecutive_inert, load_rechecks
            hist = load_rechecks(os.path.join(graph, "learning", "hold-rechecks.jsonl"))
            out["holds_recheck_days"] = len({r.get("date") for r in hist})
            rages = [a for a in (_age(r.get("date"), now) for r in hist) if a is not None]
            out["holds_recheck_newest_days"] = min(rages) if rages else None
            out["holds_clear_proposed"] = len(clear_proposals(hs, hist))
            out["holds_longest_inert_streak"] = max(
                [consecutive_inert(hist, h.get("commodity"), h.get("pattern"))[0] for h in hs] or [0])
        except Exception:                                    # noqa: BLE001
            out.update(holds_recheck_days=None, holds_clear_proposed=None, holds_longest_inert_streak=None,
                       holds_recheck_newest_days=None)
            unknown.append("learning/hold-rechecks.jsonl")
    else:
        out.update(holds=None, holds_oldest_days=None, holds_recheck_days=None,
                   holds_clear_proposed=None, holds_longest_inert_streak=None, holds_recheck_newest_days=None)
        unknown.append("learning/promotion-holds.json")

    runs, ok = _load(os.path.join(graph, "eval", "eval-runs.json"))
    if ok and isinstance(runs, list) and runs:
        last = max((r.get("run_at") or "") for r in runs if isinstance(r, dict))
        out["eval_runs"] = len(runs)
        out["eval_last_run_at"] = last or None
        out["eval_age_days"] = _age(last, now)
        out["eval_runs_7d"] = sum(1 for r in runs if isinstance(r, dict)
                                  and _age(r.get("run_at"), now) is not None and _age(r.get("run_at"), now) <= 7)
        # STALE AGAINST ITS INPUTS, not merely old. graph/README.md says re-score the gold set after
        # any prompt, model or resolver change; an old run with unchanged inputs is fine, and a
        # recent run that predates a gold edit is not. So the newest input mtime is the comparison.
        newest_input = 0.0
        for rel in ("gold/gold.jsonl", "gold/hunter-gold.jsonl", "gold/escalation-review.jsonl"):
            p = os.path.join(graph, rel)
            if os.path.exists(p):
                newest_input = max(newest_input, os.path.getmtime(p))
        prompts = os.path.join(graph, "prompts")
        if os.path.isdir(prompts):
            for dp, _dn, fn in os.walk(prompts):
                for f in fn:
                    newest_input = max(newest_input, os.path.getmtime(os.path.join(dp, f)))
        lt = _parse(last)
        if newest_input and lt is not None:
            inp = _dt.datetime.fromtimestamp(newest_input)
            out["eval_inputs_newest_at"] = inp.strftime("%Y-%m-%dT%H:%M:%S")
            out["eval_days_stale_vs_inputs"] = max(0.0, round((inp - lt).total_seconds() / 86400.0, 1))
        else:
            out["eval_inputs_newest_at"] = None
            out["eval_days_stale_vs_inputs"] = None
    else:
        out.update(eval_runs=None, eval_last_run_at=None, eval_age_days=None, eval_runs_7d=None,
                   eval_inputs_newest_at=None, eval_days_stale_vs_inputs=None)
        unknown.append("eval/eval-runs.json")

    out["unknown"] = unknown
    out["generated_at"] = now.strftime("%Y-%m-%dT%H:%M:%S")
    return out


def render(s):
    def v(k, suffix=""):
        x = s.get(k)
        return "UNKNOWN" if x is None else "%s%s" % (x, suffix)
    lines = [
        "GRAPH LEARNING LOOP - produced vs consumed, with ages",
        "",
        "  proposals pending         : %s of %s, oldest %s" % (v("proposals_pending"), v("proposals_total"),
                                                               v("proposals_oldest_days", "d")),
        "  held for a human          : %s" % v("proposals_held_for_human"),
        "  review packet             : %s proposal(s), generated %s (%s old)"
        % (v("review_packet_proposals"), v("review_packet_generated_at"), v("review_packet_age_days", "d")),
        "  hunter cases to rule      : %s, packet %s old" % (v("hunter_cases_pending"),
                                                            v("hunter_packet_age_days", "d")),
        "  patches applied last      : %s (%s ago), %s unapplied" % (v("patches_last_applied_at"),
                                                                     v("patches_last_applied_age_days", "d"),
                                                                     v("patches_unapplied")),
        "  promotion holds           : %s, oldest %s" % (v("holds"), v("holds_oldest_days", "d")),
        "  hold rechecks recorded    : %s day(s), longest inert streak %s, clear proposals %s"
        % (v("holds_recheck_days"), v("holds_longest_inert_streak"), v("holds_clear_proposed")),
        "  gold scoreboard last run  : %s (%s old), %s stale against its inputs"
        % (v("eval_last_run_at"), v("eval_age_days", "d"), v("eval_days_stale_vs_inputs", "d")),
        "",
    ]
    if s.get("unknown"):
        lines.append("  COULD NOT READ: %s - each is UNKNOWN above, never zero." % ", ".join(s["unknown"]))
        lines.append("")
    lines.append("SCOPE OF A CLEAN REPORT: UNSOUND. An age is a fact about a file, not a verdict on the review.")
    lines.append("LEARNING-STATUS-COMPLETE unknown=%d" % len(s.get("unknown") or []))
    return "\n".join(lines)


def selftest():
    import shutil
    import tempfile

    fails, ran = [], []

    def case(label, name, ok, detail=""):
        ran.append(name)
        if not ok:
            fails.append("%s %s" % (label, name))
        print("  %-14s %-58s %s" % (label, name, "ok" if ok else "FAIL " + str(detail)[:80]))

    now = _dt.datetime(2026, 9, 10, 12, 0, 0)
    tmp = tempfile.mkdtemp(prefix="learning-status-selftest-")
    try:
        os.makedirs(os.path.join(tmp, "learning"))
        os.makedirs(os.path.join(tmp, "eval"))
        os.makedirs(os.path.join(tmp, "gold"))

        def w(rel, obj):
            with open(os.path.join(tmp, rel), "w", encoding="utf-8") as fh:
                json.dump(obj, fh)

        # FROZEN FROM THE ESTATE'S REAL STATE ON 2026-09-09: a proposal waiting since 08-21.
        w("learning/proposals.json", [
            {"status": "proposed", "created_at": "2026-08-21T01:00:00"},
            {"status": "proposed", "created_at": "2026-09-07T12:00:00"},
            {"status": "applied", "created_at": "2026-08-20T00:00:00"},
            {"status": "held_for_human", "created_at": "2026-08-21T00:00:00"},
        ])
        w("learning/review-packet.json", {"generated_at": "2026-08-21T01:01:21", "proposals": [1, 2]})
        w("learning/approved-patches.json", [{"applied_at": "2026-08-20T18:22:55"}, {"applied_at": None}])
        w("learning/promotion-holds.json", {"holds": [
            {"held": "2026-08-21", "commodity": "a", "pattern": "p",
             "reason": "guards 2026-08-21: 1.59x unit-basis outlier vs its own link"},
            {"held": "2026-09-09"}]})
        with open(os.path.join(tmp, "learning", "hold-rechecks.jsonl"), "w", encoding="utf-8") as fh:
            for d in range(1, 31):
                fh.write(json.dumps({"date": "2026-08-%02d" % d, "board": "b", "commodity": "a",
                                     "pattern": "p", "hits": 0, "inert": True}) + "\n")
        w("eval/eval-runs.json", [{"run_at": "2026-08-21T01:04:51"}])
        with open(os.path.join(tmp, "gold", "gold.jsonl"), "w", encoding="utf-8") as fh:
            fh.write("{}\n")
        stamp = _dt.datetime(2026, 9, 1, 0, 0, 0).timestamp()
        os.utime(os.path.join(tmp, "gold", "gold.jsonl"), (stamp, stamp))

        s = status(tmp, now)
        case("MUST FIRE", "pending proposals are counted and aged by the OLDEST",
             s["proposals_pending"] == 2 and s["proposals_oldest_days"] == 20.5, s)
        case("MUST FIRE", "the review packet's age comes from its own generated_at",
             s["review_packet_age_days"] == 20.5, s["review_packet_age_days"])
        case("MUST FIRE", "an unapplied approved patch is counted", s["patches_unapplied"] == 1)
        # 11.0, derived by hand rather than copied from the output: the edit is 2026-09-01 00:00:00
        # and the run 2026-08-21 01:04:51, so 11 days less 3,891 s = 946,509 s = 10.9549 days, which
        # rounds to 11.0. This fixture first expected 10.9 - my arithmetic, not the code.
        case("MUST FIRE", "the scoreboard is stale against a gold edit that postdates it",
             s["eval_days_stale_vs_inputs"] == 11.0, s["eval_days_stale_vs_inputs"])
        case("MUST FIRE", "the oldest hold is found", s["holds_oldest_days"] == 20.5, s["holds_oldest_days"])
        # 3.0, derived by hand: the newest proposal is 2026-09-07T12:00:00 and now is 2026-09-10T12:00:00.
        # The first draft of this case said 2.5, which was my subtraction, not the code.
        case("MUST FIRE", "FLOW is counted beside backlog: one proposal in 7 days, the newest 3.0 days old",
             s["proposals_new_7d"] == 1 and s["proposals_newest_days"] == 3.0,
             {k: s.get(k) for k in ("proposals_new_7d", "proposals_newest_days")})
        case("MUST FIRE", "a patch applied inside 30 days counts, and no eval ran inside 7",
             s["patches_applied_30d"] == 1 and s["eval_runs_7d"] == 0, s)
        case("CLEAN TWIN", "the newest hold recheck is aged, so a stopped recorder can be seen",
             s["holds_recheck_newest_days"] == 11.5, s.get("holds_recheck_newest_days"))
        case("MUST FIRE", "a board hold inert for 30 recorded rechecks counts as one clear proposal",
             s["holds_clear_proposed"] == 1 and s["holds_longest_inert_streak"] == 30
             and s["holds_recheck_days"] == 30, s)

        # MUST NOT FIRE: the founding confusion of this whole plan, frozen.
        os.remove(os.path.join(tmp, "learning", "proposals.json"))
        s2 = status(tmp, now)
        case("MUST NOT FIRE", "an unreadable proposals file is NULL and named, never 0",
             s2["proposals_pending"] is None and "learning/proposals.json" in s2["unknown"], s2)
        w("learning/proposals.json", {"not": "a list"})
        s3 = status(tmp, now)
        case("MUST NOT FIRE", "a proposals file of the wrong SHAPE is unknown, not empty",
             s3["proposals_pending"] is None, s3["proposals_pending"])
        w("learning/proposals.json", [])
        s4 = status(tmp, now)
        case("CLEAN TWIN", "a genuinely empty list IS zero, and is not unknown",
             s4["proposals_pending"] == 0 and "learning/proposals.json" not in s4["unknown"], s4)

        # MUST NOT FIRE: a scoreboard newer than every input is not stale.
        newer = _dt.datetime(2026, 9, 5, 0, 0, 0).timestamp()
        os.utime(os.path.join(tmp, "gold", "gold.jsonl"), (newer, newer))
        w("eval/eval-runs.json", [{"run_at": "2026-09-06T00:00:00"}])
        case("MUST NOT FIRE", "a run newer than its inputs is 0 days stale",
             status(tmp, now)["eval_days_stale_vs_inputs"] == 0.0)

        # CLEAN TWIN: the rendered table says UNKNOWN in words and ends with its marker.
        txt = render(s2)
        case("CLEAN TWIN", "render prints UNKNOWN for a null field", "UNKNOWN" in txt)
        case("CLEAN TWIN", "render ends with the completion marker",
             txt.strip().splitlines()[-1].startswith("LEARNING-STATUS-COMPLETE"))
        case("CLEAN TWIN", "the JSON form round-trips", json.loads(json.dumps(s)) == s)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("")
    if fails:
        print("learning_status selftest: %d FAILED of %d" % (len(fails), len(ran)))
        for f in fails:
            print("  " + f)
        print("LEARNING-STATUS-SELFTEST-COMPLETE")
        return 1
    print("learning_status selftest: %d of %d cases pass" % (len(ran), len(ran)))
    print("LEARNING-STATUS-SELFTEST-COMPLETE")
    return 0


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    s = status()
    if a.json:
        print(json.dumps(s))
        return 0
    print(render(s))
    return 0


if __name__ == "__main__":
    sys.exit(main())
