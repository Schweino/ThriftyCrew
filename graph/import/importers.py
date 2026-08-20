"""Seed importers — legacy JSON estate -> knowledge graph (Phase 2).

Every importer is DETERMINISTIC and ADDITIVE: re-running it is a no-op, never a
duplicate. Each writes a provenance row naming the exact source file, so any node
in the graph can be traced back to the file and line of the estate it came from.

These run in DUAL-WRITE mode. The legacy PowerShell path stays fully
authoritative; the graph is a shadow copy whose quality is measured against the
gold set until its exit gate passes. Nothing here writes back to the legacy files.

The three commodity id namespaces are kept SEPARATE on purpose (see ids.py):
collapsing 'ground-turkey' (staple) into '93-7-ground-turkey' (recipe) would be a
false merge, and those two are genuinely different purchases.
"""

from __future__ import annotations

import glob
import os
import re
from typing import Callable

from graphdb import GraphDB, read_json, REPO_ROOT
from ids import (adcycle_id, category_id, catexclude_id, commodity_id,
                 known_wrong_id, mapping_id, norm_store, observation_id,
                 override_id, sku_id, store_id, store_label, hash_obj, slug)
from units import parse_engine_unit_price

GROCERY = os.path.join(REPO_ROOT, "grocery")
MEALPREP = os.path.join(REPO_ROOT, "meal-prep")


def rel(path: str) -> str:
    """Repo-relative path, for provenance.source_document."""
    return os.path.relpath(path, REPO_ROOT).replace("\\", "/")


def _money(v) -> float | None:
    """Parse '$4.88' / '4.88' / 4.88 -> 4.88. Returns None on anything else."""
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    m = re.search(r"-?\d+(?:\.\d+)?", str(v).replace(",", ""))
    return float(m.group()) if m else None


# ---------------------------------------------------------------------------
# Stores + ad cycles
# ---------------------------------------------------------------------------

def import_stores(db: GraphDB, ts: str, run: str) -> dict:
    """grocery/ad-schedule.json -> Store nodes + AdCycle nodes/edges.

    Carries the Omaha identity and the verified weekly cadence onto the node,
    because both are hard gates the graph must be able to answer for.
    """
    path = os.path.join(GROCERY, "ad-schedule.json")
    data = read_json(path)
    prov = db.record_provenance(rel(path), "import:ad-schedule", ts, run=run)

    n_store = n_cycle = 0
    for s in data.get("stores", []):
        name = s.get("store")
        if not name:
            continue
        sid = store_id(name)
        db.upsert_node(sid, "Store", store_label(name), ts,
                       description=f"Omaha-area grocery store ({s.get('method','?')} pull lane)",
                       properties={
                           "omaha_identity": True,      # every store in this file is Omaha-scoped
                           "pull_method": s.get("method"),
                           "cadence_days": s.get("cadence_days"),
                           "ad_window": s.get("current"),
                           "next_pull": s.get("next_pull"),
                           "raw_name": name,
                       }, provenance=prov)
        n_store += 1

        cycles = list(s.get("history") or [])
        if s.get("current"):
            cycles.append(s["current"])
        for c in cycles:
            frm, to = c.get("from"), c.get("to")
            if not (frm and to):
                continue
            cid = adcycle_id(name, frm, to)
            db.upsert_node(cid, "AdCycle", f"{store_label(name)} {frm}..{to}", ts,
                           properties={"from": frm, "to": to,
                                       "detected": c.get("detected"),
                                       "is_current": c is s.get("current")},
                           provenance=prov)
            db.upsert_edge(cid, "belongs_to_cycle", sid, ts, provenance=prov)
            n_cycle += 1

    # Walmart and Sam's have no weekly ad cycle but are real stores and must exist
    # as nodes, or their observations would dangle.
    for extra in ("Walmart", "Sam's Club"):
        sid = store_id(extra)
        if not db.get_node(sid):
            db.upsert_node(sid, "Store", store_label(extra), ts,
                           description="Omaha store with no weekly ad cycle (everyday pricing lane)",
                           properties={"omaha_identity": True, "pull_method": "browser",
                                       "cadence_days": None, "raw_name": extra},
                           provenance=prov)
            n_store += 1

    return {"stores": n_store, "ad_cycles": n_cycle}


