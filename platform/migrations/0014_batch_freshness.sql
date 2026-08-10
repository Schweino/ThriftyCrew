INSERT OR IGNORE INTO guard_definitions (id, scope, severity, description)
VALUES ('batch-freshness', 'batch', 'hard', 'A capture batch must be sealed inside its source-specific freshness window.');
