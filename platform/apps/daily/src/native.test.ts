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
    await mkdir(recipeDirectory, { recursive: true });
    await writeFile(path.join(root, "meal-prep", "db", "ingredients.json"), JSON.stringify([
      { item: "Eggs", bid: "eggs", gpu: 600, unit: "dozen", buy_pkg_g: 600, buy_pkg_label: "dozen" },
    ]));
    await writeFile(path.join(recipeDirectory, "complete.json"), JSON.stringify({
      slug: "complete", name: "Complete", protein: "chicken", servings: 2, visibility: "paid", stat: { cal: 600 },
      ingredients_grams: [{ item: "Eggs", grams: 300 }], scaler: { ing: [{ item: "Eggs", grams: 300, bid: "eggs", gpu: "600" }] },
    }));
    await writeFile(path.join(recipeDirectory, "incomplete.json"), JSON.stringify({
      slug: "incomplete", name: "Incomplete", protein: "chicken", servings: 2, visibility: "paid", stat: { cal: 600 },
      ingredients_grams: [{ item: "Mystery", grams: 100 }], scaler: { ing: [{ item: "Mystery", grams: 100 }] },
    }));
    const snapshot: NativeEngineSnapshot = {
      mode: "direct", observedAt: "2026-08-09T12:00:00.000Z", configurationId: "config", currentReleaseId: "old", inputHash: "a".repeat(64), inputBatchIds: ["batch"],
      commodities: [{ id: "eggs", label: "Eggs", basis_unit: "dozen", category_id: "dairy", category_label: "Dairy", sort_order: 1 }],
      stores: [{ id: "store", store_name: "Store" }],
      candidates: [{ observation_id: "obs", commodity_id: "eggs", store_location_id: "store", per_unit_micros: 2_000_000, normalized_basis_unit: "dozen", normalized_basis_qty_micros: 1_000_000, purchase_price_minor: 200, purchase_quantity: 1, package_count: 1, captured_at: "2026-08-09T11:00:00.000Z", valid_to: null, coverage_mode: "full", captured_to: "2026-08-09T11:00:00.000Z", known_wrong: 0, batch_id: "batch", name: "Eggs" }],
      currentCells: [],
    };
    const artifact = await buildNativeRelease(root, snapshot);
    expect(artifact.recipeCosts).toEqual(expect.arrayContaining([
      expect.objectContaining({ recipeSlug: "complete", status: "complete", batchCostMinor: 200, servingCostMinor: 100 }),
      expect.objectContaining({ recipeSlug: "incomplete", status: "incomplete", missingIngredients: ["Mystery"] }),
    ]));
    expect(artifact.top5.map((entry) => entry.recipeSlug)).toEqual(["complete"]);
    expect(artifact.freeRotation.map((entry) => entry.recipeSlug)).toEqual(["complete"]);
    expect((artifact.payloads.feed as { recipes: Record<string, unknown> }).recipes).toHaveProperty("complete");
    expect((artifact.payloads.feed as { recipes: Record<string, unknown> }).recipes).not.toHaveProperty("incomplete");
  });
});
