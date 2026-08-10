import type { ReleaseGuardResult } from "@thriftycrew/contracts";
import { upsertGuardResult } from "./database";

interface ReleaseContext {
  releaseId: string;
  configurationId: string;
  marketId: string;
  expectedCommodities: number;
  expectedStores: number;
  expectedRecipes: number;
}

interface CountRow { count: number }

export const releaseCaptureEvictionSql = `WITH complete_candidates AS (
    SELECT candidate_match.commodity_id, candidate_product.store_location_id,
           candidate.id AS observation_id
      FROM release_input_batches candidate_input
      JOIN capture_batches candidate_batch
        ON candidate_batch.id = candidate_input.batch_id
       AND candidate_batch.coverage_mode IN ('full','ad_only')
      JOIN observations candidate ON candidate.batch_id = candidate_batch.id
      JOIN product_versions candidate_version ON candidate_version.id = candidate.product_version_id
      JOIN products candidate_product ON candidate_product.id = candidate_version.product_id
      JOIN match_decisions candidate_match
        ON candidate_match.product_id = candidate_product.id
       AND candidate_match.configuration_id = ?2
       AND candidate_match.superseded_at IS NULL
     WHERE candidate_input.release_id = ?1
       AND (candidate.valid_to IS NULL OR candidate.valid_to >= CURRENT_TIMESTAMP)
  ), thin_selected AS (
    SELECT selected.commodity_id, selected.store_location_id, selected.observation_id
      FROM release_cells selected
      JOIN observations chosen ON chosen.id = selected.observation_id
      JOIN capture_batches selected_batch ON selected_batch.id = chosen.batch_id
     WHERE selected.release_id = ?1 AND selected.status = 'priced'
       AND selected_batch.coverage_mode IN ('partial','targeted')
  )
  SELECT selected.commodity_id, selected.store_location_id, selected.observation_id,
         candidate.observation_id AS protected_observation_id
    FROM thin_selected selected
    JOIN complete_candidates candidate
      ON candidate.commodity_id = selected.commodity_id
     AND candidate.store_location_id = selected.store_location_id
     AND candidate.observation_id <> selected.observation_id
   ORDER BY selected.commodity_id, selected.store_location_id LIMIT 500`;

export function storeCoverageFloor(priorPriced: number | undefined, firstNativeMinimum: number | undefined, firstNativeCutover: boolean): number {
  if (firstNativeCutover && firstNativeMinimum !== undefined) return firstNativeMinimum;
  return priorPriced === undefined ? 1 : Math.floor(priorPriced * 0.9);
}

function result(
  guardId: string,
  pass: boolean,
  eligibleCount: number,
  examinedCount: number,
  findings: ReleaseGuardResult["findings"] = [],
  detail: Record<string, unknown> = {},
): ReleaseGuardResult {
  return { guardId, status: pass ? "pass" : "fail", eligibleCount, examinedCount, findings, detail };
}

