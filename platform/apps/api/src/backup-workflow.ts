import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers";
import { NonRetryableError } from "cloudflare:workflows";
import { stableJson } from "@thriftycrew/domain";
import { raiseOperationalAlert, resolveOperationalAlert } from "./operations";
import type { WorkerEnv } from "./env";
import { D1_EXPORT_POLL_STEP_CONFIG, d1ExportPollPayload, d1ExportTerminalError } from "./backup-policy";
import { acquireOperationLease, releaseOperationLease } from "./orchestration";

interface BackupWorkflowPayload { trigger?: string; localDate?: string; forceReplica?: boolean }

interface ExportResult {
  at_bookmark?: string;
  error?: string;
  messages?: string[];
  status?: "complete" | "error";
  signed_url?: string;
  filename?: string;
  result?: { signed_url?: string; filename?: string };
}

async function exportRequest<T>(env: WorkerEnv, payload: Record<string, unknown>): Promise<T> {
  if (!env.D1_REST_API_TOKEN || !env.CLOUDFLARE_ACCOUNT_ID || !env.D1_DATABASE_ID) {
    throw new Error("D1 export credentials are not configured");
  }
  const response = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${env.CLOUDFLARE_ACCOUNT_ID}/d1/database/${env.D1_DATABASE_ID}/export`,
    {
      method: "POST",
      headers: { authorization: `Bearer ${env.D1_REST_API_TOKEN}`, "content-type": "application/json" },
      body: JSON.stringify(payload),
    },
  );
  const body = await response.json() as { success?: boolean; errors?: unknown[]; result?: T };
  if (!response.ok || body.success !== true || !body.result) {
    throw new Error(`D1 export request failed with ${response.status}: ${stableJson(body.errors ?? [])}`);
  }
  return body.result;
}

export class D1BackupWorkflow extends WorkflowEntrypoint<WorkerEnv, BackupWorkflowPayload> {
  override async run(event: WorkflowEvent<BackupWorkflowPayload>, step: WorkflowStep): Promise<void> {
    const backupId = `backup_${event.instanceId}`;
    const runId = `run_${event.instanceId}`;
    const startedAt = new Date().toISOString();
    const lease = await acquireOperationLease(this.env.DB, {
      resource: "workflow:d1-maintenance", holderId: runId, ownerKind: "workflow", leaseMinutes: 360, now: startedAt,
      metadata: { job: "d1-backup", workflowInstance: event.instanceId, deploymentSafe: false },
    });
    if (!lease) throw new NonRetryableError("another D1 maintenance workflow is active");
    await this.env.DB.batch([
      this.env.DB.prepare(
        `INSERT INTO job_runs
           (id, job, trigger_kind, scheduled_for, started_at, heartbeat_at, status, executor_run_id, actor_id, input_json)
         VALUES (?1, 'd1-backup', 'schedule', ?2, ?2, ?2, 'started', ?3, 'cloudflare:workflow', '{}')
         ON CONFLICT(id) DO NOTHING`,
      ).bind(runId, startedAt, event.instanceId),
      this.env.DB.prepare(
        `INSERT INTO backup_exports (id, database_id, status)
         VALUES (?1, ?2, 'started') ON CONFLICT(id) DO NOTHING`,
      ).bind(backupId, this.env.D1_DATABASE_ID ?? "unconfigured"),
    ]);
    try {
      const bookmark = await step.do("start D1 export", async () => {
        const result = await exportRequest<ExportResult>(this.env, { output_format: "polling" });
        if (!result.at_bookmark) throw new Error("D1 export omitted at_bookmark");
        return result.at_bookmark;
      });
      const stored = await step.do("download and store D1 export", D1_EXPORT_POLL_STEP_CONFIG, async () => {
        const result = await exportRequest<ExportResult>(this.env, d1ExportPollPayload(bookmark));
        const terminalError = d1ExportTerminalError(result);
        if (terminalError) throw new NonRetryableError(terminalError);
        const signedUrl = result.signed_url ?? result.result?.signed_url;
        const filename = result.filename ?? result.result?.filename;
        // Throwing here is intentional: Workflow step retries keep the export
        // alive until Cloudflare returns the one-hour signed download URL.
        if (!signedUrl || !filename) throw new Error("D1 export is not ready");
        const dump = await fetch(signedUrl);
        if (!dump.ok || !dump.body) throw new Error(`D1 export download returned ${dump.status}`);
        const date = new Date().toISOString().slice(0, 10).replaceAll("-", "/");
        const safeFilename = filename.replaceAll(/[^a-zA-Z0-9._-]/g, "-");
        const objectKey = `d1/${date}/${event.instanceId}-${safeFilename}`;
        await this.env.BACKUPS.put(objectKey, dump.body, {
          httpMetadata: { contentType: "application/sql" },
          customMetadata: { bookmark, databaseId: this.env.D1_DATABASE_ID ?? "unknown", workflowInstance: event.instanceId },
        });
        const object = await this.env.BACKUPS.head(objectKey);
        if (!object) throw new Error("R2 backup object was not readable after write");
        return { objectKey, byteLength: object.size, etag: object.etag };
      });
      let replica: { objectKey: string; byteLength: number; etag: string } | null = null;
      const weekday = new Intl.DateTimeFormat("en-US", { timeZone: "America/Chicago", weekday: "short" }).format(event.timestamp);
      if (event.payload.forceReplica === true || weekday === "Sun") {
        const replicaId = `replica_${event.instanceId}`;
        await this.env.DB.prepare(
          `INSERT INTO backup_replicas (id, backup_id, bucket, object_key, byte_length, status)
           VALUES (?1, ?2, 'tc-grocery-v3-backups-secondary', ?3, 0, 'started')
           ON CONFLICT(backup_id, bucket) DO NOTHING`,
        ).bind(replicaId, backupId, stored.objectKey).run();
        replica = await step.do("store weekly backup replica", async () => {
          const primary = await this.env.BACKUPS.get(stored.objectKey);
          if (!primary?.body) throw new Error("primary backup was unavailable for replication");
          await this.env.BACKUPS_SECONDARY.put(stored.objectKey, primary.body, {
            ...(primary.httpMetadata ? { httpMetadata: primary.httpMetadata } : {}),
            customMetadata: { ...(primary.customMetadata ?? {}), replicatedFrom: "tc-grocery-v3-backups" },
          });
          const copy = await this.env.BACKUPS_SECONDARY.head(stored.objectKey);
          if (!copy || copy.size !== stored.byteLength) throw new Error("secondary backup failed size verification");
          return { objectKey: stored.objectKey, byteLength: copy.size, etag: copy.etag };
        });
        await this.env.DB.prepare(
          `UPDATE backup_replicas SET status = 'completed', byte_length = ?2, etag = ?3,
             finished_at = ?4 WHERE id = ?1`,
        ).bind(replicaId, replica.byteLength, replica.etag, new Date().toISOString()).run();
      }
      const finishedAt = new Date().toISOString();
      await this.env.DB.batch([
        this.env.DB.prepare(
          `UPDATE backup_exports
              SET bookmark = ?2, object_key = ?3, byte_length = ?4, status = 'completed',
                  finished_at = ?5, detail_json = ?6
            WHERE id = ?1`,
        ).bind(backupId, bookmark, stored.objectKey, stored.byteLength, finishedAt, stableJson({ etag: stored.etag })),
        this.env.DB.prepare(
          `UPDATE job_runs
              SET status = 'completed', heartbeat_at = ?2, finished_at = ?2,
                  stats_json = ?3, output_hash = NULL
            WHERE id = ?1`,
        ).bind(runId, finishedAt, stableJson({ backupId, bookmark, ...stored, replica })),
      ]);
      await resolveOperationalAlert(this.env, "d1-backup", { backupId, finishedAt, byteLength: stored.byteLength }, { recoveryTitle: "Weekly D1 full export recovered successfully" });
      await releaseOperationLease(this.env.DB, lease.resource, runId, lease.fence, finishedAt);
    } catch (error) {
      const finishedAt = new Date().toISOString();
      const message = error instanceof Error ? error.message : "unknown backup failure";
      await this.env.DB.batch([
        this.env.DB.prepare(
          "UPDATE backup_exports SET status = 'failed', finished_at = ?2, detail_json = ?3 WHERE id = ?1",
        ).bind(backupId, finishedAt, stableJson({ error: message })),
        this.env.DB.prepare(
          "UPDATE job_runs SET status = 'failed', heartbeat_at = ?2, finished_at = ?2, error = ?3 WHERE id = ?1",
        ).bind(runId, finishedAt, message),
        this.env.DB.prepare(
          `UPDATE backup_replicas SET status = 'failed', finished_at = ?2, detail_json = ?3
            WHERE backup_id = ?1 AND status = 'started'`,
        ).bind(backupId, finishedAt, stableJson({ error: message })),
      ]);
      await raiseOperationalAlert(this.env, "d1-backup", "Weekly D1 full export failed", { backupId, failedAttempt: event.instanceId, error: message });
      await releaseOperationLease(this.env.DB, lease.resource, runId, lease.fence, finishedAt);
      throw error;
    }
  }
}
