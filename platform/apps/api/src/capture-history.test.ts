import { describe, expect, it } from "vitest";
import { requiresCaptureHistoryAssessment } from "./capture-history";

describe("capture history assessment scope", () => {
  it("never expands legacy replay into an unnecessary historical product scan", () => {
    expect(requiresCaptureHistoryAssessment("legacy_bridge", "2026-08-12T16:00:00.000Z")).toBe(false);
    expect(requiresCaptureHistoryAssessment("browser", "2026-08-12T16:00:00.000Z")).toBe(true);
  });
});
