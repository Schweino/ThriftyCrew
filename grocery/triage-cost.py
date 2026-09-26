"""triage-cost.py - what a triage session ACTUALLY spent, derived from its transcripts, never typed.

WHY THIS EXISTS (2026-09-24, design/PLAN-triage-token-efficiency-2026-09-24.md). The cost ledger
(grocery/triage-plans/cost-ledger.jsonl) was hand-appended from the harness usage block after each spawn, and
that block's `total_tokens` is the size of the agent's FINAL context window, not what it consumed. Checked on
4 of 4 spawns of the 2026-09-19 run: every ledger `tokens` value equals input + cache read + cache write +
output of that agent's LAST API call, exactly. What a run processes is the sum over EVERY call, one to two
orders of magnitude more. And because the rows were typed by hand, a session that stayed open for three days
of follow-on work (2026-09-20 to 09-23, 56 spawns, about 402M cost units) wrote no row at all.

So every row here is derived from the session's own transcript files:
  <projects>/<session>.jsonl                          the orchestrator (main thread)
  <projects>/<session>/subagents/agent-<id>.jsonl     each spawn, with agent-<id>.meta.json naming its type
Any agent type is counted, general-purpose included.

UNITS. cost_units is an input-token equivalent: input + 1.25 x cache write + 0.1 x cache read + 5 x output.
Those are relative list-price weights for the Opus family (cache write at the 5-minute rate); a 1-hour cache
write costs more, so this UNDERSTATES a run that writes the long cache. It is an approximation stated as one,
good for comparing runs with each other, not an invoice. final_context is kept and named: it is the number
the old ledger called `tokens`, so old and new rows can be read side by side.

The transcript format is internal to Claude Code and can change between releases (its own docs say so). So a
transcript with API calls and no usage block anywhere is BLIND (exit 3), never a zero.

Run:
  python grocery/triage-cost.py                         report the current session (CLAUDE_CODE_SESSION_ID)
  python grocery/triage-cost.py --session <id> --append --plan plan-2026-09-25.json[,plan-2026-09-25-2.json]
                                                        append one row per agent (last row per key wins)
  python grocery/triage-cost.py --budget 30000000       exit 2 when the session has spent more than that
  python grocery/triage-cost.py --report                per-plan totals from schema-2 ledger rows
  python grocery/triage-cost.py --check-agents          the three copies of each triage agent are identical
  python grocery/triage-cost.py --selftest
Exit: 0 ok / under budget, 2 over budget or drift, 3 could not evaluate. Last line: TRIAGE-COST-COMPLETE.

SCOPE OF A CLEAN REPORT: it covers the transcript files it found and names how many; a spawn whose transcript
was deleted, or a session run on another machine, is outside it.
"""
# The self-test is hermetic (temp dirs and literals only), so it reads nothing but this file:
# gate-inputs: grocery\triage-cost.py
import argparse
import glob
import json
import os
import shutil
import sys
import tempfile

W_INPUT, W_WRITE, W_READ, W_OUTPUT = 1.0, 1.25, 0.1, 5.0
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_LEDGER = os.path.join(HERE, 'triage-plans', 'cost-ledger.jsonl')
PROJECTS = os.path.join(os.path.expanduser('~'), '.claude', 'projects')
AGENTS = ('triage-developer', 'triage-ops-developer', 'triage-reviewer')


def cost_units(t):
    return (W_INPUT * t['input'] + W_WRITE * t['cache_write'] + W_READ * t['cache_read']
            + W_OUTPUT * t['output'])


