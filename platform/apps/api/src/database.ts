import type { ObservationInput, RecipeCost, ReleaseCell, ReleaseCreate, ReleaseGuardResult } from "@thriftycrew/contracts";
import { assertObservationArithmetic, deterministicId, digestHex, normalizeName, productIdentityPass, stableJson } from "@thriftycrew/domain";

export interface BatchRow {
  id: string;
  source_id: string;
  store_location_id: string;
  capture_method: string;
  coverage_mode: string;
  status: string;
  captured_from: string;
  captured_to: string;
  expected_terms: number | null;
  expected_pages: number | null;
  market_verified: number;
  location_verified: number;
  price_mode_verified: number;
  agent_id: string;
  max_age_days: number;
  source_contract_fingerprint: string | null;
  source_shape_fingerprint: string | null;
  source_schema_json: string;
}

export async function findBatch(db: D1Database, batchId: string): Promise<BatchRow | null> {
  return db.prepare(
    `SELECT b.*, s.store_location_id, s.capture_method,
            CAST(COALESCE(json_extract(s.coverage_policy_json, '$.max_age_days'), 14) AS INTEGER) AS max_age_days
       FROM capture_batches b
       JOIN capture_sources s ON s.id = b.source_id
      WHERE b.id = ?1`,
  ).bind(batchId).first<BatchRow>();
}

export async function insertObservations(
  db: D1Database,
  batch: BatchRow,
  observations: readonly ObservationInput[],
): Promise<{ accepted: number; ids: string[] }> {
  if (batch.status !== "open") throw new Error(`batch ${batch.id} is not open`);
  const statements: D1PreparedStatement[] = [];
  const ids: string[] = [];

  for (const observation of observations) {
    // Legacy comparison files round normalized unit prices to four decimal
    // places. Native capture contracts remain exact; the migration bridge gets
    // a bounded 50-micro tolerance (five hundred-thousandths of a dollar).
    assertObservationArithmetic(observation, batch.capture_method === "legacy_bridge" ? 50 : 2);
    if (observation.identity && !await productIdentityPass(observation.externalProductKey, observation.name, observation.sizeText, observation.identity)) {
      throw new Error(`observation ${observation.externalProductKey} has a forged or internally inconsistent product identity`);
    }
    if (observation.capturedAt < batch.captured_from || observation.capturedAt > batch.captured_to) {
      throw new Error(`observation ${observation.externalProductKey} falls outside the batch capture interval`);
    }
    const productId = await deterministicId("prod", batch.store_location_id, observation.externalProductKey);
    const versionHash = await digestHex(stableJson({
      name: observation.name,
      sizeText: observation.sizeText,
      productUrl: observation.productUrl ?? null,
      imageUrl: observation.imageUrl ?? null,
      taxonomyPath: observation.taxonomyPath ?? null,
      package: observation.package,
      identity: observation.identity ?? null,
    }));
    const versionId = await deterministicId("pver", productId, versionHash);
    const observationId = await deterministicId("obs", batch.id, versionId, observation.kind, observation.capturedAt);
    ids.push(observationId);

    statements.push(db.prepare(
      `INSERT INTO products (id, store_location_id, external_key, first_seen_at, last_seen_at)
       VALUES (?1, ?2, ?3, ?4, ?4)
       ON CONFLICT(store_location_id, external_key) DO UPDATE SET last_seen_at = excluded.last_seen_at`,
    ).bind(productId, batch.store_location_id, observation.externalProductKey, observation.capturedAt));

    statements.push(db.prepare(
       `INSERT INTO product_versions
         (id, product_id, name, normalized_name, size_text, product_url, image_url, taxonomy_path, package_json,
          identity_fingerprint, identity_json, content_hash, first_seen_at, last_seen_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?13)
       ON CONFLICT(product_id, content_hash) DO UPDATE SET last_seen_at = excluded.last_seen_at`,
    ).bind(
      versionId,
      productId,
      observation.name,
      normalizeName(observation.name),
      observation.sizeText,
      observation.productUrl ?? null,
      observation.imageUrl ?? null,
      observation.taxonomyPath ?? null,
      stableJson(observation.package),
      observation.identity?.fingerprint ?? null,
      stableJson(observation.identity ?? {}),
      versionHash,
      observation.capturedAt,
    ));

    statements.push(db.prepare(
      `INSERT OR IGNORE INTO observations
         (id, batch_id, product_version_id, term_key, kind, currency, purchase_price_minor, regular_price_minor,
          purchase_quantity, package_count, captured_basis_unit, captured_basis_qty_micros, normalized_basis_unit,
          normalized_basis_qty_micros, per_unit_micros, basis_options_json, loyalty_required, membership_required, raw_price_text,
          raw_size_text, captured_at, valid_from, valid_to, evidence_object_id, source_payload_key, price_semantics_json)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26)`,
    ).bind(
      observationId,
      batch.id,
      versionId,
      observation.termKey ?? null,
      observation.kind,
      observation.currency,
      observation.purchasePriceMinor,
      observation.regularPriceMinor ?? null,
      observation.purchaseQuantity,
      observation.packageCount,
      observation.capturedBasisUnit,
      observation.capturedBasisQtyMicros,
      observation.normalizedBasisUnit,
      observation.normalizedBasisQtyMicros,
      observation.perUnitMicros,
      stableJson(observation.basisOptions ?? []),
      observation.loyaltyRequired ? 1 : 0,
      observation.membershipRequired ? 1 : 0,
      observation.rawPriceText,
      observation.rawSizeText,
      observation.capturedAt,
      observation.validFrom ?? null,
      observation.validTo ?? null,
      observation.evidenceObjectId ?? null,
      observation.sourcePayloadKey ?? null,
      stableJson(observation.priceSemantics ?? {}),
    ));
  }

  // D1 batch calls have practical statement and payload ceilings. Keep the
  // application contract independent of those ceilings by flushing bounded
  // groups; an observation expands to three statements.
  for (let offset = 0; offset < statements.length; offset += 90) {
    await db.batch(statements.slice(offset, offset + 90));
  }
  return { accepted: observations.length, ids };
}

