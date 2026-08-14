import { spawn } from "node:child_process";

const child = spawn("pnpm", ["tc", "ingredient", "supervisor"], { cwd: new URL("..", import.meta.url), stdio: "inherit", shell: process.platform === "win32" });
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => child.kill(signal));
child.on("exit", (code, signal) => process.exitCode = signal ? 1 : (code ?? 1));
