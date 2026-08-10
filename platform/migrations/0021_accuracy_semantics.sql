-- @policy expand-contract
ALTER TABLE commodities ADD COLUMN band_min_micros INTEGER CHECK (band_min_micros IS NULL OR band_min_micros >= 0);
ALTER TABLE commodities ADD COLUMN band_max_micros INTEGER CHECK (band_max_micros IS NULL OR band_max_micros >= 0);
ALTER TABLE capture_batches ADD COLUMN price_mode TEXT;

UPDATE capture_sources SET price_mode = 'in_store' WHERE id = 'direct-fareway-browser';

INSERT INTO guard_definitions (id, scope, severity, description) VALUES
  ('release-price-plausibility', 'release', 'hard', 'Selected prices satisfy authored bands and cross-store extreme-outlier checks.'),
  ('release-package-semantics', 'release', 'hard', 'Selected count bases do not confuse sheets, slices, feet, or case packs with consumer units.'),
  ('release-recipe-arithmetic', 'release', 'hard', 'Recipe ingredient, batch, serving and checkout arithmetic is independently recomputed by the release service.'),
  ('release-ranking-consistency', 'release', 'hard', 'Top-five rankings and free rotation are complete, sorted, and cost-consistent.'),
  ('release-payload-consistency', 'release', 'hard', 'Public release payloads agree semantically with authoritative release tables.');

CREATE TABLE accuracy_risk_samples (
  id TEXT PRIMARY KEY,
  draw_id TEXT NOT NULL REFERENCES accuracy_draws(id),
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  lane TEXT NOT NULL CHECK (lane IN ('board', 'recipe')),
  risk_kind TEXT NOT NULL,
  risk_score INTEGER NOT NULL CHECK (risk_score >= 0),
  release_id TEXT NOT NULL REFERENCES releases(id),
  commodity_id TEXT,
  store_location_id TEXT,
  observation_id TEXT REFERENCES observations(id),
  recipe_slug TEXT,
  evidence_json TEXT NOT NULL DEFAULT '{}',
  verdict TEXT CHECK (verdict IS NULL OR verdict IN ('right', 'wrong', 'cannot_tell')),
  verified_by TEXT,
  verified_at TEXT,
  verdict_evidence_json TEXT NOT NULL DEFAULT '{}',
  UNIQUE (draw_id, ordinal),
  CHECK ((lane = 'board' AND commodity_id IS NOT NULL AND store_location_id IS NOT NULL AND observation_id IS NOT NULL AND recipe_slug IS NULL)
      OR (lane = 'recipe' AND recipe_slug IS NOT NULL))
) STRICT;

CREATE INDEX accuracy_risk_samples_draw ON accuracy_risk_samples(draw_id, lane, ordinal);
