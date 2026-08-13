import { describe, expect, it } from "vitest";
import { catalogCandidatesForTerms, chooseCatalogWinner, type CatalogCandidate } from "./hot-catalog";

const offer = (overrides: Partial<CatalogCandidate> = {}): CatalogCandidate => ({
  productId: "product-one", observationId: "observation-one", productName: "Plain Greek Yogurt 32 oz",
  normalizedName: "plain greek yogurt 32 oz", sizeText: "32 oz", productUrl: "https://example.test/yogurt",
  availabilityStatus: "in_stock", fulfillmentMode: "pickup", sellerName: "Example", offerKind: "everyday",
  packagePriceMinor: 499, normalizedBasisUnit: "oz", normalizedBasisQtyMicros: 32_000_000,
  perUnitMicros: 155_938, loyaltyRequired: false, membershipRequired: false,
  validFrom: null, validTo: null, capturedAt: "2026-08-13T12:00:00.000Z", evidenceHash: "a".repeat(64), ...overrides,
});

describe("hot catalog deterministic resolution", () => {
  it("selects the cheapest exact compatible candidate", () => {
    const candidates = catalogCandidatesForTerms([offer(), offer({ productId: "product-two", perUnitMicros: 120_000 })], ["plain greek yogurt"]);
    expect(chooseCatalogWinner(candidates).winner?.productId).toBe("product-two");
  });

  it("refuses incompatible basis units", () => {
    expect(chooseCatalogWinner([offer(), offer({ productId: "product-two", normalizedBasisUnit: "each" })]))
      .toEqual({ winner: null, reason: "candidate basis units are incompatible" });
  });

  it("excludes expired and unavailable offers", () => {
    expect(catalogCandidatesForTerms([
      offer({ validTo: "2026-08-13T00:00:00.000Z" }),
      offer({ productId: "product-two", availabilityStatus: "out_of_stock" }),
    ], ["plain greek yogurt"], new Date("2026-08-14T00:00:00.000Z"))).toEqual([]);
  });
});
