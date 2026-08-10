import { describe, expect, it } from "vitest";
import { evaluateContentPromotion } from "./content-batches";

const valid = {
  slug: "fixture-chicken-rice",
  title: "Fixture Chicken Rice",
  servings: 4,
  ingredients: [
    { name: "Chicken", quantity: 1, unit: "lb", commodityId: "chicken-breast" },
    { name: "Rice", quantity: 2, unit: "cup", commodityId: "white-rice" },
  ],
  instructions: ["Prepare every ingredient before beginning the recipe.", "Cook the chicken and rice until safely done."],
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
});
