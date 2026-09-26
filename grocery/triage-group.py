"""triage-group.py - group open triage alerts that share one cause, BEFORE the reviewer sees them.

WHY THIS EXISTS (2026-09-24, Brad). The 09-24 reviewer was sent 12 alerts and 6 of them were one condition seen by
different emitters (a pipeline that could not push, the watchdog's "not published", "computed but not shipped", the
soundness summary that repeats its own per-condition item). It spent calls proving each duplicate a duplicate, at
about 270k input-token equivalents per alert. This groups them mechanically so the reviewer gets one PRIMARY per
group; the members go to the cheap lane (triage-ops-developer JOB 3) as "superseded by <primary>", which verifies that
in a few calls and PROMOTES any member whose evidence says it is a different cause.

Two alerts are joined when EITHER holds (union-find, so joins are transitive):
  family   - both types are listed in one family of grocery/triage-families.json (one symptom, several emitters)
  shared   - both bodies contain one line of at least SHARED_MIN characters (a summary that repeats its
             per-condition item) that no more than BOILERPLATE_MAX alerts carry
NOT a key, measured on the first real run (2026-09-24): the `graded: <sha>` stamp. Every alert one pipeline run emits
carries the same stamp, so joining on it put the horseradish crown and a blind guard under the push failure: 11 of 14
alerts in 2 groups, where the reviewer's own reading was 4 real groups. A line more than BOILERPLATE_MAX alerts carry
("Full watchdog report for ...") is an emitter's footer, not a condition, and joins nothing.
The primary is the group's earliest id in queue order. Wrong joins are the costly error (a cause hidden from the
reviewer), missed joins only cost tokens, so both keys are conservative. SCOPE OF A CLEAN REPORT: a single is only
"no join found by these two keys".

  python grocery/triage-group.py [--prefix 2026-09-24] [--queue grocery/triage-queue.json]
  python grocery/triage-group.py --selftest
Exit 0, 3 when the queue or the families file cannot be read. Last line: TRIAGE-GROUP-COMPLETE.
"""
# The self-test reads nothing but this file: its cases are literals, never the queue or the families file.
# gate-inputs: grocery\triage-group.py
import argparse
import json
import os
import re
import sys

SHARED_MIN = 40
BOILERPLATE_MAX = 2
HERE = os.path.dirname(os.path.abspath(__file__))
GRADED = re.compile(r'graded:\s*[0-9a-f]{7,40}[^\n]*')


def lines_of(body):
    out = set()
    for part in re.split(r'[\r\n]+|(?<=[.;])\s+|\s-\s', GRADED.sub('', body or '')):
        s = ' '.join(part.split())
        if len(s) >= SHARED_MIN:
            out.add(s)
    return out


def group(items, families=None):
    """items: list of (id, body[, type]) in queue order -> list of (primary, [members], [reasons])."""
    items = [(t[0], t[1], t[2] if len(t) > 2 else '') for t in items]
    fam_of = {}
    for name, types in (families or {}).items():
        for ty in types:
            fam_of[ty] = name
    ids = [i for i, _, _ in items]
    parent = {i: i for i in ids}
    why = {i: set() for i in ids}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def join(a, b, reason):
        ra, rb = find(a), find(b)
        if ra != rb:
            first, second = (ra, rb) if ids.index(ra) < ids.index(rb) else (rb, ra)
            parent[second] = first
        why[a].add(reason)
        why[b].add(reason)

    fams = {}
    shared = {}
    for i, body, ty in items:
        if ty in fam_of:
            fams.setdefault(fam_of[ty], []).append(i)
        for ln in lines_of(body):
            shared.setdefault(ln, []).append(i)
    for name, members in fams.items():
        for m in members[1:]:
            join(members[0], m, 'family:' + name)
    for ln, members in shared.items():
        if len(members) > BOILERPLATE_MAX:
            continue
        for m in members[1:]:
            join(members[0], m, 'shared-line')
    groups = {}
    for i in ids:
        groups.setdefault(find(i), []).append(i)
    out = []
    for i in ids:
        if find(i) == i:
            members = [m for m in groups[i] if m != i]
            reasons = sorted(set().union(*[why[m] for m in groups[i]])) if members else []
            out.append((i, members, reasons))
    return out


