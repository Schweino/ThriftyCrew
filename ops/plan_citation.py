r"""plan_citation.py - a commit that changes a file an under-way plan names cites the plan.

    python ops/plan_citation.py --commit-msg <file>        # the commit-msg hook calls this
    python ops/plan_citation.py --replay <since> [<ref>]   # judge landed session commits, one row each
    python ops/plan_citation.py --selftest                 # frozen fixtures, hermetic

WHY THIS EXISTS (W7.2 of design/PLAN-push-derived-conflicts-2026-09-23.md, section 15.5). That plan reached
origin/main at 12:31:35Z on 2026-09-23 (f33d11829), ruled by Brad and under way, naming ops/push-main.ps1 among the
files its build would change. 54 minutes later a sibling session committed its own change to that file (5841e96b1)
without citing the plan: its Store: line read `searched "rebase verdict key", nothing applicable` and it had no Plan:
line. Two sessions then built one design twice, and the plan's own W0.1 branch conflicted with it in 6 hunks. The
search that finds the plan (`git grep -l -F 'ops/push-main.ps1' origin/main -- 'design/PLAN-*.md'`) returned exactly
that plan, and nothing in the process ran it. This runs it, at the one moment every change passes through.

WHAT IS JUDGED. A commit made by a Claude session (CLAUDE_CODE_SESSION_ID is set) that is not a merge. For every path
the commit stages (added, modified, deleted, and both names of a rename) it lists the design/PLAN-*.md files on
origin/main whose Status line says the plan is UNDER WAY and whose text names that path. For each such (path, plan)
pair the message carries a `Plan: <that plan>` line, or one `Plan-not-applicable: <reason>` line for the whole commit
(a reason of at least PNA_MIN_WORDS words), or this prints
    plan-citation: WARN - <path> is named by <plan> (build under way); read it, and add a Plan: line or
    Plan-not-applicable: <reason>
A human and the daily bot (no session id) and a merge are not judged, as with store_citation.py beside it. Staged
paths are read with the INHERITED git environment, because under a pathspec commit GIT_INDEX_FILE names the index
being committed and the shared .git/index holds other sessions' staging.

WHAT "UNDER WAY" MEANS, read from the plan's own Status line: the first line of the plan's header (before its first
`## ` heading) that begins with `Status`, or that carries `Status` after a sentence (`Date: ... Status: ...`). The
FIRST status word in that line decides:
  - ruled, under way                         -> under way: judged
  - done, superseded, closed, implemented, shipped, complete, completed, retired, abandoned, withdrawn, rejected
                                             -> finished: not judged
  - proposed, proposal, draft, awaiting, pending, measured, diagnosed, diagnosis, unratified
                                             -> not yet: not judged
  - no status word, a negated one ("not ruled", "not yet under way"), or no Status line at all -> not judged
The FIRST word, not any word, because a status grows as a build goes: "RULED 2026-09-10, W1 DONE" is still under way,
"DONE 2026-09-30 (ruled 2026-09-23)" is finished, and "PROPOSED; the earlier plan was ruled" is not yet. The under-way
words are the two the ruling names ("ruled or build under way", section 15.5 step 1). So a plan that wants its files
cited says one of them first in its Status line, and a finished plan says DONE or SUPERSEDED first.

WHAT "NAMES THE PATH" MEANS. The repo-relative path appears in the plan's text as a whole path, with either slash and
in any letter case: `ops/push-main.ps1`, `ops\push-main.ps1` and `ops/push-main.ps1:43` name it; a bare
`push-main.ps1`, `grocery/ops/push-main.ps1` and `ops/push-main.ps1.bak` do not. A plan never names itself: a commit
that edits a plan has read it.

WARN, THEN REFUSE (Brad's ruling D18, 2026-09-23, section 15.7 of that plan: "yes, 7 days after it lands, as the Store
line did"). Before REFUSE_FROM an uncited pair prints WARN and the commit goes through. From that date it prints
BLOCKED and the commit is refused, and Plan-not-applicable: <reason> is the loud, logged way out.

IT FAILS OPEN, AND NEVER SILENTLY. A deliberate refusal is exit REFUSE_EXIT (10), and ops/hooks/commit-msg refuses on
that code and on no other, so a traceback (exit 1), a file the interpreter cannot open (exit 2) or a killed interpreter
is a BLIND line and the commit goes through. Everything this cannot look at says so and never refuses: no origin/main
to read the plans from, staged files git cannot list, a git call that times out, any exception. Each prints
`plan-citation: BLIND - <why>` on stderr.

THE DECISION LOG. Every judged commit appends one row to %USERPROFILE%\.claude\plan-citation-log.jsonl: its verdict
(clear, cited, escape, warn, refuse or blind), its pairs, the plans under way and the committing checkout. It is best
effort and never fails a commit. It is what B18 (section 15.6) can read while the rule only warns, and what the week
before REFUSE_FROM is judged on. --replay derives the same verdicts from landed history through the same judge(),
taking a `Co-Authored-By: Claude` trailer as the mark of a session commit and the plans at each commit's first parent
as what origin/main held when it landed, so a baseline need not wait for the log.

EXIT CODES. --commit-msg: 0 (clear, cited, escape, warn, not judged, BLIND) or 10 (refused). --selftest: 0 pass, 1 a
case failed. --replay: 0 when it read the history, 3 when git could not (a could-not-look, never a clean answer).

SCOPE OF A CLEAN REPORT: UNSOUND by design outside its one question. A clean commit proves that no staged path is
named, as a whole repo-relative path, by a plan on origin/main whose first status word says under way. It cannot see
a plan with no Status line, a plan that exists only on a branch, a path named only by its basename, a directory, an
absolute path, or the files an --amend carries over from the commit it replaces (it reads what is staged now). A WARN
is COMPLETE for what it claims, because the claim is the match: the path is in the plan's text and the plan's Status
line says under way, both read from origin/main at commit time. It never says the plan is relevant, only that the
author must say whether it is.
"""
# gate-inputs: ops\plan_citation.py, ops\hooks\commit-msg
# WHAT THE SELF-TEST READS. Its own bytes (copied into temp repos), ops\hooks\commit-msg (copied, then run by a real
# `git commit`), and two frozen objects by id from git's object store (the founding commit and the plan blob it
# ignored), which cannot change under their ids. Everything else it builds under a per-run temp directory.
import datetime
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import traceback

