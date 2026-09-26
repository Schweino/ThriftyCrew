#!/usr/bin/env python3
"""measure-bot-checkout.py - the harness behind design/PLAN-bot-dedicated-checkout-2026-09-25.md Part 1 (W0.1).

WHAT IT ANSWERS. How often a scheduled capture run lands its own data from its own run, what stopped the ones that
did not, how many session landings fall in 06:30 to 09:00, and how many session landings made during a live bot run
touched a bot-owned path or the run's own commit. The plan's section 10 bars (B1 to B7) are read with it, 14 days
after each stage lands (W3.1).

A REPORT, NEVER A GATE. Nothing schedules it and nothing reads its exit code. It is committed rather than described
because the question recurs (.claude/rules/measurement.md, "NAMING A SCRATCH HARNESS IS NOT NAMING A HARNESS"): it is
the scratch measure.py (blob 533667d592b0) and derive.py (blob 8a232cb13938) of 2026-09-25 folded into one file, with
three changes. The owned-path set is exported from lib/bot-paths.ps1 at run time instead of a hand-kept owned.txt;
the committed-rows trim (scratch commit_rows.py, blob 66e3012497a1) is part of `measure`; and the chain-manifest check
reads the manifest AT EACH LANDING'S OWN COMMIT (`manifest`), where the scratch botmanifest.py read it at one HEAD.

USAGE (the interpreter is C:\\Codex\\Python312\\python.exe; bare `python` is not one on this box)
    measure  --out ROWS.jsonl [--main DIR] [--ledger DIR] [--since YYYY-MM-DD]
             READ-ONLY over the production checkout's grocery/out/logs, the shared reflogs, the checkout-sync log and
             the push ledger. Writes one row per bot run, per origin landing, per push-main row and per sync row.
    derive   ROWS.jsonl [--until YYYY-MM-DD]
             Every total, each with its denominator, derived ONLY from the rows (plus the cited per-run cause table).
             `--until 2026-09-24` over design/MEASURE-bot-checkout-2026-09-25.jsonl re-derives section 2's totals.
    manifest ROWS.jsonl
             Of the landings that carried a bot commit, how many changed a file in the chain manifest as
             ops/rehearse-chain.ps1 -ListSet prints it AT THAT LANDING'S OWN COMMIT.
    --selftest
             Hermetic: three frozen log excerpts (a clean run, an untracked-blocker run, a new-sync blocked run) and
             synthetic rows. Reads no checkout, no reflog, no ledger. Its last line is its verdict.

SCOPE OF A CLEAN REPORT. Unsound: it parses the log lines it knows, so a run whose tail printed a new shape is
counted by what it did print, and an old-tail push refused by the hook is not attributed (the old tail did not log
git's output). The cause of each failed landing is a HAND reading of that run's own log (CAUSE below, each entry
naming its evidence); a run not in the table is printed UNATTRIBUTED, never guessed.
"""
# The self-test is pure over in-file fixtures (temp files it creates itself); it reads no repo file but this one.
# gate-inputs: ops\measure-bot-checkout.py
import collections
import datetime as dt
import fnmatch
import io
import json
import os
import re
import statistics
import subprocess
import sys

CDT = dt.timezone(dt.timedelta(hours=-5))
DEFAULT_SINCE = "2026-09-16"
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# The cause of every capture-run that did not push on its first round, read by hand from that run's own log.
# Keyed (lane, start to the minute). Add a row only with its evidence; never infer one.
CAUSE = {
    ("ad", "2026-09-19T07:00"): ("shared-checkout: untracked blocker", "a session's untracked meal-prep/db/dedup-paired/report.json in the main checkout; git refused 4 rebases (fe2ad786e's message); hand repair"),
    ("daily", "2026-09-19T08:00"): ("shared-checkout: untracked blocker", "same file as the 07:00 run; hand repair and a plain push at 09:22"),
    ("ad", "2026-09-20T07:00"): ("code defect", "commit/push threw: Invoke-Native -C/-c binding (cc053f374)"),
    ("daily", "2026-09-20T08:00"): ("code defect", "commit/push threw, same binding defect"),
    ("daily", "2026-09-20T12:00"): ("code defect", "commit/push threw, same binding defect"),
    ("ad", "2026-09-21T07:00"): ("shared-checkout: gate red over the shared tree", "4 pushes refused by run-gates in the main checkout (3 to 5 gates red; %TEMP%\\tc-prepush-181009.log .. -181993.log); not attributed file by file"),
    ("daily", "2026-09-22T08:00"): ("commit refused (bot's own write)", "pre-commit bulk-edit verifier: BOM CHANGED meal-prep/db/cost-flags.txt"),
    ("ad", "2026-09-23T07:00"): ("commit refused (carried backlog)", "size gate: 40 new files, 28.8 MB, two days of captures after 09-22's refusal"),
    ("daily", "2026-09-23T08:00"): ("commit refused (carried backlog)", "size gate, 51 files 43.3 MB, and guards held"),
    ("daily", "2026-09-23T09:32"): ("main moved during the push", "hand run -Force -ForceBigCommit; rebase 1 then push rejected, rebase 2 then pushed"),
    ("ad", "2026-09-24T07:00"): ("shared-checkout: untracked blocker + autostash conflict on a session's dirty file", "round 1 untracked design/backlog-inbox/pd-land-W0.1R-2026-09-23.md; round 2 autostash conflict on ops/test-prepush-hook.ps1 left UU in the shared index; rounds 3-4 cannot autostash"),
    ("daily", "2026-09-24T08:00"): ("shared-checkout: unmerged path left by the 07:00 autostash", "start sync blocked/conflict on ops/test-prepush-hook.ps1; STOPPED before any capture"),
    ("daily", "2026-09-24T09:00"): ("shared-checkout: foreign untracked file", "tail sync blocked/foreign on lib/chain-queue.ps1 (??), a session's untracked copy of a file upstream added"),
    ("daily", "2026-09-24T16:38"): ("shared-checkout: foreign staged file", "start sync partial (17 short), tail sync blocked/foreign on meal-prep/pipeline/audit-lane-shape.ps1 (M ), a session's staged edit"),
    ("ad", "2026-09-25T07:00"): ("shared-branch: patch-identical duplicates on local main", "start and tail sync degraded/replay on 447b42efe (= 7e70f5fae by patch-id), landed by a session push-main -ViaWorktree from the main checkout 09-24 17:35, main_sync=manual"),
    ("daily", "2026-09-25T08:00"): ("shared-branch: patch-identical duplicates on local main", "same as the 07:00 run"),
}

