import { copyFile, mkdir, readFile, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { BROWSER_CAPTURE_ACCURACY_CUTOVER, browserCaptureSessionSchema, directCaptureArtifactSchema, type DirectCaptureArtifact } from "@thriftycrew/contracts";
import { buildBrowserCaptureAccuracy, digestHex, stableJson } from "@thriftycrew/domain";

export interface QueuedEvidence {
  file: string;
  sha256: string;
  kind: "screenshot" | "flyer_page" | "raw_payload" | "manifest";
  contentType: string;
}

export interface CaptureQueueManifest {
  version: 1;
  id: string;
  sourceId: string;
  idempotencyKey: string;
  artifactFile: string;
  artifactSha256: string;
  evidence: QueuedEvidence[];
  enqueuedAt: string;
  status: "pending" | "retrying" | "completed" | "rejected";
  attempts: number;
  nextAttemptAt: string;
  lastAttemptAt?: string;
  lastError?: string;
  completedAt?: string;
  receipt?: Record<string, unknown>;
}

export interface CaptureQueueJob {
  directory: string;
  artifactPath: string;
  evidencePaths: Array<QueuedEvidence & { path: string }>;
  manifest: CaptureQueueManifest;
  artifact: DirectCaptureArtifact;
}

export interface CaptureQueueStatus {
  ok: boolean;
  root: string;
  pending: number;
  retrying: number;
  completed: number;
  rejected: number;
  total: number;
  oldestPendingAt: string | null;
  oldestPendingMinutes: number | null;
  highestAttempts: number;
  unhealthyJobs: Array<{ id: string; sourceId: string; attempts: number; ageMinutes: number; lastError?: string }>;
}

export interface BrowserCaptureCycleStatus {
  status: "fresh" | "inflight" | "due";
  weekStart: string;
  previousWeekStart: string;
  due: string[];
  inflight: string[];
  completed: string[];
  overdue: string[];
  alertDue: boolean;
}

export const REQUIRED_BROWSER_CAPTURE_SOURCES = [
  "direct-aldi-browser",
  "direct-fareway-browser",
  "direct-sams-browser",
  "direct-walmart-browser",
] as const;
export const STRICT_BROWSER_COVERAGE_START = "2026-08-12";

const IMAGE_EXTENSIONS = new Map([
  [".png", "image/png"],
  [".jpg", "image/jpeg"],
  [".jpeg", "image/jpeg"],
  [".webp", "image/webp"],
]);

export class PermanentCaptureError extends Error {
  override readonly name = "PermanentCaptureError";
}

function nowIso(now: Date | undefined): string {
  return (now ?? new Date()).toISOString();
}

function centralParts(date: Date): { dateKey: string; weekday: number; hour: number } {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Chicago", hour12: false, year: "numeric", month: "2-digit", day: "2-digit", weekday: "short", hour: "2-digit",
  }).formatToParts(date);
  const value = Object.fromEntries(parts.filter((part) => part.type !== "literal").map((part) => [part.type, part.value]));
  const weekdays: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  return { dateKey: `${value.year}-${value.month}-${value.day}`, weekday: weekdays[value.weekday!]!, hour: Number(value.hour) % 24 };
}

function shiftDateKey(dateKey: string, days: number): string {
  const [year, month, day] = dateKey.split("-").map(Number);
  return new Date(Date.UTC(year!, month! - 1, day! + days)).toISOString().slice(0, 10);
}

function centralDateKey(date: Date): string {
  return centralParts(date).dateKey;
}

function evidenceKind(file: string): QueuedEvidence["kind"] {
  const extension = path.extname(file).toLowerCase();
  if (IMAGE_EXTENSIONS.has(extension)) return "screenshot";
  return /(?:session|manifest)/i.test(path.basename(file)) ? "manifest" : "raw_payload";
}

function contentType(file: string): string {
  const extension = path.extname(file).toLowerCase();
  return IMAGE_EXTENSIONS.get(extension) ?? (extension === ".csv" ? "text/csv; charset=utf-8" : extension === ".jsonl" ? "application/x-ndjson" : extension === ".txt" ? "text/plain; charset=utf-8" : "application/json");
}

