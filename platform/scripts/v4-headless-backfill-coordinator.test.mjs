import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import {
  HEADLESS_BACKFILL_STORES,
  assertCheckedHeadlessChunk,
  createSemanticGuard,
  planHeadlessBackfill,
  runHeadlessBackfillCoordinator,
} from "./v4-headless-backfill-coordinator.mjs";

function work(store, index = 0, commodityId = `commodity-${index}`) {
  return {
    id: `producer-${store.key}-${index}`,
    agent_id: `omaha-price-producer-${store.agentSuffix}`,
    lease_owner: `owner-${store.key}`,
    lease_generation: 1,
    lease_expires_at: "2099-01-01T00:00:00.000Z",
    input_json: JSON.stringify({ commodityId, queryTerms: [`Query ${store.key} ${index}`], storeLocationId: store.storeLocationId }),
  };
}

function chunk(store, claim, observedAt, excluded = false) {
  const terms = claim.workItems.map((item) => JSON.parse(item.input_json).queryTerms[0]);
  return {
    version: 2, phase: "discovery", store: store.key, canary: { observedAt },
    terms: terms.map((query) => ({ query, outcome: "empty", rowCount: 0,
      retrieval: { loadedResultCount: 0, availableResultCount: 0, hasMoreResults: false, termination: "end-of-results" },
      ...(excluded ? { excludedResults: [{ productKey: "bad", reason: "missing facts" }] } : {}) })),
    rows: [],
  };
}

function fakeDriver({ excludedStore, semanticStore, non200Store } = {}) {
  let clock = Date.parse("2026-08-14T23:00:00.000Z");
  const calls = []; const active = new Map(); let globalActive = 0; let maximumGlobal = 0; const maximumByStore = new Map();
  const enter = async (store) => {
    const count = (active.get(store.key) ?? 0) + 1; active.set(store.key, count);
    globalActive += 1; maximumGlobal = Math.max(maximumGlobal, globalActive);
    maximumByStore.set(store.key, Math.max(maximumByStore.get(store.key) ?? 0, count));
    await new Promise((resolve) => setTimeout(resolve, semanticStore && store.key !== semanticStore ? 15 : 1));
  };
  const leave = (store) => { active.set(store.key, active.get(store.key) - 1); globalActive -= 1; };
  return {
    calls, maximumByStore, get maximumGlobal() { return maximumGlobal; },
    async claimProducer(store) {
      calls.push(["claim-producer", store.key]);
      return { workItems: [work(store, 0, store.key === semanticStore ? "almonds" : `commodity-${store.key}`)] };
    },
    async capture(store, claim, file) {
      calls.push(["capture", store.key, claim.workItems[0].agent_id.includes("verifier") ? "verifier" : "producer"]);
      await enter(store); clock += 1_000;
      const artifact = chunk(store, claim, new Date(clock).toISOString(), excludedStore === store.key);
      await writeFile(file, JSON.stringify(artifact), "utf8"); leave(store); return artifact;
    },
    async submit(role, claimFile) {
      const claim = JSON.parse(await readFile(claimFile, "utf8"));
      calls.push(["submit", claim.workItems[0].input_json.includes("sams") ? "unexpected" : claim.workItems[0].agent_id, role]);
      if (role === "verifier") return { ok: true, submitted: [{ outcome: "not_found", workItemId: claim.workItems[0].id }] };
      return { ok: true, submitted: claim.workItems.map((item) => ({
        ...(item.input_json.includes(non200Store ?? "\u0000") ? { httpStatus: 409 } : {}),
        outcome: item.input_json.includes("almonds") ? "priced" : "not_found", workItemId: item.id,
        verifierWorkItemId: `verifier-${item.id}`,
        ...(item.input_json.includes("almonds") ? { winner: { productId: "4300002140", productName: "Honey Bunches of Oats with Crispy Almonds, 48 oz." } } : {}) })) };
    },
    async claimVerifierExact(store, lane, workItemId) {
      calls.push(["claim-verifier", store.key, workItemId]);
      const item = work(store); return { workItem: { ...item, id: workItemId,
        agent_id: `omaha-price-verifier-${store.agentSuffix}`, lease_owner: `${lane.verifierOwnerPrefix}-0` } };
    },
  };
}