# ---------------------------------------------------------------------------
# Commodities (both namespaces) + categories
# ---------------------------------------------------------------------------

def _import_commodity_list(db: GraphDB, rows: list, namespace: str, source: str,
                           prov: str, ts: str) -> int:
    n = 0
    for c in rows:
        cid_raw = c.get("id")
        if not cid_raw:
            continue
        nid = commodity_id(cid_raw, namespace)
        db.upsert_node(nid, "Commodity", c.get("label") or cid_raw, ts,
                       description=c.get("note"),
                       properties={
                           "legacy_id": cid_raw,
                           "namespace": namespace,
                           "unit_basis": c.get("unit"),
                           "band_min": c.get("band_min"),
                           "band_max": c.get("band_max"),
                       }, provenance=prov)
        # include/exclude regexes ARE this codebase's alias mechanism.
        for pat in c.get("include") or []:
            db.add_alias(nid, pat, source, ts, kind="include", is_regex=True, provenance=prov)
        for pat in c.get("exclude") or []:
            db.add_alias(nid, pat, source, ts, kind="exclude", is_regex=True, provenance=prov)
        if c.get("label"):
            db.add_alias(nid, c["label"], source, ts, kind="label", is_regex=False, provenance=prov)
        n += 1
    return n


def import_commodities(db: GraphDB, ts: str, run: str) -> dict:
    """commodities.json (staples) + recipe-commodities.json (recipe board)."""
    out = {}

    p1 = os.path.join(GROCERY, "commodities.json")
    prov1 = db.record_provenance(rel(p1), "import:commodities", ts, run=run)
    out["staple_commodities"] = _import_commodity_list(
        db, read_json(p1), "staple", rel(p1), prov1, ts)

    p2 = os.path.join(GROCERY, "recipe-commodities.json")
    if os.path.exists(p2):
        d2 = read_json(p2)
        prov2 = db.record_provenance(rel(p2), "import:recipe-commodities", ts, run=run)
        out["recipe_commodities"] = _import_commodity_list(
            db, d2.get("commodities", []), "recipe", rel(p2), prov2, ts)
        # global_exclude applies to every recipe commodity; model it once on each
        # so a query never has to know about the file-level special case.
        for pat in d2.get("global_exclude") or []:
            for c in d2.get("commodities", []):
                if c.get("id"):
                    db.add_alias(commodity_id(c["id"], "recipe"), pat, rel(p2), ts,
                                 kind="exclude", is_regex=True, provenance=prov2)
    return out


def import_categories(db: GraphDB, ts: str, run: str) -> dict:
    path = os.path.join(GROCERY, "categories.json")
    if not os.path.exists(path):
        return {"categories": 0}
    data = read_json(path)
    prov = db.record_provenance(rel(path), "import:categories", ts, run=run)
    n_cat = n_edge = 0
    for cat in data.get("categories", []):
        key = cat.get("key")
        if not key:
            continue
        catid = category_id(key)
        db.upsert_node(catid, "Category", cat.get("label") or key, ts,
                       properties={"order": cat.get("order"), "key": key}, provenance=prov)
        n_cat += 1
        for cid_raw in cat.get("commodities") or []:
            nid = commodity_id(cid_raw, "staple")
            if db.get_node(nid):
                db.upsert_edge(nid, "in_category", catid, ts, provenance=prov)
                n_edge += 1
    return {"categories": n_cat, "in_category_edges": n_edge}


def import_search_terms(db: GraphDB, ts: str, run: str) -> dict:
    path = os.path.join(GROCERY, "commodity-search.json")
    if not os.path.exists(path):
        return {"search_terms": 0}
    data = read_json(path)
    prov = db.record_provenance(rel(path), "import:commodity-search", ts, run=run)
    n = 0
    for cid_raw, term in (data.get("terms") or {}).items():
        # Most commodities carry one search term, but a few carry several
        # (e.g. popsicles -> ["popsicles", "ice pops"]). Both forms are valid.
        terms = term if isinstance(term, list) else [term]
        for ns in ("staple", "recipe"):
            nid = commodity_id(cid_raw, ns)
            if db.get_node(nid):
                for t in terms:
                    if isinstance(t, str) and t.strip():
                        db.add_alias(nid, t, rel(path), ts, kind="search_term",
                                     is_regex=False, provenance=prov)
                        n += 1
                break
    return {"search_terms": n}