def usage_of(path):
    """One transcript -> totals. Records sharing a message id are ONE API call (a streamed message is written
    as one record per content block, each carrying the same usage), so usage is taken once per id and tool
    uses are counted per block."""
    calls = {}
    order = []
    call_ts = {}
    tools = 0
    ts = []
    model = None
    tool_names = {}
    results = []
    with open(path, encoding='utf-8') as fh:
        for line in fh:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get('timestamp'):
                ts.append(r['timestamp'])
            m = r.get('message') or {}
            if r.get('type') == 'user' and isinstance(m.get('content'), list):
                for c in m['content']:
                    if isinstance(c, dict) and c.get('type') == 'tool_result':
                        body = c.get('content')
                        n = len(body) if isinstance(body, str) else len(json.dumps(body))
                        results.append((n, tool_names.get(c.get('tool_use_id'), '?')))
            if r.get('type') != 'assistant':
                continue
            model = m.get('model') or model
            mid = m.get('id') or r.get('uuid')
            if mid not in calls:
                order.append(mid)
                call_ts[mid] = r.get('timestamp')
            u = m.get('usage')
            if u or mid not in calls:
                calls[mid] = u or {}
            for c in m.get('content') or []:
                if isinstance(c, dict) and c.get('type') == 'tool_use':
                    tools += 1
                    inp = c.get('input') or {}
                    what = inp.get('file_path') or inp.get('command') or inp.get('pattern') or ''
                    tool_names[c.get('id')] = '%s %s' % (c.get('name'), str(what)[:80].replace('\n', ' '))
    t = {'input': 0, 'cache_write': 0, 'cache_read': 0, 'output': 0}
    with_usage = 0
    for mid in order:
        u = calls[mid]
        if u:
            with_usage += 1
        t['input'] += int(u.get('input_tokens') or 0)
        t['cache_write'] += int(u.get('cache_creation_input_tokens') or 0)
        t['cache_read'] += int(u.get('cache_read_input_tokens') or 0)
        t['output'] += int(u.get('output_tokens') or 0)
    last = calls[order[-1]] if order else {}
    final_context = sum(int(last.get(k) or 0) for k in (
        'input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens', 'output_tokens'))
    blind = bool(order) and with_usage == 0
    # WHY it cost what it cost (2026-09-24, design/PLAN-triage-lean-2026-09-24.md): how big the context started, how
    # big it ran on average (every call re-reads it), and how much was re-cached after the agent sat idle past the
    # cache lifetime - a call whose cache write exceeds WAIT_WRITE_TOKENS after a gap of more than WAIT_GAP_S since the
    # previous call. Measured on 09-19: 13 of 16 such re-writes followed a wait over 5 minutes.
    ctxs = [ctx_of(calls[m]) for m in order if calls[m]]
    wait_units = 0.0
    wait_n = 0
    prev = None
    for m in order:
        u = calls[m]
        g = _gap_s(call_ts.get(m), call_ts.get(prev)) if prev else None
        w = int(u.get('cache_creation_input_tokens') or 0) if u else 0
        if g is not None and g > WAIT_GAP_S and w > WAIT_WRITE_TOKENS:
            wait_units += W_WRITE * w
            wait_n += 1
        prev = m
    results.sort(reverse=True)
    return {'api_calls': len(order), 'tool_uses': tools, 'tokens': t, 'final_context': final_context,
            'first_ts': min(ts) if ts else None, 'last_ts': max(ts) if ts else None, 'model': model,
            'blind': blind, 'ctx_first': ctxs[0] if ctxs else 0,
            'ctx_avg': int(sum(ctxs) / len(ctxs)) if ctxs else 0,
            'wait_rewrites': wait_n, 'wait_rewrite_units': int(round(wait_units)),
            'biggest_results': [[n, what] for n, what in results[:3]]}


WAIT_GAP_S = 300
WAIT_WRITE_TOKENS = 50000


def first_call_of(path):
    """WHAT A SPAWN PAYS FOR BEFORE IT HAS DONE ANYTHING (W1 of design/PLAN-triage-token-cut-2026-09-25.md).
    -> {'ctx_first', 'prelude': [(chars, what)], 'loads': [...]}.

    prelude is everything written to the transcript before the first API call: the dispatch, each instruction
    file (CLAUDE.md files and a MEMORY.md index), the agent's system prompt snapshot, and the other attachments.
    Sizes are CHARACTERS of the recorded text, not tokens: the API reports tokens only per call, so the one token
    figure here is ctx_first, the first call's whole context.

    loads are nested_memory attachments written AFTER the first call: the harness adds a directory's CLAUDE.md and
    rules the first time an agent touches a file there. Each is priced by what it MEASURABLY did: jump is the
    context growth across the call that first carried it, and carry_units is 1.25 x jump (written once) plus
    0.1 x jump for every later call that re-read it. A jump also holds whatever tool result arrived in the same
    turn, so it is an upper bound on the load, stated as one."""
    recs = []
    with open(path, encoding='utf-8') as fh:
        for line in fh:
            try:
                recs.append(json.loads(line))
            except ValueError:
                continue
    prelude = []
    pending = []
    loads = []
    calls = []
    seen = set()
    for r in recs:
        t = r.get('type')
        m = r.get('message') or {}
        if t == 'assistant':
            mid = m.get('id') or r.get('uuid')
            u = m.get('usage')
            if mid in seen:
                continue
            seen.add(mid)
            calls.append(ctx_of(u or {}))
            if pending:
                loads.append({'paths': pending, 'call': len(calls) - 1})
                pending = []
            continue
        if not calls:
            if t == 'user' and not prelude:
                c = m.get('content')
                prelude.append((len(c) if isinstance(c, str) else len(json.dumps(c)), 'dispatch'))
            elif t == 'attachment':
                a = r.get('attachment') or {}
                if a.get('type') == 'instructions':
                    for f in a.get('files') or []:
                        prelude.append((len(f.get('content') or ''), 'instructions ' + str(f.get('path'))))
                elif a.get('type') == 'prompt_snapshot':
                    prelude.append((len(str(a.get('systemPrompt') or '')), 'system prompt snapshot'))
                else:
                    prelude.append((len(json.dumps(a)), 'attachment ' + str(a.get('type'))))
        elif t == 'attachment':
            a = r.get('attachment') or {}
            if a.get('type') == 'nested_memory':
                c = a.get('content') or ''
                if isinstance(c, dict):  # the harness nests {path, type, content} inside content
                    c = c.get('content') or ''
                pending.append((len(c) if isinstance(c, str) else len(json.dumps(c)), str(a.get('path'))))
    for ld in loads:
        i = ld['call']
        jump = max(0, calls[i] - calls[i - 1]) if i > 0 else 0
        later = len(calls) - i - 1
        ld.update({'jump': jump, 'later_calls': later,
                   'carry_units': int(round(W_WRITE * jump + W_READ * jump * later)),
                   'chars': sum(n for n, _ in ld['paths'])})
    return {'ctx_first': calls[0] if calls else 0, 'calls': len(calls), 'prelude': prelude, 'loads': loads}