function uint16(bytes: Uint8Array, offset: number, littleEndian: boolean): number {
  return littleEndian ? bytes[offset]! | bytes[offset + 1]! << 8 : bytes[offset]! << 8 | bytes[offset + 1]!;
}

function uint24le(bytes: Uint8Array, offset: number): number {
  return bytes[offset]! | bytes[offset + 1]! << 8 | bytes[offset + 2]! << 16;
}

function uint32be(bytes: Uint8Array, offset: number): number {
  return ((bytes[offset]! << 24) | (bytes[offset + 1]! << 16) | (bytes[offset + 2]! << 8) | bytes[offset + 3]!) >>> 0;
}

function imageDimensions(bytes: Uint8Array, extension: string): { width: number; height: number } {
  if (extension === ".png") {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 24 || !signature.every((value, index) => bytes[index] === value) || new TextDecoder().decode(bytes.slice(12, 16)) !== "IHDR") throw new Error("invalid PNG screenshot evidence");
    return { width: uint32be(bytes, 16), height: uint32be(bytes, 20) };
  }
  if (extension === ".jpg" || extension === ".jpeg") {
    if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) throw new Error("invalid JPEG screenshot evidence");
    let offset = 2;
    while (offset + 8 < bytes.length) {
      if (bytes[offset] !== 0xff) { offset += 1; continue; }
      const marker = bytes[offset + 1]!;
      if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker)) return { height: uint16(bytes, offset + 5, false), width: uint16(bytes, offset + 7, false) };
      const length = uint16(bytes, offset + 2, false);
      if (length < 2) break;
      offset += 2 + length;
    }
    throw new Error("JPEG screenshot evidence has no dimensions");
  }
  if (extension === ".webp") {
    if (bytes.length < 30 || new TextDecoder().decode(bytes.slice(0, 4)) !== "RIFF" || new TextDecoder().decode(bytes.slice(8, 12)) !== "WEBP") throw new Error("invalid WebP screenshot evidence");
    const kind = new TextDecoder().decode(bytes.slice(12, 16));
    if (kind === "VP8X") return { width: uint24le(bytes, 24) + 1, height: uint24le(bytes, 27) + 1 };
    if (kind === "VP8L" && bytes[20] === 0x2f) {
      const bits = (bytes[21]! | bytes[22]! << 8 | bytes[23]! << 16 | bytes[24]! << 24) >>> 0;
      return { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
    }
    if (kind === "VP8 " && bytes.length >= 30) return { width: uint16(bytes, 26, true) & 0x3fff, height: uint16(bytes, 28, true) & 0x3fff };
    throw new Error("unsupported WebP screenshot encoding");
  }
  throw new Error(`unsupported screenshot extension ${extension}`);
}

async function browserAudit(artifact: DirectCaptureArtifact): Promise<{ session: ReturnType<typeof browserCaptureSessionSchema.parse>; screenshotHashes: Set<string> }> {
  const session = browserCaptureSessionSchema.parse(artifact.audit.captureSession);
  if (session.sourceId !== artifact.sourceId) throw new Error("browser artifact and capture-session source identities differ");
  const attestation = artifact.audit.attestation as Record<string, unknown> | undefined;
  const screenshotHashes = new Set(Array.isArray(attestation?.screenshotSha256) ? attestation.screenshotSha256.filter((hash): hash is string => typeof hash === "string") : []);
  if (screenshotHashes.size === 0) throw new Error("browser artifact does not bind screenshot hashes in its attestation");
  if (attestation?.captureSessionHash !== session.contentHash) throw new Error("browser artifact attestation does not bind its capture-session manifest");
  const verifiedAt = Date.parse(String(attestation?.verifiedAt ?? ""));
  if (!Number.isFinite(verifiedAt) || verifiedAt < Date.parse(session.startedAt) - 5 * 60_000 || verifiedAt > Date.parse(session.finishedAt) + 5 * 60_000) throw new Error("browser proof timestamp is outside the capture session");
  if (Date.parse(session.finishedAt) >= Date.parse(BROWSER_CAPTURE_ACCURACY_CUTOVER)) {
    if (session.version !== 2) throw new Error("browser capture uses the retired pre-accuracy session contract");
    const candidates = session.accuracy.discoveryRows.map(({ rowKey: _rowKey, discoveryHash: _discoveryHash, riskReasons: _riskReasons, verificationRequired: _verificationRequired, ...row }) => row);
    const recomputed = await buildBrowserCaptureAccuracy(session.store, candidates, session.accuracy.verifications, session.terms);
    if (!recomputed.pass || stableJson(recomputed) !== stableJson(session.accuracy)) throw new Error("browser capture accuracy report is incomplete, unresolved, or not reproducible");
  }
  return { session, screenshotHashes };
}

