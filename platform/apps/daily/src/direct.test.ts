import { describe, expect, it } from "vitest";
import { buildRegularCapture } from "./direct";

describe("direct regular capture", () => {
  it("normalizes exact integer price bases and preserves shelf taxonomy", async () => {
    const artifact = await buildRegularCapture("bakers", {
      store: "Baker's",
      mode_verified: true,
      source: "kroger-api",
      deals: [
        { item: "Chicken Breast", current_price: 2.89, size: "lb", as_of: "2026-08-09", product_id: "123", store_category: "Meat & Seafood", store_aisle: "Meat" },
        { item: "Sparkling Water", current_price: 4.99, size: "2 x 12 fl oz", as_of: "2026-08-09", product_id: "456" },
        { item: "Unreadable package", current_price: 3.5, size: "family size", as_of: "2026-08-09" },
      ],
    });
    expect(artifact.sourceId).toBe("direct-bakers-headless");
    expect(artifact.observations).toHaveLength(2);
    expect(artifact.observations[0]).toMatchObject({ purchasePriceMinor: 289, normalizedBasisUnit: "lb", normalizedBasisQtyMicros: 1_000_000, perUnitMicros: 2_890_000, taxonomyPath: "Meat & Seafood/Meat" });
    expect(artifact.observations[1]).toMatchObject({ normalizedBasisUnit: "fl_oz", normalizedBasisQtyMicros: 24_000_000, packageCount: 2 });
    expect(artifact.audit).toMatchObject({ inputRows: 3, acceptedRows: 2, rejectedRows: 1 });
  });

  it("refuses to claim verified price mode when the source did not prove it", async () => {
    const artifact = await buildRegularCapture("fareway", { deals: [{ item: "Eggs", current_price: 1.99, size: "dozen", as_of: "2026-08-09" }] });
    expect(artifact.priceModeVerified).toBe(false);
  });

  it("accepts the legacy capture-date proof used by verified store pulls", async () => {
    const artifact = await buildRegularCapture("fareway", { mode_verified: "2026-08-09", price_mode: "in-store", deals: [{ item: "Eggs", current_price: 1.99, size: "dozen", as_of: "2026-08-09" }] });
    expect(artifact.priceModeVerified).toBe(true);
  });
});
