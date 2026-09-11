# analyze_attempts2.py - reads attempts2.jsonl (parse_push_attempts.py v2). Prints, per local hour and in
# total: tool calls that execute a push or a run-gates, what their output says happened, loops, retries
# after a refusal, sessions that ran the gate directly AND pushed, and pushes rejected after a gate ran.
# Transcript timestamps are UTC; local is CDT (UTC-5). One row per call is written to calls2.csv.
import json, sys, datetime, collections, csv, os

rows = [json.loads(l) for l in open(sys.argv[1], encoding='utf-8')]
outdir = os.path.dirname(sys.argv[1])

def local(ts):
    if not ts:
        return None
    return datetime.datetime.strptime(ts[:19], '%Y-%m-%dT%H:%M:%S') - datetime.timedelta(hours=5)

def merged(r):
    f = r.get('fb') if (r.get('bg') and r.get('fb')) else (r.get('f') or {})
    return f

sel = []
for r in rows:
    d = local(r.get('ts'))
    if not d or d.date() != datetime.date(2026, 9, 11):
        continue
    r['_d'] = d
    f = merged(r)
    r['_f'] = f
    gate_evidence = (f.get('waiting_line', 0) + len(f.get('verdicts', [])) + f.get('slot_timeout', 0)
                     + len(f.get('complete', [])) + len(f.get('waited_s', [])))
    r['_gate_ran_or_queued'] = gate_evidence > 0
    if f.get('slot_timeout') or f.get('hook_exit3'):
        o = 'REFUSED-no-slot' if f.get('slot_timeout') else 'HOOK-EXIT3'
    elif f.get('hook_gate_failed'):
        o = 'HOOK-GATE-FAILED'
    elif f.get('hook_ta_blocked'):
        o = 'HOOK-TA-BLOCKED'
    elif f.get('rejected_nff') or f.get('remote_rejected'):
        o = 'REJECTED-by-remote' + ('-AFTER-GATE' if gate_evidence else '')
    elif f.get('pushed'):
        o = 'PUSHED'
    elif f.get('up_to_date'):
        o = 'UP-TO-DATE'
    elif f.get('tool_timeout'):
        o = 'TOOL-TIMEOUT'
    elif f.get('verdicts'):
        o = 'GATES-' + f['verdicts'][-1].replace(' ', '-')
    elif r.get('bg') and r.get('bg_missing'):
        o = 'BG-OUTPUT-GONE'
    elif f.get('waiting_line'):
        o = 'WAITING-NO-END'
    else:
        o = 'NO-EVIDENCE'
    r['_o'] = o
    sel.append(r)

print('2026-09-11: %d tool calls executing push or run-gates, %d sessions' % (len(sel), len({r['session'] for r in sel})))
by_hour = collections.defaultdict(lambda: collections.Counter())
for r in sel:
    h = r['_d'].strftime('%H')
    by_hour[h]['calls'] += 1
    by_hour[h]['sess:' + r['session']] = 1
    by_hour[h][r['_o']] += 1
    by_hour[h]['slot_timeouts_in_output'] += r['_f'].get('slot_timeout', 0)
    by_hour[h]['loop_calls'] += 1 if r.get('loop') else 0
    by_hour[h]['direct_gates'] += 1 if (r.get('gates') and not r.get('push')) else 0
print('hour calls sessions direct-gates loop-calls refused-no-slot pushed rejected(after-gate) gate-failed ta-blocked')
for h in sorted(by_hour):
    c = by_hour[h]
    ns = sum(1 for k in c if k.startswith('sess:'))
    print('%s   %4d %8d %12d %10d %15d %6d %8d(%d) %11d %10d' % (
        h, c['calls'], ns, c['direct_gates'], c['loop_calls'], c['REFUSED-no-slot'] + c['HOOK-EXIT3'], c['PUSHED'],
        c['REJECTED-by-remote'] + c['REJECTED-by-remote-AFTER-GATE'], c['REJECTED-by-remote-AFTER-GATE'],
        c['HOOK-GATE-FAILED'], c['HOOK-TA-BLOCKED']))
