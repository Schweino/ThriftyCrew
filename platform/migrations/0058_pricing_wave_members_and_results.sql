-- @policy expand-contract
CREATE TABLE pricing_wave_members (
  wave_id TEXT NOT NULL REFERENCES pricing_waves(id),
  pricing_job_id TEXT NOT NULL REFERENCES ingredient_pricing_jobs(id),
  gap_id TEXT NOT NULL REFERENCES ingredient_gaps(id),
  joined_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (wave_id, pricing_job_id),
  UNIQUE (wave_id, gap_id)
) STRICT;

CREATE INDEX pricing_wave_members_job ON pricing_wave_members(pricing_job_id, wave_id);

INSERT OR IGNORE INTO pricing_wave_members (wave_id, pricing_job_id, gap_id)
SELECT wave_id, id, gap_id FROM ingredient_pricing_jobs WHERE wave_id IS NOT NULL;

ALTER TABLE ingredient_store_checks ADD COLUMN result_json TEXT;
ALTER TABLE ingredient_pricing_jobs ADD COLUMN commodity_proposal_json TEXT;
ALTER TABLE ingredient_pricing_jobs ADD COLUMN commodity_proposal_hash TEXT;
