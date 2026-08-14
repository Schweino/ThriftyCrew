import { describe, expect, it } from "vitest";
import { captureBatchProductsQuery } from "./capture-batch-products";

describe("capture-batch matching snapshot", () => {
  it("ranks only immutable observations belonging to the requested batch", () => {
    expect(captureBatchProductsQuery.match(/member\.batch_id = \?1/g)).toHaveLength(1);
    expect(captureBatchProductsQuery).not.toContain("source_batch");
    expect(captureBatchProductsQuery).not.toContain("batch_products");
    expect(captureBatchProductsQuery).toContain("JOIN product_versions pv ON pv.id = o.product_version_id");
  });
});
