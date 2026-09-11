# analyze_observer.py - reads observe2.jsonl (observe-gate-runs.ps1 v2) and prints, for REAL runs only:
# arrivals, how long each waited for its first worker, how long it held workers, max width, exit code, and
# orphans. A wrapper (a Claude tool shell whose command line names -File run-gates.ps1 and whose child is the
# real run) is dropped, and so is a test-prepush-hook sandbox stub (its path is under tc-prepush-selftest-).
# A run already live when the observer started has an unknown wait, so waits are reported only for runs
# CREATED after the first poll. Holds are reported only for runs whose first worker appeared after the first
# poll and that exited before the last poll.
import json, sys, datetime, collections, statistics

ev = []
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    line = line.strip()
    if line:
        try:
            ev.append(json.loads(line))
        except Exception:
            pass

def t(s):
    return datetime.datetime.fromisoformat(s[:26])

start = t(next(e['t'] for e in ev if e['ev'] == 'start'))
polls = [e for e in ev if e['ev'] == 'poll']
first_poll = t(polls[0]['t']); last_poll = t(polls[-1]['t'])
new = {e['key']: e for e in ev if e['ev'] == 'new'}
pid_key = {e['pid']: k for k, e in new.items()}
stub = {k for k, e in new.items() if 'tc-prepush-selftest-' in e.get('cmd', '')}
# A WRAPPER is a Claude tool shell whose command line names -File run-gates.ps1 and whose child is the
# REAL run. A gate worker running ops/test-prepush-hook.ps1 also has a child matching the root rule - the
# sandbox STUB - and the first version of this test called that worker's run a wrapper and dropped its
# workers from the occupancy sum. That read 7.36 of 10 mean occupancy while a direct probe of the slot
# mutexes found 0 free and 10 workers at 20 of 20 samples: a number that moved because the TOOL was
# wrong. A stub child never makes its parent a wrapper.
wrapper = set(); first_child = {}
for e in ev:
    if e['ev'] != 'child':
        continue
    if e['cpid'] in pid_key and pid_key[e['cpid']] in new and pid_key[e['cpid']] not in stub:
        wrapper.add(e['key']); continue
    first_child.setdefault(e['key'], t(e['created']))
real = [k for k in new if k not in wrapper and k not in stub]
exits = {e['key']: e for e in ev if e['ev'] == 'exit'}
orph = {e['key'] for e in ev if e['ev'] == 'orphaned'} | {k for k, e in new.items() if e.get('orphanAtFirstSight')}
maxw = collections.Counter(); worker_series = []
for p in polls:
    s = 0
    for k, v in (p.get('w') or {}).items():
        if k in wrapper or k in stub:
            continue
        s += v
        maxw[k] = max(maxw[k], v)
    live_real = None
    worker_series.append(s)

def shape(e):
    names = [c.get('name') for c in e.get('chain', [])]
    if 'sh.exe' in names:
        return 'hook'
    if names and names[0] in ('powershell.exe', 'pwsh.exe'):
        return 'tool-shell'
    return '<'.join(n or '?' for n in names)

print('observer %s .. %s, %d polls; real runs seen %d (wrappers dropped %d, sandbox stubs dropped %d)' % (
    first_poll.strftime('%H:%M:%S'), last_poll.strftime('%H:%M:%S'), len(polls), len(real), len(wrapper), len(stub - wrapper)))
print('workers across real runs per poll: min %d, max %d, mean %.2f; polls at 10: %d of %d' % (
    min(worker_series), max(worker_series), statistics.mean(worker_series), sum(1 for x in worker_series if x >= 10), len(worker_series)))
arrived = sorted(t(new[k]['created']) for k in real if t(new[k]['created']) >= first_poll)
span_h = (last_poll - first_poll).total_seconds() / 3600.0
print('real runs CREATED inside the window: %d over %.2f h = %.1f per hour; by shape %s' % (
    len(arrived), span_h, len(arrived) / span_h if span_h else 0,
    dict(collections.Counter(shape(new[k]) for k in real if t(new[k]['created']) >= first_poll))))
codes = collections.Counter(str(exits[k].get('exit')) for k in real if k in exits)
print('real runs that EXITED inside the window: %d; exit codes %s; still live at last poll: %d' % (
    sum(codes.values()), dict(codes), sum(1 for k in real if k not in exits)))
waits = []; holds = []; rows = []
for k in real:
    e = new[k]; c = t(e['created'])
    fc = first_child.get(k)
    ex = exits.get(k)
    w = (fc - c).total_seconds() if (fc and c >= first_poll) else None
    h = ((t(ex['t']) - fc).total_seconds() if (fc and ex and fc >= first_poll) else None)
    if w is not None:
        waits.append(w)
    if h is not None:
        holds.append((h, maxw[k], ex.get('exit')))
    rows.append((c, shape(e), (e['cmd'].split('worktrees')[-1][1:40] if 'worktrees' in e['cmd'] else '-'), w, h, maxw[k], ex.get('exit') if ex else 'live', k in orph,
                 (t(ex['t']) - c).total_seconds() if ex else None))
def q(xs):
    xs = sorted(xs)
    if not xs:
        return 'none'
    return 'n=%d min=%.0f median=%.0f max=%.0f' % (len(xs), xs[0], statistics.median(xs), xs[-1])
print('wait for first worker (runs created in window and granted): %s' % q(waits))
print('hold, first worker to exit (runs granted and finished in window): %s' % q([h for h, _, _ in holds]))
for h, mw, code in sorted(holds):
    print('   held %5.0fs at max width %d, exit %s' % (h, mw, code))
refused_in_window = [r for r in rows if r[6] == 3 and r[4] is None]
print('exit 3 with no worker ever seen (refused for want of a slot): %d; their life: %s' % (
    len(refused_in_window), q([r[8] for r in refused_in_window if r[8] is not None])))
print('orphans (parent gone while the run lived): %d' % sum(1 for k in real if k in orph))
if len(sys.argv) > 2:
    for r in sorted(rows):
        print('  %s %-10s %-40s wait=%-6s hold=%-6s maxW=%-2s exit=%-4s orphan=%s life=%s' % (
            r[0].strftime('%H:%M:%S'), r[1], r[2], None if r[3] is None else int(r[3]), None if r[4] is None else int(r[4]), r[5], r[6], r[7], None if r[8] is None else int(r[8])))