# D18 (Brad, 2026-09-23): the warning becomes a refusal "7 days after it lands, as the Store line did". Built on
# 2026-09-23 for landing the same day, so this is 2026-09-23 plus 7. First value, not a sweep: it is the ruling's own
# arithmetic. If the landing slips, the landing commit moves this date so that a full week of warnings comes first.
REFUSE_FROM = "2026-09-30"
# The ONE exit code that refuses. ops/hooks/commit-msg maps exactly this code to a refusal and every other non-zero
# code to a BLIND line, so a crash can never be read as a refusal. 10 is outside what an interpreter failure gives
# (1 for a traceback, 2 for a file it cannot open, 120 for a flush failure, 128 and up for a signal).
REFUSE_EXIT = 10
# A Plan-not-applicable reason shorter than this says nothing a reader can check ("n/a", "not relevant"). Taken from
# store_citation.EXEMPT_MIN_WORDS, whose W6.11 measurement found the short Store-Exempt reason was a cheap escape.
# First value, not a sweep.
PNA_MIN_WORDS = 3
PLAN_REF = "origin/main"
PLAN_DIR = "design"
PLAN_NAME_RE = re.compile(r"^PLAN-[^/\\]*\.md$", re.I)
MAX_LISTED = 12              # pairs printed before "... and N more"; every pair is still logged
GIT_TIMEOUT = 30             # seconds for one git call; a timeout is BLIND, never a verdict
GIT_REPO_VARS = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
                 "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_NAMESPACE")

HEADER_END_RE = re.compile(r"^##[ \t]", re.M)
# A Status line: `Status` at the start of a line (after quote, bold or italic marks), or after a sentence end.
STATUS_RE = re.compile(r"(?im)(?:^[ \t>*_]*|[.;][ \t]+[*_]*)status\b([^\n]*)")
NEGATED_RE = re.compile(r"\b(?:not|never)\s+(?:(?:yet|been|now)\s+)*(?:ruled|under\s*way|done|complete|completed|"
                        r"implemented|shipped|closed|superseded|started)\b", re.I)
STATUS_WORD_RE = re.compile(r"\b(ruled|under\s*way|done|superseded|closed|implemented|shipped|completed?|retired|"
                            r"abandoned|withdrawn|rejected|proposed|proposal|draft|awaiting|pending|measured|"
                            r"diagnosed|diagnosis|unratified)\b", re.I)
UNDER_WAY_WORDS = ("ruled", "under way", "underway")
FINISHED_WORDS = ("done", "superseded", "closed", "implemented", "shipped", "complete", "completed", "retired",
                  "abandoned", "withdrawn", "rejected")
NOT_YET_WORDS = ("proposed", "proposal", "draft", "awaiting", "pending", "measured", "diagnosed", "diagnosis",
                 "unratified")
PLAN_LINE_RE = re.compile(r"(?im)^[ \t]*plan[ \t]*:[ \t]*(.+)$")
PNA_RE = re.compile(r"(?im)^[ \t]*plan-not-applicable[ \t]*:[ \t]*(.*)$")
CO_AUTHOR_RE = re.compile(r"(?im)^[ \t]*co-authored-by:[ \t]*claude\b")

# THE FOUNDING CASE, frozen by id: the sibling commit, and the plan blob origin/main held at its first parent.
FOUNDING_COMMIT = "5841e96b1faddb395aeef827629cc7ab76820eed"
FOUNDING_PLAN_BLOB = "dae08abe90c127a5b6be46be5ba35ed7b467ccb6"
FOUNDING_PLAN_PATH = "design/PLAN-push-derived-conflicts-2026-09-23.md"


# ---- the rule, pure over text ----------------------------------------------------------------------------------

def status_line(text):
    """The text after `Status` on the plan's Status line, or None when its header has none."""
    m = HEADER_END_RE.search(text)
    header = text[:m.start()] if m else text
    s = STATUS_RE.search(header)
    return s.group(1) if s else None


def plan_state(text):
    """(state, status text): state is under-way, finished, not-yet, unclassified or no-status."""
    s = status_line(text)
    if s is None:
        return "no-status", ""
    w = STATUS_WORD_RE.search(NEGATED_RE.sub(" ", s))
    if not w:
        return "unclassified", s.strip()
    word = re.sub(r"\s+", " ", w.group(1).lower())
    if word in UNDER_WAY_WORDS:
        return "under-way", s.strip()
    if word in FINISHED_WORDS:
        return "finished", s.strip()
    if word in NOT_YET_WORDS:
        return "not-yet", s.strip()
    raise ValueError("status word %r is in STATUS_WORD_RE and in no class" % word)


def path_pattern(path):
    """A regex that finds `path` as a whole repo-relative path, either slash, any letter case."""
    parts = [re.escape(p) for p in path.replace("\\", "/").split("/") if p]
    return re.compile(r"(?<![\w.\\/-])" + r"[\\/]".join(parts) + r"(?![\w\\/-]|\.\w)", re.I)


def _norm(p):
    return p.replace("\\", "/").lower()


def cites(msg, plan_path):
    """True when a `Plan:` line of msg names plan_path, by path or by basename, with or without .md."""
    stem = os.path.basename(plan_path.replace("\\", "/"))
    if stem.lower().endswith(".md"):
        stem = stem[:-3]
    rx = re.compile(r"(?<![\w.-])" + re.escape(stem) + r"(?:\.md)?(?![\w-])", re.I)
    return any(rx.search(m.group(1)) for m in PLAN_LINE_RE.finditer(msg))