# ---------------------------------------------------------------------------
# Adjudicated rulings: known-wrong, dupe allowlist, overrides, category excludes
# ---------------------------------------------------------------------------

def import_known_wrong(db: GraphDB, ts: str, run: str) -> dict:
    """known-wrong.json -> KnownWrong nodes + known_wrong_for edges.

    These are the single most valuable rows in the estate: each is a human/agent
    ADJUDICATED negative with written evidence. They seed both the resolution
    constraint layer and the gold set's negative half.
    """
    path = os.path.join(GROCERY, "known-wrong.json")
    if not os.path.exists(path):
        return {"known_wrong": 0}
    data = read_json(path)
    prov = db.record_provenance(rel(path), "import:known-wrong", ts, run=run)
    n = 0
    for e in data.get("entries", []):
        commodity, store = e.get("commodity"), e.get("store")
        if not (commodity and store):
            continue
        for nm in e.get("names") or [e.get("product_id") or ""]:
            if not nm:
                continue
            kwid = known_wrong_id(commodity, store, nm)
            db.upsert_node(kwid, "KnownWrong", nm, ts,
                           description=e.get("evidence"),
                           properties={"commodity": commodity, "store": store,
                                       "product_id": e.get("product_id"),
                                       "verdict": e.get("verdict"),
                                       "key": e.get("key")},
                           provenance=prov)
            sid = store_id(store)
            if db.get_node(sid):
                db.upsert_edge(kwid, "sold_at", sid, ts, provenance=prov)
            for ns in ("staple", "recipe"):
                nid = commodity_id(commodity, ns)
                if db.get_node(nid):
                    db.upsert_edge(kwid, "known_wrong_for", nid, ts, provenance=prov,
                                   properties={"evidence": e.get("evidence"),
                                               "verdict": e.get("verdict")})
                    break
            n += 1
    return {"known_wrong": n}


def import_dupe_allowlist(db: GraphDB, ts: str, run: str) -> dict:
    """commodity-dupe-allowlist.json -> do_not_merge constraints.

    Feeds the Resolve stage's blocking layer BEFORE the model sees candidates,
    so a reviewed near-duplicate can never be re-merged by a model.
    """
    path = os.path.join(GROCERY, "commodity-dupe-allowlist.json")
    if not os.path.exists(path):
        return {"do_not_merge": 0}
    data = read_json(path)
    prov = db.record_provenance(rel(path), "import:dupe-allowlist", ts, run=run)
    n = 0
    for pair in data.get("allow", []):
        a, b = pair.get("a"), pair.get("b")
        if not (a and b):
            continue
        for ns in ("staple", "recipe"):
            na, nb = commodity_id(a, ns), commodity_id(b, ns)
            if db.get_node(na) and db.get_node(nb):
                props = {"reason": pair.get("reason"), "reviewed": pair.get("reviewed"),
                         "reviewed_by": pair.get("reviewed_by")}
                db.upsert_edge(na, "do_not_merge", nb, ts, provenance=prov, properties=props)
                db.upsert_edge(nb, "do_not_merge", na, ts, provenance=prov, properties=props)
                n += 1
                break
    return {"do_not_merge": n}


