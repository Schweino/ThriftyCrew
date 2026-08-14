import { describe, expect, it } from "vitest";
import { buildIngredientCapturePayload, buildIngredientQaPayload, type AdapterChunk, type ClaimedCheck } from "./ingredient-targeted-capture";

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
  it("locks every candidate to one comparison basis and deterministically selects the cheapest eligible product", async () => {
    const payload = await buildIngredientCapturePayload(claim, [chunk], evidence, new Date(observedAt));
    expect(payload.result).toMatchObject({ outcome: "priced", productName: "Great Value Test Spice", normalizedBasisUnit: "oz",
      normalizedBasisQtyMicros: 8_000_000, perUnitMicros: 500_000, qualifyingProductsExamined: 1 });
    expect(payload.coverage).toMatchObject([{ normalizedQuery: "test spice", terminationReason: "end_of_results", resultCount: 1 }]);
  });

  it("rejects a truncated producer search", async () => {
    const truncated = structuredClone(chunk);
    (truncated.terms![0]!.retrieval as Record<string, unknown>).hasMoreResults = true;
    (truncated.terms![0]!.retrieval as Record<string, unknown>).termination = "target-depth";
    await expect(buildIngredientCapturePayload(claim, [truncated], evidence, new Date(observedAt))).rejects.toThrow(/end-of-results coverage/);
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
});
