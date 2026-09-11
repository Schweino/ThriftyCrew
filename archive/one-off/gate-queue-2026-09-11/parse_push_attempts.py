# parse_push_attempts.py v2 - READ-ONLY census of every tool call on 2026-09-11 whose command EXECUTES a
# `git push` or `-File ...run-gates.ps1`, with the outcome its tool result or background output file
# recorded. One row per tool call. The owner is the transcript the call is IN, never a timing match.
# v1 kept 400 characters of the command and read the kind off a regex over it, which missed multi-line
# scripts that push inside a loop; v2 keeps the command whole and classifies OUTCOMES off the output text.
import glob, json, os, re, sys, datetime

PROJ = r'C:\Users\Owner\.claude\projects'
TMPC = r'C:\Users\Owner\AppData\Local\Temp\claude'
SINCE = datetime.datetime(2026, 9, 11, 0, 0).timestamp()
OUT = sys.argv[1]

def strip_strings_and_comments(cmd):
    c = re.sub(r"(?m)#.*$", '', cmd)
    c = re.sub(r"'[^'\n]*'", "''", c)
    return c

PUSH_RX = re.compile(r'(?m)(^|[;{&|(]\s*|\bthen\s+|\bdo\s+)git(\s+-C\s+\S+)?\s+push\b')
GATES_RX = re.compile(r'-File\s+["\']?[^\s"\']*run-gates\.ps1|&\s*["\']?[^\s"\']*run-gates\.ps1|(^|[;\s])(\.[\\/])?ops[\\/]run-gates\.ps1\b(?!\S)')
LOOP_RX = re.compile(r'(?mi)^\s*(for|foreach|while|do|until)\b|\bfor\s*\(|\bforeach\s*\(|\bwhile\s*\(|\b1\.\.\d+\s*\|\s*(%|ForEach)')

def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for c in content:
            if isinstance(c, dict):
                if c.get('type') == 'text':
                    out.append(c.get('text', ''))
                elif 'content' in c:
                    out.append(text_of(c['content']))
            elif isinstance(c, str):
                out.append(c)
        return '\n'.join(out)
    return ''

def facts(t):
    f = {}
    f['slot_timeout'] = len(re.findall(r'waited 1,2\d\ds and every one of the 10', t))
    f['hook_exit3'] = len(re.findall(r'run-gates COULD NOT EVALUATE \(exit 3\)', t))
    f['hook_gate_failed'] = len(re.findall(r'pre-push: BLOCKED - run-gates exited [12]', t))
    f['hook_ta_blocked'] = len(re.findall(r'pre-push: BLOCKED - the test-auditors check', t))
    f['rejected_nff'] = len(re.findall(r'\[rejected\][^\n]*(non-fast-forward|fetch first)|Updates were rejected', t))
    f['remote_rejected'] = len(re.findall(r'\[remote rejected\]|cannot lock ref|failed to update ref', t))
    f['pushed'] = len(re.findall(r'(?m)^\s*[0-9a-f]{7,40}\.\.[0-9a-f]{7,40}\s+\S+\s+->\s+\S+|\* \[new branch\]', t))
    f['up_to_date'] = t.count('Everything up-to-date')
    f['tool_timeout'] = len(re.findall(r'Command timed out|timed out after \d+', t))
    f['waiting_line'] = t.count('gate worker slots are held by other gate runs - waiting')
    f['waited_s'] = [float(x.replace(',', '')) for x in re.findall(r'after ([\d.,]+)s waiting for them', t)]
    f['width_reached'] = [int(a) for a in re.findall(r'pool width reached (\d+) of the', t)]
    f['walls'] = [int(x.replace(',', '')) for x in re.findall(r'timing: \d+ gate\(s\), ([\d,]+)s wall', t)]
    f['verdicts'] = re.findall(r'run-gates: (PASSED|FAILED|COULD NOT EVALUATE)', t)
    f['complete'] = re.findall(r'RUN-GATES-COMPLETE[^\n]*', t)
    f['attempt_markers'] = re.findall(r'attempt (\d+) of (\d+)', t, re.I)
    f['kept_logs'] = sorted(set(re.findall(r'tc-prepush-(\d+)\.log', t)))
    m = re.findall(r'\[exited with code (\d+)\]|Exit code (\d+)', t)
    f['exit_codes'] = [int(a or b) for a, b in m]
    return f

rows = []
files = [p for p in glob.glob(os.path.join(PROJ, 'C--Codex-ThriftyCrew*', '**', '*.jsonl'), recursive=True)
         if os.path.getmtime(p) >= SINCE]
for path in files:
    calls, order = {}, []
    try:
        fh = open(path, encoding='utf-8', errors='replace')
    except OSError:
        continue
    with fh:
        for line in fh:
            try:
                o = json.loads(line)
            except Exception:
                continue
            msg = o.get('message') or {}
            content = msg.get('content')
            if o.get('type') == 'assistant' and isinstance(content, list):
                for c in content:
                    if not isinstance(c, dict) or c.get('type') != 'tool_use' or c.get('name') not in ('Bash', 'PowerShell'):
                        continue
                    inp = c.get('input') or {}
                    cmd = str(inp.get('command', ''))
                    code = strip_strings_and_comments(cmd)
                    push = bool(PUSH_RX.search(code))
                    gates = bool(GATES_RX.search(cmd)) and '-ListOnly' not in cmd
                    if not (push or gates):
                        continue
                    calls[c.get('id')] = {
                        'file': path, 'session': o.get('sessionId'), 'cwd': o.get('cwd'), 'sidechain': o.get('isSidechain'),
                        'ts': o.get('timestamp'), 'tool': c.get('name'), 'bg': bool(inp.get('run_in_background')),
                        'timeout_ms': inp.get('timeout'), 'push': push, 'gates': gates,
                        'loop': bool(LOOP_RX.search(code)), 'cmd': cmd[:6000],
                    }
                    order.append(c.get('id'))
            if o.get('type') == 'user' and isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get('type') == 'tool_result' and c.get('tool_use_id') in calls:
                        rec = calls[c['tool_use_id']]
                        t = text_of(c.get('content'))
                        rec['result_ts'] = o.get('timestamp')
                        rec['result_tail'] = t[-2500:]
                        m = re.search(r'running in background with ID: (\w+)', t)
                        if m:
                            rec['bgid'] = m.group(1)
                        rec['f'] = facts(t)
    for cid in order:
        rec = calls[cid]
        if rec.get('bgid') and rec.get('session'):
            outs = glob.glob(os.path.join(TMPC, '*', rec['session'], 'tasks', rec['bgid'] + '.output'))
            if outs:
                try:
                    t = open(outs[0], encoding='utf-8', errors='replace').read()
                    rec['bg_tail'] = t[-2500:]
                    rec['bg_end'] = datetime.datetime.fromtimestamp(os.path.getmtime(outs[0])).isoformat()
                    rec['fb'] = facts(t)
                except OSError:
                    pass
            else:
                rec['bg_missing'] = True
        rows.append(rec)

rows.sort(key=lambda r: r.get('ts') or '')
with open(OUT, 'w', encoding='utf-8', newline='\n') as w:
    for r in rows:
        w.write(json.dumps(r) + '\n')
print('transcripts scanned: %d; tool calls executing push or run-gates: %d; sessions: %d' % (
    len(files), len(rows), len({r['session'] for r in rows})))
