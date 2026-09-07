r"""Audit the guards as a class, with the questions that found this session's five defects.

Three of those questions are already gated and are NOT re-asked here:
  * does anything run it            -> grocery/audit-script-census.ps1 (caught my own orphan yesterday)
  * can it prove it ran to the end  -> grocery/audit-guard-contract.ps1
  * has it lost a must-fire         -> ops/audit-mustfire-census.ps1

The three nobody watches:
  Q1 CAN IT FAIL AT ALL?       backtest.py called itself an ACCEPTANCE GATE, said in its own header
                               that it was allowed to fail, and contained no non-zero exit anywhere.
  Q2 CAN IT LOCK IN ITS OWN    four ratchets lowered a high-water baseline unconditionally, so a
     BLINDNESS?                detector that broke and found nothing recorded 0 as a permanent
                               ceiling and printed a pass forever after.
  Q3 DOES IT REPORT A          "3 findings" is a clean board and a catastrophe depending on whether
     DENOMINATOR?              3,164 rows were scanned or 4.

THE FIRST VERSION OF Q1 WAS WRONG AND FLAGGED 42 DETECTORS THAT CAN FAIL PERFECTLY WELL, including
audit-guard-contract.ps1 itself. It only looked for `exit 2` at the start of a line and missed
`exit $(if (...) { 1 } else { 0 })`, which is this estate's most common idiom. A negative result has to
prove itself; that one did not, and it is exactly the false alarm this file exists to avoid raising.
"""
import io
import os
import re

REPO = r'C:\Codex\ThriftyCrew'
SKIP = ('\\archive\\', '\\.venv\\', '\\worktrees\\', '\\node_modules\\', '\\out\\', '\\one-off\\')

# A non-zero exit path in ANY shape this estate actually writes.
FAIL_RX = (
    r'(?<![\w$])exit\s+[1-9]',
    r'exit\s+\$\(',
    r'exit\s+\$\w+',
    r'sys\.exit\(\s*[1-9]',
    r'sys\.exit\(\s*\w+',
    r'(?<![\w$])return\s+[1-9]',
    r'exit\(\s*[1-9]',
)

DETECTORS = []
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
        DETECTORS.append(os.path.join(root, f))

print('detectors examined: %d' % len(DETECTORS))
print('')

q1, q2, q3 = [], [], []
for p in sorted(DETECTORS):
    rel = os.path.relpath(p, REPO)
    try:
        t = io.open(p, encoding='utf-8-sig', errors='replace').read()
    except OSError:
        continue
    body = '\n'.join(l for l in t.splitlines() if not l.strip().startswith('#'))

    if not any(re.search(rx, body) for rx in FAIL_RX):
        q1.append(rel)

    lowers = re.search(r'-lt\s+\$(base|baseline|prev)', body)
    if lowers and 'ratchet.ps1' not in t and 'Test-RatchetMove' not in t:
        q2.append(rel)

    sums = re.findall(r'Write-GuardComplete[^\n]*-Summary\s+([^\n]+)', body)
    if sums:
        denom = r'(scanned|examined|rows|total|checked|pairs|tasks|present|stores|sites|files|count|cases|of)\s*='
        if not any(re.search(denom, s, re.I) for s in sums):
            q3.append(rel)


def show(name, rows, why, cap=16):
    print('=' * 78)
    print('%s  -  %d of %d detector(s)' % (name, len(rows), len(DETECTORS)))
    print('  %s' % why)
    for r in rows[:cap]:
        print('    %s' % r)
    if len(rows) > cap:
        print('    ... and %d more' % (len(rows) - cap))


show('Q1  CANNOT FAIL', q1, 'no non-zero exit path in any shape - it can only ever report a pass')
show('Q2  CAN LOCK IN ITS BLINDNESS', q2, 'lowers a baseline with no plausibility guard (the I15 shape)')
show('Q3  NO DENOMINATOR', q3, 'its COMPLETE summary carries a finding count with no population')
