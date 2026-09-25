"""test_member_token.py - runs worker/member-token.selftest.mjs and worker/index.selftest.mjs so run-gates discovers it.

    python worker/test_member_token.py --selftest

run-gates discovers Python suites by their --selftest flag and never runs a .mjs, so the Worker's member
token check (the fix for /alert telling strangers who pays, 2026-09-18) would otherwise go ungated. Node is
not on PATH on this box (workspace CLAUDE.md); it lives beside the Python runtime. No node is COULD NOT
EVALUATE (exit 3), never a pass. The child's own verdict line must be its last, and is echoed as ours.
"""
import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def find_node():
    for cand in sorted(glob.glob(r"C:\Codex\node-v*\node.exe"), reverse=True):
        if os.path.isfile(cand):
            return cand
    return None


def main():
    if "--selftest" not in sys.argv:
        print(__doc__)
        return 0
    node = find_node()
    if not node:
        print("member-token self-test: BLIND - no node.exe under C:\\Codex\\node-v*, nothing ran")
        return 3
    bad = 0
    suites = (("member-token.selftest.mjs", "member-token self-test: pass"),
              ("index.selftest.mjs", "worker-routes self-test: pass"),
              # 2026-09-25: the off-box boot page (Q4-tasks-dead-after-reboot, grocery/triage-plans/plan-2026-09-18.json).
              ("box-heartbeat.selftest.mjs", "box-heartbeat self-test: pass"))
    for suite, verdict in suites:
        r = subprocess.run([node, os.path.join(HERE, suite)], capture_output=True, text=True, cwd=HERE)
        lines = [l for l in (r.stdout or "").splitlines() if l.strip()]
        last = lines[-1] if lines else ""
        for l in lines:
            print("  " + l)
        if not (r.returncode == 0 and last.startswith(verdict)):
            bad += 1
            print("  " + (r.stderr or "").strip()[-2000:])
            print("  %s did not pass (node exit %d)" % (suite, r.returncode))
    print("member-token self-test: %s (suites=%d failed=%d)" % ("pass" if not bad else "FAIL", len(suites), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
