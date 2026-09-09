#!/usr/bin/env python
"""audit_graph_shape.py - the graph's SHAPE, which no row-level check can see.

SCOPE OF A CLEAN REPORT: SOUND over the nodes and edges tables as they stand. It reads every row,
  so a clean report really does mean no node is orphaned and no cut-point is unguarded at this
  instant. It says nothing about whether the edges that exist are CORRECT - that is the row-level
  checks' job, and they pass on exactly the rows this finds.

WHY THIS EXISTS (2026-09-09, backlog I73, I75 and I76).
Nothing is wrong with any individual row here, so every row-level data-quality check passes. A
degree-0 node is only visible as a property of the GRAPH, and a grep for
`networkx|centrality|betweenness|connected component|shortest path|in-degree|adjacency` over the
whole tree returns NO first-party graph analytics at all. Three questions, one pass:

  I73  ORPHANS AND ISLANDS. Nodes joined to nothing, and the components they sit in.
       It is the right FIRST graph check because it has NO THRESHOLD TO ARGUE ABOUT: the correct
       value is zero or an explanation, which makes it ratchet-shaped rather than a gate that is
       red on day one.

  I75  CUT POINTS. Retiring a commodity id is a GRAPH CUT, and both gates that guard it reason
       about NAMES: `retire_food_db_row.py` greps zero for edges/degree/connect, and the
       commodity-registrar rules on names and duplicates. Neither counts what an id actually JOINS.
       This states the estate's cross-store pricing premise as a measurable property rather than a
       belief.

  I76  VALENCE. Edges per node over time. Every freshness and volume check in this estate counts
       ROWS, and none of them can see a query getting slower because a region DENSIFIED rather than
       grew.

IT RATCHETS ON *STRUCTURAL* ORPHANS, NOT ON THE RAW COUNT (2026-09-09, queue 2026-09-09-c2c10b).
The first version ratcheted the raw degree-0 count, and its own founding commit already said the
real number was six: 199 of the 205 were `CategoryExclude` nodes, a type that joins nothing BY
CONSTRUCTION. So every wrong-class pattern the estate added to its exclude library became +1 orphan
AND +1 component (a degree-0 node is its own singleton) the next morning, the watchdog paged, and
the only way to clear it was a human typing --accept. The estate added four exclude classes in
seven days - sausage 09-02, cheese and cracker 09-04, steam-bag 09-08 - so the guard's cadence
could not keep up with the estate's own rule-adding cadence, and the six real orphans were
invisible under the noise. The raw figures are still MEASURED and still PRINTED; they are simply
reported rather than gated. See BY_CONSTRUCTION_ORPHAN_TYPES.

IT IS A RATCHET, NOT A GATE, and the direction is chosen per question - see BASELINE below. It is
read-only on the database (opened `mode=ro`) and writes only its own baseline file.

EXIT CODES: 0 clean or baseline written, 2 a hard finding, 3 could-not-evaluate. Read the verdict
LINE, not the number.

Self-test: python graph/audit_graph_shape.py --selftest   (pure, no database needed)
"""
from __future__ import annotations

import argparse
import collections
import io
import json
import os
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DB = os.path.join(REPO, "graph", "sqlite", "graph.db")
BASELINE = os.path.join(HERE, "graph-shape-baseline.json")

# The two node types the estate's cross-store pricing premise rests on. Named here rather than
# discovered, because the CLAIM is about these two specifically.
CUT_TYPES = ("Store", "Commodity")

# Node types that are degree 0 BY CONSTRUCTION, so a new one of them is not a new island.
#
# NAMED, NEVER DISCOVERED. "Every node of this type happens to have no edges today" is a
# measurement; "this type is not supposed to have edges" is a claim about the model, and only the
# second one earns an exclusion from the ratchet. Discovering the set would launder any type that
# happened to be fully orphaned this morning into a permanent blind spot.
#
# CategoryExclude: an exclude is a statement about what must NOT match, so it joins nothing.
#   graph/import/importers.py:455 upserts it with `db.upsert_node(xid, "CategoryExclude", ...)` and
#   creates no edge; graph/pipeline/resolve.py:301 only SELECTs the rows back out by type. Measured
#   2026-09-09 against graph/sqlite/graph.db: 201 of 201 are degree 0, and every one has been since
#   the day it was created.
#
# THE CLAIM IS ITSELF CHECKED. judge() reports a type in this set that has GAINED an edge as a
# model change and fails on it, because at that moment the exclusion above is no longer earned.
# IngredientMapping is deliberately NOT here: 348 of its 352 nodes have edges, so its 4 orphans are
# the small real thing the founding commit named, and they stay ratcheted.
BY_CONSTRUCTION_ORPHAN_TYPES = ("CategoryExclude",)


