import { describe, expect, it } from "vitest";
import { mergeRecipeCommodityCatalog, recipeCommodityIds } from "./recipe-commodity-catalog";

describe("recipe commodity catalog", () => {
  it("adds recipe-pricing commodities missing from the active configuration", () => {
    const catalog = mergeRecipeCommodityCatalog([
      { id: "whole-chicken", label: "Whole Chicken", basis_unit: "lb", category: "Meat" },
    ]);

    expect(catalog).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: "boneless-skinless-chicken-thigh", basis_unit: "lb" }),
    ]));
    expect(recipeCommodityIds(catalog).has("boneless-skinless-chicken-thigh")).toBe(true);
  });

  it("keeps the active configuration row when a recipe rule has the same id", () => {
    const active = { id: "whole-chicken", label: "Current Whole Chicken", basis_unit: "each", category: "Current" };
    const catalog = mergeRecipeCommodityCatalog([active]);

    expect(catalog.find((commodity) => commodity.id === "whole-chicken")).toEqual(active);
    expect(catalog.filter((commodity) => commodity.id === "whole-chicken")).toHaveLength(1);
  });

  it("exposes deterministic recipe aliases on their priced shopping commodity", () => {
    const catalog = mergeRecipeCommodityCatalog([
      { id: "ground-beef-8020", label: "Ground Beef 80/20", basis_unit: "lb", category: "Meat" },
    ]);

    expect(catalog.find((commodity) => commodity.id === "ground-beef-8020")).toEqual(expect.objectContaining({
      recipe_aliases: expect.arrayContaining(["ground-beef"]),
    }));
    expect(catalog.some((commodity) => commodity.id === "ground-beef")).toBe(false);
  });
});
