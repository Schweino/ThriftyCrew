import {
  OMAHA_GROCERY_STORE_LOCATION_IDS,
  ingredientPricingWaveCreateSchema,
  ingredientStorePriceSchema,
  ingredientStoreCheckClaimSchema,
  ingredientStoreCheckCompleteSchema,
  ingredientStoreCheckFailSchema,
  ingredientStoreCheckHeartbeatSchema,
} from "@thriftycrew/contracts";
import { deterministicId, digestHex, normalizeName, stableJson } from "@thriftycrew/domain";
import type { z } from "zod";
import type { WorkerEnv } from "./env";
import { catalogCandidatesForTerms, chooseCatalogWinner, readStoreCatalog } from "./hot-catalog";
import { aggregateIngredientStoreChecks, type IngredientAggregate } from "./ingredient-state-machine";

type WaveCreate = z.infer<typeof ingredientPricingWaveCreateSchema>;
type StoreClaim = z.infer<typeof ingredientStoreCheckClaimSchema>;
type StoreHeartbeat = z.infer<typeof ingredientStoreCheckHeartbeatSchema>;
type StoreComplete = z.infer<typeof ingredientStoreCheckCompleteSchema>;
type StoreFail = z.infer<typeof ingredientStoreCheckFailSchema>;

export function aggregateStoreCheckStates(states: Array<{ state: string }>): IngredientAggregate {
  return aggregateIngredientStoreChecks(states);
}

async function appendOutbox(db: D1Database, topic: string, aggregateKind: string, aggregateId: string, dedupeKey: string, payload: unknown): Promise<D1PreparedStatement> {
  const payloadJson = stableJson(payload);
  return db.prepare(
    `INSERT INTO pipeline_outbox
       (topic, aggregate_kind, aggregate_id, dedupe_key, payload_json, payload_hash)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT(dedupe_key) DO NOTHING`,
  ).bind(topic, aggregateKind, aggregateId, dedupeKey, payloadJson, await digestHex(payloadJson));
}

export async function createPricingWave(db: D1Database, inputValue: unknown): Promise<{ waveId: string; jobs: number; storeChecks: number }> {
  const input: WaveCreate = ingredientPricingWaveCreateSchema.parse(inputValue);
  const uniqueGapIds = [...new Set(input.gapIds)].sort();
  const rows = await db.prepare(
    `SELECT gap.id, gap.display_name, gap.normalized_name, entity.id AS entity_id
       FROM ingredient_gaps gap
       LEFT JOIN ingredient_entities entity ON entity.id = 'entity_' || gap.id
      WHERE gap.id IN (${uniqueGapIds.map(() => "?").join(",")})
        AND gap.status NOT IN ('published','permanently_unavailable')
        AND gap.qa_resolution IS NULL
      ORDER BY gap.id`,
  ).bind(...uniqueGapIds).all<{ id: string; display_name: string; normalized_name: string; entity_id: string | null }>();
  if (rows.results.length !== uniqueGapIds.length) throw new Error("pricing wave contains an unknown or terminal ingredient gap");
  const statements: D1PreparedStatement[] = [db.prepare(
    `INSERT INTO pricing_waves
       (id, market_id, campaign_id, source_kind, target_available, state, input_hash, deadline_at)
     VALUES (?1, 'omaha', ?2, ?3, ?4, 'resolving', ?5, ?6)
     ON CONFLICT(id) DO NOTHING`,
  ).bind(input.id, input.campaignId, input.sourceKind, input.targetAvailable, input.inputHash, input.deadlineAt)];
  for (const row of rows.results) {
    const jobId = await deterministicId("pricing-job", "omaha", row.id);
    const planId = await deterministicId("ingredient-query-plan", jobId, row.normalized_name);
    const planHash = await digestHex(stableJson({ canonicalTerm: row.normalized_name, aliases: [], exclusions: [], version: 1 }));
    statements.push(db.prepare(
      `INSERT INTO ingredient_pricing_jobs
         (id, wave_id, gap_id, entity_id, market_id, state, operational_state, semantic_plan_hash, last_progress_at)
       VALUES (?1, ?2, ?3, ?4, 'omaha', 'store_checks_running', 'identity_ready', ?5, CURRENT_TIMESTAMP)
       ON CONFLICT(gap_id, market_id) DO UPDATE SET
         wave_id = COALESCE(ingredient_pricing_jobs.wave_id, excluded.wave_id), updated_at = CURRENT_TIMESTAMP`,
    ).bind(jobId, input.id, row.id, row.entity_id, planHash));
    statements.push(db.prepare(
      `INSERT INTO pricing_wave_members (wave_id, pricing_job_id, gap_id)
       VALUES (?1, ?2, ?3) ON CONFLICT(wave_id, gap_id) DO NOTHING`,
    ).bind(input.id, jobId, row.id));
    statements.push(db.prepare(
      `INSERT INTO ingredient_query_plans
         (id, pricing_job_id, version, canonical_term, aliases_json, exclusions_json, plan_hash, planner_version)
       VALUES (?1, ?2, 1, ?3, '[]', '[]', ?4, 'deterministic-v1')
       ON CONFLICT(pricing_job_id, plan_hash) DO NOTHING`,
    ).bind(planId, jobId, row.normalized_name, planHash));
    for (const storeLocationId of OMAHA_GROCERY_STORE_LOCATION_IDS) {
      const checkId = await deterministicId("ingredient-store-check", jobId, storeLocationId);
      statements.push(db.prepare(
        `INSERT INTO ingredient_store_checks
           (id, pricing_job_id, gap_id, store_location_id, state, operational_state, query_plan_id, query_plan_hash, last_progress_at)
         VALUES (?1, ?2, ?3, ?4, 'queued', 'queued', ?5, ?6, CURRENT_TIMESTAMP)
         ON CONFLICT(pricing_job_id, store_location_id) DO NOTHING`,
      ).bind(checkId, jobId, row.id, storeLocationId, planId, planHash));
    }
    if (!row.entity_id) throw new Error(`ingredient gap ${row.id} has no canonical entity`);
    statements.push(db.prepare(
      `INSERT INTO ingredient_pricing_inbox
         (id, market_id, entity_id, gap_id, pricing_job_id, campaign_id, state)
       VALUES (?1, 'omaha', ?2, ?3, ?4, ?5, 'queued')
       ON CONFLICT(market_id, entity_id) DO NOTHING`,
    ).bind(`inbox_${jobId}`, row.entity_id, row.id, jobId, input.campaignId));
    statements.push(await appendOutbox(db, "ingredient.pricing.queued", "ingredient_pricing_job", jobId,
      `ingredient.pricing.queued:${jobId}:${planHash}`, { waveId: input.id, jobId, gapId: row.id, entityId: row.entity_id, planId, planHash }));
  }
  for (let offset = 0; offset < statements.length; offset += 90) await db.batch(statements.slice(offset, offset + 90));
  return { waveId: input.id, jobs: rows.results.length, storeChecks: rows.results.length * OMAHA_GROCERY_STORE_LOCATION_IDS.length };
}

