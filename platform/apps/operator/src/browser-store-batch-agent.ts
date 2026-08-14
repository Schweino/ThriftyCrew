import { StoreAdaptivePacer, StoreBatchAgent, type StoreBatchStage } from "./store-batch-agent.js";

export interface BrowserBatchItem { id: string; queries: string[] }
export type BrowserBatchExecutor = (input: { storeLocationId: string; stage: StoreBatchStage; items: readonly BrowserBatchItem[]; signal: AbortSignal; tabOwner: string }) => Promise<{ requests: number; challengeToken?: string }>;

export class BrowserStoreBatchAgent extends StoreBatchAgent<BrowserBatchItem> {
  readonly tabOwner: string;
  constructor(storeLocationId: string, private readonly executor: BrowserBatchExecutor, readonly pacer: StoreAdaptivePacer) {
    super(storeLocationId, 50); this.tabOwner = `tc-v4-${storeLocationId}-${process.pid}`;
  }
  async execute(stage: StoreBatchStage, items: readonly BrowserBatchItem[], signal: AbortSignal) {
    await this.pacer.acquire(signal);
    const result = await this.executor({ storeLocationId: this.storeLocationId, stage, items, signal, tabOwner: this.tabOwner });
    if (result.challengeToken) { this.pacer.throttle(); throw new Error(`blocked_challenge:${result.challengeToken}`); }
    this.pacer.success(); return result;
  }
}
