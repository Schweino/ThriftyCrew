import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers";
import { NonRetryableError } from "cloudflare:workflows";
import { digestHex, stableJson } from "@thriftycrew/domain";
import { raiseOperationalAlert, resolveOperationalAlert } from "./operations";
import type { WorkerEnv } from "./env";
import { acquireOperationLease, releaseOperationLease } from "./orchestration";
import { readVerifiedReleaseManifest, verifyHashedObject, verifyReleaseNodeChunk, type ReleaseRecoveryRoot } from "./restore-transitive";

interface RestoreWorkflowPayload { trigger?: string; backupId?: string }

interface RecoveryManifest {
  version: number;
  kind: string;
  createdAt: string;
  bookmark: string;
  releaseRoots: ReleaseRecoveryRoot[];
  observationLake: {
    prefix: string;
    partitionCount: number;
    catalogHash: string;
    partitions: Array<{ batch_id: string; content_hash: string; object_key: string; row_count: number; byte_length: number }>;
    latestBySource: Array<{ content_hash: string; object_key: string }>;
  };
  immutableObjects?: Array<{
    bucket: "archive" | "evidence";
    object_kind: string;
    object_key: string;
    content_hash: string;
    byte_length: number;
  }>;
}

async function currentBookmark(env: WorkerEnv): Promise<string> {
  if (!env.D1_REST_API_TOKEN || !env.CLOUDFLARE_ACCOUNT_ID || !env.D1_DATABASE_ID) throw new Error("D1 Time Travel credentials are not configured");
  const response = await fetch(`https://api.cloudflare.com/client/v4/accounts/${env.CLOUDFLARE_ACCOUNT_ID}/d1/database/${env.D1_DATABASE_ID}/time_travel/bookmark`, {
    headers: { authorization: `Bearer ${env.D1_REST_API_TOKEN}` },
  });
  const body = await response.json() as { success?: boolean; result?: { bookmark?: string }; errors?: unknown[] };
  if (!response.ok || body.success !== true || !body.result?.bookmark) throw new Error(`D1 bookmark verification failed: ${stableJson(body.errors ?? [])}`);
  return body.result.bookmark;
}

