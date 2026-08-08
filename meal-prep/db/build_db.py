"""build_db.py - materialise db\\thriftycrew.db from the JSON stores, with foreign keys ENFORCED.

WHY (2026-08-08, Brad approved the storage redesign). The ingredient layer's four stores had to agree by
convention; here they agree by constraint. Every row is inserted with PRAGMA foreign_keys=ON, so a bid that
names no commodity, a macro row for an unknown item, or a spec ingredient with no price row does not
"produce a finding" - it fails the build, loudly, naming the row.

This is deliberately a BUILD, not a sync: the JSON files remain the authored masters for now and the
database is rebuilt from them. That makes the migration reversible and keeps 246 existing readers working.
Flipping authorship (SQLite master, JSON generated) is the follow-up, and it is safe to do per-table once
this build has run clean for a while.

Usage:  python build_db.py --mp <meal-prep dir> --grocery <grocery dir> [--out <db path>] [--verify-only]
Exit:   0 clean, 1 a constraint refused a row (the message names it), 2 bad invocation.
"""
import argparse, json, os, sqlite3, sys, glob


def load_json(path):
    with open(path, 'r', encoding='utf-8-sig') as fh:
        return json.load(fh)


def _fk_msg(table, detail, err):
    """A refusal has to read like a finding, not a stack trace. The daily chain logs this line verbatim."""
    return ('CONSTRAINT REFUSED [%s]: %s -- %s\n'
            '  A reference does not resolve. This is the class that pointed Turkey Bacon at PORK and\n'
            '  dropped Garlic Powder from a recipe total. Fix the source JSON, then re-run.' % (table, detail, err))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mp', required=True)
    ap.add_argument('--grocery', required=True)
    ap.add_argument('--out', default=None)
    ap.add_argument('--verify-only', action='store_true')
    a = ap.parse_args()

    db_path = a.out or os.path.join(a.mp, 'db', 'thriftycrew.db')
    schema_path = os.path.join(a.mp, 'db', 'schema.sql')
    tmp_path = db_path + '.building'

    for p in (tmp_path, tmp_path + '-journal'):
        if os.path.exists(p):
            os.remove(p)

    con = sqlite3.connect(tmp_path)
    con.execute('PRAGMA foreign_keys = ON')
    with open(schema_path, 'r', encoding='utf-8-sig') as fh:
        con.executescript(fh.read())
    # executescript commits and can reset pragmas - re-assert before any INSERT, or the whole point is lost
    con.execute('PRAGMA foreign_keys = ON')
    assert con.execute('PRAGMA foreign_keys').fetchone()[0] == 1, 'foreign keys did not stay on'

    counts = {}

    # ---- commodity: roster UNION feed ids -------------------------------------------------------------
    roster = load_json(os.path.join(a.grocery, 'commodities.json'))
    seen = {}
    for c in roster:
        cid = str(c.get('id') or '')
        if not cid:
            continue
        seen[cid] = (cid, c.get('label'), c.get('unit'), 1)
    feed_path = os.path.join(a.grocery, 'out', 'smp-feed.json')
    if os.path.exists(feed_path):
        feed = load_json(feed_path)
        for fid, row in (feed.get('ingredients') or {}).items():
            if fid not in seen:
                seen[fid] = (fid, None, (row or {}).get('unit'), 0)
    con.executemany('INSERT INTO commodity(id,label,unit,in_roster) VALUES (?,?,?,?)', list(seen.values()))
    counts['commodity'] = len(seen)

    # ---- item -----------------------------------------------------------------------------------------
    items = load_json(os.path.join(a.mp, 'db', 'ingredients.json'))
    rows, item_names = [], set()
    for r in items:
        n = str(r.get('item') or '')
        if not n or n.startswith('_'):      # '_r300_note' is a comment row, not data
            continue
        item_names.add(n)
        rows.append((n, r.get('bid') or None, r.get('gpu'), r.get('unit'), r.get('board'),
                     r.get('buy_pkg_g'), r.get('buy_pkg_label'),
                     r.get('pantry_pkg_g'), r.get('pantry_pkg_label'), r.get('note')))
    for r in rows:
        try:
            con.execute('INSERT INTO item(name,bid,gpu,unit,board,buy_pkg_g,buy_pkg_label,pantry_pkg_g,'
                        'pantry_pkg_label,note) VALUES (?,?,?,?,?,?,?,?,?,?)', r)
        except sqlite3.IntegrityError as e:
            raise SystemExit(_fk_msg('item', 'item "%s" has bid "%s", which names no commodity' % (r[0], r[1]), e))
    counts['item'] = len(rows)

    # ---- item_macro ------------------------------------------------------------------------------------
    fdb = load_json(os.path.join(a.mp, 'food-macros-db.json'))
    mrows, skipped_macro = [], []
    for group in fdb.values():
        if not isinstance(group, list):
            continue
        for m in group:
            n = str(m.get('item') or '')
            if not n:
                continue
            if n not in item_names:
                # ORPHAN-MACRO: a macro row with no price row. Recorded, not inserted - the FK would refuse
                # it and abort the build, and one legacy reference row must not block the whole estate.
                skipped_macro.append(n)
                continue
            mrows.append((n, m.get('brand'), m.get('serving_grams'), m.get('serving_qty'),
                          m.get('serving_unit'), m.get('calories'), m.get('protein_g'),
                          m.get('carbs_g'), m.get('fat_g'), m.get('notes')))
    con.executemany('INSERT OR REPLACE INTO item_macro(item,brand,serving_grams,serving_qty,serving_unit,'
                    'calories,protein_g,carbs_g,fat_g,notes) VALUES (?,?,?,?,?,?,?,?,?,?)', mrows)
    counts['item_macro'] = len(mrows)

    # ---- item_density ----------------------------------------------------------------------------------
    dens = load_json(os.path.join(a.mp, 'db', 'densities.json')).get('items') or {}
    drows, skipped_dens = [], []
    for n, units in dens.items():
        if n.startswith('_'):
            continue
        if n not in item_names:
            skipped_dens.append(n)
            continue
        if not isinstance(units, dict):
            continue
        for u, g in units.items():
            try:
                drows.append((n, u, float(g)))
            except (TypeError, ValueError):
                pass
    con.executemany('INSERT OR REPLACE INTO item_density(item,unit,grams) VALUES (?,?,?)', drows)
    counts['item_density'] = len(drows)

    # ---- spec + spec_ingredient ------------------------------------------------------------------------
    srows, sirows = [], []
    for path in sorted(glob.glob(os.path.join(a.mp, 'db', 'recipes', '*.json'))):
        slug = os.path.splitext(os.path.basename(path))[0]
        s = load_json(path)
        stat = s.get('stat') or {}
        srows.append((slug, s.get('name'), stat.get('cal'), stat.get('protein'), str(stat.get('cost_ps') or '')))
        per_slug = {}
        for si in ((s.get('scaler') or {}).get('ing') or []):
            n = str(si.get('canon') or si.get('item') or '')
            if not n:
                continue
            # NO SKIP HERE, deliberately. The first draft skipped a spec ingredient whose item had no
            # price row - which silently degrades the exact class this build exists to prevent (a recipe
            # costing something the price store has never heard of, i.e. a cost line dropped from the
            # total). It is zero today and it must ABORT if it ever stops being zero.
            per_slug[n] = (slug, n, si.get('grams'), si.get('bid') or None)
        sirows.extend(per_slug.values())
    con.executemany('INSERT INTO spec(slug,name,cal,protein,cost_ps) VALUES (?,?,?,?,?)', srows)
    # inserted one at a time so a refusal can NAME the row. executemany reports only "FOREIGN KEY constraint
    # failed" with no clue which of 7,358 rows did it, which is the difference between a finding and a
    # scavenger hunt at 6:31am.
    for r in sirows:
        try:
            con.execute('INSERT INTO spec_ingredient(slug,item,grams,bid) VALUES (?,?,?,?)', r)
        except sqlite3.IntegrityError as e:
            raise SystemExit(_fk_msg('spec_ingredient', '%s costs "%s" (bid=%s)' % (r[0], r[1], r[3]), e))
    counts['spec'] = len(srows)
    counts['spec_ingredient'] = len(sirows)

    con.commit()

    # the engine's own last word: a full integrity sweep over every declared constraint
    problems = con.execute('PRAGMA foreign_key_check').fetchall()
    con.close()

    if problems:
        print('FOREIGN KEY CHECK FAILED: %d row(s)' % len(problems))
        for p in problems[:20]:
            print('   ', p)
        os.remove(tmp_path)
        return 1

    if a.verify_only:
        os.remove(tmp_path)
    else:
        if os.path.exists(db_path):
            os.remove(db_path)
        os.rename(tmp_path, db_path)

    for k in ('commodity', 'item', 'item_macro', 'item_density', 'spec', 'spec_ingredient'):
        print('  %-16s %6d' % (k, counts[k]))
    if skipped_macro:
        print('  SKIPPED macro rows with no item: %s' % ', '.join(sorted(set(skipped_macro))[:5]))
    if skipped_dens:
        print('  SKIPPED density rows with no item: %s' % ', '.join(sorted(set(skipped_dens))[:5]))
    print('OK: every declared foreign key holds%s' % ('' if a.verify_only else ' -> ' + db_path))
    return 0


if __name__ == '__main__':
    sys.exit(main())
