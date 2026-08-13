import type { MutationClient } from "@thriftycrew/daily/client";
import { digestHex, stableJson } from "@thriftycrew/domain";
import { encodeNativeEngineCandidateShard } from "@thriftycrew/engine";
import { describe, expect, it } from "vitest";
import { loadR2ShardedEngineSnapshot } from "./engine-snapshot";

describe("R2-sharded engine snapshot loader", () => {
  it("builds missing immutable shards, verifies hashes, and reconstructs the snapshot", async () => {
    const shard = encodeNativeEngineCandidateShard({
      batchId: "batch", configurationId: "cfg", matchRunId: "match", matchInputHash: "a".repeat(64),
      candidates: [{ observation_id: "matched", commodity_id: "milk", store_location_id: "store", known_wrong: 0 }],
      rawCandidates: [{ observation_id: "raw", commodity_id: null, store_location_id: "store" }],
    });
    const contentHash = await digestHex(stableJson(shard));
    const descriptor = {
      batch_id: "batch", configuration_id: "cfg", match_run_id: "match", match_input_hash: "a".repeat(64),
      content_hash: contentHash, matched_candidates: 1, unmatched_candidates: 1,
      byte_length: new TextEncoder().encode(stableJson(shard)).byteLength, schema_version: 1, status: "verified",
    };
    const base = {
      ok: true, version: 1, shardSchemaVersion: 2, transportEncoding: "r2-shards-v1", mode: "direct",
      observedAt: "2026-08-12T00:00:00Z", configurationId: "cfg", currentReleaseId: "rel",
      inputHash: "b".repeat(64), inputBatchIds: ["batch"], commodities: [], stores: [], currentCells: [],
      batches: [{ id: "batch", source_id: "source", coverage_mode: "full", captured_to: "2026-08-12T00:00:00Z",
        capture_method: "api", match_run_id: "match", match_input_hash: "a".repeat(64) }],
    };
    let built = false;
    const client = { request: async (pathname: string) => {
      if (pathname.includes("/build")) { built = true; return { ok: true }; }
      if (pathname.startsWith("/internal/engine/snapshot-manifest")) return { ...base, shards: built ? [descriptor] : [], missingBatchIds: built ? [] : ["batch"] };
      if (pathname.startsWith("/internal/engine/snapshot-shards/")) return { ...shard, httpStatus: 200 };
      throw new Error(`unexpected path ${pathname}`);
    } } as unknown as MutationClient;
    const snapshot = await loadR2ShardedEngineSnapshot(client, "direct");
    expect(built).toBe(true);
    expect(snapshot.transportEncoding).toBe("r2-shards-v1");
    expect(snapshot.candidates[0]).toMatchObject({ observation_id: "matched", commodity_id: "milk" });
    expect(snapshot.rawCandidates?.[0]).toMatchObject({ observation_id: "raw" });
  });

  it("rejects content that does not match the catalog hash", async () => {
    const shard = encodeNativeEngineCandidateShard({
      batchId: "batch", configurationId: "cfg", matchRunId: "match", matchInputHash: "a".repeat(64), candidates: [], rawCandidates: [],
    });
    const client = { request: async (pathname: string) => pathname.includes("snapshot-manifest") ? {
      ok: true, version: 1, shardSchemaVersion: 2, transportEncoding: "r2-shards-v1", mode: "direct",
      observedAt: "2026-08-12T00:00:00Z", configurationId: "cfg", currentReleaseId: "rel", inputHash: "b".repeat(64),
      inputBatchIds: ["batch"], commodities: [], stores: [], currentCells: [], missingBatchIds: [],
      batches: [{ id: "batch", source_id: "source", coverage_mode: "full", captured_to: "2026-08-12T00:00:00Z",
        capture_method: "api", match_run_id: "match", match_input_hash: "a".repeat(64) }],
      shards: [{ batch_id: "batch", configuration_id: "cfg", match_run_id: "match", match_input_hash: "a".repeat(64),
        content_hash: "f".repeat(64), matched_candidates: 0, unmatched_candidates: 0, byte_length: 1, schema_version: 1, status: "verified" }],
    } : { ...shard, httpStatus: 200 } } as unknown as MutationClient;
    await expect(loadR2ShardedEngineSnapshot(client, "direct")).rejects.toThrow(/hash mismatch/);
  });
});