function safeExtension(file: string): string {
  const extension = path.extname(file).toLowerCase();
  return /^[.][a-z0-9]{1,8}$/.test(extension) ? extension : ".bin";
}

async function atomicJson(file: string, value: unknown): Promise<void> {
  const temporary = `${file}.tmp-${crypto.randomUUID()}`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  await rename(temporary, file);
}

async function readManifest(directory: string): Promise<CaptureQueueManifest> {
  const value = JSON.parse(await readFile(path.join(directory, "manifest.json"), "utf8")) as CaptureQueueManifest;
  if (value.version !== 1 || !value.id || !value.sourceId || !value.artifactFile || !Array.isArray(value.evidence)) {
    throw new Error(`invalid capture queue manifest in ${directory}`);
  }
  return value;
}

async function loadJob(directory: string): Promise<CaptureQueueJob> {
  const manifest = await readManifest(directory);
  const artifactPath = path.join(directory, manifest.artifactFile);
  const artifactBytes = new Uint8Array(await readFile(artifactPath));
  if (await digestHex(artifactBytes) !== manifest.artifactSha256) throw new Error(`queued artifact hash mismatch for ${manifest.id}`);
  const artifact = directCaptureArtifactSchema.parse(JSON.parse(new TextDecoder().decode(artifactBytes).replace(/^\uFEFF/, "")));
  if (artifact.sourceId !== manifest.sourceId || artifact.idempotencyKey !== manifest.idempotencyKey) {
    throw new Error(`queued artifact identity mismatch for ${manifest.id}`);
  }
  const evidencePaths: CaptureQueueJob["evidencePaths"] = [];
  for (const evidence of manifest.evidence) {
    const evidencePath = path.join(directory, evidence.file);
    const bytes = new Uint8Array(await readFile(evidencePath));
    if (await digestHex(bytes) !== evidence.sha256) throw new Error(`queued evidence hash mismatch for ${manifest.id}/${evidence.file}`);
    evidencePaths.push({ ...evidence, path: evidencePath });
  }
  return { directory, artifactPath, evidencePaths, manifest, artifact };
}

export function defaultCaptureQueueRoot(environment: NodeJS.ProcessEnv = process.env): string {
  if (environment.TC_CAPTURE_QUEUE) return path.resolve(environment.TC_CAPTURE_QUEUE);
  const localData = environment.LOCALAPPDATA;
  if (!localData) throw new Error("set TC_CAPTURE_QUEUE or LOCALAPPDATA for the PC capture queue");
  return path.join(localData, "ThriftyCrew", "grocery-v3", "capture-queue");
}

