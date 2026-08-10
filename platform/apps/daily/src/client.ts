import { deterministicId, digestHex, stableJson } from "@thriftycrew/domain";
import type { CurrentBridgeArtifact } from "./legacy";
import type { NativeReleaseArtifact } from "./native";
import type { DirectCaptureArtifact } from "@thriftycrew/contracts";

const encoder = new TextEncoder();

interface MutationClientOptions {
  origin: string;
  agentId: string;
  secret?: string;
  oidcToken?: string;
  oidcTokenProvider?: () => Promise<string>;
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
  private cachedOidcToken: string | undefined;
  private oidcExpiresAt = 0;

  constructor(private readonly options: MutationClientOptions) {
    this.cachedOidcToken = options.oidcToken;
    this.oidcExpiresAt = options.oidcToken ? oidcExpiry(options.oidcToken) : 0;
  }

  private async authorizationToken(forceRefresh = false): Promise<string | undefined> {
    if (this.options.oidcTokenProvider && (forceRefresh || !this.cachedOidcToken || Date.now() >= this.oidcExpiresAt - 60_000)) {
      this.cachedOidcToken = await this.options.oidcTokenProvider();
      this.oidcExpiresAt = oidcExpiry(this.cachedOidcToken);
    }
    return this.cachedOidcToken;
  }

  async request(pathname: string, init: { method?: string; json?: unknown; body?: Uint8Array; headers?: HeadersInit; acceptStatuses?: number[] } = {}): Promise<ApiResult> {
    const method = init.method ?? (init.json === undefined && init.body === undefined ? "GET" : "POST");
    const body = init.body ?? (init.json === undefined ? new Uint8Array() : encoder.encode(JSON.stringify(init.json)));
    const bodyHash = await digestHex(body);
    const url = new URL(pathname, this.options.origin);
    const send = async (forceOidcRefresh = false): Promise<{ response: Response; result: ApiResult }> => {
      const timestamp = new Date().toISOString();
      const nonce = `nonce_${crypto.randomUUID()}`;
      const canonical = [timestamp, nonce, method.toUpperCase(), url.pathname, bodyHash].join("\n");
      const headers = new Headers(init.headers);
      if (init.json !== undefined) headers.set("content-type", "application/json");
      headers.set("x-tc-agent", this.options.agentId);
      headers.set("x-tc-timestamp", timestamp);
      headers.set("x-tc-nonce", nonce);
      const oidcToken = await this.authorizationToken(forceOidcRefresh);
      if (oidcToken) headers.set("authorization", `Bearer ${oidcToken}`);
      else if (this.options.secret) headers.set("x-tc-signature", await hmacHex(this.options.secret, canonical));
      else throw new Error("mutation client requires an HMAC secret or GitHub OIDC token");
      const requestInit: RequestInit = { method, headers };
      if (body.byteLength > 0) requestInit.body = new Blob([Uint8Array.from(body)]);
      const response = await fetch(url, requestInit);
      const responseText = await response.text();
      let result: ApiResult;
      try {
        result = responseText ? JSON.parse(responseText) as ApiResult : { ok: false, error: `empty response from ${url.hostname}` };
      } catch {
        result = { ok: false, error: `non-JSON response from ${url.hostname}: ${responseText.slice(0, 500)}` };
      }
      return { response, result };
    };
    let { response, result } = await send();
    // Authentication rejects an expired bearer before the route handler, so
    // rebuilding the envelope and retrying the unchanged body once cannot
    // duplicate a successful mutation.
    if (response.status === 401 && result.error === "GitHub OIDC token is expired" && this.options.oidcTokenProvider) {
      ({ response, result } = await send(true));
    }
    if (!response.ok && !init.acceptStatuses?.includes(response.status)) {
      const detail = typeof result.error === "string" ? result.error : stableJson(result);
      throw new Error(`${method} ${pathname} returned ${response.status}: ${detail}`);
    }
    return { ...result, httpStatus: response.status };
  }
}

function oidcExpiry(token: string): number {
  try {
    const payload = token.split(".")[1];
    if (!payload) return 0;
    const parsed = JSON.parse(Buffer.from(payload, "base64url").toString("utf8")) as { exp?: unknown };
    return typeof parsed.exp === "number" && Number.isFinite(parsed.exp) ? parsed.exp * 1_000 : 0;
  } catch {
    return 0;
  }
}

