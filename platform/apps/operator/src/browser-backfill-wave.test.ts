import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { adaptiveBrowserBackfillLimit, buildBrowserBackfillWavePlan, closeCompletedBrowserBackfillSessions, executeBrowserBackfillWave,
  heartbeatBrowserBackfillWave, validateBrowserBackfillWaveArtifacts, type BrowserBackfillWaveClient,
  type BrowserBackfillWaveConfig } from "./browser-backfill-wave";

const NOW = new Date("2026-08-15T00:00:00.000Z");
const RUN = "catalog-backfill-v4_test-run";
const SWITCH_TIME = "2026-08-14T23:59:00.000Z";

function inputFor(agentId: string) {
  const location = agentId.includes("aldi") ? "aldi-omaha-446-048" : agentId.includes("fareway") ? "fareway-omaha-043"
    : agentId.includes("sams") ? "sams-omaha" : "walmart-omaha";
  return JSON.stringify({ runId: RUN, storeLocationId: location, commodityId: `${location}-commodity`,
    definitionVersionId: "ingdef_test", queryTerms: [`${location} term`] });
}

function work(agentId: string, owner: string, id = `pipeline-v4-work_${agentId.replaceAll(/[^a-z]/g, "").slice(-12)}`) {
  return { id, agent_id: agentId, state: "running", lease_owner: owner,
    lease_expires_at: "2026-08-15T00:15:00.000Z", input_json: inputFor(agentId) };
}

function mockClient(overrides: Partial<BrowserBackfillWaveClient> = {}): BrowserBackfillWaveClient {
  return {
    claim: async ({ agentId, owner }) => ({ workItems: [work(agentId, owner)] }),
    claimExact: async ({ agentId, owner, workItemId }) => ({ workItem: work(agentId, owner, workItemId) }),
    heartbeat: async ({ owner }) => {
      const store = owner.includes("-aldi-") ? "aldi" : owner.includes("-fareway-") ? "fareway"
        : owner.includes("-sams-") ? "sams" : "walmart";
      const role = owner.endsWith("-verifier") ? "verifier" : "producer";
      const agentId = `omaha-price-${role}-${store === "sams" ? "sams-club" : store}`;
      return { workItems: [work(agentId, owner)] };
    },
    ...overrides,
  };
}

async function config(stores?: BrowserBackfillWaveConfig["stores"]): Promise<BrowserBackfillWaveConfig> {
  const outputRoot = await mkdtemp(path.join(os.tmpdir(), "browser-wave-"));
  const evidenceFile = path.join(outputRoot, "definition-switch.json");
  const evidenceText = `${JSON.stringify({ kind: "catalog-backfill-definition-bulk-switch-v4", status: "completed", runId: RUN,
    completedAt: SWITCH_TIME, flagsEnabled: false }, null, 2)}\n`;
  await writeFile(evidenceFile, evidenceText, "utf8");
  const { createHash } = await import("node:crypto");
  return { runId: RUN, waveId: `wave-${crypto.randomUUID().slice(0, 8)}`, outputRoot,
    definitionBulkSwitch: { status: "completed", runId: RUN, completedAt: SWITCH_TIME, evidenceFile,
      evidenceSha256: createHash("sha256").update(evidenceText).digest("hex") }, ...(stores ? { stores } : {}) };
}

