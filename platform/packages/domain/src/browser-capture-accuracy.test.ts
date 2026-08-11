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

  it("caps the blind sample at 100 and applies count risk only to the likely winner", async () => {
    const candidates = Array.from({ length: 250 }, (_, index) => {
      const productKey = `wm-paper-${index}`;
      const name = `Paper Item ${index}`;
      const purchasePriceMinor = 100 + index;
      const truth = browserCaptureTruthSchema.parse({
        capturedAt: "2026-08-12T12:00:00.000Z", pageUrl: "https://www.walmart.com/search?q=paper",
        location: "Omaha L St Supercenter", priceMode: "Pickup", pageIndex: 0, resultIndex: index,
        pageState: { pageType: "search_results", pageTitle: "paper - Walmart.com", query: "paper", resultRegionPresent: true, challengeDetected: false, currency: "USD", locale: "en-US", locationText: "Omaha L St Supercenter", fulfillmentText: "Pickup" },
        visible: { rawText: `$${(purchasePriceMinor / 100).toFixed(2)}`, priceMinor: purchasePriceMinor, productName: name, productKey, priceSemantics: { offerType: "everyday", condition: "none", unitPriceMinor: purchasePriceMinor, qualifyingQuantity: 1, totalPriceMinor: purchasePriceMinor, ambiguity: false } },
        structured: { rawText: String(purchasePriceMinor / 100), priceMinor: purchasePriceMinor, productName: name, productKey, priceSemantics: { offerType: "everyday", condition: "none", unitPriceMinor: purchasePriceMinor, qualifyingQuantity: 1, totalPriceMinor: purchasePriceMinor, ambiguity: false } },
        parser: { status: "exact", rule: "next-data-price-lines" },
      });
      return { termKey: "paper", query: "paper", productKey, name, sizeText: "12 ct", taxonomyPath: "Household/Paper", purchasePriceMinor, truth };
    });
    const accuracy = await buildBrowserCaptureAccuracy("walmart", candidates, [], [{
      outcome: "success", rowCount: candidates.length,
      retrieval: { targetResultCount: 25, loadedResultCount: candidates.length, availableResultCount: candidates.length, hasMoreResults: false, termination: "end-of-results" },
    }]);
    expect(accuracy.discoveryRows.filter((row) => row.riskReasons.includes("deterministic-sample"))).toHaveLength(100);
    expect(accuracy.discoveryRows.filter((row) => row.riskReasons.includes("count-priced"))).toHaveLength(1);
    expect(accuracy.requiredVerificationRows).toBeGreaterThanOrEqual(100);
    expect(accuracy.requiredVerificationRows).toBeLessThanOrEqual(101);
  });

  it("does not crown an irrelevant cheaper result as the likely query winner", async () => {
    const makeCandidate = (index: number, productKey: string, name: string, purchasePriceMinor: number) => {
      const truth = browserCaptureTruthSchema.parse({
        capturedAt: "2026-08-12T12:00:00.000Z", pageUrl: "https://www.walmart.com/search?q=fresh%20garlic",
        location: "Omaha L St Supercenter", priceMode: "Pickup", pageIndex: 0, resultIndex: index,
        pageState: { pageType: "search_results", pageTitle: "fresh garlic - Walmart.com", query: "fresh garlic", resultRegionPresent: true, challengeDetected: false, currency: "USD", locale: "en-US", locationText: "Omaha L St Supercenter", fulfillmentText: "Pickup" },
        visible: { rawText: `$${(purchasePriceMinor / 100).toFixed(2)}`, priceMinor: purchasePriceMinor, productName: name, productKey, priceSemantics: { offerType: "everyday", condition: "none", unitPriceMinor: purchasePriceMinor, qualifyingQuantity: 1, totalPriceMinor: purchasePriceMinor, ambiguity: false } },
        structured: { rawText: String(purchasePriceMinor / 100), priceMinor: purchasePriceMinor, productName: name, productKey, priceSemantics: { offerType: "everyday", condition: "none", unitPriceMinor: purchasePriceMinor, qualifyingQuantity: 1, totalPriceMinor: purchasePriceMinor, ambiguity: false } },
        parser: { status: "exact", rule: "next-data-price-lines" },
      });
      return { termKey: "fresh-garlic", query: "fresh garlic", productKey, name, sizeText: "1 each", taxonomyPath: "Food/Produce", purchasePriceMinor, truth };
    };
    const accuracy = await buildBrowserCaptureAccuracy("walmart", [
      makeCandidate(0, "shallot", "Shallot", 75),
      makeCandidate(1, "garlic-seasoning", "Garlic Seasoning", 99),
      makeCandidate(2, "garlic", "Fresh Garlic Bulb", 149),
    ], [], [{
      outcome: "success", rowCount: 3,
      retrieval: { targetResultCount: 3, loadedResultCount: 3, availableResultCount: 3, hasMoreResults: false, termination: "end-of-results" },
    }]);
    const shallot = accuracy.discoveryRows.find((row) => row.productKey === "shallot")!;
    const seasoning = accuracy.discoveryRows.find((row) => row.productKey === "garlic-seasoning")!;
    const garlic = accuracy.discoveryRows.find((row) => row.productKey === "garlic")!;
    expect(shallot.riskReasons).not.toContain("likely-board-winner");
    expect(seasoning.riskReasons).not.toContain("likely-board-winner");
    expect(garlic.riskReasons).toContain("likely-board-winner");
  });
});
