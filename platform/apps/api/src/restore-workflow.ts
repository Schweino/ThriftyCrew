import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers";
import { stableJson } from "@thriftycrew/domain";
import { raiseOperationalAlert } from "./operations";
import type { WorkerEnv } from "./env";
import {
  RESTORE_COUNT_TABLES,
  emptyRestoreCounts,
  inspectSqlInsert,
  normalizeCaptureBatchLine,
  utf8LengthExceeds,
  type RestoreCountTable,
} from "./restore-normalization";

interface RestoreWorkflowPayload { trigger?: string }
interface ApiEnvelope<T> { success?: boolean; errors?: unknown[]; result?: T }
interface D1QueryResult<T> { success?: boolean; error?: string; results?: T[] }

async function sha256Hex(bytes: ArrayBuffer | Uint8Array): Promise<string> {
  const normalized = bytes instanceof Uint8Array ? Uint8Array.from(bytes).buffer : bytes;
  const digest = await crypto.subtle.digest("SHA-256", normalized);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function cloudflare<T>(env: WorkerEnv, pathname: string, init: RequestInit = {}): Promise<T> {
  if (!env.D1_REST_API_TOKEN || !env.CLOUDFLARE_ACCOUNT_ID) throw new Error("D1 restore credentials are not configured");
  const response = await fetch(`https://api.cloudflare.com/client/v4/accounts/${env.CLOUDFLARE_ACCOUNT_ID}${pathname}`, {
    ...init,
    headers: { authorization: `Bearer ${env.D1_REST_API_TOKEN}`, "content-type": "application/json", ...(init.headers ?? {}) },
  });
  const body = await response.json() as ApiEnvelope<T>;
  if (!response.ok || body.success !== true || body.result === undefined) throw new Error(`Cloudflare ${pathname} returned ${response.status}: ${stableJson(body.errors ?? [])}`);
  return body.result;
}

async function queryScratch<T>(env: WorkerEnv, databaseId: string, sql: string): Promise<T[]> {
  const result = await cloudflare<Array<D1QueryResult<T>>>(env, `/d1/database/${databaseId}/query`, { method: "POST", body: JSON.stringify({ sql }) });
  if (result[0]?.success === false) throw new Error(result[0].error ?? "scratch D1 query failed");
  return result[0]?.results ?? [];
}

async function executeScratch(env: WorkerEnv, databaseId: string, sql: string, params: Array<string | null>): Promise<void> {
  const result = await cloudflare<Array<D1QueryResult<unknown>>>(env, `/d1/database/${databaseId}/query`, {
    method: "POST",
    body: JSON.stringify({ sql, params }),
  });
  if (result[0]?.success === false) throw new Error(result[0].error ?? "scratch D1 mutation failed");
}

function quoteIdentifier(value: string): string {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(value)) throw new Error(`unsafe SQL identifier in restore dump: ${value}`);
  return `"${value}"`;
}

