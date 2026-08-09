import { deterministicId, digestHex, stableJson } from "@thriftycrew/domain";
import type { CurrentBridgeArtifact } from "./legacy";

const encoder = new TextEncoder();

interface MutationClientOptions {
  origin: string;
  agentId: string;
  secret?: string;
  oidcToken?: string;
}

interface ApiResult {
  ok: boolean;
  error?: string;
  [key: string]: unknown;
}

async function hmacHex(secret: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(value));
  return Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function chunks<T>(items: readonly T[], size: number): T[][] {
  const output: T[][] = [];
  for (let offset = 0; offset < items.length; offset += size) output.push(items.slice(offset, offset + size));
  return output;
}

export class MutationClient {
  constructor(private readonly options: MutationClientOptions) {}

  async request(pathname: string, init: { method?: string; json?: unknown; body?: Uint8Array; headers?: HeadersInit; acceptStatuses?: number[] } = {}): Promise<ApiResult> {
    const method = init.method ?? (init.json === undefined && init.body === undefined ? "GET" : "POST");
    const body = init.body ?? (init.json === undefined ? new Uint8Array() : encoder.encode(JSON.stringify(init.json)));
    const timestamp = new Date().toISOString();
    const nonce = `nonce_${crypto.randomUUID()}`;
    const bodyHash = await digestHex(body);
    const url = new URL(pathname, this.options.origin);
    const canonical = [timestamp, nonce, method.toUpperCase(), url.pathname, bodyHash].join("\n");
    const headers = new Headers(init.headers);
    if (init.json !== undefined) headers.set("content-type", "application/json");
    headers.set("x-tc-agent", this.options.agentId);
    headers.set("x-tc-timestamp", timestamp);
    headers.set("x-tc-nonce", nonce);
    if (this.options.oidcToken) headers.set("authorization", `Bearer ${this.options.oidcToken}`);
    else if (this.options.secret) headers.set("x-tc-signature", await hmacHex(this.options.secret, canonical));
    else throw new Error("mutation client requires an HMAC secret or GitHub OIDC token");
    const requestInit: RequestInit = { method, headers };
    if (body.byteLength > 0) requestInit.body = new Blob([Uint8Array.from(body)]);
    const response = await fetch(url, requestInit);
    const result = await response.json() as ApiResult;
    if (!response.ok && !init.acceptStatuses?.includes(response.status)) {
      const detail = typeof result.error === "string" ? result.error : stableJson(result);
      throw new Error(`${method} ${pathname} returned ${response.status}: ${detail}`);
    }
    return { ...result, httpStatus: response.status };
  }
}

function ruleCount(artifact: CurrentBridgeArtifact): number {
  const unique = new Set<string>();
  for (const commodity of artifact.configuration.commodities) {
    for (const pattern of commodity.include) unique.add(`${commodity.id}\u001finclude\u001f${pattern}`);
    for (const pattern of commodity.exclude) unique.add(`${commodity.id}\u001fexclude\u001f${pattern}`);
  }
  return unique.size;
}

function apiBasisUnit(unit: string): string {
  return unit === "floz" ? "fl_oz" : unit === "gallon" ? "gal" : unit;
}

