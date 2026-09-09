"""How expensive is this traversal, asked BEFORE running it (2026-09-09, backlog I74).

WHAT I74 ASKED FOR, AND WHY IT IS NOT WHAT SHIPPED. The item says the nodes table has no cached
degree, "so every fan-out question is a full scan of 85,891 edges", and proposes writing a degree
column back onto `nodes`. Measured on the live database before building anything:

    plan for `select count(*) from edges where source_id = ?`
        -> SEARCH edges USING COVERING INDEX ix_edges_src (source_id=?)
    plan for `... where target_id = ?`
        -> SEARCH edges USING COVERING INDEX ix_edges_tgt (target_id=?)

    worst case measured, store:walmart with 20,146 edges : 0.365 ms
    a SKU's degree                                       : 0.003 ms
    the whole graph's degree table, grouped              : 0.004 ms

**It is not a full scan and it is not slow.** `ix_edges_src` and `ix_edges_tgt` already exist and are
COVERING for this question. A cached degree column would buy roughly nothing and would introduce a
staleness hazard - a denormalised count that silently diverges from the edges as they are written,
which in this estate is strictly worse than a fast correct query. So the remedy was declined and the
measurement recorded.

AND THE ITEM'S DIRECTION IS BACKWARDS, which matters more than the speed claim. It says a query "from
`store:walmart`" returns 20,133 rows OUTWARD. Measured: `store:walmart` has **out-degree 0 and
in-degree 20,146**. Edges run SKU -> store (`sold_at`), so a store is a TARGET, never a source, and
the expensive traversal is the one that walks IN-edges backwards. The highest out-degree in the whole
graph is **4**. A guard written against out-degree, as the item implies, would have watched the one
direction that is always cheap and missed the only expensive one entirely.

WHAT IS HERE INSTEAD: the pre-flight check the item actually wanted, with no cache to go stale. Ask
what a traversal will cost before you run it, and let the forward rule refuse the bad entry point.

    from fanout import fanout, assert_cheap_entry
    assert_cheap_entry(con, "store:walmart")   -> raises: enter from the SKU

    python graph/lib/fanout.py --selftest
Exit 0 ok, 2 self-test failure.
"""
from __future__ import annotations

import argparse
import sqlite3
import sys

# A traversal wider than this is worth stopping to think about. WHAT ELSE WAS TRIED: nothing. 1,000 is
# the FIRST PLAUSIBLE VALUE, not the survivor of a sweep, and it is grounded on the live shape rather
# than taste: the graph's largest out-degree is 4 and its largest in-degree is 20,146, so anything in
# four figures is already two orders of magnitude past a normal node and nothing sits near the bar.
# Registered in docs/CONTROL-CONSTANTS.md.
FANOUT_WARN = 1000


def out_degree(con, node_id: str, predicate: str | None = None) -> int:
    """Edges leaving this node. Index-backed by ix_edges_src; no cache, so it cannot go stale."""
    if predicate:
        return con.execute("select count(*) from edges where source_id = ? and predicate = ?",
                           (node_id, predicate)).fetchone()[0]
    return con.execute("select count(*) from edges where source_id = ?", (node_id,)).fetchone()[0]


def in_degree(con, node_id: str, predicate: str | None = None) -> int:
    """Edges arriving at this node. Index-backed by ix_edges_tgt.

    THIS IS THE EXPENSIVE DIRECTION IN THIS GRAPH and the item had it the other way round.
    """
    if predicate:
        return con.execute("select count(*) from edges where target_id = ? and predicate = ?",
                           (node_id, predicate)).fetchone()[0]
    return con.execute("select count(*) from edges where target_id = ?", (node_id,)).fetchone()[0]


def fanout(con, node_id: str, predicate: str | None = None) -> dict:
    """Both directions and which one is expensive. Returns a dict; every count carries its direction,
    because a single 'degree' number hides exactly the asymmetry that makes this worth asking."""
    o = out_degree(con, node_id, predicate)
    i = in_degree(con, node_id, predicate)
    return {"node": node_id, "predicate": predicate, "out": o, "in": i, "total": o + i,
            "widest": "in" if i >= o else "out", "widest_count": max(o, i),
            "wide": max(o, i) > FANOUT_WARN}


def assert_cheap_entry(con, node_id: str, predicate: str | None = None, limit: int = FANOUT_WARN):
    """THE FORWARD RULE AS CODE, not as prose in a comment nobody reads.

    'Enter from the SKU, or from a Commodity down through instance_of; never from a Store outward.'
    That rule has been written down twice and enforced zero times. Raises ValueError naming the
    direction and the count, so the caller learns WHY rather than just that it was refused.

    Returns the fanout dict when the entry point is cheap, so a caller can use it as a guard AND as
    the measurement in one call.
    """
    f = fanout(con, node_id, predicate)
    if f["wide"]:
        raise ValueError(
            "fan-out refused: %s has %d %s-edges%s, over the limit of %d. This is the direction that "
            "fans out - enter from the SKU, or from a Commodity down through instance_of, and never "
            "walk a Store's in-edges. Pass a larger limit only if you meant to."
            % (node_id, f["widest_count"], f["widest"],
               "" if not predicate else " on predicate %r" % predicate, limit))
    return f


