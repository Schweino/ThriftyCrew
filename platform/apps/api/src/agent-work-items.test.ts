import { describe, expect, it } from "vitest";
import { z } from "zod";
import { ingredientPriceResearchSchema, OMAHA_GROCERY_STORE_LOCATION_IDS, recipeMapSchema, recipeSourceCandidatesSchema } from "@thriftycrew/contracts";
import { activeIngredientCategoryContextSql, assertRecipeChainContinuity, ingredientCampaignPhase, type IngredientCampaignSnapshot, normalizeAccuracyEvidenceRow, recipeTerminalReason, validateAgentOutput } from "./agent-work-items";

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
  mealComponents: [
    { role: "main" as const, label: "beans", ingredientIndexes: [0] },
    { role: "substantial-accompaniment" as const, label: "tomato vegetable base", ingredientIndexes: [1] },
  ],
  conceptSummary: "A weeknight bean and tomato chili cooked on the stovetop.",
  unmappedHints: [],
  confidence: "high" as const,
};

describe("agent output boundary", () => {
  const unpricedStores = OMAHA_GROCERY_STORE_LOCATION_IDS.map((storeLocationId) => ({
    storeLocationId, outcome: "not_found" as const, checkedAt: "2026-08-13T12:00:00.000Z",
    queryTerms: ["unobtainium spice"], searchComplete: true, qualifyingProductsExamined: 0,
    locationVerified: true, priceModeVerified: true,
    sourceUrl: `https://example.test/${storeLocationId}`, evidenceSummary: "The first-party Omaha storefront completed an exact search with no qualifying in-stock result.",
    productName: null, sellerName: null, fulfillmentMode: null, availabilityText: null, packageText: null, packagePriceMinor: null, normalizedBasisUnit: null,
    normalizedBasisQtyMicros: null, perUnitMicros: null, offerKind: null, validFrom: null, validTo: null,
    loyaltyRequired: false, membershipRequired: false,
  }));

  it("requires all seven successful Omaha checks before permanent unavailability", () => {
    const research = {
      gapId: "gap_one", ingredientName: "Unobtainium spice", marketId: "omaha", researchedAt: "2026-08-13T12:00:00.000Z",
      disposition: "permanently_unavailable", stores: unpricedStores, commodityProposal: null,
      summary: "All seven registered Omaha store checks completed without a qualifying in-stock product.",
    };
    expect(ingredientPriceResearchSchema.parse(research)).toEqual(research);
    expect(() => ingredientPriceResearchSchema.parse({ ...research, stores: research.stores.slice(0, 6) })).toThrow(/exactly|Array must contain/);
    expect(() => ingredientPriceResearchSchema.parse({ ...research, stores: research.stores.map((store, index) => index === 2 ? { ...store, outcome: "blocked" } : store) })).toThrow(/needs_operator/);
    expect(JSON.stringify(z.toJSONSchema(ingredientPriceResearchSchema))).not.toContain('"format":"uri"');
  });

  it("loads ingredient category context through active configuration membership", () => {
    expect(activeIngredientCategoryContextSql).toContain("configuration_categories member");
    expect(activeIngredientCategoryContextSql).toContain("version.id = member.configuration_id");
    expect(activeIngredientCategoryContextSql).not.toContain("category.configuration_id");
  });

  it("preserves multiple source lines that map to one unique component commodity", () => {
    const duplicateCommodityCandidate = {
      ...candidate,
      ingredients: [
        { raw: "1 can black beans", quantityText: "1 can" },
        { raw: "1 can pinto beans", quantityText: "1 can" },
        { raw: "1 can tomatoes", quantityText: "1 can" },
      ],
      mealComponents: [
        { role: "main" as const, label: "beans", ingredientIndexes: [0, 1] },
        { role: "substantial-accompaniment" as const, label: "tomato vegetable base", ingredientIndexes: [2] },
      ],
    };
    const mapped = {
      requestId: "request_one",
      recipes: [{
        candidate: duplicateCommodityCandidate,
        ingredients: [
          { sourceLine: "1 can black beans", sourceName: "black beans", quantityText: "1 can", commodityId: "canned-beans", grams: 400, decision: "alias", scalingStatus: "scaled", evidence: "Registered canned bean family." },
          { sourceLine: "1 can pinto beans", sourceName: "pinto beans", quantityText: "1 can", commodityId: "canned-beans", grams: 400, decision: "alias", scalingStatus: "scaled", evidence: "Registered canned bean family." },
          { sourceLine: "1 can tomatoes", sourceName: "tomatoes", quantityText: "1 can", commodityId: "tomatoes", grams: 1_050, decision: "exact", scalingStatus: "scaled", evidence: "Exact active commodity." },
        ],
        mealComponents: [
          { role: "main" as const, label: "beans", commodityIds: ["canned-beans"] },
          { role: "substantial-accompaniment" as const, label: "tomato vegetable base", commodityIds: ["tomatoes"] },
        ],
        readyForWriting: true,
        issues: [],
      }],
    };
    expect(recipeMapSchema.parse(mapped)).toEqual(mapped);
  });

  it("recomputes unit prices and requires sale validity dates", () => {
    const priced = {
      ...unpricedStores[0], outcome: "priced" as const, productName: "Test spice", packageText: "8 oz",
      sellerName: "Example Retailer", fulfillmentMode: "pickup" as const, availabilityText: "In stock",
      qualifyingProductsExamined: 3,
      packagePriceMinor: 400, normalizedBasisUnit: "oz" as const, normalizedBasisQtyMicros: 8_000_000,
      perUnitMicros: 500_000, offerKind: "sale" as const,
    };
    const research = {
      gapId: "gap_two", ingredientName: "Test spice", marketId: "omaha", researchedAt: "2026-08-13T12:00:00.000Z",
      disposition: "available", stores: [priced, ...unpricedStores.slice(1)],
      commodityProposal: { id: "test-spice", label: "Test Spice", categoryId: "pantry", unit: "oz", include: ["\\btest spice\\b"], exclude: [], searchTerms: ["test spice"] },
      summary: "One Omaha store has a verified qualifying price and the other checks completed without a result.",
    };
    expect(() => ingredientPriceResearchSchema.parse(research)).toThrow(/ad date window/);
    expect(() => ingredientPriceResearchSchema.parse({
      ...research,
      stores: [{ ...priced, offerKind: "everyday", perUnitMicros: 499_000 }, ...unpricedStores.slice(1)],
    })).toThrow(/normalized unit price/);
  });

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
      mealComponents: [
        { role: "main", label: "beans", commodityIds: ["beans"] },
        { role: "substantial-accompaniment", label: "tomato vegetable base", commodityIds: ["tomatoes"] },
      ],
      instructions: [
        { text: "Combine the beans and tomatoes in a large pot.", usesCommodityIds: ["beans", "tomatoes"] },
        { text: "Simmer gently for twenty minutes before serving.", usesCommodityIds: [] },
      ],
      provenance: [{ url: "https://example.test/chili", accessedAt: "2026-08-10T12:00:00.000Z" }],
    }] };
    expect(validateAgentOutput("content-items-v2", content, "request_one", "recipe-writer")).toEqual(content);
  });

  it("rejects a protein-only staged recipe before audit", () => {
    const content = { items: [{
      sourceCandidateId: "candidate-herb-chicken", sourceServings: 4,
      slug: "herb-chicken", title: "Herb Chicken", servings: 14,
      cuisine: "American", proteinClass: "chicken", method: "slow cooker",
      ingredients: [
        { name: "whole chicken", grams: 6_350, commodityId: "whole-chicken", sourceLine: "1 whole chicken" },
        { name: "onion", grams: 525, commodityId: "onions", sourceLine: "1 onion" },
      ],
      mealComponents: [
        { role: "main", label: "herb chicken", commodityIds: ["whole-chicken"] },
        { role: "substantial-accompaniment", label: "onion cooking bed", commodityIds: ["onions"] },
      ],
      instructions: [
        { text: "Cook the chicken and onions to a safe internal temperature.", usesCommodityIds: ["whole-chicken", "onions"] },
        { text: "Serve the chicken with the softened aromatic onions.", usesCommodityIds: ["whole-chicken", "onions"] },
      ],
      provenance: [{ url: "https://example.test/chicken", accessedAt: "2026-08-10T12:00:00.000Z" }],
    }] };
    expect(() => validateAgentOutput("content-items-v2", content, "request_one", "recipe-writer")).toThrow(/70 grams per serving/);
  });

  it("fences recipe source output to its request", () => {
    const sourceOutput = { requestId: "request_other", candidates: [candidate], rejectedSources: [], searchSummary: "One verified source was accepted." };
    expect(() => validateAgentOutput("recipe-source-candidates-v2", sourceOutput, "request_expected", "recipe-sourcer")).toThrow(/different request/);
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
      mealComponents: [
        { role: "main", label: "beans", commodityIds: ["beans"] },
        { role: "substantial-accompaniment", label: "tomato vegetable base", commodityIds: ["tomatoes"] },
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

describe("ingredient campaign orchestration", () => {
  const snapshot = (values: Partial<IngredientCampaignSnapshot> = {}): IngredientCampaignSnapshot => ({
    requestId: "campaign_200", state: "pricing", targetPublishedIngredients: 200,
    desiredPricingWorkers: 10, publishBatchSize: 20, pausedAt: null, discoveryFrozenAt: null,
    published: 13, pending: 100, researching: 10, readyToPublish: 20,
    permanentlyUnavailable: 1, needsOperator: 9, totalUniqueGaps: 153,
    ...values,
  });

  it("continues sourcing replacements when unavailable or judgment items leave fewer than the published target viable", () => {
    expect(ingredientCampaignPhase(snapshot())).toBe("collecting");
  });

  it("prices without extra sourcing when enough viable gaps remain", () => {
    expect(ingredientCampaignPhase(snapshot({ pending: 157, researching: 10, readyToPublish: 20 }))).toBe("pricing");
  });

  it("completes only from published ingredients", () => {
    expect(ingredientCampaignPhase(snapshot({ published: 200, pending: 50, researching: 5 }))).toBe("completed");
  });

  it("drains the current queue without sourcing when discovery is frozen", () => {
    expect(ingredientCampaignPhase(snapshot({ discoveryFrozenAt: "2026-08-13T17:20:00Z" }))).toBe("pricing");
  });

  it("completes a frozen campaign when no actionable queue remains", () => {
    expect(ingredientCampaignPhase(snapshot({
      discoveryFrozenAt: "2026-08-13T17:20:00Z", pending: 0, researching: 0,
      readyToPublish: 0, needsOperator: 0,
    }))).toBe("completed");
  });
});
