import { describe, expect, it } from "vitest";
import { ingredientPublicationObservation } from "./ingredient-publication-v2";

describe("ingredient publication capture materialization", () => {
  it("turns a QA-verified package price into an exact durable observation", async () => {
    const observation = await ingredientPublicationObservation("walmart-omaha", "ingredient-definition-pistachios", {
      checkedAt: "2026-08-14T01:40:00.000Z",
      sourceUrl: "https://www.walmart.com/ip/test/123",
      productName: "Great Value Pistachios",
      packageText: "24 oz",
      packagePriceMinor: 1096,
      normalizedBasisUnit: "oz",
      normalizedBasisQtyMicros: 24_000_000,
      perUnitMicros: 456_667,
      validFrom: null,
      validTo: null,
      offerKind: "everyday",
      availabilityText: "In stock",
      fulfillmentMode: "pickup",
      sellerName: "Walmart",
      loyaltyRequired: false,
      membershipRequired: false,
    });

    expect(observation).toMatchObject({
      name: "Great Value Pistachios",
      kind: "everyday",
      purchasePriceMinor: 1096,
      regularPriceMinor: 1096,
      normalizedBasisQtyMicros: 24_000_000,
      perUnitMicros: 456_667,
      offerSnapshot: {
        availability: { status: "in_stock", fulfillmentMode: "pickup", locationId: "walmart-omaha", eligible: true },
      },
    });
    expect(observation.externalProductKey).toMatch(/^ingredient-targeted-product_/);
  });

  it("preserves promotion windows and does not invent a regular price", async () => {
    const observation = await ingredientPublicationObservation("bakers-saddle-creek", "ingredient-definition-frozen-cauliflower-florets", {
      checkedAt: "2026-08-14T01:40:00.000Z",
      sourceUrl: "https://www.bakersplus.com/p/test/123",
      productName: "Birds Eye Cauliflower Florets",
      packageText: "10.8 oz",
      packagePriceMinor: 200,
      normalizedBasisUnit: "oz",
      normalizedBasisQtyMicros: 10_800_000,
      perUnitMicros: 185_185,
      validFrom: "2026-08-12T09:21:41.939Z",
      validTo: "2026-09-02T03:59:59.999Z",
      offerKind: "sale",
      availabilityText: "Available",
      fulfillmentMode: "in_store",
      sellerName: "Baker's",
      loyaltyRequired: false,
      membershipRequired: false,
    });

    expect(observation.kind).toBe("sale");
    expect(observation.regularPriceMinor).toBeUndefined();
    expect(observation).toMatchObject({
      validFrom: "2026-08-12T09:21:41.939Z",
      validTo: "2026-09-02T03:59:59.999Z",
    });
  });
});
