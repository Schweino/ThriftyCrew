import { describe, expect, it } from "vitest";
import { selectGarbageObjects } from "./r2-gc";

describe("reference-aware R2 garbage collection", () => {
  it("selects only old unreachable objects in deterministic order", () => {
    const objects = [
      { bucket: "archive" as const, key: "reachable", size: 1, uploaded: "2026-01-01T00:00:00.000Z" },
      { bucket: "evidence" as const, key: "new", size: 2, uploaded: "2026-08-11T00:00:00.000Z" },
      { bucket: "evidence" as const, key: "old", size: 3, uploaded: "2026-01-02T00:00:00.000Z" },
    ];
    expect(selectGarbageObjects(objects, new Set(["archive\u0000reachable"]), "2026-08-01T00:00:00.000Z", 10))
      .toEqual([objects[2]]);
  });
});
