import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const git = spawnSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" });
if (git.status !== 0) throw new Error("deployment requires a readable git commit");
const commit = git.stdout.trim();
if (!/^[a-f0-9]{40}$/.test(commit)) throw new Error("deployment commit is invalid");
const wranglerCli = fileURLToPath(new URL("../bin/wrangler.js", import.meta.resolve("wrangler")));
const deployed = spawnSync(process.execPath, [wranglerCli, "deploy", ...process.argv.slice(2), "--var", `DEPLOYED_COMMIT:${commit}`], {
  stdio: "inherit",
});
if (deployed.status !== 0) process.exit(deployed.status ?? 1);
