import { describe, expect, it } from "vitest";
import { assessProductHistory, assessSourceSchema, type ProductHistoryRow } from "./capture-semantic-guards";

function row(overrides: Partial<ProductHistoryRow> = {}): ProductHistoryRow {
  return {
    product_id: "p1", external_key: "sku-1", current_observation_id: "o2", current_name: "Whole Milk", current_size_text: "1 gal",
    current_per_unit_micros: 3990000, current_basis_unit: "gal", current_basis_qty_micros: 1000000,
    current_identity_json: JSON.stringify({ primaryValue: "sku-1", confidence: "strong", retailerProductId: "sku-1", upc: "123456789012" }),
    prior_observation_id: "o1", prior_name: "Whole Milk", prior_size_text: "1 gal", prior_per_unit_micros: 3490000,
    prior_basis_unit: "gal", prior_basis_qty_micros: 1000000,
    prior_identity_json: JSON.stringify({ primaryValue: "sku-1", confidence: "strong", retailerProductId: "sku-1", upc: "123456789012" }),
    ...overrides,
  };
}

describe("capture semantic guards", () => {
  it("accepts stable product history and a first source-schema baseline", () => {
    expect(assessProductHistory([row()])).toEqual({ identityFindings: [], changePointFindings: [] });
    expect(assessSourceSchema("a".repeat(64), null, true).pass).toBe(true);
  });

  it("detects external-key reuse, stable-id conflict, and price/package change points", () => {
    const result = assessProductHistory([row({
      current_name: "Cat Litter", current_size_text: "40 lb", current_basis_unit: "lb", current_basis_qty_micros: 40000000,
      current_per_unit_micros: 199000, current_identity_json: JSON.stringify({ primaryValue: "sku-1", confidence: "strong", retailerProductId: "sku-1", upc: "999999999999" }),
      prior_basis_unit: "lb", prior_basis_qty_micros: 1000000, prior_per_unit_micros: 1990000,
    })]);
    expect(result.identityFindings.map((finding) => finding.key)).toEqual(expect.arrayContaining(["identifier:p1:upc", "reuse:p1"]));
    expect(result.changePointFindings.map((finding) => finding.key)).toEqual(expect.arrayContaining(["basis:p1", "price:p1"]));
  });

  it("fails a changed semantic source fingerprint", () => {
    expect(assessSourceSchema("a".repeat(64), "b".repeat(64), true)).toMatchObject({ pass: false, detail: { drift: true } });
  });
});
