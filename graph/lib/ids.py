"""Deterministic identifiers and hashing for the ThriftyCrew knowledge graph.

Every id in the graph is DETERMINISTIC: the same real-world thing always produces
the same id, on every machine, on every run. That is what makes the dual-write
phases comparable and what lets `rebuild.py` reconstruct the SQLite index from the
tracked JSON without inventing new identity.

Nothing here uses random or time-based ids. Provenance and event ids are derived
from their own content plus the run id, so a replayed run is idempotent.
"""

from __future__ import annotations

import hashlib
import json
import re
import unicodedata

# --------------------------------------------------------------------------
# hashing
# --------------------------------------------------------------------------


def sha256(text: str) -> str:
    """Hex sha256 of a string (UTF-8)."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def short(text: str, n: int = 16) -> str:
    """Short stable digest, used inside composite ids."""
    return sha256(text)[:n]


def hash_obj(obj) -> str:
    """Stable hash of any JSON-serialisable object (key order independent)."""
    return sha256(json.dumps(obj, sort_keys=True, separators=(",", ":"), default=str))


# --------------------------------------------------------------------------
# normalisation
# --------------------------------------------------------------------------

_WS = re.compile(r"\s+")
_NONWORD = re.compile(r"[^a-z0-9]+")


def norm_text(s: str | None) -> str:
    """Normalise a free-text surface form for comparison/blocking.

    Lowercase, strip accents, collapse whitespace. Deliberately NOT aggressive:
    it keeps digits and internal punctuation meaning (e.g. "93/7", "1/3 fat")
    because those distinctions are load-bearing in this catalog.
    """
    if not s:
        return ""
    s = unicodedata.normalize("NFKD", str(s))
    s = "".join(c for c in s if not unicodedata.combining(c))
    return _WS.sub(" ", s.lower()).strip()


def slug(s: str | None) -> str:
    """Kebab-case slug, matching the existing commodity id convention.

    'Boneless Skinless Chicken Breast' -> 'boneless-skinless-chicken-breast'
    '1/3 Fat Cream Cheese'             -> '1-3-fat-cream-cheese'
    """
    return _NONWORD.sub("-", norm_text(s)).strip("-")


# The seven Omaha stores, and every surface form they appear under across the
# repo. This table is load-bearing: known-wrong.json writes "Bakers" while the
# capture files write "Baker's", and a naive slug would split one real store into
# two nodes — the exact missed-merge the plan puts a metric on. Extend this table
# rather than "fixing" a caller.
STORE_CANON = {
    "hy-vee": "hyvee", "hyvee": "hyvee", "hy vee": "hyvee",
    "aldi": "aldi",
    "baker-s": "bakers", "bakers": "bakers", "baker s": "bakers", "baker's": "bakers",
    "family-fare": "family-fare", "family fare": "family-fare", "familyfare": "family-fare",
    "fareway": "fareway",
    "walmart": "walmart", "wal-mart": "walmart", "wal mart": "walmart",
    "sam-s-club": "sams", "sams-club": "sams", "sam s club": "sams",
    "sam's club": "sams", "sams": "sams", "sam-s": "sams", "sam's": "sams",
}

STORE_LABEL = {
    "hyvee": "Hy-Vee", "aldi": "Aldi", "bakers": "Baker's",
    "family-fare": "Family Fare", "fareway": "Fareway",
    "walmart": "Walmart", "sams": "Sam's Club",
}


def norm_store(name: str | None) -> str:
    """Canonical store slug, resolving the punctuation drift across the repo."""
    if not name:
        return ""
    raw = norm_text(name)
    if raw in STORE_CANON:
        return STORE_CANON[raw]
    s = slug(name)
    return STORE_CANON.get(s, s)


def store_label(slug_or_name: str) -> str:
    """Display name for a store slug, for board/report rendering."""
    s = norm_store(slug_or_name)
    return STORE_LABEL.get(s, slug_or_name)


# --------------------------------------------------------------------------
# node ids
# --------------------------------------------------------------------------
# Ids are prefixed by type so a bare id is self-describing in a log line.


def store_id(name: str) -> str:
    return f"store:{norm_store(name)}"


def commodity_id(cid: str, namespace: str = "staple") -> str:
    """Commodity id.

    `namespace` preserves the three separate id namespaces this repo maintains
    (staple commodities.json, recipe-commodities.json, and recipe floor ids).
    Collapsing them would be exactly the false-merge the plan warns about:
    'ground-turkey' (staple) and '93-7-ground-turkey' (recipe) are different
    purchases on purpose.
    """
    return f"commodity:{namespace}:{cid}"


def category_id(key: str) -> str:
    return f"category:{slug(key)}"


def sku_id(store: str, raw_name: str, size: str | None = None) -> str:
    """A store's product listing. Identity = (store, product name, size)."""
    basis = f"{norm_store(store)}|{norm_text(raw_name)}|{norm_text(size)}"
    return f"sku:{norm_store(store)}:{short(basis, 20)}"


def adcycle_id(store: str, frm: str, to: str) -> str:
    return f"adcycle:{norm_store(store)}:{frm}_{to}"


def recipe_id(rid: str) -> str:
    return f"recipe:{slug(rid)}"


def observation_id(commodity: str, store: str, observed_at: str, source_file: str,
                   product_name: str | None = None) -> str:
    """PriceObservation id.

    Includes the source file so two captures on the same day from different lanes
    (e.g. an ad pull and a browser capture) stay distinct facts rather than one
    silently overwriting the other.
    """
    basis = "|".join([
        commodity, norm_store(store), observed_at,
        source_file or "", norm_text(product_name),
    ])
    return f"po:{short(basis, 24)}"


def known_wrong_id(commodity: str, store: str, product: str) -> str:
    basis = f"{commodity}|{norm_store(store)}|{norm_text(product)}"
    return f"knownwrong:{short(basis, 20)}"


def override_id(commodity: str, store: str) -> str:
    return f"override:{norm_store(store)}:{commodity}"


def catexclude_id(cls: str, pattern: str) -> str:
    return f"catexclude:{slug(cls)}:{short(pattern, 12)}"


def mapping_id(item: str, board_id: str) -> str:
    return f"ingmap:{short(norm_text(item) + '|' + board_id, 20)}"


# --------------------------------------------------------------------------
# edge / provenance / event ids
# --------------------------------------------------------------------------


def edge_id(source: str, predicate: str, target: str) -> str:
    return f"e:{short(f'{source}|{predicate}|{target}', 24)}"


def provenance_id(source_document: str, extraction_method: str, timestamp: str,
                  raw_output_hash: str | None = None) -> str:
    basis = f"{source_document}|{extraction_method}|{timestamp}|{raw_output_hash or ''}"
    return f"prov:{short(basis, 24)}"


def event_id(run_id: str, step_id: str | None, kind: str, payload_hash: str) -> str:
    return f"ev:{short(f'{run_id}|{step_id or ''}|{kind}|{payload_hash}', 24)}"


def run_id(kind: str, stamp: str) -> str:
    """Run id from an explicitly-passed timestamp (never an implicit clock read,
    so a replay reproduces the same id)."""
    return f"run:{kind}:{stamp}"
