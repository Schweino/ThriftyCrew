import { acquireLaneLease, readLaneState, releaseLaneLease, writeLaneState } from "./capture-journal.mjs";
import { captureControllerRequest } from "../capture-controller-client.mjs";

const DEFAULTS = {
  aldi: { maxTerms: 3, minimumDelayMs: 5_000 },
  fareway: { maxTerms: 4, minimumDelayMs: 2_000 },
  sams: { maxTerms: 3, minimumDelayMs: 3_000 },
  walmart: { maxTerms: 5, minimumDelayMs: 1_500 },
};

async function controllerRequest(pathname, init = {}, environment = process.env) {
  const body = typeof init.body === "string" ? JSON.parse(init.body) : {};
  return captureControllerRequest(pathname, body, environment, 750);
}

export async function browserLanePolicy(store, now = new Date(), environment = process.env) {
  const defaults = DEFAULTS[store];
  if (!defaults) throw new Error(`unsupported browser lane ${store}`);
  const state = readLaneState(store, { consecutiveFailures: 0, dynamicDelayMs: defaults.minimumDelayMs, circuitOpenUntil: null }, environment);
  if (state.circuitOpenUntil && Date.parse(state.circuitOpenUntil) > now.getTime()) throw new Error(`${store} browser lane circuit is open until ${state.circuitOpenUntil}`);
  return { ...defaults, dynamicDelayMs: Math.max(defaults.minimumDelayMs, Number(state.dynamicDelayMs) || 0), state };
}

export async function recordBrowserLaneResult(store, outcome, latencyMs, now = new Date(), environment = process.env) {
  const policy = await browserLanePolicy(store, now, environment).catch((error) => {
    if (!String(error?.message).includes("circuit is open")) throw error;
    return { ...DEFAULTS[store], dynamicDelayMs: DEFAULTS[store].minimumDelayMs, state: { consecutiveFailures: 0 } };
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
  writeLaneState(store, next, environment);
  await controllerRequest(`/v1/lanes/${encodeURIComponent(store)}/result`, { method: "POST", body: JSON.stringify(next) }, environment);
  if (outcome === "blocked") await controllerRequest("/v1/challenges/open", { method: "POST", body: JSON.stringify({
    store, detail: { reason: `${store} browser adapter detected a retailer human-verification wall`, latencyMs, observedAt: now.toISOString() },
  }) }, environment);
  return next;
}

export async function withBrowserStoreLane(store, operation, environment = process.env) {
  const owner = `adapter-${process.pid}-${crypto.randomUUID()}`;
  const controller = await controllerRequest(`/v1/lanes/${encodeURIComponent(store)}/acquire`, { method: "POST", body: JSON.stringify({ owner, ttlMs: 15 * 60_000 }) }, environment);
  const controllerOwned = controller?.acquired === true;
  if (controller?.controllerReachable && !controllerOwned) throw new Error(`${store} browser lane is unavailable: ${controller.reason ?? "controller rejected the lease"}`);
  if (!controller && !acquireLaneLease(store, owner, new Date(), 15 * 60_000, environment)) throw new Error(`${store} browser lane already has an active capture`);
  const heartbeat = controllerOwned ? setInterval(() => {
    void controllerRequest(`/v1/lanes/${encodeURIComponent(store)}/acquire`, { method: "POST", body: JSON.stringify({ owner, ttlMs: 15 * 60_000 }) }, environment);
  }, 60_000) : null;
  heartbeat?.unref?.();
  try { return await operation(await browserLanePolicy(store, new Date(), environment)); }
  catch (error) {
    if (/challenge|block page|human.verification|captcha/i.test(String(error?.message ?? error))) {
      await controllerRequest("/v1/challenges/open", { method: "POST", body: JSON.stringify({ store, detail: { reason: String(error?.message ?? error) } }) }, environment);
    }
    throw error;
  }
  finally {
    if (heartbeat) clearInterval(heartbeat);
    if (controllerOwned) await controllerRequest(`/v1/lanes/${encodeURIComponent(store)}/release`, { method: "POST", body: JSON.stringify({ owner }) }, environment);
    else releaseLaneLease(store, owner, environment);
  }
}
