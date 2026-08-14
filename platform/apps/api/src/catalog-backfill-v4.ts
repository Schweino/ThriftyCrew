import { OMAHA_STORE_LOCATION_IDS } from "@thriftycrew/contracts";
import { deterministicId, digestHex, normalizeName, stableJson } from "@thriftycrew/domain";
import { createCatalogIngredientVersion } from "./dynamic-ingredient-catalog";
import { claimPipelineAgentWork } from "./store-catalog-generations";

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
const HOST_BY_STORE: Record<string, string> = {
  "aldi-omaha-446-048": "aldi.us", "bakers-saddle-creek": "bakersplus.com",
  "family-fare-omaha-6401": "shopfamilyfare.com", "fareway-omaha-043": "fareway.com",
  "hy-vee-omaha-1465": "hy-vee.com", "sams-omaha": "samsclub.com", "walmart-omaha": "walmart.com",
};

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

export async function initializeCatalogBackfill(db: D1Database, input: { releaseId: string; boardHash: string; board: unknown }) {
  const commodities = assertLegacyBoard(input.board);
  const runId = await deterministicId("catalog-backfill-v4", input.releaseId, input.boardHash);
  await db.prepare(`INSERT INTO catalog_backfill_runs_v4
      (run_id,source_release_id,source_board_hash,state,commodity_count,expected_cell_count)
    VALUES(?1,?2,?3,'staging',?4,?5)
    ON CONFLICT(source_release_id) DO NOTHING`).bind(runId, input.releaseId, input.boardHash,
      commodities.length, commodities.length * OMAHA_STORE_LOCATION_IDS.length).run();
  const current = await db.prepare("SELECT run_id,source_board_hash,commodity_count FROM catalog_backfill_runs_v4 WHERE source_release_id=?1")
    .bind(input.releaseId).first<{ run_id: string; source_board_hash: string; commodity_count: number }>();
  if (!current || current.run_id !== runId || current.source_board_hash !== input.boardHash || Number(current.commodity_count) !== commodities.length) {
    throw new Error("legacy backfill source release changed after initialization");
  }
  return { runId, commodityCount: commodities.length, expectedCellCount: commodities.length * OMAHA_STORE_LOCATION_IDS.length };
}