export async function replayCurrentArtifact(client: MutationClient, artifact: CurrentBridgeArtifact): Promise<Record<string, unknown>> {
  const config = artifact.configuration;
  const configuration = await client.request("/internal/configurations", { json: {
    id: config.id,
    sourceCommit: config.sourceCommit,
    contentHash: config.contentHash,
    expectedCategories: config.categories.length,
    expectedCommodities: config.commodities.length,
    expectedRules: ruleCount(artifact),
    expectedKnownWrong: artifact.configuration.knownWrong.length,
  } });
  if (configuration.active !== true) {
    await client.request(`/internal/configurations/${config.id}/categories`, { method: "PUT", json: { categories: config.categories } });
    for (const commodityChunk of chunks(config.commodities, 20)) {
      await client.request(`/internal/configurations/${config.id}/commodities`, { method: "PUT", json: {
        commodities: commodityChunk.map((commodity) => ({
          id: commodity.id,
          label: commodity.label,
          basisUnit: apiBasisUnit(commodity.unit),
          categoryId: commodity.categoryId,
          include: commodity.include,
          exclude: commodity.exclude,
        })),
      } });
    }
    for (const ruleChunk of chunks(config.knownWrong, 75)) {
      await client.request(`/internal/configurations/${config.id}/known-wrong`, { method: "PUT", json: { rules: ruleChunk } });
    }
    await client.request(`/internal/configurations/${config.id}/activate`, { method: "POST" });
  }

  const actualObservationByCell = new Map<string, string>();
  const inputBatchIds: string[] = [];
  for (const store of artifact.stores) {
    const plans = artifact.observations.filter((item) => item.sourceId === store.sourceId);
    const captureInstants = plans.map((plan) => plan.observation.capturedAt).sort();
    const captureManifestHash = await digestHex(stableJson(plans.map((plan) => ({
      commodityId: plan.commodityId,
      sourcePayloadKey: plan.observation.sourcePayloadKey,
      capturedAt: plan.observation.capturedAt,
      perUnitMicros: plan.observation.perUnitMicros,
    }))));
    const created = await client.request("/internal/capture-batches", { json: {
      sourceId: store.sourceId,
      coverageMode: "partial",
      capturedFrom: captureInstants[0],
      capturedTo: captureInstants.at(-1),
      expectedTerms: plans.length,
      marketVerified: true,
      locationVerified: true,
      priceModeVerified: true,
      idempotencyKey: `legacy-v3-${artifact.weekOf}-${store.sourceId}-${captureManifestHash.slice(0, 16)}`,
    } });
    const batchId = String(created.batchId);
    const evidenceId = `evidence-${batchId}-${captureManifestHash.slice(0, 12)}`;
    inputBatchIds.push(batchId);
    for (const plan of plans) {
      const observationId = await deterministicId("obs", batchId, plan.versionId, plan.observation.kind, plan.observation.capturedAt);
      actualObservationByCell.set(`${plan.commodityId}\u001f${plan.storeLocationId}`, observationId);
    }
    if (created.status === "open") {
      for (const planChunk of chunks(plans, 25)) {
        const inserted = await client.request(`/internal/capture-batches/${batchId}/observations`, { json: { observations: planChunk.map((item) => item.observation) } });
        const ids = inserted.ids as string[];
        planChunk.forEach((plan, index) => {
          const expected = actualObservationByCell.get(`${plan.commodityId}\u001f${plan.storeLocationId}`);
          if (ids[index] !== expected) throw new Error(`observation identity mismatch for ${plan.commodityId}/${plan.storeLocationId}`);
        });
      }
      const evidenceBody = encoder.encode(stableJson({
        version: 1,
        sourceId: store.sourceId,
        capturedAt: artifact.capturedAt,
        observations: plans.map((plan) => ({ commodityId: plan.commodityId, observation: plan.observation })),
      }));
      const evidenceHash = await digestHex(evidenceBody);
      await client.request(`/internal/capture-batches/${batchId}/evidence`, {
        method: "PUT",
        body: evidenceBody,
        headers: {
          "content-type": "application/json",
          "x-evidence-id": evidenceId,
          "x-evidence-kind": "raw_payload",
          "x-content-sha256": evidenceHash,
        },
      });
      await client.request(`/internal/capture-batches/${batchId}/seal`, { json: {
        terms: plans.map((plan, ordinal) => ({ termKey: plan.commodityId, ordinal, outcome: "success", rowCount: 1 })),
        evidenceManifestKey: evidenceId,
      } });
      const promoted = await client.request(`/internal/capture-batches/${batchId}/promote`, { method: "POST" });
      if (promoted.status !== "promoted") throw new Error(`legacy batch ${batchId} did not promote`);
    } else if (created.status === "validated") {
      await client.request(`/internal/capture-batches/${batchId}/promote`, { method: "POST" });
    } else if (created.status !== "promoted") {
      throw new Error(`legacy batch ${batchId} is in unexpected state ${String(created.status)}`);
    }
  }

  for (const decisionChunk of chunks(artifact.observations, 75)) {
    await client.request("/internal/match-decisions", { method: "PUT", json: { decisions: decisionChunk.map((plan) => ({
      productId: plan.productId,
      commodityId: plan.commodityId,
      configurationId: config.id,
      decidedBy: "legacy_bridge",
      reason: "Imported from the guarded legacy published board",
    })) } });
  }

  const inputManifest = {
    kind: "legacy-current-bridge",
    weekOf: artifact.weekOf,
    configurationHash: config.contentHash,
    observationCount: artifact.observations.length,
    recipeCount: artifact.recipeCosts.length,
  };
  inputBatchIds.sort();
  const inputHash = await digestHex(stableJson({ inputManifest, inputBatchIds }));
  const releaseId = `rel_${inputHash.slice(0, 24)}`;
  const releaseCreated = await client.request("/internal/releases", { json: {
    id: releaseId,
    marketId: artifact.marketId,
    configurationId: config.id,
    inputManifest,
    inputBatchIds,
    inputHash,
    summary: {
      expectedCommodities: config.commodities.length,
      expectedStores: artifact.stores.length,
      expectedRecipes: artifact.recipeCosts.length,
      expectedFreeRotation: artifact.top5.length,
    },
  } });
  const existingState = String(releaseCreated.state);
  if (existingState === "published") {
    return { releaseId, inputHash, actualObservationCount: actualObservationByCell.size, validation: { ok: true, state: "published", idempotent: true }, publication: { ok: true, state: "published", idempotent: true } };
  }
  if (existingState === "rejected") {
    return { releaseId, inputHash, actualObservationCount: actualObservationByCell.size, validation: { ok: false, state: "rejected", idempotent: true }, publication: null };
  }
  if (existingState === "validated") {
    const publication = await client.request(`/internal/releases/${releaseId}/publish`, { method: "POST" });
    return { releaseId, inputHash, actualObservationCount: actualObservationByCell.size, validation: { ok: true, state: "validated", idempotent: true }, publication };
  }
  if (existingState !== "draft") throw new Error(`release ${releaseId} is in unexpected state ${existingState}`);
  const cells = artifact.cells.map((cell) => {
    const actualId = actualObservationByCell.get(`${cell.commodityId}\u001f${cell.storeLocationId}`);
    return actualId ? { ...cell, observationId: actualId } : cell;
  });
  for (const cellChunk of chunks(cells, 200)) await client.request(`/internal/releases/${releaseId}/cells`, { method: "PUT", json: { cells: cellChunk } });
  for (const costChunk of chunks(artifact.recipeCosts, 200)) await client.request(`/internal/releases/${releaseId}/recipe-costs`, { method: "PUT", json: { costs: costChunk } });
  await client.request(`/internal/releases/${releaseId}/free-rotation`, { method: "PUT", json: { entries: artifact.freeRotation } });
  await client.request(`/internal/releases/${releaseId}/top5`, { method: "PUT", json: { entries: artifact.top5 } });
  for (const [kind, payload] of Object.entries(artifact.payloads)) {
    const wirePayload: unknown = JSON.parse(JSON.stringify(payload));
    await client.request(`/internal/releases/${releaseId}/payload`, { method: "PUT", json: { kind, payload: wirePayload, contentHash: await digestHex(stableJson(wirePayload)) } });
  }
  const validation = await client.request(`/internal/releases/${releaseId}/validate`, { method: "POST", acceptStatuses: [422] });
  const publication = validation.ok
    ? await client.request(`/internal/releases/${releaseId}/publish`, { method: "POST" })
    : null;
  return { releaseId, inputHash, actualObservationCount: actualObservationByCell.size, validation, publication };
}