def import_overrides(db: GraphDB, ts: str, run: str) -> dict:
    path = os.path.join(GROCERY, "board-price-overrides.json")
    if not os.path.exists(path):
        return {"overrides": 0}
    data = read_json(path)
    prov = db.record_provenance(rel(path), "import:board-overrides", ts, run=run)
    n = 0
    for cell in data.get("cells", []):
        cid_raw, store = cell.get("id"), cell.get("store")
        if not (cid_raw and store):
            continue
        oid = override_id(cid_raw, store)
        db.upsert_node(oid, "Override", f"{cid_raw}@{store}", ts,
                       description=cell.get("source"),
                       properties={"per_unit": cell.get("per_unit"), "store": store,
                                   "commodity": cid_raw}, provenance=prov)
        for ns in ("staple", "recipe"):
            nid = commodity_id(cid_raw, ns)
            if db.get_node(nid):
                db.upsert_edge(oid, "overrides", nid, ts, provenance=prov)
                break
        sid = store_id(store)
        if db.get_node(sid):
            db.upsert_edge(oid, "sold_at", sid, ts, provenance=prov)
        n += 1
    return {"overrides": n}


def import_category_excludes(db: GraphDB, ts: str, run: str) -> dict:
    """category-excludes.json -> CategoryExclude nodes.

    Born from the 2026-07-14 blueberries-as-Bai-beverage live mispricing; these
    are the wrong-CLASS guardrails every new commodity is born with.
    """
    path = os.path.join(GROCERY, "category-excludes.json")
    if not os.path.exists(path):
        return {"category_excludes": 0}
    data = read_json(path)
    prov = db.record_provenance(rel(path), "import:category-excludes", ts, run=run)

    # `apply` is a RULE LIST — [{categories: <regex>, classes: [...]}, ...] — not a
    # dict keyed by class. Invert it so each class knows which category patterns
    # it is enforced against. `exempt` IS keyed by class.
    applies_by_class: dict[str, list[str]] = {}
    for rule in data.get("apply") or []:
        if not isinstance(rule, dict):
            continue
        cat_pat = rule.get("categories")
        for cls in rule.get("classes") or []:
            applies_by_class.setdefault(cls, []).append(cat_pat)

    exempt = data.get("exempt") or {}
    universal = set(data.get("universal_for_unknown") or [])

    n = 0
    for cls, patterns in (data.get("classes") or {}).items():
        for pat in patterns:
            xid = catexclude_id(cls, pat)
            db.upsert_node(xid, "CategoryExclude", pat, ts,
                           description=f"wrong-class token for the '{cls}' class",
                           properties={"class": cls, "pattern": pat,
                                       "applies_to_categories": applies_by_class.get(cls, []),
                                       "exempt": exempt.get(cls),
                                       "universal_for_unknown": cls in universal},
                           provenance=prov)
            n += 1
    return {"category_excludes": n}


# ---------------------------------------------------------------------------
# Product SKUs + ingredient mappings
# ---------------------------------------------------------------------------

def import_product_urls(db: GraphDB, ts: str, run: str) -> dict:
    """product-urls.json -> ProductSKU nodes, priced_as + sold_at edges."""
    path = os.path.join(GROCERY, "product-urls.json")
    if not os.path.exists(path):
        return {"skus": 0}
    data = read_json(path)
    prov = db.record_provenance(rel(path), "import:product-urls", ts, run=run)
    n = 0
    for cid_raw, entry in (data.get("items") or {}).items():
        target = None
        for ns in ("staple", "recipe"):
            if db.get_node(commodity_id(cid_raw, ns)):
                target = commodity_id(cid_raw, ns)
                break
        for store, v in entry.items():
            if store == "commodity" or not isinstance(v, dict):
                continue
            name = v.get("name") or cid_raw
            skid = sku_id(store, name, v.get("size"))
            db.upsert_node(skid, "ProductSKU", name, ts,
                           properties={"url": v.get("url"), "price": v.get("price"),
                                       "size": v.get("size"), "store": store,
                                       "recipe_pu": v.get("recipe_pu"),
                                       "verified": v.get("verified")},
                           provenance=prov)
            sid = store_id(store)
            if db.get_node(sid):
                db.upsert_edge(skid, "sold_at", sid, ts, provenance=prov)
            if target:
                db.upsert_edge(skid, "instance_of", target, ts, provenance=prov,
                               properties={"source": "product-urls"})
            n += 1
    return {"skus": n}


