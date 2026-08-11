import { mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const DEFAULTS = {
  aldi: { maxTerms: 3, minimumDelayMs: 5_000 },
  fareway: { maxTerms: 4, minimumDelayMs: 2_000 },
  sams: { maxTerms: 3, minimumDelayMs: 3_000 },
  walmart: { maxTerms: 5, minimumDelayMs: 1_500 },
};

function rootDirectory(environment = process.env) {
  return path.join(environment.LOCALAPPDATA || os.tmpdir(), "ThriftyCrew", "grocery-v3", "browser-lanes");
}

async function atomicJson(file, value) {
  const temporary = `${file}.tmp-${crypto.randomUUID()}`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  await rename(temporary, file);
}

export async function browserLanePolicy(store, now = new Date(), environment = process.env) {
  const defaults = DEFAULTS[store];
  if (!defaults) throw new Error(`unsupported browser lane ${store}`);
  const root = rootDirectory(environment);
  await mkdir(root, { recursive: true });
  const stateFile = path.join(root, `${store}.json`);
  let state = { consecutiveFailures: 0, dynamicDelayMs: defaults.minimumDelayMs, circuitOpenUntil: null };
  try { state = { ...state, ...JSON.parse(await readFile(stateFile, "utf8")) }; } catch { /* first run */ }
  if (state.circuitOpenUntil && Date.parse(state.circuitOpenUntil) > now.getTime()) throw new Error(`${store} browser lane circuit is open until ${state.circuitOpenUntil}`);
  return { ...defaults, dynamicDelayMs: Math.max(defaults.minimumDelayMs, Number(state.dynamicDelayMs) || 0), stateFile, state };
}

export async function recordBrowserLaneResult(store, outcome, latencyMs, now = new Date(), environment = process.env) {
  const policy = await browserLanePolicy(store, now, environment).catch((error) => {
    if (!String(error?.message).includes("circuit is open")) throw error;
    return { ...DEFAULTS[store], dynamicDelayMs: DEFAULTS[store].minimumDelayMs, stateFile: path.join(rootDirectory(environment), `${store}.json`), state: { consecutiveFailures: 0 } };
  });
  const failure = outcome === "blocked" || outcome === "rejected";
  const consecutiveFailures = failure ? Number(policy.state.consecutiveFailures || 0) + 1 : 0;
  const dynamicDelayMs = failure
    ? Math.min(30_000, Math.max(policy.dynamicDelayMs, policy.minimumDelayMs) * 2)
    : Math.max(policy.minimumDelayMs, Math.round(Math.max(policy.minimumDelayMs, policy.dynamicDelayMs) * 0.85));
  const circuitMinutes = outcome === "blocked" ? 30 : consecutiveFailures >= 3 ? 5 : 0;
  const next = {
    store, consecutiveFailures, dynamicDelayMs, lastOutcome: outcome,
    lastLatencyMs: Math.max(0, Math.round(latencyMs)), lastCompletedAt: now.toISOString(),
    circuitOpenUntil: circuitMinutes ? new Date(now.getTime() + circuitMinutes * 60_000).toISOString() : null,
  };
  await mkdir(path.dirname(policy.stateFile), { recursive: true });
  await atomicJson(policy.stateFile, next);
  return next;
}

export async function withBrowserStoreLane(store, operation, environment = process.env) {
  const root = rootDirectory(environment);
  await mkdir(root, { recursive: true });
  const lock = path.join(root, `${store}.lock`);
  try {
    await mkdir(lock);
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    const ageMs = Date.now() - (await stat(lock)).mtimeMs;
    if (ageMs < 15 * 60_000) throw new Error(`${store} browser lane already has an active capture`);
    await rm(lock, { recursive: true, force: true });
    await mkdir(lock);
  }
  try { return await operation(await browserLanePolicy(store, new Date(), environment)); }
  finally { await rm(lock, { recursive: true, force: true }); }
}
