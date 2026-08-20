# Canonical graph schema

Phase 1 deliverable. This is the living definition; `sqlite/schema.sql` is its
mechanical form. Change them together, and re-score the gold set afterwards.

## Design commitments

1. **Provenance-first.** Every node, edge, alias and observation carries a
   `provenance_id`. `record_provenance()` is the only minting path, and
   `verifier.check_provenance_complete` fails the run on an orphan.
2. **Deterministic ids.** The same real-world thing yields the same id on every
   machine and every run (`lib/ids.py`). No random or clock-derived ids, which is
   what makes re-import idempotent and replay meaningful.
3. **The DB is an index.** Truth lives in the tracked JSON. `graph.db` is
   gitignored and rebuildable.
4. **Additive.** Writes are upserts. Retraction is explicit and logged.

## Node types

| type | id form | key properties |
|---|---|---|
| `Store` | `store:<slug>` | `omaha_identity`, `pull_method`, `cadence_days`, `ad_window`, `next_pull` |
| `Commodity` | `commodity:<ns>:<legacy_id>` | `legacy_id`, `namespace`, `unit_basis`, `band_min/max` |
| `Category` | `category:<slug>` | `key`, `order` |
| `ProductSKU` | `sku:<store>:<hash>` | `url`, `price`, `size`, `store`, `verified` |
| `AdCycle` | `adcycle:<store>:<from>_<to>` | `from`, `to`, `detected`, `is_current` |
| `KnownWrong` | `knownwrong:<hash>` | `commodity`, `store`, `product_id`, `verdict` |
| `Override` | `override:<store>:<commodity>` | `per_unit`, `store`, `commodity` |
| `CategoryExclude` | `catexclude:<class>:<hash>` | `class`, `pattern`, `applies_to_categories`, `exempt` |
| `IngredientMapping` | `ingmap:<hash>` | `board`, `unit`, `grams_per_unit`, `board_id` |
| `Recipe`, `AdPage`, `AuditFinding`, `Incident` | — | reserved; not yet populated |

### The three commodity namespaces are NOT merged

`<ns>` is one of `staple` (from `commodities.json`, 574 rows) or `recipe` (from
`recipe-commodities.json`, 59 rows). They are kept apart on purpose: staple
`ground-turkey` and recipe `93-7-ground-turkey` are genuinely different
purchases, and collapsing them is precisely the false merge the plan puts a
metric on. `commodity-dupe-allowlist.json` records the pairs a human already
ruled distinct, imported as `do_not_merge` edges.

## Predicates

| predicate | from → to | meaning |
|---|---|---|
| `instance_of` | ProductSKU → Commodity | this store listing is that commodity |
| `sold_at` | ProductSKU/KnownWrong/Override → Store | which store |
| `in_category` | Commodity → Category | board categorisation |
| `known_wrong_for` | KnownWrong → Commodity | adjudicated negative, absolute |
| `do_not_merge` | Commodity ↔ Commodity | reviewed distinct; blocks resolution merging |
| `overrides` | Override → Commodity | a pinned per-unit correction |
| `maps_to` | IngredientMapping → Commodity | recipe ingredient → board row |
| `belongs_to_cycle` | AdCycle → Store | weekly ad window |
| `same_as`, `excluded_from`, `uses_ingredient`, `priced_as`, `flagged_by` | — | reserved |

## Aliases

An alias is a surface form. In this catalog most aliases are **regexes**, because
the legacy resolution mechanism is `include`/`exclude` pattern arrays — so
`is_regex` is load-bearing, not decorative.

| kind | source | used by |
|---|---|---|
| `include` | `commodities.json.include` | resolver layer 4 (a hit is a match) |
| `exclude` | `commodities.json.exclude` | resolver layer 3 (absolute) |
| `search_term` | `commodity-search.json` | maps a capture's `found_by_term` back to a commodity |
| `label` | the commodity's display name | display, fuzzy lookup |
| `learned` | the learning loop | added only through the shadow gate |

## PriceObservation

The central fact type, denormalised out of `nodes` for volume.

Required: `id, commodity_id, store_id, provenance_id, observed_at`.
Carried: `product_name, price, unit_price, unit, size_text, is_sale, price_type,
ad_cycle_id, confidence, source_file`.

### `match_status` — why a raw candidate is stored at all

A capture file holds **every candidate row a search term returned**, not a set of
confirmed matches. Searching Walmart for "medjool dates" legitimately returns
Deglet Noor dates, cheese crackers and Oreos. Storing the raw candidate preserves
the evidence; `match_status` records whether it survived resolution:

`unadjudicated` · `include_hit` · `no_include_hit` · `excluded` ·
`category_excluded` · `known_wrong` · `llm_confirmed` · `llm_rejected` ·
`escalated`

**Only `include_hit` and `llm_confirmed` may price a cell** — enforced in
`v_current_cell`, and re-checked by `verifier.check_no_unresolved_pricing`.

### Unit basis is not optional

A unit price is meaningless without its basis. The capture engine reports milk
per *fluid ounce* while the board declares milk's basis as *gallon*; comparing
those raw understates milk 128-fold and would hand it a fake "cheapest" crown.
`units.reconcile_unit` converts only where the conversion is exact and returns
`None` otherwise. Refusing costs one empty cell; guessing publishes a lie.

## Decision log

Every model call and state transition appends to `decision_log` and mirrors to
`graph/provenance/<run>.jsonl` (tracked).

Types: `extract · resolve · verify · escalate · state_transition ·
learning_proposal · learning_approval · gate · tool`.

## Learning tables

`learning_proposals` (Stage 1 output; `status`: proposed → accepted/rejected/
modified/deferred/held_for_human → applied/reverted) and `approved_patches`
(Stage 2 verdict plus `shadow_before_json` / `shadow_after_json` /
`shadow_verdict`). A patch may not go live with `shadow_verdict != 'no_regression'`.

## Views

- `v_current_cell` — newest **surviving** observation per (commodity, store).
- `v_cell_crown` — cheapest surviving candidate per cell.
- `v_price_why` — observation joined to its provenance; answers "why does this
  price appear?" on its own.
