import { describe, expect, it } from "vitest";
import { leaseExpiry } from "./orchestration";

describe("unified orchestration policy", () => {
  it("computes a bounded lease expiry", () => {
    expect(leaseExpiry("2026-08-11T12:00:00.000Z", 180)).toBe("2026-08-11T15:00:00.000Z");
  });

  it("rejects leases that can hide a stuck executor indefinitely", () => {
    expect(() => leaseExpiry("2026-08-11T12:00:00.000Z", 0)).toThrow("outside policy");
    expect(() => leaseExpiry("2026-08-11T12:00:00.000Z", 10_081)).toThrow("outside policy");
  });
});
