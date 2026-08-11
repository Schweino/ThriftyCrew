import { describe, expect, it } from "vitest";
import { matchDecisionsChunkSchema } from "./index";

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
});
