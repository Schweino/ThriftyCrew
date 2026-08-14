import { StoreBatchAgent, type StoreBatchStage } from "./store-batch-agent.js";

export interface HeadlessBatchItem { id: string; queries: string[] }
export type HeadlessBatchExecutor = (input: { storeLocationId: string; stage: StoreBatchStage; items: readonly HeadlessBatchItem[]; signal: AbortSignal }) => Promise<{ requests: number }>;

export class HeadlessStoreBatchAgent extends StoreBatchAgent<HeadlessBatchItem> {
  constructor(storeLocationId: string, private readonly executor: HeadlessBatchExecutor) { super(storeLocationId, 50); }
  execute(stage: StoreBatchStage, items: readonly HeadlessBatchItem[], signal: AbortSignal) {
    return this.executor({ storeLocationId: this.storeLocationId, stage, items, signal });
  }
}
