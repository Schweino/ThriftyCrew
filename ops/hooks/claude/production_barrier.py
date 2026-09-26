#!/usr/bin/env python3
"""production_barrier.py - a Claude Code PreToolUse hook: WARN when a session writes into the production checkout.

WHY (design/PLAN-bot-dedicated-checkout-2026-09-25.md W1.1, Brad's ruling D3 (a) of 2026-09-25). Under design D the
main checkout, C:\\Codex\\ThriftyCrew, is the PRODUCTION checkout, written only by scheduled jobs; every interactive
session works in a linked worktree under C:\\Codex\\ThriftyCrew\\.claude\\worktrees\\. Every measured stall of the bot
between 09-19 and 09-25 came through a session's file in that checkout (section 2.4: 7 stall events in 7 days). A
rule in a file is not a block; this hook is the first half of the block.

STAGE 1: WARN ONLY. It never refuses, never blocks, and exits 0 on every path, including a malformed payload and its
own crash. For a Write, Edit, MultiEdit or NotebookEdit it resolves the target path; for a Bash or PowerShell command
it reads the redirection and file-writing targets it can parse (`>`, `>>`, Out-File, Set-Content, Add-Content,
Tee-Object, [IO.File]::Write*/Append*, Copy-Item/Move-Item -Destination). A target inside the production root and
outside .claude\\worktrees\\ is a WARNING: one row per write in
%LOCALAPPDATA%\\ThriftyCrew\\production-barrier\\writes-<date>.jsonl, and a one-line note into the session's context
the FIRST time in that session (so a long session is not nagged every edit). W2.1 turns it into a refusal a week
later; `.git\\tc-production-barrier.disabled` will then put it back to this mode.

SCOPE OF A CLEAN REPORT. Unsound: a shell write it cannot parse (a variable path, a script that writes on its own, a
process that is not a Claude session, such as Brad at a terminal) is not seen. A warning is a candidate, not a
verdict: a scheduled Claude task writing its own output into production is expected and is recorded like any other,
so the week's rows are read, never counted blind.

Installed into ~/.claude/settings.json by procedure P1 of design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md
section 4.4, through a launcher that exits 0 when this file is absent, so a checkout without it degrades to today.
Self-test: C:/Codex/Python312/python.exe ops/hooks/claude/production_barrier.py --selftest
"""
# Self-test: a temp log dir and a child run of this file with its own env; it reads no committed file but this one.
# gate-inputs: ops\hooks\claude\production_barrier.py
import datetime as dt
import json
import os
import re
import sys

DEFAULT_ROOT = r"C:\Codex\ThriftyCrew"
WRITE_TOOLS = {"Write": "file_path", "Edit": "file_path", "MultiEdit": "file_path", "NotebookEdit": "notebook_path"}
SHELL_TOOLS = ("Bash", "PowerShell")
QUOTED = r"""(?:"([^"]+)"|'([^']+)'|([^\s;|&()<>'"]+))"""
SHELL_PATTERNS = [
    re.compile(r"(?<![<>&\w=-])\d?>{1,2}(?!&)\s*" + QUOTED),
    re.compile(r"(?i)\b(?:Out-File|Set-Content|Add-Content|Tee-Object)\b(?:\s+-(?:FilePath|LiteralPath|Path))?\s+" + QUOTED),
    re.compile(r"(?i)\b(?:Out-File|Set-Content|Add-Content|Tee-Object|Copy-Item|Move-Item|New-Item)\b[^;|\n]*?-(?:FilePath|LiteralPath|Path|Destination)\s+" + QUOTED),
    re.compile(r"(?i)\[(?:System\.)?IO\.File\]::(?:WriteAll\w*|AppendAll\w*)\(\s*" + QUOTED),
]


def norm(path, cwd):
    """An absolute, normalised Windows path for a target, or '' when it cannot be resolved (a variable, a device)."""
    p = (path or "").strip().strip('"').strip("'")
    if not p or "$" in p or "%" in p or p.startswith("-") or p.lower() in ("nul", "/dev/null", "$null"):
        return ""
    m = re.match(r"^/([a-zA-Z])/(.*)$", p)
    if m:
        p = m.group(1).upper() + ":\\" + m.group(2)
    p = p.replace("/", "\\")
    if not re.match(r"^[a-zA-Z]:\\", p):
        base = (cwd or "").replace("/", "\\")
        mb = re.match(r"^\\([a-zA-Z])\\(.*)$", base)
        if mb:
            base = mb.group(1).upper() + ":\\" + mb.group(2)
        if not re.match(r"^[a-zA-Z]:\\", base):
            return ""
        p = os.path.join(base, p)
    return os.path.normpath(p)


