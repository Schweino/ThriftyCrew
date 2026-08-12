import path from "node:path";
import { fileURLToPath } from "node:url";

export const DEFAULT_DEPLOYMENT_ENDPOINTS = [
  "https://tc-grocery-public.curly-unit-51a6.workers.dev/api/v2/status",
  "https://www.thriftycrew.com/api/v2/status",
];

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

export async function waitForDeploymentConvergence(options) {
  const expectedCommit = options.expectedCommit;
  if (!/^[a-f0-9]{40}$/.test(expectedCommit)) throw new Error("deployment convergence requires a full git commit");
  const endpoints = options.endpoints ?? DEFAULT_DEPLOYMENT_ENDPOINTS;
  if (endpoints.length === 0) throw new Error("deployment convergence requires at least one endpoint");
  const fetchImpl = options.fetchImpl ?? fetch;
  const timeoutMs = options.timeoutMs ?? 90_000;
  const intervalMs = options.intervalMs ?? 2_000;
  const now = options.now ?? Date.now;
  const sleep = options.sleep ?? ((duration) => new Promise((resolve) => setTimeout(resolve, duration)));
  const startedAt = now();
  let rounds = 0;
  let latest = [];

  while (true) {
    rounds += 1;
    latest = await Promise.all(endpoints.map(async (endpoint) => {
      try {
        const url = new URL(endpoint);
        url.searchParams.set("deployment_probe", `${expectedCommit.slice(0, 12)}-${rounds}`);
        const response = await fetchImpl(url, {
          headers: { "cache-control": "no-cache", pragma: "no-cache" },
          signal: AbortSignal.timeout(Math.min(10_000, Math.max(1_000, timeoutMs))),
        });
        if (!response.ok) return { endpoint, ok: false, status: response.status, error: `HTTP ${response.status}` };
        const body = await response.json();
        const observedCommit = body?.deployment?.commit;
        return { endpoint, ok: observedCommit === expectedCommit, status: response.status, observedCommit: typeof observedCommit === "string" ? observedCommit : null };
      } catch (error) {
        return { endpoint, ok: false, status: null, error: errorMessage(error) };
      }
    }));
    if (latest.every((result) => result.ok)) {
      return { ok: true, expectedCommit, rounds, elapsedMs: now() - startedAt, endpoints: latest };
    }
    if (now() - startedAt >= timeoutMs) {
      throw new Error(`deployment did not converge to ${expectedCommit} within ${timeoutMs}ms: ${JSON.stringify(latest)}`);
    }
    await sleep(intervalMs);
  }
}

async function selfTest() {
  const expectedCommit = "a".repeat(40);
  const endpointCalls = new Map();
  let clock = 0;
  const result = await waitForDeploymentConvergence({
    expectedCommit,
    endpoints: ["https://worker.test/status", "https://route.test/status"],
    timeoutMs: 100,
    intervalMs: 5,
    now: () => clock,
    sleep: async (duration) => { clock += duration; },
    fetchImpl: async (url) => {
      const endpoint = `${url.origin}${url.pathname}`;
      const calls = (endpointCalls.get(endpoint) ?? 0) + 1;
      endpointCalls.set(endpoint, calls);
      return new Response(JSON.stringify({ deployment: { commit: calls === 1 ? "b".repeat(40) : expectedCommit } }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    },
  });
  if (!result.ok || result.rounds !== 2 || result.endpoints.length !== 2) throw new Error("deployment convergence self-test failed");

  let timedOut = false;
  clock = 0;
  try {
    await waitForDeploymentConvergence({
      expectedCommit,
      endpoints: ["https://stale.test/status"],
      timeoutMs: 10,
      intervalMs: 5,
      now: () => clock,
      sleep: async (duration) => { clock += duration; },
      fetchImpl: async () => new Response(JSON.stringify({ deployment: { commit: "b".repeat(40) } }), { status: 200 }),
    });
  } catch (error) {
    timedOut = errorMessage(error).includes("did not converge");
  }
  if (!timedOut) throw new Error("deployment convergence timeout self-test failed");
  return { ok: true, rounds: result.rounds, endpoints: result.endpoints.length, timeoutRejected: timedOut };
}

const invokedDirectly = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  if (process.argv[2] !== "--self-test") throw new Error("use scripts/verify-deployment.mjs --self-test; deployments invoke this module automatically");
  console.log(JSON.stringify(await selfTest()));
}
