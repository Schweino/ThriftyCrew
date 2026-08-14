import { OMAHA_STORE_LOCATION_IDS } from "@thriftycrew/contracts";
import { deterministicId, digestHex, normalizeName, stableJson } from "@thriftycrew/domain";
import { createCatalogIngredientVersion } from "./dynamic-ingredient-catalog";
import { claimPipelineAgentWork } from "./store-catalog-generations";
import omahaStorePolicies from "../../../config/omaha-store-policies.json";

type LegacyStoreRow = { storeLocationId?: string; observationId?: string; [key: string]: unknown };
type LegacyCommodity = { id?: string; label?: string; unit?: string; stores?: LegacyStoreRow[]; [key: string]: unknown };
type LegacyBoard = { commodities?: LegacyCommodity[] };

const AGENT_BY_STORE: Record<string, string> = {
  "aldi-omaha-446-048": "omaha-price-producer-aldi",
  "bakers-saddle-creek": "omaha-price-producer-bakers",
  "family-fare-omaha-6401": "omaha-price-producer-family-fare",
  "fareway-omaha-043": "omaha-price-producer-fareway",
  "hy-vee-omaha-1465": "omaha-price-producer-hy-vee",
  "sams-omaha": "omaha-price-producer-sams-club",
  "walmart-omaha": "omaha-price-producer-walmart",
};
const VERIFIER_BY_STORE = Object.fromEntries(Object.entries(AGENT_BY_STORE).map(([store, agent]) =>
  [store, agent.replace("price-producer", "price-verifier")])) as Record<string, string>;
type StoreCapturePolicy = { storeLocationId: string; sourceId: string; firstPartyHost: string; priceMode: string;
  retailerLocationKey: string; priceLocationKey: string; exactAddress: string;
  locationCanary: { expectedLocationPattern: string; expectedModePattern: string }; evidenceFreshnessMinutes: number };
const CAPTURE_POLICY_BY_STORE = Object.fromEntries((omahaStorePolicies.stores as StoreCapturePolicy[])
  .map((policy) => [policy.storeLocationId, policy])) as Record<string, StoreCapturePolicy>;

function adapterNameForPolicy(policy: StoreCapturePolicy): string {
  return policy.sourceId.replace(/^direct-/, "").replace(/-(?:browser|headless)$/, "");
}

function unitDimension(unit: string): "weight" | "volume" | "count" | "other" {
  const normalized = unit.toLowerCase();
  if (/^(?:lb|oz|kg|g)$/.test(normalized)) return "weight";
  if (/^(?:fl oz|ml|l|gal|qt|pt|cup)$/.test(normalized)) return "volume";
  if (/^(?:ea|each|ct|count)$/.test(normalized)) return "count";
  return "other";
}

export function assertLegacyBoard(boardValue: unknown): LegacyCommodity[] {
  const board = boardValue as LegacyBoard;
  if (!Array.isArray(board?.commodities) || board.commodities.length === 0) throw new Error("legacy board has no commodities");
  const commodities = [...board.commodities].sort((a, b) => String(a.id).localeCompare(String(b.id)));
  if (commodities.some((row) => !row.id || !row.label || !row.unit)) throw new Error("legacy board commodity identity is incomplete");
  if (new Set(commodities.map((row) => row.id)).size !== commodities.length) throw new Error("legacy board contains duplicate commodity ids");
  return commodities;
}

export async function initializeCatalogBackfill(db: D1Database, input: { releaseId: string; boardHash: string; boardObjectKey: string; board: unknown }) {
  const commodities = assertLegacyBoard(input.board);
  const runId = await deterministicId("catalog-backfill-v4", input.releaseId, input.boardHash);
  await db.prepare(`INSERT INTO catalog_backfill_runs_v4
      (run_id,source_release_id,source_board_hash,source_board_object_key,state,commodity_count,expected_cell_count)
    VALUES(?1,?2,?3,?4,'staging',?5,?6)
    ON CONFLICT(source_release_id) DO NOTHING`).bind(runId, input.releaseId, input.boardHash,
      input.boardObjectKey, commodities.length, commodities.length * OMAHA_STORE_LOCATION_IDS.length).run();
  const current = await db.prepare("SELECT run_id,source_board_hash,source_board_object_key,commodity_count FROM catalog_backfill_runs_v4 WHERE source_release_id=?1")
    .bind(input.releaseId).first<{ run_id: string; source_board_hash: string; source_board_object_key: string; commodity_count: number }>();
  if (!current || current.run_id !== runId || current.source_board_hash !== input.boardHash || Number(current.commodity_count) !== commodities.length) {
    throw new Error("legacy backfill source release changed after initialization");
  }
  if (current.source_board_object_key !== input.boardObjectKey) throw new Error("legacy backfill immutable source object changed after initialization");
  return { runId, commodityCount: commodities.length, expectedCellCount: commodities.length * OMAHA_STORE_LOCATION_IDS.length };
}

