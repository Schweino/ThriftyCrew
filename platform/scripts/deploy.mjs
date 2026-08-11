import { spawnSync } from "node:child_process";
import { createHash, createHmac, randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { DEFAULT_DEPLOYMENT_ENDPOINTS, waitForDeploymentConvergence } from "./verify-deployment.mjs";

const git = spawnSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" });
if (git.status !== 0) throw new Error("deployment requires a readable git commit");
const commit = git.stdout.trim();
if (!/^[a-f0-9]{40}$/.test(commit)) throw new Error("deployment commit is invalid");
const wranglerCli = fileURLToPath(new URL("../bin/wrangler.js", import.meta.resolve("wrangler")));
const deployArguments = process.argv.slice(2);
let deploymentLease;

function parseVars(source) {
  return Object.fromEntries(source.split(/\r?\n/).flatMap((line) => {
    const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (!match) return [];
    let value = match[2];
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
    return [[match[1], value]];
  }));
}

async function deploymentCredential() {
  if (process.env.TC_LOCAL_MUTATION_SECRET) return { agentId: process.env.TC_AGENT_ID ?? "local-operator", secret: process.env.TC_LOCAL_MUTATION_SECRET };
  try {
    const vars = parseVars(await readFile(new URL("../.dev.vars", import.meta.url), "utf8"));
    const keys = JSON.parse(vars.MUTATION_KEYS ?? "{}");
    const local = keys["local-operator"];
    if (typeof local === "string") return { agentId: "local-operator", secret: local };
    if (local && typeof local.secret === "string" && local.role === "operator") return { agentId: "local-operator", secret: local.secret };
  } catch { /* A non-local deploy may use an explicitly supplied credential. */ }
  throw new Error("safe deployment requires TC_LOCAL_MUTATION_SECRET or local-operator in .dev.vars");
}

async function signedMutation(pathname, payload) {
  const { agentId, secret } = await deploymentCredential();
  const origin = process.env.TC_API_ORIGIN ?? "https://tc-grocery-v3.curly-unit-51a6.workers.dev";
  const body = JSON.stringify(payload);
  const bodyHash = createHash("sha256").update(body).digest("hex");
  const timestamp = new Date().toISOString();
  const nonce = `nonce_${randomUUID()}`;
  const canonical = [timestamp, nonce, "POST", pathname, bodyHash].join("\n");
  const response = await fetch(new URL(pathname, origin), {
    method: "POST",
    headers: {
      "content-type": "application/json", "x-tc-agent": agentId, "x-tc-timestamp": timestamp,
      "x-tc-nonce": nonce, "x-tc-signature": createHmac("sha256", secret).update(canonical).digest("hex"),
    },
    body,
  });
  const result = await response.json().catch(() => ({ ok: false, error: "non-JSON preflight response" }));
  return { response, result };
}

if (!deployArguments.includes("--dry-run")) {
  const { response, result } = await signedMutation("/internal/deployments/preflight", { sourceCommit: commit });
  const bootstrap = process.env.TC_DEPLOY_PREFLIGHT_BOOTSTRAP === "1" && response.status === 404;
  if (!response.ok && !bootstrap) {
    console.error(JSON.stringify({ deploymentBlocked: true, httpStatus: response.status, ...result }));
    process.exit(75);
  }
  console.log(JSON.stringify(bootstrap ? { deploymentPreflight: "bootstrap" } : { deploymentPreflight: "clear", ...result }));
  if (!bootstrap) deploymentLease = { checkId: result.checkId, fence: result.deploymentLease?.fence };
}

const deployed = spawnSync(process.execPath, [wranglerCli, "deploy", ...deployArguments, "--var", `DEPLOYED_COMMIT:${commit}`], {
  stdio: "inherit",
});
if (deployed.status !== 0) {
  if (deploymentLease?.checkId && deploymentLease?.fence) {
    await signedMutation("/internal/deployments/complete", { ...deploymentLease, outcome: "failed" }).catch(() => undefined);
  }
  process.exit(deployed.status ?? 1);
}
if (!deployArguments.includes("--dry-run")) {
  const endpoints = process.env.TC_DEPLOY_VERIFY_URLS
    ? process.env.TC_DEPLOY_VERIFY_URLS.split(",").map((value) => value.trim()).filter(Boolean)
    : DEFAULT_DEPLOYMENT_ENDPOINTS;
  let verification;
  let verificationError;
  try {
    verification = await waitForDeploymentConvergence({
      expectedCommit: commit,
      endpoints,
      timeoutMs: Number(process.env.TC_DEPLOY_VERIFY_TIMEOUT_MS ?? 90_000),
    });
    console.log(JSON.stringify({ deploymentConverged: true, ...verification }));
  } catch (error) { verificationError = error; }
  if (deploymentLease?.checkId && deploymentLease?.fence) {
    const outcome = verificationError ? "failed" : "deployed";
    const completion = await signedMutation("/internal/deployments/complete", { ...deploymentLease, outcome });
    if (!completion.response.ok) throw new Error(`deployment drain lease was not released: ${JSON.stringify(completion.result)}`);
    console.log(JSON.stringify({ deploymentDrainReleased: true, ...completion.result }));
  }
  if (verificationError) throw verificationError;
}