export async function claimStoreChecks(db: D1Database, inputValue: unknown): Promise<Record<string, unknown>[]> {
  const input: StoreClaim = ingredientStoreCheckClaimSchema.parse(inputValue);
  const now = new Date();
  const expiresAt = new Date(now.getTime() + input.leaseSeconds * 1000).toISOString();
  await db.prepare(
    `UPDATE ingredient_store_checks
        SET state = CASE WHEN lease_lane = 'catalog' THEN 'catalog_lookup' ELSE 'transient_failed' END,
            operational_state = CASE WHEN lease_lane = 'catalog' THEN 'catalog_lookup' ELSE 'transient_backoff' END,
            resume_state = CASE WHEN lease_lane = 'catalog' THEN NULL WHEN lease_lane = 'qa' THEN 'qa_queued' ELSE 'capture_queued' END,
            lease_owner = NULL, lease_expires_at = NULL, heartbeat_at = NULL, lease_lane = NULL,
            error_class = CASE WHEN lease_lane = 'catalog' THEN NULL ELSE 'transient' END,
            last_error = 'lease expired', next_attempt_at = ?2,
            last_progress_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
      WHERE store_location_id = ?1 AND state = 'leased' AND lease_expires_at <= ?2`,
  ).bind(input.storeLocationId, now.toISOString()).run();
  const claimStates = input.lane === "qa" ? ["qa_pending", "transient_failed"]
    : input.lane === "targeted_refresh" ? ["targeted_refresh", "transient_failed", "evidence_expired"]
      : ["queued", "catalog_lookup"];
  const resumePredicate = input.lane === "qa"
    ? "AND (check_row.state <> 'transient_failed' OR check_row.resume_state = 'qa_queued')"
    : input.lane === "targeted_refresh"
      ? "AND (check_row.state <> 'transient_failed' OR check_row.resume_state IS NULL OR check_row.resume_state = 'capture_queued')"
      : "";
  const candidates = await db.prepare(
    `SELECT check_row.id
       FROM ingredient_store_checks check_row
       JOIN ingredient_pricing_jobs job ON job.id = check_row.pricing_job_id
       JOIN ingredient_gaps gap ON gap.id = check_row.gap_id
      WHERE check_row.store_location_id = ?
        AND check_row.state IN (${claimStates.map(() => "?").join(",")})
        AND check_row.next_attempt_at <= ?
        ${resumePredicate}
        AND job.state = 'store_checks_running'
        AND job.commodity_proposal_json IS NOT NULL
        AND gap.qa_resolution IS NULL
      ORDER BY check_row.next_attempt_at, check_row.created_at, check_row.id LIMIT ?`,
  ).bind(input.storeLocationId, ...claimStates, now.toISOString(), input.limit).all<{ id: string }>();
  const claimed: Record<string, unknown>[] = [];
  for (const candidate of candidates.results) {
    const updated = await db.prepare(
      `UPDATE ingredient_store_checks
          SET state = 'leased', operational_state = ?, lease_lane = ?, lease_owner = ?,
              lease_generation = lease_generation + 1, lease_expires_at = ?, heartbeat_at = ?,
              attempt_count = attempt_count + 1, last_error = NULL, resume_state = NULL,
              last_progress_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
        WHERE id = ?
          AND state IN (${claimStates.map(() => "?").join(",")})`,
    ).bind(input.lane === "qa" ? "qa_leased" : input.lane === "targeted_refresh" ? "capture_leased" : "catalog_lookup",
      input.lane, input.owner, expiresAt, now.toISOString(), candidate.id, ...claimStates).run();
    if ((updated.meta.changes ?? 0) !== 1) continue;
    const row = await db.prepare(
      `SELECT check_row.*, gap.display_name, gap.normalized_name,
              plan.canonical_term, plan.aliases_json, plan.exclusions_json, plan.plan_hash,
              job.commodity_proposal_json, job.commodity_proposal_hash
         FROM ingredient_store_checks check_row
         JOIN ingredient_gaps gap ON gap.id = check_row.gap_id
         JOIN ingredient_pricing_jobs job ON job.id = check_row.pricing_job_id
         LEFT JOIN ingredient_query_plans plan ON plan.id = check_row.query_plan_id
        WHERE check_row.id = ?1`,
    ).bind(candidate.id).first<Record<string, unknown>>();
    if (row) claimed.push(row);
  }
  return claimed;
}