export async function importCatalogBackfillPage(db: D1Database, input: {
  releaseId: string; boardHash: string; boardObjectKey: string; board: unknown; offset: number; limit: number;
}) {
  const commodities = assertLegacyBoard(input.board);
  const run = await initializeCatalogBackfill(db, input);
  const page = commodities.slice(Math.max(0, input.offset), Math.max(0, input.offset) + Math.min(50, Math.max(1, input.limit)));
  let pricedRecovered = 0;
  let legacyUnknown = 0;
  let enqueued = 0;
  for (const commodity of page) {
    const commodityId = String(commodity.id);
    const label = String(commodity.label).trim();
    const basisUnit = String(commodity.unit).trim();
    const identityJson = stableJson({ source: "legacy-board-v2", marketId: "omaha", commodityId, label, basisUnit });
    const identityHash = await digestHex(identityJson);
    const ingredientId = await deterministicId("legacy-catalog-ingredient", "omaha", commodityId);
    await db.prepare(`INSERT INTO ingredient_entities(id,market_id,canonical_name,identity_hash,identity_json,state,commodity_id)
      VALUES(?1,'omaha',?2,?3,?4,'existing_commodity',?5)
      ON CONFLICT(id) DO NOTHING`).bind(ingredientId, label, identityHash, identityJson, commodityId).run();
    const entity = await db.prepare("SELECT commodity_id,identity_hash FROM ingredient_entities WHERE id=?1")
      .bind(ingredientId).first<{ commodity_id: string; identity_hash: string }>();
    if (!entity || entity.commodity_id !== commodityId || entity.identity_hash !== identityHash) throw new Error(`legacy ingredient identity conflict for ${commodityId}`);
    const pointer = await db.prepare("SELECT pointer_generation FROM catalog_ingredient_current WHERE ingredient_id=?1")
      .bind(ingredientId).first<{ pointer_generation: number }>();
    const definition = await createCatalogIngredientVersion(db, {
      ingredientId, slug: commodityId, sourceGapId: null, expectedPointerGeneration: Number(pointer?.pointer_generation ?? 0),
      identity: { canonicalName: label, displayName: label, aliases: [], acceptedForms: [label], excludedForms: [],
        requiredQualifiers: [], optionalQualifiers: [], unitDimension: unitDimension(basisUnit), basisUnit,
        packageNormalizationRules: [`legacy board basis unit: ${basisUnit}`], queryTerms: [label], storeQueryVariants: {},
        sourceOccurrences: [{ recipeCandidateId: `legacy-board:${input.releaseId}`, sourceOccurrenceId: commodityId }],
        plannerRunId: `legacy-board-backfill:${input.releaseId}`, adjudication: null },
    });
    const semanticJson = stableJson(commodity);
    const semanticHash = await digestHex(semanticJson);
    await db.prepare(`INSERT INTO catalog_backfill_ingredients_v4
      (run_id,commodity_id,ingredient_id,definition_version_id,legacy_semantic_json,legacy_semantic_hash,semantic_state)
      VALUES(?1,?2,?3,?4,?5,?6,'staged') ON CONFLICT(run_id,commodity_id) DO NOTHING`)
      .bind(run.runId, commodityId, ingredientId, definition.versionId, semanticJson, semanticHash).run();
    const legacyByStore = new Map((commodity.stores ?? []).map((row) => [String(row.storeLocationId), row]));
    for (const storeLocationId of OMAHA_STORE_LOCATION_IDS) {
      const legacyRow = legacyByStore.get(storeLocationId);
      let observationId: string | null = null;
      let rowJson: string | null = null;
      let rowHash: string | null = null;
      let semanticState: "priced_provenance_recovered" | "legacy_unknown" = "legacy_unknown";
      if (legacyRow?.observationId) {
        const cell = await db.prepare(`SELECT cell.observation_id FROM release_cells cell JOIN observations observation ON observation.id=cell.observation_id
          WHERE cell.release_id=?1 AND cell.commodity_id=?2 AND cell.store_location_id=?3 AND cell.status='priced' AND cell.observation_id=?4`)
          .bind(input.releaseId, commodityId, storeLocationId, legacyRow.observationId).first<{ observation_id: string }>();
        if (cell) {
          observationId = cell.observation_id;
          rowJson = stableJson(legacyRow);
          rowHash = await digestHex(rowJson);
          semanticState = "priced_provenance_recovered";
          pricedRecovered += 1;
        } else legacyUnknown += 1;
      } else legacyUnknown += 1;
      const agentId = AGENT_BY_STORE[storeLocationId];
      const dedupeKey = `catalog-backfill:${ingredientId}:${storeLocationId}:${definition.versionId}:producer`;
      const workId = await deterministicId("pipeline-v4-work", dedupeKey);
      const workInput = stableJson({ kind: "catalog_backfill_store_check_v4", runId: run.runId, commodityId, ingredientId,
        definitionVersionId: definition.versionId, storeLocationId, queryTerms: [label], legacySemanticState: semanticState,
        legacyObservationId: observationId, legacyRow: legacyRow ?? null });
      const inputHash = await digestHex(workInput);
      await db.prepare(`INSERT INTO pipeline_agent_work_items_v4
        (id,agent_id,entity_type,entity_id,dedupe_key,priority,state,input_ref_hash,correlation_id,input_json)
        VALUES(?1,?2,'catalog_backfill_cell',?3,?4,50,'queued',?5,?6,?7) ON CONFLICT(dedupe_key) DO NOTHING`)
        .bind(workId, agentId, ingredientId, dedupeKey, inputHash, run.runId, workInput).run();
      const inserted = await db.prepare(`INSERT INTO catalog_backfill_cells_v4
        (run_id,commodity_id,ingredient_id,definition_version_id,store_location_id,semantic_state,evidence_state,
         legacy_observation_id,legacy_row_json,legacy_row_hash,producer_work_item_id)
        VALUES(?1,?2,?3,?4,?5,?6,'queued',?7,?8,?9,?10) ON CONFLICT(run_id,commodity_id,store_location_id) DO NOTHING`)
        .bind(run.runId, commodityId, ingredientId, definition.versionId, storeLocationId, semanticState,
          observationId, rowJson, rowHash, workId).run();
      enqueued += Number(inserted.meta.changes ?? 0);
    }
  }
  const staged = await db.prepare("SELECT COUNT(*) AS count FROM catalog_backfill_ingredients_v4 WHERE run_id=?1")
    .bind(run.runId).first<{ count: number }>();
  if (Number(staged?.count ?? 0) === commodities.length) await db.prepare(
    "UPDATE catalog_backfill_runs_v4 SET state='capturing',updated_at=CURRENT_TIMESTAMP WHERE run_id=?1 AND state='staging'")
    .bind(run.runId).run();
  return { ...run, offset: input.offset, processed: page.length, nextOffset: input.offset + page.length,
    done: input.offset + page.length >= commodities.length, pricedRecovered, legacyUnknown, enqueued };
}

export async function catalogBackfillProgress(db: D1Database, runId?: string) {
  const run = runId
    ? await db.prepare("SELECT * FROM catalog_backfill_runs_v4 WHERE run_id=?1").bind(runId).first<Record<string, unknown>>()
    : await db.prepare("SELECT * FROM catalog_backfill_runs_v4 ORDER BY created_at DESC LIMIT 1").first<Record<string, unknown>>();
  if (!run) return null;
  const [semantic, evidence, work] = await Promise.all([
    db.prepare(`SELECT semantic_state,COUNT(*) AS count FROM catalog_backfill_cells_v4 WHERE run_id=?1 GROUP BY semantic_state ORDER BY semantic_state`)
      .bind(run.run_id).all<Record<string, unknown>>(),
    db.prepare(`SELECT evidence_state,COUNT(*) AS count FROM catalog_backfill_cells_v4 WHERE run_id=?1 GROUP BY evidence_state ORDER BY evidence_state`)
      .bind(run.run_id).all<Record<string, unknown>>(),
    db.prepare(`SELECT agent_id,state,COUNT(*) AS count FROM pipeline_agent_work_items_v4 WHERE correlation_id=?1
      GROUP BY agent_id,state ORDER BY agent_id,state`).bind(run.run_id).all<Record<string, unknown>>(),
  ]);
  return { run, semanticParity: semantic.results, terminalEvidenceReadiness: evidence.results, workItems: work.results,
    promotionAllowed: catalogBackfillPromotionAllowed(evidence.results, Number(run.expected_cell_count)) };
}

export function catalogBackfillPromotionAllowed(rows: Array<Record<string, unknown>>, expectedCellCount: number): boolean {
  return rows.length === 1 && rows[0]?.evidence_state === "terminal_verified"
    && Number(rows[0]?.count ?? 0) === expectedCellCount;
}

export async function claimCatalogBackfillBatch(db: D1Database, input: {
  agentId: string; owner: string; limit: number; leaseSeconds: number;
}) {
  const now = new Date();
  return claimPipelineAgentWork(db, { agentId: input.agentId, owner: input.owner, now: now.toISOString(),
    leaseExpiresAt: new Date(now.getTime() + Math.min(3600, Math.max(60, input.leaseSeconds)) * 1000).toISOString(), limit: input.limit });
}

