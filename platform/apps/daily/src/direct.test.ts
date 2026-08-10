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

  it("builds a real-Chrome artifact only with an explicit verification attestation", async () => {
    const document = { coverage_mode: "targeted", deals: [{ item: "Eggs", current_price: 1.99, size: "dozen", as_of: "2026-08-09" }] };
    await expect(buildRegularCapture("walmart", document, undefined, "browser")).rejects.toThrow("browser captures require");
    const artifact = await buildRegularCapture("walmart", document, {
      store: "Walmart", market: "Omaha", priceMode: "pickup", verifiedAt: "2026-08-09T15:00:00.000Z",
      evidenceUrl: "https://www.walmart.com/", statement: "Logged-in Omaha pickup context verified in Chrome",
      marketVerified: true, locationVerified: true, priceModeVerified: true,
    }, "browser");
    expect(artifact).toMatchObject({ sourceId: "direct-walmart-browser", coverageMode: "targeted", marketVerified: true, locationVerified: true, priceModeVerified: true });
  });

  it("refuses to claim verified price mode when the source did not prove it", async () => {
    const artifact = await buildRegularCapture("fareway", { deals: [{ item: "Eggs", current_price: 1.99, size: "dozen", as_of: "2026-08-09" }] });
    expect(artifact.priceModeVerified).toBe(false);
  });

  it("accepts the legacy capture-date proof used by verified store pulls", async () => {
    const artifact = await buildRegularCapture("fareway", { mode_verified: "2026-08-09", price_mode: "in-store", deals: [{ item: "Eggs", current_price: 1.99, size: "dozen", as_of: "2026-08-09" }] });
    expect(artifact.priceModeVerified).toBe(true);
  });

  it("preserves the source's complete per-term receipt ledger", async () => {
    const artifact = await buildRegularCapture("bakers", {
      coverage_mode: "full",
      mode_verified: true,
      capture_terms: [
        { term_key: "eggs", ordinal: 0, outcome: "success", row_count: 2 },
        { term_key: "unicorn-fruit", ordinal: 1, outcome: "empty", row_count: 0 },
      ],
      deals: [{ item: "Large Eggs", current_price: 1.99, size: "dozen", as_of: "2026-08-09", found_by_term: "eggs" }],
    });
    expect(artifact.coverageMode).toBe("full");
    expect(artifact.expectedTerms).toBe(2);
    expect(artifact.terms).toEqual([
      { termKey: "eggs", ordinal: 0, outcome: "success", rowCount: 2 },
      { termKey: "unicorn-fruit", ordinal: 1, outcome: "empty", rowCount: 0 },
    ]);
  });

  it("downgrades a claimed full capture when any term was blocked", async () => {
    const artifact = await buildRegularCapture("bakers", {
      coverage_mode: "full",
      mode_verified: true,
      capture_terms: [{ term_key: "eggs", ordinal: 0, outcome: "blocked", row_count: 0, reason: "API refused" }],
      deals: [{ item: "Large Eggs", current_price: 1.99, size: "dozen", as_of: "2026-08-09" }],
    });
    expect(artifact.coverageMode).toBe("partial");
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

  it("parses a leading-decimal name measure as 0.x rather than 100x larger", async () => {
    const artifact = await buildRegularCapture("walmart", { mode_verified: true, deals: [{
      item: "Crest Toothpaste Radiant Mint, .85 oz Travel Size", current_price: "$0.97", size: "0.85 oz", as_of: "2026-08-09", product_id: "travel-toothpaste",
    }] });
    expect(artifact.observations[0]!.basisOptions).toEqual(expect.arrayContaining([
      expect.objectContaining({ unit: "oz", quantityMicros: 850_000, source: "stated-measure" }),
    ]));
    expect(artifact.observations[0]!.basisOptions).not.toContainEqual(expect.objectContaining({ unit: "oz", quantityMicros: 85_000_000 }));
  });
});