export async function enqueueCapture(
  root: string,
  artifactInput: string,
  evidenceInputs: readonly string[],
  now?: Date,
): Promise<{ id: string; directory: string; idempotent: boolean; manifest: CaptureQueueManifest }> {
  const artifactPath = path.resolve(artifactInput);
  const artifactBytes = new Uint8Array(await readFile(artifactPath));
  const artifact = directCaptureArtifactSchema.parse(JSON.parse(new TextDecoder().decode(artifactBytes).replace(/^\uFEFF/, "")));
  if (!artifact.sourceId.endsWith("-browser")) throw new Error("the PC queue only accepts direct browser capture sources");
  const evidenceKinds = evidenceInputs.map(evidenceKind);
  if (!evidenceKinds.includes("screenshot") || !evidenceKinds.includes("manifest") || !evidenceKinds.includes("raw_payload")) throw new Error("a browser capture queue job requires screenshot, capture-session manifest, and projected raw evidence");
  const { session, screenshotHashes } = await browserAudit(artifact);
  const suppliedHashes = new Map<string, string>();
  for (const file of evidenceInputs) {
    const input = path.resolve(file);
    const bytes = new Uint8Array(await readFile(input));
    const hash = await digestHex(bytes);
    suppliedHashes.set(input, hash);
    if (evidenceKind(input) === "screenshot") {
      if (bytes.length < 512) throw new Error(`screenshot evidence is implausibly small: ${input}`);
      const dimensions = imageDimensions(bytes, path.extname(input).toLowerCase());
      if (dimensions.width < 400 || dimensions.height < 200) throw new Error(`screenshot evidence is too small (${dimensions.width}x${dimensions.height}): ${input}`);
      if (!screenshotHashes.has(hash)) throw new Error(`screenshot evidence is not bound by the artifact attestation: ${input}`);
    }
  }
  const manifestInput = evidenceInputs.find((file) => evidenceKind(file) === "manifest")!;
  const suppliedSession = browserCaptureSessionSchema.parse(JSON.parse((await readFile(manifestInput, "utf8")).replace(/^\uFEFF/, "")));
  if (stableJson(suppliedSession) !== stableJson(session)) throw new Error("supplied capture-session evidence does not match the artifact audit");
  const rawInput = evidenceInputs.find((file) => evidenceKind(file) === "raw_payload")!;
  if (suppliedHashes.get(path.resolve(rawInput)) !== session.projectedCaptureSha256) throw new Error("projected raw evidence hash does not match the capture-session manifest");
  const artifactSha256 = await digestHex(artifactBytes);
  const identityHash = await digestHex(stableJson({ sourceId: artifact.sourceId, idempotencyKey: artifact.idempotencyKey, artifactSha256 }));
  const id = `capture_${identityHash.slice(0, 32)}`;
  await mkdir(root, { recursive: true });
  const directory = path.join(root, id);
  try {
    const existing = await loadJob(directory);
    if (existing.manifest.artifactSha256 !== artifactSha256) throw new Error(`queue identity ${id} belongs to different content`);
    return { id, directory, idempotent: true, manifest: existing.manifest };
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code !== "ENOENT") throw error;
  }

  const temporary = path.join(root, `.tmp-${id}-${crypto.randomUUID()}`);
  await mkdir(temporary);
  try {
    const storedArtifact = "artifact.json";
    await copyFile(artifactPath, path.join(temporary, storedArtifact));
    const evidence: QueuedEvidence[] = [];
    for (let index = 0; index < evidenceInputs.length; index += 1) {
      const input = path.resolve(evidenceInputs[index]!);
      const bytes = new Uint8Array(await readFile(input));
      const stored = `evidence-${String(index + 1).padStart(3, "0")}${safeExtension(input)}`;
      await copyFile(input, path.join(temporary, stored));
      evidence.push({ file: stored, sha256: await digestHex(bytes), kind: evidenceKind(input), contentType: contentType(input) });
    }
    const instant = nowIso(now);
    const manifest: CaptureQueueManifest = {
      version: 1,
      id,
      sourceId: artifact.sourceId,
      idempotencyKey: artifact.idempotencyKey,
      artifactFile: storedArtifact,
      artifactSha256,
      evidence,
      enqueuedAt: instant,
      status: "pending",
      attempts: 0,
      nextAttemptAt: instant,
    };
    await atomicJson(path.join(temporary, "manifest.json"), manifest);
    try {
      await rename(temporary, directory);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      await rm(temporary, { recursive: true, force: true });
      const existing = await loadJob(directory);
      return { id, directory, idempotent: true, manifest: existing.manifest };
    }
    return { id, directory, idempotent: false, manifest };
  } catch (error) {
    await rm(temporary, { recursive: true, force: true });
    throw error;
  }
}

