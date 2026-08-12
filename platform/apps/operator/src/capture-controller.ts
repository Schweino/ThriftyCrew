import net from "node:net";
import { appendFile, mkdir, readdir, rm, stat } from "node:fs/promises";
import path from "node:path";
import { drainBrowserCaptureQueue } from "./capture-drainer";
import { captureJournalPath } from "./capture-journal";
import { checkpointCaptureJournal } from "./capture-journal-checkpoint";
import { acquireControllerLane, releaseLaneLease, writeLaneState } from "../../../scripts/capture-journal.mjs";
import { CAPTURE_CONTROLLER_PIPE } from "../../../scripts/capture-controller-client.mjs";

const controllerToken = process.env.TC_CAPTURE_CONTROLLER_TOKEN;
if (!controllerToken || controllerToken.length < 32) throw new Error("TC_CAPTURE_CONTROLLER_TOKEN is required");
const clientRoot = path.dirname(captureJournalPath());
const logRoot = path.join(clientRoot, "logs", "controller");
type QueueCycleResult = Awaited<ReturnType<typeof drainBrowserCaptureQueue>> | { ok: false; error: string };
let queueCycle: Promise<QueueCycleResult> | null = null;

async function log(event: string, detail: Record<string, unknown> = {}): Promise<void> {
  await mkdir(logRoot, { recursive: true });
  const file = path.join(logRoot, `controller-${new Date().toISOString().slice(0, 10)}.jsonl`);
  await appendFile(file, `${JSON.stringify({ at: new Date().toISOString(), event, ...detail })}\n`, "utf8");
  const logs = (await readdir(logRoot, { withFileTypes: true })).filter((entry) => entry.isFile() && entry.name.startsWith("controller-")).sort((a, b) => b.name.localeCompare(a.name));
  await Promise.all(logs.slice(14).map((entry) => rm(path.join(logRoot, entry.name), { force: true })));
}

async function checkpoint(reason: string): Promise<void> {
  try {
    const result = await checkpointCaptureJournal();
    await log("journal-checkpoint", { reason, ...result });
  } catch (error) {
    await log("journal-checkpoint-error", { reason, detail: error instanceof Error ? error.message : String(error) });
  }
}

function runQueueCycle(reason = "scheduled"): Promise<QueueCycleResult> {
  if (queueCycle) return queueCycle;
  const cycle = drainBrowserCaptureQueue().then(async (result): Promise<QueueCycleResult> => {
    await log("queue-cycle", { reason, ...result });
    await checkpoint(reason);
    return result;
  }).catch(async (error) => {
    const detail = error instanceof Error ? error.message : String(error);
    await log("queue-cycle-error", { reason, detail });
    await checkpoint(`${reason}-error`);
    return { ok: false as const, error: detail };
  }).finally(() => { queueCycle = null; });
  queueCycle = cycle;
  return cycle;
}

async function dispatch(pathname: string, body: Record<string, unknown>): Promise<{ status: number; body: Record<string, unknown> }> {
  if (pathname === "/v1/health") {
    const journal = captureJournalPath();
    const journalBytes = await stat(journal).then((value) => value.size).catch(() => 0);
    return { status: 200, body: { ok: true, pid: process.pid, journal, journalBytes, queueCycleActive: Boolean(queueCycle), transport: "named-pipe" } };
  }
  const lane = pathname.match(/^\/v1\/lanes\/(aldi|fareway|sams|walmart)\/(acquire|release|result)$/);
  if (lane) {
    const [, store, action] = lane as [string, string, string];
    if (action === "acquire") {
      const result = acquireControllerLane(store, String(body.owner ?? ""), new Date(), Math.min(30 * 60_000, Math.max(60_000, Number(body.ttlMs) || 15 * 60_000)));
      await log("lane-acquire", { store, owner: body.owner, ...result });
      return { status: result.acquired ? 200 : 409, body: result };
    }
    if (action === "release") {
      releaseLaneLease(store, String(body.owner ?? ""));
      await log("lane-release", { store, owner: body.owner });
      return { status: 200, body: { ok: true } };
    }
    writeLaneState(store, body);
    return { status: 200, body: { ok: true } };
  }
  if (pathname === "/v1/queue/wake") {
    void runQueueCycle("wake");
    return { status: 202, body: { ok: true, accepted: true } };
  }
  return { status: 404, body: { ok: false, error: "not found" } };
}

const server = net.createServer((socket) => {
  let input = "";
  let handled = false;
  socket.setTimeout(2_000, () => socket.destroy());
  socket.on("data", async (chunk) => {
    if (handled) return;
    input += Buffer.from(chunk).toString("utf8");
    if (input.length > 64 * 1024) {
      handled = true;
      socket.end(`${JSON.stringify({ ok: false, status: 413, error: "controller request is too large" })}\n`);
      return;
    }
    const newline = input.indexOf("\n");
    if (newline < 0) return;
    handled = true;
    try {
      const request = JSON.parse(input.slice(0, newline)) as { token?: unknown; pathname?: unknown; body?: unknown };
      if (request.token !== controllerToken) {
        socket.end(`${JSON.stringify({ ok: false, status: 403, error: "forbidden" })}\n`);
        return;
      }
      const result = await dispatch(String(request.pathname ?? ""), request.body && typeof request.body === "object" ? request.body as Record<string, unknown> : {});
      socket.end(`${JSON.stringify({ ...result.body, status: result.status, controllerAccepted: result.status < 400 })}\n`);
    } catch (error) {
      await log("request-error", { detail: error instanceof Error ? error.message : String(error) });
      socket.end(`${JSON.stringify({ ok: false, status: 500, error: "controller request failed" })}\n`);
    }
  });
});

server.listen(CAPTURE_CONTROLLER_PIPE, async () => {
  await log("started", { pid: process.pid, pipe: CAPTURE_CONTROLLER_PIPE });
  void runQueueCycle("startup");
});
const interval = setInterval(() => void runQueueCycle("interval"), 5 * 60_000);
interval.unref();
for (const signal of ["SIGINT", "SIGTERM"] as const) process.on(signal, () => server.close(() => process.exit(0)));
