import { describe, expect, it } from "vitest";
import { normalizeRecipeMapperReadiness } from "./recipe-mapper-normalization";

const mappedRecipe = (overrides: Record<string, unknown> = {}) => ({
  candidate: { sourceServings: 4 },
  ingredients: [{ decision: "exact", scalingStatus: "scaled", commodityId: "rice", grams: 1400 }],
  mealComponents: [{ role: "substantial-accompaniment", commodityIds: ["rice"] }],
  readyForWriting: false,
  ...overrides,
});

describe("normalizeRecipeMapperReadiness", () => {
  it("forces blocked mappings to false", () => {
    const output = normalizeRecipeMapperReadiness({ recipes: [mappedRecipe({
      ingredients: [{ decision: "unmapped", scalingStatus: "unresolved", commodityId: null, grams: null }],
      readyForWriting: true,
    })] }) as any;
    expect(output.recipes[0].readyForWriting).toBe(false);
  });

  it("forces complete mappings to true", () => {
    const output = normalizeRecipeMapperReadiness({ recipes: [mappedRecipe()] }) as any;
    expect(output.recipes[0].readyForWriting).toBe(true);
  });

  it("blocks an undersized substantial accompaniment", () => {
    const output = normalizeRecipeMapperReadiness({ recipes: [mappedRecipe({
      ingredients: [{ decision: "exact", scalingStatus: "scaled", commodityId: "rice", grams: 900 }],
      readyForWriting: true,
    })] }) as any;
    expect(output.recipes[0].readyForWriting).toBe(false);
  });
});