export async function evaluateReleaseGuards(db: D1Database, context: ReleaseContext): Promise<void> {
  const pricedForSnapshot = (await db.prepare(
    "SELECT COUNT(*) AS count FROM release_cells WHERE release_id = ?1 AND status = 'priced'",
  ).bind(context.releaseId).first<CountRow>())?.count ?? 0;
  const snapshotRows = await db.prepare(
    `SELECT c.commodity_id, c.store_location_id, o.batch_id, b.status
       FROM release_cells c
       JOIN observations o ON o.id = c.observation_id
       JOIN capture_batches b ON b.id = o.batch_id
       LEFT JOIN release_input_batches i ON i.release_id = c.release_id AND i.batch_id = o.batch_id
      WHERE c.release_id = ?1 AND c.status = 'priced'
        AND (i.batch_id IS NULL OR b.status <> 'promoted')
      ORDER BY c.commodity_id, c.store_location_id LIMIT 500`,
  ).bind(context.releaseId).all<{ commodity_id: string; store_location_id: string; batch_id: string; status: string }>();
  const snapshotCount = (await db.prepare(
    "SELECT COUNT(*) AS count FROM release_input_batches WHERE release_id = ?1",
  ).bind(context.releaseId).first<CountRow>())?.count ?? 0;
  await upsertGuardResult(db, context.releaseId, result(
    "release-input-snapshot",
    snapshotCount > 0 && snapshotRows.results.length === 0,
    pricedForSnapshot,
    pricedForSnapshot,
    snapshotRows.results.map((row) => ({
      key: `${row.commodity_id}:${row.store_location_id}`,
      message: "Selected observation is outside the immutable promoted-batch snapshot",
      evidence: { batchId: row.batch_id, batchStatus: row.status },
    })),
    { snapshotBatchCount: snapshotCount },
  ));

  const aisleRows = await db.prepare(
    `SELECT c.commodity_id, c.store_location_id, p.id AS product_id, pv.taxonomy_path
       FROM release_cells c
       JOIN observations o ON o.id = c.observation_id
       JOIN product_versions pv ON pv.id = o.product_version_id
       JOIN products p ON p.id = pv.product_id
       JOIN match_decisions m ON m.product_id = p.id AND m.superseded_at IS NULL AND m.decided_by = 'aisle'
      WHERE c.release_id = ?1`,
  ).bind(context.releaseId).all<{ commodity_id: string; store_location_id: string; product_id: string; taxonomy_path: string | null }>();
  const aisleMissing = aisleRows.results.filter((row) => !row.taxonomy_path);
  await upsertGuardResult(db, context.releaseId, result(
    "release-aisle-taxonomy",
    aisleMissing.length === 0,
    aisleRows.results.length,
    aisleRows.results.length,
    aisleMissing.map((row) => ({
      key: row.product_id,
      message: "Aisle-authoritative match has no captured taxonomy path",
      evidence: { commodityId: row.commodity_id, storeLocationId: row.store_location_id },
    })),
  ));

  const categoryRows = await db.prepare(
    `SELECT c.id, c.label
       FROM commodities c
       LEFT JOIN configuration_categories cc
         ON cc.configuration_id = c.configuration_id AND cc.category_id = c.category_id
      WHERE c.configuration_id = ?1 AND c.active = 1
        AND (c.category_id IS NULL OR cc.category_id IS NULL)
      ORDER BY c.id`,
  ).bind(context.configurationId).all<{ id: string; label: string }>();
  const commodityCount = await db.prepare(
    "SELECT COUNT(*) AS count FROM commodities WHERE configuration_id = ?1 AND active = 1",
  ).bind(context.configurationId).first<CountRow>();
  const categoryEligible = commodityCount?.count ?? 0;
  const categoryPass = categoryEligible === context.expectedCommodities && categoryRows.results.length === 0;
  await upsertGuardResult(db, context.releaseId, result(
    "release-category-coverage",
    categoryPass,
    context.expectedCommodities,
    categoryEligible,
    categoryRows.results.map((row) => ({ key: row.id, message: `${row.label} has no category in this configuration`, evidence: { commodityId: row.id } })),
    { authoredCommodities: categoryEligible },
  ));

  const storeRows = await db.prepare(
    `SELECT l.id, l.display_name,
            SUM(CASE WHEN c.status = 'priced' THEN 1 ELSE 0 END) AS priced,
            COUNT(c.commodity_id) AS cells
       FROM store_locations l
       LEFT JOIN release_cells c ON c.store_location_id = l.id AND c.release_id = ?1
      WHERE l.market_id = ?2 AND l.active = 1
      GROUP BY l.id, l.display_name ORDER BY l.id`,
  ).bind(context.releaseId, context.marketId).all<{ id: string; display_name: string; priced: number; cells: number }>();
  const previous = await db.prepare(
    "SELECT release_id FROM current_releases WHERE market_id = ?1",
  ).bind(context.marketId).first<{ release_id: string }>();
  const previousCoverage = new Map<string, number>();
  if (previous && previous.release_id !== context.releaseId) {
    const priorRows = await db.prepare(
      `SELECT store_location_id, SUM(CASE WHEN status = 'priced' THEN 1 ELSE 0 END) AS priced
         FROM release_cells WHERE release_id = ?1 GROUP BY store_location_id`,
    ).bind(previous.release_id).all<{ store_location_id: string; priced: number }>();
    for (const row of priorRows.results) previousCoverage.set(row.store_location_id, row.priced);
  }
  const releaseKinds = previous && previous.release_id !== context.releaseId
    ? await db.prepare(
      `SELECT id, json_extract(input_manifest_json, '$.kind') AS kind
         FROM releases WHERE id IN (?1, ?2)`,
    ).bind(context.releaseId, previous.release_id).all<{ id: string; kind: string | null }>()
    : { results: [], success: true, meta: {} } as unknown as D1Result<{ id: string; kind: string | null }>;
  const kindByRelease = new Map(releaseKinds.results.map((row) => [row.id, row.kind]));
  const firstNativeCutover = kindByRelease.get(context.releaseId) === "native-v3-release"
    && kindByRelease.get(previous?.release_id ?? "") !== "native-v3-release";
  const cutoverRows = firstNativeCutover
    ? await db.prepare(
      `SELECT s.store_location_id,
              MAX(CAST(json_extract(s.coverage_policy_json, '$.first_native_min_priced') AS INTEGER)) AS minimum
         FROM release_input_batches i
         JOIN capture_batches b ON b.id = i.batch_id
         JOIN capture_sources s ON s.id = b.source_id
        WHERE i.release_id = ?1
          AND json_extract(s.coverage_policy_json, '$.first_native_min_priced') IS NOT NULL
        GROUP BY s.store_location_id`,
    ).bind(context.releaseId).all<{ store_location_id: string; minimum: number }>()
    : { results: [], success: true, meta: {} } as unknown as D1Result<{ store_location_id: string; minimum: number }>;
  const cutoverMinimum = new Map(cutoverRows.results.map((row) => [row.store_location_id, row.minimum]));
  const storeFindings: ReleaseGuardResult["findings"] = [];
  for (const row of storeRows.results) {
    const prior = previousCoverage.get(row.id);
    const authoredCutoverMinimum = cutoverMinimum.get(row.id);
    const floor = storeCoverageFloor(prior, authoredCutoverMinimum, firstNativeCutover);
    if (row.cells !== context.expectedCommodities || row.priced < floor) {
      storeFindings.push({
        key: row.id,
        message: `${row.display_name} coverage is below its accepted release floor`,
        evidence: { cells: row.cells, priced: row.priced, floor, expectedCells: context.expectedCommodities, baseline: authoredCutoverMinimum !== undefined && firstNativeCutover ? "first-native-authored" : "previous-release-90pct" },
      });
    }
  }
  await upsertGuardResult(db, context.releaseId, result(
    "release-store-coverage",
    storeRows.results.length === context.expectedStores && storeFindings.length === 0,
    context.expectedStores,
    storeRows.results.length,
    storeFindings,
    { previousReleaseId: previous?.release_id ?? null, firstNativeCutover, authoredCutoverStores: cutoverRows.results.length },
  ));

  const priorPriced = previous && previous.release_id !== context.releaseId
    ? (await db.prepare("SELECT COUNT(*) AS count FROM release_cells WHERE release_id = ?1 AND status = 'priced'").bind(previous.release_id).first<CountRow>())?.count ?? 0
    : 0;
  const dropRows = previous && previous.release_id !== context.releaseId
    ? await db.prepare(
      `SELECT old.commodity_id, old.store_location_id, newer.status, newer.reason_json
         FROM release_cells old
         LEFT JOIN release_cells newer
           ON newer.release_id = ?1 AND newer.commodity_id = old.commodity_id AND newer.store_location_id = old.store_location_id
        WHERE old.release_id = ?2 AND old.status = 'priced'
          AND (newer.status IS NULL OR newer.status <> 'priced')
          AND (newer.reason_json IS NULL OR json_extract(newer.reason_json, '$.code') IS NULL)
        ORDER BY old.commodity_id, old.store_location_id LIMIT 500`,
    ).bind(context.releaseId, previous.release_id).all<{ commodity_id: string; store_location_id: string; status: string | null; reason_json: string | null }>()
    : { results: [], success: true, meta: {} } as unknown as D1Result<{ commodity_id: string; store_location_id: string; status: string | null; reason_json: string | null }>;
  await upsertGuardResult(db, context.releaseId, result(
    "release-cell-drops",
    dropRows.results.length === 0,
    priorPriced,
    priorPriced,
    dropRows.results.map((row) => ({
      key: `${row.commodity_id}:${row.store_location_id}`,
      message: "A previously priced cell disappeared without an explicit reason code",
      evidence: { commodityId: row.commodity_id, storeLocationId: row.store_location_id, status: row.status },
    })),
    { previousReleaseId: previous?.release_id ?? null },
  ));

  const pricedCount = (await db.prepare("SELECT COUNT(*) AS count FROM release_cells WHERE release_id = ?1 AND status = 'priced'").bind(context.releaseId).first<CountRow>())?.count ?? 0;
  const wrongRows = await db.prepare(
    `SELECT c.commodity_id, c.store_location_id, o.id AS observation_id, p.external_key, pv.normalized_name, k.id AS rule_id
       FROM release_cells c
       JOIN observations o ON o.id = c.observation_id
       JOIN product_versions pv ON pv.id = o.product_version_id
       JOIN products p ON p.id = pv.product_id
       JOIN known_wrong_rules k
         ON k.configuration_id = ?2 AND k.commodity_id = c.commodity_id
        AND (k.store_location_id IS NULL OR k.store_location_id = c.store_location_id)
        AND (k.external_product_key = p.external_key OR k.normalized_name = pv.normalized_name)
      WHERE c.release_id = ?1 AND c.status = 'priced'
      ORDER BY c.commodity_id, c.store_location_id LIMIT 500`,
  ).bind(context.releaseId, context.configurationId).all<{ commodity_id: string; store_location_id: string; observation_id: string; rule_id: string }>();
  await upsertGuardResult(db, context.releaseId, result(
    "release-known-wrong",
    wrongRows.results.length === 0,
    pricedCount,
    pricedCount,
    wrongRows.results.map((row) => ({
      key: `${row.commodity_id}:${row.store_location_id}`,
      message: "Selected observation is covered by a known-wrong ruling",
      evidence: { observationId: row.observation_id, ruleId: row.rule_id },
    })),
  ));

  const basisRows = await db.prepare(
    `SELECT c.commodity_id, c.store_location_id, o.id AS observation_id,
            o.per_unit_micros,
            ROUND((o.purchase_price_minor * 10000.0 * 1000000) / o.normalized_basis_qty_micros) AS expected_micros,
            s.capture_method
       FROM release_cells c
       JOIN observations o ON o.id = c.observation_id
       JOIN capture_batches b ON b.id = o.batch_id
       JOIN capture_sources s ON s.id = b.source_id
      WHERE c.release_id = ?1 AND c.status = 'priced'
        AND ABS(o.per_unit_micros - ROUND((o.purchase_price_minor * 10000.0 * 1000000) / o.normalized_basis_qty_micros))
            > CASE WHEN s.capture_method = 'legacy_bridge' THEN 50 ELSE 2 END
      ORDER BY c.commodity_id, c.store_location_id LIMIT 500`,
  ).bind(context.releaseId).all<{ commodity_id: string; store_location_id: string; observation_id: string; per_unit_micros: number; expected_micros: number; capture_method: string }>();
  await upsertGuardResult(db, context.releaseId, result(
    "release-basis",
    basisRows.results.length === 0,
    pricedCount,
    pricedCount,
    basisRows.results.map((row) => ({
      key: `${row.commodity_id}:${row.store_location_id}`,
      message: "Displayed price does not agree with captured price and normalized package basis",
      evidence: { observationId: row.observation_id, displayedMicros: row.per_unit_micros, expectedMicros: row.expected_micros, captureMethod: row.capture_method },
    })),
  ));

  const staleRows = await db.prepare(
    `SELECT c.commodity_id, c.store_location_id, o.id AS observation_id, o.captured_at,
            CAST(COALESCE(json_extract(s.coverage_policy_json, '$.max_age_days'), 14) AS INTEGER) AS max_age_days,
            CAST(julianday(CURRENT_TIMESTAMP) - julianday(o.captured_at) AS INTEGER) AS age_days
       FROM release_cells c
       JOIN releases r ON r.id = c.release_id
       JOIN observations o ON o.id = c.observation_id
       JOIN capture_batches b ON b.id = o.batch_id
       JOIN capture_sources s ON s.id = b.source_id
      WHERE c.release_id = ?1 AND c.status = 'priced'
        AND julianday(CURRENT_TIMESTAMP) - julianday(o.captured_at)
            > CAST(COALESCE(json_extract(s.coverage_policy_json, '$.max_age_days'), 14) AS INTEGER)
      ORDER BY c.commodity_id, c.store_location_id LIMIT 500`,
  ).bind(context.releaseId).all<{ commodity_id: string; store_location_id: string; observation_id: string; captured_at: string; max_age_days: number; age_days: number }>();
  await upsertGuardResult(db, context.releaseId, result(
    "release-freshness",
    staleRows.results.length === 0,
    pricedCount,
    pricedCount,
    staleRows.results.map((row) => ({
      key: `${row.commodity_id}:${row.store_location_id}`,
      message: "Selected observation is older than its source freshness window",
      evidence: { observationId: row.observation_id, capturedAt: row.captured_at, ageDays: row.age_days, maxAgeDays: row.max_age_days },
    })),
  ));

  // Protection is evaluated against the immutable release snapshot. Looking
  // through all validated/promoted history made the result depend on captures
  // arriving after the snapshot and created a combinatorial history join once
  // direct catalogs grew. Snapshot batches are the correct bounded input.
  const evictionRows = await db.prepare(releaseCaptureEvictionSql)
    .bind(context.releaseId, context.configurationId)
    .all<{ commodity_id: string; store_location_id: string; observation_id: string; protected_observation_id: string }>();
  await upsertGuardResult(db, context.releaseId, result(
    "release-capture-eviction",
    evictionRows.results.length === 0,
    pricedCount,
    pricedCount,
    evictionRows.results.map((row) => ({
      key: `${row.commodity_id}:${row.store_location_id}`,
      message: "A thin partial capture evicted an eligible complete-capture observation",
      evidence: { selectedObservationId: row.observation_id, protectedObservationId: row.protected_observation_id },
    })),
  ));
}

export async function evaluateNotBlindGuard(db: D1Database, releaseId: string): Promise<void> {
  const active = await db.prepare(
    `SELECT d.id, r.id AS result_id, r.eligible_count, r.examined_count
       FROM guard_definitions d
       LEFT JOIN guard_results r ON r.guard_id = d.id AND r.release_id = ?1
      WHERE d.active = 1 AND d.scope = 'release' AND d.severity = 'hard' AND d.id <> 'guard-not-blind'
      ORDER BY d.id`,
  ).bind(releaseId).all<{ id: string; result_id: string | null; eligible_count: number | null; examined_count: number | null }>();
  const blind = active.results.filter((row) => row.result_id === null || ((row.eligible_count ?? 0) > 0 && (row.examined_count ?? 0) === 0));
  await upsertGuardResult(db, releaseId, result(
    "guard-not-blind",
    blind.length === 0,
    active.results.length,
    active.results.length,
    blind.map((row) => ({ key: row.id, message: "Hard guard is missing or examined none of its eligible rows", evidence: {} })),
  ));
}
