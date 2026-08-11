import { deterministicId, digestHex, stableJson, verifyBrowserCaptureAccuracy } from "@thriftycrew/domain";
import { gzipSync } from "node:zlib";
import type { CurrentBridgeArtifact } from "./legacy";
import type { NativeReleaseArtifact } from "./native";
import { browserCaptureSessionSchema, type BrowserCaptureSealAttestation, type DirectCaptureArtifact } from "@thriftycrew/contracts";

const encoder = new TextEncoder();

interface MutationClientOptions {
  origin: string;
  agentId: string;
  secret?: string;
  oidcToken?: string;
  oidcTokenProvider?: () => Promise<string>;
  jobRunId?: string;
  leaseFence?: number;
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

type DirectObservation = DirectCaptureArtifact["observations"][number];

export function deduplicateDirectObservations(observations: readonly DirectObservation[]): {
  observations: DirectObservation[];
  duplicatesAvoided: number;
} {
  const unique = new Map<string, { observation: DirectObservation; semantic: string }>();
  for (const observation of observations) {
    const versionIdentity = {
      name: observation.name,
      sizeText: observation.sizeText,
      productUrl: observation.productUrl ?? null,
      imageUrl: observation.imageUrl ?? null,
      taxonomyPath: observation.taxonomyPath ?? null,
      package: observation.package,
      identity: observation.identity ?? null,
    };
    const key = stableJson([observation.externalProductKey, versionIdentity, observation.kind, observation.capturedAt]);
    const semantic = stableJson(observation);
    const prior = unique.get(key);
    if (prior && prior.semantic !== semantic) {
      throw new Error(`conflicting duplicate observation for ${observation.externalProductKey} at ${observation.capturedAt}`);
    }
    if (!prior) unique.set(key, { observation, semantic });
  }
  return { observations: [...unique.values()].map((entry) => entry.observation), duplicatesAvoided: observations.length - unique.size };
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
      if (this.options.jobRunId && this.options.leaseFence) {
        headers.set("x-tc-job-run", this.options.jobRunId);
        headers.set("x-tc-lease-fence", String(this.options.leaseFence));
      }
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

function percentile(values: readonly number[], value: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.max(0, Math.ceil(sorted.length * value) - 1)]!;
}

function centralCycleStart(instant: string): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Chicago", year: "numeric", month: "2-digit", day: "2-digit", weekday: "short",
  }).formatToParts(new Date(instant));
  const values = Object.fromEntries(parts.filter((part) => part.type !== "literal").map((part) => [part.type, part.value]));
  const weekday = ({ Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 } as Record<string, number>)[values.weekday!]!;
  const dateKey = `${values.year}-${values.month}-${values.day}`;
  const [year, month, day] = dateKey.split("-").map(Number);
  return new Date(Date.UTC(year!, month! - 1, day! - ((weekday - 3 + 7) % 7))).toISOString().slice(0, 10);
}

