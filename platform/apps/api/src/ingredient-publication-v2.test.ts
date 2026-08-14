import { describe, expect, it } from "vitest";
import { ingredientPublicationObservation, validateIngredientPublicationExternalProofs } from "./ingredient-publication-v2";

describe("ingredient publication capture materialization", () => {
  it("turns a QA-verified package price into an exact durable observation", async () => {
    const observation = await ingredientPublicationObservation("walmart-omaha", "ingredient-definition-pistachios", {
      checkedAt: "2026-08-14T01:40:00.000Z",
      sourceUrl: "https://www.walmart.com/ip/test/123",
      productName: "Great Value Pistachios",
      packageText: "24 oz",
      packagePriceMinor: 1096,
      normalizedBasisUnit: "oz",
      normalizedBasisQtyMicros: 24_000_000,
      perUnitMicros: 456_667,
      validFrom: null,
      validTo: null,
      offerKind: "everyday",
      availabilityText: "In stock",
      fulfillmentMode: "pickup",
      sellerName: "Walmart",
      loyaltyRequired: false,
      membershipRequired: false,
    });

    expect(observation).toMatchObject({
      name: "Great Value Pistachios",
      kind: "everyday",
      purchasePriceMinor: 1096,
      regularPriceMinor: 1096,
      normalizedBasisQtyMicros: 24_000_000,
      perUnitMicros: 456_667,
      offerSnapshot: {
        availability: { status: "in_stock", fulfillmentMode: "pickup", locationId: "walmart-omaha", eligible: true },
      },
    });
    expect(observation.externalProductKey).toMatch(/^ingredient-targeted-product_/);
  });

  it("preserves promotion windows and does not invent a regular price", async () => {
    const observation = await ingredientPublicationObservation("bakers-saddle-creek", "ingredient-definition-frozen-cauliflower-florets", {
      checkedAt: "2026-08-14T01:40:00.000Z",
      sourceUrl: "https://www.bakersplus.com/p/test/123",
      productName: "Birds Eye Cauliflower Florets",
      packageText: "10.8 oz",
      packagePriceMinor: 200,
      normalizedBasisUnit: "oz",
      normalizedBasisQtyMicros: 10_800_000,
      perUnitMicros: 185_185,
      validFrom: "2026-08-12T09:21:41.939Z",
      validTo: "2026-09-02T03:59:59.999Z",
      offerKind: "sale",
      availabilityText: "Available",
      fulfillmentMode: "in_store",
      sellerName: "Baker's",
      loyaltyRequired: false,
      membershipRequired: false,
    });

    expect(observation.kind).toBe("sale");
    expect(observation.regularPriceMinor).toBeUndefined();
    expect(observation).toMatchObject({
      validFrom: "2026-08-12T09:21:41.939Z",
      validTo: "2026-09-02T03:59:59.999Z",
    });
  });
});

describe("ingredient publication external proofs", () => {
  const hash = "a".repeat(64);
  const releaseId = "rel_test";
  const plan = { releaseId, checks: [
    { gapId: "gap_1", originKind: "worker" as const, url: "https://worker.test/api/v2/board/item?release=rel_test", expectedHash: hash },
    { gapId: "gap_1", originKind: "custom_domain" as const, url: "https://example.test/api/v2/board/item?release=rel_test", expectedHash: hash },
  ] };
  const proof = (originKind: "worker" | "custom_domain", url: string) => ({
    gapId: "gap_1", originKind, url, status: 200, etag: null, responseReleaseId: releaseId,
    observedHash: hash, checkedAt: "2026-08-14T02:00:00.000Z",
  });

  it("accepts exact dual-origin release-bound projection proofs", () => {
    const result = validateIngredientPublicationExternalProofs(plan, { releaseId, proofs: [
      proof("worker", plan.checks[0]!.url), proof("custom_domain", plan.checks[1]!.url),
    ] });
    expect(result.allVerified).toBe(true);
  });

  it("rejects a substituted public origin", () => {
    expect(() => validateIngredientPublicationExternalProofs(plan, { releaseId, proofs: [
      proof("worker", "https://attacker.test/api/v2/board/item?release=rel_test"),
      proof("custom_domain", plan.checks[1]!.url),
    ] })).toThrow(/untrusted target/);
  });

  it("records a hash mismatch as an unverified proof set", () => {
    const result = validateIngredientPublicationExternalProofs(plan, { releaseId, proofs: [
      { ...proof("worker", plan.checks[0]!.url), observedHash: "b".repeat(64) },
      proof("custom_domain", plan.checks[1]!.url),
    ] });
    expect(result.allVerified).toBe(false);
  });
});
