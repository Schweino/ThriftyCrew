export interface StoreGenerationStart {
  generationId: string; storeLocationId: string; fulfillmentMode: string; sessionKind: "producer" | "verifier";
  adapterVersion: string; coverageKind: "full" | "targeted"; startedAt: string;
}

export async function startStoreCatalogGeneration(db: D1Database, input: StoreGenerationStart) {
  await db.prepare(
    `INSERT INTO store_catalog_generations
       (generation_id, store_location_id, fulfillment_mode, session_kind, adapter_version, coverage_kind, started_at, status)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'running')`,
  ).bind(input.generationId, input.storeLocationId, input.fulfillmentMode, input.sessionKind,
    input.adapterVersion, input.coverageKind, input.startedAt).run();
}

export async function completeStoreCatalogGeneration(db: D1Database, input: {
  generationId: string; resultCount: number; coverageCount: number; coverageHash: string; rawManifestKey: string; completedAt: string;
}) {
  const result = await db.prepare(
    `UPDATE store_catalog_generations SET status = 'complete', result_count = ?2, coverage_count = ?3,
       coverage_hash = ?4, raw_manifest_key = ?5, completed_at = ?6
     WHERE generation_id = ?1 AND status = 'running'`,
  ).bind(input.generationId, input.resultCount, input.coverageCount, input.coverageHash, input.rawManifestKey, input.completedAt).run();
  if ((result.meta.changes ?? 0) !== 1) throw new Error("store generation completion lost its state fence");
}

export async function claimPipelineAgentWork(db: D1Database, input: {
  agentId: string; owner: string; now: string; leaseExpiresAt: string; limit: number;
}) {
  const candidates = await db.prepare(
    `SELECT id FROM pipeline_agent_work_items_v4
      WHERE agent_id = ?1 AND available_at <= ?3
        AND (state IN ('queued','failed_transient') OR (state IN ('claimed','running') AND lease_expires_at < ?3))
      ORDER BY priority, available_at, id LIMIT ?2`,
  ).bind(input.agentId, Math.min(50, Math.max(1, input.limit)), input.now).all<{ id: string }>();
  const claimed: string[] = [];
  for (const row of candidates.results) {
    const result = await db.prepare(
      `UPDATE pipeline_agent_work_items_v4
          SET state = 'claimed', lease_owner = ?2, lease_generation = lease_generation + 1,
              lease_expires_at = ?3, attempt_count = attempt_count + 1,
              started_at = COALESCE(started_at, ?4), heartbeat_at = ?4
        WHERE id = ?1 AND (state IN ('queued','failed_transient') OR (state IN ('claimed','running') AND lease_expires_at < ?4))`,
    ).bind(row.id, input.owner, input.leaseExpiresAt, input.now).run();
    if ((result.meta.changes ?? 0) === 1) claimed.push(row.id);
  }
  if (claimed.length === 0) return [];
  const placeholders = claimed.map((_, index) => `?${index + 1}`).join(",");
  return (await db.prepare(`SELECT * FROM pipeline_agent_work_items_v4 WHERE id IN (${placeholders}) ORDER BY priority, id`).bind(...claimed).all()).results;
}
