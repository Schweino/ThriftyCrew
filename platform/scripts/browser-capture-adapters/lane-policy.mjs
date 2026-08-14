import { acquireLaneLease, readLaneState, releaseLaneLease, writeLaneState } from "./capture-journal.mjs";
import { captureControllerRequest } from "../capture-controller-client.mjs";

const DEFAULTS = {
  aldi: { maxTerms: 3, minimumDelayMs: 5_000 },
  fareway: { maxTerms: 4, minimumDelayMs: 2_000 },
  sams: { maxTerms: 3, minimumDelayMs: 3_000 },
  walmart: { maxTerms: 5, minimumDelayMs: 1_500 },
};

const RUNTIME_PROCESS = globalThis.process ?? { env: {}, pid: 0 };

export function jitteredBrowserDelayMs(baseDelayMs, random = Math.random) {
  const base = Math.max(0, Math.round(Number(baseDelayMs) || 0));
  if (base === 0) return 0;
  const sample = Math.max(0, Math.min(1, Number(random()) || 0));
  return base + Math.round(base * (0.1 + sample * 0.15));
}

export function browserLaneStartDelayMs(policy, nowMs = Date.now(), random = Math.random) {
  const completedAt = Date.parse(String(policy?.state?.lastCompletedAt ?? ""));
  if (!Number.isFinite(completedAt)) return 0;
  return Math.max(0, completedAt + jitteredBrowserDelayMs(policy.dynamicDelayMs, random) - nowMs);
}

async function controllerRequest(pathname, init = {}, environment = RUNTIME_PROCESS.env) {
  const body = typeof init.body === "string" ? JSON.parse(init.body) : {};
  return captureControllerRequest(pathname, body, environment, 5_000, true);
}

export async function browserLanePolicy(store, now = new Date(), environment = RUNTIME_PROCESS.env) {
  const defaults = DEFAULTS[store];
  if (!defaults) throw new Error(`unsupported browser lane ${store}`);
  const state = readLaneState(store, { consecutiveFailures: 0, successStreak: 0, dynamicDelayMs: defaults.minimumDelayMs, dynamicMaxTerms: defaults.maxTerms, ewmaLatencyMs: 0, circuitOpenUntil: null }, environment);
  if (state.circuitOpenUntil && Date.parse(state.circuitOpenUntil) > now.getTime()) throw new Error(`${store} browser lane circuit is open until ${state.circuitOpenUntil}`);
  return {
    ...defaults,
    configuredMaxTerms: defaults.maxTerms,
    maxTerms: Math.max(1, Math.min(defaults.maxTerms, Number(state.dynamicMaxTerms) || defaults.maxTerms)),
    dynamicDelayMs: Math.max(defaults.minimumDelayMs, Number(state.dynamicDelayMs) || 0),
    state,
  };
}

