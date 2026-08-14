import { performance } from "node:perf_hooks";
import { OMAHA_STORE_LOCATION_IDS } from "@thriftycrew/contracts";

export interface BenchmarkStage { storeLocationId: string; producerMs: number; verifierMs: number; requests: number }
export interface PipelineBenchmarkReport { fixtureSize: number; totalDurationMs: number; laneStartupSpreadMs: number; criticalPathMs: number; publicationMs: number; stores: BenchmarkStage[]; passed: boolean; budgets: { totalMs: number; startupSpreadMs: number; publicationMs: number } }

export async function runPipelineBenchmark(fixtureSize: 1 | 10 | 30 | 50, execute: (storeLocationId: string, count: number) => Promise<Omit<BenchmarkStage, "storeLocationId">>, publish: () => Promise<void>): Promise<PipelineBenchmarkReport> {
  const began = performance.now(); const starts: number[] = [];
  const stores = await Promise.all(OMAHA_STORE_LOCATION_IDS.map(async (storeLocationId) => { starts.push(performance.now()); return { storeLocationId, ...await execute(storeLocationId, fixtureSize) }; }));
  const publicationStarted = performance.now(); await publish(); const publicationMs = performance.now() - publicationStarted;
  const totalDurationMs = performance.now() - began; const laneStartupSpreadMs = Math.max(...starts) - Math.min(...starts);
  const totalBudget = fixtureSize === 1 ? 120_000 : fixtureSize <= 30 ? 300_000 : 420_000;
  const criticalPathMs = Math.max(...stores.map((store) => store.producerMs + store.verifierMs)) + publicationMs;
  const budgets = { totalMs: totalBudget, startupSpreadMs: 5_000, publicationMs: 10_000 };
  return { fixtureSize, totalDurationMs, laneStartupSpreadMs, criticalPathMs, publicationMs, stores, budgets,
    passed: totalDurationMs <= budgets.totalMs && laneStartupSpreadMs <= budgets.startupSpreadMs && publicationMs <= budgets.publicationMs };
}
