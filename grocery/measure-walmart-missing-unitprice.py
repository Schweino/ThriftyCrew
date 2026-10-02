"""measure-walmart-missing-unitprice.py - W2 step 1 of design/PLAN-browser-refresh-hardening-2026-10-02.md.

A MEASUREMENT. It reads captures and boards and writes one jsonl of cases. It changes no pricing code and writes
nothing under grocery/out.

QUESTION. Over the last 14 days of Walmart captures, how many in-store rows (pickup at storeId 5361) carry a line
price but no Walmart unit price, how many of those have a size that parses unambiguously from their own name, and
how many board cells would a per-unit price derived from that size have changed the winner of?

ACCEPTANCE BAR (written before the run, copied verbatim from the plan's W2 section):
    "build W2 step 2 only if at least 5 distinct board cells over the 14 days would have changed winner."
Unit: distinct board cells (commodity ids) over the 14-day window, counted on the SAME-DAY arm (below).
"Changed winner" here means the derived row would have been the cheapest row for the cell: its derived per-unit
price is strictly below the board's published cheapest_price, or the cell had no priced winner at all. The subset
where the winning STORE also changes (the board winner was not Walmart) is reported beside it.

ARMS (one row per case per arm, ms-04):
  same-day      the board file named for the capture's own date (comparison-<D>.json). No such board: the day is a
                counted skip for this arm, never guessed.
  latest-prior  the newest board dated on or before the capture's date, at most 7 days back. Reported for context
                only; the verdict is read on same-day.

HOW A ROW IS CLASSIFIED (the rules are the builder's, read from grocery/walmart-row-lib.ps1):
  - line price: Build-Row's linePrice pattern. No line price: not a case.
  - no unit price: the up field matches neither Build-Row unit-price pattern (dollars or cents form).
  - in-store at 5361: the capture's #tc-store line reads id 5361, and the ff field is STORE with av=IN_STOCK and a
    pk= list naming 5361, and the title declares no "(N pack)" with N > 1 (Get-WalmartChannel's ship-only rule).
    A row with a plain "STORE" ff (no av/pk) cannot prove pickup at 5361 and is counted, not a case.
  - one case per (date, item id, line price): the same SKU returned by several search terms is one case.

SIZE FROM THE NAME (strict, refusal over guess): exactly one weight or volume size in the name; refused for a count
or pack token ("N ct", "N count", "N pk", "pack of", "(N pack)", "N x", "dozen", "1ea", ...), a range ("5-6 lb"),
a variable-weight cue ("per lb", "approx", "avg"), two different sizes, or no size.

COMMODITY MAPPING: compare-deals.ps1's Match-Category, ported line for line: commodities.json in file order, include
patterns tested against the raw lower-cased name and the normalized variant, the global exclude list
(Get-TcGlobalExclude in grocery/global-exclude-lib.ps1, parsed out of that file at run time, never copied here)
waived only by the commodity's relax_global, then the commodity's own excludes against the raw name. Python re with
IGNORECASE stands in for .NET -match; a pattern that does not compile makes every row it could have decided
UNMAPPABLE, counted. A commodity id the day's board does not carry is NOT-ON-BOARD, counted.

UNIT BASIS: the derived price is put on the board cell's own unit. Weight (oz, lb, g, kg) converts to oz/lb cells;
volume (fl oz, gal, qt, pt, l, ml) to floz/gallon cells. Anything else (each, dozen, sq_ft cells, or a weight size on
a volume cell and the reverse) is UNCOMPARABLE, counted.

WHAT A "would change" IS NOT. The engine also applies bands, guards and the provenance contract, which this harness
does not run, so would_change_winner is an upper bound on what step 2 could move.

READ ONLY: captures and boards are read by absolute path (they are gitignored, so a worktree has none) and never
written. Output: design/MEASURE-walmart-missing-unitprice-2026-10.jsonl, written LF.

Exit: 0 ran and wrote the rows; 3 could not evaluate (no capture in the window, or an input unreadable).
Last line: MEASURE-WALMART-MISSING-UNITPRICE-COMPLETE.

Run: C:/Codex/Python312/python.exe grocery/measure-walmart-missing-unitprice.py [--end YYYY-MM-DD] [--days 14]
"""
import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_OUT_ROOT = r'C:\Codex\ThriftyCrew\grocery\out'
STORE_ID = '5361'
MARKER = 'MEASURE-WALMART-MISSING-UNITPRICE-COMPLETE'