def judge(msg, paths, plans, today):
    """The decision for one commit. msg is the message text, paths the staged repo-relative paths, plans a dict of
    plan path to text (origin/main's design/PLAN-*.md), today a YYYY-MM-DD string compared with REFUSE_FROM."""
    under = sorted((p for p, t in plans.items() if plan_state(t)[0] == "under-way"), key=_norm)
    pairs = []
    for path in sorted(set(paths), key=_norm):
        rx = path_pattern(path)
        for plan in under:
            if _norm(plan) == _norm(path):
                continue                          # a plan never names itself
            if rx.search(plans[plan]):
                pairs.append((path, plan))
    uncited = [pp for pp in pairs if not cites(msg, pp[1])]
    m = PNA_RE.search(msg)
    reason = m.group(1).strip() if m else None
    pna_ok = bool(reason) and len(reason.split()) >= PNA_MIN_WORDS
    if not pairs:
        verdict = "clear"
    elif not uncited:
        verdict = "cited"
    elif pna_ok:
        verdict = "escape"
    elif today >= REFUSE_FROM:
        verdict = "refuse"
    else:
        verdict = "warn"
    return {"verdict": verdict, "pairs": pairs, "uncited": uncited, "under_way": under, "paths": len(set(paths)),
            "pna_reason": reason, "pna_ok": pna_ok, "today": today, "refuse_from": REFUSE_FROM}


def emit(d, out=None):
    """Print what the committer needs to see for decision d and return the hook's exit code (0 or REFUSE_EXIT)."""
    out = out if out is not None else sys.stderr
    v = d["verdict"]
    if v in ("clear", "cited"):
        return 0
    if v == "escape":
        print("plan-citation: note - Plan-not-applicable: %s (recorded, not refused; %d pair(s) not cited)"
              % (d["pna_reason"], len(d["uncited"])), file=out)
        return 0
    if v == "warn":
        word, head = "WARN", "WARNING (refused from %s)" % REFUSE_FROM
    elif v == "refuse":
        word, head = "BLOCKED", "BLOCKED"
    else:
        raise ValueError("unknown plan-citation verdict: %r" % (v,))
    for path, plan in d["uncited"][:MAX_LISTED]:
        print("plan-citation: %s - %s is named by %s (build under way); read it, and add a Plan: line or "
              "Plan-not-applicable: <reason>" % (word, path, plan), file=out)
    if len(d["uncited"]) > MAX_LISTED:
        print("plan-citation: ... and %d more (path, plan) pair(s), all in the decision log"
              % (len(d["uncited"]) - MAX_LISTED), file=out)
    plans = sorted({p for _, p in d["uncited"]}, key=_norm)
    print("plan-citation: %s. %d staged path(s) are named by %d plan(s) under way that this message does not cite."
          % (head, len({p for p, _ in d["uncited"]}), len(plans)), file=out)
    if d["pna_reason"] is not None and not d["pna_ok"]:
        print("               Plan-not-applicable: needs a reason of %d words or more; %r was not accepted."
              % (PNA_MIN_WORDS, d["pna_reason"]), file=out)
    print("               Add, for example:\n"
          "                 Plan: %s <item id>\n"
          "                 Plan-not-applicable: <why this change does not bear on that plan>" % plans[0], file=out)
    return REFUSE_EXIT if v == "refuse" else 0


# ---- git -------------------------------------------------------------------------------------------------------

def git(args, cwd=None, env=None, data=None):
    return subprocess.run(["git"] + list(args), cwd=cwd, env=env, input=data, capture_output=True,
                          timeout=GIT_TIMEOUT)


def parse_batch(data):
    """The objects of one `git cat-file --batch` answer, in order: bytes, or None for a missing object."""
    out, i = [], 0
    while i < len(data):
        nl = data.index(b"\n", i)
        head = data[i:nl].decode("utf-8", "replace").split()
        i = nl + 1
        if len(head) < 2 or head[-1] == "missing" or head[1] == "missing":
            out.append(None)
            continue
        size = int(head[2])
        out.append(data[i:i + size])
        i += size + 1
    return out


def parse_tree(data):
    """(mode, name, sha) for every entry of one raw tree object."""
    out, i = [], 0
    while i < len(data):
        sp = data.index(b" ", i)
        nul = data.index(b"\0", sp)
        out.append((data[i:sp].decode(), data[sp + 1:nul].decode("utf-8", "replace"), data[nul + 1:nul + 21].hex()))
        i = nul + 21
    return out


def read_plans(ref=PLAN_REF, cwd=None, env=None):
    """({plan path: text}, None) for the design/PLAN-*.md directly under design/ at ref, or (None, why) when git
    could not say. A missing ref is a could-not-look, never an empty set."""
    try:
        v = git(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], cwd, env)
        if v.returncode != 0:
            return None, "no %s to read the plans under way from" % ref
        ls = git(["ls-tree", "-z", "--full-tree", "--name-only", ref, "--", PLAN_DIR + "/"], cwd, env)
        if ls.returncode != 0:
            return None, "git could not list %s:%s/" % (ref, PLAN_DIR)
        names = [n for n in ls.stdout.decode("utf-8", "replace").split("\0")
                 if n and n.count("/") == 1 and PLAN_NAME_RE.match(n.split("/")[1])]
        if not names:
            return {}, None
        cf = git(["cat-file", "--batch"], cwd, env, "".join("%s:%s\n" % (ref, n) for n in names).encode("utf-8"))
        blobs = parse_batch(cf.stdout) if cf.returncode == 0 else []
        if len(blobs) != len(names) or any(b is None for b in blobs):
            return None, "git could not read the %d plan(s) at %s" % (len(names), ref)
        return {n: b.decode("utf-8", "replace") for n, b in zip(names, blobs)}, None
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        return None, "git failed reading the plans at %s (%s)" % (ref, type(e).__name__)


def staged_paths(cwd=None, env=None):
    """Every path the commit being made stages, both names of a rename, or None when git cannot list them. Runs
    with the INHERITED environment unless env is given: GIT_INDEX_FILE names the index a pathspec commit builds."""
    try:
        r = git(["diff", "--cached", "--name-only", "--no-renames", "-z"], cwd, env)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    return [p for p in r.stdout.decode("utf-8", "replace").split("\0") if p]


def log_path():
    return os.path.join(os.environ.get("USERPROFILE") or os.path.expanduser("~"), ".claude", "plan-citation-log.jsonl")


def append_log(path, row):
    """Best effort: a log that cannot be written never fails a commit."""
    try:
        with open(path, "a", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(row) + "\n")
    except OSError:
        pass


