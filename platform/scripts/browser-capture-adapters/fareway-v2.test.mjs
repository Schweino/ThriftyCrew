import { describe, expect, it } from "vitest";
import { buildFarewayRows, captureFarewayCanary, validatedRegularPrice } from "./fareway-v2.mjs";

it("emits the canonical Fareway policy key from a passing Omaha in-store canary", async () => {
  const canary = await captureFarewayCanary({ playwright: {
    evaluate: async () => ({ url: "https://shop.fareway.com/store/fareway/products", challenge: false, plainOmaha: true }),
    getByRole: () => ({ filter: () => ({ count: async () => 1 }) }),
  } });
  expect(canary).toMatchObject({ locationId: "043", retailerLocationKey: "043",
    location: "Omaha 17070 Audrey Street", priceMode: "In-Store", locationVerified: true, priceModeVerified: true });
});

describe("Fareway regular-price semantics", () => {
  it("keeps only a genuine higher comparison price", () => {
    expect(validatedRegularPrice(219, 299)).toBe(299);
    expect(validatedRegularPrice(219, 219)).toBeUndefined();
    expect(validatedRegularPrice(219, 117)).toBeUndefined();
    expect(validatedRegularPrice(219, undefined)).toBeUndefined();
  });
});

describe("Fareway exact-row projection", () => {
  it("keeps exact rows while explicitly recording a row with no package size", () => {
    const common = { name: "Fareway Turkey", current: "Current price: $4.99", priceMinor: 499, taxonomy: "Deli", href: "https://shop.fareway.com/products/1", id: "1", lines: ["In stock"] };
    const result = buildFarewayRows("turkey", { url: "https://shop.fareway.com/s?k=turkey", title: "turkey", query: "turkey", locale: "en-US", rows: [{ ...common, size: "9 oz" }, { ...common, id: "2", href: "https://shop.fareway.com/products/2", size: "" }] }, "2026-08-12T00:00:00.000Z");
    expect(result.rows).toHaveLength(1);
    expect(result.rows[0]).toMatchObject({ availability_status: "in_stock", fulfillment_mode: "in_store",
      _capture: { offer: { availability: { locationId: "043", eligible: true } } } });
    expect(result.excludedResults).toEqual([{ productKey: "2", name: "Fareway Turkey", reason: "source-native package size is not exact" }]);
  });
});
