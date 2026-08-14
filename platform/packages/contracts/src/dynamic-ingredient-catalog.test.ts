import { describe, expect, it } from "vitest";
import { OMAHA_STORE_LOCATION_IDS, publicIngredientSnapshotSchema } from "./dynamic-ingredient-catalog";

const hash = (value: string) => value.repeat(64).slice(0, 64);
const absent = (storeLocationId: typeof OMAHA_STORE_LOCATION_IDS[number], ordinal: number) => ({
  status: "not_found" as const, storeLocationId, fulfillmentMode: "in_store", attemptedQueries: ["test"], coverageType: "targeted_exhaustive" as const,
  paginationProof: { endOfResults: true as const, resultCount: 0, hash: hash(String(ordinal + 1)) },
  producerGenerationId: `producer-${ordinal}`, verifierGenerationId: `verifier-${ordinal}`,
  excludedCandidates: [], producerEvidence: { id: `p-${ordinal}`, hash: hash("a") }, verifierEvidence: { id: `v-${ordinal}`, hash: hash("b") },
  capturedAt: "2026-08-14T12:00:00Z", verifiedAt: "2026-08-14T12:00:01Z",
});

describe("V4 public ingredient contract", () => {
  it("requires all seven stores and at least one price", () => {
    const stores = OMAHA_STORE_LOCATION_IDS.map(absent);
    const base = { ingredientId: "ingredient", definitionVersionId: "definition", slug: "ingredient", canonicalName: "ingredient", displayName: "Ingredient", basisUnit: "oz" };
    expect(publicIngredientSnapshotSchema.safeParse({ ...base, stores }).success).toBe(false);
    const priced = { status: "priced" as const, storeLocationId: OMAHA_STORE_LOCATION_IDS[0], fulfillmentMode: "in_store", retailerProductId: "1", productName: "Ingredient", brand: null,
      packageCount: 1, unitSizeMicros: 1_000_000, totalQuantityMicros: 1_000_000, unitDimension: "weight", basisUnit: "oz", shelfPriceMinor: 100,
      effectivePriceMinor: 100, unitPriceNumerator: 100, unitPriceDenominator: 1, priceKind: "regular" as const, validFrom: null, validTo: null,
      membershipRequired: false, availability: "in_stock", productUrl: "https://example.test/1", capturedAt: "2026-08-14T12:00:00Z",
      producerEvidence: { id: "p", hash: hash("c") }, verifierEvidence: { id: "v", hash: hash("d") }, queryCoverageHash: hash("e"), candidateSetHash: hash("f"), winningDecisionHash: hash("1") };
    expect(publicIngredientSnapshotSchema.safeParse({ ...base, stores: [priced, ...stores.slice(1)] }).success).toBe(true);
  });

  it("rejects reused producer evidence", () => {
    const rows = OMAHA_STORE_LOCATION_IDS.map(absent);
    rows[0]!.verifierEvidence.hash = rows[0]!.producerEvidence.hash;
    const base = { ingredientId: "ingredient", definitionVersionId: "definition", slug: "ingredient", canonicalName: "ingredient", displayName: "Ingredient", basisUnit: "oz", stores: rows };
    expect(publicIngredientSnapshotSchema.safeParse(base).success).toBe(false);
  });
});
