import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { browserCaptureTruthSchema, browserCaptureStore, type BrowserCaptureTruth } from "@thriftycrew/contracts";
import { browserCaptureTruthPass, buildBrowserCaptureAccuracy } from "./index";

describe("source-specific capture-time parser contracts", () => {
  it("keeps a frozen clean twin and must-fire failure for every browser source", async () => {
    const fixture = JSON.parse(await readFile(path.resolve(import.meta.dirname, "../../../fixtures/browser-capture/parser-contracts.json"), "utf8")) as {
      cases: Array<{ id: string; store: string; expected: boolean; identity: { productKey: string; name: string; sizeText: string; purchasePriceMinor: number }; truth: BrowserCaptureTruth }>;
    };
    const stores = new Set<string>();
    for (const item of fixture.cases) {
      const store = browserCaptureStore.parse(item.store);
      stores.add(store);
      expect(browserCaptureTruthPass(store, item.identity, browserCaptureTruthSchema.parse(item.truth)), item.id).toBe(item.expected);
    }
    expect(stores).toEqual(new Set(["aldi", "fareway", "sams", "walmart"]));
    for (const store of stores) {
      expect(fixture.cases.some((item) => item.store === store && item.expected), `${store} clean twin`).toBe(true);
      expect(fixture.cases.some((item) => item.store === store && !item.expected), `${store} must-fire`).toBe(true);
    }
  });

  it("fails closed on incomplete pagination or an unresolved independent second pass", async () => {
    const truth = browserCaptureTruthSchema.parse({
      capturedAt: "2026-08-12T12:00:00.000Z", pageUrl: "https://www.walmart.com/search?q=milk",
      location: "Omaha L St Supercenter", priceMode: "Pickup", pageIndex: 0, resultIndex: 0,
      pageState: { pageType: "search_results", pageTitle: "milk - Walmart.com", query: "milk", resultRegionPresent: true, challengeDetected: false, currency: "USD", locale: "en-US", locationText: "Omaha L St Supercenter", fulfillmentText: "Pickup" },
      visible: { rawText: "$2.99", priceMinor: 299, productName: "Whole Milk", priceSemantics: { offerType: "everyday", condition: "none", unitPriceMinor: 299, qualifyingQuantity: 1, totalPriceMinor: 299, ambiguity: false } },
      structured: { rawText: "2.99", priceMinor: 299, productName: "Whole Milk", productKey: "wm-milk", priceSemantics: { offerType: "everyday", condition: "none", unitPriceMinor: 299, qualifyingQuantity: 1, totalPriceMinor: 299, ambiguity: false } },
      parser: { status: "exact", rule: "next-data-price-lines" },
    });
    const candidate = { termKey: "milk", query: "milk", productKey: "wm-milk", name: "Whole Milk", sizeText: "1 gal", taxonomyPath: "Food/Dairy", purchasePriceMinor: 299, truth };
    const incomplete = await buildBrowserCaptureAccuracy("walmart", [candidate], [], [{
      outcome: "success", rowCount: 1,
      retrieval: { targetResultCount: 24, loadedResultCount: 1, availableResultCount: 50, hasMoreResults: true, termination: "end-of-results" },
    }]);
    expect(incomplete).toMatchObject({ pass: false, retrievalCompleteTerms: 0, requiredVerificationRows: 1, unresolvedVerificationRows: 1 });
  });
});