export async function heartbeatCatalogBackfillOwner(db: D1Database, input: { owner: string; leaseSeconds: number }) {
  const leaseSeconds = Math.min(3600, Math.max(60, input.leaseSeconds));
  const workItems = (await db.prepare(`UPDATE pipeline_agent_work_items_v4
    SET lease_expires_at=datetime('now',?2),heartbeat_at=CURRENT_TIMESTAMP,state='running'
    WHERE lease_owner=?1 AND entity_type='catalog_backfill_cell' AND state IN ('claimed','running')
      AND lease_expires_at>CURRENT_TIMESTAMP
    RETURNING *`)
    .bind(input.owner, `+${leaseSeconds} seconds`).all<Record<string, unknown>>()).results;
  const renewed = workItems.length;
  if (renewed === 0) throw new Error("backfill owner has no unexpired claimed work");
  workItems.sort((left, right) => Number(left.priority ?? 0) - Number(right.priority ?? 0)
    || String(left.available_at ?? "").localeCompare(String(right.available_at ?? ""))
    || String(left.id ?? "").localeCompare(String(right.id ?? "")));
  return { owner: input.owner, renewed, leaseSeconds, workItems };
}

export async function requeueCatalogBackfillCell(db: D1Database, input: {
  runId: string; commodityId: string; storeLocationId: string; adjudicationId: string;
  resolutionType: "adapter_repaired" | "challenge_resolved"; reason: string;
}) {
  if (!input.adjudicationId.trim() || input.reason.trim().length < 10) throw new Error("backfill requeue requires durable adjudication identity and reason");
  if (!["adapter_repaired", "challenge_resolved"].includes(input.resolutionType)) throw new Error("backfill requeue requires a typed resolution");
  const existing = await db.prepare(`SELECT id FROM pipeline_agent_work_items_v4 WHERE correlation_id=?1 AND entity_type='catalog_backfill_cell'
    AND json_extract(input_json,'$.commodityId')=?2 AND json_extract(input_json,'$.storeLocationId')=?3
    AND json_extract(input_json,'$.operatorAdjudication.id')=?4 ORDER BY created_at DESC LIMIT 1`)
    .bind(input.runId, input.commodityId, input.storeLocationId, input.adjudicationId).first<{ id: string }>();
  if (existing) return { workItemId: existing.id, adjudicationId: input.adjudicationId, state: "queued", idempotent: true };
  const prior = await db.prepare(`SELECT cell.producer_work_item_id,cell.evidence_state,work.agent_id,work.input_json,work.dedupe_key
    FROM catalog_backfill_cells_v4 cell JOIN pipeline_agent_work_items_v4 work ON work.id=cell.producer_work_item_id
    WHERE cell.run_id=?1 AND cell.commodity_id=?2 AND cell.store_location_id=?3
      AND cell.evidence_state IN ('needs_operator','challenged')`)
    .bind(input.runId, input.commodityId, input.storeLocationId)
    .first<{ producer_work_item_id: string; evidence_state: string; agent_id: string; input_json: string; dedupe_key: string }>();
  if (!prior) throw new Error("backfill cell is not awaiting operator resolution");
  if (prior.evidence_state === "needs_operator" && input.resolutionType !== "adapter_repaired") {
    throw new Error("needs-operator evidence requires a deployed adapter/source-fact repair before fresh capture");
  }
  if (prior.evidence_state === "challenged" && input.resolutionType !== "challenge_resolved") {
    throw new Error("challenged evidence requires an acknowledged challenge resolution before fresh capture");
  }
  const dedupeKey = `${prior.dedupe_key}:adjudication:${input.adjudicationId}`;
  const workItemId = await deterministicId("pipeline-v4-work", dedupeKey);
  const workInput = stableJson({ ...(JSON.parse(prior.input_json) as Record<string, unknown>), retryOf: prior.producer_work_item_id,
    operatorAdjudication: { id: input.adjudicationId, resolutionType: input.resolutionType,
      reason: input.reason.trim(), resolvedAt: new Date().toISOString() } });
  const inputHash = await digestHex(workInput);
  await db.batch([
    db.prepare(`INSERT INTO pipeline_agent_work_items_v4
      (id,agent_id,entity_type,entity_id,dedupe_key,priority,state,input_ref_hash,correlation_id,input_json)
      SELECT ?1,?2,'catalog_backfill_cell',ingredient_id,?3,60,'queued',?4,run_id,?5
      FROM catalog_backfill_cells_v4 WHERE run_id=?6 AND commodity_id=?7 AND store_location_id=?8
      ON CONFLICT(dedupe_key) DO NOTHING`).bind(workItemId, prior.agent_id, dedupeKey, inputHash, workInput,
        input.runId, input.commodityId, input.storeLocationId),
    db.prepare(`UPDATE catalog_backfill_cells_v4 SET evidence_state='queued',producer_work_item_id=?4,verifier_work_item_id=NULL,
      terminal_result_json=NULL,terminal_result_hash=NULL,updated_at=CURRENT_TIMESTAMP
      WHERE run_id=?1 AND commodity_id=?2 AND store_location_id=?3 AND producer_work_item_id=?5
        AND evidence_state IN ('needs_operator','challenged')
        AND EXISTS(SELECT 1 FROM pipeline_agent_work_items_v4 WHERE id=?4)`)
      .bind(input.runId, input.commodityId, input.storeLocationId, workItemId, prior.producer_work_item_id),
  ]);
  const moved = await db.prepare(`SELECT producer_work_item_id,evidence_state FROM catalog_backfill_cells_v4
    WHERE run_id=?1 AND commodity_id=?2 AND store_location_id=?3`).bind(input.runId, input.commodityId, input.storeLocationId)
    .first<{ producer_work_item_id: string; evidence_state: string }>();
  if (moved?.producer_work_item_id !== workItemId || moved.evidence_state !== "queued") throw new Error("backfill requeue lost its cell fence");
  return { workItemId, adjudicationId: input.adjudicationId, state: "queued", idempotent: false };
}

/** Invalidates derived evidence after a deterministic capture/validator defect.
 * Immutable evidence remains queryable, while every work item that authorized
 * the current cell is superseded and the terminal readiness count is reduced.
 */
