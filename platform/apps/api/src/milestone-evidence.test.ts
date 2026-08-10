import { describe, expect, it } from "vitest";
import { addCalendarDays, centralDateKey, consecutiveDateCount, weekStartKey } from "./milestone-evidence";

describe("milestone evidence calendar", () => {
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
});
