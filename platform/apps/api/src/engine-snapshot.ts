import { deterministicId, digestHex, stableJson } from "@thriftycrew/domain";
import {
  encodeNativeEngineCandidateShard,
  encodeNativeEngineSnapshotCandidates,
  type NativeEngineCandidateShard,
  type NativeEngineSnapshot,
} from "@thriftycrew/engine";
import type { WorkerEnv } from "./env";

export type EngineSourceMode = "legacy" | "direct" | "all";
export type EngineSnapshotProfile = "release" | "parity";

const SHARD_SCHEMA_VERSION = 2;

interface EngineSnapshotBatch {
  id: string;
  source_id: string;
  coverage_mode: string;
  captured_to: string;
  capture_method: string;
  match_run_id: string;
  match_input_hash: string;
}

interface EngineSnapshotContext {
  observedAt: string;
  mode: EngineSourceMode;
  configurationId: string;
  configurationHash: string;
  currentReleaseId: string;
  inputHash: string;
  inputBatchIds: string[];
  batches: EngineSnapshotBatch[];
}

interface EngineSnapshotShardRow {
  batch_id: string;
  configuration_id: string;
  match_run_id: string;
  match_input_hash: string;
  content_hash: string;
  object_key: string;
  matched_candidates: number;
  unmatched_candidates: number;
  byte_length: number;
  schema_version: number;
  status: "verified" | "collected";
}

interface KnownWrongLookupRule {
  commodity_id: string;
  store_location_id: string | null;
  external_product_key: string | null;
  normalized_name: string | null;
}

export function snapshotIncludesRawCandidates(profile: EngineSnapshotProfile): boolean {
  return profile === "release";
}

export function partitionSnapshotCandidateRows<T extends { commodity_id?: unknown }>(rows: readonly T[], includeRaw: boolean) {
  const candidates: T[] = [];
  const unmatchedRawCandidates: T[] = [];
  for (const row of rows) {
    if (row.commodity_id !== null && row.commodity_id !== undefined && String(row.commodity_id) !== "") candidates.push(row);
    else if (includeRaw) unmatchedRawCandidates.push(row);
  }
  return { candidates, unmatchedRawCandidates };
}

function modePredicate(mode: EngineSourceMode): string {
  if (mode === "legacy") return "s.capture_method = 'legacy_bridge'";
  if (mode === "direct") return "s.capture_method <> 'legacy_bridge'";
  return "1 = 1";
}

export function markKnownWrongCandidates<T extends {
  commodity_id: unknown; store_location_id: unknown; external_key: unknown; normalized_name?: unknown;
}>(candidates: readonly T[], rules: readonly KnownWrongLookupRule[]): Array<T & { known_wrong: number }> {
  const externalKnownWrong = new Set<string>();
  const nameKnownWrong = new Set<string>();
  for (const rule of rules) {
    const scope = rule.store_location_id ?? "*";
    if (rule.external_product_key) externalKnownWrong.add(stableJson([rule.commodity_id, scope, rule.external_product_key]));
    if (rule.normalized_name) nameKnownWrong.add(stableJson([rule.commodity_id, scope, rule.normalized_name]));
  }
  return candidates.map((candidate) => {
    const commodityId = String(candidate.commodity_id);
    const storeLocationId = String(candidate.store_location_id);
    const externalKey = String(candidate.external_key);
    const normalizedName = String(candidate.normalized_name ?? "");
    const scopedKeys = [storeLocationId, "*"];
    const knownWrong = scopedKeys.some((scope) =>
      externalKnownWrong.has(stableJson([commodityId, scope, externalKey]))
      || nameKnownWrong.has(stableJson([commodityId, scope, normalizedName])));
    return { ...candidate, known_wrong: knownWrong ? 1 : 0 };
  });
}

