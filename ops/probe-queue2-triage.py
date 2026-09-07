r"""Triage I8-I27 by checking each claim against the tree, not against its own write-up.

Every check is falsifiable and prints its evidence. A claim that cannot be settled mechanically is
reported as NEEDS-LOOK rather than assumed true - "I could not check it" and "it is fine" are the two
answers this estate keeps conflating.

I19 is skipped: another session owns it.
"""
import io
import json
import os
import re
import subprocess

REPO = r'C:\Codex\ThriftyCrew'
R = []


def rec(cid, verdict, evidence):
    R.append((cid, verdict, evidence))


def read(p):
    try:
        return io.open(os.path.join(REPO, p), encoding='utf-8-sig').read()
    except OSError:
        return ''


def sh(args, cwd=REPO):
    try:
        p = subprocess.run(args, cwd=cwd, capture_output=True, text=True,
                           encoding='utf-8', errors='replace', timeout=120)
        return p.returncode, (p.stdout or '') + (p.stderr or '')
    except Exception as e:                                     # noqa: BLE001
        return -1, str(e)


# ---------------------------------------------------------------- I8
g = read('ops\\run-gates.ps1')
py_listed = len(re.findall(r"f = '[^']+\.py'", g))
ps_discovered = ('Get-ChildItem' in g and '-SelfTest' in g)
rec('I8', 'VERIFIED' if (py_listed and ps_discovered) else 'NOT VERIFIED',
    '%d Python suite(s) hand-listed; PowerShell self-tests %s discovered'
    % (py_listed, 'ARE' if ps_discovered else 'are NOT'))

# ---------------------------------------------------------------- I9
inits = []
for root, dirs, files in os.walk(REPO):
    if any(x in root for x in ('.venv', 'node_modules', '.git', 'worktrees', 'archive')):
        continue
    if '__init__.py' in files:
        inits.append(os.path.relpath(root, REPO))
pyfiles = 0
for root, dirs, files in os.walk(REPO):
    if any(x in root for x in ('.venv', 'node_modules', '.git', 'worktrees', 'archive')):
        continue
    pyfiles += len([f for f in files if f.endswith('.py')])
syspath = len(re.findall(r'sys\.path\.insert', read('meal-prep\\pipeline\\hunt_lib.py') +
                         read('sidecar\\hardeval.py') + read('sidecar\\matcher_eval.py')))
rec('I9', 'VERIFIED' if not inits else 'PARTLY',
    '%d .py file(s), %d __init__.py; sys.path.insert used %d time(s) in three sampled files'
    % (pyfiles, len(inits), syspath))

# ---------------------------------------------------------------- I10
rc, out = sh(['git', 'log', '--since=90 days ago', '--name-only', '--pretty=format:'])
churn = {}
for line in out.splitlines():
    line = line.strip()
    if line.endswith(('.ps1', '.py')):
        churn[line] = churn.get(line, 0) + 1
sizes = {}
for f in churn:
    fp = os.path.join(REPO, f.replace('/', os.sep))
    if os.path.isfile(fp):
        sizes[f] = os.path.getsize(fp)
top_size = sorted(sizes, key=lambda k: -sizes[k])[:10]
top_churn = sorted(churn, key=lambda k: -churn[k])[:10]
overlap = set(top_size) & set(top_churn)
rec('I10', 'VERIFIED' if len(overlap) >= 3 else 'NOT VERIFIED',
    '%d of the 10 biggest code files are also in the 10 most-changed: %s'
    % (len(overlap), ', '.join(sorted(os.path.basename(x) for x in overlap))[:120]))

# ---------------------------------------------------------------- I11
twin_lines = []
rc, out = sh(['git', 'grep', '-h', '-i', 'CLEAN TWIN', '--', '*.ps1', '*.py'])
for line in out.splitlines():
    twin_lines.append(line.strip())
