r"""replay-store-citations.py - what would the Store: check decide about commits that already landed?

    python ops/replay-store-citations.py --since 2026-09-20T00:00:00 --until 2026-09-22T19:08:00 --today 2026-09-25
    python ops/replay-store-citations.py --since 2026-09-15T00:00:00 --until ... --compare-ref origin/main
    python ops/replay-store-citations.py --selftest

WHY THIS EXISTS (2026-09-23, W0.1 of design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md). From
REFUSE_FROM the commit-msg hook refuses a Claude-session code commit whose Store: line does not resolve, and
the resolver did not look inside the repository, so a commit citing the estate's own rules, design docs or
libraries - the knowledge goal 1 of that plan asks every change to use - would have been refused. A replay of
2026-09-20..22 found four such commits. A fix to a rule that refuses things is judged on the commits it would
have refused, so this replays landed history through `store_citation.judge_message` as a CHARACTERIZATION: it
pins what the rule decides today, then shows exactly which verdicts a change to the rule moves, in which
direction, over which commits (software-craft/tests-as-safety-net.md 1). It is committed rather than kept in
a scratch directory because the question recurs every time the rule changes (.claude/rules/measurement.md,
"naming a scratch harness is not naming a harness").

WHAT IT JUDGES. Non-merge commits on --ref inside [--since, --until] whose message carries a Claude
co-author trailer, the same population the live hook judges (a session commit). Each commit is judged with
ITS OWN tracked set (`git ls-tree -r --name-only <sha>`) and its own changed code files, never today's tree,
so a citation of a file that existed at the time resolves and one that did not is refused. Pass both bounds
with a time of day: a date-only `--since` starts at the current time of day, which cut 2026-09-18 to its
evening in the review that wrote W0.1.

--compare-ref <ref> also loads the store_citation.py held at that ref and judges every commit with both, and
prints each commit whose verdict differs, with the direction. That is the "did the change only widen what
passes" question, asked of real history.

EXIT. 0 when it judged at least one commit; 3 when it judged none (a window with no session code commits, or
a git failure) - a replay that read nothing has not shown anything, and must not read as a pass.

SCOPE OF A CLEAN REPORT: it replays the MESSAGE rule only. It cannot replay whether the session searched (the
search log is not in git), and it judges each commit's tracked set as git holds it, not the index a pathspec
commit actually used, which differs only for files staged beside the commit and never committed.
"""
# The self-test builds its own temp repo and copies in the resolver it loads:
# gate-inputs: ops\store_citation.py
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TRAILER_RE = re.compile(r"^co-authored-by:\s*claude\b", re.I | re.M)
GIT_REPO_VARS = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
                 "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_NAMESPACE")


def git(args, cwd, env=None):
    r = subprocess.run(["git"] + args, cwd=cwd, env=env, capture_output=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (" ".join(args[:3]), (r.stderr or "").strip()[:200]))
    return r.stdout


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_at_ref(repo, ref, tmp):
    """The store_citation.py that <ref> holds, imported from a temp copy."""
    text = git(["show", "%s:ops/store_citation.py" % ref], repo)
    path = os.path.join(tmp, "store_citation_at_ref.py")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    return load_module(path, "store_citation_at_ref")


def session_commits(repo, ref, since, until):
    """[(sha, message)] for non-merge commits in the window that carry a Claude co-author trailer."""
    args = ["log", ref, "--no-merges", "--format=%H%x00%B%x1e"]
    if since:
        args.append("--since=" + since)
    if until:
        args.append("--until=" + until)
    out = []
    for chunk in git(args, repo).split("\x1e"):
        chunk = chunk.strip("\n")
        if "\x00" not in chunk:
            continue
        sha, msg = chunk.split("\x00", 1)
        if TRAILER_RE.search(msg):
            out.append((sha.strip(), msg))
    return out


