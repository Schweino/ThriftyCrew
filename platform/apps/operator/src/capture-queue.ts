import { copyFile, mkdir, readFile, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { directCaptureArtifactSchema, type DirectCaptureArtifact } from "@thriftycrew/contracts";
import { digestHex, stableJson } from "@thriftycrew/domain";

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

function evidenceKind(file: string): QueuedEvidence["kind"] {
  return IMAGE_EXTENSIONS.has(path.extname(file).toLowerCase()) ? "screenshot" : "manifest";
}

function contentType(file: string): string {
  return IMAGE_EXTENSIONS.get(path.extname(file).toLowerCase()) ?? "application/json";
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
  if (evidenceInputs.length === 0 || !evidenceInputs.some((file) => IMAGE_EXTENSIONS.has(path.extname(file).toLowerCase()))) {
    throw new Error("a browser capture queue job requires at least one screenshot evidence file");
  }
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
