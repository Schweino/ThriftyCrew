"""Promote SHADOW-GATED learned aliases into the legacy catalog.

    python graph/learning/promote_aliases.py --dry-run
    python graph/learning/promote_aliases.py

THE ONE PLACE THE GRAPH WRITES BACK, and it needs its reason stated plainly.

Every other importer in this estate runs dual-write: the legacy PowerShell path
stays authoritative and the graph is a shadow that never touches it. That
doctrine is what made the graph safe to build. It also, silently, made the
learning loop useless to the thing customers actually read.

Measured 2026-08-21: 156 include patterns exist ONLY in graph.db, every one of
them proposed by Stage 1, checked against the whole corpus by
alias_blast_radius, reviewed, and applied only after the shadow gate scored it
against the gold set with no regression. The live board reads
grocery/commodities.json and had received none of them.

That is why Family Fare's whole-cloves cell read $11.92/oz. The board matched
exactly ONE clove product; the graph matched three, including a $2.99/oz jar,
because the graph holds a `cloves?,\\s*whole` pattern the catalog does not. Not
a precedence bug, not a curated pin, not a comma bug — the board was never told
what the loop learned. 118 commodities are in that state.

WHAT THIS PROMOTES, and nothing else:
  * kind='include' aliases whose source is 'learning-patch' — i.e. they came
    through Stage 1 -> blast radius -> review -> shadow gate. A hand-added
    alias or an import artefact is not eligible; if it is not in
    commodities.json already, that was somebody's decision.
  * only for commodities that exist in commodities.json under their legacy id.

WHAT IT REFUSES:
  * a pattern that will not compile, or that carries a control character (see
    stage2_review.payload_is_sane — \\b is legal JSON for backspace, so a
    word-boundary pattern can arrive inert and look healthy).
  * a duplicate of a pattern the catalog already has.
  * anything listed in promotion-holds.json. THIS IS THE IMPORTANT ONE. The
    first promotion (2026-08-21) put all 156 in and the guard suite went
    hard=0 -> hard=10: unit-basis outliers where the newly-matched product's
    own link disagreed with the board, one alias that cross-claimed another
    commodity's cell, and one that crowned a fl-oz product on a weight row.
    Passing the shadow gate is NOT passing the guard suite — the gold set does
    not know what a per-unit basis is. 141 promoted clean; those 15 are held
    with their measured reason. Do not clear an entry without re-running
    compare-deals + guards and reading the diff.

It writes ONLY commodities.json's `include` arrays. It never edits excludes,
never reorders, never reformats another field. Run --dry-run first, then diff
the rebuilt board before deploying: the guard suite is the real gate here, not
this script's own opinion.
"""

from __future__ import annotations

import argparse
import collections
import io
import json
import os
import re
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

from graphdb import REPO_ROOT                              # noqa: E402

CATALOG = os.path.join(REPO_ROOT, "grocery", "commodities.json")
DB = os.path.join(REPO_ROOT, "graph", "sqlite", "graph.db")
HOLDS = os.path.join(HERE, "promotion-holds.json")


def held() -> dict[tuple[str, str], str]:
    """(commodity, pattern) -> why the guard suite threw it out."""
    if not os.path.exists(HOLDS):
        return {}
    with open(HOLDS, encoding="utf-8-sig") as fh:
        doc = json.load(fh)
    return {(h["commodity"], h["pattern"]): h["reason"] for h in doc.get("holds", [])}


def eligible(db) -> dict[str, list[str]]:
    """legacy_id -> learned include patterns not already in the catalog."""
    legacy = {}
    for r in db.execute("SELECT id, properties_json FROM nodes WHERE type='Commodity'"):
        lid = (json.loads(r["properties_json"] or "{}")).get("legacy_id")
        if lid:
            legacy[r["id"]] = lid
    out: dict[str, list[str]] = collections.defaultdict(list)
    for r in db.execute("""SELECT node_id, alias FROM aliases
                           WHERE kind='include' AND source='learning-patch'"""):
        lid = legacy.get(r["node_id"])
        if lid:
            out[lid].append(r["alias"])
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    db = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    learned = eligible(db)
    holds = held()

    with open(CATALOG, encoding="utf-8-sig") as fh:
        catalog = json.load(fh)

    added = collections.defaultdict(list)
    refused: list[tuple[str, str, str]] = []
    n_seen = 0
    for row in catalog:
        cid = row.get("id")
        if not cid or cid not in learned:
            continue
        have = list(row.get("include") or [])
        for pat in learned[cid]:
            n_seen += 1
            if pat in have:
                continue
            if (cid, pat) in holds:
                refused.append((cid, pat, "HELD: " + holds[(cid, pat)]))
                continue
            bad = [c for c in pat if ord(c) < 32]
            if bad:
                refused.append((cid, pat, f"control character {bad[0]!r} — escape eaten in transit"))
                continue
            try:
                re.compile(pat, re.IGNORECASE)
            except re.error as e:
                refused.append((cid, pat, f"does not compile: {e}"))
                continue
            have.append(pat)
            added[cid].append(pat)
        if added.get(cid):
            row["include"] = have

    total = sum(len(v) for v in added.values())
    print(f"learned patterns examined : {n_seen}")
    print(f"already in the catalog    : {n_seen - total - len(refused)}")
    print(f"REFUSED                   : {len(refused)}")
    for cid, pat, why in refused[:10]:
        print(f"    {cid:<24}{pat[:34]!r:<38}{why}")
    print(f"to promote                : {total} across {len(added)} commodities")
    for cid, pats in list(added.items())[:10]:
        print(f"    {cid:<24}{len(pats)}  e.g. {pats[0][:44]!r}")

    if args.dry_run:
        print("\n(dry run — commodities.json untouched)")
        return 0
    if not total:
        print("\nnothing to promote")
        return 0

    with io.open(CATALOG, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(catalog, fh, indent=2, ensure_ascii=False)
    print(f"\nwrote {CATALOG}")
    print("NEXT, and not optional: re-run compare-deals + guards + audit-known-wrong")
    print("and diff the board before deploying. This script's opinion is not the gate.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
