import { spawnSync } from "node:child_process";

const git = spawnSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" });
if (git.status !== 0) throw new Error("deployment requires a readable git commit");
const commit = git.stdout.trim();
if (!/^[a-f0-9]{40}$/.test(commit)) throw new Error("deployment commit is invalid");
const command = process.platform === "win32" ? "wrangler.cmd" : "wrangler";
const deployed = spawnSync(command, ["deploy", ...process.argv.slice(2), "--var", `DEPLOYED_COMMIT:${commit}`], {
  stdio: "inherit",
  shell: process.platform === "win32",
});
if (deployed.status !== 0) process.exit(deployed.status ?? 1);
