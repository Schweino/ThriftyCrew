"""Propose labels for the Family Fare flyer-line set, from the evidence file, for Brad to review.

D5 of design/PLAN-link-rides-with-price-2026-09-27.md; the Hy-Vee set it mirrors is grocery/hyvee/flyer-link-gold.jsonl.
A Family Fare flyer line is Freshop's own offer, so it carries the product's exact store name. The proposed label is the
ONE candidate whose name equals the line and whose sale_price text equals the flyer text; anything else is left as
UNSURE for a person, never guessed. A line whose search failed is not labelled yet (the collector retries it).
Run after collect-flyer-link-evidence.ps1 (the collector, 30 lines a day inside Freshop's budget).
Writes one row per line; existing rows for other lines are kept, so two collection days merge.
"""
import json, re, sys
from collections import OrderedDict

ev_path, gold_path = sys.argv[1], sys.argv[2]
norm = lambda s: re.sub(r'\s+', ' ', re.sub(r'[^a-z0-9$/ .]', ' ', (s or '').lower())).strip()
lines = OrderedDict()
for l in open(ev_path, encoding='utf-8'):
    if l.strip():
        r = json.loads(l)
        lines.setdefault((r['line'], r['ad']), []).append(r)
gold = OrderedDict()
try:
    for l in open(gold_path, encoding='utf-8'):
        if l.strip():
            g = json.loads(l)
            gold[(g['line'], g['ad'])] = g
except FileNotFoundError:
    pass
new = 0
for (line, ad), rs in lines.items():
    cands = [r for r in rs if r['kind'] == 'candidate']
    if not cands:
        continue
    hit = [r for r in cands if norm(r['name']) == norm(line) and norm(r['sale_price']) == norm(ad)]
    same_sale = [r for r in cands if norm(r['sale_price']) == norm(ad)]
    if len(hit) == 1:
        label, ids = hit[0]['product_id'], [hit[0]['product_id']]
        why = 'the one product whose store name equals the line and whose sale text equals the flyer; ' + str(len(same_sale)) + ' product(s) share the flyer text'
        ev = [hit[0]['product_id'] + ' "' + hit[0]['name'] + '" ' + hit[0]['size_field'] + ', sale ' + hit[0]['sale_price'] + ', regular ' + str(hit[0]['base_price'])]
    else:
        label, ids = 'UNSURE', []
        why = str(len(hit)) + ' candidate(s) match name and sale text; needs a person'
        ev = [r['product_id'] + ' "' + r['name'] + '" sale ' + (r['sale_price'] or '-') for r in same_sale[:6]]
    key = (line, ad)
    if key not in gold or gold[key].get('labels', '').startswith('proposed'):
        gold[key] = OrderedDict([('store', 'Family Fare'), ('commodity', cands[0]['commodity']), ('line', line), ('ad', ad),
                                 ('label', label), ('product_ids', ids), ('why', why), ('evidence', ev),
                                 ('labels', 'proposed, awaiting Brad review'),
                                 ('source', 'proposed ' + cands[0]['read_day'] + ' by label_flyer_gold.py over ' + ev_path.replace('\\', '/').split('/')[-1] + ' (Freshop store 6401), BEFORE any linker ran on it')])
        new += 1
with open(gold_path, 'w', encoding='utf-8', newline='\n') as f:
    for g in gold.values():
        f.write(json.dumps(g) + '\n')
lab = [g for g in gold.values()]
print('family-fare flyer gold: %d line(s) held, %d written this run; labelled %d, UNSURE %d' % (
    len(lab), new, sum(1 for g in lab if g['label'] != 'UNSURE'), sum(1 for g in lab if g['label'] == 'UNSURE')))