def import_ingredient_map(db: GraphDB, ts: str, run: str) -> dict:
    path = os.path.join(MEALPREP, "ingredient-map.json")
    if not os.path.exists(path):
        return {"ingredient_mappings": 0}
    data = read_json(path)
    prov = db.record_provenance(rel(path), "import:ingredient-map", ts, run=run)
    n = 0
    for m in data.get("mappings", []):
        item, board_id = m.get("item"), m.get("board_id")
        if not (item and board_id):
            continue
        mid = mapping_id(item, board_id)
        db.upsert_node(mid, "IngredientMapping", item, ts,
                       properties={"board": m.get("board"), "unit": m.get("unit"),
                                   "grams_per_unit": m.get("grams_per_unit"),
                                   "board_id": board_id}, provenance=prov)
        ns = "recipe" if m.get("board") == "recipe" else "staple"
        for cand in (ns, "staple", "recipe"):
            nid = commodity_id(board_id, cand)
            if db.get_node(nid):
                db.upsert_edge(mid, "maps_to", nid, ts, provenance=prov)
                break
        n += 1
    return {"ingredient_mappings": n}


# ---------------------------------------------------------------------------
# Fareway shop lane — already keyed by commodity id (Block 1.2)
# ---------------------------------------------------------------------------

def _is_capture(rows: list) -> bool:
    """Distinguish a capture from a WORKLIST by shape, never by filename.

    grocery/out/fareway/ holds both. reprice-chips.json and recapture-terms.json
    are worklists — rows of {id, q[, t]} naming what still needs pricing — and
    importing them as observations would invent prices that were never observed.
    A capture row carries a price field; a worklist row does not.
    """
    if not isinstance(rows, list) or not rows:
        return False
    sample = [r for r in rows[:50] if isinstance(r, dict)]
    if not sample:
        return False
    keys = {k for r in sample for k in r}
    return bool(keys & {"price", "ad_price", "lp"})


def import_fareway_shop(db: GraphDB, ts: str, run: str, *,
                        limit_files: int | None = None) -> dict:
    """grocery/out/fareway/fareway-shop-*.json -> PriceObservation rows.

    The cheapest lane in the estate to import: every row is ALREADY keyed by
    commodity id, so no resolution is needed and no model is consulted. Rows land
    pre-adjudicated as 'include_hit' because the capture itself asserted the
    commodity — the id came from the store-side pull, not from a guess here.

    Two field subtleties, both load-bearing:
      * `unit` carries an engine-computed unit price ("$1.99/lb"). Prefer it, per
        the same rule that makes Walmart's wm_unit_price authoritative.
      * `per: "package (estimated)"` marks a variable-weight item where `price`
        is an ESTIMATE for a whole package (e.g. $59.90 for "about 10 lb" of
        ground beef). The sticker is not comparable; the unit price is.
    """
    files = sorted(glob.glob(os.path.join(GROCERY, "out", "fareway", "fareway-shop-*.json")))
    if limit_files:
        files = files[-limit_files:]

    n_obs = n_files = n_skipped = n_worklist = 0
    for fp in files:
        try:
            rows = read_json(fp)
        except Exception:
            continue
        if not _is_capture(rows):
            n_worklist += 1
            continue

        observed = os.path.basename(fp).replace("fareway-shop-", "").replace(".json", "")
        prov = db.record_provenance(rel(fp), "import:fareway-shop", ts,
                                    raw_output_hash=hash_obj(len(rows)), run=run)
        n_files += 1

        for r in rows:
            legacy = r.get("id")
            name = r.get("name")
            if not (legacy and name):
                n_skipped += 1
                continue
            cid = None
            for ns in ("staple", "recipe"):
                cand = commodity_id(legacy, ns)
                if db.get_node(cand):
                    cid = cand
                    break
            if not cid:
                n_skipped += 1
                continue

            price = _money(r.get("price"))
            orig = _money(r.get("orig"))
            upx, unit = parse_engine_unit_price(r.get("unit"))
            estimated = "estimat" in str(r.get("per", "")).lower()

            oid = observation_id(cid, "Fareway", observed, rel(fp), name)
            db.add_observation({
                "id": oid,
                "commodity_id": cid,
                "store_id": store_id("Fareway"),
                "product_name": name,
                # A variable-weight sticker is not a comparable price; keep it for
                # evidence but never let it stand in as one.
                "price": None if (estimated and upx is not None) else price,
                "unit_price": upx,
                "unit": unit,
                "size_text": r.get("size"),
                "is_sale": 1 if (orig and price and orig > price) else 0,
                "price_type": "sale" if (orig and price and orig > price) else "everyday",
                "ad_cycle_id": None,
                "provenance_id": prov,
                "confidence": 1.0,
                "observed_at": observed,
                "source_file": rel(fp),
                # the capture asserted the commodity id; nothing to adjudicate
                "match_status": "include_hit",
                "match_reason": "fareway shop capture is keyed by commodity id",
            })
            n_obs += 1

    return {"fareway_observations": n_obs, "fareway_files": n_files,
            "fareway_worklists_skipped": n_worklist, "fareway_rows_skipped": n_skipped}


