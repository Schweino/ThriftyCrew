import { describe, expect, it } from "vitest";
import { scheduleDiff, workflowCrons } from "./schedules";

describe("schedule authority", () => {
  it("extracts quoted GitHub schedules", () => {
    expect(workflowCrons("schedule:\n  - cron: '7 12 * * *'\n  - cron: \"17 15 * * 1\"\n")).toEqual(["7 12 * * *", "17 15 * * 1"]);
  });

  it("fails both missing and rogue executor entries", () => {
    expect(scheduleDiff(["7 12 * * *", "17 15 * * 1"], ["7 12 * * *", "0 0 * * *"])).toEqual({ missing: ["17 15 * * 1"], rogue: ["0 0 * * *"] });
  });
});