export async function heartbeatStoreCheck(db: D1Database, checkId: string, inputValue: unknown): Promise<void> {
  const input: StoreHeartbeat = ingredientStoreCheckHeartbeatSchema.parse(inputValue);
  const now = new Date();
  const update = await db.prepare(
    `UPDATE ingredient_store_checks
        SET heartbeat_at = ?4, lease_expires_at = ?5, updated_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND state = 'leased' AND lease_owner = ?2 AND lease_generation = ?3`,
  ).bind(checkId, input.owner, input.leaseGeneration, now.toISOString(), new Date(now.getTime() + input.leaseSeconds * 1000).toISOString()).run();
  if ((update.meta.changes ?? 0) !== 1) throw new Error("store-check heartbeat rejected by lease fence");
}

export async function resolveClaimedStoreCheckFromCatalog(db: D1Database, checkId: string, inputValue: unknown): Promise<Record<string, unknown>> {
  const input: StoreHeartbeat = ingredientStoreCheckHeartbeatSchema.parse(inputValue);
  const row = await db.prepare(
    `SELECT check_row.id, check_row.store_location_id, check_row.state, check_row.lease_owner, check_row.lease_generation,
            plan.canonical_term, plan.aliases_json, plan.exclusions_json, plan.plan_hash
       FROM ingredient_store_checks check_row
       JOIN ingredient_query_plans plan ON plan.id = check_row.query_plan_id
      WHERE check_row.id = ?1`,
  ).bind(checkId).first<{ id: string; store_location_id: string; state: string; lease_owner: string | null; lease_generation: number; canonical_term: string; aliases_json: string; exclusions_json: string; plan_hash: string }>();
  if (!row || row.state !== "leased" || row.lease_owner !== input.owner || row.lease_generation !== input.leaseGeneration) {
    throw new Error("catalog resolution rejected by lease fence");
  }
  const aliases = JSON.parse(row.aliases_json) as string[];
  const exclusions = JSON.parse(row.exclusions_json) as string[];
  const terms = [row.canonical_term, ...aliases];
  const catalog = await readStoreCatalog(db, row.store_location_id, terms);
  const candidates = catalogCandidatesForTerms(catalog.offers, terms, new Date(), exclusions);
  const selection = chooseCatalogWinner(candidates);
  const statements: D1PreparedStatement[] = [];
  for (const candidate of candidates) {
    const candidateId = await deterministicId("ingredient-candidate", checkId, candidate.productId, candidate.evidenceHash);
    statements.push(db.prepare(
      `INSERT INTO ingredient_store_candidates
         (id, store_check_id, product_id, observation_id, retailer_product_key, product_name, package_text,
          package_price_minor, normalized_basis_unit, normalized_basis_qty_micros, per_unit_micros, offer_kind,
          valid_from, valid_to, loyalty_required, membership_required, eligible, rejection_codes_json, evidence_hash)
       VALUES (?1, ?2, ?3, ?4, ?3, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, 1, '[]', ?16)
       ON CONFLICT(store_check_id, retailer_product_key, evidence_hash) DO NOTHING`,
    ).bind(candidateId, checkId, candidate.productId, candidate.observationId, candidate.productName, candidate.sizeText,
      candidate.packagePriceMinor, candidate.normalizedBasisUnit, candidate.normalizedBasisQtyMicros, candidate.perUnitMicros,
      candidate.offerKind, candidate.validFrom, candidate.validTo, candidate.loyaltyRequired ? 1 : 0, candidate.membershipRequired ? 1 : 0, candidate.evidenceHash));
  }
  const exactCoverage = await db.prepare(
    `SELECT COUNT(*) AS count FROM ingredient_query_coverage
      WHERE store_check_id = ?1 AND complete = 1 AND location_verified = 1 AND price_mode_verified = 1
        AND expires_at > CURRENT_TIMESTAMP AND normalized_query IN (${terms.map(() => "?").join(",")})`,
  ).bind(checkId, ...terms.map((term) => normalizeName(term))).first<{ count: number }>();
  const hasCompleteCoverage = Number(exactCoverage?.count ?? 0) === new Set(terms.map((term) => normalizeName(term))).size;
  const nextState = selection.winner && selection.winner.productUrl && hasCompleteCoverage ? "qa_pending" : "targeted_refresh";
  statements.push(db.prepare(
    `UPDATE ingredient_store_checks
        SET state = ?4, operational_state = CASE WHEN ?4 = 'qa_pending' THEN 'qa_queued' ELSE 'targeted_refresh' END,
            candidate_count = ?5, eligible_count = ?5,
            lease_owner = NULL, lease_expires_at = NULL, heartbeat_at = NULL,
            last_error = ?6, updated_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND state = 'leased' AND lease_owner = ?2 AND lease_generation = ?3`,
  ).bind(checkId, input.owner, input.leaseGeneration, nextState, candidates.length,
    selection.reason ?? (hasCompleteCoverage ? null : "exact query coverage is absent or expired; targeted search is required")));
  const results = await db.batch(statements);
  if ((results.at(-1)?.meta.changes ?? 0) !== 1) throw new Error("catalog resolution lost its lease fence");
  return {
    checkId,
    state: nextState,
    storeLocationId: row.store_location_id,
    catalogRootHash: catalog.rootHash,
    catalogCoverageMode: catalog.coverageMode,
    candidateCount: candidates.length,
    winner: selection.winner ? { productId: selection.winner.productId, observationId: selection.winner.observationId, perUnitMicros: selection.winner.perUnitMicros } : null,
    requiresSemanticQa: nextState === "qa_pending",
    requiresTargetedRefresh: nextState === "targeted_refresh",
  };
}