def in_production(target, root):
    """Inside the production root and not inside its linked worktrees. The boundary is the separator."""
    t, r = target.lower().rstrip("\\"), os.path.normpath(root).lower().rstrip("\\")
    if not (t == r or t.startswith(r + "\\")):
        return False
    return not (t + "\\").startswith(r + "\\.claude\\worktrees\\")


def targets_of(payload):
    tool = payload.get("tool_name") or ""
    ti = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or ""
    out = []
    if tool in WRITE_TOOLS:
        out.append(ti.get(WRITE_TOOLS[tool]) or "")
    elif tool in SHELL_TOOLS:
        cmd = ti.get("command") or ""
        for rx in SHELL_PATTERNS:
            for m in rx.finditer(cmd):
                out.append(next(g for g in m.groups()[-3:] if g is not None))
    seen, res = set(), []
    for t in out:
        n = norm(t, cwd)
        if n and n.lower() not in seen:
            seen.add(n.lower())
            res.append(n)
    return tool, res


def decide(payload, root, logdir, now=None):
    """The warnings for one tool call: (rows written, context text or ''). Never raises past the caller's guard."""
    tool, targets = targets_of(payload)
    hits = [t for t in targets if in_production(t, root)]
    if not hits:
        return [], ""
    now = now or dt.datetime.now()
    sid = re.sub(r"[^A-Za-z0-9_-]", "_", str(payload.get("session_id") or "unknown"))[:80]
    os.makedirs(logdir, exist_ok=True)
    rows = []
    with open(os.path.join(logdir, "writes-%s.jsonl" % now.strftime("%Y-%m-%d")), "a", encoding="utf-8", newline="\n") as f:
        for t in hits:
            row = {"ts": now.isoformat(timespec="seconds"), "mode": "warn", "tool": tool, "target": t,
                   "cwd": payload.get("cwd") or "", "session_id": sid}
            f.write(json.dumps(row, sort_keys=True) + "\n")
            rows.append(row)
    marker_dir = os.path.join(logdir, "warned")
    os.makedirs(marker_dir, exist_ok=True)
    marker = os.path.join(marker_dir, sid)
    if os.path.exists(marker):
        return rows, ""
    with open(marker, "w", encoding="utf-8") as f:
        f.write(now.isoformat(timespec="seconds") + "\n")
    text = ("production-barrier WARN, nothing was refused (design/PLAN-bot-dedicated-checkout-2026-09-25.md W1.1): "
            + hits[0] + " is inside the production checkout " + root + ", which only scheduled jobs should write. "
            "An interactive session works in a linked worktree under " + root + "\\.claude\\worktrees\\<name> and lands "
            "with ops\\push-main.ps1. A scheduled task writing its own output: carry on. Shown once per session; "
            "every such write is recorded.")
    return rows, text


def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
        root = os.environ.get("TC_PRODUCTION_ROOT") or DEFAULT_ROOT
        logdir = os.environ.get("TC_PRODUCTION_BARRIER_LOG") or os.path.join(
            os.environ.get("LOCALAPPDATA", os.path.expanduser("~")), "ThriftyCrew", "production-barrier")
        _, text = decide(payload, root, logdir)
        if text:
            sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": text}}))
    except Exception:
        pass   # WARN mode: a hook that cannot judge says nothing and never blocks the tool call
    return 0