async function buildBrowserEvidenceAttestation(
  artifact: DirectCaptureArtifact,
  evidenceInputs: readonly CaptureEvidenceInput[],
): Promise<BrowserCaptureSealAttestation> {
  const session = browserCaptureSessionSchema.parse(artifact.audit.captureSession);
  if (session.version !== 2) throw new Error("browser evidence attestation requires the current accuracy session contract");
  if (session.sourceId !== artifact.sourceId || session.coverageMode !== artifact.coverageMode
    || session.startedAt !== artifact.capturedFrom || session.finishedAt !== artifact.capturedTo
    || session.expectedTerms !== artifact.expectedTerms) throw new Error("browser session identity does not match the capture artifact");
  const { contentHash, ...sessionContent } = session;
  if (await digestHex(stableJson(sessionContent)) !== contentHash) throw new Error("browser session content hash is not reproducible");
  if (!session.accuracy.pass || !await verifyBrowserCaptureAccuracy(session.store, session.accuracy, session.terms)) {
    throw new Error("browser capture accuracy is incomplete, unresolved, or not reproducible");
  }
  const manifest = evidenceInputs.find((evidence) => evidence.kind === "manifest");
  const raw = evidenceInputs.find((evidence) => evidence.kind === "raw_payload");
  const screenshots = evidenceInputs.filter((evidence) => evidence.kind === "screenshot");
  if (!manifest || !raw || screenshots.length === 0) throw new Error("browser attestation requires manifest, projected raw, and screenshot evidence");
  const manifestSha256 = await digestHex(manifest.body);
  const serializedSessionSha256 = await digestHex(new TextEncoder().encode(JSON.stringify(session)));
  if (manifestSha256 !== serializedSessionSha256) throw new Error("browser manifest evidence differs from the locally verified capture session");
  if (await digestHex(raw.body) !== session.projectedCaptureSha256) throw new Error("browser projected raw evidence differs from the capture session");
  const boundScreenshots = new Set(session.canaries.flatMap((canary) => canary.screenshotSha256 ? [canary.screenshotSha256] : []));
  let screenshotSha256: string | null = null;
  for (const screenshot of screenshots) {
    const hash = await digestHex(screenshot.body);
    if (boundScreenshots.has(hash)) { screenshotSha256 = hash; break; }
  }
  if (!screenshotSha256) throw new Error("browser screenshot evidence is not bound by a capture canary");
  const attempted = session.terms.filter((term) => term.outcome !== "not_attempted");
  const durations = attempted.map((term) => Math.max(0, Date.parse(term.finishedAt) - Date.parse(term.startedAt)));
  return {
    version: 1,
    verifier: "pc-browser-capture-queue",
    verifiedAt: new Date().toISOString(),
    sessionId: session.sessionId,
    sessionVersion: 2,
    sourceId: session.sourceId,
    store: session.store,
    coverageMode: session.coverageMode,
    startedAt: session.startedAt,
    finishedAt: session.finishedAt,
    expectedTerms: session.expectedTerms,
    captureTermsSha256: await digestHex(stableJson(artifact.terms)),
    sessionContentHash: session.contentHash,
    manifestSha256,
    projectedCaptureSha256: session.projectedCaptureSha256,
    screenshotSha256,
    metrics: {
      cycleStart: centralCycleStart(session.finishedAt),
      attemptedTerms: attempted.length,
      successTerms: session.terms.filter((term) => term.outcome === "success").length,
      emptyTerms: session.terms.filter((term) => term.outcome === "empty").length,
      rejectedTerms: session.terms.filter((term) => term.outcome === "rejected").length,
      blockedTerms: session.terms.filter((term) => term.outcome === "blocked").length,
      notAttemptedTerms: session.terms.filter((term) => term.outcome === "not_attempted").length,
      retryCount: attempted.reduce((sum, term) => sum + Math.max(0, term.attempts - 1), 0),
      chunkCount: session.chunks.length,
      durationMs: Math.max(0, Date.parse(session.finishedAt) - Date.parse(session.startedAt)),
      termDurationP50Ms: percentile(durations, 0.5),
      termDurationP95Ms: percentile(durations, 0.95),
      projectedRows: session.terms.reduce((sum, term) => sum + term.rowCount, 0),
      accuracyPolicyVersion: session.accuracy.policyVersion,
      discoveryRows: session.accuracy.discoveryRows.length,
      requiredVerificationRows: session.accuracy.requiredVerificationRows,
      matchedVerificationRows: session.accuracy.matchedVerificationRows,
      unresolvedVerificationRows: session.accuracy.unresolvedVerificationRows,
      priceAgreementRows: session.accuracy.priceAgreementRows,
      singleChannelRows: session.accuracy.singleChannelRows,
      anomalyRows: session.accuracy.anomalyRows,
      retrievalCompleteTerms: session.accuracy.retrievalCompleteTerms,
      pageStateAttestedRows: session.accuracy.pageStateAttestedRows ?? 0,
      promotionSemanticsRows: session.accuracy.promotionSemanticsRows ?? 0,
    },
  };
}

