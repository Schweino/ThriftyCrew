-- ThriftyCrew knowledge graph — SQLite schema
-- Phase 1 deliverable. See graph/schema.md for the canonical prose definition.
--
-- THIS DATABASE IS AN INDEX, NEVER THE SOLE HOLDER OF TRUTH.
-- Every row here is reproducible from the tracked JSON under graph/nodes, graph/edges,
-- graph/aliases and graph/provenance by `python graph/lib/rebuild.py`. The .db file is
-- gitignored on purpose: it keeps the git-bus small and preserves the single-writer rule
-- (only the local daily pipeline writes; agents and audits read).

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------------
-- provenance — written FIRST, referenced by everything that asserts a fact.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS provenance (
    id                TEXT PRIMARY KEY,
    source_document   TEXT NOT NULL,          -- repo-relative path or URL
    extraction_method TEXT NOT NULL,          -- e.g. 'import:commodities.json', 'local-extract-v1'
    model             TEXT,                   -- NULL for deterministic imports
    prompt_version    TEXT,                   -- e.g. 'extract.v1' — NULL for deterministic imports
    timestamp         TEXT NOT NULL,          -- ISO-8601
    raw_output_hash   TEXT,                   -- sha256 of the raw model output / source slice
    run_id            TEXT
);
CREATE INDEX IF NOT EXISTS ix_prov_run    ON provenance(run_id);
CREATE INDEX IF NOT EXISTS ix_prov_source ON provenance(source_document);
CREATE INDEX IF NOT EXISTS ix_prov_method ON provenance(extraction_method);