# Build-Row's patterns (walmart-row-lib.ps1), verbatim in meaning.
LP_RE = re.compile(r'\$\s*([\d,]+(?:\.\d{1,2})?)')
UP_DOLLAR_RE = re.compile(r'\$\s*([\d,]+(?:\.\d{1,3})?)\s*/\s*(.+)$')
UP_CENT_RE = re.compile(r'^\s*([\d,]+(?:\.\d{1,3})?)\s*[^\d/\s]{1,3}\s*/\s*(.+)$')
PACK_TITLE_RE = re.compile(r'(?i)\(\s*(\d+)\s*-?\s*pack\s*\)')

NUM = r'(\d+(?:\.\d+)?|\.\d+)'
UNIT_ALTS = [
    ('floz', r'fl\.?\s*oz\.?|fluid\s+ounces?'),
    ('oz', r'oz\.?|ounces?'),
    ('lb', r'lbs?\.?|pounds?'),
    ('kg', r'kg|kilograms?'),
    ('g', r'g|grams?'),
    ('gal', r'gal\.?|gallons?'),
    ('qt', r'qt\.?|quarts?'),
    ('pt', r'pt\.?|pints?'),
    ('ml', r'ml|milliliters?|millilitres?'),
    ('l', r'l|liters?|litres?'),
]
SIZE_RE = re.compile(r'(?<![\w.])' + NUM + r'\s*-?\s*(' + '|'.join('(?:%s)' % a for _, a in UNIT_ALTS) + r')(?![a-z])', re.I)
COUNT_RES = [
    re.compile(r'\b\d+\s*-?\s*(?:ct|count|pk|packs?|pcs?|pieces?|ea|each|rolls?|bags?|cans?|bottles?|cups?|pouches?|packets?|servings?|slices?|sticks?|links?|bars?|jars?)\b', re.I),
    re.compile(r'\bpack\s+of\s+\d+', re.I),
    re.compile(r'\b\d+\s*x\s*\d', re.I),
    re.compile(r'\bdozen\b', re.I),
    re.compile(r'\bmulti-?pack\b|\bvariety\s+pack\b', re.I),
]
RANGE_RE = re.compile(r'\d\s*(?:-|to)\s*\d+(?:\.\d+)?\s*(?:lbs?|oz|pounds?|ounces?)\b', re.I)
VARIABLE_RE = re.compile(r'\bper\s+(?:lb|pound)\b|\bapprox|\baverage\b|\bavg\b|\bpriced\s+per\b', re.I)

WEIGHT_OZ = {'oz': 1.0, 'lb': 16.0, 'g': 1 / 28.349523125, 'kg': 1000 / 28.349523125}
VOLUME_FLOZ = {'floz': 1.0, 'gal': 128.0, 'qt': 32.0, 'pt': 16.0, 'ml': 1 / 29.5735295625, 'l': 1000 / 29.5735295625}
BOARD_WEIGHT = {'oz': 1.0, 'lb': 16.0}
BOARD_VOLUME = {'floz': 1.0, 'gallon': 128.0}


def unit_key(tok):
    for key, alt in UNIT_ALTS:
        if re.fullmatch(alt, tok.strip(), re.I):
            return key
    return None


def git_blob(path):
    data = open(path, 'rb').read()
    return hashlib.sha1(b'blob %d\0' % len(data) + data).hexdigest()


def sha256(path):
    return hashlib.sha256(open(path, 'rb').read()).hexdigest()


