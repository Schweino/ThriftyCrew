import { describe, expect, it } from "vitest";
import { z } from "zod";
import { recipeSourceCandidatesSchema } from "@thriftycrew/contracts";
import { assertRecipeChainContinuity, normalizeAccuracyEvidenceRow, recipeTerminalReason, validateAgentOutput } from "./agent-work-items";

const candidate = {
  id: "candidate-bean-chili",
  title: "Weeknight Bean Chili",
  proposedSlug: "weeknight-bean-chili",
  sourceUrl: "https://example.test/chili",
  accessedAt: "2026-08-10T12:00:00.000Z",
  sourceServings: 4,
  cuisine: "American",
  proteinClass: "beans",
  method: "stovetop simmer",
  sourceNutrition: { calories: 420, proteinGrams: 20, carbohydrateGrams: 34 },
  ingredients: [
    { raw: "1 can beans", quantityText: "1 can" },
    { raw: "1 can tomatoes", quantityText: "1 can" },
  ],
  conceptSummary: "A weeknight bean and tomato chili cooked on the stovetop.",
  unmappedHints: [],
  confidence: "high" as const,
};

describe("agent output boundary", () => {
  it("turns frozen source-native offer facts into an explicit reviewer evidence packet", () => {
    expect(normalizeAccuracyEvidenceRow({
      observation_id: "obs_one", product_name: "Whole Milk, 1 gal", price_mode: "pickup",
      source_id: "direct-store", capture_method: "browser", coverage_mode: "full", capture_batch_id: "batch_one",
      market_verified: 1, location_verified: 1, price_mode_verified: 1,
      price_semantics_json: '{"offerType":"everyday"}',
      offer_snapshot_json: '{"purchasePriceMinor":399,"availability":{"status":"in_stock","fulfillmentMode":"pickup"}}',
    })).toMatchObject({
      priceSemantics: { offerType: "everyday" },
      offerSnapshot: { purchasePriceMinor: 399, availability: { status: "in_stock", fulfillmentMode: "pickup" } },
      captureVerification: { marketVerified: true, locationVerified: true, priceModeVerified: true, priceMode: "pickup", captureBatchId: "batch_one" },
    });
  });

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

  it("forbids placeholder file changes when the agent requires an operator", () => {
    const proposal = {
      title: "Operator intervention is required for scheduler repair", branch: "agent/operator-scheduler-repair",
      rationale: "The evidence does not identify a safe repository change, so an operator must inspect runtime configuration.",
      files: [{ path: "README.md", operation: "update", content: "" }],
      tests: ["Verify the scheduler and its success telemetry manually."], requiresOperator: true,
    };
    expect(() => validateAgentOutput("pull-request-v1", proposal, "triage_one", "triage-developer")).toThrow(/must be empty/);
  });

  it("accepts a file-free operator escalation and rejects a file-free autonomous PR", () => {
    const proposal = {
      title: "Operator intervention is required for scheduler repair", branch: "agent/operator-scheduler-repair",
      rationale: "The evidence does not identify a safe repository change, so an operator must inspect runtime configuration.",
      files: [], tests: ["Verify the scheduler and its success telemetry manually."], requiresOperator: true,
    };
    expect(validateAgentOutput("pull-request-v1", proposal, "triage_one", "triage-developer")).toEqual(proposal);
    expect(() => validateAgentOutput("pull-request-v1", { ...proposal, requiresOperator: false }, "triage_one", "triage-developer")).toThrow(/at least one change/);
  });

  it("accepts structured staged recipe content", () => {
    const content = { items: [{
      sourceCandidateId: candidate.id,
      sourceServings: 4,
      slug: "bean-chili", title: "Weeknight Bean Chili", servings: 14,
      cuisine: "American", proteinClass: "beans", method: "stovetop simmer",
      ingredients: [
        { name: "beans", grams: 1_400, commodityId: "beans", sourceLine: "1 can beans" },
        { name: "tomatoes", grams: 1_050, commodityId: "tomatoes", sourceLine: "1 can tomatoes" },
      ],
      instructions: [
        { text: "Combine the beans and tomatoes in a large pot.", usesCommodityIds: ["beans", "tomatoes"] },
        { text: "Simmer gently for twenty minutes before serving.", usesCommodityIds: [] },
      ],
      provenance: [{ url: "https://example.test/chili", accessedAt: "2026-08-10T12:00:00.000Z" }],
    }] };
    expect(validateAgentOutput("content-items-v1", content, "request_one", "recipe-writer")).toEqual(content);
  });

  it("fences recipe source output to its request", () => {
    const sourceOutput = { requestId: "request_other", candidates: [candidate], rejectedSources: [], searchSummary: "One verified source was accepted." };
    expect(() => validateAgentOutput("recipe-source-candidates-v1", sourceOutput, "request_expected", "recipe-sourcer")).toThrow(/different request/);
  });

  it("keeps recipe source URLs strict without emitting an unsupported uri format", () => {
    const jsonSchema = JSON.stringify(z.toJSONSchema(recipeSourceCandidatesSchema));
    expect(jsonSchema).not.toContain('"format":"uri"');
    expect(() => recipeSourceCandidatesSchema.parse({
      requestId: "request_one",
      candidates: [{ ...candidate, sourceUrl: "not-a-url" }],
      rejectedSources: [],
      searchSummary: "One source candidate was evaluated.",
    })).toThrow(/valid URL/);
  });

  it("requires a dedup decision for every sourced candidate", () => {
    const input = { output: { requestId: "request_one", candidates: [candidate], rejectedSources: [], searchSummary: "One verified source was accepted." } };
    const output = { requestId: "request_one", accepted: [], decisions: [] };
    expect(() => assertRecipeChainContinuity("recipe-deduper", input, output)).toThrow(/every sourced candidate/);
  });

  it("prevents the writer from silently dropping ready mappings", () => {
    const input = { output: { requestId: "request_one", recipes: [{
      candidate,
      ingredients: [
        { sourceLine: "1 can beans", sourceName: "beans", quantityText: "1 can", commodityId: "beans", grams: 1_400, decision: "exact", scalingStatus: "scaled", evidence: "Exact active commodity." },
        { sourceLine: "1 can tomatoes", sourceName: "tomatoes", quantityText: "1 can", commodityId: "tomatoes", grams: 1_050, decision: "exact", scalingStatus: "scaled", evidence: "Exact active commodity." },
      ],
      readyForWriting: true,
      issues: [],
    }] } };
    expect(() => assertRecipeChainContinuity("recipe-writer", input, { items: [] })).toThrow();
  });

  it("ends a recipe request cleanly when a stage has nothing safe to advance", () => {
    expect(recipeTerminalReason("recipe-sourcer", {
      requestId: "request_one", candidates: [], rejectedSources: [], searchSummary: "No source had enough verified facts.",
    })).toBe("no verified source candidates");
    expect(recipeTerminalReason("recipe-deduper", {
      requestId: "request_one", accepted: [], decisions: [{
        candidateId: candidate.id, decision: "catalog_duplicate", duplicateOf: "existing-chili", reason: "The current catalog already contains the same dish.",
        similarity: { protein: "same", flavor: "same", starch: "same", method: "same" },
      }],
    })).toBe("all candidates were rejected or deduplicated");
  });
});
