import { describe, expect, it } from "vitest";
import { assertObservationArithmetic, canonicalProductUrl, expectedPerUnitMicros, expectedProductIdentityFingerprint, isClearlyIngredientDerivative, isClearlyNonFoodIngredientProduct, matchesIngredientCommodityExclusion, normalizeName, productIdentityPass, semanticOfferFact, semanticProductVersion, stableJson } from "./index";

describe("domain invariants", () => {
  it("normalizes product identity without punctuation drift", () => {
    expect(normalizeName("Member's Mark, 48 OZ. & More")).toBe("member s mark 48 oz and more");
  });

  it("rejects prepared derivatives and non-food lookalikes from ingredient pricing", () => {
    expect(isClearlyIngredientDerivative("green-chilli", "Pueblo Lindo Chopped Green Chiles")).toBe(true);
    expect(isClearlyIngredientDerivative("saffron", "Mahatma Saffron Rice")).toBe(true);
    expect(isClearlyNonFoodIngredientProduct("Saffron Eau de Parfum Spray")).toBe(true);
    expect(isClearlyNonFoodIngredientProduct("Amber & Saffron Incense Sticks")).toBe(true);
    expect(isClearlyNonFoodIngredientProduct("Rose Water Eyeshadow Palette")).toBe(true);
    expect(isClearlyNonFoodIngredientProduct("Micellar Rose Cleansing Water")).toBe(true);
  });

  it("applies locked package-form exclusions as well as product-name exclusions", () => {
    expect(matchesIngredientCommodityExclusion(["(?i)\\bcanned\\b"], "Green Chiles", "4 oz can")).toBe(true);
    expect(matchesIngredientCommodityExclusion(["(?i)\\bcanned\\b"], "Fresh Green Chilli", "8 oz bag")).toBe(false);
  });

  it("computes integer per-unit money", () => {
    expect(expectedPerUnitMicros(477, 1_000_000)).toBe(4_770_000);
    expect(expectedPerUnitMicros(299, 2_000_000)).toBe(1_495_000);
  });

  it("rejects a package-basis mismatch", () => {
    expect(() => assertObservationArithmetic({
      externalProductKey: "x",
      name: "Example",
      sizeText: "2 lb",
      package: {},
      kind: "everyday",
      currency: "USD",
      purchasePriceMinor: 299,
      purchaseQuantity: 1,
      packageCount: 1,
      capturedBasisUnit: "lb",
      capturedBasisQtyMicros: 2_000_000,
      normalizedBasisUnit: "lb",
      normalizedBasisQtyMicros: 2_000_000,
      perUnitMicros: 2_990_000,
      loyaltyRequired: false,
      membershipRequired: false,
      rawPriceText: "$2.99",
      rawSizeText: "2 lb",
      capturedAt: "2026-08-09T12:00:00.000Z",
    })).toThrow(/per-unit mismatch/);
  });

  it("produces stable object hashes independent of key order", () => {
    expect(stableJson({ b: 2, a: 1 })).toBe(stableJson({ a: 1, b: 2 }));
  });

  it("matches JSON wire semantics for undefined values", () => {
    expect(stableJson({ kept: 1, omitted: undefined, array: [1, undefined] })).toBe('{"array":[1,null],"kept":1}');
  });

  it("keeps transport provenance out of semantic product and offer identity", () => {
    expect(canonicalProductUrl("https://STORE.example/item/1/?utm_source=x#details")).toBe("https://store.example/item/1");
    const product = { name: " Whole Milk ", sizeText: "1 GAL", productUrl: "https://store.example/item/1?session=a", taxonomyPath: "Dairy > Milk", identity: { brand: "Store Brand" } };
    expect(semanticProductVersion(product)).toEqual(semanticProductVersion({ ...product, productUrl: "https://store.example/item/1?session=b" }));
    const offer = {
      kind: "everyday", currency: "USD", purchasePriceMinor: 399, purchaseQuantity: 1, packageCount: 1,
      capturedBasisUnit: "gal", capturedBasisQtyMicros: 1_000_000, normalizedBasisUnit: "gal",
      normalizedBasisQtyMicros: 1_000_000, perUnitMicros: 3_990_000, loyaltyRequired: false,
      membershipRequired: false, rawPriceText: "$3.99", rawSizeText: "1 gal",
      offerSnapshot: { observedAt: "2026-08-11T00:00:00Z", retailerProductId: "1" },
    };
    expect(semanticOfferFact(offer)).toEqual(semanticOfferFact({ ...offer, offerSnapshot: { ...offer.offerSnapshot, observedAt: "2026-08-12T00:00:00Z" } }));
  });

  it("rejects forged identity fingerprints and confidence inflation", async () => {
    const base = { primaryType: "retailer_id" as const, primaryValue: "sku-1", retailerProductId: "sku-1", canonicalUrl: "https://retailer.example/ip/item/sku-1" };
    const fingerprint = await expectedProductIdentityFingerprint(base, "Whole Milk", "1 gal");
    expect(await productIdentityPass("sku-1", "Whole Milk", "1 gal", { ...base, confidence: "strong", fingerprint })).toBe(true);
    expect(await productIdentityPass("sku-1", "Cat Litter", "40 lb", { ...base, confidence: "strong", fingerprint })).toBe(false);
    expect(await productIdentityPass("sku-1", "Whole Milk", "1 gal", { ...base, confidence: "moderate", fingerprint })).toBe(false);
  });
});
