"""measure_rules_split.py - the W2.3 rubric for option A against option B (D2, 2026-09-25).

Read-only. Writes one row per case per arm into --out (JSONL) and prints the derived totals.

  (i)   session-start instruction bytes in a main-checkout session that reads nothing:
        global CLAUDE.md + C:\\Codex\\CLAUDE.md + ThriftyCrew CLAUDE.md (blob at the arm's ref) + MEMORY.md
        (cut at the harness limits, 200 lines or 25,000 B) + every .claude/rules/*.md at the arm's ref whose
        front matter has no paths: key, counted WITHOUT its front matter (the loader hands on the body).
        BAR, written before the run: at most 50,000 B for arm B.
  (iii) replay of transcripts: for each context (a session or a subagent transcript) that EDITED a file under
        grocery/ with Edit, MultiEdit, Write or NotebookEdit, would the grocery depth file have loaded before
        that first edit under arm B's paths:? BAR, written before the run: at least 90% of contexts.
        A second population, contexts whose only grocery write was a shell command, is reported beside it
        and never folded in.

THE TRIGGER ASSUMED (read out of CLI 2.1.263, see the header of the report in the commit): a paths: rules
file loads when the Read tool reads a file (text, image or notebook) whose path, relative to the checkout
that holds the rules directory, the rules file's paths: list matches with gitignore semantics (the loader
uses the `ignore` package; a slashless entry matches a path segment at any depth). The attachment is built
at the next turn, so a Read in the SAME assistant message as the edit does not count. Edit, Write, Grep,
Glob and shell commands never trigger it (STRICT model). The IDE model also counts an `opened_file_in_ide`
attachment, which the loader sends through the same matcher, and both are printed. How this can be wrong: an @-mention in the prompt also triggers
(not replayed, so the rate is a floor); a compaction between the load and the edit may drop the loaded
file (counted and printed, not excluded); and a build other than 2.1.263 may differ.

VALIDATION of the trigger model on data we do have: every nested_memory attachment in the corpus (a nested
CLAUDE.md or rules file the same mechanism loads) is checked for a successful Read under that directory in
the turn before it.

Usage:
  python measure_rules_split.py --ref-a origin/main --ref-b HEAD --days 7 --out rows.jsonl
"""
import argparse, glob, json, os, re, subprocess, sys, time, datetime, collections

TC = r'C:\Codex\ThriftyCrew'  # the main checkout, for classifying transcript paths
REPO = subprocess.run(['git', '-C', os.path.dirname(os.path.abspath(__file__)), 'rev-parse', '--show-toplevel'],
                      capture_output=True, text=True).stdout.strip()  # where the refs are read
GLOBAL_MD = r'C:\Users\Owner\.claude\CLAUDE.md'
WORKSPACE_MD = r'C:\Codex\CLAUDE.md'
MEMORY_MD = r'C:\Users\Owner\.claude\projects\C--Codex-ThriftyCrew\memory\MEMORY.md'
PROJECTS = r'C:\Users\Owner\.claude\projects'
MEM_LINES, MEM_BYTES = 200, 25000
BAR_BYTES = 50000
BAR_REPLAY = 0.90
EDIT_TOOLS = {'Edit', 'MultiEdit', 'Write', 'NotebookEdit'}
SHELL_TOOLS = {'Bash', 'PowerShell'}
SHELL_WRITE_RX = re.compile(r'Set-Content|Add-Content|Out-File|WriteAllText|WriteAllBytes|Move-Item|Copy-Item|'
                            r'Remove-Item|New-Item|\bgit\s+(mv|rm|checkout\s+--)\b|\bsed\s+-i\b|>\s*\S', re.I)


def git(repo, *args):
    return subprocess.run(['git', '-C', repo] + list(args), capture_output=True, encoding='utf-8',
                          errors='replace').stdout


def split_front_matter(text):
    if not text.startswith('---\n') and not text.startswith('---\r\n'):
        return None, text
    m = re.search(r'\r?\n---\r?\n', text[3:])
    if not m:
        return None, text
    return text[4:3 + m.start()], text[3 + m.end():]


