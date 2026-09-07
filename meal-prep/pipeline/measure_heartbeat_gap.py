r"""measure_heartbeat_gap.py - how long can the daemon legitimately go quiet?

    python meal-prep/pipeline/measure_heartbeat_gap.py            # the measurement
    python meal-prep/pipeline/measure_heartbeat_gap.py --selftest # frozen fixtures, hermetic

WHY THIS EXISTS (2026-09-07, backlog E10's open half). `status_heartbeat` shipped in `9301d154` and
made a long run observable, and its own header names the real prize: "a hung lane looks exactly like
a slow one". It calls a stall when the counters stand still for a whole interval, and it repeats with
a count of intervals.

WHAT WAS NEVER CHECKED IS THE INTERVAL. `--status-every` defaults to 600 s, which was a guess. E10
asked for the calibration and named the number that matters: **the longest LEGITIMATE gap between
progress events**. Below that, "NO PROGRESS" is a slow page fetch and the message trains people to
ignore it. Above it, a real stall sits unreported for as long as it takes.

WHERE THE ANSWER ALREADY IS. Every run writes `lane-log.jsonl`, one timestamped row per lane event,
and seven completed runs hold 3,302 of them. The gap between consecutive rows IS how long the daemon
went without the `lane_lines` counter moving - one of the five the heartbeat compares - so the
distribution of those gaps is the measurement E10 asked for, already on disk.

THE OVERNIGHT TRAP. A run can be paused and resumed, and a gap that spans an operator going to bed
is not a lane being slow. Gaps over `--max-gap-min` (default 60) are reported SEPARATELY and excluded
from the percentiles rather than being silently kept or silently dropped - keeping them makes the p99
meaningless, and dropping them without saying so hides that a run was interrupted at all.

EVERY FIGURE CARRIES ITS CASE COUNT (`.claude/rules/measurement.md`). A p99 over 6 gaps is the
maximum wearing a percentile's clothes, and runs with too little history say so.

Exit 0 always: this is a measurement, not a gate.
"""
from __future__ import annotations

import argparse
import datetime
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.abspath(os.path.join(HERE, "..", "runs"))

MIN_GAPS = 20          # below this, no percentile is claimed
DEFAULT_MAX_GAP_MIN = 60


def parse_at(s):
    """A lane-log timestamp, or None. Tolerant by design: one unparseable row must not lose a run."""
    try:
        return datetime.datetime.strptime(str(s)[:19], "%Y-%m-%dT%H:%M:%S")
    except Exception:                                              # noqa: BLE001
        return None


def gaps_seconds(times):
    """Seconds between consecutive events, in the order given. Negative steps are dropped rather
    than made absolute: a clock that went backwards is a broken record, not a short gap."""
    out = []
    for a, b in zip(times, times[1:]):
        d = (b - a).total_seconds()
        if d >= 0:
            out.append(d)
    return out


def split_long(gaps, max_gap_min):
    """(ordinary, interrupted). Separated, never silently merged or silently dropped."""
    cap = max_gap_min * 60.0
    return [g for g in gaps if g <= cap], [g for g in gaps if g > cap]


def pctile(vals, q):
    """Nearest-rank percentile: returns a real observation, never an interpolation. None when empty."""
    if not vals:
        return None
    s = sorted(vals)
    k = max(0, min(len(s) - 1, int(round(q * (len(s) - 1)))))
    return s[k]


def judge_interval(interval_sec, ordinary, min_gaps=MIN_GAPS):
    """Is `--status-every` sized so that a NO-PROGRESS report means something?

    The heartbeat calls a stall when nothing moves for one whole interval, so the interval has to sit
    ABOVE the ordinary quiet gap or the message fires on slow work. Verdicts: too-few-gaps, too-short,
    ok. Deliberately does not recommend a number - the interval is also a reporting cadence, and how
    often a human wants to hear from a run is not something a percentile knows.
    """
    n = len(ordinary)
    if n < min_gaps:
        return {"verdict": "too-few-gaps", "n": n,
                "line": "%d ordinary gap(s), under the %d needed to state a percentile" % (n, min_gaps)}
    p99, mx = pctile(ordinary, 0.99), max(ordinary)
    v = "too-short" if interval_sec <= p99 else "ok"
    return {"verdict": v, "n": n, "p99": p99, "max": mx,
            "line": ("--status-every %ds against a p99 ordinary quiet gap of %.0fs and a worst of "
                     "%.0fs, over %d gap(s) -> %s" % (interval_sec, p99, mx, n, v))}


