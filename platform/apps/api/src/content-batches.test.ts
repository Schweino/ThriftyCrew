import { describe, expect, it } from "vitest";
import { evaluateContentPromotion } from "./content-batches";

const valid = {
  sourceCandidateId: "candidate-chicken-rice",
  sourceServings: 4,
  slug: "fixture-chicken-rice",
  title: "Fixture Chicken Rice",
  servings: 14 as const,
  cuisine: "American",
  proteinClass: "chicken",
  method: "stovetop simmer",
  sourceNutrition: { calories: 575, proteinGrams: 42, carbohydrateGrams: 32 },
  ingredients: [
    { name: "Chicken", grams: 1_600, commodityId: "chicken-breast", sourceLine: "1 lb chicken breast" },
    { name: "Rice", grams: 1_200, commodityId: "white-rice", sourceLine: "2 cups white rice" },
  ],
  mealComponents: [
    { role: "main" as const, label: "chicken", commodityIds: ["chicken-breast"] },
    { role: "substantial-accompaniment" as const, label: "rice", commodityIds: ["white-rice"] },
  ],
  instructions: [
    { text: "Cook the chicken fully in a large covered skillet.", usesCommodityIds: ["chicken-breast"] },
    { text: "Add the rice and simmer until tender and safely done.", usesCommodityIds: ["white-rice"] },
  ],
  provenance: [{ url: "https://example.com/source", accessedAt: "2026-08-10T00:00:00-05:00" }],
};

describe("content promotion guards", () => {
  it("accepts a complete mapped batch", async () => {
    const result = await evaluateContentPromotion([valid], new Set(["chicken-breast", "white-rice"]));
    expect(result.ok).toBe(true);
    expect(result.contentHash).toHaveLength(64);
  });

  it("rejects unknown commodities and duplicate titles", async () => {
    const result = await evaluateContentPromotion([valid, { ...valid, slug: "fixture-two", ingredients: [{ ...valid.ingredients[0]!, commodityId: "invented" }, valid.ingredients[1]!] }], new Set(["chicken-breast", "white-rice"]));
    expect(result.ok).toBe(false);
    expect(result.findings.map((finding) => finding.key)).toContain("unknown-commodity:fixture-two:invented");
  });

  it("rejects purchased ingredients that are never used and step-only ingredients", async () => {
    const result = await evaluateContentPromotion([{
      ...valid,
      instructions: [
        { text: "Cook the chicken fully in a large covered skillet.", usesCommodityIds: ["chicken-breast"] },
        { text: "Finish the dish with an unlisted garnish before serving.", usesCommodityIds: ["cilantro"] },
      ],
    }], new Set(["chicken-breast", "white-rice", "cilantro"]));
    expect(result.ok).toBe(false);
    expect(result.findings.map((finding) => finding.key)).toEqual(expect.arrayContaining([
      "unused-ingredient:fixture-chicken-rice:white-rice",
      "unlisted-step-ingredient:fixture-chicken-rice:cilantro",
    ]));
  });

  it("rejects a standalone protein with an aromatic mislabeled as an accompaniment", async () => {
    const proteinOnly = {
      ...valid,
      slug: "fixture-herb-chicken",
      title: "Fixture Herb Chicken",
      ingredients: [
        { name: "Chicken", grams: 6_350, commodityId: "whole-chicken", sourceLine: "1 whole chicken" },
        { name: "Onion", grams: 525, commodityId: "onions", sourceLine: "1 onion" },
      ],
      mealComponents: [
        { role: "main" as const, label: "herb chicken", commodityIds: ["whole-chicken"] },
        { role: "substantial-accompaniment" as const, label: "onion cooking bed", commodityIds: ["onions"] },
      ],
      instructions: [
        { text: "Cook the chicken over the onion bed to a safe internal temperature.", usesCommodityIds: ["whole-chicken", "onions"] },
        { text: "Serve the chicken pieces with the softened aromatic onions.", usesCommodityIds: ["whole-chicken", "onions"] },
      ],
    };
    const result = await evaluateContentPromotion([proteinOnly], new Set(["whole-chicken", "onions"]));
    expect(result.ok).toBe(false);
    expect(result.findings.map((finding) => finding.key)).toContain("insubstantial-accompaniment:fixture-herb-chicken");
  });
});