def parse_paths(fm):
    """The loader's reading of paths: (a YAML block list, a flow list or a comma string; trailing /**
    stripped; empties dropped; only ** means unconditional). None when unconditional."""
    if fm is None:
        return None
    lines = fm.splitlines()
    raw = None
    for i, ln in enumerate(lines):
        m = re.match(r'^paths\s*:(.*)$', ln)
        if not m:
            continue
        val = m.group(1).strip()
        raw = []
        if val == '' or val.startswith('#'):
            for nxt in lines[i + 1:]:
                im = re.match(r'^\s*-\s*(.*)$', nxt)
                if not im:
                    break
                raw.append(im.group(1).strip().strip('"').strip("'"))
        elif val.startswith('['):
            raw = [p.strip().strip('"').strip("'") for p in val.strip('[]').split(',')]
        else:
            raw = [p.strip() for p in val.strip('"').strip("'").split(',')]
    if raw is None:
        return None
    ents = [p[:-3] if p.endswith('/**') else p for p in raw]
    ents = [p for p in ents if p]
    if not ents or all(p == '**' for p in ents):
        return None
    return ents


def glob_to_rx(pat):
    out, i = '', 0
    while i < len(pat):
        if pat.startswith('**/', i):
            out += '(?:.*/)?'; i += 3
        elif pat.startswith('**', i):
            out += '.*'; i += 2
        elif pat[i] == '*':
            out += '[^/]*'; i += 1
        elif pat[i] == '?':
            out += '[^/]'; i += 1
        else:
            out += re.escape(pat[i]); i += 1
    return re.compile('^' + out + '$', re.I)


def gitignore_match(entries, rel):
    """gitignore semantics as the `ignore` package applies them: a path matches when it or any parent
    directory matches; a pattern with no slash (other than a trailing one) matches a single segment at any
    depth, one with a slash is anchored at the root. Windows paths compare case-insensitively."""
    rel = rel.replace('\\', '/').strip('/')
    if not rel or rel.startswith('..'):
        return False
    parts = rel.split('/')
    prefixes = ['/'.join(parts[:k]) for k in range(1, len(parts) + 1)]
    for e in entries:
        e2 = e.lstrip('/')
        anchored = '/' in e2.rstrip('/') or e.startswith('/')
        rx = glob_to_rx(e2.rstrip('/'))
        if anchored:
            if any(rx.match(p) for p in prefixes):
                return True
        else:
            if any(rx.match(seg) for seg in parts):
                return True
    return False


def rules_at(ref):
    names = [n for n in git(REPO, 'ls-tree', '--name-only', ref, '.claude/rules/').splitlines() if n.endswith('.md')]
    out = {}
    for n in names:
        text = git(REPO, 'show', f'{ref}:{n}')
        blob = git(REPO, 'rev-parse', f'{ref}:{n}').strip()
        fm, body = split_front_matter(text)
        out[os.path.basename(n)] = {'paths': parse_paths(fm), 'body_bytes': len(body.encode('utf-8')),
                                    'file_bytes': len(text.encode('utf-8')), 'blob': blob}
    return out


def memory_bytes():
    raw = open(MEMORY_MD, 'rb').read()
    lines = raw.split(b'\n')
    cut = b'\n'.join(lines[:MEM_LINES])
    return min(len(cut), MEM_BYTES), len(raw), len(lines)


def bytes_rows(arm, ref):
    rows = []
    for label, path in (('global CLAUDE.md', GLOBAL_MD), ('workspace CLAUDE.md', WORKSPACE_MD)):
        rows.append({'measure': 'i', 'arm': arm, 'file': label, 'source': path, 'loads_at_start': True,
                     'bytes': os.path.getsize(path)})
    tcmd = git(REPO, 'show', f'{ref}:CLAUDE.md')
    rows.append({'measure': 'i', 'arm': arm, 'file': 'ThriftyCrew CLAUDE.md', 'source': f'{ref}:CLAUDE.md',
                 'blob': git(REPO, 'rev-parse', f'{ref}:CLAUDE.md').strip(), 'loads_at_start': True,
                 'bytes': len(tcmd.encode('utf-8'))})
    mb, mraw, mlines = memory_bytes()
    rows.append({'measure': 'i', 'arm': arm, 'file': 'MEMORY.md', 'source': MEMORY_MD, 'loads_at_start': True,
                 'bytes': mb, 'raw_bytes': mraw, 'lines': mlines})
    for name, r in sorted(rules_at(ref).items()):
        rows.append({'measure': 'i', 'arm': arm, 'file': '.claude/rules/' + name, 'source': f'{ref}:.claude/rules/{name}',
                     'blob': r['blob'], 'loads_at_start': r['paths'] is None, 'paths': r['paths'],
                     'bytes': r['body_bytes']})
    return rows