def selftest():
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    print("measure_heartbeat_gap self-test")
    print("")
    t0 = datetime.datetime(2026, 9, 4, 12, 0, 0)
    mk = lambda *mins: [t0 + datetime.timedelta(minutes=m) for m in mins]

    # MUST FIRE - the founding shapes.
    T("MUST FIRE  consecutive events become the seconds between them",
      gaps_seconds(mk(0, 1, 3)) == [60.0, 120.0], str(gaps_seconds(mk(0, 1, 3))))
    T("MUST FIRE  THE OVERNIGHT TRAP - a gap past the cap is separated, not averaged into the rest",
      split_long([60.0, 120.0, 30000.0], 60) == ([60.0, 120.0], [30000.0]),
      str(split_long([60.0, 120.0, 30000.0], 60)))
    T("MUST FIRE  an interval at or under the p99 ordinary gap is too short to mean anything",
      judge_interval(600, [600.0] * 30)["verdict"] == "too-short", judge_interval(600, [600.0] * 30)["line"])

    # MUST NOT FIRE - the legal inputs.
    T("MUST NOT FIRE  an interval comfortably above the ordinary gap is ok",
      judge_interval(600, [30.0] * 30)["verdict"] == "ok", judge_interval(600, [30.0] * 30)["line"])
    T("MUST NOT FIRE  THE MEASUREMENT RULE - nineteen gaps produce a refusal, not a p99",
      judge_interval(600, [30.0] * 19)["verdict"] == "too-few-gaps", judge_interval(600, [30.0] * 19)["line"])
    T("MUST NOT FIRE  a clock that went BACKWARDS is dropped, not turned into a short gap",
      gaps_seconds(mk(0, 5, 1)) == [300.0], str(gaps_seconds(mk(0, 5, 1))))
    T("MUST NOT FIRE  an unparseable timestamp yields None rather than throwing",
      parse_at("not a time") is None, str(parse_at("not a time")))

    # CLEAN TWIN - adjacent behaviour that still works.
    T("CLEAN TWIN a real lane-log timestamp parses",
      parse_at("2026-09-04T15:57:14") == datetime.datetime(2026, 9, 4, 15, 57, 14), str(parse_at("2026-09-04T15:57:14")))
    T("CLEAN TWIN one event alone yields no gap rather than a zero",
      gaps_seconds(mk(0)) == [], str(gaps_seconds(mk(0))))
    T("CLEAN TWIN the percentile is nearest-rank, so it returns a gap that actually happened",
      pctile([1.0, 2.0, 3.0, 100.0], 0.99) == 100.0, str(pctile([1.0, 2.0, 3.0, 100.0], 0.99)))
    T("CLEAN TWIN nothing to take a percentile of yields None, not zero",
      pctile([], 0.5) is None, str(pctile([], 0.5)))

    if bad:
        print("")
        print("SELF-TEST FAIL: %d check(s)" % len(bad))
        print("HEARTBEAT-GAP-SELFTEST-COMPLETE")
        return 1
    print("")
    print("SELF-TEST PASS: 3 must-fire cases led by the overnight trap, 4 must-not-fire cases "
          "including the backwards clock, and 4 clean twins")
    print("HEARTBEAT-GAP-SELFTEST-COMPLETE")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="how long the daemon legitimately goes quiet")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--interval", type=int, default=600, help="the --status-every being judged")
    ap.add_argument("--max-gap-min", dest="max_gap_min", type=int, default=DEFAULT_MAX_GAP_MIN)
    a = ap.parse_args()
    if a.selftest:
        return selftest()

    if not os.path.isdir(RUNS):
        print("HEARTBEAT GAP BLIND: %s is not on disk, so nothing was measured." % RUNS)
        print("HEARTBEAT-GAP-COMPLETE blind=no-runs")
        return 0

    pooled, interrupted, per_run = [], [], []
    for name in sorted(os.listdir(RUNS)):
        p = os.path.join(RUNS, name, "lane-log.jsonl")
        if not os.path.exists(p):
            continue
        times = []
        with io.open(p, encoding="utf-8-sig") as f:
            for ln in f:
                ln = ln.strip()
                if not ln:
                    continue
                try:
                    t = parse_at(json.loads(ln).get("at"))
                except Exception:                                  # noqa: BLE001
                    t = None
                if t:
                    times.append(t)
        if len(times) < 2:
            per_run.append((name, len(times), 0, 0, None, None))
            continue
        ordinary, long_ = split_long(gaps_seconds(times), a.max_gap_min)
        pooled += ordinary
        interrupted += long_
        per_run.append((name, len(times), len(ordinary), len(long_),
                        pctile(ordinary, 0.99), max(ordinary) if ordinary else None))

    print("heartbeat gaps, from lane-log.jsonl across %d run(s)" % len(per_run))
    print("")
    print("  %-34s %7s %7s %7s %9s %9s" % ("run", "events", "gaps", "over-cap", "p99 s", "max s"))
    for name, ev, ng, nl, p99, mx in per_run:
        print("  %-34s %7d %7d %7d %9s %9s"
              % (name[:34], ev, ng, nl,
                 ("%.0f" % p99) if p99 is not None else "-", ("%.0f" % mx) if mx is not None else "-"))

    print("")
    v = judge_interval(a.interval, pooled)
    print("  pooled: " + v["line"])
    if pooled:
        print("  distribution over %d ordinary gap(s): p50 %.0fs  p90 %.0fs  p95 %.0fs  p99 %.0fs  max %.0fs"
              % (len(pooled), pctile(pooled, 0.5), pctile(pooled, 0.9), pctile(pooled, 0.95),
                 pctile(pooled, 0.99), max(pooled)))
    print("  %d gap(s) over the %d-minute cap were EXCLUDED as interrupted runs rather than slow lanes%s"
          % (len(interrupted), a.max_gap_min,
             (" (longest %.1f h)" % (max(interrupted) / 3600.0)) if interrupted else ""))
    print("")
    print("NOTHING WAS CHANGED. The interval is also a reporting cadence - how often a human wants to "
          "hear from a run is not something a percentile knows - so this says whether the current "
          "number can mean what the heartbeat claims it means, and stops there.")
    print("HEARTBEAT-GAP-COMPLETE runs=%d gaps=%d excluded=%d" % (len(per_run), len(pooled), len(interrupted)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
