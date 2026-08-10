-- @policy expand-contract
INSERT OR IGNORE INTO guard_definitions (id, scope, severity, description)
VALUES (
  'batch-browser-evidence',
  'batch',
  'hard',
  'Browser capture batches must bind a valid session manifest, raw payload, and screenshot canary to the declared source identity.'
);