def import_product_url_prices(db: GraphDB, ts: str, run: str, *,
                              limit_files: int | None = None) -> dict:
    """product-urls.json -> PriceObservation rows (Block 1, largest parity lever).

    WHY THIS IS THE BIGGEST LEVER, measured rather than assumed: 86.2% of the
    live board's 3,213 cells have a product-urls entry for that exact
    (commodity, store), and 71.5% of those reproduce the board's rendered
    data-pu within 2%. The capture sweep is a DISCOVERY lane; this file is the
    curated, shelf-verified answer the board actually renders, complete with the
    See-item link. Importing only the sweep and not this was why the graph could
    speak to barely a third of the board.

    Rows land pre-adjudicated as include_hit: the file is keyed by commodity id
    and each entry was curated for that commodity, so there is nothing for the
    resolver to decide. `verified` dates are carried onto the observation so
    freshness stays auditable.
    """
    path = os.path.join(GROCERY, "product-urls.json")
    if not os.path.exists(path):
        return {"product_url_observations": 0}
    data = read_json(path)
    prov = db.record_provenance(rel(path), "import:product-urls-prices", ts, run=run)

    n_obs = n_skip = 0
    for cid_raw, entry in (data.get("items") or {}).items():
        cid = None
        for ns in ("staple", "recipe"):
            cand = commodity_id(cid_raw, ns)
            if db.get_node(cand):
                cid = cand
                break
        if not cid:
            n_skip += 1
            continue

        for store, v in entry.items():
            if store == "commodity" or not isinstance(v, dict):
                continue
            price = _money(v.get("price"))
            if price is None:
                n_skip += 1
                continue
            name = v.get("name") or cid_raw
            # `verified` is the day the shelf was actually checked; fall back to
            # the file's own updated stamp so an observation always has a date.
            observed = v.get("verified") or data.get("updated") or ts[:10]

            oid = observation_id(cid, store, observed, rel(path), name)
            db.add_observation({
                "id": oid,
                "commodity_id": cid,
                "store_id": store_id(store),
                "product_name": name,
                "price": price,
                # recipe_pu is NOT imported as unit_price: it is the RECIPE
                # board's basis, which for some commodities differs from the
                # staple board's declared unit. Carrying it across without its
                # basis is precisely the mismatch reconcile_unit exists to stop
                # (the milk fl-oz/gallon class of error). Let price+size derive,
                # where the basis is unambiguous.
                "unit_price": None,
                "unit": None,
                "size_text": v.get("size"),
                "is_sale": 0,
                "price_type": "everyday",
                "ad_cycle_id": None,
                "provenance_id": prov,
                "confidence": 1.0,
                "observed_at": observed,
                "source_file": rel(path),
                "match_status": "include_hit",
                "match_reason": "curated product-urls entry, keyed by commodity id"
                                + (f"; shelf-verified {v['verified']}" if v.get("verified") else ""),
            })
            n_obs += 1

    return {"product_url_observations": n_obs, "product_url_skipped": n_skip}


# ---------------------------------------------------------------------------
# Price observations — the high-volume backfill
# ---------------------------------------------------------------------------