export interface CaptureEvidenceInput { body: Uint8Array; kind: "screenshot" | "flyer_page" | "raw_payload" | "manifest"; contentType: string }

export async function ingestDirectCapture(
  client: MutationClient,
  artifact: DirectCaptureArtifact,
  evidenceBody: Uint8Array,
  additionalEvidence: readonly CaptureEvidenceInput[] = [],
  options: { promote?: boolean } = {},
): Promise<Record<string, unknown>> {
  const created = await client.request("/internal/capture-batches", { json: {
    sourceId: artifact.sourceId,
    coverageMode: artifact.coverageMode,
    capturedFrom: artifact.capturedFrom,
    capturedTo: artifact.capturedTo,
    ...(artifact.validFrom ? { validFrom: artifact.validFrom } : {}),
    ...(artifact.validTo ? { validTo: artifact.validTo } : {}),
    ...(artifact.expectedTerms !== undefined ? { expectedTerms: artifact.expectedTerms } : {}),
    ...(artifact.expectedPages !== undefined ? { expectedPages: artifact.expectedPages } : {}),
    marketVerified: artifact.marketVerified,
    locationVerified: artifact.locationVerified,
    priceModeVerified: artifact.priceModeVerified,
    priceMode: artifact.priceMode,
    idempotencyKey: artifact.idempotencyKey,
  } });
  const batchId = String(created.batchId);
  let status = String(created.status);
  const primary: CaptureEvidenceInput = { body: evidenceBody, kind: artifact.evidence?.kind ?? "raw_payload", contentType: artifact.evidence?.contentType ?? "application/json" };
  const evidenceInputs = [primary, ...additionalEvidence];
  const evidenceIds: string[] = [];
  for (const evidence of evidenceInputs) evidenceIds.push(`evidence-${batchId}-${(await digestHex(evidence.body)).slice(0, 16)}`);
  const evidenceId = evidenceIds[0]!;
  if (status === "open") {
    for (let index = 0; index < evidenceInputs.length; index += 1) {
      const evidence = evidenceInputs[index]!;
      await client.request(`/internal/capture-batches/${batchId}/evidence`, {
        method: "PUT",
        body: evidence.body,
        headers: {
          "content-type": evidence.contentType,
          "x-evidence-id": evidenceIds[index]!,
          "x-evidence-kind": evidence.kind,
          "x-content-sha256": await digestHex(evidence.body),
        },
      });
    }
    for (const observationChunk of chunks(artifact.observations, 50)) {
      await client.request(`/internal/capture-batches/${batchId}/observations`, { json: { observations: observationChunk.map((observation) => ({ ...observation, evidenceObjectId: observation.evidenceObjectId ?? evidenceId })) } });
    }
    const sealed = await client.request(`/internal/capture-batches/${batchId}/seal`, { json: { terms: artifact.terms, evidenceManifestKey: evidenceId }, acceptStatuses: [422] });
    status = String(sealed.status);
    if (status === "rejected") return { ok: false, batchId, status, audit: artifact.audit, seal: sealed };
  }
  if (status === "validated" && options.promote === false) {
    return { ok: true, batchId, status, evidenceId, evidenceIds, observations: artifact.observations.length, terms: artifact.terms.length, audit: artifact.audit, promotionPending: true };
  }
  if (status === "validated") {
    const promoted = await client.request(`/internal/capture-batches/${batchId}/promote`, { method: "POST" });
    status = String(promoted.status);
  }
  if (status !== "promoted") throw new Error(`direct capture ${batchId} is in unexpected state ${status}`);
  return { ok: true, batchId, status, evidenceId, evidenceIds, observations: artifact.observations.length, terms: artifact.terms.length, audit: artifact.audit };
}

function configurationRuleCount(config: CurrentBridgeArtifact["configuration"]): number {
  const unique = new Set<string>();
  for (const commodity of config.commodities) {
    for (const pattern of commodity.include) unique.add(`${commodity.id}\u001finclude\u001f${pattern}`);
    for (const pattern of commodity.exclude) unique.add(`${commodity.id}\u001fexclude\u001f${pattern}`);
  }
  return unique.size;
}

function apiBasisUnit(unit: string): string {
  return unit === "floz" ? "fl_oz" : unit === "gallon" ? "gal" : unit;
}

