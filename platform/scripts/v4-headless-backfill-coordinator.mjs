import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const HEADLESS_BACKFILL_STORES = Object.freeze([
  { key: "bakers", agentSuffix: "bakers", storeLocationId: "bakers-saddle-creek", storeName: "Baker's" },
  { key: "family-fare", agentSuffix: "family-fare", storeLocationId: "family-fare-omaha-6401", storeName: "Family Fare" },
  { key: "hy-vee", agentSuffix: "hy-vee", storeLocationId: "hy-vee-omaha-1465", storeName: "Hy-Vee" },
]);

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const safeSegment = (value) => String(value).replace(/[^a-zA-Z0-9._-]+/g, "-");
const normalize = (value) => String(value ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

export function planHeadlessBackfill({ runId, outputDirectory, limit = 5, waveId = new Date().toISOString().replace(/\D/g, "").slice(0, 14) }) {
  if (!runId) throw new Error("headless backfill coordinator requires --run-id");
  if (!outputDirectory) throw new Error("headless backfill coordinator requires --output-dir");
  const boundedLimit = Math.min(50, Math.max(1, Number(limit)));
  if (!Number.isSafeInteger(boundedLimit)) throw new Error("headless backfill limit must be an integer from 1 to 50");
  return {
    kind: "v4-flags-off-headless-backfill-plan",
    runId,
    waveId,
    limit: boundedLimit,
    outputDirectory: path.resolve(outputDirectory),
    stores: HEADLESS_BACKFILL_STORES.map((store) => ({
      ...store,
      producerAgent: `omaha-price-producer-${store.agentSuffix}`,
      verifierAgent: `omaha-price-verifier-${store.agentSuffix}`,
      producerOwner: `v4-backfill-headless-${store.key}-producer-${safeSegment(waveId)}`,
      verifierOwnerPrefix: `v4-backfill-headless-${store.key}-verifier-${safeSegment(waveId)}`,
      directory: path.resolve(outputDirectory, store.key),
    })),
  };
}

export function assertCheckedHeadlessChunk(chunk) {
  if (chunk?.version !== 2 || chunk.phase !== "discovery" || !HEADLESS_BACKFILL_STORES.some((store) => store.key === chunk.store)) {
    throw new Error("headless coordinator received a non-headless V2 discovery chunk");
  }
  if (!Array.isArray(chunk.terms) || chunk.terms.length === 0 || !Array.isArray(chunk.rows)) throw new Error("headless chunk is incomplete");
  for (const term of chunk.terms) {
    if (["blocked", "rejected"].includes(String(term.outcome))) throw new Error(`${chunk.store} query ${term.query} was ${term.outcome}`);
    if (Array.isArray(term.excludedResults) && term.excludedResults.length > 0) throw new Error(`${chunk.store} query ${term.query} has explicit exclusions`);
    const retrieval = term.retrieval ?? {};
    if (retrieval.hasMoreResults === true || !["end-of-results", "target-reached"].includes(String(retrieval.termination))) {
      throw new Error(`${chunk.store} query ${term.query} has incomplete retrieval`);
    }
    if (!Number.isSafeInteger(Number(retrieval.loadedResultCount)) || Number(retrieval.loadedResultCount) < 0
      || Number(retrieval.loadedResultCount) !== Number(retrieval.availableResultCount)) {
      throw new Error(`${chunk.store} query ${term.query} has inconsistent raw-result coverage`);
    }
  }
  return chunk;
}

function compilePatterns(values = []) {
  return values.map((value) => {
    try { return new RegExp(String(value), "i"); } catch { return null; }
  }).filter(Boolean);
}

export function createSemanticGuard(commodities, knownWrong) {
  const definitions = new Map((commodities ?? []).map((row) => [String(row.id), { ...row, exclusions: compilePatterns(row.exclude) }]));
  const known = knownWrong?.entries ?? [];
  return ({ store, workItem, submission }) => {
    const payload = JSON.parse(String(workItem.input_json ?? "{}"));
    const winner = submission?.winner;
    if (!winner) return null;
    const name = String(winner.productName ?? "");
    const definition = definitions.get(String(payload.commodityId));
    const exclusion = definition?.exclusions.find((pattern) => pattern.test(name));
    const knownMatch = known.find((entry) => String(entry.commodity) === String(payload.commodityId)
      && (!entry.store || normalize(entry.store) === normalize(store.storeName))
      && (String(entry.product_id ?? "") === String(winner.productId ?? "")
        || (entry.names ?? []).some((candidate) => normalize(candidate) === normalize(name))));
    if (!exclusion && !knownMatch) return null;
    return {
      commodityId: payload.commodityId,
      storeLocationId: store.storeLocationId,
      productId: winner.productId,
      productName: name,
      reason: knownMatch ? `known-wrong match: ${knownMatch.evidence ?? knownMatch.verdict}` : `authored exclude matched ${exclusion}`,
    };
  };
}

function extractLastJson(text) {
  for (let index = text.lastIndexOf("{"); index >= 0; index = text.lastIndexOf("{", index - 1)) {
    try { return JSON.parse(text.slice(index)); } catch { /* scan to the prior object start */ }
  }
  throw new Error(`command did not emit a JSON result: ${text.slice(-500)}`);
}

async function runCommand(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: ROOT, env: process.env, windowsHide: true,
      shell: process.platform === "win32" && /\.cmd$/i.test(command), stdio: [options.stdin ? "pipe" : "ignore", "pipe", "pipe"] });
    const stdout = []; const stderr = [];
    child.stdout.on("data", (chunk) => stdout.push(chunk)); child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.on("error", reject);
    child.on("exit", (code) => {
      const output = Buffer.concat(stdout).toString("utf8"); const errors = Buffer.concat(stderr).toString("utf8");
      if (code !== 0) reject(new Error(`${command} exited ${code}: ${(errors || output).slice(-2000)}`));
      else resolve({ output, errors, json: options.json === false ? null : extractLastJson(output) });
    });
    if (options.stdin) child.stdin.end(options.stdin); else child.stdin?.end();
  });
}