export async function correctCatalogBackfillEvidence(db: D1Database, input: {
  runId: string; commodityId: string; storeLocationId: string; correctionId: string; reason: string;
}) {
  if (!input.correctionId.trim() || input.reason.trim().length < 20) {
    throw new Error("backfill evidence correction requires a durable identity and detailed reason");
  }
  const existing = await db.prepare(`SELECT id FROM pipeline_agent_work_items_v4
    WHERE correlation_id=?1 AND entity_type='catalog_backfill_cell'
      AND json_extract(input_json,'$.commodityId')=?2 AND json_extract(input_json,'$.storeLocationId')=?3
      AND json_extract(input_json,'$.evidenceCorrection.id')=?4 ORDER BY created_at DESC LIMIT 1`)
    .bind(input.runId, input.commodityId, input.storeLocationId, input.correctionId).first<{ id: string }>();
  if (existing) return { workItemId: existing.id, correctionId: input.correctionId, state: "queued", idempotent: true };
  const prior = await db.prepare(`SELECT cell.ingredient_id,cell.producer_work_item_id,cell.verifier_work_item_id,cell.evidence_state,
      work.agent_id,work.input_json,work.dedupe_key
    FROM catalog_backfill_cells_v4 cell JOIN pipeline_agent_work_items_v4 work ON work.id=cell.producer_work_item_id
    WHERE cell.run_id=?1 AND cell.commodity_id=?2 AND cell.store_location_id=?3
      AND cell.evidence_state IN ('producer_ready','terminal_verified','needs_operator')`)
    .bind(input.runId, input.commodityId, input.storeLocationId).first<{ ingredient_id: string; producer_work_item_id: string;
      verifier_work_item_id: string | null; evidence_state: string; agent_id: string; input_json: string; dedupe_key: string }>();
  if (!prior) throw new Error("backfill cell has no invalidatable derived evidence");
  const dedupeKey = `${prior.dedupe_key}:correction:${input.correctionId}`;
  const workItemId = await deterministicId("pipeline-v4-work", dedupeKey);
  const correctedAt = new Date().toISOString();
  const workInput = stableJson({ ...(JSON.parse(prior.input_json) as Record<string, unknown>),
    retryOf: prior.producer_work_item_id, evidenceCorrection: { id: input.correctionId, type: "evidence_invalidated",
      reason: input.reason.trim(), invalidatedState: prior.evidence_state, correctedAt } });
  const inputHash = await digestHex(workInput);
  await db.batch([
    db.prepare(`INSERT INTO pipeline_agent_work_items_v4
      (id,agent_id,entity_type,entity_id,dedupe_key,priority,state,input_ref_hash,correlation_id,input_json)
      VALUES(?1,?2,'catalog_backfill_cell',?3,?4,100,'queued',?5,?6,?7)
      ON CONFLICT(dedupe_key) DO NOTHING`).bind(workItemId, prior.agent_id, prior.ingredient_id, dedupeKey, inputHash, input.runId, workInput),
    db.prepare(`UPDATE pipeline_agent_work_items_v4 SET state='superseded',terminal_at=COALESCE(terminal_at,CURRENT_TIMESTAMP),
      lease_owner=NULL,lease_expires_at=NULL WHERE id IN (?1,?2) AND state<>'superseded'`)
      .bind(prior.producer_work_item_id, prior.verifier_work_item_id ?? ""),
    db.prepare(`UPDATE catalog_backfill_cells_v4 SET evidence_state='queued',producer_work_item_id=?4,verifier_work_item_id=NULL,
      terminal_result_json=NULL,terminal_result_hash=NULL,updated_at=CURRENT_TIMESTAMP
      WHERE run_id=?1 AND commodity_id=?2 AND store_location_id=?3 AND producer_work_item_id=?5
        AND evidence_state IN ('producer_ready','terminal_verified','needs_operator')
        AND EXISTS(SELECT 1 FROM pipeline_agent_work_items_v4 WHERE id=?4)`)
      .bind(input.runId, input.commodityId, input.storeLocationId, workItemId, prior.producer_work_item_id),
    db.prepare(`UPDATE catalog_backfill_ingredients_v4 SET terminal_evidence_count=(SELECT COUNT(*)
      FROM catalog_backfill_cells_v4 cell WHERE cell.run_id=?1 AND cell.commodity_id=?2
        AND cell.evidence_state='terminal_verified'),updated_at=CURRENT_TIMESTAMP WHERE run_id=?1 AND commodity_id=?2`)
      .bind(input.runId, input.commodityId),
  ]);
  const moved = await db.prepare(`SELECT producer_work_item_id,evidence_state FROM catalog_backfill_cells_v4
    WHERE run_id=?1 AND commodity_id=?2 AND store_location_id=?3`).bind(input.runId, input.commodityId, input.storeLocationId)
    .first<{ producer_work_item_id: string; evidence_state: string }>();
  if (moved?.producer_work_item_id !== workItemId || moved.evidence_state !== "queued") {
    throw new Error("backfill evidence correction lost its cell fence");
  }
  return { workItemId, correctionId: input.correctionId, previousState: prior.evidence_state,
    supersededWorkItemIds: [prior.producer_work_item_id, prior.verifier_work_item_id].filter(Boolean), state: "queued", idempotent: false };
}

export type BackfillEvidenceSubmission = {
  workItemId: string; owner: string; leaseGeneration: number; generationId: string; sessionId: string;
  document: unknown;
};

type DerivedBackfillCapture = { outcome: "priced" | "not_found" | "challenged" | "needs_operator"; observedAt: string; sourceUrl: string;
  candidateSetHash: string; winner: Record<string, unknown> | null; coverageHash: string };

function parsedBackfillPackage(value: string): { unit: string; quantityMicros: number } | null {
  const normalized = value.toLowerCase().replace(/fluid ounces?/g, "fl oz").replace(/ounces?/g, "oz")
    .replace(/pounds?/g, "lb").replace(/\blbs?\.?/g, "lb").replace(/grams?/g, "g").replace(/kilograms?/g, "kg")
    .replace(/liters?/g, "l").replace(/gallons?/g, "gal").replace(/counts?/g, "ct").trim();
  const match = normalized.match(/^(?:(\d+)\s*[x×]\s*)?([0-9]+(?:\.[0-9]+)?)\s*(fl\s*oz|oz|lb|ml|l|g|kg|ct|ea|each|dozen|gal|qt|pt)\b/);
  if (!match) return /^(?:each|ea)$/.test(normalized) ? { unit: "each", quantityMicros: 1_000_000 } : null;
  const count = Number(match[1] ?? 1); const quantity = Number(match[2]) * count;
  const raw = String(match[3]).replace(/\s/g, "");
  const unit = raw === "floz" ? "fl_oz" : raw === "l" ? "liter" : raw === "g" ? "gram" : ["ct", "ea", "each"].includes(raw) ? "each" : raw;
  return Number.isFinite(quantity) && quantity > 0 ? { unit, quantityMicros: Math.round(quantity * 1_000_000) } : null;
}

function convertedBackfillQuantity(value: { unit: string; quantityMicros: number }, basisUnit: string): number | null {
  const from = value.unit; const to = basisUnit.toLowerCase().replace("fl oz", "fl_oz");
  const mass: Record<string, number> = { oz: 28.349523125, lb: 453.59237, gram: 1, g: 1, kg: 1000 };
  const volume: Record<string, number> = { fl_oz: 29.5735295625, ml: 1, liter: 1000, l: 1000, gal: 3785.411784, qt: 946.352946, pt: 473.176473 };
  if (from === to || (from === "gram" && to === "g") || (from === "liter" && to === "l")) return value.quantityMicros;
  if (from in mass && to in mass) return Math.round(value.quantityMicros * mass[from]! / mass[to]!);
  if (from in volume && to in volume) return Math.round(value.quantityMicros * volume[from]! / volume[to]!);
  if (from === "each" && to === "dozen") return Math.round(value.quantityMicros / 12);
  if (from === "dozen" && ["each", "ea", "ct"].includes(to)) return value.quantityMicros * 12;
  return null;
}