export async function deployConfiguration(client: MutationClient, config: CurrentBridgeArtifact["configuration"]): Promise<Record<string, unknown>> {
  const configuration = await client.request("/internal/configurations", { json: {
    id: config.id,
    sourceCommit: config.sourceCommit,
    contentHash: config.contentHash,
    expectedCategories: config.categories.length,
    expectedCommodities: config.commodities.length,
    expectedRules: configurationRuleCount(config),
    expectedKnownWrong: config.knownWrong.length,
  } });
  let activation: Record<string, unknown> | null = null;
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
          ...(commodity.band_min !== undefined ? { bandMinMicros: Math.round(commodity.band_min * 1_000_000) } : {}),
          ...(commodity.band_max !== undefined ? { bandMaxMicros: Math.round(commodity.band_max * 1_000_000) } : {}),
        })),
      } });
    }
    for (const [index, ruleChunk] of chunks(config.knownWrong, 75).entries()) {
      await client.request(`/internal/configurations/${config.id}/known-wrong${index === 0 ? "?replace=1" : ""}`, { method: "PUT", json: { rules: ruleChunk } });
    }
    activation = await client.request(`/internal/configurations/${config.id}/activate`, { method: "POST" });
  }
  return {
    ok: true,
    configurationId: config.id,
    active: true,
    idempotent: configuration.active === true,
    activation,
  };
}

export async function replayCurrentArtifact(client: MutationClient, artifact: CurrentBridgeArtifact): Promise<Record<string, unknown>> {
  const config = artifact.configuration;
  await deployConfiguration(client, config);

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

export async function publishNativeRelease(client: MutationClient, artifact: NativeReleaseArtifact): Promise<Record<string, unknown>> {
  const created = await client.request("/internal/releases", { json: {
    id: artifact.releaseId,
    marketId: artifact.marketId,
    configurationId: artifact.configurationId,
    inputManifest: artifact.inputManifest,
    inputBatchIds: artifact.inputBatchIds,
    inputHash: artifact.inputHash,
    summary: {
      expectedCommodities: Number(artifact.audit.commodities),
      expectedStores: Number(artifact.audit.stores),
      expectedRecipes: artifact.recipeCosts.length,
      expectedFreeRotation: artifact.freeRotation.length,
    },
  } });
  const state = String(created.state);
  if (state === "published") return { ok: true, releaseId: artifact.releaseId, state, idempotent: true, audit: artifact.audit };
  if (state === "rejected") return { ok: false, releaseId: artifact.releaseId, state, idempotent: true, audit: artifact.audit };
  if (state === "validated") {
    const publication = await client.request(`/internal/releases/${artifact.releaseId}/publish`, { method: "POST" });
    return { ok: true, releaseId: artifact.releaseId, state: "published", validation: { ok: true, idempotent: true }, publication, audit: artifact.audit };
  }
  if (state !== "draft") throw new Error(`native release ${artifact.releaseId} is in unexpected state ${state}`);
  for (const cellChunk of chunks(artifact.cells, 200)) await client.request(`/internal/releases/${artifact.releaseId}/cells`, { method: "PUT", json: { cells: cellChunk } });
  for (const costChunk of chunks(artifact.recipeCosts, 200)) await client.request(`/internal/releases/${artifact.releaseId}/recipe-costs`, { method: "PUT", json: { costs: costChunk } });
  await client.request(`/internal/releases/${artifact.releaseId}/free-rotation`, { method: "PUT", json: { entries: artifact.freeRotation } });
  await client.request(`/internal/releases/${artifact.releaseId}/top5`, { method: "PUT", json: { entries: artifact.top5 } });
  for (const [kind, payload] of Object.entries(artifact.payloads)) {
    const wirePayload: unknown = JSON.parse(JSON.stringify(payload));
    await client.request(`/internal/releases/${artifact.releaseId}/payload`, { method: "PUT", json: { kind, payload: wirePayload, contentHash: await digestHex(stableJson(wirePayload)) } });
  }
  const validation = await client.request(`/internal/releases/${artifact.releaseId}/validate`, { method: "POST", acceptStatuses: [422] });
  const publication = validation.ok ? await client.request(`/internal/releases/${artifact.releaseId}/publish`, { method: "POST" }) : null;
  return { ok: Boolean(validation.ok && publication?.ok), releaseId: artifact.releaseId, inputHash: artifact.inputHash, validation, publication, audit: artifact.audit };
}