export class D1RestoreDrillWorkflow extends WorkflowEntrypoint<WorkerEnv, RestoreWorkflowPayload> {
  override async run(event: WorkflowEvent<RestoreWorkflowPayload>, step: WorkflowStep): Promise<void> {
    const drillId = `restore_${event.instanceId}`;
    const runId = `run_${event.instanceId}`;
    const incidentKey = "d1-restore-drill";
    const startedAt = new Date().toISOString();
    const lease = await acquireOperationLease(this.env.DB, {
      resource: "workflow:d1-maintenance", holderId: runId, ownerKind: "workflow", leaseMinutes: 30, now: startedAt,
      metadata: { job: "d1-restore-drill", workflowInstance: event.instanceId, mode: "non-destructive-manifest-verification", deploymentSafe: true },
    });
    if (!lease) throw new NonRetryableError("another D1 maintenance workflow is active");
    let backupId = "unknown";
    let manifestHash = "0".repeat(64);
    try {
      await this.env.DB.prepare(
        `INSERT INTO job_runs
           (id, job, trigger_kind, scheduled_for, started_at, heartbeat_at, status, executor_run_id, actor_id,
            input_json, lease_resource, lease_fence)
         VALUES (?1, 'restore-drill-quarterly', 'schedule', ?2, ?2, ?2, 'started', ?3, 'cloudflare:workflow', ?4, ?5, ?6)
         ON CONFLICT(id) DO NOTHING`,
      ).bind(runId, startedAt, event.instanceId, stableJson({ mode: "non-destructive-manifest-verification" }), lease.resource, lease.fence).run();
      const selected = await step.do("select lake recovery manifest", async () => {
        const row = event.payload.backupId
          ? await this.env.DB.prepare(
            `SELECT backup.id AS backup_id, lake.object_key, lake.content_hash, lake.bookmark, lake.created_at
               FROM backup_exports backup JOIN lake_backup_manifests lake ON json_extract(backup.detail_json, '$.manifestId') = lake.id
              WHERE backup.id = ?1 AND backup.status = 'completed' AND lake.status = 'completed'`,
          ).bind(event.payload.backupId).first<{ backup_id: string; object_key: string; content_hash: string; bookmark: string; created_at: string }>()
          : await this.env.DB.prepare(
            `SELECT backup.id AS backup_id, lake.object_key, lake.content_hash, lake.bookmark, lake.created_at
               FROM lake_backup_manifests lake JOIN backup_exports backup ON json_extract(backup.detail_json, '$.manifestId') = lake.id
              WHERE backup.status = 'completed' AND lake.status = 'completed' ORDER BY lake.created_at DESC LIMIT 1`,
          ).first<{ backup_id: string; object_key: string; content_hash: string; bookmark: string; created_at: string }>();
        if (!row) throw new Error("no completed lake recovery manifest is available");
        return row;
      });
      backupId = selected.backup_id;
      manifestHash = selected.content_hash;
      const baseEvidence = await step.do("verify Time Travel and recovery manifest replicas", async () => {
        const [primary, replica, bookmarkNow] = await Promise.all([
          this.env.BACKUPS.get(selected.object_key), this.env.BACKUPS_SECONDARY.get(selected.object_key), currentBookmark(this.env),
        ]);
        if (!primary || !replica) throw new Error("primary or secondary recovery manifest is missing");
        const [primaryText, replicaText] = await Promise.all([primary.text(), replica.text()]);
        if (await digestHex(primaryText) !== selected.content_hash || await digestHex(replicaText) !== selected.content_hash || primaryText !== replicaText) {
          throw new Error("recovery manifest hash or replica parity failed");
        }
        const manifest = JSON.parse(primaryText) as RecoveryManifest;
        if (![1, 2].includes(manifest.version) || manifest.kind !== "grocery-lake-recovery-manifest" || manifest.bookmark !== selected.bookmark) throw new Error("recovery manifest contract is invalid");
        const manifestAge = Date.now() - Date.parse(manifest.createdAt);
        if (!Number.isFinite(manifestAge) || manifestAge < 0 || manifestAge > 30 * 24 * 60 * 60 * 1000) {
          throw new Error("recovery manifest bookmark is outside Paid Time Travel retention");
        }
        if (!Array.isArray(manifest.observationLake.partitions)
          || manifest.observationLake.partitions.length !== manifest.observationLake.partitionCount) throw new Error("recovery manifest partition catalog is incomplete");
        const catalogHash = await digestHex(stableJson(manifest.observationLake.partitions.map((item) => [
          item.batch_id, item.content_hash, item.object_key, item.row_count, item.byte_length,
        ])));
        if (catalogHash !== manifest.observationLake.catalogHash) throw new Error("recovery manifest partition catalog hash failed");
        return { manifest, currentBookmark: bookmarkNow };
      });
      const manifest = baseEvidence.manifest;
      let verifiedObjects = 0;
      for (const root of manifest.releaseRoots) {
        const releaseManifest = await step.do(`verify release root ${root.release_id}`, () => readVerifiedReleaseManifest(this.env, root));
        verifiedObjects += 1;
        for (let offset = 0; offset < releaseManifest.nodes.length; offset += 40) {
          const nodes = releaseManifest.nodes.slice(offset, offset + 40);
          verifiedObjects += await step.do(`verify release nodes ${root.release_id} ${offset}`, () => verifyReleaseNodeChunk(this.env, root.release_id, nodes));
        }
      }
      for (let offset = 0; offset < manifest.observationLake.partitions.length; offset += 50) {
        const partitions = manifest.observationLake.partitions.slice(offset, offset + 50);
        await step.do(`verify observation partitions ${offset}`, async () => {
          await Promise.all(partitions.map(async (item) => {
            const object = await this.env.ARCHIVE.head(item.object_key);
            if (!object || object.size !== item.byte_length || object.customMetadata?.sha256 !== item.content_hash) {
              throw new Error(`immutable observation partition is missing or corrupt: ${item.object_key}`);
            }
          }));
        });
        verifiedObjects += partitions.length;
      }
      const immutableObjects = manifest.immutableObjects ?? [];
      for (let offset = 0; offset < immutableObjects.length; offset += 40) {
        const objects = immutableObjects.slice(offset, offset + 40);
        await step.do(`verify immutable release objects ${offset}`, async () => {
          await Promise.all(objects.map((item) => verifyHashedObject(
            item.bucket === "archive" ? this.env.ARCHIVE : this.env.EVIDENCE,
            item.object_key, item.content_hash, item.byte_length,
          )));
        });
        verifiedObjects += objects.length;
      }
      const evidence = { bookmark: manifest.bookmark, currentBookmark: baseEvidence.currentBookmark, releaseRoots: manifest.releaseRoots.length,
        partitions: manifest.observationLake.partitionCount,
        immutableObjects: immutableObjects.length, verifiedObjects, transitive: manifest.version >= 2,
        catalogHash: manifest.observationLake.catalogHash };
      const finishedAt = new Date().toISOString();
      await this.env.DB.batch([
        this.env.DB.prepare(
          `INSERT INTO restore_drills (id, backup_id, scratch_database_id, dump_sha256, status, started_at, finished_at, evidence_json)
           VALUES (?1, ?2, 'r2-lake-manifest-verification', ?3, 'passed', ?4, ?5, ?6)`,
        ).bind(drillId, backupId, manifestHash, startedAt, finishedAt, stableJson({ mode: "non-destructive-manifest-verification", ...evidence })),
        this.env.DB.prepare("UPDATE job_runs SET status = 'completed', heartbeat_at = ?2, finished_at = ?2, stats_json = ?3 WHERE id = ?1")
          .bind(runId, finishedAt, stableJson({ drillId, backupId, ...evidence })),
      ]);
      await resolveOperationalAlert(this.env, incidentKey, { drillId, backupId, finishedAt, ...evidence }, { recoveryTitle: "R2 lake and D1 Time Travel recovery drill passed" });
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown restore drill failure";
      const finishedAt = new Date().toISOString();
      if (backupId !== "unknown") await this.env.DB.prepare(
        `INSERT INTO restore_drills (id, backup_id, scratch_database_id, dump_sha256, status, started_at, finished_at, evidence_json)
         VALUES (?1, ?2, 'r2-lake-manifest-verification', ?3, 'failed', ?4, ?5, ?6)
         ON CONFLICT(id) DO UPDATE SET status = 'failed', finished_at = excluded.finished_at, evidence_json = excluded.evidence_json`,
      ).bind(drillId, backupId, manifestHash, startedAt, finishedAt, stableJson({ error: message })).run();
      await this.env.DB.prepare("UPDATE job_runs SET status = 'failed', heartbeat_at = ?2, finished_at = ?2, error = ?3 WHERE id = ?1").bind(runId, finishedAt, message).run();
      await raiseOperationalAlert(this.env, incidentKey, "R2 lake and D1 Time Travel recovery drill failed", { drillId, backupId, error: message });
      throw error;
    } finally {
      await releaseOperationLease(this.env.DB, lease.resource, runId, lease.fence);
    }
  }
}
