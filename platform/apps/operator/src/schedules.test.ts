import { describe, expect, it } from "vitest";
import { automaticWorkflowTriggers, scheduleDiff, workflowCrons } from "./schedules";

describe("schedule authority", () => {
  it("extracts quoted GitHub schedules", () => {
    expect(workflowCrons("schedule:\n  - cron: '7 12 * * *'\n  - cron: \"17 15 * * 1\"\n")).toEqual(["7 12 * * *", "17 15 * * 1"]);
  });

  it("fails both missing and rogue executor entries", () => {
    expect(scheduleDiff(["7 12 * * *", "17 15 * * 1"], ["7 12 * * *", "0 0 * * *"])).toEqual({ missing: ["17 15 * * 1"], rogue: ["0 0 * * *"] });
  });

  it("rejects hosted-runner triggers while allowing manual and reusable workflows", () => {
    expect(automaticWorkflowTriggers("on:\n  push:\n  workflow_dispatch:\n  schedule:\n    - cron: '0 0 * * *'\n")).toEqual(["push", "schedule"]);
    expect(automaticWorkflowTriggers("on: { workflow_dispatch: {} }\n")).toEqual([]);
    expect(automaticWorkflowTriggers("on:\n  workflow_call:\n")).toEqual([]);
  });
});
