import { OMAHA_GROCERY_STORE_LOCATION_IDS } from "@thriftycrew/contracts";
import type { MutationClient } from "@thriftycrew/daily/client";

type ClaimedCheck = { id?: unknown; lease_generation?: unknown };
type ClaimResponse = { checks?: ClaimedCheck[] };

const pause = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function drainCatalogLane(client: MutationClient, storeLocationId: string, owner: string, limit: number): Promise<number> {
  const claimed = await client.request("/internal/ingredient-pricing/store-checks/claim", {
    json: { storeLocationId, owner, lane: "catalog", limit, leaseSeconds: 300 },
  }) as ClaimResponse;
  await Promise.all((claimed.checks ?? []).map(async (check) => {
    const id = String(check.id ?? "");
    const leaseGeneration = Number(check.lease_generation);
    if (!id || !Number.isInteger(leaseGeneration) || leaseGeneration < 1) throw new Error("claimed store check omitted its lease fence");
    await client.request(`/internal/ingredient-pricing/store-checks/${encodeURIComponent(id)}/catalog-resolve`, {
      json: { owner, leaseGeneration, leaseSeconds: 300 },
    });
  }));
  return (claimed.checks ?? []).length;
}

export async function runIngredientPipelineTick(client: MutationClient, options: { owner?: string; limitPerStore?: number } = {}) {
  const owner = options.owner ?? `ingredient-coordinator-${process.pid}`;
  const limit = options.limitPerStore ?? 50;
  const claimedEvents = await client.request("/internal/pipeline/outbox/claim", {
    json: { owner, limit: 200, leaseSeconds: 120 },
  }) as { events?: Array<{ id?: unknown; lease_generation?: unknown }> };
  const catalog = await client.request("/internal/ingredient-pricing/catalog/materialize", { method: "POST", retrySafe: true });
  const storeResults = await Promise.all(OMAHA_GROCERY_STORE_LOCATION_IDS.map(async (storeLocationId) => {
    const catalogResolved = await drainCatalogLane(client, storeLocationId, owner, limit);
    return { storeLocationId, catalogResolved };
  }));
  const definitionPlanning = await client.request("/internal/ingredient-pricing/proposals/plan", { method: "POST" });
  await Promise.all((claimedEvents.events ?? []).map((event) => client.request(`/internal/pipeline/outbox/${encodeURIComponent(String(event.id))}/ack`, {
    json: { owner, leaseGeneration: Number(event.lease_generation) },
  })));
  const status = await client.request("/internal/ingredient-pricing/status");
  return { ok: true, catalog, outboxEvents: (claimedEvents.events ?? []).length, stores: storeResults, definitionPlanning, status,
    progressed: (claimedEvents.events ?? []).length > 0 || storeResults.some((row) => row.catalogResolved > 0) || definitionPlanning.queued === true };
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
