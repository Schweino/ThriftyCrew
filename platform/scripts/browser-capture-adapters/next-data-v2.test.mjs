import { describe, expect, it } from "vitest";
import { captureNextDataCanary, walmartPickupEligible } from "./next-data-v2.mjs";

describe("Walmart pickup eligibility", () => {
  it("requires in-stock pickup at the configured Omaha store", () => {
    expect(walmartPickupEligible({ availabilityStatus: "IN_STOCK", pickupStoreIds: ["5361"] })).toBe(true);
    expect(walmartPickupEligible({ availabilityStatus: "IN_STOCK", pickupStoreIds: ["9999"] })).toBe(false);
    expect(walmartPickupEligible({ availabilityStatus: "OUT_OF_STOCK", pickupStoreIds: ["5361"] })).toBe(false);
    expect(walmartPickupEligible({ availabilityStatus: "IN_STOCK", pickupStoreIds: [] })).toBe(false);
  });
});

describe("next-data location canary", () => {
  it("waits for Sam's pickup location hydration before passing", async () => {
    const states = [
      { url: "https://www.samsclub.com/search?q=milk", body: "Loading", challenge: false },
      { url: "https://www.samsclub.com/search?q=milk", body: "Pickup\nOmaha Sam's Club", challenge: false },
    ];
    const waits = [];
    const tab = {
      playwright: {
        evaluate: async () => states.shift(),
        waitForTimeout: async (milliseconds) => waits.push(milliseconds),
      },
    };

    const canary = await captureNextDataCanary(tab, "sams");

    expect(canary.locationVerified).toBe(true);
    expect(waits).toEqual([750]);
  });

  it("fails immediately on a retailer challenge", async () => {
    let evaluations = 0;
    const tab = {
      playwright: {
        evaluate: async () => {
          evaluations += 1;
          return { url: "https://www.samsclub.com/are-you-human", body: "Verify you are human", challenge: true };
        },
        waitForTimeout: async () => {
          throw new Error("must not wait on a challenge");
        },
      },
    };

    await expect(captureNextDataCanary(tab, "sams")).rejects.toThrow("retailer block page detected");
    expect(evaluations).toBe(1);
  });
});
