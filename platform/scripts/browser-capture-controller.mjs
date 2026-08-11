import http from "node:http";
import { appendFile, mkdir, readdir, rm, stat } from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";
import { acquireControllerLane, captureJournalPath, releaseLaneLease, writeLaneState } from "./browser-capture-adapters/capture-journal.mjs";

const host = "127.0.0.1";
const port = Number(process.env.TC_CAPTURE_CONTROLLER_PORT ?? 43763);
const platformRoot = path.resolve(import.meta.dirname, "..");
const pnpm = process.env.TC_PNPM_PATH || "pnpm";
const clientRoot = path.dirname(captureJournalPath());
const logRoot = path.join(clientRoot, "logs", "controller");
let queueCycle = null;

async function log(event, detail = {}) {
  await mkdir(logRoot, { recursive: true });
  const file = path.join(logRoot, `controller-${new Date().toISOString().slice(0, 10)}.jsonl`);
  await appendFile(file, `${JSON.stringify({ at: new Date().toISOString(), event, ...detail })}\n`, "utf8");
  const logs = (await readdir(logRoot, { withFileTypes: true })).filter((entry) => entry.isFile() && entry.name.startsWith("controller-")).sort((a, b) => b.name.localeCompare(a.name));
  await Promise.all(logs.slice(14).map((entry) => rm(path.join(logRoot, entry.name), { force: true })));
}

function runQueueCycle(reason = "scheduled") {
  if (queueCycle) return queueCycle;
  queueCycle = new Promise((resolve) => {
    const child = spawn(pnpm, ["tc", "capture", "queue", "drain"], {
      cwd: platformRoot,
      env: process.env,
      windowsHide: true,
      shell: process.platform === "win32",
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    let settled = false;
    child.stdout.on("data", (chunk) => { output = `${output}${chunk}`.slice(-8000); });
    child.stderr.on("data", (chunk) => { output = `${output}${chunk}`.slice(-8000); });
    child.on("close", async (code) => {
      if (settled) return;
      settled = true;
      await log("queue-cycle", { reason, code, output: output.slice(-4000) });
      queueCycle = null;
      resolve({ code });
    });
    child.on("error", async (error) => {
      if (settled) return;
      settled = true;
      await log("queue-cycle-error", { reason, detail: error.message });
      queueCycle = null;
      resolve({ code: -1 });
    });
  });
  return queueCycle;
}

async function jsonBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {};
}

function respond(response, status, value) {
  response.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
  response.end(JSON.stringify(value));
}

const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://${host}:${port}`);
    if (request.method === "GET" && url.pathname === "/v1/health") {
      const journal = captureJournalPath();
      const journalBytes = await stat(journal).then((value) => value.size).catch(() => 0);
      return respond(response, 200, { ok: true, pid: process.pid, journal, journalBytes, queueCycleActive: Boolean(queueCycle) });
    }
    const lane = url.pathname.match(/^\/v1\/lanes\/(aldi|fareway|sams|walmart)\/(acquire|release|result)$/);
    if (request.method === "POST" && lane) {
      const [, store, action] = lane;
      const body = await jsonBody(request);
      if (action === "acquire") {
        const result = acquireControllerLane(store, String(body.owner ?? ""), new Date(), Math.min(30 * 60_000, Math.max(60_000, Number(body.ttlMs) || 15 * 60_000)));
        await log("lane-acquire", { store, owner: body.owner, ...result });
        return respond(response, result.acquired ? 200 : 409, result);
      }
      if (action === "release") {
        releaseLaneLease(store, String(body.owner ?? ""));
        await log("lane-release", { store, owner: body.owner });
        return respond(response, 200, { ok: true });
      }
      writeLaneState(store, body);
      return respond(response, 200, { ok: true });
    }
    if (request.method === "POST" && url.pathname === "/v1/queue/wake") {
      void runQueueCycle("wake");
      return respond(response, 202, { ok: true, accepted: true });
    }
    respond(response, 404, { ok: false, error: "not found" });
  } catch (error) {
    await log("request-error", { detail: error instanceof Error ? error.message : String(error) });
    respond(response, 500, { ok: false, error: "controller request failed" });
  }
});

server.listen(port, host, async () => {
  await log("started", { pid: process.pid, host, port });
  void runQueueCycle("startup");
});

const interval = setInterval(() => void runQueueCycle("interval"), 5 * 60_000);
interval.unref();
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => server.close(() => process.exit(0)));
