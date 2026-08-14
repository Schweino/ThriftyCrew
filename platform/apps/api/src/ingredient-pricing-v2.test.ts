import { describe, expect, it } from "vitest";
import { OMAHA_GROCERY_STORE_LOCATION_IDS } from "@thriftycrew/contracts";
import { aggregateStoreCheckStates, buildPermanentUnavailableResearch } from "./ingredient-pricing-v2";

describe("ingredient pricing v2 aggregate", () => {
  it("accepts one priced store and six validated not-found stores", () => {
    expect(aggregateStoreCheckStates(OMAHA_GROCERY_STORE_LOCATION_IDS.map((_, index) => ({
      state: index === 0 ? "qa_verified_priced" : "qa_verified_not_found",
    })))).toMatchObject({ state: "ready_to_publish", terminalCount: 7, pricedCount: 1, notFoundCount: 6 });
  });

  it("marks seven validated not-found stores permanently unavailable", () => {
    expect(aggregateStoreCheckStates(OMAHA_GROCERY_STORE_LOCATION_IDS.map(() => ({ state: "qa_verified_not_found" }))))
      .toMatchObject({ state: "permanently_unavailable", terminalCount: 7, pricedCount: 0, notFoundCount: 7 });
  });

  it("builds the durable research required by permanently-unavailable gaps", () => {
    const stores = OMAHA_GROCERY_STORE_LOCATION_IDS.map((storeLocationId) => ({
      storeLocationId,
      outcome: "not_found" as const,
      checkedAt: "2026-08-14T06:23:00.000Z",
      queryTerms: ["minced lemongrass"],
      searchComplete: true,
      qualifyingProductsExamined: 0,
      locationVerified: true,
      priceModeVerified: true,
      sourceUrl: "https://example.com/store-search",
      evidenceSummary: "Complete first-party location-bound search found no qualifying exact product.",
      productName: null,
      sellerName: null,
      fulfillmentMode: null,
      availabilityText: null,
      packageText: null,
      packagePriceMinor: null,
      normalizedBasisUnit: null,
      normalizedBasisQtyMicros: null,
      perUnitMicros: null,
      offerKind: null,
      validFrom: null,
      validTo: null,
      loyaltyRequired: false,
      membershipRequired: false,
    }));
    expect(buildPermanentUnavailableResearch({
      gapId: "ingredient-gap_test",
      ingredientName: "minced lemongrass",
      researchedAt: "2026-08-14T06:23:00.000Z",
      stores,
    })).toMatchObject({ disposition: "permanently_unavailable", stores });
  });

  it("keeps blocked, ambiguous, and incomplete stores nonterminal", () => {
    for (const state of ["blocked_challenge", "ambiguous", "qa_pending"]) {
      const aggregate = aggregateStoreCheckStates(OMAHA_GROCERY_STORE_LOCATION_IDS.map((_, index) => ({
        state: index === 0 ? "qa_verified_priced" : index === 6 ? state : "qa_verified_not_found",
      })));
      expect(aggregate).toMatchObject({ state: "store_checks_running", terminalCount: 6, pricedCount: 1, notFoundCount: 5 });
    }
  });
});
