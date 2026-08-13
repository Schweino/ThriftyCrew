import { describe, expect, it } from "vitest";
import { extractShoppingRequirements, expectedUnitDimension } from "./ingredient-requirements";

describe("atomic shopping requirements", () => {
  it("classifies process water without creating a purchasable identity", () => {
    expect(extractShoppingRequirements("2 cups boiling water")).toMatchObject([{ role: "process", normalizedName: "water" }]);
  });

  it("splits combined purchased ingredients", () => {
    expect(extractShoppingRequirements("kosher salt and black pepper").map((item) => item.normalizedName))
      .toEqual(["kosher salt", "black pepper"]);
    expect(extractShoppingRequirements("harissa and plain yogurt").map((item) => item.normalizedName))
      .toEqual(["harissa", "plain yogurt"]);
  });

  it("preserves known indivisible product names", () => {
    expect(extractShoppingRequirements("1 cup half and half")).toMatchObject([{ role: "purchased", normalizedName: "half and half" }]);
  });

  it("marks unresolved source alternatives instead of inventing one identity", () => {
    expect(extractShoppingRequirements("dried apricots or prunes")).toMatchObject([{ role: "alternative" }]);
  });

  it("derives the comparison dimension from the locked source line", () => {
    expect(expectedUnitDimension("2 pounds pistachios")).toBe("mass");
    expect(expectedUnitDimension("3 tablespoons olive oil")).toBe("volume");
  });
});