def run_commit_check(msg_path):
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if not sid:
        return 0                                  # a human or the bot: not judged
    row = {"t": int(time.time()), "sid": sid, "toplevel": "", "refuse_from": REFUSE_FROM}

    def blind(why):
        print("plan-citation: BLIND - %s; the commit is not judged" % why, file=sys.stderr)
        row.update(verdict="blind", why=why)
        append_log(log_path(), row)
        return 0

    gd = git(["rev-parse", "--git-dir"])
    if gd.returncode != 0:
        return blind("git could not name the repository")
    if os.path.exists(os.path.join(gd.stdout.decode("utf-8", "replace").strip(), "MERGE_HEAD")):
        return 0                                  # a merge: not judged
    top = git(["rev-parse", "--show-toplevel"])
    row["toplevel"] = top.stdout.decode("utf-8", "replace").strip() if top.returncode == 0 else ""
    paths = staged_paths()
    if paths is None:
        return blind("git could not list the staged files")
    with open(msg_path, encoding="utf-8", errors="replace") as f:
        msg = f.read()
    row["subject"] = (msg.strip().splitlines() or [""])[0][:120]
    plans = {}
    if paths:
        plans, why = read_plans()
        if plans is None:
            return blind(why)
    d = judge(msg, paths, plans, time.strftime("%Y-%m-%d"))
    row.update(verdict=d["verdict"], paths=d["paths"], pairs=d["pairs"], uncited=d["uncited"],
               under_way=d["under_way"], pna_reason=d["pna_reason"], pna_ok=d["pna_ok"])
    append_log(log_path(), row)
    return emit(d)


# ---- replay ----------------------------------------------------------------------------------------------------

def replay(since, ref=PLAN_REF, cwd=None, env=None, out=None):
    """One row per first-parent, non-merge commit on ref since `since`, judged by judge() against the plans its first
    parent held. Returns (exit code, rows)."""
    out = out if out is not None else sys.stdout
    fmt = "%x1e%H%x1f%P%x1f%cs%x1f%B%x1f"
    lg = git(["-c", "core.quotePath=false", "log", "--first-parent", "--no-merges", "--no-renames", "--name-only",
              "--since=" + since, "--format=" + fmt, ref], cwd, env)
    if lg.returncode != 0:
        print("PLAN-CITATION-REPLAY-COMPLETE blind=git-log-failed since=%s ref=%s" % (since, ref), file=out)
        return 3, []
    commits = []
    for rec in lg.stdout.decode("utf-8", "replace").split("\x1e"):
        f = rec.split("\x1f")
        if len(f) < 5:
            continue
        parents = f[1].split()
        commits.append({"sha": f[0].strip(), "parent": parents[0] if parents else None, "date": f[2], "msg": f[3],
                        "paths": [l for l in f[4].splitlines() if l.strip()]})
    # The design/ tree at each first parent, then each distinct tree's plan blobs, then each distinct blob: three git
    # processes however long the window is.
    with_parent = [c for c in commits if c["parent"]]
    trees = {}
    if with_parent:
        bc = git(["cat-file", "--batch-check"], cwd, env,
                 "".join("%s:%s\n" % (c["parent"], PLAN_DIR) for c in with_parent).encode())
        heads = bc.stdout.decode("utf-8", "replace").splitlines() if bc.returncode == 0 else []
        if len(heads) != len(with_parent):
            print("PLAN-CITATION-REPLAY-COMPLETE blind=design-trees-unreadable since=%s ref=%s" % (since, ref), file=out)
            return 3, []
        for c, h in zip(with_parent, heads):
            p = h.split()
            c["tree"] = p[0] if len(p) >= 2 and p[1] == "tree" else None
        uniq = sorted({c["tree"] for c in with_parent if c["tree"]})
        raw = parse_batch(git(["cat-file", "--batch"], cwd, env, "".join(t + "\n" for t in uniq).encode()).stdout) if uniq else []
        entries = {}
        for t, data in zip(uniq, raw):
            entries[t] = [(name, sha) for mode, name, sha in parse_tree(data or b"")
                          if mode.startswith("100") and PLAN_NAME_RE.match(name)]
        blobs = sorted({sha for es in entries.values() for _, sha in es})
        braw = parse_batch(git(["cat-file", "--batch"], cwd, env, "".join(b + "\n" for b in blobs).encode()).stdout) if blobs else []
        text = {b: (d or b"").decode("utf-8", "replace") for b, d in zip(blobs, braw)}
        for t in uniq:
            trees[t] = {PLAN_DIR + "/" + name: text.get(sha, "") for name, sha in entries.get(t, [])}
    rows, tally = [], {}
    for c in reversed(commits):                  # oldest first
        if not CO_AUTHOR_RE.search(c["msg"]):
            v, d = "not-session", None
        else:
            d = judge(c["msg"], c["paths"], trees.get(c.get("tree"), {}), c["date"])
            v = d["verdict"]
        tally[v] = tally.get(v, 0) + 1
        subj = (c["msg"].strip().splitlines() or [""])[0][:70]
        rows.append({"sha": c["sha"], "date": c["date"], "verdict": v, "pairs": len(d["pairs"]) if d else 0,
                     "uncited": [list(pp) for pp in d["uncited"]] if d else [], "subject": subj})
        shown = ", ".join("%s<-%s" % (p, os.path.basename(pl)) for p, pl in rows[-1]["uncited"][:2])
        print("%s\t%s\t%s\tpairs=%d\tuncited=%d\t%s\t%s" % (c["sha"][:10], c["date"], v, rows[-1]["pairs"],
                                                             len(rows[-1]["uncited"]), shown or "-", subj), file=out)
    session = len(commits) - tally.get("not-session", 0)
    named = sum(tally.get(k, 0) for k in ("cited", "escape", "warn", "refuse"))
    print("plan-citation replay: %d commit(s) on %s since %s; %d session commit(s), %d not; of the session commits %d "
          "changed a file an under-way plan names, and %d of those %d carried no Plan line"
          % (len(commits), ref, since, session, tally.get("not-session", 0), named,
             tally.get("warn", 0) + tally.get("refuse", 0), named), file=out)
    print("PLAN-CITATION-REPLAY-COMPLETE commits=%d session=%d not_session=%d clear=%d cited=%d escape=%d warn=%d refuse=%d"
          % (len(commits), session, tally.get("not-session", 0), tally.get("clear", 0), tally.get("cited", 0),
             tally.get("escape", 0), tally.get("warn", 0), tally.get("refuse", 0)), file=out)
    return 0, rows