function phraseTokens(value: string): string[][] {
  return value.split("/").map((part) => normalizeName(part.replace(/\([^)]*\)/g, " ")).split(" ")
    .filter((token) => token.length > 1 && !["fresh", "whole", "ground", "canned", "jarred"].includes(token))).filter((tokens) => tokens.length > 0);
}

export async function deriveCatalogBackfillCapture(input: { storeLocationId: string; queryTerms: string[]; identity: Record<string, any>; document: unknown }): Promise<DerivedBackfillCapture> {
  const policy = CAPTURE_POLICY_BY_STORE[input.storeLocationId];
  if (!policy) throw new Error("backfill capture store policy is missing");
  const chunk = input.document as Record<string, any>;
  if (chunk?.version !== 2 || chunk?.phase !== "discovery" || chunk?.store !== adapterNameForPolicy(policy)) throw new Error("backfill capture adapter chunk identity mismatch");
  const canary = chunk.canary as Record<string, unknown> | undefined;
  if (!canary || canary.locationVerified !== true || canary.priceModeVerified !== true) throw new Error("backfill capture lacks an exact location/mode canary");
  const canaryLocation = stableJson([canary.location, canary.exactAddress]);
  const canaryMode = String(canary.priceMode ?? "");
  const canaryLocationId = String(canary.locationId ?? "");
  if (String(canary.retailerLocationKey ?? "") !== policy.retailerLocationKey
    || canaryLocationId && canaryLocationId !== policy.retailerLocationKey && canaryLocationId !== policy.priceLocationKey
    || !new RegExp(policy.locationCanary.expectedLocationPattern, "i").test(canaryLocation)
    || !new RegExp(policy.locationCanary.expectedModePattern, "i").test(canaryMode)) {
    throw new Error("backfill capture canary is not bound to the canonical retailer location and price mode");
  }
  const sourceUrl = String(canary.evidenceUrl ?? "");
  const observedAt = String(canary.observedAt ?? "");
  const host = new URL(sourceUrl).hostname;
  if (host !== policy.firstPartyHost && !host.endsWith(`.${policy.firstPartyHost}`)) throw new Error("backfill capture canary uses the wrong retailer host");
  const expectedTerms = [...new Set(input.queryTerms.map(normalizeName))].sort();
  const termRows = Array.isArray(chunk.terms) ? chunk.terms : [];
  const observedTerms = termRows.map((row: any) => normalizeName(String(row.query ?? ""))).sort();
  if (stableJson(expectedTerms) !== stableJson(observedTerms)) throw new Error("backfill capture does not cover exactly the locked query plan");
  const coverageHash = await digestHex(stableJson(termRows.map((term: any) => ({ query: normalizeName(String(term.query)),
    outcome: term.outcome, rowCount: term.rowCount, retrieval: term.retrieval, excludedResults: term.excludedResults ?? [] }))));
  const challenged = termRows.some((term: any) => term.outcome === "blocked" || /challenge|captcha|blocked/i.test(String(term.reason ?? "")));
  if (challenged) return { outcome: "challenged", observedAt, sourceUrl,
    candidateSetHash: await digestHex(stableJson(chunk.rows ?? [])), winner: null, coverageHash };
  const rejected = termRows.some((term: any) => !["success", "empty"].includes(String(term.outcome)));
  if (rejected) return { outcome: "needs_operator", observedAt, sourceUrl,
    candidateSetHash: await digestHex(stableJson(chunk.rows ?? [])), winner: null, coverageHash };
  const rowsByTerm = new Map(expectedTerms.map((term) => [term, 0]));
  for (const row of Array.isArray(chunk.rows) ? chunk.rows : []) {
    const query = normalizeName(String(row.q ?? row.term ?? ""));
    if (!rowsByTerm.has(query)) throw new Error("backfill capture row is outside the locked query plan");
    rowsByTerm.set(query, (rowsByTerm.get(query) ?? 0) + 1);
  }
  for (const term of termRows) {
    const retrieval = term.retrieval as Record<string, unknown> | undefined;
    const query = normalizeName(String(term.query ?? ""));
    const projectedRows = rowsByTerm.get(query) ?? 0;
    const excludedResults = Array.isArray(term.excludedResults) ? term.excludedResults : [];
    if (!Number.isSafeInteger(term.rowCount) || term.rowCount !== projectedRows) throw new Error(`backfill capture row count mismatch for ${term.query}`);
    if (excludedResults.some((item: any) => !String(item?.productKey ?? "").trim() || !String(item?.name ?? "").trim() || !String(item?.reason ?? "").trim())
      || new Set(excludedResults.map((item: any) => String(item.productKey))).size !== excludedResults.length) {
      throw new Error(`backfill capture raw exclusion facts are incomplete for ${term.query}`);
    }
    const terminal = term.outcome === "success" ? retrieval?.termination === "end-of-results"
      : term.outcome === "empty" && ["no-results", "end-of-results"].includes(String(retrieval?.termination));
    const loadedResultCount = Number(retrieval?.loadedResultCount);
    const availableResultCount = Number(retrieval?.availableResultCount);
    if (!terminal || retrieval?.hasMoreResults !== false || !Number.isSafeInteger(loadedResultCount) || !Number.isSafeInteger(availableResultCount)
      || loadedResultCount !== availableResultCount
      || loadedResultCount !== projectedRows + excludedResults.length
      || Number(retrieval.pageCount ?? 0) < 1) {
      throw new Error(`backfill capture lacks complete challenge-free pagination for ${term.query}`);
    }
    if (term.outcome === "empty" && (projectedRows !== 0 || excludedResults.length !== 0 || loadedResultCount !== 0)) {
      throw new Error(`backfill capture forged or filtered an empty result for ${term.query}`);
    }
  }
  const accepted = [input.identity.canonicalName, input.identity.displayName, ...(input.identity.acceptedForms ?? [])]
    .flatMap((value: string) => phraseTokens(String(value)));
  const excluded = (input.identity.excludedForms ?? []).map((value: string) => normalizeName(String(value))).filter(Boolean);
  const candidates: Array<Record<string, any>> = [];
  for (const row of Array.isArray(chunk.rows) ? chunk.rows : []) {
    const query = normalizeName(String(row.q ?? row.term ?? ""));
    if (!expectedTerms.includes(query)) throw new Error("backfill capture row is outside the locked query plan");
    const capture = row._capture as Record<string, any> | undefined;
    const offer = capture?.offer as Record<string, any> | undefined;
    const pageState = capture?.pageState as Record<string, any> | undefined;
    if (!capture || !offer || pageState?.challengeDetected === true) throw new Error("backfill capture row lacks challenge-free source truth");
    const productId = String(offer.retailerProductId ?? row.id ?? "").trim();
    const productName = String(offer.productName ?? row.name ?? row.n ?? "").trim();
    const productUrl = String(offer.sourceUrl ?? row.url ?? "");
    const packageText = String(offer.sizeText ?? row.size ?? "").trim();
    const priceMinor = Number(offer.purchasePriceMinor);
    const availability = offer.availability as Record<string, any> | undefined;
    const locationText = stableJson([capture.location, pageState?.locationText]);
    const mode = String(capture.priceMode ?? pageState?.fulfillmentText ?? "");
    const locationPattern = new RegExp(policy.locationCanary.expectedLocationPattern, "i");
    const modePattern = new RegExp(policy.locationCanary.expectedModePattern, "i");
    if (!locationPattern.test(locationText) || !modePattern.test(mode)) {
      throw new Error("backfill capture row is not bound to the authoritative location and price mode");
    }
    const url = new URL(productUrl);
    if (url.hostname !== policy.firstPartyHost && !url.hostname.endsWith(`.${policy.firstPartyHost}`) || !productId || !productName || !Number.isSafeInteger(priceMinor) || priceMinor <= 0
      || !availability || typeof availability.eligible !== "boolean" || !String(availability.status ?? "")) {
      throw new Error("backfill capture row has invalid source, product, price, or availability identity");
    }
    const normalizedProduct = normalizeName(productName);
    const identityAccepted = accepted.some((tokens) => tokens.every((token) => normalizedProduct.includes(token)));
    const identityExcluded = excluded.some((value: string) => normalizedProduct.includes(value));
    const parsed = parsedBackfillPackage(packageText);
    const quantityMicros = parsed ? convertedBackfillQuantity(parsed, String(input.identity.basisUnit ?? "")) : null;
    const semantics = offer.priceSemantics as Record<string, any> | undefined;
    const qualifyingQuantity = Number(semantics?.qualifyingQuantity ?? 1);
    const semanticsExact = semantics?.ambiguity === false && Number.isSafeInteger(Number(semantics?.unitPriceMinor))
      && Number.isSafeInteger(Number(semantics?.totalPriceMinor)) && Number.isSafeInteger(qualifyingQuantity) && qualifyingQuantity > 0
      && Math.abs(Number(semantics?.unitPriceMinor) * qualifyingQuantity - Number(semantics?.totalPriceMinor)) <= 1
      && Number(semantics?.totalPriceMinor) === priceMinor;
    const promotional = ["sale", "markdown", "multibuy", "loyalty"].includes(String(semantics?.offerType));
    const validFrom = typeof semantics?.validFrom === "string" ? semantics.validFrom : null;
    const validTo = typeof semantics?.validTo === "string" ? semantics.validTo : null;
    const validPromotion = !promotional || Boolean(validFrom && validTo && Date.parse(validFrom) <= Date.parse(observedAt)
      && Date.parse(validTo) >= Date.parse(observedAt) && validTo > validFrom);
    const availabilityLocation = String(availability.locationId ?? "").toLowerCase();
    const availabilityMode = String(availability.fulfillmentMode ?? "");
    const availabilityUnknown = availability.status === "unknown" || availability.status === "";
    const locationUnknown = availabilityLocation === "";
    const fulfillmentUnknown = availabilityMode === "";
    const availabilityModeEligible = normalizeName(availabilityMode) === normalizeName(policy.priceMode)
      || new RegExp(policy.locationCanary.expectedModePattern, "i").test(availabilityMode);
    const storeEligible = (availabilityLocation === policy.retailerLocationKey.toLowerCase()
      || availabilityLocation === policy.priceLocationKey.toLowerCase())
      && availabilityModeEligible
      && availability.eligible === true && availability.status === "in_stock";
    candidates.push({ productId, productName, productUrl, packageText, priceMinor, quantityMicros,
      validFrom, validTo,
      eligible: identityAccepted && !identityExcluded && storeEligible && quantityMicros !== null && quantityMicros > 0 && semanticsExact && validPromotion,
      rejectionCodes: [!identityAccepted && "identity_not_included", identityExcluded && "identity_excluded", !quantityMicros && "invalid_package_basis",
        availabilityUnknown && "availability_unknown", locationUnknown && "location_unknown", fulfillmentUnknown && "fulfillment_unknown",
        !storeEligible && !availabilityUnknown && !locationUnknown && !fulfillmentUnknown && "store_ineligible",
        !semanticsExact && "invalid_price_semantics", !validPromotion && "missing_or_inactive_ad_dates"].filter(Boolean) });
  }
  const unique = new Map<string, Record<string, any>>();
  for (const candidate of candidates) {
    const prior = unique.get(candidate.productId);
    if (prior && stableJson(prior) !== stableJson(candidate)) throw new Error("backfill capture contains conflicting source facts for one product");
    unique.set(candidate.productId, candidate);
  }
  const frozen = [...unique.values()].sort((a, b) => String(a.productId).localeCompare(String(b.productId)));
  const unresolvedCandidate = frozen.some((candidate) => candidate.rejectionCodes.some((code: string) =>
    ["invalid_package_basis", "availability_unknown", "location_unknown", "fulfillment_unknown", "invalid_price_semantics", "missing_or_inactive_ad_dates"].includes(code))
    && !candidate.rejectionCodes.includes("identity_not_included") && !candidate.rejectionCodes.includes("identity_excluded"));
  const eligible = frozen.filter((row) => row.eligible).sort((a, b) => {
    const left = BigInt(a.priceMinor) * BigInt(b.quantityMicros); const right = BigInt(b.priceMinor) * BigInt(a.quantityMicros);
    return left < right ? -1 : left > right ? 1 : String(a.productId).localeCompare(String(b.productId));
  });
  // An eligible exact candidate gives the deterministic winner authority. An
  // unresolved same-identity candidate blocks only absence: it could conceal a
  // qualifying result when there is no exact candidate to price. Fact-free
  // client exclusions remain nonterminal because the server cannot type them.
  if ((!eligible.length && unresolvedCandidate)
    || termRows.some((term: any) => Array.isArray(term.excludedResults) && term.excludedResults.length > 0)) {
    return { outcome: "needs_operator", observedAt, sourceUrl, candidateSetHash: await digestHex(stableJson(frozen)), winner: null, coverageHash };
  }
  const winner = eligible[0] ? { ...eligible[0], unitPriceNumerator: eligible[0].priceMinor, unitPriceDenominator: eligible[0].quantityMicros } : null;
  return { outcome: winner ? "priced" : "not_found", observedAt, sourceUrl,
    candidateSetHash: await digestHex(stableJson(frozen)), winner,
    coverageHash };
}

