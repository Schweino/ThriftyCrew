import { describe, expect, it } from "vitest";
import { declaredGramsPerBasisUnit, recomputeRecipeIngredientAmounts } from "./release-integrity";

describe("release recipe conversion integrity", () => {
  const broccoli = {
    basisUnit: "lb",
    conversionSource: "commodity-mass-unit",
    conversionConfidence: "moderate",
    gpu: 453.59237,
    definitionGpu: null,
    scalerGpu: null,
    grams: 637,
    perUnitMicros: 1_325_712,
    sourcePurchasePriceMinor: 116,
    checkoutPerUnitMicros: 1_325_712,
    checkoutSourcePurchasePriceMinor: 116,
    variableWeight: false,
    packageCount: 2,
    utilizedCostMinor: 186,
    purchaseCostMinor: 232,
  };

  it("replays the production broccoli mass conversion from its governed basis unit", () => {
    expect(declaredGramsPerBasisUnit(broccoli)).toBe(453.59237);
    expect(recomputeRecipeIngredientAmounts(broccoli)).toEqual({
      declaredGpu: 453.59237,
      expectedUtilizedMinor: 186,
      expectedCheckoutMinor: 232,
      expectedPackages: 2,
    });
  });

  it("governs ounce, kilogram, and gram conversions without a definition GPU", () => {
    expect(declaredGramsPerBasisUnit({ ...broccoli, basisUnit: "oz" })).toBe(28.349523125);
    expect(declaredGramsPerBasisUnit({ ...broccoli, basisUnit: "kg" })).toBe(1000);
    expect(declaredGramsPerBasisUnit({ ...broccoli, basisUnit: "g" })).toBe(1);
  });

  it("fails closed for unsupported sources and basis units", () => {
    expect(declaredGramsPerBasisUnit({ ...broccoli, conversionSource: "model-inferred" })).toBeNaN();
    expect(declaredGramsPerBasisUnit({ ...broccoli, basisUnit: "each" })).toBeNaN();
    expect(declaredGramsPerBasisUnit({ ...broccoli, conversionSource: "ingredient-definition", definitionGpu: null })).toBe(0);
  });

  it("keeps scaler and ingredient-definition provenance distinct", () => {
    expect(declaredGramsPerBasisUnit({ ...broccoli, conversionSource: "recipe-scaler-exception", scalerGpu: 42 })).toBe(42);
    expect(declaredGramsPerBasisUnit({ ...broccoli, conversionSource: "ingredient-definition", definitionGpu: 31.5 })).toBe(31.5);
  });
});
