import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers";
import { NonRetryableError } from "cloudflare:workflows";
import { digestHex, stableJson } from "@thriftycrew/domain";
import { raiseOperationalAlert, resolveOperationalAlert } from "./operations";
import type { WorkerEnv } from "./env";
import { acquireOperationLease, releaseOperationLease } from "./orchestration";

interface BackupWorkflowPayload { trigger?: string; localDate?: string; forceReplica?: boolean }

async function currentBookmark(env: WorkerEnv): Promise<string> {
  if (!env.D1_REST_API_TOKEN || !env.CLOUDFLARE_ACCOUNT_ID || !env.D1_DATABASE_ID) throw new Error("D1 Time Travel credentials are not configured");
  const response = await fetch(`https://api.cloudflare.com/client/v4/accounts/${env.CLOUDFLARE_ACCOUNT_ID}/d1/database/${env.D1_DATABASE_ID}/time_travel/bookmark`, {
    headers: { authorization: `Bearer ${env.D1_REST_API_TOKEN}` },
  });
  const body = await response.json() as { success?: boolean; result?: { bookmark?: string }; errors?: unknown[] };
  if (!response.ok || body.success !== true || !body.result?.bookmark) throw new Error(`D1 bookmark request failed with ${response.status}: ${stableJson(body.errors ?? [])}`);
  return body.result.bookmark;
}

