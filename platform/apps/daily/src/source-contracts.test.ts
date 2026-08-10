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
});