function retryDelayMs(attempts: number): number {
  return Math.min(6 * 60 * 60 * 1000, 30_000 * 2 ** Math.min(attempts - 1, 10));
}

export async function drainCaptureQueue(
  root: string,
  processor: (job: CaptureQueueJob) => Promise<Record<string, unknown>>,
  options: { now?: Date; maxJobs?: number } = {},
): Promise<{ ok: boolean; processed: number; completed: number; failed: number; skipped: number; results: Array<Record<string, unknown>> }> {
  await mkdir(root, { recursive: true });
  const entries = (await readdir(root, { withFileTypes: true }))
    .filter((entry) => entry.isDirectory() && entry.name.startsWith("capture_"))
    .map((entry) => path.join(root, entry.name))
    .sort();
  const now = options.now ?? new Date();
  const results: Array<Record<string, unknown>> = [];
  let processed = 0;
  let completed = 0;
  let failed = 0;
  let skipped = 0;
  for (const directory of entries) {
    if (processed >= (options.maxJobs ?? 100)) break;
    const manifest = await readManifest(directory);
    if (manifest.status === "completed" || manifest.status === "rejected" || Date.parse(manifest.nextAttemptAt) > now.getTime()) {
      skipped += 1;
      continue;
    }
    const lease = path.join(directory, ".lease");
    try {
      await mkdir(lease);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "EEXIST") {
        skipped += 1;
        continue;
      }
      throw error;
    }
    processed += 1;
    try {
      const job = await loadJob(directory);
      const attemptedAt = now.toISOString();
      const attempts = job.manifest.attempts + 1;
      try {
        const receipt = await processor(job);
        const updated: CaptureQueueManifest = {
          ...job.manifest,
          status: "completed",
          attempts,
          lastAttemptAt: attemptedAt,
          nextAttemptAt: attemptedAt,
          completedAt: attemptedAt,
          receipt,
        };
        delete updated.lastError;
        await atomicJson(path.join(directory, "manifest.json"), updated);
        await atomicJson(path.join(directory, "receipt.json"), receipt);
        completed += 1;
        results.push({ id: updated.id, sourceId: updated.sourceId, status: "completed", attempts, receipt });
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        const permanent = error instanceof PermanentCaptureError;
        const updated: CaptureQueueManifest = {
          ...job.manifest,
          status: permanent ? "rejected" : "retrying",
          attempts,
          lastAttemptAt: attemptedAt,
          lastError: message.slice(0, 10_000),
          nextAttemptAt: permanent ? attemptedAt : new Date(now.getTime() + retryDelayMs(attempts)).toISOString(),
        };
        await atomicJson(path.join(directory, "manifest.json"), updated);
        failed += 1;
        results.push({ id: updated.id, sourceId: updated.sourceId, status: updated.status, attempts, nextAttemptAt: updated.nextAttemptAt, error: updated.lastError });
      }
    } finally {
      await rm(lease, { recursive: true, force: true });
    }
  }
  return { ok: failed === 0, processed, completed, failed, skipped, results };
}

