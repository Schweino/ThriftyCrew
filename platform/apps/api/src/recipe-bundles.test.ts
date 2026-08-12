import { describe, expect, it } from "vitest";
import { recipeFeedIngredients } from "./recipe-bundles";

describe("recipeFeedIngredients", () => {
  it("exposes legacy scaler IDs with the promoted canonical price", () => {
    const result = recipeFeedIngredients(
      {
        "ground-beef-93-7": { cheapest: 6.99, unit: "lb" },
        pasta: { cheapest: 0.056875, unit: "oz" },
      },
      ["ground-beef-93-7", "pasta"],
      { "93-7-ground-beef": "ground-beef-93-7", "penne-pasta": "pasta" },
    );
    expect(result["93-7-ground-beef"]).toEqual({ cheapest: 6.99, unit: "lb", alias_of: "ground-beef-93-7" });
    expect(result["penne-pasta"]).toEqual({ cheapest: 0.056875, unit: "oz", alias_of: "pasta" });
  });

  it("does not invent an alias when its canonical ingredient is absent", () => {
    expect(recipeFeedIngredients({}, ["ground-beef-93-7"], { "93-7-ground-beef": "ground-beef-93-7" })).toEqual({});
  });
});