describe("flags-off headless backfill coordinator", () => {
  it("plans only the three headless stores and clamps batches at 50", async () => {
    const output = await mkdtemp(path.join(os.tmpdir(), "headless-plan-"));
    const plan = planHeadlessBackfill({ runId: "run", outputDirectory: output, limit: 99, waveId: "wave" });
    expect(plan.limit).toBe(50);
    expect(plan.stores.map((store) => store.key)).toEqual(["bakers", "family-fare", "hy-vee"]);
    expect(JSON.stringify(plan)).not.toMatch(/aldi|fareway|sams|walmart|rollout|feature.flag/i);
  });

  it("runs stores concurrently while serializing each store producer and verifier", async () => {
    const output = await mkdtemp(path.join(os.tmpdir(), "headless-run-"));
    const plan = planHeadlessBackfill({ runId: "run", outputDirectory: output, limit: 1, waveId: "wave" });
    const driver = fakeDriver();
    const result = await runHeadlessBackfillCoordinator({ plan, driver, semanticGuard: () => null });
    expect(result.ok).toBe(true);
    expect(result.lanes.every((lane) => lane.produced === 1 && lane.verified === 1)).toBe(true);
    expect(driver.maximumGlobal).toBeGreaterThan(1);
    expect([...driver.maximumByStore.values()]).toEqual([1, 1, 1]);
    expect(driver.calls.filter((call) => call[0] === "claim-verifier")).toHaveLength(3);
  });

  it("stops only one lane when immutable source facts were excluded", async () => {
    const output = await mkdtemp(path.join(os.tmpdir(), "headless-exclusion-"));
    const plan = planHeadlessBackfill({ runId: "run", outputDirectory: output, limit: 1, waveId: "wave" });
    const result = await runHeadlessBackfillCoordinator({ plan, driver: fakeDriver({ excludedStore: "bakers" }), semanticGuard: () => null });
    expect(result.globallyStopped).toBe(false);
    expect(result.lanes.find((lane) => lane.store === "bakers").state).toBe("stopped");
    expect(result.lanes.filter((lane) => lane.state === "complete")).toHaveLength(2);
  });

  it("stops only the affected lane on an exposed non-200 submission", async () => {
    const output = await mkdtemp(path.join(os.tmpdir(), "headless-non200-"));
    const plan = planHeadlessBackfill({ runId: "run", outputDirectory: output, limit: 1, waveId: "wave" });
    const result = await runHeadlessBackfillCoordinator({ plan, driver: fakeDriver({ non200Store: "family-fare" }), semanticGuard: () => null });
    expect(result.globallyStopped).toBe(false);
    expect(result.lanes.find((lane) => lane.store === "family-fare")).toMatchObject({ state: "stopped", produced: 0, verified: 0 });
    expect(result.lanes.filter((lane) => lane.state === "complete")).toHaveLength(2);
  });

  it("globally stops before verifier claims on an authored semantic exclusion", async () => {
    const output = await mkdtemp(path.join(os.tmpdir(), "headless-semantic-"));
    const plan = planHeadlessBackfill({ runId: "run", outputDirectory: output, limit: 1, waveId: "wave" });
    const driver = fakeDriver({ semanticStore: "bakers" });
    const guard = createSemanticGuard([{ id: "almonds", exclude: ["\\boats?\\b", "\\bcereals?\\b"] }], { entries: [] });
    const result = await runHeadlessBackfillCoordinator({ plan, driver, semanticGuard: guard });
    expect(result.globallyStopped).toBe(true);
    expect(result.globalReason).toMatch(/systematic semantic defect/);
    expect(driver.calls.filter((call) => call[0] === "claim-verifier")).toHaveLength(0);
  });

  it("rejects blocked, rejected, excluded, and incomplete chunks", () => {
    const store = HEADLESS_BACKFILL_STORES[0]; const claim = { workItems: [work(store)] };
    expect(() => assertCheckedHeadlessChunk(chunk(store, claim, new Date().toISOString(), true))).toThrow(/exclusions/);
    const blocked = chunk(store, claim, new Date().toISOString()); blocked.terms[0].outcome = "blocked";
    expect(() => assertCheckedHeadlessChunk(blocked)).toThrow(/blocked/);
    const truncated = chunk(store, claim, new Date().toISOString()); truncated.terms[0].retrieval.hasMoreResults = true;
    expect(() => assertCheckedHeadlessChunk(truncated)).toThrow(/incomplete retrieval/);
  });
});