export class D1BackupWorkflow extends WorkflowEntrypoint<WorkerEnv, BackupWorkflowPayload> {
  override async run(event: WorkflowEvent<BackupWorkflowPayload>, step: WorkflowStep): Promise<void> {
    const backupId = `backup_${event.instanceId}`;
    const manifestId = `lake_${event.instanceId}`;
    const runId = `run_${event.instanceId}`;
    const startedAt = new Date().toISOString();
    const lease = await acquireOperationLease(this.env.DB, {
      resource: "workflow:d1-maintenance", holderId: runId, ownerKind: "workflow", leaseMinutes: 30, now: startedAt,
      metadata: { job: "d1-backup", workflowInstance: event.instanceId, mode: "time-travel-lake-manifest", deploymentSafe: true },
    });
    if (!lease) throw new NonRetryableError("another D1 maintenance workflow is active");
    await this.env.DB.batch([
      this.env.DB.prepare(
        `INSERT INTO job_runs
           (id, job, trigger_kind, scheduled_for, started_at, heartbeat_at, status, executor_run_id, actor_id,
            input_json, lease_resource, lease_fence)
         VALUES (?1, 'd1-backup', 'schedule', ?2, ?2, ?2, 'started', ?3, 'cloudflare:workflow', ?4, ?5, ?6)
         ON CONFLICT(id) DO NOTHING`,
      ).bind(runId, startedAt, event.instanceId, stableJson({ mode: "time-travel-lake-manifest" }), lease.resource, lease.fence),
      this.env.DB.prepare("INSERT INTO backup_exports (id, database_id, status, detail_json) VALUES (?1, ?2, 'started', ?3) ON CONFLICT(id) DO NOTHING")
        .bind(backupId, this.env.D1_DATABASE_ID ?? "unconfigured", stableJson({ mode: "time-travel-lake-manifest" })),
    ]);
    try {
      const bookmark = await step.do("capture D1 Time Travel bookmark", () => currentBookmark(this.env));
      const catalog = await step.do("build immutable lake recovery catalog", async () => {
        const [releases, partitions, configuration, immutableObjects, schema] = await Promise.all([
          this.env.DB.prepare(
            `SELECT current.market_id, current.release_id, graph.root_hash, graph.object_key, graph.node_count
               FROM current_releases current JOIN release_graphs graph ON graph.release_id = current.release_id
              ORDER BY current.market_id`,
          ).all<{ market_id: string; release_id: string; root_hash: string; object_key: string; node_count: number }>(),
          this.env.DB.prepare(
            `SELECT COALESCE(partition.batch_id, object.content_hash) AS batch_id,
                    COALESCE(partition.source_id, 'historical-backfill') AS source_id,
                    COALESCE(partition.partition_date, substr(object.created_at, 1, 10)) AS partition_date,
                    object.content_hash, object.object_key, COALESCE(partition.row_count, object.row_count, 0) AS row_count,
                    object.byte_length
               FROM object_store_objects object LEFT JOIN observation_partitions partition ON partition.content_hash = object.content_hash
              WHERE object.object_kind = 'observation-partition'
              ORDER BY partition_date, source_id, batch_id`,
          ).all<{ batch_id: string; source_id: string; partition_date: string; content_hash: string; object_key: string; row_count: number; byte_length: number }>(),
          this.env.DB.prepare("SELECT id, content_hash FROM configuration_versions WHERE active = 1").first<{ id: string; content_hash: string }>(),
          this.env.DB.prepare(
            `SELECT DISTINCT bucket, object_kind, object_key, content_hash, byte_length FROM (
               SELECT 'archive' AS bucket, 'configuration' AS object_kind, archive.object_key,
                      archive.sha256 AS content_hash, archive.byte_length
                 FROM configuration_versions configuration
                 JOIN configuration_archives archive ON archive.configuration_id = configuration.id
                WHERE configuration.active = 1 AND archive.status = 'verified'
               UNION ALL
               SELECT 'evidence', 'release-payload', payload.object_key, payload.content_hash, payload.byte_length
                 FROM current_releases current JOIN release_payloads payload ON payload.release_id = current.release_id
                WHERE payload.object_key IS NOT NULL
               UNION ALL
               SELECT 'evidence', 'recipe-bundle', payload.object_key, payload.content_hash, payload.byte_length
                 FROM current_releases current JOIN release_recipe_payload_refs payload ON payload.release_id = current.release_id
               UNION ALL
               SELECT 'evidence', 'recipe-cost-detail', detail.object_key, detail.content_hash, detail.byte_length
                 FROM current_releases current JOIN recipe_cost_detail_objects detail ON detail.release_id = current.release_id
               UNION ALL
               SELECT 'archive', 'triage-archive', archive.object_key, archive.content_hash, archive.byte_length
                 FROM triage_archives archive
             ) ORDER BY bucket, object_kind, object_key`,
          ).all<{ bucket: "archive" | "evidence"; object_kind: string; object_key: string; content_hash: string; byte_length: number }>(),
          this.env.DB.prepare("SELECT MAX(id) AS latest FROM d1_migrations").first<{ latest: number | null }>().catch(() => ({ latest: null })),
        ]);
        if (!configuration) throw new Error("active configuration is absent from recovery catalog");
        if (releases.results.length === 0) throw new Error("current release graph is absent from recovery catalog");
        if (!immutableObjects.results.some((item) => item.object_kind === "configuration")) throw new Error("active configuration archive is absent from recovery catalog");
        const partitionCatalogHash = await digestHex(stableJson(partitions.results.map((item) => [item.batch_id, item.content_hash, item.object_key, item.row_count, item.byte_length])));
        return {
          version: 2, kind: "grocery-lake-recovery-manifest", createdAt: new Date().toISOString(), bookmark,
          databaseId: this.env.D1_DATABASE_ID, timeTravelRetentionDays: 30,
          configuration, schemaMigration: schema?.latest ?? null,
          releaseRoots: releases.results,
          observationLake: {
            prefix: "observations/schema=1/", partitionCount: partitions.results.length,
            rowCount: partitions.results.reduce((sum, item) => sum + item.row_count, 0),
            byteLength: partitions.results.reduce((sum, item) => sum + item.byte_length, 0),
            catalogHash: partitionCatalogHash,
            partitions: partitions.results,
            latestBySource: Object.values(Object.fromEntries(partitions.results.map((item) => [item.source_id, item]))),
          },
          immutableObjects: immutableObjects.results,
          rebuild: { hotIndex: "scan observation Parquet partitions then promote manifest release roots", releaseGraphPrefix: "release-manifests/schema=1/" },
        };
      });
      const stored = await step.do("replicate recovery manifest", async () => {
        const serialized = stableJson(catalog);
        const hash = await digestHex(serialized);
        const bytes = new TextEncoder().encode(serialized);
        const date = catalog.createdAt.slice(0, 10).replaceAll("-", "/");
        const objectKey = `lake-manifests/${date}/${manifestId}-${hash}.json`;
        const options = { httpMetadata: { contentType: "application/json; charset=utf-8" }, customMetadata: { sha256: hash, bookmark, schema: "grocery-lake-recovery-v2" } };
        await Promise.all([this.env.BACKUPS.put(objectKey, bytes, options), this.env.BACKUPS_SECONDARY.put(objectKey, bytes, options)]);
        const [primary, replica] = await Promise.all([this.env.BACKUPS.head(objectKey), this.env.BACKUPS_SECONDARY.head(objectKey)]);
        if (!primary || !replica || primary.size !== bytes.byteLength || replica.size !== bytes.byteLength
          || primary.customMetadata?.sha256 !== hash || replica.customMetadata?.sha256 !== hash) throw new Error("recovery manifest replication verification failed");
        return { objectKey, hash, byteLength: bytes.byteLength, primaryEtag: primary.etag, replicaEtag: replica.etag };
      });
      const finishedAt = new Date().toISOString();
      await this.env.DB.batch([
        this.env.DB.prepare(
          `INSERT INTO lake_backup_manifests
             (id, bookmark, object_key, content_hash, byte_length, release_root_count, partition_count, replica_verified, status, finished_at)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 1, 'completed', ?8)`,
        ).bind(manifestId, bookmark, stored.objectKey, stored.hash, stored.byteLength, catalog.releaseRoots.length, catalog.observationLake.partitionCount, finishedAt),
        this.env.DB.prepare(
          `UPDATE backup_exports SET bookmark = ?2, object_key = ?3, byte_length = ?4, status = 'completed', finished_at = ?5, detail_json = ?6 WHERE id = ?1`,
        ).bind(backupId, bookmark, stored.objectKey, stored.byteLength, finishedAt, stableJson({ mode: "time-travel-lake-manifest", manifestId, contentHash: stored.hash, replicaVerified: true })),
        this.env.DB.prepare(
          `INSERT INTO backup_replicas (id, backup_id, bucket, object_key, byte_length, etag, status, finished_at)
           VALUES (?1, ?2, 'tc-grocery-v3-backups-secondary', ?3, ?4, ?5, 'completed', ?6)`,
        ).bind(`replica_${event.instanceId}`, backupId, stored.objectKey, stored.byteLength, stored.replicaEtag, finishedAt),
        this.env.DB.prepare("UPDATE job_runs SET status = 'completed', heartbeat_at = ?2, finished_at = ?2, stats_json = ?3 WHERE id = ?1")
          .bind(runId, finishedAt, stableJson({ backupId, manifestId, bookmark, ...stored, partitions: catalog.observationLake.partitionCount,
            releaseRoots: catalog.releaseRoots.length, immutableObjects: catalog.immutableObjects.length })),
      ]);
      await resolveOperationalAlert(this.env, "d1-backup", { backupId, manifestId, finishedAt }, { recoveryTitle: "D1 Time Travel and R2 lake manifest backup recovered" });
    } catch (error) {
      const finishedAt = new Date().toISOString();
      const message = error instanceof Error ? error.message : "unknown backup failure";
      await this.env.DB.batch([
        this.env.DB.prepare("UPDATE backup_exports SET status = 'failed', finished_at = ?2, detail_json = ?3 WHERE id = ?1").bind(backupId, finishedAt, stableJson({ mode: "time-travel-lake-manifest", error: message })),
        this.env.DB.prepare("UPDATE job_runs SET status = 'failed', heartbeat_at = ?2, finished_at = ?2, error = ?3 WHERE id = ?1").bind(runId, finishedAt, message),
      ]);
      await raiseOperationalAlert(this.env, "d1-backup", "D1 Time Travel and R2 lake manifest backup failed", { backupId, failedAttempt: event.instanceId, error: message });
      throw error;
    } finally {
      await releaseOperationLease(this.env.DB, lease.resource, runId, lease.fence);
    }
  }
}
