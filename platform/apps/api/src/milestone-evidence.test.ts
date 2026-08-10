import { describe, expect, it } from "vitest";
import { addCalendarDays, browserWeekPass, centralDateKey, consecutiveDateCount, validateExternalEdgeProof, weekStartKey } from "./milestone-evidence";

describe("milestone evidence calendar", () => {
  it("does not count partial browser captures as a completed direct-Chrome week", () => {
    const complete = ["aldi", "fareway", "sams", "walmart"].map(() => ({ coverage_mode: "full", has_screenshot: 1, has_match: 1 }));
    expect(browserWeekPass(complete, 4)).toBe(true);
    expect(browserWeekPass(complete.map((row, index) => index === 0 ? { ...row, coverage_mode: "partial" } : row), 4)).toBe(false);
    expect(browserWeekPass(complete.map((row, index) => index === 0 ? { ...row, has_match: 0 } : row), 4)).toBe(false);
  });
  it("uses Omaha calendar dates instead of UTC dates", () => {
    expect(centralDateKey(new Date("2026-08-10T02:00:00.000Z"))).toBe("2026-08-09");
    expect(centralDateKey(new Date("2026-08-10T15:00:00.000Z"))).toBe("2026-08-10");
  });

  it("finds Monday week boundaries across month changes", () => {
    expect(weekStartKey("2026-08-09")).toBe("2026-08-03");
    expect(weekStartKey("2026-08-10")).toBe("2026-08-10");
    expect(addCalendarDays("2026-08-31", 1)).toBe("2026-09-01");
  });

  it("counts only a consecutive tail and deduplicates retries", () => {
    expect(consecutiveDateCount(["2026-08-06", "2026-08-08", "2026-08-09", "2026-08-08"])).toBe(2);
    expect(consecutiveDateCount(["2026-08-07", "2026-08-08", "2026-08-09"])).toBe(3);
    expect(consecutiveDateCount([])).toBe(0);
  });

  it("accepts only a fresh exact public release proof", () => {
    const now = new Date("2026-08-10T00:00:00.000Z");
    const proof = {
      url: "https://www.thriftycrew.com/api/v2/releases/current?milestone_probe=test",
      httpStatus: 200,
      contentType: "application/json; charset=UTF-8",
      releaseId: "rel_current",
      observedAt: "2026-08-09T23:59:00.000Z",
    };
    expect(validateExternalEdgeProof(proof, "https://www.thriftycrew.com", "rel_current", now).ok).toBe(true);
    expect(validateExternalEdgeProof({ ...proof, url: "https://attacker.example/api/v2/releases/current" }, "https://www.thriftycrew.com", "rel_current", now).ok).toBe(false);
    expect(validateExternalEdgeProof({ ...proof, observedAt: "2026-08-09T22:00:00.000Z" }, "https://www.thriftycrew.com", "rel_current", now).ok).toBe(false);
  });
});
