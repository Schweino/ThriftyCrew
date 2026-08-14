import { OMAHA_GROCERY_STORE_LOCATION_IDS } from "@thriftycrew/contracts";
import type { MutationClient } from "@thriftycrew/daily/client";
import { readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { captureHeadlessDiscovery, captureHeadlessVerification, claimSearchTerms, type HeadlessStore } from "./headless-targeted-capture";
import { buildIngredientCapturePayload, buildIngredientQaPayload, type AdapterChunk, type ClaimedCheck } from "./ingredient-targeted-capture";

type ClaimResponse = { checks?: ClaimedCheck[] };

const HEADLESS_STORES: Partial<Record<string, HeadlessStore>> = {
  "bakers-saddle-creek": "bakers",
  "family-fare-omaha-6401": "family-fare",
  "hy-vee-omaha-1465": "hy-vee",
};
const KROGER_CREDENTIALS_FILE = path.resolve(import.meta.dirname, "../../../..", "grocery", ".krogerkey");

const pause = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function drainCatalogLane(client: MutationClient, storeLocationId: string, owner: string, limit: number): Promise<number> {
  const claimed = await client.request("/internal/ingredient-pricing/store-checks/claim", {
    json: { storeLocationId, owner, lane: "catalog", limit, leaseSeconds: 300 },
  }) as ClaimResponse;
  await Promise.all((claimed.checks ?? []).map(async (check) => {
    const id = String(check.id);
    const leaseGeneration = Number(check.lease_generation);
    if (!id || !Number.isInteger(leaseGeneration) || leaseGeneration < 1) throw new Error("claimed store check omitted its lease fence");
    await client.request(`/internal/ingredient-pricing/store-checks/${encodeURIComponent(id)}/catalog-resolve`, {
      json: { owner, leaseGeneration, leaseSeconds: 300 },
    });
  }));
  return (claimed.checks ?? []).length;
}

async function uploadEvidence(client: MutationClient, check: ClaimedCheck, kind: "producer" | "verifier", chunk: AdapterChunk) {
  const claim = { checkId: check.id, queryPlanHash: check.query_plan_hash };
  const response = await client.request("/internal/ingredient-pricing/evidence", { json: {
    checkId: check.id, kind, sourceUrl: chunk.canary.evidenceUrl, observedAt: chunk.canary.observedAt,
    document: kind === "producer" ? { claim, chunks: [chunk] } : { claim, verification: chunk },
  } }) as { evidence?: unknown };
  if (!response.evidence) throw new Error(`evidence upload omitted its immutable pointer for ${check.id}`);
  return response.evidence as Parameters<typeof buildIngredientCapturePayload>[2];
}

async function failClaimedChecks(client: MutationClient, checks: ClaimedCheck[], reason: unknown): Promise<void> {
  const message = String(reason instanceof Error ? reason.message : reason);
  // Freshop reports throttling as either HTTP 429 or HTTP 400 with
  // {"error_code":429}. Give the shared retailer quota time to recover
  // instead of allowing the event loop to amplify the refusal every minute.
  const retryDelay = /source throttled/i.test(message) ? 5 * 60_000 : 60_000;
  const retryAt = new Date(Date.now() + retryDelay).toISOString();
  await Promise.allSettled(checks.map((check) => client.request(`/internal/ingredient-pricing/store-checks/${encodeURIComponent(check.id)}/fail`, { json: {
    owner: check.lease_owner, leaseGeneration: Number(check.lease_generation), failureClass: "transient",
    reason: message.slice(0, 5000), challengeId: null, retryAt,
  } })));
}

async function drainHeadlessCaptureLane(client: MutationClient, storeLocationId: string, adapter: HeadlessStore, owner: string, limit: number): Promise<number> {
  const claimed = await client.request("/internal/ingredient-pricing/store-checks/claim", {
    json: { storeLocationId, owner, lane: "targeted_refresh", limit: Math.min(15, limit), leaseSeconds: 900 },
  }) as ClaimResponse;
  const checks = claimed.checks ?? [];
  if (checks.length === 0) return 0;
  const file = path.join(os.tmpdir(), `tc-ingredient-${adapter}-capture-${process.pid}-${Date.now()}.json`);
  try {
    const terms = claimSearchTerms(checks);
    const chunk = await captureHeadlessDiscovery(adapter, terms, file, { krogerCredentialsFile: KROGER_CREDENTIALS_FILE });
    for (const check of checks) {
      const evidence = await uploadEvidence(client, check, "producer", chunk);
      const payload = await buildIngredientCapturePayload(check, [chunk], evidence);
      await client.request(`/internal/ingredient-pricing/store-checks/${encodeURIComponent(check.id)}/capture-result`, { json: payload });
    }
    return checks.length;
  } catch (error) {
    await failClaimedChecks(client, checks, error);
    return 0;
  } finally {
    await rm(file, { force: true }).catch(() => undefined);
  }
}

async function drainHeadlessQaLane(client: MutationClient, storeLocationId: string, adapter: HeadlessStore, owner: string, limit: number): Promise<number> {
  const claimed = await client.request("/internal/ingredient-pricing/store-checks/claim", {
    json: { storeLocationId, owner, lane: "qa", limit: Math.min(15, limit), leaseSeconds: 900 },
  }) as ClaimResponse;
  const checks = claimed.checks ?? [];
  if (checks.length === 0) return 0;
  const file = path.join(os.tmpdir(), `tc-ingredient-${adapter}-qa-${process.pid}-${Date.now()}.json`);
  const discoveryFile = `${file}.discovery.json`;
  try {
    const verification = await captureHeadlessVerification(adapter, checks, file, { krogerCredentialsFile: KROGER_CREDENTIALS_FILE });
    const discovery = JSON.parse(await readFile(discoveryFile, "utf8")) as AdapterChunk;
    for (const check of checks) {
      const captured = JSON.parse(String(check.capture_result_json ?? "null")) as { outcome?: string } | null;
      const chunk = captured?.outcome === "priced" ? verification : discovery;
      const evidence = await uploadEvidence(client, check, "verifier", chunk);
      const payload = buildIngredientQaPayload(check, chunk, evidence as Parameters<typeof buildIngredientQaPayload>[2]);
      await client.request(`/internal/ingredient-pricing/store-checks/${encodeURIComponent(check.id)}/qa-complete`, { json: payload });
    }
    return checks.length;
  } catch (error) {
    await failClaimedChecks(client, checks, error);
    return 0;
  } finally {
    await Promise.all([rm(file, { force: true }), rm(discoveryFile, { force: true })]).catch(() => undefined);
  }
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
    const adapter = HEADLESS_STORES[storeLocationId];
    const captured = adapter ? await drainHeadlessCaptureLane(client, storeLocationId, adapter, owner, limit) : 0;
    const qaCompleted = adapter ? await drainHeadlessQaLane(client, storeLocationId, adapter, `${owner}-qa`, limit) : 0;
    return { storeLocationId, catalogResolved, captured, qaCompleted };
  }));
  const definitionPlanning = await client.request("/internal/ingredient-pricing/proposals/plan", { method: "POST" });
  await Promise.all((claimedEvents.events ?? []).map((event) => client.request(`/internal/pipeline/outbox/${encodeURIComponent(String(event.id))}/ack`, {
    json: { owner, leaseGeneration: Number(event.lease_generation) },
  })));
  const status = await client.request("/internal/ingredient-pricing/status");
  return { ok: true, catalog, outboxEvents: (claimedEvents.events ?? []).length, stores: storeResults, definitionPlanning, status,
    progressed: (claimedEvents.events ?? []).length > 0 || storeResults.some((row) => row.catalogResolved > 0 || row.captured > 0 || row.qaCompleted > 0) || definitionPlanning.queued === true };
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
