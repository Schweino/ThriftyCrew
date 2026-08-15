import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import { buildNextDataRows, buildNextDataSuccess, captureNextDataCanary, findVerificationRow, packageSizeFromName, parseNextDataOfferItem, pickupEligible, sourcePriceSemantics, walmartPickupEligible } from "./next-data-v2.mjs";

describe("next-data winner verification", () => {
  it("finds the frozen winner by canonical URL while retaining the retailer id", () => {
    const rows = [{ id: "7874229289", url: "https://www.samsclub.com/ip/item/7874229289" }];
    expect(findVerificationRow(rows, { productKey: rows[0].url })).toBe(rows[0]);
    expect(findVerificationRow(rows, { productKey: rows[0].url, retailerProductId: rows[0].id })).toBe(rows[0]);
  });
});

describe("next-data pagination implementation", () => {
  it("uses canonical page navigation when Walmart exposes only a hash href", async () => {
    const source = await readFile(new URL("./next-data-v2.mjs", import.meta.url), "utf8");
    expect(source).toContain('continuation.searchParams.set("page", String(pageCount + 1))');
    expect(source).toContain("await tab.goto(continuation.href)");
    expect(source).toContain('replace(/#.*$/, "")');
  });
});

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
    expect(packageSizeFromName("Minute Ready-to-Eat Jasmine Rice, Microwaveable Rice Cups, 4.4 oz, 2 Count")).toBe("2 x 4.4 oz");
    expect(packageSizeFromName("Large Eggs (24 ct)")).toBe("24 ct");
    expect(packageSizeFromName("Happy Farms String Cheese 10 OZ")).toBe("10 oz");
    expect(packageSizeFromName("McCormick Pure Vanilla Extract, 1.0 fl oz Box")).toBe("1.0 fl oz");
    expect(packageSizeFromName("Sam's Zero Sugar Cola Soda, 2 Liter Bottle")).toBe("2 l");
    expect(packageSizeFromName("Maruchan Instant Lunch Ramen Noodles, Chicken Flavor, 2.25 oz Cup")).toBe("2.25 oz");
    expect(packageSizeFromName('The Cheesecake Factory Famous "Brown Bread", 18.7 oz, Kosher Rye Bread, Bag')).toBe("18.7 oz");
    expect(packageSizeFromName("Dave's Killer Bread, 20.5 oz Loaf")).toBe("20.5 oz");
    expect(packageSizeFromName("Wholesum Organic Mixed Squash, 3 lbs.")).toBe("3 lb");
    expect(packageSizeFromName("Jimmy Dean Turkey Sausage Patties 24 ct.")).toBe("24 ct");
    expect(packageSizeFromName("Reynolds Heavy Duty Aluminum Foil, 18in x 120 sq. ft., 2pk")).toBe("2 x 120 sq ft");
    expect(packageSizeFromName("Member's Mark Tilapia Fillet, priced per pound")).toBe("");
    expect(packageSizeFromName("Lobster Tails, 4 ct., priced per pound")).toBe("");
    expect(packageSizeFromName("Mixed Squash, 3 lbs., priced per pound")).toBe("");
  });

  it("preserves promotion conditions instead of labeling every price everyday", () => {
    expect(sourcePriceSemantics("walmart", { linePrice: "$2.50", promotionText: "2 for $5.00", wasPrice: "$3.29" })).toMatchObject({ offerType: "multibuy", condition: "quantity", qualifyingQuantity: 2, totalPriceMinor: 500, regularPriceMinor: 329 });
    expect(sourcePriceSemantics("sams", { linePrice: "$8.83", promotionText: "", wasPrice: "" })).toMatchObject({ offerType: "member", condition: "membership", unitPriceMinor: 883 });
  });

  it("requires in-stock pickup at the retailer's configured location", () => {
    expect(pickupEligible({ availabilityStatus: "IN_STOCK", pickupStoreIds: ["8146"] }, "8146")).toBe(true);
    expect(pickupEligible({ availabilityStatus: "IN_STOCK", pickupStoreIds: ["6279"] }, "8146")).toBe(false);
  });

  it("records an unpriceable retailer row without discarding exact rows from the term", () => {
    const capturedAt = "2026-08-12T19:00:00.000Z";
    const base = { linePrice: "$4.25", unitPrice: "", wasPrice: "", priceDisplayCondition: "", savings: "", memberPriceString: "", promotionText: "", taxonomy: "0:1", url: "https://www.samsclub.com/p/item", imageUrl: "", availabilityStatus: "IN_STOCK", availabilityText: "In stock", offerId: "offer", sellerName: "Sam's Club", pickupStoreIds: ["8146"] };
    const result = buildNextDataRows("sams", "turkey", {
      url: "https://www.samsclub.com/s/turkey", title: "Turkey", query: "turkey", locale: "en-US",
      rows: [{ ...base, id: "exact", name: "Turkey Breast, 2 lb Bag", visiblePrice: "$4.25" }, { ...base, id: "missing-size", name: "Premium Carved Turkey Breast", visiblePrice: "$4.25" }],
    }, capturedAt);
    expect(result.rows).toHaveLength(2);
    expect(result.rows[0]).toMatchObject({ id: "exact", size: "2 lb", availability_status: "in_stock", fulfillment_mode: "pickup", seller_name: "Sam's Club", offer_id: "offer" });
    expect(result.rows[1]).toMatchObject({ id: "missing-size", size: "", _capture: { offer: {
      sizeText: "", candidateIssues: ["invalid_package_basis"] }, parser: { status: "typed_unpriceable" } } });
    expect(result.excludedResults).toEqual([]);
  });

  it("keeps complete raw-result accounting for a typed unpriceable row", () => {
    const built = buildNextDataRows("sams", "turkey", { url: "https://www.samsclub.com/s/turkey", title: "Turkey", query: "turkey", locale: "en-US",
      rows: [{ id: "missing-size", name: "Premium Turkey", linePrice: "$4.25", unitPrice: "", wasPrice: "", priceDisplayCondition: "", savings: "", memberPriceString: "", promotionText: "", taxonomy: "", url: "https://www.samsclub.com/p/item", imageUrl: "", availabilityStatus: "IN_STOCK", availabilityText: "In stock", offerId: "", sellerName: "Sam's Club", pickupStoreIds: ["8146"], visiblePrice: "$4.25" }] }, "2026-08-12T19:00:00.000Z");
    expect(buildNextDataSuccess("turkey", { hasMore: false }, built, { attempts: 1, startedAt: "2026-08-12T19:00:00.000Z", finishedAt: "2026-08-12T19:00:01.000Z" })).toMatchObject({
      blocked: false, rows: [{ id: "missing-size" }], term: { outcome: "success", rowCount: 1, retrieval: { loadedResultCount: 1, availableResultCount: 1 } },
    });
  });
});

describe("next-data location canary", () => {
  it("binds Walmart pickup evidence to store 5361 at 12850 L St, not the shopper shipping address", async () => {
    const tab = {
      playwright: {
        evaluate: async () => ({
          url: "https://www.walmart.com/search?q=milk&facet=fulfillment_method%3APickup",
          body: "12812 S 38TH St\nOmaha L St Supercenter\n12850 L St, Omaha, NE 68137",
          challenge: false,
        }),
        waitForTimeout: async () => { throw new Error("exact store canary should pass immediately"); },
      },
    };

    await expect(captureNextDataCanary(tab, "walmart")).resolves.toMatchObject({
      location: "Omaha L St Supercenter, 12850 L St, Omaha, NE 68137",
      locationId: "5361",
      retailerLocationKey: "5361",
      locationVerified: true,
      priceModeVerified: true,
    });
  });

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
    expect(canary.locationId).toBe("8146");
    expect(canary.retailerLocationKey).toBe("8146");
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
