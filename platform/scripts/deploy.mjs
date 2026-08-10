import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { DEFAULT_DEPLOYMENT_ENDPOINTS, waitForDeploymentConvergence } from "./verify-deployment.mjs";

const git = spawnSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" });
if (git.status !== 0) throw new Error("deployment requires a readable git commit");
const commit = git.stdout.trim();
if (!/^[a-f0-9]{40}$/.test(commit)) throw new Error("deployment commit is invalid");
const wranglerCli = fileURLToPath(new URL("../bin/wrangler.js", import.meta.resolve("wrangler")));
const deployArguments = process.argv.slice(2);
const deployed = spawnSync(process.execPath, [wranglerCli, "deploy", ...deployArguments, "--var", `DEPLOYED_COMMIT:${commit}`], {
  stdio: "inherit",
});
if (deployed.status !== 0) process.exit(deployed.status ?? 1);
if (!deployArguments.includes("--dry-run")) {
  const endpoints = process.env.TC_DEPLOY_VERIFY_URLS
    ? process.env.TC_DEPLOY_VERIFY_URLS.split(",").map((value) => value.trim()).filter(Boolean)
    : DEFAULT_DEPLOYMENT_ENDPOINTS;
  const verification = await waitForDeploymentConvergence({
    expectedCommit: commit,
    endpoints,
    timeoutMs: Number(process.env.TC_DEPLOY_VERIFY_TIMEOUT_MS ?? 90_000),
  });
  console.log(JSON.stringify({ deploymentConverged: true, ...verification }));
}