export async function qaClaimedCatalogStoreCheck(env: Pick<WorkerEnv, "DB" | "EVIDENCE">, checkId: string, inputValue: unknown): Promise<IngredientAggregate> {
  const input: StoreHeartbeat = ingredientStoreCheckHeartbeatSchema.parse(inputValue);
  const row = await env.DB.prepare(
    `SELECT check_row.store_location_id, check_row.lease_owner, check_row.lease_generation,
            gap.display_name, plan.canonical_term, policy.price_mode,
            candidate.product_id, candidate.product_name, candidate.package_text,
            candidate.package_price_minor, candidate.normalized_basis_unit,
            candidate.normalized_basis_qty_micros, candidate.per_unit_micros,
            candidate.offer_kind, candidate.valid_from, candidate.valid_to,
            candidate.loyalty_required, candidate.membership_required,
            offer.product_url, offer.availability_status, offer.seller_name, offer.captured_at,
            candidate.evidence_hash
       FROM ingredient_store_checks check_row
       JOIN ingredient_gaps gap ON gap.id = check_row.gap_id
       JOIN ingredient_query_plans plan ON plan.id = check_row.query_plan_id
       JOIN store_pricing_policies policy ON policy.store_location_id = check_row.store_location_id
       JOIN ingredient_store_candidates candidate ON candidate.store_check_id = check_row.id AND candidate.eligible = 1
       JOIN catalog_current_offers offer ON offer.store_location_id = check_row.store_location_id AND offer.product_id = candidate.product_id
      WHERE check_row.id = ?1 AND check_row.state = 'leased'
      ORDER BY candidate.per_unit_micros, candidate.id LIMIT 1`,
  ).bind(checkId).first<Record<string, unknown>>();
  if (!row || row.lease_owner !== input.owner || Number(row.lease_generation) !== input.leaseGeneration) {
    throw new Error("catalog QA rejected by lease fence or has no eligible candidate");
  }
  if (!row.product_url) throw new Error("catalog candidate lacks a first-party product URL");
  const checkedAt = String(row.captured_at);
  const result = ingredientStorePriceSchema.parse({
    storeLocationId: row.store_location_id, outcome: "priced", checkedAt,
    queryTerms: [row.canonical_term], searchComplete: true,
    qualifyingProductsExamined: 1, locationVerified: true, priceModeVerified: true,
    sourceUrl: row.product_url, evidenceSummary: `Catalog winner verified against the promoted location-bound capture for ${row.display_name}.`,
    productName: row.product_name, sellerName: row.seller_name ?? String(row.store_location_id),
    fulfillmentMode: row.price_mode, availabilityText: row.availability_status,
    packageText: row.package_text, packagePriceMinor: Number(row.package_price_minor),
    normalizedBasisUnit: row.normalized_basis_unit, normalizedBasisQtyMicros: Number(row.normalized_basis_qty_micros),
    perUnitMicros: Number(row.per_unit_micros), offerKind: row.offer_kind,
    validFrom: row.valid_from, validTo: row.valid_to,
    loyaltyRequired: Number(row.loyalty_required) === 1, membershipRequired: Number(row.membership_required) === 1,
  });
  const evidenceJson = stableJson({ schema: "tc-catalog-store-evidence-v1", checkId, result, sourceEvidenceHash: row.evidence_hash });
  const evidenceBytes = new TextEncoder().encode(evidenceJson);
  const sha256 = await digestHex(evidenceBytes);
  const objectKey = `ingredient-store-evidence/${checkId}/${sha256}.json`;
  await env.EVIDENCE.put(objectKey, evidenceBytes, { httpMetadata: { contentType: "application/json; charset=utf-8" }, customMetadata: { sha256, kind: "catalog-store-evidence" } });
  return completeStoreCheck(env, checkId, {
    owner: input.owner, leaseGeneration: input.leaseGeneration, result,
    evidence: { objectKey, sha256, byteLength: evidenceBytes.byteLength, contentType: "application/json; charset=utf-8" },
    candidateSetHash: await digestHex(stableJson([row.product_id, row.evidence_hash])),
    validatorVersions: { schema: "ingredient-store-price-v1", arithmetic: "deterministic-v1", identity: "exact-catalog-v1" },
  });
}

async function verifyEvidenceObject(bucket: R2Bucket, evidence: StoreComplete["evidence"]): Promise<void> {
  const object = await bucket.get(evidence.objectKey);
  if (!object) throw new Error("ingredient evidence object is absent from immutable storage");
  const bytes = new Uint8Array(await object.arrayBuffer());
  if (bytes.byteLength !== evidence.byteLength || await digestHex(bytes) !== evidence.sha256) {
    throw new Error("ingredient evidence object failed length or SHA-256 verification");
  }
}

