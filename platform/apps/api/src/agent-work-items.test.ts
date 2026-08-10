import { describe, expect, it } from "vitest";
import { validateAgentOutput } from "./agent-work-items";

describe("agent output boundary", () => {
  it("fences triage plans to their source item", () => {
    const plan = {
      version: 1, triageId: "tri_other", diagnosis: "A sufficiently detailed diagnosis for the evidence.", evidenceRefs: ["guard://one"],
      blastRadius: { routes: [], releases: [], stores: [], commodities: [], recipes: [] },
      implementation: ["Apply the narrow implementation change."], verification: ["Run the deterministic verification suite."],
      rollback: ["Revert the bounded implementation commit."], requiresOperator: false,
    };
    expect(() => validateAgentOutput("triage-plan-v1", plan, "tri_expected", "triage-reviewer")).toThrow(/different triage item/);
  });

  it("enforces the source-sentinel PR path allowlist", () => {
    const proposal = {
      title: "Repair a changed store source contract", branch: "agent/source-contract-fix",
      rationale: "The captured source moved one documented field and the parser must follow it.",
      files: [{ path: ".github/workflows/rogue.yml", operation: "create", content: "name: rogue" }],
      tests: ["pnpm test"], requiresOperator: false,
    };
    expect(() => validateAgentOutput("pull-request-v1", proposal, "sentinel_one", "source-sentinel-investigator")).toThrow(/forbidden/);
  });

  it("accepts structured staged recipe content", () => {
    const content = { items: [{
      slug: "bean-chili", title: "Weeknight Bean Chili", servings: 4,
      ingredients: [{ name: "beans", quantity: 400, unit: "g", commodityId: "beans" }, { name: "tomatoes", quantity: 300, unit: "g", commodityId: "tomatoes" }],
      instructions: ["Combine the ingredients and simmer gently for twenty minutes."],
      provenance: [{ url: "https://example.test/chili", accessedAt: "2026-08-10T12:00:00.000Z" }],
    }] };
    expect(validateAgentOutput("content-items-v1", content, "request_one", "recipe-writer")).toEqual(content);
  });
});