def parse_global_exclude(path):
    """Get-TcGlobalExclude's single-quoted strings, comments stripped quote-aware. Parsed, never copied."""
    src = open(path, encoding='utf-8-sig').read()
    m = re.search(r'function\s+Get-TcGlobalExclude\s*\{(.*?)\n\}', src, re.S)
    if not m:
        raise RuntimeError('Get-TcGlobalExclude not found in ' + path)
    out = []
    for line in m.group(1).splitlines():
        i, inq, buf = 0, False, ''
        while i < len(line):
            ch = line[i]
            if inq:
                if ch == "'" and i + 1 < len(line) and line[i + 1] == "'":
                    buf += "'"; i += 2; continue
                if ch == "'":
                    out.append(buf); buf = ''; inq = False
                else:
                    buf += ch
            else:
                if ch == '#':
                    break
                if ch == "'":
                    inq = True
            i += 1
    return out


class Matcher:
    """compare-deals.ps1 Match-Category, ported."""

    def __init__(self, commodities, global_exclude):
        self.bad_patterns = []
        self.glob = []
        for g in global_exclude:
            self.glob.append((g, self._c(g, '<global>')))
        self.coms = []
        for c in commodities:
            inc = [self._c(p, c['id']) for p in (c.get('include') or []) if p is not None]
            exc = [self._c(p, c['id']) for p in (c.get('exclude') or []) if p is not None]
            relax = [p for p in (c.get('relax_global') or []) if p is not None]
            self.coms.append((c, inc, exc, relax))

    def _c(self, p, owner):
        try:
            return re.compile(p, re.I)
        except re.error as e:
            self.bad_patterns.append((owner, p, str(e)))
            return None

    @staticmethod
    def texts(name):
        n = name.lower()
        v = re.sub(r',?\s*priced per\s+\w+', '', n)
        v = re.sub(r'\s{2,}', ' ', re.sub(r'\band\b', ' ', v)).strip()
        return [n, v]

    def match(self, name):
        """Returns (commodity or None, uncertain_reason or None)."""
        texts = self.texts(name)
        n = texts[0]
        if any(rx is None for _, rx in self.glob):
            return None, 'a global exclude pattern did not compile in Python'
        ghits = [g for g, rx in self.glob if rx.search(n)]
        for c, inc, exc, relax in self.coms:
            if any(rx is None for rx in inc):
                return None, 'include pattern of ' + c['id'] + ' did not compile in Python'
            hit = any(rx.search(t) for rx in inc for t in texts)
            if not hit:
                continue
            if ghits:
                relax_l = [r.lower() for r in relax]
                if any(g.lower() not in relax_l for g in ghits):
                    continue
            if any(rx is None for rx in exc):
                return None, 'exclude pattern of ' + c['id'] + ' did not compile in Python'
            if any(rx.search(n) for rx in exc):
                continue
            return c, None
        return None, None


def parse_size(name):
    """Returns (qty, unitkey, refusal). Exactly one of (qty,unit) or refusal is set."""
    for rx in COUNT_RES:
        m = rx.search(name)
        if m:
            return None, None, 'count or pack token "' + m.group(0).strip() + '"'
    if PACK_TITLE_RE.search(name):
        return None, None, 'pack title'
    m = RANGE_RE.search(name)
    if m:
        return None, None, 'size range "' + m.group(0) + '"'
    m = VARIABLE_RE.search(name)
    if m:
        return None, None, 'variable-weight cue "' + m.group(0) + '"'
    sizes = []
    for m in SIZE_RE.finditer(name):
        k = unit_key(m.group(2))
        if k is None:
            continue
        q = float(m.group(1))
        if (q, k) not in sizes:
            sizes.append((q, k))
    if not sizes:
        return None, None, 'no size in the name'
    if len(sizes) > 1:
        return None, None, 'two sizes ' + ' / '.join('%g %s' % s for s in sizes)
    q, k = sizes[0]
    if q <= 0:
        return None, None, 'zero size'
    return q, k, None


def to_board_unit(q, k, board_unit):
    if board_unit in BOARD_WEIGHT and k in WEIGHT_OZ:
        return q * WEIGHT_OZ[k] / BOARD_WEIGHT[board_unit]
    if board_unit in BOARD_VOLUME and k in VOLUME_FLOZ:
        return q * VOLUME_FLOZ[k] / BOARD_VOLUME[board_unit]
    return None


