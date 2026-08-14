import { describe, expect, it } from "vitest";
import { matchDecisionDeltaReconcileSchema, matchDecisionRebindSchema, matchDecisionsChunkSchema } from "./index";

function decisions(count: number) {
  return Array.from({ length: count }, (_, index) => ({
    productId: `product-${index}`,
    commodityId: "commodity",
    configurationId: "configuration",
    decidedBy: "rule" as const,
    reason: "authored rule",
  }));
}

describe("match decision upload chunks", () => {
  it("accepts the measured 250-row upload size and rejects larger requests", () => {
    expect(matchDecisionsChunkSchema.safeParse({ decisions: decisions(250) }).success).toBe(true);
    expect(matchDecisionsChunkSchema.safeParse({ decisions: decisions(251) }).success).toBe(false);
  });

  it("requires incremental rebinds to cross configuration boundaries", () => {
    expect(matchDecisionRebindSchema.safeParse({
      batchId: "batch", sourceConfigurationId: "old", targetConfigurationId: "new", excludedProductIds: [],
    }).success).toBe(true);
    expect(matchDecisionRebindSchema.safeParse({
      batchId: "batch", sourceConfigurationId: "same", targetConfigurationId: "same", excludedProductIds: [],
    }).success).toBe(false);
  });

  it("allows delta reconciliation only for products in the affected set", () => {
    expect(matchDecisionDeltaReconcileSchema.safeParse({
      batchId: "batch", configurationId: "new", affectedProductIds: ["one", "two"], retainedProductIds: ["two"],
    }).success).toBe(true);
    expect(matchDecisionDeltaReconcileSchema.safeParse({
      batchId: "batch", configurationId: "new", affectedProductIds: ["one"], retainedProductIds: ["two"],
    }).success).toBe(false);
  });
});