def ctx_of(u):
    return sum(int(u.get(k) or 0) for k in ('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens'))


def _gap_s(a, b):
    from datetime import datetime
    if not a or not b:
        return None
    try:
        return (datetime.fromisoformat(a.replace('Z', '+00:00'))
                - datetime.fromisoformat(b.replace('Z', '+00:00'))).total_seconds()
    except ValueError:
        return None


def _duration_ms(a, b):
    from datetime import datetime
    if not a or not b:
        return None
    try:
        fa = datetime.fromisoformat(a.replace('Z', '+00:00'))
        fb = datetime.fromisoformat(b.replace('Z', '+00:00'))
        return int((fb - fa).total_seconds() * 1000)
    except ValueError:
        return None


def find_session(session, projects=PROJECTS):
    """The directory holding <session>.jsonl. A session is filed under the directory it was LAUNCHED from, so
    every project directory is searched rather than assuming C--Codex."""
    hits = glob.glob(os.path.join(projects, '*', session + '.jsonl'))
    return os.path.dirname(hits[0]) if hits else None


def session_rows(session, projects=PROJECTS):
    """-> (rows, why). rows is None when the session cannot be read; why says what was missing."""
    home = find_session(session, projects)
    if not home:
        return None, 'no transcript named %s.jsonl under %s' % (session, projects)
    specs = [('orchestrator:' + session, 'orchestrator', os.path.join(home, session + '.jsonl'))]
    for meta in sorted(glob.glob(os.path.join(home, session, 'subagents', '*.meta.json'))):
        try:
            mj = json.load(open(meta, encoding='utf-8'))
        except ValueError:
            mj = {}
        aid = os.path.basename(meta)[:-len('.meta.json')]
        specs.append((aid, mj.get('agentType') or 'unknown', meta[:-len('.meta.json')] + '.jsonl'))
    rows = []
    for key, agent, path in specs:
        if not os.path.exists(path):
            continue
        u = usage_of(path)
        if u['blind']:
            return None, '%s has %d API call(s) and no usage block on any of them - the transcript format moved' % (
                path, u['api_calls'])
        t = u['tokens']
        rows.append({
            'schema': 2, 'date': (u['first_ts'] or '')[:10], 'session': session, 'agent_id': key,
            'agent': agent, 'model': u['model'], 'api_calls': u['api_calls'], 'tool_uses': u['tool_uses'],
            'input': t['input'], 'cache_write': t['cache_write'], 'cache_read': t['cache_read'],
            'output': t['output'], 'cost_units': int(round(cost_units(t))), 'final_context': u['final_context'],
            'duration_ms': _duration_ms(u['first_ts'], u['last_ts']), 'first_ts': u['first_ts'],
            'last_ts': u['last_ts'], 'ctx_first': u['ctx_first'], 'ctx_avg': u['ctx_avg'],
            'wait_rewrites': u['wait_rewrites'], 'wait_rewrite_units': u['wait_rewrite_units'],
            'biggest_results': u['biggest_results']})
    return rows, 'read %d transcript(s)' % len(rows)


NUMERIC = ('api_calls', 'tool_uses', 'input', 'cache_write', 'cache_read', 'output', 'cost_units')


