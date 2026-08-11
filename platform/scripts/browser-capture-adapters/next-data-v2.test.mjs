import { describe, expect, it } from "vitest";
import { walmartPickupEligible } from "./next-data-v2.mjs";

describe("Walmart pickup eligibility", () => {
  it("requires in-stock pickup at the configured Omaha store", () => {
    expect(walmartPickupEligible({ availabilityStatus: "IN_STOCK", pickupStoreIds: ["5361"] })).toBe(true);
    expect(walmartPickupEligible({ availabilityStatus: "IN_STOCK", pickupStoreIds: ["9999"] })).toBe(false);
    expect(walmartPickupEligible({ availabilityStatus: "OUT_OF_STOCK", pickupStoreIds: ["5361"] })).toBe(false);
    expect(walmartPickupEligible({ availabilityStatus: "IN_STOCK", pickupStoreIds: [] })).toBe(false);
  });
});
