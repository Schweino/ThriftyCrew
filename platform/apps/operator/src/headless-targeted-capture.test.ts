import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { assertCompleteResultEnvelope, captureHeadlessDiscovery, claimSearchTerms, familyFareCatalogMatches,
  headlessPriceMinor, headlessPriceSemantics, mapWithConcurrency, matchesFrozenWinner, offsetPageStarts,
  stableProductName } from "./headless-targeted-capture";

describe("headless targeted store capture", () => {
  it("accepts only unambiguous single-package prices", () => {
    expect(headlessPriceMinor("$3.49")).toBe(349);
    expect(headlessPriceMinor(3.49)).toBe(349);
    expect(headlessPriceMinor("4 for $5.00")).toBeNull();
    expect(headlessPriceMinor("$3.499")).toBeNull();
  });

  it("stabilizes retailer trademark mojibake before freezing identity", () => {
    expect(stableProductName("KrogerÂ® Pearl Couscous")).toBe("Kroger Pearl Couscous");
    expect(stableProductName("KrogerÃ‚Â® Pearl Couscous")).toBe("Kroger Pearl Couscous");
  });

  it("refuses a discounted price without a complete effective window", () => {
    expect(headlessPriceSemantics(299, 399)).toBeNull();
    expect(headlessPriceSemantics(299, 399, "2026-08-12T00:00:00.000Z", "2026-08-19T00:00:00.000Z"))
      .toMatchObject({ offerType: "sale", regularPriceMinor: 399 });
    expect(headlessPriceSemantics(399, 399)).toMatchObject({ offerType: "everyday" });
  });

  it("deduplicates locked query plans across a store microbatch", () => {
    const claims = [
      { commodity_proposal_json: JSON.stringify({ searchTerms: ["pistachios", "pistachio nuts"] }) },
      { commodity_proposal_json: JSON.stringify({ searchTerms: ["pistachios", "cinnamon sticks"] }) },
    ];
    expect(claimSearchTerms(claims as never)).toEqual(["pistachios", "pistachio nuts", "cinnamon sticks"]);
  });

  it("filters a full Family Fare catalog with order-independent query tokens", () => {
    expect(familyFareCatalogMatches("ground chipotle", "Organic Chipotle Ground Pepper")).toBe(true);
    expect(familyFareCatalogMatches("wild rice blend", "Long Grain & Wild Rice Blend")).toBe(true);
    expect(familyFareCatalogMatches("chipotle paste", "Chipotle Pepper Sauce")).toBe(false);
  });

  it("runs independent term work concurrently while preserving deterministic result order", async () => {
    let active = 0; let peak = 0;
    const values = await mapWithConcurrency([1, 2, 3, 4, 5, 6], 3, async (value) => {
      active += 1; peak = Math.max(peak, active);
      await new Promise((resolve) => setTimeout(resolve, 5));
      active -= 1;
      return value * 10;
    });
    expect(peak).toBe(3);
    expect(values).toEqual([10, 20, 30, 40, 50, 60]);
  });

  it("requires every offset and every reported Kroger result exactly once", () => {
    expect(offsetPageStarts(120, 50)).toEqual([0, 50, 100]);
    expect(() => assertCompleteResultEnvelope("Baker's", 120, [
      { offset: 0, count: 50, ids: Array.from({ length: 50 }, (_, index) => `p${index}`) },
      { offset: 50, count: 50, ids: Array.from({ length: 50 }, (_, index) => `p${index + 50}`) },
      { offset: 100, count: 20, ids: Array.from({ length: 20 }, (_, index) => `p${index + 100}`) },
    ], 50)).not.toThrow();
    expect(() => assertCompleteResultEnvelope("Baker's", 120, [
      { offset: 0, count: 50, ids: [] }, { offset: 100, count: 20, ids: [] },
    ], 50)).toThrow(/every expected offset|returned 2 pages/);
    expect(() => assertCompleteResultEnvelope("Baker's", 100, [
      { offset: 0, count: 50, ids: Array.from({ length: 50 }, (_, index) => `p${index}`) },
      { offset: 50, count: 50, ids: Array.from({ length: 50 }, (_, index) => index === 0 ? "p0" : `p${index + 50}`) },
    ], 50)).toThrow(/overlapping product identities/);
    expect(() => assertCompleteResultEnvelope("Baker's", 1, [
      { offset: 0, count: 1, ids: [""] },
    ], 50)).toThrow(/without a stable product identity/);
  });

  it("does not truncate a Kroger result total at the former 1,000-result ceiling", () => {
    const starts = offsetPageStarts(1_051, 50);
    expect(starts).toHaveLength(22);
    expect(starts.slice(-2)).toEqual([1_000, 1_050]);
    const truncated = starts.slice(0, 20).map((offset) => ({ offset, count: 50,
      ids: Array.from({ length: 50 }, (_, index) => `p${offset + index}`) }));
    expect(() => assertCompleteResultEnvelope("Baker's", 1_051, truncated, 50)).toThrow(/returned 20 pages/);
  });

  it("fans out all Kroger pages and records examined results rather than only accepted rows", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "tc-headless-test-"));
    const credentials = path.join(directory, "kroger.json"); const output = path.join(directory, "capture.json");
    await writeFile(credentials, JSON.stringify({ client_id: "id", client_secret: "secret" }), "utf8");
    const starts: number[] = [];
    const fetchImpl = async (input: string | URL | Request) => {
      const url = new URL(String(input));
      if (url.pathname.endsWith("/token")) return new Response(JSON.stringify({ access_token: "token" }), { status: 200 });
      const start = Number(url.searchParams.get("filter.start")); starts.push(start);
      const total = 120; const count = Math.min(50, total - start);
      return new Response(JSON.stringify({ data: Array.from({ length: count }, (_, index) => ({ productId: `p${start + index}` })),
        meta: { pagination: { start, limit: 50, total } } }), { status: 200 });
    };
    try {
      const chunk = await captureHeadlessDiscovery("bakers", ["bulk spice"], output,
        { krogerCredentialsFile: credentials, fetchImpl, pageConcurrency: 3 });
      expect(starts.sort((a, b) => a - b)).toEqual([0, 50, 100]);
      expect(chunk.terms?.[0]?.retrieval).toMatchObject({ targetResultCount: 120, loadedResultCount: 120,
        availableResultCount: 120, pageCount: 3, hasMoreResults: false, termination: "end-of-results" });
      expect(JSON.parse(await readFile(output, "utf8"))).toMatchObject({ store: "bakers" });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("recovers a reported 347-product Kroger envelope when offset 300 is rejected", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "tc-kroger-ceiling-test-"));
    const credentials = path.join(directory, "kroger.json"); const output = path.join(directory, "capture.json");
    await writeFile(credentials, JSON.stringify({ client_id: "id", client_secret: "secret" }), "utf8");
    const products = Array.from({ length: 347 }, (_, index) => ({ productId: `p${index.toString().padStart(3, "0")}`,
      brand: `Brand ${index % 7}`, description: `Sea Salt ${index}` }));
    const requests: Array<{ start: number; brands: string | null; fulfillment: string | null }> = [];
    const fetchImpl = async (input: string | URL | Request) => {
      const url = new URL(String(input));
      if (url.pathname.endsWith("/token")) return new Response(JSON.stringify({ access_token: "token" }), { status: 200 });
      const start = Number(url.searchParams.get("filter.start")); const brandFilter = url.searchParams.get("filter.brand");
      requests.push({ start, brands: brandFilter, fulfillment: url.searchParams.get("filter.fulfillment") });
      if (!brandFilter && start >= 300) return new Response(JSON.stringify({ error: "offset limit" }), { status: 400 });
      const brands = new Set((brandFilter ?? "").split("|").filter(Boolean));
      const selected = brandFilter ? products.filter((product) => brands.has(product.brand)) : products;
      return new Response(JSON.stringify({ data: selected.slice(start, start + 50),
        meta: { pagination: { start, limit: 50, total: selected.length } } }), { status: 200 });
    };
    try {
      const chunk = await captureHeadlessDiscovery("bakers", ["sea salt"], output,
        { krogerCredentialsFile: credentials, fetchImpl, pageConcurrency: 8 });
      expect(requests.some((request) => request.brands === null && request.start === 300)).toBe(false);
      expect(requests.every((request) => request.fulfillment === "ais")).toBe(true);
      expect(chunk.terms?.[0]?.retrieval).toMatchObject({ targetResultCount: 347, loadedResultCount: 347,
        availableResultCount: 347, hasMoreResults: false, termination: "end-of-results" });
      expect((chunk.terms?.[0]?.retrieval as Record<string, unknown>).partitionProof).toBeTruthy();
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("keeps one Hy-Vee search view across parallel pages and counts its complete envelope", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "tc-hyvee-test-"));
    const output = path.join(directory, "capture.json"); const requests: Array<{ pageNumber: number; pageViewId: string }> = [];
    const fetchImpl = async (_input: string | URL | Request, init?: RequestInit) => {
      const request = JSON.parse(String(init?.body)) as { pageNumber: number; pageViewId: string };
      requests.push(request);
      const start = (request.pageNumber - 1) * 90; const total = 100; const count = Math.min(90, total - start);
      return new Response(JSON.stringify({ results: Array.from({ length: count }, (_, index) => ({ id: `h${start + index}` })),
        meta: { pagination: { pagesTotal: 2, total } } }), { status: 200 });
    };
    try {
      const chunk = await captureHeadlessDiscovery("hy-vee", ["bulk spice"], output, { fetchImpl, pageConcurrency: 2 });
      expect(requests.map((request) => request.pageNumber).sort()).toEqual([1, 2]);
      expect(new Set(requests.map((request) => request.pageViewId)).size).toBe(1);
      expect(chunk.terms?.[0]?.retrieval).toMatchObject({ loadedResultCount: 100, availableResultCount: 100, pageCount: 2 });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("gives Hy-Vee QA exact producer identity, size, and price semantics", () => {
    const captured = { sourceUrl: "https://www.hy-vee.com/aisles-online/p/1/spice", productName: "Whole Spice",
      packageText: "2 oz", packagePriceMinor: 499 };
    const row = { url: captured.sourceUrl, name: captured.productName, size: captured.packageText,
      _capture: { offer: { purchasePriceMinor: captured.packagePriceMinor } } };
    expect(matchesFrozenWinner(row, captured)).toBe(true);
    expect(matchesFrozenWinner({ ...row, _capture: { offer: { purchasePriceMinor: 599 } } }, captured)).toBe(false);
    expect(matchesFrozenWinner({ ...row, size: "3 oz" }, captured)).toBe(false);
  });
});