# ------------------------------------------------------------------------------------------ replay
CHECKOUT_RX = re.compile(r'^(?P<root>c:[\\/]codex[\\/]thriftycrew(?:[\\/]\.claude[\\/]worktrees[\\/][^\\/]+)?)'
                         r'(?:[\\/](?P<rel>.*))?$', re.I)


def rel_to_tc(path):
    """Path relative to the ThriftyCrew checkout that holds it (a worktree root when it is under one)."""
    if not path:
        return None
    p = path.replace('/', '\\')
    m = CHECKOUT_RX.match(p)
    if not m:
        return None
    return (m.group('rel') or '').replace('\\', '/')


def rel_to_main(path):
    p = (path or '').replace('/', '\\')
    if not p.lower().startswith(TC.lower() + '\\'):
        return None
    return p[len(TC) + 1:].replace('\\', '/')


def depth_would_load(entries, path):
    """B loads a depth file for this Read if the file's own checkout copy of the rules matches it relative
    to that checkout, or the main checkout's copy matches it relative to the main checkout (an ancestor
    rules directory, which with a slashless entry reaches into worktrees too)."""
    r1 = rel_to_tc(path)
    if r1 is not None and gitignore_match(entries, r1):
        return True
    r2 = rel_to_main(path)
    return r2 is not None and gitignore_match(entries, r2)


def is_grocery_file(path):
    r = rel_to_tc(path)
    return r is not None and (r.lower().startswith('grocery/'))


def iter_contexts(root, days):
    cut = time.time() - days * 86400
    for f in glob.glob(os.path.join(root, '**', '*.jsonl'), recursive=True):
        if os.path.getmtime(f) >= cut:
            yield f