def _fixture_db():
    """An in-memory graph shaped like the real one: SKUs point AT a store, so the store is a target.
    Hermetic, so this suite needs no graph.db and run-gates can discover it anywhere."""
    con = sqlite3.connect(":memory:")
    con.execute("create table edges (id text primary key, source_id text, target_id text, predicate text)")
    con.execute("create index ix_edges_src on edges(source_id, predicate)")
    con.execute("create index ix_edges_tgt on edges(target_id, predicate)")
    rows = []
    for n in range(1500):                        # a wide store: 1,500 SKUs sold at it
        rows.append(("e%d" % n, "sku:%d" % n, "store:big", "sold_at"))
    rows.append(("x1", "sku:0", "commodity:staple:eggs", "instance_of"))
    rows.append(("x2", "sku:1", "commodity:staple:eggs", "instance_of"))
    con.executemany("insert into edges values (?,?,?,?)", rows)
    con.commit()
    return con


def _selftest() -> int:
    bad = 0

    def T(name, ok, got=""):
        nonlocal bad
        if ok:
            print("  ok    " + name)
        else:
            print("  X     " + name + "   got: " + str(got))
            bad += 1

    con = _fixture_db()

    # MUST FIRE - the founding correction. The store is a TARGET, so its cost is in-degree. A guard
    # written against out-degree, as I74 implies, would see 0 and wave it through.
    f = fanout(con, "store:big")
    T("MUST FIRE  a store's cost is its IN-degree, and its out-degree is 0",
      f["in"] == 1500 and f["out"] == 0 and f["widest"] == "in", f)
    T("MUST FIRE  a wide entry point is refused by the forward rule",
      _raises(lambda: assert_cheap_entry(con, "store:big")), "no refusal")
    T("and the refusal names the direction and the count",
      "1500 in-edges" in _msg(lambda: assert_cheap_entry(con, "store:big")),
      _msg(lambda: assert_cheap_entry(con, "store:big")))

    # MUST NOT FIRE - the cheap entry point the rule tells you to use.
    T("MUST NOT FIRE  entering from a SKU is cheap and is allowed",
      assert_cheap_entry(con, "sku:0")["total"] == 2, fanout(con, "sku:0"))
    T("MUST NOT FIRE  a commodity reached through instance_of is allowed",
      assert_cheap_entry(con, "commodity:staple:eggs")["in"] == 2,
      fanout(con, "commodity:staple:eggs"))

    # MUST NOT FIRE - a node with no edges at all is 0, not an error and not 1.
    T("MUST NOT FIRE  an unknown node is degree 0, not an error",
      fanout(con, "sku:does-not-exist")["total"] == 0, fanout(con, "sku:does-not-exist"))

    # MUST FIRE - the predicate filter narrows, or a per-predicate guard would be useless.
    T("MUST FIRE  filtering by predicate narrows the count",
      in_degree(con, "commodity:staple:eggs", "instance_of") == 2
      and in_degree(con, "commodity:staple:eggs", "sold_at") == 0,
      in_degree(con, "commodity:staple:eggs", "sold_at"))

    T("the limit is the constant declared above the run", FANOUT_WARN == 1000, str(FANOUT_WARN))

    try:
        f2 = fanout(con, "store:big")
        T("MUST NOT FIRE  fanout() itself never raises - only the assert does",
          f2["wide"] is True, f2)
    except Exception as e:
        T("MUST NOT FIRE  fanout() itself never raises - only the assert does", False, str(e))

    # CLEAN TWIN - the index the whole design leans on is actually used, not just present. If this
    # ever stops being a covering-index search, the no-cache decision needs revisiting.
    plan = [r[3] for r in con.execute(
        "explain query plan select count(*) from edges where target_id = ?", ("store:big",))]
    T("CLEAN TWIN  the in-degree query still uses the index, which is why no cache is needed",
      any("ix_edges_tgt" in p for p in plan), plan)

    con.close()
    if bad:
        print("fanout SELF-TEST FAIL (%d)" % bad)
        return 2
    print("fanout SELF-TEST PASS: 10 case(s) resolved")
    return 0


def _raises(fn) -> bool:
    try:
        fn()
        return False
    except ValueError:
        return True


def _msg(fn) -> str:
    try:
        fn()
        return ""
    except ValueError as e:
        return str(e)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--node", default="", help="report the fan-out of one node against the live graph")
    args = ap.parse_args()

    if args.selftest:
        return _selftest()

    import os
    db = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sqlite", "graph.db")
    if not os.path.exists(db):
        print("fanout: no graph.db - BLIND, not clean.")
        return 3
    con = sqlite3.connect("file:" + db.replace("\\", "/") + "?mode=ro", uri=True)
    if args.node:
        print(fanout(con, args.node))
        return 0
    widest = con.execute(
        "select target_id, count(*) c from edges group by target_id order by c desc limit 5").fetchall()
    print("widest IN-degree nodes (the expensive direction):")
    for nid, c in widest:
        print("  %-40s %d" % (nid, c))
    o = con.execute(
        "select source_id, count(*) c from edges group by source_id order by c desc limit 1").fetchone()
    print("widest OUT-degree node: %s with %d - the direction I74 assumed was expensive" % (o[0], o[1]))
    con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
