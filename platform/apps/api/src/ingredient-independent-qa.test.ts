import { describe, expect, it } from "vitest";
import { hasCompleteLocationModeProof, isCompleteVerificationTerm } from "./ingredient-independent-qa";

const common = { storeLocationId: "aldi-omaha-446-048", checkedAt: "2026-08-13T20:00:00.000Z",
  queryTerms: ["test"], searchComplete: true, qualifyingProductsExamined: 0, locationVerified: true,
  priceModeVerified: true, sourceUrl: "https://www.aldi.us/store/aldi/s?k=test", evidenceSummary: "complete" } as const;

describe("ingredient independent QA capture proof", () => {
  it("treats an explicit empty no-results envelope as complete", () => {
    expect(isCompleteVerificationTerm({ outcome: "empty", retrieval: { termination: "no-results", hasMoreResults: false } })).toBe(true);
    expect(isCompleteVerificationTerm({ outcome: "success", retrieval: { termination: "target-depth", hasMoreResults: true } })).toBe(false);
  });

  it("accepts a complete location-bound no-result search without inventing product fulfillment", () => {
    expect(hasCompleteLocationModeProof({ ...common, outcome: "not_found", productName: null, sellerName: null,
      fulfillmentMode: null, availabilityText: null, packageText: null, packagePriceMinor: null,
      normalizedBasisUnit: null, normalizedBasisQtyMicros: null, perUnitMicros: null, offerKind: null,
      validFrom: null, validTo: null, loyaltyRequired: false, membershipRequired: false } as unknown as Parameters<typeof hasCompleteLocationModeProof>[0], "in_store")).toBe(true);
  });

  it("requires a priced result to match the registered store price mode", () => {
    const priced = { ...common, outcome: "priced", qualifyingProductsExamined: 1, productName: "Test", sellerName: "Aldi",
      fulfillmentMode: "pickup", availabilityText: "In stock", packageText: "8 oz", packagePriceMinor: 400,
      normalizedBasisUnit: "oz", normalizedBasisQtyMicros: 8_000_000, perUnitMicros: 500_000,
      offerKind: "everyday", validFrom: null, validTo: null, loyaltyRequired: false, membershipRequired: false } as const;
    expect(hasCompleteLocationModeProof(priced as unknown as Parameters<typeof hasCompleteLocationModeProof>[0], "in_store")).toBe(false);
  });
});