export function createSubprocessDriver({ pnpm = process.platform === "win32" ? "pnpm.cmd" : "pnpm", pnpmPrefix = [] } = {}) {
  const tc = (...args) => runCommand(pnpm, [...pnpmPrefix, "--silent", "tc", "ingredient", "backfill-v4", ...args]);
  return {
    async claimProducer(store, lane, plan) {
      const file = path.join(lane.directory, "producer-claim.json");
      return (await tc("claim", lane.producerAgent, lane.producerOwner, String(plan.limit), file)).json;
    },
    async capture(store, claim, file) {
      const claimText = `${JSON.stringify(claim)}\n`;
      await runCommand(pnpm, [...pnpmPrefix, "--silent", "exec", "tsx", "scripts/run-v4-backfill-store-batch.mjs", "headless", store.key, file], { stdin: claimText, json: false });
      return JSON.parse(await readFile(file, "utf8"));
    },
    async submit(role, claimFile, chunkFile, generation, session, wrapperFile) {
      const result = (await tc("submit-claim", role, claimFile, chunkFile, generation, session, wrapperFile)).json;
      const wrapper = JSON.parse(await readFile(wrapperFile, "utf8"));
      return { ...result, submitted: (result.submitted ?? []).map((row, index) => ({
        ...row, workItemId: wrapper.submissions?.[index]?.workItemId,
      })) };
    },
    async claimVerifierExact(store, lane, workItemId, index, file) {
      return (await tc("claim-exact", lane.verifierAgent, workItemId, `${lane.verifierOwnerPrefix}-${index}`, file)).json;
    },
  };
}

function claimDocument(result, lane, role) {
  const workItems = result?.workItems ?? (result?.workItem ? [result.workItem] : []);
  if (workItems.length === 0) return null;
  return { kind: "catalog-backfill-claim-v4", agentId: role === "producer" ? lane.producerAgent : lane.verifierAgent,
    owner: role === "producer" ? lane.producerOwner : workItems[0].lease_owner, claimedAt: new Date().toISOString(), workItems };
}

function submissionResults(result) {
  if (result?.ok !== true || !Array.isArray(result.submitted)) throw new Error("backfill submit command omitted checked submission results");
  for (const row of result.submitted) {
    // The mutation client throws on non-2xx. Some drivers additionally expose the
    // HTTP status; when they do, require the endpoint's exact success contract.
    if (row.httpStatus !== undefined && Number(row.httpStatus) !== 200) throw new Error(`backfill submit returned HTTP ${row.httpStatus}`);
    if (row.outcome === "needs_operator" || row.outcome === "challenged") throw new Error(`backfill submit returned ${row.outcome}`);
  }
  return result.submitted;
}

