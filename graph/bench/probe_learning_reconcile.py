"""probe_learning_reconcile.py - what will a checkout's next export do with learning rows landed from another one?

    python graph/bench/probe_learning_reconcile.py --db <COPY of a graph.db> --rev <git rev> [--ids <file>]
    python graph/bench/probe_learning_reconcile.py --bot-sim --main <checkout> --landing <git rev> [--ids <file>]

WHY THIS IS COMMITTED (2026-09-23, design/PLAN-graph-learning-reconcile-2026-09-23.md). Landing a learning verdict
from a worktree asks two questions every time, and a rewritten scratch probe is a second harness however faithful:

  --db       Reconcile plus export, run on a private copy (taken mode=ro) of a COPY of a database against the learning
             JSON at <rev>, into a scratch directory holding <rev>'s five files. It checks: every landed row of the three
             reconciled tables is present and equal in the exported file; every row only the database held is kept; the
             database took every row the JSON differed on and changed no other, which is the expectation when the
             database PREDATES the landing (a row it decided later fails it, correctly kept, and the reconcile counts
             say kept_db_newer); per id (from --ids, one proposal id per line) the status and
             patch rows equal <rev>'s; and a second export is byte-identical with nothing to reconcile. It REFUSES a
             path shaped graph/sqlite/graph.db, so it can never open a checkout's live database.
  --bot-sim  The ~07:00 bot's two git steps over the real blobs, read-only against <checkout>: capture-run's
             `rebase -X theirs` replays the checkout's commits not in <rev> onto <rev> (`git merge-file --theirs` per
             commit), then rebase.autoStash re-applies its working copy (`git merge-file`). It prints the statuses and
             patch rows of the ids at each step, and how many conflicts -X theirs decided.

Writes only a temp directory it removes, and never the checkout it reads (git runs with --no-optional-locks).
Exit 0 every check held, 1 a check failed, 3 could not evaluate. Read the verdict line.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import graphdb                                            # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
RECONCILED = {"learning_proposals": "learning/proposals.json", "approved_patches": "learning/approved-patches.json",
              "eval_runs": "eval/eval-runs.json"}


def git_show(rev: str, rel: str, repo: str = REPO) -> bytes:
    r = subprocess.run(["git", "--no-optional-locks", "-C", repo, "show", f"{rev}:graph/{rel}"], capture_output=True)
    if r.returncode != 0:
        raise SystemExit(f"PROBE-LEARNING-RECONCILE could not evaluate: git show {rev}:graph/{rel} failed")
    return r.stdout


def rows_of(raw: bytes) -> dict:
    return {r["id"]: r for r in json.loads(raw.decode("utf-8-sig"))}


def db_rows(g, table: str) -> dict:
    return {r["id"]: dict(r) for r in g.conn.execute(f"SELECT * FROM {table}")}


def readb(path: str) -> bytes:
    with open(path, "rb") as fh:
        return fh.read()


def read_ids(path: str | None) -> list:
    if not path:
        return []
    with open(path, encoding="utf-8-sig") as fh:
        return [ln.strip() for ln in fh if ln.strip()]


def probe_db(a) -> int:
    parts = os.path.normcase(os.path.abspath(a.db)).split(os.sep)
    if parts[-3:] == ["graph", "sqlite", "graph.db"]:
        print(f"PROBE-LEARNING-RECONCILE refused: {a.db} is shaped like a live graph.db; copy it and pass the copy")
        return 3
    if not os.path.exists(a.db):
        print(f"PROBE-LEARNING-RECONCILE could not evaluate: no database at {a.db}")
        return 3
    ids = read_ids(a.ids)
    root = tempfile.mkdtemp(prefix="plr-")
    out = os.path.join(root, "graph")
    work = os.path.join(root, "work.db")
    fails = []

    def check(label, ok, got=""):
        print(("  ok    " if ok else "  FAIL  ") + label + ("" if ok else f"   got: {got}"))
        if not ok:
            fails.append(label)

    try:
        landed = {}
        for _, rel in graphdb.GraphDB.LEARNING_TABLES:
            raw = git_show(a.rev, rel)
            os.makedirs(os.path.dirname(os.path.join(out, rel)), exist_ok=True)
            with open(os.path.join(out, rel), "wb") as fh:
                fh.write(raw)
            landed[rel] = raw
        # Work on a private copy of the copy, taken read-only, so a rerun starts from the same bytes.
        import sqlite3                                                     # noqa: PLC0415
        src = sqlite3.connect(f"file:{os.path.abspath(a.db).replace(os.sep, '/')}?mode=ro", uri=True)
        dst = sqlite3.connect(work)
        src.backup(dst)
        dst.close()
        src.close()
        g = graphdb.GraphDB(work, restore_learning=False)
        before = {t: db_rows(g, t) for t in RECONCILED}
        tr = {t: rows_of(landed[rel]) for t, rel in RECONCILED.items()}
        for t in RECONCILED:
            b, x = before[t], tr[t]
            diff = sum(1 for i in set(b) & set(x) if b[i] != {k: x[i].get(k) for k in b[i]})
            print(f"  before  {t:<19} db={len(b)} tracked={len(x)} only-db={len(set(b) - set(x))} "
                  f"only-tracked={len(set(x) - set(b))} differ={diff}")

        g.export_learning(out_dir=out)
        rep = g.last_reconcile
        print("  reconcile: " + json.dumps({k: v for k, v in rep.items() if k not in ("ids", "read")}))
        after = {t: db_rows(g, t) for t in RECONCILED}
        exported = {t: rows_of(readb(os.path.join(out, rel))) for t, rel in RECONCILED.items()}

        for t in RECONCILED:
            x, e, b, n = tr[t], exported[t], before[t], after[t]
            missing = [i for i in x if i not in e]
            unequal = [i for i in x if i in e and any(e[i].get(k) != v for k, v in x[i].items())]
            check(f"{t}: every landed row ({len(x)}) is present and equal in the exported file",
                  not missing and not unequal, f"missing={len(missing)} unequal={len(unequal)} e.g. {(missing + unequal)[:3]}")
            dropped = [i for i in b if i not in e]
            check(f"{t}: every row only the database held ({len(set(b) - set(x))}) is kept", not dropped,
                  f"dropped={dropped[:3]}")
            moved = {i for i in n if i not in b or n[i] != b[i]}
            explained = {i for i in x if i not in b or b[i] != {k: x[i].get(k) for k in b[i]}}
            check(f"{t}: the database took all {len(explained)} row(s) the JSON differed on and changed no other",
                  moved == explained, f"moved={len(moved)} explained={len(explained)} "
                  f"unexplained={sorted(moved - explained)[:3]} unmoved={sorted(explained - moved)[:3]}")

        if ids:
            want = tr["learning_proposals"]
            got_st = Counter(after["learning_proposals"].get(i, {}).get("status") for i in ids)
            ok_st = [i for i in ids if i in want and after["learning_proposals"].get(i, {}).get("status") == want[i]["status"]]
            check(f"per id: {len(ok_st)} of {len(ids)} statuses equal the landed JSON {dict(got_st)}",
                  len(ok_st) == len(ids), f"{len(ids) - len(ok_st)} differ")
            by_pid_after = Counter(r["proposal_id"] for r in after["approved_patches"].values())
            by_pid_want = Counter(r["proposal_id"] for r in tr["approved_patches"].values())
            ok_ap = [i for i in ids if by_pid_after[i] == by_pid_want[i] and by_pid_want[i] >= 1]
            verdicts = Counter(r["verdict"] for r in after["approved_patches"].values() if r["proposal_id"] in set(ids))
            reviewers = Counter(r["reviewer"] for r in after["approved_patches"].values() if r["proposal_id"] in set(ids))
            check(f"per id: {len(ok_ap)} of {len(ids)} have their landed patch row(s) {dict(verdicts)} "
                  f"reviewer {dict(reviewers)}", len(ok_ap) == len(ids), f"{len(ids) - len(ok_ap)} short")
            from learning_reconcile import VERDICT_STATUS                  # noqa: PLC0415
            agree = [i for i in ids if any(VERDICT_STATUS.get(r["verdict"]) == after["learning_proposals"].get(i, {}).get("status")
                                           for r in after["approved_patches"].values() if r["proposal_id"] == i)]
            check(f"per id: {len(agree)} of {len(ids)} statuses are the status their own patch verdict names",
                  len(agree) == len(ids), f"{len(ids) - len(agree)} disagree")

        first = {rel: readb(os.path.join(out, rel)) for _, rel in graphdb.GraphDB.LEARNING_TABLES}
        g.export_learning(out_dir=out)
        second = {rel: readb(os.path.join(out, rel)) for _, rel in graphdb.GraphDB.LEARNING_TABLES}
        from learning_reconcile import noteworthy                          # noqa: PLC0415
        check("a second export is byte-identical on all 5 files and has nothing to reconcile",
              first == second and noteworthy(g.last_reconcile) == 0,
              f"identical={first == second} noteworthy={noteworthy(g.last_reconcile)}")
        g.conn.rollback()
        g.conn.close()
    finally:
        shutil.rmtree(root, ignore_errors=True)
    verdict = "fail" if fails else "pass"
    print(f"PROBE-LEARNING-RECONCILE-COMPLETE mode=db rev={a.rev} checks_failed={len(fails)} verdict={verdict}")
    return 1 if fails else 0


def bot_sim(a) -> int:
    main = a.main
    # Resolve the landing HERE: a symbolic rev ('HEAD', a branch) passed to the other checkout would name ITS commit.
    sha = subprocess.run(["git", "--no-optional-locks", "-C", REPO, "rev-parse", "--verify", a.landing + "^{commit}"],
                         capture_output=True, text=True).stdout.strip()
    if not sha:
        print(f"PROBE-LEARNING-RECONCILE could not evaluate: {a.landing} does not resolve here")
        return 3
    a.landing = sha
    head = subprocess.run(["git", "--no-optional-locks", "-C", main, "rev-parse", "HEAD"], capture_output=True,
                          text=True).stdout.strip()
    local = subprocess.run(["git", "--no-optional-locks", "-C", main, "rev-list", "--reverse", f"{a.landing}..{head}"],
                           capture_output=True, text=True).stdout.split()
    print(f"  main HEAD {head[:9]}; commits the rebase replays onto {a.landing}: {[c[:9] for c in local]}")
    ids = read_ids(a.ids)
    land = rows_of(git_show(a.landing, RECONCILED["learning_proposals"]))
    if not ids:
        mine = rows_of(git_show(head, RECONCILED["learning_proposals"], main))
        ids = [i for i in land if i in mine and land[i]["status"] != mine[i]["status"]]
    S = set(ids)
    tmp = tempfile.mkdtemp(prefix="plr-bot-")

    def say(raw: bytes, rel: str) -> str:
        try:
            rows = json.loads(raw.decode("utf-8-sig"))
        except ValueError:
            return "UNPARSEABLE"
        if rel.endswith("proposals.json"):
            by = {r["id"]: r for r in rows}
            return str(dict(Counter(by[i]["status"] if i in by else "ABSENT" for i in ids)))
        return f"{sum(1 for r in rows if r.get('proposal_id') in S)} patch row(s)"

    def merge(cur: bytes, base: bytes, other: bytes, theirs: bool) -> tuple[bytes, int]:
        paths = []
        for n, b in (("cur", cur), ("base", base), ("other", other)):
            p = os.path.join(tmp, n)
            with open(p, "wb") as fh:
                fh.write(b)
            paths.append(p)
        r = subprocess.run(["git", "merge-file", "-p"] + (["--theirs"] if theirs else []) + paths, capture_output=True)
        return r.stdout, r.returncode

    try:
        for rel in (RECONCILED["learning_proposals"], RECONCILED["approved_patches"]):
            cur = git_show(a.landing, rel)
            print(f"== graph/{rel}   ids followed: {len(ids)}")
            print(f"   landing            : {say(cur, rel)}")
            decided = 0
            for c in local:
                base, mine = git_show(c + "^", rel, main), git_show(c, rel, main)
                _, n = merge(cur, base, mine, theirs=False)
                cur, _ = merge(cur, base, mine, theirs=True)
                decided += n
            print(f"   A rebase -X theirs : {decided} conflict(s) decided for the local side -> {say(cur, rel)}")
            with open(os.path.join(main, "graph", rel), "rb") as fh:
                work = fh.read()
            res, left = merge(cur, git_show(head, rel, main), work, theirs=False)
            print(f"   B autostash apply  : {left} conflict(s) left in the file -> {say(res, rel)}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"PROBE-LEARNING-RECONCILE-COMPLETE mode=bot-sim landing={a.landing} replayed={len(local)}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--db")
    ap.add_argument("--rev")
    ap.add_argument("--ids")
    ap.add_argument("--bot-sim", action="store_true")
    ap.add_argument("--main")
    ap.add_argument("--landing")
    a = ap.parse_args()
    if a.bot_sim and a.main and a.landing:
        return bot_sim(a)
    if a.db and a.rev:
        return probe_db(a)
    ap.print_help()
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
