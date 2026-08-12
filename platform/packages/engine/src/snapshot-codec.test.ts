import { describe, expect, it } from "vitest";
import {
  decodeNativeEngineCandidateShard,
  decodeNativeEngineSnapshot,
  encodeNativeEngineCandidateShard,
  encodeNativeEngineSnapshotCandidates,
  isEngineSnapshotEncoding,
  type NativeEngineSnapshot,
} from "./index";

describe("engine snapshot tuple transport", () => {
  it("round trips matched and unmatched candidates without semantic loss", () => {
    const snapshot = {
      mode: "direct", observedAt: "2026-08-12T00:00:00.000Z", configurationId: "cfg", currentReleaseId: "rel",
      inputHash: "a".repeat(64), inputBatchIds: ["batch"], commodities: [], stores: [], currentCells: [],
      candidates: [{ observation_id: "matched", commodity_id: "milk", store_location_id: "store", per_unit_micros: 1,
        captured_at: "2026-08-12T00:00:00.000Z", valid_to: null, coverage_mode: "full", captured_to: "2026-08-12T00:00:00.000Z",
        normalized_basis_unit: "oz", known_wrong: 0 }],
      rawCandidates: [{ observation_id: "raw", store_location_id: "store", per_unit_micros: 2,
        captured_at: "2026-08-12T00:00:00.000Z", valid_to: null, coverage_mode: "full", captured_to: "2026-08-12T00:00:00.000Z",
        normalized_basis_unit: "oz", name: "Raw" }], rawCandidateEncoding: "unmatched-only",
    } satisfies NativeEngineSnapshot;
    const decoded = decodeNativeEngineSnapshot(encodeNativeEngineSnapshotCandidates(snapshot));
    expect(decoded.candidates[0]!).toMatchObject(snapshot.candidates[0]!);
    expect(decoded.rawCandidates?.[0]).toMatchObject(snapshot.rawCandidates[0]!);
    expect(decoded.transportEncoding).toBe("tuples-v1");
  });

  it("accepts current and legacy measurement encodings", () => {
    expect(isEngineSnapshotEncoding("tuples-v1")).toBe(true);
    expect(isEngineSnapshotEncoding("r2-shards-v1")).toBe(true);
    expect(isEngineSnapshotEncoding("unmatched-only")).toBe(true);
    expect(isEngineSnapshotEncoding("tuples-v2")).toBe(false);
  });

  it("round trips independently verifiable candidate shards", () => {
    const encoded = encodeNativeEngineCandidateShard({
      batchId: "batch", configurationId: "cfg", matchRunId: "match", matchInputHash: "a".repeat(64),
      candidates: [{ observation_id: "matched", commodity_id: "milk", store_location_id: "store", known_wrong: 0 }],
      rawCandidates: [{ observation_id: "raw", commodity_id: null, store_location_id: "store" }],
    });
    expect(decodeNativeEngineCandidateShard(encoded)).toEqual({
      candidates: [expect.objectContaining({ observation_id: "matched", commodity_id: "milk", known_wrong: 0 })],
      rawCandidates: [expect.objectContaining({ observation_id: "raw", commodity_id: null })],
    });
    expect(() => decodeNativeEngineCandidateShard({ ...encoded, matchedCandidateRows: [["too-short"]] })).toThrow(/wrong width/);
  });
});