def judge_commit(sc, repo, sha, msg, today, home):
    code = [p for p in git(["show", "--name-only", "--diff-filter=ACMR", "--format=", sha], repo).splitlines()
            if p and sc.is_code(p)]
    if not code:
        return None
    tracked = {p.lower() for p in git(["ls-tree", "-r", "--name-only", sha], repo).splitlines() if p}
    store = dict(home)
    store.update(tracked=tracked, repo_roots=[repo.replace("\\", "/")], repo_blind=False)
    text = "\n".join(l for l in msg.splitlines() if not l.startswith("#"))
    return sc.judge_message(text, code, store, today, None)


def replay(repo, ref, since, until, today, sc, home, old=None, out=print):
    rows = []
    for sha, msg in session_commits(repo, ref, since, until):
        d = judge_commit(sc, repo, sha, msg, today, home)
        if d is None:
            continue
        row = {"sha": sha[:9], "verdict": d["verdict"], "why": d["why"], "cited": d.get("cited", []),
               "kinds": d.get("cited_kinds", []), "blind": bool(d.get("repo_blind")),
               "subject": (msg.strip().splitlines() or [""])[0][:70]}
        if old is not None:
            o = judge_commit(old, repo, sha, msg, today, home)
            row["old_verdict"] = o["verdict"] if o else "not-judged"
        rows.append(row)
        out("  %-9s %-7s %s%s  %s" % (row["sha"], row["verdict"],
                                     ("(was %s) " % row["old_verdict"]) if old is not None and row["old_verdict"] != row["verdict"] else "",
                                     row["why"], row["subject"]))
    judged = len(rows)
    refused = sum(1 for r in rows if r["verdict"] == "refuse")
    blind = sum(1 for r in rows if r["blind"])
    tail = "judged=%d refused=%d blind=%d" % (judged, refused, blind)
    if old is not None:
        changed = [r for r in rows if r["old_verdict"] != r["verdict"]]
        widened = sum(1 for r in changed if r["verdict"] in ("ok", "exempt"))
        narrowed = sum(1 for r in changed if r["verdict"] not in ("ok", "exempt"))
        tail += " changed=%d widened=%d narrowed=%d" % (len(changed), widened, narrowed)
    out("replay-store-citations: " + tail + " today=" + today)
    out("REPLAY-STORE-CITATIONS-COMPLETE " + tail)
    return rows


def clean_git_env(**extra):
    env = {k: v for k, v in os.environ.items() if k not in GIT_REPO_VARS}
    env.update(extra)
    return env


