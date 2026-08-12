import net from "node:net";
import { spawn } from "node:child_process";
import { appendFile, mkdir, readdir, rm, stat } from "node:fs/promises";
import path from "node:path";
import { drainBrowserCaptureQueue } from "./capture-drainer";
import { browserCaptureCycleStatus, defaultCaptureQueueRoot, hydrateCaptureQueueJournal } from "./capture-queue";
import { appendCaptureChunk, captureSessionStatus, retainCaptureSessionEvidence } from "./capture-session";
import { captureJournalPath } from "./capture-journal";
import { checkpointCaptureJournal } from "./capture-journal-checkpoint";
import { acknowledgeCaptureChallenge, acquireControllerLane, browserCaptureJournalDueState, captureCoordinatorStatus, failCaptureWork, heartbeatCaptureWork, leaseCaptureWork, openCaptureChallenge, recordStoreRateResult, releaseLaneLease, resolveCaptureChallenge, writeLaneState } from "../../../scripts/capture-journal.mjs";
import { CAPTURE_CONTROLLER_PIPE } from "../../../scripts/capture-controller-client.mjs";

const controllerToken = process.env.TC_CAPTURE_CONTROLLER_TOKEN;
if (!controllerToken || controllerToken.length < 32) throw new Error("TC_CAPTURE_CONTROLLER_TOKEN is required");
const clientRoot = path.dirname(captureJournalPath());
const logRoot = path.join(clientRoot, "logs", "controller");
type QueueCycleResult = Awaited<ReturnType<typeof drainBrowserCaptureQueue>> | { ok: false; error: string };
let queueCycle: Promise<QueueCycleResult> | null = null;
let checkpointTimer: NodeJS.Timeout | null = null;
const checkpointReasons = new Set<string>();
let lastCheckpointAt = 0;

function raiseChallengePrompt(challengeId: string, store: string, detail: string): void {
  const notifier = path.resolve(import.meta.dirname, "../../../../grocery/notify-desktop.ps1");
  const storeLabel = store === "sams" ? "Sam's Club" : store === "aldi" ? "ALDI" : store[0]!.toUpperCase() + store.slice(1);
  const child = spawn("powershell.exe", ["-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", notifier,
    "-Store", storeLabel, "-Detail", detail, "-AlsoEmail", "-ControllerChallengeId", challengeId], {
    detached: true, stdio: "ignore", windowsHide: true,
  });
  child.unref();
}

async function log(event: string, detail: Record<string, unknown> = {}): Promise<void> {
  await mkdir(logRoot, { recursive: true });
  const file = path.join(logRoot, `controller-${new Date().toISOString().slice(0, 10)}.jsonl`);
  await appendFile(file, `${JSON.stringify({ at: new Date().toISOString(), event, ...detail })}\n`, "utf8");
  const logs = (await readdir(logRoot, { withFileTypes: true })).filter((entry) => entry.isFile() && entry.name.startsWith("controller-")).sort((a, b) => b.name.localeCompare(a.name));
  await Promise.all(logs.slice(14).map((entry) => rm(path.join(logRoot, entry.name), { force: true })));
}

for (const [event, source] of [["uncaught-exception", "uncaughtException"], ["unhandled-rejection", "unhandledRejection"]] as const) {
  process.on(source, (error: unknown) => {
    const detail = error instanceof Error ? `${error.message}\n${error.stack ?? ""}` : String(error);
    void log(event, { detail }).finally(() => process.exit(1));
  });
}

async function checkpoint(reason: string): Promise<void> {
  try {
    const result = await checkpointCaptureJournal();
    await log("journal-checkpoint", { reason, ...result });
  } catch (error) {
    await log("journal-checkpoint-error", { reason, detail: error instanceof Error ? error.message : String(error) });
  }
}

