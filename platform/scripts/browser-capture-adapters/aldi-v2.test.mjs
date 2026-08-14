import { describe, expect, it } from "vitest";
import { buildAldiRows, selectAldiInStoreControl } from "./aldi-v2.mjs";

it("selects In-Store when Pickup is listed first", () => {
  expect(selectAldiInStoreControl([
    "Pickup available today ALDI - OLA 48 - Omaha",
    "In-Store open today ALDI - OLA 48 - Omaha",
  ])).toBe("In-Store open today ALDI - OLA 48 - Omaha");
});

describe("ALDI exact-row projection", () => {
  it("keeps exact rows while explicitly recording a row with no package size", () => {
    const common = { name: "ALDI Blueberries", current: "Current price: $3.49", priceMinor: 349, taxonomy: "Produce", href: "https://www.aldi.us/products/1-blueberries", id: "1", lines: [], availabilityText: "In stock" };
    const result = buildAldiRows("blueberries", { url: "https://www.aldi.us/store/aldi/s?k=blueberries", title: "blueberries", query: "blueberries", locale: "en-US", rows: [{ ...common, size: "6 oz" }, { ...common, id: "2", href: "https://www.aldi.us/products/2-blueberries", size: "" }] }, "2026-08-12T00:00:00.000Z");
    expect(result.rows).toHaveLength(1);
    expect(result.rows[0]).toMatchObject({ availability_status: "in_stock", fulfillment_mode: "in_store" });
    expect(result.excludedResults).toEqual([{ productKey: "2", name: "ALDI Blueberries", reason: "source-native package size is not exact" }]);
  });
});