export class D1RestoreDrillWorkflow extends WorkflowEntrypoint<WorkerEnv, RestoreWorkflowPayload> {
  override async run(event: WorkflowEvent<RestoreWorkflowPayload>, step: WorkflowStep): Promise<void> {
    const startedAt = new Date().toISOString();
    const drillId = `restore_${event.instanceId}`;
    const runId = `run_${event.instanceId}`;
    let scratchDatabaseId: string | null = null;
    let backupId = "unknown";
    let dumpSha256 = "0".repeat(64);
    let normalizedObjectKey: string | null = null;
    let normalizedMultipartUploadId: string | null = null;
    let normalizedMultipartCompleted = false;
    await this.env.DB.prepare(
      `INSERT INTO job_runs (id, job, trigger_kind, scheduled_for, started_at, heartbeat_at, status, executor_run_id, actor_id, input_json)
       VALUES (?1, 'restore-drill-quarterly', 'schedule', ?2, ?2, ?2, 'started', ?3, 'cloudflare:restore-workflow', '{}')
       ON CONFLICT(id) DO NOTHING`,
    ).bind(runId, startedAt, event.instanceId).run();
    try {
      const backup = await step.do("select latest completed backup", async () => {
        const row = await this.env.DB.prepare(
          "SELECT id, object_key FROM backup_exports WHERE status = 'completed' AND object_key IS NOT NULL ORDER BY finished_at DESC LIMIT 1",
        ).first<{ id: string; object_key: string }>();
        if (!row) throw new Error("no completed D1 backup is available");
        return row;
      });
      backupId = backup.id;
      const dump = await step.do("inspect exact R2 backup", async () => {
        const object = await this.env.BACKUPS.head(backup.object_key);
        if (!object) throw new Error(`backup object ${backup.object_key} is missing`);
        return { etag: object.etag.replaceAll('"', ""), length: object.size };
      });
      const hashChunkBytes = 4 * 1024 * 1024;
      const chunkHashes: string[] = [];
      for (let offset = 0, index = 0; offset < dump.length; offset += hashChunkBytes, index += 1) {
        const length = Math.min(hashChunkBytes, dump.length - offset);
        const hash = await step.do(`hash R2 backup chunk ${index}`, async () => {
          const object = await this.env.BACKUPS.get(backup.object_key, { range: { offset, length } });
          if (!object?.body) throw new Error(`backup object ${backup.object_key} chunk ${index} is unreadable`);
          const bytes = await object.arrayBuffer();
          if (bytes.byteLength !== length) throw new Error(`backup object ${backup.object_key} chunk ${index} has the wrong length`);
          return sha256Hex(bytes);
        });
        chunkHashes.push(hash);
      }
      const hashScheme = "sha256-merkle-r2-v1";
      dumpSha256 = await sha256Hex(new TextEncoder().encode(stableJson({ hashScheme, objectKey: backup.object_key, etag: dump.etag, length: dump.length, hashChunkBytes, chunkHashes })));
      normalizedObjectKey = `restore-normalized/${backup.id}/${dumpSha256}.sql`;
      const multipart = await step.do("create normalized restore multipart upload", async () => {
        const upload = await this.env.BACKUPS.createMultipartUpload(normalizedObjectKey!, {
          httpMetadata: { contentType: "application/sql" },
          customMetadata: { sourceObjectKey: backup.object_key, sourceDumpSha256: dumpSha256 },
        });
        return { uploadId: upload.uploadId };
      });
      normalizedMultipartUploadId = multipart.uploadId;
      const statementLimitBytes = 90_000;
      const targetPartBytes = 4 * 1024 * 1024;
      const boundarySearchBytes = 512 * 1024;
      const expectedCounts = emptyRestoreCounts();
      const releaseHashes: Record<string, string> = {};
      const recoveryRows: Array<{ table: string; columns: string[]; values: Array<string | null> }> = [];
      const deferredUpdates: string[] = [];
      const uploadedParts: Array<{ partNumber: number; etag: string }> = [];
      let currentReleaseId: string | null = null;
      let normalizedByteLength = 0;
      let sourceOffset = 0;
      for (let partNumber = 1; sourceOffset < dump.length; partNumber += 1) {
        const remaining = dump.length - sourceOffset;
        const nominalEnd = Math.min(sourceOffset + targetPartBytes, dump.length);
        const part = await step.do(`normalize and upload restore part ${partNumber}`, {
          retries: { limit: 2, delay: "30 seconds", backoff: "constant" },
          timeout: "10 minutes",
        }, async () => {
          let sourceEnd = nominalEnd;
          if (sourceEnd < dump.length) {
            const searchLength = Math.min(boundarySearchBytes, dump.length - sourceEnd);
            const boundary = await this.env.BACKUPS.get(backup.object_key, { range: { offset: sourceEnd, length: searchLength } });
            if (!boundary?.body) throw new Error("backup object is unreadable while locating a multipart line boundary");
            const boundaryBytes = new Uint8Array(await boundary.arrayBuffer());
            const newline = boundaryBytes.indexOf(10);
            if (newline < 0) throw new Error(`restore SQL line exceeds ${boundarySearchBytes} boundary-search bytes`);
            sourceEnd += newline + 1;
          }
          const object = await this.env.BACKUPS.get(backup.object_key, { range: { offset: sourceOffset, length: sourceEnd - sourceOffset } });
          if (!object?.body) throw new Error(`backup object part ${partNumber} is unreadable`);
          const bytes = await object.arrayBuffer();
          if (bytes.byteLength !== sourceEnd - sourceOffset) throw new Error(`backup object part ${partNumber} has the wrong length`);
          const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
          const hasTrailingNewline = text.endsWith("\n");
          const lines = text.split("\n");
          if (hasTrailingNewline) lines.pop();
          const partCounts = emptyRestoreCounts();
          const partReleaseHashes: Record<string, string> = {};
          const partRecoveryRows: Array<{ table: string; columns: string[]; values: Array<string | null> }> = [];
          const partDeferredUpdates: string[] = [];
          let partCurrentReleaseId: string | null = null;
          const outputParts: string[] = [];
          for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
            const line = lines[lineIndex]!;
            const table = line.match(/^INSERT INTO "([^"]+)"/)?.[1];
            if (table && RESTORE_COUNT_TABLES.includes(table as RestoreCountTable)) partCounts[table as RestoreCountTable] += 1;
            const oversized = utf8LengthExceeds(line, statementLimitBytes);
            const needsParsedValues = table === "releases" || table === "current_releases" || oversized;
            const insert = needsParsedValues ? inspectSqlInsert(line) : null;
            if (insert) {
              const record = Object.fromEntries(insert.columns.map((column, index) => [column, insert.values[index]]));
              if (insert.table === "current_releases" && record.market_id === "omaha" && typeof record.release_id === "string") partCurrentReleaseId = record.release_id;
              if (insert.table === "releases" && typeof record.id === "string" && typeof record.input_hash === "string") partReleaseHashes[record.id] = record.input_hash;
            }
            if (oversized) {
              if (!insert) throw new Error("oversized non-INSERT statement cannot be normalized");
              partRecoveryRows.push(insert);
              outputParts.push(`-- oversized INSERT for ${insert.table} restored through parameter binding\n`);
              continue;
            }
            const adjusted = table === "capture_batches" ? normalizeCaptureBatchLine(line) : { line };
            if (adjusted.deferredUpdate) partDeferredUpdates.push(adjusted.deferredUpdate);
            outputParts.push(adjusted.line);
            if (hasTrailingNewline || lineIndex < lines.length - 1) outputParts.push("\n");
          }
          const isLastPart = sourceEnd === dump.length;
          const allDeferredUpdates = [...deferredUpdates, ...partDeferredUpdates];
          if (isLastPart && allDeferredUpdates.length > 0) {
            if (outputParts.at(-1) !== "\n") outputParts.push("\n");
            outputParts.push(`${allDeferredUpdates.join("\n")}\n`);
          }
          const output = outputParts.join("");
          const encodedOutput = new TextEncoder().encode(output);
          let outputBytes = encodedOutput;
          const minimumMultipartBytes = 5 * 1024 * 1024;
          if (!isLastPart && encodedOutput.byteLength < minimumMultipartBytes) {
            outputBytes = new Uint8Array(minimumMultipartBytes);
            outputBytes.set(encodedOutput);
            outputBytes.fill(32, encodedOutput.byteLength);
          }
          const upload = this.env.BACKUPS.resumeMultipartUpload(normalizedObjectKey!, multipart.uploadId);
          const uploaded = await upload.uploadPart(partNumber, outputBytes);
          return { sourceEnd, byteLength: outputBytes.byteLength, uploaded, counts: partCounts, releaseHashes: partReleaseHashes, currentReleaseId: partCurrentReleaseId, recoveryRows: partRecoveryRows, deferredUpdates: partDeferredUpdates };
        });
        sourceOffset = part.sourceEnd;
        normalizedByteLength += part.byteLength;
        uploadedParts.push(part.uploaded);
        for (const table of RESTORE_COUNT_TABLES) expectedCounts[table] += part.counts[table];
        Object.assign(releaseHashes, part.releaseHashes);
        if (part.currentReleaseId) currentReleaseId = part.currentReleaseId;
        recoveryRows.push(...part.recoveryRows);
        deferredUpdates.push(...part.deferredUpdates);
      }
      const completedMultipart = await step.do("complete normalized restore multipart upload", async () => {
        const upload = this.env.BACKUPS.resumeMultipartUpload(normalizedObjectKey!, multipart.uploadId);
        const object = await upload.complete(uploadedParts);
        return { etag: object.etag.replaceAll('"', ""), length: object.size };
      });
      normalizedMultipartCompleted = true;
      if (completedMultipart.length !== normalizedByteLength) throw new Error("completed normalized restore object has the wrong byte length");
      const expectedRelease = currentReleaseId ? { id: currentReleaseId, inputHash: releaseHashes[currentReleaseId] } : null;
      if (!expectedRelease?.inputHash) throw new Error("backup dump omitted the current Omaha release or its input hash");
      const normalized = { objectKey: normalizedObjectKey, ...completedMultipart, deferredSupersessionUpdates: deferredUpdates.length, statementLimitBytes, recoveryRows, expectedCounts, expectedRelease };
      const scratch = await step.do("create isolated scratch D1", async () => cloudflare<{ uuid?: string }>(this.env, "/d1/database", {
        method: "POST",
        body: JSON.stringify({ name: `tc-grocery-v3-restore-${startedAt.slice(0, 10).replaceAll("-", "")}-${event.instanceId.slice(-8)}`, primary_location_hint: "wnam", read_replication: { mode: "disabled" } }),
      }));
      if (!scratch.uuid) throw new Error("scratch D1 creation omitted its UUID");
      scratchDatabaseId = scratch.uuid;
      await this.env.DB.prepare(
        `INSERT INTO restore_drills (id, backup_id, scratch_database_id, dump_sha256, status, started_at, evidence_json)
         VALUES (?1, ?2, ?3, ?4, 'started', ?5, ?6)
         ON CONFLICT(id) DO UPDATE SET
           backup_id = excluded.backup_id,
           scratch_database_id = excluded.scratch_database_id,
           dump_sha256 = excluded.dump_sha256,
           status = 'started',
           started_at = excluded.started_at,
           finished_at = NULL,
           evidence_json = excluded.evidence_json`,
      ).bind(drillId, backupId, scratchDatabaseId, dumpSha256, startedAt, stableJson({
        objectKey: backup.object_key,
        byteLength: dump.length,
        etag: dump.etag,
        hashScheme,
        hashChunkBytes,
        chunkCount: chunkHashes.length,
        normalized: {
          objectKey: normalized.objectKey,
          etag: normalized.etag,
          length: normalized.length,
          deferredSupersessionUpdates: normalized.deferredSupersessionUpdates,
          statementLimitBytes: normalized.statementLimitBytes,
          recoveryRows: normalized.recoveryRows.length,
          expectedCounts: normalized.expectedCounts,
          expectedRelease: normalized.expectedRelease,
        },
        trigger: event.payload.trigger ?? "scheduled",
      })).run();
      const initialized = await step.do("initialize scratch import", async () => cloudflare<{ upload_url?: string; filename?: string }>(this.env, `/d1/database/${scratchDatabaseId}/import`, {
        method: "POST", body: JSON.stringify({ action: "init", etag: normalized.etag }),
      }));
      if (!initialized.upload_url || !initialized.filename) throw new Error("D1 import initialization omitted upload metadata");
      await step.do("upload backup to scratch import", async () => {
        const object = await this.env.BACKUPS.get(normalized.objectKey);
        if (!object?.body) throw new Error(`normalized restore object ${normalized.objectKey} is unreadable during upload`);
        const etag = object.etag.replaceAll('"', "");
        if (etag !== normalized.etag || object.size !== normalized.length) throw new Error("normalized restore object changed between creation and upload");
        const response = await fetch(initialized.upload_url!, { method: "PUT", body: object.body });
        if (!response.ok) throw new Error(`scratch import upload returned ${response.status}`);
      });
      const ingested = await step.do("start scratch import", {
        retries: { limit: 2, delay: "30 seconds", backoff: "constant" },
        timeout: "30 minutes",
      }, async () => cloudflare<{ at_bookmark?: string; status?: string; error?: string }>(this.env, `/d1/database/${scratchDatabaseId}/import`, {
        method: "POST", body: JSON.stringify({ action: "ingest", etag: normalized.etag, filename: initialized.filename }),
      }));
      if (!ingested.at_bookmark) throw new Error("scratch import omitted polling bookmark");
      let completed = ingested;
      for (let attempt = 0; attempt < 30 && completed.status !== "complete"; attempt += 1) {
        await step.sleep(`wait for scratch import ${attempt}`, "10 seconds");
        const polled = await step.do(`poll scratch import ${attempt}`, async () => cloudflare<{ at_bookmark?: string; status?: string; error?: string; result?: { final_bookmark?: string } }>(this.env, `/d1/database/${scratchDatabaseId}/import`, {
          method: "POST", body: JSON.stringify({ action: "poll", current_bookmark: ingested.at_bookmark }),
        }));
        if (!polled) throw new Error("scratch import poll returned no status");
        completed = polled;
        if (completed.status === "error") throw new Error(completed.error ?? "scratch import failed");
      }
      if (completed.status !== "complete") throw new Error("scratch import did not complete within five minutes");
      for (let index = 0; index < normalized.recoveryRows.length; index += 1) {
        const row = normalized.recoveryRows[index]!;
        await step.do(`restore oversized ${row.table} row ${index}`, async () => {
          const placeholders = row.values.map((_, valueIndex) => `?${valueIndex + 1}`).join(", ");
          const sql = `INSERT INTO ${quoteIdentifier(row.table)} (${row.columns.map(quoteIdentifier).join(", ")}) VALUES (${placeholders})`;
          await executeScratch(this.env, scratchDatabaseId!, sql, row.values);
          return true;
        });
      }
      const comparisons: Record<RestoreCountTable, { expected: number; scratch: number; liveAtVerification: number }> = {} as Record<RestoreCountTable, { expected: number; scratch: number; liveAtVerification: number }>;
      for (const table of RESTORE_COUNT_TABLES) {
        const live = await this.env.DB.prepare(`SELECT COUNT(*) AS count FROM ${table}`).first<{ count: number }>();
        const restored = await queryScratch<{ count: number }>(this.env, scratchDatabaseId, `SELECT COUNT(*) AS count FROM ${table}`);
        comparisons[table] = {
          expected: normalized.expectedCounts[table],
          scratch: restored[0]?.count ?? -1,
          liveAtVerification: live?.count ?? -1,
        };
      }
      const liveRelease = await this.env.DB.prepare(
        `SELECT r.id, r.input_hash FROM current_releases c JOIN releases r ON r.id = c.release_id WHERE c.market_id = 'omaha'`,
      ).first<{ id: string; input_hash: string }>();
      const scratchRelease = (await queryScratch<{ id: string; input_hash: string }>(this.env, scratchDatabaseId,
        `SELECT r.id, r.input_hash FROM current_releases c JOIN releases r ON r.id = c.release_id WHERE c.market_id = 'omaha'`))[0];
      const countsMatch = Object.values(comparisons).every((value) => value.expected === value.scratch);
      const releaseMatches = Boolean(scratchRelease && normalized.expectedRelease.id === scratchRelease.id && normalized.expectedRelease.inputHash === scratchRelease.input_hash);
      if (!countsMatch || !releaseMatches) throw new Error(`scratch restore verification failed: ${stableJson({ comparisons, expectedRelease: normalized.expectedRelease, scratchRelease, liveRelease })}`);
      const finishedAt = new Date().toISOString();
      await this.env.DB.batch([
        this.env.DB.prepare("UPDATE restore_drills SET status = 'passed', finished_at = ?2, evidence_json = ?3 WHERE id = ?1")
          .bind(drillId, finishedAt, stableJson({ comparisons, expectedRelease: normalized.expectedRelease, scratchRelease, liveRelease, byteLength: dump.length, etag: dump.etag, hashScheme, hashChunkBytes, chunkCount: chunkHashes.length, normalizedObjectKey: normalized.objectKey, normalizedEtag: normalized.etag, normalizedByteLength: normalized.length, deferredSupersessionUpdates: normalized.deferredSupersessionUpdates, statementLimitBytes: normalized.statementLimitBytes, recoveredOversizedRows: normalized.recoveryRows.length, comparisonBasis: "dump-stream-counts+dump-release-pointer", importStatus: completed.status })),
        this.env.DB.prepare("UPDATE job_runs SET status = 'completed', heartbeat_at = ?2, finished_at = ?2, stats_json = ?3 WHERE id = ?1")
          .bind(runId, finishedAt, stableJson({ drillId, backupId, scratchDatabaseId, comparisons })),
        this.env.DB.prepare(
          `UPDATE triage_items SET status = 'resolved', resolution_json = ?2, resolved_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
            WHERE source_kind = 'operational_alert' AND source_ref LIKE ?1 AND status <> 'resolved'`,
        ).bind(`restore-drill:${event.instanceId.replace(/-a\d+$/, "")}%`, stableJson({ drillId, backupId, recoveredBy: event.instanceId })),
      ]);
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown restore drill failure";
      const finishedAt = new Date().toISOString();
      if (backupId !== "unknown" && scratchDatabaseId) {
        await this.env.DB.prepare(
          `INSERT INTO restore_drills (id, backup_id, scratch_database_id, dump_sha256, status, started_at, finished_at, evidence_json)
           VALUES (?1, ?2, ?3, ?4, 'failed', ?5, ?6, ?7)
           ON CONFLICT(id) DO UPDATE SET status = 'failed', finished_at = excluded.finished_at, evidence_json = excluded.evidence_json`,
        ).bind(drillId, backupId, scratchDatabaseId, dumpSha256, startedAt, finishedAt, stableJson({ error: message })).run();
      }
      await this.env.DB.prepare("UPDATE job_runs SET status = 'failed', heartbeat_at = ?2, finished_at = ?2, error = ?3 WHERE id = ?1")
        .bind(runId, finishedAt, message).run();
      await raiseOperationalAlert(this.env, `restore-drill:${event.instanceId}`, "Quarterly D1 restore drill failed", { drillId, backupId, scratchDatabaseId, error: message });
      throw error;
    } finally {
      if (scratchDatabaseId) {
        try {
          await step.do("delete exact scratch D1", async () => {
            await cloudflare<null>(this.env, `/d1/database/${scratchDatabaseId}`, { method: "DELETE" });
            return true;
          });
        } catch (error) {
          await raiseOperationalAlert(this.env, `restore-scratch-cleanup:${scratchDatabaseId}`, "Restore drill scratch database cleanup failed", { scratchDatabaseId, error: error instanceof Error ? error.message : "unknown cleanup failure" });
        }
      }
      if (normalizedObjectKey && normalizedMultipartUploadId && !normalizedMultipartCompleted) {
        try {
          await step.do("abort exact normalized restore multipart upload", async () => {
            const upload = this.env.BACKUPS.resumeMultipartUpload(normalizedObjectKey!, normalizedMultipartUploadId!);
            await upload.abort();
            return true;
          });
        } catch (error) {
          await raiseOperationalAlert(this.env, `restore-multipart-cleanup:${normalizedMultipartUploadId}`, "Normalized restore multipart cleanup failed", { normalizedObjectKey, normalizedMultipartUploadId, error: error instanceof Error ? error.message : "unknown cleanup failure" });
        }
      }
      if (normalizedObjectKey) {
        try {
          await step.do("delete exact normalized restore object", async () => {
            await this.env.BACKUPS.delete(normalizedObjectKey!);
            return true;
          });
        } catch (error) {
          await raiseOperationalAlert(this.env, `restore-normalized-cleanup:${normalizedObjectKey}`, "Normalized restore object cleanup failed", { normalizedObjectKey, error: error instanceof Error ? error.message : "unknown cleanup failure" });
        }
      }
    }
  }
}
