-- @policy contract
-- @restore-proof d1-time-travel-and-immutable-r2-archive-ledger
-- Verified hot/cold retention: archive membership remains an immutable restore
-- ledger after the corresponding operational observation is removed from D1.

ALTER TABLE archive_manifests ADD COLUMN completed_at TEXT;

DROP TRIGGER archive_manifest_rows_no_update;
DROP TRIGGER archive_manifest_rows_no_delete;

ALTER TABLE archive_manifest_observations RENAME TO archive_manifest_observations_legacy;

CREATE TABLE archive_manifest_observations (
  manifest_id TEXT NOT NULL REFERENCES archive_manifests(id),
  observation_id TEXT NOT NULL,
  PRIMARY KEY (manifest_id, observation_id)
) STRICT;

INSERT INTO archive_manifest_observations (manifest_id, observation_id)
SELECT manifest_id, observation_id FROM archive_manifest_observations_legacy;

DROP TABLE archive_manifest_observations_legacy;

CREATE TRIGGER archive_manifest_rows_no_update
BEFORE UPDATE ON archive_manifest_observations
BEGIN SELECT RAISE(ABORT, 'archive manifest membership is immutable'); END;

CREATE TRIGGER archive_manifest_rows_no_delete
BEFORE DELETE ON archive_manifest_observations
BEGIN SELECT RAISE(ABORT, 'archive manifest membership is immutable'); END;

DROP TRIGGER observations_no_delete;

ALTER TABLE maintenance_leases RENAME TO maintenance_leases_legacy;

CREATE TABLE maintenance_leases (
  kind TEXT PRIMARY KEY CHECK (kind IN ('canonical-cleanup', 'verified-archive')),
  run_id TEXT NOT NULL,
  expires_at TEXT NOT NULL
) STRICT;

INSERT INTO maintenance_leases (kind, run_id, expires_at)
SELECT kind, run_id, expires_at FROM maintenance_leases_legacy;

DROP TABLE maintenance_leases_legacy;

CREATE TRIGGER observations_no_delete
BEFORE DELETE ON observations
WHEN NOT EXISTS (
  SELECT 1 FROM maintenance_leases
   WHERE kind IN ('canonical-cleanup', 'verified-archive')
     AND expires_at > CURRENT_TIMESTAMP
)
BEGIN
  SELECT RAISE(ABORT, 'observations are append-only; verified archive or cleanup lease required');
END;

PRAGMA optimize;
