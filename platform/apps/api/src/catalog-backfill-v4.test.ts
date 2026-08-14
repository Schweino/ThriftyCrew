import { describe, expect, it } from "vitest";
import { assertLegacyBoard, catalogBackfillPromotionAllowed } from "./catalog-backfill-v4";

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
});
