import { describe, expect, it } from "vitest";
import { buildFarewayRows, validatedRegularPrice } from "./fareway-v2.mjs";

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
    const common = { name: "Fareway Turkey", current: "Current price: $4.99", priceMinor: 499, taxonomy: "Deli", href: "https://shop.fareway.com/products/1", id: "1", lines: [] };
    const result = buildFarewayRows("turkey", { url: "https://shop.fareway.com/s?k=turkey", title: "turkey", query: "turkey", locale: "en-US", rows: [{ ...common, size: "9 oz" }, { ...common, id: "2", href: "https://shop.fareway.com/products/2", size: "" }] }, "2026-08-12T00:00:00.000Z");
    expect(result.rows).toHaveLength(1);
    expect(result.excludedResults).toEqual([{ productKey: "2", name: "Fareway Turkey", reason: "source-native package size is not exact" }]);
  });
});
