import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers";
import { stableJson } from "@thriftycrew/domain";
import { raiseOperationalAlert } from "./operations";
import type { WorkerEnv } from "./env";
import {
  RESTORE_COUNT_TABLES,
  emptyRestoreCounts,
  inspectSqlInsert,
  normalizeCaptureBatchLine,
  type RestoreCountTable,
} from "./restore-normalization";

interface RestoreWorkflowPayload { trigger?: string }
interface ApiEnvelope<T> { success?: boolean; errors?: unknown[]; result?: T }

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
  const result = await cloudflare<Array<{ results?: T[] }>>(env, `/d1/database/${databaseId}/query`, { method: "POST", body: JSON.stringify({ sql }) });
  return result[0]?.results ?? [];
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
      const normalized = await step.do("normalize forward capture references", {
        retries: { limit: 2, delay: "30 seconds", backoff: "constant" },
        timeout: "30 minutes",
      }, async () => {
        const source = await this.env.BACKUPS.get(backup.object_key);
        if (!source?.body) throw new Error(`backup object ${backup.object_key} is unreadable during normalization`);
        const sourceEtag = source.etag.replaceAll('"', "");
        if (sourceEtag !== dump.etag || source.size !== dump.length) throw new Error("backup object changed between hashing and normalization");
        const expectedCounts = emptyRestoreCounts();
        const releaseHashes: Record<string, string> = {};
        const deferredUpdates: string[] = [];
        let currentReleaseId: string | null = null;
        let carry = "";
        const processLine = (line: string): string => {
          const adjusted = normalizeCaptureBatchLine(line);
          if (adjusted.deferredUpdate) deferredUpdates.push(adjusted.deferredUpdate);
          const insert = inspectSqlInsert(line);
          if (insert) {
            if (RESTORE_COUNT_TABLES.includes(insert.table as RestoreCountTable)) {
              expectedCounts[insert.table as RestoreCountTable] += 1;
            }
            const record = Object.fromEntries(insert.columns.map((column, index) => [column, insert.values[index]]));
            if (insert.table === "current_releases" && record.market_id === "omaha" && typeof record.release_id === "string") {
              currentReleaseId = record.release_id;
            }
            if (insert.table === "releases" && typeof record.id === "string" && typeof record.input_hash === "string") {
              releaseHashes[record.id] = record.input_hash;
            }
          }
          return `${adjusted.line}\n`;
        };
        const transformer = new TransformStream<string, string>({
          transform(chunk, controller) {
            const lines = `${carry}${chunk}`.split("\n");
            carry = lines.pop() ?? "";
            for (const line of lines) controller.enqueue(processLine(line));
          },
          flush(controller) {
            if (carry) controller.enqueue(processLine(carry));
            if (deferredUpdates.length > 0) controller.enqueue(`${deferredUpdates.join("\n")}\n`);
          },
        });
        const body = source.body
          .pipeThrough(new TextDecoderStream())
          .pipeThrough(transformer)
          .pipeThrough(new TextEncoderStream());
        const stored = await this.env.BACKUPS.put(normalizedObjectKey!, body, {
          httpMetadata: { contentType: "application/sql" },
          customMetadata: { sourceObjectKey: backup.object_key, sourceDumpSha256: dumpSha256 },
        });
        if (!stored) throw new Error("normalized restore object upload returned no object metadata");
        const expectedRelease = currentReleaseId ? { id: currentReleaseId, inputHash: releaseHashes[currentReleaseId] } : null;
        if (!expectedRelease?.inputHash) throw new Error("backup dump omitted the current Omaha release or its input hash");
        return {
          objectKey: normalizedObjectKey!,
          etag: stored.etag.replaceAll('"', ""),
          length: stored.size,
          deferredSupersessionUpdates: deferredUpdates.length,
          expectedCounts,
          expectedRelease,
        };
      });
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
      ).bind(drillId, backupId, scratchDatabaseId, dumpSha256, startedAt, stableJson({ objectKey: backup.object_key, byteLength: dump.length, etag: dump.etag, hashScheme, hashChunkBytes, chunkCount: chunkHashes.length, normalized, trigger: event.payload.trigger ?? "scheduled" })).run();
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
          .bind(drillId, finishedAt, stableJson({ comparisons, expectedRelease: normalized.expectedRelease, scratchRelease, liveRelease, byteLength: dump.length, etag: dump.etag, hashScheme, hashChunkBytes, chunkCount: chunkHashes.length, normalizedObjectKey: normalized.objectKey, normalizedEtag: normalized.etag, normalizedByteLength: normalized.length, deferredSupersessionUpdates: normalized.deferredSupersessionUpdates, comparisonBasis: "dump-stream-counts+dump-release-pointer", importStatus: completed.status })),
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