describe("browser backfill wave coordinator", () => {
  it("plans only the four browser stores with distinct owners, exact paths, and adaptive limits", async () => {
    const value = await config([{ store: "aldi", adaptive: { challengeOpen: true, requestedLimit: 3 } },
      { store: "fareway", adaptive: { successStreak: 4, requestedLimit: 4 } }, { store: "sams" }, { store: "walmart" }]);
    const plan = buildBrowserBackfillWavePlan(value, NOW);
    expect(plan.flagsEnabled).toBe(false);
    expect(plan.chromeAutomated).toBe(false);
    expect(plan.callerOutcomesSubmitted).toBe(false);
    expect(plan.stores.map((item) => item.store)).toEqual(["aldi", "fareway", "sams", "walmart"]);
    expect(new Set(plan.stores.map((item) => item.owner)).size).toBe(4);
    expect(plan.stores.find((item) => item.store === "aldi")?.limit).toBe(1);
    expect(plan.stores.find((item) => item.store === "fareway")?.limit).toBe(4);
    for (const store of plan.stores) {
      expect(store.paths.claim).toBe(path.join(path.resolve(value.outputRoot), value.waveId, store.store, "producer", "claim.json"));
      expect(store.paths.artifact).toBe(path.join(path.resolve(value.outputRoot), value.waveId, store.store, "producer", "browser-artifact.json"));
    }
    expect(adaptiveBrowserBackfillLimit("walmart", { consecutiveFailures: 1, requestedLimit: 5 })).toBe(1);
  });

  it("rejects duplicate sessions, headless stores, and verifier batches without exact IDs", async () => {
    const value = await config([{ store: "aldi" }, { store: "aldi", role: "verifier", verifierWorkItemId: "pipeline-v4-work_x" }]);
    expect(() => buildBrowserBackfillWavePlan(value, NOW)).toThrow(/only one producer-or-verifier/);
    expect(() => buildBrowserBackfillWavePlan({ ...value, stores: [{ store: "bakers" as any }] }, NOW)).toThrow(/headless/);
    expect(() => buildBrowserBackfillWavePlan({ ...value, stores: [{ store: "fareway", role: "verifier" }] }, NOW)).toThrow(/exact/);
  });

  it("keeps production claims disabled without exact bulk-switch evidence", async () => {
    const value = await config([{ store: "aldi" }]);
    delete value.definitionBulkSwitch;
    let called = false;
    await expect(executeBrowserBackfillWave(value, mockClient({ claim: async () => { called = true; return {}; } }), NOW))
      .rejects.toThrow(/disabled until/);
    expect(called).toBe(false);
  });

  it("claims browser stores concurrently and emits claim, map, heartbeat, artifact, and lock paths", async () => {
    const value = await config();
    let active = 0; let maximumActive = 0;
    const client = mockClient({ claim: async ({ agentId, owner }) => {
      active += 1; maximumActive = Math.max(maximumActive, active);
      await new Promise((resolve) => setTimeout(resolve, 10));
      active -= 1;
      return { workItems: [work(agentId, owner)] };
    } });
    const manifest = await executeBrowserBackfillWave(value, client, NOW);
    expect(maximumActive).toBe(4);
    expect(manifest.stores).toHaveLength(4);
    for (const store of manifest.stores) {
      expect(JSON.parse(await readFile(store.paths.claim, "utf8")).owner).toBe(store.owner);
      expect(JSON.parse(await readFile(store.paths.map, "utf8")).artifactPath).toBe(store.paths.artifact);
      expect(JSON.parse(await readFile(store.paths.heartbeat, "utf8")).owner).toBe(store.owner);
      expect(JSON.parse(await readFile(store.paths.lock, "utf8")).role).toBe("producer");
    }
  });

  it("uses claim-exact for a distinct verifier owner and exact work id", async () => {
    const verifierId = "pipeline-v4-work_verifierexact";
    const value = await config([{ store: "fareway", role: "verifier", verifierWorkItemId: verifierId }]);
    let batchCalled = false; let exactCalled = "";
    const client = mockClient({ claim: async () => { batchCalled = true; return {}; },
      claimExact: async ({ agentId, owner, workItemId }) => { exactCalled = workItemId; return { workItem: work(agentId, owner, workItemId) }; },
      heartbeat: async ({ owner }) => ({ workItems: [work("omaha-price-verifier-fareway", owner, verifierId)] }) });
    const manifest = await executeBrowserBackfillWave(value, client, NOW);
    expect(batchCalled).toBe(false);
    expect(exactCalled).toBe(verifierId);
    expect(manifest.stores[0]?.workItemIds).toEqual([verifierId]);
    expect(manifest.stores[0]?.owner).toMatch(/fareway-verifier$/);
  });

  it("allows an exact verifier only after the producer session is authoritatively closed", async () => {
    const producerConfig = await config([{ store: "fareway" }]);
    const producer = await executeBrowserBackfillWave(producerConfig, mockClient(), NOW);
    const verifierId = "pipeline-v4-work_afterproducer";
    const verifierConfig: BrowserBackfillWaveConfig = { ...producerConfig, waveId: `wave-${crypto.randomUUID().slice(0, 8)}`,
      stores: [{ store: "fareway", role: "verifier", verifierWorkItemId: verifierId }] };
    await expect(executeBrowserBackfillWave(verifierConfig, mockClient(), NOW)).rejects.toThrow(/active.*session lock/);
    await expect(closeCompletedBrowserBackfillSessions(producer, mockClient({ heartbeat: async () => ({ workItems: [] }) }), NOW))
      .resolves.toEqual([{ store: "fareway", closed: true }]);
    const verifierClient = mockClient({ claimExact: async ({ agentId, owner, workItemId }) => ({ workItem: work(agentId, owner, workItemId) }),
      heartbeat: async ({ owner }) => ({ workItems: [work("omaha-price-verifier-fareway", owner, verifierId)] }) });
    await expect(executeBrowserBackfillWave(verifierConfig, verifierClient, NOW)).resolves.toMatchObject({
      stores: [{ role: "verifier", workItemIds: [verifierId] }],
    });
  });

  it("fails closed on stale leases and retains the exclusive session lock", async () => {
    const value = await config([{ store: "walmart" }]);
    const stale = mockClient({ claim: async ({ agentId, owner }) => ({ workItems: [{ ...work(agentId, owner), lease_expires_at: "2026-08-14T23:59:59.000Z" }] }) });
    await expect(executeBrowserBackfillWave(value, stale, NOW)).rejects.toThrow(/stale lease/);
    const lock = buildBrowserBackfillWavePlan(value, NOW).stores[0]!.paths.lock;
    expect(JSON.parse(await readFile(lock, "utf8")).store).toBe("walmart");
    await expect(executeBrowserBackfillWave(value, stale, NOW)).rejects.toThrow(/session lock/);
  });

  it("rejects persisted claim tampering before heartbeat", async () => {
    const value = await config([{ store: "aldi" }]);
    const manifest = await executeBrowserBackfillWave(value, mockClient(), NOW);
    await writeFile(manifest.stores[0]!.paths.claim, "{}\n", "utf8");
    let called = false;
    await expect(heartbeatBrowserBackfillWave(manifest, mockClient({ heartbeat: async () => { called = true; return {}; } }), NOW))
      .rejects.toThrow(/hash/);
    expect(called).toBe(false);
  });

  it("rejects a mismatched browser artifact without submitting an outcome", async () => {
    const value = await config([{ store: "aldi" }]);
    const manifest = await executeBrowserBackfillWave(value, mockClient(), NOW);
    const plan = manifest.stores[0]!;
    await writeFile(plan.paths.artifact, `${JSON.stringify({ version: 2, phase: "discovery", store: "walmart",
      canary: { observedAt: NOW.toISOString(), marketVerified: true, locationVerified: true, priceModeVerified: true,
        locationId: "aldi-omaha-446-048" }, terms: [{ query: "aldi-omaha-446-048 term" }] })}\n`, "utf8");
    await expect(validateBrowserBackfillWaveArtifacts(manifest, NOW)).rejects.toThrow(/mismatched store/);
  });
});
