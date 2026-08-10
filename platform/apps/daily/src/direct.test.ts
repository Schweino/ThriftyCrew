import { describe, expect, it } from "vitest";
import { buildRegularCapture } from "./direct";
import { buildBrowserCaptureAccuracy, digestHex, stableJson } from "@thriftycrew/domain";

async function walmartBrowserSession() {
  const screenshotSha256 = "a".repeat(64);
  const truth = {
    capturedAt: "2026-08-12T15:01:00.000Z", pageUrl: "https://www.walmart.com/search?q=eggs", location: "Omaha L St Supercenter", priceMode: "pickup", pageIndex: 0, resultIndex: 0,
    visible: { rawText: "$1.99", priceMinor: 199, productName: "Eggs", sizeText: "dozen" },
    structured: { rawText: "1.99", priceMinor: 199, productName: "Eggs", productKey: "wm-eggs", sizeText: "dozen" },
    parser: { status: "exact" as const, rule: "next-data-price-lines" as const },
  };
  const terms = [{
    termKey: "eggs", query: "eggs", ordinal: 0, outcome: "success" as const, rowCount: 1, attempts: 1,
    startedAt: "2026-08-12T15:00:00.000Z", finishedAt: "2026-08-12T15:01:00.000Z",
    retrieval: { targetResultCount: 1, loadedResultCount: 1, availableResultCount: 1, pageCount: 1, hasMoreResults: false, termination: "end-of-results" as const },
  }];
  const candidate = { termKey: "eggs", query: "eggs", productKey: "wm-eggs", name: "Eggs", sizeText: "dozen", purchasePriceMinor: 199, truth };
  const provisional = await buildBrowserCaptureAccuracy("walmart", [candidate], [], terms);
  const target = provisional.discoveryRows[0]!;
  const verificationTruth = { ...truth, capturedAt: "2026-08-12T15:01:30.000Z" };
  const verifications = [{ rowKey: target.rowKey, discoveryHash: target.discoveryHash, observedAt: verificationTruth.capturedAt, outcome: "observed" as const, productKey: "wm-eggs", name: "Eggs", sizeText: "dozen", purchasePriceMinor: 199, truth: verificationTruth }];
  const accuracy = await buildBrowserCaptureAccuracy("walmart", [candidate], verifications, terms);
  const content = {
    version: 2 as const,
    sessionId: "browser-walmart-2026-08-12-fixture",
    store: "walmart" as const,
    sourceId: "direct-walmart-browser",
    worklistHash: "b".repeat(64),
    startedAt: "2026-08-12T15:00:00.000Z",
    finishedAt: "2026-08-12T15:02:00.000Z",
    coverageMode: "full" as const,
    expectedTerms: 1,
    terms,
    canaries: [
      { ordinal: 0, observedAt: "2026-08-12T15:00:00.000Z", market: "Omaha", location: "Omaha L St Supercenter", priceMode: "pickup", evidenceUrl: "https://www.walmart.com/", marketVerified: true as const, locationVerified: true as const, priceModeVerified: true as const, screenshotSha256 },
      { ordinal: 1, observedAt: "2026-08-12T15:01:30.000Z", market: "Omaha", location: "Omaha L St Supercenter", priceMode: "pickup", evidenceUrl: "https://www.walmart.com/", marketVerified: true as const, locationVerified: true as const, priceModeVerified: true as const },
    ],
    chunks: [
      { id: "chunk-discovery", phase: "discovery" as const, ordinal: 0, termKeys: ["eggs"], rowCount: 1, verificationCount: 0, sha256: "c".repeat(64), createdAt: "2026-08-12T15:01:00.000Z" },
      { id: "chunk-verification", phase: "verification" as const, ordinal: 1, termKeys: [], rowCount: 0, verificationCount: 1, sha256: "e".repeat(64), createdAt: "2026-08-12T15:01:30.000Z" },
    ],
    accuracy,
    projectedCaptureSha256: "d".repeat(64),
  };
  return { ...content, contentHash: await digestHex(stableJson(content)), screenshotSha256 };
}

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

  it("accepts Freshop ea/pk package counts and canonicalizes date-only evidence before morning runs", async () => {
    const artifact = await buildRegularCapture("family-fare", {
      store: "Family Fare",
      mode_verified: "2026-08-09",
      deals: [
        { item: "Granola Bars 6 Ea", current_price: 3.99, size: "6 ea", as_of: "2026-08-09", found_by_term: "granola bars" },
        { item: "Sparkling Water 12 Pack", current_price: 4.99, size: "12 pk", as_of: "2026-08-09", found_by_term: "sparkling water" },
      ],
    });
    expect(artifact.observations).toHaveLength(2);
    expect(artifact.observations[0]).toMatchObject({ normalizedBasisUnit: "each", normalizedBasisQtyMicros: 6_000_000, packageCount: 1 });
    expect(artifact.observations[1]).toMatchObject({ normalizedBasisUnit: "each", normalizedBasisQtyMicros: 12_000_000, packageCount: 1 });
    expect(artifact.capturedFrom).toBe("2026-08-09T05:00:00.000Z");
    expect(artifact.capturedTo).toBe("2026-08-09T05:00:00.000Z");
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
    const session = await walmartBrowserSession();
    const document = { coverage_mode: "full", capture_session: session, deals: [{ item: "Eggs", current_price: 1.99, size: "dozen", as_of: "2026-08-12", found_by_term: "eggs", product_id: "wm-eggs" }] };
    await expect(buildRegularCapture("walmart", document, undefined, "browser")).rejects.toThrow("browser captures require");
    await expect(buildRegularCapture("walmart", { ...document, deals: [{ ...document.deals[0], current_price: 2.99 }] }, {
      store: "Walmart", market: "Omaha", priceMode: "pickup", verifiedAt: "2026-08-12T15:00:00.000Z",
      evidenceUrl: "https://www.walmart.com/", statement: "Logged-in Omaha pickup context verified in Chrome",
      marketVerified: true, locationVerified: true, priceModeVerified: true,
      screenshotSha256: [session.screenshotSha256], captureSessionHash: session.contentHash,
    }, "browser")).rejects.toThrow("not bound to exact capture truth");
    const artifact = await buildRegularCapture("walmart", document, {
      store: "Walmart", market: "Omaha", priceMode: "pickup", verifiedAt: "2026-08-12T15:00:00.000Z",
      evidenceUrl: "https://www.walmart.com/", statement: "Logged-in Omaha pickup context verified in Chrome",
      marketVerified: true, locationVerified: true, priceModeVerified: true,
      screenshotSha256: [session.screenshotSha256], captureSessionHash: session.contentHash,
    }, "browser");
    expect(artifact).toMatchObject({ sourceId: "direct-walmart-browser", coverageMode: "full", expectedTerms: 1, capturedFrom: session.startedAt, capturedTo: session.finishedAt, marketVerified: true, locationVerified: true, priceModeVerified: true });
  });

  it("refuses to claim verified price mode when the source did not prove it", async () => {
    const artifact = await buildRegularCapture("fareway", { deals: [{ item: "Eggs", current_price: 1.99, size: "dozen", as_of: "2026-08-09" }] });
    expect(artifact.priceModeVerified).toBe(false);
  });

  it("accepts the legacy capture-date proof used by verified store pulls", async () => {
    const artifact = await buildRegularCapture("fareway", { mode_verified: "2026-08-09", price_mode: "in-store", deals: [{ item: "Eggs", current_price: 1.99, size: "dozen", as_of: "2026-08-09" }] });
    expect(artifact.priceModeVerified).toBe(true);
  });

  it("uses Hy-Vee's verified per-item price when current_price preserves the multi-buy total", async () => {
    const artifact = await buildRegularCapture("hy-vee", {
      mode_verified: "2026-08-10",
      price_mode: "in-store",
      deals: [{
        item: "Hy-Vee Whole Grain Raisin Bran",
        ad_price: "$2.5",
        current_price: 5,
        price_multiple: 2,
        regular: 2.5,
        size: "16.6 oz",
        as_of: "2026-08-10",
      }],
    });
    expect(artifact.observations[0]).toMatchObject({
      purchasePriceMinor: 250,
      rawPriceText: "$2.5",
      package: expect.objectContaining({
        sourceCheckoutPrice: 5,
        priceMultiple: 2,
        priceInterpretation: "verified-per-item-multibuy",
      }),
    });
  });

  it.each([
    ["family-fare", "pickup"],
    ["hy-vee", "in-store"],
  ])("accepts the dated price-mode proof emitted by the %s adapter", async (store, priceMode) => {
    const artifact = await buildRegularCapture(store, {
      mode_verified: "2026-08-09",
      price_mode: priceMode,
      deals: [{ item: "Large Eggs", current_price: 1.99, size: "dozen", as_of: "2026-08-09" }],
    });
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

  it("reconstructs a Sam's package checkout price when the displayed price is explicitly per unit", async () => {
    const artifact = await buildRegularCapture("sams", { mode_verified: true, price_mode: "club", deals: [{
      item: "Member's Mark Raw Shrimp, 2 lbs.", current_price: "$8.48", size: "lb", as_of: "2026-08-05",
      sams_unit_price: "$8.48/lb", sams_item_id: "shrimp",
    }] });
    expect(artifact.observations[0]).toMatchObject({ purchasePriceMinor: 1696, normalizedBasisUnit: "lb", normalizedBasisQtyMicros: 2_000_000, perUnitMicros: 8_480_000 });
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

  it("normalizes consumer units instead of sheets, square feet, slices, or supplier cases", async () => {
    const artifact = await buildRegularCapture("walmart", { mode_verified: true, price_mode: "pickup", deals: [
      { item: "Great Value Toilet Paper, 1000 Sheets per Roll, 12 Rolls", current_price: "$9.48", size: "12000 ct", as_of: "2026-08-09" },
      { item: "Aluminum Foil Roll, 12in x 165 SQ.FT", current_price: "$13.99", size: "165 ct", as_of: "2026-08-09" },
      { item: "Italian Sandwich Bread Loaf, 17 oz, 18 Count", current_price: "$2.84", size: "18 ct", as_of: "2026-08-09" },
      { item: "Fresh Iceberg Lettuce Head", current_price: "$2.49", size: "24 ct", as_of: "2026-08-09" },
    ] });
    expect(artifact.observations.map((row) => row.normalizedBasisQtyMicros)).toEqual([12_000_000, 1_000_000, 1_000_000, 1_000_000]);
  });

  it("rejects compound price strings instead of stripping punctuation into a different price", async () => {
    await expect(buildRegularCapture("walmart", { mode_verified: true, price_mode: "pickup", deals: [
      { item: "Large Eggs", current_price: "2/$5", size: "dozen", as_of: "2026-08-09" },
    ] })).rejects.toThrow("no regular rows could be normalized");
  });
});