def components(nodes, edges):
    """Weakly connected components over an undirected view. Returns {node: component_id}.

    Pure and iterative - a recursive flood fill over 48,000 nodes blows the stack, and finding that
    out from a RecursionError inside a gate is a worse way to learn it than a comment.
    """
    adj = collections.defaultdict(list)
    for a, b in edges:
        adj[a].append(b)
        adj[b].append(a)
    seen = {}
    cid = 0
    for n in nodes:
        if n in seen:
            continue
        cid += 1
        stack = [n]
        seen[n] = cid
        while stack:
            cur = stack.pop()
            for nxt in adj.get(cur, ()):
                if nxt not in seen:
                    seen[nxt] = cid
                    stack.append(nxt)
    return seen


def degrees(nodes, edges):
    """node -> total degree, counting both directions. Every node in `nodes` gets an entry, so a
    node touched by NO edge scores 0 rather than being absent - the whole point of I73."""
    d = {n: 0 for n in nodes}
    for a, b in edges:
        if a in d:
            d[a] += 1
        if b in d:
            d[b] += 1
    return d


def shatter(nodes, edges, drop):
    """How many components remain once `drop` is removed. The cut-point measurement (I75)."""
    keep = [n for n in nodes if n not in drop]
    kept = set(keep)
    e = [(a, b) for a, b in edges if a in kept and b in kept]
    comp = components(keep, e)
    return len(set(comp.values())), comp


def measure(nodes, edges, ntype):
    """The whole shape of a graph as one dict, pure. main() and the self-test both go through here,
    so a self-test case exercises the SAME arithmetic the live run does rather than a copy of it.

    `structural_*` are the ratcheted figures; the raw ones are kept beside them and reported.
    """
    deg = degrees(nodes, edges)
    comp = components(nodes, edges)
    sizes = collections.Counter(comp.values())
    orphans = [n for n, d in deg.items() if d == 0]
    ncomp = len(sizes)

    # A degree-0 node is always its own singleton component, so the by-construction orphan count IS
    # the number of by-construction singleton components. Subtracting one from each figure keeps the
    # two numbers talking about the same nodes.
    structural_orphans = sorted(n for n in orphans
                                if ntype.get(n) not in BY_CONSTRUCTION_ORPHAN_TYPES)
    by_construction = len(orphans) - len(structural_orphans)

    # The tripwire under the constant: any node of a by-construction type that carries an edge.
    edged = {}
    for t in BY_CONSTRUCTION_ORPHAN_TYPES:
        edged[t] = sum(1 for n in nodes if ntype.get(n) == t and deg.get(n, 0) > 0)

    return {
        "nodes": len(nodes),
        "edges": len(edges),
        "orphans": len(orphans),
        "components": ncomp,
        "largest": max(sizes.values()) if sizes else 0,
        "valence": round(len(edges) / float(len(nodes)), 4) if nodes else 0.0,
        "structural_orphans": len(structural_orphans),
        "structural_components": ncomp - by_construction,
        "structural_orphan_ids": structural_orphans,
        "by_construction_orphans": by_construction,
        "by_construction_edged": edged,
        "_deg": deg,
        "_comp": comp,
        "_sizes": sizes,
        "_orphans": orphans,
    }


