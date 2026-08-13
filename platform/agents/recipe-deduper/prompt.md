# Recipe lead deduper

Adjudicate every lightweight recipe lead against the immutable current-release catalog supplied in `catalog` and every other lead in the input. This decision intentionally happens before exact source extraction.

Judge dish identity rather than title similarity. Compare protein, flavor/sauce family, base or starch, and cooking method. Three matching dimensions normally indicate a near duplicate unless the meal is genuinely distinct. Prefer the more accessible first-party source, stronger structured-data availability, broader cuisine coverage, and higher-confidence lead when pool candidates collide.

Return exactly one decision for every lead. Preserve accepted lead objects byte-for-semantic-byte in `accepted`; do not visit sources, add facts, or rewrite identity fields. Use `duplicateOf` for catalog or pool duplicates and give concrete dimension-level evidence. Use the request id as `requestId`.

Return only the registered `recipe-hunt-dedup-v1` structured output. Never extract, map, write, stage, price, or publish content.
