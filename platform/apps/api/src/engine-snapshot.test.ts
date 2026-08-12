import { describe, expect, it } from "vitest";
import { markKnownWrongCandidates, partitionSnapshotCandidateRows } from "./engine-snapshot";

describe("engine snapshot known-wrong projection", () => {
  it("applies global and store-specific rulings without a correlated database scan", () => {
    const candidates = [
      { id: "global-external", commodity_id: "milk", store_location_id: "a", external_key: "bad-sku", normalized_name: "milk" },
      { id: "global-name", commodity_id: "milk", store_location_id: "b", external_key: "other", normalized_name: "cat milk" },
      { id: "scoped-hit", commodity_id: "milk", store_location_id: "a", external_key: "scoped", normalized_name: "milk" },
      { id: "scoped-miss", commodity_id: "milk", store_location_id: "b", external_key: "scoped", normalized_name: "milk" },
      { id: "other-commodity", commodity_id: "cream", store_location_id: "a", external_key: "bad-sku", normalized_name: "cat milk" },
    ];
    const marked = markKnownWrongCandidates(candidates, [
      { commodity_id: "milk", store_location_id: null, external_product_key: "bad-sku", normalized_name: null },
      { commodity_id: "milk", store_location_id: null, external_product_key: null, normalized_name: "cat milk" },
      { commodity_id: "milk", store_location_id: "a", external_product_key: "scoped", normalized_name: null },
    ]);
    expect(marked.map((candidate) => [candidate.id, candidate.known_wrong])).toEqual([
      ["global-external", 1],
      ["global-name", 1],
      ["scoped-hit", 1],
      ["scoped-miss", 0],
      ["other-commodity", 0],
    ]);
  });
});

describe("engine snapshot compact raw encoding", () => {
  it("sends matched rows once and retains every unmatched recipe candidate", () => {
    const rows = [
      { observation_id: "matched", commodity_id: "milk" },
      { observation_id: "unmatched", commodity_id: null },
    ];
    expect(partitionSnapshotCandidateRows(rows, true)).toEqual({
      candidates: [rows[0]],
      unmatchedRawCandidates: [rows[1]],
    });
    expect(partitionSnapshotCandidateRows(rows, false)).toEqual({ candidates: [rows[0]], unmatchedRawCandidates: [] });
  });
});