# ---- self-test -------------------------------------------------------------------------------------------------

def remove_tree(path, tries=10):
    """Remove the self-test's per-run directory. git writes its objects read-only, and on Windows a handle a git child
    has just closed can hold the emptied root for a moment (measured: two runs left an empty root behind), so the
    read-only bit is cleared and the removal retried. Removing a tree is idempotent, so a retry is always safe."""
    def clear_and_retry(func, p, _exc):
        try:
            os.chmod(p, 0o700)
            func(p)
        except OSError:
            pass
    kw = {"onexc": clear_and_retry} if sys.version_info >= (3, 12) else {"onerror": clear_and_retry}
    for _ in range(tries):
        shutil.rmtree(path, **kw)
        if not os.path.exists(path):
            return
        time.sleep(0.2)


def selftest():
    fails, n = [], 0

    def case(label, cond):
        nonlocal n
        n += 1
        if not cond:
            fails.append(label)

    here = os.path.dirname(os.path.abspath(__file__))
    before = (datetime.date.fromisoformat(REFUSE_FROM) - datetime.timedelta(days=1)).isoformat()
    root = tempfile.mkdtemp(prefix="plc-")
    try:
        # ---- the Status line: the FIRST status word decides ----
        def doc(status, body="Files: `ops/x.ps1`.\n"):
            return "# PLAN: a fixture\n\n%s\n\n## 1. Work\n\n%s" % (status, body)

        under = doc("**Status: PLAN, ruled by Brad 2026-09-23, build under way.** Revised later.")
        case("MUST FIRE a Status line saying 'ruled ... build under way' is under way",
             plan_state(under)[0] == "under-way")
        case("MUST NOT FIRE a Status line saying DONE first is finished",
             plan_state(doc("Status: DONE 2026-09-30 (ruled 2026-09-23)."))[0] == "finished")
        case("MUST NOT FIRE a Status line saying SUPERSEDED first is finished",
             plan_state(doc("> **STATUS: SUPERSEDED by PLAN-other-2026-09-24.md.**"))[0] == "finished")
        case("CLEAN TWIN 'RULED 2026-09-10, W1 DONE' is still under way: the first word decides, not any word",
             plan_state(doc("**Status: RULED 2026-09-10, W1 DONE, W2 next.**"))[0] == "under-way")
        case("MUST NOT FIRE a negated 'not ruled' and a first word of PROPOSED are not under way",
             plan_state(doc("**Status: PLAN, not ruled.**"))[0] == "unclassified"
             and plan_state(doc("**Status: PROPOSED; the earlier plan was ruled.**"))[0] == "not-yet")
        case("MUST NOT FIRE a plan with no Status line, or one only below its first ## heading, is not judged",
             plan_state("# PLAN\n\nWritten 2026-09-23.\n\n## 1. Work\n\nStatus: ruled\n")[0] == "no-status")
        case("CLEAN TWIN a Status after a sentence ('Date: ... Status: ruled') is read",
             plan_state(doc("Date: 2026-09-23. Status: ruled, build under way."))[0] == "under-way")

        # ---- a path is named as a whole repo-relative path ----
        rx = path_pattern("ops/x.ps1")
        case("MUST FIRE a path is named with either slash, any case, and a :line suffix",
             bool(rx.search("edit ops\\x.ps1 here")) and bool(rx.search("see `OPS/X.PS1:43`."))
             and bool(rx.search("(ops/x.ps1)")))
        case("MUST NOT FIRE a longer path, a prefix, a suffix and a bare basename do not name it",
             not rx.search("grocery/ops/x.ps1") and not rx.search("xops/x.ps1") and not rx.search("ops/x.ps1.bak")
             and not rx.search("ops/x.ps1x") and not rx.search("x.ps1"))

        # ---- judge() ----
        pa = "design/PLAN-a-2026-09-23.md"
        plans = {pa: under}
        d = judge("fix x\n\nbody\n", ["ops/x.ps1"], plans, before)
        case("MUST FIRE a staged path named by a plan under way, with no Plan line, warns and names the pair",
             d["verdict"] == "warn" and d["uncited"] == [("ops/x.ps1", pa)])
        eo = io.StringIO()
        erc = emit(d, out=eo)
        case("MUST FIRE the warning prints the ruled wording, and exits 0 before REFUSE_FROM",
             erc == 0 and ("plan-citation: WARN - ops/x.ps1 is named by " + pa + " (build under way); read it, and add a "
                           "Plan: line or Plan-not-applicable: <reason>") in eo.getvalue())
        d = judge("fix x\n\nPlan: " + pa + " W1\n", ["ops/x.ps1"], plans, before)
        eo = io.StringIO()
        case("MUST NOT FIRE the same commit with a Plan: line naming the plan does not warn, and prints nothing",
             d["verdict"] == "cited" and emit(d, out=eo) == 0 and eo.getvalue() == "")
        case("CLEAN TWIN a Plan: line naming the plan by basename, without .md, cites it",
             judge("x\n\nPlan: PLAN-a-2026-09-23 W7.2\n", ["ops/x.ps1"], plans, before)["verdict"] == "cited")
        case("MUST FIRE a Plan: line naming a DIFFERENT plan whose name extends this one does not cite it",
             judge("x\n\nPlan: design/PLAN-a-2026-09-23-b.md\n", ["ops/x.ps1"], plans, before)["verdict"] == "warn")
        case("MUST NOT FIRE a plan whose status says DONE or SUPERSEDED does not warn",
             judge("x\n", ["ops/x.ps1"], {pa: doc("Status: DONE.")}, before)["verdict"] == "clear"
             and judge("x\n", ["ops/x.ps1"], {pa: doc("**Status: SUPERSEDED.**")}, before)["verdict"] == "clear")
        d = judge("x\n\nPlan-not-applicable: comment typo only\n", ["ops/x.ps1"], plans, before)
        eo = io.StringIO()
        case("CLEAN TWIN Plan-not-applicable with a reason of exactly %d words (the bar) passes as an escape" % PNA_MIN_WORDS,
             d["verdict"] == "escape" and emit(d, out=eo) == 0 and "WARN" not in eo.getvalue())
        d = judge("x\n\nPlan-not-applicable: typo only\n", ["ops/x.ps1"], plans, before)
        eo = io.StringIO()
        emit(d, out=eo)
        case("MUST FIRE a Plan-not-applicable reason of %d words, one under the bar, is not an escape" % (PNA_MIN_WORDS - 1),
             d["verdict"] == "warn" and "was not accepted" in eo.getvalue())
        d = judge("x\n", ["ops/x.ps1"], plans, REFUSE_FROM)
        eo = io.StringIO()
        rc = emit(d, out=eo)
        case("MUST FIRE ON the cutoff %s an uncited pair refuses with exit %d and the BLOCKED line" % (REFUSE_FROM, REFUSE_EXIT),
             d["verdict"] == "refuse" and rc == REFUSE_EXIT and ("plan-citation: BLOCKED - ops/x.ps1 is named by " + pa) in eo.getvalue())
        case("CLEAN TWIN one day before the cutoff (%s) the same pair only warns" % before,
             judge("x\n", ["ops/x.ps1"], plans, before)["verdict"] == "warn")
        selfplan = doc("**Status: ruled.**", "This plan is " + pa + ", and it changes ops/x.ps1.\n")
        case("MUST NOT FIRE a commit that edits the plan itself is not judged against that plan",
             judge("x\n", [pa], {pa: selfplan}, before)["verdict"] == "clear")
        pb = "design/PLAN-b-2026-09-23.md"
        d = judge("x\n\nPlan: " + pa + "\n", ["ops/x.ps1"], {pa: under, pb: under}, before)
        case("MUST FIRE two plans under way name the path and the message cites one: exactly the other is uncited",
             d["verdict"] == "warn" and d["uncited"] == [("ops/x.ps1", pb)] and len(d["pairs"]) == 2)
        try:
            emit({"verdict": "sideways", "uncited": [], "pna_reason": None, "pna_ok": False}, out=io.StringIO())
            raised = False
        except ValueError:
            raised = True
        case("MUST FIRE an unknown verdict raises rather than printing nothing", raised)
        try:
            append_log(os.path.join(root, "no-such-dir", "deeper", "log.jsonl"), {"x": 1})
            logged_ok = True
        except Exception:
            logged_ok = False
        case("CLEAN TWIN a decision log that cannot be written does not raise", logged_ok)

        # ---- git: the plans on origin/main ----
        genv = {k: v for k, v in os.environ.items() if k not in GIT_REPO_VARS and k != "CLAUDE_CODE_SESSION_ID"}
        genv["GIT_CEILING_DIRECTORIES"] = root
        nohooks = os.path.join(root, "nohooks")
        os.makedirs(nohooks)
        base_cfg = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
                    "-c", "core.hooksPath=" + nohooks]

        def write(repo, rel, body):
            p = os.path.join(repo, rel.replace("/", os.sep))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8", newline="\n") as f:
                f.write(body)

        def g(repo, *args, env=None):
            return subprocess.run(["git"] + list(args), cwd=repo, env=env or genv, capture_output=True,
                                  encoding="utf-8", errors="replace", timeout=120)

        prepo = os.path.join(root, "p")
        os.makedirs(prepo)
        g(prepo, "init", "-q", "-b", "main")
        write(prepo, pa, under)
        write(prepo, "design/MEASURE-z-2026-09-23.md", under)
        write(prepo, "design/sub/PLAN-y-2026-09-23.md", under)
        g(prepo, "add", "-A")
        g(prepo, *(base_cfg + ["commit", "-q", "-m", "plans"]))
        got, why = read_plans(cwd=prepo, env=genv)
        case("MUST FIRE a repo with no origin/main reads as BLIND with its reason, never as an empty plan set",
             got is None and "no origin/main" in (why or ""))
        g(prepo, "update-ref", "refs/remotes/origin/main", "HEAD")
        got, why = read_plans(cwd=prepo, env=genv)
        case("CLEAN TWIN read_plans reads exactly the PLAN-*.md directly under design/ on origin/main, with their text",
             why is None and got is not None and sorted(got) == [pa] and got[pa] == under)

        # ---- the founding case, from the frozen objects ----
        objrepo = os.environ.get("TC_PLAN_CITATION_OBJECT_REPO") or os.path.dirname(here)
        fb = g(objrepo, "cat-file", "blob", FOUNDING_PLAN_BLOB)
        fm = g(objrepo, "log", "-1", "--format=%B", FOUNDING_COMMIT)
        fp = g(objrepo, "diff-tree", "--no-commit-id", "--name-only", "-r", "--no-renames", FOUNDING_COMMIT)
        fpaths = [l for l in fp.stdout.splitlines() if l.strip()]
        d = judge(fm.stdout, fpaths, {FOUNDING_PLAN_PATH: fb.stdout}, before) if fb.returncode == 0 else {"verdict": "unread"}
        case("MUST FIRE the founding commit 5841e96b1, judged against the plan origin/main held at its parent, warns on "
             "ops/push-main.ps1", fb.returncode == 0 and fm.returncode == 0 and fpaths == ["ops/push-main.ps1"]
             and d["verdict"] == "warn" and d.get("uncited") == [("ops/push-main.ps1", FOUNDING_PLAN_PATH)])
        d = judge(fm.stdout + "\nPlan: " + FOUNDING_PLAN_PATH + " W2.1\n", fpaths, {FOUNDING_PLAN_PATH: fb.stdout}, before) \
            if fb.returncode == 0 else {"verdict": "unread"}
        case("CLEAN TWIN the founding commit with the Plan line it lacked is cited", d["verdict"] == "cited")

        # ---- the SHARED commit-msg hook, driven by a real `git commit` in a temp repo ----
        # core.hooksPath points at a temp copy of ops/hooks/commit-msg, so git runs it the way it runs it live and
        # nothing installed on this box is touched. The checkout's own ops/plan_citation.py is a copy of this file
        # with REFUSE_FROM rewritten, so each case asserts the same verdict on any day. USERPROFILE is a temp home.
        hooks_dir = os.path.join(root, "hooks")
        os.makedirs(hooks_dir)
        with open(os.path.join(here, "hooks", "commit-msg"), "rb") as f:
            hook_bytes = f.read().replace(b"\r\n", b"\n")
        with open(os.path.join(hooks_dir, "commit-msg"), "wb") as f:
            f.write(hook_bytes)
        with open(os.path.abspath(__file__), "rb") as f:
            me = f.read().replace(b"\r\n", b"\n")
        needle = ('REFUSE_FROM = "' + REFUSE_FROM + '"').encode()
        thome = os.path.join(root, "home")
        os.makedirs(os.path.join(thome, ".claude"))
        hlog = os.path.join(thome, ".claude", "plan-citation-log.jsonl")
        henv = dict(genv, CLAUDE_CODE_SESSION_ID="plc-fixture-session", USERPROFILE=thome)
        hrepo = os.path.join(root, "h")
        os.makedirs(hrepo)
        g(hrepo, "init", "-q", "-b", "main")
        write(hrepo, pa, under)
        write(hrepo, "ops/x.ps1", "1\n")
        write(hrepo, "other.txt", "1\n")
        cut = os.path.join(hrepo, "ops", "plan_citation.py")

        def set_copy(refuse_from):
            with open(cut, "wb") as f:
                f.write(me.replace(needle, ('REFUSE_FROM = "' + refuse_from + '"').encode()))

        set_copy("9999-12-31")
        g(hrepo, "add", "-A")
        g(hrepo, *(base_cfg + ["commit", "-q", "-m", "base"]))
        g(hrepo, "update-ref", "refs/remotes/origin/main", "HEAD")
        case("CLEAN TWIN the fixture copy's REFUSE_FROM line was found exactly once, so the hook cases test a rewritten date",
             me.count(needle) == 1)
        state = {"k": 0}

        def hook_commit(rel, msg, env=None, extra=()):
            state["k"] += 1
            if rel:
                write(hrepo, rel, "%d\n" % (state["k"] + 1))
                g(hrepo, "add", "--", rel, env=env or henv)
            mp = os.path.join(root, "m%d.txt" % state["k"])
            with open(mp, "w", encoding="utf-8", newline="\n") as f:
                f.write(msg)
            h0 = g(hrepo, "rev-parse", "HEAD").stdout.strip()
            r = subprocess.run(["git", "-c", "core.hooksPath=" + hooks_dir, "-c", "user.name=t", "-c", "user.email=t@t",
                                "-c", "commit.gpgsign=false", "commit", "-q", "-F", mp] + list(extra), cwd=hrepo,
                               env=env or henv, capture_output=True, encoding="utf-8", errors="replace", timeout=180)
            return r, g(hrepo, "rev-parse", "HEAD").stdout.strip() != h0

        def log_rows():
            if not os.path.isfile(hlog):
                return []
            with open(hlog, encoding="utf-8", errors="replace") as f:
                return [json.loads(l) for l in f if l.strip()]

        r, landed = hook_commit("ops/x.ps1", "warn case\n\nbody\n")
        rows = log_rows()
        case("MUST FIRE before the cutoff the hook prints the WARN line for an uncited pair, the commit lands, and one warn "
             "row is logged", r.returncode == 0 and landed and ("plan-citation: WARN - ops/x.ps1 is named by " + pa)
             in (r.stderr or "") and len(rows) == 1 and rows[0].get("verdict") == "warn"
             and rows[0].get("uncited") == [["ops/x.ps1", pa]])
        set_copy("2000-01-01")
        r, landed = hook_commit("ops/x.ps1", "refuse case\n\nbody\n")
        case("MUST FIRE from the cutoff the hook refuses an uncited pair: the commit does not land and BLOCKED is printed",
             r.returncode != 0 and not landed and ("plan-citation: BLOCKED - ops/x.ps1 is named by " + pa) in (r.stderr or ""))
        r, landed = hook_commit(None, "cited case\n\nPlan: " + pa + " W7.2\n")
        rows = log_rows()
        case("MUST NOT FIRE from the cutoff the same staged change with a Plan: line lands, logged as cited",
             r.returncode == 0 and landed and "plan-citation: WARN" not in (r.stderr or "")
             and "plan-citation: BLOCKED" not in (r.stderr or "") and rows[-1].get("verdict") == "cited")
        write(hrepo, "ops/x.ps1", "staged but not committed\n")
        g(hrepo, "add", "--", "ops/x.ps1")
        r, landed = hook_commit("other.txt", "pathspec case\n\nbody\n", extra=("--", "other.txt"))
        rows = log_rows()
        case("MUST NOT FIRE a pathspec commit of an unnamed path is judged on ITS paths (GIT_INDEX_FILE), not on a named "
             "path staged beside it", r.returncode == 0 and landed and rows[-1].get("verdict") == "clear"
             and rows[-1].get("paths") == 1)
        g(hrepo, "reset", "-q", "--", "ops/x.ps1")
        g(hrepo, "checkout", "-q", "--", "ops/x.ps1")
        g(hrepo, "update-ref", "-d", "refs/remotes/origin/main")
        r, landed = hook_commit("ops/x.ps1", "no origin case\n\nbody\n")
        case("MUST NOT FIRE from the cutoff, with no origin/main to read, the hook says BLIND and the commit lands",
             r.returncode == 0 and landed and "plan-citation: BLIND - no origin/main" in (r.stderr or ""))
        g(hrepo, "update-ref", "refs/remotes/origin/main", "HEAD")
        nosid = {k: v for k, v in henv.items() if k != "CLAUDE_CODE_SESSION_ID"}
        nrows = len(log_rows())
        r, landed = hook_commit("ops/x.ps1", "human case\n\nbody\n", env=nosid)
        case("CLEAN TWIN with no CLAUDE_CODE_SESSION_ID the commit is not judged: it lands, nothing is printed, nothing logged",
             r.returncode == 0 and landed and "plan-citation" not in (r.stderr or "") and len(log_rows()) == nrows)
        g(hrepo, "checkout", "-q", "-b", "side")
        r, _ = hook_commit("ops/x.ps1", "side change\n\nbody\n", env=nosid)
        g(hrepo, "checkout", "-q", "main")
        r, _ = hook_commit("other.txt", "main change\n\nbody\n", env=nosid)
        mp = os.path.join(root, "merge.txt")
        with open(mp, "w", encoding="utf-8", newline="\n") as f:
            f.write("merge side\n\nbody\n")
        h0 = g(hrepo, "rev-parse", "HEAD").stdout.strip()
        mr = subprocess.run(["git", "-c", "core.hooksPath=" + hooks_dir, "-c", "user.name=t", "-c", "user.email=t@t",
                             "-c", "commit.gpgsign=false", "merge", "-q", "--no-ff", "side", "-F", mp], cwd=hrepo,
                            env=henv, capture_output=True, encoding="utf-8", errors="replace", timeout=180)
        case("MUST NOT FIRE from the cutoff a merge that brings in a named path is not judged, and lands",
             mr.returncode == 0 and g(hrepo, "rev-parse", "HEAD").stdout.strip() != h0
             and "plan-citation: BLOCKED" not in (mr.stderr or ""))
        # The hook used to `exit 1` the moment store_citation refused. It now runs both checks and then decides, so
        # the adjacent behaviour most likely broken on the way past is a store refusal: it must still refuse, and the
        # plan check must have run as well. A stub store_citation.py that refuses stands in for the real one.
        set_copy("9999-12-31")
        stub_store = os.path.join(hrepo, "ops", "store_citation.py")
        with open(stub_store, "w", encoding="utf-8", newline="\n") as f:
            f.write("import sys\nsys.exit(1)\n")
        r, landed = hook_commit("ops/x.ps1", "store refuses\n\nbody\n")
        case("CLEAN TWIN a store-citation refusal still refuses the commit, and the plan check ran before the hook decided",
             r.returncode != 0 and not landed and ("plan-citation: WARN - ops/x.ps1 is named by " + pa) in (r.stderr or ""))
        os.remove(stub_store)
        g(hrepo, "reset", "-q", "--", "ops/x.ps1")
        with open(cut, "w", encoding="utf-8", newline="\n") as f:
            f.write("raise RuntimeError('fixture crash')\n")
        r, landed = hook_commit("ops/x.ps1", "crash case\n\nbody\n")
        case("MUST NOT FIRE a check that crashes (exit 1) is BLIND, never a refusal: the uncited commit lands",
             r.returncode == 0 and landed and "plan-citation: BLIND - ops/plan_citation.py exited 1" in (r.stderr or ""))
        os.remove(cut)
        r, landed = hook_commit("ops/x.ps1", "missing case\n\nbody\n")
        case("MUST NOT FIRE a checkout with no ops/plan_citation.py says BLIND and the commit lands",
             r.returncode == 0 and landed and "plan-citation: BLIND - this checkout has no ops/plan_citation.py"
             in (r.stderr or ""))

        # ---- replay: the same judge() over landed history ----
        # The commits are dated the day before REFUSE_FROM, because replay judges each on its own date: made today,
        # they would read refuse instead of warn once the cutoff passed, and the case would go red on the calendar.
        rrepo = os.path.join(root, "r")
        os.makedirs(rrepo)
        g(rrepo, "init", "-q", "-b", "main")
        renv = dict(genv, GIT_AUTHOR_DATE=before + "T12:00:00+00:00", GIT_COMMITTER_DATE=before + "T12:00:00+00:00")
        co = "\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n"
        for i, (files, msg) in enumerate(((((pa, under), ("ops/x.ps1", "1\n")), "base" + co),
                                          ((("ops/x.ps1", "2\n"),), "uncited" + co),
                                          ((("ops/x.ps1", "3\n"),), "cited\n\nPlan: " + pa + co),
                                          ((("ops/x.ps1", "4\n"),), "a person\n"))):
            for rel, body in files:
                write(rrepo, rel, body)
            g(rrepo, "add", "-A")
            mpath = os.path.join(root, "r%d.txt" % i)
            with open(mpath, "w", encoding="utf-8", newline="\n") as f:
                f.write(msg)
            g(rrepo, *(base_cfg + ["commit", "-q", "-F", mpath]), env=renv)
        ro = io.StringIO()
        rrc, rrows = replay("2000-01-01", ref="main", cwd=rrepo, env=genv, out=ro)
        case("CLEAN TWIN replay judges each landed commit against its parent's plans: clear, warn, cited, not-session",
             rrc == 0 and [x["verdict"] for x in rrows] == ["clear", "warn", "cited", "not-session"]
             and "PLAN-CITATION-REPLAY-COMPLETE commits=4 session=3 not_session=1 clear=1 cited=1 escape=0 warn=1 refuse=0"
             in ro.getvalue())
        ro = io.StringIO()
        rrc, _ = replay("2000-01-01", ref="no-such-ref", cwd=rrepo, env=genv, out=ro)
        case("MUST FIRE replay over a ref git cannot read exits 3 BLIND, never a clean zero", rrc == 3 and "blind=" in ro.getvalue())
    finally:
        remove_tree(root)
    if os.path.exists(root):
        print("  note  the temp directory %s could not be removed (a handle was still open on it)" % root)

    for f in fails:
        print("  FAIL  " + f)
    expected = 40
    if n != expected:
        fails.append("ran %d cases, expected %d" % (n, expected))
        print("  FAIL  ran %d cases, expected %d" % (n, expected))
    print("plan_citation self-test: %s (cases=%d failures=%d)" % ("pass" if not fails else "FAIL", n, len(fails)))
    return 1 if fails else 0


def main(argv):
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    if "--selftest" in argv:
        return selftest()
    if "--replay" in argv:
        i = argv.index("--replay")
        if i + 1 >= len(argv):
            print("usage: plan_citation.py --replay <since, e.g. 2026-09-16> [<ref>]", file=sys.stderr)
            return 2
        ref = argv[i + 2] if i + 2 < len(argv) else PLAN_REF
        return replay(argv[i + 1], ref)[0]
    if "--commit-msg" in argv:
        i = argv.index("--commit-msg")
        if i + 1 >= len(argv):
            print("plan-citation: BLIND - no message file was passed; the commit is not judged", file=sys.stderr)
            return 0
        try:
            return run_commit_check(argv[i + 1])
        except Exception as e:                    # FAILS OPEN, and says so: never a silent pass
            print("plan-citation: BLIND - the check raised %s: %s; the commit is not judged" % (type(e).__name__, e),
                  file=sys.stderr)
            traceback.print_exc(file=sys.stderr)
            return 0
    print(__doc__.splitlines()[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