export async function reconcileCaptureQueueRemote(
  root: string,
  inspector: (batchId: string) => Promise<Record<string, unknown>>,
  now = new Date(),
): Promise<{ checked: number; ready: number; inflight: number; rejected: number; errors: number }> {
  await mkdir(root, { recursive: true });
  let checked = 0;
  let ready = 0;
  let inflight = 0;
  let rejected = 0;
  let errors = 0;
  for (const entry of await readdir(root, { withFileTypes: true })) {
    if (!entry.isDirectory() || !entry.name.startsWith("capture_")) continue;
    const directory = path.join(root, entry.name);
    const manifest = await readManifest(directory);
    if (manifest.status !== "completed" || !manifest.receipt || typeof manifest.receipt.batchId !== "string") continue;
    checked += 1;
    let remote: Record<string, unknown>;
    try {
      remote = await inspector(manifest.receipt.batchId);
    } catch (error) {
      errors += 1;
      inflight += 1;
      const message = error instanceof Error ? error.message : String(error);
      const updated: CaptureQueueManifest = { ...manifest, receipt: { ...manifest.receipt, remoteError: message.slice(0, 2000), remoteCheckedAt: now.toISOString() } };
      await atomicJson(path.join(directory, "manifest.json"), updated);
      await atomicJson(path.join(directory, "receipt.json"), updated.receipt);
      continue;
    }
    const remoteStatus = String(remote.status ?? "unknown");
    const matching = remote.matching as Record<string, unknown> | null | undefined;
    const matchStatus = matching ? String(matching.status ?? "unknown") : "pending";
    const nextReceipt: Record<string, unknown> = { ...manifest.receipt, remote, remoteCheckedAt: now.toISOString() };
    delete nextReceipt.remoteError;
    const updated: CaptureQueueManifest = { ...manifest, receipt: nextReceipt };
    if (remoteStatus === "rejected" || matchStatus === "failed") {
      updated.status = "rejected";
      updated.lastError = `remote browser batch ${manifest.receipt.batchId} is ${remoteStatus} with matching ${matchStatus}`;
      updated.nextAttemptAt = now.toISOString();
      rejected += 1;
    } else if ((remoteStatus === "promoted" || remoteStatus === "superseded") && matchStatus === "passed") {
      delete updated.lastError;
      ready += 1;
    } else {
      inflight += 1;
    }
    await atomicJson(path.join(directory, "manifest.json"), updated);
    await atomicJson(path.join(directory, "receipt.json"), updated.receipt);
  }
  return { checked, ready, inflight, rejected, errors };
}

function remoteCaptureReady(job: CaptureQueueJob, captureDate: string): boolean {
  if (captureDate < STRICT_BROWSER_COVERAGE_START) return job.manifest.status === "completed";
  if (job.artifact.coverageMode !== "full" || job.manifest.status !== "completed") return false;
  const remote = job.manifest.receipt?.remote as Record<string, unknown> | undefined;
  const matching = remote?.matching as Record<string, unknown> | null | undefined;
  return (remote?.status === "promoted" || remote?.status === "superseded") && matching?.status === "passed";
}

export async function captureQueueStatus(
  root: string,
  options: { now?: Date; maxPendingMinutes?: number; maxAttempts?: number } = {},
): Promise<CaptureQueueStatus> {
  await mkdir(root, { recursive: true });
  const now = options.now ?? new Date();
  const manifests: CaptureQueueManifest[] = [];
  for (const entry of await readdir(root, { withFileTypes: true })) {
    if (!entry.isDirectory() || !entry.name.startsWith("capture_")) continue;
    manifests.push(await readManifest(path.join(root, entry.name)));
  }
  const active = manifests.filter((manifest) => manifest.status !== "completed");
  const ages = active.map((manifest) => Math.max(0, (now.getTime() - Date.parse(manifest.enqueuedAt)) / 60_000));
  const maxPendingMinutes = options.maxPendingMinutes ?? 180;
  const maxAttempts = options.maxAttempts ?? 5;
  const unhealthyJobs = active.flatMap((manifest, index) => {
    const ageMinutes = ages[index] ?? 0;
    return manifest.status === "rejected" || ageMinutes > maxPendingMinutes || manifest.attempts >= maxAttempts
      ? [{ id: manifest.id, sourceId: manifest.sourceId, attempts: manifest.attempts, ageMinutes: Math.round(ageMinutes), ...(manifest.lastError ? { lastError: manifest.lastError } : {}) }]
      : [];
  });
  const oldest = [...active].sort((left, right) => left.enqueuedAt.localeCompare(right.enqueuedAt))[0];
  const oldestAge = ages.length ? Math.max(...ages) : null;
  return {
    ok: unhealthyJobs.length === 0,
    root,
    pending: manifests.filter((manifest) => manifest.status === "pending").length,
    retrying: manifests.filter((manifest) => manifest.status === "retrying").length,
    completed: manifests.filter((manifest) => manifest.status === "completed").length,
    rejected: manifests.filter((manifest) => manifest.status === "rejected").length,
    total: manifests.length,
    oldestPendingAt: oldest?.enqueuedAt ?? null,
    oldestPendingMinutes: oldestAge === null ? null : Math.round(oldestAge),
    highestAttempts: manifests.reduce((maximum, manifest) => Math.max(maximum, manifest.attempts), 0),
    unhealthyJobs,
  };
}

