"""Commodity listing overlap probe - node similarity over instance_of (backlog I193).

WHAT IT MEASURES. Every ProductSKU is filed under at most one commodity PER NAMESPACE (staple, recipe)
by the engine's identity table (graph/identity/<ns>/*.jsonl, written by compare-deals.ps1
-IdentityNamespace). Scoring every commodity pair that shares a listing by the Jaccard index of their
listing sets finds two things: the same food under two ids (the staple/recipe twins of backlog I194,
tagged `same-id`) and two ids whose legacy spelling differs (`different-id`), which is where a form
mix-up (frozen vs canned) can hide. --pair lists one pair's shared listings with a crude FORM tag read
off the product name and size, so a reader can say whether they are misfiled.

TWO SOURCES, and they differ on purpose:
  --source graph     (default) instance_of edges in graph.db, the rebuildable INDEX.
  --source identity  the tracked identity .jsonl files, which are the TRUTH the index is built from.
The graph also prints how many of its identity-table edges the current files no longer assert
(`stale`): graph/import/importers.py upserts instance_of edges and never retracts one, so a listing
the engine has since re-filed keeps its old edge. Measure a form question on --source identity.

READ-ONLY. graph.db is opened with sqlite URI mode=ro; nothing is written anywhere. Point --db at a
COPY when the daily pipeline may be writing. graph.db is gitignored, so a worktree has none: pass --db.

Every run prints an input fingerprint and the denominators of every rate (.claude/rules/measurement.md).

SCOPE OF A CLEAN REPORT: the FORM tag is a word match on the listing name (can/canned/cup -> canned,
frozen/steam/bag -> frozen, else a 14.5-15.25 oz size -> can-size, else unknown). It is UNSOUND: an
`unknown` is not a verdict, and a canned listing that names no form reads `can-size` at best.

Usage:
  python graph/eval/probe_listing_overlap.py [--db PATH] [--source graph|identity] [--min 0.5]
  python graph/eval/probe_listing_overlap.py [--db PATH] [--source identity] --pair A,B
  python graph/eval/probe_listing_overlap.py --selftest
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
from collections import Counter, defaultdict
from itertools import combinations

HERE = os.path.dirname(os.path.abspath(__file__))
GRAPH = os.path.dirname(HERE)
DEFAULT_DB = os.path.join(GRAPH, "sqlite", "graph.db")
IDENTITY = os.path.join(GRAPH, "identity")
sys.path.insert(0, os.path.join(GRAPH, "lib"))


def open_ro(path: str) -> sqlite3.Connection:
    return sqlite3.connect("file:" + path.replace("\\", "/") + "?mode=ro", uri=True)


def form_of(name: str, size: str | None) -> str:
    n = (name or "").lower()
    if re.search(r"\bcann?ed\b|\bcans?\b|\bcups?\b", n):
        return "canned"
    if re.search(r"\bfrozen\b|\bsteam|\bbag\b", n):
        return "frozen"
    m = re.match(r"\s*([\d.]+)\s*oz\s*$", (size or "").lower())
    if m and 14.5 <= float(m.group(1)) <= 15.25:
        return "can-size"
    return "unknown"


class Data:
    """edges: set of (sku, commodity); info: sku -> (name, store, size); legacy; dnm; src."""

    def __init__(self):
        self.edges: set[tuple[str, str]] = set()
        self.info: dict[str, tuple[str, str, str]] = {}
        self.legacy: dict[str, str] = {}
        self.dnm: set[frozenset] = set()
        self.src: dict[tuple[str, str], str] = {}

    def by_commodity(self):
        c = defaultdict(set)
        for s, t in self.edges:
            c[t].add(s)
        return c

    def by_sku(self):
        c = defaultdict(set)
        for s, t in self.edges:
            c[s].add(t)
        return c


def load_graph(conn: sqlite3.Connection) -> Data:
    d = Data()
    for s, t, props in conn.execute(
            "SELECT e.source_id, e.target_id, e.properties_json FROM edges e "
            "JOIN nodes a ON a.id = e.source_id AND a.type = 'ProductSKU' "
            "JOIN nodes b ON b.id = e.target_id AND b.type = 'Commodity' "
            "WHERE e.predicate = 'instance_of'"):
        d.edges.add((s, t))
        try:
            d.src[(s, t)] = json.loads(props or "{}").get("source", "?")
        except ValueError:
            d.src[(s, t)] = "?"
    for nid, nm, props in conn.execute(
            "SELECT id, canonical_name, properties_json FROM nodes WHERE type IN ('Commodity','ProductSKU')"):
        try:
            p = json.loads(props or "{}")
        except ValueError:
            p = {}
        if nid.startswith("commodity:"):
            d.legacy[nid] = p.get("legacy_id") or nid.rsplit(":", 1)[-1]
        else:
            d.info[nid] = (nm, p.get("store", "?"), p.get("size") or "")
    d.dnm = {frozenset(r) for r in conn.execute(
        "SELECT source_id, target_id FROM edges WHERE predicate = 'do_not_merge'")}
    return d


def load_identity(root: str) -> tuple[Data, str]:
    from ids import sku_id  # graph/lib/ids.py, the id the importer mints
    d = Data()
    hashes = []
    for ns in ("staple", "recipe"):
        nsdir = os.path.join(root, ns)
        if not os.path.isdir(nsdir):
            continue
        man = os.path.join(nsdir, "_manifest.json")
        if os.path.exists(man):
            with open(man, encoding="utf-8-sig") as fh:
                m = json.load(fh)
            hashes.append(f"{ns}:rules={str(m.get('rules_hash'))[:12]} built_at={m.get('built_at')} "
                          f"rows_total={m.get('rows_total')}")
        for fname in sorted(os.listdir(nsdir)):
            if not fname.endswith(".jsonl"):
                continue
            with open(os.path.join(nsdir, fname), encoding="utf-8") as fh:
                for line in fh:
                    if not line.strip():
                        continue
                    r = json.loads(line)
                    if not (r.get("store") and r.get("name")):
                        continue
                    s = sku_id(r["store"], r["name"], r.get("size"))
                    d.info[s] = (r["name"], r["store"], r.get("size") or "")
                    c = r.get("commodity")
                    if c:
                        d.edges.add((s, c))
                        d.src[(s, c)] = "identity-table"
                        d.legacy.setdefault(c, c.rsplit(":", 1)[-1])
    return d, " ".join(hashes)


def score_pairs(d: Data):
    by_c, by_s = d.by_commodity(), d.by_sku()
    pairs: Counter = Counter()
    for cs in by_s.values():
        if len(cs) > 1:
            for a, b in combinations(sorted(cs), 2):
                pairs[(a, b)] += 1
    out = [(sh / len(by_c[a] | by_c[b]), sh, len(by_c[a] | by_c[b]), a, b) for (a, b), sh in pairs.items()]
    out.sort(key=lambda r: (-r[0], r[3], r[4]))
    return out


def run_rank(d: Data, minj: float):
    by_s = d.by_sku()
    multi = sum(1 for cs in by_s.values() if len(cs) > 1)
    print(f"skus_filed={len(by_s)} filed_under_more_than_one={multi} of {len(by_s)} "
          f"commodities_with_skus={len(d.by_commodity())}")
    rows = score_pairs(d)
    hi = [r for r in rows if r[0] >= minj]
    cross = sum(1 for r in hi if r[3].split(":")[1] != r[4].split(":")[1])
    same = sum(1 for r in hi if d.legacy.get(r[3]) == d.legacy.get(r[4]))
    dnm = sum(1 for r in hi if frozenset((r[3], r[4])) in d.dnm)
    print(f"pairs_sharing_a_sku={len(rows)} at_or_above_{minj}={len(hi)} cross_namespace={cross} of {len(hi)} "
          f"same_legacy_id={same} of {len(hi)} do_not_merge={dnm} of {len(hi)}")
    for j, sh, un, a, b in hi:
        tag = "same-id" if d.legacy.get(a) == d.legacy.get(b) else "different-id"
        print(f"{j:.3f} shared={sh} union={un} {tag} {a} {b}")


def run_pair(d: Data, a: str, b: str):
    by_c, by_s = d.by_commodity(), d.by_sku()
    sa, sb = by_c.get(a, set()), by_c.get(b, set())
    shared = sorted(sa & sb, key=lambda s: (d.info.get(s, ("", "", ""))[1], d.info.get(s, ("", "", ""))[0]))
    union = len(sa | sb)
    print(f"PAIR {a} ({len(sa)} skus) x {b} ({len(sb)} skus): shared={len(shared)} union={union} "
          f"jaccard={(len(shared) / union if union else 0):.3f}")
    forms = Counter()
    lines = []
    for s in shared:
        nm, store, size = d.info.get(s, ("?", "?", ""))
        f = form_of(nm, size)
        forms[f] += 1
        extra = sorted(by_s[s] - {a, b})
        lines.append(f"  {f:8} {store} | {nm} | {size}" + (" also=" + ",".join(extra) if extra else ""))
    print("  forms of shared listings: " + " ".join(f"{k}={v} of {len(shared)}" for k, v in sorted(forms.items())))
    for ln in lines:
        print(ln)


def selftest() -> int:
    fails = 0
    ran = 0

    def case(label, ok):
        nonlocal fails, ran
        ran += 1
        print(("PASS " if ok else "FAIL ") + label)
        if not ok:
            fails += 1

    d = Data()
    peas_r, peas_s = "commodity:recipe:frozen-green-peas", "commodity:staple:canned-peas"
    hoi_r, hoi_s = "commodity:recipe:hoisin-sauce", "commodity:staple:hoisin-sauce"
    d.edges = {("k0", peas_r), ("k0", peas_s), ("k1", peas_r), ("k1", peas_s), ("k2", peas_s),
               ("k3", hoi_r), ("k3", hoi_s)}
    d.legacy = {peas_r: "frozen-green-peas", peas_s: "canned-peas", hoi_r: "hoisin-sauce", hoi_s: "hoisin-sauce"}
    got = {(a, b): (round(j, 3), sh, un) for j, sh, un, a, b in score_pairs(d)}
    case("MUST FIRE a different-id pair sharing 2 of 3 listings scores 0.667", got.get((peas_r, peas_s)) == (0.667, 2, 3))
    case("CLEAN TWIN a same-id twin still scores 1.0 over its one listing", got.get((hoi_r, hoi_s)) == (1.0, 1, 1))
    case("MUST NOT FIRE commodities that share no listing never form a pair",
         (peas_r, hoi_r) not in got and (hoi_s, peas_s) not in got and len(got) == 2)
    case("MUST FIRE a 15 oz listing that names no form reads can-size", form_of("Green Peas, Sweet", "15 oz") == "can-size")
    case("MUST FIRE a listing that says can reads canned", form_of("Del Monte Sweet Peas, 15 oz Can", "15 oz") == "canned")
    case("CLEAN TWIN a steamable bag reads frozen", form_of("Birds Eye Steamfresh Sweet Peas", "10 oz") == "frozen")
    case("MUST NOT FIRE a 12 oz listing with no form word is not can-size", form_of("Organic Sweet Peas", "12 oz") == "unknown")
    print(f"cases={ran} of 7 failed={fails}")
    ok = fails == 0 and ran == 7
    print("probe_listing_overlap self-test " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--identity", default=IDENTITY, help="identity table root (graph/identity)")
    ap.add_argument("--source", choices=("graph", "identity"), default="graph")
    ap.add_argument("--min", type=float, default=0.5)
    ap.add_argument("--pair", default=None, help="two commodity ids, comma separated")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.source == "identity":
        d, fp = load_identity(a.identity)
        if not d.edges:
            print(f"BLIND: no identity rows under {a.identity}")
            return 3
        print(f"INPUT source=identity root={a.identity} {fp} filed_edges={len(d.edges)}")
    else:
        if not os.path.exists(a.db):
            print(f"BLIND: no graph.db at {a.db} (it is gitignored; pass --db)")
            return 3
        conn = open_ro(a.db)
        d = load_graph(conn)
        newest = conn.execute("SELECT max(updated_at) FROM nodes").fetchone()[0]
        print(f"INPUT source=graph db={a.db} bytes={os.path.getsize(a.db)} newest_node_updated_at={newest} "
              f"instance_of_edges={len(d.edges)}")
        if os.path.isdir(a.identity):
            truth, _ = load_identity(a.identity)
            idt = {e for e in d.edges if d.src.get(e) == "identity-table"}
            print(f"identity-table edges={len(idt)} asserted_by_current_files={len(idt & truth.edges)} "
                  f"stale={len(idt - truth.edges)} of {len(idt)} (vs {a.identity})")
    if a.pair:
        x, y = [p.strip() for p in a.pair.split(",", 1)]
        run_pair(d, x, y)
    else:
        run_rank(d, a.min)
    return 0


if __name__ == "__main__":
    sys.exit(main())