def read_capture(path):
    """Yields dicts with the 9 columns plus store_id from the governing #tc-store line."""
    store = ''
    header = None
    with open(path, encoding='utf-8-sig') as fh:
        for line in fh:
            line = line.rstrip('\r\n')
            if line.startswith('#tc-store'):
                m = re.search(r'\bid="([^"]*)"', line)
                store = m.group(1) if m else ''
                header = None
                continue
            if line.startswith('q|n|'):
                header = line.split('|')
                continue
            if not line or header is None:
                continue
            parts = line.split('|')
            if len(parts) != len(header):
                yield {'_malformed': True}
                continue
            row = dict(zip(header, parts))
            row['_store'] = store
            yield row


def shelf(ff):
    parts = ff.split(';')
    out = {'f': parts[0].strip().upper(), 'av': '', 'pk': []}
    for kv in parts[1:]:
        kv = kv.strip()
        if kv.lower().startswith('av='):
            out['av'] = kv[3:].strip().upper()
        elif kv.lower().startswith('pk='):
            out['pk'] = [x.strip() for x in kv[3:].split(',') if x.strip()]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out-root', default=DEFAULT_OUT_ROOT, help='grocery/out of the MAIN checkout, read only')
    ap.add_argument('--end', default=None, help='last capture date in the window (default: newest capture)')
    ap.add_argument('--days', type=int, default=14)
    ap.add_argument('--jsonl', default=os.path.join(REPO, 'design', 'MEASURE-walmart-missing-unitprice-2026-10.jsonl'))
    a = ap.parse_args()

    cap_dir = os.path.join(a.out_root, 'captures')
    caps = {}
    for p in glob.glob(os.path.join(cap_dir, 'walmart-capture-*.csv')):
        m = re.search(r'walmart-capture-(\d{4}-\d{2}-\d{2})\.csv$', p)
        if m:
            caps[m.group(1)] = p
    boards = {}
    for p in glob.glob(os.path.join(a.out_root, 'comparison-*.json')):
        m = re.search(r'comparison-(\d{4}-\d{2}-\d{2})\.json$', p)
        if m:
            boards[m.group(1)] = p
    if not caps:
        print('COULD NOT EVALUATE: no walmart-capture-*.csv under ' + cap_dir)
        print(MARKER + ' exit=3')
        return 3
    end = dt.date.fromisoformat(a.end) if a.end else max(dt.date.fromisoformat(d) for d in caps)
    window = [(end - dt.timedelta(days=i)).isoformat() for i in range(a.days - 1, -1, -1)]

    com_path = os.path.join(HERE, 'commodities.json')
    gex_path = os.path.join(HERE, 'global-exclude-lib.ps1')
    commodities = json.load(open(com_path, encoding='utf-8-sig'))
    matcher = Matcher(commodities, parse_global_exclude(gex_path))
    print('harness  grocery/measure-walmart-missing-unitprice.py blob ' + git_blob(os.path.abspath(__file__)))
    print('input    grocery/commodities.json blob ' + git_blob(com_path) + ' (' + str(len(commodities)) + ' commodities)')
    print('input    grocery/global-exclude-lib.ps1 blob ' + git_blob(gex_path) + ' (' + str(len(matcher.glob)) + ' global patterns)')
    print('patterns that did not compile in Python: ' + str(len(matcher.bad_patterns)))
    for b in matcher.bad_patterns:
        print('  BAD ' + repr(b))
    print('window   ' + window[0] + ' .. ' + window[-1] + ' (' + str(len(window)) + ' days)')

    board_cache = {}

    def load_board(d):
        if d not in board_cache:
            b = json.load(open(boards[d], encoding='utf-8-sig'))
            board_cache[d] = {c['id']: c for c in b['comparison']}
        return board_cache[d]

    def prior_board(d):
        dd = dt.date.fromisoformat(d)
        for i in range(0, 8):
            k = (dd - dt.timedelta(days=i)).isoformat()
            if k in boards:
                return k
        return None

    rows_out = []
    day_notes = []
    for d in window:
        if d not in caps:
            day_notes.append((d, 'SKIP no capture', {}))
            print('day ' + d + ': SKIP no capture')
            continue
        cpath = caps[d]
        tally = {'rows': 0, 'malformed': 0, 'no_lp': 0, 'has_up': 0, 'store_line_not_5361': 0,
                 'no_shelf_signal': 0, 'not_in_store_5361': 0, 'cases_raw': 0}
        cases = {}
        for r in read_capture(cpath):
            if r.get('_malformed'):
                tally['malformed'] += 1
                continue
            tally['rows'] += 1
            lpm = LP_RE.search(r.get('lp', ''))
            if not lpm:
                tally['no_lp'] += 1
                continue
            up = r.get('up', '')
            if UP_DOLLAR_RE.search(up) or UP_CENT_RE.search(up):
                tally['has_up'] += 1
                continue
            if r['_store'] != STORE_ID:
                tally['store_line_not_5361'] += 1
                continue
            sh = shelf(r.get('ff', ''))
            if not sh['av'] and not sh['pk']:
                tally['no_shelf_signal'] += 1
                continue
            pm = PACK_TITLE_RE.search(r.get('n', ''))
            in_store = (sh['f'] == 'STORE' and sh['av'] == 'IN_STOCK' and STORE_ID in sh['pk']
                        and not (pm and int(pm.group(1)) > 1))
            if not in_store:
                tally['not_in_store_5361'] += 1
                continue
            tally['cases_raw'] += 1
            lp = float(lpm.group(1).replace(',', ''))
            key = (r.get('id', '') or r.get('n', ''), lp)
            if key not in cases:
                cases[key] = {'name': r.get('n', ''), 'line_price': lp, 'item_id': r.get('id', ''), 'terms': []}
            if r.get('q', '') not in cases[key]['terms']:
                cases[key]['terms'].append(r.get('q', ''))
        tally['cases'] = len(cases)
        csha = sha256(cpath)[:12]
        print('day %s: rows=%d no_lp=%d has_up=%d store_line_not_5361=%d no_shelf_signal=%d not_in_store_5361=%d '
              'in_store_no_up_rows=%d cases(distinct sku+price)=%d capture_sha256=%s'
              % (d, tally['rows'], tally['no_lp'], tally['has_up'], tally['store_line_not_5361'],
                 tally['no_shelf_signal'], tally['not_in_store_5361'], tally['cases_raw'], len(cases), csha))
        day_notes.append((d, 'read', tally))

        for arm in ('same-day', 'latest-prior'):
            bd = d if (arm == 'same-day' and d in boards) else (prior_board(d) if arm == 'latest-prior' else None)
            if bd is None:
                print('  arm %s: SKIP no board for %s (%d case(s) not judged)' % (arm, d, len(cases)))
            for c in cases.values():
                q, k, refusal = parse_size(c['name'])
                row = {'arm': arm, 'date': d, 'capture_file': os.path.basename(cpath), 'capture_sha256_12': csha,
                       'board_file': ('comparison-' + bd + '.json') if bd else None,
                       'item_id': c['item_id'], 'terms': c['terms'], 'name': c['name'], 'line_price': c['line_price'],
                       'parsed_size': q, 'parsed_unit': k, 'derived_unit_price': None, 'board_unit': None,
                       'commodity': None, 'board_winner_store': None, 'board_winner_unit_price': None,
                       'would_change_winner': None, 'winner_store_changes': None, 'outcome': None, 'reason': None}
                if refusal:
                    row['outcome'] = 'SIZE-REFUSED'
                    row['reason'] = refusal
                    rows_out.append(row)
                    continue
                com, unsure = matcher.match(c['name'])
                if unsure:
                    row['outcome'] = 'UNMAPPABLE'
                    row['reason'] = unsure
                    rows_out.append(row)
                    continue
                if com is None:
                    row['outcome'] = 'UNMAPPABLE'
                    row['reason'] = 'Match-Category matches no commodity (no include hit, or excluded)'
                    rows_out.append(row)
                    continue
                row['commodity'] = com['id']
                if bd is None:
                    row['outcome'] = 'NO-BOARD'
                    row['reason'] = 'no board for this arm on ' + d
                    rows_out.append(row)
                    continue
                cell = load_board(bd).get(com['id'])
                if cell is None:
                    row['outcome'] = 'NOT-ON-BOARD'
                    row['reason'] = 'commodity ' + com['id'] + ' has no cell on ' + row['board_file']
                    rows_out.append(row)
                    continue
                bu = cell.get('unit') or com.get('unit')
                row['board_unit'] = bu
                row['board_winner_store'] = cell.get('cheapest_store') or None
                row['board_winner_unit_price'] = cell.get('cheapest_price')
                qb = to_board_unit(q, k, bu)
                if qb is None or qb <= 0:
                    row['outcome'] = 'UNCOMPARABLE'
                    row['reason'] = 'name size in %s cannot be put on the cell unit %s' % (k, bu)
                    rows_out.append(row)
                    continue
                dup = c['line_price'] / qb
                row['derived_unit_price'] = round(dup, 4)
                wp = cell.get('cheapest_price')
                if not row['board_winner_store'] or wp in (None, 0):
                    row['would_change_winner'] = True
                    row['winner_store_changes'] = True
                    row['outcome'] = 'COMPARED'
                    row['reason'] = 'cell has no priced winner; the derived row would fill it'
                else:
                    beats = dup < float(wp) - 1e-9
                    row['would_change_winner'] = beats
                    row['winner_store_changes'] = bool(beats and row['board_winner_store'] != 'Walmart')
                    row['outcome'] = 'COMPARED'
                    row['reason'] = ('derived %.4f/%s %s board %.4f/%s (%s)'
                                     % (dup, bu, 'beats' if beats else 'does not beat', float(wp), bu,
                                        row['board_winner_store']))
                rows_out.append(row)

    os.makedirs(os.path.dirname(a.jsonl), exist_ok=True)
    with open(a.jsonl, 'w', encoding='utf-8', newline='\n') as fh:
        for r in rows_out:
            fh.write(json.dumps(r, ensure_ascii=False) + '\n')

    # TOTALS, DERIVED FROM THE ROWS JUST WRITTEN (re-read from the file, ms-04).
    rows = [json.loads(l) for l in open(a.jsonl, encoding='utf-8')]
    print('wrote %d row(s) to %s' % (len(rows), os.path.relpath(a.jsonl, REPO).replace('\\', '/')))
    read_days = [d for d, s, _ in day_notes if s == 'read']
    print('days with a capture: %d of %d; skipped (no capture): %s'
          % (len(read_days), len(window), ', '.join(d for d, s, _ in day_notes if s != 'read') or 'none'))
    for arm in ('same-day', 'latest-prior'):
        ar = [r for r in rows if r['arm'] == arm]
        n = len(ar)
        print('ARM ' + arm + ': cases %d' % n)
        if not n:
            continue
        by = {}
        for r in ar:
            by[r['outcome']] = by.get(r['outcome'], 0) + 1
        for k in sorted(by):
            print('  %-13s %d of %d (%.0f%%)' % (k, by[k], n, 100.0 * by[k] / n))
        parsed = [r for r in ar if r['outcome'] != 'SIZE-REFUSED']
        comp = [r for r in ar if r['outcome'] == 'COMPARED']
        win = [r for r in comp if r['would_change_winner']]
        stw = [r for r in comp if r['winner_store_changes']]
        print('  size parsed: %d of %d cases' % (len(parsed), n))
        print('  compared: %d of %d parsed; would change winning row: %d of %d compared; '
              'winning store changes: %d of %d compared' % (len(comp), len(parsed), len(win), len(comp), len(stw), len(comp)))
        cells = sorted(set(r['commodity'] for r in win))
        scells = sorted(set(r['commodity'] for r in stw))
        judged_days = sorted(set(r['date'] for r in ar if r['board_file']))
        print('  board-judged days: %d of %d capture days' % (len(judged_days), len(read_days)))
        print('  DISTINCT cells whose winning row would change: %d %s' % (len(cells), cells))
        print('  DISTINCT cells whose winning store would change: %d %s' % (len(scells), scells))
        if arm == 'same-day':
            print('  VERDICT vs bar (>= 5 distinct cells, same-day arm): ' + ('MET' if len(cells) >= 5 else 'NOT MET'))
    print(MARKER + ' exit=0')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as e:
        print('COULD NOT EVALUATE: ' + type(e).__name__ + ': ' + str(e))
        print(MARKER + ' exit=3')
        sys.exit(3)
