import { describe, expect, it } from "vitest";
import { OMAHA_GROCERY_STORE_LOCATION_IDS } from "@thriftycrew/contracts";
import { aggregateStoreCheckStates } from "./ingredient-pricing-v2";

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

  it("keeps blocked, ambiguous, and incomplete stores nonterminal", () => {
    for (const state of ["blocked_challenge", "ambiguous", "qa_pending"]) {
      const aggregate = aggregateStoreCheckStates(OMAHA_GROCERY_STORE_LOCATION_IDS.map((_, index) => ({
        state: index === 0 ? "qa_verified_priced" : index === 6 ? state : "qa_verified_not_found",
      })));
      expect(aggregate).toMatchObject({ state: "store_checks_running", terminalCount: 6, pricedCount: 1, notFoundCount: 5 });
    }
  });
});
