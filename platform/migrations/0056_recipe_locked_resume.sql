-- @policy expand-contract
-- Pin held recipes to immutable fact and mapping versions without rewriting
-- the legacy hold representation during the dual-write canary.

ALTER TABLE recipe_ingredient_holds ADD COLUMN source_fact_version_id TEXT REFERENCES recipe_source_fact_versions(id);
ALTER TABLE recipe_ingredient_holds ADD COLUMN mapping_version_id TEXT REFERENCES recipe_mapping_versions(id);
ALTER TABLE recipe_ingredient_holds ADD COLUMN resume_error TEXT;

PRAGMA optimize;