export async function sealAggregateIfTerminal(env: Pick<WorkerEnv, "DB" | "EVIDENCE">, pricingJobId: string): Promise<IngredientAggregate> {
  const rows = await env.DB.prepare(
    `SELECT check_row.id, check_row.gap_id, check_row.store_location_id, check_row.state, check_row.result_json,
            check_row.evidence_id, check_row.qa_attestation_id,
            evidence.sha256 AS evidence_hash, qa.output_hash AS qa_hash
       FROM ingredient_store_checks check_row
       LEFT JOIN ingredient_evidence_refs evidence ON evidence.id = check_row.evidence_id
       LEFT JOIN ingredient_qa_attestations qa ON qa.id = check_row.qa_attestation_id
      WHERE check_row.pricing_job_id = ?1 ORDER BY check_row.store_location_id`,
  ).bind(pricingJobId).all<{ id: string; gap_id: string; store_location_id: string; state: string; result_json: string | null; evidence_id: string | null; qa_attestation_id: string | null; evidence_hash: string | null; qa_hash: string | null }>();
  const aggregate = aggregateStoreCheckStates(rows.results);
  await env.DB.prepare(
    `UPDATE ingredient_pricing_jobs
        SET state = ?2, operational_state = ?2, state_version = state_version + 1,
            terminal_store_count = ?3, priced_store_count = ?4,
            not_found_store_count = ?5, last_progress_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP WHERE id = ?1`,
  ).bind(pricingJobId, aggregate.state, aggregate.terminalCount, aggregate.pricedCount, aggregate.notFoundCount).run();
  if (aggregate.state === "store_checks_running") return aggregate;
  if (rows.results.length !== OMAHA_GROCERY_STORE_LOCATION_IDS.length || rows.results.some((row) => !row.evidence_hash || !row.qa_hash)) {
    throw new Error("terminal aggregate is missing immutable evidence or QA hashes");
  }
  const job = await env.DB.prepare(
    "SELECT gap_id, entity_id FROM ingredient_pricing_jobs WHERE id = ?1",
  ).bind(pricingJobId).first<{ gap_id: string; entity_id: string | null }>();
  if (!job) throw new Error("ingredient pricing job disappeared during aggregation");
  const bundle = {
    schema: "tc-ingredient-resolution-v2", pricingJobId, gapId: job.gap_id,
    disposition: aggregate.state === "ready_to_publish" ? "available" : "unavailable",
    stores: rows.results.map((row) => ({ storeLocationId: row.store_location_id, state: row.state, result: row.result_json ? JSON.parse(row.result_json) : null, evidenceHash: row.evidence_hash, qaHash: row.qa_hash })),
  };
  const bundleJson = stableJson(bundle);
  const evidenceRootHash = await digestHex(bundleJson);
  const resolutionId = await deterministicId("ingredient-resolution", pricingJobId, evidenceRootHash);
  const objectKey = `ingredient-resolutions/${resolutionId}.json`;
  await env.EVIDENCE.put(objectKey, bundleJson, { httpMetadata: { contentType: "application/json; charset=utf-8" }, customMetadata: { sha256: evidenceRootHash, kind: "ingredient-resolution" } });
  const stored = await env.EVIDENCE.head(objectKey);
  if (!stored || stored.size !== new TextEncoder().encode(bundleJson).byteLength || stored.customMetadata?.sha256 !== evidenceRootHash) {
    throw new Error("ingredient resolution bundle failed immutable storage verification");
  }
  const qaResultHash = await digestHex(stableJson(rows.results.map((row) => row.qa_hash)));
  const disposition = aggregate.state === "ready_to_publish" ? "available" : "unavailable";
  const statements: D1PreparedStatement[] = [
    env.DB.prepare(
      `INSERT INTO ingredient_resolution_versions
         (id, pricing_job_id, gap_id, disposition, evidence_root_hash, qa_policy_version, qa_result_hash, evidence_bundle_key, sealed_at)
       VALUES (?1, ?2, ?3, ?4, ?5, 'seven-store-terminal-v2', ?6, ?7, CURRENT_TIMESTAMP)
       ON CONFLICT(pricing_job_id, evidence_root_hash) DO NOTHING`,
    ).bind(resolutionId, pricingJobId, job.gap_id, disposition, evidenceRootHash, qaResultHash, objectKey),
    env.DB.prepare(
      `INSERT INTO ingredient_current_resolutions (gap_id, resolution_version_id)
       VALUES (?1, ?2) ON CONFLICT(gap_id) DO UPDATE SET resolution_version_id = excluded.resolution_version_id, updated_at = CURRENT_TIMESTAMP`,
    ).bind(job.gap_id, resolutionId),
    env.DB.prepare("UPDATE ingredient_pricing_jobs SET resolution_version_id = ?2, last_progress_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(pricingJobId, resolutionId),
    env.DB.prepare("UPDATE ingredient_pricing_inbox SET state = ?2, updated_at = CURRENT_TIMESTAMP WHERE pricing_job_id = ?1")
      .bind(pricingJobId, aggregate.state === "ready_to_publish" ? "publish_pending" : "active"),
    env.DB.prepare(
      `UPDATE ingredient_gaps SET status = ?2, updated_at = CURRENT_TIMESTAMP
        WHERE id = ?1 AND status NOT IN ('published','permanently_unavailable')`,
    ).bind(job.gap_id, aggregate.state),
    await appendOutbox(env.DB, aggregate.state === "ready_to_publish" ? "ingredient.resolution.available" : "ingredient.resolution.unavailable",
      "ingredient_resolution", resolutionId, `ingredient.resolution:${resolutionId}`, bundle),
  ];
  if (aggregate.state === "permanently_unavailable" && job.entity_id) {
    statements.push(env.DB.prepare(
      `INSERT INTO permanently_unavailable_ingredients
         (entity_id, resolution_version_id, identity_hash, aliases_json)
       SELECT entity.id, ?2, entity.identity_hash,
              COALESCE((SELECT json_group_array(alias.normalized_alias) FROM ingredient_aliases alias WHERE alias.entity_id = entity.id), '[]')
         FROM ingredient_entities entity WHERE entity.id = ?1
       ON CONFLICT(entity_id) DO NOTHING`,
    ).bind(job.entity_id, resolutionId));
    statements.push(env.DB.prepare(
      `UPDATE recipe_hold_requirements SET resolution_version_id = ?2, terminal_kind = 'unavailable', blocked_at = CURRENT_TIMESTAMP
        WHERE gap_id = ?1 AND terminal_kind IS NULL`,
    ).bind(job.gap_id, resolutionId));
    statements.push(env.DB.prepare("DELETE FROM ingredient_pricing_inbox WHERE pricing_job_id = ?1").bind(pricingJobId));
  }
  await env.DB.batch(statements);
  return aggregate;
}

export async function completeStoreCheck(env: Pick<WorkerEnv, "DB" | "EVIDENCE">, checkId: string, inputValue: unknown): Promise<IngredientAggregate> {
  const input: StoreComplete = ingredientStoreCheckCompleteSchema.parse(inputValue);
  const row = await env.DB.prepare(
    `SELECT id, pricing_job_id, gap_id, store_location_id, state, lease_owner, lease_generation
       FROM ingredient_store_checks WHERE id = ?1`,
  ).bind(checkId).first<{ id: string; pricing_job_id: string; gap_id: string; store_location_id: string; state: string; lease_owner: string | null; lease_generation: number }>();
  if (!row || row.state !== "leased" || row.lease_owner !== input.owner || row.lease_generation !== input.leaseGeneration) {
    throw new Error("store-check completion rejected by lease fence");
  }
  if (input.result.storeLocationId !== row.store_location_id) throw new Error("store-check result belongs to another store");
  if (input.result.outcome !== "priced" && input.result.outcome !== "not_found") {
    throw new Error("only QA-terminal priced or not_found results may complete a store check");
  }
  await verifyEvidenceObject(env.EVIDENCE, input.evidence);
  const evidenceId = await deterministicId("ingredient-evidence", checkId, input.evidence.sha256);
  const qaInputHash = await digestHex(stableJson({ result: input.result, candidateSetHash: input.candidateSetHash, evidenceHash: input.evidence.sha256 }));
  const qaOutputHash = await digestHex(stableJson({ verdict: input.result.outcome, validatorVersions: input.validatorVersions, qaInputHash }));
  const qaId = await deterministicId("ingredient-qa", checkId, qaInputHash, qaOutputHash);
  const state = input.result.outcome === "priced" ? "qa_verified_priced" : "qa_verified_not_found";
  const statements = [
    env.DB.prepare(
      `INSERT INTO ingredient_evidence_refs
         (id, store_check_id, kind, object_key, sha256, byte_length, content_type, observed_at, source_url)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
       ON CONFLICT(store_check_id, kind, sha256) DO NOTHING`,
    ).bind(evidenceId, checkId, input.result.outcome === "priced" ? "offer" : "not_found", input.evidence.objectKey,
      input.evidence.sha256, input.evidence.byteLength, input.evidence.contentType, input.result.checkedAt, input.result.sourceUrl),
    env.DB.prepare(
      `INSERT INTO ingredient_qa_attestations
         (id, store_check_id, input_hash, validator_versions_json, verdict, findings_json, output_hash)
       VALUES (?1, ?2, ?3, ?4, ?5, '[]', ?6)
       ON CONFLICT(store_check_id, input_hash, output_hash) DO NOTHING`,
    ).bind(qaId, checkId, qaInputHash, stableJson(input.validatorVersions), input.result.outcome, qaOutputHash),
    env.DB.prepare(
      `UPDATE ingredient_store_checks
          SET state = ?4, terminal_outcome = ?5, evidence_id = ?6, qa_attestation_id = ?7,
              candidate_count = ?8, eligible_count = ?9, lease_owner = NULL, lease_expires_at = NULL,
              heartbeat_at = NULL, last_error = NULL, result_json = ?10, updated_at = CURRENT_TIMESTAMP
        WHERE id = ?1 AND state = 'leased' AND lease_owner = ?2 AND lease_generation = ?3`,
    ).bind(checkId, input.owner, input.leaseGeneration, state, input.result.outcome, evidenceId, qaId,
      input.result.qualifyingProductsExamined, input.result.outcome === "priced" ? input.result.qualifyingProductsExamined : 0,
      stableJson(input.result)),
  ];
  const results = await env.DB.batch(statements);
  if ((results.at(-1)?.meta.changes ?? 0) !== 1) throw new Error("store-check completion lost its lease fence");
  return sealAggregateIfTerminal(env, row.pricing_job_id);
}

export async function ingestAgentIngredientResearch(env: Pick<WorkerEnv, "DB" | "EVIDENCE">, inputValue: unknown): Promise<IngredientAggregate | null> {
  void env;
  void inputValue;
  throw new Error("model-authored ingredient pricing is disabled; use first-party store capture and independent QA");
  /* Retained temporarily as forensic migration reference; intentionally unreachable.
  const research = ingredientPriceResearchSchema.parse(inputValue);
  const job = await env.DB.prepare(`SELECT job.id FROM ingredient_pricing_jobs job
      JOIN ingredient_gaps gap ON gap.id = job.gap_id
      WHERE job.gap_id = ?1 AND job.market_id = 'omaha' AND job.state != 'failed' AND gap.qa_resolution IS NULL`)
    .bind(research.gapId).first<{ id: string }>();
  if (!job) return null;
  for (const result of research.stores) {
    const check = await env.DB.prepare(
      `SELECT id, state FROM ingredient_store_checks WHERE pricing_job_id = ?1 AND store_location_id = ?2`,
    ).bind(job.id, result.storeLocationId).first<{ id: string; state: string }>();
    if (!check || terminalStates.has(check.state)) continue;
    const evidenceJson = stableJson({ schema: "tc-agent-targeted-store-evidence-v1", agentId: "ingredient-price-researcher", result });
    const bytes = new TextEncoder().encode(evidenceJson);
    const sha256 = await digestHex(bytes);
    const objectKey = `ingredient-store-evidence/${check.id}/${sha256}.json`;
    await env.EVIDENCE.put(objectKey, bytes, { httpMetadata: { contentType: "application/json; charset=utf-8" }, customMetadata: { sha256, kind: "agent-targeted-store-evidence" } });
    const evidenceId = await deterministicId("ingredient-evidence", check.id, sha256);
    const verified = result.outcome === "priced" || result.outcome === "not_found";
    const qaInputHash = verified ? await digestHex(stableJson({ result, evidenceHash: sha256 })) : null;
    const qaOutputHash = verified ? await digestHex(stableJson({ verdict: result.outcome, qaInputHash, policy: "targeted-agent-v1" })) : null;
    const qaId = verified ? await deterministicId("ingredient-qa", check.id, qaInputHash!, qaOutputHash!) : null;
    const state = result.outcome === "priced" ? "qa_verified_priced"
      : result.outcome === "not_found" ? "qa_verified_not_found"
        : result.outcome === "blocked" ? "blocked_challenge" : "ambiguous";
    const statements = [
      env.DB.prepare(`INSERT INTO ingredient_evidence_refs
        (id, store_check_id, kind, object_key, sha256, byte_length, content_type, observed_at, source_url)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'application/json; charset=utf-8', ?7, ?8)
        ON CONFLICT(store_check_id, kind, sha256) DO NOTHING`)
        .bind(evidenceId, check.id, result.outcome === "priced" ? "offer" : result.outcome === "not_found" ? "not_found" : "challenge", objectKey, sha256, bytes.byteLength, result.checkedAt, result.sourceUrl),
      env.DB.prepare(`UPDATE ingredient_store_checks SET state = ?2, terminal_outcome = ?3, evidence_id = ?4,
        qa_attestation_id = ?5, result_json = ?6, candidate_count = ?7, eligible_count = ?8,
        lease_owner = NULL, lease_expires_at = NULL, heartbeat_at = NULL, last_error = ?9, updated_at = CURRENT_TIMESTAMP
        WHERE id = ?1 AND state NOT IN ('qa_verified_priced','qa_verified_not_found')`)
        .bind(check.id, state, verified ? result.outcome : null, evidenceId, qaId, stableJson(result), result.qualifyingProductsExamined,
          result.outcome === "priced" ? result.qualifyingProductsExamined : 0, verified ? null : result.evidenceSummary),
    ];
    if (verified) statements.splice(1, 0, env.DB.prepare(`INSERT INTO ingredient_qa_attestations
        (id, store_check_id, input_hash, validator_versions_json, verdict, findings_json, output_hash)
        VALUES (?1, ?2, ?3, ?4, ?5, '[]', ?6) ON CONFLICT(store_check_id, input_hash, output_hash) DO NOTHING`)
        .bind(qaId, check.id, qaInputHash, stableJson({ schema: "ingredient-store-price-v1", identity: "codex-targeted-v1", arithmetic: "schema-v1" }), result.outcome, qaOutputHash));
    await env.DB.batch(statements);
  }
  const attention = await env.DB.prepare(`SELECT COUNT(*) AS count FROM ingredient_store_checks
    WHERE pricing_job_id = ?1 AND state IN ('blocked_challenge','ambiguous','adapter_quarantined')`).bind(job.id).first<{ count: number }>();
  if (Number(attention?.count ?? 0) > 0) {
    await env.DB.prepare("UPDATE ingredient_pricing_jobs SET state = 'needs_operator', updated_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(job.id).run();
    return null;
  }
  return sealAggregateIfTerminal(env, job.id);
  */
}

export async function failStoreCheck(db: D1Database, checkId: string, inputValue: unknown): Promise<void> {
  const input: StoreFail = ingredientStoreCheckFailSchema.parse(inputValue);
  const state = input.failureClass === "challenge" ? "blocked_challenge"
    : input.failureClass === "ambiguous" ? "ambiguous"
      : input.failureClass === "adapter_quarantined" ? "adapter_quarantined" : "transient_failed";
  const retryAt = input.retryAt ?? (input.failureClass === "transient" ? new Date(Date.now() + 30_000).toISOString() : "9999-12-31T23:59:59.999Z");
  const operationalState = input.failureClass === "challenge" ? "challenge_blocked"
    : input.failureClass === "ambiguous" ? "ambiguous"
      : input.failureClass === "adapter_quarantined" ? "adapter_quarantined" : "transient_backoff";
  const update = await db.prepare(
    `UPDATE ingredient_store_checks
        SET state = ?4, operational_state = ?8,
            resume_state = CASE WHEN ?4 = 'transient_failed' AND lease_lane = 'qa' THEN 'qa_queued'
                                WHEN ?4 = 'transient_failed' THEN 'capture_queued' ELSE resume_state END,
            challenge_id = ?5, error_class = ?9, last_error = ?6, next_attempt_at = ?7,
            lease_owner = NULL, lease_expires_at = NULL, heartbeat_at = NULL, lease_lane = NULL,
            last_progress_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND state = 'leased' AND lease_owner = ?2 AND lease_generation = ?3`,
  ).bind(checkId, input.owner, input.leaseGeneration, state, input.challengeId, input.reason, retryAt,
    operationalState, input.failureClass).run();
  if ((update.meta.changes ?? 0) !== 1) throw new Error("store-check failure rejected by lease fence");
  // A blocked or ambiguous store is isolated to its own check. The remaining
  // six store lanes continue; operator attention is derived from check state.
}

export async function pricingWaveStatus(db: D1Database, waveId: string): Promise<Record<string, unknown> | null> {
  const wave = await db.prepare("SELECT * FROM pricing_waves WHERE id = ?1").bind(waveId).first<Record<string, unknown>>();
  if (!wave) return null;
  const [jobs, stores, lastEvent] = await Promise.all([
    db.prepare(`SELECT job.state, COUNT(*) AS count FROM pricing_wave_members member
      JOIN ingredient_pricing_jobs job ON job.id = member.pricing_job_id
      WHERE member.wave_id = ?1 GROUP BY job.state ORDER BY job.state`).bind(waveId).all(),
    db.prepare(
      `SELECT check_row.store_location_id, check_row.state, COUNT(*) AS count
         FROM ingredient_store_checks check_row JOIN pricing_wave_members member ON member.pricing_job_id = check_row.pricing_job_id
        WHERE member.wave_id = ?1 GROUP BY check_row.store_location_id, check_row.state
        ORDER BY check_row.store_location_id, check_row.state`,
    ).bind(waveId).all(),
    db.prepare("SELECT * FROM pipeline_stage_events WHERE campaign_id = ?1 ORDER BY created_at DESC, id DESC LIMIT 1").bind(wave.campaign_id ?? waveId).first(),
  ]);
  return { ...wave, jobs: jobs.results, stores: stores.results, lastEvent };
}

export async function ingredientPipelineStatus(db: D1Database): Promise<Record<string, unknown>> {
  const [jobs, stores, waves, inbox, attention, lastProgress, challenges, outbox, stageLatency, orphans] = await Promise.all([
    db.prepare(`SELECT CASE WHEN job.operational_state = 'cancelled' AND gap.qa_resolution IS NOT NULL
          THEN 'cancelled_existing_alias' ELSE job.operational_state END AS state, COUNT(*) AS count
      FROM ingredient_pricing_jobs job JOIN ingredient_gaps gap ON gap.id = job.gap_id
      GROUP BY CASE WHEN job.operational_state = 'cancelled' AND gap.qa_resolution IS NOT NULL
          THEN 'cancelled_existing_alias' ELSE job.operational_state END ORDER BY state`).all(),
    db.prepare(`SELECT check_row.store_location_id, check_row.operational_state AS state, COUNT(*) AS count
      FROM ingredient_store_checks check_row JOIN ingredient_pricing_jobs job ON job.id = check_row.pricing_job_id
      WHERE job.operational_state = 'store_checks_running' GROUP BY check_row.store_location_id, check_row.operational_state
      ORDER BY check_row.store_location_id, check_row.operational_state`).all(),
    db.prepare("SELECT state, COUNT(*) AS count FROM pricing_waves GROUP BY state ORDER BY state").all(),
    db.prepare(`SELECT state, COUNT(*) AS count, MIN(created_at) AS oldest_created_at
      FROM ingredient_pricing_inbox GROUP BY state ORDER BY state`).all(),
    db.prepare(`SELECT check_row.id, check_row.gap_id, gap.display_name, check_row.store_location_id,
        check_row.operational_state AS state, check_row.challenge_id, check_row.last_error, check_row.updated_at
      FROM ingredient_store_checks check_row JOIN ingredient_gaps gap ON gap.id = check_row.gap_id
      JOIN ingredient_pricing_jobs job ON job.id = check_row.pricing_job_id
      WHERE check_row.operational_state IN ('challenge_blocked','ambiguous','adapter_quarantined','authentication_blocked')
        AND job.operational_state NOT IN ('cancelled','failed_manual') AND gap.qa_resolution IS NULL
      ORDER BY check_row.updated_at, check_row.id LIMIT 100`).all(),
    db.prepare(`SELECT MAX(changed_at) AS changed_at FROM (
      SELECT MAX(updated_at) AS changed_at FROM ingredient_store_checks
      UNION ALL SELECT MAX(updated_at) FROM ingredient_pricing_jobs
      UNION ALL SELECT MAX(last_progress_at) FROM pricing_waves
    )`).first<{ changed_at: string | null }>(),
    db.prepare(`SELECT store_location_id, COUNT(*) AS count, MIN(opened_at) AS oldest_opened_at
      FROM ingredient_capture_challenges WHERE resolved_at IS NULL AND abandoned_at IS NULL
      GROUP BY store_location_id ORDER BY store_location_id`).all(),
    db.prepare(`SELECT CASE WHEN acknowledged_at IS NULL THEN 'pending' ELSE 'acknowledged' END AS state,
      COUNT(*) AS count, MIN(created_at) AS oldest_created_at FROM pipeline_outbox
      GROUP BY CASE WHEN acknowledged_at IS NULL THEN 'pending' ELSE 'acknowledged' END ORDER BY state`).all(),
    db.prepare(`SELECT lane, stage, event_kind, COUNT(*) AS count, MAX(created_at) AS last_at
      FROM pipeline_stage_events WHERE created_at >= datetime('now','-1 day')
      GROUP BY lane, stage, event_kind ORDER BY lane, stage, event_kind`).all(),
    db.prepare(`SELECT COUNT(*) AS count FROM ingredient_store_checks check_row
      JOIN ingredient_pricing_jobs job ON job.id = check_row.pricing_job_id
      WHERE job.operational_state IN ('cancelled','public_verified','permanently_unavailable','failed_manual')
        AND check_row.operational_state NOT IN ('cancelled','qa_verified_priced','qa_verified_not_found')`).first<{ count: number }>(),
  ]);
  return { marketId: "omaha", waves: waves.results, jobs: jobs.results, stores: stores.results, inbox: inbox.results,
    needsOperator: attention.results, challenges: challenges.results, outbox: outbox.results,
    stagesLast24Hours: stageLatency.results, orphanActiveChecks: Number(orphans?.count ?? 0),
    lastProgressAt: lastProgress?.changed_at ?? null };
}

export async function pipelineEvents(db: D1Database, after: number, limit: number): Promise<{ events: Record<string, unknown>[]; next: number }> {
  const rows = await db.prepare(
    `SELECT id, topic, aggregate_kind, aggregate_id, payload_json, payload_hash, created_at
       FROM pipeline_outbox WHERE id > ?1 ORDER BY id LIMIT ?2`,
  ).bind(after, limit).all<Record<string, unknown>>();
  const events = rows.results.map((row) => ({ ...row, payload: JSON.parse(String(row.payload_json)), payload_json: undefined }));
  return { events, next: rows.results.length ? Number(rows.results.at(-1)?.id) : after };
}
