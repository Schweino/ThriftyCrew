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
`llm_match_unverified` · `escalated`

**Only `include_hit` and `llm_confirmed` may price a cell** — enforced in
`v_current_cell`, and re-checked by `verifier.check_no_unresolved_pricing`.

**The local model may only reject, never mint a price** (decision 2026-08-20).
A confident local NO_MATCH becomes `llm_rejected`; a confident local MATCH
becomes `llm_match_unverified`, which cannot price and waits in the escalation
queue (`kind: confirm_match`) for the Claude reviewer. `llm_confirmed` therefore
means *reviewer-confirmed* — the reviewer is the only writer of that status.
Why: the Phase 0 bench decomposed by label shows the local model at 22/22 on
gold MATCH but 5/8 on gold NO_MATCH, with all three errors being false MATCHes
at confidence 0.95–0.98 — above any usable escalation threshold. Confidence
does not discriminate this model's false matches, so no threshold makes a local
MATCH safe to publish.

`confidence` is nullable: NULL means no adjudicator asserted anything (raw
capture, `no_include_hit`, post-`--reset`). Deterministic layers that matched
assert 1.0; the LLM layer asserts the model's own number.

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

Views are `DROP`ped and recreated by `schema.sql` on every open, so an edited
view definition actually reaches existing databases (`CREATE VIEW IF NOT
EXISTS` kept old definitions alive forever, which is how the same-day-tie bug
below survived its own fix).

- `v_current_cell` — newest **surviving** observation per (commodity, store),
  **exactly one row per cell**. `observed_at` is a date, so same-day candidates
  tie on "newest"; ties break deterministically (cheapest per-unit, no-unit-
  price rows last, then price, then id).
- `v_cell_crown` — cheapest surviving **per-unit** candidate per cell (never
  `MIN(price)`: a small dear package beats a large cheap one on shelf price
  while being the worse buy), `basis_flag IS NULL` enforced.
- `v_price_why` — observation joined to its provenance; answers "why does this
  price appear?" on its own.

## Price state (2026-08-20) — the answer, not the log

`cell_state` and `question_verdicts` implement
`design/PLAN-price-state-2026-08-20.md`. The estate stored a grocery board as an
event stream — 128,162 observations over 37 days, ~40 rows per cell of which one
was the answer, growing ~6,500/day with no retention. A board is a **state
machine**, and these two tables say so.

| table | one row per | grows with |
|---|---|---|
| `cell_state` | (commodity, store) | the CATALOG |
| `question_verdicts` | (commodity, product) | new PRODUCTS |
| `price_observations` | surviving evidence | store ASSORTMENT |

None of them grows with time. Measured: 130,240 observations → 27,116 after the
supersede-prune, 3,149 cells, 8.6 evidence rows per answer.

**`cell_state` is tracked JSON, and that is the price historian.** Every change
is a commit diff, so history is dated, auditable, stored as deltas, and costs
nothing daily. There is no history table and no rollup because there does not
need to be one.

**Evidence ids are pointers, never foreign keys.** `cell_state` is durable;
`price_observations` is derived and prunable, and a durable table cannot hold a
foreign key into one it outlives — the destructive rebuild drill proved it by
failing on exactly that constraint. A dangling evidence id means the receipt was
pruned, which is legal; the price and its as-of date stand alone.

**Only EXPENSIVE verdicts are banked.** Deterministic ones re-derive in ~1.5s for
100k rows and would freeze the very rules the next `commodities.json` edit is
meant to change; banking them also made the tracked export 11.5 MB of daily churn
for answers nobody reads. What is banked: model calls (55 GPU-minutes to
reproduce), reviewer rulings, known-wrong. The resolver consults them at **layer
4.5** — after the deterministic layers so a new rule still wins, before the model
so a question is never paid for twice.

**A banked verdict carries an AUTHORITY TIER (2026-08-22).** `decided_by` used to
be derived from the status prefix — `"model" if status.startswith("llm_")` — so a
Claude reviewer's ruling, which lands as `llm_confirmed`/`llm_rejected` because
those are *match statuses, not authorship*, was stamped `model` exactly like the
local model's own guess. The column held two values across 4,141 rows and told
nobody anything, while `resolve.py` cited all of them to the model as precedent:
3,315 of the 3,692 rejections are the model's own unreviewed work. `graph/lib/authority.py`
now derives the tier from the reason's authorship marker (`reviewer ...`,
`adjudicated ...`, `llm: ...`, under any number of `banked: ` re-bank prefixes),
`state.py` stamps `decided_by` honestly going forward, and only **adjudicated**
rulings are shown to the model as precedent — model-consensus ones are labelled
tentative, single-model ones are not shown at all. The tier is re-derived from
`reason` at read time, so a bank written before this change is stale, never wrong.
ADVISORY ONLY: it changes what the model is TOLD, never what may price a cell.

**Freshness is data.** `everyday_asof` + `MaxCarryDays` (read from
`grocery/capture-policy.ps1`, never copied) decides staleness; `ad_from`/`ad_to`
bound an ad price to its window; `reverted_checked_at` NULL after a window closes
means the post-ad verification pull is still OWED, and
`verifier.check_ad_reversion_owed` turns that into a red gate rather than a
silent assumption.
