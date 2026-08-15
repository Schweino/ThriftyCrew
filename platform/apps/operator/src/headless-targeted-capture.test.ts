import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { assertCompleteResultEnvelope, captureHeadlessDiscovery, claimSearchTerms, familyFareCatalogMatches, headlessStoreCanary,
  headlessPriceMinor, headlessPriceSemantics, mapWithConcurrency, matchesFrozenWinner, offsetPageStarts,
  stableProductName } from "./headless-targeted-capture";

describe("headless targeted store capture", () => {
  it.each([
    ["bakers", "61500319", "in_store"],
    ["family-fare", "6401", "pickup"],
    ["hy-vee", "1465", "in_store"],
  ] as const)("emits the canonical %s policy key", (store, key, priceMode) => {
    expect(headlessStoreCanary(store, "2026-08-14T00:00:00.000Z")).toMatchObject({
      locationId: key, retailerLocationKey: key, priceMode, locationVerified: true, priceModeVerified: true,
    });
  });
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
      expect(requests.some((request) => request.brands === null && request.start === 297)).toBe(true);
      expect(requests.filter((request) => request.brands === null)).toHaveLength(55);
      expect(requests.every((request) => request.fulfillment === "ais")).toBe(true);
      expect(chunk.terms?.[0]?.retrieval).toMatchObject({ targetResultCount: 347, loadedResultCount: 347,
        availableResultCount: 347, hasMoreResults: false, termination: "end-of-results" });
      expect((chunk.terms?.[0]?.retrieval as Record<string, unknown>).partitionProof).toBeTruthy();
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("reconciles cross-window Kroger reorder duplicates instead of rejecting the readable capped prefix", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "tc-kroger-prefix-reorder-test-"));
    const credentials = path.join(directory, "kroger.json"); const output = path.join(directory, "capture.json");
    await writeFile(credentials, JSON.stringify({ client_id: "id", client_secret: "secret" }), "utf8");
    const products = Array.from({ length: 305 }, (_, index) => ({ productId: `p${index.toString().padStart(3, "0")}`,
      brand: `Brand ${index % 5}`, description: `Apples ${index}` }));
    const fetchImpl = async (input: string | URL | Request) => {
      const url = new URL(String(input));
      if (url.pathname.endsWith("/token")) return new Response(JSON.stringify({ access_token: "token" }), { status: 200 });
      const start = Number(url.searchParams.get("filter.start")); const brandFilter = url.searchParams.get("filter.brand");
      const brands = new Set((brandFilter ?? "").split("|").filter(Boolean));
      const selected = brandFilter ? products.filter((product) => brands.has(product.brand)) : products;
      const page = selected.slice(start, start + 50);
      if (!brandFilter && start === 50) page[0] = products[49]!;
      return new Response(JSON.stringify({ data: page, meta: { pagination: { start, limit: 50, total: selected.length } } }), { status: 200 });
    };
    try {
      const chunk = await captureHeadlessDiscovery("bakers", ["apples"], output,
        { krogerCredentialsFile: credentials, fetchImpl, pageConcurrency: 8 });
      expect(chunk.terms?.[0]).toMatchObject({ outcome: "success", retrieval: {
        targetResultCount: 305, loadedResultCount: 305, availableResultCount: 305, termination: "end-of-results" } });
    } finally { await rm(directory, { recursive: true, force: true }); }
  });

  it("isolates one failed term without discarding successful sibling terms", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "tc-kroger-term-isolation-"));
    const credentials = path.join(directory, "kroger.json"); const output = path.join(directory, "capture.json");
    await writeFile(credentials, JSON.stringify({ client_id: "id", client_secret: "secret" }), "utf8");
    const fetchImpl = async (input: string | URL | Request) => {
      const url = new URL(String(input));
      if (url.pathname.endsWith("/token")) return new Response(JSON.stringify({ access_token: "token" }), { status: 200 });
      const term = url.searchParams.get("filter.term"); const start = Number(url.searchParams.get("filter.start"));
      if (term === "sea salt") return new Response(JSON.stringify({ error: "source ceiling" }), { status: 400 });
      const products = [{ productId: "c1", brand: "Spice Co", description: "Whole Cumin Seeds" }];
      return new Response(JSON.stringify({ data: products.slice(start, start + 50),
        meta: { pagination: { start, limit: 50, total: products.length } } }), { status: 200 });
    };
    try {
      const chunk = await captureHeadlessDiscovery("bakers", ["sea salt", "cumin seeds"], output,
        { krogerCredentialsFile: credentials, fetchImpl, pageConcurrency: 2 });
      expect(chunk.terms?.find((term) => term.query === "sea salt")).toMatchObject({ outcome: "rejected",
        retrieval: { termination: "error", hasMoreResults: false } });
      expect(chunk.terms?.find((term) => term.query === "cumin seeds")).toMatchObject({ outcome: "success", rowCount: 1,
        retrieval: { termination: "end-of-results", availableResultCount: 1 } });
      expect(chunk.rows?.find((row) => row.id === "c1")).toMatchObject({ _capture: { offer: {
        purchasePriceMinor: null, candidateIssues: ["invalid_package_basis", "invalid_price_semantics"] } } });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("reconciles an inconsistent broad Kroger total only through complete disjoint brand facets", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "tc-kroger-facet-reconcile-"));
    const credentials = path.join(directory, "kroger.json"); const output = path.join(directory, "capture.json");
    await writeFile(credentials, JSON.stringify({ client_id: "id", client_secret: "secret" }), "utf8");
    const products = Array.from({ length: 333 }, (_, index) => ({ productId: `p${index}`,
      brand: `Brand ${index % 7}`, description: `Sea Salt ${index}` }));
    const fetchImpl = async (input: string | URL | Request) => {
      const url = new URL(String(input));
      if (url.pathname.endsWith("/token")) return new Response(JSON.stringify({ access_token: "token" }), { status: 200 });
      const start = Number(url.searchParams.get("filter.start")); const brandFilter = url.searchParams.get("filter.brand");
      if (!brandFilter && start > 250) return new Response(JSON.stringify({ error: "offset limit" }), { status: 400 });
      const brands = new Set((brandFilter ?? "").split("|").filter(Boolean));
      const selected = brandFilter ? products.filter((product) => brands.has(product.brand)) : products;
      return new Response(JSON.stringify({ data: selected.slice(start, start + 50),
        meta: { pagination: { start, limit: 50, total: brandFilter ? selected.length : 337 } } }), { status: 200 });
    };
    try {
      const chunk = await captureHeadlessDiscovery("bakers", ["sea salt"], output,
        { krogerCredentialsFile: credentials, fetchImpl, pageConcurrency: 8 });
      expect(chunk.terms?.[0]?.retrieval).toMatchObject({ targetResultCount: 333, loadedResultCount: 333,
        availableResultCount: 333, hasMoreResults: false, termination: "end-of-results" });
      expect((chunk.terms?.[0]?.retrieval as { partitionProof?: Array<Record<string, unknown>> }).partitionProof)
        .toContainEqual(expect.objectContaining({ strategy: "disjoint_brand_facets", broadReportedTotal: 337,
          authoritativeUniqueTotal: 333, observedOutsidePartitions: 0 }));
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("accepts Kroger's pagination-less empty first page as a complete zero-result envelope", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "tc-kroger-empty-test-"));
    const credentials = path.join(directory, "kroger.json"); const output = path.join(directory, "capture.json");
    await writeFile(credentials, JSON.stringify({ client_id: "id", client_secret: "secret" }), "utf8");
    const fetchImpl = async (input: string | URL | Request) => {
      const url = new URL(String(input));
      if (url.pathname.endsWith("/token")) return new Response(JSON.stringify({ access_token: "token" }), { status: 200 });
      return new Response(JSON.stringify({ data: [] }), { status: 200 });
    };
    try {
      const chunk = await captureHeadlessDiscovery("bakers", ["ras el hanout"], output,
        { krogerCredentialsFile: credentials, fetchImpl });
      expect(chunk.terms?.[0]).toMatchObject({ outcome: "empty", rowCount: 0,
        retrieval: { targetResultCount: 0, loadedResultCount: 0, availableResultCount: 0,
          pageCount: 1, hasMoreResults: false, termination: "end-of-results" } });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("preserves a Baker's priced raw candidate with unresolved package facts", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "tc-kroger-raw-test-"));
    const credentials = path.join(directory, "kroger.json"); const output = path.join(directory, "capture.json");
    await writeFile(credentials, JSON.stringify({ client_id: "id", client_secret: "secret" }), "utf8");
    const fetchImpl = async (input: string | URL | Request) => {
      const url = new URL(String(input));
      if (url.pathname.endsWith("/token")) return new Response(JSON.stringify({ access_token: "token" }), { status: 200 });
      return new Response(JSON.stringify({ data: [{ productId: "b1", description: "Loose Acorn Squash priced per pound",
        productPageURI: "/p/acorn/b1", items: [{ itemId: "i1", size: "", price: { regular: null },
          fulfillment: { inStore: true }, inventory: { stockLevel: "HIGH" } }] }],
        meta: { pagination: { start: 0, limit: 50, total: 1 } } }), { status: 200 });
    };
    try {
      const chunk = await captureHeadlessDiscovery("bakers", ["acorn squash"], output,
        { krogerCredentialsFile: credentials, fetchImpl });
      expect(chunk.rows).toHaveLength(1);
      expect(chunk.rows?.[0]).toMatchObject({ id: "b1", size: "", _capture: { offer: {
        purchasePriceMinor: null, candidateIssues: ["invalid_package_basis", "invalid_price_semantics"] },
        parser: { status: "typed_unpriceable" } } });
      expect(chunk.terms?.[0]).toMatchObject({ rowCount: 1, retrieval: { loadedResultCount: 1, availableResultCount: 1 } });
    } finally { await rm(directory, { recursive: true, force: true }); }
  });

  it("preserves a Family Fare priced raw candidate with unresolved package facts", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "tc-freshop-raw-test-"));
    const catalog = path.join(directory, "catalog.json"); const output = path.join(directory, "capture.json");
    await writeFile(catalog, JSON.stringify({ deals: [{ product_id: "f1", item: "Loose Acorn Squash" }] }), "utf8");
    const fetchImpl = async (input: string | URL | Request) => {
      const url = new URL(String(input));
      if (url.pathname.endsWith("/stores/6401")) return new Response(JSON.stringify({ city: "Omaha" }), { status: 200 });
      return new Response(JSON.stringify({ id: "f1", name: "Loose Acorn Squash", size: "", price: 1.29,
        base_price: 1.29, status: "available", canonical_url: "/product/f1" }), { status: 200 });
    };
    try {
      const chunk = await captureHeadlessDiscovery("family-fare", ["acorn squash"], output,
        { familyFareCatalogFile: catalog, fetchImpl });
      expect(chunk.rows).toHaveLength(1);
      expect(chunk.rows?.[0]).toMatchObject({ id: "f1", size: "", _capture: { offer: {
        candidateIssues: ["invalid_package_basis"] }, parser: { status: "typed_unpriceable" } } });
      expect(chunk.terms?.[0]).toMatchObject({ rowCount: 1, retrieval: { loadedResultCount: 1, availableResultCount: 1 } });
    } finally { await rm(directory, { recursive: true, force: true }); }
  });

  it("preserves indexed Family Fare identity as availability-unknown when the store detail is empty", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "tc-freshop-empty-detail-test-"));
    const catalog = path.join(directory, "catalog.json"); const output = path.join(directory, "capture.json");
    await writeFile(catalog, JSON.stringify({ deals: [
      { product_id: "oil", item: "Chosen Foods Pure Avocado Oil", size: "16 oz", current_price: 12.99,
        base_price: 12.99, canonical_url: "/product/oil" },
      { product_id: "shampoo", item: "Suave Shampoo Avocado Oil", size: "28 oz", current_price: 5.99,
        base_price: 5.99, canonical_url: "/product/shampoo" },
    ] }), "utf8");
    const fetchImpl = async (input: string | URL | Request) => {
      const url = new URL(String(input));
      if (url.pathname.endsWith("/stores/6401")) return new Response(JSON.stringify({ city: "Omaha" }), { status: 200 });
      if (url.pathname.endsWith("/products/shampoo")) return new Response("{}", { status: 200 });
      return new Response(JSON.stringify({ id: "oil", name: "Chosen Foods Pure Avocado Oil", size: "16 oz", price: 12.99,
        base_price: 12.99, status: "available", canonical_url: "/product/oil" }), { status: 200 });
    };
    try {
      const chunk = await captureHeadlessDiscovery("family-fare", ["avocado oil"], output,
        { familyFareCatalogFile: catalog, fetchImpl });
      expect(chunk.rows).toHaveLength(2);
      expect(chunk.terms?.[0]?.excludedResults).toBeUndefined();
      expect(chunk.rows?.find((row) => row.id === "shampoo")).toMatchObject({ _capture: { offer: { availability: {
        status: "unknown", eligible: false, locationId: "6401" } } } });
    } finally { await rm(directory, { recursive: true, force: true }); }
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

  it("preserves source-declared sponsored rows inside Hy-Vee's complete reported envelope", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "tc-hyvee-sponsored-test-"));
    const output = path.join(directory, "capture.json");
    const product = (id: string, isSponsored: boolean) => ({ id, description: `${id} Adobo Seasoning`, unitOfMeasure: "8 oz",
      isSponsored, isEcommerceActive: true, pricing: { tagPriceValue: 2.99, basePriceValue: 2.99 } });
    const fetchImpl = async () => new Response(JSON.stringify({ results: [product("s1", true), product("o1", false)],
      meta: { pagination: { pagesTotal: 1, total: 2 } } }), { status: 200 });
    try {
      const chunk = await captureHeadlessDiscovery("hy-vee", ["adobo seasoning"], output, { fetchImpl });
      expect(chunk.rows).toHaveLength(2);
      expect(chunk.terms?.[0]?.retrieval).toMatchObject({ loadedResultCount: 2, availableResultCount: 2 });
      expect(chunk.terms?.[0]?.retrieval).not.toHaveProperty("partitionProof");
    } finally { await rm(directory, { recursive: true, force: true }); }
  });

  it("preserves additive sponsored rows outside Hy-Vee's organic reported total", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "tc-hyvee-sponsored-additive-test-"));
    const output = path.join(directory, "capture.json");
    const product = (id: string, isSponsored: boolean) => ({ id, description: `${id} Adobo Seasoning`, unitOfMeasure: "8 oz",
      isSponsored, isEcommerceActive: true, pricing: { tagPriceValue: 2.99, basePriceValue: 2.99 } });
    const fetchImpl = async () => new Response(JSON.stringify({ results: [product("s1", true), product("o1", false)],
      meta: { pagination: { pagesTotal: 1, total: 1 } } }), { status: 200 });
    try {
      const chunk = await captureHeadlessDiscovery("hy-vee", ["adobo seasoning"], output, { fetchImpl });
      expect(chunk.terms?.[0]?.retrieval).toMatchObject({ loadedResultCount: 2, availableResultCount: 2,
        partitionProof: [{ strategy: "organic_total_plus_sponsored", organicReportedTotal: 1, sponsoredUnique: 1,
          authoritativeUniqueTotal: 2 }] });
    } finally { await rm(directory, { recursive: true, force: true }); }
  });

  it("rejects a Hy-Vee envelope whose raw rows exceed its reported total", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "tc-hyvee-sponsored-count-test-"));
    const output = path.join(directory, "capture.json");
    const fetchImpl = async () => new Response(JSON.stringify({ results: [
      { id: "s1", description: "Sponsored Almonds", isSponsored: true },
      { id: "o1", description: "Organic Almonds", isSponsored: false },
      { id: "o2", description: "More Organic Almonds", isSponsored: false },
    ], meta: { pagination: { pagesTotal: 1, total: 1 } } }), { status: 200 });
    try {
      const chunk = await captureHeadlessDiscovery("hy-vee", ["almonds"], output, { fetchImpl });
      expect(chunk.terms?.[0]).toMatchObject({ outcome: "rejected", reason: "Hy-Vee pagination examined 3 raw/2 organic of 1 reported results" });
    } finally { await rm(directory, { recursive: true, force: true }); }
  });

  it("preserves a Hy-Vee raw result whose dedicated size contradicts its exact title suffix", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "tc-hyvee-size-test-"));
    const output = path.join(directory, "capture.json");
    const fetchImpl = async () => new Response(JSON.stringify({
      results: [{ id: "3976100", description: "McCormick Gourmet Saffron, 0.04 oz", unitOfMeasure: "0.35 oz",
        isEcommerceActive: true, pricing: { tagPriceValue: 24.99, basePriceValue: 24.99 } }],
      meta: { pagination: { pagesTotal: 1, total: 1 } },
    }), { status: 200 });
    try {
      const chunk = await captureHeadlessDiscovery("hy-vee", ["saffron"], output, { fetchImpl });
      expect(chunk.rows).toHaveLength(1);
      expect(chunk.rows?.[0]).toMatchObject({ id: "3976100", size: "", _capture: { offer: {
        rawSizeText: "0.35 oz", candidateIssues: ["invalid_package_basis"] }, parser: { status: "typed_unpriceable" } } });
      expect(chunk.terms?.[0]?.excludedResults).toBeUndefined();
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
