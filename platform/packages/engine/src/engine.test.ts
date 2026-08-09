import { describe, expect, it } from "vitest";
import { buildNativeParityReport, convertUnitPriceMicros, evaluateAisleEvidence, evaluateAisleFamilyEvidence, guardResult, matchProductName, selectWinner } from "./index";

describe("matching", () => {
  it("ports the authored .NET inline case-insensitive prefix", () => {
    expect(matchProductName("Del Monte Sliced Pears", [{ commodityId: "pears", includes: ["pears"], excludes: ["(?i)^.*sliced.*pears"], priority: 1 }]).status).toBe("unmatched");
  });
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

  it("uses taxonomy as a commodity-family second opinion instead of banning non-food aisles", () => {
    expect(evaluateAisleFamilyEvidence("pets_wildlife/cat/litter_boxes", "pet").status).toBe("confirmed");
    expect(evaluateAisleFamilyEvidence("household/cleaners_air_fresheners/tile_wood", "household").status).toBe("confirmed");
    expect(evaluateAisleFamilyEvidence("pets_wildlife/cat/litter_boxes", "food").status).toBe("rejected");
    expect(evaluateAisleFamilyEvidence("health_beauty/sports_nutrition/protein_bars", "food", ["personal"]).status).toBe("confirmed");
    expect(evaluateAisleFamilyEvidence("health_beauty/baby_child/infant_meals", "baby").status).toBe("confirmed");
    expect(evaluateAisleFamilyEvidence("health_beauty/grooming_hygiene/bar_liquid_soap", "household", ["personal"]).status).toBe("confirmed");
    expect(evaluateAisleFamilyEvidence("freezer/frozen_meals_more/appetizers_snacks_side_dishes", "food").status).not.toBe("rejected");
  });
});

describe("winner selection", () => {
  it("converts captured unit prices to the commodity basis", () => {
    expect(convertUnitPriceMicros(250_000, "oz", "lb")).toBe(4_000_000);
    expect(convertUnitPriceMicros(1_000_000, "each", "dozen")).toBe(12_000_000);
    expect(convertUnitPriceMicros(1_000_000, "oz", "each")).toBeNull();
  });
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

describe("native engine parity", () => {
  it("rebuilds winners from the immutable snapshot", () => {
    const report = buildNativeParityReport({
      mode: "legacy", observedAt: "2026-08-09T12:00:00.000Z", configurationId: "config", currentReleaseId: "release", inputHash: "a".repeat(64), inputBatchIds: ["batch"],
      commodities: [{ id: "eggs", label: "Eggs", basis_unit: "dozen", category_id: "dairy" }],
      stores: [{ id: "store", store_name: "Store" }],
      candidates: [{ observation_id: "obs", commodity_id: "eggs", store_location_id: "store", per_unit_micros: 1_990_000, normalized_basis_unit: "dozen", captured_at: "2026-08-09T11:00:00.000Z", valid_to: null, coverage_mode: "full", captured_to: "2026-08-09T11:00:00.000Z", known_wrong: 0 }],
      currentCells: [{ commodity_id: "eggs", store_location_id: "store", observation_id: "obs", status: "priced", is_crown: 1, display_per_unit_micros: 1_990_000, display_unit: "dozen" }],
    });
    expect(report).toMatchObject({ comparedCells: 1, diffCount: 0, diffs: [] });
  });

  it("uses one deterministic crown when stores tie", () => {
    const base = {
      mode: "legacy" as const, observedAt: "2026-08-09T12:00:00.000Z", configurationId: "config", currentReleaseId: "release", inputHash: "b".repeat(64), inputBatchIds: ["batch"],
      commodities: [{ id: "eggs", label: "Eggs", basis_unit: "dozen", category_id: "dairy" }],
      stores: [{ id: "aldi", store_name: "Aldi" }, { id: "walmart", store_name: "Walmart" }],
      candidates: ["aldi", "walmart"].map((store) => ({ observation_id: `obs-${store}`, commodity_id: "eggs", store_location_id: store, per_unit_micros: 1_990_000, normalized_basis_unit: "dozen", captured_at: "2026-08-09T11:00:00.000Z", valid_to: null, coverage_mode: "full" as const, captured_to: "2026-08-09T11:00:00.000Z", known_wrong: 0 })),
      currentCells: [
        { commodity_id: "eggs", store_location_id: "aldi", observation_id: "obs-aldi", status: "priced", is_crown: 1, display_per_unit_micros: 1_990_000, display_unit: "dozen" },
        { commodity_id: "eggs", store_location_id: "walmart", observation_id: "obs-walmart", status: "priced", is_crown: 0, display_per_unit_micros: 1_990_000, display_unit: "dozen" },
      ],
    };
    expect(buildNativeParityReport(base).diffCount).toBe(0);
  });
});