export function assertFreshBackfillEvidence(storeLocationId: string, input: BackfillEvidenceSubmission, derived: DerivedBackfillCapture) {
  if (!input.owner || !input.generationId || !input.sessionId || !Number.isInteger(input.leaseGeneration) || input.leaseGeneration < 1) {
    throw new Error("backfill evidence omitted its lease, generation, or session fence");
  }
  const policy = CAPTURE_POLICY_BY_STORE[storeLocationId];
  const observedAt = Date.parse(derived.observedAt);
  if (!policy || !Number.isFinite(observedAt) || Date.now() - observedAt > policy.evidenceFreshnessMinutes * 60_000 || observedAt - Date.now() > 60_000) {
    throw new Error("backfill evidence is stale or future-dated");
  }
  const url = new URL(derived.sourceUrl);
  if (url.protocol !== "https:" || !policy || url.hostname !== policy.firstPartyHost && !url.hostname.endsWith(`.${policy.firstPartyHost}`)) {
    throw new Error("backfill evidence source does not match the authoritative retailer");
  }
}

export function assertIndependentBackfillEvidence(input: {
  producer: { documentHash: string; generationId: string; sessionId: string; observedAt: string };
  verifier: { documentHash: string; generationId: string; sessionId: string; observedAt: string };
}) {
  if (input.producer.documentHash === input.verifier.documentHash || input.producer.generationId === input.verifier.generationId
    || input.producer.sessionId === input.verifier.sessionId) throw new Error("verifier evidence is not independent from producer evidence");
  if (Date.parse(input.verifier.observedAt) <= Date.parse(input.producer.observedAt)) throw new Error("verifier evidence must be newer than producer evidence");
}

