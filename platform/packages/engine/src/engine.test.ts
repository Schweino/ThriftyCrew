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

  it("rejects sampled and successor produce impostors while preserving clean produce", () => {
    const authored = JSON.parse(readFileSync(new URL("../../../config/commodities.json", import.meta.url), "utf8")) as
      Array<{ id: string; include: string[]; exclude: string[] }>;
    const cases = [
      { id: "watermelon", bad: [
        "Gatorade Zero Sugar Thirst Quencher Watermelon Splash Sports Drinks, 12 fl oz, 12 Count Bottles",
        "Propel Zero Sugar Electrolyte Water Beverage Watermelon",
        "Extra Sugarfree Sweet Watermelon Gum 15 Ea",
        "Salsagheti Watermelon, 0.84 oz., 24 pk.",
        "BUBBL'R Antioxidant Sparkling Water, Watermelon Lime Smash'r, 12 fl oz, 6 Pack Cans",
        "Red Bull Energy Watermelon, 8.4 oz., 24 pk.",
        "5 Radish Vegetable Seeds: Watermelon Daikon Purple Plum French Champion Full Sun Biennial",
        "5-hour ENERGY Shot, Extra Strength, Watermelon 1.93 fl. oz., 24 pk.",
        "Karma Probiotic Water, Watermelon Wild Berry, 18 fl. oz., 1 Count Bottle",
        "RESPAWN By RAZER Watermelon Guava Rush Sugar Free Chewing Mints, 1 oz., 8 pk.",
        "Watermelon Spears 16 OZ",
        "Seedless Watermelon Slices",
        "Marketside Watermelon Bowl, 24 oz",
        "Marketside Fresh Whole Watermelon Center, 32 oz",
        "Starbucks Lime Watermelon Refreshers Concentrate 32 Fl Oz",
        "Charms Watermelon Fluffy Stuff",
        "Claeys Hard Candies, Old Fashioned, Watermelon 6 Oz",
        "Red Thunder Watermelon 48 FL OZ",
        "Summit Watermelon 12 FL OZ",
        "Good2Grow BIGGER - Watermelon Berry Twist",
      ], good: ["Seedless Watermelon Each", "Whole Seedless Watermelon"] },
      { id: "mangoes", bad: [
        "bubly Mango Sparkling Water, 12 fl oz, 8 Pack Cans",
        "Golden Farms Organic Mango Sauce Pouches, Unsweetened, 3.17 oz., 12 pk.",
        "Dole Fruit Bowls Mangoes & Creme Layers Snacks, 4.3 oz, 4 pack",
        "(4 pack) Del Monte Diced Mango in Extra Light Syrup, Canned Fruit, 15 oz Can",
        "Jolly Rancher Fruit Punch + Mango Ropes 10 Oz",
        "Modelo Chelada Mango Chile Flavored Beer 24 Fl Oz",
        "Star Kist Pink Salmon, Mango Chipotle, Wild Caught, Skinless, Boneless 2.6 Oz",
        "Starbucks Mango Dragonfruit Refreshers Concentrate 32 Fl Oz",
        "Aidells Refrigerated Spicy Mango with Jalapeño Smoked Chicken Sausage Links, 12 oz, 4 Count",
        "SWEETENED MANGO GREAT VALUE BAG 12 OZ",
        "Marketside Fresh Cut Mango, 16 oz Tray",
      ], good: ["Red Mango Each", "Large Mangos"] },
      { id: "cherries", bad: [
        "Fareway Unsweetened & Pitted Dark Sweet Cherries",
        "Del Monte Very Cherry Flavored Mixed Fruit In Extra Light Syrup",
        "Orchard Natural Cherry Mixed Fruit in Fruit Juice 4 oz., 24 ct.",
        "Great Value Light Syrup Extra Cherry Fruit Mix, 15 oz",
        "Bubly Cherry Sparkling Water Cans",
        "Ocean Spray Cherry Craisins",
        "ICEE Cherry & Blue Raspberry Freeze Tubes, 3 fl oz, 6 Count",
        "Great Value Premium Cocktail Cherries, 11 oz",
        "Oregon Fruit Co. Red Tart Cherries in Water, 14.5 oz Can",
      ], good: ["Red Cherries Bag 1 LB", "Field & Vine Pacific Northwest Sweet Fresh Cherries"] },
    ];
    for (const test of cases) {
      const commodity = authored.find((item) => item.id === test.id)!;
      const rules = [{ commodityId: test.id, includes: commodity.include, excludes: commodity.exclude, priority: 1 }];
      for (const product of test.bad) expect(matchProductName(product, rules).status, `${test.id}: ${product}`).toBe("unmatched");
      for (const product of test.good) expect(matchProductName(product, rules), `${test.id}: ${product}`).toMatchObject({ status: "matched", commodityId: test.id });
    }
  });

  it("rejects black-pepper blends and snacks while preserving ground black pepper", () => {
    const authored = JSON.parse(readFileSync(new URL("../../../config/commodities.json", import.meta.url), "utf8")) as
      Array<{ id: string; include: string[]; exclude: string[] }>;
    const commodity = authored.find((item) => item.id === "black-pepper")!;
    const rules = [{ commodityId: commodity.id, includes: commodity.include, excludes: commodity.exclude, priority: 1 }];
    expect(matchProductName("Himalayan Pink Salt Black Pepper and Garlic Seasoning Blend", rules).status).toBe("unmatched");
    expect(matchProductName("Cheez-It Black Pepper Cheddar Baked Snack Crackers, 12.4 oz", rules).status).toBe("unmatched");
    expect(matchProductName("Great Value Black Pepper Popcorn, Ready to Cook Popcorn Chicken, 11g Protein, 3 lb (Frozen)", rules).status).toBe("unmatched");
    expect(matchProductName("Saverne Black Pepper & Lemon Organic Sauerkraut / 16oz Glass", rules).status).toBe("unmatched");
    expect(matchProductName("Member's Mark Fine Ground Black Pepper, 18 oz.", rules)).toMatchObject({ status: "matched", commodityId: "black-pepper" });
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

  it("uses half-open retailer offer windows and reveals the everyday fallback at expiry", () => {
    const candidates = [
      { observationId: "sale", commodityId: "x", storeLocationId: "s", perUnitMicros: 1, capturedAt: "2026-08-12T12:00:00.000Z", batchCapturedTo: "2026-08-12T12:00:00.000Z", batchCoverageMode: "full" as const, validFrom: "2026-08-12T05:00:00.000Z", validTo: "2026-08-19T05:00:00.000Z" },
      { observationId: "regular", commodityId: "x", storeLocationId: "s", perUnitMicros: 2, capturedAt: "2026-08-12T12:00:00.000Z", batchCapturedTo: "2026-08-12T12:00:00.000Z", batchCoverageMode: "full" as const },
    ];
    expect(selectWinner(candidates, "2026-08-19T04:59:59.999Z").winner?.observationId).toBe("sale");
    const expired = selectWinner(candidates, "2026-08-19T05:00:00.000Z");
    expect(expired.winner?.observationId).toBe("regular");
    expect(expired.rejected).toContainEqual({ observationId: "sale", reason: "expired" });
    const future = selectWinner(candidates, "2026-08-12T04:59:59.999Z");
    expect(future.winner?.observationId).toBe("regular");
    expect(future.rejected).toContainEqual({ observationId: "sale", reason: "not-yet-active" });
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