function scheduleCheckpoint(reason: string): void {
  checkpointReasons.add(reason);
  if (checkpointTimer) return;
  const delay = Math.max(0, 30_000 - (Date.now() - lastCheckpointAt));
  checkpointTimer = setTimeout(() => {
    checkpointTimer = null;
    const reasons = [...checkpointReasons].join(",");
    checkpointReasons.clear();
    lastCheckpointAt = Date.now();
    void checkpoint(reasons || "debounced");
  }, delay);
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
  if (pathname === "/v1/cycle/status") {
    const now = body.now ? new Date(String(body.now)) : new Date();
    const journal = browserCaptureJournalDueState(now);
    return { status: 200, body: { ok: true, ...(journal ?? await browserCaptureCycleStatus(defaultCaptureQueueRoot(), now)), authority: journal ? "capture-journal" : "queue-reconciliation" } };
  }
  if (pathname === "/v1/coordinator/status") {
    return { status: 200, body: { ok: true, ...captureCoordinatorStatus() } };
  }
  if (pathname === "/v1/work/next") {
    const owner = String(body.owner ?? "").trim();
    if (!owner) return { status: 422, body: { ok: false, error: "work owner is required" } };
    const result = leaseCaptureWork(owner, body.store ? String(body.store) : undefined, new Date(), Number(body.ttlMs) || 5 * 60_000, undefined,
      Math.max(1, Math.min(5, Number(body.count) || 1)));
    await log("work-next", { owner, store: body.store, ...result });
    return { status: result.acquired ? 200 : 204, body: { ok: true, ...result } };
  }
  if (pathname === "/v1/work/heartbeat") {
    const result = heartbeatCaptureWork(String(body.owner ?? ""), String(body.workId ?? ""), new Date(), Number(body.ttlMs) || 5 * 60_000,
      body.metadata && typeof body.metadata === "object" ? body.metadata as Record<string, unknown> : {});
    return { status: result.renewed ? 200 : 409, body: { ok: Boolean(result.renewed), ...result } };
  }
  if (pathname === "/v1/work/fail") {
    const retryDelayMs = Math.max(1_000, Math.min(60 * 60_000, Number(body.retryDelayMs) || 60_000));
    failCaptureWork(String(body.owner ?? ""), String(body.workId ?? ""), String(body.error ?? "capture executor failed"), new Date(Date.now() + retryDelayMs));
    return { status: 200, body: { ok: true, retryAt: new Date(Date.now() + retryDelayMs).toISOString() } };
  }
  if (pathname === "/v1/sessions/commit-file") {
    const directory = path.resolve(String(body.directory ?? ""));
    const chunkFile = path.resolve(String(body.chunkFile ?? ""));
    const result = await appendCaptureChunk(directory, chunkFile);
    scheduleCheckpoint("chunk-commit");
    return { status: 200, body: { ok: true, ...result } };
  }
  if (pathname === "/v1/sessions/evidence-file") {
    const result = await retainCaptureSessionEvidence(path.resolve(String(body.directory ?? "")), path.resolve(String(body.evidenceFile ?? "")), String(body.kind ?? "screenshot"));
    scheduleCheckpoint("session-evidence");
    return { status: 200, body: result };
  }
  if (pathname === "/v1/sessions/status") {
    return { status: 200, body: await captureSessionStatus(path.resolve(String(body.directory ?? ""))) };
  }
  if (pathname === "/v1/challenges/open") {
    const store = String(body.store ?? "");
    if (!/^(aldi|fareway|sams|walmart)$/.test(store)) return { status: 422, body: { ok: false, error: "supported store is required" } };
    const detail = body.detail && typeof body.detail === "object" ? body.detail as Record<string, unknown> : { reason: String(body.reason ?? "retailer challenge detected") };
    const result = openCaptureChallenge(store, detail);
    if (!result.idempotent) raiseChallengePrompt(result.id, store, String(detail.reason ?? "A human-verification wall stopped this store lane. Clear it in Chrome, then click OK."));
    await log("challenge-open", { store, ...result, detail });
    scheduleCheckpoint("challenge-open");
    return { status: 201, body: { ok: true, ...result } };
  }
  const challenge = pathname.match(/^\/v1\/challenges\/([^/]+)\/(acknowledge|resolve)$/);
  if (challenge) {
    const [, id, action] = challenge;
    const result = action === "acknowledge" ? acknowledgeCaptureChallenge(id!) : resolveCaptureChallenge(id!, body.canaryPassed === true);
    await log(`challenge-${action}`, { id, ...result });
    scheduleCheckpoint(`challenge-${action}`);
    return { status: (result.acknowledged === false || result.resolved === false) ? 409 : 200, body: { ok: result.acknowledged !== false && result.resolved !== false, ...result } };
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
    recordStoreRateResult(store, String(body.lastOutcome ?? body.outcome ?? "success"), Number(body.lastLatencyMs ?? body.latencyMs) || 0);
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
  // Named-pipe clients use bounded request deadlines and may disconnect while
  // a durable commit/checkpoint is still finishing. EPIPE is a client-lifetime
  // event, not a daemon-fatal condition.
  socket.on("error", (error) => {
    void log("client-socket-error", { code: (error as NodeJS.ErrnoException).code ?? "unknown", detail: error.message });
  });
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
      const transportStatus = Object.hasOwn(result.body, "status") ? { httpStatus: result.status } : { status: result.status };
      socket.end(`${JSON.stringify({ ...result.body, ...transportStatus, controllerAccepted: result.status < 400 })}\n`);
    } catch (error) {
      await log("request-error", { detail: error instanceof Error ? error.message : String(error) });
      socket.end(`${JSON.stringify({ ok: false, status: 500, error: "controller request failed" })}\n`);
    }
  });
});

const hydration = await hydrateCaptureQueueJournal(defaultCaptureQueueRoot()).catch((error) => ({ checked: 0, hydrated: 0, errors: 1, detail: error instanceof Error ? error.message : String(error) }));
server.listen(CAPTURE_CONTROLLER_PIPE, async () => {
  await log("started", { pid: process.pid, pipe: CAPTURE_CONTROLLER_PIPE });
  await log("journal-hydration", hydration);
  void runQueueCycle("startup");
});
const interval = setInterval(() => void runQueueCycle("interval"), 5 * 60_000);
interval.unref();
for (const signal of ["SIGINT", "SIGTERM"] as const) process.on(signal, () => {
  if (checkpointTimer) clearTimeout(checkpointTimer);
  void checkpoint(`shutdown-${signal}`).finally(() => server.close(() => process.exit(0)));
});
