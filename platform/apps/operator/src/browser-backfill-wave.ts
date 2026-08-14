import { mkdir, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { createHash } from "node:crypto";

export const BROWSER_BACKFILL_STORES = ["aldi", "fareway", "sams", "walmart"] as const;
export type BrowserBackfillStore = typeof BROWSER_BACKFILL_STORES[number];
export type BrowserBackfillRole = "producer" | "verifier";

const STORE_CONTRACTS: Record<BrowserBackfillStore, {
  locationId: string;
  producerAgentId: string;
  verifierAgentId: string;
  baseLimit: number;
  maximumLimit: number;
  artifactStore: string;
}> = {
  aldi: { locationId: "aldi-omaha-446-048", producerAgentId: "omaha-price-producer-aldi",
    verifierAgentId: "omaha-price-verifier-aldi", baseLimit: 2, maximumLimit: 3, artifactStore: "aldi" },
  fareway: { locationId: "fareway-omaha-043", producerAgentId: "omaha-price-producer-fareway",
    verifierAgentId: "omaha-price-verifier-fareway", baseLimit: 2, maximumLimit: 4, artifactStore: "fareway" },
  sams: { locationId: "sams-omaha", producerAgentId: "omaha-price-producer-sams-club",
    verifierAgentId: "omaha-price-verifier-sams-club", baseLimit: 2, maximumLimit: 3, artifactStore: "sams" },
  walmart: { locationId: "walmart-omaha", producerAgentId: "omaha-price-producer-walmart",
    verifierAgentId: "omaha-price-verifier-walmart", baseLimit: 3, maximumLimit: 5, artifactStore: "walmart" },
};

export interface BrowserBackfillAdaptiveSignal {
  consecutiveFailures?: number;
  successStreak?: number;
  ewmaLatencyMs?: number;
  challengeOpen?: boolean;
  requestedLimit?: number;
}

export interface BrowserBackfillStoreRequest {
  store: BrowserBackfillStore;
  role?: BrowserBackfillRole;
  verifierWorkItemId?: string;
  adaptive?: BrowserBackfillAdaptiveSignal;
}

export interface BrowserBackfillWaveConfig {
  runId: string;
  waveId: string;
  outputRoot: string;
  stores?: BrowserBackfillStoreRequest[];
  leaseSeconds?: number;
  definitionBulkSwitch?: {
    status: "completed";
    runId: string;
    completedAt: string;
    evidenceFile: string;
    evidenceSha256: string;
  };
}

export interface BrowserBackfillWavePaths {
  directory: string;
  claim: string;
  map: string;
  artifact: string;
  heartbeat: string;
  lock: string;
}

export interface BrowserBackfillWaveStorePlan {
  store: BrowserBackfillStore;
  storeLocationId: string;
  artifactStore: string;
  role: BrowserBackfillRole;
  agentId: string;
  owner: string;
  limit: number;
  verifierWorkItemId?: string;
  paths: BrowserBackfillWavePaths;
}

export interface BrowserBackfillWavePlan {
  kind: "catalog-backfill-browser-wave-plan-v4";
  flagsEnabled: false;
  chromeAutomated: false;
  callerOutcomesSubmitted: false;
  runId: string;
  waveId: string;
  leaseSeconds: number;
  generatedAt: string;
  stores: BrowserBackfillWaveStorePlan[];
}

export interface BrowserBackfillClaimWorkItem {
  id?: unknown;
  agent_id?: unknown;
  state?: unknown;
  lease_owner?: unknown;
  lease_expires_at?: unknown;
  input_json?: unknown;
  [key: string]: unknown;
}

export interface BrowserBackfillWaveClient {
  claim(input: { agentId: string; owner: string; limit: number; leaseSeconds: number }): Promise<{ workItems?: BrowserBackfillClaimWorkItem[] }>;
  claimExact(input: { agentId: string; workItemId: string; owner: string; leaseSeconds: number }): Promise<{ workItem?: BrowserBackfillClaimWorkItem }>;
  heartbeat(input: { owner: string; leaseSeconds: number }): Promise<{ workItems?: BrowserBackfillClaimWorkItem[] }>;
}

export interface BrowserBackfillWaveManifest extends Omit<BrowserBackfillWavePlan, "kind" | "stores"> {
  kind: "catalog-backfill-browser-wave-manifest-v4";
  claimedAt: string;
  stores: Array<BrowserBackfillWaveStorePlan & {
    workItemIds: string[];
    claimSha256: string;
    mapSha256: string;
    heartbeatSha256: string;
  }>;
}

interface ActiveSessionLock {
  kind: "catalog-backfill-browser-session-lock-v4";
  waveId: string;
  store: BrowserBackfillStore;
  role: BrowserBackfillRole;
  owner: string;
  agentId: string;
  leaseExpiresAt: string;
  claimSha256?: string;
}

const SAFE_ID = /^[a-z0-9][a-z0-9._-]{2,80}$/;
const SHA256 = /^[a-f0-9]{64}$/i;

function exactInteger(value: unknown, fallback: number): number {
  const parsed = Number(value ?? fallback);
  if (!Number.isSafeInteger(parsed)) return fallback;
  return parsed;
}

export function adaptiveBrowserBackfillLimit(store: BrowserBackfillStore, signal: BrowserBackfillAdaptiveSignal = {}): number {
  const contract = STORE_CONTRACTS[store];
  if (signal.challengeOpen || exactInteger(signal.consecutiveFailures, 0) > 0 || Number(signal.ewmaLatencyMs ?? 0) >= 30_000) return 1;
  const successCeiling = exactInteger(signal.successStreak, 0) >= 3 ? contract.maximumLimit : contract.baseLimit;
  const requested = exactInteger(signal.requestedLimit, successCeiling);
  return Math.max(1, Math.min(contract.maximumLimit, successCeiling, requested));
}

function requireSafeId(label: string, value: string): void {
  if (!SAFE_ID.test(value)) throw new Error(`${label} must be a stable lowercase identifier`);
}

function normalizeRequests(requests?: BrowserBackfillStoreRequest[]): BrowserBackfillStoreRequest[] {
  const normalized: BrowserBackfillStoreRequest[] = requests ?? BROWSER_BACKFILL_STORES.map((store) => ({ store }));
  const seen = new Set<string>();
  for (const request of normalized) {
    if (!BROWSER_BACKFILL_STORES.includes(request.store)) throw new Error(`unsupported or headless browser backfill store: ${request.store}`);
    if (seen.has(request.store)) throw new Error(`only one producer-or-verifier session is allowed for ${request.store}`);
    seen.add(request.store);
    const role = request.role ?? "producer";
    if (role === "verifier" && !String(request.verifierWorkItemId ?? "").startsWith("pipeline-v4-work_")) {
      throw new Error(`${request.store} verifier requires an exact pipeline-v4 work item id`);
    }
    if (role === "producer" && request.verifierWorkItemId) throw new Error(`${request.store} producer cannot carry a verifier work item id`);
  }
  return normalized;
}

export function buildBrowserBackfillWavePlan(config: BrowserBackfillWaveConfig, now = new Date()): BrowserBackfillWavePlan {
  requireSafeId("waveId", config.waveId);
  if (!config.runId.startsWith("catalog-backfill-v4_")) throw new Error("runId must identify the V4 catalog backfill");
  const leaseSeconds = exactInteger(config.leaseSeconds, 900);
  if (leaseSeconds < 60 || leaseSeconds > 900) throw new Error("browser backfill leaseSeconds must be between 60 and 900");
  const outputRoot = path.resolve(config.outputRoot);
  const stores = normalizeRequests(config.stores).map((request) => {
    const contract = STORE_CONTRACTS[request.store];
    const role = request.role ?? "producer";
    const owner = `v4-backfill-browser-wave-${config.waveId}-${request.store}-${role}`;
    const directory = path.join(outputRoot, config.waveId, request.store, role);
    return {
      store: request.store,
      storeLocationId: contract.locationId,
      artifactStore: contract.artifactStore,
      role,
      agentId: role === "producer" ? contract.producerAgentId : contract.verifierAgentId,
      owner,
      limit: role === "producer" ? adaptiveBrowserBackfillLimit(request.store, request.adaptive) : 1,
      ...(role === "verifier" ? { verifierWorkItemId: request.verifierWorkItemId } : {}),
      paths: {
        directory,
        claim: path.join(directory, "claim.json"),
        map: path.join(directory, "work-map.json"),
        artifact: path.join(directory, "browser-artifact.json"),
        heartbeat: path.join(directory, "heartbeat.json"),
        lock: path.join(outputRoot, ".browser-backfill-locks", `${request.store}.json`),
      },
    } satisfies BrowserBackfillWaveStorePlan;
  });
  if (new Set(stores.map((store) => store.owner)).size !== stores.length) throw new Error("browser backfill owners must be distinct");
  return { kind: "catalog-backfill-browser-wave-plan-v4", flagsEnabled: false, chromeAutomated: false,
    callerOutcomesSubmitted: false, runId: config.runId, waveId: config.waveId, leaseSeconds,
    generatedAt: now.toISOString(), stores };
}

async function assertDefinitionSwitch(config: BrowserBackfillWaveConfig, now: Date): Promise<void> {
  const gate = config.definitionBulkSwitch;
  if (!gate || gate.status !== "completed" || gate.runId !== config.runId || !SHA256.test(gate.evidenceSha256)) {
    throw new Error("production browser claims are disabled until the exact definition bulk switch is completed");
  }
  const completedAt = Date.parse(gate.completedAt);
  if (!Number.isFinite(completedAt) || completedAt > now.getTime()) throw new Error("definition bulk switch completion timestamp is invalid");
  let evidenceText = "";
  try { evidenceText = await readFile(path.resolve(gate.evidenceFile), "utf8"); }
  catch { throw new Error("definition bulk switch evidence file is missing or unreadable"); }
  if (sha256(evidenceText) !== gate.evidenceSha256.toLowerCase()) throw new Error("definition bulk switch evidence hash does not match");
  let evidence: any;
  try { evidence = JSON.parse(evidenceText); } catch { throw new Error("definition bulk switch evidence is not valid JSON"); }
  if (evidence?.kind !== "catalog-backfill-definition-bulk-switch-v4" || evidence.status !== "completed"
    || evidence.runId !== config.runId || evidence.completedAt !== gate.completedAt || evidence.flagsEnabled !== false) {
    throw new Error("definition bulk switch evidence does not authorize the flags-off browser wave");
  }
}

function sha256(value: string | Buffer): string {
  return createHash("sha256").update(value).digest("hex");
}

async function atomicJson(file: string, value: unknown): Promise<string> {
  await mkdir(path.dirname(file), { recursive: true });
  const text = `${JSON.stringify(value, null, 2)}\n`;
  const temporary = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
  await writeFile(temporary, text, { encoding: "utf8", flag: "wx" });
  await rename(temporary, file);
  return sha256(text);
}

function parseInput(work: BrowserBackfillClaimWorkItem): Record<string, unknown> {
  try { return JSON.parse(String(work.input_json ?? "{}")) as Record<string, unknown>; }
  catch { throw new Error(`claimed work ${String(work.id ?? "<missing>")} has invalid input_json`); }
}

function exactWorkItems(plan: BrowserBackfillWaveStorePlan, workItems: BrowserBackfillClaimWorkItem[], now: Date,
  expectedRunId?: string): BrowserBackfillClaimWorkItem[] {
  if (workItems.length === 0) throw new Error(`${plan.store} claim returned no work items`);
  if (workItems.length > plan.limit) throw new Error(`${plan.store} claim exceeded its adaptive limit`);
  const ids = new Set<string>();
  for (const work of workItems) {
    const id = String(work.id ?? "");
    if (!id.startsWith("pipeline-v4-work_") || ids.has(id)) throw new Error(`${plan.store} claim returned a missing or duplicate work id`);
    ids.add(id);
    if (String(work.agent_id ?? "") !== plan.agentId || String(work.lease_owner ?? "") !== plan.owner) {
      throw new Error(`${plan.store} claim artifact does not match its exact agent and owner`);
    }
    const expiry = Date.parse(String(work.lease_expires_at ?? ""));
    if (!Number.isFinite(expiry) || expiry <= now.getTime()) throw new Error(`${plan.store} claim contains a stale lease`);
    const input = parseInput(work);
    if (String(input.storeLocationId ?? "") !== plan.storeLocationId
      || String(input.runId ?? "") === "" || expectedRunId && String(input.runId) !== expectedRunId) {
      throw new Error(`${plan.store} claim input is not bound to its canonical store and run`);
    }
  }
  if (plan.role === "verifier" && (workItems.length !== 1 || String(workItems[0]?.id) !== plan.verifierWorkItemId)) {
    throw new Error(`${plan.store} verifier claim did not return its exact work item`);
  }
  return workItems;
}

function mapArtifact(plan: BrowserBackfillWaveStorePlan, workItems: BrowserBackfillClaimWorkItem[], runId: string, generatedAt: string) {
  return {
    kind: "catalog-backfill-browser-work-map-v4",
    runId,
    store: plan.store,
    storeLocationId: plan.storeLocationId,
    role: plan.role,
    agentId: plan.agentId,
    owner: plan.owner,
    generatedAt,
    artifactPath: plan.paths.artifact,
    workItems: workItems.map((work) => {
      const input = parseInput(work);
      const queryTerms = Array.isArray(input.queryTerms) ? input.queryTerms.map(String).map((term) => term.trim()).filter(Boolean) : [];
      if (queryTerms.length === 0) throw new Error(`${plan.store} work ${String(work.id)} has no exact query terms`);
      return { workItemId: String(work.id), commodityId: String(input.commodityId ?? ""),
        definitionVersionId: String(input.definitionVersionId ?? ""), queryTerms };
    }),
  };
}

async function acquireLock(plan: BrowserBackfillWaveStorePlan, now: Date, leaseSeconds: number): Promise<void> {
  await mkdir(path.dirname(plan.paths.lock), { recursive: true });
  const provisional: ActiveSessionLock = { kind: "catalog-backfill-browser-session-lock-v4", waveId: path.basename(path.dirname(path.dirname(plan.paths.directory))),
    store: plan.store, role: plan.role, owner: plan.owner, agentId: plan.agentId,
    leaseExpiresAt: new Date(now.getTime() + leaseSeconds * 1_000).toISOString() };
  try {
    const handle = await open(plan.paths.lock, "wx");
    try { await handle.writeFile(`${JSON.stringify(provisional, null, 2)}\n`, "utf8"); } finally { await handle.close(); }
  } catch (error: any) {
    if (error?.code !== "EEXIST") throw error;
    let existing: ActiveSessionLock | undefined;
    try { existing = JSON.parse(await readFile(plan.paths.lock, "utf8")) as ActiveSessionLock; } catch { /* fail closed below */ }
    const stale = !existing || !Number.isFinite(Date.parse(existing.leaseExpiresAt)) || Date.parse(existing.leaseExpiresAt) <= now.getTime();
    throw new Error(`${plan.store} already has an ${stale ? "stale or unreadable" : "active"} producer-or-verifier session lock`);
  }
}

async function validateLock(plan: BrowserBackfillWaveStorePlan, now: Date): Promise<ActiveSessionLock> {
  let lock: ActiveSessionLock;
  try { lock = JSON.parse(await readFile(plan.paths.lock, "utf8")) as ActiveSessionLock; }
  catch { throw new Error(`${plan.store} session lock is missing or unreadable`); }
  if (lock.kind !== "catalog-backfill-browser-session-lock-v4" || lock.store !== plan.store || lock.role !== plan.role
    || lock.owner !== plan.owner || lock.agentId !== plan.agentId) throw new Error(`${plan.store} session lock does not match the wave plan`);
  if (Date.parse(lock.leaseExpiresAt) <= now.getTime()) throw new Error(`${plan.store} session lock lease is stale`);
  return lock;
}

async function claimStore(plan: BrowserBackfillWaveStorePlan, wave: BrowserBackfillWavePlan, client: BrowserBackfillWaveClient, now: Date) {
  await acquireLock(plan, now, wave.leaseSeconds);
  try {
    let responseItems: BrowserBackfillClaimWorkItem[];
    if (plan.role === "producer") {
      const response = await client.claim({ agentId: plan.agentId, owner: plan.owner, limit: plan.limit, leaseSeconds: wave.leaseSeconds });
      responseItems = response.workItems ?? [];
    } else {
      const response = await client.claimExact({ agentId: plan.agentId, workItemId: plan.verifierWorkItemId!, owner: plan.owner,
        leaseSeconds: wave.leaseSeconds });
      responseItems = response.workItem ? [response.workItem] : [];
    }
    const claimed = exactWorkItems(plan, responseItems, now, wave.runId);
    const claimArtifact = { kind: "catalog-backfill-claim-v4", runId: wave.runId, agentId: plan.agentId, owner: plan.owner,
      claimedAt: now.toISOString(), workItems: claimed };
    const claimSha256 = await atomicJson(plan.paths.claim, claimArtifact);
    const mapSha256 = await atomicJson(plan.paths.map, mapArtifact(plan, claimed, wave.runId, now.toISOString()));
    const heartbeatResponse = await client.heartbeat({ owner: plan.owner, leaseSeconds: wave.leaseSeconds });
    const heartbeatItems = exactWorkItems(plan, heartbeatResponse.workItems ?? [], now, wave.runId);
    if (heartbeatItems.map((item) => String(item.id)).sort().join("|") !== claimed.map((item) => String(item.id)).sort().join("|")) {
      throw new Error(`${plan.store} heartbeat snapshot does not match the exact claim`);
    }
    const heartbeat = { kind: "catalog-backfill-heartbeat-v4", runId: wave.runId, agentId: plan.agentId,
      owner: plan.owner, refreshedAt: new Date().toISOString(), workItems: heartbeatItems };
    const heartbeatSha256 = await atomicJson(plan.paths.heartbeat, heartbeat);
    const expiry = Math.min(...heartbeatItems.map((item) => Date.parse(String(item.lease_expires_at))));
    const lock: ActiveSessionLock = { kind: "catalog-backfill-browser-session-lock-v4", waveId: wave.waveId,
      store: plan.store, role: plan.role, owner: plan.owner, agentId: plan.agentId,
      leaseExpiresAt: new Date(expiry).toISOString(), claimSha256 };
    await atomicJson(plan.paths.lock, lock);
    return { ...plan, workItemIds: claimed.map((item) => String(item.id)), claimSha256, mapSha256, heartbeatSha256 };
  } catch (error) {
    // An interrupted claim is ambiguous: the server may hold a live lease even
    // when the response was lost. Retain the provisional lock and fail closed.
    throw error;
  }
}

export async function executeBrowserBackfillWave(config: BrowserBackfillWaveConfig, client: BrowserBackfillWaveClient,
  now = new Date()): Promise<BrowserBackfillWaveManifest> {
  await assertDefinitionSwitch(config, now);
  const plan = buildBrowserBackfillWavePlan(config, now);
  const stores = await Promise.all(plan.stores.map((store) => claimStore(store, plan, client, now)));
  const manifest: BrowserBackfillWaveManifest = { ...plan, kind: "catalog-backfill-browser-wave-manifest-v4",
    claimedAt: new Date().toISOString(), stores };
  await atomicJson(path.join(path.resolve(config.outputRoot), config.waveId, "manifest.json"), manifest);
  return manifest;
}

function claimArtifactMatches(plan: BrowserBackfillWaveStorePlan, claim: any, expectedRunId: string, now: Date): BrowserBackfillClaimWorkItem[] {
  if (claim?.kind !== "catalog-backfill-claim-v4" || claim.runId !== expectedRunId || claim.agentId !== plan.agentId || claim.owner !== plan.owner) {
    throw new Error(`${plan.store} persisted claim does not match its wave plan`);
  }
  return exactWorkItems(plan, Array.isArray(claim.workItems) ? claim.workItems : [], now, expectedRunId);
}

export async function heartbeatBrowserBackfillWave(manifest: BrowserBackfillWaveManifest, client: BrowserBackfillWaveClient,
  now = new Date()): Promise<Array<{ store: BrowserBackfillStore; heartbeatSha256: string }>> {
  const results = await Promise.all(manifest.stores.map(async (plan) => {
    await validateLock(plan, now);
    const claimText = await readFile(plan.paths.claim, "utf8");
    if (sha256(claimText) !== plan.claimSha256) throw new Error(`${plan.store} persisted claim hash does not match the manifest`);
    const claimed = claimArtifactMatches(plan, JSON.parse(claimText), manifest.runId, now);
    const response = await client.heartbeat({ owner: plan.owner, leaseSeconds: manifest.leaseSeconds });
    const refreshed = exactWorkItems(plan, response.workItems ?? [], now);
    if (refreshed.map((item) => String(item.id)).sort().join("|") !== claimed.map((item) => String(item.id)).sort().join("|")) {
      throw new Error(`${plan.store} heartbeat returned work outside the persisted claim`);
    }
    const heartbeatSha256 = await atomicJson(plan.paths.heartbeat, { kind: "catalog-backfill-heartbeat-v4",
      runId: manifest.runId, agentId: plan.agentId, owner: plan.owner, refreshedAt: now.toISOString(), workItems: refreshed });
    return { store: plan.store, heartbeatSha256 };
  }));
  return results;
}

export async function closeCompletedBrowserBackfillSessions(manifest: BrowserBackfillWaveManifest,
  client: BrowserBackfillWaveClient, now = new Date()): Promise<Array<{ store: BrowserBackfillStore; closed: true }>> {
  return Promise.all(manifest.stores.map(async (plan) => {
    await validateLock(plan, now);
    const claimText = await readFile(plan.paths.claim, "utf8");
    if (sha256(claimText) !== plan.claimSha256) throw new Error(`${plan.store} persisted claim hash does not match the manifest`);
    claimArtifactMatches(plan, JSON.parse(claimText), manifest.runId, now);
    const response = await client.heartbeat({ owner: plan.owner, leaseSeconds: manifest.leaseSeconds });
    if ((response.workItems ?? []).length !== 0) throw new Error(`${plan.store} session is still active and cannot transition roles`);
    await atomicJson(plan.paths.heartbeat, { kind: "catalog-backfill-heartbeat-v4", runId: manifest.runId,
      agentId: plan.agentId, owner: plan.owner, refreshedAt: now.toISOString(), completed: true, workItems: [] });
    // validateLock above fences this deletion to the exact wave owner and role.
    await rm(plan.paths.lock);
    return { store: plan.store, closed: true as const };
  }));
}

function expectedCanaryLocation(plan: BrowserBackfillWaveStorePlan): Set<string> {
  return new Set([plan.storeLocationId, plan.storeLocationId.split("-").at(-1) ?? "", plan.store === "fareway" ? "043" : ""]);
}

export async function validateBrowserBackfillWaveArtifacts(manifest: BrowserBackfillWaveManifest, now = new Date()) {
  return Promise.all(manifest.stores.map(async (plan) => {
    await validateLock(plan, now);
    const [claimText, mapText, artifactText] = await Promise.all([
      readFile(plan.paths.claim, "utf8"), readFile(plan.paths.map, "utf8"), readFile(plan.paths.artifact, "utf8"),
    ]);
    if (sha256(claimText) !== plan.claimSha256 || sha256(mapText) !== plan.mapSha256) {
      throw new Error(`${plan.store} persisted claim or map hash does not match the manifest`);
    }
    const workItems = claimArtifactMatches(plan, JSON.parse(claimText), manifest.runId, now);
    const map = JSON.parse(mapText) as any;
    const artifact = JSON.parse(artifactText) as any;
    if (map?.kind !== "catalog-backfill-browser-work-map-v4" || map.owner !== plan.owner || map.agentId !== plan.agentId
      || map.storeLocationId !== plan.storeLocationId || map.artifactPath !== plan.paths.artifact) {
      throw new Error(`${plan.store} work map does not match its exact claim and artifact path`);
    }
    const mappedIds = (map.workItems ?? []).map((item: any) => String(item.workItemId)).sort();
    const claimIds = workItems.map((item) => String(item.id)).sort();
    if (mappedIds.join("|") !== claimIds.join("|")) throw new Error(`${plan.store} work map does not cover the exact claim`);
    const expectedPhase = plan.role === "producer" ? "discovery" : "verification";
    if (artifact?.version !== 2 || artifact.phase !== expectedPhase || artifact.store !== plan.artifactStore) {
      throw new Error(`${plan.store} browser artifact has a mismatched store, phase, or version`);
    }
    if (artifact?.canary?.marketVerified !== true || artifact?.canary?.locationVerified !== true
      || artifact?.canary?.priceModeVerified !== true || !expectedCanaryLocation(plan).has(String(artifact?.canary?.locationId ?? ""))) {
      throw new Error(`${plan.store} browser artifact is not bound to the canonical location canary`);
    }
    const observedAt = Date.parse(String(artifact.canary.observedAt ?? ""));
    if (!Number.isFinite(observedAt) || observedAt > now.getTime() || now.getTime() - observedAt > 15 * 60_000) {
      throw new Error(`${plan.store} browser artifact canary is stale`);
    }
    const exactTerms = new Set((map.workItems ?? []).flatMap((item: any) => item.queryTerms ?? []).map(String));
    const artifactTerms = plan.role === "producer" ? (artifact.terms ?? []).map((item: any) => String(item.query ?? "")) : [];
    if (plan.role === "producer" && (artifactTerms.length === 0 || new Set(artifactTerms).size !== artifactTerms.length
      || [...exactTerms].sort().join("|") !== [...new Set<string>(artifactTerms)].sort().join("|"))) {
      throw new Error(`${plan.store} browser artifact does not exactly cover the work-map queries`);
    }
    if (plan.role === "verifier" && (!Array.isArray(artifact.verifications) || artifact.verifications.length === 0)) {
      throw new Error(`${plan.store} verifier artifact contains no independent verification records`);
    }
    return { store: plan.store, role: plan.role, artifact: plan.paths.artifact, sha256: sha256(artifactText), workItems: claimIds.length };
  }));
}
