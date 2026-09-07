r"""Of the detectors that cannot fail, which ones CLAIM to gate?

"Cannot fail" is not a defect on its own. aisle.py is marked ADVISORY, AND BLIND-NEVER-BLOCK on
purpose, probe-* files are diagnostics, and a report that always exits 0 is fine when it says so. The
I17 defect was narrower and sharper: backtest.py opened by calling itself "the ACCEPTANCE GATE",
said in the next paragraph that it was "allowed to fail", and contained no non-zero exit at all.

So the finding is the CONTRADICTION, not the exit code. This lists only the files whose own words
claim to gate, refuse, block or fail while having no way to do it.
"""
import io
import os
import re

REPO = r'C:\Codex\ThriftyCrew'
SKIP = ('\\archive\\', '\\.venv\\', '\\worktrees\\', '\\node_modules\\', '\\out\\', '\\one-off\\')

FAIL_RX = (r'(?<![\w$])exit\s+[1-9]', r'exit\s+\$\(', r'exit\s+\$\w+',
           r'sys\.exit\(\s*[1-9]', r'sys\.exit\(\s*\w+', r'(?<![\w$])return\s+[1-9]', r'exit\(\s*[1-9]')

# Words a file uses about ITSELF when it believes it stops things.
CLAIM_RX = r'(?i)\b(acceptance gate|is a gate|the gate|hard[- ]fail|must fail|blocks?\b|refuses?\b|rejects?\b|will fail|fails the|allowed to fail)'

# Words that say the opposite, out loud. A file that declares itself advisory is not contradicting
# anything by exiting 0, and counting it would be the false alarm this whole pass exists to avoid.
ADVISORY_RX = r'(?i)(advisory|never block|blind-never-block|report only|does not block|diagnostic|reports? and stops|no verdict)'

rows = []
for root, dirs, files in os.walk(REPO):
    low = (root + '\\').lower()
    if any(s in low for s in SKIP):
        continue
    for f in files:
        if not (f.endswith('.ps1') or f.endswith('.py')):
            continue
        if f.endswith('-lib.ps1'):
            continue
        if not (f.startswith('audit-') or f.startswith('audit_') or 'selftest' in f.lower()
                or f.endswith('-test.ps1') or f.startswith('probe-') or f.startswith('verify-')):
            continue
        p = os.path.join(root, f)
        try:
            t = io.open(p, encoding='utf-8-sig', errors='replace').read()
        except OSError:
            continue
        body = '\n'.join(l for l in t.splitlines() if not l.strip().startswith('#'))
        if any(re.search(rx, body) for rx in FAIL_RX):
            continue                                    # it can fail; nothing to say
        header = t[:4000]
        claims = re.findall(CLAIM_RX, header)
        if not claims:
            continue
        if re.search(ADVISORY_RX, header):
            continue                                    # it says it is advisory - consistent
        rows.append((os.path.relpath(p, REPO), sorted(set(c.lower() for c in claims))[:4]))

print('detectors that CANNOT FAIL but CLAIM to gate: %d' % len(rows))
print('')
for rel, claims in rows:
    print('  %-52s claims: %s' % (rel, ', '.join(claims)))
if not rows:
    print('  none - every detector that cannot fail either says it is advisory or makes no gate claim.')
    print('  I17 (backtest.py) was the only instance and it is fixed.')
