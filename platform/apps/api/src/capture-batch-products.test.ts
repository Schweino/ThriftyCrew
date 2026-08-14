import { describe, expect, it } from "vitest";
import { captureBatchProductsQuery } from "./capture-batch-products";

describe("capture-batch matching snapshot", () => {
  it("includes the requested validated batch while excluding unrelated unpromoted batches", () => {
    expect(captureBatchProductsQuery).toContain("source_batch.status IN ('promoted','superseded') OR source_batch.id = ?1");
    expect(captureBatchProductsQuery.match(/member\.batch_id = \?1/g)).toHaveLength(1);
    expect(captureBatchProductsQuery.match(/source_batch\.id = \?1/g)).toHaveLength(1);
  });
});
