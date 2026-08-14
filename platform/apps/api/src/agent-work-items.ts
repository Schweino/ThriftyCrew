import {
  accuracyVerdictsSchema,
  contentBatchAuditSchema,
  contentBatchItemsSchema,
  ingredientPriceResearchSchema,
  ingredientDefinitionPlanSchema,
  pullRequestProposalSchema,
  recipeDedupSchema,
  recipeHuntDedupSchema,
  recipeHuntResultsSchema,
  recipeMapSchema,
  recipeSourceFactsSchema,
  recipeSourceCandidatesSchema,
  RECIPE_MIN_ACCOMPANIMENT_GRAMS_PER_SERVING,
  triagePlanSchema,
  type AgentWorkItemClaim,
  type AgentWorkItemComplete,
  type AgentWorkItemFail,
} from "@thriftycrew/contracts";
import { deterministicId, digestHex, normalizeName, stableJson } from "@thriftycrew/domain";
import type { z } from "zod";
import type { MutationIdentity, WorkerEnv } from "./env";
import { evaluateContentPromotion } from "./content-batches";
import { mergeRecipeCommodityCatalog } from "./recipe-commodity-catalog";
import { createPricingWave } from "./ingredient-pricing-v2";
import { assertPublicRecipeSourceUrl, decideRecipeFactsAgainstArtifact, recipeFactVerificationHash, verifyRecipeMappingContinuity } from "./recipe-source-verification";
import { expectedUnitDimension, extractShoppingRequirements } from "./ingredient-requirements";

interface RegistryRow {
  id: string;
  output_contract: string;
  execution_config_hash: string;
  criticality: "safety" | "operational" | "optional";
  prompt_sha256: string;
  input_contracts_json: string;
}

interface WorkSeed {
  sourceKind: "triage-item" | "accuracy-draw" | "recipe-request" | "source-sentinel-result" | "release-status";
  sourceRef: string;
  stage: string;
  input: unknown;
  severity: "safety" | "operational" | "optional";
}

export function isAtomicDiscoveryGapName(value: string): boolean {
  const normalized = normalizeName(value);
  if (!normalized || /^(?:hot |boiling |cold )?water$/.test(normalized)) return false;
  return !/\b(?:and|or)\b/.test(normalized);
}

export function normalizeAccuracyEvidenceRow(row: Record<string, unknown>): Record<string, unknown> {
  if (!row.observation_id && !row.product_name) return row;
  const parseEvidence = (value: unknown, field: string): Record<string, unknown> => {
    if (typeof value !== "string") return {};
    const parsed = JSON.parse(value) as unknown;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error(`${field} is not an evidence object`);
    return parsed as Record<string, unknown>;
  };
  const {
    price_semantics_json: priceSemanticsJson,
    offer_snapshot_json: offerSnapshotJson,
    market_verified: marketVerified,
    location_verified: locationVerified,
    price_mode_verified: priceModeVerified,
    ...facts
  } = row;
  return {
    ...facts,
    priceSemantics: parseEvidence(priceSemanticsJson, "price_semantics_json"),
    offerSnapshot: parseEvidence(offerSnapshotJson, "offer_snapshot_json"),
    captureVerification: {
      marketVerified: Number(marketVerified) === 1,
      locationVerified: Number(locationVerified) === 1,
      priceModeVerified: Number(priceModeVerified) === 1,
      priceMode: row.price_mode ?? null,
      sourceId: row.source_id ?? null,
      captureMethod: row.capture_method ?? null,
      coverageMode: row.coverage_mode ?? null,
      captureBatchId: row.capture_batch_id ?? null,
    },
  };
}

const RECIPE_CHAIN: Record<string, string | undefined> = {
  "recipe-sourcer": "recipe-deduper",
  "recipe-deduper": "recipe-fact-extractor",
  "recipe-fact-extractor": "recipe-mapper",
  "recipe-mapper": "recipe-writer",
  "recipe-writer": "recipe-auditor",
  "recipe-auditor": undefined,
};

export const activeIngredientCategoryContextSql = `SELECT category.id, category.label
  FROM categories category
  JOIN configuration_categories member ON member.category_id = category.id
  JOIN configuration_versions version ON version.id = member.configuration_id
 WHERE version.active = 1 ORDER BY category.sort_order, category.id`;