print()
print('outcome totals: %s' % dict(collections.Counter(r['_o'] for r in sel).most_common()))

# retries: within a session, the next push/gates call after a refusal, and the gap
bys = collections.defaultdict(list)
for r in sel:
    bys[r['session']].append(r)
REF = {'REFUSED-no-slot', 'HOOK-EXIT3'}
ref_n = 0; retried = 0; gaps = []; ended = 0; retry_rows = []
for s, lst in bys.items():
    lst.sort(key=lambda r: r['_d'])
    for i, r in enumerate(lst):
        if r['_o'] in REF:
            ref_n += 1
            end = local(r.get('result_ts')) if not r.get('bg') else (datetime.datetime.fromisoformat(r['bg_end']) if r.get('bg_end') else None)
            if i + 1 < len(lst):
                retried += 1
                nxt = lst[i + 1]
                gaps.append(((nxt['_d'] - end).total_seconds() / 60.0) if end else None)
                retry_rows.append((s[:8], r['_d'].strftime('%H:%M'), end.strftime('%H:%M') if end else '?', nxt['_d'].strftime('%H:%M'), nxt['_o']))
            else:
                ended += 1
print('refusals (no slot / hook exit 3) seen in a call\'s output: %d calls; followed by another push or gate call in the same session: %d; last such call in its session: %d' % (ref_n, retried, ended))
for x in retry_rows:
    print('   session %s refused call started %s, ended %s, next call %s -> %s' % x)
# slot timeouts inside ONE call (a loop or a script that pushed more than once)
multi = [r for r in sel if r['_f'].get('slot_timeout', 0) + r['_f'].get('hook_exit3', 0) > 1 or len(r['_f'].get('attempt_markers', [])) > 1]
print('calls whose own output shows more than one attempt or more than one refusal: %d' % len(multi))
for r in multi:
    print('   %s %s loop=%s attempts=%s slot_timeouts=%d hook_exit3=%d rejected=%d pushed=%d' % (
        r['session'][:8], r['_d'].strftime('%H:%M'), r.get('loop'), r['_f'].get('attempt_markers'), r['_f'].get('slot_timeout', 0),
        r['_f'].get('hook_exit3', 0), r['_f'].get('rejected_nff', 0), r['_f'].get('pushed', 0)))
loops = [r for r in sel if r.get('loop') and r.get('push')]
print('calls that push inside a loop construct (strings and comments stripped; unsound, a for over files also counts): %d in %d sessions' % (
    len(loops), len({r['session'] for r in loops})))
dbl = 0; dsess = 0
for s, lst in bys.items():
    ds = [r for r in lst if r.get('gates') and not r.get('push')]
    if ds:
        dsess += 1
        if any(p['_d'] > ds[0]['_d'] and p.get('push') for p in lst):
            dbl += 1
print('sessions that ran run-gates directly: %d; of those, later pushed (the hook runs the whole gate again): %d' % (dsess, dbl))
per = collections.Counter(len(l) for l in bys.values())
print('push-or-gate calls per session: %s' % dict(sorted(per.items())))

with open(os.path.join(outdir, 'calls2.csv'), 'w', newline='', encoding='utf-8') as w:
    cw = csv.writer(w)
    cw.writerow(['local_start', 'session', 'cwd', 'bg', 'timeout_ms', 'push', 'gates', 'loop', 'outcome', 'slot_timeouts', 'waited_s', 'width', 'walls', 'attempts', 'kept_logs'])
    for r in sorted(sel, key=lambda r: r['_d']):
        f = r['_f']
        cw.writerow([r['_d'].strftime('%H:%M:%S'), r['session'][:8], (r.get('cwd') or '').split('\\')[-1], r.get('bg'), r.get('timeout_ms'),
                     r.get('push'), r.get('gates'), r.get('loop'), r['_o'], f.get('slot_timeout', 0), f.get('waited_s'), f.get('width_reached'),
                     f.get('walls'), len(f.get('attempt_markers', [])), ' '.join(f.get('kept_logs', []))])
