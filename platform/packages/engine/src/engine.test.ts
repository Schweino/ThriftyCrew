import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { buildNativeCells, buildNativeParityReport, candidatePriceForUnit, convertUnitPriceMicros, evaluateAisleEvidence, evaluateAisleFamilyEvidence, guardResult, matchProductName, selectWinner, sourceNativeSizeConflict } from "./index";

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

  it("rejects bacon-flavoured soup and pasta sauce without rejecting bacon", () => {
    const bacon = [{
      commodityId: "bacon",
      includes: ["\\bbacon\\b"],
      excludes: ["\\bsoups?\\b", "\\bsauces?\\b", "\\balfredo\\b", "\\bcarbonara\\b", "\\bpasta\\b"],
      priority: 1,
    }];
    expect(matchProductName("Campbell's Chunky Creamy Chicken Bacon Carbonara Soup", bacon).status).toBe("unmatched");
    expect(matchProductName("(3 pack) RAGU Bacon Alfredo White Pasta Sauce", bacon).status).toBe("unmatched");
    expect(matchProductName("Applewood Smoked Classic Cut Bacon", bacon)).toMatchObject({ status: "matched", commodityId: "bacon" });
  });

  it("does not classify parsley-flavored mashed potatoes as dried parsley", () => {
    const parsley = [{
      commodityId: "dried-parsley",
      includes: ["(?:dried\\s+parsley|parsley\\s+(?:flakes?|leaves?))"],
      excludes: ["\\bpotato(?:es)?\\b"],
      priority: 1,
    }];
    expect(matchProductName("Chef's Cupboard Mashed Potatoes With Roasted Garlic Parsley 4 OZ", parsley).status).toBe("unmatched");
    expect(matchProductName("Lawry's Coarse Ground Garlic Salt with Parsley, 33 oz.", parsley).status).toBe("unmatched");
    expect(matchProductName("Smart Way Parsley Flakes 0.5 OZ", parsley)).toMatchObject({ status: "matched", commodityId: "dried-parsley" });
    expect(matchProductName("Badia Dried Parsley 3 OZ", parsley)).toMatchObject({ status: "matched", commodityId: "dried-parsley" });
  });

  it("keeps adjacent Gerber beverages out of the authored baby-food rule", () => {
    const authored = JSON.parse(readFileSync(new URL("../../../config/commodities.json", import.meta.url), "utf8")) as
      Array<{ id: string; include: string[]; exclude: string[] }>;
    const babyFood = authored.find((commodity) => commodity.id === "baby-food");
    expect(babyFood).toBeDefined();
    const rules = [{ commodityId: "baby-food", includes: babyFood!.include, excludes: babyFood!.exclude, priority: 1 }];
    expect(matchProductName("Gerber Toddler Apple Juice Beverage 32 fl oz", rules).status).toBe("unmatched");
    expect(matchProductName("Gerber Stage 2 Sweet Corn and Green Beans Baby Food 4 oz", rules)).toMatchObject({ status: "matched", commodityId: "baby-food" });
  });

  it("keeps lemon-flavored pudding out of the fresh lemons commodity", () => {
    const authored = JSON.parse(readFileSync(new URL("../../../config/commodities.json", import.meta.url), "utf8")) as
      Array<{ id: string; include: string[]; exclude: string[] }>;
    const lemons = authored.find((commodity) => commodity.id === "lemons");
    expect(lemons).toBeDefined();
    const rules = [{ commodityId: "lemons", includes: lemons!.include, excludes: lemons!.exclude, priority: 1 }];
    expect(matchProductName("Snack Pack Lemon Pudding, 3.25 oz Pudding Cups, 4 Count", rules).status).toBe("unmatched");
    expect(matchProductName("Luigi's Lemon & Strawberry Real Italian Ice, 6 fl oz, 6 Count, (Frozen)", rules).status).toBe("unmatched");
    expect(matchProductName("GOOD GOOD Vegan Lemon Curd With No Added Sugar, 12 oz Jar", rules).status).toBe("unmatched");
    expect(matchProductName("Fresh Lemons, Each", rules)).toMatchObject({ status: "matched", commodityId: "lemons" });
  });

  it("keeps turkey breakfast sausage out of the pork breakfast-sausage commodity", () => {
    const authored = JSON.parse(readFileSync(new URL("../../../config/commodities.json", import.meta.url), "utf8")) as
      Array<{ id: string; include: string[]; exclude: string[] }>;
    const breakfastSausage = authored.find((commodity) => commodity.id === "breakfast-sausage");
    expect(breakfastSausage).toBeDefined();
    const rules = [{ commodityId: "breakfast-sausage", includes: breakfastSausage!.include, excludes: breakfastSausage!.exclude, priority: 1 }];
    expect(matchProductName("FESTIVE Turkey Breakfast Sausage, Frozen, 1 lb Roll", rules).status).toBe("unmatched");
    expect(matchProductName("Appleton Farms Premium Pork Sausage Roll 16 OZ", rules)).toMatchObject({ status: "matched", commodityId: "breakfast-sausage" });
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
  it("rejects a captured package that contradicts an exact source-native title suffix", () => {
    expect(sourceNativeSizeConflict("Happy Farms String Cheese 10 OZ", "12 oz")).toBe(true);
    expect(sourceNativeSizeConflict("Happy Farms String Cheese 10 OZ", "10 oz")).toBe(false);
    expect(sourceNativeSizeConflict("Dual Label 12 oz (340 g)", "12 oz")).toBe(false);
    expect(sourceNativeSizeConflict("Stonemill Cajun Seasoning 35 OZ", "3.5 oz")).toBe(false);
    expect(sourceNativeSizeConflict("(4 pack) Cake Mix, 15.25 oz", "61 oz")).toBe(false);
    expect(sourceNativeSizeConflict("Ribeye Steak, 0.9 - 1.6 lb", "1.1 lb")).toBe(false);
    expect(sourceNativeSizeConflict("Oyster Sauce, 20.20 fl oz", "19.989 fl oz")).toBe(false);
    const result = selectWinner([
      { observationId: "conflict", commodityId: "string-cheese", storeLocationId: "aldi", perUnitMicros: 1, capturedAt: "2026-08-12T11:00:00.000Z", batchCapturedTo: "2026-08-12T11:00:00.000Z", batchCoverageMode: "full", sourceIdentityConflict: true },
      { observationId: "sound", commodityId: "string-cheese", storeLocationId: "aldi", perUnitMicros: 2, capturedAt: "2026-08-12T11:00:00.000Z", batchCapturedTo: "2026-08-12T11:00:00.000Z", batchCoverageMode: "full" },
    ], "2026-08-12T12:00:00.000Z");
    expect(result.winner?.observationId).toBe("sound");
    expect(result.rejected).toContainEqual({ observationId: "conflict", reason: "source-name-size-conflict" });
  });
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

  it("removes observations outside the source freshness policy before ranking", () => {
    const result = selectWinner([
      { observationId: "stale", commodityId: "x", storeLocationId: "s", perUnitMicros: 1, capturedAt: "2026-07-01T12:00:00.000Z", batchCapturedTo: "2026-07-01T12:00:00.000Z", batchCoverageMode: "full", maxAgeDays: 7 },
      { observationId: "fresh", commodityId: "x", storeLocationId: "s", perUnitMicros: 2, capturedAt: "2026-08-08T12:00:00.000Z", batchCapturedTo: "2026-08-08T12:00:00.000Z", batchCoverageMode: "full", maxAgeDays: 7 },
    ], "2026-08-09T12:00:00.000Z");
    expect(result.winner?.observationId).toBe("fresh");
    expect(result.rejected).toContainEqual({ observationId: "stale", reason: "stale" });
  });
});