function object(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function array(value: unknown): Array<Record<string, unknown>> {
  return Array.isArray(value)
    ? value.filter((item): item is Record<string, unknown> => Boolean(item) && typeof item === "object" && !Array.isArray(item))
    : [];
}

async function currentRecipeCatalog(db: D1Database): Promise<Array<Record<string, unknown>>> {
  const rows = await db.prepare(
    `SELECT cost.recipe_slug, cost.detail_json
       FROM current_releases current
       JOIN release_recipe_costs cost ON cost.release_id = current.release_id
      WHERE current.market_id = 'omaha' ORDER BY cost.recipe_slug`,
  ).all<{ recipe_slug: string; detail_json: string }>();
  return rows.results.map((row) => {
    const detail = object(JSON.parse(row.detail_json));
    const commodityIds = [...new Set(array(detail.ingredients)
      .map((ingredient) => ingredient.commodityId)
      .filter((value): value is string => typeof value === "string" && value.length > 0))].sort();
    return { slug: row.recipe_slug, commodityIds };
  });
}

async function currentCommodityCatalog(db: D1Database): Promise<Array<Record<string, unknown>>> {
  const rows = await db.prepare(
    `SELECT commodity.id, commodity.label, commodity.basis_unit, category.label AS category
       FROM commodities commodity
       JOIN configuration_versions version ON version.id = commodity.configuration_id
       LEFT JOIN categories category ON category.id = commodity.category_id
      WHERE version.active = 1 AND commodity.active = 1
      ORDER BY category.sort_order, commodity.id`,
  ).all<Record<string, unknown>>();
  return mergeRecipeCommodityCatalog(rows.results);
}

async function activeAgent(db: D1Database, agentId: string): Promise<RegistryRow> {
  const row = await db.prepare(
    `SELECT id, output_contract, execution_config_hash, criticality, prompt_sha256, input_contracts_json
       FROM agent_registry WHERE id = ?1 AND active = 1 AND enabled = 1`,
  ).bind(agentId).first<RegistryRow>();
  if (!row || !row.execution_config_hash) throw new Error("agent is unknown, disabled, or missing an execution configuration hash");
  return row;
}

async function seedsFor(db: D1Database, agentId: string): Promise<WorkSeed[]> {
  if (agentId === "triage-reviewer") {
    const rows = await db.prepare(
      `SELECT id, source_kind, source_ref, severity, title, evidence_json, created_at
         FROM triage_items WHERE status = 'open' ORDER BY created_at, id LIMIT 25`,
    ).all<Record<string, unknown>>();
    return rows.results.map((row) => ({
      sourceKind: "triage-item", sourceRef: String(row.id), stage: "review",
      severity: String(row.severity) === "hard" || String(row.severity) === "safety" ? "safety" : "operational",
      input: { contract: "triage-item-v1", item: row },
    }));
  }
  if (agentId === "triage-developer") {
    const rows = await db.prepare(
      `SELECT id, source_kind, source_ref, severity, title, evidence_json, plan_ref, resolution_json, updated_at
         FROM triage_items WHERE status = 'planned' ORDER BY updated_at, id LIMIT 25`,
    ).all<Record<string, unknown>>();
    return rows.results.map((row) => ({
      sourceKind: "triage-item", sourceRef: String(row.id), stage: "develop",
      severity: String(row.severity) === "hard" || String(row.severity) === "safety" ? "safety" : "operational",
      input: { contract: "triage-plan-v1", item: row, plan: JSON.parse(String(row.resolution_json ?? "{}")) },
    }));
  }
  if (agentId === "accuracy-headless") {
    const rows = await db.prepare(
      `SELECT id, market_id, release_id, requested_size, sampled_count, seed, protocol_version, created_at, due_at
         FROM accuracy_draws WHERE status = 'open' ORDER BY created_at, id LIMIT 10`,
    ).all<Record<string, unknown>>();
    return Promise.all(rows.results.map(async (row) => {
      const cells = await db.prepare(
        `SELECT cell.ordinal, cell.commodity_id, commodity.label AS commodity_label,
                cell.store_location_id, location.display_name AS store_name,
                version.name AS product_name, version.size_text, version.product_url, version.taxonomy_path,
                observation.purchase_price_minor, observation.purchase_quantity, observation.package_count,
                observation.normalized_basis_unit, observation.normalized_basis_qty_micros,
                observation.per_unit_micros, observation.raw_price_text, observation.captured_at,
                observation.kind AS offer_kind, observation.regular_price_minor,
                observation.loyalty_required, observation.membership_required,
                observation.price_semantics_json, observation.offer_snapshot_json,
                observation.availability_status, observation.fulfillment_mode, observation.seller_name,
                batch.id AS capture_batch_id, batch.source_id, source.capture_method,
                batch.coverage_mode, batch.price_mode, batch.market_verified,
                batch.location_verified, batch.price_mode_verified
           FROM accuracy_draw_cells cell
           JOIN accuracy_draws draw ON draw.id = cell.draw_id
           JOIN releases release ON release.id = draw.release_id
           JOIN commodities commodity ON commodity.id = cell.commodity_id AND commodity.configuration_id = release.configuration_id
           JOIN store_locations location ON location.id = cell.store_location_id
           JOIN observations observation ON observation.id = cell.observation_id
           JOIN product_versions version ON version.id = observation.product_version_id
           JOIN capture_batches batch ON batch.id = observation.batch_id
           JOIN capture_sources source ON source.id = batch.source_id
          WHERE cell.draw_id = ?1 ORDER BY cell.ordinal`,
      ).bind(String(row.id)).all();
      const riskSamples = await db.prepare(
        `SELECT sample.ordinal, sample.lane, sample.risk_kind, sample.risk_score,
                sample.commodity_id, sample.store_location_id, sample.observation_id, sample.recipe_slug,
                sample.evidence_json, commodity.label AS commodity_label, location.display_name AS store_name,
                version.name AS product_name, version.size_text, version.product_url, version.taxonomy_path,
                observation.purchase_price_minor, observation.purchase_quantity, observation.package_count,
                observation.normalized_basis_unit, observation.normalized_basis_qty_micros,
                observation.per_unit_micros, observation.raw_price_text, observation.captured_at,
                observation.kind AS offer_kind, observation.regular_price_minor,
                observation.loyalty_required, observation.membership_required,
                observation.price_semantics_json, observation.offer_snapshot_json,
                observation.availability_status, observation.fulfillment_mode, observation.seller_name,
                batch.id AS capture_batch_id, batch.source_id, source.capture_method,
                batch.coverage_mode, batch.price_mode, batch.market_verified,
                batch.location_verified, batch.price_mode_verified,
                cost.status AS recipe_status, cost.batch_cost_minor, cost.serving_cost_minor, cost.detail_json
           FROM accuracy_risk_samples sample
           JOIN accuracy_draws draw ON draw.id = sample.draw_id
           JOIN releases release ON release.id = draw.release_id
           LEFT JOIN commodities commodity ON commodity.id = sample.commodity_id AND commodity.configuration_id = release.configuration_id
           LEFT JOIN store_locations location ON location.id = sample.store_location_id
           LEFT JOIN observations observation ON observation.id = sample.observation_id
           LEFT JOIN product_versions version ON version.id = observation.product_version_id
           LEFT JOIN capture_batches batch ON batch.id = observation.batch_id
           LEFT JOIN capture_sources source ON source.id = batch.source_id
           LEFT JOIN release_recipe_costs cost ON cost.release_id = sample.release_id AND cost.recipe_slug = sample.recipe_slug
          WHERE sample.draw_id = ?1 ORDER BY sample.ordinal`,
      ).bind(String(row.id)).all();
      return { sourceKind: "accuracy-draw", sourceRef: String(row.id), stage: "judge", severity: "safety", input: {
        contract: "accuracy-blind-sample-v1", draw: row,
        cells: cells.results.map((cell) => normalizeAccuracyEvidenceRow(cell as Record<string, unknown>)),
        riskSamples: riskSamples.results.map((sample) => normalizeAccuracyEvidenceRow(sample as Record<string, unknown>)),
      } };
    }));
  }
  if (agentId === "source-sentinel-investigator") {
    const rows = await db.prepare(
      `SELECT result.id, result.source_id, result.contract_version, result.status,
              result.checks_json, result.evidence_json, result.observed_at
         FROM source_sentinel_results result
         JOIN triage_items triage
           ON triage.source_kind = 'operational_alert'
          AND triage.source_ref = 'source-contract:' || result.source_id
          AND triage.status <> 'resolved'
        WHERE result.status = 'fail'
        ORDER BY result.observed_at DESC LIMIT 10`,
    ).all<Record<string, unknown>>();
    return rows.results.map((row) => ({ sourceKind: "source-sentinel-result", sourceRef: String(row.id), stage: "investigate", severity: "operational", input: { contract: "source-sentinel-result-v1", result: row } }));
  }
  if (agentId === "post-publish-reviewer") {
    const row = await db.prepare(
      `SELECT release.id, release.published_at, release.configuration_id, release.input_hash, release.summary_json
         FROM current_releases current JOIN releases release ON release.id = current.release_id
        WHERE current.market_id = 'omaha'`,
    ).first<Record<string, unknown>>();
    return row ? [{ sourceKind: "release-status", sourceRef: String(row.id), stage: "review", severity: "safety", input: { contract: "release-status-v1", release: row } }] : [];
  }
  if (agentId === "recipe-sourcer") {
    const rows = await db.prepare(
      `SELECT request.id, request.request_text, request.source_ref, request.requested_at,
              discovery.target_missing_ingredients, discovery.unique_missing_ingredients,
              discovery.target_published_ingredients, discovery.source_round, discovery.state AS discovery_state
         FROM recipe_suggestion_requests request
         LEFT JOIN ingredient_discovery_batches discovery ON discovery.request_id = request.id
        WHERE request.status = 'queued' AND (discovery.request_id IS NULL OR (discovery.paused_at IS NULL AND discovery.discovery_frozen_at IS NULL))
        ORDER BY request.requested_at, request.id LIMIT 10`,
    ).all<Record<string, unknown>>();
    const commodities = rows.results.length > 0 ? await currentCommodityCatalog(db) : [];
    const sourcingCommodities = commodities.map((commodity) => [commodity.id, commodity.label, commodity.category]
      .filter((value) => typeof value === "string" && value.length > 0).join(" | "));
    const unavailable = rows.results.length > 0 ? await db.prepare(
      `SELECT display_name, normalized_name FROM ingredient_gaps
        WHERE status = 'permanently_unavailable' ORDER BY normalized_name`,
    ).all<{ display_name: string; normalized_name: string }>() : { results: [] };
    return Promise.all(rows.results.map(async (row) => {
      const prior = row.target_missing_ingredients ? await db.prepare(
        `SELECT DISTINCT occurrence.source_url, gap.normalized_name
           FROM ingredient_gap_occurrences occurrence
           JOIN ingredient_gaps gap ON gap.id = occurrence.gap_id
          WHERE occurrence.request_id = ?1 ORDER BY occurrence.source_url, gap.normalized_name`,
      ).bind(row.id).all<{ source_url: string; normalized_name: string }>() : { results: [] };
      const rejectedSources = row.target_missing_ingredients ? await db.prepare(
        `SELECT DISTINCT json_extract(detail_json, '$.sourceUrl') AS source_url
           FROM pipeline_stage_events
          WHERE campaign_id = ?1 AND lane = 'discovery' AND event_kind = 'source_rejected'
            AND json_extract(detail_json, '$.sourceUrl') IS NOT NULL
          ORDER BY source_url`,
      ).bind(row.id).all<{ source_url: string }>() : { results: [] };
      return {
        sourceKind: "recipe-request" as const,
        sourceRef: String(row.id),
        stage: "source",
        severity: "optional" as const,
        input: {
          contract: "recipe-source-request-v1",
          request: row,
          commodities: sourcingCommodities,
          permanentlyUnavailable: unavailable.results,
          discovery: row.target_missing_ingredients ? {
            targetMissingIngredients: row.target_published_ingredients ?? row.target_missing_ingredients,
            uniqueMissingIngredients: row.unique_missing_ingredients,
            requestedLeadCount: Math.min(50, Math.max(20,
              (Number(row.target_published_ingredients ?? row.target_missing_ingredients) - Number(row.unique_missing_ingredients ?? 0)) * 3)),
            sourceRound: row.source_round,
            priorSourceUrls: [...new Set([
              ...prior.results.map((item) => item.source_url),
              ...rejectedSources.results.map((item) => item.source_url),
            ])],
            previouslyFoundIngredients: [...new Set(prior.results.map((item) => item.normalized_name))],
          } : null,
        },
      };
    }));
  }
  if (agentId === "ingredient-price-researcher") {
    // V3 containment boundary: generic model/web research is not a pricing
    // execution plane and may never be seeded as public price authority.
    return [];
  }
  return [];
}

async function enqueue(db: D1Database, agent: RegistryRow, seed: WorkSeed, adapterVersion: string, inputContract: string): Promise<string> {
  const inputJson = stableJson(seed.input);
  const fingerprint = await digestHex(stableJson({
    agentId: agent.id,
    sourceKind: seed.sourceKind,
    sourceRef: seed.sourceRef,
    stage: seed.stage,
    adapterVersion,
    inputContract,
    executionConfigHash: agent.execution_config_hash,
    input: seed.input,
  }));
  const id = await deterministicId("agent-work", agent.id, fingerprint);
  await db.prepare(
    `INSERT INTO agent_work_items
       (id, agent_id, source_kind, source_ref, stage, adapter_version, input_contract,
        output_contract, execution_config_hash, execution_fingerprint, severity, input_json)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
     ON CONFLICT(execution_fingerprint) DO NOTHING`,
  ).bind(id, agent.id, seed.sourceKind, seed.sourceRef, seed.stage, adapterVersion, inputContract,
    agent.output_contract, agent.execution_config_hash, fingerprint, seed.severity, inputJson).run();
  return id;
}

export interface IngredientCampaignSnapshot {
  requestId: string;
  state: string;
  targetPublishedIngredients: number;
  desiredPricingWorkers: number;
  publishBatchSize: number;
  pausedAt: string | null;
  discoveryFrozenAt: string | null;
  published: number;
  pending: number;
  researching: number;
  readyToPublish: number;
  permanentlyUnavailable: number;
  needsOperator: number;
  totalUniqueGaps: number;
}

export function ingredientDiscoveryBufferTarget(targetPublishedIngredients: number): number {
  return targetPublishedIngredients + Math.max(10, Math.min(20, Math.ceil(targetPublishedIngredients * 0.4)));
}

export function ingredientCampaignPhase(snapshot: IngredientCampaignSnapshot): "collecting" | "pricing" | "completed" {
  if (snapshot.discoveryFrozenAt) {
    const open = snapshot.pending + snapshot.researching + snapshot.readyToPublish + snapshot.needsOperator;
    return open === 0 ? "completed" : "pricing";
  }
  if (snapshot.published >= snapshot.targetPublishedIngredients) return "completed";
  const viable = snapshot.published + snapshot.pending + snapshot.researching + snapshot.readyToPublish;
  return viable < ingredientDiscoveryBufferTarget(snapshot.targetPublishedIngredients) ? "collecting" : "pricing";
}

export async function ingredientCampaignSnapshot(db: D1Database, requestId: string): Promise<IngredientCampaignSnapshot | null> {
  const row = await db.prepare(
    `SELECT batch.request_id, batch.state, batch.target_published_ingredients,
            batch.desired_pricing_workers, batch.publish_batch_size, batch.paused_at, batch.discovery_frozen_at,
            COUNT(DISTINCT gap.id) AS total_unique_gaps,
            COUNT(DISTINCT CASE WHEN gap.status = 'published' THEN gap.id END) AS published,
            COUNT(DISTINCT CASE WHEN gap.status = 'pending' THEN gap.id END) AS pending,
            COUNT(DISTINCT CASE WHEN gap.status = 'researching' THEN gap.id END) AS researching,
            COUNT(DISTINCT CASE WHEN gap.status = 'ready_to_publish' THEN gap.id END) AS ready_to_publish,
            COUNT(DISTINCT CASE WHEN gap.status = 'permanently_unavailable' THEN gap.id END) AS permanently_unavailable,
            COUNT(DISTINCT CASE WHEN gap.status = 'needs_operator' AND gap.qa_resolution IS NULL THEN gap.id END) AS needs_operator
       FROM ingredient_discovery_batches batch
       LEFT JOIN ingredient_gap_occurrences occurrence ON occurrence.request_id = batch.request_id
       LEFT JOIN ingredient_gaps gap ON gap.id = occurrence.gap_id
      WHERE batch.request_id = ?1 GROUP BY batch.request_id`,
  ).bind(requestId).first<Record<string, unknown>>();
  if (!row) return null;
  return {
    requestId: String(row.request_id), state: String(row.state),
    targetPublishedIngredients: Number(row.target_published_ingredients),
    desiredPricingWorkers: Number(row.desired_pricing_workers), publishBatchSize: Number(row.publish_batch_size),
    pausedAt: row.paused_at ? String(row.paused_at) : null,
    discoveryFrozenAt: row.discovery_frozen_at ? String(row.discovery_frozen_at) : null,
    published: Number(row.published), pending: Number(row.pending), researching: Number(row.researching),
    readyToPublish: Number(row.ready_to_publish), permanentlyUnavailable: Number(row.permanently_unavailable),
    needsOperator: Number(row.needs_operator), totalUniqueGaps: Number(row.total_unique_gaps),
  };
}

export async function reconcileIngredientCampaign(db: D1Database, requestId: string): Promise<IngredientCampaignSnapshot | null> {
  const snapshot = await ingredientCampaignSnapshot(db, requestId);
  if (!snapshot || snapshot.pausedAt) return snapshot;
  const state = ingredientCampaignPhase(snapshot);
  if (state === "collecting" && !snapshot.discoveryFrozenAt) {
    const sourcing = await db.prepare(
      `SELECT batch.source_round, request.status,
              MAX(CASE WHEN work.agent_id = 'recipe-sourcer'
                    THEN CAST(json_extract(work.input_json, '$.discovery.sourceRound') AS INTEGER) END) AS latest_seeded_round,
              SUM(CASE WHEN work.state IN ('queued','retryable','leased') THEN 1 ELSE 0 END) AS active_work
         FROM ingredient_discovery_batches batch
         JOIN recipe_suggestion_requests request ON request.id = batch.request_id
         LEFT JOIN agent_work_items work ON work.source_ref = batch.request_id
        WHERE batch.request_id = ?1 GROUP BY batch.request_id, request.status`,
    ).bind(requestId).first<{ source_round: number; status: string; latest_seeded_round: number | null; active_work: number }>();
    // The round is part of the sourcer work-item fingerprint. Advance it once
    // only after that round's entire chain is terminal and the request has been
    // returned to collecting. The newly advanced round has no matching seed,
    // so repeated reconciliation is idempotent until the sourcer claims it.
    if (sourcing?.status === "queued" && Number(sourcing.active_work) === 0
      && sourcing.latest_seeded_round !== null && Number(sourcing.latest_seeded_round) >= Number(sourcing.source_round)) {
      await db.prepare(
        "UPDATE ingredient_discovery_batches SET source_round = source_round + 1, updated_at = CURRENT_TIMESTAMP WHERE request_id = ?1 AND source_round = ?2",
      ).bind(requestId, sourcing.source_round).run();
    }
  }
  await db.batch([
    db.prepare("UPDATE ingredient_discovery_batches SET state = ?2, updated_at = CURRENT_TIMESTAMP WHERE request_id = ?1")
      .bind(requestId, state),
    db.prepare("UPDATE recipe_suggestion_requests SET status = ?2, updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status <> 'promoted'")
      .bind(requestId, state === "completed" ? "reviewed" : state === "collecting" ? "queued" : "running"),
  ]);
  return { ...snapshot, state };
}

export async function reconcileIngredientHolds(db: D1Database): Promise<void> {
  const holds = await db.prepare(
    `SELECT id, request_id, mapper_work_item_id, candidate_id, candidate_json, gap_ids_json, discovery_only,
            source_fact_version_id, mapping_version_id
       FROM recipe_ingredient_holds WHERE status = 'paused' ORDER BY created_at, id`,
  ).all<Record<string, unknown>>();
  if (holds.results.length === 0) {
    const batches = await db.prepare("SELECT request_id FROM ingredient_discovery_batches ORDER BY request_id").all<{ request_id: string }>();
    for (const batch of batches.results) await reconcileIngredientCampaign(db, batch.request_id);
    return;
  }
  const writer = await activeAgent(db, "recipe-writer");
  for (const hold of holds.results) {
    const requirements = await db.prepare(
      `SELECT gap_id FROM recipe_hold_requirement_occurrences
        WHERE hold_id = ?1 AND role = 'purchased' AND gap_id IS NOT NULL
        ORDER BY source_ingredient_index, split_component_index`,
    ).bind(hold.id).all<{ gap_id: string }>();
    const gapIds = [...new Set(requirements.results.map((row) => row.gap_id))];
    if (gapIds.length === 0) {
      await db.prepare("UPDATE recipe_ingredient_holds SET resume_error = 'relational dependency occurrences are missing', updated_at = CURRENT_TIMESTAMP WHERE id = ?1")
        .bind(hold.id).run();
      continue;
    }
    const gaps = await db.prepare(
      `SELECT id, status, commodity_id, qa_resolution, qa_resolution_commodity_id
         FROM ingredient_gaps WHERE id IN (${gapIds.map(() => "?").join(",")}) ORDER BY id`,
    ).bind(...gapIds).all<{ id: string; status: string; commodity_id: string | null; qa_resolution: string | null; qa_resolution_commodity_id: string | null }>();
    const terminal = gaps.results.every((gap) => gap.status === "published" || gap.status === "permanently_unavailable" || gap.qa_resolution === "existing_alias");
    if (!terminal) continue;
    if (gaps.results.some((gap) => gap.status === "permanently_unavailable")) {
      await db.batch([
        db.prepare("UPDATE recipe_ingredient_holds SET status = 'rejected', updated_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(hold.id),
        db.prepare("UPDATE recipe_suggestion_requests SET status = 'rejected', updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status <> 'promoted'").bind(hold.request_id),
      ]);
      continue;
    }
    if (Number(hold.discovery_only) === 1) {
      await db.prepare("UPDATE recipe_ingredient_holds SET status = 'completed', updated_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(hold.id).run();
      continue;
    }
    if (!hold.source_fact_version_id || !hold.mapping_version_id) {
      await db.prepare("UPDATE recipe_ingredient_holds SET resume_error = 'immutable fact or mapping version is missing; legacy self-verification is prohibited', updated_at = CURRENT_TIMESTAMP WHERE id = ?1")
        .bind(hold.id).run();
      continue;
    }
    const locked = await db.prepare(
      `SELECT mapping.mapping_json, mapping.mapping_hash, facts.facts_hash
         FROM recipe_mapping_versions mapping
         JOIN recipe_source_fact_versions facts ON facts.id = mapping.source_fact_version_id
        WHERE mapping.id = ?1 AND facts.id = ?2 AND mapping.verified_at IS NOT NULL AND facts.verified_at IS NOT NULL`,
    ).bind(hold.mapping_version_id, hold.source_fact_version_id).first<{ mapping_json: string; mapping_hash: string; facts_hash: string }>();
    if (!locked) {
      await db.prepare("UPDATE recipe_ingredient_holds SET resume_error = 'immutable fact or mapping verification is absent', updated_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(hold.id).run();
      continue;
    }
    const occurrenceRows = await db.prepare(
      `SELECT occurrence.source_line, occurrence.source_ingredient_index, occurrence.split_component_index, gap.id AS gap_id,
              COALESCE(gap.qa_resolution_commodity_id, gap.commodity_id) AS commodity_id
         FROM recipe_hold_requirement_occurrences occurrence
         JOIN ingredient_gaps gap ON gap.id = occurrence.gap_id
        WHERE occurrence.hold_id = ?1 AND occurrence.role = 'purchased'
        ORDER BY occurrence.source_ingredient_index, occurrence.split_component_index`,
    ).bind(hold.id).all<{ source_line: string; source_ingredient_index: number; split_component_index: number; gap_id: string; commodity_id: string | null }>();
    const commodityByOccurrence = new Map(occurrenceRows.results.map((row) => [`${row.source_ingredient_index}:${row.split_component_index}`, row.commodity_id]));
    const lockedRecipe = JSON.parse(locked.mapping_json) as z.infer<typeof recipeMapSchema>["recipes"][number];
    const ingredients = lockedRecipe.ingredients.map((ingredient, mappedIndex) => {
      if (ingredient.decision !== "unmapped") return ingredient;
      const sourceIngredientIndex = ingredient.sourceIngredientIndex ?? mappedIndex;
      const splitComponentIndex = ingredient.splitComponentIndex ?? 0;
      const commodityId = commodityByOccurrence.get(`${sourceIngredientIndex}:${splitComponentIndex}`);
      return commodityId ? { ...ingredient, commodityId, decision: "alias" as const, evidence: "Public-verified missing ingredient resolution bound to the immutable source occurrence." } : ingredient;
    });
    const mealComponents = lockedRecipe.candidate.mealComponents.map((component) => ({
      role: component.role,
      label: component.label,
      commodityIds: [...new Set(component.ingredientIndexes.flatMap((index) => ingredients
        .filter((ingredient, mappedIndex) => (ingredient.sourceIngredientIndex ?? mappedIndex) === index)
        .flatMap((ingredient) => ingredient.commodityId ?? [])))],
    }));
    const gramsByCommodity = new Map(ingredients.flatMap((ingredient) => ingredient.commodityId && ingredient.grams !== null ? [[ingredient.commodityId, ingredient.grams] as const] : []));
    const accompanimentIds = new Set(mealComponents.filter((component) => component.role === "substantial-accompaniment").flatMap((component) => component.commodityIds));
    const accompanimentGrams = [...accompanimentIds].reduce((sum, commodityId) => sum + (gramsByCommodity.get(commodityId) ?? 0), 0);
    const readyForWriting = lockedRecipe.candidate.sourceServings !== null
      && ingredients.every((ingredient) => ingredient.decision === "process" || (ingredient.decision !== "unmapped" && ingredient.scalingStatus === "scaled"))
      && accompanimentGrams >= 14 * RECIPE_MIN_ACCOMPANIMENT_GRAMS_PER_SERVING;
    if (!readyForWriting) {
      await db.prepare("UPDATE recipe_ingredient_holds SET resume_error = 'resolved commodity still requires a bounded quantity conversion review', updated_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(hold.id).run();
      continue;
    }
    const resumedMap = recipeMapSchema.parse({ requestId: hold.request_id, recipes: [{ ...lockedRecipe, ingredients, mealComponents, readyForWriting, issues: [] }] });
    const currentRelease = await db.prepare(
      `SELECT current.release_id, release.configuration_id
         FROM current_releases current JOIN releases release ON release.id = current.release_id
        WHERE current.market_id = 'omaha' AND release.state = 'published'`,
    ).first<{ release_id: string; configuration_id: string }>();
    if (!currentRelease) throw new Error("recipe resume requires a current public grocery release");
    const dependencyRoot = await digestHex(stableJson({ factsHash: locked.facts_hash, mappingHash: locked.mapping_hash,
      gaps: gaps.results.map((gap) => [gap.id, gap.status, gap.commodity_id, gap.qa_resolution_commodity_id]) }));
    const resumeEventId = await deterministicId("recipe-resume", String(hold.id), dependencyRoot, currentRelease.release_id);
    await db.batch([
      db.prepare(
        `INSERT INTO recipe_resume_events
           (id, hold_id, dependency_root_hash, configuration_id, release_id)
         VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT(hold_id, dependency_root_hash, release_id) DO NOTHING`,
      ).bind(resumeEventId, hold.id, dependencyRoot, currentRelease.configuration_id, currentRelease.release_id),
      ...gapIds.map((gapId) => db.prepare(
        `UPDATE recipe_hold_requirements SET terminal_kind = 'available', satisfied_at = CURRENT_TIMESTAMP
          WHERE hold_id = ?1 AND gap_id = ?2 AND terminal_kind IS NULL`,
      ).bind(hold.id, gapId)),
    ]);
    const writerWorkItemId = await enqueue(db, writer, {
      sourceKind: "recipe-request", sourceRef: String(hold.request_id), stage: "writer-resume", severity: writer.criticality,
      input: {
        contract: "recipe-map-v2", previousWorkItemId: hold.mapper_work_item_id,
        output: resumedMap, nextAgentId: "recipe-writer", nextPromptHash: writer.prompt_sha256,
        resumeEventId, dependencyRoot, releaseId: currentRelease.release_id,
      },
    }, "phase2-v1", "recipe-map-v2");
    await db.batch([
      db.prepare("UPDATE recipe_ingredient_holds SET status = 'resumed', resume_error = NULL, updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status = 'paused'").bind(hold.id),
      db.prepare("UPDATE recipe_resume_events SET state = 'consumed', consumed_work_item_id = ?2, consumed_at = CURRENT_TIMESTAMP WHERE id = ?1 AND state = 'ready'").bind(resumeEventId, writerWorkItemId),
      db.prepare("UPDATE recipe_suggestion_requests SET status = 'running', updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status <> 'promoted'").bind(hold.request_id),
    ]);
  }
  const batches = await db.prepare("SELECT request_id FROM ingredient_discovery_batches ORDER BY request_id").all<{ request_id: string }>();
  for (const batch of batches.results) await reconcileIngredientCampaign(db, batch.request_id);
}

export async function claimAgentWorkItem(db: D1Database, identity: MutationIdentity, body: AgentWorkItemClaim): Promise<Record<string, unknown> | null> {
  if (identity.registeredAgentId !== body.agentId) throw new Error("an agent may only claim its own registered work");
  const agent = await activeAgent(db, body.agentId);
  if (body.agentId === "recipe-writer") await reconcileIngredientHolds(db);
  if (body.adapterVersion !== "phase2-v1") throw new Error("agent adapter version is not registered");
  const inputContracts = JSON.parse(agent.input_contracts_json) as string[];
  if (!inputContracts.includes(body.inputContract)) throw new Error("agent input contract is not registered");
  const evaluation = await db.prepare(
    `SELECT id FROM agent_evaluations
      WHERE agent_id = ?1 AND execution_config_hash = ?2 AND passed = 1
      ORDER BY evaluated_at DESC LIMIT 1`,
  ).bind(agent.id, agent.execution_config_hash).first<{ id: string }>();
  if (!evaluation) throw new Error("agent execution is blocked until this exact execution configuration passes evaluation");
  for (const seed of await seedsFor(db, body.agentId)) await enqueue(db, agent, seed, body.adapterVersion, body.inputContract);
  const now = new Date();
  await db.prepare(
    `UPDATE agent_work_items SET state = 'retryable', lease_id = NULL, lease_expires_at = NULL,
       updated_at = CURRENT_TIMESTAMP, last_error = 'lease expired'
     WHERE agent_id = ?1 AND state = 'leased' AND lease_expires_at <= ?2`,
  ).bind(agent.id, now.toISOString()).run();
  const candidate = await db.prepare(
    `SELECT id FROM agent_work_items
      WHERE agent_id = ?1 AND execution_config_hash = ?2
        AND state IN ('queued', 'retryable') AND available_at <= ?3
        AND attempt_count < max_attempts
      ORDER BY CASE WHEN agent_id = 'accuracy-headless' AND source_kind = 'accuracy-draw'
                         AND EXISTS (SELECT 1 FROM accuracy_draws draw
                                      WHERE draw.id = agent_work_items.source_ref
                                        AND draw.protocol_version = 'winner-challenger-v1')
                    THEN 0 ELSE 1 END,
               CASE severity WHEN 'safety' THEN 0 WHEN 'operational' THEN 1 ELSE 2 END,
               created_at, id LIMIT 1`,
  ).bind(agent.id, agent.execution_config_hash, now.toISOString()).first<{ id: string }>();
  if (!candidate) return null;
  const leaseId = crypto.randomUUID();
  const expiresAt = new Date(now.getTime() + body.leaseSeconds * 1000).toISOString();
  const claimed = await db.prepare(
    `UPDATE agent_work_items SET state = 'leased', lease_id = ?2,
       lease_generation = lease_generation + 1, lease_expires_at = ?3,
       attempt_count = attempt_count + 1, github_run_id = ?4, updated_at = CURRENT_TIMESTAMP
     WHERE id = ?1 AND state IN ('queued', 'retryable')
     RETURNING *`,
  ).bind(candidate.id, leaseId, expiresAt, identity.githubRunId ?? null).first<Record<string, unknown>>();
  if (!claimed) return null;
  if (claimed.source_kind === "recipe-request") {
    await db.prepare(
      `UPDATE recipe_suggestion_requests SET status = 'running', work_item_id = ?2,
         updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status IN ('queued', 'running')`,
    ).bind(claimed.source_ref, claimed.id).run();
  }
  if (claimed.agent_id === "ingredient-price-researcher") {
    await db.prepare(
      `UPDATE ingredient_gaps SET status = 'researching', research_work_item_id = ?2,
         updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status IN ('pending', 'researching')`,
    ).bind(claimed.source_ref, claimed.id).run();
  }
  const inputHash = await digestHex(String(claimed.input_json));
  await db.prepare(
    `INSERT INTO agent_work_item_attempts
       (id, work_item_id, lease_id, lease_generation, github_run_id, status, input_hash, started_at)
     VALUES (?1, ?2, ?3, ?4, ?5, 'leased', ?6, ?7)`,
  ).bind(await deterministicId("agent-attempt", candidate.id, String(claimed.lease_generation)), candidate.id,
    leaseId, claimed.lease_generation, identity.githubRunId ?? null, inputHash, now.toISOString()).run();
  return { ...claimed, input: JSON.parse(String(claimed.input_json)), input_json: undefined, evaluationId: evaluation.id };
}

export function validateAgentOutput(contract: string, value: unknown, sourceRef: string, agentId: string): unknown {
  if (contract === "triage-plan-v1") {
    const plan = triagePlanSchema.parse(value);
    if (plan.triageId !== sourceRef) throw new Error("triage plan belongs to a different triage item");
    return plan;
  }
  if (contract === "pull-request-v1") {
    const proposal = pullRequestProposalSchema.parse(value);
    for (const file of proposal.files) {
      const normalized = file.path.replaceAll("\\", "/");
      if (normalized.startsWith("/") || normalized.includes("../") || normalized.startsWith(".github/workflows/") || /(^|\/)(\.env|\.dev\.vars|secrets?)(\/|$)/i.test(normalized)) throw new Error(`pull-request path is forbidden: ${file.path}`);
      if (agentId === "source-sentinel-investigator" && !(
        normalized === "platform/config/source-contracts.json"
        || normalized.startsWith("platform/apps/daily/src/source-contracts")
        || normalized.startsWith("platform/agents/evals/source-sentinel-investigator")
        || normalized.startsWith("grocery/tests/fixtures/")
      )) throw new Error(`source sentinel path is outside its allowlist: ${file.path}`);
    }
    return proposal;
  }
  if (contract === "accuracy-verdicts-v1") {
    const verdicts = accuracyVerdictsSchema.parse(value);
    if (verdicts.drawId !== sourceRef) throw new Error("accuracy verdicts belong to a different draw");
    return verdicts;
  }
  if (contract === "recipe-source-candidates-v2") {
    const candidates = recipeSourceCandidatesSchema.parse(value);
    if (candidates.requestId !== sourceRef) throw new Error("recipe source output belongs to a different request");
    return candidates;
  }
  if (contract === "recipe-hunt-leads-v1") {
    const result = recipeHuntResultsSchema.parse(value);
    if (result.requestId !== sourceRef) throw new Error("recipe hunt output belongs to a different request");
    return result;
  }
  if (contract === "recipe-hunt-dedup-v1") {
    const result = recipeHuntDedupSchema.parse(value);
    if (result.requestId !== sourceRef) throw new Error("recipe hunt dedup output belongs to a different request");
    return result;
  }
  if (contract === "recipe-source-facts-v3") {
    const result = recipeSourceFactsSchema.parse(value);
    if (result.requestId !== sourceRef) throw new Error("recipe source facts belong to a different request");
    return result;
  }
  if (contract === "recipe-dedup-v2") {
    const dedup = recipeDedupSchema.parse(value);
    if (dedup.requestId !== sourceRef) throw new Error("recipe dedup output belongs to a different request");
    return dedup;
  }
  if (contract === "recipe-map-v2") {
    const map = recipeMapSchema.parse(value);
    if (map.requestId !== sourceRef) throw new Error("recipe map output belongs to a different request");
    return map;
  }
  if (contract === "ingredient-price-research-v1") {
    const research = ingredientPriceResearchSchema.parse(value);
    if (research.gapId !== sourceRef) throw new Error("ingredient research belongs to a different gap");
    return research;
  }
  if (contract === "ingredient-definition-plan-v1") {
    const plan = ingredientDefinitionPlanSchema.parse(value);
    if (plan.batchId !== sourceRef) throw new Error("ingredient definition plan belongs to a different batch");
    return plan;
  }
  if (contract === "content-items-v2") return contentBatchItemsSchema.parse(value);
  if (contract === "content-audit-v1") return contentBatchAuditSchema.parse(value);
  throw new Error(`output contract ${contract} has no server validator`);
}

async function enqueueRecipeNext(db: D1Database, completed: Record<string, unknown>, output: unknown): Promise<string | undefined> {
  const nextAgentId = RECIPE_CHAIN[String(completed.agent_id)];
  if (!nextAgentId) return undefined;
  const next = await activeAgent(db, nextAgentId);
  if (nextAgentId === "recipe-fact-extractor") {
    const discovery = await db.prepare("SELECT request_id FROM ingredient_discovery_batches WHERE request_id = ?1")
      .bind(String(completed.source_ref)).first<{ request_id: string }>();
    if (discovery) {
      const dedup = recipeHuntDedupSchema.parse(output);
      const shardSize = 8;
      for (let offset = 0; offset < dedup.accepted.length; offset += shardSize) {
        const accepted = dedup.accepted.slice(offset, offset + shardSize);
        const candidateIds = new Set(accepted.map((candidate) => candidate.id));
        const shardOutput = { ...dedup, accepted,
          decisions: dedup.decisions.filter((decision) => candidateIds.has(decision.candidateId)) };
        const input = { contract: String(completed.output_contract), previousWorkItemId: completed.id,
          output: shardOutput, nextAgentId, nextPromptHash: next.prompt_sha256,
          shard: { index: Math.floor(offset / shardSize), size: accepted.length, total: dedup.accepted.length } };
        await enqueue(db, next, { sourceKind: "recipe-request", sourceRef: String(completed.source_ref),
          stage: "fact-extractor", severity: next.criticality, input }, String(completed.adapter_version), String(completed.output_contract));
      }
      return nextAgentId;
    }
  }
  const input: Record<string, unknown> = { contract: String(completed.output_contract), previousWorkItemId: completed.id, output, nextAgentId, nextPromptHash: next.prompt_sha256 };
  if (nextAgentId === "recipe-deduper") input.catalog = await currentRecipeCatalog(db);
  if (nextAgentId === "recipe-mapper") input.commodities = await currentCommodityCatalog(db);
  if (nextAgentId === "recipe-auditor" && String(completed.agent_id) === "recipe-writer") {
    input.lockedMap = object(JSON.parse(String(completed.input_json))).output;
  }
  await enqueue(db, next, {
    sourceKind: "recipe-request",
    sourceRef: String(completed.source_ref),
    stage: nextAgentId.replace("recipe-", ""),
    severity: next.criticality,
    input,
  }, String(completed.adapter_version), String(completed.output_contract));
  return nextAgentId;
}

export function assertRecipeChainContinuity(agentId: string, inputValue: unknown, outputValue: unknown): void {
  const input = object(inputValue);
  if (agentId === "recipe-deduper") {
    const sourced = recipeHuntResultsSchema.parse(input.output);
    const dedup = recipeHuntDedupSchema.parse(outputValue);
    const sourceIds = sourced.leads.map((candidate) => candidate.id).sort();
    const decisionIds = dedup.decisions.map((decision) => decision.candidateId).sort();
    if (stableJson(sourceIds) !== stableJson(decisionIds)) throw new Error("recipe deduper must return exactly one decision for every sourced candidate");
  }
  if (agentId === "recipe-fact-extractor") {
    const dedup = recipeHuntDedupSchema.parse(input.output);
    const facts = recipeSourceFactsSchema.parse(outputValue);
    const acceptedIds = dedup.accepted.map((candidate) => candidate.id).sort();
    const resolvedIds = [...facts.candidates.map((candidate) => candidate.id), ...facts.rejectedSources.map((item) => item.candidateId)].sort();
    if (stableJson(acceptedIds) !== stableJson(resolvedIds)) throw new Error("recipe fact extractor must resolve every accepted hunt lead exactly once");
  }
  if (agentId === "recipe-mapper") {
    const dedup = recipeSourceFactsSchema.parse(input.output);
    const map = recipeMapSchema.parse(outputValue);
    const acceptedIds = dedup.candidates.map((candidate) => candidate.id).sort();
    const mappedIds = map.recipes.map((recipe) => recipe.candidate.id).sort();
    if (stableJson(acceptedIds) !== stableJson(mappedIds)) throw new Error("recipe mapper must return exactly one mapping record for every accepted candidate");
  }
  if (agentId === "recipe-writer") {
    const map = recipeMapSchema.parse(input.output);
    const items = contentBatchItemsSchema.parse(outputValue);
    const readyIds = map.recipes.filter((recipe) => recipe.readyForWriting).map((recipe) => recipe.candidate.id).sort();
    const writtenIds = items.items.map((item) => item.sourceCandidateId).sort();
    if (stableJson(readyIds) !== stableJson(writtenIds)) throw new Error("recipe writer must return exactly one item for every ready mapped candidate");
    const mappedByCandidate = new Map(map.recipes.map((recipe) => [recipe.candidate.id, recipe]));
    for (const item of items.items) {
      const mapped = mappedByCandidate.get(item.sourceCandidateId);
      if (!mapped || stableJson(mapped.mealComponents) !== stableJson(item.mealComponents)) {
        throw new Error(`recipe writer must preserve meal components for ${item.sourceCandidateId}`);
      }
      const expectedIngredients = mapped.ingredients.filter((ingredient) => ingredient.decision !== "process")
        .map((ingredient) => ({ sourceLine: ingredient.sourceLine, commodityId: ingredient.commodityId, grams: ingredient.grams }));
      const actualIngredients = item.ingredients.map((ingredient) => ({ sourceLine: ingredient.sourceLine, commodityId: ingredient.commodityId, grams: ingredient.grams }));
      if (stableJson(expectedIngredients) !== stableJson(actualIngredients)) throw new Error(`deterministic recipe verification rejected ingredient drift for ${item.sourceCandidateId}`);
      if (!item.provenance.some((entry) => entry.url === mapped.candidate.sourceUrl && entry.accessedAt === mapped.candidate.accessedAt)) {
        throw new Error(`deterministic recipe verification rejected provenance drift for ${item.sourceCandidateId}`);
      }
    }
  }
}

async function persistRecipeIngredientGaps(db: D1Database, completed: Record<string, unknown>, outputValue: unknown): Promise<{ gapCount: number; discovery: boolean; collecting: boolean }> {
  const map = recipeMapSchema.parse(outputValue);
  const discovery = await db.prepare(
    "SELECT request_id FROM ingredient_discovery_batches WHERE request_id = ?1",
  ).bind(completed.source_ref).first<{ request_id: string }>();
  const gapIdsByName = new Map<string, string>();
  const rejectedAlternativeCandidates = new Set<string>();
  for (const recipe of map.recipes) {
    for (const ingredient of recipe.ingredients.filter((item) => item.decision === "unmapped")) {
      // The mapper has already removed quantities, preparation text, and optional
      // substitutions from sourceName. Re-parsing the raw source line can turn a
      // valid identity such as "coconut aminos" into "1 4 cup coconut aminos
      // may sub tamari" when the source uses Unicode fractions.
      const requirements = extractShoppingRequirements(ingredient.sourceName || ingredient.sourceLine);
      if (requirements.some((requirement) => requirement.role === "alternative")) {
        rejectedAlternativeCandidates.add(recipe.candidate.id);
        break;
      }
      for (const requirement of requirements.filter((item) => item.role === "purchased")) {
        if (!gapIdsByName.has(requirement.normalizedName)) gapIdsByName.set(requirement.normalizedName, await deterministicId("ingredient-gap", requirement.normalizedName));
      }
    }
  }
  for (const candidateId of rejectedAlternativeCandidates) {
    await db.prepare(
      `INSERT INTO pipeline_stage_events (campaign_id, lane, aggregate_kind, aggregate_id, stage, event_kind, detail_json)
       VALUES (?1, 'discovery', 'recipe_candidate', ?2, 'atomic-requirements', 'source_rejected', ?3)`,
    ).bind(completed.source_ref, candidateId, stableJson({ reason: "unresolved source ingredient alternative" })).run();
  }
  if (gapIdsByName.size === 0) {
    if (!discovery) return { gapCount: 0, discovery: false, collecting: false };
    const count = await db.prepare(
      "SELECT COUNT(DISTINCT gap_id) AS count FROM ingredient_gap_occurrences WHERE request_id = ?1",
    ).bind(completed.source_ref).first<{ count: number }>();
    const uniqueCount = Number(count?.count ?? 0);
    await db.prepare(
      `UPDATE ingredient_discovery_batches SET unique_missing_ingredients = ?2,
         source_round = source_round + 1, updated_at = CURRENT_TIMESTAMP WHERE request_id = ?1`,
    ).bind(completed.source_ref, uniqueCount).run();
    const campaign = await reconcileIngredientCampaign(db, String(completed.source_ref));
    const collecting = campaign?.state === "collecting";
    return { gapCount: 0, discovery: true, collecting };
  }
  const statements: D1PreparedStatement[] = [];
  // One canonical entity/identity version may be referenced by many recipe
  // occurrences. Emit those inserts once per persistence pass so differing
  // package expressions for the same normalized requirement cannot collide on
  // ingredient_entities.id or ingredient_identity_versions(entity_id, version).
  const emittedEntityIds = new Set<string>();
  for (const recipe of map.recipes) {
    if (rejectedAlternativeCandidates.has(recipe.candidate.id)) {
      continue;
    }
    const recipeGapIds: string[] = [];
    const occurrenceRequirements: Array<{ gapId: string; entityId: string; sourceIngredientIndex: number; splitComponentIndex: number; sourceLine: string; normalizedName: string }> = [];
    for (const [mappedIndex, ingredient] of recipe.ingredients.entries()) {
      if (ingredient.decision !== "unmapped") continue;
      const sourceIngredientIndex = ingredient.sourceIngredientIndex ?? mappedIndex;
      if (sourceIngredientIndex < 0) throw new Error(`unmapped ingredient is not pinned to a source occurrence: ${ingredient.sourceLine}`);
      const requirements = extractShoppingRequirements(ingredient.sourceName || ingredient.sourceLine);
      const selectedRequirements = ingredient.splitComponentIndex === undefined
        ? requirements
        : requirements.filter((item) => item.splitComponentIndex === ingredient.splitComponentIndex);
      for (const requirement of selectedRequirements.filter((item) => item.role === "purchased")) {
        const gapId = gapIdsByName.get(requirement.normalizedName);
        if (!gapId) continue;
        const entityId = `entity_${gapId}`;
        const identity = { baseProduct: requirement.normalizedName, forms: [], aliases: [requirement.normalizedName], exclusions: [],
          expectedUnitDimension: expectedUnitDimension(ingredient.sourceLine), resolverVersion: "atomic-source-v1" };
        const identityHash = await digestHex(stableJson(identity));
        const identityVersionId = await deterministicId("ingredient-identity-version", entityId, identityHash);
        recipeGapIds.push(gapId);
        occurrenceRequirements.push({ gapId, entityId, sourceIngredientIndex, splitComponentIndex: requirement.splitComponentIndex,
          sourceLine: ingredient.sourceLine, normalizedName: requirement.normalizedName });
        statements.push(db.prepare(
          `INSERT INTO ingredient_gaps (id, normalized_name, display_name)
           VALUES (?1, ?2, ?3) ON CONFLICT(normalized_name) DO NOTHING`,
        ).bind(gapId, requirement.normalizedName, requirement.displayName));
        if (!emittedEntityIds.has(entityId)) {
          emittedEntityIds.add(entityId);
          statements.push(db.prepare(
            `INSERT INTO ingredient_entities
               (id, market_id, canonical_name, identity_hash, identity_json, state)
             VALUES (?1, 'omaha', ?2, ?3, ?4, 'novel')
             ON CONFLICT DO NOTHING`,
          ).bind(entityId, requirement.displayName, identityHash, stableJson(identity)));
          statements.push(db.prepare(
            `INSERT INTO ingredient_identity_versions
               (id, entity_id, version, base_product, aliases_json, exclusions_json, expected_unit_dimension,
                identity_hash, resolver_version, verified_at)
             VALUES (?1, ?2, 1, ?3, ?4, '[]', ?5, ?6, 'atomic-source-v1', CURRENT_TIMESTAMP)
             ON CONFLICT DO NOTHING`,
          ).bind(identityVersionId, entityId, requirement.normalizedName, stableJson([requirement.normalizedName]), identity.expectedUnitDimension, identityHash));
        }
        statements.push(db.prepare(
          `INSERT INTO ingredient_aliases
             (market_id, normalized_alias, entity_id, resolution_source, confidence, evidence_hash)
           VALUES ('omaha', ?1, ?2, 'deterministic', 'exact', ?3)
           ON CONFLICT(market_id, normalized_alias) DO NOTHING`,
        ).bind(requirement.normalizedName, entityId, identityHash));
        statements.push(db.prepare(
          `INSERT INTO ingredient_gap_occurrences (gap_id, request_id, candidate_id, source_line, source_url)
           VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT DO NOTHING`,
        ).bind(gapId, completed.source_ref, recipe.candidate.id, ingredient.sourceLine, recipe.candidate.sourceUrl));
      }
    }
    const uniqueGapIds = [...new Set(recipeGapIds)].sort();
    if (uniqueGapIds.length > 0) {
      const holdId = await deterministicId("recipe-hold", String(completed.source_ref), String(completed.id), recipe.candidate.id);
      const locked = await db.prepare(
        `SELECT mapping.id AS mapping_id, mapping.source_fact_version_id
           FROM recipe_mapping_versions mapping
           JOIN recipe_source_fact_versions facts ON facts.id = mapping.source_fact_version_id
          WHERE facts.request_id = ?1 AND facts.candidate_id = ?2 AND mapping.verified_at IS NOT NULL
          ORDER BY mapping.created_at DESC, mapping.id DESC LIMIT 1`,
      ).bind(completed.source_ref, recipe.candidate.id).first<{ mapping_id: string; source_fact_version_id: string }>();
      if (!locked) throw new Error(`recipe hold ${recipe.candidate.id} is missing its immutable fact and mapping versions`);
      statements.push(db.prepare(
        `INSERT INTO recipe_ingredient_holds
           (id, request_id, mapper_work_item_id, candidate_id, candidate_json, gap_ids_json, discovery_only,
            source_fact_version_id, mapping_version_id)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
         ON CONFLICT(request_id, mapper_work_item_id, candidate_id) DO NOTHING`,
      ).bind(holdId, completed.source_ref, completed.id, recipe.candidate.id, stableJson(recipe.candidate), stableJson(uniqueGapIds), discovery ? 1 : 0,
        locked.source_fact_version_id, locked.mapping_id));
      for (const gapId of uniqueGapIds) {
        statements.push(db.prepare(
          `INSERT INTO recipe_hold_requirements (hold_id, gap_id, entity_id)
           VALUES (?1, ?2, ?3) ON CONFLICT(hold_id, gap_id) DO NOTHING`,
        ).bind(holdId, gapId, `entity_${gapId}`));
      }
      for (const occurrence of occurrenceRequirements) {
        statements.push(db.prepare(
          `INSERT INTO recipe_hold_requirement_occurrences
             (hold_id, source_ingredient_index, split_component_index, gap_id, entity_id, source_line, normalized_requirement, role)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'purchased')
           ON CONFLICT(hold_id, source_ingredient_index, split_component_index) DO NOTHING`,
        ).bind(holdId, occurrence.sourceIngredientIndex, occurrence.splitComponentIndex, occurrence.gapId, occurrence.entityId,
          occurrence.sourceLine, occurrence.normalizedName));
      }
    }
  }
  for (let offset = 0; offset < statements.length; offset += 90) await db.batch(statements.slice(offset, offset + 90));
  const candidateGapIds = [...new Set(gapIdsByName.values())].sort();
  const activeGaps = await db.prepare(
    `SELECT id FROM ingredient_gaps
      WHERE id IN (${candidateGapIds.map(() => "?").join(",")})
        AND status NOT IN ('published','permanently_unavailable')
        AND qa_resolution IS NULL
      ORDER BY id`,
  ).bind(...candidateGapIds).all<{ id: string }>();
  const activeGapIds = activeGaps.results.map((row) => row.id);
  if (activeGapIds.length > 0) {
    const waveId = await deterministicId("pricing-wave", String(completed.source_ref));
    const campaignTarget = discovery
      ? await db.prepare("SELECT target_published_ingredients FROM ingredient_discovery_batches WHERE request_id = ?1")
        .bind(completed.source_ref).first<{ target_published_ingredients: number }>()
      : null;
    await createPricingWave(db, {
      id: waveId,
      campaignId: String(completed.source_ref),
      sourceKind: "recipe",
      gapIds: activeGapIds,
      targetAvailable: Number(campaignTarget?.target_published_ingredients ?? Math.max(1, activeGapIds.length)),
      deadlineAt: null,
      inputHash: await digestHex(`ingredient-pricing-wave-v2\u001f${String(completed.source_ref)}`),
    });
  }
  if (!discovery) return { gapCount: gapIdsByName.size, discovery: false, collecting: false };
  const count = await db.prepare(
    "SELECT COUNT(DISTINCT gap_id) AS count FROM ingredient_gap_occurrences WHERE request_id = ?1",
  ).bind(completed.source_ref).first<{ count: number }>();
  const uniqueCount = Number(count?.count ?? 0);
  await db.prepare(
    `UPDATE ingredient_discovery_batches
        SET unique_missing_ingredients = ?2, source_round = source_round + 1,
            updated_at = CURRENT_TIMESTAMP WHERE request_id = ?1`,
  ).bind(completed.source_ref, uniqueCount).run();
  const campaign = await reconcileIngredientCampaign(db, String(completed.source_ref));
  const collecting = campaign?.state === "collecting";
  return { gapCount: gapIdsByName.size, discovery: true, collecting };
}

async function persistIngredientResearch(db: D1Database, outputValue: unknown): Promise<void> {
  const research = ingredientPriceResearchSchema.parse(outputValue);
  const status = research.disposition === "available"
    ? "ready_to_publish"
    : research.disposition === "permanently_unavailable" ? "permanently_unavailable" : "needs_operator";
  await db.prepare(
    `UPDATE ingredient_gaps SET status = ?2, commodity_id = ?3, research_json = ?4,
       updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND qa_resolution IS NULL
         AND status IN ('pending','researching','needs_operator')`,
  ).bind(research.gapId, status, research.commodityProposal?.id ?? null, stableJson(research)).run();
  const requests = await db.prepare(
    `SELECT DISTINCT occurrence.request_id FROM ingredient_gap_occurrences occurrence WHERE occurrence.gap_id = ?1`,
  ).bind(research.gapId).all<{ request_id: string }>();
  for (const request of requests.results) {
    const discovery = await db.prepare(
      "SELECT request_id FROM ingredient_discovery_batches WHERE request_id = ?1",
    ).bind(request.request_id).first();
    if (research.disposition === "permanently_unavailable" && !discovery) {
      await db.prepare("UPDATE recipe_suggestion_requests SET status = 'rejected', updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status <> 'promoted'").bind(request.request_id).run();
    }
    if (discovery) await reconcileIngredientCampaign(db, request.request_id);
  }
}

async function persistRecipeSourceFacts(env: Pick<WorkerEnv, "DB" | "EVIDENCE">, outputValue: unknown): Promise<unknown> {
  const facts = recipeSourceFactsSchema.parse(outputValue);
  const lockByCandidate = new Map(facts.factLocks.map((lock) => [lock.candidateId, lock]));
  const rejectedSources = [...facts.rejectedSources];
  const artifacts = (await Promise.all(facts.candidates.map(async (candidate) => {
    const sourceUrl = assertPublicRecipeSourceUrl(candidate.sourceUrl).toString();
    const response = await fetch(sourceUrl, { headers: { accept: "text/html,application/ld+json,application/json;q=0.9" }, redirect: "follow" });
    if (!response.ok) {
      const reason = `source artifact fetch returned HTTP ${response.status}`;
      rejectedSources.push({ candidateId: candidate.id, sourceUrl, reason });
      await env.DB.prepare(
        `INSERT INTO pipeline_stage_events
           (campaign_id, lane, aggregate_kind, aggregate_id, stage, event_kind, detail_json)
         VALUES (?1, 'discovery', 'recipe_candidate', ?2, 'source-artifact', 'source_rejected', ?3)`,
      ).bind(facts.requestId, candidate.id, stableJson({ sourceUrl, reason })).run();
      return null;
    }
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.byteLength < 1 || bytes.byteLength > 2_000_000) throw new Error(`source artifact size is invalid for ${candidate.id}`);
    const sha256 = await digestHex(bytes);
    const artifactId = await deterministicId("recipe-source-artifact", facts.requestId, candidate.id, sha256);
    const objectKey = `recipe-source-artifacts/${facts.requestId}/${candidate.id}/${sha256}`;
    const contentType = response.headers.get("content-type")?.slice(0, 200) || "text/html";
    await env.EVIDENCE.put(objectKey, bytes, { httpMetadata: { contentType }, customMetadata: { sha256, kind: "recipe-source-artifact" } });
    const stored = await env.EVIDENCE.head(objectKey);
    if (!stored || stored.size !== bytes.byteLength || stored.customMetadata?.sha256 !== sha256) throw new Error(`source artifact storage verification failed for ${candidate.id}`);
    return { candidate, sourceUrl, bytes, sha256, artifactId, objectKey, contentType, status: response.status };
  }))).filter((artifact): artifact is NonNullable<typeof artifact> => artifact !== null);
  const statements: D1PreparedStatement[] = [];
  const verifiedCandidateIds = new Set<string>();
  for (const artifact of artifacts) {
    const { candidate } = artifact;
    const lock = lockByCandidate.get(candidate.id);
    if (!lock) throw new Error(`missing fact lock for ${candidate.id}`);
    const factsJson = stableJson(candidate);
    const factsHash = await digestHex(factsJson);
    const id = await deterministicId("recipe-facts", facts.requestId, candidate.id, factsHash);
    const decision = decideRecipeFactsAgainstArtifact(candidate, new TextDecoder().decode(artifact.bytes));
    const { findings } = decision;
    if (!decision.accepted) {
      const { reason } = decision;
      rejectedSources.push({ candidateId: candidate.id, sourceUrl: artifact.sourceUrl, reason });
      await env.DB.prepare(
        `INSERT INTO pipeline_stage_events
           (campaign_id, lane, aggregate_kind, aggregate_id, stage, event_kind, detail_json)
         VALUES (?1, 'discovery', 'recipe_candidate', ?2, 'atomic-requirements', 'source_rejected', ?3)`,
      ).bind(facts.requestId, candidate.id, stableJson({ sourceUrl: artifact.sourceUrl, reason, findings })).run();
      continue;
    }
    verifiedCandidateIds.add(candidate.id);
    const verificationInputHash = await recipeFactVerificationHash({ artifactHash: artifact.sha256, factsHash });
    const verificationOutputHash = await recipeFactVerificationHash({ verdict: "verified", findings, verifierVersion: "artifact-containment-v1" });
    const verificationId = await deterministicId("recipe-fact-verification", id, verificationInputHash, verificationOutputHash);
    statements.push(env.DB.prepare(
      `INSERT INTO recipe_source_artifacts
         (id, request_id, candidate_id, source_url, object_key, sha256, byte_length, content_type, http_status, fetched_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, CURRENT_TIMESTAMP)
       ON CONFLICT(request_id, candidate_id, sha256) DO NOTHING`,
    ).bind(artifact.artifactId, facts.requestId, candidate.id, artifact.sourceUrl, artifact.objectKey, artifact.sha256,
      artifact.bytes.byteLength, artifact.contentType, artifact.status));
    statements.push(env.DB.prepare(
      `INSERT INTO recipe_source_fact_versions
         (id, request_id, candidate_id, source_url, accessed_at, artifact_key, artifact_hash, source_artifact_id,
          facts_json, facts_hash, verifier_version, verified_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'artifact-containment-v1', NULL)
       ON CONFLICT(request_id, candidate_id, facts_hash) DO NOTHING`,
    ).bind(id, facts.requestId, candidate.id, artifact.sourceUrl, candidate.accessedAt, artifact.objectKey, artifact.sha256,
      artifact.artifactId, factsJson, factsHash));
    statements.push(env.DB.prepare(
      `INSERT INTO recipe_fact_verifications
         (id, source_fact_version_id, source_artifact_id, verifier_version, input_hash, verdict, findings_json, output_hash)
       VALUES (?1, ?2, ?3, 'artifact-containment-v1', ?4, 'verified', ?5, ?6)
       ON CONFLICT(source_fact_version_id, input_hash, output_hash) DO NOTHING`,
    ).bind(verificationId, id, artifact.artifactId, verificationInputHash, stableJson(findings), verificationOutputHash));
    statements.push(env.DB.prepare(
      `UPDATE recipe_source_fact_versions SET fact_verification_id = ?2, verified_at = CURRENT_TIMESTAMP
        WHERE id = ?1 AND source_artifact_id = ?3 AND facts_hash = ?4`,
    ).bind(id, verificationId, artifact.artifactId, factsHash));
  }
  for (let offset = 0; offset < statements.length; offset += 90) await env.DB.batch(statements.slice(offset, offset + 90));
  return recipeSourceFactsSchema.parse({
    ...facts,
    candidates: facts.candidates.filter((candidate) => verifiedCandidateIds.has(candidate.id)),
    factLocks: facts.factLocks.filter((lock) => verifiedCandidateIds.has(lock.candidateId)),
    rejectedSources,
    extractionSummary: facts.extractionSummary,
  });
}

async function persistRecipeMappings(db: D1Database, outputValue: unknown): Promise<void> {
  const map = recipeMapSchema.parse(outputValue);
  const statements: D1PreparedStatement[] = [];
  for (const recipe of map.recipes) {
    const source = await db.prepare(
      `SELECT id FROM recipe_source_fact_versions
        WHERE request_id = ?1 AND candidate_id = ?2 AND verified_at IS NOT NULL
        ORDER BY created_at DESC, id DESC LIMIT 1`,
    ).bind(map.requestId, recipe.candidate.id).first<{ id: string }>();
    if (!source) throw new Error(`mapping ${recipe.candidate.id} is not pinned to a verified source-fact version`);
    const mappingJson = stableJson(recipe);
    const mappingHash = await digestHex(mappingJson);
    const id = await deterministicId("recipe-mapping", source.id, mappingHash);
    const findings = verifyRecipeMappingContinuity(recipe);
    if (findings.length > 0) throw new Error(`mapping verification rejected ${recipe.candidate.id}: ${findings.join(", ")}`);
    const verificationInputHash = await digestHex(stableJson({ sourceFactVersionId: source.id, mappingHash }));
    const verificationOutputHash = await digestHex(stableJson({ verdict: "verified", findings, verifierVersion: "mapping-continuity-v1" }));
    const verificationId = await deterministicId("recipe-mapping-verification", id, verificationInputHash, verificationOutputHash);
    statements.push(db.prepare(
      `INSERT INTO recipe_mapping_versions
         (id, source_fact_version_id, mapping_json, mapping_hash, mapper_version, verified_at)
       VALUES (?1, ?2, ?3, ?4, 'recipe-map-v2', NULL)
       ON CONFLICT(source_fact_version_id, mapping_hash) DO NOTHING`,
    ).bind(id, source.id, mappingJson, mappingHash));
    statements.push(db.prepare(
      `INSERT INTO recipe_mapping_verifications
         (id, mapping_version_id, verifier_version, input_hash, verdict, findings_json, output_hash)
       VALUES (?1, ?2, 'mapping-continuity-v1', ?3, 'verified', ?4, ?5)
       ON CONFLICT(mapping_version_id, input_hash, output_hash) DO NOTHING`,
    ).bind(verificationId, id, verificationInputHash, stableJson(findings), verificationOutputHash));
    statements.push(db.prepare(
      `UPDATE recipe_mapping_versions SET mapping_verification_id = ?2, verified_at = CURRENT_TIMESTAMP WHERE id = ?1`,
    ).bind(id, verificationId));
  }
  for (let offset = 0; offset < statements.length; offset += 90) await db.batch(statements.slice(offset, offset + 90));
}

export async function enqueueIngredientDefinitionPlan(db: D1Database, limit = 50): Promise<{ queued: boolean; batchId: string | null; count: number }> {
  const rows = await db.prepare(
    `SELECT job.id AS pricing_job_id, job.gap_id, gap.display_name, gap.normalized_name,
            job.resolution_version_id
       FROM ingredient_pricing_jobs job JOIN ingredient_gaps gap ON gap.id = job.gap_id
      WHERE job.state IN ('store_checks_running','ready_to_publish')
        AND job.commodity_proposal_json IS NULL
        AND NOT EXISTS (SELECT 1 FROM agent_work_items work WHERE work.agent_id = 'ingredient-definition-planner'
          AND work.state IN ('queued','leased','retryable') AND json_extract(work.input_json, '$.pricingJobIds') LIKE '%' || job.id || '%')
      ORDER BY job.updated_at, job.id LIMIT ?1`,
  ).bind(Math.min(50, Math.max(1, limit))).all<Record<string, unknown>>();
  if (rows.results.length === 0) return { queued: false, batchId: null, count: 0 };
  const pricingJobIds = rows.results.map((row) => String(row.pricing_job_id)).sort();
  const batchId = await deterministicId("ingredient-definition-plan", ...pricingJobIds);
  const agent = await activeAgent(db, "ingredient-definition-planner");
  const categories = await db.prepare(activeIngredientCategoryContextSql).all<{ id: string; label: string }>();
  await enqueue(db, agent, {
    sourceKind: "recipe-request",
    sourceRef: batchId,
    stage: "definition-plan",
    severity: agent.criticality,
    input: { batchId, pricingJobIds, ingredients: rows.results, categories: categories.results,
      constraints: { exactIdentityOnly: true, noBrandSpecificMatchers: true, oneExistingCategoryRequired: true } },
  }, "ingredient-definition-plan-v1", "ingredient-definition-plan-v1");
  return { queued: true, batchId, count: rows.results.length };
}

export function assertRetailerTolerantIngredientDefinition(proposal: { id: string; include: string[] }): void {
  for (const pattern of proposal.include) {
    const trimmed = pattern.trim();
    if (trimmed.startsWith("^") && trimmed.endsWith("$")) {
      throw new Error(`ingredient definition ${proposal.id} uses a whole-title anchored include that cannot match ordinary branded retailer product names`);
    }
  }
}

async function persistIngredientDefinitionPlan(db: D1Database, outputValue: unknown): Promise<void> {
  const plan = ingredientDefinitionPlanSchema.parse(outputValue);
  const statements: D1PreparedStatement[] = [];
  for (const item of plan.items) {
    assertRetailerTolerantIngredientDefinition(item.proposal);
    const proposalJson = stableJson(item.proposal);
    const proposalHash = await digestHex(proposalJson);
    const canonicalTerm = item.proposal.searchTerms[0]!;
    const aliases = item.proposal.searchTerms.slice(1);
    const queryPlanHash = await digestHex(stableJson({ canonicalTerm, aliases, exclusions: item.proposal.exclude,
      basisUnit: item.proposal.unit, commodityId: item.proposal.id, version: 2 }));
    statements.push(db.prepare(
      `UPDATE ingredient_pricing_jobs SET commodity_proposal_json = ?2, commodity_proposal_hash = ?3,
         operational_state = CASE WHEN state = 'store_checks_running' THEN 'store_checks_running' ELSE operational_state END,
         semantic_plan_hash = ?5, last_progress_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
        WHERE id = ?1 AND gap_id = ?4 AND state IN ('store_checks_running','ready_to_publish')`,
    ).bind(item.pricingJobId, proposalJson, proposalHash, item.gapId, queryPlanHash));
    statements.push(db.prepare(
      `UPDATE ingredient_query_plans SET version = 2, canonical_term = ?2, aliases_json = ?3,
         exclusions_json = ?4, plan_hash = ?5, planner_version = 'ingredient-definition-planner-v2'
        WHERE pricing_job_id = ?1`,
    ).bind(item.pricingJobId, canonicalTerm, stableJson(aliases), stableJson(item.proposal.exclude), queryPlanHash));
    statements.push(db.prepare(
      `UPDATE ingredient_store_checks SET query_plan_hash = ?2, last_progress_at = CURRENT_TIMESTAMP,
         operational_state = CASE WHEN state IN ('queued','targeted_refresh','transient_failed','evidence_expired') THEN 'capture_queued' ELSE operational_state END,
         updated_at = CURRENT_TIMESTAMP WHERE pricing_job_id = ?1`,
    ).bind(item.pricingJobId, queryPlanHash));
    statements.push(db.prepare(
      `UPDATE ingredient_resolution_versions SET commodity_proposal_hash = ?2
        WHERE id = (SELECT resolution_version_id FROM ingredient_pricing_jobs WHERE id = ?1)`,
    ).bind(item.pricingJobId, proposalHash));
  }
  if (statements.length) await db.batch(statements);
}

export function recipeTerminalReason(agentId: string, outputValue: unknown): string | undefined {
  if (agentId === "recipe-sourcer" && recipeHuntResultsSchema.parse(outputValue).leads.length === 0) return "no accessible source leads";
  if (agentId === "recipe-deduper" && recipeHuntDedupSchema.parse(outputValue).accepted.length === 0) return "all recipe leads were rejected or deduplicated";
  if (agentId === "recipe-fact-extractor" && recipeSourceFactsSchema.parse(outputValue).candidates.length === 0) return "no accepted recipe lead had complete exact source facts";
  if (agentId === "recipe-mapper" && recipeMapSchema.parse(outputValue).recipes.every((recipe) => !recipe.readyForWriting)) return "no candidate could be mapped and scaled safely";
  return undefined;
}

async function stageAuditedRecipeBatch(db: D1Database, completed: Record<string, unknown>, auditValue: unknown): Promise<{ contentBatchId: string; status: string }> {
  const input = JSON.parse(String(completed.input_json)) as { output?: unknown; nextPromptHash?: string };
  const itemsDocument = contentBatchItemsSchema.parse(input.output);
  const audit = contentBatchAuditSchema.parse(auditValue);
  if (audit.auditorAgentId !== "recipe-auditor" || audit.promptHash !== input.nextPromptHash) throw new Error("recipe audit identity or prompt hash does not match the active chain input");
  const commodities = await currentCommodityCatalog(db);
  const deterministicGuard = await evaluateContentPromotion(itemsDocument.items, new Set(commodities.map((commodity) => String(commodity.id))));
  const combinedFindings = [
    ...audit.findings,
    ...deterministicGuard.findings.map((finding) => ({
      key: `deterministic:${finding.key}`,
      severity: finding.severity,
      message: finding.message,
      ...(finding.itemSlug ? { itemSlug: finding.itemSlug } : {}),
    })),
  ];
  const findings = combinedFindings.slice(0, 1000);
  const inputHash = await digestHex(stableJson(input));
  const contentHash = deterministicGuard.contentHash;
  const batchId = await deterministicId("content", "recipe-pack", String(completed.source_ref), contentHash);
  await db.prepare(
    `INSERT INTO content_batches
       (id, kind, status, input_hash, prompt_hash, source_refs_json, created_by, content_hash)
     VALUES (?1, 'recipe-pack', 'staging', ?2, ?3, ?4, 'recipe-writer', ?5)
     ON CONFLICT(id) DO NOTHING`,
  ).bind(batchId, inputHash, audit.promptHash, stableJson([`recipe-request://${String(completed.source_ref)}`]), contentHash).run();
  const itemStatements = await Promise.all(itemsDocument.items.map(async (item, ordinal) => db.prepare(
    `INSERT INTO content_batch_items (batch_id, slug, ordinal, content_json, content_hash)
     VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT(batch_id, slug) DO NOTHING`,
  ).bind(batchId, item.slug, ordinal, stableJson(item), await digestHex(stableJson(item)))));
  for (let offset = 0; offset < itemStatements.length; offset += 90) await db.batch(itemStatements.slice(offset, offset + 90));
  const hardFindings = combinedFindings.filter((finding) => finding.severity === "hard").length;
  const warningFindings = combinedFindings.filter((finding) => finding.severity === "warning").length;
  const auditId = await deterministicId("content-audit", batchId, audit.promptHash);
  const status = hardFindings > 0 ? "rejected" : "audited";
  await db.batch([
    db.prepare(
      `INSERT INTO content_batch_audits
         (id, batch_id, auditor_agent_id, prompt_hash, findings_json, hard_findings, warning_findings)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT(id) DO NOTHING`,
    ).bind(auditId, batchId, audit.auditorAgentId, audit.promptHash, stableJson(findings), hardFindings, warningFindings),
    db.prepare("UPDATE content_batches SET status = ?2, sealed_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status = 'staging'").bind(batchId, status),
    db.prepare("UPDATE recipe_suggestion_requests SET status = ?2, content_batch_id = ?3, updated_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(completed.source_ref, status === "audited" ? "staged" : "rejected", batchId),
  ]);
  return { contentBatchId: batchId, status };
}

export async function completeAgentWorkItem(env: Pick<WorkerEnv, "DB" | "EVIDENCE">, identity: MutationIdentity, workItemId: string, body: AgentWorkItemComplete): Promise<Record<string, unknown>> {
  const db = env.DB;
  const current = await db.prepare("SELECT * FROM agent_work_items WHERE id = ?1").bind(workItemId).first<Record<string, unknown>>();
  if (!current) throw new Error("work item not found");
  if (identity.registeredAgentId !== current.agent_id) throw new Error("an agent may only complete its own work");
  if (current.state === "completed" && current.lease_id === body.leaseId && Number(current.lease_generation) === body.leaseGeneration) return { idempotent: true, workItemId, state: "completed" };
  let output = validateAgentOutput(String(current.output_contract), body.output, String(current.source_ref), String(current.agent_id));
  if (String(current.agent_id).startsWith("recipe-")) assertRecipeChainContinuity(String(current.agent_id), JSON.parse(String(current.input_json)), output);
  // Fact verification is an acceptance gate, not a post-completion side effect.
  // Persisting it first is safe to replay because artifacts and fact versions are
  // content-addressed. A rejection therefore leaves the lease open so the normal
  // failure path can retry or source a replacement instead of stranding a
  // completed work item with no verified facts.
  const recipeFactsPersisted = current.agent_id === "recipe-fact-extractor";
  if (recipeFactsPersisted) output = await persistRecipeSourceFacts(env, output);
  // Mapping persistence is also an acceptance gate. It creates the durable
  // Lane A -> Lane B handoff, so it must succeed before the lease is marked
  // completed. Every write in these helpers is deterministic/idempotent and is
  // therefore safe to replay after a partial D1 batch.
  const recipeMappingsPersisted = current.agent_id === "recipe-mapper";
  let persistedMapperGapResult: Awaited<ReturnType<typeof persistRecipeIngredientGaps>> | undefined;
  if (recipeMappingsPersisted) {
    await persistRecipeMappings(db, output);
    persistedMapperGapResult = await persistRecipeIngredientGaps(db, current, output);
  }
  const outputJson = stableJson(output);
  const outputHash = await digestHex(outputJson);
  const finishedAt = new Date().toISOString();
  const update = await db.prepare(
    `UPDATE agent_work_items SET state = 'completed', output_json = ?5, completed_at = ?6,
       updated_at = CURRENT_TIMESTAMP
     WHERE id = ?1 AND agent_id = ?2 AND state = 'leased' AND lease_id = ?3
       AND lease_generation = ?4 AND lease_expires_at > ?6`,
  ).bind(workItemId, identity.registeredAgentId, body.leaseId, body.leaseGeneration, outputJson, finishedAt).run();
  if ((update.meta.changes ?? 0) !== 1) {
    await db.prepare(
      `UPDATE agent_work_item_attempts SET status = 'late-discarded', output_hash = ?4,
         detail_json = ?5, finished_at = ?6
       WHERE work_item_id = ?1 AND lease_id = ?2 AND lease_generation = ?3`,
    ).bind(workItemId, body.leaseId, body.leaseGeneration, outputHash, stableJson({ reason: "lease fence rejected completion" }), finishedAt).run();
    throw new Error("completion was discarded because the lease is stale or expired");
  }
  await db.prepare(
    `UPDATE agent_work_item_attempts SET status = 'completed', output_hash = ?4, finished_at = ?5
     WHERE work_item_id = ?1 AND lease_id = ?2 AND lease_generation = ?3`,
  ).bind(workItemId, body.leaseId, body.leaseGeneration, outputHash, finishedAt).run();
  let nextAgentId: string | undefined;
  let contentBatch: { contentBatchId: string; status: string } | undefined;
  if (current.agent_id === "triage-reviewer") {
    await db.prepare(
      `UPDATE triage_items SET status = 'planned', plan_ref = ?2, resolution_json = ?3,
         updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status = 'open'`,
    ).bind(current.source_ref, `agent-work://${workItemId}`, outputJson).run();
    nextAgentId = "triage-developer";
  }
  if (current.agent_id === "triage-developer") {
    const proposal = pullRequestProposalSchema.parse(output);
    if (proposal.requiresOperator) {
      await db.prepare(
        `UPDATE triage_items SET status = 'needs_operator', resolution_json = ?2,
           updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status = 'planned'`,
      ).bind(current.source_ref, outputJson).run();
    }
  }
  let recipeTerminal: { status: "rejected"; reason: string } | undefined;
  if (current.agent_id === "ingredient-price-researcher") {
    await persistIngredientResearch(db, output);
    await db.prepare(
      `INSERT INTO pipeline_stage_events
         (campaign_id, lane, aggregate_kind, aggregate_id, stage, event_kind, detail_json)
       VALUES (NULL, 'pricing', 'ingredient_gap', ?1, 'legacy-model-research', 'forensic_only', ?2)`,
    ).bind(current.source_ref, stableJson({ workItemId, outputHash, authority: false })).run();
  } else if (current.agent_id === "ingredient-definition-planner") {
    const expected = array(object(JSON.parse(String(current.input_json))).ingredients).map((row) => String(row.pricing_job_id)).sort();
    const actual = ingredientDefinitionPlanSchema.parse(output).items.map((item) => item.pricingJobId).sort();
    if (stableJson(expected) !== stableJson(actual)) throw new Error("ingredient definition planner must return exactly one proposal for every batched pricing job");
    await persistIngredientDefinitionPlan(db, output);
  } else if (current.agent_id === "recipe-auditor") contentBatch = await stageAuditedRecipeBatch(db, current, output);
  else if (String(current.agent_id).startsWith("recipe-")) {
    if (current.agent_id === "recipe-writer") {
      const writerInput = object(JSON.parse(String(current.input_json)));
      const dependencyRoot = String(writerInput.dependencyRoot ?? await digestHex(stableJson(writerInput.output)));
      const verifierInputHash = await digestHex(stableJson({ dependencyRoot, lockedMap: writerInput.output }));
      const verificationId = await deterministicId("recipe-write-verification", workItemId, verifierInputHash, outputHash);
      await db.batch([
        db.prepare(`INSERT INTO recipe_write_verification_versions
          (id, request_id, writer_work_item_id, dependency_root_hash, input_hash, output_hash, verifier_version, verdict, findings_json)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'locked-facts-v2', 'verified', '[]')
          ON CONFLICT(writer_work_item_id, input_hash, output_hash) DO NOTHING`)
          .bind(verificationId, current.source_ref, workItemId, dependencyRoot, verifierInputHash, outputHash),
        db.prepare(
          `INSERT INTO pipeline_stage_events (campaign_id, lane, aggregate_kind, aggregate_id, stage, event_kind, detail_json)
           VALUES (?1, 'recipe', 'recipe_request', ?1, 'deterministic-verify', 'passed', ?2)`,
        ).bind(current.source_ref, stableJson({ workItemId, outputHash, verificationId, dependencyRoot, verifierVersion: "locked-facts-v2" })),
      ]);
    }
    if (current.agent_id === "recipe-fact-extractor" && !recipeFactsPersisted) await persistRecipeSourceFacts(env, output);
    if (current.agent_id === "recipe-mapper" && !recipeMappingsPersisted) await persistRecipeMappings(db, output);
    const gapResult = current.agent_id === "recipe-mapper"
      ? persistedMapperGapResult ?? await persistRecipeIngredientGaps(db, current, output)
      : { gapCount: 0, discovery: false, collecting: false };
    const reason = gapResult.gapCount > 0 ? undefined : recipeTerminalReason(String(current.agent_id), output);
    if (reason) {
      const discovery = await db.prepare(
        "SELECT request_id FROM ingredient_discovery_batches WHERE request_id = ?1 AND state = 'collecting'",
      ).bind(current.source_ref).first();
      if (discovery && (current.agent_id === "recipe-sourcer" || current.agent_id === "recipe-deduper" || current.agent_id === "recipe-fact-extractor")) {
        await db.batch([
          db.prepare("UPDATE ingredient_discovery_batches SET source_round = source_round + 1, updated_at = CURRENT_TIMESTAMP WHERE request_id = ?1").bind(current.source_ref),
          db.prepare("UPDATE recipe_suggestion_requests SET status = 'queued', updated_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(current.source_ref),
        ]);
      } else {
        await db.prepare("UPDATE recipe_suggestion_requests SET status = 'rejected', updated_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(current.source_ref).run();
        recipeTerminal = { status: "rejected", reason };
      }
    } else if (!gapResult.discovery) {
      const hasReadyRecipe = current.agent_id !== "recipe-mapper" || recipeMapSchema.parse(output).recipes.some((recipe) => recipe.readyForWriting);
      if (hasReadyRecipe) nextAgentId = await enqueueRecipeNext(db, current, output);
    }
  }
  return { idempotent: false, workItemId, state: "completed", outputHash, nextAgentId: nextAgentId ?? null, contentBatch: contentBatch ?? null, recipeTerminal: recipeTerminal ?? null };
}

export async function failAgentWorkItem(db: D1Database, identity: MutationIdentity, workItemId: string, body: AgentWorkItemFail): Promise<Record<string, unknown>> {
  const current = await db.prepare("SELECT * FROM agent_work_items WHERE id = ?1").bind(workItemId).first<Record<string, unknown>>();
  if (!current) throw new Error("work item not found");
  if (identity.registeredAgentId !== current.agent_id) throw new Error("an agent may only fail its own work");
  const retry = body.retryable && Number(current.attempt_count) < Number(current.max_attempts);
  const state = retry ? "retryable" : "deadletter";
  const finishedAt = new Date().toISOString();
  const delaySeconds = Math.min(3600, 60 * 2 ** Math.max(0, Number(current.attempt_count) - 1));
  const availableAt = new Date(Date.now() + delaySeconds * 1000).toISOString();
  const update = await db.prepare(
    `UPDATE agent_work_items SET state = ?5, last_error = ?6, available_at = ?7,
       lease_id = NULL, lease_expires_at = NULL, updated_at = CURRENT_TIMESTAMP
     WHERE id = ?1 AND agent_id = ?2 AND state = 'leased' AND lease_id = ?3 AND lease_generation = ?4`,
  ).bind(workItemId, identity.registeredAgentId, body.leaseId, body.leaseGeneration, state, body.reason, availableAt).run();
  if ((update.meta.changes ?? 0) !== 1) throw new Error("failure was discarded because the lease is stale");
  await db.prepare(
    `UPDATE agent_work_item_attempts SET status = 'failed', detail_json = ?4, finished_at = ?5
     WHERE work_item_id = ?1 AND lease_id = ?2 AND lease_generation = ?3`,
  ).bind(workItemId, body.leaseId, body.leaseGeneration, stableJson({ reason: body.reason, retryable: retry }), finishedAt).run();
  if (current.agent_id === "ingredient-price-researcher" && !retry) {
    await db.prepare(
      `UPDATE ingredient_gaps SET status = 'needs_operator', publication_error = ?2,
         updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status = 'researching'`,
    ).bind(current.source_ref, body.reason).run();
    await db.prepare(
      `UPDATE ingredient_pricing_jobs SET state = 'needs_operator', updated_at = CURRENT_TIMESTAMP
        WHERE gap_id = ?1 AND state = 'store_checks_running'`,
    ).bind(current.source_ref).run();
    const campaigns = await db.prepare(
      "SELECT DISTINCT request_id FROM ingredient_gap_occurrences WHERE gap_id = ?1",
    ).bind(current.source_ref).all<{ request_id: string }>();
    for (const campaign of campaigns.results) await reconcileIngredientCampaign(db, campaign.request_id);
  }
  if (!retry && ["recipe-sourcer", "recipe-deduper", "recipe-fact-extractor"].includes(String(current.agent_id))) {
    const discovery = await db.prepare(
      `SELECT request_id FROM ingredient_discovery_batches
        WHERE request_id = ?1 AND state = 'collecting' AND paused_at IS NULL AND discovery_frozen_at IS NULL`,
    ).bind(current.source_ref).first<{ request_id: string }>();
    if (discovery) {
      await db.prepare(
        "UPDATE ingredient_discovery_batches SET source_round = source_round + 1, updated_at = CURRENT_TIMESTAMP WHERE request_id = ?1",
      ).bind(current.source_ref).run();
      await reconcileIngredientCampaign(db, String(current.source_ref));
    }
  }
  return { workItemId, state, retryAt: retry ? availableAt : null };
}