neg = sum(1 for x in twin_lines if re.search(r'CLEAN TWIN[^\n]{0,90}\b(does not|must not|is not|no[t]? )', x, re.I))
pos = len(twin_lines) - neg
rec('I11', 'NEEDS-LOOK',
    '%d "CLEAN TWIN" line(s): %d phrased as "must NOT fire", %d phrased positively - two readings do coexist'
    % (len(twin_lines), neg, pos))

# ---------------------------------------------------------------- I12
rc, out = sh(['git', 'grep', '-l', '-i', '-E', r'null[_-]?rate|null_pct|pct_null', '--', '*.ps1', '*.py'])
rec('I12', 'VERIFIED' if not out.strip() else 'NOT VERIFIED',
    'files mentioning a null-rate concept: %s' % (out.strip().replace('\n', ', ') or 'NONE'))

# ---------------------------------------------------------------- I13 / I14
hist = []
for p in ('meal-prep/pipeline/catalog-similarity.json', 'sidecar/out/hardeval.json',
          'grocery/out/coverage-ledger-history.jsonl', 'ops/write-seam-baseline.json'):
    if os.path.isfile(os.path.join(REPO, p.replace('/', os.sep))):
        hist.append(p)
cal = read('meal-prep\\pipeline\\harvest_embed.py')
derived = ('percentile' in cal) or ('p90' in cal) or ('ask_floor' in cal)
rec('I13', 'NEEDS-LOOK', 'artefacts keeping history on disk: %s' % (', '.join(hist) or 'none found'))
rec('I14', 'VERIFIED' if derived else 'NOT VERIFIED',
    'harvest_embed.py derives a floor from the data: %s (ask_floor/p90 present: %s)'
    % (derived, 'yes' if derived else 'no'))

# ---------------------------------------------------------------- I15
rc, out = sh(['git', 'grep', '-l', '-E', r'high-water|baseline', '--', 'ops/*.json'])
rec('I15', 'PARTLY' if out.strip() else 'VERIFIED',
    'baseline files that DO pin a count: %s' % (out.strip().replace('\n', ', ') or 'none'))

# ---------------------------------------------------------------- I16
bo = read('grocery\\audit-basis-outliers.ps1') or read('grocery\\flag_outliers.py')
ups = len(re.findall(r'-gt|>', bo))
dns = len(re.findall(r'-lt|<', bo))
rec('I16', 'NEEDS-LOOK', 'outlier rule file read: %s; comparisons up=%d down=%d'
    % ('yes' if bo else 'NO FILE FOUND', ups, dns))

# ---------------------------------------------------------------- I17
bt = read('sidecar\\backtest.py')
exits = re.findall(r'(?m)^\s*(?:sys\.)?exit\(([^)]*)\)', bt)
rets = re.findall(r'(?m)^\s*return\s+(\d+)', bt)
claims_gate = bool(re.search(r'acceptance gate', bt, re.I))
rec('I17', 'VERIFIED' if (claims_gate and set(exits + rets) <= {'0', ''}) else 'NEEDS-LOOK',
    'calls itself an acceptance gate: %s; exit/return codes found: %s'
    % (claims_gate, sorted(set(exits + rets)) or 'none'))

# ---------------------------------------------------------------- I18
sched = read('ops\\scheduled-tasks\\tc-graph-nightly-matching.xml') + \
        read('ops\\scheduled-tasks\\tc-recipe-harvest-crawl.xml')
mentions_eval = ('hardeval' in sched) or ('backtest' in sched)
rc, out = sh(['git', 'grep', '-l', 'hardeval', '--', '*.ps1'])
rec('I18', 'VERIFIED' if not mentions_eval else 'NOT VERIFIED',
    'no scheduled task runs hardeval/backtest: %s; ps1 files referencing hardeval: %s'
    % (not mentions_eval, out.strip().replace('\n', ', ') or 'none'))

# ---------------------------------------------------------------- I20
rc, out = sh(['git', 'grep', '-c', '-i', 'untrusted', '--', 'meal-prep/pipeline/hunt-daemon.py',
              'meal-prep/pipeline/hunt_lib.py', 'sidecar'])