BOT_SUBJECT = re.compile(r"^(Daily pipeline|Graph nightly|Harvest crawl|Pricing chain|Ratchet|Daily ratchets)")
RUNHDR = re.compile(r"^--- run-log: capture-run-(ad|daily) \| (\S+) \| pid (\d+) ---")
RUNEND = re.compile(r"^--- run-log: finished (\S+) rc=(-?\d+) ---")


def git(*args, cwd=None):
    r = subprocess.run(["git"] + list(args), capture_output=True, text=True, encoding="utf-8", errors="replace",
                       cwd=cwd or REPO)
    return r.returncode, r.stdout


def owned_match(path, owned):
    """lib/bot-paths.ps1 Test-BotPathOwned's rule: a directory entry owns its subtree, the boundary is the slash."""
    p = path.replace("\\", "/")
    for o in owned:
        n = o.replace("\\", "/").rstrip("/")
        if "*" in n or "?" in n:
            if fnmatch.fnmatchcase(p, n):
                return True
        elif p == n or p.startswith(n + "/"):
            return True
    return False


def export_owned():
    """The owned set, read from the declaration itself. An empty or failed export is fatal, never an empty set."""
    cmd = (". '" + os.path.join(REPO, "lib", "bot-paths.ps1") + "'; "
           "$a = @((Get-BotInputPaths) + (Get-BotServedPaths) + (Get-BotGlobPaths) + (Get-BotLanePaths)); "
           "$a | ForEach-Object { $_ }")
    r = subprocess.run(["powershell", "-NoProfile", "-Command", cmd], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    owned = sorted(set(x.strip() for x in r.stdout.splitlines() if x.strip()))
    if r.returncode != 0 or not owned:
        raise SystemExit("measure: could not export the owned set from lib/bot-paths.ps1 (rc=%d)" % r.returncode)
    return owned


def new_rebase_round():
    return {"autostash": False, "up_to_date": False, "rebased": False, "autostash_conflict": False,
            "untracked_blocker": [], "unmerged": [], "cannot_autostash": False, "error": []}


def parse_capture_log(text, fn):
    """One row per `--- run-log:` block of a capture-run-{ad,daily}-<date>.log."""
    out, cur = [], None
    for ln in text.splitlines():
        h = RUNHDR.match(ln)
        if h:
            cur = {"kind": "run", "bot": "capture-run", "lane": h.group(1), "log": fn, "start": h.group(2),
                   "pid": int(h.group(3)), "end": None, "rc": None, "commit": None, "commit_refused": False,
                   "stopped_before_capture": False, "start_sync": None, "tail_syncs": [], "rebase_rounds": {},
                   "pushed_attempt": None, "push_failed": False, "failed_lanes": "", "elapsed_s": None,
                   "blockers": [], "tail_style": None, "handoff": False}
            continue
        if cur is None:
            continue
        e = RUNEND.match(ln)
        if e:
            cur["end"], cur["rc"] = e.group(1), int(e.group(2))
            out.append(cur)
            cur = None
            continue
        s = ln.strip()
        mm = re.match(r"^sync\[start\]: (\w+)(?:/(\S+))?.*?behind=(\d+) behind_after=(\d+) - (.*)$", s)
        if mm:
            cur["start_sync"] = {"outcome": mm.group(1), "class": mm.group(2) or "", "behind": int(mm.group(3)),
                                 "behind_after": int(mm.group(4)), "why": mm.group(5)[:300]}
        mm = re.match(r"^sync\[tail (\d+)\]: (\w+)(?:/(\S+))?.*?behind=(\d+) behind_after=(\d+) - (.*)$", s)
        if mm:
            cur["tail_style"] = "sync"
            cur["tail_syncs"].append({"n": int(mm.group(1)), "outcome": mm.group(2), "class": mm.group(3) or "",
                                      "behind": int(mm.group(4)), "why": mm.group(6)[:300]})
        mm = re.match(r"^commit: \[main ([0-9a-f]+)\] (.*)$", s)
        if mm:
            cur["commit"], cur["subject"] = mm.group(1), mm.group(2)
        if re.match(r"^(commit: REFUSED|WARNING: commit REFUSED)", s):
            cur["commit_refused"] = True
        if s.startswith("commit/push threw"):
            cur["commit_push_threw"] = s[:200]
        if "STOPPED before any capture" in s:
            cur["stopped_before_capture"] = True
        if "handing off to" in s:
            cur["handoff"] = True
        mm = re.match(r"^rebase\[(\d+)\]: (.*)$", s)
        if mm:
            cur["tail_style"] = "autostash"
            r = cur["rebase_rounds"].setdefault(mm.group(1), new_rebase_round())
            t = mm.group(2)
            if t.startswith("Created autostash"):
                r["autostash"] = True
            if "is up to date" in t:
                r["up_to_date"] = True
            if t.startswith("Successfully rebased"):
                r["rebased"] = True
            if "Applying autostash resulted in conflicts" in t:
                r["autostash_conflict"] = True
            if "Cannot autostash" in t:
                r["cannot_autostash"] = True
            um = re.match(r"^(\S+): unmerged", t)
            if um and um.group(1) not in r["unmerged"]:
                r["unmerged"].append(um.group(1))
            q = re.match(r"^moved untracked '([^']+)'", t)
            if q:
                r["untracked_blocker"].append(q.group(1))
            if t.startswith(("error:", "fatal:")):
                r["error"].append(t[:160])
        mm = re.match(r"^rebase attempt (\d+) conflicted", s)
        if mm:
            cur["rebase_rounds"].setdefault(mm.group(1), new_rebase_round())["conflicted"] = True
        mm = re.match(r"^pushed on attempt (\d+)", s)
        if mm:
            cur["pushed_attempt"] = int(mm.group(1))
        if s.startswith("PUSH FAILED"):
            cur["push_failed"] = True
        if re.match(r"^tail\[\d+\]: the sync ended", s):
            cur["push_failed"] = True
        mm = re.match(r"^FAILED LANES: (.*)$", s)
        if mm:
            cur["failed_lanes"] = mm.group(1)
        mm = re.match(r"^elapsed (\d+) s", s)
        if mm:
            cur["elapsed_s"] = int(mm.group(1))
        mm = re.match(r"^foreign-held: (\d+)", s)
        if mm:
            cur["foreign_held"] = int(mm.group(1))
    if cur is not None:
        cur["unterminated"] = True
        out.append(cur)
    return out


def parse_lane_log(text, fn, date):
    rows = []
    for ln in text.splitlines():
        s = ln.strip()
        mm = re.match(r"^(graph-nightly|harvest-crawl): (committed|commit refused|nothing)(.*)$", s)
        if not mm:
            continue
        tail = mm.group(3)
        fh = re.search(r"foreign-held: (\d+)", tail)
        rows.append({"kind": "run", "bot": mm.group(1), "lane": mm.group(1), "log": fn, "date": date,
                     "committed": mm.group(2) == "committed", "commit_refused": mm.group(2) == "commit refused",
                     "pushed": "and pushed" in tail, "push_failed": ("push failed" in tail) or ("push threw" in tail),
                     "foreign_held": int(fh.group(1)) if fh else 0})
    return rows


def reflog(path, since):
    out = []
    for line in io.open(path, encoding="utf-8", errors="replace"):
        head, _, msg = line.rstrip("\n").partition("\t")
        parts = head.split(" ")
        ts = int(parts[-2])
        at = dt.datetime.fromtimestamp(ts, CDT).isoformat()
        if at >= since:
            out.append({"old": parts[0], "new": parts[1], "ts": ts, "msg": msg, "at": at})
    return out


def ts_of(local_iso):
    return dt.datetime.fromisoformat(local_iso).replace(tzinfo=CDT).timestamp()


def cmd_measure(out_path, main, ledger, since):
    logs = os.path.join(main, "grocery", "out", "logs")
    rc, gd = git("rev-parse", "--git-common-dir", cwd=main)
    gitdir = os.path.abspath(os.path.join(main, gd.strip())) if rc == 0 else os.path.join(main, ".git")
    owned = export_owned()
    rows = []
    for fn in sorted(os.listdir(logs)):
        m = re.match(r"capture-run-(ad|daily)-(\d{4}-\d{2}-\d{2})\.log$", fn)
        if m and m.group(2) >= since:
            rows += parse_capture_log(io.open(os.path.join(logs, fn), encoding="utf-8", errors="replace").read(), fn)
    for fn in sorted(os.listdir(logs)):
        m = re.match(r"(graph-nightly|harvest-crawl)-(\d{4}-\d{2}-\d{2})\.log$", fn)
        if m and m.group(2) >= since:
            rows += parse_lane_log(io.open(os.path.join(logs, fn), encoding="utf-8", errors="replace").read(), fn, m.group(2))

    mainlog = reflog(os.path.join(gitdir, "logs", "refs", "heads", "main"), since)
    for r in rows:
        if r.get("bot") != "capture-run" or not r.get("commit"):
            continue
        c = next((x for x in mainlog if x["new"].startswith(r["commit"]) and x["msg"].startswith("commit")), None)
        r["commit_at"] = c["at"] if c else None
        if c and r.get("end"):
            endts = ts_of(r["end"])
            r["main_moves_after_commit"] = [{"at": x["at"], "msg": x["msg"][:90]} for x in mainlog
                                            if c["ts"] <= x["ts"] <= endts + 5 and x is not c]
            r["tail_wall_s"] = int(endts - c["ts"])

    olog = [x for x in reflog(os.path.join(gitdir, "logs", "refs", "remotes", "origin", "main"), since)
            if x["msg"].startswith("update by push")]
    for L in olog:
        _, out = git("log", "--format=%H%x09%an%x09%s", L["old"] + ".." + L["new"])
        commits = [x.split("\t") for x in out.splitlines() if x]
        _, names = git("diff", "--name-only", L["old"], L["new"])
        paths = [p for p in names.splitlines() if p]
        bot_c = [c for c in commits if len(c) > 2 and (c[1] == "smp-pipeline-bot" or BOT_SUBJECT.match(c[2]))]
        own = [p for p in paths if owned_match(p, owned)]
        rows.append({"kind": "landing", "at": L["at"], "ts": L["ts"], "old": L["old"][:12], "new": L["new"][:12],
                     "n_commits": len(commits), "n_bot_commits": len(bot_c),
                     "bot_subjects": [c[2][:80] for c in bot_c], "session_only": len(bot_c) == 0,
                     "n_paths": len(paths), "owned_paths": own[:40], "n_owned_paths": len(own), "paths": paths[:400]})

    landings = [x for x in rows if x["kind"] == "landing"]
    for r in rows:
        if r.get("bot") != "capture-run" or not r.get("subject"):
            continue
        hit = next((L for L in landings if r["subject"][:80] in L["bot_subjects"]
                    and (not r.get("commit_at") or L["at"] >= r["commit_at"][:19])), None)
        r["landed_at"] = hit["at"] if hit else None
        if hit and r.get("end"):
            r["landed_minus_end_s"] = int(hit["ts"] - ts_of(r["end"]))

    if os.path.isdir(ledger):
        for fn in sorted(os.listdir(ledger)):
            m = re.match(r"pushes-(\d{4}-\d{2}-\d{2})\.jsonl$", fn)
            if not m or m.group(1) < since:
                continue
            for ln in io.open(os.path.join(ledger, fn), encoding="utf-8", errors="replace"):
                try:
                    j = json.loads(ln)
                except ValueError:
                    continue
                if j.get("event") != "push-main":
                    continue
                run = j.get("run") or ""
                rows.append({"kind": "pushmain", "end_utc": j.get("ts"),
                             "start_utc": run.split("@", 1)[1] if "@" in run else None, "outcome": j.get("outcome"),
                             "checkout": j.get("checkout"), "via_worktree": j.get("via_worktree"),
                             "main_sync": j.get("main_sync"), "chain": j.get("chain_touching"),
                             "lock_wait_ms": j.get("lock_wait_ms_total"), "rounds": j.get("rounds")})

    p = os.path.join(gitdir, "tc-checkout-sync-log.jsonl")
    if os.path.exists(p):
        for ln in io.open(p, encoding="utf-8"):
            j = json.loads(ln)
            rows.append({"kind": "sync", "ts": j["ts"], "pid": j["pid"], "lane": j["kind"], "phase": j["phase"],
                         "outcome": j["outcome"], "class": j["class"], "behind": j["behind"],
                         "behind_after": j["behind_after"], "ahead": j["ahead"], "foreign": j["foreign"],
                         "sec": j["sec"], "why": j["why"][:300]})

    trim_committed_form(rows)
    with io.open(out_path, "w", encoding="utf-8", newline="\n") as f:
        for r in rows:
            f.write(json.dumps(r, sort_keys=True) + "\n")
    print("measure: owned set %d entries from lib/bot-paths.ps1; since %s" % (len(owned), since))
    print("MEASURE-BOT-CHECKOUT-COMPLETE rows=%d runs=%d landings=%d pushmain=%d sync=%d" % (
        len(rows), sum(r["kind"] == "run" for r in rows), sum(r["kind"] == "landing" for r in rows),
        sum(r["kind"] == "pushmain" for r in rows), sum(r["kind"] == "sync" for r in rows)))


def trim_committed_form(rows):
    """Every row kept; a landing keeps its full path list only when it fell inside a live capture run."""
    wins = [(ts_of(r["start"]), ts_of(r["end"])) for r in rows
            if r["kind"] == "run" and r.get("bot") == "capture-run" and r.get("end")]
    for r in rows:
        if r["kind"] == "landing":
            r["in_live_run"] = bool(r["session_only"] and any(a <= r["ts"] <= b for a, b in wins))
            if not r["in_live_run"]:
                r.pop("paths", None)


def run_date(r):
    return (r.get("start") or r.get("date") or "")[:10]


def bot_commit_paths(sha):
    _, out = git("diff-tree", "--no-commit-id", "--name-only", "-r", sha)
    return set(x for x in out.splitlines() if x)


def derive(rows, until=None, botpaths_of=bot_commit_paths, say=print):
    """Every total, from the rows alone. Returns the totals so the self-test can assert on them."""
    if until:
        rows = [r for r in rows if not (
            (r["kind"] == "run" and r.get("bot") == "capture-run" and run_date(r) > until) or
            (r["kind"] == "landing" and r["at"][:10] > until))]
    t = {}
    runs = [r for r in rows if r["kind"] == "run" and r["bot"] == "capture-run"]
    lands = [r for r in rows if r["kind"] == "landing"]
    pms = [r for r in rows if r["kind"] == "pushmain"]
    key = lambda r: (r["lane"], r["start"][:16])
    say("== Q1 capture-run runs%s (one row each)" % (" through " + until if until else ""))
    armed = [r for r in runs if r.get("commit") or r["commit_refused"] or r["stopped_before_capture"] or r.get("commit_push_threw")]
    committed = [r for r in armed if r.get("commit")]
    first = [r for r in committed if r["pushed_attempt"] == 1]
    held = [r for r in armed if r["pushed_attempt"] is None]
    t.update(runs=len(runs), armed=len(armed), committed=len(committed), first_round=len(first), held=len(held))
    say("runs parsed: %d; armed (a commit, a refusal, a throw or a start-sync stop): %d" % (len(runs), len(armed)))
    say("committed runs pushed on round 1: %d of %d; not on round 1: %d of %d" % (
        len(first), len(committed), len(committed) - len(first), len(committed)))
    for r in committed:
        if r["pushed_attempt"] == 1:
            continue
        rounds = len(r["rebase_rounds"]) or len(r["tail_syncs"]) or 0
        say("  %s %s rounds=%d pushed@%s landed=%s lag_after_end=%ss | %s" % (
            r["lane"], r["start"], rounds, r["pushed_attempt"], r.get("landed_at"), r.get("landed_minus_end_s"),
            CAUSE.get(key(r), ("UNATTRIBUTED",))[0]))
    say("armed runs whose data did NOT land from their own run: %d of %d" % (len(held), len(armed)))
    causes = collections.Counter(CAUSE.get(key(r), ("UNATTRIBUTED",))[0] for r in held)
    for k, v in causes.most_common():
        say("  %2d  %s" % (v, k))
    t["held_shared_checkout"] = sum(v for k, v in causes.items() if k.startswith("shared-checkout"))
    t["held_unattributed"] = causes.get("UNATTRIBUTED", 0)
    t["main_moved"] = sum(1 for r in committed if CAUSE.get(key(r), ("",))[0] == "main moved during the push")
    say("  shared checkout %d of %d held; main moved during the push %d of %d committed" % (
        t["held_shared_checkout"], len(held), t["main_moved"], len(committed)))
    lag = sorted(r["landed_minus_end_s"] for r in held if r.get("landed_minus_end_s") is not None)
    t["lag_n"], t["lag_median"] = len(lag), (statistics.median(lag) if lag else None)
    say("held runs that committed and landed later: %d; lag after run end, s: %s (median %s)" % (len(lag), lag, t["lag_median"]))
    new = [r for r in armed if r["tail_style"] == "sync" or r["start_sync"]]
    old = [r for r in armed if r not in new]
    t["old_armed"], t["old_landed"] = len(old), sum(r["pushed_attempt"] is not None for r in old)
    t["new_armed"], t["new_landed"] = len(new), sum(r["pushed_attempt"] is not None for r in new)
    say("OLD autostash tail: %d armed, landed from their own run %d of %d" % (len(old), t["old_landed"], len(old)))
    say("NEW two-way sync:   %d armed, landed from their own run %d of %d" % (len(new), t["new_landed"], len(new)))

    say("\n== sync log rows")
    for s in [r for r in rows if r["kind"] == "sync"]:
        say("  %s %s/%s %s/%s behind %d->%d sec=%s foreign=%s" % (s["ts"][:16], s["lane"], s["phase"], s["outcome"],
                                                              s["class"], s["behind"], s["behind_after"], s["sec"], s["foreign"]))

    say("\n== graph nightly and harvest (every row; the lane logs are not cut by --until)")
    for b in ("graph-nightly", "harvest-crawl"):
        rs = [r for r in rows if r["kind"] == "run" and r["bot"] == b]
        c = [r for r in rs if r["committed"]]
        t[b] = (len(c), sum(r["pushed"] for r in c))
        say("  %s: committed %d; pushed %d of %d committed; commit refused %d" % (
            b, len(c), t[b][1], len(c), sum(r["commit_refused"] for r in rs)))

    lt = lambda l: dt.datetime.fromtimestamp(l["ts"], CDT)
    sess = [l for l in lands if l["session_only"]]
    say("\n== Q3 origin landings: %d total, %d session-only" % (len(lands), len(sess)))
    byday = collections.defaultdict(lambda: [0, 0])
    for l in sess:
        x = lt(l)
        m = x.hour * 60 + x.minute
        byday[x.date().isoformat()][0] += 1
        if 390 <= m < 540:
            byday[x.date().isoformat()][1] += 1
    for d in sorted(byday):
        say("  %s session landings %3d, in 06:30-09:00 %2d" % (d, byday[d][0], byday[d][1]))
    full = [d for d in sorted(byday) if not until or d <= until]
    if full and not until:
        full = full[:-1]   # the last day in the rows is partial unless --until names a full one
    w, tot = sum(byday[d][1] for d in full), sum(byday[d][0] for d in full)
    t.update(window_days=len(full), window_landings=w, window_total=tot)
    say("  over %d full days: %d of %d session landings in 06:30-09:00 (%.1f%%), mean %.1f a day; the window is 10.4%% of the day" % (
        len(full), w, tot, 100.0 * w / max(1, tot), w / max(1, len(full))))
    pm_in = []
    for p in pms:
        if not p.get("start_utc"):
            continue
        try:
            x = dt.datetime.fromisoformat(p["start_utc"].replace("Z", "")[:26] + "+00:00").astimezone(CDT)
        except ValueError:
            continue
        if 390 <= x.hour * 60 + x.minute < 540:
            pm_in.append(p)
    t["pm_window"], t["pm_total"] = len(pm_in), len(pms)
    say("  push-main runs started in 06:30-09:00: %d of %d rows; outcomes %s" % (
        len(pm_in), len(pms), dict(collections.Counter(p["outcome"] for p in pm_in))))

    say("\n== Q4 session landings during a live capture-run run")
    tot_in = own_in = hit_in = 0
    ended = [r for r in armed if r.get("end")]
    for r in ended:
        st, en = ts_of(r["start"]), ts_of(r["end"])
        bp = botpaths_of(r["commit"]) if r.get("commit") else set()
        ins = [l for l in sess if st <= l["ts"] <= en]
        o = [l for l in ins if l["n_owned_paths"] > 0]
        h = [l for l in ins if bp & set(l.get("paths") or [])]
        tot_in, own_in, hit_in = tot_in + len(ins), own_in + len(o), hit_in + len(h)
        if ins:
            say("  %s %s landings=%d touching-owned=%d touching-the-bot-commit=%d" % (r["lane"], r["start"], len(ins), len(o), len(h)))
    t.update(in_run=tot_in, in_run_owned=own_in, in_run_hit=hit_in)
    say("  over %d armed runs with an end: %d session landings inside a live run; %d touched a bot-owned path (%.1f%%); %d touched the run's own commit's paths (%.1f%%)" % (
        len(ended), tot_in, own_in, 100.0 * own_in / max(1, tot_in), hit_in, 100.0 * hit_in / max(1, tot_in)))
    allown = [l for l in sess if l["n_owned_paths"] > 0]
    t["sess_owned"], t["sess_total"] = len(allown), len(sess)
    say("  all session landings touching a bot-owned path: %d of %d (%.1f%%)" % (len(allown), len(sess), 100.0 * len(allown) / max(1, len(sess))))
    say("DERIVE-BOT-CHECKOUT-COMPLETE armed=%d committed=%d first_round=%d held=%d unattributed=%d" % (
        t["armed"], t["committed"], t["first_round"], t["held"], t["held_unattributed"]))
    return t


def list_manifest(sha):
    r = subprocess.run(["powershell", "-NoProfile", "-File", os.path.join(REPO, "ops", "rehearse-chain.ps1"),
                        "-ListSet", "-Commit", sha], capture_output=True, text=True, encoding="utf-8", errors="replace")
    lines = r.stdout.splitlines()
    done = [l for l in lines if l.startswith("CHAIN-REHEARSAL-LISTSET-COMPLETE")]
    if r.returncode != 0 or not done:
        return None
    return set(l.strip() for l in lines if l.strip() and not l.startswith(("CHAIN-REHEARSAL", "chain-rehearsal")))


def bot_shas(old, new):
    _, out = git("log", "--format=%H %an", old + ".." + new)
    return [x.split(" ")[0] for x in out.splitlines() if x.endswith("smp-pipeline-bot")]


def manifest_check(rows, lister=list_manifest, shas_of=bot_shas, paths_of=bot_commit_paths, say=print):
    bot = [r for r in rows if r["kind"] == "landing" and r["n_bot_commits"] > 0]
    hit = blind = ncommits = 0
    sizes = []
    for L in bot:
        man = lister(L["new"])
        if not man:
            # An EMPTY set is not a clean answer: at a commit older than the manifest it lists nothing, and
            # "0 files, so 0 touched" is the agreeing zero .claude/rules/measurement.md warns about.
            blind += 1
            say("  %s BLIND: -ListSet listed %s at %s" % (L["at"][:16], "nothing" if man is not None else "no answer", L["new"]))
            continue
        sizes.append(len(man))
        shas = shas_of(L["old"], L["new"])
        ncommits += len(shas)
        paths = set()
        for s in shas:
            paths |= paths_of(s)
        m = sorted(paths & man)
        if m:
            hit += 1
            say("  %s touches the manifest at its own commit: %s" % (L["at"][:16], m[:6]))
    say("BOT-CHECKOUT-MANIFEST-COMPLETE landings=%d bot_commits=%d touching_manifest=%d blind=%d manifest_files=%s..%s" % (
        len(bot), ncommits, hit, blind, min(sizes) if sizes else "-", max(sizes) if sizes else "-"))
    return {"landings": len(bot), "hit": hit, "blind": blind}


# ----------------------------------------------------------------------------------------------------- self-test
FIX_CLEAN = """--- run-log: capture-run-ad | 2026-09-17T06:00:02 | pid 26744 ---
foreign-held: 47 tracked owned file(s) another session dirtied before this run started, left uncommitted: grocery/alert-log.txt
commit: [main 988fcc06f] Daily pipeline: refresh prices + feed (2026-09-17) [ad]
commit:  17 files changed, 90262 insertions(+), 87 deletions(-)
rebase[1]: Created autostash: 05b7f332a
rebase[1]: Current branch main is up to date.
pushed on attempt 1
FAILED LANES: Fareway
elapsed 229 s
--- run-log: finished 2026-09-17T06:03:51 rc=1 ---
"""
FIX_UNTRACKED = """--- run-log: capture-run-ad | 2026-09-19T07:00:02 | pid 30288 ---
commit: [main b7b059f85] Daily pipeline: refresh prices + feed (2026-09-19) [ad]
rebase[1]: Created autostash: b7f41ebe6
rebase attempt 1 conflicted; aborting (never detached)
rebase[2]: Created autostash: a045deb2e
rebase attempt 2 conflicted; aborting (never detached)
rebase[3]: Created autostash: 9b9723b02
rebase attempt 3 conflicted; aborting (never detached)
rebase[4]: Created autostash: 36919f31e
rebase attempt 4 conflicted; aborting (never detached)
PUSH FAILED after 4 attempts - this run's data is committed locally but NOT on main, so the live site still serves the previous board
FAILED LANES: push
elapsed 138 s
--- run-log: finished 2026-09-19T07:02:20 rc=1 ---
"""
FIX_NEWSYNC = """--- run-log: capture-run-daily | 2026-09-24T09:00:03 | pid 37436 ---
sync[start]: current e98f662d5..e98f662d5 behind=0 behind_after=0 - HEAD already contains origin; nothing was written
commit: [main 3c45a9478] Daily pipeline: refresh prices + feed (2026-09-24) [daily]
sync[tail 1]: blocked/foreign 3c45a9478.. behind=11 behind_after=0 - uncommitted work the bot does not own sits on path(s) upstream changed: lib/chain-queue.ps1 (??); nothing was written
tail[1]: the sync ended blocked - NOT pushing; this run's commit stays local until a sync reaches origin/main
FAILED LANES: guards-blocked, sync
elapsed 3861 s
--- run-log: finished 2026-09-24T10:04:24 rc=1 ---
"""


def selftest():
    cases = []

    def T(label, cond, got=""):
        cases.append((label, bool(cond)))
        print(("  PASS  " if cond else "  FAIL  ") + label + ("" if cond else "  got: " + str(got)))

    c = parse_capture_log(FIX_CLEAN, "capture-run-ad-2026-09-17.log")
    T("CLEAN TWIN: a clean run parses to one row that committed and pushed on round 1",
      len(c) == 1 and c[0]["commit"] == "988fcc06f" and c[0]["pushed_attempt"] == 1 and c[0]["tail_style"] == "autostash", c)
    T("CLEAN TWIN: the clean run's rebase round reads up to date, rc and end are read",
      c and c[0]["rebase_rounds"]["1"]["up_to_date"] and c[0]["rc"] == 1 and c[0]["end"] == "2026-09-17T06:03:51", c)
    u = parse_capture_log(FIX_UNTRACKED, "capture-run-ad-2026-09-19.log")
    T("MUST FIRE: an untracked-blocker run reads 4 conflicted rounds, PUSH FAILED, no pushed attempt",
      len(u) == 1 and len(u[0]["rebase_rounds"]) == 4 and all(v.get("conflicted") for v in u[0]["rebase_rounds"].values())
      and u[0]["push_failed"] and u[0]["pushed_attempt"] is None, u)
    n = parse_capture_log(FIX_NEWSYNC, "capture-run-daily-2026-09-24.log")
    T("MUST FIRE: a new-sync run blocked on a foreign file reads tail blocked/foreign and push_failed",
      len(n) == 1 and n[0]["tail_style"] == "sync" and n[0]["tail_syncs"] and n[0]["tail_syncs"][0]["outcome"] == "blocked"
      and n[0]["tail_syncs"][0]["class"] == "foreign" and n[0]["push_failed"] and n[0]["pushed_attempt"] is None, n)
    T("CLEAN TWIN: the new-sync run's start sync is read as current, behind 0",
      n and n[0]["start_sync"] and n[0]["start_sync"]["outcome"] == "current" and n[0]["start_sync"]["behind"] == 0, n)
    two = parse_capture_log(FIX_CLEAN + FIX_UNTRACKED, "x.log")
    T("CLEAN TWIN: two run-log blocks in one file are two rows, never merged", len(two) == 2, len(two))
    cut = parse_capture_log(FIX_CLEAN.rsplit("--- run-log: finished", 1)[0], "x.log")
    T("MUST FIRE: a run with no finished marker is kept and marked unterminated, never dropped",
      len(cut) == 1 and cut[0].get("unterminated") is True, cut)

    # derive over the three parsed runs plus synthetic landings. Keys of CAUSE are the real runs' own.
    rows = c + u + n
    for r in rows:
        r["landed_at"] = None
    u[0]["landed_minus_end_s"] = 8381
    base = ts_of("2026-09-24T09:30:00")
    rows += [
        {"kind": "landing", "at": "2026-09-24T09:30:00-05:00", "ts": base, "old": "a", "new": "b", "n_bot_commits": 0,
         "session_only": True, "n_owned_paths": 1, "owned_paths": ["public/smp-feed.json"], "paths": ["public/smp-feed.json"]},
        {"kind": "landing", "at": "2026-09-24T09:40:00-05:00", "ts": base + 600, "old": "b", "new": "c", "n_bot_commits": 0,
         "session_only": True, "n_owned_paths": 0, "owned_paths": [], "paths": ["lib/x.ps1"]},
        {"kind": "landing", "at": "2026-09-24T12:00:00-05:00", "ts": ts_of("2026-09-24T12:00:00"), "old": "c", "new": "d",
         "n_bot_commits": 0, "session_only": True, "n_owned_paths": 0, "owned_paths": []},
        {"kind": "landing", "at": "2026-09-25T07:10:00-05:00", "ts": ts_of("2026-09-25T07:10:00"), "old": "d", "new": "e",
         "n_bot_commits": 0, "session_only": True, "n_owned_paths": 0, "owned_paths": []},
    ]
    quiet = lambda *a: None
    bp = lambda sha: {"public/smp-feed.json"} if sha == "3c45a9478" else set()
    t = derive(rows, botpaths_of=bp, say=quiet)
    T("CLEAN TWIN: derive counts 3 armed, 3 committed, 1 on round 1, 2 held", (t["armed"], t["committed"], t["first_round"], t["held"]) == (3, 3, 1, 2), t)
    T("MUST FIRE: both held runs are attributed to the shared checkout from the cause table, none UNATTRIBUTED",
      t["held_shared_checkout"] == 2 and t["held_unattributed"] == 0, t)
    T("CLEAN TWIN: a landing inside the live 09-24 09:00 run that shares the bot commit's path is a real overlap",
      (t["in_run"], t["in_run_owned"], t["in_run_hit"]) == (2, 1, 1), t)
    T("CLEAN TWIN: the old/new tail split reads 2 old and 1 new", (t["old_armed"], t["new_armed"]) == (2, 1), t)
    t2 = derive(rows, until="2026-09-24", botpaths_of=bp, say=quiet)
    T("MUST NOT FIRE: --until 2026-09-24 leaves out the 09-25 landing and keeps every run through 09-24",
      t2["sess_total"] == 3 and t2["armed"] == 3 and t2["window_days"] == 1, t2)
    T("CLEAN TWIN: without --until the last day in the rows is not counted as a full day",
      t["window_days"] == 1 and t["sess_total"] == 4, t)
    unk = [dict(r) for r in rows]
    for r in unk:
        if r.get("start", "").startswith("2026-09-19"):
            r["start"] = "2026-09-19T07:31:00"
    t3 = derive(unk, botpaths_of=bp, say=quiet)
    T("MUST FIRE: a held run with no cause entry is counted UNATTRIBUTED, never guessed", t3["held_unattributed"] == 1, t3)

    # the owned-path rule mirrors Test-BotPathOwned: the boundary is the slash
    own = ["grocery/out", "grocery/alert-sent-*.txt", "public"]
    T("MUST FIRE: a file under an owned directory is owned", owned_match("grocery/out/regular/x.json", own))
    T("MUST NOT FIRE: a sibling whose name only starts with an owned directory is not owned",
      not owned_match("grocery/outbound.md", own))
    T("CLEAN TWIN: a rotating file is owned by its glob, and a backslash path is the same path",
      owned_match("grocery/alert-sent-2026-09-25.txt", own) and owned_match("grocery\\out\\x.json", own))

    # the manifest check reads the set AT EACH LANDING'S OWN COMMIT
    mrows = [{"kind": "landing", "at": "2026-09-20T07:00:00", "old": "o1", "new": "n1", "n_bot_commits": 1},
             {"kind": "landing", "at": "2026-09-21T07:00:00", "old": "o2", "new": "n2", "n_bot_commits": 1},
             {"kind": "landing", "at": "2026-09-22T07:00:00", "old": "o3", "new": "n3", "n_bot_commits": 0}]
    asked = []
    sets = {"n1": {"grocery/x.ps1"}, "n2": {"grocery/y.ps1"}}
    lister = lambda sha: (asked.append(sha), sets.get(sha))[1]
    m = manifest_check(mrows, lister=lister, shas_of=lambda o, n: ["s-" + n],
                       paths_of=lambda s: {"grocery/x.ps1"}, say=quiet)
    T("MUST FIRE: a bot path in the manifest AT ITS OWN COMMIT counts, and one only in another commit's set does not",
      m == {"landings": 2, "hit": 1, "blind": 0} and asked == ["n1", "n2"], (m, asked))
    m2 = manifest_check(mrows, lister=lambda sha: None, shas_of=lambda o, n: [], paths_of=lambda s: set(), say=quiet)
    T("MUST FIRE: a manifest that cannot be listed is BLIND, never a clean zero", m2["blind"] == 2 and m2["hit"] == 0, m2)
    m3 = manifest_check(mrows, lister=lambda sha: set(), shas_of=lambda o, n: ["s"], paths_of=lambda s: {"a.ps1"}, say=quiet)
    T("MUST FIRE: an EMPTY manifest (a commit older than the manifest) is BLIND, not 0 touched", m3["blind"] == 2 and m3["hit"] == 0, m3)

    want = 20
    failed = [l for l, ok in cases if not ok]
    if len(cases) != want:
        print("MEASURE-BOT-CHECKOUT SELF-TEST FAIL: ran %d cases, the literal list holds %d" % (len(cases), want))
        return 1
    if failed:
        print("MEASURE-BOT-CHECKOUT SELF-TEST FAIL (%d of %d cases failed)" % (len(failed), len(cases)))
        return 1
    print("MEASURE-BOT-CHECKOUT SELF-TEST PASS (%d of %d cases)" % (len(cases), len(cases)))
    return 0


def read_rows(p):
    return [json.loads(l) for l in io.open(p, encoding="utf-8") if l.strip()]


def main(argv):
    if "--selftest" in argv:
        return selftest()
    if len(argv) < 2 or argv[0] not in ("measure", "derive", "manifest"):
        print(__doc__)
        return 2

    def opt(name, default=None):
        return argv[argv.index(name) + 1] if name in argv else default

    if argv[0] == "measure":
        out = opt("--out")
        if not out:
            print("measure: --out ROWS.jsonl is required")
            return 2
        rc, gd = git("rev-parse", "--path-format=absolute", "--git-common-dir")
        main_dir = opt("--main", os.path.dirname(gd.strip().rstrip("/\\")) if rc == 0 else REPO)
        ledger = opt("--ledger", os.path.join(os.environ.get("LOCALAPPDATA", ""), "ThriftyCrew", "push-ledger"))
        cmd_measure(out, main_dir, ledger, opt("--since", DEFAULT_SINCE))
        return 0
    rows = read_rows(argv[1])
    if argv[0] == "derive":
        derive(rows, until=opt("--until"))
        return 0
    r = manifest_check(rows)
    return 3 if r["blind"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