describe("alternative package bases", () => {
  it("never lets an ambiguous same-unit option underbid the normalized captured basis", () => {
    expect(candidatePriceForUnit({
      normalized_basis_unit: "oz",
      per_unit_micros: 1_080_178,
      basis_options_json: JSON.stringify([{ unit: "oz", perUnitMicros: 11_412, source: "stated-measure" }]),
    }, "oz")).toEqual({ unit: "oz", perUnitMicros: 1_080_178, source: "normalized" });
  });

  it("prices a matched weight commodity from an audited multipack basis", () => {
    const snapshot = {
      mode: "direct" as const, observedAt: "2026-08-09T12:00:00.000Z", configurationId: "config", currentReleaseId: "release", inputHash: "d".repeat(64), inputBatchIds: ["batch"],
      commodities: [{ id: "beans", label: "Beans", basis_unit: "oz", category_id: "pantry" }],
      stores: [{ id: "sams", store_name: "Sam's Club" }],
      candidates: [{
        observation_id: "obs", commodity_id: "beans", store_location_id: "sams", per_unit_micros: 1_110_000,
        normalized_basis_unit: "each", captured_at: "2026-08-09T11:00:00.000Z", valid_to: null,
        coverage_mode: "full" as const, captured_to: "2026-08-09T11:00:00.000Z", known_wrong: 0,
        basis_options_json: JSON.stringify([{ unit: "oz", quantityMicros: 90_000_000, perUnitMicros: 74_000, source: "count-times-measure" }]),
      }],
      currentCells: [],
    };
    expect(buildNativeCells(snapshot)[0]).toMatchObject({ status: "priced", displayPerUnitMicros: 74_000 });
  });
});

