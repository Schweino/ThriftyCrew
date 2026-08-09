import { describe, expect, it } from "vitest";
import { evaluateAisleEvidence, guardResult, matchProductName, selectWinner } from "./index";

describe("matching", () => {
  it("refuses a same-priority collision instead of first-match-wins", () => {
    const result = matchProductName("Kroger chicken breast", [
      { commodityId: "chicken", includes: ["chicken"], excludes: [], priority: 10 },
      { commodityId: "chicken-breast", includes: ["chicken breast"], excludes: [], priority: 10 },
    ]);
    expect(result.status).toBe("collision");
    expect(result.commodityId).toBeNull();
  });

  it("rejects a food match when the store shelves it as cat litter", () => {
    expect(evaluateAisleEvidence("Pets/Cats/Cat Litter", ["baking"], ["cat litter", "pets"]).status).toBe("rejected");
  });

  it("never invents an aisle flip when shelf taxonomy is unavailable", () => {
    expect(evaluateAisleEvidence(undefined, ["baking"], ["pets"])).toMatchObject({ status: "unavailable", examined: false });
  });
});

describe("winner selection", () => {
  it("does not let a thin partial batch evict the complete capture", () => {
    const result = selectWinner([
      { observationId: "partial", commodityId: "formula", storeLocationId: "sams", perUnitMicros: 1_444_500, capturedAt: "2026-08-06T12:00:00.000Z", batchCapturedTo: "2026-08-06T12:00:00.000Z", batchCoverageMode: "partial" },
      { observationId: "complete", commodityId: "formula", storeLocationId: "sams", perUnitMicros: 770_400, capturedAt: "2026-08-05T12:00:00.000Z", batchCapturedTo: "2026-08-05T12:00:00.000Z", batchCoverageMode: "full" },
    ], "2026-08-09T12:00:00.000Z");
    expect(result.winner?.observationId).toBe("complete");
  });

  it("removes known-wrong observations before ranking", () => {
    const result = selectWinner([
      { observationId: "bad", commodityId: "x", storeLocationId: "s", perUnitMicros: 1, capturedAt: "2026-08-09T12:00:00.000Z", batchCapturedTo: "2026-08-09T12:00:00.000Z", batchCoverageMode: "full", knownWrong: true },
      { observationId: "good", commodityId: "x", storeLocationId: "s", perUnitMicros: 2, capturedAt: "2026-08-09T12:00:00.000Z", batchCapturedTo: "2026-08-09T12:00:00.000Z", batchCoverageMode: "full" },
    ], "2026-08-09T12:00:00.000Z");
    expect(result.winner?.observationId).toBe("good");
  });
});

describe("guard coverage", () => {
  it("refuses a blind pass", () => {
    expect(() => guardResult({ guardId: "x", status: "pass", eligibleCount: 10, examinedCount: 0, detail: {} })).toThrow(/blind/);
  });
});