def replay_context(path, depths):
    """One row per context: its first grocery edit (tool), first shell grocery write, which depth files
    would have loaded before each, and every depth file loaded by the end."""
    msgs = []  # (msg_index, [tool_use dicts])
    results = {}
    compacts = []
    nested = []  # (msg_index_before, attachment path)
    ide_opened = []  # (msg_index_before, filename)
    cwd = None
    idx = -1
    last_msg_id = None
    try:
        fh = open(path, encoding='utf-8', errors='replace')
    except OSError:
        return None
    with fh:
        for line in fh:
            try:
                e = json.loads(line)
            except Exception:
                continue
            cwd = cwd or e.get('cwd')
            t = e.get('type')
            if t == 'assistant':
                m = e.get('message') or {}
                mid = m.get('id') or e.get('uuid')
                if mid != last_msg_id:
                    idx += 1; last_msg_id = mid
                    msgs.append((idx, []))
                for c in m.get('content') or []:
                    if isinstance(c, dict) and c.get('type') == 'tool_use':
                        msgs[-1][1].append(c)
            elif t == 'user':
                m = e.get('message') or {}
                cont = m.get('content')
                if isinstance(cont, list):
                    for c in cont:
                        if isinstance(c, dict) and c.get('type') == 'tool_result':
                            results[c.get('tool_use_id')] = bool(c.get('is_error'))
            elif t == 'system' and e.get('subtype') == 'compact_boundary':
                compacts.append(idx)
            elif t == 'attachment':
                a = e.get('attachment') or {}
                if a.get('type') == 'nested_memory':
                    nested.append((idx, a.get('path') or ''))
                elif a.get('type') == 'opened_file_in_ide':
                    ide_opened.append((idx, a.get('filename') or ''))
    # Two trigger models. STRICT: only a successful Read (what the 2.1.263 and 2.1.281 binaries push onto
    # nestedMemoryAttachmentTriggers). IDE: also an `opened_file_in_ide` attachment, which the loader passes
    # through the same matcher (vps -> imr); the desktop surface records one when it shows a file, and one
    # was seen loading a depth file after an Edit in the session that wrote this harness.
    loaded_at = {}      # STRICT: depth name -> msg index after which it is loaded
    loaded_at_ide = {}  # IDE model
    ide_by_idx = collections.defaultdict(list)
    for mi, fn in ide_opened:
        ide_by_idx[mi].append(fn)
    first_edit = None; first_shell = None; any_edit = False; first_mp = None
    for mi, uses in msgs:
        for u in uses:
            name = u.get('name'); inp = u.get('input') or {}
            if name == 'Read' and not results.get(u.get('id'), False):
                fp = inp.get('file_path') or ''
                for dn, ents in depths.items():
                    if depth_would_load(ents, fp):
                        loaded_at.setdefault(dn, mi)
                        loaded_at_ide.setdefault(dn, mi)
        for fn in ide_by_idx.get(mi, []):
            for dn, ents in depths.items():
                if depth_would_load(ents, fn):
                    loaded_at_ide.setdefault(dn, mi)
        for u in uses:
            name = u.get('name'); inp = u.get('input') or {}
            if name in EDIT_TOOLS:
                any_edit = True
                fp = inp.get('file_path') or inp.get('notebook_path') or ''
                if first_edit is None and is_grocery_file(fp):
                    first_edit = (mi, name, rel_to_tc(fp))
                r = rel_to_tc(fp)
                if first_mp is None and r is not None and r.lower().startswith('meal-prep/'):
                    first_mp = (mi, name, r)
            elif name in SHELL_TOOLS:
                cmd = inp.get('command') or ''
                if re.search(r'grocery[\\/]', cmd, re.I) and SHELL_WRITE_RX.search(cmd):
                    any_edit = True
                    if first_shell is None:
                        first_shell = (mi, name, cmd[:120])
    # nested_memory validation: was there a successful Read in the previous assistant message under the
    # directory the attachment came from?
    val = []
    by_idx = dict(msgs)
    for mi, ap in nested:
        # a rules file at <root>\.claude\rules\x.md is loaded for a read under <root>; a CLAUDE.md for one under its dir
        low = ap.lower().replace('/', '\\')
        k = low.find('\\.claude\\rules\\')
        adir = ap[:k] if k >= 0 else os.path.dirname(ap)
        prev = by_idx.get(mi, [])
        reads = [u for u in prev if u.get('name') == 'Read' and not results.get(u.get('id'), False)
                 and (u.get('input') or {}).get('file_path', '').lower().startswith(adir.lower())]
        others = [u.get('name') for u in prev]
        ide = [fn for fn in ide_by_idx.get(mi, []) if fn.lower().startswith(adir.lower())]
        earlier = any(u.get('name') == 'Read' and (u.get('input') or {}).get('file_path', '').lower().startswith(adir.lower())
                      for j, us in msgs if j < mi for u in us)
        val.append({'attachment': ap, 'read_under_dir_in_prev_turn': bool(reads), 'ide_opened_under_dir': bool(ide),
                    'read_under_dir_any_earlier_turn': earlier,
                    'prev_turn_tools': others})

    def before(ev, table=None):
        table = loaded_at if table is None else table
        if ev is None:
            return None
        return {dn: (dn in table and table[dn] < ev[0]) for dn in depths}

    def compacted_between(ev, dn):
        if ev is None or dn not in loaded_at:
            return False
        return any(loaded_at[dn] <= c < ev[0] for c in compacts)

    return {
        'measure': 'iii', 'context': os.path.relpath(path, PROJECTS), 'cwd': cwd,
        'is_subagent': ('subagents' in path.split(os.sep)) or os.path.basename(os.path.dirname(path)).startswith('wf_'),
        'first_grocery_edit': first_edit and {'msg': first_edit[0], 'tool': first_edit[1], 'rel': first_edit[2]},
        'depth_loaded_before_edit': before(first_edit),
        'depth_loaded_before_edit_ide_model': before(first_edit, loaded_at_ide),
        'ide_opened_count': len(ide_opened),
        'compaction_between_load_and_edit': compacted_between(first_edit, 'grocery-depth.md'),
        'first_shell_grocery_write': first_shell and {'msg': first_shell[0], 'tool': first_shell[1], 'cmd': first_shell[2]},
        'depth_loaded_before_shell_write': before(first_shell),
        'first_mealprep_edit': first_mp and {'msg': first_mp[0], 'tool': first_mp[1], 'rel': first_mp[2]},
        'depth_loaded_before_mealprep_edit': before(first_mp),
        'any_edit': any_edit, 'msgs': len(msgs),
        'depth_loaded_by_end': sorted(loaded_at), 'nested_validation': val,
    }


