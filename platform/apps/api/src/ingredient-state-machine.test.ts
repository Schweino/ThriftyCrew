import { describe, expect, it } from "vitest";
import { OMAHA_GROCERY_STORE_LOCATION_IDS } from "@thriftycrew/contracts";
import { aggregateIngredientStoreChecks, assertStoreCheckTransition } from "./ingredient-state-machine";

describe("ingredient v3 state machine", () => {
  it("requires exactly one terminal result for every authoritative store", () => {
    expect(aggregateIngredientStoreChecks(OMAHA_GROCERY_STORE_LOCATION_IDS.map((storeLocationId, index) => ({
      storeLocationId, state: index === 0 ? "qa_verified_priced" : "qa_verified_not_found",
    })))).toEqual({ state: "ready_to_publish", terminalCount: 7, pricedCount: 1, notFoundCount: 6 });
  });

  it("rejects a duplicated store even when seven rows are supplied", () => {
    const duplicate: Array<{ storeLocationId: string; state: string }> = OMAHA_GROCERY_STORE_LOCATION_IDS
      .map((storeLocationId) => ({ storeLocationId, state: "qa_verified_not_found" }));
    duplicate[6] = { storeLocationId: String(duplicate[0]?.storeLocationId), state: "qa_verified_not_found" };
    expect(() => aggregateIngredientStoreChecks(duplicate)).toThrow(/exactly one check/);
  });

  it("keeps challenges nonterminal and allows only canary-backed requeue transitions", () => {
    expect(() => assertStoreCheckTransition("challenge_blocked", "qa_verified_priced")).toThrow(/invalid/);
    expect(() => assertStoreCheckTransition("challenge_blocked", "capture_queued")).not.toThrow();
  });

  it("makes cancellation terminal", () => {
    expect(() => assertStoreCheckTransition("cancelled", "capture_queued")).toThrow(/invalid/);
  });
});