describe("authored price bands", () => {
  it("rejects an internally consistent but implausible semantic price before winner selection", () => {
    const cells = buildNativeCells({
      mode: "direct", observedAt: "2026-08-09T12:00:00.000Z", configurationId: "config", currentReleaseId: "release", inputHash: "e".repeat(64), inputBatchIds: ["batch"],
      commodities: [{ id: "shrimp", label: "Shrimp", basis_unit: "lb", category_id: "meat", band_min_micros: 2_500_000, band_max_micros: 16_000_000 }],
      stores: [{ id: "walmart", store_name: "Walmart" }],
      candidates: [{ observation_id: "bad", commodity_id: "shrimp", store_location_id: "walmart", per_unit_micros: 500_000, normalized_basis_unit: "lb", captured_at: "2026-08-09T11:00:00.000Z", valid_to: null, coverage_mode: "full", captured_to: "2026-08-09T11:00:00.000Z", known_wrong: 0 }],
      currentCells: [],
    });
    expect(cells[0]).toMatchObject({ status: "missing", reason: { rejectedCandidates: [{ observationId: "bad", reason: "outside-authored-price-band" }] } });
  });
});

describe("guard coverage", () => {
  it("refuses a blind pass", () => {
    expect(() => guardResult({ guardId: "x", status: "pass", eligibleCount: 10, examinedCount: 0, detail: {} })).toThrow(/blind/);
  });
});

describe("native engine parity", () => {
  it("keeps the selected candidate provenance on native release cells", () => {
    const snapshot = {
      mode: "direct" as const, observedAt: "2026-08-09T12:00:00.000Z", configurationId: "config", currentReleaseId: "release", inputHash: "c".repeat(64), inputBatchIds: ["batch"],
      commodities: [{ id: "eggs", label: "Eggs", basis_unit: "dozen", category_id: "dairy" }],
      stores: [{ id: "store", store_name: "Store" }],
      candidates: [{ observation_id: "obs", commodity_id: "eggs", store_location_id: "store", per_unit_micros: 1_990_000, normalized_basis_unit: "dozen", captured_at: "2026-08-09T11:00:00.000Z", valid_to: null, coverage_mode: "full" as const, captured_to: "2026-08-09T11:00:00.000Z", known_wrong: 0, name: "Large Eggs" }],
      currentCells: [],
    };
    expect(buildNativeCells(snapshot)[0]).toMatchObject({ observationId: "obs", isCrown: true, winner: { name: "Large Eggs" }, reason: { code: "native-winner" } });
  });

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