async function readEngineSnapshotContext(env: WorkerEnv, mode: EngineSourceMode, requestedObservedAt?: string): Promise<EngineSnapshotContext> {
  const observedAt = requestedObservedAt ?? new Date().toISOString();
  if (!Number.isFinite(Date.parse(observedAt))) throw new Error("Engine snapshot observedAt is invalid");
  const [configuration, currentRelease] = await Promise.all([
    env.DB.prepare("SELECT id, content_hash FROM configuration_versions WHERE active = 1")
      .first<{ id: string; content_hash: string }>(),
    env.DB.prepare("SELECT release_id FROM current_releases WHERE market_id = 'omaha'")
      .first<{ release_id: string }>(),
  ]);
  if (!configuration) throw new Error("No active engine configuration");
  if (!currentRelease) throw new Error("No current Omaha release");
  const batches = await env.DB.prepare(
    `WITH selected_batches AS (
       SELECT id, source_id, coverage_mode, captured_to, capture_method FROM (
         SELECT b.id, b.source_id, b.coverage_mode, b.captured_to, s.capture_method,
                ROW_NUMBER() OVER (PARTITION BY b.source_id ORDER BY b.captured_to DESC, b.promoted_at DESC, b.id DESC) AS ordinal
           FROM capture_batches b JOIN capture_sources s ON s.id = b.source_id
          WHERE b.status IN ('promoted','superseded') AND ${modePredicate(mode)}
            AND (b.valid_from IS NULL OR b.valid_from <= ?2)
            AND (b.valid_to IS NULL OR b.valid_to > ?2)
       ) WHERE ordinal = 1
     ), ranked_runs AS (
       SELECT run.batch_id, run.id AS match_run_id, run.input_hash AS match_input_hash,
              ROW_NUMBER() OVER (PARTITION BY run.batch_id ORDER BY run.created_at DESC, run.id DESC) AS ordinal
         FROM match_runs run
        WHERE run.configuration_id = ?1 AND run.status = 'passed'
     )
     SELECT batch.id, batch.source_id, batch.coverage_mode, batch.captured_to, batch.capture_method,
            run.match_run_id, run.match_input_hash
       FROM selected_batches batch
       LEFT JOIN ranked_runs run ON run.batch_id = batch.id AND run.ordinal = 1
      ORDER BY batch.source_id`,
  ).bind(configuration.id, observedAt).all<EngineSnapshotBatch>();
  if (batches.results.length === 0) throw new Error(`No promoted ${mode} capture batches`);
  const unbound = batches.results.filter((batch) => !batch.match_run_id || !batch.match_input_hash);
  if (unbound.length > 0) throw new Error(`Promoted snapshot batches lack a passed match run: ${unbound.map((batch) => batch.id).join(", ")}`);
  const inputBatchIds = batches.results.map((batch) => batch.id).sort();
  const dateParts = Object.fromEntries(new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Chicago", year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(new Date(observedAt)).map((part) => [part.type, part.value]));
  const inputHash = await digestHex(stableJson({
    configurationId: configuration.id,
    configurationHash: configuration.content_hash,
    mode,
    pricingDate: `${dateParts.year}-${dateParts.month}-${dateParts.day}`,
    inputBatchIds,
    shardSchemaVersion: SHARD_SCHEMA_VERSION,
    matchRuns: batches.results.map((batch) => [batch.id, batch.match_run_id, batch.match_input_hash]),
  }));
  return {
    observedAt, mode, configurationId: configuration.id, configurationHash: configuration.content_hash,
    currentReleaseId: currentRelease.release_id, inputHash, inputBatchIds, batches: batches.results,
  };
}

export async function readEngineSnapshotIdentity(env: WorkerEnv, mode: EngineSourceMode, observedAt?: string) {
  const context = await readEngineSnapshotContext(env, mode, observedAt);
  const { configurationHash: _configurationHash, ...identity } = context;
  return identity;
}

async function readCandidateRows(env: WorkerEnv, configurationId: string, batchIds: readonly string[]) {
  if (batchIds.length === 0) return [];
  const placeholders = batchIds.map((_, index) => `?${index + 2}`).join(",");
  const rows = await env.DB.prepare(
    `SELECT o.id AS observation_id, m.commodity_id, p.store_location_id, o.per_unit_micros,
            member.observed_at AS captured_at, o.valid_from, o.valid_to, b.coverage_mode, b.captured_to, b.id AS batch_id,
            o.normalized_basis_unit, o.normalized_basis_qty_micros, o.purchase_price_minor, o.regular_price_minor, o.kind,
            o.purchase_quantity, o.package_count, pv.size_text,
            o.membership_required, o.loyalty_required, o.raw_price_text, pv.name, pv.normalized_name, pv.product_url,
            pv.taxonomy_path, p.external_key, o.basis_options_json,
            CAST(COALESCE(json_extract(s.coverage_policy_json, '$.max_age_days'), 14) AS INTEGER) AS max_age_days
       FROM capture_batch_observations member
       JOIN observations o ON o.id = member.observation_id
       JOIN capture_batches b ON b.id = member.batch_id
       JOIN capture_sources s ON s.id = b.source_id
       JOIN product_versions pv ON pv.id = o.product_version_id
       JOIN products p ON p.id = pv.product_id
       LEFT JOIN match_decisions m ON m.product_id = p.id AND m.configuration_id = ?1 AND m.superseded_at IS NULL
      WHERE member.batch_id IN (${placeholders})
      ORDER BY b.id, p.store_location_id, o.per_unit_micros, o.id`,
  ).bind(configurationId, ...batchIds).all<Record<string, unknown> & { commodity_id?: unknown }>();
  return rows.results;
}

async function readKnownWrongRules(env: WorkerEnv, configurationId: string) {
  return (await env.DB.prepare(
    `SELECT commodity_id, store_location_id, external_product_key, normalized_name
       FROM known_wrong_rules WHERE configuration_id = ?1 ORDER BY commodity_id, id`,
  ).bind(configurationId).all<KnownWrongLookupRule>()).results;
}

function shardObjectKey(configurationId: string, batchId: string, contentHash: string): string {
  return `engine-snapshots/schema=${SHARD_SCHEMA_VERSION}/config=${configurationId}/batch=${batchId}/prefix=${contentHash.slice(0, 2)}/${contentHash}.json`;
}

async function verifiedShardObject(env: WorkerEnv, row: EngineSnapshotShardRow): Promise<boolean> {
  if (row.status !== "verified" || row.schema_version !== SHARD_SCHEMA_VERSION) return false;
  const object = await env.ARCHIVE.head(row.object_key);
  return Boolean(object && object.size === row.byte_length && object.customMetadata?.sha256 === row.content_hash);
}

export async function buildEngineSnapshotShard(env: WorkerEnv, batchId: string, mode: EngineSourceMode = "direct", observedAt?: string) {
  const context = await readEngineSnapshotContext(env, mode, observedAt);
  const batch = context.batches.find((candidate) => candidate.id === batchId);
  if (!batch) throw new Error(`Batch ${batchId} is not selected by the current ${mode} snapshot`);
  const existing = await env.DB.prepare(
    `SELECT batch_id, configuration_id, match_run_id, match_input_hash, content_hash, object_key,
            matched_candidates, unmatched_candidates, byte_length, schema_version, status
       FROM engine_snapshot_shards_v2 WHERE batch_id = ?1 AND configuration_id = ?2 AND match_run_id = ?3`,
  ).bind(batch.id, context.configurationId, batch.match_run_id).first<EngineSnapshotShardRow>();
  if (existing && await verifiedShardObject(env, existing)) return { ok: true, idempotent: true, shard: existing };

  const [candidateRows, knownWrongRules] = await Promise.all([
    readCandidateRows(env, context.configurationId, [batch.id]),
    readKnownWrongRules(env, context.configurationId),
  ]);
  const partitioned = partitionSnapshotCandidateRows(candidateRows, true);
  const matched = markKnownWrongCandidates(
    partitioned.candidates as Array<Record<string, unknown> & { commodity_id: unknown; store_location_id: unknown; external_key: unknown }>,
    knownWrongRules,
  );
  const shard = encodeNativeEngineCandidateShard({
    batchId: batch.id, configurationId: context.configurationId, matchRunId: batch.match_run_id,
    matchInputHash: batch.match_input_hash, candidates: matched, rawCandidates: partitioned.unmatchedRawCandidates,
  });
  const bytes = new TextEncoder().encode(stableJson(shard));
  const contentHash = await digestHex(bytes);
  const objectKey = shardObjectKey(context.configurationId, batch.id, contentHash);
  if (existing && existing.schema_version === SHARD_SCHEMA_VERSION && (existing.content_hash !== contentHash || existing.object_key !== objectKey || existing.byte_length !== bytes.byteLength)) {
    throw new Error(`Engine snapshot shard drifted without a new match run: ${batch.id}`);
  }
  await env.ARCHIVE.put(objectKey, bytes, { customMetadata: {
    sha256: contentHash, schema: String(SHARD_SCHEMA_VERSION), batchId: batch.id,
    configurationId: context.configurationId, matchRunId: batch.match_run_id,
  } });
  const uploaded = await env.ARCHIVE.get(objectKey);
  if (!uploaded || uploaded.size !== bytes.byteLength || await digestHex(new Uint8Array(await uploaded.arrayBuffer())) !== contentHash) {
    throw new Error(`Engine snapshot shard failed read-after-write verification: ${batch.id}`);
  }
  const shardId = await deterministicId("engine-snapshot-shard", batch.id, context.configurationId, batch.match_run_id);
  await env.DB.prepare(
    `INSERT INTO engine_snapshot_shards_v2
       (id, batch_id, configuration_id, match_run_id, match_input_hash, content_hash, object_key,
        matched_candidates, unmatched_candidates, byte_length, schema_version, status, verified_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 'verified', ?12)
     ON CONFLICT(batch_id, configuration_id, match_run_id) DO UPDATE SET
       content_hash = excluded.content_hash, object_key = excluded.object_key,
       matched_candidates = excluded.matched_candidates, unmatched_candidates = excluded.unmatched_candidates,
       byte_length = excluded.byte_length, schema_version = excluded.schema_version,
       status = 'verified', verified_at = excluded.verified_at, collected_at = NULL`,
  ).bind(shardId, batch.id, context.configurationId, batch.match_run_id, batch.match_input_hash, contentHash, objectKey,
    matched.length, partitioned.unmatchedRawCandidates.length, bytes.byteLength, SHARD_SCHEMA_VERSION, new Date().toISOString()).run();
  const row: EngineSnapshotShardRow = {
    batch_id: batch.id, configuration_id: context.configurationId, match_run_id: batch.match_run_id,
    match_input_hash: batch.match_input_hash, content_hash: contentHash, object_key: objectKey,
    matched_candidates: matched.length, unmatched_candidates: partitioned.unmatchedRawCandidates.length,
    byte_length: bytes.byteLength, schema_version: SHARD_SCHEMA_VERSION, status: "verified",
  };
  return { ok: true, idempotent: false, shard: row };
}

async function readSnapshotDimensions(env: WorkerEnv, context: EngineSnapshotContext) {
  const [commodities, stores, currentCells] = await Promise.all([
    env.DB.prepare(
      `SELECT c.id, c.label, c.basis_unit, c.category_id, c.band_min_micros, c.band_max_micros, cat.label AS category_label, cat.sort_order
         FROM commodities c LEFT JOIN categories cat ON cat.id = c.category_id
        WHERE c.configuration_id = ?1 AND c.active = 1 ORDER BY cat.sort_order, c.id`,
    ).bind(context.configurationId).all(),
    env.DB.prepare(
      `SELECT l.id, b.name AS store_name, l.display_name, b.membership_required
         FROM store_locations l JOIN store_brands b ON b.id = l.brand_id
        WHERE l.market_id = 'omaha' AND l.active = 1 ORDER BY l.id`,
    ).all(),
    env.DB.prepare(
      `SELECT c.commodity_id, c.store_location_id, c.observation_id, c.status, c.is_crown,
              c.display_per_unit_micros, c.display_unit
         FROM release_cells c WHERE c.release_id = ?1 ORDER BY c.commodity_id, c.store_location_id`,
    ).bind(context.currentReleaseId).all(),
  ]);
  return { commodities: commodities.results, stores: stores.results, currentCells: currentCells.results };
}

export async function readEngineSnapshotManifest(env: WorkerEnv, mode: EngineSourceMode, observedAt?: string) {
  const context = await readEngineSnapshotContext(env, mode, observedAt);
  const dimensions = await readSnapshotDimensions(env, context);
  const clauses = context.batches.map((_, index) => `(batch_id = ?${index * 3 + 1} AND configuration_id = ?${index * 3 + 2} AND match_run_id = ?${index * 3 + 3})`).join(" OR ");
  const bindings = context.batches.flatMap((batch) => [batch.id, context.configurationId, batch.match_run_id]);
  const rows = clauses ? await env.DB.prepare(
    `SELECT batch_id, configuration_id, match_run_id, match_input_hash, content_hash, object_key,
            matched_candidates, unmatched_candidates, byte_length, schema_version, status
       FROM engine_snapshot_shards_v2 WHERE ${clauses} ORDER BY batch_id`,
  ).bind(...bindings).all<EngineSnapshotShardRow>() : { results: [] as EngineSnapshotShardRow[] };
  const verification = await Promise.all(rows.results.map(async (row) => ({ row, verified: await verifiedShardObject(env, row) })));
  const verified = verification.filter((item) => item.verified).map((item) => item.row);
  const byBatch = new Map(verified.map((row) => [row.batch_id, row]));
  const { configurationHash: _configurationHash, ...identity } = context;
  return {
    ok: true, version: 1, transportEncoding: "r2-shards-v1" as const, shardSchemaVersion: SHARD_SCHEMA_VERSION,
    ...identity, ...dimensions, shards: context.batches.flatMap((batch) => byBatch.has(batch.id) ? [byBatch.get(batch.id)!] : []),
    missingBatchIds: context.batches.filter((batch) => !byBatch.has(batch.id)).map((batch) => batch.id),
  };
}

export async function readEngineSnapshotShard(env: WorkerEnv, batchId: string, configurationId: string, matchRunId: string): Promise<NativeEngineCandidateShard> {
  const row = await env.DB.prepare(
    `SELECT batch_id, configuration_id, match_run_id, match_input_hash, content_hash, object_key,
            matched_candidates, unmatched_candidates, byte_length, schema_version, status
       FROM engine_snapshot_shards_v2 WHERE batch_id = ?1 AND configuration_id = ?2 AND match_run_id = ?3`,
  ).bind(batchId, configurationId, matchRunId).first<EngineSnapshotShardRow>();
  if (!row || row.status !== "verified") throw new Error("Engine snapshot shard is not available");
  const object = await env.ARCHIVE.get(row.object_key);
  if (!object || object.size !== row.byte_length) throw new Error("Engine snapshot shard object is missing or has the wrong size");
  const bytes = new Uint8Array(await object.arrayBuffer());
  if (await digestHex(bytes) !== row.content_hash) throw new Error("Engine snapshot shard object failed content verification");
  const shard = JSON.parse(new TextDecoder().decode(bytes)) as NativeEngineCandidateShard;
  if (shard.batchId !== batchId || shard.configurationId !== configurationId || shard.matchRunId !== matchRunId
    || shard.matchInputHash !== row.match_input_hash) throw new Error("Engine snapshot shard identity verification failed");
  return shard;
}

export async function readEngineSnapshot(env: WorkerEnv, mode: EngineSourceMode, profile: EngineSnapshotProfile = "release", observedAt?: string) {
  const context = await readEngineSnapshotContext(env, mode, observedAt);
  const [candidateRows, knownWrongRules, dimensions] = await Promise.all([
    readCandidateRows(env, context.configurationId, context.inputBatchIds),
    readKnownWrongRules(env, context.configurationId),
    readSnapshotDimensions(env, context),
  ]);
  const includeRaw = snapshotIncludesRawCandidates(profile);
  const partitioned = partitionSnapshotCandidateRows(candidateRows, includeRaw);
  const markedCandidates = markKnownWrongCandidates(
    partitioned.candidates as Array<Record<string, unknown> & { commodity_id: unknown; store_location_id: unknown; external_key: unknown }>,
    knownWrongRules,
  );
  const { configurationHash: _configurationHash, ...identity } = context;
  return encodeNativeEngineSnapshotCandidates({
    ok: true, ...identity, ...dimensions, candidates: markedCandidates,
    rawCandidateEncoding: includeRaw ? "unmatched-only" : "omitted",
    rawCandidates: partitioned.unmatchedRawCandidates,
  } as unknown as NativeEngineSnapshot);
}
