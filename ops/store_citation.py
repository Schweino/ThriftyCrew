r"""store_citation.py - did the change say what the knowledge store told it?

    python ops/store_citation.py                      # plan audit (run-gates runs this, no arguments)
    python ops/store_citation.py --commit-msg <file>  # the commit-msg hook calls this
    python ops/store_citation.py --selftest           # frozen fixtures, hermetic

WHY THIS EXISTS (Brad, 2026-09-18). The knowledge store (~/.claude/skills and the memory directory) holds
the engineering rules this estate has paid for, and nothing made a session USE them. Measured that day:
the backlog run made real code fixes across dozens of subagents with 0 store searches and 127 of 127
replies reading "Consulted: nothing relevant". The one fix that searched first (2c6a2b5b5, the graph
import) came out with a better design BECAUSE of it. Pushing knowledge at a session automatically was
measured and refused twice (the file-path signal and edit-time craft recall, both 2026-09-12), and a
prose rule delivered every turn was broken six times (memory always-on-delivery-is-not-sufficient).
So this does not try to recall anything. It checks the RECORD, at the two places a decision is written
down, and a record either exists and resolves or it does not - that part has an exit code.

TWO CHECKS.
  1. A design/PLAN-*.md or design/MEASURE-*.md dated on or after PLAN_CUTOFF carries a
     `## Knowledge consulted` section with something under it. Older plans are not judged, so this is
     at zero on the day it lands and needs no ratchet.
  2. A commit made by a Claude session (CLAUDE_CODE_SESSION_ID is set) that changes CODE carries a
     `Store:` line naming the store files it used, or `Store: searched <terms>, nothing applicable`.
     Every named file must RESOLVE. A human commit and the daily bot have no session id and are not
     judged; neither is a merge, nor a commit that touches no code. `Store-Exempt: <reason>` is the
     loud, logged way out for a mechanical commit (a rename, a revert, a data refresh).

WARN, THEN REFUSE (Brad's ruling, 2026-09-18). Until REFUSE_FROM the commit check prints its finding and
lets the commit through; from that date a missing or unresolvable line refuses the commit. The week in
between is measured by ~/.claude/skills/store-usage-report.py off the decision log this appends to, and
the date is the one line to move if that week shows the rule crying wolf.

WHAT "BACKED" MEANS. knowledge-search's search.py logs every search with the session id (02da8e6, store
repo). A `Store:` line from a session with NO logged search in the last BACKING_HOURS is recorded as
unbacked. That is logged and reported, never refused: a session id can go missing for reasons that are
not the author's, and a could-not-look must not settle the question.

SCOPE OF A CLEAN REPORT: sound for what it checks and nothing more. A clean plan audit proves every new
plan HAS the section, never that the section is honest or that the design used it well; a judgement has
no exit code. A clean commit check proves the named files exist, not that they were read.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time

PLAN_CUTOFF = "2026-09-20"   # plans named with an earlier date are not judged (first day after landing)
REFUSE_FROM = "2026-09-25"   # Brad, 2026-09-18: one week of warnings, then refuse. First value, not a sweep.
BACKING_HOURS = 24           # a search this recent in the same session backs a Store: line. First value.

CODE_EXT = {".ps1", ".psm1", ".py", ".js", ".ts", ".sql", ".sh"}
NOT_CODE_PREFIX = ("grocery/out/", "archive/", "meal-prep/out/", "ops/prompt-backup/")
PLAN_RE = re.compile(r"^(PLAN|MEASURE)-.*?(\d{4}-\d{2}-\d{2}).*\.md$")
HEADING_RE = re.compile(r"^##\s+knowledge consulted\s*$", re.I | re.M)
STORE_LINE_RE = re.compile(r"^store:\s*(.*)$", re.I | re.M)
EXEMPT_RE = re.compile(r"^store-exempt:\s*(\S.*)$", re.I | re.M)
NOTHING_RE = re.compile(r"\bsearched\b.*\b(nothing|none)\b.*\bapplicable\b", re.I)
PATH_RE = re.compile(r"(?:memory:[\w.-]+|\[\[[\w.-]+\]\]|[\w.-]+(?:/[\w.-]+)*\.md)")


def home_store():
    h = os.path.join(os.environ.get("USERPROFILE") or os.path.expanduser("~"), ".claude")
    return {"skills": os.path.join(h, "skills"),
            "memory": os.path.join(h, "projects", "C--Codex-ThriftyCrew", "memory"),
            "log": os.path.join(h, "store-citation-log.jsonl"),
            "recall_log": os.path.join(h, "recall-log.jsonl")}


# ---- plan audit -------------------------------------------------------------------------------------

def plan_findings(design_dir, cutoff=PLAN_CUTOFF):
    """(judged, missing): plan files dated >= cutoff, and those without a non-empty section."""
    judged, missing = [], []
    for name in sorted(os.listdir(design_dir)) if os.path.isdir(design_dir) else []:
        m = PLAN_RE.match(name)
        if not m or m.group(2) < cutoff:
            continue
        judged.append(name)
        with open(os.path.join(design_dir, name), encoding="utf-8", errors="replace") as f:
            text = f.read()
        h = HEADING_RE.search(text)
        body = ""
        if h:
            rest = text[h.end():]
            nxt = re.search(r"^##\s", rest, re.M)
            body = (rest[:nxt.start()] if nxt else rest).strip()
        if not body:
            missing.append(name)
    return judged, missing


def run_plan_audit(repo):
    judged, missing = plan_findings(os.path.join(repo, "design"))
    for name in missing:
        print("  MISSING  design/%s has no '## Knowledge consulted' section with content" % name)
    if missing:
        print("store-citation: %d of %d plan(s) dated %s or later name nothing from the knowledge store."
              " Add the section: the search terms you ran and each store file you used, or"
              " 'searched <terms>: nothing applicable'." % (len(missing), len(judged), PLAN_CUTOFF))
    print("STORE-CITATION-PLANS-COMPLETE judged=%d missing=%d cutoff=%s" % (len(judged), len(missing), PLAN_CUTOFF))
    return 1 if missing else 0


# ---- commit check -----------------------------------------------------------------------------------

def is_code(path):
    p = path.replace("\\", "/")
    if p.startswith(NOT_CODE_PREFIX):
        return False
    return os.path.splitext(p)[1].lower() in CODE_EXT or p.startswith("ops/hooks/")


def resolve(token, store):
    """True when a cited token names a real store file."""
    t = token.strip()
    if t.startswith("memory:") or t.startswith("[["):
        name = t[7:] if t.startswith("memory:") else t[2:-2]
        name = name[:-3] if name.endswith(".md") else name
        return os.path.isfile(os.path.join(store["memory"], name + ".md"))
    rel = t.replace("\\", "/")
    for base in (store["skills"], os.path.dirname(store["skills"]), store["memory"]):
        if os.path.isfile(os.path.join(base, rel)):
            return True
    return False


def judge_message(text, code_files, store, today, searched):
    """The decision for one commit message: a dict with verdict ok|exempt|warn|refuse and why."""
    d = {"code_files": len(code_files), "cited": [], "unresolved": [], "backed": searched,
         "mode": "refuse" if today >= REFUSE_FROM else "warn"}
    if not code_files:
        d.update(verdict="ok", why="no code changed")
        return d
    ex = EXEMPT_RE.search(text)
    if ex:
        d.update(verdict="exempt", why=ex.group(1).strip())
        return d
    lines = [m.group(1).strip() for m in STORE_LINE_RE.finditer(text)]
    if not lines or not any(lines):
        d.update(verdict=d["mode"], why="no Store: line")
        return d
    body = " ".join(lines)
    d["cited"] = PATH_RE.findall(body)
    d["unresolved"] = [c for c in d["cited"] if not resolve(c, store)]
    if d["unresolved"]:
        d.update(verdict=d["mode"], why="cited file(s) do not resolve")
    elif not d["cited"] and not NOTHING_RE.search(body):
        d.update(verdict=d["mode"], why="Store: line names no store file and does not say what was searched")
    else:
        d.update(verdict="ok", why="cited" if d["cited"] else "searched, nothing applicable")
    return d


def session_searched(recall_log, sid, now, hours=BACKING_HOURS):
    """True/False when the search log can say; None when it cannot be read."""
    try:
        with open(recall_log, encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"search"' not in line or sid not in line:
                    continue
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("ev") == "search" and r.get("sid") == sid and now - r.get("t", 0) <= hours * 3600:
                    return True
        return False
    except OSError:
        return None


def staged_code_files():
    out = subprocess.run(["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return None
    return [p for p in out.stdout.splitlines() if p and is_code(p)]


def append_log(path, row):
    try:
        with open(path, "a", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(row) + "\n")
    except OSError:
        pass


def run_commit_check(msg_path):
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if not sid:
        return 0                                  # a human or the bot: not judged
    git_dir = subprocess.run(["git", "rev-parse", "--git-dir"], capture_output=True, text=True).stdout.strip()
    if git_dir and os.path.exists(os.path.join(git_dir, "MERGE_HEAD")):
        return 0
    store = home_store()
    if not os.path.isdir(store["skills"]):
        print("store-citation: BLIND - no knowledge store at %s, commit not judged" % store["skills"], file=sys.stderr)
        return 0
    code = staged_code_files()
    if code is None:
        print("store-citation: BLIND - could not list staged files, commit not judged", file=sys.stderr)
        return 0
    with open(msg_path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    text = "\n".join(l for l in text.splitlines() if not l.startswith("#"))
    now = int(time.time())
    today = time.strftime("%Y-%m-%d")
    d = judge_message(text, code, store, today, session_searched(store["recall_log"], sid, now))
    d.update(t=now, sid=sid, repo=os.path.basename(os.getcwd()), subject=(text.strip().splitlines() or [""])[0][:120])
    append_log(store["log"], d)
    if d["verdict"] in ("ok", "exempt"):
        if d["verdict"] == "ok" and d["cited"] and d["backed"] is False:
            print("store-citation: note - Store: line cites files but this session logged no search in the last"
                  " %dh (recorded, not refused)" % BACKING_HOURS, file=sys.stderr)
        return 0
    head = "WARNING (refused from %s)" % REFUSE_FROM if d["verdict"] == "warn" else "BLOCKED"
    print("store-citation: %s. This commit changes %d code file(s) and %s." % (head, len(code), d["why"]), file=sys.stderr)
    if d["unresolved"]:
        print("                not found in the store: %s" % ", ".join(d["unresolved"]), file=sys.stderr)
    print("                Search first:  C:\\Codex\\Python312\\python.exe %USERPROFILE%\\.claude\\skills\\knowledge-search\\search.py \"<terms>\"\n"
          "                then add a line such as:\n"
          "                  Store: database-craft/transactions-and-recovery.md (section 3); memory:ps-null-count-is-one\n"
          "                  Store: searched \"regex timeout\", nothing applicable\n"
          "                  Store-Exempt: <reason>   (mechanical commits only - logged)", file=sys.stderr)
    return 1 if d["verdict"] == "refuse" else 0


# ---- self-test --------------------------------------------------------------------------------------

def selftest():
    fails, n = [], 0

    def case(label, cond):
        nonlocal n
        n += 1
        if not cond:
            fails.append(label)

    root = tempfile.mkdtemp(prefix="stc-")
    try:
        store = {"skills": os.path.join(root, "skills"), "memory": os.path.join(root, "mem"),
                 "log": os.path.join(root, "log.jsonl"), "recall_log": os.path.join(root, "recall.jsonl")}
        os.makedirs(os.path.join(store["skills"], "database-craft"))
        os.makedirs(store["memory"])
        open(os.path.join(store["skills"], "database-craft", "transactions.md"), "w").close()
        open(os.path.join(store["memory"], "ps-null.md"), "w").close()
        code = ["ops/x.ps1"]
        warn_day, refuse_day = "2026-09-19", REFUSE_FROM

        d = judge_message("fix\n\nbody\n", code, store, warn_day, None)
        case("MUST FIRE code commit with no Store: line warns before the refuse date", d["verdict"] == "warn")
        d = judge_message("fix\n\nbody\n", code, store, refuse_day, None)
        case("MUST FIRE code commit with no Store: line is refused from the refuse date", d["verdict"] == "refuse")
        d = judge_message("fix\n\nStore: database-craft/nope.md\n", code, store, refuse_day, None)
        case("MUST FIRE a cited file that does not exist is refused", d["verdict"] == "refuse" and d["unresolved"] == ["database-craft/nope.md"])
        d = judge_message("fix\n\nStore: memory:ghost\n", code, store, refuse_day, None)
        case("MUST FIRE a memory that does not exist is refused", d["verdict"] == "refuse")
        d = judge_message("fix\n\nStore: I looked around\n", code, store, refuse_day, None)
        case("MUST FIRE a Store: line naming nothing and no search is refused", d["verdict"] == "refuse")
        d = judge_message("fix\n\nStore: database-craft/transactions.md (section 3); memory:ps-null\n", code, store, refuse_day, True)
        case("MUST NOT FIRE resolvable citations pass", d["verdict"] == "ok" and len(d["cited"]) == 2)
        d = judge_message("fix\n\nStore: [[ps-null]]\n", code, store, refuse_day, True)
        case("MUST NOT FIRE a [[memory]] citation resolves", d["verdict"] == "ok")
        d = judge_message('fix\n\nStore: searched "regex timeout", nothing applicable\n', code, store, refuse_day, True)
        case("MUST NOT FIRE an explicit nothing-applicable search passes", d["verdict"] == "ok")
        d = judge_message("data\n", [], store, refuse_day, None)
        case("MUST NOT FIRE a commit with no code is not judged", d["verdict"] == "ok")
        d = judge_message("rename\n\nStore-Exempt: pure rename\n", code, store, refuse_day, None)
        case("MUST NOT FIRE Store-Exempt passes and records its reason", d["verdict"] == "exempt" and d["why"] == "pure rename")
        case("CLEAN TWIN code detection: a .ps1 is code, a board output is not, a hook is",
             is_code("ops/x.ps1") and not is_code("grocery/out/a.py") and is_code("ops/hooks/commit-msg") and not is_code("design/PLAN-x.md"))

        with open(store["recall_log"], "w") as f:
            f.write(json.dumps({"t": 1000, "ev": "search", "sid": "s1"}) + "\n")
            f.write(json.dumps({"t": 1000, "ev": "open", "sid": "s2"}) + "\n")
            f.write(json.dumps({"t": 1000, "ev": "search", "sid": "s3x"}) + "\n")
        case("MUST FIRE a logged search in the same session backs the line", session_searched(store["recall_log"], "s1", 2000) is True)
        case("MUST NOT FIRE another session's search, or an open, backs nothing", session_searched(store["recall_log"], "s2", 2000) is False)
        case("MUST NOT FIRE a session id that is only a SUBSTRING of a searching session's backs nothing",
             session_searched(store["recall_log"], "s3", 2000) is False)
        case("MUST NOT FIRE a search older than the window backs nothing", session_searched(store["recall_log"], "s1", 1000 + BACKING_HOURS * 3600 + 1) is False)
        case("CLEAN TWIN an unreadable log is None, never False", session_searched(os.path.join(root, "absent"), "s1", 2000) is None)

        dd = os.path.join(root, "design")
        os.makedirs(dd)
        with open(os.path.join(dd, "PLAN-old-2026-09-01.md"), "w") as f:
            f.write("# old\n")
        with open(os.path.join(dd, "PLAN-new-%s.md" % PLAN_CUTOFF), "w") as f:
            f.write("# new\n\n## Knowledge consulted\n\n## Next\n")
        with open(os.path.join(dd, "MEASURE-good-%s.md" % PLAN_CUTOFF), "w") as f:
            f.write("# m\n\n## Knowledge consulted\n\nsearched x: nothing applicable\n")
        judged, missing = plan_findings(dd)
        case("MUST FIRE a new plan whose section is EMPTY is missing", missing == ["PLAN-new-%s.md" % PLAN_CUTOFF])
        case("MUST NOT FIRE a plan dated before the cutoff is not judged", "PLAN-old-2026-09-01.md" not in judged)
        case("CLEAN TWIN a filled section on a MEASURE doc is judged and passes", "MEASURE-good-%s.md" % PLAN_CUTOFF in judged and len(judged) == 2)
    finally:
        import shutil
        shutil.rmtree(root, ignore_errors=True)

    for f in fails:
        print("  FAIL  " + f)
    expected = 19
    if n != expected:
        fails.append("ran %d cases, expected %d" % (n, expected))
        print("  FAIL  ran %d cases, expected %d" % (n, expected))
    print("store_citation self-test: %s (cases=%d failures=%d)" % ("pass" if not fails else "FAIL", n, len(fails)))
    return 1 if fails else 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    if "--commit-msg" in argv:
        i = argv.index("--commit-msg")
        return run_commit_check(argv[i + 1]) if i + 1 < len(argv) else 0
    return run_plan_audit(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
