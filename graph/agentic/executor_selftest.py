"""executor_selftest.py - the Executor's tool boundary (backlog E11 + E18, 2026-09-06).

    python graph/agentic/executor_selftest.py --selftest

WHY THIS FILE EXISTS AT ALL. graph\\agentic was covered by NOTHING - it is not in run-gates' static
list, it has no -SelfTest, and no other suite imports it. So the executor that shells out on a plan's
tool string had no test of any kind, and the validation added today would have had none either.

WHAT IT GUARDS. `_run_tool` used to do os.path.join(REPO_ROOT, step.tool) and hand the result to
subprocess.run. os.path.join DISCARDS the left operand when the right is absolute, so an absolute tool
name escapes the repo root entirely; "../.." walks out the same way. The plan-hash check one method up
proves the plan has not been MUTATED and says nothing about whether its values were sane to begin
with - those are different questions and only one of them was being asked.

EXIT: 0 all cases pass, 1 at least one failed. Read the verdict LINE, not the number (backlog E2).
"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "graph", "lib"))

import executor as E                                    # noqa: E402

_fails = []


def T(name, cond, got=""):
    if cond:
        print("  ok    %s" % name)
    else:
        print("  X     %s   got: %s" % (name, got))
        _fails.append(name)


def run():
    print("executor self-test: the tool boundary")

    # ---- MUST FIRE: the four ways a tool string escapes or misbehaves ----------------------------
    ok, _, why = E.validate_tool_path("C:/Windows/System32/evil.ps1", REPO)
    T("MUST FIRE  an ABSOLUTE tool path is refused - os.path.join would discard the repo root and "
      "run it from wherever it points", (not ok) and "ABSOLUTE" in why, why or "accepted")

    ok, _, why = E.validate_tool_path("../../evil.ps1", REPO)
    T("MUST FIRE  a traversal out of the repo is refused, however it is spelled",
      (not ok) and "escapes" in why, why or "accepted")

    ok, _, why = E.validate_tool_path("grocery/does-not-exist.ps1", REPO)
    T("MUST FIRE  a tool that does not exist is refused BEFORE subprocess, not after it fails",
      (not ok) and "does not exist" in why, why or "accepted")

    ok, _, why = E.validate_tool_path("grocery/known-wrong.json", REPO)
    T("MUST FIRE  a real in-repo file that is not a runnable script is refused",
      (not ok) and "runnable" in why, why or "accepted")

    ok, _, why = E.validate_tool_path("", REPO)
    T("MUST FIRE  an empty tool name is refused", (not ok), why or "accepted")

    ok, _, why = E.validate_tool_path("//server/share/x.ps1", REPO)
    T("MUST FIRE  a UNC network path is refused", (not ok), why or "accepted")

    # ---- CLEAN TWINS: the real plan must still run --------------------------------------------
    # These are the literals daily_pipeline_plan() actually uses. If a narrowing ever breaks them the
    # daily chain stops, so they are asserted by name rather than by a generic "some .ps1 works".
    for real in ("grocery/check-ad-cycles.ps1", "grocery/compare-deals.ps1", "grocery/guards.ps1",
                 "graph/agentic/verifier.py", "graph/pipeline/resolve.py"):
        ok, path, why = E.validate_tool_path(real, REPO)
        T("CLEAN TWIN the real plan's %s is accepted" % real, ok, why or "refused")

    ok, path, why = E.validate_tool_path("grocery/guards.ps1", REPO)
    T("an accepted tool resolves to a path INSIDE the repo",
      ok and os.path.normpath(path).startswith(os.path.normpath(REPO) + os.sep), path or why)

    # ---- the refusal is recorded, not silent -----------------------------------------------------
    # A boundary that refuses quietly is a boundary nobody can audit. The result dict must carry the
    # reason and a `refused` marker so the decision log answers "why did the run NOT do that?".
    class _FakeStep(object):
        type = "tool"
        tool = "C:/evil.ps1"
        args = {}
        id = "s1"

    class _FakeEx(E.Executor):
        def __init__(self):                              # noqa: D107
            self.shadow = False

    res = E.Executor._run_tool(_FakeEx(), _FakeStep())
    T("MUST FIRE  a refused tool returns ok=False with the REASON and a refused marker, so the "
      "decision log can answer why the run did not do it",
      (res.get("ok") is False) and res.get("refused") is True and "REFUSED" in str(res.get("error")),
      str(res))

    # SHADOW MODE MUST STILL NOT EXECUTE. It is the default and the whole reason the graph can be
    # proven against the daily chain without touching it; a validation change must not quietly make
    # shadow run something.
    class _ShadowEx(E.Executor):
        def __init__(self):                              # noqa: D107
            self.shadow = True

    res2 = E.Executor._run_tool(_ShadowEx(), _FakeStep())
    T("CLEAN TWIN shadow mode still short-circuits before any validation or execution",
      res2.get("shadow") is True and res2.get("ok") is True, str(res2))

    if _fails:
        print("SELF-TEST FAIL: %d case(s)" % len(_fails))
        return 1
    print("SELF-TEST PASS: 6 refusal shapes, the real plan's 5 tools, in-repo resolution, the "
          "recorded refusal, and shadow mode")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(run())
    print("usage: executor_selftest.py --selftest")
    sys.exit(2)