export async function importCatalogBackfillPage(db: D1Database, input: {
  releaseId: string; boardHash: string; board: unknown; offset: number; limit: number;
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
  const result = await db.prepare(`UPDATE pipeline_agent_work_items_v4
    SET lease_expires_at=datetime('now',?2),heartbeat_at=CURRENT_TIMESTAMP,state='running'
    WHERE lease_owner=?1 AND entity_type='catalog_backfill_cell' AND state IN ('claimed','running')
      AND lease_expires_at>CURRENT_TIMESTAMP`)
    .bind(input.owner, `+${leaseSeconds} seconds`).run();
  const renewed = Number(result.meta.changes ?? 0);
  if (renewed === 0) throw new Error("backfill owner has no unexpired claimed work");
  return { owner: input.owner, renewed, leaseSeconds };
}

type BackfillEvidenceSubmission = {
  workItemId: string; owner: string; leaseGeneration: number; generationId: string; sessionId: string;
  sourceUrl: string; observedAt: string; outcome: "priced" | "not_found" | "ambiguous" | "challenged";
  document: unknown;
};

function assertFreshBackfillEvidence(storeLocationId: string, input: BackfillEvidenceSubmission) {
  if (!input.owner || !input.generationId || !input.sessionId || !Number.isInteger(input.leaseGeneration) || input.leaseGeneration < 1) {
    throw new Error("backfill evidence omitted its lease, generation, or session fence");
  }
  const observedAt = Date.parse(input.observedAt);
  if (!Number.isFinite(observedAt) || Date.now() - observedAt > 15 * 60_000 || observedAt - Date.now() > 60_000) {
    throw new Error("backfill evidence is stale or future-dated");
  }
  const url = new URL(input.sourceUrl);
  if (url.protocol !== "https:" || !url.hostname.endsWith(HOST_BY_STORE[storeLocationId] ?? ".invalid")) {
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

export async function submitCatalogBackfillProducer(db: D1Database, input: BackfillEvidenceSubmission) {
  const work = await db.prepare(`SELECT * FROM pipeline_agent_work_items_v4 WHERE id=?1 AND entity_type='catalog_backfill_cell'`)
    .bind(input.workItemId).first<Record<string, unknown>>();
  if (!work || !String(work.agent_id).startsWith("omaha-price-producer-")) throw new Error("producer backfill work item is missing");
  const payload = JSON.parse(String(work.input_json)) as Record<string, string>;
  const storeLocationId = String(payload.storeLocationId ?? "");
  if (!payload.runId || !payload.commodityId || !payload.ingredientId || !payload.definitionVersionId || !storeLocationId) throw new Error("producer work item payload is incomplete");
  assertFreshBackfillEvidence(storeLocationId, input);
  const documentJson = stableJson(input.document);
  const documentHash = await digestHex(documentJson);
  const evidenceId = await deterministicId("catalog-backfill-evidence", input.workItemId, "producer", documentHash);
  const isTerminalCandidate = input.outcome === "priced" || input.outcome === "not_found";
  const verifierAgent = VERIFIER_BY_STORE[storeLocationId];
  if (isTerminalCandidate && !verifierAgent) throw new Error("producer work item has no registered verifier lane");
  const verifierDedupe = `catalog-backfill:${payload.ingredientId}:${payload.storeLocationId}:${payload.definitionVersionId}:verifier:${evidenceId}`;
  const verifierWorkId = await deterministicId("pipeline-v4-work", verifierDedupe);
  const verifierInput = stableJson({ ...payload, kind: "catalog_backfill_verify_v4", producerWorkItemId: input.workItemId,
    producerEvidenceId: evidenceId, producerOutcome: input.outcome, producerDocumentHash: documentHash,
    producerGenerationId: input.generationId, producerSessionId: input.sessionId, producerObservedAt: input.observedAt });
  const verifierInputHash = await digestHex(verifierInput);
  const resultJson = stableJson({ outcome: input.outcome, evidenceId, documentHash });
  const statements: D1PreparedStatement[] = [
    db.prepare(`INSERT INTO catalog_backfill_evidence_v4
      (evidence_id,run_id,commodity_id,store_location_id,work_item_id,kind,generation_id,session_id,source_url,observed_at,document_json,document_hash)
      SELECT ?1,?2,?3,?4,id,'producer',?5,?6,?7,?8,?9,?10 FROM pipeline_agent_work_items_v4
      WHERE id=?11 AND lease_owner=?12 AND lease_generation=?13 AND state IN ('claimed','running') AND lease_expires_at>CURRENT_TIMESTAMP
      ON CONFLICT(work_item_id) DO NOTHING`).bind(evidenceId, payload.runId, payload.commodityId, payload.storeLocationId,
        input.generationId, input.sessionId, input.sourceUrl, input.observedAt, documentJson, documentHash,
        input.workItemId, input.owner, input.leaseGeneration),
    db.prepare(`UPDATE pipeline_agent_work_items_v4 SET state=?2,result_json=?3,result_ref_hash=?4,terminal_at=CURRENT_TIMESTAMP,
      lease_owner=NULL,lease_expires_at=NULL WHERE id=?1 AND EXISTS(SELECT 1 FROM catalog_backfill_evidence_v4 WHERE evidence_id=?5)`)
      .bind(input.workItemId, isTerminalCandidate ? "succeeded" : input.outcome === "challenged" ? "blocked_challenge" : "needs_operator",
        resultJson, documentHash, evidenceId),
    db.prepare(`UPDATE catalog_backfill_cells_v4 SET evidence_state=?4,updated_at=CURRENT_TIMESTAMP
      WHERE run_id=?1 AND commodity_id=?2 AND store_location_id=?3 AND EXISTS(SELECT 1 FROM catalog_backfill_evidence_v4 WHERE evidence_id=?5)`)
      .bind(payload.runId, payload.commodityId, payload.storeLocationId,
        isTerminalCandidate ? "producer_ready" : input.outcome === "challenged" ? "challenged" : "needs_operator", evidenceId),
  ];
  if (isTerminalCandidate) {
    statements.push(db.prepare(`INSERT INTO pipeline_agent_work_items_v4
      (id,agent_id,entity_type,entity_id,dedupe_key,priority,state,input_ref_hash,correlation_id,input_json)
      SELECT ?1,?2,'catalog_backfill_cell',?3,?4,50,'queued',?5,?6,?7
      WHERE EXISTS(SELECT 1 FROM catalog_backfill_evidence_v4 WHERE evidence_id=?8) ON CONFLICT(dedupe_key) DO NOTHING`)
      .bind(verifierWorkId, verifierAgent, payload.ingredientId, verifierDedupe, verifierInputHash, payload.runId, verifierInput, evidenceId));
    statements.push(db.prepare(`UPDATE catalog_backfill_cells_v4 SET verifier_work_item_id=?4 WHERE run_id=?1 AND commodity_id=?2
      AND store_location_id=?3 AND EXISTS(SELECT 1 FROM catalog_backfill_evidence_v4 WHERE evidence_id=?5)`)
      .bind(payload.runId, payload.commodityId, payload.storeLocationId, verifierWorkId, evidenceId));
  }
  await db.batch(statements);
  const stored = await db.prepare("SELECT evidence_id FROM catalog_backfill_evidence_v4 WHERE evidence_id=?1").bind(evidenceId).first();
  if (!stored) throw new Error("producer evidence rejected by lease fence");
  return { evidenceId, documentHash, outcome: input.outcome, verifierWorkItemId: isTerminalCandidate ? verifierWorkId : null };
}

export async function submitCatalogBackfillVerifier(db: D1Database, input: BackfillEvidenceSubmission) {
  const work = await db.prepare(`SELECT * FROM pipeline_agent_work_items_v4 WHERE id=?1 AND entity_type='catalog_backfill_cell'`)
    .bind(input.workItemId).first<Record<string, unknown>>();
  if (!work || !String(work.agent_id).startsWith("omaha-price-verifier-")) throw new Error("verifier backfill work item is missing");
  const payload = JSON.parse(String(work.input_json)) as Record<string, string>;
  const storeLocationId = String(payload.storeLocationId ?? "");
  const producerOutcome = String(payload.producerOutcome ?? "");
  if (!payload.runId || !payload.commodityId || !payload.producerEvidenceId || !storeLocationId) throw new Error("verifier work item payload is incomplete");
  assertFreshBackfillEvidence(storeLocationId, input);
  if (!["priced", "not_found"].includes(producerOutcome) || input.outcome !== producerOutcome) {
    if (!['ambiguous','challenged'].includes(input.outcome)) throw new Error("verifier outcome does not match the frozen producer outcome");
  }
  const producer = await db.prepare(`SELECT document_hash,generation_id,session_id,observed_at FROM catalog_backfill_evidence_v4
    WHERE evidence_id=?1 AND kind='producer'`).bind(payload.producerEvidenceId)
    .first<{ document_hash: string; generation_id: string; session_id: string; observed_at: string }>();
  if (!producer) throw new Error("verifier work item is not bound to producer evidence");
  const documentJson = stableJson(input.document);
  const documentHash = await digestHex(documentJson);
  assertIndependentBackfillEvidence({ producer: { documentHash: producer.document_hash, generationId: producer.generation_id,
    sessionId: producer.session_id, observedAt: producer.observed_at }, verifier: { documentHash, generationId: input.generationId,
    sessionId: input.sessionId, observedAt: input.observedAt } });
  const evidenceId = await deterministicId("catalog-backfill-evidence", input.workItemId, "verifier", documentHash);
  const terminal = input.outcome === "priced" || input.outcome === "not_found";
  const terminalJson = stableJson({ outcome: input.outcome, producerEvidenceId: payload.producerEvidenceId,
    verifierEvidenceId: evidenceId, producerDocumentHash: producer.document_hash, verifierDocumentHash: documentHash,
    verifiedAt: input.observedAt, document: input.document });
  const terminalHash = await digestHex(terminalJson);
  await db.batch([
    db.prepare(`INSERT INTO catalog_backfill_evidence_v4
      (evidence_id,run_id,commodity_id,store_location_id,work_item_id,kind,generation_id,session_id,source_url,observed_at,document_json,document_hash)
      SELECT ?1,?2,?3,?4,id,'verifier',?5,?6,?7,?8,?9,?10 FROM pipeline_agent_work_items_v4
      WHERE id=?11 AND lease_owner=?12 AND lease_generation=?13 AND state IN ('claimed','running') AND lease_expires_at>CURRENT_TIMESTAMP
      ON CONFLICT(work_item_id) DO NOTHING`).bind(evidenceId, payload.runId, payload.commodityId, payload.storeLocationId,
        input.generationId, input.sessionId, input.sourceUrl, input.observedAt, documentJson, documentHash,
        input.workItemId, input.owner, input.leaseGeneration),
    db.prepare(`UPDATE pipeline_agent_work_items_v4 SET state=?2,result_json=?3,result_ref_hash=?4,terminal_at=CURRENT_TIMESTAMP,
      lease_owner=NULL,lease_expires_at=NULL WHERE id=?1 AND EXISTS(SELECT 1 FROM catalog_backfill_evidence_v4 WHERE evidence_id=?5)`)
      .bind(input.workItemId, terminal ? "succeeded" : input.outcome === "challenged" ? "blocked_challenge" : "needs_operator",
        terminalJson, terminalHash, evidenceId),
    db.prepare(`UPDATE catalog_backfill_cells_v4 SET evidence_state=?4,terminal_result_json=?5,terminal_result_hash=?6,updated_at=CURRENT_TIMESTAMP
      WHERE run_id=?1 AND commodity_id=?2 AND store_location_id=?3 AND evidence_state='producer_ready'
        AND EXISTS(SELECT 1 FROM catalog_backfill_evidence_v4 WHERE evidence_id=?7)`)
      .bind(payload.runId, payload.commodityId, payload.storeLocationId,
        terminal ? "terminal_verified" : input.outcome === "challenged" ? "challenged" : "needs_operator",
        terminal ? terminalJson : null, terminal ? terminalHash : null, evidenceId),
    db.prepare(`UPDATE catalog_backfill_ingredients_v4 SET terminal_evidence_count=(SELECT COUNT(*) FROM catalog_backfill_cells_v4 cell
      WHERE cell.run_id=?1 AND cell.commodity_id=?2 AND cell.evidence_state='terminal_verified'),updated_at=CURRENT_TIMESTAMP
      WHERE run_id=?1 AND commodity_id=?2`).bind(payload.runId, payload.commodityId),
  ]);
  const stored = await db.prepare("SELECT evidence_id FROM catalog_backfill_evidence_v4 WHERE evidence_id=?1").bind(evidenceId).first();
  if (!stored) throw new Error("verifier evidence rejected by lease fence");
  return { evidenceId, documentHash, terminalHash: terminal ? terminalHash : null, outcome: input.outcome };
}
