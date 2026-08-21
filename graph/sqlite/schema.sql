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
    -- NULL = no adjudicator has asserted a confidence. A deterministic layer
    -- that MATCHED something writes 1.0; "no pattern matched" is an absence of
    -- knowledge and must stay NULL — attaching certainty to "don't know" is how
    -- a downstream reader comes to trust a row nobody ever vouched for.
    confidence    REAL,
    observed_at   TEXT NOT NULL,
    source_file   TEXT,
    -- Adjudication. A capture file holds every candidate row a search term
    -- returned, NOT a set of confirmed matches: a search for "medjool dates"
    -- legitimately returns Deglet Noor dates too. Storing the raw candidate
    -- preserves the evidence; these two columns record whether it survived
    -- resolution, and why. Only 'include_hit' rows may price a board cell.
    match_status  TEXT NOT NULL DEFAULT 'unadjudicated',
        -- unadjudicated | include_hit | no_include_hit | excluded
        -- | category_excluded | known_wrong | llm_confirmed | llm_rejected
        -- | llm_match_unverified | escalated
        --
        -- llm_match_unverified: the LOCAL model said MATCH with confidence, but
        -- the local model may not mint a price (Phase 0 bench decomposition:
        -- 3 of its 8 gold NO_MATCH cases came back as MATCH at conf 0.95-0.98,
        -- so confidence does not discriminate its false matches). The row waits
        -- in the escalation queue; only the Claude reviewer may upgrade it to
        -- llm_confirmed. 'llm_confirmed' therefore means REVIEWER-confirmed.
    match_reason  TEXT,
    -- Basis plausibility, orthogonal to match_status. A row can be a CORRECT
    -- match and still carry an unusable per-unit price, because the source size
    -- was wrong ("221 fl oz" for a hand-soap pump) or because a loose include
    -- pattern let a different product in ("Cinnamon Swirl Crumb Cake" under
    -- ground-cinnamon). Either way the row computes an impossibly low per-unit
    -- price and would steal the cheapest crown. Flagged rows stay as EVIDENCE
    -- but are barred from pricing a cell.
    basis_flag    TEXT,      -- NULL = plausible | 'low_outlier' | 'no_basis'
    basis_detail  TEXT
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
    -- no_regression | regression | not_run | requeued
    --   requeued: the patch was approved, never applied, and its target could
    --   not be resolved at the time. It has been DEMOTED back to a proposal so
    --   it is re-reviewed. See stage2_review.py --requeue-stuck: an approval
    --   granted under one target-resolution regime must never silently apply
    --   under a different one.
    shadow_verdict     TEXT,
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
-- cell_state — THE ANSWER. One row per (commodity, store), never per capture.
--
-- A grocery board is a state machine, not an event stream: every cell has a
-- current everyday price, sometimes a current ad price, and freshness rules for
-- each. price_observations held 40 rows per cell of which 1 was the answer, and
-- grew ~6,500 rows/day forever. This table is bounded by the CATALOG (633
-- commodities x 7 stores), never by elapsed time.
--
-- It is exported to tracked JSON, which is what makes price history free: every
-- price change is a diff in a commit, so `git log -p graph/state/cell-state.json`
-- IS the history — dated, auditable, stored as deltas, and costing nothing daily.
--
-- The wide per-store file Brad specified still exists as the RENDERED artifact
-- (public/board.json); this is the one place it is computed from.
-- See design/PLAN-price-state-2026-08-20.md.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cell_state (
    commodity_id        TEXT NOT NULL,
    store_id            TEXT NOT NULL,
    -- everyday: the shelf price, refreshed on the capture policy's quarter.
    -- STALENESS IS NOT STORED. everyday_asof + MaxCarryDays is computed at read
    -- time against grocery/capture-policy.ps1, because a window baked in here
    -- would be the fourth private copy of it this estate has had to close.
    everyday_price      REAL,
    everyday_unit_price REAL,
    everyday_unit       TEXT,
    everyday_size       TEXT,
    everyday_product    TEXT,
    everyday_asof       TEXT,
    -- Evidence ids are POINTERS, deliberately not foreign keys. cell_state is
    -- tracked and durable; price_observations is derived, prunable and
    -- rebuildable — a durable table cannot hold a foreign key into a table that
    -- it outlives. The destructive rebuild drill proved it: restoring
    -- cell-state.json into a fresh index failed on FOREIGN KEY constraint
    -- because the evidence rows had not been re-imported yet. A dangling
    -- evidence id means "the receipt was pruned", which is legal; the price and
    -- its as-of date stand on their own.
    everyday_evidence   TEXT,
    -- ad: present only while the store's cycle window contains today.
    ad_price            REAL,
    ad_unit_price       REAL,
    ad_product          TEXT,
    ad_from             TEXT,
    ad_to               TEXT,
    ad_evidence         TEXT,
    -- NULL after an ad window closes = the post-ad verification pull is still
    -- OWED. This is the whole point of tracking ad windows as data: when an ad
    -- ends, somebody must confirm the shelf went back up. Until this is stamped,
    -- verifier.check_ad_reversion_owed reports the cell.
    reverted_checked_at TEXT,
    updated_at          TEXT NOT NULL,
    PRIMARY KEY (commodity_id, store_id)
);
CREATE INDEX IF NOT EXISTS ix_cell_store  ON cell_state(store_id);
CREATE INDEX IF NOT EXISTS ix_cell_asof   ON cell_state(everyday_asof);
CREATE INDEX IF NOT EXISTS ix_cell_adto   ON cell_state(ad_to);

