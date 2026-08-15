import { describe, expect, it } from "vitest";
import { buildIngredientCapturePayload, buildIngredientQaPayload, isClearlyDerivativeProduct, isClearlyNonFoodProduct, matchesCommodityExclusion, mergeIngredientQaDiscoveryChunks, type AdapterChunk, type ClaimedCheck } from "./ingredient-targeted-capture";

const hash = (character: string) => character.repeat(64);
const observedAt = "2026-08-13T20:00:00.000Z";
const claim: ClaimedCheck = {
  id: "check_one", store_location_id: "walmart-omaha", lease_owner: "capture-owner", lease_generation: 2,
  query_plan_hash: hash("a"), canonical_term: "test spice", aliases_json: "[]", exclusions_json: "[]",
  commodity_proposal_json: JSON.stringify({ id: "test-spice", label: "Test Spice", categoryId: "pantry", unit: "oz",
    include: ["\\btest spice\\b"], exclude: ["extract"], searchTerms: ["test spice"] }),
};
const priceSemantics = { offerType: "everyday", condition: "none", unitPriceMinor: 400, qualifyingQuantity: 1, totalPriceMinor: 400, ambiguity: false };
const chunk: AdapterChunk = {
  version: 2, phase: "discovery", store: "walmart",
  canary: { evidenceUrl: "https://www.walmart.com/search?q=test%20spice", observedAt, locationVerified: true, priceModeVerified: true },
  terms: [{ query: "test spice", outcome: "success", rowCount: 1, finishedAt: observedAt,
    retrieval: { pageCount: 1, availableResultCount: 1, hasMoreResults: false, termination: "end-of-results" } }],
  rows: [{ q: "test spice", id: "123", n: "Great Value Test Spice", size: "8 oz", url: "https://www.walmart.com/ip/test-spice/123",
    _capture: { visible: { priceMinor: 400, priceSemantics }, offer: { retailerProductId: "123", productName: "Great Value Test Spice",
      sourceUrl: "https://www.walmart.com/ip/test-spice/123", sizeText: "8 oz", purchasePriceMinor: 400, sellerName: "Walmart.com",
      availability: { status: "in_stock", eligible: true, rawText: "Pickup today" }, priceSemantics } } }],
};
const evidence = { objectKey: "ingredient-store-evidence/check/producer/hash.json", sha256: hash("b"), byteLength: 100,
  contentType: "application/json", sourceUrl: chunk.canary.evidenceUrl, observedAt };