def selftest():
    res = []

    def case(label, ok, got):
        res.append((label, bool(ok), got))

    fam = {'board-not-shipped': ['pipeline could not push', 'watchdog not published']}
    items = [
        ('a', 'capture-run could not push. graded: 3c45a9478 at C:/x', 'pipeline could not push'),
        ('b', 'NOT PUBLISHED: board older. graded: 3c45a9478 at C:/x', 'watchdog not published'),
        ('c', 'summary line one\n- NEW-CONTESTED Inglehoffer Horseradish Cream Style 9.5 OZ | chain: horseradish', 'summary'),
        ('d', '- NEW-CONTESTED Inglehoffer Horseradish Cream Style 9.5 OZ | chain: horseradish\nFull report', 'crown'),
        ('e', 'an unrelated alert about a test that timed out under load on a busy box today', 'guard'),
        ('f', 'horseradish crown, same run. graded: 3c45a9478 at C:/x', 'soundness contested crown'),
    ]
    by = {p: m for p, m, _ in group(items, fam)}
    case('MUST FIRE: two types in one family are one group, primary the earlier (a <- b)', by.get('a') == ['b'], by.get('a'))
    case('MUST FIRE: a summary that repeats a condition line joins that item (c <- d)', by.get('c') == ['d'], by.get('c'))
    case('MUST NOT FIRE: an alert sharing nothing stays single (e)', by.get('e') == [], by.get('e'))
    case('MUST NOT FIRE: an alert sharing only the run stamp stays single (f, the 09-24 over-grouping)',
         by.get('f') == [], by.get('f'))
    short = [('x', 'push failed: see log'), ('y', 'push failed: see log')]
    gs = {p: m for p, m, _ in group(short)}
    case('BAR: a shared line under %d characters joins nothing (x, y single)' % SHARED_MIN,
         gs.get('x') == [] and gs.get('y') == [], gs)
    at = 'y' * SHARED_MIN
    ga = {p: m for p, m, _ in group([('p', at), ('q', at)])}
    case('BAR: a shared line of exactly %d characters joins (p <- q)' % SHARED_MIN, ga.get('p') == ['q'], ga)
    pad = 'the board was rebuilt but never shipped to readers today'
    trans = [('t1', pad, 'pipeline could not push'), ('t2', pad + '\nother', 'x'), ('t3', 'y', 'watchdog not published')]
    gt = {p: m for p, m, _ in group(trans, fam)}
    case('CLEAN TWIN: joins are transitive (t1 <- t2 by line, t1 <- t3 by family)',
         sorted(gt.get('t1') or []) == ['t2', 't3'], gt)
    boiler = 'Full watchdog report for 2026-09-24, healthy checks included: C:/x/log'
    gb = {p: m for p, m, _ in group([('w1', boiler), ('w2', boiler), ('w3', boiler)])}
    case('BAR: a line %d alerts carry is boilerplate and joins nothing (w1, w2, w3 single)' % (BOILERPLATE_MAX + 1),
         gb.get('w1') == [] and gb.get('w2') == [] and gb.get('w3') == [], gb)
    bad = [r for r in res if not r[1]]
    for label, ok, got in res:
        print('%s  %s%s' % ('PASS' if ok else 'FAIL', label, '' if ok else '  got=%r' % (got,)))
    if len(res) != 8:
        print('FAIL  ran %d case(s), expected 8' % len(res))
        bad.append(None)
    print('triage-group self-test %s (%d cases)' % ('pass' if not bad else 'FAIL', len(res)))
    return 0 if not bad else 1


def main():
    if '--selftest' in sys.argv:
        sys.exit(selftest())
    ap = argparse.ArgumentParser()
    ap.add_argument('--prefix', default='')
    ap.add_argument('--queue', default=os.path.join(HERE, 'triage-queue.json'))
    ap.add_argument('--families', default=os.path.join(HERE, 'triage-families.json'))
    a = ap.parse_args()
    try:
        q = json.load(open(a.queue, encoding='utf-8-sig'))
        families = json.load(open(a.families, encoding='utf-8-sig')).get('families') or {}
    except (OSError, ValueError) as e:
        print('triage-group: BLIND - could not read the queue or the families file: %s' % e)
        print('TRIAGE-GROUP-COMPLETE blind=input')
        sys.exit(3)
    items = q['items'] if isinstance(q, dict) else q
    todo = [(str(i.get('id')), str(i.get('body') or ''), str(i.get('type') or '')) for i in items
            if str(i.get('status')) == 'open' and str(i.get('id', '')).startswith(a.prefix)]
    groups = group(todo, families)
    joined = 0
    for p, members, reasons in groups:
        if members:
            joined += len(members)
            print('GROUP  %s <- %s  (%s)' % (p, ', '.join(members), ', '.join(reasons)))
        else:
            print('SINGLE %s' % p)
    print('triage-group: %d open alert(s) with prefix %r -> %d group(s); %d grouped under a primary' % (
        len(todo), a.prefix, len(groups), joined))
    print('TRIAGE-GROUP-COMPLETE alerts=%d groups=%d grouped=%d' % (len(todo), len(groups), joined))


if __name__ == '__main__':
    main()
