import { describe, expect, it } from "vitest";
import { hydrateReleaseRecipeBundle, recipeFeedIngredients } from "./recipe-bundles";

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

describe("hydrateReleaseRecipeBundle", () => {
  it("adds release metadata at read time without changing release-neutral recipe data", () => {
    const bundle = { version: 2, slug: "dinner", feed: { ingredients: { rice: { store: "Aldi" } } } };
    expect(hydrateReleaseRecipeBundle(bundle, "release-2", "2026-08-12T14:00:00Z", "2026-08-12")).toEqual({
      ...bundle, releaseId: "release-2", feed: {
        ingredients: { rice: { store: "Aldi" } }, release_id: "release-2",
        generated: "2026-08-12T14:00:00Z", week_of: "2026-08-12",
      },
    });
    expect(bundle).not.toHaveProperty("releaseId");
  });
});
