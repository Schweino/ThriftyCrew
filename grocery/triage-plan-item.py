"""triage-plan-item.py - read or update ONE item of a triage plan without reading the whole plan.

WHY THIS EXISTS (2026-09-24, design/PLAN-triage-lean-2026-09-24.md). Every API call an agent makes re-reads its whole
context, so a file read early is paid for again on every later call. On 2026-09-19 the developer read the whole plan
(56,189 characters, about 14k tokens) and then made about 140 more calls; the reviewer read the whole README (28,913
characters). Since 2026-09-24 a developer spawn works ONE item, so it needs that item and the plan's header, nothing
else.

  python grocery/triage-plan-item.py show   --plan <plan.json> --id <queue_id>
      prints the plan header (round, board_week, generated, lane, routing_artifact) and the one item, as JSON
  python grocery/triage-plan-item.py ids    --plan <plan.json>
      one line per item: queue_id, status, lane, est_tool_calls, publish_batch
  python grocery/triage-plan-item.py update --plan <plan.json> --id <queue_id> --json-file <fields.json>
      merges the top-level keys of <fields.json> into that item and writes the plan back (UTF-8, LF, indent 2)
  python grocery/triage-plan-item.py --selftest

Exit 0 ok, 1 refused (no such id, two items with the id, a bad fields file), 3 could not read the plan.
"""
# The self-test is hermetic (temp dirs and literals only), so it reads nothing but this file:
# gate-inputs: grocery\triage-plan-item.py
import argparse
import json
import os
import shutil
import sys
import tempfile

HEADER = ('generated', 'round', 'round_override', 'board_week', 'lane', 'routing_artifact', 'ship_sequence')


def load(path):
    with open(path, encoding='utf-8-sig') as fh:
        return json.load(fh)


def save(path, doc):
    tmp = path + '.tmp-' + str(os.getpid())
    with open(tmp, 'w', encoding='utf-8', newline='\n') as fh:
        json.dump(doc, fh, indent=2, ensure_ascii=False)
        fh.write('\n')
    os.replace(tmp, path)


def find(doc, qid):
    hits = [i for i in doc.get('items') or [] if str(i.get('queue_id')) == qid]
    return hits


def show(doc, qid):
    hits = find(doc, qid)
    if len(hits) != 1:
        return None, '%d item(s) carry queue_id %s' % (len(hits), qid)
    head = {k: doc[k] for k in HEADER if k in doc}
    return {'plan_header': head, 'item': hits[0]}, 'ok'


def update(doc, qid, fields):
    if not isinstance(fields, dict) or not fields:
        return False, 'the fields file must hold a non-empty JSON object'
    if 'queue_id' in fields and str(fields['queue_id']) != qid:
        return False, 'the fields may not change queue_id'
    hits = find(doc, qid)
    if len(hits) != 1:
        return False, '%d item(s) carry queue_id %s' % (len(hits), qid)
    hits[0].update(fields)
    return True, 'updated %s: %s' % (qid, ', '.join(sorted(fields)))