export async function recordBrowserLaneResult(store, outcome, latencyMs, now = new Date(), environment = RUNTIME_PROCESS.env) {
  const policy = await browserLanePolicy(store, now, environment).catch((error) => {
    if (!String(error?.message).includes("circuit is open")) throw error;
    return { ...DEFAULTS[store], dynamicDelayMs: DEFAULTS[store].minimumDelayMs, state: { consecutiveFailures: 0 } };
  });
  const failure = outcome === "blocked" || outcome === "rejected";
  const consecutiveFailures = failure ? Number(policy.state.consecutiveFailures || 0) + 1 : 0;
  const successStreak = failure ? 0 : Number(policy.state.successStreak || 0) + 1;
  const previousEwma = Number(policy.state.ewmaLatencyMs || latencyMs);
  const ewmaLatencyMs = Math.max(0, Math.round(previousEwma * 0.8 + Math.max(0, latencyMs) * 0.2));
  const latencyPressure = ewmaLatencyMs > 10_000 ? 1.35 : ewmaLatencyMs > 6_000 ? 1.15 : 1;
  const dynamicDelayMs = failure
    ? Math.min(30_000, Math.max(policy.dynamicDelayMs, policy.minimumDelayMs) * 2)
    : Math.max(policy.minimumDelayMs, Math.min(30_000, Math.round(Math.max(policy.minimumDelayMs, policy.dynamicDelayMs) * 0.85 * latencyPressure)));
  const priorMaxTerms = Number(policy.state.dynamicMaxTerms || policy.maxTerms);
  const dynamicMaxTerms = failure ? Math.max(1, Math.floor(priorMaxTerms / 2))
    : successStreak >= 3 && ewmaLatencyMs < 8_000 ? Math.min(policy.configuredMaxTerms, priorMaxTerms + 1) : priorMaxTerms;
  const circuitMinutes = outcome === "blocked" ? 30 : consecutiveFailures >= 3 ? 5 : 0;
  const next = {
    store, consecutiveFailures, successStreak, dynamicDelayMs, dynamicMaxTerms, ewmaLatencyMs, lastOutcome: outcome,
    lastLatencyMs: Math.max(0, Math.round(latencyMs)), lastCompletedAt: now.toISOString(),
    circuitOpenUntil: circuitMinutes ? new Date(now.getTime() + circuitMinutes * 60_000).toISOString() : null,
  };
  writeLaneState(store, next, environment);
  await controllerRequest(`/v1/lanes/${encodeURIComponent(store)}/result`, { method: "POST", body: JSON.stringify(next) }, environment);
  if (outcome === "blocked") await controllerRequest("/v1/challenges/open", { method: "POST", body: JSON.stringify({
    store, detail: { reason: `${store} browser adapter detected a retailer human-verification wall`, latencyMs, observedAt: now.toISOString() },
  }) }, environment);
  return next;
}

export async function withBrowserStoreLane(store, operation, environment = RUNTIME_PROCESS.env) {
  const owner = `adapter-${RUNTIME_PROCESS.pid}-${crypto.randomUUID()}`;
  const controller = await controllerRequest(`/v1/lanes/${encodeURIComponent(store)}/acquire`, { method: "POST", body: JSON.stringify({ owner, ttlMs: 15 * 60_000 }) }, environment);
  const controllerOwned = controller?.acquired === true;
  if (controller?.controllerReachable && !controllerOwned) throw new Error(`${store} browser lane is unavailable: ${controller.reason ?? "controller rejected the lease"}`);
  if (!controller && !acquireLaneLease(store, owner, new Date(), 15 * 60_000, environment)) throw new Error(`${store} browser lane already has an active capture`);
  const heartbeat = controllerOwned ? setInterval(() => {
    void controllerRequest(`/v1/lanes/${encodeURIComponent(store)}/acquire`, { method: "POST", body: JSON.stringify({ owner, ttlMs: 15 * 60_000 }) }, environment);
  }, 60_000) : null;
  heartbeat?.unref?.();
  try {
    const policy = await browserLanePolicy(store, new Date(), environment);
    const startDelayMs = browserLaneStartDelayMs(policy);
    if (startDelayMs > 0) await new Promise((resolve) => setTimeout(resolve, startDelayMs));
    return await operation(policy);
  }
  catch (error) {
    if (/challenge|block page|human.verification|captcha/i.test(String(error?.message ?? error))) {
      await controllerRequest("/v1/challenges/open", { method: "POST", body: JSON.stringify({ store, detail: { reason: String(error?.message ?? error) } }) }, environment);
    }
    throw error;
  }
  finally {
    if (heartbeat) clearInterval(heartbeat);
    if (controllerOwned) {
      const released = await controllerRequest(`/v1/lanes/${encodeURIComponent(store)}/release`, { method: "POST", body: JSON.stringify({ owner }) }, environment);
      if (!released?.controllerReachable) releaseLaneLease(store, owner, environment);
    } else releaseLaneLease(store, owner, environment);
  }
}
