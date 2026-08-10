import { describe, expect, it } from "vitest";
import { assessBrowserCaptureSla, browserCaptureCycleWindow, REQUIRED_BROWSER_CAPTURE_SOURCES } from "./browser-capture-sla";

function completeRows() {
  return REQUIRED_BROWSER_CAPTURE_SOURCES.map((sourceId) => ({
    source_id: sourceId,
    batch_id: `batch_${sourceId}`,
    captured_to: "2026-08-12T12:00:00.000Z",
    coverage_mode: "full",
    status: "promoted",
    has_screenshot: 1,
    has_manifest: 1,
    has_raw_payload: 1,
    has_match: 1,
  }));
}

describe("browser capture SLA", () => {
  it("uses a Wednesday-through-Tuesday Omaha cycle and a Saturday noon deadline", () => {
    expect(browserCaptureCycleWindow(new Date("2026-08-15T16:59:00.000Z"))).toMatchObject({
      cycleStart: "2026-08-12", cycleEnd: "2026-08-18", enforced: true, deadlineExpired: false,
    });
    expect(browserCaptureCycleWindow(new Date("2026-08-15T17:00:00.000Z"))).toMatchObject({
      cycleStart: "2026-08-12", cycleEnd: "2026-08-18", enforced: true, deadlineExpired: true,
    });
    expect(browserCaptureCycleWindow(new Date("2026-08-10T16:00:00.000Z")).enforced).toBe(false);
  });

  it("requires all four strict remote truth components", () => {
    const now = new Date("2026-08-15T18:00:00.000Z");
    expect(assessBrowserCaptureSla(completeRows(), now)).toMatchObject({ ready: true, deadlineExpired: true, missing: [] });
    const partial = completeRows();
    partial[0] = { ...partial[0]!, coverage_mode: "partial", has_manifest: 0 };
    const assessment = assessBrowserCaptureSla(partial, now);
    expect(assessment.ready).toBe(false);
    expect(assessment.missing[0]).toMatchObject({ sourceId: "direct-aldi-browser" });
    expect(assessment.missing[0]?.reasons).toEqual(["coverage is partial", "session manifest missing"]);
  });

  it("reports an entirely absent store instead of silently accepting three", () => {
    const assessment = assessBrowserCaptureSla(completeRows().slice(1), new Date("2026-08-15T18:00:00.000Z"));
    expect(assessment.ready).toBe(false);
    expect(assessment.missing[0]).toEqual({ sourceId: "direct-aldi-browser", reasons: ["no capture batch in cycle"] });
  });
});