describe("targeted ingredient capture bridge", () => {
  it("accepts a redundant leading inline case-insensitive flag", async () => {
    const inlineFlagClaim = { ...claim, commodity_proposal_json: JSON.stringify({
      id: "test-spice", label: "Test Spice", categoryId: "pantry", unit: "oz",
      include: ["(?i)\\btest spice\\b"], exclude: [], searchTerms: ["test spice"],
    }) };
    const payload = await buildIngredientCapturePayload(inlineFlagClaim, [chunk], evidence, new Date(observedAt));
    expect(payload.result.outcome).toBe("priced");
  });

  it("fails closed on non-food products whose names happen to match an ingredient", () => {
    expect(isClearlyNonFoodProduct("Spicy Cinnamon Stick Scented Wax Melts", "Home Decor")).toBe(true);
    expect(isClearlyNonFoodProduct("Aussie Miracle Moist Conditioner with Avocado Oil Paraben Free", "Grocery")).toBe(true);
    expect(isClearlyNonFoodProduct("Aussie Conditioner, With Avocado Oil 12.1 Fl Oz", "Grocery")).toBe(true);
    expect(isClearlyNonFoodProduct("Dossier Ambery Saffron Eau De Parfum, 1.7 oz", "Beauty")).toBe(true);
    expect(isClearlyNonFoodProduct("Organic Cinnamon Sticks", "Pantry / Spices")).toBe(false);
  });

  it("fails closed on prepared derivatives when the ingredient is the whole commodity", () => {
    expect(isClearlyDerivativeProduct("ingredient-definition-pistachios", "Pillsbury Pistachio Frosting")).toBe(true);
    expect(isClearlyDerivativeProduct("ingredient-definition-pistachios", "Pistachio Muffins 4 Ct")).toBe(true);
    expect(isClearlyDerivativeProduct("ingredient-definition-pistachios", "Wonderful Roasted Pistachios")).toBe(false);
    expect(isClearlyDerivativeProduct("ingredient-definition-green-chilli", "HATCH Diced Tomatoes & Green Chiles")).toBe(true);
    expect(isClearlyDerivativeProduct("ingredient-definition-green-chilli", "Fresh Green Chili Pepper")).toBe(false);
    expect(isClearlyDerivativeProduct("ingredient-definition-saffron", "Mahatma Authentic Saffron Yellow Rice")).toBe(true);
    expect(isClearlyDerivativeProduct("ingredient-definition-saffron", "Premium Saffron Threads")).toBe(false);
  });

  it("applies package-form synonyms in locked exclusions", () => {
    expect(matchesCommodityExclusion(["\\bcanned\\b"], "Giorgio Portabella Mushrooms", "4 oz Can")).toBe(true);
    expect(matchesCommodityExclusion(["\\bdried\\b"], "Dry Portabella Mushroom Slices", "2 oz")).toBe(true);
    expect(matchesCommodityExclusion(["\\bcanned\\b"], "Fresh Portabella Mushrooms", "6 oz")).toBe(false);
  });

  it("keeps non-food matches in the evidence set but makes them ineligible", async () => {
    const nonFood = structuredClone(chunk);
    nonFood.rows![0]!.n = "Test Spice Scented Wax Melt";
    (nonFood.rows![0]!._capture as Record<string, any>).offer.productName = "Test Spice Scented Wax Melt";
    const payload = await buildIngredientCapturePayload(claim, [nonFood], evidence, new Date(observedAt));
    expect(payload.result.outcome).toBe("not_found");
    expect(payload.candidates[0]).toMatchObject({ eligible: false, rejectionCodes: ["non_food_product"] });
  });

  it("locks every candidate to one comparison basis and deterministically selects the cheapest eligible product", async () => {
    const payload = await buildIngredientCapturePayload(claim, [chunk], evidence, new Date(observedAt));
    expect(payload.result).toMatchObject({ outcome: "priced", productName: "Great Value Test Spice", normalizedBasisUnit: "oz",
      normalizedBasisQtyMicros: 8_000_000, perUnitMicros: 500_000, qualifyingProductsExamined: 1 });
    expect(payload.coverage).toMatchObject([{ normalizedQuery: "test spice", terminationReason: "end_of_results", resultCount: 1 }]);
  });

  it("keeps Aluminum Foil multipacks on their square-foot material basis", async () => {
    const foilClaim = { ...claim, commodity_proposal_json: JSON.stringify({ id: "aluminum-foil", label: "Aluminum Foil",
      categoryId: "household", unit: "sq_ft", include: ["aluminum\\s+foil"], exclude: [], searchTerms: ["test spice"] }) };
    const foil = structuredClone(chunk);
    foil.rows![0]!.n = "Reynolds Heavy Duty Aluminum Foil, 18in x 120 sq. ft., 2pk";
    foil.rows![0]!.size = "2 x 120 sq ft";
    const offer = (foil.rows![0]!._capture as Record<string, any>).offer;
    offer.productName = foil.rows![0]!.n; offer.sizeText = foil.rows![0]!.size;
    const payload = await buildIngredientCapturePayload(foilClaim, [foil], evidence, new Date(observedAt));
    expect(payload.result).toMatchObject({ outcome: "priced", normalizedBasisUnit: "sq_ft",
      normalizedBasisQtyMicros: 240_000_000 });
  });

  it("rejects a truncated producer search", async () => {
    const truncated = structuredClone(chunk);
    (truncated.terms![0]!.retrieval as Record<string, unknown>).hasMoreResults = true;
    (truncated.terms![0]!.retrieval as Record<string, unknown>).termination = "target-depth";
    await expect(buildIngredientCapturePayload(claim, [truncated], evidence, new Date(observedAt))).rejects.toThrow(/end-of-results coverage/);
  });

  it("accepts an explicit no-results terminal as complete empty coverage", async () => {
    const empty = structuredClone(chunk);
    empty.terms![0]!.outcome = "empty";
    empty.terms![0]!.rowCount = 0;
    empty.terms![0]!.retrieval = { pageCount: 1, loadedResultCount: 0, hasMoreResults: false, termination: "no-results" };
    empty.rows = [];
    const payload = await buildIngredientCapturePayload(claim, [empty], evidence, new Date(observedAt));
    expect(payload.result.outcome).toBe("not_found");
  });

  it("deduplicates the same product found by multiple locked queries when only observation metadata differs", async () => {
    const multiClaim = { ...claim, commodity_proposal_json: JSON.stringify({ id: "test-spice", label: "Test Spice", categoryId: "pantry", unit: "oz",
      include: ["\\btest spice\\b"], exclude: ["extract"], searchTerms: ["test spice", "whole test spice"] }) };
    const first = structuredClone(chunk);
    const second = structuredClone(chunk);
    second.canary.observedAt = "2026-08-13T20:01:00.000Z";
    second.terms![0]!.query = "whole test spice";
    second.terms![0]!.finishedAt = second.canary.observedAt;
    second.rows![0]!.q = "whole test spice";
    (first.rows![0]!._capture as Record<string, any>).offer.observedAt = observedAt;
    (second.rows![0]!._capture as Record<string, any>).offer.observedAt = second.canary.observedAt;
    const payload = await buildIngredientCapturePayload(multiClaim, [first, second], evidence, new Date(second.canary.observedAt));
    expect(payload.candidates).toHaveLength(1);
    expect(payload.result).toMatchObject({ outcome: "priced", packagePriceMinor: 400 });
  });

  it("uses the retailer row id when a legacy offer incorrectly carries a URL-shaped product id", async () => {
    const legacy = structuredClone(chunk);
    (legacy.rows![0]!._capture as Record<string, any>).offer.retailerProductId = "https://www.walmart.com/ip/test-spice/123";
    const payload = await buildIngredientCapturePayload(claim, [legacy], evidence, new Date(observedAt));
    expect(payload.candidates[0]!.productId).toBe("123");
  });

  it("requires the independent pass to reproduce the frozen winner", () => {
    const qaClaim = { ...claim, lease_owner: "qa-owner", lease_generation: 3, capture_result_json: JSON.stringify({
      outcome: "priced", sourceUrl: "https://www.walmart.com/ip/test-spice/123", productName: "Great Value Test Spice",
      packageText: "8 oz", packagePriceMinor: 400, queryTerms: ["test spice"],
    }) };
    const verification: AdapterChunk = { version: 2, phase: "verification", store: "walmart", canary: chunk.canary,
      verifications: [{ outcome: "observed", productKey: "https://www.walmart.com/ip/test-spice/123", name: "Great Value Test Spice", sizeText: "8 oz", purchasePriceMinor: 400 }] };
    expect(buildIngredientQaPayload(qaClaim, verification, { ...evidence, objectKey: "ingredient-store-evidence/check/verifier/hash.json", sha256: hash("c") }).verdict).toBe("priced");
    verification.verifications![0]!.purchasePriceMinor = 499;
    expect(() => buildIngredientQaPayload(qaClaim, verification, { ...evidence, objectKey: "ingredient-store-evidence/check/verifier/hash.json", sha256: hash("c") })).toThrow(/does not reproduce/);
  });

  it("verifies a no-match result from complete searches that returned only ineligible products", () => {
    const qaClaim = { ...claim, lease_owner: "qa-owner", lease_generation: 3, capture_result_json: JSON.stringify({
      outcome: "not_found", queryTerms: ["test spice"], qualifyingProductsExamined: 0,
    }) };
    const repeated = structuredClone(chunk);
    repeated.rows![0]!.n = "Unrelated Extract";
    (repeated.rows![0]!._capture as Record<string, any>).offer.productName = "Unrelated Extract";
    expect(buildIngredientQaPayload(qaClaim, repeated, { ...evidence, objectKey: "ingredient-store-evidence/check/verifier/hash.json",
      sha256: hash("c"), observedAt: "2026-08-13T20:02:00.000Z" }).verdict).toBe("not_found");
    (repeated.rows![0]!._capture as Record<string, any>).offer.productName = "Great Value Test Spice";
    expect(() => buildIngredientQaPayload(qaClaim, repeated, { ...evidence, objectKey: "ingredient-store-evidence/check/verifier/hash.json",
      sha256: hash("c"), observedAt: "2026-08-13T20:02:00.000Z" })).toThrow(/eligible exact candidate/);
  });

  it("verifies a no-match result from an explicit empty no-results search", () => {
    const qaClaim = { ...claim, lease_owner: "qa-owner", lease_generation: 3, capture_result_json: JSON.stringify({
      outcome: "not_found", queryTerms: ["test spice"], qualifyingProductsExamined: 0,
    }) };
    const repeated = structuredClone(chunk);
    repeated.terms![0]!.outcome = "empty";
    repeated.terms![0]!.rowCount = 0;
    repeated.terms![0]!.retrieval = { pageCount: 1, loadedResultCount: 0, hasMoreResults: false, termination: "no-results" };
    repeated.rows = [];
    expect(buildIngredientQaPayload(qaClaim, repeated, { ...evidence, objectKey: "ingredient-store-evidence/check/verifier/empty.json",
      sha256: hash("c"), observedAt: "2026-08-13T20:02:00.000Z" }).verdict).toBe("not_found");
  });

  it("merges bounded independent discovery chunks without losing query coverage", () => {
    const second = structuredClone(chunk);
    second.terms![0]!.query = "whole test spice";
    second.rows![0]!.q = "whole test spice";
    second.canary.observedAt = "2026-08-13T20:01:00.000Z";
    const merged = mergeIngredientQaDiscoveryChunks([chunk, second]);
    expect(merged.terms?.map((term) => term.query)).toEqual(["test spice", "whole test spice"]);
    expect(merged.canary.observedAt).toBe(second.canary.observedAt);
  });
});
