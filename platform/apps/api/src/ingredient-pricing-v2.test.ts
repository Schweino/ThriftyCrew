import { describe, expect, it } from "vitest";
import { OMAHA_GROCERY_STORE_LOCATION_IDS } from "@thriftycrew/contracts";
import { aggregateStoreCheckStates, buildPermanentUnavailableResearch, retryAdapterQuarantinedStoreCheck } from "./ingredient-pricing-v2";

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

describe("quarantined adapter retry", () => {
  it("uses a state/version/evidence fence and records the operator reason", async () => {
    const statements: Array<{ sql: string; values: unknown[] }> = [];
    const db = { prepare(sql: string) { const row = { sql, values: [] as unknown[] }; statements.push(row); return {
      bind(...values: unknown[]) { row.values = values; return this; },
      async run() { return { meta: { changes: 1 } }; },
    }; } } as unknown as D1Database;
    await expect(retryAdapterQuarantinedStoreCheck(db, "check_1", {
      expectedStateVersion: 7, reason: "adapter 3.3.5 fixes complete Kroger tail coverage",
    })).resolves.toMatchObject({ checkId: "check_1", state: "capture_queued", stateVersion: 8 });
    expect(statements[0]?.sql).toContain("state = 'adapter_quarantined'");
    expect(statements[0]?.sql).toContain("state_version = ?2");
    expect(statements[0]?.sql).toContain("evidence_id IS NULL");
    expect(statements[1]?.values[1]).toContain("adapter 3.3.5");
  });

  it("fails closed when the quarantine fence changed", async () => {
    const db = { prepare() { return { bind() { return this; }, async run() { return { meta: { changes: 0 } }; } }; } } as unknown as D1Database;
    await expect(retryAdapterQuarantinedStoreCheck(db, "check_1", {
      expectedStateVersion: 7, reason: "adapter correction is ready for a fenced retry",
    })).rejects.toThrow(/lost its quarantined state\/version fence/);
  });
});