def selftest():
    res = []

    def case(label, ok, got):
        res.append((label, bool(ok), got))

    root = tempfile.mkdtemp(prefix='tpi-')
    try:
        plan = os.path.join(root, 'plan-2026-09-25.json')
        doc = {'generated': '2026-09-25T09:50:00', 'round': 1, 'board_week': '2026-09-24', 'queue_ids_seen': ['a', 'b'],
               'items': [{'queue_id': 'a', 'status': 'planned', 'lane': 'money', 'est_tool_calls': 40,
                          'evidence': ['x' * 5000]},
                         {'queue_id': 'b', 'status': 'planned', 'lane': 'ops', 'est_tool_calls': 20,
                          'root_cause': 'café row'}]}
        save(plan, doc)
        out, why = show(load(plan), 'b')
        text = json.dumps(out)
        case('MUST FIRE: show returns only the named item, never a sibling (b without a\'s 5000-char evidence)',
             out is not None and out['item']['queue_id'] == 'b' and 'xxxxx' not in text, why)
        case('CLEAN TWIN: show carries the plan header the item needs (round, board_week)',
             out is not None and out['plan_header'].get('round') == 1 and out['plan_header'].get('board_week') == '2026-09-24',
             out and out['plan_header'])
        out2, why2 = show(load(plan), 'zz')
        case('MUST FIRE: an id no item carries is refused', out2 is None and '0 item(s)' in why2, why2)
        d = load(plan)
        ok, why3 = update(d, 'a', {'status': 'done', 'shipped_commit': 'abc1234'})
        save(plan, d)
        d2 = load(plan)
        a = find(d2, 'a')[0]
        b = find(d2, 'b')[0]
        case('CLEAN TWIN: update merges fields into the one item and leaves the sibling and non-ASCII text intact',
             ok and a['status'] == 'done' and a['shipped_commit'] == 'abc1234' and b['status'] == 'planned'
             and b['root_cause'] == 'café row', (ok, a.get('status'), b.get('root_cause')))
        ok2, why4 = update(d2, 'a', {'queue_id': 'b'})
        case('MUST FIRE: an update may not rename the item', not ok2, why4)
        d2['items'].append({'queue_id': 'a'})
        ok3, why5 = update(d2, 'a', {'status': 'x'})
        case('MUST FIRE: two items with one id are refused, never guessed between', not ok3 and '2 item(s)' in why5, why5)
        raw = open(plan, 'rb').read()
        case('CLEAN TWIN: the plan is written LF with no BOM', b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf'),
             raw[:3])
    finally:
        shutil.rmtree(root, ignore_errors=True)
    bad = [r for r in res if not r[1]]
    for label, ok, got in res:
        print('%s  %s%s' % ('PASS' if ok else 'FAIL', label, '' if ok else '  got=%r' % (got,)))
    if len(res) != 7:
        print('FAIL  ran %d case(s), expected 7' % len(res))
        bad.append(None)
    print('triage-plan-item self-test %s (%d cases)' % ('pass' if not bad else 'FAIL', len(res)))
    return 0 if not bad else 1


def main():
    if '--selftest' in sys.argv:
        sys.exit(selftest())
    ap = argparse.ArgumentParser()
    ap.add_argument('mode', choices=['show', 'ids', 'update'])
    ap.add_argument('--plan', required=True)
    ap.add_argument('--id', default='')
    ap.add_argument('--json-file', default='')
    a = ap.parse_args()
    try:
        doc = load(a.plan)
    except (OSError, ValueError) as e:
        print('triage-plan-item: could not read %s: %s' % (a.plan, e))
        sys.exit(3)
    if a.mode == 'ids':
        for i in doc.get('items') or []:
            print('%-22s status=%-16s lane=%-6s est=%-4s batch=%s' % (
                i.get('queue_id'), i.get('status'), i.get('lane', '-'), i.get('est_tool_calls', '-'),
                i.get('publish_batch', '-')))
        sys.exit(0)
    if a.mode == 'show':
        out, why = show(doc, a.id)
        if out is None:
            print('triage-plan-item: REFUSED - ' + why)
            sys.exit(1)
        print(json.dumps(out, indent=2, ensure_ascii=False))
        sys.exit(0)
    try:
        fields = json.load(open(a.json_file, encoding='utf-8-sig'))
    except (OSError, ValueError) as e:
        print('triage-plan-item: REFUSED - could not read the fields file: %s' % e)
        sys.exit(1)
    ok, why = update(doc, a.id, fields)
    if not ok:
        print('triage-plan-item: REFUSED - ' + why)
        sys.exit(1)
    save(a.plan, doc)
    print('triage-plan-item: ' + why)
    sys.exit(0)


if __name__ == '__main__':
    main()
