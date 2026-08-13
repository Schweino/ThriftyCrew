import type { MutationClient } from "@thriftycrew/daily/client";
import { digestHex, stableJson } from "@thriftycrew/domain";
import {
  decodeNativeEngineCandidateShard,
  type NativeEngineCandidateShard,
  type NativeEngineSnapshot,
} from "@thriftycrew/engine";

type SnapshotMode = "legacy" | "direct" | "all";
type SnapshotProfile = "release" | "parity";

interface SnapshotShardDescriptor {
  batch_id: string;
  configuration_id: string;
  match_run_id: string;
  match_input_hash: string;
  content_hash: string;
  matched_candidates: number;
  unmatched_candidates: number;
  byte_length: number;
  schema_version: number;
  status: "verified";
}

interface SnapshotBatch {
  id: string;
  source_id: string;
  coverage_mode: string;
  captured_to: string;
  capture_method: string;
  match_run_id: string;
  match_input_hash: string;
}

interface SnapshotManifest extends Omit<NativeEngineSnapshot, "candidates" | "rawCandidates" | "rawCandidateEncoding"> {
  version: 1;
  shardSchemaVersion: 2;
  transportEncoding: "r2-shards-v1";
  batches: SnapshotBatch[];
  shards: SnapshotShardDescriptor[];
  missingBatchIds: string[];
  httpStatus?: number;
}

function withoutHttpStatus<T extends { httpStatus?: number }>(value: T): Omit<T, "httpStatus"> {
  const { httpStatus: _httpStatus, ...rest } = value;
  return rest;
}

async function mapConcurrent<T, R>(items: readonly T[], concurrency: number, work: (item: T) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(items.length);
  let cursor = 0;
  const worker = async () => {
    while (cursor < items.length) {
      const index = cursor++;
      results[index] = await work(items[index]!);
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, worker));
  return results;
}

async function manifest(client: MutationClient, mode: SnapshotMode, observedAt?: string): Promise<SnapshotManifest> {
  const query = new URLSearchParams({ mode });
  if (observedAt) query.set("observedAt", observedAt);
  return await client.request(`/internal/engine/snapshot-manifest?${query}`) as unknown as SnapshotManifest;
}

export async function loadR2ShardedEngineSnapshot(
  client: MutationClient,
  mode: SnapshotMode,
  profile: SnapshotProfile = "release",
  observedAt?: string,
): Promise<NativeEngineSnapshot> {
  let current = await manifest(client, mode, observedAt);
  if (current.version !== 1 || current.transportEncoding !== "r2-shards-v1" || current.shardSchemaVersion !== 2) {
    throw new Error("R2 engine snapshot manifest contract is unsupported");
  }
  if (current.missingBatchIds.length > 0) {
    await mapConcurrent(current.missingBatchIds, 4, async (batchId) => {
      const query = new URLSearchParams({ mode });
      if (observedAt) query.set("observedAt", observedAt);
      await client.request(`/internal/engine/snapshot-shards/${encodeURIComponent(batchId)}/build?${query}`, { method: "POST" });
    });
    current = await manifest(client, mode, observedAt);
  }
  if (current.missingBatchIds.length > 0) throw new Error(`R2 engine snapshot shards remain missing: ${current.missingBatchIds.join(", ")}`);
  if (current.shards.length !== current.batches.length) throw new Error("R2 engine snapshot manifest does not bind exactly one shard per batch");
  const shardByBatch = new Map(current.shards.map((shard) => [shard.batch_id, shard]));
  const ordered = current.batches.map((batch) => {
    const descriptor = shardByBatch.get(batch.id);
    if (!descriptor) throw new Error(`R2 engine snapshot manifest omitted batch ${batch.id}`);
    return descriptor;
  });
  const fetched = await mapConcurrent(ordered, 4, async (descriptor) => {
    const query = new URLSearchParams({ configurationId: descriptor.configuration_id, matchRunId: descriptor.match_run_id });
    const response = (await client.request(`/internal/engine/snapshot-shards/${encodeURIComponent(descriptor.batch_id)}?${query}`)) as unknown as NativeEngineCandidateShard & { httpStatus?: number };
    const shard = withoutHttpStatus(response) as NativeEngineCandidateShard;
    if (await digestHex(stableJson(shard)) !== descriptor.content_hash) throw new Error(`R2 engine snapshot shard hash mismatch: ${descriptor.batch_id}`);
    if (shard.batchId !== descriptor.batch_id || shard.configurationId !== descriptor.configuration_id
      || shard.matchRunId !== descriptor.match_run_id || shard.matchInputHash !== descriptor.match_input_hash) {
      throw new Error(`R2 engine snapshot shard identity mismatch: ${descriptor.batch_id}`);
    }
    const decoded = decodeNativeEngineCandidateShard(shard);
    if (decoded.candidates.length !== descriptor.matched_candidates || decoded.rawCandidates.length !== descriptor.unmatched_candidates) {
      throw new Error(`R2 engine snapshot shard row count mismatch: ${descriptor.batch_id}`);
    }
    return decoded;
  });
  const { version: _version, shardSchemaVersion: _shardSchemaVersion, shards: _shards,
    missingBatchIds: _missingBatchIds, httpStatus: _httpStatus, ...base } = current;
  const candidates = fetched.flatMap((shard) => shard.candidates) as NativeEngineSnapshot["candidates"];
  const rawCandidates = profile === "release"
    ? fetched.flatMap((shard) => shard.rawCandidates) as NonNullable<NativeEngineSnapshot["rawCandidates"]>
    : [];
  const manifestBytes = new TextEncoder().encode(stableJson(withoutHttpStatus(current))).byteLength;
  return {
    ...base,
    candidates,
    rawCandidates,
    rawCandidateEncoding: profile === "release" ? "unmatched-only" : "omitted",
    transportEncoding: "r2-shards-v1",
    transportBytes: manifestBytes + ordered.reduce((sum, shard) => sum + shard.byte_length, 0),
  } as NativeEngineSnapshot;
}
