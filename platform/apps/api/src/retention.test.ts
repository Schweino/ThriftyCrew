import { describe, expect, it } from "vitest";
import { summarizeRetentionProtections } from "./retention";

describe("dependency-aware observation retention", () => {
  it("counts each observation once per reason while preserving multi-reference protection", () => {
    expect(summarizeRetentionProtections([
      { observation_id: "one", protections: "current-release-cell:rel,accuracy-draw:draw" },
      { observation_id: "two", protections: "accuracy-draw:draw,accuracy-draw:draw-2" },
    ])).toEqual({
      protectedCount: 2,
      byReason: { "accuracy-draw": 2, "current-release-cell": 1 },
    });
  });
});
