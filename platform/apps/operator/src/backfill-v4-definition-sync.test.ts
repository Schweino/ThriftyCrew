import { describe, expect, it } from "vitest";
import { planDefinitionSync } from "./backfill-v4-definition-sync";

function audit() {
  return { summary: { total: 573, invalid: 0 }, definitions: Array.from({ length: 573 }, (_, index) => ({
    commodityId: index === 0 ? "almonds" : `commodity-${String(index).padStart(3, "0")}`, changed: true })),
    unmapped: { missingConfig: [], configNotInRun: [], knownWrongCommodityNotInRun: [], knownWrongStore: [],
      reversedKnownWrong: Array.from({ length: 3 }, (_, index) => ({ reversed_on: "2026-08-01", reversed_by: `operator-${index}` })) } };
}

describe("V4 definition sync planning", () => {
  it("excludes the completed Almonds sample and resumes deterministically by offset", () => {
    const first = planDefinitionSync(audit(), { offset: 0, limit: 25, excluded: new Set(["almonds"]) });
    const restarted = planDefinitionSync(audit(), { offset: 25, limit: 25, excluded: new Set(["almonds"]) });
    expect(first).toMatchObject({ total: 572, nextOffset: 25, reversedKnownWrong: 3 });
    expect(first.page[0]).toEqual({ commodityId: "commodity-001", correctionId: "authored-identity-v1-commodity-001" });
    expect(restarted.page[0]).toEqual({ commodityId: "commodity-026", correctionId: "authored-identity-v1-commodity-026" });
    expect(new Set([...first.page, ...restarted.page].map((row) => row.correctionId)).size).toBe(50);
  });

  it("rejects blocking unmapped rows but accepts the three explicitly reversed rulings", () => {
    const value = audit(); value.unmapped.knownWrongStore.push({ store: "Unknown" } as never);
    expect(() => planDefinitionSync(value, { offset: 0, limit: 25, excluded: new Set(["almonds"]) })).toThrow(/complete clean post-foil/);
  });
});
