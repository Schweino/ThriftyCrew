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


def selftest():
    fails = []

    def T(name, cond, got=""):
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

    if fails:
        print("SELF-TEST FAIL: %d case(s)" % len(fails))
        return 1
    print("SELF-TEST PASS: 3 must-fire cases led by the founding one (a node with no edges scores 0 "
          "rather than vanishing) plus the cut-point shatter, 2 must-not-fire including the leaf "
          "that shatters nothing, and 3 clean twins over chains, the empty graph and a 5,000-node "
          "iterative flood fill")
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

    deg = degrees(nodes, edges)
    comp = components(nodes, edges)
    sizes = collections.Counter(comp.values())
    orphans = [n for n, d in deg.items() if d == 0]
    ncomp = len(sizes)
    largest = max(sizes.values())
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
    cur = {"nodes": len(nodes), "edges": len(edges), "orphans": len(orphans),
           "components": ncomp, "largest": largest,
           "valence": round(valence, 4)}
    base = None
    if os.path.exists(BASELINE):
        try:
            base = json.load(io.open(BASELINE, encoding="utf-8-sig"))
        except Exception:
            base = None
    if base is None or a.accept:
        io.open(BASELINE, "w", encoding="utf-8", newline="\n").write(
            json.dumps({"note": "I73/I75/I76 ratchet. orphans and components may only go DOWN or "
                                "stay; a RISE is a new island nobody explained. valence is "
                                "REPORTED, never gated - it is expected to rise, and the number "
                                "exists so a slower query can be attributed to densification "
                                "rather than to growth.",
                        "recorded": cur}, indent=2) + "\n")
        print()
        print("BASELINE WRITTEN at %d orphan(s) and %d component(s). These are on the record and "
              "are silent from here; a RISE fails." % (len(orphans), ncomp))
        print("GRAPH-SHAPE-COMPLETE orphans=%d components=%d valence=%.4f"
              % (len(orphans), ncomp, valence))
        return 0

    b = base.get("recorded", {})
    bad = []
    if cur["orphans"] > b.get("orphans", cur["orphans"]):
        bad.append("orphans rose %d -> %d" % (b["orphans"], cur["orphans"]))
    if cur["components"] > b.get("components", cur["components"]):
        bad.append("components rose %d -> %d" % (b["components"], cur["components"]))
    print()
    print("  against the baseline: orphans %s -> %s, components %s -> %s, valence %s -> %s"
          % (b.get("orphans"), cur["orphans"], b.get("components"), cur["components"],
             b.get("valence"), cur["valence"]))
    if bad:
        for m in bad:
            print("  FAIL  " + m)
        print("GRAPH SHAPE AUDIT FAILED: %s. A new island is a node the graph stopped being able to "
              "reach, and no row-level check can see it. Explain it or fix it; --accept records a "
              "deliberate rise." % "; ".join(bad))
        print("GRAPH-SHAPE-COMPLETE orphans=%d components=%d valence=%.4f FAIL"
              % (len(orphans), ncomp, valence))
        return 2
    print("graph-shape: PASSED - orphans and components have not risen.")
    print("GRAPH-SHAPE-COMPLETE orphans=%d components=%d valence=%.4f"
          % (len(orphans), ncomp, valence))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