def judge(cur, base, names=None):
    """The verdict, as a list of FAIL strings. PURE - no database, no clock, no printing - so the
    self-test can drive it with the real failing rows rather than approximating them.

    An empty list is a pass. `names` maps node id -> (type, canonical_name) and is used only to
    NAME a new orphan in the verdict: the founding version stored counts alone, so every rise cost
    somebody a full re-derivation to find out WHICH node was new. That re-derivation is what queue
    item 2026-09-09-c2c10b was.
    """
    names = names or {}
    fails = []

    # The by-construction claim is a claim. If the type ever gains an edge, the exclusion above is
    # unearned and the model moved under the constant - that is a finding, not a quiet adjustment.
    for t in sorted((cur.get("by_construction_edged") or {})):
        n = cur["by_construction_edged"][t]
        if n:
            fails.append("%s has %d node(s) with edges - the by-construction claim moved, so its "
                         "exclusion from the ratchet is no longer earned; re-read "
                         "BY_CONSTRUCTION_ORPHAN_TYPES before accepting anything" % (t, n))

    # A baseline written before the structural split cannot be compared against. Say so out loud and
    # require --accept: reading it as a pass would silently un-ratchet the whole check.
    if "structural_orphans" not in base or "structural_components" not in base:
        fails.append("BASELINE SHAPE CHANGED: the recorded baseline carries no structural_orphans / "
                     "structural_components, so it predates the by-construction split and there is "
                     "nothing to ratchet against. Read the figures, then re-record with --accept")
        return fails

    if cur["structural_orphans"] > base["structural_orphans"]:
        fails.append("structural orphans rose %d -> %d"
                     % (base["structural_orphans"], cur["structural_orphans"]))
        new_ids = sorted(set(cur.get("structural_orphan_ids") or ())
                         - set(base.get("structural_orphan_ids") or ()))
        for nid in new_ids:
            t, cn = names.get(nid, ("?", "?"))
            fails.append("NEW structural orphan: %s  %s  %s" % (nid, t, cn))
    if cur["structural_components"] > base["structural_components"]:
        fails.append("structural components rose %d -> %d"
                     % (base["structural_components"], cur["structural_components"]))
    return fails


def _fixture_graph(new_node_type):
    """FROZEN FROM THE REAL ROWS of graph/sqlite/graph.db at 2026-09-09 08:21:32 (queue
    2026-09-09-c2c10b): 207 degree-0 nodes in 215 components, of which 201 are CategoryExclude.

    `new_node_type` is the type given to the two steam-bag-carrier nodes the 08:21 import created.
    Their real type is CategoryExclude - pass 'Commodity' to get the same two ids as REAL orphans,
    which is the must-fire. Returns (nodes, edges, ntype, names).
    """
    nodes, edges, ntype, names = [], [], {}, {}

    def add(nid, typ, canonical):
        nodes.append(nid)
        ntype[nid] = typ
        names[nid] = (typ, canonical)

    # the giant component, standing in for the 48,091 real ones
    core = ["core:%02d" % i for i in range(10)]
    for c in core:
        add(c, "ProductSKU", c)
    edges.extend((core[i], core[i + 1]) for i in range(len(core) - 1))

    # the seven islands of two
    for i in range(7):
        a, b = "isle:%d:a" % i, "isle:%d:b" % i
        add(a, "ProductSKU", a)
        add(b, "Commodity", b)
        edges.append((a, b))

    # the SIX structural orphans, real ids, unchanged since the founding commit 2d2f67c0e
    for nid, cn in (("ingmap:6b4cc6ad6d397e2cd4e0", "93/7 Ground Beef"),
                    ("ingmap:648e7dc851fb4ffe2447", "Beef Chuck Roast"),
                    ("ingmap:310c6469154d4983769f", "Green Bell Peppers"),
                    ("ingmap:ada1dd054ef795e7ec2b", "Penne Pasta")):
        add(nid, "IngredientMapping", cn)
    add("commodity:recipe:colby-jack-cheese", "Commodity", "colby jack cheese")
    add("commodity:recipe:fat-free-mozzarella", "Commodity", "fat free mozzarella")

    # the 199 CategoryExclude nodes that predate today
    for i in range(199):
        nid = "catexclude:prior:%03d" % i
        add(nid, "CategoryExclude", "prior pattern %d" % i)

    # and the two the 08:00 capture's import created at 08:21:21, from commit 5a9c2dfee
    add("catexclude:steam-bag-carrier:bc94ace29898", new_node_type,
        r"\bsteam(?:ers?|ables?|fresh|crisp)\b")
    add("catexclude:steam-bag-carrier:78199a12cdbf", new_node_type, r"\bsauced\b")
    return nodes, edges, ntype, names