export async function ingestDirectCapture(
  client: MutationClient,
  artifact: DirectCaptureArtifact,
  evidenceBody: Uint8Array,
  additionalEvidence: readonly CaptureEvidenceInput[] = [],
  options: { promote?: boolean } = {},
): Promise<Record<string, unknown>> {
  const deduplicated = deduplicateDirectObservations(artifact.observations);
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
    ...(artifact.sourceSchema ? { sourceSchema: artifact.sourceSchema } : {}),
    idempotencyKey: artifact.idempotencyKey,
  } });
  const batchId = String(created.batchId);
  let status = String(created.status);
  const primary: CaptureEvidenceInput = { body: evidenceBody, kind: artifact.evidence?.kind ?? "raw_payload", contentType: artifact.evidence?.contentType ?? "application/json" };
  const browserRawIndex = artifact.sourceId.endsWith("-browser")
    ? additionalEvidence.findIndex((evidence) => evidence.kind === "raw_payload") : -1;
  // Browser artifacts can be tens of MiB because they contain normalized observations plus the audit.
  // The immutable projected capture is the actual row evidence and is already hash-bound by the session,
  // so do not upload the redundant artifact a second time as evidence.
  const evidenceInputs = browserRawIndex >= 0 ? [...additionalEvidence] : [primary, ...additionalEvidence];
  // The authenticated PC capture agent performs the expensive row-by-row verification locally,
  // then sends a compact request-bound attestation. The Worker independently binds that attestation
  // to the immutable R2 hashes instead of loading a 40-80 MiB manifest into its 128 MiB isolate.
  const browserEvidenceAttestation = browserRawIndex >= 0
    ? await buildBrowserEvidenceAttestation(artifact, evidenceInputs)
    : undefined;
  const evidenceIds: string[] = [];
  for (const evidence of evidenceInputs) evidenceIds.push(`evidence-${batchId}-${(await digestHex(evidence.body)).slice(0, 16)}`);
  const bindingEvidenceIndex = browserRawIndex >= 0 ? evidenceInputs.findIndex((evidence) => evidence.kind === "raw_payload") : 0;
  const evidenceId = evidenceIds[bindingEvidenceIndex]!;
  if (status === "open") {
    for (let index = 0; index < evidenceInputs.length; index += 1) {
      const evidence = evidenceInputs[index]!;
      const compress = evidence.body.byteLength > 8 * 1024 * 1024;
      const uploadBody = compress ? new Uint8Array(gzipSync(evidence.body, { level: 9 })) : evidence.body;
      await client.request(`/internal/capture-batches/${batchId}/evidence`, {
        method: "PUT",
        body: uploadBody,
        headers: {
          "content-type": evidence.contentType,
          ...(compress ? { "content-encoding": "gzip", "x-uncompressed-length": String(evidence.body.byteLength) } : {}),
          "x-evidence-id": evidenceIds[index]!,
          "x-evidence-kind": evidence.kind,
          "x-content-sha256": await digestHex(evidence.body),
        },
      });
    }
    for (const observationChunk of chunks(deduplicated.observations, 100)) {
      await client.request(`/internal/capture-batches/${batchId}/observations`, { json: { observations: observationChunk.map((observation) => ({ ...observation, evidenceObjectId: observation.evidenceObjectId ?? evidenceId })) } });
    }
    const sealed = await client.request(`/internal/capture-batches/${batchId}/seal`, { json: {
      terms: artifact.terms,
      evidenceManifestKey: evidenceId,
      ...(browserEvidenceAttestation ? { browserEvidenceAttestation } : {}),
    }, acceptStatuses: [422] });
    status = String(sealed.status);
    if (status === "rejected") return { ok: false, batchId, status, audit: artifact.audit, seal: sealed };
  }
  if (status === "validated" && options.promote === false) {
    return { ok: true, batchId, status, evidenceId, evidenceIds, observations: deduplicated.observations.length, duplicateObservationsAvoided: deduplicated.duplicatesAvoided, terms: artifact.terms.length, audit: artifact.audit, promotionPending: true };
  }
  if (status === "validated") {
    const promoted = await client.request(`/internal/capture-batches/${batchId}/promote`, { method: "POST" });
    status = String(promoted.status);
  }
  if (status !== "promoted") throw new Error(`direct capture ${batchId} is in unexpected state ${status}`);
  return { ok: true, batchId, status, evidenceId, evidenceIds, observations: deduplicated.observations.length, duplicateObservationsAvoided: deduplicated.duplicatesAvoided, terms: artifact.terms.length, audit: artifact.audit };
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
  const releaseRequest = {
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
  };
  const created = await client.request("/internal/releases", { json: releaseRequest });
  const state = String(created.state);
  if (state === "published") return { ok: true, releaseId: artifact.releaseId, state, idempotent: true, audit: artifact.audit };
  if (state === "rejected") return { ok: false, releaseId: artifact.releaseId, state, idempotent: true, audit: artifact.audit };
  if (state === "validated") {
    const publication = await client.request(`/internal/releases/${artifact.releaseId}/publish`, { method: "POST" });
    return { ok: true, releaseId: artifact.releaseId, state: "published", validation: { ok: true, idempotent: true }, publication, audit: artifact.audit };
  }
  if (state !== "draft") throw new Error(`native release ${artifact.releaseId} is in unexpected state ${state}`);
  try {
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
  } catch (error) {
    // A second executor can observe `draft` just before the first executor
    // publishes. Re-read the deterministic release identity so that completed
    // concurrent publication is idempotent instead of a false failure.
    if (error instanceof Error && error.message.includes("release content is immutable")) {
      const raced = await client.request("/internal/releases", { json: releaseRequest });
      if (String(raced.state) === "published") {
        return { ok: true, releaseId: artifact.releaseId, state: "published", idempotent: true, concurrentPublication: true, audit: artifact.audit };
      }
    }
    throw error;
  }
}
