import { describe, expect, it } from "vitest";
import { buildFarewayRows, captureFarewayCanary, parseFarewayApolloAvailability, validatedRegularPrice } from "./fareway-v2.mjs";

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
    const common = { name: "Fareway Turkey", current: "Current price: $4.99", priceMinor: 499, taxonomy: "Deli", href: "https://shop.fareway.com/products/1", id: "1", lines: ["In stock"],
      availability: { status: "in_stock", eligible: true, rawText: "apollo availability", sourceBinding: { shopId: "16671402", retailerLocationId: "531573", serviceType: "instore" } } };
    const result = buildFarewayRows("turkey", { url: "https://shop.fareway.com/s?k=turkey", title: "turkey", query: "turkey", locale: "en-US", rows: [{ ...common, size: "9 oz" }, { ...common, id: "2", href: "https://shop.fareway.com/products/2", size: "" }] }, "2026-08-12T00:00:00.000Z");
    expect(result.rows).toHaveLength(1);
    expect(result.rows[0]).toMatchObject({ availability_status: "in_stock", fulfillment_mode: "in_store",
      _capture: { offer: { availability: { locationId: "043", eligible: true } } } });
    expect(result.excludedResults).toEqual([{ productKey: "2", name: "Fareway Turkey", reason: "source-native package size is not exact" }]);
  });
});

describe("Fareway exact Omaha detail availability", () => {
  const exactKey = JSON.stringify({ ids: ["items_531573-90266603"], postalCode: "68136", shopId: "16671402", zoneId: "917" });
  const state = (availability, shops = [{ id: "16671402", retailerLocationId: "531573", serviceType: "instore" }]) => ({
    ShopCollectionScoped: { shops }, Items: { [exactKey]: { items: [{ id: "90266603", availability }] } } });

  it("accepts only exact available/inStock truth bound to shop 16671402 and retailer location 531573", () => {
    expect(parseFarewayApolloAvailability(state({ available: true, stockLevel: "inStock" }), "90266603"))
      .toMatchObject({ status: "in_stock", eligible: true, sourceBinding: { shopId: "16671402",
        retailerLocationId: "531573", serviceType: "instore", productId: "90266603" } });
    expect(parseFarewayApolloAvailability(state({ available: false, stockLevel: "outOfStock" }), "90266603"))
      .toMatchObject({ status: "unavailable", eligible: false });
  });

  it("fails closed on missing shop binding, missing item truth, or conflicting exact facts", () => {
    expect(parseFarewayApolloAvailability(state({ available: true, stockLevel: "inStock" }, []), "90266603"))
      .toMatchObject({ status: "unknown", eligible: false });
    expect(parseFarewayApolloAvailability(state({ available: true, stockLevel: "inStock" }), "other"))
      .toMatchObject({ status: "unknown", eligible: false });
    const conflicting = state({ available: true, stockLevel: "inStock" });
    conflicting.Other = { Items: { [exactKey]: { items: [{ id: "90266603",
      availability: { available: false, stockLevel: "outOfStock" } }] } } };
    expect(parseFarewayApolloAvailability(conflicting, "90266603")).toMatchObject({ status: "unknown", eligible: false });
    const wrongShop = state({ available: true, stockLevel: "inStock" });
    const wrongKey = JSON.stringify({ ids: ["items_531573-90266603"], postalCode: "68136", shopId: "wrong-shop", zoneId: "917" });
    wrongShop.Items = { [wrongKey]: wrongShop.Items[exactKey] };
    expect(parseFarewayApolloAvailability(wrongShop, "90266603")).toMatchObject({ status: "unknown", eligible: false });
  });
});
