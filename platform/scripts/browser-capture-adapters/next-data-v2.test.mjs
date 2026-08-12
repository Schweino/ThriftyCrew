import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import { captureNextDataCanary, packageSizeFromName, parseNextDataOfferItem, pickupEligible, sourcePriceSemantics, walmartPickupEligible } from "./next-data-v2.mjs";

describe("Walmart pickup eligibility", () => {
  it("requires in-stock pickup at the configured Omaha store", () => {
    expect(walmartPickupEligible({ availabilityStatus: "IN_STOCK", pickupStoreIds: ["5361"] })).toBe(true);
    expect(walmartPickupEligible({ availabilityStatus: "IN_STOCK", pickupStoreIds: ["9999"] })).toBe(false);
    expect(walmartPickupEligible({ availabilityStatus: "OUT_OF_STOCK", pickupStoreIds: ["5361"] })).toBe(false);
    expect(walmartPickupEligible({ availabilityStatus: "IN_STOCK", pickupStoreIds: [] })).toBe(false);
  });
});

describe("source-native offer parsing", () => {
  it("replays sanitized real source fragments including a must-fire shipping-only case", async () => {
    const fixture = JSON.parse(await readFile(new URL("../../fixtures/browser-capture/next-data-source-offers.json", import.meta.url), "utf8"));
    for (const item of fixture.cases) {
      const parsed = parseNextDataOfferItem(item.item, item.origin);
      expect(packageSizeFromName(parsed.name), item.id).toBe(item.expect.size);
      expect(sourcePriceSemantics(item.store, parsed).unitPriceMinor, item.id).toBe(item.expect.priceMinor);
      expect(parsed.unitPrice, item.id).toBe(item.expect.unitPrice);
      expect(pickupEligible(parsed, item.expect.pickupLocation), item.id).toBe(item.expect.eligible);
    }
  });
  it("extracts single and multipack package sizes from real retailer title shapes", () => {
    expect(packageSizeFromName("Great Value Whole Milk, Gallon")).toBe("1 gal");
    expect(packageSizeFromName("Kemps Protein+ Whole Milk, 48 Fl. Oz.")).toBe("48 fl oz");
    expect(packageSizeFromName("Silk Almond Milk, 64 fl. oz., 3 pk.")).toBe("3 x 64 fl oz");
    expect(packageSizeFromName("Large Eggs (24 ct)")).toBe("24 ct");
  });

  it("preserves promotion conditions instead of labeling every price everyday", () => {
    expect(sourcePriceSemantics("walmart", { linePrice: "$2.50", promotionText: "2 for $5.00", wasPrice: "$3.29" })).toMatchObject({ offerType: "multibuy", condition: "quantity", qualifyingQuantity: 2, totalPriceMinor: 500, regularPriceMinor: 329 });
    expect(sourcePriceSemantics("sams", { linePrice: "$8.83", promotionText: "", wasPrice: "" })).toMatchObject({ offerType: "member", condition: "membership", unitPriceMinor: 883 });
  });

  it("requires in-stock pickup at the retailer's configured location", () => {
    expect(pickupEligible({ availabilityStatus: "IN_STOCK", pickupStoreIds: ["8146"] }, "8146")).toBe(true);
    expect(pickupEligible({ availabilityStatus: "IN_STOCK", pickupStoreIds: ["6279"] }, "8146")).toBe(false);
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
