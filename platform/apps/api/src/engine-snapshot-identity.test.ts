import { describe, expect, it } from "vitest";
import { materializedSnapshotInputHash } from "./engine-snapshot";

describe("materialized engine snapshot identity", () => {
  it("binds release identity to immutable shard contents independent of response order", async () => {
    const left = { batch_id: "batch-a", match_run_id: "match-a", content_hash: "a".repeat(64) };
    const right = { batch_id: "batch-b", match_run_id: "match-b", content_hash: "b".repeat(64) };
    const ordered = await materializedSnapshotInputHash("c".repeat(64), [left, right]);
    expect(await materializedSnapshotInputHash("c".repeat(64), [right, left])).toBe(ordered);
    expect(await materializedSnapshotInputHash("c".repeat(64), [left, { ...right, content_hash: "d".repeat(64) }])).not.toBe(ordered);
  });
});
