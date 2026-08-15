import { describe, expect, it } from "vitest";
import { deterministicId } from "@thriftycrew/domain";
import { assertFreshBackfillEvidence, assertFrozenBackfillReproduction, assertIndependentBackfillEvidence, assertLegacyBoard,
  catalogBackfillPromotionAllowed, claimCatalogBackfillWorkItem, deriveCatalogBackfillCapture, heartbeatCatalogBackfillOwner } from "./catalog-backfill-v4";
import { assertBackfillIdentityPatterns, compileKnownWrongBackfillProducts, correctCatalogBackfillDefinition, correctCatalogBackfillEvidence, requeueCatalogBackfillCell } from "./catalog-backfill-v4";

const identity = { canonicalName: "Bananas", displayName: "Bananas", acceptedForms: ["Bananas"], excludedForms: ["chips"], basisUnit: "lb" };

function walmartChunk(overrides: Record<string, any> = {}) {
  const observedAt = new Date().toISOString();
  const rows = [{ term: "Bananas", id: "a", name: "Fresh Bananas", size: "2 lb", url: "https://www.walmart.com/ip/a",
    _capture: { location: "Omaha L St Supercenter 5361", priceMode: "pickup",
      pageState: { locationText: "12850 L St store 5361", fulfillmentText: "pickup", challengeDetected: false },
      offer: { retailerProductId: "a", productName: "Fresh Bananas", sourceUrl: "https://www.walmart.com/ip/a", sizeText: "2 lb",
        purchasePriceMinor: 200, availability: { locationId: "5361", fulfillmentMode: "pickup", eligible: true, status: "in_stock" },
        priceSemantics: { offerType: "everyday", condition: "none", ambiguity: false, unitPriceMinor: 200, qualifyingQuantity: 1, totalPriceMinor: 200 } } } },
  { term: "Bananas", id: "b", name: "Fresh Bananas", size: "1 lb", url: "https://www.walmart.com/ip/b",
    _capture: { location: "Omaha L St Supercenter 5361", priceMode: "pickup",
      pageState: { locationText: "12850 L St store 5361", fulfillmentText: "pickup", challengeDetected: false },
      offer: { retailerProductId: "b", productName: "Fresh Bananas", sourceUrl: "https://www.walmart.com/ip/b", sizeText: "1 lb",
        purchasePriceMinor: 150, availability: { locationId: "5361", fulfillmentMode: "pickup", eligible: true, status: "in_stock" },
        priceSemantics: { offerType: "everyday", condition: "none", ambiguity: false, unitPriceMinor: 150, qualifyingQuantity: 1, totalPriceMinor: 150 } } } }];
  return { version: 2, phase: "discovery", store: "walmart",
    canary: { evidenceUrl: "https://www.walmart.com/store/5361-omaha-ne", observedAt,
      location: "Omaha L St Supercenter, 12850 L St, Omaha, NE 68137", locationId: "5361", retailerLocationKey: "5361",
      priceMode: "Pickup", locationVerified: true, priceModeVerified: true },
    terms: [{ query: "Bananas", outcome: "success", rowCount: 2, retrieval: { loadedResultCount: 2, availableResultCount: 2,
      pageCount: 1, hasMoreResults: false, termination: "end-of-results" } }], rows, ...overrides };
}

