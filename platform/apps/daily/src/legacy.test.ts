import path from "node:path";
import { existsSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { expectedPerUnitMicros } from "@thriftycrew/domain";
import { buildCurrentBridge, exactLegacyPriceBasis, inferBasisQuantity } from "./legacy";

const incomeRoot = path.resolve(import.meta.dirname, "../../../..");
const hasCurrentIgnoredArtifact = existsSync(path.join(incomeRoot, "grocery", "out", `comparison-${new Date().toISOString().slice(0, 10)}.json`));

describe("legacy current-state bridge", () => {
  it("recovers exact normalized quantities from raw package sizes", () => {
    expect(inferBasisQuantity({ unit: "lb", size: "3 oz", basis: "size 0.188 lb" })).toBe(0.1875);
    expect(inferBasisQuantity({ unit: "dozen", size: "18 ct", basis: "size 1.5 dozen" })).toBe(1.5);
    expect(inferBasisQuantity({ unit: "each", size: "8 ct", basis: "per-package (8 ct inside)" })).toBe(1);
  });

  it("finds a cent-denominated multi-buy basis without changing the shown unit price", () => {
    expect(exactLegacyPriceBasis(2.495, 1)).toMatchObject({ purchasePriceMinor: 499, purchaseQuantity: 2, deltaMicros: 0 });
    expect(exactLegacyPriceBasis(13.28, 3 / 16).deltaMicros).toBeLessThanOrEqual(2);
  });

  it.runIf(hasCurrentIgnoredArtifact)("builds the complete current authored surface and repairs private recipe-only bases", async () => {
    const artifact = await buildCurrentBridge(incomeRoot);
    expect(artifact.audit).toMatchObject({
      incompleteRecipes: 0,
      uncategorized: [],
      multiplyCategorized: [],
    });
    expect(artifact.audit.authoredCommodities).toBeGreaterThanOrEqual(507);
    expect(artifact.audit.boardCommodities).toBeGreaterThanOrEqual(494);
    expect(artifact.audit.boardCommodities).toBeLessThanOrEqual(artifact.audit.authoredCommodities);
    expect(artifact.audit.authoredRecipes).toBeGreaterThanOrEqual(542);
    expect(artifact.audit.pricedCells).toBeGreaterThan(0);
    expect(artifact.audit.pricedCells).toBeLessThanOrEqual(artifact.audit.authoredCommodities * 7);
    expect(artifact.cells).toHaveLength(artifact.audit.authoredCommodities * 7);
    expect(artifact.stores).toHaveLength(7);
    expect(artifact.stores.every((store) => store.priceMode === "mixed")).toBe(true);
    const boardCommodities = (artifact.payloads.board as { commodities: Array<{ id: string }> }).commodities;
    expect(boardCommodities).toHaveLength(artifact.audit.boardCommodities);
    expect(new Set(boardCommodities.map((commodity) => commodity.id)).size).toBe(boardCommodities.length);
    expect(artifact.recipeCosts.filter((item) => item.status === "incomplete")).toHaveLength(0);
    expect(artifact.audit.repairedRecipes).toBe(artifact.audit.sourceIncompleteRecipes);
    expect(artifact.recipeCosts.filter((item) => (item.detail.repairedFromPrivateBasis as { commodityId?: string } | undefined)?.commodityId === "dried-ancho-chiles")).toHaveLength(artifact.audit.repairedRecipes);
    expect(artifact.observations.every((item) => item.observation.perUnitMicros >= 0)).toBe(true);
    const largestLegacyRoundingDelta = Math.max(...artifact.observations.map(({ observation }) => Math.abs(
      expectedPerUnitMicros(observation.purchasePriceMinor, observation.normalizedBasisQtyMicros) - observation.perUnitMicros,
    )));
    expect(largestLegacyRoundingDelta).toBeLessThanOrEqual(50);
  }, 30_000);
});