def read_ledger(path):
    rows = []
    if os.path.exists(path):
        with open(path, encoding='utf-8') as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try:
                        rows.append(json.loads(line))
                    except ValueError:
                        pass
    return rows


def latest_by_key(rows):
    """Schema-2 rows, the LAST row per agent_id. A row is re-appended when its agent spent more, so the newest
    one is the whole account and older ones are history."""
    out = {}
    for r in rows:
        if r.get('schema') == 2 and r.get('agent_id'):
            out[r['agent_id']] = r
    return out


def append_rows(rows, plans, ledger):
    """Append each row whose numbers moved since its key's last row. Returns how many were written. Written as
    one append of LF lines, so the file stays one JSON object per line."""
    have = latest_by_key(read_ledger(ledger))
    new = []
    for r in rows:
        r = dict(r)
        old = have.get(r['agent_id'])
        prev_plans = list(old.get('plans') or []) if old else []
        r['plans'] = sorted(set(prev_plans) | set(plans))
        if old and all(old.get(k) == r.get(k) for k in NUMERIC) and old.get('plans') == r['plans']:
            continue
        new.append(r)
    if new:
        with open(ledger, 'a', encoding='utf-8', newline='\n') as fh:
            for r in new:
                fh.write(json.dumps(r, sort_keys=True) + '\n')
    return len(new)


def plan_statuses(plan_dir, name):
    try:
        doc = json.load(open(os.path.join(plan_dir, name), encoding='utf-8-sig'))
    except (OSError, ValueError):
        return None
    return [str(i.get('status') or '') for i in doc.get('items') or []]