def pct(n, d):
    return f'{n} of {d} ({100.0 * n / d:.1f}%)' if d else f'{n} of 0 (no denominator)'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ref-a', default='origin/main')
    ap.add_argument('--ref-b', default='HEAD')
    ap.add_argument('--days', type=float, default=7)
    ap.add_argument('--out', required=True)
    ap.add_argument('--roots', default='C--Codex-ThriftyCrew',
                    help='comma list of project dirs under ~/.claude/projects; a trailing * is a glob')
    a = ap.parse_args()
    rows = []
    fp = {'ref_a': a.ref_a, 'ref_a_sha': git(REPO, 'rev-parse', a.ref_a).strip(), 'ref_b': a.ref_b,
          'ref_b_sha': git(REPO, 'rev-parse', a.ref_b).strip(), 'days': a.days,
          'harness_blob': subprocess.run(['git', 'hash-object', __file__], capture_output=True, text=True).stdout.strip(),
          'run_at': datetime.datetime.now().isoformat(timespec='seconds')}
    rows.append({'measure': 'fingerprint', **fp})
    for arm, ref in (('A', a.ref_a), ('B', a.ref_b)):
        rows.extend(bytes_rows(arm, ref))
    # depth paths come from arm B's own front matter, never from this file
    rb = rules_at(a.ref_b)
    depths = {n: r['paths'] for n, r in rb.items() if r['paths'] is not None}
    rows.append({'measure': 'depth_paths', 'arm': 'B', 'depths': depths})
    roots = []
    for r in a.roots.split(','):
        roots.extend(sorted(glob.glob(os.path.join(PROJECTS, r.strip()))))
    for root in roots:
        for f in iter_contexts(root, a.days):
            row = replay_context(f, depths)
            if row:
                row['root'] = os.path.basename(root)
                rows.append(row)
    with open(a.out, 'w', encoding='utf-8', newline='\n') as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + '\n')

    # ---------------------------------------------------------------- totals, derived from the rows
    print('fingerprint', json.dumps(fp))
    for arm in ('A', 'B'):
        br = [r for r in rows if r.get('measure') == 'i' and r['arm'] == arm]
        start = sum(r['bytes'] for r in br if r['loads_at_start'])
        rules_start = sum(r['bytes'] for r in br if r['loads_at_start'] and r['file'].startswith('.claude/rules/'))
        cond = sum(r['bytes'] for r in br if not r['loads_at_start'])
        print(f'(i) arm {arm}: session start {start:,} B (rules {rules_start:,} B); conditional, not at start {cond:,} B')
        for r in br:
            print(f'      {"START" if r["loads_at_start"] else "paths"} {r["bytes"]:>7,} {r["file"]}')
    bstart = sum(r['bytes'] for r in rows if r.get('measure') == 'i' and r['arm'] == 'B' and r['loads_at_start'])
    print(f'(i) BAR at most {BAR_BYTES:,} B: arm B {bstart:,} B -> {"MET" if bstart <= BAR_BYTES else "NOT MET"}')
    ctx = [r for r in rows if r.get('measure') == 'iii']
    print(f'(iii) contexts scanned: {len(ctx)} (roots {len(roots)}, last {a.days:g} days)')
    for root_label, sel in (('all roots', ctx), ('C--Codex-ThriftyCrew only', [r for r in ctx if r['root'] == 'C--Codex-ThriftyCrew']),
                            ('worktree-key roots only', [r for r in ctx if r['root'] != 'C--Codex-ThriftyCrew'])):
        ed = [r for r in sel if r['first_grocery_edit']]
        ok = [r for r in ed if r['depth_loaded_before_edit'].get('grocery-depth.md')]
        oki = [r for r in ed if r['depth_loaded_before_edit_ide_model'].get('grocery-depth.md')]
        print(f'(iii) {root_label}: IDE model (Read or an opened_file_in_ide attachment): {pct(len(oki), len(ed))}')
        cmp_ = [r for r in ok if r['compaction_between_load_and_edit']]
        sh = [r for r in sel if r['first_shell_grocery_write'] and not r['first_grocery_edit']]
        shok = [r for r in sh if r['depth_loaded_before_shell_write'].get('grocery-depth.md')]
        print(f'(iii) {root_label}: grocery depth loaded before the first tool edit of grocery/: {pct(len(ok), len(ed))}'
              f'; of those, a compaction fell between load and edit in {len(cmp_)}')
        print(f'      shell-only grocery writers (separate population): depth before first write {pct(len(shok), len(sh))}')
        if ed:
            ops = [r for r in ed if r['depth_loaded_before_edit'].get('ops-and-gates-depth.md')]
            print(f'      same contexts, ops-and-gates depth also loaded before that edit: {pct(len(ops), len(ed))}')
        miss = [r for r in ed if not r['depth_loaded_before_edit'].get('grocery-depth.md')]
        for r in miss[:15]:
            print(f'      MISS {r["context"]} first edit {r["first_grocery_edit"]}')
    if ctx:
        print(f'(iii) BAR at least {BAR_REPLAY:.0%} (all roots) -> see the all-roots line')
    med = [r for r in ctx if r['first_mealprep_edit']]
    mok = [r for r in med if r['depth_loaded_before_mealprep_edit'].get('meal-prep-depth.md')]
    print(f'(extra) meal-prep depth loaded before the first tool edit of meal-prep/: {pct(len(mok), len(med))}')
    vals = [v for r in ctx for v in r['nested_validation']]
    vok = [v for v in vals if v['read_under_dir_in_prev_turn']]
    vide = [v for v in vals if v['read_under_dir_in_prev_turn'] or v['ide_opened_under_dir']]
    print(f'trigger validation: nested_memory attachments preceded by a successful Read under their directory in the turn before: {pct(len(vok), len(vals))}')
    print(f'trigger validation: ... by a Read OR an opened_file_in_ide attachment under it: {pct(len(vide), len(vals))}')
    un = [v for v in vals if not v['read_under_dir_in_prev_turn']]
    lag = [v for v in un if v['read_under_dir_any_earlier_turn']]
    shell_only = [v for v in un if v['prev_turn_tools'] and set(v['prev_turn_tools']) <= {'PowerShell', 'Bash', 'Grep', 'Glob'}]
    print(f'trigger validation: of the {len(un)} not explained by the turn before, a Read under the directory happened in an EARLIER turn in {len(lag)}; the turn before held only shell or search tools in {len(shell_only)}')
    print(f'opened_file_in_ide attachments in the corpus: {sum(r["ide_opened_count"] for r in ctx)} across {sum(1 for r in ctx if r["ide_opened_count"])} contexts')
    for v in [v for v in vals if not (v['read_under_dir_in_prev_turn'] or v['ide_opened_under_dir'])][:10]:
        print(f'      UNEXPLAINED {v["attachment"]} prev-turn tools {v["prev_turn_tools"]}')
    # session classes for the missing-rules list
    for label, pred in (('grocery-editing', lambda r: bool(r['first_grocery_edit'])),
                        ('meal-prep-editing', lambda r: bool(r['first_mealprep_edit'])),
                        ('read-only (no edit, no shell write)', lambda r: not r['any_edit'])):
        sel = [r for r in ctx if pred(r)]
        c = collections.Counter(d for r in sel for d in r['depth_loaded_by_end'])
        print(f'depth loaded by end of context, {label}: n={len(sel)} ' + ', '.join(f'{d} {pct(c[d], len(sel))}' for d in sorted(depths)))
    print('MEASURE-RULES-SPLIT-COMPLETE rows=%d contexts=%d' % (len(rows), len(ctx)))


if __name__ == '__main__':
    main()