export async function createRelease(db: D1Database, release: ReleaseCreate): Promise<void> {
  const statements: D1PreparedStatement[] = [db.prepare(
    `INSERT INTO releases
       (id, market_id, configuration_id, engine_run_id, input_manifest_json, input_hash, summary_json)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
  ).bind(
    release.id,
    release.marketId,
    release.configurationId,
    release.engineRunId ?? null,
    stableJson(release.inputManifest),
    release.inputHash,
    stableJson(release.summary),
  )];
  release.inputBatchIds.forEach((batchId, ordinal) => {
    statements.push(db.prepare(
      "INSERT INTO release_input_batches (release_id, batch_id, ordinal) VALUES (?1, ?2, ?3)",
    ).bind(release.id, batchId, ordinal));
  });
  await db.batch(statements);
}

export async function insertReleaseCells(db: D1Database, releaseId: string, cells: readonly ReleaseCell[]): Promise<void> {
  const statements = cells.map((cell) => db.prepare(
    `INSERT INTO release_cells
       (release_id, commodity_id, store_location_id, observation_id, status, is_crown, display_per_unit_micros, display_unit, reason_json)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
     ON CONFLICT(release_id, commodity_id, store_location_id) DO UPDATE SET
       observation_id = excluded.observation_id,
       status = excluded.status,
       is_crown = excluded.is_crown,
       display_per_unit_micros = excluded.display_per_unit_micros,
       display_unit = excluded.display_unit,
       reason_json = excluded.reason_json`,
  ).bind(
    releaseId,
    cell.commodityId,
    cell.storeLocationId,
    cell.observationId ?? null,
    cell.status,
    cell.isCrown ? 1 : 0,
    cell.displayPerUnitMicros ?? null,
    cell.displayUnit ?? null,
    stableJson(cell.reason),
  ));
  for (let offset = 0; offset < statements.length; offset += 90) {
    await db.batch(statements.slice(offset, offset + 90));
  }
}

export async function insertRecipeCosts(db: D1Database, releaseId: string, costs: readonly RecipeCost[]): Promise<void> {
  const statements = costs.map((cost) => db.prepare(
    `INSERT INTO release_recipe_costs
       (release_id, recipe_slug, status, batch_cost_minor, serving_cost_minor, servings, missing_ingredients_json, detail_json)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
     ON CONFLICT(release_id, recipe_slug) DO UPDATE SET
       status = excluded.status,
       batch_cost_minor = excluded.batch_cost_minor,
       serving_cost_minor = excluded.serving_cost_minor,
       servings = excluded.servings,
       missing_ingredients_json = excluded.missing_ingredients_json,
       detail_json = excluded.detail_json`,
  ).bind(
    releaseId,
    cost.recipeSlug,
    cost.status,
    cost.batchCostMinor ?? null,
    cost.servingCostMinor ?? null,
    cost.servings,
    stableJson(cost.missingIngredients),
    stableJson(cost.detail),
  ));
  for (let offset = 0; offset < statements.length; offset += 90) {
    await db.batch(statements.slice(offset, offset + 90));
  }
}

export async function upsertGuardResult(db: D1Database, releaseId: string, result: ReleaseGuardResult): Promise<void> {
  const resultId = await deterministicId("guard", releaseId, result.guardId);
  const definition = await db.prepare("SELECT severity FROM guard_definitions WHERE id = ?1").bind(result.guardId).first<{ severity: "hard" | "warning" | "info" }>();
  const statements: D1PreparedStatement[] = [db.prepare(
    `INSERT INTO guard_results
       (id, guard_id, release_id, status, eligible_count, examined_count, finding_count, detail_json)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
     ON CONFLICT(id) DO UPDATE SET
       status = excluded.status,
       eligible_count = excluded.eligible_count,
       examined_count = excluded.examined_count,
       finding_count = excluded.finding_count,
       detail_json = excluded.detail_json`,
  ).bind(
    resultId,
    result.guardId,
    releaseId,
    result.status,
    result.eligibleCount,
    result.examinedCount,
    result.findings.length,
    stableJson(result.detail),
  )];
  statements.push(db.prepare("DELETE FROM guard_findings WHERE result_id = ?1").bind(resultId));
  for (const finding of result.findings) {
    const findingId = await deterministicId("finding", resultId, finding.key);
    statements.push(db.prepare(
      `INSERT INTO guard_findings (id, result_id, finding_key, message, evidence_json)
       VALUES (?1, ?2, ?3, ?4, ?5)`,
    ).bind(findingId, resultId, finding.key, finding.message, stableJson(finding.evidence)));
    const triageId = await deterministicId("triage", "guard_finding", findingId);
    statements.push(db.prepare(
      `INSERT INTO triage_items
         (id, source_kind, source_ref, severity, status, title, evidence_json)
       VALUES (?1, 'guard_finding', ?2, ?3, 'open', ?4, ?5)
       ON CONFLICT(source_ref) DO UPDATE SET
         title = excluded.title, evidence_json = excluded.evidence_json, updated_at = CURRENT_TIMESTAMP`,
    ).bind(triageId, findingId, definition?.severity ?? "hard", `${result.guardId}: ${finding.message}`, stableJson(finding.evidence)));
  }
  for (let offset = 0; offset < statements.length; offset += 90) {
    await db.batch(statements.slice(offset, offset + 90));
  }
}