export function assertFrozenBackfillReproduction(producerOutcome: string, producerWinner: unknown, derived: DerivedBackfillCapture) {
  if (!["priced", "not_found"].includes(producerOutcome) || derived.outcome !== producerOutcome) {
    throw new Error("verifier rederivation does not match the frozen producer outcome");
  }
  if (producerOutcome === "priced" && stableJson(derived.winner) !== stableJson(producerWinner)) {
    throw new Error("verifier did not independently reproduce the frozen producer winner");
  }
}

export async function submitCatalogBackfillProducer(db: D1Database, input: BackfillEvidenceSubmission) {
  const work = await db.prepare(`SELECT * FROM pipeline_agent_work_items_v4 WHERE id=?1 AND entity_type='catalog_backfill_cell'`)
    .bind(input.workItemId).first<Record<string, unknown>>();
  if (!work || !String(work.agent_id).startsWith("omaha-price-producer-")) throw new Error("producer backfill work item is missing");
  const payload = JSON.parse(String(work.input_json)) as Record<string, any>;
  const storeLocationId = String(payload.storeLocationId ?? "");
  if (!payload.runId || !payload.commodityId || !payload.ingredientId || !payload.definitionVersionId || !storeLocationId) throw new Error("producer work item payload is incomplete");
  const definition = await db.prepare(`SELECT version.identity_json FROM catalog_ingredient_versions version
    JOIN catalog_ingredient_current current ON current.ingredient_id=version.ingredient_id
      AND current.current_version_id=version.version_id AND current.current_state='active'
    WHERE version.version_id=?1 AND version.ingredient_id=?2`)
    .bind(payload.definitionVersionId, payload.ingredientId).first<{ identity_json: string }>();
  if (!definition) throw new Error("producer work item definition is not current and durable");
  const queryTerms = Array.isArray(payload.queryTerms) ? payload.queryTerms.map(String) : [];
  const derived = await deriveCatalogBackfillCapture({ storeLocationId, queryTerms,
    identity: JSON.parse(definition.identity_json) as Record<string, any>, document: input.document });
  assertFreshBackfillEvidence(storeLocationId, input, derived);
  const documentJson = stableJson({ adapterChunk: input.document, derived });
  const documentHash = await digestHex(documentJson);
  const evidenceId = await deterministicId("catalog-backfill-evidence", input.workItemId, "producer", documentHash);
  const terminalCandidate = derived.outcome === "priced" || derived.outcome === "not_found";
  const verifierAgent = VERIFIER_BY_STORE[storeLocationId];
  if (terminalCandidate && !verifierAgent) throw new Error("producer work item has no registered verifier lane");
  const verifierDedupe = `catalog-backfill:${payload.ingredientId}:${payload.storeLocationId}:${payload.definitionVersionId}:verifier:${evidenceId}`;
  const verifierWorkId = await deterministicId("pipeline-v4-work", verifierDedupe);
  const verifierInput = stableJson({ ...payload, kind: "catalog_backfill_verify_v4", producerWorkItemId: input.workItemId,
    producerEvidenceId: evidenceId, producerOutcome: derived.outcome, producerWinner: derived.winner,
    producerCandidateSetHash: derived.candidateSetHash, producerCoverageHash: derived.coverageHash, producerDocumentHash: documentHash,
    producerGenerationId: input.generationId, producerSessionId: input.sessionId, producerObservedAt: derived.observedAt });
  const verifierInputHash = await digestHex(verifierInput);
  const resultJson = stableJson({ ...derived, evidenceId, documentHash });
  const statements: D1PreparedStatement[] = [
    db.prepare(`INSERT INTO catalog_backfill_evidence_v4
      (evidence_id,run_id,commodity_id,store_location_id,work_item_id,kind,generation_id,session_id,source_url,observed_at,document_json,document_hash)
      SELECT ?1,?2,?3,?4,id,'producer',?5,?6,?7,?8,?9,?10 FROM pipeline_agent_work_items_v4
      WHERE id=?11 AND lease_owner=?12 AND lease_generation=?13 AND state IN ('claimed','running') AND lease_expires_at>CURRENT_TIMESTAMP
      ON CONFLICT(work_item_id) DO NOTHING`).bind(evidenceId, payload.runId, payload.commodityId, payload.storeLocationId,
        input.generationId, input.sessionId, derived.sourceUrl, derived.observedAt, documentJson, documentHash,
        input.workItemId, input.owner, input.leaseGeneration),
    db.prepare(`UPDATE pipeline_agent_work_items_v4 SET state=?2,result_json=?3,result_ref_hash=?4,terminal_at=CURRENT_TIMESTAMP,
      lease_owner=NULL,lease_expires_at=NULL WHERE id=?1 AND EXISTS(SELECT 1 FROM catalog_backfill_evidence_v4 WHERE evidence_id=?5)`)
      .bind(input.workItemId, terminalCandidate ? "succeeded" : derived.outcome === "challenged" ? "blocked_challenge" : "needs_operator",
        resultJson, documentHash, evidenceId),
    db.prepare(`UPDATE catalog_backfill_cells_v4 SET evidence_state=?4,updated_at=CURRENT_TIMESTAMP
      WHERE run_id=?1 AND commodity_id=?2 AND store_location_id=?3 AND EXISTS(SELECT 1 FROM catalog_backfill_evidence_v4 WHERE evidence_id=?5)`)
      .bind(payload.runId, payload.commodityId, payload.storeLocationId,
        terminalCandidate ? "producer_ready" : derived.outcome, evidenceId),
  ];
  if (terminalCandidate) statements.push(db.prepare(`INSERT INTO pipeline_agent_work_items_v4
      (id,agent_id,entity_type,entity_id,dedupe_key,priority,state,input_ref_hash,correlation_id,input_json)
      SELECT ?1,?2,'catalog_backfill_cell',?3,?4,50,'queued',?5,?6,?7
      WHERE EXISTS(SELECT 1 FROM catalog_backfill_evidence_v4 WHERE evidence_id=?8) ON CONFLICT(dedupe_key) DO NOTHING`)
      .bind(verifierWorkId, verifierAgent!, payload.ingredientId, verifierDedupe, verifierInputHash, payload.runId, verifierInput, evidenceId));
  if (terminalCandidate) statements.push(db.prepare(`UPDATE catalog_backfill_cells_v4 SET verifier_work_item_id=?4 WHERE run_id=?1 AND commodity_id=?2
      AND store_location_id=?3 AND EXISTS(SELECT 1 FROM catalog_backfill_evidence_v4 WHERE evidence_id=?5)`)
      .bind(payload.runId, payload.commodityId, payload.storeLocationId, verifierWorkId, evidenceId));
  await db.batch(statements);
  const stored = await db.prepare("SELECT evidence_id FROM catalog_backfill_evidence_v4 WHERE evidence_id=?1").bind(evidenceId).first();
  if (!stored) throw new Error("producer evidence rejected by lease fence");
  return { evidenceId, documentHash, outcome: derived.outcome, candidateSetHash: derived.candidateSetHash,
    coverageHash: derived.coverageHash, winner: derived.winner, verifierWorkItemId: terminalCandidate ? verifierWorkId : null };
}

