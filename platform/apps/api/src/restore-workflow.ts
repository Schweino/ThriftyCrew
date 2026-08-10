import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers";
import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex } from "@noble/hashes/utils.js";
import { stableJson } from "@thriftycrew/domain";
import { raiseOperationalAlert } from "./operations";
import type { WorkerEnv } from "./env";

interface RestoreWorkflowPayload { trigger?: string }
interface ApiEnvelope<T> { success?: boolean; errors?: unknown[]; result?: T }

async function sha256Stream(body: ReadableStream<Uint8Array>): Promise<string> {
  const hasher = sha256.create();
  const reader = body.getReader();
  while (true) {
    const chunk = await reader.read();
    if (chunk.done) break;
    hasher.update(chunk.value);
  }
  return bytesToHex(hasher.digest());
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
      const hashed = await step.do("hash exact R2 backup", async () => {
        const object = await this.env.BACKUPS.get(backup.object_key);
        if (!object?.body) throw new Error(`backup object ${backup.object_key} is unreadable`);
        const etag = object.etag.replaceAll('"', "");
        if (etag !== dump.etag || object.size !== dump.length) throw new Error("backup object changed between inspection and hashing");
        return { sha256: await sha256Stream(object.body), etag, length: object.size };
      });
      dumpSha256 = hashed.sha256;
      const scratch = await step.do("create isolated scratch D1", async () => cloudflare<{ uuid?: string }>(this.env, "/d1/database", {
        method: "POST",
        body: JSON.stringify({ name: `tc-grocery-v3-restore-${startedAt.slice(0, 10).replaceAll("-", "")}-${event.instanceId.slice(-8)}`, primary_location_hint: "wnam", read_replication: { mode: "disabled" } }),
      }));
      if (!scratch.uuid) throw new Error("scratch D1 creation omitted its UUID");
      scratchDatabaseId = scratch.uuid;
      await this.env.DB.prepare(
        `INSERT INTO restore_drills (id, backup_id, scratch_database_id, dump_sha256, status, started_at, evidence_json)
         VALUES (?1, ?2, ?3, ?4, 'started', ?5, ?6)`,
      ).bind(drillId, backupId, scratchDatabaseId, dumpSha256, startedAt, stableJson({ objectKey: backup.object_key, byteLength: dump.length, trigger: event.payload.trigger ?? "scheduled" })).run();
      const initialized = await step.do("initialize scratch import", async () => cloudflare<{ upload_url?: string; filename?: string }>(this.env, `/d1/database/${scratchDatabaseId}/import`, {
        method: "POST", body: JSON.stringify({ action: "init", etag: dump.etag }),
      }));
      if (!initialized.upload_url || !initialized.filename) throw new Error("D1 import initialization omitted upload metadata");
      await step.do("upload backup to scratch import", async () => {
        const object = await this.env.BACKUPS.get(backup.object_key);
        if (!object?.body) throw new Error(`backup object ${backup.object_key} is unreadable during upload`);
        const etag = object.etag.replaceAll('"', "");
        if (etag !== hashed.etag || object.size !== hashed.length) throw new Error("backup object changed between hashing and upload");
        const response = await fetch(initialized.upload_url!, { method: "PUT", body: object.body });
        if (!response.ok) throw new Error(`scratch import upload returned ${response.status}`);
      });
      const ingested = await step.do("start scratch import", async () => cloudflare<{ at_bookmark?: string; status?: string; error?: string }>(this.env, `/d1/database/${scratchDatabaseId}/import`, {
        method: "POST", body: JSON.stringify({ action: "ingest", etag: dump.etag, filename: initialized.filename }),
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
      const tables = ["capture_batches", "observations", "products", "releases", "release_cells", "job_runs"];
      const comparisons: Record<string, { production: number; scratch: number }> = {};
      for (const table of tables) {
        const production = await this.env.DB.prepare(`SELECT COUNT(*) AS count FROM ${table}`).first<{ count: number }>();
        const restored = await queryScratch<{ count: number }>(this.env, scratchDatabaseId, `SELECT COUNT(*) AS count FROM ${table}`);
        comparisons[table] = { production: production?.count ?? -1, scratch: restored[0]?.count ?? -1 };
      }
      const productionRelease = await this.env.DB.prepare(
        `SELECT r.id, r.input_hash FROM current_releases c JOIN releases r ON r.id = c.release_id WHERE c.market_id = 'omaha'`,
      ).first<{ id: string; input_hash: string }>();
      const scratchRelease = (await queryScratch<{ id: string; input_hash: string }>(this.env, scratchDatabaseId,
        `SELECT r.id, r.input_hash FROM current_releases c JOIN releases r ON r.id = c.release_id WHERE c.market_id = 'omaha'`))[0];
      const countsMatch = Object.values(comparisons).every((value) => value.production === value.scratch);
      const releaseMatches = Boolean(productionRelease && scratchRelease && productionRelease.id === scratchRelease.id && productionRelease.input_hash === scratchRelease.input_hash);
      if (!countsMatch || !releaseMatches) throw new Error(`scratch restore verification failed: ${stableJson({ comparisons, productionRelease, scratchRelease })}`);
      const finishedAt = new Date().toISOString();
      await this.env.DB.batch([
        this.env.DB.prepare("UPDATE restore_drills SET status = 'passed', finished_at = ?2, evidence_json = ?3 WHERE id = ?1")
          .bind(drillId, finishedAt, stableJson({ comparisons, productionRelease, scratchRelease, byteLength: dump.length, importStatus: completed.status })),
        this.env.DB.prepare("UPDATE job_runs SET status = 'completed', heartbeat_at = ?2, finished_at = ?2, stats_json = ?3 WHERE id = ?1")
          .bind(runId, finishedAt, stableJson({ drillId, backupId, scratchDatabaseId, comparisons })),
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
    }
  }
}