async function runLane(plan, lane, driver, semanticGuard, globalStop) {
  await mkdir(lane.directory, { recursive: true });
  const store = HEADLESS_BACKFILL_STORES.find((candidate) => candidate.key === lane.key);
  const producerClaimFile = path.join(lane.directory, "producer-claim.json");
  const producerChunkFile = path.join(lane.directory, "producer-chunk.json");
  const producerWrapperFile = path.join(lane.directory, "producer-wrappers.json");
  let producedCount = 0;
  let verified = 0;
  try {
    if (globalStop.signal.aborted) throw globalStop.signal.reason;
    const producerClaimResult = await driver.claimProducer(store, lane, plan);
    const producerClaim = claimDocument(producerClaimResult, lane, "producer");
    if (!producerClaim) return { store: lane.key, state: "idle", produced: 0, verified: 0 };
    await writeFile(producerClaimFile, `${JSON.stringify(producerClaim, null, 2)}\n`, "utf8");
    const producerChunk = assertCheckedHeadlessChunk(await driver.capture(store, producerClaim, producerChunkFile));
    if (globalStop.signal.aborted) throw globalStop.signal.reason;
    const producerGeneration = `headless-${lane.key}-producer-generation-${plan.waveId}-${randomUUID()}`;
    const producerSession = `headless-${lane.key}-producer-session-${plan.waveId}-${randomUUID()}`;
    const producerSubmit = await driver.submit("producer", producerClaimFile, producerChunkFile, producerGeneration, producerSession, producerWrapperFile);
    const produced = submissionResults(producerSubmit);
    producedCount = produced.length;
    const workById = new Map(producerClaim.workItems.map((work) => [work.id, work]));
    for (const row of produced) {
      const work = workById.get(row.producerWorkItemId ?? row.workItemId) ?? producerClaim.workItems.find((item) => item.id === row.workItemId);
      const defect = semanticGuard({ store, workItem: work ?? producerClaim.workItems[0], submission: row });
      if (defect) { globalStop.abort(new Error(`systematic semantic defect: ${JSON.stringify(defect)}`)); throw globalStop.signal.reason; }
    }
    for (const [index, row] of produced.entries()) {
      if (globalStop.signal.aborted) throw globalStop.signal.reason;
      if (!row.verifierWorkItemId) throw new Error("producer result omitted exact verifier work item");
      const verifierClaimFile = path.join(lane.directory, `verifier-${String(index).padStart(3, "0")}-claim.json`);
      const verifierChunkFile = path.join(lane.directory, `verifier-${String(index).padStart(3, "0")}-chunk.json`);
      const verifierWrapperFile = path.join(lane.directory, `verifier-${String(index).padStart(3, "0")}-wrapper.json`);
      const verifierClaimResult = await driver.claimVerifierExact(store, lane, row.verifierWorkItemId, index, verifierClaimFile);
      const verifierClaim = claimDocument(verifierClaimResult, lane, "verifier");
      if (!verifierClaim || verifierClaim.workItems.length !== 1 || verifierClaim.workItems[0].id !== row.verifierWorkItemId) throw new Error("exact verifier claim fence mismatch");
      await writeFile(verifierClaimFile, `${JSON.stringify(verifierClaim, null, 2)}\n`, "utf8");
      const verifierChunk = assertCheckedHeadlessChunk(await driver.capture(store, verifierClaim, verifierChunkFile));
      if (globalStop.signal.aborted) throw globalStop.signal.reason;
      if (Date.parse(verifierChunk.canary?.observedAt) <= Date.parse(producerChunk.canary?.observedAt)) throw new Error("verifier capture is not later than producer capture");
      const verifierGeneration = `headless-${lane.key}-verifier-generation-${plan.waveId}-${randomUUID()}`;
      const verifierSession = `headless-${lane.key}-verifier-session-${plan.waveId}-${randomUUID()}`;
      const verifierSubmit = submissionResults(await driver.submit("verifier", verifierClaimFile, verifierChunkFile,
        verifierGeneration, verifierSession, verifierWrapperFile));
      if (verifierSubmit.length !== 1) throw new Error("exact verifier submission count mismatch");
      verified += 1;
    }
    return { store: lane.key, state: "complete", produced: produced.length, verified };
  } catch (error) {
    return { store: lane.key, state: globalStop.signal.aborted ? "globally_stopped" : "stopped", produced: producedCount, verified,
      error: error instanceof Error ? error.message : String(error) };
  }
}

export async function runHeadlessBackfillCoordinator({ plan, driver, semanticGuard }) {
  const globalStop = new AbortController();
  const lanes = await Promise.all(plan.stores.map((lane) => runLane(plan, lane, driver, semanticGuard, globalStop)));
  return { ok: !globalStop.signal.aborted && lanes.every((lane) => ["complete", "idle"].includes(lane.state)),
    kind: "v4-flags-off-headless-backfill-result", runId: plan.runId, waveId: plan.waveId,
    globallyStopped: globalStop.signal.aborted, globalReason: globalStop.signal.reason?.message ?? null, lanes };
}

function parseArgs(values) {
  const result = {};
  for (let index = 0; index < values.length; index += 1) {
    const key = values[index];
    if (key === "--dry-run") result.dryRun = true;
    else if (key?.startsWith("--")) result[key.slice(2)] = values[++index];
  }
  return result;
}

export async function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  const plan = planHeadlessBackfill({ runId: args["run-id"], outputDirectory: args["output-dir"], limit: Number(args.limit ?? 5), waveId: args["wave-id"] });
  await mkdir(plan.outputDirectory, { recursive: true });
  await writeFile(path.join(plan.outputDirectory, "plan.json"), `${JSON.stringify(plan, null, 2)}\n`, "utf8");
  if (args.dryRun) { process.stdout.write(`${JSON.stringify({ ok: true, dryRun: true, plan }, null, 2)}\n`); return; }
  const [commodities, knownWrong] = await Promise.all([
    readFile(path.join(ROOT, "config", "commodities.json"), "utf8").then(JSON.parse),
    readFile(path.join(ROOT, "config", "known-wrong.json"), "utf8").then(JSON.parse),
  ]);
  const result = await runHeadlessBackfillCoordinator({ plan, driver: createSubprocessDriver(), semanticGuard: createSemanticGuard(commodities, knownWrong) });
  await writeFile(path.join(plan.outputDirectory, "result.json"), `${JSON.stringify(result, null, 2)}\n`, "utf8");
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  if (!result.ok) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) await main();
