import { describe, expect, it } from "vitest";
import { evaluateSourceContract } from "./source-contracts";

describe("source contracts", () => {
  it("fails a shape canary before ingestion", () => {
    const result = evaluateSourceContract({
      version: 1, sourceId: "direct-fixture-headless", coverageMode: "full",
      capturedFrom: "2026-08-10T00:00:00-05:00", capturedTo: "2026-08-10T00:01:00-05:00",
      expectedTerms: 1, marketVerified: true, locationVerified: true, priceModeVerified: false, priceMode: "in_store",
      idempotencyKey: "fixture", terms: [{ termKey: "one", ordinal: 0, outcome: "blocked", rowCount: 0 }],
      observations: [], audit: { inputRows: 10, rejectedRows: 2 },
    }, { sourceId: "direct-fixture-headless", minimumRows: 1, minimumTermCompletionPercent: 100, minimumTaxonomyPercent: 0, requiredPriceMode: true, allowedPriceModes: ["pickup"], maximumRejectedPercent: 10 });
    expect(result.status).toBe("fail");
    expect(result.checks.filter((check) => check.status === "fail").map((check) => check.key)).toEqual(expect.arrayContaining(["minimum-rows", "term-completion", "price-mode-attestation", "price-mode-exact", "rejection-rate"]));
  });

  it("requires semantic identity, promotion, and API schema evidence after cutover", () => {
    const result = evaluateSourceContract({
      version: 1, sourceId: "direct-fixture-headless", coverageMode: "full",
      capturedFrom: "2026-08-12T06:00:00-05:00", capturedTo: "2026-08-12T06:01:00-05:00",
      expectedTerms: 1, marketVerified: true, locationVerified: true, priceModeVerified: true, priceMode: "in_store",
      idempotencyKey: "semantic-fixture", terms: [{ termKey: "one", ordinal: 0, outcome: "success", rowCount: 1 }],
      observations: [{
        externalProductKey: "synthetic", name: "Milk", sizeText: "1 gal", package: {}, kind: "everyday", currency: "USD", purchasePriceMinor: 299,
        purchaseQuantity: 1, packageCount: 1, capturedBasisUnit: "gal", capturedBasisQtyMicros: 1_000_000, normalizedBasisUnit: "gal", normalizedBasisQtyMicros: 1_000_000,
        perUnitMicros: 2_990_000, loyaltyRequired: false, membershipRequired: false, rawPriceText: "$2.99", rawSizeText: "1 gal", capturedAt: "2026-08-12T11:00:30.000Z",
      }], audit: { inputRows: 1, rejectedRows: 0 },
    }, { sourceId: "direct-fixture-headless", minimumRows: 1, minimumTermCompletionPercent: 100, minimumTaxonomyPercent: 0, requiredPriceMode: true, requiredSourceSchema: true, minimumIdentityPercent: 100, minimumPriceSemanticsPercent: 100 });
    expect(result.status).toBe("fail");
    expect(result.checks.filter((check) => check.status === "fail").map((check) => check.key)).toEqual(expect.arrayContaining(["source-schema-fingerprint", "sku-identity", "price-semantics"]));
  });
});