def report(ledger, plan_dir):
    latest = latest_by_key(read_ledger(ledger))
    by_plan = {}
    for r in latest.values():
        for p in r.get('plans') or ['(no plan)']:
            by_plan.setdefault(p, []).append(r)
    lines = []
    for p in sorted(by_plan):
        rs = by_plan[p]
        cu = sum(int(r.get('cost_units') or 0) for r in rs)
        st = plan_statuses(plan_dir, p)
        if st is None:
            lines.append('%s  cost_units=%d over %d agent row(s)  (plan file not found)' % (p, cu, len(rs)))
            continue
        done = sum(1 for s in st if s == 'done')
        per = ('%d per done item' % (cu // done)) if done else 'no done item'
        lines.append('%s  cost_units=%d over %d agent row(s)  done %d of %d items  %s' % (
            p, cu, len(rs), done, len(st), per))
    return lines, len(latest)


def check_agents(copies):
    """copies: list of directories. -> (problems, compared)."""
    problems = []
    compared = 0
    for a in AGENTS:
        blobs = {}
        for d in copies:
            p = os.path.join(d, a + '.md')
            if not os.path.exists(p):
                problems.append('%s is missing from %s' % (a, d))
                continue
            blobs[d] = open(p, 'rb').read().replace(b'\r\n', b'\n')
        compared += len(blobs)
        if len(set(blobs.values())) > 1:
            problems.append('%s differs between: %s' % (a, ', '.join(sorted(blobs))))
    return problems, compared


def default_agent_copies():
    """The three places a triage agent definition lives: this checkout's .claude/agents (versioned), the
    workspace root C:\\Codex\\.claude\\agents (what a session launched from C:\\Codex loads, since a project
    agent outranks a user one), and ~/.claude/agents. The workspace root is the parent of the MAIN checkout,
    found through git's common dir so a worktree resolves it the same way."""
    import subprocess
    repo = os.path.dirname(HERE)
    main = repo
    try:
        common = subprocess.run(['git', '-C', repo, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                                capture_output=True, text=True, timeout=30).stdout.strip()
        if common:
            main = os.path.dirname(os.path.normpath(common))
    except (OSError, subprocess.SubprocessError):
        pass
    return [os.path.join(repo, '.claude', 'agents'),
            os.path.join(os.path.dirname(main), '.claude', 'agents'),
            os.path.join(os.path.expanduser('~'), '.claude', 'agents')]


# The directory triage-spawn-guard-hook.py reads (its STAMPS); both default to the same place.
CLOSED_DIR = os.environ.get('TC_TRIAGE_CLOSED_DIR') or os.path.join(
    os.environ.get('LOCALAPPDATA') or os.path.expanduser('~'), 'ThriftyCrew', 'triage-closed')


def write_closed_stamp(session, spent, closed_dir):
    import time
    os.makedirs(closed_dir, exist_ok=True)
    path = os.path.join(closed_dir, '%s.json' % session)
    with open(path, 'w', encoding='utf-8', newline='\n') as fh:
        json.dump({'session': session, 'closed_at': time.strftime('%Y-%m-%dT%H:%M:%S'), 'cost_units': spent}, fh)
    return path


# ------------------------------------------------------------------------------------------------ self-test
def _write(path, records):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8', newline='\n') as fh:
        for r in records:
            fh.write(json.dumps(r) + '\n')


def _call(mid, ts, usage, tools=0):
    recs = [{'type': 'assistant', 'timestamp': ts,
             'message': {'id': mid, 'model': 'claude-opus-5-5', 'usage': usage,
                         'content': [{'type': 'text', 'text': 'x'}]}}]
    for n in range(tools):
        recs.append({'type': 'assistant', 'timestamp': ts,
                     'message': {'id': mid, 'model': 'claude-opus-5-5', 'usage': usage,
                                 'content': [{'type': 'tool_use', 'name': 'Bash', 'id': 't%d' % n}]}})
    return recs


def selftest():
    results = []

    def case(label, ok, got):
        results.append((label, bool(ok), got))

    root = tempfile.mkdtemp(prefix='tcost-')
    try:
        proj = os.path.join(root, 'projects', 'C--Codex')
        sid = 'sess-a'
        u1 = {'input_tokens': 10, 'cache_creation_input_tokens': 100, 'cache_read_input_tokens': 1000,
              'output_tokens': 20}
        u2 = {'input_tokens': 2, 'cache_creation_input_tokens': 4, 'cache_read_input_tokens': 2000,
              'output_tokens': 8}
        _write(os.path.join(proj, sid + '.jsonl'),
               _call('m1', '2026-09-25T14:00:00Z', u1, tools=2) + _call('m2', '2026-09-25T14:10:00Z', u2, tools=1))
        sub = os.path.join(proj, sid, 'subagents')
        _write(os.path.join(sub, 'agent-x1.jsonl'), _call('s1', '2026-09-25T14:01:00Z', u1, tools=3))
        json.dump({'agentType': 'triage-reviewer'}, open(os.path.join(sub, 'agent-x1.meta.json'), 'w'))
        rows, why = session_rows(sid, os.path.join(root, 'projects'))
        orch = [r for r in rows or [] if r['agent'] == 'orchestrator']
        o = orch[0] if orch else {}
        case('CLEAN TWIN: a session reads as one orchestrator row plus one row per spawn (2 rows)',
             rows is not None and len(rows) == 2, why)
        case('MUST FIRE: records sharing a message id are ONE api call, and tool uses count per block (2 calls, 3 tools)',
             o.get('api_calls') == 2 and o.get('tool_uses') == 3, (o.get('api_calls'), o.get('tool_uses')))
        # the founding finding: final_context is the LAST call's four classes, the number the old ledger held
        case('MUST FIRE: final_context is the last call only (2+4+2000+8 = 2014), never the sum',
             o.get('final_context') == 2014, o.get('final_context'))
        # binary-exact: 12 input, 104 write, 3000 read, 28 output -> 12 + 130 + 300 + 140 = 582
        case('CLEAN TWIN: cost_units sums every call with the stated weights (582)',
             o.get('cost_units') == 582, o.get('cost_units'))

        _write(os.path.join(proj, 'sess-blind.jsonl'),
               [{'type': 'assistant', 'timestamp': '2026-09-25T14:00:00Z',
                 'message': {'id': 'b1', 'content': [{'type': 'text', 'text': 'x'}]}}])
        rows_b, why_b = session_rows('sess-blind', os.path.join(root, 'projects'))
        case('MUST FIRE: a transcript with calls and no usage block is BLIND, never a zero',
             rows_b is None and 'no usage block' in why_b, why_b)
        rows_m, why_m = session_rows('no-such', os.path.join(root, 'projects'))
        case('MUST FIRE: a session with no transcript is BLIND', rows_m is None, why_m)

        ledger = os.path.join(root, 'ledger.jsonl')
        n1 = append_rows(rows, ['plan-2026-09-25.json'], ledger)
        n2 = append_rows(rows, ['plan-2026-09-25.json'], ledger)
        case('CLEAN TWIN: an unchanged re-append writes nothing (2 then 0)', n1 == 2 and n2 == 0, (n1, n2))
        grown = [dict(r) for r in rows]
        grown[0]['cost_units'] += 1
        n3 = append_rows(grown, ['plan-2026-09-25-2.json'], ledger)
        latest = latest_by_key(read_ledger(ledger))
        lo = latest['orchestrator:' + sid]
        case('MUST FIRE: a row whose agent spent more is re-appended, the newest wins, and it keeps every plan',
             n3 == 2 and lo['cost_units'] == 583 and lo['plans'] == ['plan-2026-09-25-2.json', 'plan-2026-09-25.json'],
             (n3, lo['cost_units'], lo['plans']))

        # budget bar: at the bar is within it, one unit past is over
        case('BAR: spend exactly AT the budget (582 of 582) is within it', budget_verdict(582, 582) == 0,
             budget_verdict(582, 582))
        case('BAR: one unit PAST the budget (583 of 582) is over', budget_verdict(583, 582) == 2,
             budget_verdict(583, 582))

        a, b = os.path.join(root, 'a'), os.path.join(root, 'b')
        for d in (a, b):
            os.makedirs(d)
            for n in AGENTS:
                open(os.path.join(d, n + '.md'), 'wb').write(b'same\n')
        open(os.path.join(b, 'triage-reviewer.md'), 'wb').write(b'same\r\n')
        p0, c0 = check_agents([a, b])
        case('CLEAN TWIN: copies that differ only in line endings are identical (6 compared)',
             not p0 and c0 == 6, (p0, c0))
        open(os.path.join(b, 'triage-developer.md'), 'wb').write(b'drifted\n')
        p1, _ = check_agents([a, b])
        case('MUST FIRE: a drifted agent copy is named', any('triage-developer differs' in p for p in p1), p1)

        # WHY it cost: a re-cache after an idle gap. Bar: a gap of exactly 300 s is NOT a wait; 301 s is.
        big = {'input_tokens': 1, 'cache_creation_input_tokens': 60000, 'cache_read_input_tokens': 0, 'output_tokens': 1}
        small = {'input_tokens': 1, 'cache_creation_input_tokens': 10, 'cache_read_input_tokens': 60000, 'output_tokens': 1}
        wpath = os.path.join(root, 'w.jsonl')
        recs = (_call('w1', '2026-09-25T14:00:00Z', small, tools=1)
                + [{'type': 'user', 'timestamp': '2026-09-25T14:00:01Z',
                    'message': {'content': [{'type': 'tool_result', 'tool_use_id': 't0', 'content': 'y' * 1234}]}}]
                + _call('w2', '2026-09-25T14:05:01Z', big)
                + _call('w3', '2026-09-25T14:10:01Z', big))
        _write(wpath, recs)
        wu = usage_of(wpath)
        case('BAR: a re-cache 301 s after the previous call counts as a wait re-write; one exactly 300 s after does not (1 of 2)',
             wu['wait_rewrites'] == 1 and wu['wait_rewrite_units'] == 75000, (wu['wait_rewrites'], wu['wait_rewrite_units']))
        case('MUST FIRE: the biggest tool result is named with its size and the call that produced it (1234 chars, Bash)',
             wu['biggest_results'] and wu['biggest_results'][0][0] == 1234 and wu['biggest_results'][0][1].startswith('Bash'),
             wu['biggest_results'])
        # 60011, 60001, 60001 -> 180013 / 3 = 60004 (integer)
        case('CLEAN TWIN: ctx_first and ctx_avg read the context each call re-read (60011 first, 60004 average)',
             wu['ctx_first'] == 60011 and wu['ctx_avg'] == 60004, (wu['ctx_first'], wu['ctx_avg']))

        # W1 first-call breakdown. Contexts 1000, 1000 (load arrives), 5000, 5000: the jump is 4000 at call 3, re-read
        # by 1 later call, so 1.25 x 4000 + 0.1 x 4000 x 1 = 5400.
        def cu(n):
            return {'input_tokens': 0, 'cache_creation_input_tokens': 0, 'cache_read_input_tokens': n, 'output_tokens': 1}
        fpath = os.path.join(root, 'f.jsonl')
        _write(fpath,
               [{'type': 'user', 'message': {'content': 'd' * 100}},
                {'type': 'attachment', 'attachment': {'type': 'instructions', 'files': [
                    {'path': 'C:\\x\\MEMORY.md', 'content': 'm' * 300}]}},
                {'type': 'attachment', 'attachment': {'type': 'prompt_snapshot', 'systemPrompt': 's' * 200}}]
               + _call('f1', '2026-09-25T14:00:00Z', cu(1000)) + _call('f2', '2026-09-25T14:00:10Z', cu(1000))
               + [{'type': 'attachment', 'attachment': {'type': 'nested_memory', 'path': 'C:\\r\\ops.md',
                                                       'content': {'path': 'C:\\r\\ops.md', 'content': 'r' * 700}}}]
               + _call('f3', '2026-09-25T14:00:20Z', cu(5000)) + _call('f4', '2026-09-25T14:00:30Z', cu(5000)))
        fc = first_call_of(fpath)
        pre = dict((w, n) for n, w in fc['prelude'])
        case('CLEAN TWIN: the prelude names the dispatch, each instruction file and the system prompt (100, 300, 200 chars)',
             pre.get('dispatch') == 100 and pre.get('instructions C:\\x\\MEMORY.md') == 300
             and pre.get('system prompt snapshot') == 200 and fc['ctx_first'] == 1000, (fc['prelude'], fc['ctx_first']))
        ld = fc['loads'][0] if fc['loads'] else {}
        case('MUST FIRE: a nested-memory load after call 2 is priced on the call that carried it (+4000, 5400 units, 700 chars)',
             len(fc['loads']) == 1 and ld.get('call') == 2 and ld.get('jump') == 4000 and ld.get('carry_units') == 5400
             and ld.get('chars') == 700, fc['loads'])

        # W2: the stamp is <closed_dir>/<session>.json, the exact name triage-spawn-guard-hook.py's stamp_path() reads
        sp = write_closed_stamp('sess-z', 582, os.path.join(root, 'closed'))
        st = json.load(open(sp, encoding='utf-8'))
        case('MUST FIRE: --session-closed writes <dir>/<session>.json carrying the session and its spend (582)',
             os.path.basename(sp) == 'sess-z.json' and st.get('session') == 'sess-z' and st.get('cost_units') == 582,
             (sp, st))
    finally:
        shutil.rmtree(root, ignore_errors=True)

    bad = [r for r in results if not r[1]]
    for label, ok, got in results:
        print('%s  %s%s' % ('PASS' if ok else 'FAIL', label, '' if ok else '  got=%r' % (got,)))
    expected = 18
    if len(results) != expected:
        print('FAIL  the suite ran %d case(s), expected %d' % (len(results), expected))
        bad.append(None)
    print('triage-cost self-test %s (%d of %d cases)' % ('pass' if not bad else 'FAIL',
                                                       len(results) - len([b for b in bad if b]), len(results)))
    return 0 if not bad else 1


def budget_verdict(spent, budget):
    return 0 if spent <= budget else 2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--session', default=os.environ.get('CLAUDE_CODE_SESSION_ID', ''))
    ap.add_argument('--projects', default=PROJECTS)
    ap.add_argument('--ledger', default=DEFAULT_LEDGER)
    ap.add_argument('--plan', default='', help='plan file name(s) this spend belongs to, comma separated')
    ap.add_argument('--append', action='store_true')
    ap.add_argument('--budget', type=float, default=None)
    ap.add_argument('--report', action='store_true')
    ap.add_argument('--check-agents', action='store_true')
    ap.add_argument('--first-call', action='store_true',
                    help='what each transcript loaded before its first call, and each nested-memory load after it')
    ap.add_argument('--session-closed', action='store_true',
                    help='STEP 5: stamp this session closed, so triage-spawn-guard-hook refuses any later spawn')
    ap.add_argument('--closed-dir', default='')
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args()
    if a.selftest:
        rc = selftest()
        sys.exit(rc)
    if a.check_agents:
        copies = default_agent_copies()
        problems, compared = check_agents(copies)
        for p in problems:
            print('DRIFT  ' + p)
        print('triage-cost: compared %d agent file(s) across %d copies, %d problem(s)' % (
            compared, len(copies), len(problems)))
        print('TRIAGE-COST-COMPLETE check-agents problems=%d' % len(problems))
        sys.exit(2 if problems else 0)
    if a.session_closed:
        # W2: STEP 5 stamps the session, and ~/.claude/skills/triage-spawn-guard-hook.py refuses any later spawn
        # from it. The stamp lives outside the repo (it is per machine and per session, never a tracked file).
        if not a.session:
            print('triage-cost: BLIND - no --session and CLAUDE_CODE_SESSION_ID is not set, so nothing was stamped')
            print('TRIAGE-COST-COMPLETE blind=no-session')
            sys.exit(3)
        rows, why = session_rows(a.session, a.projects)
        spent = sum(r['cost_units'] for r in rows) if rows else None
        path = write_closed_stamp(a.session, spent, a.closed_dir or CLOSED_DIR)
        print('triage-cost: session %s stamped CLOSED at %s cost_units in %s; a later spawn from it is refused' % (
            a.session, spent if spent is not None else 'unknown', path))
        print('TRIAGE-COST-COMPLETE session-closed cost_units=%s' % (spent if spent is not None else 'unknown'))
        sys.exit(0)
    if a.first_call:
        if not a.session:
            print('triage-cost: BLIND - no --session and CLAUDE_CODE_SESSION_ID is not set')
            print('TRIAGE-COST-COMPLETE blind=no-session')
            sys.exit(3)
        home = find_session(a.session, a.projects)
        if not home:
            print('triage-cost: BLIND - no transcript named %s.jsonl' % a.session)
            print('TRIAGE-COST-COMPLETE blind=transcript')
            sys.exit(3)
        paths = [('orchestrator', os.path.join(home, a.session + '.jsonl'))]
        for meta in sorted(glob.glob(os.path.join(home, a.session, 'subagents', '*.meta.json'))):
            try:
                at = json.load(open(meta, encoding='utf-8')).get('agentType') or 'unknown'
            except ValueError:
                at = 'unknown'
            paths.append(('%s %s' % (at, os.path.basename(meta)[6:14]), meta[:-len('.meta.json')] + '.jsonl'))
        total_carry = 0
        loaded = 0
        for label, p in paths:
            if not os.path.exists(p):
                continue
            fc = first_call_of(p)
            print('%s: ctx_first=%d tokens over %d call(s); prelude %d chars' % (
                label, fc['ctx_first'], fc['calls'], sum(n for n, _ in fc['prelude'])))
            for n, what in sorted(fc['prelude'], reverse=True):
                if n >= 1000:
                    print('    %7d chars  %s' % (n, what))
            for ld in fc['loads']:
                loaded += 1
                total_carry += ld['carry_units']
                print('    LOAD at call %d: %d file(s), %d chars, context +%d tokens, re-read by %d later call(s), '
                      'about %d cost_units' % (ld['call'] + 1, len(ld['paths']), ld['chars'], ld['jump'],
                                               ld['later_calls'], ld['carry_units']))
                for n, what in sorted(ld['paths'], reverse=True)[:3]:
                    print('        %7d chars  %s' % (n, what))
        print('first-call: %d transcript(s), %d nested-memory load(s) carrying about %d cost_units' % (
            len(paths), loaded, total_carry))
        print('TRIAGE-COST-COMPLETE first-call transcripts=%d loads=%d carry_units=%d' % (len(paths), loaded, total_carry))
        sys.exit(0)
    if a.report:
        lines, keys = report(a.ledger, os.path.dirname(os.path.abspath(a.ledger)))
        for ln in lines:
            print(ln)
        print('TRIAGE-COST-COMPLETE report agents=%d plans=%d' % (keys, len(lines)))
        sys.exit(0)
    if not a.session:
        print('triage-cost: BLIND - no --session and CLAUDE_CODE_SESSION_ID is not set')
        print('TRIAGE-COST-COMPLETE blind=no-session')
        sys.exit(3)
    rows, why = session_rows(a.session, a.projects)
    if rows is None:
        print('triage-cost: BLIND - ' + why)
        print('TRIAGE-COST-COMPLETE blind=transcript')
        sys.exit(3)
    total = sum(r['cost_units'] for r in rows)
    for r in sorted(rows, key=lambda r: -r['cost_units']):
        print('%-22s %-20s calls=%5d tools=%5d cost_units=%11d ctx_avg=%7d wait_rewrites=%3d (%d units)' % (
            r['agent'], r['agent_id'][:20], r['api_calls'], r['tool_uses'], r['cost_units'], r['ctx_avg'],
            r['wait_rewrites'], r['wait_rewrite_units']))
        for n, what in r['biggest_results'][:1]:
            print('    biggest read: %d chars from %s' % (n, what))
    spawns = len(rows) - 1
    print('session %s: cost_units=%d over %d agent row(s) (%d spawn(s) plus the orchestrator), %s' % (
        a.session, total, len(rows), spawns, why))
    rc = 0
    if a.append:
        plans = [p.strip() for p in a.plan.split(',') if p.strip()]
        if not plans:
            print('triage-cost: REFUSED - --append needs --plan naming the plan file(s) this spend belongs to')
            print('TRIAGE-COST-COMPLETE refused=no-plan')
            sys.exit(2)
        n = append_rows(rows, plans, a.ledger)
        print('appended %d row(s) to %s' % (n, a.ledger))
    if a.budget is not None:
        rc = budget_verdict(total, a.budget)
        print('BUDGET %s: spent %d of %d cost_units (%.0f%%)' % (
            'OVER' if rc else 'within', total, int(a.budget), 100.0 * total / a.budget if a.budget else 0))
    print('TRIAGE-COST-COMPLETE cost_units=%d rows=%d' % (total, len(rows)))
    sys.exit(rc)


if __name__ == '__main__':
    main()
