import { createHash } from "node:crypto";
import { mkdir, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { digestHex } from "@thriftycrew/domain";
import { captureJournalPath, closeCaptureJournals, serializeCaptureJournal } from "./capture-journal";
import { localCaptureMutationClient } from "./capture-drainer";
import { decryptCaptureJournalEnvelope, encryptCaptureJournalEnvelope } from "./capture-journal-envelope";

let lastUploadedPlaintextHash: string | undefined;

function journalKey(environment: NodeJS.ProcessEnv = process.env): Buffer {
  const encoded = environment.TC_CAPTURE_JOURNAL_KEY;
  if (!encoded) throw new Error("TC_CAPTURE_JOURNAL_KEY is required for encrypted journal checkpoints");
  const key = Buffer.from(encoded, "base64");
  if (key.byteLength !== 32 || key.toString("base64") !== encoded) throw new Error("TC_CAPTURE_JOURNAL_KEY must be a canonical base64-encoded 32-byte key");
  return key;
}

export async function checkpointCaptureJournal(): Promise<Record<string, unknown>> {
  const plain = serializeCaptureJournal();
  const plaintextSha256 = await digestHex(plain);
  if (plaintextSha256 === lastUploadedPlaintextHash) return { ok: true, skipped: true, plaintextSha256 };
  const encrypted = encryptCaptureJournalEnvelope(plain, journalKey());
  const ciphertextSha256 = await digestHex(encrypted);
  const createdAt = new Date().toISOString();
  const result = await localCaptureMutationClient().request("/internal/capture-journal-checkpoints", {
    method: "PUT",
    body: encrypted,
    headers: {
      "content-type": "application/vnd.thriftycrew.capture-journal+encrypted",
      "x-content-sha256": ciphertextSha256,
      "x-journal-plaintext-sha256": plaintextSha256,
      "x-journal-schema": "1",
      "x-checkpoint-created-at": createdAt,
    },
  });
  lastUploadedPlaintextHash = plaintextSha256;
  return { ...result, plaintextSha256, ciphertextSha256, byteLength: encrypted.byteLength };
}

interface LatestCheckpoint {
  id: string;
  ciphertextSha256: string;
  plaintextSha256: string;
  byteLength: number;
  journalSchema: number;
  createdAt: string;
  downloadUrl: string;
}

export async function restoreCaptureJournal(force = false): Promise<Record<string, unknown>> {
  const target = captureJournalPath();
  if (target === ":memory:") throw new Error("an in-memory capture journal cannot be restored");
  const exists = await stat(target).then(() => true).catch(() => false);
  if (exists && !force) throw new Error(`capture journal already exists at ${target}; pass --force to preserve it as a backup and restore`);
  const result = await localCaptureMutationClient().request("/internal/capture-journal-checkpoints/latest");
  const checkpoint = result.checkpoint as LatestCheckpoint | undefined;
  if (!checkpoint?.downloadUrl) throw new Error("latest capture journal checkpoint response is incomplete");
  const response = await fetch(checkpoint.downloadUrl);
  if (!response.ok) throw new Error(`journal checkpoint download returned ${response.status}`);
  const encrypted = new Uint8Array(await response.arrayBuffer());
  if (encrypted.byteLength !== checkpoint.byteLength || await digestHex(encrypted) !== checkpoint.ciphertextSha256) {
    throw new Error("downloaded journal checkpoint failed ciphertext verification");
  }
  const plain = decryptCaptureJournalEnvelope(encrypted, journalKey());
  if (await digestHex(plain) !== checkpoint.plaintextSha256) throw new Error("decrypted journal checkpoint failed plaintext verification");
  await mkdir(path.dirname(target), { recursive: true });
  const temporary = `${target}.restore-${process.pid}-${Date.now()}`;
  await writeFile(temporary, plain, { flag: "wx" });
  let verification: string;
  try {
    const database = new DatabaseSync(temporary, { readOnly: true });
    verification = String((database.prepare("PRAGMA integrity_check").get() as Record<string, unknown>)["integrity_check"] ?? "");
    const tables = Number((database.prepare("SELECT COUNT(*) AS count FROM sqlite_master WHERE type = 'table'").get() as { count: number }).count);
    database.close();
    if (verification !== "ok" || tables < 7) throw new Error(`restored journal validation failed (integrity=${verification}, tables=${tables})`);
    closeCaptureJournals();
    let backupFile: string | undefined;
    if (exists) {
      backupFile = `${target}.pre-restore-${new Date().toISOString().replace(/[:.]/g, "-")}`;
      await rename(target, backupFile);
      for (const suffix of ["-wal", "-shm"]) {
        const sidecar = `${target}${suffix}`;
        if (await stat(sidecar).then(() => true).catch(() => false)) await rename(sidecar, `${backupFile}${suffix}`);
      }
    }
    try { await rename(temporary, target); }
    catch (error) {
      if (backupFile) await rename(backupFile, target).catch(() => undefined);
      throw error;
    }
    lastUploadedPlaintextHash = checkpoint.plaintextSha256;
    return { ok: true, checkpointId: checkpoint.id, target, backupFile, plaintextSha256: checkpoint.plaintextSha256, createdAt: checkpoint.createdAt };
  } catch (error) {
    await rm(temporary, { force: true });
    throw error;
  }
}

export function captureJournalCheckpointFingerprint(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}