def selftest():
    fails, n = [], 0

    def case(label, cond):
        nonlocal n
        n += 1
        if not cond:
            fails.append(label)
            print("  FAIL  " + label)

    sc = load_module(os.path.join(HERE, "store_citation.py"), "store_citation_for_replay_selftest")
    root = tempfile.mkdtemp(prefix="rsc-")
    try:
        env = clean_git_env(GIT_CEILING_DIRECTORIES=root)
        repo = os.path.join(root, "repo")
        os.makedirs(os.path.join(repo, ".claude", "rules"))
        os.makedirs(os.path.join(repo, "lib"))
        os.makedirs(os.path.join(repo, "ops"))
        shutil.copyfile(os.path.join(HERE, "store_citation.py"), os.path.join(repo, "ops", "store_citation.py"))

        def commit(files, msg):
            for rel, body in files.items():
                with open(os.path.join(repo, rel), "w", encoding="utf-8", newline="\n") as f:
                    f.write(body)
            git(["add", "--"] + list(files), repo, env)
            git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", msg], repo, env)

        git(["init", "-q"], repo, env)
        commit({".claude/rules/r.md": "# r\n", "ops/store_citation.py": open(os.path.join(repo, "ops", "store_citation.py"), encoding="utf-8").read()},
               "base, by a human")
        commit({"lib/x.ps1": "1\n"}, "cites a rule\n\nStore: .claude/rules/r.md\n\nCo-Authored-By: Claude X <x@x>")
        commit({"lib/x.ps1": "2\n"}, "no store line\n\nCo-Authored-By: Claude X <x@x>")
        commit({"lib/x.ps1": "3\n"}, "a human code commit")
        commit({"notes.md": "n\n"}, "docs only\n\nCo-Authored-By: Claude X <x@x>")

        home = {"skills": os.path.join(root, "skills"), "memory": os.path.join(root, "mem"),
                "memories": [os.path.join(root, "mem")], "log": os.path.join(root, "log.jsonl"),
                "recall_log": os.path.join(root, "recall.jsonl")}
        os.makedirs(home["skills"])
        os.makedirs(home["memory"])
        lines = []
        rows = replay(repo, "HEAD", None, None, sc.REFUSE_FROM, sc, home, out=lines.append)
        by_subject = {r["subject"]: r for r in rows}
        case("CLEAN TWIN exactly the two session CODE commits are judged (a human commit and a docs-only commit are not)",
             len(rows) == 2 and set(by_subject) == {"cites a rule", "no store line"})
        case("MUST FIRE a session code commit with no Store: line replays as refuse on the refuse date",
             by_subject.get("no store line", {}).get("verdict") == "refuse")
        case("CLEAN TWIN each commit is judged against its OWN tracked set, never flagged blind",
             all(r["blind"] is False for r in rows))
        case("CLEAN TWIN the last line is the COMPLETE marker naming the judged count",
             bool(lines) and lines[-1].startswith("REPLAY-STORE-CITATIONS-COMPLETE judged=2 "))
        old = load_at_ref(repo, "HEAD", root)
        lines2 = []
        rows2 = replay(repo, "HEAD", None, None, sc.REFUSE_FROM, sc, home, old=old, out=lines2.append)
        case("MUST NOT FIRE a resolver compared with the identical resolver changes no verdict",
             all(r["old_verdict"] == r["verdict"] for r in rows2) and " changed=0 " in lines2[-1] + " ")
        lines3 = []
        # A window that ENDS before the repo existed. (A far-future --since is not a safe empty window: git's
        # approxidate can drop a year it cannot parse, and the window silently becomes everything.)
        rows3 = replay(repo, "HEAD", None, "2001-01-01T00:00:00", sc.REFUSE_FROM, sc, home, out=lines3.append)
        case("MUST FIRE an empty window judges nothing, and main() reads that as exit 3, never a pass",
             rows3 == [] and lines3[-1].startswith("REPLAY-STORE-CITATIONS-COMPLETE judged=0 "))
    except Exception as e:
        fails.append("the self-test raised: %r" % (e,))
        print("  FAIL  the self-test raised: %r" % (e,))
    finally:
        shutil.rmtree(root, ignore_errors=True)

    expected = 6
    if n != expected:
        fails.append("ran %d cases, expected %d" % (n, expected))
        print("  FAIL  ran %d cases, expected %d" % (n, expected))
    print("replay-store-citations self-test: %s (cases=%d failures=%d)" % ("pass" if not fails else "FAIL", n, len(fails)))
    return 1 if fails else 0


def main(argv):
    if "--selftest" in argv:
        return selftest()

    def opt(name, default=None):
        return argv[argv.index(name) + 1] if name in argv and argv.index(name) + 1 < len(argv) else default

    repo = os.path.dirname(HERE)
    sc = load_module(os.path.join(HERE, "store_citation.py"), "store_citation_for_replay")
    today = opt("--today", __import__("time").strftime("%Y-%m-%d"))
    tmp = tempfile.mkdtemp(prefix="rsc-")
    try:
        old = load_at_ref(repo, opt("--compare-ref"), tmp) if opt("--compare-ref") else None
        rows = replay(repo, opt("--ref", "origin/main"), opt("--since"), opt("--until"), today, sc, sc.home_store(), old=old)
    except RuntimeError as e:
        print("replay-store-citations: BLIND - %s" % e)
        print("REPLAY-STORE-CITATIONS-COMPLETE judged=0 refused=0 blind=0")
        return 3
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return 0 if rows else 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