export async function browserCaptureCycleStatus(root: string, now = new Date()): Promise<BrowserCaptureCycleStatus> {
  await mkdir(root, { recursive: true });
  const current = centralParts(now);
  const weekStart = shiftDateKey(current.dateKey, -((current.weekday - 3 + 7) % 7));
  const previousWeekStart = shiftDateKey(weekStart, -7);
  const jobs: CaptureQueueJob[] = [];
  for (const entry of await readdir(root, { withFileTypes: true })) {
    if (!entry.isDirectory() || !entry.name.startsWith("capture_")) continue;
    try { jobs.push(await loadJob(path.join(root, entry.name))); } catch { /* queue health reports corrupt jobs separately */ }
  }
  const latestBySource = new Map<string, CaptureQueueJob>();
  for (const job of jobs) {
    if (!REQUIRED_BROWSER_CAPTURE_SOURCES.includes(job.artifact.sourceId as typeof REQUIRED_BROWSER_CAPTURE_SOURCES[number])) continue;
    const prior = latestBySource.get(job.artifact.sourceId);
    if (!prior
      || job.artifact.capturedTo > prior.artifact.capturedTo
      || (job.artifact.capturedTo === prior.artifact.capturedTo && job.manifest.enqueuedAt > prior.manifest.enqueuedAt)) {
      latestBySource.set(job.artifact.sourceId, job);
    }
  }
  const due: string[] = [];
  const inflight: string[] = [];
  const completed: string[] = [];
  const overdue: string[] = [];
  for (const sourceId of REQUIRED_BROWSER_CAPTURE_SOURCES) {
    const latest = latestBySource.get(sourceId);
    const captureDate = latest ? centralDateKey(new Date(latest.artifact.capturedTo)) : null;
    const currentWeek = captureDate !== null && captureDate >= weekStart;
    if (currentWeek && latest && remoteCaptureReady(latest, captureDate!)) completed.push(sourceId);
    else if (currentWeek && latest && (latest.manifest.status === "pending" || latest.manifest.status === "retrying" || latest.manifest.status === "completed")) inflight.push(sourceId);
    else due.push(sourceId);
    if (!captureDate || captureDate < previousWeekStart) overdue.push(sourceId);
  }
  const status = due.length ? "due" : inflight.length ? "inflight" : "fresh";
  const retryWindowExpired = current.weekday === 6 && current.hour >= 12 || current.weekday === 0 || current.weekday === 1 || current.weekday === 2;
  return { status, weekStart, previousWeekStart, due, inflight, completed, overdue, alertDue: status !== "fresh" && (retryWindowExpired || overdue.length > 0) };
}

export async function verifyCaptureQueueFilesystem(root: string): Promise<{ ok: boolean; jobs: number; bytes: number }> {
  await mkdir(root, { recursive: true });
  let jobs = 0;
  let bytes = 0;
  for (const entry of await readdir(root, { withFileTypes: true })) {
    if (!entry.isDirectory() || !entry.name.startsWith("capture_")) continue;
    const job = await loadJob(path.join(root, entry.name));
    jobs += 1;
    bytes += (await stat(job.artifactPath)).size;
    for (const evidence of job.evidencePaths) bytes += (await stat(evidence.path)).size;
  }
  return { ok: true, jobs, bytes };
}
