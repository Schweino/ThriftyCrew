import { describe, expect, it } from "vitest";
import { runPipelineBenchmark } from "./pipeline-benchmark";

describe("V4 pipeline benchmark", () => {
  it("starts all seven fixture lanes concurrently and reports critical path", async () => {
    const starts: number[] = [];
    const report = await runPipelineBenchmark(30, async () => { starts.push(Date.now()); await Promise.resolve(); return { producerMs: 10, verifierMs: 10, requests: 2 }; }, async () => {});
    expect(starts).toHaveLength(7);
    expect(report.laneStartupSpreadMs).toBeLessThan(5_000);
    expect(report.criticalPathMs).toBeGreaterThanOrEqual(20);
    expect(report.passed).toBe(true);
  });
});
