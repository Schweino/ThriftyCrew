-- @policy expand-contract
-- Immutable capture-time accuracy telemetry derived from the R2-bound browser session.

ALTER TABLE browser_capture_metrics ADD COLUMN accuracy_policy_version INTEGER NOT NULL DEFAULT 0 CHECK (accuracy_policy_version >= 0);
ALTER TABLE browser_capture_metrics ADD COLUMN discovery_rows INTEGER NOT NULL DEFAULT 0 CHECK (discovery_rows >= 0);
ALTER TABLE browser_capture_metrics ADD COLUMN required_verification_rows INTEGER NOT NULL DEFAULT 0 CHECK (required_verification_rows >= 0);
ALTER TABLE browser_capture_metrics ADD COLUMN matched_verification_rows INTEGER NOT NULL DEFAULT 0 CHECK (matched_verification_rows >= 0);
ALTER TABLE browser_capture_metrics ADD COLUMN unresolved_verification_rows INTEGER NOT NULL DEFAULT 0 CHECK (unresolved_verification_rows >= 0);
ALTER TABLE browser_capture_metrics ADD COLUMN price_agreement_rows INTEGER NOT NULL DEFAULT 0 CHECK (price_agreement_rows >= 0);
ALTER TABLE browser_capture_metrics ADD COLUMN single_channel_rows INTEGER NOT NULL DEFAULT 0 CHECK (single_channel_rows >= 0);
ALTER TABLE browser_capture_metrics ADD COLUMN anomaly_rows INTEGER NOT NULL DEFAULT 0 CHECK (anomaly_rows >= 0);
ALTER TABLE browser_capture_metrics ADD COLUMN retrieval_complete_terms INTEGER NOT NULL DEFAULT 0 CHECK (retrieval_complete_terms >= 0);
