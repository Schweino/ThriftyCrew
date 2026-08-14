export type StoreBatchStage = "producer" | "verifier";
export interface StoreBatchMetrics { storeLocationId: string; stage: StoreBatchStage; startedAt: string; completedAt: string; items: number; requests: number; error: string | null }

export abstract class StoreBatchAgent<T> {
  protected constructor(readonly storeLocationId: string, readonly maximumBatchSize = 50) {}
  abstract execute(stage: StoreBatchStage, items: readonly T[], signal: AbortSignal): Promise<{ requests: number }>;

  async run(stage: StoreBatchStage, items: readonly T[], signal: AbortSignal): Promise<StoreBatchMetrics> {
    if (items.length > this.maximumBatchSize) throw new Error(`store batch exceeds ${this.maximumBatchSize} items`);
    const startedAt = new Date().toISOString();
    try {
      const result = await this.execute(stage, items, signal);
      return { storeLocationId: this.storeLocationId, stage, startedAt, completedAt: new Date().toISOString(), items: items.length, requests: result.requests, error: null };
    } catch (error) {
      return { storeLocationId: this.storeLocationId, stage, startedAt, completedAt: new Date().toISOString(), items: items.length, requests: 0,
        error: error instanceof Error ? error.message : String(error) };
    }
  }
}

export class StoreAdaptivePacer {
  private nextAllowedAt = 0;
  private intervalMs: number;
  constructor(readonly storeLocationId: string, minimumIntervalMs: number, readonly maximumIntervalMs = 60_000) { this.intervalMs = minimumIntervalMs; }
  async acquire(signal: AbortSignal): Promise<void> {
    const delay = Math.max(0, this.nextAllowedAt - Date.now());
    if (delay) await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(resolve, delay);
      signal.addEventListener("abort", () => { clearTimeout(timer); reject(signal.reason); }, { once: true });
    });
    this.nextAllowedAt = Date.now() + this.intervalMs;
  }
  success(): void { this.intervalMs = Math.max(50, Math.floor(this.intervalMs * 0.9)); }
  throttle(retryAfterMs?: number): void { this.intervalMs = Math.min(this.maximumIntervalMs, Math.max(retryAfterMs ?? 0, this.intervalMs * 2)); }
}
