import { describe, expect, it } from "vitest";
import { sameMatchRunFacts } from "./match-run-persistence";

const body = { id: "new", batchId: "batch", configurationId: "config", inputHash: "hash",
  productCount: 10, matchedCount: 8, unmatchedCount: 2, collisionCount: 0, aisleRejectedCount: 1 };

describe("match-run semantic idempotency", () => {
  it("reuses an existing tuple only when every persisted result count agrees", () => {
    expect(sameMatchRunFacts({ id: "prior", status: "passed", product_count: 10, matched_count: 8,
      unmatched_count: 2, collision_count: 0, aisle_rejected_count: 1 }, body, "passed")).toBe(true);
  });

  it("fails closed when an identical tuple carries different result facts", () => {
    expect(sameMatchRunFacts({ id: "prior", status: "passed", product_count: 10, matched_count: 7,
      unmatched_count: 3, collision_count: 0, aisle_rejected_count: 1 }, body, "passed")).toBe(false);
  });
});

