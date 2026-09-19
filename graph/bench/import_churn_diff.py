import sqlite3
import sys

a, b = sys.argv[1], sys.argv[2]
ca, cb = sqlite3.connect(a), sqlite3.connect(b)
ca.row_factory = cb.row_factory = sqlite3.Row


def rows(c, sql, key):
    return {tuple(r[k] for k in key): dict(r) for r in c.execute(sql)}


for name, sql, key in (
        ("cell_state", "SELECT * FROM cell_state", ("commodity_id", "store_id")),
        ("question_verdicts", "SELECT * FROM question_verdicts", ("commodity_id", "product_key"))):
    ra, rb = rows(ca, sql, key), rows(cb, sql, key)
    only_a = sorted(set(ra) - set(rb))
    only_b = sorted(set(rb) - set(ra))
    diff = [k for k in set(ra) & set(rb) if ra[k] != rb[k]]
    print("== %s: a=%d b=%d only_a=%d only_b=%d differ=%d" % (name, len(ra), len(rb), len(only_a),
                                                             len(only_b), len(diff)))
    for k in only_a[:10]:
        print("  only A", ra[k])
    for k in only_b[:10]:
        print("  only B", rb[k])
    for k in sorted(diff)[:15]:
        cols = [c for c in ra[k] if ra[k][c] != rb[k][c]]
        print("  differ", k, {c: (ra[k][c], rb[k][c]) for c in cols})

obs_sql = "SELECT id, commodity_id, store_id, product_name, price, price_type, observed_at, match_status, source_file FROM price_observations"
oa = rows(ca, obs_sql, ("id",))
ob = rows(cb, obs_sql, ("id",))
only_a = sorted(set(oa) - set(ob))
only_b = sorted(set(ob) - set(oa))
diff = [k for k in set(oa) & set(ob) if oa[k] != ob[k]]
print("== price_observations: a=%d b=%d only_a=%d only_b=%d differ=%d" % (len(oa), len(ob), len(only_a), len(only_b), len(diff)))
for k in only_a[:12]:
    print("  only A", oa[k])
for k in only_b[:12]:
    print("  only B", ob[k])
for k in sorted(diff)[:12]:
    cols = [c for c in oa[k] if oa[k][c] != ob[k][c]]
    print("  differ", k, {c: (oa[k][c], ob[k][c]) for c in cols})
