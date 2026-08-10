import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { NativeEngineSnapshot } from "@thriftycrew/engine";
import { buildNativeRelease } from "./native";

const temporaryRoots: string[] = [];
afterEach(async () => Promise.all(temporaryRoots.splice(0).map((root) => rm(root, { recursive: true, force: true }))));

describe("native release construction", () => {
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
});
