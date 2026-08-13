-- @policy expand-contract
-- Collector/QA separation, complete search coverage, and capture scope linkage.

ALTER TABLE ingredient_store_checks ADD COLUMN capture_result_json TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN candidate_set_hash TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN producer_evidence_id TEXT REFERENCES ingredient_evidence_refs(id);
ALTER TABLE ingredient_store_checks ADD COLUMN verifier_evidence_id TEXT REFERENCES ingredient_evidence_refs(id);

ALTER TABLE ingredient_query_coverage ADD COLUMN retailer_result_total INTEGER CHECK (retailer_result_total IS NULL OR retailer_result_total >= 0);
ALTER TABLE ingredient_query_coverage ADD COLUMN cursors_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE ingredient_query_coverage ADD COLUMN end_of_results_proven INTEGER NOT NULL DEFAULT 0 CHECK (end_of_results_proven IN (0,1));
ALTER TABLE ingredient_query_coverage ADD COLUMN pagination_hash TEXT;
ALTER TABLE ingredient_query_coverage ADD COLUMN query_plan_hash TEXT;
ALTER TABLE ingredient_query_coverage ADD COLUMN producer_version TEXT;

ALTER TABLE ingredient_store_candidates ADD COLUMN product_url TEXT;
ALTER TABLE ingredient_store_candidates ADD COLUMN seller_name TEXT;
ALTER TABLE ingredient_store_candidates ADD COLUMN fulfillment_state TEXT;
ALTER TABLE ingredient_store_candidates ADD COLUMN availability_state TEXT;
ALTER TABLE ingredient_store_candidates ADD COLUMN offer_id TEXT;
ALTER TABLE ingredient_store_candidates ADD COLUMN regular_price_minor INTEGER CHECK (regular_price_minor IS NULL OR regular_price_minor >= 0);
ALTER TABLE ingredient_store_candidates ADD COLUMN producer_evidence_hash TEXT;
ALTER TABLE ingredient_store_candidates ADD COLUMN verifier_evidence_hash TEXT;
ALTER TABLE ingredient_store_candidates ADD COLUMN originating_query TEXT;

CREATE TABLE ingredient_targeted_capture_scopes (
  store_check_id TEXT NOT NULL REFERENCES ingredient_store_checks(id),
  scope_id TEXT NOT NULL REFERENCES capture_scopes(id),
  query_plan_hash TEXT NOT NULL,
  attached_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (store_check_id, scope_id)
) STRICT;

CREATE INDEX ingredient_targeted_capture_scopes_scope ON ingredient_targeted_capture_scopes(scope_id, store_check_id);

PRAGMA optimize;