-- ---------------------------------------------------------------------------
-- nodes
-- ---------------------------------------------------------------------------
-- type ∈ Store | Commodity | ProductSKU | AdCycle | AdPage | PriceObservation
--        | Recipe | IngredientMapping | KnownWrong | Override | CategoryExclude
--        | AuditFinding | Incident | Category
CREATE TABLE IF NOT EXISTS nodes (
    id             TEXT PRIMARY KEY,
    type           TEXT NOT NULL,
    canonical_name TEXT NOT NULL,
    description    TEXT,
    properties_json TEXT NOT NULL DEFAULT '{}',
    provenance_id  TEXT REFERENCES provenance(id),
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_nodes_type ON nodes(type);
CREATE INDEX IF NOT EXISTS ix_nodes_name ON nodes(canonical_name);
CREATE INDEX IF NOT EXISTS ix_nodes_type_name ON nodes(type, canonical_name);

-- ---------------------------------------------------------------------------
-- edges
-- ---------------------------------------------------------------------------
-- predicate ∈ sold_at | priced_as | instance_of | in_category | excluded_from
--             | known_wrong_for | overrides | maps_to | uses_ingredient
--             | belongs_to_cycle | do_not_merge | same_as | flagged_by
CREATE TABLE IF NOT EXISTS edges (
    id             TEXT PRIMARY KEY,
    source_id      TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    target_id      TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    predicate      TEXT NOT NULL,
    properties_json TEXT NOT NULL DEFAULT '{}',
    provenance_id  TEXT REFERENCES provenance(id),
    confidence     REAL NOT NULL DEFAULT 1.0,
    created_at     TEXT NOT NULL,
    UNIQUE(source_id, target_id, predicate)
);
CREATE INDEX IF NOT EXISTS ix_edges_src  ON edges(source_id, predicate);
CREATE INDEX IF NOT EXISTS ix_edges_tgt  ON edges(target_id, predicate);
CREATE INDEX IF NOT EXISTS ix_edges_pred ON edges(predicate);

-- ---------------------------------------------------------------------------
-- aliases — surface forms. In THIS codebase an alias is usually a regex
-- `include` pattern lifted from commodities.json, so `is_regex` matters.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS aliases (
    node_id    TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    alias      TEXT NOT NULL,
    kind       TEXT NOT NULL DEFAULT 'include',   -- include | exclude | search_term | label | learned
    is_regex   INTEGER NOT NULL DEFAULT 0,
    source     TEXT NOT NULL,                     -- file or learning-patch id
    confidence REAL NOT NULL DEFAULT 1.0,
    provenance_id TEXT REFERENCES provenance(id),
    created_at TEXT NOT NULL,
    PRIMARY KEY (node_id, alias, kind)
);
CREATE INDEX IF NOT EXISTS ix_alias_alias ON aliases(alias);
CREATE INDEX IF NOT EXISTS ix_alias_kind  ON aliases(node_id, kind);

-- ---------------------------------------------------------------------------
-- price_observations — the central fact type. Denormalised out of nodes
-- because it is by far the highest-volume and most-queried structure.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS price_observations (
    id            TEXT PRIMARY KEY,
    commodity_id  TEXT NOT NULL,
    store_id      TEXT NOT NULL,
    product_name  TEXT,                    -- the raw store string this came from
    price         REAL,
    unit_price    REAL,
    unit          TEXT,
    size_text     TEXT,
    is_sale       INTEGER NOT NULL DEFAULT 0,
    price_type    TEXT,                    -- 'everyday' | 'sale' | 'ad'
    ad_cycle_id   TEXT,
    provenance_id TEXT NOT NULL REFERENCES provenance(id),
    confidence    REAL NOT NULL DEFAULT 1.0,
    observed_at   TEXT NOT NULL,
    source_file   TEXT,
    -- Adjudication. A capture file holds every candidate row a search term
    -- returned, NOT a set of confirmed matches: a search for "medjool dates"
    -- legitimately returns Deglet Noor dates too. Storing the raw candidate
    -- preserves the evidence; these two columns record whether it survived
    -- resolution, and why. Only 'include_hit' rows may price a board cell.
    match_status  TEXT NOT NULL DEFAULT 'unadjudicated',
        -- unadjudicated | include_hit | no_include_hit | excluded
        -- | category_excluded | known_wrong | llm_confirmed | llm_rejected | escalated
    match_reason  TEXT
);
CREATE INDEX IF NOT EXISTS ix_po_commodity ON price_observations(commodity_id, observed_at DESC);
CREATE INDEX IF NOT EXISTS ix_po_store     ON price_observations(store_id, observed_at DESC);
CREATE INDEX IF NOT EXISTS ix_po_cell      ON price_observations(commodity_id, store_id, observed_at DESC);
CREATE INDEX IF NOT EXISTS ix_po_cycle     ON price_observations(ad_cycle_id);

-- ---------------------------------------------------------------------------
-- decision_log — §10 of the plan. Every model call and state transition.
-- The audit trail that answers "why does this price appear?".
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS decision_log (
    event_id      TEXT PRIMARY KEY,
    run_id        TEXT NOT NULL,
    timestamp     TEXT NOT NULL,
    type          TEXT NOT NULL,   -- extract|resolve|verify|escalate|state_transition
                                   -- |learning_proposal|learning_approval|gate|tool
    step_id       TEXT,
    model         TEXT,
    input_hash    TEXT,
    output_hash   TEXT,
    confidence    REAL,
    decision      TEXT,
    detail_json   TEXT NOT NULL DEFAULT '{}',
    provenance_ids TEXT NOT NULL DEFAULT '[]'
);
CREATE INDEX IF NOT EXISTS ix_dlog_run  ON decision_log(run_id, timestamp);
CREATE INDEX IF NOT EXISTS ix_dlog_type ON decision_log(type, timestamp DESC);

-- ---------------------------------------------------------------------------
-- Learning loop (Phase 5)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS learning_proposals (
    id           TEXT PRIMARY KEY,
    created_at   TEXT NOT NULL,
    model        TEXT NOT NULL,           -- the Stage-1 local model
    queue_hash   TEXT,                    -- hash of the queue slice analysed
    kind         TEXT NOT NULL,           -- add_alias|add_known_wrong|add_gold|tighten_prompt
    target_id    TEXT,                    -- commodity/node the suggestion touches
    payload_json TEXT NOT NULL,
    confidence   REAL NOT NULL,
    rationale    TEXT,
    status       TEXT NOT NULL DEFAULT 'proposed'
                 -- proposed|accepted|rejected|modified|deferred|held_for_human|applied|reverted
);
CREATE INDEX IF NOT EXISTS ix_lp_status ON learning_proposals(status, created_at);

CREATE TABLE IF NOT EXISTS approved_patches (
    id            TEXT PRIMARY KEY,
    proposal_id   TEXT NOT NULL REFERENCES learning_proposals(id),
    reviewed_at   TEXT NOT NULL,
    reviewer      TEXT NOT NULL,          -- 'claude-fable-medium'
    verdict       TEXT NOT NULL,          -- accept|reject|modify|defer|hold_for_human
    payload_json  TEXT NOT NULL,          -- possibly-modified payload
    rationale     TEXT,
    -- shadow evaluation, recorded BEFORE anything goes live
    shadow_before_json TEXT,
    shadow_after_json  TEXT,
    shadow_verdict     TEXT,              -- no_regression | regression | not_run
    applied_at    TEXT,
    applied_by    TEXT
);
CREATE INDEX IF NOT EXISTS ix_ap_verdict ON approved_patches(verdict, reviewed_at);

-- ---------------------------------------------------------------------------
-- eval_runs — every gold-set scoring, with the exact prompt/model versions.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS eval_runs (
    id              TEXT PRIMARY KEY,
    run_at          TEXT NOT NULL,
    model           TEXT,
    prompt_version  TEXT,
    gold_version    TEXT,
    entity_precision REAL, entity_recall REAL,
    relation_precision REAL, relation_recall REAL,
    false_merge_rate REAL, missed_merge_rate REAL,
    n_gold INTEGER, n_pred INTEGER,
    context         TEXT,           -- 'phase2' | 'shadow:<patch_id>' | 'bench'
    detail_json     TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS ix_eval_at ON eval_runs(run_at DESC);

-- ---------------------------------------------------------------------------
-- Convenience views
-- ---------------------------------------------------------------------------
-- Newest SURVIVING observation per (commodity, store) — the graph's answer to
-- "the board". Restricted to rows that passed resolution: a candidate row that
-- failed its include regex, hit an exclude, or matched a known-wrong ruling must
-- never be able to price a cell. That restriction is the whole point.
CREATE VIEW IF NOT EXISTS v_current_cell AS
SELECT p.*
FROM price_observations p
JOIN (
    SELECT commodity_id, store_id, MAX(observed_at) AS mx
    FROM price_observations
    WHERE match_status IN ('include_hit', 'llm_confirmed')
    GROUP BY commodity_id, store_id
) t ON t.commodity_id = p.commodity_id
   AND t.store_id     = p.store_id
   AND t.mx           = p.observed_at
WHERE p.match_status IN ('include_hit', 'llm_confirmed');

-- Cheapest surviving per-unit candidate per cell — the "crown" the board renders.
CREATE VIEW IF NOT EXISTS v_cell_crown AS
SELECT commodity_id, store_id, MIN(price) AS best_price, COUNT(*) AS n_candidates
FROM price_observations
WHERE match_status IN ('include_hit', 'llm_confirmed') AND price IS NOT NULL
GROUP BY commodity_id, store_id;

-- Full provenance join for the "why does this price appear?" question.
CREATE VIEW IF NOT EXISTS v_price_why AS
SELECT p.id, p.commodity_id, p.store_id, p.product_name, p.price, p.unit_price,
       p.unit, p.is_sale, p.observed_at,
       v.source_document, v.extraction_method, v.model, v.timestamp AS extracted_at
FROM price_observations p
LEFT JOIN provenance v ON v.id = p.provenance_id;