export async function submitCatalogBackfillVerifier(db: D1Database, input: BackfillEvidenceSubmission) {
  const work = await db.prepare(`SELECT * FROM pipeline_agent_work_items_v4 WHERE id=?1 AND entity_type='catalog_backfill_cell'`)
    .bind(input.workItemId).first<Record<string, unknown>>();
  if (!work || !String(work.agent_id).startsWith("omaha-price-verifier-")) throw new Error("verifier backfill work item is missing");
  const payload = JSON.parse(String(work.input_json)) as Record<string, any>;
  const storeLocationId = String(payload.storeLocationId ?? "");
  const producerOutcome = String(payload.producerOutcome ?? "");
  if (!payload.runId || !payload.commodityId || !payload.producerEvidenceId || !storeLocationId) throw new Error("verifier work item payload is incomplete");
  const definition = await db.prepare(`SELECT version.identity_json FROM catalog_ingredient_versions version
    JOIN catalog_ingredient_current current ON current.ingredient_id=version.ingredient_id
      AND current.current_version_id=version.version_id AND current.current_state='active'
    WHERE version.version_id=?1 AND version.ingredient_id=?2`)
    .bind(payload.definitionVersionId, payload.ingredientId).first<{ identity_json: string }>();
  if (!definition) throw new Error("verifier work item definition is not current and durable");
  const queryTerms = Array.isArray(payload.queryTerms) ? payload.queryTerms.map(String) : [];
  const derived = await deriveCatalogBackfillCapture({ storeLocationId, queryTerms,
    identity: JSON.parse(definition.identity_json) as Record<string, any>, document: input.document });
  assertFreshBackfillEvidence(storeLocationId, input, derived);
  assertFrozenBackfillReproduction(producerOutcome, payload.producerWinner, derived);
  const producer = await db.prepare(`SELECT document_hash,generation_id,session_id,observed_at FROM catalog_backfill_evidence_v4
    WHERE evidence_id=?1 AND kind='producer'`).bind(payload.producerEvidenceId)
    .first<{ document_hash: string; generation_id: string; session_id: string; observed_at: string }>();
  if (!producer) throw new Error("verifier work item is not bound to producer evidence");
  const documentJson = stableJson({ adapterChunk: input.document, derived });
  const documentHash = await digestHex(documentJson);
  assertIndependentBackfillEvidence({ producer: { documentHash: producer.document_hash, generationId: producer.generation_id,
    sessionId: producer.session_id, observedAt: producer.observed_at }, verifier: { documentHash, generationId: input.generationId,
    sessionId: input.sessionId, observedAt: derived.observedAt } });
  const evidenceId = await deterministicId("catalog-backfill-evidence", input.workItemId, "verifier", documentHash);
  const terminalJson = stableJson({ outcome: derived.outcome, winner: derived.winner,
    candidateSetHash: derived.candidateSetHash, coverageHash: derived.coverageHash, producerEvidenceId: payload.producerEvidenceId,
    verifierEvidenceId: evidenceId, producerDocumentHash: producer.document_hash, verifierDocumentHash: documentHash,
    verifiedAt: derived.observedAt });
  const terminalHash = await digestHex(terminalJson);
  await db.batch([
    db.prepare(`INSERT INTO catalog_backfill_evidence_v4
      (evidence_id,run_id,commodity_id,store_location_id,work_item_id,kind,generation_id,session_id,source_url,observed_at,document_json,document_hash)
      SELECT ?1,?2,?3,?4,id,'verifier',?5,?6,?7,?8,?9,?10 FROM pipeline_agent_work_items_v4
      WHERE id=?11 AND lease_owner=?12 AND lease_generation=?13 AND state IN ('claimed','running') AND lease_expires_at>CURRENT_TIMESTAMP
      ON CONFLICT(work_item_id) DO NOTHING`).bind(evidenceId, payload.runId, payload.commodityId, payload.storeLocationId,
        input.generationId, input.sessionId, derived.sourceUrl, derived.observedAt, documentJson, documentHash,
        input.workItemId, input.owner, input.leaseGeneration),
    db.prepare(`UPDATE pipeline_agent_work_items_v4 SET state=?2,result_json=?3,result_ref_hash=?4,terminal_at=CURRENT_TIMESTAMP,
      lease_owner=NULL,lease_expires_at=NULL WHERE id=?1 AND EXISTS(SELECT 1 FROM catalog_backfill_evidence_v4 WHERE evidence_id=?5)`)
      .bind(input.workItemId, "succeeded", terminalJson, terminalHash, evidenceId),
    db.prepare(`UPDATE catalog_backfill_cells_v4 SET evidence_state=?4,terminal_result_json=?5,terminal_result_hash=?6,updated_at=CURRENT_TIMESTAMP
      WHERE run_id=?1 AND commodity_id=?2 AND store_location_id=?3 AND evidence_state='producer_ready'
        AND EXISTS(SELECT 1 FROM catalog_backfill_evidence_v4 WHERE evidence_id=?7)`)
      .bind(payload.runId, payload.commodityId, payload.storeLocationId,
        "terminal_verified", terminalJson, terminalHash, evidenceId),
    db.prepare(`UPDATE catalog_backfill_ingredients_v4 SET terminal_evidence_count=(SELECT COUNT(*) FROM catalog_backfill_cells_v4 cell
      WHERE cell.run_id=?1 AND cell.commodity_id=?2 AND cell.evidence_state='terminal_verified'),updated_at=CURRENT_TIMESTAMP
      WHERE run_id=?1 AND commodity_id=?2`).bind(payload.runId, payload.commodityId),
  ]);
  const stored = await db.prepare("SELECT evidence_id FROM catalog_backfill_evidence_v4 WHERE evidence_id=?1").bind(evidenceId).first();
  if (!stored) throw new Error("verifier evidence rejected by lease fence");
  return { evidenceId, documentHash, terminalHash, outcome: derived.outcome, winner: derived.winner };
}
