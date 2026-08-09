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

  it("binds an external verification attestation and stable name identity", async () => {
    const artifact = await buildRegularCapture("hy-vee", {
      store: "Hy-Vee", price_mode: "in-store", source: "fixture", deals: [
        { item: "Hy Vee Grade A Large Eggs", size: "dozen", ad_price: "$1.59", as_of: "2026-08-09" },
      ],
    }, {
      store: "Hy-Vee", market: "Omaha", priceMode: "in_store", verifiedAt: "2026-08-09T15:00:00.000Z",
      evidenceUrl: "https://www.hy-vee.com/", statement: "Store and shelf-price mode inspected",
      marketVerified: true, locationVerified: true, priceModeVerified: true,
    });
    expect(artifact.priceModeVerified).toBe(true);
    expect(artifact.observations[0]?.externalProductKey).toMatch(/^catalog-/);
    expect(artifact.audit.attestationHash).toMatch(/^[a-f0-9]{64}$/);
  });

  it("refuses to claim verified price mode when the source did not prove it", async () => {
    const artifact = await buildRegularCapture("fareway", { deals: [{ item: "Eggs", current_price: 1.99, size: "dozen", as_of: "2026-08-09" }] });
    expect(artifact.priceModeVerified).toBe(false);
  });

  it("accepts the legacy capture-date proof used by verified store pulls", async () => {
    const artifact = await buildRegularCapture("fareway", { mode_verified: "2026-08-09", price_mode: "in-store", deals: [{ item: "Eggs", current_price: 1.99, size: "dozen", as_of: "2026-08-09" }] });
    expect(artifact.priceModeVerified).toBe(true);
  });

  it("uses Sam's verified unit-price field for club packs", async () => {
    const artifact = await buildRegularCapture("sams", { mode_verified: true, deals: [{
      item: "Applesauce Pouches 32 ct", current_price: "$13.98", size: "32 ct 3.2 oz", as_of: "2026-08-05",
      sams_unit_price: "$0.44/ea", sams_item_id: "13594011076",
    }] });
    expect(artifact.observations[0]).toMatchObject({
      externalProductKey: "13594011076",
      membershipRequired: true,
      normalizedBasisUnit: "each",
      perUnitMicros: 440_000,
    });
    expect(artifact.observations[0]!.basisOptions).toEqual(expect.arrayContaining([
      expect.objectContaining({ unit: "oz", quantityMicros: 102_400_000, source: "count-times-measure" }),
      expect.objectContaining({ unit: "each", quantityMicros: 32_000_000 }),
    ]));
  });

  it("does not multiply a total package weight by an item count", async () => {
    const artifact = await buildRegularCapture("sams", { mode_verified: true, deals: [
      {
        item: "Hormel Fully Cooked Bacon (10.5 oz., 72 ct.)", current_price: "$15.76", size: "10.5 oz", as_of: "2026-08-05",
        sams_unit_price: "$1.50/oz", sams_item_id: "bacon",
      },
      {
        item: "Pedigree Dentastix, 3.45 lbs., 65 ct.", current_price: "$22.88", size: "65 ct 3.45 lb", as_of: "2026-08-05",
        sams_unit_price: "$0.35/ea", sams_item_id: "treats",
      },
    ] });
    expect(artifact.observations[0]!.basisOptions).toEqual(expect.arrayContaining([
      expect.objectContaining({ unit: "oz", quantityMicros: 10_500_000, source: "stated-measure" }),
    ]));
    expect(artifact.observations[0]!.basisOptions).not.toContainEqual(expect.objectContaining({ unit: "oz", quantityMicros: 756_000_000 }));
    expect(artifact.observations[1]!.basisOptions).toEqual(expect.arrayContaining([
      expect.objectContaining({ unit: "lb", quantityMicros: 3_450_000, source: "stated-measure" }),
    ]));
    expect(artifact.observations[1]!.basisOptions).not.toContainEqual(expect.objectContaining({ unit: "lb", quantityMicros: 224_250_000 }));
  });
});
