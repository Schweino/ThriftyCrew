"""emit_commodity_defs.py - commodity definitions for the sidecar, from the graph.

    python graph/pipeline/emit_commodity_defs.py --out sidecar/data/commodity-defs-graph.json
    python graph/pipeline/emit_commodity_defs.py --compare sidecar/data/commodity-defs.json

WHY THIS EXISTS
---------------
`grocery/audit-semantic-identity.ps1` builds the sidecar's commodity-defs.json from
grocery/commodities.json - the STAPLE catalogue, 588 entries. The graph holds 687 commodities
across two namespaces, and the difference is not academic. Measured 2026-08-22 on the live graph:

    contested questions the resolver asked   435
      staple namespace                        15
      recipe namespace                       420   <- 97%

    of the 44 distinct recipe commodities involved:
      defined in grocery/recipe-commodities.json  12
      defined nowhere the sidecar can read        32   (they arrive via the recipe-board import)

So the semantic helper could score 15 of 435 pairs. A filter that applies to 3% of the questions is
not a filter, and PLAN-local-matching's phase 3 depends on this one being real.

THIS DOES NOT BREAK THE DIVISION OF LABOUR
-------------------------------------------
The estate's rule is that PowerShell owns which products match which rules, because that regex must
stay byte-identical to the pricing engine, and a second copy in Python is the bug this estate keeps
getting bitten by. That rule is untouched here: `commodity_text()` deliberately EXCLUDES the regex
(feeding the model the patterns would relaunder the same blind spot in vector form). It needs a
label and some examples of what the board has accepted - both of which the graph holds for every
commodity in both namespaces, which is exactly what grocery/commodities.json does not.

EXEMPLARS COME FROM `instance_of`, NOT FROM TODAY'S BOARD
---------------------------------------------------------
The PowerShell prep takes exemplars from the latest comparison board, so a commodity that ships
nothing today gets none - which is the same reason 93 of 315 contested pairs had no peer
calibration in phase 2. `instance_of` is what the board has ACCEPTED, which is a larger and more
stable set. That is a real difference and it moves scores, so `--compare` exists to measure it
before anything downstream is changed: commodity_text is label + exemplars, and dropping the
exemplars alone moves TASK A AUC from 0.9705 to 0.7921.

READ-ONLY, enforced with PRAGMA query_only.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DEFAULT_DB = os.path.join(REPO, "graph", "sqlite", "graph.db")

MAX_EXEMPLARS = 6      # what audit-semantic-identity.ps1 collects; commodity_text() uses 5


def log(m: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def open_ro(path: str) -> sqlite3.Connection:
    uri = "file:" + os.path.abspath(path).replace("\\", "/") + "?mode=ro"
    c = sqlite3.connect(uri, uri=True)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA query_only = ON")
    return c


def build(conn: sqlite3.Connection) -> list[dict]:
    """One entry per Commodity node, in the schema the sidecar already reads.

    `id` is the BARE legacy id (`cumin`), not the namespaced node id
    (`commodity:staple:cumin`), because that is what commodity-defs.json has always held and what
    resolve.py's --emit-contested already translates to in `def_id`. Preferring `legacy_id` from the
    node's properties over splitting the id keeps the two namespaces from colliding silently if one
    ever renames.
    """
    ex: dict[str, list[str]] = {}
    for r in conn.execute(
            """SELECT e.target_id AS cid, n.canonical_name AS product
               FROM edges e JOIN nodes n ON n.id = e.source_id
               WHERE e.predicate = 'instance_of' AND n.canonical_name IS NOT NULL
               ORDER BY n.canonical_name"""):
        lst = ex.setdefault(r["cid"], [])
        if len(lst) < MAX_EXEMPLARS and r["product"] not in lst:
            lst.append(r["product"])

    out = []
    for r in conn.execute(
            "SELECT id, canonical_name, properties_json FROM nodes WHERE type='Commodity' ORDER BY id"):
        try:
            props = json.loads(r["properties_json"] or "{}")
        except json.JSONDecodeError:
            props = {}
        out.append({
            "id": props.get("legacy_id") or r["id"].rsplit(":", 1)[-1],
            # THE UNAMBIGUOUS KEY, and the reason it has to exist. 33 bare ids name a commodity in
            # BOTH namespaces - milk, butter, peanut-butter, carrots, brown-sugar, honey - so a
            # lookup by bare id silently resolves a recipe question against the staple's text, or
            # the reverse. That is not a missing score, it is a wrong one, and for near-identical
            # foods it would look plausible enough never to be questioned. Consumers that know the
            # namespace (the contested lane, whose questions come from the graph) key on this;
            # `id` stays as it always was for the identity and coverage lanes, whose board pairs
            # carry the legacy id and nothing else.
            "node_id": r["id"],
            "label": r["canonical_name"] or r["id"],
            "unit": props.get("unit_basis") or "",
            "exemplars": ex.get(r["id"], []),
            # Not read by commodity_text(); carried so a diff can say WHICH namespace a new
            # definition came from without joining back to the graph.
            "namespace": props.get("namespace") or "",
        })
    return out


def compare(new: list[dict], old_path: str) -> int:
    """What changes if the sidecar reads this instead of what it reads today.

    Prints, and returns the number of commodities whose TEXT changes - which is the number of
    commodities whose every score changes, and therefore the real blast radius on the identity and
    coverage lanes and on the daily alert they feed.
    """
    if not os.path.exists(old_path):
        log(f"BLIND: nothing to compare against at {old_path}")
        return -1
    with open(old_path, encoding="utf-8-sig") as f:
        old = json.load(f)
    # Keyed by BARE id on both sides on purpose: this diff answers "what changes for the file the
    # sidecar reads today", and that file is keyed by bare id. The 33 namespace collisions are
    # reported separately below rather than folded in, because they are a different problem from a
    # changed definition.
    o = {d["id"]: d for d in old}
    n = {d["id"]: d for d in new}
    seen: dict[str, list[str]] = {}
    for d in new:
        seen.setdefault(d["id"], []).append(d.get("node_id") or d["id"])
    collide = {k: v for k, v in seen.items() if len(v) > 1}

    added = sorted(set(n) - set(o))
    dropped = sorted(set(o) - set(n))
    changed_label, changed_ex, gained_ex = [], [], []
    for k in sorted(set(o) & set(n)):
        if (o[k].get("label") or "") != (n[k].get("label") or ""):
            changed_label.append(k)
        oe, ne = list(o[k].get("exemplars") or []), list(n[k].get("exemplars") or [])
        if oe != ne:
            changed_ex.append(k)
            if not oe and ne:
                gained_ex.append(k)

    log(f"commodities: {len(o)} today -> {len(n)} from the graph")
    log(f"  ADDED   {len(added)}  (by namespace: "
        f"{ {ns: sum(1 for k in added if n[k].get('namespace') == ns) for ns in sorted({n[k].get('namespace') for k in added})} })")
    log(f"  DROPPED {len(dropped)}" + (f"  {dropped[:10]}" if dropped else ""))
    log(f"  label changed    {len(changed_label)}")
    log(f"  exemplars changed {len(changed_ex)}, of which {len(gained_ex)} had NONE before")
    # DROPPED is the line to read first. An id the sidecar scores today and would stop scoring is a
    # guard silently narrowing, which is the failure this estate rates worse than a noisy one.
    if dropped:
        log("  ^^ DROPPED is the dangerous column: those commodities would stop being scored at all")
    touched = len(added) + len(dropped) + len(set(changed_label) | set(changed_ex))
    log(f"  TEXT CHANGES FOR {touched} commodit(y/ies) - every score for each of them moves")
    if collide:
        log(f"  {len(collide)} bare id(s) exist in BOTH namespaces and cannot be told apart by `id` "
            f"alone: {', '.join(sorted(collide)[:6])}{' ...' if len(collide) > 6 else ''}")
        log("     consumers that know the namespace must key on `node_id` (see build())")
    return touched


def main() -> int:
    ap = argparse.ArgumentParser(description="Emit sidecar commodity definitions from the graph")
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--out", default=None, help="write the definitions here")
    ap.add_argument("--compare", default=None,
                    help="an existing commodity-defs.json to diff against; writes nothing unless "
                         "--out is also given")
    args = ap.parse_args()

    if not os.path.exists(args.db):
        log(f"BLIND: no graph db at {args.db}")
        return 3
    conn = open_ro(args.db)
    try:
        defs = build(conn)
    finally:
        conn.close()
    ns: dict[str, int] = {}
    for d in defs:
        ns[d["namespace"]] = ns.get(d["namespace"], 0) + 1
    no_ex = sum(1 for d in defs if not d["exemplars"])
    log(f"{len(defs)} commodit(y/ies) by namespace {ns}; {no_ex} carry no exemplars at all")

    if args.compare:
        compare(defs, args.compare)
    if args.out:
        d = os.path.dirname(os.path.abspath(args.out))
        if d:
            os.makedirs(d, exist_ok=True)
        tmp = args.out + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            json.dump(defs, f, indent=2, ensure_ascii=False)
        os.replace(tmp, args.out)
        log(f"wrote {args.out}")
    if not args.out and not args.compare:
        log("nothing to do: pass --out, --compare, or both")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