-- ---------------------------------------------------------------------------
-- question_verdicts — adjudication memory, one row per QUESTION.
--
-- resolve() is a pure function of (commodity_id, product_name), so the same
-- question was being answered up to 40 times and stored on 40 rows. Banking it
-- once here means (a) deleting a superseded observation destroys no
-- adjudication work, which is what makes the supersede rule safe, and (b) the
-- resolver can consult it as LAYER 0 — a question answered in a previous run is
-- never asked again, not merely never asked twice within one run.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS question_verdicts (
    commodity_id   TEXT NOT NULL,
    product_key    TEXT NOT NULL,      -- norm_text(product_name)
    product_name   TEXT NOT NULL,      -- a representative raw surface form
    status         TEXT NOT NULL,      -- the match_status this question earns
    reason         TEXT,
    confidence     REAL,
    decided_by     TEXT,               -- 'deterministic' | model id | reviewer
    prompt_version TEXT,
    decided_at     TEXT NOT NULL,
    PRIMARY KEY (commodity_id, product_key)
);
CREATE INDEX IF NOT EXISTS ix_qv_status ON question_verdicts(status);

-- ---------------------------------------------------------------------------
-- Views are DROPped before CREATE so that editing this file actually changes an
-- existing database on its next open. CREATE VIEW IF NOT EXISTS silently keeps
-- the old definition forever, which is how a view bug outlives its fix.

-- The CURRENT surviving rows: for each (commodity, store, product), only that
-- product's NEWEST sighting — an older sighting is superseded by its latest one
-- (the price-state supersede rule, applied at read time until Phase C lands it
-- at import). Ad/sale rows are current only while their ad window CONTAINS
-- today; an ad row with no resolvable window is never current (an expired
-- 07-23 blueberries sale was crowning its cell a month later). Everyday AGE is
-- deliberately NOT gated here: the 90-day window lives in capture-policy.ps1
-- and a literal here would be another private copy — check_row_age reads the
-- canonical value at run time instead. The ad window has no such problem: the
-- window data lives in this database, on the AdCycle node.
DROP VIEW IF EXISTS v_current_rows;
CREATE VIEW v_current_rows AS
SELECT * FROM (
    SELECT p.*,
           ROW_NUMBER() OVER (
               PARTITION BY p.commodity_id, p.store_id, lower(trim(COALESCE(p.product_name,'')))
               ORDER BY p.observed_at DESC, p.price ASC, p.id ASC
           ) AS prn
    FROM price_observations p
    WHERE p.match_status IN ('include_hit', 'llm_confirmed')
      AND p.basis_flag IS NULL
      AND (COALESCE(p.price_type,'') NOT IN ('ad','sale')
           OR EXISTS (SELECT 1 FROM nodes ac
                      WHERE ac.id = p.ad_cycle_id
                        AND date('now','localtime')
                            BETWEEN json_extract(ac.properties_json,'$.from')
                                AND json_extract(ac.properties_json,'$.to')))
)
WHERE prn = 1;

-- Newest CURRENT observation per (commodity, store) — the graph's answer to
-- "the board". Restricted to rows that passed resolution: a candidate row that
-- failed its include regex, hit an exclude, or matched a known-wrong ruling must
-- never be able to price a cell. That restriction is the whole point.
--
-- Exactly ONE row per cell, by construction. observed_at is a DATE, so every
-- candidate a sweep captured the same day ties on "newest" — a plain
-- MAX(observed_at) join returned 3.9 rows per cell (207 for deodorant at
-- family-fare) and left the reader to collapse them arbitrarily. Ties are
-- broken deterministically: cheapest per-unit first (board semantics), rows
-- with no unit price last, then price, then id so replays are stable.
DROP VIEW IF EXISTS v_current_cell;
CREATE VIEW v_current_cell AS
SELECT * FROM (
    SELECT p.*,
           ROW_NUMBER() OVER (
               PARTITION BY p.commodity_id, p.store_id
               ORDER BY p.observed_at DESC,
                        (p.unit_price IS NULL) ASC,
                        p.unit_price ASC,
                        p.price ASC,
                        p.id ASC
           ) AS rn
    FROM v_current_rows p
)
WHERE rn = 1;

-- Cheapest CURRENT per-unit candidate per cell — the "crown" the board
-- renders. MIN(price) was the modelling error this view is named to prevent:
-- a small dear package beats a large cheap one on shelf price while being the
-- worse buy (sampled: 114 of 200 multi-candidate cells crowned the wrong row).
-- Selecting over v_current_rows (not raw observations) is equally load-bearing:
-- a flat minimum over history crowns the cheapest price EVER SEEN, not the
-- current one, and old low prices win forever.
DROP VIEW IF EXISTS v_cell_crown;
CREATE VIEW v_cell_crown AS
SELECT * FROM (
    SELECT p.commodity_id, p.store_id, p.id AS observation_id, p.product_name,
           p.price, p.unit_price, p.unit, p.observed_at,
           COUNT(*) OVER (PARTITION BY p.commodity_id, p.store_id) AS n_candidates,
           ROW_NUMBER() OVER (
               PARTITION BY p.commodity_id, p.store_id
               ORDER BY (p.unit_price IS NULL) ASC,
                        p.unit_price ASC,
                        p.price ASC,
                        p.id ASC
           ) AS rn
    FROM v_current_rows p
    WHERE p.price IS NOT NULL
)
WHERE rn = 1;

-- Full provenance join for the "why does this price appear?" question.
DROP VIEW IF EXISTS v_price_why;
CREATE VIEW v_price_why AS
SELECT p.id, p.commodity_id, p.store_id, p.product_name, p.price, p.unit_price,
       p.unit, p.is_sale, p.observed_at,
       v.source_document, v.extraction_method, v.model, v.timestamp AS extracted_at
FROM price_observations p
LEFT JOIN provenance v ON v.id = p.provenance_id;
