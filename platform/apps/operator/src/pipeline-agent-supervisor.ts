import { EventEmitter } from "node:events";
import type { MutationClient } from "@thriftycrew/daily/client";
import { OMAHA_STORE_LOCATION_IDS } from "@thriftycrew/contracts";
import { runIngredientPipelineTick } from "./ingredient-pipeline.js";

export interface SupervisorStatus { running: boolean; ticks: number; lastProgressAt: string | null; lastTickAt: string | null; activeStoreLanes: string[]; oldestRunnableAgeMs: number; stagesOver30Seconds: string[]; stalled: boolean }

export class PipelineAgentSupervisor extends EventEmitter {
  private running = false; private ticks = 0; private lastProgressAt: string | null = null; private lastTickAt: string | null = null;
  private readonly controller = new AbortController(); private wakeResolver: (() => void) | null = null;
  constructor(private readonly client: MutationClient, private readonly idlePollMs = 5_000) { super(); }
  wake(reason: string): void { this.emit("wake", reason); this.wakeResolver?.(); this.wakeResolver = null; }
  stop(): void { this.running = false; this.controller.abort(); this.wake("stop"); }
  status(): SupervisorStatus { const age = this.lastProgressAt ? Date.now() - Date.parse(this.lastProgressAt) : 0; return {
    running: this.running, ticks: this.ticks, lastProgressAt: this.lastProgressAt, lastTickAt: this.lastTickAt,
    activeStoreLanes: this.running ? [...OMAHA_STORE_LOCATION_IDS] : [], oldestRunnableAgeMs: age,
    stagesOver30Seconds: age > 30_000 ? ["pipeline"] : [], stalled: age > 60_000,
  }; }
  async run(): Promise<void> {
    if (this.running) throw new Error("pipeline supervisor is already running"); this.running = true;
    while (this.running && !this.controller.signal.aborted) {
      const started = Date.now();
      const tick = await runIngredientPipelineTick(this.client, { owner: `v4-supervisor-${process.pid}`, limitPerStore: 50 });
      this.ticks += 1; this.lastTickAt = new Date().toISOString();
      if (tick.progressed) { this.lastProgressAt = this.lastTickAt; this.emit("progress", tick); continue; }
      const elapsed = Date.now() - started;
      await new Promise<void>((resolve) => { const timer = setTimeout(() => { this.wakeResolver = null; resolve(); }, Math.max(50, this.idlePollMs - elapsed));
        this.wakeResolver = () => { clearTimeout(timer); resolve(); }; });
    }
  }
}