def _resolve_by_term(db: GraphDB, term: str | None, term_index: dict) -> str | None:
    """Map a capture's `found_by_term` back to a commodity via commodity-search.

    This is the EXISTING, deterministic linkage the estate already trusts. Using
    it for backfill means the graph starts from the legacy system's own answers,
    which is what makes the Phase 2 parity comparison meaningful.
    """
    if not term:
        return None
    return term_index.get(term.strip().lower())


def _build_term_index(db: GraphDB) -> dict:
    idx = {}
    for row in db.conn.execute(
            "SELECT node_id, alias FROM aliases WHERE kind='search_term'").fetchall():
        idx[row["alias"].strip().lower()] = row["node_id"]
    return idx


def import_observations(db: GraphDB, ts: str, run: str, *, limit_files: int | None = None,
                        dirs: tuple[str, ...] = ("regular", "throttled"),
                        progress: Callable[[str], None] | None = None) -> dict:
    """grocery/out/<lane>/*.json -> PriceObservation rows.

    Observations are the one structure NOT exported to tracked JSON (they are
    reconstructable from these very captures, which are themselves tracked). Their
    provenance rows ARE exported, so the audit trail survives a rebuild.
    """
    term_index = _build_term_index(db)
    n_obs = n_files = n_unresolved = 0

    for lane in dirs:
        files = sorted(glob.glob(os.path.join(GROCERY, "out", lane, "*.json")))
        if limit_files:
            files = files[-limit_files:]
        for fp in files:
            try:
                data = read_json(fp)
            except Exception:
                continue
            if not isinstance(data, dict):
                continue
            deals = data.get("deals")
            if not deals:
                continue

            store = data.get("store")
            observed = data.get("captured") or data.get("week_of") or ts[:10]
            prov = db.record_provenance(rel(fp), f"import:capture:{lane}", ts,
                                        raw_output_hash=hash_obj(data.get("source", "")),
                                        run=run)
            n_files += 1
            if progress:
                progress(f"  {rel(fp)}  ({len(deals)} deals)")

            for d in deals:
                dstore = d.get("store") or store
                if not dstore:
                    continue
                cid = _resolve_by_term(db, d.get("found_by_term"), term_index)
                if not cid:
                    n_unresolved += 1
                    continue
                name = d.get("item")
                price = _money(d.get("current_price") or d.get("ad_price"))
                as_of = d.get("as_of") or observed
                oid = observation_id(cid, dstore, as_of, rel(fp), name)

                # Prefer the LEGACY ENGINE's own verified unit price over
                # re-deriving one here. See parse_engine_unit_price for why.
                upx, unit = parse_engine_unit_price(
                    d.get("engine_check") or d.get("wm_unit_price"))

                db.add_observation({
                    "id": oid,
                    "commodity_id": cid,
                    "store_id": store_id(dstore),
                    "product_name": name,
                    "price": price,
                    "unit_price": upx,
                    "unit": unit,
                    "size_text": d.get("size"),
                    "is_sale": 1 if (d.get("price_type") or "").lower() == "sale" else 0,
                    "price_type": d.get("price_type"),
                    "ad_cycle_id": None,
                    "provenance_id": prov,
                    "confidence": 1.0,
                    "observed_at": as_of,
                    "source_file": rel(fp),
                })
                n_obs += 1
    return {"observations": n_obs, "capture_files": n_files,
            "unresolved_rows": n_unresolved}


# ---------------------------------------------------------------------------

# Lane importers run AFTER the generic capture backfill and take limit_files.
LANE_IMPORTERS: list[tuple[str, Callable]] = [
    ("fareway_shop", import_fareway_shop),
    ("product_url_prices", import_product_url_prices),
]

ALL_IMPORTERS: list[tuple[str, Callable]] = [
    ("stores", import_stores),
    ("commodities", import_commodities),
    ("categories", import_categories),
    ("search_terms", import_search_terms),
    ("known_wrong", import_known_wrong),
    ("dupe_allowlist", import_dupe_allowlist),
    ("overrides", import_overrides),
    ("category_excludes", import_category_excludes),
    ("product_urls", import_product_urls),
    ("ingredient_map", import_ingredient_map),
]