describe("truthful V4 catalog backfill", () => {
  it("rejects incomplete and duplicate legacy commodity identities", () => {
    expect(() => assertLegacyBoard({ commodities: [] })).toThrow("no commodities");
    expect(() => assertLegacyBoard({ commodities: [{ id: "rice", label: "Rice", unit: "lb" }, { id: "rice", label: "Rice", unit: "lb" }] }))
      .toThrow("duplicate commodity ids");
    expect(() => assertLegacyBoard({ commodities: [{ id: "rice", label: "Rice" }] })).toThrow("identity is incomplete");
  });

  it("sorts valid legacy commodities deterministically", () => {
    expect(assertLegacyBoard({ commodities: [
      { id: "zucchini", label: "Zucchini", unit: "lb" },
      { id: "apples", label: "Apples", unit: "lb" },
    ] }).map((row) => row.id)).toEqual(["apples", "zucchini"]);
  });

  it("never promotes partial, mixed, or oversized evidence counts", () => {
    expect(catalogBackfillPromotionAllowed([{ evidence_state: "terminal_verified", count: 4010 }], 4011)).toBe(false);
    expect(catalogBackfillPromotionAllowed([{ evidence_state: "terminal_verified", count: 4011 }, { evidence_state: "queued", count: 1 }], 4011)).toBe(false);
    expect(catalogBackfillPromotionAllowed([{ evidence_state: "terminal_verified", count: 4012 }], 4011)).toBe(false);
    expect(catalogBackfillPromotionAllowed([{ evidence_state: "terminal_verified", count: 4011 }], 4011)).toBe(true);
  });

  it("requires a newer, independently generated verifier session and hash", () => {
    const producer = { documentHash: "a".repeat(64), generationId: "producer-generation", sessionId: "producer-session",
      observedAt: "2026-08-14T20:00:00.000Z" };
    expect(() => assertIndependentBackfillEvidence({ producer, verifier: { documentHash: "b".repeat(64),
      generationId: "verifier-generation", sessionId: "verifier-session", observedAt: "2026-08-14T20:01:00.000Z" } })).not.toThrow();
    expect(() => assertIndependentBackfillEvidence({ producer, verifier: { ...producer, observedAt: "2026-08-14T20:01:00.000Z" } })).toThrow("not independent");
    expect(() => assertIndependentBackfillEvidence({ producer, verifier: { documentHash: "b".repeat(64),
      generationId: "verifier-generation", sessionId: "verifier-session", observedAt: producer.observedAt } })).toThrow("must be newer");
  });

  it("derives the rational cheapest winner from a complete canonical Omaha adapter chunk", async () => {
    const derived = await deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity,
      document: walmartChunk() });
    expect(derived).toMatchObject({ outcome: "priced", winner: { productId: "a", priceMinor: 200, quantityMicros: 2_000_000 } });
  });

  it("prices an Aluminum Foil multipack by total square-foot material basis", async () => {
    const chunk = walmartChunk() as Record<string, any>;
    const row = chunk.rows[0];
    row.term = chunk.terms[0].query = "Aluminum Foil";
    row.name = row._capture.offer.productName = "Reynolds Heavy Duty Aluminum Foil, 18in x 120 sq. ft., 2pk";
    row.size = row._capture.offer.sizeText = "2 x 120 sq ft";
    chunk.rows = [row]; chunk.terms[0].rowCount = 1;
    chunk.terms[0].retrieval.loadedResultCount = chunk.terms[0].retrieval.availableResultCount = 1;
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Aluminum Foil"], identity: {
      canonicalName: "Aluminum Foil", displayName: "Aluminum Foil", acceptedForms: ["Aluminum Foil"], excludedForms: [],
      includeNamePatterns: ["aluminum\\s+foil"], excludeNamePatterns: [], basisUnit: "sq_ft",
    }, document: chunk })).resolves.toMatchObject({ outcome: "priced", winner: { quantityMicros: 240_000_000 } });
  });

  it.each([
    { ingredient: "Almonds", product: "Member's Mark Whole Natural Almonds, 48 oz.", include: ["\\balmonds\\b"], exclude: ["\\bcereals?\\b", "crackers?", "\\bcandy\\b", "trail\\s*mix"], outcome: "priced" },
    { ingredient: "Almonds", product: "Honey Bunches of Oats with Crispy Almonds Cereal, 48 oz.", include: ["\\balmonds\\b"], exclude: ["\\bcereals?\\b", "\\boats?\\b"], outcome: "not_found" },
    { ingredient: "Almonds", product: "Planters Salted Mixed Nuts, Peanuts, Cashews, Almonds, 56 oz.", include: ["\\balmonds\\b"], exclude: ["\\bmixed\\s+nuts?\\b"], outcome: "not_found" },
    { ingredient: "Almonds", product: "Almond Flour Crackers with Sea Salt, 20 oz.", include: ["\\balmonds\\b"], exclude: ["crackers?", "\\bflour\\b"], outcome: "not_found" },
    { ingredient: "Apple Juice", product: "Apple Juice Flavored Breakfast Cereal, 18 oz.", include: ["apple\\s+juice"], exclude: ["\\bcereals?\\b", "flavored"], outcome: "not_found" },
    { ingredient: "Air Freshener", product: "Glade Air Freshener Spray, 8 oz.", include: ["air\\s+freshener"], exclude: ["candles?", "wax\\s+melts?"], outcome: "priced" },
    { ingredient: "Air Freshener", product: "Air Freshener Scented Candle, 8 oz.", include: ["air\\s+freshener"], exclude: ["candles?", "wax\\s+melts?"], outcome: "not_found" },
  ])("uses versioned include/exclude identity rules for $ingredient: $product", async ({ ingredient, product, include, exclude, outcome }) => {
    const chunk = walmartChunk();
    chunk.rows = [chunk.rows[0]!];
    chunk.rows[0]!.term = ingredient;
    chunk.rows[0]!.name = chunk.rows[0]!._capture.offer.productName = product;
    chunk.terms[0]!.query = ingredient;
    chunk.terms[0]!.rowCount = 1;
    chunk.terms[0]!.retrieval.loadedResultCount = 1;
    chunk.terms[0]!.retrieval.availableResultCount = 1;
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: [ingredient], identity: {
      canonicalName: ingredient, displayName: ingredient, acceptedForms: [ingredient], excludedForms: [],
      includeNamePatterns: include, excludeNamePatterns: exclude, basisUnit: "lb",
    }, document: chunk })).resolves.toMatchObject({ outcome });
  });

  it("binds Sam's almond identity to the definition's source taxonomy and known-wrong facts", async () => {
    const chunk = walmartChunk() as Record<string, any>;
    chunk.store = "sams";
    chunk.canary = { ...chunk.canary, evidenceUrl: "https://www.samsclub.com/club/8146-omaha-ne",
      location: "Omaha Sam's Club", exactAddress: "Omaha Sam's Club", locationId: "8146", retailerLocationKey: "8146", priceMode: "Pickup" };
    chunk.terms[0].query = "Almonds";
    chunk.rows = [chunk.rows[0]];
    chunk.rows[0].term = "Almonds";
    chunk.rows[0].url = chunk.rows[0].url.replace("walmart.com", "samsclub.com");
    chunk.rows[0]._capture.location = "Omaha Sam's Club 8146";
    chunk.rows[0]._capture.pageState.locationText = "Omaha Sam's Club 8146";
    chunk.rows[0]._capture.offer.sourceUrl = chunk.rows[0]._capture.offer.sourceUrl.replace("walmart.com", "samsclub.com");
    chunk.rows[0]._capture.offer.availability.locationId = "8146";
    chunk.rows[0].name = chunk.rows[0]._capture.offer.productName = "Member's Mark Whole Natural Almonds, 48 oz.";
    chunk.rows[0].taxonomy_path = "0:100001:9520104";
    chunk.terms[0].rowCount = 1; chunk.terms[0].retrieval.loadedResultCount = 1; chunk.terms[0].retrieval.availableResultCount = 1;
    const almondIdentity = { canonicalName: "Almonds", displayName: "Almonds", acceptedForms: ["Almonds"], excludedForms: [],
      includeNamePatterns: ["\\balmonds\\b"], excludeNamePatterns: ["\\bcereals?\\b"], basisUnit: "lb",
      storeTaxonomyRules: { "sams-omaha": { allowTerminalIds: ["9520104"] } },
      knownWrongProducts: [{ storeLocationId: "sams-omaha", productId: "known-bad" }] };
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "sams-omaha", queryTerms: ["Almonds"], identity: almondIdentity, document: chunk }))
      .resolves.toMatchObject({ outcome: "priced" });
    chunk.rows[0].name = chunk.rows[0]._capture.offer.productName = "Honey Bunches of Oats with Crispy Almonds, 48 oz.";
    chunk.rows[0].taxonomy_path = "0:100001:2261";
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "sams-omaha", queryTerms: ["Almonds"], identity: almondIdentity, document: chunk }))
      .resolves.toMatchObject({ outcome: "not_found", winner: null });
    chunk.rows[0].name = chunk.rows[0]._capture.offer.productName = "Whole Natural Almonds, 48 oz.";
    chunk.rows[0].taxonomy_path = "";
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "sams-omaha", queryTerms: ["Almonds"], identity: almondIdentity, document: chunk }))
      .resolves.toMatchObject({ outcome: "needs_operator", winner: null });
    chunk.rows.push(structuredClone(chunk.rows[0]));
    chunk.rows[0].id = chunk.rows[0]._capture.offer.retailerProductId = "eligible";
    chunk.rows[0].taxonomy_path = "0:100001:9520104";
    chunk.rows[1].id = chunk.rows[1]._capture.offer.retailerProductId = "irrelevant";
    chunk.rows[1].name = chunk.rows[1]._capture.offer.productName = "Vegetable Tray, 48 oz.";
    chunk.terms[0].rowCount = 2; chunk.terms[0].retrieval.loadedResultCount = 2; chunk.terms[0].retrieval.availableResultCount = 2;
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "sams-omaha", queryTerms: ["Almonds"], identity: almondIdentity, document: chunk }))
      .resolves.toMatchObject({ outcome: "priced", winner: { productId: "eligible" } });
  });

  it("compiles known-wrong rulings with exact normalized store/name/id authority and excludes reversed rulings", () => {
    const compiled = compileKnownWrongBackfillProducts([
      { commodity: "almonds", store: "Baker's", names: ["Bad Almond Cereal"], product_id: "bad-1", verdict: "wrong-product" },
      { commodity: "almonds", store: "Hy-Vee", names: ["Rehabilitated Almonds"], product_id: "good-1", verdict: "wrong-product",
        reversed_on: "2026-08-14", reversed_by: "operator" },
    ], "almonds");
    expect(compiled.unmapped).toEqual([]);
    expect(compiled.reversed).toHaveLength(1);
    expect(compiled.products).toEqual(expect.arrayContaining([
      { storeLocationId: "bakers-saddle-creek", productId: "bad-1" },
      { storeLocationId: "bakers-saddle-creek", normalizedName: "bad almond cereal" },
    ]));
    expect(compiled.products.some((row) => row.productId === "good-1")).toBe(false);
  });

  it.each([
    { productId: "different-id", productName: "Bad Almond Cereal", label: "same normalized name with a different id" },
    { productId: "bad-1", productName: "Renamed Almond Product", label: "same scoped id with changed spelling" },
  ])("rejects a known-wrong product by $label", async ({ productId, productName }) => {
    const chunk = walmartChunk();
    chunk.rows = [chunk.rows[0]!];
    chunk.rows[0]!.term = "Almonds"; chunk.rows[0]!.id = chunk.rows[0]!._capture.offer.retailerProductId = productId;
    chunk.rows[0]!.name = chunk.rows[0]!._capture.offer.productName = productName;
    chunk.terms[0]!.query = "Almonds"; chunk.terms[0]!.rowCount = 1;
    chunk.terms[0]!.retrieval.loadedResultCount = 1; chunk.terms[0]!.retrieval.availableResultCount = 1;
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Almonds"], identity: {
      canonicalName: "Almonds", displayName: "Almonds", acceptedForms: ["Almonds"], excludedForms: [],
      includeNamePatterns: ["almond"], excludeNamePatterns: [], basisUnit: "lb",
      knownWrongProducts: [{ storeLocationId: "walmart-omaha", productId: "bad-1", normalizedName: "bad almond cereal" }],
    }, document: chunk })).resolves.toMatchObject({ outcome: "not_found", winner: null });
  });

  it("rejects invalid, oversized, and backreference identity patterns before persistence", () => {
    expect(() => assertBackfillIdentityPatterns({ includeNamePatterns: ["("], excludeNamePatterns: [] })).toThrow("invalid name pattern");
    expect(() => assertBackfillIdentityPatterns({ includeNamePatterns: ["a".repeat(501)], excludeNamePatterns: [] })).toThrow("unsafe name pattern");
    expect(() => assertBackfillIdentityPatterns({ includeNamePatterns: ["(almond)\\1"], excludeNamePatterns: [] })).toThrow("unsafe name pattern");
  });

  it("terminalizes safely typed raw ineligible candidates but not fact-free exclusions", async () => {
    const priced = walmartChunk();
    priced.rows[1]!._capture.offer.availability = { locationId: "5361", fulfillmentMode: "pickup", eligible: false, status: "unavailable" };
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity, document: priced }))
      .resolves.toMatchObject({ outcome: "priced", winner: { productId: "a" } });
    const absent = walmartChunk();
    for (const row of absent.rows) row._capture.offer.availability = {
      locationId: "5361", fulfillmentMode: "pickup", eligible: false, status: "unavailable",
    };
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity, document: absent }))
      .resolves.toMatchObject({ outcome: "not_found", winner: null });
    const insufficient = walmartChunk({ rows: [], terms: [{ query: "Bananas", outcome: "success", rowCount: 0,
      excludedResults: [{ productKey: "raw-a", name: "Bananas", reason: "missing source truth" }],
      retrieval: { loadedResultCount: 1, availableResultCount: 1, pageCount: 1, hasMoreResults: false, termination: "end-of-results" } }] });
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity, document: insufficient }))
      .resolves.toMatchObject({ outcome: "needs_operator" });
  });

  it("prices an exact mass winner despite a source row with an incompatible volume basis", async () => {
    const mixed = walmartChunk();
    mixed.rows[0]!.name = mixed.rows[0]!._capture.offer.productName = "Bananas, 2 lbs.";
    mixed.rows[0]!.size = mixed.rows[0]!._capture.offer.sizeText = "2 lbs.";
    mixed.rows[1]!.name = mixed.rows[1]!._capture.offer.productName = "Bananas Fragrance Refill";
    mixed.rows[1]!.size = mixed.rows[1]!._capture.offer.sizeText = "2 x 0.25 fl oz";
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity,
      document: mixed })).resolves.toMatchObject({ outcome: "priced", winner: { productId: "a", quantityMicros: 2_000_000 } });
  });

  it("prices an eligible winner beside an irrelevant variable-weight raw candidate", async () => {
    const mixed = walmartChunk();
    mixed.rows[1]!.name = mixed.rows[1]!._capture.offer.productName = "Fresh-Cut Vegetable Tray with Ranch, priced per pound";
    mixed.rows[1]!.size = mixed.rows[1]!._capture.offer.sizeText = "";
    (mixed.rows[1]!._capture.offer as Record<string, unknown>).candidateIssues = ["invalid_package_basis"];
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity,
      document: mixed })).resolves.toMatchObject({ outcome: "priced", winner: { productId: "a" } });
  });

  it("blocks absence when an exact-identity variable-weight raw candidate is unresolved", async () => {
    const unresolved = walmartChunk();
    unresolved.rows = [unresolved.rows[1]!];
    unresolved.rows[0]!.name = unresolved.rows[0]!._capture.offer.productName = "Fresh Bananas, priced per pound";
    unresolved.rows[0]!.size = unresolved.rows[0]!._capture.offer.sizeText = "";
    (unresolved.rows[0]!._capture.offer as Record<string, unknown>).candidateIssues = ["invalid_package_basis"];
    unresolved.terms[0]!.rowCount = 1;
    unresolved.terms[0]!.retrieval.loadedResultCount = 1;
    unresolved.terms[0]!.retrieval.availableResultCount = 1;
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity,
      document: unresolved })).resolves.toMatchObject({ outcome: "needs_operator", winner: null });
  });

  it("classifies identity before nullable raw price facts without inventing zero", async () => {
    const irrelevant = walmartChunk();
    irrelevant.rows[1]!.name = irrelevant.rows[1]!._capture.offer.productName = "Vegetable Tray with Ranch";
    irrelevant.rows[1]!._capture.offer.purchasePriceMinor = null as unknown as number;
    irrelevant.rows[1]!._capture.offer.priceSemantics = { offerType: "unknown", condition: "unknown", ambiguity: true,
      unitPriceMinor: null, qualifyingQuantity: 1, totalPriceMinor: null } as any;
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity,
      document: irrelevant })).resolves.toMatchObject({ outcome: "priced", winner: { productId: "a" } });
    const exact = walmartChunk();
    exact.rows = [exact.rows[1]!];
    exact.rows[0]!._capture.offer.purchasePriceMinor = null as unknown as number;
    exact.rows[0]!._capture.offer.priceSemantics = { offerType: "unknown", condition: "unknown", ambiguity: true,
      unitPriceMinor: null, qualifyingQuantity: 1, totalPriceMinor: null } as any;
    exact.terms[0]!.rowCount = 1; exact.terms[0]!.retrieval.loadedResultCount = 1; exact.terms[0]!.retrieval.availableResultCount = 1;
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity,
      document: exact })).resolves.toMatchObject({ outcome: "needs_operator", winner: null });
  });

  it("never derives not-found from an exact candidate whose availability is unknown", async () => {
    const unknown = walmartChunk();
    for (const row of unknown.rows) row._capture.offer.availability = {
      locationId: "5361", fulfillmentMode: "pickup", eligible: false, status: "unknown",
    };
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity,
      document: unknown })).resolves.toMatchObject({ outcome: "needs_operator", winner: null });
  });

  it("prices an eligible exact winner despite an unknown-availability nonwinner", async () => {
    const mixed = walmartChunk();
    mixed.rows[1]!._capture.offer.availability = {
      locationId: "5361", fulfillmentMode: "pickup", eligible: false, status: "unknown",
    };
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity,
      document: mixed })).resolves.toMatchObject({ outcome: "priced", winner: { productId: "a" } });
  });

  it("never derives not-found when an exact candidate omits its row-level location key", async () => {
    const missingLocation = walmartChunk();
    for (const row of missingLocation.rows) delete (row._capture.offer.availability as Record<string, unknown>).locationId;
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity,
      document: missingLocation })).resolves.toMatchObject({ outcome: "needs_operator", winner: null });
  });

  it("binds Sam's only to canonical club 8146 with configured pickup semantics", async () => {
    const chunk = walmartChunk() as Record<string, any>;
    chunk.store = "sams";
    chunk.canary.evidenceUrl = "https://www.samsclub.com/club/8146-omaha-ne";
    chunk.canary.location = "Omaha Sam's Club";
    chunk.canary.locationId = "8146";
    chunk.canary.retailerLocationKey = "8146";
    for (const row of chunk.rows) {
      row.url = row.url.replace("walmart.com", "samsclub.com");
      row._capture.location = "Omaha club 8146";
      row._capture.priceMode = "pickup";
      row._capture.pageState.locationText = "Omaha club 8146";
      row._capture.offer.sourceUrl = row._capture.offer.sourceUrl.replace("walmart.com", "samsclub.com");
      row._capture.offer.availability.locationId = "8146";
    }
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "sams-omaha", queryTerms: ["Bananas"], identity, document: chunk }))
      .resolves.toMatchObject({ outcome: "priced" });
    for (const row of chunk.rows) {
      row._capture.location = "Omaha club 6181";
      row._capture.pageState.locationText = "Omaha club 6181";
      row._capture.offer.availability.locationId = "6181";
    }
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "sams-omaha", queryTerms: ["Bananas"], identity, document: chunk }))
      .rejects.toThrow("authoritative location and price mode");
  });

  it("accepts Fareway's configured exact-address canary while keeping row availability bound to store 043", async () => {
    const chunk = walmartChunk() as Record<string, any>;
    chunk.store = "fareway";
    chunk.canary.evidenceUrl = "https://shop.fareway.com/store/fareway/products";
    chunk.canary.location = "17070 Audrey Street, Omaha, NE 68136";
    chunk.canary.locationId = "043";
    chunk.canary.retailerLocationKey = "043";
    chunk.canary.priceMode = "In-Store";
    for (const row of chunk.rows) {
      row.url = row.url.replace("walmart.com", "shop.fareway.com");
      row._capture.location = "17070 Audrey Street, Omaha, NE 68136";
      row._capture.priceMode = "In-Store";
      row._capture.pageState.locationText = "17070 Audrey Street, Omaha, NE 68136";
      row._capture.pageState.fulfillmentText = "In-Store";
      row._capture.offer.sourceUrl = row._capture.offer.sourceUrl.replace("walmart.com", "shop.fareway.com");
      row._capture.offer.availability.locationId = "043";
      row._capture.offer.availability.fulfillmentMode = "in_store";
      row._capture.offer.availability.sourceBinding = { retailerLocationId: "531573", shopId: "16671402", serviceType: "instore",
        productId: row.id, sourceProductId: row.id, apolloEncoding: "percent-encoded-json", apolloRawSha256: "a".repeat(64), apolloRawBytes: 100 };
    }
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "fareway-omaha-043", queryTerms: ["Bananas"], identity, document: chunk }))
      .resolves.toMatchObject({ outcome: "priced" });
    for (const row of chunk.rows) row._capture.offer.availability.locationId = "999";
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "fareway-omaha-043", queryTerms: ["Bananas"], identity, document: chunk }))
      .resolves.toMatchObject({ outcome: "not_found" });
    for (const row of chunk.rows) {
      row._capture.offer.availability.locationId = "043";
      delete row._capture.offer.availability.sourceBinding;
    }
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "fareway-omaha-043", queryTerms: ["Bananas"], identity, document: chunk }))
      .resolves.toMatchObject({ outcome: "needs_operator", winner: null });
    for (const row of chunk.rows) row._capture.offer.availability.sourceBinding = {
      retailerLocationId: "531573", shopId: "16671402", serviceType: "instore", productId: "wrong", sourceProductId: row.id,
      apolloEncoding: "percent-encoded-json", apolloRawSha256: "a".repeat(64), apolloRawBytes: 100,
    };
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "fareway-omaha-043", queryTerms: ["Bananas"], identity, document: chunk }))
      .resolves.toMatchObject({ outcome: "needs_operator", winner: null });
  });

  it("accepts the source-native Omaha Hy-Vee #01 canary while binding offers to store 1465", async () => {
    const chunk = walmartChunk() as Record<string, any>;
    chunk.store = "hy-vee";
    chunk.canary.evidenceUrl = "https://www.hy-vee.com/aisles-online/search?search=Bananas";
    chunk.canary.location = "Omaha Hy-Vee #01";
    chunk.canary.locationId = "1465";
    chunk.canary.retailerLocationKey = "1465";
    chunk.canary.priceMode = "in_store";
    for (const row of chunk.rows) {
      row.url = row.url.replace("walmart.com", "hy-vee.com");
      row._capture.location = "Omaha Hy-Vee #01";
      row._capture.priceMode = "in_store";
      row._capture.pageState.locationText = "Omaha Hy-Vee #01";
      row._capture.pageState.fulfillmentText = "in_store";
      row._capture.offer.sourceUrl = row._capture.offer.sourceUrl.replace("walmart.com", "hy-vee.com");
      row._capture.offer.availability.locationId = "1465";
      row._capture.offer.availability.fulfillmentMode = "in_store";
    }
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "hy-vee-omaha-1465", queryTerms: ["Bananas"], identity, document: chunk }))
      .resolves.toMatchObject({ outcome: "priced" });
  });

  it("fails closed on forged empty, missing raw exclusions, policy mismatch, and incomplete pagination", async () => {
    const missingCanonicalCanary = walmartChunk(); delete (missingCanonicalCanary.canary as any).retailerLocationKey;
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity, document: missingCanonicalCanary }))
      .rejects.toThrow("canonical retailer location");
    const empty = walmartChunk({ rows: [], terms: [{ query: "Bananas", outcome: "empty", rowCount: 0,
      retrieval: { loadedResultCount: 0, pageCount: 1, hasMoreResults: false, termination: "no-results" } }] });
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity, document: empty }))
      .rejects.toThrow("complete challenge-free pagination");
    const missingExclusion = walmartChunk({ rows: [], terms: [{ query: "Bananas", outcome: "success", rowCount: 0,
      retrieval: { loadedResultCount: 1, availableResultCount: 1, pageCount: 1, hasMoreResults: false, termination: "end-of-results" } }] });
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity, document: missingExclusion }))
      .rejects.toThrow("complete challenge-free pagination");
    const wrongPolicy = walmartChunk(); wrongPolicy.rows[0]!._capture.offer.availability.locationId = "6181";
    wrongPolicy.rows[0]!._capture.location = "Omaha club 6181"; wrongPolicy.rows[0]!._capture.pageState.locationText = "club 6181";
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity, document: wrongPolicy }))
      .rejects.toThrow("authoritative location and price mode");
    const truncated = walmartChunk(); truncated.terms[0]!.retrieval.hasMoreResults = true;
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity, document: truncated }))
      .rejects.toThrow("complete challenge-free pagination");
  });

  it("derives durable escalation states for blocked, rejected, and raw exclusions", async () => {
    const blocked = walmartChunk({ rows: [], terms: [{ query: "Bananas", outcome: "blocked", rowCount: 0,
      reason: "challenge detected", retrieval: { loadedResultCount: 0, availableResultCount: 0, pageCount: 1, hasMoreResults: false, termination: "blocked" } }] });
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity, document: blocked }))
      .resolves.toMatchObject({ outcome: "challenged" });
    const rejected = walmartChunk({ rows: [], terms: [{ query: "Bananas", outcome: "rejected", rowCount: 0,
      reason: "adapter parse failure", retrieval: { loadedResultCount: 0, availableResultCount: 0, pageCount: 1, hasMoreResults: false, termination: "error" } }] });
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity, document: rejected }))
      .resolves.toMatchObject({ outcome: "needs_operator" });
    const excluded = walmartChunk({ rows: [], terms: [{ query: "Bananas", outcome: "success", rowCount: 0,
      excludedResults: [{ productKey: "raw-a", name: "Bananas", reason: "ambiguous package" }],
      retrieval: { loadedResultCount: 1, availableResultCount: 1, pageCount: 1, hasMoreResults: false, termination: "end-of-results" } }] });
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity, document: excluded }))
      .resolves.toMatchObject({ outcome: "needs_operator" });
    const undatedSale = walmartChunk(); undatedSale.rows[0]!._capture.offer.priceSemantics.offerType = "sale";
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity, document: undatedSale }))
      .resolves.toMatchObject({ outcome: "priced", winner: { productId: "b" } });
    for (const row of undatedSale.rows) row._capture.offer.priceSemantics.offerType = "sale";
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity, document: undatedSale }))
      .resolves.toMatchObject({ outcome: "needs_operator" });
  });

  it("rejects stale/future evidence and a divergent verifier winner", async () => {
    const derived = await deriveCatalogBackfillCapture({ storeLocationId: "walmart-omaha", queryTerms: ["Bananas"], identity,
      document: walmartChunk() });
    const lease = { workItemId: "work", owner: "owner", leaseGeneration: 1, generationId: "generation", sessionId: "session", document: {} };
    expect(() => assertFreshBackfillEvidence("walmart-omaha", lease, { ...derived, observedAt: new Date(Date.now() - 16 * 60_000).toISOString() }))
      .toThrow("stale or future-dated");
    expect(() => assertFreshBackfillEvidence("walmart-omaha", lease, { ...derived, observedAt: new Date(Date.now() + 61_000).toISOString() }))
      .toThrow("stale or future-dated");
    expect(() => assertFrozenBackfillReproduction("priced", { productId: "different" }, derived))
      .toThrow("did not independently reproduce");
  });

  it("makes a typed operator-resolution requeue idempotent by adjudication identity", async () => {
    const db = { prepare() { return { bind() { return this; }, async first() { return { id: "work_repaired" }; } }; } } as unknown as D1Database;
    await expect(requeueCatalogBackfillCell(db, { runId: "run", commodityId: "bananas", storeLocationId: "walmart-omaha",
      adjudicationId: "adapter-fix-1", resolutionType: "adapter_repaired", reason: "adapter now preserves complete raw pickup facts" }))
      .resolves.toEqual({ workItemId: "work_repaired", adjudicationId: "adapter-fix-1", state: "queued", idempotent: true });
  });

  it.each(["producer_ready", "needs_operator", "terminal_verified"])(
    "supersedes invalid %s producer/verifier work and clears readiness before recapture", async (priorState) => {
      const expectedWorkId = await deterministicId("pipeline-v4-work", `old-${priorState}:correction:missing-location-id-v1`);
      const statements: string[] = [];
      const db = { prepare(sql: string) {
        statements.push(sql);
        return { bind() { return this; }, async first() {
          if (sql.includes("$.evidenceCorrection.id")) return null;
          if (sql.includes("cell.ingredient_id")) return { ingredient_id: "ingredient", producer_work_item_id: "producer-old",
            verifier_work_item_id: "verifier-old", evidence_state: priorState, agent_id: "omaha-price-producer-aldi",
            input_json: JSON.stringify({ runId: "run", commodityId: "bananas", storeLocationId: "aldi-omaha-446-048" }), dedupe_key: `old-${priorState}` };
          if (sql.includes("SELECT producer_work_item_id,evidence_state")) return {
            producer_work_item_id: expectedWorkId, evidence_state: "queued" };
          return null;
        } };
      }, async batch(items: unknown[]) { return items; } } as unknown as D1Database;
      const result = await correctCatalogBackfillEvidence(db, { runId: "run", commodityId: "bananas",
        storeLocationId: "aldi-omaha-446-048", correctionId: "missing-location-id-v1",
        reason: "Row availability lacked its canonical retailer location key" });
      expect(result).toMatchObject({ previousState: priorState, state: "queued",
        supersededWorkItemIds: ["producer-old", "verifier-old"] });
      expect(statements.some((sql) => sql.includes("state='superseded'"))).toBe(true);
      expect(statements.some((sql) => sql.includes("terminal_result_json=NULL"))).toBe(true);
      expect(statements.some((sql) => sql.includes("terminal_evidence_count"))).toBe(true);
    });

  it("reports the actual progressed cell state for an idempotent evidence correction", async () => {
    const db = { prepare() { return { bind() { return this; }, async first() { return {
      id: "correction-work", work_state: "succeeded", producer_work_item_id: "correction-work",
      evidence_state: "producer_ready",
    }; } }; } } as unknown as D1Database;
    await expect(correctCatalogBackfillEvidence(db, { runId: "run", commodityId: "bananas",
      storeLocationId: "aldi-omaha-446-048", correctionId: "missing-location-id-v1",
      reason: "Row availability lacked its canonical retailer location key" })).resolves.toMatchObject({
        workItemId: "correction-work", correctionWorkItemId: "correction-work", state: "producer_ready",
        workState: "succeeded", idempotent: true,
      });
  });

  it("returns a refreshed heartbeat snapshot for the exact owner without cross-owner leakage", async () => {
    const rows = [
      { id: "owned", lease_owner: "v4-backfill-walmart-owner", state: "running", agent_id: "omaha-price-producer-walmart" },
      { id: "foreign", lease_owner: "v4-backfill-aldi-owner", state: "running", agent_id: "omaha-price-producer-aldi" },
    ];
    const statements: Array<{ sql: string; bound: unknown[] }> = [];
    const db = { prepare(sql: string) {
      const statement = { sql, bound: [] as unknown[] };
      statements.push(statement);
      return { bind(...values: unknown[]) { statement.bound = values; return this; },
        async all() { return { results: rows.filter((row) => row.lease_owner === statement.bound[0]) }; } };
    } } as unknown as D1Database;
    await expect(heartbeatCatalogBackfillOwner(db, { owner: "v4-backfill-walmart-owner", leaseSeconds: 900 }))
      .resolves.toMatchObject({ renewed: 1, workItems: [{ id: "owned", lease_owner: "v4-backfill-walmart-owner" }] });
    expect(statements[0]?.sql).toContain("WHERE lease_owner=?1");
    expect(statements[0]?.sql).toContain("RETURNING *");
    expect(statements[0]?.bound).toEqual(["v4-backfill-walmart-owner", "+900 seconds"]);
  });

  it("claims only the exact agent-bound backfill work item without scanning global work", async () => {
    const statements: Array<{ sql: string; bound: unknown[] }> = [];
    const db = { prepare(sql: string) {
      const statement = { sql, bound: [] as unknown[] }; statements.push(statement);
      return { bind(...values: unknown[]) { statement.bound = values; return this; }, async first() {
        return statement.bound[0] === "pipeline-v4-work_target" && statement.bound[1] === "omaha-price-producer-sams-club"
          ? { id: statement.bound[0], agent_id: statement.bound[1], lease_owner: statement.bound[2] } : null;
      } };
    } } as unknown as D1Database;
    await expect(claimCatalogBackfillWorkItem(db, { agentId: "omaha-price-producer-sams-club",
      workItemId: "pipeline-v4-work_target", owner: "v4-backfill-sams-repair", leaseSeconds: 900 }))
      .resolves.toMatchObject({ id: "pipeline-v4-work_target", lease_owner: "v4-backfill-sams-repair" });
    expect(statements).toHaveLength(1);
    expect(statements[0]?.sql).toContain("WHERE id=?1 AND agent_id=?2");
    expect(statements[0]?.sql).toContain("RETURNING *");
  });

  it("rejects an exact backfill claim when the agent or lease state does not match", async () => {
    const db = { prepare() { return { bind() { return this; }, async first() { return null; } }; } } as unknown as D1Database;
    await expect(claimCatalogBackfillWorkItem(db, { agentId: "omaha-price-producer-fareway",
      workItemId: "pipeline-v4-work_foreign", owner: "v4-backfill-fareway-repair", leaseSeconds: 900 }))
      .rejects.toThrow("unavailable, mismatched, or already leased");
  });

  it("atomically versions one definition and supersedes all seven cells with rollback metadata", async () => {
    const statements: Array<{ sql: string; bound: unknown[] }> = []; let newVersionId = ""; let newDefinitionHash = "";
    const oldIdentity = { canonicalName: "Almonds", displayName: "Almonds", aliases: [], acceptedForms: ["Almonds"], excludedForms: [],
      requiredQualifiers: [], optionalQualifiers: [], unitDimension: "weight", basisUnit: "oz", packageNormalizationRules: ["legacy"],
      queryTerms: ["Almonds"], storeQueryVariants: {}, sourceOccurrences: [{ recipeCandidateId: "legacy", sourceOccurrenceId: "almonds" }],
      plannerRunId: "legacy", adjudication: null };
    const stores = ["aldi-omaha-446-048", "bakers-saddle-creek", "family-fare-omaha-6401", "fareway-omaha-043",
      "hy-vee-omaha-1465", "sams-omaha", "walmart-omaha"];
    const db = { prepare(sql: string) {
      const statement = { sql, bound: [] as unknown[] }; statements.push(statement);
      return { bind(...values: unknown[]) { statement.bound = values; if (sql.includes("INSERT OR IGNORE INTO catalog_ingredient_versions")) {
          newVersionId = String(values[0]); newDefinitionHash = String(values[10]);
        } return this; },
        async first() {
          if (sql.includes("catalog_backfill_definition_corrections_v4 WHERE")) return null;
          if (sql.includes("SELECT version_id,ingredient_id,definition_hash")) return { version_id: newVersionId,
            ingredient_id: "ingredient-almonds", definition_hash: newDefinitionHash };
          if (sql.includes("COUNT(*) AS cells FROM catalog_backfill_definition_correction_stage_v4")) return { cells: 7 };
          if (sql.includes("COUNT(cell.store_location_id)")) return { current_version_id: newVersionId, pointer_generation: 4,
            definition_version_id: newVersionId, terminal_evidence_count: 0, cells: 7, queued: 7 };
          if (sql.includes("backfill.ingredient_id")) return { ingredient_id: "ingredient-almonds", definition_version_id: "old-definition",
            current_version_id: "old-definition", pointer_generation: 3, version: 1, slug: "almonds", definition_hash: "a".repeat(64),
            identity_json: JSON.stringify(oldIdentity), source_gap_id: null };
          return null;
        }, async all() {
          if (sql.includes("DISTINCT alias.ingredient_id")) return { results: [] };
          if (sql.includes("cell.store_location_id")) return { results: stores.map((store, index) => ({ store_location_id: store,
            evidence_state: index === 0 ? "terminal_verified" : "queued", producer_work_item_id: `producer-${index}`,
            verifier_work_item_id: index === 0 ? "verifier-0" : null, terminal_result_hash: index === 0 ? "b".repeat(64) : null,
            producer_state: index === 0 ? "succeeded" : "queued",
            producer_result_ref_hash: index === 0 ? "c".repeat(64) : null, producer_lease_owner: null,
            producer_lease_generation: 0, producer_lease_expires_at: null, verifier_state: index === 0 ? "claimed" : null,
            verifier_result_ref_hash: null, verifier_lease_owner: index === 0 ? "qa-owner" : null,
            verifier_lease_generation: index === 0 ? 1 : null, verifier_lease_expires_at: index === 0 ? "2099-01-01" : null,
            agent_id: `omaha-price-producer-${index}`, input_json: JSON.stringify({ runId: "run", commodityId: "almonds",
              ingredientId: "ingredient-almonds", definitionVersionId: "old-definition", storeLocationId: store, queryTerms: ["Almonds"] }) })) };
          return { results: [] };
        }, async run() { return {}; } };
    }, async batch(items: unknown[]) { return items; } } as unknown as D1Database;
    const result = await correctCatalogBackfillDefinition(db, { runId: "run", commodityId: "almonds", correctionId: "almonds-authored-v1",
      reason: "Persist authored include, exclude, taxonomy, and known-wrong identity rules" });
    expect(result).toMatchObject({ oldDefinitionVersionId: "old-definition", cells: 7, queued: 7, terminalEvidenceCount: 0,
      oldPointerGeneration: 3, newPointerGeneration: 4, idempotent: false });
    expect(statements.filter((statement) => statement.sql.includes("INSERT OR IGNORE INTO catalog_backfill_definition_correction_stage_v4"))).toHaveLength(7);
    expect(statements.filter((statement) => statement.sql.includes("INSERT INTO catalog_backfill_definition_corrections_v4"))).toHaveLength(1);
    const liveMutations = statements.filter((statement) => /UPDATE catalog_ingredient_current|INSERT INTO pipeline_agent_work_items_v4|UPDATE pipeline_agent_work_items_v4|UPDATE catalog_backfill_cells_v4|UPDATE catalog_backfill_ingredients_v4/.test(statement.sql));
    expect(liveMutations).toHaveLength(5);
    expect(liveMutations.every((statement) => statement.sql.includes("EXISTS(SELECT 1 FROM catalog_backfill_definition_corrections_v4"))).toBe(true);
  });
});