rec('I20', 'NEEDS-LOOK', 'files mentioning "untrusted": %s' % (out.strip().replace('\n', ', ') or 'NONE'))

# ---------------------------------------------------------------- I21
gl = read('lib\\ghost-lib.ps1')
m = re.search(r'\$TC_STAGING[A-Z_]*\s*=\s*(\$[a-z]+|\w+)', gl, re.I)
rec('I21', 'NEEDS-LOOK', 'staging default in ghost-lib: %s' % (m.group(0) if m else 'not found by that name'))

# ---------------------------------------------------------------- I22 / I23
rc, out = sh(['git', 'grep', '-l', '-i', '-E', r'prompt[- ]?injection|injected instruction', '--', '*.ps1', '*.py'])
rec('I23', 'VERIFIED' if not out.strip() else 'NOT VERIFIED',
    'files with an injection fixture or mention: %s' % (out.strip().replace('\n', ', ') or 'NONE'))
rec('I22', 'NEEDS-LOOK', 'depends on what the write-up names as the property; read the item')

# ---------------------------------------------------------------- I24 / I25 / I26
rc, out = sh(['git', 'grep', '-l', '-i', '-E', r'search console|gsc|searchconsole', '--', '*.md', '*.ps1', '*.py', '*.json'])
files = [x for x in out.strip().splitlines() if x]
props = set()
for f in files:
    for mm in re.findall(r'(?i)(sc-domain:[\w.-]+|https?://[\w.-]+/?)', read(f.replace('/', os.sep))):
        props.add(mm.rstrip('/'))
rec('I25', 'NEEDS-LOOK', '%d file(s) mention Search Console; distinct property-ish strings: %s'
    % (len(files), ', '.join(sorted(props))[:150] or 'none'))
bl = read('docs\\seo-backlink-plan.md')
rec('I26', 'VERIFIED' if ('thriftycrew.com' not in bl and bl) else ('NOT VERIFIED' if bl else 'NEEDS-LOOK'),
    'seo-backlink-plan.md exists: %s; mentions thriftycrew.com: %s'
    % (bool(bl), 'thriftycrew.com' in bl))
rc, out = sh(['git', 'grep', '-l', '-i', '-E', r'position|impressions|ctr', '--', 'grocery/*.ps1', 'ops/*.ps1'])
rec('I24', 'VERIFIED' if not out.strip() else 'NEEDS-LOOK',
    'estate scripts tracking search metrics: %s' % (out.strip().replace('\n', ', ') or 'NONE'))

# ---------------------------------------------------------------- I27
ls = read(os.path.join(os.path.expanduser('~'), '.claude', 'skills', 'lesson', 'SKILL.md'))
if not ls:
    ls = ''
    for base in (r'C:\Users\Owner\.claude\skills\lesson\SKILL.md',):
        try:
            ls = io.open(base, encoding='utf-8-sig').read()
        except OSError:
            pass
cites = re.findall(r'\[\[([a-z0-9-]+)\]\]', ls)
memdir = r'C:\Users\Owner\.claude\projects\C--Codex-ThriftyCrew\memory'
missing = [c for c in cites if not os.path.isfile(os.path.join(memdir, c + '.md'))]
rec('I27', 'VERIFIED' if missing else ('NOT VERIFIED' if cites else 'NEEDS-LOOK'),
    '%d citation(s) in lesson/SKILL.md; missing: %s' % (len(cites), ', '.join(missing) or 'none'))

# ---------------------------------------------------------------- report
print('%-5s %-13s %s' % ('ID', 'VERDICT', 'EVIDENCE'))
print('-' * 110)
for cid, v, e in R:
    print('%-5s %-13s %s' % (cid, v, e[:92]))
print('')
print('VERIFIED   = the claim holds against the tree')
print('PARTLY     = the claim holds but overstates, or part of it is already handled')
print('NEEDS-LOOK = not settleable mechanically; read the item before acting')
print('I19 skipped - another session owns it.')
