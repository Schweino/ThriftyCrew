import { describe, expect, it } from "vitest";
import { assertPublicRecipeSourceUrl, verifyRecipeFactsAgainstArtifact, verifyRecipeMappingContinuity } from "./recipe-source-verification";

describe("recipe source verification", () => {
  it("rejects private and insecure source URLs", () => {
    expect(() => assertPublicRecipeSourceUrl("http://example.com/recipe")).toThrow(/HTTPS/);
    expect(() => assertPublicRecipeSourceUrl("https://127.0.0.1/recipe")).toThrow(/public/);
  });

  it("requires title, ingredient, and quantity facts in the sealed artifact", () => {
    const candidate = { title: "Lemon Chicken", ingredients: [{ raw: "2 pounds chicken thighs", quantityText: "2 pounds" }] };
    expect(verifyRecipeFactsAgainstArtifact(candidate, "<h1>Lemon Chicken</h1><li>2 pounds chicken thighs</li>")).toEqual([]);
    expect(verifyRecipeFactsAgainstArtifact(candidate, "<h1>Lemon Chicken</h1>")).toContain("ingredient_0_missing_from_artifact");
  });

  it("rejects mapping lines that are absent from locked source facts", () => {
    expect(verifyRecipeMappingContinuity({ candidate: { ingredients: [{ raw: "1 cup rice" }] }, ingredients: [{ sourceLine: "1 cup pasta" }] }))
      .toEqual(["mapping_0_source_line_not_locked"]);
  });
});
