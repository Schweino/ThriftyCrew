import { describe, expect, it } from "vitest";
import { assertIndependentBackfillEvidence, assertLegacyBoard, catalogBackfillPromotionAllowed } from "./catalog-backfill-v4";

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

  it("requires a newer, independently generated verifier session and hash", () => {
    const producer = { documentHash: "a".repeat(64), generationId: "producer-generation", sessionId: "producer-session",
      observedAt: "2026-08-14T20:00:00.000Z" };
    expect(() => assertIndependentBackfillEvidence({ producer, verifier: { documentHash: "b".repeat(64),
      generationId: "verifier-generation", sessionId: "verifier-session", observedAt: "2026-08-14T20:01:00.000Z" } })).not.toThrow();
    expect(() => assertIndependentBackfillEvidence({ producer, verifier: { ...producer, observedAt: "2026-08-14T20:01:00.000Z" } })).toThrow("not independent");
    expect(() => assertIndependentBackfillEvidence({ producer, verifier: { documentHash: "b".repeat(64),
      generationId: "verifier-generation", sessionId: "verifier-session", observedAt: producer.observedAt } })).toThrow("must be newer");
  });
});