def selftest():
    fails = []
    ran = []

    def T(name, cond, got=""):
        ran.append(name)
        print(("  ok    " if cond else "  X     ") + name + ("" if cond else "   got: %s" % (got,)))
        if not cond:
            fails.append(name)

    # a---b---c   d(alone)   e---f
    nodes = ["a", "b", "c", "d", "e", "f"]
    edges = [("a", "b"), ("b", "c"), ("e", "f")]

    d = degrees(nodes, edges)
    T("MUST FIRE  THE FOUNDING CASE - a node touched by no edge scores 0 and is not simply absent",
      d["d"] == 0 and set(d) == set(nodes), d)
    T("MUST NOT FIRE  a node with edges scores its real degree, both directions counted",
      d["b"] == 2 and d["a"] == 1, d)

    comp = components(nodes, edges)
    T("MUST FIRE  a lone node is its OWN component, so islands are countable",
      len(set(comp.values())) == 3, sorted(set(comp.values())))
    T("CLEAN TWIN a chain a-b-c is ONE component, not three",
      comp["a"] == comp["b"] == comp["c"], (comp["a"], comp["b"], comp["c"]))

    # removing the middle of the chain shatters it
    n2, _ = shatter(nodes, edges, {"b"})
    T("MUST FIRE  removing a CUT POINT shatters the graph - a-b-c becomes two isolated nodes",
      n2 == 4, n2)      # a, c, d, and {e,f}
    n3, _ = shatter(nodes, edges, {"a"})
    T("MUST NOT FIRE  removing a LEAF does not shatter anything - the count only drops by its own node",
      n3 == 3, n3)

    T("CLEAN TWIN an empty graph has no components and no degrees, rather than one of each",
      len(components([], [])) == 0 and degrees([], []) == {}, "")
    big = [str(i) for i in range(5000)]
    chain = [(str(i), str(i + 1)) for i in range(4999)]
    T("CLEAN TWIN a 5,000-node chain resolves to ONE component without blowing the stack",
      len(set(components(big, chain).values())) == 1, "")

    # ---- the structural split, frozen from the real 2026-09-09 rows (queue 2026-09-09-c2c10b) ----
    BASE = {"orphans": 205, "components": 213,
            "structural_orphans": 6, "structural_components": 14,
            "structural_orphan_ids": sorted([
                "ingmap:6b4cc6ad6d397e2cd4e0", "ingmap:648e7dc851fb4ffe2447",
                "ingmap:310c6469154d4983769f", "ingmap:ada1dd054ef795e7ec2b",
                "commodity:recipe:colby-jack-cheese", "commodity:recipe:fat-free-mozzarella"])}
    NEW_A = "catexclude:steam-bag-carrier:bc94ace29898"
    NEW_B = "catexclude:steam-bag-carrier:78199a12cdbf"

    # (1) MUST FIRE - the same two ids, at degree 0, typed as something that is NOT by construction.
    n, e, ty, nm = _fixture_graph("Commodity")
    bad = measure(n, e, ty)
    v = judge(bad, BASE, nm)
    joined = "; ".join(v)
    T("MUST FIRE  two real degree-0 nodes of a NOT-by-construction type raise the structural count",
      "structural orphans rose 6 -> 8" in joined, joined)
    T("MUST FIRE  the verdict NAMES both new ids, so a rise costs a read and not a re-derivation",
      NEW_A in joined and NEW_B in joined, joined)
    T("MUST FIRE  a structural component rise is reported beside the orphan rise",
      "structural components rose 14 -> 16" in joined, joined)

    # (2) MUST NOT FIRE - the identical fixture with the two nodes at their REAL type. The raw
    #     figures still read 207/215; only the ratcheted ones are quiet.
    n, e, ty, nm = _fixture_graph("CategoryExclude")
    good = measure(n, e, ty)
    T("MUST NOT FIRE  the same two ids at their real CategoryExclude type do not move the ratchet",
      judge(good, BASE, nm) == [], judge(good, BASE, nm))
    T("MUST NOT FIRE  the RAW figures are still measured and still read 207 orphans / 215 components",
      good["orphans"] == 207 and good["components"] == 215,
      (good["orphans"], good["components"]))
    T("MUST NOT FIRE  the structural figures are the six real orphans in fourteen components",
      good["structural_orphans"] == 6 and good["structural_components"] == 14
      and good["by_construction_orphans"] == 201,
      (good["structural_orphans"], good["structural_components"],
       good["by_construction_orphans"]))

    # (3) MUST FIRE - the constant's own tripwire. Join one CategoryExclude node into the core and
    #     the by-construction claim has moved, so the exclusion is no longer earned.
    n, e, ty, nm = _fixture_graph("CategoryExclude")
    e = list(e) + [("core:00", "catexclude:prior:000")]
    moved = judge(measure(n, e, ty), BASE, nm)
    T("MUST FIRE  a by-construction node that GAINS an edge is reported as a model change",
      any("by-construction claim moved" in f and f.startswith("CategoryExclude has 1 ")
          for f in moved), moved)

    # (4) MUST FIRE - a baseline from before the split has nothing to compare against and must never
    #     read as a pass. This is the shape the live baseline was in when this fix shipped.
    old_shape = judge(good, {"orphans": 205, "components": 213}, nm)
    T("MUST FIRE  a pre-split baseline reports BASELINE SHAPE CHANGED rather than passing silently",
      len(old_shape) == 1 and old_shape[0].startswith("BASELINE SHAPE CHANGED"), old_shape)

    # (5) CLEAN TWIN - the adjacent behaviour this change was most likely to break: I75 still reads
    #     the same graph, and a baseline compared against itself is quiet.
    n, e, ty, nm = _fixture_graph("CategoryExclude")
    cut = {x for x in n if ty.get(x) == "Commodity"}
    n_after, _ = shatter(n, e, cut)
    # 9 Commodity nodes leave: the 7 island-b halves, which strands 7 island-a singletons, plus the
    # 2 orphan recipe commodities. 215 - 9 + 7 = 213, and the core chain is still one component.
    T("CLEAN TWIN the I75 cut-point measurement is untouched - dropping the fixture's 9 Commodity "
      "nodes strands the 7 island halves and leaves 213 components, from 215",
      len(cut) == 9 and n_after == 213, (len(cut), n_after))
    T("CLEAN TWIN a graph judged against a baseline recorded FROM IT reports nothing at all",
      judge(good, good, nm) == [], judge(good, good, nm))

    if fails:
        print("SELF-TEST FAIL: %d of %d case(s)" % (len(fails), len(ran)))
        return 1
    print("SELF-TEST PASS: %d case(s) - must-fire led by the founding one (a node with no edges "
          "scores 0 rather than vanishing), the cut-point shatter, the two real steam-bag-carrier "
          "ids raising the structural count and naming themselves, a by-construction type that "
          "gained an edge, and a pre-split baseline that must not read as a pass; must-not-fire "
          "including the leaf that shatters nothing and those same two ids at their real "
          "CategoryExclude type; clean twins over chains, the empty graph, a 5,000-node iterative "
          "flood fill, the I75 shatter and a baseline compared with itself" % len(ran))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--db", default=DB)
    ap.add_argument("--accept", action="store_true",
                    help="record today's figures as the new baseline")
    a = ap.parse_args()
    if a.selftest:
        return selftest()

    if not os.path.exists(a.db):
        print("GRAPH SHAPE AUDIT BLIND: no database at %s, so nothing was examined. That is "
              "could-not-evaluate, never 'the graph is clean'." % a.db)
        print("GRAPH-SHAPE-COMPLETE blind=no-db")
        return 3

    db = sqlite3.connect("file:%s?mode=ro" % a.db.replace("\\", "/"), uri=True)
    db.row_factory = sqlite3.Row
    nodes = [r["id"] for r in db.execute("SELECT id FROM nodes")]
    ntype = {r["id"]: r["type"] for r in db.execute("SELECT id, type FROM nodes")}
    edges = [(r["source_id"], r["target_id"])
             for r in db.execute("SELECT source_id, target_id FROM edges")]
    if not nodes:
        print("GRAPH SHAPE AUDIT BLIND: the nodes table is empty. Nothing was examined.")
        print("GRAPH-SHAPE-COMPLETE blind=no-nodes")
        return 3

    cname = {r["id"]: r["canonical_name"]
             for r in db.execute("SELECT id, canonical_name FROM nodes")}
    names = {nid: (ntype.get(nid, "?"), cname.get(nid, "")) for nid in nodes}

    cur = measure(nodes, edges, ntype)
    deg, comp, sizes, orphans = cur["_deg"], cur["_comp"], cur["_sizes"], cur["_orphans"]
    ncomp = cur["components"]
    largest = cur["largest"]
    islands = sorted(v for v in sizes.values() if v > 1 and v < largest)

    print("GRAPH SHAPE  %d nodes, %d edges" % (len(nodes), len(edges)))
    print()
    print("I73  ORPHANS AND ISLANDS")
    print("  nodes with degree 0            : %d of %d" % (len(orphans), len(nodes)))
    print("  weakly connected components    : %d" % ncomp)
    print("  largest component              : %d of %d nodes (%.1f%%)"
          % (largest, len(nodes), 100.0 * largest / len(nodes)))
    print("  components of 2 or more, apart from the largest: %d  sizes %s"
          % (len(islands), islands[:12] if islands else "-"))
    if orphans:
        bytype = collections.Counter(ntype.get(n, "?") for n in orphans)
        print("  orphans by node type           : %s"
              % ", ".join("%s=%d" % kv for kv in bytype.most_common()))
    # THE RATCHETED FIGURES, printed beside the raw ones so the two are never confused. Only these
    # two move the verdict; the four lines above are measured and reported.
    print("  RATCHETED structural orphans   : %d of %d  (the other %d are %s, degree 0 by "
          "construction)"
          % (cur["structural_orphans"], len(orphans), cur["by_construction_orphans"],
             "/".join(BY_CONSTRUCTION_ORPHAN_TYPES)))
    print("  RATCHETED structural components: %d of %d" % (cur["structural_components"], ncomp))

    print()
    print("I76  VALENCE - edges per node, which no row count can see")
    valence = len(edges) / float(len(nodes))
    print("  edges per node                 : %.4f" % valence)

    print()
    print("I75  CUT POINTS - what the cross-store pricing premise actually rests on")
    for t in CUT_TYPES:
        drop = {n for n in nodes if ntype.get(n) == t}
        if not drop:
            print("  %-10s not present in this graph - not scored" % t)
            continue
        n_after, _ = shatter(nodes, edges, drop)
        print("  remove the %-4d %-10s node(s) -> %d component(s), from %d"
              % (len(drop), t, n_after, ncomp))
    print("  FORWARD RULE, and it is free: enter from the SKU, or from a Commodity down through")
    print("  instance_of. NEVER from a Store outward - one Store fans out tens of thousands of ways.")

    # ---- the ratchet ----
    record = {k: v for k, v in cur.items() if not k.startswith("_")}
    base = None
    if os.path.exists(BASELINE):
        try:
            base = json.load(io.open(BASELINE, encoding="utf-8-sig"))
        except Exception:
            base = None
    if base is None or a.accept:
        io.open(BASELINE, "w", encoding="utf-8", newline="\n").write(
            json.dumps({"note": "I73/I75/I76 ratchet. structural_orphans and structural_components "
                                "may only go DOWN or stay; a RISE is a new island nobody explained, "
                                "and the verdict NAMES the node. `orphans`, `components`, `nodes`, "
                                "`edges` and `largest` are the RAW figures - measured and reported, "
                                "never gated, because CategoryExclude is degree 0 by construction "
                                "and a new exclude pattern is not a new island (queue "
                                "2026-09-09-c2c10b). valence is REPORTED too - it is expected to "
                                "rise, and the number exists so a slower query can be attributed to "
                                "densification rather than to growth.",
                        "recorded": record}, indent=2) + "\n")
        print()
        print("BASELINE WRITTEN at %d structural orphan(s) and %d structural component(s), from a "
              "raw %d and %d. These are on the record and are silent from here; a RISE fails."
              % (record["structural_orphans"], record["structural_components"], len(orphans), ncomp))
        print("GRAPH-SHAPE-COMPLETE orphans=%d components=%d structural_orphans=%d "
              "structural_components=%d valence=%.4f"
              % (len(orphans), ncomp, record["structural_orphans"],
                 record["structural_components"], valence))
        return 0

    b = base.get("recorded", {})
    bad = judge(record, b, names)
    print()
    print("  against the baseline: structural orphans %s -> %s, structural components %s -> %s"
          % (b.get("structural_orphans"), record["structural_orphans"],
             b.get("structural_components"), record["structural_components"]))
    print("  reported only, never gated: orphans %s -> %s, components %s -> %s, valence %s -> %s"
          % (b.get("orphans"), record["orphans"], b.get("components"), record["components"],
             b.get("valence"), record["valence"]))
    if bad:
        for m in bad:
            print("  FAIL  " + m)
        print("GRAPH SHAPE AUDIT FAILED: %s. A new island is a node the graph stopped being able to "
              "reach, and no row-level check can see it. Explain it or fix it; --accept records a "
              "deliberate rise." % "; ".join(bad))
        print("GRAPH-SHAPE-COMPLETE orphans=%d components=%d structural_orphans=%d "
              "structural_components=%d valence=%.4f FAIL"
              % (len(orphans), ncomp, record["structural_orphans"],
                 record["structural_components"], valence))
        return 2
    print("graph-shape: PASSED - structural orphans and components have not risen.")
    print("GRAPH-SHAPE-COMPLETE orphans=%d components=%d structural_orphans=%d "
          "structural_components=%d valence=%.4f"
          % (len(orphans), ncomp, record["structural_orphans"],
             record["structural_components"], valence))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
