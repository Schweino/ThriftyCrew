import { OMAHA_GROCERY_STORE_LOCATION_IDS } from "@thriftycrew/contracts";
import type { MutationClient } from "@thriftycrew/daily/client";

type ClaimedCheck = { id?: unknown; lease_generation?: unknown };
type ClaimResponse = { checks?: ClaimedCheck[] };

const pause = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function drainLane(client: MutationClient, storeLocationId: string, lane: "catalog" | "qa", owner: string, limit: number): Promise<number> {
  const claimed = await client.request("/internal/ingredient-pricing/store-checks/claim", {
    json: { storeLocationId, owner, lane, limit, leaseSeconds: 300 },
  }) as ClaimResponse;
  let completed = 0;
  for (const check of claimed.checks ?? []) {
    const id = String(check.id ?? "");
    const leaseGeneration = Number(check.lease_generation);
    if (!id || !Number.isInteger(leaseGeneration) || leaseGeneration < 1) throw new Error("claimed store check omitted its lease fence");
    const path = lane === "catalog" ? "catalog-resolve" : "catalog-qa";
    await client.request(`/internal/ingredient-pricing/store-checks/${encodeURIComponent(id)}/${path}`, {
      json: { owner, leaseGeneration, leaseSeconds: 300 },
    });
    completed += 1;
  }
  return completed;
}

export async function runIngredientPipelineTick(client: MutationClient, options: { owner?: string; limitPerStore?: number } = {}) {
  const owner = options.owner ?? `ingredient-coordinator-${process.pid}`;
  const limit = options.limitPerStore ?? 50;
  const catalog = await client.request("/internal/ingredient-pricing/catalog/materialize", { method: "POST", retrySafe: true });
  const storeResults = await Promise.all(OMAHA_GROCERY_STORE_LOCATION_IDS.map(async (storeLocationId) => {
    const catalogResolved = await drainLane(client, storeLocationId, "catalog", owner, limit);
    const qaCompleted = await drainLane(client, storeLocationId, "qa", owner, limit);
    return { storeLocationId, catalogResolved, qaCompleted };
  }));
  const definitionPlanning = await client.request("/internal/ingredient-pricing/proposals/plan", { method: "POST" });
  const status = await client.request("/internal/ingredient-pricing/status");
  return { ok: true, catalog, stores: storeResults, definitionPlanning, status,
    progressed: storeResults.some((row) => row.catalogResolved + row.qaCompleted > 0) || definitionPlanning.queued === true };
}

export async function runIngredientPipeline(client: MutationClient, options: { owner?: string; limitPerStore?: number; once?: boolean } = {}) {
  let idleDelay = 1_000;
  let ticks = 0;
  for (;;) {
    const tick = await runIngredientPipelineTick(client, options);
    ticks += 1;
    if (options.once) return { ...tick, ticks };
    if (tick.progressed) { idleDelay = 1_000; continue; }
    await pause(idleDelay);
    idleDelay = Math.min(15_000, idleDelay * 2);
  }
}
