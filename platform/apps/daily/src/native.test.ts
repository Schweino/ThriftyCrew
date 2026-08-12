import { copyFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { NativeEngineSnapshot } from "@thriftycrew/engine";
import { buildNativeRelease, loadNativeReleaseCatalog, nativeReleaseIdentity } from "./native";

const temporaryRoots: string[] = [];
afterEach(async () => Promise.all(temporaryRoots.splice(0).map((root) => rm(root, { recursive: true, force: true }))));

describe("native release construction", () => {
  it("rejects duplicate normalized ingredient definitions instead of silently overwriting pricing metadata", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-native-duplicates-"));
    temporaryRoots.push(root);
    const recipeDirectory = path.join(root, "meal-prep", "db", "recipes");
    const configDirectory = path.join(root, "platform", "config");
    await mkdir(recipeDirectory, { recursive: true });
    await mkdir(configDirectory, { recursive: true });
    await Promise.all([
      writeFile(path.join(root, "meal-prep", "db", "ingredients.json"), JSON.stringify([{ item: "Golden Raisins", bid: "golden-raisins" }, { item: " Golden  Raisins " }])),
      writeFile(path.join(configDirectory, "recipe-commodities.json"), JSON.stringify({ commodities: [] })),
      writeFile(path.join(configDirectory, "recipe-commodity-extensions.json"), JSON.stringify({ commodities: [] })),
      writeFile(path.join(configDirectory, "recipe-commodity-aliases.json"), JSON.stringify({})),
      writeFile(path.join(configDirectory, "known-wrong.json"), JSON.stringify({ entries: [] })),
      writeFile(path.join(configDirectory, "ingredient-conversion-policy.json"), JSON.stringify({ version: 1, authority: "test", precedence: [], requirements: { maximumExceptionRatio: 20 }, confidence: {} })),
    ]);
    await expect(loadNativeReleaseCatalog(root)).rejects.toThrow("duplicate normalized item");
  });

  it("costs recipes from release crowns and excludes incomplete recipes from ranked surfaces", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-native-"));
    temporaryRoots.push(root);
    const recipeDirectory = path.join(root, "meal-prep", "db", "recipes");
    const configDirectory = path.join(root, "platform", "config");
    await mkdir(recipeDirectory, { recursive: true });
    await mkdir(configDirectory, { recursive: true });
    await Promise.all([
      writeFile(path.join(configDirectory, "recipe-commodities.json"), JSON.stringify({ global_exclude: [], commodities: [{ id: "spice", label: "Spice", unit: "oz", include: ["special spice"], exclude: [], band_min: 0.1, band_max: 5 }] })),
      writeFile(path.join(configDirectory, "recipe-commodity-extensions.json"), JSON.stringify({ commodities: [] })),
      writeFile(path.join(configDirectory, "recipe-commodity-aliases.json"), JSON.stringify({})),
      writeFile(path.join(configDirectory, "known-wrong.json"), JSON.stringify({ entries: [] })),
      writeFile(path.join(configDirectory, "ingredient-conversion-policy.json"), JSON.stringify({ version: 1, authority: "test", precedence: [], requirements: { maximumExceptionRatio: 20 }, confidence: {} })),
    ]);
    await writeFile(path.join(root, "meal-prep", "db", "ingredients.json"), JSON.stringify([
      { item: "Eggs", bid: "eggs", gpu: 600, unit: "dozen", buy_pkg_g: 600, buy_pkg_label: "dozen" },
      { item: "Spice", bid: "spice", gpu: 28.3495, unit: "oz", buy_pkg_g: 28.3495, buy_pkg_label: "jar" },
    ]));
    await writeFile(path.join(recipeDirectory, "complete.json"), JSON.stringify({
      slug: "complete", name: "Complete", protein: "chicken", servings: 2, visibility: "paid", stat: { cal: 600 },
      ingredients_grams: [{ item: "Eggs", grams: 300 }], scaler: { ing: [{ item: "Eggs", grams: 300, bid: "eggs", gpu: "600" }] },
    }));
    await writeFile(path.join(recipeDirectory, "incomplete.json"), JSON.stringify({
      slug: "incomplete", name: "Incomplete", protein: "chicken", servings: 2, visibility: "paid", stat: { cal: 600 },
      ingredients_grams: [{ item: "Mystery", grams: 100 }], scaler: { ing: [{ item: "Mystery", grams: 100 }] },
    }));
    await writeFile(path.join(recipeDirectory, "recipe-rule.json"), JSON.stringify({
      slug: "recipe-rule", name: "Recipe Rule", protein: "beef", servings: 2, visibility: "paid", stat: { cal: 600 },
      ingredients_grams: [{ item: "Spice", grams: 14.17475 }], scaler: { ing: [{ item: "Spice", grams: 14.17475, bid: "spice", gpu: "28.3495" }] },
    }));
    const snapshot: NativeEngineSnapshot = {
      mode: "direct", observedAt: "2026-08-09T12:00:00.000Z", configurationId: "config", currentReleaseId: "old", inputHash: "a".repeat(64), inputBatchIds: ["batch"],
      commodities: [{ id: "eggs", label: "Eggs", basis_unit: "dozen", category_id: "dairy", category_label: "Dairy", sort_order: 1 }],
      stores: [{ id: "store", store_name: "Store", membership_required: 1 }],
      candidates: [{ observation_id: "obs", commodity_id: "eggs", store_location_id: "store", per_unit_micros: 2_000_000, normalized_basis_unit: "dozen", normalized_basis_qty_micros: 1_000_000, purchase_price_minor: 200, purchase_quantity: 1, package_count: 1, captured_at: "2026-08-09T11:00:00.000Z", valid_to: null, coverage_mode: "full", captured_to: "2026-08-09T11:00:00.000Z", known_wrong: 0, batch_id: "batch", name: "Eggs" }],
      rawCandidates: [{ observation_id: "raw-spice", store_location_id: "store", per_unit_micros: 1_000_000, normalized_basis_unit: "oz", captured_at: "2026-08-09T11:00:00.000Z", valid_to: null, coverage_mode: "full", captured_to: "2026-08-09T11:00:00.000Z", batch_id: "batch", name: "Special Spice 1 oz" }],
      currentCells: [],
    };
    const artifact = await buildNativeRelease(root, snapshot);
    const identity = await nativeReleaseIdentity(snapshot, await loadNativeReleaseCatalog(root));
    expect(identity).toMatchObject({ releaseId: artifact.releaseId, inputHash: artifact.inputHash, inputBatchIds: artifact.inputBatchIds });
    expect(artifact.recipeCosts).toEqual(expect.arrayContaining([
      expect.objectContaining({ recipeSlug: "complete", status: "complete", batchCostMinor: 100, servingCostMinor: 50, detail: expect.objectContaining({ utilizedBatchCostMinor: 100, splitStoreCheckoutCostMinor: 200, bestSingleStoreCheckoutCostMinor: 200 }) }),
      expect.objectContaining({ recipeSlug: "incomplete", status: "incomplete", missingIngredients: ["Mystery"] }),
      expect.objectContaining({ recipeSlug: "recipe-rule", status: "complete", batchCostMinor: 50, servingCostMinor: 25 }),
    ]));
    expect(artifact.top5.map((entry) => entry.recipeSlug)).toEqual(["complete", "recipe-rule"]);
    expect(artifact.freeRotation.map((entry) => entry.recipeSlug)).toEqual(["complete", "recipe-rule"]);
    expect((artifact.payloads.feed as { recipes: Record<string, unknown> }).recipes).toHaveProperty("complete");
    expect((artifact.payloads.feed as { recipes: Record<string, unknown> }).recipes).not.toHaveProperty("incomplete");
    const board = artifact.payloads.board as { commodities: Array<{ stores: Array<{ observationId: string; membership: boolean; member_label: string }> }> };
    expect(board.commodities[0]?.stores[0]).toMatchObject({ observationId: "obs", membership: true, member_label: "Membership required" });
  });

  it("prices the strict specialty rules and rejects their common false-positive traps", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-native-accuracy-"));
    temporaryRoots.push(root);
    const recipeDirectory = path.join(root, "meal-prep", "db", "recipes");
    const configDirectory = path.join(root, "platform", "config");
    await mkdir(recipeDirectory, { recursive: true });
    await mkdir(configDirectory, { recursive: true });
    const realConfig = path.resolve(import.meta.dirname, "../../../config");
    await Promise.all([
      copyFile(path.join(realConfig, "recipe-commodities.json"), path.join(configDirectory, "recipe-commodities.json")),
      copyFile(path.join(realConfig, "recipe-commodity-extensions.json"), path.join(configDirectory, "recipe-commodity-extensions.json")),
      copyFile(path.join(realConfig, "recipe-commodity-aliases.json"), path.join(configDirectory, "recipe-commodity-aliases.json")),
      copyFile(path.join(realConfig, "ingredient-conversion-policy.json"), path.join(configDirectory, "ingredient-conversion-policy.json")),
      writeFile(path.join(configDirectory, "known-wrong.json"), JSON.stringify({ entries: [] })),
    ]);
    const fixtures = [
      ["Aji Amarillo Paste", "aji-amarillo-paste", 28.3495, "Aji Amarillo Chili Paste 7 oz", "oz"],
      ["Bulgur Wheat", "bulgur-wheat", 28.3495, "Bob's Red Mill Bulgur Wheat 28 oz", "oz"],
      ["Doubanjiang", "doubanjiang", 28.3495, "Pixian Doubanjiang Fermented Broad Bean Paste 16 oz", "oz"],
      ["Dried Ancho Chiles", "dried-ancho-chiles", 28.3495, "Dried Ancho Chiles 4 oz", "oz"],
      ["Dried Guajillo Chiles", "dried-guajillo-chiles", 28.3495, "Dried Guajillo Chiles 4 oz", "oz"],
      ["Horseradish Sauce", "horseradish-sauce", 28.3495, "Creamy Horseradish Sauce 9 oz", "oz"],
      ["Keto Bun", "keto-bun", 50, "Keto Hamburger Buns 8 Count 14 oz", "oz"],
      ["Korean Rice Cakes", "korean-rice-cakes", 28.3495, "Korean Tteokbokki Rice Cakes 21 oz", "oz"],
      ["Pomegranate Molasses", "pomegranate-molasses", 29.57, "Pure Pomegranate Molasses 10 fl oz", "fl_oz"],
      ["Sumac", "sumac", 28.3495, "Ground Sumac 2 oz", "oz"],
      ["Sweet Soy Sauce", "sweet-soy-sauce", 29.57, "Kikkoman Sweet Soy Sauce 10 fl oz", "fl_oz"],
      ["Condensed French Onion Soup", "condensed-french-onion-soup", 298, "Condensed French Onion Soup 10.5 oz", "oz"],
      ["Fajita Seasoning", "fajita-seasoning", 35.44, "Fajita Seasoning Mix 1.25 oz", "oz"],
      ["Red Wine Vinegar", "red-wine-vinegar", 29.57, "Red Wine Vinegar 12 fl oz", "fl_oz"],
    ] as const;
    await writeFile(path.join(root, "meal-prep", "db", "ingredients.json"), JSON.stringify(fixtures.map(([item, bid, gpu]) => ({
      item, bid, gpu, unit: bid === "keto-bun" || bid === "condensed-french-onion-soup" || bid === "fajita-seasoning" ? "each" : "oz", board: "recipe",
    }))));
    await Promise.all(fixtures.map(async ([item, bid, gpu]) => writeFile(path.join(recipeDirectory, `${bid}.json`), JSON.stringify({
      slug: bid, name: item, protein: "chicken", servings: 2, visibility: "paid", stat: { cal: 500 },
      ingredients_grams: [{ item, grams: gpu }],
      scaler: { ing: [{ item, grams: gpu, bid, gpu: String(gpu) }] },
    }))));
    const rawCandidates: NonNullable<NativeEngineSnapshot["rawCandidates"]> = fixtures.map(([, bid, , name, unit], index) => ({
      observation_id: `good-${bid}`, store_location_id: "store", per_unit_micros: 500_000,
      normalized_basis_unit: unit, normalized_basis_qty_micros: 1_000_000, purchase_price_minor: 500,
      captured_at: "2026-08-11T11:00:00.000Z", valid_to: null, coverage_mode: "full" as const,
      captured_to: "2026-08-11T11:00:00.000Z", batch_id: "batch", name, size_text: index % 2 ? "package" : null,
    }));
    rawCandidates.push(
      { ...rawCandidates[0]!, observation_id: "trap-douban", name: "American Chili Beans in Sauce 15 oz", per_unit_micros: 10_000 },
      { ...rawCandidates[0]!, observation_id: "trap-ancho", name: "Anchovy Fillets 4 oz", per_unit_micros: 10_000 },
      { ...rawCandidates[0]!, observation_id: "trap-rice", name: "Chocolate Rice Cakes Snack 6 oz", per_unit_micros: 10_000 },
    );
    const snapshot: NativeEngineSnapshot = {
      mode: "direct", observedAt: "2026-08-11T12:00:00.000Z", configurationId: "config", currentReleaseId: "old",
      inputHash: "c".repeat(64), inputBatchIds: ["batch"], commodities: [],
      stores: [{ id: "store", store_name: "Store", membership_required: 0 }],
      candidates: [], rawCandidates, currentCells: [],
    };
    const artifact = await buildNativeRelease(root, snapshot);
    expect(artifact.recipeCosts).toHaveLength(fixtures.length);
    expect(artifact.recipeCosts.every((recipe) => recipe.status === "complete")).toBe(true);
    for (const [, bid] of fixtures) {
      const cost = artifact.recipeCosts.find((recipe) => recipe.recipeSlug === bid);
      expect(cost?.detail).toEqual(expect.objectContaining({
        ingredients: [expect.objectContaining({ observationId: `good-${bid}` })],
      }));
    }
  });
});
