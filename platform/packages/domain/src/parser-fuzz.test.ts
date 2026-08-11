import { describe, expect, it } from "vitest";
import { browserCaptureTruthSchema } from "@thriftycrew/contracts";
import { browserCaptureTruthPass, parseCapturePriceText } from "./index";

function nextRandom(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state ^= state << 13; state ^= state >>> 17; state ^= state << 5;
    return state >>> 0;
  };
}

function walmartTruth(priceMinor: number, rawText: string) {
  const semantics = { offerType: "everyday" as const, condition: "none" as const, unitPriceMinor: priceMinor, qualifyingQuantity: 1, totalPriceMinor: priceMinor, ambiguity: false as const };
  return browserCaptureTruthSchema.parse({
    capturedAt: "2026-08-12T12:00:00.000Z", pageUrl: "https://www.walmart.com/search?q=test", location: "Omaha L St Supercenter", priceMode: "Pickup", pageIndex: 0, resultIndex: 0,
    pageState: { pageType: "search_results", pageTitle: "test - Walmart.com", query: "test", resultRegionPresent: true, challengeDetected: false, currency: "USD", locale: "en-US", locationText: "Omaha L St Supercenter", fulfillmentText: "Pickup" },
    visible: { rawText, priceMinor, productName: "Test Product", sizeText: "1 each", priceSemantics: semantics },
    structured: { rawText: (priceMinor / 100).toFixed(2), priceMinor, productName: "Test Product", productKey: "test-1", sizeText: "1 each", priceSemantics: semantics },
    parser: { status: "exact", rule: "next-data-price-lines" },
  });
}

describe("capture price parser mutation and fuzz resistance", () => {
  it("parses supported price labels and rejects conflicting or incomplete strings", () => {
    expect(parseCapturePriceText("Current price: $2.99")).toEqual({ unitPriceMinor: 299, qualifyingQuantity: 1, totalPriceMinor: 299 });
    expect(parseCapturePriceText("2 for $5.00")).toEqual({ unitPriceMinor: 250, qualifyingQuantity: 2, totalPriceMinor: 500 });
    expect(parseCapturePriceText("$2.99 was $3.99")).toBeUndefined();
    expect(parseCapturePriceText("2 for")).toBeUndefined();
    expect(parseCapturePriceText("free")).toBeUndefined();
  });

  it("fails closed across 500 deterministic digit, decimal, and extra-price mutations", () => {
    const random = nextRandom(0x5eedc0de);
    for (let index = 0; index < 500; index += 1) {
      const priceMinor = 1 + (random() % 999_999);
      const raw = `$${Math.floor(priceMinor / 100)}.${String(priceMinor % 100).padStart(2, "0")}`;
      const identity = { productKey: "test-1", name: "Test Product", sizeText: "1 each", purchasePriceMinor: priceMinor };
      expect(browserCaptureTruthPass("walmart", identity, walmartTruth(priceMinor, raw)), `clean-${index}`).toBe(true);
      expect(browserCaptureTruthPass("walmart", identity, walmartTruth(priceMinor + 100, raw)), `stale-structured-${index}`).toBe(false);
      expect(parseCapturePriceText(`${raw} regular $${(priceMinor / 100 + 1).toFixed(2)}`), `double-price-${index}`).toBeUndefined();
      const digitsOnly = raw.replace(".", "");
      expect(parseCapturePriceText(digitsOnly)?.unitPriceMinor, `decimal-loss-${index}`).not.toBe(priceMinor);
    }
  });
});