def selftest():
    import shutil
    import subprocess
    import tempfile
    cases = []

    def T(label, cond, got=""):
        cases.append(bool(cond))
        print(("  PASS  " if cond else "  FAIL  ") + label + ("" if cond else "  got: " + repr(got)))

    root = r"C:\Codex\ThriftyCrew"
    wt = root + r"\.claude\worktrees\agent-x"
    tmp = tempfile.mkdtemp(prefix="pbar-")
    try:
        log = os.path.join(tmp, "log")
        w = lambda path, cwd=wt, sid="s1": {"tool_name": "Write", "tool_input": {"file_path": path}, "cwd": cwd, "session_id": sid}
        sh = lambda tool, cmd, cwd=wt, sid="s1": {"tool_name": tool, "tool_input": {"command": cmd}, "cwd": cwd, "session_id": sid}
        rows, text = decide(w(root + r"\lib\x.ps1"), root, log)
        T("MUST FIRE: a Write to C:\\Codex\\ThriftyCrew\\lib\\x.ps1 warns, with a row and a context note",
          len(rows) == 1 and "production-barrier WARN" in text and rows[0]["target"].lower() == (root + r"\lib\x.ps1").lower(), (rows, text))
        rows2, text2 = decide(w(root + r"\lib\y.ps1"), root, log)
        T("CLEAN TWIN: the second write in the same session is still recorded, and the note is not repeated",
          len(rows2) == 1 and text2 == "", (rows2, text2))
        T("MUST NOT FIRE: a Write inside .claude\\worktrees\\<name>\\ is not a production write",
          decide(w(wt + r"\lib\x.ps1"), root, log) == ([], ""))
        T("MUST NOT FIRE: a relative path from a worktree resolves to the worktree, not to production",
          decide(w(r"lib\x.ps1", cwd=wt), root, log) == ([], ""))
        r3, _ = decide(w("lib/x.ps1", cwd=root, sid="s2"), root, log)
        T("MUST FIRE: the same relative path from the main checkout resolves into production", len(r3) == 1, r3)
        r4, _ = decide(sh("Bash", "echo x > /c/Codex/ThriftyCrew/grocery/notes.txt", sid="s3"), root, log)
        T("MUST FIRE: a Bash redirection into /c/Codex/ThriftyCrew warns", len(r4) == 1 and r4[0]["target"].lower().endswith(r"grocery\notes.txt"), r4)
        r5, _ = decide(sh("PowerShell", "Set-Content -Path C:\\Codex\\ThriftyCrew\\a.txt -Value 1; 'x' | Out-File 'C:/Codex/ThriftyCrew/b.txt'", sid="s4"), root, log)
        T("MUST FIRE: Set-Content -Path and Out-File into production are both read", len(r5) == 2, r5)
        r6, _ = decide(sh("PowerShell", "[IO.File]::WriteAllText('C:\\Codex\\ThriftyCrew\\c.txt', $t)", sid="s5"), root, log)
        T("MUST FIRE: [IO.File]::WriteAllText into production is read", len(r6) == 1, r6)
        T("MUST NOT FIRE: 2>&1, > $null and > /dev/null are not file writes",
          decide(sh("Bash", "git status 2>&1; x > /dev/null; y 2>$null", cwd=root), root, log) == ([], ""))
        T("MUST NOT FIRE: a sibling directory whose name only starts with the root is not production",
          decide(w(r"C:\Codex\ThriftyCrewX\a.txt"), root, log) == ([], ""))
        T("MUST NOT FIRE: a Read is never a write",
          decide({"tool_name": "Read", "tool_input": {"file_path": root + r"\lib\x.ps1"}, "cwd": root}, root, log) == ([], ""))
        T("MUST NOT FIRE: a variable path cannot be resolved and is left alone (the hook is unsound, and says so)",
          decide(sh("PowerShell", "Set-Content -Path $p -Value 1", cwd=root), root, log) == ([], ""))
        lines = open(os.path.join(log, "writes-%s.jsonl" % dt.datetime.now().strftime("%Y-%m-%d")), encoding="utf-8").read().splitlines()
        T("CLEAN TWIN: every warning is one parseable row (7 so far)", len(lines) == 7 and all(json.loads(l)["mode"] == "warn" for l in lines), len(lines))
        env = dict(os.environ, TC_PRODUCTION_ROOT=root, TC_PRODUCTION_BARRIER_LOG=os.path.join(tmp, "log2"))
        pr = subprocess.run([sys.executable, os.path.abspath(__file__)], input=json.dumps(w(root + r"\z.txt", sid="s9")),
                            capture_output=True, text=True, env=env)
        ok = pr.returncode == 0
        try:
            ok = ok and "production-barrier WARN" in json.loads(pr.stdout)["hookSpecificOutput"]["additionalContext"]
        except (ValueError, KeyError, TypeError):
            ok = False
        T("MUST FIRE: run as a hook, it exits 0 and emits additionalContext JSON, never a block", ok, (pr.returncode, pr.stdout[:200]))
        pb = subprocess.run([sys.executable, os.path.abspath(__file__)], input="{not json", capture_output=True, text=True, env=env)
        T("MUST NOT FIRE: a malformed payload exits 0 and prints nothing", pb.returncode == 0 and pb.stdout == "", (pb.returncode, pb.stdout))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    want = 15
    if len(cases) != want:
        print("PRODUCTION-BARRIER SELF-TEST FAIL: ran %d cases, the literal list holds %d" % (len(cases), want))
        return 1
    bad = cases.count(False)
    if bad:
        print("PRODUCTION-BARRIER SELF-TEST FAIL (%d of %d cases failed)" % (bad, len(cases)))
        return 1
    print("PRODUCTION-BARRIER SELF-TEST PASS (%d of %d cases)" % (len(cases), len(cases)))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(main())
