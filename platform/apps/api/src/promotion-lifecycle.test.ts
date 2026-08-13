import { describe, expect, it } from "vitest";
import { promotionRequestPlan } from "./promotion-lifecycle";

describe("promotion boundary planning", () => {
  it("creates prefetch, activation, verification, and expiry work from a half-open retailer window", async () => {
    const plan = await promotionRequestPlan({
      store_location_id: "fareway-omaha-043", store_name: "Fareway", capture_lane: "browser",
      current_valid_from: "2026-08-16T05:00:00.000Z", current_valid_to: "2026-08-23T05:00:00.000Z",
    }, "2026-08-15T12:00:00.000Z");
    expect(plan.map((item) => [item.requestKind, item.dueAt])).toEqual([
      ["prefetch", "2026-08-15T23:00:00.000Z"],
      ["activate", "2026-08-16T05:00:00.000Z"],
      ["post_verify", "2026-08-16T06:00:00.000Z"],
      ["expire", "2026-08-23T05:00:00.000Z"],
    ]);
  });

  it("does not manufacture overdue start work for an ad that has been live for days", async () => {
    const plan = await promotionRequestPlan({
      store_location_id: "hy-vee-omaha-1465", store_name: "Hy-Vee", capture_lane: "headless",
      current_valid_from: "2026-08-10T05:00:00.000Z", current_valid_to: "2026-08-17T05:00:00.000Z",
    }, "2026-08-12T12:00:00.000Z");
    expect(plan.map((item) => item.requestKind)).toEqual(["expire"]);
  });
});
