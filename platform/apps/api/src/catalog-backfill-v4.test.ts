import { describe, expect, it } from "vitest";
import { assertFreshBackfillEvidence, assertFrozenBackfillReproduction, assertIndependentBackfillEvidence, assertLegacyBoard,
  catalogBackfillPromotionAllowed, deriveCatalogBackfillCapture, heartbeatCatalogBackfillOwner } from "./catalog-backfill-v4";
import { requeueCatalogBackfillCell } from "./catalog-backfill-v4";

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
    }
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "fareway-omaha-043", queryTerms: ["Bananas"], identity, document: chunk }))
      .resolves.toMatchObject({ outcome: "priced" });
    for (const row of chunk.rows) row._capture.offer.availability.locationId = "999";
    await expect(deriveCatalogBackfillCapture({ storeLocationId: "fareway-omaha-043", queryTerms: ["Bananas"], identity, document: chunk }))
      .resolves.toMatchObject({ outcome: "not_found" });
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
});
